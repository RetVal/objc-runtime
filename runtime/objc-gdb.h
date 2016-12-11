/*
 * Copyright (c) 2008 Apple Inc.  All Rights Reserved.
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

#ifndef _OBJC_GDB_H
#define _OBJC_GDB_H

/* 
 * WARNING  DANGER  HAZARD  BEWARE  EEK
 * 
 * Everything in this file is for debugger and developer tool use only.
 * These will change in arbitrary OS updates and in unpredictable ways.
 * When your program breaks, you get to keep both pieces.
 */

#ifdef __APPLE_API_PRIVATE

#define _OBJC_PRIVATE_H_
#include <stdint.h>
#include <objc/hashtable.h>
#include <objc/maptable.h>

__BEGIN_DECLS


/***********************************************************************
* Class pointer preflighting
**********************************************************************/

// Return cls if it's a valid class, or crash.
OBJC_EXPORT Class gdb_class_getClass(Class cls)
#if __OBJC2__
    OBJC_AVAILABLE(10.6, 3.1, 9.0, 1.0);
#else
    OBJC_AVAILABLE(10.7, 3.1, 9.0, 1.0);
#endif

// Same as gdb_class_getClass(object_getClass(cls)).
OBJC_EXPORT Class gdb_object_getClass(id obj)
    OBJC_AVAILABLE(10.7, 4.3, 9.0, 1.0);


/***********************************************************************
* Class lists for heap.
**********************************************************************/

#if __OBJC2__

// Maps class name to Class, for in-use classes only. NXStrValueMapPrototype.
OBJC_EXPORT NXMapTable *gdb_objc_realized_classes
    OBJC_AVAILABLE(10.6, 3.1, 9.0, 1.0);

#else

// Hashes Classes, for all known classes. Custom prototype.
OBJC_EXPORT NXHashTable *_objc_debug_class_hash
    __OSX_AVAILABLE(10.2) 
    __IOS_UNAVAILABLE __TVOS_UNAVAILABLE __WATCHOS_UNAVAILABLE;

#endif


/***********************************************************************
* Non-pointer isa
**********************************************************************/

#if __OBJC2__

// Extract isa pointer from an isa field.
// (Class)(isa & mask) == class pointer
OBJC_EXPORT const uintptr_t objc_debug_isa_class_mask
    OBJC_AVAILABLE(10.10, 7.0, 9.0, 1.0);

// Extract magic cookie from an isa field.
// (isa & magic_mask) == magic_value
OBJC_EXPORT const uintptr_t objc_debug_isa_magic_mask
    OBJC_AVAILABLE(10.10, 7.0, 9.0, 1.0);
OBJC_EXPORT const uintptr_t objc_debug_isa_magic_value
    OBJC_AVAILABLE(10.10, 7.0, 9.0, 1.0);

// Use indexed ISAs for targets which store index of the class in the ISA.
// This index can be used to index the array of classes.
OBJC_EXPORT const uintptr_t objc_debug_indexed_isa_magic_mask;
OBJC_EXPORT const uintptr_t objc_debug_indexed_isa_magic_value;

// Then these are used to extract the index from the ISA.
OBJC_EXPORT const uintptr_t objc_debug_indexed_isa_index_mask;
OBJC_EXPORT const uintptr_t objc_debug_indexed_isa_index_shift;

// And then we can use that index to get the class from this array.  Note
// the size is provided so that clients can ensure the index they get is in
// bounds and not read off the end of the array.
OBJC_EXPORT Class objc_indexed_classes[];

// When we don't have enough bits to store a class*, we can instead store an
// index in to this array.  Classes are added here when they are realized.
// Note, an index of 0 is illegal.
OBJC_EXPORT uintptr_t objc_indexed_classes_count;

// Absolute symbols for some of the above values are in objc-abi.h.

#endif


/***********************************************************************
* Tagged pointer decoding
**********************************************************************/
#if __OBJC2__

// Basic tagged pointers (7 classes, 60-bit payload).

// if (obj & mask) obj is a tagged pointer object
OBJC_EXPORT uintptr_t objc_debug_taggedpointer_mask
    OBJC_AVAILABLE(10.9, 7.0, 9.0, 1.0);

