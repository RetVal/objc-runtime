/*
TEST_BUILD
    $C{COMPILE} $DIR/weak2.m -DWEAK_FRAMEWORK=1 -DWEAK_IMPORT= -UEMPTY  -dynamiclib -install_name $T{DYLIBDIR}/libweakframework.dylib -o libweakframework.dylib

    $C{COMPILE} $DIR/weakframework-missing.m -L. -weak-lweakframework -o weakframework-missing.exe

    $C{COMPILE} $DIR/weak2.m -DWEAK_FRAMEWORK=1 -DWEAK_IMPORT= -DEMPTY= -dynamiclib -install_name $T{DYLIBDIR}/libweakframework.dylib -o libweakframework.dylib

END
*/

#define WEAK_FRAMEWORK 1
#define WEAK_IMPORT
#include "weak.m"
