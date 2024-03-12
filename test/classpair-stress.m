// TEST_CONFIG

#include "test.h"
#include <objc/NSObject.h>
#include <objc/runtime.h>

int main()
{
    // Allocate a large number of classes and make sure their instances work.
    // This is mostly to ensure that the indexed class system on 32-bit works
    // correctly for the full range of values, and when we run off the end.

    // The indexed class array is currently 32,768 entries. Each iteration will
    // use two (class and metaclass).
    int count = 20000;
    for (int i = 0; i < count; i++) {
        testprintf("Testing iteration %d\n", i);

        char *name;
        asprintf(&name, "TestClass-%d", i);

        Class c = objc_allocateClassPair([NSObject class], name, 0);
        objc_registerClassPair(c);

        testprintf("%s is at %p\n", name, c);

        free(name);

        RELEASE_VALUE([[c alloc] init]);
    }

    succeed(__FILE__);
}
