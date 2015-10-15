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
#include "llvm-DenseMap.h"
#include "NSObject.h"

#include <malloc/malloc.h>
#include <stdint.h>
#include <stdbool.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <libkern/OSAtomic.h>
#include <Block.h>
#include <map>
#include <execinfo.h>

@interface NSInvocation
- (SEL)selector;
@end


#if TARGET_OS_MAC

// NSObject used to be in Foundation/CoreFoundation.

#define SYMBOL_ELSEWHERE_IN_3(sym, vers, n)                             \
    OBJC_EXPORT const char elsewhere_ ##n __asm__("$ld$hide$os" #vers "$" #sym); const char elsewhere_ ##n = 0
#define SYMBOL_ELSEWHERE_IN_2(sym, vers, n)     \
    SYMBOL_ELSEWHERE_IN_3(sym, vers, n)
#define SYMBOL_ELSEWHERE_IN(sym, vers)                  \
    SYMBOL_ELSEWHERE_IN_2(sym, vers, __COUNTER__)

#if __OBJC2__
# define NSOBJECT_ELSEWHERE_IN(vers)                       \
    SYMBOL_ELSEWHERE_IN(_OBJC_CLASS_$_NSObject, vers);     \
    SYMBOL_ELSEWHERE_IN(_OBJC_METACLASS_$_NSObject, vers); \
    SYMBOL_ELSEWHERE_IN(_OBJC_IVAR_$_NSObject.isa, vers)
#else
# define NSOBJECT_ELSEWHERE_IN(vers)                       \
    SYMBOL_ELSEWHERE_IN(.objc_class_name_NSObject, vers)
#endif

#if TARGET_OS_IPHONE
    NSOBJECT_ELSEWHERE_IN(5.1);
    NSOBJECT_ELSEWHERE_IN(5.0);
    NSOBJECT_ELSEWHERE_IN(4.3);
    NSOBJECT_ELSEWHERE_IN(4.2);
    NSOBJECT_ELSEWHERE_IN(4.1);
    NSOBJECT_ELSEWHERE_IN(4.0);
    NSOBJECT_ELSEWHERE_IN(3.2);
    NSOBJECT_ELSEWHERE_IN(3.1);
    NSOBJECT_ELSEWHERE_IN(3.0);
    NSOBJECT_ELSEWHERE_IN(2.2);
    NSOBJECT_ELSEWHERE_IN(2.1);
    NSOBJECT_ELSEWHERE_IN(2.0);
#else
    NSOBJECT_ELSEWHERE_IN(10.7);
    NSOBJECT_ELSEWHERE_IN(10.6);
    NSOBJECT_ELSEWHERE_IN(10.5);
    NSOBJECT_ELSEWHERE_IN(10.4);
    NSOBJECT_ELSEWHERE_IN(10.3);
    NSOBJECT_ELSEWHERE_IN(10.2);
    NSOBJECT_ELSEWHERE_IN(10.1);
    NSOBJECT_ELSEWHERE_IN(10.0);
#endif

// TARGET_OS_MAC
#endif


/***********************************************************************
* Weak ivar support
**********************************************************************/

static id defaultBadAllocHandler(Class cls)
{
    _objc_fatal("attempt to allocate object of class '%s' failed", 
                cls->nameForLogging());
}

static id(*badAllocHandler)(Class) = &defaultBadAllocHandler;

static id callBadAllocHandler(Class cls)
{
    // fixme add re-entrancy protection in case allocation fails inside handler
    return (*badAllocHandler)(cls);
}

void _objc_setBadAllocHandler(id(*newHandler)(Class))
{
    badAllocHandler = newHandler;
}


namespace {

#if TARGET_OS_EMBEDDED
#   define SIDE_TABLE_STRIPE 8
#else
#   define SIDE_TABLE_STRIPE 64
#endif

// should be a multiple of cache line size (64)
#define SIDE_TABLE_SIZE 128

// The order of these bits is important.
#define SIDE_TABLE_WEAKLY_REFERENCED (1UL<<0)
#define SIDE_TABLE_DEALLOCATING      (1UL<<1)  // MSB-ward of weak bit
#define SIDE_TABLE_RC_ONE            (1UL<<2)  // MSB-ward of deallocating bit
#define SIDE_TABLE_RC_PINNED         (1UL<<(WORD_BITS-1))

#define SIDE_TABLE_RC_SHIFT 2
#define SIDE_TABLE_FLAG_MASK (SIDE_TABLE_RC_ONE-1)

// RefcountMap disguises its pointers because we 
// don't want the table to act as a root for `leaks`.
typedef objc::DenseMap<DisguisedPtr<objc_object>,size_t,true> RefcountMap;

class SideTable {
private:
    static uint8_t table_buf[SIDE_TABLE_STRIPE * SIDE_TABLE_SIZE];

public:
    spinlock_t slock;
    RefcountMap refcnts;
    weak_table_t weak_table;

    SideTable() : slock(SPINLOCK_INITIALIZER)
    {
        memset(&weak_table, 0, sizeof(weak_table));
    }
    
    ~SideTable() 
    {
        // never delete side_table in case other threads retain during exit
        assert(0);
    }

    static SideTable *tableForPointer(const void *p) 
    {
#     if SIDE_TABLE_STRIPE == 1
        return (SideTable *)table_buf;
#     else
        uintptr_t a = (uintptr_t)p;
        int index = ((a >> 4) ^ (a >> 9)) & (SIDE_TABLE_STRIPE - 1);
        return (SideTable *)&table_buf[index * SIDE_TABLE_SIZE];
#     endif
    }

