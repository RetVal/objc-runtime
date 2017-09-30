/*
 * Copyright (c) 2007 Apple Inc.  All Rights Reserved.
 * 
 * @APPLE_LICENSE_HEADER_START@
 * 
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */

/***********************************************************************
* objc-os.h
* OS portability layer.
**********************************************************************/

#ifndef _OBJC_OS_H
#define _OBJC_OS_H

#include <TargetConditionals.h>
#include "objc-config.h"

#ifdef __LP64__
#   define WORD_SHIFT 3UL
#   define WORD_MASK 7UL
#   define WORD_BITS 64
#else
#   define WORD_SHIFT 2UL
#   define WORD_MASK 3UL
#   define WORD_BITS 32
#endif

static inline uint32_t word_align(uint32_t x) {
    return (x + WORD_MASK) & ~WORD_MASK;
}
static inline size_t word_align(size_t x) {
    return (x + WORD_MASK) & ~WORD_MASK;
}


// Mix-in for classes that must not be copied.
class nocopy_t {
  private:
    nocopy_t(const nocopy_t&) = delete;
    const nocopy_t& operator=(const nocopy_t&) = delete;
  protected:
    nocopy_t() { }
    ~nocopy_t() { }
};


#if TARGET_OS_MAC

#   define OS_UNFAIR_LOCK_INLINE 1

#   ifndef __STDC_LIMIT_MACROS
#       define __STDC_LIMIT_MACROS
#   endif

#   include <stdio.h>
#   include <stdlib.h>
#   include <stdint.h>
#   include <stdarg.h>
#   include <string.h>
#   include <ctype.h>
#   include <errno.h>
#   include <dlfcn.h>
#   include <fcntl.h>
#   include <assert.h>
#   include <limits.h>
#   include <syslog.h>
#   include <unistd.h>
#   include <pthread.h>
#   include <crt_externs.h>
#   undef check
#   include <Availability.h>
#   include <TargetConditionals.h>
#   include <sys/mman.h>
#   include <sys/time.h>
#   include <sys/stat.h>
#   include <sys/param.h>
#   include <sys/reason.h>
#   include <mach/mach.h>
#   include <mach/vm_param.h>
#   include <mach/mach_time.h>
#   include <mach-o/dyld.h>
#   include <mach-o/ldsyms.h>
#   include <mach-o/loader.h>
#   include <mach-o/getsect.h>
#   include <mach-o/dyld_priv.h>
#   include <malloc/malloc.h>
//#   include <os/lock_private.h>
#   include <os/lock.h>
#   include <libkern/OSAtomic.h>
#   include <libkern/OSCacheControl.h>
#   include <System/pthread_machdep.h>
#   include "objc-probes.h"  // generated dtrace probe definitions.

// Some libc functions call objc_msgSend() 
// so we can't use them without deadlocks.
void syslog(int, const char *, ...) UNAVAILABLE_ATTRIBUTE;
void vsyslog(int, const char *, va_list) UNAVAILABLE_ATTRIBUTE;


#define ALWAYS_INLINE inline __attribute__((always_inline))
#define NEVER_INLINE inline __attribute__((noinline))

#define fastpath(x) (__builtin_expect(bool(x), 1))
#define slowpath(x) (__builtin_expect(bool(x), 0))

typedef OSSpinLock os_lock_handoff_s;
#define OS_LOCK_HANDOFF_INIT OS_SPINLOCK_INIT

ALWAYS_INLINE void os_lock_lock(volatile os_lock_handoff_s *lock) {
    return OSSpinLockLock(lock);
}

ALWAYS_INLINE void os_lock_unlock(volatile os_lock_handoff_s *lock) {
    return OSSpinLockUnlock(lock);
}

ALWAYS_INLINE bool os_lock_trylock(volatile os_lock_handoff_s *lock) {
    return OSSpinLockTry(lock);
}

static ALWAYS_INLINE uintptr_t 
addc(uintptr_t lhs, uintptr_t rhs, uintptr_t carryin, uintptr_t *carryout)
{
    return __builtin_addcl(lhs, rhs, carryin, carryout);
}

static ALWAYS_INLINE uintptr_t 
subc(uintptr_t lhs, uintptr_t rhs, uintptr_t carryin, uintptr_t *carryout)
{
    return __builtin_subcl(lhs, rhs, carryin, carryout);
}


#if __arm64__

static ALWAYS_INLINE
uintptr_t 
LoadExclusive(uintptr_t *src)
{
    uintptr_t result;
    asm("ldxr %x0, [%x1]" 
        : "=r" (result) 
        : "r" (src), "m" (*src));
    return result;
}

static ALWAYS_INLINE
bool 
StoreExclusive(uintptr_t *dst, uintptr_t oldvalue __unused, uintptr_t value)
{
    uint32_t result;
    asm("stxr %w0, %x2, [%x3]" 
        : "=r" (result), "=m" (*dst) 
        : "r" (value), "r" (dst));
    return !result;
}


static ALWAYS_INLINE
bool 
StoreReleaseExclusive(uintptr_t *dst, uintptr_t oldvalue __unused, uintptr_t value)
{
    uint32_t result;
    asm("stlxr %w0, %x2, [%x3]" 
        : "=r" (result), "=m" (*dst) 
        : "r" (value), "r" (dst));
    return !result;
}

