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
/***********************************************************************
* objc-runtime.m
* Copyright 1988-1996, NeXT Software, Inc.
* Author:	s. naroff
*
**********************************************************************/



/***********************************************************************
* Imports.
**********************************************************************/

#include "objc-private.h"
#include "objc-loadmethod.h"
#include "message.h"

OBJC_EXPORT Class getOriginalClassForPosingClass(Class);


/***********************************************************************
* Exports.
**********************************************************************/

// Settings from environment variables
#if SUPPORT_ENVIRON
int PrintImages = -1;     // env OBJC_PRINT_IMAGES
int PrintLoading = -1;    // env OBJC_PRINT_LOAD_METHODS
int PrintInitializing = -1; // env OBJC_PRINT_INITIALIZE_METHODS
int PrintResolving = -1;  // env OBJC_PRINT_RESOLVED_METHODS
int PrintConnecting = -1; // env OBJC_PRINT_CLASS_SETUP
int PrintProtocols = -1;  // env OBJC_PRINT_PROTOCOL_SETUP
int PrintIvars = -1;      // env OBJC_PRINT_IVAR_SETUP
int PrintVtables = -1;    // env OBJC_PRINT_VTABLE_SETUP
int PrintVtableImages = -1;//env OBJC_PRINT_VTABLE_IMAGES
int PrintFuture = -1;     // env OBJC_PRINT_FUTURE_CLASSES
int PrintGC = -1;         // env OBJC_PRINT_GC
int PrintPreopt = -1;     // env OBJC_PRINT_PREOPTIMIZATION
int PrintCxxCtors = -1;   // env OBJC_PRINT_CXX_CTORS
int PrintExceptions = -1; // env OBJC_PRINT_EXCEPTIONS
int PrintExceptionThrow = -1; // env OBJC_PRINT_EXCEPTION_THROW
int PrintAltHandlers = -1; // env OBJC_PRINT_ALT_HANDLERS
int PrintDeprecation = -1;// env OBJC_PRINT_DEPRECATION_WARNINGS
int PrintReplacedMethods = -1; // env OBJC_PRINT_REPLACED_METHODS
int PrintCaches = -1;     // env OBJC_PRINT_CACHE_SETUP
int PrintPoolHiwat = -1;  // env OBJC_PRINT_POOL_HIGHWATER
int PrintCustomRR = -1;   // env OBJC_PRINT_CUSTOM_RR
int PrintCustomAWZ = -1;  // env OBJC_PRINT_CUSTOM_AWZ

int UseInternalZone = -1; // env OBJC_USE_INTERNAL_ZONE

int DebugUnload = -1;     // env OBJC_DEBUG_UNLOAD
int DebugFragileSuperclasses = -1; // env OBJC_DEBUG_FRAGILE_SUPERCLASSES
int DebugNilSync = -1;    // env OBJC_DEBUG_NIL_SYNC
int DebugNonFragileIvars = -1; // env OBJC_DEBUG_NONFRAGILE_IVARS
int DebugAltHandlers = -1;// env OBJC_DEBUG_ALT_HANDLERS

int DisableGC = -1;       // env OBJC_DISABLE_GC
int DisableVtables = -1;  // env OBJC_DISABLE_VTABLES
int DisablePreopt = -1;   // env OBJC_DISABLE_PREOPTIMIZATION
int DebugFinalizers = -1; // env OBJC_DEBUG_FINALIZERS
#endif


// objc's key for pthread_getspecific
static tls_key_t _objc_pthread_key;

// Selectors
SEL SEL_load = NULL;
SEL SEL_initialize = NULL;
SEL SEL_resolveInstanceMethod = NULL;
SEL SEL_resolveClassMethod = NULL;
SEL SEL_cxx_construct = NULL;
SEL SEL_cxx_destruct = NULL;
SEL SEL_retain = NULL;
SEL SEL_release = NULL;
SEL SEL_autorelease = NULL;
SEL SEL_retainCount = NULL;
SEL SEL_alloc = NULL;
SEL SEL_allocWithZone = NULL;
SEL SEL_copy = NULL;
SEL SEL_new = NULL;
SEL SEL_finalize = NULL;
SEL SEL_forwardInvocation = NULL;

