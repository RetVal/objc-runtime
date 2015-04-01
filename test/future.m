/*
TEST_BUILD
    $C{COMPILE} $DIR/future0.m -o future0.dylib -dynamiclib
    $C{COMPILE} $DIR/future2.m -x none future0.dylib -o future2.dylib -dynamiclib
    $C{COMPILE} $DIR/future.m -x none future0.dylib -o future.out
END
*/

#include "test.h"

#if __has_feature(objc_arc)

int main()
{
    testwarn("rdar://10041403 future class API is not ARC-compatible");
    succeed(__FILE__);
}


#else

#include <objc/runtime.h>
#include <malloc/malloc.h>
#include <string.h>
#include <dlfcn.h>
#include "future.h"

@implementation Sub2 
+(int)method { 
    return 2;
}
+(Class)classref {
    return [Sub2 class];
}
@end

@implementation SubSub2
+(int)method {
    return 1 + [super method];
}
@end

int main()
{
    Class oldTestRoot;
    Class oldSub1;
    Class newSub1;
#if !__OBJC2__
    Class oldSub2;
    Class newSub2;
    uintptr_t buf[20];
#endif

    // objc_getFutureClass with existing class
    oldTestRoot = objc_getFutureClass("TestRoot");
    testassert(oldTestRoot == [TestRoot class]);

    // objc_getFutureClass with missing class
    oldSub1 = objc_getFutureClass("Sub1");
    testassert(oldSub1);
    testassert(malloc_size(objc_unretainedPointer(oldSub1)) > 0);
    testassert(objc_getClass("Sub1") == Nil);

    // objc_getFutureClass a second time
    testassert(oldSub1 == objc_getFutureClass("Sub1"));

#if !__OBJC2__
    // objc_setFutureClass with existing class
    oldSub2 = objc_getClass("Sub2");
    testassert(oldSub2 == [Sub2 class]);
    testassert(oldSub2 == class_getSuperclass(objc_getClass("SubSub2")));
    objc_setFutureClass((Class)buf, "Sub2");
    testassert(0 == strcmp(class_getName((Class)buf), "Sub2"));
    newSub2 = objc_getClass("Sub2");
    testassert(newSub2 == (Class)buf);
    testassert(newSub2 != oldSub2);
    // check classrefs
    testassert(newSub2 == [Sub2 class]);
    testassert(newSub2 == [newSub2 class]);
    testassert(newSub2 == [newSub2 classref]);
    testassert(newSub2 != [oldSub2 class]);
    // check superclass chains
    testassert(newSub2 == class_getSuperclass(objc_getClass("SubSub2")));
#else
    // 64-bit ABI ignores objc_setFutureClass.
#endif

    // Load class Sub1
    dlopen("future2.dylib", 0);

    // Verify use of future class
    newSub1 = objc_getClass("Sub1");
    testassert(oldSub1 == newSub1);
    testassert(newSub1 == [newSub1 classref]);
    testassert(newSub1 == class_getSuperclass(objc_getClass("SubSub1")));

    testassert(1 == [oldSub1 method]);
    testassert(1 == [newSub1 method]);
#if !__OBJC2__
    testassert(2 == [newSub2 method]);
    testassert(2 == [oldSub2 method]);
    testassert(3 == [SubSub2 method]);
#endif

    succeed(__FILE__);
}

#endif
