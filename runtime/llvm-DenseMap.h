//===- llvm/ADT/DenseMap.h - Dense probed hash table ------------*- C++ -*-===//
//
//                     The LLVM Compiler Infrastructure
//
// This file is distributed under the University of Illinois Open Source
// License. See LICENSE.TXT for details.
//
//===----------------------------------------------------------------------===//
//
// This file defines the DenseMap class.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_ADT_DENSEMAP_H
#define LLVM_ADT_DENSEMAP_H

#include "llvm-type_traits.h"
#include <algorithm>
#include <iterator>
#include <new>
#include <utility>
#include <cassert>
#include <cstddef>
#include <cstring>
#include <TargetConditionals.h>

namespace objc {

#if TARGET_OS_IPHONE

// lifted from <MathExtras.h>:

/// CountLeadingZeros_32 - this function performs the platform optimal form of
/// counting the number of zeros from the most significant bit to the first one
/// bit.  Ex. CountLeadingZeros_32(0x00F000FF) == 8.
/// Returns 32 if the word is zero.
inline unsigned CountLeadingZeros_32(uint32_t Value) {
  unsigned Count; // result
#if __GNUC__ >= 4
  // PowerPC is defined for __builtin_clz(0)
#if !defined(__ppc__) && !defined(__ppc64__)
  if (!Value) return 32;
#endif
  Count = __builtin_clz(Value);
#else
  if (!Value) return 32;
  Count = 0;
  // bisection method for count leading zeros
  for (unsigned Shift = 32 >> 1; Shift; Shift >>= 1) {
    uint32_t Tmp = Value >> Shift;
    if (Tmp) {
      Value = Tmp;
    } else {
      Count |= Shift;
    }
  }
#endif
  return Count;
}
/// CountLeadingOnes_32 - this function performs the operation of
/// counting the number of ones from the most significant bit to the first zero
/// bit.  Ex. CountLeadingOnes_32(0xFF0FFF00) == 8.
/// Returns 32 if the word is all ones.
inline unsigned CountLeadingOnes_32(uint32_t Value) {
  return CountLeadingZeros_32(~Value);
}
/// CountLeadingZeros_64 - This function performs the platform optimal form
/// of counting the number of zeros from the most significant bit to the first
/// one bit (64 bit edition.)
/// Returns 64 if the word is zero.
inline unsigned CountLeadingZeros_64(uint64_t Value) {
  unsigned Count; // result
#if __GNUC__ >= 4
  // PowerPC is defined for __builtin_clzll(0)
#if !defined(__ppc__) && !defined(__ppc64__)
  if (!Value) return 64;
#endif
  Count = __builtin_clzll(Value);
#else
  if (sizeof(long) == sizeof(int64_t)) {
    if (!Value) return 64;
    Count = 0;
    // bisection method for count leading zeros
    for (unsigned Shift = 64 >> 1; Shift; Shift >>= 1) {
      uint64_t Tmp = Value >> Shift;
      if (Tmp) {
        Value = Tmp;
      } else {
        Count |= Shift;
      }
    }
  } else {
    // get hi portion
    uint32_t Hi = Hi_32(Value);
    // if some bits in hi portion
    if (Hi) {
        // leading zeros in hi portion plus all bits in lo portion
        Count = CountLeadingZeros_32(Hi);
    } else {
        // get lo portion
        uint32_t Lo = Lo_32(Value);
        // same as 32 bit value
        Count = CountLeadingZeros_32(Lo)+32;
    }
  }
#endif
  return Count;
}
/// CountLeadingOnes_64 - This function performs the operation
/// of counting the number of ones from the most significant bit to the first
/// zero bit (64 bit edition.)
/// Returns 64 if the word is all ones.
inline unsigned CountLeadingOnes_64(uint64_t Value) {
  return CountLeadingZeros_64(~Value);
}
/// CountTrailingZeros_32 - this function performs the platform optimal form of
/// counting the number of zeros from the least significant bit to the first one
/// bit.  Ex. CountTrailingZeros_32(0xFF00FF00) == 8.
/// Returns 32 if the word is zero.
inline unsigned CountTrailingZeros_32(uint32_t Value) {
#if __GNUC__ >= 4
  return Value ? __builtin_ctz(Value) : 32;
#else
  static const unsigned Mod37BitPosition[] = {
    32, 0, 1, 26, 2, 23, 27, 0, 3, 16, 24, 30, 28, 11, 0, 13,
    4, 7, 17, 0, 25, 22, 31, 15, 29, 10, 12, 6, 0, 21, 14, 9,
    5, 20, 8, 19, 18
  };
  return Mod37BitPosition[(-Value & Value) % 37];
#endif
}
/// CountTrailingOnes_32 - this function performs the operation of
/// counting the number of ones from the least significant bit to the first zero
/// bit.  Ex. CountTrailingOnes_32(0x00FF00FF) == 8.
/// Returns 32 if the word is all ones.
inline unsigned CountTrailingOnes_32(uint32_t Value) {
  return CountTrailingZeros_32(~Value);
}
/// CountTrailingZeros_64 - This function performs the platform optimal form
/// of counting the number of zeros from the least significant bit to the first
/// one bit (64 bit edition.)
/// Returns 64 if the word is zero.
inline unsigned CountTrailingZeros_64(uint64_t Value) {
#if __GNUC__ >= 4
  return Value ? __builtin_ctzll(Value) : 64;
#else
  static const unsigned Mod67Position[] = {
    64, 0, 1, 39, 2, 15, 40, 23, 3, 12, 16, 59, 41, 19, 24, 54,
    4, 64, 13, 10, 17, 62, 60, 28, 42, 30, 20, 51, 25, 44, 55,
    47, 5, 32, 65, 38, 14, 22, 11, 58, 18, 53, 63, 9, 61, 27,
    29, 50, 43, 46, 31, 37, 21, 57, 52, 8, 26, 49, 45, 36, 56,
    7, 48, 35, 6, 34, 33, 0
  };
  return Mod67Position[(-Value & Value) % 67];
#endif
}

/// CountTrailingOnes_64 - This function performs the operation
/// of counting the number of ones from the least significant bit to the first
/// zero bit (64 bit edition.)
/// Returns 64 if the word is all ones.
inline unsigned CountTrailingOnes_64(uint64_t Value) {
  return CountTrailingZeros_64(~Value);
}
/// CountPopulation_32 - this function counts the number of set bits in a value.
/// Ex. CountPopulation(0xF000F000) = 8
/// Returns 0 if the word is zero.
inline unsigned CountPopulation_32(uint32_t Value) {
#if __GNUC__ >= 4
  return __builtin_popcount(Value);
#else
  uint32_t v = Value - ((Value >> 1) & 0x55555555);
  v = (v & 0x33333333) + ((v >> 2) & 0x33333333);
  return ((v + (v >> 4) & 0xF0F0F0F) * 0x1010101) >> 24;
#endif
}
/// CountPopulation_64 - this function counts the number of set bits in a value,
/// (64 bit edition.)
inline unsigned CountPopulation_64(uint64_t Value) {
#if __GNUC__ >= 4
  return __builtin_popcountll(Value);
#else
  uint64_t v = Value - ((Value >> 1) & 0x5555555555555555ULL);
  v = (v & 0x3333333333333333ULL) + ((v >> 2) & 0x3333333333333333ULL);
  v = (v + (v >> 4)) & 0x0F0F0F0F0F0F0F0FULL;
  return unsigned((uint64_t)(v * 0x0101010101010101ULL) >> 56);
#endif
}
/// Log2_32 - This function returns the floor log base 2 of the specified value,
/// -1 if the value is zero. (32 bit edition.)
/// Ex. Log2_32(32) == 5, Log2_32(1) == 0, Log2_32(0) == -1, Log2_32(6) == 2
inline unsigned Log2_32(uint32_t Value) {
  return 31 - CountLeadingZeros_32(Value);
}
/// Log2_64 - This function returns the floor log base 2 of the specified value,
/// -1 if the value is zero. (64 bit edition.)
inline unsigned Log2_64(uint64_t Value) {
  return 63 - CountLeadingZeros_64(Value);
}
/// Log2_32_Ceil - This function returns the ceil log base 2 of the specified
/// value, 32 if the value is zero. (32 bit edition).
/// Ex. Log2_32_Ceil(32) == 5, Log2_32_Ceil(1) == 0, Log2_32_Ceil(6) == 3
inline unsigned Log2_32_Ceil(uint32_t Value) {
  return 32-CountLeadingZeros_32(Value-1);
}

#endif /* TARGET_OS_IPHONE */

template<typename T>
struct DenseMapInfo {
  //static inline T getEmptyKey();
  //static inline T getTombstoneKey();
  //static unsigned getHashValue(const T &Val);
  //static bool isEqual(const T &LHS, const T &RHS);
};

// Provide DenseMapInfo for all pointers.
template<typename T>
struct DenseMapInfo<T*> {
  static inline T* getEmptyKey() {
    intptr_t Val = -1;
    return reinterpret_cast<T*>(Val);
  }
  static inline T* getTombstoneKey() {
    intptr_t Val = -2;
    return reinterpret_cast<T*>(Val);
  }
  static unsigned getHashValue(const T *PtrVal) {
    return (unsigned((uintptr_t)PtrVal) >> 4) ^
           (unsigned((uintptr_t)PtrVal) >> 9);
  }
  static bool isEqual(const T *LHS, const T *RHS) { return LHS == RHS; }
};

// Provide DenseMapInfo for chars.
template<> struct DenseMapInfo<char> {
  static inline char getEmptyKey() { return ~0; }
  static inline char getTombstoneKey() { return ~0 - 1; }
  static unsigned getHashValue(const char& Val) { return Val * 37; }
  static bool isEqual(const char &LHS, const char &RHS) {
    return LHS == RHS;
  }
};
  
// Provide DenseMapInfo for unsigned ints.
template<> struct DenseMapInfo<unsigned> {
  static inline unsigned getEmptyKey() { return ~0; }
  static inline unsigned getTombstoneKey() { return ~0U - 1; }
  static unsigned getHashValue(const unsigned& Val) { return Val * 37; }
  static bool isEqual(const unsigned& LHS, const unsigned& RHS) {
    return LHS == RHS;
  }
};

// Provide DenseMapInfo for unsigned longs.
template<> struct DenseMapInfo<unsigned long> {
  static inline unsigned long getEmptyKey() { return ~0UL; }
  static inline unsigned long getTombstoneKey() { return ~0UL - 1L; }
  static unsigned getHashValue(const unsigned long& Val) {
    return (unsigned)(Val * 37UL);
  }
  static bool isEqual(const unsigned long& LHS, const unsigned long& RHS) {
    return LHS == RHS;
  }
};

// Provide DenseMapInfo for unsigned long longs.
template<> struct DenseMapInfo<unsigned long long> {
  static inline unsigned long long getEmptyKey() { return ~0ULL; }
  static inline unsigned long long getTombstoneKey() { return ~0ULL - 1ULL; }
  static unsigned getHashValue(const unsigned long long& Val) {
    return (unsigned)(Val * 37ULL);
  }
  static bool isEqual(const unsigned long long& LHS,
                      const unsigned long long& RHS) {
    return LHS == RHS;
  }
};

// Provide DenseMapInfo for ints.
template<> struct DenseMapInfo<int> {
  static inline int getEmptyKey() { return 0x7fffffff; }
  static inline int getTombstoneKey() { return -0x7fffffff - 1; }
  static unsigned getHashValue(const int& Val) { return (unsigned)(Val * 37); }
  static bool isEqual(const int& LHS, const int& RHS) {
    return LHS == RHS;
  }
};

// Provide DenseMapInfo for longs.
template<> struct DenseMapInfo<long> {
  static inline long getEmptyKey() {
    return (1UL << (sizeof(long) * 8 - 1)) - 1L;
  }
  static inline long getTombstoneKey() { return getEmptyKey() - 1L; }
  static unsigned getHashValue(const long& Val) {
    return (unsigned)(Val * 37L);
  }
  static bool isEqual(const long& LHS, const long& RHS) {
    return LHS == RHS;
  }
};

// Provide DenseMapInfo for long longs.
template<> struct DenseMapInfo<long long> {
  static inline long long getEmptyKey() { return 0x7fffffffffffffffLL; }
  static inline long long getTombstoneKey() { return -0x7fffffffffffffffLL-1; }
  static unsigned getHashValue(const long long& Val) {
    return (unsigned)(Val * 37LL);
  }
  static bool isEqual(const long long& LHS,
                      const long long& RHS) {
    return LHS == RHS;
  }
};

// Provide DenseMapInfo for all pairs whose members have info.
template<typename T, typename U>
struct DenseMapInfo<std::pair<T, U> > {
  typedef std::pair<T, U> Pair;
  typedef DenseMapInfo<T> FirstInfo;
  typedef DenseMapInfo<U> SecondInfo;

