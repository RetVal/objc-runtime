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
* mixins.h
* Thread related utility mixins
**********************************************************************/

#ifndef _OBJC_THREAD_MIXINS_H
#define _OBJC_THREAD_MIXINS_H

// .. locker_mixin .....................................................

// Adds locker, conditional_locker, lockWith(), unlockWith(), lockTwo()
// and unlockTwo() to a class.
template <class T>
class locker_mixin: public T {
public:
    using T::T;

    // Address-ordered lock discipline for a pair of locks.
    void lockWith(T& other) {
        if (this < &other) {
            T::lock();
            other.lock();
        } else {
            other.lock();
            if (this != &other) T::lock();
        }
    }

    void unlockWith(T& other) {
        T::unlock();
        if (this != &other) other.unlock();
    }

    static void lockTwo(locker_mixin *lock1, locker_mixin *lock2) {
        lock1->lockWith(*lock2);
    }

    static void unlockTwo(locker_mixin *lock1, locker_mixin *lock2) {
        lock1->unlockWith(*lock2);
    }

    // Scoped lock and unlock
    class locker : nocopy_t {
        T& lock;
    public:
        locker(T& newLock) : lock(newLock) {
            lock.lock();
        }
        ~locker() { lock.unlock(); }
    };

    // Either scoped lock and unlock, or NOP.
    class conditional_locker : nocopy_t {
        T& lock;
        bool didLock;
    public:
        conditional_locker(T& newLock, bool shouldLock)
            : lock(newLock), didLock(shouldLock)
        {
            if (shouldLock) lock.lock();
        }
        ~conditional_locker() { if (didLock) lock.unlock(); }
    };
};

// .. getter_setter ....................................................

// Adds implementations of the essential operators for arithmetic and
// pointer types

template <class T, class Enable=void>
class getter_setter {};

// For arithmetic types
template <class T>
class getter_setter<T,
                    typename std::enable_if<std::is_arithmetic<
                                                typename T::type>::value>::type> : T {
public:
    using type = typename T::type;

    ALWAYS_INLINE getter_setter& operator=(const type &value) {
        T::set_(value);
        return *this;
    }
    ALWAYS_INLINE getter_setter& operator+=(const type &value) {
        T::set_(T::get_() + value);
        return *this;
    }
    ALWAYS_INLINE getter_setter& operator-=(const type &value) {
        T::set_(T::get_() - value);
        return *this;
    }
    ALWAYS_INLINE getter_setter& operator*=(const type &value) {
        T::set_(T::get_() * value);
        return *this;
    }
    ALWAYS_INLINE getter_setter& operator/=(const type &value) {
        T::set_(T::get_() / value);
        return *this;
    }
    ALWAYS_INLINE getter_setter& operator%=(const type &value) {
        T::set_(T::get_() % value);
        return *this;
    }
    ALWAYS_INLINE getter_setter& operator&=(const type &value) {
        T::set_(T::get_() & value);
        return *this;
    }
    ALWAYS_INLINE getter_setter& operator|=(const type &value) {
        T::set_(T::get_() | value);
        return *this;
    }
    ALWAYS_INLINE getter_setter& operator^=(const type &value) {
        T::set_(T::get_() ^ value);
        return *this;
    }
    ALWAYS_INLINE getter_setter& operator<<=(const type &value) {
        T::set_(T::get_() << value);
        return *this;
    }
    ALWAYS_INLINE getter_setter& operator>>=(const type &value) {
        T::set_(T::get_() >> value);
        return *this;
    }

    ALWAYS_INLINE type operator++() {
        type result = T::get_() + 1;
        T::set_(result);
        return result;
    }
    ALWAYS_INLINE type operator++(int) {
        type result = T::get_();
        T::set_(result + 1);
        return result;
    }

    ALWAYS_INLINE type operator--() {
        type result = T::get_() - 1;
        T::set_(result);
        return result;
    }
    ALWAYS_INLINE type operator--(int) {
        type result = T::get_();
        T::set_(result - 1);
        return result;
    }

    ALWAYS_INLINE operator type() const {
        return T::get_();
    }
};

// For non-void pointer types
template <class T>
class getter_setter<T,
                    typename std::enable_if<std::is_pointer<
                                                typename T::type>::value
                                            && !std::is_void<
                                                typename std::remove_pointer<typename T::type>::type>
                                            ::value>::type> : T {
public:
    using type = typename T::type;
    using points_to_type = typename std::remove_pointer<typename T::type>::type;

    ALWAYS_INLINE getter_setter& operator=(const type &value) {
        T::set_(value);
        return *this;
    }
    ALWAYS_INLINE getter_setter& operator+=(std::ptrdiff_t value) {
        T::set_(T::get_() + value);
        return *this;
    }
    ALWAYS_INLINE getter_setter& operator-=(std::ptrdiff_t value) {
        T::set_(T::get_() - value);
        return *this;
    }

    ALWAYS_INLINE type operator++() {
        type result = T::get_() + 1;
        T::set_(result);
        return result;
    }
    ALWAYS_INLINE type operator++(int) {
        type result = T::get_();
        T::set_(result + 1);
        return result;
    }

    ALWAYS_INLINE type operator--() {
        type result = T::get_() - 1;
        T::set_(result);
        return result;
    }
    ALWAYS_INLINE type operator--(int) {
        type result = T::get_();
        T::set_(result - 1);
        return result;
    }

    ALWAYS_INLINE operator type() const {
        return T::get_();
    }

    ALWAYS_INLINE points_to_type& operator[](std::size_t ndx) {
        return T::get_()[ndx];
    }
    ALWAYS_INLINE points_to_type& operator*() {
        return *T::get_();
    }
    ALWAYS_INLINE points_to_type* operator->() {
        return T::get_();
    }
};

// For void *
template <class T>
class getter_setter<T,
                    typename std::enable_if<std::is_pointer<
                                                typename T::type>::value
                                            && std::is_void<
                                                typename std::remove_pointer<typename T::type>::type>
                                            ::value>::type> : T {
public:
    using type = typename T::type;
    using points_to_type = typename std::remove_pointer<typename T::type>::type;

    ALWAYS_INLINE getter_setter& operator=(const type &value) {
        T::set_(value);
        return *this;
    }

    ALWAYS_INLINE operator type() const {
        return T::get_();
    }
};

#endif // _OBJC_THREAD_MIXINS_H
