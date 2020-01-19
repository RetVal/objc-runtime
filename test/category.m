// TEST_CFLAGS -Wl,-no_objc_category_merging

#include "test.h"
#include "testroot.i"
#include <string.h>
#include <objc/runtime.h>

static int state = 0;

@interface Super : TestRoot @end
@implementation Super
-(void)instancemethod { fail("-instancemethod not overridden by category"); }
+(void)method { fail("+method not overridden by category"); } 
@end

@interface Super (Category) @end
@implementation Super (Category) 
+(void)method { 
    testprintf("in [Super(Category) method]\n"); 
    testassert(self == [Super class]);
    testassert(state == 0);
    state = 1;
}
-(void)instancemethod { 
    testprintf("in [Super(Category) instancemethod]\n"); 
    testassert(object_getClass(self) == [Super class]);
    testassert(state == 1);
    state = 2;
}
@end

@interface Super (PropertyCategory) 
@property int i;
@property(class) int i;
@end
@implementation Super (PropertyCategory) 
- (int)i { return 0; }
- (void)setI:(int)value { (void)value; }
+ (int)i { return 0; }
+ (void)setI:(int)value { (void)value; }
@end

// rdar://5086110  memory smasher in category with class method and property
@interface Super (r5086110) 
@property int property5086110;
@end
@implementation Super (r5086110) 
+(void)method5086110 { 
    fail("method method5086110 called!");
}
- (int)property5086110 { fail("property5086110 called!"); return 0; }
- (void)setProperty5086110:(int)value { fail("setProperty5086110 called!"); (void)value; }
@end

// rdar://25605427 incorrect handling of class properties in 10.11 and earlier
@interface Super25605427 : TestRoot
@property(class, readonly) int i;
@end
@implementation Super25605427
+(int)i { return 0; }
@end

@interface Super25605427 (r25605427a)
@property(readonly) int r25605427a1;
@end
@implementation Super25605427 (r25605427a)
-(int)r25605427a1 { return 0; }
+(int)r25605427a2 { return 0; }
@end

@interface Super25605427 (r25605427b)
@property(readonly) int r25605427b1;
@end
@implementation Super25605427 (r25605427b)
-(int)r25605427b1 { return 0; }
+(int)r25605427b2 { return 0; }
@end

@interface Super25605427 (r25605427c)
@property(readonly) int r25605427c1;
@end
@implementation Super25605427 (r25605427c)
-(int)r25605427c1 { return 0; }
+(int)r25605427c2 { return 0; }
@end

@interface Super25605427 (r25605427d)
@property(readonly) int r25605427d1;
@end
@implementation Super25605427 (r25605427d)
-(int)r25605427d1 { return 0; }
+(int)r25605427d2 { return 0; }
@end


@interface PropertyClass : Super {
    int q;
}
@property(readonly) int q;
@end
@implementation PropertyClass
@synthesize q;
@end

@interface PropertyClass (PropertyCategory)
@property int q;
@end
@implementation PropertyClass (PropertyCategory)
@dynamic q;
@end


int main()
{
    {
        // rdar://25605427 bugs in 10.11 and earlier when metaclass
        // has a property and category has metaclass additions.
        // Memory smasher in buildPropertyList (caught by guard malloc)
        Class cls = [Super25605427 class];
        // Incorrect attachment of instance properties from category to metacls
        testassert(class_getProperty(cls, "r25605427d1"));
        testassert(! class_getProperty(object_getClass(cls), "r25605427d1"));
    }

    // methods introduced by category
    state = 0;
    [Super method];
    [[Super new] instancemethod];
    testassert(state == 2);

    // property introduced by category
    objc_property_t p = class_getProperty([Super class], "i");
    testassert(p);
    testassert(0 == strcmp(property_getName(p), "i"));
    testassert(property_getAttributes(p));

    objc_property_t p2 = class_getProperty(object_getClass([Super class]), "i");
    testassert(p2);
    testassert(p != p2);
    testassert(0 == strcmp(property_getName(p2), "i"));
    testassert(property_getAttributes(p2));

    // methods introduced by category's property
    Method m;
    m = class_getInstanceMethod([Super class], @selector(i));
    testassert(m);
    m = class_getInstanceMethod([Super class], @selector(setI:));
    testassert(m);

    m = class_getClassMethod([Super class], @selector(i));
    testassert(m);
    m = class_getClassMethod([Super class], @selector(setI:));
    testassert(m);

    // class's property shadowed by category's property
    objc_property_t *plist = class_copyPropertyList([PropertyClass class], NULL);
    testassert(plist);
    testassert(plist[0]);
    testassert(0 == strcmp(property_getName(plist[0]), "q"));
    testassert(0 == strcmp(property_getAttributes(plist[0]), "Ti,D"));
    testassert(plist[1]);
    testassert(0 == strcmp(property_getName(plist[1]), "q"));
    testassert(0 == strcmp(property_getAttributes(plist[1]), "Ti,R,Vq"));
    testassert(!plist[2]);
    free(plist);
    
    succeed(__FILE__);
}

