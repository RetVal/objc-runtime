/*
 * Copyright (c) 2017 Apple Inc.  All Rights Reserved.
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

#ifndef _OBJC_PTRAUTH_H_
#define _OBJC_PTRAUTH_H_

#include <objc/objc.h>

// On some architectures, method lists and method caches store signed IMPs.

// fixme simply include ptrauth.h once all build trains have it
#if __has_include (<ptrauth.h>)
#include <ptrauth.h>
#else
#define ptrauth_strip(__value, __key) __value
#define ptrauth_blend_discriminator(__pointer, __integer) ((uintptr_t)0)
#define ptrauth_sign_constant(__value, __key, __data) __value
#define ptrauth_sign_unauthenticated(__value, __key, __data) __value
#define ptrauth_auth_and_resign(__value, __old_key, __old_data, __new_key, __new_data) __value
#define ptrauth_auth_function(__value, __old_key, __old_data) __value
#define ptrauth_auth_data(__value, __old_key, __old_data) __value
#define ptrauth_string_discriminator(__string) ((int)0)
#define ptrauth_sign_generic_data(__value, __data) ((ptrauth_generic_signature_t)0)

#define __ptrauth_function_pointer
#define __ptrauth_return_address
#define __ptrauth_block_invocation_pointer
#define __ptrauth_block_copy_helper
#define __ptrauth_block_destroy_helper
#define __ptrauth_block_byref_copy_helper
#define __ptrauth_block_byref_destroy_helper
#define __ptrauth_objc_method_list_imp
#define __ptrauth_cxx_vtable_pointer
#define __ptrauth_cxx_vtt_vtable_pointer
#define __ptrauth_swift_heap_object_destructor
#define __ptrauth_cxx_virtual_function_pointer(__declkey)
#define __ptrauth_swift_function_pointer(__typekey)
#define __ptrauth_swift_class_method_pointer(__declkey)
#define __ptrauth_swift_protocol_witness_function_pointer(__declkey)
#define __ptrauth_swift_value_witness_function_pointer(__key)
#endif


#if __has_feature(ptrauth_calls)

#if !__arm64__
#error ptrauth other than arm64e is unimplemented
#endif

// Method lists use process-independent signature for compatibility.
using MethodListIMP = IMP __ptrauth_objc_method_list_imp;

#else

using MethodListIMP = IMP;

#endif

// _OBJC_PTRAUTH_H_
#endif
