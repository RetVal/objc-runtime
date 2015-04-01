#if __OBJC2__

#include <mach/shared_region.h>

#if __LP64__
#   define PTR " .quad " 
#else
#   define PTR " .long " 
#endif

#define str(x) #x
#define str2(x) str(x)

__BEGIN_DECLS
void nop(void) { }
__END_DECLS

asm(
    ".globl _OBJC_CLASS_$_Super    \n"
    ".section __DATA,__objc_data  \n"
    ".align 3                     \n"
    "_OBJC_CLASS_$_Super:          \n"
    PTR "_OBJC_METACLASS_$_Super   \n"
    PTR "0                        \n"
    PTR "__objc_empty_cache \n"
    PTR "__objc_empty_vtable \n"
    PTR "L_ro \n"
    ""
    "_OBJC_METACLASS_$_Super:          \n"
    PTR "_OBJC_METACLASS_$_Super   \n"
    PTR "_OBJC_CLASS_$_Super        \n"
    PTR "__objc_empty_cache \n"
    PTR "__objc_empty_vtable \n"
    PTR "L_meta_ro \n"
    ""
    "L_ro: \n"
    ".long 2 \n"
    ".long 0 \n"
    ".long 0 \n"
#if __LP64__
    ".long 0 \n"
#endif
    PTR "0 \n"
    PTR "L_super_name \n"
#if EVIL_SUPER
    PTR "L_evil_methods \n"
#else
    PTR "L_good_methods \n"
#endif
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    ""
    "L_meta_ro: \n"
    ".long 3 \n"
    ".long 40 \n"
    ".long 40 \n"
#if __LP64__
    ".long 0 \n"
#endif
    PTR "0 \n"
    PTR "L_super_name \n"
#if EVIL_SUPER_META
    PTR "L_evil_methods \n"
#else
    PTR "L_good_methods \n"
#endif
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"

    ".globl _OBJC_CLASS_$_Sub    \n"
    ".section __DATA,__objc_data  \n"
    ".align 3                     \n"
    "_OBJC_CLASS_$_Sub:          \n"
    PTR "_OBJC_METACLASS_$_Sub   \n"
    PTR "_OBJC_CLASS_$_Super       \n"
    PTR "__objc_empty_cache \n"
    PTR "__objc_empty_vtable \n"
    PTR "L_sub_ro \n"
    ""
    "_OBJC_METACLASS_$_Sub:          \n"
    PTR "_OBJC_METACLASS_$_Super   \n"
    PTR "_OBJC_METACLASS_$_Super        \n"
    PTR "__objc_empty_cache \n"
    PTR "__objc_empty_vtable \n"
    PTR "L_sub_meta_ro \n"
    ""
    "L_sub_ro: \n"
    ".long 2 \n"
    ".long 0 \n"
    ".long 0 \n"
#if __LP64__
    ".long 0 \n"
#endif
    PTR "0 \n"
    PTR "L_sub_name \n"
#if EVIL_SUB
    PTR "L_evil_methods \n"
#else
    PTR "L_good_methods \n"
#endif
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    ""
    "L_sub_meta_ro: \n"
    ".long 3 \n"
    ".long 40 \n"
    ".long 40 \n"
#if __LP64__
    ".long 0 \n"
#endif
    PTR "0 \n"
    PTR "L_sub_name \n"
#if EVIL_SUB_META
    PTR "L_evil_methods \n"
#else
    PTR "L_good_methods \n"
#endif
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"

    "L_evil_methods: \n"
    ".long 24 \n"
    ".long 1 \n"
    PTR "L_load \n"
    PTR "L_load \n"
    PTR str2(SHARED_REGION_BASE+SHARED_REGION_SIZE-0x1000) " \n"

    "L_good_methods: \n"
    ".long 24 \n"
    ".long 1 \n"
    PTR "L_load \n"
    PTR "L_load \n"
    PTR "_nop \n"

    ".cstring \n"
    "L_super_name: .ascii \"Super\\0\" \n"
    "L_sub_name:   .ascii \"Sub\\0\" \n"
    "L_load:       .ascii \"load\\0\" \n"


    ".section __DATA,__objc_classlist \n"
#if !OMIT_SUPER
    PTR "_OBJC_CLASS_$_Super \n"
#endif
#if !OMIT_SUB
    PTR "_OBJC_CLASS_$_Sub \n"
#endif

    ".section __DATA,__objc_nlclslist \n"
#if !OMIT_NL_SUPER
    PTR "_OBJC_CLASS_$_Super \n"
#endif
#if !OMIT_NL_SUB
    PTR "_OBJC_CLASS_$_Sub \n"
#endif

    ".text \n"
);

// __OBJC2__
#endif

void fn(void) { }
