// TEST_CONFIG MEM=mrc

#include "test.h"
#include <objc/NSObject.h>

@interface Test : NSObject {
@public
    char bytes[32-sizeof(void*)];
}
@end
@implementation Test
@end

@interface TestSELs : NSObject {
    SEL sel1, sel2, sel3;
}
@end
@implementation TestSELs

- (id)init {
    sel1 = @selector(sel1);
    sel2 = @selector(sel2);
    sel3 = @selector(sel3);
    return self;
}

- (void)compareWith: (TestSELs *)other {
    testassert(sel1 == other->sel1);
    testassert(sel2 == other->sel2);
    testassert(sel3 == other->sel3);
}

@end

int main()
{
    Test *o0 = [Test new];
    [o0 retain];
    Test *o1 = class_createInstance([Test class], 32);
    [o1 retain];
    id o2 = object_copy(o0, 0);
    id o3 = object_copy(o1, 0);
    id o4 = object_copy(o1, 32);

    testassert(malloc_size(o0) == 32);
    testassert(malloc_size(o1) == 64);
    testassert(malloc_size(o2) == 32);
    testassert(malloc_size(o3) == 32);
    testassert(malloc_size(o4) == 64);

    testassert([o0 retainCount] == 2);
    testassert([o1 retainCount] == 2);
    testassert([o2 retainCount] == 1);
    testassert([o3 retainCount] == 1);
    testassert([o4 retainCount] == 1);

    TestSELs *sels = [TestSELs new];
    TestSELs *selsCopy = object_copy(sels, 0);
    [sels compareWith: selsCopy];

    succeed(__FILE__);
}
