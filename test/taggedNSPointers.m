// TEST_CFLAGS -framework Foundation

#include "test.h"
#include <objc/runtime.h>
#import <Foundation/Foundation.h>

#if __OBJC2__ && __LP64__

void testTaggedNumber()
{
    NSNumber *taggedNS = [NSNumber numberWithInt: 1234];
    CFNumberRef taggedCF = (CFNumberRef)objc_unretainedPointer(taggedNS);
    uintptr_t taggedAddress = (uintptr_t)taggedCF;
    int result;
    
    testassert( CFGetTypeID(taggedCF) == CFNumberGetTypeID() );
    
    CFNumberGetValue(taggedCF, kCFNumberIntType, &result);
    testassert(result == 1234);

    testassert(taggedAddress & 0x1); // make sure it is really tagged

    // do some generic object-y things to the taggedPointer instance
    CFRetain(taggedCF);
    CFRelease(taggedCF);
    
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    [dict setObject: taggedNS forKey: @"fred"];
    testassert(taggedNS == [dict objectForKey: @"fred"]);
    [dict setObject: @"bob" forKey: taggedNS];
    testassert([@"bob" isEqualToString: [dict objectForKey: taggedNS]]);
    
    NSNumber *i12345 = [NSNumber numberWithInt: 12345];
    NSNumber *i12346 = [NSNumber numberWithInt: 12346];
    NSNumber *i12347 = [NSNumber numberWithInt: 12347];
    
    NSArray *anArray = [NSArray arrayWithObjects: i12345, i12346, i12347, nil];
    testassert([anArray count] == 3);
    testassert([anArray indexOfObject: i12346] == 1);
    
    NSSet *aSet = [NSSet setWithObjects: i12345, i12346, i12347, nil];
    testassert([aSet count] == 3);
    testassert([aSet containsObject: i12346]);
    
    [taggedNS performSelector: @selector(intValue)];
    testassert(![taggedNS isProxy]);
    testassert([taggedNS isKindOfClass: [NSNumber class]]);
    testassert([taggedNS respondsToSelector: @selector(intValue)]);
    
    [taggedNS description];
}

int main()
{
    PUSH_POOL {
        testTaggedNumber(); // should be tested by CF... our tests are wrong, wrong, wrong.
    } POP_POOL;

    succeed(__FILE__);
}

// OBJC2 && __LP64__
#else
// not (OBJC2 && __LP64__)

    // Tagged pointers not supported. Crash if an NSNumber actually 
    // is a tagged pointer (which means this test is out of date).

int main() 
{
    PUSH_POOL {
        testassert(*(void **)objc_unretainedPointer([NSNumber numberWithInt:1234]));
    } POP_POOL;
    
    succeed(__FILE__);
}

#endif
