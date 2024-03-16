// These options must match customrr2.m
// TEST_CONFIG MEM=mrc
/*
TEST_BUILD
    $C{COMPILE} $DIR/customrr.m -fvisibility=default -o customrr.exe -fno-objc-convert-messages-to-runtime-calls
    $C{COMPILE} -bundle -bundle_loader customrr.exe $DIR/customrr-cat1.m -o customrr-cat1.bundle
    $C{COMPILE} -bundle -bundle_loader customrr.exe $DIR/customrr-cat2.m -o customrr-cat2.bundle
END
*/


#include "test.h"
#include <dlfcn.h>
#include <objc/NSObject.h>
#include <objc/runtime.h>

typedef struct _NSZone NSZone;

static int Retains;
static int Releases;
static int Autoreleases;
static int RetainCounts;
static int PlusRetains;
static int PlusReleases;
static int PlusAutoreleases;
static int PlusRetainCounts;
static int Allocs;
static int AllocWithZones;

static int SubRetains;
static int SubReleases;
static int SubAutoreleases;
static int SubRetainCounts;
static int SubPlusRetains;
static int SubPlusReleases;
static int SubPlusAutoreleases;
static int SubPlusRetainCounts;
static int SubAllocs;
static int SubAllocWithZones;

static int Imps;

static id imp_fn(id self, SEL _cmd __unused, ...)
{
    Imps++;
    return self;
}

static void zero(void) {
    // Flush any stale autorelease TLS entries before zeroing everything.
    objc_autoreleasePoolPop(objc_autoreleasePoolPush());
    Retains = 0;
    Releases = 0;
    Autoreleases = 0;
    RetainCounts = 0;
    PlusRetains = 0;
    PlusReleases = 0;
    PlusAutoreleases = 0;
    PlusRetainCounts = 0;
    Allocs = 0;
    AllocWithZones = 0;

    SubRetains = 0;
    SubReleases = 0;
    SubAutoreleases = 0;
    SubRetainCounts = 0;
    SubPlusRetains = 0;
    SubPlusReleases = 0;
    SubPlusAutoreleases = 0;
    SubPlusRetainCounts = 0;
    SubAllocs = 0;
    SubAllocWithZones = 0;

    Imps = 0;
}


id HackRetain(id self, SEL _cmd __unused) { Retains++; return self; }
void HackRelease(id self __unused, SEL _cmd __unused) { Releases++; }
id HackAutorelease(id self, SEL _cmd __unused) { Autoreleases++; return self; }
NSUInteger HackRetainCount(id self __unused, SEL _cmd __unused) { RetainCounts++; return 1; }
id HackPlusRetain(id self, SEL _cmd __unused) { PlusRetains++; return self; }
void HackPlusRelease(id self __unused, SEL _cmd __unused) { PlusReleases++; }
id HackPlusAutorelease(id self, SEL _cmd __unused) { PlusAutoreleases++; return self; }
NSUInteger HackPlusRetainCount(id self __unused, SEL _cmd __unused) { PlusRetainCounts++; return 1; }
id HackAlloc(Class self, SEL _cmd __unused) { Allocs++; return class_createInstance(self, 0); }
id HackAllocWithZone(Class self, SEL _cmd __unused) { AllocWithZones++; return class_createInstance(self, 0); }


@interface OverridingSub : NSObject @end
@implementation OverridingSub 

-(id) retain { SubRetains++; return self; }
+(id) retain { SubPlusRetains++; return self; }
-(oneway void) release { SubReleases++; }
+(oneway void) release { SubPlusReleases++; }
-(id) autorelease { SubAutoreleases++; return self; }
+(id) autorelease { SubPlusAutoreleases++; return self; }
-(NSUInteger) retainCount { SubRetainCounts++; return 1; }
+(NSUInteger) retainCount { SubPlusRetainCounts++; return 1; }

@end