static ALWAYS_INLINE
void 
ClearExclusive(uintptr_t *dst)
{
    // pretend it writes to *dst for instruction ordering purposes
    asm("clrex" : "=m" (*dst));
}


#elif __arm__  

static ALWAYS_INLINE
uintptr_t 
LoadExclusive(uintptr_t *src)
{
    return *src;
}

static ALWAYS_INLINE
bool 
StoreExclusive(uintptr_t *dst, uintptr_t oldvalue, uintptr_t value)
{
    return OSAtomicCompareAndSwapPtr((void *)oldvalue, (void *)value, 
                                     (void **)dst);
}

static ALWAYS_INLINE
bool 
StoreReleaseExclusive(uintptr_t *dst, uintptr_t oldvalue, uintptr_t value)
{
    return OSAtomicCompareAndSwapPtrBarrier((void *)oldvalue, (void *)value, 
                                            (void **)dst);
}

static ALWAYS_INLINE
void 
ClearExclusive(uintptr_t *dst __unused)
{
}


#elif __x86_64__  ||  __i386__

static ALWAYS_INLINE
uintptr_t 
LoadExclusive(uintptr_t *src)
{
    return *src;
}

static ALWAYS_INLINE
bool 
StoreExclusive(uintptr_t *dst, uintptr_t oldvalue, uintptr_t value)
{
    
    return __sync_bool_compare_and_swap((void **)dst, (void *)oldvalue, (void *)value);
}

static ALWAYS_INLINE
bool 
StoreReleaseExclusive(uintptr_t *dst, uintptr_t oldvalue, uintptr_t value)
{
    return StoreExclusive(dst, oldvalue, value);
}

static ALWAYS_INLINE
void 
ClearExclusive(uintptr_t *dst __unused)
{
}


#else 
#   error unknown architecture
#endif


#if !TARGET_OS_IPHONE
#   include <CrashReporterClient.h>
#else
    // CrashReporterClient not yet available on iOS
    __BEGIN_DECLS
    extern const char *CRSetCrashLogMessage(const char *msg);
    extern const char *CRGetCrashLogMessage(void);
    extern const char *CRGetCrashLogMessage2(const char *msg);
    __END_DECLS
#endif

#   if __cplusplus
#       include <vector>
#       include <algorithm>
#       include <functional>
        using namespace std;
#   endif

#   define PRIVATE_EXTERN __attribute__((visibility("hidden")))
#   undef __private_extern__
#   define __private_extern__ use_PRIVATE_EXTERN_instead
#   undef private_extern
#   define private_extern use_PRIVATE_EXTERN_instead

/* Use this for functions that are intended to be breakpoint hooks.
   If you do not, the compiler may optimize them away.
   BREAKPOINT_FUNCTION( void stop_on_error(void) ); */
#   define BREAKPOINT_FUNCTION(prototype)                             \
    OBJC_EXTERN __attribute__((noinline, used, visibility("hidden"))) \
    prototype { asm(""); }

#elif TARGET_OS_WIN32

#   define WINVER 0x0501		// target Windows XP and later
#   define _WIN32_WINNT 0x0501	// target Windows XP and later
#   define WIN32_LEAN_AND_MEAN
    // hack: windef.h typedefs BOOL as int
#   define BOOL WINBOOL
#   include <windows.h>
#   undef BOOL

#   include <stdio.h>
#   include <stdlib.h>
#   include <stdint.h>
#   include <stdarg.h>
#   include <string.h>
#   include <assert.h>
#   include <malloc.h>
#   include <Availability.h>

#   if __cplusplus
#       include <vector>
#       include <algorithm>
#       include <functional>
        using namespace std;
#       define __BEGIN_DECLS extern "C" {
#       define __END_DECLS   }
#   else
#       define __BEGIN_DECLS /*empty*/
#       define __END_DECLS   /*empty*/
#   endif

#   define PRIVATE_EXTERN
#   define __attribute__(x)
#   define inline __inline

/* Use this for functions that are intended to be breakpoint hooks.
   If you do not, the compiler may optimize them away.
   BREAKPOINT_FUNCTION( void MyBreakpointFunction(void) ); */
#   define BREAKPOINT_FUNCTION(prototype) \
    __declspec(noinline) prototype { __asm { } }

/* stub out dtrace probes */
#   define OBJC_RUNTIME_OBJC_EXCEPTION_RETHROW() do {} while(0)  
#   define OBJC_RUNTIME_OBJC_EXCEPTION_THROW(arg0) do {} while(0)

#else
#   error unknown OS
#endif


#include <objc/objc.h>
#include <objc/objc-api.h>

extern void _objc_fatal(const char *fmt, ...) 
    __attribute__((noreturn, format (printf, 1, 2)));
extern void _objc_fatal_with_reason(uint64_t reason, uint64_t flags, 
                                    const char *fmt, ...) 
    __attribute__((noreturn, format (printf, 3, 4)));

#define INIT_ONCE_PTR(var, create, delete)                              \
    do {                                                                \
        if (var) break;                                                 \
        __typeof__(var) v = create;                                         \
        while (!var) {                                                  \
            if (OSAtomicCompareAndSwapPtrBarrier(0, (void*)v, (void**)&var)){ \
                goto done;                                              \
            }                                                           \
        }                                                               \
        delete;                                                         \
    done:;                                                              \
    } while (0)

