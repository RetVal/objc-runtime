/*
 * @APPLE_LICENSE_HEADER_START@
 * 
 * Copyright (c) 2011 Apple Inc.  All Rights Reserved.
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
 *  objc-msg-arm64.s - ARM64 code to support objc messaging
 *
 ********************************************************************/

#ifdef __arm64__
	
#include <arm/arch.h>


.data

// _objc_entryPoints and _objc_exitPoints are used by method dispatch
// caching code to figure out whether any threads are actively 
// in the cache for dispatching.  The labels surround the asm code
// that do cache lookups.  The tables are zero-terminated.

.align 4
.private_extern _objc_entryPoints
_objc_entryPoints:
	.quad   _cache_getImp
	.quad   _objc_msgSend
	.quad   _objc_msgSendSuper
	.quad   _objc_msgSendSuper2
	.quad   _objc_msgLookup
	.quad   _objc_msgLookupSuper2
	.quad   0

.private_extern _objc_exitPoints
_objc_exitPoints:
	.quad   LExit_cache_getImp
	.quad   LExit_objc_msgSend
	.quad   LExit_objc_msgSendSuper
	.quad   LExit_objc_msgSendSuper2
	.quad   LExit_objc_msgLookup
	.quad   LExit_objc_msgLookupSuper2
	.quad   0


/********************************************************************
* List every exit insn from every messenger for debugger use.
* Format:
* (
*   1 word instruction's address
*   1 word type (ENTER or FAST_EXIT or SLOW_EXIT or NIL_EXIT)
* )
* 1 word zero
*
* ENTER is the start of a dispatcher
* FAST_EXIT is method dispatch
* SLOW_EXIT is uncached method lookup
* NIL_EXIT is returning zero from a message sent to nil
* These must match objc-gdb.h.
********************************************************************/
	
#define ENTER     1
#define FAST_EXIT 2
#define SLOW_EXIT 3
#define NIL_EXIT  4

.section __DATA,__objc_msg_break
.globl _gdb_objc_messenger_breakpoints
_gdb_objc_messenger_breakpoints:
// contents populated by the macros below

.macro MESSENGER_START
4:
	.section __DATA,__objc_msg_break
	.quad 4b
	.quad ENTER
	.text
.endmacro
.macro MESSENGER_END_FAST
4:
	.section __DATA,__objc_msg_break
	.quad 4b
	.quad FAST_EXIT
	.text
.endmacro
.macro MESSENGER_END_SLOW
4:
	.section __DATA,__objc_msg_break
	.quad 4b
	.quad SLOW_EXIT
	.text
.endmacro
.macro MESSENGER_END_NIL
4:
	.section __DATA,__objc_msg_break
	.quad 4b
	.quad NIL_EXIT
	.text
.endmacro


/* objc_super parameter to sendSuper */
#define RECEIVER         0
#define CLASS            8

/* Selected field offsets in class structure */
#define SUPERCLASS       8
#define CACHE            16

/* Selected field offsets in isa field */
#define ISA_MASK         0x0000000ffffffff8

/* Selected field offsets in method structure */
#define METHOD_NAME      0
#define METHOD_TYPES     8
#define METHOD_IMP       16


/********************************************************************
 * ENTRY functionName
 * STATIC_ENTRY functionName
 * END_ENTRY functionName
 ********************************************************************/

.macro ENTRY /* name */
	.text
	.align 5
	.globl    $0
$0:
.endmacro

.macro STATIC_ENTRY /*name*/
	.text
	.align 5
	.private_extern $0
$0:
.endmacro

.macro END_ENTRY /* name */
LExit$0:
.endmacro


/********************************************************************
 * UNWIND name, flags
 * Unwind info generation	
 ********************************************************************/
.macro UNWIND
	.section __LD,__compact_unwind,regular,debug
	.quad $0
	.set  LUnwind$0, LExit$0 - $0
	.long LUnwind$0
	.long $1
	.quad 0	 /* no personality */
	.quad 0  /* no LSDA */
	.text
.endmacro

#define NoFrame 0x02000000  // no frame, no SP adjustment
#define FrameWithNoSaves 0x04000000  // frame, no non-volatile saves


