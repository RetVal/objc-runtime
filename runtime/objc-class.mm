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
*	objc-class.m
*	Copyright 1988-1997, Apple Computer, Inc.
*	Author:	s. naroff
**********************************************************************/


/***********************************************************************
 * Lazy method list arrays and method list locking  (2004-10-19)
 * 
 * cls->methodLists may be in one of three forms:
 * 1. NULL: The class has no methods.
 * 2. non-NULL, with CLS_NO_METHOD_ARRAY set: cls->methodLists points 
 *    to a single method list, which is the class's only method list.
 * 3. non-NULL, with CLS_NO_METHOD_ARRAY clear: cls->methodLists points to 
 *    an array of method list pointers. The end of the array's block 
 *    is set to -1. If the actual number of method lists is smaller 
 *    than that, the rest of the array is NULL.
 * 
 * Attaching categories and adding and removing classes may change 
 * the form of the class list. In addition, individual method lists 
 * may be reallocated when fixed up.
 *
 * Classes are initially read as #1 or #2. If a category is attached 
 * or other methods added, the class is changed to #3. Once in form #3, 
 * the class is never downgraded to #1 or #2, even if methods are removed.
 * Classes added with objc_addClass are initially either #1 or #3.
 * 
 * Accessing and manipulating a class's method lists are synchronized, 
 * to prevent races when one thread restructures the list. However, 
 * if the class is not yet in use (i.e. not in class_hash), then the 
 * thread loading the class may access its method lists without locking.
 * 
 * The following functions acquire methodListLock:
 * class_getInstanceMethod
 * class_getClassMethod
 * class_nextMethodList
 * class_addMethods
 * class_removeMethods
 * class_respondsToMethod
 * _class_lookupMethodAndLoadCache
 * lookupMethodInClassAndLoadCache
 * _objc_add_category_flush_caches
 *
 * The following functions don't acquire methodListLock because they 
 * only access method lists during class load and unload:
 * _objc_register_category
 * _resolve_categories_for_class (calls _objc_add_category)
 * add_class_to_loadable_list
 * _objc_addClass
 * _objc_remove_classes_in_image
 *
 * The following functions use method lists without holding methodListLock.
 * The caller must either hold methodListLock, or be loading the class.
 * _getMethod (called by class_getInstanceMethod, class_getClassMethod, 
 *   and class_respondsToMethod)
 * _findMethodInClass (called by _class_lookupMethodAndLoadCache, 
 *   lookupMethodInClassAndLoadCache, _getMethod)
 * _findMethodInList (called by _findMethodInClass)
 * nextMethodList (called by _findMethodInClass and class_nextMethodList
 * fixupSelectorsInMethodList (called by nextMethodList)
 * _objc_add_category (called by _objc_add_category_flush_caches, 
 *   resolve_categories_for_class and _objc_register_category)
 * _objc_insertMethods (called by class_addMethods and _objc_add_category)
 * _objc_removeMethods (called by class_removeMethods)
 * _objcTweakMethodListPointerForClass (called by _objc_insertMethods)
 * get_base_method_list (called by add_class_to_loadable_list)
 * lookupNamedMethodInMethodList (called by add_class_to_loadable_list)
 ***********************************************************************/

/***********************************************************************
 * Thread-safety of class info bits  (2004-10-19)
 * 
 * Some class info bits are used to store mutable runtime state. 
 * Modifications of the info bits at particular times need to be 
 * synchronized to prevent races.
 * 
 * Three thread-safe modification functions are provided:
 * _class_setInfo()     // atomically sets some bits
 * _class_clearInfo()   // atomically clears some bits
 * _class_changeInfo()  // atomically sets some bits and clears others
 * These replace CLS_SETINFO() for the multithreaded cases.
 * 
 * Three modification windows are defined:
 * - compile time
 * - class construction or image load (before +load) in one thread
 * - multi-threaded messaging and method caches
 * 
 * Info bit modification at compile time and class construction do not 
 *   need to be locked, because only one thread is manipulating the class.
 * Info bit modification during messaging needs to be locked, because 
 *   there may be other threads simultaneously messaging or otherwise 
 *   manipulating the class.
 *   
 * Modification windows for each flag:
 * 
 * CLS_CLASS: compile-time and class load
 * CLS_META: compile-time and class load
 * CLS_INITIALIZED: +initialize
 * CLS_POSING: messaging
 * CLS_MAPPED: compile-time
 * CLS_FLUSH_CACHE: class load and messaging
 * CLS_GROW_CACHE: messaging
 * CLS_NEED_BIND: unused
 * CLS_METHOD_ARRAY: unused
 * CLS_JAVA_HYBRID: JavaBridge only
 * CLS_JAVA_CLASS: JavaBridge only
 * CLS_INITIALIZING: messaging
 * CLS_FROM_BUNDLE: class load
 * CLS_HAS_CXX_STRUCTORS: compile-time and class load
 * CLS_NO_METHOD_ARRAY: class load and messaging
 * CLS_HAS_LOAD_METHOD: class load
 * 
 * CLS_INITIALIZED and CLS_INITIALIZING have additional thread-safety 
 * constraints to support thread-safe +initialize. See "Thread safety 
 * during class initialization" for details.
 * 
 * CLS_JAVA_HYBRID and CLS_JAVA_CLASS are set immediately after JavaBridge 
 * calls objc_addClass(). The JavaBridge does not use an atomic update, 
 * but the modification counts as "class construction" unless some other 
 * thread quickly finds the class via the class list. This race is 
 * small and unlikely in well-behaved code.
 *
 * Most info bits that may be modified during messaging are also never 
 * read without a lock. There is no general read lock for the info bits.
 * CLS_INITIALIZED: classInitLock
 * CLS_FLUSH_CACHE: cacheUpdateLock
 * CLS_GROW_CACHE: cacheUpdateLock
 * CLS_NO_METHOD_ARRAY: methodListLock
 * CLS_INITIALIZING: classInitLock
 ***********************************************************************/

/***********************************************************************
* Imports.
**********************************************************************/

#include "objc-private.h"
#include "objc-abi.h"
#include "objc-auto.h"
#include <objc/message.h>


/* overriding the default object allocation and error handling routines */

