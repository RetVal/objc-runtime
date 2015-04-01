/*
 * Copyright (c) 1999-2007 Apple Inc.  All Rights Reserved.
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
/*
 *	objc-private.h
 *	Copyright 1988-1996, NeXT Software, Inc.
 */

#ifndef _OBJC_PRIVATE_H_
#define _OBJC_PRIVATE_H_

#include "objc-os.h"

#include "objc.h"
#include "runtime.h"
#include "maptable.h"
#include "hashtable2.h"
#include "objc-api.h"
#include "objc-config.h"
#include "objc-references.h"
#include "objc-initialize.h"
#include "objc-loadmethod.h"
#include "objc-internal.h"
#include "objc-abi.h"

#include "objc-auto.h"

#define __APPLE_API_PRIVATE
#include "objc-gdb.h"
#undef __APPLE_API_PRIVATE

/* Do not include message.h here. */
/* #include "message.h" */


__BEGIN_DECLS

#ifdef __LP64__
#   define WORD_SHIFT 3UL
#   define WORD_MASK 7UL
#else
#   define WORD_SHIFT 2UL
#   define WORD_MASK 3UL
#endif

#if (defined(OBJC_NO_GC) && SUPPORT_GC)  ||  \
    (!defined(OBJC_NO_GC) && !SUPPORT_GC)
#   error OBJC_NO_GC and SUPPORT_GC inconsistent
#endif

#if SUPPORT_GC
#   include <auto_zone.h>
	// PRIVATE_EXTERN is needed to help the compiler know "how" extern these are
    PRIVATE_EXTERN extern BOOL UseGC;            // equivalent to calling objc_collecting_enabled()
    PRIVATE_EXTERN extern BOOL UseCompaction;    // if binary has opted-in for compaction.
    PRIVATE_EXTERN extern auto_zone_t *gc_zone;  // the GC zone, or NULL if no GC
    extern void objc_addRegisteredClass(Class c);
    extern void objc_removeRegisteredClass(Class c);
    extern void objc_disableCompaction();
#else
#   define UseGC NO
#   define UseCompaction NO
#   define gc_zone NULL
#   define objc_addRegisteredClass(c) do {} while(0)
#   define objc_removeRegisteredClass(c) do {} while(0)
    /* Uses of the following must be protected with UseGC. */
    extern id gc_unsupported_dont_call();
#   define auto_zone_allocate_object gc_unsupported_dont_call
#   define auto_zone_retain gc_unsupported_dont_call
#   define auto_zone_release gc_unsupported_dont_call
#   define auto_zone_is_valid_pointer gc_unsupported_dont_call
#   define auto_zone_write_barrier_memmove gc_unsupported_dont_call
#   define AUTO_OBJECT_SCANNED 0
#endif

#if __OBJC2__
typedef struct objc_cache *Cache;
#else 
// definition in runtime.h
#endif


typedef struct {
    uint32_t version; // currently 0
    uint32_t flags;
} objc_image_info;

// masks for objc_image_info.flags
#define OBJC_IMAGE_IS_REPLACEMENT (1<<0)
#define OBJC_IMAGE_SUPPORTS_GC (1<<1)
#define OBJC_IMAGE_REQUIRES_GC (1<<2)
#define OBJC_IMAGE_OPTIMIZED_BY_DYLD (1<<3)
#define OBJC_IMAGE_SUPPORTS_COMPACTION (1<<4)


#define _objcHeaderIsReplacement(h)  ((h)->info  &&  ((h)->info->flags & OBJC_IMAGE_IS_REPLACEMENT))

/* OBJC_IMAGE_IS_REPLACEMENT:
   Don't load any classes
   Don't load any categories
   Do fix up selector refs (@selector points to them)
   Do fix up class refs (@class and objc_msgSend points to them)
   Do fix up protocols (@protocol points to them)
   Do fix up super_class pointers in classes ([super ...] points to them)
   Future: do load new classes?
   Future: do load new categories?
   Future: do insert new methods on existing classes?
   Future: do insert new methods on existing categories?
*/

#define _objcInfoSupportsGC(info) (((info)->flags & OBJC_IMAGE_SUPPORTS_GC) ? 1 : 0)
#define _objcInfoRequiresGC(info) (((info)->flags & OBJC_IMAGE_REQUIRES_GC) ? 1 : 0)
#define _objcInfoSupportsCompaction(info) (((info)->flags & OBJC_IMAGE_SUPPORTS_COMPACTION) ? 1 : 0)
#define _objcHeaderSupportsGC(h) ((h)->info && _objcInfoSupportsGC((h)->info))
#define _objcHeaderRequiresGC(h) ((h)->info && _objcInfoRequiresGC((h)->info))
#define _objcHeaderSupportsCompaction(h) ((h)->info && _objcInfoSupportsCompaction((h)->info))

