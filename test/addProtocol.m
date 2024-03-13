/*
TEST_BUILD_OUTPUT
.*addProtocol.m:\d+:\d+: warning: null passed to a callee that requires a non-null argument \[-Wnonnull\](\n.* note: expanded from macro 'testassert')?
.*addProtocol.m:\d+:\d+: warning: null passed to a callee that requires a non-null argument \[-Wnonnull\](\n.* note: expanded from macro 'testassert')?
.*addProtocol.m:\d+:\d+: warning: null passed to a callee that requires a non-null argument \[-Wnonnull\](\n.* note: expanded from macro 'testassert')?
.*addProtocol.m:\d+:\d+: warning: null passed to a callee that requires a non-null argument \[-Wnonnull\](\n.* note: expanded from macro 'testassert')?
.*addProtocol.m:\d+:\d+: warning: null passed to a callee that requires a non-null argument \[-Wnonnull\](\n.* note: expanded from macro 'testassert')?
END
TEST_RUN_OUTPUT
objc\[\d+\]: protocol_addProtocol: added protocol 'EmptyProto' is still under construction!
objc\[\d+\]: objc_registerProtocol: protocol 'Proto1' was already registered!
objc\[\d+\]: protocol_addProtocol: modified protocol 'Proto1' is not under construction!
objc\[\d+\]: protocol_addMethodDescription: protocol 'Proto1' is not under construction!
objc\[\d+\]: objc_registerProtocol: protocol 'SuperProto' was already registered!
objc\[\d+\]: protocol_addProtocol: modified protocol 'SuperProto' is not under construction!
objc\[\d+\]: protocol_addMethodDescription: protocol 'SuperProto' is not under construction!
OK: addProtocol.m
END 
*/

#include "test.h"

#include <objc/runtime.h>

@protocol SuperProto @end
@protocol SuperProto2 @end
@protocol UnrelatedProto @end


void Crash(id self, SEL _cmd)
{
    fail("%c[%s %s] called unexpectedly", 
         class_isMetaClass(object_getClass(self)) ? '+' : '-', 
         object_getClassName(self), sel_getName(_cmd));
}


