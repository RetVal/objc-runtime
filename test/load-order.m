/*
TEST_BUILD
    $C{COMPILE} $DIR/load-order3.m -install_name $T{DYLIBDIR}/load-order3.dylib -o load-order3.dylib -dynamiclib
    $C{COMPILE} $DIR/load-order2.m -install_name $T{DYLIBDIR}/load-order2.dylib -o load-order2.dylib -x none load-order3.dylib -dynamiclib
    $C{COMPILE} $DIR/load-order1.m -install_name $T{DYLIBDIR}/load-order1.dylib -o load-order1.dylib -x none load-order3.dylib load-order2.dylib -dynamiclib
    $C{COMPILE} $DIR/load-order.m  -o load-order.exe -x none load-order3.dylib load-order2.dylib load-order1.dylib 
END
*/

#include "test.h"

extern int state1, state2, state3;

int main()
{
    testassert(state1 == 1  &&  state2 == 2  &&  state3 == 3);
    succeed(__FILE__);
}
