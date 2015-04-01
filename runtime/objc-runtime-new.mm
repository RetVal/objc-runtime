/*
 * Copyright (c) 2005-2009 Apple Inc.  All Rights Reserved.
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
* objc-runtime-new.m
* Support for new-ABI classes and images.
**********************************************************************/

#if __OBJC2__

#include "objc-private.h"
#include "objc-runtime-new.h"
#include "objc-file.h"
#include <objc/message.h>
#include <mach/shared_region.h>

#define newcls(cls) ((class_t *)cls)
#define newmethod(meth) ((method_t *)meth)
#define newivar(ivar) ((ivar_t *)ivar)
#define newcategory(cat) ((category_t *)cat)
#define newprotocol(p) ((protocol_t *)p)
#define newproperty(p) ((property_t *)p)

static const char *getName(class_t *cls);
static uint32_t unalignedInstanceSize(class_t *cls);
static uint32_t alignedInstanceSize(class_t *cls);
static BOOL isMetaClass(class_t *cls);
static class_t *getSuperclass(class_t *cls);
static void detach_class(class_t *cls, BOOL isMeta);
static void free_class(class_t *cls);
static class_t *setSuperclass(class_t *cls, class_t *newSuper);
static class_t *realizeClass(class_t *cls);
static void flushCaches(class_t *cls);
static void flushVtables(class_t *cls);
static method_t *getMethodNoSuper_nolock(class_t *cls, SEL sel);
static method_t *getMethod_nolock(class_t *cls, SEL sel);
static void changeInfo(class_t *cls, unsigned int set, unsigned int clear);
static IMP _method_getImplementation(method_t *m);
static BOOL hasCxxStructors(class_t *cls);
static IMP addMethod(class_t *cls, SEL name, IMP imp, const char *types, BOOL replace);
static NXHashTable *realizedClasses(void);
static bool isRRSelector(SEL sel);
static bool isAWZSelector(SEL sel);
static void updateCustomRR_AWZ(class_t *cls, method_t *meth);
static method_t *search_method_list(const method_list_t *mlist, SEL sel);

id objc_noop_imp(id self, SEL _cmd __unused) {
    return self;
}

/***********************************************************************
* Lock management
* Every lock used anywhere must be managed here. 
* Locks not managed here may cause gdb deadlocks.
**********************************************************************/
rwlock_t runtimeLock;
rwlock_t selLock;
mutex_t cacheUpdateLock = MUTEX_INITIALIZER;
recursive_mutex_t loadMethodLock = RECURSIVE_MUTEX_INITIALIZER;
static int debugger_runtimeLock;
static int debugger_selLock;
static int debugger_cacheUpdateLock;
static int debugger_loadMethodLock;
#define RDONLY 1
#define RDWR 2

void lock_init(void)
{
    rwlock_init(&selLock);
    rwlock_init(&runtimeLock);
    recursive_mutex_init(&loadMethodLock);
}


/***********************************************************************
* startDebuggerMode
* Attempt to acquire some locks for debugger mode.
* Returns 0 if debugger mode failed because too many locks are unavailable.
*
* Locks successfully acquired are held until endDebuggerMode().
* Locks not acquired are off-limits until endDebuggerMode(); any 
*   attempt to manipulate them will cause a trap.
* Locks not handled here may cause deadlocks in gdb.
**********************************************************************/
int startDebuggerMode(void)
{
    int result = DEBUGGER_FULL;

    // runtimeLock is required (can't do much without it)
    if (rwlock_try_write(&runtimeLock)) {
        debugger_runtimeLock = RDWR;
    } else if (rwlock_try_read(&runtimeLock)) {
        debugger_runtimeLock = RDONLY;
        result = DEBUGGER_PARTIAL;
    } else {
        return DEBUGGER_OFF;
    }

    // cacheUpdateLock is required (must not fail a necessary cache flush)
    // must be AFTER runtimeLock to avoid lock inversion
    if (mutex_try_lock(&cacheUpdateLock)) {
        debugger_cacheUpdateLock = RDWR;
    } else {
        rwlock_unlock(&runtimeLock, debugger_runtimeLock);
        debugger_runtimeLock = 0;
        return DEBUGGER_OFF;
    }

    // side table locks are not optional
    if (!noSideTableLocksHeld()) {
        rwlock_unlock(&runtimeLock, debugger_runtimeLock);
        mutex_unlock(&cacheUpdateLock);
        debugger_runtimeLock = 0;
        return DEBUGGER_OFF;
    }
    
    // selLock is optional
    if (rwlock_try_write(&selLock)) {
        debugger_selLock = RDWR;
    } else if (rwlock_try_read(&selLock)) {
        debugger_selLock = RDONLY;
        result = DEBUGGER_PARTIAL;
    } else {
        debugger_selLock = 0;
        result = DEBUGGER_PARTIAL;
    }

    // loadMethodLock is optional
    if (recursive_mutex_try_lock(&loadMethodLock)) {
        debugger_loadMethodLock = RDWR;
    } else {
        debugger_loadMethodLock = 0;
        result = DEBUGGER_PARTIAL;
    }

    return result;
}

/***********************************************************************
* endDebuggerMode
* Relinquish locks acquired in startDebuggerMode().
**********************************************************************/
void endDebuggerMode(void)
{
    assert(debugger_runtimeLock != 0);

    rwlock_unlock(&runtimeLock, debugger_runtimeLock);
    debugger_runtimeLock = 0;

    rwlock_unlock(&selLock, debugger_selLock);
    debugger_selLock = 0;

    assert(debugger_cacheUpdateLock == RDWR);
    mutex_unlock(&cacheUpdateLock);
    debugger_cacheUpdateLock = 0;

    if (debugger_loadMethodLock) {
        recursive_mutex_unlock(&loadMethodLock);
        debugger_loadMethodLock = 0;
    }
}

/***********************************************************************
* isManagedDuringDebugger
* Returns YES if the given lock is handled specially during debugger 
* mode (i.e. debugger mode tries to acquire it).
**********************************************************************/
BOOL isManagedDuringDebugger(void *lock)
{
    if (lock == &selLock) return YES;
    if (lock == &cacheUpdateLock) return YES;
    if (lock == &runtimeLock) return YES;
    if (lock == &loadMethodLock) return YES;
    return NO;
}

/***********************************************************************
* isLockedDuringDebugger
* Returns YES if the given mutex was acquired by debugger mode.
* Locking a managed mutex during debugger mode causes a trap unless 
*   this returns YES.
**********************************************************************/
BOOL isLockedDuringDebugger(void *lock)
{
    assert(DebuggerMode);

    if (lock == &cacheUpdateLock) return YES;
    if (lock == (mutex_t *)&loadMethodLock) return YES;
    return NO;
}

/***********************************************************************
* isReadingDuringDebugger
* Returns YES if the given rwlock was read-locked by debugger mode.
* Read-locking a managed rwlock during debugger mode causes a trap unless
*   this returns YES.
**********************************************************************/
BOOL isReadingDuringDebugger(rwlock_t *lock)
{
    assert(DebuggerMode);
    
    // read-lock is allowed even if debugger mode actually write-locked it
    if (debugger_runtimeLock  &&  lock == &runtimeLock) return YES;
    if (debugger_selLock  &&  lock == &selLock) return YES;

    return NO;
}

/***********************************************************************
* isWritingDuringDebugger
* Returns YES if the given rwlock was write-locked by debugger mode.
* Write-locking a managed rwlock during debugger mode causes a trap unless
*   this returns YES.
**********************************************************************/
BOOL isWritingDuringDebugger(rwlock_t *lock)
{
    assert(DebuggerMode);
    
    if (debugger_runtimeLock == RDWR  &&  lock == &runtimeLock) return YES;
    if (debugger_selLock == RDWR  &&  lock == &selLock) return YES;

    return NO;
}


/***********************************************************************
* vtable dispatch
* 
* Every class gets a vtable pointer. The vtable is an array of IMPs.
* The selectors represented in the vtable are the same for all classes
*   (i.e. no class has a bigger or smaller vtable).
* Each vtable index has an associated trampoline which dispatches to 
*   the IMP at that index for the receiver class's vtable (after 
*   checking for NULL). Dispatch fixup uses these trampolines instead 
*   of objc_msgSend.
* Fragility: The vtable size and list of selectors is chosen at launch 
*   time. No compiler-generated code depends on any particular vtable 
*   configuration, or even the use of vtable dispatch at all.
* Memory size: If a class's vtable is identical to its superclass's 
*   (i.e. the class overrides none of the vtable selectors), then 
*   the class points directly to its superclass's vtable. This means 
*   selectors to be included in the vtable should be chosen so they are 
*   (1) frequently called, but (2) not too frequently overridden. In 
*   particular, -dealloc is a bad choice.
* Forwarding: If a class doesn't implement some vtable selector, that 
*   selector's IMP is set to objc_msgSend in that class's vtable.
* +initialize: Each class keeps the default vtable (which always 
*   redirects to objc_msgSend) until its +initialize is completed.
*   Otherwise, the first message to a class could be a vtable dispatch, 
*   and the vtable trampoline doesn't include +initialize checking.
* Changes: Categories, addMethod, and setImplementation all force vtable 
*   reconstruction for the class and all of its subclasses, if the 
*   vtable selectors are affected.
**********************************************************************/

/***********************************************************************
* ABI WARNING ABI WARNING ABI WARNING ABI WARNING ABI WARNING
* vtable_prototype on x86_64 steals %rax and does not clear %rdx on return
* This means vtable dispatch must never be used for vararg calls
* or very large return values.
* ABI WARNING ABI WARNING ABI WARNING ABI WARNING ABI WARNING
**********************************************************************/

#define X8(x) \
    x x x x x x x x
#define X64(x) \
    X8(x) X8(x) X8(x) X8(x) X8(x) X8(x) X8(x) X8(x)
#define X128(x) \
    X64(x) X64(x)

#define vtableMax 128

// hack to avoid conflicts with compiler's internal declaration
asm("\n .data"
    "\n .globl __objc_empty_vtable "
    "\n __objc_empty_vtable:"
#if __LP64__
    X128("\n .quad _objc_msgSend")
#else
    X128("\n .long _objc_msgSend")
#endif
    );

#if SUPPORT_VTABLE

// Trampoline descriptors for gdb.

objc_trampoline_header *gdb_objc_trampolines = NULL;

void gdb_objc_trampolines_changed(objc_trampoline_header *thdr) __attribute__((noinline));
void gdb_objc_trampolines_changed(objc_trampoline_header *thdr)
{
    rwlock_assert_writing(&runtimeLock);
    assert(thdr == gdb_objc_trampolines);

    if (PrintVtables) {
        _objc_inform("VTABLES: gdb_objc_trampolines_changed(%p)", thdr);
    }
}

// fixme workaround for rdar://6667753
static void appendTrampolines(objc_trampoline_header *thdr) __attribute__((noinline));

static void appendTrampolines(objc_trampoline_header *thdr)
{
    rwlock_assert_writing(&runtimeLock);
    assert(thdr->next == NULL);

    if (gdb_objc_trampolines != thdr->next) {
        thdr->next = gdb_objc_trampolines;
    }
    gdb_objc_trampolines = thdr;

    gdb_objc_trampolines_changed(thdr);
}

// Vtable management.

static size_t vtableStrlen;
static size_t vtableCount; 
static SEL *vtableSelectors;
static IMP *vtableTrampolines;
static const char * const defaultVtable[] = {
    "allocWithZone:", 
    "alloc", 
    "class", 
    "self", 
    "isKindOfClass:", 
    "respondsToSelector:", 
    "isFlipped", 
    "length", 
    "objectForKey:", 
    "count", 
    "objectAtIndex:", 
    "isEqualToString:", 
    "isEqual:", 
    "retain", 
    "release", 
    "autorelease", 
};
static const char * const defaultVtableGC[] = {
    "allocWithZone:", 
    "alloc", 
    "class", 
    "self", 
    "isKindOfClass:", 
    "respondsToSelector:", 
    "isFlipped", 
    "length", 
    "objectForKey:", 
    "count", 
    "objectAtIndex:", 
    "isEqualToString:", 
    "isEqual:", 
    "hash", 
    "addObject:", 
    "countByEnumeratingWithState:objects:count:", 
};

OBJC_EXTERN void objc_msgSend_vtable0(void);
OBJC_EXTERN void objc_msgSend_vtable1(void);
OBJC_EXTERN void objc_msgSend_vtable2(void);
OBJC_EXTERN void objc_msgSend_vtable3(void);
OBJC_EXTERN void objc_msgSend_vtable4(void);
OBJC_EXTERN void objc_msgSend_vtable5(void);
OBJC_EXTERN void objc_msgSend_vtable6(void);
OBJC_EXTERN void objc_msgSend_vtable7(void);
OBJC_EXTERN void objc_msgSend_vtable8(void);
OBJC_EXTERN void objc_msgSend_vtable9(void);
OBJC_EXTERN void objc_msgSend_vtable10(void);
OBJC_EXTERN void objc_msgSend_vtable11(void);
OBJC_EXTERN void objc_msgSend_vtable12(void);
OBJC_EXTERN void objc_msgSend_vtable13(void);
OBJC_EXTERN void objc_msgSend_vtable14(void);
OBJC_EXTERN void objc_msgSend_vtable15(void);

static IMP const defaultVtableTrampolines[] = {
    (IMP)objc_msgSend_vtable0, 
    (IMP)objc_msgSend_vtable1, 
    (IMP)objc_msgSend_vtable2, 
    (IMP)objc_msgSend_vtable3, 
    (IMP)objc_msgSend_vtable4, 
    (IMP)objc_msgSend_vtable5, 
    (IMP)objc_msgSend_vtable6, 
    (IMP)objc_msgSend_vtable7, 
    (IMP)objc_msgSend_vtable8, 
    (IMP)objc_msgSend_vtable9,  
    (IMP)objc_msgSend_vtable10, 
    (IMP)objc_msgSend_vtable11, 
    (IMP)objc_msgSend_vtable12, 
    (IMP)objc_msgSend_vtable13, 
    (IMP)objc_msgSend_vtable14, 
    (IMP)objc_msgSend_vtable15,
};
extern objc_trampoline_header defaultVtableTrampolineDescriptors;

static void check_vtable_size(void) __unused;
static void check_vtable_size(void)
{
    // Fail to compile if vtable sizes don't match.
    int c1[sizeof(defaultVtableTrampolines)-sizeof(defaultVtable)] __unused;
    int c2[sizeof(defaultVtable)-sizeof(defaultVtableTrampolines)] __unused;
    int c3[sizeof(defaultVtableTrampolines)-sizeof(defaultVtableGC)] __unused;
    int c4[sizeof(defaultVtableGC)-sizeof(defaultVtableTrampolines)] __unused;

    // Fail to compile if vtableMax is too small
    int c5[vtableMax - sizeof(defaultVtable)] __unused;
    int c6[vtableMax - sizeof(defaultVtableGC)] __unused;
}


extern uint8_t vtable_prototype;
extern uint8_t vtable_ignored;
extern int vtable_prototype_size;
extern int vtable_prototype_index_offset;
extern int vtable_prototype_index2_offset;
extern int vtable_prototype_tagtable_offset;
extern int vtable_prototype_tagtable_size;
static size_t makeVtableTrampoline(uint8_t *dst, size_t index)
{
    // copy boilerplate
    memcpy(dst, &vtable_prototype, vtable_prototype_size);
    
    // insert indexes
#if defined(__x86_64__)
    if (index > 255) _objc_fatal("vtable_prototype busted");
    {
        // `jmpq *0x7fff(%rax)`  ff a0 ff 7f
        uint16_t *p = (uint16_t *)(dst + vtable_prototype_index_offset + 2);
        if (*p != 0x7fff) _objc_fatal("vtable_prototype busted");
        *p = index * 8;
    }
    {
        uint16_t *p = (uint16_t *)(dst + vtable_prototype_index2_offset + 2);
        if (*p != 0x7fff) _objc_fatal("vtable_prototype busted");
        *p = index * 8;
    }
#else
#   warning unknown architecture
#endif

    // insert tagged isa table
#if defined(__x86_64__)
    {
        // `movq $0x1122334455667788, %r10`  49 ba 88 77 66 55 44 33 22 11
        if (vtable_prototype_tagtable_size != 10) {
            _objc_fatal("vtable_prototype busted");
        }
        uint8_t *p = (uint8_t *)(dst + vtable_prototype_tagtable_offset);
        if (*p++ != 0x49) _objc_fatal("vtable_prototype busted");
        if (*p++ != 0xba) _objc_fatal("vtable_prototype busted");
        if (*(uintptr_t *)p != 0x1122334455667788) {
            _objc_fatal("vtable_prototype busted");
        }
        uintptr_t addr = (uintptr_t)_objc_tagged_isa_table;
        memcpy(p, &addr, sizeof(addr));
    }
#else
#   warning unknown architecture
#endif

    return vtable_prototype_size;
}


static void initVtables(void)
{
    if (DisableVtables) {
        if (PrintVtables) {
            _objc_inform("VTABLES: vtable dispatch disabled by OBJC_DISABLE_VTABLES");
        }
        vtableCount = 0;
        vtableSelectors = NULL;
        vtableTrampolines = NULL;
        return;
    }

    const char * const *names;
    size_t i;

    if (UseGC) {
        names = defaultVtableGC;
        vtableCount = sizeof(defaultVtableGC) / sizeof(defaultVtableGC[0]);
    } else {
        names = defaultVtable;
        vtableCount = sizeof(defaultVtable) / sizeof(defaultVtable[0]);
    }
    if (vtableCount > vtableMax) vtableCount = vtableMax;

    vtableSelectors = (SEL*)_malloc_internal(vtableCount * sizeof(SEL));
    vtableTrampolines = (IMP*)_malloc_internal(vtableCount * sizeof(IMP));

    // Built-in trampolines and their descriptors

    size_t defaultVtableTrampolineCount = 
        sizeof(defaultVtableTrampolines) / sizeof(defaultVtableTrampolines[0]);
#ifndef NDEBUG
    // debug: use generated code for 3/4 of the table
    // Disabled even in Debug builds to avoid breaking backtrace symbol names.
    // defaultVtableTrampolineCount /= 4;
#endif

    for (i = 0; i < defaultVtableTrampolineCount && i < vtableCount; i++) {
        vtableSelectors[i] = sel_registerName(names[i]);
        vtableTrampolines[i] = defaultVtableTrampolines[i];
    }
    appendTrampolines(&defaultVtableTrampolineDescriptors);


    // Generated trampolines and their descriptors

    if (vtableCount > defaultVtableTrampolineCount) {
        // Memory for trampoline code
        size_t generatedCount = 
            vtableCount - defaultVtableTrampolineCount;

        const int align = 16;
        size_t codeSize = 
            round_page(sizeof(objc_trampoline_header) + align + 
                       generatedCount * (sizeof(objc_trampoline_descriptor) 
                                         + vtable_prototype_size + align));
        void *codeAddr = mmap(0, codeSize, PROT_READ|PROT_WRITE, 
                              MAP_PRIVATE|MAP_ANON, 
                              VM_MAKE_TAG(VM_MEMORY_OBJC_DISPATCHERS), 0);
        uint8_t *t = (uint8_t *)codeAddr;
        
        // Trampoline header
        objc_trampoline_header *thdr = (objc_trampoline_header *)t;
        thdr->headerSize = sizeof(objc_trampoline_header);
        thdr->descSize = sizeof(objc_trampoline_descriptor);
        thdr->descCount = (uint32_t)generatedCount;
        thdr->next = NULL;
        
        // Trampoline descriptors
        objc_trampoline_descriptor *tdesc = (objc_trampoline_descriptor *)(thdr+1);
        t = (uint8_t *)&tdesc[generatedCount];
        t += align - ((uintptr_t)t % align);
        
        // Dispatch code
        size_t tdi;
        for (i = defaultVtableTrampolineCount, tdi = 0; 
             i < vtableCount; 
             i++, tdi++) 
        {
            vtableSelectors[i] = sel_registerName(names[i]);
            if (ignoreSelector(vtableSelectors[i])) {
                vtableTrampolines[i] = (IMP)&vtable_ignored;
                tdesc[tdi].offset = 0;
                tdesc[tdi].flags = 0;
            } else {
                vtableTrampolines[i] = (IMP)t;
                tdesc[tdi].offset = 
                    (uint32_t)((uintptr_t)t - (uintptr_t)&tdesc[tdi]);
                tdesc[tdi].flags = 
                    OBJC_TRAMPOLINE_MESSAGE|OBJC_TRAMPOLINE_VTABLE;
                
                t += makeVtableTrampoline(t, i);
                t += align - ((uintptr_t)t % align);
            }
        }

        appendTrampolines(thdr);
        sys_icache_invalidate(codeAddr, codeSize);
        mprotect(codeAddr, codeSize, PROT_READ|PROT_EXEC);
    }


    if (PrintVtables) {
        for (i = 0; i < vtableCount; i++) {
            _objc_inform("VTABLES: vtable[%zu] %p %s", 
                         i, vtableTrampolines[i], 
                         sel_getName(vtableSelectors[i]));
        }
    }

    if (PrintVtableImages) {
        _objc_inform("VTABLE IMAGES: '#' implemented by class");
        _objc_inform("VTABLE IMAGES: '-' inherited from superclass");
        _objc_inform("VTABLE IMAGES: ' ' not implemented");
        for (i = 0; i <= vtableCount; i++) {
            char spaces[vtableCount+1+1];
            size_t j;
            for (j = 0; j < i; j++) {
                spaces[j] = '|';
            }
            spaces[j] = '\0';
            _objc_inform("VTABLE IMAGES: %s%s", spaces, 
                         i<vtableCount ? sel_getName(vtableSelectors[i]) : "");
        }
    }

    if (PrintVtables  ||  PrintVtableImages) {
        vtableStrlen = 0;
        for (i = 0; i < vtableCount; i++) {
            vtableStrlen += strlen(sel_getName(vtableSelectors[i]));
        }
    }
}


static int vtable_getIndex(SEL sel)
{
    unsigned int i;
    for (i = 0; i < vtableCount; i++) {
        if (vtableSelectors[i] == sel) return i;
    }
    return -1;
}

static BOOL vtable_containsSelector(SEL sel)
{
    return (vtable_getIndex(sel) < 0) ? NO : YES;
}

static void printVtableOverrides(class_t *cls, class_t *supercls)
{
    char overrideMap[vtableCount+1];
    unsigned int i;

    if (supercls) {
        size_t overridesBufferSize = vtableStrlen + 2*vtableCount + 1;
        char *overrides =
            (char *)_calloc_internal(overridesBufferSize, 1);
        for (i = 0; i < vtableCount; i++) {
            if (ignoreSelector(vtableSelectors[i])) {
                overrideMap[i] = '-';
                continue;
            }
            if (getMethodNoSuper_nolock(cls, vtableSelectors[i])) {
                strlcat(overrides, sel_getName(vtableSelectors[i]), overridesBufferSize);
                strlcat(overrides, ", ", overridesBufferSize);
                overrideMap[i] = '#';
            } else if (getMethod_nolock(cls, vtableSelectors[i])) {
                overrideMap[i] = '-';
            } else {
                overrideMap[i] = ' ';
            }
        }
        if (PrintVtables) {
            _objc_inform("VTABLES: %s%s implements %s", 
                         getName(cls), isMetaClass(cls) ? "(meta)" : "", 
                         overrides);
        }
        _free_internal(overrides);
    }
    else {
        for (i = 0; i < vtableCount; i++) {
            overrideMap[i] = '#';
        }
    }

    if (PrintVtableImages) {
        overrideMap[vtableCount] = '\0';
        _objc_inform("VTABLE IMAGES: %s  %s%s", overrideMap, 
                     getName(cls), isMetaClass(cls) ? "(meta)" : "");
    }
}

