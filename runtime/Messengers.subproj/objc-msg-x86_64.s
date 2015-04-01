/*
 * Copyright (c) 1999-2007 Apple Inc.  All Rights Reserved.
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

#ifdef __x86_64__

/********************************************************************
 ********************************************************************
 **
 **  objc-msg-x86_64.s - x86-64 code to support objc messaging.
 **
 ********************************************************************
 ********************************************************************/

#define __OBJC2__ 1
	
/********************************************************************
* Data used by the ObjC runtime.
*
********************************************************************/

.data
// Substitute receiver for messages sent to nil (usually also nil)
// id _objc_nilReceiver
.align 4
.private_extern __objc_nilReceiver
__objc_nilReceiver:
	.quad   0

// _objc_entryPoints and _objc_exitPoints are used by objc
// to get the critical regions for which method caches 
// cannot be garbage collected.

.private_extern	_objc_entryPoints
_objc_entryPoints:
	.quad	__cache_getImp
	.quad	__cache_getMethod
	.quad	_objc_msgSend
	.quad	_objc_msgSend_fpret
	.quad	_objc_msgSend_fp2ret
	.quad	_objc_msgSend_stret
	.quad	_objc_msgSendSuper
	.quad	_objc_msgSendSuper_stret
	.quad	_objc_msgSendSuper2
	.quad	_objc_msgSendSuper2_stret
	.quad	0

.private_extern	_objc_exitPoints
_objc_exitPoints:
	.quad	LExit__cache_getImp
	.quad	LExit__cache_getMethod
	.quad	LExit_objc_msgSend
	.quad	LExit_objc_msgSend_fpret
	.quad	LExit_objc_msgSend_fp2ret
	.quad	LExit_objc_msgSend_stret
	.quad	LExit_objc_msgSendSuper
	.quad	LExit_objc_msgSendSuper_stret
	.quad	LExit_objc_msgSendSuper2
	.quad	LExit_objc_msgSendSuper2_stret
	.quad	0


/********************************************************************
 * Recommended multi-byte NOP instructions
 * (Intel 64 and IA-32 Architectures Software Developer's Manual Volume 2B)
 ********************************************************************/
#define nop1 .byte 0x90
#define nop2 .byte 0x66,0x90
#define nop3 .byte 0x0F,0x1F,0x00
#define nop4 .byte 0x0F,0x1F,0x40,0x00
#define nop5 .byte 0x0F,0x1F,0x44,0x00,0x00
#define nop6 .byte 0x66,0x0F,0x1F,0x44,0x00,0x00
#define nop7 .byte 0x0F,0x1F,0x80,0x00,0x00,0x00,0x00
#define nop8 .byte 0x0F,0x1F,0x84,0x00,0x00,0x00,0x00,0x00
#define nop9 .byte 0x66,0x0F,0x1F,0x84,0x00,0x00,0x00,0x00,0x00

	
/********************************************************************
 * Names for parameter registers.
 ********************************************************************/

#define a1  rdi
#define a1d edi
#define a1b dil
#define a2  rsi
#define a2d esi
#define a2b sil
#define a3  rdx
#define a3d edx
#define a4  rcx
#define a4d ecx
#define a5  r8
#define a5d r8d
#define a6  r9
#define a6d r9d


/********************************************************************
 * Names for relative labels
 * DO NOT USE THESE LABELS ELSEWHERE
 * Reserved labels: 5: 6: 7: 8: 9:
 ********************************************************************/
#define LCacheMiss 	5
#define LCacheMiss_f 	5f
#define LCacheMiss_b 	5b
#define LNilTestDone 	6
#define LNilTestDone_f 	6f
#define LNilTestDone_b 	6b
#define LNilTestSlow 	7
#define LNilTestSlow_f 	7f
#define LNilTestSlow_b 	7b
#define LGetIsaDone 	8
#define LGetIsaDone_f 	8f
#define LGetIsaDone_b 	8b
#define LGetIsaSlow 	9
#define LGetIsaSlow_f 	9f
#define LGetIsaSlow_b 	9b

/********************************************************************
 * Macro parameters
 ********************************************************************/

#define STRET -1
#define NORMAL 0
#define FPRET 1
#define FP2RET 2


/********************************************************************
 *
 * Structure definitions.
 *
 ********************************************************************/

// objc_super parameter to sendSuper
#define receiver 	0
#define class 		8

// Selected field offsets in class structure
// #define isa		0    USE GetIsa INSTEAD
#define cache 		16

// Method descriptor
#define method_name 	0
#define method_imp 	16

// Cache header
#define mask		0
#define occupied	8
#define buckets		16

// typedef struct {
//	uint128_t floatingPointArgs[8];	// xmm0..xmm7
//	long linkageArea[4];		// r10, rax, ebp, ret
//	long registerArgs[6];		// a1..a6
//	long stackArgs[0];		// variable-size
// } *marg_list;
#define FP_AREA 0
#define LINK_AREA (FP_AREA+8*16)
#define REG_AREA (LINK_AREA+4*8)
#define STACK_AREA (REG_AREA+6*8)


//////////////////////////////////////////////////////////////////////
//
// ENTRY		functionName
//
// Assembly directives to begin an exported function.
//
// Takes: functionName - name of the exported function
//////////////////////////////////////////////////////////////////////

.macro ENTRY
	.text
	.globl	$0
	.align	6, 0x90
$0:
.endmacro

.macro STATIC_ENTRY
	.text
	.private_extern	$0
	.align	2, 0x90
$0:
.endmacro

//////////////////////////////////////////////////////////////////////
//
// END_ENTRY	functionName
//
// Assembly directives to end an exported function.  Just a placeholder,
// a close-parenthesis for ENTRY, until it is needed for something.
//
// Takes: functionName - name of the exported function
//////////////////////////////////////////////////////////////////////

.macro END_ENTRY
LExit$0:	
.endmacro


/* DWARF support
   These macros work for objc_msgSend variants and others that call
   CacheLookup/MethodTableLookup or SaveRegisters/RestoreRegisters
   without otherwise building a frame or clobbering callee-save registers

   The macros build appropriate FDEs and tie them to the CIE.
*/

#define DW_CFA_offset 0x80
#define DW_CFA_restore 0xc0
#define DW_CFA_advance_loc4 0x4
#define DW_CFA_same_value 0x8
#define DW_CFA_def_cfa 0xc
#define DW_CFA_def_cfa_register 0xd
#define DW_CFA_def_cfa_offset 0xe
#define DW_CFA_offset_extended_sf 0x11
#define DW_CFA_def_cfa_offset_sf 0x13
#define DW_rax 0
#define DW_rdx 1
#define DW_rcx 2
#define DW_rsi 4
#define DW_rdi 5
#define DW_rbp 6
#define DW_rsp 7
#define DW_r8  8
#define DW_r9  9
#define DW_r10 10
#define DW_ra 16
#define DW_xmm0 17
#define DW_xmm1 18
#define DW_xmm2 19
#define DW_xmm3 20
#define DW_xmm4 21
#define DW_xmm5 22
#define DW_xmm6 23
#define DW_xmm7 24
#define DW_a1  DW_rdi
#define DW_a2  DW_rsi
#define DW_a3  DW_rdx
#define DW_a4  DW_rcx
#define DW_a5  DW_r8
#define DW_a6  DW_r9

