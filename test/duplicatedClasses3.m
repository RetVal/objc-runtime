/*
TEST_BUILD
    $C{COMPILE} $DIR/duplicatedClasses0.m -fvisibility=hidden -DTestRoot=TestRoot2 -install_name $T{DYLIBDIR}/duplicatedClasses0.dylib -o duplicatedClasses0.dylib -dynamiclib
    $C{COMPILE} $DIR/duplicatedClasses3.m -x none duplicatedClasses0.dylib -o duplicatedClasses3.exe
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
    fail("should have crashed already");
}
