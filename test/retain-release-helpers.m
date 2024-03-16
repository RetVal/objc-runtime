// TEST_CONFIG ARCH=arm64,arm64e MEM=mrc LANGUAGE=objective-c

#include "test.h"
#include "testroot.i"

#include <ptrauth.h>

@interface RetainReleaseChecker: NSObject {
    const char *_registerName;
    const char *_context;
    BOOL _shouldRetain;
    BOOL _shouldRelease;
}
@end

@implementation RetainReleaseChecker

+ (id)allocRawIsa {
    id obj = (id)calloc(class_getInstanceSize(self), 1);
    *(Class __ptrauth_objc_isa_pointer *)obj = self;
    return obj;
}

- (id)initWithRegisterName: (const char *)name shouldRetain: (BOOL)shouldRetain shouldRelease: (BOOL)shouldRelease context: (const char *)contextStr {
    if ((self = [self init])) {
        _registerName = name;
        _shouldRetain = shouldRetain;
        _shouldRelease = shouldRelease;
        _context = contextStr;
    }
    return self;
}

- (void)dealloc {
    if (![self _isDeallocating])
        fail("%s: Object %p in %s is in dealloc but _isDeallocating is false.", _context, self, _registerName);
    [super dealloc];
}

@end

@interface OverriddenRetainReleaseChecker: RetainReleaseChecker {
    unsigned _retainCount;
    unsigned _releaseCount;
}
@end

@implementation OverriddenRetainReleaseChecker

- (id)retain {
    _retainCount++;
    return self;
}

- (oneway void)release {
    _releaseCount++;
}

- (void)validateAndDestroy {
    if (_shouldRetain && _retainCount == 0)
        fail("%s: Object %p in %s was expected to be retained, but no retain was performed.", _context, self, _registerName);
    if (_shouldRetain && _retainCount > 1)
        fail("%s: Object %p in %s was expected to be retained once, but was retained %u times.", _context, self, _registerName, _retainCount);
    if (!_shouldRetain && _retainCount > 0)
        fail("%s: Object %p in %s was not expected to be retained, but was retained %u times.", _context, self, _registerName, _retainCount);

    if (_shouldRelease && _releaseCount == 0)
        fail("%s: Object %p in %s was expected to be released, but no release was performed.", _context, self, _registerName);
    if (_shouldRelease && _releaseCount > 1)
        fail("%s: Object %p in %s was expected to be released once, but was released %u times.", _context, self, _registerName, _releaseCount);
    if (!_shouldRelease && _releaseCount > 0)
        fail("%s: Object %p in %s was not expected to be released, but was released %u times.", _context, self, _registerName, _releaseCount);

    [super release];
}

@end

@interface NoOverrideRetainReleaseChecker: RetainReleaseChecker {}

@end

@implementation NoOverrideRetainReleaseChecker

- (id)init {
    if ((self = [super init])) {
        // Bump our retain count so that we can release twice without being destroyed.
        [self retain];
        [self retain];

        // Make sure we're counting correctly.
        testassertequal([self retainCount], 3);

        // We can't test retain and release at the same time, since we can only
        // detect deltas, so that's a net change of zero.
        testassert(!_shouldRetain || !_shouldRelease);
    }
    return self;
}

- (void)validateAndDestroy {
    if (_shouldRetain && [self retainCount] <= 3)
        fail("%s: Object %p in %s was expected to be retained, but retain count is %lu.", _context, self, _registerName, [self retainCount]);
    if (_shouldRetain && [self retainCount] > 4)
        fail("%s: Object %p in %s was expected to be retained once, but retain count is %lu.", _context, self, _registerName, [self retainCount]);

    if (_shouldRelease && [self retainCount] >= 3)
        fail("%s: Object %p in %s was expected to be released, but retain count is %lu.", _context, self, _registerName, [self retainCount]);
    if (_shouldRelease && [self retainCount] < 2)
        fail("%s: Object %p in %s was expected to be released once, but retain count is %lu.", _context, self, _registerName, [self retainCount]);

    for (unsigned long i = [self retainCount]; i > 0; i--)
        [self release];
}

@end

#define NUM_REGS 30

struct Registers {
    void *x[NUM_REGS];
};

