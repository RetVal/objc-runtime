/*
 * Copyright (c) 2007 Apple Inc.  All Rights Reserved.
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
* objc-os.m
* OS portability layer.
**********************************************************************/

#include "objc-private.h"
#include "objc-loadmethod.h"



#if   TARGET_OS_MAC

#include "objc-file.h"


/***********************************************************************
* libobjc must never run static destructors. 
* Cover libc's __cxa_atexit with our own definition that runs nothing.
* rdar://21734598  ER: Compiler option to suppress C++ static destructors
**********************************************************************/
extern "C" int __cxa_atexit();
extern "C" int __cxa_atexit() { return 0; }


/***********************************************************************
* bad_magic.
* Return YES if the header has invalid Mach-o magic.
**********************************************************************/
bool bad_magic(const headerType *mhdr)
{
    return (mhdr->magic != MH_MAGIC  &&  mhdr->magic != MH_MAGIC_64  &&  
            mhdr->magic != MH_CIGAM  &&  mhdr->magic != MH_CIGAM_64);
}


static header_info * addHeader(const headerType *mhdr, const char *path,
                               const _dyld_section_location_info_t dyldObjCInfo,
                               int &totalClasses, int &unoptimizedTotalClasses)
{
    header_info *hi;

    if (bad_magic(mhdr)) return NULL;

    bool inSharedCache = false;

    // Look for hinfo from the dyld shared cache.
    hi = preoptimizedHinfoForHeader(mhdr);
    if (hi) {
        // Found an hinfo in the dyld shared cache.

        // Weed out duplicates.
        if (hi->isLoaded()) {
            return NULL;
        }

        inSharedCache = true;

        // Initialize fields not set by the shared cache
        // hi->next is set by appendHeader
        hi->setLoaded(true);

        if (PrintPreopt) {
            _objc_inform("PREOPTIMIZATION: honoring preoptimized header info at %p for %s", hi, hi->fname());
        }

#if DEBUG
        // Verify image_info
//        size_t info_size = 0;
//        const objc_image_info *image_info = _getObjcImageInfo(mhdr, dyldObjCInfo, &info_size);
//        const objc_image_info *hi_info = hi->info();
//        ASSERT(image_info == hi_info);
#endif
    }
    else 
    {
        // Didn't find an hinfo in the dyld shared cache.

        // Locate the __OBJC segment
        size_t info_size = 0;
        unsigned long seg_size;
        const objc_image_info *image_info = _getObjcImageInfo(mhdr, dyldObjCInfo, &info_size);
        const uint8_t *objc_segment = getsegmentdata(mhdr,SEG_OBJC,&seg_size);
        if (!objc_segment  &&  !image_info) return NULL;

        // Allocate a header_info entry.
        // Note we also allocate space for a single header_info_rw in the
        // rw_data[] inside header_info.
        hi = (header_info *)calloc(sizeof(header_info) + sizeof(header_info_rw), 1);

        // Set up the new header_info entry.
        hi->setmhdr(mhdr);
        // Install a placeholder image_info if absent to simplify code elsewhere
        static const objc_image_info emptyInfo = {0, 0};
        hi->setinfo(image_info ?: &emptyInfo);
        hi->setdyldInfo(dyldObjCInfo);

        hi->setLoaded(true);
    }

    {
        size_t count = 0;
        if (hi->classlist(&count)) {
            totalClasses += (int)count;
            if (!inSharedCache) unoptimizedTotalClasses += count;
        }
    }

    appendHeader(hi);

    return hi;
}


/***********************************************************************
* linksToLibrary
* Returns true if the image links directly to a dylib whose install name 
* is exactly the given name.
**********************************************************************/
bool
linksToLibrary(const header_info *hi, const char *name)
{
    const struct dylib_command *cmd;
    unsigned long i;
    
    cmd = (const struct dylib_command *) (hi->mhdr() + 1);
    for (i = 0; i < hi->mhdr()->ncmds; i++) {
        if (cmd->cmd == LC_LOAD_DYLIB  ||  cmd->cmd == LC_LOAD_UPWARD_DYLIB  ||
            cmd->cmd == LC_LOAD_WEAK_DYLIB  ||  cmd->cmd == LC_REEXPORT_DYLIB)
        {
            const char *dylib = cmd->dylib.name.offset + (const char *)cmd;
            if (0 == strcmp(dylib, name)) return true;
        }
        cmd = (const struct dylib_command *)((char *)cmd + cmd->cmdsize);
    }

    return false;
}


#if SUPPORT_GC_COMPAT

