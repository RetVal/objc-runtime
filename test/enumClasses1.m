#include "enumClasses.h"

// Cats have retractable claws (using a category)
@interface Cat (Category) <Claws>

- (void)retract;
- (void)extend;

@end

@implementation Cat (Category)

- (void)retract {
}
- (void)extend {
}

@end