@interface OverridingASub : NSObject @end
@implementation OverridingASub
+(id) alloc { SubAllocs++; return class_createInstance(self, 0); }
@end

@interface OverridingAWZSub : NSObject @end
@implementation OverridingAWZSub
+(id) allocWithZone:(NSZone * __unused)z { SubAllocWithZones++; return class_createInstance(self, 0); }
@end

@interface OverridingAAWZSub : NSObject @end
@implementation OverridingAAWZSub
+(id) alloc { SubAllocs++; return class_createInstance(self, 0); }
+(id) allocWithZone:(NSZone * __unused)z { SubAllocWithZones++; return class_createInstance(self, 0); }
@end


@interface InheritingSub : NSObject @end
@implementation InheritingSub @end

@interface InheritingSub2 : NSObject @end
@implementation InheritingSub2 @end
@interface InheritingSub2_2 : InheritingSub2 @end
@implementation InheritingSub2_2 @end

@interface InheritingSub3 : NSObject @end
@implementation InheritingSub3 @end
@interface InheritingSub3_2 : InheritingSub3 @end
@implementation InheritingSub3_2 @end

@interface InheritingSub4 : NSObject @end
@implementation InheritingSub4 @end
@interface InheritingSub4_2 : InheritingSub4 @end
@implementation InheritingSub4_2 @end

@interface InheritingSub5 : NSObject @end
@implementation InheritingSub5 @end
@interface InheritingSub5_2 : InheritingSub5 @end
@implementation InheritingSub5_2 @end

@interface InheritingSub6 : NSObject @end
@implementation InheritingSub6 @end
@interface InheritingSub6_2 : InheritingSub6 @end
@implementation InheritingSub6_2 @end

@interface InheritingSub7 : NSObject @end
@implementation InheritingSub7 @end
@interface InheritingSub7_2 : InheritingSub7 @end
@implementation InheritingSub7_2 @end

@interface InheritingSubCat : NSObject @end
@implementation InheritingSubCat @end
@interface InheritingSubCat_2 : InheritingSubCat @end
@implementation InheritingSubCat_2 @end


extern uintptr_t OBJC_CLASS_$_UnrealizedSubA1;
@interface UnrealizedSubA1 : NSObject @end
@implementation UnrealizedSubA1 @end
extern uintptr_t OBJC_CLASS_$_UnrealizedSubA2;
@interface UnrealizedSubA2 : NSObject @end
@implementation UnrealizedSubA2 @end
extern uintptr_t OBJC_CLASS_$_UnrealizedSubA3;
@interface UnrealizedSubA3 : NSObject @end
@implementation UnrealizedSubA3 @end

extern uintptr_t OBJC_CLASS_$_UnrealizedSubB1;
@interface UnrealizedSubB1 : NSObject @end
@implementation UnrealizedSubB1 @end
extern uintptr_t OBJC_CLASS_$_UnrealizedSubB2;
@interface UnrealizedSubB2 : NSObject @end
@implementation UnrealizedSubB2 @end
extern uintptr_t OBJC_CLASS_$_UnrealizedSubB3;
@interface UnrealizedSubB3 : NSObject @end
@implementation UnrealizedSubB3 @end

extern uintptr_t OBJC_CLASS_$_UnrealizedSubC1;
@interface UnrealizedSubC1 : NSObject @end
@implementation UnrealizedSubC1 @end
extern uintptr_t OBJC_CLASS_$_UnrealizedSubC2;
@interface UnrealizedSubC2 : NSObject @end
@implementation UnrealizedSubC2 @end
extern uintptr_t OBJC_CLASS_$_UnrealizedSubC3;
@interface UnrealizedSubC3 : NSObject @end
@implementation UnrealizedSubC3 @end


