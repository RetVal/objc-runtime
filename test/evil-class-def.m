#include <sys/cdefs.h>

#if __LP64__
#   define PTR " .quad " 
#   define PTRSIZE "8"
#   define LOGPTRSIZE "3"
#else
#   define PTR " .long " 
#   define PTRSIZE "4"
#   define LOGPTRSIZE "2"
#endif

#if __has_feature(ptrauth_calls)
#   define SIGNED_METHOD_LIST_IMP "@AUTH(ia,0,addr) "
#   define SIGNED_METHOD_LIST "@AUTH(da,0xC310,addr) "
#   define SIGNED_ISA "@AUTH(da, 0x6AE1, addr) "
#   define SIGNED_SUPER "@AUTH(da, 0xB5AB, addr) "
#   define SIGNED_RO  "@AUTH(da, 0x61F8, addr) "
#else
#   define SIGNED_METHOD_LIST_IMP
#   define SIGNED_METHOD_LIST
#   define SIGNED_ISA
#   define SIGNED_SUPER
#   define SIGNED_RO
#endif

#if TARGET_OS_EXCLAVEKIT
#   define SIGNED_OBJC_SEL "@AUTH(da, 0x57c2, addr) "
#   define SIGNED_METHOD_TYPES "@AUTH(da,0xdec6,addr) "
#else
#   define SIGNED_OBJC_SEL
#   define SIGNED_METHOD_TYPES
#endif


#define str(x) #x
#define str2(x) str(x)

__BEGIN_DECLS
// not id to avoid ARC operations because the class doesn't implement RR methods
void* nop(void* self) { return self; }
__END_DECLS

asm(
    ".globl _OBJC_CLASS_$_Super               \n"
    ".section __DATA,__objc_data              \n"
    ".align 3                                 \n"
    "_OBJC_CLASS_$_Super:                     \n"
    PTR "_OBJC_METACLASS_$_Super" SIGNED_ISA "\n"
    PTR "0                                    \n"
    PTR "__objc_empty_cache                   \n"
    PTR "0                                    \n"
    PTR "L_ro" SIGNED_RO "                    \n"
    // pad to OBJC_MAX_CLASS_SIZE
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    ""
    "_OBJC_METACLASS_$_Super:                 \n"
    PTR "_OBJC_METACLASS_$_Super" SIGNED_ISA "\n"
    PTR "_OBJC_CLASS_$_Super" SIGNED_SUPER   "\n"
    PTR "__objc_empty_cache                   \n"
    PTR "0                                    \n"
    PTR "L_meta_ro" SIGNED_RO "               \n"
    // pad to OBJC_MAX_CLASS_SIZE
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    ""
    "L_ro: \n"
    ".long 2 \n"
    ".long 0 \n"
    ".long " PTRSIZE " \n"
#if __LP64__
    ".long 0 \n"
#endif
    PTR "0 \n"
    PTR "L_super_name \n"
#if EVIL_SUPER
    PTR "L_evil_methods" SIGNED_METHOD_LIST "\n"
#else
    PTR "L_good_methods" SIGNED_METHOD_LIST "\n"
#endif
    PTR "0 \n"
    PTR "L_super_ivars \n"
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
    PTR "L_evil_methods" SIGNED_METHOD_LIST "\n"
#else
    PTR "L_good_methods" SIGNED_METHOD_LIST "\n"
#endif
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"

    ".globl _OBJC_CLASS_$_Sub               \n"
    ".section __DATA,__objc_data            \n"
    ".align 3                               \n"
    "_OBJC_CLASS_$_Sub:                     \n"
    PTR "_OBJC_METACLASS_$_Sub" SIGNED_ISA "\n"
    PTR "_OBJC_CLASS_$_Super" SIGNED_SUPER "\n"
    PTR "__objc_empty_cache                 \n"
    PTR "0                                  \n"
    PTR "L_sub_ro" SIGNED_RO "              \n"
    // pad to OBJC_MAX_CLASS_SIZE
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    ""
    "_OBJC_METACLASS_$_Sub:                     \n"
    PTR "_OBJC_METACLASS_$_Super" SIGNED_ISA   "\n"
    PTR "_OBJC_METACLASS_$_Super" SIGNED_SUPER "\n"
    PTR "__objc_empty_cache                     \n"
    PTR "0                                      \n"
    PTR "L_sub_meta_ro" SIGNED_RO "             \n"
    // pad to OBJC_MAX_CLASS_SIZE
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    ""
    "L_sub_ro: \n"
    ".long 2 \n"
    ".long 0 \n"
    ".long " PTRSIZE " \n"
#if __LP64__
    ".long 0 \n"
#endif
    PTR "0 \n"
    PTR "L_sub_name \n"
#if EVIL_SUB
    PTR "L_evil_methods" SIGNED_METHOD_LIST "\n"
#else
    PTR "L_good_methods" SIGNED_METHOD_LIST "\n"
#endif
    PTR "0 \n"
    PTR "L_sub_ivars \n"
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
    PTR "L_evil_methods" SIGNED_METHOD_LIST "\n"
#else
    PTR "L_good_methods" SIGNED_METHOD_LIST "\n"
#endif
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"
    PTR "0 \n"

    "L_evil_methods: \n"
    ".long 3*" PTRSIZE " \n"
    ".long 1 \n"
    PTR "L_load" SIGNED_OBJC_SEL " \n"
    PTR "L_load" SIGNED_METHOD_TYPES " \n"
    PTR "_abort" SIGNED_METHOD_LIST_IMP "\n"
    // assumes that abort is inside the dyld shared cache

    "L_good_methods: \n"
    ".long 3*" PTRSIZE " \n"
    ".long 2 \n"
    PTR "L_load" SIGNED_OBJC_SEL " \n"
    PTR "L_load" SIGNED_METHOD_TYPES " \n"
    PTR "_nop" SIGNED_METHOD_LIST_IMP "\n"
    PTR "L_self" SIGNED_OBJC_SEL " \n"
    PTR "L_self" SIGNED_METHOD_TYPES " \n"
    PTR "_nop" SIGNED_METHOD_LIST_IMP "\n"

    "L_super_ivars: \n"
    ".long 4*" PTRSIZE " \n"
    ".long 1 \n"
    PTR "L_super_ivar_offset \n"
    PTR "L_super_ivar_name \n"
    PTR "L_super_ivar_type \n"
    ".long " LOGPTRSIZE " \n"
    ".long " PTRSIZE " \n"

    "L_sub_ivars: \n"
    ".long 4*" PTRSIZE " \n"
    ".long 1 \n"
    PTR "L_sub_ivar_offset \n"
    PTR "L_sub_ivar_name \n"
    PTR "L_sub_ivar_type \n"
    ".long " LOGPTRSIZE " \n"
    ".long " PTRSIZE " \n"

    "L_super_ivar_offset: \n"
    ".long 0 \n"
    "L_sub_ivar_offset: \n"
    ".long " PTRSIZE " \n"

    ".cstring \n"
    "L_super_name:       .ascii \"Super\\0\" \n"
    "L_sub_name:         .ascii \"Sub\\0\" \n"
    "L_load:             .ascii \"load\\0\" \n"
    "L_self:             .ascii \"self\\0\" \n"
    "L_super_ivar_name:  .ascii \"super_ivar\\0\" \n"
    "L_super_ivar_type:  .ascii \"c\\0\" \n"
    "L_sub_ivar_name:    .ascii \"sub_ivar\\0\" \n"
    "L_sub_ivar_type:    .ascii \"@\\0\" \n"


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

void fn(void) { }