    static void init() {
        // use placement new instead of static ctor to avoid dtor at exit
        for (int i = 0; i < SIDE_TABLE_STRIPE; i++) {
            new (&table_buf[i * SIDE_TABLE_SIZE]) SideTable;
        }
    }
};

STATIC_ASSERT(sizeof(SideTable) <= SIDE_TABLE_SIZE);
__attribute__((aligned(SIDE_TABLE_SIZE))) uint8_t 
SideTable::table_buf[SIDE_TABLE_STRIPE * SIDE_TABLE_SIZE];

// anonymous namespace
};


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
    id oldObj;
    SideTable *oldTable;
    SideTable *newTable;
    spinlock_t *lock1;
#if SIDE_TABLE_STRIPE > 1
    spinlock_t *lock2;
#endif

    // Acquire locks for old and new values.
    // Order by lock address to prevent lock ordering problems. 
    // Retry if the old value changes underneath us.
 retry:
    oldObj = *location;
    
    oldTable = SideTable::tableForPointer(oldObj);
    newTable = SideTable::tableForPointer(newObj);
    
    lock1 = &newTable->slock;
#if SIDE_TABLE_STRIPE > 1
    lock2 = &oldTable->slock;
    if (lock1 > lock2) {
        spinlock_t *temp = lock1;
        lock1 = lock2;
        lock2 = temp;
    }
    if (lock1 != lock2) spinlock_lock(lock2);
#endif
    spinlock_lock(lock1);

    if (*location != oldObj) {
        spinlock_unlock(lock1);
#if SIDE_TABLE_STRIPE > 1
        if (lock1 != lock2) spinlock_unlock(lock2);
#endif
        goto retry;
    }

    weak_unregister_no_lock(&oldTable->weak_table, oldObj, location);
    newObj = weak_register_no_lock(&newTable->weak_table, newObj, location);
    // weak_register_no_lock returns nil if weak store should be rejected

    // Set is-weakly-referenced bit in refcount table.
    if (newObj  &&  !newObj->isTaggedPointer()) {
        newObj->setWeaklyReferenced_nolock();
    }

    // Do not set *location anywhere else. That would introduce a race.
    *location = newObj;
    
    spinlock_unlock(lock1);
#if SIDE_TABLE_STRIPE > 1
    if (lock1 != lock2) spinlock_unlock(lock2);
#endif

    return newObj;
}

id
objc_storeWeakOrNil(id *location, id newObj) {
    id oldObj;
    SideTable *oldTable;
    SideTable *newTable;
    spinlock_t *lock1;
#if SIDE_TABLE_STRIPE > 1
    spinlock_t *lock2;
#endif
    
    // Acquire locks for old and new values.
    // Order by lock address to prevent lock ordering problems.
    // Retry if the old value changes underneath us.
retry:
    oldObj = *location;
    
    oldTable = SideTable::tableForPointer(oldObj);
    newTable = SideTable::tableForPointer(newObj);
    
    lock1 = &newTable->slock;
#if SIDE_TABLE_STRIPE > 1
    lock2 = &oldTable->slock;
    if (lock1 > lock2) {
        spinlock_t *temp = lock1;
        lock1 = lock2;
        lock2 = temp;
    }
    if (lock1 != lock2) spinlock_lock(lock2);
#endif
    spinlock_lock(lock1);
    
    if (*location != oldObj) {
        spinlock_unlock(lock1);
#if SIDE_TABLE_STRIPE > 1
        if (lock1 != lock2) spinlock_unlock(lock2);
#endif
        goto retry;
    }
    
    weak_unregister_no_lock(&oldTable->weak_table, oldObj, location);
    newObj = weak_register_no_lock(&newTable->weak_table, newObj, location);
    // weak_register_no_lock returns nil if weak store should be rejected
    
    // Set is-weakly-referenced bit in refcount table.
    if (newObj  &&  !newObj->isTaggedPointer()) {
        newObj->setWeaklyReferenced_nolock();
    }
    
    // Do not set *location anywhere else. That would introduce a race.
    *location = newObj;
    
    spinlock_unlock(lock1);
#if SIDE_TABLE_STRIPE > 1
    if (lock1 != lock2) spinlock_unlock(lock2);
#endif
    
    return newObj;
}

