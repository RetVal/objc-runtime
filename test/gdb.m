// TEST_CFLAGS -Wno-deprecated-declarations

#include "test.h"
#include "testroot.i"
#include <objc/objc-gdb.h>
#include <objc/runtime.h>

int main()
{
    // Class hashes
    Class result;

    // Class should not be realized yet
    // fixme not true during class hash rearrangement
    // result = NXMapGet(gdb_objc_realized_classes, "TestRoot");
    // testassert(!result);

    [TestRoot class];
    // Now class should be realized

    result = (__bridge Class)(NXMapGet(gdb_objc_realized_classes, "TestRoot"));
    testassert(result);
    testassert(result == [TestRoot class]);

    result = (__bridge Class)(NXMapGet(gdb_objc_realized_classes, "DoesNotExist"));
    testassert(!result);

    // Class structure decoding
    
    uintptr_t *maskp = (uintptr_t *)dlsym(RTLD_DEFAULT, "objc_debug_class_rw_data_mask");
    testassert(maskp);

    succeed(__FILE__);
}
