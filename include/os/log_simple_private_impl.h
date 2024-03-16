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

#ifndef _OS_LOG_SIMPLE_PRIVATE_IMPL_H_
#define _OS_LOG_SIMPLE_PRIVATE_IMPL_H_

#include <mach-o/dyld_priv.h>
#include <stdint.h>
#include <_simple.h>
#include <uuid/uuid.h>
#include <Availability.h>
#include <sys/cdefs.h>

__BEGIN_DECLS

// Some clients of os_log_simple will also include os/log.h
// This declaration needs to be consistent with whatever libtrace is exporting
// in trace_base.h
extern struct mach_header __dso_handle;


#define LOG_SIMPLE_AVAILABILITY \
		__API_AVAILABLE(macos(12.0), ios(15.0), tvos(15.0), watchos(8.0))

LOG_SIMPLE_AVAILABILITY
uint64_t
os_log_simple_now(void);

// Helper routine to convert between legacy syslog ASL levels to
// os_log type constants
LOG_SIMPLE_AVAILABILITY
uint8_t
os_log_simple_type_from_asl(int level);

// libplatform isn't allowed to link libdyld, so clients of the os_log_simple
// interface should link libdyld and we call into the dyld routines in a macro
#define __os_log_simple_dyld(sender_mh, sender_uuid, dsc_uuid, dsc_load_addr_p) __extension__({\
	if (!_dyld_get_image_uuid(sender_mh, sender_uuid)) {\
		uuid_clear(sender_uuid);\
	}\
	if (!_dyld_get_shared_cache_uuid(dsc_uuid)) {\
		uuid_clear(dsc_uuid);\
	} else {\
		size_t _dsc_size;\
		*dsc_load_addr_p = (uintptr_t)_dyld_get_shared_cache_range(&_dsc_size);\
	}\
})

#define __os_log_simple_impl(type, subsystem, fmt, ...) __extension__({\
	uuid_t __sender_uuid;\
	uuid_t __dsc_uuid;\
	uintptr_t __dsc_load_addr = 0;\
	const struct mach_header *__sender_mh = &__dso_handle;\
	__os_log_simple_dyld(__sender_mh, __sender_uuid, __dsc_uuid, &__dsc_load_addr);\
	_os_log_simple(__sender_mh, __sender_uuid, __dsc_uuid, __dsc_load_addr, (type), (subsystem), (fmt), ##__VA_ARGS__);\
})

__printflike(7, 8)
LOG_SIMPLE_AVAILABILITY
void
_os_log_simple(const struct mach_header *sender_mh, uuid_t sender_uuid,
		uuid_t dsc_uuid, uintptr_t dsc_load_addr, uint8_t type,
		const char *subsystem, const char *fmt, ...);

#define _os_log_simple_offset(type, subsystem, offset, message) __extension__({\
	uuid_t __sender_uuid;\
	uuid_t __dsc_uuid;\
	uintptr_t __dsc_load_addr = 0;\
	const struct mach_header *__sender_mh = dyld_image_header_containing_address((void *)(uintptr_t)(offset));\
	__os_log_simple_dyld(__sender_mh, __sender_uuid, __dsc_uuid, &__dsc_load_addr);\
	__os_log_simple_offset(__sender_mh, __sender_uuid, __dsc_uuid, __dsc_load_addr, (uint64_t)(uintptr_t)(offset), (type), (subsystem), message);\
})

LOG_SIMPLE_AVAILABILITY
void
__os_log_simple_offset(const struct mach_header *sender_mh,
		const uuid_t sender_uuid, const uuid_t dsc_uuid,
		uintptr_t dsc_load_addr, uint64_t absolute_offset, uint8_t type,
		const char *subsystem, const char *message);

LOG_SIMPLE_AVAILABILITY
void
_os_log_simple_shim(uint8_t type, const char *subsystem, const char *message);

LOG_SIMPLE_AVAILABILITY
typedef struct {
	uint8_t type;
	const char *subsystem;
	const char *message;
	uint64_t timestamp;
	uint64_t pid;
	uint64_t unique_pid;
	uint64_t pid_version;
	uint64_t tid;
	uint64_t relative_offset;
	uuid_t sender_uuid;
	uuid_t process_uuid;
	uuid_t dsc_uuid;
} os_log_simple_payload_t;

LOG_SIMPLE_AVAILABILITY
int
_os_log_simple_send(os_log_simple_payload_t *payload);

// payload_out will contain pointers to content within buffer
LOG_SIMPLE_AVAILABILITY
int
_os_log_simple_parse(const char *buffer, size_t length, os_log_simple_payload_t *payload_out);

// SPI for launchd to retry connection to the socket after it sets it up
__API_AVAILABLE(macos(13.0), ios(16.0), tvos(16.0), watchos(9.0))
void
_os_log_simple_reinit_4launchd(void);

__END_DECLS

#endif // _OS_LOG_SIMPLE_PRIVATE_IMPL_H_
