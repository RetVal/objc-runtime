#include <ptrauth.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/cdefs.h>
#include <TargetConditionals.h>

#if __LP64__
#   define PTR " .quad " 
#   define PTRSIZE "8"
#   define LOGPTRSIZE "3"
#   define ONLY_LP64(x) x
#else
#   define PTR " .long " 
#   define PTRSIZE "4"
#   define LOGPTRSIZE "2"
#   define ONLY_LP64(x)
#endif

#if __has_feature(ptrauth_calls)
#   define SIGNED_METHOD_LIST_IMP "@AUTH(ia,0,addr) "
#   define SIGNED_STUB_INITIALIZER "@AUTH(ia,0xc671,addr) "
#   define SIGNED_METHOD_LIST "@AUTH(da,0xC310,addr) "
#   define SIGNED_ISA "@AUTH(da, 0x6AE1, addr) "
#   define SIGNED_SUPER "@AUTH(da, 0xB5AB, addr) "
#   define SIGNED_RO  "@AUTH(da, 0x61F8, addr) "
#else
#   define SIGNED_METHOD_LIST_IMP
#   define SIGNED_STUB_INITIALIZER
#   define SIGNED_METHOD_LIST
#   define SIGNED_ISA
#   define SIGNED_SUPER
#   define SIGNED_RO
#endif

#if TARGET_OS_EXCLAVEKIT
// On ExclaveKit, all method lists are signed
#   define SIGNED_OBJC_SEL "@AUTH(da,0x57c2,addr)"
#   define SIGNED_METHOD_TYPES "@AUTH(da,0xdec6,addr)"
#else
#   define SIGNED_OBJC_SEL
#   define SIGNED_METHOD_TYPES
#endif

#define str(x) #x
#define str2(x) str(x)

// Swift metadata initializers. Define these in the test.
EXTERN_C Class initSuper(Class cls, void *arg);
EXTERN_C Class initSub(Class cls, void *arg);

@interface SwiftSuper : NSObject @end
@interface SwiftSub : SwiftSuper @end

__BEGIN_DECLS
// not id to avoid ARC operations because the class doesn't implement RR methods
void* nop(void* self) { return self; }
__END_DECLS

