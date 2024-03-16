/*
 * Copyright (c) 2010-2012 Apple Inc. All rights reserved.
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
* Inlineable parts of NSObject / objc_object implementation
**********************************************************************/

#ifndef _OBJC_OBJCOBJECT_H_
#define _OBJC_OBJCOBJECT_H_

#include "objc-private.h"


enum ReturnDisposition : bool {
    ReturnAtPlus0 = false, ReturnAtPlus1 = true
};

static ALWAYS_INLINE 
bool prepareOptimizedReturn(id obj, bool cameFromRootAutorelease, ReturnDisposition disposition);


#if SUPPORT_TAGGED_POINTERS

extern "C" { 
    extern ptrauth_taggedpointer_table_entry Class objc_debug_taggedpointer_classes[_OBJC_TAG_SLOT_COUNT];
    extern ptrauth_taggedpointer_table_entry Class objc_debug_taggedpointer_ext_classes[_OBJC_TAG_EXT_SLOT_COUNT];
}
#define objc_tag_classes objc_debug_taggedpointer_classes
#define objc_tag_ext_classes objc_debug_taggedpointer_ext_classes

#endif

#if SUPPORT_INDEXED_ISA

ALWAYS_INLINE Class &
classForIndex(uintptr_t index) {
    ASSERT(index > 0);
    ASSERT(index < (uintptr_t)objc_indexed_classes_count);
    return objc_indexed_classes[index];
}

#endif


inline bool
objc_object::isClass() const
{
    if (isTaggedPointer()) return false;
    return ISA()->isMetaClass();
}


#if SUPPORT_TAGGED_POINTERS

inline Class
objc_object::getIsa() const
{
    if (fastpath(!isTaggedPointer())) return ISA(/*authenticated*/true);

    extern objc_class OBJC_CLASS_$___NSUnrecognizedTaggedPointer;
    uintptr_t slot, ptr = (uintptr_t)this;
    Class cls;

    slot = (ptr >> _OBJC_TAG_SLOT_SHIFT) & _OBJC_TAG_SLOT_MASK;
    cls = objc_tag_classes[slot];
    if (slowpath(cls == (Class)&OBJC_CLASS_$___NSUnrecognizedTaggedPointer)) {
        slot = (ptr >> _OBJC_TAG_EXT_SLOT_SHIFT) & _OBJC_TAG_EXT_SLOT_MASK;
        cls = objc_tag_ext_classes[slot];
    }
    return cls;
}

inline uintptr_t
objc_object::isaBits() const
{
    return isa().bits;
}

inline bool 
objc_object::isTaggedPointer() const
{
    return _objc_isTaggedPointer(this);
}

inline bool 
objc_object::isBasicTaggedPointer() const
{
    return isTaggedPointer()  &&  !isExtTaggedPointer();
}

inline bool 
objc_object::isExtTaggedPointer() const
{
    uintptr_t ptr = _objc_decodeTaggedPointer(this);
    return (ptr & _OBJC_TAG_EXT_MASK) == _OBJC_TAG_EXT_MASK;
}


// SUPPORT_TAGGED_POINTERS
#else
// not SUPPORT_TAGGED_POINTERS

inline Class
objc_object::getIsa() const
{
    return ISA();
}

inline uintptr_t
objc_object::isaBits() const
{
    return isa().bits;
}


inline bool 
objc_object::isTaggedPointer() const
{
    return false;
}

inline bool 
objc_object::isBasicTaggedPointer() const
{
    return false;
}

inline bool 
objc_object::isExtTaggedPointer() const
{
    return false;
}


// not SUPPORT_TAGGED_POINTERS
#endif


#if SUPPORT_NONPOINTER_ISA

// Set the class field in an isa. Takes both the class to set and
// a pointer to the object where the isa will ultimately be used.
// This is necessary to get the pointer signing right.
//
// Note: this method does not support setting an indexed isa. When
// indexed isas are in use, it can only be used to set the class of a
// raw isa.
inline void
isa_t::setClass(Class newCls, UNUSED_WITHOUT_PTRAUTH objc_object *obj)
{
    // Match the conditional in isa.h.
#if __has_feature(ptrauth_calls) || TARGET_OS_SIMULATOR
#   if ISA_SIGNING_SIGN_MODE == ISA_SIGNING_SIGN_NONE
    // No signing, just use the raw pointer.
    uintptr_t signedCls = (uintptr_t)newCls;

#   elif ISA_SIGNING_SIGN_MODE == ISA_SIGNING_SIGN_ONLY_SWIFT
    // We're only signing Swift classes. Non-Swift classes just use
    // the raw pointer
    uintptr_t signedCls = (uintptr_t)newCls;
    if (newCls->isSwiftStable())
        signedCls = (uintptr_t)ptrauth_sign_unauthenticated((void *)newCls, ISA_SIGNING_KEY, ptrauth_blend_discriminator(obj, ISA_SIGNING_DISCRIMINATOR));

#   elif ISA_SIGNING_SIGN_MODE == ISA_SIGNING_SIGN_ALL
    // We're signing everything
    uintptr_t signedCls = (uintptr_t)ptrauth_sign_unauthenticated((void *)newCls, ISA_SIGNING_KEY, ptrauth_blend_discriminator(obj, ISA_SIGNING_DISCRIMINATOR));

#   else
#       error Unknown isa signing mode.
#   endif

    shiftcls_and_sig = signedCls >> 3;

#elif SUPPORT_INDEXED_ISA
    // Indexed isa only uses this method to set a raw pointer class.
    // Setting an indexed class is handled separately.
    cls = newCls;

#else // Nonpointer isa, no ptrauth
    shiftcls = (uintptr_t)newCls >> 3;
#endif
}

// Get the class pointer out of an isa. When ptrauth is supported,
// this operation is optionally authenticated. Many code paths don't
// need the authentication, so it can be skipped in those cases for
// better performance.
//
// Note: this method does not support retrieving indexed isas. When
// indexed isas are in use, it can only be used to retrieve the class
// of a raw isa.
#if SUPPORT_INDEXED_ISA || (ISA_SIGNING_AUTH_MODE != ISA_SIGNING_AUTH)
#define MAYBE_UNUSED_AUTHENTICATED_PARAM __attribute__((unused))
#else
#define MAYBE_UNUSED_AUTHENTICATED_PARAM UNUSED_WITHOUT_PTRAUTH
#endif

