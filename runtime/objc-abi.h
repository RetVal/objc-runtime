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


#ifndef _OBJC_ABI_H
#define _OBJC_ABI_H

/* 
 * WARNING  DANGER  HAZARD  BEWARE  EEK
 * 
 * Everything in this file is for Apple Internal use only.
 * These will change in arbitrary OS updates and in unpredictable ways.
 * When your program breaks, you get to keep both pieces.
 */

/*
 * objc-abi.h: Declarations for functions used by compiler codegen.
 */

#include <malloc/malloc.h>
#include <TargetConditionals.h>
#include <objc/objc.h>
#include <objc/runtime.h>
#include <objc/message.h>

/* Runtime startup. */

// Old static initializer. Used by old crt1.o and old bug workarounds.
OBJC_EXPORT void _objcInit(void)
    OBJC_AVAILABLE(10.0, 2.0, 9.0, 1.0);

/* Images */

// Description of an Objective-C image.
// __DATA,__objc_imageinfo stores one of these.
typedef struct objc_image_info {
    uint32_t version; // currently 0
    uint32_t flags;

#if __cplusplus >= 201103L
  private:
    enum : uint32_t {
        IsReplacement       = 1<<0,  // used for Fix&Continue, now ignored
        SupportsGC          = 1<<1,  // image supports GC
        RequiresGC          = 1<<2,  // image requires GC
        OptimizedByDyld     = 1<<3,  // image is from an optimized shared cache
        CorrectedSynthesize = 1<<4,  // used for an old workaround, now ignored
        IsSimulated         = 1<<5,  // image compiled for a simulator platform
        HasCategoryClassProperties  = 1<<6,  // class properties in category_t

        SwiftVersionMaskShift = 8,
        SwiftVersionMask    = 0xff << SwiftVersionMaskShift  // Swift ABI version

    };
   public:
    enum : uint32_t {
        SwiftVersion1   = 1,
        SwiftVersion1_2 = 2,
        SwiftVersion2   = 3,
        SwiftVersion3   = 4
    };

  public:
    bool isReplacement()   const { return flags & IsReplacement; }
    bool supportsGC()      const { return flags & SupportsGC; }
    bool requiresGC()      const { return flags & RequiresGC; }
    bool optimizedByDyld() const { return flags & OptimizedByDyld; }
    bool hasCategoryClassProperties() const { return flags & HasCategoryClassProperties; }
    bool containsSwift()   const { return (flags & SwiftVersionMask) != 0; }
    uint32_t swiftVersion() const { return (flags & SwiftVersionMask) >> SwiftVersionMaskShift; }
#endif
} objc_image_info;

/* 
IsReplacement:
   Once used for Fix&Continue in old OS X object files (not final linked images)
   Not currently used.

SupportsGC:
   App: GC is required. Framework: GC is supported but not required.

RequiresGC:
   Framework: GC is required.

OptimizedByDyld:
   Assorted metadata precooked in the dyld shared cache.
   Never set for images outside the shared cache file itself.

CorrectedSynthesize:
   Once used on old iOS to mark images that did not have a particular 
   miscompile. Not used by the runtime.

IsSimulated:
   Image was compiled for a simulator platform. Not used by the runtime.

HasClassProperties:
   New ABI: category_t.classProperties fields are present.
   Old ABI: Set by some compilers. Not used by the runtime.
*/


/* Properties */

// Read or write an object property. Not all object properties use these.
OBJC_EXPORT id objc_getProperty(id self, SEL _cmd, ptrdiff_t offset, BOOL atomic)
    OBJC_AVAILABLE(10.5, 2.0, 9.0, 1.0);
OBJC_EXPORT void objc_setProperty(id self, SEL _cmd, ptrdiff_t offset, id newValue, BOOL atomic, signed char shouldCopy)
    OBJC_AVAILABLE(10.5, 2.0, 9.0, 1.0);

OBJC_EXPORT void objc_setProperty_atomic(id self, SEL _cmd, id newValue, ptrdiff_t offset)
    OBJC_AVAILABLE(10.8, 6.0, 9.0, 1.0);
OBJC_EXPORT void objc_setProperty_nonatomic(id self, SEL _cmd, id newValue, ptrdiff_t offset)
    OBJC_AVAILABLE(10.8, 6.0, 9.0, 1.0);
OBJC_EXPORT void objc_setProperty_atomic_copy(id self, SEL _cmd, id newValue, ptrdiff_t offset)
    OBJC_AVAILABLE(10.8, 6.0, 9.0, 1.0);
OBJC_EXPORT void objc_setProperty_nonatomic_copy(id self, SEL _cmd, id newValue, ptrdiff_t offset)
    OBJC_AVAILABLE(10.8, 6.0, 9.0, 1.0);


// Read or write a non-object property. Not all uses are C structs, 
// and not all C struct properties use this.
OBJC_EXPORT void objc_copyStruct(void *dest, const void *src, ptrdiff_t size, BOOL atomic, BOOL hasStrong)
    OBJC_AVAILABLE(10.5, 2.0, 9.0, 1.0);

