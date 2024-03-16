/*
 * Copyright (c) 2010-2012 Apple Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 *
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 *
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 *
 * @APPLE_LICENSE_HEADER_END@
 */

#include "objc-private.h"
#include "NSObject.h"

#include "objc-weak.h"
#include "DenseMapExtras.h"

#include <malloc/malloc.h>
#include <stdint.h>
#include <stdbool.h>
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>
#include <sys/types.h>
#include <Block.h>
#include <map>
#include "NSObject-internal.h"
#include "NSObject-private.h"

#if !TARGET_OS_EXCLAVEKIT
#include <mach/mach.h>
#include <sys/mman.h>
#include <execinfo.h>

//#include <os/feature_private.h>

extern "C" {
#include <os/reason_private.h>
#include <os/variant_private.h>
#include <os/log_simple_private.h>
}
#endif

@interface NSInvocation
- (SEL)selector;
@end

OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_magic_offset  = __builtin_offsetof(AutoreleasePoolPageData, magic);
OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_next_offset   = __builtin_offsetof(AutoreleasePoolPageData, next);
OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_thread_offset = __builtin_offsetof(AutoreleasePoolPageData, thread);
OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_parent_offset = __builtin_offsetof(AutoreleasePoolPageData, parent);
OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_child_offset  = __builtin_offsetof(AutoreleasePoolPageData, child);
OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_depth_offset  = __builtin_offsetof(AutoreleasePoolPageData, depth);
OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_hiwat_offset  = __builtin_offsetof(AutoreleasePoolPageData, hiwat);
OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_begin_offset  = sizeof(AutoreleasePoolPageData);
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
OBJC_EXTERN const uintptr_t objc_debug_autoreleasepoolpage_ptr_mask = (AutoreleasePoolPageData::AutoreleasePoolEntry){ .ptr = ~(uintptr_t)0 }.ptr;
#else
OBJC_EXTERN const uintptr_t objc_debug_autoreleasepoolpage_ptr_mask = ~(uintptr_t)0;
#endif
OBJC_EXTERN const uint32_t objc_class_abi_version = OBJC_CLASS_ABI_VERSION_MAX;

/***********************************************************************
* Weak ivar support
**********************************************************************/

static id defaultBadAllocHandler(Class cls)
{
    _objc_fatal("attempt to allocate object of class '%s' failed", 
                cls->nameForLogging());
}

id(*badAllocHandler)(Class) = &defaultBadAllocHandler;

id _objc_callBadAllocHandler(Class cls)
{
    // fixme add re-entrancy protection in case allocation fails inside handler
    return (*badAllocHandler)(cls);
}

void _objc_setBadAllocHandler(id(*newHandler)(Class))
{
    badAllocHandler = newHandler;
}


static id _initializeSwiftRefcountingThenCallRetain(id objc);
static void _initializeSwiftRefcountingThenCallRelease(id objc);

explicit_atomic<id(*)(id)> swiftRetain{&_initializeSwiftRefcountingThenCallRetain};
explicit_atomic<void(*)(id)> swiftRelease{&_initializeSwiftRefcountingThenCallRelease};

static void _initializeSwiftRefcounting() {
    void *const token = dlopen("/usr/lib/swift/libswiftCore.dylib", RTLD_LAZY | RTLD_LOCAL);
    ASSERT(token);
    swiftRetain.store((id(*)(id))dlsym(token, "swift_retain"), memory_order_relaxed);
    ASSERT(swiftRetain.load(memory_order_relaxed));
    swiftRelease.store((void(*)(id))dlsym(token, "swift_release"), memory_order_relaxed);
    ASSERT(swiftRelease.load(memory_order_relaxed));
    dlclose(token);
}

static id _initializeSwiftRefcountingThenCallRetain(id objc) {
  _initializeSwiftRefcounting();
  return swiftRetain.load(memory_order_relaxed)(objc);
}

static void _initializeSwiftRefcountingThenCallRelease(id objc) {
  _initializeSwiftRefcounting();
  swiftRelease.load(memory_order_relaxed)(objc);
}

namespace objc {
    extern int PageCountWarning;
}

namespace {

_Atomic uint32_t numFaults = 0;

// The order of these bits is important.
#define SIDE_TABLE_WEAKLY_REFERENCED (1UL<<0)
#define SIDE_TABLE_DEALLOCATING      (1UL<<1)  // MSB-ward of weak bit
#define SIDE_TABLE_RC_ONE            (1UL<<2)  // MSB-ward of deallocating bit
#define SIDE_TABLE_RC_PINNED         (1UL<<(WORD_BITS-1))

#define SIDE_TABLE_RC_SHIFT 2
#define SIDE_TABLE_FLAG_MASK (SIDE_TABLE_RC_ONE-1)

template<>
void SideTable::lockTwo<DoHaveOld, DoHaveNew>
    (SideTable *lock1, SideTable *lock2)
{
    spinlock_t::lockTwo(&lock1->slock, &lock2->slock);
}

template<>
void SideTable::lockTwo<DoHaveOld, DontHaveNew>
    (SideTable *lock1, SideTable *)
{
    lock1->lock();
}

template<>
void SideTable::lockTwo<DontHaveOld, DoHaveNew>
    (SideTable *, SideTable *lock2)
{
    lock2->lock();
}

template<>
void SideTable::unlockTwo<DoHaveOld, DoHaveNew>
    (SideTable *lock1, SideTable *lock2)
{
    spinlock_t::unlockTwo(&lock1->slock, &lock2->slock);
}

template<>
void SideTable::unlockTwo<DoHaveOld, DontHaveNew>
    (SideTable *lock1, SideTable *)
{
    lock1->unlock();
}

template<>
void SideTable::unlockTwo<DontHaveOld, DoHaveNew>
    (SideTable *, SideTable *lock2)
{
    lock2->unlock();
}

static objc::ExplicitInit<StripedMap<SideTable>> SideTablesMap;
OBJC_EXTERN void *const objc_debug_side_tables_map = &SideTablesMap;

static StripedMap<SideTable>& SideTables() {
    return SideTablesMap.get();
}

// anonymous namespace
};

void SideTableLockAll() {
    SideTables().lockAll();
}

void SideTableUnlockAll() {
    SideTables().unlockAll();
}

void SideTableForceResetAll() {
    SideTables().forceResetAll();
}

void SideTableDefineLockOrder() {
    SideTables().defineLockOrder();
}

void SideTableLocksPrecedeLock(const void *newlock) {
    SideTables().precedeLock(newlock);
}

void SideTableLocksSucceedLock(const void *oldlock) {
    SideTables().succeedLock(oldlock);
}

void SideTableLocksPrecedeLocks(StripedMap<spinlock_t>& newlocks) {
    int i = 0;
    const void *newlock;
    while ((newlock = newlocks.getLock(i++))) {
        SideTables().precedeLock(newlock);
    }
}

void SideTableLocksSucceedLocks(StripedMap<spinlock_t>& oldlocks) {
    int i = 0;
    const void *oldlock;
    while ((oldlock = oldlocks.getLock(i++))) {
        SideTables().succeedLock(oldlock);
    }
}

// Call out to the _setWeaklyReferenced method on obj, if implemented.
static void callSetWeaklyReferenced(id obj) {
    if (!obj)
        return;

    Class cls = obj->getIsa();

    if (slowpath(cls->hasCustomRR() && !object_isClass(obj))) {
        ASSERT(((objc_class *)cls)->isInitializing() || ((objc_class *)cls)->isInitialized());
        void (*setWeaklyReferenced)(id, SEL) = (void(*)(id, SEL))
        class_getMethodImplementation(cls, @selector(_setWeaklyReferenced));
        if ((IMP)setWeaklyReferenced != _objc_msgForward) {
          (*setWeaklyReferenced)(obj, @selector(_setWeaklyReferenced));
        }
    }
}

//
// The -fobjc-arc flag causes the compiler to issue calls to objc_{retain/release/autorelease/retain_block}
//

id objc_retainBlock(id x) {
    return (id)_Block_copy(x);
}

//
// The following SHOULD be called by the compiler directly, but the request hasn't been made yet :-)
//

BOOL objc_should_deallocate(id object) {
    return YES;
}

id
objc_retain_autorelease(id obj)
{
    return objc_autorelease(objc_retain(obj));
}


void
objc_storeStrong(id *location, id obj)
{
    id prev = *location;
    if (obj == prev) {
        return;
    }
    objc_retain(obj);
    *location = obj;
    objc_release(prev);
}


// Update a weak variable.
// If HaveOld is true, the variable has an existing value 
//   that needs to be cleaned up. This value might be nil.
// If HaveNew is true, there is a new value that needs to be 
//   assigned into the variable. This value might be nil.
// If CrashIfDeallocating is true, the process is halted if newObj is 
//   deallocating or newObj's class does not support weak references. 
//   If CrashIfDeallocating is false, nil is stored instead.
enum CrashIfDeallocating {
    DontCrashIfDeallocating = false, DoCrashIfDeallocating = true
};
template <HaveOld haveOld, HaveNew haveNew,
          enum CrashIfDeallocating crashIfDeallocating>
