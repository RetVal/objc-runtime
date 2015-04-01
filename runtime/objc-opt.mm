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

/*
  objc-opt.mm
  Management of optimizations in the dyld shared cache 
*/

#include "objc.h"
#include "objc-private.h"

using namespace objc_opt;


#if !SUPPORT_PREOPT
// Preoptimization not supported on this platform.

bool isPreoptimized(void) 
{
    return false;
}

const objc_selopt_t *preoptimizedSelectors(void) 
{
    return NULL;
}

struct class_t * getPreoptimizedClass(const char *name)
{
    return NULL;
}

header_info *preoptimizedHinfoForHeader(const headerType *mhdr)
{
    return NULL;
}

void preopt_init(void)
{
    disableSharedCacheOptimizations();
    
    if (PrintPreopt) {
        _objc_inform("PREOPTIMIZATION: is DISABLED "
                     "(not supported on ths platform)");
    }
}


// !SUPPORT_PREOPT
#else
// SUPPORT_PREOPT


#include <objc-shared-cache.h>

__BEGIN_DECLS

// preopt: the actual opt used at runtime
// _objc_opt_data: opt data possibly written by dyld
// empty_opt_data: empty data to use if dyld didn't cooperate or DisablePreopt

static const objc_opt_t *opt = NULL;
static bool preoptimized;

extern const objc_opt_t _objc_opt_data;  // in __TEXT, __objc_opt_ro
static const uint32_t empty_opt_data[] = OPT_INITIALIZER;

bool isPreoptimized(void) 
{
    return preoptimized;
}


const objc_selopt_t *preoptimizedSelectors(void) 
{
    assert(opt);
    return opt->selopt();
}

struct class_t * getPreoptimizedClass(const char *name)
{
    assert(opt);
    objc_clsopt_t *classes = opt->clsopt();
    if (!classes) return NULL;

    void *cls;
    void *hi;
    uint32_t count = classes->getClassAndHeader(name, cls, hi);
    if (count == 1  &&  ((header_info *)hi)->loaded) {
        // exactly one matching class, and it's image is loaded
        return (struct class_t *)cls;
    } 
    if (count == 2) {
        // more than one matching class - find one that is loaded
        void *clslist[count];
        void *hilist[count];
        classes->getClassesAndHeaders(name, clslist, hilist);
        for (uint32_t i = 0; i < count; i++) {
            if (((header_info *)hilist[i])->loaded) {
                return (struct class_t *)clslist[i];
            }
        }
    }

    // no match that is loaded
    return NULL;
}

namespace objc_opt {
struct objc_headeropt_t {
    uint32_t count;
    uint32_t entsize;
    header_info headers[0];  // sorted by mhdr address

    header_info *get(const headerType *mhdr) 
    {
        assert(entsize == sizeof(header_info));

        int32_t start = 0;
        int32_t end = count;
        while (start <= end) {
            int32_t i = (start+end)/2;
            header_info *hi = headers+i;
            if (mhdr == hi->mhdr) return hi;
            else if (mhdr < hi->mhdr) end = i-1;
            else start = i+1;
        }

#if !NDEBUG
        for (uint32_t i = 0; i < count; i++) {
            header_info *hi = headers+i;
            if (mhdr == hi->mhdr) {
                _objc_fatal("failed to find header %p (%d/%d)", 
                            mhdr, i, count);
            }
        }
#endif

        return NULL;
    }
};
};


header_info *preoptimizedHinfoForHeader(const headerType *mhdr)
{
    assert(opt);
    objc_headeropt_t *hinfos = opt->headeropt();
    if (hinfos) return hinfos->get(mhdr);
    else return NULL;
}


void preopt_init(void)
{
    // `opt` not set at compile time in order to detect too-early usage
    const char *failure = NULL;
    opt = &_objc_opt_data;

    if (DisablePreopt) {
        // OBJC_DISABLE_PREOPTIMIZATION is set
        // If opt->version != VERSION then you continue at your own risk.
        failure = "(by OBJC_DISABLE_PREOPTIMIZATION)";
    } 
    else if (opt->version != objc_opt::VERSION) {
        // This shouldn't happen. You probably forgot to 
        // change OPT_INITIALIZER and objc-sel-table.s.
        // If dyld really did write the wrong optimization version, 
        // then we must halt because we don't know what bits dyld twiddled.
        _objc_fatal("bad objc preopt version (want %d, got %d)", 
                    objc_opt::VERSION, opt->version);
    }
    else if (!opt->selopt()  ||  !opt->headeropt()) {
        // One of the tables is missing. 
        failure = "(dyld shared cache is absent or out of date)";
    }
#if SUPPORT_IGNORED_SELECTOR_CONSTANT
    else if (UseGC) {
        // GC is on, which renames some selectors
        // Non-selector optimizations are still valid, but we don't have
        // any of those yet
        failure = "(GC is on)";
    }
#endif

    if (failure) {
        // All preoptimized selector references are invalid.
        preoptimized = NO;
        opt = (objc_opt_t *)empty_opt_data;
        disableSharedCacheOptimizations();

        if (PrintPreopt) {
            _objc_inform("PREOPTIMIZATION: is DISABLED %s", failure);
        }
    }
    else {
        // Valid optimization data written by dyld shared cache
        preoptimized = YES;

        if (PrintPreopt) {
            _objc_inform("PREOPTIMIZATION: is ENABLED "
                         "(version %d)", opt->version);
        }
    }
}


__END_DECLS

// SUPPORT_PREOPT
#endif
