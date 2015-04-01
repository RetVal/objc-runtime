#include "test.h"

int state3 = 0;

@interface Three @end
@implementation Three
+(void)load 
{ 
    state3 = 3;
}
@end
