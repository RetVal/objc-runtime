// TEST_CONFIG MEM=mrc,gc

#include "test.h"

#import <Foundation/NSObject.h>

@interface Sub : NSObject { } @end
@implementation Sub 
+(id)allocWithZone:(NSZone *)zone { 
    testprintf("in +[Sub alloc]\n");
    return [super allocWithZone:zone];
    }
-(void)dealloc { 
    testprintf("in -[Sub dealloc]\n");
    [super dealloc];
}
@end

int main()
{
    PUSH_POOL {
        [[Sub new] autorelease];
    } POP_POOL;

    succeed(__FILE__);
}