/***********************************************************************
* updateVtable
* Rebuilds vtable for cls, using superclass's vtable if appropriate.
* Assumes superclass's vtable is up to date. 
* Does nothing to subclass vtables.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void updateVtable(class_t *cls, BOOL force)
{
    rwlock_assert_writing(&runtimeLock);

    // Keep default vtable until +initialize is complete. 
    // Default vtable redirects to objc_msgSend, which 
    // enforces +initialize locking.
    if (!force  &&  !_class_isInitialized((Class)cls)) {
        /*
        if (PrintVtables) {
            _objc_inform("VTABLES: KEEPING DEFAULT vtable for "
                         "uninitialized class %s%s",
                         getName(cls), isMetaClass(cls) ? "(meta)" : "");
        }
        */
        return;
    }

    // Decide whether this class can share its superclass's vtable.

    class_t *supercls = getSuperclass(cls);
    BOOL needVtable = NO;
    unsigned int i;
    if (!supercls) {
        // Root classes always need a vtable
        needVtable = YES;
    } 
    else if (cls->data()->flags & RW_SPECIALIZED_VTABLE) {
        // Once you have your own vtable, you never go back
        needVtable = YES;
    } 
    else {
        for (i = 0; i < vtableCount; i++) {
            if (ignoreSelector(vtableSelectors[i])) continue;
            method_t *m = getMethodNoSuper_nolock(cls, vtableSelectors[i]);
            // assume any local implementation differs from super's
            if (m) {
                needVtable = YES;
                break;
            }
        }
    }

    // Build a vtable for this class, or not.

    if (!needVtable) {
        if (PrintVtables) {
            _objc_inform("VTABLES: USING SUPERCLASS vtable for class %s%s %p",
                         getName(cls), isMetaClass(cls) ? "(meta)" : "", cls);
        }
        cls->vtable = supercls->vtable;
    } 
    else {
        if (PrintVtables) {
            _objc_inform("VTABLES: %s vtable for class %s%s %p",
                         (cls->data()->flags & RW_SPECIALIZED_VTABLE) ? 
                         "UPDATING SPECIALIZED" : "CREATING SPECIALIZED", 
                         getName(cls), isMetaClass(cls) ? "(meta)" : "", cls);
        }
        if (PrintVtables  ||  PrintVtableImages) {
            printVtableOverrides(cls, supercls);
        }

        IMP *new_vtable;
        IMP *super_vtable = supercls ? supercls->vtable : &_objc_empty_vtable;
        // fixme use msgForward (instead of msgSend from empty vtable) ?

        if (cls->data()->flags & RW_SPECIALIZED_VTABLE) {
            // update cls->vtable in place
            new_vtable = cls->vtable;
            if (new_vtable == &_objc_empty_vtable) {
                // oops - our vtable is not as specialized as we thought
                // This is probably the broken memcpy of __NSCFConstantString.
                // rdar://8770551
                new_vtable = (IMP*)malloc(vtableCount * sizeof(IMP));
            }
            assert(new_vtable != &_objc_empty_vtable);
        } else {
            // make new vtable
            new_vtable = (IMP*)malloc(vtableCount * sizeof(IMP));
            changeInfo(cls, RW_SPECIALIZED_VTABLE, 0);
        }
        
        for (i = 0; i < vtableCount; i++) {
            if (ignoreSelector(vtableSelectors[i])) {
                new_vtable[i] = (IMP)&vtable_ignored;
            } else {
                method_t *m = getMethodNoSuper_nolock(cls, vtableSelectors[i]);
                if (m) new_vtable[i] = _method_getImplementation(m);
                else new_vtable[i] = super_vtable[i];
            }
        }

        if (cls->vtable != new_vtable) {
            // don't let other threads see uninitialized parts of new_vtable
            OSMemoryBarrier();
            cls->vtable = new_vtable;
        }
    }
}

// SUPPORT_VTABLE
#else
// !SUPPORT_VTABLE

static void initVtables(void)
{
    if (PrintVtables) {
        _objc_inform("VTABLES: no vtables on this architecture");
    }
}

static BOOL vtable_containsSelector(SEL sel)
{
    return NO;
}

static void updateVtable(class_t *cls, BOOL force)
{
}

// !SUPPORT_VTABLE
#endif

typedef struct {
    category_t *cat;
    BOOL fromBundle;
} category_pair_t;

typedef struct {
    uint32_t count;
    category_pair_t list[0];  // variable-size
} category_list;

#define FOREACH_METHOD_LIST(_mlist, _cls, code)                         \
    do {                                                                \
        const method_list_t *_mlist;                                    \
        if (_cls->data()->method_lists) {                               \
            if (_cls->data()->flags & RW_METHOD_ARRAY) {                \
                method_list_t **_mlistp;                                \
                for (_mlistp=_cls->data()->method_lists; *_mlistp; _mlistp++){\
                    _mlist = *_mlistp;                                  \
                    code                                                \
                }                                                       \
            } else {                                                    \
                _mlist = _cls->data()->method_list;                     \
                code                                                    \
            }                                                           \
        }                                                               \
    } while (0) 

#define FOREACH_REALIZED_CLASS_AND_SUBCLASS(_c, _cls, code)             \
    do {                                                                \
        rwlock_assert_writing(&runtimeLock);                            \
        class_t *_top = _cls;                                           \
        class_t *_c = _top;                                             \
        if (_c) {                                                       \
            while (1) {                                                 \
                code                                                    \
                if (_c->data()->firstSubclass) {                          \
                    _c = _c->data()->firstSubclass;                       \
                } else {                                                \
                    while (!_c->data()->nextSiblingClass  &&  _c != _top) { \
                        _c = getSuperclass(_c);                         \
                    }                                                   \
                    if (_c == _top) break;                              \
                    _c = _c->data()->nextSiblingClass;                    \
                }                                                       \
            }                                                           \
        } else {                                                        \
            /* nil means all realized classes */                        \
            NXHashTable *_classes = realizedClasses();                  \
            NXHashTable *_metaclasses = realizedMetaclasses();          \
            NXHashState _state;                                         \
            _state = NXInitHashState(_classes);                         \
            while (NXNextHashState(_classes, &_state, (void**)&_c))    \
            {                                                           \
                code                                                    \
            }                                                           \
            _state = NXInitHashState(_metaclasses);                     \
            while (NXNextHashState(_metaclasses, &_state, (void**)&_c)) \
            {                                                           \
                code                                                    \
            }                                                           \
        }                                                               \
    } while (0)


/*
  Low two bits of mlist->entsize is used as the fixed-up marker.
  PREOPTIMIZED VERSION:
    Fixed-up method lists get entsize&3 == 3.
    dyld shared cache sets this for method lists it preoptimizes.
  UN-PREOPTIMIZED VERSION:
    Fixed-up method lists get entsize&3 == 1. 
    dyld shared cache uses 3, but those aren't trusted.
*/

static uint32_t fixed_up_method_list = 3;

void
disableSharedCacheOptimizations(void)
{
    fixed_up_method_list = 1;
}

static BOOL isMethodListFixedUp(const method_list_t *mlist)
{
    return (mlist->entsize_NEVER_USE & 3) == fixed_up_method_list;
}

static void setMethodListFixedUp(method_list_t *mlist)
{
    rwlock_assert_writing(&runtimeLock);
    assert(!isMethodListFixedUp(mlist));
    mlist->entsize_NEVER_USE = (mlist->entsize_NEVER_USE & ~3) | fixed_up_method_list;
}

/*
static size_t chained_property_list_size(const chained_property_list *plist)
{
    return sizeof(chained_property_list) + 
        plist->count * sizeof(property_t);
}
*/

static size_t protocol_list_size(const protocol_list_t *plist)
{
    return sizeof(protocol_list_t) + plist->count * sizeof(protocol_t *);
}


// low bit used by dyld shared cache
static uint32_t method_list_entsize(const method_list_t *mlist)
{
    return mlist->entsize_NEVER_USE & ~(uint32_t)3;
}

static size_t method_list_size(const method_list_t *mlist)
{
    return sizeof(method_list_t) + (mlist->count-1)*method_list_entsize(mlist);
}

static method_t *method_list_nth(const method_list_t *mlist, uint32_t i)
{
    assert(i < mlist->count);
    return (method_t *)(i*method_list_entsize(mlist) + (char *)&mlist->first);
}

static uint32_t method_list_count(const method_list_t *mlist)
{
    return mlist ? mlist->count : 0;
}

static void method_list_swap(method_list_t *mlist, uint32_t i, uint32_t j)
{
    size_t entsize = method_list_entsize(mlist);
    char temp[entsize];
    memcpy(temp, method_list_nth(mlist, i), entsize);
    memcpy(method_list_nth(mlist, i), method_list_nth(mlist, j), entsize);
    memcpy(method_list_nth(mlist, j), temp, entsize);
}

static uint32_t method_list_index(const method_list_t *mlist,const method_t *m)
{
    uint32_t i = (uint32_t)(((uintptr_t)m - (uintptr_t)mlist) / method_list_entsize(mlist));
    assert(i < mlist->count);
    return i;
}


static size_t ivar_list_size(const ivar_list_t *ilist)
{
    return sizeof(ivar_list_t) + (ilist->count-1) * ilist->entsize;
}

static ivar_t *ivar_list_nth(const ivar_list_t *ilist, uint32_t i)
{
    return (ivar_t *)(i*ilist->entsize + (char *)&ilist->first);
}


// part of ivar_t, with non-deprecated alignment
typedef struct {
    uintptr_t *offset;
    const char *name;
    const char *type;
    uint32_t alignment;
} ivar_alignment_t;

static uint32_t ivar_alignment(const ivar_t *ivar)
{
    uint32_t alignment = ((ivar_alignment_t *)ivar)->alignment;
    if (alignment == (uint32_t)-1) alignment = (uint32_t)WORD_SHIFT;
    return 1<<alignment;
}


static method_list_t *cat_method_list(const category_t *cat, BOOL isMeta)
{
    if (!cat) return NULL;

    if (isMeta) return cat->classMethods;
    else return cat->instanceMethods;
}

static uint32_t cat_method_count(const category_t *cat, BOOL isMeta)
{
    method_list_t *cmlist = cat_method_list(cat, isMeta);
    return cmlist ? cmlist->count : 0;
}

static method_t *cat_method_nth(const category_t *cat, BOOL isMeta, uint32_t i)
{
    method_list_t *cmlist = cat_method_list(cat, isMeta);
    if (!cmlist) return NULL;
    
    return method_list_nth(cmlist, i);
}


static property_t *
property_list_nth(const property_list_t *plist, uint32_t i)
{
    return (property_t *)(i*plist->entsize + (char *)&plist->first);
}

// fixme don't chain property lists
typedef struct chained_property_list {
    struct chained_property_list *next;
    uint32_t count;
    property_t list[0];  // variable-size
} chained_property_list;


static void try_free(const void *p) 
{
    if (p && malloc_size(p)) free((void *)p);
}


/***********************************************************************
* make_ro_writeable
* Reallocates rw->ro if necessary to make it writeable.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static class_ro_t *make_ro_writeable(class_rw_t *rw)
{
    rwlock_assert_writing(&runtimeLock);

    if (rw->flags & RW_COPIED_RO) {
        // already writeable, do nothing
    } else {
        class_ro_t *ro = (class_ro_t *)
            _memdup_internal(rw->ro, sizeof(*rw->ro));
        rw->ro = ro;
        rw->flags |= RW_COPIED_RO;
    }
    return (class_ro_t *)rw->ro;
}


/***********************************************************************
* unattachedCategories
* Returns the class => categories map of unattached categories.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static NXMapTable *unattachedCategories(void)
{
    rwlock_assert_writing(&runtimeLock);

    static NXMapTable *category_map = NULL;

    if (category_map) return category_map;

    // fixme initial map size
    category_map = NXCreateMapTableFromZone(NXPtrValueMapPrototype, 16, 
                                            _objc_internal_zone());

    return category_map;
}


/***********************************************************************
* addUnattachedCategoryForClass
* Records an unattached category.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void addUnattachedCategoryForClass(category_t *cat, class_t *cls, 
                                          header_info *catHeader)
{
    rwlock_assert_writing(&runtimeLock);

    BOOL catFromBundle = (catHeader->mhdr->filetype == MH_BUNDLE) ? YES: NO;

    // DO NOT use cat->cls! cls may be cat->cls->isa instead
    NXMapTable *cats = unattachedCategories();
    category_list *list;

    list = (category_list *)NXMapGet(cats, cls);
    if (!list) {
        list = (category_list *)
            _calloc_internal(sizeof(*list) + sizeof(list->list[0]), 1);
    } else {
        list = (category_list *)
            _realloc_internal(list, sizeof(*list) + sizeof(list->list[0]) * (list->count + 1));
    }
    list->list[list->count++] = (category_pair_t){cat, catFromBundle};
    NXMapInsert(cats, cls, list);
}


/***********************************************************************
* removeUnattachedCategoryForClass
* Removes an unattached category.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void removeUnattachedCategoryForClass(category_t *cat, class_t *cls)
{
    rwlock_assert_writing(&runtimeLock);

    // DO NOT use cat->cls! cls may be cat->cls->isa instead
    NXMapTable *cats = unattachedCategories();
    category_list *list;

    list = (category_list *)NXMapGet(cats, cls);
    if (!list) return;

    uint32_t i;
    for (i = 0; i < list->count; i++) {
        if (list->list[i].cat == cat) {
            // shift entries to preserve list order
            memmove(&list->list[i], &list->list[i+1], 
                    (list->count-i-1) * sizeof(list->list[i]));
            list->count--;
            return;
        }
    }
}


/***********************************************************************
* unattachedCategoriesForClass
* Returns the list of unattached categories for a class, and 
* deletes them from the list. 
* The result must be freed by the caller. 
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static category_list *unattachedCategoriesForClass(class_t *cls)
{
    rwlock_assert_writing(&runtimeLock);
    return (category_list *)NXMapRemove(unattachedCategories(), cls);
}


/***********************************************************************
* isRealized
* Returns YES if class cls has been realized.
* Locking: To prevent concurrent realization, hold runtimeLock.
**********************************************************************/
static BOOL isRealized(class_t *cls)
{
    return (cls->data()->flags & RW_REALIZED) ? YES : NO;
}


/***********************************************************************
* isFuture
* Returns YES if class cls is an unrealized future class.
* Locking: To prevent concurrent realization, hold runtimeLock.
**********************************************************************/
#ifndef NDEBUG
// currently used in asserts only
static BOOL isFuture(class_t *cls)
{
    return (cls->data()->flags & RW_FUTURE) ? YES : NO;
}
#endif


/***********************************************************************
* classNSObject
* Returns class NSObject.
* Locking: none
**********************************************************************/
static class_t *classNSObject(void)
{
    extern class_t OBJC_CLASS_$_NSObject;
    return &OBJC_CLASS_$_NSObject;
}


/***********************************************************************
* printReplacements
* Implementation of PrintReplacedMethods / OBJC_PRINT_REPLACED_METHODS.
* Warn about methods from cats that override other methods in cats or cls.
* Assumes no methods from cats have been added to cls yet.
**********************************************************************/
static void printReplacements(class_t *cls, category_list *cats)
{
    uint32_t c;
    BOOL isMeta = isMetaClass(cls);

    if (!cats) return;

    // Newest categories are LAST in cats
    // Later categories override earlier ones.
    for (c = 0; c < cats->count; c++) {
        category_t *cat = cats->list[c].cat;
        uint32_t cmCount = cat_method_count(cat, isMeta);
        uint32_t m;
        for (m = 0; m < cmCount; m++) {
            uint32_t c2, m2;
            method_t *meth2 = NULL;
            method_t *meth = cat_method_nth(cat, isMeta, m);
            SEL s = sel_registerName((const char *)meth->name);

            // Don't warn about GC-ignored selectors
            if (ignoreSelector(s)) continue;
            
            // Look for method in earlier categories
            for (c2 = 0; c2 < c; c2++) {
                category_t *cat2 = cats->list[c2].cat;
                uint32_t cm2Count = cat_method_count(cat2, isMeta);
                for (m2 = 0; m2 < cm2Count; m2++) {
                    meth2 = cat_method_nth(cat2, isMeta, m2);
                    SEL s2 = sel_registerName((const char *)meth2->name);
                    if (s == s2) goto whine;
                }
            }

            // Look for method in cls
            FOREACH_METHOD_LIST(mlist, cls, {
                for (m2 = 0; m2 < mlist->count; m2++) {
                    meth2 = method_list_nth(mlist, m2);
                    SEL s2 = sel_registerName((const char *)meth2->name);
                    if (s == s2) goto whine;
                }
            });

            // Didn't find any override.
            continue;

        whine:
            // Found an override.
            logReplacedMethod(getName(cls), s, isMetaClass(cls), cat->name, 
                              _method_getImplementation(meth2), 
                              _method_getImplementation(meth));
        }
    }
}


static BOOL isBundleClass(class_t *cls)
{
    return (cls->data()->ro->flags & RO_FROM_BUNDLE) ? YES : NO;
}


static method_list_t *
fixupMethodList(method_list_t *mlist, bool bundleCopy, bool sort)
{
    assert(!isMethodListFixedUp(mlist));

    mlist = (method_list_t *)
        _memdup_internal(mlist, method_list_size(mlist));

    // fixme lock less in attachMethodLists ?
    sel_lock();

    // Unique selectors in list.
    uint32_t m;
    for (m = 0; m < mlist->count; m++) {
        method_t *meth = method_list_nth(mlist, m);
        SEL sel = sel_registerNameNoLock((const char *)meth->name, bundleCopy);
        meth->name = sel;

        if (ignoreSelector(sel)) {
            meth->imp = (IMP)&_objc_ignored_method;
        }
    }

    sel_unlock();

    // Sort by selector address.
    if (sort) {
        method_t::SortBySELAddress sorter;
        std::stable_sort(mlist->begin(), mlist->end(), sorter);
    }
    
    // Mark method list as uniqued and sorted
    setMethodListFixedUp(mlist);

    return mlist;
}


static void 
attachMethodLists(class_t *cls, method_list_t **addedLists, int addedCount, 
                  BOOL baseMethods, BOOL methodsFromBundle, 
                  BOOL *inoutVtablesAffected)
{
    rwlock_assert_writing(&runtimeLock);

    // Don't scan redundantly
    bool scanForCustomRR = !UseGC && !cls->hasCustomRR();
    bool scanForCustomAWZ = !UseGC && !cls->hasCustomAWZ();

    // RR special cases:
    // NSObject's base instance methods are not custom RR.
    // All other root classes are custom RR.
    // updateCustomRR_AWZ also knows about these cases.
    if (baseMethods && scanForCustomRR  &&  cls->isRootClass()) {
        if (cls != classNSObject()) {
            cls->setHasCustomRR();
        }
        scanForCustomRR = false;
    }

    // AWZ special cases:
    // NSObject's base class methods are not custom AWZ.
    // All other root metaclasses are custom AWZ.
    // updateCustomRR_AWZ also knows about these cases.
    if (baseMethods && scanForCustomAWZ  &&  cls->isRootMetaclass()) {
        if (cls != classNSObject()->isa) {
            cls->setHasCustomAWZ();
        }
        scanForCustomAWZ = false;
    }

    // Method list array is NULL-terminated.
    // Some elements of lists are NULL; we must filter them out.

    method_list_t *oldBuf[2];
    method_list_t **oldLists;
    int oldCount = 0;
    if (cls->data()->flags & RW_METHOD_ARRAY) {
        oldLists = cls->data()->method_lists;
    } else {
        oldBuf[0] = cls->data()->method_list;
        oldBuf[1] = NULL;
        oldLists = oldBuf;
    }
    if (oldLists) {
        while (oldLists[oldCount]) oldCount++;
    }
        
    int newCount = oldCount;
    for (int i = 0; i < addedCount; i++) {
        if (addedLists[i]) newCount++;  // only non-NULL entries get added
    }

    method_list_t *newBuf[2];
    method_list_t **newLists;
    if (newCount > 1) {
        newLists = (method_list_t **)
            _malloc_internal((1 + newCount) * sizeof(*newLists));
    } else {
        newLists = newBuf;
    }

    // Add method lists to array.
    // Reallocate un-fixed method lists.
    // The new methods are PREPENDED to the method list array.

    newCount = 0;
    int i;
    for (i = 0; i < addedCount; i++) {
        method_list_t *mlist = addedLists[i];
        if (!mlist) continue;

        // Fixup selectors if necessary
        if (!isMethodListFixedUp(mlist)) {
            mlist = fixupMethodList(mlist, methodsFromBundle, true/*sort*/);
        }

        // Scan for vtable updates
        if (inoutVtablesAffected  &&  !*inoutVtablesAffected) {
            uint32_t m;
            for (m = 0; m < mlist->count; m++) {
                SEL sel = method_list_nth(mlist, m)->name;
                if (vtable_containsSelector(sel)) {
                    *inoutVtablesAffected = YES;
                    break;
                }
            }
        }

        // Scan for method implementations tracked by the class's flags
        for (uint32_t m = 0; 
             (scanForCustomRR || scanForCustomAWZ)  &&  m < mlist->count; 
             m++) 
        {
            SEL sel = method_list_nth(mlist, m)->name;
            if (scanForCustomRR  &&  isRRSelector(sel)) {
                cls->setHasCustomRR();
                scanForCustomRR = false;
            } else if (scanForCustomAWZ  &&  isAWZSelector(sel)) {
                cls->setHasCustomAWZ();
                scanForCustomAWZ = false;
            } 
        }
        
        // Fill method list array
        newLists[newCount++] = mlist;
    }

    // Copy old methods to the method list array
    for (i = 0; i < oldCount; i++) {
        newLists[newCount++] = oldLists[i];
    }
    if (oldLists  &&  oldLists != oldBuf) free(oldLists);

    // NULL-terminate
    newLists[newCount] = NULL;

    if (newCount > 1) {
        assert(newLists != newBuf);
        cls->data()->method_lists = newLists;
        changeInfo(cls, RW_METHOD_ARRAY, 0);
    } else {
        assert(newLists == newBuf);
        cls->data()->method_list = newLists[0];
        assert(!(cls->data()->flags & RW_METHOD_ARRAY));
    }
}

static void 
attachCategoryMethods(class_t *cls, category_list *cats, 
                      BOOL *inoutVtablesAffected)
{
    if (!cats) return;
    if (PrintReplacedMethods) printReplacements(cls, cats);

    BOOL isMeta = isMetaClass(cls);
    method_list_t **mlists = (method_list_t **)
        _malloc_internal(cats->count * sizeof(*mlists));

    // Count backwards through cats to get newest categories first
    int mcount = 0;
    int i = cats->count;
    BOOL fromBundle = NO;
    while (i--) {
        method_list_t *mlist = cat_method_list(cats->list[i].cat, isMeta);
        if (mlist) {
            mlists[mcount++] = mlist;
            fromBundle |= cats->list[i].fromBundle;
        }
    }

    attachMethodLists(cls, mlists, mcount, NO, fromBundle, inoutVtablesAffected);

    _free_internal(mlists);

}


static chained_property_list *
buildPropertyList(const property_list_t *plist, category_list *cats, BOOL isMeta)
{
    chained_property_list *newlist;
    uint32_t count = 0;
    uint32_t p, c;

    // Count properties in all lists.
    if (plist) count = plist->count;
    if (cats) {
        for (c = 0; c < cats->count; c++) {
            category_t *cat = cats->list[c].cat;
            /*
            if (isMeta  &&  cat->classProperties) {
                count += cat->classProperties->count;
            } 
            else*/
            if (!isMeta  &&  cat->instanceProperties) {
                count += cat->instanceProperties->count;
            }
        }
    }
    
    if (count == 0) return NULL;

    // Allocate new list. 
    newlist = (chained_property_list *)
        _malloc_internal(sizeof(*newlist) + count * sizeof(property_t));
    newlist->count = 0;
    newlist->next = NULL;

    // Copy properties; newest categories first, then ordinary properties
    if (cats) {
        c = cats->count;
        while (c--) {
            property_list_t *cplist;
            category_t *cat = cats->list[c].cat;
            /*
            if (isMeta) {
                cplist = cat->classProperties;
                } else */
            {
                cplist = cat->instanceProperties;
            }
            if (cplist) {
                for (p = 0; p < cplist->count; p++) {
                    newlist->list[newlist->count++] = 
                        *property_list_nth(cplist, p);
                }
            }
        }
    }
    if (plist) {
        for (p = 0; p < plist->count; p++) {
            newlist->list[newlist->count++] = *property_list_nth(plist, p);
        }
    }

    assert(newlist->count == count);

    return newlist;
}


static const protocol_list_t **
buildProtocolList(category_list *cats, const protocol_list_t *base, 
                  const protocol_list_t **protos)
{
    const protocol_list_t **p, **newp;
    const protocol_list_t **newprotos;
    unsigned int count = 0;
    unsigned int i;

    // count protocol list in base
    if (base) count++;

    // count protocol lists in cats
    if (cats) for (i = 0; i < cats->count; i++) {
        category_t *cat = cats->list[i].cat;
        if (cat->protocols) count++;
    }

    // no base or category protocols? return existing protocols unchanged
    if (count == 0) return protos;

    // count protocol lists in protos
    for (p = protos; p  &&  *p; p++) {
        count++;
    }

    if (count == 0) return NULL;
    
    newprotos = (const protocol_list_t **)
        _malloc_internal((count+1) * sizeof(protocol_list_t *));
    newp = newprotos;

    if (base) {
        *newp++ = base;
    }

    for (p = protos; p  &&  *p; p++) {
        *newp++ = *p;
    }
    
    if (cats) for (i = 0; i < cats->count; i++) {
        category_t *cat = cats->list[i].cat;
        if (cat->protocols) {
            *newp++ = cat->protocols;
        }
    }

    *newp = NULL;

    return newprotos;
}


