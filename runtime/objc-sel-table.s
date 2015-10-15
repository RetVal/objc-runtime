#include <mach/vm_param.h>
.section __TEXT,__objc_opt_ro
.align 3
.private_extern __objc_opt_data
__objc_opt_data:
.long 12 /* table.version */
.long 0 /* table.selopt_offset */
.long 0 /* table.headeropt_offset */
.long 0 /* table.clsopt_offset */
.space PAGE_MAX_SIZE-16

/* space for selopt, smax/capacity=262144, blen/mask=131071+1 */
.space 131072    /* mask tab */
.space 262144    /* checkbytes */
.space 262144*4  /* offsets */

/* space for clsopt, smax/capacity=32768, blen/mask=16383+1 */
.space 16384            /* mask tab */
.space 32768    	/* checkbytes */
.space 32768*12 	/* offsets to name and class and header_info */
.space PAGE_MAX_SIZE	/* some duplicate classes */


.section __DATA,__objc_opt_rw
.align 3
.private_extern __objc_opt_rw_data
__objc_opt_rw_data:
/* space for header_info structures */
.space 32768
