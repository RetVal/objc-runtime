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

#include "objc-opt.h"
#include "objc-private.h"
#include "objc-os.h"
#include "objc-file.h"

struct objc_headeropt_ro_t {
    uint32_t count;
    uint32_t entsize;
    header_info headers[0];  // sorted by mhdr address

    header_info& getOrEnd(uint32_t i) const {
        ASSERT(i <= count);
        return *(header_info *)((uint8_t *)&headers + (i * entsize));
    }

    header_info& get(uint32_t i) const {
        ASSERT(i < count);
        return *(header_info *)((uint8_t *)&headers + (i * entsize));
    }

    uint32_t index(const header_info* hi) const {
        const header_info* begin = &get((uint32_t)0);
        const header_info* end = &getOrEnd(count);
        ASSERT(hi >= begin && hi < end);
        return (uint32_t)(((uintptr_t)hi - (uintptr_t)begin) / entsize);
    }

    header_info *get(const headerType *mhdr) const
    {
        int32_t start = 0;
        int32_t end = count;
        while (start <= end) {
            int32_t i = (start+end)/2;
            header_info &hi = get(i);
            if (mhdr == hi.mhdr()) return &hi;
            else if (mhdr < hi.mhdr()) end = i-1;
            else start = i+1;
        }

#if DEBUG
        for (uint32_t i = 0; i < count; i++) {
            header_info &hi = get(i);
            if (mhdr == hi.mhdr()) {
                _objc_fatal("failed to find header %p (%d/%d)",
                            mhdr, i, count);
            }
        }
#endif

        return nil;
    }
};

static const objc_headeropt_ro_t *headerInfoROs;
objc_headeropt_rw_t *objc_debug_headerInfoRWs;

SEL *header_info::selrefs(size_t *outCount) const
{
    _dyld_section_location_info_t info = dyldInfo();
    return getSectionData<SEL>(mhdr(), info, _dyld_section_location_data_sel_refs, outCount);
}

message_ref_t *header_info::messagerefs(size_t *outCount) const
{
    _dyld_section_location_info_t info = dyldInfo();
    return getSectionData<message_ref_t>(mhdr(), info, _dyld_section_location_data_msg_refs, outCount);
}

Class* header_info::classrefs(size_t *outCount) const
{
    _dyld_section_location_info_t info = dyldInfo();
    return getSectionData<Class>(mhdr(), info, _dyld_section_location_data_class_refs, outCount);
}

Class* header_info::superrefs(size_t *outCount) const
{
    _dyld_section_location_info_t info = dyldInfo();
    return getSectionData<Class>(mhdr(), info, _dyld_section_location_data_super_refs, outCount);
}

protocol_t ** header_info::protocolrefs(size_t *outCount) const
{
    _dyld_section_location_info_t info = dyldInfo();
    return getSectionData<protocol_t *>(mhdr(), info, _dyld_section_location_data_protocol_refs, outCount);
}

classref_t const *header_info::classlist(size_t *outCount) const
{
    _dyld_section_location_info_t info = dyldInfo();
    return getSectionData<classref_t>(mhdr(), info, _dyld_section_location_data_class_list, outCount);
}

const classref_t *header_info::nlclslist(size_t *outCount) const
{
    _dyld_section_location_info_t info = dyldInfo();
    return getSectionData<classref_t>(mhdr(), info, _dyld_section_location_data_non_lazy_class_list, outCount);
}

stub_class_t * const *header_info::stublist(size_t *outCount) const
{
    _dyld_section_location_info_t info = dyldInfo();
    return getSectionData<stub_class_t *>(mhdr(), info, _dyld_section_location_data_stub_list, outCount);
}

category_t * const *header_info::catlist(size_t *outCount) const
{
    _dyld_section_location_info_t info = dyldInfo();
    return getSectionData<category_t *>(mhdr(), info, _dyld_section_location_data_category_list, outCount);
}

category_t * const *header_info::catlist2(size_t *outCount) const
{
    _dyld_section_location_info_t info = dyldInfo();
    return getSectionData<category_t *>(mhdr(), info, _dyld_section_location_data_category_list2, outCount);
}

category_t * const *header_info::nlcatlist(size_t *outCount) const
{
    _dyld_section_location_info_t info = dyldInfo();
    return getSectionData<category_t *>(mhdr(), info, _dyld_section_location_data_non_lazy_category_list, outCount);
}

protocol_t * const *header_info::protocollist(size_t *outCount) const
{
    _dyld_section_location_info_t info = dyldInfo();
    return getSectionData<protocol_t *>(mhdr(), info, _dyld_section_location_data_protocol_list, outCount);
}