#define INIT_ONCE_32(var, create, delete)                               \
    do {                                                                \
        if (var) break;                                                 \
        __typeof__(var) v = create;                                         \
        while (!var) {                                                  \
            if (OSAtomicCompareAndSwap32Barrier(0, v, (volatile int32_t *)&var)) { \
                goto done;                                              \
            }                                                           \
        }                                                               \
        delete;                                                         \
    done:;                                                              \
    } while (0)


// Thread keys reserved by libc for our use.
#if defined(__PTK_FRAMEWORK_OBJC_KEY0)
#   define SUPPORT_DIRECT_THREAD_KEYS 1
#   define TLS_DIRECT_KEY        ((tls_key_t)__PTK_FRAMEWORK_OBJC_KEY0)
#   define SYNC_DATA_DIRECT_KEY  ((tls_key_t)__PTK_FRAMEWORK_OBJC_KEY1)
#   define SYNC_COUNT_DIRECT_KEY ((tls_key_t)__PTK_FRAMEWORK_OBJC_KEY2)
#   define AUTORELEASE_POOL_KEY  ((tls_key_t)__PTK_FRAMEWORK_OBJC_KEY3)
# if SUPPORT_RETURN_AUTORELEASE
#   define RETURN_DISPOSITION_KEY ((tls_key_t)__PTK_FRAMEWORK_OBJC_KEY4)
# endif
# if SUPPORT_QOS_HACK
#   define QOS_KEY               ((tls_key_t)__PTK_FRAMEWORK_OBJC_KEY5)
# endif
#else
#   define SUPPORT_DIRECT_THREAD_KEYS 0
#endif


#if TARGET_OS_WIN32

// Compiler compatibility

// OS compatibility

#define strdup _strdup

#define issetugid() 0

#define MIN(x, y) ((x) < (y) ? (x) : (y))

static __inline void bcopy(const void *src, void *dst, size_t size) { memcpy(dst, src, size); }
static __inline void bzero(void *dst, size_t size) { memset(dst, 0, size); }

int asprintf(char **dstp, const char *format, ...);

typedef void * malloc_zone_t;

static __inline malloc_zone_t malloc_default_zone(void) { return (malloc_zone_t)-1; }
static __inline void *malloc_zone_malloc(malloc_zone_t z, size_t size) { return malloc(size); }
static __inline void *malloc_zone_calloc(malloc_zone_t z, size_t size, size_t count) { return calloc(size, count); }
static __inline void *malloc_zone_realloc(malloc_zone_t z, void *p, size_t size) { return realloc(p, size); }
static __inline void malloc_zone_free(malloc_zone_t z, void *p) { free(p); }
static __inline malloc_zone_t malloc_zone_from_ptr(const void *p) { return (malloc_zone_t)-1; }
static __inline size_t malloc_size(const void *p) { return _msize((void*)p); /* fixme invalid pointer check? */ }


// OSAtomic

static __inline BOOL OSAtomicCompareAndSwapLong(long oldl, long newl, long volatile *dst) 
{ 
    // fixme barrier is overkill
    long original = InterlockedCompareExchange(dst, newl, oldl);
    return (original == oldl);
}

static __inline BOOL OSAtomicCompareAndSwapPtrBarrier(void *oldp, void *newp, void * volatile *dst) 
{ 
    void *original = InterlockedCompareExchangePointer(dst, newp, oldp);
    return (original == oldp);
}

static __inline BOOL OSAtomicCompareAndSwap32Barrier(int32_t oldl, int32_t newl, int32_t volatile *dst) 
{ 
    long original = InterlockedCompareExchange((volatile long *)dst, newl, oldl);
    return (original == oldl);
}

static __inline int32_t OSAtomicDecrement32Barrier(volatile int32_t *dst)
{
    return InterlockedDecrement((volatile long *)dst);
}

static __inline int32_t OSAtomicIncrement32Barrier(volatile int32_t *dst)
{
    return InterlockedIncrement((volatile long *)dst);
}


// Internal data types

typedef DWORD objc_thread_t;  // thread ID
static __inline int thread_equal(objc_thread_t t1, objc_thread_t t2) { 
    return t1 == t2; 
}
static __inline objc_thread_t thread_self(void) { 
    return GetCurrentThreadId(); 
}

typedef struct {
    DWORD key;
    void (*dtor)(void *);
} tls_key_t;
static __inline tls_key_t tls_create(void (*dtor)(void*)) { 
    // fixme need dtor registry for DllMain to call on thread detach
    tls_key_t k;
    k.key = TlsAlloc();
    k.dtor = dtor;
    return k;
}
static __inline void *tls_get(tls_key_t k) { 
    return TlsGetValue(k.key); 
}
static __inline void tls_set(tls_key_t k, void *value) { 
    TlsSetValue(k.key, value); 
}

