// TEST_CONFIG

#include "test.h"

#include <pthread.h>
#include "objc/objc-internal.h"
#include "testroot.i"

static unsigned ctors1 = 0;
static unsigned dtors1 = 0;
static unsigned ctors2 = 0;
static unsigned dtors2 = 0;

class cxx1 {
    unsigned & ctors;
    unsigned& dtors;

  public:
    cxx1() : ctors(ctors1), dtors(dtors1) { ctors++; }

    ~cxx1() { dtors++; }
};
class cxx2 {
    unsigned& ctors;
    unsigned& dtors;

  public:
    cxx2() : ctors(ctors2), dtors(dtors2) { ctors++; }

    ~cxx2() { dtors++; }
};

/*
  Class hierarchy:
  TestRoot
   CXXBase
    NoCXXSub
     CXXSub

  This has two cxx-wielding classes, and a class in between without cxx.
*/


@interface CXXBase : TestRoot {
    cxx1 baseIvar;
}
@end
@implementation CXXBase @end

@interface NoCXXSub : CXXBase {
    int nocxxIvar;
}
@end
@implementation NoCXXSub @end

@interface CXXSub : NoCXXSub {
    cxx2 subIvar;
}
@end
@implementation CXXSub @end


void test_single(void) 
{
    // Single allocation

    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    testonthread(^{
        id o = [TestRoot new];
        testassert(ctors1 == 0  &&  dtors1 == 0  &&  
                   ctors2 == 0  &&  dtors2 == 0);
        testassert([o class] == [TestRoot class]);
        RELEASE_VAR(o);
    });
    testcollect();
    testassert(ctors1 == 0  &&  dtors1 == 0  &&  
               ctors2 == 0  &&  dtors2 == 0);

    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    testonthread(^{
        id o = [CXXBase new];
        testassert(ctors1 == 1  &&  dtors1 == 0  &&  
                   ctors2 == 0  &&  dtors2 == 0);
        testassert([o class] == [CXXBase class]);
        RELEASE_VAR(o);
    });
    testcollect();
    testassert(ctors1 == 1  &&  dtors1 == 1  &&  
               ctors2 == 0  &&  dtors2 == 0);

    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    testonthread(^{
        id o = [NoCXXSub new];
        testassert(ctors1 == 1  &&  dtors1 == 0  &&  
                   ctors2 == 0  &&  dtors2 == 0);
        testassert([o class] == [NoCXXSub class]);
        RELEASE_VAR(o);
    });
    testcollect();
    testassert(ctors1 == 1  &&  dtors1 == 1  &&  
               ctors2 == 0  &&  dtors2 == 0);

    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    testonthread(^{
        id o = [CXXSub new];
        testassert(ctors1 == 1  &&  dtors1 == 0  &&  
                   ctors2 == 1  &&  dtors2 == 0);
        testassert([o class] == [CXXSub class]);
        RELEASE_VAR(o);
    });
    testcollect();
    testassert(ctors1 == 1  &&  dtors1 == 1  &&  
               ctors2 == 1  &&  dtors2 == 1);
}

void test_inplace(void) 
{
    __unsafe_unretained volatile id o;
    char o2[64];

    id (*objc_constructInstance_fn)(Class, void*) = (id(*)(Class, void*))dlsym(RTLD_DEFAULT, "objc_constructInstance");
    void (*objc_destructInstance_fn)(id) = (void(*)(id))dlsym(RTLD_DEFAULT, "objc_destructInstance");

    // In-place allocation

    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    o = objc_constructInstance_fn([TestRoot class], o2);
    testassert(ctors1 == 0  &&  dtors1 == 0  &&  
               ctors2 == 0  &&  dtors2 == 0);
    testassert([o class] == [TestRoot class]);
    objc_destructInstance_fn(o), o = nil;
    testcollect();
    testassert(ctors1 == 0  &&  dtors1 == 0  &&  
               ctors2 == 0  &&  dtors2 == 0);

    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    o = objc_constructInstance_fn([CXXBase class], o2);
    testassert(ctors1 == 1  &&  dtors1 == 0  &&  
               ctors2 == 0  &&  dtors2 == 0);
    testassert([o class] == [CXXBase class]);
    objc_destructInstance_fn(o), o = nil;
    testcollect();
    testassert(ctors1 == 1  &&  dtors1 == 1  &&  
               ctors2 == 0  &&  dtors2 == 0);

    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    o = objc_constructInstance_fn([NoCXXSub class], o2);
    testassert(ctors1 == 1  &&  dtors1 == 0  &&  
               ctors2 == 0  &&  dtors2 == 0);
    testassert([o class] == [NoCXXSub class]);
    objc_destructInstance_fn(o), o = nil;
    testcollect();
    testassert(ctors1 == 1  &&  dtors1 == 1  &&  
               ctors2 == 0  &&  dtors2 == 0);

    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    o = objc_constructInstance_fn([CXXSub class], o2);
    testassert(ctors1 == 1  &&  dtors1 == 0  &&  
               ctors2 == 1  &&  dtors2 == 0);
    testassert([o class] == [CXXSub class]);
    objc_destructInstance_fn(o), o = nil;
    testcollect();
    testassert(ctors1 == 1  &&  dtors1 == 1  &&  
               ctors2 == 1  &&  dtors2 == 1);
}


