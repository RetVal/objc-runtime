// TEST_CONFIG MEM=mrc,gc
// TEST_CFLAGS -Wno-deprecated-declarations

#include "test.h"

#if __cplusplus  &&  !__clang__

int main()
{
    // llvm-g++ is confused by @selector(foo::) and will never be fixed
    succeed(__FILE__);
}

#else

#include <objc/runtime.h>
#include <objc/message.h>

id ID_RESULT = (id)0x12345678;
long long LL_RESULT = __LONG_LONG_MAX__ - 2LL*__INT_MAX__;
double FP_RESULT = __DBL_MIN__ + __DBL_EPSILON__;
long double LFP_RESULT = __LDBL_MIN__ + __LDBL_EPSILON__;
// STRET_RESULT in test.h


static int state = 0;
static id receiver;

@interface Super { id isa; } @end

@interface Super (Forwarded) 
+(id)idret: 
   (long)i1:(long)i2:(long)i3:(long)i4:(long)i5:(long)i6:(long)i7:(long)i8:(long)i9:(long)i10:(long)i11:(long)i12:(long)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15;

+(id)idre2: 
   (long)i1:(long)i2:(long)i3:(long)i4:(long)i5:(long)i6:(long)i7:(long)i8:(long)i9:(long)i10:(long)i11:(long)i12:(long)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15;

+(id)idre3: 
   (long)i1:(long)i2:(long)i3:(long)i4:(long)i5:(long)i6:(long)i7:(long)i8:(long)i9:(long)i10:(long)i11:(long)i12:(long)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15;

+(long long)llret: 
   (long)i1:(long)i2:(long)i3:(long)i4:(long)i5:(long)i6:(long)i7:(long)i8:(long)i9:(long)i10:(long)i11:(long)i12:(long)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15;

+(long long)llre2: 
   (long)i1:(long)i2:(long)i3:(long)i4:(long)i5:(long)i6:(long)i7:(long)i8:(long)i9:(long)i10:(long)i11:(long)i12:(long)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15;

+(long long)llre3: 
   (long)i1:(long)i2:(long)i3:(long)i4:(long)i5:(long)i6:(long)i7:(long)i8:(long)i9:(long)i10:(long)i11:(long)i12:(long)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15;

+(struct stret)stret: 
   (long)i1:(long)i2:(long)i3:(long)i4:(long)i5:(long)i6:(long)i7:(long)i8:(long)i9:(long)i10:(long)i11:(long)i12:(long)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15;

+(struct stret)stre2: 
   (long)i1:(long)i2:(long)i3:(long)i4:(long)i5:(long)i6:(long)i7:(long)i8:(long)i9:(long)i10:(long)i11:(long)i12:(long)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15;

+(struct stret)stre3: 
   (long)i1:(long)i2:(long)i3:(long)i4:(long)i5:(long)i6:(long)i7:(long)i8:(long)i9:(long)i10:(long)i11:(long)i12:(long)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15;

+(double)fpret: 
   (long)i1:(long)i2:(long)i3:(long)i4:(long)i5:(long)i6:(long)i7:(long)i8:(long)i9:(long)i10:(long)i11:(long)i12:(long)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15;

+(double)fpre2: 
   (long)i1:(long)i2:(long)i3:(long)i4:(long)i5:(long)i6:(long)i7:(long)i8:(long)i9:(long)i10:(long)i11:(long)i12:(long)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15;

+(double)fpre3: 
   (long)i1:(long)i2:(long)i3:(long)i4:(long)i5:(long)i6:(long)i7:(long)i8:(long)i9:(long)i10:(long)i11:(long)i12:(long)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15;

@end