// Perform a copy of a C++ object using striped locks. Used by non-POD C++ typed atomic properties.
OBJC_EXPORT void objc_copyCppObjectAtomic(void *dest, const void *src, void (*copyHelper) (void *dest, const void *source))
    OBJC_AVAILABLE(10.8, 6.0, 9.0, 1.0);

/* Classes. */
#if __OBJC2__
OBJC_EXPORT IMP _objc_empty_vtable
    OBJC_AVAILABLE(10.5, 2.0, 9.0, 1.0);
#endif
OBJC_EXPORT struct objc_cache _objc_empty_cache
    OBJC_AVAILABLE(10.0, 2.0, 9.0, 1.0);


/* Messages */

#if __OBJC2__
// objc_msgSendSuper2() takes the current search class, not its superclass.
OBJC_EXPORT id objc_msgSendSuper2(struct objc_super *super, SEL op, ...)
    OBJC_AVAILABLE(10.6, 2.0, 9.0, 1.0);
OBJC_EXPORT void objc_msgSendSuper2_stret(struct objc_super *super, SEL op,...)
    OBJC_AVAILABLE(10.6, 2.0, 9.0, 1.0)
    OBJC_ARM64_UNAVAILABLE;

// objc_msgSend_noarg() may be faster for methods with no additional arguments.
OBJC_EXPORT id objc_msgSend_noarg(id self, SEL _cmd)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0);
#endif

#if __OBJC2__
// Debug messengers. Messengers used by the compiler have a debug flavor that 
// may perform extra sanity checking. 
// Old objc_msgSendSuper() does not have a debug version; this is OBJC2 only.
// *_fixup() do not have debug versions; use non-fixup only for debug mode.
OBJC_EXPORT id objc_msgSend_debug(id self, SEL op, ...)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0);
OBJC_EXPORT id objc_msgSendSuper2_debug(struct objc_super *super, SEL op, ...)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0);
OBJC_EXPORT void objc_msgSend_stret_debug(id self, SEL op, ...)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0)
    OBJC_ARM64_UNAVAILABLE;
OBJC_EXPORT void objc_msgSendSuper2_stret_debug(struct objc_super *super, SEL op,...)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0)
    OBJC_ARM64_UNAVAILABLE;

# if defined(__i386__)
OBJC_EXPORT double objc_msgSend_fpret_debug(id self, SEL op, ...)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0);
# elif defined(__x86_64__)
OBJC_EXPORT long double objc_msgSend_fpret_debug(id self, SEL op, ...)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0);
#  if __STDC_VERSION__ >= 199901L
OBJC_EXPORT _Complex long double objc_msgSend_fp2ret_debug(id self, SEL op, ...)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0);
#  else
OBJC_EXPORT void objc_msgSend_fp2ret_debug(id self, SEL op, ...)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0);
#  endif
# endif

#endif

#if __OBJC2__
// Lookup messengers.
// These are not callable C functions. Do not call them directly.
// The caller should set the method parameters, call objc_msgLookup(), 
// then immediately call the returned IMP.
// 
// Generic ABI:
// - Callee-saved registers are preserved.
// - Receiver and selector registers may be modified. These values must 
//   be passed to the called IMP. Other parameter registers are preserved.
// - Caller-saved non-parameter registers are not preserved. Some of 
//   these registers are used to pass data from objc_msgLookup() to 
//   the called IMP and must not be disturbed by the caller.
// - Red zone is not preserved.
// See each architecture's implementation for details.

OBJC_EXPORT void objc_msgLookup(void)
    OBJC_AVAILABLE(10.12, 10.0, 10.0, 3.0);
OBJC_EXPORT void objc_msgLookupSuper2(void)
    OBJC_AVAILABLE(10.12, 10.0, 10.0, 3.0);
OBJC_EXPORT void objc_msgLookup_stret(void)
    OBJC_AVAILABLE(10.12, 10.0, 10.0, 3.0)
    OBJC_ARM64_UNAVAILABLE;
OBJC_EXPORT void objc_msgLookupSuper2_stret(void)
    OBJC_AVAILABLE(10.12, 10.0, 10.0, 3.0)
    OBJC_ARM64_UNAVAILABLE;

# if defined(__i386__)
OBJC_EXPORT void objc_msgLookup_fpret(void)
    OBJC_AVAILABLE(10.12, 10.0, 10.0, 3.0);
# elif defined(__x86_64__)
OBJC_EXPORT void objc_msgLookup_fpret(void)
    OBJC_AVAILABLE(10.12, 10.0, 10.0, 3.0);
OBJC_EXPORT void objc_msgLookup_fp2ret(void)
    OBJC_AVAILABLE(10.12, 10.0, 10.0, 3.0);
# endif

#endif

#if TARGET_OS_OSX  &&  defined(__x86_64__)
// objc_msgSend_fixup() is used for vtable-dispatchable call sites.
OBJC_EXPORT void objc_msgSend_fixup(void)
    __OSX_DEPRECATED(10.5, 10.8, "fixup dispatch is no longer optimized") 
    __IOS_UNAVAILABLE __TVOS_UNAVAILABLE __WATCHOS_UNAVAILABLE;