// CIE
// 8-byte data multiplier
// 1-byte insn multiplier
// PC-relative everything
// No prologue
	
	.section __TEXT,__eh_frame,coalesced,no_toc+strip_static_syms+live_support
CIE:
	.set	L$set$0,LECIE1-LSCIE1
	.long	L$set$0	# Length of Common Information Entry
LSCIE1:
	.long	0	# CIE Identifier Tag
	.byte	0x3	# CIE Version
	.ascii	"zPR\0"	# CIE Augmentation: size + personality + FDE encoding
	.byte	0x1	# uleb128 0x1; CIE Code Alignment Factor
	.byte	0x78	# sleb128 -0x8; CIE Data Alignment Factor
	.byte	0x10	# CIE RA Column
	.byte	0x6	# uleb128 0x1; Augmentation size
	// Personality augmentation
	.byte	0x9b
	.long	___objc_personality_v0+4@GOTPCREL
	// FDE-encoding augmentation
	.byte	0x10
	// Prefix instructions
	// CFA is %rsp+8
	.byte	DW_CFA_def_cfa
	.byte	DW_rsp
	.byte	8
	// RA is at 0(%rsp) aka 1*-8(CFA)
	.byte	DW_CFA_offset | DW_ra
	.byte	1
	
	.align 3
LECIE1:


.macro EMIT_FDE

	.section __TEXT,__eh_frame,coalesced,no_toc+strip_static_syms+live_support
	
// FDE header
.globl $0.eh
$0.eh:
LSFDE$0:
	.set 	LLENFDE$0, LEFDE$0-LASFDE$0
	.long 	LLENFDE$0		# FDE Length
LASFDE$0:
	.long 	LASFDE$0-CIE		# FDE CIE offset
	.quad	L_dw_start_$0-.		# FDE address start
	.quad	L_dw_len_$0		# FDE address range
	.byte	0x0			# uleb128 0x0; Augmentation size

	// DW_START: set by CIE

.if $1 == 1
	// CacheLookup 

	// push
	.byte 	DW_CFA_advance_loc4
	.long	L_dw_push_$0 - L_dw_start_$0
	.byte	DW_CFA_def_cfa_offset	// CFA = rsp+16
	.byte	16
	
	// pop
	.byte 	DW_CFA_advance_loc4
	.long	L_dw_pop_$0 - L_dw_push_$0
	.byte	DW_CFA_def_cfa_offset	// CFA = rsp+8
	.byte	8

	// cache miss: push is back in effect
	.byte 	DW_CFA_advance_loc4
	.long	L_dw_miss_$0 - L_dw_pop_$0
	.byte	DW_CFA_def_cfa_offset	// CFA = rsp+16
	.byte	16
	
	// pop during cache miss
	.byte 	DW_CFA_advance_loc4
	.long	L_dw_miss_pop_$0 - L_dw_miss_$0
	.byte	DW_CFA_def_cfa_offset	// CFA = rsp+8
	.byte	8

.endif

.if $2 == 1
	// Save/RestoreRegisters or MethodTableLookup

	// enter
	.byte 	DW_CFA_advance_loc4
.if $1 == 1
	.long	L_dw_enter_$0 - L_dw_miss_pop_$0
.else
	.long	L_dw_enter_$0 - L_dw_start_$0
.endif
	.byte   DW_CFA_def_cfa_offset
	.byte   16
	.byte	DW_CFA_offset | DW_rbp	// rbp => 2*-8(CFA)
	.byte	2
	.byte	DW_CFA_def_cfa_register	// CFA = rbp+16 (offset unchanged)
	.byte	DW_rbp
	
	// leave
	.byte 	DW_CFA_advance_loc4
	.long	L_dw_leave_$0 - L_dw_enter_$0

	.byte 	DW_CFA_same_value	// rbp = original value
	.byte	DW_rbp
	.byte	DW_CFA_def_cfa		// CFA = rsp+8
	.byte	DW_rsp
	.byte	8

.endif

	.align 3
LEFDE$0:
	.text
	
.endmacro


// Start of function
.macro DW_START
L_dw_start_$0:
.endmacro

// After `push` in CacheLookup
.macro DW_PUSH
L_dw_push_$0:	
.endmacro

// After `pop` in CacheLookup
.macro DW_POP
L_dw_pop_$0:
.endmacro

// After cache miss label
.macro DW_MISS
L_dw_miss_$0:	
.endmacro

// After pop in MethodTableLookup
.macro DW_MISS_POP
L_dw_miss_pop_$0:	
.endmacro
	
// After `enter` in SaveRegisters
.macro DW_ENTER
L_dw_enter_$0:	
.endmacro

// After `leave` in RestoreRegisters
.macro DW_LEAVE
L_dw_leave_$0:
.endmacro
	
// End of function
// $1 == 1 iff you called CacheLookup
// $2 == 1 iff you called MethodTableLookup or Save/RestoreRegsters
.macro DW_END
	.set 	L_dw_len_$0, . - L_dw_start_$0
	EMIT_FDE $0, $1, $2
.endmacro


/////////////////////////////////////////////////////////////////////
//
// SaveRegisters caller
//
// Pushes a stack frame and saves all registers that might contain
// parameter values.
//
// On entry:	%0 = caller's symbol name for DWARF
//		stack = ret
//
// On exit: 
//		%rsp is 16-byte aligned
//	
/////////////////////////////////////////////////////////////////////

.macro SaveRegisters
	// These instructions must match the DWARF data in EMIT_FDE.
	
	enter	$$0x80+8, $$0		// +8 for alignment
	DW_ENTER $0

	movdqa	%xmm0, -0x80(%rbp)
	push	%rax			// might be xmm parameter count
	movdqa	%xmm1, -0x70(%rbp)
	push	%a1
	movdqa	%xmm2, -0x60(%rbp)
	push	%a2
	movdqa	%xmm3, -0x50(%rbp)
	push	%a3
	movdqa	%xmm4, -0x40(%rbp)
	push	%a4
	movdqa	%xmm5, -0x30(%rbp)
	push	%a5
	movdqa	%xmm6, -0x20(%rbp)
	push	%a6
	movdqa	%xmm7, -0x10(%rbp)
	
	// These instructions must match the DWARF data in EMIT_FDE.
.endmacro

/////////////////////////////////////////////////////////////////////
//
// RestoreRegisters
//
// Pops a stack frame pushed by SaveRegisters
//
// On entry:	$0 = caller's symbol name for DWARF
//		%rbp unchanged since SaveRegisters
//
// On exit: 
//		stack = ret
//	
/////////////////////////////////////////////////////////////////////