  static inline Pair getEmptyKey() {
    return std::make_pair(FirstInfo::getEmptyKey(),
                          SecondInfo::getEmptyKey());
  }
  static inline Pair getTombstoneKey() {
    return std::make_pair(FirstInfo::getTombstoneKey(),
                            SecondInfo::getEmptyKey());
  }
  static unsigned getHashValue(const Pair& PairVal) {
    uint64_t key = (uint64_t)FirstInfo::getHashValue(PairVal.first) << 32
          | (uint64_t)SecondInfo::getHashValue(PairVal.second);
    key += ~(key << 32);
    key ^= (key >> 22);
    key += ~(key << 13);
    key ^= (key >> 8);
    key += (key << 3);
    key ^= (key >> 15);
    key += ~(key << 27);
    key ^= (key >> 31);
    return (unsigned)key;
  }
  static bool isEqual(const Pair& LHS, const Pair& RHS) { return LHS == RHS; }
};

} // end namespace objc



namespace objc {

template<typename KeyT, typename ValueT,
         typename KeyInfoT = DenseMapInfo<KeyT>,
         typename ValueInfoT = DenseMapInfo<ValueT>, bool IsConst = false>
class DenseMapIterator;

// ZeroValuesArePurgeable=true is used by the refcount table.
// A key/value pair with value==0 is not required to be stored 
//   in the refcount table; it could correctly be erased instead.
// For performance, we do keep zero values in the table when the 
//   true refcount decreases to 1: this makes any future retain faster.
// For memory size, we allow rehashes and table insertions to 
//   remove a zero value as if it were a tombstone.

template<typename KeyT, typename ValueT,
         bool ZeroValuesArePurgeable = false, 
         typename KeyInfoT = DenseMapInfo<KeyT>,
         typename ValueInfoT = DenseMapInfo<ValueT> >
class DenseMap {
  typedef std::pair<KeyT, ValueT> BucketT;
  unsigned NumBuckets;
  BucketT *Buckets;

