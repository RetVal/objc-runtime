/*
 * @APPLE_LICENSE_HEADER_START@
 *
 * Copyright (c) 2021 Apple Inc.  All Rights Reserved.
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
/********************************************************************
 *
 *  retain-release-helpers-arm64.s - ARM64 code for compressed retain/release sequences
 *
 ********************************************************************/

#ifdef __arm64

#include "isa.h"
#include "arm64-asm.h"


// We support the inlined fast path when we have an inline refcount. We don't
// currently have support for indexed isa.
#if ISA_HAS_INLINE_RC && !SUPPORT_INDEXED_ISA
#define INLINE_RR_FASTPATH 1
#endif

#if INLINE_RR_FASTPATH

// Constants for various offsets and bit positions used later.
#define HAS_DEFAULT_RR_BIT 2
#define NONPOINTER_ISA_BIT 0
#define IS_SWIFT_STABLE_BIT 1
#define SWIFT_CLASS_FLAGS_OFFSET (CLASS_BITS_OFFSET + PTRSIZE) // Located at &objc_class::bits + 1.
#define SWIFT_CLASS_FLAG_USES_SWIFT_REFCOUNTING_BIT 1
#define CLASS_BITS_OFFSET (4 * PTRSIZE)
#define CLASS_CACHE_FLAGS_OFFSET (3 * PTRSIZE)
#define CLASS_CACHE_FLAGS_SHIFT 48
#define CLASS_CACHE_FLAG_HAS_CUSTOM_DEALLOC_INITIATION ((1<<12) << CLASS_CACHE_FLAGS_SHIFT)

// Set up the selectors and selrefs we'll use with msgSend.
.section    __TEXT,__objc_methname,cstring_literals
LRetain:
	.asciz "retain"
LRelease:
	.asciz "release"
LDealloc:
	.asciz "dealloc"
LInitiateDealloc:
	.asciz "_objc_initiateDealloc"

.section    __DATA,__objc_selrefs,literal_pointers,no_dead_strip
.p2align    PTRSHIFT
LRetainRef:
	PTR LRetain
LReleaseRef:
	PTR LRelease
LDeallocRef:
	PTR LDealloc
LInitiateDeallocRef:
	PTR LInitiateDealloc

// Use ARM64e as a good-enough proxy for CAS support.
#if __arm64e__
#define USE_CAS 1
#endif

// Define a CLREX macro that expands to nothing when we use CAS.
#if USE_CAS
#define CLREX
#else
#define CLREX clrex
#endif

.text
.align 2

.macro RetainFunction reg
.ifc \reg, x1
	RetainFunctionImpl \reg, p2
.else
	RetainFunctionImpl \reg, p1
.endif
.endmacro

.macro RetainFunctionImpl reg, tmpreg
.globl _objc_retain_\reg
_objc_retain_\reg:
	// These functions always return their argument. Move the argument into
	// x0 right away so that's always taken care of. The ands performs that
	// move and updates the condition flags for the nil/tagged check.
	ands x0, \reg, \reg

	// Check for nil and tagged pointers.
#if SUPPORT_TAGGED_POINTERS
	b.le LnilOrTagged_retain // Check self <= 0 for tagged-or-nil.
#else
	b.eq LnilOrTagged_retain // Check self == 0 when we don't have tagged pointers.
#endif
	// Load raw isa value into p16. If we don't have CAS, load-exclusive.
#if USE_CAS
	// CAS updates p16 so we begin our retry after the load.
	ldr p16, [\reg]
Lretry_retain_\reg:
#else
Lretry_retain_\reg:
	// stxr does not update p16 so we need to reload it when retrying.
	ldxr p16, [\reg]
