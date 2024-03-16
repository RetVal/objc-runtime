// Define FOUNDATION=1 for NSObject and NSAutoreleasePool
// Define FOUNDATION=0 for _objc_root* and _objc_autoreleasePool*

#include "test.h"

#if FOUNDATION
#   define RR_PUSH() [[NSAutoreleasePool alloc] init]
#   define RR_POP(p) [(id)p release]
#   define RR_RETAIN(o) [o retain]
#   define RR_RELEASE(o) [o release]
#   define RR_AUTORELEASE(o) [o autorelease]
#   define RR_RETAINCOUNT(o) [o retainCount]
#else
#   define RR_PUSH() _objc_autoreleasePoolPush()
#   define RR_POP(p) _objc_autoreleasePoolPop(p)
#   define RR_RETAIN(o) _objc_rootRetain((id)o)
#   define RR_RELEASE(o) _objc_rootRelease((id)o)
#   define RR_AUTORELEASE(o) _objc_rootAutorelease((id)o)
#   define RR_RETAINCOUNT(o) _objc_rootRetainCount((id)o)
#endif

#include <objc/objc-internal.h>
#include <Foundation/Foundation.h>
#include <ptrauth.h>

static int state;
static pthread_attr_t smallstack;

#define NESTED_COUNT 8

@interface Deallocator : NSObject @end
@implementation Deallocator
-(void) dealloc 
{
    // testprintf("-[Deallocator %p dealloc]\n", self);
    state++;
    [super dealloc];
}
@end

@interface AutoreleaseDuringDealloc : NSObject @end
@implementation AutoreleaseDuringDealloc
-(void) dealloc
{
    state++;
    RR_AUTORELEASE([[Deallocator alloc] init]);
    [super dealloc];
}
@end

@interface AutoreleasePoolDuringDealloc : NSObject @end
@implementation AutoreleasePoolDuringDealloc
-(void) dealloc
{
    // caller's pool
    for (int i = 0; i < NESTED_COUNT; i++) {
        RR_AUTORELEASE([[Deallocator alloc] init]);
    }

    // local pool, popped
    void *pool = RR_PUSH();
    for (int i = 0; i < NESTED_COUNT; i++) {
        RR_AUTORELEASE([[Deallocator alloc] init]);
    }
    RR_POP(pool);

    // caller's pool again
    for (int i = 0; i < NESTED_COUNT; i++) {
        RR_AUTORELEASE([[Deallocator alloc] init]);
    }

#if FOUNDATION
    {
        static bool warned;
        if (!warned) testwarn("rdar://7138159 NSAutoreleasePool leaks");
        warned = true;
    }
    state += NESTED_COUNT;
#else
    // local pool, not popped
    RR_PUSH();
    for (int i = 0; i < NESTED_COUNT; i++) {
        RR_AUTORELEASE([[Deallocator alloc] init]);
    }
#endif

    [super dealloc];
}
@end

@interface AutoreleaseSelfDuringDealloc : NSObject @end
@implementation AutoreleaseSelfDuringDealloc
+ (id)allocRawIsa {
    id obj = (id)calloc(class_getInstanceSize(self), 1);
    *(Class __ptrauth_objc_isa_pointer *)obj = self;
    return obj;
}
- (void)_objc_initiateDealloc {
    [self dealloc];
}
- (void)dealloc
{
    state++;
    RR_AUTORELEASE(self);
    [super dealloc];
}
@end

void *autorelease_lots_fn(void *singlePool)
{
    // Enough to blow out the stack if AutoreleasePoolPage is recursive.
    const int COUNT = 1024*1024;
    state = 0;

    int p = 0;
    void **pools = (void**)malloc((COUNT+1) * sizeof(void*));
    pools[p++] = RR_PUSH();

    id obj = RR_AUTORELEASE([[Deallocator alloc] init]);

    // last pool has only 1 autorelease in it
    pools[p++] = RR_PUSH();

    for (int i = 0; i < COUNT; i++) {
        if (rand() % 1000 == 0  &&  !singlePool) {
            pools[p++] = RR_PUSH();
        } else {
            RR_AUTORELEASE(RR_RETAIN(obj));
        }
    }

    testassert(state == 0);
    while (--p) {
        RR_POP(pools[p]);
    }
    testassert(state == 0);
    testassert(RR_RETAINCOUNT(obj) == 1);
    RR_POP(pools[0]);
    testassert(state == 1);
    free(pools);

    return NULL;
}

