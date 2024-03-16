/*
TEST_CONFIG ARCH=arm64e
TEST_BUILD
    $C{COMPILE} $DIR/ptrauth.m -Wno-deprecated-objc-isa-usage -Wno-deprecated-declarations -framework Foundation -o ptrauth.exe
END
TEST_CRASHES
TEST_RUN_OUTPUT
doSomething
CRASHED: SIG.*
END
*/

#include "test.h"

#include <objc/NSObject.h>
#include <objc/runtime.h>

#include <stdio.h>

int count = 0;

@interface ParentClass : NSObject

- (void)doSomething;

@end

@implementation ParentClass

- (void)doSomething
{
    if (++count == 1) {
        printf("doSomething\n");
	fflush(stdout);
    }
}

@end

int main()
{
    for (int n = 0; n < 128; ++n) {
        char name[32];
        snprintf(name, sizeof(name), "PtrAuthTest%d", n);

        Class testClass = objc_allocateClassPair([ParentClass class], name, 0);

        // This should work, because the isa pointer will be signed
        id obj = [[testClass alloc] init];
        [obj doSomething];

        // Hacking the isa pointer to an unsigned value should cause a crash
        ((__bridge struct objc_object *)obj)->isa = testClass;
        [obj doSomething];
    }

    fail("should have crashed when attempting to invoke -doSomething");
}
