// TEST_CFLAGS -framework Foundation

#include "test.h"
#include <objc/runtime.h>

int CalledHackClass = 0;

id HackClass(id self, SEL _cmd __unused)
{
    CalledHackClass++;
    return self;
}

int main(int argc __unused, char **argv __unused)
{
    // Since Foundation now includes the Swift overlay, we can count on
    // SwiftObject being loaded when Foundation is loaded.
    Class SwiftObject = objc_getClass("_TtCs12_SwiftObject");
    testassert(SwiftObject);

    // Replace +class using the RawUnsafe call so we don't look like an
    // override.
    Method m = class_getClassMethod(SwiftObject, @selector(class));
    _method_setImplementationRawUnsafe(m, (IMP)HackClass);

    _objc_flush_caches(SwiftObject);

    // Verify the hack worked.
    IMP imp = class_getMethodImplementation(object_getClass(SwiftObject), @selector(class));
    testassertequal(imp, (IMP)HackClass);

    // Call +class using the optimized entrypoint. This should not call our
    // override.
    Class result = objc_opt_class(SwiftObject);
    testassert(result == SwiftObject);
    testassertequal(CalledHackClass, 0);

    succeed(__FILE__);
}