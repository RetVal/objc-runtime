/*
 * Copyright (c) 2020 Apple Inc. All rights reserved.
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

#ifndef _OS_LOG_SIMPLE_PRIVATE_H_
#define _OS_LOG_SIMPLE_PRIVATE_H_

#include <os/log_simple_private_impl.h>
/**
 * These constants have the same value as os_log_type from os/log.h
 */
#define OS_LOG_SIMPLE_TYPE_DEFAULT 0x00
#define OS_LOG_SIMPLE_TYPE_INFO 0x01
#define OS_LOG_SIMPLE_TYPE_DEBUG 0x02
#define OS_LOG_SIMPLE_TYPE_ERROR 0x10

#define os_log_simple(fmt, ...)\
		os_log_simple_with_type(OS_LOG_SIMPLE_TYPE_DEFAULT, (fmt), ##__VA_ARGS__)

#define os_log_simple_error(fmt, ...)\
		os_log_simple_with_type(OS_LOG_SIMPLE_TYPE_ERROR, (fmt), ##__VA_ARGS__)

#define os_log_simple_with_type(type, fmt, ...)\
		os_log_simple_with_subsystem((type), NULL, (fmt), ##__VA_ARGS__)

#define os_log_simple_with_subsystem(type, subsystem, fmt, ...)\
		__os_log_simple_impl((type), (subsystem), (fmt), ##__VA_ARGS__)

#define os_log_simple_available() (&_os_log_simple != 0)

#endif /* _OS_LOG_SIMPLE_PRIVATE_H_ */
