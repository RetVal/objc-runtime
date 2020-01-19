#include <sys/cdefs.h>

#if __LP64__
#   define PTR " .quad " 
#else
#   define PTR " .long " 
#endif

#if __has_feature(ptrauth_calls)
#   define SIGNED_METHOD_LIST_IMP "@AUTH(ia,0,addr) "
#else
#   define SIGNED_METHOD_LIST_IMP
#endif

#define str(x) #x
#define str2(x) str(x)

__BEGIN_DECLS
void nop(void) { }
__END_DECLS

asm(
    ".section __DATA,__objc_data \n"
    ".align 3 \n"
    "L_category: \n"
    PTR "L_cat_name \n"
    PTR "_OBJC_CLASS_$_NSObject \n"
#if EVIL_INSTANCE_METHOD
    PTR "L_evil_methods \n"
#else
    PTR "L_good_methods \n"
#endif
#if EVIL_CLASS_METHOD
    PTR "L_evil_methods \n"
#else
    PTR "L_good_methods \n"
#endif
    PTR "0 \n"
    PTR "0 \n"

    "L_evil_methods: \n"
    ".long 24 \n"
    ".long 1 \n"
    PTR "L_load \n"
    PTR "L_load \n"
    PTR "_abort" SIGNED_METHOD_LIST_IMP "\n"
    // assumes that abort is inside the dyld shared cache

    "L_good_methods: \n"
    ".long 24 \n"
    ".long 1 \n"
    PTR "L_load \n"
    PTR "L_load \n"
    PTR "_nop" SIGNED_METHOD_LIST_IMP "\n"

    ".cstring \n"
    "L_cat_name:   .ascii \"Evil\\0\" \n"
    "L_load:       .ascii \"load\\0\" \n"

    ".section __DATA,__objc_catlist \n"
#if !OMIT_CAT
    PTR "L_category \n"
#endif

    ".section __DATA,__objc_nlcatlist \n"
#if !OMIT_NL_CAT
    PTR "L_category \n"
#endif

    ".text \n"
    );

void fn(void) { }
