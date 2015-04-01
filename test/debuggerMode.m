// rdar://6401639, waiting for rdar://5648998
// TEST_DISABLED

#include "test.h"
#include <objc/objc.h>
#include <mach/mach.h>
#include <pthread.h>
#define _OBJC_PRIVATE_H_
#include <objc/objc-gdb.h>

#warning this test needs to be augmented for the side table machienery

@interface Super { id isa; } @end

@implementation Super
+(void)initialize { } 
+class { return self; }
+(int)method { return 1; }
+(int)method2 { return 1; }
@end


semaphore_t sema;

void *thread(void *arg __unused)
{
    objc_registerThreadWithCollector();

    semaphore_signal(sema);
    testprintf("hi\n");
    while (1) {
        [Super method];
        _objc_flush_caches(0, YES);
    }

    return NULL;
}


void stopAllThreads(void)
{
    mach_msg_type_number_t count, i;
    thread_act_array_t list;

    task_threads(mach_task_self(), &list, &count);
    for (i = 0; i < count; i++) {
        if (list[i] == mach_thread_self()) continue;
        thread_suspend(list[i]);
        mach_port_deallocate(mach_task_self(), list[i]);
    }
}

void startAllThreads(void)
{
    mach_msg_type_number_t count, i;
    thread_act_array_t list;

    task_threads(mach_task_self(), &list, &count);
    for (i = 0; i < count; i++) {
        if (list[i] == mach_thread_self()) continue;
        thread_resume(list[i]);
        mach_port_deallocate(mach_task_self(), list[i]);
    }
}


static void cycle(int mode, int *good, int *bad)
{
    stopAllThreads();
    if (gdb_objc_startDebuggerMode(mode)) {
        testprintf("good\n");
        [Super method];
        [Super method2];
        if (mode == OBJC_DEBUGMODE_FULL) {
            // will crash without full write locks
            _objc_flush_caches(0, YES);
        }
        gdb_objc_endDebuggerMode();
        ++*good;
    } else {
        testprintf("bad\n");
        ++*bad;
    }
    startAllThreads();
    sched_yield();
}


int main()
{
#define STOPS 10000
#define THREADS 1
    int i;

    [Super class];

    testassert(STOPS > 200);

    // Uncontended debugger mode
    testassert(gdb_objc_startDebuggerMode(0));
    gdb_objc_endDebuggerMode();

    // Uncontended full debugger mode
    testassert(gdb_objc_startDebuggerMode(OBJC_DEBUGMODE_FULL));
    gdb_objc_endDebuggerMode();

    // Nested debugger mode
    testassert(gdb_objc_startDebuggerMode(0));
    testassert(gdb_objc_startDebuggerMode(0));
    gdb_objc_endDebuggerMode();
    gdb_objc_endDebuggerMode();

    // Nested full debugger mode
    testassert(gdb_objc_startDebuggerMode(OBJC_DEBUGMODE_FULL));
    testassert(gdb_objc_startDebuggerMode(OBJC_DEBUGMODE_FULL));
    gdb_objc_endDebuggerMode();
    gdb_objc_endDebuggerMode();

    // Check that debugger mode sometimes works and sometimes doesn't
    // when contending with another runtime-manipulating thread.

    semaphore_create(mach_task_self(), &sema, 0, 0);

    for (i = 0; i < THREADS; i++) {
        pthread_t th;
        pthread_create(&th, NULL, &thread, NULL);
        semaphore_wait(sema);
    }

    testprintf("go\n");

    int good0 = 0, bad0 = 0;
    for (i = 0; i < STOPS; i++) {
        cycle(0, &good0, &bad0);
    }
    testprintf("good0 %d, bad0 %d\n", good0, bad0);

    int goodF = 0, badF = 0;
    for (i = 0; i < STOPS; i++) {
        cycle(OBJC_DEBUGMODE_FULL, &goodF, &badF);
    }
    testprintf("goodF %d, badF %d\n", goodF, badF);

    // Require at least 1% each of good and bad. 
    // Also require more than one each (exactly one is likely 
    // a bug wherein the locks got stuck the first time).
    // Also require that FULL worked less often.

    if (good0 > STOPS/100  &&  bad0 > STOPS/100  &&  good0 > 1  &&  bad0 > 1 &&
        goodF > STOPS/100  &&  badF > STOPS/100  &&  goodF > 1  &&  badF > 1
#ifdef __OBJC2__
        && good0 > goodF  /* not reliable enough in old runtime */
#endif
        )
    {
        succeed(__FILE__);
    }

    fail("good0=%d/%d bad0=%d/%d goodF=%d/%d badF=%d/%d (required at least %d/%d good)", 
         good0, STOPS, bad0, STOPS, goodF, STOPS, badF, STOPS, STOPS/100, STOPS);
}
