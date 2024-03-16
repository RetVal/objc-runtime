// TEST_CONFIG MEM=mrc
// TEST_CFLAGS -Wno-unused-variable

#include "test.h"
#include "swift-class-def.m"

SWIFT_STUB_CLASS(SwiftClass1, initSwiftClass);
SWIFT_STUB_CLASS(SwiftClass2, initSwiftClass);
SWIFT_STUB_CLASS(SwiftClass3, initSwiftClass);
SWIFT_STUB_CLASS(SwiftClass4, initSwiftClass);

SWIFT_CLASS(RealSwiftClass1, NSObject, realInit);
SWIFT_CLASS(RealSwiftClass2, NSObject, realInit);
SWIFT_CLASS(RealSwiftClass3, NSObject, realInit);
SWIFT_CLASS(RealSwiftClass4, NSObject, realInit);

int initCount = 0;

EXTERN_C Class realInit(Class cls __unused, void *arg __unused)
{
    fail("\"real\" initializer should not be called");
}

EXTERN_C Class initSwiftClass(Class cls, void *arg __unused)
{
    initCount++;

    Class HeapClass = (Class)malloc(OBJC_MAX_CLASS_SIZE);

    Class source = Nil;
    if (cls == RawSwiftClass1) source = RawRealSwiftClass1;
    if (cls == RawSwiftClass2) source = RawRealSwiftClass2;
    if (cls == RawSwiftClass3) source = RawRealSwiftClass3;
    if (cls == RawSwiftClass4) source = RawRealSwiftClass4;
    testassert(cls);

    memcpy(HeapClass, source, OBJC_MAX_CLASS_SIZE);
    // Re-sign the isa and super pointers in the new location.
    ((Class __ptrauth_objc_isa_pointer *)(void *)HeapClass)[0] = ((Class __ptrauth_objc_isa_pointer *)(void *)source)[0];
    ((Class __ptrauth_objc_super_pointer *)(void *)HeapClass)[1] = ((Class __ptrauth_objc_super_pointer *)(void *)source)[1];
    ((void *__ptrauth_objc_class_ro *)(void *)HeapClass)[4] = ((void * __ptrauth_objc_class_ro *)(void *)source)[4];

    _objc_realizeClassFromSwift(HeapClass, cls);

    return HeapClass;
}

int main()
{
    Class *classes = objc_copyClassList(NULL);
    testassert(classes);
    testassertequal(initCount, 4);

    int saw1 = 0;
    int saw2 = 0;
    int saw3 = 0;
    int saw4 = 0;
    for (Class *cursor = classes; *cursor; cursor++) {
        const char *name = class_getName(*cursor);
        if (strncmp(name, "RealSwiftClass", strlen("RealSwiftClass")) == 0) {
            switch (name[strlen("RealSwiftClass")]) {
            case '1': saw1++; break;
            case '2': saw2++; break;
            case '3': saw3++; break;
            case '4': saw4++; break;
            default: fail("Saw unknown RealSwiftClass %s", name);
            }
        }
    }

    testassertequal(saw1, 1);
    testassertequal(saw2, 1);
    testassertequal(saw3, 1);
    testassertequal(saw4, 1);

    free(classes);

    classes = objc_copyClassList(NULL);
    testassert(classes);
    testassertequal(initCount, 4);

    for (Class *cursor = classes; *cursor; cursor++) {
        const char *name = class_getName(*cursor);
        if (strncmp(name, "RealSwiftClass", strlen("RealSwiftClass")) == 0) {
            switch (name[strlen("RealSwiftClass")]) {
            case '1': saw1++; break;
            case '2': saw2++; break;
            case '3': saw3++; break;
            case '4': saw4++; break;
            default: fail("Saw unknown RealSwiftClass %s", name);
            }
        }
    }

    testassertequal(saw1, 2);
    testassertequal(saw2, 2);
    testassertequal(saw3, 2);
    testassertequal(saw4, 2);

    succeed(__FILE__);
}
