/*
Make sure we detect classes with the RW_REALIZED bit set in the binary. rdar://problem/67692760

(Note that on arm64e, this problem will cause a pointer auth failure.)

TEST_CONFIG OS=macosx ARCH=!arm64e
TEST_CRASHES
TEST_RUN_OUTPUT
objc\[\d+\]: realized class 0x[0-9a-fA-F]+ has corrupt data pointer: malloc_size\(0x[0-9a-fA-F]+\) = 0
objc\[\d+\]: HALTED
END
*/

#include "test.h"
#include "class-structures.h"

#include <objc/NSObject.h>

#define RW_REALIZED (1U<<31)

struct ObjCClass_ro FakeSuperclassRO = {
    .flags = RW_REALIZED
};

struct ObjCClass FakeSuperclass = {
    &OBJC_METACLASS_$_NSObject,
    &OBJC_METACLASS_$_NSObject,
    NULL,
    0,
    &FakeSuperclassRO
};

struct ObjCClass_ro FakeSubclassRO;

struct ObjCClass FakeSubclass = {
  &FakeSuperclass,
  &FakeSuperclass,
  NULL,
  0,
  &FakeSubclassRO
};

static struct ObjCClass *class_ptr __attribute__((used)) __attribute((section("__DATA,__objc_nlclslist"))) = &FakeSubclass;

int main() {}
