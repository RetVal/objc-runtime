// TEST_CONFIG MEM=mrc
// TEST_CFLAGS -Os

#include "test.h"
#include "testroot.i"

#include <objc/objc-internal.h>
#include <objc/objc-abi.h>

@interface TestObject : TestRoot @end
@implementation TestObject @end


// MAGIC and NOT_MAGIC each call two functions
// with or without the magic instruction sequence, respectively.
//
// tmp = first(obj);
// magic, or not;
// tmp = second(tmp);

#if __arm__

#define NOT_MAGIC(first, second)                \
    tmp = first(obj);                           \
    asm volatile("mov r8, r8");                 \
    tmp = second(tmp);

#define MAGIC(first, second)                    \
    tmp = first(obj);                           \
    asm volatile("mov r7, r7");                 \
    tmp = second(tmp);

// arm
#elif __arm64__

#define NO_NOP(first, second)                   \
    tmp = first(obj);                           \
    tmp = second(tmp);

#define WITH_NOP(first, second)                 \
    tmp = first(obj);                           \
    asm volatile("mov x29, x29");               \
    tmp = second(tmp);

#define WITH_BAD_NOP(first, second)             \
    tmp = first(obj);                           \
    asm volatile("mov x28, x28");               \
    tmp = second(tmp);

#define TWO_NOPS(first, second)                 \
    tmp = first(obj);                           \
    asm volatile("mov x29, x29");               \
    asm volatile("mov x28, x28");               \
    tmp = second(tmp);

#define TWO_BAD_NOPS(first, second)                 \
    tmp = first(obj);                           \
    asm volatile("mov x28, x28");               \
    asm volatile("mov x28, x28");               \
    tmp = second(tmp);

// arm64
#elif __x86_64__

#define NOT_MAGIC(first, second) \
    tmp = first(obj);            \
    asm volatile("nop");         \
    tmp = second(tmp);

#define MAGIC(first, second) \
    tmp = first(obj);        \
    tmp = second(tmp);

// x86_64
#elif __i386__

#define NOT_MAGIC(first, second) \
    tmp = first(obj);            \
    tmp = second(tmp);

#define MAGIC(first, second)                             \
    asm volatile("\n subl $16, %%esp"                    \
                 "\n movl %[obj], (%%esp)"               \
                 "\n call _" #first                      \
                 "\n"                                    \
                 "\n movl %%ebp, %%ebp"                  \
                 "\n"                                    \
                 "\n movl %%eax, (%%esp)"                \
                 "\n call _" #second                     \
                 "\n movl %%eax, %[tmp]"                 \
                 "\n addl $16, %%esp"                    \
                 : [tmp] "=r" (tmp)                      \
                 : [obj] "r" (obj)                       \
                 : "eax", "edx", "ecx", "cc", "memory")

// i386
#else

#error unknown architecture

#endif

#if __arm64__
#define HAS_RETURNADDR_ELISION 1
#endif

// Define a custom assert macro for the refcounts that includes more info about
// the test being run.
unsigned retainCountFailures = 0;
static void checkRetainCount(unsigned long actual, unsigned long expected,
                             id obj, const char *actualName,
                             const char *function, const char *description,
                             int line) {
    if (actual != expected) {
        fprintf(stderr, "BAD: Incorrect refcount testing %s(%s), %s=%ld, expected %ld, obj %p at %s:%d\n",
                function, description, actualName, actual, expected, obj, __FILE__, line);
        retainCountFailures++;
    } else {
        testprintf("%s(%s), %s=%ld\n", function, description, actualName, actual);
    }
}