long long forward_handler(id self, SEL _cmd, long i1, long i2, long i3, long i4, long i5, long i6, long i7, long i8, long i9, long i10, long i11, long i12, long i13, double f1, double f2, double f3, double f4, double f5, double f6, double f7, double f8, double f9, double f10, double f11, double f12, double f13, double f14, double f15)
{
    testassert(self == receiver);

    testassert(i1 == 1);
    testassert(i2 == 2);
    testassert(i3 == 3);
    testassert(i4 == 4);
    testassert(i5 == 5);
    testassert(i6 == 6);
    testassert(i7 == 7);
    testassert(i8 == 8);
    testassert(i9 == 9);
    testassert(i10 == 10);
    testassert(i11 == 11);
    testassert(i12 == 12);
    testassert(i13 == 13);

    testassert(f1 == 1.0);
    testassert(f2 == 2.0);
    testassert(f3 == 3.0);
    testassert(f4 == 4.0);
    testassert(f5 == 5.0);
    testassert(f6 == 6.0);
    testassert(f7 == 7.0);
    testassert(f8 == 8.0);
    testassert(f9 == 9.0);
    testassert(f10 == 10.0);
    testassert(f11 == 11.0);
    testassert(f12 == 12.0);
    testassert(f13 == 13.0);
    testassert(f14 == 14.0);
    testassert(f15 == 15.0);

    if (_cmd == @selector(idret::::::::::::::::::::::::::::)  ||  
        _cmd == @selector(idre2::::::::::::::::::::::::::::)  ||  
        _cmd == @selector(idre3::::::::::::::::::::::::::::)) 
    {
        union {
            id idval;
            long long llval;
        } result;
        testassert(state == 11);
        state = 12;
        result.idval = ID_RESULT;
        return result.llval;
    } else if (_cmd == @selector(llret::::::::::::::::::::::::::::)  ||  
               _cmd == @selector(llre2::::::::::::::::::::::::::::)  ||  
               _cmd == @selector(llre3::::::::::::::::::::::::::::)) 
    {
        testassert(state == 13);
        state = 14;
        return LL_RESULT;
    } else if (_cmd == @selector(fpret::::::::::::::::::::::::::::)  ||  
               _cmd == @selector(fpre2::::::::::::::::::::::::::::)  ||  
               _cmd == @selector(fpre3::::::::::::::::::::::::::::)) 
    {
        testassert(state == 15);
        state = 16;
#if defined(__i386__)
        __asm__ volatile("fldl %0" : : "m" (FP_RESULT));
#elif defined(__x86_64__)
        __asm__ volatile("movsd %0, %%xmm0" : : "m" (FP_RESULT));
#elif defined(__arm__)
        union {
            double fpval;
            long long llval;
        } result;
        result.fpval = FP_RESULT;
        return result.llval;
#else
#       error unknown architecture
#endif
        return 0;
    } else if (_cmd == @selector(stret::::::::::::::::::::::::::::)  ||  
               _cmd == @selector(stre2::::::::::::::::::::::::::::)  ||  
               _cmd == @selector(stre3::::::::::::::::::::::::::::)) 
    {
        fail("stret message sent to non-stret forward_handler");
    } else {
        fail("unknown selector %s in forward_handler", sel_getName(_cmd));
    }
}


struct stret forward_stret_handler(id self, SEL _cmd, long i1, long i2, long i3, long i4, long i5, long i6, long i7, long i8, long i9, long i10, long i11, long i12, long i13, double f1, double f2, double f3, double f4, double f5, double f6, double f7, double f8, double f9, double f10, double f11, double f12, double f13, double f14, double f15)
{
    testassert(self == receiver);

    testassert(i1 == 1);
    testassert(i2 == 2);
    testassert(i3 == 3);
    testassert(i4 == 4);
    testassert(i5 == 5);
    testassert(i6 == 6);
    testassert(i7 == 7);
    testassert(i8 == 8);
    testassert(i9 == 9);
    testassert(i10 == 10);
    testassert(i11 == 11);
    testassert(i12 == 12);
    testassert(i13 == 13);

