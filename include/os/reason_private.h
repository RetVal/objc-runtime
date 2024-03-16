/*
 * Copyright (c) 2017 Apple Inc. All rights reserved.
 *
 * @APPLE_OSREFERENCE_LICENSE_HEADER_START@
 *
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. The rights granted to you under the License
 * may not be used to create, or enable the creation or redistribution of,
 * unlawful or unlicensed copies of an Apple operating system, or to
 * circumvent, violate, or enable the circumvention or violation of, any
 * terms of an Apple operating system software license agreement.
 *
 * Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this file.
 *
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 *
 * @APPLE_OSREFERENCE_LICENSE_HEADER_END@
 */

#ifndef OS_REASON_PRIVATE_H
#define OS_REASON_PRIVATE_H

#include <sys/reason.h>
#include <os/base.h>

__BEGIN_DECLS

#ifndef KERNEL

/*
 * similar to abort_with_payload, but for faults.
 *
 * [EBUSY]   too many corpses are being generated at the moment
 * [EQFULL]  the process used all its user fault quota
 * [ENOTSUP] generating simulated abort with reason is disabled
 * [EPERM]   generating simulated abort with reason for this namespace is not turned on
 */
int
os_fault_with_payload(uint32_t reason_namespace, uint64_t reason_code,
    void *payload, uint32_t payload_size, const char *reason_string,
    uint64_t reason_flags) __attribute__((cold));

#endif // !KERNEL

/*
 * Codes in the OS_REASON_LIBSYSTEM namespace
 */

OS_ENUM(os_reason_libsystem_code, uint64_t,
    OS_REASON_LIBSYSTEM_CODE_WORKLOOP_OWNERSHIP_LEAK = 1,
    OS_REASON_LIBSYSTEM_CODE_FAULT = 2, /* generic fault with old-style os_log_fault payload */
    OS_REASON_LIBSYSTEM_CODE_SECINIT_INITIALIZER = 3,
    OS_REASON_LIBSYSTEM_CODE_PTHREAD_CORRUPTION = 4,
    OS_REASON_LIBSYSTEM_CODE_OS_LOG_FAULT = 5, /* generated _only_ by os_log_fault in libtrace */
    );

__END_DECLS

#endif // OS_REASON_PRIVATE_H