  unsigned NumEntries;
  unsigned NumTombstones;
public:
  typedef KeyT key_type;
  typedef ValueT mapped_type;
  typedef BucketT value_type;

  DenseMap(const DenseMap &other) {
    NumBuckets = 0;
    CopyFrom(other);
  }

  explicit DenseMap(unsigned NumInitBuckets = 64) {
    init(NumInitBuckets);
  }

  template<typename InputIt>
  DenseMap(const InputIt &I, const InputIt &E) {
    init(64);
    insert(I, E);
  }
  
  ~DenseMap() {
    const KeyT EmptyKey = getEmptyKey(), TombstoneKey = getTombstoneKey();
    for (BucketT *P = Buckets, *E = Buckets+NumBuckets; P != E; ++P) {
      if (!KeyInfoT::isEqual(P->first, EmptyKey) &&
          !KeyInfoT::isEqual(P->first, TombstoneKey))
        P->second.~ValueT();
      P->first.~KeyT();
    }
#ifndef NDEBUG
    memset(Buckets, 0x5a, sizeof(BucketT)*NumBuckets);
#endif
    operator delete(Buckets);
  }

  typedef DenseMapIterator<KeyT, ValueT, KeyInfoT> iterator;
  typedef DenseMapIterator<KeyT, ValueT,
                           KeyInfoT, ValueInfoT, true> const_iterator;
  inline iterator begin() {
    // When the map is empty, avoid the overhead of AdvancePastEmptyBuckets().
    return empty() ? end() : iterator(Buckets, Buckets+NumBuckets);
  }
  inline iterator end() {
    return iterator(Buckets+NumBuckets, Buckets+NumBuckets);
  }
  inline const_iterator begin() const {
    return empty() ? end() : const_iterator(Buckets, Buckets+NumBuckets);
  }
  inline const_iterator end() const {
    return const_iterator(Buckets+NumBuckets, Buckets+NumBuckets);
  }