inline Class
isa_t::getClass(MAYBE_UNUSED_AUTHENTICATED_PARAM bool authenticated) const {
#if SUPPORT_INDEXED_ISA
    return cls;
#else

    uintptr_t clsbits = bits;

#   if __has_feature(ptrauth_calls)
#       if ISA_SIGNING_AUTH_MODE == ISA_SIGNING_AUTH
    // Most callers aren't security critical, so skip the
    // authentication unless they ask for it. Message sending and
    // cache filling are protected by the auth code in msgSend.
    if (authenticated) {
        // Mask off all bits besides the class pointer and signature.
        clsbits &= ISA_MASK;
        if (clsbits == 0)
            return Nil;
        clsbits = (uintptr_t)ptrauth_auth_data((void *)clsbits, ISA_SIGNING_KEY, ptrauth_blend_discriminator(this, ISA_SIGNING_DISCRIMINATOR));
    } else {
        // If not authenticating, strip using the precomputed class mask.
        clsbits &= objc_debug_isa_class_mask;
    }
#       else
    // If not authenticating, strip using the precomputed class mask.
    clsbits &= objc_debug_isa_class_mask;
#       endif

#   else
    clsbits &= ISA_MASK;
#   endif

    return (Class)clsbits;
#endif
}

inline Class
isa_t::getDecodedClass(bool authenticated) const {
#if SUPPORT_INDEXED_ISA
    if (nonpointer) {
        return classForIndex(indexcls);
    }
    return (Class)cls;
#else
    return getClass(authenticated);
#endif
}

inline Class
objc_object::ISA(bool authenticated) const
{
    ASSERT(!isTaggedPointer());
    return isa().getDecodedClass(authenticated);
}

inline Class
objc_object::rawISA() const
{
    ASSERT(!isTaggedPointer() && !isa().nonpointer);
    return (Class)isa().bits;
}

inline bool 
objc_object::hasNonpointerIsa() const
{
    return isa().nonpointer;
}


inline void 
objc_object::initIsa(Class cls)
{
    initIsa(cls, false, false);
}

inline void 
objc_object::initClassIsa(Class cls)
{
    if (DisableNonpointerIsa  ||  cls->instancesRequireRawIsa()) {
        initIsa(cls, false/*not nonpointer*/, false);
    } else {
        initIsa(cls, true/*nonpointer*/, false);
    }
}

inline void
objc_object::initProtocolIsa(Class cls)
{
    return initClassIsa(cls);
}

inline void 
objc_object::initInstanceIsa(Class cls, bool hasCxxDtor)
{
    ASSERT(!cls->instancesRequireRawIsa());
    ASSERT(hasCxxDtor == cls->hasCxxDtor());

    initIsa(cls, true, hasCxxDtor);
}

#if !SUPPORT_INDEXED_ISA && !ISA_HAS_CXX_DTOR_BIT
#define UNUSED_WITHOUT_INDEXED_ISA_AND_DTOR_BIT __attribute__((unused))
#else
#define UNUSED_WITHOUT_INDEXED_ISA_AND_DTOR_BIT
#endif

inline void 
objc_object::initIsa(Class cls, bool nonpointer, UNUSED_WITHOUT_INDEXED_ISA_AND_DTOR_BIT bool hasCxxDtor)
{ 
    ASSERT(!isTaggedPointer()); 
    
    isa_t newisa(0);

    if (!nonpointer) {
        newisa.setClass(cls, this);
    } else {
        ASSERT(!DisableNonpointerIsa);
        ASSERT(!cls->instancesRequireRawIsa());


#if SUPPORT_INDEXED_ISA
        ASSERT(cls->classArrayIndex() > 0);
        newisa.bits = ISA_INDEX_MAGIC_VALUE;
        // isa.magic is part of ISA_MAGIC_VALUE
        // isa.nonpointer is part of ISA_MAGIC_VALUE
        newisa.has_cxx_dtor = hasCxxDtor;
        newisa.indexcls = (uintptr_t)cls->classArrayIndex();
#else
        newisa.bits = ISA_MAGIC_VALUE;
        // isa.magic is part of ISA_MAGIC_VALUE
        // isa.nonpointer is part of ISA_MAGIC_VALUE
#   if ISA_HAS_CXX_DTOR_BIT
        newisa.has_cxx_dtor = hasCxxDtor;
#   endif
        newisa.setClass(cls, this);
#endif
#if ISA_HAS_INLINE_RC
        newisa.extra_rc = 1;
#endif
    }

    // This write must be performed in a single store in some cases
    // (for example when realizing a class because other threads
    // may simultaneously try to use the class).
    // fixme use atomics here to guarantee single-store and to
    // guarantee memory order w.r.t. the class index table
    // ...but not too atomic because we don't want to hurt instantiation
    isa() = newisa;
}

inline Class 
objc_object::changeIsa(Class newCls)
{
    // This is almost always true but there are 
    // enough edge cases that we can't assert it.
    // assert(newCls->isFuture()  || 
    //        newCls->isInitializing()  ||  newCls->isInitialized());

    ASSERT(!isTaggedPointer()); 

    isa_t oldisa;
    isa_t newisa(0);

#if ISA_HAS_INLINE_RC
    bool sideTableLocked = false;
    bool transcribeToSideTable = false;
#endif

    oldisa = LoadExclusive(&isa().bits);

    do {
#if ISA_HAS_INLINE_RC
        transcribeToSideTable = false;
#endif
        if ((oldisa.bits == 0  ||  oldisa.nonpointer)  &&
            !newCls->isFuture()  &&  newCls->canAllocNonpointer())
        {
            // 0 -> nonpointer
            // nonpointer -> nonpointer
#if SUPPORT_INDEXED_ISA
            if (oldisa.bits == 0) {
                newisa.bits = ISA_INDEX_MAGIC_VALUE;
#if ISA_HAS_INLINE_RC
                newisa.extra_rc = 1;
#endif
            } else {
                newisa = oldisa;
            }
            // isa.magic is part of ISA_MAGIC_VALUE
            // isa.nonpointer is part of ISA_MAGIC_VALUE
            newisa.has_cxx_dtor = newCls->hasCxxDtor();
            ASSERT(newCls->classArrayIndex() > 0);
            newisa.indexcls = (uintptr_t)newCls->classArrayIndex();
#else
            if (oldisa.bits == 0) {
                newisa.bits = ISA_MAGIC_VALUE;
#if ISA_HAS_INLINE_RC
                newisa.extra_rc = 1;
#endif
            }
            else {
                newisa = oldisa;
            }
            // isa.magic is part of ISA_MAGIC_VALUE
            // isa.nonpointer is part of ISA_MAGIC_VALUE
#   if ISA_HAS_CXX_DTOR_BIT
            newisa.has_cxx_dtor = newCls->hasCxxDtor();
#   endif
            newisa.setClass(newCls, this);
#endif
        }
#if ISA_HAS_INLINE_RC
        else if (oldisa.nonpointer) {
            // nonpointer -> raw pointer
            // Need to copy retain count et al to side table.
            // Acquire side table lock before setting isa to 
            // prevent races such as concurrent -release.
            if (!sideTableLocked) sidetable_lock();
            sideTableLocked = true;
            transcribeToSideTable = true;
            newisa.setClass(newCls, this);
        }
#endif
        else {
            // raw pointer -> raw pointer
            newisa.setClass(newCls, this);
        }
    } while (slowpath(!StoreExclusive(&isa().bits, &oldisa.bits, newisa.bits)));

#if ISA_HAS_INLINE_RC
    if (transcribeToSideTable) {
        // Copy oldisa's retain count et al to side table.
        // oldisa.has_assoc: nothing to do
        // oldisa.has_cxx_dtor: nothing to do
        sidetable_moveExtraRC_nolock(oldisa.extra_rc, 
                                     oldisa.isDeallocating(),
                                     oldisa.weakly_referenced);
    }

    if (sideTableLocked) sidetable_unlock();
#endif

    return oldisa.getDecodedClass(false);
}