id
objc_loadWeakRetained(id *location)
{
    id result;

    SideTable *table;
    spinlock_t *lock;
    
 retry:
    result = *location;
    if (!result) return nil;
    
    table = SideTable::tableForPointer(result);
    lock = &table->slock;
    
    spinlock_lock(lock);
    if (*location != result) {
        spinlock_unlock(lock);
        goto retry;
    }

    result = weak_read_no_lock(&table->weak_table, location);

    spinlock_unlock(lock);
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
 * Initialize a fresh weak pointer to some object location. 
 * It would be used for code like: 
 *
 * (The nil case) 
 * __weak id weakPtr;
 * (The non-nil case) 
 * NSObject *o = ...;
 * __weak id weakPtr = o;
 * 
 * @param addr Address of __weak ptr. 
 * @param val Object ptr. 
 */
id
objc_initWeak(id *addr, id val)
{
    *addr = 0;
    if (!val) return nil;
    return objc_storeWeak(addr, val);
}

__attribute__((noinline, used)) void
objc_destroyWeak_slow(id *addr)
{
    SideTable *oldTable;
    spinlock_t *lock;
    id oldObj;

    // No need to see weak refs, we are destroying
    
    // Acquire lock for old value only
    // retry if the old value changes underneath us
 retry: 
    oldObj = *addr;
    oldTable = SideTable::tableForPointer(oldObj);
    
    lock = &oldTable->slock;
    spinlock_lock(lock);
    
    if (*addr != oldObj) {
        spinlock_unlock(lock);
        goto retry;
    }

    weak_unregister_no_lock(&oldTable->weak_table, oldObj, addr);
    
    spinlock_unlock(lock);
}

/** 
 * Destroys the relationship between a weak pointer
 * and the object it is referencing in the internal weak
 * table. If the weak pointer is not referencing anything, 
 * there is no need to edit the weak table. 
 * 
 * @param addr The weak pointer address. 
 */
void
objc_destroyWeak(id *addr)
{
    if (!*addr) return;
    return objc_destroyWeak_slow(addr);
}

/** 
 * This function copies a weak pointer from one location to another,
 * when the destination doesn't already contain a weak pointer. It
 * would be used for code like:
 *
 *  __weak id weakPtr1 = ...;
 *  __weak id weakPtr2 = weakPtr1;
 * 
 * @param to weakPtr2 in this ex
 * @param from weakPtr1
 */
void
objc_copyWeak(id *to, id *from)
{
    id val = objc_loadWeakRetained(from);
    objc_initWeak(to, val);
    objc_release(val);
}

/** 
 * Move a weak pointer from one location to another.
 * Before the move, the destination must be uninitialized.
 * After the move, the source is nil.
 */
void
objc_moveWeak(id *to, id *from)
{
    objc_copyWeak(to, from);
    objc_storeWeak(from, 0);
}


/***********************************************************************
   Autorelease pool implementation

   A thread's autorelease pool is a stack of pointers. 
   Each pointer is either an object to release, or POOL_SENTINEL which is 
     an autorelease pool boundary.
   A pool token is a pointer to the POOL_SENTINEL for that pool. When 
     the pool is popped, every object hotter than the sentinel is released.
   The stack is divided into a doubly-linked list of pages. Pages are added 
     and deleted as necessary. 
   Thread-local storage points to the hot page, where newly autoreleased 
     objects are stored. 
**********************************************************************/

BREAKPOINT_FUNCTION(void objc_autoreleaseNoPool(id obj));

namespace {

struct magic_t {
    static const uint32_t M0 = 0xA1A1A1A1;
#   define M1 "AUTORELEASE!"
    static const size_t M1_len = 12;
    uint32_t m[4];
    
    magic_t() {
        assert(M1_len == strlen(M1));
        assert(M1_len == 3 * sizeof(m[1]));

        m[0] = M0;
        strncpy((char *)&m[1], M1, M1_len);
    }

    ~magic_t() {
        m[0] = m[1] = m[2] = m[3] = 0;
    }

    bool check() const {
        return (m[0] == M0 && 0 == strncmp((char *)&m[1], M1, M1_len));
    }

    bool fastcheck() const {
#ifdef NDEBUG
        return (m[0] == M0);
#else
        return check();
#endif
    }

#   undef M1
};
    

// Set this to 1 to mprotect() autorelease pool contents
#define PROTECT_AUTORELEASEPOOL 0

class AutoreleasePoolPage 
{

#define POOL_SENTINEL nil
    static pthread_key_t const key = AUTORELEASE_POOL_KEY;
    static uint8_t const SCRIBBLE = 0xA3;  // 0xA3A3A3A3 after releasing
    static size_t const SIZE = 
#if PROTECT_AUTORELEASEPOOL
        PAGE_MAX_SIZE;  // must be multiple of vm page size
#else
        PAGE_MAX_SIZE;  // size and alignment, power of 2
#endif
    static size_t const COUNT = SIZE / sizeof(id);

    magic_t const magic;
    id *next;
    pthread_t const thread;
    AutoreleasePoolPage * const parent;
    AutoreleasePoolPage *child;
    uint32_t const depth;
    uint32_t hiwat;

    // SIZE-sizeof(*this) bytes of contents follow

    static void * operator new(size_t size) {
        return malloc_zone_memalign(malloc_default_zone(), SIZE, SIZE);
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

    AutoreleasePoolPage(AutoreleasePoolPage *newParent) 
        : magic(), next(begin()), thread(pthread_self()),
          parent(newParent), child(nil), 
          depth(parent ? 1+parent->depth : 0), 
          hiwat(parent ? parent->hiwat : 0)
    { 
        if (parent) {
            parent->check();
            assert(!parent->child);
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
        assert(empty());

        // Not recursive: we don't want to blow out the stack 
        // if a thread accumulates a stupendous amount of garbage
        assert(!child);
    }


    void busted(bool die = true) 
    {
        magic_t right;
        (die ? _objc_fatal : _objc_inform)
            ("autorelease pool page %p corrupted\n"
             "  magic     0x%08x 0x%08x 0x%08x 0x%08x\n"
             "  should be 0x%08x 0x%08x 0x%08x 0x%08x\n"
             "  pthread   %p\n"
             "  should be %p\n", 
             this, 
             magic.m[0], magic.m[1], magic.m[2], magic.m[3], 
             right.m[0], right.m[1], right.m[2], right.m[3], 
             this->thread, pthread_self());
    }

    void check(bool die = true) 
    {
        if (!magic.check() || !pthread_equal(thread, pthread_self())) {
            busted(die);
        }
    }

    void fastcheck(bool die = true) 
    {
        if (! magic.fastcheck()) {
            busted(die);
        }
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
        assert(!full());
        unprotect();
        id *ret = next;  // faster than `return next-1` because of aliasing
        *next++ = obj;
        protect();
        return ret;
    }

    void releaseAll() 
    {
        releaseUntil(begin());
    }

    void releaseUntil(id *stop) 
    {
        // Not recursive: we don't want to blow out the stack 
        // if a thread accumulates a stupendous amount of garbage
        
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
            id obj = *--page->next;
            memset((void*)page->next, SCRIBBLE, sizeof(*page->next));
            page->protect();

            if (obj != POOL_SENTINEL) {
                objc_release(obj);
            }
        }

        setHotPage(this);

#ifndef NDEBUG
        // we expect any children to be completely empty
        for (AutoreleasePoolPage *page = child; page; page = page->child) {
            assert(page->empty());
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
            delete deathptr;
        } while (deathptr != this);
    }

    static void tls_dealloc(void *p) 
    {
        // reinstate TLS value while we work
        setHotPage((AutoreleasePoolPage *)p);
        pop(0);
        setHotPage(nil);
    }

    static AutoreleasePoolPage *pageForPointer(const void *p) 
    {
        return pageForPointer((uintptr_t)p);
    }

    static AutoreleasePoolPage *pageForPointer(uintptr_t p) 
    {
        AutoreleasePoolPage *result;
        uintptr_t offset = p % SIZE;

        assert(offset >= sizeof(AutoreleasePoolPage));

        result = (AutoreleasePoolPage *)(p - offset);
        result->fastcheck();

        return result;
    }


    static inline AutoreleasePoolPage *hotPage() 
    {
        AutoreleasePoolPage *result = (AutoreleasePoolPage *)
            tls_get_direct(key);
        if (result) result->fastcheck();
        return result;
    }

    static inline void setHotPage(AutoreleasePoolPage *page) 
    {
        if (page) page->fastcheck();
        tls_set_direct(key, (void *)page);
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
        assert(page == hotPage()  &&  page->full());

        do {
            if (page->child) page = page->child;
            else page = new AutoreleasePoolPage(page);
        } while (page->full());

        setHotPage(page);
        return page->add(obj);
    }

    static __attribute__((noinline))
    id *autoreleaseNoPage(id obj)
    {
        // No pool in place.
        assert(!hotPage());

        if (obj != POOL_SENTINEL  &&  DebugMissingPools) {
            // We are pushing an object with no pool in place, 
            // and no-pool debugging was requested by environment.
            _objc_inform("MISSING POOLS: Object %p of class %s "
                         "autoreleased with no pool in place - "
                         "just leaking - break on "
                         "objc_autoreleaseNoPool() to debug", 
                         (void*)obj, object_getClassName(obj));
            objc_autoreleaseNoPool(obj);
            return nil;
        }

        // Install the first page.
        AutoreleasePoolPage *page = new AutoreleasePoolPage(nil);
        setHotPage(page);

        // Push an autorelease pool boundary if it wasn't already requested.
        if (obj != POOL_SENTINEL) {
            page->add(POOL_SENTINEL);
        }

        // Push the requested object.
        return page->add(obj);
    }

public:
    static inline id autorelease(id obj)
    {
        assert(obj);
        assert(!obj->isTaggedPointer());
        id *dest __unused = autoreleaseFast(obj);
        assert(!dest  ||  *dest == obj);
        return obj;
    }


    static inline void *push() 
    {
        id *dest = autoreleaseFast(POOL_SENTINEL);
        assert(*dest == POOL_SENTINEL);
        return dest;
    }

    static inline void pop(void *token) 
    {
        AutoreleasePoolPage *page;
        id *stop;

        if (token) {
            page = pageForPointer(token);
            stop = (id *)token;
            assert(*stop == POOL_SENTINEL);
        } else {
            // Token 0 is top-level pool
            page = coldPage();
            assert(page);
            stop = page->begin();
        }

        if (PrintPoolHiwat) printHiwat();

        page->releaseUntil(stop);

        // memory: delete empty children
        // hysteresis: keep one empty child if this page is more than half full
        // special case: delete everything for pop(0)
        // special case: delete everything for pop(top) with DebugMissingPools
        if (!token  ||  
            (DebugMissingPools  &&  page->empty()  &&  !page->parent)) 
        {
            page->kill();
            setHotPage(nil);
        } else if (page->child) {
            if (page->lessThanHalfFull()) {
                page->child->kill();
            }
            else if (page->child->child) {
                page->child->child->kill();
            }
        }
    }

    static void init()
    {
        int r __unused = pthread_key_init_np(AutoreleasePoolPage::key, 
                                             AutoreleasePoolPage::tls_dealloc);
        assert(r == 0);
    }

    void print() 
    {
        _objc_inform("[%p]  ................  PAGE %s %s %s", this, 
                     full() ? "(full)" : "", 
                     this == hotPage() ? "(hot)" : "", 
                     this == coldPage() ? "(cold)" : "");
        check(false);
        for (id *p = begin(); p < next; p++) {
            if (*p == POOL_SENTINEL) {
                _objc_inform("[%p]  ################  POOL %p", p, p);
            } else {
                _objc_inform("[%p]  %#16lx  %s", 
                             p, (unsigned long)*p, object_getClassName(*p));
            }
        }
    }

    static void printAll()
    {        
        _objc_inform("##############");
        _objc_inform("AUTORELEASE POOLS for thread %p", pthread_self());

        AutoreleasePoolPage *page;
        ptrdiff_t objects = 0;
        for (page = coldPage(); page; page = page->child) {
            objects += page->next - page->begin();
        }
        _objc_inform("%llu releases pending.", (unsigned long long)objects);

        for (page = coldPage(); page; page = page->child) {
            page->print();
        }

        _objc_inform("##############");
    }

    static void printHiwat()
    {
        // Check and propagate high water mark
        // Ignore high water marks under 256 to suppress noise.
        AutoreleasePoolPage *p = hotPage();
        uint32_t mark = p->depth*COUNT + (uint32_t)(p->next - p->begin());
        if (mark > p->hiwat  &&  mark > 256) {
            for( ; p; p = p->parent) {
                p->unprotect();
                p->hiwat = mark;
                p->protect();
            }
            
            _objc_inform("POOL HIGHWATER: new high water mark of %u "
                         "pending autoreleases for thread %p:", 
                         mark, pthread_self());
            
            void *stack[128];
            int count = backtrace(stack, sizeof(stack)/sizeof(stack[0]));
            char **sym = backtrace_symbols(stack, count);
            for (int i = 0; i < count; i++) {
                _objc_inform("POOL HIGHWATER:     %s", sym[i]);
            }
            free(sym);
        }
    }

#undef POOL_SENTINEL
};

// anonymous namespace
};


/***********************************************************************
* Slow paths for inline control
**********************************************************************/

#if SUPPORT_NONPOINTER_ISA

NEVER_INLINE id 
objc_object::rootRetain_overflow(bool tryRetain)
{
    return rootRetain(tryRetain, true);
}


NEVER_INLINE bool 
objc_object::rootRelease_underflow(bool performDealloc)
{
    return rootRelease(performDealloc, true);
}


// Slow path of clearDeallocating() 
// for weakly-referenced objects with indexed isa
NEVER_INLINE void
objc_object::clearDeallocating_weak()
{
    assert(isa.indexed  &&  isa.weakly_referenced);

    SideTable *table = SideTable::tableForPointer(this);
    spinlock_lock(&table->slock);
    weak_clear_no_lock(&table->weak_table, (id)this);
    spinlock_unlock(&table->slock);
}

#endif

__attribute__((noinline,used))
id 
objc_object::rootAutorelease2()
{
    assert(!isTaggedPointer());
    return AutoreleasePoolPage::autorelease((id)this);
}


BREAKPOINT_FUNCTION(
    void objc_overrelease_during_dealloc_error(void)
);


NEVER_INLINE
bool 
objc_object::overrelease_error()
{
    _objc_inform_now_and_on_crash("%s object %p overreleased while already deallocating; break on objc_overrelease_during_dealloc_error to debug", object_getClassName((id)this), this);
    objc_overrelease_during_dealloc_error();
    return false;  // allow rootRelease() to tail-call this
}


/***********************************************************************
* Retain count operations for side table.
**********************************************************************/


#if !NDEBUG
// Used to assert that an object is not present in the side table.
bool
objc_object::sidetable_present()
{
    bool result = false;
    SideTable *table = SideTable::tableForPointer(this);

    spinlock_lock(&table->slock);

    RefcountMap::iterator it = table->refcnts.find(this);
    if (it != table->refcnts.end()) result = true;

    if (weak_is_registered_no_lock(&table->weak_table, (id)this)) result = true;

    spinlock_unlock(&table->slock);

    return result;
}
#endif

#if SUPPORT_NONPOINTER_ISA

void 
objc_object::sidetable_lock()
{
    SideTable *table = SideTable::tableForPointer(this);
    spinlock_lock(&table->slock);
}

void 
objc_object::sidetable_unlock()
{
    SideTable *table = SideTable::tableForPointer(this);
    spinlock_unlock(&table->slock);
}


// Move the entire retain count to the side table, 
// as well as isDeallocating and weaklyReferenced.
void 
objc_object::sidetable_moveExtraRC_nolock(size_t extra_rc, 
                                          bool isDeallocating, 
                                          bool weaklyReferenced)
{
    assert(!isa.indexed);        // should already be changed to not-indexed
    SideTable *table = SideTable::tableForPointer(this);

    size_t& refcntStorage = table->refcnts[this];
    size_t oldRefcnt = refcntStorage;
    // not deallocating - that was in the isa
    assert((oldRefcnt & SIDE_TABLE_DEALLOCATING) == 0);  
    assert((oldRefcnt & SIDE_TABLE_WEAKLY_REFERENCED) == 0);  

    uintptr_t carry;
    size_t refcnt = addc(oldRefcnt, extra_rc<<SIDE_TABLE_RC_SHIFT, 0, &carry);
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
    assert(isa.indexed);
    SideTable *table = SideTable::tableForPointer(this);

    size_t& refcntStorage = table->refcnts[this];
    size_t oldRefcnt = refcntStorage;
    // not deallocating - that is in the isa
    assert((oldRefcnt & SIDE_TABLE_DEALLOCATING) == 0);  
    assert((oldRefcnt & SIDE_TABLE_WEAKLY_REFERENCED) == 0);  

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
// Returns true if the sidetable retain count is now 0.
bool 
objc_object::sidetable_subExtraRC_nolock(size_t delta_rc)
{
    assert(isa.indexed);
    SideTable *table = SideTable::tableForPointer(this);

    size_t& refcntStorage = table->refcnts[this];
    size_t oldRefcnt = refcntStorage;
    // not deallocating - that is in the isa
    assert((oldRefcnt & SIDE_TABLE_DEALLOCATING) == 0);  
    assert((oldRefcnt & SIDE_TABLE_WEAKLY_REFERENCED) == 0);  

    if (oldRefcnt < delta_rc) {
        _objc_inform_now_and_on_crash("refcount underflow error for object %p",
                                      this);
        _objc_fatal("refcount underflow error for %s %p", 
                    object_getClassName((id)this), this);
    }

    size_t newRefcnt = oldRefcnt - (delta_rc << SIDE_TABLE_RC_SHIFT);
    if (newRefcnt == 0) {
        table->refcnts.erase(this);
        return true;
    } 
    else {
        refcntStorage = newRefcnt;
        return false;
    }
}


size_t 
objc_object::sidetable_getExtraRC_nolock()
{
    assert(isa.indexed);
    SideTable *table = SideTable::tableForPointer(this);
    RefcountMap::iterator it = table->refcnts.find(this);
    assert(it != table->refcnts.end());
    return it->second >> SIDE_TABLE_RC_SHIFT;
}


// SUPPORT_NONPOINTER_ISA
#endif


__attribute__((used,noinline,nothrow))
id
objc_object::sidetable_retain_slow(SideTable *table)
{
#if SUPPORT_NONPOINTER_ISA
    assert(!isa.indexed);
#endif

    spinlock_lock(&table->slock);
    size_t& refcntStorage = table->refcnts[this];
    if (! (refcntStorage & SIDE_TABLE_RC_PINNED)) {
        refcntStorage += SIDE_TABLE_RC_ONE;
    }
    spinlock_unlock(&table->slock);

    return (id)this;
}


id
objc_object::sidetable_retain()
{
#if SUPPORT_NONPOINTER_ISA
    assert(!isa.indexed);
#endif
    SideTable *table = SideTable::tableForPointer(this);

    if (spinlock_trylock(&table->slock)) {
        size_t& refcntStorage = table->refcnts[this];
        if (! (refcntStorage & SIDE_TABLE_RC_PINNED)) {
            refcntStorage += SIDE_TABLE_RC_ONE;
        }
        spinlock_unlock(&table->slock);
        return (id)this;
    }
    return sidetable_retain_slow(table);
}


bool
objc_object::sidetable_tryRetain()
{
#if SUPPORT_NONPOINTER_ISA
    assert(!isa.indexed);
#endif
    SideTable *table = SideTable::tableForPointer(this);

    // NO SPINLOCK HERE
    // _objc_rootTryRetain() is called exclusively by _objc_loadWeak(), 
    // which already acquired the lock on our behalf.

    // fixme can't do this efficiently with os_lock_handoff_s
    // if (table->slock == 0) {
    //     _objc_fatal("Do not call -_tryRetain.");
    // }

    bool result = true;
    RefcountMap::iterator it = table->refcnts.find(this);
    if (it == table->refcnts.end()) {
        table->refcnts[this] = SIDE_TABLE_RC_ONE;
    } else if (it->second & SIDE_TABLE_DEALLOCATING) {
        result = false;
    } else if (! (it->second & SIDE_TABLE_RC_PINNED)) {
        it->second += SIDE_TABLE_RC_ONE;
    }
    
    return result;
}


uintptr_t
objc_object::sidetable_retainCount()
{
    SideTable *table = SideTable::tableForPointer(this);

    size_t refcnt_result = 1;
    
    spinlock_lock(&table->slock);
    RefcountMap::iterator it = table->refcnts.find(this);
    if (it != table->refcnts.end()) {
        // this is valid for SIDE_TABLE_RC_PINNED too
        refcnt_result += it->second >> SIDE_TABLE_RC_SHIFT;
    }
    spinlock_unlock(&table->slock);
    return refcnt_result;
}


bool 
objc_object::sidetable_isDeallocating()
{
    SideTable *table = SideTable::tableForPointer(this);

    // NO SPINLOCK HERE
    // _objc_rootIsDeallocating() is called exclusively by _objc_storeWeak(), 
    // which already acquired the lock on our behalf.


    // fixme can't do this efficiently with os_lock_handoff_s
    // if (table->slock == 0) {
    //     _objc_fatal("Do not call -_isDeallocating.");
    // }

    RefcountMap::iterator it = table->refcnts.find(this);
    return (it != table->refcnts.end()) && (it->second & SIDE_TABLE_DEALLOCATING);
}


bool 
objc_object::sidetable_isWeaklyReferenced()
{
    bool result = false;

    SideTable *table = SideTable::tableForPointer(this);
    spinlock_lock(&table->slock);

    RefcountMap::iterator it = table->refcnts.find(this);
    if (it != table->refcnts.end()) {
        result = it->second & SIDE_TABLE_WEAKLY_REFERENCED;
    }

    spinlock_unlock(&table->slock);

    return result;
}


void 
objc_object::sidetable_setWeaklyReferenced_nolock()
{
#if SUPPORT_NONPOINTER_ISA
    assert(!isa.indexed);
#endif

    SideTable *table = SideTable::tableForPointer(this);

    table->refcnts[this] |= SIDE_TABLE_WEAKLY_REFERENCED;
}


__attribute__((used,noinline,nothrow))
bool
objc_object::sidetable_release_slow(SideTable *table, bool performDealloc)
{
#if SUPPORT_NONPOINTER_ISA
    assert(!isa.indexed);
#endif
    bool do_dealloc = false;

    spinlock_lock(&table->slock);
    RefcountMap::iterator it = table->refcnts.find(this);
    if (it == table->refcnts.end()) {
        do_dealloc = true;
        table->refcnts[this] = SIDE_TABLE_DEALLOCATING;
    } else if (it->second < SIDE_TABLE_DEALLOCATING) {
        // SIDE_TABLE_WEAKLY_REFERENCED may be set. Don't change it.
        do_dealloc = true;
        it->second |= SIDE_TABLE_DEALLOCATING;
    } else if (! (it->second & SIDE_TABLE_RC_PINNED)) {
        it->second -= SIDE_TABLE_RC_ONE;
    }
    spinlock_unlock(&table->slock);
    if (do_dealloc  &&  performDealloc) {
        ((void(*)(objc_object *, SEL))objc_msgSend)(this, SEL_dealloc);
    }
    return do_dealloc;
}


bool 
objc_object::sidetable_release(bool performDealloc)
{
#if SUPPORT_NONPOINTER_ISA
    assert(!isa.indexed);
#endif
    SideTable *table = SideTable::tableForPointer(this);

    bool do_dealloc = false;

    if (spinlock_trylock(&table->slock)) {
        RefcountMap::iterator it = table->refcnts.find(this);
        if (it == table->refcnts.end()) {
            do_dealloc = true;
            table->refcnts[this] = SIDE_TABLE_DEALLOCATING;
        } else if (it->second < SIDE_TABLE_DEALLOCATING) {
            // SIDE_TABLE_WEAKLY_REFERENCED may be set. Don't change it.
            do_dealloc = true;
            it->second |= SIDE_TABLE_DEALLOCATING;
        } else if (! (it->second & SIDE_TABLE_RC_PINNED)) {
            it->second -= SIDE_TABLE_RC_ONE;
        }
        spinlock_unlock(&table->slock);
        if (do_dealloc  &&  performDealloc) {
            ((void(*)(objc_object *, SEL))objc_msgSend)(this, SEL_dealloc);
        }
        return do_dealloc;
    }

    return sidetable_release_slow(table, performDealloc);
}


void 
objc_object::sidetable_clearDeallocating()
{
    SideTable *table = SideTable::tableForPointer(this);

    // clear any weak table items
    // clear extra retain count and deallocating bit
    // (fixme warn or abort if extra retain count == 0 ?)
    spinlock_lock(&table->slock);
    RefcountMap::iterator it = table->refcnts.find(this);
    if (it != table->refcnts.end()) {
        if (it->second & SIDE_TABLE_WEAKLY_REFERENCED) {
            weak_clear_no_lock(&table->weak_table, (id)this);
        }
        table->refcnts.erase(it);
    }
    spinlock_unlock(&table->slock);
}


/***********************************************************************
* Optimized retain/release/autorelease entrypoints
**********************************************************************/


#if __OBJC2__

__attribute__((aligned(16)))
id 
objc_retain(id obj)
{
    if (!obj) return obj;
    if (obj->isTaggedPointer()) return obj;
    return obj->retain();
}


__attribute__((aligned(16)))
void 
objc_release(id obj)
{
    if (!obj) return;
    if (obj->isTaggedPointer()) return;
    return obj->release();
}


__attribute__((aligned(16)))
id
objc_autorelease(id obj)
{
    if (!obj) return obj;
    if (obj->isTaggedPointer()) return obj;
    return obj->autorelease();
}


// OBJC2
#else
// not OBJC2


id objc_retain(id obj) { return [obj retain]; }
void objc_release(id obj) { [obj release]; }
id objc_autorelease(id obj) { return [obj autorelease]; }


#endif


/***********************************************************************
* Basic operations for root class implementations a.k.a. _objc_root*()
**********************************************************************/

bool
_objc_rootTryRetain(id obj) 
{
    assert(obj);

    return obj->rootTryRetain();
}

bool
_objc_rootIsDeallocating(id obj) 
{
    assert(obj);

    return obj->rootIsDeallocating();
}


void 
objc_clear_deallocating(id obj) 
{
    assert(obj);
    assert(!UseGC);

    if (obj->isTaggedPointer()) return;
    obj->clearDeallocating();
}


bool
_objc_rootReleaseWasZero(id obj)
{
    assert(obj);

    return obj->rootReleaseShouldDealloc();
}


id
_objc_rootAutorelease(id obj)
{
    assert(obj);
    // assert(!UseGC);
    if (UseGC) return obj;  // fixme CF calls this when GC is on

    return obj->rootAutorelease();
}

uintptr_t
_objc_rootRetainCount(id obj)
{
    assert(obj);

    return obj->rootRetainCount();
}


id
_objc_rootRetain(id obj)
{
    assert(obj);

    return obj->rootRetain();
}

void
_objc_rootRelease(id obj)
{
    assert(obj);

    obj->rootRelease();
}


id
_objc_rootAllocWithZone(Class cls, malloc_zone_t *zone)
{
    id obj;

#if __OBJC2__
    // allocWithZone under __OBJC2__ ignores the zone parameter
    (void)zone;
    obj = class_createInstance(cls, 0);
#else
    if (!zone || UseGC) {
        obj = class_createInstance(cls, 0);
    }
    else {
        obj = class_createInstanceFromZone(cls, 0, zone);
    }
#endif

    if (!obj) obj = callBadAllocHandler(cls);
    return obj;
}


// Call [cls alloc] or [cls allocWithZone:nil], with appropriate 
// shortcutting optimizations.
static ALWAYS_INLINE id
callAlloc(Class cls, bool checkNil, bool allocWithZone=false)
{
    if (checkNil && !cls) return nil;

#if __OBJC2__
    if (! cls->ISA()->hasCustomAWZ()) {
        // No alloc/allocWithZone implementation. Go straight to the allocator.
        // fixme store hasCustomAWZ in the non-meta class and 
        // add it to canAllocFast's summary
        if (cls->canAllocFast()) {
            // No ctors, raw isa, etc. Go straight to the metal.
            bool dtor = cls->hasCxxDtor();
            id obj = (id)calloc(1, cls->bits.fastInstanceSize());
            if (!obj) return callBadAllocHandler(cls);
            obj->initInstanceIsa(cls, dtor);
            return obj;
        }
        else {
            // Has ctor or raw isa or something. Use the slower path.
            id obj = class_createInstance(cls, 0);
            if (!obj) return callBadAllocHandler(cls);
            return obj;
        }
    }
#endif

    // No shortcuts available.
    if (allocWithZone) return [cls allocWithZone:nil];
    return [cls alloc];
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


void
_objc_rootDealloc(id obj)
{
    assert(obj);

    obj->rootDealloc();
}

void
_objc_rootFinalize(id obj __unused)
{
    assert(obj);
    assert(UseGC);

    if (UseGC) {
        return;
    }
    _objc_fatal("_objc_rootFinalize called with garbage collection off");
}


id
_objc_rootInit(id obj)
{
    // In practice, it will be hard to rely on this function.
    // Many classes do not properly chain -init calls.
    return obj;
}


malloc_zone_t *
_objc_rootZone(id obj)
{
    (void)obj;
    if (gc_zone) {
        return gc_zone;
    }
#if __OBJC2__
    // allocWithZone under __OBJC2__ ignores the zone parameter
    return malloc_default_zone();
#else
    malloc_zone_t *rval = malloc_zone_from_ptr(obj);
    return rval ? rval : malloc_default_zone();
#endif
}

uintptr_t
_objc_rootHash(id obj)
{
    if (UseGC) {
        return _object_getExternalHash(obj);
    }
    return (uintptr_t)obj;
}

void *
objc_autoreleasePoolPush(void)
{
    if (UseGC) return nil;
    return AutoreleasePoolPage::push();
}

void
objc_autoreleasePoolPop(void *ctxt)
{
    if (UseGC) return;

    // fixme rdar://9167170
    if (!ctxt) return;

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
    if (UseGC) return;
    AutoreleasePoolPage::printAll();
}

id 
objc_autoreleaseReturnValue(id obj)
{
    if (fastAutoreleaseForReturn(obj)) return obj;

    return objc_autorelease(obj);
}

id 
objc_retainAutoreleaseReturnValue(id obj)
{
    return objc_autoreleaseReturnValue(objc_retain(obj));
}

id
objc_retainAutoreleasedReturnValue(id obj)
{
    if (fastRetainFromReturn(obj)) return obj;

    return objc_retain(obj);
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

#undef objc_retainedObject
#undef objc_unretainedObject
#undef objc_unretainedPointer

// convert objc_objectptr_t to id, callee must take ownership.
id objc_retainedObject(objc_objectptr_t pointer) { return (id)pointer; }

// convert objc_objectptr_t to id, without ownership transfer.
id objc_unretainedObject(objc_objectptr_t pointer) { return (id)pointer; }

// convert id to objc_objectptr_t, no ownership transfer.
objc_objectptr_t objc_unretainedPointer(id object) { return object; }


void arr_init(void) 
{
    AutoreleasePoolPage::init();
    SideTable::init();
}

@implementation NSObject

+ (void)load {
    if (UseGC) gc_init2();
}

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
    return self->superclass;
}

- (Class)superclass {
    return [self class]->superclass;
}

+ (BOOL)isMemberOfClass:(Class)cls {
    return object_getClass((id)self) == cls;
}

- (BOOL)isMemberOfClass:(Class)cls {
    return [self class] == cls;
}

+ (BOOL)isKindOfClass:(Class)cls {
    for (Class tcls = object_getClass((id)self); tcls; tcls = tcls->superclass) {
        if (tcls == cls) return YES;
    }
    return NO;
}

- (BOOL)isKindOfClass:(Class)cls {
    for (Class tcls = [self class]; tcls; tcls = tcls->superclass) {
        if (tcls == cls) return YES;
    }
    return NO;
}

+ (BOOL)isSubclassOfClass:(Class)cls {
    for (Class tcls = self; tcls; tcls = tcls->superclass) {
        if (tcls == cls) return YES;
    }
    return NO;
}

+ (BOOL)isAncestorOfObject:(NSObject *)obj {
    for (Class tcls = [obj class]; tcls; tcls = tcls->superclass) {
        if (tcls == self) return YES;
    }
    return NO;
}

+ (BOOL)instancesRespondToSelector:(SEL)sel {
    if (!sel) return NO;
    return class_respondsToSelector(self, sel);
}

+ (BOOL)respondsToSelector:(SEL)sel {
    if (!sel) return NO;
    return class_respondsToSelector_inst(object_getClass(self), sel, self);
}

- (BOOL)respondsToSelector:(SEL)sel {
    if (!sel) return NO;
    return class_respondsToSelector_inst([self class], sel, self);
}

+ (BOOL)conformsToProtocol:(Protocol *)protocol {
    if (!protocol) return NO;
    for (Class tcls = self; tcls; tcls = tcls->superclass) {
        if (class_conformsToProtocol(tcls, protocol)) return YES;
    }
    return NO;
}

- (BOOL)conformsToProtocol:(Protocol *)protocol {
    if (!protocol) return NO;
    for (Class tcls = [self class]; tcls; tcls = tcls->superclass) {
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
    return ((id)self)->rootRetain();
}


+ (BOOL)_tryRetain {
    return YES;
}

// Replaced by ObjectAlloc
- (BOOL)_tryRetain {
    return ((id)self)->rootTryRetain();
}

+ (BOOL)_isDeallocating {
    return NO;
}

- (BOOL)_isDeallocating {
    return ((id)self)->rootIsDeallocating();
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
    ((id)self)->rootRelease();
}

+ (id)autorelease {
    return (id)self;
}

// Replaced by ObjectAlloc
- (id)autorelease {
    return ((id)self)->rootAutorelease();
}

+ (NSUInteger)retainCount {
    return ULONG_MAX;
}

- (NSUInteger)retainCount {
    return ((id)self)->rootRetainCount();
}

+ (id)alloc {
    return _objc_rootAlloc(self);
}

// Replaced by ObjectAlloc
+ (id)allocWithZone:(struct _NSZone *)zone {
    return _objc_rootAllocWithZone(self, (malloc_zone_t *)zone);
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

// Replaced by CF (throws an NSException)
+ (void)finalize {
}

- (void)finalize {
    _objc_rootFinalize(self);
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