/* OBJC_IMAGE_SUPPORTS_GC:
    was compiled with -fobjc-gc flag, regardless of whether write-barriers were issued
    if executable image compiled this way, then all subsequent libraries etc. must also be this way
*/

#define _objcHeaderOptimizedByDyld(h)  ((h)->info  &&  ((h)->info->flags & OBJC_IMAGE_OPTIMIZED_BY_DYLD))

/* OBJC_IMAGE_OPTIMIZED_BY_DYLD:
   Assorted metadata precooked in the dyld shared cache.
   Never set for images outside the shared cache file itself.
*/
   

typedef struct _header_info {
    struct _header_info *next;
    const headerType *mhdr;
    const objc_image_info *info;
    const char *fname;  // same as Dl_info.dli_fname
    bool loaded;
    bool inSharedCache;
    bool allClassesRealized;

    // Do not add fields without editing ObjCModernAbstraction.hpp

#if !__OBJC2__
    struct old_protocol **proto_refs;
    struct objc_module *mod_ptr;
    size_t              mod_count;
# if TARGET_OS_WIN32
    struct objc_module **modules;
    size_t moduleCount;
    struct old_protocol **protocols;
    size_t protocolCount;
    void *imageinfo;
    size_t imageinfoBytes;
    SEL *selrefs;
    size_t selrefCount;
    struct objc_class **clsrefs;
    size_t clsrefCount;    
    TCHAR *moduleName;
# endif
#endif
} header_info;

extern header_info *FirstHeader;
extern header_info *LastHeader;
extern int HeaderCount;

extern void appendHeader(header_info *hi);
extern void removeHeader(header_info *hi);

extern objc_image_info *_getObjcImageInfo(const headerType *head, size_t *size);
extern BOOL _hasObjcContents(const header_info *hi);


/* selectors */
extern void sel_init(BOOL gc, size_t selrefCount);
extern SEL sel_registerNameNoLock(const char *str, BOOL copy);
extern void sel_lock(void);
extern void sel_unlock(void);
extern BOOL sel_preoptimizationValid(const header_info *hi);

extern SEL SEL_load;
extern SEL SEL_initialize;
extern SEL SEL_resolveClassMethod;
extern SEL SEL_resolveInstanceMethod;
extern SEL SEL_cxx_construct;
extern SEL SEL_cxx_destruct;
extern SEL SEL_retain;
extern SEL SEL_release;
extern SEL SEL_autorelease;
extern SEL SEL_retainCount;
extern SEL SEL_alloc;
extern SEL SEL_allocWithZone;
extern SEL SEL_copy;
extern SEL SEL_new;
extern SEL SEL_finalize;
extern SEL SEL_forwardInvocation;

/* preoptimization */
extern void preopt_init(void);
extern void disableSharedCacheOptimizations(void);
extern bool isPreoptimized(void);
extern header_info *preoptimizedHinfoForHeader(const headerType *mhdr);

#if __cplusplus
namespace objc_opt { struct objc_selopt_t; };
extern const struct objc_opt::objc_selopt_t *preoptimizedSelectors(void);
extern struct class_t * getPreoptimizedClass(const char *name);
#endif



/* optional malloc zone for runtime data */
extern malloc_zone_t *_objc_internal_zone(void);
extern void *_malloc_internal(size_t size);
extern void *_calloc_internal(size_t count, size_t size);
extern void *_realloc_internal(void *ptr, size_t size);
extern char *_strdup_internal(const char *str);
extern char *_strdupcat_internal(const char *s1, const char *s2);
extern uint8_t *_ustrdup_internal(const uint8_t *str);
extern void *_memdup_internal(const void *mem, size_t size);
extern void _free_internal(void *ptr);
extern size_t _malloc_size_internal(void *ptr);

extern Class _calloc_class(size_t size);

extern IMP lookUpMethod(Class, SEL, BOOL initialize, BOOL cache, id obj);
extern void lockForMethodLookup(void);
extern void unlockForMethodLookup(void);
extern IMP prepareForMethodLookup(Class cls, SEL sel, BOOL initialize, id obj);

extern IMP _cache_getImp(Class cls, SEL sel);
extern Method _cache_getMethod(Class cls, SEL sel, IMP objc_msgForward_internal_imp);

