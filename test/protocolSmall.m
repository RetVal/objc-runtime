/*
TEST_BUILD_OUTPUT
.*protocolSmall.m:\d+:\d+: warning: cannot find protocol definition for 'SmallProto'
.*protocolSmall.m:\d+:\d+: note: protocol 'SmallProto' has no definition
END
*/

#include "test.h"
#include "testroot.i"
#include <objc/runtime.h>
#include <ptrauth.h>

#if TARGET_OS_EXCLAVEKIT && __has_feature(ptrauth_calls)
#define ptrauth_method_list_types \
    __ptrauth(ptrauth_key_process_dependent_data, 1, \
    ptrauth_string_discriminator("method_t::bigSigned::types"))
#define ptrauth_objc_sel __ptrauth_objc_sel
#else
#define ptrauth_method_list_types
#define ptrauth_objc_sel
#endif

struct MethodListOneEntry {
    uint32_t entSizeAndFlags;
    uint32_t count;
    SEL ptrauth_objc_sel name;
    const char * ptrauth_method_list_types types;
    void *imp;
};

struct SmallProtoStructure {
    Class isa;
    const char *mangledName;
    struct protocol_list_t *protocols;
    void *instanceMethods;
    void *classMethods;
    void *optionalInstanceMethods;
    void *optionalClassMethods;
    void *instanceProperties;
    uint32_t size;   // sizeof(protocol_t)
    uint32_t flags;    
};

struct MethodListOneEntry SmallProtoMethodList = {
    .entSizeAndFlags = 3 * sizeof(void *),
    .count = 1,
    .name = NULL,
    .types = "v@:",
    .imp = NULL,
};

struct SmallProtoStructure SmallProtoData
    __asm__("__OBJC_PROTOCOL_$_SmallProto")
    = {
    .mangledName = "SmallProto",
    .instanceMethods = &SmallProtoMethodList,
    .size = sizeof(struct SmallProtoStructure),
};

void *SmallProtoListEntry
    __attribute__((section("__DATA,__objc_protolist,coalesced,no_dead_strip")))
    = &SmallProtoData;

@protocol SmallProto;
@protocol NormalProto
- (void)protoMethod;
@end

@interface C: TestRoot <SmallProto, NormalProto> @end
@implementation C
- (void)protoMethod {}
@end

int main()
{
    // Fix up the method list selector by hand, getting the compiler to generate a
    // proper selref as a compile-time constant is a pain.
    SmallProtoMethodList.name = @selector(protoMethod);
    unsigned protoCount;

    Protocol * __unsafe_unretained *protos = class_copyProtocolList([C class], &protoCount);
    for (unsigned i = 0; i < protoCount; i++) {
        testprintf("Checking index %u protocol %p\n", i, protos[i]);
        const char *name = protocol_getName(protos[i]);
        testprintf("Name is %s\n", name);
        testassert(strcmp(name, "SmallProto") == 0 || strcmp(name, "NormalProto") == 0);

        objc_property_t *classProperties = protocol_copyPropertyList2(protos[i], NULL, YES, NO);
        testassert(classProperties == NULL);

        struct objc_method_description desc = protocol_getMethodDescription(protos[i], @selector(protoMethod), YES, YES);
        testprintf("Protocol protoMethod name is %s types are %s\n", desc.name, desc.types);
        testassert(desc.name == @selector(protoMethod));
        testassert(desc.types[0] == 'v');
    }
    free(protos);

    succeed(__FILE__);
}