#endif
	and p17, p16, #ISA_MASK_NOSIG // p17 contains the actual class pointer.
	ldr p17, [p17, #CLASS_BITS_OFFSET]  // p17 contains the class's `bits` field.

	// If hasCustomRR, call swift_retain or msgSend retain. This code
	// expects the raw isa value in p16 and `bits` in p17.
	tbz p17, HAS_DEFAULT_RR_BIT, LcustomRR_retain

	tbz p16, NONPOINTER_ISA_BIT, LrawISA_retain    // If raw isa pointer, call into C.

	// We now have:
	// * Raw isa field in p16.
	// * Object with nonpointer isa.
	// * And no custom RR override.

	// Check for deallocating. An object is deallocating when its inline
	// refcount is 0 and has_sidetable is 0. These fields are contiguous
	// at the top of the isa field, so we shift away the other bits and then
	// compare with zero.
	lsr p17, p16, #RC_HAS_SIDETABLE_BIT
	cbz p17, Ldeallocating_retain

	// We're ready to actually perform the retain. Next steps:
	// * Increment the inline refcount.
	// * Check for overflow.
	// * CAS the isa field.
	mov p17, RC_ONE
	adds p17, p16, p17 // New isa field value is in p17.
	b.cs Loverflow_retain
#if USE_CAS
	mov \tmpreg, p16
	cas p16, p17, [\reg] // Try to store the updated value.
	cmp \tmpreg, p16
	b.ne Lretry_retain_\reg // On failure, retry. p16 has been loaded with the latest value.
#else
	stxr w16, p17, [\reg] // Try to store the updated value.
	cbnz w16, Lretry_retain_\reg // On failure, retry.
#endif

	ret
.endmacro

// The object is already in x0/w0, so we just need to clear our exclusive load
// and call swift_retain or objc_msgSend.
LcustomRR_retain:
	CLREX

	// Check the isSwiftStable bit, msgSend if this class isn't Swift.
	tbz p17, IS_SWIFT_STABLE_BIT, LmsgSend_retain

	// Load the Swift class flags into p17.
	and p17, p16, #ISA_MASK_NOSIG // p17 contains the actual class pointer.
	ldr w17, [p17, #SWIFT_CLASS_FLAGS_OFFSET]

	// If this class doesn't use Swift refcounting, msgSend.
	tbz w17, SWIFT_CLASS_FLAG_USES_SWIFT_REFCOUNTING_BIT, LmsgSend_retain

	// The class uses Swift refcounting. Call the pointer in swiftRetain.
	adrp x17, _swiftRetain@PAGE
	ldr  x17, [x17, _swiftRetain@PAGEOFF]
	TailCallFunctionPointer x17

LmsgSend_retain:
	adrp x1, LRetainRef@PAGE
	ldr  x1, [x1, LRetainRef@PAGEOFF]
	b _objc_msgSend

// The object is already in x0/w0, so we just need to clear our exclusive load
// and jump to objc_retain_full.
LrawISA_retain:
	CLREX
	b _objc_retain_full

// The object is already in x0/w0, so we just need to clear our exclusive load
// and jump to _objc_rootRetain.
Loverflow_retain:
	CLREX
	b __objc_rootRetain

Ldeallocating_retain:
	// Clear our exclusive load of the isa before returning.
	CLREX
LnilOrTagged_retain:
	// For nil/tagged/deallocating objects, release is a no-op.
	// The object is already in x0/w0, so we can just return.
	ret

.globl _objc_retain
_objc_retain:
RetainFunction x0
RetainFunction x1
RetainFunction x2
RetainFunction x3
RetainFunction x4
RetainFunction x5
RetainFunction x6
RetainFunction x7
RetainFunction x8
RetainFunction x9
RetainFunction x10
RetainFunction x11
RetainFunction x12
RetainFunction x13
RetainFunction x14
RetainFunction x15
RetainFunction x19
RetainFunction x20
RetainFunction x21
RetainFunction x22
RetainFunction x23
RetainFunction x24
RetainFunction x25
RetainFunction x26
RetainFunction x27
RetainFunction x28


.macro ReleaseFunction reg
.ifc \reg, x1
	ReleaseFunctionImpl \reg, p2, p3
.else
.ifc \reg, x2
	ReleaseFunctionImpl \reg, p1, p3
.else
	ReleaseFunctionImpl \reg, p1, p2
.endif
.endif
.endmacro

.macro ReleaseFunctionImpl reg, casReg, maskedIsaReg
	.text
	.align 2
	.globl _objc_release_\reg
_objc_release_\reg:
	// Many paths need the object pointer to be in x0. Move it here, and
	// also set the condition flags for the nil/tagged check.
	ands x0, \reg, \reg

	// Check for nil and tagged pointers.
#if SUPPORT_TAGGED_POINTERS
	b.le LnilOrTagged_release // Check self <= 0 for tagged-or-nil.
#else
	b.eq LnilOrTagged_release // Check self == 0 when we don't have tagged pointers.
#endif
// Load raw isa value into p16. If we don't have CAS, load-exclusive.
#if USE_CAS
	// CAS updates p16 so we begin our retry after the load.
	ldr p16, [\reg]
Lretry_release_\reg:
#else
Lretry_release_\reg:
	// stxr does not update p16 so we need to reload it when retrying.
	ldxr p16, [\reg]
#endif
	and \maskedIsaReg, p16, #ISA_MASK_NOSIG      // maskedIsaReg contains the actual class pointer.
	ldr p17, [\maskedIsaReg, #CLASS_BITS_OFFSET]       // maskedIsaReg contains the class's `bits` field.

	// If hasCustomRR, call swift_release or msgSend release. This code
	// expects the raw isa value in p16 and `bits` in p17.
	tbz p17, HAS_DEFAULT_RR_BIT, LcustomRR_release_\reg

	tbz p16, NONPOINTER_ISA_BIT, LrawISA_release_\reg   // If raw isa pointer, call into C.

	// We now have:
	// * Raw isa field in p16.
	// * Object with nonpointer isa.
	// * And no custom RR override.

	// Check for deallocating. An object is deallocating when its inline
	// refcount is 0 and has_sidetable is 0. These fields are contiguous
	// at the top of the isa field, so we shift away the other bits and then
	// compare with zero.
	lsr p17, p16, #RC_HAS_SIDETABLE_BIT
	cbz p17, Ldeallocating_release

	// If the inline refcount is zero and we have a sidetable, then we need
	// to call rootRelease to borrow from the sidetable.
	cmp p17, #1
	b.eq Lcall_root_release_\reg

	// We're ready to actually perform the release. Next steps:
	// * Decrement the inline refcount.
	// * CAS the isa field.
	// * Check for zero.
	mov p17, RC_ONE
	sub p17, p16, p17 // isa -= RC_ONE

#if USE_CAS
	mov \casReg, p16
	cas p16, p17, [\reg] // Try to store the updated value.
	cmp \casReg, p16
	b.ne Lretry_release_\reg // On failure, retry. p16 has been loaded with the latest value.
#else
	// Store the new isa into the object.
	stxr w16, p17, [\reg] // Try to store the updated value.
	cbnz w16, Lretry_release_\reg // On failure, retry.
#endif

	// Success. Did we transition to deallocating? If so, call dealloc.
	lsr p17, p17, #RC_HAS_SIDETABLE_BIT
	cbz p17, Ldealloc_\reg

	ret

Ldealloc_\reg:
	// Successfully stored a deallocating isa into the object. Send dealloc
	// or _objc_initiateDealloc.

	// At this point, we have:
	//   Masked isa in maskedIsaReg.
	//   self in p0.
	ldr x17, [\maskedIsaReg, #CLASS_CACHE_FLAGS_OFFSET]

	adrp x1, LDeallocRef@PAGE
	ldr  x1, [x1, LDeallocRef@PAGEOFF]
	adrp x2, LInitiateDeallocRef@PAGE
	ldr  x2, [x2, LInitiateDeallocRef@PAGEOFF]

	tst x17, #CLASS_CACHE_FLAG_HAS_CUSTOM_DEALLOC_INITIATION
	csel x1, x1, x2, eq

	b    _objc_msgSend

Lcall_root_release_\reg:
	CLREX
	b   __objc_rootRelease

// Call swift_release or objc_msgSend.
LcustomRR_release_\reg:
	CLREX
	// Check the isSwiftStable bit, msgSend if this class isn't Swift.
	tbz p17, IS_SWIFT_STABLE_BIT, LmsgSend_release

	// Load the Swift class flags into p17.
	and p17, p16, #ISA_MASK_NOSIG // p17 contains the actual class pointer.
	ldr w17, [p17, #SWIFT_CLASS_FLAGS_OFFSET]

	// If this class doesn't use Swift refcounting, msgSend.
	tbz w17, SWIFT_CLASS_FLAG_USES_SWIFT_REFCOUNTING_BIT, LmsgSend_release

	// The class uses Swift refcounting. Call the pointer in swiftRetain.
	adrp x17, _swiftRelease@PAGE
	ldr  x17, [x17, _swiftRelease@PAGEOFF]
	TailCallFunctionPointer x17

LrawISA_release_\reg:
	// The object has a raw isa pointer, call into C for that.
	CLREX
	b   _objc_release_full

.endmacro

Ldeallocating_release:
	// Clear our exclusive load of the isa before returning.
	CLREX
LnilOrTagged_release:
	// For nil/tagged/deallocating objects, release is a no-op.
	ret

LmsgSend_release:
	adrp x1, LReleaseRef@PAGE
	ldr  x1, [x1, LReleaseRef@PAGEOFF]
	b    _objc_msgSend


.globl _objc_release
_objc_release:
ReleaseFunction x0
ReleaseFunction x1
ReleaseFunction x2
ReleaseFunction x3
ReleaseFunction x4
ReleaseFunction x5
ReleaseFunction x6
ReleaseFunction x7
ReleaseFunction x8
ReleaseFunction x9
ReleaseFunction x10
ReleaseFunction x11
ReleaseFunction x12
ReleaseFunction x13
ReleaseFunction x14
ReleaseFunction x15
ReleaseFunction x19
ReleaseFunction x20
ReleaseFunction x21
ReleaseFunction x22
ReleaseFunction x23
ReleaseFunction x24
ReleaseFunction x25
ReleaseFunction x26
ReleaseFunction x27
ReleaseFunction x28

#else

// When !INLINE_RR_FASTPATH, generate simple thunks that call into objc_retain/release.

.macro RetainFunction reg
	.text
	.align 2
	.globl _objc_retain_\reg
_objc_retain_\reg:
	mov x0, \reg
	b   _objc_retain
.endmacro

.macro ReleaseFunction reg
	.text
	.align 2
	.globl _objc_release_\reg
_objc_release_\reg:
	mov x0, \reg
	b   _objc_release
.endmacro

RetainFunction x1
RetainFunction x2
RetainFunction x3
RetainFunction x4
RetainFunction x5
RetainFunction x6
RetainFunction x7
RetainFunction x8
RetainFunction x9
RetainFunction x10
RetainFunction x11
RetainFunction x12
RetainFunction x13
RetainFunction x14
RetainFunction x15
RetainFunction x19
RetainFunction x20
RetainFunction x21
RetainFunction x22
RetainFunction x23
RetainFunction x24
RetainFunction x25
RetainFunction x26
RetainFunction x27
RetainFunction x28

ReleaseFunction x1
ReleaseFunction x2
ReleaseFunction x3
ReleaseFunction x4
ReleaseFunction x5
ReleaseFunction x6
ReleaseFunction x7
ReleaseFunction x8
ReleaseFunction x9
ReleaseFunction x10
ReleaseFunction x11
ReleaseFunction x12
ReleaseFunction x13
ReleaseFunction x14
ReleaseFunction x15
ReleaseFunction x19
ReleaseFunction x20
ReleaseFunction x21
ReleaseFunction x22
ReleaseFunction x23
ReleaseFunction x24
ReleaseFunction x25
ReleaseFunction x26
ReleaseFunction x27
ReleaseFunction x28

#endif // INLINE_RR_FASTPATH

#endif