void test_batch(void) 
{
#if __has_feature(objc_arc) 
    // not converted to ARC yet
    return;
#else

    id o2[100];
    unsigned int count, i;

    // Batch allocation

    for (i = 0; i < 100; i++) {
        o2[i] = (id)malloc(class_getInstanceSize([TestRoot class]));
    }
    for (i = 0; i < 100; i++) {
        free(o2[i]);
    }

    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    count = class_createInstances([TestRoot class], 0, o2, 10);
    testassert(count > 0);
    testassert(ctors1 == 0  &&  dtors1 == 0  &&  
               ctors2 == 0  &&  dtors2 == 0);
    for (i = 0; i < count; i++) testassert([o2[i] class] == [TestRoot class]);
    for (i = 0; i < count; i++) object_dispose(o2[i]), o2[i] = nil;
    testcollect();
    testassert(ctors1 == 0  &&  dtors1 == 0  &&  
               ctors2 == 0  &&  dtors2 == 0);

    for (i = 0; i < 100; i++) {
        // prime batch allocator
        free(malloc(class_getInstanceSize([TestRoot class])));
    }
    
    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    count = class_createInstances([CXXBase class], 0, o2, 10);
    testassert(count > 0);
    testassert(ctors1 == count  &&  dtors1 == 0  &&  
               ctors2 == 0  &&  dtors2 == 0);
    for (i = 0; i < count; i++) testassert([o2[i] class] == [CXXBase class]);
    for (i = 0; i < count; i++) object_dispose(o2[i]), o2[i] = nil;
    testcollect();
    testassert(ctors1 == count  &&  dtors1 == count  &&  
               ctors2 == 0  &&  dtors2 == 0);

    for (i = 0; i < 100; i++) {
        // prime batch allocator
        free(malloc(class_getInstanceSize([TestRoot class])));
    }
    
    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    count = class_createInstances([NoCXXSub class], 0, o2, 10);
    testassert(count > 0);
    testassert(ctors1 == count  &&  dtors1 == 0  &&  
               ctors2 == 0  &&  dtors2 == 0);
    for (i = 0; i < count; i++) testassert([o2[i] class] == [NoCXXSub class]);
    for (i = 0; i < count; i++) object_dispose(o2[i]), o2[i] = nil;
    testcollect();
    testassert(ctors1 == count  &&  dtors1 == count  &&  
               ctors2 == 0  &&  dtors2 == 0);

    for (i = 0; i < 100; i++) {
        // prime batch allocator
        free(malloc(class_getInstanceSize([TestRoot class])));
    }
    
    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    count = class_createInstances([CXXSub class], 0, o2, 10);
    testassert(count > 0);
    testassert(ctors1 == count  &&  dtors1 == 0  &&  
               ctors2 == count  &&  dtors2 == 0);
    for (i = 0; i < count; i++) testassert([o2[i] class] == [CXXSub class]);
    for (i = 0; i < count; i++) object_dispose(o2[i]), o2[i] = nil;
    testcollect();
    testassert(ctors1 == count  &&  dtors1 == count  &&  
               ctors2 == count  &&  dtors2 == count);
#endif
}

int main()
{
    testonthread(^{ test_single(); });
    testonthread(^{ test_inplace(); });

    leak_mark();

    testonthread(^{ test_batch(); });

    // fixme can't get this to zero; may or may not be a real leak
    leak_check(64);

    // fixme ctor exceptions aren't caught inside .cxx_construct ?
    // Single allocation, ctors fail
    // In-place allocation, ctors fail
    // Batch allocation, ctors fail for every object
    // Batch allocation, ctors fail for every other object

    succeed(__FILE__);
}