.macro RestoreRegisters
	// These instructions must match the DWARF data in EMIT_FDE.

	movdqa	-0x80(%rbp), %xmm0
	pop	%a6
	movdqa	-0x70(%rbp), %xmm1
	pop	%a5
	movdqa	-0x60(%rbp), %xmm2
	pop	%a4
	movdqa	-0x50(%rbp), %xmm3
	pop	%a3
	movdqa	-0x40(%rbp), %xmm4
	pop	%a2
	movdqa	-0x30(%rbp), %xmm5
	pop	%a1
	movdqa	-0x20(%rbp), %xmm6
	pop	%rax
	movdqa	-0x10(%rbp), %xmm7
	
	leave
	DW_LEAVE $0

	// These instructions must match the DWARF data in EMIT_FDE.
.endmacro


/////////////////////////////////////////////////////////////////////
//
//
// CacheLookup	return-type, caller
//
// Locate the implementation for a selector in a class method cache.
//
// Takes: 
//	  $0 = NORMAL, FPRET, FP2RET, STRET
//	  $1 = caller's symbol name for DWARF
//	  a2 or a3 (STRET) = selector
//	  %r11 = class whose cache is to be searched
//
// On exit: (found) method in %r11, stack unchanged, eq/ne set for forwarding
//	    (not found) jumps to LCacheMiss, %rax on stack
//
/////////////////////////////////////////////////////////////////////

.macro	CacheLookup

	push	%rax
	DW_PUSH $1
	
	movq	cache(%r11), %r10	// cache = class->cache
.if $0 != STRET
	mov	%a2d, %eax		// index = sel
.else
	mov	%a3d, %eax		// index = sel
.endif
	
// search the receiver's cache
// r11 = method (soon)
// eax = index
// r10 = cache
// a2 or a3 = sel
1:
	andl	mask(%r10), %eax		// index &= mask
	movq	buckets(%r10, %rax, 8), %r11	// method = cache->buckets[index]
	incl	%eax				// index++
	testq	%r11, %r11			// if (method == NULL)
	je	LCacheMiss_f			//   goto cacheMissLabel
.if $0 != STRET
	cmpq	method_name(%r11), %a2		// if (method_name != sel)
.else
	cmpq	method_name(%r11), %a3		// if (method_name != sel)
.endif
	jne	1b				//   goto loop

	// cache hit, r11 = method triplet
	// restore saved registers
	pop	%rax
	DW_POP	$1

.if $0 != STRET
	// eq (non-stret) flag already set above
.else
	// set ne (stret) for forwarding; r11 != 0
	test	%r11, %r11
.endif

.endmacro


/////////////////////////////////////////////////////////////////////
//
// MethodTableLookup classRegister, selectorRegister, caller
//
// Takes:	$0 = class to search (a1 or a2 or r10 ONLY)
//		$1 = selector to search for (a2 or a3 ONLY)
//		$2 = caller's symbol name for DWARF
// 		r11 = class to search
//
// Stack: ret, rax (pushed by CacheLookup)
//
// On exit: pops registers pushed by CacheLookup
//	  imp in %r11
//
/////////////////////////////////////////////////////////////////////
.macro MethodTableLookup
	
	pop	%rax	// saved by CacheLookup
	DW_MISS_POP $2
	
	SaveRegisters $2

	// _class_lookupMethodAndLoadCache3(receiver, selector, class)

	movq	$0, %a1
	movq	$1, %a2
	movq	%r11, %a3
	call	__class_lookupMethodAndLoadCache3

	// IMP is now in %rax
	movq	%rax, %r11

	RestoreRegisters $2

.endmacro

/////////////////////////////////////////////////////////////////////
//
// GetIsa return-type
// GetIsaFast return-type
// GetIsaSupport return-type
//
// Sets r11 = obj->isa. Consults the tagged isa table if necessary.
//
// Takes:	$0 = NORMAL or FPRET or FP2RET or STRET
//		a1 or a2 (STRET) = receiver
//
// On exit: 	r11 = receiver->isa
//		r10 is clobbered
//
/////////////////////////////////////////////////////////////////////
	
.macro GetIsa

.if $0 != STRET
	testb	$$1, %a1b
	jnz	1f
	movq	(%a1), %r11
	jmp	2f
1:	movl	%a1d, %r10d
.else
	testb	$$1, %a2b
	jnz	1f
	movq	(%a2), %r11
	jmp	2f
1:	movl	%a2d, %r10d
.endif
	andl	$$0xF, %r10d
	leaq	__objc_tagged_isa_table(%rip), %r11
	movq	(%r11, %r10, 8), %r11	// read isa from table
2:
.endmacro

.macro GetIsaFast
.if $0 != STRET
	testb	$$1, %a1b
	.byte	0x2e	// harmless branch hint prefix to align IFETCH blocks
	jnz	LGetIsaSlow_f
	movq	(%a1), %r11
.else
	testb	$$1, %a2b
	.byte	0x2e	// harmless branch hint prefix to align IFETCH blocks
	jnz	LGetIsaSlow_f
	movq	(%a2), %r11
.endif
LGetIsaDone:	
.endmacro

.macro GetIsaSupport
LGetIsaSlow:
	leaq	__objc_tagged_isa_table(%rip), %r11
.if $0 != STRET
	movl	%a1d, %r10d
.else
	movl	%a2d, %r10d
.endif
	andl	$$0xF, %r10d
	movq	(%r11, %r10, 8), %r11	// read isa from table
	jmp	LGetIsaDone_b
.endmacro
	
/////////////////////////////////////////////////////////////////////
//
// NilTest return-type
//
// Takes:	$0 = NORMAL or FPRET or FP2RET or STRET
//		%a1 or %a2 (STRET) = receiver
//
// On exit: 	Loads non-nil receiver in %a1 or %a2 (STRET), or returns zero.
//
// NilTestSupport return-type
//
// Takes:	$0 = NORMAL or FPRET or FP2RET or STRET
//		%a1 or %a2 (STRET) = receiver
//
// On exit: 	Loads non-nil receiver in %a1 or %a2 (STRET), or returns zero.
//
/////////////////////////////////////////////////////////////////////

.macro NilTest
.if $0 != STRET
	testq	%a1, %a1
.else
	testq	%a2, %a2
.endif
	jz	LNilTestSlow_f
LNilTestDone:
.endmacro

.macro NilTestSupport
	.align 3
LNilTestSlow:
.if $0 != STRET
	movq	__objc_nilReceiver(%rip), %a1
	testq	%a1, %a1	// if (receiver != nil)
.else
	movq	__objc_nilReceiver(%rip), %a2
	testq	%a2, %a2	// if (receiver != nil)
.endif
	jne	LNilTestDone_b	//   send to new receiver

.if $0 == FPRET
	fldz
.elseif $0 == FP2RET
	fldz
	fldz
.endif
.if $0 != STRET
	xorl	%eax, %eax
	xorl	%edx, %edx
	xorps	%xmm0, %xmm0
	xorps	%xmm1, %xmm1
.endif
	ret
.endmacro
	

