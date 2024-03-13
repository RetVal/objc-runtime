// test.h 
// Common definitions for trivial test harness


#ifndef TEST_H
#define TEST_H

#include <TargetConditionals.h>

#ifndef TARGET_OS_SIMULATOR
#define TARGET_OS_SIMULATOR 0
#endif
#ifndef TARGET_OS_IOS
#define TARGET_OS_IOS 0
#endif

#include <stdio.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>

#if __cplusplus
#include <atomic>
using std::atomic_int;
using std::memory_order_relaxed;
#else
#include <stdatomic.h>
#endif
#include <malloc/malloc.h>

#if !TARGET_OS_EXCLAVEKIT
#include <sys/errno.h>
#include <sys/param.h>

#include <libgen.h>
#include <unistd.h>
#include <pthread.h>
#include <mach/mach.h>
#include <mach/vm_param.h>
#include <mach/mach_time.h>
#else
#include <threads.h>
#endif

#include <objc/objc.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <objc/objc-abi.h>
#include <objc/objc-auto.h>
#include <objc/objc-internal.h>

#if __has_include(<ptrauth.h>)
#   include <ptrauth.h>
#endif

#include "../runtime/isa.h"

#if __cplusplus
#   define EXTERN_C extern "C"
#else
#   define EXTERN_C /*empty*/
#endif


#if TARGET_OS_EXCLAVEKIT
// ExclaveKit compatibility
#define MAXPATHLEN  1024

static inline const char *test_getenv(const char *name)
{
    (void)name;
    return NULL;
}
#define getenv(x) test_getenv(x)

static inline char *basename(char *path)
{
    size_t len = strlen(path);
    char *ptr = path + len - 1;
    while (ptr > path && *ptr == '/')
        *ptr-- = 0;
    ptr = strrchr(path, '/');
    if (!ptr)
        return path;
    return ptr + 1;
}

static inline char *basename_r(const char *path, char *bname)
{
    size_t len = strlen(path);
    memcpy(bname, path, len + 1);
    return basename(bname);
}

static inline char *dirname(char *path)
{
    size_t len = strlen(path);
    char *ptr = path + len - 1;
    while (ptr > path && *ptr == '/')
        *ptr-- = 0;
    ptr = strrchr(path, '/');
    if (!ptr)
        path[0] = 0;
    else
        *ptr = 0;
    return path;
}

static inline char *dirname_r(const char *path, char *dname)
{
    size_t len = strlen(path);
    memcpy(dname, path, len);
    return dirname(dname);
}

// rdar://92046168 - _Noreturn annotations are missing
_Noreturn void exit(int);
#endif

// Test output
static inline void succeed(const char *name)  __attribute__((noreturn));
static inline void succeed(const char *name)
{
    if (name) {
        char *path = strdup(name);
        fprintf(stderr, "OK: %s\n", basename(path));
        free(path);
    } else {
        fprintf(stderr, "OK\n");
    }
    exit(0);
}

static inline void fail(const char *msg, ...)   __attribute__((noreturn));
static inline void fail(const char *msg, ...)
{
    if (msg) {
        char *msg2;
        asprintf(&msg2, "BAD: %s\n", msg);
        va_list v;
        va_start(v, msg);
        vfprintf(stderr, msg2, v);
        va_end(v);
        free(msg2);
    } else {
        fprintf(stderr, "BAD\n");
    }
    exit(1);
}

