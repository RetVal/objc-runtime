// TEST_CONFIG
// TEST_CFLAGS -framework Foundation

#include "test.h"
#include "class-structures.h"
#include <Foundation/Foundation.h>
#include <mach-o/dyld_priv.h>

// Redeclare the headerinfo RW structs so we can look up loaded/unloaded status.
typedef struct header_info_rw {
#ifdef __LP64__
    uintptr_t isLoaded                : 1;
    [[maybe_unused]] uintptr_t unused : 1;
    uintptr_t next                    : 62;
#else
    uintptr_t isLoaded                : 1;
    [[maybe_unused]] uintptr_t unused : 1;
    uintptr_t next                    : 30;
#endif
} header_info_rw;

struct objc_headeropt_rw_t {
    uint32_t count;
    uint32_t entsize;
    header_info_rw headers[0];  // sorted by mhdr address
};

extern struct objc_headeropt_rw_t *objc_debug_headerInfoRWs;

// =======================
// List-of-list utilities.
// =======================

// Struct representing an entry in a relative list-of-lists. When initialized
// inline, it can generate the relative offset to the target pointer.
struct ListOfListsEntry {
    union {
        struct {
            uint32_t entsizeAndFlags;
            uint32_t count;
        };
        struct {
            uint64_t imageIndex: 16;
            int64_t listOffset: 48;
        };
    };

    ListOfListsEntry(uint32_t count) :
        entsizeAndFlags(sizeof(uint64_t)), count(count) {}

    ListOfListsEntry(void *target, uint16_t imageIndex) :
        imageIndex(imageIndex), listOffset((intptr_t)target - (intptr_t)this) {}
};

// Find the index of an image that's either loaded or unloaded, as requested.
uint16_t findImageIndex(bool loaded) {
    uint32_t i = 0;
    while (true) {
        if (i >= objc_debug_headerInfoRWs->count)
            fail("Could not find a%sloaded image index before the end of the array!", loaded ? " " : "n un");
        if (objc_debug_headerInfoRWs->headers[i].isLoaded == loaded)
            return i;
        i++;
    }
}

// Image indexes to use in our test lists.
uint16_t testLoadedImageIndex = 0x10ad;
uint16_t testUnloadedImageIndex = 0xdead;

void FixupListOfListsImageIndexes(ListOfListsEntry *list) {
    uint16_t realLoadedIndex = findImageIndex(true);
    uint16_t realUnloadedIndex = findImageIndex(false);
    for (uint32_t i = 1; i <= list[0].count; i++) {
        if (list[i].imageIndex == testLoadedImageIndex)
            list[i].imageIndex = realLoadedIndex;
        else if (list[i].imageIndex == testUnloadedImageIndex)
            list[i].imageIndex = realUnloadedIndex;
        else
            fail("Unknown unfixed image index %u", list[i].imageIndex);
    }
}


// ====================================
// Method lists used by our test class.
// ====================================

// We can only use selectors that are in the shared cache, otherwise the runtime
// assumes we can never find a match in a relative list. Define these selectors
// to things we know are always in the shared cache. It doesn't really matter
// what, as long as they're unique and always in the shared cache, and don't
// exist in NSObject. We use NSString selectors for no particular reason.

SEL onlyInMainListSEL = @selector(length);
SEL onlyInLoadedCategorySEL = @selector(doubleValue);
SEL inMainListAndLoadedCategorySEL = @selector(floatValue);
SEL onlyInUnloadedCategorySEL = @selector(intValue);
SEL inMainOverriddenAtRuntimeSEL = @selector(integerValue);
SEL inCategoryOverriddenAtRuntimeSEL = @selector(longLongValue);

SELREF(length)
SELREF(doubleValue)
SELREF(floatValue)
SELREF(intValue)
SELREF(integerValue)
SELREF(longLongValue)

const char *emptyString = "";

SMALL_METHOD_LIST(TestClassMethodList, 3,
    SMALL_METHOD(length, emptyString, onlyInMainList)
    SMALL_METHOD(floatValue, emptyString, inMainListAndLoadedCategory_main)
    SMALL_METHOD(integerValue, emptyString, inMainOverriddenAtRuntime)
)

SMALL_METHOD_LIST(TestClassCategoryMethodList, 3,
    SMALL_METHOD(doubleValue, emptyString, onlyInLoadedCategory)
    SMALL_METHOD(floatValue, emptyString, inMainListAndLoadedCategory_category)
    SMALL_METHOD(longLongValue, emptyString, inCategoryOverriddenAtRuntime)
)