OBJC_EXPORT id	(*_alloc)(Class, size_t);
OBJC_EXPORT id	(*_copy)(id, size_t);
OBJC_EXPORT id	(*_realloc)(id, size_t);
OBJC_EXPORT id	(*_dealloc)(id);
OBJC_EXPORT id	(*_zoneAlloc)(Class, size_t, void *);
OBJC_EXPORT id	(*_zoneRealloc)(id, size_t, void *);
OBJC_EXPORT id	(*_zoneCopy)(id, size_t, void *);


/***********************************************************************
* Function prototypes internal to this module.
**********************************************************************/

static IMP lookupMethodInClassAndLoadCache(Class cls, SEL sel);
static Method look_up_method(Class cls, SEL sel, BOOL withCache, BOOL withResolver);


/***********************************************************************
* Static data internal to this module.
**********************************************************************/

#if !TARGET_OS_WIN32  &&  !defined(__arm__)
#   define MESSAGE_LOGGING
#endif

#if defined(MESSAGE_LOGGING)
// Method call logging
static int		LogObjCMessageSend		(BOOL isClassMethod, const char * objectsClass, const char * implementingClass, SEL selector);
typedef int	(*ObjCLogProc)(BOOL, const char *, const char *, SEL);

static int			objcMsgLogFD		= (-1);
static ObjCLogProc	objcMsgLogProc		= &LogObjCMessageSend;
static int			objcMsgLogEnabled	= 0;
#endif


/***********************************************************************
* Information about multi-thread support:
*
* Since we do not lock many operations which walk the superclass, method
* and ivar chains, these chains must remain intact once a class is published
* by inserting it into the class hashtable.  All modifications must be
* atomic so that someone walking these chains will always geta valid
* result.
***********************************************************************/



/***********************************************************************
* object_getClass.
* Locking: None. If you add locking, tell gdb (rdar://7516456).
**********************************************************************/
Class object_getClass(id obj)
{
    return _object_getClass(obj);
}


/***********************************************************************
* object_setClass.
**********************************************************************/
Class object_setClass(id obj, Class cls)
{
    if (obj) {
        Class old;
        do {
            old = obj->isa;
        } while (! OSAtomicCompareAndSwapPtrBarrier(old, cls, (void * volatile *)&obj->isa));

        if (old  &&  _class_instancesHaveAssociatedObjects(old)) {
            _class_setInstancesHaveAssociatedObjects(cls);
        }

        return old;
    }
    else return Nil;
}


/***********************************************************************
* object_getClassName.
**********************************************************************/
const char *object_getClassName(id obj)
{
    Class isa = _object_getClass(obj);
    if (isa) return _class_getName(isa);
    else return "nil";
}


/***********************************************************************
 * object_getMethodImplementation.
 **********************************************************************/
IMP object_getMethodImplementation(id obj, SEL name)
{
    Class cls = (obj ? _object_getClass(obj) : nil);
    return class_getMethodImplementation(cls, name);
}


/***********************************************************************
 * object_getMethodImplementation_stret.
 **********************************************************************/
IMP object_getMethodImplementation_stret(id obj, SEL name)
{
    Class cls = (obj ? _object_getClass(obj) : nil);
    return class_getMethodImplementation_stret(cls, name);
}


/***********************************************************************
* object_getIndexedIvars.
**********************************************************************/
void *object_getIndexedIvars(id obj)
{
    // ivars are tacked onto the end of the object
    if (obj) return ((char *) obj) + _class_getInstanceSize(_object_getClass(obj));
    else return NULL;
}


Ivar object_setInstanceVariable(id obj, const char *name, void *value)
{
    Ivar ivar = NULL;

    if (obj && name) {
        if ((ivar = class_getInstanceVariable(_object_getClass(obj), name))) {
            object_setIvar(obj, ivar, (id)value);
        }
    }
    return ivar;
}

Ivar object_getInstanceVariable(id obj, const char *name, void **value)
{
    if (obj && name) {
        Ivar ivar;
        if ((ivar = class_getInstanceVariable(_object_getClass(obj), name))) {
            if (value) *value = (void *)object_getIvar(obj, ivar);
            return ivar;
        }
    }
    if (value) *value = NULL;
    return NULL;
}

static BOOL is_scanned_offset(ptrdiff_t ivar_offset, const uint8_t *layout) {
    ptrdiff_t index = 0, ivar_index = ivar_offset / sizeof(void*);
    uint8_t byte;
    while ((byte = *layout++)) {
        unsigned skips = (byte >> 4);
        unsigned scans = (byte & 0x0F);
        index += skips;
        while (scans--) {
            if (index == ivar_index) return YES;
            if (index > ivar_index) return NO;
            ++index;
        }
    }
    return NO;
}

// FIXME:  this could be optimized.

static Class _ivar_getClass(Class cls, Ivar ivar) {
    Class ivar_class = NULL;
    const char *ivar_name = ivar_getName(ivar);
    Ivar named_ivar = _class_getVariable(cls, ivar_name, &ivar_class);
    if (named_ivar) {
        // the same ivar name can appear multiple times along the superclass chain.
        while (named_ivar != ivar && ivar_class != NULL) {
            ivar_class = class_getSuperclass(ivar_class);
            named_ivar = _class_getVariable(cls, ivar_getName(ivar), &ivar_class);
        }
    }
    return ivar_class;
}

void object_setIvar(id obj, Ivar ivar, id value)
{
    if (obj && ivar) {
        Class cls = _ivar_getClass(object_getClass(obj), ivar);
        ptrdiff_t ivar_offset = ivar_getOffset(ivar);
        id *location = (id *)((char *)obj + ivar_offset);
        // if this ivar is a member of an ARR compiled class, then issue the correct barrier according to the layout.
        if (_class_usesAutomaticRetainRelease(cls)) {
            // for ARR, layout strings are relative to the instance start.
            uint32_t instanceStart = _class_getInstanceStart(cls);
            const uint8_t *weak_layout = class_getWeakIvarLayout(cls);
            if (weak_layout && is_scanned_offset(ivar_offset - instanceStart, weak_layout)) {
                // use the weak system to write to this variable.
                objc_storeWeak(location, value);
                return;
            }
            const uint8_t *strong_layout = class_getIvarLayout(cls);
            if (strong_layout && is_scanned_offset(ivar_offset - instanceStart, strong_layout)) {
                objc_storeStrong(location, value);
                return;
            }
        }
#if SUPPORT_GC
        if (UseGC) {
            // for GC, check for weak references.
            const uint8_t *weak_layout = class_getWeakIvarLayout(cls);
            if (weak_layout && is_scanned_offset(ivar_offset, weak_layout)) {
                objc_assign_weak(value, location);
            }
        }
        objc_assign_ivar_internal(value, obj, ivar_offset);
#else
        *location = value;
#endif
    }
}