void *nsthread_fn(void *arg __unused)
{
    [NSThread currentThread];
    void *pool = RR_PUSH();
    RR_AUTORELEASE([[Deallocator alloc] init]);
    RR_POP(pool);
    return NULL;
}

void cycle(void)
{
    // Normal autorelease.
    testprintf("-- Normal autorelease.\n");
    {
        void *pool = RR_PUSH();
        state = 0;
        RR_AUTORELEASE([[Deallocator alloc] init]);
        testassert(state == 0);
        RR_POP(pool);
        testassert(state == 1);
    }

    // Autorelease during dealloc during autoreleasepool-pop.
    // That autorelease is handled by the popping pool, not the one above it.
    testprintf("-- Autorelease during dealloc during autoreleasepool-pop.\n");
    {
        void *pool = RR_PUSH();
        state = 0;
        RR_AUTORELEASE([[AutoreleaseDuringDealloc alloc] init]);
        testassert(state == 0);
        RR_POP(pool);
        testassert(state == 2);
    }

    // Autorelease pool during dealloc during autoreleasepool-pop.
    testprintf("-- Autorelease pool during dealloc during autoreleasepool-pop.\n");
    {
        void *pool = RR_PUSH();
        state = 0;
        RR_AUTORELEASE([[AutoreleasePoolDuringDealloc alloc] init]);
        testassert(state == 0);
        RR_POP(pool);
        testassert(state == 4 * NESTED_COUNT);
    }

    // Autorelease an object during its own dealloc.
    testprintf("-- Autorelease deallocating object.\n");

    // Raw isa only skips the autorelease pool when it has custom dealloc initiation.
    // Do this early in case we're on a platform where everything gets a raw isa.
    _class_setCustomDeallocInitiation([AutoreleaseSelfDuringDealloc class]);

    {
        void *pool = RR_PUSH();
        state = 0;
        RELEASE_VALUE([[AutoreleaseSelfDuringDealloc alloc] init]);
        testassert(state == 1);
        RR_POP(pool);
    }
    testprintf("-- Autorelease deallocating object with raw isa.\n");
    {
        void *pool = RR_PUSH();
        state = 0;
        RELEASE_VALUE([[AutoreleaseSelfDuringDealloc allocRawIsa] init]);
        testassert(state == 1);
        RR_POP(pool);
    }

    // Top-level thread pool popped normally.
    // Check twice - once for empty placeholder, once without.
#   if DEBUG_POOL_ALLOCATION || FOUNDATION
    // DebugPoolAllocation disables the empty placeholder pool.
    // Guard Malloc disables the empty placeholder pool (checked at runtime)
    // Foundation makes RR_PUSH return an NSAutoreleasePool not the raw token.
#       define CHECK_PLACEHOLDER 0
#   else
#       define CHECK_PLACEHOLDER 1
#   endif
    testprintf("-- Thread-level pool popped normally.\n");
    {
        state = 0;
        testonthread(^{ 
            void *pool = RR_PUSH();
#if CHECK_PLACEHOLDER
            if (!is_guardmalloc()) {
                testassert(pool == (void*)1);
            }
#endif
            RR_AUTORELEASE([[Deallocator alloc] init]);
            // Push and pop a pool to clear out the return TLS.
            RR_POP(RR_PUSH());
            RR_POP(pool);
            pool = RR_PUSH();
#if CHECK_PLACEHOLDER
            if (!is_guardmalloc()) {
                testassert(pool != (void*)1);
            }
#endif
            RR_AUTORELEASE([[Deallocator alloc] init]);
            RR_POP(pool);
        });
        testassert(state == 2);
    }


    // Autorelease with no pool.
    testprintf("-- Autorelease with no pool.\n");
    {
        state = 0;
        testonthread(^{
            RR_AUTORELEASE([[Deallocator alloc] init]);
        });
        testassert(state == 1);
    }

    // Autorelease with no pool after popping the top-level pool.
    testprintf("-- Autorelease with no pool after popping the last pool.\n");
    {
        state = 0;
        testonthread(^{
            void *pool = RR_PUSH();
            RR_AUTORELEASE([[Deallocator alloc] init]);
            RR_POP(pool);
            RR_AUTORELEASE([[Deallocator alloc] init]);
        });
        testassert(state == 2);
    }

    // Top-level thread pool not popped.
    // The runtime should clean it up.
#if FOUNDATION
    {
        static bool warned;
        if (!warned) testwarn("rdar://7138159 NSAutoreleasePool leaks");
        warned = true;
    }
#else
    testprintf("-- Thread-level pool not popped.\n");
    {
        state = 0;
        testonthread(^{
            RR_PUSH();
            RR_AUTORELEASE([[Deallocator alloc] init]);
            // pool not popped
        });
        testassert(state == 1);
    }
#endif

    // Intermediate pool not popped.
    // Popping the containing pool should clean up the skipped pool first.
#if FOUNDATION
    {
        static bool warned;
        if (!warned) testwarn("rdar://7138159 NSAutoreleasePool leaks");
        warned = true;
    }
#else
    testprintf("-- Intermediate pool not popped.\n");
    {
        void *pool = RR_PUSH();
        void *pool2 = RR_PUSH();
        RR_AUTORELEASE([[Deallocator alloc] init]);
        state = 0;
        (void)pool2; // pool2 not popped
        RR_POP(pool);
        testassert(state == 1);
    }
#endif
}


