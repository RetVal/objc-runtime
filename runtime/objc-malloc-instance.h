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

#ifndef _OBJC_MALLOC_INSTANCE_H
#define _OBJC_MALLOC_INSTANCE_H

#include <cstdlib>
#if _MALLOC_TYPE_ENABLED
# include <malloc_type_private.h>
#endif

namespace objc {

static inline id
malloc_instance(size_t size, Class cls __unused)
{
#if _MALLOC_TYPE_ENABLED
    malloc_type_descriptor_t desc = {};
    desc.summary.type_kind = MALLOC_TYPE_KIND_OBJC;
    return (id)malloc_type_calloc(1, size, desc.type_id);
#else
    return (id)calloc(1, size);
#endif
}

} // namespace objc

#endif // _OBJC_MALLOC_INSTANCE_H