/***********************************************************************
* shouldRejectGCApp
* Return YES if the executable requires GC.
**********************************************************************/
static bool shouldRejectGCApp(const header_info *hi)
{
    ASSERT(hi->mhdr()->filetype == MH_EXECUTE);

    if (!hi->info()->supportsGC()) {
        // App does not use GC. Don't reject it.
        return NO;
    }
        
    // Exception: Trivial AppleScriptObjC apps can run without GC.
    // 1. executable defines no classes
    // 2. executable references NSBundle only
    // 3. executable links to AppleScriptObjC.framework
    // Note that objc_appRequiresGC() also knows about this.
    size_t classcount = 0;
    size_t refcount = 0;
    hi->classlist(&classcount);
    hi->classrefs(&refcount);
    if (classcount == 0  &&  refcount == 1  &&  
        linksToLibrary(hi, "/System/Library/Frameworks"
                       "/AppleScriptObjC.framework/Versions/A"
                       "/AppleScriptObjC"))
    {
        // It's AppleScriptObjC. Don't reject it.
        return NO;
    } 
    else {
        // GC and not trivial AppleScriptObjC. Reject it.
        return YES;
    }
}


/***********************************************************************
* rejectGCImage
* Halt if an image requires GC.
* Testing of the main executable should use rejectGCApp() instead.
**********************************************************************/
static bool shouldRejectGCImage(const headerType *mhdr)
{
    ASSERT(mhdr->filetype != MH_EXECUTE);

    objc_image_info *image_info;
    size_t size;

    // 64-bit: no image_info means no objc at all
    image_info = _getObjcImageInfo(mhdr, nullptr, &size);
    if (!image_info) {
        // Not objc, therefore not GC. Don't reject it.
        return NO;
    }

    return image_info->requiresGC();
}

// SUPPORT_GC_COMPAT
#endif

/***********************************************************************
* hasSignedClassROPointers
* Test if an image has signed class_ro_t pointers.
**********************************************************************/
static bool hasSignedClassROPointers(const headerType *h, _dyld_section_location_info_t dyldObjCInfo)
{
    size_t infoSize = 0;
    objc_image_info *info = _getObjcImageInfo(h, dyldObjCInfo, &infoSize);
    if (!info) {
        // If there's no ObjC in an image, return true; if there really are
        // classes in the image anyway, we'll die with a pointer auth failure
        // later on.
        return true;
    }
    return info->shouldEnforceClassRoSigning();
}

static bool hasSignedClassROPointers(const header_info *hi) {
    return hasSignedClassROPointers(hi->mhdr(), hi->dyldInfo());
}

// Swift currently adds 4 callbacks.
struct loadImageCallback {
    union {
        objc_func_loadImage func;
        objc_func_loadImage2 func2;
    };
    uint8_t kind;
};
static GlobalSmallVector<loadImageCallback, 4> loadImageCallbacks;

void objc_addLoadImageFunc(objc_func_loadImage _Nonnull func) {
    // Not supported on the old runtime. Not that the old runtime is supported anyway.
    mutex_locker_t lock(runtimeLock);

    // Call it with all the existing images first.
    for (auto header = FirstHeader; header; header = header->getNext()) {
        func((struct mach_header *)header->mhdr());
    }

    // Add it to the vector for future loads.
    loadImageCallback callback = {
        .func = func,
        .kind = 1
    };
    loadImageCallbacks.append(callback);
}

void objc_addLoadImageFunc2(objc_func_loadImage2 _Nonnull func) {
    mutex_locker_t lock(runtimeLock);

    // Call it with all the existing images first.
    for (auto header = FirstHeader; header; header = header->getNext()) {
        func((const mach_header *)header->mhdr(), header->dyldInfo());
    }

    // Add it to the vector for future loads.
    loadImageCallback callback = {
        .func2 = func,
        .kind = 2,
    };
    loadImageCallbacks.append(callback);
}


/***********************************************************************
* map_images_nolock
* Process the given images which are being mapped in by dyld.
* All class registration and fixups are performed (or deferred pending
* discovery of missing superclasses etc), and +load methods are called.
*
* info[] is in bottom-up order i.e. libobjc will be earlier in the 
* array than any library that links to libobjc.
*
* Locking: loadMethodLock(old) or runtimeLock(new) acquired by map_images.
**********************************************************************/
#include "objc-file.h"

