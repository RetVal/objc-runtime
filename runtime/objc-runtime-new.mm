/*
 * Copyright (c) 2005-2009 Apple Inc.  All Rights Reserved.
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

/***********************************************************************
* objc-runtime-new.m
* Support for new-ABI classes and images.
**********************************************************************/

#include <cstdint>
#include "DenseMapExtras.h"
#include "llvm-MathExtras.h"
#include "objc-private.h"
#include "objc-malloc-instance.h"
#include "objc-runtime-new.h"
#include "objc-file.h"
#include "objc-probes.h"
#include "objc-zalloc.h"
#include <Block.h>
#include <objc/message.h>

#if !TARGET_OS_EXCLAVEKIT
#include <mach/shared_region.h>

extern "C" {
#include <os/bsd.h>
#include <os/reason_private.h>
#include <os/variant_private.h>
}
#endif // !TARGET_OS_EXCLAVEKIT

#define newprotocol(p) ((protocol_t *)p)

static void disableTaggedPointers();
static void detach_class(Class cls, bool isMeta);
static void free_class(Class cls);
static IMP addMethod(Class cls, SEL name, IMP imp, const char *types, bool replace);
static void adjustCustomFlagsForMethodChange(Class cls, method_t *meth);
static method_t *search_method_list(const method_list_t *mlist, SEL sel);
template<typename T> static bool method_lists_contains_any(T *mlists, T *end,
        SEL sels[], size_t selcount);
static void flushCaches(Class cls, const char *func, bool (^predicate)(Class c));
static void initializeTaggedPointerObfuscator(void);
#if SUPPORT_FIXUP
static void fixupMessageRef(message_ref_t *msg);
#endif
static Class realizeClassMaybeSwiftAndUnlock(Class cls, mutex_t& lock);
static Class readClass(Class cls, bool headerIsBundle, bool headerIsPreoptimized);

template<class EnumerateFunc>
static void enumerateSelectorsInMethodList(const method_list_t *list,
                                           const EnumerateFunc &fn);

struct locstamped_category_t {
    category_t *cat;
    struct header_info *hi;
};
enum {
    ATTACH_CLASS               = 1 << 0,
    ATTACH_METACLASS           = 1 << 1,
    ATTACH_CLASS_AND_METACLASS = 1 << 2,
    ATTACH_EXISTING            = 1 << 3,
};
static void attachCategories(Class cls, const struct locstamped_category_t *cats_list, uint32_t cats_count, int flags);


/***********************************************************************
* Lock management
**********************************************************************/
mutex_t runtimeLock;
mutex_t selLock;
#if CONFIG_USE_CACHE_LOCK
mutex_t cacheUpdateLock;
#endif
recursive_mutex_t loadMethodLock;

/***********************************************************************
* Class structure decoding
**********************************************************************/

const uintptr_t objc_debug_class_rw_data_mask = DEBUG_DATA_MASK;


/***********************************************************************
* Non-pointer isa decoding
**********************************************************************/
#if SUPPORT_INDEXED_ISA

// Indexed non-pointer isa.

// These are used to mask the ISA and see if its got an index or not.
const uintptr_t objc_debug_indexed_isa_magic_mask  = ISA_INDEX_MAGIC_MASK;
const uintptr_t objc_debug_indexed_isa_magic_value = ISA_INDEX_MAGIC_VALUE;

// die if masks overlap
STATIC_ASSERT((ISA_INDEX_MASK & ISA_INDEX_MAGIC_MASK) == 0);

// die if magic is wrong
STATIC_ASSERT((~ISA_INDEX_MAGIC_MASK & ISA_INDEX_MAGIC_VALUE) == 0);

// Then these are used to extract the index from the ISA.
const uintptr_t objc_debug_indexed_isa_index_mask  = ISA_INDEX_MASK;
const uintptr_t objc_debug_indexed_isa_index_shift  = ISA_INDEX_SHIFT;

asm("\n .globl _objc_absolute_indexed_isa_magic_mask"                   \
    "\n _objc_absolute_indexed_isa_magic_mask = " STRINGIFY2(ISA_INDEX_MAGIC_MASK));
asm("\n .globl _objc_absolute_indexed_isa_magic_value" \
    "\n _objc_absolute_indexed_isa_magic_value = " STRINGIFY2(ISA_INDEX_MAGIC_VALUE));
asm("\n .globl _objc_absolute_indexed_isa_index_mask"                   \
    "\n _objc_absolute_indexed_isa_index_mask = " STRINGIFY2(ISA_INDEX_MASK));
asm("\n .globl _objc_absolute_indexed_isa_index_shift" \
    "\n _objc_absolute_indexed_isa_index_shift = " STRINGIFY2(ISA_INDEX_SHIFT));


// And then we can use that index to get the class from this array.  Note
// the size is provided so that clients can ensure the index they get is in
// bounds and not read off the end of the array.
// Defined in the objc-msg-*.s files
// const Class objc_indexed_classes[]

// When we don't have enough bits to store a class*, we can instead store an
// index in to this array.  Classes are added here when they are realized.
// Note, an index of 0 is illegal.
uintptr_t objc_indexed_classes_count = 0;

// SUPPORT_INDEXED_ISA
#else
// not SUPPORT_INDEXED_ISA

// These variables exist but are all set to 0 so that they are ignored.
const uintptr_t objc_debug_indexed_isa_magic_mask  = 0;
const uintptr_t objc_debug_indexed_isa_magic_value = 0;
const uintptr_t objc_debug_indexed_isa_index_mask  = 0;
const uintptr_t objc_debug_indexed_isa_index_shift = 0;
Class objc_indexed_classes[1] = { nil };
uintptr_t objc_indexed_classes_count = 0;

// not SUPPORT_INDEXED_ISA
#endif


#if SUPPORT_PACKED_ISA

// Packed non-pointer isa.

asm("\n .globl _objc_absolute_packed_isa_class_mask" \
    "\n _objc_absolute_packed_isa_class_mask = " STRINGIFY2(ISA_MASK));

// a better definition is
//     (uintptr_t)ptrauth_strip((void *)ISA_MASK, ISA_SIGNING_KEY)
// however we know that PAC uses bits outside of MACH_VM_MAX_ADDRESS
// so approximate the definition here to be constant
template <typename T>
static constexpr T coveringMask(T n) {
    for (T mask = 0; mask != ~T{0}; mask = (mask << 1) | 1) {
        if ((n & mask) == n) return mask;
    }
    return ~T{0};
}
const uintptr_t objc_debug_isa_class_mask  = ISA_MASK & coveringMask(OBJC_VM_MAX_ADDRESS - 1);

const uintptr_t objc_debug_isa_magic_mask  = ISA_MAGIC_MASK;
const uintptr_t objc_debug_isa_magic_value = ISA_MAGIC_VALUE;

// die if masks overlap
STATIC_ASSERT((ISA_MASK & ISA_MAGIC_MASK) == 0);

// die if magic is wrong
STATIC_ASSERT((~ISA_MAGIC_MASK & ISA_MAGIC_VALUE) == 0);

// die if virtual address space bound goes up
STATIC_ASSERT((~ISA_MASK & OBJC_VM_MAX_ADDRESS) == 0  ||
              ISA_MASK + sizeof(void*) == OBJC_VM_MAX_ADDRESS);

// SUPPORT_PACKED_ISA
#else
// not SUPPORT_PACKED_ISA

// These variables exist but enforce pointer alignment only.
const uintptr_t objc_debug_isa_class_mask  = (~WORD_MASK);
const uintptr_t objc_debug_isa_magic_mask  = WORD_MASK;
const uintptr_t objc_debug_isa_magic_value = 0;

// not SUPPORT_PACKED_ISA
#endif

// We use a *signed* "pointer" to control enforcement.  It's signed so that
// an attacker can't just overwrite it with some random thing to turn off
// pointer authentication of the class_ro_t pointers.
//
// Note that this is *disable* rather than *enable* because NULL pointers
// are not signed, and we want to protect against it being turned off;
// enabling it increases security so an attacker is unlikely to want to
// do that.
namespace objc {
    uintptr_t ptrauth_class_rx_enforce disableEnforceClassRXPtrAuth;
}

/***********************************************************************
* Swift marker bits
**********************************************************************/
const uintptr_t objc_debug_swift_stable_abi_bit = FAST_IS_SWIFT_STABLE;


/***********************************************************************
* allocatedClasses
* A table of all classes (and metaclasses) which have been allocated
* with objc_allocateClassPair.
**********************************************************************/
namespace objc {
static ExplicitInitDenseSet<Class> allocatedClasses;
}

/***********************************************************************
* _firstRealizedClass
* The root of all realized classes
**********************************************************************/
static Class _firstRealizedClass = nil;

/***********************************************************************
* didInitialAttachCategories
* Whether the initial attachment of categories present at startup has
* been done.
**********************************************************************/
static bool didInitialAttachCategories = false;

/***********************************************************************
* didCallDyldNotifyRegister
* Whether the call to _dyld_objc_notify_register has completed.
**********************************************************************/
bool didCallDyldNotifyRegister = false;


/***********************************************************************
* smallMethodIMPMap
* The map from small method pointers to replacement IMPs.
*
* Locking: runtimeLock must be held when accessing this map.
**********************************************************************/
namespace objc {
    // The value type of smallMethodIMPMap is really IMP, but signed with a
    // custom discriminator and blended with the method_t* that it's associated
    // with. This securely ties the IMP in the table to the method that it
    // belongs to, without requiring the table itself to be aware of address
    // discrimination or hashing signed pointers.
    static objc::LazyInitDenseMap<const method_t *, void *> smallMethodIMPMap;
#define smallMethodIMPMapKey ptrauth_key_process_dependent_code
#define smallMethodIMPMapDiscriminator(methodPtr) \
    ptrauth_blend_discriminator(methodPtr, ptrauth_string_discriminator("smallMethodIMPMap"))

    static objc::LazyInitDenseMap<const method_t *, objc_method_description *> methodDescriptionMap;
}

static IMP method_t_remappedImp_nolock(const method_t *m) {
    lockdebug::assert_locked(&runtimeLock);
    auto *map = objc::smallMethodIMPMap.get(false);
    if (!map)
        return nullptr;
    auto iter = map->find(m);
    if (iter == map->end())
        return nullptr;
    return bitcast_auth_and_resign(IMP, iter->second,
                                   smallMethodIMPMapKey,
                                   smallMethodIMPMapDiscriminator(m),
                                   ptrauth_key_function_pointer,
                                   ptrauth_function_pointer_type_discriminator(IMP));
}

IMP method_t::remappedImp(bool needsLock) const {
    ASSERT(getKind() == Kind::small);
    if (needsLock) {
        mutex_locker_t guard(runtimeLock);
        return method_t_remappedImp_nolock(this);
    } else {
        lockdebug::assert_locked(&runtimeLock);
        return method_t_remappedImp_nolock(this);
    }
}

void method_t::remapImp(IMP imp) {
    ASSERT(getKind() == Kind::small);
    lockdebug::assert_locked(&runtimeLock);

    auto *map = objc::smallMethodIMPMap.get(true);
    (*map)[this] = bitcast_auth_and_resign(void *, imp,
                                           ptrauth_key_function_pointer,
                                           ptrauth_function_pointer_type_discriminator(IMP),
                                           smallMethodIMPMapKey,
                                           smallMethodIMPMapDiscriminator(this));
}

objc_method_description *method_t::getCachedDescription() const {
    mutex_locker_t guard(runtimeLock);

    auto &ptr = (*objc::methodDescriptionMap.get(true))[this];
    if (!ptr) {
        ptr = (objc_method_description *)malloc(sizeof *ptr);
        ptr->name = name();
        ptr->types = (char *)types();
    }
    return ptr;
}

void method_t::tryFreeContents_nolock() {
    assert_locked(&runtimeLock);
    try_free(types());
    if (auto *map = objc::methodDescriptionMap.get(false))
        map->erase(this);
}

/*
  Low two bits of mlist->entsize is used as the fixed-up marker.
    Method lists from shared cache are 1 (uniqued) or 3 (uniqued and sorted).
    (Protocol method lists are not sorted because of their extra parallel data)
    Runtime fixed-up method lists get 3.

  High two bits of protocol->flags is used as the fixed-up marker.
  PREOPTIMIZED VERSION:
    Protocols from shared cache are 1<<30.
    Runtime fixed-up protocols get 1<<30.
  UN-PREOPTIMIZED VERSION:
  Protocols from shared cache are 1<<30.
    Shared cache's fixups are not trusted.
    Runtime fixed-up protocols get 3<<30.
*/

static const uint32_t fixed_up_method_list = 3;
static const uint32_t uniqued_method_list = 1;
static uint32_t fixed_up_protocol = PROTOCOL_FIXED_UP_1;
static uint32_t canonical_protocol = PROTOCOL_IS_CANONICAL;

void
disableSharedCacheProtocolOptimizations(void)
{
    fixed_up_protocol = PROTOCOL_FIXED_UP_1 | PROTOCOL_FIXED_UP_2;
    // Its safe to just set canonical protocol to 0 as we'll never call
    // clearIsCanonical() unless isCanonical() returned true, which can't happen
    // with a 0 mask
    canonical_protocol = 0;
}

bool method_list_t::isUniqued() const {
    // Small lists always use selrefs which are already uniqued before we use them.
    if ( listKind() == method_t::Kind::small )
        return true;
    return (flags() & uniqued_method_list) != 0;
}

bool method_list_t::isFixedUp() const {
    // Ignore any flags in the top bits, just look at the bottom two.
    return (flags() & 0x3) == fixed_up_method_list;
}

void method_list_t::setFixedUp() {
    lockdebug::assert_locked(&runtimeLock);
    ASSERT(!isFixedUp());
    entsizeAndFlags = entsizeAndFlags| fixed_up_method_list;
}

bool protocol_t::isFixedUp() const {
    return (flags & PROTOCOL_FIXED_UP_MASK) == fixed_up_protocol;
}

void protocol_t::setFixedUp() {
    lockdebug::assert_locked(&runtimeLock);
    ASSERT(!isFixedUp());
    flags = (flags & ~PROTOCOL_FIXED_UP_MASK) | fixed_up_protocol;
}

bool protocol_t::isCanonical() const {
    return (flags & canonical_protocol) != 0;
}

void protocol_t::clearIsCanonical() {
    lockdebug::assert_locked(&runtimeLock);
    ASSERT(isCanonical());
    flags = flags & ~canonical_protocol;
}


method_array_t::ListIterator method_array_t::endCategoryMethodLists(Class cls) const
{
    auto mlists = beginLists();
    auto mlistsEnd = endLists();

    if (mlists == mlistsEnd  ||  !cls->data()->ro()->baseMethods)
    {
        // No methods, or no base methods.
        // Everything here is a category method.
        return mlistsEnd;
    }

    // Have base methods. Category methods are
    // everything except the last method list.
    return --mlistsEnd;
}

static const char *sel_cname(SEL sel)
{
    return (const char *)(void *)sel;
}


static size_t protocol_list_size(const protocol_list_t *plist)
{
    return sizeof(protocol_list_t) + plist->count * sizeof(protocol_t *);
}


using ClassCopyFixupHandler = void (*)(Class _Nonnull oldClass,
                                       Class _Nonnull newClass);
// Normally there's only one handler registered.
static GlobalSmallVector<ClassCopyFixupHandler, 1> classCopyFixupHandlers;

void _objc_setClassCopyFixupHandler(void (* _Nonnull newFixupHandler)
    (Class _Nonnull oldClass, Class _Nonnull newClass)) {
    mutex_locker_t lock(runtimeLock);

    classCopyFixupHandlers.append(newFixupHandler);
}

static Class
alloc_class_for_subclass(Class supercls, size_t extraBytes)
{
    if (!supercls  ||  !supercls->isAnySwift()) {
        return _calloc_class(sizeof(objc_class) + extraBytes);
    }

    // Superclass is a Swift class. New subclass must duplicate its extra bits.

    // Allocate the new class, with space for super's prefix and suffix
    // and self's extraBytes.
    swift_class_t *swiftSupercls = (swift_class_t *)supercls;
    size_t superSize = swiftSupercls->classSize;
    void *superBits = swiftSupercls->baseAddress();
    void *bits = malloc(superSize + extraBytes);

    // Copy all of the superclass's data to the new class.
    memcpy(bits, superBits, superSize);

    // Erase the objc data and the Swift description in the new class.
    swift_class_t *swcls = (swift_class_t *)
        ((uint8_t *)bits + swiftSupercls->classAddressOffset);
    memset(swcls, 0, sizeof(objc_class));
    swcls->description = nil;

    for (auto handler : classCopyFixupHandlers) {
        handler(supercls, (Class)swcls);
    }

    return (Class)swcls;
}


/***********************************************************************
* object_getIndexedIvars.
**********************************************************************/
void *object_getIndexedIvars(id obj)
{
    uint8_t *base = (uint8_t *)obj;

    if (_objc_isTaggedPointerOrNil(obj)) return nil;

    if (!obj->isClass()) return base + obj->ISA()->alignedInstanceSize();

    Class cls = (Class)obj;
    if (!cls->isAnySwift()) return base + sizeof(objc_class);

    swift_class_t *swcls = (swift_class_t *)cls;
    return base - swcls->classAddressOffset + word_align(swcls->classSize);
}


/***********************************************************************
* make_ro_writeable
* Reallocates rw->ro if necessary to make it writeable.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static class_ro_t *make_ro_writeable(class_rw_t *rw)
{
    lockdebug::assert_locked(&runtimeLock);

    if (rw->flags & RW_COPIED_RO) {
        // already writeable, do nothing
    } else {
        rw->set_ro(rw->ro()->duplicate());
        rw->flags |= RW_COPIED_RO;
    }
    return const_cast<class_ro_t *>(rw->ro());
}


/***********************************************************************
* dataSegmentsContain
* Returns true if the given address lies within a data segment in any
* loaded image.
**********************************************************************/
NEVER_INLINE
static bool
dataSegmentsContain(Class cls)
{
    uint32_t index;
    if (objc::dataSegmentsRanges.find((uintptr_t)cls, index)) {
        // if the class is realized (hence has a class_rw_t),
        // memorize where we found the range
        if (cls->isRealized()) {
            cls->data()->witness = (uint16_t)index;
        }
        return true;
    }
    return false;
}


/***********************************************************************
* isKnownClass
* Return true if the class is known to the runtime (located within the
* shared cache, within the data segment of a loaded image, or has been
* allocated with obj_allocateClassPair).
*
* The result of this operation is cached on the class in a "witness"
* value that is cheaply checked in the fastpath.
**********************************************************************/
ALWAYS_INLINE
static bool
isKnownClass(Class cls)
{
    if (fastpath(cls->isRealized() && objc::dataSegmentsRanges.contains(cls->data()->witness, (uintptr_t)cls))) {
        return true;
    }
    auto &set = objc::allocatedClasses.get();
    return set.find(cls) != set.end() || dataSegmentsContain(cls);
}


/***********************************************************************
* addClassTableEntry
* Add a class to the table of all classes. If addMeta is true,
* automatically adds the metaclass of the class as well.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void
addClassTableEntry(Class cls, bool addMeta = true)
{
    lockdebug::assert_locked(&runtimeLock);

    // This class is allowed to be a known class via the shared cache or via
    // data segments, but it is not allowed to be in the dynamic table already.
    auto &set = objc::allocatedClasses.get();

    ASSERT(set.find(cls) == set.end());

    if (!isKnownClass(cls))
        set.insert(cls);
    if (addMeta)
        addClassTableEntry(cls->ISA(), false);
}


/***********************************************************************
* checkIsKnownClass
* Checks the given class against the list of all known classes. Dies
* with a fatal error if the class is not known.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
ALWAYS_INLINE
static void
checkIsKnownClass(Class cls)
{
    if (slowpath(!isKnownClass(cls))) {
        _objc_fatal("Attempt to use unknown class %p.", cls);
    }
}

/***********************************************************************
* classNSObject
* Returns class NSObject.
* Locking: none
**********************************************************************/
static Class classNSObject(void)
{
    extern objc_class OBJC_CLASS_$_NSObject;
    return (Class)&OBJC_CLASS_$_NSObject;
}

static Class metaclassNSObject(void)
{
    extern objc_class OBJC_METACLASS_$_NSObject;
    return (Class)&OBJC_METACLASS_$_NSObject;
}

/***********************************************************************
* printReplacements
* Implementation of PrintReplacedMethods / OBJC_PRINT_REPLACED_METHODS.
* Warn about methods from cats that override other methods in cats or cls.
* Assumes no methods from cats have been added to cls yet.
**********************************************************************/
__attribute__((cold, noinline))
static void
printReplacements(Class cls, const locstamped_category_t *cats_list, uint32_t cats_count)
{
    uint32_t c;
    bool isMeta = cls->isMetaClass();

    // Newest categories are LAST in cats
    // Later categories override earlier ones.
    for (c = 0; c < cats_count; c++) {
        category_t *cat = cats_list[c].cat;

        method_list_t *mlist = cat->methodsForMeta(isMeta);
        if (!mlist) continue;

        for (const auto& meth : *mlist) {
            SEL s = sel_registerName(sel_cname(meth.name()));

            // Search for replaced methods in method lookup order.
            // Complain about the first duplicate only.

            // Look for method in earlier categories
            for (uint32_t c2 = 0; c2 < c; c2++) {
                category_t *cat2 = cats_list[c2].cat;

                const method_list_t *mlist2 = cat2->methodsForMeta(isMeta);
                if (!mlist2) continue;

                for (const auto& meth2 : *mlist2) {
                    SEL s2 = sel_registerName(sel_cname(meth2.name()));
                    if (s == s2) {
                        logReplacedMethod(cls->nameForLogging(), s,
                                          cls->isMetaClass(), cat->name,
                                          meth2.impRaw(), meth.impRaw());
                        goto complained;
                    }
                }
            }

            // Look for method in cls
            for (const auto& meth2 : cls->data()->methods()) {
                SEL s2 = sel_registerName(sel_cname(meth2.name()));
                if (s == s2) {
                    logReplacedMethod(cls->nameForLogging(), s,
                                      cls->isMetaClass(), cat->name,
                                      meth2.impRaw(), meth.impRaw());
                    goto complained;
                }
            }

        complained:
            ;
        }
    }
}


/***********************************************************************
* unreasonableClassCount
* Provides an upper bound for any iteration of classes,
* to prevent spins when runtime metadata is corrupted.
**********************************************************************/
static unsigned unreasonableClassCount()
{
    lockdebug::assert_locked(&runtimeLock);

    int base = NXCountMapTable(gdb_objc_realized_classes) +
    getPreoptimizedClassUnreasonableCount();

    // Provide lots of slack here. Some iterations touch metaclasses too.
    // Some iterations backtrack (like realized class iteration).
    // We don't need an efficient bound, merely one that prevents spins.
    return (base + 1) * 16;
}


/***********************************************************************
* Class enumerators
* The passed in block returns `false` if subclasses can be skipped
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static inline void
foreach_realized_class_and_subclass_2(Class top, unsigned &count,
                                      bool skip_metaclass,
                                      bool (^code)(Class) __attribute((noescape)))
{
    Class cls = top;

    lockdebug::assert_locked(&runtimeLock);
    ASSERT(top);

    while (1) {
        if (--count == 0) {
            _objc_fatal("Memory corruption in class list.");
        }

        bool skip_subclasses;

        if (skip_metaclass && cls->isMetaClass()) {
            skip_subclasses = true;
        } else {
            skip_subclasses = !code(cls);
        }

        if (!skip_subclasses && cls->data()->firstSubclass) {
            cls = cls->data()->firstSubclass;
        } else {
            while (!cls->data()->nextSiblingClass  &&  cls != top) {
                cls = cls->getSuperclass();
                if (--count == 0) {
                    _objc_fatal("Memory corruption in class list.");
                }
            }
            if (cls == top) break;
            cls = cls->data()->nextSiblingClass;
        }
    }
}

// Enumerates a class and all of its realized subclasses.
static void
foreach_realized_class_and_subclass(Class top, bool (^code)(Class) __attribute((noescape)))
{
    unsigned int count = unreasonableClassCount();

    foreach_realized_class_and_subclass_2(top, count, false, code);
}

// Enumerates all realized classes and metaclasses.
static void
foreach_realized_class_and_metaclass(bool (^code)(Class) __attribute((noescape)))
{
    unsigned int count = unreasonableClassCount();

    for (Class top = _firstRealizedClass;
         top != nil;
         top = top->data()->nextSiblingClass)
    {
        foreach_realized_class_and_subclass_2(top, count, false, code);
    }
}

// Enumerates all realized classes (ignoring metaclasses).
static void
foreach_realized_class(bool (^code)(Class) __attribute((noescape)))
{
    unsigned int count = unreasonableClassCount();

    for (Class top = _firstRealizedClass;
         top != nil;
         top = top->data()->nextSiblingClass)
    {
        foreach_realized_class_and_subclass_2(top, count, true, code);
    }
}


/***********************************************************************
 * enumerateSelectorsInMethodList
 **********************************************************************/
template<class EnumerateFunc>
static void enumerateSelectorsInMethodList(const method_list_t *list,
                                           const EnumerateFunc &fn) {
    switch (list->listKind()) {
    case method_t::Kind::small:
        if (CONFIG_SHARED_CACHE_RELATIVE_DIRECT_SELECTORS && objc::inSharedCache((uintptr_t)list)) {
            for (auto& meth: *list) if (!fn(meth.getSmallNameAsSEL())) break;
        } else {
            for (auto& meth: *list) if (!fn(meth.getSmallNameAsSELRef())) break;
        }
        break;
    case method_t::Kind::big:
        for (auto& meth: *list) if (!fn(meth.big().name)) break;
        break;
    case method_t::Kind::bigSigned:
        for (auto& meth: *list) if (!fn(meth.bigSigned().name)) break;
        break;
#if TARGET_OS_EXCLAVEKIT
    case method_t::Kind::bigStripped:
        for (auto& meth: *list) if (!fn(meth.bigStripped().name)) break;
        break;
#endif
    }
}

/***********************************************************************
 * Method Scanners / Optimization tracking
 * Implementation of scanning for various implementations of methods.
 **********************************************************************/

namespace objc {

// The current state of NSObject swizzling for every scanner
//
// It allows for cheap checks of global swizzles, and also lets
// things like IMP Swizzling before NSObject has been initialized
// to be remembered, as setInitialized() would miss these.
//
// The bits have values from flag_t below, *but* if we're asking
// about the metaclass then shifted left one.
static uintptr_t NSObjectSwizzledMask;

static uintptr_t InterestingSelectorOnes;
static uintptr_t InterestingSelectorZeroes;

static const char * const interestingSelectors[] = {
     "_isDeallocating",
     "_tryRetain",
     "alloc",
     "allocWithZone:",
     "allowsWeakReference",
     "autorelease",
     "class",
     "isKindOfClass:",
     "new",
     "release",
     "respondsToSelector:",
     "retain",
     "retainCount",
     "retainWeakReference",
     "self"
};

class Scanner {
    // There must be a spare bit between each of these
    typedef enum {
        AWZ  = 0x0001,
        RR   = 0x0004,
        Core = 0x0010,
    } flag_t;

    typedef enum {
        NotInherited,
        Inherited
    } inherited_t;

    typedef enum {
        NotMetaclass,
        Metaclass
    } metaclass_t;

 public:
    static void
    init()
    {
        static const unsigned count = (sizeof(interestingSelectors)
                                       /sizeof(interestingSelectors[0]));

        uintptr_t ones = ~(uintptr_t)0;
        uintptr_t zeroes = ~(uintptr_t)0;

        for (unsigned n = 0; n < count; ++n) {
            // Look up the selector only if it's provided by the shared cache. We
            // haven't yet initialized the named selector table, so we can't create a
            // new selector if it isn't already in the shared cache table.
            SEL sel = _sel_searchBuiltins(interestingSelectors[n]);

            // If we couldn't look up the selector, give up and set masks that
            // match every selector.
            if (!sel) {
                ones = 0;
                zeroes = 0;
                break;
            }

            ones &= (uintptr_t)sel;
            zeroes &= ~(uintptr_t)sel;
        }

        InterestingSelectorOnes = ones;
        InterestingSelectorZeroes = zeroes;
    }

 private:
    static void
    printCustom(const char *prefix, Class cls, inherited_t inherited)
    {
        _objc_inform("%s: %s%s%s",
                     prefix,
                     cls->nameForLogging(),
                     cls->isMetaClass() ? " (meta)" : "",
                     inherited == Inherited ? " (inherited)" : "");
    }

    static void
    propagateCustomFlags(Class cls,
                         unsigned flags,
                         inherited_t inherited = NotInherited)
    {
        bool customAWZ = !!(flags & AWZ);
        bool customRR = !!(flags & RR);
        bool customCore = !!(flags & Core);

        foreach_realized_class_and_subclass(cls, [=](Class c){
            bool isSubclass = c != cls;

            if (isSubclass && !c->isInitialized()) {
                // Subclass not yet initialized. Wait for setInitialized() to do it
                return false;
            }

            bool keepGoing = false;
            inherited_t isInherited = isSubclass ? Inherited : inherited;

            if (customAWZ && !c->hasCustomAWZ()) {
                c->setHasCustomAWZ();
                if (PrintCustomAWZ)
                    printCustom("CUSTOM AWZ", c, isInherited);
                keepGoing = true;
            }
            if (customRR && !c->hasCustomRR()) {
                c->setHasCustomRR();
                if (PrintCustomRR)
                    printCustom("CUSTOM RR", c, isInherited);
                keepGoing = true;
            }
            if (customCore && !c->hasCustomCore()) {
                c->setHasCustomCore();
                if (PrintCustomCore)
                    printCustom("CUSTOM Core", c, isInherited);
                keepGoing = true;
            }

            return keepGoing;
        });
    }

    static ALWAYS_INLINE bool isInterestingSelector(SEL sel) {
        uintptr_t uisel = (uintptr_t)sel;

        return (uisel & InterestingSelectorZeroes) == 0
            && (uisel & InterestingSelectorOnes) == InterestingSelectorOnes;
    }

    static ALWAYS_INLINE bool isAWZSelector(SEL sel) {
        return sel == @selector(alloc) || sel == @selector(allocWithZone:);
    }

    static ALWAYS_INLINE
    bool isRRSelector(SEL sel) {
        return sel == @selector(retain) ||
               sel == @selector(release) ||
               sel == @selector(autorelease) ||
               sel == @selector(_tryRetain) ||
               sel == @selector(_isDeallocating) ||
               sel == @selector(retainCount) ||
               sel == @selector(allowsWeakReference) ||
               sel == @selector(retainWeakReference);
    }

    static  ALWAYS_INLINE
    bool isCoreSelector(SEL sel) {
        return sel == @selector(new) ||
               sel == @selector(self) ||
               sel == @selector(class) ||
               sel == @selector(isKindOfClass:) ||
               sel == @selector(respondsToSelector:);
    }

    static
    bool isClassOnly(unsigned flags) {
        return flags == AWZ;
    }

    static
    bool isSwiftObject(Class cls) {
        if (cls->isRootClass() || cls->isRootMetaclass())
            if (strcmp(cls->mangledName(), "_TtCs12_SwiftObject") == 0)
                return true;
        return false;
    }

    static
    bool isNSObjectSwizzled(unsigned flags, metaclass_t mc) {
        return NSObjectSwizzledMask & (flags << mc);
    }

    static
    void setNSObjectSwizzled(Class cls, unsigned flags, metaclass_t mc) {
        NSObjectSwizzledMask |= (flags << mc);
        if (cls->isInitialized())
            propagateCustomFlags(cls, flags);
    }

    template <class T>
    static unsigned
    scanMethodLists(T first, T end) {
        unsigned flags = 0;
        T ptr = first;
        while (ptr < end) {
            method_list_t *mlist = *ptr;
            ++ptr;

            enumerateSelectorsInMethodList(mlist, [&flags](SEL sel){
                if (!isInterestingSelector(sel))
                    return true;
                if (isAWZSelector(sel))
                    flags |= AWZ;
                else if (isRRSelector(sel))
                    flags |= RR;
                else if (isCoreSelector(sel))
                    flags |= Core;
                return flags != (AWZ|RR|Core);
            });
        }
        return flags;
    }

    static bool
    knownClassHasDefaultImpl(Class cls, metaclass_t mc) {
        Class nsobj = mc ? metaclassNSObject() : classNSObject();
        return cls == nsobj;
    }

    static void
    scanAddedClassImpl(Class cls, metaclass_t mc) {
        unsigned flags = (NSObjectSwizzledMask >> mc) & (AWZ|RR|Core);
        inherited_t inheritedAWZ = NotInherited;
        inherited_t inheritedRR = NotInherited;
        inherited_t inheritedCore = NotInherited;

        if (knownClassHasDefaultImpl(cls, mc)) {
            // This class is known to have the default implementations,
            // but we need to check categories.
            auto &methods = cls->data()->methods();
            flags |= scanMethodLists(methods.beginCategoryMethodLists(),
                                     methods.endCategoryMethodLists(cls));
        } else if (!cls->getSuperclass()) {
            // Custom root class
            flags |= (AWZ|RR|Core);
        } else {
            Class superCls = cls->getSuperclass();
            if (superCls->hasCustomAWZ()) {
                flags |= AWZ;
                inheritedAWZ = Inherited;
            }
            if (superCls->hasCustomRR()) {
                flags |= RR;
                inheritedRR = Inherited;
            }
            if (superCls->hasCustomCore()) {
                flags |= Core;
                inheritedCore = Inherited;
            }

            if (flags != (AWZ|RR|Core)) {
                auto &methods = cls->data()->methods();
                flags |= scanMethodLists(methods.beginLists(),
                                         methods.endLists());
            }
        }

        if (slowpath(flags & AWZ)) {
            cls->setHasCustomAWZ();
            if (PrintCustomAWZ)
                printCustom("CUSTOM AWZ", cls, inheritedAWZ);
        } else {
            cls->setHasDefaultAWZ();
        }
        if (slowpath(flags & RR)) {
            cls->setHasCustomRR();
            if (PrintCustomRR)
                printCustom("CUSTOM RR", cls, inheritedRR);
        } else {
            cls->setHasDefaultRR();
        }

        // We ignore Core on SwiftObject, since we know the implementations
        // match NSObject's, and nobody can legitimately change those methods.
        if (slowpath(flags & Core) && !isSwiftObject(cls)) {
            cls->setHasCustomCore();
            if (PrintCustomCore)
                printCustom("CUSTOM Core", cls, inheritedCore);
        } else {
            cls->setHasDefaultCore();
        }
    }

 public:
    // Scan a class that is about to be marked Initialized for particular
    // bundles of selectors, and mark the class and its children
    // accordingly.
    //
    // This also handles inheriting properties from its superclass.
    //
    // Caller: objc_class::setInitialized()
    static void
    scanInitializedClass(Class cls, Class metacls)
    {
        scanAddedClassImpl(cls, NotMetaclass);
        scanAddedClassImpl(metacls, Metaclass);
    }

    // Inherit various properties from the superclass when a class
    // is being added to the graph.
    //
    // Caller: addSubclass()
    static void
    scanAddedSubClass(Class subcls, Class supercls)
    {
        unsigned flags = 0;

        if (supercls->hasCustomAWZ())
            flags |= AWZ;
        if (supercls->hasCustomRR())
            flags |= RR;
        if (supercls->hasCustomCore())
            flags |= Core;

        if (subcls->hasCustomAWZ())
            flags &= ~AWZ;
        if (subcls->hasCustomRR())
            flags &= ~RR;
        if (subcls->hasCustomCore())
            flags &= ~Core;

        if (slowpath(flags))
            propagateCustomFlags(subcls, flags, Inherited);
    }

    // Scan Method lists for selectors that would override things
    // in a Bundle.
    //
    // This is used to detect when categories override problematic selectors
    // are injected in a class after it has been initialized.
    //
    // Caller: prepareMethodLists()
    static void
    scanAddedMethodLists(Class cls, method_list_t **mlists, int count)
    {
        method_list_t **end = mlists + count;
        unsigned flags = scanMethodLists(mlists, end);

        if (slowpath(flags))
            propagateCustomFlags(cls, flags, NotInherited);
    }