id object_getIvar(id obj, Ivar ivar)
{
    if (obj  &&  ivar) {
        Class cls = _object_getClass(obj);
        ptrdiff_t ivar_offset = ivar_getOffset(ivar);
        if (_class_usesAutomaticRetainRelease(cls)) {
            // for ARR, layout strings are relative to the instance start.
            uint32_t instanceStart = _class_getInstanceStart(cls);
            const uint8_t *weak_layout = class_getWeakIvarLayout(cls);
            if (weak_layout && is_scanned_offset(ivar_offset - instanceStart, weak_layout)) {
                // use the weak system to read this variable.
                id *location = (id *)((char *)obj + ivar_offset);
                return objc_loadWeak(location);
            }
        }
        id *idx = (id *)((char *)obj + ivar_offset);
#if SUPPORT_GC
        if (UseGC) {
            const uint8_t *weak_layout = class_getWeakIvarLayout(cls);
            if (weak_layout && is_scanned_offset(ivar_offset, weak_layout)) {
                return objc_read_weak(idx);
            }
        }
#endif
        return *idx;
    }
    return NULL;
}


/***********************************************************************
* object_cxxDestructFromClass.
* Call C++ destructors on obj, starting with cls's 
*   dtor method (if any) followed by superclasses' dtors (if any), 
*   stopping at cls's dtor (if any).
* Uses methodListLock and cacheUpdateLock. The caller must hold neither.
**********************************************************************/
static void object_cxxDestructFromClass(id obj, Class cls)
{
    void (*dtor)(id);

    // Call cls's dtor first, then superclasses's dtors.

    for ( ; cls != NULL; cls = _class_getSuperclass(cls)) {
        if (!_class_hasCxxStructors(cls)) return; 
        dtor = (void(*)(id))
            lookupMethodInClassAndLoadCache(cls, SEL_cxx_destruct);
        if (dtor != (void(*)(id))_objc_msgForward_internal) {
            if (PrintCxxCtors) {
                _objc_inform("CXX: calling C++ destructors for class %s", 
                             _class_getName(cls));
            }
            (*dtor)(obj);
        }
    }
}


/***********************************************************************
* object_cxxDestruct.
* Call C++ destructors on obj, if any.
* Uses methodListLock and cacheUpdateLock. The caller must hold neither.
**********************************************************************/
void object_cxxDestruct(id obj)
{
    if (!obj) return;
    if (OBJC_IS_TAGGED_PTR(obj)) return;
    object_cxxDestructFromClass(obj, obj->isa);  // need not be object_getClass
}


/***********************************************************************
* object_cxxConstructFromClass.
* Recursively call C++ constructors on obj, starting with base class's 
*   ctor method (if any) followed by subclasses' ctors (if any), stopping 
*   at cls's ctor (if any).
* Returns YES if construction succeeded.
* Returns NO if some constructor threw an exception. The exception is 
*   caught and discarded. Any partial construction is destructed.
* Uses methodListLock and cacheUpdateLock. The caller must hold neither.
*
* .cxx_construct returns id. This really means:
* return self: construction succeeded
* return nil:  construction failed because a C++ constructor threw an exception
**********************************************************************/
static BOOL object_cxxConstructFromClass(id obj, Class cls)
{
    id (*ctor)(id);
    Class supercls;

    // Stop if neither this class nor any superclass has ctors.
    if (!_class_hasCxxStructors(cls)) return YES;  // no ctor - ok

    supercls = _class_getSuperclass(cls);

    // Call superclasses' ctors first, if any.
    if (supercls) {
        BOOL ok = object_cxxConstructFromClass(obj, supercls);
        if (!ok) return NO;  // some superclass's ctor failed - give up
    }

    // Find this class's ctor, if any.
    ctor = (id(*)(id))lookupMethodInClassAndLoadCache(cls, SEL_cxx_construct);
    if (ctor == (id(*)(id))_objc_msgForward_internal) return YES;  // no ctor - ok
    
    // Call this class's ctor.
    if (PrintCxxCtors) {
        _objc_inform("CXX: calling C++ constructors for class %s", _class_getName(cls));
    }
    if ((*ctor)(obj)) return YES;  // ctor called and succeeded - ok

    // This class's ctor was called and failed. 
    // Call superclasses's dtors to clean up.
    if (supercls) object_cxxDestructFromClass(obj, supercls);
    return NO;
}


/***********************************************************************
* object_cxxConstructFromClass.
* Call C++ constructors on obj, if any.
* Returns YES if construction succeeded.
* Returns NO if some constructor threw an exception. The exception is 
*   caught and discarded. Any partial construction is destructed.
* Uses methodListLock and cacheUpdateLock. The caller must hold neither.
**********************************************************************/
BOOL object_cxxConstruct(id obj)
{
    if (!obj) return YES;
    if (OBJC_IS_TAGGED_PTR(obj)) return YES;
    return object_cxxConstructFromClass(obj, obj->isa);  // need not be object_getClass
}


