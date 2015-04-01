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
* Trampoline descriptors for gdb.
**********************************************************************/

#if __OBJC2__  &&  defined(__x86_64__)

typedef struct {
    uint32_t offset;  // 0 = unused, else code = (uintptr_t)desc + desc->offset
    uint32_t flags;
} objc_trampoline_descriptor;
#define OBJC_TRAMPOLINE_MESSAGE (1<<0)   // trampoline acts like objc_msgSend
#define OBJC_TRAMPOLINE_STRET   (1<<1)   // trampoline is struct-returning
#define OBJC_TRAMPOLINE_VTABLE  (1<<2)   // trampoline is vtable dispatcher

typedef struct objc_trampoline_header {
    uint16_t headerSize;  // sizeof(objc_trampoline_header)
    uint16_t descSize;    // sizeof(objc_trampoline_descriptor)
    uint32_t descCount;   // number of descriptors following this header
    struct objc_trampoline_header *next;
} objc_trampoline_header;

OBJC_EXPORT objc_trampoline_header *gdb_objc_trampolines
    __OSX_AVAILABLE_STARTING(__MAC_10_6, __IPHONE_NA);

OBJC_EXPORT void gdb_objc_trampolines_changed(objc_trampoline_header *thdr)
    __OSX_AVAILABLE_STARTING(__MAC_10_6, __IPHONE_NA);
// Notify gdb that gdb_objc_trampolines has changed.
// thdr itself includes the new descriptors; thdr->next is not new.

#endif


/***********************************************************************
* Debugger mode.
**********************************************************************/

// Start debugger mode. 
// Returns non-zero if debugger mode was successfully started.
// In debugger mode, you can try to use the runtime without deadlocking 
// on other threads. All other threads must be stopped during debugger mode. 
// OBJC_DEBUGMODE_FULL requires more locks so later operations are less 
// likely to fail.
#define OBJC_DEBUGMODE_FULL (1<<0)
OBJC_EXPORT int gdb_objc_startDebuggerMode(uint32_t flags)
    __OSX_AVAILABLE_STARTING(__MAC_10_6, __IPHONE_3_1);

// Stop debugger mode. Do not call if startDebuggerMode returned zero.
OBJC_EXPORT void gdb_objc_endDebuggerMode(void)
    __OSX_AVAILABLE_STARTING(__MAC_10_6, __IPHONE_3_1);

// Failure hook when debugger mode tries something that would block.
// Set a breakpoint here to handle it before the runtime causes a trap.
// Debugger mode is still active; call endDebuggerMode to end it.
OBJC_EXPORT void gdb_objc_debuggerModeFailure(void)
    __OSX_AVAILABLE_STARTING(__MAC_10_6, __IPHONE_3_1);

// Older debugger-mode mechanism. Too simplistic.
OBJC_EXPORT BOOL gdb_objc_isRuntimeLocked(void)
    __OSX_AVAILABLE_STARTING(__MAC_10_6, __IPHONE_3_1);

// Return cls if it's a valid class, or crash.
OBJC_EXPORT Class gdb_class_getClass(Class cls)
#if __OBJC2__
    __OSX_AVAILABLE_STARTING(__MAC_10_6, __IPHONE_3_1);
#else
    __OSX_AVAILABLE_STARTING(__MAC_10_7, __IPHONE_3_1);
#endif

// Same as gdb_class_getClass(object_getClass(cls)).
OBJC_EXPORT Class gdb_object_getClass(id obj)
    __OSX_AVAILABLE_STARTING(__MAC_10_7, __IPHONE_4_3);


/***********************************************************************
* Class lists for heap.
**********************************************************************/

#if __OBJC2__

// Maps class name to Class, for in-use classes only. NXStrValueMapPrototype.
OBJC_EXPORT NXMapTable *gdb_objc_realized_classes
    __OSX_AVAILABLE_STARTING(__MAC_10_6, __IPHONE_3_1);

#else

// Hashes Classes, for all known classes. Custom prototype.
OBJC_EXPORT NXHashTable *_objc_debug_class_hash
    __OSX_AVAILABLE_STARTING(__MAC_10_2, __IPHONE_NA);

#endif

#if __OBJC2__

// if (obj & mask) obj is a tagged pointer object
OBJC_EXPORT uintptr_t objc_debug_taggedpointer_mask
__OSX_AVAILABLE_STARTING(__MAC_10_8, __IPHONE_NA);

// tag_slot = (obj >> slot_shift) & slot_mask
OBJC_EXPORT unsigned int objc_debug_taggedpointer_slot_shift
__OSX_AVAILABLE_STARTING(__MAC_10_8, __IPHONE_NA);
OBJC_EXPORT uintptr_t objc_debug_taggedpointer_slot_mask
__OSX_AVAILABLE_STARTING(__MAC_10_8, __IPHONE_NA);

// class = classes[tag_slot]
OBJC_EXPORT Class objc_debug_taggedpointer_classes[]
__OSX_AVAILABLE_STARTING(__MAC_10_8, __IPHONE_NA);

// payload = (obj << payload_lshift) >> payload_rshift
// Payload signedness is determined by the signedness of the right-shift.
OBJC_EXPORT unsigned int objc_debug_taggedpointer_payload_lshift
__OSX_AVAILABLE_STARTING(__MAC_10_8, __IPHONE_NA);
OBJC_EXPORT unsigned int objc_debug_taggedpointer_payload_rshift
__OSX_AVAILABLE_STARTING(__MAC_10_8, __IPHONE_NA);

#endif


#ifndef OBJC_NO_GC

/***********************************************************************
 * Garbage Collector heap dump
**********************************************************************/

/* Dump GC heap; if supplied the name is returned in filenamebuffer.  Returns YES on success. */
OBJC_EXPORT BOOL objc_dumpHeap(char *filenamebuffer, unsigned long length)
    __OSX_AVAILABLE_STARTING(__MAC_10_7, __IPHONE_NA);

#define OBJC_HEAP_DUMP_FILENAME_FORMAT "/tmp/objc-gc-heap-dump-%d-%d"

#endif

__END_DECLS

#endif

#endif