#define SWIFT_CLASS(name, superclass, swiftInit) \
asm(                                               \
    ".globl _OBJC_CLASS_$_" #name             "\n" \
    ".section __DATA,__objc_data               \n" \
    ".align 3                                  \n" \
    "_OBJC_CLASS_$_" #name ":                  \n" \
    PTR "_OBJC_METACLASS_$_" #name SIGNED_ISA "\n" \
    PTR "_OBJC_CLASS_$_" #superclass SIGNED_SUPER "\n" \
    PTR "__objc_empty_cache                    \n" \
    PTR "0 \n"                                     \
    PTR "(L_" #name "_ro + 2)" SIGNED_RO "\n"      \
    /* Swift class fields. */                      \
    ".long 0 \n"   /* flags */                     \
    ".long 0 \n"   /* instanceAddressOffset */     \
    ".long 16 \n"  /* instanceSize */              \
    ".short 15 \n" /* instanceAlignMask */         \
    ".short 0 \n"  /* reserved */                  \
    ".long 256 \n" /* classSize */                 \
    ".long 0 \n"   /* classAddressOffset */        \
    PTR "0 \n"     /* description */               \
    /* pad to OBJC_MAX_CLASS_SIZE */               \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
                                                   \
    "_OBJC_METACLASS_$_" #name ":              \n" \
    PTR "_OBJC_METACLASS_$_" #superclass SIGNED_ISA "\n" \
    PTR "_OBJC_METACLASS_$_" #superclass SIGNED_SUPER "\n" \
    PTR "__objc_empty_cache                    \n" \
    PTR "0 \n"                                     \
    PTR "L_" #name "_meta_ro" SIGNED_RO "\n"       \
    /* pad to OBJC_MAX_CLASS_SIZE */               \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
                                                   \
    "L_" #name "_ro: \n"                           \
    ".long (1<<6) \n"                              \
    ".long 0 \n"                                   \
    ".long " PTRSIZE " \n"                         \
    ONLY_LP64(".long 0 \n")                        \
    PTR "0 \n"                                     \
    PTR "L_" #name "_name \n"                      \
    PTR "L_" #name "_methods" SIGNED_METHOD_LIST "\n" \
    PTR "0 \n"                                     \
    PTR "L_" #name "_ivars \n"                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "_" #swiftInit SIGNED_METHOD_LIST_IMP "\n" \
                                                   \
    "L_" #name "_meta_ro: \n"                      \
    ".long 1 \n"                                   \
    ".long 40 \n"                                  \
    ".long 40 \n"                                  \
    ONLY_LP64(".long 0 \n")                        \
    PTR "0 \n"                                     \
    PTR "L_" #name "_name \n"                      \
    PTR "L_" #name "_meta_methods" SIGNED_METHOD_LIST "\n" \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
    PTR "0 \n"                                     \
                                                   \
    "L_" #name "_methods: \n"                      \
    "L_" #name "_meta_methods: \n"                 \
    ".long 3*" PTRSIZE "\n"                        \
    ".long 1 \n"                                   \
    PTR "L_" #name "_self" SIGNED_OBJC_SEL " \n"   \
    PTR "L_" #name "_self" SIGNED_METHOD_TYPES "\n"\
    PTR "_nop" SIGNED_METHOD_LIST_IMP "\n"         \
                                                   \
    "L_" #name "_ivars: \n"                        \
    ".long 4*" PTRSIZE " \n"                       \
    ".long 1 \n"                                   \
    PTR "L_" #name "_ivar_offset \n"               \
    PTR "L_" #name "_ivar_name \n"                 \
    PTR "L_" #name "_ivar_type \n"                 \
    ".long " LOGPTRSIZE "\n"                       \
    ".long " PTRSIZE "\n"                          \
                                                   \
    "L_" #name "_ivar_offset: \n"                  \
    ".long 0 \n"                                   \
                                                   \
    ".cstring \n"                                  \
    "L_" #name "_name: .ascii \"" #name "\\0\" \n" \
    "L_" #name "_self: .ascii \"self\\0\" \n"      \
    "L_" #name "_ivar_name: "                      \
    "  .ascii \"" #name "_ivar\\0\" \n"            \
    "L_" #name "_ivar_type: .ascii \"c\\0\" \n"    \
                                                   \
                                                   \
    ".text \n"                                     \
);                                                 \
extern char OBJC_CLASS_$_ ## name;                 \
Class Raw ## name = (Class)&OBJC_CLASS_$_ ## name

#define SWIFT_STUB_CLASSREF(name)                                        \
extern char OBJC_CLASS_$_ ## name;                                       \
static Class name ## Classref = (Class)(&OBJC_CLASS_$_ ## name + 1);     \
__attribute__((section("__DATA,__objc_stublist,regular,no_dead_strip"))) \
void *name ## StubListPtr = &OBJC_CLASS_$_ ## name;

#define SWIFT_STUB_CLASS(name, initializer)        \
asm(                                               \
    ".globl _OBJC_CLASS_$_" #name "\n"             \
    ".section __DATA,__objc_data \n"               \
    ".align 3 \n"                                  \
    "_dummy" #name ": \n"                          \
    PTR "0 \n"                                     \
    ".alt_entry _OBJC_CLASS_$_" #name "\n"         \
    "_OBJC_CLASS_$_" #name ": \n"                  \
    PTR "1 \n"                                     \
    PTR "_" #initializer SIGNED_STUB_INITIALIZER "\n" \
    ".text"                                        \
);                                                 \
extern char OBJC_CLASS_$_ ## name;                 \
Class Raw ## name = (Class)&OBJC_CLASS_$_ ## name; \
SWIFT_STUB_CLASSREF(name)


inline bool isRealized(Class cls)
{
    // check the is-realized bits directly

// FAST_DATA_MASK taken from objc-runtime-new.h, must be updated here if it
// ever changes there.
#if __LP64__
# if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
#  define FAST_DATA_MASK          0x0000007ffffffff8UL
# else
#  define FAST_DATA_MASK          0x00007ffffffffff8UL
# endif
#else
# define FAST_DATA_MASK        0xfffffffcUL
#endif
#define RW_REALIZED (1<<31)

    uint32_t *rw = (uint32_t *)((uintptr_t *)cls)[4];  // class_t->data

    rw = ptrauth_strip(rw, ptrauth_key_process_dependent_data);
    rw = (uint32_t *)((uintptr_t)rw & FAST_DATA_MASK);

    return ((uint32_t *)rw)[0] & RW_REALIZED;  // class_rw_t->flags
}
