/*
 * Copyright (c) 1999-2007 Apple Inc.  All Rights Reserved.
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
#include "objc-file.h"

#if TARGET_IPHONE_SIMULATOR
// getsectiondata() not yet available

// 1. Find segment with file offset == 0 and file size != 0. This segment's
//    contents span the Mach-O header. (File size of 0 is .bss, for example) 
// 2. Slide is header's address - segment's preferred address
static ptrdiff_t
objc_getImageSlide(const struct mach_header *header)
{
    unsigned long i;
    const struct segment_command *sgp = (const struct segment_command *)(header + 1);

    for (i = 0; i < header->ncmds; i++){
        if (sgp->cmd == LC_SEGMENT) {
            if (sgp->fileoff == 0  &&  sgp->filesize != 0) {
                return (uintptr_t)header - (uintptr_t)sgp->vmaddr;
            }
        }
        sgp = (const struct segment_command *)((char *)sgp + sgp->cmdsize);
    }

    // uh-oh
    _objc_fatal("could not calculate VM slide for image");
    return 0;  // not reached
}

uint8_t *
objc_getsectiondata(const struct mach_header *mh, const char *segname, const char *sectname, unsigned long *outSize)
{
    uint32_t size = 0;
    
    char *data = getsectdatafromheader(mh, segname, sectname, &size);
    if (data) {
        *outSize = size;
        return (uint8_t *)data + objc_getImageSlide(mh);
    } else {
        *outSize = 0;
        return NULL;
    }
}

static const struct segment_command *
objc_getsegbynamefromheader(const mach_header *head, const char *segname)
{
    const struct segment_command *sgp;
    unsigned long i;

    sgp = (const struct segment_command *) (head + 1);
    for (i = 0; i < head->ncmds; i++){
        if (sgp->cmd == LC_SEGMENT) {
            if (strncmp(sgp->segname, segname, sizeof(sgp->segname)) == 0) {
                return sgp;
            }
        }
        sgp = (const struct segment_command *)((char *)sgp + sgp->cmdsize);
    }
    return NULL;
}

uint8_t *
objc_getsegmentdata(const struct mach_header *mh, const char *segname, unsigned long *outSize)
{
    const struct segment_command *seg;
    
    seg = objc_getsegbynamefromheader(mh, segname);
    if (seg) {
        *outSize = seg->vmsize;
        return (uint8_t *)seg->vmaddr + objc_getImageSlide(mh);
    } else {
        *outSize = 0;
        return NULL;
    }
}

// TARGET_IPHONE_SIMULATOR
#endif

#define GETSECT(name, type, sectname)                                   \
    type *name(const header_info *hi, size_t *outCount)  \
    {                                                                   \
        unsigned long byteCount = 0;                                    \
        type *data = (type *)                                           \
            getsectiondata(hi->mhdr, SEG_DATA, sectname, &byteCount);   \
        *outCount = byteCount / sizeof(type);                           \
        return data;                                                    \
    }

//      function name                 content type     section name
GETSECT(_getObjc2SelectorRefs,        SEL,             "__objc_selrefs"); 
GETSECT(_getObjc2MessageRefs,         message_ref_t,   "__objc_msgrefs"); 
GETSECT(_getObjc2ClassRefs,           class_t *,       "__objc_classrefs");
GETSECT(_getObjc2SuperRefs,           class_t *,       "__objc_superrefs");
GETSECT(_getObjc2ClassList,           classref_t,       "__objc_classlist");
GETSECT(_getObjc2NonlazyClassList,    classref_t,       "__objc_nlclslist");
GETSECT(_getObjc2CategoryList,        category_t *,    "__objc_catlist");
GETSECT(_getObjc2NonlazyCategoryList, category_t *,    "__objc_nlcatlist");
GETSECT(_getObjc2ProtocolList,        protocol_t *,    "__objc_protolist");
GETSECT(_getObjc2ProtocolRefs,        protocol_t *,    "__objc_protorefs");


objc_image_info *
_getObjcImageInfo(const headerType *mhdr, size_t *outBytes)
{
    unsigned long byteCount = 0;
    objc_image_info *data = (objc_image_info *)
        getsectiondata(mhdr, SEG_DATA, "__objc_imageinfo", &byteCount);
    *outBytes = byteCount;
    return data;
}


static const segmentType *
getsegbynamefromheader(const headerType *head, const char *segname)
{
    const segmentType *sgp;
    unsigned long i;
    
    sgp = (const segmentType *) (head + 1);
    for (i = 0; i < head->ncmds; i++){
        if (sgp->cmd == SEGMENT_CMD) {
            if (strncmp(sgp->segname, segname, sizeof(sgp->segname)) == 0) {
                return sgp;
            }
        }
        sgp = (const segmentType *)((char *)sgp + sgp->cmdsize);
    }
    return NULL;
}

BOOL
_hasObjcContents(const header_info *hi)
{
    // Look for a __DATA,__objc* section other than __DATA,__objc_imageinfo
    const segmentType *seg = getsegbynamefromheader(hi->mhdr, "__DATA");
    if (!seg) return NO;

    const sectionType *sect;
    uint32_t i;
    for (i = 0; i < seg->nsects; i++) {
        sect = ((const sectionType *)(seg+1))+i;
        if (0 == strncmp(sect->sectname, "__objc_", 7)  &&  
            0 != strncmp(sect->sectname, "__objc_imageinfo", 16)) 
        {
            return YES;
        }
    }

    return NO;
}

#endif
