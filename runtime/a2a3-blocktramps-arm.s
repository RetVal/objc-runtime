#if __arm__
	
#include <arm/arch.h>

.syntax unified

.text


// This must match a1a2-blocktramps-arm.s
#if defined(_ARM_ARCH_7)
#   define THUMB2 1
#else
#   define THUMB2 0
#endif

#if THUMB2
	.thumb
	.thumb_func __a2a3_tramphead
	.thumb_func __a2a3_firsttramp
	.thumb_func __a2a3_nexttramp
	.thumb_func __a2a3_trampend
#else
	// don't use Thumb-1
	.arm
#endif
	
.align 12
.private_extern __a2a3_tramphead
__a2a3_tramphead_nt:	
__a2a3_tramphead:
	/*
	 r0 == stret
	 r1 == self
	 r2 == pc of trampoline's first instruction + 4
	 lr == original return address
	 */

	// calculate the trampoline's index (512 entries, 8 bytes each)
#if THUMB2
	// PC bias is only 4, no need to correct with 8-byte trampolines
	ubfx r2, r2, #3, #9
#else
	sub  r2, r2, #8               // correct PC bias
	lsl  r2, r2, #20
	lsr  r2, r2, #23
#endif

	// load block pointer from trampoline's data
	// nt label works around thumb integrated asm bug rdar://11315197
	adr  r12, __a2a3_tramphead_nt // text page
	sub  r12, r12, #4096          // data page precedes text page
	ldr  r12, [r12, r2, LSL #3]   // load block pointer from data + index*8

	// shuffle parameters
	mov  r2, r1                   // _cmd = self
	mov  r1, r12                  // self = block pointer

	// tail call block->invoke
	ldr  pc, [r12, #12]
	// not reached

	// Make v6 and v7 match so they have the same number of TrampolineEntry
	// below. Debug asserts in objc-block-trampoline.m check this.
#if THUMB2
	.space 16
#endif

.macro TrampolineEntry
	mov r2, pc
	b __a2a3_tramphead
	.align 3
.endmacro

.align 3
.private_extern __a2a3_firsttramp
__a2a3_firsttramp:
    TrampolineEntry

.private_extern __a2a3_nexttramp
__a2a3_nexttramp:
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry

.private_extern __a2a3_trampend
__a2a3_trampend:

#endif