    // Handle IMP Swizzling (the IMP for an exisiting method being changed).
    //
    // In almost all cases, IMP swizzling does not affect custom bits.
    // Custom search will already find the method whether or not
    // it is swizzled, so it does not transition from non-custom to custom.
    //
    // The only cases where IMP swizzling can affect the custom bits is
    // if the swizzled method is one of the methods that is assumed to be
    // non-custom. These special cases are listed in setInitialized().
    // We look for such cases here.
    //
    // Caller: Swizzling methods via adjustCustomFlagsForMethodChange()
    static void
    scanChangedMethod(Class cls, const method_t *meth)
    {
        unsigned flags = 0;
        SEL sel = meth->name();

        if (isAWZSelector(sel))
            flags |= AWZ;
        else if (isRRSelector(sel))
            flags |= RR;
        else if (isCoreSelector(sel))
            flags |= Core;

        if (fastpath(!flags))
            return;

        if (cls) {
            bool isMeta = cls->isMetaClass();
            if (isMeta) {
                if (cls == metaclassNSObject()
                    && !isNSObjectSwizzled(flags, Metaclass))
                    setNSObjectSwizzled(cls, flags, Metaclass);
            }
            if (!isMeta && !isClassOnly(flags)) {
                if (cls == classNSObject()
                    && !isNSObjectSwizzled(flags, NotMetaclass))
                    setNSObjectSwizzled(cls, flags, NotMetaclass);
            }
        } else {
            // We're called from method_exchangeImplementations, only NSObject
            // class and metaclass may be problematic (exchanging the default
            // builtin IMP of an interesting seleector, is a swizzling that,
            // may flip our scanned property. For other classes, the previous
            // value had already flipped the property).
            //
            // However, as we don't know the class, we need to scan all of
            // NSObject class and metaclass methods (this is SLOW).
            cls = classNSObject();
            if (!isClassOnly(flags) && !isNSObjectSwizzled(flags, NotMetaclass)) {
                for (const auto &meth2: cls->data()->methods()) {
                    if (meth == &meth2) {
                        setNSObjectSwizzled(cls, flags, NotMetaclass);
                        break;
                    }
                }
            }

            cls = metaclassNSObject();
            if (!isNSObjectSwizzled(flags, Metaclass)) {
                for (const auto &meth2: cls->data()->methods()) {
                    if (meth == &meth2) {
                        setNSObjectSwizzled(cls, flags, Metaclass);
                        break;
                    }
                }
            }
        }
    }
};

class category_list : nocopy_t {
    union {
        locstamped_category_t lc;
        struct {
            locstamped_category_t *array;
            // this aliases with locstamped_category_t::hi
            // which is an aliased pointer
            uint32_t is_array :  1;
            uint32_t count    : 31;
            uint32_t size     : 32;
        };
    } _u;

public:
    category_list() : _u{{nullptr, nullptr}} { }
    category_list(locstamped_category_t lc) : _u{{lc}} { }
    category_list(category_list &&other) : category_list() {
        std::swap(_u, other._u);
    }
    ~category_list()
    {
        if (_u.is_array) {
            free(_u.array);
        }
    }

    uint32_t count() const
    {
        if (_u.is_array) return _u.count;
        return _u.lc.cat ? 1 : 0;
    }

    uint32_t arrayByteSize(uint32_t size) const
    {
        return sizeof(locstamped_category_t) * size;
    }

    const locstamped_category_t *array() const
    {
        return _u.is_array ? _u.array : &_u.lc;
    }

    void append(locstamped_category_t lc)
    {
        if (_u.is_array) {
            if (_u.count == _u.size) {
                // Have a typical malloc growth:
                // - size <=  8: grow by 2
                // - size <= 16: grow by 4
                // - size <= 32: grow by 8
                // ... etc
                _u.size += _u.size < 8 ? 2 : 1 << (Log2_32(_u.size) - 1);
                _u.array = (locstamped_category_t *)reallocf(_u.array, arrayByteSize(_u.size));
            }
            _u.array[_u.count++] = lc;
        } else if (_u.lc.cat == NULL) {
            _u.lc = lc;
        } else {
            locstamped_category_t *arr = (locstamped_category_t *)malloc(arrayByteSize(2));
            arr[0] = _u.lc;
            arr[1] = lc;

            _u.array = arr;
            _u.is_array = true;
            _u.count = 2;
            _u.size = 2;
        }
    }

    void erase(category_t *cat)
    {
        if (_u.is_array) {
            for (int i = 0; i < _u.count; i++) {
                if (_u.array[i].cat == cat) {
                    // shift entries to preserve list order
                    memmove(&_u.array[i], &_u.array[i+1], arrayByteSize(_u.count - i - 1));
                    _u.count--;
                    return;
                }
            }
        } else if (_u.lc.cat == cat) {
            _u.lc.cat = NULL;
            _u.lc.hi = NULL;
        }
    }
};

class UnattachedCategories : public ExplicitInitDenseMap<Class, category_list>
{
public:
    void addForClass(locstamped_category_t lc, Class cls)
    {
        lockdebug::assert_locked(&runtimeLock);

        if (slowpath(PrintConnecting)) {
            _objc_inform("CLASS: found category %c%s(%s)",
                         cls->isMetaClassMaybeUnrealized() ? '+' : '-',
                         cls->nameForLogging(), lc.cat->name);
        }

        auto result = get().try_emplace(cls, lc);
        if (!result.second) {
            result.first->second.append(lc);
        }
    }

    void attachToClass(Class cls, Class previously, int flags)
    {
        lockdebug::assert_locked(&runtimeLock);
        ASSERT((flags & ATTACH_CLASS) ||
               (flags & ATTACH_METACLASS) ||
               (flags & ATTACH_CLASS_AND_METACLASS));

        auto &map = get();
        auto it = map.find(previously);

        if (it != map.end()) {
            category_list &list = it->second;
            if (flags & ATTACH_CLASS_AND_METACLASS) {
                int otherFlags = flags & ~ATTACH_CLASS_AND_METACLASS;
                attachCategories(cls, list.array(), list.count(), otherFlags | ATTACH_CLASS);
                attachCategories(cls->ISA(), list.array(), list.count(), otherFlags | ATTACH_METACLASS);
            } else {
                attachCategories(cls, list.array(), list.count(), flags);
            }
            map.erase(it);
        }
    }

    void eraseCategoryForClass(category_t *cat, Class cls)
    {
        lockdebug::assert_locked(&runtimeLock);

        auto &map = get();
        auto it = map.find(cls);
        if (it != map.end()) {
            category_list &list = it->second;
            list.erase(cat);
            if (list.count() == 0) {
                map.erase(it);
            }
        }
    }

    void eraseClass(Class cls)
    {
        lockdebug::assert_locked(&runtimeLock);

        get().erase(cls);
    }
};

static UnattachedCategories unattachedCategories;

} // namespace objc

static bool isBundleClass(Class cls)
{
    return cls->data()->ro()->flags & RO_FROM_BUNDLE;
}


static void
fixupMethodList(method_list_t *mlist, bool bundleCopy, bool sort)
{
    lockdebug::assert_locked(&runtimeLock);
    ASSERT(!mlist->isFixedUp());

    // Skip empty lists. This is a workaround for empty lists embedded in
    // relative_list_list_t structures that shouldn't be mutated.
    if (mlist->count == 0)
        return;

    // fixme lock less in attachMethodLists ?
    // dyld3 may have already uniqued, but not sorted, the list
    if (!mlist->isUniqued()) {
        mutex_locker_t lock(selLock);

        // Unique selectors in list.
        for (auto& meth : *mlist) {
            const char *name = sel_cname(meth.name());
            meth.setName(sel_registerNameNoLock(name, bundleCopy));
        }
    }

    // Sort by selector address.
    // Don't try to sort small lists, as they're immutable.
    // Don't try to sort big lists of nonstandard size, as stable_sort
    // won't copy the entries properly.
    if (sort && mlist->listKind() != method_t::Kind::small && mlist->entsize() == method_t::bigSize)
        mlist->sortBySELAddress();

    // Mark method list as uniqued and sorted.
    // Can't mark small lists, since they're immutable.
    if (mlist->listKind() != method_t::Kind::small) {
        mlist->setFixedUp();
    }
}


static void
prepareMethodLists(Class cls, method_list_t **addedLists, int addedCount,
                   bool baseMethods, bool methodsFromBundle, const char *why)
{
    lockdebug::assert_locked(&runtimeLock);

    if (addedCount == 0) return;

    // There exist RR/AWZ/Core special cases for some class's base methods.
    // But this code should never need to scan base methods for RR/AWZ/Core:
    // default RR/AWZ/Core cannot be set before setInitialized().
    // Therefore we need not handle any special cases here.
    if (baseMethods) {
        ASSERT(cls->hasCustomAWZ() && cls->hasCustomRR() && cls->hasCustomCore());
    } else if (cls->cache.isConstantOptimizedCache()) {
        cls->setDisallowPreoptCachesRecursively(why);
    } else if (cls->allowsPreoptInlinedSels()) {
#if CONFIG_USE_PREOPT_CACHES
        SEL *sels = (SEL *)objc_opt_offsets[OBJC_OPT_INLINED_METHODS_START];
        SEL *sels_end = (SEL *)objc_opt_offsets[OBJC_OPT_INLINED_METHODS_END];
        if (method_lists_contains_any(addedLists, addedLists + addedCount, sels, sels_end - sels)) {
            cls->setDisallowPreoptInlinedSelsRecursively(why);
        }
#endif
    }

    // Add method lists to array.
    // Reallocate un-fixed method lists.
    // The new methods are PREPENDED to the method list array.

    for (int i = 0; i < addedCount; i++) {
        method_list_t *mlist = addedLists[i];
        ASSERT(mlist);

        // Fixup selectors if necessary
        if (!mlist->isFixedUp()) {
            fixupMethodList(mlist, methodsFromBundle, true/*sort*/);
        }
    }

    // If the class is initialized, then scan for method implementations
    // tracked by the class's flags. If it's not initialized yet,
    // then objc_class::setInitialized() will take care of it.
    if (cls->isInitialized()) {
        objc::Scanner::scanAddedMethodLists(cls, addedLists, addedCount);
    }
}

class_rw_ext_t *
class_rw_t::extAlloc(const class_ro_t *ro, bool deepCopy)
{
    lockdebug::assert_locked(&runtimeLock);

    auto rwe = objc::zalloc<class_rw_ext_t>();

    rwe->version = (ro->flags & RO_META) ? 7 : 0;

    if (method_list_t *list = ro->baseMethods.dyn_cast<method_list_t *>()) {
        if (deepCopy) list = list->duplicate();
        rwe->methods.attachLists(&list, 1, /*preoptimized*/false, PrintPreopt ? "methods" : nullptr);
    } else if (auto *listList = ro->baseMethods.dyn_cast<relative_list_list_t<method_list_t> *>()) {
        if (deepCopy) {
            auto iter = listList->beginLists();
            auto end = listList->endLists();
            while (iter != end) {
                method_list_t *dup = (*iter)->duplicate();
                rwe->methods.attachLists(&dup, 1, /*preoptimized*/false, PrintPreopt ? "methods" : nullptr);
                ++iter;
            }
        } else {
            rwe->methods.attachListList(listList);
        }
    }

    // See comments in objc_duplicateClass
    // property lists and protocol lists historically
    // have not been deep-copied
    //
    // This is probably wrong and ought to be fixed some day
    if (property_list_t *proplist = ro->baseProperties.dyn_cast<property_list_t *>()) {
        rwe->properties.attachLists(&proplist, 1, /*preoptimized*/false, PrintPreopt ? "properties" : nullptr);
    } else if (auto *propListList = ro->baseProperties.dyn_cast<relative_list_list_t<property_list_t> *>()) {
        rwe->properties.attachListList(propListList);
    }

    if( protocol_list_t *protolist = ro->baseProtocols.dyn_cast<protocol_list_t *>()) {
        rwe->protocols.attachLists(&protolist, 1, /*preoptimized*/false, PrintPreopt ? "protocols" : nullptr);
    } else if (auto *protoListList = ro->baseProtocols.dyn_cast<relative_list_list_t<protocol_list_t> *>()) {
        rwe->protocols.attachListList(protoListList);
    }


    set_ro_or_rwe(rwe, ro);
    return rwe;
}

// Attach method lists and properties and protocols from categories to a class.
// Assumes the categories in cats are all loaded and sorted by load order,
// oldest categories first.
static void
attachCategories(Class cls, const locstamped_category_t *cats_list, uint32_t cats_count,
                 int flags)
{
    if (slowpath(PrintReplacedMethods)) {
        printReplacements(cls, cats_list, cats_count);
    }
    if (slowpath(PrintConnecting)) {
        _objc_inform("CLASS: attaching %d categories to%s class '%s'%s",
                     cats_count, (flags & ATTACH_EXISTING) ? " existing" : "",
                     cls->nameForLogging(), (flags & ATTACH_METACLASS) ? " (meta)" : "");
        for (uint32_t i = 0; i < cats_count; i++)
            _objc_inform("    category: (%s) %p", cats_list[i].cat->name, cats_list[i].cat);
    }

    /*
     * Only a few classes have more than 64 categories during launch.
     * This uses a little stack, and avoids malloc.
     *
     * Categories must be added in the proper order, which is back
     * to front. To do that with the chunking, we iterate cats_list
     * from front to back, build up the local buffers backwards,
     * and call attachLists on the chunks. attachLists prepends the
     * lists, so the final result is in the expected order.
     */
    constexpr uint32_t ATTACH_BUFSIZ = 64;
    struct Lists {
        ReversedFixedSizeArray<method_list_t *, ATTACH_BUFSIZ> methods;
        ReversedFixedSizeArray<property_list_t *, ATTACH_BUFSIZ> properties;
        ReversedFixedSizeArray<protocol_list_t *, ATTACH_BUFSIZ> protocols;
    };
    Lists preattachedLists;
    Lists normalLists;

    bool fromBundle = NO;
    bool isMeta = (flags & ATTACH_METACLASS);
    auto rwe = cls->data()->extAllocIfNeeded();

    for (uint32_t i = 0; i < cats_count; i++) {
        auto& entry = cats_list[i];

        method_list_t *mlist = entry.cat->methodsForMeta(isMeta);
        bool isPreattached = entry.hi->info()->dyldCategoriesOptimized() && !DisablePreattachedCategories;
        Lists *lists = isPreattached ? &preattachedLists : &normalLists;
        if (mlist) {
            if (lists->methods.isFull()) {
                prepareMethodLists(cls, lists->methods.array, lists->methods.count, NO, fromBundle, __func__);
                rwe->methods.attachLists(lists->methods.array, lists->methods.count, isPreattached, PrintPreopt ? "methods" : nullptr);
                lists->methods.clear();
            }
            lists->methods.add(mlist);
            fromBundle |= entry.hi->isBundle();
        }

        property_list_t *proplist =
            entry.cat->propertiesForMeta(isMeta, entry.hi);
        if (proplist) {
            if (lists->properties.isFull()) {
                rwe->properties.attachLists(lists->properties.array, lists->properties.count, isPreattached, PrintPreopt ? "properties" : nullptr);
                lists->properties.clear();
            }
            lists->properties.add(proplist);
        }

        protocol_list_t *protolist = entry.cat->protocolsForMeta(isMeta);
        if (protolist) {
            if (lists->protocols.isFull()) {
                rwe->protocols.attachLists(lists->protocols.array, lists->protocols.count, isPreattached, PrintPreopt ? "protocols" : nullptr);
                lists->protocols.clear();
            }
            lists->protocols.add(protolist);
        }
    }

    auto attach = [&](Lists *lists, bool isPreattached) {
        if (lists->methods.count > 0) {
            prepareMethodLists(cls, lists->methods.begin(), lists->methods.count,
                               NO, fromBundle, __func__);
            rwe->methods.attachLists(lists->methods.begin(), lists->methods.count, isPreattached, PrintPreopt ? "methods" : nullptr);
            if (flags & ATTACH_EXISTING) {
                flushCaches(cls, __func__, [](Class c){
                    // constant caches have been dealt with in prepareMethodLists
                    // if the class still is constant here, it's fine to keep
                    return !c->cache.isConstantOptimizedCache();
                });
            }
        }

        rwe->properties.attachLists(lists->properties.begin(), lists->properties.count, isPreattached, PrintPreopt ? "properties" : nullptr);

        rwe->protocols.attachLists(lists->protocols.begin(), lists->protocols.count, isPreattached, PrintPreopt ? "protocols" : nullptr);
    };
    attach(&preattachedLists, true);
    attach(&normalLists, false);
}


/***********************************************************************
* methodizeClass
* Fixes up cls's method list, protocol list, and property list.
* Attaches any outstanding categories.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void methodizeClass(Class cls, Class previously)
{
    lockdebug::assert_locked(&runtimeLock);

    bool isMeta = cls->isMetaClass();
    auto rw = cls->data();
    auto ro = rw->ro();

    // This should always run before a class has a rw_ext.
    ASSERT(!rw->ext());

    // Methodizing for the first time
    if (PrintConnecting) {
        _objc_inform("CLASS: methodizing class '%s' %s",
                     cls->nameForLogging(), isMeta ? "(meta)" : "");
    }

    // Install methods and properties that the class implements itself.
    if (method_list_t *list = ro->baseMethods.template dyn_cast<method_list_t *>()) {
        prepareMethodLists(cls, &list, 1, YES, isBundleClass(cls), nullptr);
    } else if (auto *listList = ro->baseMethods.template dyn_cast<relative_list_list_t<method_list_t> *>()) {
        // We pass true for ignoringInitialLoad because we want to
        // prepareMethodLists on all loaded preattached categories, even if
        // we haven't called load_images yet. We don't want to consider such
        // categories for dynamic dispatch at that time, but we still need to
        // prepare them to find overrides and dump preoptimized categories etc.
        auto iter = listList->beginLists();
        auto end = listList->endLists();
        unsigned numLoaded = 0;
        while (iter != end) {
            method_list_t *methodList = *iter;

            ++iter;

            bool isLastList = (iter == end);
            bool isBaseMethods = isLastList;
            prepareMethodLists(cls, &methodList, 1, isBaseMethods, isBundleClass(cls), nullptr);

            numLoaded++;
        }

        // When a class has a huge number of preattached lists, and a
        // lot of them are not loaded, we can spend a significant amount
        // of time in the msgSend slow path just skipping over the
        // unloaded entries. There are a small number of such classes in
        // the shared cache which also get messaged a huge amount, such
        // as NSObject and NSString. Trade some memory for time and
        // eagerly copy the method lists of those objects into a
        // contiguous array for faster searches. Classes with at least
        // `threshold` lists, of which at most `1/proportion` are
        // loaded, have their lists copied.
        //
        // We set the threshold at 100 and 1/2. Empirically, this should
        // affect ~10 total classes.
        const unsigned threshold = 100;
        const unsigned proportion = 2;
        if (listList->count >= threshold && numLoaded <= listList->count / proportion) {
            rw->extAllocIfNeeded()->methods.copyListList(numLoaded);
        }
    }

    // Root classes get bonus method implementations if they don't have
    // them already. These apply before category replacements.
    if (cls->isRootMetaclass()) {
        // root metaclass
        addMethod(cls, @selector(initialize), (IMP)&objc_noop_imp, "", NO);
    }

    // Attach categories.
    if (previously) {
        if (isMeta) {
            objc::unattachedCategories.attachToClass(cls, previously,
                                                     ATTACH_METACLASS);
        } else {
            // When a class relocates, categories with class methods
            // may be registered on the class itself rather than on
            // the metaclass. Tell attachToClass to look for those.
            objc::unattachedCategories.attachToClass(cls, previously,
                                                     ATTACH_CLASS_AND_METACLASS);
        }
    }
    objc::unattachedCategories.attachToClass(cls, cls,
                                             isMeta ? ATTACH_METACLASS : ATTACH_CLASS);

#if DEBUG
    // Debug: sanity-check all SELs; log method list contents
    for (const auto& meth : rw->methods()) {
        if (PrintConnecting) {
            _objc_inform("METHOD %c[%s %s]", isMeta ? '+' : '-',
                         cls->nameForLogging(), sel_getName(meth.name()));
        }
        ASSERT(sel_registerName(sel_getName(meth.name())) == meth.name());
    }
#endif
}


/***********************************************************************
* nonMetaClasses
* Returns the secondary metaclass => class map
* Used for some cases of +initialize and +resolveClassMethod:.
* This map does not contain all class and metaclass pairs. It only
* contains metaclasses whose classes would be in the runtime-allocated
* named-class table, but are not because some other class with the same name
* is in that table.
* Classes with no duplicates are not included.
* Classes in the preoptimized named-class table are not included.
* Classes whose duplicates are in the preoptimized table are not included.
* Most code should use getMaybeUnrealizedNonMetaClass()
* instead of reading this table.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static NXMapTable *nonmeta_class_map = nil;
static NXMapTable *nonMetaClasses(void)
{
    lockdebug::assert_locked(&runtimeLock);

    if (nonmeta_class_map) return nonmeta_class_map;

    // nonmeta_class_map is typically small
    INIT_ONCE_PTR(nonmeta_class_map,
                  NXCreateMapTable(NXPtrValueMapPrototype, 32),
                  NXFreeMapTable(v));

    return nonmeta_class_map;
}


/***********************************************************************
* addNonMetaClass
* Adds metacls => cls to the secondary metaclass map
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void addNonMetaClass(Class cls)
{
    lockdebug::assert_locked(&runtimeLock);
    void *old;
    old = NXMapInsert(nonMetaClasses(), cls->ISA(), cls);

    ASSERT(!cls->isMetaClassMaybeUnrealized());
    ASSERT(cls->ISA()->isMetaClassMaybeUnrealized());
    ASSERT(!old);
}


static void removeNonMetaClass(Class cls)
{
    lockdebug::assert_locked(&runtimeLock);
    NXMapRemove(nonMetaClasses(), cls->ISA());
}


static bool scanMangledField(const char *&string, const char *end,
                             const char *&field, int& length)
{
    // Leading zero not allowed.
    if (*string == '0') return false;

    length = 0;
    field = string;
    while (field < end) {
        char c = *field;
        if (!isdigit(c)) break;
        field++;
        if (__builtin_smul_overflow(length, 10, &length)) return false;
        if (__builtin_sadd_overflow(length, c - '0', &length)) return false;
    }

    string = field + length;
    return length > 0  &&  string <= end;
}


/***********************************************************************
* copySwiftV1DemangledName
* Returns the pretty form of the given Swift-v1-mangled class or protocol name.
* Returns nil if the string doesn't look like a mangled Swift v1 name.
* The result must be freed with free().
**********************************************************************/
static char *copySwiftV1DemangledName(const char *string, bool isProtocol = false)
{
    if (!string) return nil;

    // Swift mangling prefix.
    if (strncmp(string, isProtocol ? "_TtP" : "_TtC", 4) != 0) return nil;
    string += 4;

    const char *end = string + strlen(string);

    // Module name.
    const char *prefix;
    int prefixLength;
    if (string[0] == 's') {
        // "s" is the Swift module.
        prefix = "Swift";
        prefixLength = 5;
        string += 1;
    } else {
        if (! scanMangledField(string, end, prefix, prefixLength)) return nil;
    }

    // Class or protocol name.
    const char *suffix;
    int suffixLength;
    if (! scanMangledField(string, end, suffix, suffixLength)) return nil;

    if (isProtocol) {
        // Remainder must be "_".
        if (strcmp(string, "_") != 0) return nil;
    } else {
        // Remainder must be empty.
        if (string != end) return nil;
    }

    char *result;
    _objc_asprintf(&result, "%.*s.%.*s", prefixLength,prefix, suffixLength,suffix);
    return result;
}


/***********************************************************************
* copySwiftV1MangledName
* Returns the Swift 1.0 mangled form of the given class or protocol name.
* Returns nil if the string doesn't look like an unmangled Swift name.
* The result must be freed with free().
**********************************************************************/
static char *copySwiftV1MangledName(const char *string, bool isProtocol = false)
{
    if (!string) return nil;

    size_t dotCount = 0;
    size_t dotIndex;
    const char *s;
    for (s = string; *s; s++) {
        if (*s == '.') {
            dotCount++;
            dotIndex = s - string;
        }
    }
    size_t stringLength = s - string;

    if (dotCount != 1  ||  dotIndex == 0  ||  dotIndex >= stringLength-1) {
        return nil;
    }

    const char *prefix = string;
    size_t prefixLength = dotIndex;
    const char *suffix = string + dotIndex + 1;
    size_t suffixLength = stringLength - (dotIndex + 1);

    char *name;

    if (prefixLength == 5  &&  memcmp(prefix, "Swift", 5) == 0) {
        _objc_asprintf(&name, "_Tt%cs%zu%.*s%s",
                       isProtocol ? 'P' : 'C',
                       suffixLength, (int)suffixLength, suffix,
                       isProtocol ? "_" : "");
    } else {
        _objc_asprintf(&name, "_Tt%c%zu%.*s%zu%.*s%s",
                       isProtocol ? 'P' : 'C',
                       prefixLength, (int)prefixLength, prefix,
                       suffixLength, (int)suffixLength, suffix,
                       isProtocol ? "_" : "");
    }
    return name;
}


/***********************************************************************
* getClassExceptSomeSwift
* Looks up a class by name. The class MIGHT NOT be realized.
* Demangled Swift names are recognized.
* Classes known to the Swift runtime but not yet used are NOT recognized.
*   (such as subclasses of un-instantiated generics)
* Use look_up_class() to find them as well.
* Locking: runtimeLock must be read- or write-locked by the caller.
**********************************************************************/

// This is a misnomer: gdb_objc_realized_classes is actually a list of
// named classes not in the dyld shared cache, whether realized or not.
// This list excludes lazily named classes, which have to be looked up
// using a getClass hook.
NXMapTable *gdb_objc_realized_classes;  // exported for debuggers in objc-gdb.h
uintptr_t objc_debug_realized_class_generation_count;

template <typename T>
static T unalignedLoad(const void *ptr) {
    T value;
    memcpy(&value, ptr, sizeof(T));
    return value;
}

static unsigned namedClassTableHash(const char *name) {
#if __has_feature(ptrauth_calls)
    if (!name)
        return 0;

    // WARNING: this abuses the PAC G key to do a fast, secure string
    // hash. We currently rely on the fact that the G key is always
    // available even in ARM64 processes. If this ever changes, then
    // we'll need to conditionalize this code to fall back to the
    // regular hash function in that case.

    uint64_t hash = 0;
    size_t len = strlen(name);

    // +1 to include the trailing NULL in the hash. This avoids the possibility
    // of length extension (not that it would be feasible to do that anyway)
    // and also gives a non-zero hash to the empty string.
    size_t remaining = len + 1;

    const char *ptr = name;
    while (remaining > sizeof(uint64_t)) {
        hash = ptrauth_sign_generic_data(hash, unalignedLoad<uint64_t>(ptr));
        remaining -= sizeof(uint64_t);
        ptr += sizeof(uint64_t);
    }
    if (remaining > sizeof(uint32_t)) {
        hash = ptrauth_sign_generic_data(hash, unalignedLoad<uint32_t>(ptr));
        remaining -= sizeof(uint32_t);
        ptr += sizeof(uint32_t);
    }
    if (remaining > sizeof(uint16_t)) {
        hash = ptrauth_sign_generic_data(hash, unalignedLoad<uint16_t>(ptr));
        remaining -= sizeof(uint16_t);
        ptr += sizeof(uint16_t);
    }
    if (remaining > sizeof(uint8_t)) {
        hash = ptrauth_sign_generic_data(hash, unalignedLoad<uint8_t>(ptr));
        remaining -= sizeof(uint8_t);
        ptr += sizeof(uint8_t);
    }
    return hash >> 32;
#else
    return NXStrValueMapPrototype.hash(gdb_objc_realized_classes, name);
#endif
}

#if __has_feature(ptrauth_calls)
static unsigned namedClassTableHashCallback(NXMapTable *table, const void *key) {
    const char *name = (const char *)key;
    return namedClassTableHash(name);
}
#endif

static ptrauth_extra_data_t namedClassTableDiscriminator(unsigned hash) {
    return ptrauth_blend_discriminator((void *)(uintptr_t)hash, ptrauth_string_discriminator("gdb_objc_realized_classes"));
}

static const ptrauth_key namedClassTablePtrauthKey = ptrauth_key_process_independent_data;

static Class getClassFromNamedClassTable(const char *name) {
    unsigned hash = namedClassTableHash(name);
    void *result = (Class)NXMapGetWithHash(gdb_objc_realized_classes, name, hash);
    if (!result)
        return nullptr;

    return (Class)ptrauth_auth_data(result, namedClassTablePtrauthKey, namedClassTableDiscriminator(hash));
}

static Class getClass_impl(const char *name)
{
    lockdebug::assert_locked(&runtimeLock);

    // allocated in _read_images
    ASSERT(gdb_objc_realized_classes);

    // Try runtime-allocated table
    if (Class cls = getClassFromNamedClassTable(name))
        return cls;

    // Try table from dyld shared cache.
    // Note we do this last to handle the case where we dlopen'ed a shared cache
    // dylib with duplicates of classes already present in the main executable.
    // In that case, we put the class from the main executable in
    // gdb_objc_realized_classes and want to check that before considering any
    // newly loaded shared cache binaries.
    return getPreoptimizedClass(name);
}

static Class getClassExceptSomeSwift(const char *name)
{
    lockdebug::assert_locked(&runtimeLock);

    // Try name as-is
    Class result = getClass_impl(name);
    if (result) return result;

    // Try Swift-mangled equivalent of the given name.
    if (char *swName = copySwiftV1MangledName(name)) {
        result = getClass_impl(swName);
        free(swName);
        return result;
    }

    return nil;
}


/***********************************************************************
* addNamedClass
* Adds name => cls to the named non-meta class map.
* Warns about duplicate class names and keeps the old mapping.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void addNamedClass(Class cls, const char *name, Class replacing = nil)
{
    lockdebug::assert_locked(&runtimeLock);
    Class old;
    if ((old = getClassExceptSomeSwift(name))  &&  old != replacing) {
        inform_duplicate(name, old, cls);

        // getMaybeUnrealizedNonMetaClass uses name lookups.
        // Classes not found by name lookup must be in the
        // secondary meta->nonmeta table.
        addNonMetaClass(cls);
    } else {
        unsigned hash = namedClassTableHash(name);
        void *signedCls = ptrauth_sign_unauthenticated((void *)cls, namedClassTablePtrauthKey, namedClassTableDiscriminator(hash));
        NXMapInsertWithHash(gdb_objc_realized_classes, name, hash, signedCls);
    }
    ASSERT(!cls->isMetaClassMaybeUnrealized());

    // wrong: constructed classes are already realized when they get here
    // ASSERT(!cls->isRealized());
}

static void addNamedClass_locked(Class cls, const char *name, Class replacing = nil)
{
    mutex_locker_t lock(runtimeLock);
    addNamedClass(cls, name, replacing);
}


/***********************************************************************
* removeNamedClass
* Removes cls from the name => cls map.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void removeNamedClass(Class cls, const char *name)
{
    lockdebug::assert_locked(&runtimeLock);
    ASSERT(!(cls->bits.safe_ro()->flags & RO_META));
    if (cls == getClassFromNamedClassTable(name)) {
        NXMapRemove(gdb_objc_realized_classes, name);
    } else {
        // cls has a name collision with another class - don't remove the other
        // but do remove cls from the secondary metaclass->class map.
        removeNonMetaClass(cls);
    }
}


/***********************************************************************
* futureNamedClasses
* Returns the classname => future class map for unrealized future classes.
* WARNING: Symbolication knows about future_named_class_map. Any changes must
* be coordinated.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static NXMapTable *future_named_class_map = nil;
OBJC_EXTERN void *const _Nonnull objc_debug_future_named_class_map = &future_named_class_map;
static NXMapTable *futureNamedClasses()
{
    lockdebug::assert_locked(&runtimeLock);

    if (future_named_class_map) return future_named_class_map;

    // future_named_class_map is big enough for CF's classes and a few others
    future_named_class_map =
        NXCreateMapTable(NXStrValueMapPrototype, 32);

    return future_named_class_map;
}


static bool haveFutureNamedClasses() {
    return future_named_class_map  &&  NXCountMapTable(future_named_class_map);
}


/***********************************************************************
* addFutureNamedClass
* Installs cls as the class structure to use for the named class if it appears.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void addFutureNamedClass(const char *name, Class cls)
{
    void *old;

    lockdebug::assert_locked(&runtimeLock);

    if (PrintFuture) {
        _objc_inform("FUTURE: reserving %p for %s", (void*)cls, name);
    }

    class_rw_t *rw = objc::zalloc<class_rw_t>();
    class_ro_t *ro = (class_ro_t *)calloc(sizeof(class_ro_t), 1);
    ro->name.store(strdupIfMutable(name), std::memory_order_relaxed);
    rw->set_ro(ro);
    cls->setData(rw);
    cls->data()->flags = RO_FUTURE;

    old = NXMapKeyCopyingInsert(futureNamedClasses(), name, cls);
    ASSERT(!old);
}


/***********************************************************************
* popFutureNamedClass
* Removes the named class from the unrealized future class list,
* because it has been realized.
* Returns nil if the name is not used by a future class.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static Class popFutureNamedClass(const char *name)
{
    lockdebug::assert_locked(&runtimeLock);

    Class cls = nil;

    if (future_named_class_map) {
        cls = (Class)NXMapKeyFreeingRemove(future_named_class_map, name);
        if (cls && NXCountMapTable(future_named_class_map) == 0) {
            NXFreeMapTable(future_named_class_map);
            future_named_class_map = nil;
        }
    }

    return cls;
}


/***********************************************************************
* remappedClasses
* Returns the oldClass => newClass map for realized future classes.
* Returns the oldClass => nil map for ignored weak-linked classes.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static objc::DenseMap<Class, Class> *remappedClasses(bool create)
{
    static objc::LazyInitDenseMap<Class, Class> remapped_class_map;

    lockdebug::assert_locked(&runtimeLock);

    // start big enough to hold CF's classes and a few others
    return remapped_class_map.get(create, 32);
}


/***********************************************************************
* noClassesRemapped
* Returns YES if no classes have been remapped
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static bool noClassesRemapped(void)
{
    lockdebug::assert_locked(&runtimeLock);

    bool result = (remappedClasses(NO) == nil);
#if DEBUG
    // Catch construction of an empty table, which defeats optimization.
    auto *map = remappedClasses(NO);
    if (map) ASSERT(map->size() > 0);
#endif
    return result;
}


/***********************************************************************
* addRemappedClass
* newcls is a realized future class, replacing oldcls.
* OR newcls is nil, replacing ignored weak-linked class oldcls.
* Locking: runtimeLock must be write-locked by the caller
**********************************************************************/
static void addRemappedClass(Class oldcls, Class newcls)
{
    lockdebug::assert_locked(&runtimeLock);

    if (PrintFuture) {
        _objc_inform("FUTURE: using %p instead of %p for %s",
                     (void*)newcls, (void*)oldcls, oldcls->nameForLogging());
    }

    auto result = remappedClasses(YES)->insert({ oldcls, newcls });
#if DEBUG
    if (!std::get<1>(result)) {
        // An existing mapping was overwritten. This is not allowed
        // unless it was to nil.
        auto iterator = std::get<0>(result);
        auto value = std::get<1>(*iterator);
        ASSERT(value == nil);
    }
#else
    (void)result;
#endif
}


