/*
 * Copyright (c) 2009 Apple Inc.  All Rights Reserved.
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


#ifndef _OBJC_INTERNAL_H
#define _OBJC_INTERNAL_H

/* 
 * WARNING  DANGER  HAZARD  BEWARE  EEK
 * 
 * Everything in this file is for Apple Internal use only.
 * These will change in arbitrary OS updates and in unpredictable ways.
 * When your program breaks, you get to keep both pieces.
 */

/*
 * objc-internal.h: Private SPI for use by other system frameworks.
 */

#include <objc/objc.h>
#include <objc/runtime.h>
#include <Availability.h>
#include <mach-o/loader.h>

// Include NSObject.h only if we're ObjC. Module imports get unhappy
// otherwise.
#if __OBJC__
#include <objc/NSObject.h>
#endif

#if __has_include(<malloc/malloc.h>)
#   include <malloc/malloc.h>
#endif

// Termination reasons in the OS_REASON_OBJC namespace.
#define OBJC_EXIT_REASON_UNSPECIFIED 1
#define OBJC_EXIT_REASON_GC_NOT_SUPPORTED 2
#define OBJC_EXIT_REASON_CLASS_RO_SIGNING_REQUIRED 3

// This is the allocation size required for each of the class and the metaclass 
// with objc_initializeClassPair() and objc_readClassPair().
// The runtime's class structure will never grow beyond this.
#define OBJC_MAX_CLASS_SIZE (32*sizeof(void*))

// Private objc_setAssociatedObject policy modifier. When an object is
// destroyed, associated objects attached to that object that are marked with
// this will be released after all associated objects not so marked.
//
// In addition, such associations are not removed when calling
// objc_removeAssociatedObjects.
//
// NOTE: This should be used sparingly. Performance will be poor when a single
// object has more than a few (deliberately vague) associated objects marked
// with this flag. If you're not sure if you should use this, you should not use
// this!
#define _OBJC_ASSOCIATION_SYSTEM_OBJECT (1 << 16)

__BEGIN_DECLS

// This symbol is exported only from debug builds of libobjc itself.
#if defined(OBJC_IS_DEBUG_BUILD)
OBJC_EXPORT void _objc_isDebugBuild(void);
#endif

// In-place construction of an Objective-C class.
// cls and metacls must each be OBJC_MAX_CLASS_SIZE bytes.
// Returns nil if a class with the same name already exists.
// Returns nil if the superclass is under construction.
// Call objc_registerClassPair() when you are done.
OBJC_EXPORT Class _Nullable
objc_initializeClassPair(Class _Nullable superclass, const char * _Nonnull name,
                         Class _Nonnull cls, Class _Nonnull metacls) 
    OBJC_AVAILABLE(10.6, 3.0, 9.0, 1.0, 2.0);

// Class and metaclass construction from a compiler-generated memory image.
// cls and cls->isa must each be OBJC_MAX_CLASS_SIZE bytes. 
// Extra bytes not used the the metadata must be zero.
// info is the same objc_image_info that would be emitted by a static compiler.
// Returns nil if a class with the same name already exists.
// Returns nil if the superclass is nil and the class is not marked as a root.
// Returns nil if the superclass is under construction.
// Do not call objc_registerClassPair().
struct objc_image_info;
OBJC_EXPORT Class _Nullable
objc_readClassPair(Class _Nonnull cls,
                   const struct objc_image_info * _Nonnull info)
    OBJC_AVAILABLE(10.10, 8.0, 9.0, 1.0, 2.0);

// Batch object allocation using malloc_zone_batch_malloc().
OBJC_EXPORT unsigned
class_createInstances(Class _Nullable cls, size_t extraBytes, 
                      id _Nonnull * _Nonnull results, unsigned num_requested)
    OBJC_AVAILABLE(10.7, 4.3, 9.0, 1.0, 2.0)
    OBJC_ARC_UNAVAILABLE;

// Get the isa pointer written into objects just before being freed.
OBJC_EXPORT Class _Nonnull
_objc_getFreedObjectClass(void)
    OBJC_AVAILABLE(10.0, 2.0, 9.0, 1.0, 2.0);

// env NSObjCMessageLoggingEnabled
OBJC_EXPORT void
instrumentObjcMessageSends(BOOL flag)
    OBJC_AVAILABLE(10.0, 2.0, 9.0, 1.0, 2.0);

// Initializer called by libSystem
OBJC_EXPORT void
_objc_init(void)
    OBJC_AVAILABLE(10.8, 6.0, 9.0, 1.0, 2.0);

// fork() safety called by libSystem
OBJC_EXPORT void
_objc_atfork_prepare(void)
    OBJC_AVAILABLE(10.12, 10.0, 10.0, 3.0, 2.0);

OBJC_EXPORT void
_objc_atfork_parent(void)
    OBJC_AVAILABLE(10.12, 10.0, 10.0, 3.0, 2.0);

OBJC_EXPORT void
_objc_atfork_child(void)
    OBJC_AVAILABLE(10.12, 10.0, 10.0, 3.0, 2.0);

#if !OBJC_NO_GC_API

// Return YES if GC is on and `object` is a GC allocation.
OBJC_EXPORT BOOL
objc_isAuto(id _Nullable object) 
    OBJC_OSX_DEPRECATED_OTHERS_UNAVAILABLE(10.4, 10.8, "it always returns NO");

// GC debugging
OBJC_EXPORT BOOL
objc_dumpHeap(char * _Nonnull filename, unsigned long length)
    OBJC_OSX_DEPRECATED_OTHERS_UNAVAILABLE(10.4, 10.8, "it always returns NO");

// GC startup callback from Foundation
OBJC_EXPORT objc_zone_t _Nullable
objc_collect_init(int (* _Nonnull callback)(void))
    OBJC_OSX_DEPRECATED_OTHERS_UNAVAILABLE(10.4, 10.8, "it does nothing");

#endif // !OBJC_NO_GC_API

// Copies the list of currently realized classes
// intended for introspection only
// most users will want objc_copyClassList instead.
OBJC_EXPORT
Class _Nonnull * _Nullable
objc_copyRealizedClassList(unsigned int *_Nullable outCount)
	OBJC_AVAILABLE(10.15, 13.0, 13.0, 6.0, 5.0);

typedef struct objc_imp_cache_entry {
    SEL _Nonnull sel;
    IMP _Nonnull imp;
} objc_imp_cache_entry;

OBJC_EXPORT
objc_imp_cache_entry *_Nullable
class_copyImpCache(Class _Nonnull cls, int * _Nullable outCount)
	OBJC_AVAILABLE(10.15, 13.0, 13.0, 6.0, 5.0);

OBJC_EXPORT
unsigned long
sel_hash(SEL _Nullable sel)
    OBJC_AVAILABLE(10.16, 14.0, 14.0, 7.0, 6.0);

// Plainly-implemented GC barriers. Rosetta used to use these.
OBJC_EXPORT id _Nullable
objc_assign_strongCast_generic(id _Nullable value, id _Nullable * _Nonnull dest)
    UNAVAILABLE_ATTRIBUTE;

OBJC_EXPORT id _Nullable
objc_assign_global_generic(id _Nullable value, id _Nullable * _Nonnull dest)
    UNAVAILABLE_ATTRIBUTE;

OBJC_EXPORT id _Nullable
objc_assign_threadlocal_generic(id _Nullable value,
                                id _Nullable * _Nonnull dest)
    UNAVAILABLE_ATTRIBUTE;

OBJC_EXPORT id _Nullable
objc_assign_ivar_generic(id _Nullable value, id _Nonnull dest, ptrdiff_t offset)
    UNAVAILABLE_ATTRIBUTE;

