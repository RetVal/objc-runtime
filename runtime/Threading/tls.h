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
* tls.h
* Thread local storage
**********************************************************************/

#ifndef _OBJC_TLS_H
#define _OBJC_TLS_H

/* This file defines some types and macros for implementing tls.

   Specifically:

      tls_fast(T)            aVar; // Fast, simple TLS (no destructor)
      tls(T)                 bVar; // Simple TLS
      tls(T, dtor)           cVar; // Simple TLS with destructor
      tls_direct(T, K)       dVar; // Direct TLS if supported, otherwise simple
      tls_direct(T, K, dtor) eVar; // Direct TLS with destructor

   tls_fast(T) will use compiler supported thread_local if available,
   and will fall back to simple TLS if it isn't available.  This is
   typically the fastest unless direct TLS keys are supported, in which
   case tls_direct(T, K) will be faster.

   There is also

      tls_autoptr(T) aPtr; // Points to an automatically managed instance of T
      tls_autoptr_direct(T, K) bPtr; // As above, using direct TLS if supported

   Again, the direct version falls back to the regular version if direct
   TLS isn't supported.

*/

template <class T, typename Destructor=void>
using tls_impl = getter_setter<objc_tls_base<T, Destructor> >;

// If the system supports direct thread keys, tls_direct(T, Key) will use
// them; otherwise it will fall back to tls(T).
#if SUPPORT_DIRECT_THREAD_KEYS
template <class T, tls_key Key, typename Destructor=void>
using tls_direct_impl = getter_setter<objc_tls_direct_base<T, Key, Destructor> >;
#define tls_direct(T,K,...) tls_direct_impl<T,K __VA_OPT__(,) __VA_ARGS__>
#else
template <class T, tls_key Key, typename Destructor=void>
using tls_direct_impl = getter_setter<objc_tls_base<T, Destructor> >;
#define tls_direct(T,K,...) tls_impl<T __VA_OPT__(,) __VA_ARGS__>
#endif

// If the compiler supports thread_local, tls_fast(T) will use it, otherwise
// it will fall back to tls_impl<T>.  Note that this means it can only be used
// for things up to the size of a void*.
#if SUPPORT_THREAD_LOCAL
#define tls_fast(T) thread_local T
#else
#define tls_fast(T) tls_impl<T>
#endif

// tls_direct_fast(T, Key) is like tls_direct() but doesn't support
// destructors, so can fall back to compiler TLS support.
#if SUPPORT_DIRECT_THREAD_KEYS
#define tls_direct_fast(T,K) tls_direct_impl<T, K>
#elif SUPPORT_THREAD_LOCAL
#define tls_direct_fast(T,K) thread_local T
#else
#define tls_direct_fast(T,K) tls_impl<T>
#endif

// Finally, tls(T) is the fallback implementation
#define tls(T,...) tls_impl<T __VA_OPT__(,) __VA_ARGS__>

// A "pointer" to an automatically managed, lazily created, instance of T
#define tls_autoptr(T)  tls_autoptr_impl<T>

// If the system supports direct thread keys, tls_autoptr_direct(T, Key) will
// use them, otherwise it will fall back to tls_autoptr(T)
#if SUPPORT_DIRECT_THREAD_KEYS
#define tls_autoptr_direct(T,K) tls_autoptr_direct_impl<T, K>
#else
#define tls_autoptr_direct(T,K) tls_autoptr_impl<T>
#endif

#endif // _OBJC_TLS_H