/***********************************************************************
* methodizeClass
* Fixes up cls's method list, protocol list, and property list.
* Attaches any outstanding categories.
* Builds vtable.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void methodizeClass(class_t *cls)
{
    category_list *cats;
    BOOL isMeta;

    rwlock_assert_writing(&runtimeLock);

    isMeta = isMetaClass(cls);

    // Methodizing for the first time
    if (PrintConnecting) {
        _objc_inform("CLASS: methodizing class '%s' %s", 
                     getName(cls), isMeta ? "(meta)" : "");
    }
    
    // Build method and protocol and property lists.
    // Include methods and protocols and properties from categories, if any

    attachMethodLists(cls, (method_list_t **)&cls->data()->ro->baseMethods, 1, 
                      YES, isBundleClass(cls), NULL);

    // Root classes get bonus method implementations if they don't have 
    // them already. These apply before category replacements.

    if (cls->isRootMetaclass()) {
        // root metaclass
        addMethod(cls, SEL_initialize, (IMP)&objc_noop_imp, "", NO);
    }

    cats = unattachedCategoriesForClass(cls);
    attachCategoryMethods(cls, cats, NULL);

    if (cats  ||  cls->data()->ro->baseProperties) {
        cls->data()->properties = 
            buildPropertyList(cls->data()->ro->baseProperties, cats, isMeta);
    }
    
    if (cats  ||  cls->data()->ro->baseProtocols) {
        cls->data()->protocols = 
            buildProtocolList(cats, cls->data()->ro->baseProtocols, NULL);
    }

    if (PrintConnecting) {
        uint32_t i;
        if (cats) {
            for (i = 0; i < cats->count; i++) {
                _objc_inform("CLASS: attached category %c%s(%s)", 
                             isMeta ? '+' : '-', 
                             getName(cls), cats->list[i].cat->name);
            }
        }
    }
    
    if (cats) _free_internal(cats);

    // No vtable until +initialize completes
    // Cause error in 10.10, so comment it to make the program run, problem may be introduced.
    // assert(cls->vtable == &_objc_empty_vtable);

#ifndef NDEBUG
    // Debug: sanity-check all SELs; log method list contents
    FOREACH_METHOD_LIST(mlist, cls, {
        method_list_t::method_iterator iter = mlist->begin();
        method_list_t::method_iterator end = mlist->end();
        for ( ; iter != end; ++iter) {
            if (PrintConnecting) {
                _objc_inform("METHOD %c[%s %s]", isMeta ? '+' : '-', 
                             getName(cls), sel_getName(iter->name));
            }
            assert(ignoreSelector(iter->name)  ||  sel_registerName(sel_getName(iter->name))==iter->name); 
        }
    });
#endif
}


/***********************************************************************
* remethodizeClass
* Attach outstanding categories to an existing class.
* Fixes up cls's method list, protocol list, and property list.
* Updates method caches and vtables for cls and its subclasses.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void remethodizeClass(class_t *cls)
{
    category_list *cats;
    BOOL isMeta;

    rwlock_assert_writing(&runtimeLock);

    isMeta = isMetaClass(cls);

    // Re-methodizing: check for more categories
    if ((cats = unattachedCategoriesForClass(cls))) {
        chained_property_list *newproperties;
        const protocol_list_t **newprotos;
        
        if (PrintConnecting) {
            _objc_inform("CLASS: attaching categories to class '%s' %s", 
                         getName(cls), isMeta ? "(meta)" : "");
        }
        
        // Update methods, properties, protocols
        
        BOOL vtableAffected = NO;
        attachCategoryMethods(cls, cats, &vtableAffected);
        
        newproperties = buildPropertyList(NULL, cats, isMeta);
        if (newproperties) {
            newproperties->next = cls->data()->properties;
            cls->data()->properties = newproperties;
        }
        
        newprotos = buildProtocolList(cats, NULL, cls->data()->protocols);
        if (cls->data()->protocols  &&  cls->data()->protocols != newprotos) {
            _free_internal(cls->data()->protocols);
        }
        cls->data()->protocols = newprotos;
        
        _free_internal(cats);

        // Update method caches and vtables
        flushCaches(cls);
        if (vtableAffected) flushVtables(cls);
    }
}


/***********************************************************************
* changeInfo
* Atomically sets and clears some bits in cls's info field.
* set and clear must not overlap.
**********************************************************************/
static void changeInfo(class_t *cls, unsigned int set, unsigned int clear)
{
    uint32_t oldf, newf;

    assert(isFuture(cls)  ||  isRealized(cls));

    do {
        oldf = cls->data()->flags;
        newf = (oldf | set) & ~clear;
    } while (!OSAtomicCompareAndSwap32Barrier(oldf, newf, (volatile int32_t *)&cls->data()->flags));
}


/***********************************************************************
* getClass
* Looks up a class by name. The class MIGHT NOT be realized.
* Locking: runtimeLock must be read- or write-locked by the caller.
**********************************************************************/

// This is a misnomer: gdb_objc_realized_classes is actually a list of 
// named classes not in the dyld shared cache, whether realized or not.
NXMapTable *gdb_objc_realized_classes;  // exported for debuggers in objc-gdb.h

static class_t *getClass(const char *name)
{
    rwlock_assert_locked(&runtimeLock);

    // allocated in _read_images
    assert(gdb_objc_realized_classes);

    // Try runtime-allocated table
    class_t *result = (class_t *)NXMapGet(gdb_objc_realized_classes, name);
    if (result) return result;

    // Try table from dyld shared cache
    return getPreoptimizedClass(name);
}


/***********************************************************************
* addNamedClass
* Adds name => cls to the named non-meta class map.
* Warns about duplicate class names and keeps the old mapping.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void addNamedClass(class_t *cls, const char *name)
{
    rwlock_assert_writing(&runtimeLock);
    class_t *old;
    if ((old = getClass(name))) {
        inform_duplicate(name, (Class)old, (Class)cls);
    } else {
        NXMapInsert(gdb_objc_realized_classes, name, cls);
    }
    assert(!(cls->data()->flags & RO_META));

    // wrong: constructed classes are already realized when they get here
    // assert(!isRealized(cls));
}


/***********************************************************************
* removeNamedClass
* Removes cls from the name => cls map.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void removeNamedClass(class_t *cls, const char *name)
{
    rwlock_assert_writing(&runtimeLock);
    assert(!(cls->data()->flags & RO_META));
    if (cls == NXMapGet(gdb_objc_realized_classes, name)) {
        NXMapRemove(gdb_objc_realized_classes, name);
    } else {
        // cls has a name collision with another class - don't remove the other
    }
}


/***********************************************************************
* realizedClasses
* Returns the class list for realized non-meta classes.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static NXHashTable *realized_class_hash = NULL;

static NXHashTable *realizedClasses(void)
{    
    rwlock_assert_locked(&runtimeLock);

    // allocated in _read_images
    assert(realized_class_hash);

    return realized_class_hash;
}


/***********************************************************************
* realizedMetaclasses
* Returns the class list for realized metaclasses.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static NXHashTable *realized_metaclass_hash = NULL;
static NXHashTable *realizedMetaclasses(void)
{    
    rwlock_assert_locked(&runtimeLock);

    // allocated in _read_images
    assert(realized_metaclass_hash);

    return realized_metaclass_hash;
}


/***********************************************************************
* addRealizedClass
* Adds cls to the realized non-meta class hash.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void addRealizedClass(class_t *cls)
{
    rwlock_assert_writing(&runtimeLock);
    void *old;
    old = NXHashInsert(realizedClasses(), cls);
    objc_addRegisteredClass((Class)cls);
    assert(!isMetaClass(cls));
    assert(!old);
}


/***********************************************************************
* removeRealizedClass
* Removes cls from the realized non-meta class hash.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void removeRealizedClass(class_t *cls)
{
    rwlock_assert_writing(&runtimeLock);
    if (isRealized(cls)) {
        assert(!isMetaClass(cls));
        NXHashRemove(realizedClasses(), cls);
        objc_removeRegisteredClass((Class)cls);
    }
}


/***********************************************************************
* addRealizedMetaclass
* Adds cls to the realized metaclass hash.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void addRealizedMetaclass(class_t *cls)
{
    rwlock_assert_writing(&runtimeLock);
    void *old;
    old = NXHashInsert(realizedMetaclasses(), cls);
    assert(isMetaClass(cls));
    assert(!old);
}


/***********************************************************************
* removeRealizedMetaclass
* Removes cls from the realized metaclass hash.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void removeRealizedMetaclass(class_t *cls)
{
    rwlock_assert_writing(&runtimeLock);
    if (isRealized(cls)) {
        assert(isMetaClass(cls));
        NXHashRemove(realizedMetaclasses(), cls);
    }
}


/***********************************************************************
* futureNamedClasses
* Returns the classname => future class map for unrealized future classes.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static NXMapTable *futureNamedClasses(void)
{
    rwlock_assert_writing(&runtimeLock);

    static NXMapTable *future_named_class_map = NULL;
    
    if (future_named_class_map) return future_named_class_map;

    // future_named_class_map is big enough for CF's classes and a few others
    future_named_class_map = 
        NXCreateMapTableFromZone(NXStrValueMapPrototype, 32,
                                 _objc_internal_zone());

    return future_named_class_map;
}


/***********************************************************************
* addFutureNamedClass
* Installs cls as the class structure to use for the named class if it appears.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void addFutureNamedClass(const char *name, class_t *cls)
{
    void *old;

    rwlock_assert_writing(&runtimeLock);

    if (PrintFuture) {
        _objc_inform("FUTURE: reserving %p for %s", cls, name);
    }

    cls->setData((class_rw_t *)_calloc_internal(sizeof(*cls->data()), 1));
    cls->data()->flags = RO_FUTURE;

    old = NXMapKeyCopyingInsert(futureNamedClasses(), name, cls);
    assert(!old);
}


/***********************************************************************
* removeFutureNamedClass
* Removes the named class from the unrealized future class list, 
* because it has been realized.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void removeFutureNamedClass(const char *name)
{
    rwlock_assert_writing(&runtimeLock);

    NXMapKeyFreeingRemove(futureNamedClasses(), name);
}


/***********************************************************************
* remappedClasses
* Returns the oldClass => newClass map for realized future classes.
* Returns the oldClass => NULL map for ignored weak-linked classes.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static NXMapTable *remappedClasses(BOOL create)
{
    static NXMapTable *remapped_class_map = NULL;

    rwlock_assert_locked(&runtimeLock);

    if (remapped_class_map) return remapped_class_map;
    if (!create) return NULL;

    // remapped_class_map is big enough to hold CF's classes and a few others
    INIT_ONCE_PTR(remapped_class_map, 
                  NXCreateMapTableFromZone(NXPtrValueMapPrototype, 32, 
                                           _objc_internal_zone()), 
                  NXFreeMapTable(v));

    return remapped_class_map;
}


/***********************************************************************
* noClassesRemapped
* Returns YES if no classes have been remapped
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static BOOL noClassesRemapped(void)
{
    rwlock_assert_locked(&runtimeLock);

    BOOL result = (remappedClasses(NO) == NULL);
    return result;
}


/***********************************************************************
* addRemappedClass
* newcls is a realized future class, replacing oldcls.
* OR newcls is NULL, replacing ignored weak-linked class oldcls.
* Locking: runtimeLock must be write-locked by the caller
**********************************************************************/
static void addRemappedClass(class_t *oldcls, class_t *newcls)
{
    rwlock_assert_writing(&runtimeLock);

    if (PrintFuture) {
        _objc_inform("FUTURE: using %p instead of %p for %s", 
                     oldcls, newcls, getName(oldcls));
    }

    void *old;
    old = NXMapInsert(remappedClasses(YES), oldcls, newcls);
    assert(!old);
}


/***********************************************************************
* remapClass
* Returns the live class pointer for cls, which may be pointing to 
* a class struct that has been reallocated.
* Returns NULL if cls is ignored because of weak linking.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static class_t *remapClass(class_t *cls)
{
    rwlock_assert_locked(&runtimeLock);

    class_t *c2;

    if (!cls) return NULL;

    if (NXMapMember(remappedClasses(YES), cls, (void**)&c2) == NX_MAPNOTAKEY) {
        return cls;
    } else {
        return c2;
    }
}

static class_t *remapClass(classref_t cls)
{
    return remapClass((class_t *)cls);
}

Class _class_remap(Class cls_gen)
{
    rwlock_read(&runtimeLock);
    Class result = (Class)remapClass(newcls(cls_gen));
    rwlock_unlock_read(&runtimeLock);
    return result;
}

/***********************************************************************
* remapClassRef
* Fix up a class ref, in case the class referenced has been reallocated 
* or is an ignored weak-linked class.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static void remapClassRef(class_t **clsref)
{
    rwlock_assert_locked(&runtimeLock);

    class_t *newcls = remapClass(*clsref);    
    if (*clsref != newcls) *clsref = newcls;
}


/***********************************************************************
* nonMetaClasses
* Returns the memoized metaclass => class map
* Used for some cases of +initialize.
* This map does not contain all classes and metaclasses. It only 
* contains memoized results from the slow path in getNonMetaClass(), 
* and classes that the slow path can't find (like objc_registerClassPair).
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static NXMapTable *nonmeta_class_map = NULL;
static NXMapTable *nonMetaClasses(void)
{
    rwlock_assert_locked(&runtimeLock);

    if (nonmeta_class_map) return nonmeta_class_map;

    // nonmeta_class_map is typically small
    INIT_ONCE_PTR(nonmeta_class_map, 
                  NXCreateMapTableFromZone(NXPtrValueMapPrototype, 32, 
                                           _objc_internal_zone()), 
                  NXFreeMapTable(v));

    return nonmeta_class_map;
}


/***********************************************************************
* addNonMetaClass
* Adds metacls => cls to the memoized metaclass map
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void addNonMetaClass(class_t *cls)
{
    rwlock_assert_writing(&runtimeLock);
    void *old;
    old = NXMapInsert(nonMetaClasses(), cls->isa, cls);

    assert(isRealized(cls));
    assert(isRealized(cls->isa));
    assert(!isMetaClass(cls));
    assert(isMetaClass(cls->isa));
    assert(!old);
}


static void removeNonMetaClass(class_t *cls)
{
    rwlock_assert_writing(&runtimeLock);
    NXMapRemove(nonMetaClasses(), cls->isa);
}


/***********************************************************************
* getNonMetaClass
* Return the ordinary class for this class or metaclass. 
* `inst` is an instance of `cls` or a subclass thereof, or nil. 
* Non-nil inst is faster.
* Used by +initialize. 
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static class_t *getNonMetaClass(class_t *metacls, id inst)
{
    static int total, slow, memo;
    rwlock_assert_locked(&runtimeLock);

    realizeClass(metacls);

    total++;

    // return cls itself if it's already a non-meta class
    if (!isMetaClass(metacls)) return metacls;

    // metacls really is a metaclass

    // special case for root metaclass
    // where inst == inst->isa == metacls is possible
    if (metacls->isa == metacls) {
        class_t *cls = metacls->superclass;
        assert(isRealized(cls));
        assert(!isMetaClass(cls));
        assert(cls->isa == metacls);
        if (cls->isa == metacls) return cls;
    }

    // use inst if available
    if (inst) {
        class_t *cls = (class_t *)inst;
        realizeClass(cls);
        // cls may be a subclass - find the real class for metacls
        while (cls  &&  cls->isa != metacls) {
            cls = cls->superclass;
            realizeClass(cls);
        }
        if (cls) {
            assert(!isMetaClass(cls));
            assert(cls->isa == metacls);
            return cls;
        }
#if !NDEBUG
        _objc_fatal("cls is not an instance of metacls");
#else
        // release build: be forgiving and fall through to slow lookups
#endif
    }

    // try memoized table
    class_t *cls = (class_t *)NXMapGet(nonMetaClasses(), metacls);
    if (cls) {
        memo++;
        if (PrintInitializing) {
            _objc_inform("INITIALIZE: %d/%d (%g%%) memoized metaclass lookups",
                         memo, total, memo*100.0/total);
        }

        assert(isRealized(cls));
        assert(!isMetaClass(cls));
        assert(cls->isa == metacls);
        return cls;
    }

    // try slow lookup
    slow++;
    if (PrintInitializing) {
        _objc_inform("INITIALIZE: %d/%d (%g%%) slow metaclass lookups", 
                     slow, total, slow*100.0/total);
    }

    for (header_info *hi = FirstHeader; hi; hi = hi->next) {
        size_t count;
        classref_t *classlist = _getObjc2ClassList(hi, &count);
        for (size_t i = 0; i < count; i++) {
            cls = remapClass(classlist[i]);
            if (cls  &&  cls->isa == metacls) {
                // memoize result
                realizeClass(cls);
                addNonMetaClass(cls);
                return cls;
            }
        }
    }

    _objc_fatal("no class for metaclass %p", metacls);

    return cls;
}


/***********************************************************************
* _class_getNonMetaClass
* Return the ordinary class for this class or metaclass. 
* Used by +initialize. 
* Locking: acquires runtimeLock
**********************************************************************/
Class _class_getNonMetaClass(Class cls_gen, id obj)
{
    class_t *cls = newcls(cls_gen);
    rwlock_write(&runtimeLock);
    cls = getNonMetaClass(cls, obj);
    assert(isRealized(cls));
    rwlock_unlock_write(&runtimeLock);
    
    return (Class)cls;
}


/***********************************************************************
* addSubclass
* Adds subcls as a subclass of supercls.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void addSubclass(class_t *supercls, class_t *subcls)
{
    rwlock_assert_writing(&runtimeLock);

    if (supercls  &&  subcls) {
        assert(isRealized(supercls));
        assert(isRealized(subcls));
        subcls->data()->nextSiblingClass = supercls->data()->firstSubclass;
        supercls->data()->firstSubclass = subcls;

        if (supercls->data()->flags & RW_HAS_CXX_STRUCTORS) {
            subcls->data()->flags |= RW_HAS_CXX_STRUCTORS;
        }

        if (supercls->hasCustomRR()) {
            subcls->setHasCustomRR(true);
        }

        if (supercls->hasCustomAWZ()) {
            subcls->setHasCustomAWZ(true);
        }
    }
}


/***********************************************************************
* removeSubclass
* Removes subcls as a subclass of supercls.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void removeSubclass(class_t *supercls, class_t *subcls)
{
    rwlock_assert_writing(&runtimeLock);
    assert(isRealized(supercls));
    assert(isRealized(subcls));
    assert(getSuperclass(subcls) == supercls);

    class_t **cp;
    for (cp = &supercls->data()->firstSubclass; 
         *cp  &&  *cp != subcls; 
         cp = &(*cp)->data()->nextSiblingClass)
        ;
    assert(*cp == subcls);
    *cp = subcls->data()->nextSiblingClass;
}



/***********************************************************************
* protocols
* Returns the protocol name => protocol map for protocols.
* Locking: runtimeLock must read- or write-locked by the caller
**********************************************************************/
static NXMapTable *protocols(void)
{
    static NXMapTable *protocol_map = NULL;
    
    rwlock_assert_locked(&runtimeLock);

    INIT_ONCE_PTR(protocol_map, 
                  NXCreateMapTableFromZone(NXStrValueMapPrototype, 16, 
                                           _objc_internal_zone()), 
                  NXFreeMapTable(v) );

    return protocol_map;
}


/***********************************************************************
* remapProtocol
* Returns the live protocol pointer for proto, which may be pointing to 
* a protocol struct that has been reallocated.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static protocol_t *remapProtocol(protocol_ref_t proto)
{
    rwlock_assert_locked(&runtimeLock);

    protocol_t *newproto = (protocol_t *)
        NXMapGet(protocols(), ((protocol_t *)proto)->name);
    return newproto ? newproto : (protocol_t *)proto;
}


/***********************************************************************
* remapProtocolRef
* Fix up a protocol ref, in case the protocol referenced has been reallocated.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static void remapProtocolRef(protocol_t **protoref)
{
    rwlock_assert_locked(&runtimeLock);

    protocol_t *newproto = remapProtocol((protocol_ref_t)*protoref);
    if (*protoref != newproto) *protoref = newproto;
}


/***********************************************************************
* moveIvars
* Slides a class's ivars to accommodate the given superclass size.
* Also slides ivar and weak GC layouts if provided.
* Ivars are NOT compacted to compensate for a superclass that shrunk.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void moveIvars(class_ro_t *ro, uint32_t superSize, 
                      layout_bitmap *ivarBitmap, layout_bitmap *weakBitmap)
{
    rwlock_assert_writing(&runtimeLock);

    uint32_t diff;
    uint32_t i;

    assert(superSize > ro->instanceStart);
    diff = superSize - ro->instanceStart;

    if (ro->ivars) {
        // Find maximum alignment in this class's ivars
        uint32_t maxAlignment = 1;
        for (i = 0; i < ro->ivars->count; i++) {
            ivar_t *ivar = ivar_list_nth(ro->ivars, i);
            if (!ivar->offset) continue;  // anonymous bitfield

            uint32_t alignment = ivar_alignment(ivar);
            if (alignment > maxAlignment) maxAlignment = alignment;
        }

        // Compute a slide value that preserves that alignment
        uint32_t alignMask = maxAlignment - 1;
        if (diff & alignMask) diff = (diff + alignMask) & ~alignMask;

        // Slide all of this class's ivars en masse
        for (i = 0; i < ro->ivars->count; i++) {
            ivar_t *ivar = ivar_list_nth(ro->ivars, i);
            if (!ivar->offset) continue;  // anonymous bitfield

            uint32_t oldOffset = (uint32_t)*ivar->offset;
            uint32_t newOffset = oldOffset + diff;
            *ivar->offset = newOffset;

            if (PrintIvars) {
                _objc_inform("IVARS:    offset %u -> %u for %s (size %u, align %u)", 
                             oldOffset, newOffset, ivar->name, 
                             ivar->size, ivar_alignment(ivar));
            }
        }

        // Slide GC layouts
        uint32_t oldOffset = ro->instanceStart;
        uint32_t newOffset = ro->instanceStart + diff;

        if (ivarBitmap) {
            layout_bitmap_slide(ivarBitmap, 
                                oldOffset >> WORD_SHIFT, 
                                newOffset >> WORD_SHIFT);
        }
        if (weakBitmap) {
            layout_bitmap_slide(weakBitmap, 
                                oldOffset >> WORD_SHIFT, 
                                newOffset >> WORD_SHIFT);
        }
    }

    *(uint32_t *)&ro->instanceStart += diff;
    *(uint32_t *)&ro->instanceSize += diff;

    if (!ro->ivars) {
        // No ivars slid, but superclass changed size. 
        // Expand bitmap in preparation for layout_bitmap_splat().
        if (ivarBitmap) layout_bitmap_grow(ivarBitmap, ro->instanceSize >> WORD_SHIFT);
        if (weakBitmap) layout_bitmap_grow(weakBitmap, ro->instanceSize >> WORD_SHIFT);
    }
}


/***********************************************************************
* getIvar
* Look up an ivar by name.
* Locking: runtimeLock must be read- or write-locked by the caller.
**********************************************************************/
static ivar_t *getIvar(class_t *cls, const char *name)
{
    rwlock_assert_locked(&runtimeLock);

    const ivar_list_t *ivars;
    assert(isRealized(cls));
    if ((ivars = cls->data()->ro->ivars)) {
        uint32_t i;
        for (i = 0; i < ivars->count; i++) {
            ivar_t *ivar = ivar_list_nth(ivars, i);
            if (!ivar->offset) continue;  // anonymous bitfield

            // ivar->name may be NULL for anonymous bitfields etc.
            if (ivar->name  &&  0 == strcmp(name, ivar->name)) {
                return ivar;
            }
        }
    }

    return NULL;
}

