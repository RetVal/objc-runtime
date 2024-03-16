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

#include <atomic>
#include <utility>
#include <TargetConditionals.h>
#include "objc-config.h"
#include "objc-private.h"
#include "objc-vm.h"

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
static inline size_t align16(size_t x) {
    return (x + size_t(15)) & ~size_t(15);
}

// Mix-in for classes that must not be copied.
class nocopy_t {
  private:
    nocopy_t(const nocopy_t&) = delete;
    const nocopy_t& operator=(const nocopy_t&) = delete;
  protected:
    constexpr nocopy_t() = default;
    ~nocopy_t() = default;
};

// Version of std::atomic that does not allow implicit conversions
// to/from the wrapped type, and requires an explicit memory order
// be passed to load() and store().
template <typename T>
struct explicit_atomic : public std::atomic<T> {
    explicit explicit_atomic(T initial) noexcept : std::atomic<T>(std::move(initial)) {}
    operator T() const = delete;
    
    T load(std::memory_order order) const noexcept {
        return std::atomic<T>::load(order);
    }
    void store(T desired, std::memory_order order) noexcept {
        std::atomic<T>::store(desired, order);
    }
    
    // Convert a normal pointer to an atomic pointer. This is a
    // somewhat dodgy thing to do, but if the atomic type is lock
    // free and the same size as the non-atomic type, we know the
    // representations are the same, and the compiler generates good
    // code.
    static explicit_atomic<T> *from_pointer(T *ptr) {
        static_assert(sizeof(explicit_atomic<T> *) == sizeof(T *),
                      "Size of atomic must match size of original");
        explicit_atomic<T> *atomic = (explicit_atomic<T> *)ptr;
        ASSERT(atomic->is_lock_free());
        return atomic;
    }
};

namespace objc {
static inline uintptr_t mask16ShiftBits(uint16_t mask)
{
    // returns by how much 0xffff must be shifted "right" to return mask
    uintptr_t maskShift = __builtin_clz(mask) - 16;
    ASSERT((0xffff >> maskShift) == mask);
    return maskShift;
}
}

#if TARGET_OS_MAC

#   define OS_UNFAIR_LOCK_INLINE 1

#   ifndef __STDC_LIMIT_MACROS
#       define __STDC_LIMIT_MACROS
#   endif

#   include <Availability.h>
#   include <TargetConditionals.h>

#   include <stdio.h>
#   include <stdlib.h>
#   include <stdint.h>
#   include <stdarg.h>
#   include <string.h>
#   include <ctype.h>
#   include <errno.h>
#   include <dlfcn.h>
#   include <assert.h>
#   include <limits.h>

#if !TARGET_OS_EXCLAVEKIT
#   include <fcntl.h>
#   include <syslog.h>
#   include <unistd.h>
#   include <pthread.h>
#   include <crt_externs.h>
#   undef check
#   include <sys/mman.h>
#   include <sys/time.h>
#   include <sys/stat.h>
#   include <sys/param.h>
#   include <sys/reason.h>
#   include <mach/mach.h>
#   include <mach/mach_time.h>
#endif // !TARGET_OS_EXCLAVEKIT

#   include <mach-o/dyld.h>
#   include <mach-o/loader.h>
#   include <mach-o/getsect.h>
#   include <mach-o/dyld_priv.h>

#ifndef DYLD_PLATFROM_DEFINITION_MACOS
#define DYLD_PLATFROM_DEFINITION_MACOS(ver) \
const dyld_build_version_t dyld_platform_version_macOS_ ## ver = {\
    .platform = PLATFORM_MACOS,\
    .version = DYLD_MACOSX_VERSION_ ## ver\
}
#endif

DYLD_PLATFROM_DEFINITION_MACOS(10_13);
DYLD_PLATFROM_DEFINITION_MACOS(10_14);

#if __has_include(<malloc/malloc.h>)
#   include <malloc/malloc.h>
#endif

#if !TARGET_OS_EXCLAVEKIT
#   include <mach-o/ldsyms.h>
#   include <os/lock_private.h>
#   include <libkern/OSCacheControl.h>
#   include <System/pthread_machdep.h>
#endif // !TARGET_OS_EXCLAVEKIT

#   include "objc-probes.h"  // generated dtrace probe definitions.