    testassert(f1 == 1.0);
    testassert(f2 == 2.0);
    testassert(f3 == 3.0);
    testassert(f4 == 4.0);
    testassert(f5 == 5.0);
    testassert(f6 == 6.0);
    testassert(f7 == 7.0);
    testassert(f8 == 8.0);
    testassert(f9 == 9.0);
    testassert(f10 == 10.0);
    testassert(f11 == 11.0);
    testassert(f12 == 12.0);
    testassert(f13 == 13.0);
    testassert(f14 == 14.0);
    testassert(f15 == 15.0);

    if (_cmd == @selector(idret::::::::::::::::::::::::::::)  ||
        _cmd == @selector(idre2::::::::::::::::::::::::::::)  ||
        _cmd == @selector(idre3::::::::::::::::::::::::::::)  ||
        _cmd == @selector(llret::::::::::::::::::::::::::::)  ||
        _cmd == @selector(llre2::::::::::::::::::::::::::::)  ||
        _cmd == @selector(llre3::::::::::::::::::::::::::::)  ||
        _cmd == @selector(fpret::::::::::::::::::::::::::::)  ||
        _cmd == @selector(fpre2::::::::::::::::::::::::::::)  ||
        _cmd == @selector(fpre3::::::::::::::::::::::::::::))
    {
        fail("non-stret selector %s sent to forward_stret_handler", sel_getName(_cmd));
    } else if (_cmd == @selector(stret::::::::::::::::::::::::::::)  ||  
               _cmd == @selector(stre2::::::::::::::::::::::::::::)  ||  
               _cmd == @selector(stre3::::::::::::::::::::::::::::)) 
    {
        testassert(state == 17);
        state = 18;
        return STRET_RESULT;
    } else {
        fail("unknown selector %s in forward::", sel_getName(_cmd));
    }

}

@implementation Super
+(void)initialize { }
+(id)class { return self; }

