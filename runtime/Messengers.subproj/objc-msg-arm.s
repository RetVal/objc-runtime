/*
 * @APPLE_LICENSE_HEADER_START@
 * 
 * Copyright (c) 1999-2007 Apple Computer, Inc.  All Rights Reserved.
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
 *  objc-msg-arm.s - ARM code to support objc messaging
 *
 ********************************************************************/

#ifdef __arm__
	
#include <arm/arch.h>

#ifdef ARM11
#define MOVE cpy
#define MOVEEQ cpyeq
#define MOVENE cpyne
#else
#define MOVE mov
#define MOVEEQ moveq
#define MOVENE movne
#endif

#ifdef _ARM_ARCH_7
#define THUMB 1
#endif

.syntax unified	
	
#if defined(__DYNAMIC__)
#define MI_EXTERN(var) \
	.non_lazy_symbol_pointer                        ;\
L ## var ## __non_lazy_ptr:                         ;\
	.indirect_symbol var                            ;\
	.long 0
#else
#define MI_EXTERN(var) \
	.globl var
#endif


#if defined(__DYNAMIC__) && defined(THUMB)
#define MI_GET_ADDRESS(reg,var)  \
	ldr     reg, 4f                                 ;\
3:	add	reg, pc                                     ;\
	ldr	reg, [reg]                                  ;\
	b	5f                                          ;\
	.align 2 ;\
4:	.long   L ## var ## __non_lazy_ptr - (3b + 4)	;\
5:
#elif defined(__DYNAMIC__)	
#define MI_GET_ADDRESS(reg,var)  \
	ldr     reg, 4f                                 ;\
3:	ldr     reg, [pc, reg]                          ;\
	b       5f                                      ;\
	.align 2 ;\
4:	.long   L ## var ## __non_lazy_ptr - (3b + 8)   ;\
5:
#else	
#define MI_GET_ADDRESS(reg,var)  \
	ldr     reg, 3f ;\
	b       4f      ;\
	.align 2 ;\
3:	.long var       ;\
4:
#endif


#if defined(__DYNAMIC__)
#define MI_BRANCH_EXTERNAL(var)  \
	MI_GET_ADDRESS(ip, var)                         ;\
	bx      ip
#else
#define MI_BRANCH_EXTERNAL(var)                     \
	b       var
#endif

#if defined(__DYNAMIC__) && defined(THUMB)
#define MI_CALL_EXTERNAL(var)    \
	MI_GET_ADDRESS(ip,var)  ;\
	blx     ip
#elif defined(__DYNAMIC__)
#define MI_CALL_EXTERNAL(var)    \
	MI_GET_ADDRESS(ip,var)  ;\
	MOVE    lr, pc          ;\
	bx      ip
#else
#define MI_CALL_EXTERNAL(var)  \
	bl      var
#endif


MI_EXTERN(__class_lookupMethodAndLoadCache3)
MI_EXTERN(_FwdSel)
MI_EXTERN(___objc_error)
MI_EXTERN(__objc_forward_handler)
MI_EXTERN(__objc_forward_stret_handler)

#if 0
// Special section containing a function pointer that dyld will call
// when it loads new images.
MI_EXTERN(__objc_notify_images)
.text
.align 2
L__objc_notify_images:
	MI_BRANCH_EXTERNAL(__objc_notify_images)

.section __DATA,__image_notify
.long L__objc_notify_images
#endif


# _objc_entryPoints and _objc_exitPoints are used by method dispatch
# caching code to figure out whether any threads are actively 
# in the cache for dispatching.  The labels surround the asm code
# that do cache lookups.  The tables are zero-terminated.
.data
.private_extern _objc_entryPoints
_objc_entryPoints:
	.long   __cache_getImp
	.long   __cache_getMethod
	.long   _objc_msgSend
	.long   _objc_msgSend_noarg
	.long   _objc_msgSend_stret
	.long   _objc_msgSendSuper
	.long   _objc_msgSendSuper_stret
	.long   _objc_msgSendSuper2
	.long   _objc_msgSendSuper2_stret
	.long   0