#define ALL_REGS(macro) \
    macro(0) \
    macro(1) \
    macro(2) \
    macro(3) \
    macro(4) \
    macro(5) \
    macro(6) \
    macro(7) \
    macro(8) \
    macro(9) \
    macro(10) \
    macro(11) \
    macro(12) \
    macro(13) \
    macro(14) \
    macro(15) \
    macro(16) \
    macro(17) \
    macro(19) \
    macro(20) \
    macro(21) \
    macro(22) \
    macro(23) \
    macro(24) \
    macro(25) \
    macro(26) \
    macro(27) \
    macro(28) \
    macro(29)

const char *registerNames[] = {
#define NAME(num) "x" #num,
ALL_REGS(NAME)
#undef NAME
};

#define PASS_REGS_HELPER(num) \
    register void *x ## num asm ("x" #num) = regs->x[num];
#define PASS_REGS ALL_REGS(PASS_REGS_HELPER)

#define REG_INPUTS_HELPER(num) \
    "r" (x ## num),
#define REG_INPUTS ALL_REGS(REG_INPUTS_HELPER)

#define MAKE_CALL_FUNC(func) \
    void call_ ## func(struct Registers *regs) { \
        PASS_REGS \
        asm("bl _" #func : : REG_INPUTS "i" (0)); \
    }

#define MAKE_RETAIN_ONE_REG_CALL_FUNC(num) \
    MAKE_CALL_FUNC(objc_retain_x ## num)

MAKE_RETAIN_ONE_REG_CALL_FUNC(0)
MAKE_RETAIN_ONE_REG_CALL_FUNC(1)
MAKE_RETAIN_ONE_REG_CALL_FUNC(2)
MAKE_RETAIN_ONE_REG_CALL_FUNC(3)
MAKE_RETAIN_ONE_REG_CALL_FUNC(4)
MAKE_RETAIN_ONE_REG_CALL_FUNC(5)
MAKE_RETAIN_ONE_REG_CALL_FUNC(6)
MAKE_RETAIN_ONE_REG_CALL_FUNC(7)
MAKE_RETAIN_ONE_REG_CALL_FUNC(8)
MAKE_RETAIN_ONE_REG_CALL_FUNC(9)
MAKE_RETAIN_ONE_REG_CALL_FUNC(10)
MAKE_RETAIN_ONE_REG_CALL_FUNC(11)
MAKE_RETAIN_ONE_REG_CALL_FUNC(12)
MAKE_RETAIN_ONE_REG_CALL_FUNC(13)
MAKE_RETAIN_ONE_REG_CALL_FUNC(14)
MAKE_RETAIN_ONE_REG_CALL_FUNC(15)
MAKE_RETAIN_ONE_REG_CALL_FUNC(19)
MAKE_RETAIN_ONE_REG_CALL_FUNC(20)
MAKE_RETAIN_ONE_REG_CALL_FUNC(21)
MAKE_RETAIN_ONE_REG_CALL_FUNC(22)
MAKE_RETAIN_ONE_REG_CALL_FUNC(23)
MAKE_RETAIN_ONE_REG_CALL_FUNC(24)
MAKE_RETAIN_ONE_REG_CALL_FUNC(25)
MAKE_RETAIN_ONE_REG_CALL_FUNC(26)
MAKE_RETAIN_ONE_REG_CALL_FUNC(27)
MAKE_RETAIN_ONE_REG_CALL_FUNC(28)

#define MAKE_RELEASE_ONE_REG_CALL_FUNC(num) \
    MAKE_CALL_FUNC(objc_release_x ## num)

MAKE_RELEASE_ONE_REG_CALL_FUNC(0)
MAKE_RELEASE_ONE_REG_CALL_FUNC(1)
MAKE_RELEASE_ONE_REG_CALL_FUNC(2)
MAKE_RELEASE_ONE_REG_CALL_FUNC(3)
MAKE_RELEASE_ONE_REG_CALL_FUNC(4)
MAKE_RELEASE_ONE_REG_CALL_FUNC(5)
MAKE_RELEASE_ONE_REG_CALL_FUNC(6)
MAKE_RELEASE_ONE_REG_CALL_FUNC(7)
MAKE_RELEASE_ONE_REG_CALL_FUNC(8)
MAKE_RELEASE_ONE_REG_CALL_FUNC(9)
MAKE_RELEASE_ONE_REG_CALL_FUNC(10)
MAKE_RELEASE_ONE_REG_CALL_FUNC(11)
MAKE_RELEASE_ONE_REG_CALL_FUNC(12)
MAKE_RELEASE_ONE_REG_CALL_FUNC(13)
MAKE_RELEASE_ONE_REG_CALL_FUNC(14)
MAKE_RELEASE_ONE_REG_CALL_FUNC(15)
MAKE_RELEASE_ONE_REG_CALL_FUNC(19)
MAKE_RELEASE_ONE_REG_CALL_FUNC(20)
MAKE_RELEASE_ONE_REG_CALL_FUNC(21)
MAKE_RELEASE_ONE_REG_CALL_FUNC(22)
MAKE_RELEASE_ONE_REG_CALL_FUNC(23)
MAKE_RELEASE_ONE_REG_CALL_FUNC(24)
MAKE_RELEASE_ONE_REG_CALL_FUNC(25)
MAKE_RELEASE_ONE_REG_CALL_FUNC(26)
MAKE_RELEASE_ONE_REG_CALL_FUNC(27)
MAKE_RELEASE_ONE_REG_CALL_FUNC(28)

static bool supportedRegister(unsigned reg) {
    // x16 and x17 aren't supported because the dyld stub overwrites them. x18
    // is reserved. x29 is the frame pointer.
    return reg != 16 && reg != 17 && reg != 18 && reg != 29;
}

// Stub implementations for the unsupported registers. These should never be called.
static void call_objc_retain_x16(struct Registers *regs)  { (void)regs; abort(); }
static void call_objc_retain_x17(struct Registers *regs)  { (void)regs; abort(); }
static void call_objc_retain_x29(struct Registers *regs)  { (void)regs; abort(); }
static void call_objc_release_x16(struct Registers *regs) { (void)regs; abort(); }
static void call_objc_release_x17(struct Registers *regs) { (void)regs; abort(); }
static void call_objc_release_x29(struct Registers *regs) { (void)regs; abort(); }

typedef RetainReleaseChecker *(^Maker)(void);

void testRetainOneRegFuncsImpl(Maker maker, const char *context)
{
    for (unsigned i = 0; i < NUM_REGS; i++) {
        if (!supportedRegister(i))
            continue;

        testprintf("Testing objc_retain_x%u - %s\n", i, context);
        char *fullContext;
        asprintf(&fullContext, "objc_retain_x%u - %s", i, context);

        struct Registers regs;
        for (unsigned j = 0; j < NUM_REGS; j++) {
            regs.x[j] = [maker() initWithRegisterName: registerNames[j]
                                         shouldRetain: i == j
                                        shouldRelease: NO
                                              context: fullContext];
            if (i == j)
                testprintf("Object that should retain is %p.\n", regs.x[j]);
        }

#define CALL_IF_MATCH(num) \
        if (i == num) call_objc_retain_x ## num(&regs);
ALL_REGS(CALL_IF_MATCH)
#undef CALL_IF_MATCH

        testprintf("Validating results.\n");
        for (unsigned j = 0; j < NUM_REGS; j++)
            [(id)regs.x[j] validateAndDestroy];

        free(fullContext);
    }
}

void testRetainOneRegFuncs(void)
{
    testRetainOneRegFuncsImpl(^{ return [OverriddenRetainReleaseChecker alloc]; }, "Overridden RR");
    testRetainOneRegFuncsImpl(^{ return [NoOverrideRetainReleaseChecker alloc]; }, "NSObject RR");
    testRetainOneRegFuncsImpl(^{ return [OverriddenRetainReleaseChecker allocRawIsa]; }, "Overridden RR, raw isa");
    testRetainOneRegFuncsImpl(^{ return [NoOverrideRetainReleaseChecker allocRawIsa]; }, "NSObject RR, raw isa");
}

void testReleaseOneRegFuncsImpl(Maker maker, const char *context)
{
    for (unsigned i = 0; i < NUM_REGS; i++) {
        if (!supportedRegister(i))
            continue;

        testprintf("Testing objc_release_x%u - %s\n", i, context);
        char *fullContext;
        asprintf(&fullContext, "objc_release_x%u - %s", i, context);

        struct Registers regs;
        for (unsigned j = 0; j < NUM_REGS; j++) {
            regs.x[j] = [maker() initWithRegisterName: registerNames[j]
                                         shouldRetain: NO
                                        shouldRelease: i == j
                                              context: fullContext];
            if (i == j)
                testprintf("Object that should release is %p.\n", regs.x[j]);
        }

#define CALL_IF_MATCH(num) \
        if (i == num) call_objc_release_x ## num(&regs);
ALL_REGS(CALL_IF_MATCH)
#undef CALL_IF_MATCH

        testprintf("Validating results.\n");
        for (unsigned j = 0; j < NUM_REGS; j++)
            [(id)regs.x[j] validateAndDestroy];

        free(fullContext);
    }
}

void testReleaseOneRegFuncs(void)
{
    testReleaseOneRegFuncsImpl(^{ return [OverriddenRetainReleaseChecker alloc]; }, "Overridden RR");
    testReleaseOneRegFuncsImpl(^{ return [NoOverrideRetainReleaseChecker alloc]; }, "NSObject RR");
    testReleaseOneRegFuncsImpl(^{ return [OverriddenRetainReleaseChecker allocRawIsa]; }, "Overridden RR, raw isa");
    testReleaseOneRegFuncsImpl(^{ return [NoOverrideRetainReleaseChecker allocRawIsa]; }, "NSObject RR, raw isa");
}

void testOverflowRetainReleaseOneRegFuncs(void)
{
    // ARM64-not-e currently has 19 bits of inline refcount. Do enough retains
    // to overflow that.
    const int numRetains = 1 << 20;

    for (unsigned i = 0; i < NUM_REGS; i++) {
        if (!supportedRegister(i))
            continue;

        testprintf("Testing overflow of objc_retain/release_x%u\n", i);
        char *fullContext;
        asprintf(&fullContext, "overflow objc_retain/release_x%u", i);

        struct Registers regs;
        for (unsigned j = 0; j < NUM_REGS; j++) {
            regs.x[j] = [[NoOverrideRetainReleaseChecker alloc]
                            initWithRegisterName: registerNames[j]
                                    shouldRetain: i == j
                                   shouldRelease: NO
                                         context: fullContext];
            if (i == j)
                testprintf("Object that should retain/release is %p.\n", regs.x[j]);
        }

#define CALL_RETAIN_IF_MATCH(num) \
        if (i == num) call_objc_retain_x ## num(&regs);
#define CALL_RELEASE_IF_MATCH(num) \
        if (i == num) call_objc_release_x ## num(&regs);

        // NOTE: the {} around the body are necessary, ALL_REGS produces multiple statements!
        for (int j = 0; j < numRetains; j++) {
            ALL_REGS(CALL_RETAIN_IF_MATCH)
        }
        testprintf("After %d retains, retain count is %lu\n", numRetains, [(id)regs.x[i] retainCount]);
        for (int j = 0; j < numRetains - 1; j++) {
            ALL_REGS(CALL_RELEASE_IF_MATCH)
        }

#undef CALL_RETAIN_IF_MATCH
#undef CALL_RELEASE_IF_MATCH

        testprintf("Validating results.\n");
        for (unsigned j = 0; j < NUM_REGS; j++)
            [(id)regs.x[j] validateAndDestroy];

        free(fullContext);
    }
}


@interface DeallocatingChecker: NSObject {
@public
    BOOL *outDeallocated;
}

@end

@implementation DeallocatingChecker

- (void)dealloc {
    // If we're using side tables, rc is 1 here, and it can still
    // increment and decrement.  We should fix that.
    // rdar://93537253 (Make side table retain count zero during dealloc)
#if !ISA_HAS_INLINE_RC
    testassertequal([self retainCount], 1);
    testassert([self _isDeallocating]);
#else
#define CHECK()                             \
    testassertequal([self retainCount], 0); \
    testassert([self _isDeallocating]);

    CHECK();

    struct Registers regs;
    for (unsigned i = 0; i < NUM_REGS; i++)
        regs.x[i] = self;

#define RETAIN_RELEASE(num)                                                          \
    if (supportedRegister(num)) {                                                    \
        testprintf("DeallocatingChecker %p calling objc_retain_x" #num "\n", self);  \
        call_objc_retain_x ## num(&regs);                                            \
        CHECK();                                                                     \
        testprintf("DeallocatingChecker %p calling objc_release_x" #num "\n", self); \
        call_objc_release_x ## num(&regs);                                           \
        CHECK();                                                                     \
    }

    ALL_REGS(RETAIN_RELEASE)

#undef RETAIN_RELEASE
#endif

    *outDeallocated = YES;
    [super dealloc];
}

@end

void testRetainReleaseInDealloc(void) {
    testprintf("testRetainReleaseInDealloc\n");
    BOOL deallocated = NO;
    DeallocatingChecker *obj = [[DeallocatingChecker alloc] init];
    obj->outDeallocated = &deallocated;
    [obj release];
    testassert(deallocated);
}

void testSwift() {
#if !TARGET_OS_EXCLAVEKIT // Probably can't dlopen libswiftCore in exclaves.
    void *swiftcore = dlopen("/usr/lib/swift/libswiftCore.dylib", RTLD_LAZY);
    testassert(swiftcore);

    void *(*swift_allocObject)(void *, size_t, size_t) =
        dlsym(swiftcore, "swift_allocObject");
    testassert(swift_allocObject);

    void (*swift_deallocUninitializedObject)(void *, size_t, size_t) =
        dlsym(swiftcore, "swift_deallocUninitializedObject");
    testassert(swift_deallocUninitializedObject);

    size_t (*swift_retainCount)(void *) =
        dlsym(swiftcore, "swift_retainCount");
    testassert(swift_retainCount);

    // Use AnyKeyPath as our test class. It's public API so we know we can count
    // on it being there, and it's a native Swift class.
    Class AnyKeyPath = objc_getClass("Swift.AnyKeyPath");
    testassert(AnyKeyPath);

    void *(^createObj)(void) = ^{
        // We'll allocate an uninitialized instance rather than trying to figure out
        // how to properly initialize one of these things from the outside. We just
        // need something we can retain and release.
        void *obj = swift_allocObject(AnyKeyPath, class_getInstanceSize(AnyKeyPath), 0);
        testassert(obj);
        testassertequal(swift_retainCount(obj), 1);
        return obj;
    };

    void (^destroyObj)(void *) = ^(void *obj) {
        swift_deallocUninitializedObject(obj, class_getInstanceSize(AnyKeyPath), 0);
    };

    for (unsigned i = 0; i < NUM_REGS; i++) {
        if (!supportedRegister(i))
            continue;

        testprintf("Testing Swift path of objc_retain/release_x%u\n", i);

        struct Registers regs;
        for (unsigned j = 0; j < NUM_REGS; j++) {
            regs.x[j] = createObj();
            if (i == j)
                 testprintf("Object that should retain/release is %p.\n", regs.x[j]);
        }

#define CALL_RETAIN_IF_MATCH(num) \
        if (i == num) call_objc_retain_x ## num(&regs);
#define CALL_RELEASE_IF_MATCH(num) \
        if (i == num) call_objc_release_x ## num(&regs);

        ALL_REGS(CALL_RETAIN_IF_MATCH)
        for (unsigned j = 0; j < NUM_REGS; j++) {
            if (i == j)
                testassertequal(swift_retainCount(regs.x[j]), 2);
            else
                testassertequal(swift_retainCount(regs.x[j]), 1);
        }
        ALL_REGS(CALL_RELEASE_IF_MATCH)
        for (unsigned j = 0; j < NUM_REGS; j++) {
            testassertequal(swift_retainCount(regs.x[j]), 1);
            destroyObj(regs.x[j]);
        }

        #undef CALL_RETAIN_IF_MATCH
        #undef CALL_RELEASE_IF_MATCH
    }
#endif
}

void testNilAndTagged()
{
    uintptr_t values[] = {
        0, // nil
        0x8000000000000000, // smallest tagged value
        0xffffffffffffffff, // largest tagged value
    };
    for (unsigned i = 0; i < sizeof(values) / sizeof(*values); i++) {
        void *ptr = (void *)values[i];
        testprintf("Testing retain/release of %p\n", ptr);
        struct Registers regs;
        for (unsigned j = 0; j < NUM_REGS; j++)
            regs.x[j] = ptr;

#define CALL_RETAIN_IF_MATCH(num) \
        if (i == num) call_objc_retain_x ## num(&regs);
#define CALL_RELEASE_IF_MATCH(num) \
        if (i == num) call_objc_release_x ## num(&regs);
        ALL_REGS(CALL_RETAIN_IF_MATCH)
        ALL_REGS(CALL_RELEASE_IF_MATCH)
        #undef CALL_RETAIN_IF_MATCH
        #undef CALL_RELEASE_IF_MATCH
    }
}

int main()
{
    testRetainOneRegFuncs();
    testReleaseOneRegFuncs();
    testOverflowRetainReleaseOneRegFuncs();
    testRetainReleaseInDealloc();
    testSwift();
    testNilAndTagged();

    succeed(__FILE__);
}
