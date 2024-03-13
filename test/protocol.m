/*
TEST_BUILD_OUTPUT
.*protocol.m:\d+:\d+: warning: null passed to a callee that requires a non-null argument \[-Wnonnull\](\n.* note: expanded from macro 'testassert')?
END
*/

#include "test.h"
#include "testroot.i"
#include <string.h>
#include <objc/runtime.h>
#include <objc/objc-internal.h>

@protocol Proto1 
+(id)proto1ClassMethod;
-(id)proto1InstanceMethod;
@end

@protocol Proto2
+(id)proto2ClassMethod;
-(id)proto2InstanceMethod;
@end

@protocol Proto3 <Proto2>
+(id)proto3ClassMethod;
-(id)proto3InstanceMethod;
@end

@protocol Proto4
@property int i;
@end

// This declaration order deliberately looks weird because it determines the 
// selector address order on some architectures rdar://10582325. Recent ld64
// sorts selectors, so we underscore some of the methods to ensure some of the
// methods are out of order in terms of selector address.
@protocol Proto5
-(id)m11:(id<Proto1>)a;
-(void)_m12:(id<Proto1>)a;
-(int)m13:(id<Proto1>)a;
+(void)_m22:(TestRoot<Proto1>*)a;
+(int)m23:(TestRoot<Proto1>*)a;
+(TestRoot*)m21:(TestRoot<Proto1>*)a;
@optional
-(id(^)(id))m31:(id<Proto1>(^)(id<Proto1>))a;
-(void)_m32:(id<Proto1>(^)(id<Proto1>))a;
-(int)m33:(id<Proto1>(^)(id<Proto1>))a;
+(void)_m42:(TestRoot<Proto1>*(^)(TestRoot<Proto1>*))a;
+(int)m43:(TestRoot<Proto1>*(^)(TestRoot<Proto1>*))a;
+(TestRoot*(^)(TestRoot*))m41:(TestRoot<Proto1>*(^)(TestRoot<Proto1>*))a;
@end

@protocol Proto6 <Proto5>
@optional
+(TestRoot*(^)(TestRoot*))n41:(TestRoot<Proto1>*(^)(TestRoot<Proto1>*))a;
@end

@protocol Proto7 <Proto5>
@end

@protocol ProtoEmpty
@end

#define SwiftV1MangledName "_TtP6Module15SwiftV1Protocol_"

__attribute__((objc_runtime_name(SwiftV1MangledName)))
@protocol SwiftV1Protocol
@end

@interface Super : TestRoot <Proto1> @end
@implementation Super
+(id)proto1ClassMethod { return self; }
-(id)proto1InstanceMethod { return self; }
@end

@interface SubNoProtocols : Super @end
@implementation SubNoProtocols @end

@interface SuperNoProtocols : TestRoot @end
@implementation SuperNoProtocols
@end

@interface SubProp : Super <Proto4> { int i; } @end
@implementation SubProp 
@synthesize i;
@end


