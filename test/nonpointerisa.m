// TEST_CFLAGS -framework Foundation
// TEST_CONFIG MEM=mrc OS=!exclavekit

#include "test.h"
#include <dlfcn.h>

#include <objc/objc-gdb.h>
#include <Foundation/Foundation.h>

#define ISA(x) (*((uintptr_t *)(x)))
#define NONPOINTER(x) (ISA(x) & 1)

#if SUPPORT_NONPOINTER_ISA
// Quiet the warning about redefining the macro from isa.h.
# undef RC_ONE
# if __x86_64__
#   define RC_ONE (1ULL<<56)
# elif __arm64__ && __LP64__
#   define RC_ONE (objc_debug_isa_magic_value == 1 ? 1ULL<<56 : 1ULL<<45)
# elif __ARM_ARCH_7K__ >= 2  ||  (__arm64__ && !__LP64__)
#   define RC_ONE (1ULL<<25)
# else
#   error unknown architecture
# endif
#endif


void check_raw_pointer(id obj, Class cls)
{
    testassert(object_getClass(obj) == cls);
    testassert(!NONPOINTER(obj));

    uintptr_t isa = ISA(obj);
    testassertequal(ptrauth_strip((void *)isa, ptrauth_key_process_independent_data), (void *)cls);
    testassertequal((Class)(isa & objc_debug_isa_class_mask), cls);
    testassertequal(ptrauth_strip((void *)(isa & ~objc_debug_isa_class_mask), ptrauth_key_process_independent_data), 0);

    CFRetain(obj);
    testassert(ISA(obj) == isa);
    testassert([obj retainCount] == 2);
    [obj retain];
    testassert(ISA(obj) == isa);
    testassert([obj retainCount] == 3);
    CFRelease(obj);
    testassert(ISA(obj) == isa);
    testassert([obj retainCount] == 2);
    [obj release];
    testassert(ISA(obj) == isa);
    testassert([obj retainCount] == 1);
}


#if ! SUPPORT_NONPOINTER_ISA

int main()
{
#if OBJC_HAVE_NONPOINTER_ISA  ||  OBJC_HAVE_PACKED_NONPOINTER_ISA  ||  OBJC_HAVE_INDEXED_NONPOINTER_ISA
#   error wrong
#endif

    testprintf("Isa with index\n");
    id index_o = [NSObject new];
    check_raw_pointer(index_o, [NSObject class]);

    // These variables DO NOT exist without non-pointer isa support.
    testassert(!dlsym(RTLD_DEFAULT, "objc_absolute_packed_isa_class_mask"));
    testassert(!dlsym(RTLD_DEFAULT, "objc_absolute_indexed_isa_magic_mask"));
    testassert(!dlsym(RTLD_DEFAULT, "objc_absolute_indexed_isa_magic_value"));
    testassert(!dlsym(RTLD_DEFAULT, "objc_absolute_indexed_isa_index_mask"));
    testassert(!dlsym(RTLD_DEFAULT, "objc_absolute_indexed_isa_index_shift"));

    // These variables DO exist even without non-pointer isa support.
    testassert(dlsym(RTLD_DEFAULT, "objc_debug_isa_class_mask"));
    testassert(dlsym(RTLD_DEFAULT, "objc_debug_isa_magic_mask"));
    testassert(dlsym(RTLD_DEFAULT, "objc_debug_isa_magic_value"));

    succeed(__FILE__);
}

#else
// SUPPORT_NONPOINTER_ISA