inline bool
objc_object::hasAssociatedObjects() const
{
    if (isTaggedPointer()) return true;
    if (isa().nonpointer) return isa().has_assoc;
    return true;
}


inline void
objc_object::setHasAssociatedObjects()
{
    if (isTaggedPointer()) return;

    if (slowpath(!hasNonpointerIsa() && ISA()->hasCustomRR()) && !ISA()->isFuture() && !ISA()->isMetaClass()) {
        void(*setAssoc)(id, SEL) = (void(*)(id, SEL)) object_getMethodImplementation((id)this, @selector(_noteAssociatedObjects));
        if ((IMP)setAssoc != _objc_msgForward) {
            (*setAssoc)((id)this, @selector(_noteAssociatedObjects));
        }
    }

    isa_t newisa, oldisa = LoadExclusive(&isa().bits);
    do {
        newisa = oldisa;
        if (!newisa.nonpointer  ||  newisa.has_assoc) {
            ClearExclusive(&isa().bits);
            return;
        }
        newisa.has_assoc = true;
    } while (slowpath(!StoreExclusive(&isa().bits, &oldisa.bits, newisa.bits)));
}


inline bool
objc_object::isWeaklyReferenced() const
{
    ASSERT(!isTaggedPointer());
    if (isa().nonpointer) return isa().weakly_referenced;
    else return sidetable_isWeaklyReferenced();
}


inline void
objc_object::setWeaklyReferenced_nolock()
{
    isa_t newisa, oldisa = LoadExclusive(&isa().bits);
    do {
        newisa = oldisa;
        if (slowpath(!newisa.nonpointer)) {
            ClearExclusive(&isa().bits);
            sidetable_setWeaklyReferenced_nolock();
            return;
        }
        if (newisa.weakly_referenced) {
            ClearExclusive(&isa().bits);
            return;
        }
        newisa.weakly_referenced = true;
    } while (slowpath(!StoreExclusive(&isa().bits, &oldisa.bits, newisa.bits)));
}


inline bool
objc_object::isUniquelyReferenced() const
{
    ASSERT(!isTaggedPointer());
    if (fastpath(!ISA()->hasCustomRR())) {
        return rootRetainCount() == 1;
    }
    return ((NSUInteger(*)(objc_object *, SEL))objc_msgSend)((objc_object *)this, @selector(retainCount)) == 1;
}


inline bool
objc_object::hasCxxDtor() const
{
    ASSERT(!isTaggedPointer());
#if ISA_HAS_CXX_DTOR_BIT
    if (isa().nonpointer)
        return isa().has_cxx_dtor;
    else
#endif
        return ISA()->hasCxxDtor();
}



inline bool 
objc_object::rootIsDeallocating() const
{
    if (isTaggedPointer()) return false;
#if ISA_HAS_INLINE_RC
    if (isa().nonpointer) return isa().isDeallocating();
#endif
    return sidetable_isDeallocating();
}


inline void 
objc_object::clearDeallocating()
{
    if (slowpath(!isa().nonpointer)) {
        // Slow path for raw pointer isa.
        sidetable_clearDeallocating();
#if ISA_HAS_INLINE_RC
    } else if (slowpath(isa().weakly_referenced || isa().has_sidetable_rc)) {
#else
    } else {
#endif
        // Slow path for non-pointer isa with weak refs and/or side table data.
        clearDeallocating_slow();
    }

    assert(!sidetable_present());
}


inline void
objc_object::rootDealloc()
{
    if (isTaggedPointer()) return;  // fixme necessary?

#if !ISA_HAS_INLINE_RC
    object_dispose((id)this);
#else
    if (fastpath(isa().nonpointer                     &&
                 !isa().weakly_referenced             &&
                 !isa().has_assoc                     &&
#if ISA_HAS_CXX_DTOR_BIT
                 !isa().has_cxx_dtor                  &&
#else
                 !isa().getClass(false)->hasCxxDtor() &&
#endif
                 !isa().has_sidetable_rc))
    {
        assert(!sidetable_present());
        free(this);
    } 
    else {
        object_dispose((id)this);
    }
#endif // ISA_HAS_INLINE_RC
}

extern explicit_atomic<id(*)(id)> swiftRetain;
extern explicit_atomic<void(*)(id)> swiftRelease;

// Equivalent to calling [this retain], with shortcuts if there is no override
inline id 
objc_object::retain()
{
    ASSERT(!isTaggedPointer());

    return rootRetain(false, RRVariant::FastOrMsgSend);
}

// Base retain implementation, ignoring overrides.
// This does not check isa.fast_rr; if there is an RR override then 
// it was already called and it chose to call [super retain].
//
// tryRetain=true is the -_tryRetain path.
// handleOverflow=false is the frameless fast path.
// handleOverflow=true is the framed slow path including overflow to side table
// The code is structured this way to prevent duplication.

ALWAYS_INLINE id 
objc_object::rootRetain()
{
    return rootRetain(false, RRVariant::Fast);
}

ALWAYS_INLINE bool 
objc_object::rootTryRetain()
{
    return rootRetain(true, RRVariant::Fast) ? true : false;
}