-(long long) forward:(SEL)sel :(marg_list)args
{
    char *p;
    uintptr_t *gp;
    double *fp;
    struct stret *struct_addr;
    
#if defined(__i386__)
    struct_addr = ((struct stret **)args)[-1];
#elif defined(__x86_64__)
    struct_addr = *(struct stret **)((char *)args + 8*16+4*8);
#elif defined(__arm__)
    struct_addr = *(struct stret **)((char *)args + 0);
#else
#   error unknown architecture
#endif

    testassert(self == receiver);
    testassert(_cmd == sel_registerName("forward::"));

    p = (char *)args;
#if defined(__x86_64__)
    p += 8*16 + 4*8;  // skip over xmm and linkage
    if (sel == @selector(stret::::::::::::::::::::::::::::)  ||  
        sel == @selector(stre2::::::::::::::::::::::::::::)  ||  
        sel == @selector(stre3::::::::::::::::::::::::::::)) 
    {
        p += sizeof(void *);  // struct return
    }
#elif defined(__i386__)
    // nothing to do
#elif defined(__arm__)
    if (sel == @selector(stret::::::::::::::::::::::::::::)  ||  
        sel == @selector(stre2::::::::::::::::::::::::::::)  ||  
        sel == @selector(stre3::::::::::::::::::::::::::::)) 
    {
        p += sizeof(void *);  // struct return;
    }
#else
#   error unknown architecture
#endif
    gp = (uintptr_t *)p;
    testassert(*gp++ == (uintptr_t)self);
    testassert(*gp++ == (uintptr_t)sel);
    testassert(*gp++ == 1);
    testassert(*gp++ == 2);
    testassert(*gp++ == 3);
    testassert(*gp++ == 4);
    testassert(*gp++ == 5);
    testassert(*gp++ == 6);
    testassert(*gp++ == 7);
    testassert(*gp++ == 8);
    testassert(*gp++ == 9);
    testassert(*gp++ == 10);
    testassert(*gp++ == 11);
    testassert(*gp++ == 12);
    testassert(*gp++ == 13);

#if defined(__i386__)  ||  defined(__arm__)

    fp = (double *)gp;
    testassert(*fp++ == 1.0);
    testassert(*fp++ == 2.0);
    testassert(*fp++ == 3.0);
    testassert(*fp++ == 4.0);
    testassert(*fp++ == 5.0);
    testassert(*fp++ == 6.0);
    testassert(*fp++ == 7.0);
    testassert(*fp++ == 8.0);
    testassert(*fp++ == 9.0);
    testassert(*fp++ == 10.0);
    testassert(*fp++ == 11.0);
    testassert(*fp++ == 12.0);
    testassert(*fp++ == 13.0);
    testassert(*fp++ == 14.0);
    testassert(*fp++ == 15.0);

#elif defined(__x86_64__)

    fp = (double *)args;  // xmm, double-wide
    testassert(*fp++ == 1.0); fp++;
    testassert(*fp++ == 2.0); fp++;
    testassert(*fp++ == 3.0); fp++;
    testassert(*fp++ == 4.0); fp++;
    testassert(*fp++ == 5.0); fp++;
    testassert(*fp++ == 6.0); fp++;
    testassert(*fp++ == 7.0); fp++;
    testassert(*fp++ == 8.0); fp++;
    fp = (double *)gp;
    testassert(*fp++ == 9.0);
    testassert(*fp++ == 10.0);
    testassert(*fp++ == 11.0);
    testassert(*fp++ == 12.0);
    testassert(*fp++ == 13.0);
    testassert(*fp++ == 14.0);
    testassert(*fp++ == 15.0);

#else
#   error unknown architecture
#endif

    if (sel == @selector(idret::::::::::::::::::::::::::::)  ||  
        sel == @selector(idre2::::::::::::::::::::::::::::)  ||  
        sel == @selector(idre3::::::::::::::::::::::::::::)) 
    {
        union {
            id idval;
            long long llval;
        } result;
        testassert(state == 1);
        state = 2;
        result.idval = ID_RESULT;
        return result.llval;
    } else if (sel == @selector(llret::::::::::::::::::::::::::::)  ||  
               sel == @selector(llre2::::::::::::::::::::::::::::)  ||  
               sel == @selector(llre3::::::::::::::::::::::::::::)) 
    {
        testassert(state == 3);
        state = 4;
        return LL_RESULT;
    } else if (sel == @selector(fpret::::::::::::::::::::::::::::)  ||  
               sel == @selector(fpre2::::::::::::::::::::::::::::)  ||  
               sel == @selector(fpre3::::::::::::::::::::::::::::)) 
    {
        testassert(state == 5);
        state = 6;
#if defined(__i386__)
        __asm__ volatile("fldl %0" : : "m" (FP_RESULT));
#elif defined(__x86_64__)
        __asm__ volatile("movsd %0, %%xmm0" : : "m" (FP_RESULT));
#elif defined(__arm__)
        union {
            double fpval;
            long long llval;
        } result;
        result.fpval = FP_RESULT;
        return result.llval;
#else
#       error unknown architecture
#endif
        return 0;
    } else if (sel == @selector(stret::::::::::::::::::::::::::::)  ||  
               sel == @selector(stre2::::::::::::::::::::::::::::)  ||  
               sel == @selector(stre3::::::::::::::::::::::::::::)) 
    {
        testassert(state == 7);
        state = 8;
        *struct_addr = STRET_RESULT;
        return 0;
    } else {
        fail("unknown selector %s in forward::", sel_getName(sel));
    }
    return 0;
}

@end

typedef id (*id_fn_t)(id self, SEL _cmd, long i1, long i2, long i3, long i4, long i5, long i6, long i7, long i8, long i9, long i10, long i11, long i12, long i13, double f1, double f2, double f3, double f4, double f5, double f6, double f7, double f8, double f9, double f10, double f11, double f12, double f13, double f14, double f15);