#define testassert(cond) \
    ((void) (((cond) != 0) ? (void)0 : __testassert(#cond, __FILE__, __LINE__)))
#define __testassert(cond, file, line) \
    (fail("failed assertion '%s' at %s:%u", cond, __FILE__, __LINE__))

static inline char *hexstring(uint8_t *data, size_t size)
{
    char *str;
    switch (size) {
    case sizeof(unsigned long long):
        asprintf(&str, "%016llx", *(unsigned long long *)data);
        break;
    case sizeof(unsigned int):
        asprintf(&str, "%08x", *(unsigned int*)data);
        break;
    case sizeof(uint16_t):
        asprintf(&str, "%04x", *(uint16_t *)data);
        break;
    default:
        str = (char *)malloc(size * 2 + 1);
        for (size_t i = 0; i < size; i++) {
            snprintf(str + 2 * i, 3, "%02x", data[i]);
        }
    }
    return str;
}

static inline void failnotequal(uint8_t *lhs, size_t lhsSize, uint8_t *rhs, size_t rhsSize, const char *lhsStr, const char *rhsStr, const char *file, unsigned line)
{
    fprintf(stderr, "BAD: failed assertion '%s != %s' (0x%s != 0x%s) at %s:%u\n", lhsStr, rhsStr, hexstring(lhs, lhsSize), hexstring(rhs, rhsSize), file, line);
    exit(1);
}

#define testassertequal(lhs, rhs) do {\
    __typeof__(0 ? lhs : rhs) __lhs = lhs; \
    __typeof__(0 ? lhs : rhs) __rhs = rhs; \
    if ((__lhs) != (__rhs)) failnotequal((uint8_t *)&__lhs, sizeof(__lhs), (uint8_t *)&__rhs, sizeof(__rhs), #lhs, #rhs, __FILE__, __LINE__); \
} while(0)

#define testassertequalstr(lhs, rhs) do { \
    __typeof__(lhs) __lhs = lhs; \
    __typeof__(rhs) __rhs = rhs; \
    if (strcmp(__lhs, __rhs) != 0) \
        fail("failed assertion %s (\"%s\") != %s (\"%s\") at %s:%u", #lhs, __lhs, #rhs, __rhs, __FILE__, __LINE__); \
} while(0)

/* time-sensitive assertion, disabled under valgrind */
#if TARGET_OS_EXCLAVEKIT
#define timecheck_valgrind
#else
#define timecheck_valgrind \
    if (getenv("VALGRIND") && 0 != strcmp(getenv("VALGRIND"), "NO")) {  \
        /* valgrind; do nothing */                                      \
    } else
#endif
#define timecheck(name, time, fast, slow)                                       \
    timecheck_valgrind                                                          \
    testprintf("timecheck: %s %llu in %llu, %llu\n", name, time, fast, slow);   \
    if (time > slow) {                                                          \
        fprintf(stderr, "SLOW: %s %llu, expected %llu..%llu\n",                 \
                name, (uint64_t)(time), (uint64_t)(fast), (uint64_t)(slow));    \
    } else if (time < fast) {                                                   \
        fprintf(stderr, "FAST: %s %llu, expected %llu..%llu\n",                 \
                name, (uint64_t)(time), (uint64_t)(fast), (uint64_t)(slow));    \
    } else {                                                                    \
        testprintf("time: %s %llu, expected %llu..%llu\n",                      \
                   name, (uint64_t)(time), (uint64_t)(fast), (uint64_t)(slow)); \
    }


// Return true if testprintf() output is enabled.
static inline bool testverbose(void)
{
#if TARGET_OS_EXCLAVEKIT
#   ifdef VERBOSE
    return VERBOSE >= 2;
#   else
    return false;
#   endif
#else
    static int verbose = -1;
    if (verbose < 0) verbose = atoi(getenv("VERBOSE") ?: "0");

    // VERBOSE=1 prints test harness info only
    // VERBOSE=2 prints test info
    return verbose >= 2;
#endif
}

// Print debugging info when VERBOSE=2 is set,
// without disturbing the test's expected output.
static inline void testprintf(const char *msg, ...)
{
    if (msg  &&  testverbose()) {
        char *msg2;
        asprintf(&msg2, "VERBOSE: %s", msg);
        va_list v;
        va_start(v, msg);
        vfprintf(stderr, msg2, v);
        va_end(v);
        free(msg2);
    }
}

// complain to output, but don't fail the test
// Use when warning that some test is being temporarily skipped 
// because of something like a compiler bug.
static inline void testwarn(const char *msg, ...)
{
    if (msg) {
        char *msg2;
        asprintf(&msg2, "WARN: %s\n", msg);
        va_list v;
        va_start(v, msg);
        vfprintf(stderr, msg2, v);
        va_end(v);
        free(msg2);
    }
}

static inline void testnoop() { }

// Are we running in dyld3 mode?
// Note: checks by looking for the DYLD_USE_CLOSURES environment variable.
// This is is always set by our test script, but this won't give the right
// answer when being run manually unless that variable is set.
static inline bool testdyld3(void) {
    static int dyld = 0;
    if (dyld == 0) {
        const char *useClosures = getenv("DYLD_USE_CLOSURES");
        dyld = useClosures && useClosures[0] == '1' ? 3 : 2;
    }
    return dyld == 3;
}

// Prevent deprecation warnings from some runtime functions.
static inline void test_objc_flush_caches(Class cls)
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    _objc_flush_caches(cls);
#pragma clang diagnostic pop    
}
#define _objc_flush_caches(c) test_objc_flush_caches(c)

static inline Class test_class_setSuperclass(Class cls, Class supercls)
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return class_setSuperclass(cls, supercls);
#pragma clang diagnostic pop
}
#define class_setSuperclass(c, s) test_class_setSuperclass(c, s)

static inline void testcollect() 
{
    _objc_flush_caches(nil);
}

// Synchronously run test code on another thread.

// The block object is unsafe_unretained because we must not allow 
// ARC to retain them in non-Foundation tests
typedef void(^testblock_t)(void);
static __unsafe_unretained testblock_t testcodehack;
#if !TARGET_OS_EXCLAVEKIT
typedef void *thread_return_t;
#else
typedef int thread_return_t;
#endif
static inline thread_return_t _testthread(void *arg __unused)
{
    testcodehack();
    return 0;
}
static inline void testonthread(__unsafe_unretained testblock_t code) 
{
#if !TARGET_OS_EXCLAVEKIT
    pthread_t th;
    testcodehack = code;  // force GC not-thread-local, avoid ARC void* casts
    pthread_create(&th, NULL, _testthread, NULL);
    pthread_join(th, NULL);
#else
    thrd_t th;
    testcodehack = code;
    thrd_create(&th, _testthread, NULL);
    thrd_join(th, NULL);
#endif
}

/* Make sure libobjc does not call global operator new. 
   Any test that DOES need to call global operator new must 
   `#define TEST_CALLS_OPERATOR_NEW` before including test.h.
 */
#if __cplusplus  &&  !defined(TEST_CALLS_OPERATOR_NEW)
#if !defined(TEST_OVERRIDES_NEW)
#define TEST_OVERRIDES_NEW 1
#endif
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Winline-new-delete"
#import <new>
inline void* operator new(std::size_t) { fail("called global operator new"); }
inline void* operator new[](std::size_t) { fail("called global operator new[]"); }
inline void* operator new(std::size_t, const std::nothrow_t&) noexcept(true) { fail("called global operator new(nothrow)"); }
inline void* operator new[](std::size_t, const std::nothrow_t&) noexcept(true) { fail("called global operator new[](nothrow)"); }
inline void operator delete(void*) noexcept(true) { fail("called global operator delete"); }
inline void operator delete[](void*) noexcept(true) { fail("called global operator delete[]"); }
inline void operator delete(void*, const std::nothrow_t&) noexcept(true) { fail("called global operator delete(nothrow)"); }
inline void operator delete[](void*, const std::nothrow_t&) noexcept(true) { fail("called global operator delete[](nothrow)"); }
#pragma clang diagnostic pop
#endif


/* Leak checking
   Fails if total malloc memory in use at leak_check(n) 
   is more than n bytes above that at leak_mark().
*/

#if !TARGET_OS_EXCLAVEKIT
static inline void leak_recorder(task_t task __unused, void *ctx, unsigned type __unused, vm_range_t *ranges, unsigned count)
{
    size_t *inuse = (size_t *)ctx;
    while (count--) {
        *inuse += ranges[count].size;
    }
}

static inline size_t leak_inuse(void)
{
    size_t total = 0;
    vm_address_t *zones;
    unsigned count;
    malloc_get_all_zones(mach_task_self(), NULL, &zones, &count);
    for (unsigned i = 0; i < count; i++) {
        size_t inuse = 0;
        malloc_zone_t *zone = (malloc_zone_t *)zones[i];
        if (!zone->introspect || !zone->introspect->enumerator) continue;

        // skip DispatchContinuations because it sometimes claims to be 
        // using lots of memory that then goes away later
        if (0 == strcmp(zone->zone_name, "DispatchContinuations")) continue;

        zone->introspect->enumerator(mach_task_self(), &inuse, MALLOC_PTR_IN_USE_RANGE_TYPE, (vm_address_t)zone, NULL, leak_recorder);
        // fprintf(stderr, "%zu in use for zone %s\n", inuse, zone->zone_name);
        total += inuse;
    }

    return total;
}


static inline void leak_dump_heap(const char *msg)
{
    fprintf(stderr, "%s\n", msg);

    // Make `heap` write to stderr
    int outfd = dup(STDOUT_FILENO);
    dup2(STDERR_FILENO, STDOUT_FILENO);
    pid_t pid = getpid();
    char cmd[256];
    // environment variables reset for iOS simulator use
    snprintf(cmd, sizeof(cmd), "DYLD_LIBRARY_PATH= DYLD_ROOT_PATH= /usr/bin/heap -addresses all %d", (int)pid);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    system(cmd);
#pragma clang diagnostic pop

    dup2(outfd, STDOUT_FILENO);
    close(outfd);
}

static size_t _leak_start;
static inline void leak_mark(void)
{
    testcollect();
    if (getenv("LEAK_HEAP")) {
        leak_dump_heap("HEAP AT leak_mark");
    }
    _leak_start = leak_inuse();
}

#define leak_check(n)                                                   \
    do {                                                                \
        const char *_check = getenv("LEAK_CHECK");                      \
        size_t inuse;                                                   \
        if (_check && 0 == strcmp(_check, "NO")) break;                 \
        testcollect();                                                  \
        if (getenv("LEAK_HEAP")) {                                      \
            leak_dump_heap("HEAP AT leak_check");                       \
        }                                                               \
        inuse = leak_inuse();                                           \
        if (inuse > _leak_start + (n)) {                                  \
            fprintf(stderr, "BAD: %zu bytes leaked at %s:%u "           \
                    "(try LEAK_HEAP and HANG_ON_LEAK to debug)\n",      \
                 inuse - _leak_start, __FILE__, __LINE__);              \
            if (getenv("HANG_ON_LEAK")) {                               \
                fprintf(stderr, "Hanging after leaks detected. "        \
                        "Leaks command:\n");                            \
                fprintf(stderr, "leaks %d\n", getpid());                \
                while (1) sleep(1);                                     \
            }                                                           \
        }                                                               \
    } while (0)

#else // TARGET_OS_EXCLAVEKIT

typedef int task_t;
typedef struct vm_range vm_range_t;

static inline void leak_recorder(task_t task __unused, void *ctx __unused, unsigned type __unused, vm_range_t *ranges __unused, unsigned count __unused) {}
static inline size_t leak_inuse(void) { return 0; }
static size_t _leak_start;
static inline void leak_mark(void) {}
#define leak_check(n)

#endif // TARGET_OS_EXCLAVEKIT

// true when running under Guard Malloc
static inline bool is_guardmalloc(void)
{
    const char *env = getenv("GUARDMALLOC");
    return (env  &&  0 == strcmp(env, "1"));
}

// true when running a debug build of libobjc
static inline bool is_debug(void)
{
    static int debugness = -1;
    if (debugness == -1) {
        debugness = dlsym(RTLD_DEFAULT, "_objc_isDebugBuild") ? 1 : 0;
    }
    return (bool)debugness;
}


/* Memory management compatibility macros */

static id self_fn(id x) __attribute__((used));
static id self_fn(id x) { return x; }

#if __has_feature(objc_arc_weak)
    // __weak
#   define WEAK_STORE(dst, val)      (dst = (val))
#   define WEAK_LOAD(src)            (src)
#else
    // no __weak
#   define WEAK_STORE(dst, val)      objc_storeWeak((id *)&dst, val)
#   define WEAK_LOAD(src)            objc_loadWeak((id *)&src)
#endif

#if __has_feature(objc_arc)
    // ARC
#   define RELEASE_VAR(x)            x = nil
#   define SUPER_DEALLOC() 
#   define RETAIN(x)                 (self_fn(x))
#   define RELEASE_VALUE(x)          ((void)self_fn(x))
#   define AUTORELEASE(x)            (self_fn(x))

#else
    // MRC
#   define RELEASE_VAR(x)            do { [x release]; x = nil; } while (0)
#   define SUPER_DEALLOC()           [super dealloc]
#   define RETAIN(x)                 [x retain]
#   define RELEASE_VALUE(x)          [x release]
#   define AUTORELEASE(x)            [x autorelease]
#endif

/* gcc compatibility macros */
/* <rdar://problem/9412038> @autoreleasepool should generate objc_autoreleasePoolPush/Pop on 10.7/5.0 */
//#if !defined(__clang__)
#   define PUSH_POOL { void *pool = objc_autoreleasePoolPush();
#   define POP_POOL objc_autoreleasePoolPop(pool); }
//#else
//#   define PUSH_POOL @autoreleasepool
//#   define POP_POOL
//#endif

#if __OBJC__

/* General purpose root class */

OBJC_ROOT_CLASS
@interface TestRoot {
 @public
    Class isa;
}

+(void) load;
+(void) initialize;

-(id) self;
-(Class) class;
-(Class) superclass;

+(id) new;
+(id) alloc;
+(id) allocWithZone:(void*)zone;
-(id) copy;
-(id) mutableCopy;
-(id) init;
-(void) dealloc;
@end
@interface TestRoot (RR)
-(id) retain;
-(oneway void) release;
-(id) autorelease;
-(unsigned long) retainCount;
-(id) copyWithZone:(void *)zone;
-(id) mutableCopyWithZone:(void*)zone;
@end

// incremented for each call of TestRoot's methods
extern atomic_int TestRootLoad;
extern atomic_int TestRootInitialize;
extern atomic_int TestRootAlloc;
extern atomic_int TestRootAllocWithZone;
extern atomic_int TestRootCopy;
extern atomic_int TestRootCopyWithZone;
extern atomic_int TestRootMutableCopy;
extern atomic_int TestRootMutableCopyWithZone;
extern atomic_int TestRootInit;
extern atomic_int TestRootDealloc;
extern atomic_int TestRootRetain;
extern atomic_int TestRootRelease;
extern atomic_int TestRootAutorelease;
extern atomic_int TestRootRetainCount;
extern atomic_int TestRootTryRetain;
extern atomic_int TestRootIsDeallocating;
extern atomic_int TestRootPlusRetain;
extern atomic_int TestRootPlusRelease;
extern atomic_int TestRootPlusAutorelease;
extern atomic_int TestRootPlusRetainCount;

#endif


// Struct that does not return in registers on any architecture

struct stret {
    int a;
    int b;
    int c;
    int d;
    int e;
    int f;
    int g;
    int h;
    int i;
    int j;
};

static inline BOOL stret_equal(struct stret a, struct stret b)
{
    return (a.a == b.a  &&  
            a.b == b.b  &&  
            a.c == b.c  &&  
            a.d == b.d  &&  
            a.e == b.e  &&  
            a.f == b.f  &&  
            a.g == b.g  &&  
            a.h == b.h  &&  
            a.i == b.i  &&  
            a.j == b.j);
}

static struct stret STRET_RESULT __attribute__((used)) = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10};


#if TARGET_OS_SIMULATOR
// Force cwd to executable's directory during launch.
// sim used to do this but simctl does not.
#include <crt_externs.h>
 __attribute__((constructor)) 
static void hack_cwd(void)
{
    if (!getenv("HACKED_CWD")) {
        chdir(dirname((*_NSGetArgv())[0]));
        setenv("HACKED_CWD", "1", 1);
    }
}
#endif

#endif