ALWAYS_INLINE id
objc_object::rootRetain(bool tryRetain, objc_object::RRVariant variant)
{
    if (slowpath(isTaggedPointer())) return (id)this;

    bool sideTableLocked = false;
    bool transcribeToSideTable = false;

    isa_t oldisa;
    isa_t newisa;

    oldisa = LoadExclusive(&isa().bits);

    if (variant == RRVariant::FastOrMsgSend) {
        // These checks are only meaningful for objc_retain()
        // They are here so that we avoid a re-load of the isa.
        if (slowpath(oldisa.getDecodedClass(false)->hasCustomRR())) {
            ClearExclusive(&isa().bits);
            if (oldisa.getDecodedClass(false)->canCallSwiftRR()) {
                return swiftRetain.load(memory_order_relaxed)((id)this);
            }
            return ((id(*)(objc_object *, SEL))objc_msgSend)(this, @selector(retain));
        }
    }

    if (slowpath(!oldisa.nonpointer)) {
        // a Class is a Class forever, so we can perform this check once
        // outside of the CAS loop
        if (oldisa.getDecodedClass(false)->isMetaClass()) {
            ClearExclusive(&isa().bits);
            return (id)this;
        }
    }

#if !ISA_HAS_INLINE_RC
    // No need for a CAS loop in this case; we aren't changing the ISA pointer
    ClearExclusive(&isa().bits);
    if (tryRetain) return sidetable_tryRetain() ? (id)this : nil;
    else return sidetable_retain(sideTableLocked);
#else
    do {
        transcribeToSideTable = false;
        newisa = oldisa;
        if (slowpath(!newisa.nonpointer)) {
            ClearExclusive(&isa().bits);
            if (tryRetain) return sidetable_tryRetain() ? (id)this : nil;
            else return sidetable_retain(sideTableLocked);
        }
        // don't check newisa.fast_rr; we already called any RR overrides
        if (slowpath(newisa.isDeallocating())) {
            ClearExclusive(&isa().bits);
            if (sideTableLocked) {
                ASSERT(variant == RRVariant::Full);
                sidetable_unlock();
            }
            if (slowpath(tryRetain)) {
                return nil;
            } else {
                return (id)this;
            }
        }
        uintptr_t carry;
        newisa.bits = addc(newisa.bits, RC_ONE, 0, &carry);  // extra_rc++

        if (slowpath(carry)) {
            // newisa.extra_rc++ overflowed
            if (variant != RRVariant::Full) {
                ClearExclusive(&isa().bits);
                return rootRetain_overflow(tryRetain);
            }
            // Leave half of the retain counts inline and 
            // prepare to copy the other half to the side table.
            if (!tryRetain && !sideTableLocked) sidetable_lock();
            sideTableLocked = true;
            transcribeToSideTable = true;
            newisa.extra_rc = RC_HALF;
            newisa.has_sidetable_rc = true;
        }
    } while (slowpath(!StoreExclusive(&isa().bits, &oldisa.bits, newisa.bits)));

    if (variant == RRVariant::Full) {
        if (slowpath(transcribeToSideTable)) {
            // Copy the other half of the retain counts to the side table.
            sidetable_addExtraRC_nolock(RC_HALF);
        }

        if (slowpath(!tryRetain && sideTableLocked)) sidetable_unlock();
    } else {
        ASSERT(!transcribeToSideTable);
        ASSERT(!sideTableLocked);
    }
#endif

    return (id)this;
}


// Equivalent to calling [this release], with shortcuts if there is no override
inline void
objc_object::release()
{
    ASSERT(!isTaggedPointer());

    rootRelease(true, RRVariant::FastOrMsgSend);
}


// Base release implementation, ignoring overrides.
// Does not call -dealloc.
// Returns true if the object should now be deallocated.
// This does not check isa.fast_rr; if there is an RR override then 
// it was already called and it chose to call [super release].
// 
// handleUnderflow=false is the frameless fast path.
// handleUnderflow=true is the framed slow path including side table borrow
// The code is structured this way to prevent duplication.

ALWAYS_INLINE bool 
objc_object::rootRelease()
{
    return rootRelease(true, RRVariant::Fast);
}

ALWAYS_INLINE bool 
objc_object::rootReleaseShouldDealloc()
{
    return rootRelease(false, RRVariant::Fast);
}