// Some libc functions call objc_msgSend() 
// so we can't use them without deadlocks.
void syslog(int, const char *, ...) UNAVAILABLE_ATTRIBUTE;
void vsyslog(int, const char *, va_list) UNAVAILABLE_ATTRIBUTE;


#define ALWAYS_INLINE inline __attribute__((always_inline))
#define NEVER_INLINE __attribute__((noinline))

#define fastpath(x) (__builtin_expect(bool(x), 1))
#define slowpath(x) (__builtin_expect(bool(x), 0))


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

#if __arm64__ && !__arm64e__

static ALWAYS_INLINE
uintptr_t
LoadExclusive(uintptr_t *src)
{
    return __builtin_arm_ldrex(src);
}

static ALWAYS_INLINE
bool
StoreExclusive(uintptr_t *dst, uintptr_t *oldvalue, uintptr_t value)
{
    if (slowpath(__builtin_arm_strex(value, dst))) {
        *oldvalue = LoadExclusive(dst);
        return false;
    }
    return true;
}


static ALWAYS_INLINE
bool
StoreReleaseExclusive(uintptr_t *dst, uintptr_t *oldvalue, uintptr_t value)
{
    if (slowpath(__builtin_arm_stlex(value, dst))) {
        *oldvalue = LoadExclusive(dst);
        return false;
    }
    return true;
}

static ALWAYS_INLINE
void
ClearExclusive(uintptr_t *dst __unused)
{
    __builtin_arm_clrex();
}

#else

static ALWAYS_INLINE
uintptr_t
LoadExclusive(uintptr_t *src)
{
    return __c11_atomic_load((_Atomic(uintptr_t) *)src, __ATOMIC_RELAXED);
}

static ALWAYS_INLINE
bool
StoreExclusive(uintptr_t *dst, uintptr_t *oldvalue, uintptr_t value)
{
    return __c11_atomic_compare_exchange_weak((_Atomic(uintptr_t) *)dst, oldvalue, value, __ATOMIC_RELAXED, __ATOMIC_RELAXED);
}


static ALWAYS_INLINE
bool
StoreReleaseExclusive(uintptr_t *dst, uintptr_t *oldvalue, uintptr_t value)
{
    return __c11_atomic_compare_exchange_weak((_Atomic(uintptr_t) *)dst, oldvalue, value, __ATOMIC_RELEASE, __ATOMIC_RELAXED);
}

static ALWAYS_INLINE
void
ClearExclusive(uintptr_t *dst __unused)
{
}

#endif

template <typename T>
bool CompareAndSwap(T oldval, T newval, volatile T *theval)
{
    return std::atomic_compare_exchange_strong_explicit(
        reinterpret_cast<std::atomic<T>*>(const_cast<T*>(theval)),
        &oldval, newval,
        std::memory_order_seq_cst,
        std::memory_order_relaxed);
}

template <typename T>
bool CompareAndSwapNoBarrier(T oldval, T newval, volatile T *theval)
{
    return std::atomic_compare_exchange_strong_explicit(
        reinterpret_cast<std::atomic<T>*>(const_cast<T*>(theval)),
        &oldval, newval,
        std::memory_order_relaxed,
        std::memory_order_relaxed);
}

// N.B. unlike OSAtomicIncrement, this returns the *old* value
template <typename T>
T AtomicIncrement(volatile T *value)
{
    return std::atomic_fetch_add_explicit(
        reinterpret_cast<std::atomic<T>*>(const_cast<T*>(value)),
        1,
        std::memory_order_seq_cst);
}

// N.B. unlike OSAtomicDecrement, this returns the *old* value
template <typename T>
T AtomicDecrement(volatile T *value)
{
    return std::atomic_fetch_sub_explicit(
        reinterpret_cast<std::atomic<T>*>(const_cast<T*>(value)),
        1,
        std::memory_order_seq_cst);
}

#if !TARGET_OS_IPHONE
#   if !TARGET_OS_EXCLAVEKIT
#       include <CrashReporterClient.h>
#   endif
#else
    // CrashReporterClient not yet available on iOS
    __BEGIN_DECLS
    extern const char *CRSetCrashLogMessage(const char *msg);
    extern const char *CRGetCrashLogMessage(void);
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

#else
#   error unknown OS
#endif