#define CHECK_RETAIN_COUNT(actual, expected) \
    checkRetainCount(actual, expected, obj, #actual, __func__, description, __LINE__)

#pragma clang diagnostic ignored "-Wunused-function"

static void testSuccessful1_1(const char *description, void (^block)(id, id *)) {
    testprintf("  Successful +1 -> +1 handshake\n");

    PUSH_POOL {
        TestObject *obj = [[TestObject alloc] init];
        TestObject *tmp;
        testassert(obj);

        TestRootRetain = 0;
        TestRootRelease = 0;
        TestRootAutorelease = 0;
        TestRootDealloc = 0;

        block(obj, &tmp);

        CHECK_RETAIN_COUNT(TestRootDealloc, 0);
        CHECK_RETAIN_COUNT(TestRootRetain, 0);
        CHECK_RETAIN_COUNT(TestRootRelease, 0);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 0);

        [tmp release];
        CHECK_RETAIN_COUNT(TestRootDealloc, 1);
        CHECK_RETAIN_COUNT(TestRootRetain, 0);
        CHECK_RETAIN_COUNT(TestRootRelease, 1);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 0);

    } POP_POOL;
}

static void testSuccessful1_1noNOP(const char *description, void (^block)(id, id *)) {
    testprintf("  Successful +1 -> +1 handshake\n");

    PUSH_POOL {
        TestObject *obj = [[TestObject alloc] init];
        TestObject *tmp;
        testassert(obj);

        TestRootRetain = 0;
        TestRootRelease = 0;
        TestRootAutorelease = 0;
        TestRootDealloc = 0;

        block(obj, &tmp);

        // no-NOP claim on an object with overridden RR methods will still
        // autorelease, but that autorelease will then be undone in the claim,
        // so we'll dealloc before the pool ends.
        CHECK_RETAIN_COUNT(TestRootDealloc, 0);
        CHECK_RETAIN_COUNT(TestRootRetain, 0);
        CHECK_RETAIN_COUNT(TestRootRelease, 0);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 1);

        [tmp release];
        CHECK_RETAIN_COUNT(TestRootDealloc, 1);
        CHECK_RETAIN_COUNT(TestRootRetain, 0);
        CHECK_RETAIN_COUNT(TestRootRelease, 1);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 1);

    } POP_POOL;
}

static void testUnsuccessful1_1(const char *description, void (^block)(id, id *)) {
    testprintf("Unsuccessful +1 -> +1 handshake\n");

    TestObject *obj = [[TestObject alloc] init];
    PUSH_POOL {
        TestObject *tmp;
        testassert(obj);

        TestRootRetain = 0;
        TestRootRelease = 0;
        TestRootAutorelease = 0;
        TestRootDealloc = 0;

        block(obj, &tmp);

        CHECK_RETAIN_COUNT(TestRootDealloc, 0);
        CHECK_RETAIN_COUNT(TestRootRetain, 1);
        CHECK_RETAIN_COUNT(TestRootRelease, 0);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 1);

        [tmp release];
        CHECK_RETAIN_COUNT(TestRootDealloc, 0);
        CHECK_RETAIN_COUNT(TestRootRetain, 1);
        CHECK_RETAIN_COUNT(TestRootRelease, 1);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 1);

    } POP_POOL;
    CHECK_RETAIN_COUNT(TestRootDealloc, 1);
    CHECK_RETAIN_COUNT(TestRootRetain, 1);
    CHECK_RETAIN_COUNT(TestRootRelease, 2);
    CHECK_RETAIN_COUNT(TestRootAutorelease, 1);
}

void testSuccessful0_1noNOP(const char *description, void (^block)(id, id *)) {
    testprintf("  Successful +0 -> +1 handshake\n");

    PUSH_POOL {
        TestObject *obj = [[TestObject alloc] init];
        TestObject *tmp;
        testassert(obj);

        TestRootRetain = 0;
        TestRootRelease = 0;
        TestRootAutorelease = 0;
        TestRootDealloc = 0;

        block(obj, &tmp);

        // no-NOP claim on an object with overridden RR methods will still
        // autorelease, but that autorelease will then be undone in the claim,
        // so we'll dealloc before the pool ends.
        CHECK_RETAIN_COUNT(TestRootDealloc, 0);
        CHECK_RETAIN_COUNT(TestRootRetain, 1);
        CHECK_RETAIN_COUNT(TestRootRelease, 0);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 1);

        [tmp release];
        CHECK_RETAIN_COUNT(TestRootDealloc, 0);
        CHECK_RETAIN_COUNT(TestRootRetain, 1);
        CHECK_RETAIN_COUNT(TestRootRelease, 1);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 1);

        [tmp release];
        CHECK_RETAIN_COUNT(TestRootDealloc, 1);
        CHECK_RETAIN_COUNT(TestRootRetain, 1);
        CHECK_RETAIN_COUNT(TestRootRelease, 2);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 1);

    } POP_POOL;
}