SMALL_METHOD_LIST(TestClassUnloadedCategoryMethodList, 3,
    SMALL_METHOD(doubleValue, emptyString, unloadedCategoryMethod)
    SMALL_METHOD(floatValue, emptyString, unloadedCategoryMethod)
    SMALL_METHOD(intValue, emptyString, unloadedCategoryMethod)
)

ListOfListsEntry TestClassListOfMethodLists[] = {
    {5},

    {&TestClassUnloadedCategoryMethodList, testUnloadedImageIndex},
    {&TestClassCategoryMethodList, testLoadedImageIndex},
    {&TestClassUnloadedCategoryMethodList, testUnloadedImageIndex},
    {&TestClassUnloadedCategoryMethodList, testUnloadedImageIndex},
    {&TestClassMethodList, testLoadedImageIndex},
};


// ======================================
// Protocol lists used by our test class.
// ======================================

@protocol OnlyInMain
@end
@protocol InMainAndCategory
@end
@protocol OnlyInCategory
@end
@protocol OnlyInUnloadedCategory
@end
@protocol RuntimeAdded
@end

uintptr_t TestClassProtocolList[] = {
    // Count.
    2,

    (uintptr_t)@protocol(OnlyInMain),
    (uintptr_t)@protocol(InMainAndCategory),
};

uintptr_t TestClassCategoryProtocolList[] = {
    // Count.
    2,

    (uintptr_t)@protocol(OnlyInCategory),
    (uintptr_t)@protocol(InMainAndCategory),
};

uintptr_t TestClassUnloadedCategoryProtocolList[] = {
    // Count.
    1,

    (uintptr_t)@protocol(OnlyInUnloadedCategory),
};

ListOfListsEntry TestClassListOfProtocolLists[] = {
    {5},

    {&TestClassUnloadedCategoryProtocolList, testUnloadedImageIndex},
    {&TestClassCategoryProtocolList, testLoadedImageIndex},
    {&TestClassUnloadedCategoryProtocolList, testUnloadedImageIndex},
    {&TestClassUnloadedCategoryProtocolList, testUnloadedImageIndex},
    {&TestClassProtocolList, testLoadedImageIndex},
};


// ======================================
// Property lists used by our test class.
// ======================================
#if __LP64__
#define PROPERTY_LIST_COUNT_AND_SIZE(count) \
    ((uintptr_t)count << 32) | (2 * sizeof(void *))
#else
#define PROPERTY_LIST_COUNT_AND_SIZE(count) \
    2 * sizeof(void *), count
#endif

uintptr_t TestClassPropertyList[] = {
    PROPERTY_LIST_COUNT_AND_SIZE(2),

    (uintptr_t)"onlyInMain",
    (uintptr_t)"Ti,D",
    (uintptr_t)"inMainAndCategory",
    (uintptr_t)"Ti,D",
};

uintptr_t TestClassCategoryPropertyList[] = {
    PROPERTY_LIST_COUNT_AND_SIZE(2),

    (uintptr_t)"onlyInCategory",
    (uintptr_t)"Ti,D",
    (uintptr_t)"inMainAndCategory",
    (uintptr_t)"Ti,D",
};

uintptr_t TestClassUnloadedCategoryPropertyList[] = {
    PROPERTY_LIST_COUNT_AND_SIZE(1),

    (uintptr_t)"onlyInUnloadedCategory",
    (uintptr_t)"Ti,D",
};

ListOfListsEntry TestClassListOfPropertyLists[] = {
    {5},

    {&TestClassUnloadedCategoryPropertyList, testUnloadedImageIndex},
    {&TestClassCategoryPropertyList, testLoadedImageIndex},
    {&TestClassUnloadedCategoryPropertyList, testUnloadedImageIndex},
    {&TestClassUnloadedCategoryPropertyList, testUnloadedImageIndex},
    {&TestClassPropertyList, testLoadedImageIndex},
};


// ==========================================================================
// Our test class itself. We write out all the structures manually so that we
// can use the list-of-lists representation for its methods, protocols, and
// properties.
// ==========================================================================

struct ObjCClass_ro TestClassMeta_ro = {
    .flags = RO_META,
    .instanceStart = 40,
    .instanceSize = 40,
};