/* message dispatcher */
extern IMP _class_lookupMethodAndLoadCache3(id, SEL, Class);

#if !OBJC_OLD_DISPATCH_PROTOTYPES
extern void _objc_msgForward_internal(void);
extern void _objc_ignored_method(void);
#else
extern id _objc_msgForward_internal(id, SEL, ...);
extern id _objc_ignored_method(id, SEL, ...);
#endif

/* errors */
extern void __objc_error(id, const char *, ...) __attribute__((format (printf, 2, 3), noreturn));
extern void _objc_inform(const char *fmt, ...) __attribute__((format (printf, 1, 2)));
extern void _objc_inform_on_crash(const char *fmt, ...) __attribute__((format (printf, 1, 2)));
extern void _objc_inform_now_and_on_crash(const char *fmt, ...) __attribute__((format (printf, 1, 2)));
extern void _objc_inform_deprecated(const char *oldname, const char *newname) __attribute__((noinline));
extern void inform_duplicate(const char *name, Class oldCls, Class cls);
extern bool crashlog_header_name(header_info *hi);
extern bool crashlog_header_name_string(const char *name);

/* magic */
extern Class _objc_getFreedObjectClass (void);

/* map table additions */
extern void *NXMapKeyCopyingInsert(NXMapTable *table, const void *key, const void *value);
extern void *NXMapKeyFreeingRemove(NXMapTable *table, const void *key);

/* hash table additions */
extern unsigned _NXHashCapacity(NXHashTable *table);
extern void _NXHashRehashToCapacity(NXHashTable *table, unsigned newCapacity);

/* property attribute parsing */
extern const char *copyPropertyAttributeString(const objc_property_attribute_t *attrs, unsigned int count);
extern objc_property_attribute_t *copyPropertyAttributeList(const char *attrs, unsigned int *outCount);
extern char *copyPropertyAttributeValue(const char *attrs, const char *name);


/* locking */
/* Every lock used anywhere must be declared here. 
 * Locks not declared here may cause gdb deadlocks. */
extern void lock_init(void);
extern rwlock_t selLock;
extern mutex_t cacheUpdateLock;
extern recursive_mutex_t loadMethodLock;
#if __OBJC2__
extern rwlock_t runtimeLock;
#else
extern mutex_t classLock;
extern mutex_t methodListLock;
#endif

/* Debugger mode for gdb */
#define DEBUGGER_OFF 0
#define DEBUGGER_PARTIAL 1
#define DEBUGGER_FULL 2
extern int startDebuggerMode(void);
extern void endDebuggerMode(void);

#if defined(NDEBUG)  ||  TARGET_OS_WIN32

#define mutex_lock(m)             _mutex_lock_nodebug(m)
#define mutex_try_lock(m)         _mutex_try_lock_nodebug(m)
#define mutex_unlock(m)           _mutex_unlock_nodebug(m)
#define mutex_assert_locked(m)    do { } while (0)
#define mutex_assert_unlocked(m)  do { } while (0)

#define recursive_mutex_lock(m)             _recursive_mutex_lock_nodebug(m)
#define recursive_mutex_try_lock(m)         _recursive_mutex_try_lock_nodebug(m)
#define recursive_mutex_unlock(m)           _recursive_mutex_unlock_nodebug(m)
#define recursive_mutex_assert_locked(m)    do { } while (0)
#define recursive_mutex_assert_unlocked(m)  do { } while (0)

#define monitor_enter(m)            _monitor_enter_nodebug(m)
#define monitor_exit(m)             _monitor_exit_nodebug(m)
#define monitor_wait(m)             _monitor_wait_nodebug(m)
#define monitor_assert_locked(m)    do { } while (0)
#define monitor_assert_unlocked(m)  do { } while (0)

#define rwlock_read(m)              _rwlock_read_nodebug(m)
#define rwlock_write(m)             _rwlock_write_nodebug(m)
#define rwlock_try_read(m)          _rwlock_try_read_nodebug(m)
#define rwlock_try_write(m)         _rwlock_try_write_nodebug(m)
#define rwlock_unlock_read(m)       _rwlock_unlock_read_nodebug(m)
#define rwlock_unlock_write(m)      _rwlock_unlock_write_nodebug(m)
#define rwlock_assert_reading(m)    do { } while (0)
#define rwlock_assert_writing(m)    do { } while (0)
#define rwlock_assert_locked(m)     do { } while (0)
#define rwlock_assert_unlocked(m)   do { } while (0)

#else

