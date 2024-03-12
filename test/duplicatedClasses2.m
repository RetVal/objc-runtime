/*
TEST_CONFIG OS=!exclavekit
TEST_BUILD
    $C{COMPILE} $DIR/duplicatedClasses0.m -fvisibility=hidden -DTestRoot=TestRoot2 -install_name $T{DYLIBDIR}/duplicatedClasses0.dylib -o duplicatedClasses0.dylib -dynamiclib
    $C{COMPILE} $DIR/duplicatedClasses2.m -o duplicatedClasses2.exe
END
*/

// TEST_ENV OBJC_DEBUG_DUPLICATE_CLASSES=FATAL
// TEST_CRASHES
/*
TEST_RUN_OUTPUT
objc\[\d+\]: Class DuplicatedClass is implemented in both .+ \(0x[0-9a-f]+\) and .+ \(0x[0-9a-f]+\)\. One of the two will be used\. Which one is undefined\.
objc\[\d+\]: HALTED
END
 */

#include "duplicatedClasses0.m"

int main()
{
    void *dl = dlopen("duplicatedClasses0.dylib", RTLD_LAZY);
    if (!dl) fail("couldn't open dylib");
    fail("should have crashed already");
}