int main(int argc __unused, char **argv)
{
    objc_autoreleasePoolPush();

    // Hack NSObject's RR methods.
    // Don't use runtime functions to do this - 
    // we want the runtime to think that these are NSObject's real code
    {
        Class cls = [NSObject class];
        IMP imp = class_getMethodImplementation(cls, @selector(retain));
        Method m = class_getInstanceMethod(cls, @selector(retain));
        testassertequal(method_getImplementation(m), imp);  // verify Method struct is as we expect

        m = class_getInstanceMethod(cls, @selector(retain));
        _method_setImplementationRawUnsafe(m, (IMP)HackRetain);
        m = class_getInstanceMethod(cls, @selector(release));
        _method_setImplementationRawUnsafe(m, (IMP)HackRelease);
        m = class_getInstanceMethod(cls, @selector(autorelease));
        _method_setImplementationRawUnsafe(m, (IMP)HackAutorelease);
        m = class_getInstanceMethod(cls, @selector(retainCount));
        _method_setImplementationRawUnsafe(m, (IMP)HackRetainCount);
        m = class_getClassMethod(cls, @selector(retain));
        _method_setImplementationRawUnsafe(m, (IMP)HackPlusRetain);
        m = class_getClassMethod(cls, @selector(release));
        _method_setImplementationRawUnsafe(m, (IMP)HackPlusRelease);
        m = class_getClassMethod(cls, @selector(autorelease));
        _method_setImplementationRawUnsafe(m, (IMP)HackPlusAutorelease);
        m = class_getClassMethod(cls, @selector(retainCount));
        _method_setImplementationRawUnsafe(m, (IMP)HackPlusRetainCount);
        m = class_getClassMethod(cls, @selector(alloc));
        _method_setImplementationRawUnsafe(m, (IMP)HackAlloc);
        m = class_getClassMethod(cls, @selector(allocWithZone:));
        _method_setImplementationRawUnsafe(m, (IMP)HackAllocWithZone);

        _objc_flush_caches(cls);

        imp = class_getMethodImplementation(cls, @selector(retain));
        testassertequal(imp, (IMP)HackRetain);  // verify hack worked
    }

    Class cls = [NSObject class];
    Class icl = [InheritingSub class];
    Class ocl = [OverridingSub class];
    /*
    Class oa1 = [OverridingASub class];
    Class oa2 = [OverridingAWZSub class];
    Class oa3 = [OverridingAAWZSub class];
    */
    NSObject *obj = [NSObject new];
    InheritingSub *inh = [InheritingSub new];
    OverridingSub *ovr = [OverridingSub new];

    Class ccc;
    id ooo;
    Class cc2;
    id oo2;

#if __x86_64__
    // vtable dispatch can introduce bypass just like the ARC entrypoints
#else
    testprintf("method dispatch does not bypass\n");
    zero();
    
    [obj retain];
    testassertequal(Retains, 1);
    [obj release];
    testassertequal(Releases, 1);
    [obj autorelease];
    testassertequal(Autoreleases, 1);

    [cls retain];
    testassertequal(PlusRetains, 1);
    [cls release];
    testassertequal(PlusReleases, 1);
    [cls autorelease];
    testassertequal(PlusAutoreleases, 1);

    [inh retain];
    testassertequal(Retains, 2);
    [inh release];
    testassertequal(Releases, 2);
    [inh autorelease];
    testassertequal(Autoreleases, 2);

    [icl retain];
    testassertequal(PlusRetains, 2);
    [icl release];
    testassertequal(PlusReleases, 2);
    [icl autorelease];
    testassertequal(PlusAutoreleases, 2);
    
    [ovr retain];
    testassertequal(SubRetains, 1);
    [ovr release];
    testassertequal(SubReleases, 1);
    [ovr autorelease];
    testassertequal(SubAutoreleases, 1);

    [ocl retain];
    testassertequal(SubPlusRetains, 1);
    [ocl release];
    testassertequal(SubPlusReleases, 1);
    [ocl autorelease];
    testassertequal(SubPlusAutoreleases, 1);

    [UnrealizedSubA1 retain];
    testassertequal(PlusRetains, 3);
    [UnrealizedSubA2 release];
    testassertequal(PlusReleases, 3);
    [UnrealizedSubA3 autorelease];
    testassertequal(PlusAutoreleases, 3);
#endif


    testprintf("objc_msgSend() does not bypass\n");
    zero();

    id (*retain_fn)(id, SEL) = (id(*)(id, SEL))objc_msgSend;
    void (*release_fn)(id, SEL) = (void(*)(id, SEL))objc_msgSend;
    id (*autorelease_fn)(id, SEL) = (id(*)(id, SEL))objc_msgSend;

    retain_fn(obj, @selector(retain));
    testassertequal(Retains, 1);
    release_fn(obj, @selector(release));
    testassertequal(Releases, 1);
    autorelease_fn(obj, @selector(autorelease));
    testassertequal(Autoreleases, 1);

    retain_fn(cls, @selector(retain));
    testassertequal(PlusRetains, 1);
    release_fn(cls, @selector(release));
    testassertequal(PlusReleases, 1);
    autorelease_fn(cls, @selector(autorelease));
    testassertequal(PlusAutoreleases, 1);

    retain_fn(inh, @selector(retain));
    testassertequal(Retains, 2);
    release_fn(inh, @selector(release));
    testassertequal(Releases, 2);
    autorelease_fn(inh, @selector(autorelease));
    testassertequal(Autoreleases, 2);

    retain_fn(icl, @selector(retain));
    testassertequal(PlusRetains, 2);
    release_fn(icl, @selector(release));
    testassertequal(PlusReleases, 2);
    autorelease_fn(icl, @selector(autorelease));
    testassertequal(PlusAutoreleases, 2);
    
    retain_fn(ovr, @selector(retain));
    testassertequal(SubRetains, 1);
    release_fn(ovr, @selector(release));
    testassertequal(SubReleases, 1);
    autorelease_fn(ovr, @selector(autorelease));
    testassertequal(SubAutoreleases, 1);

    retain_fn(ocl, @selector(retain));
    testassertequal(SubPlusRetains, 1);
    release_fn(ocl, @selector(release));
    testassertequal(SubPlusReleases, 1);
    autorelease_fn(ocl, @selector(autorelease));
    testassertequal(SubPlusAutoreleases, 1);

    retain_fn((Class)&OBJC_CLASS_$_UnrealizedSubB1, @selector(retain));
    testassertequal(PlusRetains, 3);
    release_fn((Class)&OBJC_CLASS_$_UnrealizedSubB2, @selector(release));
    testassertequal(PlusReleases, 3);
    autorelease_fn((Class)&OBJC_CLASS_$_UnrealizedSubB3, @selector(autorelease));
    testassertequal(PlusAutoreleases, 3);


    testprintf("arc function bypasses instance but not class or override\n");
    zero();
    
    objc_retain(obj);
    testassertequal(Retains, 0);
    objc_release(obj);
    testassertequal(Releases, 0);
    objc_autorelease(obj);
    testassertequal(Autoreleases, 0);

    objc_retain(cls);
    testassertequal(PlusRetains, 0);
    objc_release(cls);
    testassertequal(PlusReleases, 0);
    objc_autorelease(cls);
    testassertequal(PlusAutoreleases, 0);

    objc_retain(inh);
    testassertequal(Retains, 0);
    objc_release(inh);
    testassertequal(Releases, 0);
    objc_autorelease(inh);
    testassertequal(Autoreleases, 0);

    objc_retain(icl);
    testassertequal(PlusRetains, 0);
    objc_release(icl);
    testassertequal(PlusReleases, 0);
    objc_autorelease(icl);
    testassertequal(PlusAutoreleases, 0);

    objc_retain(ovr);
    testassertequal(SubRetains, 1);
    objc_release(ovr);
    testassertequal(SubReleases, 1);
    objc_autorelease(ovr);
    testassertequal(SubAutoreleases, 1);

    objc_retain(ocl);
    testassertequal(SubPlusRetains, 1);
    objc_release(ocl);
    testassertequal(SubPlusReleases, 1);
    objc_autorelease(ocl);
    testassertequal(SubPlusAutoreleases, 1);

    objc_retain((Class)&OBJC_CLASS_$_UnrealizedSubC1);
    testassertequal(PlusRetains, 1);
    objc_release((Class)&OBJC_CLASS_$_UnrealizedSubC2);
    testassertequal(PlusReleases, 1);
    objc_autorelease((Class)&OBJC_CLASS_$_UnrealizedSubC3);
    testassertequal(PlusAutoreleases, 1);

    testprintf("unrelated addMethod does not clobber\n");
    zero();

    class_addMethod(cls, @selector(unrelatedMethod), (IMP)imp_fn, "");
    
    objc_retain(obj);
    testassertequal(Retains, 0);
    objc_release(obj);
    testassertequal(Releases, 0);
    objc_autorelease(obj);
    testassertequal(Autoreleases, 0);


    testprintf("add class method does not clobber\n");
    zero();
    
    objc_retain(obj);
    testassertequal(Retains, 0);
    objc_release(obj);
    testassertequal(Releases, 0);
    objc_autorelease(obj);
    testassertequal(Autoreleases, 0);

    class_addMethod(object_getClass(cls), @selector(retain), (IMP)imp_fn, "");
    
    objc_retain(obj);
    testassertequal(Retains, 0);
    objc_release(obj);
    testassertequal(Releases, 0);
    objc_autorelease(obj);
    testassertequal(Autoreleases, 0);


    testprintf("addMethod clobbers (InheritingSub2, retain)\n");
    zero();

    ccc = [InheritingSub2 class];
    ooo = [ccc new];
    cc2 = [InheritingSub2_2 class];
    oo2 = [cc2 new];
    
    objc_retain(ooo);
    testassertequal(Retains, 0);
    objc_release(ooo);
    testassertequal(Releases, 0);
    objc_autorelease(ooo);
    testassertequal(Autoreleases, 0);

    objc_retain(oo2);
    testassertequal(Retains, 0);
    objc_release(oo2);
    testassertequal(Releases, 0);
    objc_autorelease(oo2);
    testassertequal(Autoreleases, 0);

    class_addMethod(ccc, @selector(retain), (IMP)imp_fn, "");

    objc_retain(ooo);
    testassertequal(Retains, 0);
    testassertequal(Imps, 1);
    objc_release(ooo);
    testassertequal(Releases, 1);
    objc_autorelease(ooo);
    testassertequal(Autoreleases, 1);

    objc_retain(oo2);
    testassertequal(Retains, 0);
    testassertequal(Imps, 2);
    objc_release(oo2);
    testassertequal(Releases, 2);
    objc_autorelease(oo2);
    testassertequal(Autoreleases, 2);


    testprintf("addMethod clobbers (InheritingSub3, release)\n");
    zero();

    ccc = [InheritingSub3 class];
    ooo = [ccc new];
    cc2 = [InheritingSub3_2 class];
    oo2 = [cc2 new];
    
    objc_retain(ooo);
    testassertequal(Retains, 0);
    objc_release(ooo);
    testassertequal(Releases, 0);
    objc_autorelease(ooo);
    testassertequal(Autoreleases, 0);
    
    objc_retain(oo2);
    testassertequal(Retains, 0);
    objc_release(oo2);
    testassertequal(Releases, 0);
    objc_autorelease(oo2);
    testassertequal(Autoreleases, 0);

    class_addMethod(ccc, @selector(release), (IMP)imp_fn, "");

    objc_retain(ooo);
    testassertequal(Retains, 1);
    objc_release(ooo);
    testassertequal(Releases, 0);
    testassertequal(Imps, 1);
    objc_autorelease(ooo);
    testassertequal(Autoreleases, 1);

    objc_retain(oo2);
    testassertequal(Retains, 2);
    objc_release(oo2);
    testassertequal(Releases, 0);
    testassertequal(Imps, 2);
    objc_autorelease(oo2);
    testassertequal(Autoreleases, 2);


    testprintf("addMethod clobbers (InheritingSub4, autorelease)\n");
    zero();

    ccc = [InheritingSub4 class];
    ooo = [ccc new];
    cc2 = [InheritingSub4_2 class];
    oo2 = [cc2 new];
    
    objc_retain(ooo);
    testassertequal(Retains, 0);
    objc_release(ooo);
    testassertequal(Releases, 0);
    objc_autorelease(ooo);
    testassertequal(Autoreleases, 0);
    
    objc_retain(oo2);
    testassertequal(Retains, 0);
    objc_release(oo2);
    testassertequal(Releases, 0);
    objc_autorelease(oo2);
    testassertequal(Autoreleases, 0);

    class_addMethod(ccc, @selector(autorelease), (IMP)imp_fn, "");

    objc_retain(ooo);
    testassertequal(Retains, 1);
    objc_release(ooo);
    testassertequal(Releases, 1);
    objc_autorelease(ooo);
    testassertequal(Autoreleases, 0);
    testassertequal(Imps, 1);

    objc_retain(oo2);
    testassertequal(Retains, 2);
    objc_release(oo2);
    testassertequal(Releases, 2);
    objc_autorelease(oo2);
    testassertequal(Autoreleases, 0);
    testassertequal(Imps, 2);


    testprintf("addMethod clobbers (InheritingSub5, retainCount)\n");
    zero();

    ccc = [InheritingSub5 class];
    ooo = [ccc new];
    cc2 = [InheritingSub5_2 class];
    oo2 = [cc2 new];
    
    objc_retain(ooo);
    testassertequal(Retains, 0);
    objc_release(ooo);
    testassertequal(Releases, 0);
    objc_autorelease(ooo);
    testassertequal(Autoreleases, 0);

    objc_retain(oo2);
    testassertequal(Retains, 0);
    objc_release(oo2);
    testassertequal(Releases, 0);
    objc_autorelease(oo2);
    testassertequal(Autoreleases, 0);

    class_addMethod(ccc, @selector(retainCount), (IMP)imp_fn, "");

    objc_retain(ooo);
    testassertequal(Retains, 1);
    objc_release(ooo);
    testassertequal(Releases, 1);
    objc_autorelease(ooo);
    testassertequal(Autoreleases, 1);
    // no bypassing call for -retainCount

    objc_retain(oo2);
    testassertequal(Retains, 2);
    objc_release(oo2);
    testassertequal(Releases, 2);
    objc_autorelease(oo2);
    testassertequal(Autoreleases, 2);
    // no bypassing call for -retainCount


    testprintf("setSuperclass to clean super does not clobber (InheritingSub6)\n");
    zero();

    ccc = [InheritingSub6 class];
    ooo = [ccc new];
    cc2 = [InheritingSub6_2 class];
    oo2 = [cc2 new];
    
    objc_retain(ooo);
    testassertequal(Retains, 0);
    objc_release(ooo);
    testassertequal(Releases, 0);
    objc_autorelease(ooo);
    testassertequal(Autoreleases, 0);

    objc_retain(oo2);
    testassertequal(Retains, 0);
    objc_release(oo2);
    testassertequal(Releases, 0);
    objc_autorelease(oo2);
    testassertequal(Autoreleases, 0);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    class_setSuperclass(ccc, [InheritingSub class]);
#pragma clang diagnostic pop

    objc_retain(ooo);
    testassertequal(Retains, 0);
    objc_release(ooo);
    testassertequal(Releases, 0);
    objc_autorelease(ooo);
    testassertequal(Autoreleases, 0);
    
    objc_retain(oo2);
    testassertequal(Retains, 0);
    objc_release(oo2);
    testassertequal(Releases, 0);
    objc_autorelease(oo2);
    testassertequal(Autoreleases, 0);


    testprintf("setSuperclass to dirty super clobbers (InheritingSub7)\n");
    zero();

    ccc = [InheritingSub7 class];
    ooo = [ccc new];
    cc2 = [InheritingSub7_2 class];
    oo2 = [cc2 new];
    
    objc_retain(ooo);
    testassertequal(Retains, 0);
    objc_release(ooo);
    testassertequal(Releases, 0);
    objc_autorelease(ooo);
    testassertequal(Autoreleases, 0);
    
    objc_retain(oo2);
    testassertequal(Retains, 0);
    objc_release(oo2);
    testassertequal(Releases, 0);
    objc_autorelease(oo2);
    testassertequal(Autoreleases, 0);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    class_setSuperclass(ccc, [OverridingSub class]);
#pragma clang diagnostic pop

    objc_retain(ooo);
    testassertequal(SubRetains, 1);
    objc_release(ooo);
    testassertequal(SubReleases, 1);
    objc_autorelease(ooo);
    testassertequal(SubAutoreleases, 1);

    objc_retain(oo2);
    testassertequal(SubRetains, 2);
    objc_release(oo2);
    testassertequal(SubReleases, 2);
    objc_autorelease(oo2);
    testassertequal(SubAutoreleases, 2);

    // These tests required dlopen()
#if !TARGET_OS_EXCLAVEKIT
    void *dlh;

    testprintf("category replacement of unrelated method does not clobber (InheritingSubCat)\n");
    zero();

    ccc = [InheritingSubCat class];
    ooo = [ccc new];
    cc2 = [InheritingSubCat_2 class];
    oo2 = [cc2 new];
    
    objc_retain(ooo);
    testassertequal(Retains, 0);
    objc_release(ooo);
    testassertequal(Releases, 0);
    objc_autorelease(ooo);
    testassertequal(Autoreleases, 0);

    objc_retain(oo2);
    testassertequal(Retains, 0);
    objc_release(oo2);
    testassertequal(Releases, 0);
    objc_autorelease(oo2);
    testassertequal(Autoreleases, 0);

    dlh = dlopen("customrr-cat1.bundle", RTLD_LAZY);
    testassert(dlh);

    objc_retain(ooo);
    testassertequal(Retains, 0);
    objc_release(ooo);
    testassertequal(Releases, 0);
    objc_autorelease(ooo);
    testassertequal(Autoreleases, 0);

    objc_retain(oo2);
    testassertequal(Retains, 0);
    objc_release(oo2);
    testassertequal(Releases, 0);
    objc_autorelease(oo2);
    testassertequal(Autoreleases, 0);

    testprintf("category replacement clobbers (InheritingSubCat)\n");
    zero();

    ccc = [InheritingSubCat class];
    ooo = [ccc new];
    cc2 = [InheritingSubCat_2 class];
    oo2 = [cc2 new];
    
    objc_retain(ooo);
    testassertequal(Retains, 0);
    objc_release(ooo);
    testassertequal(Releases, 0);
    objc_autorelease(ooo);
    testassertequal(Autoreleases, 0);

    objc_retain(oo2);
    testassertequal(Retains, 0);
    objc_release(oo2);
    testassertequal(Releases, 0);
    objc_autorelease(oo2);
    testassertequal(Autoreleases, 0);

    dlh = dlopen("customrr-cat2.bundle", RTLD_LAZY);
    testassert(dlh);

    objc_retain(ooo);
    testassertequal(Retains, 1);
    objc_release(ooo);
    testassertequal(Releases, 1);
    objc_autorelease(ooo);
    testassertequal(Autoreleases, 1);

    objc_retain(oo2);
    testassertequal(Retains, 2);
    objc_release(oo2);
    testassertequal(Releases, 2);
    objc_autorelease(oo2);
    testassertequal(Autoreleases, 2);
#endif // !TARGET_OS_EXCLAVEKIT

    testprintf("allocateClassPair with clean super does not clobber\n");
    zero();

    objc_retain(inh);
    testassertequal(Retains, 0);
    objc_release(inh);
    testassertequal(Releases, 0);
    objc_autorelease(inh);
    testassertequal(Autoreleases, 0);

    ccc = objc_allocateClassPair([InheritingSub class], "CleanClassPair", 0);
    objc_registerClassPair(ccc);
    ooo = [ccc new];

    objc_retain(inh);
    testassertequal(Retains, 0);
    objc_release(inh);
    testassertequal(Releases, 0);
    objc_autorelease(inh);
    testassertequal(Autoreleases, 0);
    
    objc_retain(ooo);
    testassertequal(Retains, 0);
    objc_release(ooo);
    testassertequal(Releases, 0);
    objc_autorelease(ooo);
    testassertequal(Autoreleases, 0);


    testprintf("allocateClassPair with clobbered super clobbers\n");
    zero();

    ccc = objc_allocateClassPair([OverridingSub class], "DirtyClassPair", 0);
    objc_registerClassPair(ccc);
    ooo = [ccc new];
    
    objc_retain(ooo);
    testassertequal(SubRetains, 1);
    objc_release(ooo);
    testassertequal(SubReleases, 1);
    objc_autorelease(ooo);
    testassertequal(SubAutoreleases, 1);


    testprintf("allocateClassPair with clean super and override clobbers\n");
    zero();

    ccc = objc_allocateClassPair([InheritingSub class], "Dirty2ClassPair", 0);
    class_addMethod(ccc, @selector(autorelease), (IMP)imp_fn, "");
    objc_registerClassPair(ccc);
    ooo = [ccc new];
    
    objc_retain(ooo);
    testassertequal(Retains, 1);
    objc_release(ooo);
    testassertequal(Releases, 1);
    objc_autorelease(ooo);
    testassertequal(Autoreleases, 0);
    testassertequal(Imps, 1);


    // method_setImplementation and method_exchangeImplementations only 
    // clobber when manipulating NSObject. We can only test one at a time.
    // To test both, we need two tests: customrr and customrr2.

    // These tests also check recursive clobber.

#if TEST_EXCHANGEIMPLEMENTATIONS
    testprintf("exchangeImplementations clobbers (recursive)\n");
#else
    testprintf("setImplementation clobbers (recursive)\n");
#endif
    zero();

    objc_retain(obj);
    testassertequal(Retains, 0);
    objc_release(obj);
    testassertequal(Releases, 0);
    objc_autorelease(obj);
    testassertequal(Autoreleases, 0);

    objc_retain(inh);
    testassertequal(Retains, 0);
    objc_release(inh);
    testassertequal(Releases, 0);
    objc_autorelease(inh);
    testassertequal(Autoreleases, 0);

    Method meth = class_getInstanceMethod(cls, @selector(retainCount));
    testassert(meth);
#if TEST_EXCHANGEIMPLEMENTATIONS
    method_exchangeImplementations(meth, meth);
#else
    method_setImplementation(meth, (IMP)imp_fn);
#endif
    
    objc_retain(obj);
    testassertequal(Retains, 1);
    objc_release(obj);
    testassertequal(Releases, 1);
    objc_autorelease(obj);
    testassertequal(Autoreleases, 1);

    objc_retain(inh);
    testassertequal(Retains, 2);
    objc_release(inh);
    testassertequal(Releases, 2);
    objc_autorelease(inh);
    testassertequal(Autoreleases, 2);

    
    // do not add more tests here - the recursive test must be LAST

    succeed(basename(argv[0]));
}
