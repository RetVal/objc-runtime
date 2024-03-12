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
* darwin.h
* Darwin thread support package
**********************************************************************/

#ifndef _OBJC_DARWINTHREADS_H
#define _OBJC_DARWINTHREADS_H

#include <os/lock.h>

// Much of the implementation is inherited from the pthreads one
#define _OBJC_PTHREAD_IS_DARWIN    1
#include "pthreads.h"

static inline bool objc_is_threaded() {
    return pthread_is_threaded_np();
}

// .. Direct thread keys ...............................................

#define SUPPORT_DIRECT_THREAD_KEYS 1

ALWAYS_INLINE pthread_key_t tls_get_key(tls_key k) {
    switch (k) {
    case tls_key::main:
        return __PTK_FRAMEWORK_OBJC_KEY0;
    case tls_key::sync_data:
        return __PTK_FRAMEWORK_OBJC_KEY1;
    case tls_key::sync_count:
        return __PTK_FRAMEWORK_OBJC_KEY2;
    case tls_key::autorelease_pool:
        return __PTK_FRAMEWORK_OBJC_KEY3;
#if SUPPORT_RETURN_AUTORELEASE
    case tls_key::return_autorelease_object:
        return __PTK_FRAMEWORK_OBJC_KEY4;
    case tls_key::return_autorelease_address:
        return __PTK_FRAMEWORK_OBJC_KEY5;
#endif
    }
}

__attribute__((const))
static inline objc_thread_t objc_thread_self()
{
    return (pthread_t)_pthread_getspecific_direct(_PTHREAD_TSD_SLOT_PTHREAD_SELF);
}

// .. objc_tls_direct ..................................................

template <class T, tls_key Key, typename Destructor>
class objc_tls_direct_base {
public:
  using type = T;

  static_assert(sizeof(T) <= sizeof(void *), "T must fit in a void *");

  static void dtor_(void *ptr) {
    Destructor d;
    d((T)(uintptr_t)ptr);
  }
protected:
  objc_tls_direct_base() { pthread_key_init_np(tls_get_key(Key), dtor_); }

  ALWAYS_INLINE T get_() const {
      if (_pthread_has_direct_tsd())
          return (T)(uintptr_t)_pthread_getspecific_direct(tls_get_key(Key));
      else
          return (T)(uintptr_t)pthread_getspecific(tls_get_key(Key));
  }
  ALWAYS_INLINE void set_(T newval) {
      if (_pthread_has_direct_tsd()) {
          _pthread_setspecific_direct(tls_get_key(Key),
                                      (void *)(uintptr_t)newval);
      } else {
          pthread_setspecific(tls_get_key(Key), (void *)(uintptr_t)newval);
      }
  }
};

template <class T, tls_key Key>
class objc_tls_direct_base<T, Key, void> {
public:
  using type = T;

  static_assert(sizeof(T) <= sizeof(void *), "T must fit in a void *");
  static_assert(std::is_trivially_destructible<T>::value,
                "T must be trivially destructible");

protected:
  ALWAYS_INLINE T get_() const {
      if (_pthread_has_direct_tsd())
          return (T)(uintptr_t)_pthread_getspecific_direct(tls_get_key(Key));
      else
          return (T)(uintptr_t)pthread_getspecific(tls_get_key(Key));
  }
  ALWAYS_INLINE void set_(T newval) {
      if (_pthread_has_direct_tsd()) {
          _pthread_setspecific_direct(tls_get_key(Key),
                                      (void *)(uintptr_t)newval);
      } else {
          pthread_setspecific(tls_get_key(Key), (void *)(uintptr_t)newval);
      }
  }
};

// .. tls_autoptr_direct ...............................................

template <class T, tls_key Key>
class tls_autoptr_direct_impl {
private:
    static void dtor_(void *ptr) {
        delete (T *)ptr;
    }