struct ObjCClass TestClassMeta = {
    .isa = &OBJC_METACLASS_$_NSObject,
    .superclass = &OBJC_METACLASS_$_NSObject,
    .cachePtr = &_objc_empty_cache,
    .data = &TestClassMeta_ro,
};

struct ObjCClass_ro TestClass_ro = {
    .instanceStart = sizeof(void *),
    .instanceSize = sizeof(void *),
    .name = "TestClass",
    .baseMethodList = (struct ObjCMethodList *)((uintptr_t)&TestClassListOfMethodLists + 1),
    .baseProtocols = (struct protocol_list_t *)((uintptr_t)&TestClassListOfProtocolLists + 1),
    .baseProperties = (struct property_list_t *)((uintptr_t)&TestClassListOfPropertyLists + 1),
};

struct ObjCClass TestClass = {
    .isa = &TestClassMeta,
    .superclass = &OBJC_CLASS_$_NSObject,
    .cachePtr = &_objc_empty_cache,
    .data = &TestClass_ro,
};


// ==========================================================================
// Method implementations. Return separate values for each one to verify that
// the correct implementation is being invoked.
// ==========================================================================

#define METHOD_IMPLEMENTATION(name)                                  \
    EXTERN_C const char *name(id self __unused, SEL _cmd __unused) { \
        return #name;                                                \
    }

METHOD_IMPLEMENTATION(onlyInMainList)
METHOD_IMPLEMENTATION(onlyInLoadedCategory)
METHOD_IMPLEMENTATION(inMainListAndLoadedCategory_main)
METHOD_IMPLEMENTATION(inMainListAndLoadedCategory_category)
METHOD_IMPLEMENTATION(inMainOverriddenAtRuntime)
METHOD_IMPLEMENTATION(inMainOverriddenAtRuntime_override)
METHOD_IMPLEMENTATION(inCategoryOverriddenAtRuntime)
METHOD_IMPLEMENTATION(inCategoryOverriddenAtRuntime_override)
METHOD_IMPLEMENTATION(runtimeAdded)

EXTERN_C void unloadedCategoryMethod(id self __unused, SEL _cmd __unused) {
    fail("Method %s in unloaded category called, this should not happen.", sel_getName(_cmd));
}


// ====================
// Actual tests follow.
// ====================

// Search for a predicate in a NULL-terminated array of pointers.
template <typename T, typename Fn>
T find(T *ptr, const Fn &predicate) {
    while (*ptr) {
        if (predicate(*ptr))
            return *ptr;
        ptr++;
    }
    return nullptr;
}

