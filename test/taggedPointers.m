// TEST_CONFIG

#include "test.h"
#include <objc/runtime.h>
#include <objc/objc-internal.h>
#import <Foundation/NSObject.h>

#if __has_feature(objc_arc)

int main()
{
    testwarn("rdar://11368528 confused by Foundation");
    succeed(__FILE__);
}

#else

#if __OBJC2__ && __LP64__

static BOOL didIt;

#define TAG_VALUE(tagSlot, value) (objc_unretainedObject((void*)(1UL | (((uintptr_t)(tagSlot)) << 1) | (((uintptr_t)(value)) << 4))))

@interface WeakContainer : NSObject
{
  @public
    __weak id weaks[10000];
}
@end
@implementation WeakContainer
-(void) dealloc {
    for (unsigned int i = 0; i < sizeof(weaks)/sizeof(weaks[0]); i++) {
        testassert(weaks[i] == nil);
    }
    SUPER_DEALLOC();
}
-(void) finalize {
    for (unsigned int i = 0; i < sizeof(weaks)/sizeof(weaks[0]); i++) {
        testassert(weaks[i] == nil);
    }
    [super finalize];
}
@end

@interface TaggedBaseClass
@end

@implementation TaggedBaseClass
+ (void) initialize {
}

- (void) instanceMethod {
    didIt = YES;
}

- (uintptr_t) taggedValue {
    return (uintptr_t)objc_unretainedPointer(self) >> 4;
}

- (struct stret) stret: (struct stret) aStruct {
    return aStruct;
}

- (long double) fpret: (long double) aValue {
    return aValue;
}


-(void) dealloc {
    fail("TaggedBaseClass dealloc called!");
}

static void *
retain_fn(void *self, SEL _cmd __unused) {
    void * (*fn)(void *) = (typeof(fn))_objc_rootRetain;
    return fn(self); 
}

static void 
release_fn(void *self, SEL _cmd __unused) {
    void (*fn)(void *) = (typeof(fn))_objc_rootRelease;
    fn(self); 
}

static void *
autorelease_fn(void *self, SEL _cmd __unused) { 
    void * (*fn)(void *) = (typeof(fn))_objc_rootAutorelease;
    return fn(self); 
}

static unsigned long 
retaincount_fn(void *self, SEL _cmd __unused) { 
    unsigned long (*fn)(void *) = (typeof(fn))_objc_rootRetainCount;
    return fn(self); 
}

+(void) load {
    class_addMethod(self, sel_registerName("retain"), (IMP)retain_fn, "");
    class_addMethod(self, sel_registerName("release"), (IMP)release_fn, "");
    class_addMethod(self, sel_registerName("autorelease"), (IMP)autorelease_fn, "");
    class_addMethod(self, sel_registerName("retainCount"), (IMP)retaincount_fn, "");    
}

@end

@interface TaggedSubclass: TaggedBaseClass
@end

@implementation TaggedSubclass

- (void) instanceMethod {
    return [super instanceMethod];
}

- (uintptr_t) taggedValue {
    return [super taggedValue];
}

- (struct stret) stret: (struct stret) aStruct {
    return [super stret: aStruct];
}

- (long double) fpret: (long double) aValue {
    return [super fpret: aValue];
}
@end

@interface TaggedNSObjectSubclass : NSObject
@end

@implementation TaggedNSObjectSubclass

- (void) instanceMethod {
    didIt = YES;
}

- (uintptr_t) taggedValue {
    return (uintptr_t)objc_unretainedPointer(self) >> 4;
}

- (struct stret) stret: (struct stret) aStruct {
    return aStruct;
}

- (long double) fpret: (long double) aValue {
    return aValue;
}
@end

