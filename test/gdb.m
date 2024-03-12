// TEST_CFLAGS -Wno-deprecated-declarations

#define __APPLE_API_PRIVATE 1

#include "test.h"
#include "testroot.i"
#include <objc/objc-gdb.h>
#include <objc/maptable.h>
#include <objc/runtime.h>

#define SwiftV1MangledName4 "_TtC6Swiftt13SwiftV1Class4"
__attribute__((objc_runtime_name(SwiftV1MangledName4)))
@interface SwiftV1Class4 : TestRoot @end
@implementation SwiftV1Class4 @end

@interface UnrealizedClass: TestRoot @end
@implementation UnrealizedClass @end
extern void *OBJC_CLASS_$_UnrealizedClass;
Class UnrealizedClass_raw = (__bridge Class)(void *)&OBJC_CLASS_$_UnrealizedClass;

@interface ClassWithUnsignedClassRO: TestRoot @end
@implementation ClassWithUnsignedClassRO @end
extern void *OBJC_CLASS_$_ClassWithUnsignedClassRO;
Class ClassWithUnsignedClassRO_raw = (__bridge Class)(void *)&OBJC_CLASS_$_ClassWithUnsignedClassRO;

Class getFromNamedClassTable(const char *name) {
    void *cls = NXMapGet(gdb_objc_realized_classes, name);
    // Don't bother with trying to authenticate it for a test.
    cls = ptrauth_strip(cls, ptrauth_key_process_dependent_data);
    return (__bridge Class)cls;
}

int main()
{
    // Class hashes
    Class result;

    [TestRoot class];
    // Now class should be realized

    if (!testdyld3()) {
        // In dyld3 mode, the class will be in the launch closure and not in our table.
        result = getFromNamedClassTable("TestRoot");
        testassert(result);
        testassert(result == [TestRoot class]);
    }

    Class dynamic = objc_allocateClassPair([TestRoot class], "Dynamic", 0);
    objc_registerClassPair(dynamic);
    result = getFromNamedClassTable("Dynamic");
    testassert(result);
    testassert(result == dynamic);

    Class *realizedClasses = objc_copyRealizedClassList(NULL);
    bool foundTestRoot = false;
    bool foundDynamic = false;
    for (Class *cursor = realizedClasses; *cursor; cursor++) {
        if (*cursor == [TestRoot class])
            foundTestRoot = true;
        if (*cursor == dynamic)
            foundDynamic = true;
    }
    free(realizedClasses);
    testassert(foundTestRoot);
    testassert(foundDynamic);

    result = getFromNamedClassTable("DoesNotExist");
    testassert(!result);

    // Class structure decoding

    uintptr_t *maskp = (uintptr_t *)dlsym(RTLD_DEFAULT, "objc_debug_class_rw_data_mask");
    testassert(maskp);

    // Raw class names
    testassert(strcmp(objc_debug_class_getNameRaw([SwiftV1Class4 class]), SwiftV1MangledName4) == 0);
    testassert(strcmp(objc_debug_class_getNameRaw([TestRoot class]), "TestRoot") == 0);
    testassert(strcmp(objc_debug_class_getNameRaw(UnrealizedClass_raw), "UnrealizedClass") == 0);

    // Strip the class_ro pointer to ensure this call works with unsigned pointers. rdar://90415774
    // On archs without ptrauth, the strip will be a no-op and this ends up being a redundant test
    // of a second unrealized class.
    void **unsignedROContents = &OBJC_CLASS_$_ClassWithUnsignedClassRO;
    unsignedROContents[4] = ptrauth_strip(unsignedROContents[4], ptrauth_key_process_independent_data);
    testassert(strcmp(objc_debug_class_getNameRaw(ClassWithUnsignedClassRO_raw), "ClassWithUnsignedClassRO") == 0);

    succeed(__FILE__);
}
