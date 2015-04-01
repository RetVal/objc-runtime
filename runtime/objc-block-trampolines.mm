/*
 * Copyright (c) 2010 Apple Inc.  All Rights Reserved.
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
 * objc-block-trampolines.m
 * Author:	b.bum
 *
 **********************************************************************/

/***********************************************************************
 * Imports.
 **********************************************************************/
#include "objc-private.h"
#include "runtime.h"

#include <Block.h>
#include <Block_private.h>
#include <mach/mach.h>

// symbols defined in assembly files
// Don't use the symbols directly; they're thumb-biased on some ARM archs.
#define TRAMP(tramp)                                \
    static inline uintptr_t tramp(void) {           \
        extern void *_##tramp;                      \
        return ((uintptr_t)&_##tramp) & ~1UL;       \
    }
// Scalar return
TRAMP(a1a2_tramphead);   // trampoline header code
TRAMP(a1a2_firsttramp);  // first trampoline
TRAMP(a1a2_nexttramp);   // second trampoline
TRAMP(a1a2_trampend);    // after the last trampoline

// Struct return
TRAMP(a2a3_tramphead);
TRAMP(a2a3_firsttramp);
TRAMP(a2a3_nexttramp);
TRAMP(a2a3_trampend);

// argument mode identifier
typedef enum {
    ReturnValueInRegisterArgumentMode,
    ReturnValueOnStackArgumentMode,
    
    ArgumentModeMax
} ArgumentMode;

// slot size is 8 bytes on both i386 and x86_64 (because of bytes-per-call instruction is > 4 for both)
#define SLOT_SIZE 8

// unsigned value, any value, larger thna # of blocks that fit in the page pair
#define LAST_SLOT_MARKER 4241

#define TRAMPOLINE_PAGE_PAIR_HEADER_SIZE (sizeof(uint32_t) + sizeof(struct _TrampolineBlockPagePair *) + sizeof(struct _TrampolineBlockPagePair *))
typedef struct _TrampolineBlockPagePair {
    struct _TrampolineBlockPagePair *nextPagePair; // linked list of all page pairs
    struct _TrampolineBlockPagePair *nextAvailablePage; // linked list of pages with available slots
    
    uint32_t nextAvailable; // index of next available slot, 0 if no more available

    // Data: block pointers and free list.
    // Bytes parallel with trampoline header are the fields above, or unused.
    uint8_t blocks[ PAGE_SIZE - TRAMPOLINE_PAGE_PAIR_HEADER_SIZE ] 
    __attribute__((unavailable)) /* always use _headerSize() */;

    // Code: trampoline header followed by trampolines.
    uint8_t trampolines[PAGE_SIZE];

    // Per-trampoline block data format:
    // initial value is 0 while page pair is filled sequentially (last slot is LAST_SLOT_MARKER to indicate end of page)
    // when filled, value is reference to Block_copy()d block
    // when empty, value is index of next available slot OR LAST_SLOT_MARKER

} TrampolineBlockPagePair;

// two sets of trampoline page pairs; one for stack returns and one for register returns
static TrampolineBlockPagePair *headPagePairs[2];

#pragma mark Utility Functions
static inline uint32_t _headerSize() {
    uint32_t headerSize = (uint32_t) (a1a2_firsttramp() - a1a2_tramphead());

    // make sure stret and non-stret sizes match
    assert(a2a3_firsttramp() - a2a3_tramphead() == headerSize);

    return headerSize;
}

static inline uint32_t _slotSize() {
    uint32_t slotSize = (uint32_t) (a1a2_nexttramp() - a1a2_firsttramp());

    // make sure stret and non-stret sizes match
    assert(a2a3_nexttramp() - a2a3_firsttramp() == slotSize);

    return slotSize;
}

static inline bool trampolinesAreThumb(void) {
    extern void *_a1a2_firsttramp;
#if !NDEBUG
    extern void *_a1a2_nexttramp;
    extern void *_a2a3_firsttramp;
    extern void *_a2a3_nexttramp;
#endif

    // make sure thumb-edness of all trampolines match
    assert(((uintptr_t)&_a1a2_firsttramp) % 2 == 
           ((uintptr_t)&_a2a3_firsttramp) % 2);
    assert(((uintptr_t)&_a1a2_firsttramp) % 2 == 
           ((uintptr_t)&_a1a2_nexttramp) % 2);
    assert(((uintptr_t)&_a1a2_firsttramp) % 2 == 
           ((uintptr_t)&_a2a3_nexttramp) % 2);

    return ((uintptr_t)&_a1a2_firsttramp) % 2;
}

static inline uint32_t _slotsPerPagePair() {
    uint32_t slotSize = _slotSize();
    uint32_t slotsPerPagePair = PAGE_SIZE / slotSize;
    return slotsPerPagePair;
}

static inline uint32_t _paddingSlotCount() {
    uint32_t headerSize = _headerSize();
    uint32_t slotSize = _slotSize();
    uint32_t paddingSlots = headerSize / slotSize;
    return paddingSlots;
}

static inline id *_payloadAddressAtIndex(TrampolineBlockPagePair *pagePair, uint32_t index) {
    uint32_t slotSize = _slotSize();
    uintptr_t baseAddress = (uintptr_t) pagePair; 
    uintptr_t payloadAddress = baseAddress + (slotSize * index);
    return (id *)payloadAddress;
}

static inline IMP _trampolineAddressAtIndex(TrampolineBlockPagePair *pagePair, uint32_t index) {
    uint32_t slotSize = _slotSize();
    uintptr_t baseAddress = (uintptr_t) &(pagePair->trampolines);
    uintptr_t trampolineAddress = baseAddress + (slotSize * index);

#if defined(__arm__)
    if (trampolinesAreThumb()) trampolineAddress++;
#endif

    return (IMP)trampolineAddress;
}

static inline void _lock() {
#if __OBJC2__
    rwlock_write(&runtimeLock);
#else
    mutex_lock(&classLock);
#endif
}

static inline void _unlock() {
#if __OBJC2__
    rwlock_unlock_write(&runtimeLock);
#else
    mutex_unlock(&classLock);
#endif
}

static inline void _assert_locked() {
#if __OBJC2__
    rwlock_assert_writing(&runtimeLock);
#else
    mutex_assert_locked(&classLock);
#endif
}

#pragma mark Trampoline Management Functions
static TrampolineBlockPagePair *_allocateTrampolinesAndData(ArgumentMode aMode) {    
    _assert_locked();

    vm_address_t dataAddress;
    
    // make sure certain assumptions are met
    assert(PAGE_SIZE == 4096);
    assert(sizeof(TrampolineBlockPagePair) == 2*PAGE_SIZE);
    assert(_slotSize() == 8);
    assert(_headerSize() >= TRAMPOLINE_PAGE_PAIR_HEADER_SIZE);
    assert((_headerSize() % _slotSize()) == 0);

    assert(a1a2_tramphead() % PAGE_SIZE == 0);
    assert(a1a2_tramphead() + PAGE_SIZE == a1a2_trampend());
    assert(a2a3_tramphead() % PAGE_SIZE == 0);
    assert(a2a3_tramphead() + PAGE_SIZE == a2a3_trampend());

    TrampolineBlockPagePair *headPagePair = headPagePairs[aMode];
    
    if (headPagePair) {
        assert(headPagePair->nextAvailablePage == NULL);
    }
    
    int i;
    kern_return_t result = KERN_FAILURE;
    for(i = 0; i < 5; i++) {
         result = vm_allocate(mach_task_self(), &dataAddress, PAGE_SIZE * 2, TRUE);
        if (result != KERN_SUCCESS) {
            mach_error("vm_allocate failed", result);
            return NULL;
        }

        vm_address_t codeAddress = dataAddress + PAGE_SIZE;
        result = vm_deallocate(mach_task_self(), codeAddress, PAGE_SIZE);
        if (result != KERN_SUCCESS) {
            mach_error("vm_deallocate failed", result);
            return NULL;
        }
        
        uintptr_t codePage;
        switch(aMode) {
            case ReturnValueInRegisterArgumentMode:
                codePage = a1a2_firsttramp() & ~(PAGE_MASK);
                break;
            case ReturnValueOnStackArgumentMode:
                codePage = a2a3_firsttramp() & ~(PAGE_MASK);
                break;
            default:
                _objc_fatal("unknown return mode %d", (int)aMode);
                break;
        }
        vm_prot_t currentProtection, maxProtection;
        result = vm_remap(mach_task_self(), &codeAddress, PAGE_SIZE, 0, FALSE, mach_task_self(),
                          codePage, TRUE, &currentProtection, &maxProtection, VM_INHERIT_SHARE);
        if (result != KERN_SUCCESS) {
            result = vm_deallocate(mach_task_self(), dataAddress, PAGE_SIZE);
            if (result != KERN_SUCCESS) {
                mach_error("vm_deallocate for retry failed.", result);
                return NULL;
            } 
        } else
            break;
    }
    
    if (result != KERN_SUCCESS)
        return NULL; 
    
    TrampolineBlockPagePair *pagePair = (TrampolineBlockPagePair *) dataAddress;
    pagePair->nextAvailable = _paddingSlotCount();
    pagePair->nextPagePair = NULL;
    pagePair->nextAvailablePage = NULL;
    id *lastPageBlockPtr = _payloadAddressAtIndex(pagePair, _slotsPerPagePair() - 1);
    *lastPageBlockPtr = (id)(uintptr_t) LAST_SLOT_MARKER;
    
    if (headPagePair) {
        TrampolineBlockPagePair *lastPage = headPagePair;
        while(lastPage->nextPagePair)
            lastPage = lastPage->nextPagePair;
        
        lastPage->nextPagePair = pagePair;
        headPagePairs[aMode]->nextAvailablePage = pagePair;
    } else {
        headPagePairs[aMode] = pagePair;
    }
    
    return pagePair;
}

static TrampolineBlockPagePair *_getOrAllocatePagePairWithNextAvailable(ArgumentMode aMode) {
    _assert_locked();
    
    TrampolineBlockPagePair *headPagePair = headPagePairs[aMode];

    if (!headPagePair)
        return _allocateTrampolinesAndData(aMode);
    
    if (headPagePair->nextAvailable) // make sure head page is filled first
        return headPagePair;
    
    if (headPagePair->nextAvailablePage) // check if there is a page w/a hole
        return headPagePair->nextAvailablePage;
    
    return _allocateTrampolinesAndData(aMode); // tack on a new one
}

static TrampolineBlockPagePair *_pagePairAndIndexContainingIMP(IMP anImp, uint32_t *outIndex, TrampolineBlockPagePair **outHeadPagePair) {
    _assert_locked();

    uintptr_t impValue = (uintptr_t) anImp;
    uint32_t i;

    for(i = 0; i < ArgumentModeMax; i++) {
        TrampolineBlockPagePair *pagePair = headPagePairs[i];
        
        while(pagePair) {
            uintptr_t startOfTrampolines = (uintptr_t) &(pagePair->trampolines);
            uintptr_t endOfTrampolines = ((uintptr_t) startOfTrampolines) + PAGE_SIZE;
            
            if ( (impValue >=startOfTrampolines) && (impValue <= endOfTrampolines) ) {
                if (outIndex) {
                    *outIndex = (uint32_t) ((impValue - startOfTrampolines) / SLOT_SIZE);
                }
                if (outHeadPagePair) {
                    *outHeadPagePair = headPagePairs[i];
                }
                return pagePair;
            }
            
            pagePair = pagePair->nextPagePair;
        }
    }
    
    return NULL;
}

// `block` must already have been copied 
static IMP _imp_implementationWithBlockNoCopy(ArgumentMode aMode, id block)
{
    _assert_locked();

    TrampolineBlockPagePair *pagePair = _getOrAllocatePagePairWithNextAvailable(aMode);
    if (!headPagePairs[aMode])
        headPagePairs[aMode] = pagePair;

    uint32_t index = pagePair->nextAvailable;
    id *payloadAddress = _payloadAddressAtIndex(pagePair, index);
    assert((index < 1024) || (index == LAST_SLOT_MARKER));
    
    uint32_t nextAvailableIndex = (uint32_t) *((uintptr_t *) payloadAddress);
    if (nextAvailableIndex == 0)
        // first time through, slots are filled with zeros, fill sequentially
        pagePair->nextAvailable = index + 1;
    else if (nextAvailableIndex == LAST_SLOT_MARKER) {
        // last slot is filled with this as marker
        // page now full, remove from available page linked list
        pagePair->nextAvailable = 0;
        TrampolineBlockPagePair *iteratorPair = headPagePairs[aMode];
        while(iteratorPair && (iteratorPair->nextAvailablePage != pagePair))
            iteratorPair = iteratorPair->nextAvailablePage;
        if (iteratorPair) {
            iteratorPair->nextAvailablePage = pagePair->nextAvailablePage;
            pagePair->nextAvailablePage = NULL;
        }
    } else {
        // empty slot at index contains pointer to next available index
        pagePair->nextAvailable = nextAvailableIndex;
    }
    
    *payloadAddress = block;
    IMP trampoline = _trampolineAddressAtIndex(pagePair, index);
    
    return trampoline;
}

static ArgumentMode _argumentModeForBlock(id block) {
    ArgumentMode aMode = ReturnValueInRegisterArgumentMode;
    
    if (_Block_has_signature(block) && _Block_use_stret(block))
        aMode = ReturnValueOnStackArgumentMode;
    
    return aMode;
}

#pragma mark Public API
IMP imp_implementationWithBlock(id block) 
{
    block = Block_copy(block);
    _lock();
    IMP returnIMP = _imp_implementationWithBlockNoCopy(_argumentModeForBlock(block), block);
    _unlock();
    return returnIMP;
}


id imp_getBlock(IMP anImp) {
    uint32_t index;
    TrampolineBlockPagePair *pagePair;
    
    if (!anImp) return NULL;
    
    _lock();
    
    pagePair = _pagePairAndIndexContainingIMP(anImp, &index, NULL);
    
    if (!pagePair) {
        _unlock();
        return NULL;
    }
    
    id potentialBlock = *_payloadAddressAtIndex(pagePair, index);
    
    if ((uintptr_t) potentialBlock == (uintptr_t) LAST_SLOT_MARKER) {
        _unlock();
        return NULL;
    }
    
    if ((uintptr_t) potentialBlock < (uintptr_t) _slotsPerPagePair()) {
        _unlock();
        return NULL;
    }
    
    _unlock();
    
    return potentialBlock;
}

BOOL imp_removeBlock(IMP anImp) {
    TrampolineBlockPagePair *pagePair;
    TrampolineBlockPagePair *headPagePair;
    uint32_t index;
    
    if (!anImp) return NO;
    
    _lock();
    pagePair = _pagePairAndIndexContainingIMP(anImp, &index, &headPagePair);
    
    if (!pagePair) {
        _unlock();
        return NO;
    }
    
    id *payloadAddress = _payloadAddressAtIndex(pagePair, index);
    id block = *payloadAddress;
    // block is released below
    
    if (pagePair->nextAvailable) {
        *payloadAddress = (id) (uintptr_t) pagePair->nextAvailable;
        pagePair->nextAvailable = index;
    } else {
        *payloadAddress = (id) (uintptr_t) LAST_SLOT_MARKER; // nada after this one is used
        pagePair->nextAvailable = index;
    }
    
    // make sure this page is on available linked list
    TrampolineBlockPagePair *pagePairIterator = headPagePair;
    
    // see if pagePair is the next available page for any existing pages
    while(pagePairIterator->nextAvailablePage && (pagePairIterator->nextAvailablePage != pagePair))
        pagePairIterator = pagePairIterator->nextAvailablePage;
    
    if (! pagePairIterator->nextAvailablePage) { // if iteration stopped because nextAvail was NULL
        // add to end of list.
        pagePairIterator->nextAvailablePage = pagePair;
        pagePair->nextAvailablePage = NULL;
    }
    
    _unlock();
    Block_release(block);
    return YES;
}
