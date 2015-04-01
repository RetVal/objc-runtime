/*
 * Copyright (c) 2005-2007 Apple Inc.  All Rights Reserved.
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

#ifndef _OBJC_RUNTIME_NEW_H
#define _OBJC_RUNTIME_NEW_H

__BEGIN_DECLS

// We cannot store flags in the low bits of the 'data' field until we work with
// the 'leaks' team to not think that objc is leaking memory. See radar 8955342
// for more info.
#define CLASS_FAST_FLAGS_VIA_RW_DATA 0


// Values for class_ro_t->flags
// These are emitted by the compiler and are part of the ABI. 
// class is a metaclass
#define RO_META               (1<<0)
// class is a root class
#define RO_ROOT               (1<<1)
// class has .cxx_construct/destruct implementations
#define RO_HAS_CXX_STRUCTORS  (1<<2)
// class has +load implementation
// #define RO_HAS_LOAD_METHOD    (1<<3)
// class has visibility=hidden set
#define RO_HIDDEN             (1<<4)
// class has attribute(objc_exception): OBJC_EHTYPE_$_ThisClass is non-weak
#define RO_EXCEPTION          (1<<5)
// this bit is available for reassignment
// #define RO_REUSE_ME           (1<<6) 
// class compiled with -fobjc-arc (automatic retain/release)
#define RO_IS_ARR             (1<<7)

// class is in an unloadable bundle - must never be set by compiler
#define RO_FROM_BUNDLE        (1<<29)
// class is unrealized future class - must never be set by compiler
#define RO_FUTURE             (1<<30)
// class is realized - must never be set by compiler
#define RO_REALIZED           (1<<31)

// Values for class_rw_t->flags
// These are not emitted by the compiler and are never used in class_ro_t. 
// Their presence should be considered in future ABI versions.
// class_t->data is class_rw_t, not class_ro_t
#define RW_REALIZED           (1<<31)
// class is unresolved future class
#define RW_FUTURE             (1<<30)
// class is initialized
#define RW_INITIALIZED        (1<<29)
// class is initializing
#define RW_INITIALIZING       (1<<28)
// class_rw_t->ro is heap copy of class_ro_t
#define RW_COPIED_RO          (1<<27)
// class allocated but not yet registered
#define RW_CONSTRUCTING       (1<<26)
// class allocated and registered
#define RW_CONSTRUCTED        (1<<25)
// GC:  class has unsafe finalize method
#define RW_FINALIZE_ON_MAIN_THREAD (1<<24)
// class +load has been called
#define RW_LOADED             (1<<23)
// class does not share super's vtable
#define RW_SPECIALIZED_VTABLE (1<<22)
// class instances may have associative references
#define RW_INSTANCES_HAVE_ASSOCIATED_OBJECTS (1<<21)
// class or superclass has .cxx_construct/destruct implementations
#define RW_HAS_CXX_STRUCTORS  (1<<20)
// class has instance-specific GC layout
#define RW_HAS_INSTANCE_SPECIFIC_LAYOUT (1 << 19)
// class's method list is an array of method lists
#define RW_METHOD_ARRAY       (1<<18)

#if !CLASS_FAST_FLAGS_VIA_RW_DATA
    // class or superclass has custom retain/release/autorelease/retainCount
#   define RW_HAS_CUSTOM_RR      (1<<17)
    // class or superclass has custom allocWithZone: implementation
#   define RW_HAS_CUSTOM_AWZ     (1<<16)
#endif

// classref_t is unremapped class_t*
typedef struct classref * classref_t;

struct method_t {
    SEL name;
    const char *types;
    IMP imp;

    struct SortBySELAddress :
        public std::binary_function<const method_t&,
                                    const method_t&, bool>
    {
        bool operator() (const method_t& lhs,
                         const method_t& rhs)
        { return lhs.name < rhs.name; }
    };
};

typedef struct method_list_t {
    uint32_t entsize_NEVER_USE;  // high bits used for fixup markers
    uint32_t count;
    method_t first;

    uint32_t getEntsize() const { 
        return entsize_NEVER_USE & ~(uint32_t)3; 
    }
    uint32_t getCount() const { 
        return count; 
    }
    method_t& get(uint32_t i) const { 
        return *(method_t *)((uint8_t *)&first + i*getEntsize()); 
    }

    // iterate methods, taking entsize into account
    // fixme need a proper const_iterator
    struct method_iterator {
        uint32_t entsize;
        uint32_t index;  // keeping track of this saves a divide in operator-
        method_t* method;

        typedef std::random_access_iterator_tag iterator_category;
        typedef method_t value_type;
        typedef ptrdiff_t difference_type;
        typedef method_t* pointer;
        typedef method_t& reference;

        method_iterator() { }

        method_iterator(const method_list_t& mlist, uint32_t start = 0)
            : entsize(mlist.getEntsize())
            , index(start)
            , method(&mlist.get(start))
        { }

        const method_iterator& operator += (ptrdiff_t delta) {
            method = (method_t*)((uint8_t *)method + delta*entsize);
            index += (int32_t)delta;
            return *this;
        }
        const method_iterator& operator -= (ptrdiff_t delta) {
            method = (method_t*)((uint8_t *)method - delta*entsize);
            index -= (int32_t)delta;
            return *this;
        }
        const method_iterator operator + (ptrdiff_t delta) const {
            return method_iterator(*this) += delta;
        }
        const method_iterator operator - (ptrdiff_t delta) const {
            return method_iterator(*this) -= delta;
        }

        method_iterator& operator ++ () { *this += 1; return *this; }
        method_iterator& operator -- () { *this -= 1; return *this; }
        method_iterator operator ++ (int) {
            method_iterator result(*this); *this += 1; return result;
        }
        method_iterator operator -- (int) {
            method_iterator result(*this); *this -= 1; return result;
        }

        ptrdiff_t operator - (const method_iterator& rhs) const {
            return (ptrdiff_t)this->index - (ptrdiff_t)rhs.index;
        }

        method_t& operator * () const { return *method; }
        method_t* operator -> () const { return method; }

        operator method_t& () const { return *method; }

        bool operator == (const method_iterator& rhs) {
            return this->method == rhs.method;
        }
        bool operator != (const method_iterator& rhs) {
            return this->method != rhs.method;
        }

        bool operator < (const method_iterator& rhs) {
            return this->method < rhs.method;
        }
        bool operator > (const method_iterator& rhs) {
            return this->method > rhs.method;
        }
    };

    method_iterator begin() const { return method_iterator(*this, 0); }
    method_iterator end() const { return method_iterator(*this, getCount()); }

} method_list_t;

typedef struct ivar_t {
    // *offset is 64-bit by accident even though other 
    // fields restrict total instance size to 32-bit. 
    uintptr_t *offset;
    const char *name;
    const char *type;
    // alignment is sometimes -1; use ivar_alignment() instead
    uint32_t alignment  __attribute__((deprecated));
    uint32_t size;
} ivar_t;

typedef struct ivar_list_t {
    uint32_t entsize;
    uint32_t count;
    ivar_t first;
} ivar_list_t;

typedef struct objc_property {
    const char *name;
    const char *attributes;
} property_t;

typedef struct property_list_t {
    uint32_t entsize;
    uint32_t count;
    property_t first;
} property_list_t;

typedef uintptr_t protocol_ref_t;  // protocol_t *, but unremapped

typedef struct protocol_t {
    id isa;
    const char *name;
    struct protocol_list_t *protocols;
    method_list_t *instanceMethods;
    method_list_t *classMethods;
    method_list_t *optionalInstanceMethods;
    method_list_t *optionalClassMethods;
    property_list_t *instanceProperties;
    uint32_t size;   // sizeof(protocol_t)
    uint32_t flags;
    const char **extendedMethodTypes;

    bool hasExtendedMethodTypesField() const {
        return size >= (offsetof(protocol_t, extendedMethodTypes) 
                        + sizeof(extendedMethodTypes));
    }
    bool hasExtendedMethodTypes() const {
        return hasExtendedMethodTypesField() && extendedMethodTypes;
    }
} protocol_t;

typedef struct protocol_list_t {
    // count is 64-bit by accident. 
    uintptr_t count;
    protocol_ref_t list[0]; // variable-size
} protocol_list_t;

typedef struct class_ro_t {
    uint32_t flags;
    uint32_t instanceStart;
    uint32_t instanceSize;
#ifdef __LP64__
    uint32_t reserved;
#endif

    const uint8_t * ivarLayout;
    
    const char * name;
    const method_list_t * baseMethods;
    const protocol_list_t * baseProtocols;
    const ivar_list_t * ivars;

    const uint8_t * weakIvarLayout;
    const property_list_t *baseProperties;
} class_ro_t;

typedef struct class_rw_t {
    uint32_t flags;
    uint32_t version;

    const class_ro_t *ro;

    union {
        method_list_t **method_lists;  // RW_METHOD_ARRAY == 1
        method_list_t *method_list;    // RW_METHOD_ARRAY == 0
    };
    struct chained_property_list *properties;
    const protocol_list_t ** protocols;

    struct class_t *firstSubclass;
    struct class_t *nextSiblingClass;
} class_rw_t;

typedef struct class_t {
    struct class_t *isa;
    struct class_t *superclass;
    Cache cache;
    IMP *vtable;
    uintptr_t data_NEVER_USE;  // class_rw_t * plus custom rr/alloc flags

    class_rw_t *data() const { 
        return (class_rw_t *)(data_NEVER_USE & ~(uintptr_t)3); 
    }
    void setData(class_rw_t *newData) {
        uintptr_t flags = (uintptr_t)data_NEVER_USE & (uintptr_t)3;
        data_NEVER_USE = (uintptr_t)newData | flags;
    }

    bool hasCustomRR() const {
#if CLASS_FAST_FLAGS_VIA_RW_DATA
        return data_NEVER_USE & (uintptr_t)1;
#else
        return data()->flags & RW_HAS_CUSTOM_RR;
#endif
    }
    void setHasCustomRR(bool inherited = false);

    bool hasCustomAWZ() const {
#if CLASS_FAST_FLAGS_VIA_RW_DATA
        return data_NEVER_USE & (uintptr_t)2;
#else
        return data()->flags & RW_HAS_CUSTOM_AWZ;
#endif
    }
    void setHasCustomAWZ(bool inherited = false);

    bool isRootClass() const {
        return superclass == NULL;
    }
    bool isRootMetaclass() const {
        return isa == this;
    }
} class_t;

typedef struct category_t {
    const char *name;
    classref_t cls;
    struct method_list_t *instanceMethods;
    struct method_list_t *classMethods;
    struct protocol_list_t *protocols;
    struct property_list_t *instanceProperties;
} category_t;

struct objc_super2 {
    id receiver;
    Class current_class;
};

typedef struct {
    IMP imp;
    SEL sel;
} message_ref_t;


__END_DECLS

#endif
