// TEST_CONFIG OS=!exclavekit

#include "test.h"

#include <dispatch/dispatch.h>
#include <mach/thread_act.h>
#include <mach/thread_policy.h>

static struct thread_basic_info
getThreadBasicInfo(mach_port_t thread_port)
{
    struct thread_basic_info thbi;
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    if (!thread_port) thread_port = pthread_mach_thread_np(pthread_self());

    kern_return_t kr = thread_info(thread_port, THREAD_BASIC_INFO,
            (thread_info_t)&thbi, &count);
    if (kr) {
       abort();
    }

    return thbi;
}

static struct policy_timeshare_info
getThreadTimeshareInfo(mach_port_t thread_port)
{
    struct policy_timeshare_info pti;
    mach_msg_type_number_t count = POLICY_TIMESHARE_INFO_COUNT;
    if (!thread_port) thread_port = pthread_mach_thread_np(pthread_self());

    kern_return_t kr = thread_info(thread_port, THREAD_SCHED_TIMESHARE_INFO,
            (thread_info_t)&pti, &count);
    if (kr) {
        abort();
    }

    return pti;
}

static struct policy_rr_info
getThreadRRInfo(mach_port_t thread_port)
{
    struct policy_rr_info pri;
    mach_msg_type_number_t count = POLICY_RR_INFO_COUNT;
    if (!thread_port) thread_port = pthread_mach_thread_np(pthread_self());

    kern_return_t kr = thread_info(thread_port, THREAD_SCHED_RR_INFO,
            (thread_info_t)&pri, &count);
    if (kr) {
        abort();
    }

    return pri;
}

// This function and the support functions above are borrowed from dispatch's
// test_lib.c.
static int currentThreadPriority()
{
    mach_port_t tp = MACH_PORT_NULL;
    int policy = getThreadBasicInfo(tp).policy;
    if (policy == POLICY_TIMESHARE) {
        return getThreadTimeshareInfo(tp).base_priority;
    } else if (policy == POLICY_RR) {
        return getThreadRRInfo(tp).base_priority;
    } else {
        __builtin_trap();
    }
}

static uint64_t now()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return ((uint64_t)(1000000000)) * ts.tv_sec + ts.tv_nsec;
}

static int mainThreadPriority;

enum State {
  Initial,
  RunningInitialize,
  MainThreadBlocked,
  DoneInitialize,
};

_Atomic enum State state;

static void waitState(enum State waitFor) {
    while(state != waitFor)
        usleep(1);
}

@interface TestClass: NSObject @end
@implementation TestClass

+ (void)initialize {
    int initialPriority = currentThreadPriority();
    testprintf("+initialize started with priority %d\n", initialPriority);

    state = RunningInitialize;
    waitState(MainThreadBlocked);

    int newPriority;
    uint64_t startTime = now();
    while (now() - startTime < 10000000000) {
        newPriority = currentThreadPriority();
        if (newPriority == mainThreadPriority)
            break;
        usleep(1);
    }

    testprintf("newPriority is %d\n", newPriority);
    testassertequal(newPriority, mainThreadPriority);
    state = DoneInitialize;
}

@end

int main() {
    mainThreadPriority = currentThreadPriority();
    testprintf("main thread priority is %d\n", mainThreadPriority);

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0);
    dispatch_async(queue, ^{
        [TestClass self];
    });

    waitState(RunningInitialize);
    state = MainThreadBlocked;
    [TestClass self];
    testprintf("state is %d\n", state);

    succeed(__FILE__);

    return 0;
}
