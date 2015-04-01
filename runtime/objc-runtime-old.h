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

#ifndef _OBJC_RUNTIME_OLD_H
#define _OBJC_RUNTIME_OLD_H

#include "objc-private.h"
#include "objc-file-old.h"


struct old_class {
    struct old_class *isa;
    struct old_class *super_class;
    const char *name;
    long version;
    long info;
    long instance_size;
    struct old_ivar_list *ivars;
    struct old_method_list **methodLists;
    Cache cache;
    struct old_protocol_list *protocols;
    // CLS_EXT only
    const uint8_t *ivar_layout;
    struct old_class_ext *ext;
};

struct old_class_ext {
    uint32_t size;
    const uint8_t *weak_ivar_layout;
    struct old_property_list **propertyLists;
};

struct old_category {
    char *category_name;
    char *class_name;
    struct old_method_list *instance_methods;
    struct old_method_list *class_methods;
    struct old_protocol_list *protocols;
    uint32_t size;
    struct old_property_list *instance_properties;
};

struct old_ivar {
    char *ivar_name;
    char *ivar_type;
    int ivar_offset;
#ifdef __LP64__
    int space;
#endif
};

struct old_ivar_list {
    int ivar_count;
#ifdef __LP64__
    int space;
#endif
    /* variable length structure */
    struct old_ivar ivar_list[1];
};


struct old_method {
    SEL method_name;
    char *method_types;
    IMP method_imp;
};

struct old_method_list {
    struct old_method_list *obsolete;

    int method_count;
#ifdef __LP64__
    int space;
#endif
    /* variable length structure */
    struct old_method method_list[1];
};

struct old_protocol {
    Class isa;
    const char *protocol_name;
    struct old_protocol_list *protocol_list;
    struct objc_method_description_list *instance_methods;
    struct objc_method_description_list *class_methods;
};

struct old_protocol_list {
    struct old_protocol_list *next;
    long count;
    struct old_protocol *list[1];
};

struct old_protocol_ext {
    uint32_t size;
    struct objc_method_description_list *optional_instance_methods;
    struct objc_method_description_list *optional_class_methods;
    struct old_property_list *instance_properties;
    const char **extendedMethodTypes;
};


struct old_property {
    const char *name;
    const char *attributes;
};

struct old_property_list {
    uint32_t entsize;
    uint32_t count;
    struct old_property first;
};


#define CLS_CLASS		0x1
#define CLS_META		0x2
#define CLS_INITIALIZED		0x4
#define CLS_POSING		0x8
#define CLS_MAPPED		0x10
#define CLS_FLUSH_CACHE		0x20
#define CLS_GROW_CACHE		0x40
#define CLS_NEED_BIND		0x80
#define CLS_METHOD_ARRAY        0x100
// the JavaBridge constructs classes with these markers
#define CLS_JAVA_HYBRID		0x200
#define CLS_JAVA_CLASS		0x400
// thread-safe +initialize
#define CLS_INITIALIZING	0x800
// bundle unloading
#define CLS_FROM_BUNDLE		0x1000
// C++ ivar support
#define CLS_HAS_CXX_STRUCTORS	0x2000
// Lazy method list arrays
#define CLS_NO_METHOD_ARRAY	0x4000
// +load implementation
#define CLS_HAS_LOAD_METHOD     0x8000
// objc_allocateClassPair API
#define CLS_CONSTRUCTING        0x10000
// visibility=hidden
#define CLS_HIDDEN              0x20000
// GC:  class has unsafe finalize method
#define CLS_FINALIZE_ON_MAIN_THREAD 0x40000
// Lazy property list arrays
#define CLS_NO_PROPERTY_ARRAY	0x80000
// +load implementation
#define CLS_CONNECTED           0x100000
#define CLS_LOADED              0x200000
// objc_allocateClassPair API
#define CLS_CONSTRUCTED         0x400000
// class is leaf for cache flushing
#define CLS_LEAF                0x800000
// class instances may have associative references
#define CLS_INSTANCES_HAVE_ASSOCIATED_OBJECTS 0x1000000
// class has instance-specific GC layout
#define CLS_HAS_INSTANCE_SPECIFIC_LAYOUT 0x2000000


// Terminator for array of method lists
#define END_OF_METHODS_LIST ((struct old_method_list*)-1)

#define ISCLASS(cls)		(((cls)->info & CLS_CLASS) != 0)
#define ISMETA(cls)		(((cls)->info & CLS_META) != 0)
#define GETMETA(cls)		(ISMETA(cls) ? (cls) : (cls)->isa)


__BEGIN_DECLS

#define oldcls(cls) ((struct old_class *)cls)
#define oldprotocol(proto) ((struct old_protocol *)proto)
#define oldmethod(meth) ((struct old_method *)meth)
#define oldcategory(cat) ((struct old_category *)cat)
#define oldivar(ivar) ((struct old_ivar *)ivar)
#define oldproperty(prop) ((struct old_property *)prop)

extern void unload_class(struct old_class *cls);

extern Class objc_getOrigClass (const char *name);
extern IMP lookupNamedMethodInMethodList(struct old_method_list *mlist, const char *meth_name);
extern void _objc_insertMethods(struct old_class *cls, struct old_method_list *mlist, struct old_category *cat);
extern void _objc_removeMethods(struct old_class *cls, struct old_method_list *mlist);
extern void _objc_flush_caches (Class cls);
extern BOOL _class_addProperties(struct old_class *cls, struct old_property_list *additions);
extern void change_class_references(struct old_class *imposter, struct old_class *original, struct old_class *copy, BOOL changeSuperRefs);
extern void flush_marked_caches(void);
extern void set_superclass(struct old_class *cls, struct old_class *supercls, BOOL cls_is_new);
extern void try_free(const void *p);

extern struct old_property *property_list_nth(const struct old_property_list *plist, uint32_t i);
extern struct old_property **copyPropertyList(struct old_property_list *plist, unsigned int *outCount);

extern void _class_setInfo(Class cls, long set);
extern void _class_clearInfo(Class cls, long clear);
extern void _class_changeInfo(Class cls, long set, long clear);


// used by flush_caches outside objc-cache.m
extern void _cache_flush(Class cls);
#ifdef OBJC_INSTRUMENTED
extern unsigned int LinearFlushCachesCount;
extern unsigned int LinearFlushCachesVisitedCount;
extern unsigned int MaxLinearFlushCachesVisitedCount;
extern unsigned int NonlinearFlushCachesCount;
extern unsigned int NonlinearFlushCachesClassCount;
extern unsigned int NonlinearFlushCachesVisitedCount;
extern unsigned int MaxNonlinearFlushCachesVisitedCount;
extern unsigned int IdealFlushCachesCount;
extern unsigned int MaxIdealFlushCachesCount;
#endif

__END_DECLS

#endif