typedef struct {
    CRITICAL_SECTION *lock;
} mutex_t;
#define MUTEX_INITIALIZER {0};
extern void mutex_init(mutex_t *m);
static __inline int _mutex_lock_nodebug(mutex_t *m) { 
    // fixme error check
    if (!m->lock) {
        mutex_init(m);
    }
    EnterCriticalSection(m->lock); 
    return 0;
}
static __inline bool _mutex_try_lock_nodebug(mutex_t *m) { 
    // fixme error check
    if (!m->lock) {
        mutex_init(m);
    }
    return TryEnterCriticalSection(m->lock); 
}
static __inline int _mutex_unlock_nodebug(mutex_t *m) { 
    // fixme error check
    LeaveCriticalSection(m->lock); 
    return 0;
}


typedef mutex_t spinlock_t;
#define spinlock_lock(l) mutex_lock(l)
#define spinlock_unlock(l) mutex_unlock(l)
#define SPINLOCK_INITIALIZER MUTEX_INITIALIZER


typedef struct {
    HANDLE mutex;
} recursive_mutex_t;
#define RECURSIVE_MUTEX_INITIALIZER {0};
#define RECURSIVE_MUTEX_NOT_LOCKED 1
extern void recursive_mutex_init(recursive_mutex_t *m);
static __inline int _recursive_mutex_lock_nodebug(recursive_mutex_t *m) { 
    assert(m->mutex);
    return WaitForSingleObject(m->mutex, INFINITE);
}
static __inline bool _recursive_mutex_try_lock_nodebug(recursive_mutex_t *m) { 
    assert(m->mutex);
    return (WAIT_OBJECT_0 == WaitForSingleObject(m->mutex, 0));
}
static __inline int _recursive_mutex_unlock_nodebug(recursive_mutex_t *m) { 
    assert(m->mutex);
    return ReleaseMutex(m->mutex) ? 0 : RECURSIVE_MUTEX_NOT_LOCKED;
}


/*
typedef HANDLE mutex_t;
static inline void mutex_init(HANDLE *m) { *m = CreateMutex(NULL, FALSE, NULL); }
static inline void _mutex_lock(mutex_t *m) { WaitForSingleObject(*m, INFINITE); }
static inline bool mutex_try_lock(mutex_t *m) { return WaitForSingleObject(*m, 0) == WAIT_OBJECT_0; }
static inline void _mutex_unlock(mutex_t *m) { ReleaseMutex(*m); }
*/

// based on http://www.cs.wustl.edu/~schmidt/win32-cv-1.html
// Vista-only CONDITION_VARIABLE would be better
typedef struct {
    HANDLE mutex;
    HANDLE waiters;      // semaphore for those in cond_wait()
    HANDLE waitersDone;  // auto-reset event after everyone gets a broadcast
    CRITICAL_SECTION waitCountLock;  // guards waitCount and didBroadcast
    unsigned int waitCount;
    int didBroadcast; 
} monitor_t;
#define MONITOR_INITIALIZER { 0 }
#define MONITOR_NOT_ENTERED 1
extern int monitor_init(monitor_t *c);

static inline int _monitor_enter_nodebug(monitor_t *c) {
    if (!c->mutex) {
        int err = monitor_init(c);
        if (err) return err;
    }
    return WaitForSingleObject(c->mutex, INFINITE);
}
static inline int _monitor_leave_nodebug(monitor_t *c) {
    if (!ReleaseMutex(c->mutex)) return MONITOR_NOT_ENTERED;
    else return 0;
}
static inline int _monitor_wait_nodebug(monitor_t *c) { 
    int last;
    EnterCriticalSection(&c->waitCountLock);
    c->waitCount++;
    LeaveCriticalSection(&c->waitCountLock);

    SignalObjectAndWait(c->mutex, c->waiters, INFINITE, FALSE);

    EnterCriticalSection(&c->waitCountLock);
    c->waitCount--;
    last = c->didBroadcast  &&  c->waitCount == 0;
    LeaveCriticalSection(&c->waitCountLock);

    if (last) {
        // tell broadcaster that all waiters have awoken
        SignalObjectAndWait(c->waitersDone, c->mutex, INFINITE, FALSE);
    } else {
        WaitForSingleObject(c->mutex, INFINITE);
    }

    // fixme error checking
    return 0;
}
static inline int monitor_notify(monitor_t *c) { 
    int haveWaiters;

    EnterCriticalSection(&c->waitCountLock);
    haveWaiters = c->waitCount > 0;
    LeaveCriticalSection(&c->waitCountLock);

    if (haveWaiters) {
        ReleaseSemaphore(c->waiters, 1, 0);
    }

    // fixme error checking
    return 0;
}
static inline int monitor_notifyAll(monitor_t *c) { 
    EnterCriticalSection(&c->waitCountLock);
    if (c->waitCount == 0) {
        LeaveCriticalSection(&c->waitCountLock);
        return 0;
    }
    c->didBroadcast = 1;
    ReleaseSemaphore(c->waiters, c->waitCount, 0);
    LeaveCriticalSection(&c->waitCountLock);

    // fairness: wait for everyone to move from waiters to mutex
    WaitForSingleObject(c->waitersDone, INFINITE);
    // not under waitCountLock, but still under mutex
    c->didBroadcast = 0;

    // fixme error checking
    return 0;
}


// fixme no rwlock yet


typedef IMAGE_DOS_HEADER headerType;
// fixme YES bundle? NO bundle? sometimes?
#define headerIsBundle(hi) YES
OBJC_EXTERN IMAGE_DOS_HEADER __ImageBase;
#define libobjc_header ((headerType *)&__ImageBase)