void testSuccessful0_1(const char *description, void (^block)(id, id *)) {
    testprintf("  Successful +0 -> +1 handshake\n");

    PUSH_POOL {
        TestObject *obj = [[TestObject alloc] init];
        TestObject *tmp;
        testassert(obj);

        TestRootRetain = 0;
        TestRootRelease = 0;
        TestRootAutorelease = 0;
        TestRootDealloc = 0;

        block(obj, &tmp);

        CHECK_RETAIN_COUNT(TestRootDealloc, 0);
        CHECK_RETAIN_COUNT(TestRootRetain, 1);
        CHECK_RETAIN_COUNT(TestRootRelease, 0);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 0);

        [tmp release];
        CHECK_RETAIN_COUNT(TestRootDealloc, 0);
        CHECK_RETAIN_COUNT(TestRootRetain, 1);
        CHECK_RETAIN_COUNT(TestRootRelease, 1);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 0);

        [tmp release];
        CHECK_RETAIN_COUNT(TestRootDealloc, 1);
        CHECK_RETAIN_COUNT(TestRootRetain, 1);
        CHECK_RETAIN_COUNT(TestRootRelease, 2);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 0);

    } POP_POOL;
}

void testUnsuccessful0_1(const char *description, void (^block)(id, id *)) {
    testprintf("Unsuccessful +0 -> +1 handshake\n");

    TestObject *obj = [[TestObject alloc] init];
    PUSH_POOL {
        TestObject *tmp;
        testassert(obj);

        TestRootRetain = 0;
        TestRootRelease = 0;
        TestRootAutorelease = 0;
        TestRootDealloc = 0;

        block(obj, &tmp);

        CHECK_RETAIN_COUNT(TestRootDealloc, 0);
        CHECK_RETAIN_COUNT(TestRootRetain, 2);
        CHECK_RETAIN_COUNT(TestRootRelease, 0);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 1);

        [tmp release];
        CHECK_RETAIN_COUNT(TestRootDealloc, 0);
        CHECK_RETAIN_COUNT(TestRootRetain, 2);
        CHECK_RETAIN_COUNT(TestRootRelease, 1);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 1);

        [tmp release];
        CHECK_RETAIN_COUNT(TestRootDealloc, 0);
        CHECK_RETAIN_COUNT(TestRootRetain, 2);
        CHECK_RETAIN_COUNT(TestRootRelease, 2);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 1);

    } POP_POOL;
    CHECK_RETAIN_COUNT(TestRootDealloc, 1);
    CHECK_RETAIN_COUNT(TestRootRetain, 2);
    CHECK_RETAIN_COUNT(TestRootRelease, 3);
    CHECK_RETAIN_COUNT(TestRootAutorelease, 1);
}

void testSuccessful1_0(const char *description, void (^block)(id, id *)) {
    testprintf("  Successful +1 -> +0 handshake\n");

    PUSH_POOL {
        TestObject *obj = [[[TestObject alloc] init] retain];
        TestObject *tmp;
        testassert(obj);

        TestRootRetain = 0;
        TestRootRelease = 0;
        TestRootAutorelease = 0;
        TestRootDealloc = 0;

        block(obj, &tmp);

        CHECK_RETAIN_COUNT(TestRootDealloc, 0);
        CHECK_RETAIN_COUNT(TestRootRetain, 0);
        CHECK_RETAIN_COUNT(TestRootRelease, 1);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 0);

        [tmp release];
        CHECK_RETAIN_COUNT(TestRootDealloc, 1);
        CHECK_RETAIN_COUNT(TestRootRetain, 0);
        CHECK_RETAIN_COUNT(TestRootRelease, 2);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 0);

    } POP_POOL;
}

