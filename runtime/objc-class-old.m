/*
 * Copyright (c) 1999-2009 Apple Inc.  All Rights Reserved.
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
* objc-class-old.m
* Support for old-ABI classes, methods, and categories.
**********************************************************************/

#if !__OBJC2__

#include "objc-private.h"
#include "objc-runtime-old.h"

// Freed objects have their isa set to point to this dummy class.
// This avoids the need to check for Nil classes in the messenger.
static const struct old_class freedObjectClass =
{
    Nil,				// isa
    Nil,				// super_class
    "FREED(id)",			// name
    0,				// version
    0,				// info
    0,				// instance_size
    NULL,				// ivars
    NULL,				// methodLists
    (Cache) &_objc_empty_cache,		// cache
    NULL,				// protocols
    NULL,			// ivar_layout;
    NULL			// ext
};


/***********************************************************************
* _class_getFreedObjectClass.  Return a pointer to the dummy freed
* object class.  Freed objects get their isa pointers replaced with
* a pointer to the freedObjectClass, so that we can catch usages of
* the freed object.
**********************************************************************/
static Class _class_getFreedObjectClass(void)
{
    return (Class)&freedObjectClass;
}


/***********************************************************************
* _objc_getFreedObjectClass.  Return a pointer to the dummy freed
* object class.  Freed objects get their isa pointers replaced with
* a pointer to the freedObjectClass, so that we can catch usages of
* the freed object.
**********************************************************************/
Class _objc_getFreedObjectClass(void)
{
    return _class_getFreedObjectClass();
}


static void allocateExt(struct old_class *cls)
{
    if (! (cls->info & CLS_EXT)) {
        _objc_inform("class '%s' needs to be recompiled", cls->name);
        return;
    } 
    if (!cls->ext) {
        uint32_t size = (uint32_t)sizeof(struct old_class_ext);
        cls->ext = _calloc_internal(size, 1);
        cls->ext->size = size;
    }
}


static inline struct old_method *_findNamedMethodInList(struct old_method_list * mlist, const char *meth_name) {
    int i;
    if (!mlist) return NULL;
    if (ignoreSelectorNamed(meth_name)) return NULL;
    for (i = 0; i < mlist->method_count; i++) {
        struct old_method *m = &mlist->method_list[i];
        if (0 == strcmp((const char *)(m->method_name), meth_name)) {
            return m;
        }
    }
    return NULL;
}


/***********************************************************************
* Method list fixup markers.
* mlist->obsolete == fixed_up_method_list marks method lists with real SELs 
*   versus method lists with un-uniqued char*.
* PREOPTIMIZED VERSION:
*   Fixed-up method lists get mlist->obsolete == OBJC_FIXED_UP 
*   dyld shared cache sets this for method lists it preoptimizes.
* UN-PREOPTIMIZED VERSION
*   Fixed-up method lists get mlist->obsolete == OBJC_FIXED_UP_outside_dyld
*   dyld shared cache uses OBJC_FIXED_UP, but those aren't trusted.
**********************************************************************/
#define OBJC_FIXED_UP ((void *)1771)
#define OBJC_FIXED_UP_outside_dyld ((void *)1773)
static void *fixed_up_method_list = OBJC_FIXED_UP;

// sel_init() decided that selectors in the dyld shared cache are untrustworthy
void disableSharedCacheOptimizations(void)
{
    fixed_up_method_list = OBJC_FIXED_UP_outside_dyld;
}

/***********************************************************************
* fixupSelectorsInMethodList
* Uniques selectors in the given method list.
* Also replaces imps for GC-ignored selectors
* The given method list must be non-NULL and not already fixed-up.
* If the class was loaded from a bundle:
*   fixes up the given list in place with heap-allocated selector strings
* If the class was not from a bundle:
*   allocates a copy of the method list, fixes up the copy, and returns 
*   the copy. The given list is unmodified.
*
* If cls is already in use, methodListLock must be held by the caller.
**********************************************************************/
static struct old_method_list *fixupSelectorsInMethodList(struct old_class *cls, struct old_method_list *mlist)
{
    int i;
    size_t size;
    struct old_method *method;
    struct old_method_list *old_mlist; 
    
    if ( ! mlist ) return NULL;
    if ( mlist->obsolete == fixed_up_method_list ) {
        // method list OK
    } else {
        BOOL isBundle = (cls->info & CLS_FROM_BUNDLE) ? YES : NO;
        if (!isBundle) {
            old_mlist = mlist;
            size = sizeof(struct old_method_list) - sizeof(struct old_method) + old_mlist->method_count * sizeof(struct old_method);
            mlist = _malloc_internal(size);
            memmove(mlist, old_mlist, size);
        } else {
            // Mach-O bundles are fixed up in place. 
            // This prevents leaks when a bundle is unloaded.
        }
        sel_lock();
        for ( i = 0; i < mlist->method_count; i += 1 ) {
            method = &mlist->method_list[i];
            method->method_name =
                sel_registerNameNoLock((const char *)method->method_name, isBundle);  // Always copy selector data from bundles.

            if (ignoreSelector(method->method_name)) {
                method->method_imp = (IMP)&_objc_ignored_method;
            }
        }
        sel_unlock();
        mlist->obsolete = fixed_up_method_list;
    }
    return mlist;
}


/***********************************************************************
* nextMethodList
* Returns successive method lists from the given class.
* Method lists are returned in method search order (i.e. highest-priority 
* implementations first).
* All necessary method list fixups are performed, so the 
* returned method list is fully-constructed.
*
* If cls is already in use, methodListLock must be held by the caller.
* For full thread-safety, methodListLock must be continuously held by the 
* caller across all calls to nextMethodList(). If the lock is released, 
* the bad results listed in class_nextMethodList() may occur.
*
* void *iterator = NULL;
* struct old_method_list *mlist;
* mutex_lock(&methodListLock);
* while ((mlist = nextMethodList(cls, &iterator))) {
*     // do something with mlist
* }
* mutex_unlock(&methodListLock);
**********************************************************************/
static struct old_method_list *nextMethodList(struct old_class *cls,
                                               void **it)
{
    uintptr_t index = *(uintptr_t *)it;
    struct old_method_list **resultp;

    if (index == 0) {
        // First call to nextMethodList.
        if (!cls->methodLists) {
            resultp = NULL;
        } else if (cls->info & CLS_NO_METHOD_ARRAY) {
            resultp = (struct old_method_list **)&cls->methodLists;
        } else {
            resultp = &cls->methodLists[0];
            if (!*resultp  ||  *resultp == END_OF_METHODS_LIST) {
                resultp = NULL;
            }
        }
    } else {
        // Subsequent call to nextMethodList.
        if (!cls->methodLists) {
            resultp = NULL;
        } else if (cls->info & CLS_NO_METHOD_ARRAY) {
            resultp = NULL;
        } else {
            resultp = &cls->methodLists[index];
            if (!*resultp  ||  *resultp == END_OF_METHODS_LIST) {
                resultp = NULL;
            }
        }
    }

    // resultp now is NULL, meaning there are no more method lists, 
    // OR the address of the method list pointer to fix up and return.
    
    if (resultp) {
        if (*resultp) {
            *resultp = fixupSelectorsInMethodList(cls, *resultp);
        }
        *it = (void *)(index + 1);
        return *resultp;
    } else {
        *it = 0;
        return NULL;
    }
}


/* These next three functions are the heart of ObjC method lookup. 
 * If the class is currently in use, methodListLock must be held by the caller.
 */
static inline struct old_method *_findMethodInList(struct old_method_list * mlist, SEL sel) {
    int i;
    if (!mlist) return NULL;
    for (i = 0; i < mlist->method_count; i++) {
        struct old_method *m = &mlist->method_list[i];
        if (m->method_name == sel) {
            return m;
        }
    }
    return NULL;
}

static inline struct old_method * _findMethodInClass(struct old_class *cls, SEL sel) __attribute__((always_inline));
static inline struct old_method * _findMethodInClass(struct old_class *cls, SEL sel) {
    // Flattened version of nextMethodList(). The optimizer doesn't 
    // do a good job with hoisting the conditionals out of the loop.
    // Conceptually, this looks like:
    // while ((mlist = nextMethodList(cls, &iterator))) {
    //     struct old_method *m = _findMethodInList(mlist, sel);
    //     if (m) return m;
    // }

    if (!cls->methodLists) {
        // No method lists.
        return NULL;
    }
    else if (cls->info & CLS_NO_METHOD_ARRAY) {
        // One method list.
        struct old_method_list **mlistp;
        mlistp = (struct old_method_list **)&cls->methodLists;
        *mlistp = fixupSelectorsInMethodList(cls, *mlistp);
        return _findMethodInList(*mlistp, sel);
    }
    else {
        // Multiple method lists.
        struct old_method_list **mlistp;
        for (mlistp = cls->methodLists; 
             *mlistp != NULL  &&  *mlistp != END_OF_METHODS_LIST; 
             mlistp++) 
        {
            struct old_method *m;
            *mlistp = fixupSelectorsInMethodList(cls, *mlistp);
            m = _findMethodInList(*mlistp, sel);
            if (m) return m;
        }
        return NULL;
    }
}

static inline struct old_method * _getMethod(struct old_class *cls, SEL sel) {
    for (; cls; cls = cls->super_class) {
        struct old_method *m;
        m = _findMethodInClass(cls, sel);
        if (m) return m;
    }
    return NULL;
}


// fixme for gc debugging temporary use
IMP findIMPInClass(struct old_class *cls, SEL sel)
{
    struct old_method *m = _findMethodInClass(cls, sel);
    if (m) return m->method_imp;
    else return NULL;
}


