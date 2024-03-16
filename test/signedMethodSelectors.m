// TEST_CRASHES

/*
TEST_RUN_OUTPUT
Calling smashed method.
CRASHED: .*
OR
Calling smashed method.
OK: signedMethodSelectors.m
END
*/

#include "test.h"
#include "testroot.i"

#include <objc/runtime.h>
#include <ptrauth.h>
#include <stdio.h>

@interface TargetClass: TestRoot @end
@implementation TargetClass @end

void testIMP(id self __unused, SEL _cmd __unused)
{
    // This usually should not be called, but it can be if we get unlucky.
}

int main()
{
    TargetClass *obj = [TargetClass new];

    // We'll usually crash after one attempt, but we could get supremely unlucky
    // and have a valid signature that's all zeroes, so try a bunch before we
    // declare failure.
    for(int i = 0; i < 64; i++) {
        char *origSelStr;
        asprintf(&origSelStr, "originalSelector%d", i);
        SEL origSel = sel_getUid(origSelStr);
        free(origSelStr);

        char *replacementSelStr;
        asprintf(&replacementSelStr, "replacementSelector%d", i);
        SEL replacementSel = sel_getUid(replacementSelStr);
        free(replacementSelStr);

        class_addMethod([TargetClass class], origSel, (IMP)testIMP, "");
        Method method = class_getInstanceMethod([TargetClass class], origSel);

        // Overwrite the selector in the newly added method. Mask off the low
        // two bits to get the actual method_t*. `SEL name` is the first field.
        SEL *namePtr = (SEL *)((uintptr_t)method & ~0x3);
        namePtr = ptrauth_strip(namePtr, ptrauth_key_process_dependent_data);
        *namePtr = replacementSel;

        // This print ensures that we crash at the expected point, and not in
        // the iffy pointer-abuse code above.
        if (i == 0)
            fprintf(stderr, "Calling smashed method.\n");

        // Try to send replacementSel. This should crash with a ptrauth failure.
        ((void (*)(id, SEL))objc_msgSend)(obj, replacementSel);
    }

    // This test is supposed to crash on ARM64e, and should succeed elsewhere.
    // (Success elsewhere validates that the ARM64e crash comes from ptrauthed
    // selectors in the method list and not, say, a busted test.
#if __has_feature(ptrauth_calls)
    fail("should have crashed already");
#else
    succeed(__FILE__);
#endif
}