/***********************************************************************
* _class_resolveClassMethod
* Call +resolveClassMethod and return the method added or NULL.
* cls should be a metaclass.
* Assumes the method doesn't exist already.
**********************************************************************/
static Method _class_resolveClassMethod(Class cls, SEL sel)
{
    BOOL resolved;
    Method meth = NULL;
    Class clsInstance;

    if (!look_up_method(cls, SEL_resolveClassMethod, 
                        YES /*cache*/, NO /*resolver*/))
    {
        return NULL;
    }

    // GrP fixme same hack as +initialize
    if (strncmp(_class_getName(cls), "_%", 2) == 0) {
        // Posee's meta's name is smashed and isn't in the class_hash, 
        // so objc_getClass doesn't work.
        const char *baseName = strchr(_class_getName(cls), '%'); // get posee's real name
        clsInstance = (Class)objc_getClass(baseName);
    } else {
        clsInstance = (Class)objc_getClass(_class_getName(cls));
    }
    
    resolved = ((BOOL(*)(id, SEL, SEL))objc_msgSend)((id)clsInstance, SEL_resolveClassMethod, sel);

    if (resolved) {
        // +resolveClassMethod adds to self->isa
        meth = look_up_method(cls, sel, YES/*cache*/, NO/*resolver*/);

        if (!meth) {
            // Method resolver didn't add anything?
            _objc_inform("+[%s resolveClassMethod:%s] returned YES, but "
                         "no new implementation of +[%s %s] was found", 
                         class_getName(cls),
                         sel_getName(sel), 
                         class_getName(cls), 
                         sel_getName(sel));
            return NULL;
        }
    }

    return meth;
}


/***********************************************************************
* _class_resolveInstanceMethod
* Call +resolveInstanceMethod and return the method added or NULL.
* cls should be a non-meta class.
* Assumes the method doesn't exist already.
**********************************************************************/
static Method _class_resolveInstanceMethod(Class cls, SEL sel)
{
    BOOL resolved;
    Method meth = NULL;

    if (!look_up_method(((id)cls)->isa, SEL_resolveInstanceMethod, 
                        YES /*cache*/, NO /*resolver*/))
    {
        return NULL;
    }

    resolved = ((BOOL(*)(id, SEL, SEL))objc_msgSend)((id)cls, SEL_resolveInstanceMethod, sel);

    if (resolved) {
        // +resolveClassMethod adds to self
        meth = look_up_method(cls, sel, YES/*cache*/, NO/*resolver*/);

        if (!meth) {
            // Method resolver didn't add anything?
            _objc_inform("+[%s resolveInstanceMethod:%s] returned YES, but "
                         "no new implementation of %c[%s %s] was found", 
                         class_getName(cls),
                         sel_getName(sel), 
                         class_isMetaClass(cls) ? '+' : '-', 
                         class_getName(cls), 
                         sel_getName(sel));
            return NULL;
        }
    }

    return meth;
}


/***********************************************************************
* _class_resolveMethod
* Call +resolveClassMethod or +resolveInstanceMethod and return 
* the method added or NULL. 
* Assumes the method doesn't exist already.
**********************************************************************/
Method _class_resolveMethod(Class cls, SEL sel)
{
    Method meth = NULL;

    if (_class_isMetaClass(cls)) {
        meth = _class_resolveClassMethod(cls, sel);
    }
    if (!meth) {
        meth = _class_resolveInstanceMethod(cls, sel);
    }

    if (PrintResolving  &&  meth) {
        _objc_inform("RESOLVE: method %c[%s %s] dynamically resolved to %p", 
                     class_isMetaClass(cls) ? '+' : '-', 
                     class_getName(cls), sel_getName(sel), 
                     method_getImplementation(meth));
    }
    
    return meth;
}


/***********************************************************************
* look_up_method
* Look up a method in the given class and its superclasses. 
* If withCache==YES, look in the class's method cache too.
* If withResolver==YES, call +resolveClass/InstanceMethod too.
* Returns NULL if the method is not found. 
* +forward:: entries are not returned.
**********************************************************************/
static Method look_up_method(Class cls, SEL sel, 
                             BOOL withCache, BOOL withResolver)
{
    Method meth = NULL;

    if (withCache) {
        meth = _cache_getMethod(cls, sel, _objc_msgForward_internal);
        if (meth == (Method)1) {
            // Cache contains forward:: . Stop searching.
            return NULL;
        }
    }

    if (!meth) meth = _class_getMethod(cls, sel);

    if (!meth  &&  withResolver) meth = _class_resolveMethod(cls, sel);

    return meth;
}


/***********************************************************************
* class_getInstanceMethod.  Return the instance method for the
* specified class and selector.
**********************************************************************/
Method class_getInstanceMethod(Class cls, SEL sel)
{
    if (!cls  ||  !sel) return NULL;

    return look_up_method(cls, sel, YES/*cache*/, YES/*resolver*/);
}

/***********************************************************************
* class_getClassMethod.  Return the class method for the specified
* class and selector.
**********************************************************************/
Method class_getClassMethod(Class cls, SEL sel)
{
    if (!cls  ||  !sel) return NULL;

    return class_getInstanceMethod(_class_getMeta(cls), sel);
}


/***********************************************************************
* class_getInstanceVariable.  Return the named instance variable.
**********************************************************************/
Ivar class_getInstanceVariable(Class cls, const char *name)
{
    if (!cls  ||  !name) return NULL;

    return _class_getVariable(cls, name, NULL);
}


/***********************************************************************
* class_getClassVariable.  Return the named class variable.
**********************************************************************/
Ivar class_getClassVariable(Class cls, const char *name)
{
    if (!cls) return NULL;

    return class_getInstanceVariable(((id)cls)->isa, name);
}


/***********************************************************************
* gdb_objc_class_changed
* Tell gdb that a class changed. Currently used for OBJC2 ivar layouts only
* Does nothing; gdb sets a breakpoint on it.
**********************************************************************/
BREAKPOINT_FUNCTION( 
    void gdb_objc_class_changed(Class cls, unsigned long changes, const char *classname)
);


/***********************************************************************
* _objc_flush_caches.  Flush the caches of the specified class and any
* of its subclasses.  If cls is a meta-class, only meta-class (i.e.
* class method) caches are flushed.  If cls is an instance-class, both
* instance-class and meta-class caches are flushed.
**********************************************************************/
void _objc_flush_caches(Class cls)
{
    flush_caches (cls, YES);

    if (!cls) {
        // collectALot if cls==nil
        mutex_lock(&cacheUpdateLock);
        _cache_collect(true);
        mutex_unlock(&cacheUpdateLock);
    }
}


/***********************************************************************
* class_respondsToSelector.
**********************************************************************/
BOOL class_respondsToMethod(Class cls, SEL sel)
{
    OBJC_WARN_DEPRECATED;

    return class_respondsToSelector(cls, sel);
}