#if !OBJC_NO_GC_API
// GC preflight for an app executable.
// 1: some slice requires GC
// 0: no slice requires GC
// -1: I/O or file format error
OBJC_EXPORT int
objc_appRequiresGC(int fd)
    __OSX_AVAILABLE(10.11) 
    __IOS_UNAVAILABLE __TVOS_UNAVAILABLE
    __WATCHOS_UNAVAILABLE
#ifndef __APPLE_BLEACH_SDK__
    __BRIDGEOS_UNAVAILABLE
#endif
;
#endif // !OBJC_NO_GC_API

#if !(TARGET_OS_OSX && !TARGET_OS_MACCATALYST && __i386__)
// Add a class copy fixup handler. The name is a misnomer, as
// multiple calls will install multiple handlers. Older versions
// of the Swift runtime call it by name, and it's only used by Swift
// so it's not worth deprecating this name in favor of a better one.
OBJC_EXPORT void
_objc_setClassCopyFixupHandler(void (* _Nonnull newFixupHandler)
    (Class _Nonnull oldClass, Class _Nonnull newClass))
    OBJC_AVAILABLE(10.14, 12.0, 12.0, 5.0, 3.0);
#endif

// Install handler for allocation failures. 
// Handler may abort, or throw, or provide an object to return.
OBJC_EXPORT void
_objc_setBadAllocHandler(id _Nullable (* _Nonnull newHandler)
                           (Class _Nullable isa))
    OBJC_AVAILABLE(10.8, 6.0, 9.0, 1.0, 2.0);

/**
 * Queries the Objective-C runtime for a selector matching the provided name.
 *
 * @param str A pointer to a C string. Pass the name of the method you wish to
 *  look up.
 *
 * @return A nullable pointer of type SEL specifying the selector matching the
 *  named method if any.
 */
OBJC_EXPORT SEL _Nullable
sel_lookUpByName(const char * _Nonnull name)
    OBJC_AVAILABLE(11.3, 14.5, 14.5, 7.3, 5.3);


/**
 * Returns the names of all the classes within a library.
 *
 * @param image The mach header for library or framework you are inquiring about.
 * @param outCount The number of class names returned.
 *
 * @return An array of C strings representing the class names.
 */
OBJC_EXPORT const char * _Nonnull * _Nullable
objc_copyClassNamesForImageHeader(const struct mach_header * _Nonnull mh,
                                  unsigned int * _Nullable outCount)
    OBJC_AVAILABLE(10.14, 12.0, 12.0, 5.0, 3.0);

/**
 * Returns the all the classes within a library.
 *
 * @param image The mach header for library or framework you are inquiring about.
 * @param outCount The number of class names returned.
 *
 * @return An array of Class objects
 */

OBJC_EXPORT Class _Nonnull * _Nullable
objc_copyClassesForImage(const char * _Nonnull image,
                         unsigned int * _Nullable outCount)
    OBJC_AVAILABLE(10.16, 14.0, 14.0, 7.0, 4.0);

/**
 * Attempts to acquire the runtime lock, copies the list of currently realized
 * classes into the buffer if the runtime lock can be acquired.
 *
 * @param buffer The buffer to copy into.
 * @param outCount The length of the buffer. At most this many classes are returned.
 *
 * @return The number of currently realized classes if the lock was acquired,
 *         or SIZE_MAX if the lock could not be acquired.
 */
OBJC_EXPORT size_t
_objc_getRealizedClassList_trylock(Class _Nullable * _Nullable buffer, size_t bufferLen)
    OBJC_AVAILABLE(13.0, 16.0, 16.0, 9.0, 7.0);

/**
 * Register images with the ObjC runtime. Normally this is handled automatically
 * by dyld. This call exists for code creating images in memory outside of dyld.
 *
 * @param count The number of images.
 * @param paths The image paths. (Currently unused. Use NULL for images with no
 *              corresponding file on disk.)
 * @param mhdrs The image mach headers.
 */
void
_objc_map_images(unsigned count, const char * _Nullable const paths[_Nullable],
                 const struct mach_header * _Nonnull const mhdrs[_Nullable])
    OBJC_AVAILABLE(13.0, 16.0, 16.0, 9.0, 7.0);

/**
 * Call +load methods in the given image. Normally this is handled automatically
 * by dyld. This call exists for code creating images in memory outside of dyld.
 *
 * @param paths The image path. (Currently unused. Use NULL for images with no
 *              corresponding file on disk.)
 * @param mhdrs The image mach header.
 */
void
_objc_load_image(const char * _Nullable path, const struct mach_header * _Nonnull mh)
    OBJC_AVAILABLE(13.0, 16.0, 16.0, 9.0, 7.0);

/**
 * Begin class enumeration.
 *
 * @param image The mach header for the library or framework you wish to search.
 * @param namePrefix If non-NULL, a required prefix for the class name, which
                     must remain valid for the duration of the enumeration.
 * @param conformingTo If non-NULL, a protocol to which the enumerated classes
 *                     must conform.
 * @param subclassing If non-NULL, a class which the enumerated classes must
 *                    subclass.
 * @param enumerator The enumeration data structure to initialize.
 */

typedef struct objc_class_enumerator {
    const void * _Nullable image;
    const char * _Nullable namePrefix;
#if __swift__
    void       * _Nullable conformingTo;
#else
    Protocol   * _Nullable conformingTo;
#endif
    Class        _Nullable subclassing;

    size_t      namePrefixLen;

    const Class _Nonnull * _Nullable imageClassList;
    size_t                           imageClassNdx;
    size_t                           imageClassCount;
} objc_class_enumerator_t;

OBJC_EXPORT void
_objc_beginClassEnumeration(const void * _Nullable image,
                            const char * _Nullable namePrefix,
                            Protocol * _Nullable conformingTo,
                            Class _Nullable subclassing,
                            objc_class_enumerator_t * _Nonnull enumerator)
    OBJC_AVAILABLE(13.0, 16.0, 16.0, 9.0, 7.0);

/**
 * Retrieve the next matching class from the enumerator.
 *
 * @param enumerator The enumerator.
 *
 * @return Class A matching class, or NULL to signify end of enumeration.
 */

OBJC_EXPORT Class _Nullable
_objc_enumerateNextClass(objc_class_enumerator_t * _Nonnull enumerator)
    OBJC_AVAILABLE(13.0, 16.0, 16.0, 9.0, 7.0);


/**
 * End class enumeration.
 *
 * @param enumerator The enumerator to destroy.
 */

OBJC_EXPORT void
_objc_endClassEnumeration(objc_class_enumerator_t * _Nonnull enumerator)
    OBJC_AVAILABLE(13.0, 16.0, 16.0, 9.0, 7.0);