void testSuccessful1_0noNOP(const char *description, void (^block)(id, id *)) {
    testprintf("  Successful +1 -> +0 handshake\n");

    PUSH_POOL {
        TestObject *obj = [[[TestObject alloc] init] retain];
        TestObject *tmp;
        testassert(obj);

        TestRootRetain = 0;
        TestRootRelease = 0;
        TestRootAutorelease = 0;
        TestRootDealloc = 0;

        block(obj, &tmp);

        // no-NOP claim on an object with overridden RR methods will still
        // autorelease, but that autorelease will then be undone in the claim,
        // so we'll dealloc before the pool ends.
        CHECK_RETAIN_COUNT(TestRootDealloc, 0);
        CHECK_RETAIN_COUNT(TestRootRetain, 0);
        CHECK_RETAIN_COUNT(TestRootRelease, 1);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 1);

        [tmp release];
        CHECK_RETAIN_COUNT(TestRootDealloc, 1);
        CHECK_RETAIN_COUNT(TestRootRetain, 0);
        CHECK_RETAIN_COUNT(TestRootRelease, 2);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 1);

    } POP_POOL;
}

void testUnsuccessful1_0(const char *description, void (^block)(id, id *)) {
    testprintf("Unsuccessful +1 -> +0 handshake\n");

        TestObject *obj = [[[TestObject alloc] init] retain];
    PUSH_POOL {
        TestObject *tmp;
        testassert(obj);

        TestRootRetain = 0;
        TestRootRelease = 0;
        TestRootAutorelease = 0;
        TestRootDealloc = 0;

        block(obj, &tmp);

        CHECK_RETAIN_COUNT(TestRootDealloc, 0);
        CHECK_RETAIN_COUNT(TestRootRetain, 0);
        CHECK_RETAIN_COUNT(TestRootRelease, 0);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 1);

        [tmp release];
        CHECK_RETAIN_COUNT(TestRootDealloc, 0);
        CHECK_RETAIN_COUNT(TestRootRetain, 0);
        CHECK_RETAIN_COUNT(TestRootRelease, 1);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 1);

    } POP_POOL;
    CHECK_RETAIN_COUNT(TestRootDealloc, 1);
    CHECK_RETAIN_COUNT(TestRootRetain, 0);
    CHECK_RETAIN_COUNT(TestRootRelease, 2);
    CHECK_RETAIN_COUNT(TestRootAutorelease, 1);
}

void testSuccessful0_0(const char *description, void (^block)(id, id *)) {
    testprintf("  Successful +0 -> +0 handshake\n");

    PUSH_POOL {
        TestObject *obj = [[TestObject alloc] init];
        TestObject *tmp;
        testassert(obj);

        TestRootRetain = 0;
        TestRootRelease = 0;
        TestRootAutorelease = 0;
        TestRootDealloc = 0;

        block(obj, &tmp);

#if HAS_RETURNADDR_ELISION
        CHECK_RETAIN_COUNT(TestRootDealloc, 0);
        CHECK_RETAIN_COUNT(TestRootRetain, 1);
        CHECK_RETAIN_COUNT(TestRootRelease, 1);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 0);

        [tmp release];
        CHECK_RETAIN_COUNT(TestRootDealloc, 1);
        CHECK_RETAIN_COUNT(TestRootRetain, 1);
        CHECK_RETAIN_COUNT(TestRootRelease, 2);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 0);