/***********************************************************************
* remapClass
* Returns the live class pointer for cls, which may be pointing to
* a class struct that has been reallocated.
* Returns nil if cls is ignored because of weak linking.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static Class remapClass(Class cls)
{
    lockdebug::assert_locked(&runtimeLock);

    if (!cls) return nil;

    auto *map = remappedClasses(NO);
    if (!map)
        return cls;

    auto iterator = map->find(cls);
    if (iterator == map->end())
        return cls;
    return std::get<1>(*iterator);
}

static Class remapClass(classref_t cls)
{
    return remapClass((Class)cls);
}

Class _class_remap(Class cls)
{
    mutex_locker_t lock(runtimeLock);
    return remapClass(cls);
}

/***********************************************************************
* remapClassRef
* Fix up a class ref, in case the class referenced has been reallocated
* or is an ignored weak-linked class.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static void remapClassRef(Class *clsref)
{
    lockdebug::assert_locked(&runtimeLock);

    Class newcls = remapClass(*clsref);
    if (*clsref != newcls) *clsref = newcls;
}


_Nullable Class
objc_loadClassref(_Nullable Class * _Nonnull clsref)
{
    auto *atomicClsref = explicit_atomic<uintptr_t>::from_pointer((uintptr_t *)clsref);

    uintptr_t cls = atomicClsref->load(std::memory_order_relaxed);
    if (fastpath((cls & 1) == 0))
        return (Class)cls;

    auto stub = (stub_class_t *)(cls & ~1ULL);
    Class initialized = stub->initializer((Class)stub, nil);
    atomicClsref->store((uintptr_t)initialized, std::memory_order_relaxed);
    return initialized;
}


/***********************************************************************
* getMaybeUnrealizedNonMetaClass
* Return the ordinary class for this class or metaclass.
* `inst` is an instance of `cls` or a subclass thereof, or nil.
* Non-nil inst is faster.
* The result may be unrealized.
* Used by +initialize.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static Class getMaybeUnrealizedNonMetaClass(Class metacls, id inst)
{
    static int total, named, secondary, sharedcache, dyld3;
    lockdebug::assert_locked(&runtimeLock);
    ASSERT(metacls->isRealized());

    total++;

    // return cls itself if it's already a non-meta class
    if (!metacls->isMetaClass()) return metacls;

    // metacls really is a metaclass
    // which means inst (if any) is a class

    // special case for root metaclass
    // where inst == inst->ISA() == metacls is possible
    if (metacls->ISA() == metacls) {
        Class cls = metacls->getSuperclass();
        ASSERT(cls->isRealized());
        ASSERT(!cls->isMetaClass());
        ASSERT(cls->ISA() == metacls);
        if (cls->ISA() == metacls) return cls;
    }

    // use inst if available
    if (inst) {
        Class cls = remapClass((Class)inst);
        // cls may be a subclass - find the real class for metacls
        // fixme this probably stops working once Swift starts
        // reallocating classes if cls is unrealized.
        while (cls) {
            if (cls->ISA() == metacls) {
                ASSERT(!cls->isMetaClassMaybeUnrealized());
                return cls;
            }
            cls = cls->getSuperclass();
        }
#if DEBUG
        _objc_fatal("cls is not an instance of metacls");
#else
        // release build: be forgiving and fall through to slow lookups
#endif
    }

    // See if the metaclass has a pointer to its nonmetaclass.
    if (Class cls = metacls->bits.safe_ro()->getNonMetaclass())
        return cls;

    // try name lookup
    {
        Class cls = getClassExceptSomeSwift(metacls->mangledName());
        if (cls && cls->ISA() == metacls) {
            named++;
            if (PrintInitializing) {
                _objc_inform("INITIALIZE: %d/%d (%g%%) "
                             "successful by-name metaclass lookups",
                             named, total, named*100.0/total);
            }
            return cls;
        }
    }

    // try secondary table
    {
        Class cls = (Class)NXMapGet(nonMetaClasses(), metacls);
        if (cls) {
            secondary++;
            if (PrintInitializing) {
                _objc_inform("INITIALIZE: %d/%d (%g%%) "
                             "successful secondary metaclass lookups",
                             secondary, total, secondary*100.0/total);
            }

            ASSERT(cls->ISA() == metacls);
            return cls;
        }
    }

    if (Class cls = getPreoptimizedClassesWithMetaClass(metacls)) {
        if (PrintInitializing) {
            if (objc::inSharedCache((uintptr_t)cls)) {
                sharedcache++;
                _objc_inform("INITIALIZE: %d/%d (%g%%) "
                             "successful shared cache metaclass lookups",
                             sharedcache, total, sharedcache*100.0/total);
            } else {
                dyld3++;
                _objc_inform("INITIALIZE: %d/%d (%g%%) "
                             "successful dyld closure metaclass lookups",
                             dyld3, total, dyld3*100.0/total);
            }
        }

        return cls;
    }

    _objc_fatal("no class for metaclass %p", (void*)metacls);
}


/***********************************************************************
* class_initialize.  Send the '+initialize' message on demand to any
* uninitialized class. Force initialization of superclasses first.
* inst is an instance of cls, or nil. Non-nil is better for performance.
* Returns the class pointer. If the class was unrealized then
* it may be reallocated.
* Locking:
*   runtimeLock must be held by the caller
*   This function may drop the lock.
*   On exit the lock is re-acquired or dropped as requested by leaveLocked.
**********************************************************************/
static Class initializeAndMaybeRelock(Class cls, id inst,
                                      mutex_t& lock, bool leaveLocked)
{
    lockdebug::assert_locked(&lock);
    ASSERT(cls->isRealized());

    if (cls->isInitialized()) {
        if (!leaveLocked) lock.unlock();
        return cls;
    }

    // Find the non-meta class for cls, if it is not already one.
    // The +initialize message is sent to the non-meta class object.
    Class nonmeta = getMaybeUnrealizedNonMetaClass(cls, inst);

    // Realize the non-meta class if necessary.
    if (nonmeta->isRealized()) {
        // nonmeta is cls, which was already realized
        // OR nonmeta is distinct, but is already realized
        // - nothing else to do
        lock.unlock();
    } else {
        nonmeta = realizeClassMaybeSwiftAndUnlock(nonmeta, lock);
        // runtimeLock is now unlocked
        // fixme Swift can't relocate the class today,
        // but someday it will:
        cls = object_getClass(nonmeta);
    }

    // runtimeLock is now unlocked, for +initialize dispatch
    ASSERT(nonmeta->isRealized());
    initializeNonMetaClass(nonmeta);

    if (leaveLocked) runtimeLock.lock();
    return cls;
}

// Locking: acquires runtimeLock
Class class_initialize(Class cls, id obj)
{
    runtimeLock.lock();
    return initializeAndMaybeRelock(cls, obj, runtimeLock, false);
}

// Locking: caller must hold runtimeLock; this may drop and re-acquire it
static Class initializeAndLeaveLocked(Class cls, id obj, mutex_t& lock)
{
    return initializeAndMaybeRelock(cls, obj, lock, true);
}


/***********************************************************************
* addRootClass
* Adds cls as a new realized root class.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void addRootClass(Class cls)
{
    lockdebug::assert_locked(&runtimeLock);

    ASSERT(cls->isRealized());

    objc_debug_realized_class_generation_count++;

    cls->data()->nextSiblingClass = _firstRealizedClass;
    _firstRealizedClass = cls;
}

static void removeRootClass(Class cls)
{
    lockdebug::assert_locked(&runtimeLock);

    objc_debug_realized_class_generation_count++;

    Class *classp;
    for (classp = &_firstRealizedClass;
         *classp != cls;
         classp = &(*classp)->data()->nextSiblingClass)
    { }

    *classp = (*classp)->data()->nextSiblingClass;
}


/***********************************************************************
* addSubclass
* Adds subcls as a subclass of supercls.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void addSubclass(Class supercls, Class subcls)
{
    lockdebug::assert_locked(&runtimeLock);

    if (supercls  &&  subcls) {
        ASSERT(supercls->isRealized());
        ASSERT(subcls->isRealized());

        objc_debug_realized_class_generation_count++;

        subcls->data()->nextSiblingClass = supercls->data()->firstSubclass;
        supercls->data()->firstSubclass = subcls;

        if (supercls->hasCxxCtor()) {
            subcls->setHasCxxCtor();
        }

        if (supercls->hasCxxDtor()) {
            subcls->setHasCxxDtor();
        }

        if (supercls->hasCustomDeallocInitiation())
            subcls->setHasCustomDeallocInitiation();

        objc::Scanner::scanAddedSubClass(subcls, supercls);

        if (!supercls->allowsPreoptCaches()) {
            subcls->setDisallowPreoptCachesRecursively(__func__);
        } else if (!supercls->allowsPreoptInlinedSels()) {
            subcls->setDisallowPreoptInlinedSelsRecursively(__func__);
        }

        // Special case: instancesRequireRawIsa does not propagate
        // from root class to root metaclass
        if (supercls->instancesRequireRawIsa()  &&  supercls->getSuperclass()) {
            subcls->setInstancesRequireRawIsaRecursively(true);
        }
    }
}


/***********************************************************************
* removeSubclass
* Removes subcls as a subclass of supercls.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void removeSubclass(Class supercls, Class subcls)
{
    lockdebug::assert_locked(&runtimeLock);
    ASSERT(supercls->isRealized());
    ASSERT(subcls->isRealized());
    ASSERT(subcls->getSuperclass() == supercls);

    objc_debug_realized_class_generation_count++;

    Class *cp;
    for (cp = &supercls->data()->firstSubclass;
         *cp  &&  *cp != subcls;
         cp = &(*cp)->data()->nextSiblingClass)
        ;
    ASSERT(*cp == subcls);
    *cp = subcls->data()->nextSiblingClass;
}



/***********************************************************************
* protocols
* Returns the protocol name => protocol map for protocols.
* Locking: runtimeLock must read- or write-locked by the caller
**********************************************************************/
static NXMapTable *protocols(void)
{
    static NXMapTable *protocol_map = nil;

    lockdebug::assert_locked(&runtimeLock);

    INIT_ONCE_PTR(protocol_map,
                  NXCreateMapTable(NXStrValueMapPrototype, 16),
                  NXFreeMapTable(v) );

    return protocol_map;
}


/***********************************************************************
* getProtocol
* Looks up a protocol by name. Demangled Swift names are recognized.
* Locking: runtimeLock must be read- or write-locked by the caller.
**********************************************************************/
static NEVER_INLINE Protocol *getProtocol(const char *name)
{
    lockdebug::assert_locked(&runtimeLock);

    // Try name as-is.
    Protocol *result = (Protocol *)NXMapGet(protocols(), name);
    if (result) return result;

    // Try table from dyld3 closure and dyld shared cache
    result = getPreoptimizedProtocol(name);
    if (result) return result;

    // Try Swift-mangled equivalent of the given name.
    if (char *swName = copySwiftV1MangledName(name, true/*isProtocol*/)) {
        result = (Protocol *)NXMapGet(protocols(), swName);

        // Try table from dyld3 closure and dyld shared cache
        if (!result)
            result = getPreoptimizedProtocol(swName);

        free(swName);
        return result;
    }

    return nullptr;
}


/***********************************************************************
* remapProtocol
* Returns the live protocol pointer for proto, which may be pointing to
* a protocol struct that has been reallocated.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static ALWAYS_INLINE protocol_t *remapProtocol(protocol_ref_t proto)
{
    lockdebug::assert_locked(&runtimeLock);

    // Protocols in shared cache images have a canonical bit to mark that they
    // are the definition we should use
    if (((protocol_t *)proto)->isCanonical())
        return (protocol_t *)proto;

    protocol_t *newproto = (protocol_t *)
        getProtocol(((protocol_t *)proto)->mangledName);
    return newproto ? newproto : (protocol_t *)proto;
}


/***********************************************************************
* remapProtocolRef
* Fix up a protocol ref, in case the protocol referenced has been reallocated.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static size_t UnfixedProtocolReferences;
static void remapProtocolRef(protocol_t **protoref)
{
    lockdebug::assert_locked(&runtimeLock);

    protocol_t *newproto = remapProtocol((protocol_ref_t)*protoref);
    if (*protoref != newproto) {
        *protoref = newproto;
        UnfixedProtocolReferences++;
    }
}


/***********************************************************************
* moveIvars
* Slides a class's ivars to accommodate the given superclass size.
* Ivars are NOT compacted to compensate for a superclass that shrunk.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void moveIvars(class_ro_t *ro, uint32_t superSize)
{
    lockdebug::assert_locked(&runtimeLock);

    uint32_t diff;

    ASSERT(superSize > ro->instanceStart);
    diff = superSize - ro->instanceStart;

    if (ro->ivars) {
        // Find maximum alignment in this class's ivars
        uint32_t maxAlignment = 1;
        for (const auto& ivar : *ro->ivars) {
            if (!ivar.offset) continue;  // anonymous bitfield

            uint32_t alignment = ivar.alignment();
            if (alignment > maxAlignment) maxAlignment = alignment;
        }

        // Compute a slide value that preserves that alignment
        uint32_t alignMask = maxAlignment - 1;
        diff = (diff + alignMask) & ~alignMask;

        // Slide all of this class's ivars en masse
        for (const auto& ivar : *ro->ivars) {
            if (!ivar.offset) continue;  // anonymous bitfield

            uint32_t oldOffset = (uint32_t)*ivar.offset;
            uint32_t newOffset = oldOffset + diff;
            *ivar.offset = newOffset;

            if (PrintIvars) {
                _objc_inform("IVARS:    offset %u -> %u for %s "
                             "(size %u, align %u)",
                             oldOffset, newOffset, ivar.name,
                             ivar.size, ivar.alignment());
            }
        }
    }

    *(uint32_t *)&ro->instanceStart += diff;
    *(uint32_t *)&ro->instanceSize += diff;
}


static void reconcileInstanceVariables(Class cls, Class supercls, const class_ro_t*& ro)
{
    class_rw_t *rw = cls->data();

    ASSERT(supercls);
    ASSERT(!cls->isMetaClass());

    /* debug: print them all before sliding
    if (ro->ivars) {
        for (const auto& ivar : *ro->ivars) {
            if (!ivar.offset) continue;  // anonymous bitfield

            _objc_inform("IVARS: %s.%s (offset %u, size %u, align %u)",
                         ro->name, ivar.name,
                         *ivar.offset, ivar.size, ivar.alignment());
        }
    }
    */

    // Non-fragile ivars - reconcile this class with its superclass
    const class_ro_t *super_ro = supercls->data()->ro();

    if (DebugNonFragileIvars) {
        // Debugging: Force non-fragile ivars to slide.
        // Intended to find compiler, runtime, and program bugs.
        // If it fails with this and works without, you have a problem.

        // Operation: Reset everything to 0 + misalignment.
        // Then force the normal sliding logic to push everything back.

        // Exceptions: root classes, metaclasses, *NSCF* classes,
        // __CF* classes, NSConstantString, NSSimpleCString

        // (already know it's not root because supercls != nil)
        const char *clsname = cls->mangledName();
        if (!strstr(clsname, "NSCF")  &&
            0 != strncmp(clsname, "__CF", 4)  &&
            0 != strcmp(clsname, "NSConstantString")  &&
            0 != strcmp(clsname, "NSSimpleCString"))
        {
            uint32_t oldStart = ro->instanceStart;
            class_ro_t *ro_w = make_ro_writeable(rw);
            ro = rw->ro();

            // Find max ivar alignment in class.
            // default to word size to simplify ivar update
            uint32_t alignment = 1<<WORD_SHIFT;
            if (ro->ivars) {
                for (const auto& ivar : *ro->ivars) {
                    if (ivar.alignment() > alignment) {
                        alignment = ivar.alignment();
                    }
                }
            }
            uint32_t misalignment = ro->instanceStart % alignment;
            uint32_t delta = ro->instanceStart - misalignment;
            ro_w->instanceStart = misalignment;
            ro_w->instanceSize -= delta;

            if (PrintIvars) {
                _objc_inform("IVARS: DEBUG: forcing ivars for class '%s' "
                             "to slide (instanceStart %zu -> %zu)",
                             cls->nameForLogging(), (size_t)oldStart,
                             (size_t)ro->instanceStart);
            }

            if (ro->ivars) {
                for (const auto& ivar : *ro->ivars) {
                    if (!ivar.offset) continue;  // anonymous bitfield
                    *ivar.offset -= delta;
                }
            }
        }
    }

    if (ro->instanceStart >= super_ro->instanceSize) {
        // Superclass has not overgrown its space. We're done here.
        return;
    }
    // fixme can optimize for "class has no new ivars", etc

    if (ro->instanceStart < super_ro->instanceSize) {
        // Superclass has changed size. This class's ivars must move.
        // Also slide layout bits in parallel.
        // This code is incapable of compacting the subclass to
        //   compensate for a superclass that shrunk, so don't do that.
        if (PrintIvars) {
            _objc_inform("IVARS: sliding ivars for class %s "
                         "(superclass was %u bytes, now %u)",
                         cls->nameForLogging(), ro->instanceStart,
                         super_ro->instanceSize);
        }
        class_ro_t *ro_w = make_ro_writeable(rw);
        ro = rw->ro();
        moveIvars(ro_w, super_ro->instanceSize);
        gdb_objc_class_changed(cls, OBJC_CLASS_IVARS_CHANGED, ro->getName());
    }
}

static void validateAlreadyRealizedClass(Class cls) {
    ASSERT(cls->isRealized());
#if TARGET_OS_OSX
    class_rw_t *rw = cls->data();
    size_t rwSize = malloc_size(rw);

    if (rwSize < sizeof(class_rw_t))
        _objc_fatal("realized class %p has corrupt data pointer: malloc_size(%p) = %zu", cls, rw, rwSize);
#endif
}

/***********************************************************************
* realizeClassWithoutSwift
* Performs first-time initialization on class cls,
* including allocating its read-write data.
* Does not perform any Swift-side initialization.
* Returns the real class structure for the class.
* Locking: runtimeLock must be write-locked by the caller
**********************************************************************/
static Class realizeClassWithoutSwift(Class cls, Class previously)
{
    lockdebug::assert_locked(&runtimeLock);

    class_rw_t *rw;
    Class supercls;
    Class metacls;

    if (!cls) return nil;
    if (cls->isRealized()) {
        validateAlreadyRealizedClass(cls);
        return cls;
    }
    ASSERT(cls == remapClass(cls));

    // fixme verify class is not in an un-dlopened part of the shared cache?

    auto ro = cls->safe_ro();
    auto isMeta = ro->flags & RO_META;
    if (ro->flags & RO_FUTURE) {
        // This was a future class. rw data is already allocated.
        rw = cls->data();
        ro = cls->data()->ro();
        ASSERT(!isMeta);
        cls->changeInfo(RW_REALIZED|RW_REALIZING, RW_FUTURE);
    } else {
        // Normal class. Allocate writeable class data.
        rw = objc::zalloc<class_rw_t>();
        rw->set_ro(ro);
        rw->flags = RW_REALIZED|RW_REALIZING|isMeta;
        cls->setData(rw);
    }

    cls->cache.initializeToEmptyOrPreoptimizedInDisguise();

#if FAST_CACHE_META
    if (isMeta) cls->cache.setBit(FAST_CACHE_META);
#endif

    // Choose an index for this class.
    // Sets cls->instancesRequireRawIsa if indexes no more indexes are available
    cls->chooseClassArrayIndex();

    if (PrintConnecting) {
        _objc_inform("CLASS: realizing class '%s'%s %p %p #%u %s%s",
                     cls->nameForLogging(), isMeta ? " (meta)" : "",
                     (void*)cls, ro, cls->classArrayIndex(),
                     cls->isSwiftStable() ? "(swift)" : "",
                     cls->isSwiftLegacy() ? "(pre-stable swift)" : "");
    }

    // Realize superclass and metaclass, if they aren't already.
    // This needs to be done after RW_REALIZED is set above, for root classes.
    // This needs to be done after class index is chosen, for root metaclasses.
    // This assumes that none of those classes have Swift contents,
    //   or that Swift's initializers have already been called.
    //   fixme that assumption will be wrong if we add support
    //   for ObjC subclasses of Swift classes.
    supercls = realizeClassWithoutSwift(remapClass(cls->getSuperclass()), nil);
    metacls = realizeClassWithoutSwift(remapClass(cls->ISA()), nil);

#if SUPPORT_NONPOINTER_ISA
    if (isMeta) {
        // Metaclasses do not need any features from non pointer ISA
        // This allows for a faspath for classes in objc_retain/objc_release.
        cls->setInstancesRequireRawIsa();
    } else {
        // Disable non-pointer isa for some classes and/or platforms.
        // Set instancesRequireRawIsa.
        bool instancesRequireRawIsa = cls->instancesRequireRawIsa();
        bool rawIsaIsInherited = false;
        static bool hackedDispatch = false;
        const char *name;

        if (DisableNonpointerIsa) {
            // Non-pointer isa disabled by environment or app SDK version
            instancesRequireRawIsa = true;
        }
        else if (!hackedDispatch
                 && (name = ro->getName()) // Yes, we mean to assign here
                 && 0 == strcmp(name, "OS_object"))
        {
            // hack for libdispatch et al - isa also acts as vtable pointer
            hackedDispatch = true;
            instancesRequireRawIsa = true;
        }
        else if (supercls  &&  supercls->getSuperclass()  &&
                 supercls->instancesRequireRawIsa())
        {
            // This is also propagated by addSubclass()
            // but nonpointer isa setup needs it earlier.
            // Special case: instancesRequireRawIsa does not propagate
            // from root class to root metaclass
            instancesRequireRawIsa = true;
            rawIsaIsInherited = true;
        }

        if (instancesRequireRawIsa) {
            cls->setInstancesRequireRawIsaRecursively(rawIsaIsInherited);
        }
    }
// SUPPORT_NONPOINTER_ISA
#endif

    // Update superclass and metaclass in case of remapping
    cls->setSuperclass(supercls);
    cls->initClassIsa(metacls);

    // Reconcile instance variable offsets / layout.
    // This may reallocate class_ro_t, updating our ro variable.
    if (supercls  &&  !isMeta) reconcileInstanceVariables(cls, supercls, ro);

    // Set fastInstanceSize if it wasn't set already.
    cls->setInstanceSize(ro->instanceSize);

    // Copy some flags from ro to rw
    if (ro->flags & RO_HAS_CXX_STRUCTORS) {
        cls->setHasCxxDtor();
        if (! (ro->flags & RO_HAS_CXX_DTOR_ONLY)) {
            cls->setHasCxxCtor();
        }
    }

    // Propagate the associated objects forbidden flag from ro or from
    // the superclass.
    if ((ro->flags & RO_FORBIDS_ASSOCIATED_OBJECTS) ||
        (supercls && supercls->forbidsAssociatedObjects()))
    {
        rw->flags |= RW_FORBIDS_ASSOCIATED_OBJECTS;
    }

    // Connect this class to its superclass's subclass lists
    if (supercls) {
        addSubclass(supercls, cls);
    } else {
        addRootClass(cls);
    }

    // Attach categories
    methodizeClass(cls, previously);

    return cls;
}


/***********************************************************************
* _objc_realizeClassFromSwift
* Called by Swift when it needs the ObjC part of a class to be realized.
* There are four cases:
* 1. cls != nil; previously == cls
*    Class cls is being realized in place
* 2. cls != nil; previously == nil
*    Class cls is being constructed at runtime
* 3. cls != nil; previously != cls
*    The class that was at previously has been reallocated to cls
* 4. cls == nil, previously != nil
*    The class at previously is hereby disavowed
*
* Only variants #1 and #2 are supported today.
*
* Locking: acquires runtimeLock
**********************************************************************/
Class _objc_realizeClassFromSwift(Class cls, void *previously)
{
    if (cls) {
        if (previously && previously != (void*)cls) {
            // #3: relocation
            mutex_locker_t lock(runtimeLock);
            addRemappedClass((Class)previously, cls);
            addClassTableEntry(cls);
            addNamedClass(cls, cls->mangledName(), /*replacing*/nil);
            return realizeClassWithoutSwift(cls, (Class)previously);
        } else {
            // #1 and #2: realization in place, or new class
            mutex_locker_t lock(runtimeLock);

            if (!previously) {
                // #2: new class
                cls = readClass(cls, false/*bundle*/, false/*shared cache*/);
            }

            // #1 and #2: realization in place, or new class
            // We ignore the Swift metadata initializer callback.
            // We assume that's all handled since we're being called from Swift.
            return realizeClassWithoutSwift(cls, nil);
        }
    }
    else {
        // #4: disavowal
        // In the future this will mean remapping the old address to nil
        // and if necessary removing the old address from any other tables.
        _objc_fatal("Swift requested that class %p be ignored, "
                    "but libobjc does not support that.", previously);
    }
}

/***********************************************************************
* realizeSwiftClass
* Performs first-time initialization on class cls,
* including allocating its read-write data,
* and any Swift-side initialization.
* Returns the real class structure for the class.
* Locking: acquires runtimeLock indirectly
**********************************************************************/
static Class realizeSwiftClass(Class cls)
{
    lockdebug::assert_unlocked(&runtimeLock);

    // Some assumptions:
    // * Metaclasses never have a Swift initializer.
    // * Root classes never have a Swift initializer.
    //   (These two together avoid initialization order problems at the root.)
    // * Unrealized non-Swift classes have no Swift ancestry.
    // * Unrealized Swift classes with no initializer have no ancestry that
    //   does have the initializer.
    //   (These two together mean we don't need to scan superclasses here
    //   and we don't need to worry about Swift superclasses inside
    //   realizeClassWithoutSwift()).

    // fixme some of these assumptions will be wrong
    // if we add support for ObjC sublasses of Swift classes.

#if DEBUG
    runtimeLock.lock();
    ASSERT(remapClass(cls) == cls);
    ASSERT(cls->isSwiftStable_ButAllowLegacyForNow());
    ASSERT(!cls->isMetaClassMaybeUnrealized());
    ASSERT(cls->getSuperclass());
    runtimeLock.unlock();
#endif

    // Look for a Swift metadata initialization function
    // installed on the class. If it is present we call it.
    // That function in turn initializes the Swift metadata,
    // prepares the "compiler-generated" ObjC metadata if not
    // already present, and calls _objc_realizeSwiftClass() to finish
    // our own initialization.

    if (auto init = cls->swiftMetadataInitializer()) {
        if (PrintConnecting) {
            _objc_inform("CLASS: calling Swift metadata initializer "
                         "for class '%s' (%p)", cls->nameForLogging(), cls);
        }

        Class newcls = init(cls, nil);

        if (cls != newcls) {
            mutex_locker_t lock(runtimeLock);
            addRemappedClass(cls, newcls);
        }

        return newcls;
    }
    else {
        // No Swift-side initialization callback.
        // Perform our own realization directly.
        mutex_locker_t lock(runtimeLock);
        return realizeClassWithoutSwift(cls, nil);
    }
}


/***********************************************************************
* realizeClassMaybeSwift (MaybeRelock / AndUnlock / AndLeaveLocked)
* Realize a class that might be a Swift class.
* Returns the real class structure for the class.
* Locking:
*   runtimeLock must be held on entry
*   runtimeLock may be dropped during execution
*   ...AndUnlock function leaves runtimeLock unlocked on exit
*   ...AndLeaveLocked re-acquires runtimeLock if it was dropped
* This complication avoids repeated lock transitions in some cases.
**********************************************************************/
static Class
realizeClassMaybeSwiftMaybeRelock(Class cls, mutex_t& lock, bool leaveLocked)
{
    lockdebug::assert_locked(&lock);

    if (!cls->isSwiftStable_ButAllowLegacyForNow()) {
        // Non-Swift class. Realize it now with the lock still held.
        // fixme wrong in the future for objc subclasses of swift classes
        realizeClassWithoutSwift(cls, nil);
        if (!leaveLocked) lock.unlock();
    } else {
        // Swift class. We need to drop locks and call the Swift
        // runtime to initialize it.
        lock.unlock();
        cls = realizeSwiftClass(cls);
        ASSERT(cls->isRealized());    // callback must have provoked realization
        if (leaveLocked) lock.lock();
    }

    return cls;
}

static Class
realizeClassMaybeSwiftAndUnlock(Class cls, mutex_t& lock)
{
    return realizeClassMaybeSwiftMaybeRelock(cls, lock, false);
}

static Class
realizeClassMaybeSwiftAndLeaveLocked(Class cls, mutex_t& lock)
{
    return realizeClassMaybeSwiftMaybeRelock(cls, lock, true);
}


/***********************************************************************
* missingWeakSuperclass
* Return YES if some superclass of cls was weak-linked and is missing.
**********************************************************************/
static bool
missingWeakSuperclass(Class cls)
{
    ASSERT(!cls->isRealized());

    if (!cls->getSuperclass()) {
        // superclass nil. This is normal for root classes only.
        return (!(cls->safe_ro()->flags & RO_ROOT));
    } else {
        // superclass not nil. Check if a higher superclass is missing.
        Class supercls = remapClass(cls->getSuperclass());
        ASSERT(cls != cls->getSuperclass());
        ASSERT(cls != supercls);
        if (!supercls) return YES;
        if (supercls->isRealized()) return NO;
        return missingWeakSuperclass(supercls);
    }
}


/***********************************************************************
* realizeAllClassesInImage
* Non-lazily realizes all unrealized classes in the given image.
* Locking: runtimeLock must be held by the caller.
* Locking: this function may drop and re-acquire the lock.
**********************************************************************/
static void realizeAllClassesInImage(header_info *hi)
{
    lockdebug::assert_locked(&runtimeLock);

    size_t count, i;
    classref_t const *classlist;

    classlist = hi->classlist(&count);

    for (i = 0; i < count; i++) {
        Class cls = remapClass(classlist[i]);
        if (cls) {
            realizeClassMaybeSwiftAndLeaveLocked(cls, runtimeLock);
        }
    }

    stub_class_t * const *stublist = hi->stublist(&count);
    for (i = 0; i < count; i++) {
        // Only call the initiaizer if the class hasn't already been
        // initialized. Initialized stubs are always remapped, so
        // only call the initializer if there's no remapping.
        if (remapClass((Class)stublist[i]) == (Class)stublist[i]) {
            // Drop the lock while calling the initializer, it will
            // probably call back into libobjc.
            runtimeLock.unlock();
            stublist[i]->initializer((Class)stublist[i], nil);
            runtimeLock.lock();
        }
    }
}


/***********************************************************************
* realizeAllClasses
* Non-lazily realizes all unrealized classes in all known images.
* Locking: runtimeLock must be held by the caller.
* Locking: this function may drop and re-acquire the lock.
* Dropping the lock makes this function thread-unsafe with respect
*   to concurrent image unload, but the callers of this function
*   already ultimately do something that is also thread-unsafe with
*   respect to image unload (such as using the list of all classes).
**********************************************************************/
static void realizeAllClasses(void)
{
    lockdebug::assert_locked(&runtimeLock);

    // Skip headers until we locate LastHeaderRealizedAllClasses. If it's NULL
    // then we don't skip any.
    header_info *hi = FirstHeader;
    if (LastHeaderRealizedAllClasses)
        while (hi && hi != LastHeaderRealizedAllClasses)
            hi = hi->getNext();

    for (; hi; hi = hi->getNext()) {
        realizeAllClassesInImage(hi);  // may drop and re-acquire runtimeLock

        // This header is now the last one that had all classes realized. It's
        // possible that this is incorrect and moves the marker backwards, if
        // some other thread came through and moved it forward while we dropped
        // the runtimeLock above. That's OK, this is just an optimization, and
        // it will self-repair the next time through.
        LastHeaderRealizedAllClasses = hi;
    }
}


/***********************************************************************
* _objc_allocateFutureClass
* Allocate an unresolved future class for the given class name.
* Returns any existing allocation if one was already made.
* Assumes the named class doesn't exist yet.
* Locking: acquires runtimeLock
**********************************************************************/
Class _objc_allocateFutureClass(const char *name)
{
    mutex_locker_t lock(runtimeLock);

    Class cls;
    NXMapTable *map = futureNamedClasses();

    if ((cls = (Class)NXMapGet(map, name))) {
        // Already have a future class for this name.
        return cls;
    }

    cls = _calloc_class(sizeof(objc_class));
    addFutureNamedClass(name, cls);

    return cls;
}


/***********************************************************************
* objc_getFutureClass.  Return the id of the named class.
* If the class does not exist, return an uninitialized class
* structure that will be used for the class when and if it
* does get loaded.
* Not thread safe.
**********************************************************************/
Class objc_getFutureClass(const char *name)
{
    Class cls;

    // YES unconnected, NO class handler
    // (unconnected is OK because it will someday be the real class)
    cls = look_up_class(name, YES, NO);
    if (cls) {
        if (PrintFuture) {
            _objc_inform("FUTURE: found %p already in use for %s",
                         (void*)cls, name);
        }

        return cls;
    }

    // No class or future class with that name yet. Make one.
    // fixme not thread-safe with respect to
    // simultaneous library load or getFutureClass.
    return _objc_allocateFutureClass(name);
}


BOOL _class_isFutureClass(Class cls)
{
    return cls  &&  cls->isFuture();
}

BOOL _class_isSwift(Class _Nullable cls)
{
    return cls && cls->isSwiftStable();
}

/***********************************************************************
* _objc_flush_caches
* Flushes all caches.
* (Historical behavior: flush caches for cls, its metaclass,
* and subclasses thereof. Nil flushes all classes.)
* Locking: acquires runtimeLock
**********************************************************************/
static void flushCaches(Class cls, const char *func, bool (^predicate)(Class))
{
    lockdebug::assert_locked(&runtimeLock);
#if CONFIG_USE_CACHE_LOCK
    mutex_locker_t lock(cacheUpdateLock);
#endif

    const auto handler = ^(Class c) {
        if (predicate(c)) {
            c->cache.eraseNolock(func);
        }

        return true;
    };

    // dtrace probe
    OBJC_RUNTIME_CACHE_FLUSH(cls);

    if (cls) {
        foreach_realized_class_and_subclass(cls, handler);
    } else {
        foreach_realized_class_and_metaclass(handler);
    }
}


void _objc_flush_caches(Class cls)
{
    {
        mutex_locker_t lock(runtimeLock);
        flushCaches(cls, __func__, [](Class c){
            return !c->cache.isConstantOptimizedCache();
        });
        if (cls && !cls->isMetaClass() && !cls->isRootClass()) {
            flushCaches(cls->ISA(), __func__, [](Class c){
                return !c->cache.isConstantOptimizedCache();
            });
        } else {
            // cls is a root class or root metaclass. Its metaclass is itself
            // or a subclass so the metaclass caches were already flushed.
        }
    }

    if (!cls) {
        // collectALot if cls==nil
#if CONFIG_USE_CACHE_LOCK
        mutex_locker_t lock(cacheUpdateLock);
#else
        mutex_locker_t lock(runtimeLock);
#endif
        cache_t::collectNolock(true);
    }
}

/***********************************************************************
* is_root_ramdisk
* Returns true if we're running from a ramdisk, for instance when
* we're in restoreOS.  In that case, we mustn't generate simulated
* crashes.
**********************************************************************/
bool
is_root_ramdisk()
{
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    char value[32];
    if (os_parse_boot_arg_string("rd", value, sizeof(value))
        || os_parse_boot_arg_string("rootdev", value, sizeof(value))) {
        return value[0] == 'm' && value[1] == 'd' && value[3] == 0;
    }
#endif
    return false;
}

/***********************************************************************
* map_images
* Process the given images which are being mapped in by dyld.
* Calls ABI-agnostic code after taking ABI-specific locks.
*
* Locking: write-locks runtimeLock
**********************************************************************/
void
map_images(unsigned count, const struct _dyld_objc_notify_mapped_info infos[])
{
    bool takeEnforcementDisableFault;

    {
        mutex_locker_t lock(runtimeLock);
        map_images_nolock(count, infos, &takeEnforcementDisableFault);
    }

    if (takeEnforcementDisableFault) {
        if (DebugClassRXSigning == Fatal)
            _objc_fatal("class_rx signing mismatch");

#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
        bool objcModeNoFaults = DisableFaults
            || DisableClassROFaults
            || getpid() == 1
            || is_root_ramdisk()
            || !os_variant_has_internal_diagnostics("com.apple.obj-c");
        if (!objcModeNoFaults) {
            os_fault_with_payload(OS_REASON_LIBSYSTEM,
                                  OS_REASON_LIBSYSTEM_CODE_FAULT,
                                  NULL, 0,
                                  "class_ro_t enforcement disabled",
                                  0);
        }
#endif
    }
}

void
_objc_map_images(unsigned count, const char * const paths[],
                 const struct mach_header * const mhdrs[])
{
    std::vector<_dyld_objc_notify_mapped_info> infos;
    for (unsigned i = 0; i != count; ++i ) {
        _dyld_objc_notify_mapped_info info = {
            mhdrs[i], paths[i], nullptr, 0, 0
        };
        infos.push_back(info);
    }
    map_images(count, infos.data());
}