static id 
storeWeak(id *location, objc_object *newObj)
{
    ASSERT(haveOld  ||  haveNew);
    if (!haveNew) ASSERT(newObj == nil);

    Class previouslyInitializedClass = nil;
    id oldObj;
    SideTable *oldTable;
    SideTable *newTable;

    // Acquire locks for old and new values.
    // Order by lock address to prevent lock ordering problems. 
    // Retry if the old value changes underneath us.
 retry:
    if (haveOld) {
        oldObj = *location;
        oldTable = &SideTables()[oldObj];
    } else {
        oldTable = nil;
    }
    if (haveNew) {
        newTable = &SideTables()[newObj];
    } else {
        newTable = nil;
    }

    SideTable::lockTwo<haveOld, haveNew>(oldTable, newTable);

    if (haveOld  &&  *location != oldObj) {
        SideTable::unlockTwo<haveOld, haveNew>(oldTable, newTable);
        goto retry;
    }

    // Prevent a deadlock between the weak reference machinery
    // and the +initialize machinery by ensuring that no 
    // weakly-referenced object has an un-+initialized isa.
    if (haveNew  &&  newObj) {
        Class cls = newObj->getIsa();
        if (cls != previouslyInitializedClass  &&  
            !((objc_class *)cls)->isInitialized()) 
        {
            SideTable::unlockTwo<haveOld, haveNew>(oldTable, newTable);
            class_initialize(cls, (id)newObj);

            // If this class is finished with +initialize then we're good.
            // If this class is still running +initialize on this thread 
            // (i.e. +initialize called storeWeak on an instance of itself)
            // then we may proceed but it will appear initializing and 
            // not yet initialized to the check above.
            // Instead set previouslyInitializedClass to recognize it on retry.
            previouslyInitializedClass = cls;

            goto retry;
        }
    }

    // Clean up old value, if any.
    if (haveOld) {
        weak_unregister_no_lock(&oldTable->weak_table, oldObj, location);
    }

    // Assign new value, if any.
    if (haveNew) {
        newObj = (objc_object *)
            weak_register_no_lock(&newTable->weak_table, (id)newObj, location, 
                                  crashIfDeallocating ? CrashIfDeallocating : ReturnNilIfDeallocating);
        // weak_register_no_lock returns nil if weak store should be rejected

        // Set is-weakly-referenced bit in refcount table.
        if (!_objc_isTaggedPointerOrNil(newObj)) {
            newObj->setWeaklyReferenced_nolock();
        }

        // Do not set *location anywhere else. That would introduce a race.
        *location = (id)newObj;
    }
    else {
        // No new value. The storage is not changed.
    }
    
    SideTable::unlockTwo<haveOld, haveNew>(oldTable, newTable);

    // This must be called without the locks held, as it can invoke
    // arbitrary code. In particular, even if _setWeaklyReferenced
    // is not implemented, resolveInstanceMethod: may be, and may
    // call back into the weak reference machinery.
    callSetWeaklyReferenced((id)newObj);

    return (id)newObj;
}


/** 
 * This function stores a new value into a __weak variable. It would
 * be used anywhere a __weak variable is the target of an assignment.
 * 
 * @param location The address of the weak pointer itself
 * @param newObj The new object this weak ptr should now point to
 * 
 * @return \e newObj
 */
id
objc_storeWeak(id *location, id newObj)
{
    return storeWeak<DoHaveOld, DoHaveNew, DoCrashIfDeallocating>
        (location, (objc_object *)newObj);
}


/** 
 * This function stores a new value into a __weak variable. 
 * If the new object is deallocating or the new object's class 
 * does not support weak references, stores nil instead.
 * 
 * @param location The address of the weak pointer itself
 * @param newObj The new object this weak ptr should now point to
 * 
 * @return The value stored (either the new object or nil)
 */
id
objc_storeWeakOrNil(id *location, id newObj)
{
    return storeWeak<DoHaveOld, DoHaveNew, DontCrashIfDeallocating>
        (location, (objc_object *)newObj);
}


/** 
 * Initialize a fresh weak pointer to some object location. 
 * It would be used for code like: 
 *
 * (The nil case) 
 * __weak id weakPtr;
 * (The non-nil case) 
 * NSObject *o = ...;
 * __weak id weakPtr = o;
 * 
 * This function IS NOT thread-safe with respect to concurrent 
 * modifications to the weak variable. (Concurrent weak clear is safe.)
 *
 * @param location Address of __weak ptr. 
 * @param newObj Object ptr. 
 */
id
objc_initWeak(id *location, id newObj)
{
    if (!newObj) {
        *location = nil;
        return nil;
    }

    return storeWeak<DontHaveOld, DoHaveNew, DoCrashIfDeallocating>
        (location, (objc_object*)newObj);
}

id
objc_initWeakOrNil(id *location, id newObj)
{
    if (!newObj) {
        *location = nil;
        return nil;
    }

    return storeWeak<DontHaveOld, DoHaveNew, DontCrashIfDeallocating>
        (location, (objc_object*)newObj);
}


/** 
 * Destroys the relationship between a weak pointer
 * and the object it is referencing in the internal weak
 * table. If the weak pointer is not referencing anything, 
 * there is no need to edit the weak table. 
 *
 * This function IS NOT thread-safe with respect to concurrent 
 * modifications to the weak variable. (Concurrent weak clear is safe.)
 * 
 * @param location The weak pointer address. 
 */
void
objc_destroyWeak(id *location)
{
    (void)storeWeak<DoHaveOld, DontHaveNew, DontCrashIfDeallocating>
        (location, nil);
}


/*
  Once upon a time we eagerly cleared *location if we saw the object 
  was deallocating. This confuses code like NSPointerFunctions which 
  tries to pre-flight the raw storage and assumes if the storage is 
  zero then the weak system is done interfering. That is false: the 
  weak system is still going to check and clear the storage later. 
  This can cause objc_weak_error complaints and crashes.
  So we now don't touch the storage until deallocation completes.
*/

id
objc_loadWeakRetained(id *location)
{
    id obj;
    id result;
    Class cls;

    SideTable *table;
    
 retry:
    // fixme std::atomic this load
    obj = *location;
    if (_objc_isTaggedPointerOrNil(obj)) return obj;
    
    table = &SideTables()[obj];
    
    table->lock();
    if (*location != obj) {
        table->unlock();
        goto retry;
    }
    
    result = obj;

    cls = obj->ISA();
    if (! cls->hasCustomRR()) {
        // Fast case. We know +initialize is complete because
        // default-RR can never be set before then.
        ASSERT(cls->isInitialized());
        if (! obj->rootTryRetain()) {
            result = nil;
        }
    }
    else {
        // Slow case. We must check for +initialize and call it outside
        // the lock if necessary in order to avoid deadlocks.
        // Use lookUpImpOrForward so we can avoid the assert in
        // class_getInstanceMethod, since we intentionally make this
        // callout with the lock held.
        if (cls->isInitialized() || _thisThreadIsInitializingClass(cls)) {
            BOOL (*tryRetain)(id, SEL) = (BOOL(*)(id, SEL))
                lookUpImpOrForwardTryCache(obj, @selector(retainWeakReference), cls);
            if ((IMP)tryRetain == _objc_msgForward) {
                result = nil;
            }
            else if (! (*tryRetain)(obj, @selector(retainWeakReference))) {
                result = nil;
            }
        }
        else {
            table->unlock();
            class_initialize(cls, obj);
            goto retry;
        }
    }
        
    table->unlock();
    return result;
}

/** 
 * This loads the object referenced by a weak pointer and returns it, after
 * retaining and autoreleasing the object to ensure that it stays alive
 * long enough for the caller to use it. This function would be used
 * anywhere a __weak variable is used in an expression.
 * 
 * @param location The weak pointer address
 * 
 * @return The object pointed to by \e location, or \c nil if \e location is \c nil.
 */
id
objc_loadWeak(id *location)
{
    if (!*location) return nil;
    return objc_autorelease(objc_loadWeakRetained(location));
}


/** 
 * This function copies a weak pointer from one location to another,
 * when the destination doesn't already contain a weak pointer. It
 * would be used for code like:
 *
 *  __weak id src = ...;
 *  __weak id dst = src;
 * 
 * This function IS NOT thread-safe with respect to concurrent 
 * modifications to the destination variable. (Concurrent weak clear is safe.)
 *
 * @param dst The destination variable.
 * @param src The source variable.
 */
void
objc_copyWeak(id *dst, id *src)
{
    id obj = objc_loadWeakRetained(src);
    objc_initWeak(dst, obj);
    objc_release(obj);
}

/** 
 * Move a weak pointer from one location to another.
 * Before the move, the destination must be uninitialized.
 * After the move, the source is nil.
 *
 * This function IS NOT thread-safe with respect to concurrent 
 * modifications to either weak variable. (Concurrent weak clear is safe.)
 *
 */
void
objc_moveWeak(id *dst, id *src)
{
    id obj;
    SideTable *table;

retry:
    obj = *src;
    if (obj == nil) {
        *dst = nil;
        return;
    }

    table = &SideTables()[obj];
    table->lock();
    if (*src != obj) {
        table->unlock();
        goto retry;
    }

    weak_unregister_no_lock(&table->weak_table, obj, src);
    weak_register_no_lock(&table->weak_table, obj, dst, DontCheckDeallocating);
    *dst = obj;
    *src = nil;
    table->unlock();
}


/***********************************************************************
   Autorelease pool implementation

   A thread's autorelease pool is a stack of pointers. 
   Each pointer is either an object to release, or POOL_BOUNDARY which is 
     an autorelease pool boundary.
   A pool token is a pointer to the POOL_BOUNDARY for that pool. When 
     the pool is popped, every object hotter than the sentinel is released.
   The stack is divided into a doubly-linked list of pages. Pages are added 
     and deleted as necessary. 
   Thread-local storage points to the hot page, where newly autoreleased 
     objects are stored. 
**********************************************************************/

// The TLS for ReturnAutoreleaseInfo
tls_direct(uintptr_t, tls_key::return_autorelease_object,
           ReturnAutoreleaseInfo::TlsDealloc)
	ReturnAutoreleaseInfo::tlsFirstWord;
tls_direct(const void *, tls_key::return_autorelease_address)
	ReturnAutoreleaseInfo::tlsReturnAddress;

BREAKPOINT_FUNCTION(void objc_autoreleaseNoPool(id obj));
BREAKPOINT_FUNCTION(void objc_autoreleasePoolInvalid(const void *token));