/***********************************************************************
* _freedHandler.
**********************************************************************/
static void _freedHandler(id obj, SEL sel)
{
    __objc_error (obj, "message %s sent to freed object=%p", 
                  sel_getName(sel), obj);
}


/***********************************************************************
* ABI-specific lookUpMethod helpers.
**********************************************************************/
void lockForMethodLookup(void)
{
    mutex_lock(&methodListLock);
}
void unlockForMethodLookup(void)
{
    mutex_unlock(&methodListLock);
}
IMP prepareForMethodLookup(Class cls, SEL sel, BOOL init, id obj)
{
    mutex_assert_unlocked(&methodListLock);

    // Check for freed class
    if (cls == _class_getFreedObjectClass())
        return (IMP) _freedHandler;

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
* class_getVariable.  Return the named instance variable.
**********************************************************************/

Ivar _class_getVariable(Class cls_gen, const char *name, Class *memberOf)
{
    struct old_class *cls = oldcls(cls_gen);

    for (; cls != Nil; cls = cls->super_class) {
        int i;

        // Skip class having no ivars
        if (!cls->ivars) continue;

        for (i = 0; i < cls->ivars->ivar_count; i++) {
            // Check this ivar's name.  Be careful because the
            // compiler generates ivar entries with NULL ivar_name
            // (e.g. for anonymous bit fields).
            struct old_ivar *ivar = &cls->ivars->ivar_list[i];
            if (ivar->ivar_name  &&  0 == strcmp(name, ivar->ivar_name)) {
                if (memberOf) *memberOf = (Class)cls;
                return (Ivar)ivar;
            }
        }
    }

    // Not found
    return NULL;
}


struct old_property * 
property_list_nth(const struct old_property_list *plist, uint32_t i)
{
    return (struct old_property *)(i*plist->entsize + (char *)&plist->first);
}

struct old_property **
copyPropertyList(struct old_property_list *plist, unsigned int *outCount)
{
    struct old_property **result = NULL;
    unsigned int count = 0;

    if (plist) {
        count = plist->count;
    }

    if (count > 0) {
        unsigned int i;
        result = malloc((count+1) * sizeof(struct old_property *));
        
        for (i = 0; i < count; i++) {
            result[i] = property_list_nth(plist, i);
        }
        result[i] = NULL;
    }

    if (outCount) *outCount = count;
    return result;
}


static struct old_property_list *
nextPropertyList(struct old_class *cls, uintptr_t *indexp)
{
    struct old_property_list *result = NULL;

    mutex_assert_locked(&classLock);
    if (! ((cls->info & CLS_EXT)  &&  cls->ext)) {
        // No class ext
        result = NULL;
    } else if (!cls->ext->propertyLists) {
        // No property lists
        result = NULL;
    } else if (cls->info & CLS_NO_PROPERTY_ARRAY) {
        // Only one property list
        if (*indexp == 0) {
            result = (struct old_property_list *)cls->ext->propertyLists;
        } else {
            result = NULL;
        }
    } else {
        // More than one property list
        result = cls->ext->propertyLists[*indexp];
    }

    if (result) {
        ++*indexp;
        return result;
    } else {
        *indexp = 0;
        return NULL;
    }
}


/***********************************************************************
* class_getIvarLayout
* NULL means all-scanned. "" means non-scanned.
**********************************************************************/
const uint8_t *
class_getIvarLayout(Class cls_gen)
{
    struct old_class *cls = oldcls(cls_gen);
    if (cls  &&  (cls->info & CLS_EXT)) {
        return cls->ivar_layout;
    } else {
        return NULL;  // conservative scan
    }
}


/***********************************************************************
* class_getWeakIvarLayout
* NULL means no weak ivars.
**********************************************************************/
const uint8_t *
class_getWeakIvarLayout(Class cls_gen)
{
    struct old_class *cls = oldcls(cls_gen);
    if (cls  &&  (cls->info & CLS_EXT)  &&  cls->ext) {
        return cls->ext->weak_ivar_layout;
    } else {
        return NULL;  // no weak ivars
    }
}


/***********************************************************************
* class_setIvarLayout
* NULL means all-scanned. "" means non-scanned.
**********************************************************************/
void class_setIvarLayout(Class cls_gen, const uint8_t *layout)
{
    struct old_class *cls = oldcls(cls_gen);
    if (!cls) return;

    if (! (cls->info & CLS_EXT)) {
        _objc_inform("class '%s' needs to be recompiled", cls->name);
        return;
    } 

    // fixme leak
    cls->ivar_layout = _ustrdup_internal(layout);
}

// SPI:  Instance-specific object layout.

void _class_setIvarLayoutAccessor(Class cls_gen, const uint8_t* (*accessor) (id object)) {
    struct old_class *cls = oldcls(cls_gen);
    if (!cls) return;

    if (! (cls->info & CLS_EXT)) {
        _objc_inform("class '%s' needs to be recompiled", cls->name);
        return;
    } 

    // fixme leak
    cls->ivar_layout = (const uint8_t *)accessor;
    _class_setInfo(cls_gen, CLS_HAS_INSTANCE_SPECIFIC_LAYOUT);
}

const uint8_t *_object_getIvarLayout(Class cls_gen, id object) {
    struct old_class *cls = oldcls(cls_gen);
    if (cls && (cls->info & CLS_EXT)) {
        const uint8_t* layout = cls->ivar_layout;
        if (cls->info & CLS_HAS_INSTANCE_SPECIFIC_LAYOUT) {
            const uint8_t* (*accessor) (id object) = (const uint8_t* (*)(id))layout;
            layout = accessor(object);
        }
        return layout;
    } else {
        return NULL;
    }
}

/***********************************************************************
* class_setWeakIvarLayout
* NULL means no weak ivars.
**********************************************************************/
void class_setWeakIvarLayout(Class cls_gen, const uint8_t *layout)
{
    struct old_class *cls = oldcls(cls_gen);
    if (!cls) return;

    mutex_lock(&classLock);

    allocateExt(cls);
    
    // fixme leak
    cls->ext->weak_ivar_layout = _ustrdup_internal(layout);

    mutex_unlock(&classLock);
}


/***********************************************************************
* _class_changeInfo
* Atomically sets and clears some bits in cls's info field.
* set and clear must not overlap.
**********************************************************************/
void _class_changeInfo(Class cls, long set, long clear)
{
    struct old_class *old = oldcls(cls);
    long newinfo;
    long oldinfo;
    do {
        oldinfo = old->info;
        newinfo = (oldinfo | set) & ~clear;
    } while (! OSAtomicCompareAndSwapLong(oldinfo, newinfo, &old->info));
}


/***********************************************************************
* _class_getInfo
* Returns YES iff all set bits in get are also set in cls's info field.
**********************************************************************/
BOOL _class_getInfo(Class cls, int get)
{
    struct old_class *old = oldcls(cls);
    return ((old->info & get) == get) ? YES : NO;
}


/***********************************************************************
* _class_setInfo
* Atomically sets some bits in cls's info field.
**********************************************************************/
void _class_setInfo(Class cls, long set)
{
    _class_changeInfo(cls, set, 0);
}


/***********************************************************************
* _class_clearInfo
* Atomically clears some bits in cls's info field.
**********************************************************************/
void _class_clearInfo(Class cls, long clear)
{
    _class_changeInfo(cls, 0, clear);
}


/***********************************************************************
* isInitializing
* Return YES if cls is currently being initialized.
* The initializing bit is stored in the metaclass only.
**********************************************************************/
BOOL _class_isInitializing(Class cls)
{
    return _class_getInfo(_class_getMeta(cls), CLS_INITIALIZING);
}


/***********************************************************************
* isInitialized
* Return YES if cls is already initialized.
* The initialized bit is stored in the metaclass only.
**********************************************************************/
BOOL _class_isInitialized(Class cls)
{
    return _class_getInfo(_class_getMeta(cls), CLS_INITIALIZED);
}


/***********************************************************************
* setInitializing
* Mark cls as initialization in progress.
**********************************************************************/
void _class_setInitializing(Class cls)
{
    _class_setInfo(_class_getMeta(cls), CLS_INITIALIZING);
}


/***********************************************************************
* setInitialized
* Atomically mark cls as initialized and not initializing.
**********************************************************************/
void _class_setInitialized(Class cls)
{
    _class_changeInfo(_class_getMeta(cls), CLS_INITIALIZED, CLS_INITIALIZING);
}


/***********************************************************************
* class_setVersion.  Record the specified version with the class.
**********************************************************************/
void class_setVersion(Class cls, int version)
{
    if (!cls) return;
    cls->version = version;
}

/***********************************************************************
* class_getVersion.  Return the version recorded with the class.
**********************************************************************/
int class_getVersion(Class cls)
{
    if (!cls) return 0;
    return (int)cls->version;
}


Class _class_getMeta(Class cls)
{
    if (_class_getInfo(cls, CLS_META)) return cls;
    else return ((id)cls)->isa;
}

BOOL _class_isMetaClass(Class cls)
{
    if (!cls) return NO;
    return _class_getInfo(cls, CLS_META);
}


/***********************************************************************
* _class_getNonMetaClass. 
* Return the ordinary class for this class or metaclass. 
* Used by +initialize. 
**********************************************************************/
Class _class_getNonMetaClass(Class cls, id obj __unused)
{
    // fixme ick
    if (_class_isMetaClass(cls)) {
        if (strncmp(_class_getName(cls), "_%", 2) == 0) {
            // Posee's meta's name is smashed and isn't in the class_hash, 
            // so objc_getClass doesn't work.
            const char *baseName = strchr(_class_getName(cls), '%'); // get posee's real name
            cls = (Class)objc_getClass(baseName);
        } else {
            cls = (Class)objc_getClass(_class_getName(cls));
        }
        assert(cls);
    }

    return cls;
}


Class _class_getSuperclass(Class cls)
{
    if (!cls) return nil;
    return (Class)cls->super_class;
}


Cache _class_getCache(Class cls)
{
    return cls->cache;
}

void _class_setCache(Class cls, Cache cache)
{
    cls->cache = cache;
}

size_t _class_getInstanceSize(Class cls)
{
    if (!cls) return 0;
    return (cls->instance_size + WORD_MASK) & ~WORD_MASK;
}

const char * _class_getName(Class cls)
{
    if (!cls) return "nil";
    return cls->name;
}



const char *_category_getName(Category cat)
{
    return oldcategory(cat)->category_name;
}

const char *_category_getClassName(Category cat)
{
    return oldcategory(cat)->class_name;
}

Class _category_getClass(Category cat)
{
    return (Class)objc_getClass(oldcategory(cat)->class_name);
}

IMP _category_getLoadMethod(Category cat)
{
    struct old_method_list *mlist = oldcategory(cat)->class_methods;
    if (mlist) {
        return lookupNamedMethodInMethodList(mlist, "load");
    } else {
        return NULL;
    }
}



/***********************************************************************
* class_nextMethodList.
* External version of nextMethodList().
*
* This function is not fully thread-safe. A series of calls to 
* class_nextMethodList() may fail if methods are added to or removed 
* from the class between calls.
* If methods are added between calls to class_nextMethodList(), it may 
* return previously-returned method lists again, and may fail to return 
* newly-added lists. 
* If methods are removed between calls to class_nextMethodList(), it may 
* omit surviving method lists or simply crash.
**********************************************************************/
OBJC_EXPORT struct objc_method_list *class_nextMethodList(Class cls, void **it)
{
    struct old_method_list *result;

    OBJC_WARN_DEPRECATED;

    mutex_lock(&methodListLock);
    result = nextMethodList(oldcls(cls), it);
    mutex_unlock(&methodListLock);
    return (struct objc_method_list *)result;
}


/***********************************************************************
* class_addMethods.
*
* Formerly class_addInstanceMethods ()
**********************************************************************/
OBJC_EXPORT void class_addMethods(Class cls, struct objc_method_list *meths)
{
    OBJC_WARN_DEPRECATED;

    // Add the methods.
    mutex_lock(&methodListLock);
    _objc_insertMethods(oldcls(cls), (struct old_method_list *)meths, NULL);
    mutex_unlock(&methodListLock);

    // Must flush when dynamically adding methods.  No need to flush
    // all the class method caches.  If cls is a meta class, though,
    // this will still flush it and any of its sub-meta classes.
    flush_caches (cls, NO);
}


/***********************************************************************
* class_removeMethods.
**********************************************************************/
OBJC_EXPORT void class_removeMethods(Class cls, struct objc_method_list *meths)
{
    OBJC_WARN_DEPRECATED;

    // Remove the methods
    mutex_lock(&methodListLock);
    _objc_removeMethods(oldcls(cls), (struct old_method_list *)meths);
    mutex_unlock(&methodListLock);

    // Must flush when dynamically removing methods.  No need to flush
    // all the class method caches.  If cls is a meta class, though,
    // this will still flush it and any of its sub-meta classes.
    flush_caches (cls, NO);
}

/***********************************************************************
* lookupNamedMethodInMethodList
* Only called to find +load/-.cxx_construct/-.cxx_destruct methods, 
* without fixing up the entire method list.
* The class is not yet in use, so methodListLock is not taken.
**********************************************************************/
IMP lookupNamedMethodInMethodList(struct old_method_list *mlist, const char *meth_name)
{
    struct old_method *m;
    m = meth_name ? _findNamedMethodInList(mlist, meth_name) : NULL;
    return (m ? m->method_imp : NULL);
}

Method _class_getMethod(Class cls, SEL sel)
{
    Method result;
    
    mutex_lock(&methodListLock);
    result = (Method)_getMethod(oldcls(cls), sel);
    mutex_unlock(&methodListLock);

    return result;
}

Method _class_getMethodNoSuper(Class cls, SEL sel)
{
    Method result;

    mutex_lock(&methodListLock);
    result = (Method)_findMethodInClass(oldcls(cls), sel);
    mutex_unlock(&methodListLock);

    return result;
}

Method _class_getMethodNoSuper_nolock(Class cls, SEL sel)
{
    mutex_assert_locked(&methodListLock);
    return (Method)_findMethodInClass(oldcls(cls), sel);
}


BOOL class_conformsToProtocol(Class cls_gen, Protocol *proto_gen)
{
    struct old_class *cls = oldcls(cls_gen);
    struct old_protocol *proto = oldprotocol(proto_gen);
    
    if (!cls_gen) return NO;
    if (!proto) return NO;

    if (cls->isa->version >= 3) {
        struct old_protocol_list *list;
        for (list = cls->protocols; list != NULL; list = list->next) {
            int i;
            for (i = 0; i < list->count; i++) {
                if (list->list[i] == proto) return YES;
                if (protocol_conformsToProtocol((Protocol *)list->list[i], proto_gen)) return YES;
            }
            if (cls->isa->version <= 4) break;
        }
    }
    return NO;
}


static NXMapTable *	posed_class_hash = NULL;

/***********************************************************************
* objc_getOrigClass.
**********************************************************************/
Class _objc_getOrigClass(const char *name)
{
    Class ret;

    // Look for class among the posers
    ret = Nil;
    mutex_lock(&classLock);
    if (posed_class_hash)
        ret = (Class) NXMapGet (posed_class_hash, name);
    mutex_unlock(&classLock);
    if (ret)
        return ret;

    // Not a poser.  Do a normal lookup.
    ret = (Class)objc_getClass (name);
    if (!ret)
        _objc_inform ("class `%s' not linked into application", name);

    return ret;
}

Class objc_getOrigClass(const char *name)
{
    OBJC_WARN_DEPRECATED;
    return _objc_getOrigClass(name);
}

/***********************************************************************
* _objc_addOrigClass.  This function is only used from class_poseAs.
* Registers the original class names, before they get obscured by
* posing, so that [super ..] will work correctly from categories
* in posing classes and in categories in classes being posed for.
**********************************************************************/
static void	_objc_addOrigClass	   (struct old_class *origClass)
{
    mutex_lock(&classLock);

    // Create the poser's hash table on first use
    if (!posed_class_hash)
    {
        posed_class_hash = NXCreateMapTableFromZone (NXStrValueMapPrototype,
                                                     8,
                                                     _objc_internal_zone ());
    }

    // Add the named class iff it is not already there (or collides?)
    if (NXMapGet (posed_class_hash, origClass->name) == 0)
        NXMapInsert (posed_class_hash, origClass->name, origClass);

    mutex_unlock(&classLock);
}


/***********************************************************************
* change_class_references
* Change classrefs and superclass pointers from original to imposter
* But if copy!=nil, don't change copy->super_class.
* If changeSuperRefs==YES, also change [super message] classrefs. 
* Used by class_poseAs and objc_setFutureClass
* classLock must be locked.
**********************************************************************/
void change_class_references(struct old_class *imposter, 
                             struct old_class *original, 
                             struct old_class *copy, 
                             BOOL changeSuperRefs)
{
    header_info *hInfo;
    struct old_class *clsObject;
    NXHashState state;

    // Change all subclasses of the original to point to the imposter.
    state = NXInitHashState (class_hash);
    while (NXNextHashState (class_hash, &state, (void **) &clsObject))
    {
        while  ((clsObject) && (clsObject != imposter) &&
                (clsObject != copy))
        {
            if (clsObject->super_class == original)
            {
                clsObject->super_class = imposter;
                clsObject->isa->super_class = imposter->isa;
                // We must flush caches here!
                break;
            }

            clsObject = clsObject->super_class;
        }
    }

    // Replace the original with the imposter in all class refs
    // Major loop - process all headers
    for (hInfo = FirstHeader; hInfo != NULL; hInfo = hInfo->next)
    {
        struct old_class **cls_refs;
        size_t	refCount;
        unsigned int	index;

        // Fix class refs associated with this header
        cls_refs = _getObjcClassRefs(hInfo, &refCount);
        if (cls_refs) {
            for (index = 0; index < refCount; index += 1) {
                if (cls_refs[index] == original) {
                    cls_refs[index] = imposter;
                }
            }
        }
    }
}


/***********************************************************************
* class_poseAs.
*
* !!! class_poseAs () does not currently flush any caches.
**********************************************************************/
Class class_poseAs(Class imposter_gen, Class original_gen)
{
    struct old_class *imposter = oldcls(imposter_gen);
    struct old_class *original = oldcls(original_gen);
    char *			imposterNamePtr;
    struct old_class * 			copy;

    OBJC_WARN_DEPRECATED;

    // Trivial case is easy
    if (imposter_gen == original_gen)
        return imposter_gen;

    // Imposter must be an immediate subclass of the original
    if (imposter->super_class != original) {
        __objc_error((id)imposter_gen, 
                     "[%s poseAs:%s]: target not immediate superclass", 
                     imposter->name, original->name);
    }

    // Can't pose when you have instance variables (how could it work?)
    if (imposter->ivars) {
        __objc_error((id)imposter_gen, 
                     "[%s poseAs:%s]: %s defines new instance variables", 
                     imposter->name, original->name, imposter->name);
    }

    // Build a string to use to replace the name of the original class.
#if TARGET_OS_WIN32
#   define imposterNamePrefix "_%"
    imposterNamePtr = _malloc_internal(strlen(original->name) + strlen(imposterNamePrefix) + 1);
    strcpy(imposterNamePtr, imposterNamePrefix);
    strcat(imposterNamePtr, original->name);
#   undef imposterNamePrefix
#else
    asprintf(&imposterNamePtr, "_%%%s", original->name);
#endif

    // We lock the class hashtable, so we are thread safe with respect to
    // calls to objc_getClass ().  However, the class names are not
    // changed atomically, nor are all of the subclasses updated
    // atomically.  I have ordered the operations so that you will
    // never crash, but you may get inconsistent results....

    // Register the original class so that [super ..] knows
    // exactly which classes are the "original" classes.
    _objc_addOrigClass (original);
    _objc_addOrigClass (imposter);

    // Copy the imposter, so that the imposter can continue
    // its normal life in addition to changing the behavior of
    // the original.  As a hack we don't bother to copy the metaclass.
    // For some reason we modify the original rather than the copy.
    copy = (struct old_class *)_malloc_internal(sizeof(struct old_class));
    memmove(copy, imposter, sizeof(struct old_class));

    mutex_lock(&classLock);

    // Remove both the imposter and the original class.
    NXHashRemove (class_hash, imposter);
    NXHashRemove (class_hash, original);

    NXHashInsert (class_hash, copy);
    objc_addRegisteredClass((Class)copy);  // imposter & original will rejoin later, just track the new guy

    // Mark the imposter as such
    _class_setInfo((Class)imposter, CLS_POSING);
    _class_setInfo((Class)imposter->isa, CLS_POSING);

    // Change the name of the imposter to that of the original class.
    imposter->name      = original->name;
    imposter->isa->name = original->isa->name;

    // Also copy the version field to avoid archiving problems.
    imposter->version = original->version;

    // Change classrefs and superclass pointers
    // Don't change copy->super_class
    // Don't change [super ...] messages
    change_class_references(imposter, original, copy, NO);

    // Change the name of the original class.
    original->name      = imposterNamePtr + 1;
    original->isa->name = imposterNamePtr;

    // Restore the imposter and the original class with their new names.
    NXHashInsert (class_hash, imposter);
    NXHashInsert (class_hash, original);

    mutex_unlock(&classLock);

    return imposter_gen;
}


/***********************************************************************
* flush_caches.  Flush the instance and optionally class method caches
* of cls and all its subclasses.
*
* Specifying Nil for the class "all classes."
**********************************************************************/
void flush_caches(Class target_gen, BOOL flush_meta)
{
    NXHashState state;
    struct old_class *target = oldcls(target_gen);
    struct old_class *clsObject;
#ifdef OBJC_INSTRUMENTED
    unsigned int classesVisited;
    unsigned int subclassCount;
#endif

    mutex_lock(&classLock);
    mutex_lock(&cacheUpdateLock);

    // Leaf classes are fastest because there are no subclass caches to flush.
    // fixme instrument
    if (target  &&  (target->info & CLS_LEAF)) {
        _cache_flush ((Class)target);
        
        if (!flush_meta) {
            mutex_unlock(&cacheUpdateLock);
            mutex_unlock(&classLock);
            return;  // done
        } else if (target->isa  &&  (target->isa->info & CLS_LEAF)) {
            _cache_flush ((Class)target->isa);
            mutex_unlock(&cacheUpdateLock);
            mutex_unlock(&classLock);
            return;  // done
        } else {
            // Reset target and handle it by one of the methods below.
            target = target->isa;
            flush_meta = NO;
            // NOT done
        }
    }

    state = NXInitHashState(class_hash);

    // Handle nil and root instance class specially: flush all
    // instance and class method caches.  Nice that this
    // loop is linear vs the N-squared loop just below.
    if (!target  ||  !target->super_class)
    {
#ifdef OBJC_INSTRUMENTED
        LinearFlushCachesCount += 1;
        classesVisited = 0;
        subclassCount = 0;
#endif
        // Traverse all classes in the hash table
        while (NXNextHashState(class_hash, &state, (void**)&clsObject))
        {
            struct old_class *metaClsObject;
#ifdef OBJC_INSTRUMENTED
            classesVisited += 1;
#endif

            // Skip class that is known not to be a subclass of this root
            // (the isa pointer of any meta class points to the meta class
            // of the root).
            // NOTE: When is an isa pointer of a hash tabled class ever nil?
            metaClsObject = clsObject->isa;
            if (target  &&  metaClsObject  &&  target->isa != metaClsObject->isa) {
                continue;
            }

#ifdef OBJC_INSTRUMENTED
            subclassCount += 1;
#endif

            _cache_flush ((Class)clsObject);
            if (flush_meta  &&  metaClsObject != NULL) {
                _cache_flush ((Class)metaClsObject);
            }
        }
#ifdef OBJC_INSTRUMENTED
        LinearFlushCachesVisitedCount += classesVisited;
        if (classesVisited > MaxLinearFlushCachesVisitedCount)
            MaxLinearFlushCachesVisitedCount = classesVisited;
        IdealFlushCachesCount += subclassCount;
        if (subclassCount > MaxIdealFlushCachesCount)
            MaxIdealFlushCachesCount = subclassCount;
#endif

        mutex_unlock(&cacheUpdateLock);
        mutex_unlock(&classLock);
        return;
    }

    // Outer loop - flush any cache that could now get a method from
    // cls (i.e. the cache associated with cls and any of its subclasses).
#ifdef OBJC_INSTRUMENTED
    NonlinearFlushCachesCount += 1;
    classesVisited = 0;
    subclassCount = 0;
#endif
    while (NXNextHashState(class_hash, &state, (void**)&clsObject))
    {
        struct old_class *clsIter;

#ifdef OBJC_INSTRUMENTED
        NonlinearFlushCachesClassCount += 1;
#endif

        // Inner loop - Process a given class
        clsIter = clsObject;
        while (clsIter)
        {

#ifdef OBJC_INSTRUMENTED
            classesVisited += 1;
#endif
            // Flush clsObject instance method cache if
            // clsObject is a subclass of cls, or is cls itself
            // Flush the class method cache if that was asked for
            if (clsIter == target)
            {
#ifdef OBJC_INSTRUMENTED
                subclassCount += 1;
#endif
                _cache_flush ((Class)clsObject);
                if (flush_meta)
                    _cache_flush ((Class)clsObject->isa);

                break;

            }

            // Flush clsObject class method cache if cls is
            // the meta class of clsObject or of one
            // of clsObject's superclasses
            else if (clsIter->isa == target)
            {
#ifdef OBJC_INSTRUMENTED
                subclassCount += 1;
#endif
                _cache_flush ((Class)clsObject->isa);
                break;
            }

            // Move up superclass chain
            // else if (_class_isInitialized(clsIter))
            clsIter = clsIter->super_class;

            // clsIter is not initialized, so its cache
            // must be empty.  This happens only when
            // clsIter == clsObject, because
            // superclasses are initialized before
            // subclasses, and this loop traverses
            // from sub- to super- classes.
            // else
                // break;
        }
    }
#ifdef OBJC_INSTRUMENTED
    NonlinearFlushCachesVisitedCount += classesVisited;
    if (classesVisited > MaxNonlinearFlushCachesVisitedCount)
        MaxNonlinearFlushCachesVisitedCount = classesVisited;
    IdealFlushCachesCount += subclassCount;
    if (subclassCount > MaxIdealFlushCachesCount)
        MaxIdealFlushCachesCount = subclassCount;
#endif

    mutex_unlock(&cacheUpdateLock);
    mutex_unlock(&classLock);
}


/***********************************************************************
* flush_marked_caches. Flush the method cache of any class marked 
* CLS_FLUSH_CACHE (and all subclasses thereof)
* fixme instrument
**********************************************************************/
void flush_marked_caches(void)
{
    struct old_class *cls;
    struct old_class *supercls;
    NXHashState state;

    mutex_lock(&classLock);
    mutex_lock(&cacheUpdateLock);

    state = NXInitHashState(class_hash);
    while (NXNextHashState(class_hash, &state, (void**)&cls)) {
        for (supercls = cls; supercls; supercls = supercls->super_class) {
            if (supercls->info & CLS_FLUSH_CACHE) {
                _cache_flush((Class)cls);
                break;
            }
        }

        for (supercls = cls->isa; supercls; supercls = supercls->super_class) {
            if (supercls->info & CLS_FLUSH_CACHE) {
                _cache_flush((Class)cls->isa);
                break;
            }
        }
    }

    state = NXInitHashState(class_hash);
    while (NXNextHashState(class_hash, &state, (void**)&cls)) {
        if (cls->info & CLS_FLUSH_CACHE) {
            _class_clearInfo((Class)cls, CLS_FLUSH_CACHE);            
        }
        if (cls->isa->info & CLS_FLUSH_CACHE) {
            _class_clearInfo((Class)cls->isa, CLS_FLUSH_CACHE);
        }
    }

    mutex_unlock(&cacheUpdateLock);
    mutex_unlock(&classLock);
}


/***********************************************************************
* get_base_method_list
* Returns the method list containing the class's own methods, 
* ignoring any method lists added by categories or class_addMethods. 
* Called only by add_class_to_loadable_list. 
* Does not hold methodListLock because add_class_to_loadable_list 
* does not manipulate in-use classes.
**********************************************************************/
static struct old_method_list *get_base_method_list(struct old_class *cls) 
{
    struct old_method_list **ptr;

    if (!cls->methodLists) return NULL;
    if (cls->info & CLS_NO_METHOD_ARRAY) return (struct old_method_list *)cls->methodLists;
    ptr = cls->methodLists;
    if (!*ptr  ||  *ptr == END_OF_METHODS_LIST) return NULL;
    while ( *ptr != 0 && *ptr != END_OF_METHODS_LIST ) { ptr++; }
    --ptr;
    return *ptr;
}


static IMP _class_getLoadMethod_nocheck(struct old_class *cls)
{
    struct old_method_list *mlist;
    mlist = get_base_method_list(cls->isa);
    if (mlist) {
        return lookupNamedMethodInMethodList (mlist, "load");
    }
    return NULL;
}


BOOL _class_hasLoadMethod(Class cls)
{
    if (oldcls(cls)->isa->info & CLS_HAS_LOAD_METHOD) return YES;
    return (_class_getLoadMethod_nocheck(oldcls(cls)) ? YES : NO);
}


/***********************************************************************
* _class_getLoadMethod
* Returns cls's +load implementation, or NULL if it doesn't have one.
**********************************************************************/
IMP _class_getLoadMethod(Class cls_gen)
{
    struct old_class *cls = oldcls(cls_gen);
    if (cls->isa->info & CLS_HAS_LOAD_METHOD) {
        return _class_getLoadMethod_nocheck(cls);
    }
    return NULL;
}


BOOL _class_shouldGrowCache(Class cls)
{
    return _class_getInfo(cls, CLS_GROW_CACHE);
}

void _class_setGrowCache(Class cls, BOOL grow)
{
    if (grow) _class_setInfo(cls, CLS_GROW_CACHE);
    else _class_clearInfo(cls, CLS_GROW_CACHE);
}

BOOL _class_hasCxxStructors(Class cls)
{
    // this DOES check superclasses too, because set_superclass 
    // propagates the flag from the superclass.
    return _class_getInfo(cls, CLS_HAS_CXX_STRUCTORS);
}

BOOL _class_shouldFinalizeOnMainThread(Class cls) {
    return _class_getInfo(cls, CLS_FINALIZE_ON_MAIN_THREAD);
}

void _class_setFinalizeOnMainThread(Class cls) {
    _class_setInfo(cls, CLS_FINALIZE_ON_MAIN_THREAD);
}

BOOL _class_instancesHaveAssociatedObjects(Class cls) {
    return _class_getInfo(cls, CLS_INSTANCES_HAVE_ASSOCIATED_OBJECTS);
}

void _class_setInstancesHaveAssociatedObjects(Class cls) {
    _class_setInfo(cls, CLS_INSTANCES_HAVE_ASSOCIATED_OBJECTS);
}

BOOL _class_usesAutomaticRetainRelease(Class cls)
{
    return NO;
}

uint32_t _class_getInstanceStart(Class cls)
{
    _objc_fatal("_class_getInstanceStart() unimplemented for fragile instance variables");
    return 0;   // PCB:  never used just provided for ARR consistency.
}

ptrdiff_t ivar_getOffset(Ivar ivar)
{
    return oldivar(ivar)->ivar_offset;
}

const char *ivar_getName(Ivar ivar)
{
    return oldivar(ivar)->ivar_name;
}

const char *ivar_getTypeEncoding(Ivar ivar)
{
    return oldivar(ivar)->ivar_type;
}


IMP method_getImplementation(Method m)
{
    if (!m) return NULL;
    return oldmethod(m)->method_imp;
}

SEL method_getName(Method m)
{
    if (!m) return NULL;
    return oldmethod(m)->method_name;
}

const char *method_getTypeEncoding(Method m)
{
    if (!m) return NULL;
    return oldmethod(m)->method_types;
}

unsigned int method_getSizeOfArguments(Method m)
{
    OBJC_WARN_DEPRECATED;
    if (!m) return 0;
    return encoding_getSizeOfArguments(method_getTypeEncoding(m));
}

unsigned int method_getArgumentInfo(Method m, int arg,
                                    const char **type, int *offset)
{
    OBJC_WARN_DEPRECATED;
    if (!m) return 0;
    return encoding_getArgumentInfo(method_getTypeEncoding(m), 
                                    arg, type, offset);
}


static OSSpinLock impLock = OS_SPINLOCK_INIT;

IMP method_setImplementation(Method m_gen, IMP imp)
{
    IMP old;
    struct old_method *m = oldmethod(m_gen);
    if (!m) return NULL;
    if (!imp) return NULL;
    
    if (ignoreSelector(m->method_name)) {
        // Ignored methods stay ignored
        return m->method_imp;
    }

    OSSpinLockLock(&impLock);
    old = m->method_imp;
    m->method_imp = imp;
    OSSpinLockUnlock(&impLock);
    return old;
}


void method_exchangeImplementations(Method m1_gen, Method m2_gen)
{
    IMP m1_imp;
    struct old_method *m1 = oldmethod(m1_gen);
    struct old_method *m2 = oldmethod(m2_gen);
    if (!m1  ||  !m2) return;

    if (ignoreSelector(m1->method_name)  ||  ignoreSelector(m2->method_name)) {
        // Ignored methods stay ignored. Now they're both ignored.
        m1->method_imp = (IMP)&_objc_ignored_method;
        m2->method_imp = (IMP)&_objc_ignored_method;
        return;
    }

    OSSpinLockLock(&impLock);
    m1_imp = m1->method_imp;
    m1->method_imp = m2->method_imp;
    m2->method_imp = m1_imp;
    OSSpinLockUnlock(&impLock);
}


struct objc_method_description * method_getDescription(Method m)
{
    if (!m) return NULL;
    return (struct objc_method_description *)oldmethod(m);
}


const char *property_getName(objc_property_t prop)
{
    return oldproperty(prop)->name;
}

const char *property_getAttributes(objc_property_t prop)
{
    return oldproperty(prop)->attributes;
}

objc_property_attribute_t *property_copyAttributeList(objc_property_t prop, 
                                                      unsigned int *outCount)
{
    if (!prop) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    objc_property_attribute_t *result;
    mutex_lock(&classLock);
    result = copyPropertyAttributeList(oldproperty(prop)->attributes,outCount);
    mutex_unlock(&classLock);
    return result;
}

char * property_copyAttributeValue(objc_property_t prop, const char *name)
{
    if (!prop  ||  !name  ||  *name == '\0') return NULL;
    
    char *result;
    mutex_lock(&classLock);
    result = copyPropertyAttributeValue(oldproperty(prop)->attributes, name);
    mutex_unlock(&classLock);
    return result;    
}


/***********************************************************************
* class_addMethod
**********************************************************************/
static IMP _class_addMethod(Class cls_gen, SEL name, IMP imp, 
                            const char *types, BOOL replace)
{
    struct old_class *cls = oldcls(cls_gen);
    struct old_method *m;
    IMP result = NULL;

    if (!types) types = "";

    mutex_lock(&methodListLock);

    if ((m = _findMethodInClass(cls, name))) {
        // already exists
        // fixme atomic
        result = method_getImplementation((Method)m);
        if (replace) {
            method_setImplementation((Method)m, imp);
        }
    } else {
        // fixme could be faster
        struct old_method_list *mlist = 
            _calloc_internal(sizeof(struct old_method_list), 1);
        mlist->obsolete = fixed_up_method_list;
        mlist->method_count = 1;
        mlist->method_list[0].method_name = name;
        mlist->method_list[0].method_types = _strdup_internal(types);
        if (!ignoreSelector(name)) {
            mlist->method_list[0].method_imp = imp;
        } else {
            mlist->method_list[0].method_imp = (IMP)&_objc_ignored_method;
        }
        
        _objc_insertMethods(cls, mlist, NULL);
        if (!(cls->info & CLS_CONSTRUCTING)) {
            flush_caches((Class)cls, NO);
        } else {
            // in-construction class has no subclasses
            flush_cache((Class)cls);
        }
        result = NULL;
    }

    mutex_unlock(&methodListLock);

    return result;
}


/***********************************************************************
* class_addMethod
**********************************************************************/
BOOL class_addMethod(Class cls, SEL name, IMP imp, const char *types)
{
    IMP old;
    if (!cls) return NO;

    printf("Adding method");
    old = _class_addMethod(cls, name, imp, types, NO);
    return old ? NO : YES;
}


/***********************************************************************
* class_replaceMethod
**********************************************************************/
IMP class_replaceMethod(Class cls, SEL name, IMP imp, const char *types)
{
    if (!cls) return NULL;

    return _class_addMethod(cls, name, imp, types, YES);
}


/***********************************************************************
* class_addIvar
**********************************************************************/
BOOL class_addIvar(Class cls_gen, const char *name, size_t size, 
                   uint8_t alignment, const char *type)
{
    struct old_class *cls = oldcls(cls_gen);
    BOOL result = YES;

    if (!cls) return NO;
    if (ISMETA(cls)) return NO;
    if (!(cls->info & CLS_CONSTRUCTING)) return NO;

    if (!type) type = "";
    if (name  &&  0 == strcmp(name, "")) name = NULL;
    
    mutex_lock(&classLock);

    // Check for existing ivar with this name
    // fixme check superclasses?
    if (cls->ivars) {
        int i;
        for (i = 0; i < cls->ivars->ivar_count; i++) {
            if (0 == strcmp(cls->ivars->ivar_list[i].ivar_name, name)) {
                result = NO;
                break;
            }
        }
    }

    if (result) {
        struct old_ivar_list *old = cls->ivars;
        size_t oldSize;
        int newCount;
        struct old_ivar *ivar;
        size_t alignBytes;
        size_t misalign;
        
        if (old) {
            oldSize = sizeof(struct old_ivar_list) + 
                (old->ivar_count - 1) * sizeof(struct old_ivar);
            newCount = 1 + old->ivar_count;
        } else {
            oldSize = sizeof(struct old_ivar_list) - sizeof(struct old_ivar);
            newCount = 1;
        }

        // allocate new ivar list
        cls->ivars = _calloc_internal(oldSize + sizeof(struct old_ivar), 1);
        if (old) memcpy(cls->ivars, old, oldSize);
        if (old  &&  malloc_size(old)) free(old);
        cls->ivars->ivar_count = newCount;
        ivar = &cls->ivars->ivar_list[newCount-1];

        // set ivar name and type
        ivar->ivar_name = _strdup_internal(name);
        ivar->ivar_type = _strdup_internal(type);

        // align if necessary
        alignBytes = 1 << alignment;
        misalign = cls->instance_size % alignBytes;
        if (misalign) cls->instance_size += (long)(alignBytes - misalign);

        // set ivar offset and increase instance size
        ivar->ivar_offset = (int)cls->instance_size;
        cls->instance_size += (long)size;
    }

    mutex_unlock(&classLock);

    return result;
}


/***********************************************************************
* class_addProtocol
**********************************************************************/
BOOL class_addProtocol(Class cls_gen, Protocol *protocol_gen)
{
    struct old_class *cls = oldcls(cls_gen);
    struct old_protocol *protocol = oldprotocol(protocol_gen);
    struct old_protocol_list *plist;

    if (!cls) return NO;
    if (class_conformsToProtocol(cls_gen, protocol_gen)) return NO;

    mutex_lock(&classLock);

    // fixme optimize - protocol list doesn't escape?
    plist = _calloc_internal(sizeof(struct old_protocol_list), 1);
    plist->count = 1;
    plist->list[0] = protocol;
    plist->next = cls->protocols;
    cls->protocols = plist;

    // fixme metaclass?

    mutex_unlock(&classLock);

    return YES;
}


/***********************************************************************
* _class_addProperties
* Internal helper to add properties to a class. 
* Used by category attachment and  class_addProperty() 
* Locking: acquires classLock
**********************************************************************/
BOOL 
_class_addProperties(struct old_class *cls,
                     struct old_property_list *additions)
{
    struct old_property_list *newlist;

    if (!(cls->info & CLS_EXT)) return NO;

    newlist = 
        _memdup_internal(additions, sizeof(*newlist) - sizeof(newlist->first) 
                         + (additions->entsize * additions->count));

    mutex_lock(&classLock);

    allocateExt(cls);
    if (!cls->ext->propertyLists) {
        // cls has no properties - simply use this list
        cls->ext->propertyLists = (struct old_property_list **)newlist;
        _class_setInfo((Class)cls, CLS_NO_PROPERTY_ARRAY);
    } 
    else if (cls->info & CLS_NO_PROPERTY_ARRAY) {
        // cls has one property list - make a new array
        struct old_property_list **newarray = 
            _malloc_internal(3 * sizeof(*newarray));
        newarray[0] = newlist;
        newarray[1] = (struct old_property_list *)cls->ext->propertyLists;
        newarray[2] = NULL;
        cls->ext->propertyLists = newarray;
        _class_clearInfo((Class)cls, CLS_NO_PROPERTY_ARRAY);
    }
    else {
        // cls has a property array - make a bigger one
        struct old_property_list **newarray;
        int count = 0;
        while (cls->ext->propertyLists[count]) count++;
        newarray = _malloc_internal((count+2) * sizeof(*newarray));
        newarray[0] = newlist;
        memcpy(&newarray[1], &cls->ext->propertyLists[0], 
               count * sizeof(*newarray));
        newarray[count+1] = NULL;
        free(cls->ext->propertyLists);
        cls->ext->propertyLists = newarray;
    }

    mutex_unlock(&classLock);

    return YES;
}


/***********************************************************************
* class_addProperty
* Adds a property to a class. Returns NO if the proeprty already exists.
* Locking: acquires classLock
**********************************************************************/
static BOOL 
_class_addProperty(Class cls_gen, const char *name, 
                   const objc_property_attribute_t *attrs, unsigned int count, 
                   BOOL replace)
{
    struct old_class *cls = oldcls(cls_gen);
    
    if (!cls) return NO;
    if (!name) return NO;

    struct old_property *prop = oldproperty(class_getProperty(cls_gen, name));
    if (prop  &&  !replace) {
        // already exists, refuse to replace
        return NO;
    } 
    else if (prop) {
        // replace existing
        mutex_lock(&classLock);
        try_free(prop->attributes);
        prop->attributes = copyPropertyAttributeString(attrs, count);
        mutex_unlock(&classLock);
        return YES;
    } 
    else {
        // add new
        struct old_property_list proplist;
        proplist.entsize = sizeof(struct old_property);
        proplist.count = 1;
        proplist.first.name = _strdup_internal(name);
        proplist.first.attributes = copyPropertyAttributeString(attrs, count);
        
        return _class_addProperties(cls, &proplist);
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
* class_copyProtocolList.  Returns a heap block containing the 
* protocols implemented by the class, or NULL if the class 
* implements no protocols. Caller must free the block.
* Does not copy any superclass's protocols.
**********************************************************************/
Protocol * __unsafe_unretained *
class_copyProtocolList(Class cls_gen, unsigned int *outCount)
{
    struct old_class *cls = oldcls(cls_gen);
    struct old_protocol_list *plist;
    Protocol **result = NULL;
    unsigned int count = 0;
    unsigned int p;

    if (!cls) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    mutex_lock(&classLock);

    for (plist = cls->protocols; plist != NULL; plist = plist->next) {
        count += (int)plist->count;
    }

    if (count > 0) {
        result = malloc((count+1) * sizeof(Protocol *));
        
        for (p = 0, plist = cls->protocols; 
             plist != NULL; 
             plist = plist->next) 
        {
            int i;
            for (i = 0; i < plist->count; i++) {
                result[p++] = (Protocol *)plist->list[i];
            }
        }
        result[p] = NULL;
    }

    mutex_unlock(&classLock);

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* class_getProperty.  Return the named property.
**********************************************************************/
objc_property_t class_getProperty(Class cls_gen, const char *name)
{
    struct old_property *result;
    struct old_class *cls = oldcls(cls_gen);
    if (!cls  ||  !name) return NULL;

    mutex_lock(&classLock);

    for (result = NULL; cls && !result; cls = cls->super_class) {
        uintptr_t iterator = 0;
        struct old_property_list *plist;
        while ((plist = nextPropertyList(cls, &iterator))) {
            uint32_t i;
            for (i = 0; i < plist->count; i++) {
                struct old_property *p = property_list_nth(plist, i);
                if (0 == strcmp(name, p->name)) {
                    result = p;
                    goto done;
                }
            }
        }
    }

 done:
    mutex_unlock(&classLock);

    return (objc_property_t)result;
}


/***********************************************************************
* class_copyPropertyList. Returns a heap block containing the 
* properties declared in the class, or NULL if the class 
* declares no properties. Caller must free the block.
* Does not copy any superclass's properties.
**********************************************************************/
objc_property_t *class_copyPropertyList(Class cls_gen, unsigned int *outCount)
{
    struct old_class *cls = oldcls(cls_gen);
    struct old_property_list *plist;
    uintptr_t iterator = 0;
    struct old_property **result = NULL;
    unsigned int count = 0;
    unsigned int p, i;

    if (!cls) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    mutex_lock(&classLock);

    iterator = 0;
    while ((plist = nextPropertyList(cls, &iterator))) {
        count += plist->count;
    }

    if (count > 0) {
        result = malloc((count+1) * sizeof(struct old_property *));
        
        p = 0;
        iterator = 0;
        while ((plist = nextPropertyList(cls, &iterator))) {
            for (i = 0; i < plist->count; i++) {
                result[p++] = property_list_nth(plist, i);
            }
        }
        result[p] = NULL;
    }

    mutex_unlock(&classLock);

    if (outCount) *outCount = count;
    return (objc_property_t *)result;
}


/***********************************************************************
* class_copyMethodList.  Returns a heap block containing the 
* methods implemented by the class, or NULL if the class 
* implements no methods. Caller must free the block.
* Does not copy any superclass's methods.
**********************************************************************/
Method *class_copyMethodList(Class cls_gen, unsigned int *outCount)
{
    struct old_class *cls = oldcls(cls_gen);
    struct old_method_list *mlist;
    void *iterator = NULL;
    Method *result = NULL;
    unsigned int count = 0;
    unsigned int m;

    if (!cls) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    mutex_lock(&methodListLock);

    iterator = NULL;
    while ((mlist = nextMethodList(cls, &iterator))) {
        count += mlist->method_count;
    }

    if (count > 0) {
        result = malloc((count+1) * sizeof(Method));
        
        m = 0;
        iterator = NULL;
        while ((mlist = nextMethodList(cls, &iterator))) {
            int i;
            for (i = 0; i < mlist->method_count; i++) {
                Method aMethod = (Method)&mlist->method_list[i];
                if (ignoreSelector(method_getName(aMethod))) {
                    count--;
                    continue;
                }
                result[m++] = aMethod;
            }
        }
        result[m] = NULL;
    }

    mutex_unlock(&methodListLock);

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* class_copyIvarList.  Returns a heap block containing the 
* ivars declared in the class, or NULL if the class 
* declares no ivars. Caller must free the block.
* Does not copy any superclass's ivars.
**********************************************************************/
Ivar *class_copyIvarList(Class cls_gen, unsigned int *outCount)
{
    struct old_class *cls = oldcls(cls_gen);
    Ivar *result = NULL;
    unsigned int count = 0;
    int i;

    if (!cls) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    if (cls->ivars) {
        count = cls->ivars->ivar_count;
    }

    if (count > 0) {
        result = malloc((count+1) * sizeof(Ivar));

        for (i = 0; i < cls->ivars->ivar_count; i++) {
            result[i] = (Ivar)&cls->ivars->ivar_list[i];
        }
        result[i] = NULL;
    }

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* objc_allocateClass.
**********************************************************************/

void set_superclass(struct old_class *cls, struct old_class *supercls, 
                    BOOL cls_is_new)
{
    struct old_class *meta = cls->isa;

    if (supercls) {
        cls->super_class = supercls;
        meta->super_class = supercls->isa;
        meta->isa = supercls->isa->isa;

        // Propagate C++ cdtors from superclass.
        if (supercls->info & CLS_HAS_CXX_STRUCTORS) {
            if (cls_is_new) cls->info |= CLS_HAS_CXX_STRUCTORS;
            else _class_setInfo((Class)cls, CLS_HAS_CXX_STRUCTORS);
        }

        // Superclass is no longer a leaf for cache flushing
        if (supercls->info & CLS_LEAF) {
            _class_clearInfo((Class)supercls, CLS_LEAF);
            _class_clearInfo((Class)supercls->isa, CLS_LEAF);
        }
    } else {
        cls->super_class = Nil;  // superclass of root class is nil
        meta->super_class = cls; // superclass of root metaclass is root class
        meta->isa = meta;      // metaclass of root metaclass is root metaclass

        // Root class is never a leaf for cache flushing, because the 
        // root metaclass is a subclass. (This could be optimized, but 
        // is too uncommon to bother.)
        _class_clearInfo((Class)cls, CLS_LEAF);
        _class_clearInfo((Class)meta, CLS_LEAF);
    }    
}

// &UnsetLayout is the default ivar layout during class construction
static const uint8_t UnsetLayout = 0;

Class objc_initializeClassPair(Class superclass_gen, const char *name, Class cls_gen, Class meta_gen)
{
    struct old_class *supercls = oldcls(superclass_gen);
    struct old_class *cls = oldcls(cls_gen);
    struct old_class *meta = oldcls(meta_gen);
    
    // Connect to superclasses and metaclasses
    cls->isa = meta;
    set_superclass(cls, supercls, YES);

    // Set basic info
    cls->name = _strdup_internal(name);
    meta->name = _strdup_internal(name);
    cls->version = 0;
    meta->version = 7;
    cls->info = CLS_CLASS | CLS_CONSTRUCTING | CLS_EXT | CLS_LEAF;
    meta->info = CLS_META | CLS_CONSTRUCTING | CLS_EXT | CLS_LEAF;

    // Set instance size based on superclass.
    if (supercls) {
        cls->instance_size = supercls->instance_size;
        meta->instance_size = supercls->isa->instance_size;
    } else {
        cls->instance_size = sizeof(struct old_class *);  // just an isa
        meta->instance_size = sizeof(struct old_class);
    }
    
    // No ivars. No methods. Empty cache. No protocols. No layout. Empty ext.
    cls->ivars = NULL;
    cls->methodLists = NULL;
    cls->cache = (Cache)&_objc_empty_cache;
    cls->protocols = NULL;
    cls->ivar_layout = &UnsetLayout;
    cls->ext = NULL;
    allocateExt(cls);
    cls->ext->weak_ivar_layout = &UnsetLayout;

    meta->ivars = NULL;
    meta->methodLists = NULL;
    meta->cache = (Cache)&_objc_empty_cache;
    meta->protocols = NULL;
    meta->ext = NULL;
    
    return cls_gen;
}

Class objc_allocateClassPair(Class superclass_gen, const char *name, 
                             size_t extraBytes)
{
    struct old_class *supercls = oldcls(superclass_gen);
    Class cls, meta;

    if (objc_getClass(name)) return NO;
    // fixme reserve class name against simultaneous allocation

    if (supercls  &&  (supercls->info & CLS_CONSTRUCTING)) {
        // Can't make subclass of an in-construction class
        return NO;
    }

    // Allocate new classes. 
    if (supercls) {
        cls = _calloc_class(_class_getInstanceSize((Class)supercls->isa) + extraBytes);
        meta = _calloc_class(_class_getInstanceSize((Class)supercls->isa->isa) + extraBytes);
    } else {
        cls = _calloc_class(sizeof(struct old_class) + extraBytes);
        meta = _calloc_class(sizeof(struct old_class) + extraBytes);
    }


    objc_initializeClassPair(superclass_gen, name, cls, meta);
    
    return (Class)cls;
}


void objc_registerClassPair(Class cls_gen)
{
    struct old_class *cls = oldcls(cls_gen);

    if ((cls->info & CLS_CONSTRUCTED)  ||  
        (cls->isa->info & CLS_CONSTRUCTED)) 
    {
        _objc_inform("objc_registerClassPair: class '%s' was already "
                     "registered!", cls->name);
        return;
    }

    if (!(cls->info & CLS_CONSTRUCTING)  ||  
        !(cls->isa->info & CLS_CONSTRUCTING)) 
    {
        _objc_inform("objc_registerClassPair: class '%s' was not "
                     "allocated with objc_allocateClassPair!", cls->name);
        return;
    }

    if (ISMETA(cls)) {
        _objc_inform("objc_registerClassPair: class '%s' is a metaclass, "
                     "not a class!", cls->name);
        return;
    }

    mutex_lock(&classLock);

    // Build ivar layouts
    if (UseGC) {
        if (cls->ivar_layout != &UnsetLayout) {
            // Class builder already called class_setIvarLayout.
        }
        else if (!cls->super_class) {
            // Root class. Scan conservatively (should be isa ivar only).
            cls->ivar_layout = NULL;
        }
        else if (cls->ivars == NULL) {
            // No local ivars. Use superclass's layout.
            cls->ivar_layout = 
                _ustrdup_internal(cls->super_class->ivar_layout);
        }
        else {
            // Has local ivars. Build layout based on superclass.
            struct old_class *supercls = cls->super_class;
            const uint8_t *superlayout = 
                class_getIvarLayout((Class)supercls);
            layout_bitmap bitmap = 
                layout_bitmap_create(superlayout, supercls->instance_size, 
                                     cls->instance_size, NO);
            int i;
            for (i = 0; i < cls->ivars->ivar_count; i++) {
                struct old_ivar *iv = &cls->ivars->ivar_list[i];
                layout_bitmap_set_ivar(bitmap, iv->ivar_type, iv->ivar_offset);
            }
            cls->ivar_layout = layout_string_create(bitmap);
            layout_bitmap_free(bitmap);
        }

        if (cls->ext->weak_ivar_layout != &UnsetLayout) {
            // Class builder already called class_setWeakIvarLayout.
        }
        else if (!cls->super_class) {
            // Root class. No weak ivars (should be isa ivar only)
            cls->ext->weak_ivar_layout = NULL;
        }
        else if (cls->ivars == NULL) {
            // No local ivars. Use superclass's layout.
            const uint8_t *weak = 
                class_getWeakIvarLayout((Class)cls->super_class);
            if (weak) {
                cls->ext->weak_ivar_layout = _ustrdup_internal(weak);
            } else {
                cls->ext->weak_ivar_layout = NULL;
            }
        }
        else {
            // Has local ivars. Build layout based on superclass.
            // No way to add weak ivars yet.
            const uint8_t *weak = 
                class_getWeakIvarLayout((Class)cls->super_class);
            if (weak) {
                cls->ext->weak_ivar_layout = _ustrdup_internal(weak);
            } else {
                cls->ext->weak_ivar_layout = NULL;
            }
        }
    }

    // Clear "under construction" bit, set "done constructing" bit
    cls->info &= ~CLS_CONSTRUCTING;
    cls->isa->info &= ~CLS_CONSTRUCTING;
    cls->info |= CLS_CONSTRUCTED;
    cls->isa->info |= CLS_CONSTRUCTED;

    NXHashInsertIfAbsent(class_hash, cls);
    objc_addRegisteredClass((Class)cls);
    //objc_addRegisteredClass(cls->isa);  if we ever allocate classes from GC

    mutex_unlock(&classLock);
}


Class objc_duplicateClass(Class orig_gen, const char *name, size_t extraBytes)
{
    unsigned int count, i;
    struct old_method **originalMethods;
    struct old_method_list *duplicateMethods;
    struct old_class *original = oldcls(orig_gen);
    // Don't use sizeof(struct objc_class) here because 
    // instance_size has historically contained two extra words, 
    // and instance_size is what objc_getIndexedIvars() actually uses.
    struct old_class *duplicate = (struct old_class *)
        _calloc_class(_class_getInstanceSize((Class)original->isa) + extraBytes);

    duplicate->isa = original->isa;
    duplicate->super_class = original->super_class;
    duplicate->name = strdup(name);
    duplicate->version = original->version;
    duplicate->info = original->info & (CLS_CLASS|CLS_META|CLS_INITIALIZED|CLS_JAVA_HYBRID|CLS_JAVA_CLASS|CLS_HAS_CXX_STRUCTORS|CLS_HAS_LOAD_METHOD);
    duplicate->instance_size = original->instance_size;
    duplicate->ivars = original->ivars;
    // methodLists handled below
    duplicate->cache = (Cache)&_objc_empty_cache;
    duplicate->protocols = original->protocols;
    if (original->info & CLS_EXT) {
        duplicate->info |= original->info & (CLS_EXT|CLS_NO_PROPERTY_ARRAY);
        duplicate->ivar_layout = original->ivar_layout;
        if (original->ext) {
            duplicate->ext = _malloc_internal(original->ext->size);
            memcpy(duplicate->ext, original->ext, original->ext->size);
        } else {
            duplicate->ext = NULL;
        }
    }

    // Method lists are deep-copied so they can be stomped.
    originalMethods = (struct old_method **)
        class_copyMethodList(orig_gen, &count);
    if (originalMethods) {
        duplicateMethods = (struct old_method_list *)
            calloc(sizeof(struct old_method_list) + 
                   (count-1)*sizeof(struct old_method), 1);
        duplicateMethods->obsolete = fixed_up_method_list;
        duplicateMethods->method_count = count;
        for (i = 0; i < count; i++) {
            duplicateMethods->method_list[i] = *(originalMethods[i]);
        }
        duplicate->methodLists = (struct old_method_list **)duplicateMethods;
        duplicate->info |= CLS_NO_METHOD_ARRAY;
        free(originalMethods);
    }

    mutex_lock(&classLock);
    NXHashInsert(class_hash, duplicate);
    objc_addRegisteredClass((Class)duplicate);
    mutex_unlock(&classLock);

    return (Class)duplicate;
}


void objc_disposeClassPair(Class cls_gen)
{
    struct old_class *cls = oldcls(cls_gen);

    if (!(cls->info & (CLS_CONSTRUCTED|CLS_CONSTRUCTING))  ||  
        !(cls->isa->info & (CLS_CONSTRUCTED|CLS_CONSTRUCTING))) 
    {
        // class not allocated with objc_allocateClassPair
        // disposing still-unregistered class is OK!
        _objc_inform("objc_disposeClassPair: class '%s' was not "
                     "allocated with objc_allocateClassPair!", cls->name);
        return;
    }

    if (ISMETA(cls)) {
        _objc_inform("objc_disposeClassPair: class '%s' is a metaclass, "
                     "not a class!", cls->name);
        return;
    }

    mutex_lock(&classLock);
    NXHashRemove(class_hash, cls);
    objc_removeRegisteredClass((Class)cls);
    unload_class(cls->isa);
    unload_class(cls);
    mutex_unlock(&classLock);
}



/***********************************************************************
* _class_createInstanceFromZone.  Allocate an instance of the
* specified class with the specified number of bytes for indexed
* variables, in the specified zone.  The isa field is set to the
* class, C++ default constructors are called, and all other fields are zeroed.
**********************************************************************/
id 
_class_createInstanceFromZone(Class cls, size_t extraBytes, void *zone)
{
    id obj;
    size_t size;

    // Can't create something for nothing
    if (!cls) return nil;

    // Allocate and initialize
    size = _class_getInstanceSize(cls) + extraBytes;

    // CF requires all objects be at least 16 bytes.
    if (size < 16) size = 16;

#if SUPPORT_GC
    if (UseGC) {
        obj = (id)auto_zone_allocate_object(gc_zone, size,
                                            AUTO_OBJECT_SCANNED, 0, 1);
    } else 
#endif
    if (zone) {
        obj = (id)malloc_zone_calloc (zone, 1, size);
    } else {
        obj = (id)calloc(1, size);
    }
    if (!obj) return nil;

    obj->isa = cls;

    if (_class_hasCxxStructors(cls)) {
        obj = _objc_constructOrFree(cls, obj);
    }

    return obj;
}


/***********************************************************************
* _class_createInstance.  Allocate an instance of the specified
* class with the specified number of bytes for indexed variables, in
* the default zone, using _class_createInstanceFromZone.
**********************************************************************/
static id _class_createInstance(Class cls, size_t extraBytes)
{
    return _class_createInstanceFromZone (cls, extraBytes, NULL);
}


static id _object_copyFromZone(id oldObj, size_t extraBytes, void *zone) 
{
    id obj;
    size_t size;

    if (!oldObj) return nil;

    obj = (*_zoneAlloc)(oldObj->isa, extraBytes, zone);
    size = _class_getInstanceSize(oldObj->isa) + extraBytes;
    
    // fixme need C++ copy constructor
    objc_memmove_collectable(obj, oldObj, size);
    
#if SUPPORT_GC
    if (UseGC) gc_fixup_weakreferences(obj, oldObj);
#endif
    
    return obj;
}


/***********************************************************************
* objc_destructInstance
* Destroys an instance without freeing memory. 
* Calls C++ destructors.
* Removes associative references.
* Returns `obj`. Does nothing if `obj` is nil.
* Be warned that GC DOES NOT CALL THIS. If you edit this, also edit finalize.
* CoreFoundation and other clients do call this under GC.
**********************************************************************/
void *objc_destructInstance(id obj) 
{
    if (obj) {
        Class isa = _object_getClass(obj);

        if (_class_hasCxxStructors(isa)) {
            object_cxxDestruct(obj);
        }

        if (_class_instancesHaveAssociatedObjects(isa)) {
            _object_remove_assocations(obj);
        }

        if (!UseGC) objc_clear_deallocating(obj);
    }

    return obj;
}

static id 
_object_dispose(id anObject) 
{
    if (anObject==nil) return nil;

    objc_destructInstance(anObject);
    
#if SUPPORT_GC
    if (UseGC) {
        auto_zone_retain(gc_zone, anObject); // gc free expects rc==1
    } else 
#endif
    {
        // only clobber isa for non-gc
        anObject->isa = _objc_getFreedObjectClass (); 
    }
    free(anObject);
    return nil;
}

static id _object_copy(id oldObj, size_t extraBytes) 
{
    void *z = malloc_zone_from_ptr(oldObj);
    return _object_copyFromZone(oldObj, extraBytes,
					 z ? z : malloc_default_zone());
}

static id _object_reallocFromZone(id anObject, size_t nBytes, 
                                           void *zone) 
{
    id newObject; 
    Class tmp;

    if (anObject == nil)
        __objc_error(nil, "reallocating nil object");

    if (anObject->isa == _objc_getFreedObjectClass ())
        __objc_error(anObject, "reallocating freed object");

    if (nBytes < _class_getInstanceSize(anObject->isa))
        __objc_error(anObject, "(%s, %zu) requested size too small", 
                     object_getClassName(anObject), nBytes);

    // fixme need C++ copy constructor
    // fixme GC copy
    // Make sure not to modify space that has been declared free
    tmp = anObject->isa; 
    anObject->isa = _objc_getFreedObjectClass ();
    newObject = (id)malloc_zone_realloc(zone, anObject, nBytes);
    if (newObject) {
        newObject->isa = tmp;
    } else {
        // realloc failed, anObject is still alive
        anObject->isa = tmp;
    }
    return newObject;
}


static id _object_realloc(id anObject, size_t nBytes) 
{
    void *z = malloc_zone_from_ptr(anObject);
    return _object_reallocFromZone(anObject,
					    nBytes,
					    z ? z : malloc_default_zone());
}

id (*_alloc)(Class, size_t) = _class_createInstance;
id (*_copy)(id, size_t) = _object_copy;
id (*_realloc)(id, size_t) = _object_realloc;
id (*_dealloc)(id) = _object_dispose;
id (*_zoneAlloc)(Class, size_t, void *) = _class_createInstanceFromZone;
id (*_zoneCopy)(id, size_t, void *) = _object_copyFromZone;
id (*_zoneRealloc)(id, size_t, void *) = _object_reallocFromZone;
void (*_error)(id, const char *, va_list) = _objc_error;


id class_createInstance(Class cls, size_t extraBytes)
{
    if (UseGC) {
        return _class_createInstance(cls, extraBytes);
    } else {
        return (*_alloc)(cls, extraBytes);
    }
}

id class_createInstanceFromZone(Class cls, size_t extraBytes, void *z)
{
    OBJC_WARN_DEPRECATED;
    if (UseGC) {
        return _class_createInstanceFromZone(cls, extraBytes, z);
    } else {
        return (*_zoneAlloc)(cls, extraBytes, z);
    }
}

unsigned class_createInstances(Class cls, size_t extraBytes, 
                               id *results, unsigned num_requested)
{
    if (UseGC  ||  _alloc == &_class_createInstance) {
        return _class_createInstancesFromZone(cls, extraBytes, NULL, 
                                              results, num_requested);
    } else {
        // _alloc in use, which isn't understood by the batch allocator
        return 0;
    }
}

id object_copy(id obj, size_t extraBytes) 
{
    if (UseGC) return _object_copy(obj, extraBytes);
    else return (*_copy)(obj, extraBytes); 
}

id object_copyFromZone(id obj, size_t extraBytes, void *z) 
{
    OBJC_WARN_DEPRECATED;
    if (UseGC) return _object_copyFromZone(obj, extraBytes, z);
    else return (*_zoneCopy)(obj, extraBytes, z); 
}

id object_dispose(id obj) 
{
    if (UseGC) return _object_dispose(obj);
    else return (*_dealloc)(obj); 
}

id object_realloc(id obj, size_t nBytes) 
{
    OBJC_WARN_DEPRECATED;
    if (UseGC) return _object_realloc(obj, nBytes);
    else return (*_realloc)(obj, nBytes); 
}

id object_reallocFromZone(id obj, size_t nBytes, void *z) 
{
    OBJC_WARN_DEPRECATED;
    if (UseGC) return _object_reallocFromZone(obj, nBytes, z);
    else return (*_zoneRealloc)(obj, nBytes, z); 
}


// ProKit SPI
Class class_setSuperclass(Class cls, Class newSuper)
{
    Class oldSuper = cls->super_class;
    set_superclass(oldcls(cls), oldcls(newSuper), NO);
    flush_caches(cls, YES);
    return oldSuper;
}
#endif