static void load_categories_nolock(header_info *hi) {
    bool hasPreoptimizedCategories = hi->info()->dyldCategoriesOptimized() && !DisablePreattachedCategories;
    bool hasRoot = dyld_shared_cache_some_image_overridden();
    bool hasClassProperties = hi->info()->hasCategoryClassProperties();

    size_t count;
    auto processCatlist = [&](category_t * const *catlist, bool stubCategories) {
        for (unsigned i = 0; i < count; i++) {
            category_t *cat = catlist[i];
            Class cls = remapClass(cat->cls);
            locstamped_category_t lc{cat, hi};

            if (!cls) {
                // Category's target class is missing (probably weak-linked).
                // Ignore the category.
                if (PrintConnecting) {
                    _objc_inform("CLASS: IGNORING category \?\?\?(%s) %p with "
                                 "missing weak-linked target class",
                                 cat->name, cat);
                }
                continue;
            }

            // Process this category.
            if (cls->isStubClass()) {
                // Stub classes are never realized. Stub classes
                // don't know their metaclass until they're
                // initialized, so we have to add categories with
                // class methods or properties to the stub itself.
                // methodizeClass() will find them and add them to
                // the metaclass as appropriate.
                if (cat->instanceMethods ||
                    cat->protocols ||
                    cat->instanceProperties ||
                    cat->classMethods ||
                    cat->protocols ||
                    (hasClassProperties && cat->_classProperties))
                {
                    objc::unattachedCategories.addForClass(lc, cls);
                }
            } else {
                // First, register the category with its target class.
                // Then, rebuild the class's method lists (etc) if
                // the class is realized.
                //
                // If we're still in the initial launch, then all preoptimized
                // categories that point to a class in the shared cache can and
                // must be skipped to avoid duplicate method list entries.
                //
                // ALERT: a class that is within the shared cache range may not
                // logically be in the shared cache, due to inside-out patching.
                // Because of this, we also check the class_ro_t to see if that
                // is within the shared cache. An inside-out-patched class has
                // its class_ro_t re-pointed to the root.
                //
                // If the class has not yet had its lists copied then
                // attachLists will end up doing nothing, so everything works
                // fine. However, if a root is present (or if an image in the
                // shared cache doesn't have preoptimized categories for some
                // reason) then we could end up with a category pointing to a
                // class that HAS had its lists copied. That would have already
                // copied the lists from this category, since it would be
                // considered loaded at that time, and thus this category is
                // already attached. But attachLists will still add the lists,
                // resulting in duplicates. Duplicates are mostly "just" a
                // performance issue, but code that inspects classes with calls
                // like class_copyMethodList can get confused when it finds
                // multiple copies of the same method. (rdar://107325636)
                if (!didInitialAttachCategories && hasPreoptimizedCategories && objc::inSharedCache((uintptr_t)cls) && objc::inSharedCache((uintptr_t)cls->safe_ro()))
                    continue;

                if (cat->instanceMethods ||  cat->protocols
                    ||  cat->instanceProperties)
                {
                    if (cls->isRealized()) {
                        if (slowpath(PrintConnecting))
                            _objc_inform("CLASS: Attaching category (%s) %p to class %s", cat->name, cat, cls->nameForLogging());
                        attachCategories(cls, &lc, 1, ATTACH_EXISTING);
                    } else {
                        if (slowpath(PrintConnecting))
                            _objc_inform("CLASS: Adding unattached category (%s) %p for class %s", cat->name, cat, cls->nameForLogging());
                        objc::unattachedCategories.addForClass(lc, cls);
                    }
                }

                if (cat->classMethods  ||  cat->protocols
                    ||  (hasClassProperties && cat->_classProperties))
                {
                    if (cls->ISA()->isRealized()) {
                        if (slowpath(PrintConnecting))
                            _objc_inform("CLASS: Attaching category (%s) %p to metaclass %s", cat->name, cat, cls->nameForLogging());
                        attachCategories(cls->ISA(), &lc, 1, ATTACH_EXISTING | ATTACH_METACLASS);
                    } else {
                        if (slowpath(PrintConnecting))
                            _objc_inform("CLASS: Adding unattached category (%s) %p for metaclass %s", cat->name, cat, cls->nameForLogging());
                        objc::unattachedCategories.addForClass(lc, cls->ISA());
                    }
                }
            }
        }
    };

    // Don't load categories in catlist if we're still in the initial load, the
    // header has dyld optimized categories, and there are no roots. After the
    // initial load we still need to load categories ourselves since they may
    // contain new RR/AWZ/core overrides.
    bool scanCatlist = didInitialAttachCategories || !hasPreoptimizedCategories || hasRoot;
    if (scanCatlist) {
        if (slowpath(PrintPreopt)) {
            _objc_inform("PREOPTIMIZATION: SCANNING categories in image %p %s "
                         "- didInitialAttachCategories=%d "
                         "hi->info()->dyldCategoriesOptimized()=%d hasRoot=%d",
                         hi->mhdr(), hi->fname(), didInitialAttachCategories,
                         hi->info()->dyldCategoriesOptimized(), hasRoot);
        }
        processCatlist(hi->catlist(&count), /*stubCategories*/false);
    } else {
        if (slowpath(PrintPreopt)) {
            _objc_inform("PREOPTIMIZATION: IGNORING preoptimized categories in "
                         "image %p %s", hi->mhdr(), hi->fname());
        }
    }

    // Categories in catlist2 point to stub classes and aren't preoptimized, so
    // scan those unconditionally.
    processCatlist(hi->catlist2(&count), /*stubCategories*/true);
}

void loadAllCategoriesIfNeeded() {
    if (!didInitialAttachCategories && didCallDyldNotifyRegister) {
        if (slowpath(PrintImages)) {
            _objc_inform("IMAGES: performing initial category attach\n");
        }

        for (auto *hi = FirstHeader; hi != NULL; hi = hi->getNext()) {
            load_categories_nolock(hi);
        }

        // load_categories_nolock uses this to decide whether it's safe to skip
        // images with dyld optimized categories, so we need to set it after
        // calling loadAllCategories.
        didInitialAttachCategories = true;
    }
}

/***********************************************************************
* load_images
* Process +load in the given images which are being mapped in by dyld.
*
* Locking: write-locks runtimeLock and loadMethodLock
**********************************************************************/
extern bool hasLoadMethods(const headerType *mhdr, const _dyld_section_location_info_t dyldObjCInfo);
extern void prepare_load_methods(const headerType *mhdr, const _dyld_section_location_info_t dyldObjCInfo);

void
load_images(const struct _dyld_objc_notify_mapped_info* info)
{
    if (slowpath(PrintImages)) {
        _objc_inform("IMAGES: calling +load methods in %s\n", info->path ? info->path : "<null>");
    }


    // Return without taking locks if there are no +load methods here.
    if (!hasLoadMethods((const headerType *)info->mh, info->sectionLocationMetadata)) return;

    recursive_mutex_locker_t lock(loadMethodLock);

    // Load all pending categories if they haven't been loaded yet, and discover
    // load methods.
    {
        mutex_locker_t lock2(runtimeLock);
        loadAllCategoriesIfNeeded();
        prepare_load_methods((const headerType *)info->mh, info->sectionLocationMetadata);
    }

    // Call +load methods (without runtimeLock - re-entrant)
    call_load_methods();
}

void
_objc_load_image(const char *path, const struct mach_header *mh) {
    _dyld_objc_notify_mapped_info info = {
        mh, path, nullptr, 0, 0
    };
    load_images(&info);
}

/***********************************************************************
* unmap_image
* Process the given image which is about to be unmapped by dyld.
*
* Locking: write-locks runtimeLock and loadMethodLock
**********************************************************************/
void
unmap_image(const char *path __unused, const struct mach_header *mh)
{
    recursive_mutex_locker_t lock(loadMethodLock);
    mutex_locker_t lock2(runtimeLock);
    unmap_image_nolock(mh);
}


/***********************************************************************
* mustReadClasses
* Preflight check in advance of readClass() from an image.
**********************************************************************/
static bool mustReadClasses(mapped_image_info info, bool hasDyldRoots)
{
    const char *reason;

    // If the image is not preoptimized then we must read classes.
    if (!info.dyldObjCRefsOptimized()) {
        reason = nil; // Don't log this one because it is noisy.
        goto readthem;
    }

    // If iOS simulator then we must read classes.
#if TARGET_OS_SIMULATOR
    reason = "the image is for iOS simulator";
    goto readthem;
#endif

    ASSERT(!info.hi->isBundle());  // no MH_BUNDLE in shared cache

    // If the image may have missing weak superclasses then we must read classes
    if (!noMissingWeakSuperclasses() || hasDyldRoots) {
        reason = "the image may contain classes with missing weak superclasses";
        goto readthem;
    }

    // If there are unresolved future classes then we must read classes.
    if (haveFutureNamedClasses()) {
        reason = "there are unresolved future classes pending";
        goto readthem;
    }

    // readClass() rewrites bits in backward-deploying Swift stable ABI code.
    // The assumption here is there there are no such classes
    // in the dyld shared cache.
#if DEBUG
    {
        size_t count;
        classref_t const *classlist = info.hi->classlist(&count);
        for (size_t i = 0; i < count; i++) {
            Class cls = remapClass(classlist[i]);
            ASSERT(!cls->isUnfixedBackwardDeployingStableSwift());
        }
    }
#endif

    // readClass() does not need to do anything.
    return NO;

 readthem:
    if (PrintPreopt  &&  reason) {
        _objc_inform("PREOPTIMIZATION: reading classes manually from %s "
                     "because %s", info.hi->fname(), reason);
    }
    return YES;
}


/***********************************************************************
* readClass
* Read a class and metaclass as written by a compiler.
* Returns the new class pointer. This could be:
* - cls
* - nil  (cls has a missing weak-linked superclass)
* - something else (space for this class was reserved by a future class)
*
* Note that all work performed by this function is preflighted by
* mustReadClasses(). Do not change this function without updating that one.
*
* Locking: runtimeLock acquired by map_images or objc_readClassPair
**********************************************************************/
Class readClass(Class cls, bool headerIsBundle, bool headerIsPreoptimized)
{
    const char *mangledName = cls->nonlazyMangledName();

    if (missingWeakSuperclass(cls)) {
        // No superclass (probably weak-linked).
        // Disavow any knowledge of this subclass.
        if (PrintConnecting) {
            _objc_inform("CLASS: IGNORING class '%s' with "
                         "missing weak-linked superclass",
                         cls->nameForLogging());
        }
        addRemappedClass(cls, nil);
        cls->setSuperclass(nil);
        return nil;
    }

    cls->fixupBackwardDeployingStableSwift();

    Class replacing = nil;
    if (mangledName != nullptr) {
        if (Class newCls = popFutureNamedClass(mangledName)) {
            // This name was previously allocated as a future class.
            // Copy objc_class to future class's struct.
            // Preserve future's rw data block.

            if (newCls->isAnySwift()) {
                _objc_fatal("Can't complete future class request for '%s' "
                            "because the real class is too big.",
                            cls->nameForLogging());
            }

            class_rw_t *rw = newCls->data();
            const class_ro_t *old_ro = rw->ro();

            newCls->setSuperclass(cls->getSuperclass());
            newCls->initIsa(cls->getIsa());
            memcpy(&newCls->cache, &cls->cache, sizeof(newCls->cache));
            if (cls->hasCustomRR())
                newCls->setHasCustomRR();
            else
                newCls->setHasDefaultRR();
            rw->set_ro(cls->safe_ro());

            freeIfMutable((char *)old_ro->getName());
            free((void *)old_ro);

            addRemappedClass(cls, newCls);

            replacing = cls;
            cls = newCls;
        }
    }

    if (headerIsPreoptimized  &&  !replacing) {
        // class list built in shared cache
        // fixme strict assert doesn't work because of duplicates
        // ASSERT(cls == getClass(name));
        ASSERT(mangledName == nullptr || getClassExceptSomeSwift(mangledName));
    } else {
        if (mangledName) { //some Swift generic classes can lazily generate their names
            addNamedClass(cls, mangledName, replacing);
        } else {
            Class meta = cls->ISA();
            const class_ro_t *metaRO = meta->bits.safe_ro();
            ASSERT(metaRO->getNonMetaclass() && "Metaclass with lazy name must have a pointer to the corresponding nonmetaclass.");
            ASSERT(metaRO->getNonMetaclass() == cls && "Metaclass nonmetaclass pointer must equal the original class.");
        }
        addClassTableEntry(cls);
    }

    // for future reference: shared cache never contains MH_BUNDLEs
    if (headerIsBundle) {
        const_cast<class_ro_t *>(cls->safe_ro())->flags |= RO_FROM_BUNDLE;
        const_cast<class_ro_t *>(cls->ISA()->safe_ro())->flags |= RO_FROM_BUNDLE;
    }

    return cls;
}


/***********************************************************************
* readProtocol
* Read a protocol as written by a compiler.
**********************************************************************/
static void
readProtocol(protocol_t *newproto, Class protocol_class,
             NXMapTable *protocol_map,
             bool headerIsPreoptimized, bool headerIsBundle)
{
    // This is not enough to make protocols in unloaded bundles safe,
    // but it does prevent crashes when looking up unrelated protocols.
    auto insertFn = headerIsBundle ? NXMapKeyCopyingInsert : NXMapInsert;

    protocol_t *oldproto = (protocol_t *)getProtocol(newproto->mangledName);

    if (oldproto) {
        if (oldproto != newproto) {
            // Some other definition already won.
            if (PrintProtocols) {
                _objc_inform("PROTOCOLS: protocol at %p is %s  "
                             "(duplicate of %p)",
                             newproto, oldproto->nameForLogging(), oldproto);
            }

            // If we are a shared cache binary then we have a definition of this
            // protocol, but if another one was chosen then we need to clear our
            // isCanonical bit so that no-one trusts it.
            // Note, if getProtocol returned a shared cache protocol then the
            // canonical definition is already in the shared cache and we don't
            // need to do anything.
            if (headerIsPreoptimized && !oldproto->isCanonical()) {
                // Note newproto is an entry in our __objc_protolist section which
                // for shared cache binaries points to the original protocol in
                // that binary, not the shared cache uniqued one.
                auto cacheproto = (protocol_t *)
                    getSharedCachePreoptimizedProtocol(newproto->mangledName);
                if (cacheproto && cacheproto->isCanonical())
                    cacheproto->clearIsCanonical();
            }
        }
    }
    else if (headerIsPreoptimized) {
        // Shared cache initialized the protocol object itself,
        // but in order to allow out-of-cache replacement we need
        // to add it to the protocol table now.

        protocol_t *cacheproto = (protocol_t *)
            getPreoptimizedProtocol(newproto->mangledName);
        protocol_t *installedproto;
        if (cacheproto  &&  cacheproto != newproto) {
            // Another definition in the shared cache wins (because
            // everything in the cache was fixed up to point to it).
            installedproto = cacheproto;
        }
        else {
            // This definition wins.
            installedproto = newproto;
        }

        ASSERT(installedproto->getIsa() == protocol_class);
        ASSERT(installedproto->size >= sizeof(protocol_t));
        insertFn(protocol_map, installedproto->mangledName,
                 installedproto);

        if (PrintProtocols) {
            _objc_inform("PROTOCOLS: protocol at %p is %s",
                         installedproto, installedproto->nameForLogging());
            if (newproto != installedproto) {
                _objc_inform("PROTOCOLS: protocol at %p is %s  "
                             "(duplicate of %p)",
                             newproto, installedproto->nameForLogging(),
                             installedproto);
            }
        }
    }
    else {
        // New protocol from an un-preoptimized image. Fix it up in place.
        // fixme duplicate protocols from unloadable bundle
        newproto->initIsa(protocol_class);  // fixme pinned
        insertFn(protocol_map, newproto->mangledName, newproto);
        if (PrintProtocols) {
            _objc_inform("PROTOCOLS: protocol at %p is %s",
                         newproto, newproto->nameForLogging());
        }
    }
}

/***********************************************************************
* _read_images
* Perform initial processing of the headers in the linked
* list beginning with headerList.
*
* Called by: map_images_nolock
*
* Locking: runtimeLock acquired by map_images
**********************************************************************/
void _read_images(mapped_image_info infosParam[], uint32_t hCount, int totalClasses, int unoptimizedTotalClasses)
{
    UnsafeSpan<mapped_image_info> infos{infosParam, hCount};

    size_t count;
    size_t i;
    Class *resolvedFutureClasses = nil;
    size_t resolvedFutureClassCount = 0;
    static bool doneOnce;
    bool launchTime = NO;

    lockdebug::assert_locked(&runtimeLock);

    if (!doneOnce) {
        // dtrace probe
        OBJC_RUNTIME_FIRST_TIME_START();

        doneOnce = YES;
        launchTime = YES;

#if SUPPORT_NONPOINTER_ISA
        // Disable non-pointer isa under some conditions.

# if SUPPORT_INDEXED_ISA
        // Disable nonpointer isa if any image contains old Swift code
        for (auto info : infos) {
            if (info.hi->info()->containsSwift()  &&
                info.hi->info()->swiftUnstableVersion() < objc_image_info::SwiftVersion3)
            {
                DisableNonpointerIsa = On;
                if (PrintRawIsa) {
                    _objc_inform("RAW ISA: disabling non-pointer isa because "
                                 "the app or a framework contains Swift code "
                                 "older than Swift 3.0");
                }
                break;
            }
        }
# endif

# if TARGET_OS_OSX
#   if !TARGET_OS_EXCLAVEKIT
        // Disable non-pointer isa if the app is too old
        // (linked before OS X 10.11)
        // Note: we must check for macOS, because Catalyst and Almond apps
        // return false for a Mac SDK check! rdar://78225780
        if (dyld_get_active_platform() == PLATFORM_MACOS && !false /*dyld_program_sdk_at_least(dyld_platform_version_macOS_10_11)*/) {
            DisableNonpointerIsa = On;
            if (PrintRawIsa) {
                _objc_inform("RAW ISA: disabling non-pointer isa because "
                             "the app is too old.");
            }
        }
#   endif

        // Disable non-pointer isa if the app has a __DATA,__objc_rawisa section
        // New apps that load old extensions may need this.
        for (auto info : infos) {
            if (info.hi->mhdr()->filetype != MH_EXECUTE) continue;
            unsigned long size;
            if (info.hi->hasRawISASection()) {
                DisableNonpointerIsa = On;
                if (PrintRawIsa) {
                    _objc_inform("RAW ISA: disabling non-pointer isa because "
                                 "the app has a __DATA,__objc_rawisa section");
                }
            }
            break;  // assume only one MH_EXECUTE image
        }
# endif

#endif

        if (DisableTaggedPointers) {
            disableTaggedPointers();
        }

        initializeTaggedPointerObfuscator();

        if (PrintConnecting) {
            _objc_inform("CLASS: found %d classes during launch", totalClasses);
        }

        // namedClasses
        // Preoptimized classes don't go in this table.
        // 4/3 is NXMapTable's load factor
        int namedClassesSize =
            (isPreoptimized() ? unoptimizedTotalClasses : totalClasses) * 4 / 3;
        NXMapTablePrototype namedClassesPrototype = NXStrValueMapPrototype;
#if __has_feature(ptrauth_calls)
        // Only set this when we have ptrauth, we use the standard callback
        // otherwise.
        namedClassesPrototype.hash = namedClassTableHashCallback;
#endif
        gdb_objc_realized_classes =
            NXCreateMapTable(namedClassesPrototype, namedClassesSize);

        // dtrace probe
        OBJC_RUNTIME_FIRST_TIME_END();
    }

    // Fix up @selector references
    // Note this has to be before anyone uses a method list, as relative method
    // lists point to selRefs, and assume they are already fixed up (uniqued).

    // dtrace probe
    OBJC_RUNTIME_FIXUP_SELECTORS_START();

    static size_t UnfixedSelectors;
    {
        mutex_locker_t lock(selLock);
        for (auto info : infos) {
            if (info.dyldObjCRefsOptimized()) continue;

            bool isBundle = info.hi->isBundle();
            SEL *sels = info.hi->selrefs(&count);
            UnfixedSelectors += count;
            for (i = 0; i < count; i++) {
                const char *name = sel_cname(sels[i]);
                SEL sel = sel_registerNameNoLock(name, isBundle);
                if (sels[i] != sel) {
                    sels[i] = sel;
                }
            }
        }
    }

    // dtrace probe
    OBJC_RUNTIME_FIXUP_SELECTORS_END();

    // Discover classes. Fix up unresolved future classes. Mark bundle classes.

    // dtrace probe
    OBJC_RUNTIME_DISCOVER_CLASSES_START();

    bool hasDyldRoots = dyld_shared_cache_some_image_overridden();

    for (auto info : infos) {
        if (! mustReadClasses(info, hasDyldRoots)) {
            // Image is sufficiently optimized that we need not call readClass()
            continue;
        }

        classref_t const *classlist = info.hi->classlist(&count);

        bool headerIsBundle = info.hi->isBundle();
        bool headerIsPreoptimized = info.dyldObjCRefsOptimized();

        for (i = 0; i < count; i++) {
            Class cls = (Class)classlist[i];
            Class newCls = readClass(cls, headerIsBundle, headerIsPreoptimized);

            if (newCls != cls  &&  newCls) {
                // Class was moved but not deleted. Currently this occurs
                // only when the new class resolved a future class.
                // Non-lazily realize the class below.
                resolvedFutureClasses = (Class *)
                    realloc(resolvedFutureClasses,
                            (resolvedFutureClassCount+1) * sizeof(Class));
                resolvedFutureClasses[resolvedFutureClassCount++] = newCls;
            }
        }
    }

    // dtrace probe
    OBJC_RUNTIME_DISCOVER_CLASSES_END();

    // Fix up remapped classes
    // Class list and nonlazy class list remain unremapped.
    // Class refs and super refs are remapped for message dispatching.

    // dtrace probe
    OBJC_RUNTIME_REMAP_CLASSES_START();

    if (!noClassesRemapped()) {
        for (auto info : infos) {
            Class *classrefs = info.hi->classrefs(&count);
            for (i = 0; i < count; i++) {
                remapClassRef(&classrefs[i]);
            }
            // fixme why doesn't test future1 catch the absence of this?
            classrefs = info.hi->superrefs(&count);
            for (i = 0; i < count; i++) {
                remapClassRef(&classrefs[i]);
            }
        }
    }

    // dtrace probe
    OBJC_RUNTIME_REMAP_CLASSES_END();

#if SUPPORT_FIXUP
    // Fix up old objc_msgSend_fixup call sites

    // dtrace probe
    OBJC_RUNTIME_FIXUP_VTABLES_START();

    for (auto info : infos) {
        message_ref_t *refs = info.hi->messagerefs(&count);
        if (count == 0) continue;

        if (PrintVtables) {
            _objc_inform("VTABLES: repairing %zu unsupported vtable dispatch "
                         "call sites in %s", count, info.hi->fname());
        }
        for (i = 0; i < count; i++) {
            fixupMessageRef(refs+i);
        }
    }

    // dtrace probe
    OBJC_RUNTIME_FIXUP_VTABLES_END();
#endif


    // Discover protocols. Fix up protocol refs.

    // dtrace probe
    OBJC_RUNTIME_DISCOVER_PROTOCOLS_START();

    for (auto info : infos) {
        extern objc_class OBJC_CLASS_$_Protocol;
        Class cls = (Class)&OBJC_CLASS_$_Protocol;
        ASSERT(cls);
        NXMapTable *protocol_map = protocols();
        bool isPreoptimized = info.dyldObjCRefsOptimized();

        // Skip reading protocols if this is an image from the shared cache
        // and we support roots
        // Note, after launch we do need to walk the protocol as the protocol
        // in the shared cache is marked with isCanonical() and that may not
        // be true if some non-shared cache binary was chosen as the canonical
        // definition
        if (launchTime && isPreoptimized) {
            if (PrintProtocols) {
                _objc_inform("PROTOCOLS: Skipping reading protocols in image: %s",
                             info.hi->fname());
            }
            continue;
        }

        bool isBundle = info.hi->isBundle();

        protocol_t * const *protolist = info.hi->protocollist(&count);
        for (i = 0; i < count; i++) {
            readProtocol(protolist[i], cls, protocol_map,
                         isPreoptimized, isBundle);
        }
    }

    // dtrace probe
    OBJC_RUNTIME_DISCOVER_PROTOCOLS_END();

    // Fix up @protocol references
    // Preoptimized images may have the right
    // answer already but we don't know for sure.

    // dtrace probe
    OBJC_RUNTIME_FIXUP_PROTOCOLS_START();

    for (auto info : infos) {
        // At launch time, we know preoptimized image refs are pointing at the
        // shared cache definition of a protocol.  We can skip the check on
        // launch, but have to visit @protocol refs for shared cache images
        // loaded later.
        if (launchTime && info.hi->isPreoptimized())
            continue;
        protocol_t **protolist = info.hi->protocolrefs(&count);
        for (i = 0; i < count; i++) {
            remapProtocolRef(&protolist[i]);
        }
    }

    // dtrace probe
    OBJC_RUNTIME_FIXUP_PROTOCOLS_END();

    // Discover categories. Only do this after the initial category
    // attachment has been done. For categories present at startup,
    // discovery is deferred until the first load_images call after
    // the call to _dyld_objc_notify_register completes. rdar://problem/53119145

    // dtrace probe
    OBJC_RUNTIME_DISCOVER_CATEGORIES_START();

    if (didInitialAttachCategories) {
        for (auto info : infos) {
            load_categories_nolock(info.hi);
        }
    }

    // dtrace probe
    OBJC_RUNTIME_DISCOVER_CATEGORIES_END();

    // Category discovery MUST BE Late to avoid potential races
    // when other threads call the new category code before
    // this thread finishes its fixups.

    // +load handled by prepare_load_methods()

    // Realize non-lazy classes (for +load methods and static instances)

    // dtrace probe
    OBJC_RUNTIME_REALIZE_NON_LAZY_CLASSES_START();

    for (auto info : infos) {
        classref_t const *classlist = info.hi->nlclslist(&count);
        for (i = 0; i < count; i++) {
            Class cls = remapClass(classlist[i]);
            if (!cls) continue;

            addClassTableEntry(cls);

            if (cls->isSwiftStable()) {
                if (cls->swiftMetadataInitializer()) {
                    _objc_fatal("Swift class %s with a metadata initializer "
                                "is not allowed to be non-lazy",
                                cls->nameForLogging());
                }
                // fixme also disallow relocatable classes
                // We can't disallow all Swift classes because of
                // classes like Swift.__EmptyArrayStorage
            }
            realizeClassWithoutSwift(cls, nil);
        }
    }

    // dtrace probe
    OBJC_RUNTIME_REALIZE_NON_LAZY_CLASSES_END();

    // Realize newly-resolved future classes, in case CF manipulates them

    // dtrace probe
    OBJC_RUNTIME_REALIZE_FUTURE_CLASSES_START();

    if (resolvedFutureClasses) {
        for (i = 0; i < resolvedFutureClassCount; i++) {
            Class cls = resolvedFutureClasses[i];
            if (cls->isSwiftStable()) {
                _objc_fatal("Swift class is not allowed to be future");
            }
            realizeClassWithoutSwift(cls, nil);
            cls->setInstancesRequireRawIsaRecursively(false/*inherited*/);
        }
        free(resolvedFutureClasses);
    }

    // dtrace probe
    OBJC_RUNTIME_REALIZE_FUTURE_CLASSES_END();

    if (DebugNonFragileIvars) {
        realizeAllClasses();
    }


    // Print preoptimization statistics
    if (PrintPreopt) {
        static unsigned int PreoptTotalMethodLists;
        static unsigned int PreoptOptimizedMethodLists;
        static unsigned int PreoptTotalClasses;
        static unsigned int PreoptOptimizedClasses;

        for (auto info : infos) {
            if (info.dyldObjCRefsOptimized()) {
                _objc_inform("PREOPTIMIZATION: honoring preoptimized selectors "
                             "in %s", info.hi->fname());
            }
            else if (info.hi->info()->optimizedByDyld()) {
                _objc_inform("PREOPTIMIZATION: IGNORING preoptimized selectors "
                             "in %s", info.hi->fname());
            }

            classref_t const *classlist = info.hi->classlist(&count);
            for (i = 0; i < count; i++) {
                Class cls = remapClass(classlist[i]);
                if (!cls) continue;

                PreoptTotalClasses++;
                if (info.dyldObjCRefsOptimized()) {
                    PreoptOptimizedClasses++;
                }

                auto countMethodList = [&](method_list_t *list) {
                    PreoptTotalMethodLists++;
                    if (list->isFixedUp())
                        PreoptOptimizedMethodLists++;
                };
                auto countMethods = [&](Class cls) {
                    auto &baseMethods = cls->bits.safe_ro()->baseMethods;
                    if (method_list_t *list = baseMethods.dyn_cast<method_list_t *>()) {
                        countMethodList(list);
                    } else if (auto *listList = baseMethods.dyn_cast<relative_list_list_t<method_list_t> *>()) {
                        auto iter = listList->beginLists();
                        auto end = listList->endLists();
                        while (iter != end) {
                            countMethodList(*iter);
                            ++iter;
                        }
                    }
                };
                countMethods(cls);
                countMethods(cls->ISA());
            }
        }

        _objc_inform("PREOPTIMIZATION: %zu selector references not "
                     "pre-optimized", UnfixedSelectors);
        _objc_inform("PREOPTIMIZATION: %u/%u (%.3g%%) method lists pre-sorted",
                     PreoptOptimizedMethodLists, PreoptTotalMethodLists,
                     PreoptTotalMethodLists
                     ? 100.0*PreoptOptimizedMethodLists/PreoptTotalMethodLists
                     : 0.0);
        _objc_inform("PREOPTIMIZATION: %u/%u (%.3g%%) classes pre-registered",
                     PreoptOptimizedClasses, PreoptTotalClasses,
                     PreoptTotalClasses
                     ? 100.0*PreoptOptimizedClasses/PreoptTotalClasses
                     : 0.0);
        _objc_inform("PREOPTIMIZATION: %zu protocol references not "
                     "pre-optimized", UnfixedProtocolReferences);
    }
}


/***********************************************************************
* prepare_load_methods
* Schedule +load for classes in this image, any un-+load-ed
* superclasses in other images, and any categories in this image.
**********************************************************************/
// Recursively schedule +load for cls and any un-+load-ed superclasses.
// cls must already be connected.
static void schedule_class_load(Class cls)
{
    if (!cls) return;
    ASSERT(cls->isRealized());  // _read_images should realize

    if (cls->data()->flags & RW_LOADED) return;

    // Ensure superclass-first ordering
    schedule_class_load(cls->getSuperclass());

    add_class_to_loadable_list(cls);
    cls->setInfo(RW_LOADED);
}

// Quick scan for +load methods that doesn't take a lock.
bool hasLoadMethods(const headerType *mhdr, const _dyld_section_location_info_t info)
{
    size_t count;
    if (getSectionData<classref_t>(mhdr, info, _dyld_section_location_data_non_lazy_class_list, &count)) {
        if (count > 0) return true;
    }
    if (getSectionData<category_t*>(mhdr, info, _dyld_section_location_data_non_lazy_category_list, &count)) {
        if (count > 0) return true;
    }
    return false;
}

void prepare_load_methods(const headerType *mhdr, const _dyld_section_location_info_t info)
{
    size_t count, i;

    lockdebug::assert_locked(&runtimeLock);

    classref_t const *classlist = getSectionData<classref_t>(mhdr, info, _dyld_section_location_data_non_lazy_class_list, &count);
    for (i = 0; i < count; i++) {
        schedule_class_load(remapClass(classlist[i]));
    }

    category_t * const *categorylist = getSectionData<category_t *>(mhdr, info, _dyld_section_location_data_non_lazy_category_list, &count);

    for (i = 0; i < count; i++) {
        category_t *cat = categorylist[i];
        Class cls = remapClass(cat->cls);
        if (!cls) continue;  // category for ignored weak-linked class
        if (cls->isSwiftStable()) {
            _objc_fatal("Swift class extensions and categories on Swift "
                        "classes are not allowed to have +load methods");
        }
        realizeClassWithoutSwift(cls, nil);
        ASSERT(cls->ISA()->isRealized());
        add_category_to_loadable_list(cat);
    }
}


/***********************************************************************
* _unload_image
* Only handles MH_BUNDLE for now.
* Locking: write-lock and loadMethodLock acquired by unmap_image
**********************************************************************/
void _unload_image(header_info *hi)
{
    size_t count, i;

    lockdebug::assert_locked(&loadMethodLock);
    lockdebug::assert_locked(&runtimeLock);

    // Unload unattached categories and categories waiting for +load.

    // Ignore __objc_catlist2. We don't support unloading Swift
    // and we never will.
    category_t * const *catlist = hi->catlist(&count);
    for (i = 0; i < count; i++) {
        category_t *cat = catlist[i];
        Class cls = remapClass(cat->cls);
        if (!cls) continue;  // category for ignored weak-linked class

        // fixme for MH_DYLIB cat's class may have been unloaded already

        // unattached list
        objc::unattachedCategories.eraseCategoryForClass(cat, cls);

        // +load queue
        remove_category_from_loadable_list(cat);
    }

    // Unload classes.

    // Gather classes from both __DATA,__objc_clslist
    // and __DATA,__objc_nlclslist. arclite's hack puts a class in the latter
    // only, and we need to unload that class if we unload an arclite image.

    objc::DenseSet<Class> classes{};
    classref_t const *classlist;

    classlist = hi->classlist(&count);
    for (i = 0; i < count; i++) {
        Class cls = remapClass(classlist[i]);
        if (cls) classes.insert(cls);
    }

    classlist = hi->nlclslist(&count);
    for (i = 0; i < count; i++) {
        Class cls = remapClass(classlist[i]);
        if (cls) classes.insert(cls);
    }

    // First detach classes from each other. Then free each class.
    // This avoid bugs where this loop unloads a subclass before its superclass

    for (Class cls: classes) {
        remove_class_from_loadable_list(cls);
        detach_class(cls->ISA(), YES);
        detach_class(cls, NO);
    }
    for (Class cls: classes) {
        free_class(cls->ISA());
        free_class(cls);
    }

    // XXX FIXME -- Clean up protocols:
    // <rdar://problem/9033191> Support unloading protocols at dylib/image unload time

    // fixme DebugUnload
}

/***********************************************************************
* method_getDescription
* Returns a pointer to this method's objc_method_description.
* Locking: none
**********************************************************************/
struct objc_method_description *
method_getDescription(Method mSigned)
{
    if (!mSigned) return nil;
    method_t *m = _method_auth(mSigned);
    return m->getDescription();
}


IMP
method_getImplementation(Method mSigned)
{
    method_t *m = _method_auth(mSigned);
    return m ? m->imp(true) : nil;
}

IMPAndSEL _method_getImplementationAndName(Method mSigned)
{
    method_t *m = _method_auth(mSigned);
    return { m->imp(true), m->name() };
}


/***********************************************************************
* method_getName
* Returns this method's selector.
* The method must not be nil.
* The method must already have been fixed-up.
* Locking: none
**********************************************************************/
SEL
method_getName(Method mSigned)
{
    if (!mSigned) return nil;

    method_t *m = _method_auth(mSigned);
    ASSERT(m->name() == sel_registerName(sel_getName(m->name())));
    return m->name();
}


/***********************************************************************
* method_getTypeEncoding
* Returns this method's old-style type encoding string.
* The method must not be nil.
* Locking: none
**********************************************************************/
const char *
method_getTypeEncoding(Method mSigned)
{
    if (!mSigned) return nil;
    method_t *m = _method_auth(mSigned);
    return m->types();
}


/***********************************************************************
* method_setImplementation
* Sets this method's implementation to imp.
* The previous implementation is returned.
**********************************************************************/
static IMP
_method_setImplementation(Class cls, method_t *m, IMP imp)
{
    lockdebug::assert_locked(&runtimeLock);

    if (!m) return nil;
    if (!imp) return nil;

    IMP old = m->imp(false);
    SEL sel = m->name();

    m->setImp(imp);

    // Cache updates are slow if cls is nil (i.e. unknown)
    // RR/AWZ updates are slow if cls is nil (i.e. unknown)
    // fixme build list of classes whose Methods are known externally?

    flushCaches(cls, __func__, [sel, old](Class c){
        return c->cache.shouldFlush(sel, old);
    });

    adjustCustomFlagsForMethodChange(cls, m);

    return old;
}

IMP
method_setImplementation(Method mSigned, IMP imp)
{
    method_t *m = _method_auth(mSigned);

    // Don't know the class - will be slow if RR/AWZ are affected
    // fixme build list of classes whose Methods are known externally?
    mutex_locker_t lock(runtimeLock);
    return _method_setImplementation(Nil, m, imp);
}

extern void _method_setImplementationRawUnsafe(Method mSigned, IMP imp)
{
    method_t *m = _method_auth(mSigned);

    mutex_locker_t lock(runtimeLock);
    m->setImp(imp);
}


void method_exchangeImplementations(Method m1Signed, Method m2Signed)
{
    if (!m1Signed  ||  !m2Signed) return;

    method_t *m1 = _method_auth(m1Signed);
    method_t *m2 = _method_auth(m2Signed);

    mutex_locker_t lock(runtimeLock);

    IMP imp1 = m1->imp(false);
    IMP imp2 = m2->imp(false);
    SEL sel1 = m1->name();
    SEL sel2 = m2->name();

    m1->setImp(imp2);
    m2->setImp(imp1);


    // RR/AWZ updates are slow because class is unknown
    // Cache updates are slow because class is unknown
    // fixme build list of classes whose Methods are known externally?

    flushCaches(nil, __func__, [sel1, sel2, imp1, imp2](Class c){
        return c->cache.shouldFlush(sel1, imp1) || c->cache.shouldFlush(sel2, imp2);
    });

    adjustCustomFlagsForMethodChange(nil, m1);
    adjustCustomFlagsForMethodChange(nil, m2);
}