static void reconcileInstanceVariables(class_t *cls, class_t *supercls) {
    class_rw_t *rw = cls->data();
    const class_ro_t *ro = rw->ro;
    
    if (supercls) {
        // Non-fragile ivars - reconcile this class with its superclass
        // Does this really need to happen for the isMETA case?
        layout_bitmap ivarBitmap;
        layout_bitmap weakBitmap;
        BOOL layoutsChanged = NO;
        BOOL mergeLayouts = UseGC;
        const class_ro_t *super_ro = supercls->data()->ro;
        
        if (DebugNonFragileIvars) {
            // Debugging: Force non-fragile ivars to slide.
            // Intended to find compiler, runtime, and program bugs.
            // If it fails with this and works without, you have a problem.
            
            // Operation: Reset everything to 0 + misalignment. 
            // Then force the normal sliding logic to push everything back.
            
            // Exceptions: root classes, metaclasses, *NSCF* classes, 
            // __CF* classes, NSConstantString, NSSimpleCString
            
            // (already know it's not root because supercls != nil)
            if (!strstr(getName(cls), "NSCF")  &&  
                0 != strncmp(getName(cls), "__CF", 4)  &&  
                0 != strcmp(getName(cls), "NSConstantString")  &&  
                0 != strcmp(getName(cls), "NSSimpleCString")) 
            {
                uint32_t oldStart = ro->instanceStart;
                uint32_t oldSize = ro->instanceSize;
                class_ro_t *ro_w = make_ro_writeable(rw);
                ro = rw->ro;
                
                // Find max ivar alignment in class.
                // default to word size to simplify ivar update
                uint32_t alignment = 1<<WORD_SHIFT;
                if (ro->ivars) {
                    uint32_t i;
                    for (i = 0; i < ro->ivars->count; i++) {
                        ivar_t *ivar = ivar_list_nth(ro->ivars, i);
                        if (ivar_alignment(ivar) > alignment) {
                            alignment = ivar_alignment(ivar);
                        }
                    }
                }
                uint32_t misalignment = ro->instanceStart % alignment;
                uint32_t delta = ro->instanceStart - misalignment;
                ro_w->instanceStart = misalignment;
                ro_w->instanceSize -= delta;
                
                if (PrintIvars) {
                    _objc_inform("IVARS: DEBUG: forcing ivars for class '%s' "
                                 "to slide (instanceStart %zu -> %zu)", 
                                 getName(cls), (size_t)oldStart, 
                                 (size_t)ro->instanceStart);
                }
                
                if (ro->ivars) {
                    uint32_t i;
                    for (i = 0; i < ro->ivars->count; i++) {
                        ivar_t *ivar = ivar_list_nth(ro->ivars, i);
                        if (!ivar->offset) continue;  // anonymous bitfield
                        *ivar->offset -= delta;
                    }
                }
                
                if (mergeLayouts) {
                    layout_bitmap layout;
                    if (ro->ivarLayout) {
                        layout = layout_bitmap_create(ro->ivarLayout, 
                                                      oldSize, oldSize, NO);
                        layout_bitmap_slide_anywhere(&layout, 
                                                     delta >> WORD_SHIFT, 0);
                        ro_w->ivarLayout = layout_string_create(layout);
                        layout_bitmap_free(layout);
                    }
                    if (ro->weakIvarLayout) {
                        layout = layout_bitmap_create(ro->weakIvarLayout, 
                                                      oldSize, oldSize, YES);
                        layout_bitmap_slide_anywhere(&layout, 
                                                     delta >> WORD_SHIFT, 0);
                        ro_w->weakIvarLayout = layout_string_create(layout);
                        layout_bitmap_free(layout);
                    }
                }
            }
        }
        
        // fixme can optimize for "class has no new ivars", etc
        // WARNING: gcc c++ sets instanceStart/Size=0 for classes with  
        //   no local ivars, but does provide a layout bitmap. 
        //   Handle that case specially so layout_bitmap_create doesn't die
        //   The other ivar sliding code below still works fine, and 
        //   the final result is a good class.
        if (ro->instanceStart == 0  &&  ro->instanceSize == 0) {
            // We can't use ro->ivarLayout because we don't know
            // how long it is. Force a new layout to be created.
            if (PrintIvars) {
                _objc_inform("IVARS: instanceStart/Size==0 for class %s; "
                             "disregarding ivar layout", ro->name);
            }
            ivarBitmap = layout_bitmap_create_empty(super_ro->instanceSize, NO);
            weakBitmap = layout_bitmap_create_empty(super_ro->instanceSize, YES);
            layoutsChanged = YES;
        } else {
            ivarBitmap = 
            layout_bitmap_create(ro->ivarLayout, 
                                 ro->instanceSize, 
                                 ro->instanceSize, NO);
            weakBitmap = 
            layout_bitmap_create(ro->weakIvarLayout, 
                                 ro->instanceSize,
                                 ro->instanceSize, YES);
        }
        
        if (ro->instanceStart < super_ro->instanceSize) {
            // Superclass has changed size. This class's ivars must move.
            // Also slide layout bits in parallel.
            // This code is incapable of compacting the subclass to 
            //   compensate for a superclass that shrunk, so don't do that.
            if (PrintIvars) {
                _objc_inform("IVARS: sliding ivars for class %s "
                             "(superclass was %u bytes, now %u)", 
                             ro->name, ro->instanceStart, 
                             super_ro->instanceSize);
            }
            class_ro_t *ro_w = make_ro_writeable(rw);
            ro = rw->ro;
            moveIvars(ro_w, super_ro->instanceSize, 
                      mergeLayouts ? &ivarBitmap : NULL, mergeLayouts ? &weakBitmap : NULL);
            gdb_objc_class_changed((Class)cls, OBJC_CLASS_IVARS_CHANGED, ro->name);
            layoutsChanged = mergeLayouts;
        } 
        
        if (mergeLayouts) {
            // Check superclass's layout against this class's layout.
            // This needs to be done even if the superclass is not bigger.
            layout_bitmap superBitmap = layout_bitmap_create(super_ro->ivarLayout, 
                                                             super_ro->instanceSize, 
                                                             super_ro->instanceSize, NO);
            layoutsChanged |= layout_bitmap_splat(ivarBitmap, superBitmap, 
                                                  ro->instanceStart);
            layout_bitmap_free(superBitmap);
            
            // check the superclass' weak layout.
            superBitmap = layout_bitmap_create(super_ro->weakIvarLayout, 
                                               super_ro->instanceSize, 
                                               super_ro->instanceSize, YES);
            layoutsChanged |= layout_bitmap_splat(weakBitmap, superBitmap, 
                                                  ro->instanceStart);
            layout_bitmap_free(superBitmap);
        }
        
        if (layoutsChanged) {
            // Rebuild layout strings. 
            if (PrintIvars) {
                _objc_inform("IVARS: gc layout changed for class %s",
                             ro->name);
            }
            class_ro_t *ro_w = make_ro_writeable(rw);
            ro = rw->ro;
            if (DebugNonFragileIvars) {
                try_free(ro_w->ivarLayout);
                try_free(ro_w->weakIvarLayout);
            }
            ro_w->ivarLayout = layout_string_create(ivarBitmap);
            ro_w->weakIvarLayout = layout_string_create(weakBitmap);
        }
        
        layout_bitmap_free(ivarBitmap);
        layout_bitmap_free(weakBitmap);
    }
}

/***********************************************************************
* realizeClass
* Performs first-time initialization on class cls, 
* including allocating its read-write data.
* Returns the real class structure for the class. 
* Locking: runtimeLock must be write-locked by the caller
**********************************************************************/
static class_t *realizeClass(class_t *cls)
{
    rwlock_assert_writing(&runtimeLock);

    const class_ro_t *ro;
    class_rw_t *rw;
    class_t *supercls;
    class_t *metacls;
    BOOL isMeta;

    if (!cls) return NULL;
    if (isRealized(cls)) return cls;
    assert(cls == remapClass(cls));

    ro = (const class_ro_t *)cls->data();
    if (ro->flags & RO_FUTURE) {
        // This was a future class. rw data is already allocated.
        rw = cls->data();
        ro = cls->data()->ro;
        changeInfo(cls, RW_REALIZED, RW_FUTURE);
    } else {
        // Normal class. Allocate writeable class data.
        rw = (class_rw_t *)_calloc_internal(sizeof(class_rw_t), 1);
        rw->ro = ro;
        rw->flags = RW_REALIZED;
        cls->setData(rw);
    }

    isMeta = (ro->flags & RO_META) ? YES : NO;

    rw->version = isMeta ? 7 : 0;  // old runtime went up to 6

    if (PrintConnecting) {
        _objc_inform("CLASS: realizing class '%s' %s %p %p", 
                     ro->name, isMeta ? "(meta)" : "", cls, ro);
    }

    // Realize superclass and metaclass, if they aren't already.
    // This needs to be done after RW_REALIZED is set above, for root classes.
    supercls = realizeClass(remapClass(cls->superclass));
    metacls = realizeClass(remapClass(cls->isa));

    // Check for remapped superclass and metaclass
    if (supercls != cls->superclass) {
        cls->superclass = supercls;
    }
    if (metacls != cls->isa) {
        cls->isa = metacls;
    }

    /* debug: print them all
    if (ro->ivars) {
        uint32_t i;
        for (i = 0; i < ro->ivars->count; i++) {
            ivar_t *ivar = ivar_list_nth(ro->ivars, i);
            if (!ivar->offset) continue;  // anonymous bitfield

            _objc_inform("IVARS: %s.%s (offset %u, size %u, align %u)", 
                         ro->name, ivar->name, 
                         *ivar->offset, ivar->size, ivar_alignment(ivar));
        }
    }
    */

    // Reconcile instance variable offsets / layout.
    if (!isMeta) reconcileInstanceVariables(cls, supercls);

    // Copy some flags from ro to rw
    if (ro->flags & RO_HAS_CXX_STRUCTORS) rw->flags |= RW_HAS_CXX_STRUCTORS;

    // Connect this class to its superclass's subclass lists
    if (supercls) {
        addSubclass(supercls, cls);
    }

    // Attach categories
    methodizeClass(cls);

    if (!isMeta) {
        addRealizedClass(cls);
    } else {
        addRealizedMetaclass(cls);
    }

    return cls;
}


/***********************************************************************
* missingWeakSuperclass
* Return YES if some superclass of cls was weak-linked and is missing.
**********************************************************************/
static BOOL 
missingWeakSuperclass(class_t *cls)
{
    assert(!isRealized(cls));

    if (!cls->superclass) {
        // superclass NULL. This is normal for root classes only.
        return (!(cls->data()->flags & RO_ROOT));
    } else {
        // superclass not NULL. Check if a higher superclass is missing.
        class_t *supercls = remapClass(cls->superclass);
        assert(cls != cls->superclass);
        assert(cls != supercls);
        if (!supercls) return YES;
        if (isRealized(supercls)) return NO;
        return missingWeakSuperclass(supercls);
    }
}


/***********************************************************************
* realizeAllClassesInImage
* Non-lazily realizes all unrealized classes in the given image.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void realizeAllClassesInImage(header_info *hi)
{
    rwlock_assert_writing(&runtimeLock);

    size_t count, i;
    classref_t *classlist;

    if (hi->allClassesRealized) return;

    classlist = _getObjc2ClassList(hi, &count);

    for (i = 0; i < count; i++) {
        realizeClass(remapClass(classlist[i]));
    }

    hi->allClassesRealized = YES;
}


/***********************************************************************
* realizeAllClasses
* Non-lazily realizes all unrealized classes in all known images.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void realizeAllClasses(void)
{
    rwlock_assert_writing(&runtimeLock);

    header_info *hi;
    for (hi = FirstHeader; hi; hi = hi->next) {
        realizeAllClassesInImage(hi);
    }
}


/***********************************************************************
* _objc_allocateFutureClass
* Allocate an unresolved future class for the given class name.
* Returns any existing allocation if one was already made.
* Assumes the named class doesn't exist yet.
* Locking: acquires runtimeLock
**********************************************************************/
Class _objc_allocateFutureClass(const char *name)
{
    rwlock_write(&runtimeLock);

    class_t *cls;
    NXMapTable *future_named_class_map = futureNamedClasses();

    if ((cls = (class_t *)NXMapGet(future_named_class_map, name))) {
        // Already have a future class for this name.
        rwlock_unlock_write(&runtimeLock);
        return (Class)cls;
    }

    cls = (class_t *)_calloc_class(sizeof(*cls));
    addFutureNamedClass(name, cls);

    rwlock_unlock_write(&runtimeLock);
    return (Class)cls;
}


/***********************************************************************
* 
**********************************************************************/
void objc_setFutureClass(Class cls, const char *name)
{
    // fixme hack do nothing - NSCFString handled specially elsewhere
}


/***********************************************************************
* flushVtables
* Rebuilds vtables for cls and its realized subclasses. 
* If cls is Nil, all realized classes and metaclasses are touched.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void flushVtables(class_t *cls)
{
    rwlock_assert_writing(&runtimeLock);

    if (PrintVtables  &&  !cls) {
        _objc_inform("VTABLES: ### EXPENSIVE ### global vtable flush!");
    }

    FOREACH_REALIZED_CLASS_AND_SUBCLASS(c, cls, {
        updateVtable(c, NO);
    });
}


/***********************************************************************
* flushCaches
* Flushes caches for cls and its realized subclasses.
* Does not update vtables.
* If cls is Nil, all realized and metaclasses classes are touched.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void flushCaches(class_t *cls)
{
    rwlock_assert_writing(&runtimeLock);

    FOREACH_REALIZED_CLASS_AND_SUBCLASS(c, cls, {
        flush_cache((Class)c);
    });
}


/***********************************************************************
* flush_caches
* Flushes caches and rebuilds vtables for cls, its subclasses, 
* and optionally its metaclass.
* Locking: acquires runtimeLock
**********************************************************************/
void flush_caches(Class cls_gen, BOOL flush_meta)
{
    class_t *cls = newcls(cls_gen);
    rwlock_write(&runtimeLock);
    // fixme optimize vtable flushing? (only needed for vtable'd selectors)
    flushCaches(cls);
    flushVtables(cls);
    // don't flush root class's metaclass twice (it's a subclass of the root)
    if (flush_meta  &&  getSuperclass(cls)) {
        flushCaches(cls->isa);
        flushVtables(cls->isa);
    }
    rwlock_unlock_write(&runtimeLock);
}


/***********************************************************************
* map_images
* Process the given images which are being mapped in by dyld.
* Calls ABI-agnostic code after taking ABI-specific locks.
*
* Locking: write-locks runtimeLock
**********************************************************************/
const char *
map_images(enum dyld_image_states state, uint32_t infoCount,
           const struct dyld_image_info infoList[])
{
    const char *err;

    rwlock_write(&runtimeLock);
    err = map_images_nolock(state, infoCount, infoList);
    rwlock_unlock_write(&runtimeLock);
    return err;
}


/***********************************************************************
* load_images
* Process +load in the given images which are being mapped in by dyld.
* Calls ABI-agnostic code after taking ABI-specific locks.
*
* Locking: write-locks runtimeLock and loadMethodLock
**********************************************************************/
const char *
load_images(enum dyld_image_states state, uint32_t infoCount,
            const struct dyld_image_info infoList[])
{
    BOOL found;

    recursive_mutex_lock(&loadMethodLock);

    // Discover load methods
    rwlock_write(&runtimeLock);
    found = load_images_nolock(state, infoCount, infoList);
    rwlock_unlock_write(&runtimeLock);

    // Call +load methods (without runtimeLock - re-entrant)
    if (found) {
        call_load_methods();
    }

    recursive_mutex_unlock(&loadMethodLock);

    return NULL;
}


/***********************************************************************
* unmap_image
* Process the given image which is about to be unmapped by dyld.
* mh is mach_header instead of headerType because that's what 
*   dyld_priv.h says even for 64-bit.
*
* Locking: write-locks runtimeLock and loadMethodLock
**********************************************************************/
void 
unmap_image(const struct mach_header *mh, intptr_t vmaddr_slide)
{
    recursive_mutex_lock(&loadMethodLock);
    rwlock_write(&runtimeLock);

    unmap_image_nolock(mh);

    rwlock_unlock_write(&runtimeLock);
    recursive_mutex_unlock(&loadMethodLock);
}



/***********************************************************************
* _read_images
* Perform initial processing of the headers in the linked 
* list beginning with headerList. 
*
* Called by: map_images_nolock
*
* Locking: runtimeLock acquired by map_images
**********************************************************************/
void _read_images(header_info **hList, uint32_t hCount)
{
    header_info *hi;
    uint32_t hIndex;
    size_t count;
    size_t i;
    class_t **resolvedFutureClasses = NULL;
    size_t resolvedFutureClassCount = 0;
    static unsigned int totalMethodLists;
    static unsigned int preoptimizedMethodLists;
    static unsigned int totalClasses;
    static unsigned int preoptimizedClasses;
    static BOOL doneOnce;

    rwlock_assert_writing(&runtimeLock);

#define EACH_HEADER \
    hIndex = 0;         \
    crashlog_header_name(NULL) && hIndex < hCount && (hi = hList[hIndex]) && crashlog_header_name(hi); \
    hIndex++

    if (!doneOnce) {
        doneOnce = YES;
        initVtables();
        
        // Count classes. Size various table based on the total.
        size_t total = 0;
        size_t unoptimizedTotal = 0;
        for (EACH_HEADER) {
            if (_getObjc2ClassList(hi, &count)) {
                total += count;
                if (!hi->inSharedCache) unoptimizedTotal += count;
            }
        }
        
        if (PrintConnecting) {
            _objc_inform("CLASS: found %zu classes during launch", total);
        }

        // namedClasses (NOT realizedClasses)
        // Preoptimized classes don't go in this table.
        // 4/3 is NXMapTable's load factor
        size_t namedClassesSize = 
            (isPreoptimized() ? unoptimizedTotal : total) * 4 / 3;
        gdb_objc_realized_classes =
            NXCreateMapTableFromZone(NXStrValueMapPrototype, namedClassesSize, 
                                     _objc_internal_zone());
        
        // realizedClasses and realizedMetaclasses - less than the full total
        realized_class_hash = 
            NXCreateHashTableFromZone(NXPtrPrototype, total / 8, NULL, 
                                      _objc_internal_zone());
        realized_metaclass_hash = 
            NXCreateHashTableFromZone(NXPtrPrototype, total / 8, NULL, 
                                      _objc_internal_zone());
    }


    // Discover classes. Fix up unresolved future classes. Mark bundle classes.
    NXMapTable *future_named_class_map = futureNamedClasses();

    for (EACH_HEADER) {
        bool headerIsBundle = (hi->mhdr->filetype == MH_BUNDLE);
        bool headerInSharedCache = hi->inSharedCache;

        classref_t *classlist = _getObjc2ClassList(hi, &count);
        for (i = 0; i < count; i++) {
            class_t *cls = (class_t *)classlist[i];
            const char *name = getName(cls);
            
            if (missingWeakSuperclass(cls)) {
                // No superclass (probably weak-linked). 
                // Disavow any knowledge of this subclass.
                if (PrintConnecting) {
                    _objc_inform("CLASS: IGNORING class '%s' with "
                                 "missing weak-linked superclass", name);
                }
                addRemappedClass(cls, NULL);
                cls->superclass = NULL;
                continue;
            }

            class_t *newCls = NULL;
            if (NXCountMapTable(future_named_class_map) > 0) {
                newCls = (class_t *)NXMapGet(future_named_class_map, name);
                removeFutureNamedClass(name);
            }
            
            if (newCls) {
                // Copy class_t to future class's struct.
                // Preserve future's rw data block.
                class_rw_t *rw = newCls->data();
                memcpy(newCls, cls, sizeof(class_t));
                rw->ro = (class_ro_t *)newCls->data();
                newCls->setData(rw);
                
                addRemappedClass(cls, newCls);
                cls = newCls;

                // Non-lazily realize the class below.
                resolvedFutureClasses = (class_t **)
                    _realloc_internal(resolvedFutureClasses, 
                                      (resolvedFutureClassCount+1) 
                                      * sizeof(class_t *));
                resolvedFutureClasses[resolvedFutureClassCount++] = newCls;
            }

            totalClasses++;
            if (headerInSharedCache  &&  isPreoptimized()) {
                // class list built in shared cache
                // fixme strict assert doesn't work because of duplicates
                // assert(cls == getClass(name));
                assert(getClass(name));
                preoptimizedClasses++;
            } else {
                addNamedClass(cls, name);
            }             

            // for future reference: shared cache never contains MH_BUNDLEs
            if (headerIsBundle) {
                cls->data()->flags |= RO_FROM_BUNDLE;
                cls->isa->data()->flags |= RO_FROM_BUNDLE;
            }

            if (PrintPreopt) {
                const method_list_t *mlist;
                if ((mlist = ((class_ro_t *)cls->data())->baseMethods)) {
                    totalMethodLists++;
                    if (isMethodListFixedUp(mlist)) preoptimizedMethodLists++;
                }
                if ((mlist = ((class_ro_t *)cls->isa->data())->baseMethods)) {
                    totalMethodLists++;
                    if (isMethodListFixedUp(mlist)) preoptimizedMethodLists++;
                }
            }
        }
    }

    if (PrintPreopt  &&  totalMethodLists) {
        _objc_inform("PREOPTIMIZATION: %u/%u (%.3g%%) method lists pre-sorted",
                     preoptimizedMethodLists, totalMethodLists, 
                     100.0*preoptimizedMethodLists/totalMethodLists);
    }
    if (PrintPreopt  &&  totalClasses) {
        _objc_inform("PREOPTIMIZATION: %u/%u (%.3g%%) classes pre-registered",
                     preoptimizedClasses, totalClasses, 
                     100.0*preoptimizedClasses/totalClasses);
    }

    // Fix up remapped classes
    // Class list and nonlazy class list remain unremapped.
    // Class refs and super refs are remapped for message dispatching.
    
    if (!noClassesRemapped()) {
        for (EACH_HEADER) {
            class_t **classrefs = _getObjc2ClassRefs(hi, &count);
            for (i = 0; i < count; i++) {
                remapClassRef(&classrefs[i]);
            }
            // fixme why doesn't test future1 catch the absence of this?
            classrefs = _getObjc2SuperRefs(hi, &count);
            for (i = 0; i < count; i++) {
                remapClassRef(&classrefs[i]);
            }
        }
    }


    // Fix up @selector references
    sel_lock();
    for (EACH_HEADER) {
        if (PrintPreopt) {
            if (sel_preoptimizationValid(hi)) {
                _objc_inform("PREOPTIMIZATION: honoring preoptimized selectors in %s", 
                             hi->fname);
            }
            else if (_objcHeaderOptimizedByDyld(hi)) {
                _objc_inform("PREOPTIMIZATION: IGNORING preoptimized selectors in %s", 
                             hi->fname);
            }
        }
        
        if (sel_preoptimizationValid(hi)) continue;

        SEL *sels = _getObjc2SelectorRefs(hi, &count);
        BOOL isBundle = hi->mhdr->filetype == MH_BUNDLE;
        for (i = 0; i < count; i++) {
            sels[i] = sel_registerNameNoLock((const char *)sels[i], isBundle);
        }
    }
    sel_unlock();

    // Discover protocols. Fix up protocol refs.
    NXMapTable *protocol_map = protocols();
    for (EACH_HEADER) {
        extern class_t OBJC_CLASS_$_Protocol;
        Class cls = (Class)&OBJC_CLASS_$_Protocol;
        assert(cls);
        protocol_t **protocols = _getObjc2ProtocolList(hi, &count);
        // fixme duplicate protocol from bundle
        for (i = 0; i < count; i++) {
            if (!NXMapGet(protocol_map, protocols[i]->name)) {
                protocols[i]->isa = cls;
                NXMapKeyCopyingInsert(protocol_map, 
                                      protocols[i]->name, protocols[i]);
                if (PrintProtocols) {
                    _objc_inform("PROTOCOLS: protocol at %p is %s",
                                 protocols[i], protocols[i]->name);
                }
            } else {
                if (PrintProtocols) {
                    _objc_inform("PROTOCOLS: protocol at %p is %s (duplicate)",
                                 protocols[i], protocols[i]->name);
                }
            }
        }
    }
    for (EACH_HEADER) {
        protocol_t **protocols;
        protocols = _getObjc2ProtocolRefs(hi, &count);
        for (i = 0; i < count; i++) {
            remapProtocolRef(&protocols[i]);
        }
    }

    // Realize non-lazy classes (for +load methods and static instances)
    for (EACH_HEADER) {
        classref_t *classlist = 
            _getObjc2NonlazyClassList(hi, &count);
        for (i = 0; i < count; i++) {
            realizeClass(remapClass(classlist[i]));
        }
    }    

    // Realize newly-resolved future classes, in case CF manipulates them
    if (resolvedFutureClasses) {
        for (i = 0; i < resolvedFutureClassCount; i++) {
            realizeClass(resolvedFutureClasses[i]);
        }
        _free_internal(resolvedFutureClasses);
    }    

    // Discover categories. 
    for (EACH_HEADER) {
        category_t **catlist = 
            _getObjc2CategoryList(hi, &count);
        for (i = 0; i < count; i++) {
            category_t *cat = catlist[i];
            class_t *cls = remapClass(cat->cls);

            if (!cls) {
                // Category's target class is missing (probably weak-linked).
                // Disavow any knowledge of this category.
                catlist[i] = NULL;
                if (PrintConnecting) {
                    _objc_inform("CLASS: IGNORING category \?\?\?(%s) %p with "
                                 "missing weak-linked target class", 
                                 cat->name, cat);
                }
                continue;
            }

            // Process this category. 
            // First, register the category with its target class. 
            // Then, rebuild the class's method lists (etc) if 
            // the class is realized. 
            BOOL classExists = NO;
            if (cat->instanceMethods ||  cat->protocols  
                ||  cat->instanceProperties) 
            {
                addUnattachedCategoryForClass(cat, cls, hi);
                if (isRealized(cls)) {
                    remethodizeClass(cls);
                    classExists = YES;
                }
                if (PrintConnecting) {
                    _objc_inform("CLASS: found category -%s(%s) %s", 
                                 getName(cls), cat->name, 
                                 classExists ? "on existing class" : "");
                }
            }

            if (cat->classMethods  ||  cat->protocols  
                /* ||  cat->classProperties */) 
            {
                addUnattachedCategoryForClass(cat, cls->isa, hi);
                if (isRealized(cls->isa)) {
                    remethodizeClass(cls->isa);
                }
                if (PrintConnecting) {
                    _objc_inform("CLASS: found category +%s(%s)", 
                                 getName(cls), cat->name);
                }
            }
        }
    }

    // Category discovery MUST BE LAST to avoid potential races 
    // when other threads call the new category code before 
    // this thread finishes its fixups.

    // +load handled by prepare_load_methods()

    if (DebugNonFragileIvars) {
        realizeAllClasses();
    }

#undef EACH_HEADER
}


/***********************************************************************
* prepare_load_methods
* Schedule +load for classes in this image, any un-+load-ed 
* superclasses in other images, and any categories in this image.
**********************************************************************/
// Recursively schedule +load for cls and any un-+load-ed superclasses.
// cls must already be connected.
static void schedule_class_load(class_t *cls)
{
    if (!cls) return;
    assert(isRealized(cls));  // _read_images should realize

    if (cls->data()->flags & RW_LOADED) return;

    // Ensure superclass-first ordering
    schedule_class_load(getSuperclass(cls));

    add_class_to_loadable_list((Class)cls);
    changeInfo(cls, RW_LOADED, 0); 
}

