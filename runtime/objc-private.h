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
 *    objc-private.h
 *    Copyright 1988-1996, NeXT Software, Inc.
 */

#ifndef _OBJC_PRIVATE_H_
#define _OBJC_PRIVATE_H_

#include "objc-config.h"

/* Isolate ourselves from the definitions of id and Class in the compiler 
 * and public headers.
 */

#ifdef _OBJC_OBJC_H_
#error include objc-private.h before other headers
#endif

#define OBJC_TYPES_DEFINED 1
#undef OBJC_OLD_DISPATCH_PROTOTYPES
#define OBJC_OLD_DISPATCH_PROTOTYPES 0

#include <cstddef>  // for nullptr_t
#include <stdint.h>
#include <assert.h>

// An assert that's disabled for release builds but still ensures the expression compiles.
#ifdef NDEBUG
#define ASSERT(x) (void)sizeof(!(x))
#else
#define ASSERT(x) assert(x)
#endif

// `this` is never NULL in C++ unless we encounter UB, but checking for what's impossible
// is the point of these asserts, so disable the corresponding warning, and let's hope
// we will reach the assert despite the UB
#define ASSERT_THIS_NOT_NULL \
_Pragma("clang diagnostic push") \
_Pragma("clang diagnostic ignored \"-Wundefined-bool-conversion\"") \
ASSERT(this) \
_Pragma("clang diagnostic pop")