/***********************************************************************
* ivar_getOffset
* fixme
* Locking: none
**********************************************************************/
ptrdiff_t
ivar_getOffset(Ivar ivar)
{
    if (!ivar) return 0;
    return *ivar->offset;
}


/***********************************************************************
* ivar_getName
* fixme
* Locking: none
**********************************************************************/
const char *
ivar_getName(Ivar ivar)
{
    if (!ivar) return nil;
    return ivar->name;
}


/***********************************************************************
* ivar_getTypeEncoding
* fixme
* Locking: none
**********************************************************************/
const char *
ivar_getTypeEncoding(Ivar ivar)
{
    if (!ivar) return nil;
    return ivar->type;
}



const char *property_getName(objc_property_t prop)
{
    return prop->name;
}

const char *property_getAttributes(objc_property_t prop)
{
    return prop->attributes;
}

objc_property_attribute_t *property_copyAttributeList(objc_property_t prop,
                                                      unsigned int *outCount)
{
    if (!prop) {
        if (outCount) *outCount = 0;
        return nil;
    }

    mutex_locker_t lock(runtimeLock);
    return copyPropertyAttributeList(prop->attributes,outCount);
}

char * property_copyAttributeValue(objc_property_t prop, const char *name)
{
    if (!prop  ||  !name  ||  *name == '\0') return nil;

    mutex_locker_t lock(runtimeLock);
    return copyPropertyAttributeValue(prop->attributes, name);
}


/***********************************************************************
* getExtendedTypesIndexesForMethod
* Returns:
* a is the count of methods in all method lists before m's method list
* b is the index of m in m's method list
* a+b is the index of m's extended types in the extended types array
**********************************************************************/
static void getExtendedTypesIndexesForMethod(protocol_t *proto, const method_t *m, bool isRequiredMethod, bool isInstanceMethod, uint32_t& a, uint32_t &b)
{
    a = 0;

    if (proto->instanceMethods) {
        if (isRequiredMethod && isInstanceMethod) {
            b = proto->instanceMethods->indexOfMethod(m);
            return;
        }
        a += proto->instanceMethods->count;
    }

    if (proto->classMethods) {
        if (isRequiredMethod && !isInstanceMethod) {
            b = proto->classMethods->indexOfMethod(m);
            return;
        }
        a += proto->classMethods->count;
    }

    if (proto->optionalInstanceMethods) {
        if (!isRequiredMethod && isInstanceMethod) {
            b = proto->optionalInstanceMethods->indexOfMethod(m);
            return;
        }
        a += proto->optionalInstanceMethods->count;
    }

    if (proto->optionalClassMethods) {
        if (!isRequiredMethod && !isInstanceMethod) {
            b = proto->optionalClassMethods->indexOfMethod(m);
            return;
        }
        a += proto->optionalClassMethods->count;
    }
}


/***********************************************************************
* getExtendedTypesIndexForMethod
* Returns the index of m's extended types in proto's extended types array.
**********************************************************************/
static uint32_t getExtendedTypesIndexForMethod(protocol_t *proto, const method_t *m, bool isRequiredMethod, bool isInstanceMethod)
{
    uint32_t a;
    uint32_t b;
    getExtendedTypesIndexesForMethod(proto, m, isRequiredMethod,
                                     isInstanceMethod, a, b);
    return a + b;
}


/***********************************************************************
* fixupProtocolMethodList
* Fixes up a single method list in a protocol.
**********************************************************************/
static void
fixupProtocolMethodList(protocol_t *proto, method_list_t *mlist,
                        bool required, bool instance)
{
    lockdebug::assert_locked(&runtimeLock);

    if (!mlist) return;
    if (mlist->isFixedUp()) return;

    const char **extTypes = proto->extendedMethodTypes();
    fixupMethodList(mlist, true/*always copy for simplicity*/,
                    !extTypes/*sort if no extended method types*/);

    if (extTypes && mlist->listKind() != method_t::Kind::small) {
        // Sort method list and extended method types together.
        // fixupMethodList() can't do this.
        // fixme COW stomp
        uint32_t count = mlist->count;
        uint32_t prefix;
        uint32_t junk;
        getExtendedTypesIndexesForMethod(proto, &mlist->get(0),
                                         required, instance, prefix, junk);
        for (uint32_t i = 0; i < count; i++) {
            for (uint32_t j = i+1; j < count; j++) {
                auto& mi = mlist->get(i).big();
                auto& mj = mlist->get(j).big();
                if (mi.name > mj.name) {
                    std::swap(mi, mj);
                    std::swap(extTypes[prefix+i], extTypes[prefix+j]);
                }
            }
        }
    }
}


/***********************************************************************
* fixupProtocol
* Fixes up all of a protocol's method lists.
**********************************************************************/
static void
fixupProtocol(protocol_t *proto)
{
    lockdebug::assert_locked(&runtimeLock);

    if (proto->protocols) {
        for (uintptr_t i = 0; i < proto->protocols->count; i++) {
            protocol_t *sub = remapProtocol(proto->protocols->list[i]);
            if (!sub->isFixedUp()) fixupProtocol(sub);
        }
    }

    fixupProtocolMethodList(proto, proto->instanceMethods, YES, YES);
    fixupProtocolMethodList(proto, proto->classMethods, YES, NO);
    fixupProtocolMethodList(proto, proto->optionalInstanceMethods, NO, YES);
    fixupProtocolMethodList(proto, proto->optionalClassMethods, NO, NO);

    // fixme memory barrier so we can check this with no lock
    proto->setFixedUp();
}


/***********************************************************************
* fixupProtocolIfNeeded
* Fixes up all of a protocol's method lists if they aren't fixed up already.
* Locking: write-locks runtimeLock.
**********************************************************************/
static void
fixupProtocolIfNeeded(protocol_t *proto)
{
    lockdebug::assert_unlocked(&runtimeLock);
    ASSERT(proto);

    if (!proto->isFixedUp()) {
        mutex_locker_t lock(runtimeLock);
        fixupProtocol(proto);
    }
}


static method_list_t *
getProtocolMethodList(protocol_t *proto, bool required, bool instance)
{
    method_list_t **mlistp = nil;
    if (required) {
        if (instance) {
            mlistp = &proto->instanceMethods;
        } else {
            mlistp = &proto->classMethods;
        }
    } else {
        if (instance) {
            mlistp = &proto->optionalInstanceMethods;
        } else {
            mlistp = &proto->optionalClassMethods;
        }
    }

    return *mlistp;
}


/***********************************************************************
* protocol_getMethod_nolock
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static method_t *
protocol_getMethod_nolock(protocol_t *proto, SEL sel,
                          bool isRequiredMethod, bool isInstanceMethod,
                          bool recursive)
{
    lockdebug::assert_locked(&runtimeLock);

    if (!proto  ||  !sel) return nil;

    ASSERT(proto->isFixedUp());

    method_list_t *mlist =
        getProtocolMethodList(proto, isRequiredMethod, isInstanceMethod);
    if (mlist) {
        method_t *m = search_method_list(mlist, sel);
        if (m) return m;
    }

    if (recursive  &&  proto->protocols) {
        method_t *m;
        for (uint32_t i = 0; i < proto->protocols->count; i++) {
            protocol_t *realProto = remapProtocol(proto->protocols->list[i]);
            m = protocol_getMethod_nolock(realProto, sel,
                                          isRequiredMethod, isInstanceMethod,
                                          true);
            if (m) return m;
        }
    }

    return nil;
}


/***********************************************************************
* protocol_getMethod
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
Method
protocol_getMethod(protocol_t *proto, SEL sel, bool isRequiredMethod, bool isInstanceMethod, bool recursive)
{
    if (!proto) return nil;
    fixupProtocolIfNeeded(proto);

    mutex_locker_t lock(runtimeLock);
    return _method_sign(protocol_getMethod_nolock(proto, sel, isRequiredMethod,
                                                  isInstanceMethod, recursive));
}


/***********************************************************************
* protocol_getMethodTypeEncoding_nolock
* Return the @encode string for the requested protocol method.
* Returns nil if the compiler did not emit any extended @encode data.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
const char *
protocol_getMethodTypeEncoding_nolock(protocol_t *proto, SEL sel,
                                      bool isRequiredMethod,
                                      bool isInstanceMethod)
{
    lockdebug::assert_locked(&runtimeLock);

    if (!proto) return nil;
    ASSERT(proto->isFixedUp());

    if (proto->extendedMethodTypes()) {
        method_t *m = protocol_getMethod_nolock(proto, sel,
                                                isRequiredMethod,
                                                isInstanceMethod,
                                                false);
        if (m) {
            uint32_t i = getExtendedTypesIndexForMethod(proto, m,
                                                        isRequiredMethod,
                                                        isInstanceMethod);
            return proto->extendedMethodTypes()[i];
        }
    }

    // No method with that name, or no extended method types. Search
    // incorporated protocols.
    if (proto->protocols) {
        for (uintptr_t i = 0; i < proto->protocols->count; i++) {
            const char *enc =
                protocol_getMethodTypeEncoding_nolock(remapProtocol(proto->protocols->list[i]), sel, isRequiredMethod, isInstanceMethod);
            if (enc) return enc;
        }
    }

    return nil;
}

/***********************************************************************
* _protocol_getMethodTypeEncoding
* Return the @encode string for the requested protocol method.
* Returns nil if the compiler did not emit any extended @encode data.
* Locking: acquires runtimeLock
**********************************************************************/
const char *
_protocol_getMethodTypeEncoding(Protocol *proto_gen, SEL sel,
                                BOOL isRequiredMethod, BOOL isInstanceMethod)
{
    protocol_t *proto = newprotocol(proto_gen);

    if (!proto) return nil;
    fixupProtocolIfNeeded(proto);

    mutex_locker_t lock(runtimeLock);
    return protocol_getMethodTypeEncoding_nolock(proto, sel,
                                                 isRequiredMethod,
                                                 isInstanceMethod);
}


/***********************************************************************
* protocol_t::demangledName
* Returns the (Swift-demangled) name of the given protocol.
* Locking: none
**********************************************************************/
const char *
protocol_t::demangledName()
{
    if (!hasDemangledNameField())
        return mangledName;

    if (! _demangledName) {
        char *de = copySwiftV1DemangledName(mangledName, true/*isProtocol*/);
        if (!CompareAndSwap<const char *>(nullptr, de ?: mangledName,
                                          &_demangledName))
        {
            if (de) free(de);
        }
    }
    return _demangledName;
}

/***********************************************************************
* protocol_getName
* Returns the (Swift-demangled) name of the given protocol.
* Locking: runtimeLock must not be held by the caller
**********************************************************************/
const char *
protocol_getName(Protocol *proto)
{
    if (!proto) return "nil";
    else return newprotocol(proto)->demangledName();
}


/***********************************************************************
* protocol_getInstanceMethodDescription
* Returns the description of a named instance method.
* Locking: runtimeLock must not be held by the caller
**********************************************************************/
struct objc_method_description
protocol_getMethodDescription(Protocol *p, SEL aSel,
                              BOOL isRequiredMethod, BOOL isInstanceMethod)
{
    Method mSigned =
        protocol_getMethod(newprotocol(p), aSel,
                           isRequiredMethod, isInstanceMethod, true);
    method_t *m = _method_auth(mSigned);
    // method_getDescription is inefficient for small methods. Don't bother
    // trying to use it, just make our own.
    if (m) return (struct objc_method_description){m->name(), (char *)m->types()};
    else return (struct objc_method_description){nil, nil};
}


/***********************************************************************
* protocol_conformsToProtocol_nolock
* Returns YES if self conforms to other.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static bool
protocol_conformsToProtocol_nolock(protocol_t *self, protocol_t *other)
{
    lockdebug::assert_locked(&runtimeLock);

    if (!self  ||  !other) {
        return NO;
    }

    // protocols need not be fixed up

    if (0 == strcmp(self->mangledName, other->mangledName)) {
        return YES;
    }

    if (self->protocols) {
        uintptr_t i;
        for (i = 0; i < self->protocols->count; i++) {
            protocol_t *proto = remapProtocol(self->protocols->list[i]);
            if (other == proto) {
              return YES;
            }
            if (0 == strcmp(other->mangledName, proto->mangledName)) {
                return YES;
            }
            if (protocol_conformsToProtocol_nolock(proto, other)) {
                return YES;
            }
        }
    }

    return NO;
}


/***********************************************************************
* protocol_conformsToProtocol
* Returns YES if self conforms to other.
* Locking: acquires runtimeLock
**********************************************************************/
BOOL protocol_conformsToProtocol(Protocol *self, Protocol *other)
{
    mutex_locker_t lock(runtimeLock);
    return protocol_conformsToProtocol_nolock(newprotocol(self),
                                              newprotocol(other));
}


/***********************************************************************
* protocol_isEqual
* Return YES if two protocols are equal (i.e. conform to each other)
* Locking: acquires runtimeLock
**********************************************************************/
BOOL protocol_isEqual(Protocol *self, Protocol *other)
{
    if (self == other) return YES;
    if (!self  ||  !other) return NO;

    if (!protocol_conformsToProtocol(self, other)) return NO;
    if (!protocol_conformsToProtocol(other, self)) return NO;

    return YES;
}


/***********************************************************************
* protocol_copyMethodDescriptionList
* Returns descriptions of a protocol's methods.
* Locking: acquires runtimeLock
**********************************************************************/
struct objc_method_description *
protocol_copyMethodDescriptionList(Protocol *p,
                                   BOOL isRequiredMethod,BOOL isInstanceMethod,
                                   unsigned int *outCount)
{
    protocol_t *proto = newprotocol(p);
    struct objc_method_description *result = nil;
    unsigned int count = 0;

    if (!proto) {
        if (outCount) *outCount = 0;
        return nil;
    }

    fixupProtocolIfNeeded(proto);

    mutex_locker_t lock(runtimeLock);

    method_list_t *mlist =
        getProtocolMethodList(proto, isRequiredMethod, isInstanceMethod);

    if (mlist) {
        result = (struct objc_method_description *)
            calloc(mlist->count + 1, sizeof(struct objc_method_description));
        for (const auto& meth : *mlist) {
            result[count].name = meth.name();
            result[count].types = (char *)meth.types();
            count++;
        }
    }

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* protocol_getProperty
* fixme
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static property_t *
protocol_getProperty_nolock(protocol_t *proto, const char *name,
                            bool isRequiredProperty, bool isInstanceProperty)
{
    lockdebug::assert_locked(&runtimeLock);

    if (!isRequiredProperty) {
        // Only required properties are currently supported.
        return nil;
    }

    property_list_t *plist = isInstanceProperty ?
        proto->instanceProperties : proto->classProperties();
    if (plist) {
        for (auto& prop : *plist) {
            if (0 == strcmp(name, prop.name)) {
                return &prop;
            }
        }
    }

    if (proto->protocols) {
        uintptr_t i;
        for (i = 0; i < proto->protocols->count; i++) {
            protocol_t *p = remapProtocol(proto->protocols->list[i]);
            property_t *prop =
                protocol_getProperty_nolock(p, name,
                                            isRequiredProperty,
                                            isInstanceProperty);
            if (prop) return prop;
        }
    }

    return nil;
}

objc_property_t protocol_getProperty(Protocol *p, const char *name,
                              BOOL isRequiredProperty, BOOL isInstanceProperty)
{
    if (!p  ||  !name) return nil;

    mutex_locker_t lock(runtimeLock);
    return (objc_property_t)
        protocol_getProperty_nolock(newprotocol(p), name,
                                    isRequiredProperty, isInstanceProperty);
}


/***********************************************************************
* protocol_copyPropertyList
* protocol_copyPropertyList2
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
static property_t **
copyPropertyList(property_list_t *plist, unsigned int *outCount)
{
    property_t **result = nil;
    unsigned int count = 0;

    if (plist) {
        count = plist->count;
    }

    if (count > 0) {
        result = (property_t **)malloc((count+1) * sizeof(property_t *));

        count = 0;
        for (auto& prop : *plist) {
            result[count++] = &prop;
        }
        result[count] = nil;
    }

    if (outCount) *outCount = count;
    return result;
}

objc_property_t *
protocol_copyPropertyList2(Protocol *proto, unsigned int *outCount,
                           BOOL isRequiredProperty, BOOL isInstanceProperty)
{
    if (!proto  ||  !isRequiredProperty) {
        // Optional properties are not currently supported.
        if (outCount) *outCount = 0;
        return nil;
    }

    mutex_locker_t lock(runtimeLock);

    property_list_t *plist = isInstanceProperty
        ? newprotocol(proto)->instanceProperties
        : newprotocol(proto)->classProperties();
    return (objc_property_t *)copyPropertyList(plist, outCount);
}

objc_property_t *
protocol_copyPropertyList(Protocol *proto, unsigned int *outCount)
{
    return protocol_copyPropertyList2(proto, outCount,
                                      YES/*required*/, YES/*instance*/);
}