// Prototypes


#elif TARGET_OS_MAC


// OS headers
#include <mach-o/loader.h>
#ifndef __LP64__
#   define SEGMENT_CMD LC_SEGMENT
#else
#   define SEGMENT_CMD LC_SEGMENT_64
#endif

#ifndef VM_MEMORY_OBJC_DISPATCHERS
#   define VM_MEMORY_OBJC_DISPATCHERS 0
#endif


// Compiler compatibility

// OS compatibility

static inline uint64_t nanoseconds() {
    return mach_absolute_time();
}

// Internal data types

typedef pthread_t objc_thread_t;

static __inline int thread_equal(objc_thread_t t1, objc_thread_t t2) { 
    return pthread_equal(t1, t2); 
}
static __inline objc_thread_t thread_self(void) { 
    return pthread_self(); 
}


typedef pthread_key_t tls_key_t;

static inline tls_key_t tls_create(void (*dtor)(void*)) { 
    tls_key_t k;
    pthread_key_create(&k, dtor); 
    return k;
}
static inline void *tls_get(tls_key_t k) { 
    return pthread_getspecific(k); 
}
static inline void tls_set(tls_key_t k, void *value) { 
    pthread_setspecific(k, value); 
}

#if SUPPORT_DIRECT_THREAD_KEYS

#if DEBUG
static bool is_valid_direct_key(tls_key_t k) {
    return (   k == SYNC_DATA_DIRECT_KEY
            || k == SYNC_COUNT_DIRECT_KEY
            || k == AUTORELEASE_POOL_KEY
#   if SUPPORT_RETURN_AUTORELEASE
            || k == RETURN_DISPOSITION_KEY
#   endif
#   if SUPPORT_QOS_HACK
            || k == QOS_KEY
#   endif
               );
}
#endif

static inline void *tls_get_direct(tls_key_t k) 
{ 
    assert(is_valid_direct_key(k));

    if (_pthread_has_direct_tsd()) {
        return _pthread_getspecific_direct(k);
    } else {
        return pthread_getspecific(k);
    }
}
static inline void tls_set_direct(tls_key_t k, void *value) 
{ 
    assert(is_valid_direct_key(k));

    if (_pthread_has_direct_tsd()) {
        _pthread_setspecific_direct(k, value);
    } else {
        pthread_setspecific(k, value);
    }
}

// SUPPORT_DIRECT_THREAD_KEYS
#endif


static inline pthread_t pthread_self_direct()
{
    return (pthread_t)
        _pthread_getspecific_direct(_PTHREAD_TSD_SLOT_PTHREAD_SELF);
}

static inline mach_port_t mach_thread_self_direct() 
{
    return (mach_port_t)(uintptr_t)
        _pthread_getspecific_direct(_PTHREAD_TSD_SLOT_MACH_THREAD_SELF);
}

#include <pthread/tsd_private.h>

#if SUPPORT_QOS_HACK

#include <pthread/qos_private.h>

static inline pthread_priority_t pthread_self_priority_direct() 
{
    pthread_priority_t pri = (pthread_priority_t)
        _pthread_getspecific_direct(_PTHREAD_TSD_SLOT_PTHREAD_QOS_CLASS);
    return pri & ~_PTHREAD_PRIORITY_FLAGS_MASK;
}
#endif


template <bool Debug> class mutex_tt;
template <bool Debug> class monitor_tt;
template <bool Debug> class rwlock_tt;
template <bool Debug> class recursive_mutex_tt;

#if DEBUG
#   define LOCKDEBUG 1
#else
#   define LOCKDEBUG 0
#endif

using spinlock_t = mutex_tt<LOCKDEBUG>;
using mutex_t = mutex_tt<LOCKDEBUG>;
using monitor_t = monitor_tt<LOCKDEBUG>;
using rwlock_t = rwlock_tt<LOCKDEBUG>;
using recursive_mutex_t = recursive_mutex_tt<LOCKDEBUG>;

//extern "C" void os_unfair_lock_assert_owner(os_unfair_lock *);
//extern "C" void os_unfair_lock_assert_not_owner(os_unfair_lock *);
extern "C" void os_unfair_lock_unlock(os_unfair_lock *);
extern "C" void os_unfair_lock_lock_with_options(os_unfair_lock *, uint32_t options);

// Use fork_unsafe_lock to get a lock that isn't 
// acquired and released around fork().
// All fork-safe locks are checked in debug builds.
struct fork_unsafe_lock_t { };
extern const fork_unsafe_lock_t fork_unsafe_lock;

inline void os_unfair_lock_lock_with_options_inline(os_unfair_lock *unfair_lock, uint32_t options) {
    os_unfair_lock_lock_with_options(unfair_lock, options);
}

inline void os_unfair_lock_unlock_inline(os_unfair_lock *unfair_lock) {
    os_unfair_lock_unlock(unfair_lock);
}

#ifndef OS_UNFAIR_LOCK_DATA_SYNCHRONIZATION
#define OS_UNFAIR_LOCK_DATA_SYNCHRONIZATION 0x10000
#endif

#include "objc-lockdebug.h"