ALWAYS_INLINE bool
objc_object::rootRelease(bool performDealloc, objc_object::RRVariant variant)
{
    if (slowpath(isTaggedPointer())) return false;

    bool sideTableLocked = false;

    isa_t newisa, oldisa;

    oldisa = LoadExclusive(&isa().bits);

    if (variant == RRVariant::FastOrMsgSend) {
        // These checks are only meaningful for objc_release()
        // They are here so that we avoid a re-load of the isa.
        if (slowpath(oldisa.getDecodedClass(false)->hasCustomRR())) {
            ClearExclusive(&isa().bits);
            if (oldisa.getDecodedClass(false)->canCallSwiftRR()) {
                swiftRelease.load(memory_order_relaxed)((id)this);
                return true;
            }
            ((void(*)(objc_object *, SEL))objc_msgSend)(this, @selector(release));
            return true;
        }
    }

    if (slowpath(!oldisa.nonpointer)) {
        // a Class is a Class forever, so we can perform this check once
        // outside of the CAS loop
        if (oldisa.getDecodedClass(false)->isMetaClass()) {
            ClearExclusive(&isa().bits);
            return false;
        }
    }

#if !ISA_HAS_INLINE_RC
    // Without inline ref counts, we always use sidetables
    ClearExclusive(&isa().bits);
    return sidetable_release(sideTableLocked, performDealloc);
#else
retry:
    do {
        newisa = oldisa;
        if (slowpath(!newisa.nonpointer)) {
            ClearExclusive(&isa().bits);
            return sidetable_release(sideTableLocked, performDealloc);
        }
        if (slowpath(newisa.isDeallocating())) {
            ClearExclusive(&isa().bits);
            if (sideTableLocked) {
                ASSERT(variant == RRVariant::Full);
                sidetable_unlock();
            }
            return false;
        }

        // don't check newisa.fast_rr; we already called any RR overrides
        uintptr_t carry;
        newisa.bits = subc(newisa.bits, RC_ONE, 0, &carry);  // extra_rc--
        if (slowpath(carry)) {
            // don't ClearExclusive()
            goto underflow;
        }
    } while (slowpath(!StoreReleaseExclusive(&isa().bits, &oldisa.bits, newisa.bits)));

    if (slowpath(newisa.isDeallocating()))
        goto deallocate;

    if (variant == RRVariant::Full) {
        if (slowpath(sideTableLocked)) sidetable_unlock();
    } else {
        ASSERT(!sideTableLocked);
    }
    return false;

 underflow:
    // newisa.extra_rc-- underflowed: borrow from side table or deallocate

    // abandon newisa to undo the decrement
    newisa = oldisa;

    if (slowpath(newisa.has_sidetable_rc)) {
        if (variant != RRVariant::Full) {
            ClearExclusive(&isa().bits);
            return rootRelease_underflow(performDealloc);
        }

        // Transfer retain count from side table to inline storage.

        if (!sideTableLocked) {
            ClearExclusive(&isa().bits);
            sidetable_lock();
            sideTableLocked = true;
            // Need to start over to avoid a race against 
            // the nonpointer -> raw pointer transition.
            oldisa = LoadExclusive(&isa().bits);
            goto retry;
        }

        // Try to remove some retain counts from the side table.        
        auto borrow = sidetable_subExtraRC_nolock(RC_HALF);

        bool emptySideTable = borrow.remaining == 0; // we'll clear the side table if no refcounts remain there

        if (borrow.borrowed > 0) {
            // Side table retain count decreased.
            // Try to add them to the inline count.
            bool didTransitionToDeallocating = false;
            newisa.extra_rc = borrow.borrowed - 1;  // redo the original decrement too
            newisa.has_sidetable_rc = !emptySideTable;

            bool stored = StoreReleaseExclusive(&isa().bits, &oldisa.bits, newisa.bits);

            if (!stored && oldisa.nonpointer) {
                // Inline update failed. 
                // Try it again right now. This prevents livelock on LL/SC 
                // architectures where the side table access itself may have 
                // dropped the reservation.
                uintptr_t overflow;
                newisa.bits =
                    addc(oldisa.bits, RC_ONE * (borrow.borrowed-1), 0, &overflow);
                newisa.has_sidetable_rc = !emptySideTable;
                if (!overflow) {
                    stored = StoreReleaseExclusive(&isa().bits, &oldisa.bits, newisa.bits);
                    if (stored) {
                        didTransitionToDeallocating = newisa.isDeallocating();
                    }
                }
            }

            if (!stored) {
                // Inline update failed.
                // Put the retains back in the side table.
                ClearExclusive(&isa().bits);
                sidetable_addExtraRC_nolock(borrow.borrowed);
                oldisa = LoadExclusive(&isa().bits);
                goto retry;
            }

            // Decrement successful after borrowing from side table.
            if (emptySideTable)
                sidetable_clearExtraRC_nolock();

            if (!didTransitionToDeallocating) {
                if (slowpath(sideTableLocked)) sidetable_unlock();
                return false;
            }
        }
        else {
            // Side table is empty after all. Fall-through to the dealloc path.
        }
    }

deallocate:
    // Really deallocate.

    ASSERT(newisa.isDeallocating());
    ASSERT(isa().isDeallocating());

    if (slowpath(sideTableLocked)) sidetable_unlock();

    __c11_atomic_thread_fence(__ATOMIC_ACQUIRE);

    if (performDealloc) {
        this->performDealloc();
    }
    return true;
#endif // ISA_HAS_INLINE_RC
}


// Equivalent to [this autorelease], with shortcuts if there is no override
ALWAYS_INLINE id
objc_object::autorelease()
{
    ASSERT(!isTaggedPointer());
    if (fastpath(!ISA()->hasCustomRR())) {
        return rootAutorelease();
    }

    return ((id(*)(objc_object *, SEL))objc_msgSend)(this, @selector(autorelease));
}


// Base autorelease implementation, ignoring overrides.
ALWAYS_INLINE id
objc_object::rootAutorelease()
{
    if (isTaggedPointer()) return (id)this;
    bool nonpointerIsa = false;
#if ISA_HAS_INLINE_RC
    nonpointerIsa = isa().nonpointer;

    // When we can cheaply determine if the object is deallocating, avoid
    // putting it in the pool. Refcounting doesn't work on a deallocating object
    // so it's pointless to put it in the pool, and potentially dangerous.
    if (nonpointerIsa && isa().isDeallocating()) return (id)this;
#endif

    // If the class has custom dealloc initiation, we also want to avoid putting
    // deallocating instances in the pool even if it's expensive to check. (UIView
    // and UIViewController need this. rdar://97186669)
    if (!nonpointerIsa && ISA()->hasCustomDeallocInitiation() && rootIsDeallocating())
        return (id)this;

    if (prepareOptimizedReturn((id)this, true, ReturnAtPlus1)) return (id)this;
    if (slowpath(isClass())) return (id)this;
    
    return rootAutorelease2();
}


inline uintptr_t 
objc_object::rootRetainCount() const
{
    if (isTaggedPointer()) return (uintptr_t)this;

#if ISA_HAS_INLINE_RC
    sidetable_lock();
    isa_t bits = __c11_atomic_load((_Atomic uintptr_t *)&isa().bits, __ATOMIC_RELAXED);
    if (bits.nonpointer) {
        uintptr_t rc = bits.extra_rc;
        if (bits.has_sidetable_rc) {
            rc += sidetable_getExtraRC_nolock();
        }
        sidetable_unlock();
        return rc;
    }

    sidetable_unlock();
#endif

    return sidetable_retainCount();
}


// SUPPORT_NONPOINTER_ISA
#else
// not SUPPORT_NONPOINTER_ISA

inline void
isa_t::setClass(Class cls, objc_object *obj)
{
    this->cls = cls;
}

inline Class
isa_t::getClass(bool authenticated __unused) const
{
    return cls;
}

inline Class
isa_t::getDecodedClass(bool authenticated) const
{
    return getClass(authenticated);
}

inline Class 
objc_object::ISA(bool authenticated __unused) const
{
    ASSERT(!isTaggedPointer()); 
    return isa().getClass(/*authenticated*/false);
}

inline Class
objc_object::rawISA() const
{
    return ISA();
}

inline bool 
objc_object::hasNonpointerIsa() const
{
    return false;
}


inline void 
objc_object::initIsa(Class cls)
{
    ASSERT(!isTaggedPointer()); 
    isa().setClass(cls, this);
}


inline void 
objc_object::initClassIsa(Class cls)
{
    initIsa(cls);
}


inline void 
objc_object::initProtocolIsa(Class cls)
{
    initIsa(cls);
}


inline void 
objc_object::initInstanceIsa(Class cls, bool)
{
    initIsa(cls);
}


inline void 
objc_object::initIsa(Class cls, bool, bool)
{ 
    initIsa(cls);
}


inline Class 
objc_object::changeIsa(Class cls)
{
    // This is almost always rue but there are 
    // enough edge cases that we can't assert it.
    // assert(cls->isFuture()  ||  
    //        cls->isInitializing()  ||  cls->isInitialized());

    ASSERT(!isTaggedPointer()); 

    isa_t newisa, oldisa;
    newisa.setClass(cls, this);
    oldisa.bits = __c11_atomic_exchange((_Atomic uintptr_t *)&isa().bits, newisa.bits, __ATOMIC_RELAXED);

    Class oldcls = oldisa.getDecodedClass(/*authenticated*/false);
    if (oldcls  &&  oldcls->instancesHaveAssociatedObjects()) {
        cls->setInstancesHaveAssociatedObjects();
    }

    return oldcls;
}