class AutoreleasePoolPage : private AutoreleasePoolPageData
{
	friend struct thread_data_t;

public:
	static size_t const SIZE =
#if PROTECT_AUTORELEASEPOOL
		PAGE_MAX_SIZE;  // must be multiple of vm page size
#else
		PAGE_MIN_SIZE;  // size and alignment, power of 2
#endif

private:
    // EMPTY_POOL_PLACEHOLDER is stored in TLS when exactly one pool is 
    // pushed and it has never contained any objects. This saves memory 
    // when the top level (i.e. libdispatch) pushes and pops pools but 
    // never uses them.
#   define EMPTY_POOL_PLACEHOLDER ((AutoreleasePoolPage*)1)

#   define POOL_BOUNDARY nil

    class HotPageDealloc;
    static tls_direct(AutoreleasePoolPage *, tls_key::autorelease_pool, HotPageDealloc)
        hotPage_;
	static uint8_t const SCRIBBLE = 0xA3;  // 0xA3A3A3A3 after releasing
	static size_t const COUNT = SIZE / sizeof(id);
    static size_t const MAX_FAULTS = 1;

    // SIZE-sizeof(*this) bytes of contents follow

    static void * operator new(size_t size) {
        void *result = 0;
        int r = posix_memalign(&result, SIZE, SIZE);
        ASSERT(r == 0);
        return result;
    }
    static void operator delete(void * p) {
        return free(p);
    }

    inline void protect() {
#if PROTECT_AUTORELEASEPOOL
        mprotect(this, SIZE, PROT_READ);
        check();
#endif
    }

    inline void unprotect() {
#if PROTECT_AUTORELEASEPOOL
        check();
        mprotect(this, SIZE, PROT_READ | PROT_WRITE);
#endif
    }

    void checkTooMuchAutorelease()
    {
#if !TARGET_OS_EXCLAVEKIT
        int newDepth = depth+1;
        if (newDepth == objc::PageCountWarning && numFaults < MAX_FAULTS) {
            bool objcModeNoFaults = DisableFaults || getpid() == 1 || is_root_ramdisk() || !os_variant_has_internal_diagnostics("com.apple.obj-c");
            if (!objcModeNoFaults) {
//                os_fault_with_payload(OS_REASON_LIBSYSTEM,
//                                      OS_REASON_LIBSYSTEM_CODE_FAULT,
//                                      NULL, 0, "Large Autorelease Pool", 0);
            } else {
                os_log_simple("Large Autorelease Pool");
            }
            numFaults++;
        }
#endif
    }

	AutoreleasePoolPage(AutoreleasePoolPage *newParent) :
		AutoreleasePoolPageData(begin(),
								objc_thread_self(),
								newParent,
								newParent ? 1+newParent->depth : 0,
								newParent ? newParent->hiwat : 0)
    {
        if (objc::PageCountWarning != -1) {
            checkTooMuchAutorelease();
        }

        if (parent) {
            parent->check();
            ASSERT(!parent->child);
            parent->unprotect();
            parent->child = this;
            parent->protect();
        }
        protect();
    }

    ~AutoreleasePoolPage() 
    {
        check();
        unprotect();
        ASSERT(empty());

        // Not recursive: we don't want to blow out the stack 
        // if a thread accumulates a stupendous amount of garbage
        ASSERT(!child);
    }

    template<typename Fn>
    void
    busted(Fn log) const
    {
        magic_t right;
        log("autorelease pool page %p corrupted\n"
             "  magic     0x%08x 0x%08x 0x%08x 0x%08x\n"
             "  should be 0x%08x 0x%08x 0x%08x 0x%08x\n"
             "  pthread   %p\n"
             "  should be %p\n", 
             this, 
             magic.m[0], magic.m[1], magic.m[2], magic.m[3], 
             right.m[0], right.m[1], right.m[2], right.m[3], 
             this->thread, objc_thread_self());
    }

    __attribute__((noinline, cold, noreturn))
    void
    busted_die() const
    {
        busted(_objc_fatal);
        __builtin_unreachable();
    }

    inline void
    check(bool die = true) const
    {
        if (!magic.check() || thread != objc_thread_self()) {
            if (die) {
                busted_die();
            } else {
                busted(_objc_inform);
            }
        }
    }

    inline void
    fastcheck() const
    {
#if CHECK_AUTORELEASEPOOL
        check();
#else
        if (! magic.fastcheck()) {
            busted_die();
        }
#endif
    }


    id * begin() {
        return (id *) ((uint8_t *)this+sizeof(*this));
    }

    id * end() {
        return (id *) ((uint8_t *)this+SIZE);
    }

    bool empty() {
        return next == begin();
    }

    bool full() { 
        return next == end();
    }

    bool lessThanHalfFull() {
        return (next - begin() < (end() - begin()) / 2);
    }

    id *add(id obj)
    {
        ASSERT(!full());
        unprotect();
        id *ret;

#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
        if (!DisableAutoreleaseCoalescing || !DisableAutoreleaseCoalescingLRU) {
            if (!DisableAutoreleaseCoalescingLRU) {
                if (!empty() && (obj != POOL_BOUNDARY)) {
                    AutoreleasePoolEntry *topEntry = (AutoreleasePoolEntry *)next - 1;
                    for (uintptr_t offset = 0; offset < 4; offset++) {
                        AutoreleasePoolEntry *offsetEntry = topEntry - offset;
                        if (offsetEntry <= (AutoreleasePoolEntry*)begin() || *(id *)offsetEntry == POOL_BOUNDARY) {
                            break;
                        }
                        if (offsetEntry->ptr == (uintptr_t)obj && offsetEntry->count < AutoreleasePoolEntry::maxCount) {
                            if (offset > 0) {
                                AutoreleasePoolEntry found = *offsetEntry;
                                memmove(offsetEntry, offsetEntry + 1, offset * sizeof(*offsetEntry));
                                *topEntry = found;
                            }
                            topEntry->count++;
                            ret = (id *)topEntry;  // need to reset ret
                            goto done;
                        }
                    }
                }
            } else {
                if (!empty() && (obj != POOL_BOUNDARY)) {
                    AutoreleasePoolEntry *prevEntry = (AutoreleasePoolEntry *)next - 1;
                    if (prevEntry->ptr == (uintptr_t)obj && prevEntry->count < AutoreleasePoolEntry::maxCount) {
                        prevEntry->count++;
                        ret = (id *)prevEntry;  // need to reset ret
                        goto done;
                    }
                }
            }
        }
#endif
        ret = next;  // faster than `return next-1` because of aliasing
        *next++ = obj;
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
        // Make sure obj fits in the bits available for it
        ASSERT(((AutoreleasePoolEntry *)ret)->ptr == (uintptr_t)obj);
#endif
     done:
        protect();
        return ret;
    }

    // Release the conceptually autoreleased object in the ReturnAutoreleaseInfo
    // TLS, clearing the TLS before performing the release. Returns true if an
    // object was released, false if the TLS was already empty.
    static bool releaseReturnAutoreleaseTLS() {
        ReturnAutoreleaseInfo info = getReturnAutoreleaseInfo();
        if (id obj = info.getReturnedObject()) {
            setReturnAutoreleaseInfo({});
            objc_release(obj);
            return true;
        }
        return false;
    }

    void releaseAll() 
    {
        releaseUntil(begin());
    }

    void releaseUntil(id *stop) 
    {
        // Not recursive: we don't want to blow out the stack 
        // if a thread accumulates a stupendous amount of garbage

        do {
            while (this->next != stop) {
                // Restart from hotPage() every time, in case -release
                // autoreleased more objects
                AutoreleasePoolPage *page = hotPage();

                // fixme I think this `while` can be `if`, but I can't prove it
                while (page->empty()) {
                    page = page->parent;
                    setHotPage(page);
                }

                page->unprotect();
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
                AutoreleasePoolEntry* entry = (AutoreleasePoolEntry*) --page->next;

                // create an obj with the zeroed out top byte and release that
                id obj = (id)entry->ptr;
                int count = (int)entry->count;  // grab these before memset
#else
                id obj = *--page->next;
#endif
                memset((void*)page->next, SCRIBBLE, sizeof(*page->next));
                page->protect();

                if (obj != POOL_BOUNDARY) {
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
                    // release count+1 times since it is count of the additional
                    // autoreleases beyond the first one
                    for (int i = 0; i < count + 1; i++) {
                        objc_release(obj);
                    }
#else
                    objc_release(obj);
#endif
                }
            }

            // Stale return autorelease info is conceptually autoreleased. If
            // there is any, release the object in the info. If stale info is
            // present, we have to loop in case it autoreleased more objects
            // when it was released.
        } while (releaseReturnAutoreleaseTLS());

        setHotPage(this);

#if DEBUG
        // we expect any children to be completely empty
        for (AutoreleasePoolPage *page = child; page; page = page->child) {
            ASSERT(page->empty());
        }
#endif
    }

    void kill() 
    {
        // Not recursive: we don't want to blow out the stack 
        // if a thread accumulates a stupendous amount of garbage
        AutoreleasePoolPage *page = this;
        while (page->child) page = page->child;

        AutoreleasePoolPage *deathptr;
        do {
            deathptr = page;
            page = page->parent;
            if (page) {
                page->unprotect();
                page->child = nil;
                page->protect();
            }
            deathptr->unprotect();
            delete deathptr;
        } while (deathptr != this);
    }

    static AutoreleasePoolPage *pageForPointer(const void *p) 
    {
        return pageForPointer((uintptr_t)p);
    }

    static AutoreleasePoolPage *pageForPointer(uintptr_t p) 
    {
        AutoreleasePoolPage *result;
        uintptr_t offset = p % SIZE;

        ASSERT(offset >= sizeof(AutoreleasePoolPage));

        result = (AutoreleasePoolPage *)(p - offset);
        result->fastcheck();

        return result;
    }


    static inline bool haveEmptyPoolPlaceholder()
    {
        return hotPage_ == EMPTY_POOL_PLACEHOLDER;
    }

    static inline id* setEmptyPoolPlaceholder()
    {
        hotPage_ = EMPTY_POOL_PLACEHOLDER;
        return (id *)EMPTY_POOL_PLACEHOLDER;
    }

