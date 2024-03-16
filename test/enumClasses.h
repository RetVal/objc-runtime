/* Emacs, this is -*-objc-*- */

#ifndef ENUMCLASSES_H_
#define ENUMCLASSES_H_

#include "test.h"

typedef enum {
    UnknownSize = -1,
    MinasculeSize,
    SmallSize,
    MediumSize,
    BigSize,
    HugeSize,
} creature_size_t;

typedef enum {
    BlackAndOrange,
    GrayAndBlack,
    Plaid,
} stripe_color_t;

@protocol Creature
- (const char *)name;
- (creature_size_t)size;
@end

@protocol Claws
- (void)retract;
- (void)extend;
@end

@protocol Stripes
- (stripe_color_t)stripeColor;
@end

// Animal
@interface Animal : TestRoot <Creature>

- (const char *)name;
- (creature_size_t)size;

@end

@interface Dog : Animal

- (const char *)name;

@end

@interface Cat : Animal

- (const char *)name;

@end

@interface Elephant : Animal

- (const char *)name;
- (creature_size_t)size;

@end

#endif /* ENUMCLASSES_H_ */