typedef long long (*ll_fn_t)(id self, SEL _cmd, long i1, long i2, long i3, long i4, long i5, long i6, long i7, long i8, long i9, long i10, long i11, long i12, long i13, double f1, double f2, double f3, double f4, double f5, double f6, double f7, double f8, double f9, double f10, double f11, double f12, double f13, double f14, double f15);

typedef double (*fp_fn_t)(id self, SEL _cmd, long i1, long i2, long i3, long i4, long i5, long i6, long i7, long i8, long i9, long i10, long i11, long i12, long i13, double f1, double f2, double f3, double f4, double f5, double f6, double f7, double f8, double f9, double f10, double f11, double f12, double f13, double f14, double f15);

typedef struct stret (*st_fn_t)(id self, SEL _cmd, long i1, long i2, long i3, long i4, long i5, long i6, long i7, long i8, long i9, long i10, long i11, long i12, long i13, double f1, double f2, double f3, double f4, double f5, double f6, double f7, double f8, double f9, double f10, double f11, double f12, double f13, double f14, double f15);

__BEGIN_DECLS
extern void *getSP(void);
__END_DECLS

#if defined(__x86_64__)
    asm(".text \n _getSP: movq %rsp, %rax \n retq \n");
#elif defined(__i386__)
    asm(".text \n _getSP: movl %esp, %eax \n ret \n");
#elif defined(__arm__)
    asm(".text \n _getSP: mov r0, sp \n bx lr \n");
#else
#   error unknown architecture
#endif