OBJC_EXPORT void objc_msgSend_stret_fixup(void)
    __OSX_DEPRECATED(10.5, 10.8, "fixup dispatch is no longer optimized") 
    __IOS_UNAVAILABLE __TVOS_UNAVAILABLE __WATCHOS_UNAVAILABLE;
OBJC_EXPORT void objc_msgSendSuper2_fixup(void)
    __OSX_DEPRECATED(10.5, 10.8, "fixup dispatch is no longer optimized") 
    __IOS_UNAVAILABLE __TVOS_UNAVAILABLE __WATCHOS_UNAVAILABLE;
OBJC_EXPORT void objc_msgSendSuper2_stret_fixup(void)
    __OSX_DEPRECATED(10.5, 10.8, "fixup dispatch is no longer optimized") 
    __IOS_UNAVAILABLE __TVOS_UNAVAILABLE __WATCHOS_UNAVAILABLE;
OBJC_EXPORT void objc_msgSend_fpret_fixup(void)
    __OSX_DEPRECATED(10.5, 10.8, "fixup dispatch is no longer optimized") 
    __IOS_UNAVAILABLE __TVOS_UNAVAILABLE __WATCHOS_UNAVAILABLE;
OBJC_EXPORT void objc_msgSend_fp2ret_fixup(void)
    __OSX_DEPRECATED(10.5, 10.8, "fixup dispatch is no longer optimized") 
    __IOS_UNAVAILABLE __TVOS_UNAVAILABLE __WATCHOS_UNAVAILABLE;
#endif

/* C++-compatible exception handling. */
#if __OBJC2__

// fixme these conflict with C++ compiler's internal definitions
#if !defined(__cplusplus)

// Vtable for C++ exception typeinfo for Objective-C types.
OBJC_EXPORT const void *objc_ehtype_vtable[]
    OBJC_AVAILABLE(10.5, 2.0, 9.0, 1.0);

// C++ exception typeinfo for type `id`.
OBJC_EXPORT struct objc_typeinfo OBJC_EHTYPE_id
    OBJC_AVAILABLE(10.5, 2.0, 9.0, 1.0);

#endif

// Exception personality function for Objective-C and Objective-C++ code.
struct _Unwind_Exception;
struct _Unwind_Context;
OBJC_EXPORT int
__objc_personality_v0(int version,
                      int actions,
                      uint64_t exceptionClass,
                      struct _Unwind_Exception *exceptionObject,
                      struct _Unwind_Context *context)
    OBJC_AVAILABLE(10.5, 2.0, 9.0, 1.0);

#endif

/* ARC */

OBJC_EXPORT id objc_retainBlock(id)
    OBJC_AVAILABLE(10.7, 5.0, 9.0, 1.0);


/* Non-pointer isa */

#if __OBJC2__

// Extract class pointer from an isa field.
    
#if  TARGET_OS_SIMULATOR
    // No simulators use nonpointer isa yet.
    
#elif __LP64__
#   define OBJC_HAVE_NONPOINTER_ISA 1
#   define OBJC_HAVE_PACKED_NONPOINTER_ISA 1

// Packed-isa version. This one is used directly by Swift code.
// (Class)(isa & (uintptr_t)&objc_absolute_packed_isa_class_mask) == class ptr
OBJC_EXPORT const struct { char c; } objc_absolute_packed_isa_class_mask
    OBJC_AVAILABLE(10.12, 10.0, 10.0, 3.0);

#elif __ARM_ARCH_7K__ >= 2
#   define OBJC_HAVE_NONPOINTER_ISA 1
#   define OBJC_HAVE_INDEXED_NONPOINTER_ISA 1

// Indexed-isa version.
// if (isa & (uintptr_t)&objc_absolute_indexed_isa_magic_mask == (uintptr_t)&objc_absolute_indexed_isa_magic_value) {
//     uintptr_t index = (isa & (uintptr_t)&objc_absolute_indexed_isa_index_mask) >> (uintptr_t)&objc_absolute_indexed_isa_index_shift;
//     cls = objc_indexed_classes[index];
// } else
//     cls = (Class)isa;
// }
OBJC_EXPORT const struct { char c; } objc_absolute_indexed_isa_magic_mask
    OBJC_AVAILABLE(10.12, 10.0, 10.0, 3.0);
OBJC_EXPORT const struct { char c; } objc_absolute_indexed_isa_magic_value
    OBJC_AVAILABLE(10.12, 10.0, 10.0, 3.0);
OBJC_EXPORT const struct { char c; } objc_absolute_indexed_isa_index_mask
    OBJC_AVAILABLE(10.12, 10.0, 10.0, 3.0);
OBJC_EXPORT const struct { char c; } objc_absolute_indexed_isa_index_shift
    OBJC_AVAILABLE(10.12, 10.0, 10.0, 3.0);

#endif

// OBJC2
#endif

// _OBJC_ABI_H
#endif
