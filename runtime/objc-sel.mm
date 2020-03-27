/*
 * Copyright (c) 2012 Apple Inc.  All Rights Reserved.
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

#if __OBJC2__

#include "objc-private.h"
#include "objc-cache.h"
#include "DenseMapExtras.h"

#if SUPPORT_PREOPT
static const objc_selopt_t *builtins = NULL;
static bool useDyldSelectorLookup = false;
#endif


static objc::ExplicitInitDenseSet<const char *> namedSelectors;
static SEL search_builtins(const char *key);


/***********************************************************************
* sel_init
* Initialize selector tables and register selectors used internally.
**********************************************************************/
void sel_init(size_t selrefCount)
{
#if SUPPORT_PREOPT
    // If dyld finds a known shared cache selector, then it must be also looking
    // in the shared cache table.
    if (_dyld_get_objc_selector("retain") != nil)
        useDyldSelectorLookup = true;
    else
        builtins = preoptimizedSelectors();

    if (PrintPreopt && useDyldSelectorLookup) {
        _objc_inform("PREOPTIMIZATION: using dyld selector opt");
    }

    if (PrintPreopt  &&  builtins) {
        uint32_t occupied = builtins->occupied;
        uint32_t capacity = builtins->capacity;
        
        _objc_inform("PREOPTIMIZATION: using selopt at %p", builtins);
        _objc_inform("PREOPTIMIZATION: %u selectors", occupied);
        _objc_inform("PREOPTIMIZATION: %u/%u (%u%%) hash table occupancy",
                     occupied, capacity,
                     (unsigned)(occupied/(double)capacity*100));
    }
	namedSelectors.init(useDyldSelectorLookup ? 0 : (unsigned)selrefCount);
#else
	namedSelectors.init((unsigned)selrefCount);
#endif

    // Register selectors used by libobjc

    mutex_locker_t lock(selLock);

    SEL_cxx_construct = sel_registerNameNoLock(".cxx_construct", NO);
    SEL_cxx_destruct = sel_registerNameNoLock(".cxx_destruct", NO);
}


static SEL sel_alloc(const char *name, bool copy)
{
    selLock.assertLocked();
    return (SEL)(copy ? strdupIfMutable(name) : name);    
}


const char *sel_getName(SEL sel) 
{
    if (!sel) return "<null selector>";
    return (const char *)(const void*)sel;
}


BOOL sel_isMapped(SEL sel) 
{
    if (!sel) return NO;

    const char *name = (const char *)(void *)sel;

    if (sel == search_builtins(name)) return YES;

    mutex_locker_t lock(selLock);
    auto it = namedSelectors.get().find(name);
    return it != namedSelectors.get().end() && (SEL)*it == sel;
}


static SEL search_builtins(const char *name) 
{
#if SUPPORT_PREOPT
  if (builtins) {
      SEL result = 0;
      if ((result = (SEL)builtins->get(name)))
          return result;

      if ((result = (SEL)_dyld_get_objc_selector(name)))
          return result;
  } else if (useDyldSelectorLookup) {
      if (SEL result = (SEL)_dyld_get_objc_selector(name))
          return result;
  }
#endif
    return nil;
}


static SEL __sel_registerName(const char *name, bool shouldLock, bool copy) 
{
    SEL result = 0;

    if (shouldLock) selLock.assertUnlocked();
    else selLock.assertLocked();

    if (!name) return (SEL)0;

    result = search_builtins(name);
    if (result) return result;
    
    conditional_mutex_locker_t lock(selLock, shouldLock);
	auto it = namedSelectors.get().insert(name);
	if (it.second) {
		// No match. Insert.
		*it.first = (const char *)sel_alloc(name, copy);
	}
	return (SEL)*it.first;
}


SEL sel_registerName(const char *name) {
    return __sel_registerName(name, 1, 1);     // YES lock, YES copy
}

SEL sel_registerNameNoLock(const char *name, bool copy) {
    return __sel_registerName(name, 0, copy);  // NO lock, maybe copy
}


// 2001/1/24
// the majority of uses of this function (which used to return NULL if not found)
// did not check for NULL, so, in fact, never return NULL
//
SEL sel_getUid(const char *name) {
    return __sel_registerName(name, 2, 1);  // YES lock, YES copy
}


BOOL sel_isEqual(SEL lhs, SEL rhs)
{
    return bool(lhs == rhs);
}


#endif
