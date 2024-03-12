// TEST_CONFIG OS=!macosx

#include "test.h"
#include "testroot.i"
#include <simd/simd.h>
#include <time.h>
#include <stdint.h>

#if !TARGET_OS_EXCLAVEKIT
#if TARGET_OS_OSX
#include <Cambria/Traps.h>
#include <Cambria/Cambria.h>
#endif
#endif // !TARGET_OS_EXCLAVEKIT

#ifndef TEST_NAME
#define TEST_NAME __FILE__
#endif

#if defined(__arm__) 
// rdar://8331406
#   define ALIGN_() 
#else
#   define ALIGN_() asm(".align 4");
#endif

@interface Super : TestRoot @end

@implementation Super

-(void)voidret_nop
{
    return;
}

-(void)voidret_nop2
{
    return;
}

-(id)idret_nop
{
    return nil;
}

-(long long)llret_nop
{
    return 0;
}

-(struct stret)stret_nop
{
    return STRET_RESULT;
}

-(double)fpret_nop
{
    return 0;
}

-(long double)lfpret_nop
{
    return 0;
}

-(vector_ulong2)vecret_nop
{
    return (vector_ulong2){0x1234567890abcdefULL, 0xfedcba0987654321ULL};
}

@end


@interface Sub : Super @end

@implementation Sub @end

static uint64_t hires_time()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return ((uint64_t)(1000000000)) * ts.tv_sec + ts.tv_nsec;
}

int main()
{

    // cached message performance
    // catches failure to cache or (abi=2) failure to fixup (#5584187)
    // fixme unless they all fail

    Sub *sub = [Sub new];

    // Some of these times have high variance on some compilers.
    // The errors we're trying to catch should be catastrophically slow,
    // so the margins here are generous to avoid false failures.

    // Use voidret because id return is too slow for perf test with ARC.

    // Pick smallest of voidret_nop and voidret_nop2 time
    // in the hopes that one of them didn't collide in the method cache.

    // ALIGN_ matches loop alignment to make -O0 work

#define TRIALS 50
#define MESSAGES 1000000

    enum {
        voidret_nop,
        voidret_nop2,
        llret_nop,
        stret_nop,
        fpret_nop,
        lfpret_nop,
        vecret_nop,
      
        timesCount
    };
    
    uint64_t times[timesCount];
    for (int i = 0; i < timesCount; i++)
        times[i] = UINT64_MAX;

    // Measure the time needed to send MESSAGES messages. On completion,
    // the minimum measured time is stored in the `times` array.
    //
    // Attempt to test with a clean method cache by flushing the class's
    // cache, then sending the message to be tested once before
    // measuring.
#define MEASURE(message)                                      \
    do {                                                      \
        _objc_flush_caches([sub class]);                      \
        [sub message];                                        \
        uint64_t startTime = hires_time();                    \
        ALIGN_();                                             \
        for (int i = 0; i < MESSAGES; i++)                    \
            [sub message];                                    \
        uint64_t totalTime = hires_time() - startTime;        \
        testprintf("trial: " #message "  %llu\n", totalTime); \
        if (totalTime < times[message])                       \
            times[message] = totalTime;                       \
    } while(0)
    
    // Measure each message TRIALS times. We take a minimum over many
    // trials rather than a simple average for two reasons:
    //
    // 1. If preemption or sudden system load makes a trial slow, it is not
    //    useful to incorporate that into the data. We want to reject those
    //    trials. There aren't transient events that will make a trial unusually
    //    *fast*, so the minimum is what we want to measure.
    // 2. Some hardware seems to take time to ramp up performance when suddenly
    //    placed under load. The first ~10 trials of a test run can be much
    //    slower than the rest, causing subsequent tests to be "too fast.'
    //
    // The baseline time comes from measuring voidret_nop and
    // voidret_nop2. We measure those between measuring each of the
    // other methods, to try to capture any variance.
    for (int i = 0; i < TRIALS; i++) {
        MEASURE(voidret_nop);
        MEASURE(voidret_nop2);

        MEASURE(llret_nop);

        MEASURE(voidret_nop);
        MEASURE(voidret_nop2);

        MEASURE(stret_nop);

        MEASURE(voidret_nop);
        MEASURE(voidret_nop2);

        MEASURE(fpret_nop);

        MEASURE(voidret_nop);
        MEASURE(voidret_nop2);

        MEASURE(vecret_nop);

        MEASURE(voidret_nop);
        MEASURE(voidret_nop2);

        MEASURE(lfpret_nop);
    }

    MEASURE(voidret_nop);
    MEASURE(voidret_nop2);

    testprintf("BASELINE: voidret  %llu\n", times[voidret_nop]);
    testprintf("BASELINE: voidret2  %llu\n", times[voidret_nop2]);
    
    // Take the min/max of the two baseline methods, multiplied/divided
    // by a fudge factor for the final range we'll accept as "good."
    // Running times can vary a lot so we have a generous fudge factor
    // to avoid false positives.
    #define FUDGE 3
    uint64_t minTargetTime = MIN(times[voidret_nop], times[voidret_nop2]) / FUDGE;
    uint64_t maxTargetTime = MAX(times[voidret_nop], times[voidret_nop2]) * FUDGE;
    
    testprintf("BASELINE: acceptable range is %llu - %llu\n", minTargetTime, maxTargetTime);
    
#define CHECK(message)                                                         \
    do {                                                                       \
        timecheck(#message " ", times[message], minTargetTime, maxTargetTime); \
    } while(0)
    
    CHECK(llret_nop);
    CHECK(stret_nop);
    CHECK(fpret_nop);
    CHECK(vecret_nop);

#if !TARGET_OS_EXCLAVEKIT
#if TARGET_OS_OSX
    // lpfret is ~10x slower than other msgSends on Rosetta due to using the
    // x87 stack for returning the value, so don't test it there.
    if (!oah_is_current_process_translated())
#endif
#endif
        CHECK(lfpret_nop);

    succeed(TEST_NAME);
}