void prepare_load_methods(header_info *hi)
{
    size_t count, i;

    rwlock_assert_writing(&runtimeLock);

    classref_t *classlist = 
        _getObjc2NonlazyClassList(hi, &count);
    for (i = 0; i < count; i++) {
        schedule_class_load(remapClass(classlist[i]));
    }

    category_t **categorylist = _getObjc2NonlazyCategoryList(hi, &count);
    for (i = 0; i < count; i++) {
        category_t *cat = categorylist[i];
        class_t *cls = remapClass(cat->cls);
        if (!cls) continue;  // category for ignored weak-linked class
        realizeClass(cls);
        assert(isRealized(cls->isa));
        add_category_to_loadable_list((Category)cat);
    }
}


/***********************************************************************
* _unload_image
* Only handles MH_BUNDLE for now.
* Locking: write-lock and loadMethodLock acquired by unmap_image
**********************************************************************/
void _unload_image(header_info *hi)
{
    size_t count, i;

    recursive_mutex_assert_locked(&loadMethodLock);
    rwlock_assert_writing(&runtimeLock);

    // Unload unattached categories and categories waiting for +load.

    category_t **catlist = _getObjc2CategoryList(hi, &count);
    for (i = 0; i < count; i++) {
        category_t *cat = catlist[i];
        if (!cat) continue;  // category for ignored weak-linked class
        class_t *cls = remapClass(cat->cls);
        assert(cls);  // shouldn't have live category for dead class

        // fixme for MH_DYLIB cat's class may have been unloaded already

        // unattached list
        removeUnattachedCategoryForClass(cat, cls);

        // +load queue
        remove_category_from_loadable_list((Category)cat);
    }

    // Unload classes.

    classref_t *classlist = _getObjc2ClassList(hi, &count);

    // First detach classes from each other. Then free each class.
    // This avoid bugs where this loop unloads a subclass before its superclass

    for (i = 0; i < count; i++) {
        class_t *cls = remapClass(classlist[i]);
        if (cls) {
            remove_class_from_loadable_list((Class)cls);
            detach_class(cls->isa, YES);
            detach_class(cls, NO);
        }
    }
    
    for (i = 0; i < count; i++) {
        class_t *cls = remapClass(classlist[i]);
        if (cls) {
            free_class(cls->isa);
            free_class(cls);
        }
    }
    
    // XXX FIXME -- Clean up protocols:
    // <rdar://problem/9033191> Support unloading protocols at dylib/image unload time

    // fixme DebugUnload
}


/***********************************************************************
* method_getDescription
* Returns a pointer to this method's objc_method_description.
* Locking: none
**********************************************************************/
struct objc_method_description *
method_getDescription(Method m)
{
    if (!m) return NULL;
    return (struct objc_method_description *)newmethod(m);
}


/***********************************************************************
* method_getImplementation
* Returns this method's IMP.
* Locking: none
**********************************************************************/
static IMP 
_method_getImplementation(method_t *m)
{
    if (!m) return NULL;
    return m->imp;
}

IMP 
method_getImplementation(Method m)
{
    return _method_getImplementation(newmethod(m));
}


/***********************************************************************
* method_getName
* Returns this method's selector.
* The method must not be NULL.
* The method must already have been fixed-up.
* Locking: none
**********************************************************************/
SEL 
method_getName(Method m_gen)
{
    method_t *m = newmethod(m_gen);
    if (!m) return NULL;

    assert((SEL)m->name == sel_registerName((char *)m->name));
    return (SEL)m->name;
}


/***********************************************************************
* method_getTypeEncoding
* Returns this method's old-style type encoding string.
* The method must not be NULL.
* Locking: none
**********************************************************************/
const char *
method_getTypeEncoding(Method m)
{
    if (!m) return NULL;
    return newmethod(m)->types;
}


/***********************************************************************
* method_setImplementation
* Sets this method's implementation to imp.
* The previous implementation is returned.
**********************************************************************/
static IMP 
_method_setImplementation(class_t *cls, method_t *m, IMP imp)
{
    rwlock_assert_writing(&runtimeLock);

    if (!m) return NULL;
    if (!imp) return NULL;

    if (ignoreSelector(m->name)) {
        // Ignored methods stay ignored
        return m->imp;
    }

    IMP old = _method_getImplementation(m);
    m->imp = imp;

    // No cache flushing needed - cache contains Methods not IMPs.
    
    // vtable and RR/AWZ updates are slow if cls is NULL (i.e. unknown)
    // fixme build list of classes whose Methods are known externally?

    if (vtable_containsSelector(m->name)) {
        flushVtables(cls);
    }

    // Catch changes to retain/release and allocWithZone implementations
    updateCustomRR_AWZ(cls, m);

    // fixme update monomorphism if necessary

    return old;
}

IMP 
method_setImplementation(Method m, IMP imp)
{
    // Don't know the class - will be slow if vtables are affected
    // fixme build list of classes whose Methods are known externally?
    IMP result;
    rwlock_write(&runtimeLock);
    result = _method_setImplementation(Nil, newmethod(m), imp);
    rwlock_unlock_write(&runtimeLock);
    return result;
}


void method_exchangeImplementations(Method m1_gen, Method m2_gen)
{
    method_t *m1 = newmethod(m1_gen);
    method_t *m2 = newmethod(m2_gen);
    if (!m1  ||  !m2) return;

    rwlock_write(&runtimeLock);

    if (ignoreSelector(m1->name)  ||  ignoreSelector(m2->name)) {
        // Ignored methods stay ignored. Now they're both ignored.
        m1->imp = (IMP)&_objc_ignored_method;
        m2->imp = (IMP)&_objc_ignored_method;
        rwlock_unlock_write(&runtimeLock);
        return;
    }

    IMP m1_imp = m1->imp;
    m1->imp = m2->imp;
    m2->imp = m1_imp;

    // vtable and RR/AWZ updates are slow because class is unknown
    // fixme build list of classes whose Methods are known externally?

    if (vtable_containsSelector(m1->name)  ||  
        vtable_containsSelector(m2->name)) 
    {
        // Don't know the class - will be slow if vtables are affected
        // fixme build list of classes whose Methods are known externally?
        flushVtables(NULL);
    }

    updateCustomRR_AWZ(nil, m1);
    updateCustomRR_AWZ(nil, m2);

    // fixme update monomorphism if necessary

    rwlock_unlock_write(&runtimeLock);
}


/***********************************************************************
* ivar_getOffset
* fixme
* Locking: none
**********************************************************************/
ptrdiff_t
ivar_getOffset(Ivar ivar)
{
    if (!ivar) return 0;
    return *newivar(ivar)->offset;
}


/***********************************************************************
* ivar_getName
* fixme
* Locking: none
**********************************************************************/
const char *
ivar_getName(Ivar ivar)
{
    if (!ivar) return NULL;
    return newivar(ivar)->name;
}


/***********************************************************************
* ivar_getTypeEncoding
* fixme
* Locking: none
**********************************************************************/
const char *
ivar_getTypeEncoding(Ivar ivar)
{
    if (!ivar) return NULL;
    return newivar(ivar)->type;
}



const char *property_getName(objc_property_t prop)
{
    return newproperty(prop)->name;
}

const char *property_getAttributes(objc_property_t prop)
{
    return newproperty(prop)->attributes;
}

objc_property_attribute_t *property_copyAttributeList(objc_property_t prop, 
                                                      unsigned int *outCount)
{
    if (!prop) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    objc_property_attribute_t *result;
    rwlock_read(&runtimeLock);
    result = copyPropertyAttributeList(newproperty(prop)->attributes,outCount);
    rwlock_unlock_read(&runtimeLock);
    return result;
}

char * property_copyAttributeValue(objc_property_t prop, const char *name)
{
    if (!prop  ||  !name  ||  *name == '\0') return NULL;
    
    char *result;
    rwlock_read(&runtimeLock);
    result = copyPropertyAttributeValue(newproperty(prop)->attributes, name);
    rwlock_unlock_read(&runtimeLock);
    return result;    
}


/***********************************************************************
* getExtendedTypesIndexesForMethod
* Returns:
* a is the count of methods in all method lists before m's method list
* b is the index of m in m's method list
* a+b is the index of m's extended types in the extended types array
**********************************************************************/
static void getExtendedTypesIndexesForMethod(protocol_t *proto, const method_t *m, BOOL isRequiredMethod, BOOL isInstanceMethod, uint32_t& a, uint32_t &b)
{
    a = 0;

    if (isRequiredMethod && isInstanceMethod) {
        b = method_list_index(proto->instanceMethods, m);
        return;
    }
    a += method_list_count(proto->instanceMethods);

    if (isRequiredMethod && !isInstanceMethod) {
        b = method_list_index(proto->classMethods, m);
        return;
    }
    a += method_list_count(proto->classMethods);

    if (!isRequiredMethod && isInstanceMethod) {
        b = method_list_index(proto->optionalInstanceMethods, m);
        return;
    }
    a += method_list_count(proto->optionalInstanceMethods);

    if (!isRequiredMethod && !isInstanceMethod) {
        b = method_list_index(proto->optionalClassMethods, m);
        return;
    }
    a += method_list_count(proto->optionalClassMethods);
}


/***********************************************************************
* getExtendedTypesIndexForMethod
* Returns the index of m's extended types in proto's extended types array.
**********************************************************************/
static uint32_t getExtendedTypesIndexForMethod(protocol_t *proto, const method_t *m, BOOL isRequiredMethod, BOOL isInstanceMethod)
{
    uint32_t a;
    uint32_t b;
    getExtendedTypesIndexesForMethod(proto, m, isRequiredMethod, 
                                     isInstanceMethod, a, b);
    return a + b;
}


/***********************************************************************
* _protocol_getMethod_nolock
* Locking: runtimeLock must be write-locked by the caller
**********************************************************************/
static method_t *
_protocol_getMethod_nolock(protocol_t *proto, SEL sel, 
                           BOOL isRequiredMethod, BOOL isInstanceMethod, 
                           BOOL recursive)
{
    rwlock_assert_writing(&runtimeLock);

    if (!proto  ||  !sel) return NULL;

    method_list_t **mlistp = NULL;

    if (isRequiredMethod) {
        if (isInstanceMethod) {
            mlistp = &proto->instanceMethods;
        } else {
            mlistp = &proto->classMethods;
        }
    } else {
        if (isInstanceMethod) {
            mlistp = &proto->optionalInstanceMethods;
        } else {
            mlistp = &proto->optionalClassMethods;
        }
    }

    if (*mlistp) {
        method_list_t *mlist = *mlistp;
        if (!isMethodListFixedUp(mlist)) {
            bool hasExtendedMethodTypes = proto->hasExtendedMethodTypes();
            mlist = fixupMethodList(mlist, true/*always copy for simplicity*/,
                                    !hasExtendedMethodTypes/*sort if no ext*/);
            *mlistp = mlist;

            if (hasExtendedMethodTypes) {
                // Sort method list and extended method types together.
                // fixupMethodList() can't do this.
                // fixme COW stomp
                uint32_t count = method_list_count(mlist);
                uint32_t prefix;
                uint32_t unused;
                getExtendedTypesIndexesForMethod(proto, method_list_nth(mlist, 0), isRequiredMethod, isInstanceMethod, prefix, unused);
                const char **types = proto->extendedMethodTypes;
                for (uint32_t i = 0; i < count; i++) {
                    for (uint32_t j = i+1; j < count; j++) {
                        method_t *mi = method_list_nth(mlist, i);
                        method_t *mj = method_list_nth(mlist, j);
                        if (mi->name > mj->name) {
                            method_list_swap(mlist, i, j);
                            std::swap(types[prefix+i], types[prefix+j]);
                        }
                    }
                }
            }
        }

        method_t *m = search_method_list(mlist, sel);
        if (m) return m;
    }

    if (recursive  &&  proto->protocols) {
        method_t *m;
        for (uint32_t i = 0; i < proto->protocols->count; i++) {
            protocol_t *realProto = remapProtocol(proto->protocols->list[i]);
            m = _protocol_getMethod_nolock(realProto, sel, 
                                           isRequiredMethod, isInstanceMethod, 
                                           true);
            if (m) return m;
        }
    }

    return NULL;
}


/***********************************************************************
* _protocol_getMethod
* fixme
* Locking: write-locks runtimeLock
**********************************************************************/
Method 
_protocol_getMethod(Protocol *p, SEL sel, BOOL isRequiredMethod, BOOL isInstanceMethod, BOOL recursive)
{
    rwlock_write(&runtimeLock);
    method_t *result = _protocol_getMethod_nolock(newprotocol(p), sel, 
                                                  isRequiredMethod,
                                                  isInstanceMethod, 
                                                  recursive);
    rwlock_unlock_write(&runtimeLock);
    return (Method)result;
}


/***********************************************************************
* _protocol_getMethodTypeEncoding_nolock
* Return the @encode string for the requested protocol method.
* Returns NULL if the compiler did not emit any extended @encode data.
* Locking: runtimeLock must be held for writing by the caller
**********************************************************************/
const char * 
_protocol_getMethodTypeEncoding_nolock(protocol_t *proto, SEL sel, 
                                       BOOL isRequiredMethod, 
                                       BOOL isInstanceMethod)
{
    rwlock_assert_writing(&runtimeLock);

    if (!proto) return NULL;
    if (!proto->hasExtendedMethodTypes()) return NULL;

    method_t *m = 
        _protocol_getMethod_nolock(proto, sel, 
                                   isRequiredMethod, isInstanceMethod, false);
    if (m) {
        uint32_t i = getExtendedTypesIndexForMethod(proto, m, 
                                                    isRequiredMethod, 
                                                    isInstanceMethod);
        return proto->extendedMethodTypes[i];
    }

    // No method with that name. Search incorporated protocols.
    if (proto->protocols) {
        for (uintptr_t i = 0; i < proto->protocols->count; i++) {
            const char *enc = 
                _protocol_getMethodTypeEncoding_nolock(remapProtocol(proto->protocols->list[i]), sel, isRequiredMethod, isInstanceMethod);
            if (enc) return enc;
        }
    }

    return NULL;
}

/***********************************************************************
* _protocol_getMethodTypeEncoding
* Return the @encode string for the requested protocol method.
* Returns NULL if the compiler did not emit any extended @encode data.
* Locking: runtimeLock must not be held by the caller
**********************************************************************/
const char * 
_protocol_getMethodTypeEncoding(Protocol *proto_gen, SEL sel, 
                                BOOL isRequiredMethod, BOOL isInstanceMethod)
{
    const char *enc;
    rwlock_write(&runtimeLock);
    enc = _protocol_getMethodTypeEncoding_nolock(newprotocol(proto_gen), sel, 
                                                 isRequiredMethod, 
                                                 isInstanceMethod);
    rwlock_unlock_write(&runtimeLock);
    return enc;
}

/***********************************************************************
* protocol_getName
* Returns the name of the given protocol.
* Locking: runtimeLock must not be held by the caller
**********************************************************************/
const char *
protocol_getName(Protocol *proto)
{
    return newprotocol(proto)->name;
}


/***********************************************************************
* protocol_getInstanceMethodDescription
* Returns the description of a named instance method.
* Locking: runtimeLock must not be held by the caller
**********************************************************************/
struct objc_method_description 
protocol_getMethodDescription(Protocol *p, SEL aSel, 
                              BOOL isRequiredMethod, BOOL isInstanceMethod)
{
    Method m = 
        _protocol_getMethod(p, aSel, isRequiredMethod, isInstanceMethod, true);
    if (m) return *method_getDescription(m);
    else return (struct objc_method_description){NULL, NULL};
}


/***********************************************************************
* _protocol_conformsToProtocol_nolock
* Returns YES if self conforms to other.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static BOOL _protocol_conformsToProtocol_nolock(protocol_t *self, protocol_t *other)
{
    if (!self  ||  !other) {
        return NO;
    }

    if (0 == strcmp(self->name, other->name)) {
        return YES;
    }

    if (self->protocols) {
        uintptr_t i;
        for (i = 0; i < self->protocols->count; i++) {
            protocol_t *proto = remapProtocol(self->protocols->list[i]);
            if (0 == strcmp(other->name, proto->name)) {
                return YES;
            }
            if (_protocol_conformsToProtocol_nolock(proto, other)) {
                return YES;
            }
        }
    }

    return NO;
}


/***********************************************************************
* protocol_conformsToProtocol
* Returns YES if self conforms to other.
* Locking: acquires runtimeLock
**********************************************************************/
BOOL protocol_conformsToProtocol(Protocol *self, Protocol *other)
{
    BOOL result;
    rwlock_read(&runtimeLock);
    result = _protocol_conformsToProtocol_nolock(newprotocol(self), 
                                                 newprotocol(other));
    rwlock_unlock_read(&runtimeLock);
    return result;
}


/***********************************************************************
* protocol_isEqual
* Return YES if two protocols are equal (i.e. conform to each other)
* Locking: acquires runtimeLock
**********************************************************************/
BOOL protocol_isEqual(Protocol *self, Protocol *other)
{
    if (self == other) return YES;
    if (!self  ||  !other) return NO;

    if (!protocol_conformsToProtocol(self, other)) return NO;
    if (!protocol_conformsToProtocol(other, self)) return NO;

    return YES;
}


