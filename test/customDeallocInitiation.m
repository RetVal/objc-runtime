// TEST_CONFIG MEM=mrc

#include "test.h"
#include <objc/NSObject.h>

static int deallocCalls;
static int initiateDeallocCalls;

@interface SuperTest: NSObject
@end

@implementation SuperTest

- (id)init {
    deallocCalls = 0;
    initiateDeallocCalls = 0;
    return self;
}

- (void)dealloc {
    deallocCalls++;
    [super dealloc];
}

- (void)_objc_initiateDealloc {
    initiateDeallocCalls++;
    [super dealloc];
}

@end

@interface SubTestRealizedBeforeSet: SuperTest @end
@implementation SubTestRealizedBeforeSet @end

@interface SubTestRealizedAfterSet: SuperTest @end
@implementation SubTestRealizedAfterSet @end

int main()
{
    // Realize classes and test the normal dealloc path.
    [[SuperTest new] release];
    testassertequal(deallocCalls, 1);
    testassertequal(initiateDeallocCalls, 0);

    [[SubTestRealizedBeforeSet new] release];
    testassertequal(deallocCalls, 1);
    testassertequal(initiateDeallocCalls, 0);

    Class DynamicSubTestCreatedBeforeSet = objc_allocateClassPair(
        [SuperTest class], "DynamicSubTestCreatedBeforeSet", 0);
    objc_registerClassPair(DynamicSubTestCreatedBeforeSet);
    [[DynamicSubTestCreatedBeforeSet new] release];
    testassertequal(deallocCalls, 1);
    testassertequal(initiateDeallocCalls, 0);

    // Set custom dealloc initiation and test the above classes again.
    _class_setCustomDeallocInitiation([SuperTest class]);

    [[SuperTest new] release];
    testassertequal(deallocCalls, 0);
    testassertequal(initiateDeallocCalls, 1);

    [[SubTestRealizedBeforeSet new] release];
    testassertequal(deallocCalls, 0);
    testassertequal(initiateDeallocCalls, 1);

    [[DynamicSubTestCreatedBeforeSet new] release];
    testassertequal(deallocCalls, 0);
    testassertequal(initiateDeallocCalls, 1);

    // Test subclasses that are realized or created after setting custom initiation.
    [[SubTestRealizedAfterSet new] release];
    testassertequal(deallocCalls, 0);
    testassertequal(initiateDeallocCalls, 1);

    Class DynamicSubTestCreatedAfterSet = objc_allocateClassPair(
        [SuperTest class], "DynamicSubTestCreatedAfterSet", 0);
    objc_registerClassPair(DynamicSubTestCreatedAfterSet);
    [[DynamicSubTestCreatedAfterSet new] release];
    testassertequal(deallocCalls, 0);
    testassertequal(initiateDeallocCalls, 1);

    succeed(__FILE__);
}