#else
        CHECK_RETAIN_COUNT(TestRootDealloc, 0);
        CHECK_RETAIN_COUNT(TestRootRetain, 0);
        CHECK_RETAIN_COUNT(TestRootRelease, 0);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 0);

        [tmp release];
        CHECK_RETAIN_COUNT(TestRootDealloc, 1);
        CHECK_RETAIN_COUNT(TestRootRetain, 0);
        CHECK_RETAIN_COUNT(TestRootRelease, 1);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 0);
#endif
    } POP_POOL;
}

void testSuccessful0_0noNOP(const char *description, void (^block)(id, id *)) {
    testprintf("  Successful +0 -> +0 handshake\n");

    PUSH_POOL {
        TestObject *obj = [[TestObject alloc] init];
        TestObject *tmp;
        testassert(obj);

        TestRootRetain = 0;
        TestRootRelease = 0;
        TestRootAutorelease = 0;
        TestRootDealloc = 0;

        block(obj, &tmp);

        // no-NOP claim on an object with overridden RR methods will still
        // autorelease, but that autorelease will then be undone in the claim,
        // so we'll dealloc before the pool ends.
        CHECK_RETAIN_COUNT(TestRootDealloc, 0);
        CHECK_RETAIN_COUNT(TestRootRetain, 1);
        CHECK_RETAIN_COUNT(TestRootRelease, 1);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 1);

        [tmp release];
        CHECK_RETAIN_COUNT(TestRootDealloc, 1);
        CHECK_RETAIN_COUNT(TestRootRetain, 1);
        CHECK_RETAIN_COUNT(TestRootRelease, 2);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 1);
    } POP_POOL;
}

void testUnsuccessful0_0(const char *description, void (^block)(id, id *)) {
    testprintf("Unsuccessful +0 -> +0 handshake\n");

    TestObject *obj = [[TestObject alloc] init];
    PUSH_POOL {
        TestObject *tmp;
        testassert(obj);

        TestRootRetain = 0;
        TestRootRelease = 0;
        TestRootAutorelease = 0;
        TestRootDealloc = 0;

        block(obj, &tmp);

        CHECK_RETAIN_COUNT(TestRootDealloc, 0);
        CHECK_RETAIN_COUNT(TestRootRetain, 1);
        CHECK_RETAIN_COUNT(TestRootRelease, 0);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 1);

        [tmp release];
        CHECK_RETAIN_COUNT(TestRootDealloc, 0);
        CHECK_RETAIN_COUNT(TestRootRetain, 1);
        CHECK_RETAIN_COUNT(TestRootRelease, 1);
        CHECK_RETAIN_COUNT(TestRootAutorelease, 1);

    } POP_POOL;
    CHECK_RETAIN_COUNT(TestRootDealloc, 1);
    CHECK_RETAIN_COUNT(TestRootRetain, 1);
    CHECK_RETAIN_COUNT(TestRootRelease, 2);
    CHECK_RETAIN_COUNT(TestRootAutorelease, 1);
}

void testRepeatedUnsuccessful(void) {
    testprintf("Repeated unsuccessful handshake\n");
    TestObject *obj = [[TestObject alloc] init];
    testassert(obj);

    TestRootRetain = 0;
    TestRootRelease = 0;
    TestRootAutorelease = 0;
    TestRootDealloc = 0;

    PUSH_POOL {
        objc_retainAutoreleaseReturnValue(obj);
        objc_retainAutoreleaseReturnValue(obj);
        objc_retainAutoreleaseReturnValue(obj);
        // Push and pop an inner pool to clear out the TLS.
        PUSH_POOL
        POP_POOL
    } POP_POOL

    const char *description = "";

    CHECK_RETAIN_COUNT(TestRootDealloc, 0);
    CHECK_RETAIN_COUNT(TestRootRetain, 3);
    CHECK_RETAIN_COUNT(TestRootRelease, 3);
    CHECK_RETAIN_COUNT(TestRootAutorelease, 3);

    [obj release];

    CHECK_RETAIN_COUNT(TestRootDealloc, 1);
    CHECK_RETAIN_COUNT(TestRootRetain, 3);
    CHECK_RETAIN_COUNT(TestRootRelease, 4);
    CHECK_RETAIN_COUNT(TestRootAutorelease, 3);
}