/**
 * Mark a class as having custom dealloc initiation.
 *
 * NOTE: if you adopt this function for something other than deallocating on the
 * main thread, please let the runtime team know about it so we can be sure it
 * will work properly for your use case.
 *
 * When this is set, the default NSObject implementation of `-release` will send
 * the `_objc_initiateDealloc` message to instances of this class instead of
 * `dealloc` when the refcount drops to zero. This gives the class the
 * opportunity to customize how `dealloc` is invoked, for example by invoking it
 * on the main thread instead of synchronously in the release call.
 *
 * A default implementation of `_objc_initiateDealloc` is not provided. Classes
 * must implement their own.
 *
 * The implementation of `_objc_initiateDealloc` is expected to eventually call
 * `[self dealloc]`. Note that once `_objc_initiateDealloc` is sent, the object
 * is in a deallocating state. This means:
 *
 * 1. Retaining the object will NOT extend its lifetime.
 * 2. Releasing the object will NOT cause another call to `dealloc` or
 *    `_objc_initiateDealloc`.
 * 3. Existing weak references to the object will produce `nil` when read.
 * 4. Forming new weak references to the object is an error.
 *
 * Because the implementation of `_objc_initiateDealloc` will call
 * `[self dealloc]`, it necessarily runs before any subclass overrides of
 * `dealloc`. Overrides of `dealloc` often rely on the superclass state still
 * being intact and usable, so ensure that `_objc_initiateDealloc` does not free
 * resources that a subclass might still try to access. Most or all of your
 * object teardown work should continue to be in `dealloc` to preserve the
 * expected sequence of events.
 *
 * This call primarily exists to support classes which need to deallocate on the
 * main thread. This can be accomplished by setting the class to use custom
 * dealloc initiation, and then implementing `_objc_initiateDealloc` to call
 * dealloc on the main thread. For example:
 *
 * ```
 * _class_setCustomDeallocInitiation([MyClass class]);
 *
 * - (void)_objc_initiateDealloc {
 *     if (pthread_main_np())
 *         [self dealloc];
 *     else
 *         dispatch_async_f(dispatch_get_main_queue(), self,
 *             _objc_deallocOnMainThreadHelper);
 * }
 * ```
 *
 * (We use `dispatch_async_f` to avoid an unsafe capture of `self` in a block,
 * which could result in the object being released by Dispatch after being
 * freed.)
 *
 * @param cls The class to modify.
 */
OBJC_EXPORT void
_class_setCustomDeallocInitiation(_Nonnull Class cls);
#define OBJC_SETCUSTOMDEALLOCINITIATION_DEFINED 1

// Tagged pointer objects.

#if __LP64__
#define OBJC_HAVE_TAGGED_POINTERS 1
#endif

#if OBJC_HAVE_TAGGED_POINTERS

// Tagged pointer layout and usage is subject to change on different OS versions.

// Tag indexes 0..<7 have a 60-bit payload.
// Tag index 7 is reserved.
// Tag indexes 8..<264 have a 52-bit payload.
// Tag index 264 is reserved.

#if __has_feature(objc_fixed_enum)  ||  __cplusplus >= 201103L
enum objc_tag_index_t : uint16_t
#else
typedef uint16_t objc_tag_index_t;
enum
#endif
{
    // 60-bit payloads
    OBJC_TAG_NSAtom            = 0, 
    OBJC_TAG_1                 = 1, 
    OBJC_TAG_NSString          = 2, 
    OBJC_TAG_NSNumber          = 3, 
    OBJC_TAG_NSIndexPath       = 4, 
    OBJC_TAG_NSManagedObjectID = 5, 
    OBJC_TAG_NSDate            = 6,

    // 60-bit reserved
    OBJC_TAG_RESERVED_7        = 7, 

    // 52-bit payloads
    OBJC_TAG_Photos_1          = 8,
    OBJC_TAG_Photos_2          = 9,
    OBJC_TAG_Photos_3          = 10,
    OBJC_TAG_Photos_4          = 11,
    OBJC_TAG_XPC_1             = 12,
    OBJC_TAG_XPC_2             = 13,
    OBJC_TAG_XPC_3             = 14,
    OBJC_TAG_XPC_4             = 15,
    OBJC_TAG_NSColor           = 16,
    OBJC_TAG_UIColor           = 17,
    OBJC_TAG_CGColor           = 18,
    OBJC_TAG_NSIndexSet        = 19,
    OBJC_TAG_NSMethodSignature = 20,
    OBJC_TAG_UTTypeRecord      = 21,
    OBJC_TAG_Foundation_1      = 22,
    OBJC_TAG_Foundation_2      = 23,
    OBJC_TAG_Foundation_3      = 24,
    OBJC_TAG_Foundation_4      = 25,
    OBJC_TAG_CGRegion          = 26,

    // When using the split tagged pointer representation
    // (OBJC_SPLIT_TAGGED_POINTERS), this is the first tag where
    // the tag and payload are unobfuscated. All tags from here to
    // OBJC_TAG_Last52BitPayload are unobfuscated. The shared cache
    // builder is able to construct these as long as the low bit is
    // not set (i.e. even-numbered tags).
    OBJC_TAG_FirstUnobfuscatedSplitTag = 136, // 128 + 8, first ext tag with high bit set

    OBJC_TAG_Constant_CFString = 136,

    OBJC_TAG_First60BitPayload = 0, 
    OBJC_TAG_Last60BitPayload  = 6, 
    OBJC_TAG_First52BitPayload = 8, 
    OBJC_TAG_Last52BitPayload  = 263,

    OBJC_TAG_RESERVED_264      = 264
};
#if __has_feature(objc_fixed_enum)  &&  !defined(__cplusplus)
typedef enum objc_tag_index_t objc_tag_index_t;
#endif


// Returns true if tagged pointers are enabled.
// The other functions below must not be called if tagged pointers are disabled.
static inline bool 
_objc_taggedPointersEnabled(void);

// Register a class for a tagged pointer tag.
// Aborts if the tag is invalid or already in use.
OBJC_EXPORT void
_objc_registerTaggedPointerClass(objc_tag_index_t tag, Class _Nonnull cls)
    OBJC_AVAILABLE(10.9, 7.0, 9.0, 1.0, 2.0);

// Returns the registered class for the given tag.
// Returns nil if the tag is valid but has no registered class.
// Aborts if the tag is invalid.
OBJC_EXPORT Class _Nullable
_objc_getClassForTag(objc_tag_index_t tag)
    OBJC_AVAILABLE(10.9, 7.0, 9.0, 1.0, 2.0);

// Create a tagged pointer object with the given tag and payload.
// Assumes the tag is valid.
// Assumes tagged pointers are enabled.
// The payload will be silently truncated to fit.
static inline void * _Nonnull
_objc_makeTaggedPointer(objc_tag_index_t tag, uintptr_t payload);

// Return true if ptr is a tagged pointer object.
// Does not check the validity of ptr's class.
static inline bool 
_objc_isTaggedPointer(const void * _Nullable ptr);

// Extract the tag value from the given tagged pointer object.
// Assumes ptr is a valid tagged pointer object.
// Does not check the validity of ptr's tag.
static inline objc_tag_index_t 
_objc_getTaggedPointerTag(const void * _Nullable ptr);

// Extract the payload from the given tagged pointer object.
// Assumes ptr is a valid tagged pointer object.
// The payload value is zero-extended.
static inline uintptr_t
_objc_getTaggedPointerValue(const void * _Nullable ptr);

// Extract the payload from the given tagged pointer object.
// Assumes ptr is a valid tagged pointer object.
// The payload value is sign-extended.
static inline intptr_t
_objc_getTaggedPointerSignedValue(const void * _Nullable ptr);

// Don't use the values below. Use the declarations above.

#if __arm64__
// ARM64 uses a new tagged pointer scheme where normal tags are in
// the low bits, extended tags are in the high bits, and half of the
// extended tag space is reserved for unobfuscated payloads.
#   define OBJC_SPLIT_TAGGED_POINTERS 1
#else
#   define OBJC_SPLIT_TAGGED_POINTERS 0
#endif

#if (TARGET_OS_OSX || TARGET_OS_MACCATALYST) && __x86_64__
    // 64-bit Mac - tag bit is LSB
#   define OBJC_MSB_TAGGED_POINTERS 0
#else
    // Everything else - tag bit is MSB
#   define OBJC_MSB_TAGGED_POINTERS 1
#endif

#define _OBJC_TAG_INDEX_MASK 0x7UL

