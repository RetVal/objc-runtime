/*
 * Copyright (c) 2022 Apple Inc.  All Rights Reserved.
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
* lockdebug.h
* Lock debugging
**********************************************************************/

#ifndef _OBJC_LOCKDEBUG_H
#define _OBJC_LOCKDEBUG_H

// Define LOCKDEBUG if it isn't already set
#ifndef LOCKDEBUG
#   if DEBUG
#       define LOCKDEBUG 1
#   else
#       define LOCKDEBUG 0
#   endif
#endif

namespace lockdebug {

    // Internal functions
#if LOCKDEBUG
    namespace notify {
        void remember(objc_lock_base_t *lock);
        void lock(objc_lock_base_t *lock);
        void unlock(objc_lock_base_t *lock);

        void remember(objc_recursive_lock_base_t *lock);
        void lock(objc_recursive_lock_base_t *lock);
        void unlock(objc_recursive_lock_base_t *lock);
    }
#endif

    // Use fork_unsafe to get a lock that isn't acquired and released around
    // fork().
    struct fork_unsafe_t {
        constexpr fork_unsafe_t() = default;
    };

    template <class T>
    class lock_mixin: public T {
    public:
#if LOCKDEBUG
        lock_mixin() : T() {
            lockdebug::notify::remember((T *)this);
        }

        lock_mixin(const fork_unsafe_t) : T() {}

        void lock() {
            lockdebug::notify::lock((T *)this);
            T::lock();
        }

        bool tryLock() {
            bool success = T::tryLock();
            if (success)
                lockdebug::notify::lock((T *)this);
            return success;
        }

        void unlock() {
            lockdebug::notify::unlock((T *)this);
            T::unlock();
        }

        bool tryUnlock() {
            bool success = T::tryUnlock();
            if (success)
                lockdebug::notify::unlock((T *)this);
            return success;
        }

        void unlockForkedChild() {
            lockdebug::notify::unlock((T *)this);
            T::unlockForkedChild();
        }

        void reset() {
            lockdebug::notify::unlock((T *)this);
            T::reset();
        }
#else
        lock_mixin() : T() {}
        lock_mixin(const fork_unsafe_t) : T() {}
#endif
    };

    // APIs
#if LOCKDEBUG
    void assert_locked(objc_lock_base_t *lock);
    void assert_unlocked(objc_lock_base_t *lock);

    void assert_locked(objc_recursive_lock_base_t *lock);
    void assert_unlocked(objc_recursive_lock_base_t *lock);

    void assert_all_locks_locked();
    void assert_no_locks_locked();
    void assert_no_locks_locked_except(std::initializer_list<void *> canBeLocked);

    void set_in_fork_prepare(bool in_prepare);
    void lock_precedes_lock(const void *old_lock, const void *new_lock);
#else
    static inline void assert_locked(objc_lock_base_t *) {}
    static inline void assert_unlocked(objc_lock_base_t *) {}

    static inline void assert_locked(objc_recursive_lock_base_t *) {}
    static inline void assert_unlocked(objc_recursive_lock_base_t *) {}

    static inline void assert_all_locks_locked() {}
    static inline void assert_no_locks_locked() {}
    static inline void assert_no_locks_locked_except(std::initializer_list<void *>) {}

    static inline void set_in_fork_prepare(bool) {}
    static inline void lock_precedes_lock(const void *, const void *) {}
#endif
}

extern const lockdebug::fork_unsafe_t fork_unsafe;

#endif // _OBJC_LOCKDEBUG_H
