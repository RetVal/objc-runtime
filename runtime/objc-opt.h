/*
 * Copyright (c) 2023 Apple Inc.  All Rights Reserved.
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
  objc-opt.h
  Management of optimizations in the dyld shared cache
*/

#ifndef _OBJC_OPT_H
#define _OBJC_OPT_H

#include <stdint.h>

typedef struct header_info_rw {

    bool getLoaded() const {
        return isLoaded;
    }

    void setLoaded(bool v) {
        isLoaded = v ? 1: 0;
    }

    struct header_info *getNext() const {
        return (struct header_info *)(next << 2);
    }

    void setNext(struct header_info *v) {
        next = ((uintptr_t)v) >> 2;
    }

private:
#ifdef __LP64__
    uintptr_t isLoaded                : 1;
    [[maybe_unused]] uintptr_t unused : 1;
    uintptr_t next                    : 62;
#else
    uintptr_t isLoaded                : 1;
    [[maybe_unused]] uintptr_t unused : 1;
    uintptr_t next                    : 30;
#endif
} header_info_rw;

struct objc_headeropt_rw_t {
    uint32_t count;
    uint32_t entsize;
    header_info_rw headers[0];  // sorted by mhdr address
};

#endif // _OBJC_OPT_H