inline bool
objc_object::hasAssociatedObjects() const
{
    return getIsa()->instancesHaveAssociatedObjects();
}


inline void
objc_object::setHasAssociatedObjects()
{
    getIsa()->setInstancesHaveAssociatedObjects();
}


inline bool
objc_object::isWeaklyReferenced() const
{
    ASSERT(!isTaggedPointer());

    return sidetable_isWeaklyReferenced();
}


inline void 
objc_object::setWeaklyReferenced_nolock()
{
    ASSERT(!isTaggedPointer());

    sidetable_setWeaklyReferenced_nolock();
}


inline bool
objc_object::isUniquelyReferenced() const
{
    ASSERT(!isTaggedPointer());
    if (fastpath(!ISA()->hasCustomRR())) {
        return rootRetainCount() == 1;
    }
    return ((NSUInteger(*)(objc_object *, SEL))objc_msgSend)((objc_object *)this, @selector(retainCount)) == 1;
}


inline bool
objc_object::hasCxxDtor() const
{
    ASSERT(!isTaggedPointer());
    return isa().getClass(/*authenticated*/false)->hasCxxDtor();
}


inline bool 
objc_object::rootIsDeallocating() const
{
    if (isTaggedPointer()) return false;
    return sidetable_isDeallocating();
}


inline void 
objc_object::clearDeallocating()
{
    sidetable_clearDeallocating();
}


inline void
objc_object::rootDealloc()
{
    if (isTaggedPointer()) return;
    object_dispose((id)this);
}


// Equivalent to calling [this retain], with shortcuts if there is no override
inline id 
objc_object::retain()
{
    ASSERT(!isTaggedPointer());

    if (fastpath(!ISA()->hasCustomRR())) {
        // Standard RR of a class is a no-op.
        if (ISA()->isMetaClass())
            return (id)this;

        return sidetable_retain();
    }

    return ((id(*)(objc_object *, SEL))objc_msgSend)(this, @selector(retain));
}


// Base retain implementation, ignoring overrides.
// This does not check isa.fast_rr; if there is an RR override then 
// it was already called and it chose to call [super retain].
inline id 
objc_object::rootRetain()
{
    if (isTaggedPointer()) return (id)this;
    return sidetable_retain();
}


// Equivalent to calling [this release], with shortcuts if there is no override
inline void
objc_object::release()
{
    ASSERT(!isTaggedPointer());

    if (fastpath(!ISA()->hasCustomRR())) {
        // Standard RR of a class is a no-op.
        if (!ISA()->isMetaClass())
            sidetable_release();
        return;
    }

    ((void(*)(objc_object *, SEL))objc_msgSend)(this, @selector(release));
}


// Base release implementation, ignoring overrides.
// Does not call -dealloc.
// Returns true if the object should now be deallocated.
// This does not check isa.fast_rr; if there is an RR override then 
// it was already called and it chose to call [super release].
inline bool 
objc_object::rootRelease()
{
    if (isTaggedPointer()) return false;
    return sidetable_release();
}

inline bool 
objc_object::rootReleaseShouldDealloc()
{
    if (isTaggedPointer()) return false;
    return sidetable_release(/*locked*/false, /*performDealloc*/false);
}


// Equivalent to [this autorelease], with shortcuts if there is no override
inline id 
objc_object::autorelease()
{
    if (isTaggedPointer()) return (id)this;
    if (fastpath(!ISA()->hasCustomRR())) return rootAutorelease();

    return ((id(*)(objc_object *, SEL))objc_msgSend)(this, @selector(autorelease));
}


// Base autorelease implementation, ignoring overrides.
ALWAYS_INLINE id
objc_object::rootAutorelease()
{
    if (isTaggedPointer()) return (id)this;

    // If the class has custom dealloc initiation, we also want to avoid putting
    // deallocating instances in the pool even if it's expensive to check. (UIView
    // and UIViewController need this. rdar://97186669)
    if (ISA()->hasCustomDeallocInitiation() && rootIsDeallocating())
        return (id)this;

    if (prepareOptimizedReturn((id)this, true, ReturnAtPlus1)) return (id)this;

    return rootAutorelease2();
}


// Base tryRetain implementation, ignoring overrides.
// This does not check isa.fast_rr; if there is an RR override then 
// it was already called and it chose to call [super _tryRetain].
inline bool 
objc_object::rootTryRetain()
{
    if (isTaggedPointer()) return true;
    return sidetable_tryRetain();
}


inline uintptr_t 
objc_object::rootRetainCount() const
{
    if (isTaggedPointer()) return (uintptr_t)this;
    return sidetable_retainCount();
}


// not SUPPORT_NONPOINTER_ISA
#endif


#if SUPPORT_RETURN_AUTORELEASE

/***********************************************************************
  Fast handling of return through Cocoa's +0 autoreleasing convention.
  The caller and callee cooperate to keep the returned object 
  out of the autorelease pool and eliminate redundant retain/release pairs.

  An optimized callee looks at the caller's instructions following the 
  return. If the caller's instructions are also optimized then the callee 
  skips all retain count operations: no autorelease, no retain/autorelease.
  Instead it saves the result's current retain count (+0 or +1) in 
  thread-local storage. If the caller does not look optimized then 
  the callee performs autorelease or retain/autorelease as usual.

  An optimized caller looks at the thread-local storage. If the result 
  is set then it performs any retain or release needed to change the 
  result from the retain count left by the callee to the retain count 
  desired by the caller. Otherwise the caller assumes the result is 
  currently at +0 from an unoptimized callee and performs any retain 
  needed for that case.

  There are two optimized callees:
    objc_autoreleaseReturnValue
      result is currently +1. The unoptimized path autoreleases it.
    objc_retainAutoreleaseReturnValue
      result is currently +0. The unoptimized path retains and autoreleases it.

  There are two optimized callers:
    objc_retainAutoreleasedReturnValue
      caller wants the value at +1. The unoptimized path retains it.
    objc_unsafeClaimAutoreleasedReturnValue
      caller wants the value at +0 unsafely. The unoptimized path does nothing.

  Example:

    Callee:
      // compute ret at +1
      return objc_autoreleaseReturnValue(ret);
    
    Caller:
      ret = callee();
      ret = objc_retainAutoreleasedReturnValue(ret);
      // use ret at +1 here

    Callee sees the optimized caller, sets TLS, and leaves the result at +1.
    Caller sees the TLS, clears it, and accepts the result at +1 as-is.

  The callee's recognition of the optimized caller is architecture-dependent.
  x86_64: Callee looks for `mov rax, rdi` followed by a call or 
    jump instruction to objc_retainAutoreleasedReturnValue or 
    objc_unsafeClaimAutoreleasedReturnValue. 
  i386:  Callee looks for a magic nop `movl %ebp, %ebp` (frame pointer register)
  armv7: Callee looks for a magic nop `mov r7, r7` (frame pointer register). 
  arm64: Callee looks for a magic nop `mov x29, x29` (frame pointer register). 

  Tagged pointer objects do participate in the optimized return scheme, 
  because it saves message sends. They are not entered in the autorelease 
  pool in the unoptimized case.
**********************************************************************/