#if OBJC_SPLIT_TAGGED_POINTERS
#define _OBJC_TAG_SLOT_COUNT 8
#define _OBJC_TAG_SLOT_MASK 0x7UL
#else
// array slot includes the tag bit itself
#define _OBJC_TAG_SLOT_COUNT 16
#define _OBJC_TAG_SLOT_MASK 0xfUL
#endif

#define _OBJC_TAG_EXT_INDEX_MASK 0xff
// array slot has no extra bits
#define _OBJC_TAG_EXT_SLOT_COUNT 256
#define _OBJC_TAG_EXT_SLOT_MASK 0xff

#if OBJC_SPLIT_TAGGED_POINTERS
#   define _OBJC_TAG_MASK (1UL<<63)
#   define _OBJC_TAG_INDEX_SHIFT 0
#   define _OBJC_TAG_SLOT_SHIFT 0
#   define _OBJC_TAG_PAYLOAD_LSHIFT 1
#   define _OBJC_TAG_PAYLOAD_RSHIFT 4
#   define _OBJC_TAG_EXT_MASK (_OBJC_TAG_MASK | 0x7UL)
#   define _OBJC_TAG_NO_OBFUSCATION_MASK ((1UL<<62) | _OBJC_TAG_EXT_MASK)
#   define _OBJC_TAG_CONSTANT_POINTER_MASK \
        ~(_OBJC_TAG_EXT_MASK | ((uintptr_t)_OBJC_TAG_EXT_SLOT_MASK << _OBJC_TAG_EXT_SLOT_SHIFT))
#   define _OBJC_TAG_EXT_INDEX_SHIFT 55
#   define _OBJC_TAG_EXT_SLOT_SHIFT 55
#   define _OBJC_TAG_EXT_PAYLOAD_LSHIFT 9
#   define _OBJC_TAG_EXT_PAYLOAD_RSHIFT 12
#elif OBJC_MSB_TAGGED_POINTERS
#   define _OBJC_TAG_MASK (1UL<<63)
#   define _OBJC_TAG_INDEX_SHIFT 60
#   define _OBJC_TAG_SLOT_SHIFT 60
#   define _OBJC_TAG_PAYLOAD_LSHIFT 4
#   define _OBJC_TAG_PAYLOAD_RSHIFT 4
#   define _OBJC_TAG_EXT_MASK (0xfUL<<60)
#   define _OBJC_TAG_EXT_INDEX_SHIFT 52
#   define _OBJC_TAG_EXT_SLOT_SHIFT 52
#   define _OBJC_TAG_EXT_PAYLOAD_LSHIFT 12
#   define _OBJC_TAG_EXT_PAYLOAD_RSHIFT 12
#else
#   define _OBJC_TAG_MASK 1UL
#   define _OBJC_TAG_INDEX_SHIFT 1
#   define _OBJC_TAG_SLOT_SHIFT 0
#   define _OBJC_TAG_PAYLOAD_LSHIFT 0
#   define _OBJC_TAG_PAYLOAD_RSHIFT 4
#   define _OBJC_TAG_EXT_MASK 0xfUL
#   define _OBJC_TAG_EXT_INDEX_SHIFT 4
#   define _OBJC_TAG_EXT_SLOT_SHIFT 4
#   define _OBJC_TAG_EXT_PAYLOAD_LSHIFT 0
#   define _OBJC_TAG_EXT_PAYLOAD_RSHIFT 12
#endif

// Map of tags to obfuscated tags.
extern uintptr_t objc_debug_taggedpointer_obfuscator;

#if OBJC_SPLIT_TAGGED_POINTERS
extern uint8_t objc_debug_tag60_permutations[8];

static inline uintptr_t _objc_basicTagToObfuscatedTag(uintptr_t tag) {
    return objc_debug_tag60_permutations[tag];
}

static inline uintptr_t _objc_obfuscatedTagToBasicTag(uintptr_t tag) {
    for (unsigned i = 0; i < 7; i++)
        if (objc_debug_tag60_permutations[i] == tag)
            return i;
    return 7;
}
#endif

static inline void * _Nonnull
_objc_encodeTaggedPointer_withObfuscator(uintptr_t ptr, uintptr_t obfuscator)
{
    uintptr_t value = (obfuscator ^ ptr);
#if OBJC_SPLIT_TAGGED_POINTERS
    if ((value & _OBJC_TAG_NO_OBFUSCATION_MASK) == _OBJC_TAG_NO_OBFUSCATION_MASK)
        return (void *)ptr;
    uintptr_t basicTag = (value >> _OBJC_TAG_INDEX_SHIFT) & _OBJC_TAG_INDEX_MASK;
    uintptr_t permutedTag = _objc_basicTagToObfuscatedTag(basicTag);
    value &= ~(_OBJC_TAG_INDEX_MASK << _OBJC_TAG_INDEX_SHIFT);
    value |= permutedTag << _OBJC_TAG_INDEX_SHIFT;
#endif
    return (void *)value;
}

static inline uintptr_t
_objc_decodeTaggedPointer_noPermute_withObfuscator(const void * _Nullable ptr,
                                                   uintptr_t obfuscator)
{
    uintptr_t value = (uintptr_t)ptr;
#if OBJC_SPLIT_TAGGED_POINTERS
    if ((value & _OBJC_TAG_NO_OBFUSCATION_MASK) == _OBJC_TAG_NO_OBFUSCATION_MASK)
        return value;
#endif
    return value ^ obfuscator;
}

static inline uintptr_t
_objc_decodeTaggedPointer_withObfuscator(const void * _Nullable ptr,
                                         uintptr_t obfuscator)
{
    uintptr_t value
      = _objc_decodeTaggedPointer_noPermute_withObfuscator(ptr, obfuscator);
#if OBJC_SPLIT_TAGGED_POINTERS
    uintptr_t basicTag = (value >> _OBJC_TAG_INDEX_SHIFT) & _OBJC_TAG_INDEX_MASK;

    value &= ~(_OBJC_TAG_INDEX_MASK << _OBJC_TAG_INDEX_SHIFT);
    value |= _objc_obfuscatedTagToBasicTag(basicTag) << _OBJC_TAG_INDEX_SHIFT;
#endif
    return value;
}

static inline void * _Nonnull
_objc_encodeTaggedPointer(uintptr_t ptr)
{
    return _objc_encodeTaggedPointer_withObfuscator(ptr, objc_debug_taggedpointer_obfuscator);
}

static inline uintptr_t
_objc_decodeTaggedPointer_noPermute(const void * _Nullable ptr)
{
    return _objc_decodeTaggedPointer_noPermute_withObfuscator(ptr, objc_debug_taggedpointer_obfuscator);
}

static inline uintptr_t
_objc_decodeTaggedPointer(const void * _Nullable ptr)
{
    return _objc_decodeTaggedPointer_withObfuscator(ptr, objc_debug_taggedpointer_obfuscator);
}

static inline bool
_objc_taggedPointersEnabled(void)
{
    extern uintptr_t objc_debug_taggedpointer_mask;
    return (objc_debug_taggedpointer_mask != 0);
}

