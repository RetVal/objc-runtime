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

/***********************************************************************
* threading.h
* Threading support
**********************************************************************/

#ifndef _OBJC_THREADING_H
#define _OBJC_THREADING_H

// TLS key identifiers
enum class tls_key {
    main                       = 0,
    sync_data                  = 1,
    sync_count                 = 2,
    autorelease_pool           = 3,
#if SUPPORT_RETURN_AUTORELEASE
    return_autorelease_object  = 4,
    return_autorelease_address = 5
#endif
};

#if OBJC_THREADING_PACKAGE == OBJC_THREADING_NONE
#include "nothreads.h"
#elif OBJC_THREADING_PACKAGE == OBJC_THREADING_DARWIN
#include "darwin.h"
#elif OBJC_THREADING_PACKAGE == OBJC_THREADING_PTHREADS
#include "pthreads.h"
#elif OBJC_THREADING_PACKAGE == OBJC_THREADING_C11THREADS
#include "c11threads.h"
#else
#error No threading package selected in objc-config.h
#endif

#include "mixins.h"
#include "lockdebug.h"
#include "tls.h"

using objc_lock_t = locker_mixin<lockdebug::lock_mixin<objc_lock_base_t>>;
using objc_recursive_lock_t =
    locker_mixin<lockdebug::lock_mixin<objc_recursive_lock_base_t>>;
using objc_nodebug_lock_t = locker_mixin<objc_lock_base_t>;

#endif // _OBJC_THREADING_H
