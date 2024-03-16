// TEST_CONFIG OS=!exclavekit MEM=mrc

// Ensure that our atfork handlers don't crash in the child if one of the internal locks used in @synchronized is held when we fork.

#include "test.h"

#include <objc/objc-sync.h>

void *thread(void *param)
{
    for (;;) {
        @synchronized((id)param) {
        }
    }
}

int main()
{
    // Spawn a bunch of threads and do a bunch of forks. We're checking:
    // 1. We don't crash if another thread held a lock in sDataLists.
    // 2. We don't stumble over a SyncData that still holds a lock but is marked
    //    as available for reuse.
    // Empirically, 1000 threads catches #1 on the first fork almost every time.
    // 10 forks is not enough to trigger #2 most of the time, but should be
    // enough to catch it reliably in testing when we test all OSes/archs, and
    // doing more than that just takes too long.

	#define THREAD_COUNT 1000
    // Spawn a ton of threads that will virtually guarantee that some thread is
    // holding one of the locks in sDataLists when we fork.
    for (uintptr_t i = 0; i < THREAD_COUNT; i++) {
        pthread_t pt;
        pthread_create(&pt, NULL, thread, (void *)i);
    }

    // Nest several synchronizations on the forking thread to make sure we're
    // clearing out the thread-level cache.
    for (uintptr_t i = 0; i < 10; i++)
        objc_sync_enter((id)(i + THREAD_COUNT));
    for (uintptr_t i = 0; i < 10; i++)
        objc_sync_exit((id)(i + THREAD_COUNT));

    // Fork and make sure the child doesn't crash.
    for (uintptr_t i = 0; i < 10; i++) {
        pid_t child;
        switch ((child = fork())) {
            case -1:
                fail("fork failed (errno %d %s)",
                     errno,
                     strerror(errno));
                abort();
            case 0:
                // In the child.
                for (uintptr_t i = THREAD_COUNT; i < THREAD_COUNT * 2; i++) {
                    @synchronized((id)i) {}
                }
                _exit(0);
            default: {
                // parent
                int result = 0;
                while (waitpid(child, &result, 0) < 0) {
                    if (errno != EINTR) {
                        fail("waitpid failed (errno %d %s)",
                             errno,
                             strerror(errno));
                    }
                }
                if (!WIFEXITED(result)) {
                    fail("child crashed (waitpid result %d)", result);
                }

                break;
            }
        }
    }

    succeed(__FILE__);
}