int main()
{
    // old-ABI implementation of [Protocol retain] 
    // is added by +[NSObject(NSObject) load] in CF.
    [NSObject class];

    Protocol *proto, *proto2;
    Protocol * __unsafe_unretained *protolist;
    struct objc_method_description *desclist;
    objc_property_t *proplist;
    unsigned int count;

    // If objc_registerProtocol() fails to preserve the retain count
    // then ARC will deallocate Protocol objects too early.
    class_replaceMethod(objc_getClass("Protocol"), 
                        sel_registerName("dealloc"), (IMP)Crash, "v@:");
    class_replaceMethod(objc_getClass("__IncompleteProtocol"), 
                        sel_registerName("dealloc"), (IMP)Crash, "v@:");

    // make sure binary contains hard copies of these protocols
    proto = @protocol(SuperProto);
    proto = @protocol(SuperProto2);

    // Adding a protocol

    char *name = strdup("Proto1");
    proto = objc_allocateProtocol(name);
    testassert(proto);
    testassert(!objc_getProtocol(name));

    protocol_addProtocol(proto, @protocol(SuperProto));
    protocol_addProtocol(proto, @protocol(SuperProto2));
    // no inheritance cycles
    proto2 = objc_allocateProtocol("EmptyProto");
    protocol_addProtocol(proto, proto2);  // fails
    objc_registerProtocol(proto2);
    protocol_addProtocol(proto, proto2);  // succeeds

    char *types = strdup("@:");

    // Force reverse order for these selectors (so we can check sorting works)
    SEL instSelectors[] = {
        @selector(ReqInst3),
        @selector(ReqInst2),
        @selector(ReqInst1),
        @selector(ReqInst0)
    };
    (void)&instSelectors;

    protocol_addMethodDescription(proto, @selector(ReqInst0), types, YES, YES);
    protocol_addMethodDescription(proto, @selector(ReqInst1), types, YES, YES);
    protocol_addMethodDescription(proto, @selector(ReqInst2), types, YES, YES);
    protocol_addMethodDescription(proto, @selector(ReqInst3), types, YES, YES);

    protocol_addMethodDescription(proto, @selector(ReqClas0), types, YES, NO);
    protocol_addMethodDescription(proto, @selector(ReqClas1), types, YES, NO);
    protocol_addMethodDescription(proto, @selector(ReqClas2), types, YES, NO);
    protocol_addMethodDescription(proto, @selector(ReqClas3), types, YES, NO);

    protocol_addMethodDescription(proto, @selector(OptInst0), types, NO,  YES);
    protocol_addMethodDescription(proto, @selector(OptInst1), types, NO,  YES);
    protocol_addMethodDescription(proto, @selector(OptInst2), types, NO,  YES);
    protocol_addMethodDescription(proto, @selector(OptInst3), types, NO,  YES);

    protocol_addMethodDescription(proto, @selector(OptClas0), types, NO,  NO);
    protocol_addMethodDescription(proto, @selector(OptClas1), types, NO,  NO);
    protocol_addMethodDescription(proto, @selector(OptClas2), types, NO,  NO);
    protocol_addMethodDescription(proto, @selector(OptClas3), types, NO,  NO);

    char *name0 = strdup("ReqInst0");
    char *name1 = strdup("ReqInst1");
    char *name2 = strdup("ReqInst2");
    char *name3 = strdup("ReqInst3");
    char *name4 = strdup("ReqClass0");
    char *name5 = strdup("ReqClass1");
    char *name6 = strdup("ReqClass2");
    char *name7 = strdup("ReqClass3");
    char *attrname = strdup("T");
    char *attrvalue = strdup("i");
    objc_property_attribute_t attrs[] = {{attrname, attrvalue}};
    int attrcount = sizeof(attrs) / sizeof(attrs[0]);
    protocol_addProperty(proto, name0, attrs, attrcount, YES, YES);
    protocol_addProperty(proto, name1, attrs, attrcount, YES, YES);
    protocol_addProperty(proto, name2, attrs, attrcount, YES, YES);
    protocol_addProperty(proto, name3, attrs, attrcount, YES, YES);
    protocol_addProperty(proto, name4, attrs, attrcount, YES, NO);
    protocol_addProperty(proto, name5, attrs, attrcount, YES, NO);
    protocol_addProperty(proto, name6, attrs, attrcount, YES, NO);
    protocol_addProperty(proto, name7, attrs, attrcount, YES, NO);

    objc_registerProtocol(proto);
    testassert(0 == strcmp(protocol_getName(proto), "Proto1"));

    // Use of added protocols

    testassert(proto == objc_getProtocol("Proto1"));
    strncpy(name, "XXXXXX", 7);  // name is copied
    testassert(0 == strcmp(protocol_getName(proto), "Proto1"));

    protolist = protocol_copyProtocolList(proto, &count);
    testassert(protolist);
    testassert(count == 3);
    // note this order is not required
    testassert(protolist[0] == @protocol(SuperProto)  &&  
               protolist[1] == @protocol(SuperProto2)  &&  
               protolist[2] == proto2);
    free(protolist);

    testassert(protocol_conformsToProtocol(proto, proto2));
    testassert(protocol_conformsToProtocol(proto, @protocol(SuperProto)));
    testassert(!protocol_conformsToProtocol(proto, @protocol(UnrelatedProto)));

    strncpy(types, "XX", 3);  // types is copied
    desclist = protocol_copyMethodDescriptionList(proto, YES, YES, &count);
    testassert(desclist  &&  count == 4);
    testprintf("%p %p\n", desclist[0].name, @selector(ReqInst0));
    // testassert(desclist[0].name == @selector(ReqInst0));
    testassert(0 == strcmp(desclist[0].types, "@:"));
    free(desclist);
    desclist = protocol_copyMethodDescriptionList(proto, YES, NO,  &count);
    testassert(desclist  &&  count == 4);
    testassert(desclist[1].name == @selector(ReqClas1));
    testassert(0 == strcmp(desclist[1].types, "@:"));
    free(desclist);
    desclist = protocol_copyMethodDescriptionList(proto, NO,  YES, &count);
    testassert(desclist  &&  count == 4);
    testassert(desclist[2].name == @selector(OptInst2));
    testassert(0 == strcmp(desclist[2].types, "@:"));
    free(desclist);
    desclist = protocol_copyMethodDescriptionList(proto, NO,  NO,  &count);
    testassert(desclist  &&  count == 4);
    testassert(desclist[3].name == @selector(OptClas3));
    testassert(0 == strcmp(desclist[3].types, "@:"));
    free(desclist);

    strncpy(name0, "XXXXXXXX", 9);  // name is copied
    strncpy(name1, "XXXXXXXX", 9);  // name is copied
    strncpy(name2, "XXXXXXXX", 9);  // name is copied
    strncpy(name3, "XXXXXXXX", 9);  // name is copied
    strncpy(name4, "XXXXXXXXX", 10);  // name is copied
    strncpy(name5, "XXXXXXXXX", 10);  // name is copied
    strncpy(name6, "XXXXXXXXX", 10);  // name is copied
    strncpy(name7, "XXXXXXXXX", 10);  // name is copied
    strncpy(attrname, "X", 2);             // description is copied
    strncpy(attrvalue, "X", 2);            // description is copied
    memset(attrs, 'X', sizeof(attrs)); // description is copied

    // Check instance methods (verifies that the list was sorted)
    testassert(protocol_getMethodDescription(proto, @selector(ReqInst0), YES, YES).name == @selector(ReqInst0));
    testassert(protocol_getMethodDescription(proto, @selector(ReqInst1), YES, YES).name == @selector(ReqInst1));
    testassert(protocol_getMethodDescription(proto, @selector(ReqInst2), YES, YES).name == @selector(ReqInst2));
    testassert(protocol_getMethodDescription(proto, @selector(ReqInst3), YES, YES).name == @selector(ReqInst3));

    // instance properties
    count = 100;
    proplist = protocol_copyPropertyList(proto, &count);
    testassert(proplist);
    testassert(count == 4);
    // note this order is not required
    testassert(0 == strcmp(property_getName(proplist[0]), "ReqInst0"));
    testassert(0 == strcmp(property_getName(proplist[1]), "ReqInst1"));
    testassert(0 == strcmp(property_getName(proplist[2]), "ReqInst2"));
    testassert(0 == strcmp(property_getName(proplist[3]), "ReqInst3"));
    testassert(0 == strcmp(property_getAttributes(proplist[0]), "Ti"));
    testassert(0 == strcmp(property_getAttributes(proplist[1]), "Ti"));
    testassert(0 == strcmp(property_getAttributes(proplist[2]), "Ti"));
    testassert(0 == strcmp(property_getAttributes(proplist[3]), "Ti"));
    free(proplist);

    // class properties
    count = 100;
    proplist = protocol_copyPropertyList2(proto, &count, YES, NO);
    testassert(proplist);
    testassert(count == 4);
    // note this order is not required
    testassert(0 == strcmp(property_getName(proplist[0]), "ReqClass0"));
    testassert(0 == strcmp(property_getName(proplist[1]), "ReqClass1"));
    testassert(0 == strcmp(property_getName(proplist[2]), "ReqClass2"));
    testassert(0 == strcmp(property_getName(proplist[3]), "ReqClass3"));
    testassert(0 == strcmp(property_getAttributes(proplist[0]), "Ti"));
    testassert(0 == strcmp(property_getAttributes(proplist[1]), "Ti"));
    testassert(0 == strcmp(property_getAttributes(proplist[2]), "Ti"));
    testassert(0 == strcmp(property_getAttributes(proplist[3]), "Ti"));
    free(proplist);

    testassert(proto2 == objc_getProtocol("EmptyProto"));
    testassert(0 == strcmp(protocol_getName(proto2), "EmptyProto"));

    protolist = protocol_copyProtocolList(proto2, &count);
    testassert(!protolist);
    testassert(count == 0);

    testassert(!protocol_conformsToProtocol(proto2, proto));
    testassert(!protocol_conformsToProtocol(proto2,@protocol(SuperProto)));
    testassert(!protocol_conformsToProtocol(proto2,@protocol(UnrelatedProto)));

    desclist = protocol_copyMethodDescriptionList(proto2, YES, YES, &count);
    testassert(!desclist  &&  count == 0);
    desclist = protocol_copyMethodDescriptionList(proto2, YES, NO,  &count);
    testassert(!desclist  &&  count == 0);
    desclist = protocol_copyMethodDescriptionList(proto2, NO,  YES, &count);
    testassert(!desclist  &&  count == 0);
    desclist = protocol_copyMethodDescriptionList(proto2, NO,  NO,  &count);
    testassert(!desclist  &&  count == 0);

    // Immutability of existing protocols

    objc_registerProtocol(proto);
    protocol_addProtocol(proto, @protocol(SuperProto2));
    protocol_addMethodDescription(proto, @selector(foo), "", YES, YES);

    objc_registerProtocol(@protocol(SuperProto));
    protocol_addProtocol(@protocol(SuperProto), @protocol(SuperProto2));
    protocol_addMethodDescription(@protocol(SuperProto), @selector(foo), "", YES, YES);

    // No duplicates

    proto = objc_allocateProtocol("SuperProto");
    testassert(!proto);
    proto = objc_allocateProtocol("Proto1");
    testassert(!proto);

    // NULL protocols ignored

    protocol_addProtocol((__bridge Protocol *)((void*)1), NULL);
    protocol_addProtocol(NULL, (__bridge Protocol *)((void*)1));
    protocol_addProtocol(NULL, NULL);
    protocol_addMethodDescription(NULL, @selector(foo), "", YES, YES);

    succeed(__FILE__);
}
