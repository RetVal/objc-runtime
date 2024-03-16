// TEST_CONFIG MEM=mrc
// TEST_ENV OBJC_DEBUG_WEAK_ERRORS=fatal
// TEST_CRASHES
/*
TEST_RUN_OUTPUT
objc\[\d+\]: __weak variable at 0x[0-9a-f]+ holds 0x[0-9a-f]+ instead of 0x[0-9a-f]+. This is probably incorrect use of objc_storeWeak\(\) and objc_loadWeak\(\).
objc\[\d+\]: HALTED
END
*/

#include "test.h"

#include <objc/NSObject.h>

int main()
{
    id weakVar = nil;
    @autoreleasepool {
        id obj = [NSObject new];
        objc_storeWeak(&weakVar, obj);
        weakVar = [NSObject new];
        [obj release];
    }

    fail("should have crashed");
}

