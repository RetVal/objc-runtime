/*
TEST_BUILD
    $C{COMPILE} $DIR/weak2.m -UWEAK_FRAMEWORK -DWEAK_IMPORT=__attribute__\\(\\(weak_import\\)\\) -UEMPTY  -dynamiclib -install_name $T{DYLIBDIR}/libweakimport.dylib -o libweakimport.dylib

    $C{COMPILE} $DIR/weakimport-missing.m -L. -weak-lweakimport -o weakimport-missing.exe

    $C{COMPILE} $DIR/weak2.m -UWEAK_FRAMEWORK -DWEAK_IMPORT=__attribute__\\(\\(weak_import\\)\\)  -DEMPTY= -dynamiclib -install_name $T{DYLIBDIR}/libweakimport.dylib -o libweakimport.dylib
END
*/

// #define WEAK_FRAMEWORK
#define WEAK_IMPORT __attribute__((weak_import))
#include "weak.m"