extern int _mutex_lock_debug(mutex_t *lock, const char *name);
extern int _mutex_try_lock_debug(mutex_t *lock, const char *name);
extern int _mutex_unlock_debug(mutex_t *lock, const char *name);
extern void _mutex_assert_locked_debug(mutex_t *lock, const char *name);
extern void _mutex_assert_unlocked_debug(mutex_t *lock, const char *name);

extern int _recursive_mutex_lock_debug(recursive_mutex_t *lock, const char *name);
extern int _recursive_mutex_try_lock_debug(recursive_mutex_t *lock, const char *name);
extern int _recursive_mutex_unlock_debug(recursive_mutex_t *lock, const char *name);
extern void _recursive_mutex_assert_locked_debug(recursive_mutex_t *lock, const char *name);
extern void _recursive_mutex_assert_unlocked_debug(recursive_mutex_t *lock, const char *name);

extern int _monitor_enter_debug(monitor_t *lock, const char *name);
extern int _monitor_exit_debug(monitor_t *lock, const char *name);
extern int _monitor_wait_debug(monitor_t *lock, const char *name);
extern void _monitor_assert_locked_debug(monitor_t *lock, const char *name);
extern void _monitor_assert_unlocked_debug(monitor_t *lock, const char *name);

extern void _rwlock_read_debug(rwlock_t *l, const char *name);
extern void _rwlock_write_debug(rwlock_t *l, const char *name);
extern int  _rwlock_try_read_debug(rwlock_t *l, const char *name);
extern int  _rwlock_try_write_debug(rwlock_t *l, const char *name);
extern void _rwlock_unlock_read_debug(rwlock_t *l, const char *name);
extern void _rwlock_unlock_write_debug(rwlock_t *l, const char *name);
extern void _rwlock_assert_reading_debug(rwlock_t *l, const char *name);
extern void _rwlock_assert_writing_debug(rwlock_t *l, const char *name);
extern void _rwlock_assert_locked_debug(rwlock_t *l, const char *name);
extern void _rwlock_assert_unlocked_debug(rwlock_t *l, const char *name);

#define mutex_lock(m)             _mutex_lock_debug (m, #m)
#define mutex_try_lock(m)         _mutex_try_lock_debug (m, #m)
#define mutex_unlock(m)           _mutex_unlock_debug (m, #m)
#define mutex_assert_locked(m)    _mutex_assert_locked_debug (m, #m)
#define mutex_assert_unlocked(m)  _mutex_assert_unlocked_debug (m, #m)

#define recursive_mutex_lock(m)             _recursive_mutex_lock_debug (m, #m)
#define recursive_mutex_try_lock(m)         _recursive_mutex_try_lock_debug (m, #m)
#define recursive_mutex_unlock(m)           _recursive_mutex_unlock_debug (m, #m)
#define recursive_mutex_assert_locked(m)    _recursive_mutex_assert_locked_debug (m, #m)
#define recursive_mutex_assert_unlocked(m)  _recursive_mutex_assert_unlocked_debug (m, #m)

#define monitor_enter(m)            _monitor_enter_debug(m, #m)
#define monitor_exit(m)             _monitor_exit_debug(m, #m)
#define monitor_wait(m)             _monitor_wait_debug(m, #m)
#define monitor_assert_locked(m)    _monitor_assert_locked_debug(m, #m)
#define monitor_assert_unlocked(m)  _monitor_assert_unlocked_debug(m, #m)

#define rwlock_read(m)              _rwlock_read_debug(m, #m)
#define rwlock_write(m)             _rwlock_write_debug(m, #m)
#define rwlock_try_read(m)          _rwlock_try_read_debug(m, #m)
#define rwlock_try_write(m)         _rwlock_try_write_debug(m, #m)
#define rwlock_unlock_read(m)       _rwlock_unlock_read_debug(m, #m)
#define rwlock_unlock_write(m)      _rwlock_unlock_write_debug(m, #m)
#define rwlock_assert_reading(m)    _rwlock_assert_reading_debug(m, #m)
#define rwlock_assert_writing(m)    _rwlock_assert_writing_debug(m, #m)
#define rwlock_assert_locked(m)     _rwlock_assert_locked_debug(m, #m)
#define rwlock_assert_unlocked(m)   _rwlock_assert_unlocked_debug(m, #m)

#endif

extern bool noSideTableLocksHeld(void);

#define rwlock_unlock(m, s)                           \
    do {                                              \
        if ((s) == RDONLY) rwlock_unlock_read(m);     \
        else if ((s) == RDWR) rwlock_unlock_write(m); \
    } while (0)


extern NXHashTable *class_hash;