    static inline AutoreleasePoolPage *hotPage() 
    {
        AutoreleasePoolPage *result = hotPage_;
        if (result == EMPTY_POOL_PLACEHOLDER) return nil;
        if (result) result->fastcheck();
        return result;
    }

    static inline void setHotPage(AutoreleasePoolPage *page) 
    {
        if (page) page->fastcheck();
        hotPage_ = page;
    }

    static inline AutoreleasePoolPage *coldPage() 
    {
        AutoreleasePoolPage *result = hotPage();
        if (result) {
            while (result->parent) {
                result = result->parent;
                result->fastcheck();
            }
        }
        return result;
    }


    static inline id *autoreleaseFast(id obj)
    {
        AutoreleasePoolPage *page = hotPage();
        if (page && !page->full()) {
            return page->add(obj);
        } else if (page) {
            return autoreleaseFullPage(obj, page);
        } else {
            return autoreleaseNoPage(obj);
        }
    }

    static __attribute__((noinline))
    id *autoreleaseFullPage(id obj, AutoreleasePoolPage *page)
    {
        // The hot page is full. 
        // Step to the next non-full page, adding a new page if necessary.
        // Then add the object to that page.
        ASSERT(page == hotPage());
        ASSERT(page->full()  ||  DebugPoolAllocation);

        do {
            if (page->child) page = page->child;
            else page = new AutoreleasePoolPage(page);
        } while (page->full());

        setHotPage(page);

        // dtrace probe
        OBJC_RUNTIME_AUTORELEASE_POOL_GROW(page->depth);

        return page->add(obj);
    }

    static __attribute__((noinline))
    id *autoreleaseNoPage(id obj)
    {
        // "No page" could mean no pool has been pushed
        // or an empty placeholder pool has been pushed and has no contents yet
        ASSERT(!hotPage());

        bool pushExtraBoundary = false;
        if (haveEmptyPoolPlaceholder()) {
            // We are pushing a second pool over the empty placeholder pool
            // or pushing the first object into the empty placeholder pool.
            // Before doing that, push a pool boundary on behalf of the pool 
            // that is currently represented by the empty placeholder.
            pushExtraBoundary = true;
        }
        else if (obj != POOL_BOUNDARY  &&  DebugMissingPools) {
            // We are pushing an object with no pool in place, 
            // and no-pool debugging was requested by environment.
            _objc_inform("MISSING POOLS: (%p) Object %p of class %s "
                         "autoreleased with no pool in place - "
                         "just leaking - break on "
                         "objc_autoreleaseNoPool() to debug", 
                         objc_thread_self(), (void*)obj, object_getClassName(obj));
            objc_autoreleaseNoPool(obj);

            if (DebugMissingPools == Fatal)
                _objc_fatal("Missing pools are a fatal error");

            return nil;
        }
        else if (obj == POOL_BOUNDARY  &&  !DebugPoolAllocation) {
            // We are pushing a pool with no pool in place,
            // and alloc-per-pool debugging was not requested.
            // Install and return the empty pool placeholder.
            return setEmptyPoolPlaceholder();
        }

        // We are pushing an object or a non-placeholder'd pool.

        // Install the first page.
        AutoreleasePoolPage *page = new AutoreleasePoolPage(nil);
        setHotPage(page);

        // dtrace probe
        OBJC_RUNTIME_AUTORELEASE_POOL_GROW(page->depth);

        // Push a boundary on behalf of the previously-placeholder'd pool.
        if (pushExtraBoundary) {
            page->add(POOL_BOUNDARY);
        }

        // Push the requested object or pool.
        return page->add(obj);
    }


    static __attribute__((noinline))
    id *autoreleaseNewPage(id obj)
    {
        AutoreleasePoolPage *page = hotPage();
        if (page) return autoreleaseFullPage(obj, page);
        else return autoreleaseNoPage(obj);
    }

public:
    static inline id autorelease(id obj)
    {
        ASSERT(!_objc_isTaggedPointerOrNil(obj));
        id *dest __unused = autoreleaseFast(obj);
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
        ASSERT(!dest  ||  dest == (id *)EMPTY_POOL_PLACEHOLDER  ||  (id)((AutoreleasePoolEntry *)dest)->ptr == obj);
#else
        ASSERT(!dest  ||  dest == (id *)EMPTY_POOL_PLACEHOLDER  ||  *dest == obj);
#endif
        return obj;
    }

    static inline void moveTLSAutoreleaseToPool(ReturnAutoreleaseInfo info)
    {
        if (id obj = info.getReturnedObject()) {
            if (info.cameFromRootAutorelease) {
                // This object already got an autorelease message, don't send
                // another one.
                autorelease(obj);
            } else {
                // Force this to be a real, non-elided autorelease. If this
                // calls back to the default implementation, we want it to go
                // into the pool, not the TLS.
                setReturnAutoreleaseInfo(ReturnAutoreleaseInfo::blockedInfo());
                objc_autorelease(obj);
            }
        }
        setReturnAutoreleaseInfo({});
    }

    static inline void *push() 
    {
        ReturnAutoreleaseInfo info = getReturnAutoreleaseInfo();
        moveTLSAutoreleaseToPool(info);

        id *dest;
        if (slowpath(DebugPoolAllocation)) {
            // Each autorelease pool starts on a new pool page.
            dest = autoreleaseNewPage(POOL_BOUNDARY);
        } else {
            dest = autoreleaseFast(POOL_BOUNDARY);
        }
        ASSERT(dest == (id *)EMPTY_POOL_PLACEHOLDER || *dest == POOL_BOUNDARY);

        // dtrace probe
        OBJC_RUNTIME_AUTORELEASE_POOL_PUSH(dest);

        return dest;
    }

    __attribute__((noinline, cold))
    static void badPop(void *token)
    {
        static bool complained = false;
#if TARGET_OS_EXCLAVEKIT
        bool willTerminate = true;
#else
        bool willTerminate = (DebugPoolAllocation == Fatal
                              || true /*sdkIsAtLeast(10_12, 10_0, 10_0, 3_0, 2_0)*/);
#endif

        if (!complained) {
            complained = true;
            _objc_inform_now_and_on_crash
                ("Invalid or prematurely-freed autorelease pool %p. "
                 "Set a breakpoint on objc_autoreleasePoolInvalid to debug. ",
                 token);
            if (!willTerminate)
                _objc_inform("Proceeding anyway.  Memory errors are likely.");
        }
        objc_autoreleasePoolInvalid(token);

        if (willTerminate)
            _objc_fatal("Invalid autorelease pools are a fatal error");
    }

    template<bool allowDebug>
    static void
    popPage(void *token, AutoreleasePoolPage *page, id *stop)
    {
        if (allowDebug && PrintPoolHiwat) printHiwat();

        page->releaseUntil(stop);

        // memory: delete empty children
        if (allowDebug && DebugPoolAllocation  &&  page->empty()) {
            // special case: delete everything during page-per-pool debugging
            AutoreleasePoolPage *parent = page->parent;
            page->kill();
            setHotPage(parent);
        } else if (allowDebug && DebugMissingPools  &&  page->empty()  &&  !page->parent) {
            // special case: delete everything for pop(top)
            // when debugging missing autorelease pools
            page->kill();
            setHotPage(nil);
        } else if (page->child) {
            // hysteresis: keep one empty child if page is more than half full
            if (page->lessThanHalfFull()) {
                page->child->kill();
            }
            else if (page->child->child) {
                page->child->child->kill();
            }
        }
    }

    __attribute__((noinline, cold))
    static void
    popPageDebug(void *token, AutoreleasePoolPage *page, id *stop)
    {
        popPage<true>(token, page, stop);
    }

    static inline void
    pop(void *token)
    {
        // dtrace probe
        OBJC_RUNTIME_AUTORELEASE_POOL_POP(token);

        // We may have an object in the ReturnAutorelease TLS when the pool is
        // otherwise empty. Release that first before checking for an empty pool
        // so we don't return prematurely. Loop in case the release placed a new
        // object in the TLS.
        while (releaseReturnAutoreleaseTLS())
            ;

        AutoreleasePoolPage *page;
        id *stop;
        if (token == (void*)EMPTY_POOL_PLACEHOLDER) {
            // Popping the top-level placeholder pool.
            page = hotPage();
            if (!page) {
                // Pool was never used. Clear the placeholder.
                return setHotPage(nil);
            }
            // Pool was used. Pop its contents normally.
            // Pool pages remain allocated for re-use as usual.
            page = coldPage();
            token = page->begin();
        } else {
            page = pageForPointer(token);
        }

        stop = (id *)token;
        if (*stop != POOL_BOUNDARY) {
            if (stop == page->begin()  &&  !page->parent) {
                // Start of coldest page may correctly not be POOL_BOUNDARY:
                // 1. top-level pool is popped, leaving the cold page in place
                // 2. an object is autoreleased with no pool
            } else {
                // Error. For bincompat purposes this is not 
                // fatal in executables built with old SDKs.
                return badPop(token);
            }
        }

        if (slowpath(PrintPoolHiwat || DebugPoolAllocation || DebugMissingPools)) {
            return popPageDebug(token, page, stop);
        }

        return popPage<false>(token, page, stop);
    }

    __attribute__((noinline, cold))
    void print()
    {
        _objc_inform("[%p]  ................  PAGE %s %s %s", this, 
                     full() ? "(full)" : "", 
                     this == hotPage() ? "(hot)" : "", 
                     this == coldPage() ? "(cold)" : "");
        check(false);
        for (id *p = begin(); p < next; p++) {
            if (*p == POOL_BOUNDARY) {
                _objc_inform("[%p]  ################  POOL %p", p, p);
            } else {
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
                AutoreleasePoolEntry *entry = (AutoreleasePoolEntry *)p;
                if (entry->count > 0) {
                    id obj = (id)entry->ptr;
                    _objc_inform("[%p]  %#16lx  %s  autorelease count %u",
                                 p, (unsigned long)obj, object_getClassName(obj),
                                 entry->count + 1);
                    goto done;
                }
#endif
                _objc_inform("[%p]  %#16lx  %s",
                             p, (unsigned long)*p, object_getClassName(*p));
             done:;
            }
        }
    }

