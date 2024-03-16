#include "test.h"
#include "class-structures.h"

struct ObjCClass_ro FooMetaclass_ro = {
    .flags = 1,
    .instanceStart = 40,
    .instanceSize = 40,
    .name = "Foo",
};

struct ObjCClass FooMetaclass = {
    .isa = &OBJC_METACLASS_$_NSObject,
    .superclass = &OBJC_METACLASS_$_NSObject,
    .cachePtr = &_objc_empty_cache,
    .data = &FooMetaclass_ro,
};


int ranMyMethod1;
extern "C" void myMethod1(id self __unused, SEL _cmd) {
    testprintf("myMethod1\n");
    testassert(_cmd == @selector(myMethod1));
    ranMyMethod1 = 1;
}

int ranMyMethod2;
extern "C" void myMethod2(id self __unused, SEL _cmd) {
    testprintf("myMethod2\n");
    testassert(_cmd == @selector(myMethod2));
    ranMyMethod2 = 1;
}

int ranMyMethod3;
extern "C" void myMethod3(id self __unused, SEL _cmd) {
    testprintf("myMethod3\n");
    testassert(_cmd == @selector(myMethod3));
    ranMyMethod3 = 1;
}

int ranMyReplacedMethod1;
extern "C" void myReplacedMethod1(id self __unused, SEL _cmd) {
    testprintf("myReplacedMethod1\n");
    testassert(_cmd == @selector(myMethod1));
    ranMyReplacedMethod1 = 1;
}

int ranMyReplacedMethod2;
extern "C" void myReplacedMethod2(id self __unused, SEL _cmd) {
    testprintf("myReplacedMethod2\n");
    testassert(_cmd == @selector(myMethod2));
    ranMyReplacedMethod2 = 1;
}

struct BigStruct {
  uintptr_t a, b, c, d, e, f, g;
};

int ranMyMethodStret;
extern "C" BigStruct myMethodStret(id self __unused, SEL _cmd) {
    testprintf("myMethodStret\n");
    testassert(_cmd == @selector(myMethodStret));
    ranMyMethodStret = 1;
    BigStruct ret = {};
    return ret;
}

int ranMyReplacedMethodStret;
extern "C" BigStruct myReplacedMethodStret(id self __unused, SEL _cmd) {
    testprintf("myReplacedMethodStret\n");
    testassert(_cmd == @selector(myMethodStret));
    ranMyReplacedMethodStret = 1;
    BigStruct ret = {};
    return ret;
}

extern struct ObjCMethodList Foo_methodlistSmall;

asm("\
.section __TEXT,__cstring\n\
_MyMethod1Name:\n\
    .asciz \"myMethod1\"\n\
_MyMethod2Name:\n\
    .asciz \"myMethod2\"\n\
_MyMethod3Name:\n\
    .asciz \"myMethod3\"\n\
_BoringMethodType:\n\
    .asciz \"v16@0:8\"\n\
_MyMethodStretName:\n\
    .asciz \"myMethodStret\"\n\
_MyMethodNullTypesName:\n\
    .asciz \"myMethodNullTypes\"\n\
_StretType:\n\
    .asciz \"{BigStruct=QQQQQQQ}16@0:8\"\n\
");

#if __LP64__
asm("\
.section __DATA,__objc_selrefs,literal_pointers,no_dead_strip\n\
_MyMethod1NameRef:\n\
    .quad _MyMethod1Name\n\
_MyMethod2NameRef:\n\
    .quad _MyMethod2Name\n\
_MyMethod3NameRef:\n\
    .quad _MyMethod3Name\n\
_MyMethodStretNameRef:\n\
    .quad _MyMethodStretName\n\
_MyMethodNullTypesNameRef:\n\
    .quad _MyMethodNullTypesName\n\
");
#else
asm("\
.section __DATA,__objc_selrefs,literal_pointers,no_dead_strip\n\
_MyMethod1NameRef:\n\
    .long _MyMethod1Name\n\
_MyMethod2NameRef:\n\
    .long _MyMethod2Name\n\
_MyMethod3NameRef:\n\
    .long _MyMethod3Name\n\
_MyMethodStretNameRef:\n\
    .long _MyMethodStretName\n\
_MyMethodNullTypesNameRef:\n\
    .long _MyMethodNullTypesName\n\
");
#endif

#if MUTABLE_METHOD_LIST
asm(".section __DATA,__objc_methlist\n");
#else
asm(".section __TEXT,__objc_methlist\n");
#endif

asm("\
    .p2align 2\n\
_Foo_methodlistSmall:\n\
    .long 12 | 0x80000000\n\
    .long 5\n\
    \n\
    .long _MyMethod1NameRef - .\n\
    .long _BoringMethodType - .\n\
    .long _myMethod1 - .\n\
    \n\
    .long _MyMethod2NameRef - .\n\
    .long _BoringMethodType - .\n\
    .long _myMethod2 - .\n\
    \n\
    .long _MyMethod3NameRef - .\n\
    .long _BoringMethodType - .\n\
    .long _myMethod3 - .\n\
    \n\
    .long _MyMethodStretNameRef - .\n\
    .long _StretType - .\n\
    .long _myMethodStret - .\n\
\n\
    .long _MyMethodNullTypesNameRef - .\n\
    .long 0\n\
    .long _myMethod1 - .\n\
");

struct ObjCClass_ro Foo_ro = {
    .instanceStart = 8,
    .instanceSize = 8,
    .name = "Foo",
    .baseMethodList = &Foo_methodlistSmall,
};

struct ObjCClass FooClass = {
    .isa = &FooMetaclass,
    .superclass = &OBJC_CLASS_$_NSObject,
    .cachePtr = &_objc_empty_cache,
    .data = &Foo_ro,
};


@interface Foo: NSObject

- (void)myMethod1;
- (void)myMethod2;
- (void)myMethod3;
- (BigStruct)myMethodStret;

@end
