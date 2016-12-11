/*
 * Copyright (c) 2004-2007 Apple Inc. All rights reserved.
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

#include "objc-private.h"

// GC is no longer supported.

#if OBJC_NO_GC_API

// No GC and no GC symbols needed. We're done here.
# if SUPPORT_GC_COMPAT
#   error inconsistent config settings
# endif

#else

// No GC but we do need to export GC symbols.
// These are mostly the same as the OBJC_NO_GC inline versions in objc-auto.h.

# if !SUPPORT_GC_COMPAT
#   error inconsistent config settings
# endif

OBJC_EXPORT void objc_collect(unsigned long options __unused) { }
OBJC_EXPORT BOOL objc_collectingEnabled(void) { return NO; }
OBJC_EXPORT void objc_setCollectionThreshold(size_t threshold __unused) { }
OBJC_EXPORT void objc_setCollectionRatio(size_t ratio __unused) { }
OBJC_EXPORT void objc_startCollectorThread(void) { }

#if TARGET_OS_WIN32
OBJC_EXPORT BOOL objc_atomicCompareAndSwapPtr(id predicate, id replacement, volatile id *objectLocation) 
    { void *original = InterlockedCompareExchangePointer((void * volatile *)objectLocation, (void *)replacement, (void *)predicate); return (original == predicate); }

OBJC_EXPORT BOOL objc_atomicCompareAndSwapPtrBarrier(id predicate, id replacement, volatile id *objectLocation) 
    { void *original = InterlockedCompareExchangePointer((void * volatile *)objectLocation, (void *)replacement, (void *)predicate); return (original == predicate); }
#else
OBJC_EXPORT BOOL objc_atomicCompareAndSwapPtr(id predicate, id replacement, volatile id *objectLocation) 
    { return OSAtomicCompareAndSwapPtr((void *)predicate, (void *)replacement, (void * volatile *)objectLocation); }

OBJC_EXPORT BOOL objc_atomicCompareAndSwapPtrBarrier(id predicate, id replacement, volatile id *objectLocation) 
    { return OSAtomicCompareAndSwapPtrBarrier((void *)predicate, (void *)replacement, (void * volatile *)objectLocation); }
#endif

OBJC_EXPORT BOOL objc_atomicCompareAndSwapGlobal(id predicate, id replacement, volatile id *objectLocation) 
    { return objc_atomicCompareAndSwapPtr(predicate, replacement, objectLocation); }

OBJC_EXPORT BOOL objc_atomicCompareAndSwapGlobalBarrier(id predicate, id replacement, volatile id *objectLocation) 
    { return objc_atomicCompareAndSwapPtrBarrier(predicate, replacement, objectLocation); }

OBJC_EXPORT BOOL objc_atomicCompareAndSwapInstanceVariable(id predicate, id replacement, volatile id *objectLocation) 
    { return objc_atomicCompareAndSwapPtr(predicate, replacement, objectLocation); }

OBJC_EXPORT BOOL objc_atomicCompareAndSwapInstanceVariableBarrier(id predicate, id replacement, volatile id *objectLocation) 
    { return objc_atomicCompareAndSwapPtrBarrier(predicate, replacement, objectLocation); }

OBJC_EXPORT id objc_assign_strongCast(id val, id *dest) 
    { return (*dest = val); }

OBJC_EXPORT id objc_assign_global(id val, id *dest) 
    { return (*dest = val); }

OBJC_EXPORT id objc_assign_threadlocal(id val, id *dest)
    { return (*dest = val); }

OBJC_EXPORT id objc_assign_ivar(id val, id dest, ptrdiff_t offset) 
    { return (*(id*)((char *)dest+offset) = val); }

OBJC_EXPORT id objc_read_weak(id *location) 
    { return *location; }

OBJC_EXPORT id objc_assign_weak(id value, id *location) 
    { return (*location = value); }

OBJC_EXPORT void *objc_memmove_collectable(void *dst, const void *src, size_t size) 
    { return memmove(dst, src, size); }

OBJC_EXPORT void objc_finalizeOnMainThread(Class cls __unused) { }
OBJC_EXPORT BOOL objc_is_finalized(void *ptr __unused) { return NO; }
OBJC_EXPORT void objc_clear_stack(unsigned long options __unused) { }

OBJC_EXPORT BOOL objc_collecting_enabled(void) { return NO; }
OBJC_EXPORT void objc_set_collection_threshold(size_t threshold __unused) { } 
OBJC_EXPORT void objc_set_collection_ratio(size_t ratio __unused) { } 
OBJC_EXPORT void objc_start_collector_thread(void) { }

OBJC_EXPORT id objc_allocate_object(Class cls, int extra) 
    { return class_createInstance(cls, extra); }

OBJC_EXPORT void objc_registerThreadWithCollector() { }
OBJC_EXPORT void objc_unregisterThreadWithCollector() { }
OBJC_EXPORT void objc_assertRegisteredThreadWithCollector() { }

OBJC_EXPORT malloc_zone_t* objc_collect_init(int(*callback)() __unused) { return nil; }
OBJC_EXPORT void* objc_collectableZone() { return nil; }

OBJC_EXPORT BOOL objc_isAuto(id object __unused) { return NO; }
OBJC_EXPORT BOOL objc_dumpHeap(char *filename __unused, unsigned long length __unused)
    { return NO; }

// not OBJC_NO_GC_API
#endif