    __attribute__((noinline, cold))
    static void printAll()
    {
        _objc_inform("##############");
        _objc_inform("AUTORELEASE POOLS for thread %p", objc_thread_self());

        AutoreleasePoolPage *page;
        ptrdiff_t objects = 0;
        for (page = coldPage(); page; page = page->child) {
            objects += page->next - page->begin();
        }
        _objc_inform("%llu releases pending.", (unsigned long long)objects);

        if (haveEmptyPoolPlaceholder()) {
            _objc_inform("[%p]  ................  PAGE (placeholder)", 
                         EMPTY_POOL_PLACEHOLDER);
            _objc_inform("[%p]  ################  POOL (placeholder)", 
                         EMPTY_POOL_PLACEHOLDER);
        }
        else {
            for (page = coldPage(); page; page = page->child) {
                page->print();
            }
        }

        _objc_inform("##############");
    }

#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
    __attribute__((noinline, cold))
    unsigned sumOfExtraReleases()
    {
        unsigned sumOfExtraReleases = 0;
        for (id *p = begin(); p < next; p++) {
            if (*p != POOL_BOUNDARY) {
                sumOfExtraReleases += ((AutoreleasePoolEntry *)p)->count;
            }
        }
        return sumOfExtraReleases;
    }
#endif

    __attribute__((noinline, cold))
    static void printHiwat()
    {
        // Check and propagate high water mark
        // Ignore high water marks under 256 to suppress noise.
        AutoreleasePoolPage *p = hotPage();
        uint32_t mark = p->depth*COUNT + (uint32_t)(p->next - p->begin());
        if (mark > p->hiwat + 256) {
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
            unsigned sumOfExtraReleases = 0;
#endif
            for( ; p; p = p->parent) {
                p->unprotect();
                p->hiwat = mark;
                p->protect();
                
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
                sumOfExtraReleases += p->sumOfExtraReleases();
#endif
            }

            _objc_inform("POOL HIGHWATER: new high water mark of %u "
                         "pending releases for thread %p:",
                         mark, objc_thread_self());
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
            if (sumOfExtraReleases > 0) {
                _objc_inform("POOL HIGHWATER: extra sequential autoreleases of objects: %u",
                             sumOfExtraReleases);
            }
#endif

#if !TARGET_OS_EXCLAVEKIT
            void *stack[128];
            int count = backtrace(stack, sizeof(stack)/sizeof(stack[0]));
            char **sym = backtrace_symbols(stack, count);
            for (int i = 0; i < count; i++) {
                _objc_inform("POOL HIGHWATER:     %s", sym[i]);
            }
            free(sym);
#endif
        }
    }

#undef POOL_BOUNDARY

    friend struct ReturnAutoreleaseInfo::TlsDealloc;
};

void ReturnAutoreleaseInfo::TlsDealloc::operator()(uintptr_t firstWord) {
    // Release the object in the TLS. Loop in case it autoreleases something
    // else into the TLS. Once that loop completes, there may be more objects
    // in the actual autorelease pool. These will be taken care of by
    // tls_dealloc.

    // Launder the pointer through ReturnAutoreleaseInfo to handle any
    // encoding it does.
    ReturnAutoreleaseInfo info;
    info.firstWord = firstWord;
    objc_release(info.getReturnedObject());

    // Clean up any additional objects that may have been put in.
    while (AutoreleasePoolPage::releaseReturnAutoreleaseTLS())
        ;
}

class AutoreleasePoolPage::HotPageDealloc {
public:
    void operator()(AutoreleasePoolPage *p) {
        // We may have an object in the ReturnAutorelease TLS when the pool is
        // otherwise empty. Release that first before checking for an empty pool
        // so we don't return prematurely. Loop in case the release placed a new
        // object in the TLS.
        while (releaseReturnAutoreleaseTLS())
            ;

        if (p == EMPTY_POOL_PLACEHOLDER) {
            // No objects or pool pages to clean up here.
            return;
        }

        // reinstate TLS value while we work
        setHotPage((AutoreleasePoolPage *)p);

        if (AutoreleasePoolPage *page = coldPage()) {
            if (!page->empty()) objc_autoreleasePoolPop(page->begin());  // pop all of the pools
            if (slowpath(DebugMissingPools || DebugPoolAllocation)) {
                // pop() killed the pages already
            } else {
                page->kill();  // free all of the pages
            }
        }

        // clear TLS value so TLS destruction doesn't loop
        setHotPage(nil);
    }
};

tls_direct(AutoreleasePoolPage *, tls_key::autorelease_pool,
           AutoreleasePoolPage::HotPageDealloc) AutoreleasePoolPage::hotPage_;

/***********************************************************************
* Slow paths for inline control
**********************************************************************/

#if SUPPORT_NONPOINTER_ISA

NEVER_INLINE id 
objc_object::rootRetain_overflow(bool tryRetain)
{
    return rootRetain(tryRetain, RRVariant::Full);
}


NEVER_INLINE uintptr_t
objc_object::rootRelease_underflow(bool performDealloc)
{
    return rootRelease(performDealloc, RRVariant::Full);
}


// Slow path of clearDeallocating() 
// for objects with nonpointer isa
// that were ever weakly referenced 
// or whose retain count ever overflowed to the side table.
NEVER_INLINE void
objc_object::clearDeallocating_slow()
{
    ASSERT(isa().nonpointer  &&  (isa().weakly_referenced
#if ISA_HAS_INLINE_RC
                                  || isa().has_sidetable_rc
#endif
                                  ));

    SideTable& table = SideTables()[this];
    table.lock();
    if (isa().weakly_referenced) {
        weak_clear_no_lock(&table.weak_table, (id)this);
    }
#if ISA_HAS_INLINE_RC
    if (isa().has_sidetable_rc) {
#endif
        table.refcnts.erase(this);
#if ISA_HAS_INLINE_RC
    }
#endif
    table.unlock();
}

#endif

void moveTLSAutoreleaseToPool(ReturnAutoreleaseInfo info) {
    AutoreleasePoolPage::moveTLSAutoreleaseToPool(info);
}

__attribute__((noinline,used))
id 
objc_object::rootAutorelease2()
{
    ASSERT(!isTaggedPointer());
    return AutoreleasePoolPage::autorelease((id)this);
}


/***********************************************************************
* Retain count operations for side table.
**********************************************************************/


#if DEBUG
// Used to assert that an object is not present in the side table.
bool
objc_object::sidetable_present() const
{
    bool result = false;
    SideTable& table = SideTables()[this];

    table.lock();

    RefcountMap::iterator it = table.refcnts.find(this);
    if (it != table.refcnts.end()) result = true;

    if (weak_is_registered_no_lock(&table.weak_table, (id)this)) result = true;

    table.unlock();

    return result;
}
#endif

void
objc_object::performDealloc()
{
    if (ISA()->hasCustomDeallocInitiation())
        ((void(*)(objc_object *, SEL))objc_msgSend)(this, @selector(_objc_initiateDealloc));
    else
        ((void(*)(objc_object *, SEL))objc_msgSend)(this, @selector(dealloc));
}


#if SUPPORT_NONPOINTER_ISA

void 
objc_object::sidetable_lock() const
{
    SideTable& table = SideTables()[this];
    table.lock();
}

void 
objc_object::sidetable_unlock() const
{
    SideTable& table = SideTables()[this];
    table.unlock();
}


// Move the entire retain count to the side table, 
// as well as isDeallocating and weaklyReferenced.
void 
objc_object::sidetable_moveExtraRC_nolock(size_t extra_rc, 
                                          bool isDeallocating, 
                                          bool weaklyReferenced)
{
    ASSERT(!isa().nonpointer);        // should already be changed to raw pointer
    SideTable& table = SideTables()[this];

    size_t& refcntStorage = table.refcnts[this];
    size_t oldRefcnt = refcntStorage;
    // not deallocating - that was in the isa
    ASSERT((oldRefcnt & SIDE_TABLE_DEALLOCATING) == 0);  
    ASSERT((oldRefcnt & SIDE_TABLE_WEAKLY_REFERENCED) == 0);  

    uintptr_t carry;
    size_t refcnt = addc(oldRefcnt, (extra_rc - 1) << SIDE_TABLE_RC_SHIFT, 0, &carry);
    if (carry) refcnt = SIDE_TABLE_RC_PINNED;
    if (isDeallocating) refcnt |= SIDE_TABLE_DEALLOCATING;
    if (weaklyReferenced) refcnt |= SIDE_TABLE_WEAKLY_REFERENCED;

    refcntStorage = refcnt;
}


// Move some retain counts to the side table from the isa field.
// Returns true if the object is now pinned.
bool 
objc_object::sidetable_addExtraRC_nolock(size_t delta_rc)
{
    ASSERT(isa().nonpointer);
    SideTable& table = SideTables()[this];

    size_t& refcntStorage = table.refcnts[this];
    size_t oldRefcnt = refcntStorage;
    // isa-side bits should not be set here
    ASSERT((oldRefcnt & SIDE_TABLE_DEALLOCATING) == 0);
    ASSERT((oldRefcnt & SIDE_TABLE_WEAKLY_REFERENCED) == 0);

    if (oldRefcnt & SIDE_TABLE_RC_PINNED) return true;

    uintptr_t carry;
    size_t newRefcnt = 
        addc(oldRefcnt, delta_rc << SIDE_TABLE_RC_SHIFT, 0, &carry);
    if (carry) {
        refcntStorage =
            SIDE_TABLE_RC_PINNED | (oldRefcnt & SIDE_TABLE_FLAG_MASK);
        return true;
    }
    else {
        refcntStorage = newRefcnt;
        return false;
    }
}


