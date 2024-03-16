/*
 * Copyright (c) 2019 Apple Inc.  All Rights Reserved.
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

#ifndef POINTERUNION_H
#define POINTERUNION_H

#include <cstdint>
#include <atomic>

namespace objc {

template <typename T> struct PointerUnionTypeSelectorReturn {
  using Return = T;
};

/// Get a type based on whether two types are the same or not.
///
/// For:
///
/// \code
///   using Ret = typename PointerUnionTypeSelector<T1, T2, EQ, NE>::Return;
/// \endcode
///
/// Ret will be EQ type if T1 is same as T2 or NE type otherwise.
template <typename T1, typename T2, typename RET_EQ, typename RET_NE>
struct PointerUnionTypeSelector {
  using Return = typename PointerUnionTypeSelectorReturn<RET_NE>::Return;
};

template <typename T, typename RET_EQ, typename RET_NE>
struct PointerUnionTypeSelector<T, T, RET_EQ, RET_NE> {
  using Return = typename PointerUnionTypeSelectorReturn<RET_EQ>::Return;
};

template <typename T1, typename T2, typename RET_EQ, typename RET_NE>
struct PointerUnionTypeSelectorReturn<
    PointerUnionTypeSelector<T1, T2, RET_EQ, RET_NE>> {
  using Return =
      typename PointerUnionTypeSelector<T1, T2, RET_EQ, RET_NE>::Return;
};

/// A pointer-sized value containing a pointer to one of two different types.
/// The types are discriminated using the low bit of the value; the types must
/// therefore be at least two-byte aligned.
///
/// This type is used to represent pointers in loaded images so should be
/// considered ABI. It's guaranteed that T1 is stored as a raw pointer, and T2
/// is stored with the low bit set to 1.
template <class T1, class T2, typename Auth1, typename Auth2>
class PointerUnion {
    uintptr_t _value;

    static_assert(alignof(T1) >= 2, "alignment requirement");
    static_assert(alignof(T2) >= 2, "alignment requirement");

    struct IsPT1 {
      static const uintptr_t Num = 0;
    };
    struct IsPT2 {
      static const uintptr_t Num = 1;
    };
    template <typename T> struct UNION_DOESNT_CONTAIN_TYPE {};

    uintptr_t getTag() const {
        return _value & 1;
    }

public:
    explicit PointerUnion(const std::atomic<uintptr_t> &raw)
    : _value(raw.load(std::memory_order_relaxed))
    { }
    PointerUnion(T1 *t, const void *address) {
        _value = (uintptr_t)Auth1::sign(t, address);
    }
    PointerUnion(T2 *t, const void *address) {
        _value = (uintptr_t)Auth2::sign((void *)((uintptr_t)t | 1), address);
    }

    PointerUnion(const PointerUnion &other) {
        *this = other;
    }

    PointerUnion &operator=(const PointerUnion &other) {
        if (T1 *t1 = other.dyn_cast<T1 *>())
            set(t1);
        else if (T2 *t2 = other.dyn_cast<T2 *>())
            set(t2);
        return *this;
    }

    void set(T1 *t) {
        _value = (uintptr_t)Auth1::sign(t, this);
    }

    void set(T2 *t) {
        _value = (uintptr_t)Auth2::sign((void *)((uintptr_t)t | 1), this);
    }

    void storeAt(std::atomic<uintptr_t> &raw, std::memory_order order) const {
        raw.store(_value, order);
    }

    bool isNull() const {
        return _value == 0;
    }

    template <typename T>
    bool is() const {
        using Ty = typename PointerUnionTypeSelector<T1 *, T, IsPT1,
            PointerUnionTypeSelector<T2 *, T, IsPT2,
            UNION_DOESNT_CONTAIN_TYPE<T>>>::Return;
        return getTag() == Ty::Num;
    }

    template <typename T> T get(const void *address) const {
        ASSERT(is<T>() && "Invalid accessor called");
        using AuthT = typename PointerUnionTypeSelector<T1 *, T, Auth1,
            PointerUnionTypeSelector<T2 *, T, Auth2,
            UNION_DOESNT_CONTAIN_TYPE<T>>>::Return;

        uintptr_t authed = (uintptr_t)AuthT::auth((void *)_value, address);
        return (T)(authed & ~1);
    }

    template <typename T> T get() const {
        return get<T>(this);
    }

    template <typename T> T dyn_cast(const void *address) const {
      if (is<T>())
        return get<T>(address);
      return T();
    }

    template <typename T> T dyn_cast() const {
        return dyn_cast<T>(this);
    }

    operator bool() const {
        if (T1 *t1 = dyn_cast<T1 *>())
            return true;
        else if (T2 *t2 = dyn_cast<T2 *>())
            return true;
        return false;
    }
};

// A pointer union of four types, using the low two bits to discriminate. This
// is not currently ABI anywhere.
template <class PT1, class PT2, class PT3, class PT4, typename ValueTy = uintptr_t>
class PointerUnion4 {
    ValueTy _value;

    static_assert(alignof(PT1) >= 4, "alignment requirement");
    static_assert(alignof(PT2) >= 4, "alignment requirement");
    static_assert(alignof(PT3) >= 4, "alignment requirement");
    static_assert(alignof(PT4) >= 4, "alignment requirement");

    struct IsPT1 {
      static const uintptr_t Num = 0;
    };
    struct IsPT2 {
      static const uintptr_t Num = 1;
    };
    struct IsPT3 {
      static const uintptr_t Num = 2;
    };
    struct IsPT4 {
      static const uintptr_t Num = 3;
    };
    template <typename T> struct UNION_DOESNT_CONTAIN_TYPE {};

    uintptr_t getPointer() const {
        return _value & ~3;
    }
    uintptr_t getTag() const {
        return _value & 3;
    }

public:
    void set(PT1 t) { _value = (uintptr_t)t; }
    void set(PT2 t) { _value = (uintptr_t)t | 1; }
    void set(PT3 t) { _value = (uintptr_t)t | 2; }
    void set(PT4 t) { _value = (uintptr_t)t | 3; }

    template<typename T>
    PointerUnion4(T t) { set(t); }

    bool isNull() const {
        return getPointer() == 0;
    }

    template <typename T>
    bool is() const {
        using Ty = typename PointerUnionTypeSelector<PT1, T, IsPT1,
            PointerUnionTypeSelector<PT2, T, IsPT2,
            PointerUnionTypeSelector<PT3, T, IsPT3,
            PointerUnionTypeSelector<PT4, T, IsPT4,
        	UNION_DOESNT_CONTAIN_TYPE<T>>>>>::Return;
        return getTag() == Ty::Num;
    }

    template <typename T> T get() const {
      ASSERT(is<T>() && "Invalid accessor called");
      return reinterpret_cast<T>(getPointer());
    }

    template <typename T> T dyn_cast() const {
      if (is<T>())
        return get<T>();
      return T();
    }
};

} // namespace objc

#endif /* DENSEMAPEXTRAS_H */