/********************************************************************
 *
 * CacheLookup NORMAL|GETIMP|LOOKUP
 * 
 * Locate the implementation for a selector in a class method cache.
 *
 * Takes:
 *	 x1 = selector
 *	 x16 = class to be searched
 *
 * Kills:
 * 	 x9,x10,x11,x12, x17
 *
 * On exit: (found) calls or returns IMP
 *                  with x16 = class, x17 = IMP
 *          (not found) jumps to LCacheMiss
 *
 ********************************************************************/

#define NORMAL 0
#define GETIMP 1
#define LOOKUP 2

.macro CacheHit
.if $0 == NORMAL
	MESSENGER_END_FAST
	br	x17			// call imp
.elseif $0 == GETIMP
	mov	x0, x17			// return imp
	ret
.elseif $0 == LOOKUP
	ret				// return imp via x17
.else
.abort oops
.endif
.endmacro

.macro CheckMiss
	// miss if bucket->sel == 0
.if $0 == GETIMP
	cbz	x9, LGetImpMiss
.elseif $0 == NORMAL
	cbz	x9, __objc_msgSend_uncached
.elseif $0 == LOOKUP
	cbz	x9, __objc_msgLookup_uncached
.else
.abort oops
.endif
.endmacro

.macro JumpMiss
.if $0 == GETIMP
	b	LGetImpMiss
.elseif $0 == NORMAL
	b	__objc_msgSend_uncached
.elseif $0 == LOOKUP
	b	__objc_msgLookup_uncached
.else
.abort oops
.endif
.endmacro

