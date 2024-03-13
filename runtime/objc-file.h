/*
 * Copyright (c) 2009 Apple Inc.  All Rights Reserved.
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

#ifndef _OBJC_FILE_NEW_H
#define _OBJC_FILE_NEW_H

#include "objc-runtime-new.h"

// classref_t is not fixed up at launch; use remapClass() to convert

// classlist and catlist and protolist sections are marked const here
// because those sections may be in read-only __DATA_CONST segments.

static inline void
foreach_data_segment(const headerType *mhdr,
                     std::function<void(const segmentType *, intptr_t slide)> code)
{
    intptr_t slide = 0;

    // compute VM slide
    const segmentType *seg = (const segmentType *) (mhdr + 1);
    for (unsigned long i = 0; i < mhdr->ncmds; i++) {
        if (seg->cmd == SEGMENT_CMD  &&
            segnameEquals(seg->segname, "__TEXT"))
        {
            slide = (char *)mhdr - (char *)seg->vmaddr;
            break;
        }
        seg = (const segmentType *)((char *)seg + seg->cmdsize);
    }

    // enumerate __DATA* and __AUTH* segments
    seg = (const segmentType *) (mhdr + 1);
    for (unsigned long i = 0; i < mhdr->ncmds; i++) {
        if (seg->cmd == SEGMENT_CMD  &&
            (segnameStartsWith(seg->segname, "__DATA") ||
             segnameStartsWith(seg->segname, "__AUTH")))
        {
            code(seg, slide);
        }
        seg = (const segmentType *)((char *)seg + seg->cmdsize);
    }
}

#endif