.data
.private_extern _objc_exitPoints
_objc_exitPoints:
	.long   LGetImpExit
	.long   LGetMethodExit
	.long   LMsgSendExit
	.long   LMsgSendNoArgExit
	.long   LMsgSendStretExit
	.long   LMsgSendSuperExit
	.long   LMsgSendSuperStretExit
	.long   LMsgSendSuper2Exit
	.long   LMsgSendSuper2StretExit
	.long   0


/* objc_super parameter to sendSuper */
.set RECEIVER,         0
.set CLASS,            4

/* Selected field offsets in class structure */
.set ISA,              0
.set SUPERCLASS,       4
.set CACHE,            8

/* Method descriptor */
.set METHOD_NAME,      0
.set METHOD_IMP,       8

/* Cache header */
.set MASK,             0
.set NEGMASK,         -8
.set OCCUPIED,         4
.set BUCKETS,          8     /* variable length array */


#####################################################################
#
# ENTRY		functionName
#
# Assembly directives to begin an exported function.
# We align on cache boundaries for these few functions.
#
# Takes: functionName - name of the exported function
#####################################################################

.macro ENTRY /* name */
	.text
#ifdef THUMB
	.thumb
#endif
	.align 5
	.globl    _$0
#ifdef THUMB
	.thumb_func
#endif
_$0:	
.endmacro

.macro STATIC_ENTRY /*name*/
	.text
#ifdef THUMB
	.thumb
#endif
	.align 5
	.private_extern _$0
#ifdef THUMB
	.thumb_func
#endif
_$0:	
.endmacro
	
	
#####################################################################
#
# END_ENTRY	functionName
#
# Assembly directives to end an exported function.  Just a placeholder,
# a close-parenthesis for ENTRY, until it is needed for something.
#
# Takes: functionName - name of the exported function
#####################################################################

.macro END_ENTRY /* name */
.endmacro


#####################################################################
#
# CacheLookup selectorRegister, classReg, cacheMissLabel
#
# Locate the implementation for a selector in a class method cache.
#
# Takes: 
#	 $0 = register containing selector (a2 or a3 ONLY)
#	 $1 = class whose cache is to be searched
#	 cacheMissLabel = label to branch to iff method is not cached
#
# Kills:
#	a4, $1, r9, ip
#
# On exit: (found) method triplet in $1, imp in ip
#          (not found) jumps to cacheMissLabel
#
#####################################################################