void testGenericTaggedPointer(uint8_t tagSlot, const char *classname)
{
    testprintf("%s\n", classname);

    Class cls = objc_getClass(classname);
    testassert(cls);

    id taggedPointer = TAG_VALUE(tagSlot, 1234);
    testassert(object_getClass(taggedPointer) == cls);
    testassert([taggedPointer taggedValue] == 1234);

    didIt = NO;
    [taggedPointer instanceMethod];
    testassert(didIt);    
    
    struct stret orig = STRET_RESULT;
    testassert(stret_equal(orig, [taggedPointer stret: orig]));
    
    long double value = 3.14156789;
    testassert(value == [taggedPointer fpret: value]);

    // Tagged pointers should bypass refcount tables and autorelease pools
    // and weak reference tables
    WeakContainer *w = [WeakContainer new];
    leak_mark();
    for (uintptr_t i = 0; i < sizeof(w->weaks)/sizeof(w->weaks[0]); i++) {
        id o = TAG_VALUE(tagSlot, i);
        testassert(object_getClass(o) == cls);
        
        id result = WEAK_STORE(w->weaks[i], o);
        testassert(result == o);
        testassert(w->weaks[i] == o);
        
        result = WEAK_LOAD(w->weaks[i]);
        testassert(result == o);
        
        if (!objc_collectingEnabled()) {
            uintptr_t rc = _objc_rootRetainCount(o);
            testassert(rc != 0);
            _objc_rootRelease(o);  testassert(_objc_rootRetainCount(o) == rc);
            _objc_rootRelease(o);  testassert(_objc_rootRetainCount(o) == rc);
            _objc_rootRetain(o);   testassert(_objc_rootRetainCount(o) == rc);
            _objc_rootRetain(o);   testassert(_objc_rootRetainCount(o) == rc);
            _objc_rootRetain(o);   testassert(_objc_rootRetainCount(o) == rc);
#if !__has_feature(objc_arc)
            [o release];  testassert(_objc_rootRetainCount(o) == rc);
            [o release];  testassert(_objc_rootRetainCount(o) == rc);
            [o retain];   testassert(_objc_rootRetainCount(o) == rc);
            [o retain];   testassert(_objc_rootRetainCount(o) == rc);
            [o retain];   testassert(_objc_rootRetainCount(o) == rc);
            objc_release(o);  testassert(_objc_rootRetainCount(o) == rc);
            objc_release(o);  testassert(_objc_rootRetainCount(o) == rc);
            objc_retain(o);   testassert(_objc_rootRetainCount(o) == rc);
            objc_retain(o);   testassert(_objc_rootRetainCount(o) == rc);
            objc_retain(o);   testassert(_objc_rootRetainCount(o) == rc);
#endif
            PUSH_POOL {
                testassert(_objc_rootRetainCount(o) == rc);
                _objc_rootAutorelease(o);
                testassert(_objc_rootRetainCount(o) == rc);
#if !__has_feature(objc_arc)
                [o autorelease];
                testassert(_objc_rootRetainCount(o) == rc);
                objc_autorelease(o);
                testassert(_objc_rootRetainCount(o) == rc);
                objc_retainAutorelease(o);
                testassert(_objc_rootRetainCount(o) == rc);
                objc_autoreleaseReturnValue(o);
                testassert(_objc_rootRetainCount(o) == rc);
                objc_retainAutoreleaseReturnValue(o);
                testassert(_objc_rootRetainCount(o) == rc);
                objc_retainAutoreleasedReturnValue(o);
                testassert(_objc_rootRetainCount(o) == rc);
#endif
            } POP_POOL;
            testassert(_objc_rootRetainCount(o) == rc);
        }
    }
    leak_check(0);
    for (uintptr_t i = 0; i < 10000; i++) {
        testassert(w->weaks[i] != NULL);
        WEAK_STORE(w->weaks[i], NULL);
        testassert(w->weaks[i] == NULL);
        testassert(WEAK_LOAD(w->weaks[i]) == NULL);
    }
    RELEASE_VAR(w);
}

int main()
{
    PUSH_POOL {    
        _objc_insert_tagged_isa(5, objc_getClass("TaggedBaseClass"));
        testGenericTaggedPointer(5, "TaggedBaseClass");
        
        _objc_insert_tagged_isa(2, objc_getClass("TaggedSubclass"));
        testGenericTaggedPointer(2, "TaggedSubclass");
        
        _objc_insert_tagged_isa(3, objc_getClass("TaggedNSObjectSubclass"));
        testGenericTaggedPointer(3, "TaggedNSObjectSubclass");
    } POP_POOL;

    succeed(__FILE__);
}

// OBJC2 && __LP64__
#else
// not (OBJC2 && __LP64__)

    // Tagged pointers not supported.

int main() 
{
    succeed(__FILE__);
}

#endif

#endif