/***********************************************************************
* protocol_copyProtocolList
* Copies this protocol's incorporated protocols.
* Does not copy those protocol's incorporated protocols in turn.
* Locking: acquires runtimeLock
**********************************************************************/
Protocol * __unsafe_unretained *
protocol_copyProtocolList(Protocol *p, unsigned int *outCount)
{
    unsigned int count = 0;
    Protocol **result = nil;
    protocol_t *proto = newprotocol(p);

    if (!proto) {
        if (outCount) *outCount = 0;
        return nil;
    }

    mutex_locker_t lock(runtimeLock);

    if (proto->protocols) {
        count = (unsigned int)proto->protocols->count;
    }
    if (count > 0) {
        result = (Protocol **)malloc((count+1) * sizeof(Protocol *));

        unsigned int i;
        for (i = 0; i < count; i++) {
            result[i] = (Protocol *)remapProtocol(proto->protocols->list[i]);
        }
        result[i] = nil;
    }

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* objc_allocateProtocol
* Creates a new protocol. The protocol may not be used until
* objc_registerProtocol() is called.
* Returns nil if a protocol with the same name already exists.
* Locking: acquires runtimeLock
**********************************************************************/
Protocol *
objc_allocateProtocol(const char *name)
{
    mutex_locker_t lock(runtimeLock);

    if (getProtocol(name)) {
        return nil;
    }

    protocol_t *result = (protocol_t *)calloc(sizeof(protocol_t), 1);

    extern objc_class OBJC_CLASS_$___IncompleteProtocol;
    Class cls = (Class)&OBJC_CLASS_$___IncompleteProtocol;
    result->initProtocolIsa(cls);
    result->size = sizeof(protocol_t);
    // fixme mangle the name if it looks swift-y?
    result->mangledName = strdupIfMutable(name);

    // fixme reserve name without installing

    return (Protocol *)result;
}


/***********************************************************************
 * signProtocolMethodList
 * Sign a method list for a protocol.
 **********************************************************************/
static void
signProtocolMethodList(method_list_t *list)
{
    if (!list)
        return;

    size_t count = list->count;
    for (size_t n = 0; n < count; ++n) {
        struct method_t::big old = list->get(n).big();
#if TARGET_OS_EXCLAVEKIT
        auto &meth = list->get(n).bigStripped();
#else
        auto &meth = list->get(n).bigSigned();
#endif
        meth.name = old.name;
        meth.types = old.types;
        meth.imp = nil;
    }
}

/***********************************************************************
* objc_registerProtocol
* Registers a newly-constructed protocol. The protocol is now
* ready for use and immutable.
* Locking: acquires runtimeLock
**********************************************************************/
void objc_registerProtocol(Protocol *proto_gen)
{
    protocol_t *proto = newprotocol(proto_gen);

    mutex_locker_t lock(runtimeLock);

    extern objc_class OBJC_CLASS_$___IncompleteProtocol;
    Class oldcls = (Class)&OBJC_CLASS_$___IncompleteProtocol;
    extern objc_class OBJC_CLASS_$_Protocol;
    Class cls = (Class)&OBJC_CLASS_$_Protocol;

    if (proto->ISA() == cls) {
        _objc_inform("objc_registerProtocol: protocol '%s' was already "
                     "registered!", proto->nameForLogging());
        return;
    }
    if (proto->ISA() != oldcls) {
        _objc_inform("objc_registerProtocol: protocol '%s' was not allocated "
                     "with objc_allocateProtocol!", proto->nameForLogging());
        return;
    }

#if TARGET_OS_EXCLAVEKIT
    // Sign all of the method lists
    signProtocolMethodList(proto->instanceMethods);
    signProtocolMethodList(proto->classMethods);
    signProtocolMethodList(proto->optionalInstanceMethods);
    signProtocolMethodList(proto->optionalClassMethods);
#endif

    // NOT initProtocolIsa(). The protocol object may already
    // have been retained and we must preserve that count.
    proto->changeIsa(cls);

    // Don't add this protocol if we already have it.
    // Should we warn on duplicates?
    if (getProtocol(proto->mangledName) == nil) {
        NXMapKeyCopyingInsert(protocols(), proto->mangledName, proto);
    }
}


/***********************************************************************
* protocol_addProtocol
* Adds an incorporated protocol to another protocol.
* No method enforcement is performed.
* `proto` must be under construction. `addition` must not.
* Locking: acquires runtimeLock
**********************************************************************/
void
protocol_addProtocol(Protocol *proto_gen, Protocol *addition_gen)
{
    protocol_t *proto = newprotocol(proto_gen);
    protocol_t *addition = newprotocol(addition_gen);

    extern objc_class OBJC_CLASS_$___IncompleteProtocol;
    Class cls = (Class)&OBJC_CLASS_$___IncompleteProtocol;

    if (!proto_gen) return;
    if (!addition_gen) return;

    mutex_locker_t lock(runtimeLock);

    if (proto->ISA() != cls) {
        _objc_inform("protocol_addProtocol: modified protocol '%s' is not "
                     "under construction!", proto->nameForLogging());
        return;
    }
    if (addition->ISA() == cls) {
        _objc_inform("protocol_addProtocol: added protocol '%s' is still "
                     "under construction!", addition->nameForLogging());
        return;
    }

    protocol_list_t *protolist = proto->protocols;
    if (!protolist) {
        protolist = (protocol_list_t *)
            calloc(1, sizeof(protocol_list_t)
                             + sizeof(protolist->list[0]));
    } else {
        protolist = (protocol_list_t *)
            realloc(protolist, protocol_list_size(protolist)
                              + sizeof(protolist->list[0]));
    }

    protolist->list[protolist->count++] = (protocol_ref_t)addition;
    proto->protocols = protolist;
}


/***********************************************************************
* protocol_addMethodDescription
* Adds a method to a protocol. The protocol must be under construction.
* Locking: acquires runtimeLock
**********************************************************************/
static void
protocol_addMethod_nolock(method_list_t*& list, SEL name, const char *types)
{
    if (!list) {
        list = (method_list_t *)calloc(method_list_t::byteSize(sizeof(struct method_t::big), 1), 1);
        list->entsizeAndFlags = sizeof(struct method_t::big);
    } else {
        size_t size = list->byteSize() + list->entsize();
        list = (method_list_t *)realloc(list, size);
    }

    auto &meth = list->get(list->count++).big();
    meth.name = name;
    meth.types = types ? strdupIfMutable(types) : "";
    meth.imp = nil;
}

void
protocol_addMethodDescription(Protocol *proto_gen, SEL name, const char *types,
                              BOOL isRequiredMethod, BOOL isInstanceMethod)
{
    protocol_t *proto = newprotocol(proto_gen);

    extern objc_class OBJC_CLASS_$___IncompleteProtocol;
    Class cls = (Class)&OBJC_CLASS_$___IncompleteProtocol;

    if (!proto_gen) return;

    mutex_locker_t lock(runtimeLock);

    if (proto->ISA() != cls) {
        _objc_inform("protocol_addMethodDescription: protocol '%s' is not "
                     "under construction!", proto->nameForLogging());
        return;
    }

    if (isRequiredMethod  &&  isInstanceMethod) {
        protocol_addMethod_nolock(proto->instanceMethods, name, types);
    } else if (isRequiredMethod  &&  !isInstanceMethod) {
        protocol_addMethod_nolock(proto->classMethods, name, types);
    } else if (!isRequiredMethod  &&  isInstanceMethod) {
        protocol_addMethod_nolock(proto->optionalInstanceMethods, name,types);
    } else /*  !isRequiredMethod  &&  !isInstanceMethod) */ {
        protocol_addMethod_nolock(proto->optionalClassMethods, name, types);
    }
}


/***********************************************************************
* protocol_addProperty
* Adds a property to a protocol. The protocol must be under construction.
* Locking: acquires runtimeLock
**********************************************************************/
static void
protocol_addProperty_nolock(property_list_t *&plist, const char *name,
                            const objc_property_attribute_t *attrs,
                            unsigned int count)
{
    if (!plist) {
        plist = (property_list_t *)calloc(property_list_t::byteSize(sizeof(property_t), 1), 1);
        plist->entsizeAndFlags = sizeof(property_t);
        plist->count = 1;
    } else {
        plist->count++;
        plist = (property_list_t *)realloc(plist, plist->byteSize());
    }

    property_t& prop = plist->get(plist->count - 1);
    prop.name = strdupIfMutable(name);
    prop.attributes = copyPropertyAttributeString(attrs, count);
}

void
protocol_addProperty(Protocol *proto_gen, const char *name,
                     const objc_property_attribute_t *attrs,
                     unsigned int count,
                     BOOL isRequiredProperty, BOOL isInstanceProperty)
{
    protocol_t *proto = newprotocol(proto_gen);

    extern objc_class OBJC_CLASS_$___IncompleteProtocol;
    Class cls = (Class)&OBJC_CLASS_$___IncompleteProtocol;

    if (!proto) return;
    if (!name) return;

    mutex_locker_t lock(runtimeLock);

    if (proto->ISA() != cls) {
        _objc_inform("protocol_addProperty: protocol '%s' is not "
                     "under construction!", proto->nameForLogging());
        return;
    }

    if (isRequiredProperty  &&  isInstanceProperty) {
        protocol_addProperty_nolock(proto->instanceProperties, name, attrs, count);
    }
    else if (isRequiredProperty  &&  !isInstanceProperty) {
        protocol_addProperty_nolock(proto->_classProperties, name, attrs, count);
    }
    //else if (!isRequiredProperty  &&  isInstanceProperty) {
    //    protocol_addProperty_nolock(proto->optionalInstanceProperties, name, attrs, count);
    //}
    //else /*  !isRequiredProperty  &&  !isInstanceProperty) */ {
    //    protocol_addProperty_nolock(proto->optionalClassProperties, name, attrs, count);
    //}
}

static size_t
objc_getRealizedClassList_nolock(Class *buffer, size_t bufferLen)
{
    size_t count = 0;

    if (buffer) {
        size_t c = 0;
        foreach_realized_class([=, &count, &c](Class cls) {
            count++;
            if (c < bufferLen) {
                buffer[c++] = cls;
            }
            return true;
        });
    } else {
        foreach_realized_class([&count](Class cls) {
            count++;
            return true;
        });
    }

    return count;
}

// This function is called by LLDB to fetch the class list. Make sure it
// always gets emitted.
__attribute__((used))
static Class *
objc_copyRealizedClassList_nolock(unsigned int *outCount)
{
    Class *result = nil;
    unsigned int count = 0;

    foreach_realized_class([&count](Class cls) {
        count++;
        return true;
    });

    if (count > 0) {
        unsigned int c = 0;

        result = (Class *)malloc((1+count) * sizeof(Class));
        foreach_realized_class([=, &c](Class cls) {
            result[c++] = cls;
            return true;
        });
        result[c] = nil;
    }

    if (outCount) *outCount = count;
    return result;
}

/***********************************************************************
 * _objc_getRealizedClassList_trylock
 * Returns pointers to all realized classes.
 * Locking: attempts to acquire runtimeLock, fails gracefully if it's already locked
 **********************************************************************/
size_t
_objc_getRealizedClassList_trylock(Class *buffer, size_t bufferLen) {
    bool locked = runtimeLock.tryLock();
    if (!locked)
        return SIZE_MAX;

    size_t result = objc_getRealizedClassList_nolock(buffer, bufferLen);
    runtimeLock.unlock();
    return result;
}

/***********************************************************************
 * objc_getClassList
 * Returns pointers to all classes.
 * This requires all classes be realized, which is regretfully non-lazy.
 * Locking: acquires runtimeLock
 **********************************************************************/
int
objc_getClassList(Class *buffer, int bufferLen)
{
    mutex_locker_t lock(runtimeLock);

    realizeAllClasses();

    return (int)objc_getRealizedClassList_nolock(buffer, bufferLen);
}

/***********************************************************************
 * objc_copyClassList
 * Returns pointers to Realized classes.
 *
 * outCount may be nil. *outCount is the number of classes returned.
 * If the returned array is not nil, it is nil-terminated and must be
 * freed with free().
 * Locking: write-locks runtimeLock
 **********************************************************************/
Class *
objc_copyRealizedClassList(unsigned int *outCount)
{
    mutex_locker_t lock(runtimeLock);

    return objc_copyRealizedClassList_nolock(outCount);
}


/***********************************************************************
* objc_copyClassList
* Returns pointers to all classes.
* This requires all classes be realized, which is regretfully non-lazy.
*
* outCount may be nil. *outCount is the number of classes returned.
* If the returned array is not nil, it is nil-terminated and must be
* freed with free().
* Locking: write-locks runtimeLock
**********************************************************************/
Class *
objc_copyClassList(unsigned int *outCount)
{
    mutex_locker_t lock(runtimeLock);

    realizeAllClasses();

    return objc_copyRealizedClassList_nolock(outCount);
}

/***********************************************************************
 * _objc_beginClassEnumeration
 * Initialize an objc_class_enumerator_t
 *
 * Locking: acquires runtimeLock.
 **********************************************************************/
void
_objc_beginClassEnumeration(const void * _Nullable image,
                            const char * _Nullable namePrefix,
                            Protocol * _Nullable conformingTo,
                            Class _Nullable subclassing,
                            objc_class_enumerator_t * _Nonnull enumerator)
{
    memset(enumerator, 0, sizeof(*enumerator));

    enumerator->image = image;
    enumerator->namePrefix = namePrefix;
    enumerator->conformingTo = conformingTo;
    enumerator->subclassing = subclassing;

    if (namePrefix)
        enumerator->namePrefixLen = strlen(namePrefix);

    if (image == OBJC_DYNAMIC_CLASSES) {
        // For the dynamic class case, grab a list of dynamically created
        // classes when enumeration starts.
        mutex_locker_t lock(runtimeLock);

        auto set = objc::allocatedClasses.get();
        Class *dynamicList = (Class *)calloc(sizeof(Class), set.size());
        size_t dynamicCount = 0;

        for (Class cls : set) {
            if ((cls->data()->flags & (RW_CONSTRUCTED|RW_META))
                == RW_CONSTRUCTED) {
                dynamicList[dynamicCount++] = cls;
            }
        }

        Class *shrunkList = (Class *)realloc(dynamicList,
                                             sizeof(Class) * dynamicCount);
        if (shrunkList)
            dynamicList = shrunkList;

        enumerator->imageClassList = dynamicList;
        enumerator->imageClassNdx = 0;
        enumerator->imageClassCount = dynamicCount;
    }
}

/***********************************************************************
 * _classConformsToProtocol_unrealized
 * Test if a potentially unrealized class conforms to a protocol,
 * without realizing it.
 *
 * Locking: caller must lock runtimeLock.
 **********************************************************************/
bool
_classConformsToProtocol_unrealized(Class _Nonnull cls,
                                    Protocol * _Nonnull protocol)
{
    lockdebug::assert_locked(&runtimeLock);

    protocol_t *proto = newprotocol(protocol);
    protocol_array_t protocols;

    if (cls->isRealized()) {
        protocols = cls->data()->protocols();
    } else {
        auto ro = cls->safe_ro();
        protocols = protocol_array_t{ro->baseProtocols};
    }

    for (const auto& protoRef : protocols) {
        protocol_t *p = remapProtocol(protoRef);
        if (p == proto || protocol_conformsToProtocol_nolock(p, proto)) {
            return true;
        }
    }

    if (!cls->isRealized()) {
        // If the class is unrealized, search for categories that might
        // conform to the protocol as well
        bool isMeta = cls->isMetaClassMaybeUnrealized();
        auto &map = objc::unattachedCategories.get();
        auto it = map.find(cls);

        if (it != map.end()) {
            objc::category_list &list = it->second;
            const locstamped_category_t *cats = list.array();
            uint32_t catCount = list.count();

            for (uint32_t n = 0; n < catCount; ++n) {
                protocol_list_t *protoList
                    = cats[n].cat->protocolsForMeta(isMeta);
                if (!protoList)
                    continue;

                for (const auto& protoRef : *protoList) {
                    protocol_t *p = remapProtocol(protoRef);
                    if (p == proto
                        || protocol_conformsToProtocol_nolock(p, proto)) {
                        return true;
                    }
                }
            }
        }
    }

    return false;
}

/***********************************************************************
 * _classOrSuperclassConformsToProtocol_unrealized
 * Test if a potentially unrealized class *or its superclasses*
 * conform to the specified protocol, without realizing anything.
 *
 * Locking: caller must hold runtimeLock.
 **********************************************************************/
bool
_classOrSuperclassConformsToProtocol_unrealized(Class _Nonnull cls,
                                                Protocol * _Nonnull proto)
{
    for (Class tcls = cls; tcls; tcls = remapClass(tcls->getSuperclass())) {
        if (_classConformsToProtocol_unrealized(tcls, proto))
            return true;
    }

    return false;
}

/***********************************************************************
 * _objc_enumerateNextClass
 * Return the next class in an enumeration.
 *
 * Locking: acquires runtimeLock.
 **********************************************************************/
Class _Nullable
_objc_enumerateNextClass(objc_class_enumerator_t * _Nonnull enumerator)
{
    mutex_locker_t lock(runtimeLock);

    if (!enumerator->imageClassList) {
        ASSERT(enumerator->image != OBJC_DYNAMIC_CLASSES);

        // Find the runtime's header_info struct for the image
        header_info *hi;
        for (hi = FirstHeader; hi != NULL; hi = hi->getNext()) {
            if (hi->mhdr() == (const headerType *)enumerator->image) {
                break;
            }
        }

        if (hi) {
            enumerator->imageClassList = (Class *)hi->classlist(&enumerator->imageClassCount);
        }

        if (!enumerator->imageClassList)
            return nil;

        enumerator->imageClassNdx = 0;
    }

    while (enumerator->imageClassNdx < enumerator->imageClassCount) {
        size_t ndx = enumerator->imageClassNdx++;
        Class cls = remapClass(enumerator->imageClassList[ndx]);
        if (!cls)
            continue;

        // Filter by name prefix
        if (enumerator->namePrefix) {
            const char *name = cls->demangledName(/* needs lock */false);
            if (memcmp(name, enumerator->namePrefix,
                       enumerator->namePrefixLen) != 0)
                continue;
        }

        // Filter by conformance
        if (enumerator->conformingTo
            && !_classOrSuperclassConformsToProtocol_unrealized(cls,
                                                 enumerator->conformingTo))
            continue;

        // Filter by superclass
        if (enumerator->subclassing) {
            Class scls = remapClass(cls->getSuperclass());
            while (scls && scls != enumerator->subclassing)
                scls = remapClass(scls->getSuperclass());
            if (!scls)
                continue;
        }

        // If we get here, we've found a match, so realize and return it
        realizeClassMaybeSwiftAndLeaveLocked(cls, runtimeLock);

        return cls;
    }

    return nil;
}

/***********************************************************************
 * _objc_endClassEnumeration
 * Release any resources associated with an enumeration.
 *
 * Locking: none.
 **********************************************************************/
void
_objc_endClassEnumeration(objc_class_enumerator_t * _Nonnull enumerator)
{
    if (enumerator->image == OBJC_DYNAMIC_CLASSES) {
        /* If we're doing dynamic class enumeration, we'll have allocated
           a class list. */
        free((void *)enumerator->imageClassList);
    }
}

/***********************************************************************
 * objc_enumerateClasses
 * Enumerates classes, filtering by image, name, protocol conformance
 * and superclass.
 *
 * Locking: acquires and drops runtimeLock during enumeration.
 **********************************************************************/
void
objc_enumerateClasses(const void * _Nullable image,
                      const char * _Nullable namePrefix,
                      Protocol * _Nullable conformingTo,
                      Class _Nullable subclassing,
                      void (^ _Nonnull block)(Class aClass, BOOL *stop)
                      __attribute__((noescape)))
{
    objc_class_enumerator_t enumerator;
    const struct mach_header *imageHeader;

    if (!image) {
        // NULL means search caller's image
        void *caller = __builtin_return_address(0);
        imageHeader = dyld_image_header_containing_address(caller);
        if (!imageHeader) {
            _objc_inform("unable to find caller's image");
            return;
        }
    } else if (image == OBJC_DYNAMIC_CLASSES) {
        imageHeader = (struct mach_header *)OBJC_DYNAMIC_CLASSES;
    } else {
        imageHeader = _dyld_get_dlopen_image_header(const_cast<void *>(image));
        if (!imageHeader && image == dyld_image_header_containing_address(image)) {
            // The caller supplied a valid Mach header known to dyld, so accept
            // it as-is.
            imageHeader = reinterpret_cast<const struct mach_header *>(image);
        }
        if (!imageHeader) {
            _objc_inform("unable to find mach header for image");
            return;
        }
    }

    _objc_beginClassEnumeration(imageHeader, namePrefix, conformingTo,
                                subclassing, &enumerator);

    Class cls;
    BOOL stop = NO;
    while (!stop && (cls = _objc_enumerateNextClass(&enumerator))) {
        block(cls, &stop);
    }

    _objc_endClassEnumeration(&enumerator);
}

void
_class_setCustomDeallocInitiation(_Nonnull Class cls)
{
    // Clients may stick this in their `init` method or similar just to have
    // an easy place to call it before any instances are destroyed. Fast path
    // the case where it's already set.
    if (cls->hasCustomDeallocInitiation())
        return;

    {
        mutex_locker_t guard(runtimeLock);

        foreach_realized_class_and_subclass(cls, [](Class subclass) -> bool {
            subclass->setHasCustomDeallocInitiation();
            return true;
        });
    }
}

/***********************************************************************
 * class_copyImpCache
 * Returns the current content of the Class IMP Cache
 *
 * outCount may be nil. *outCount is the number of entries returned.
 * If the returned array is not nil, it is nil-terminated and must be
 * freed with free().
 * Locking: write-locks cacheUpdateLock
 **********************************************************************/
objc_imp_cache_entry *
class_copyImpCache(Class cls, int *outCount)
{
    objc_imp_cache_entry *buffer = nullptr;

#if CONFIG_USE_CACHE_LOCK
    mutex_locker_t lock(cacheUpdateLock);
#else
    mutex_locker_t lock(runtimeLock);
#endif

    cache_t &cache = cls->cache;
    int count = (int)cache.occupied();

    if (count) {
        buffer = (objc_imp_cache_entry *)calloc(1+count, sizeof(objc_imp_cache_entry));
        cache.copyCacheNolock(buffer, count);
    }

    if (outCount) *outCount = count;
    return buffer;
}


/***********************************************************************
* objc_copyProtocolList
* Returns pointers to all protocols.
* Locking: read-locks runtimeLock
**********************************************************************/
Protocol * __unsafe_unretained *
objc_copyProtocolList(unsigned int *outCount)
{
    mutex_locker_t lock(runtimeLock);

    NXMapTable *protocol_map = protocols();

    // Protocols from pre-optimized images won't be in the protocol map, so scan
    // images directly and add any protocols that aren't in the map.
    objc::DenseMap<const char*, Protocol*> preoptimizedProtocols;
    {
        header_info *hi;
        for (hi = FirstHeader; hi; hi = hi->getNext()) {
            size_t count, i;
            const protocol_t * const *protolist = hi->protocollist(&count);
            for (i = 0; i < count; i++) {
                const protocol_t* protocol = protolist[i];

                // Skip protocols we have in the run time map.  These likely
                // correspond to protocols added dynamically which have the same
                // name as a protocol found later in a dlopen'ed shared cache image.
                if (NXMapGet(protocol_map, protocol->mangledName) != nil)
                    continue;

                // The protocols in the shared cache protolist point to their
                // original on-disk object, not the optimized one.  We can use the name
                // to find the optimized one.
                Protocol* optimizedProto = getPreoptimizedProtocol(protocol->mangledName);
                preoptimizedProtocols.insert({ protocol->mangledName, optimizedProto });
            }
        }
    }

    unsigned int count = NXCountMapTable(protocol_map) + (unsigned int)preoptimizedProtocols.size();
    if (count == 0) {
        if (outCount) *outCount = 0;
        return nil;
    }

    Protocol **result = (Protocol **)malloc((count+1) * sizeof(Protocol*));

    unsigned int i = 0;
    Protocol *proto;
    const char *name;
    NXMapState state = NXInitMapState(protocol_map);
    while (NXNextMapState(protocol_map, &state,
                          (const void **)&name, (const void **)&proto))
    {
        result[i++] = proto;
    }

    // Add any protocols found in the pre-optimized table
    for (auto it : preoptimizedProtocols) {
        result[i++] = it.second;
    }

    result[i++] = nil;
    ASSERT(i == count+1);

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* objc_getProtocol
* Get a protocol by name, or return nil
* Locking: read-locks runtimeLock
**********************************************************************/
Protocol *objc_getProtocol(const char *name)
{
    mutex_locker_t lock(runtimeLock);
    return getProtocol(name);
}


/***********************************************************************
* class_copyMethodList
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
Method *
class_copyMethodList(Class cls, unsigned int *outCount)
{
    unsigned int count = 0;
    Method *result = nil;

    if (!cls) {
        if (outCount) *outCount = 0;
        return nil;
    }

    mutex_locker_t lock(runtimeLock);
    const auto methods = cls->data()->methods();

    ASSERT(cls->isRealized());

    count = methods.count();

    if (count > 0) {
        auto iterator = methods.signedBegin();
        auto end = methods.signedEnd();

        result = (Method *)malloc((count + 1) * sizeof(Method));

        count = 0;
        for (; iterator != end; ++iterator) {
            result[count++] = _method_sign(&*iterator);
        }
        result[count] = nil;
    }

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* class_copyIvarList
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
Ivar *
class_copyIvarList(Class cls, unsigned int *outCount)
{
    const ivar_list_t *ivars;
    Ivar *result = nil;
    unsigned int count = 0;

    if (!cls) {
        if (outCount) *outCount = 0;
        return nil;
    }

    mutex_locker_t lock(runtimeLock);

    ASSERT(cls->isRealized());

    if ((ivars = cls->data()->ro()->ivars)  &&  ivars->count) {
        result = (Ivar *)malloc((ivars->count+1) * sizeof(Ivar));

        for (auto& ivar : *ivars) {
            if (!ivar.offset) continue;  // anonymous bitfield
            result[count++] = &ivar;
        }
        result[count] = nil;
    }

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* class_copyPropertyList. Returns a heap block containing the
* properties declared in the class, or nil if the class
* declares no properties. Caller must free the block.
* Does not copy any superclass's properties.
* Locking: read-locks runtimeLock
**********************************************************************/
objc_property_t *
class_copyPropertyList(Class cls, unsigned int *outCount)
{
    if (!cls) {
        if (outCount) *outCount = 0;
        return nil;
    }

    mutex_locker_t lock(runtimeLock);

    checkIsKnownClass(cls);
    ASSERT(cls->isRealized());

    auto rw = cls->data();

    property_t **result = nil;
    auto const properties = rw->properties();
    unsigned int count = properties.count();
    if (count > 0) {
        result = (property_t **)malloc((count + 1) * sizeof(property_t *));

        count = 0;
        for (auto& prop : properties) {
            result[count++] = &prop;
        }
        result[count] = nil;
    }

    if (outCount) *outCount = count;
    return (objc_property_t *)result;
}


/***********************************************************************
* _category_getName
* Returns a category's name.
* Locking: none
**********************************************************************/
const char *
_category_getName(Category cat)
{
    return cat->name;
}


/***********************************************************************
* _category_getClassName
* Returns a category's class's name
* Called only from add_category_to_loadable_list and
* remove_category_from_loadable_list for logging purposes.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
const char *
_category_getClassName(Category cat)
{
    lockdebug::assert_locked(&runtimeLock);
    return remapClass(cat->cls)->nameForLogging();
}


/***********************************************************************
* _category_getClass
* Returns a category's class
* Called only by call_category_loads.
* Locking: read-locks runtimeLock
**********************************************************************/
Class
_category_getClass(Category cat)
{
    mutex_locker_t lock(runtimeLock);
    Class result = remapClass(cat->cls);
    ASSERT(result->isRealized());  // ok for call_category_loads' usage
    return result;
}


/***********************************************************************
* category_t::propertiesForMeta
* Return a category's instance or class properties.
* hi is the image containing the category.
**********************************************************************/
property_list_t *
category_t::propertiesForMeta(bool isMeta, struct header_info *hi) const
{
    if (!isMeta) return instanceProperties;
    else if (hi->info()->hasCategoryClassProperties()) return _classProperties;
    else return nil;
}


/***********************************************************************
* class_copyProtocolList
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
Protocol * __unsafe_unretained *
class_copyProtocolList(Class cls, unsigned int *outCount)
{
    unsigned int count = 0;
    Protocol **result = nil;

    if (!cls) {
        if (outCount) *outCount = 0;
        return nil;
    }

    mutex_locker_t lock(runtimeLock);
    const auto protocols = cls->data()->protocols();

    checkIsKnownClass(cls);

    ASSERT(cls->isRealized());

    count = protocols.count();

    if (count > 0) {
        result = (Protocol **)malloc((count+1) * sizeof(Protocol *));

        count = 0;
        for (const auto& proto : protocols) {
            result[count++] = (Protocol *)remapProtocol(proto);
        }
        result[count] = nil;
    }

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* objc_copyImageNames
* Copies names of loaded images with ObjC contents.
*
* Locking: acquires runtimeLock
**********************************************************************/
const char **objc_copyImageNames(unsigned int *outCount)
{
    std::vector<const headerType *> headers;

    {
        mutex_locker_t lock(runtimeLock);

        for (header_info *hi = FirstHeader; hi != nil; hi = hi->getNext()) {
            headers.push_back(hi->mhdr());
        }
    }

    const char **names = (const char **)
        malloc((headers.size()+1) * sizeof(char *));

    unsigned int count = 0;
    for (auto *header : headers)
        if (const char *fname = dyld_image_path_containing_address(header))
            names[count++] = fname;

    names[count] = nil;

    if (count == 0) {
        // Return nil instead of empty list if there are no images
        free((void *)names);
        names = nil;
    }

    if (outCount) *outCount = count;
    return names;
}


/***********************************************************************
* copyClassNamesForImage_nolock
* Copies class names from the given image.
* Missing weak-import classes are omitted.
* Swift class names are demangled.
*
* Locking: runtimeLock must be held by the caller
**********************************************************************/
const char **
copyClassNamesForImage_nolock(header_info *hi, unsigned int *outCount)
{
    lockdebug::assert_locked(&runtimeLock);
    ASSERT(hi);

    size_t count;
    classref_t const *classlist = hi->classlist(&count);
    const char **names = (const char **)
        malloc((count+1) * sizeof(const char *));

    size_t shift = 0;
    for (size_t i = 0; i < count; i++) {
        Class cls = remapClass(classlist[i]);
        if (cls) {
            names[i-shift] = cls->demangledName(/* needs lock */false);
        } else {
            shift++;  // ignored weak-linked class
        }
    }
    count -= shift;
    names[count] = nil;

    if (outCount) *outCount = (unsigned int)count;
    return names;
}

Class *
copyClassesForImage_nolock(header_info *hi, unsigned int *outCount)
{
    lockdebug::assert_locked(&runtimeLock);
    ASSERT(hi);

    size_t count;
    classref_t const *classlist = hi->classlist(&count);
    Class *classes = (Class *)
        malloc((count+1) * sizeof(Class));

    size_t shift = 0;
    for (size_t i = 0; i < count; i++) {
        Class cls = remapClass(classlist[i]);
        if (cls) {
            classes[i-shift] = cls;
        } else {
            shift++;  // ignored weak-linked class
        }
    }
    count -= shift;
    classes[count] = nil;

    if (outCount) *outCount = (unsigned int)count;
    return classes;
}


// Find the header_info* matching the given path and call the passed in function
// with it, with the runtime lock held. If there is no match, the function is not
// called. Carefully arranges things to avoid acquiring the dyld lock with the
// runtime lock held by always calling dyld_image_path_containing_address with
// the runtime lock unlocked.
template <typename Fn>
static void withHeaderInfoForPath(const char *path, const Fn &f) {
    // We cannot attempt to acquire the dyld lock while holding the ObjC lock,
    // or we may deadlock (rdar://73246373). To find the appropriate header_info
    // we'll perform a three-stage search with a retry loop.
    //
    // 1. With the runtime lock held, gather all mach headers and UUIDs.
    // 2. WITHOUT the runtime lock held, use dyld_image_path_containing_address
    //    to find the mach header and UUID matching the path.
    // 3. With the runtime lock held again, find the header_info with that mach
    //    header. Check the UUID against what we found. If they don't match,
    //    restart and try again. This avoids an ABA problem with concurrent
    //    unloads.

    // Loop until we succeed.
    while (true) {
        // Stage 1: gather mach headers and UUIDs.
        struct uuidWrapper { uuid_t uuid; };
        std::vector<std::pair<const headerType *, uuidWrapper>> headersAndUUIDs;
        {
            mutex_locker_t lock(runtimeLock);

            for (header_info *hi = FirstHeader; hi != nil; hi = hi->getNext()) {
                uuidWrapper wrapper;
                if (_dyld_get_image_uuid((const mach_header *)hi->mhdr(), wrapper.uuid))
                    headersAndUUIDs.push_back({hi->mhdr(), wrapper});
            }
        }

        // Stage 2: locate the match, if any.
        auto match = headersAndUUIDs.begin();
        for (; match != headersAndUUIDs.end(); match++) {
            const char *thisPath = dyld_image_path_containing_address(std::get<const headerType *>(*match));
            if (thisPath && strcmp(thisPath, path) == 0) {
                break;
            }
        }

        // If nothing matches, then we're done, just return.
        if (match == headersAndUUIDs.end())
            return;

        // Stage 3: Find the matching header_info and call.
        auto matchingHeader = std::get<const headerType *>(*match);
        auto matchingUUID = std::get<uuidWrapper>(*match).uuid;
        {
            mutex_locker_t lock(runtimeLock);

            for (header_info *hi = FirstHeader; hi != nil; hi = hi->getNext()) {
                if (hi->mhdr() == matchingHeader) {
                    uuid_t currentUUID;
                    if (_dyld_get_image_uuid((const mach_header *)matchingHeader, currentUUID)) {
                        if (memcmp(currentUUID, matchingUUID, sizeof(currentUUID)) == 0) {
                            // The match is still valid. Call and return.
                            f(hi);
                            return;
                        }
                    }
                    // If we get here, the UUIDs don't match or we couldn't
                    // retrieve the new one. Retry.
                    break;
                }
            }
        }
    }
}


/***********************************************************************
* objc_copyClassNamesForImage
* Copies class names from the named image.
* The image name must be identical to dladdr's dli_fname value.
* Missing weak-import classes are omitted.
* Swift class names are demangled.
*
* Locking: acquires runtimeLock
**********************************************************************/
const char **
objc_copyClassNamesForImage(const char *image, unsigned int *outCount)
{
    if (!image) {
        if (outCount) *outCount = 0;
        return nil;
    }

    const char **result = NULL;
    withHeaderInfoForPath(image, [&](header_info *hi) {
        result = copyClassNamesForImage_nolock(hi, outCount);
    });

    if (!result)
        if (outCount) *outCount = 0;

    return result;
}

Class *
objc_copyClassesForImage(const char *image, unsigned int *outCount)
{
    if (!image) {
        if (outCount) *outCount = 0;
        return nil;
    }

    Class *result = NULL;
    withHeaderInfoForPath(image, [&](header_info *hi) {
        result = copyClassesForImage_nolock(hi, outCount);
    });

    if (!result)
        if (outCount) *outCount = 0;

    return result;
}

/***********************************************************************
* objc_copyClassNamesForImageHeader
* Copies class names from the given image.
* Missing weak-import classes are omitted.
* Swift class names are demangled.
*
* Locking: acquires runtimeLock
**********************************************************************/
const char **
objc_copyClassNamesForImageHeader(const struct mach_header *mh, unsigned int *outCount)
{
    if (!mh) {
        if (outCount) *outCount = 0;
        return nil;
    }

    mutex_locker_t lock(runtimeLock);

    // Find the image.
    header_info *hi;
    for (hi = FirstHeader; hi != nil; hi = hi->getNext()) {
        if (hi->mhdr() == (const headerType *)mh) break;
    }

    if (!hi) {
        if (outCount) *outCount = 0;
        return nil;
    }

    return copyClassNamesForImage_nolock(hi, outCount);
}


/***********************************************************************
* saveTemporaryString
* Save a string in a thread-local FIFO buffer.
* This is suitable for temporary strings generated for logging purposes.
**********************************************************************/
static void
saveTemporaryString(char *str)
{
    // Fixed-size FIFO. We free the first string, shift
    // the rest, and add the new string to the end.
    _objc_pthread_data *data = _objc_fetch_pthread_data(true);
    if (data->printableNames[0]) {
        free(data->printableNames[0]);
    }
    int last = countof(data->printableNames) - 1;
    for (int i = 0; i < last; i++) {
        data->printableNames[i] = data->printableNames[i+1];
    }
    data->printableNames[last] = str;
}


/***********************************************************************
* objc_class::nameForLogging
* Returns the class's name, suitable for display.
* The returned memory is TEMPORARY. Print it or copy it immediately.
* Locking: none
**********************************************************************/
const char *
objc_class::nameForLogging()
{
    // Handle the easy case directly.
    if (isRealized()  ||  isFuture()) {
        if (!isAnySwift()) {
            return data()->ro()->getName();
        }
        auto rwe = data()->ext();
        if (rwe && rwe->demangledName) {
            return rwe->demangledName;
        }
    }

    char *result;

    if (isStubClass()) {
        _objc_asprintf(&result, "<stub class %p>", this);
    } else if (const char *name = nonlazyMangledName()) {
        char *de = copySwiftV1DemangledName(name);
        if (de) result = de;
        else result = strdup(name);
    } else {
        _objc_asprintf(&result, "<lazily named class %p>", this);
    }
    saveTemporaryString(result);
    return result;
}


/***********************************************************************
* objc_class::demangledName
* If realize=false, the class must already be realized or future.
* Locking: runtimeLock may or may not be held by the caller.
**********************************************************************/
mutex_t DemangleCacheLock;
static objc::DenseSet<const char *> *DemangleCache;
const char *
objc_class::demangledName(bool needsLock)
{
    if (!needsLock) {
        lockdebug::assert_locked(&runtimeLock);
    }

    // Return previously demangled name if available.
    if (isRealized()  ||  isFuture()) {
        // Swift metaclasses don't have the is-Swift bit.
        // We can't take this shortcut for them.
        if (isFuture() || (!isMetaClass() && !isAnySwift())) {
            return data()->ro()->getName();
        }
        auto rwe = data()->ext();
        if (rwe && rwe->demangledName) {
            return rwe->demangledName;
        }
    }

    // Try demangling the mangled name.
    const char *mangled = mangledName();
    char *de = copySwiftV1DemangledName(mangled);
    class_rw_ext_t *rwe;

    if (isRealized()  ||  isFuture()) {
        if (needsLock) {
            mutex_locker_t lock(runtimeLock);
            rwe = data()->extAllocIfNeeded();
        } else {
            rwe = data()->extAllocIfNeeded();
        }
        // Class is already realized or future.
        // Save demangling result in rw data.
        // We may not own runtimeLock so use an atomic operation instead.
        if (!CompareAndSwap<const char *>(nullptr, de ?: mangled,
                                          &rwe->demangledName))
        {
            if (de) free(de);
        }
        return rwe->demangledName;
    }

    // Class is not yet realized.
    if (!de) {
        // Name is not mangled. Return it without caching.
        return mangled;
    }

    // Class is not yet realized and name is mangled.
    // Allocate the name but don't save it in the class.
    // Save the name in a side cache instead to prevent leaks.
    // When the class is actually realized we may allocate a second
    // copy of the name, but we don't care.
    // (Previously we would try to realize the class now and save the
    // name there, but realization is more complicated for Swift classes.)

    // Only objc_copyClassNamesForImage() should get here.
    // fixme lldb's calls to class_getName() can also get here when
    // interrogating the dyld shared cache. (rdar://27258517)
    // fixme ASSERT(realize);

    const char *cached;
    {
        mutex_locker_t lock(DemangleCacheLock);
        if (!DemangleCache) {
            DemangleCache = new objc::DenseSet<const char *>{};
        }
        cached = *DemangleCache->insert(de).first;
    }
    if (cached != de) free(de);
    return cached;
}


/***********************************************************************
* class_getName
* fixme
* Locking: may acquire DemangleCacheLock
**********************************************************************/
const char *class_getName(Class cls)
{
    if (!cls) return "nil";
    // fixme lldb calls class_getName() on unrealized classes (rdar://27258517)
    // ASSERT(cls->isRealized()  ||  cls->isFuture());
    return cls->demangledName(/* needs lock */true);
}

/***********************************************************************
* objc_debug_class_getNameRaw
* Locking: may acquire DemangleCacheLock
**********************************************************************/
const char *objc_debug_class_getNameRaw(Class cls)
{
    if (!cls) return "nil";
    const char *name = cls->rawUnsafeMangledName();
    if (!name)
        name = cls->installMangledNameForLazilyNamedClass();
    return name;
}


/***********************************************************************
* class_getVersion
* fixme
* Locking: none
**********************************************************************/
int
class_getVersion(Class cls)
{
    if (!cls) return 0;
    ASSERT(cls->isRealized());
    auto rwe = cls->data()->ext();
    if (rwe) {
        return rwe->version;
    }
    return cls->isMetaClass() ? 7 : 0;
}


/***********************************************************************
* class_setVersion
* fixme
* Locking: none
**********************************************************************/
void
class_setVersion(Class cls, int version)
{
    if (!cls) return;
    ASSERT(cls->isRealized());
    auto rwe = cls->data()->ext();
    if (!rwe) {
        mutex_locker_t lock(runtimeLock);
        rwe = cls->data()->extAllocIfNeeded();
    }

    rwe->version = version;
}

/***********************************************************************
 * search_method_list_inline
 **********************************************************************/
template<class compareFunc>
ALWAYS_INLINE static method_t *
findMethodInSortedMethodList(SEL key, const method_list_t *list, const compareFunc &compare)
{
    ASSERT(list);

    auto first = list->begin();
    auto base = first;

    uint32_t count;

    // When to stop the binary search and move to a linear search.
    const uint32_t threshold = 4;

    for (count = list->count; count > threshold; count >>= 1) {
        auto probe = base + (count >> 1);

        int comparison = compare(probe);
        if (comparison == 0) {
            // `probe` is a match.
            // Rewind looking for the *first* occurrence of this value.
            // This is required for correct category overrides.
            while (probe > first && compare(probe - 1) == 0) {
                probe--;
            }
            return &*probe;
        }

        if (comparison > 0) {
            base = probe + 1;
            count--;
        }
    }

    // Once we've shrunk the range enough, it's faster to do a linear search.
    while (count-- > 0) {
        auto comparison = compare(base);
        if (comparison == 0)
            return &*base;
        if (comparison < 0)
            return nil;
        base++;
    }

    return nil;
}

template<typename T>
ALWAYS_INLINE static int
compare(T lhs, T rhs) {
    if ((uintptr_t)lhs > (uintptr_t)rhs)
        return 1;
    if ((uintptr_t)lhs < (uintptr_t)rhs)
        return -1;
    return 0;
}

ALWAYS_INLINE static method_t *
findMethodInSortedMethodList(SEL key, const method_list_t *list)
{
    switch (list->listKind()) {
        case method_t::Kind::small:
            if (CONFIG_SHARED_CACHE_RELATIVE_DIRECT_SELECTORS && objc::inSharedCache((uintptr_t)list)) {
                if (!objc::inSharedCache((uintptr_t)key))
                    return nil;
                uintptr_t keyOffset = (uintptr_t)key - sharedCacheRelativeMethodBase();
                return findMethodInSortedMethodList(key, list, [=](method_t &m) { return compare(keyOffset, (uintptr_t)m.getSmallNameAsSELOffset()); });
            } else {
                return findMethodInSortedMethodList(key, list, [=](method_t &m) { return compare(key, m.getSmallNameAsSELRef()); });
            }
        case method_t::Kind::big:
            return findMethodInSortedMethodList(key, list, [=](method_t &m) { return compare(key, m.big().name); });
        case method_t::Kind::bigSigned:
            return findMethodInSortedMethodList(key, list, [=](method_t &m) { return compare(key, m.bigSigned().name); });
#if TARGET_OS_EXCLAVEKIT
        case method_t::Kind::bigStripped:
            return findMethodInSortedMethodList(key, list, [=](method_t &m) { return compare(key, m.bigStripped().name); });
#endif
    }
}

template<class getNameFunc>
ALWAYS_INLINE static method_t *
findMethodInUnsortedMethodList(SEL sel, const method_list_t *list, const getNameFunc &getName)
{
    for (auto& meth : *list) {
        if (getName(meth) == sel) return &meth;
    }
    return nil;
}

ALWAYS_INLINE static method_t *
findMethodInUnsortedMethodList(SEL key, const method_list_t *list)
{
    switch (list->listKind()) {
        case method_t::Kind::small:
            if (CONFIG_SHARED_CACHE_RELATIVE_DIRECT_SELECTORS && objc::inSharedCache((uintptr_t)list)) {
                if (!objc::inSharedCache((uintptr_t)key))
                    return nil;
                return findMethodInUnsortedMethodList(key, list, [](method_t &m) { return m.getSmallNameAsSEL(); });
            } else {
                return findMethodInUnsortedMethodList(key, list, [](method_t &m) { return m.getSmallNameAsSELRef(); });
            }
        case method_t::Kind::big:
            return findMethodInUnsortedMethodList(key, list, [](method_t &m) { return m.big().name; });
        case method_t::Kind::bigSigned:
            return findMethodInUnsortedMethodList(key, list, [](method_t &m) { return m.bigSigned().name; });
#if TARGET_OS_EXCLAVEKIT
        case method_t::Kind::bigStripped:
            return findMethodInUnsortedMethodList(key, list, [](method_t &m) { return m.bigStripped().name; });
#endif
    }
}

ALWAYS_INLINE static method_t *
search_method_list_inline(const method_list_t *mlist, SEL sel)
{
    int methodListIsFixedUp = mlist->isFixedUp();
    int methodListHasExpectedSize = mlist->isExpectedSize();

    if (fastpath(methodListIsFixedUp && methodListHasExpectedSize)) {
        return findMethodInSortedMethodList(sel, mlist);
    } else {
        // Linear search of unsorted method list
        if (auto *m = findMethodInUnsortedMethodList(sel, mlist))
            return m;
    }

#if DEBUG
    // sanity-check negative results
    if (mlist->isFixedUp()) {
        for (auto& meth : *mlist) {
            if (meth.name() == sel) {
                _objc_fatal("linear search worked when binary search did not");
            }
        }
    }
#endif

    return nil;
}

NEVER_INLINE static method_t *
search_method_list(const method_list_t *mlist, SEL sel)
{
    return search_method_list_inline(mlist, sel);
}


/***********************************************************************
* _getLoadMethod
**********************************************************************/
ALWAYS_INLINE static IMP
_getLoadMethod(const method_list_t *mlist)
{
    if (!mlist)
        return nil;

    if (auto meth = search_method_list_inline(mlist, @selector(load))) {
        return meth->imp(false);
    }

    return nil;
}

/***********************************************************************
* objc_class::getLoadMethod
* fixme
* Called only from add_class_to_loadable_list.
* Locking: runtimeLock must be read- or write-locked by the caller.
**********************************************************************/
NEVER_INLINE IMP
objc_class::getLoadMethod()
{
    lockdebug::assert_locked(&runtimeLock);

    ASSERT(isRealized());
    ASSERT(ISA()->isRealized());
    ASSERT(!isMetaClass());
    ASSERT(ISA()->isMetaClass());

    auto &baseMethods = ISA()->data()->ro()->baseMethods;
    if (auto *list = baseMethods.dyn_cast<method_list_t *>()) {
        return _getLoadMethod(list);
    } else if (auto *listList = baseMethods.dyn_cast<relative_list_list_t<method_list_t> *>()) {
        // A load method will always be in the last list, since it's in the
        // class itself rather than in a category, and all other lists are
        // category lists.
        return _getLoadMethod(listList->lastList());
    }

    return nullptr;
}


/***********************************************************************
* _category_getLoadMethod
* fixme
* Called only from add_category_to_loadable_list
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
NEVER_INLINE IMP
_category_getLoadMethod(Category cat)
{
    lockdebug::assert_locked(&runtimeLock);

    return _getLoadMethod(cat->classMethods);
}


/***********************************************************************
 * method_lists_contains_any
 **********************************************************************/
template<typename T>
static NEVER_INLINE bool
method_lists_contains_any(T *mlists, T *end,
                          SEL sels[], size_t selcount)
{
    while (mlists < end) {
        const method_list_t *mlist = *mlists++;
        int methodListIsFixedUp = mlist->isFixedUp();
        int methodListHasExpectedSize = mlist->entsize() == sizeof(struct method_t::big);

        if (fastpath(methodListIsFixedUp && methodListHasExpectedSize)) {
            for (size_t i = 0; i < selcount; i++) {
                if (findMethodInSortedMethodList(sels[i], mlist)) {
                    return true;
                }
            }
        } else {
            for (size_t i = 0; i < selcount; i++) {
                if (findMethodInUnsortedMethodList(sels[i], mlist)) {
                    return true;
                }
            }
        }
    }
    return false;
}

static method_t *getMethodFromRelativeList(relative_list_list_t<method_list_t> *list, SEL sel) {
    // Relative lists never have a match for selectors outside the shared
    // cache.
    if (!objc::inSharedCache((uintptr_t)sel))
        return nullptr;

    for (auto mlists = list->beginLists(),
              end = list->endLists();
         mlists != end;
         ++mlists)
    {
        // <rdar://problem/46904873> getMethodNoSuper_nolock is the hottest
        // caller of search_method_list, inlining it turns
        // getMethodNoSuper_nolock into a frame-less function and eliminates
        // any store from this codepath.
        method_t *m = search_method_list_inline(*mlists, sel);
        if (m) return m;
    }

    return nullptr;
}

template <typename MethodListPointer>
static method_t *getMethodFromListArray(MethodListPointer array, unsigned count, SEL sel) {
    for (unsigned i = 0; i < count; i++) {
        // <rdar://problem/46904873> getMethodNoSuper_nolock is the hottest
        // caller of search_method_list, inlining it turns
        // getMethodNoSuper_nolock into a frame-less function and eliminates
        // any store from this codepath.
        method_t *m = search_method_list_inline(array[i], sel);
        if (m) return m;
    }
    return nullptr;
}

/***********************************************************************
 * getMethodNoSuper_nolock
 * fixme
 * Locking: runtimeLock must be read- or write-locked by the caller
 **********************************************************************/
static method_t *
getMethodNoSuper_nolock(Class cls, SEL sel)
{
    lockdebug::assert_locked(&runtimeLock);

    ASSERT(cls->isRealized());
    // fixme nil cls?
    // fixme nil sel?

    auto alternates = cls->data()->methodAlternates();

    if (auto *relativeList = alternates.relativeList)
        return getMethodFromRelativeList(relativeList, sel);

    if (alternates.list)
        return getMethodFromListArray(&alternates.list, 1, sel);

    if (auto *array = alternates.array) {
        auto listAlternates = array->listAlternates();
        if (listAlternates.oneList)
            return getMethodFromListArray(&listAlternates.oneList, 1, sel);
        if (auto innerArray = listAlternates.array)
            return getMethodFromListArray(innerArray, listAlternates.arrayCount, sel);
        if (auto *relativeList = listAlternates.listList)
            return getMethodFromRelativeList(relativeList, sel);
    }

    return nil;
}


/***********************************************************************
* getMethod_nolock
* fixme
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static method_t *
getMethod_nolock(Class cls, SEL sel)
{
    method_t *m = nil;

    lockdebug::assert_locked(&runtimeLock);

    // fixme nil cls?
    // fixme nil sel?

    ASSERT(cls->isRealized());

    while (cls  &&  ((m = getMethodNoSuper_nolock(cls, sel))) == nil) {
        cls = cls->getSuperclass();
    }

    return m;
}


/***********************************************************************
* _class_getMethod
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
static Method _class_getMethod(Class cls, SEL sel)
{
    mutex_locker_t lock(runtimeLock);
    return _method_sign(getMethod_nolock(cls, sel));
}


/***********************************************************************
* class_getInstanceMethod.  Return the instance method for the
* specified class and selector.
**********************************************************************/
Method class_getInstanceMethod(Class cls, SEL sel)
{
    if (!cls  ||  !sel) return nil;

    // This deliberately avoids +initialize because it historically did so.

    // This implementation is a bit weird because it's the only place that
    // wants a Method instead of an IMP.

#warning fixme build and search caches

    // Search method lists, try method resolver, etc.
    lookUpImpOrForward(nil, sel, cls, LOOKUP_RESOLVER);

#warning fixme build and search caches

    return _class_getMethod(cls, sel);
}


/***********************************************************************
* resolveClassMethod
* Call +resolveClassMethod, looking for a method to be added to class cls.
* cls should be a metaclass.
* Does not check if the method already exists.
**********************************************************************/
static void resolveClassMethod(id inst, SEL sel, Class cls)
{
    lockdebug::assert_unlocked(&runtimeLock);
    ASSERT(cls->isRealized());
    ASSERT(cls->isMetaClass());

    if (!lookUpImpOrNilTryCache(inst, @selector(resolveClassMethod:), cls)) {
        // Resolver not implemented.
        return;
    }

    Class nonmeta;
    {
        mutex_locker_t lock(runtimeLock);
        nonmeta = getMaybeUnrealizedNonMetaClass(cls, inst);
        // +initialize path should have realized nonmeta already
        if (!nonmeta->isRealized()) {
            _objc_fatal("nonmeta class %s (%p) unexpectedly not realized",
                        nonmeta->nameForLogging(), nonmeta);
        }
    }
    BOOL (*msg)(Class, SEL, SEL) = (typeof(msg))objc_msgSend;
    bool resolved = msg(nonmeta, @selector(resolveClassMethod:), sel);

    // Cache the result (good or bad) so the resolver doesn't fire next time.
    // +resolveClassMethod adds to self->ISA() a.k.a. cls
    IMP imp = lookUpImpOrNilTryCache(inst, sel, cls);

    if (resolved  &&  PrintResolving) {
        if (imp) {
            _objc_inform("RESOLVE: method %c[%s %s] "
                         "dynamically resolved to %p",
                         cls->isMetaClass() ? '+' : '-',
                         cls->nameForLogging(), sel_getName(sel), imp);
        }
        else {
            // Method resolver didn't add anything?
            _objc_inform("RESOLVE: +[%s resolveClassMethod:%s] returned YES"
                         ", but no new implementation of %c[%s %s] was found",
                         cls->nameForLogging(), sel_getName(sel),
                         cls->isMetaClass() ? '+' : '-',
                         cls->nameForLogging(), sel_getName(sel));
        }
    }
}


/***********************************************************************
* resolveInstanceMethod
* Call +resolveInstanceMethod, looking for a method to be added to class cls.
* cls may be a metaclass or a non-meta class.
* Does not check if the method already exists.
**********************************************************************/
static void resolveInstanceMethod(id inst, SEL sel, Class cls)
{
    lockdebug::assert_unlocked(&runtimeLock);
    ASSERT(cls->isRealized());
    SEL resolve_sel = @selector(resolveInstanceMethod:);

    if (!lookUpImpOrNilTryCache(cls, resolve_sel, cls->ISA(/*authenticated*/true))) {
        // Resolver not implemented.
        return;
    }

    BOOL (*msg)(Class, SEL, SEL) = (typeof(msg))objc_msgSend;
    bool resolved = msg(cls, resolve_sel, sel);

    // Cache the result (good or bad) so the resolver doesn't fire next time.
    // +resolveInstanceMethod adds to self a.k.a. cls
    IMP imp = lookUpImpOrNilTryCache(inst, sel, cls);

    if (resolved  &&  PrintResolving) {
        if (imp) {
            _objc_inform("RESOLVE: method %c[%s %s] "
                         "dynamically resolved to %p",
                         cls->isMetaClass() ? '+' : '-',
                         cls->nameForLogging(), sel_getName(sel), imp);
        }
        else {
            // Method resolver didn't add anything?
            _objc_inform("RESOLVE: +[%s resolveInstanceMethod:%s] returned YES"
                         ", but no new implementation of %c[%s %s] was found",
                         cls->nameForLogging(), sel_getName(sel),
                         cls->isMetaClass() ? '+' : '-',
                         cls->nameForLogging(), sel_getName(sel));
        }
    }
}


/***********************************************************************
* resolveMethod_locked
* Call +resolveClassMethod or +resolveInstanceMethod.
*
* Called with the runtimeLock held to avoid pressure in the caller
* Tail calls into lookUpImpOrForward, also to avoid pressure in the callerb
**********************************************************************/
static NEVER_INLINE IMP
resolveMethod_locked(id inst, SEL sel, Class cls, int behavior)
{
    lockdebug::assert_locked(&runtimeLock);
    ASSERT(cls->isRealized());

    runtimeLock.unlock();

    if (! cls->isMetaClass()) {
        // try [cls resolveInstanceMethod:sel]
        resolveInstanceMethod(inst, sel, cls);
    }
    else {
        // try [nonMetaClass resolveClassMethod:sel]
        // and [cls resolveInstanceMethod:sel]
        resolveClassMethod(inst, sel, cls);
        if (!lookUpImpOrNilTryCache(inst, sel, cls)) {
            resolveInstanceMethod(inst, sel, cls);
        }
    }

    // chances are that calling the resolver have populated the cache
    // so attempt using it
    return lookUpImpOrForwardTryCache(inst, sel, cls, behavior);
}


/***********************************************************************
* log_and_fill_cache
* Log this method call. If the logger permits it, fill the method cache.
* cls is the method whose cache should be filled.
* implementer is the class that owns the implementation in question.
**********************************************************************/
static void
log_and_fill_cache(Class cls, IMP imp, SEL sel, id receiver, Class implementer)
{
#if SUPPORT_MESSAGE_LOGGING
    if (slowpath(objcMsgLogEnabled && implementer)) {
        bool cacheIt = logMessageSend(implementer->isMetaClass(),
                                      cls->nameForLogging(),
                                      implementer->nameForLogging(),
                                      sel);
        if (!cacheIt) return;
    }
#endif
    cls->cache.insert(sel, imp, receiver);
}


/***********************************************************************
* realizeAndInitializeIfNeeded_locked
* Realize the given class if not already realized, and initialize it if
* not already initialized.
* inst is an instance of cls or a subclass, or nil if none is known.
* cls is the class to initialize and realize.
* initializer is true to initialize the class, false to skip initialization.
**********************************************************************/
static Class
realizeAndInitializeIfNeeded_locked(id inst, Class cls, bool initialize)
{
    lockdebug::assert_locked(&runtimeLock);
    if (slowpath(!cls->isRealized())) {
        cls = realizeClassMaybeSwiftAndLeaveLocked(cls, runtimeLock);
        // runtimeLock may have been dropped but is now locked again
    }

    if (slowpath(initialize && !cls->isInitialized())) {
        cls = initializeAndLeaveLocked(cls, inst, runtimeLock);
        // runtimeLock may have been dropped but is now locked again

        // If sel == initialize, class_initialize will send +initialize and
        // then the messenger will send +initialize again after this
        // procedure finishes. Of course, if this is not being called
        // from the messenger then it won't happen. 2778172
    }
    return cls;
}

/***********************************************************************
* lookUpImpOrForward / lookUpImpOrForwardTryCache / lookUpImpOrNilTryCache
* The standard IMP lookup.
*
* The TryCache variant attempts a fast-path lookup in the IMP Cache.
* Most callers should use lookUpImpOrForwardTryCache with LOOKUP_INITIALIZE
*
* Without LOOKUP_INITIALIZE: tries to avoid +initialize (but sometimes fails)
* With    LOOKUP_NIL: returns nil on negative cache hits
*
* inst is an instance of cls or a subclass thereof, or nil if none is known.
*   If cls is an un-initialized metaclass then a non-nil inst is faster.
* May return _objc_msgForward_impcache. IMPs destined for external use
*   must be converted to _objc_msgForward or _objc_msgForward_stret.
*   If you don't want forwarding at all, use LOOKUP_NIL.
**********************************************************************/
ALWAYS_INLINE
static IMP _lookUpImpTryCache(id inst, SEL sel, Class cls, int behavior)
{
    lockdebug::assert_unlocked(&runtimeLock);

    if (slowpath(!cls->isInitialized())) {
        // see comment in lookUpImpOrForward
        return lookUpImpOrForward(inst, sel, cls, behavior);
    }

    IMP imp = cache_getImp(cls, sel);
    if (imp != NULL) goto done;
#if CONFIG_USE_PREOPT_CACHES
    if (fastpath(cls->cache.isConstantOptimizedCache(/* strict */true))) {
        imp = cache_getImp(cls->cache.preoptFallbackClass(), sel);
    }
#endif
    if (slowpath(imp == NULL)) {
        // dtrace probe
        OBJC_RUNTIME_CACHE_MISS(inst, sel, cls);

        return lookUpImpOrForward(inst, sel, cls, behavior);
    }

done:
    if ((behavior & LOOKUP_NIL) && imp == (IMP)_objc_msgForward_impcache) {
        return nil;
    }
    return imp;
}

IMP lookUpImpOrForwardTryCache(id inst, SEL sel, Class cls, int behavior)
{
    return _lookUpImpTryCache(inst, sel, cls, behavior);
}

IMP lookUpImpOrNilTryCache(id inst, SEL sel, Class cls, int behavior)
{
    return _lookUpImpTryCache(inst, sel, cls, behavior | LOOKUP_NIL);
}

NEVER_INLINE
IMP lookUpImpOrForward(id inst, SEL sel, Class cls, int behavior)
{
    const IMP forward_imp = (IMP)_objc_msgForward_impcache;
    IMP imp = nil;
    Class curClass;

    lockdebug::assert_unlocked(&runtimeLock);

    if (slowpath(!cls->isInitialized())) {
        // The first message sent to a class is often +new or +alloc, or +self
        // which goes through objc_opt_* or various optimized entry points.
        //
        // However, the class isn't realized/initialized yet at this point,
        // and the optimized entry points fall down through objc_msgSend,
        // which ends up here.
        //
        // We really want to avoid caching these, as it can cause IMP caches
        // to be made with a single entry forever.
        //
        // Note that this check is racy as several threads might try to
        // message a given class for the first time at the same time,
        // in which case we might cache anyway.
        behavior |= LOOKUP_NOCACHE;
    }

    // runtimeLock is held during isRealized and isInitialized checking
    // to prevent races against concurrent realization.

    // runtimeLock is held during method search to make
    // method-lookup + cache-fill atomic with respect to method addition.
    // Otherwise, a category could be added but ignored indefinitely because
    // the cache was re-filled with the old value after the cache flush on
    // behalf of the category.

    runtimeLock.lock();

    // We don't want people to be able to craft a binary blob that looks like
    // a class but really isn't one and do a CFI attack.
    //
    // To make these harder we want to make sure this is a class that was
    // either built into the binary or legitimately registered through
    // objc_duplicateClass, objc_initializeClassPair or objc_allocateClassPair.
    checkIsKnownClass(cls);

    cls = realizeAndInitializeIfNeeded_locked(inst, cls, behavior & LOOKUP_INITIALIZE);
    // runtimeLock may have been dropped but is now locked again
    lockdebug::assert_locked(&runtimeLock);
    curClass = cls;

    // The code used to lookup the class's cache again right after
    // we take the lock but for the vast majority of the cases
    // evidence shows this is a miss most of the time, hence a time loss.
    //
    // The only codepath calling into this without having performed some
    // kind of cache lookup is class_getInstanceMethod().

    for (unsigned attempts = unreasonableClassCount();;) {
        if (curClass->cache.isConstantOptimizedCache(/* strict */true)) {
#if CONFIG_USE_PREOPT_CACHES
            imp = cache_getImp(curClass, sel);
            if (imp) goto done_unlock;
            curClass = curClass->cache.preoptFallbackClass();
#endif
        } else {
            // curClass method list.
            method_t *meth = getMethodNoSuper_nolock(curClass, sel);
            if (meth) {
                imp = meth->imp(false);
                goto done;
            }

            if (slowpath((curClass = curClass->getSuperclass()) == nil)) {
                // No implementation found, and method resolver didn't help.
                // Use forwarding.
                imp = forward_imp;
                break;
            }
        }

        // Halt if there is a cycle in the superclass chain.
        if (slowpath(--attempts == 0)) {
            _objc_fatal("Memory corruption in class list.");
        }

        // Superclass cache.
        imp = cache_getImp(curClass, sel);
        if (slowpath(imp == forward_imp)) {
            // Found a forward:: entry in a superclass.
            // Stop searching, but don't cache yet; call method
            // resolver for this class first.
            break;
        }
        if (fastpath(imp)) {
            // Found the method in a superclass. Cache it in this class.
            goto done;
        }
    }

    // No implementation found. Try method resolver once.

    if (slowpath(behavior & LOOKUP_RESOLVER)) {
        behavior ^= LOOKUP_RESOLVER;
        return resolveMethod_locked(inst, sel, cls, behavior);
    }

 done:
    if (fastpath((behavior & LOOKUP_NOCACHE) == 0)) {
#if CONFIG_USE_PREOPT_CACHES
        while (cls->cache.isConstantOptimizedCache(/* strict */true)) {
            cls = cls->cache.preoptFallbackClass();
        }
#endif
        log_and_fill_cache(cls, imp, sel, inst, curClass);
    }
#if CONFIG_USE_PREOPT_CACHES
 done_unlock:
#endif
    runtimeLock.unlock();
    if (slowpath((behavior & LOOKUP_NIL) && imp == forward_imp)) {
        return nil;
    }
    return imp;
}

/***********************************************************************
* lookupMethodInClassAndLoadCache.
* Like lookUpImpOrForward, but does not search superclasses.
* Caches and returns objc_msgForward if the method is not found in the class.
**********************************************************************/
IMP lookupMethodInClassAndLoadCache(Class cls, SEL sel)
{
    IMP imp;

    // fixme this is incomplete - no resolver, +initialize -
    // but it's only used for .cxx_construct/destruct so we don't care
    ASSERT(sel == SEL_cxx_construct  ||  sel == SEL_cxx_destruct);

    // Search cache first.
    //
    // If the cache used for the lookup is preoptimized,
    // we ask for `_objc_msgForward_impcache` to be returned on cache misses,
    // so that there's no TOCTOU race between using `isConstantOptimizedCache`
    // and calling cache_getImp() when not under the runtime lock.
    //
    // For dynamic caches, a miss will return `nil`
    imp = cache_getImp(cls, sel, _objc_msgForward_impcache);

    if (slowpath(imp == nil)) {
        // Cache miss. Search method list.

        // dtrace probe
        OBJC_RUNTIME_CACHE_MISS(nil, sel, cls);

        mutex_locker_t lock(runtimeLock);

        if (auto meth = getMethodNoSuper_nolock(cls, sel)) {
            // Hit in method list. Cache it.
            imp = meth->imp(false);
        } else {
            imp = _objc_msgForward_impcache;
        }

        // Note, because we do not hold the runtime lock above
        // isConstantOptimizedCache might flip, so we need to double check
        if (!cls->cache.isConstantOptimizedCache(true /* strict */)) {
            cls->cache.insert(sel, imp, nil);
        }
    }

    return imp;
}


/***********************************************************************
* class_getProperty
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
objc_property_t class_getProperty(Class cls, const char *name)
{
    if (!cls  ||  !name) return nil;

    mutex_locker_t lock(runtimeLock);

    checkIsKnownClass(cls);

    ASSERT(cls->isRealized());

    for ( ; cls; cls = cls->getSuperclass()) {
        for (auto& prop : cls->data()->properties()) {
            if (0 == strcmp(name, prop.name)) {
                return (objc_property_t)&prop;
            }
        }
    }

    return nil;
}


/***********************************************************************
* Locking: fixme
**********************************************************************/

Class gdb_class_getClass(Class cls)
{
    const char *className = cls->mangledName();
    if(!className || !strlen(className)) return Nil;
    Class rCls = look_up_class(className, NO, NO);
    return rCls;
}

Class gdb_object_getClass(id obj)
{
    if (!obj) return nil;
    return gdb_class_getClass(obj->getIsa());
}


/***********************************************************************
* Locking: write-locks runtimeLock
**********************************************************************/
void
objc_class::setInitialized()
{
    Class metacls;
    Class cls;

    ASSERT(!isMetaClass());

    cls = (Class)this;
    metacls = cls->ISA();

    mutex_locker_t lock(runtimeLock);

    // Special cases:
    // - NSObject AWZ  class methods are default.
    // - NSObject RR   class and instance methods are default.
    // - NSObject Core class and instance methods are default.
    // adjustCustomFlagsForMethodChange() also knows these special cases.
    // attachMethodLists() also knows these special cases.

    objc::Scanner::scanInitializedClass(cls, metacls);

#if CONFIG_USE_PREOPT_CACHES
    cls->cache.maybeConvertToPreoptimized();
    metacls->cache.maybeConvertToPreoptimized();
#endif

    if (PrintInitializing) {
        _objc_inform("INITIALIZE: thread %p: setInitialized(%s)",
                     objc_thread_self(), cls->nameForLogging());
    }
    // Update the +initialize flags.
    // Do this last.
    metacls->changeInfo(RW_INITIALIZED, RW_INITIALIZING);
}


void
objc_class::printInstancesRequireRawIsa(bool inherited)
{
    ASSERT(PrintRawIsa);
    ASSERT(instancesRequireRawIsa());
    _objc_inform("RAW ISA:  %s%s%s", nameForLogging(),
                 isMetaClass() ? " (meta)" : "",
                 inherited ? " (inherited)" : "");
}

/***********************************************************************
* Mark this class and all of its subclasses as requiring raw isa pointers
**********************************************************************/
void objc_class::setInstancesRequireRawIsaRecursively(bool inherited)
{
    Class cls = (Class)this;
    lockdebug::assert_locked(&runtimeLock);

    if (instancesRequireRawIsa()) return;

    foreach_realized_class_and_subclass(cls, [=](Class c){
        if (c->instancesRequireRawIsa()) {
            return false;
        }

        c->setInstancesRequireRawIsa();

        if (PrintRawIsa) c->printInstancesRequireRawIsa(inherited || c != cls);
        return true;
    });
}

#if CONFIG_USE_PREOPT_CACHES
void objc_class::setDisallowPreoptCachesRecursively(const char *why)
{
    Class cls = (Class)this;
    lockdebug::assert_locked(&runtimeLock);

    if (!allowsPreoptCaches()) return;

    foreach_realized_class_and_subclass(cls, [=](Class c){
        if (!c->allowsPreoptCaches()) {
            return false;
        }

        if (c->cache.isConstantOptimizedCache(/* strict */true)) {
            c->cache.eraseNolock(why);
        } else {
            if (PrintCaches) {
                  _objc_inform("CACHES: %sclass %s: disallow preopt cache (from %s)",
                               isMetaClass() ? "meta" : "",
                               nameForLogging(), why);
            }
            c->setDisallowPreoptCaches();
        }
        return true;
    });
}

void objc_class::setDisallowPreoptInlinedSelsRecursively(const char *why)
{
    Class cls = (Class)this;
    lockdebug::assert_locked(&runtimeLock);

    if (!allowsPreoptInlinedSels()) return;

    foreach_realized_class_and_subclass(cls, [=](Class c){
        if (!c->allowsPreoptInlinedSels()) {
            return false;
        }

        if (PrintCaches) {
              _objc_inform("CACHES: %sclass %s: disallow sel-inlined preopt cache (from %s)",
                           isMetaClass() ? "meta" : "",
                           nameForLogging(), why);
        }

        c->setDisallowPreoptInlinedSels();
        if (c->cache.isConstantOptimizedCacheWithInlinedSels()) {
            c->cache.eraseNolock(why);
        }
        return true;
    });
}
#endif

/***********************************************************************
* Choose a class index.
* Set instancesRequireRawIsa if no more class indexes are available.
**********************************************************************/
void objc_class::chooseClassArrayIndex()
{
#if SUPPORT_INDEXED_ISA
    Class cls = (Class)this;
    lockdebug::assert_locked(&runtimeLock);

    if (objc_indexed_classes_count >= ISA_INDEX_COUNT) {
        // No more indexes available.
        ASSERT(cls->classArrayIndex() == 0);
        cls->setInstancesRequireRawIsaRecursively(false/*not inherited*/);
        return;
    }

    unsigned index = objc_indexed_classes_count++;
    if (index == 0) index = objc_indexed_classes_count++;  // index 0 is unused
    classForIndex(index) = cls;
    cls->setClassArrayIndex(index);
#endif
}

static const char *empty_lazyClassNamer(Class cls __unused) {
    return nullptr;
}

static ChainedHookFunction<objc_hook_lazyClassNamer> LazyClassNamerHook{empty_lazyClassNamer};

void objc_setHook_lazyClassNamer(_Nonnull objc_hook_lazyClassNamer newValue,
                                  _Nonnull objc_hook_lazyClassNamer * _Nonnull oldOutValue) {
    LazyClassNamerHook.set(newValue, oldOutValue);
}

const char * objc_class::installMangledNameForLazilyNamedClass() {
    auto lazyClassNamer = LazyClassNamerHook.get();
    if (!*lazyClassNamer) {
        _objc_fatal("Lazily named class %p with no lazy name handler registered", this);
    }

    // If this is called on a metaclass, extract the original class
    // and make it do the installation instead. It will install
    // the metaclass's name too.
    if (isMetaClass()) {
        Class nonMeta = bits.safe_ro()->getNonMetaclass();
        return nonMeta->installMangledNameForLazilyNamedClass();
    }

    Class cls = (Class)this;
    Class metaclass = ISA();

    const char *name = lazyClassNamer((Class)this);
    if (!name) {
        _objc_fatal("Lazily named class %p wasn't named by lazy name handler", this);
    }

    // Add the name to the name->class table before setting it on the class.
    // This ensures that another thread which roundtrips class->name->class
    // will succeed. If we set the name on the class first, there would be a
    // race where the other thread would see the class's name, but not the entry
    // in the table, so the name->class lookup would fail.
    addNamedClass_locked(cls, name);

    // Emplace the name into the class_ro_t. If we lose the race,
    // then we'll free our name and use whatever got placed there
    // instead of our name.
    const char *previously = NULL;
    class_ro_t *ro = (class_ro_t *)cls->bits.safe_ro();
    bool wonRace = ro->name.compare_exchange_strong(previously, name, std::memory_order_release, std::memory_order_acquire);
    if (!wonRace) {
        free((void *)name);
        name = previously;
    }

    // Emplace whatever name won the race in the metaclass too.
    class_ro_t *metaRO = (class_ro_t *)metaclass->bits.safe_ro();

    // Write our pointer if the current value is NULL. There's no
    // need to loop or check success, since the only way this can
    // fail is if another thread succeeded in writing the exact
    // same pointer.
    const char *expected = NULL;
    metaRO->name.compare_exchange_strong(expected, name, std::memory_order_release, std::memory_order_acquire);

    return name;
}

/***********************************************************************
* Update custom RR and AWZ when a method changes its IMP
**********************************************************************/
static void
adjustCustomFlagsForMethodChange(Class cls, method_t *meth)
{
    objc::Scanner::scanChangedMethod(cls, meth);
}


/***********************************************************************
* class_getIvarLayout
* Called by the garbage collector.
* The class must be nil or already realized.
* Locking: none
**********************************************************************/
const uint8_t *
class_getIvarLayout(Class cls)
{
    if (cls) return cls->data()->ro()->getIvarLayout();
    else return nil;
}


/***********************************************************************
* class_getWeakIvarLayout
* Called by the garbage collector.
* The class must be nil or already realized.
* Locking: none
**********************************************************************/
const uint8_t *
class_getWeakIvarLayout(Class cls)
{
    if (cls) return cls->data()->ro()->weakIvarLayout;
    else return nil;
}


/***********************************************************************
* class_setIvarLayout
* Changes the class's ivar layout.
* nil layout means no unscanned ivars
* The class must be under construction.
* fixme: sanity-check layout vs instance size?
* fixme: sanity-check layout vs superclass?
* Locking: acquires runtimeLock
**********************************************************************/
void
class_setIvarLayout(Class cls, const uint8_t *layout)
{
    if (!cls) return;

    ASSERT(!cls->isMetaClass());

    mutex_locker_t lock(runtimeLock);

    checkIsKnownClass(cls);

    // Can only change layout of in-construction classes.
    // note: if modifications to post-construction classes were
    //   allowed, there would be a race below (us vs. concurrent object_setIvar)
    if (!(cls->data()->flags & RW_CONSTRUCTING)) {
        _objc_inform("*** Can't set ivar layout for already-registered "
                     "class '%s'", cls->nameForLogging());
        return;
    }

    class_ro_t *ro_w = make_ro_writeable(cls->data());

    try_free(ro_w->getIvarLayout());
    ro_w->ivarLayout = ustrdupMaybeNil(layout);
}


/***********************************************************************
* class_setWeakIvarLayout
* Changes the class's weak ivar layout.
* nil layout means no weak ivars
* The class must be under construction.
* fixme: sanity-check layout vs instance size?
* fixme: sanity-check layout vs superclass?
* Locking: acquires runtimeLock
**********************************************************************/
void
class_setWeakIvarLayout(Class cls, const uint8_t *layout)
{
    if (!cls) return;

    mutex_locker_t lock(runtimeLock);

    checkIsKnownClass(cls);

    // Can only change layout of in-construction classes.
    // note: if modifications to post-construction classes were
    //   allowed, there would be a race below (us vs. concurrent object_setIvar)
    if (!(cls->data()->flags & RW_CONSTRUCTING)) {
        _objc_inform("*** Can't set weak ivar layout for already-registered "
                     "class '%s'", cls->nameForLogging());
        return;
    }

    class_ro_t *ro_w = make_ro_writeable(cls->data());

    try_free(ro_w->weakIvarLayout);
    ro_w->weakIvarLayout = ustrdupMaybeNil(layout);
}


/***********************************************************************
* getIvar
* Look up an ivar by name.
* Locking: runtimeLock must be read- or write-locked by the caller.
**********************************************************************/
static ivar_t *getIvar(Class cls, const char *name)
{
    lockdebug::assert_locked(&runtimeLock);

    const ivar_list_t *ivars;
    ASSERT(cls->isRealized());
    if ((ivars = cls->data()->ro()->ivars)) {
        for (auto& ivar : *ivars) {
            if (!ivar.offset) continue;  // anonymous bitfield

            // ivar.name may be nil for anonymous bitfields etc.
            if (ivar.name  &&  0 == strcmp(name, ivar.name)) {
                return &ivar;
            }
        }
    }

    return nil;
}


/***********************************************************************
* _class_getClassForIvar
* Given a class and an ivar that is in it or one of its superclasses,
* find the actual class that defined the ivar.
**********************************************************************/
Class _class_getClassForIvar(Class cls, Ivar ivar)
{
    mutex_locker_t lock(runtimeLock);

    for ( ; cls; cls = cls->getSuperclass()) {
        if (auto ivars = cls->data()->ro()->ivars) {
            if (ivars->containsIvar(ivar)) {
                return cls;
            }
        }
    }

    return nil;
}


/***********************************************************************
* _class_getVariable
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
Ivar
_class_getVariable(Class cls, const char *name)
{
    mutex_locker_t lock(runtimeLock);

    for ( ; cls; cls = cls->getSuperclass()) {
        ivar_t *ivar = getIvar(cls, name);
        if (ivar) {
            return ivar;
        }
    }

    return nil;
}


/***********************************************************************
* class_conformsToProtocol
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
BOOL class_conformsToProtocol(Class cls, Protocol *proto_gen)
{
    protocol_t *proto = newprotocol(proto_gen);

    if (!cls) return NO;
    if (!proto_gen) return NO;

    mutex_locker_t lock(runtimeLock);

    checkIsKnownClass(cls);

    ASSERT(cls->isRealized());

    for (const auto& proto_ref : cls->data()->protocols()) {
        protocol_t *p = remapProtocol(proto_ref);
        if (p == proto || protocol_conformsToProtocol_nolock(p, proto)) {
            return YES;
        }
    }

    return NO;
}

static void
addMethods_finish(Class cls, method_list_t *newlist)
{
    auto rwe = cls->data()->extAllocIfNeeded();

    if (newlist->count > 1)
        newlist->sortBySELAddress();

    prepareMethodLists(cls, &newlist, 1, NO, NO, __func__);
    rwe->methods.attachLists(&newlist, 1, /*preoptimized*/false, PrintPreopt ? "methods" : nullptr);

    // If the class being modified has a constant cache,
    // then all children classes are flattened constant caches
    // and need to be flushed as well.
    flushCaches(cls, __func__, [](Class c){
        // constant caches have been dealt with in prepareMethodLists
        // if the class still is constant here, it's fine to keep
        return !c->cache.isConstantOptimizedCache();
    });
}