/********************************************************************
 * Method _cache_getMethod(Class cls, SEL sel, IMP msgForward_internal_imp)
 *
 * On entry:	a1 = class whose cache is to be searched
 *		a2 = selector to search for
 *		a3 = _objc_msgForward_internal IMP
 *
 * If found, returns method triplet pointer.
 * If not found, returns NULL.
 *
 * NOTE: _cache_getMethod never returns any cache entry whose implementation
 * is _objc_msgForward_internal. It returns 1 instead. This prevents thread-
 * thread-safety and memory management bugs in _class_lookupMethodAndLoadCache.
 * See _class_lookupMethodAndLoadCache for details.
 *
 * _objc_msgForward_internal is passed as a parameter because it's more 
 * efficient to do the (PIC) lookup once in the caller than repeatedly here.
 ********************************************************************/
		
	STATIC_ENTRY __cache_getMethod
	DW_START __cache_getMethod

// do lookup
	movq	%a1, %r11		// move class to r11 for CacheLookup
	CacheLookup NORMAL, __cache_getMethod

// cache hit, method triplet in %r11
	cmpq	method_imp(%r11), %a3	// if (imp==_objc_msgForward_internal)
	je	  1f			//	 return (Method)1
	movq	%r11, %rax		// return method triplet address
	ret
1:	movl	$1, %eax
	ret

LCacheMiss:
// cache miss, return nil
	DW_MISS __cache_getMethod
	pop	%rax		// pushed by CacheLookup
	DW_MISS_POP __cache_getMethod
	xorl	%eax, %eax
	ret

LGetMethodExit:
	DW_END		__cache_getMethod, 1, 0
	END_ENTRY 	__cache_getMethod


/********************************************************************
 * IMP _cache_getImp(Class cls, SEL sel)
 *
 * On entry:	a1 = class whose cache is to be searched
 *		a2 = selector to search for
 *
 * If found, returns method implementation.
 * If not found, returns NULL.
 ********************************************************************/

	STATIC_ENTRY __cache_getImp
	DW_START __cache_getImp

// do lookup
	movq	%a1, %r11		// move class to r11 for CacheLookup
	CacheLookup NORMAL, __cache_getImp

// cache hit, method triplet in %r11
	movq	method_imp(%r11), %rax	// return method imp address
	ret

LCacheMiss:
// cache miss, return nil
	DW_MISS __cache_getImp
	pop	%rax		// pushed by CacheLookup
	DW_MISS_POP __cache_getImp
	xorl	%eax, %eax
	ret

LGetImpExit:
	DW_END		__cache_getImp, 1, 0
	END_ENTRY 	__cache_getImp


/********************************************************************
 *
 * id objc_msgSend(id self, SEL	_cmd,...);
 *
 ********************************************************************/
	
	.data
	.align 3
	.private_extern __objc_tagged_isa_table
__objc_tagged_isa_table:
	.fill 16, 8, 0

	ENTRY	_objc_msgSend
	DW_START _objc_msgSend

	NilTest	NORMAL

	GetIsaFast NORMAL		// r11 = self->isa
	CacheLookup NORMAL, _objc_msgSend  // r11=method, eq set (nonstret fwd)
	jmp	*method_imp(%r11)	// goto *imp

	NilTestSupport	NORMAL

	GetIsaSupport	NORMAL

// cache miss: go search the method lists
LCacheMiss:
	DW_MISS _objc_msgSend
	GetIsa	NORMAL			// r11 = self->isa
	MethodTableLookup %a1, %a2, _objc_msgSend	// r11 = IMP
	cmp	%r11, %r11		// set eq (nonstret) for forwarding
	jmp	*%r11			// goto *imp

	DW_END 		_objc_msgSend, 1, 1
	END_ENTRY	_objc_msgSend

#if __OBJC2__
	ENTRY _objc_msgSend_fixup
	DW_START _objc_msgSend_fixup

	NilTest	NORMAL

	SaveRegisters _objc_msgSend_fixup
	
	// Dereference obj/isa/cache to crash before _objc_fixupMessageRef
	movq	8(%a2), %a6		// selector
	GetIsa	NORMAL			// r11 = isa = *receiver
	movq	cache(%r11), %a5	// cache = *isa
	movq	mask(%a5), %a4		// *cache

	// a1 = receiver
	// a2 = address of message ref
	movq	%a2, %a3
	xorl	%a2d, %a2d
	// __objc_fixupMessageRef(receiver, 0, ref)
	call	__objc_fixupMessageRef
	movq	%rax, %r11

	RestoreRegisters _objc_msgSend_fixup

	// imp is in r11
	// Load _cmd from the message_ref
	movq	8(%a2), %a2
	cmp	%r11, %r11		// set nonstret (eq) for forwarding
	jmp 	*%r11

	NilTestSupport	NORMAL
	
	DW_END 		_objc_msgSend_fixup, 0, 1
	END_ENTRY 	_objc_msgSend_fixup


	STATIC_ENTRY _objc_msgSend_fixedup
	// Load _cmd from the message_ref
	movq	8(%a2), %a2
	jmp	_objc_msgSend
	END_ENTRY _objc_msgSend_fixedup
#endif

	
/********************************************************************
 *
 * id objc_msgSendSuper(struct objc_super *super, SEL _cmd,...);
 *
 * struct objc_super {
 *		id	receiver;
 *		Class	class;
 * };
 ********************************************************************/
	
	ENTRY	_objc_msgSendSuper
	DW_START _objc_msgSendSuper

// search the cache (objc_super in %a1)
	movq	class(%a1), %r11	// class = objc_super->class
	CacheLookup NORMAL, _objc_msgSendSuper  // r11 = method, eq set (nonstret fwd)
	movq	receiver(%a1), %a1	// load real receiver
	jmp	*method_imp(%r11)	// goto *imp

// cache miss: go search the method lists
LCacheMiss:
	DW_MISS _objc_msgSendSuper
	movq	receiver(%a1), %r10
	movq	class(%a1), %r11
	MethodTableLookup %r10, %a2, _objc_msgSendSuper	// r11 = IMP
	movq	receiver(%a1), %a1	// load real receiver
	cmp	%r11, %r11		// set eq (nonstret) for forwarding
	jmp	*%r11			// goto *imp
	
	DW_END 		_objc_msgSendSuper, 1, 1
	END_ENTRY	_objc_msgSendSuper


/********************************************************************
 * id objc_msgSendSuper2
 ********************************************************************/

#if __OBJC2__
	ENTRY _objc_msgSendSuper2_fixup
	DW_START _objc_msgSendSuper2_fixup

	SaveRegisters _objc_msgSendSuper2_fixup
	// a1 = address of objc_super2
	// a2 = address of message ref
	movq	%a2, %a3
	movq	%a1, %a2
	movq	receiver(%a1), %a1
	// __objc_fixupMessageRef(receiver, objc_super, ref)
	call	__objc_fixupMessageRef
	movq	%rax, %r11
	RestoreRegisters _objc_msgSendSuper2_fixup

	// imp is in r11
	// Load _cmd from the message_ref
	movq	8(%a2), %a2
	// Load receiver from objc_super2
	movq	receiver(%a1), %a1
	cmp	%r11, %r11		// set nonstret (eq) for forwarding
	jmp 	*%r11
	
	DW_END 		_objc_msgSendSuper2_fixup, 0, 1
	END_ENTRY 	_objc_msgSendSuper2_fixup


	STATIC_ENTRY _objc_msgSendSuper2_fixedup
	movq	8(%a2), %a2		// load _cmd from message_ref
	jmp 	_objc_msgSendSuper2
	END_ENTRY _objc_msgSendSuper2_fixedup


	ENTRY _objc_msgSendSuper2
	DW_START _objc_msgSendSuper2
	// objc_super->class is superclass of class to search
	