// Run checks on the test class. When testRuntimeAdditions is true, we require
// the presence of the runtime-added method/property/protocol. When false, we
// require that they not be present.
void doChecks(bool testRuntimeAdditions)
{
    NSObject *obj = [(__bridge Class)&TestClass new];

    #define SEND(sel) ((const char *(*)(id, SEL))objc_msgSend)(obj, sel)

    testassertequal((__bridge void *)obj, (__bridge void *)[obj self]);
    testassertequalstr(SEND(onlyInMainListSEL), "onlyInMainList");
    testassertequalstr(SEND(inMainListAndLoadedCategorySEL), "inMainListAndLoadedCategory_category");
    testassertequalstr(SEND(onlyInLoadedCategorySEL), "onlyInLoadedCategory");
    testassert(![obj respondsToSelector: onlyInUnloadedCategorySEL]);
    if (testRuntimeAdditions) {
        testassertequalstr(SEND(inMainOverriddenAtRuntimeSEL), "inMainOverriddenAtRuntime_override");
        testassertequalstr(SEND(inCategoryOverriddenAtRuntimeSEL), "inCategoryOverriddenAtRuntime_override");
        testassertequalstr(SEND(@selector(runtimeAdded)), "runtimeAdded");
    } else {
        testassertequalstr(SEND(inMainOverriddenAtRuntimeSEL), "inMainOverriddenAtRuntime");
        testassertequalstr(SEND(inCategoryOverriddenAtRuntimeSEL), "inCategoryOverriddenAtRuntime");
        testassert(![obj respondsToSelector: @selector(runtimeAdded)]);
    }

    Method *methods = class_copyMethodList([obj class], nullptr);
    testassert(find(methods, [](auto m) { return method_getName(m) == onlyInMainListSEL; }));
    testassert(find(methods, [](auto m) { return method_getName(m) == inMainListAndLoadedCategorySEL; }));
    testassert(find(methods, [](auto m) { return method_getName(m) == onlyInLoadedCategorySEL; }));
    testassert(!find(methods, [](auto m) { return method_getName(m) == onlyInUnloadedCategorySEL; }));
    bool hasRuntimeAddedMethod = find(methods, [](auto m) { return method_getName(m) == @selector(runtimeAdded); });
    testassertequal(hasRuntimeAddedMethod, testRuntimeAdditions);
    free(methods);

    testassert([obj conformsToProtocol: @protocol(OnlyInMain)]);
    testassert([obj conformsToProtocol: @protocol(InMainAndCategory)]);
    testassert([obj conformsToProtocol: @protocol(OnlyInCategory)]);
    testassert(![obj conformsToProtocol: @protocol(OnlyInUnloadedCategory)]);
    testassertequal([obj conformsToProtocol: @protocol(RuntimeAdded)], testRuntimeAdditions);

    Protocol * __unsafe_unretained *protocols = class_copyProtocolList([obj class], nullptr);
    testassert(find(protocols, [](auto p) { return p == @protocol(OnlyInMain); }));
    testassert(find(protocols, [](auto p) { return p == @protocol(InMainAndCategory); }));
    testassert(find(protocols, [](auto p) { return p == @protocol(OnlyInCategory); }));
    testassert(!find(protocols, [](auto p) { return p == @protocol(OnlyInUnloadedCategory); }));
    bool hasRuntimeAddedProtocol = find(protocols, [](auto p) { return p == @protocol(RuntimeAdded); });
    testassertequal(hasRuntimeAddedProtocol, testRuntimeAdditions);
    free(protocols);

    testassert(class_getProperty([obj class], "onlyInMain"));
    testassert(class_getProperty([obj class], "inMainAndCategory"));
    testassert(class_getProperty([obj class], "onlyInCategory"));
    testassert(!class_getProperty([obj class], "onlyInUnloadedCategory"));
    testassertequal((bool)class_getProperty([obj class], "runtimeAdded"), testRuntimeAdditions);

    objc_property_t *properties = class_copyPropertyList([obj class], nullptr);
    testassert(find(properties, [](auto p) { return strcmp(property_getName(p), "onlyInMain") == 0; }));
    testassert(find(properties, [](auto p) { return strcmp(property_getName(p), "inMainAndCategory") == 0; }));
    testassert(find(properties, [](auto p) { return strcmp(property_getName(p), "onlyInCategory") == 0; }));
    testassert(!find(properties, [](auto p) { return strcmp(property_getName(p), "onlyInUnloadedCategory") == 0; }));
    bool hasRuntimeAddedProperty = find(properties, [](auto p) { return strcmp(property_getName(p), "runtimeAdded") == 0; });
    testassertequal(hasRuntimeAddedProperty, testRuntimeAdditions);
    free(properties);

    RELEASE_VAR(obj);
}

int main() {
    FixupListOfListsImageIndexes(TestClassListOfMethodLists);
    FixupListOfListsImageIndexes(TestClassListOfProtocolLists);
    FixupListOfListsImageIndexes(TestClassListOfPropertyLists);

    testprintf("Testing class as-is\n");
    doChecks(false);

    testprintf("Adding new method, protocol, and property at runtime.\n");

    BOOL addMethodSuccess = class_addMethod((__bridge Class)&TestClass, @selector(runtimeAdded), (IMP)runtimeAdded, "");
    testassert(addMethodSuccess);

    IMP replacedMethod = class_replaceMethod((__bridge Class)&TestClass, inMainOverriddenAtRuntimeSEL, (IMP)inMainOverriddenAtRuntime_override, "");
    testassert(replacedMethod);
    replacedMethod = class_replaceMethod((__bridge Class)&TestClass, inCategoryOverriddenAtRuntimeSEL, (IMP)inCategoryOverriddenAtRuntime_override, "");
    testassert(replacedMethod);

    BOOL addProtocolSuccess = class_addProtocol((__bridge Class)&TestClass, @protocol(RuntimeAdded));
    testassert(addProtocolSuccess);

    objc_property_attribute_t attrs[] = {
        { "T", "i" },
        { "D", "" },
    };
    BOOL addPropertySuccess = class_addProperty((__bridge Class)&TestClass, "runtimeAdded", attrs, 2);
    testassert(addPropertySuccess);

    testprintf("Testing class with runtime additions\n");
    doChecks(true);

    succeed(__FILE__);
}