  bool empty() const { return NumEntries == 0; }
  unsigned size() const { return NumEntries; }

  /// Grow the densemap so that it has at least Size buckets. Does not shrink
  void resize(size_t Size) { grow(Size); }

  void clear() {
    if (NumEntries == 0 && NumTombstones == 0) return;
    
    // If the capacity of the array is huge, and the # elements used is small,
    // shrink the array.
    if (NumEntries * 4 < NumBuckets && NumBuckets > 64) {
      shrink_and_clear();
      return;
    }

    const KeyT EmptyKey = getEmptyKey(), TombstoneKey = getTombstoneKey();
    for (BucketT *P = Buckets, *E = Buckets+NumBuckets; P != E; ++P) {
      if (!KeyInfoT::isEqual(P->first, EmptyKey)) {
        if (!KeyInfoT::isEqual(P->first, TombstoneKey)) {
          P->second.~ValueT();
          --NumEntries;
        }
        P->first = EmptyKey;
      }
    }
    assert(NumEntries == 0 && "Node count imbalance!");
    NumTombstones = 0;
  }

  /// count - Return true if the specified key is in the map.
  bool count(const KeyT &Val) const {
    BucketT *TheBucket;
    return LookupBucketFor(Val, TheBucket);
  }

  iterator find(const KeyT &Val) {
    BucketT *TheBucket;
    if (LookupBucketFor(Val, TheBucket))
      return iterator(TheBucket, Buckets+NumBuckets);
    return end();
  }
  const_iterator find(const KeyT &Val) const {
    BucketT *TheBucket;
    if (LookupBucketFor(Val, TheBucket))
      return const_iterator(TheBucket, Buckets+NumBuckets);
    return end();
  }

