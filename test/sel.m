/*
TEST_BUILD_OUTPUT
.*sel.m:\d+:\d+: warning: null passed to a callee that requires a non-null argument \[-Wnonnull\](\n.* note: expanded from macro 'testassert')?
.*sel.m:\d+:\d+: warning: null passed to a callee that requires a non-null argument \[-Wnonnull\](\n.* note: expanded from macro 'testassert')?
END
*/

#include "test.h"
#include <string.h>
#include <objc/objc-runtime.h>
#include <objc/objc-auto.h>
#include <objc/objc-internal.h>

int main()
{
    // Make sure @selector values are correctly fixed up
    testassert(@selector(foo) == sel_registerName("foo"));

    // sel_getName recognizes the zero SEL
    testassert(0 == strcmp("<null selector>", sel_getName(0)));

    // sel_lookUpByName returns NULL for NULL string
    testassert(NULL == sel_lookUpByName(NULL));

    // sel_lookUpByName returns NULL for unregistered and matches later registered selector
    {
        SEL sel;
        testassert(NULL == sel_lookUpByName("__testSelectorLookUp:"));
        testassert(NULL != (sel = sel_registerName("__testSelectorLookUp:")));
        testassert(sel  == sel_lookUpByName("__testSelectorLookUp:"));
    }

    // sel_lookUpByName matches @selector value
    testassert(@selector(foo2) == sel_lookUpByName("foo2"));

    succeed(__FILE__);
}