BOOL class_respondsToSelector(Class cls, SEL sel)
{
    IMP imp;

    if (!sel  ||  !cls) return NO;

    // Avoids +initialize because it historically did so.
    // We're not returning a callable IMP anyway.
    imp = lookUpMethod(cls, sel, NO/*initialize*/, YES/*cache*/, nil);
    return (imp != (IMP)_objc_msgForward_internal) ? YES : NO;
}


/***********************************************************************
* class_getMethodImplementation.
* Returns the IMP that would be invoked if [obj sel] were sent, 
* where obj is an instance of class cls.
**********************************************************************/
IMP class_lookupMethod(Class cls, SEL sel)
{
    OBJC_WARN_DEPRECATED;

    // No one responds to zero!
    if (!sel) {
        __objc_error((id)cls, "invalid selector (null)");
    }

    return class_getMethodImplementation(cls, sel);
}

IMP class_getMethodImplementation(Class cls, SEL sel)
{
    IMP imp;

    if (!cls  ||  !sel) return NULL;

    imp = lookUpMethod(cls, sel, YES/*initialize*/, YES/*cache*/, nil);

    // Translate forwarding function to C-callable external version
    if (imp == _objc_msgForward_internal) {
        return _objc_msgForward;
    }

    return imp;
}


IMP class_getMethodImplementation_stret(Class cls, SEL sel)
{
    IMP imp = class_getMethodImplementation(cls, sel);

    // Translate forwarding function to struct-returning version
    if (imp == (IMP)&_objc_msgForward /* not _internal! */) {
        return (IMP)&_objc_msgForward_stret;
    }
    return imp;
}


/***********************************************************************
* instrumentObjcMessageSends/logObjcMessageSends.
**********************************************************************/
#if !defined(MESSAGE_LOGGING)  &&  defined(__arm__)
void	instrumentObjcMessageSends       (BOOL		flag)
{
}
#elif defined(MESSAGE_LOGGING)
static int	LogObjCMessageSend (BOOL			isClassMethod,
                               const char *	objectsClass,
                               const char *	implementingClass,
                               SEL				selector)
{
    char	buf[ 1024 ];

    // Create/open the log file
    if (objcMsgLogFD == (-1))
    {
        snprintf (buf, sizeof(buf), "/tmp/msgSends-%d", (int) getpid ());
        objcMsgLogFD = secure_open (buf, O_WRONLY | O_CREAT, geteuid());
        if (objcMsgLogFD < 0) {
            // no log file - disable logging
            objcMsgLogEnabled = 0;
            objcMsgLogFD = -1;
            return 1;
        }
    }

    // Make the log entry
    snprintf(buf, sizeof(buf), "%c %s %s %s\n",
            isClassMethod ? '+' : '-',
            objectsClass,
            implementingClass,
            sel_getName(selector));

    static OSSpinLock lock = OS_SPINLOCK_INIT;
    OSSpinLockLock(&lock);
    write (objcMsgLogFD, buf, strlen(buf));
    OSSpinLockUnlock(&lock);

    // Tell caller to not cache the method
    return 0;
}

void	instrumentObjcMessageSends       (BOOL		flag)
{
    int		enabledValue = (flag) ? 1 : 0;

    // Shortcut NOP
    if (objcMsgLogEnabled == enabledValue)
        return;

    // If enabling, flush all method caches so we get some traces
    if (flag)
        flush_caches (Nil, YES);

    // Sync our log file
    if (objcMsgLogFD != (-1))
        fsync (objcMsgLogFD);

    objcMsgLogEnabled = enabledValue;
}

void	logObjcMessageSends      (ObjCLogProc	logProc)
{
    if (logProc)
    {
        objcMsgLogProc = logProc;
        objcMsgLogEnabled = 1;
    }
    else
    {
        objcMsgLogProc = logProc;
        objcMsgLogEnabled = 0;
    }

    if (objcMsgLogFD != (-1))
        fsync (objcMsgLogFD);
}
#endif

/***********************************************************************
* log_and_fill_cache
* Log this method call. If the logger permits it, fill the method cache.
* cls is the method whose cache should be filled. 
* implementer is the class that owns the implementation in question.
**********************************************************************/
void
log_and_fill_cache(Class cls, Class implementer, Method meth, SEL sel)
{
#if defined(MESSAGE_LOGGING)
    BOOL cacheIt = YES;

    if (objcMsgLogEnabled) {
        cacheIt = objcMsgLogProc (_class_isMetaClass(implementer) ? YES : NO,
                                  _class_getName(cls),
                                  _class_getName(implementer), 
                                  sel);
    }
    if (cacheIt)
#endif
        _cache_fill (cls, meth, sel);
}


/***********************************************************************
* _class_lookupMethodAndLoadCache.
* Method lookup for dispatchers ONLY. OTHER CODE SHOULD USE lookUpMethod().
* This lookup avoids optimistic cache scan because the dispatcher 
* already tried that.
**********************************************************************/
IMP _class_lookupMethodAndLoadCache3(id obj, SEL sel, Class cls)
{        
    return lookUpMethod(cls, sel, YES/*initialize*/, NO/*cache*/, obj);
}


