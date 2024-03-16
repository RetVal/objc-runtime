// Run test badPool as if it were built with an old SDK.

// TEST_CONFIG MEM=mrc OS=watchsimulator ARCH=x86_64
// TEST_CRASHES
// TEST_CFLAGS -DOLD=1 -Xlinker -platform_version -Xlinker watchos-simulator -Xlinker 2.0 -Xlinker 2.0 -mwatchos-simulator-version-min=2.0

/*
TEST_BUILD_OUTPUT
ld: warning: passed two min versions.*for platform.*
END

TEST_RUN_OUTPUT
objc\[\d+\]: Invalid or prematurely-freed autorelease pool 0x[0-9a-fA-f]+\. Set a breakpoint .*
objc\[\d+\]: Proceeding anyway.*
OK: badPool.m
END
*/

#include "badPool.m"
