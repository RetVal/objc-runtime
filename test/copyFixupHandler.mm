// TEST_CONFIG MEM=mrc

#define TEST_CALLS_OPERATOR_NEW
#include "test.h"
#include "testroot.i"
#include "swift-class-def.m"

#include <objc/objc-internal.h>

#include <vector>

static Class expectedOldClass;

static std::vector<Class> observedNewClasses1;
static void handler1(Class _Nonnull oldClass, Class _Nonnull newClass) {
    testprintf("%s(%p, %p)\n", __func__, oldClass, newClass);
    testassert(oldClass == expectedOldClass);
    observedNewClasses1.push_back(newClass);
}

static std::vector<Class> observedNewClasses2;
static void handler2(Class _Nonnull oldClass, Class _Nonnull newClass) {
    testprintf("%s(%p, %p)\n", __func__, oldClass, newClass);
    testassert(oldClass == expectedOldClass);
    observedNewClasses2.push_back(newClass);
}

static std::vector<Class> observedNewClasses3;
static void handler3(Class _Nonnull oldClass, Class _Nonnull newClass) {
    testprintf("%s(%p, %p)\n", __func__, oldClass, newClass);
    testassert(oldClass == expectedOldClass);
    observedNewClasses3.push_back(newClass);
}

EXTERN_C Class _objc_realizeClassFromSwift(Class, void *);

EXTERN_C Class init(Class cls, void *arg) {
    (void)arg;
    _objc_realizeClassFromSwift(cls, cls);
    return cls;
}

@interface SwiftRoot: TestRoot @end
SWIFT_CLASS(SwiftRoot, TestRoot, init);

int main()
{
    expectedOldClass = [SwiftRoot class];
    Class A = objc_allocateClassPair([RawSwiftRoot class], "A", 0);
    objc_registerClassPair(A);
    testassertequal(observedNewClasses1.size(), 0);
    testassertequal(observedNewClasses2.size(), 0);
    testassertequal(observedNewClasses3.size(), 0);
    
    _objc_setClassCopyFixupHandler(handler1);
    
    expectedOldClass = A;
    Class B = objc_allocateClassPair(A, "B", 0);
    objc_registerClassPair(B);
    testassertequal(observedNewClasses1.size(), 2);
    testassertequal(observedNewClasses2.size(), 0);
    testassertequal(observedNewClasses3.size(), 0);
    testassertequal(observedNewClasses1[0], B);
    
    _objc_setClassCopyFixupHandler(handler2);
    
    expectedOldClass = B;
    Class C = objc_allocateClassPair(B, "C", 0);
    objc_registerClassPair(C);
    testassertequal(observedNewClasses1.size(), 4);
    testassertequal(observedNewClasses2.size(), 2);
    testassertequal(observedNewClasses3.size(), 0);
    testassertequal(observedNewClasses1[2], C);
    testassertequal(observedNewClasses2[0], C);
    
    _objc_setClassCopyFixupHandler(handler3);
    
    expectedOldClass = C;
    Class D = objc_allocateClassPair(C, "D", 0);
    objc_registerClassPair(D);
    testassertequal(observedNewClasses1.size(), 6);
    testassertequal(observedNewClasses2.size(), 4);
    testassertequal(observedNewClasses3.size(), 2);
    testassertequal(observedNewClasses1[4], D);
    testassertequal(observedNewClasses2[2], D);
    testassertequal(observedNewClasses3[0], D);
    
    succeed(__FILE__);
}