__attribute__((no_sanitize("unsigned-shift-base")))
static inline void * _Nonnull
_objc_makeTaggedPointer_withObfuscator(objc_tag_index_t tag, uintptr_t value,
                                       uintptr_t obfuscator)
{
    // PAYLOAD_LSHIFT and PAYLOAD_RSHIFT are the payload extraction shifts.
    // They are reversed here for payload insertion.

    // ASSERT(_objc_taggedPointersEnabled());
    if (tag <= OBJC_TAG_Last60BitPayload) {
        // ASSERT(((value << _OBJC_TAG_PAYLOAD_RSHIFT) >> _OBJC_TAG_PAYLOAD_LSHIFT) == value);
        uintptr_t result =
            (_OBJC_TAG_MASK | 
             ((uintptr_t)tag << _OBJC_TAG_INDEX_SHIFT) | 
             ((value << _OBJC_TAG_PAYLOAD_RSHIFT) >> _OBJC_TAG_PAYLOAD_LSHIFT));
        return _objc_encodeTaggedPointer_withObfuscator(result, obfuscator);
    } else {
        // ASSERT(tag >= OBJC_TAG_First52BitPayload);
        // ASSERT(tag <= OBJC_TAG_Last52BitPayload);
        // ASSERT(((value << _OBJC_TAG_EXT_PAYLOAD_RSHIFT) >> _OBJC_TAG_EXT_PAYLOAD_LSHIFT) == value);
        uintptr_t result =
            (_OBJC_TAG_EXT_MASK |
             ((uintptr_t)(tag - OBJC_TAG_First52BitPayload) << _OBJC_TAG_EXT_INDEX_SHIFT) |
             ((value << _OBJC_TAG_EXT_PAYLOAD_RSHIFT) >> _OBJC_TAG_EXT_PAYLOAD_LSHIFT));
        return _objc_encodeTaggedPointer_withObfuscator(result, obfuscator);
    }
}

static inline void * _Nonnull
_objc_makeTaggedPointer(objc_tag_index_t tag, uintptr_t value)
{
    return _objc_makeTaggedPointer_withObfuscator(tag, value, objc_debug_taggedpointer_obfuscator);
}

static inline bool
_objc_isTaggedPointer(const void * _Nullable ptr)
{
    return ((uintptr_t)ptr & _OBJC_TAG_MASK) == _OBJC_TAG_MASK;
}

static inline bool
_objc_isTaggedPointerOrNil(const void * _Nullable ptr)
{
    // this function is here so that clang can turn this into
    // a comparison with NULL when this is appropriate
    // it turns out it's not able to in many cases without this
    return !ptr || ((uintptr_t)ptr & _OBJC_TAG_MASK) == _OBJC_TAG_MASK;
}

static inline objc_tag_index_t
_objc_getTaggedPointerTag_withObfuscator(const void * _Nullable ptr,
                                         uintptr_t obfuscator)
{
    // ASSERT(_objc_isTaggedPointer(ptr));
    uintptr_t value = _objc_decodeTaggedPointer_withObfuscator(ptr, obfuscator);
    uintptr_t basicTag = (value >> _OBJC_TAG_INDEX_SHIFT) & _OBJC_TAG_INDEX_MASK;
    uintptr_t extTag =   (value >> _OBJC_TAG_EXT_INDEX_SHIFT) & _OBJC_TAG_EXT_INDEX_MASK;
    if (basicTag == _OBJC_TAG_INDEX_MASK) {
        return (objc_tag_index_t)(extTag + OBJC_TAG_First52BitPayload);
    } else {
        return (objc_tag_index_t)basicTag;
    }
}

__attribute__((no_sanitize("unsigned-shift-base")))
static inline uintptr_t
_objc_getTaggedPointerValue_withObfuscator(const void * _Nullable ptr,
                                           uintptr_t obfuscator)
{
    // ASSERT(_objc_isTaggedPointer(ptr));
    uintptr_t value = _objc_decodeTaggedPointer_noPermute_withObfuscator(ptr, obfuscator);
    uintptr_t basicTag = (value >> _OBJC_TAG_INDEX_SHIFT) & _OBJC_TAG_INDEX_MASK;
    if (basicTag == _OBJC_TAG_INDEX_MASK) {
        return (value << _OBJC_TAG_EXT_PAYLOAD_LSHIFT) >> _OBJC_TAG_EXT_PAYLOAD_RSHIFT;
    } else {
        return (value << _OBJC_TAG_PAYLOAD_LSHIFT) >> _OBJC_TAG_PAYLOAD_RSHIFT;
    }
}

__attribute__((no_sanitize("unsigned-shift-base")))
static inline intptr_t
_objc_getTaggedPointerSignedValue_withObfuscator(const void * _Nullable ptr,
                                                 uintptr_t obfuscator)
{
    // ASSERT(_objc_isTaggedPointer(ptr));
    uintptr_t value = _objc_decodeTaggedPointer_noPermute_withObfuscator(ptr, obfuscator);
    uintptr_t basicTag = (value >> _OBJC_TAG_INDEX_SHIFT) & _OBJC_TAG_INDEX_MASK;
    if (basicTag == _OBJC_TAG_INDEX_MASK) {
        return ((intptr_t)value << _OBJC_TAG_EXT_PAYLOAD_LSHIFT) >> _OBJC_TAG_EXT_PAYLOAD_RSHIFT;
    } else {
        return ((intptr_t)value << _OBJC_TAG_PAYLOAD_LSHIFT) >> _OBJC_TAG_PAYLOAD_RSHIFT;
    }
}

static inline objc_tag_index_t
_objc_getTaggedPointerTag(const void * _Nullable ptr)
{
    return _objc_getTaggedPointerTag_withObfuscator(ptr, objc_debug_taggedpointer_obfuscator);
}

static inline uintptr_t
_objc_getTaggedPointerValue(const void * _Nullable ptr)
{
    return _objc_getTaggedPointerValue_withObfuscator(ptr, objc_debug_taggedpointer_obfuscator);
}

static inline intptr_t
_objc_getTaggedPointerSignedValue(const void * _Nullable ptr)
{
    return _objc_getTaggedPointerSignedValue_withObfuscator(ptr, objc_debug_taggedpointer_obfuscator);
}

#   if OBJC_SPLIT_TAGGED_POINTERS
static inline void * _Nullable
_objc_getTaggedPointerRawPointerValue(const void * _Nullable ptr) {
    return (void *)((uintptr_t)ptr & _OBJC_TAG_CONSTANT_POINTER_MASK);
}
#   endif

#else

// Just check for nil when we don't support tagged pointers.
static inline bool
_objc_isTaggedPointerOrNil(const void * _Nullable ptr)
{
    return !ptr;
}

// OBJC_HAVE_TAGGED_POINTERS
#endif

/**
 * Returns the method implementation of an object.
 *
 * @param obj An Objective-C object.
 * @param name An Objective-C selector.
 *
 * @return The IMP corresponding to the instance method implemented by
 * the class of \e obj.
 * 
 * @note Equivalent to:
 *
 * class_getMethodImplementation(object_getClass(obj), name);
 */
OBJC_EXPORT IMP _Nonnull
object_getMethodImplementation(id _Nullable obj, SEL _Nonnull name)
    OBJC_AVAILABLE(10.9, 7.0, 9.0, 1.0, 2.0);

OBJC_EXPORT IMP _Nonnull
object_getMethodImplementation_stret(id _Nullable obj, SEL _Nonnull name)
    OBJC_AVAILABLE(10.9, 7.0, 9.0, 1.0, 2.0)
    OBJC_ARM64_UNAVAILABLE;


/**
 * Adds multiple methods to a class in bulk. This amortizes overhead that can be
 * expensive when adding methods one by one with class_addMethod.
 *
 * @param cls The class to which to add the methods.
 * @param names An array of selectors for the methods to add.
 * @param imps An array of functions which implement the new methods.
 * @param types An array of strings that describe the types of each method's
 *              arguments.
 * @param count The number of items in the names, imps, and types arrays.
 * @param outFiledCount Upon return, contains the number of failed selectors in
 *                      the returned array.
 *
 * @return A NULL-terminated C array of selectors which could not be added. A
 * method cannot be added when a method of that name already exists on that
 * class. When no failures occur, the return value is \c NULL. When a non-NULL
 * value is returned, the caller must free the array with \c free().
 *
 */