// Move some retain counts from the side table to the isa field.
// Returns the actual count subtracted, which may be less than the request.
objc_object::SidetableBorrow
objc_object::sidetable_subExtraRC_nolock(size_t delta_rc)
{
    ASSERT(isa().nonpointer);
    SideTable& table = SideTables()[this];

    RefcountMap::iterator it = table.refcnts.find(this);
    if (it == table.refcnts.end()  ||  it->second == 0) {
        // Side table retain count is zero. Can't borrow.
        return { 0, 0 };
    }
    size_t oldRefcnt = it->second;

    // isa-side bits should not be set here
    ASSERT((oldRefcnt & SIDE_TABLE_DEALLOCATING) == 0);
    ASSERT((oldRefcnt & SIDE_TABLE_WEAKLY_REFERENCED) == 0);

    size_t newRefcnt = oldRefcnt - (delta_rc << SIDE_TABLE_RC_SHIFT);
    ASSERT(oldRefcnt > newRefcnt);  // shouldn't underflow
    it->second = newRefcnt;
    return { delta_rc, newRefcnt >> SIDE_TABLE_RC_SHIFT };
}


size_t 
objc_object::sidetable_getExtraRC_nolock() const
{
    ASSERT(isa().nonpointer);
    SideTable& table = SideTables()[this];
    RefcountMap::iterator it = table.refcnts.find(this);
    if (it == table.refcnts.end()) return 0;
    else return it->second >> SIDE_TABLE_RC_SHIFT;
}


void
objc_object::sidetable_clearExtraRC_nolock()
{
    ASSERT(isa().nonpointer);
    SideTable& table = SideTables()[this];
    RefcountMap::iterator it = table.refcnts.find(this);
    table.refcnts.erase(it);
}


// SUPPORT_NONPOINTER_ISA
#endif


id
objc_object::sidetable_retain(bool locked)
{
#if SUPPORT_NONPOINTER_ISA
    ASSERT(!isa().nonpointer);
#endif
    SideTable& table = SideTables()[this];
    
    if (!locked) table.lock();
    size_t& refcntStorage = table.refcnts[this];
    if (! (refcntStorage & SIDE_TABLE_RC_PINNED)) {
        refcntStorage += SIDE_TABLE_RC_ONE;
    }
    table.unlock();

    return (id)this;
}


bool
objc_object::sidetable_tryRetain()
{
#if SUPPORT_NONPOINTER_ISA
    ASSERT(!isa().nonpointer);
#endif
    SideTable& table = SideTables()[this];

    // NO SPINLOCK HERE
    // _objc_rootTryRetain() is called exclusively by _objc_loadWeak(), 
    // which already acquired the lock on our behalf.

    // fixme can't do this efficiently with os_lock_handoff_s
    // if (table.slock == 0) {
    //     _objc_fatal("Do not call -_tryRetain.");
    // }

    bool result = true;
    auto it = table.refcnts.try_emplace(this, SIDE_TABLE_RC_ONE);
    auto &refcnt = it.first->second;
    if (it.second) {
        // there was no entry
    } else if (refcnt & SIDE_TABLE_DEALLOCATING) {
        result = false;
    } else if (! (refcnt & SIDE_TABLE_RC_PINNED)) {
        refcnt += SIDE_TABLE_RC_ONE;
    }
    
    return result;
}


uintptr_t
objc_object::sidetable_retainCount() const
{
    SideTable& table = SideTables()[this];

    size_t refcnt_result = 1;
    
    table.lock();
    RefcountMap::iterator it = table.refcnts.find(this);
    if (it != table.refcnts.end()) {
        // this is valid for SIDE_TABLE_RC_PINNED too
        refcnt_result += it->second >> SIDE_TABLE_RC_SHIFT;
    }
    table.unlock();
    return refcnt_result;
}


bool 
objc_object::sidetable_isDeallocating() const
{
    SideTable& table = SideTables()[this];

    // NO SPINLOCK HERE
    // _objc_rootIsDeallocating() is called exclusively by _objc_storeWeak(), 
    // which already acquired the lock on our behalf.


    // fixme can't do this efficiently with os_lock_handoff_s
    // if (table.slock == 0) {
    //     _objc_fatal("Do not call -_isDeallocating.");
    // }

    RefcountMap::iterator it = table.refcnts.find(this);
    return (it != table.refcnts.end()) && (it->second & SIDE_TABLE_DEALLOCATING);
}


bool 
objc_object::sidetable_isWeaklyReferenced() const
{
    bool result = false;

    SideTable& table = SideTables()[this];
    table.lock();

    RefcountMap::iterator it = table.refcnts.find(this);
    if (it != table.refcnts.end()) {
        result = it->second & SIDE_TABLE_WEAKLY_REFERENCED;
    }

    table.unlock();

    return result;
}

#if OBJC_WEAK_FORMATION_CALLOUT_DEFINED
//Clients can dlsym() for this symbol to see if an ObjC supporting
//-_setWeaklyReferenced is present
OBJC_EXPORT const uintptr_t _objc_has_weak_formation_callout = 0;
static_assert(SUPPORT_NONPOINTER_ISA, "Weak formation callout must only be defined when nonpointer isa is supported.");
#else
static_assert(!SUPPORT_NONPOINTER_ISA, "If weak callout is not present then we must not support nonpointer isas.");
#endif

void 
objc_object::sidetable_setWeaklyReferenced_nolock()
{
#if SUPPORT_NONPOINTER_ISA
    ASSERT(!isa().nonpointer);
#endif
  
    SideTable& table = SideTables()[this];
  
    table.refcnts[this] |= SIDE_TABLE_WEAKLY_REFERENCED;
}


// rdar://20206767
// return uintptr_t instead of bool so that the various raw-isa 
// -release paths all return zero in eax
uintptr_t
objc_object::sidetable_release(bool locked, bool performDealloc)
{
#if SUPPORT_NONPOINTER_ISA
    ASSERT(!isa().nonpointer);
#endif
    SideTable& table = SideTables()[this];

    bool do_dealloc = false;

    if (!locked) table.lock();
    auto it = table.refcnts.try_emplace(this, SIDE_TABLE_DEALLOCATING);
    auto &refcnt = it.first->second;
    if (it.second) {
        do_dealloc = true;
    } else if (refcnt < SIDE_TABLE_DEALLOCATING) {
        // SIDE_TABLE_WEAKLY_REFERENCED may be set. Don't change it.
        do_dealloc = true;
        refcnt |= SIDE_TABLE_DEALLOCATING;
    } else if (! (refcnt & SIDE_TABLE_RC_PINNED)) {
        refcnt -= SIDE_TABLE_RC_ONE;
    }
    table.unlock();
    if (do_dealloc  &&  performDealloc) {
        this->performDealloc();
    }
    return do_dealloc;
}


void 
objc_object::sidetable_clearDeallocating()
{
    SideTable& table = SideTables()[this];

    // clear any weak table items
    // clear extra retain count and deallocating bit
    // (fixme warn or abort if extra retain count == 0 ?)
    table.lock();
    RefcountMap::iterator it = table.refcnts.find(this);
    if (it != table.refcnts.end()) {
        if (it->second & SIDE_TABLE_WEAKLY_REFERENCED) {
            weak_clear_no_lock(&table.weak_table, (id)this);
        }
        table.refcnts.erase(it);
    }
    table.unlock();
}


/***********************************************************************
* Optimized retain/release/autorelease entrypoints
**********************************************************************/

#if ISA_HAS_INLINE_RC && !SUPPORT_INDEXED_ISA && __arm64__
// On ARM64 with nonpointer isa, objc_retain/release are provided by
// retain-release-helpers-arm64.s. We still need the C implementation for
// various slow paths. Expose those with _full suffixes.

extern "C" id objc_retain_full(id obj)
{
    // The assembly implementation has already performed the tagged-or-nil check.
    ASSERT(!_objc_isTaggedPointerOrNil(obj));
    return obj->retain();
}

extern "C" void objc_release_full(id obj)
{
    // The assembly implementation has already performed the tagged-or-nil check.
    ASSERT(!_objc_isTaggedPointerOrNil(obj));
    obj->release();
}

#else

__attribute__((always_inline))
static id _Nullable _objc_retain(id _Nullable obj) {
    if (_objc_isTaggedPointerOrNil(obj)) return obj;
    return obj->retain();
}

__attribute__((aligned(16), flatten, noinline))
id
objc_retain(id obj)
{
    return _objc_retain(obj);
}

__attribute__((always_inline))
static void _objc_release(id _Nullable obj) {
    if (_objc_isTaggedPointerOrNil(obj)) return;
    return obj->release();
}

__attribute__((aligned(16), flatten, noinline))
void
objc_release(id obj)
{
    return _objc_release(obj);
}

#if __arm64__
void
objc_release_x0(id obj)
{
    return _objc_release(obj);
}

id
objc_retain_x0(id obj)
{
    return _objc_retain(obj);
}
#endif

#endif

__attribute__((aligned(16), flatten, noinline))
id
objc_autorelease(id obj)
{
    if (_objc_isTaggedPointerOrNil(obj)) return obj;
    return obj->autorelease();
}


__attribute__((aligned(16), flatten, noinline))
bool
objc_isUniquelyReferenced(id obj)
{
    if (_objc_isTaggedPointerOrNil(obj)) return false;
    return obj->isUniquelyReferenced();
}


/***********************************************************************
* Basic operations for root class implementations a.k.a. _objc_root*()
**********************************************************************/

bool
_objc_rootTryRetain(id obj) 
{
    ASSERT(obj);

    return obj->rootTryRetain();
}

bool
_objc_rootIsDeallocating(id obj) 
{
    ASSERT(obj);

    return obj->rootIsDeallocating();
}


void 
objc_clear_deallocating(id obj) 
{
    ASSERT(obj);

    if (obj->isTaggedPointer()) return;
    obj->clearDeallocating();
}


bool
_objc_rootReleaseWasZero(id obj)
{
    ASSERT(obj);

    return obj->rootReleaseShouldDealloc();
}