  /// lookup - Return the entry for the specified key, or a default
  /// constructed value if no such entry exists.
  ValueT lookup(const KeyT &Val) const {
    BucketT *TheBucket;
    if (LookupBucketFor(Val, TheBucket))
      return TheBucket->second;
    return ValueT();
  }

  // Inserts key,value pair into the map if the key isn't already in the map.
  // If the key is already in the map, it returns false and doesn't update the
  // value.
  std::pair<iterator, bool> insert(const std::pair<KeyT, ValueT> &KV) {
    BucketT *TheBucket;
    if (LookupBucketFor(KV.first, TheBucket))
      return std::make_pair(iterator(TheBucket, Buckets+NumBuckets),
                            false); // Already in map.

    // Otherwise, insert the new element.
    TheBucket = InsertIntoBucket(KV.first, KV.second, TheBucket);
    return std::make_pair(iterator(TheBucket, Buckets+NumBuckets),
                          true);
  }

  /// insert - Range insertion of pairs.
  template<typename InputIt>
  void insert(InputIt I, InputIt E) {
    for (; I != E; ++I)
      insert(*I);
  }


  bool erase(const KeyT &Val) {
    BucketT *TheBucket;
    if (!LookupBucketFor(Val, TheBucket))
      return false; // not in map.

    TheBucket->second.~ValueT();
    TheBucket->first = getTombstoneKey();
    --NumEntries;
    ++NumTombstones;
    return true;
  }
  void erase(iterator I) {
    BucketT *TheBucket = &*I;
    TheBucket->second.~ValueT();
    TheBucket->first = getTombstoneKey();
    --NumEntries;
    ++NumTombstones;
  }

  void swap(DenseMap& RHS) {
    std::swap(NumBuckets, RHS.NumBuckets);
    std::swap(Buckets, RHS.Buckets);
    std::swap(NumEntries, RHS.NumEntries);
    std::swap(NumTombstones, RHS.NumTombstones);
  }

  value_type& FindAndConstruct(const KeyT &Key) {
    BucketT *TheBucket;
    if (LookupBucketFor(Key, TheBucket))
      return *TheBucket;

    return *InsertIntoBucket(Key, ValueT(), TheBucket);
  }

  ValueT &operator[](const KeyT &Key) {
    return FindAndConstruct(Key).second;
  }

  DenseMap& operator=(const DenseMap& other) {
    CopyFrom(other);
    return *this;
  }

  /// isPointerIntoBucketsArray - Return true if the specified pointer points
  /// somewhere into the DenseMap's array of buckets (i.e. either to a key or
  /// value in the DenseMap).
  bool isPointerIntoBucketsArray(const void *Ptr) const {
    return Ptr >= Buckets && Ptr < Buckets+NumBuckets;
  }