// search the cache (objc_super in %a1)
	movq	class(%a1), %r11	// cls = objc_super->class
	movq	8(%r11), %r11		// cls = class->superclass
	CacheLookup NORMAL, _objc_msgSendSuper2	// r11 = method, eq set (nonstret fwd)
	movq	receiver(%a1), %a1	// load real receiver
	jmp	*method_imp(%r11)	// goto *imp

// cache miss: go search the method lists
LCacheMiss:
	DW_MISS _objc_msgSendSuper2
	movq	receiver(%a1), %r10
	movq	class(%a1), %r11
	movq	8(%r11), %r11
	MethodTableLookup %r10, %a2, _objc_msgSendSuper2	// r11 = IMP
	movq	receiver(%a1), %a1	// load real receiver
	cmp	%r11, %r11		// set eq (nonstret) for forwarding
	jmp	*%r11			// goto *imp
	
	DW_END 		_objc_msgSendSuper2, 1, 1
	END_ENTRY	_objc_msgSendSuper2
#endif


/********************************************************************
 *
 * double objc_msgSend_fpret(id self, SEL _cmd,...);
 * Used for `long double` return only. `float` and `double` use objc_msgSend.
 *
 ********************************************************************/

	ENTRY	_objc_msgSend_fpret
	DW_START _objc_msgSend_fpret

	NilTest	FPRET

	GetIsaFast FPRET		// r11 = self->isa
	CacheLookup FPRET, _objc_msgSend_fpret	// r11 = method, eq set (nonstret fwd)
	jmp	*method_imp(%r11)	// goto *imp

	NilTestSupport	FPRET

	GetIsaSupport	FPRET

// cache miss: go search the method lists
LCacheMiss:
	DW_MISS _objc_msgSend_fpret
	GetIsa	FPRET			// r11 = self->isa
	MethodTableLookup %a1, %a2, _objc_msgSend_fpret	// r11 = IMP
	cmp	%r11, %r11		// set eq (nonstret) for forwarding
	jmp	*%r11			// goto *imp

	DW_END 		_objc_msgSend_fpret, 1, 1
	END_ENTRY	_objc_msgSend_fpret
	
#if __OBJC2__
	ENTRY _objc_msgSend_fpret_fixup
	DW_START _objc_msgSend_fpret_fixup

	NilTest	FPRET

	SaveRegisters _objc_msgSend_fpret_fixup

	// Dereference obj/isa/cache to crash before _objc_fixupMessageRef
	movq	8(%a2), %a6		// selector
	GetIsa	FPRET			// r11 = isa = *receiver
	movq	cache(%r11), %a5	// cache = *isa
	movq	mask(%a5), %a4		// *cache

	// a1 = receiver
	// a2 = address of message ref
	movq	%a2, %a3
	xorl	%a2d, %a2d
	// __objc_fixupMessageRef(receiver, 0, ref)
	call	__objc_fixupMessageRef
	movq	%rax, %r11

	RestoreRegisters _objc_msgSend_fpret_fixup

	// imp is in r11
	// Load _cmd from the message_ref
	movq	8(%a2), %a2
	cmp	%r11, %r11		// set nonstret (eq) for forwarding
	jmp 	*%r11

	NilTestSupport	FPRET
	
	DW_END 		_objc_msgSend_fpret_fixup, 0, 1
	END_ENTRY 	_objc_msgSend_fpret_fixup


	STATIC_ENTRY _objc_msgSend_fpret_fixedup
	// Load _cmd from the message_ref
	movq	8(%a2), %a2
	jmp	_objc_msgSend_fpret
	END_ENTRY _objc_msgSend_fpret_fixedup
#endif


/********************************************************************
 *
 * double objc_msgSend_fp2ret(id self, SEL _cmd,...);
 * Used for `complex long double` return only.
 *
 ********************************************************************/

	ENTRY	_objc_msgSend_fp2ret
	DW_START _objc_msgSend_fp2ret

	NilTest	FP2RET

	GetIsaFast FP2RET		// r11 = self->isa
	CacheLookup FP2RET, _objc_msgSend_fp2ret	// r11 = method, eq set (nonstret fwd)
	jmp	*method_imp(%r11)	// goto *imp

	NilTestSupport	FP2RET

	GetIsaSupport 	FP2RET
	
// cache miss: go search the method lists
LCacheMiss:
	DW_MISS _objc_msgSend_fp2ret
	GetIsa	FP2RET			// r11 = self->isa
	MethodTableLookup %a1, %a2, _objc_msgSend_fp2ret	// r11 = IMP
	cmp	%r11, %r11		// set eq (nonstret) for forwarding
	jmp	*%r11			// goto *imp

	DW_END 		_objc_msgSend_fp2ret, 1, 1
	END_ENTRY	_objc_msgSend_fp2ret

#if __OBJC2__
	ENTRY _objc_msgSend_fp2ret_fixup
	DW_START _objc_msgSend_fp2ret_fixup

	NilTest	FP2RET

	SaveRegisters _objc_msgSend_fp2ret_fixup

	// Dereference obj/isa/cache to crash before _objc_fixupMessageRef
	movq	8(%a2), %a6		// selector
	GetIsa	FP2RET			// r11 = isa = *receiver
	movq	cache(%r11), %a5	// cache = *isa
	movq	mask(%a5), %a4		// *cache
	
	// a1 = receiver
	// a2 = address of message ref
	movq	%a2, %a3
	xorl	%a2d, %a2d
	// __objc_fixupMessageRef(receiver, 0, ref)
	call	__objc_fixupMessageRef
	movq	%rax, %r11

	RestoreRegisters _objc_msgSend_fp2ret_fixup

	// imp is in r11
	// Load _cmd from the message_ref
	movq	8(%a2), %a2
	cmp	%r11, %r11		// set nonstret (eq) for forwarding
	jmp 	*%r11

	NilTestSupport	FP2RET
	
	DW_END 		_objc_msgSend_fp2ret_fixup, 0, 1
	END_ENTRY 	_objc_msgSend_fp2ret_fixup


	STATIC_ENTRY _objc_msgSend_fp2ret_fixedup
	// Load _cmd from the message_ref
	movq	8(%a2), %a2
	jmp	_objc_msgSend_fp2ret
	END_ENTRY _objc_msgSend_fp2ret_fixedup
#endif