#if !TARGET_OS_WIN32
/* nil handler object */
extern id _objc_nilReceiver;
extern id _objc_setNilReceiver(id newNilReceiver);
extern id _objc_getNilReceiver(void);
#endif

/* forward handler functions */
extern void *_objc_forward_handler;
extern void *_objc_forward_stret_handler;

/* tagged pointer support */
#if SUPPORT_TAGGED_POINTERS

#define OBJC_IS_TAGGED_PTR(PTR)		((uintptr_t)(PTR) & 0x1)
extern Class _objc_tagged_isa_table[16];

#else

#define OBJC_IS_TAGGED_PTR(PTR)		0

#endif


/* ignored selector support */

/* Non-GC: no ignored selectors
   GC without fixup dispatch: some selectors ignored, remapped to kIgnore
   GC with fixup dispatch: some selectors ignored, but not remapped 
*/

static inline int ignoreSelector(SEL sel)
{
#if !SUPPORT_GC
    return NO;
#elif SUPPORT_IGNORED_SELECTOR_CONSTANT
    return UseGC  &&  sel == (SEL)kIgnore;
#else
    return UseGC  &&  
        (sel == @selector(retain)       ||  
         sel == @selector(release)      ||  
         sel == @selector(autorelease)  ||  
         sel == @selector(retainCount)  ||  
         sel == @selector(dealloc));
#endif
}

static inline int ignoreSelectorNamed(const char *sel)
{
#if !SUPPORT_GC
    return NO;
#else
    // release retain retainCount dealloc autorelease
    return (UseGC &&
            (  (sel[0] == 'r' && sel[1] == 'e' &&
                (strcmp(&sel[2], "lease") == 0 || 
                 strcmp(&sel[2], "tain") == 0 ||
                 strcmp(&sel[2], "tainCount") == 0 ))
               ||
               (strcmp(sel, "dealloc") == 0)
               || 
               (sel[0] == 'a' && sel[1] == 'u' && 
                strcmp(&sel[2], "torelease") == 0)));
#endif
}

/* Protocol implementation */
#if !__OBJC2__
struct old_protocol;
struct objc_method_description * lookup_protocol_method(struct old_protocol *proto, SEL aSel, BOOL isRequiredMethod, BOOL isInstanceMethod, BOOL recursive);
#else
Method _protocol_getMethod(Protocol *p, SEL sel, BOOL isRequiredMethod, BOOL isInstanceMethod, BOOL recursive);
#endif

/* GC startup */
extern void gc_init(BOOL wantsGC, BOOL wantsCompaction);
extern void gc_init2(void);

/* Exceptions */
struct alt_handler_list;
extern void exception_init(void);
extern void _destroyAltHandlerList(struct alt_handler_list *list);

/* Class change notifications (gdb only for now) */
#define OBJC_CLASS_ADDED (1<<0)
#define OBJC_CLASS_REMOVED (1<<1)
#define OBJC_CLASS_IVARS_CHANGED (1<<2)
#define OBJC_CLASS_METHODS_CHANGED (1<<3)
extern void gdb_objc_class_changed(Class cls, unsigned long changes, const char *classname)
    __attribute__((noinline));

/* Write barrier implementations */
extern id objc_assign_strongCast_non_gc(id value, id *dest);
extern id objc_assign_global_non_gc(id value, id *dest);
extern id objc_assign_threadlocal_non_gc(id value, id *dest);
extern id objc_assign_ivar_non_gc(id value, id dest, ptrdiff_t offset);
extern id objc_assign_strongCast_gc(id val, id *dest);
extern id objc_assign_global_gc(id val, id *dest);
extern id objc_assign_threadlocal_gc(id val, id *dest);
extern id objc_assign_ivar_gc(id value, id dest, ptrdiff_t offset);

extern id objc_getAssociatedObject_non_gc(id object, const void *key);
extern void objc_setAssociatedObject_non_gc(id object, const void *key, id value, objc_AssociationPolicy policy);
extern id objc_getAssociatedObject_gc(id object, const void *key);
extern void objc_setAssociatedObject_gc(id object, const void *key, id value, objc_AssociationPolicy policy);

#if SUPPORT_GC

/* GC weak reference fixup. */
extern void gc_fixup_weakreferences(id newObject, id oldObject);

/* GC datasegment registration. */
extern void gc_register_datasegment(uintptr_t base, size_t size);
extern void gc_unregister_datasegment(uintptr_t base, size_t size);
extern void gc_fixup_barrier_stubs(const struct dyld_image_info *info);