OBJC_EXPORT _Nullable SEL * _Nullable
class_addMethodsBulk(_Nullable Class cls, _Nonnull const SEL * _Nonnull names,
                     _Nonnull const IMP * _Nonnull imps,
                     const char * _Nonnull * _Nonnull types, uint32_t count,
                     uint32_t * _Nullable outFailedCount)
        OBJC_AVAILABLE(10.14, 12.0, 12.0, 5.0, 3.0);

/**
 * Replaces multiple methods in a class in bulk. This amortizes overhead that
 * can be expensive when adding methods one by one with class_replaceMethod.
 *
 * @param cls The class to modify.
 * @param names An array of selectors for the methods to replace.
 * @param imps An array of functions will be the new method implementantations.
 * @param types An array of strings that describe the types of each method's
 *              arguments.
 * @param count The number of items in the names, imps, and types arrays.
 */
OBJC_EXPORT void
class_replaceMethodsBulk(_Nullable Class cls,
                         _Nonnull const SEL * _Nonnull names,
                         _Nonnull const IMP * _Nonnull imps,
                         const char * _Nonnull * _Nonnull types,
                         uint32_t count)
        OBJC_AVAILABLE(10.14, 12.0, 12.0, 5.0, 3.0);


// Instance-specific instance variable layout. This is no longer implemented.

OBJC_EXPORT void
_class_setIvarLayoutAccessor(Class _Nullable cls,
                             const uint8_t* _Nullable (* _Nonnull accessor)
                               (id _Nullable object))
    UNAVAILABLE_ATTRIBUTE;

OBJC_EXPORT const uint8_t * _Nullable
_object_getIvarLayout(Class _Nullable cls, id _Nullable object)
    UNAVAILABLE_ATTRIBUTE;


/*
  "Unknown" includes non-object ivars and non-ARC non-__weak ivars
  "Strong" includes ARC __strong ivars
  "Weak" includes ARC and new MRC __weak ivars
  "Unretained" includes ARC __unsafe_unretained and old GC+MRC __weak ivars
*/
typedef enum {
    objc_ivar_memoryUnknown,     // unknown / unknown
    objc_ivar_memoryStrong,      // direct access / objc_storeStrong
    objc_ivar_memoryWeak,        // objc_loadWeak[Retained] / objc_storeWeak
    objc_ivar_memoryUnretained   // direct access / direct access
} objc_ivar_memory_management_t;

OBJC_EXPORT objc_ivar_memory_management_t
_class_getIvarMemoryManagement(Class _Nullable cls, Ivar _Nonnull ivar)
    OBJC_AVAILABLE(10.12, 10.0, 10.0, 3.0, 2.0);

OBJC_EXPORT BOOL _class_isFutureClass(Class _Nullable cls)
    OBJC_AVAILABLE(10.9, 7.0, 9.0, 1.0, 2.0);

/// Returns true if the class is an ABI stable Swift class. (Despite
/// the name, this does NOT return true for Swift classes built with
/// Swift versions prior to 5.0.)
OBJC_EXPORT BOOL _class_isSwift(Class _Nullable cls)
    OBJC_AVAILABLE(10.16, 14.0, 14.0, 7.0, 5.0);

// API to only be called by root classes like NSObject or NSProxy

OBJC_EXPORT
id _Nonnull
_objc_rootRetain(id _Nonnull obj)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT
void
_objc_rootRelease(id _Nonnull obj)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT
bool
_objc_rootReleaseWasZero(id _Nonnull obj)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT
bool
_objc_rootTryRetain(id _Nonnull obj)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT
bool
_objc_rootIsDeallocating(id _Nonnull obj)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT
id _Nonnull
_objc_rootAutorelease(id _Nonnull obj)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT
uintptr_t
_objc_rootRetainCount(id _Nonnull obj)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT
id _Nonnull
_objc_rootInit(id _Nonnull obj)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT
id _Nullable
_objc_rootAllocWithZone(Class _Nonnull cls, objc_zone_t _Nullable zone __unused)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT
id _Nullable
_objc_rootAlloc(Class _Nonnull cls)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT
void
_objc_rootDealloc(id _Nonnull obj)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT
void
_objc_rootFinalize(id _Nonnull obj)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT
objc_zone_t _Nonnull
_objc_rootZone(id _Nonnull obj)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT
uintptr_t
_objc_rootHash(id _Nonnull obj)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT
void * _Nonnull
objc_autoreleasePoolPush(void)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT
void
objc_autoreleasePoolPop(void * _Nonnull context)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);


OBJC_EXPORT id _Nullable
objc_alloc(Class _Nullable cls)
    OBJC_AVAILABLE(10.9, 7.0, 9.0, 1.0, 2.0);

OBJC_EXPORT id _Nullable
objc_allocWithZone(Class _Nullable cls)
    OBJC_AVAILABLE(10.9, 7.0, 9.0, 1.0, 2.0);

OBJC_EXPORT id _Nullable
objc_alloc_init(Class _Nullable cls)
    OBJC_AVAILABLE(10.14.4, 12.2, 12.2, 5.2, 3.2);

OBJC_EXPORT id _Nullable
objc_opt_new(Class _Nullable cls)
	OBJC_AVAILABLE(10.15, 13.0, 13.0, 6.0, 5.0);

OBJC_EXPORT id _Nullable
objc_opt_self(id _Nullable obj)
	OBJC_AVAILABLE(10.15, 13.0, 13.0, 6.0, 5.0);

OBJC_EXPORT Class _Nullable
objc_opt_class(id _Nullable obj)
	OBJC_AVAILABLE(10.15, 13.0, 13.0, 6.0, 5.0);

OBJC_EXPORT BOOL
objc_opt_respondsToSelector(id _Nullable obj, SEL _Nullable sel)
	OBJC_AVAILABLE(10.15, 13.0, 13.0, 6.0, 5.0);

OBJC_EXPORT BOOL
objc_opt_isKindOfClass(id _Nullable obj, Class _Nullable cls)
	OBJC_AVAILABLE(10.15, 13.0, 13.0, 6.0, 5.0);


OBJC_EXPORT BOOL
objc_sync_try_enter(id _Nonnull obj)
    OBJC_AVAILABLE(10.15, 13.0, 13.0, 6.0, 5.0);

OBJC_EXPORT id _Nullable
objc_retain(id _Nullable obj)
    __asm__("_objc_retain")
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT void
objc_release(id _Nullable obj)
    __asm__("_objc_release")
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT id _Nullable
objc_autorelease(id _Nullable obj)
    __asm__("_objc_autorelease")
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

// Prepare a value at +1 for return through a +0 autoreleasing convention.
OBJC_EXPORT id _Nullable
objc_autoreleaseReturnValue(id _Nullable obj)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

// Prepare a value at +0 for return through a +0 autoreleasing convention.
OBJC_EXPORT id _Nullable
objc_retainAutoreleaseReturnValue(id _Nullable obj)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

// Accept a value returned through a +0 autoreleasing convention for use at +1.
OBJC_EXPORT id _Nullable
objc_retainAutoreleasedReturnValue(id _Nullable obj)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

// Accept a value returned through a +0 autoreleasing convention for use at +1.
OBJC_EXPORT id _Nullable
objc_claimAutoreleasedReturnValue(id _Nullable obj)
    OBJC_AVAILABLE(13.0, 16.0, 16.0, 9.0, 7.0);

// Accept a value returned through a +0 autoreleasing convention for use at +0.
OBJC_EXPORT id _Nullable
objc_unsafeClaimAutoreleasedReturnValue(id _Nullable obj)
    OBJC_AVAILABLE(10.11, 9.0, 9.0, 1.0, 2.0);