/***********************************************************************
* protocol_copyMethodDescriptionList
* Returns descriptions of a protocol's methods.
* Locking: acquires runtimeLock
**********************************************************************/
struct objc_method_description *
protocol_copyMethodDescriptionList(Protocol *p, 
                                   BOOL isRequiredMethod,BOOL isInstanceMethod,
                                   unsigned int *outCount)
{
    protocol_t *proto = newprotocol(p);
    struct objc_method_description *result = NULL;
    unsigned int count = 0;

    if (!proto) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    rwlock_read(&runtimeLock);

    method_list_t *mlist = NULL;

    if (isRequiredMethod) {
        if (isInstanceMethod) {
            mlist = proto->instanceMethods;
        } else {
            mlist = proto->classMethods;
        }
    } else {
        if (isInstanceMethod) {
            mlist = proto->optionalInstanceMethods;
        } else {
            mlist = proto->optionalClassMethods;
        }
    }

    if (mlist) {
        unsigned int i;
        count = mlist->count;
        result = (struct objc_method_description *)
            calloc(count + 1, sizeof(struct objc_method_description));
        for (i = 0; i < count; i++) {
            method_t *m = method_list_nth(mlist, i);
            result[i].name = sel_registerName((const char *)m->name);
            result[i].types = (char *)m->types;
        }
    }

    rwlock_unlock_read(&runtimeLock);

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* protocol_getProperty
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
static property_t * 
_protocol_getProperty_nolock(protocol_t *proto, const char *name, 
                             BOOL isRequiredProperty, BOOL isInstanceProperty)
{
    if (!isRequiredProperty  ||  !isInstanceProperty) {
        // Only required instance properties are currently supported
        return NULL;
    }

    property_list_t *plist;
    if ((plist = proto->instanceProperties)) {
        uint32_t i;
        for (i = 0; i < plist->count; i++) {
            property_t *prop = property_list_nth(plist, i);
            if (0 == strcmp(name, prop->name)) {
                return prop;
            }
        }
    }

    if (proto->protocols) {
        uintptr_t i;
        for (i = 0; i < proto->protocols->count; i++) {
            protocol_t *p = remapProtocol(proto->protocols->list[i]);
            property_t *prop = 
                _protocol_getProperty_nolock(p, name, 
                                             isRequiredProperty, 
                                             isInstanceProperty);
            if (prop) return prop;
        }
    }

    return NULL;
}

objc_property_t protocol_getProperty(Protocol *p, const char *name, 
                              BOOL isRequiredProperty, BOOL isInstanceProperty)
{
    property_t *result;

    if (!p  ||  !name) return NULL;

    rwlock_read(&runtimeLock);
    result = _protocol_getProperty_nolock(newprotocol(p), name, 
                                          isRequiredProperty, 
                                          isInstanceProperty);
    rwlock_unlock_read(&runtimeLock);
    
    return (objc_property_t)result;
}


/***********************************************************************
* protocol_copyPropertyList
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
static property_t **
copyPropertyList(property_list_t *plist, unsigned int *outCount)
{
    property_t **result = NULL;
    unsigned int count = 0;

    if (plist) {
        count = plist->count;
    }

    if (count > 0) {
        unsigned int i;
        result = (property_t **)malloc((count+1) * sizeof(property_t *));
        
        for (i = 0; i < count; i++) {
            result[i] = property_list_nth(plist, i);
        }
        result[i] = NULL;
    }

    if (outCount) *outCount = count;
    return result;
}

objc_property_t *protocol_copyPropertyList(Protocol *proto, unsigned int *outCount)
{
    property_t **result = NULL;

    if (!proto) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    rwlock_read(&runtimeLock);

    property_list_t *plist = newprotocol(proto)->instanceProperties;
    result = copyPropertyList(plist, outCount);

    rwlock_unlock_read(&runtimeLock);

    return (objc_property_t *)result;
}


/***********************************************************************
* protocol_copyProtocolList
* Copies this protocol's incorporated protocols. 
* Does not copy those protocol's incorporated protocols in turn.
* Locking: acquires runtimeLock
**********************************************************************/
Protocol * __unsafe_unretained * 
protocol_copyProtocolList(Protocol *p, unsigned int *outCount)
{
    unsigned int count = 0;
    Protocol **result = NULL;
    protocol_t *proto = newprotocol(p);
    
    if (!proto) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    rwlock_read(&runtimeLock);

    if (proto->protocols) {
        count = (unsigned int)proto->protocols->count;
    }
    if (count > 0) {
        result = (Protocol **)malloc((count+1) * sizeof(Protocol *));

        unsigned int i;
        for (i = 0; i < count; i++) {
            result[i] = (Protocol *)remapProtocol(proto->protocols->list[i]);
        }
        result[i] = NULL;
    }

    rwlock_unlock_read(&runtimeLock);

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* objc_allocateProtocol
* Creates a new protocol. The protocol may not be used until 
* objc_registerProtocol() is called.
* Returns NULL if a protocol with the same name already exists.
* Locking: acquires runtimeLock
**********************************************************************/
Protocol *
objc_allocateProtocol(const char *name)
{
    rwlock_write(&runtimeLock);

    if (NXMapGet(protocols(), name)) {
        rwlock_unlock_write(&runtimeLock);
        return NULL;
    }

    protocol_t *result = (protocol_t *)_calloc_internal(sizeof(protocol_t), 1);

    extern class_t OBJC_CLASS_$___IncompleteProtocol;
    Class cls = (Class)&OBJC_CLASS_$___IncompleteProtocol;
    result->isa = cls;
    result->name = _strdup_internal(name);

    // fixme reserve name without installing

    rwlock_unlock_write(&runtimeLock);

    return (Protocol *)result;
}


/***********************************************************************
* objc_registerProtocol
* Registers a newly-constructed protocol. The protocol is now 
* ready for use and immutable.
* Locking: acquires runtimeLock
**********************************************************************/
void objc_registerProtocol(Protocol *proto_gen) 
{
    protocol_t *proto = newprotocol(proto_gen);

    rwlock_write(&runtimeLock);

    extern class_t OBJC_CLASS_$___IncompleteProtocol;
    Class oldcls = (Class)&OBJC_CLASS_$___IncompleteProtocol;
    extern class_t OBJC_CLASS_$_Protocol;
    Class cls = (Class)&OBJC_CLASS_$_Protocol;

    if (proto->isa == cls) {
        _objc_inform("objc_registerProtocol: protocol '%s' was already "
                     "registered!", proto->name);
        rwlock_unlock_write(&runtimeLock);
        return;
    }
    if (proto->isa != oldcls) {
        _objc_inform("objc_registerProtocol: protocol '%s' was not allocated "
                     "with objc_allocateProtocol!", proto->name);
        rwlock_unlock_write(&runtimeLock);
        return;
    }

    proto->isa = cls;

    NXMapKeyCopyingInsert(protocols(), proto->name, proto);

    rwlock_unlock_write(&runtimeLock);
}


/***********************************************************************
* protocol_addProtocol
* Adds an incorporated protocol to another protocol.
* No method enforcement is performed.
* `proto` must be under construction. `addition` must not.
* Locking: acquires runtimeLock
**********************************************************************/
void 
protocol_addProtocol(Protocol *proto_gen, Protocol *addition_gen) 
{
    protocol_t *proto = newprotocol(proto_gen);
    protocol_t *addition = newprotocol(addition_gen);

    extern class_t OBJC_CLASS_$___IncompleteProtocol;
    Class cls = (Class)&OBJC_CLASS_$___IncompleteProtocol;

    if (!proto_gen) return;
    if (!addition_gen) return;

    rwlock_write(&runtimeLock);

    if (proto->isa != cls) {
        _objc_inform("protocol_addProtocol: modified protocol '%s' is not "
                     "under construction!", proto->name);
        rwlock_unlock_write(&runtimeLock);
        return;
    }
    if (addition->isa == cls) {
        _objc_inform("protocol_addProtocol: added protocol '%s' is still "
                     "under construction!", addition->name);
        rwlock_unlock_write(&runtimeLock);
        return;        
    }
    
    protocol_list_t *protolist = proto->protocols;
    if (!protolist) {
        protolist = (protocol_list_t *)
            _calloc_internal(1, sizeof(protocol_list_t) 
                             + sizeof(protolist->list[0]));
    } else {
        protolist = (protocol_list_t *)
            _realloc_internal(protolist, protocol_list_size(protolist) 
                              + sizeof(protolist->list[0]));
    }

    protolist->list[protolist->count++] = (protocol_ref_t)addition;
    proto->protocols = protolist;

    rwlock_unlock_write(&runtimeLock);        
}


/***********************************************************************
* protocol_addMethodDescription
* Adds a method to a protocol. The protocol must be under construction.
* Locking: acquires runtimeLock
**********************************************************************/
static void
_protocol_addMethod(method_list_t **list, SEL name, const char *types)
{
    if (!*list) {
        *list = (method_list_t *)
            _calloc_internal(sizeof(method_list_t), 1);
        (*list)->entsize_NEVER_USE = sizeof((*list)->first);
        setMethodListFixedUp(*list);
    } else {
        size_t size = method_list_size(*list) + method_list_entsize(*list);
        *list = (method_list_t *)
            _realloc_internal(*list, size);
    }

    method_t *meth = method_list_nth(*list, (*list)->count++);
    meth->name = name;
    meth->types = _strdup_internal(types ? types : "");
    meth->imp = NULL;
}

void 
protocol_addMethodDescription(Protocol *proto_gen, SEL name, const char *types,
                              BOOL isRequiredMethod, BOOL isInstanceMethod) 
{
    protocol_t *proto = newprotocol(proto_gen);

    extern class_t OBJC_CLASS_$___IncompleteProtocol;
    Class cls = (Class)&OBJC_CLASS_$___IncompleteProtocol;

    if (!proto_gen) return;

    rwlock_write(&runtimeLock);

    if (proto->isa != cls) {
        _objc_inform("protocol_addMethodDescription: protocol '%s' is not "
                     "under construction!", proto->name);
        rwlock_unlock_write(&runtimeLock);
        return;
    }

    if (isRequiredMethod  &&  isInstanceMethod) {
        _protocol_addMethod(&proto->instanceMethods, name, types);
    } else if (isRequiredMethod  &&  !isInstanceMethod) {
        _protocol_addMethod(&proto->classMethods, name, types);
    } else if (!isRequiredMethod  &&  isInstanceMethod) {
        _protocol_addMethod(&proto->optionalInstanceMethods, name, types);
    } else /*  !isRequiredMethod  &&  !isInstanceMethod) */ {
        _protocol_addMethod(&proto->optionalClassMethods, name, types);
    }

    rwlock_unlock_write(&runtimeLock);
}


/***********************************************************************
* protocol_addProperty
* Adds a property to a protocol. The protocol must be under construction.
* Locking: acquires runtimeLock
**********************************************************************/
static void 
_protocol_addProperty(property_list_t **plist, const char *name, 
                      const objc_property_attribute_t *attrs, 
                      unsigned int count)
{
    if (!*plist) {
        *plist = (property_list_t *)
            _calloc_internal(sizeof(property_list_t), 1);
        (*plist)->entsize = sizeof(property_t);
    } else {
        *plist = (property_list_t *)
            _realloc_internal(*plist, sizeof(property_list_t) 
                              + (*plist)->count * (*plist)->entsize);
    }

    property_t *prop = property_list_nth(*plist, (*plist)->count++);
    prop->name = _strdup_internal(name);
    prop->attributes = copyPropertyAttributeString(attrs, count);
}

void 
protocol_addProperty(Protocol *proto_gen, const char *name, 
                     const objc_property_attribute_t *attrs, 
                     unsigned int count,
                     BOOL isRequiredProperty, BOOL isInstanceProperty)
{
    protocol_t *proto = newprotocol(proto_gen);

    extern class_t OBJC_CLASS_$___IncompleteProtocol;
    Class cls = (Class)&OBJC_CLASS_$___IncompleteProtocol;

    if (!proto) return;
    if (!name) return;

    rwlock_write(&runtimeLock);

    if (proto->isa != cls) {
        _objc_inform("protocol_addProperty: protocol '%s' is not "
                     "under construction!", proto->name);
        rwlock_unlock_write(&runtimeLock);
        return;
    }

    if (isRequiredProperty  &&  isInstanceProperty) {
        _protocol_addProperty(&proto->instanceProperties, name, attrs, count);
    }
    //else if (isRequiredProperty  &&  !isInstanceProperty) {
    //    _protocol_addProperty(&proto->classProperties, name, attrs, count);
    //} else if (!isRequiredProperty  &&  isInstanceProperty) {
    //    _protocol_addProperty(&proto->optionalInstanceProperties, name, attrs, count);
    //} else /*  !isRequiredProperty  &&  !isInstanceProperty) */ {
    //    _protocol_addProperty(&proto->optionalClassProperties, name, attrs, count);
    //}

    rwlock_unlock_write(&runtimeLock);
}


/***********************************************************************
* objc_getClassList
* Returns pointers to all classes.
* This requires all classes be realized, which is regretfully non-lazy.
* Locking: acquires runtimeLock
**********************************************************************/
int 
objc_getClassList(Class *buffer, int bufferLen) 
{
    rwlock_write(&runtimeLock);

    realizeAllClasses();

    int count;
    class_t *cls;
    NXHashState state;
    NXHashTable *classes = realizedClasses();
    int allCount = NXCountHashTable(classes);

    if (!buffer) {
        rwlock_unlock_write(&runtimeLock);
        return allCount;
    }

    count = 0;
    state = NXInitHashState(classes);
    while (count < bufferLen  &&  
           NXNextHashState(classes, &state, (void **)&cls))
    {
        buffer[count++] = (Class)cls;
    }

    rwlock_unlock_write(&runtimeLock);

    return allCount;
}


/***********************************************************************
* objc_copyClassList
* Returns pointers to all classes.
* This requires all classes be realized, which is regretfully non-lazy.
* 
* outCount may be NULL. *outCount is the number of classes returned. 
* If the returned array is not NULL, it is NULL-terminated and must be 
* freed with free().
* Locking: write-locks runtimeLock
**********************************************************************/
Class *
objc_copyClassList(unsigned int *outCount)
{
    rwlock_write(&runtimeLock);

    realizeAllClasses();

    Class *result = NULL;
    NXHashTable *classes = realizedClasses();
    unsigned int count = NXCountHashTable(classes);

    if (count > 0) {
        class_t *cls;
        NXHashState state = NXInitHashState(classes);
        result = (Class *)malloc((1+count) * sizeof(Class));
        count = 0;
        while (NXNextHashState(classes, &state, (void **)&cls)) {
            result[count++] = (Class)cls;
        }
        result[count] = NULL;
    }

    rwlock_unlock_write(&runtimeLock);
        
    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* objc_copyProtocolList
* Returns pointers to all protocols.
* Locking: read-locks runtimeLock
**********************************************************************/
Protocol * __unsafe_unretained * 
objc_copyProtocolList(unsigned int *outCount) 
{
    rwlock_read(&runtimeLock);

    unsigned int count, i;
    Protocol *proto;
    const char *name;
    NXMapState state;
    NXMapTable *protocol_map = protocols();
    Protocol **result;

    count = NXCountMapTable(protocol_map);
    if (count == 0) {
        rwlock_unlock_read(&runtimeLock);
        if (outCount) *outCount = 0;
        return NULL;
    }

    result = (Protocol **)calloc(1 + count, sizeof(Protocol *));

    i = 0;
    state = NXInitMapState(protocol_map);
    while (NXNextMapState(protocol_map, &state, 
                          (const void **)&name, (const void **)&proto))
    {
        result[i++] = proto;
    }
    
    result[i++] = NULL;
    assert(i == count+1);

    rwlock_unlock_read(&runtimeLock);

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* objc_getProtocol
* Get a protocol by name, or return NULL
* Locking: read-locks runtimeLock
**********************************************************************/
Protocol *objc_getProtocol(const char *name)
{
    rwlock_read(&runtimeLock); 
    Protocol *result = (Protocol *)NXMapGet(protocols(), name);
    rwlock_unlock_read(&runtimeLock);
    return result;
}


/***********************************************************************
* class_copyMethodList
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
Method *
class_copyMethodList(Class cls_gen, unsigned int *outCount)
{
    class_t *cls = newcls(cls_gen);
    unsigned int count = 0;
    Method *result = NULL;

    if (!cls) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    rwlock_read(&runtimeLock);
    
    assert(isRealized(cls));

    FOREACH_METHOD_LIST(mlist, cls, {
        count += mlist->count;
    });

    if (count > 0) {
        unsigned int m;
        result = (Method *)malloc((count + 1) * sizeof(Method));
        
        m = 0;
        FOREACH_METHOD_LIST(mlist, cls, {
            unsigned int i;
            for (i = 0; i < mlist->count; i++) {
                Method aMethod = (Method)method_list_nth(mlist, i);
                if (ignoreSelector(method_getName(aMethod))) {
                    count--;
                    continue;
                }
                result[m++] = aMethod;
            }
        });
        result[m] = NULL;
    }

    rwlock_unlock_read(&runtimeLock);

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* class_copyIvarList
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
Ivar *
class_copyIvarList(Class cls_gen, unsigned int *outCount)
{
    class_t *cls = newcls(cls_gen);
    const ivar_list_t *ivars;
    Ivar *result = NULL;
    unsigned int count = 0;
    unsigned int i;

    if (!cls) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    rwlock_read(&runtimeLock);

    assert(isRealized(cls));
    
    if ((ivars = cls->data()->ro->ivars)  &&  ivars->count) {
        result = (Ivar *)malloc((ivars->count+1) * sizeof(Ivar));
        
        for (i = 0; i < ivars->count; i++) {
            ivar_t *ivar = ivar_list_nth(ivars, i);
            if (!ivar->offset) continue;  // anonymous bitfield
            result[count++] = (Ivar)ivar;
        }
        result[count] = NULL;
    }

    rwlock_unlock_read(&runtimeLock);
    
    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* class_copyPropertyList. Returns a heap block containing the 
* properties declared in the class, or NULL if the class 
* declares no properties. Caller must free the block.
* Does not copy any superclass's properties.
* Locking: read-locks runtimeLock
**********************************************************************/
objc_property_t *
class_copyPropertyList(Class cls_gen, unsigned int *outCount)
{
    class_t *cls = newcls(cls_gen);
    chained_property_list *plist;
    unsigned int count = 0;
    property_t **result = NULL;

    if (!cls) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    rwlock_read(&runtimeLock);

    assert(isRealized(cls));

    for (plist = cls->data()->properties; plist; plist = plist->next) {
        count += plist->count;
    }

    if (count > 0) {
        unsigned int p;
        result = (property_t **)malloc((count + 1) * sizeof(property_t *));
        
        p = 0;
        for (plist = cls->data()->properties; plist; plist = plist->next) {
            unsigned int i;
            for (i = 0; i < plist->count; i++) {
                result[p++] = &plist->list[i];
            }
        }
        result[p] = NULL;
    }

    rwlock_unlock_read(&runtimeLock);

    if (outCount) *outCount = count;
    return (objc_property_t *)result;
}


/***********************************************************************
* _class_getLoadMethod
* fixme
* Called only from add_class_to_loadable_list.
* Locking: runtimeLock must be read- or write-locked by the caller.
**********************************************************************/
IMP 
_class_getLoadMethod(Class cls_gen)
{
    rwlock_assert_locked(&runtimeLock);

    class_t *cls = newcls(cls_gen);
    const method_list_t *mlist;
    uint32_t i;

    assert(isRealized(cls));
    assert(isRealized(cls->isa));
    assert(!isMetaClass(cls));
    assert(isMetaClass(cls->isa));

    mlist = cls->isa->data()->ro->baseMethods;
    if (mlist) for (i = 0; i < mlist->count; i++) {
        method_t *m = method_list_nth(mlist, i);
        if (0 == strcmp((const char *)m->name, "load")) {
            return m->imp;
        }
    }

    return NULL;
}


/***********************************************************************
* _category_getName
* Returns a category's name.
* Locking: none
**********************************************************************/
const char *
_category_getName(Category cat)
{
    return newcategory(cat)->name;
}


/***********************************************************************
* _category_getClassName
* Returns a category's class's name
* Called only from add_category_to_loadable_list and 
* remove_category_from_loadable_list.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
const char *
_category_getClassName(Category cat)
{
    rwlock_assert_locked(&runtimeLock);
    return getName(remapClass(newcategory(cat)->cls));
}


/***********************************************************************
* _category_getClass
* Returns a category's class
* Called only by call_category_loads.
* Locking: read-locks runtimeLock
**********************************************************************/
Class 
_category_getClass(Category cat)
{
    rwlock_read(&runtimeLock);
    class_t *result = remapClass(newcategory(cat)->cls);
    assert(isRealized(result));  // ok for call_category_loads' usage
    rwlock_unlock_read(&runtimeLock);
    return (Class)result;
}


/***********************************************************************
* _category_getLoadMethod
* fixme
* Called only from add_category_to_loadable_list
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
IMP 
_category_getLoadMethod(Category cat)
{
    rwlock_assert_locked(&runtimeLock);

    const method_list_t *mlist;
    uint32_t i;

    mlist = newcategory(cat)->classMethods;
    if (mlist) for (i = 0; i < mlist->count; i++) {
        method_t *m = method_list_nth(mlist, i);
        if (0 == strcmp((const char *)m->name, "load")) {
            return m->imp;
        }
    }

    return NULL;
}


/***********************************************************************
* class_copyProtocolList
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
Protocol * __unsafe_unretained * 
class_copyProtocolList(Class cls_gen, unsigned int *outCount)
{
    class_t *cls = newcls(cls_gen);
    Protocol **r;
    const protocol_list_t **p;
    unsigned int count = 0;
    unsigned int i;
    Protocol **result = NULL;
    
    if (!cls) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    rwlock_read(&runtimeLock);

    assert(isRealized(cls));
    
    for (p = cls->data()->protocols; p  &&  *p; p++) {
        count += (uint32_t)(*p)->count;
    }

    if (count) {
        result = (Protocol **)malloc((count+1) * sizeof(Protocol *));
        r = result;
        for (p = cls->data()->protocols; p  &&  *p; p++) {
            for (i = 0; i < (*p)->count; i++) {
                *r++ = (Protocol *)remapProtocol((*p)->list[i]);
            }
        }
        *r++ = NULL;
    }

    rwlock_unlock_read(&runtimeLock);

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* _objc_copyClassNamesForImage
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
const char **
_objc_copyClassNamesForImage(header_info *hi, unsigned int *outCount)
{
    size_t count, i, shift;
    classref_t *classlist;
    const char **names;
    
    rwlock_read(&runtimeLock);
    
    classlist = _getObjc2ClassList(hi, &count);
    names = (const char **)malloc((count+1) * sizeof(const char *));
    
    shift = 0;
    for (i = 0; i < count; i++) {
        class_t *cls = remapClass(classlist[i]);
        if (cls) {
            names[i-shift] = getName(cls);
        } else {
            shift++;  // ignored weak-linked class
        }
    }
    count -= shift;
    names[count] = NULL;

    rwlock_unlock_read(&runtimeLock);

    if (outCount) *outCount = (unsigned int)count;
    return names;
}


/***********************************************************************
* _class_getCache
* fixme
* Locking: none
**********************************************************************/
Cache 
_class_getCache(Class cls)
{
    return newcls(cls)->cache;
}


/***********************************************************************
* _class_getInstanceSize
* Uses alignedInstanceSize() to ensure that 
*   obj + class_getInstanceSize(obj->isa) == object_getIndexedIvars(obj)
* Locking: none
**********************************************************************/
size_t 
_class_getInstanceSize(Class cls)
{
    if (!cls) return 0;
    return alignedInstanceSize(newcls(cls));
}

static uint32_t
unalignedInstanceSize(class_t *cls)
{
    assert(cls);
    assert(isRealized(cls));
    return (uint32_t)cls->data()->ro->instanceSize;
}

static uint32_t
alignedInstanceSize(class_t *cls)
{
    assert(cls);
    assert(isRealized(cls));
    // fixme rdar://5278267
    return (uint32_t)((unalignedInstanceSize(cls) + WORD_MASK) & ~WORD_MASK);
}

/***********************************************************************
 * _class_getInstanceStart
 * Uses alignedInstanceStart() to ensure that ARR layout strings are
 * interpreted relative to the first word aligned ivar of an object.
 * Locking: none
 **********************************************************************/

static uint32_t
alignedInstanceStart(class_t *cls)
{
    assert(cls);
    assert(isRealized(cls));
    return (uint32_t)((cls->data()->ro->instanceStart + WORD_MASK) & ~WORD_MASK);
}

uint32_t _class_getInstanceStart(Class cls_gen) {
    class_t *cls = newcls(cls_gen);
    return alignedInstanceStart(cls);
}


/***********************************************************************
* class_getVersion
* fixme
* Locking: none
**********************************************************************/
int 
class_getVersion(Class cls)
{
    if (!cls) return 0;
    assert(isRealized(newcls(cls)));
    return newcls(cls)->data()->version;
}


/***********************************************************************
* _class_setCache
* fixme
* Locking: none
**********************************************************************/
void 
_class_setCache(Class cls, Cache cache)
{
    newcls(cls)->cache = cache;
}


/***********************************************************************
* class_setVersion
* fixme
* Locking: none
**********************************************************************/
void 
class_setVersion(Class cls, int version)
{
    if (!cls) return;
    assert(isRealized(newcls(cls)));
    newcls(cls)->data()->version = version;
}


/***********************************************************************
* _class_getName
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
const char *_class_getName(Class cls)
{
    if (!cls) return "nil";
    // fixme hack rwlock_write(&runtimeLock);
    const char *name = getName(newcls(cls));
    // rwlock_unlock_write(&runtimeLock);
    return name;
}


/***********************************************************************
* getName
* fixme
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static const char *
getName(class_t *cls)
{
    // fixme hack rwlock_assert_writing(&runtimeLock);
    assert(cls);

    if (isRealized(cls)) {
        return cls->data()->ro->name;
    } else {
        return ((const class_ro_t *)cls->data())->name;
    }
}

static method_t *findMethodInSortedMethodList(SEL key, const method_list_t *list)
{
    const method_t * const first = &list->first;
    const method_t *base = first;
    const method_t *probe;
    uintptr_t keyValue = (uintptr_t)key;
    uint32_t count;
    
    for (count = list->count; count != 0; count >>= 1) {
        probe = base + (count >> 1);
        
        uintptr_t probeValue = (uintptr_t)probe->name;
        
        if (keyValue == probeValue) {
            // `probe` is a match.
            // Rewind looking for the *first* occurrence of this value.
            // This is required for correct category overrides.
            while (probe > first && keyValue == (uintptr_t)probe[-1].name) {
                probe--;
            }
            return (method_t *)probe;
        }
        
        if (keyValue > probeValue) {
            base = probe + 1;
            count--;
        }
    }
    
    return NULL;
}

/***********************************************************************
* getMethodNoSuper_nolock
* fixme
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static method_t *search_method_list(const method_list_t *mlist, SEL sel)
{
    int methodListIsFixedUp = isMethodListFixedUp(mlist);
    int methodListHasExpectedSize = mlist->getEntsize() == sizeof(method_t);
    
    if (__builtin_expect(methodListIsFixedUp && methodListHasExpectedSize, 1)) {
        return findMethodInSortedMethodList(sel, mlist);
    } else {
        // Linear search of unsorted method list
        method_list_t::method_iterator iter = mlist->begin();
        method_list_t::method_iterator end = mlist->end();
        for ( ; iter != end; ++iter) {
            if (iter->name == sel) return &*iter;
        }
    }

#ifndef NDEBUG
    // sanity-check negative results
    if (isMethodListFixedUp(mlist)) {
        method_list_t::method_iterator iter = mlist->begin();
        method_list_t::method_iterator end = mlist->end();
        for ( ; iter != end; ++iter) {
            if (iter->name == sel) {
                _objc_fatal("linear search worked when binary search did not");
            }
        }
    }
#endif

    return NULL;
}

static method_t *
getMethodNoSuper_nolock(class_t *cls, SEL sel)
{
    rwlock_assert_locked(&runtimeLock);

    assert(isRealized(cls));
    // fixme nil cls? 
    // fixme NULL sel?

    FOREACH_METHOD_LIST(mlist, cls, {
        method_t *m = search_method_list(mlist, sel);
        if (m) return m;
    });

    return NULL;
}


/***********************************************************************
* _class_getMethodNoSuper
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
Method 
_class_getMethodNoSuper(Class cls, SEL sel)
{
    rwlock_read(&runtimeLock);
    Method result = (Method)getMethodNoSuper_nolock(newcls(cls), sel);
    rwlock_unlock_read(&runtimeLock);
    return result;
}

/***********************************************************************
* _class_getMethodNoSuper
* For use inside lockForMethodLookup() only.
* Locking: read-locks runtimeLock
**********************************************************************/
Method 
_class_getMethodNoSuper_nolock(Class cls, SEL sel)
{
    return (Method)getMethodNoSuper_nolock(newcls(cls), sel);
}


/***********************************************************************
* getMethod_nolock
* fixme
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static method_t *
getMethod_nolock(class_t *cls, SEL sel)
{
    method_t *m = NULL;

    rwlock_assert_locked(&runtimeLock);

    // fixme nil cls?
    // fixme NULL sel?

    assert(isRealized(cls));

    while (cls  &&  ((m = getMethodNoSuper_nolock(cls, sel))) == NULL) {
        cls = getSuperclass(cls);
    }

    return m;
}


/***********************************************************************
* _class_getMethod
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
Method _class_getMethod(Class cls, SEL sel)
{
    Method m;
    rwlock_read(&runtimeLock);
    m = (Method)getMethod_nolock(newcls(cls), sel);
    rwlock_unlock_read(&runtimeLock);
    return m;
}


/***********************************************************************
* ABI-specific lookUpMethod helpers.
* Locking: read- and write-locks runtimeLock.
**********************************************************************/
void lockForMethodLookup(void)
{
    rwlock_read(&runtimeLock);
}
void unlockForMethodLookup(void)
{
    rwlock_unlock_read(&runtimeLock);
}

IMP prepareForMethodLookup(Class cls, SEL sel, BOOL init, id obj)
{
    rwlock_assert_unlocked(&runtimeLock);

    if (!isRealized(newcls(cls))) {
        rwlock_write(&runtimeLock);
        realizeClass(newcls(cls));
        rwlock_unlock_write(&runtimeLock);
    }

    if (init  &&  !_class_isInitialized(cls)) {
        _class_initialize (_class_getNonMetaClass(cls, obj));
        // If sel == initialize, _class_initialize will send +initialize and 
        // then the messenger will send +initialize again after this 
        // procedure finishes. Of course, if this is not being called 
        // from the messenger then it won't happen. 2778172
    }

    return NULL;
}


/***********************************************************************
* class_getProperty
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
objc_property_t class_getProperty(Class cls_gen, const char *name)
{
    property_t *result = NULL;
    chained_property_list *plist;
    class_t *cls = newcls(cls_gen);

    if (!cls  ||  !name) return NULL;

    rwlock_read(&runtimeLock);

    assert(isRealized(cls));

    for ( ; cls; cls = getSuperclass(cls)) {
        for (plist = cls->data()->properties; plist; plist = plist->next) {
            uint32_t i;
            for (i = 0; i < plist->count; i++) {
                if (0 == strcmp(name, plist->list[i].name)) {
                    result = &plist->list[i];
                    goto done;
                }
            }
        }
    }

 done:
    rwlock_unlock_read(&runtimeLock);

    return (objc_property_t)result;
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
BOOL _class_isMetaClass(Class cls)
{
    if (!cls) return NO;
    return isMetaClass(newcls(cls));
}

static BOOL 
isMetaClass(class_t *cls)
{
    assert(cls);
    assert(isRealized(cls));
    return (cls->data()->ro->flags & RO_META) ? YES : NO;
}

class_t *getMeta(class_t *cls)
{
    if (isMetaClass(cls)) return cls;
    else return cls->isa;
}

Class _class_getMeta(Class cls)
{
    return (Class)getMeta(newcls(cls));
}

Class gdb_class_getClass(Class cls)
{
    const char *className = getName(newcls(cls));
    if(!className || !strlen(className)) return Nil;
    Class rCls = look_up_class(className, NO, NO);
    return rCls;
}

Class gdb_object_getClass(id obj)
{
    Class cls = _object_getClass(obj);
    return gdb_class_getClass(cls);
}

BOOL gdb_objc_isRuntimeLocked()
{
    if (rwlock_try_write(&runtimeLock)) {
        rwlock_unlock_write(&runtimeLock);
    } else
        return YES;
    
    if (mutex_try_lock(&cacheUpdateLock)) {
        mutex_unlock(&cacheUpdateLock);
    } else 
        return YES;
    
    return NO;
}

/***********************************************************************
* Locking: fixme
**********************************************************************/
BOOL 
_class_isInitializing(Class cls_gen)
{
    class_t *cls = newcls(_class_getMeta(cls_gen));
    return (cls->data()->flags & RW_INITIALIZING) ? YES : NO;
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
BOOL 
_class_isInitialized(Class cls_gen)
{
    class_t *cls = newcls(_class_getMeta(cls_gen));
    return (cls->data()->flags & RW_INITIALIZED) ? YES : NO;
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
void 
_class_setInitializing(Class cls_gen)
{
    assert(!_class_isMetaClass(cls_gen));
    class_t *cls = newcls(_class_getMeta(cls_gen));
    changeInfo(cls, RW_INITIALIZING, 0);
}


/***********************************************************************
* Locking: write-locks runtimeLock
**********************************************************************/
void 
_class_setInitialized(Class cls_gen)
{
    class_t *metacls;
    class_t *cls;

    rwlock_write(&runtimeLock);

    assert(!_class_isMetaClass(cls_gen));

    cls = newcls(cls_gen);
    metacls = getMeta(cls);

    // Update vtables (initially postponed pending +initialize completion)
    // Do cls first because root metacls is a subclass of root cls
    updateVtable(cls, YES);
    updateVtable(metacls, YES);

    rwlock_unlock_write(&runtimeLock);

    changeInfo(metacls, RW_INITIALIZED, RW_INITIALIZING);
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
BOOL 
_class_shouldGrowCache(Class cls)
{
    return YES; // fixme good or bad for memory use?
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
void 
_class_setGrowCache(Class cls, BOOL grow)
{
    // fixme good or bad for memory use?
}


/***********************************************************************
* _class_isLoadable
* fixme
* Locking: none
**********************************************************************/
BOOL 
_class_isLoadable(Class cls)
{
    assert(isRealized(newcls(cls)));
    return YES;  // any class registered for +load is definitely loadable
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
static BOOL 
hasCxxStructors(class_t *cls)
{
    // this DOES check superclasses too, because addSubclass()
    // propagates the flag from the superclass.
    assert(isRealized(cls));
    return (cls->data()->flags & RW_HAS_CXX_STRUCTORS) ? YES : NO;
}

BOOL 
_class_hasCxxStructors(Class cls)
{
    return hasCxxStructors(newcls(cls));
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
BOOL
_class_shouldFinalizeOnMainThread(Class cls)
{
    assert(isRealized(newcls(cls)));
    return (newcls(cls)->data()->flags & RW_FINALIZE_ON_MAIN_THREAD) ? YES : NO;
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
void
_class_setFinalizeOnMainThread(Class cls)
{
    assert(isRealized(newcls(cls)));
    changeInfo(newcls(cls), RW_FINALIZE_ON_MAIN_THREAD, 0);
}


/***********************************************************************
* _class_instancesHaveAssociatedObjects
* May manipulate unrealized future classes in the CF-bridged case.
**********************************************************************/
BOOL
_class_instancesHaveAssociatedObjects(Class cls_gen)
{
    class_t *cls = newcls(cls_gen);
    assert(isFuture(cls)  ||  isRealized(cls));
    return (cls->data()->flags & RW_INSTANCES_HAVE_ASSOCIATED_OBJECTS) ? YES : NO;
}


/***********************************************************************
* _class_setInstancesHaveAssociatedObjects
* May manipulate unrealized future classes in the CF-bridged case.
**********************************************************************/
void
_class_setInstancesHaveAssociatedObjects(Class cls_gen)
{
    class_t *cls = newcls(cls_gen);
    assert(isFuture(cls)  ||  isRealized(cls));
    changeInfo(cls, RW_INSTANCES_HAVE_ASSOCIATED_OBJECTS, 0);
}


/***********************************************************************
 * _class_usesAutomaticRetainRelease
 * Returns YES if class was compiled with -fobjc-arc
 **********************************************************************/
BOOL _class_usesAutomaticRetainRelease(Class cls_gen)
{
    class_t *cls = newcls(cls_gen);
    return (cls->data()->ro->flags & RO_IS_ARR) ? YES : NO;
}


/***********************************************************************
* Return YES if sel is used by retain/release implementors
**********************************************************************/
static bool isRRSelector(SEL sel)
{
    return (sel == SEL_retain  ||  sel == SEL_release  ||  
            sel == SEL_autorelease || sel == SEL_retainCount);
}


/***********************************************************************
* Return YES if sel is used by allocWithZone implementors
**********************************************************************/
static bool isAWZSelector(SEL sel)
{
    return (sel == SEL_allocWithZone);
}


/***********************************************************************
* Mark this class and all of its subclasses as implementors or 
* inheritors of custom RR (retain/release/autorelease/retainCount)
**********************************************************************/
void class_t::setHasCustomRR(bool inherited) 
{
    rwlock_assert_writing(&runtimeLock);

    if (hasCustomRR()) return;
    
    FOREACH_REALIZED_CLASS_AND_SUBCLASS(c, this, {
        if (PrintCustomRR && !c->hasCustomRR()) {
            _objc_inform("CUSTOM RR:  %s%s%s", getName(c), 
                         isMetaClass(c) ? " (meta)" : "", 
                         (inherited  ||  c != this) ? " (inherited)" : "");
        }
#if CLASS_FAST_FLAGS_VIA_RW_DATA        
        c->data_NEVER_USE |= (uintptr_t)1;
#else
        c->data()->flags |= RW_HAS_CUSTOM_RR;
#endif
    });
}


/***********************************************************************
* Mark this class and all of its subclasses as implementors or 
* inheritors of custom allocWithZone:
**********************************************************************/
void class_t::setHasCustomAWZ(bool inherited ) 
{
    rwlock_assert_writing(&runtimeLock);

    if (hasCustomAWZ()) return;
    
    FOREACH_REALIZED_CLASS_AND_SUBCLASS(c, this, {
        if (PrintCustomAWZ && !c->hasCustomAWZ()) {
            _objc_inform("CUSTOM AWZ: %s%s%s", getName(c), 
                         isMetaClass(c) ? " (meta)" : "", 
                         (inherited  ||  c != this) ? " (inherited)" : "");
        }
#if CLASS_FAST_FLAGS_VIA_RW_DATA        
        c->data_NEVER_USE |= (uintptr_t)2;
#else
        c->data()->flags |= RW_HAS_CUSTOM_AWZ;
#endif
    });
}


/***********************************************************************
* Update custom RR and AWZ when a method changes its IMP
**********************************************************************/
static void
updateCustomRR_AWZ(class_t *cls, method_t *meth)
{
    // In almost all cases, IMP swizzling does not affect custom RR/AWZ bits. 
    // The class is already marked for custom RR/AWZ, so changing the IMP 
    // does not transition from non-custom to custom.
    // 
    // The only cases where IMP swizzling can affect the RR/AWZ bits is 
    // if the swizzled method is one of the methods that is assumed to be 
    // non-custom. These special cases come from attachMethodLists(). 
    // We look for such cases here if we do not know the affected class.

    if (isRRSelector(meth->name)) {
        if (cls) {
            cls->setHasCustomRR();
        } else {
            // Don't know the class. 
            // The only special case is class NSObject.
            FOREACH_METHOD_LIST(mlist, classNSObject(), {
                for (uint32_t i = 0; i < mlist->count; i++) {
                    if (meth == method_list_nth(mlist, i)) {
                        // Yep, they're swizzling NSObject.
                        classNSObject()->setHasCustomRR();
                        return;
                    }
                }
            });
        }
    }
    else if (isAWZSelector(meth->name)) {
        if (cls) {
            cls->setHasCustomAWZ();
        } else {
            // Don't know the class. 
            // The only special case is metaclass NSObject.
            FOREACH_METHOD_LIST(mlist, classNSObject()->isa, {
                for (uint32_t i = 0; i < mlist->count; i++) {
                    if (meth == method_list_nth(mlist, i)) {
                        // Yep, they're swizzling metaclass NSObject.
                        classNSObject()->isa->setHasCustomRR();
                        return;
                    }
                }
            });
        }
    }
}

/***********************************************************************
* Locking: none
* fixme assert realized to get superclass remapping?
**********************************************************************/
Class 
_class_getSuperclass(Class cls)
{
    return (Class)getSuperclass(newcls(cls));
}

static class_t *
getSuperclass(class_t *cls)
{
    if (!cls) return NULL;
    return cls->superclass;
}


/***********************************************************************
* class_getIvarLayout
* Called by the garbage collector. 
* The class must be NULL or already realized. 
* Locking: none
**********************************************************************/
const uint8_t *
class_getIvarLayout(Class cls_gen)
{
    class_t *cls = newcls(cls_gen);
    if (cls) return cls->data()->ro->ivarLayout;
    else return NULL;
}


/***********************************************************************
* class_getWeakIvarLayout
* Called by the garbage collector. 
* The class must be NULL or already realized. 
* Locking: none
**********************************************************************/
const uint8_t *
class_getWeakIvarLayout(Class cls_gen)
{
    class_t *cls = newcls(cls_gen);
    if (cls) return cls->data()->ro->weakIvarLayout;
    else return NULL;
}


/***********************************************************************
* class_setIvarLayout
* Changes the class's GC scan layout.
* NULL layout means no unscanned ivars
* The class must be under construction.
* fixme: sanity-check layout vs instance size?
* fixme: sanity-check layout vs superclass?
* Locking: acquires runtimeLock
**********************************************************************/
void
class_setIvarLayout(Class cls_gen, const uint8_t *layout)
{
    class_t *cls = newcls(cls_gen);
    if (!cls) return;

    rwlock_write(&runtimeLock);
    
    // Can only change layout of in-construction classes.
    // note: if modifications to post-construction classes were 
    //   allowed, there would be a race below (us vs. concurrent GC scan)
    if (!(cls->data()->flags & RW_CONSTRUCTING)) {
        _objc_inform("*** Can't set ivar layout for already-registered "
                     "class '%s'", getName(cls));
        rwlock_unlock_write(&runtimeLock);
        return;
    }

    class_ro_t *ro_w = make_ro_writeable(cls->data());

    try_free(ro_w->ivarLayout);
    ro_w->ivarLayout = _ustrdup_internal(layout);

    rwlock_unlock_write(&runtimeLock);
}

// SPI:  Instance-specific object layout.

void
_class_setIvarLayoutAccessor(Class cls_gen, const uint8_t* (*accessor) (id object)) {
    class_t *cls = newcls(cls_gen);
    if (!cls) return;

    rwlock_write(&runtimeLock);

    class_ro_t *ro_w = make_ro_writeable(cls->data());

    // FIXME:  this really isn't safe to free if there are instances of this class already.
    if (!(cls->data()->flags & RW_HAS_INSTANCE_SPECIFIC_LAYOUT)) try_free(ro_w->ivarLayout);
    ro_w->ivarLayout = (uint8_t *)accessor;
    changeInfo(cls, RW_HAS_INSTANCE_SPECIFIC_LAYOUT, 0);

    rwlock_unlock_write(&runtimeLock);
}

const uint8_t *
_object_getIvarLayout(Class cls_gen, id object) {
    class_t *cls = newcls(cls_gen);
    if (cls) {
        const uint8_t* layout = cls->data()->ro->ivarLayout;
        if (cls->data()->flags & RW_HAS_INSTANCE_SPECIFIC_LAYOUT) {
            const uint8_t* (*accessor) (id object) = (const uint8_t* (*)(id))layout;
            layout = accessor(object);
        }
        return layout;
    }
    return NULL;
}

/***********************************************************************
* class_setWeakIvarLayout
* Changes the class's GC weak layout.
* NULL layout means no weak ivars
* The class must be under construction.
* fixme: sanity-check layout vs instance size?
* fixme: sanity-check layout vs superclass?
* Locking: acquires runtimeLock
**********************************************************************/
void
class_setWeakIvarLayout(Class cls_gen, const uint8_t *layout)
{
    class_t *cls = newcls(cls_gen);
    if (!cls) return;

    rwlock_write(&runtimeLock);
    
    // Can only change layout of in-construction classes.
    // note: if modifications to post-construction classes were 
    //   allowed, there would be a race below (us vs. concurrent GC scan)
    if (!(cls->data()->flags & RW_CONSTRUCTING)) {
        _objc_inform("*** Can't set weak ivar layout for already-registered "
                     "class '%s'", getName(cls));
        rwlock_unlock_write(&runtimeLock);
        return;
    }

    class_ro_t *ro_w = make_ro_writeable(cls->data());

    try_free(ro_w->weakIvarLayout);
    ro_w->weakIvarLayout = _ustrdup_internal(layout);

    rwlock_unlock_write(&runtimeLock);
}


/***********************************************************************
* _class_getVariable
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
Ivar 
_class_getVariable(Class cls, const char *name, Class *memberOf)
{
    rwlock_read(&runtimeLock);

    for ( ; cls != Nil; cls = class_getSuperclass(cls)) {
        ivar_t *ivar = getIvar(newcls(cls), name);
        if (ivar) {
            rwlock_unlock_read(&runtimeLock);
            if (memberOf) *memberOf = cls;
            return (Ivar)ivar;
        }
    }

    rwlock_unlock_read(&runtimeLock);

    return NULL;
}


/***********************************************************************
* class_conformsToProtocol
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
BOOL class_conformsToProtocol(Class cls_gen, Protocol *proto_gen)
{
    class_t *cls = newcls(cls_gen);
    protocol_t *proto = newprotocol(proto_gen);
    const protocol_list_t **plist;
    unsigned int i;
    BOOL result = NO;
    
    if (!cls_gen) return NO;
    if (!proto_gen) return NO;

    rwlock_read(&runtimeLock);

    assert(isRealized(cls));

    for (plist = cls->data()->protocols; plist  &&  *plist; plist++) {
        for (i = 0; i < (*plist)->count; i++) {
            protocol_t *p = remapProtocol((*plist)->list[i]);
            if (p == proto || _protocol_conformsToProtocol_nolock(p, proto)) {
                result = YES;
                goto done;
            }
        }
    }

 done:
    rwlock_unlock_read(&runtimeLock);

    return result;
}


/***********************************************************************
* addMethod
* fixme
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static IMP 
addMethod(class_t *cls, SEL name, IMP imp, const char *types, BOOL replace)
{
    IMP result = NULL;

    rwlock_assert_writing(&runtimeLock);

    assert(types);
    assert(isRealized(cls));

    method_t *m;
    if ((m = getMethodNoSuper_nolock(cls, name))) {
        // already exists
        if (!replace) {
            result = _method_getImplementation(m);
        } else {
            result = _method_setImplementation(cls, m, imp);
        }
    } else {
        // fixme optimize
        method_list_t *newlist;
        newlist = (method_list_t *)_calloc_internal(sizeof(*newlist), 1);
        newlist->entsize_NEVER_USE = (uint32_t)sizeof(method_t) | fixed_up_method_list;
        newlist->count = 1;
        newlist->first.name = name;
        newlist->first.types = strdup(types);
        if (!ignoreSelector(name)) {
            newlist->first.imp = imp;
        } else {
            newlist->first.imp = (IMP)&_objc_ignored_method;
        }

        BOOL vtablesAffected = NO;
        attachMethodLists(cls, &newlist, 1, NO, NO, &vtablesAffected);
        flushCaches(cls);
        if (vtablesAffected) flushVtables(cls);

        result = NULL;
    }

    return result;
}


BOOL 
class_addMethod(Class cls, SEL name, IMP imp, const char *types)
{
    if (!cls) return NO;

    rwlock_write(&runtimeLock);
    IMP old = addMethod(newcls(cls), name, imp, types ?: "", NO);
    rwlock_unlock_write(&runtimeLock);
    return old ? NO : YES;
}


IMP 
class_replaceMethod(Class cls, SEL name, IMP imp, const char *types)
{
    if (!cls) return NULL;

    rwlock_write(&runtimeLock);
    IMP old = addMethod(newcls(cls), name, imp, types ?: "", YES);
    rwlock_unlock_write(&runtimeLock);
    return old;
}


/***********************************************************************
* class_addIvar
* Adds an ivar to a class.
* Locking: acquires runtimeLock
**********************************************************************/
BOOL 
class_addIvar(Class cls_gen, const char *name, size_t size, 
              uint8_t alignment, const char *type)
{
    class_t *cls = newcls(cls_gen);

    if (!cls) return NO;

    if (!type) type = "";
    if (name  &&  0 == strcmp(name, "")) name = NULL;

    rwlock_write(&runtimeLock);

    assert(isRealized(cls));

    // No class variables
    if (isMetaClass(cls)) {
        rwlock_unlock_write(&runtimeLock);
        return NO;
    }

    // Can only add ivars to in-construction classes.
    if (!(cls->data()->flags & RW_CONSTRUCTING)) {
        rwlock_unlock_write(&runtimeLock);
        return NO;
    }

    // Check for existing ivar with this name, unless it's anonymous.
    // Check for too-big ivar.
    // fixme check for superclass ivar too?
    if ((name  &&  getIvar(cls, name))  ||  size > UINT32_MAX) {
        rwlock_unlock_write(&runtimeLock);
        return NO;
    }

    class_ro_t *ro_w = make_ro_writeable(cls->data());

    // fixme allocate less memory here
    
    ivar_list_t *oldlist, *newlist;
    if ((oldlist = (ivar_list_t *)cls->data()->ro->ivars)) {
        size_t oldsize = ivar_list_size(oldlist);
        newlist = (ivar_list_t *)
            _calloc_internal(oldsize + oldlist->entsize, 1);
        memcpy(newlist, oldlist, oldsize);
        _free_internal(oldlist);
    } else {
        newlist = (ivar_list_t *)
            _calloc_internal(sizeof(ivar_list_t), 1);
        newlist->entsize = (uint32_t)sizeof(ivar_t);
    }

    uint32_t offset = unalignedInstanceSize(cls);
    uint32_t alignMask = (1<<alignment)-1;
    offset = (offset + alignMask) & ~alignMask;

    ivar_t *ivar = ivar_list_nth(newlist, newlist->count++);
    ivar->offset = (uintptr_t *)_malloc_internal(sizeof(*ivar->offset));
    *ivar->offset = offset;
    ivar->name = name ? _strdup_internal(name) : NULL;
    ivar->type = _strdup_internal(type);
    ivar->alignment = alignment;
    ivar->size = (uint32_t)size;

    ro_w->ivars = newlist;
    ro_w->instanceSize = (uint32_t)(offset + size);

    // Ivar layout updated in registerClass.

    rwlock_unlock_write(&runtimeLock);

    return YES;
}


/***********************************************************************
* class_addProtocol
* Adds a protocol to a class.
* Locking: acquires runtimeLock
**********************************************************************/
BOOL class_addProtocol(Class cls_gen, Protocol *protocol_gen)
{
    class_t *cls = newcls(cls_gen);
    protocol_t *protocol = newprotocol(protocol_gen);
    protocol_list_t *plist;
    const protocol_list_t **plistp;

    if (!cls) return NO;
    if (class_conformsToProtocol(cls_gen, protocol_gen)) return NO;

    rwlock_write(&runtimeLock);

    assert(isRealized(cls));
    
    // fixme optimize
    plist = (protocol_list_t *)
        _malloc_internal(sizeof(protocol_list_t) + sizeof(protocol_t *));
    plist->count = 1;
    plist->list[0] = (protocol_ref_t)protocol;
    
    unsigned int count = 0;
    for (plistp = cls->data()->protocols; plistp && *plistp; plistp++) {
        count++;
    }

    cls->data()->protocols = (const protocol_list_t **)
        _realloc_internal(cls->data()->protocols, 
                          (count+2) * sizeof(protocol_list_t *));
    cls->data()->protocols[count] = plist;
    cls->data()->protocols[count+1] = NULL;

    // fixme metaclass?

    rwlock_unlock_write(&runtimeLock);

    return YES;
}


/***********************************************************************
* class_addProperty
* Adds a property to a class.
* Locking: acquires runtimeLock
**********************************************************************/
static BOOL 
_class_addProperty(Class cls_gen, const char *name, 
                   const objc_property_attribute_t *attrs, unsigned int count, 
                   BOOL replace)
{
    class_t *cls = newcls(cls_gen);
    chained_property_list *plist;

    if (!cls) return NO;
    if (!name) return NO;

    property_t *prop = class_getProperty(cls_gen, name);
    if (prop  &&  !replace) {
        // already exists, refuse to replace
        return NO;
    } 
    else if (prop) {
        // replace existing
        rwlock_write(&runtimeLock);
        try_free(prop->attributes);
        prop->attributes = copyPropertyAttributeString(attrs, count);
        rwlock_unlock_write(&runtimeLock);
        return YES;
    }
    else {
        rwlock_write(&runtimeLock);
        
        assert(isRealized(cls));
        
        plist = (chained_property_list *)
            _malloc_internal(sizeof(*plist) + sizeof(plist->list[0]));
        plist->count = 1;
        plist->list[0].name = _strdup_internal(name);
        plist->list[0].attributes = copyPropertyAttributeString(attrs, count);
        
        plist->next = cls->data()->properties;
        cls->data()->properties = plist;
        
        rwlock_unlock_write(&runtimeLock);
        
        return YES;
    }
}

BOOL 
class_addProperty(Class cls_gen, const char *name, 
                  const objc_property_attribute_t *attrs, unsigned int n)
{
    return _class_addProperty(cls_gen, name, attrs, n, NO);
}

void 
class_replaceProperty(Class cls_gen, const char *name, 
                      const objc_property_attribute_t *attrs, unsigned int n)
{
    _class_addProperty(cls_gen, name, attrs, n, YES);
}


/***********************************************************************
* look_up_class
* Look up a class by name, and realize it.
* Locking: acquires runtimeLock
**********************************************************************/
id 
look_up_class(const char *name, 
              BOOL includeUnconnected __attribute__((unused)), 
              BOOL includeClassHandler __attribute__((unused)))
{
    if (!name) return nil;

    rwlock_read(&runtimeLock);
    class_t *result = getClass(name);
    BOOL unrealized = result  &&  !isRealized(result);
    rwlock_unlock_read(&runtimeLock);
    if (unrealized) {
        rwlock_write(&runtimeLock);
        realizeClass(result);
        rwlock_unlock_write(&runtimeLock);
    }
    return (id)result;
}


/***********************************************************************
* objc_duplicateClass
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
Class 
objc_duplicateClass(Class original_gen, const char *name, 
                    size_t extraBytes)
{
    class_t *original = newcls(original_gen);
    class_t *duplicate;

    rwlock_write(&runtimeLock);

    assert(isRealized(original));
    assert(!isMetaClass(original));

    duplicate = (class_t *)
        _calloc_class(alignedInstanceSize(original->isa) + extraBytes);
    if (unalignedInstanceSize(original->isa) < sizeof(class_t)) {
        _objc_inform("busted! %s\n", original->data()->ro->name);
    }


    duplicate->isa = original->isa;
    duplicate->superclass = original->superclass;
    duplicate->cache = (Cache)&_objc_empty_cache;
    duplicate->vtable = &_objc_empty_vtable;

    duplicate->setData((class_rw_t *)_calloc_internal(sizeof(*original->data()), 1));
    duplicate->data()->flags = (original->data()->flags | RW_COPIED_RO) & ~RW_SPECIALIZED_VTABLE;
    duplicate->data()->version = original->data()->version;
    duplicate->data()->firstSubclass = NULL;
    duplicate->data()->nextSiblingClass = NULL;

    duplicate->data()->ro = (class_ro_t *)
        _memdup_internal(original->data()->ro, sizeof(*original->data()->ro));
    *(char **)&duplicate->data()->ro->name = _strdup_internal(name);
    
    if (original->data()->flags & RW_METHOD_ARRAY) {
        duplicate->data()->method_lists = (method_list_t **)
            _memdup_internal(original->data()->method_lists, 
                             malloc_size(original->data()->method_lists));
        method_list_t **mlistp;
        for (mlistp = duplicate->data()->method_lists; *mlistp; mlistp++) {
            *mlistp = (method_list_t *)
                _memdup_internal(*mlistp, method_list_size(*mlistp));
        }
    } else {
        if (original->data()->method_list) {
            duplicate->data()->method_list = (method_list_t *)
                _memdup_internal(original->data()->method_list, 
                                 method_list_size(original->data()->method_list));
        }
    }

    // fixme dies when categories are added to the base
    duplicate->data()->properties = original->data()->properties;
    duplicate->data()->protocols = original->data()->protocols;

    if (duplicate->superclass) {
        addSubclass(duplicate->superclass, duplicate);
    }

    // Don't methodize class - construction above is correct

    addNamedClass(duplicate, duplicate->data()->ro->name);
    addRealizedClass(duplicate);
    // no: duplicate->isa == original->isa
    // addRealizedMetaclass(duplicate->isa);

    if (PrintConnecting) {
        _objc_inform("CLASS: realizing class '%s' (duplicate of %s) %p %p", 
                     name, original->data()->ro->name, 
                     duplicate, duplicate->data()->ro);
    }

    rwlock_unlock_write(&runtimeLock);

    return (Class)duplicate;
}

/***********************************************************************
* objc_initializeClassPair
* Locking: runtimeLock must be write-locked by the caller
**********************************************************************/

// &UnsetLayout is the default ivar layout during class construction
static const uint8_t UnsetLayout = 0;

static void objc_initializeClassPair_internal(Class superclass_gen, const char *name, Class cls_gen, Class meta_gen)
{
    rwlock_assert_writing(&runtimeLock);

    class_t *superclass = newcls(superclass_gen);
    class_t *cls = newcls(cls_gen);
    class_t *meta = newcls(meta_gen);
    class_ro_t *cls_ro_w, *meta_ro_w;
    
    cls->setData((class_rw_t *)_calloc_internal(sizeof(class_rw_t), 1));
    meta->setData((class_rw_t *)_calloc_internal(sizeof(class_rw_t), 1));
    cls_ro_w   = (class_ro_t *)_calloc_internal(sizeof(class_ro_t), 1);
    meta_ro_w  = (class_ro_t *)_calloc_internal(sizeof(class_ro_t), 1);
    cls->data()->ro = cls_ro_w;
    meta->data()->ro = meta_ro_w;

    // Set basic info
    cls->cache = (Cache)&_objc_empty_cache;
    meta->cache = (Cache)&_objc_empty_cache;
    cls->vtable = &_objc_empty_vtable;
    meta->vtable = &_objc_empty_vtable;

    cls->data()->flags = RW_CONSTRUCTING | RW_COPIED_RO | RW_REALIZED;
    meta->data()->flags = RW_CONSTRUCTING | RW_COPIED_RO | RW_REALIZED;
    cls->data()->version = 0;
    meta->data()->version = 7;

    cls_ro_w->flags = 0;
    meta_ro_w->flags = RO_META;
    if (!superclass) {
        cls_ro_w->flags |= RO_ROOT;
        meta_ro_w->flags |= RO_ROOT;
    }
    if (superclass) {
        cls_ro_w->instanceStart = unalignedInstanceSize(superclass);
        meta_ro_w->instanceStart = unalignedInstanceSize(superclass->isa);
        cls_ro_w->instanceSize = cls_ro_w->instanceStart;
        meta_ro_w->instanceSize = meta_ro_w->instanceStart;
    } else {
        cls_ro_w->instanceStart = 0;
        meta_ro_w->instanceStart = (uint32_t)sizeof(class_t);
        cls_ro_w->instanceSize = (uint32_t)sizeof(id);  // just an isa
        meta_ro_w->instanceSize = meta_ro_w->instanceStart;
    }

    cls_ro_w->name = _strdup_internal(name);
    meta_ro_w->name = _strdup_internal(name);

    cls_ro_w->ivarLayout = &UnsetLayout;
    cls_ro_w->weakIvarLayout = &UnsetLayout;

    // Connect to superclasses and metaclasses
    cls->isa = meta;
    if (superclass) {
        meta->isa = superclass->isa->isa;
        cls->superclass = superclass;
        meta->superclass = superclass->isa;
        addSubclass(superclass, cls);
        addSubclass(superclass->isa, meta);
    } else {
        meta->isa = meta;
        cls->superclass = Nil;
        meta->superclass = cls;
        addSubclass(cls, meta);
    }
}

/***********************************************************************
* objc_initializeClassPair
**********************************************************************/
Class objc_initializeClassPair(Class superclass_gen, const char *name, Class cls_gen, Class meta_gen)
{
    class_t *superclass = newcls(superclass_gen);

    rwlock_write(&runtimeLock);
    
    //
    // Common superclass integrity checks with objc_allocateClassPair
    //
    if (getClass(name)) {
        rwlock_unlock_write(&runtimeLock);
        return Nil;
    }
    // fixme reserve class against simultaneous allocation

    if (superclass) assert(isRealized(superclass));

    if (superclass  &&  superclass->data()->flags & RW_CONSTRUCTING) {
        // Can't make subclass of an in-construction class
        rwlock_unlock_write(&runtimeLock);
        return Nil;
    }


    // just initialize what was supplied
    objc_initializeClassPair_internal(superclass_gen, name, cls_gen, meta_gen);

    rwlock_unlock_write(&runtimeLock);
    return cls_gen;
}

/***********************************************************************
* objc_allocateClassPair
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
Class objc_allocateClassPair(Class superclass_gen, const char *name, 
                             size_t extraBytes)
{
    class_t *superclass = newcls(superclass_gen);
    Class cls, meta;

    rwlock_write(&runtimeLock);

    //
    // Common superclass integrity checks with objc_initializeClassPair
    //
    if (getClass(name)) {
        rwlock_unlock_write(&runtimeLock);
        return Nil;
    }
    // fixme reserve class against simmultaneous allocation

    if (superclass) assert(isRealized(superclass));

    if (superclass  &&  superclass->data()->flags & RW_CONSTRUCTING) {
        // Can't make subclass of an in-construction class
        rwlock_unlock_write(&runtimeLock);
        return Nil;
    }



    // Allocate new classes.
    size_t size = sizeof(class_t);
    size_t metasize = sizeof(class_t);
    if (superclass) {
        size = alignedInstanceSize(superclass->isa);
        metasize = alignedInstanceSize(superclass->isa->isa);
    }
    cls  = _calloc_class(size + extraBytes);
    meta = _calloc_class(metasize + extraBytes);

    objc_initializeClassPair_internal(superclass_gen, name, cls, meta);

    rwlock_unlock_write(&runtimeLock);

    return (Class)cls;
}


/***********************************************************************
* objc_registerClassPair
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
void objc_registerClassPair(Class cls_gen)
{
    class_t *cls = newcls(cls_gen);
    
    rwlock_write(&runtimeLock);

    if ((cls->data()->flags & RW_CONSTRUCTED)  ||  
        (cls->isa->data()->flags & RW_CONSTRUCTED)) 
    {
        _objc_inform("objc_registerClassPair: class '%s' was already "
                     "registered!", cls->data()->ro->name);
        rwlock_unlock_write(&runtimeLock);
        return;
    }

    if (!(cls->data()->flags & RW_CONSTRUCTING)  ||  
        !(cls->isa->data()->flags & RW_CONSTRUCTING))
    {
        _objc_inform("objc_registerClassPair: class '%s' was not "
                     "allocated with objc_allocateClassPair!", 
                     cls->data()->ro->name);
        rwlock_unlock_write(&runtimeLock);
        return;
    }

    // Build ivar layouts
    if (UseGC) {
        class_t *supercls = getSuperclass(cls);
        class_ro_t *ro_w = (class_ro_t *)cls->data()->ro;

        if (ro_w->ivarLayout != &UnsetLayout) {
            // Class builder already called class_setIvarLayout.
        }
        else if (!supercls) {
            // Root class. Scan conservatively (should be isa ivar only).
            ro_w->ivarLayout = NULL;
        }
        else if (ro_w->ivars == NULL) {
            // No local ivars. Use superclass's layouts.
            ro_w->ivarLayout = 
                _ustrdup_internal(supercls->data()->ro->ivarLayout);
        }
        else {
            // Has local ivars. Build layouts based on superclass.
            layout_bitmap bitmap = 
                layout_bitmap_create(supercls->data()->ro->ivarLayout, 
                                     unalignedInstanceSize(supercls), 
                                     unalignedInstanceSize(cls), NO);
            uint32_t i;
            for (i = 0; i < ro_w->ivars->count; i++) {
                ivar_t *ivar = ivar_list_nth(ro_w->ivars, i);
                if (!ivar->offset) continue;  // anonymous bitfield

                layout_bitmap_set_ivar(bitmap, ivar->type, *ivar->offset);
            }
            ro_w->ivarLayout = layout_string_create(bitmap);
            layout_bitmap_free(bitmap);
        }

        if (ro_w->weakIvarLayout != &UnsetLayout) {
            // Class builder already called class_setWeakIvarLayout.
        }
        else if (!supercls) {
            // Root class. No weak ivars (should be isa ivar only).
            ro_w->weakIvarLayout = NULL;
        }
        else if (ro_w->ivars == NULL) {
            // No local ivars. Use superclass's layout.
            ro_w->weakIvarLayout = 
                _ustrdup_internal(supercls->data()->ro->weakIvarLayout);
        }
        else {
            // Has local ivars. Build layout based on superclass.
            // No way to add weak ivars yet.
            ro_w->weakIvarLayout = 
                _ustrdup_internal(supercls->data()->ro->weakIvarLayout);
        }
    }

    // Clear "under construction" bit, set "done constructing" bit
    cls->data()->flags &= ~RW_CONSTRUCTING;
    cls->isa->data()->flags &= ~RW_CONSTRUCTING;
    cls->data()->flags |= RW_CONSTRUCTED;
    cls->isa->data()->flags |= RW_CONSTRUCTED;

    // Add to named and realized classes
    addNamedClass(cls, cls->data()->ro->name);
    addRealizedClass(cls);
    addRealizedMetaclass(cls->isa);
    addNonMetaClass(cls);

    rwlock_unlock_write(&runtimeLock);
}


/***********************************************************************
* detach_class
* Disconnect a class from other data structures.
* Exception: does not remove the class from the +load list
* Call this before free_class.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void detach_class(class_t *cls, BOOL isMeta)
{
    rwlock_assert_writing(&runtimeLock);

    // categories not yet attached to this class
    category_list *cats;
    cats = unattachedCategoriesForClass(cls);
    if (cats) free(cats);

    // superclass's subclass list
    if (isRealized(cls)) {
        class_t *supercls = getSuperclass(cls);
        if (supercls) {
            removeSubclass(supercls, cls);
        }
    }

    // class tables and +load queue
    if (!isMeta) {
        removeNamedClass(cls, getName(cls));
        removeRealizedClass(cls);
        removeNonMetaClass(cls);
    } else {
        removeRealizedMetaclass(cls);
    }
}


/***********************************************************************
* free_class
* Frees a class's data structures.
* Call this after detach_class.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void free_class(class_t *cls)
{
    rwlock_assert_writing(&runtimeLock);

    if (! isRealized(cls)) return;

    uint32_t i;
    
    // Dereferences the cache contents; do this before freeing methods
    if (cls->cache != (Cache)&_objc_empty_cache) _cache_free(cls->cache);

    FOREACH_METHOD_LIST(mlist, cls, {
        for (i = 0; i < mlist->count; i++) {
            method_t *m = method_list_nth(mlist, i);
            try_free(m->types);
        }
        try_free(mlist);
    });
    if (cls->data()->flags & RW_METHOD_ARRAY) {
        try_free(cls->data()->method_lists);
    }
    
    const ivar_list_t *ilist = cls->data()->ro->ivars;
    if (ilist) {
        for (i = 0; i < ilist->count; i++) {
            const ivar_t *ivar = ivar_list_nth(ilist, i);
            try_free(ivar->offset);
            try_free(ivar->name);
            try_free(ivar->type);
        }
        try_free(ilist);
    }
    
    const protocol_list_t **plistp;
    for (plistp = cls->data()->protocols; plistp && *plistp; plistp++) {
        try_free(*plistp);
    }
    try_free(cls->data()->protocols);
    
    const chained_property_list *proplist = cls->data()->properties;
    while (proplist) {
        for (i = 0; i < proplist->count; i++) {
            const property_t *prop = proplist->list+i;
            try_free(prop->name);
            try_free(prop->attributes);
        }
        {
            const chained_property_list *temp = proplist;
            proplist = proplist->next;
            try_free(temp);
        }
    }
    
    if (cls->vtable != &_objc_empty_vtable  &&  
        cls->data()->flags & RW_SPECIALIZED_VTABLE) try_free(cls->vtable);
    try_free(cls->data()->ro->ivarLayout);
    try_free(cls->data()->ro->weakIvarLayout);
    try_free(cls->data()->ro->name);
    try_free(cls->data()->ro);
    try_free(cls->data());
    try_free(cls);
}


void objc_disposeClassPair(Class cls_gen)
{
    class_t *cls = newcls(cls_gen);

    rwlock_write(&runtimeLock);

    if (!(cls->data()->flags & (RW_CONSTRUCTED|RW_CONSTRUCTING))  ||  
        !(cls->isa->data()->flags & (RW_CONSTRUCTED|RW_CONSTRUCTING))) 
    {
        // class not allocated with objc_allocateClassPair
        // disposing still-unregistered class is OK!
        _objc_inform("objc_disposeClassPair: class '%s' was not "
                     "allocated with objc_allocateClassPair!", 
                     cls->data()->ro->name);
        rwlock_unlock_write(&runtimeLock);
        return;
    }

    if (isMetaClass(cls)) {
        _objc_inform("objc_disposeClassPair: class '%s' is a metaclass, "
                     "not a class!", cls->data()->ro->name);
        rwlock_unlock_write(&runtimeLock);
        return;
    }

    // Shouldn't have any live subclasses.
    if (cls->data()->firstSubclass) {
        _objc_inform("objc_disposeClassPair: class '%s' still has subclasses, "
                     "including '%s'!", cls->data()->ro->name, 
                     getName(cls->data()->firstSubclass));
    }
    if (cls->isa->data()->firstSubclass) {
        _objc_inform("objc_disposeClassPair: class '%s' still has subclasses, "
                     "including '%s'!", cls->data()->ro->name, 
                     getName(cls->isa->data()->firstSubclass));
    }

    // don't remove_class_from_loadable_list() 
    // - it's not there and we don't have the lock
    detach_class(cls->isa, YES);
    detach_class(cls, NO);
    free_class(cls->isa);
    free_class(cls);

    rwlock_unlock_write(&runtimeLock);
}


/***********************************************************************
* class_createInstance
* fixme
* Locking: none
**********************************************************************/
static id
_class_createInstanceFromZone(Class cls, size_t extraBytes, void *zone)
    __attribute__((always_inline));

static id
_class_createInstanceFromZone(Class cls, size_t extraBytes, void *zone)
{
    if (!cls) return nil;

    assert(isRealized(newcls(cls)));

    size_t size = alignedInstanceSize(newcls(cls)) + extraBytes;

    // CF requires all object be at least 16 bytes.
    if (size < 16) size = 16;

    id obj;
#if SUPPORT_GC
    if (UseGC) {
        obj = (id)auto_zone_allocate_object(gc_zone, size,
                                            AUTO_OBJECT_SCANNED, 0, 1);
    } else 
#endif
    if (zone) {
        obj = (id)malloc_zone_calloc ((malloc_zone_t *)zone, 1, size);
    } else {
        obj = (id)calloc(1, size);
    }
    if (!obj) return nil;

    obj->isa = cls;  // need not be object_setClass

    if (_class_hasCxxStructors(cls)) {
        obj = _objc_constructOrFree(cls, obj);
    }

    return obj;
}


id 
class_createInstance(Class cls, size_t extraBytes)
{
    return _class_createInstanceFromZone(cls, extraBytes, NULL);
}

/***********************************************************************
* class_createInstances
* fixme
* Locking: none
**********************************************************************/
unsigned 
class_createInstances(Class cls, size_t extraBytes, 
                      id *results, unsigned num_requested)
{
    return _class_createInstancesFromZone(cls, extraBytes, NULL, 
                                          results, num_requested);
}

static BOOL classOrSuperClassesUseARR(Class cls) {
    while (cls) {
        if (_class_usesAutomaticRetainRelease(cls)) return true;
        cls = class_getSuperclass(cls);
    }
    return false;
}

static void arr_fixup_copied_references(id newObject, id oldObject)
{
    // use ARR layouts to correctly copy the references from old object to new, both strong and weak.
    Class cls = oldObject->isa;
    while (cls) {
        if (_class_usesAutomaticRetainRelease(cls)) {
            // FIXME:  align the instance start to nearest id boundary. This currently handles the case where
            // the the compiler folds a leading BOOL (char, short, etc.) into the alignment slop of a superclass.
            size_t instanceStart = _class_getInstanceStart(cls);
            const uint8_t *strongLayout = class_getIvarLayout(cls);
            if (strongLayout) {
                id *newPtr = (id *)((char*)newObject + instanceStart);
                unsigned char byte;
                while ((byte = *strongLayout++)) {
                    unsigned skips = (byte >> 4);
                    unsigned scans = (byte & 0x0F);
                    newPtr += skips;
                    while (scans--) {
                        // ensure strong references are properly retained.
                        id value = *newPtr++;
                        if (value) objc_retain(value);
                    }
                }
            }
            const uint8_t *weakLayout = class_getWeakIvarLayout(cls);
            // fix up weak references if any.
            if (weakLayout) {
                id *newPtr = (id *)((char*)newObject + instanceStart), *oldPtr = (id *)((char*)oldObject + instanceStart);
                unsigned char byte;
                while ((byte = *weakLayout++)) {
                    unsigned skips = (byte >> 4);
                    unsigned weaks = (byte & 0x0F);
                    newPtr += skips, oldPtr += skips;
                    while (weaks--) {
                        *newPtr = nil;
                        objc_storeWeak(newPtr, objc_loadWeak(oldPtr));
                        ++newPtr, ++oldPtr;
                    }
                }
            }
        }
        cls = class_getSuperclass(cls);
    }
}

/***********************************************************************
* object_copyFromZone
* fixme
* Locking: none
**********************************************************************/
static id 
_object_copyFromZone(id oldObj, size_t extraBytes, void *zone)
{
    id obj;
    size_t size;

    if (!oldObj) return nil;
    if (OBJC_IS_TAGGED_PTR(oldObj)) return oldObj;

    size = _class_getInstanceSize(oldObj->isa) + extraBytes;
#if SUPPORT_GC
    if (UseGC) {
        obj = (id) auto_zone_allocate_object(gc_zone, size, 
                                             AUTO_OBJECT_SCANNED, 0, 1);
    } else
#endif
    if (zone) {
        obj = (id) malloc_zone_calloc((malloc_zone_t *)zone, size, 1);
    } else {
        obj = (id) calloc(1, size);
    }
    if (!obj) return nil;

    // fixme this doesn't handle C++ ivars correctly (#4619414)
    objc_memmove_collectable(obj, oldObj, size);

#if SUPPORT_GC
    if (UseGC)
        gc_fixup_weakreferences(obj, oldObj);
    else if (classOrSuperClassesUseARR(obj->isa))
        arr_fixup_copied_references(obj, oldObj);
#else
    if (classOrSuperClassesUseARR(obj->isa))
        arr_fixup_copied_references(obj, oldObj);
#endif

    return obj;
}


/***********************************************************************
* object_copy
* fixme
* Locking: none
**********************************************************************/
id 
object_copy(id oldObj, size_t extraBytes)
{
    return _object_copyFromZone(oldObj, extraBytes, malloc_default_zone());
}


#if !(TARGET_OS_EMBEDDED  ||  TARGET_OS_IPHONE)

/***********************************************************************
* class_createInstanceFromZone
* fixme
* Locking: none
**********************************************************************/
id
class_createInstanceFromZone(Class cls, size_t extraBytes, void *zone)
{
    return _class_createInstanceFromZone(cls, extraBytes, zone);
}

/***********************************************************************
* object_copyFromZone
* fixme
* Locking: none
**********************************************************************/
id 
object_copyFromZone(id oldObj, size_t extraBytes, void *zone)
{
    return _object_copyFromZone(oldObj, extraBytes, zone);
}

#endif


/***********************************************************************
* objc_destructInstance
* Destroys an instance without freeing memory. 
* Calls C++ destructors.
* Calls ARR ivar cleanup.
* Removes associative references.
* Returns `obj`. Does nothing if `obj` is nil.
* Be warned that GC DOES NOT CALL THIS. If you edit this, also edit finalize.
* CoreFoundation and other clients do call this under GC.
**********************************************************************/
void *objc_destructInstance(id obj) 
{
    if (obj) {
        Class isa_gen = _object_getClass(obj);
        class_t *isa = newcls(isa_gen);

        // Read all of the flags at once for performance.
        bool cxx = hasCxxStructors(isa);
        bool assoc = !UseGC && _class_instancesHaveAssociatedObjects(isa_gen);

        // This order is important.
        if (cxx) object_cxxDestruct(obj);
        if (assoc) _object_remove_assocations(obj);
        
        if (!UseGC) objc_clear_deallocating(obj);
    }

    return obj;
}


/***********************************************************************
* object_dispose
* fixme
* Locking: none
**********************************************************************/
id 
object_dispose(id obj)
{
    if (!obj) return nil;

    objc_destructInstance(obj);
    
#if SUPPORT_GC
    if (UseGC) {
        auto_zone_retain(gc_zone, obj); // gc free expects rc==1
    }
#endif

    free(obj);

    return nil;
}

// These variables are always provided for debuggers.
uintptr_t objc_debug_taggedpointer_mask = 0;
unsigned  objc_debug_taggedpointer_slot_shift = 0;
uintptr_t objc_debug_taggedpointer_slot_mask = 0;
unsigned  objc_debug_taggedpointer_payload_lshift = 0;
unsigned  objc_debug_taggedpointer_payload_rshift = 0;
Class objc_debug_taggedpointer_classes[1] = { nil };

static void
disableTaggedPointers() { }

void
_objc_registerTaggedPointerClass(objc_tag_index_t tag, Class cls)
{
}


/***********************************************************************
* _objc_getFreedObjectClass
* fixme
* Locking: none
**********************************************************************/
Class _objc_getFreedObjectClass (void)
{
    return nil;
}

#if SUPPORT_FIXUP

OBJC_EXTERN id objc_msgSend_fixedup(id, SEL, ...);
OBJC_EXTERN id objc_msgSendSuper2_fixedup(id, SEL, ...);
OBJC_EXTERN id objc_msgSend_stret_fixedup(id, SEL, ...);
OBJC_EXTERN id objc_msgSendSuper2_stret_fixedup(id, SEL, ...);
#if defined(__i386__)  ||  defined(__x86_64__)
OBJC_EXTERN id objc_msgSend_fpret_fixedup(id, SEL, ...);
#endif
#if defined(__x86_64__)
OBJC_EXTERN id objc_msgSend_fp2ret_fixedup(id, SEL, ...);
#endif

/***********************************************************************
* _objc_fixupMessageRef
* Fixes up message ref *msg. 
* obj is the receiver. supr is NULL for non-super messages
* Locking: acquires runtimeLock
**********************************************************************/
OBJC_EXTERN IMP 
_objc_fixupMessageRef(id obj, struct objc_super2 *supr, message_ref_t *msg)
{
    IMP imp;
    class_t *isa;
#if SUPPORT_VTABLE
    int vtableIndex;
#endif

    rwlock_assert_unlocked(&runtimeLock);

    if (!supr) {
        // normal message - search obj->isa for the method implementation
        isa = (class_t *) _object_getClass(obj);
        
        if (!isRealized(isa)) {
            // obj is a class object, isa is its metaclass
            class_t *cls;
            rwlock_write(&runtimeLock);
            cls = realizeClass((class_t *)obj);
            rwlock_unlock_write(&runtimeLock);
                
            // shouldn't have instances of unrealized classes!
            assert(isMetaClass(isa));
            // shouldn't be relocating classes here!
            assert(cls == (class_t *)obj);
        }
    }
    else {
        // this is objc_msgSend_super, and supr->current_class->superclass
        // is the class to search for the method implementation
        assert(isRealized((class_t *)supr->current_class));
        isa = getSuperclass((class_t *)supr->current_class);
    }

    msg->sel = sel_registerName((const char *)msg->sel);

    if (ignoreSelector(msg->sel)) {
        // ignored selector - bypass dispatcher
        msg->imp = (IMP)&vtable_ignored;
        imp = (IMP)&_objc_ignored_method;
    }
#if SUPPORT_VTABLE
    else if (msg->imp == (IMP)&objc_msgSend_fixup  &&  
        (vtableIndex = vtable_getIndex(msg->sel)) >= 0) 
    {
        // vtable dispatch
        msg->imp = vtableTrampolines[vtableIndex];
        imp = isa->vtable[vtableIndex];
    }
#endif
    else {
        // ordinary dispatch
        imp = lookUpMethod((Class)isa, msg->sel, YES/*initialize*/, YES/*cache*/, obj);
        
        if (msg->imp == (IMP)&objc_msgSend_fixup) { 
            msg->imp = (IMP)&objc_msgSend_fixedup;
        } 
        else if (msg->imp == (IMP)&objc_msgSendSuper2_fixup) { 
            msg->imp = (IMP)&objc_msgSendSuper2_fixedup;
        } 
        else if (msg->imp == (IMP)&objc_msgSend_stret_fixup) { 
            msg->imp = (IMP)&objc_msgSend_stret_fixedup;
        } 
        else if (msg->imp == (IMP)&objc_msgSendSuper2_stret_fixup) { 
            msg->imp = (IMP)&objc_msgSendSuper2_stret_fixedup;
        } 
#if defined(__i386__)  ||  defined(__x86_64__)
        else if (msg->imp == (IMP)&objc_msgSend_fpret_fixup) { 
            msg->imp = (IMP)&objc_msgSend_fpret_fixedup;
        } 
#endif
#if defined(__x86_64__)
        else if (msg->imp == (IMP)&objc_msgSend_fp2ret_fixup) { 
            msg->imp = (IMP)&objc_msgSend_fp2ret_fixedup;
        } 
#endif
        else {
            // The ref may already have been fixed up, either by another thread
            // or by +initialize via lookUpMethod above.
        }
    }

    return imp;
}

// SUPPORT_FIXUP
#endif


// ProKit SPI
static class_t *setSuperclass(class_t *cls, class_t *newSuper)
{
    class_t *oldSuper;

    rwlock_assert_writing(&runtimeLock);

    assert(isRealized(cls));
    assert(isRealized(newSuper));

    oldSuper = cls->superclass;
    removeSubclass(oldSuper, cls);
    removeSubclass(oldSuper->isa, cls->isa);

    cls->superclass = newSuper;
    cls->isa->superclass = newSuper->isa;
    addSubclass(newSuper, cls);
    addSubclass(newSuper->isa, cls->isa);

    flushCaches(cls->isa);
    flushVtables(cls->isa);
    flushCaches(cls);
    flushVtables(cls);
    
    return oldSuper;
}


Class class_setSuperclass(Class cls_gen, Class newSuper_gen)
{
    class_t *cls = newcls(cls_gen);
    class_t *newSuper = newcls(newSuper_gen);
    class_t *oldSuper;

    rwlock_write(&runtimeLock);
    oldSuper = setSuperclass(cls, newSuper);
    rwlock_unlock_write(&runtimeLock);

    return (Class)oldSuper;
}

#endif