bool header_info::hasForkOkSection() const
{
    _dyld_section_location_info_t info = dyldInfo();
    size_t unusedOutCount;
    return getSectionData<uint8_t>(mhdr(), info, _dyld_section_location_data_objc_fork_ok, &unusedOutCount) != NULL;
}

bool header_info::hasRawISASection() const
{
    _dyld_section_location_info_t info = dyldInfo();
    size_t unusedOutCount;
    return getSectionData<uint8_t>(mhdr(), info, _dyld_section_location_data_raw_isa, &unusedOutCount) != NULL;
}

objc_image_info *
_getObjcImageInfo(const headerType *mhdr, _dyld_section_location_info_t info, size_t *outBytes)
{
    return getSectionData<objc_image_info>(mhdr, info, _dyld_section_location_objc_image_info, outBytes);
}

#if !SUPPORT_PREOPT
// Preoptimization not supported on this platform.

bool isPreoptimized(void)
{
    return false;
}

bool noMissingWeakSuperclasses(void) 
{
    return false;
}

bool header_info::isPreoptimized() const
{
    return false;
}

Protocol *getPreoptimizedProtocol(const char *name)
{
    return nil;
}

unsigned int getPreoptimizedClassUnreasonableCount()
{
    return 0;
}

Class getPreoptimizedClass(const char *name)
{
    return nil;
}

Class getPreoptimizedClassesWithMetaClass(Class metacls)
{
    return nil;
}

header_info *preoptimizedHinfoForHeader(const headerType *mhdr)
{
    return nil;
}

header_info_rw *getPreoptimizedHeaderRW(const struct header_info *const hdr)
{
    return nil;
}

void preopt_init(void)
{
    disableSharedCacheProtocolOptimizations();

    if (PrintPreopt) {
        _objc_inform("PREOPTIMIZATION: is DISABLED "
                     "(not supported on ths platform)");
    }
}


// !SUPPORT_PREOPT
#else
// SUPPORT_PREOPT

#include <objc-shared-cache.h>

using objc_opt::objc_opt_t;

__BEGIN_DECLS

// preopt: the actual opt used at runtime (nil or &_objc_opt_data)
// _objc_opt_data: opt data possibly written by dyld
// opt is initialized to ~0 to detect incorrect use before preopt_init()

static const objc_opt_t *opt = (objc_opt_t *)~0;
static bool preoptimized;

extern const objc_opt_t _objc_opt_data;  // in __TEXT, __objc_opt_ro

/***********************************************************************
* Return YES if we have a valid optimized shared cache.
**********************************************************************/
bool isPreoptimized(void) 
{
    return preoptimized;
}


/***********************************************************************
* Return YES if the shared cache does not have any classes with 
* missing weak superclasses.
**********************************************************************/
bool noMissingWeakSuperclasses(void)
{
    if (!preoptimized) return NO;  // might have missing weak superclasses
    return opt->flags & objc_opt::NoMissingWeakSuperclasses;
}


/***********************************************************************
* Return YES if this image's dyld shared cache optimizations are valid.
**********************************************************************/
bool header_info::isPreoptimized() const
{
    // preoptimization disabled for some reason
    if (!preoptimized) return NO;

    // image not from shared cache, or not fixed inside shared cache
    if (!info()->optimizedByDyld()) return NO;

    return YES;
}

Protocol *getSharedCachePreoptimizedProtocol(const char *name)
{
    // Don't ask dyld for protocols when preoptimization is off or there's a
    // libobjc root. Canonical protocols in the shared cache are not fixed up
    // for a libobjc root and still point to the shared cache's copy of the
    // Protocol class, so they can't be used.
    if (DisablePreopt || !isPreoptimized()) return nil;

    Protocol *result = nil;
    // Note, we have to pass the lambda directly here as otherwise we would try
    // message copy and autorelease.
    _dyld_for_each_objc_protocol(name, [&result](void* protocolPtr, bool isLoaded, bool* stop) {
        if (!isLoaded)
            return;

        if (!objc::inSharedCache((uintptr_t)protocolPtr))
            return;

        // Found a loaded image with this class name, so stop the search
        result = (Protocol *)protocolPtr;
        *stop = true;
    });
    return result;
}


Protocol *getPreoptimizedProtocol(const char *name)
{
    // Don't ask dyld for protocols when preoptimization is off or there's a
    // libobjc root. Canonical protocols in the shared cache are not fixed up
    // for a libobjc root and still point to the shared cache's copy of the
    // Protocol class, so they can't be used.
    if (DisablePreopt || !isPreoptimized()) return nil;

    Protocol *result = nil;
    // Note, we have to pass the lambda directly here as otherwise we would try
    // message copy and autorelease.
    _dyld_for_each_objc_protocol(name, [&result](void* protocolPtr, bool isLoaded, bool* stop) {
        // Skip images which aren't loaded.  This supports the case where dyld
        // might soft link an image from the main binary so its possibly not
        // loaded yet.
        if (!isLoaded)
            return;

        // Found a loaded image with this class name, so stop the search
        result = (Protocol *)protocolPtr;
        *stop = true;
    });
    return result;
}