void 
map_images_nolock(unsigned mhCount, const struct _dyld_objc_notify_mapped_info infos[],
                  bool *disabledClassROEnforcement)
{
    static bool firstTime = YES;
    static bool executableHasClassROSigning = false;
    static bool executableIsARM64e = false;

    mapped_image_info mappedInfos[mhCount];
    uint32_t hCount;
    size_t selrefCount = 0;

    *disabledClassROEnforcement = false;

    // Perform first-time initialization if necessary.
    // This function is called before ordinary library initializers. 
    // fixme defer initialization until an objc-using image is found?
    if (firstTime) {
        preopt_init();
    } else {
        // If map_images is called twice in a row with no load_images in between
        // then we need to attach categories in that second map_images call.
        // Early code in places like libxpc is already using NSObject and has
        // probably caused its preattached categories to be copied, without this
        // new batch of images loaded. If we don't attach categories now, then
        // we'll skip scanning the categories in the new batch of images,
        // resulting in missing methods. An example problematic scenario:
        //
        // 1. map_images for a handful of low-level dylibs.
        // 2. libxpc initializes, triggers methodization of NSObject, copies
        //    NSObject's methods.
        // 3. CoreFoundation is loaded.
        // 4. map_images for CoreFoundation. Skip preattached categories.
        // 5. NSObject is missing CF category methods.
        //
        // By attaching categories now, we ensure that CF's preattached
        // categories are still scanned in this scenario.
        //
        // NOTE: this scenario is extremely uncommon and should never happen in
        // normal programs. It does happen in WINE, because WINE uses an old
        // x86-64 executable type that gives it control directly instead of
        // through dyld. It then calls dlopen which eventually triggers our
        // initializers. This causes map_images and load_images to happen in a
        // weird sequence, where we get map_images twice in a row.
        // rdar://109496408
        loadAllCategoriesIfNeeded();
    }

    if (PrintImages) {
        _objc_inform("IMAGES: processing %u newly-mapped images...\n", mhCount);
    }


    // Find all images with Objective-C metadata.
    hCount = 0;

    // Count classes. Size various table based on the total.
    int totalClasses = 0;
    int unoptimizedTotalClasses = 0;
    {
        uint32_t i = mhCount;
        while (i--) {
            const headerType *mhdr = (const headerType *)infos[i].mh;

            auto hi = addHeader(mhdr, infos[i].path, infos[i].sectionLocationMetadata,
                                totalClasses, unoptimizedTotalClasses);
            if (!hi) {
                // no objc data in this entry
                continue;
            }

            mapped_image_info mappedInfo{hi, infos[i]};

            if (mhdr->filetype == MH_EXECUTE) {
                // Size some data structures based on main executable's size

                // If dyld3 optimized the main executable, then there shouldn't
                // be any selrefs needed in the dynamic map so we can just init
                // to a 0 sized map
                if (mappedInfo.dyldObjCRefsOptimized()) {
                  size_t count;
                  hi->selrefs(&count);
                  selrefCount += count;
                  hi->messagerefs(&count);
                  selrefCount += count;
                }

#if SUPPORT_GC_COMPAT
                // Halt if this is a GC app.
                if (shouldRejectGCApp(hi)) {
                    _objc_fatal_with_reason
                        (OBJC_EXIT_REASON_GC_NOT_SUPPORTED, 
                         OS_REASON_FLAG_CONSISTENT_FAILURE, 
                         "Objective-C garbage collection " 
                         "is no longer supported.");
                }
#endif

                if (hasSignedClassROPointers(hi)) {
                    executableHasClassROSigning = true;
                }
            }

            mappedInfos[hCount++] = mappedInfo;

            if (PrintImages) {
                _objc_inform("IMAGES: loading image for %s%s%s%s\n",
                             hi->fname(),
                             mhdr->filetype == MH_BUNDLE ? " (bundle)" : "",
                             hi->info()->hasCategoryClassProperties() ? " (has class properties)" : "",
                             hi->info()->optimizedByDyld()?" (preoptimized)":"");
            }

            // dtrace probe
            OBJC_RUNTIME_LOAD_IMAGE(hi->fname(),
                                    mhdr->filetype == MH_BUNDLE,
                                    hi->info()->hasCategoryClassProperties(),
                                    hi->info()->optimizedByDyld());
        }
    }

    // Perform one-time runtime initialization that must be deferred until 
    // the executable itself is found. This needs to be done before 
    // further initialization.
    // (The executable may not be present in this infoList if the 
    // executable does not contain Objective-C code but Objective-C 
    // is dynamically loaded later.
    if (firstTime) {
        sel_init(selrefCount);
        arr_init();

#if SUPPORT_GC_COMPAT
        // Reject any GC images linked to the main executable.
        // We already rejected the app itself above.
        // Images loaded after launch will be rejected by dyld.

        for (uint32_t i = 0; i < hCount; i++) {
            auto hi = mappedInfos[i].hi;
            auto mh = hi->mhdr();
            if (mh->filetype != MH_EXECUTE  &&  shouldRejectGCImage(mh)) {
                _objc_fatal_with_reason
                    (OBJC_EXIT_REASON_GC_NOT_SUPPORTED, 
                     OS_REASON_FLAG_CONSISTENT_FAILURE, 
                     "%s requires Objective-C garbage collection "
                     "which is no longer supported.", hi->fname());
            }
        }
#endif

#if TARGET_OS_OSX
#   if !TARGET_OS_EXCLAVEKIT
        // Disable +initialize fork safety if the app is too old (< 10.13).
        // Disable +initialize fork safety if the app has a
        //   __DATA,__objc_fork_ok section.

        if (!true/*dyld_program_sdk_at_least(dyld_platform_version_macOS_10_13)*/) {
            DisableInitializeForkSafety = On;
            if (PrintInitializing) {
                _objc_inform("INITIALIZE: disabling +initialize fork "
                             "safety enforcement because the app is "
                             "too old.)");
            }
        }

        for (uint32_t i = 0; i < hCount; i++) {
            auto hi = mappedInfos[i].hi;
            auto mh = hi->mhdr();
            if (mh->filetype != MH_EXECUTE) continue;
            unsigned long size;
            if (hi->hasForkOkSection()) {
                DisableInitializeForkSafety = On;
                if (PrintInitializing) {
                    _objc_inform("INITIALIZE: disabling +initialize fork "
                                 "safety enforcement because the app has "
                                 "a __DATA,__objc_fork_ok section");
                }
            }
            break;  // assume only one MH_EXECUTE image
        }
#   endif // !TARGET_OS_EXCLAVEKIT
#endif // TARGET_OS_OSX

        // Check the main executable for ARM64e-ness. Note, we cannot
        // check the headers we get passed in for an MH_EXECUTABLE,
        // because dyld helpfully omits images that contain no ObjC,
        // and the main executable might not contain ObjC.
        const headerType *mainExecutableHeader = (headerType *)_dyld_get_prog_image_header();
        if (mainExecutableHeader
            && mainExecutableHeader->cputype == CPU_TYPE_ARM64
            && ((mainExecutableHeader->cpusubtype & ~CPU_SUBTYPE_MASK)
                == CPU_SUBTYPE_ARM64E)) {
            executableIsARM64e = true;
        }
    }

    // If the main executable is ARM64e, make sure every image that is loaded
    // has pointer signing turned on.
    if (executableIsARM64e) {
        bool shouldWarn = (executableHasClassROSigning
                           && DebugClassRXSigning);
        for (uint32_t i = 0; i < hCount; ++i) {
            auto hi = mappedInfos[i].hi;
            if (!hasSignedClassROPointers(hi)) {
                if (!objc::disableEnforceClassRXPtrAuth) {
                    *disabledClassROEnforcement = true;
                    objc::disableEnforceClassRXPtrAuth = 1;

                    // We *don't* want to log here, because that will give
                    // attackers an indication that they've managed to disable
                    // enforcement.

                    // Later, when we're really confident, we might be able to
                    // do this instead:
                    //
                    // _objc_fatal_with_reason
                    //     (OBJC_EXIT_REASON_CLASS_RO_SIGNING_REQUIRED,
                    //      OS_REASON_FLAG_CONSISTENT_FAILURE,
                    //      "%s was built without class_ro_t pointer signing",
                    //      hi->fname());
                }

                if (shouldWarn) {
                    _objc_inform("%s has un-signed class_ro_t pointers, but the "
                                 "main executable was compiled with class_ro_t "
                                 "pointer signing enabled", hi->fname());
                }
            }
        }
    }

    if (hCount > 0) {
        _read_images(mappedInfos, hCount, totalClasses, unoptimizedTotalClasses);
    }

    firstTime = NO;

    // Call image load funcs after everything is set up.
    for (auto callback : loadImageCallbacks) {
        for (uint32_t i = 0; i < mhCount; i++) {
            switch (callback.kind) {
                case 1:
                    callback.func(infos[i].mh);
                    break;
                case 2:
                    callback.func2(infos[i].mh, infos[i].sectionLocationMetadata);
                    break;
                default:
                    _objc_fatal("Corrupt load image callback, unknown kind %u, func %p", callback.kind, callback.func);
            }
        }
    }
}