/**********************************************************************
* addMethod
* fixme
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static IMP
addMethod(Class cls, SEL name, IMP imp, const char *types, bool replace)
{
    IMP result = nil;

    lockdebug::assert_locked(&runtimeLock);

    checkIsKnownClass(cls);

    ASSERT(types);
    ASSERT(cls->isRealized());

    method_t *m;
    if ((m = getMethodNoSuper_nolock(cls, name))) {
        // already exists
        if (!replace) {
            result = m->imp(false);
        } else {
            result = _method_setImplementation(cls, m, imp);
        }
    } else {
        // fixme optimize
        method_list_t *newlist = method_list_t::allocateMethodList(1, fixed_up_method_list);

#if TARGET_OS_EXCLAVEKIT
        auto &first = newlist->begin()->bigStripped();
#else
        auto &first = newlist->begin()->bigSigned();
#endif
        first.name = name;
        first.types = strdupIfMutable(types);
        first.imp = imp;

        addMethods_finish(cls, newlist);
        result = nil;
    }

    return result;
}

/**********************************************************************
* addMethods
* Add the given methods to a class in bulk.
* Returns the selectors which could not be added, when replace == NO and a
* method already exists. The returned selectors are NULL terminated and must be
* freed by the caller. They are NULL if no failures occurred.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static SEL *
addMethods(Class cls, const SEL *names, const IMP *imps, const char **types,
           uint32_t count, bool replace, uint32_t *outFailedCount)
{
    lockdebug::assert_locked(&runtimeLock);

    ASSERT(names);
    ASSERT(imps);
    ASSERT(types);
    ASSERT(cls->isRealized());

    method_list_t *newlist = method_list_t::allocateMethodList(count, fixed_up_method_list);
    newlist->count = 0;

    SEL *failedNames = nil;
    uint32_t failedCount = 0;

    for (uint32_t i = 0; i < count; i++) {
        method_t *m;
        if ((m = getMethodNoSuper_nolock(cls, names[i]))) {
            // already exists
            if (!replace) {
                // report failure
                if (failedNames == nil) {
                    // allocate an extra entry for a trailing NULL in case
                    // every method fails
                    failedNames = (SEL *)calloc(sizeof(*failedNames),
                                                count + 1);
                }
                failedNames[failedCount] = m->name();
                failedCount++;
            } else {
                _method_setImplementation(cls, m, imps[i]);
            }
        } else {
#if TARGET_OS_EXCLAVEKIT
            auto &newmethod = newlist->end()->bigStripped();
#else
            auto &newmethod = newlist->end()->bigSigned();
#endif
            newmethod.name = names[i];
            newmethod.types = strdupIfMutable(types[i]);
            newmethod.imp = imps[i];
            newlist->count++;
        }
    }

    if (newlist->count > 0) {
        // fixme resize newlist because it may have been over-allocated above.
        // Note that realloc() alone doesn't work due to ptrauth.
        addMethods_finish(cls, newlist);
    } else {
        // Attaching the method list to the class consumes it. If we don't
        // do that, we have to free the memory ourselves.
        newlist->deallocate();
    }

    if (outFailedCount) *outFailedCount = failedCount;

    return failedNames;
}


BOOL
class_addMethod(Class cls, SEL name, IMP imp, const char *types)
{
    if (!cls) return NO;

    mutex_locker_t lock(runtimeLock);
    return ! addMethod(cls, name, imp, types ?: "", NO);
}


IMP
class_replaceMethod(Class cls, SEL name, IMP imp, const char *types)
{
    if (!cls) return nil;

    mutex_locker_t lock(runtimeLock);
    return addMethod(cls, name, imp, types ?: "", YES);
}


SEL *
class_addMethodsBulk(Class cls, const SEL *names, const IMP *imps,
                     const char **types, uint32_t count,
                     uint32_t *outFailedCount)
{
    if (!cls) {
        if (outFailedCount) *outFailedCount = count;
        return (SEL *)memdup(names, count * sizeof(*names));
    }

    mutex_locker_t lock(runtimeLock);
    return addMethods(cls, names, imps, types, count, NO, outFailedCount);
}

void
class_replaceMethodsBulk(Class cls, const SEL *names, const IMP *imps,
                         const char **types, uint32_t count)
{
    if (!cls) return;

    mutex_locker_t lock(runtimeLock);
    addMethods(cls, names, imps, types, count, YES, nil);
}


/***********************************************************************
* class_addIvar
* Adds an ivar to a class.
* Locking: acquires runtimeLock
**********************************************************************/
BOOL
class_addIvar(Class cls, const char *name, size_t size,
              uint8_t alignment, const char *type)
{
    if (!cls) return NO;

    if (!type) type = "";
    if (name  &&  0 == strcmp(name, "")) name = nil;

    mutex_locker_t lock(runtimeLock);

    checkIsKnownClass(cls);
    ASSERT(cls->isRealized());

    // No class variables
    if (cls->isMetaClass()) {
        return NO;
    }

    // Can only add ivars to in-construction classes.
    if (!(cls->data()->flags & RW_CONSTRUCTING)) {
        return NO;
    }

    // Check for existing ivar with this name, unless it's anonymous.
    // Check for too-big ivar.
    // fixme check for superclass ivar too?
    if ((name  &&  getIvar(cls, name))  ||  size > UINT32_MAX) {
        return NO;
    }

    class_ro_t *ro_w = make_ro_writeable(cls->data());

    // fixme allocate less memory here

    ivar_list_t *oldlist, *newlist;
    if ((oldlist = (ivar_list_t *)cls->data()->ro()->ivars)) {
        size_t oldsize = oldlist->byteSize();
        newlist = (ivar_list_t *)calloc(oldsize + oldlist->entsize(), 1);
        memcpy(newlist, oldlist, oldsize);
        free(oldlist);
    } else {
        newlist = (ivar_list_t *)calloc(ivar_list_t::byteSize(sizeof(ivar_t), 1), 1);
        newlist->entsizeAndFlags = (uint32_t)sizeof(ivar_t);
    }

    uint32_t offset = cls->unalignedInstanceSize();
    uint32_t alignMask = (1<<alignment)-1;
    offset = (offset + alignMask) & ~alignMask;

    ivar_t& ivar = newlist->get(newlist->count++);
#if __x86_64__
    // Deliberately over-allocate the ivar offset variable.
    // Use calloc() to clear all 64 bits. See the note in struct ivar_t.
    ivar.offset = (int32_t *)(int64_t *)calloc(sizeof(int64_t), 1);
#else
    ivar.offset = (int32_t *)malloc(sizeof(int32_t));
#endif
    *ivar.offset = offset;
    ivar.name = name ? strdupIfMutable(name) : nil;
    ivar.type = strdupIfMutable(type);
    ivar.alignment_raw = alignment;
    ivar.size = (uint32_t)size;

    ro_w->ivars = newlist;
    cls->setInstanceSize((uint32_t)(offset + size));

    // Ivar layout updated in registerClass.

    return YES;
}


/***********************************************************************
* class_addProtocol
* Adds a protocol to a class.
* Locking: acquires runtimeLock
**********************************************************************/
BOOL class_addProtocol(Class cls, Protocol *protocol_gen)
{
    protocol_t *protocol = newprotocol(protocol_gen);

    if (!cls) return NO;
    if (class_conformsToProtocol(cls, protocol_gen)) return NO;

    mutex_locker_t lock(runtimeLock);
    auto rwe = cls->data()->extAllocIfNeeded();

    ASSERT(cls->isRealized());

    // fixme optimize
    protocol_list_t *protolist = (protocol_list_t *)
        malloc(sizeof(protocol_list_t) + sizeof(protocol_t *));
    protolist->count = 1;
    protolist->list[0] = (protocol_ref_t)protocol;

    rwe->protocols.attachLists(&protolist, 1, /*preoptimized*/false, PrintPreopt ? "protocols" : nullptr);

    // fixme metaclass?

    return YES;
}


/***********************************************************************
* class_addProperty
* Adds a property to a class.
* Locking: acquires runtimeLock
**********************************************************************/
static bool
_class_addProperty(Class cls, const char *name,
                   const objc_property_attribute_t *attrs, unsigned int count,
                   bool replace)
{
    if (!cls) return NO;
    if (!name) return NO;

    property_t *prop = class_getProperty(cls, name);
    if (prop  &&  !replace) {
        // already exists, refuse to replace
        return NO;
    }
    else if (prop) {
        // replace existing
        mutex_locker_t lock(runtimeLock);
        try_free(prop->attributes);
        prop->attributes = copyPropertyAttributeString(attrs, count);
        return YES;
    }
    else {
        mutex_locker_t lock(runtimeLock);
        auto rwe = cls->data()->extAllocIfNeeded();

        ASSERT(cls->isRealized());

        property_list_t *proplist = (property_list_t *)
            malloc(property_list_t::byteSize(sizeof(property_t), 1));
        proplist->count = 1;
        proplist->entsizeAndFlags = sizeof(property_t);
        proplist->begin()->name = strdupIfMutable(name);
        proplist->begin()->attributes = copyPropertyAttributeString(attrs, count);

        rwe->properties.attachLists(&proplist, 1, /*preoptimized*/false, PrintPreopt ? "properties" : nullptr);

        return YES;
    }
}

BOOL
class_addProperty(Class cls, const char *name,
                  const objc_property_attribute_t *attrs, unsigned int n)
{
    return _class_addProperty(cls, name, attrs, n, NO);
}

void
class_replaceProperty(Class cls, const char *name,
                      const objc_property_attribute_t *attrs, unsigned int n)
{
    _class_addProperty(cls, name, attrs, n, YES);
}


/***********************************************************************
* look_up_class
* Look up a class by name, and realize it.
* Locking: acquires runtimeLock
**********************************************************************/
static BOOL empty_getClass(const char *name, Class *outClass)
{
    *outClass = nil;
    return NO;
}

static ChainedHookFunction<objc_hook_getClass> GetClassHook{empty_getClass};

void objc_setHook_getClass(objc_hook_getClass newValue,
                           objc_hook_getClass *outOldValue)
{
    GetClassHook.set(newValue, outOldValue);
}

Class
look_up_class(const char *name,
              bool includeUnconnected __attribute__((unused)),
              bool includeClassHandler __attribute__((unused)))
{
    if (!name) return nil;

    Class result;
    bool unrealized;
    {
        runtimeLock.lock();
        result = getClassExceptSomeSwift(name);
        unrealized = result  &&  !result->isRealized();
        if (unrealized) {
            result = realizeClassMaybeSwiftAndUnlock(result, runtimeLock);
            // runtimeLock is now unlocked
        } else {
            runtimeLock.unlock();
        }
    }

    if (!result) {
        // Ask Swift about its un-instantiated classes.

        // We use thread-local storage to prevent infinite recursion
        // if the hook function provokes another lookup of the same name
        // (for example, if the hook calls objc_allocateClassPair)

        auto *tls = _objc_fetch_pthread_data(true);

        // Stop if this thread is already looking up this name.
        for (unsigned i = 0; i < tls->classNameLookupsUsed; i++) {
            if (0 == strcmp(name, tls->classNameLookups[i])) {
                return nil;
            }
        }

        // Save this lookup in tls.
        if (tls->classNameLookupsUsed == tls->classNameLookupsAllocated) {
            tls->classNameLookupsAllocated =
                (tls->classNameLookupsAllocated * 2 ?: 1);
            size_t size = tls->classNameLookupsAllocated *
                sizeof(tls->classNameLookups[0]);
            tls->classNameLookups = (const char **)
                realloc(tls->classNameLookups, size);
        }
        tls->classNameLookups[tls->classNameLookupsUsed++] = name;

        // Call the hook.
        Class swiftcls = nil;
        if (GetClassHook.get()(name, &swiftcls)) {
            ASSERT(swiftcls->isRealized());
            result = swiftcls;
        }

        // Erase the name from tls.
        unsigned slot = --tls->classNameLookupsUsed;
        ASSERT(slot >= 0  &&  slot < tls->classNameLookupsAllocated);
        ASSERT(name == tls->classNameLookups[slot]);
        tls->classNameLookups[slot] = nil;
    }

    return result;
}


