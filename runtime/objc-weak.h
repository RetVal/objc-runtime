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

#include <objc/objc.h>
#include "objc-config.h"

__BEGIN_DECLS

/*
The weak table is a hash table governed by a single spin lock.
An allocated blob of memory, most often an object, but under GC any such allocation,
may have its address stored in a __weak marked storage location through use of
compiler generated write-barriers or hand coded uses of the register weak primitive.
Associated with the registration can be a callback block for the case when one of
 the allocated chunks of memory is reclaimed.
The table is hashed on the address of the allocated memory.  When __weak marked memory
 changes its reference, we count on the fact that we can still see its previous reference.

So, in the hash table, indexed by the weakly referenced item, is a list of all locations
 where this address is currently being stored.
 
For ARR, we also keep track of whether an arbitrary object is being deallocated by
 briefly placing it in the table just prior to invoking dealloc, and removing it
 via objc_clear_deallocating just prior to memory reclamation.
 
*/

struct weak_referrer_t {
    id *referrer;       // clear this address
};
typedef struct weak_referrer_t weak_referrer_t;

struct weak_referrer_array_t {
    weak_referrer_t     *refs;
    size_t              num_refs;
    size_t              num_allocated;
    size_t              max_hash_displacement;
};
typedef struct weak_referrer_array_t weak_referrer_array_t;

struct weak_entry_t {
    id                      referent;
    weak_referrer_array_t   referrers;
};
typedef struct weak_entry_t weak_entry_t;

struct weak_table_t {
    size_t              num_weak_refs;
    size_t              max_weak_refs;
    struct weak_entry_t *weak_entries;
};
typedef struct weak_table_t weak_table_t;

extern id weak_register_no_lock(weak_table_t *weak_table, id referent, id *referrer);
extern void weak_unregister_no_lock(weak_table_t *weak_table, id referent, id *referrer);

extern id arr_read_weak_reference(weak_table_t *weak_table, id *referrer);
extern void arr_clear_deallocating(weak_table_t *weak_table, id referent);

__END_DECLS