/***********************************************************************
* unmap_image_nolock
* Process the given image which is about to be unmapped by dyld.
* mh is mach_header instead of headerType because that's what
*   dyld_priv.h says even for 64-bit.
*
* Locking: loadMethodLock(both) and runtimeLock(new) acquired by unmap_image.
**********************************************************************/
void
unmap_image_nolock(const struct mach_header *mh)
{
    if (PrintImages) {
        _objc_inform("IMAGES: processing 1 newly-unmapped image...\n");
    }

    header_info *hi;

    // Find the runtime's header_info struct for the image
    for (hi = FirstHeader; hi != NULL; hi = hi->getNext()) {
        if (hi->mhdr() == (const headerType *)mh) {
            break;
        }
    }

    if (!hi) return;

    if (PrintImages) {
        _objc_inform("IMAGES: unloading image for %s%s\n",
                     hi->fname(),
                     hi->mhdr()->filetype == MH_BUNDLE ? " (bundle)" : "");
    }

    _unload_image(hi);

    // Remove header_info from header list
    removeHeader(hi);
    free(hi);
}


/***********************************************************************
* patch_root_of_class_nolock
* Patches the given class passed from dyld.
* The body of originalClass will be replaced by the equivalent fields from replacementClass
*
* Locking: untimeLock(new) acquired by patch_root_of_class.
**********************************************************************/
static void
patch_root_of_class_nolock(const struct mach_header *originalMH, void* originalClass,
                   const struct mach_header *replacementMH, const void* replacementClass)
{
    Class originalCls = (Class)originalClass;
    Class replacementCls = (Class)replacementClass;

    if (PrintConnecting) {
        _objc_inform("CLASS: patching class '%s' (%p) to point to body of %p",
                     originalCls->nameForLogging(), originalCls, replacementClass);
    }

    // dyld should never pass Swift classes
    ASSERT(!originalCls->isAnySwift());
    ASSERT(!replacementCls->isAnySwift());

    // This should never be called on a realized class.
    ASSERT(!originalCls->isRealized());
    ASSERT(!replacementCls->isRealized());

    originalCls->initIsa(replacementCls->getIsa());
    originalCls->setSuperclass(replacementCls->getSuperclass());
    originalCls->cache.initializeToEmpty();

    bool authRO = hasSignedClassROPointers((const headerType *)replacementMH, nullptr);
    originalCls->bits.copyROFrom(replacementCls->bits, authRO);
}