NEVER_INLINE id
_objc_rootAutorelease(id obj)
{
    ASSERT(obj);
    return obj->rootAutorelease();
}

uintptr_t
_objc_rootRetainCount(id obj)
{
    ASSERT(obj);

    return obj->rootRetainCount();
}


NEVER_INLINE id
_objc_rootRetain(id obj)
{
    ASSERT(obj);

    return obj->rootRetain();
}

NEVER_INLINE void
_objc_rootRelease(id obj)
{
    ASSERT(obj);

    obj->rootRelease();
}

// Call [cls alloc] or [cls allocWithZone:nil], with appropriate
// shortcutting optimizations.
static ALWAYS_INLINE id
callAlloc(Class cls, bool checkNil, bool allocWithZone=false)
{
    if (slowpath(checkNil && !cls)) return nil;
    if (fastpath(!cls->ISA()->hasCustomAWZ())) {
        return _objc_rootAllocWithZone(cls, nil);
    }

    // No shortcuts available.
    if (allocWithZone) {
        return ((id(*)(id, SEL, struct _NSZone *))objc_msgSend)(cls, @selector(allocWithZone:), nil);
    }
    return ((id(*)(id, SEL))objc_msgSend)(cls, @selector(alloc));
}


// Base class implementation of +alloc. cls is not nil.
// Calls [cls allocWithZone:nil].
id
_objc_rootAlloc(Class cls)
{
    return callAlloc(cls, false/*checkNil*/, true/*allocWithZone*/);
}

// Calls [cls alloc].
id
objc_alloc(Class cls)
{
    return callAlloc(cls, true/*checkNil*/, false/*allocWithZone*/);
}

// Calls [cls allocWithZone:nil].
id
objc_allocWithZone(Class cls)
{
    return callAlloc(cls, true/*checkNil*/, true/*allocWithZone*/);
}

// Calls [[cls alloc] init].
id
objc_alloc_init(Class cls)
{
    return [callAlloc(cls, true/*checkNil*/, false/*allocWithZone*/) init];
}

// Calls [cls new]
id
objc_opt_new(Class cls)
{
    if (fastpath(cls && !cls->ISA()->hasCustomCore())) {
        return [callAlloc(cls, false/*checkNil*/) init];
    }

    return ((id(*)(id, SEL))objc_msgSend)(cls, @selector(new));
}

// Calls [obj self]
id
objc_opt_self(id obj)
{
    if (fastpath(_objc_isTaggedPointerOrNil(obj) || !obj->ISA()->hasCustomCore())) {
        return obj;
    }

    return ((id(*)(id, SEL))objc_msgSend)(obj, @selector(self));
}

// Calls [obj class]
Class
objc_opt_class(id obj)
{
    if (slowpath(!obj)) return nil;
    Class cls = obj->getIsa();
    if (fastpath(!cls->hasCustomCore())) {
        return cls->isMetaClass() ? obj : cls;
    }

    return ((Class(*)(id, SEL))objc_msgSend)(obj, @selector(class));
}

// Calls [obj isKindOfClass]
BOOL
objc_opt_isKindOfClass(id obj, Class otherClass)
{
    if (slowpath(!obj)) return NO;
    Class cls = obj->getIsa();
    if (fastpath(!cls->hasCustomCore())) {
        for (Class tcls = cls; tcls; tcls = tcls->getSuperclass()) {
            if (tcls == otherClass) return YES;
        }
        return NO;
    }

    return ((BOOL(*)(id, SEL, Class))objc_msgSend)(obj, @selector(isKindOfClass:), otherClass);
}

// Calls [obj respondsToSelector]
BOOL
objc_opt_respondsToSelector(id obj, SEL sel)
{
    if (slowpath(!obj)) return NO;
    Class cls = obj->getIsa();
    if (fastpath(!cls->hasCustomCore())) {
        return class_respondsToSelector_inst(obj, sel, cls);
    }

    return ((BOOL(*)(id, SEL, SEL))objc_msgSend)(obj, @selector(respondsToSelector:), sel);
}

void
_objc_rootDealloc(id obj)
{
    ASSERT(obj);

    obj->rootDealloc();
}

void
_objc_rootFinalize(id obj __unused)
{
    ASSERT(obj);
    _objc_fatal("_objc_rootFinalize called with garbage collection off");
}


id
_objc_rootInit(id obj)
{
    // In practice, it will be hard to rely on this function.
    // Many classes do not properly chain -init calls.
    return obj;
}


objc_zone_t
_objc_rootZone(id obj)
{
    (void)obj;
    // allocWithZone under __OBJC2__ ignores the zone parameter
#if SUPPORT_ZONES
    return malloc_default_zone();
#else
    return nullptr;
#endif
}

uintptr_t
_objc_rootHash(id obj)
{
    return (uintptr_t)obj;
}

void *
objc_autoreleasePoolPush(void)
{
    return AutoreleasePoolPage::push();
}

NEVER_INLINE
void
objc_autoreleasePoolPop(void *ctxt)
{
    AutoreleasePoolPage::pop(ctxt);
}


void *
_objc_autoreleasePoolPush(void)
{
    return objc_autoreleasePoolPush();
}

void
_objc_autoreleasePoolPop(void *ctxt)
{
    objc_autoreleasePoolPop(ctxt);
}

void 
_objc_autoreleasePoolPrint(void)
{
    AutoreleasePoolPage::printAll();
}


// Same as objc_release but suitable for tail-calling 
// if you need the value back and don't want to push a frame before this point.
__attribute__((noinline))
static id 
objc_releaseAndReturn(id obj)
{
    objc_release(obj);
    return obj;
}

// Same as objc_retainAutorelease but suitable for tail-calling 
// if you don't want to push a frame before this point.
__attribute__((noinline))
static id 
objc_retainAutoreleaseAndReturn(id obj)
{
    return objc_retainAutorelease(obj);
}


// Prepare a value at +1 for return through a +0 autoreleasing convention.
id 
objc_autoreleaseReturnValue(id obj)
{
    if (prepareOptimizedReturn(obj, false, ReturnAtPlus1)) return obj;

    return objc_autorelease(obj);
}

// Prepare a value at +0 for return through a +0 autoreleasing convention.
id 
objc_retainAutoreleaseReturnValue(id obj)
{
    // With return-address autorelease elision, we still need to retain the
    // object when prepare succeeds, because the claim side of the handoff
    // may not actually happen.
#if HAS_RETURNADDR_AUTORELEASE_ELISION
    if (prepareOptimizedReturn(obj, false, ReturnAtPlus1)) return objc_retain(obj);
#else
    if (prepareOptimizedReturn(obj, false, ReturnAtPlus0)) return obj;
#endif

    // not objc_autoreleaseReturnValue(objc_retain(obj)) 
    // because we don't need another optimization attempt
    return objc_retainAutoreleaseAndReturn(obj);
}

// Accept a value returned through a +0 autoreleasing convention for use at +1.
id
objc_retainAutoreleasedReturnValue(id obj)
{
    if (acceptOptimizedReturn(/*expectsNop*/true) == ReturnAtPlus1) return obj;

    return objc_retain(obj);
}

// Accept a value returned through a +0 autoreleasing convention for use at +1,
// without a NOP in the caller on ARM64.
id
objc_claimAutoreleasedReturnValue(id obj)
{
    if (acceptOptimizedReturn(/*expectsNop*/false) == ReturnAtPlus1) return obj;

    return objc_retain(obj);
}

// Accept a value returned through a +0 autoreleasing convention for use at +0.
id
objc_unsafeClaimAutoreleasedReturnValue(id obj)
{
    if (acceptOptimizedReturn(/*expectsNop*/true) == ReturnAtPlus1)
        return objc_releaseAndReturn(obj);

    return obj;
}

id
objc_retainAutorelease(id obj)
{
    return objc_autorelease(objc_retain(obj));
}

void
_objc_deallocOnMainThreadHelper(void *context)
{
    id obj = (id)context;
    [obj dealloc];
}

// convert objc_objectptr_t to id, callee must take ownership.
id objc_retainedObject(objc_objectptr_t pointer) { return (id)pointer; }

// convert objc_objectptr_t to id, without ownership transfer.
id objc_unretainedObject(objc_objectptr_t pointer) { return (id)pointer; }

// convert id to objc_objectptr_t, no ownership transfer.
objc_objectptr_t objc_unretainedPointer(id object) { return object; }

#if !TARGET_OS_EXCLAVEKIT
static void *weakTableScan(void *) {
    pthread_setname_np("ObjC weak reference scanner");

    struct timespec sleepInterval = { 0, 1000000 };
    char *intervalStr = getenv("OBJC_DEBUG_SCAN_WEAK_TABLES_INTERVAL_NANOSECONDS");
    if (intervalStr) {
        unsigned long long nanos = strtoull(intervalStr, NULL, 10);
        sleepInterval.tv_nsec = nanos % 1000000000;
        sleepInterval.tv_sec = nanos / 1000000000;
    }

    auto &tables = SideTables();
    while (true) {
        tables.forEach([&](SideTable &table) {
            nanosleep(&sleepInterval, NULL);

            table.lock();

            auto mask = table.weak_table.mask;
            if (mask) {
                for (uintptr_t i = 0; i <= mask; i++) {
                    auto &entry = table.weak_table.weak_entries[i];
                    auto *referrers = entry.out_of_line() ? entry.referrers : entry.inline_referrers;
                    uintptr_t count = entry.out_of_line() ? entry.mask + 1 : WEAK_INLINE_COUNT;
                    objc_object *referent = entry.referent;
                    if (!referent) continue;

                    for (uintptr_t j = 0; j < count; j++) {
                        objc_object **referrer = referrers[j];
                        if (!referrer) continue;

                        objc_object *currentValue = *referrer;
                        if (referent != currentValue)
                            _objc_fatal("Weak reference at %p contains %p, should contain %p", referrer, currentValue, referent);
                    }
                }
            }
            table.unlock();
        });
    }
}