/***********************************************************************
* lookUpMethod.
* The standard method lookup. 
* initialize==NO tries to avoid +initialize (but sometimes fails)
* cache==NO skips optimistic unlocked lookup (but uses cache elsewhere)
* Most callers should use initialize==YES and cache==YES.
* inst is an instance of cls or a subclass thereof, or nil if none is known. 
*   If cls is an un-initialized metaclass then a non-nil inst is faster.
* May return _objc_msgForward_internal. IMPs destined for external use 
*   must be converted to _objc_msgForward or _objc_msgForward_stret.
**********************************************************************/
IMP lookUpMethod(Class cls, SEL sel, BOOL initialize, BOOL cache, id inst)
{
    Class curClass;
    IMP methodPC = NULL;
    Method meth;
    BOOL triedResolver = NO;

    // Optimistic cache lookup
    if (cache) {
        methodPC = _cache_getImp(cls, sel);
        if (methodPC) return methodPC;    
    }

    // realize, +initialize, and any special early exit
    methodPC = prepareForMethodLookup(cls, sel, initialize, inst);
    if (methodPC) return methodPC;


    // The lock is held to make method-lookup + cache-fill atomic 
    // with respect to method addition. Otherwise, a category could 
    // be added but ignored indefinitely because the cache was re-filled 
    // with the old value after the cache flush on behalf of the category.
 retry:
    lockForMethodLookup();

    // Ignore GC selectors
    if (ignoreSelector(sel)) {
        methodPC = _cache_addIgnoredEntry(cls, sel);
        goto done;
    }

    // Try this class's cache.

    methodPC = _cache_getImp(cls, sel);
    if (methodPC) goto done;

    // Try this class's method lists.

    meth = _class_getMethodNoSuper_nolock(cls, sel);
    if (meth) {
        log_and_fill_cache(cls, cls, meth, sel);
        methodPC = method_getImplementation(meth);
        goto done;
    }

    // Try superclass caches and method lists.

    curClass = cls;
    while ((curClass = _class_getSuperclass(curClass))) {
        // Superclass cache.
        meth = _cache_getMethod(curClass, sel, _objc_msgForward_internal);
        if (meth) {
            if (meth != (Method)1) {
                // Found the method in a superclass. Cache it in this class.
                log_and_fill_cache(cls, curClass, meth, sel);
                methodPC = method_getImplementation(meth);
                goto done;
            }
            else {
                // Found a forward:: entry in a superclass.
                // Stop searching, but don't cache yet; call method 
                // resolver for this class first.
                break;
            }
        }

        // Superclass method list.
        meth = _class_getMethodNoSuper_nolock(curClass, sel);
        if (meth) {
            log_and_fill_cache(cls, curClass, meth, sel);
            methodPC = method_getImplementation(meth);
            goto done;
        }
    }

    // No implementation found. Try method resolver once.

    if (!triedResolver) {
        unlockForMethodLookup();
        _class_resolveMethod(cls, sel);
        // Don't cache the result; we don't hold the lock so it may have 
        // changed already. Re-do the search from scratch instead.
        triedResolver = YES;
        goto retry;
    }

    // No implementation found, and method resolver didn't help. 
    // Use forwarding.

    _cache_addForwardEntry(cls, sel);
    methodPC = _objc_msgForward_internal;

 done:
    unlockForMethodLookup();

    // paranoia: look for ignored selectors with non-ignored implementations
    assert(!(ignoreSelector(sel)  &&  methodPC != (IMP)&_objc_ignored_method));

    return methodPC;
}


/***********************************************************************
* lookupMethodInClassAndLoadCache.
* Like _class_lookupMethodAndLoadCache, but does not search superclasses.
* Caches and returns objc_msgForward if the method is not found in the class.
**********************************************************************/
static IMP lookupMethodInClassAndLoadCache(Class cls, SEL sel)
{
    Method meth;
    IMP imp;

    // fixme this still has the method list vs method cache race 
    // because it doesn't hold a lock across lookup+cache_fill, 
    // but it's only used for .cxx_construct/destruct and we assume 
    // categories don't change them.

    // Search cache first.
    imp = _cache_getImp(cls, sel);
    if (imp) return imp;

    // Cache miss. Search method list.

    meth = _class_getMethodNoSuper(cls, sel);

    if (meth) {
        // Hit in method list. Cache it.
        _cache_fill(cls, meth, sel);
        return method_getImplementation(meth);
    } else {
        // Miss in method list. Cache objc_msgForward.
        _cache_addForwardEntry(cls, sel);
        return _objc_msgForward_internal;
    }
}


/***********************************************************************
* _malloc_internal
* _calloc_internal
* _realloc_internal
* _strdup_internal
* _strdupcat_internal
* _memdup_internal
* _free_internal
* Convenience functions for the internal malloc zone.
**********************************************************************/
void *_malloc_internal(size_t size) 
{
    return malloc_zone_malloc(_objc_internal_zone(), size);
}

void *_calloc_internal(size_t count, size_t size) 
{
    return malloc_zone_calloc(_objc_internal_zone(), count, size);
}

void *_realloc_internal(void *ptr, size_t size)
{
    return malloc_zone_realloc(_objc_internal_zone(), ptr, size);
}

char *_strdup_internal(const char *str)
{
    size_t len;
    char *dup;
    if (!str) return NULL;
    len = strlen(str);
    dup = (char *)malloc_zone_malloc(_objc_internal_zone(), len + 1);
    memcpy(dup, str, len + 1);
    return dup;
}

uint8_t *_ustrdup_internal(const uint8_t *str)
{
    return (uint8_t *)_strdup_internal((char *)str);
}

// allocate a new string that concatenates s1+s2.
char *_strdupcat_internal(const char *s1, const char *s2)
{
    size_t len1 = strlen(s1);
    size_t len2 = strlen(s2);
    char *dup = (char *)
        malloc_zone_malloc(_objc_internal_zone(), len1 + len2 + 1);
    memcpy(dup, s1, len1);
    memcpy(dup + len1, s2, len2 + 1);
    return dup;
}

void *_memdup_internal(const void *mem, size_t len)
{
    void *dup = malloc_zone_malloc(_objc_internal_zone(), len);
    memcpy(dup, mem, len);
    return dup;
}

void _free_internal(void *ptr)
{
    malloc_zone_free(_objc_internal_zone(), ptr);
}

size_t _malloc_size_internal(void *ptr)
{
    malloc_zone_t *zone = _objc_internal_zone();
    return zone->size(zone, ptr);
}

Class _calloc_class(size_t size)
{
#if SUPPORT_GC
    if (UseGC) return (Class) malloc_zone_calloc(gc_zone, 1, size);
#endif
    return (Class) _calloc_internal(1, size);
}


const char *class_getName(Class cls)
{
    return _class_getName(cls);
}

Class class_getSuperclass(Class cls)
{
    return _class_getSuperclass(cls);
}

BOOL class_isMetaClass(Class cls)
{
    return _class_isMetaClass(cls);
}


size_t class_getInstanceSize(Class cls)
{
    return _class_getInstanceSize(cls);
}


