/*
 * @APPLE_LICENSE_HEADER_START@
 * 
 * Copyright (c) 2018 Apple Inc.  All Rights Reserved.
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
 *  arm64-asm.h - asm tools for arm64/arm64_32 and ROP/JOP
 *
 ********************************************************************/

#if __arm64__

#include "objc-config.h"

#if __LP64__
// true arm64

#define SUPPORT_TAGGED_POINTERS 1
#define PTR .quad
#define PTRSIZE 8
#define PTRSHIFT 3  // 1<<PTRSHIFT == PTRSIZE
// "p" registers are pointer-sized
#define UXTP UXTX
#define p0  x0
#define p1  x1
#define p2  x2
#define p3  x3
#define p4  x4
#define p5  x5
#define p6  x6
#define p7  x7
#define p8  x8
#define p9  x9
#define p10 x10
#define p11 x11
#define p12 x12
#define p13 x13
#define p14 x14
#define p15 x15
#define p16 x16
#define p17 x17

// true arm64
#else
// arm64_32

#define SUPPORT_TAGGED_POINTERS 0
#define PTR .long
#define PTRSIZE 4
#define PTRSHIFT 2  // 1<<PTRSHIFT == PTRSIZE
// "p" registers are pointer-sized
#define UXTP UXTW
#define p0  w0
#define p1  w1
#define p2  w2
#define p3  w3
#define p4  w4
#define p5  w5
#define p6  w6
#define p7  w7
#define p8  w8
#define p9  w9
#define p10 w10
#define p11 w11
#define p12 w12
#define p13 w13
#define p14 w14
#define p15 w15
#define p16 w16
#define p17 w17

// arm64_32
#endif


#if __has_feature(ptrauth_returns)
// ROP
#   define SignLR pacibsp

.macro AuthenticateLR
	autibsp
	tbz	x30, #62, . + 8
	brk	#0xc471
.endmacro

#else
// not ROP
#   define SignLR
#   define AuthenticateLR
#endif

#if __has_feature(ptrauth_calls)
// JOP

.macro TailCallFunctionPointer fptrRegister
#if IMP_SIGNING_DISCRIMINATOR
	mov	x16, #IMP_SIGNING_DISCRIMINATOR
	braa	\fptrRegister, x16
#else
	braaz	\fptrRegister
#endif
.endmacro

.macro TailCallCachedImp IMP, IMPAddress, SEL, ISA
	// $0 = cached imp, $1 = address of cached imp, $2 = SEL, $3 = isa
	eor	\IMPAddress, \IMPAddress, \SEL	// mix SEL into ptrauth modifier
	eor	\IMPAddress, \IMPAddress, \ISA  // mix isa into ptrauth modifier
.ifndef LTailCallCachedImpIndirectBranch
LTailCallCachedImpIndirectBranch:
.endif
	brab	\IMP, \IMPAddress
.endmacro

.macro TailCallMethodListImp
	// $0 = method list imp, $1 = address of method list imp
	braa	$0, $1
.endmacro

.macro TailCallBlockInvoke
	// $0 = invoke function, $1 = address of invoke function
	braa	$0, $1
.endmacro

.macro AuthAndResignAsIMP
	// $0 = cached imp, $1 = address of cached imp, $2 = SEL, $3 = isa, $4 = temp register
	// note: assumes the imp is not nil
    eor $1, $1, $2          // mix SEL into ptrauth modifier
    eor $1, $1, $3          // mix isa into ptrauth modifier
    autib   $0, $1          // authenticate cached imp
    eor $1, $0, $0, lsl #1  // mix together the two failure bits
    tbz $1, #62, 0f         // if the result is zero, we authenticated
    brk #0xc471             // crash if authentication failed
0:
#ifdef IMP_SIGNING_DISCRIMINATOR
    mov     $4, #IMP_SIGNING_DISCRIMINATOR
    pacia   $0, $4         // resign cached imp as IMP
#else
    paciza  $0              // resign cached imp as IMP
#endif
.endmacro

.macro ExtractISA
	and	$0, $1, #ISA_MASK
#if ISA_SIGNING_AUTH_MODE == ISA_SIGNING_STRIP
	xpacd	$0
#elif ISA_SIGNING_AUTH_MODE == ISA_SIGNING_AUTH
	mov	x10, $2
	movk	x10, #ISA_SIGNING_DISCRIMINATOR, LSL #48
	autda	$0, x10
#endif
.endmacro

.macro AuthISASuper dst, addr_mutable, discriminator
#if ISA_SIGNING_AUTH_MODE == ISA_SIGNING_AUTH
	movk	\addr_mutable, #\discriminator, LSL #48
	autda	\dst, \addr_mutable
#elif ISA_SIGNING_AUTH_MODE == ISA_SIGNING_STRIP
	xpacd	\dst
#endif
.endmacro

.macro SignAsImp fptr, temporary
#if IMP_SIGNING_DISCRIMINATOR
	mov	\temporary, #IMP_SIGNING_DISCRIMINATOR
	pacia	\fptr, \temporary
#else
	paciza	\fptr
#endif
.endmacro

// JOP
#else
// not JOP

.macro TailCallFunctionPointer
	// $0 = function pointer value
	br	$0
.endmacro

.macro TailCallCachedImp
	// $0 = cached imp, $1 = address of cached imp, $2 = SEL, $3 = isa
	eor	$0, $0, $3
.ifndef LTailCallCachedImpIndirectBranch
LTailCallCachedImpIndirectBranch:
.endif
	br	$0
.endmacro

.macro TailCallMethodListImp
	// $0 = method list imp, $1 = address of method list imp
	br	$0
.endmacro

.macro TailCallBlockInvoke
	// $0 = invoke function, $1 = address of invoke function
	br	$0
.endmacro

.macro AuthAndResignAsIMP
	// $0 = cached imp, $1 = address of cached imp, $2 = SEL
	eor	$0, $0, $3
.endmacro

.macro SignAsImp
.endmacro

.macro ExtractISA
	and    $0, $1, #ISA_MASK
.endmacro

// not JOP
#endif

#define TailCallBlockInvoke TailCallMethodListImp


// __arm64__
#endif
