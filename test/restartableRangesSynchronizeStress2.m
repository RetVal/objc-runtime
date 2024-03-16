// TEST_CONFIG MEM=arc LANGUAGE=objective-c OS=!exclavekit
// TEST_ENV OBJC_DEBUG_SCRIBBLE_CACHES=YES
// TEST_NO_MALLOC_SCRIBBLE

// Stress test thread-safe cache deallocation and reallocation.

#include "test.h"
#include "testroot.i"
#include <dispatch/dispatch.h>

@interface MyClass1 : TestRoot
@end
@implementation MyClass1
@end

@interface MyClass2 : TestRoot
@end
@implementation MyClass2
@end

@interface MyClass3 : TestRoot
@end
@implementation MyClass3
@end

@interface MyClass4 : TestRoot
@end
@implementation MyClass4
@end

int main() {
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        usleep(200000);
        while (1) {
            usleep(1000);
            _objc_flush_caches(MyClass1.class);
            _objc_flush_caches(MyClass2.class);
            _objc_flush_caches(MyClass3.class);
            _objc_flush_caches(MyClass4.class);
        }
    });
    
    for (int i = 0; i < 6; i++) {
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            long j = 0;
            while (1) {
                j++;
                (void)[[MyClass1 alloc] init];
                (void)[[MyClass2 alloc] init];
                (void)[[MyClass3 alloc] init];
                (void)[[MyClass4 alloc] init];
            }
        });
    }
    
    sleep(5);
    
    succeed(__FILE__);
    
    return 0;
}