int main()
{
    id idval;
    long long llval;
    struct stret stval;
    double fpval;
    void *sp1 = (void*)1;
    void *sp2 = (void*)2;

    receiver = [Super class];

    // Test default forward handler

    state = 1;
    sp1 = getSP();
    idval = [Super idret:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 2);
    testassert(idval == ID_RESULT);

    state = 3;
    sp1 = getSP();
    llval = [Super llret:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 4);
    testassert(llval == LL_RESULT);

    state = 5;
    sp1 = getSP();
    fpval = [Super fpret:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 6);
    testassert(fpval == FP_RESULT);

    state = 7;
    sp1 = getSP();
    stval = [Super stret:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 8);
    testassert(stret_equal(stval, STRET_RESULT));


    // Test default forward handler, cached

    state = 1;
    sp1 = getSP();
    idval = [Super idret:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 2);
    testassert(idval == ID_RESULT);

    state = 3;
    sp1 = getSP();
    llval = [Super llret:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 4);
    testassert(llval == LL_RESULT);

    state = 5;
    sp1 = getSP();
    fpval = [Super fpret:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 6);
    testassert(fpval == FP_RESULT);

    state = 7;
    sp1 = getSP();
    stval = [Super stret:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 8);
    testassert(stret_equal(stval, STRET_RESULT));


    // Test default forward handler, uncached but fixed-up

    _objc_flush_caches(nil);

    state = 1;
    sp1 = getSP();
    idval = [Super idret:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 2);
    testassert(idval == ID_RESULT);

    state = 3;
    sp1 = getSP();
    llval = [Super llret:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 4);
    testassert(llval == LL_RESULT);

    state = 5;
    sp1 = getSP();
    fpval = [Super fpret:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 6);
    testassert(fpval == FP_RESULT);

    state = 7;
    sp1 = getSP();
    stval = [Super stret:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 8);
    testassert(stret_equal(stval, STRET_RESULT));


    // Test manual forwarding

    state = 1;
    sp1 = getSP();
    idval = ((id_fn_t)_objc_msgForward)(receiver, @selector(idre2::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 2);
    testassert(idval == ID_RESULT);

    state = 3;
    sp1 = getSP();
    llval = ((ll_fn_t)_objc_msgForward)(receiver, @selector(llre2::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 4);
    testassert(llval == LL_RESULT);

    state = 5;
    sp1 = getSP();
    fpval = ((fp_fn_t)_objc_msgForward)(receiver, @selector(fpre2::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 6);
    testassert(fpval == FP_RESULT);

    state = 7;
    sp1 = getSP();
    stval = ((st_fn_t)_objc_msgForward_stret)(receiver, @selector(stre2::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 8);
    testassert(stret_equal(stval, STRET_RESULT));


    // Test manual forwarding, cached

    state = 1;
    sp1 = getSP();
    idval = ((id_fn_t)_objc_msgForward)(receiver, @selector(idre2::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 2);
    testassert(idval == ID_RESULT);

    state = 3;
    sp1 = getSP();
    llval = ((ll_fn_t)_objc_msgForward)(receiver, @selector(llre2::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 4);
    testassert(llval == LL_RESULT);

    state = 5;
    sp1 = getSP();
    fpval = ((fp_fn_t)_objc_msgForward)(receiver, @selector(fpre2::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 6);
    testassert(fpval == FP_RESULT);

    state = 7;
    sp1 = getSP();
    stval = ((st_fn_t)_objc_msgForward_stret)(receiver, @selector(stre2::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 8);
    testassert(stret_equal(stval, STRET_RESULT));


    // Test manual forwarding, uncached but fixed-up

    _objc_flush_caches(nil);

    state = 1;
    sp1 = getSP();
    idval = ((id_fn_t)_objc_msgForward)(receiver, @selector(idre2::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 2);
    testassert(idval == ID_RESULT);

    state = 3;
    sp1 = getSP();
    llval = ((ll_fn_t)_objc_msgForward)(receiver, @selector(llre2::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 4);
    testassert(llval == LL_RESULT);

    state = 5;
    sp1 = getSP();
    fpval = ((fp_fn_t)_objc_msgForward)(receiver, @selector(fpre2::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 6);
    testassert(fpval == FP_RESULT);

    state = 7;
    sp1 = getSP();
    stval = ((st_fn_t)_objc_msgForward_stret)(receiver, @selector(stre2::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 8);
    testassert(stret_equal(stval, STRET_RESULT));


    // Test user-defined forward handler

    objc_setForwardHandler((void*)&forward_handler, (void*)&forward_stret_handler);

    state = 11;
    sp1 = getSP();
    idval = [Super idre3:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 12);
    testassert(idval == ID_RESULT);

    state = 13;
    sp1 = getSP();
    llval = [Super llre3:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 14);
    testassert(llval == LL_RESULT);

    state = 15;
    sp1 = getSP();
    fpval = [Super fpre3:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 16);
    testassert(fpval == FP_RESULT);

    state = 17;
    sp1 = getSP();
    stval = [Super stre3:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 18);
    testassert(stret_equal(stval, STRET_RESULT));


    // Test user-defined forward handler, cached

    state = 11;
    sp1 = getSP();
    idval = [Super idre3:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 12);
    testassert(idval == ID_RESULT);

    state = 13;
    sp1 = getSP();
    llval = [Super llre3:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 14);
    testassert(llval == LL_RESULT);

    state = 15;
    sp1 = getSP();
    fpval = [Super fpre3:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 16);
    testassert(fpval == FP_RESULT);

    state = 17;
    sp1 = getSP();
    stval = [Super stre3:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 18);
    testassert(stret_equal(stval, STRET_RESULT));


    // Test user-defined forward handler, uncached but fixed-up

    _objc_flush_caches(nil);

    state = 11;
    sp1 = getSP();
    idval = [Super idre3:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 12);
    testassert(idval == ID_RESULT);

    state = 13;
    sp1 = getSP();
    llval = [Super llre3:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 14);
    testassert(llval == LL_RESULT);

    state = 15;
    sp1 = getSP();
    fpval = [Super fpre3:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 16);
    testassert(fpval == FP_RESULT);

    state = 17;
    sp1 = getSP();
    stval = [Super stre3:1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    sp2 = getSP();
    testassert(sp1 == sp2);
    testassert(state == 18);
    testassert(stret_equal(stval, STRET_RESULT));


    succeed(__FILE__);
}

#endif
