#include "enumClasses.h"
#include "testroot.i"

// Animal
@implementation Animal

- (const char *)name { return "animal"; }
- (creature_size_t)size { return UnknownSize; }

@end

// Cat
@implementation Cat

- (const char *)name { return "cat"; }

@end
