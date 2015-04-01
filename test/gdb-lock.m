// TEST_CFLAGS -framework Foundation

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/objc-gdb.h>

#include "test.h"

@interface Foo : NSObject
@end
@implementation Foo
- (void) foo
{
}

- (void) test: __attribute__((unused)) sender
{
    unsigned int x = 0;
    Method foo = class_getInstanceMethod([Foo class], @selector(foo));
    IMP fooIMP = method_getImplementation(foo);
    const char *fooTypes = method_getTypeEncoding(foo);
    while(1) {
        PUSH_POOL {
            char newSELName[100];
            sprintf(newSELName, "a%u", x++);
            SEL newSEL = sel_registerName(newSELName);
            class_addMethod([Foo class], newSEL, fooIMP, fooTypes);
            ((void(*)(id, SEL))objc_msgSend)(self, newSEL);
        } POP_POOL;
    }
}
@end

int main() {
    PUSH_POOL {
        [NSThread detachNewThreadSelector: @selector(test:) toTarget: [Foo new] withObject: nil];
        unsigned int x = 0;
        unsigned int lockCount = 0;
        while(1) {
            if (gdb_objc_isRuntimeLocked())
                lockCount++;
            x++;
            if (x > 1000000)
                break;
        }
        if (lockCount < 10) {
            fail("Runtime not locked very much.");
        }
    } POP_POOL;

    succeed(__FILE__);
    
    return 0;
}