void check_nonpointer(id obj, Class cls)
{
    testassertequal(object_getClass(obj), cls);
    testassert(NONPOINTER(obj));

    uintptr_t isa = ISA(obj);

    if (objc_debug_indexed_isa_magic_mask != 0) {
        // Indexed isa.
        testassertequal((isa & objc_debug_indexed_isa_magic_mask), objc_debug_indexed_isa_magic_value);
        testassert((isa & ~objc_debug_indexed_isa_index_mask) != 0);
        uintptr_t index = (isa & objc_debug_indexed_isa_index_mask) >> objc_debug_indexed_isa_index_shift;
        testassert(index < objc_indexed_classes_count);
        testassertequal(objc_indexed_classes[index], cls);
    } else {
        // Packed isa.
        testassertequal((Class)(isa & objc_debug_isa_class_mask), cls);
        testassert((Class)(isa & ~objc_debug_isa_class_mask) != 0);
        testassertequal((isa & objc_debug_isa_magic_mask), objc_debug_isa_magic_value);
    }

    CFRetain(obj);
    testassertequal(ISA(obj), isa + RC_ONE);
    testassertequal([obj retainCount], 2);
    [obj retain];
    testassertequal(ISA(obj), isa + RC_ONE*2);
    testassertequal([obj retainCount], 3);
    CFRelease(obj);
    testassertequal(ISA(obj), isa + RC_ONE);
    testassertequal([obj retainCount], 2);
    [obj release];
    testassertequal(ISA(obj), isa);
    testassertequal([obj retainCount], 1);
}


@interface Fake_OS_object : NSObject {
    int refcnt;
    int xref_cnt;
}
@end

@implementation Fake_OS_object
+(void)initialize {
    static bool initialized;
    if (!initialized) {
        initialized = true;
        testprintf("Nonpointer during +initialize\n");
        testassert(!NONPOINTER(self));
        id o = [Fake_OS_object new];
        check_nonpointer(o, self);
        [o release];
    }
}
@end

@interface Sub_OS_object : NSObject @end

@implementation Sub_OS_object
@end



