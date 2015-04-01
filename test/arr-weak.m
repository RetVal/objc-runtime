// TEST_CONFIG MEM=mrc
// TEST_CRASHES
/*
TEST_RUN_OUTPUT
objc\[\d+\]: cannot form weak reference to instance \(0x[0-9a-f]+\) of class Crash
CRASHED: SIG(ILL|TRAP)
END
*/

#include "test.h"

#include <Foundation/NSObject.h>

static id weak;
static id weak2;
static bool did_dealloc;

@interface Test : NSObject @end
@implementation Test 
-(void)dealloc {
    testassert(weak == self);
    testassert(weak2 == self);

    testprintf("Weak references clear during super dealloc\n");
    testassert(weak2 != NULL);
    [super dealloc];
    testassert(weak2 == NULL);

    did_dealloc = true;
}
@end

@interface Crash : NSObject @end
@implementation Crash
-(void)dealloc {
    testassert(weak == self);
    testassert(weak2 == self);

    testprintf("Weak store crashes while deallocating\n");
    objc_storeWeak(&weak, self);
    fail("objc_storeWeak of deallocating value should have crashed");
    [super dealloc];
}
@end

int main()
{
    Test *obj = [Test new];
    Test *obj2 = [Test new];
    id result;

    testprintf("Weak assignment\n");
    result = objc_storeWeak(&weak, obj);
    testassert(result == obj);
    testassert(weak == obj);

    testprintf("Weak assignment to the same value\n");
    result = objc_storeWeak(&weak, obj);
    testassert(result == obj);
    testassert(weak == obj);

    testprintf("Weak assignment to different value\n");
    result = objc_storeWeak(&weak, obj2);
    testassert(result == obj2);
    testassert(weak == obj2);

    testprintf("Weak assignment to NULL\n");
    result = objc_storeWeak(&weak, NULL);
    testassert(result == NULL);
    testassert(weak == NULL);

    testprintf("Weak clear\n");

    result = objc_storeWeak(&weak, obj);
    testassert(result == obj);
    testassert(weak == obj);

    result = objc_storeWeak(&weak2, obj);
    testassert(result == obj);
    testassert(weak2 == obj);

    did_dealloc = false;
    [obj release];
    testassert(did_dealloc);
    testassert(weak == NULL);
    testassert(weak2 == NULL);

    Crash *obj3 = [Crash new];
    result = objc_storeWeak(&weak, obj3);
    testassert(result == obj3);
    testassert(weak == obj3);

    result = objc_storeWeak(&weak2, obj3);
    testassert(result == obj3);
    testassert(weak2 == obj3);

    [obj3 release];
    fail("should have crashed in -[Crash dealloc]");
}