  /// getPointerIntoBucketsArray() - Return an opaque pointer into the buckets
  /// array.  In conjunction with the previous method, this can be used to
  /// determine whether an insertion caused the DenseMap to reallocate.
  const void *getPointerIntoBucketsArray() const { return Buckets; }

private:
  void CopyFrom(const DenseMap& other) {
    if (NumBuckets != 0 &&
        (!isPodLike<KeyInfoT>::value || !isPodLike<ValueInfoT>::value)) {
      const KeyT EmptyKey = getEmptyKey(), TombstoneKey = getTombstoneKey();
      for (BucketT *P = Buckets, *E = Buckets+NumBuckets; P != E; ++P) {
        if (!KeyInfoT::isEqual(P->first, EmptyKey) &&
            !KeyInfoT::isEqual(P->first, TombstoneKey))
          P->second.~ValueT();
        P->first.~KeyT();
      }
    }

    NumEntries = other.NumEntries;
    NumTombstones = other.NumTombstones;

    if (NumBuckets) {
#ifndef NDEBUG
      memset(Buckets, 0x5a, sizeof(BucketT)*NumBuckets);
#endif
      operator delete(Buckets);
    }
    Buckets = static_cast<BucketT*>(operator new(sizeof(BucketT) *
                                                 other.NumBuckets));

    if (isPodLike<KeyInfoT>::value && isPodLike<ValueInfoT>::value)
      memcpy(Buckets, other.Buckets, other.NumBuckets * sizeof(BucketT));
    else
      for (size_t i = 0; i < other.NumBuckets; ++i) {
        new (&Buckets[i].first) KeyT(other.Buckets[i].first);
        if (!KeyInfoT::isEqual(Buckets[i].first, getEmptyKey()) &&
            !KeyInfoT::isEqual(Buckets[i].first, getTombstoneKey()))
          new (&Buckets[i].second) ValueT(other.Buckets[i].second);
      }
    NumBuckets = other.NumBuckets;
  }

  BucketT *InsertIntoBucket(const KeyT &Key, const ValueT &Value,
                            BucketT *TheBucket) {
    // If the load of the hash table is more than 3/4, grow the table. 
    // If fewer than 1/8 of the buckets are empty (meaning that many are 
    // filled with tombstones), rehash the table without growing.
    //
    // The later case is tricky.  For example, if we had one empty bucket with
    // tons of tombstones, failing lookups (e.g. for insertion) would have to
    // probe almost the entire table until it found the empty bucket.  If the
    // table completely filled with tombstones, no lookup would ever succeed,
    // causing infinite loops in lookup.
    ++NumEntries;
    if (NumEntries*4 >= NumBuckets*3) {
      this->grow(NumBuckets * 2);
      LookupBucketFor(Key, TheBucket);
    }
    else if (NumBuckets-(NumEntries+NumTombstones) < NumBuckets/8) {
      this->grow(NumBuckets);
      LookupBucketFor(Key, TheBucket);
    }

    // If we are writing over a tombstone or zero value, remember this.
    if (!KeyInfoT::isEqual(TheBucket->first, getEmptyKey())) {
      if (KeyInfoT::isEqual(TheBucket->first, getTombstoneKey())) {
        --NumTombstones;
      } else {
        assert(ZeroValuesArePurgeable  &&  TheBucket->second == 0);
        TheBucket->second.~ValueT();
        --NumEntries;
      }
    }

    TheBucket->first = Key;
    new (&TheBucket->second) ValueT(Value);
    return TheBucket;
  }

  static unsigned getHashValue(const KeyT &Val) {
    return KeyInfoT::getHashValue(Val);
  }
  static const KeyT getEmptyKey() {
    return KeyInfoT::getEmptyKey();
  }
  static const KeyT getTombstoneKey() {
    return KeyInfoT::getTombstoneKey();
  }