    ALWAYS_INLINE T *get_(bool create) const {
        if (_pthread_has_direct_tsd()) {
            T *ptr = (T *)_pthread_getspecific_direct(tls_get_key(Key));
            if (create && !ptr) {
                ptr = new T();
                _pthread_setspecific_direct(tls_get_key(Key), ptr);
            }
            return ptr;
        } else {
            T *ptr = (T *)pthread_getspecific(tls_get_key(Key));
            if (create && !ptr) {
                ptr = new T();
                pthread_setspecific(tls_get_key(Key), ptr);
            }
            return ptr;
        }
    }
    ALWAYS_INLINE void set_(T* newptr) {
        if (_pthread_has_direct_tsd()) {
            T *ptr = (T *)_pthread_getspecific_direct(tls_get_key(Key));
            if (ptr)
                delete ptr;
            _pthread_setspecific_direct(tls_get_key(Key), newptr);
        } else {
            T *ptr = (T *)pthread_getspecific(tls_get_key(Key));
            if (ptr)
                delete ptr;
            pthread_setspecific(tls_get_key(Key), newptr);
        }
    }

public:
    tls_autoptr_direct_impl() { pthread_key_init_np(tls_get_key(Key), dtor_); }

    ALWAYS_INLINE tls_autoptr_direct_impl& operator=(T *newptr) {
        set_(newptr);
        return *this;
    }

    ALWAYS_INLINE T *get(bool create) const { return get_(create); }

    ALWAYS_INLINE operator T*() const {
        return get_(true);
    }

    ALWAYS_INLINE T& operator*() {
        return *get_(true);
    }

    ALWAYS_INLINE T* operator->() {
        return get_(true);
    }
};

// .. objc_lock_t ......................................................

class objc_lock_base_t : nocopy_t {
    os_unfair_lock lock_;
public:
    objc_lock_base_t() : lock_(OS_UNFAIR_LOCK_INIT) {}

    ALWAYS_INLINE void lock() {
        // <rdar://problem/50384154>
        uint32_t opts = (OS_UNFAIR_LOCK_DATA_SYNCHRONIZATION
                         | OS_UNFAIR_LOCK_ADAPTIVE_SPIN);
        os_unfair_lock_lock_with_options_inline
            (&lock_, (os_unfair_lock_options_t)opts);
    }

    ALWAYS_INLINE bool tryLock() {
        return os_unfair_lock_trylock(&lock_);
    }

    ALWAYS_INLINE void unlock() {
        os_unfair_lock_unlock_inline(&lock_);
    }

    ALWAYS_INLINE bool tryUnlock() {
        os_unfair_lock_unlock_inline(&lock_);
        return true;
    }

    ALWAYS_INLINE void reset() {
        memset(&lock_, 0, sizeof(lock_));
        lock_ = os_unfair_lock OS_UNFAIR_LOCK_INIT;
    }
};

// .. objc_recursive_lock_t ............................................

class objc_recursive_lock_base_t : nocopy_t {
    os_unfair_recursive_lock lock_;
public:
    objc_recursive_lock_base_t() : lock_(OS_UNFAIR_RECURSIVE_LOCK_INIT) {}

    ALWAYS_INLINE void lock() {
        os_unfair_recursive_lock_lock(&lock_);
    }

    ALWAYS_INLINE bool tryLock() {
        return os_unfair_recursive_lock_trylock(&lock_);
    }

    ALWAYS_INLINE void unlock() {
        os_unfair_recursive_lock_unlock(&lock_);
    }

    ALWAYS_INLINE bool tryUnlock() {
        return os_unfair_recursive_lock_tryunlock4objc(&lock_);
    }

    ALWAYS_INLINE void unlockForkedChild() {
        os_unfair_recursive_lock_unlock_forked_child(&lock_);
    }

    ALWAYS_INLINE void reset() {
        memset(&lock_, 0, sizeof(lock_));
        lock_ = os_unfair_recursive_lock OS_UNFAIR_RECURSIVE_LOCK_INIT;
    }

    // Same as reset, but avoids any troublesome lockdebug overrides.
    ALWAYS_INLINE void hardReset() {
        reset();
    }
};

#endif // _OBJC_DARWINTHREADS_H
