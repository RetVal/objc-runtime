/*
TEST_RUN_OUTPUT
objc\[\d+\]: Class Sub is implemented in both [^\s]+ \(0x[0-9a-f]+\) and [^\s]+ \(0x[0-9a-f]+\)\. One of the two will be used\. Which one is undefined\.
OK: readClassPair.m
END
 */

#include "test.h"
#include <objc/objc-internal.h>

// Reuse evil-class-def.m as a non-evil class definition.

#define EVIL_SUPER 0
#define EVIL_SUPER_META 0
#define EVIL_SUB 0
#define EVIL_SUB_META 0

#define OMIT_SUPER 1
#define OMIT_NL_SUPER 1
#define OMIT_SUB 1
#define OMIT_NL_SUB 1

#include "evil-class-def.m"

int main()
{
    // This definition is ABI and is never allowed to change.
    testassert(OBJC_MAX_CLASS_SIZE == 32*sizeof(void*));

    struct objc_image_info ii = { 0, 0 };

    // Read a root class.
    testassert(!objc_getClass("Super"));

    extern intptr_t OBJC_CLASS_$_Super[OBJC_MAX_CLASS_SIZE/sizeof(void*)];
    Class Super = objc_readClassPair((__bridge Class)(void*)&OBJC_CLASS_$_Super, &ii);
    testassert(Super);

    testassert(objc_getClass("Super") == Super);
    testassert(0 == strcmp(class_getName(Super), "Super"));
    testassert(class_getSuperclass(Super) == nil);
    testassert(class_getClassMethod(Super, @selector(load)));
    testassert(class_getInstanceMethod(Super, @selector(load)));
    testassert(class_getInstanceVariable(Super, "super_ivar"));
    testassert(class_getInstanceSize(Super) == sizeof(void*));
    [Super load];

    // Read a non-root class.
    testassert(!objc_getClass("Sub"));

    // Clang assumes too much alignment on this by default (rdar://problem/60881608),
    // so tell it that it's only as aligned as an intptr_t.
    extern _Alignas(intptr_t) intptr_t OBJC_CLASS_$_Sub[OBJC_MAX_CLASS_SIZE/sizeof(void*)];
    // Make a duplicate of class Sub for use later.
    intptr_t Sub2_buf[OBJC_MAX_CLASS_SIZE/sizeof(void*)];
    memcpy(Sub2_buf, &OBJC_CLASS_$_Sub, sizeof(Sub2_buf));
    // Re-sign the isa and super pointers in the new location.
    ((Class __ptrauth_objc_isa_pointer *)(void *)Sub2_buf)[0] = ((Class __ptrauth_objc_isa_pointer *)(void *)&OBJC_CLASS_$_Sub)[0];
    ((Class __ptrauth_objc_super_pointer *)(void *)Sub2_buf)[1] = ((Class __ptrauth_objc_super_pointer *)(void *)&OBJC_CLASS_$_Sub)[1];
    ((void *__ptrauth_objc_class_ro *)(void *)Sub2_buf)[4] = ((void * __ptrauth_objc_class_ro *)(void *)&OBJC_CLASS_$_Sub)[4];

    Class Sub = objc_readClassPair((__bridge Class)(void*)&OBJC_CLASS_$_Sub, &ii);
    testassert(Sub);

    testassert(0 == strcmp(class_getName(Sub), "Sub"));
    testassert(objc_getClass("Sub") == Sub);
    testassert(class_getSuperclass(Sub) == Super);
    testassert(class_getClassMethod(Sub, @selector(load)));
    testassert(class_getInstanceMethod(Sub, @selector(load)));
    testassert(class_getInstanceVariable(Sub, "sub_ivar"));
    testassert(class_getInstanceSize(Sub) == 2*sizeof(void*));
    [Sub load];

    // Reading a class whose name already exists succeeds
    // with a duplicate warning.
    Class Sub2 = objc_readClassPair((__bridge Class)(void*)Sub2_buf, &ii);
    testassert(Sub2);
    testassert(Sub2 != Sub);
    testassert(objc_getClass("Sub") == Sub);  // didn't change
    testassert(0 == strcmp(class_getName(Sub2), "Sub"));
    testassert(class_getSuperclass(Sub2) == Super);
    testassert(class_getClassMethod(Sub2, @selector(load)));
    testassert(class_getInstanceMethod(Sub2, @selector(load)));
    testassert(class_getInstanceVariable(Sub2, "sub_ivar"));
    testassert(class_getInstanceSize(Sub2) == 2*sizeof(void*));
    [Sub2 load];

    succeed(__FILE__);
}