# if __x86_64__

static ALWAYS_INLINE bool 
callerAcceptsOptimizedReturn(const void * const ra0)
{
    const uint8_t *ra1 = (const uint8_t *)ra0;
    const unaligned_uint16_t *ra2;
    const unaligned_uint32_t *ra4 = (const unaligned_uint32_t *)ra1;
    const void **sym;

#define PREFER_GOTPCREL 0
#if PREFER_GOTPCREL
    // 48 89 c7    movq  %rax,%rdi
    // ff 15       callq *symbol@GOTPCREL(%rip)
    if (*ra4 != 0xffc78948) {
        return false;
    }
    if (ra1[4] != 0x15) {
        return false;
    }
    ra1 += 3;
#else
    // 48 89 c7    movq  %rax,%rdi
    // e8          callq symbol
    if (*ra4 != 0xe8c78948) {
        return false;
    }
    ra1 += (long)*(const unaligned_int32_t *)(ra1 + 4) + 8l;
    ra2 = (const unaligned_uint16_t *)ra1;
    // ff 25       jmpq *symbol@DYLDMAGIC(%rip)
    if (*ra2 != 0x25ff) {
        return false;
    }
#endif
    ra1 += 6l + (long)*(const unaligned_int32_t *)(ra1 + 2);
    sym = (const void **)ra1;
    if (*sym != objc_retainAutoreleasedReturnValue  &&  
        *sym != objc_unsafeClaimAutoreleasedReturnValue) 
    {
        return false;
    }

    return true;
}

// __x86_64__
# elif __arm__

static ALWAYS_INLINE bool 
callerAcceptsOptimizedReturn(const void *ra)
{
    // if the low bit is set, we're returning to thumb mode
    if ((uintptr_t)ra & 1) {
        // 3f 46          mov r7, r7
        // we mask off the low bit via subtraction
        // 16-bit instructions are well-aligned
        if (*(uint16_t *)((uint8_t *)ra - 1) == 0x463f) {
            return true;
        }
    } else {
        // 07 70 a0 e1    mov r7, r7
        // 32-bit instructions may be only 16-bit aligned
        if (*(unaligned_uint32_t *)ra == 0xe1a07007) {
            return true;
        }
    }
    return false;
}

// __arm__
# elif __arm64__

static ALWAYS_INLINE bool 
callerAcceptsOptimizedReturn(const void *ra)
{
    // fd 03 1d aa    mov fp, fp
    // arm64 instructions are well-aligned
    if (*(uint32_t *)ra == 0xaa1d03fd) {
        return true;
    }
    return false;
}

// __arm64__
# elif __i386__

static ALWAYS_INLINE bool 
callerAcceptsOptimizedReturn(const void *ra)
{
    // 89 ed    movl %ebp, %ebp
    if (*(unaligned_uint16_t *)ra == 0xed89) {
        return true;
    }
    return false;
}

// __i386__
# else

#warning unknown architecture

static ALWAYS_INLINE bool 
callerAcceptsOptimizedReturn(const void *ra)
{
    return false;
}

// unknown architecture
# endif

struct ReturnAutoreleaseInfo {
    constexpr static int objectShift = 2;
#if __LP64__
    constexpr static int objectBits = 64 - objectShift;
#else
    constexpr static int objectBits = 32 - objectShift;
#endif
    union {
        struct {
            uintptr_t returnDisposition: 1;
            uintptr_t cameFromRootAutorelease: 1;
            uintptr_t returnedObject: objectBits;
        };
        uintptr_t firstWord;
    };

    const void *returnAddress;

    ReturnAutoreleaseInfo() :
    returnDisposition(0), cameFromRootAutorelease(0),
    returnedObject(0), returnAddress(nullptr) {}

    ReturnAutoreleaseInfo(id obj, bool cameFromRootAutorelease, ReturnDisposition disposition, const void *returnAddress) :
    returnDisposition(disposition), cameFromRootAutorelease(cameFromRootAutorelease),
    returnedObject((uintptr_t)obj >> objectShift), returnAddress(returnAddress) {
        ASSERT(!_objc_isTaggedPointerOrNil(obj));
        ASSERT(getReturnedObject() == obj);
    }

    // Indicates that autorelease elision is temporarily disabled.
    static ReturnAutoreleaseInfo blockedInfo() {
        ReturnAutoreleaseInfo info;
        info.firstWord = ~(uintptr_t)0;
        return info;
    }

#if !HAS_RETURNADDR_AUTORELEASE_ELISION
    ReturnAutoreleaseInfo(ReturnDisposition disposition)
    : returnDisposition(disposition), returnAddress(nullptr) {}
#endif

    id getReturnedObject() const {
        return (id)(returnedObject << objectShift);
    }

    ReturnDisposition getReturnDisposition() const {
        return ReturnDisposition(returnDisposition);
    }

    const void *getReturnAddress() const {
        return returnAddress;
    }

    bool isEmpty() const {
        return isBlocked() || (returnedObject == 0 && returnAddress == nullptr);
    }

    bool isBlocked() const {
        return firstWord == ~(uintptr_t)0;
    }

    struct TlsDealloc {
        void operator()(uintptr_t firstWord);
    };

    // The actual TLS storage
    static tls_direct(uintptr_t, tls_key::return_autorelease_object, TlsDealloc) tlsFirstWord;
    static tls_direct(const void *, tls_key::return_autorelease_address) tlsReturnAddress;
};

static ALWAYS_INLINE ReturnAutoreleaseInfo
getReturnAutoreleaseInfo()
{
    ReturnAutoreleaseInfo info;
    info.firstWord = ReturnAutoreleaseInfo::tlsFirstWord;
    info.returnAddress = ReturnAutoreleaseInfo::tlsReturnAddress;
    return info;
}