.macro CacheLookup
	// x1 = SEL, x16 = isa
	ldp	x10, x11, [x16, #CACHE]	// x10 = buckets, x11 = occupied|mask
	and	w12, w1, w11		// x12 = _cmd & mask
	add	x12, x10, x12, LSL #4	// x12 = buckets + ((_cmd & mask)<<4)

	ldp	x9, x17, [x12]		// {x9, x17} = *bucket
1:	cmp	x9, x1			// if (bucket->sel != _cmd)
	b.ne	2f			//     scan more
	CacheHit $0			// call or return imp
	
2:	// not hit: x12 = not-hit bucket
	CheckMiss $0			// miss if bucket->sel == 0
	cmp	x12, x10		// wrap if bucket == buckets
	b.eq	3f
	ldp	x9, x17, [x12, #-16]!	// {x9, x17} = *--bucket
	b	1b			// loop

3:	// wrap: x12 = first bucket, w11 = mask
	add	x12, x12, w11, UXTW #4	// x12 = buckets+(mask<<4)

	// Clone scanning loop to miss instead of hang when cache is corrupt.
	// The slow path may detect any corruption and halt later.

	ldp	x9, x17, [x12]		// {x9, x17} = *bucket
1:	cmp	x9, x1			// if (bucket->sel != _cmd)
	b.ne	2f			//     scan more
	CacheHit $0			// call or return imp
	
2:	// not hit: x12 = not-hit bucket
	CheckMiss $0			// miss if bucket->sel == 0
	cmp	x12, x10		// wrap if bucket == buckets
	b.eq	3f
	ldp	x9, x17, [x12, #-16]!	// {x9, x17} = *--bucket
	b	1b			// loop

3:	// double wrap
	JumpMiss $0
	
.endmacro


/********************************************************************
 *
 * id objc_msgSend(id self, SEL _cmd, ...);
 * IMP objc_msgLookup(id self, SEL _cmd, ...);
 * 
 * objc_msgLookup ABI:
 * IMP returned in x17
 * x16 reserved for our use but not used
 *
 ********************************************************************/

	.data
	.align 3
	.globl _objc_debug_taggedpointer_classes
_objc_debug_taggedpointer_classes:
	.fill 16, 8, 0
	.globl _objc_debug_taggedpointer_ext_classes
_objc_debug_taggedpointer_ext_classes:
	.fill 256, 8, 0

	ENTRY _objc_msgSend
	UNWIND _objc_msgSend, NoFrame
	MESSENGER_START

	cmp	x0, #0			// nil check and tagged pointer check
	b.le	LNilOrTagged		//  (MSB tagged pointer looks negative)
	ldr	x13, [x0]		// x13 = isa
	and	x16, x13, #ISA_MASK	// x16 = class	
LGetIsaDone:
	CacheLookup NORMAL		// calls imp or objc_msgSend_uncached

LNilOrTagged:
	b.eq	LReturnZero		// nil check

	// tagged
	mov	x10, #0xf000000000000000
	cmp	x0, x10
	b.hs	LExtTag
	adrp	x10, _objc_debug_taggedpointer_classes@PAGE
	add	x10, x10, _objc_debug_taggedpointer_classes@PAGEOFF
	ubfx	x11, x0, #60, #4
	ldr	x16, [x10, x11, LSL #3]
	b	LGetIsaDone

LExtTag:
	// ext tagged
	adrp	x10, _objc_debug_taggedpointer_ext_classes@PAGE
	add	x10, x10, _objc_debug_taggedpointer_ext_classes@PAGEOFF
	ubfx	x11, x0, #52, #8
	ldr	x16, [x10, x11, LSL #3]
	b	LGetIsaDone
	
LReturnZero:
	// x0 is already zero
	mov	x1, #0
	movi	d0, #0
	movi	d1, #0
	movi	d2, #0
	movi	d3, #0
	MESSENGER_END_NIL
	ret

	END_ENTRY _objc_msgSend


	ENTRY _objc_msgLookup
	UNWIND _objc_msgLookup, NoFrame

	cmp	x0, #0			// nil check and tagged pointer check
	b.le	LLookup_NilOrTagged	//  (MSB tagged pointer looks negative)
	ldr	x13, [x0]		// x13 = isa
	and	x16, x13, #ISA_MASK	// x16 = class	
LLookup_GetIsaDone:
	CacheLookup LOOKUP		// returns imp

LLookup_NilOrTagged:
	b.eq	LLookup_Nil	// nil check

	// tagged
	mov	x10, #0xf000000000000000
	cmp	x0, x10
	b.hs	LLookup_ExtTag
	adrp	x10, _objc_debug_taggedpointer_classes@PAGE
	add	x10, x10, _objc_debug_taggedpointer_classes@PAGEOFF
	ubfx	x11, x0, #60, #4
	ldr	x16, [x10, x11, LSL #3]
	b	LLookup_GetIsaDone

LLookup_ExtTag:	
	adrp	x10, _objc_debug_taggedpointer_ext_classes@PAGE
	add	x10, x10, _objc_debug_taggedpointer_ext_classes@PAGEOFF
	ubfx	x11, x0, #52, #8
	ldr	x16, [x10, x11, LSL #3]
	b	LLookup_GetIsaDone

LLookup_Nil:
	adrp	x17, __objc_msgNil@PAGE
	add	x17, x17, __objc_msgNil@PAGEOFF
	ret

	END_ENTRY _objc_msgLookup

	
	STATIC_ENTRY __objc_msgNil

	// x0 is already zero
	mov	x1, #0
	movi	d0, #0
	movi	d1, #0
	movi	d2, #0
	movi	d3, #0
	ret
	
	END_ENTRY __objc_msgNil


	ENTRY _objc_msgSendSuper
	UNWIND _objc_msgSendSuper, NoFrame
	MESSENGER_START

	ldp	x0, x16, [x0]		// x0 = real receiver, x16 = class
	CacheLookup NORMAL		// calls imp or objc_msgSend_uncached

	END_ENTRY _objc_msgSendSuper

	// no _objc_msgLookupSuper

	ENTRY _objc_msgSendSuper2
	UNWIND _objc_msgSendSuper2, NoFrame
	MESSENGER_START

	ldp	x0, x16, [x0]		// x0 = real receiver, x16 = class
	ldr	x16, [x16, #SUPERCLASS]	// x16 = class->superclass
	CacheLookup NORMAL

	END_ENTRY _objc_msgSendSuper2

	
	ENTRY _objc_msgLookupSuper2
	UNWIND _objc_msgLookupSuper2, NoFrame

	ldp	x0, x16, [x0]		// x0 = real receiver, x16 = class
	ldr	x16, [x16, #SUPERCLASS]	// x16 = class->superclass
	CacheLookup LOOKUP

	END_ENTRY _objc_msgLookupSuper2


.macro MethodTableLookup
	
	// push frame
	stp	fp, lr, [sp, #-16]!
	mov	fp, sp

	// save parameter registers: x0..x8, q0..q7
	sub	sp, sp, #(10*8 + 8*16)
	stp	q0, q1, [sp, #(0*16)]
	stp	q2, q3, [sp, #(2*16)]
	stp	q4, q5, [sp, #(4*16)]
	stp	q6, q7, [sp, #(6*16)]
	stp	x0, x1, [sp, #(8*16+0*8)]
	stp	x2, x3, [sp, #(8*16+2*8)]
	stp	x4, x5, [sp, #(8*16+4*8)]
	stp	x6, x7, [sp, #(8*16+6*8)]
	str	x8,     [sp, #(8*16+8*8)]

	// receiver and selector already in x0 and x1
	mov	x2, x16
	bl	__class_lookupMethodAndLoadCache3

	// imp in x0
	mov	x17, x0
	
	// restore registers and return
	ldp	q0, q1, [sp, #(0*16)]
	ldp	q2, q3, [sp, #(2*16)]
	ldp	q4, q5, [sp, #(4*16)]
	ldp	q6, q7, [sp, #(6*16)]
	ldp	x0, x1, [sp, #(8*16+0*8)]
	ldp	x2, x3, [sp, #(8*16+2*8)]
	ldp	x4, x5, [sp, #(8*16+4*8)]
	ldp	x6, x7, [sp, #(8*16+6*8)]
	ldr	x8,     [sp, #(8*16+8*8)]

	mov	sp, fp
	ldp	fp, lr, [sp], #16

.endmacro

	STATIC_ENTRY __objc_msgSend_uncached
	UNWIND __objc_msgSend_uncached, FrameWithNoSaves

	// THIS IS NOT A CALLABLE C FUNCTION
	// Out-of-band x16 is the class to search
	
	MethodTableLookup
	br	x17

	END_ENTRY __objc_msgSend_uncached


	STATIC_ENTRY __objc_msgLookup_uncached
	UNWIND __objc_msgLookup_uncached, FrameWithNoSaves

	// THIS IS NOT A CALLABLE C FUNCTION
	// Out-of-band x16 is the class to search
	
	MethodTableLookup
	ret

	END_ENTRY __objc_msgLookup_uncached


	STATIC_ENTRY _cache_getImp

	and	x16, x0, #ISA_MASK
	CacheLookup GETIMP

LGetImpMiss:
	mov	x0, #0
	ret

	END_ENTRY _cache_getImp


/********************************************************************
*
* id _objc_msgForward(id self, SEL _cmd,...);
*
* _objc_msgForward is the externally-callable
*   function returned by things like method_getImplementation().
* _objc_msgForward_impcache is the function pointer actually stored in
*   method caches.
*
********************************************************************/

	STATIC_ENTRY __objc_msgForward_impcache

	MESSENGER_START
	nop
	MESSENGER_END_SLOW

	// No stret specialization.
	b	__objc_msgForward

	END_ENTRY __objc_msgForward_impcache

	
	ENTRY __objc_msgForward

	adrp	x17, __objc_forward_handler@PAGE
	ldr	x17, [x17, __objc_forward_handler@PAGEOFF]
	br	x17
	
	END_ENTRY __objc_msgForward
	
	
	ENTRY _objc_msgSend_noarg
	b	_objc_msgSend
	END_ENTRY _objc_msgSend_noarg

	ENTRY _objc_msgSend_debug
	b	_objc_msgSend
	END_ENTRY _objc_msgSend_debug

	ENTRY _objc_msgSendSuper2_debug
	b	_objc_msgSendSuper2
	END_ENTRY _objc_msgSendSuper2_debug

	
	ENTRY _method_invoke
	// x1 is method triplet instead of SEL
	ldr	x17, [x1, #METHOD_IMP]
	ldr	x1, [x1, #METHOD_NAME]
	br	x17
	END_ENTRY _method_invoke

#endif
