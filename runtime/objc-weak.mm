/*
 * Copyright (c) 2010-2011 Apple Inc. All rights reserved.
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

#include "objc-weak.h"
#include "objc-os.h"
#include "objc-private.h"

#include <stdint.h>
#include <stdbool.h>
#include <sys/types.h>
#include <libkern/OSAtomic.h>


template <typename T> struct WeakAllocator {
    typedef T                 value_type;
    typedef value_type*       pointer;
    typedef const value_type *const_pointer;
    typedef value_type&       reference;
    typedef const value_type& const_reference;
    typedef size_t            size_type;
    typedef ptrdiff_t         difference_type;

    template <typename U> struct rebind { typedef WeakAllocator<U> other; };

    template <typename U> WeakAllocator(const WeakAllocator<U>&) {}
    WeakAllocator() {}
    WeakAllocator(const WeakAllocator&) {}
    ~WeakAllocator() {}

    pointer address(reference x) const { return &x; }
    const_pointer address(const_reference x) const { 
        return x;
    }

    pointer allocate(size_type n, const_pointer = 0) {
        return static_cast<pointer>(::_malloc_internal(n * sizeof(T)));
    }

    void deallocate(pointer p, size_type) { ::_free_internal(p); }

    size_type max_size() const { 
        return static_cast<size_type>(-1) / sizeof(T);
    }

    void construct(pointer p, const value_type& x) { 
        new(p) value_type(x); 
    }

    void destroy(pointer p) { p->~value_type(); }

    void operator=(const WeakAllocator&);

};

class Range {
private:
    void *_address;                                     // start of range
    void *_end;                                         // end of the range (one byte beyond last usable space)
public:
    static void *displace(void *address, ptrdiff_t offset) { return (void *)((char *)address + offset); }

    //
    // Constructors
    //
    Range()                             : _address(NULL),    _end(NULL) {}
    Range(void *address)                : _address(address), _end(address) {}
    Range(void *address, void *end)     : _address(address), _end(end) {}
    Range(void *address, size_t size)   : _address(address), _end(displace(address, size)) {}
    
    //
    // Accessors
    //
    inline Range& range()                                       { return *this; }
    inline void   *address()                              const { return _address; }
    inline void   *end()                                  const { return _end; }
    inline size_t size()                                  const { return (uintptr_t)_end - (uintptr_t)_address; }
    inline void   set_address(void *address)                    { _address = address; }
    inline void   set_end(void *end)                            { _end = end; }
    inline void   set_size(size_t size)                         { _end = displace(_address, size); }
    inline void   set_range(void *address, void *end)           { _address = address; _end = end; }
    inline void   set_range(void *address, size_t size)         { _address = address; _end = displace(address, size); }
    inline void   set_range(Range range)                        { _address = range.address(); _end = range.end(); }
    inline void   adjust_address(intptr_t delta)                { _address = displace(_address, delta); }
    inline void   adjust_end(intptr_t delta)                    { _end = displace(_end, delta); }
    inline void   adjust(intptr_t delta)                        { _address = displace(_address, delta), _end = displace(_end, delta); }
    
    
    //
    // is_empty
    //
    // Returns true if the range is empty.
    //
    inline bool is_empty() { return _address == _end; }

    
    //
    // in_range
    //
    // Returns true if the specified address is in range.
    // This form reduces the number of branches.  Works well with invariant lo and hi.
    //
    static inline bool in_range(void *lo, void *hi, void *address) {
        uintptr_t lo_as_int = (uintptr_t)lo;
        uintptr_t hi_as_int = (uintptr_t)hi;
        uintptr_t diff = hi_as_int - lo_as_int;
        uintptr_t address_as_int = (uintptr_t)address;
        return (address_as_int - lo_as_int) < diff;
    }
    inline bool in_range(void *address) const { return in_range(_address, _end, address); }
    
    
    //
    // operator ==
    //
    // Used to locate entry in list or hash table (use is_range for exaxt match.)
    inline bool operator==(const Range *range)  const { return _address == range->_address; }
    inline bool operator==(const Range &range)  const { return _address == range._address; }
    

    //
    // is_range
    //
    // Return true if the ranges are equivalent.
    //
    inline bool is_range(const Range& range) const { return _address == range._address && _end == range._end; }
    
    
    //
    // clear
    //
    // Initialize the range to zero.
    //
    inline void clear() { bzero(address(), size()); }
    
    //
    // expand_range
    //
    // Expand the bounds with the specified range.
    //
    inline void expand_range(void *address) {
        if (_address > address) _address = address;
        if (_end < address) _end = address;
    }
    inline void expand_range(Range& range) {
        expand_range(range.address());
        expand_range(range.end());
    }
            
    
    //
    // relative_address
    //
    // Converts an absolute address to an address relative to this address.
    //
    inline void *relative_address(void *address) const { return (void *)((uintptr_t)address - (uintptr_t)_address); }

    
    //
    // absolute_address
    //
    // Converts an address relative to this address to an absolute address.
    //
    inline void *absolute_address(void *address) const { return (void *)((uintptr_t)address + (uintptr_t)_address); }
};


template<> struct WeakAllocator<void> {
    typedef void        value_type;
    typedef void*       pointer;
    typedef const void *const_pointer;
    template <typename U> struct rebind { typedef WeakAllocator<U> other; };
};

typedef std::pair<id, id *> WeakPair;
typedef std::vector<WeakPair, WeakAllocator<WeakPair> > WeakPairVector;
typedef std::vector<weak_referrer_t, WeakAllocator<WeakPair> > WeakReferrerVector;

static void append_referrer_no_lock(weak_referrer_array_t *list, id *new_referrer);

static inline uintptr_t hash_pointer(void *key) {
    uintptr_t k = (uintptr_t)key;

    // Code from CFSet.c
#if __LP64__
    uintptr_t a = 0x4368726973746F70ULL;
    uintptr_t b = 0x686572204B616E65ULL;
#else
    uintptr_t a = 0x4B616E65UL;
    uintptr_t b = 0x4B616E65UL; 
#endif
    uintptr_t c = 1;
    a += k;
#if __LP64__
    a -= b; a -= c; a ^= (c >> 43);
    b -= c; b -= a; b ^= (a << 9);
    c -= a; c -= b; c ^= (b >> 8);
    a -= b; a -= c; a ^= (c >> 38);
    b -= c; b -= a; b ^= (a << 23);
    c -= a; c -= b; c ^= (b >> 5);
    a -= b; a -= c; a ^= (c >> 35);
    b -= c; b -= a; b ^= (a << 49);
    c -= a; c -= b; c ^= (b >> 11);
    a -= b; a -= c; a ^= (c >> 12);
    b -= c; b -= a; b ^= (a << 18);
    c -= a; c -= b; c ^= (b >> 22);
#else
    a -= b; a -= c; a ^= (c >> 13);
    b -= c; b -= a; b ^= (a << 8);
    c -= a; c -= b; c ^= (b >> 13);
    a -= b; a -= c; a ^= (c >> 12);
    b -= c; b -= a; b ^= (a << 16);
    c -= a; c -= b; c ^= (b >> 5);
    a -= b; a -= c; a ^= (c >> 3);
    b -= c; b -= a; b ^= (a << 10);
    c -= a; c -= b; c ^= (b >> 15);
#endif
    return c;
}

// Up until this size the weak referrer array grows one slot at a time. Above this size it grows by doubling.
#define WEAK_TABLE_DOUBLE_SIZE 8

// Grow the refs list. Rehashes the entries.
static void grow_refs(weak_referrer_array_t *list)
{
    size_t old_num_allocated = list->num_allocated;
    size_t num_refs = list->num_refs;
    weak_referrer_t *old_refs = list->refs;
    size_t new_allocated = old_num_allocated < WEAK_TABLE_DOUBLE_SIZE ? old_num_allocated + 1 : old_num_allocated + old_num_allocated;
    list->refs = (weak_referrer_t *)_malloc_internal(new_allocated * sizeof(weak_referrer_t));
    list->num_allocated = _malloc_size_internal(list->refs)/sizeof(weak_referrer_t);
    bzero(list->refs, list->num_allocated * sizeof(weak_referrer_t));
    // for larger tables drop one entry from the end to give an odd number of hash buckets for better hashing
    if ((list->num_allocated > WEAK_TABLE_DOUBLE_SIZE) && !(list->num_allocated & 1)) list->num_allocated--;
    list->num_refs = 0;
    list->max_hash_displacement = 0;
    
    size_t i;
    for (i=0; i < old_num_allocated && num_refs > 0; i++) {
        if (old_refs[i].referrer != NULL) {
            append_referrer_no_lock(list, old_refs[i].referrer);
            num_refs--;
        }
    }
    if (old_refs)
        _free_internal(old_refs);
}

// Add the given referrer to list
// Does not perform duplicate checking.
static void append_referrer_no_lock(weak_referrer_array_t *list, id *new_referrer)
{
    if ((list->num_refs == list->num_allocated) || ((list->num_refs >= WEAK_TABLE_DOUBLE_SIZE) && (list->num_refs >= list->num_allocated * 2 / 3))) {
        grow_refs(list);
    }
    size_t index = hash_pointer(new_referrer) % list->num_allocated, hash_displacement = 0;
    while (list->refs[index].referrer != NULL) {
        index++;
        hash_displacement++;
        if (index == list->num_allocated)
            index = 0;
    }
    if (list->max_hash_displacement < hash_displacement) {
        list->max_hash_displacement = hash_displacement;
        //malloc_printf("max_hash_displacement: %d allocated: %d\n", list->max_hash_displacement, list->num_allocated);
    }
    weak_referrer_t &ref = list->refs[index];
    ref.referrer = new_referrer;
    list->num_refs++;
}


// Remove old_referrer from list, if it's present.
// Does not remove duplicates.
// fixme this is slow if old_referrer is not present.
static void remove_referrer_no_lock(weak_referrer_array_t *list, id *old_referrer)
{
    size_t index = hash_pointer(old_referrer) % list->num_allocated;
    size_t start_index = index, hash_displacement = 0;
    while (list->refs[index].referrer != old_referrer) {
        index++;
        hash_displacement++;
        if (index == list->num_allocated)
            index = 0;
        if (index == start_index || hash_displacement > list->max_hash_displacement) {
            malloc_printf("attempted to remove unregistered weak referrer %p\n", old_referrer);
            return;
        }
    }
    list->refs[index].referrer = NULL;
    list->num_refs--;
}


// Add new_entry to the zone's table of weak references.
// Does not check whether the referent is already in the table.
// Does not update num_weak_refs.
static void weak_entry_insert_no_lock(weak_table_t *weak_table, weak_entry_t *new_entry)
{
    weak_entry_t *weak_entries = weak_table->weak_entries;
    assert(weak_entries != NULL);

    size_t table_size = weak_table->max_weak_refs;
    size_t hash_index = hash_pointer(new_entry->referent) % table_size;
    size_t index = hash_index;

    do {
        weak_entry_t *entry = weak_entries + index;
        if (entry->referent == NULL) {
            *entry = *new_entry;
            return;
        }
        index++; if (index == table_size) index = 0;
    } while (index != hash_index);
    malloc_printf("no room for new entry in auto weak ref table!\n");
}


// Remove entry from the zone's table of weak references, and rehash
// Does not update num_weak_refs.
static void weak_entry_remove_no_lock(weak_table_t *weak_table, weak_entry_t *entry)
{
    // remove entry
    entry->referent = NULL;
    if (entry->referrers.refs) _free_internal(entry->referrers.refs);
    entry->referrers.refs = NULL;
    entry->referrers.num_refs = 0;
    entry->referrers.num_allocated = 0;

    // rehash after entry
    weak_entry_t *weak_entries = weak_table->weak_entries;
    size_t table_size = weak_table->max_weak_refs;
    size_t hash_index = entry - weak_entries;
    size_t index = hash_index;

    if (!weak_entries) return;

    do {
        index++; if (index == table_size) index = 0;
        if (!weak_entries[index].referent) return;
        weak_entry_t slot = weak_entries[index];
        weak_entries[index].referent = NULL;
        weak_entry_insert_no_lock(weak_table, &slot);
    } while (index != hash_index);
}


// Grow the given zone's table of weak references if it is full.
static void weak_grow_maybe_no_lock(weak_table_t *weak_table)
{
    if (weak_table->num_weak_refs >= weak_table->max_weak_refs * 3 / 4) {
        // grow table
        size_t old_max = weak_table->max_weak_refs;
        size_t new_max = old_max ? old_max * 2 + 1 : 15;
        weak_entry_t *old_entries = weak_table->weak_entries;
        weak_entry_t *new_entries = (weak_entry_t *)_calloc_internal(new_max, sizeof(weak_entry_t));
        weak_table->max_weak_refs = new_max;
        weak_table->weak_entries = new_entries;

        if (old_entries) {
            weak_entry_t *entry;
            weak_entry_t *end = old_entries + old_max;
            for (entry = old_entries; entry < end; entry++) {
                weak_entry_insert_no_lock(weak_table, entry);
            }
            _free_internal(old_entries);
        }
    }
}

// Return the weak reference table entry for the given referent. 
// If there is no entry for referent, return NULL.
static weak_entry_t *weak_entry_for_referent(weak_table_t *weak_table, id referent)
{
    weak_entry_t *weak_entries = weak_table->weak_entries;

    if (!weak_entries) return NULL;
    
    size_t table_size = weak_table->max_weak_refs;
    size_t hash_index = hash_pointer(referent) % table_size;
    size_t index = hash_index;

    do {
        weak_entry_t *entry = weak_entries + index;
        if (entry->referent == referent) return entry;
        if (entry->referent == NULL) return NULL;
        index++; if (index == table_size) index = 0;
    } while (index != hash_index);

    return NULL;
}

// Unregister an already-registered weak reference. 
// This is used when referrer's storage is about to go away, but referent 
//   isn't dead yet. (Otherwise, zeroing referrer later would be a 
//   bad memory access.)
// Does nothing if referent/referrer is not a currently active weak reference.
// Does not zero referrer.
// fixme currently requires old referent value to be passed in (lame)
// fixme unregistration should be automatic if referrer is collected
void weak_unregister_no_lock(weak_table_t *weak_table, id referent, id *referrer)
{
    weak_entry_t *entry;

    if ((entry = weak_entry_for_referent(weak_table, referent))) {
        remove_referrer_no_lock(&entry->referrers, referrer);
        if (entry->referrers.num_refs == 0) {
            weak_entry_remove_no_lock(weak_table, entry);
            weak_table->num_weak_refs--;
        }
    } 

    // Do not set *referrer = NULL. objc_storeWeak() requires that the 
    // value not change.
}


void 
arr_clear_deallocating(weak_table_t *weak_table, id referent) {
    {
        weak_entry_t *entry = weak_entry_for_referent(weak_table, referent);
        if (entry == NULL) {
            /// XXX shouldn't happen, but does with mismatched CF/objc
            //printf("XXX no entry for clear deallocating %p\n", referent);
            return;
        }
        // zero out references
        for (size_t i = 0; i < entry->referrers.num_allocated; ++i) {
            id *referrer = entry->referrers.refs[i].referrer;
            if (referrer) {
                if (*referrer == referent) {
                    *referrer = nil;
                }
                else if (*referrer) {
                    _objc_inform("__weak variable @ %p holds %p instead of %p\n", referrer, *referrer, referent);
                }
            }
        }
            
        weak_entry_remove_no_lock(weak_table, entry);
        weak_table->num_weak_refs--;
    }
}


id weak_register_no_lock(weak_table_t *weak_table, id referent, id *referrer) {
    if (referent && !OBJC_IS_TAGGED_PTR(referent)) {
        // ensure that the referenced object is viable
        BOOL (*allowsWeakReference)(id, SEL) = (BOOL(*)(id, SEL))
        class_getMethodImplementation(object_getClass(referent), 
                                      @selector(allowsWeakReference));
        if ((IMP)allowsWeakReference != _objc_msgForward) {
            if (! (*allowsWeakReference)(referent, @selector(allowsWeakReference))) {
                _objc_fatal("cannot form weak reference to instance (%p) of class %s", referent, object_getClassName(referent));
            }
        }
        else {
            return NULL;
        }
        // now remember it and where it is being stored
        weak_entry_t *entry;
        if ((entry = weak_entry_for_referent(weak_table, referent))) {
            append_referrer_no_lock(&entry->referrers, referrer);
        } 
        else {
            weak_entry_t new_entry;
            new_entry.referent = referent;
            new_entry.referrers.refs = NULL;
            new_entry.referrers.num_refs = 0;
            new_entry.referrers.num_allocated = 0;
            append_referrer_no_lock(&new_entry.referrers, referrer);
            weak_table->num_weak_refs++;
            weak_grow_maybe_no_lock(weak_table);
            weak_entry_insert_no_lock(weak_table, &new_entry);
        }
    }

    // Do not set *referrer. objc_storeWeak() requires that the 
    // value not change.

    return referent;
}


// Automated Retain Release (ARR) support

id 
arr_read_weak_reference(weak_table_t *weak_table, id *referrer) {
    id referent;
    // find entry and mark that it needs retaining
    {
        referent = *referrer;
        if (OBJC_IS_TAGGED_PTR(referent)) return referent;
        weak_entry_t *entry;
        if (referent == NULL || !(entry = weak_entry_for_referent(weak_table, referent))) {
            *referrer = NULL;
            return NULL;
        }
        BOOL (*tryRetain)(id, SEL) = (BOOL(*)(id, SEL))
            class_getMethodImplementation(object_getClass(referent), 
                                          @selector(retainWeakReference));
        if ((IMP)tryRetain != _objc_msgForward) {
            //printf("sending _tryRetain for %p\n", referent);
            if (! (*tryRetain)(referent, @selector(retainWeakReference))) {
                //printf("_tryRetain(%p) tried and failed!\n", referent);
                return NULL;
            }
            //else printf("_tryRetain(%p) succeeded\n", referent);
        }
        else {
            *referrer = NULL;
            return NULL;
        }
    }
    return referent;
}