#include <objc/objc.h>
#include <objc/objc-api.h>

extern void _objc_fatal(const char *fmt, ...) 
    __attribute__((noreturn, cold, format (printf, 1, 2)));
extern void _objc_fatal_with_reason(uint64_t reason, uint64_t flags, 
                                    const char *fmt, ...) 
    __attribute__((noreturn, cold, format (printf, 3, 4)));

#define INIT_ONCE_PTR(var, create, delete)                              \
    do {                                                                \
        if (var) break;                                                 \
        typeof(var) v = create;                                         \
        while (!var) {                                                  \
            if (CompareAndSwap<void *>(nullptr, (void *)v,              \
                                       (void * volatile *)&var)){       \
                goto done;                                              \
            }                                                           \
        }                                                               \
        delete;                                                         \
    done:;                                                              \
    } while (0)

#define INIT_ONCE_32(var, create, delete)                               \
    do {                                                                \
        if (var) break;                                                 \
        typeof(var) v = create;                                         \
        while (!var) {                                                  \
            if (CompareAndSwap<int32_t>(0, v,                           \
                                        (volatile int32_t *)&var)) {    \
                goto done;                                              \
            }                                                           \
        }                                                               \
        delete;                                                         \
    done:;                                                              \
    } while (0)


#if   TARGET_OS_MAC


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
#if HAVE_CLOCK_GETTIME_NSEC_NP
    return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return uint64_t(1000000000) * ts.tv_sec + ts.tv_nsec;
#endif
}

// Threading
#include "Threading/threading.h"

// Old names for locks
using spinlock_t = objc_lock_t;
using mutex_t = objc_lock_t;
using recursive_mutex_t = objc_recursive_lock_t;

using mutex_locker_t = mutex_t::locker;
using conditional_mutex_locker_t = mutex_t::conditional_locker;

// Mach-O things
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

template<typename T>
static T* getSectionData(const headerType* mhdr,
                         _dyld_section_location_info_t info,
                         _dyld_section_location_kind kind,
                         size_t *outCount)
{
    _dyld_section_info_result result = _dyld_lookup_section_info((const struct mach_header *)mhdr, info, kind);
    if ( result.buffer != NULL ) {
        *outCount = result.bufferSize / sizeof(T);
        return (T*)result.buffer;
    }

    *outCount = 0;
    return NULL;
}

// Prototypes

#if SUPPORT_MESSAGE_LOGGING
/* Secure /tmp usage */
extern int secure_open(const char *filename, int flags, uid_t euid);
#endif

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
// sdkIsAtLeast(mac, ios, tv, watch, bridge)
//
// This version order matches OBJC_AVAILABLE.
//
// NOTE: prefer dyld_program_sdk_at_least when possible
#define sdkIsAtLeast(x, i, t, w, b)                                    \
    (dyld_program_sdk_at_least(dyld_platform_version_macOS_ ## x)   || \
     dyld_program_sdk_at_least(dyld_platform_version_iOS_ ## i)     || \
     dyld_program_sdk_at_least(dyld_platform_version_tvOS_ ## t)    || \
     dyld_program_sdk_at_least(dyld_platform_version_watchOS_ ## w) || \
     dyld_program_sdk_at_least(dyld_platform_version_bridgeOS_ ## b))


// If we don't have asprintf(), use our own implementation instead
#if !HAVE_ASPRINTF
int _objc_vasprintf(char **strp, const char *fmt, va_list args);
int _objc_asprintf(char **strp, const char *fmt, ...);
#else
#define _objc_vasprintf  vasprintf
#define _objc_asprintf   asprintf
#endif // HAVE_ASPRINTF


#if !TARGET_OS_EXCLAVEKIT
#ifndef __BUILDING_OBJCDT__
// fork() safety requires careful tracking of all locks.
// Our custom lock types check this in debug builds.
// Disallow direct use of all other lock types.
typedef __darwin_pthread_mutex_t pthread_mutex_t UNAVAILABLE_ATTRIBUTE;
typedef __darwin_pthread_rwlock_t pthread_rwlock_t UNAVAILABLE_ATTRIBUTE;
typedef struct os_unfair_lock_s os_unfair_lock UNAVAILABLE_ATTRIBUTE;
#endif
#endif // !TARGET_OS_EXCLAVEKIT

#endif