// tag_slot = (obj >> slot_shift) & slot_mask
OBJC_EXPORT unsigned int objc_debug_taggedpointer_slot_shift
    OBJC_AVAILABLE(10.9, 7.0, 9.0, 1.0);
OBJC_EXPORT uintptr_t objc_debug_taggedpointer_slot_mask
    OBJC_AVAILABLE(10.9, 7.0, 9.0, 1.0);

// class = classes[tag_slot]
OBJC_EXPORT Class objc_debug_taggedpointer_classes[]
    OBJC_AVAILABLE(10.9, 7.0, 9.0, 1.0);

// payload = (obj << payload_lshift) >> payload_rshift
// Payload signedness is determined by the signedness of the right-shift.
OBJC_EXPORT unsigned int objc_debug_taggedpointer_payload_lshift
    OBJC_AVAILABLE(10.9, 7.0, 9.0, 1.0);
OBJC_EXPORT unsigned int objc_debug_taggedpointer_payload_rshift
    OBJC_AVAILABLE(10.9, 7.0, 9.0, 1.0);


// Extended tagged pointers (255 classes, 52-bit payload).

// If you interrogate an extended tagged pointer using the basic 
// tagged pointer scheme alone, it will appear to have an isa 
// that is either nil or class __NSUnrecognizedTaggedPointer.

// if (ext_mask != 0  &&  (obj & ext_mask) == ext_mask) 
//   obj is a ext tagged pointer object
OBJC_EXPORT uintptr_t objc_debug_taggedpointer_ext_mask
    OBJC_AVAILABLE(10.12, 10.0, 10.0, 3.0);

// ext_tag_slot = (obj >> ext_slot_shift) & ext_slot_mask
OBJC_EXPORT unsigned int objc_debug_taggedpointer_ext_slot_shift
    OBJC_AVAILABLE(10.12, 10.0, 10.0, 3.0);
OBJC_EXPORT uintptr_t objc_debug_taggedpointer_ext_slot_mask
    OBJC_AVAILABLE(10.12, 10.0, 10.0, 3.0);

// class = ext_classes[ext_tag_slot]
OBJC_EXPORT Class objc_debug_taggedpointer_ext_classes[]
    OBJC_AVAILABLE(10.12, 10.0, 10.0, 3.0);

// payload = (obj << ext_payload_lshift) >> ext_payload_rshift
// Payload signedness is determined by the signedness of the right-shift.
OBJC_EXPORT unsigned int objc_debug_taggedpointer_ext_payload_lshift
    OBJC_AVAILABLE(10.12, 10.0, 10.0, 3.0);
OBJC_EXPORT unsigned int objc_debug_taggedpointer_ext_payload_rshift
    OBJC_AVAILABLE(10.12, 10.0, 10.0, 3.0);

#endif


/***********************************************************************
* Breakpoints in objc_msgSend for debugger stepping.
* The array is a {0,0} terminated list of addresses. 
* Each address is one of the following:
* OBJC_MESSENGER_START:    Address is the start of a messenger function.
* OBJC_MESSENGER_END_FAST: Address is a jump insn that calls an IMP.
* OBJC_MESSENGER_END_SLOW: Address is some insn in the slow lookup path.
* OBJC_MESSENGER_END_NIL:  Address is a return insn for messages to nil.
* 
* Every path from OBJC_MESSENGER_START should reach some OBJC_MESSENGER_END.
* At all ENDs, the stack and parameter register state is the same as START.
*
* In some cases, the END_FAST case jumps to something other than the
* method's implementation. In those cases the jump's destination will 
* be another function that is marked OBJC_MESSENGER_START.
**********************************************************************/
#if __OBJC2__

#define OBJC_MESSENGER_START    1
#define OBJC_MESSENGER_END_FAST 2
#define OBJC_MESSENGER_END_SLOW 3
#define OBJC_MESSENGER_END_NIL  4

struct objc_messenger_breakpoint {
    uintptr_t address;
    uintptr_t kind;
};

OBJC_EXPORT struct objc_messenger_breakpoint 
gdb_objc_messenger_breakpoints[]
    OBJC_AVAILABLE(10.9, 7.0, 9.0, 1.0);

#endif


__END_DECLS

#endif

#endif