/********************************************************************
 *
 * void	objc_msgSend_stret(void *st_addr, id self, SEL _cmd, ...);
 *
 * objc_msgSend_stret is the struct-return form of msgSend.
 * The ABI calls for %a1 to be used as the address of the structure
 * being returned, with the parameters in the succeeding locations.
 *
 * On entry:	%a1 is the address where the structure is returned,
 *		%a2 is the message receiver,
 *		%a3 is the selector
 ********************************************************************/

	ENTRY	_objc_msgSend_stret
	DW_START _objc_msgSend_stret

	NilTest	STRET

	GetIsaFast STRET		// r11 = self->isa
	CacheLookup STRET, _objc_msgSend_stret	// r11 = method, ne set (stret fwd)
	jmp	*method_imp(%r11)	// goto *imp

	NilTestSupport	STRET

	GetIsaSupport	STRET

// cache miss: go search the method lists
LCacheMiss:
	DW_MISS _objc_msgSend_stret
	GetIsa	STRET			// r11 = self->isa
	MethodTableLookup %a2, %a3, _objc_msgSend_stret	// r11 = IMP
	test	%r11, %r11		// set ne (stret) for forward; r11!=0
	jmp	*%r11			// goto *imp

	DW_END 		_objc_msgSend_stret, 1, 1
	END_ENTRY	_objc_msgSend_stret

#if __OBJC2__
	ENTRY _objc_msgSend_stret_fixup
	DW_START _objc_msgSend_stret_fixup

	NilTest	STRET

	SaveRegisters _objc_msgSend_stret_fixup

	// Dereference obj/isa/cache to crash before _objc_fixupMessageRef
	movq	8(%a3), %a6		// selector
	GetIsa	STRET			// r11 = isa = *receiver
	movq	cache(%r11), %a5	// cache = *isa
	movq	mask(%a5), %a4		// *cache

	// a2 = receiver
	// a3 = address of message ref
	movq	%a2, %a1
	xorl	%a2d, %a2d
	// __objc_fixupMessageRef(receiver, 0, ref)
	call	__objc_fixupMessageRef
	movq	%rax, %r11

	RestoreRegisters _objc_msgSend_stret_fixup

	// imp is in r11
	// Load _cmd from the message_ref
	movq	8(%a3), %a3
	test	%r11, %r11		// set stret (ne) for forward; r11!=0
	jmp	*%r11			// goto *imp

	NilTestSupport STRET
	
	DW_END 		_objc_msgSend_stret_fixup, 0, 1
	END_ENTRY 	_objc_msgSend_stret_fixup


	STATIC_ENTRY _objc_msgSend_stret_fixedup
	// Load _cmd from the message_ref
	movq	8(%a3), %a3
	jmp	_objc_msgSend_stret
	END_ENTRY _objc_msgSend_stret_fixedup
#endif


/********************************************************************
 *
 * void objc_msgSendSuper_stret(void *st_addr, struct objc_super *super, SEL _cmd, ...);
 *
 * struct objc_super {
 *		id	receiver;
 *		Class	class;
 * };
 *
 * objc_msgSendSuper_stret is the struct-return form of msgSendSuper.
 * The ABI calls for (sp+4) to be used as the address of the structure
 * being returned, with the parameters in the succeeding registers.
 *
 * On entry:	%a1 is the address where the structure is returned,
 *		%a2 is the address of the objc_super structure,
 *		%a3 is the selector
 *
 ********************************************************************/

	ENTRY	_objc_msgSendSuper_stret
	DW_START _objc_msgSendSuper_stret

// search the cache (objc_super in %a2)
	movq	class(%a2), %r11	// class = objc_super->class
	CacheLookup STRET, _objc_msgSendSuper_stret	// r11 = method, ne set (stret fwd)
	movq	receiver(%a2), %a2	// load real receiver
	jmp	*method_imp(%r11)	// goto *imp

// cache miss: go search the method lists
LCacheMiss:
	DW_MISS _objc_msgSendSuper_stret
	movq	receiver(%a2), %r10
	movq	class(%a2), %r11
	MethodTableLookup %r10, %a3, _objc_msgSendSuper_stret	// r11 = IMP
	movq	receiver(%a2), %a2	// load real receiver
	test	%r11, %r11		// set ne (stret) for forward; r11!=0
	jmp	*%r11			// goto *imp

	DW_END 		_objc_msgSendSuper_stret, 1, 1
	END_ENTRY	_objc_msgSendSuper_stret


/********************************************************************
 * id objc_msgSendSuper2_stret
 ********************************************************************/

#if __OBJC2__
	ENTRY _objc_msgSendSuper2_stret_fixup
	DW_START _objc_msgSendSuper2_stret_fixup

	SaveRegisters _objc_msgSendSuper2_stret_fixup
	// a2 = address of objc_super2
	// a3 = address of message ref
	movq	receiver(%a2), %a1
	// __objc_fixupMessageRef(receiver, objc_super, ref)
	call	__objc_fixupMessageRef
	movq	%rax, %r11
	RestoreRegisters _objc_msgSendSuper2_stret_fixup

	// imp is in r11
	// Load _cmd from the message_ref
	movq	8(%a3), %a3
	// Load receiver from objc_super2
	movq	receiver(%a2), %a2
	test	%r11, %r11		// set stret (ne) for forward; r11!=0
	jmp	*%r11			// goto *imp
	
	DW_END 		_objc_msgSendSuper2_stret_fixup, 0, 1
	END_ENTRY 	_objc_msgSendSuper2_stret_fixup

	
	STATIC_ENTRY _objc_msgSendSuper2_stret_fixedup
	movq	8(%a3), %a3		// load _cmd from message_ref
	jmp	_objc_msgSendSuper2_stret
	END_ENTRY _objc_msgSendSuper2_stret_fixedup


	ENTRY	_objc_msgSendSuper2_stret
	DW_START _objc_msgSendSuper2_stret

// search the cache (objc_super in %a2)
	movq	class(%a2), %r11	// class = objc_super->class
	movq	8(%r11), %r11		// class = class->super_class
	CacheLookup STRET, _objc_msgSendSuper2_stret	// r11 = method, ne set (stret fwd)
	movq	receiver(%a2), %a2	// load real receiver
	jmp	*method_imp(%r11)	// goto *imp

// cache miss: go search the method lists
LCacheMiss:
	DW_MISS _objc_msgSendSuper2_stret
	movq	receiver(%a2), %r10
	movq	class(%a2), %r11
	movq	8(%r11), %r11
	MethodTableLookup %r10, %a3, _objc_msgSendSuper2_stret	// r11 = IMP
	movq	receiver(%a2), %a2	// load real receiver
	test	%r11, %r11		// set ne (stret) for forward; r11!=0
	jmp	*%r11			// goto *imp

	DW_END 		_objc_msgSendSuper2_stret, 1, 1
	END_ENTRY	_objc_msgSendSuper2_stret
#endif


/********************************************************************
 *
 * id _objc_msgForward(id self, SEL _cmd,...);
 *
 ********************************************************************/

// _FwdSel is @selector(forward::), set up in map_images().
// ALWAYS dereference _FwdSel to get to "forward::" !!
	.data
	.align 3
	.private_extern _FwdSel
_FwdSel: .quad 0

	.cstring
	.align 3
LUnkSelStr: .ascii "Does not recognize selector %s (while forwarding %s)\0"

	.data
	.align 3
	.private_extern __objc_forward_handler