static void
slow_cycle(void)
{
    // Large autorelease stack.
    // Do this only once because it's slow.
    testprintf("-- Large autorelease stack.\n");
    {
        // limit stack size: autorelease pop should not be recursive
        pthread_t th;
        pthread_create(&th, &smallstack, &autorelease_lots_fn, NULL);
        pthread_join(th, NULL);
    }

    // Single large autorelease pool.
    // Do this only once because it's slow.
    testprintf("-- Large autorelease pool.\n");
    {
        // limit stack size: autorelease pop should not be recursive
        pthread_t th;
        pthread_create(&th, &smallstack, &autorelease_lots_fn, (void*)1);
        pthread_join(th, NULL);
    }
}


int main()
{
    pthread_attr_init(&smallstack);
    pthread_attr_setstacksize(&smallstack, 32768);

    // inflate the refcount side table so it doesn't show up in leak checks
    {
        int count = 10000;
        id *objs = (id *)malloc(count*sizeof(id));
        for (int i = 0; i < count; i++) {
            objs[i] = RR_RETAIN([NSObject new]);
        }
        for (int i = 0; i < count; i++) {
            RR_RELEASE(objs[i]);
            RR_RELEASE(objs[i]);
        }
        free(objs);
    }

#if FOUNDATION
    // inflate NSAutoreleasePool's instance cache
    {
        int count = 32;
        id *objs = (id *)malloc(count * sizeof(id));
        for (int i = 0; i < count; i++) {
            objs[i] = [[NSAutoreleasePool alloc] init];
        }
        for (int i = 0; i < count; i++) {
            [objs[count-i-1] release];
        }
        
        free(objs);
    }
#endif

    // preheat
    {
        for (int i = 0; i < 100; i++) {
            cycle();
        }
        
        slow_cycle();
    }
    
    // check for leaks using top-level pools
    {
        leak_mark();
        
        for (int i = 0; i < 1000; i++) {
            cycle();
        }
        
        leak_check(0);
        
        slow_cycle();
        
        leak_check(0);
    }
    
    // check for leaks using pools not at top level
    // fixme for FOUNDATION this leak mark/check needs 
    // to be outside the autorelease pool for some reason
    leak_mark();
    void *pool = RR_PUSH();
    {
        for (int i = 0; i < 1000; i++) {
            cycle();
        }
        
        slow_cycle();
    }
    RR_POP(pool);
    leak_check(0);

    // NSThread.
    // Can't leak check this because it's too noisy.
    testprintf("-- NSThread.\n");
    {
        pthread_t th;
        pthread_create(&th, &smallstack, &nsthread_fn, 0);
        pthread_join(th, NULL);
    }
    
    // NO LEAK CHECK HERE

    succeed(NAME);
}