/***********************************************************************
* objc_duplicateClass
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
Class
objc_duplicateClass(Class original, const char *name,
                    size_t extraBytes)
{
    Class duplicate;

    mutex_locker_t lock(runtimeLock);

    checkIsKnownClass(original);

    auto orig_rw  = original->data();
    auto orig_rwe = orig_rw->ext();
    auto orig_ro  = orig_rw->ro();

    ASSERT(original->isRealized());
    ASSERT(!original->isMetaClass());

    duplicate = alloc_class_for_subclass(original, extraBytes);

    duplicate->initClassIsa(original->ISA());
    duplicate->setSuperclass(original->getSuperclass());

    duplicate->cache.initializeToEmpty();

    class_rw_t *rw = objc::zalloc<class_rw_t>();
    rw->flags = (orig_rw->flags | RW_COPIED_RO | RW_REALIZING);
    rw->firstSubclass = nil;
    rw->nextSiblingClass = nil;

    duplicate->bits.copyRWFrom(original->bits);
    duplicate->setData(rw);

    auto ro = orig_ro->duplicate();
    *(char **)&ro->name = strdupIfMutable(name);
    rw->set_ro(ro);

    if (orig_rwe) {
        auto rwe = rw->extAllocIfNeeded();
        rwe->version = orig_rwe->version;
        orig_rwe->methods.duplicateInto(rwe->methods);

        // fixme dies when categories are added to the base
        rwe->properties = orig_rwe->properties;
        rwe->protocols = orig_rwe->protocols;
    } else if (ro->baseMethods) {
        // if we have base methods, we need to make a deep copy
        // which requires a class_rw_ext_t to be allocated
        rw->deepCopy(ro);
    }

    duplicate->chooseClassArrayIndex();

    if (duplicate->getSuperclass()) {
        addSubclass(duplicate->getSuperclass(), duplicate);
        // duplicate->isa == original->isa so don't addSubclass() for it
    } else {
        addRootClass(duplicate);
    }

    // Don't methodize class - construction above is correct

    addNamedClass(duplicate, ro->getName());
    addClassTableEntry(duplicate, /*addMeta=*/false);

    if (PrintConnecting) {
        _objc_inform("CLASS: realizing class '%s' (duplicate of %s) %p %p",
                     name, original->nameForLogging(), (void*)duplicate, ro);
    }

    duplicate->clearInfo(RW_REALIZING);

    return duplicate;
}

/***********************************************************************
* objc_initializeClassPair
* Locking: runtimeLock must be write-locked by the caller
**********************************************************************/

// &UnsetLayout is the default ivar layout during class construction
static const uint8_t UnsetLayout = 0;

static void objc_initializeClassPair_internal(Class superclass, const char *name, Class cls, Class meta)
{
    lockdebug::assert_locked(&runtimeLock);

    class_ro_t *cls_ro_w, *meta_ro_w;
    class_rw_t *cls_rw_w, *meta_rw_w;

    cls_rw_w   = objc::zalloc<class_rw_t>();
    meta_rw_w  = objc::zalloc<class_rw_t>();
    cls_ro_w   = (class_ro_t *)calloc(sizeof(class_ro_t), 1);
    meta_ro_w  = (class_ro_t *)calloc(sizeof(class_ro_t), 1);

    // Set basic info
    cls_rw_w->flags = RW_CONSTRUCTING | RW_COPIED_RO | RW_REALIZED | RW_REALIZING;
    meta_rw_w->flags = RW_CONSTRUCTING | RW_COPIED_RO | RW_REALIZED | RW_REALIZING | RW_META;

    cls_ro_w->flags = 0;
    meta_ro_w->flags = RO_META;

    cls->setData(cls_rw_w);
    cls_rw_w->set_ro(cls_ro_w);
    meta->setData(meta_rw_w);
    meta_rw_w->set_ro(meta_ro_w);

    if (superclass) {
        uint32_t flagsToCopy = RW_FORBIDS_ASSOCIATED_OBJECTS;
        cls_rw_w->flags |= superclass->data()->flags & flagsToCopy;
        cls_ro_w->instanceStart = superclass->unalignedInstanceSize();
        meta_ro_w->instanceStart = superclass->ISA()->unalignedInstanceSize();
        cls->setInstanceSize(cls_ro_w->instanceStart);
        meta->setInstanceSize(meta_ro_w->instanceStart);

        // Mark this class as Swift-enhanced.
        if (superclass->isSwiftStable()) {
            cls->bits.setIsSwiftStable();
            meta->bits.setIsSwiftStable();
        }
        if (superclass->isSwiftLegacy()) {
            cls->bits.setIsSwiftLegacy();
            meta->bits.setIsSwiftLegacy();
        }
    } else {
        cls_ro_w->flags |= RO_ROOT;
        meta_ro_w->flags |= RO_ROOT;
        cls_ro_w->instanceStart = 0;
        meta_ro_w->instanceStart = (uint32_t)sizeof(objc_class);
        cls->setInstanceSize((uint32_t)sizeof(id));  // just an isa
        meta->setInstanceSize(meta_ro_w->instanceStart);
    }

    const char *dupedIfMutableName = strdupIfMutable(name);
    cls_ro_w->name.store(dupedIfMutableName, std::memory_order_release);
    meta_ro_w->name.store(dupedIfMutableName, std::memory_order_release);

    cls_ro_w->ivarLayout = &UnsetLayout;
    cls_ro_w->weakIvarLayout = &UnsetLayout;

    // This absolutely needs to be done before chooseClassArrayIndex and
    // addSubclass as initializeToEmpty() clobbers the FAST_CACHE bits
    cls->cache.initializeToEmpty();
    meta->cache.initializeToEmpty();

    meta->chooseClassArrayIndex();
    cls->chooseClassArrayIndex();

#if FAST_CACHE_META
    meta->cache.setBit(FAST_CACHE_META);
#endif
    meta->setInstancesRequireRawIsa();

    // Connect to superclasses and metaclasses
    cls->initClassIsa(meta);

    if (superclass) {
        meta->initClassIsa(superclass->ISA()->ISA());
        cls->setSuperclass(superclass);
        meta->setSuperclass(superclass->ISA());
        addSubclass(superclass, cls);
        addSubclass(superclass->ISA(), meta);
    } else {
        meta->initClassIsa(meta);
        cls->setSuperclass(Nil);
        meta->setSuperclass(cls);
        addRootClass(cls);
        addSubclass(cls, meta);
    }

    addClassTableEntry(cls);
}


/***********************************************************************
* verifySuperclass
* Sanity-check the superclass provided to
* objc_allocateClassPair, objc_initializeClassPair, or objc_readClassPair.
**********************************************************************/
bool
verifySuperclass(Class superclass, bool rootOK)
{
    if (!superclass) {
        // Superclass does not exist.
        // If subclass may be a root class, this is OK.
        // If subclass must not be a root class, this is bad.
        return rootOK;
    }

    // Superclass must be realized.
    if (! superclass->isRealized()) return false;

    // Superclass must not be under construction.
    if (superclass->data()->flags & RW_CONSTRUCTING) return false;

    return true;
}


/***********************************************************************
* objc_initializeClassPair
**********************************************************************/
Class objc_initializeClassPair(Class superclass, const char *name, Class cls, Class meta)
{
    // Fail if the class name is in use.
    if (look_up_class(name, NO, NO)) return nil;

    mutex_locker_t lock(runtimeLock);

    // Fail if the class name is in use.
    // Fail if the superclass isn't kosher.
    if (getClassExceptSomeSwift(name)  ||
        !verifySuperclass(superclass, true/*rootOK*/))
    {
        return nil;
    }

    objc_initializeClassPair_internal(superclass, name, cls, meta);

    return cls;
}


/***********************************************************************
* objc_allocateClassPair
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
Class objc_allocateClassPair(Class superclass, const char *name,
                             size_t extraBytes)
{
    Class cls, meta;

    // Fail if the class name is in use.
    if (look_up_class(name, NO, NO)) return nil;

    mutex_locker_t lock(runtimeLock);

    // Fail if the class name is in use.
    // Fail if the superclass isn't kosher.
    if (getClassExceptSomeSwift(name)  ||
        !verifySuperclass(superclass, true/*rootOK*/))
    {
        return nil;
    }

    // Allocate new classes.
    cls  = alloc_class_for_subclass(superclass, extraBytes);
    meta = alloc_class_for_subclass(superclass, extraBytes);

    // fixme mangle the name if it looks swift-y?
    objc_initializeClassPair_internal(superclass, name, cls, meta);

    return cls;
}


/***********************************************************************
* objc_registerClassPair
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
void objc_registerClassPair(Class cls)
{
    mutex_locker_t lock(runtimeLock);

    checkIsKnownClass(cls);

    if ((cls->data()->flags & RW_CONSTRUCTED)  ||
        (cls->ISA()->data()->flags & RW_CONSTRUCTED))
    {
        _objc_inform("objc_registerClassPair: class '%s' was already "
                     "registered!", cls->data()->ro()->getName());
        return;
    }

    if (!(cls->data()->flags & RW_CONSTRUCTING)  ||
        !(cls->ISA()->data()->flags & RW_CONSTRUCTING))
    {
        _objc_inform("objc_registerClassPair: class '%s' was not "
                     "allocated with objc_allocateClassPair!",
                     cls->data()->ro()->getName());
        return;
    }

    // Clear "under construction" bit, set "done constructing" bit
    cls->ISA()->changeInfo(RW_CONSTRUCTED, RW_CONSTRUCTING | RW_REALIZING);
    cls->changeInfo(RW_CONSTRUCTED, RW_CONSTRUCTING | RW_REALIZING);

    // Add to named class table.
    addNamedClass(cls, cls->data()->ro()->getName());
}


/***********************************************************************
* objc_readClassPair()
* Read a class and metaclass as written by a compiler.
* Assumes the class and metaclass are not referenced by other things
* that might need to be fixed up (such as categories and subclasses).
* Does not call +load.
* Returns the class pointer, or nil.
*
* Locking: runtimeLock acquired by map_images
**********************************************************************/
Class objc_readClassPair(Class bits, const struct objc_image_info *info)
{
    mutex_locker_t lock(runtimeLock);

    // No info bits are significant yet.
    (void)info;

    // Fail if the superclass isn't kosher.
    bool rootOK = bits->safe_ro()->flags & RO_ROOT;
    if (!verifySuperclass(bits->getSuperclass(), rootOK)){
        return nil;
    }

    // Duplicate classes are allowed, just like they are for image loading.
    // readClass will complain about the duplicate.

    Class cls = readClass(bits, false/*bundle*/, false/*shared cache*/);
    if (cls != bits) {
        // This function isn't allowed to remap anything.
        _objc_fatal("objc_readClassPair for class %s changed %p to %p",
                    cls->nameForLogging(), bits, cls);
    }

    // The only client of this function is old Swift.
    // Stable Swift won't use it.
    // fixme once Swift in the OS settles we can assert(!cls->isSwiftStable()).
    cls = realizeClassWithoutSwift(cls, nil);

    return cls;
}


/***********************************************************************
* detach_class
* Disconnect a class from other data structures.
* Exception: does not remove the class from the +load list
* Call this before free_class.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void detach_class(Class cls, bool isMeta)
{
    lockdebug::assert_locked(&runtimeLock);

    // categories not yet attached to this class
    objc::unattachedCategories.eraseClass(cls);

    // superclass's subclass list
    if (cls->isRealized()) {
        Class supercls = cls->getSuperclass();
        if (supercls) {
            removeSubclass(supercls, cls);
        } else {
            removeRootClass(cls);
        }
    }

    // class tables and +load queue
    if (!isMeta) {
        removeNamedClass(cls, cls->mangledName());
    }
    objc::allocatedClasses.get().erase(cls);
}


/***********************************************************************
* free_class
* Frees a class's data structures.
* Call this after detach_class.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void free_class(Class cls)
{
    lockdebug::assert_locked(&runtimeLock);

    if (! cls->isRealized()) return;

    auto rw = cls->data();
    auto rwe = rw->ext();
    auto ro = rw->ro();

    cls->cache.destroy();

    if (rwe) {
        for (auto& meth : rwe->methods) {
            meth.tryFreeContents_nolock();
        }
        rwe->methods.tryFree();
    }

    const ivar_list_t *ivars = ro->ivars;
    if (ivars) {
        for (auto& ivar : *ivars) {
            try_free(ivar.offset);
            try_free(ivar.name);
            try_free(ivar.type);
        }
        try_free(ivars);
    }

    if (rwe) {
        for (auto& prop : rwe->properties) {
            try_free(prop.name);
            try_free(prop.attributes);
        }
        rwe->properties.tryFree();

        rwe->protocols.tryFree();
    }

    try_free(ro->getIvarLayout());
    try_free(ro->weakIvarLayout);
    if (!cls->isMetaClass())
        try_free(ro->getName());
    try_free(ro);
    objc::zfree(rwe);
    objc::zfree(rw);
    try_free(cls);
}


void objc_disposeClassPair(Class cls)
{
    mutex_locker_t lock(runtimeLock);

    checkIsKnownClass(cls);

    if (!(cls->data()->flags & (RW_CONSTRUCTED|RW_CONSTRUCTING))  ||
        !(cls->ISA()->data()->flags & (RW_CONSTRUCTED|RW_CONSTRUCTING)))
    {
        // class not allocated with objc_allocateClassPair
        // disposing still-unregistered class is OK!
        _objc_inform("objc_disposeClassPair: class '%s' was not "
                     "allocated with objc_allocateClassPair!",
                     cls->data()->ro()->getName());
        return;
    }

    if (cls->isMetaClass()) {
        _objc_inform("objc_disposeClassPair: class '%s' is a metaclass, "
                     "not a class!", cls->data()->ro()->getName());
        return;
    }

    // Shouldn't have any live subclasses.
    if (cls->data()->firstSubclass) {
        _objc_inform("objc_disposeClassPair: class '%s' still has subclasses, "
                     "including '%s'!", cls->data()->ro()->getName(),
                     cls->data()->firstSubclass->nameForLogging());
    }
    if (cls->ISA()->data()->firstSubclass) {
        _objc_inform("objc_disposeClassPair: class '%s' still has subclasses, "
                     "including '%s'!", cls->data()->ro()->getName(),
                     cls->ISA()->data()->firstSubclass->nameForLogging());
    }

    // don't remove_class_from_loadable_list()
    // - it's not there and we don't have the lock
    detach_class(cls->ISA(), YES);
    detach_class(cls, NO);
    free_class(cls->ISA());
    free_class(cls);
}


/***********************************************************************
* objc_constructInstance
* Creates an instance of `cls` at the location pointed to by `bytes`.
* `bytes` must point to at least class_getInstanceSize(cls) bytes of
*   well-aligned zero-filled memory.
* The new object's isa is set. Any C++ constructors are called.
* Returns `bytes` if successful. Returns nil if `cls` or `bytes` is
*   nil, or if C++ constructors fail.
* Note: class_createInstance() and class_createInstances() preflight this.
**********************************************************************/
id
objc_constructInstance(Class cls, void *bytes)
{
    if (!cls  ||  !bytes) return nil;

    id obj = (id)bytes;

    // Read class's info bits all at once for performance
    bool hasCxxCtor = cls->hasCxxCtor();
    bool hasCxxDtor = cls->hasCxxDtor();
    bool fast = cls->canAllocNonpointer();

    if (fast) {
        obj->initInstanceIsa(cls, hasCxxDtor);
    } else {
        obj->initIsa(cls);
    }

    if (hasCxxCtor) {
        return object_cxxConstructFromClass(obj, cls, OBJECT_CONSTRUCT_NONE);
    } else {
        return obj;
    }
}


/***********************************************************************
* class_createInstance
* fixme
* Locking: none
*
* Note: this function has been carefully written so that the fastpath
* takes no branch.
**********************************************************************/
static ALWAYS_INLINE id
_class_createInstance(Class cls, size_t extraBytes,
                      int construct_flags = OBJECT_CONSTRUCT_NONE,
                      bool cxxConstruct = true,
                      size_t *outAllocatedSize = nil)
{
    ASSERT(cls->isRealized());

    // Read class's info bits all at once for performance
    bool hasCxxCtor = cxxConstruct && cls->hasCxxCtor();
    bool hasCxxDtor = cls->hasCxxDtor();
    bool fast = cls->canAllocNonpointer();
    size_t size;

    size = cls->instanceSize(extraBytes);
    if (outAllocatedSize) *outAllocatedSize = size;

    id obj = objc::malloc_instance(size, cls);
    if (slowpath(!obj)) {
        if (construct_flags & OBJECT_CONSTRUCT_CALL_BADALLOC) {
            return _objc_callBadAllocHandler(cls);
        }
        return nil;
    }

    if (fast) {
        obj->initInstanceIsa(cls, hasCxxDtor);
    } else {
        // Use raw pointer isa on the assumption that they might be
        // doing something weird with the zone or RR.
        obj->initIsa(cls);
    }

    if (fastpath(!hasCxxCtor)) {
        return obj;
    }

    construct_flags |= OBJECT_CONSTRUCT_FREE_ONFAILURE;
    return object_cxxConstructFromClass(obj, cls, construct_flags);
}

id
class_createInstance(Class cls, size_t extraBytes)
{
    if (!cls) return nil;
    return _class_createInstance(cls, extraBytes);
}

NEVER_INLINE
id
_objc_rootAllocWithZone(Class cls, objc_zone_t)
{
    // allocWithZone under __OBJC2__ ignores the zone parameter
    return _class_createInstance(cls, 0, OBJECT_CONSTRUCT_CALL_BADALLOC);
}

/***********************************************************************
* class_createInstances
* fixme
* Locking: none
**********************************************************************/
#if SUPPORT_NONPOINTER_ISA
#warning fixme optimize class_createInstances
#endif
unsigned
class_createInstances(Class cls, size_t extraBytes,
                      id *results, unsigned num_requested)
{
    return _class_createInstances(cls, extraBytes, results, num_requested);
}

/***********************************************************************
* object_copyFromZone
* fixme
* Locking: none
**********************************************************************/
id
object_copy(id oldObj, size_t extraBytes)
{
    if (_objc_isTaggedPointerOrNil(oldObj)) return oldObj;

    // fixme this doesn't handle C++ ivars correctly (#4619414)

    Class cls = oldObj->ISA(/*authenticated*/true);
    size_t size;
    id obj = _class_createInstance(cls, extraBytes, OBJECT_CONSTRUCT_NONE,
                                   false, &size);
    if (!obj) return nil;

    // Copy everything except the isa, which was already set above.
    uint8_t *copyDst = (uint8_t *)obj + sizeof(Class);
    uint8_t *copySrc = (uint8_t *)oldObj + sizeof(Class);
    size_t copySize = size - sizeof(Class);
    memmove(copyDst, copySrc, copySize);

    fixupCopiedIvars(obj, oldObj);

    return obj;
}


#if SUPPORT_ZONES

/***********************************************************************
* class_createInstanceFromZone
* fixme
* Locking: none
**********************************************************************/
id
class_createInstanceFromZone(Class cls, size_t extraBytes, void *)
{
    if (!cls) return nil;
    return _class_createInstance(cls, extraBytes);
}

/***********************************************************************
* object_copyFromZone
* fixme
* Locking: none
**********************************************************************/
id
object_copyFromZone(id oldObj, size_t extraBytes, void *)
{
    return object_copy(oldObj, extraBytes);
}

#endif


/***********************************************************************
* objc_destructInstance
* Destroys an instance without freeing memory.
* Calls C++ destructors.
* Calls ARC ivar cleanup.
* Removes associative references.
* Returns `obj`. Does nothing if `obj` is nil.
**********************************************************************/
void *objc_destructInstance(id obj)
{
    if (obj) {
        // Read all of the flags at once for performance.
        bool cxx = obj->hasCxxDtor();
        bool assoc = obj->hasAssociatedObjects();

        // This order is important.
        if (cxx) object_cxxDestruct(obj);
        if (assoc) _object_remove_associations(obj, /*deallocating*/true);
        obj->clearDeallocating();
    }

    return obj;
}


/***********************************************************************
* object_dispose
* fixme
* Locking: none
**********************************************************************/
id
object_dispose(id obj)
{
    if (!obj) return nil;

    objc_destructInstance(obj);
    free(obj);

    return nil;
}


/***********************************************************************
* _objc_getFreedObjectClass
* fixme
* Locking: none
**********************************************************************/
Class _objc_getFreedObjectClass (void)
{
    return nil;
}



/***********************************************************************
* Tagged pointer objects.
*
* Tagged pointer objects store the class and the object value in the
* object pointer; the "pointer" does not actually point to anything.
*
* Tagged pointer objects currently use this representation:
* (LSB)
*  1 bit   set if tagged, clear if ordinary object pointer
*  3 bits  tag index
* 60 bits  payload
* (MSB)
* The tag index defines the object's class.
* The payload format is defined by the object's class.
*
* If the tag index is 0b111, the tagged pointer object uses an
* "extended" representation, allowing more classes but with smaller payloads:
* (LSB)
*  1 bit   set if tagged, clear if ordinary object pointer
*  3 bits  0b111
*  8 bits  extended tag index
* 52 bits  payload
* (MSB)
*
* Some architectures reverse the MSB and LSB in these representations.
*
* This representation is subject to change. Representation-agnostic SPI is:
* objc-internal.h for class implementers.
* objc-gdb.h for debuggers.
**********************************************************************/
#if !SUPPORT_TAGGED_POINTERS

// These variables are always provided for debuggers.
uintptr_t objc_debug_taggedpointer_obfuscator = 0;
uintptr_t objc_debug_taggedpointer_mask = 0;
unsigned  objc_debug_taggedpointer_slot_shift = 0;
uintptr_t objc_debug_taggedpointer_slot_mask = 0;
unsigned  objc_debug_taggedpointer_payload_lshift = 0;
unsigned  objc_debug_taggedpointer_payload_rshift = 0;
Class objc_debug_taggedpointer_classes[1] = { nil };

uintptr_t objc_debug_taggedpointer_ext_mask = 0;
unsigned  objc_debug_taggedpointer_ext_slot_shift = 0;
uintptr_t objc_debug_taggedpointer_ext_slot_mask = 0;
unsigned  objc_debug_taggedpointer_ext_payload_lshift = 0;
unsigned  objc_debug_taggedpointer_ext_payload_rshift = 0;
Class objc_debug_taggedpointer_ext_classes[1] = { nil };

uintptr_t objc_debug_constant_cfstring_tag_bits = 0;

static void
disableTaggedPointers() { }

static void
initializeTaggedPointerObfuscator(void) { }

#else

// The "slot" used in the class table and given to the debugger
// includes the is-tagged bit. This makes objc_msgSend faster.
// The "ext" representation doesn't do that.

uintptr_t objc_debug_taggedpointer_obfuscator;
uintptr_t objc_debug_taggedpointer_mask = _OBJC_TAG_MASK;
unsigned  objc_debug_taggedpointer_slot_shift = _OBJC_TAG_SLOT_SHIFT;
uintptr_t objc_debug_taggedpointer_slot_mask = _OBJC_TAG_SLOT_MASK;
unsigned  objc_debug_taggedpointer_payload_lshift = _OBJC_TAG_PAYLOAD_LSHIFT;
unsigned  objc_debug_taggedpointer_payload_rshift = _OBJC_TAG_PAYLOAD_RSHIFT;
// objc_debug_taggedpointer_classes is defined in objc-msg-*.s

uintptr_t objc_debug_taggedpointer_ext_mask = _OBJC_TAG_EXT_MASK;
unsigned  objc_debug_taggedpointer_ext_slot_shift = _OBJC_TAG_EXT_SLOT_SHIFT;
uintptr_t objc_debug_taggedpointer_ext_slot_mask = _OBJC_TAG_EXT_SLOT_MASK;
unsigned  objc_debug_taggedpointer_ext_payload_lshift = _OBJC_TAG_EXT_PAYLOAD_LSHIFT;
unsigned  objc_debug_taggedpointer_ext_payload_rshift = _OBJC_TAG_EXT_PAYLOAD_RSHIFT;
// objc_debug_taggedpointer_ext_classes is defined in objc-msg-*.s

#if OBJC_SPLIT_TAGGED_POINTERS
uint8_t objc_debug_tag60_permutations[8] = { 0, 1, 2, 3, 4, 5, 6, 7 };
uintptr_t objc_debug_constant_cfstring_tag_bits = _OBJC_TAG_EXT_MASK | ((uintptr_t)(OBJC_TAG_Constant_CFString - OBJC_TAG_First52BitPayload) << _OBJC_TAG_EXT_SLOT_SHIFT);
#else
uintptr_t objc_debug_constant_cfstring_tag_bits = 0;
#endif

static void
disableTaggedPointers()
{
    objc_debug_taggedpointer_mask = 0;
    objc_debug_taggedpointer_slot_shift = 0;
    objc_debug_taggedpointer_slot_mask = 0;
    objc_debug_taggedpointer_payload_lshift = 0;
    objc_debug_taggedpointer_payload_rshift = 0;

    objc_debug_taggedpointer_ext_mask = 0;
    objc_debug_taggedpointer_ext_slot_shift = 0;
    objc_debug_taggedpointer_ext_slot_mask = 0;
    objc_debug_taggedpointer_ext_payload_lshift = 0;
    objc_debug_taggedpointer_ext_payload_rshift = 0;
}


// Returns a pointer to the class's storage in the tagged class arrays.
// Assumes the tag is a valid basic tag.
static ptrauth_taggedpointer_table_entry Class *
classSlotForBasicTagIndex(objc_tag_index_t tag)
{
#if OBJC_SPLIT_TAGGED_POINTERS
    uintptr_t obfuscatedTag = _objc_basicTagToObfuscatedTag(tag);
    return &objc_tag_classes[obfuscatedTag];
#else
    uintptr_t tagObfuscator = ((objc_debug_taggedpointer_obfuscator
                                >> _OBJC_TAG_INDEX_SHIFT)
                               & _OBJC_TAG_INDEX_MASK);
    uintptr_t obfuscatedTag = tag ^ tagObfuscator;

    // Array index in objc_tag_classes includes the tagged bit itself
#   if SUPPORT_MSB_TAGGED_POINTERS
    return &objc_tag_classes[0x8 | obfuscatedTag];
#   else
    return &objc_tag_classes[(obfuscatedTag << 1) | 1];
#   endif
#endif
}


// Returns a pointer to the class's storage in the tagged class arrays,
// or nil if the tag is out of range.
static ptrauth_taggedpointer_table_entry Class *
classSlotForTagIndex(objc_tag_index_t tag)
{
    if (tag >= OBJC_TAG_First60BitPayload && tag <= OBJC_TAG_Last60BitPayload) {
        return classSlotForBasicTagIndex(tag);
    }

    if (tag >= OBJC_TAG_First52BitPayload && tag <= OBJC_TAG_Last52BitPayload) {
        int index = tag - OBJC_TAG_First52BitPayload;
#if OBJC_SPLIT_TAGGED_POINTERS
        if (tag >= OBJC_TAG_FirstUnobfuscatedSplitTag)
            return &objc_tag_ext_classes[index];
#endif
        uintptr_t tagObfuscator = ((objc_debug_taggedpointer_obfuscator
                                    >> _OBJC_TAG_EXT_INDEX_SHIFT)
                                   & _OBJC_TAG_EXT_INDEX_MASK);
        return &objc_tag_ext_classes[index ^ tagObfuscator];
    }

    return nil;
}

/***********************************************************************
 * uniformRandom
 * Return a random number uniformly distributed between 0 and N.
 **********************************************************************/
static uint32_t
uniformRandom(uint32_t n)
{
#if !TARGET_OS_EXCLAVEKIT
    return arc4random_uniform(n);
#else
    // This is Lemire's nearly divisionless algorithm
    // See https://lemire.me/blog/2019/06/06/nearly-divisionless-random-integer-generation-on-various-systems/
    uint32_t x;
    arc4random_buf(&x, sizeof(x));
    uint64_t m = ((uint64_t)x) * n;
    uint32_t l = (uint32_t)m;
    if (l < n) {
        uint32_t t = -n % n;
        while (l < t) {
            arc4random_buf(&x, sizeof(x));
            m = ((uint64_t)x) * n;
            l = (uint32_t)m;
        }
    }
    return m >> 32;
#endif
}

/***********************************************************************
* initializeTaggedPointerObfuscator
* Initialize objc_debug_taggedpointer_obfuscator with randomness.
*
* The tagged pointer obfuscator is intended to make it more difficult
* for an attacker to construct a particular object as a tagged pointer,
* in the presence of a buffer overflow or other write control over some
* memory. The obfuscator is XORed with the tagged pointers when setting
* or retrieving payload values. They are filled with randomness on first
* use.
**********************************************************************/
static void
initializeTaggedPointerObfuscator(void)
{
    if (!DisableTaggedPointerObfuscation
#if !TARGET_OS_EXCLAVEKIT
        && true /*dyld_program_sdk_at_least(dyld_fall_2018_os_versions)*/
#endif
        ) {
        // Pull random data into the variable, then shift away all non-payload bits.
        arc4random_buf(&objc_debug_taggedpointer_obfuscator,
                       sizeof(objc_debug_taggedpointer_obfuscator));
        objc_debug_taggedpointer_obfuscator &= ~_OBJC_TAG_MASK;

#if OBJC_SPLIT_TAGGED_POINTERS
        // The obfuscator doesn't apply to any of the extended tag mask or the no-obfuscation bit.
        objc_debug_taggedpointer_obfuscator &= ~(_OBJC_TAG_EXT_MASK | _OBJC_TAG_NO_OBFUSCATION_MASK);

        // Shuffle the first seven entries of the tag permutator.
        int max = 7;
        for (int i = max - 1; i >= 0; i--) {
            int target = uniformRandom(i + 1);
            swap(objc_debug_tag60_permutations[i],
                 objc_debug_tag60_permutations[target]);
        }
#endif
    } else {
        // Set the obfuscator to zero for apps linked against older SDKs,
        // in case they're relying on the tagged pointer representation.
        objc_debug_taggedpointer_obfuscator = 0;
    }
}


/***********************************************************************
* _objc_registerTaggedPointerClass
* Set the class to use for the given tagged pointer index.
* Aborts if the tag is out of range, or if the tag is already
* used by some other class.
**********************************************************************/
void
_objc_registerTaggedPointerClass(objc_tag_index_t tag, Class cls)
{
    if (objc_debug_taggedpointer_mask == 0) {
        _objc_fatal("tagged pointers are disabled");
    }

    auto *slot = classSlotForTagIndex(tag);

    if (!slot) {
        _objc_fatal("tag index %u is invalid", (unsigned int)tag);
    }

    Class oldCls = *slot;

    if (cls  &&  oldCls  &&  cls != oldCls) {
        _objc_fatal("tag index %u used for two different classes "
                    "(was %p %s, now %p %s)", tag,
                    oldCls, oldCls->nameForLogging(),
                    cls, cls->nameForLogging());
    }

    *slot = cls;

    // Store a placeholder class in the basic tag slot that is
    // reserved for the extended tag space, if it isn't set already.
    // Do this lazily when the first extended tag is registered so
    // that old debuggers characterize bogus pointers correctly more often.
    if (tag < OBJC_TAG_First60BitPayload || tag > OBJC_TAG_Last60BitPayload) {
        auto *extSlot = classSlotForBasicTagIndex(OBJC_TAG_RESERVED_7);
        if (*extSlot == nil) {
            extern objc_class OBJC_CLASS_$___NSUnrecognizedTaggedPointer;
            *extSlot = (Class)&OBJC_CLASS_$___NSUnrecognizedTaggedPointer;
        }
    }
}


/***********************************************************************
* _objc_getClassForTag
* Returns the class that is using the given tagged pointer tag.
* Returns nil if no class is using that tag or the tag is out of range.
**********************************************************************/
Class
_objc_getClassForTag(objc_tag_index_t tag)
{
    auto *slot = classSlotForTagIndex(tag);
    if (slot) return *slot;
    else return nil;
}

#endif


#if SUPPORT_FIXUP

OBJC_EXTERN void objc_msgSend_fixup(void);
OBJC_EXTERN void objc_msgSendSuper2_fixup(void);
OBJC_EXTERN void objc_msgSend_stret_fixup(void);
OBJC_EXTERN void objc_msgSendSuper2_stret_fixup(void);
#if defined(__i386__)  ||  defined(__x86_64__)
OBJC_EXTERN void objc_msgSend_fpret_fixup(void);
#endif
#if defined(__x86_64__)
OBJC_EXTERN void objc_msgSend_fp2ret_fixup(void);
#endif

OBJC_EXTERN void objc_msgSend_fixedup(void);
OBJC_EXTERN void objc_msgSendSuper2_fixedup(void);
OBJC_EXTERN void objc_msgSend_stret_fixedup(void);
OBJC_EXTERN void objc_msgSendSuper2_stret_fixedup(void);
#if defined(__i386__)  ||  defined(__x86_64__)
OBJC_EXTERN void objc_msgSend_fpret_fixedup(void);
#endif
#if defined(__x86_64__)
OBJC_EXTERN void objc_msgSend_fp2ret_fixedup(void);
#endif

/***********************************************************************
* fixupMessageRef
* Repairs an old vtable dispatch call site.
* vtable dispatch itself is not supported.
**********************************************************************/
static void
fixupMessageRef(message_ref_t *msg)
{
    msg->sel = sel_registerName((const char *)msg->sel);

    if (msg->imp == &objc_msgSend_fixup) {
        if (msg->sel == @selector(alloc)) {
            msg->imp = (IMP)&objc_alloc;
        } else if (msg->sel == @selector(allocWithZone:)) {
            msg->imp = (IMP)&objc_allocWithZone;
        } else if (msg->sel == @selector(retain)) {
            msg->imp = (IMP)&objc_retain;
        } else if (msg->sel == @selector(release)) {
            msg->imp = (IMP)&objc_release;
        } else if (msg->sel == @selector(autorelease)) {
            msg->imp = (IMP)&objc_autorelease;
        } else {
            msg->imp = &objc_msgSend_fixedup;
        }
    }
    else if (msg->imp == &objc_msgSendSuper2_fixup) {
        msg->imp = &objc_msgSendSuper2_fixedup;
    }
    else if (msg->imp == &objc_msgSend_stret_fixup) {
        msg->imp = &objc_msgSend_stret_fixedup;
    }
    else if (msg->imp == &objc_msgSendSuper2_stret_fixup) {
        msg->imp = &objc_msgSendSuper2_stret_fixedup;
    }
#if defined(__i386__)  ||  defined(__x86_64__)
    else if (msg->imp == &objc_msgSend_fpret_fixup) {
        msg->imp = &objc_msgSend_fpret_fixedup;
    }
#endif
#if defined(__x86_64__)
    else if (msg->imp == &objc_msgSend_fp2ret_fixup) {
        msg->imp = &objc_msgSend_fp2ret_fixedup;
    }
#endif
}

// SUPPORT_FIXUP
#endif


// ProKit SPI
static Class setSuperclass(Class cls, Class newSuper)
{
    Class oldSuper;

    lockdebug::assert_locked(&runtimeLock);

    ASSERT(cls->isRealized());
    ASSERT(newSuper->isRealized());

    oldSuper = cls->getSuperclass();
    removeSubclass(oldSuper, cls);
    removeSubclass(oldSuper->ISA(), cls->ISA());

    cls->setSuperclass(newSuper);
    cls->ISA()->setSuperclass(newSuper->ISA(/*authenticated*/true));
    addSubclass(newSuper, cls);
    addSubclass(newSuper->ISA(), cls->ISA());

    // Flush subclass's method caches.
    flushCaches(cls, __func__, [](Class c){ return true; });
    flushCaches(cls->ISA(), __func__, [](Class c){ return true; });

    return oldSuper;
}


Class class_setSuperclass(Class cls, Class newSuper)
{
    mutex_locker_t lock(runtimeLock);
    return setSuperclass(cls, newSuper);
}

void runtime_init(void)
{
    objc::Scanner::init();
    objc::disableEnforceClassRXPtrAuth = DisableClassRXSigningEnforcement;
    objc::unattachedCategories.init(32);
    objc::allocatedClasses.init();
}
