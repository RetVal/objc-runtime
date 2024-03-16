// TEST_CONFIG OS=!exclavekit
// TEST_CFLAGS -Os -framework Foundation
// TEST_DISABLED pending clang support for rdar://20530049

#include "test.h"
#include "testroot.i"

#include <objc/objc-internal.h>
#include <objc/objc-abi.h>
#include <Foundation/Foundation.h>

@interface TestObject : TestRoot @end
@implementation TestObject @end

@interface Tester : NSObject @end
@implementation Tester {
@public
    id ivar;
}

-(id) return0 {
    return ivar;
}
-(id) return1 {
    id x = ivar;
    [x self];
    return x;
}

@end

OBJC_EXPORT
id
objc_retainAutoreleasedReturnValue(id obj);

// Accept a value returned through a +0 autoreleasing convention for use at +0.
OBJC_EXPORT
id
objc_unsafeClaimAutoreleasedReturnValue(id obj);


int
main()
{
    TestObject *obj;
    Tester *tt = [Tester new];

#ifdef __x86_64__
    // need to get DYLD to resolve the stubs on x86
    PUSH_POOL {
        TestObject *warm_up = [[TestObject alloc] init];
        testassert(warm_up);
        warm_up = objc_retainAutoreleasedReturnValue(warm_up);
        warm_up = objc_unsafeClaimAutoreleasedReturnValue(warm_up);
        warm_up = nil;
    } POP_POOL;
#endif
    
    testprintf("  Successful +1 -> +1 handshake\n");
    
    PUSH_POOL {
        obj = [[TestObject alloc] init];
        testassert(obj);
        tt->ivar = obj;
        obj = nil;
        
        TestRootRetain = 0;
        TestRootRelease = 0;
        TestRootAutorelease = 0;
        TestRootDealloc = 0;

        TestObject *tmp = [tt return1];

        testassert(TestRootDealloc == 0);
        testassert(TestRootRetain == 1);
        testassert(TestRootRelease == 0);
        testassert(TestRootAutorelease == 0);

        tt->ivar = nil;
        testassert(TestRootDealloc == 0);
        testassert(TestRootRetain == 1);
        testassert(TestRootRelease == 1);
        testassert(TestRootAutorelease == 0);

        tmp = nil;
        testassert(TestRootDealloc == 1);
        testassert(TestRootRetain == 1);
        testassert(TestRootRelease == 2);
        testassert(TestRootAutorelease == 0);

    } POP_POOL;
    
    testprintf("  Successful +0 -> +0 handshake\n");
    
    PUSH_POOL {
        obj = [[TestObject alloc] init];
        testassert(obj);
        tt->ivar = obj;
        obj = nil;
        
        TestRootRetain = 0;
        TestRootRelease = 0;
        TestRootAutorelease = 0;
        TestRootDealloc = 0;

        __unsafe_unretained TestObject *tmp = [tt return0];

        testassert(TestRootDealloc == 0);
        testassert(TestRootRetain == 0);
        testassert(TestRootRelease == 0);
        testassert(TestRootAutorelease == 0);

        tmp = nil;
        testassert(TestRootDealloc == 0);
        testassert(TestRootRetain == 0);
        testassert(TestRootRelease == 0);
        testassert(TestRootAutorelease == 0);

        tt->ivar = nil;
        testassert(TestRootDealloc == 1);
        testassert(TestRootRetain == 0);
        testassert(TestRootRelease == 1);
        testassert(TestRootAutorelease == 0);

    } POP_POOL;

    
    testprintf("  Successful +1 -> +0 handshake\n");
    
    PUSH_POOL {
        obj = [[TestObject alloc] init];
        testassert(obj);
        tt->ivar = obj;
        obj = nil;
        
        TestRootRetain = 0;
        TestRootRelease = 0;
        TestRootAutorelease = 0;
        TestRootDealloc = 0;

        __unsafe_unretained TestObject *tmp = [tt return1];

        testassert(TestRootDealloc == 0);
        testassert(TestRootRetain == 1);
        testassert(TestRootRelease == 1);
        testassert(TestRootAutorelease == 0);

        tmp = nil;
        testassert(TestRootDealloc == 0);
        testassert(TestRootRetain == 1);
        testassert(TestRootRelease == 1);
        testassert(TestRootAutorelease == 0);

        tt->ivar = nil;
        testassert(TestRootDealloc == 1);
        testassert(TestRootRetain == 1);
        testassert(TestRootRelease == 2);
        testassert(TestRootAutorelease == 0);

    } POP_POOL;


    testprintf("  Successful +0 -> +1 handshake\n");
    
    PUSH_POOL {
        obj = [[TestObject alloc] init];
        testassert(obj);
        tt->ivar = obj;
        obj = nil;
        
        TestRootRetain = 0;
        TestRootRelease = 0;
        TestRootAutorelease = 0;
        TestRootDealloc = 0;

        TestObject *tmp = [tt return0];

        testassert(TestRootDealloc == 0);
        testassert(TestRootRetain == 1);
        testassert(TestRootRelease == 0);
        testassert(TestRootAutorelease == 0);

        tmp = nil;
        testassert(TestRootDealloc == 0);
        testassert(TestRootRetain == 1);
        testassert(TestRootRelease == 1);
        testassert(TestRootAutorelease == 0);

        tt->ivar = nil;
        testassert(TestRootDealloc == 1);
        testassert(TestRootRetain == 1);
        testassert(TestRootRelease == 2);
        testassert(TestRootAutorelease == 0);

    } POP_POOL;

    

    succeed(__FILE__);
    
    return 0;
}