int
main()
{
#ifdef __x86_64__
    // need to get DYLD to resolve the stubs on x86
    PUSH_POOL {
        TestObject *warm_up = [[TestObject alloc] init];
        testassert(warm_up);
        warm_up = objc_retainAutoreleasedReturnValue(warm_up);
        warm_up = objc_unsafeClaimAutoreleasedReturnValue(warm_up);
        [warm_up release];
        warm_up = nil;
    } POP_POOL;
#endif

#define BLOCK(contents)     \
    #contents,              \
    ^(id obj, id *outTmp) { \
        TestObject *tmp;    \
        contents;           \
        *outTmp = tmp;      \
    }

#if __arm64__
    testSuccessful1_1(BLOCK(
        WITH_NOP(objc_autoreleaseReturnValue,
                 objc_retainAutoreleasedReturnValue)
    ));

    testUnsuccessful1_1(BLOCK(
        NO_NOP(objc_autoreleaseReturnValue,
               objc_retainAutoreleasedReturnValue);
    ));

    testSuccessful0_1(BLOCK(
        WITH_NOP(objc_retainAutoreleaseReturnValue,
                 objc_retainAutoreleasedReturnValue);
    ));

    testUnsuccessful0_1(BLOCK(
        NO_NOP(objc_retainAutoreleaseReturnValue,
               objc_retainAutoreleasedReturnValue);
    ));

    testSuccessful1_0(BLOCK(
        WITH_NOP(objc_autoreleaseReturnValue,
                 objc_unsafeClaimAutoreleasedReturnValue);
    ));

    testUnsuccessful1_0(BLOCK(
        NO_NOP(objc_autoreleaseReturnValue,
               objc_unsafeClaimAutoreleasedReturnValue);
    ));

    testSuccessful0_0(BLOCK(
        WITH_NOP(objc_retainAutoreleaseReturnValue,
                 objc_unsafeClaimAutoreleasedReturnValue);
    ));

    testUnsuccessful0_0(BLOCK(
        NO_NOP(objc_retainAutoreleaseReturnValue,
               objc_unsafeClaimAutoreleasedReturnValue);
    ));

    // objc_claimAutoreleasedReturnValue tests
    testSuccessful1_1noNOP(BLOCK(
        NO_NOP(objc_autoreleaseReturnValue,
               objc_claimAutoreleasedReturnValue)
    ));

    testUnsuccessful1_1(BLOCK(
        WITH_NOP(objc_autoreleaseReturnValue,
                 objc_claimAutoreleasedReturnValue);
    ));

    testSuccessful0_1noNOP(BLOCK(
        NO_NOP(objc_retainAutoreleaseReturnValue,
               objc_claimAutoreleasedReturnValue);
    ));

    testUnsuccessful0_1(BLOCK(
        WITH_NOP(objc_retainAutoreleaseReturnValue,
                 objc_claimAutoreleasedReturnValue);
    ));

    // Two NOPs should still work with retainAutoreleasedReturnValue and
    // unsafeClaim.
    testSuccessful1_1(BLOCK(
        TWO_NOPS(objc_autoreleaseReturnValue,
                 objc_retainAutoreleasedReturnValue)
    ));

    testSuccessful0_1(BLOCK(
        TWO_NOPS(objc_retainAutoreleaseReturnValue,
                 objc_retainAutoreleasedReturnValue);
    ));

    testSuccessful1_0(BLOCK(
        TWO_NOPS(objc_autoreleaseReturnValue,
                 objc_unsafeClaimAutoreleasedReturnValue);
    ));

    testSuccessful0_0(BLOCK(
        TWO_NOPS(objc_retainAutoreleaseReturnValue,
                 objc_unsafeClaimAutoreleasedReturnValue);
    ));

    testUnsuccessful1_1(BLOCK(
        TWO_NOPS(objc_autoreleaseReturnValue,
                 objc_claimAutoreleasedReturnValue);
    ));

    testUnsuccessful0_1(BLOCK(
        TWO_NOPS(objc_retainAutoreleaseReturnValue,
                 objc_claimAutoreleasedReturnValue);
    ));

    // Bad NOPs (i.e. nops other than the specific sentinel) should still work
    // with retainAutoreleasedReturnValue and unsafeClaim when there's only one
    // (because we'll succeed with the return value check and never examine the
    // caller's code), but not when there's two (where it actually examines the
    // caller's code).
    testSuccessful1_1noNOP(BLOCK(
        WITH_BAD_NOP(objc_autoreleaseReturnValue,
                     objc_retainAutoreleasedReturnValue)
    ));

    testSuccessful0_1noNOP(BLOCK(
        WITH_BAD_NOP(objc_retainAutoreleaseReturnValue,
                     objc_retainAutoreleasedReturnValue);
    ));

    testSuccessful1_0noNOP(BLOCK(
        WITH_BAD_NOP(objc_autoreleaseReturnValue,
                     objc_unsafeClaimAutoreleasedReturnValue);
    ));

    testSuccessful0_0noNOP(BLOCK(
        WITH_BAD_NOP(objc_retainAutoreleaseReturnValue,
                     objc_unsafeClaimAutoreleasedReturnValue);
    ));

    testUnsuccessful1_1(BLOCK(
        TWO_BAD_NOPS(objc_autoreleaseReturnValue,
                     objc_retainAutoreleasedReturnValue)
    ));

    testUnsuccessful0_1(BLOCK(
        TWO_BAD_NOPS(objc_retainAutoreleaseReturnValue,
                     objc_retainAutoreleasedReturnValue);
    ));

    testUnsuccessful1_0(BLOCK(
        TWO_BAD_NOPS(objc_autoreleaseReturnValue,
                     objc_unsafeClaimAutoreleasedReturnValue);
    ));

    testUnsuccessful0_0(BLOCK(
        TWO_BAD_NOPS(objc_retainAutoreleaseReturnValue,
                     objc_unsafeClaimAutoreleasedReturnValue);
    ));

#else // Everything besides ARM64
    testSuccessful1_1(BLOCK(
        MAGIC(objc_autoreleaseReturnValue,
              objc_retainAutoreleasedReturnValue)
    ));

    testUnsuccessful1_1(BLOCK(
        NOT_MAGIC(objc_autoreleaseReturnValue,
                  objc_retainAutoreleasedReturnValue);
    ));

    testSuccessful0_1(BLOCK(
        MAGIC(objc_retainAutoreleaseReturnValue,
              objc_retainAutoreleasedReturnValue);
    ));

    testUnsuccessful0_1(BLOCK(
        NOT_MAGIC(objc_retainAutoreleaseReturnValue,
                  objc_retainAutoreleasedReturnValue);
    ));

    testSuccessful1_0(BLOCK(
        MAGIC(objc_autoreleaseReturnValue,
              objc_unsafeClaimAutoreleasedReturnValue);
    ));

    testUnsuccessful1_0(BLOCK(
        NOT_MAGIC(objc_autoreleaseReturnValue,
                  objc_unsafeClaimAutoreleasedReturnValue);
    ));

    testSuccessful0_0(BLOCK(
        MAGIC(objc_retainAutoreleaseReturnValue,
              objc_unsafeClaimAutoreleasedReturnValue);
    ));

    testUnsuccessful0_0(BLOCK(
        NOT_MAGIC(objc_retainAutoreleaseReturnValue,
                  objc_unsafeClaimAutoreleasedReturnValue);
    ));
#endif

    testRepeatedUnsuccessful();

    testassert(retainCountFailures == 0);

    succeed(__FILE__);

    return 0;
}