  /// LookupBucketFor - Lookup the appropriate bucket for Val, returning it in
  /// FoundBucket.  If the bucket contains the key and a value, this returns
  /// true, otherwise it returns a bucket with an empty marker or tombstone 
  /// or zero value and returns false.
  bool LookupBucketFor(const KeyT &Val, BucketT *&FoundBucket) const {
    unsigned BucketNo = getHashValue(Val);
    unsigned ProbeAmt = 1;
    unsigned ProbeCount = 0;
    BucketT *BucketsPtr = Buckets;

    // FoundTombstone - Keep track of whether we find a tombstone or zero value while probing.
    BucketT *FoundTombstone = 0;
    const KeyT EmptyKey = getEmptyKey();
    const KeyT TombstoneKey = getTombstoneKey();
    assert(!KeyInfoT::isEqual(Val, EmptyKey) &&
           !KeyInfoT::isEqual(Val, TombstoneKey) &&
           "Empty/Tombstone value shouldn't be inserted into map!");

    do {
      BucketT *ThisBucket = BucketsPtr + (BucketNo & (NumBuckets-1));
      // Found Val's bucket?  If so, return it.
      if (KeyInfoT::isEqual(ThisBucket->first, Val)) {
        FoundBucket = ThisBucket;
        return true;
      }

      // If we found an empty bucket, the key doesn't exist in the set.
      // Insert it and return the default value.
      if (KeyInfoT::isEqual(ThisBucket->first, EmptyKey)) {
        // If we've already seen a tombstone while probing, fill it in instead
        // of the empty bucket we eventually probed to.
        if (FoundTombstone) ThisBucket = FoundTombstone;
        FoundBucket = FoundTombstone ? FoundTombstone : ThisBucket;
        return false;
      }

      // If this is a tombstone, remember it.  If Val ends up not in the map, we
      // prefer to return it than something that would require more probing.
      // Ditto for zero values.
      if (KeyInfoT::isEqual(ThisBucket->first, TombstoneKey) && !FoundTombstone)
        FoundTombstone = ThisBucket;  // Remember the first tombstone found.
      if (ZeroValuesArePurgeable  && 
          ThisBucket->second == 0  &&  !FoundTombstone) 
        FoundTombstone = ThisBucket;

      // Otherwise, it's a hash collision or a tombstone, continue quadratic
      // probing.
      BucketNo += ProbeAmt++;
      ProbeCount++;
    } while (ProbeCount < NumBuckets);
    // If we get here then we did not find a bucket. This is a bug. Emit some diagnostics and abort.
    unsigned EmptyCount = 0, TombstoneCount = 0, ZeroCount = 0, ValueCount = 0;
    BucketsPtr = Buckets;
    for (unsigned i=0; i<NumBuckets; i++) {
        if (KeyInfoT::isEqual(BucketsPtr->first, EmptyKey)) EmptyCount++;
        else if (KeyInfoT::isEqual(BucketsPtr->first, TombstoneKey)) TombstoneCount++;
        else if (KeyInfoT::isEqual(BucketsPtr->first, 0)) ZeroCount++;
        else ValueCount++;
        BucketsPtr++;
    }
    _objc_fatal("DenseMap::LookupBucketFor() failed to find available bucket.\nNumBuckets = %d, EmptyCount = %d, TombstoneCount = %d, ZeroCount = %d, ValueCount = %d\n", NumBuckets, EmptyCount, TombstoneCount, ZeroCount, ValueCount);
  }

  void init(unsigned InitBuckets) {
    NumEntries = 0;
    NumTombstones = 0;
    NumBuckets = InitBuckets;
    assert(InitBuckets && (InitBuckets & (InitBuckets-1)) == 0 &&
           "# initial buckets must be a power of two!");
    Buckets = static_cast<BucketT*>(operator new(sizeof(BucketT)*InitBuckets));
    // Initialize all the keys to EmptyKey.
    const KeyT EmptyKey = getEmptyKey();
    for (unsigned i = 0; i != InitBuckets; ++i)
      new (&Buckets[i].first) KeyT(EmptyKey);
  }

  void grow(unsigned AtLeast) {
    unsigned OldNumBuckets = NumBuckets;
    BucketT *OldBuckets = Buckets;

    // Double the number of buckets.
    while (NumBuckets < AtLeast)
      NumBuckets <<= 1;
    NumTombstones = 0;
    Buckets = static_cast<BucketT*>(operator new(sizeof(BucketT)*NumBuckets));

    // Initialize all the keys to EmptyKey.
    const KeyT EmptyKey = getEmptyKey();
    for (unsigned i = 0, e = NumBuckets; i != e; ++i)
      new (&Buckets[i].first) KeyT(EmptyKey);

    // Insert all the old elements.
    const KeyT TombstoneKey = getTombstoneKey();
    for (BucketT *B = OldBuckets, *E = OldBuckets+OldNumBuckets; B != E; ++B) {
      if (!KeyInfoT::isEqual(B->first, EmptyKey) &&
          !KeyInfoT::isEqual(B->first, TombstoneKey)) 
      {
        // Valid key/value, or zero value
        if (!ZeroValuesArePurgeable  ||  B->second != 0) {
          // Insert the key/value into the new table.
          BucketT *DestBucket;
          bool FoundVal = LookupBucketFor(B->first, DestBucket);
          (void)FoundVal; // silence warning.
          assert(!FoundVal && "Key already in new map?");
          DestBucket->first = B->first;
          new (&DestBucket->second) ValueT(B->second);
        } else {
          NumEntries--;
        }

        // Free the value.
        B->second.~ValueT();
      }
      B->first.~KeyT();
    }

#ifndef NDEBUG
    memset(OldBuckets, 0x5a, sizeof(BucketT)*OldNumBuckets);
#endif
    // Free the old table.
    operator delete(OldBuckets);
  }

