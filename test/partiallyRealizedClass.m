// TEST_CONFIG
#include <objc/NSObject.h>
#include "test.h"

@interface AccessStatic: NSObject @end
@implementation AccessStatic @end

// EXTERN_C id objc_retainAutoreleaseReturnValue(id);
// EXTERN_C id objc_alloc(id);

// Verify that objc_retainAutoreleaseReturnValue on an unrealized class doesn't
// put the class into a half-baked state where the metaclass is realized but the
// class is not. rdar://101151980
int main() {
    extern char OBJC_CLASS_$_AccessStatic;
    id st = (__bridge id)(void *)&OBJC_CLASS_$_AccessStatic;

    objc_retainAutoreleaseReturnValue(st);
    objc_alloc(st);

    succeed(__FILE__);
}