OBJC_EXPORT void
objc_storeStrong(id _Nullable * _Nonnull location, id _Nullable obj)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT id _Nullable
objc_retainAutorelease(id _Nullable obj)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

// obsolete.
OBJC_EXPORT id _Nullable
objc_retain_autorelease(id _Nullable obj)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

// Returns true if the object's retain count is 1.
#define OBJC_ISUNIQUELYREFERENCED_DEFINED 1
OBJC_EXPORT bool
objc_isUniquelyReferenced(id _Nullable obj)
    OBJC_AVAILABLE(12.3, 15.4, 15.4, 8.4, 6.4);

OBJC_EXPORT id _Nullable
objc_loadWeakRetained(id _Nullable * _Nonnull location)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT id _Nullable 
objc_initWeak(id _Nullable * _Nonnull location, id _Nullable val)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

// Like objc_storeWeak, but stores nil if the new object is deallocating 
// or the new object's class does not support weak references.
// Returns the value stored (either the new object or nil).
OBJC_EXPORT id _Nullable
objc_storeWeakOrNil(id _Nullable * _Nonnull location, id _Nullable obj)
    OBJC_AVAILABLE(10.11, 9.0, 9.0, 1.0, 2.0);

// Like objc_initWeak, but stores nil if the new object is deallocating 
// or the new object's class does not support weak references.
// Returns the value stored (either the new object or nil).
OBJC_EXPORT id _Nullable
objc_initWeakOrNil(id _Nullable * _Nonnull location, id _Nullable val) 
    OBJC_AVAILABLE(10.11, 9.0, 9.0, 1.0, 2.0);

OBJC_EXPORT void
objc_destroyWeak(id _Nullable * _Nonnull location) 
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT void 
objc_copyWeak(id _Nullable * _Nonnull to, id _Nullable * _Nonnull from)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT void 
objc_moveWeak(id _Nullable * _Nonnull to, id _Nullable * _Nonnull from) 
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);


OBJC_EXPORT void
_objc_autoreleasePoolPrint(void)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT BOOL
objc_should_deallocate(id _Nonnull object)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT void
objc_clear_deallocating(id _Nonnull object)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

 
// to make CF link for now

OBJC_EXPORT void * _Nonnull
_objc_autoreleasePoolPush(void)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

OBJC_EXPORT void
_objc_autoreleasePoolPop(void * _Nonnull context)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);


/**
 * Load a classref, which is a chunk of data containing a class
 * pointer. May perform initialization and rewrite the classref to
 * point to a new object, if needed. Returns the loaded Class.
 *
 * In particular, if the classref points to a stub class (indicated
 * by setting the bottom bit of the class pointer to 1), then this
 * will call the stub's initializer and then replace the classref
 * value with the value returned by the initializer.
 *
 * @param clsref The classref to load.
 * @return The loaded Class pointer.
 */
OBJC_EXPORT _Nullable Class
objc_loadClassref(_Nullable Class * _Nonnull clsref)
    OBJC_AVAILABLE(10.15, 13.0, 13.0, 6.0, 5.0);


// Extra @encode data for XPC, or NULL
OBJC_EXPORT const char * _Nullable
_protocol_getMethodTypeEncoding(Protocol * _Nonnull proto, SEL _Nonnull sel,
                                BOOL isRequiredMethod, BOOL isInstanceMethod)
    OBJC_AVAILABLE(10.8, 6.0, 9.0, 1.0, 2.0);


/**
 * Function type for a function that is called when an image is loaded.
 *
 * @param header The mach header for the newly loaded image.
 * @param dyldInfo The dyld info for the newly loaded image.
 */
struct _dyld_section_location_info_s;
struct mach_header;
typedef void (*objc_func_loadImage2)(const struct mach_header * _Nonnull header,
                                     struct _dyld_section_location_info_s * _Nonnull dyldInfo);

/**
 * Add a function to be called when a new image is loaded. The function is
 * called after ObjC has scanned and fixed up the image. It is called
 * BEFORE +load methods are invoked.
 *
 * When adding a new function, that function is immediately called with all
 * images that are currently loaded. It is then called as needed for images
 * that are loaded afterwards.
 *
 * Note: the function is called with ObjC's internal runtime lock held.
 * Be VERY careful with what the function does to avoid deadlocks or
 * poor performance.
 *
 * @param func The function to add.
 */
#define OBJC_ADDLOADIMAGEFUNC2_DEFINED 1
OBJC_EXPORT void objc_addLoadImageFunc2(objc_func_loadImage2 _Nonnull func)
    OBJC_AVAILABLE(14.0, 17.0, 17.0, 10.0, 8.0);

/**
 * Function type for a function that is called when a realized class
 * is about to be initialized.
 *
 * @param context The context pointer the function was registered with.
 * @param cls The class that's about to be initialized.
 */
typedef void (*_objc_func_willInitializeClass)(void * _Nullable context, Class _Nonnull cls);

/**
 * Add a function to be called when a realized class is about to be
 * initialized. The class can be queried and manipulated using runtime
 * functions. Don't message it.
 *
 * When adding a new function, that function is immediately called with all
 * realized classes that are already initialized or are in the process
 * of initialization.
 *
 * @param func The function to add.
 * @param context A context pointer that will be passed to the function when called.
 */
#define OBJC_WILLINITIALIZECLASSFUNC_DEFINED 1
OBJC_EXPORT void _objc_addWillInitializeClassFunc(_objc_func_willInitializeClass _Nonnull func, void * _Nullable context)
    OBJC_AVAILABLE(10.15, 13.0, 13.0, 6.0, 4.0);

// Replicate the conditionals in objc-config.h for packed isa, indexed isa, and preopt caches
#if __ARM_ARCH_7K__ >= 2  ||  (__arm64__ && !__LP64__) || \
    !(!__LP64__  ||  \
     (TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST && !__arm64__))
OBJC_EXPORT const uintptr_t _objc_has_weak_formation_callout;
#define OBJC_WEAK_FORMATION_CALLOUT_DEFINED 1
#else
#define OBJC_WEAK_FORMATION_CALLOUT_DEFINED 0
#endif

// Be sure to edit the equivalent define in objc-config.h as well.
// Be sure to not enable CONFIG_USE_PREOPT_CACHES if CACHE_MASK_STORAGE != CACHE_MASK_STORAGE_HIGH_16
#ifndef CONFIG_USE_PREOPT_CACHES
#if TARGET_OS_EXCLAVEKIT
#define CONFIG_USE_PREOPT_CACHES 0
#elif TARGET_OS_OSX || TARGET_OS_MACCATALYST || TARGET_OS_SIMULATOR
#define CONFIG_USE_PREOPT_CACHES 0
#elif defined(__arm64__) && __LP64__
#define CONFIG_USE_PREOPT_CACHES 1
#else
#define CONFIG_USE_PREOPT_CACHES 0
#endif
#endif


// Helper function for objc4 tests only! Do not call this yourself
// for any reason ever.
OBJC_EXPORT void _method_setImplementationRawUnsafe(Method _Nonnull m, IMP _Nonnull imp)
    OBJC_AVAILABLE(10.16, 14.0, 14.0, 7.0, 5.0);

// Helper function for objc4 tests only! Do not call this yourself
// for any reason ever.
OBJC_EXPORT void
_objc_patch_root_of_class(const struct mach_header * _Nonnull originalMH, void* _Nonnull originalClass,
                          const struct mach_header * _Nonnull replacementMH, const void* _Nonnull replacementClass);

// API to only be called by classes that provide their own reference count storage

OBJC_EXPORT void
_objc_deallocOnMainThreadHelper(void * _Nullable context)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0, 2.0);

