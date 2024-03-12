// TEST_CONFIG

#include "test.h"
#include <objc/NSObject.h>
#include <objc/objc-internal.h>

extern struct mach_header __dso_handle;

@interface Original1: NSObject {
    int originalIvar;
}
@end
@implementation Original1

- (void)originalMethod {}

- (void)overriddenMethod {
    fail("Original1's overriddenMethod should never be called");
}

+ (void)overriddenClassMethod {
    fail("Original1's overriddenClassMethod should never be called");
}

@end

@interface Root1: NSObject {
    int rootIvar1;
    int rootIvar2;
}
@end
@implementation Root1

static int calledRoot1OverriddenMethod;
- (void)overriddenMethod {
    calledRoot1OverriddenMethod++;
}

static int calledRoot1OverriddenClassMethod;
+ (void)overriddenClassMethod {
    calledRoot1OverriddenClassMethod++;
}

@end

@interface Original2: NSObject {
    int originalIvar;
}
@end
@implementation Original2

- (void)originalMethod {}

- (void)overriddenMethod {
    fail("Original2's overriddenMethod should never be called");
}

static int calledOriginal2OverriddenMethod;
+ (void)overriddenClassMethod {
    calledOriginal2OverriddenMethod++;
}

@end

@interface Root2: NSObject {
    int rootIvar1;
    int rootIvar2;
}
@end
@implementation Root2

static int calledRoot2OverriddenMethod;
- (void)overriddenMethod {
    calledRoot2OverriddenMethod++;
}

+ (void)overriddenClassMethod {
    fail("Root2's overriddenClassMethod should never be called.");
}

@end

@interface Sub1: Original1 @end
@implementation Sub1 @end
@interface Sub2: Original2 @end
@implementation Sub2 @end

extern char OBJC_CLASS_$_Original1;
extern char OBJC_CLASS_$_Root1;
extern char OBJC_METACLASS_$_Original1;
extern char OBJC_METACLASS_$_Root1;
extern char OBJC_CLASS_$_Original2;
extern char OBJC_CLASS_$_Root2;

int main() {
    _objc_patch_root_of_class(&__dso_handle, &OBJC_CLASS_$_Original1, &__dso_handle, &OBJC_CLASS_$_Root1);
    _objc_patch_root_of_class(&__dso_handle, &OBJC_METACLASS_$_Original1, &__dso_handle, &OBJC_METACLASS_$_Root1);
    _objc_patch_root_of_class(&__dso_handle, &OBJC_CLASS_$_Original2, &__dso_handle, &OBJC_CLASS_$_Root2);

    testassertequalstr(class_getName([Sub1 superclass]), "Root1");
    testassertequal((void *)class_getInstanceVariable([Sub1 class], "originalIvar"), NULL);
    testassert(class_getInstanceVariable([Sub1 class], "rootIvar1"));
    testassert(class_getInstanceVariable([Sub1 class], "rootIvar2"));
    testassert(!class_respondsToSelector([Sub1 class], @selector(originalMethod)));
    [[Sub1 new] overriddenMethod];
    testassert(calledRoot1OverriddenMethod);
    [Sub1 overriddenClassMethod];
    testassert(calledRoot1OverriddenClassMethod);

    testassertequalstr(class_getName([Sub2 superclass]), "Root2");
    testassertequal((void *)class_getInstanceVariable([Sub2 class], "originalIvar"), NULL);
    testassert(class_getInstanceVariable([Sub2 class], "rootIvar1"));
    testassert(class_getInstanceVariable([Sub2 class], "rootIvar2"));
    testassert(!class_respondsToSelector([Sub2 class], @selector(originalMethod)));
    [[Sub2 new] overriddenMethod];
    testassert(calledRoot2OverriddenMethod);
    [Sub2 overriddenClassMethod];
    testassert(calledOriginal2OverriddenMethod);

    succeed(__FILE__);
}