int main()
{
    Class OS_object = objc_getClass("OS_object");
    class_setSuperclass([Sub_OS_object class], OS_object);

    uintptr_t isa;

#if SUPPORT_PACKED_ISA
# if !OBJC_HAVE_NONPOINTER_ISA  ||  !OBJC_HAVE_PACKED_NONPOINTER_ISA  ||  OBJC_HAVE_INDEXED_NONPOINTER_ISA
#   error wrong
# endif
    void *absoluteMask = (void *)&objc_absolute_packed_isa_class_mask;
#if __has_feature(ptrauth_calls)
    absoluteMask = ptrauth_strip(absoluteMask, ptrauth_key_process_independent_data);
#endif
    // absoluteMask should "cover" objc_debug_isa_class_mask
    testassert((objc_debug_isa_class_mask & (uintptr_t)absoluteMask) == objc_debug_isa_class_mask);
    // absoluteMask should only possibly differ in the high bits
    testassert((objc_debug_isa_class_mask & 0xffff) == ((uintptr_t)absoluteMask & 0xffff));

    // Indexed isa variables DO NOT exist on packed-isa platforms
    testassert(!dlsym(RTLD_DEFAULT, "objc_absolute_indexed_isa_magic_mask"));
    testassert(!dlsym(RTLD_DEFAULT, "objc_absolute_indexed_isa_magic_value"));
    testassert(!dlsym(RTLD_DEFAULT, "objc_absolute_indexed_isa_index_mask"));
    testassert(!dlsym(RTLD_DEFAULT, "objc_absolute_indexed_isa_index_shift"));

#elif SUPPORT_INDEXED_ISA
# if !OBJC_HAVE_NONPOINTER_ISA  ||  OBJC_HAVE_PACKED_NONPOINTER_ISA  ||  !OBJC_HAVE_INDEXED_NONPOINTER_ISA
#   error wrong
# endif
    testassert(objc_debug_indexed_isa_magic_mask == (uintptr_t)&objc_absolute_indexed_isa_magic_mask);
    testassert(objc_debug_indexed_isa_magic_value == (uintptr_t)&objc_absolute_indexed_isa_magic_value);
    testassert(objc_debug_indexed_isa_index_mask == (uintptr_t)&objc_absolute_indexed_isa_index_mask);
    testassert(objc_debug_indexed_isa_index_shift == (uintptr_t)&objc_absolute_indexed_isa_index_shift);

    // Packed isa variable DOES NOT exist on indexed-isa platforms.
    testassert(!dlsym(RTLD_DEFAULT, "objc_absolute_packed_isa_class_mask"));

#else
#   error unknown nonpointer isa format
#endif

    testprintf("Isa with index\n");
    id index_o = [Fake_OS_object new];
    check_nonpointer(index_o, [Fake_OS_object class]);

    testprintf("Weakly referenced\n");
    isa = ISA(index_o);
    id weak;
    objc_storeWeak(&weak, index_o);
    testassert(__builtin_popcountl(isa ^ ISA(index_o)) == 1);

    testprintf("Has associated references\n");
    id assoc = @"thing";
    isa = ISA(index_o);
    objc_setAssociatedObject(index_o, assoc, assoc, OBJC_ASSOCIATION_ASSIGN);
    testassert(__builtin_popcountl(isa ^ ISA(index_o)) == 1);

    testprintf("Isa without index\n");
    id raw_o = [OS_object alloc];
    check_raw_pointer(raw_o, [OS_object class]);


    id buf[4];
    id bufo = (id)buf;

    testprintf("Change isa 0 -> raw pointer\n");
    bzero(buf, sizeof(buf));
    object_setClass(bufo, [OS_object class]);
    check_raw_pointer(bufo, [OS_object class]);

    testprintf("Change isa 0 -> nonpointer\n");
    bzero(buf, sizeof(buf));
    object_setClass(bufo, [NSObject class]);
    check_nonpointer(bufo, [NSObject class]);

    testprintf("Change isa nonpointer -> nonpointer\n");
    testassert(NONPOINTER(bufo));
    _objc_rootRetain(bufo);
    testassert(_objc_rootRetainCount(bufo) == 2);
    object_setClass(bufo, [Fake_OS_object class]);
    testassert(_objc_rootRetainCount(bufo) == 2);
    _objc_rootRelease(bufo);
    testassert(_objc_rootRetainCount(bufo) == 1);
    check_nonpointer(bufo, [Fake_OS_object class]);

    testprintf("Change isa nonpointer -> raw pointer\n");
    // Retain count must be preserved.
    // Use root* to avoid OS_object's overrides.
    testassert(NONPOINTER(bufo));
    _objc_rootRetain(bufo);
    testassert(_objc_rootRetainCount(bufo) == 2);
    object_setClass(bufo, [OS_object class]);
    testassert(_objc_rootRetainCount(bufo) == 2);
    _objc_rootRelease(bufo);
    testassert(_objc_rootRetainCount(bufo) == 1);
    check_raw_pointer(bufo, [OS_object class]);

    testprintf("Change isa raw pointer -> nonpointer (doesn't happen)\n");
    testassert(!NONPOINTER(bufo));
    _objc_rootRetain(bufo);
    testassert(_objc_rootRetainCount(bufo) == 2);
    object_setClass(bufo, [Fake_OS_object class]);
    testassert(_objc_rootRetainCount(bufo) == 2);
    _objc_rootRelease(bufo);
    testassert(_objc_rootRetainCount(bufo) == 1);
    check_raw_pointer(bufo, [Fake_OS_object class]);

    testprintf("Change isa raw pointer -> raw pointer\n");
    testassert(!NONPOINTER(bufo));
    _objc_rootRetain(bufo);
    testassert(_objc_rootRetainCount(bufo) == 2);
    object_setClass(bufo, [Sub_OS_object class]);
    testassert(_objc_rootRetainCount(bufo) == 2);
    _objc_rootRelease(bufo);
    testassert(_objc_rootRetainCount(bufo) == 1);
    check_raw_pointer(bufo, [Sub_OS_object class]);


    succeed(__FILE__);
}

// SUPPORT_NONPOINTER_ISA
#endif