header_info *FirstHeader = 0;  // NULL means empty list
header_info *LastHeader  = 0;  // NULL means invalid; recompute it
int HeaderCount = 0;



/***********************************************************************
* objc_getClass.  Return the id of the named class.  If the class does
* not exist, call _objc_classLoader and then objc_classHandler, either of 
* which may create a new class.
* Warning: doesn't work if aClassName is the name of a posed-for class's isa!
**********************************************************************/
id objc_getClass(const char *aClassName)
{
    if (!aClassName) return Nil;

    // NO unconnected, YES class handler
    return look_up_class(aClassName, NO, YES);
}


/***********************************************************************
* objc_getRequiredClass.  
* Same as objc_getClass, but kills the process if the class is not found. 
* This is used by ZeroLink, where failing to find a class would be a 
* compile-time link error without ZeroLink.
**********************************************************************/
id objc_getRequiredClass(const char *aClassName)
{
    id cls = objc_getClass(aClassName);
    if (!cls) _objc_fatal("link error: class '%s' not found.", aClassName);
    return cls;
}


/***********************************************************************
* objc_lookUpClass.  Return the id of the named class.
* If the class does not exist, call _objc_classLoader, which may create 
* a new class.
*
* Formerly objc_getClassWithoutWarning ()
**********************************************************************/
id objc_lookUpClass(const char *aClassName)
{
    if (!aClassName) return Nil;

    // NO unconnected, NO class handler
    return look_up_class(aClassName, NO, NO);
}

/***********************************************************************
* objc_getFutureClass.  Return the id of the named class.
* If the class does not exist, return an uninitialized class 
* structure that will be used for the class when and if it 
* does get loaded.
* Not thread safe. 
**********************************************************************/
Class objc_getFutureClass(const char *name)
{
    Class cls;

    // YES unconnected, NO class handler
    // (unconnected is OK because it will someday be the real class)
    cls = (Class)look_up_class(name, YES, NO);
    if (cls) {
        if (PrintFuture) {
            _objc_inform("FUTURE: found %p already in use for %s", cls, name);
        }
        return cls;
    }
    
    // No class or future class with that name yet. Make one.
    // fixme not thread-safe with respect to 
    // simultaneous library load or getFutureClass.
    return _objc_allocateFutureClass(name);
}


/***********************************************************************
* objc_getMetaClass.  Return the id of the meta class the named class.
* Warning: doesn't work if aClassName is the name of a posed-for class's isa!
**********************************************************************/
id objc_getMetaClass(const char *aClassName)
{
    Class cls;

    if (!aClassName) return Nil;

    cls = (Class)objc_getClass (aClassName);
    if (!cls)
    {
        _objc_inform ("class `%s' not linked into application", aClassName);
        return Nil;
    }

    return (id)cls->isa;
}


/***********************************************************************
* appendHeader.  Add a newly-constructed header_info to the list. 
**********************************************************************/
void appendHeader(header_info *hi)
{
    // Add the header to the header list. 
    // The header is appended to the list, to preserve the bottom-up order.
    HeaderCount++;
    hi->next = NULL;
    if (!FirstHeader) {
        // list is empty
        FirstHeader = LastHeader = hi;
    } else {
        if (!LastHeader) {
            // list is not empty, but LastHeader is invalid - recompute it
            LastHeader = FirstHeader;
            while (LastHeader->next) LastHeader = LastHeader->next;
        }
        // LastHeader is now valid
        LastHeader->next = hi;
        LastHeader = hi;
    }
}


/***********************************************************************
* removeHeader
* Remove the given header from the header list.
* FirstHeader is updated. 
* LastHeader is set to NULL. Any code that uses LastHeader must 
* detect this NULL and recompute LastHeader by traversing the list.
**********************************************************************/
void removeHeader(header_info *hi)
{
    header_info **hiP;

    for (hiP = &FirstHeader; *hiP != NULL; hiP = &(**hiP).next) {
        if (*hiP == hi) {
            header_info *deadHead = *hiP;

            // Remove from the linked list (updating FirstHeader if necessary).
            *hiP = (**hiP).next;
            
            // Update LastHeader if necessary.
            if (LastHeader == deadHead) {
                LastHeader = NULL;  // will be recomputed next time it's used
            }

            HeaderCount--;
            break;
        }
    }
}