.macro CacheLookup /* selReg, classReg, missLabel */
	
	MOVE	r9, $0, LSR #2          /* index = (sel >> 2) */
	ldr     a4, [$1, #CACHE]        /* cache = class->cache */
	add     a4, a4, #BUCKETS        /* buckets = &cache->buckets */

/* search the cache */
/* a1=receiver, a2 or a3=sel, r9=index, a4=buckets, $1=method */
1:
	ldr     ip, [a4, #NEGMASK]      /* mask = cache->mask */
	and     r9, r9, ip              /* index &= mask           */
	ldr     $1, [a4, r9, LSL #2]    /* method = buckets[index] */
	teq     $1, #0                  /* if (method == NULL)     */
	add     r9, r9, #1              /* index++                 */
	beq     $2                      /*     goto cacheMissLabel */

	ldr     ip, [$1, #METHOD_NAME]  /* load method->method_name        */
	teq     $0, ip                  /* if (method->method_name != sel) */
	bne     1b                      /*     retry                       */

/* cache hit, $1 == method triplet address */
/* Return triplet in $1 and imp in ip      */
	ldr     ip, [$1, #METHOD_IMP]   /* imp = method->method_imp */

.endmacro


/********************************************************************
 * Method _cache_getMethod(Class cls, SEL sel, IMP msgForward_internal_imp)
 *
 * On entry:    a1 = class whose cache is to be searched
 *              a2 = selector to search for
 *              a3 = _objc_msgForward_internal IMP
 *
 * If found, returns method triplet pointer.
 * If not found, returns NULL.
 *
 * NOTE: _cache_getMethod never returns any cache entry whose implementation
 * is _objc_msgForward_internal. It returns NULL instead. This prevents thread-
 * safety and memory management bugs in _class_lookupMethodAndLoadCache. 
 * See _class_lookupMethodAndLoadCache for details.
 *
 * _objc_msgForward_internal is passed as a parameter because it's more 
 * efficient to do the (PIC) lookup once in the caller than repeatedly here.
 ********************************************************************/

	STATIC_ENTRY _cache_getMethod

# search the cache
	CacheLookup a2, a1, LGetMethodMiss

# cache hit, method triplet in a1 and imp in ip
	teq     ip, a3          /* check for _objc_msgForward_internal */
	it	eq
	MOVEEQ  a1, #1          /* return (Method)1 if forward */
	                        /* else return triplet (already in a1) */
	bx	lr
	
LGetMethodMiss:
	MOVE    a1, #0          /* return nil if cache miss */
	bx	lr

LGetMethodExit: 
    END_ENTRY _cache_getMethod


/********************************************************************
 * IMP _cache_getImp(Class cls, SEL sel)
 *
 * On entry:    a1 = class whose cache is to be searched
 *              a2 = selector to search for
 *
 * If found, returns method implementation.
 * If not found, returns NULL.
 ********************************************************************/

	STATIC_ENTRY _cache_getImp

# save registers and load class for CacheLookup

# search the cache
	CacheLookup a2, a1, LGetImpMiss

# cache hit, method triplet in a1 and imp in ip
	MOVE    a1, ip          @ return imp
	bx	lr
	
LGetImpMiss:
	MOVE    a1, #0          @ return nil if cache miss
	bx	lr

LGetImpExit: 
    END_ENTRY _cache_getImp


/********************************************************************
 * id		objc_msgSend(id	self,
 *			SEL	op,
 *			...)
 *
 * On entry: a1 is the message receiver,
 *           a2 is the selector
 ********************************************************************/

	ENTRY objc_msgSend
# check whether receiver is nil
	teq     a1, #0
    beq     LMsgSendNilReceiver
	
# save registers and load receiver's class for CacheLookup
	stmfd   sp!, {a4,v1}
	ldr     v1, [a1, #ISA]

# receiver is non-nil: search the cache
	CacheLookup a2, v1, LMsgSendCacheMiss

# cache hit (imp in ip) and CacheLookup returns with nonstret (eq) set, restore registers and call
	ldmfd   sp!, {a4,v1}
	bx      ip

# cache miss: go search the method lists
LMsgSendCacheMiss:
	ldmfd	sp!, {a4,v1}
	b	_objc_msgSend_uncached

LMsgSendNilReceiver:
    mov     a2, #0
    bx      lr

LMsgSendExit:
	END_ENTRY objc_msgSend


	STATIC_ENTRY objc_msgSend_uncached

# Push stack frame
	stmfd	sp!, {a1-a4,r7,lr}
	add     r7, sp, #16

# Load class and selector
	ldr	a3, [a1, #ISA]		/* class = receiver->isa  */
					/* selector already in a2 */
					/* receiver already in a1 */

# Do the lookup
	MI_CALL_EXTERNAL(__class_lookupMethodAndLoadCache3)
	MOVE    ip, a1

# Prep for forwarding, Pop stack frame and call imp
	teq	v1, v1		/* set nonstret (eq) */
	ldmfd	sp!, {a1-a4,r7,lr}
	bx	ip

/********************************************************************
 * id		objc_msgSend_noarg(id self, SEL op)
 *
 * On entry: a1 is the message receiver,
 *           a2 is the selector
 ********************************************************************/

	ENTRY objc_msgSend_noarg
# check whether receiver is nil
	teq     a1, #0
    beq     LMsgSendNilReceiver
	
# load receiver's class for CacheLookup
	ldr     a3, [a1, #ISA]

# receiver is non-nil: search the cache
	CacheLookup a2, a3, LMsgSendNoArgCacheMiss

# cache hit (imp in ip) and CacheLookup returns with nonstret (eq) set
	bx      ip

# cache miss: go search the method lists
LMsgSendNoArgCacheMiss:
	b	_objc_msgSend_uncached

LMsgSendNoArgExit:
	END_ENTRY objc_msgSend_noarg


/********************************************************************
 * struct_type	objc_msgSend_stret(id	self,
 *				SEL	op,
 *					...);
 *
 * objc_msgSend_stret is the struct-return form of msgSend.
 * The ABI calls for a1 to be used as the address of the structure
 * being returned, with the parameters in the succeeding registers.
 *
 * On entry: a1 is the address where the structure is returned,
 *           a2 is the message receiver,
 *           a3 is the selector
 ********************************************************************/

	ENTRY objc_msgSend_stret
# check whether receiver is nil
	teq     a2, #0
	it	eq
	bxeq    lr

# save registers and load receiver's class for CacheLookup
	stmfd   sp!, {a4,v1}
	ldr     v1, [a2, #ISA]

# receiver is non-nil: search the cache
	CacheLookup a3, v1, LMsgSendStretCacheMiss

# cache hit (imp in ip) - prep for forwarding, restore registers and call
	tst	v1, v1		/* set stret (ne); v1 is nonzero (triplet) */
	ldmfd   sp!, {a4,v1}
	bx      ip

# cache miss: go search the method lists
LMsgSendStretCacheMiss:
	ldmfd	sp!, {a4,v1}
	b	_objc_msgSend_stret_uncached
	
LMsgSendStretExit:
	END_ENTRY objc_msgSend_stret


	STATIC_ENTRY objc_msgSend_stret_uncached

# Push stack frame
	stmfd	sp!, {a1-a4,r7,lr}
	add     r7, sp, #16

# Load class and selector
	MOVE	a1, a2			/* receiver */
	MOVE	a2, a3			/* selector */
	ldr	a3, [a1, #ISA]		/* class = receiver->isa */

# Do the lookup
	MI_CALL_EXTERNAL(__class_lookupMethodAndLoadCache3)
	MOVE    ip, a1

# Prep for forwarding, pop stack frame and call imp
	tst	a1, a1		/* set stret (ne); a1 is nonzero (imp) */
	
	ldmfd	sp!, {a1-a4,r7,lr}
	bx	ip


/********************************************************************
 * id	objc_msgSendSuper(struct objc_super	*super,
 *			SEL			op,
 *						...)
 *
 * struct objc_super {
 *	id	receiver
 *	Class	class
 * }
 ********************************************************************/

	ENTRY objc_msgSendSuper

# save registers and load super class for CacheLookup
	stmfd   sp!, {a4,v1}
	ldr     v1, [a1, #CLASS]

# search the cache
	CacheLookup a2, v1, LMsgSendSuperCacheMiss

# cache hit (imp in ip) and CacheLookup returns with nonstret (eq) set, restore registers and call
	ldmfd   sp!, {a4,v1}
	ldr     a1, [a1, #RECEIVER]    @ fetch real receiver
	bx      ip

# cache miss: go search the method lists
LMsgSendSuperCacheMiss:
	ldmfd   sp!, {a4,v1}
	b	_objc_msgSendSuper_uncached

LMsgSendSuperExit:
	END_ENTRY objc_msgSendSuper


	STATIC_ENTRY objc_msgSendSuper_uncached

# Push stack frame
	stmfd	sp!, {a1-a4,r7,lr}
	add     r7, sp, #16

# Load class and selector
	ldr	a3, [a1, #CLASS]	/* class = super->class  */
					/* selector already in a2 */
	ldr     a1, [a1, #RECEIVER]	/* receiver = super->receiver */

# Do the lookup
	MI_CALL_EXTERNAL(__class_lookupMethodAndLoadCache3)
	MOVE    ip, a1

# Prep for forwarding, pop stack frame and call imp
	teq	v1, v1			/* set nonstret (eq) */
	ldmfd	sp!, {a1-a4,r7,lr}
	ldr     a1, [a1, #RECEIVER]    @ fetch real receiver
	bx	ip


/********************************************************************
 * objc_msgSendSuper2
 ********************************************************************/
	
	ENTRY objc_msgSendSuper2

# save registers and load super class for CacheLookup
	stmfd   sp!, {a4,v1}
	ldr     v1, [a1, #CLASS]
	ldr     v1, [v1, #SUPERCLASS]

# search the cache
	CacheLookup a2, v1, LMsgSendSuper2CacheMiss

# cache hit (imp in ip) and CacheLookup returns with nonstret (eq) set, restore registers and call
	ldmfd   sp!, {a4,v1}
	ldr     a1, [a1, #RECEIVER]    @ fetch real receiver
	bx      ip

# cache miss: go search the method lists
LMsgSendSuper2CacheMiss:
	ldmfd   sp!, {a4,v1}
	b	_objc_msgSendSuper2_uncached

LMsgSendSuper2Exit:
	END_ENTRY objc_msgSendSuper2


	STATIC_ENTRY objc_msgSendSuper2_uncached

# Push stack frame
	stmfd	sp!, {a1-a4,r7,lr}
	add     r7, sp, #16

# Load class and selector
	ldr	a3, [a1, #CLASS]	/* class = super->class  */
	ldr     a3, [a3, #SUPERCLASS]   /* class = class->superclass */
					/* selector already in a2 */
	ldr     a1, [a1, #RECEIVER]	/* receiver = super->receiver */

# Do the lookup
	MI_CALL_EXTERNAL(__class_lookupMethodAndLoadCache3)
	MOVE    ip, a1

# Prep for forwarding, pop stack frame and call imp
	teq	v1, v1			/* set nonstret (eq) */
	ldmfd	sp!, {a1-a4,r7,lr}
	ldr     a1, [a1, #RECEIVER]    @ fetch real receiver
	bx	ip


/********************************************************************
 * struct_type	objc_msgSendSuper_stret(objc_super	*super,
 *					SEL		op,
 *							...)
 *
 * struct objc_super {
 *	id	receiver
 *	Class	class
 * }
 *
 *
 * objc_msgSendSuper_stret is the struct-return form of msgSendSuper.
 * The ABI calls for a1 to be used as the address of the structure
 * being returned, with the parameters in the succeeding registers.
 *
 * On entry:	a1 is the address to which to copy the returned structure,
 *		a2 is the address of the objc_super structure,
 *		a3 is the selector
 ********************************************************************/

	ENTRY objc_msgSendSuper_stret

# save registers and load super class for CacheLookup
	stmfd   sp!, {a4,v1}
	ldr     v1, [a2, #CLASS]

# search the cache
	CacheLookup a3, v1, LMsgSendSuperStretCacheMiss

# cache hit (imp in ip) - prep for forwarding, restore registers and call
	tst     v1, v1		/* set stret (ne); v1 is nonzero (triplet) */
	ldmfd   sp!, {a4,v1}
	ldr     a2, [a2, #RECEIVER]      @ fetch real receiver
	bx    	ip

# cache miss: go search the method lists
LMsgSendSuperStretCacheMiss:
	ldmfd   sp!, {a4,v1}
	b	_objc_msgSendSuper_stret_uncached

LMsgSendSuperStretExit:
	END_ENTRY objc_msgSendSuper_stret


	STATIC_ENTRY objc_msgSendSuper_stret_uncached

# Push stack frame
	stmfd	sp!, {a1-a4,r7,lr}
	add     r7, sp, #16

# Load class and selector
	MOVE	a1, a2			/* struct super */
	MOVE	a2, a3			/* selector */
	ldr	a3, [a1, #CLASS]	/* class = super->class  */
	ldr     a1, [a1, #RECEIVER]	/* receiver = super->receiver */

# Do the lookup
	MI_CALL_EXTERNAL(__class_lookupMethodAndLoadCache3)
	MOVE    ip, a1

# Prep for forwarding, pop stack frame and call imp
	tst     v1, v1		/* set stret (ne); v1 is nonzero (triplet) */
	
	ldmfd	sp!, {a1-a4,r7,lr}
	ldr     a2, [a2, #RECEIVER]	@ fetch real receiver
	bx      ip

	
/********************************************************************
 * id objc_msgSendSuper2_stret
 ********************************************************************/

	ENTRY objc_msgSendSuper2_stret

# save registers and load super class for CacheLookup
	stmfd   sp!, {a4,v1}
	ldr     v1, [a2, #CLASS]
	ldr     v1, [v1, #SUPERCLASS]

# search the cache
	CacheLookup a3, v1, LMsgSendSuper2StretCacheMiss

# cache hit (imp in ip) - prep for forwarding, restore registers and call
	tst     v1, v1		/* set stret (ne); v1 is nonzero (triplet) */
	ldmfd   sp!, {a4,v1}
	ldr     a2, [a2, #RECEIVER]      @ fetch real receiver
	bx    	ip

# cache miss: go search the method lists
LMsgSendSuper2StretCacheMiss:
	ldmfd   sp!, {a4,v1}
	b	_objc_msgSendSuper2_stret_uncached

LMsgSendSuper2StretExit:
	END_ENTRY objc_msgSendSuper2_stret


	STATIC_ENTRY objc_msgSendSuper2_stret_uncached

# Push stack frame
	stmfd	sp!, {a1-a4,r7,lr}
	add     r7, sp, #16

# Load class and selector
	MOVE	a1, a2			/* struct super */
	MOVE	a2, a3			/* selector */
	ldr	a3, [a1, #CLASS]	/* class = super->class  */
	ldr     a3, [a3, #SUPERCLASS]   /* class = class->superclass */
	ldr     a1, [a1, #RECEIVER]	/* receiver = super->receiver */

# Do the lookup
	MI_CALL_EXTERNAL(__class_lookupMethodAndLoadCache3)
	MOVE    ip, a1

# Prep for forwarding, pop stack frame and call imp
	tst     v1, v1		/* set stret (ne); v1 is nonzero (triplet) */
	
	ldmfd	sp!, {a1-a4,r7,lr}
	ldr     a2, [a2, #RECEIVER]	@ fetch real receiver
	bx      ip


/********************************************************************
 *
 * id		_objc_msgForward(id	self,
 *				SEL	sel,
 *					...);
 * struct_type	_objc_msgForward_stret	(id	self,
 *					SEL	sel,
 *					...);
 *
 * Both _objc_msgForward and _objc_msgForward_stret 
 * send the message to a method having the signature:
 *
 *      - forward:(SEL)sel :(marg_list)args;
 * 
 * The marg_list's layout is:
 * d0   <-- args
 * d1
 * d2   |  increasing address
 * d3   v
 * d4
 * d5
 * d6
 * d7
 * a1
 * a2
 * a3
 * a4
 * stack args...
 * 
 * typedef struct objc_sendv_margs {
 *	int		a[4];
 *	int		stackArgs[...];
 * };
 *
 ********************************************************************/

.data
.private_extern _FwdSel
_FwdSel:
	.long 0

.private_extern __objc_forward_handler
__objc_forward_handler:
	.long 0

.private_extern __objc_forward_stret_handler
__objc_forward_stret_handler:
	.long 0


	STATIC_ENTRY   _objc_msgForward_internal
	// Method cache version

	// THIS IS NOT A CALLABLE C FUNCTION
	// Out-of-band condition register is NE for stret, EQ otherwise.

	bne	__objc_msgForward_stret
	b	__objc_msgForward
	
	END_ENTRY _objc_msgForward_internal
	

	ENTRY   _objc_msgForward
	// Non-stret version

# check for user-installed forwarding handler
	MI_GET_ADDRESS(ip, __objc_forward_handler)
	ldr	ip, [ip]
	teq	ip, #0
	it	ne
	bxne	ip

# build marg_list
	stmfd   sp!, {a1-a4}             @ push args to marg_list

# build forward::'s parameter list  (self, forward::, original sel, marg_list)
	# a1 already is self
	MOVE    a3, a2                   @ original sel
	MI_GET_ADDRESS(a2, _FwdSel)  @ "forward::"
	ldr	a2, [a2]
	MOVE    a4, sp                   @ marg_list

# check for forwarding of forward:: itself
	teq     a2, a3
	beq     LMsgForwardError         @ original sel == forward:: - give up

# push stack frame
	str     lr, [sp, #-(2*4)]!       @ save lr and align stack

# send it
	bl      _objc_msgSend

# pop stack frame and return
	ldr	lr, [sp]
	add	sp, sp, #(4 + 4 + 4*4) 		@ skip lr, pad, a1..a4
	bx	lr

	END_ENTRY _objc_msgForward


	ENTRY   _objc_msgForward_stret
	// Struct-return version

# check for user-installed forwarding handler
	MI_GET_ADDRESS(ip, __objc_forward_stret_handler)
	ldr	ip, [ip]
	teq	ip, #0
	it	ne
	bxne	ip

# build marg_list
	stmfd   sp!, {a1-a4}             @ push args to marg_list

# build forward::'s parameter list  (self, forward::, original sel, marg_list)
	MOVE    a1, a2                   @ self
	MI_GET_ADDRESS(a2, _FwdSel) @ "forward::"
	ldr	a2, [a2]
	# a3 is already original sel
	MOVE    a4, sp                   @ marg_list

# check for forwarding of forward:: itself
	teq     a2, a3
	beq     LMsgForwardError         @ original sel == forward:: - give up

# push stack frame
	str     lr, [sp, #-(2*4)]!       @ save lr and align stack

# send it
	bl      _objc_msgSend

# pop stack frame and return
	ldr	lr, [sp]
	add	sp, sp, #(4 + 4 + 4*4) 		@ skip lr, pad, a1..a4
	bx	lr
	
	END_ENTRY _objc_msgForward_stret

LMsgForwardError:
	# currently a1=self, a2=forward::, a3 = original sel, a4 = marg_list
	# call __objc_error(self, format, original sel)
	add     a2, pc, #4     @ pc bias is 8 bytes
	MI_CALL_EXTERNAL(___objc_error)
	.ascii "Does not recognize selector %s\0"


	ENTRY objc_msgSend_debug
	b	_objc_msgSend
	END_ENTRY objc_msgSend_debug

	ENTRY objc_msgSendSuper2_debug
	b	_objc_msgSendSuper2
	END_ENTRY objc_msgSendSuper2_debug

	ENTRY objc_msgSend_stret_debug
	b	_objc_msgSend_stret
	END_ENTRY objc_msgSend_stret_debug

	ENTRY objc_msgSendSuper2_stret_debug
	b	_objc_msgSendSuper2_stret
	END_ENTRY objc_msgSendSuper2_stret_debug


	ENTRY method_invoke
	# a2 is method triplet instead of SEL
	ldr	ip, [a2, #METHOD_IMP]
	ldr	a2, [a2, #METHOD_NAME]
	bx	ip
	END_ENTRY method_invoke


	ENTRY method_invoke_stret
	# a3 is method triplet instead of SEL
	ldr	ip, [a3, #METHOD_IMP]
	ldr	a3, [a3, #METHOD_NAME]
	bx	ip
	END_ENTRY method_invoke_stret


	STATIC_ENTRY _objc_ignored_method

	# self is already in a0
	bx	lr

	END_ENTRY _objc_ignored_method
	
#endif