int main()
{
    Class cls;
    Protocol * __unsafe_unretained *list;
    Protocol *protocol, *empty;
    struct objc_method_description desc2;
    objc_property_t *proplist;
    unsigned int count;

    protocol = @protocol(Proto3);
    empty = @protocol(ProtoEmpty);
    testassert(protocol);
    testassert(empty);

    testassert(0 == strcmp(protocol_getName(protocol), "Proto3"));
    testassert(0 == strcmp(protocol_getName(empty), "ProtoEmpty"));

    testassert(class_conformsToProtocol([Super class], @protocol(Proto1)));
    testassert(!class_conformsToProtocol([SubProp class], @protocol(Proto1)));
    testassert(class_conformsToProtocol([SubProp class], @protocol(Proto4)));
    testassert(!class_conformsToProtocol([SubProp class], @protocol(Proto3)));
    testassert(!class_conformsToProtocol([Super class], @protocol(Proto3)));

    testassert(!protocol_conformsToProtocol(@protocol(Proto1), @protocol(Proto2)));
    testassert(protocol_conformsToProtocol(@protocol(Proto3), @protocol(Proto2)));
    testassert(!protocol_conformsToProtocol(@protocol(Proto2), @protocol(Proto3)));

    testassert(protocol_isEqual(@protocol(Proto1), @protocol(Proto1)));
    testassert(! protocol_isEqual(@protocol(Proto1), @protocol(Proto2)));

    desc2 = protocol_getMethodDescription(protocol, @selector(proto3InstanceMethod), YES, YES);
    testassert(desc2.name && desc2.types);
    testassert(desc2.name == @selector(proto3InstanceMethod));
    desc2 = protocol_getMethodDescription(protocol, @selector(proto3ClassMethod), YES, NO);
    testassert(desc2.name && desc2.types);
    testassert(desc2.name == @selector(proto3ClassMethod));
    desc2 = protocol_getMethodDescription(protocol, @selector(proto2ClassMethod), YES, NO);
    testassert(desc2.name && desc2.types);
    testassert(desc2.name == @selector(proto2ClassMethod));

    desc2 = protocol_getMethodDescription(protocol, @selector(proto3ClassMethod), YES, YES);
    testassert(!desc2.name && !desc2.types);
    desc2 = protocol_getMethodDescription(protocol, @selector(proto3InstanceMethod), YES, NO);
    testassert(!desc2.name && !desc2.types);
    desc2 = protocol_getMethodDescription(empty, @selector(proto3ClassMethod), YES, YES);
    testassert(!desc2.name && !desc2.types);
    desc2 = protocol_getMethodDescription(empty, @selector(proto3InstanceMethod), YES, NO);
    testassert(!desc2.name && !desc2.types);

    count = 100;
    list = protocol_copyProtocolList(@protocol(Proto2), &count);
    testassert(!list);
    testassert(count == 0);
    count = 100;
    list = protocol_copyProtocolList(@protocol(Proto3), &count);
    testassert(list);
    testassert(count == 1);
    testassert(protocol_isEqual(list[0], @protocol(Proto2)));
    testassert(!list[1]);
    free(list);    

    count = 100;
    cls = objc_getClass("Super");
    testassert(cls);
    list = class_copyProtocolList(cls, &count);
    testassert(list);
    testassert(list[count] == NULL);
    testassert(count == 1);
    testassert(0 == strcmp(protocol_getName(list[0]), "Proto1"));
    free(list);

    count = 100;
    cls = objc_getClass("SuperNoProtocols");
    testassert(cls);
    list = class_copyProtocolList(cls, &count);
    testassert(!list);
    testassert(count == 0);

    count = 100;
    cls = objc_getClass("SubNoProtocols");
    testassert(cls);
    list = class_copyProtocolList(cls, &count);
    testassert(!list);
    testassert(count == 0);


    cls = objc_getClass("SuperNoProtocols");
    testassert(cls);
    list = class_copyProtocolList(cls, NULL);
    testassert(!list);

    cls = objc_getClass("Super");
    testassert(cls);
    list = class_copyProtocolList(cls, NULL);
    testassert(list);
    free(list);

    count = 100;
    list = class_copyProtocolList(NULL, &count);
    testassert(!list);
    testassert(count == 0);


    // Check property added by protocol
    cls = objc_getClass("SubProp");
    testassert(cls);

    count = 100;
    list = class_copyProtocolList(cls, &count);
    testassert(list);
    testassert(count == 1);
    testassert(0 == strcmp(protocol_getName(list[0]), "Proto4"));
    testassert(list[1] == NULL);
    free(list);

    count = 100;
    proplist = class_copyPropertyList(cls, &count);
    testassert(proplist);
    testassert(count == 1);
    testassert(0 == strcmp(property_getName(proplist[0]), "i"));
    testassert(proplist[1] == NULL);
    free(proplist);

    // Check extended type encodings
    testassert(_protocol_getMethodTypeEncoding(@protocol(Proto5), @selector(DoesNotExist), true, true) == NULL);
    testassert(_protocol_getMethodTypeEncoding(NULL, @selector(m11), true, true) == NULL);
    testassert(_protocol_getMethodTypeEncoding(@protocol(Proto5), @selector(m11), true, false) == NULL);
    testassert(_protocol_getMethodTypeEncoding(@protocol(Proto5), @selector(m11), false, false) == NULL);
    testassert(_protocol_getMethodTypeEncoding(@protocol(Proto5), @selector(m11), false, true) == NULL);
    testassert(_protocol_getMethodTypeEncoding(@protocol(Proto5), @selector(m21), true, true) == NULL);
#if __LP64__
    const char *types11 = "@24@0:8@\"<Proto1>\"16";
    const char *types12 = "v24@0:8@\"<Proto1>\"16";
    const char *types13 = "i24@0:8@\"<Proto1>\"16";
    const char *types21 = "@\"TestRoot\"24@0:8@\"TestRoot<Proto1>\"16";
    const char *types22 = "v24@0:8@\"TestRoot<Proto1>\"16";
    const char *types23 = "i24@0:8@\"TestRoot<Proto1>\"16";
    const char *types31 = "@?<@@?@>24@0:8@?<@\"<Proto1>\"@?@\"<Proto1>\">16";
    const char *types32 = "v24@0:8@?<@\"<Proto1>\"@?@\"<Proto1>\">16";
    const char *types33 = "i24@0:8@?<@\"<Proto1>\"@?@\"<Proto1>\">16";
    const char *types41 = "@?<@\"TestRoot\"@?@\"TestRoot\">24@0:8@?<@\"TestRoot<Proto1>\"@?@\"TestRoot<Proto1>\">16";
    const char *types42 = "v24@0:8@?<@\"TestRoot<Proto1>\"@?@\"TestRoot<Proto1>\">16";
    const char *types43 = "i24@0:8@?<@\"TestRoot<Proto1>\"@?@\"TestRoot<Proto1>\">16";
#else
    const char *types11 = "@12@0:4@\"<Proto1>\"8";
    const char *types12 = "v12@0:4@\"<Proto1>\"8";
    const char *types13 = "i12@0:4@\"<Proto1>\"8";
    const char *types21 = "@\"TestRoot\"12@0:4@\"TestRoot<Proto1>\"8";
    const char *types22 = "v12@0:4@\"TestRoot<Proto1>\"8";
    const char *types23 = "i12@0:4@\"TestRoot<Proto1>\"8";
    const char *types31 = "@?<@@?@>12@0:4@?<@\"<Proto1>\"@?@\"<Proto1>\">8";
    const char *types32 = "v12@0:4@?<@\"<Proto1>\"@?@\"<Proto1>\">8";
    const char *types33 = "i12@0:4@?<@\"<Proto1>\"@?@\"<Proto1>\">8";
    const char *types41 = "@?<@\"TestRoot\"@?@\"TestRoot\">12@0:4@?<@\"TestRoot<Proto1>\"@?@\"TestRoot<Proto1>\">8";
    const char *types42 = "v12@0:4@?<@\"TestRoot<Proto1>\"@?@\"TestRoot<Proto1>\">8";
    const char *types43 = "i12@0:4@?<@\"TestRoot<Proto1>\"@?@\"TestRoot<Proto1>\">8";
#endif

    // Make sure some of Proto5's selectors are out of order rdar://10582325
    // These comparisons deliberately look weird because they determine the 
    // selector order on some architectures.
    testassert(sel_registerName("m11:") > sel_registerName("_m12:")  ||
               sel_registerName("m21:") > sel_registerName("_m22:")  ||
               sel_registerName("_m32:") < sel_registerName("m31:")  ||
               sel_registerName("_m42:") < sel_registerName("m41:")  );

    if (!_protocol_getMethodTypeEncoding(@protocol(Proto5), @selector(m11:), true, true)) {
        fail("rdar://10492418 extended type encodings not present (is compiler old?)");
    } else {
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto5), @selector(m11:), true, true),   types11));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto5), @selector(_m12:), true, true),   types12));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto5), @selector(m13:), true, true),   types13));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto5), @selector(m21:), true, false),  types21));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto5), @selector(_m22:), true, false),  types22));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto5), @selector(m23:), true, false),  types23));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto5), @selector(m31:), false, true),  types31));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto5), @selector(_m32:), false, true),  types32));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto5), @selector(m33:), false, true),  types33));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto5), @selector(m41:), false, false), types41));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto5), @selector(_m42:), false, false), types42));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto5), @selector(m43:), false, false), types43));
        
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto6), @selector(m11:), true, true),   types11));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto6), @selector(_m12:), true, true),   types12));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto6), @selector(m13:), true, true),   types13));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto6), @selector(m21:), true, false),  types21));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto6), @selector(_m22:), true, false),  types22));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto6), @selector(m23:), true, false),  types23));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto6), @selector(m31:), false, true),  types31));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto6), @selector(_m32:), false, true),  types32));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto6), @selector(m33:), false, true),  types33));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto6), @selector(m41:), false, false), types41));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto6), @selector(_m42:), false, false), types42));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto6), @selector(m43:), false, false), types43));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto6), @selector(n41:), false, false), types41));

        // <rdar://problem/68987191> _protocol_getMethodTypeEncoding always returns NULL for empty protocol which only inherits
        testassert(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(m11:), true, true));
        testassert(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(_m12:), true, true));
        testassert(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(m13:), true, true));
        testassert(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(m21:), true, false));
        testassert(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(_m22:), true, false));
        testassert(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(m23:), true, false));
        testassert(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(m31:), false, true));
        testassert(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(_m32:), false, true));
        testassert(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(m33:), false, true));
        testassert(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(m41:), false, false));
        testassert(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(_m42:), false, false));
        testassert(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(m43:), false, false));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(m11:), true, true),   types11));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(_m12:), true, true),   types12));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(m13:), true, true),   types13));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(m21:), true, false),  types21));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(_m22:), true, false),  types22));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(m23:), true, false),  types23));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(m31:), false, true),  types31));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(_m32:), false, true),  types32));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(m33:), false, true),  types33));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(m41:), false, false), types41));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(_m42:), false, false), types42));
        testassert(0 == strcmp(_protocol_getMethodTypeEncoding(@protocol(Proto7), @selector(m43:), false, false), types43));
    }

    testassert(@protocol(SwiftV1Protocol) == objc_getProtocol("Module.SwiftV1Protocol"));
    testassert(@protocol(SwiftV1Protocol) == objc_getProtocol(SwiftV1MangledName));
    testassert(0 == strcmp(protocol_getName(@protocol(SwiftV1Protocol)), "Module.SwiftV1Protocol"));
    testassert(!objc_getProtocol("SwiftV1Protocol"));

    succeed(__FILE__);
}
