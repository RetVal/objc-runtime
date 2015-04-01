#include "unload.h"
#include "testroot.i"


@implementation SmallClass : TestRoot
-(void)unload2_instance_method { }
@end


@implementation BigClass : TestRoot
+(void) forward:(void *) __unused sel :(void*) __unused args { }
-(void) forward:(void *) __unused sel :(void*) __unused args { }
@end


@interface UnusedClass { id isa; } @end
@implementation UnusedClass @end


@implementation SmallClass (Category) 
-(void)unload2_category_method { }
@end