unsigned int getPreoptimizedClassUnreasonableCount()
{
    // Even if this is a root of libobjc, we'll ask dyld for classes.
    // Unless explicitly told to disable the optimization
    if (DisablePreopt) return 0;

    return _dyld_objc_class_count();
}


Class getPreoptimizedClass(const char *name)
{
    // When preoptimization is off, we'll read classes manually, so don't
    // consult dyld.
    if (DisablePreopt || !isPreoptimized())
        return nullptr;

    Class result = nil;
    // Note, we have to pass the lambda directly here as otherwise we would try
    // message copy and autorelease.
    _dyld_for_each_objc_class(name, [&result](void* classPtr, bool isLoaded, bool* stop) {
        // Skip images which aren't loaded.  This supports the case where dyld
        // might soft link an image from the main binary so its possibly not
        // loaded yet.
        if (!isLoaded)
            return;

        // Found a loaded image with this class name, so stop the search
        result = (Class)classPtr;
        *stop = true;
    });
    return result;
}

Class getPreoptimizedClassesWithMetaClass(Class metacls)
{
    // When preoptimization is off, we'll read classes manually, so don't
    // consult dyld.
    if (DisablePreopt || !isPreoptimized())
        return nullptr;

    Class cls = nil;
    // Note, we have to pass the lambda directly here as otherwise we would try
    // message copy and autorelease.
    _dyld_for_each_objc_class(metacls->mangledName(),
                              [&cls, metacls](void* classPtr, bool isLoaded, bool* stop) {
        // Skip images which aren't loaded.  This supports the case where dyld
        // might soft link an image from the main binary so its possibly not
        // loaded yet.
        if (!isLoaded)
            return;

        // Found a loaded image with this class name, so check if its the right one
        Class result = (Class)classPtr;
        if (result->ISA() == metacls) {
            cls = result;
            *stop = true;
        }
    });

    return cls;
}


header_info *preoptimizedHinfoForHeader(const headerType *mhdr)
{
    if (headerInfoROs) return headerInfoROs->get(mhdr);
    else return nil;
}


header_info_rw *getPreoptimizedHeaderRW(const struct header_info *const hdr)
{
    if (!hdr->info()->optimizedByDyld())
        return nullptr;
    if (!headerInfoROs || !objc_debug_headerInfoRWs)
        return nullptr;

    int32_t index = headerInfoROs->index(hdr);
    ASSERT(objc_debug_headerInfoRWs->entsize == sizeof(header_info_rw));
    return &objc_debug_headerInfoRWs->headers[index];
}

bool hasSharedCacheDyldInfo()
{
    return headerInfoROs->entsize >= (3 * sizeof(intptr_t));
}


void preopt_init(void)
{
    // Get the memory region occupied by the shared cache.
    size_t length;
    const uintptr_t start = (uintptr_t)_dyld_get_shared_cache_range(&length);

    if (start) {
        objc::dataSegmentsRanges.setSharedCacheRange(start, start + length);
    }

    headerInfoROs = (const objc_headeropt_ro_t *)_dyld_for_objc_header_opt_ro();
    objc_debug_headerInfoRWs = (objc_headeropt_rw_t *)_dyld_for_objc_header_opt_rw();

    // `opt` not set at compile time in order to detect too-early usage
    const char *failure = nil;
    opt = &_objc_opt_data;

    if (DisablePreopt) {
        // OBJC_DISABLE_PREOPTIMIZATION is set
        // If opt->version != VERSION then you continue at your own risk.
        failure = "(by OBJC_DISABLE_PREOPTIMIZATION)";
    }
    else if (opt->version != 16) {
        // This shouldn't happen. You probably forgot to edit objc-sel-table.s.
        // If dyld really did write the wrong optimization version,
        // then we must halt because we don't know what bits dyld twiddled.
        _objc_fatal("bad objc preopt version (want %d, got %d)",
                    objc_opt::VERSION, opt->version);
    }
    else if (!headerInfoROs) {
        // One of the tables is missing.
        failure = "(dyld shared cache is absent or out of date)";
    }
    else if (!objc::dataSegmentsRanges.inSharedCache((uintptr_t)&_objc_empty_cache)) {
        failure = "libobjc is not in the shared cache";
    }

    if (failure) {
        // All preoptimized selector references are invalid.
        preoptimized = NO;
        opt = nil;
        disableSharedCacheProtocolOptimizations();

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
