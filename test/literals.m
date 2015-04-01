// TEST_CONFIG MEM=arc,mrc CC=clang LANGUAGE=objc,objc++
// TEST_CFLAGS -framework Foundation

#import <Foundation/Foundation.h>
#import <Foundation/NSDictionary.h>
#import <objc/runtime.h>
#import <objc/objc-abi.h>
#import <math.h>
#include "test.h"

int main() {
    PUSH_POOL {

#if __has_feature(objc_bool)    // placeholder until we get a more precise macro.
        NSArray *array = @[ @1, @2, @YES, @NO, @"Hello", @"World" ];
        testassert([array count] == 6);
        NSDictionary *dict = @{ @"Name" : @"John Q. Public", @"Age" : @42 };
        testassert([dict count] == 2);
        NSDictionary *numbers = @{ @"π" : @M_PI, @"e" : @M_E };
        testassert([[numbers objectForKey:@"π"] doubleValue] == M_PI);
        testassert([[numbers objectForKey:@"e"] doubleValue] == M_E);
#endif
        
    } POP_POOL;

    succeed(__FILE__);

    return 0;
}