template <bool Debug>
class mutex_tt : nocopy_t {
    os_unfair_lock mLock;
 public:
    mutex_tt() : mLock(OS_UNFAIR_LOCK_INIT) {
        lockdebug_remember_mutex(this);
    }

    mutex_tt(const fork_unsafe_lock_t unsafe) : mLock(OS_UNFAIR_LOCK_INIT) { }

    void lock() {
        lockdebug_mutex_lock(this);

        os_unfair_lock_lock_with_options_inline
            (&mLock, OS_UNFAIR_LOCK_DATA_SYNCHRONIZATION);
    }

    void unlock() {
        lockdebug_mutex_unlock(this);

        os_unfair_lock_unlock_inline(&mLock);
    }

    void forceReset() {
        lockdebug_mutex_unlock(this);

        bzero(&mLock, sizeof(mLock));
        mLock = os_unfair_lock OS_UNFAIR_LOCK_INIT;
    }

    void assertLocked() {
        lockdebug_mutex_assert_locked(this);
    }

    void assertUnlocked() {
        lockdebug_mutex_assert_unlocked(this);
    }


    // Address-ordered lock discipline for a pair of locks.

    static void lockTwo(mutex_tt *lock1, mutex_tt *lock2) {
        if (lock1 < lock2) {
            lock1->lock();
            lock2->lock();
        } else {
            lock2->lock();
            if (lock2 != lock1) lock1->lock(); 
        }
    }

    static void unlockTwo(mutex_tt *lock1, mutex_tt *lock2) {
        lock1->unlock();
        if (lock2 != lock1) lock2->unlock();
    }

    // Scoped lock and unlock
    class locker : nocopy_t {
        mutex_tt& lock;
    public:
        locker(mutex_tt& newLock) 
            : lock(newLock) { lock.lock(); }
        ~locker() { lock.unlock(); }
    };
};

using mutex_locker_t = mutex_tt<LOCKDEBUG>::locker;


template <bool Debug>
class recursive_mutex_tt : nocopy_t {
    pthread_mutex_t mLock;

  public:
    recursive_mutex_tt() : mLock((pthread_mutex_t)PTHREAD_RECURSIVE_MUTEX_INITIALIZER) {
        lockdebug_remember_recursive_mutex(this);
    }

    recursive_mutex_tt(const fork_unsafe_lock_t unsafe)
        : mLock((pthread_mutex_t)PTHREAD_RECURSIVE_MUTEX_INITIALIZER)
    { }

    void lock()
    {
        lockdebug_recursive_mutex_lock(this);

        int err = pthread_mutex_lock(&mLock);
        if (err) _objc_fatal("pthread_mutex_lock failed (%d)", err);
    }

    void unlock()
    {
        lockdebug_recursive_mutex_unlock(this);

        int err = pthread_mutex_unlock(&mLock);
        if (err) _objc_fatal("pthread_mutex_unlock failed (%d)", err);
    }

    void forceReset()
    {
        lockdebug_recursive_mutex_unlock(this);

        bzero(&mLock, sizeof(mLock));
        mLock = (pthread_mutex_t)PTHREAD_RECURSIVE_MUTEX_INITIALIZER;
    }

    bool tryUnlock()
    {
        int err = pthread_mutex_unlock(&mLock);
        if (err == 0) {
            lockdebug_recursive_mutex_unlock(this);
            return true;
        } else if (err == EPERM) {
            return false;
        } else {
            _objc_fatal("pthread_mutex_unlock failed (%d)", err);
        }
    }


    void assertLocked() {
        lockdebug_recursive_mutex_assert_locked(this);
    }

    void assertUnlocked() {
        lockdebug_recursive_mutex_assert_unlocked(this);
    }
};


template <bool Debug>
class monitor_tt {
    pthread_mutex_t mutex;
    pthread_cond_t cond;

  public:
    monitor_tt() 
        : mutex((pthread_mutex_t)PTHREAD_MUTEX_INITIALIZER), cond((pthread_cond_t)PTHREAD_COND_INITIALIZER)
    {
        lockdebug_remember_monitor(this);
    }

    monitor_tt(const fork_unsafe_lock_t unsafe) 
        : mutex((pthread_mutex_t)PTHREAD_MUTEX_INITIALIZER), cond((pthread_cond_t)PTHREAD_COND_INITIALIZER)
    { }

    void enter() 
    {
        lockdebug_monitor_enter(this);

        int err = pthread_mutex_lock(&mutex);
        if (err) _objc_fatal("pthread_mutex_lock failed (%d)", err);
    }

    void leave() 
    {
        lockdebug_monitor_leave(this);

        int err = pthread_mutex_unlock(&mutex);
        if (err) _objc_fatal("pthread_mutex_unlock failed (%d)", err);
    }

    void wait() 
    {
        lockdebug_monitor_wait(this);

        int err = pthread_cond_wait(&cond, &mutex);
        if (err) _objc_fatal("pthread_cond_wait failed (%d)", err);
    }

    void notify() 
    {
        int err = pthread_cond_signal(&cond);
        if (err) _objc_fatal("pthread_cond_signal failed (%d)", err);        
    }

    void notifyAll() 
    {
        int err = pthread_cond_broadcast(&cond);
        if (err) _objc_fatal("pthread_cond_broadcast failed (%d)", err);        
    }