/* objc_dumpHeap implementation */
extern BOOL _objc_dumpHeap(auto_zone_t *zone, const char *filename);

/*
    objc_assign_ivar, objc_assign_global, objc_assign_threadlocal, and objc_assign_strongCast MUST NOT be called directly
    from inside libobjc. They live in the data segment, and must be called through the
    following pointer(s) for libobjc to exist in the shared cache.

    Note: If we build with GC enabled, gcc will emit calls to the original functions, which will break this.
*/

extern id (*objc_assign_ivar_internal)(id, id, ptrdiff_t);

#endif

/* Code modification */
extern size_t objc_branch_size(void *entry, void *target);
extern size_t objc_write_branch(void *entry, void *target);
extern size_t objc_cond_branch_size(void *entry, void *target, unsigned cond);
extern size_t objc_write_cond_branch(void *entry, void *target, unsigned cond);
#if defined(__i386__) || defined(__x86_64__)
#define COND_ALWAYS 0xE9  /* JMP rel32 */
#define COND_NE     0x85  /* JNE rel32  (0F 85) */
#endif


// Settings from environment variables
#if !SUPPORT_ENVIRON
#   define ENV(x) enum { x = 0 }
#else
#   define ENV(x) extern int x
#endif
ENV(PrintImages);               // env OBJC_PRINT_IMAGES
ENV(PrintLoading);              // env OBJC_PRINT_LOAD_METHODS
ENV(PrintInitializing);         // env OBJC_PRINT_INITIALIZE_METHODS
ENV(PrintResolving);            // env OBJC_PRINT_RESOLVED_METHODS
ENV(PrintConnecting);           // env OBJC_PRINT_CLASS_SETUP
ENV(PrintProtocols);            // env OBJC_PRINT_PROTOCOL_SETUP
ENV(PrintIvars);                // env OBJC_PRINT_IVAR_SETUP
ENV(PrintVtables);              // env OBJC_PRINT_VTABLE_SETUP
ENV(PrintVtableImages);         // env OBJC_PRINT_VTABLE_IMAGES
ENV(PrintFuture);               // env OBJC_PRINT_FUTURE_CLASSES
ENV(PrintGC);                   // env OBJC_PRINT_GC
ENV(PrintPreopt);               // env OBJC_PRINT_PREOPTIMIZATION
ENV(PrintCxxCtors);             // env OBJC_PRINT_CXX_CTORS
ENV(PrintExceptions);           // env OBJC_PRINT_EXCEPTIONS
ENV(PrintExceptionThrow);       // env OBJC_PRINT_EXCEPTION_THROW
ENV(PrintAltHandlers);          // env OBJC_PRINT_ALT_HANDLERS
ENV(PrintDeprecation);          // env OBJC_PRINT_DEPRECATION_WARNINGS
ENV(PrintReplacedMethods);      // env OBJC_PRINT_REPLACED_METHODS
ENV(PrintCaches);               // env OBJC_PRINT_CACHE_SETUP
ENV(PrintPoolHiwat);            // env OBJC_PRINT_POOL_HIGHWATER
ENV(PrintCustomRR);             // env OBJC_PRINT_CUSTOM_RR
ENV(PrintCustomAWZ);            // env OBJC_PRINT_CUSTOM_AWZ
ENV(UseInternalZone);           // env OBJC_USE_INTERNAL_ZONE

ENV(DebugUnload);               // env OBJC_DEBUG_UNLOAD
ENV(DebugFragileSuperclasses);  // env OBJC_DEBUG_FRAGILE_SUPERCLASSES
ENV(DebugFinalizers);           // env OBJC_DEBUG_FINALIZERS
ENV(DebugNilSync);              // env OBJC_DEBUG_NIL_SYNC
ENV(DebugNonFragileIvars);      // env OBJC_DEBUG_NONFRAGILE_IVARS
ENV(DebugAltHandlers);          // env OBJC_DEBUG_ALT_HANDLERS

ENV(DisableGC);                 // env OBJC_DISABLE_GC
ENV(DisableVtables);            // env OBJC_DISABLE_VTABLES
ENV(DisablePreopt);             // env OBJC_DISABLE_PREOPTIMIZATION

#undef ENV

extern void environ_init(void);

extern void logReplacedMethod(const char *className, SEL s, BOOL isMeta, const char *catName, IMP oldImp, IMP newImp);

static __inline uint32_t _objc_strhash(const char *s) {
    uint32_t hash = 0;
    for (;;) {
	int a = *s++;
	if (0 == a) break;
	hash += (hash << 8) + a;
    }
    return hash;
}


