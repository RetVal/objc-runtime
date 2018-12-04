#include <TargetConditionals.h>
#include <mach/vm_param.h>

#if __LP64__
# define PTR(x) .quad x
#else
# define PTR(x) .long x
#endif

.section __TEXT,__objc_opt_ro
.align 3
.private_extern __objc_opt_data
__objc_opt_data:
.long 15 /* table.version */
.long 0 /* table.flags */
.long 0 /* table.selopt_offset */
.long 0 /* table.headeropt_ro_offset */
.long 0 /* table.clsopt_offset */	
.long 0 /* table.protocolopt_offset */
.long 0 /* table.headeropt_rw_offset */
.space PAGE_MAX_SIZE-28

/* space for selopt, smax/capacity=1048576, blen/mask=524287+1 */
.space 4*(8+256)  /* header and scramble */
.space 524288     /* mask tab */
.space 1048576     /* checkbytes */
.space 1048576*4   /* offsets */

/* space for clsopt, smax/capacity=131072, blen/mask=32767+1 */
.space 4*(8+256)        /* header and scramble */
.space 32768            /* mask tab */
.space 131072           /* checkbytes */
.space 131072*12        /* offsets to name and class and header_info */
.space 512*8            /* some duplicate classes */

/* space for some demangled protocol names */
.space 1024

/* space for protocolopt, smax/capacity=16384, blen/mask=8191+1 */
.space 4*(8+256)        /* header and scramble */
.space 8192             /* mask tab */
.space 16384             /* checkbytes */
.space 16384*8           /* offsets */

/* space for 2048 header_info (RO) structures */
.space 8 + (2048*16)


.section __DATA,__objc_opt_rw
.align 3
.private_extern __objc_opt_rw_data
__objc_opt_rw_data:

/* space for 2048 header_info (RW) structures */
.space 8 + (2048*8)

/* space for 16384 protocols */
#if __LP64__
.space 16384 * 12 * 8
#else
.space 16384 * 12 * 4
#endif


/* section of pointers that the shared cache optimizer wants to know about */
.section __DATA,__objc_opt_ptrs
.align 3

#if TARGET_OS_OSX  &&  __i386__
// old ABI
.globl .objc_class_name_Protocol
PTR(.objc_class_name_Protocol)
#else
// new ABI
.globl _OBJC_CLASS_$_Protocol
PTR(_OBJC_CLASS_$_Protocol)
#endif
