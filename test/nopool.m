// TEST_CONFIG MEM=mrc OS=!exclavekit

#include "test.h"
#include "testroot.i"

@implementation TestRoot (Loader)
+(void)load 
{
    [[TestRoot new] autorelease];
    testassertequal((int)TestRootAutorelease, 1);
    testassertequal((int)TestRootDealloc, 0);
}
@end

int main()
{
    // +load's autoreleased object should have deallocated
    testassertequal((int)TestRootDealloc, 1);

    [[TestRoot new] autorelease];
    testassertequal((int)TestRootAutorelease, 2);


    objc_autoreleasePoolPop(objc_autoreleasePoolPush());
    [[TestRoot new] autorelease];
    testassertequal((int)TestRootAutorelease, 3);


    testonthread(^{
        [[TestRoot new] autorelease];
        testassertequal((int)TestRootAutorelease, 4);
        testassertequal((int)TestRootDealloc, 1);
    });
    // thread's autoreleased object should have deallocated
    testassertequal((int)TestRootDealloc, 2);


    // Test no-pool autorelease after a pool was pushed and popped.
    // The simplest POOL_SENTINEL check during pop gets this wrong.
    testonthread(^{
        objc_autoreleasePoolPop(objc_autoreleasePoolPush());
        [[TestRoot new] autorelease];
        testassertequal((int)TestRootAutorelease, 5);
        testassertequal((int)TestRootDealloc, 2);
    });
    testassert(TestRootDealloc == 3
);
    succeed(__FILE__);
}
