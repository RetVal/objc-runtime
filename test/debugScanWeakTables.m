// TEST_ENV OBJC_DEBUG_SCAN_WEAK_TABLES=YES OBJC_DEBUG_SCAN_WEAK_TABLES_INTERVAL_NANOSECONDS=1000
// TEST_CRASHES
// TEST_CONFIG MEM=mrc
/*
TEST_RUN_OUTPUT
objc\[\d+\]: Starting background scan of weak references.
objc\[\d+\]: Weak reference at 0x[0-9a-fA-F]+ contains 0x[0-9a-fA-F]+, should contain 0x[0-9a-fA-F]+
objc\[\d+\]: HALTED
END
*/

#include "test.h"
#include "testroot.i"

#include <time.h>

int main() {
    id obj = [TestRoot new];
    id weakLoc = nil;

    objc_storeWeak(&weakLoc, obj);
    memset_s(&weakLoc, sizeof(weakLoc), 0x35, sizeof(weakLoc));

    uint64_t startTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW_APPROX);
    while (clock_gettime_nsec_np(CLOCK_UPTIME_RAW_APPROX) - startTime < 5000000000) {
        sleep(1);
        printf(".\n");
    }

    fail("Should have crashed scanning weakLoc");
}