__objc_forward_handler:	.quad 0

	.data
	.align 3
	.private_extern __objc_forward_stret_handler
__objc_forward_stret_handler:	.quad 0


	STATIC_ENTRY	__objc_msgForward_internal
	// Method cache version

	// THIS IS NOT A CALLABLE C FUNCTION
	// Out-of-band condition register is NE for stret, EQ otherwise.

	jne	__objc_msgForward_stret
	jmp	__objc_msgForward

	END_ENTRY	__objc_msgForward_internal
	
	
	ENTRY	__objc_msgForward
	// Non-stret version

	// Call user handler, if any
	movq	__objc_forward_handler(%rip), %r11
	testq	%r11, %r11		// if (handler == NULL)
	je	1f			//   skip handler
	jmp	*%r11			// else goto handler
1:	
	// No user handler

	// Die if forwarding "forward::"
	cmpq	%a2, _FwdSel(%rip)
	je	LMsgForwardError

	// Record current return address. It will be copied elsewhere in 
	// the marg_list because this location is needed for register args
	movq	(%rsp), %r11

	// Push stack frame
	// Space for: fpArgs + regArgs + linkage - ret (already on stack)
	subq	$ 8*16 + 6*8 + (4-1)*8, %rsp

	// Save return address in linkage area.
	movq	%r11, 16+LINK_AREA(%rsp)
	
	// Save parameter registers
	movq	%a1,  0+REG_AREA(%rsp)
	movq	%a2,  8+REG_AREA(%rsp)
	movq	%a3, 16+REG_AREA(%rsp)
	movq	%a4, 24+REG_AREA(%rsp)
	movq	%a5, 32+REG_AREA(%rsp)
	movq	%a6, 40+REG_AREA(%rsp)

	// Save side parameter registers
	// movq	%r10, 0+LINK_AREA(%rsp)	// static chain pointer == Pascal
	movq	%rax, 8+LINK_AREA(%rsp)	// xmm count
	// 16+LINK_AREA is return address

	// Save xmm registers
	movdqa	%xmm0, 0+FP_AREA(%rsp)
	movdqa	%xmm1, 16+FP_AREA(%rsp)
	movdqa	%xmm2, 32+FP_AREA(%rsp)
	movdqa	%xmm3, 48+FP_AREA(%rsp)
	movdqa	%xmm4, 64+FP_AREA(%rsp)
	movdqa	%xmm5, 80+FP_AREA(%rsp)
	movdqa	%xmm6, 96+FP_AREA(%rsp)
	movdqa	%xmm7, 112+FP_AREA(%rsp)

	// Call [receiver forward:sel :margs]
	movq	%rsp, %a4		// marg_list
	movq	%a2, %a3		// sel
	movq	_FwdSel(%rip), %a2	// forward::
	// %a1 is already the receiver

	call	_objc_msgSend
	
	// Retrieve return address from linkage area
	movq	16+LINK_AREA(%rsp), %r11
	// Pop stack frame
	addq	$ 8*16 + 6*8 + (4-1)*8, %rsp
	// Put return address back
	movq	%r11, (%rsp)
	ret

LMsgForwardError:
	// Tail-call __objc_error(receiver, "unknown selector %s %s", "forward::", forwardedSel)
	// %a1 is already the receiver
	movq	%a3, %a4		// the forwarded selector
	leaq	LUnkSelStr(%rip), %a2	// "unknown selector %s %s"
	movq	_FwdSel(%rip), %a3	// forward::
	jmp	___objc_error		// never returns

	END_ENTRY	__objc_msgForward


	ENTRY	__objc_msgForward_stret
	// Struct-return version
	
	// Call user handler, if any
	movq	__objc_forward_stret_handler(%rip), %r11
	testq	%r11, %r11		// if (handler == NULL)
	je	1f			//   skip handler
	jmp	*%r11			// else goto handler
1:	
	// No user handler
	// Die if forwarding "forward::"
	cmpq	%a3, _FwdSel(%rip)
	je	LMsgForwardStretError

	// Record current return address. It will be copied elsewhere in 
	// the marg_list because this location is needed for register args
	movq	(%rsp), %r11

	// Push stack frame
	// Space for: fpArgs + regArgs + linkage - ret (already on stack)
	subq	$ 8*16 + 6*8 + (4-1)*8, %rsp

	// Save return address in linkage area.
	movq	%r11, 16+LINK_AREA(%rsp)
	
	// Save parameter registers
	movq	%a1,  0+REG_AREA(%rsp)
	movq	%a2,  8+REG_AREA(%rsp)
	movq	%a3, 16+REG_AREA(%rsp)
	movq	%a4, 24+REG_AREA(%rsp)
	movq	%a5, 32+REG_AREA(%rsp)
	movq	%a6, 40+REG_AREA(%rsp)

	// Save side parameter registers
	// movq	%r10, 0+LINK_AREA(%rsp)	// static chain pointer == Pascal
	movq	%rax, 8+LINK_AREA(%rsp)	// xmm count
	// 16+LINK_AREA is return address

	// Save xmm registers
	movdqa	%xmm0, 0+FP_AREA(%rsp)
	movdqa	%xmm1, 16+FP_AREA(%rsp)
	movdqa	%xmm2, 32+FP_AREA(%rsp)
	movdqa	%xmm3, 48+FP_AREA(%rsp)
	movdqa	%xmm4, 64+FP_AREA(%rsp)
	movdqa	%xmm5, 80+FP_AREA(%rsp)
	movdqa	%xmm6, 96+FP_AREA(%rsp)
	movdqa	%xmm7, 112+FP_AREA(%rsp)

	// Call [receiver forward:sel :margs]
	movq	%a2, %a1		// receiver
	movq	_FwdSel(%rip), %a2	// forward::
	// %a3 is already the selector
	movq	%rsp, %a4		// marg_list

	call	_objc_msgSend		// forward:: is NOT struct-return
	
	// Retrieve return address from linkage area
	movq	16+LINK_AREA(%rsp), %r11
	// Pop stack frame
	addq	$ 8*16 + 6*8 + (4-1)*8, %rsp
	// Put return address back
	movq	%r11, (%rsp)
	ret