/***********************************************************************
* _objc_patch_root_of_class
* Patches the given class passed from dyld.
* The body of originalClass will be replaced by the equivalent fields from replacementClass
*
* Locking: write-locks runtimeLock
**********************************************************************/
void
_objc_patch_root_of_class(const struct mach_header *originalMH, void* originalClass,
                          const struct mach_header *replacementMH, const void* replacementClass)
{
    mutex_locker_t lock(runtimeLock);
    return patch_root_of_class_nolock(originalMH, originalClass, replacementMH, replacementClass);
}

// FIXME: rdar://29241917&33734254 clang doesn't sign static initializers.
struct UnsignedInitializer {
private:
    uintptr_t storage;
public:
    UnsignedInitializer(uint32_t offset) {
#if TARGET_OS_EXCLAVEKIT
        extern const struct mach_header_64 _mh_dylib_header;
#endif
        storage = (uintptr_t)&_mh_dylib_header + offset;
    }

    void operator () () const {
        using Initializer = void(*)();
        // Note: we use a hardcoded 0 discriminator even with
        // ptrauth_function_pointer_type_discrimination, as non-function types
        // storing function pointers are always signed with a 0 discriminator.
        Initializer init = (Initializer)ptrauth_sign_unauthenticated((void *)storage,
                                                                     ptrauth_key_function_pointer, 0);
        init();
    }
};

static const uint32_t *getLibobjcInitializerOffsets(size_t *outCount) {
    extern const uint32_t sectionStart  __asm("section$start$__TEXT$__init_offsets");
    extern const uint32_t sectionEnd  __asm("section$end$__TEXT$__init_offsets");
    *outCount = &sectionEnd - &sectionStart;
    return &sectionStart;
}


/***********************************************************************
* static_init
* Run C++ static constructor functions.
* libc calls _objc_init() before dyld would call our static constructors, 
* so we have to do it ourselves.
**********************************************************************/
__attribute__((noinline))
static void static_init()
{
    size_t count;
    auto offsets = getLibobjcInitializerOffsets(&count);
    for (size_t i = 0; i < count; i++) {
        UnsignedInitializer init(offsets[i]);
        init();
    }
#if DEBUG
    if (count == 0)
        _objc_inform("No static initializers found in libobjc. This is unexpected for a debug build. Make sure the 'markgc' build phase ran on this dylib. This process is probably going to crash momentarily due to using uninitialized global data.");
#endif
}


/***********************************************************************
* _objc_atfork_prepare
* _objc_atfork_parent
* _objc_atfork_child
* Allow ObjC to be used between fork() and exec().
* libc requires this because it has fork-safe functions that use os_objects.
*
* _objc_atfork_prepare() acquires all locks.
* _objc_atfork_parent() releases the locks again.
* _objc_atfork_child() forcibly resets the locks.
**********************************************************************/