/***********************************************************************
* method_getNumberOfArguments.
**********************************************************************/
unsigned int method_getNumberOfArguments(Method m)
{
    if (!m) return 0;
    return encoding_getNumberOfArguments(method_getTypeEncoding(m));
}


void method_getReturnType(Method m, char *dst, size_t dst_len)
{
    encoding_getReturnType(method_getTypeEncoding(m), dst, dst_len);
}


char * method_copyReturnType(Method m)
{
    return encoding_copyReturnType(method_getTypeEncoding(m));
}


void method_getArgumentType(Method m, unsigned int index, 
                            char *dst, size_t dst_len)
{
    encoding_getArgumentType(method_getTypeEncoding(m),
                             index, dst, dst_len);
}


char * method_copyArgumentType(Method m, unsigned int index)
{
    return encoding_copyArgumentType(method_getTypeEncoding(m), index);
}


/***********************************************************************
* objc_constructInstance
* Creates an instance of `cls` at the location pointed to by `bytes`. 
* `bytes` must point to at least class_getInstanceSize(cls) bytes of 
*   well-aligned zero-filled memory.
* The new object's isa is set. Any C++ constructors are called.
* Returns `bytes` if successful. Returns nil if `cls` or `bytes` is 
*   NULL, or if C++ constructors fail.
* Note: class_createInstance() and class_createInstances() preflight this.
**********************************************************************/
static id 
_objc_constructInstance(Class cls, void *bytes) 
{
    id obj = (id)bytes;

    // Set the isa pointer
    obj->isa = cls;  // need not be object_setClass

    // Call C++ constructors, if any.
    if (!object_cxxConstruct(obj)) {
        // Some C++ constructor threw an exception. 
        return nil;
    }

    return obj;
}


id 
objc_constructInstance(Class cls, void *bytes) 
{
    if (!cls  ||  !bytes) return nil;
    return _objc_constructInstance(cls, bytes);
}


id
_objc_constructOrFree(Class cls, void *bytes)
{
    id obj = _objc_constructInstance(cls, bytes);
    if (!obj) {
#if SUPPORT_GC
        if (UseGC) {
            auto_zone_retain(gc_zone, bytes);  // gc free expects rc==1
        }
#endif
        free(bytes);
    }

    return obj;
}


/***********************************************************************
* _class_createInstancesFromZone
* Batch-allocating version of _class_createInstanceFromZone.
* Attempts to allocate num_requested objects, each with extraBytes.
* Returns the number of allocated objects (possibly zero), with 
* the allocated pointers in *results.
**********************************************************************/
unsigned
_class_createInstancesFromZone(Class cls, size_t extraBytes, void *zone, 
                               id *results, unsigned num_requested)
{
    unsigned num_allocated;
    if (!cls) return 0;

    size_t size = _class_getInstanceSize(cls) + extraBytes;
    // CF requires all objects be at least 16 bytes.
    if (size < 16) size = 16;

#if SUPPORT_GC
    if (UseGC) {
        num_allocated = 
            auto_zone_batch_allocate(gc_zone, size, AUTO_OBJECT_SCANNED, 0, 1, 
                                     (void**)results, num_requested);
    } else 
#endif
    {
        unsigned i;
        num_allocated = 
            malloc_zone_batch_malloc((malloc_zone_t *)(zone ? zone : malloc_default_zone()), 
                                     size, (void**)results, num_requested);
        for (i = 0; i < num_allocated; i++) {
            bzero(results[i], size);
        }
    }

    // Construct each object, and delete any that fail construction.

    unsigned shift = 0;
    unsigned i;
    BOOL ctor = _class_hasCxxStructors(cls);
    for (i = 0; i < num_allocated; i++) {
        id obj = results[i];
        if (ctor) obj = _objc_constructOrFree(cls, obj);
        else if (obj) obj->isa = cls;  // need not be object_setClass

        if (obj) {
            results[i-shift] = obj;
        } else {
            shift++;
        }
    }

    return num_allocated - shift;    
}


/***********************************************************************
* inform_duplicate. Complain about duplicate class implementations.
**********************************************************************/
void 
inform_duplicate(const char *name, Class oldCls, Class cls)
{
#if TARGET_OS_WIN32
    _objc_inform ("Class %s is implemented in two different images.", name);
#else
    const header_info *oldHeader = _headerForClass(oldCls);
    const header_info *newHeader = _headerForClass(cls);
    const char *oldName = oldHeader ? oldHeader->fname : "??";
    const char *newName = newHeader ? newHeader->fname : "??";
        
    _objc_inform ("Class %s is implemented in both %s and %s. "
                  "One of the two will be used. "
                  "Which one is undefined.",
                  name, oldName, newName);
#endif
}

#if SUPPORT_TAGGED_POINTERS
/***********************************************************************
 * _objc_insert_tagged_isa
 * Insert an isa into a particular slot in the tagged isa table.
 * Will error & abort if slot already has an isa that is different.
 **********************************************************************/
void _objc_insert_tagged_isa(unsigned char slotNumber, Class isa) {
    unsigned char actualSlotNumber = (slotNumber << 1) + 1;
    Class previousIsa = _objc_tagged_isa_table[actualSlotNumber];
    
    if (actualSlotNumber & 0xF0) {
        _objc_fatal("%s -- Slot number %uc is too large. Aborting.", __FUNCTION__, slotNumber);
    }
    
    if (actualSlotNumber == 0) {
        _objc_fatal("%s -- Slot number 0 doesn't make sense. Aborting.", __FUNCTION__);
    }
    
    if (isa && previousIsa && (previousIsa != isa)) {
        _objc_fatal("%s -- Tagged pointer table already had an item in that slot (%s). "
                     "Not putting (%s) in table. Aborting instead",
                    __FUNCTION__, class_getName(previousIsa), class_getName(isa));
    }
    _objc_tagged_isa_table[actualSlotNumber] = isa;
}
#endif