LMsgForwardStretError:
	// Tail-call __objc_error(receiver, "unknown selector %s %s", "forward::", forwardedSel)
	// %a4 is already the forwarded selector
	movq	%a2, %a1		// receiver
	leaq	LUnkSelStr(%rip), %a2	// "unknown selector %s %s"
	movq	_FwdSel(%rip), %a3	// forward::
	jmp	___objc_error		// never returns

	END_ENTRY	__objc_msgForward_stret


	ENTRY _objc_msgSend_debug
	jmp	_objc_msgSend
	END_ENTRY _objc_msgSend_debug

	ENTRY _objc_msgSendSuper2_debug
	jmp	_objc_msgSendSuper2
	END_ENTRY _objc_msgSendSuper2_debug

	ENTRY _objc_msgSend_stret_debug
	jmp	_objc_msgSend_stret
	END_ENTRY _objc_msgSend_stret_debug

	ENTRY _objc_msgSendSuper2_stret_debug
	jmp	_objc_msgSendSuper2_stret
	END_ENTRY _objc_msgSendSuper2_stret_debug

	ENTRY _objc_msgSend_fpret_debug
	jmp	_objc_msgSend_fpret
	END_ENTRY _objc_msgSend_fpret_debug

	ENTRY _objc_msgSend_fp2ret_debug
	jmp	_objc_msgSend_fp2ret
	END_ENTRY _objc_msgSend_fp2ret_debug


	ENTRY _objc_msgSend_noarg
	jmp	_objc_msgSend
	END_ENTRY _objc_msgSend_noarg


	ENTRY _method_invoke

	movq	method_imp(%a2), %r11
	movq	method_name(%a2), %a2
	jmp	*%r11
	
	END_ENTRY _method_invoke


	ENTRY _method_invoke_stret

	movq	method_imp(%a3), %r11
	movq	method_name(%a3), %a3
	jmp	*%r11
	
	END_ENTRY _method_invoke_stret


	STATIC_ENTRY __objc_ignored_method

	movq	%a1, %rax
	ret
	
	END_ENTRY __objc_ignored_method
	
	
/********************************************************************
 *
 * id vtable_prototype(id self, message_ref *msg, ...)
 *
 * This code is copied to create vtable trampolines.
 * The instruction following LvtableIndex is modified to
 * insert each vtable index.
 * The instructions following LvtableTagTable are modified to
 * load the tagged isa table.
 *
 * This code is placed in its own section to prevent dtrace from
 * instrumenting it. Otherwise, dtrace would insert an INT3, the
 * code would be copied, and the copied INT3 would cause a crash.
 * 
 * ABI WARNING ABI WARNING ABI WARNING ABI WARNING ABI WARNING
 * vtable_prototype steals %rax and does not clear %rdx on return
 * in order to precisely pack instructions into ifetch and cache lines
 * This means vtable dispatch must never be used for vararg calls
 * or very large return values.
 * ABI WARNING ABI WARNING ABI WARNING ABI WARNING ABI WARNING
 *
 ********************************************************************/

.macro VTABLE /* byte-offset, name */

	.align 6
	.private_extern _$1
_$1:
	test	%a1, %a1
	je	LvtableReturnZero_$1	// nil check	
	testl	$$1, %a1d
	jne	LvtableTaggedPointer_$1 // tag check

	movq	(%a1), %rax		// load isa  (see ABI WARNING)
	movq	24(%rax), %rax		// load vtable
	movq	8(%a2), %a2		// load _cmd
LvtableIndex_$1:
	jmpq	* $0 (%rax)		// load imp (DO NOT CHANGE)
	
LvtableReturnZero_$1:
	// integer registers only; not used for fpret / stret / etc
	xorl	%eax, %eax
	// xorl	%edx, %edx  (see ABI WARNING)
	ret

	nop
LvtableTaggedPointer_$1:
	// extract isa (bits 1-2-3) from %a1, bit 0 is kept around for the heck of it
	movl	%a1d, %eax
	andl	$$0xF, %eax
LvtableTagTable_$1:
.if $0 == 0x7fff
	movq	$$0x1122334455667788, %r10  // vtable_prototype (DO NOT CHANGE)
.else
	leaq	__objc_tagged_isa_table(%rip), %r10
.endif
LvtableTagTableEnd_$1:
	movq	(%r10, %rax, 8), %r10	// load isa from table (see ABI WARNING
	movq	24(%r10), %rax		// load vtable
	movq	8(%a2), %a2		// load _cmd
LvtableIndex2_$1:
	jmpq	* $0 (%rax)		// load imp (DO NOT CHANGE)
	
LvtableEnd_$1:

.endmacro

	.section __TEXT,__objc_codegen,regular
	VTABLE	0x7fff, vtable_prototype
	
	.data
	.align 2
	.private_extern _vtable_prototype_size
_vtable_prototype_size:
	.long	LvtableEnd_vtable_prototype - _vtable_prototype

	.private_extern _vtable_prototype_index_offset
_vtable_prototype_index_offset:
	.long	LvtableIndex_vtable_prototype - _vtable_prototype

	.private_extern _vtable_prototype_index2_offset
_vtable_prototype_index2_offset:
	.long	LvtableIndex2_vtable_prototype - _vtable_prototype

	.private_extern _vtable_prototype_tagtable_offset
_vtable_prototype_tagtable_offset:
	.long LvtableTagTable_vtable_prototype - _vtable_prototype

	.private_extern _vtable_prototype_tagtable_size
_vtable_prototype_tagtable_size:
	.long LvtableTagTableEnd_vtable_prototype - LvtableTagTable_vtable_prototype

/********************************************************************
 *
 * id vtable_ignored(id self, message_ref *msg, ...)
 *
 * Vtable trampoline for GC-ignored selectors. Immediately returns self.
 *
 ********************************************************************/	

	STATIC_ENTRY _vtable_ignored
	movq	%a1, %rax
	ret


/********************************************************************
 *
 * id objc_msgSend_vtable<n>(id self, message_ref *msg, ...)
 *
 * Built-in expansions of vtable_prototype for the default vtable.
 *
 ********************************************************************/
	
	.text

	.align	4
	.private_extern _defaultVtableTrampolineDescriptors
_defaultVtableTrampolineDescriptors:
	// objc_trampoline_header
	.short	16  // headerSize
	.short	8   // descSize
	.long	16  // descCount
	.quad	0   // next
	
	// objc_trampoline_descriptor[16]
.macro TDESC /* n */
L_tdesc$0:
	.long	_objc_msgSend_vtable$0 - L_tdesc$0
	.long	(1<<0) + (1<<2)  // MESSAGE and VTABLE
.endmacro
	
	TDESC	0
	TDESC	1
	TDESC	2
	TDESC	3
	TDESC	4
	TDESC	5
	TDESC	6
	TDESC	7
	TDESC	8
	TDESC	9
	TDESC	10
	TDESC	11
	TDESC	12
	TDESC	13
	TDESC	14
	TDESC	15

	// trampoline code
	.align	4
	VTABLE	 0*8, objc_msgSend_vtable0
	VTABLE	 1*8, objc_msgSend_vtable1
	VTABLE	 2*8, objc_msgSend_vtable2
	VTABLE	 3*8, objc_msgSend_vtable3
	VTABLE	 4*8, objc_msgSend_vtable4
	VTABLE	 5*8, objc_msgSend_vtable5
	VTABLE	 6*8, objc_msgSend_vtable6
	VTABLE	 7*8, objc_msgSend_vtable7
	VTABLE	 8*8, objc_msgSend_vtable8
	VTABLE	 9*8, objc_msgSend_vtable9
	VTABLE	10*8, objc_msgSend_vtable10
	VTABLE	11*8, objc_msgSend_vtable11
	VTABLE	12*8, objc_msgSend_vtable12
	VTABLE	13*8, objc_msgSend_vtable13
	VTABLE	14*8, objc_msgSend_vtable14
	VTABLE	15*8, objc_msgSend_vtable15

#endif
