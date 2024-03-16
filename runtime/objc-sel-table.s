#include <TargetConditionals.h>
#include "objc-vm.h"

#if __LP64__
#if __arm64e__
// 0x6AE1
# define PTR(x) .quad x@AUTH(da, 27361, addr)
#else
# define PTR(x) .quad x
#endif
#else
# define PTR(x) .long x
#endif

// These offsets are populated by the dyld shared cache builder.
// They point to memory allocatd elsewhere in the shared cache.

.section __TEXT,__objc_opt_ro
.align 3
.private_extern __objc_opt_data
__objc_opt_data:
.long 16 /* table.version */
.long 0 /* table.flags */
.long 0 /* table.selopt_offset */
.long 0 /* table.headeropt_ro_offset */
.long 0 /* table.clsopt_offset */	
.long 0 /* table.protocolopt_offset */
.long 0 /* table.headeropt_rw_offset */
.long 0 /* table.unused_protocolopt2_offset */
.long 0 /* table.largeSharedCachesClassOffset */
.long 0 /* table.largeSharedCachesProtocolOffset */
.space PAGE_MAX_SIZE-40


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
