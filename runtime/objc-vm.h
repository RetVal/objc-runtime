/*
 * Copyright (c) 2022 Apple Inc.  All Rights Reserved.
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

#ifndef _OBJC_VM_H
#define _OBJC_VM_H

/* 
 * WARNING  DANGER  HAZARD  BEWARE  EEK
 * 
 * Everything in this file is for Apple Internal use only.
 * These will change in arbitrary OS updates and in unpredictable ways.
 * When your program breaks, you get to keep both pieces.
 */

/*
 * objc-vm.h: defines PAGE_SIZE, PAGE_MIN/MAX_SIZE and PAGE_MAX_SHIFT
 */

// N.B. This file must be usable FROM ASSEMBLY SOURCE FILES

#include <TargetConditionals.h>

#if __has_include(<mach/vm_param.h>)
#  include <mach/vm_param.h>

#  define OBJC_VM_MAX_ADDRESS    MACH_VM_MAX_ADDRESS
#elif __arm64__
#  define PAGE_SIZE       16384
#  define PAGE_MIN_SIZE   16384
#  define PAGE_MAX_SIZE   16384
#  define PAGE_MAX_SHIFT  14
#if TARGET_OS_EXCLAVEKIT
#  define OBJC_VM_MAX_ADDRESS  0x0000001ffffffff8ULL
#else
#  define OBJC_VM_MAX_ADDRESS  0x00007ffffffffff8ULL
#endif
#else
#  error Unknown platform - please define PAGE_SIZE et al.
#endif

#endif // _OBJC_VM_H