  void shrink_and_clear() {
    unsigned OldNumBuckets = NumBuckets;
    BucketT *OldBuckets = Buckets;

    // Reduce the number of buckets.
    NumBuckets = NumEntries > 32 ? 1 << (Log2_32_Ceil(NumEntries) + 1)
                                 : 64;
    NumTombstones = 0;
    Buckets = static_cast<BucketT*>(operator new(sizeof(BucketT)*NumBuckets));

    // Initialize all the keys to EmptyKey.
    const KeyT EmptyKey = getEmptyKey();
    for (unsigned i = 0, e = NumBuckets; i != e; ++i)
      new (&Buckets[i].first) KeyT(EmptyKey);

    // Free the old buckets.
    const KeyT TombstoneKey = getTombstoneKey();
    for (BucketT *B = OldBuckets, *E = OldBuckets+OldNumBuckets; B != E; ++B) {
      if (!KeyInfoT::isEqual(B->first, EmptyKey) &&
          !KeyInfoT::isEqual(B->first, TombstoneKey)) {
        // Free the value.
        B->second.~ValueT();
      }
      B->first.~KeyT();
    }

#ifndef NDEBUG
    memset(OldBuckets, 0x5a, sizeof(BucketT)*OldNumBuckets);
#endif
    // Free the old table.
    operator delete(OldBuckets);

    NumEntries = 0;
  }
};

template<typename KeyT, typename ValueT,
         typename KeyInfoT, typename ValueInfoT, bool IsConst>
class DenseMapIterator {
  typedef std::pair<KeyT, ValueT> Bucket;
  typedef DenseMapIterator<KeyT, ValueT,
                           KeyInfoT, ValueInfoT, true> ConstIterator;
  friend class DenseMapIterator<KeyT, ValueT, KeyInfoT, ValueInfoT, true>;
public:
  typedef ptrdiff_t difference_type;
  typedef typename conditional<IsConst, const Bucket, Bucket>::type value_type;
  typedef value_type *pointer;
  typedef value_type &reference;
  typedef std::forward_iterator_tag iterator_category;
private:
  pointer Ptr, End;
public:
  DenseMapIterator() : Ptr(0), End(0) {}

  DenseMapIterator(pointer Pos, pointer E) : Ptr(Pos), End(E) {
    AdvancePastEmptyBuckets();
  }

  // If IsConst is true this is a converting constructor from iterator to
  // const_iterator and the default copy constructor is used.
  // Otherwise this is a copy constructor for iterator.
  DenseMapIterator(const DenseMapIterator<KeyT, ValueT,
                                          KeyInfoT, ValueInfoT, false>& I)
    : Ptr(I.Ptr), End(I.End) {}

  reference operator*() const {
    return *Ptr;
  }
  pointer operator->() const {
    return Ptr;
  }

  bool operator==(const ConstIterator &RHS) const {
    return Ptr == RHS.operator->();
  }
  bool operator!=(const ConstIterator &RHS) const {
    return Ptr != RHS.operator->();
  }

  inline DenseMapIterator& operator++() {  // Preincrement
    ++Ptr;
    AdvancePastEmptyBuckets();
    return *this;
  }
  DenseMapIterator operator++(int) {  // Postincrement
    DenseMapIterator tmp = *this; ++*this; return tmp;
  }

private:
  void AdvancePastEmptyBuckets() {
    const KeyT Empty = KeyInfoT::getEmptyKey();
    const KeyT Tombstone = KeyInfoT::getTombstoneKey();

    while (Ptr != End &&
           (KeyInfoT::isEqual(Ptr->first, Empty) ||
            KeyInfoT::isEqual(Ptr->first, Tombstone)))
      ++Ptr;
  }
};

} // end namespace objc

#endif
