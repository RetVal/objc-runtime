// TEST_CONFIG CC=clang MEM=mrc
// TEST_CFLAGS -Os

#include "test.h"

#if __i386__

int main()
{
    // no optimization on i386 (neither Mac nor Simulator)
    succeed(__FILE__);
}

#else

#include <objc/objc-internal.h>
#include <objc/objc-abi.h>
#include <Foundation/Foundation.h>

static int did_dealloc;

@interface TestObject : NSObject
@end
@implementation TestObject
-(void)dealloc
{
    did_dealloc = 1;
    [super dealloc];
}
@end

// rdar://9319305 clang transforms objc_retainAutoreleasedReturnValue() 
// into objc_retain() sometimes
extern id objc_retainAutoreleasedReturnValue(id obj) __asm__("_objc_retainAutoreleasedReturnValue");

int
main()
{
    TestObject *tmp, *obj;
    
#ifdef __x86_64__
    // need to get DYLD to resolve the stubs on x86
    PUSH_POOL {
        TestObject *warm_up = [[TestObject alloc] init];
        testassert(warm_up);
        warm_up = objc_retainAutoreleasedReturnValue(_objc_rootAutorelease(warm_up));
        [warm_up release];
        warm_up = nil;
    } POP_POOL;
#endif
    
    testprintf("Successful return autorelease handshake\n");
    
    PUSH_POOL {
        obj = [[TestObject alloc] init];
        testassert(obj);
        
        did_dealloc = 0;
        tmp = _objc_rootAutorelease(obj);
#ifdef __arm__
        asm volatile("mov r7, r7");
#endif
        tmp = objc_retainAutoreleasedReturnValue(tmp);
        testassert(!did_dealloc);
        
        did_dealloc = 0;
        [tmp release];
        testassert(did_dealloc);
        
        did_dealloc = 0;
    } POP_POOL;
    testassert(!did_dealloc);
    
    
    testprintf("Failed return autorelease handshake\n");
    
    PUSH_POOL {
        obj = [[TestObject alloc] init];
        testassert(obj);
        
        did_dealloc = 0;
        tmp = _objc_rootAutorelease(obj);
#ifdef __arm__
        asm volatile("mov r6, r6");
#elif __x86_64__
        asm volatile("mov %rdi, %rdi");
#endif
        tmp = objc_retainAutoreleasedReturnValue(tmp);
        testassert(!did_dealloc);
        
        did_dealloc = 0;
        [tmp release];
        testassert(!did_dealloc);
        
        did_dealloc = 0;
    } POP_POOL;
    testassert(did_dealloc);

    
    succeed(__FILE__);
    
    return 0;
}


#endif