    void forceReset()
    {
        lockdebug_monitor_leave(this);
        
        bzero(&mutex, sizeof(mutex));
        bzero(&cond, sizeof(cond));
        mutex = (pthread_mutex_t)PTHREAD_MUTEX_INITIALIZER;
        cond = (pthread_cond_t)PTHREAD_COND_INITIALIZER;
    }

    void assertLocked()
    {
        lockdebug_monitor_assert_locked(this);
    }

    void assertUnlocked()
    {
        lockdebug_monitor_assert_unlocked(this);
    }
};


// semaphore_create formatted for INIT_ONCE use
static inline semaphore_t create_semaphore(void)
{
    semaphore_t sem;
    kern_return_t k;
    k = semaphore_create(mach_task_self(), &sem, SYNC_POLICY_FIFO, 0);
    if (k) _objc_fatal("semaphore_create failed (0x%x)", k);
    return sem;
}


#if SUPPORT_QOS_HACK
// Override QOS class to avoid priority inversion in rwlocks
// <rdar://17697862> do a qos override before taking rw lock in objc

#include <pthread/workqueue_private.h>
extern pthread_priority_t BackgroundPriority;
extern pthread_priority_t MainPriority;

static inline void qosStartOverride()
{
    uintptr_t overrideRefCount = (uintptr_t)tls_get_direct(QOS_KEY);
    if (overrideRefCount > 0) {
        // If there is a qos override, increment the refcount and continue
        tls_set_direct(QOS_KEY, (void *)(overrideRefCount + 1));
    }
    else {
        pthread_priority_t currentPriority = pthread_self_priority_direct();
        // Check if override is needed. Only override if we are background qos
        if (currentPriority != 0  &&  currentPriority <= BackgroundPriority) {
            int res __unused = _pthread_override_qos_class_start_direct(mach_thread_self_direct(), MainPriority);
            assert(res == 0);
            // Once we override, we set the reference count in the tsd 
            // to know when to end the override
            tls_set_direct(QOS_KEY, (void *)1);
        }
    }
}

static inline void qosEndOverride()
{
    uintptr_t overrideRefCount = (uintptr_t)tls_get_direct(QOS_KEY);
    if (overrideRefCount == 0) return;

    if (overrideRefCount == 1) {
        // end the override
        int res __unused = _pthread_override_qos_class_end_direct(mach_thread_self_direct());
        assert(res == 0);
    }

    // decrement refcount
    tls_set_direct(QOS_KEY, (void *)(overrideRefCount - 1));
}

// SUPPORT_QOS_HACK
#else
// not SUPPORT_QOS_HACK

static inline void qosStartOverride() { }
static inline void qosEndOverride() { }

// not SUPPORT_QOS_HACK
#endif


template <bool Debug>
class rwlock_tt : nocopy_t {
    pthread_rwlock_t mLock;

  public:
    rwlock_tt() : mLock((pthread_rwlock_t)PTHREAD_RWLOCK_INITIALIZER) {
        lockdebug_remember_rwlock(this);
    }

    rwlock_tt(const fork_unsafe_lock_t unsafe)
        : mLock((pthread_rwlock_t)PTHREAD_RWLOCK_INITIALIZER)
    { }
    
    void read() 
    {
        lockdebug_rwlock_read(this);

        qosStartOverride();
        int err = pthread_rwlock_rdlock(&mLock);
        if (err) _objc_fatal("pthread_rwlock_rdlock failed (%d)", err);
    }

    void unlockRead()
    {
        lockdebug_rwlock_unlock_read(this);

        int err = pthread_rwlock_unlock(&mLock);
        if (err) _objc_fatal("pthread_rwlock_unlock failed (%d)", err);
        qosEndOverride();
    }

    bool tryRead()
    {
        qosStartOverride();
        int err = pthread_rwlock_tryrdlock(&mLock);
        if (err == 0) {
            lockdebug_rwlock_try_read_success(this);
            return true;
        } else if (err == EBUSY) {
            qosEndOverride();
            return false;
        } else {
            _objc_fatal("pthread_rwlock_tryrdlock failed (%d)", err);
        }
    }

    void write()
    {
        lockdebug_rwlock_write(this);

        qosStartOverride();
        int err = pthread_rwlock_wrlock(&mLock);
        if (err) _objc_fatal("pthread_rwlock_wrlock failed (%d)", err);
    }

    void unlockWrite()
    {
        lockdebug_rwlock_unlock_write(this);

        int err = pthread_rwlock_unlock(&mLock);
        if (err) _objc_fatal("pthread_rwlock_unlock failed (%d)", err);
        qosEndOverride();
    }

    bool tryWrite()
    {
        qosStartOverride();
        int err = pthread_rwlock_trywrlock(&mLock);
        if (err == 0) {
            lockdebug_rwlock_try_write_success(this);
            return true;
        } else if (err == EBUSY) {
            qosEndOverride();
            return false;
        } else {
            _objc_fatal("pthread_rwlock_trywrlock failed (%d)", err);
        }
    }

    void forceReset()
    {
        lockdebug_rwlock_unlock_write(this);

        bzero(&mLock, sizeof(mLock));
        mLock = (pthread_rwlock_t)PTHREAD_RWLOCK_INITIALIZER;
    }