// Declare lock ordering.
#if LOCKDEBUG
__attribute__((constructor))
static void defineLockOrder()
{
    // Every lock precedes crashlog_lock
    // on the assumption that fatal errors could be anywhere.
    lockdebug::lock_precedes_lock(&loadMethodLock, &crashlog_lock);
    lockdebug::lock_precedes_lock(&classInitLock, &crashlog_lock);
    lockdebug::lock_precedes_lock(&pendingInitializeMapLock, &crashlog_lock);
    lockdebug::lock_precedes_lock(&runtimeLock, &crashlog_lock);
    lockdebug::lock_precedes_lock(&DemangleCacheLock, &crashlog_lock);
    lockdebug::lock_precedes_lock(&selLock, &crashlog_lock);
#if CONFIG_USE_CACHE_LOCK
    lockdebug::lock_precedes_lock(&cacheUpdateLock, &crashlog_lock);
#endif
    lockdebug::lock_precedes_lock(&objcMsgLogLock, &crashlog_lock);
    lockdebug::lock_precedes_lock(&AltHandlerDebugLock, &crashlog_lock);
    lockdebug::lock_precedes_lock(&AssociationsManagerLock, &crashlog_lock);
    SideTableLocksPrecedeLock(&crashlog_lock);
    PropertyLocks.precedeLock(&crashlog_lock);
    StructLocks.precedeLock(&crashlog_lock);
    CppObjectLocks.precedeLock(&crashlog_lock);

    // loadMethodLock precedes everything
    // because it is held while +load methods run
    lockdebug::lock_precedes_lock(&loadMethodLock, &classInitLock);
    lockdebug::lock_precedes_lock(&loadMethodLock, &pendingInitializeMapLock);
    lockdebug::lock_precedes_lock(&loadMethodLock, &runtimeLock);
    lockdebug::lock_precedes_lock(&loadMethodLock, &DemangleCacheLock);
    lockdebug::lock_precedes_lock(&loadMethodLock, &selLock);
#if CONFIG_USE_CACHE_LOCK
    lockdebug::lock_precedes_lock(&loadMethodLock, &cacheUpdateLock);
#endif
    lockdebug::lock_precedes_lock(&loadMethodLock, &objcMsgLogLock);
    lockdebug::lock_precedes_lock(&loadMethodLock, &AltHandlerDebugLock);
    lockdebug::lock_precedes_lock(&loadMethodLock, &AssociationsManagerLock);
    SideTableLocksSucceedLock(&loadMethodLock);
    PropertyLocks.succeedLock(&loadMethodLock);
    StructLocks.succeedLock(&loadMethodLock);
    CppObjectLocks.succeedLock(&loadMethodLock);

    // PropertyLocks and CppObjectLocks and AssociationManagerLock 
    // precede everything because they are held while objc_retain() 
    // or C++ copy are called.
    // (StructLocks do not precede everything because it calls memmove only.)
    auto PropertyAndCppObjectAndAssocLocksPrecedeLock = [&](const void *lock) {
        PropertyLocks.precedeLock(lock);
        CppObjectLocks.precedeLock(lock);
        lockdebug::lock_precedes_lock(&AssociationsManagerLock, lock);
    };
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&runtimeLock);
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&DemangleCacheLock);
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&classInitLock);
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&selLock);
#if CONFIG_USE_CACHE_LOCK
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&cacheUpdateLock);
#endif
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&objcMsgLogLock);
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&AltHandlerDebugLock);

    SideTableLocksSucceedLocks(PropertyLocks);
    SideTableLocksSucceedLocks(CppObjectLocks);
    SideTableLocksSucceedLock(&AssociationsManagerLock);

    PropertyLocks.precedeLock(&AssociationsManagerLock);
    CppObjectLocks.precedeLock(&AssociationsManagerLock);

    lockdebug::lock_precedes_lock(&classInitLock, &runtimeLock);
    lockdebug::lock_precedes_lock(&pendingInitializeMapLock, &runtimeLock);

    // Runtime operations may occur inside SideTable locks
    // (such as storeWeak calling getMethodImplementation)
    SideTableLocksPrecedeLock(&runtimeLock);
    SideTableLocksPrecedeLock(&classInitLock);
    // Some operations may occur inside runtimeLock.
    lockdebug::lock_precedes_lock(&runtimeLock, &selLock);
#if CONFIG_USE_CACHE_LOCK
    lockdebug::lock_precedes_lock(&runtimeLock, &cacheUpdateLock);