static ALWAYS_INLINE void 
setReturnAutoreleaseInfo(ReturnAutoreleaseInfo info)
{
    ReturnAutoreleaseInfo::tlsFirstWord = info.firstWord;
    ReturnAutoreleaseInfo::tlsReturnAddress = info.returnAddress;
}

// If there's an object in the return autorelease TLS, move it into the current
// autorelease pool.
void moveTLSAutoreleaseToPool(ReturnAutoreleaseInfo info);

// Get the return address in the client code. In release builds, this just uses
// __builtin_return_address(0). In debug builds, it will dig a few levels down
// looking for an address outside libobjc, to see through non-inlined non-tail
// calls. This is ugly and slow but debug builds are slow anyway, and this
// keeps autorelease elision consistent between the two.
static ALWAYS_INLINE void *
clientReturnAddress(void) {
#if DEBUG
    const struct mach_header *libobjcHeader = dyld_image_header_containing_address((void *)objc_retain);

    // Ignore warnings about non-zero arguments to __builtin_return_address. We
    // will only use it on libobjc frames, which should be safe, and we only do
    // this in debug builds anyway.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wframe-address"
    void *prev = nullptr;
#define FRAME(n) do { \
    void *candidate = __builtin_return_address(n); \
    if (!candidate) return prev; \
    if (dyld_image_header_containing_address(candidate) != libobjcHeader) \
        return candidate; \
    prev = candidate; \
} while(0)
    // Six levels deep is enough to see through all the intervening stack frames
    // we currently have.
    FRAME(0);
    FRAME(1);
    FRAME(2);
    FRAME(3);
    FRAME(4);
    FRAME(5);
#undef FRAME
    // We didn't find anything outside of libobjc, return the last thing we
    // checked so we at least have something.
    return prev;
#pragma clang diagnostic pop
#else
    return __builtin_return_address(0);
#endif
}

// Try to prepare for optimized return with the given disposition (+0 or +1).
// Returns true if the optimized path is successful.
// Otherwise the return value must be retained and/or autoreleased as usual.
static ALWAYS_INLINE bool 
prepareOptimizedReturn(id obj, bool cameFromRootAutorelease, ReturnDisposition disposition)
{
#if HAS_RETURNADDR_AUTORELEASE_ELISION
    ReturnAutoreleaseInfo info = getReturnAutoreleaseInfo();

    // If we're blocking elision, return right away.
    if (info.isBlocked())
        return false;

    // Move a leftover TLS entry, if any, to the actual autorelease pool.
    moveTLSAutoreleaseToPool(info);

    if (_objc_isTaggedPointerOrNil(obj)) {
        setReturnAutoreleaseInfo({});
        return true;
    }

    // If the object's class isn't initialized, make that happen now.
    // Initializing later can cause +initialize to run in unexpected lock
    // contexts. rdar://88956559
    if (slowpath(!obj->ISA()->isInitialized())) {
        Class cls = obj->ISA(true /*authenticated*/);
        // If the class isn't even realized, abandon elision. We'll fall back
        // to a msgSend that will realize it for us.
        if (!cls->isRealized())
            return false;

        class_initialize(cls, obj);
    }

    // If the object has custom RR overrides and this is an explicit return
    // optimization call, then check the caller's code, since we want to send a
    // real autorelease message if the caller isn't going to claim. If the
    // caller claims without a NOP then we'll still optimize the return in the
    // autorelease call.
    if (!cameFromRootAutorelease && obj->ISA()->hasCustomRR())
        if (!callerAcceptsOptimizedReturn(clientReturnAddress()))
            return false;


    setReturnAutoreleaseInfo({obj, cameFromRootAutorelease, disposition, clientReturnAddress()});
    return true;
#else
    ASSERT(getReturnAutoreleaseInfo().getReturnDisposition() == ReturnAtPlus0);

    if (callerAcceptsOptimizedReturn(clientReturnAddress())) {
        if (disposition)
            setReturnAutoreleaseInfo({disposition});
        return true;
    }

    return false;
#endif
}


// Try to accept an optimized return.
// Returns the disposition of the returned object (+0 or +1).
// An un-optimized return is +0.
static ALWAYS_INLINE ReturnDisposition 
acceptOptimizedReturn(bool expectsNOP)
{
#if HAS_RETURNADDR_AUTORELEASE_ELISION
#   if __arm64__
    // Expected deltas are 1 instruction with no NOP, 2 instructions with a NOP.
    const uintptr_t expectedDeltaWithNOP = 8;
    const uintptr_t expectedDeltaNoNOP = 4;
#   else
#       error Unsupported architecture for return-address autorelease elision.
#   endif
    ReturnAutoreleaseInfo info = getReturnAutoreleaseInfo();
    if (info.isEmpty())
        return ReturnAtPlus0;

    setReturnAutoreleaseInfo({});  // reset to the unoptimized state

    uintptr_t previousReturnAddress = (uintptr_t)info.getReturnAddress();
    uintptr_t currentReturnAddress = (uintptr_t)clientReturnAddress();

    uintptr_t delta = currentReturnAddress - previousReturnAddress;

    uintptr_t expectedDelta = expectsNOP ? expectedDeltaWithNOP : expectedDeltaNoNOP;

    if (delta == expectedDelta)
        return info.getReturnDisposition();

    // If the delta is wrong, we may be in a situation like call, nop, add, claim.
    // Check the caller's code for the NOP as a fallback.
    if (expectsNOP) {
        if (callerAcceptsOptimizedReturn(info.getReturnAddress()))
            return info.getReturnDisposition();
    }

    // Handoff failed. If we're at +1, we need to move the value out of TLS and
    // into the main pool.
    if (info.getReturnDisposition() == ReturnAtPlus1)
        moveTLSAutoreleaseToPool(info);

    return ReturnAtPlus0;
#else
    ReturnAutoreleaseInfo info = getReturnAutoreleaseInfo();
    setReturnAutoreleaseInfo({});
    return info.getReturnDisposition();
#endif
}


// SUPPORT_RETURN_AUTORELEASE
#else
// not SUPPORT_RETURN_AUTORELEASE


static ALWAYS_INLINE bool
prepareOptimizedReturn(id obj __unused, bool cameFromRootAutorelease __unused, ReturnDisposition disposition __unused)
{
    return false;
}


static ALWAYS_INLINE ReturnDisposition 
acceptOptimizedReturn(bool expectsNOP __unused)
{
    return ReturnAtPlus0;
}


// not SUPPORT_RETURN_AUTORELEASE
#endif


// _OBJC_OBJECT_H_
#endif