// objc per-thread storage
typedef struct {
    struct _objc_initializing_classes *initializingClasses; // for +initialize
    struct SyncCache *syncCache;  // for @synchronize
    struct alt_handler_list *handlerList;  // for exception alt handlers

    // If you add new fields here, don't forget to update 
    // _objc_pthread_destroyspecific()

} _objc_pthread_data;

extern _objc_pthread_data *_objc_fetch_pthread_data(BOOL create);
extern void tls_init(void);


// cache.h
#if TARGET_OS_WIN32

#else
static inline int isPowerOf2(unsigned long l) { return 1 == __builtin_popcountl(l); }
#endif
extern void flush_caches(Class cls, BOOL flush_meta);
extern void flush_cache(Class cls);
extern BOOL _cache_fill(Class cls, Method smt, SEL sel);
extern void _cache_addForwardEntry(Class cls, SEL sel);
extern IMP  _cache_addIgnoredEntry(Class cls, SEL sel);
extern void _cache_free(Cache cache);
extern void _cache_collect(bool collectALot);

extern mutex_t cacheUpdateLock;

// encoding.h
extern unsigned int encoding_getNumberOfArguments(const char *typedesc);
extern unsigned int encoding_getSizeOfArguments(const char *typedesc);
extern unsigned int encoding_getArgumentInfo(const char *typedesc, unsigned int arg, const char **type, int *offset);
extern void encoding_getReturnType(const char *t, char *dst, size_t dst_len);
extern char * encoding_copyReturnType(const char *t);
extern void encoding_getArgumentType(const char *t, unsigned int index, char *dst, size_t dst_len);
extern char *encoding_copyArgumentType(const char *t, unsigned int index);

// sync.h
extern void _destroySyncCache(struct SyncCache *cache);

// arr
extern void (^objc_arr_log)(const char *, id param);
extern void arr_init(void);
extern id objc_autoreleaseReturnValue(id obj);


// layout.h
typedef struct {
    uint8_t *bits;
    size_t bitCount;
    size_t bitsAllocated;
    BOOL weak;
} layout_bitmap;
extern layout_bitmap layout_bitmap_create(const unsigned char *layout_string, size_t layoutStringInstanceSize, size_t instanceSize, BOOL weak);
extern layout_bitmap layout_bitmap_create_empty(size_t instanceSize, BOOL weak);
extern void layout_bitmap_free(layout_bitmap bits);
extern const unsigned char *layout_string_create(layout_bitmap bits);
extern void layout_bitmap_set_ivar(layout_bitmap bits, const char *type, size_t offset);
extern void layout_bitmap_grow(layout_bitmap *bits, size_t newCount);
extern void layout_bitmap_slide(layout_bitmap *bits, size_t oldPos, size_t newPos);
extern void layout_bitmap_slide_anywhere(layout_bitmap *bits, size_t oldPos, size_t newPos);
extern BOOL layout_bitmap_splat(layout_bitmap dst, layout_bitmap src, 
                                size_t oldSrcInstanceSize);
extern BOOL layout_bitmap_or(layout_bitmap dst, layout_bitmap src, const char *msg);
extern BOOL layout_bitmap_clear(layout_bitmap dst, layout_bitmap src, const char *msg);
extern void layout_bitmap_print(layout_bitmap bits);


// fixme runtime
extern id look_up_class(const char *aClassName, BOOL includeUnconnected, BOOL includeClassHandler);
extern const char *map_images(enum dyld_image_states state, uint32_t infoCount, const struct dyld_image_info infoList[]);
extern const char *map_images_nolock(enum dyld_image_states state, uint32_t infoCount, const struct dyld_image_info infoList[]);
extern const char * load_images(enum dyld_image_states state, uint32_t infoCount, const struct dyld_image_info infoList[]);
extern BOOL load_images_nolock(enum dyld_image_states state, uint32_t infoCount, const struct dyld_image_info infoList[]);
extern void unmap_image(const struct mach_header *mh, intptr_t vmaddr_slide);
extern void unmap_image_nolock(const struct mach_header *mh);
extern void _read_images(header_info **hList, uint32_t hCount);
extern void prepare_load_methods(header_info *hi);
extern void _unload_image(header_info *hi);
extern const char ** _objc_copyClassNamesForImage(header_info *hi, unsigned int *outCount);

extern Class _objc_allocateFutureClass(const char *name);


extern const header_info *_headerForClass(Class cls);

