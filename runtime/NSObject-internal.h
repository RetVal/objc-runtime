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

#ifndef _NSOBJECT_INTERNAL_H
#define _NSOBJECT_INTERNAL_H

/*
 * WARNING  DANGER  HAZARD  BEWARE  EEK
 *
 * Everything in this file is for Apple Internal use only.
 * These will change in arbitrary OS updates and in unpredictable ways.
 * When your program breaks, you get to keep both pieces.
 */

/*
 * NSObject-internal.h: Private SPI for use by other system frameworks.
 */

/***********************************************************************
   Autorelease pool implementation

   A thread's autorelease pool is a stack of pointers.
   Each pointer is either an object to release, or POOL_BOUNDARY which is
	 an autorelease pool boundary.
   A pool token is a pointer to the POOL_BOUNDARY for that pool. When
	 the pool is popped, every object hotter than the sentinel is released.
   The stack is divided into a doubly-linked list of pages. Pages are added
	 and deleted as necessary.
   Thread-local storage points to the hot page, where newly autoreleased
	 objects are stored.
**********************************************************************/

#include <stdint.h>

// structure version number. Only bump if ABI compatability is broken
#define AUTORELEASEPOOL_VERSION 1

// Set this to 1 to mprotect() autorelease pool contents
#define PROTECT_AUTORELEASEPOOL 0

// Set this to 1 to validate the entire autorelease pool header all the time
// (i.e. use check() instead of fastcheck() everywhere)
#define CHECK_AUTORELEASEPOOL (DEBUG)

#ifdef __cplusplus
#include <string.h>
#include <assert.h>
#include <objc/objc.h>

#ifndef C_ASSERT
	#if __has_feature(cxx_static_assert)
		#define C_ASSERT(expr) static_assert(expr, "(" #expr ")!")
	#elif __has_feature(c_static_assert)
		#define C_ASSERT(expr) _Static_assert(expr, "(" #expr ")!")
	#else
		#define C_ASSERT(expr)
	#endif
#endif

// Make OBJC_ASSERT work when objc-private.h hasn't been included.
// Note: we avoid defining our own ASSERT because this header gets included by
// clients, and that macro name is too generic.
#ifdef ASSERT
#define OBJC_ASSERT(x) ASSERT(x)
#else
#define OBJC_ASSERT(x) assert(x)
#endif

// Make objc_thread_t work when objc-os.h hasn't been included.
#if !OBJC_THREAD_T_DEFINED
typedef struct objc_thread *objc_thread_t;
#endif

struct magic_t {
	static const uint32_t M0 = 0xA1A1A1A1;
#   define M1 "AUTORELEASE!"
	static const size_t M1_len = 12;
	uint32_t m[4];

	magic_t() {
		OBJC_ASSERT(M1_len == strlen(M1));
		OBJC_ASSERT(M1_len == 3 * sizeof(m[1]));

		m[0] = M0;
		strncpy((char *)&m[1], M1, M1_len);
	}

	~magic_t() {
		// Clear magic before deallocation.
		// This prevents some false positives in memory debugging tools.
		// fixme semantically this should be memset_s(), but the
		// compiler doesn't optimize that at all (rdar://44856676).
		volatile uint64_t *p = (volatile uint64_t *)m;
		p[0] = 0; p[1] = 0;
	}

	bool check() const {
		return (m[0] == M0 && 0 == strncmp((char *)&m[1], M1, M1_len));
	}

	bool fastcheck() const {
#if CHECK_AUTORELEASEPOOL
		return check();
#else
		return (m[0] == M0);
#endif
	}

#   undef M1
};

class AutoreleasePoolPage;
struct AutoreleasePoolPageData
{
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
    struct AutoreleasePoolEntry {
        uintptr_t ptr: 48;
        uintptr_t count: 16;

        static const uintptr_t maxCount = 65535; // 2^16 - 1
    };
    static_assert((AutoreleasePoolEntry){ .ptr = OBJC_VM_MAX_ADDRESS }.ptr == OBJC_VM_MAX_ADDRESS, "OBJC_VM_MAX_ADDRESS doesn't fit into AutoreleasePoolEntry::ptr!");
#endif

	magic_t const magic;
	__unsafe_unretained id *next;
	objc_thread_t const thread;
	AutoreleasePoolPage * const parent;
	AutoreleasePoolPage *child;
	uint32_t const depth;
	uint32_t hiwat;

	AutoreleasePoolPageData(__unsafe_unretained id* _next, objc_thread_t _thread, AutoreleasePoolPage* _parent, uint32_t _depth, uint32_t _hiwat)
		: magic(), next(_next), thread(_thread),
		  parent(_parent), child(nil),
		  depth(_depth), hiwat(_hiwat)
	{
	}
};

#undef C_ASSERT

#endif
#endif