/***********************************************************************
* environ_init
* Read environment variables that affect the runtime.
* Also print environment variable help, if requested.
**********************************************************************/
void environ_init(void) 
{
#if SUPPORT_ENVIRON
    int PrintHelp = (getenv("OBJC_HELP") != NULL);
    int PrintOptions = (getenv("OBJC_PRINT_OPTIONS") != NULL);
    int secure = issetugid();

    if (secure) {
        // All environment variables are ignored when setuid or setgid.
        // This includes OBJC_HELP and OBJC_PRINT_OPTIONS themselves.
    } 
    else {
        if (PrintHelp) {
            _objc_inform("Objective-C runtime debugging. Set variable=YES to enable.");
            _objc_inform("OBJC_HELP: describe available environment variables");
            if (PrintOptions) {
                _objc_inform("OBJC_HELP is set");
            }
            _objc_inform("OBJC_PRINT_OPTIONS: list which options are set");
        }
        if (PrintOptions) {
            _objc_inform("OBJC_PRINT_OPTIONS is set");
        }
    }
    
#define OPTION(var, env, help) \
    if ( var == -1 ) { \
        char *value = getenv(#env); \
        var = value != NULL && !strcmp("YES", value); \
        if (secure) { \
            if (var) _objc_inform(#env " ignored when running setuid or setgid"); \
            var = 0; \
        } else { \
            if (PrintHelp) _objc_inform(#env ": " help); \
            if (PrintOptions && var) _objc_inform(#env " is set"); \
        } \
    }
    
    OPTION(PrintImages, OBJC_PRINT_IMAGES,
           "log image and library names as they are loaded");
    OPTION(PrintLoading, OBJC_PRINT_LOAD_METHODS,
           "log calls to class and category +load methods");
    OPTION(PrintInitializing, OBJC_PRINT_INITIALIZE_METHODS,
           "log calls to class +initialize methods");
    OPTION(PrintResolving, OBJC_PRINT_RESOLVED_METHODS,
           "log methods created by +resolveClassMethod: and +resolveInstanceMethod:");
    OPTION(PrintConnecting, OBJC_PRINT_CLASS_SETUP,
           "log progress of class and category setup");
    OPTION(PrintProtocols, OBJC_PRINT_PROTOCOL_SETUP,
           "log progress of protocol setup");
    OPTION(PrintIvars, OBJC_PRINT_IVAR_SETUP,
           "log processing of non-fragile ivars");
    OPTION(PrintVtables, OBJC_PRINT_VTABLE_SETUP,
           "log processing of class vtables");
    OPTION(PrintVtableImages, OBJC_PRINT_VTABLE_IMAGES,
           "print vtable images showing overridden methods");
    OPTION(PrintCaches, OBJC_PRINT_CACHE_SETUP, 
           "log processing of method caches");
    OPTION(PrintFuture, OBJC_PRINT_FUTURE_CLASSES, 
           "log use of future classes for toll-free bridging");
    OPTION(PrintGC, OBJC_PRINT_GC,
           "log some GC operations");
    OPTION(PrintPreopt, OBJC_PRINT_PREOPTIMIZATION,
           "log preoptimization courtesy of dyld shared cache");
    OPTION(PrintCxxCtors, OBJC_PRINT_CXX_CTORS, 
           "log calls to C++ ctors and dtors for instance variables");
    OPTION(PrintExceptions, OBJC_PRINT_EXCEPTIONS, 
           "log exception handling");
    OPTION(PrintExceptionThrow, OBJC_PRINT_EXCEPTION_THROW, 
           "log backtrace of every objc_exception_throw()");
    OPTION(PrintAltHandlers, OBJC_PRINT_ALT_HANDLERS, 
           "log processing of exception alt handlers");
    OPTION(PrintReplacedMethods, OBJC_PRINT_REPLACED_METHODS, 
           "log methods replaced by category implementations");
    OPTION(PrintDeprecation, OBJC_PRINT_DEPRECATION_WARNINGS, 
           "warn about calls to deprecated runtime functions");
    OPTION(PrintPoolHiwat, OBJC_PRINT_POOL_HIGHWATER, 
           "log high-water marks for autorelease pools");
    OPTION(PrintCustomRR, OBJC_PRINT_CUSTOM_RR, 
           "log classes with un-optimized custom retain/release methods");
    OPTION(PrintCustomAWZ, OBJC_PRINT_CUSTOM_AWZ, 
           "log classes with un-optimized custom allocWithZone methods");

    OPTION(DebugUnload, OBJC_DEBUG_UNLOAD,
           "warn about poorly-behaving bundles when unloaded");
    OPTION(DebugFragileSuperclasses, OBJC_DEBUG_FRAGILE_SUPERCLASSES, 
           "warn about subclasses that may have been broken by subsequent changes to superclasses");
    OPTION(DebugFinalizers, OBJC_DEBUG_FINALIZERS, 
           "warn about classes that implement -dealloc but not -finalize");
    OPTION(DebugNilSync, OBJC_DEBUG_NIL_SYNC, 
           "warn about @synchronized(nil), which does no synchronization");
    OPTION(DebugNonFragileIvars, OBJC_DEBUG_NONFRAGILE_IVARS, 
           "capriciously rearrange non-fragile ivars");
    OPTION(DebugAltHandlers, OBJC_DEBUG_ALT_HANDLERS, 
           "record more info about bad alt handler use");

    OPTION(UseInternalZone, OBJC_USE_INTERNAL_ZONE,
           "allocate runtime data in a dedicated malloc zone");

    OPTION(DisableGC, OBJC_DISABLE_GC,
           "force GC OFF, even if the executable wants it on");
    OPTION(DisableVtables, OBJC_DISABLE_VTABLES,
           "disable vtable dispatch");
    OPTION(DisablePreopt, OBJC_DISABLE_PREOPTIMIZATION,
           "disable preoptimization courtesy of dyld shared cache");

#undef OPTION
#endif
}


/***********************************************************************
* logReplacedMethod
* OBJC_PRINT_REPLACED_METHODS implementation
**********************************************************************/
void 
logReplacedMethod(const char *className, SEL s, 
                  BOOL isMeta, const char *catName, 
                  IMP oldImp, IMP newImp)
{
    const char *oldImage = "??";
    const char *newImage = "??";

    // Silently ignore +load replacement because category +load is special
    if (s == SEL_load) return;

#if TARGET_OS_WIN32
    // don't know dladdr()/dli_fname equivalent
#else
    Dl_info dl;

    if (dladdr((void*)oldImp, &dl)  &&  dl.dli_fname) oldImage = dl.dli_fname;
    if (dladdr((void*)newImp, &dl)  &&  dl.dli_fname) newImage = dl.dli_fname;
#endif
    
    _objc_inform("REPLACED: %c[%s %s]  %s%s  (IMP was %p (%s), now %p (%s))",
                 isMeta ? '+' : '-', className, sel_getName(s), 
                 catName ? "by category " : "", catName ? catName : "", 
                 oldImp, oldImage, newImp, newImage);
}



/***********************************************************************
* objc_setMultithreaded.
**********************************************************************/
void objc_setMultithreaded (BOOL flag)
{
    OBJC_WARN_DEPRECATED;

    // Nothing here. Thread synchronization in the runtime is always active.
}


/***********************************************************************
* _objc_fetch_pthread_data
* Fetch objc's pthread data for this thread.
* If the data doesn't exist yet and create is NO, return NULL.
* If the data doesn't exist yet and create is YES, allocate and return it.
**********************************************************************/
_objc_pthread_data *_objc_fetch_pthread_data(BOOL create)
{
    _objc_pthread_data *data;

    data = (_objc_pthread_data *)tls_get(_objc_pthread_key);
    if (!data  &&  create) {
        data = (_objc_pthread_data *)
            _calloc_internal(1, sizeof(_objc_pthread_data));
        tls_set(_objc_pthread_key, data);
    }

    return data;
}


/***********************************************************************
* _objc_pthread_destroyspecific
* Destructor for objc's per-thread data.
* arg shouldn't be NULL, but we check anyway.
**********************************************************************/
extern void _destroyInitializingClassList(struct _objc_initializing_classes *list);
void _objc_pthread_destroyspecific(void *arg)
{
    _objc_pthread_data *data = (_objc_pthread_data *)arg;
    if (data != NULL) {
        _destroyInitializingClassList(data->initializingClasses);
        _destroySyncCache(data->syncCache);
        _destroyAltHandlerList(data->handlerList);

        // add further cleanup here...

        _free_internal(data);
    }
}


void tls_init(void)
{
#if SUPPORT_DIRECT_THREAD_KEYS
    _objc_pthread_key = TLS_DIRECT_KEY;
    pthread_key_init_np(TLS_DIRECT_KEY, &_objc_pthread_destroyspecific);
#else
    _objc_pthread_key = tls_create(&_objc_pthread_destroyspecific);
#endif
}


/***********************************************************************
* _objcInit
* Former library initializer. This function is now merely a placeholder 
* for external callers. All runtime initialization has now been moved 
* to map_images() and _objc_init.
**********************************************************************/
void _objcInit(void)
{
    // do nothing
}


#if !(TARGET_OS_WIN32  ||  TARGET_OS_EMBEDDED  ||  TARGET_OS_IPHONE)
/***********************************************************************
* _objc_setNilReceiver
**********************************************************************/
id _objc_setNilReceiver(id newNilReceiver)
{
    id oldNilReceiver;

    oldNilReceiver = _objc_nilReceiver;
    _objc_nilReceiver = newNilReceiver;

    return oldNilReceiver;
}

/***********************************************************************
* _objc_getNilReceiver
**********************************************************************/
id _objc_getNilReceiver(void)
{
    return _objc_nilReceiver;
}
#endif


/***********************************************************************
* objc_setForwardHandler
**********************************************************************/
void objc_setForwardHandler(void *fwd, void *fwd_stret)
{
    _objc_forward_handler = fwd;
    _objc_forward_stret_handler = fwd_stret;
}


#if defined(__i386__) || defined(__x86_64__)

/**********************************************************************
* objc_branch_size
* Returns the number of BYTES needed 
* for a branch from entry to target. 
**********************************************************************/
size_t objc_branch_size(void *entry, void *target)
{
    return objc_cond_branch_size(entry, target, COND_ALWAYS);
}

size_t 
objc_cond_branch_size(void *entry, void *target, unsigned cond)
{
    // For simplicity, always use 32-bit relative jumps.
    if (cond == COND_ALWAYS) return 5;
    else return 6;
}

/**********************************************************************
* objc_write_branch
* Writes at entry an i386 branch instruction sequence that branches to target.
* The sequence written will be objc_branch_size(entry, target) BYTES.
* Returns the number of BYTES written.
**********************************************************************/
size_t objc_write_branch(void *entry, void *target) 
{
    return objc_write_cond_branch(entry, target, COND_ALWAYS);
}

size_t 
objc_write_cond_branch(void *entry, void *target, unsigned cond) 
{
    uint8_t *address = (uint8_t *)entry;  // instructions written to here
    intptr_t destination = (intptr_t)target;  // branch dest as absolute address
    intptr_t displacement = (intptr_t)destination - ((intptr_t)address + objc_cond_branch_size(entry, target, cond)); // branch dest as relative offset
    
    // For simplicity, always use 32-bit relative jumps
    if (cond != COND_ALWAYS) {
        *address++ = 0x0f;  // Jcc prefix
    }
    *address++ = cond;
    *address++ = displacement & 0xff;
    *address++ = (displacement >> 8) & 0xff;
    *address++ = (displacement >> 16) & 0xff;
    *address++ = (displacement >> 24) & 0xff;

    return address - (uint8_t *)entry;
}

// defined __i386__
#endif




#if !__OBJC2__
// GrP fixme
OBJC_EXTERN Class _objc_getOrigClass(const char *name);
#endif
const char *class_getImageName(Class cls)
{
#if TARGET_OS_WIN32
    TCHAR *szFileName;
    DWORD charactersCopied;
    Class origCls;
    HMODULE classModule;
    BOOL res;
#endif
    if (!cls) return NULL;

#if !__OBJC2__
    cls = _objc_getOrigClass(_class_getName(cls));
#endif
#if TARGET_OS_WIN32
	charactersCopied = 0;
	szFileName = malloc(MAX_PATH * sizeof(TCHAR));
	
	origCls = objc_getOrigClass(class_getName(cls));
	classModule = NULL;
	res = GetModuleHandleEx(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, (LPCTSTR)origCls, &classModule);
	if (res && classModule) {
	    charactersCopied = GetModuleFileName(classModule, szFileName, MAX_PATH * sizeof(TCHAR));
	}
	if (classModule) FreeLibrary(classModule);
	if (charactersCopied) {
		return (const char *)szFileName;
	} else 
		free(szFileName);
    return NULL;
#else
    return dyld_image_path_containing_address(cls);
#endif
}


const char **objc_copyImageNames(unsigned int *outCount)
{
    header_info *hi;
    int count = 0;
    int max = HeaderCount;
#if TARGET_OS_WIN32
    const TCHAR **names = (const TCHAR **)calloc(max+1, sizeof(TCHAR *));
#else
    const char **names = (const char **)calloc(max+1, sizeof(char *));
#endif
    
    for (hi = FirstHeader; hi != NULL && count < max; hi = hi->next) {
#if TARGET_OS_WIN32
        if (hi->moduleName) {
            names[count++] = hi->moduleName;
        }
#else
        if (hi->fname) {
            names[count++] = hi->fname;
        }
#endif
    }
    names[count] = NULL;
    
    if (count == 0) {
        // Return NULL instead of empty list if there are no images
        free((void *)names);
        names = NULL;
    }

    if (outCount) *outCount = count;
    return names;
}


/**********************************************************************
*
**********************************************************************/
const char ** 
objc_copyClassNamesForImage(const char *image, unsigned int *outCount)
{
    header_info *hi;

    if (!image) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    // Find the image.
    for (hi = FirstHeader; hi != NULL; hi = hi->next) {
#if TARGET_OS_WIN32
        if (0 == wcscmp((TCHAR *)image, hi->moduleName)) break;
#else
        if (0 == strcmp(image, hi->fname)) break;
#endif
    }
    
    if (!hi) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    return _objc_copyClassNamesForImage(hi, outCount);
}
	

/**********************************************************************
* Fast Enumeration Support
**********************************************************************/

static void (*enumerationMutationHandler)(id);

/**********************************************************************
* objc_enumerationMutation
* called by compiler when a mutation is detected during foreach iteration
**********************************************************************/
void objc_enumerationMutation(id object) {
    if (enumerationMutationHandler == nil) {
        _objc_fatal("mutation detected during 'for(... in ...)'  enumeration of object %p.", object);
    }
    (*enumerationMutationHandler)(object);
}


/**********************************************************************
* objc_setEnumerationMutationHandler
* an entry point to customize mutation error handing
**********************************************************************/
void objc_setEnumerationMutationHandler(void (*handler)(id)) {
    enumerationMutationHandler = handler;
}


/**********************************************************************
* Associative Reference Support
**********************************************************************/

#if SUPPORT_GC
id objc_getAssociatedObject_gc(id object, const void *key) {
    return (id)auto_zone_get_associative_ref(gc_zone, object, (void *)key);
}
#endif

id objc_getAssociatedObject_non_gc(id object, const void *key) {
    return _object_get_associative_reference(object, (void *)key);
}

id objc_getAssociatedObject(id object, const void *key) {
#if SUPPORT_GC
    if (UseGC) {
        return (id)auto_zone_get_associative_ref(gc_zone, object, (void *)key);
    } else 
#endif
    {
        return _object_get_associative_reference(object, (void *)key);
    }
}

#if SUPPORT_GC
void objc_setAssociatedObject_gc(id object, const void *key, id value, objc_AssociationPolicy policy) {
    if ((policy & OBJC_ASSOCIATION_COPY_NONATOMIC) == OBJC_ASSOCIATION_COPY_NONATOMIC) {
        value = ((id(*)(id, SEL))objc_msgSend)(value, SEL_copy);
    }
    auto_zone_set_associative_ref(gc_zone, object, (void *)key, value);
}
#endif

void objc_setAssociatedObject_non_gc(id object, const void *key, id value, objc_AssociationPolicy policy) {
    _object_set_associative_reference(object, (void *)key, value, policy);
}

void objc_setAssociatedObject(id object, const void *key, id value, objc_AssociationPolicy policy) {
#if SUPPORT_GC
    if (UseGC) {
        if ((policy & OBJC_ASSOCIATION_COPY_NONATOMIC) == OBJC_ASSOCIATION_COPY_NONATOMIC) {
            value = ((id(*)(id, SEL))objc_msgSend)(value, SEL_copy);
        }
        auto_zone_set_associative_ref(gc_zone, object, (void *)key, value);
    } else 
#endif
    {
        // Note, creates a retained reference in non-GC.
        _object_set_associative_reference(object, (void *)key, value, policy);
    }
}

void objc_removeAssociatedObjects(id object) {
#if SUPPORT_GC
    if (UseGC) {
        auto_zone_erase_associative_refs(gc_zone, object);
    } else 
#endif
    {
        if (_class_instancesHaveAssociatedObjects(_object_getClass(object))) _object_remove_assocations(object);
    }
}

BOOL class_instancesHaveAssociatedObjects(Class cls) {
    return _class_instancesHaveAssociatedObjects(cls);
}


/**********************************************************************
* Debugger mode
*
* Debugger mode is used when gdb wants to call runtime functions 
* and other methods while other threads are stopped. The runtime 
* provides best-effort functionality while avoiding deadlocks 
* with the stopped threads. gdb is responsible for ensuring that all 
* threads but one stay stopped.
*
* When debugger mode starts, the runtime acquires as many locks as 
* it can. Any locks that can't be acquired are off-limits until 
* debugger mode ends. The locking functions in objc-os.h check each 
* operation and halt if a disallowed lock is used; gdb catches that 
* trap and cleans up.
*
* Each ABI is responsible for tracking its locks. Any lock not 
* handled there is a potential gdb deadlock.
**********************************************************************/

#if SUPPORT_DEBUGGER_MODE

int DebuggerMode = DEBUGGER_OFF;
objc_thread_t DebuggerModeThread = 0;
static int DebuggerModeCount;

/**********************************************************************
* gdb_objc_startDebuggerMode
* Start debugger mode by taking locks. Return 0 if not enough locks 
* could be acquired.
**********************************************************************/
int gdb_objc_startDebuggerMode(uint32_t flags)
{
    BOOL wantFull = flags & OBJC_DEBUGMODE_FULL;
    if (! DebuggerMode) {
        // Start debugger mode
        int mode = startDebuggerMode();  // Do this FIRST
        if (mode == DEBUGGER_OFF) {
            // sorry
            return 0;
        }
        else if (mode == DEBUGGER_PARTIAL  &&  wantFull) {
            // not good enough
            endDebuggerMode();
            return 0;
        }
        else {
            // w00t
            DebuggerMode = mode;
            DebuggerModeCount = 1;
            DebuggerModeThread = thread_self();
            return 1;
        }
    } 
    else if (DebuggerMode == DEBUGGER_PARTIAL  &&  wantFull) {
        // Debugger mode already active, but not as requested - sorry
        return 0;
    } 
    else {
        // Debugger mode already active as requested
        if (thread_self() == DebuggerModeThread) {
            DebuggerModeCount++;
            return 1;
        } else {
            _objc_inform("DEBUGGER MODE: debugger is buggy: can't run "
                         "debugger mode from two threads!");
            return 0;
        }
    }
}


/**********************************************************************
* gdb_objc_endDebuggerMode
* Relinquish locks and end debugger mode.
**********************************************************************/
void gdb_objc_endDebuggerMode(void)
{
    if (DebuggerMode  &&  thread_self() == DebuggerModeThread) {
        if (--DebuggerModeCount == 0) {
            DebuggerMode = NO;
            DebuggerModeThread = 0;
            endDebuggerMode();  // Do this LAST
        }
    } else {
        _objc_inform("DEBUGGER MODE: debugger is buggy: debugger mode "
                     "not active for this thread!");
    }
}


/**********************************************************************
* gdb_objc_debuggerModeFailure
* Breakpoint hook for gdb when debugger mode can't finish something
**********************************************************************/
void gdb_objc_debuggerModeFailure(void)
{
    _objc_fatal("DEBUGGER MODE: failed");
}

// SUPPORT_DEBUGGER_MODE
#endif