#endif
    lockdebug::lock_precedes_lock(&runtimeLock, &DemangleCacheLock);

    // Striped locks use address order internally.
    SideTableDefineLockOrder();
    PropertyLocks.defineLockOrder();
    StructLocks.defineLockOrder();
    CppObjectLocks.defineLockOrder();
}
// LOCKDEBUG
#endif

static bool ForkIsMultithreaded;
void _objc_atfork_prepare()
{
    // Save threaded-ness for the child's use.
    ForkIsMultithreaded = objc_is_threaded();

    lockdebug::assert_no_locks_locked();
    lockdebug::set_in_fork_prepare(true);

    classInitializeAtforkPrepare();

    _objc_sync_lock_atfork_prepare();

    loadMethodLock.lock();
    PropertyLocks.lockAll();
    CppObjectLocks.lockAll();
    AssociationsManagerLock.lock();
    SideTableLockAll();
    classInitLock.lock();
    pendingInitializeMapLock.lock();
    runtimeLock.lock();
    DemangleCacheLock.lock();
    selLock.lock();
#if CONFIG_USE_CACHE_LOCK
    cacheUpdateLock.lock();
#endif
    objcMsgLogLock.lock();
    AltHandlerDebugLock.lock();
    StructLocks.lockAll();
    crashlog_lock.lock();

    lockdebug::assert_all_locks_locked();
    lockdebug::set_in_fork_prepare(false);
}

void _objc_atfork_parent()
{
    lockdebug::assert_all_locks_locked();

    CppObjectLocks.unlockAll();
    StructLocks.unlockAll();
    PropertyLocks.unlockAll();
    AssociationsManagerLock.unlock();
    AltHandlerDebugLock.unlock();
    objcMsgLogLock.unlock();
    crashlog_lock.unlock();
    loadMethodLock.unlock();
#if CONFIG_USE_CACHE_LOCK
    cacheUpdateLock.unlock();
#endif
    selLock.unlock();
    SideTableUnlockAll();
    DemangleCacheLock.unlock();
    runtimeLock.unlock();
    classInitLock.unlock();
    pendingInitializeMapLock.unlock();

    _objc_sync_lock_atfork_parent();

    classInitializeAtforkParent();

    lockdebug::assert_no_locks_locked();
}

void _objc_atfork_child()
{
    // Turn on +initialize fork safety enforcement if applicable.
    if (ForkIsMultithreaded  &&  !DisableInitializeForkSafety) {
        MultithreadedForkChild = true;
    }

    lockdebug::assert_all_locks_locked();

    CppObjectLocks.forceResetAll();
    StructLocks.forceResetAll();
    PropertyLocks.forceResetAll();
    AssociationsManagerLock.reset();
    AltHandlerDebugLock.reset();
    objcMsgLogLock.reset();
    crashlog_lock.reset();
    loadMethodLock.reset();
#if CONFIG_USE_CACHE_LOCK
    cacheUpdateLock.forceReset();
#endif
    selLock.reset();
    SideTableForceResetAll();
    DemangleCacheLock.reset();
    runtimeLock.reset();
    classInitLock.reset();
    pendingInitializeMapLock.reset();

    _objc_sync_lock_atfork_child();

    classInitializeAtforkChild();

    lockdebug::assert_no_locks_locked();
}


/***********************************************************************
* _objc_init
* Bootstrap initialization. Registers our image notifier with dyld.
* Called by libSystem BEFORE library initialization time
**********************************************************************/

void _objc_init(void)
{
    static bool initialized = false;
    if (initialized) return;
    initialized = true;
    
    // fixme defer initialization until an objc-using image is found?
    environ_init();
    static_init();
    runtime_init();
    exception_init();
    cache_t::init();

#if !TARGET_OS_EXCLAVEKIT
    _imp_implementationWithBlock_init();
#endif

    _dyld_objc_callbacks_v2 callbacks = {
        2, // version
        &map_images,
        &load_images,
        unmap_image,
        _objc_patch_root_of_class
    };
    _dyld_objc_register_callbacks((_dyld_objc_callbacks*)&callbacks);

    didCallDyldNotifyRegister = true;
}


/***********************************************************************
* _headerForAddress.
* addr can be a class or a category
**********************************************************************/
static const header_info *_headerForAddress(void *addr)
{
    const char *segnames[] = { "__DATA", "__DATA_CONST", "__DATA_DIRTY", "__AUTH" };
    header_info *hi;

    for (hi = FirstHeader; hi != NULL; hi = hi->getNext()) {
        for (size_t i = 0; i < sizeof(segnames)/sizeof(segnames[0]); i++) {
            unsigned long seg_size;            
            uint8_t *seg = getsegmentdata(hi->mhdr(), segnames[i], &seg_size);
            if (!seg) continue;
            
            // Is the class in this header?
            if ((uint8_t *)addr >= seg  &&  (uint8_t *)addr < seg + seg_size) {
                return hi;
            }
        }
    }

    // Not found
    return 0;
}


