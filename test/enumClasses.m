/*
TEST_BUILD
  $C{COMPILE} $DIR/enumClasses0.m -install_name $T{DYLIBDIR}/enumClasses0.dylib -o enumClasses0.dylib -dynamiclib
  $C{COMPILE} $DIR/enumClasses1.m -x none enumClasses0.dylib -install_name $T{DYLIBDIR}/enumClasses1.dylib -o enumClasses1.dylib -dynamiclib
  $C{COMPILE} $DIR/enumClasses.m -x none enumClasses0.dylib enumClasses1.dylib -o enumClasses.exe
END

TEST_RUN_OUTPUT
Starting with E:
  Elephant
Dogs beginning with L:
  Labrador
Has claws:
  Tabby
  Lion
  Tiger
Things that are stripey:
  Tabby
  Tiger
  Woozle
Animals:
  Dog
  Datschund
  Terrier
  Labrador
  Mastiff
  Tabby
  Lion
  Tiger
  Elephant
  Woozle
First four:
  Dog
  Datschund
  Terrier
  Labrador
(Not looking in dylib \(no dlopen\)|In dylib:
  TestRoot
  Animal
  Cat)
Found a Heffalump
OK: enumClasses.m
END
 */

#include "test.h"
#include <objc/objc-runtime.h>
#include "enumClasses.h"

// Dogs
@implementation Dog

- (const char *)name { return "dog"; }

@end

@interface Datschund : Dog

- (const char *)name;
- (creature_size_t)size;

@end

@implementation Datschund

- (const char *)name { return "datschund"; }
- (creature_size_t)size { return MediumSize; }

@end

@interface Terrier : Dog

- (const char *)name;
- (creature_size_t)size;

@end

@implementation Terrier

- (const char *)name { return "terrier"; }
- (creature_size_t)size { return SmallSize; }

@end

@interface Labrador : Dog

- (const char *)name;
- (creature_size_t)size;

@end

@implementation Labrador

- (const char *)name { return "labrador"; }
- (creature_size_t)size { return MediumSize; }

@end

@interface Mastiff : Dog

- (const char *)name;
- (creature_size_t)size;

@end

@implementation Mastiff

- (const char *)name { return "mastiff"; }
- (creature_size_t)size { return BigSize; }

@end

// Cats
@interface Tabby : Cat <Stripes>

- (const char *)name;
- (creature_size_t)size;
- (stripe_color_t)stripeColor;

@end

@implementation Tabby

- (const char *)name { return "tabby"; }
- (creature_size_t)size { return SmallSize; }
- (stripe_color_t)stripeColor { return GrayAndBlack; }

@end

@interface Lion : Cat

- (const char *)name;
- (creature_size_t)size;

@end

@implementation Lion

- (const char *)name { return "lion"; }
- (creature_size_t)size { return BigSize; }

@end

@interface Tiger : Cat <Stripes>

- (const char *)name;
- (creature_size_t)size;
- (stripe_color_t)stripeColor;

@end

@implementation Tiger

- (const char *)name { return "tiger"; }
- (creature_size_t)size { return BigSize; }
- (stripe_color_t)stripeColor { return BlackAndOrange; }

@end

// Elephants
@implementation Elephant

- (const char *)name { return "elephant"; }
- (creature_size_t)size { return HugeSize; }

@end

@interface Woozle : Elephant <Stripes>

- (const char *)name;
- (stripe_color_t)stripeColor;

@end

@implementation Woozle

- (const char *)name { return "woozle"; }
- (stripe_color_t)stripeColor { return Plaid; }

@end