    void assertReading() {
        lockdebug_rwlock_assert_reading(this);
    }

    void assertWriting() {
        lockdebug_rwlock_assert_writing(this);
    }

    void assertLocked() {
        lockdebug_rwlock_assert_locked(this);
    }

    void assertUnlocked() {
        lockdebug_rwlock_assert_unlocked(this);
    }
};


#ifndef __LP64__
typedef struct mach_header headerType;
typedef struct segment_command segmentType;
typedef struct section sectionType;
#else
typedef struct mach_header_64 headerType;
typedef struct segment_command_64 segmentType;
typedef struct section_64 sectionType;
#endif
#define headerIsBundle(hi) (hi->mhdr()->filetype == MH_BUNDLE)
#define libobjc_header ((headerType *)&_mh_dylib_header)

// Prototypes

/* Secure /tmp usage */
extern int secure_open(const char *filename, int flags, uid_t euid);


#else


#error unknown OS


#endif


static inline void *
memdup(const void *mem, size_t len)
{
    void *dup = malloc(len);
    memcpy(dup, mem, len);
    return dup;
}

// strdup that doesn't copy read-only memory
static inline char *
strdupIfMutable(const char *str)
{
    size_t size = strlen(str) + 1;
    if (_dyld_is_memory_immutable(str, size)) {
        return (char *)str;
    } else {
        return (char *)memdup(str, size);
    }
}

// free strdupIfMutable() result
static inline void
freeIfMutable(char *str)
{
    size_t size = strlen(str) + 1;
    if (_dyld_is_memory_immutable(str, size)) {
        // nothing
    } else {
        free(str);
    }
}

// nil-checking unsigned strdup
static inline uint8_t *
ustrdupMaybeNil(const uint8_t *str)
{
    if (!str) return nil;
    return (uint8_t *)strdupIfMutable((char *)str);
}

// OS version checking:
//
// sdkVersion()
// DYLD_OS_VERSION(mac, ios, tv, watch, bridge)
// sdkIsOlderThan(mac, ios, tv, watch, bridge)
// sdkIsAtLeast(mac, ios, tv, watch, bridge)
// 
// This version order matches OBJC_AVAILABLE.

#if TARGET_OS_OSX
#   define DYLD_OS_VERSION(x, i, t, w, b) DYLD_MACOSX_VERSION_##x
#   define sdkVersion() dyld_get_program_sdk_version()

#elif TARGET_OS_IOS
#   define DYLD_OS_VERSION(x, i, t, w, b) DYLD_IOS_VERSION_##i
#   define sdkVersion() dyld_get_program_sdk_version()

#elif TARGET_OS_TV
    // dyld does not currently have distinct constants for tvOS
#   define DYLD_OS_VERSION(x, i, t, w, b) DYLD_IOS_VERSION_##t
#   define sdkVersion() dyld_get_program_sdk_version()

#elif TARGET_OS_BRIDGE
#   if TARGET_OS_WATCH
#       error bridgeOS 1.0 not supported
#   endif
    // fixme don't need bridgeOS versioning yet
#   define DYLD_OS_VERSION(x, i, t, w, b) DYLD_IOS_VERSION_##t
#   define sdkVersion() dyld_get_program_sdk_bridge_os_version()

#elif TARGET_OS_WATCH
#   define DYLD_OS_VERSION(x, i, t, w, b) DYLD_WATCHOS_VERSION_##w
    // watchOS has its own API for compatibility reasons
#   define sdkVersion() dyld_get_program_sdk_watch_os_version()

#else
#   error unknown OS
#endif


#define sdkIsOlderThan(x, i, t, w, b)                           \
            (sdkVersion() < DYLD_OS_VERSION(x, i, t, w, b))
#define sdkIsAtLeast(x, i, t, w, b)                             \
            (sdkVersion() >= DYLD_OS_VERSION(x, i, t, w, b))

// Allow bare 0 to be used in DYLD_OS_VERSION() and sdkIsOlderThan()
#define DYLD_MACOSX_VERSION_0 0
#define DYLD_IOS_VERSION_0 0
#define DYLD_TVOS_VERSION_0 0
#define DYLD_WATCHOS_VERSION_0 0
#define DYLD_BRIDGEOS_VERSION_0 0

// Pretty-print a DYLD_*_VERSION_* constant.
#define SDK_FORMAT "%hu.%hhu.%hhu"
#define FORMAT_SDK(v) \
    (unsigned short)(((uint32_t)(v))>>16),  \
    (unsigned  char)(((uint32_t)(v))>>8),   \
    (unsigned  char)(((uint32_t)(v))>>0)

// fork() safety requires careful tracking of all locks.
// Our custom lock types check this in debug builds.
// Disallow direct use of all other lock types.
typedef __darwin_pthread_mutex_t pthread_mutex_t UNAVAILABLE_ATTRIBUTE;
typedef __darwin_pthread_rwlock_t pthread_rwlock_t UNAVAILABLE_ATTRIBUTE;
typedef int32_t OSSpinLock UNAVAILABLE_ATTRIBUTE;
typedef struct os_unfair_lock_s os_unfair_lock UNAVAILABLE_ATTRIBUTE;


#endif
