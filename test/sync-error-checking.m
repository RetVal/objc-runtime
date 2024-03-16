/*
TEST_CONFIG MEM=mrc
TEST_ENV OBJC_DEBUG_SYNC_ERRORS=1

TEST_RUN_OUTPUT
objc\[\d+\]: objc_sync_exit\(0x1\) returned error -1
OK: sync-error-checking.m
END
*/

#include "test.h"

#include <objc/objc-sync.h>

int main()
{
    // It's currently impossible for objc_sync_enter to return an error, so we
    // only test objc_sync_exit.
    objc_sync_exit((id)1);
    succeed(__FILE__);
}