static void startWeakTableScan() {
    _objc_inform("Starting background scan of weak references.");
    pthread_t thread;
    int ret = pthread_create(&thread, nullptr, weakTableScan, nullptr);
    if (ret != 0)
        _objc_fatal("pthread_create failed with error %d (%s)", ret, strerror(ret));
    pthread_detach(thread);
}
#endif

void arr_init(void) 
{
    SideTablesMap.init();
    _objc_associations_init();

#if !TARGET_OS_EXCLAVEKIT
    if (DebugScanWeakTables)
        startWeakTableScan();
#endif
}


#if SUPPORT_TAGGED_POINTERS

// Placeholder for old debuggers. When they inspect an 
// extended tagged pointer object they will see this isa.

@interface __NSUnrecognizedTaggedPointer : NSObject
@end

__attribute__((objc_nonlazy_class))
@implementation __NSUnrecognizedTaggedPointer
-(id) retain { return self; }
-(oneway void) release { }
-(id) autorelease { return self; }
@end

#endif

__attribute__((objc_nonlazy_class))
@implementation NSObject

+ (void)initialize {
}

+ (id)self {
    return (id)self;
}

- (id)self {
    return self;
}

+ (Class)class {
    return self;
}

- (Class)class {
    return object_getClass(self);
}

+ (Class)superclass {
    return self->getSuperclass();
}

- (Class)superclass {
    return [self class]->getSuperclass();
}

+ (BOOL)isMemberOfClass:(Class)cls {
    return self->ISA() == cls;
}

- (BOOL)isMemberOfClass:(Class)cls {
    return [self class] == cls;
}

+ (BOOL)isKindOfClass:(Class)cls {
    for (Class tcls = self->ISA(); tcls; tcls = tcls->getSuperclass()) {
        if (tcls == cls) return YES;
    }
    return NO;
}

- (BOOL)isKindOfClass:(Class)cls {
    for (Class tcls = [self class]; tcls; tcls = tcls->getSuperclass()) {
        if (tcls == cls) return YES;
    }
    return NO;
}

+ (BOOL)isSubclassOfClass:(Class)cls {
    for (Class tcls = self; tcls; tcls = tcls->getSuperclass()) {
        if (tcls == cls) return YES;
    }
    return NO;
}

+ (BOOL)isAncestorOfObject:(NSObject *)obj {
    for (Class tcls = [obj class]; tcls; tcls = tcls->getSuperclass()) {
        if (tcls == self) return YES;
    }
    return NO;
}

+ (BOOL)instancesRespondToSelector:(SEL)sel {
    return class_respondsToSelector_inst(nil, sel, self);
}

+ (BOOL)respondsToSelector:(SEL)sel {
    return class_respondsToSelector_inst(self, sel, self->ISA());
}

- (BOOL)respondsToSelector:(SEL)sel {
    return class_respondsToSelector_inst(self, sel, [self class]);
}

+ (BOOL)conformsToProtocol:(Protocol *)protocol {
    if (!protocol) return NO;
    for (Class tcls = self; tcls; tcls = tcls->getSuperclass()) {
        if (class_conformsToProtocol(tcls, protocol)) return YES;
    }
    return NO;
}

- (BOOL)conformsToProtocol:(Protocol *)protocol {
    if (!protocol) return NO;
    for (Class tcls = [self class]; tcls; tcls = tcls->getSuperclass()) {
        if (class_conformsToProtocol(tcls, protocol)) return YES;
    }
    return NO;
}

+ (NSUInteger)hash {
    return _objc_rootHash(self);
}

- (NSUInteger)hash {
    return _objc_rootHash(self);
}

+ (BOOL)isEqual:(id)obj {
    return obj == (id)self;
}

- (BOOL)isEqual:(id)obj {
    return obj == self;
}


+ (BOOL)isFault {
    return NO;
}

- (BOOL)isFault {
    return NO;
}

+ (BOOL)isProxy {
    return NO;
}

- (BOOL)isProxy {
    return NO;
}


+ (IMP)instanceMethodForSelector:(SEL)sel {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return class_getMethodImplementation(self, sel);
}

+ (IMP)methodForSelector:(SEL)sel {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return object_getMethodImplementation((id)self, sel);
}

- (IMP)methodForSelector:(SEL)sel {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return object_getMethodImplementation(self, sel);
}

+ (BOOL)resolveClassMethod:(SEL)sel {
    return NO;
}

+ (BOOL)resolveInstanceMethod:(SEL)sel {
    return NO;
}

// Replaced by CF (throws an NSException)
+ (void)doesNotRecognizeSelector:(SEL)sel {
    _objc_fatal("+[%s %s]: unrecognized selector sent to instance %p", 
                class_getName(self), sel_getName(sel), self);
}

// Replaced by CF (throws an NSException)
- (void)doesNotRecognizeSelector:(SEL)sel {
    _objc_fatal("-[%s %s]: unrecognized selector sent to instance %p", 
                object_getClassName(self), sel_getName(sel), self);
}


+ (id)performSelector:(SEL)sel {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return ((id(*)(id, SEL))objc_msgSend)((id)self, sel);
}

+ (id)performSelector:(SEL)sel withObject:(id)obj {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return ((id(*)(id, SEL, id))objc_msgSend)((id)self, sel, obj);
}

+ (id)performSelector:(SEL)sel withObject:(id)obj1 withObject:(id)obj2 {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return ((id(*)(id, SEL, id, id))objc_msgSend)((id)self, sel, obj1, obj2);
}

- (id)performSelector:(SEL)sel {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return ((id(*)(id, SEL))objc_msgSend)(self, sel);
}

- (id)performSelector:(SEL)sel withObject:(id)obj {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return ((id(*)(id, SEL, id))objc_msgSend)(self, sel, obj);
}

- (id)performSelector:(SEL)sel withObject:(id)obj1 withObject:(id)obj2 {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return ((id(*)(id, SEL, id, id))objc_msgSend)(self, sel, obj1, obj2);
}


// Replaced by CF (returns an NSMethodSignature)
+ (NSMethodSignature *)instanceMethodSignatureForSelector:(SEL)sel {
    _objc_fatal("+[NSObject instanceMethodSignatureForSelector:] "
                "not available without CoreFoundation");
}

// Replaced by CF (returns an NSMethodSignature)
+ (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    _objc_fatal("+[NSObject methodSignatureForSelector:] "
                "not available without CoreFoundation");
}

// Replaced by CF (returns an NSMethodSignature)
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    _objc_fatal("-[NSObject methodSignatureForSelector:] "
                "not available without CoreFoundation");
}

+ (void)forwardInvocation:(NSInvocation *)invocation {
    [self doesNotRecognizeSelector:(invocation ? [invocation selector] : 0)];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    [self doesNotRecognizeSelector:(invocation ? [invocation selector] : 0)];
}

+ (id)forwardingTargetForSelector:(SEL)sel {
    return nil;
}

- (id)forwardingTargetForSelector:(SEL)sel {
    return nil;
}


// Replaced by CF (returns an NSString)
+ (NSString *)description {
    return nil;
}

// Replaced by CF (returns an NSString)
- (NSString *)description {
    return nil;
}

+ (NSString *)debugDescription {
    return [self description];
}

- (NSString *)debugDescription {
    return [self description];
}


+ (id)new {
    return [callAlloc(self, false/*checkNil*/) init];
}

+ (id)retain {
    return (id)self;
}

// Replaced by ObjectAlloc
- (id)retain {
    return _objc_rootRetain(self);
}


+ (BOOL)_tryRetain {
    return YES;
}

// Replaced by ObjectAlloc
- (BOOL)_tryRetain {
    return _objc_rootTryRetain(self);
}

+ (BOOL)_isDeallocating {
    return NO;
}

- (BOOL)_isDeallocating {
    return _objc_rootIsDeallocating(self);
}

+ (BOOL)allowsWeakReference { 
    return YES; 
}

+ (BOOL)retainWeakReference {
    return YES; 
}

- (BOOL)allowsWeakReference { 
    return ! [self _isDeallocating]; 
}

- (BOOL)retainWeakReference { 
    return [self _tryRetain]; 
}

+ (oneway void)release {
}

// Replaced by ObjectAlloc
- (oneway void)release {
    _objc_rootRelease(self);
}

+ (id)autorelease {
    return (id)self;
}

// Replaced by ObjectAlloc
- (id)autorelease {
    return _objc_rootAutorelease(self);
}

+ (NSUInteger)retainCount {
    return ULONG_MAX;
}

- (NSUInteger)retainCount {
    return _objc_rootRetainCount(self);
}

+ (id)alloc {
    return _objc_rootAlloc(self);
}

// Replaced by ObjectAlloc
+ (id)allocWithZone:(struct _NSZone *)zone {
    return _objc_rootAllocWithZone(self, (objc_zone_t)zone);
}

// Replaced by CF (throws an NSException)
+ (id)init {
    return (id)self;
}

- (id)init {
    return _objc_rootInit(self);
}

// Replaced by CF (throws an NSException)
+ (void)dealloc {
}


// Replaced by NSZombies
- (void)dealloc {
    _objc_rootDealloc(self);
}

// Previously used by GC. Now a placeholder for binary compatibility.
- (void) finalize {
}

+ (struct _NSZone *)zone {
    return (struct _NSZone *)_objc_rootZone(self);
}

- (struct _NSZone *)zone {
    return (struct _NSZone *)_objc_rootZone(self);
}

+ (id)copy {
    return (id)self;
}

+ (id)copyWithZone:(struct _NSZone *)zone {
    return (id)self;
}

- (id)copy {
    return [(id)self copyWithZone:nil];
}

+ (id)mutableCopy {
    return (id)self;
}

+ (id)mutableCopyWithZone:(struct _NSZone *)zone {
    return (id)self;
}

- (id)mutableCopy {
    return [(id)self mutableCopyWithZone:nil];
}

@end