#if __OBJC__
// Declarations for internal methods used for custom weak reference
// implementations. These declarations ensure that the compiler knows
// to exclude these methods from NS_DIRECT_MEMBERS. Do NOT implement
// these methods unless you really know what you're doing.
@interface NSObject ()
- (BOOL)_tryRetain;
- (BOOL)_isDeallocating;
@end
#endif

// On async versus sync deallocation and the _dealloc2main flag
//
// Theory:
//
// If order matters, then code must always: [self dealloc].
// If order doesn't matter, then always async should be safe.
//
// Practice:
//
// The _dealloc2main bit is set for GUI objects that may be retained by other
// threads. Once deallocation begins on the main thread, doing more async
// deallocation will at best cause extra UI latency and at worst cause
// use-after-free bugs in unretained delegate style patterns. Yes, this is
// extremely fragile. Yes, in the long run, developers should switch to weak
// references.
//
// Note is NOT safe to do any equality check against the result of
// dispatch_get_current_queue(). The main thread can and does drain more than
// one dispatch queue. That is why we call pthread_main_np().
//

typedef enum {
    _OBJC_RESURRECT_OBJECT = -1,        /* _logicBlock has called -retain, and scheduled a -release for later. */
    _OBJC_DEALLOC_OBJECT_NOW = 1,       /* call [self dealloc] immediately. */
    _OBJC_DEALLOC_OBJECT_LATER = 2      /* call [self dealloc] on the main queue. */
} _objc_object_disposition_t;

// NOTE: This macro is no longer necessary merely to ensure deallocation on the
// main thread. If that's all you're using it for, you should instead use
// `_class_setCustomDeallocInitiation` along with an implementation of
// `_objc_initiateDealloc` that invokes deallocation on the main thread.
#define _OBJC_SUPPORTED_INLINE_REFCNT_LOGIC_BLOCK(_rc_ivar, _logicBlock)        \
    -(id)retain {                                                               \
        /* this will fail to compile if _rc_ivar is an unsigned type */         \
        int _retain_count_ivar_must_not_be_unsigned[0L - (__typeof__(_rc_ivar))-1] __attribute__((unused)); \
        __typeof__(_rc_ivar) _prev = __sync_fetch_and_add(&_rc_ivar, 2);        \
        if (_prev < -2) { /* specifically allow resurrection from logical 0. */ \
            __builtin_trap(); /* BUG: retain of over-released ref */            \
        }                                                                       \
        return self;                                                            \
    }                                                                           \
    -(oneway void)release {                                                     \
        __typeof__(_rc_ivar) _prev = __sync_fetch_and_sub(&_rc_ivar, 2);        \
        if (_prev > 0) {                                                        \
            return;                                                             \
        } else if (_prev < 0) {                                                 \
            __builtin_trap(); /* BUG: over-release */                           \
        }                                                                       \
        _objc_object_disposition_t fate = _logicBlock(self);                    \
        if (fate == _OBJC_RESURRECT_OBJECT) {                                   \
            return;                                                             \
        }                                                                       \
        /* mark the object as deallocating. */                                  \
        if (!__sync_bool_compare_and_swap(&_rc_ivar, -2, 1)) {                  \
            __builtin_trap(); /* BUG: dangling ref did a retain */              \
        }                                                                       \
        if (fate == _OBJC_DEALLOC_OBJECT_NOW) {                                 \
            [self dealloc];                                                     \
        } else if (fate == _OBJC_DEALLOC_OBJECT_LATER) {                        \
            dispatch_barrier_async_f(dispatch_get_main_queue(), self,           \
                _objc_deallocOnMainThreadHelper);                               \
        } else {                                                                \
            __builtin_trap(); /* BUG: bogus fate value */                       \
        }                                                                       \
    }                                                                           \
    -(NSUInteger)retainCount {                                                  \
        return (NSUInteger)(_rc_ivar + 2) >> 1;                                 \
    }                                                                           \
    -(BOOL)_tryRetain {                                                         \
        __typeof__(_rc_ivar) _prev;                                             \
        do {                                                                    \
            _prev = _rc_ivar;                                                   \
            if (_prev & 1) {                                                    \
                return 0;                                                       \
            } else if (_prev == -2) {                                           \
                return 0;                                                       \
            } else if (_prev < -2) {                                            \
                __builtin_trap(); /* BUG: over-release elsewhere */             \
            }                                                                   \
        } while ( ! __sync_bool_compare_and_swap(&_rc_ivar, _prev, _prev + 2)); \
        return 1;                                                               \
    }                                                                           \
    -(BOOL)_isDeallocating {                                                    \
        if (_rc_ivar == -2) {                                                   \
            return 1;                                                           \
        } else if (_rc_ivar < -2) {                                             \
            __builtin_trap(); /* BUG: over-release elsewhere */                 \
        }                                                                       \
        return (_rc_ivar & 1) != 0;                                             \
    }

#define _OBJC_SUPPORTED_INLINE_REFCNT_LOGIC(_rc_ivar, _dealloc2main)            \
    _OBJC_SUPPORTED_INLINE_REFCNT_LOGIC_BLOCK(_rc_ivar, (^(id _self_ __attribute__((unused))) { \
        if ((_dealloc2main) && !pthread_main_np()) {                            \
            return _OBJC_DEALLOC_OBJECT_LATER;                                  \
        } else {                                                                \
            return _OBJC_DEALLOC_OBJECT_NOW;                                    \
        }                                                                       \
    }))

#define _OBJC_SUPPORTED_INLINE_REFCNT(_rc_ivar) _OBJC_SUPPORTED_INLINE_REFCNT_LOGIC(_rc_ivar, 0)
#define _OBJC_SUPPORTED_INLINE_REFCNT_WITH_DEALLOC2MAIN(_rc_ivar) _OBJC_SUPPORTED_INLINE_REFCNT_LOGIC(_rc_ivar, 1)


// C cache_t wrappers for objcdt and the IMP caches test tool
struct cache_t;
struct bucket_t;
struct preopt_cache_t;
OBJC_EXPORT struct bucket_t * _Nonnull objc_cache_buckets(const struct cache_t * _Nonnull cache);
OBJC_EXPORT size_t objc_cache_bytesForCapacity(uint32_t cap);
OBJC_EXPORT uint32_t objc_cache_occupied(const struct cache_t * _Nonnull cache);
OBJC_EXPORT unsigned objc_cache_capacity(const struct cache_t * _Nonnull cache);

#if CONFIG_USE_PREOPT_CACHES

OBJC_EXPORT bool objc_cache_isConstantOptimizedCache(const struct cache_t * _Nonnull cache, bool strict, uintptr_t empty_addr);
OBJC_EXPORT unsigned objc_cache_preoptCapacity(const struct cache_t * _Nonnull cache);
OBJC_EXPORT Class _Nonnull objc_cache_preoptFallbackClass(const struct cache_t * _Nonnull cache);
OBJC_EXPORT const struct preopt_cache_t * _Nonnull objc_cache_preoptCache(const struct cache_t * _Nonnull cache);

/* dyld_shared_cache_builder and obj-C agree on these definitions. Do not use if you are not the dyld shared cache builder */
enum {
    OBJC_OPT_METHODNAME_START      = 0,
    OBJC_OPT_METHODNAME_END        = 1,
    OBJC_OPT_INLINED_METHODS_START = 2,
    OBJC_OPT_INLINED_METHODS_END   = 3,

    __OBJC_OPT_OFFSETS_COUNT /* no trailing comma to make C++98 happy */
};

OBJC_EXPORT const int objc_opt_preopt_caches_version ;
OBJC_EXPORT const uintptr_t objc_opt_offsets[__OBJC_OPT_OFFSETS_COUNT] ;

#endif

__END_DECLS

#endif