// An assert that's enabled in release builds.
#define RELEASE_ASSERT(x, message, ...) \
    do { \
        if (slowpath(!(x))) \
            _objc_fatal("Assertion failed: (%s) - " message, #x __VA_OPT__(,) __VA_ARGS__); \
    } while(0)

// Generate an alias for a function
#define _OBJC_ALIAS_STR(x) #x
#define OBJC_DECLARE_FUNCTION_ALIAS(alias,orig)                             \
    asm("  .globl _" _OBJC_ALIAS_STR(alias) "\n"                            \
        "  .set _" _OBJC_ALIAS_STR(alias) ",_" _OBJC_ALIAS_STR(orig) "\n")

struct objc_class;
struct objc_object;
struct category_t;

typedef struct objc_class *Class;
typedef struct objc_object *id;
typedef struct classref *classref_t;

namespace {
    struct SideTable;
};

#include "isa.h"

union isa_t {
    isa_t() { }
    isa_t(uintptr_t value) : bits(value) { }

    uintptr_t bits;

private:
    // Accessing the class requires custom ptrauth operations, so
    // force clients to go through setClass/getClass by making this
    // private.
    Class cls;

public:
#if defined(ISA_BITFIELD)
    struct {
        ISA_BITFIELD;  // defined in isa.h
    };

#if ISA_HAS_INLINE_RC
    bool isDeallocating() const {
        return extra_rc == 0 && has_sidetable_rc == 0;
    }
    void setDeallocating() {
        extra_rc = 0;
        has_sidetable_rc = 0;
    }
#endif // ISA_HAS_INLINE_RC

#endif

    void setClass(Class cls, objc_object *obj);
    Class getClass(bool authenticated) const;
    Class getDecodedClass(bool authenticated) const;
};


struct objc_object {
private:
    char isa_storage[sizeof(isa_t)];

    isa_t &isa() { return *reinterpret_cast<isa_t *>(isa_storage); }
    const isa_t &isa() const { return *reinterpret_cast<const isa_t *>(isa_storage); }

public:

    // ISA() assumes this is NOT a tagged pointer object
    Class ISA(bool authenticated = false) const;

    // rawISA() assumes this is NOT a tagged pointer object or a non pointer ISA
    Class rawISA() const;

    // getIsa() allows this to be a tagged pointer object
    Class getIsa() const;
    
    uintptr_t isaBits() const;

    // initIsa() should be used to init the isa of new objects only.
    // If this object already has an isa, use changeIsa() for correctness.
    // initInstanceIsa(): objects with no custom RR/AWZ
    // initClassIsa(): class objects
    // initProtocolIsa(): protocol objects
    // initIsa(): other objects
    void initIsa(Class cls /*nonpointer=false*/);
    void initClassIsa(Class cls /*nonpointer=maybe*/);
    void initProtocolIsa(Class cls /*nonpointer=maybe*/);
    void initInstanceIsa(Class cls, bool hasCxxDtor);

    // changeIsa() should be used to change the isa of existing objects.
    // If this is a new object, use initIsa() for performance.
    Class changeIsa(Class newCls);

    bool hasNonpointerIsa() const;
    bool isTaggedPointer() const;
    bool isBasicTaggedPointer() const;
    bool isExtTaggedPointer() const;
    bool isClass() const;

    // object may have associated objects?
    bool hasAssociatedObjects() const;
    void setHasAssociatedObjects();

    // object may be weakly referenced?
    bool isWeaklyReferenced() const;
    void setWeaklyReferenced_nolock();

    // object may be uniquely referenced?
    bool isUniquelyReferenced() const;

    // object may have -.cxx_destruct implementation?
    bool hasCxxDtor() const;

    // Optimized calls to retain/release methods
    id retain();
    void release();
    id autorelease();

    // Implementations of retain/release methods
    id rootRetain();
    bool rootRelease();
    id rootAutorelease();
    bool rootTryRetain();
    bool rootReleaseShouldDealloc();
    uintptr_t rootRetainCount() const;

    // Implementation of dealloc methods
    bool rootIsDeallocating() const;
    void clearDeallocating();
    void rootDealloc();

private:
    void initIsa(Class newCls, bool nonpointer, bool hasCxxDtor);

    // Slow paths for inline control
    id rootAutorelease2();

#if SUPPORT_NONPOINTER_ISA
    // Controls what parts of root{Retain,Release} to emit/inline
    // - Full means the full (slow) implementation
    // - Fast means the fastpaths only
    // - FastOrMsgSend means the fastpaths but checking whether we should call
    //   -retain/-release or Swift, for the usage of objc_{retain,release}
    enum class RRVariant {
        Full,
        Fast,
        FastOrMsgSend,
    };

    // Unified retain count manipulation for nonpointer isa
    inline id rootRetain(bool tryRetain, RRVariant variant);
    inline bool rootRelease(bool performDealloc, RRVariant variant);
    id rootRetain_overflow(bool tryRetain);
    uintptr_t rootRelease_underflow(bool performDealloc);

    void clearDeallocating_slow();

    // Side table retain count overflow for nonpointer isa
    struct SidetableBorrow { size_t borrowed, remaining; };

    void sidetable_lock() const;
    void sidetable_unlock() const;

    void sidetable_moveExtraRC_nolock(size_t extra_rc, bool isDeallocating, bool weaklyReferenced);
    bool sidetable_addExtraRC_nolock(size_t delta_rc);
    SidetableBorrow sidetable_subExtraRC_nolock(size_t delta_rc);
    size_t sidetable_getExtraRC_nolock() const;
    void sidetable_clearExtraRC_nolock();
#endif

    // Side-table-only retain count
    bool sidetable_isDeallocating() const;
    void sidetable_clearDeallocating();

    bool sidetable_isWeaklyReferenced() const;
    void sidetable_setWeaklyReferenced_nolock();

    id sidetable_retain(bool locked = false);
    id sidetable_retain_slow(SideTable& table);

    uintptr_t sidetable_release(bool locked = false, bool performDealloc = true);
    uintptr_t sidetable_release_slow(SideTable& table, bool performDealloc = true);

    bool sidetable_tryRetain();

    uintptr_t sidetable_retainCount() const;
#if DEBUG
    bool sidetable_present() const;
#endif

    void performDealloc();
};


// signed_method_t is a dummy type that exists to distinguish between
// externally-visible Method values and internal method_t* values.
// Externally-visible Method values are signed on ptrauth archs.
// Use _method_auth and _method_sign to convert between them.
typedef struct signed_method_t *Method;
typedef struct ivar_t *Ivar;
typedef struct category_t *Category;
typedef struct property_t *objc_property_t;

// Settings from environment variables
typedef enum {
    Off = 0,
    On = 1,
    Fatal = 2
} option_value_t;

#define OPTION(var, def, env, help) extern option_value_t var;
#define INTERNAL_OPTION(var, def, env, help) extern option_value_t var;
#include "objc-env.h"
#undef OPTION
#undef INTERNAL_OPTION

/* errors */
extern id(*badAllocHandler)(Class);
extern id _objc_callBadAllocHandler(Class cls) __attribute__((cold, noinline));
extern void __objc_error(id, const char *, ...) __attribute__((cold, format (printf, 2, 3), noreturn));
extern void _objc_inform(const char *fmt, ...) __attribute__((cold, format(printf, 1, 2)));
extern void _objc_inform_on_crash(const char *fmt, ...) __attribute__((cold, format (printf, 1, 2)));
extern void _objc_inform_now_and_on_crash(const char *fmt, ...) __attribute__((cold, format (printf, 1, 2)));
extern void _objc_inform_deprecated(const char *oldname, const char *newname) __attribute__((cold, noinline));
extern void inform_duplicate(const char *name, Class oldCls, Class cls);

// Public headers

#include "objc.h"
#include "runtime.h"
#include "objc-os.h"
#include "objc-abi.h"
#include "objc-api.h"
#include "objc-config.h"
#include "objc-internal.h"
#include "maptable.h"
#include "hashtable2.h"

/* Do not include message.h here. */
/* #include "message.h" */

#define __APPLE_API_PRIVATE
#include "objc-gdb.h"
#undef __APPLE_API_PRIVATE


// Private headers

#include "objc-ptrauth.h"

#include "objc-runtime-new.h"

#include "objc-references.h"
#include "objc-initialize.h"
#include "objc-loadmethod.h"
#include "objc-opt.h"


#define STRINGIFY(x) #x
#define STRINGIFY2(x) STRINGIFY(x)

__BEGIN_DECLS

/* preoptimization */
extern void preopt_init(void);
extern void disableSharedCacheProtocolOptimizations(void);
extern bool isPreoptimized(void);
extern bool noMissingWeakSuperclasses(void);
extern header_info *preoptimizedHinfoForHeader(const headerType *mhdr);

extern Protocol *getPreoptimizedProtocol(const char *name);
extern Protocol *getSharedCachePreoptimizedProtocol(const char *name);

extern unsigned getPreoptimizedClassUnreasonableCount();
extern Class getPreoptimizedClass(const char *name);
extern Class getPreoptimizedClassesWithMetaClass(Class metacls);

namespace objc {

struct SafeRanges {
private:
    struct Range {
        uintptr_t start;
        uintptr_t end;

        inline bool contains(uintptr_t ptr) const {
            uintptr_t m_start, m_end;
#if __arm64__
            // <rdar://problem/48304934> Force the compiler to use ldp
            // we really don't want 2 loads and 2 jumps.
            __asm__(
# if __LP64__
                    "ldp %x[one], %x[two], [%x[src]]"
# else
                    "ldp %w[one], %w[two], [%x[src]]"
# endif
                    : [one] "=r" (m_start), [two] "=r" (m_end)
                    : [src] "r" (this)
            );
#else
            m_start = start;
            m_end = end;
#endif
            return m_start <= ptr && ptr < m_end;
        }
    };

    struct Range  shared_cache;
    struct Range *ranges;
    uint32_t count;
    uint32_t size : 31;
    uint32_t sorted : 1;

public:
    inline bool inSharedCache(uintptr_t ptr) const {
        return shared_cache.contains(ptr);
    }
    inline bool contains(uint16_t witness, uintptr_t ptr) const {
        return witness < count && ranges[witness].contains(ptr);
    }

    inline void setSharedCacheRange(uintptr_t start, uintptr_t end) {
        shared_cache = Range{start, end};
        add(start, end);
    }
    bool find(uintptr_t ptr, uint32_t &pos);
    void add(uintptr_t start, uintptr_t end);
    void remove(uintptr_t start, uintptr_t end);
};

extern struct SafeRanges dataSegmentsRanges;

static inline bool inSharedCache(uintptr_t ptr) {
    return dataSegmentsRanges.inSharedCache(ptr);
}

} // objc

struct header_info;

struct header_info_rw* getPreoptimizedHeaderRW(const struct header_info *const hdr);
bool hasSharedCacheDyldInfo();

typedef struct header_info {
private:
    // Note, this is no longer a pointer, but instead an offset to a pointer
    // from this location.
    intptr_t mhdr_offset;

    // Note, this is no longer a pointer, but instead an offset to a pointer
    // from this location.
    intptr_t info_offset;

    // Note, this is no longer a pointer, but instead an offset to a pointer
    // from this location.
    // This may not be present in old shared caches
    intptr_t dyld_info_offset;

    // Do not add fields without editing ObjCModernAbstraction.hpp
public:

    header_info_rw *getHeaderInfoRW() {
        header_info_rw *preopt = getPreoptimizedHeaderRW(this);
        if (preopt) return preopt;
        else return &rw_data[0];
    }

    const headerType *mhdr() const {
        return (const headerType *)(((intptr_t)&mhdr_offset) + mhdr_offset);
    }

    void setmhdr(const headerType *mhdr) {
        mhdr_offset = (intptr_t)mhdr - (intptr_t)&mhdr_offset;
    }

    const objc_image_info *info() const {
        return (const objc_image_info *)(((intptr_t)&info_offset) + info_offset);
    }

    void setinfo(const objc_image_info *info) {
        info_offset = (intptr_t)info - (intptr_t)&info_offset;
    }

    _dyld_section_location_info_t dyldInfo() const {
        // Shared cache images might not have the info, for now
        if ( isPreoptimized() ) {
            if ( !hasSharedCacheDyldInfo() )
                return NULL;
        }
        return (const _dyld_section_location_info_t)(((intptr_t)&dyld_info_offset) + dyld_info_offset);
    }

    void setdyldInfo(_dyld_section_location_info_t info) {
        dyld_info_offset = (intptr_t)info - (intptr_t)&dyld_info_offset;
    }

    // refs sections
    SEL *selrefs(size_t *outCount) const;
    message_ref_t *messagerefs(size_t *outCount) const;
    Class* classrefs(size_t *outCount) const;
    Class* superrefs(size_t *outCount) const;
    protocol_t ** protocolrefs(size_t *outCount) const;

    // list sections
    classref_t const *classlist(size_t *outCount) const;
    const classref_t *nlclslist(size_t *outCount) const;
    stub_class_t * const *stublist(size_t *outCount) const;
    category_t * const *catlist(size_t *outCount) const;
    category_t * const *catlist2(size_t *outCount) const;
    category_t * const *nlcatlist(size_t *outCount) const;
    protocol_t * const *protocollist(size_t *outCount) const;

    // misc sections
    bool hasForkOkSection() const;
    bool hasRawISASection() const;

    bool isLoaded() {
        return getHeaderInfoRW()->getLoaded();
    }

    void setLoaded(bool v) {
        getHeaderInfoRW()->setLoaded(v);
    }

    header_info *getNext() {
        return getHeaderInfoRW()->getNext();
    }

    void setNext(header_info *v) {
        getHeaderInfoRW()->setNext(v);
    }

    bool isBundle() {
        return mhdr()->filetype == MH_BUNDLE;
    }

    const char *fname() const {
        return dyld_image_path_containing_address(mhdr());
    }

    bool isPreoptimized() const;

private:
    // Images in the shared cache will have an empty array here while those
    // allocated at run time will allocate a single entry.
    header_info_rw rw_data[];
} header_info;

extern header_info *FirstHeader;
extern header_info *LastHeader;
extern header_info *LastHeaderRealizedAllClasses;

extern void appendHeader(header_info *hi);
extern void removeHeader(header_info *hi);

extern objc_image_info *
_getObjcImageInfo(const headerType *mhdr, _dyld_section_location_info_t info, size_t *outBytes);

struct mapped_image_info {
    header_info *hi;
    _dyld_objc_notify_mapped_info dyldInfo;

    bool dyldObjCRefsOptimized() {
        return dyldInfo.dyldObjCRefsOptimized && isPreoptimized();
    }

    // TODO: dyld will add a flag for this which we need to adopt.
    bool dyldCategoriesOptimized() {
        return false;
    }
};

// Mach-O segment and section names are 16 bytes and may be un-terminated.

static inline bool segnameEquals(const char *lhs, const char *rhs) {
    return 0 == strncmp(lhs, rhs, 16);
}

static inline bool segnameStartsWith(const char *segname, const char *prefix) {
    return 0 == strncmp(segname, prefix, strlen(prefix));
}

static inline bool sectnameEquals(const char *lhs, const char *rhs) {
    return segnameEquals(lhs, rhs);
}

static inline bool sectnameStartsWith(const char *sectname, const char *prefix){
    return segnameStartsWith(sectname, prefix);
}

extern bool didCallDyldNotifyRegister;

/* selectors */
extern void sel_init(size_t selrefCount);
extern SEL sel_registerNameNoLock(const char *str, bool copy);
extern SEL _sel_searchBuiltins(const char *str);

extern SEL SEL_cxx_construct;
extern SEL SEL_cxx_destruct;

extern Class _calloc_class(size_t size);

/* method lookup */
enum {
    LOOKUP_INITIALIZE = 1,
    LOOKUP_RESOLVER = 2,
    LOOKUP_NIL = 4,
    LOOKUP_NOCACHE = 8,
};
extern IMP lookUpImpOrForward(id obj, SEL, Class cls, int behavior);
extern IMP lookUpImpOrForwardTryCache(id obj, SEL, Class cls, int behavior = 0);
extern IMP lookUpImpOrNilTryCache(id obj, SEL, Class cls, int behavior = 0);

extern IMP lookupMethodInClassAndLoadCache(Class cls, SEL sel);

struct IMPAndSEL {
    IMP imp;
    SEL sel;
};

extern IMPAndSEL _method_getImplementationAndName(Method m);

extern BOOL class_respondsToSelector_inst(id inst, SEL sel, Class cls);
extern Class class_initialize(Class cls, id inst);

extern bool objcMsgLogEnabled;
extern bool logMessageSend(bool isClassMethod,
                    const char *objectsClass,
                    const char *implementingClass,
                    SEL selector);

/* message dispatcher */

#if !OBJC_OLD_DISPATCH_PROTOTYPES
extern void _objc_msgForward_impcache(void);
#else
extern id _objc_msgForward_impcache(id, SEL, ...);
#endif

// Report an error gated on an environment variable. Based on the variable,
// uses _objc_inform or _objc_fatal. The format string and arguments are only
// evaluated when needed.
#define OBJC_DEBUG_OPTION_REPORT_ERROR(option, ...) \
    do { \
        if (option) \
            (option == Fatal ? _objc_fatal : _objc_inform)(__VA_ARGS__); \
    } while(0)

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

class recursive_mutex_locker_t : nocopy_t {
    recursive_mutex_t& lock;
  public:
    recursive_mutex_locker_t(recursive_mutex_t& newLock) 
        : lock(newLock) { lock.lock(); }
    ~recursive_mutex_locker_t() { lock.unlock(); }
};


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


extern void environ_init(void);
extern void runtime_init(void);

extern void logReplacedMethod(const char *className, SEL s, bool isMeta, const char *catName, void *oldImp, void *newImp);


// objc per-thread storage
struct _objc_pthread_data {
    struct _objc_initializing_classes *initializingClasses; // for +initialize
    struct SyncCache *syncCache;  // for @synchronize
    struct alt_handler_list *handlerList;  // for exception alt handlers
    char *printableNames[4];  // temporary demangled names for logging
    const char **classNameLookups;  // for objc_getClass() hooks
    unsigned classNameLookupsAllocated;
    unsigned classNameLookupsUsed;

    // If you add new fields here, don't forget to update the destructor
    ~_objc_pthread_data();
};

extern _objc_pthread_data *_objc_fetch_pthread_data(bool create);

// encoding.h
extern unsigned int encoding_getNumberOfArguments(const char *typedesc);
extern unsigned int encoding_getSizeOfArguments(const char *typedesc);
extern unsigned int encoding_getArgumentInfo(const char *typedesc, unsigned int arg, const char **type, int *offset);
extern void encoding_getReturnType(const char *t, char *dst, size_t dst_len);
extern char * encoding_copyReturnType(const char *t);
extern void encoding_getArgumentType(const char *t, unsigned int index, char *dst, size_t dst_len);
extern char *encoding_copyArgumentType(const char *t, unsigned int index);

// sync.h
/// Different kinds of synchronization. The `_objc_sync_enter/exit_kind` calls
/// map each unique `(object, kind)` pair to a distinct lock. The `kind` allows
/// multiple distinct locks for the same object, used for different purposes.
enum class SyncKind {
    invalid, // Don't use, raw value of 0 means something went wrong.
    atSynchronize, // Used for @synchronize/objc_sync_enter/exit.
    classInitialize, // Used for +initialize machinery.
};
extern void _destroySyncCache(struct SyncCache *cache);
extern void _objc_sync_exit_forked_child(id obj, SyncKind kind);
extern void _objc_sync_assert_locked(id obj, SyncKind kind);
extern void _objc_sync_assert_unlocked(id obj, SyncKind kind);
extern void _objc_sync_foreach_lock(void (^call)(id obj, SyncKind kind, recursive_mutex_t *mutex));
extern void _objc_sync_lock_atfork_prepare(void);
extern void _objc_sync_lock_atfork_parent(void);
extern void _objc_sync_lock_atfork_child(void);
extern int _objc_sync_enter_kind(id obj, SyncKind kind);
extern int _objc_sync_exit_kind(id obj, SyncKind kind);

// arr
extern void arr_init(void);
extern id objc_autoreleaseReturnValue(id obj);

// block trampolines
#if !TARGET_OS_EXCLAVEKIT
extern void _imp_implementationWithBlock_init(void);
extern IMP _imp_implementationWithBlockNoCopy(id block);
#endif

// layout.h
typedef struct {
    uint8_t *bits;
    size_t bitCount;
    size_t bitsAllocated;
    bool weak;
} layout_bitmap;
extern layout_bitmap layout_bitmap_create(const unsigned char *layout_string, size_t layoutStringInstanceSize, size_t instanceSize, bool weak);
extern layout_bitmap layout_bitmap_create_empty(size_t instanceSize, bool weak);
extern void layout_bitmap_free(layout_bitmap bits);
extern const unsigned char *layout_string_create(layout_bitmap bits);
extern void layout_bitmap_set_ivar(layout_bitmap bits, const char *type, size_t offset);
extern void layout_bitmap_grow(layout_bitmap *bits, size_t newCount);
extern void layout_bitmap_slide(layout_bitmap *bits, size_t oldPos, size_t newPos);
extern void layout_bitmap_slide_anywhere(layout_bitmap *bits, size_t oldPos, size_t newPos);
extern bool layout_bitmap_splat(layout_bitmap dst, layout_bitmap src, 
                                size_t oldSrcInstanceSize);
extern bool layout_bitmap_or(layout_bitmap dst, layout_bitmap src, const char *msg);
extern bool layout_bitmap_clear(layout_bitmap dst, layout_bitmap src, const char *msg);
extern void layout_bitmap_print(layout_bitmap bits);


// fixme runtime
extern bool MultithreadedForkChild;
extern id objc_noop_imp(id self, SEL _cmd);
extern Class look_up_class(const char *aClassName, bool includeUnconnected, bool includeClassHandler);
extern bool is_root_ramdisk();
extern "C" void map_images(unsigned count, const struct _dyld_objc_notify_mapped_info infos[]);
extern void map_images_nolock(unsigned count,
                              const struct _dyld_objc_notify_mapped_info infos[],
                              bool *disabledClassROEnforcement);
extern void load_images(const struct _dyld_objc_notify_mapped_info* info);
extern void unmap_image(const char *path, const struct mach_header *mh);
extern void unmap_image_nolock(const struct mach_header *mh);
extern void _read_images(mapped_image_info infos[], uint32_t hCount, int totalClasses, int unoptimizedTotalClass);
void loadAllCategoriesIfNeeded(void);
extern void _unload_image(header_info *hi);

extern const header_info *_headerForClass(Class cls);

extern Class _class_remap(Class cls);
extern Ivar _class_getVariable(Class cls, const char *name);

extern unsigned _class_createInstances(Class cls, size_t extraBytes, id *results, unsigned num_requested);

extern const char *_category_getName(Category cat);
extern const char *_category_getClassName(Category cat);
extern Class _category_getClass(Category cat);
extern IMP _category_getLoadMethod(Category cat);

enum {
    OBJECT_CONSTRUCT_NONE = 0,
    OBJECT_CONSTRUCT_FREE_ONFAILURE = 1,
    OBJECT_CONSTRUCT_CALL_BADALLOC = 2,
};
extern id object_cxxConstructFromClass(id obj, Class cls, int flags);
extern void object_cxxDestruct(id obj);

extern void fixupCopiedIvars(id newObject, id oldObject);
extern Class _class_getClassForIvar(Class cls, Ivar ivar);


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

#define countof(arr) (sizeof(arr) / sizeof((arr)[0]))


static __inline uint32_t _objc_strhash(const char *s) {
    uint32_t hash = 0;
    for (;;) {
    int a = *s++;
    if (0 == a) break;
    hash += (hash << 8) + a;
    }
    return hash;
}

#if __cplusplus

template <typename T>
static inline T log2u(T x) {
    return (x<2) ? 0 : log2u(x>>1)+1;
}

template <typename T>
static inline T exp2u(T x) {
    return (1 << x);
}

template <typename T>
static T exp2m1u(T x) { 
    return (1 << x) - 1; 
}

#endif

// Misalignment-safe integer types
__attribute__((aligned(1))) typedef uintptr_t unaligned_uintptr_t;
__attribute__((aligned(1))) typedef  intptr_t unaligned_intptr_t;
__attribute__((aligned(1))) typedef  uint64_t unaligned_uint64_t;
__attribute__((aligned(1))) typedef   int64_t unaligned_int64_t;
__attribute__((aligned(1))) typedef  uint32_t unaligned_uint32_t;
__attribute__((aligned(1))) typedef   int32_t unaligned_int32_t;
__attribute__((aligned(1))) typedef  uint16_t unaligned_uint16_t;
__attribute__((aligned(1))) typedef   int16_t unaligned_int16_t;


// Global operator new and delete. We must not use any app overrides.
// This ALSO REQUIRES each of these be in libobjc's unexported symbol list.
#if __cplusplus && !defined(TEST_OVERRIDES_NEW)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Winline-new-delete"
#include <new>
inline void* operator new(std::size_t size) { return malloc(size); }
inline void* operator new[](std::size_t size) { return malloc(size); }
inline void* operator new(std::size_t size, const std::nothrow_t&) noexcept(true) { return malloc(size); }
inline void* operator new[](std::size_t size, const std::nothrow_t&) noexcept(true) { return malloc(size); }
inline void operator delete(void* p) noexcept(true) { free(p); }
inline void operator delete[](void* p) noexcept(true) { free(p); }
inline void operator delete(void* p, const std::nothrow_t&) noexcept(true) { free(p); }
inline void operator delete[](void* p, const std::nothrow_t&) noexcept(true) { free(p); }
#pragma clang diagnostic pop
#endif

// Overflow-detecting wrapper around malloc(n * m)
static inline void *alloc_overflow(size_t n, size_t m) {
    size_t total;
    if (__builtin_mul_overflow(n, m, &total))
        _objc_fatal("attempt to allocate %zu * %zu bytes would overflow", n, m);
    return malloc(total);
}

class TimeLogger {
    uint64_t mStart;
    bool mRecord;
 public:
    TimeLogger(bool record = true) 
     : mStart(nanoseconds())
     , mRecord(record) 
    { }

    void log(const char *msg) {
        if (mRecord) {
            uint64_t end = nanoseconds();
            _objc_inform("%.2f ms: %s", (end - mStart) / 1000000.0, msg);
            mStart = nanoseconds();
        }
    }
};

enum { CacheLineSize = 64 };

// StripedMap<T> is a map of void* -> T, sized appropriately 
// for cache-friendly lock striping. 
// For example, this may be used as StripedMap<spinlock_t>
// or as StripedMap<SomeStruct> where SomeStruct stores a spin lock.
template<typename T>
class StripedMap {
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    enum { StripeCount = 8 };
#else
    enum { StripeCount = 64 };
#endif

    struct PaddedT {
        T value alignas(CacheLineSize);
    };

    PaddedT array[StripeCount];

    static unsigned int indexForPointer(const void *p) {
        uintptr_t addr = reinterpret_cast<uintptr_t>(p);
        return ((addr >> 4) ^ (addr >> 9)) % StripeCount;
    }

 public:
    T& operator[] (const void *p) { 
        return array[indexForPointer(p)].value; 
    }
    const T& operator[] (const void *p) const { 
        return const_cast<StripedMap<T>>(this)[p]; 
    }

    // Shortcuts for StripedMaps of locks.
    void lockAll() {
        for (unsigned int i = 0; i < StripeCount; i++) {
            array[i].value.lock();
        }
    }

    void unlockAll() {
        for (unsigned int i = 0; i < StripeCount; i++) {
            array[i].value.unlock();
        }
    }

    void forceResetAll() {
        for (unsigned int i = 0; i < StripeCount; i++) {
            array[i].value.reset();
        }
    }

    void defineLockOrder() {
        for (unsigned int i = 1; i < StripeCount; i++) {
            lockdebug::lock_precedes_lock(&array[i-1].value, &array[i].value);
        }
    }

    void precedeLock(const void *newlock) {
        // assumes defineLockOrder is also called
        lockdebug::lock_precedes_lock(&array[StripeCount-1].value, newlock);
    }

    void succeedLock(const void *oldlock) {
        // assumes defineLockOrder is also called
        lockdebug::lock_precedes_lock(oldlock, &array[0].value);
    }

    const void *getLock(int i) {
        if (i < StripeCount) return &array[i].value;
        else return nil;
    }

    template<typename F>
    void forEach(F f) {
        for (int i = 0; i < StripeCount; i++) {
            f(array[i].value);
        }
    }
    
#if DEBUG
    StripedMap() {
        // Verify alignment expectations.
        uintptr_t base = (uintptr_t)&array[0].value;
        uintptr_t delta = (uintptr_t)&array[1].value - base;
        ASSERT(delta % CacheLineSize == 0);
        ASSERT(base % CacheLineSize == 0);
    }
#else
    constexpr StripedMap() {}
#endif
};


// DisguisedPtr<T> acts like pointer type T*, except the 
// stored value is disguised to hide it from tools like `leaks`.
// nil is disguised as itself so zero-filled memory works as expected, 
// which means 0x80..00 is also disguised as itself but we don't care.
// Note that weak_entry_t knows about this encoding.
template <typename T>
class DisguisedPtr {
    void *value;

    static void *disguise(T* ptr) {
        return (void *)-(uintptr_t)ptr;
    }

    static T* undisguise(void *val) {
        return (T*)-(uintptr_t)val;
    }

 public:
    DisguisedPtr() { }
    DisguisedPtr(T* ptr) 
        : value(disguise(ptr)) { }
    DisguisedPtr(const DisguisedPtr<T>& ptr) 
        : value(ptr.value) { }

    DisguisedPtr<T>& operator = (T* rhs) {
        value = disguise(rhs);
        return *this;
    }
    DisguisedPtr<T>& operator = (const DisguisedPtr<T>& rhs) {
        value = rhs.value;
        return *this;
    }

    operator T* () const {
        return undisguise(value);
    }
    T* operator -> () const { 
        return undisguise(value);
    }
    T& operator * () const { 
        return *undisguise(value);
    }
    T& operator [] (size_t i) const {
        return undisguise(value)[i];
    }

    // pointer arithmetic operators omitted 
    // because we don't currently use them anywhere
};

// fixme type id is weird and not identical to objc_object*
static inline bool operator == (DisguisedPtr<objc_object> lhs, id rhs) {
    return lhs == (objc_object *)rhs;
}
static inline bool operator != (DisguisedPtr<objc_object> lhs, id rhs) {
    return lhs != (objc_object *)rhs;
}


// Storage for a thread-safe chained hook function.
// get() returns the value for calling.
// set() installs a new function and returns the old one for chaining.
// More precisely, set() writes the old value to a variable supplied by
// the caller. get() and set() use appropriate barriers so that the
// old value is safely written to the variable before the new value is
// called to use it.
//
// T1: store to old variable; store-release to hook variable
// T2: load-acquire from hook variable; call it; called hook loads old variable

template <typename Fn>
class ChainedHookFunction {
    std::atomic<Fn> hook{nil};

public:
    constexpr ChainedHookFunction(Fn f) : hook{f} { };

    Fn get() {
        return hook.load(std::memory_order_acquire);
    }

    void set(Fn newValue, Fn *oldVariable)
    {
        Fn oldValue = hook.load(std::memory_order_relaxed);
        do {
            *oldVariable = oldValue;
        } while (!hook.compare_exchange_weak(oldValue, newValue,
                                             std::memory_order_release,
                                             std::memory_order_relaxed));
    }
};


// A small vector for use as a global variable. Only supports appending and
// iteration. Stores up to N elements inline, and multiple elements in a heap
// allocation. There is no attempt to amortize reallocation cost; this is
// intended to be used in situation where a small number of elements is
// common, more might happen, and significantly more is very rare.
//
// This does not clean up its allocation, and thus cannot be used as a local
// variable or member of something with limited lifetime.

template <typename T, unsigned InlineCount>
class GlobalSmallVector {
    static_assert(std::is_pod<T>::value, "SmallVector requires POD types");
    
protected:
    unsigned count{0};
    union {
        T inlineElements[InlineCount];
        T *elements{nullptr};
    };
    
public:
    void append(const T &val) {
        if (count < InlineCount) {
            // We have space. Store the new value inline.
            inlineElements[count] = val;
        } else if (count == InlineCount) {
            // Inline storage is full. Switch to a heap allocation.
            T *newElements = (T *)malloc((count + 1) * sizeof(T));
            memcpy(newElements, inlineElements, count * sizeof(T));
            newElements[count] = val;
            elements = newElements;
        } else {
            // Resize the heap allocation and append.
            elements = (T *)realloc(elements, (count + 1) * sizeof(T));
            elements[count] = val;
        }
        count++;
    }
    
    const T *begin() const {
        return count <= InlineCount ? inlineElements : elements;
    }
    
    const T *end() const {
        return begin() + count;
    }
};

// A small vector that cleans up its internal memory allocation when destroyed.
template <typename T, unsigned InlineCount>
class SmallVector: public GlobalSmallVector<T, InlineCount> {
public:
    ~SmallVector() {
        if (this->count > InlineCount)
            free(this->elements);
    }

    template <unsigned OtherCount>
    void initFrom(const GlobalSmallVector<T, OtherCount> &other) {
        ASSERT(this->count == 0);
        this->count = (unsigned)(other.end() - other.begin());
        if (this->count > InlineCount) {
            this->elements = (T *)memdup(other.begin(), this->count * sizeof(T));
        } else {
            memcpy(this->inlineElements, other.begin(), this->count * sizeof(T));
        }
    }
};

// A simple wrapper around a pointer and a count, to allow using a plain C array
// in a range-based for loop. There is no bounds checking of any kind, hence
// "Unsafe."
template <typename T>
class UnsafeSpan {
    T *ptr;
    size_t count;

public:
    UnsafeSpan(T *ptr, size_t count) : ptr(ptr), count(count) {}

    T *begin() { return ptr; }
    T *end() { return ptr + count; }
};

// A fixed-size array that fills from the back, producing a contiguous chunk of
// memory with the elements ordered in reverse order from how they were added.
// This is a small wrapper around a C array and a count, with a bit of logic for
// computing insertion points. Built for attachCategories, which wants to build
// up arrays of category lists in reverse order.
template <typename T, uint32_t size>
struct ReversedFixedSizeArray {
    T array[size];
    uint32_t count = 0;

    bool isFull() const {
        return count >= size;
    }

    void add(T value) {
        ASSERT(!isFull());
        array[size - ++count] = value;
    }

    void clear() {
        count = 0;
    }

    T *begin() {
        return array + size - count;
    }
};

// Pointer hash function.
// This is not a terrific hash, but it is fast 
// and not outrageously flawed for our purposes.

// Based on principles from http://locklessinc.com/articles/fast_hash/
// and evaluation ideas from http://floodyberry.com/noncryptohashzoo/
#if __LP64__
static inline uint32_t ptr_hash(uint64_t key)
{
    key ^= key >> 4;
    key *= 0x8a970be7488fda55;
    key ^= __builtin_bswap64(key);
    return (uint32_t)key;
}
#else
static inline uint32_t ptr_hash(uint32_t key)
{
    key ^= key >> 4;
    key *= 0x5052acdb;
    key ^= __builtin_bswap32(key);
    return key;
}
#endif

/*
  Higher-quality hash function. This is measurably slower in some workloads.
#if __LP64__
 uint32_t ptr_hash(uint64_t key)
{
    key -= __builtin_bswap64(key);
    key *= 0x8a970be7488fda55;
    key ^= __builtin_bswap64(key);
    key *= 0x8a970be7488fda55;
    key ^= __builtin_bswap64(key);
    return (uint32_t)key;
}
#else
static uint32_t ptr_hash(uint32_t key)
{
    key -= __builtin_bswap32(key);
    key *= 0x5052acdb;
    key ^= __builtin_bswap32(key);
    key *= 0x5052acdb;
    key ^= __builtin_bswap32(key);
    return key;
}
#endif
*/



// Lock declarations
#include "objc-locks.h"

// Inlined parts of objc_object's implementation
#include "objc-object.h"

#endif /* _OBJC_PRIVATE_H_ */