/***********************************************************************
* _headerForClass
* Return the image header containing this class, or NULL.
* Returns NULL on runtime-constructed classes, and the NSCF classes.
**********************************************************************/
const header_info *_headerForClass(Class cls)
{
    return _headerForAddress(cls);
}


#if SUPPORT_MESSAGE_LOGGING
/**********************************************************************
* secure_open
* Securely open a file from a world-writable directory (like /tmp)
* If the file does not exist, it will be atomically created with mode 0600
* If the file exists, it must be, and remain after opening: 
*   1. a regular file (in particular, not a symlink)
*   2. owned by euid
*   3. permissions 0600
*   4. link count == 1
* Returns a file descriptor or -1. Errno may or may not be set on error.
**********************************************************************/
int secure_open(const char *filename, int flags, uid_t euid)
{
    struct stat fs, ls;
    int fd = -1;
    bool truncate = NO;
    bool create = NO;

    if (flags & O_TRUNC) {
        // Don't truncate the file until after it is open and verified.
        truncate = YES;
        flags &= ~O_TRUNC;
    }
    if (flags & O_CREAT) {
        // Don't create except when we're ready for it
        create = YES;
        flags &= ~O_CREAT;
        flags &= ~O_EXCL;
    }

    if (lstat(filename, &ls) < 0) {
        if (errno == ENOENT  &&  create) {
            // No such file - create it
            fd = open(filename, flags | O_CREAT | O_EXCL, 0600);
            if (fd >= 0) {
                // File was created successfully.
                // New file does not need to be truncated.
                return fd;
            } else {
                // File creation failed.
                return -1;
            }
        } else {
            // lstat failed, or user doesn't want to create the file
            return -1;
        }
    } else {
        // lstat succeeded - verify attributes and open
        if (S_ISREG(ls.st_mode)  &&  // regular file?
            ls.st_nlink == 1  &&     // link count == 1?
            ls.st_uid == euid  &&    // owned by euid?
            (ls.st_mode & ALLPERMS) == (S_IRUSR | S_IWUSR))  // mode 0600?
        {
            // Attributes look ok - open it and check attributes again
            fd = open(filename, flags, 0000);
            if (fd >= 0) {
                // File is open - double-check attributes
                if (0 == fstat(fd, &fs)  &&  
                    fs.st_nlink == ls.st_nlink  &&  // link count == 1?
                    fs.st_uid == ls.st_uid  &&      // owned by euid?
                    fs.st_mode == ls.st_mode  &&    // regular file, 0600?
                    fs.st_ino == ls.st_ino  &&      // same inode as before?
                    fs.st_dev == ls.st_dev)         // same device as before?
                {
                    // File is open and OK
                    if (truncate) ftruncate(fd, 0);
                    return fd;
                } else {
                    // Opened file looks funny - close it
                    close(fd);
                    return -1;
                }
            } else {
                // File didn't open
                return -1;
            }
        } else {
            // Unopened file looks funny - don't open it
            return -1;
        }
    }
}
#endif // SUPPORT_MESSAGE_LOGGING

#if TARGET_OS_IPHONE

const char *__crashreporter_info__ = NULL;

const char *CRSetCrashLogMessage(const char *msg)
{
    __crashreporter_info__ = msg;
    return msg;
}
const char *CRGetCrashLogMessage(void)
{
    return __crashreporter_info__;
}

#endif

// TARGET_OS_MAC
#else


#error unknown OS


#endif


// Implement (v)asprintf() for those systems that don't have it
#if !HAVE_ASPRINTF
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wformat-nonliteral"
int
_objc_vasprintf(char **strp, const char *fmt, va_list args) {
  va_list args_for_len;
  va_copy(args_for_len, args);
  int len = vsnprintf(nullptr, 0, fmt, args_for_len);
  va_end(args_for_len);

  // If we fail for any reason, strp needs to be set to NULL.
  *strp = nullptr;

  if (len < 0)
    return -1;
  char *buffer = reinterpret_cast<char *>(malloc(len + 1));
  if (!buffer)
    return -1;
  int result = vsnprintf(buffer, len + 1, fmt, args);
  if (result < 0) {
    free(buffer);
    return -1;
  }
  *strp = buffer;
  return result;
}

int
_objc_asprintf(char **strp, const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  int result = _objc_vasprintf(strp, fmt, args);
  va_end(args);
  return result;
}
#pragma clang diagnostic pop

#endif // !HAVE_ASPRINTF