static const char *heffalump_name() {
    return "heffalump";
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
int main() {
    // Enumerate just classes whose names start with an "E"
    __block unsigned eCount = 0;
    fprintf(stderr, "Starting with E:\n");
    objc_enumerateClasses(NULL, "E", NULL, NULL,
                          ^void(Class cls, BOOL *stop) {
                              (void)stop;
                              fprintf(stderr, "  %s\n", class_getName(cls));
                              ++eCount;
                          });
    testassertequal(eCount, 1);

    // Enumerate dogs whose names start with "L"
    // (mustn't get Lion)
    __block unsigned dogCount = 0;
    fprintf(stderr, "Dogs beginning with L:\n");
    objc_enumerateClasses(NULL, "L", NULL, [Dog class],
                          ^void(Class cls, BOOL *stop) {
                              (void)stop;
                              fprintf(stderr, "  %s\n", class_getName(cls));
                               ++dogCount;
                          });

    // Enumerate classes that support the "Claws" protocol; note that "Cat"
    // won't be included because it's in a separate dylib (i.e. not this image)
    // (tests category conformance)
    __block unsigned hasClaws = 0;
    fprintf(stderr, "Has claws:\n");
    objc_enumerateClasses(NULL, NULL, @protocol(Claws), NULL,
                          ^void(Class cls, BOOL *stop) {
                              (void)stop;
                              fprintf(stderr, "  %s\n", class_getName(cls));
                              ++hasClaws;
                          });
    testassertequal(hasClaws, 3);

    // Enumerate stripy things
    // (tests direct conformance)
    __block unsigned stripeCount = 0;
    fprintf(stderr, "Things that are stripey:\n");
    objc_enumerateClasses(NULL, NULL, @protocol(Stripes), NULL,
                          ^void(Class cls, BOOL *stop) {
                              (void)stop;
                              fprintf(stderr, "  %s\n", class_getName(cls));
                              ++stripeCount;
                          });
    testassertequal(stripeCount, 3);

    // Enumerate *all* of the animals (this will realize all the classes)
    __block unsigned animalCount = 0;
    fprintf(stderr, "Animals:\n");
    objc_enumerateClasses(NULL, NULL, NULL, [Animal class],
                          ^void(Class cls, BOOL *stop) {
                              (void)stop;
                              fprintf(stderr, "  %s\n", class_getName(cls));
                              ++animalCount;
                          });
    testassertequal(animalCount, 10);

    // Enumerate the first four animals
    __block unsigned stopCount = 0;
    fprintf(stderr, "First four:\n");
    objc_enumerateClasses(NULL, NULL, NULL, [Animal class],
                          ^void(Class cls, BOOL *stop) {
                              fprintf(stderr, "  %s\n", class_getName(cls));
                              if (++stopCount == 4)
                                  *stop = YES;
                          });
    testassertequal(stopCount, 4);

#if TARGET_OS_EXCLAVEKIT
    fprintf(stderr, "Not looking in dylib (no dlopen)\n");
#else
    // Enumerate the classes in the dylib
    void *dylib = dlopen("enumClasses0.dylib", RTLD_NOLOAD);
    __block unsigned dylibCount = 0;
    fprintf(stderr, "In dylib:\n");
    objc_enumerateClasses(dylib, NULL, NULL, NULL,
                          ^void(Class cls, BOOL *stop) {
                              (void)stop;
                              fprintf(stderr, "  %s\n", class_getName(cls));
                              ++dylibCount;
                          });
    testassertequal(dylibCount, 3);
    dlclose(dylib);
#endif // TARGET_OS_EXCLAVEKIT

    // Create a dynamic class
    Class heffalump = objc_allocateClassPair([Elephant class], "Heffalump", 0);

    // We mustn't see it before objc_registerClassPair is called
    __block BOOL foundHeffalump = NO;
    objc_enumerateClasses(OBJC_DYNAMIC_CLASSES, NULL, NULL, NULL,
                          ^void(Class cls, BOOL *stop) {
                              if (cls == heffalump) {
                                  fprintf(stderr, "Found an unexpected Heffalump\n");
                                  foundHeffalump = YES;
                                  *stop = YES;
                              }
                          });
    testassert(!foundHeffalump);

    // Add the -name method
    Method name = class_getInstanceMethod([Elephant class], @selector(name));
    class_addMethod(heffalump, @selector(name), (IMP)heffalump_name,
                    method_getTypeEncoding(name));

    // Register it
    objc_registerClassPair(heffalump);

    // We should now see Heffalump
    objc_enumerateClasses(OBJC_DYNAMIC_CLASSES, NULL, NULL, NULL,
                          ^void(Class cls, BOOL *stop) {
                              if (cls == heffalump) {
                                  fprintf(stderr, "Found a Heffalump\n");
                                  foundHeffalump = YES;
                                  *stop = YES;
                              }
                          });
    testassert(foundHeffalump);

    succeed(__FILE__);
}
#pragma clang diagnostic pop
