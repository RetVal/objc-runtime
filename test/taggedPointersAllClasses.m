// TEST_CONFIG

#include "test.h"
#include "testroot.i"
#include <objc/runtime.h>
#include <objc/objc-internal.h>

#if OBJC_HAVE_TAGGED_POINTERS

@interface TagSuperclass: TestRoot

- (void)test;

@end

@implementation TagSuperclass

- (void)test {}

@end

int expectedTag;
uintptr_t expectedPayload;
uintptr_t sawPayload;
int sawTag;

void impl(void *self, SEL cmd) {
    (void)cmd;
    testassert(expectedTag == _objc_getTaggedPointerTag(self));
    testassert(expectedPayload == _objc_getTaggedPointerValue(self));
    sawPayload = _objc_getTaggedPointerValue(self);
    sawTag = _objc_getTaggedPointerTag(self);
}

int main()
{
    Class classes[OBJC_TAG_Last52BitPayload + 1] = {};
    
    for (int i = 0; i <= OBJC_TAG_Last52BitPayload; i++) {
        objc_tag_index_t tag = (objc_tag_index_t)i;
        if (i > OBJC_TAG_Last60BitPayload && i < OBJC_TAG_First52BitPayload)
            continue;
        if (_objc_getClassForTag(tag) != nil)
            continue;
        
        char *name;
        asprintf(&name, "Tag%d", i);
        classes[i] = objc_allocateClassPair([TagSuperclass class], name, 0);
        free(name);
        
        class_addMethod(classes[i], @selector(test), (IMP)impl, "v@@");
        
        objc_registerClassPair(classes[i]);
        _objc_registerTaggedPointerClass(tag, classes[i]);
    }
    
    for (int i = 0; i <= OBJC_TAG_Last52BitPayload; i++) {
        objc_tag_index_t tag = (objc_tag_index_t)i;
        if (classes[i] == nil)
            continue;
        
        for (int byte = 0; byte <= 0xff; byte++) {
            uintptr_t payload;
            memset(&payload, byte, sizeof(payload));
            
            if (i <= OBJC_TAG_Last60BitPayload)
                payload >>= _OBJC_TAG_PAYLOAD_RSHIFT;
            else
                payload >>= _OBJC_TAG_EXT_PAYLOAD_RSHIFT;

            expectedTag = i;
            expectedPayload = payload;
            id obj = (__bridge id)_objc_makeTaggedPointer(tag, payload);
            [obj test];
            testassert(sawPayload == payload);
            testassert(sawTag == i);
        }
    }
    
    succeed(__FILE__);
}

#else

int main()
{
    succeed(__FILE__);
}

#endif
