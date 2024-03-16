// TEST_CONFIG MEM=mrc OS=!exclavekit
// TEST_CFLAGS -framework CoreFoundation -framework Foundation

#include "test.h"
#include "testroot.i"

#include <Foundation/Foundation.h>
#include <CoreFoundation/CoreFoundation.h>
#include <objc/objc-internal.h>

@interface Simple : TestRoot @end
@implementation Simple @end

@interface CustomRefCount : TestRoot

- (NSUInteger)rcCalls;

@end

@implementation CustomRefCount
{
  NSUInteger retainCount;
  NSUInteger rcCalls;
}

- (id)init
{
  if ((self = [super init])) {
    retainCount = 1;
    rcCalls = 0;
  }
  return self;
}

- (id)retain
{
  ++retainCount;
  return self;
}

- (void)release
{
  if (!--retainCount) {
    [self dealloc];
  }
}

-(unsigned long) retainCount
{
  ++rcCalls;
  return retainCount;
}

- (NSUInteger)rcCalls
{
  return rcCalls;
}
@end

int main()
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"

  // First a type that uses NSObject reference counting
  Simple *s = [Simple new];

  testassertequal([s retainCount], 1);
  testassert(objc_isUniquelyReferenced(s));
  [s retain];
  testassertequal([s retainCount], 2);
  testassert(!objc_isUniquelyReferenced(s));
  [s release];
  testassert(objc_isUniquelyReferenced(s));

  // Now, a type that uses custom reference counting
  CustomRefCount *crc = [CustomRefCount new];

  NSUInteger baseRcCalls = [crc rcCalls];
  testassertequal([crc retainCount], 1);
  testassertequal([crc rcCalls], baseRcCalls + 1);
  testassert(objc_isUniquelyReferenced(crc));
  testassertequal([crc rcCalls], baseRcCalls + 2);
  [crc retain];
  testassert(!objc_isUniquelyReferenced(crc));
  testassertequal([crc rcCalls], baseRcCalls + 3);
  [crc release];
  testassert(objc_isUniquelyReferenced(crc));
  testassertequal([crc rcCalls], baseRcCalls + 4);

  // Next, a type that uses the tagged representation rather than a pointer
#if OBJC_HAVE_TAGGED_POINTERS
  if (_objc_taggedPointersEnabled()) {
    NSNumber *num = [NSNumber numberWithInt:42];

    testassert(!objc_isUniquelyReferenced(num));
    [num retain];
    testassert(!objc_isUniquelyReferenced(num));
    [num release];
    testassert(!objc_isUniquelyReferenced(num));
  }
#endif

  // Finally, some Core Foundation types
  CFMutableStringRef str = CFStringCreateMutable(kCFAllocatorDefault, 0);
  CFStringAppendCString(str, "Test string", kCFStringEncodingASCII);
  id strObj = (__bridge id)str;

  testassert(objc_isUniquelyReferenced(strObj));
  [strObj retain];
  testassert(!objc_isUniquelyReferenced(strObj));
  [strObj release];
  testassert(objc_isUniquelyReferenced(strObj));

#pragma clang diagnostic pop

  succeed(__FILE__);

  return 0;
}