const char *
copyPropertyAttributeString(const objc_property_attribute_t *attrs,
                            unsigned int count)
{
    char *result;
    unsigned int i;
    if (count == 0) return strdup("");
    
#ifndef NDEBUG
    // debug build: sanitize input
    for (i = 0; i < count; i++) {
        assert(attrs[i].name);
        assert(strlen(attrs[i].name) > 0);
        assert(! strchr(attrs[i].name, ','));
        assert(! strchr(attrs[i].name, '"'));
        if (attrs[i].value) assert(! strchr(attrs[i].value, ','));
    }
#endif

    size_t len = 0;
    for (i = 0; i < count; i++) {
        if (attrs[i].value) {
            size_t namelen = strlen(attrs[i].name);
            if (namelen > 1) namelen += 2;  // long names get quoted
            len += namelen + strlen(attrs[i].value) + 1;
        }
    }

    result = (char *)malloc(len + 1);
    char *s = result;
    for (i = 0; i < count; i++) {
        if (attrs[i].value) {
            size_t namelen = strlen(attrs[i].name);
            if (namelen > 1) {
                s += sprintf(s, "\"%s\"%s,", attrs[i].name, attrs[i].value);
            } else {
                s += sprintf(s, "%s%s,", attrs[i].name, attrs[i].value);
            }
        }
    }

    // remove trailing ',' if any
    if (s > result) s[-1] = '\0';

    return result;
}

/*
  Property attribute string format:

  - Comma-separated name-value pairs. 
  - Name and value may not contain ,
  - Name may not contain "
  - Value may be empty
  - Name is single char, value follows
  - OR Name is double-quoted string of 2+ chars, value follows

  Grammar:
    attribute-string: \0
    attribute-string: name-value-pair (',' name-value-pair)*
    name-value-pair:  unquoted-name optional-value
    name-value-pair:  quoted-name optional-value
    unquoted-name:    [^",]
    quoted-name:      '"' [^",]{2,} '"'
    optional-value:   [^,]*

*/
static unsigned int 
iteratePropertyAttributes(const char *attrs, 
                          BOOL (*fn)(unsigned int index, 
                                     void *ctx1, void *ctx2, 
                                     const char *name, size_t nlen, 
                                     const char *value, size_t vlen), 
                          void *ctx1, void *ctx2)
{
    if (!attrs) return 0;

#ifndef NDEBUG
    const char *attrsend = attrs + strlen(attrs);
#endif
    unsigned int attrcount = 0;

    while (*attrs) {
        // Find the next comma-separated attribute
        const char *start = attrs;
        const char *end = start + strcspn(attrs, ",");

        // Move attrs past this attribute and the comma (if any)
        attrs = *end ? end+1 : end;

        assert(attrs <= attrsend);
        assert(start <= attrsend);
        assert(end <= attrsend);
        
        // Skip empty attribute
        if (start == end) continue;

        // Process one non-empty comma-free attribute [start,end)
        const char *nameStart;
        const char *nameEnd;

        assert(start < end);
        assert(*start);
        if (*start != '\"') {
            // single-char short name
            nameStart = start;
            nameEnd = start+1;
            start++;
        }
        else {
            // double-quoted long name
            nameStart = start+1;
            nameEnd = nameStart + strcspn(nameStart, "\",");
            start++;                       // leading quote
            start += nameEnd - nameStart;  // name
            if (*start == '\"') start++;   // trailing quote, if any
        }

        // Process one possibly-empty comma-free attribute value [start,end)
        const char *valueStart;
        const char *valueEnd;

        assert(start <= end);

        valueStart = start;
        valueEnd = end;

        BOOL more = (*fn)(attrcount, ctx1, ctx2, 
                          nameStart, nameEnd-nameStart, 
                          valueStart, valueEnd-valueStart);
        attrcount++;
        if (!more) break;
    }

    return attrcount;
}


static BOOL 
copyOneAttribute(unsigned int index, void *ctxa, void *ctxs, 
                 const char *name, size_t nlen, const char *value, size_t vlen)
{
    objc_property_attribute_t **ap = (objc_property_attribute_t**)ctxa;
    char **sp = (char **)ctxs;

    objc_property_attribute_t *a = *ap;
    char *s = *sp;

    a->name = s;
    memcpy(s, name, nlen);
    s += nlen;
    *s++ = '\0';
    
    a->value = s;
    memcpy(s, value, vlen);
    s += vlen;
    *s++ = '\0';

    a++;
    
    *ap = a;
    *sp = s;

    return YES;
}

                 
objc_property_attribute_t *
copyPropertyAttributeList(const char *attrs, unsigned int *outCount)
{
    if (!attrs) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    // Result size:
    //   number of commas plus 1 for the attributes (upper bound)
    //   plus another attribute for the attribute array terminator
    //   plus strlen(attrs) for name/value string data (upper bound)
    //   plus count*2 for the name/value string terminators (upper bound)
    unsigned int attrcount = 1;
    const char *s;
    for (s = attrs; s && *s; s++) {
        if (*s == ',') attrcount++;
    }

    size_t size = 
        attrcount * sizeof(objc_property_attribute_t) + 
        sizeof(objc_property_attribute_t) + 
        strlen(attrs) + 
        attrcount * 2;
    objc_property_attribute_t *result = (objc_property_attribute_t *) 
        calloc(size, 1);

    objc_property_attribute_t *ra = result;
    char *rs = (char *)(ra+attrcount+1);

    attrcount = iteratePropertyAttributes(attrs, copyOneAttribute, &ra, &rs);

    assert((uint8_t *)(ra+1) <= (uint8_t *)result+size);
    assert((uint8_t *)rs <= (uint8_t *)result+size);

    if (attrcount == 0) {
        free(result);
        result = NULL;
    }

    if (outCount) *outCount = attrcount;
    return result;
}


static BOOL 
findOneAttribute(unsigned int index, void *ctxa, void *ctxs, 
                 const char *name, size_t nlen, const char *value, size_t vlen)
{
    const char *query = (char *)ctxa;
    char **resultp = (char **)ctxs;

    if (strlen(query) == nlen  &&  0 == strncmp(name, query, nlen)) {
        char *result = (char *)calloc(vlen+1, 1);
        memcpy(result, value, vlen);
        result[vlen] = '\0';
        *resultp = result;
        return NO;
    }

    return YES;
}

char *copyPropertyAttributeValue(const char *attrs, const char *name)
{
    char *result = NULL;

    iteratePropertyAttributes(attrs, findOneAttribute, (void*)name, &result);

    return result;
}