extern Class _class_getSuperclass(Class cls);
extern Class _class_remap(Class cls);
extern BOOL _class_getInfo(Class cls, int info);
extern const char *_class_getName(Class cls);
extern size_t _class_getInstanceSize(Class cls);
extern Class _class_getMeta(Class cls);
extern BOOL _class_isMetaClass(Class cls);
extern Cache _class_getCache(Class cls);
extern void _class_setCache(Class cls, Cache cache);
extern BOOL _class_isInitializing(Class cls);
extern BOOL _class_isInitialized(Class cls);
extern void _class_setInitializing(Class cls);
extern void _class_setInitialized(Class cls);
extern Class _class_getNonMetaClass(Class cls, id obj);
extern Method _class_getMethod(Class cls, SEL sel);
extern Method _class_getMethodNoSuper(Class cls, SEL sel);
extern Method _class_getMethodNoSuper_nolock(Class cls, SEL sel);
extern BOOL _class_isLoadable(Class cls);
extern IMP _class_getLoadMethod(Class cls);
extern BOOL _class_hasLoadMethod(Class cls);
extern BOOL _class_hasCxxStructors(Class cls);
extern BOOL _class_shouldFinalizeOnMainThread(Class cls);
extern void _class_setFinalizeOnMainThread(Class cls);
extern BOOL _class_instancesHaveAssociatedObjects(Class cls);
extern void _class_setInstancesHaveAssociatedObjects(Class cls);
extern BOOL _class_shouldGrowCache(Class cls);
extern void _class_setGrowCache(Class cls, BOOL grow);
extern Ivar _class_getVariable(Class cls, const char *name, Class *memberOf);
extern BOOL _class_usesAutomaticRetainRelease(Class cls);
extern uint32_t _class_getInstanceStart(Class cls);

extern unsigned _class_createInstancesFromZone(Class cls, size_t extraBytes, void *zone, id *results, unsigned num_requested);
extern id _objc_constructOrFree(Class cls, void *bytes);

extern const char *_category_getName(Category cat);
extern const char *_category_getClassName(Category cat);
extern Class _category_getClass(Category cat);
extern IMP _category_getLoadMethod(Category cat);

extern BOOL object_cxxConstruct(id obj);
extern void object_cxxDestruct(id obj);

extern Method _class_resolveMethod(Class cls, SEL sel);
extern void log_and_fill_cache(Class cls, Class implementer, Method meth, SEL sel);

#define OBJC_WARN_DEPRECATED \
    do { \
        static int warned = 0; \
        if (!warned) { \
            warned = 1; \
            _objc_inform_deprecated(__FUNCTION__, NULL); \
        } \
    } while (0) \

__END_DECLS


#ifndef STATIC_ASSERT
#   define STATIC_ASSERT(x) _STATIC_ASSERT2(x, __LINE__)
#   define _STATIC_ASSERT2(x, line) _STATIC_ASSERT3(x, line)
#   define _STATIC_ASSERT3(x, line)                                     \
        typedef struct {                                                \
            int _static_assert[(x) ? 0 : -1];                           \
        } _static_assert_ ## line __attribute__((unavailable)) 
#endif


/***********************************************************************
* object_getClass.
* Locking: None. If you add locking, tell gdb (rdar://7516456).
**********************************************************************/
static inline Class _object_getClass(id obj)
{
#if SUPPORT_TAGGED_POINTERS
    if (OBJC_IS_TAGGED_PTR(obj)) {
        uint8_t slotNumber = ((uint8_t) (uint64_t) obj) & 0x0F;
        Class isa = _objc_tagged_isa_table[slotNumber];
        return isa;
    }
#endif
    if (obj) return obj->isa;
    else return Nil;
}


// Global operator new and delete. We must not use any app overrides.
// This ALSO REQUIRES each of these be in libobjc's unexported symbol list.
#if __cplusplus
#include <new>
inline void* operator new(std::size_t size) throw (std::bad_alloc) { return _malloc_internal(size); }
inline void* operator new[](std::size_t size) throw (std::bad_alloc) { return _malloc_internal(size); }
inline void* operator new(std::size_t size, const std::nothrow_t&) throw() { return _malloc_internal(size); }
inline void* operator new[](std::size_t size, const std::nothrow_t&) throw() { return _malloc_internal(size); }
inline void operator delete(void* p) throw() { _free_internal(p); }
inline void operator delete[](void* p) throw() { _free_internal(p); }
inline void operator delete(void* p, const std::nothrow_t&) throw() { _free_internal(p); }
inline void operator delete[](void* p, const std::nothrow_t&) throw() { _free_internal(p); }
#endif


#endif /* _OBJC_PRIVATE_H_ */

