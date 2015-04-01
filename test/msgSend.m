// TEST_CONFIG

#include "test.h"
#include "testroot.i"

#if __cplusplus  &&  !__clang__

int main()
{
    // llvm-g++ is confused by @selector(foo::) and will never be fixed
    succeed(__FILE__);
}

#else

#include <objc/objc.h>
#include <objc/runtime.h>
#include <objc/objc-internal.h>
#include <objc/objc-abi.h>

#if defined(__arm__) 
// rdar://8331406
#   define ALIGN_() 
#else
#   define ALIGN_() asm(".align 4");
#endif

@interface Super : TestRoot @end

@interface Sub : Super @end

static int state = 0;

static id SELF;

// for typeof() shorthand only
id (*idmsg0)(id, SEL) __attribute__((unused));
long long (*llmsg0)(id, SEL) __attribute__((unused));
// struct stret (*stretmsg0)(id, SEL) __attribute__((unused));
double (*fpmsg0)(id, SEL) __attribute__((unused));
long double (*lfpmsg0)(id, SEL) __attribute__((unused));


#define CHECK_ARGS(sel) \
do { \
    testassert(self == SELF); \
    testassert(_cmd == sel_registerName(#sel "::::::::::::::::::::::::::::"));\
    testassert(i1 == 1); \
    testassert(i2 == 2); \
    testassert(i3 == 3); \
    testassert(i4 == 4); \
    testassert(i5 == 5); \
    testassert(i6 == 6); \
    testassert(i7 == 7); \
    testassert(i8 == 8); \
    testassert(i9 == 9); \
    testassert(i10 == 10); \
    testassert(i11 == 11); \
    testassert(i12 == 12); \
    testassert(i13 == 13); \
    testassert(f1 == 1.0); \
    testassert(f2 == 2.0); \
    testassert(f3 == 3.0); \
    testassert(f4 == 4.0); \
    testassert(f5 == 5.0); \
    testassert(f6 == 6.0); \
    testassert(f7 == 7.0); \
    testassert(f8 == 8.0); \
    testassert(f9 == 9.0); \
    testassert(f10 == 10.0); \
    testassert(f11 == 11.0); \
    testassert(f12 == 12.0); \
    testassert(f13 == 13.0); \
    testassert(f14 == 14.0); \
    testassert(f15 == 15.0); \
} while (0) 

#define CHECK_ARGS_NOARG(sel) \
do { \
    testassert(self == SELF); \
    testassert(_cmd == sel_registerName(#sel "_noarg"));\
} while (0)

id ID_RESULT;
long long LL_RESULT = __LONG_LONG_MAX__ - 2LL*__INT_MAX__;
double FP_RESULT = __DBL_MIN__ + __DBL_EPSILON__;
long double LFP_RESULT = __LDBL_MIN__ + __LDBL_EPSILON__;
// STRET_RESULT in test.h

static struct stret zero;


@implementation Super
-(struct stret)stret { return STRET_RESULT; }

-(id)idret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    CHECK_ARGS(idret);
    state = 1;
    return ID_RESULT;
}

-(long long)llret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    CHECK_ARGS(llret);
    state = 2;
    return LL_RESULT;
}

-(struct stret)stret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    CHECK_ARGS(stret);
    state = 3;
    return STRET_RESULT;
}

-(double)fpret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    CHECK_ARGS(fpret);
    state = 4;
    return FP_RESULT;
}

-(long double)lfpret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    CHECK_ARGS(lfpret);
    state = 5;
    return LFP_RESULT;
}


-(id)idret_noarg
{
    CHECK_ARGS_NOARG(idret);
    state = 11;
    return ID_RESULT;
}

-(long long)llret_noarg
{
    CHECK_ARGS_NOARG(llret);
    state = 12;
    return LL_RESULT;
}

-(struct stret)stret_noarg
{
    CHECK_ARGS_NOARG(stret);
    state = 13;
    return STRET_RESULT;
}

-(double)fpret_noarg
{
    CHECK_ARGS_NOARG(fpret);
    state = 14;
    return FP_RESULT;
}

-(long double)lfpret_noarg
{
    CHECK_ARGS_NOARG(lfpret);
    state = 15;
    return LFP_RESULT;
}


-(void)voidret_nop
{
    return;
}

-(id)idret_nop
{
    return ID_RESULT;
}

-(long long)llret_nop
{
    return LL_RESULT;
}

-(struct stret)stret_nop
{
    return STRET_RESULT;
}

-(double)fpret_nop
{
    return FP_RESULT;
}

-(long double)lfpret_nop
{
    return LFP_RESULT;
}



+(id)idret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    fail("+idret called instead of -idret");
    CHECK_ARGS(idret);
}

+(long long)llret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    fail("+llret called instead of -llret");
    CHECK_ARGS(llret);
}

+(struct stret)stret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    fail("+stret called instead of -stret");
    CHECK_ARGS(stret);
}

+(double)fpret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    fail("+fpret called instead of -fpret");
    CHECK_ARGS(fpret);
}

+(long double)lfpret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    fail("+lfpret called instead of -lfpret");
    CHECK_ARGS(lfpret);
}

+(id)idret_noarg
{
    fail("+idret_noarg called instead of -idret_noarg");
    CHECK_ARGS_NOARG(idret);
}

+(long long)llret_noarg
{
    fail("+llret_noarg called instead of -llret_noarg");
    CHECK_ARGS_NOARG(llret);
}

+(struct stret)stret_noarg
{
    fail("+stret_noarg called instead of -stret_noarg");
    CHECK_ARGS_NOARG(stret);
}

+(double)fpret_noarg
{
    fail("+fpret_noarg called instead of -fpret_noarg");
    CHECK_ARGS_NOARG(fpret);
}

+(long double)lfpret_noarg
{
    fail("+lfpret_noarg called instead of -lfpret_noarg");
    CHECK_ARGS_NOARG(lfpret);
}

@end


@implementation Sub

-(id)idret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    id result;
    CHECK_ARGS(idret);
    state = 100;
    result = [super idret:i1:i2:i3:i4:i5:i6:i7:i8:i9:i10:i11:i12:i13:f1:f2:f3:f4:f5:f6:f7:f8:f9:f10:f11:f12:f13:f14:f15];
    testassert(state == 1);
    testassert(result == ID_RESULT);
    state = 101;
    return result;
}

-(long long)llret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    long long result;
    CHECK_ARGS(llret);
    state = 100;
    result = [super llret:i1:i2:i3:i4:i5:i6:i7:i8:i9:i10:i11:i12:i13:f1:f2:f3:f4:f5:f6:f7:f8:f9:f10:f11:f12:f13:f14:f15];
    testassert(state == 2);
    testassert(result == LL_RESULT);
    state = 102;
    return result;
}

-(struct stret)stret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    struct stret result;
    CHECK_ARGS(stret);
    state = 100;
    result = [super stret:i1:i2:i3:i4:i5:i6:i7:i8:i9:i10:i11:i12:i13:f1:f2:f3:f4:f5:f6:f7:f8:f9:f10:f11:f12:f13:f14:f15];
    testassert(state == 3);
    testassert(stret_equal(result, STRET_RESULT));
    state = 103;
    return result;
}

-(double)fpret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    double result;
    CHECK_ARGS(fpret);
    state = 100;
    result = [super fpret:i1:i2:i3:i4:i5:i6:i7:i8:i9:i10:i11:i12:i13:f1:f2:f3:f4:f5:f6:f7:f8:f9:f10:f11:f12:f13:f14:f15];
    testassert(state == 4);
    testassert(result == FP_RESULT);
    state = 104;
    return result;
}

-(long double)lfpret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    long double result;
    CHECK_ARGS(lfpret);
    state = 100;
    result = [super lfpret:i1:i2:i3:i4:i5:i6:i7:i8:i9:i10:i11:i12:i13:f1:f2:f3:f4:f5:f6:f7:f8:f9:f10:f11:f12:f13:f14:f15];
    testassert(state == 5);
    testassert(result == LFP_RESULT);
    state = 105;
    return result;
}


-(id)idret_noarg
{
    id result;
    CHECK_ARGS_NOARG(idret);
    state = 100;
    result = [super idret_noarg];
    testassert(state == 11);
    testassert(result == ID_RESULT);
    state = 111;
    return result;
}

-(long long)llret_noarg
{
    long long result;
    CHECK_ARGS_NOARG(llret);
    state = 100;
    result = [super llret_noarg];
    testassert(state == 12);
    testassert(result == LL_RESULT);
    state = 112;
    return result;
}

-(struct stret)stret_noarg
{
    struct stret result;
    CHECK_ARGS_NOARG(stret);
    state = 100;
    result = [super stret_noarg];
    testassert(state == 13);
    testassert(stret_equal(result, STRET_RESULT));
    state = 113;
    return result;
}

-(double)fpret_noarg
{
    double result;
    CHECK_ARGS_NOARG(fpret);
    state = 100;
    result = [super fpret_noarg];
    testassert(state == 14);
    testassert(result == FP_RESULT);
    state = 114;
    return result;
}

-(long double)lfpret_noarg
{
    long double result;
    CHECK_ARGS_NOARG(lfpret);
    state = 100;
    result = [super lfpret_noarg];
    testassert(state == 15);
    testassert(result == LFP_RESULT);
    state = 115;
    return result;
}

@end


#if __x86_64__

@interface TaggedSub : Sub @end

@implementation TaggedSub : Sub

#define TAG_VALUE(tagSlot, value) (objc_unretainedObject((void*)(1UL | (((uintptr_t)(tagSlot)) << 1) | (((uintptr_t)(value)) << 4))))

+(void)initialize
{
    _objc_insert_tagged_isa(2, self);
}

@end

// DWARF checking machinery

#include <dlfcn.h>
#include <signal.h>
#include <sys/mman.h>
#include <libunwind.h>

#define UNW_STEP_SUCCESS 1
#define UNW_STEP_END     0

bool caught = false;
uintptr_t clobbered;

uintptr_t r12 = 0;
uintptr_t r13 = 0;
uintptr_t r14 = 0;
uintptr_t r15 = 0;
uintptr_t rbx = 0;
uintptr_t rbp = 0;
uintptr_t rsp = 0;
uintptr_t rip = 0;

void handle_exception(x86_thread_state64_t *state)
{
    unw_cursor_t curs;
    unw_word_t reg;
    int err;
    int step;

    err = unw_init_local(&curs, (unw_context_t *)state);
    testassert(!err);

    step = unw_step(&curs);
    testassert(step == UNW_STEP_SUCCESS);

    err = unw_get_reg(&curs, UNW_X86_64_R12, &reg);
    testassert(!err);
    testassert(reg == r12);

    err = unw_get_reg(&curs, UNW_X86_64_R13, &reg);
    testassert(!err);
    testassert(reg == r13);

    err = unw_get_reg(&curs, UNW_X86_64_R14, &reg);
    testassert(!err);
    testassert(reg == r14);

    err = unw_get_reg(&curs, UNW_X86_64_R15, &reg);
    testassert(!err);
    testassert(reg == r15);

    err = unw_get_reg(&curs, UNW_X86_64_RBX, &reg);
    testassert(!err);
    testassert(reg == rbx);

    err = unw_get_reg(&curs, UNW_X86_64_RBP, &reg);
    testassert(!err);
    testassert(reg == rbp);

    err = unw_get_reg(&curs, UNW_X86_64_RSP, &reg);
    testassert(!err);
    testassert(reg == rsp);

    err = unw_get_reg(&curs, UNW_REG_IP, &reg);
    testassert(!err);
    testassert(reg == rip);


    // set thread state to unwound state
    state->__r12 = r12;
    state->__r13 = r13;
    state->__r14 = r14;
    state->__r15 = r15;
    state->__rbx = rbx;
    state->__rbp = rbp;
    state->__rsp = rsp;
    state->__rip = rip;

    caught = true;
}


void sigtrap(int sig, siginfo_t *info, void *cc)
{
    ucontext_t *uc = (ucontext_t *)cc;
    mcontext_t mc = (mcontext_t)uc->uc_mcontext;

    testprintf("    handled\n");

    testassert(sig == SIGTRAP);
    testassert((uintptr_t)info->si_addr-1 == clobbered);

    handle_exception(&mc->__ss);
    // handle_exception changed register state for continuation
}


uint8_t set(uintptr_t dst, uint8_t newvalue)
{
    uintptr_t start = dst & ~(4096-1);
    mprotect((void*)start, 4096, PROT_READ|PROT_WRITE);
    // int3
    uint8_t oldvalue = *(uint8_t *)dst;
    *(uint8_t *)dst = newvalue;
    mprotect((void*)start, 4096, PROT_READ|PROT_EXEC);
    return oldvalue;
}

uint8_t clobber(void *fn, uintptr_t offset)
{
    clobbered = (uintptr_t)fn + offset;
    return set((uintptr_t)fn + offset, 0xcc /*int3*/);
}

void unclobber(void *fn, uintptr_t offset, uint8_t oldvalue)
{
    set((uintptr_t)fn + offset, oldvalue);
}

__BEGIN_DECLS
extern void callit(void *obj, void *sel, void *fn);
extern struct stret callit_stret(void *obj, void *sel, void *fn);
__END_DECLS

__asm__(
"\n  .text"
"\n  .globl _callit"
"\n  _callit:"
// save rsp and rip registers to variables
"\n      movq  (%rsp), %r10"
"\n      movq  %r10, _rip(%rip)"
"\n      movq  %rsp, _rsp(%rip)"
"\n      addq  $8,   _rsp(%rip)"   // rewind to pre-call value
// save other non-volatile registers to variables
"\n      movq  %rbx, _rbx(%rip)"
"\n      movq  %rbp, _rbp(%rip)"
"\n      movq  %r12, _r12(%rip)"
"\n      movq  %r13, _r13(%rip)"
"\n      movq  %r14, _r14(%rip)"
"\n      movq  %r15, _r15(%rip)"
"\n      jmpq  *%rdx"
        );

__asm__(
"\n  .text"
"\n  .globl _callit_stret"
"\n  _callit_stret:"
// save rsp and rip registers to variables
"\n      movq  (%rsp), %r10"
"\n      movq  %r10, _rip(%rip)"
"\n      movq  %rsp, _rsp(%rip)"
"\n      addq  $8,   _rsp(%rip)"   // rewind to pre-call value
// save other non-volatile registers to variables
"\n      movq  %rbx, _rbx(%rip)"
"\n      movq  %rbp, _rbp(%rip)"
"\n      movq  %r12, _r12(%rip)"
"\n      movq  %r13, _r13(%rip)"
"\n      movq  %r14, _r14(%rip)"
"\n      movq  %r15, _r15(%rip)"
"\n      jmpq  *%rcx"
        );

uintptr_t *getOffsets(void *symbol, const char *symname)
{
    uintptr_t *result = (uintptr_t *)malloc(4096 * sizeof(uintptr_t));
    uintptr_t *end = result + 4096;
    uintptr_t *p = result;

    // find library
    Dl_info dl;
    dladdr(symbol, &dl);

    // call `otool` on library
    unsetenv("DYLD_LIBRARY_PATH");
    unsetenv("DYLD_ROOT_PATH");
    unsetenv("DYLD_INSERT_LIBRARIES");
    char *cmd;
    asprintf(&cmd, "/usr/bin/xcrun otool -arch x86_64 -tv -p _%s %s", 
             symname, dl.dli_fname);
    FILE *disa = popen(cmd, "r");
    free(cmd);
    testassert(disa);

    // read past "_symname:" line
    char *line;
    size_t len;
    while ((line = fgetln(disa, &len))) {
        if (0 == strncmp(1+line, symname, MIN(len-1, strlen(symname)))) break;
    }

    // read instructions and save offsets
    char op[128];
    long base = 0;
    long addr;
    while (2 == fscanf(disa, "%lx%s%*[^\n]\n", &addr, op)) {
        if (base == 0) base = addr;
        if (0 != strncmp(op, "nop", 3)) {
            testassert(p < end);
            *p++ = addr - base;
        } else {
            // assume nops are unreached (e.g. alignment padding)
        }
    }
    pclose(disa);

    testassert(p > result);
    testassert(p < end);
    *p = ~0UL;
    return result;
}

void CALLIT(void *o, void *sel_arg, SEL s, void *f) __attribute__((noinline));
void CALLIT(void *o, void *sel_arg, SEL s, void *f)
{
    uintptr_t message_ref[2];
    if (sel_arg != s) {
        // fixup dispatch
        // copy to a local buffer to keep sel_arg un-fixed-up
        memcpy(message_ref, sel_arg, sizeof(message_ref));
        sel_arg = message_ref;
    }
    if (s == @selector(idret_nop)) callit(o, sel_arg, f);
    else if (s == @selector(fpret_nop)) callit(o, sel_arg, f);
    else if (s == @selector(stret_nop)) callit_stret(o, sel_arg, f);
    else fail("test_dw selector");
}

// sub = ordinary receiver object
// tagged = tagged receiver object
// SEL = selector to send
// sub_arg = arg to pass in receiver register (may be objc_super struct)
// tagged_arg = arg to pass in receiver register (may be objc_super struct)
// sel_arg = arg to pass in sel register (may be message_ref)
void test_dw(const char *name, id sub, id tagged, SEL sel)
{
    testprintf("DWARF FOR %s\n", name);

    void *fn = dlsym(RTLD_DEFAULT, name);
    testassert(fn);

    // argument substitutions

    void *sub_arg = (void*)objc_unretainedPointer(sub);
    void *tagged_arg = (void*)objc_unretainedPointer(tagged);
    void *sel_arg = (void*)sel;

    struct objc_super sup_st = { sub, object_getClass(sub) };
    struct objc_super tagged_sup_st = { tagged, object_getClass(tagged) };
    struct { void *imp; SEL sel; } message_ref = { fn, sel };

    if (strstr(name, "Super")) {
        // super version - replace receiver with objc_super
        sub_arg = &sup_st;
        tagged_arg = &tagged_sup_st;
    }

    if (strstr(name, "_fixup")) {
        // fixup version - replace sel with message_ref
        sel_arg = &message_ref;
    }


    uintptr_t *insnOffsets = getOffsets(fn, name);
    uintptr_t *offsetp = insnOffsets;
    uintptr_t offset;
    while ((offset = *offsetp++) != ~0UL) {
        testprintf("OFFSET %lu\n", offset);

        uint8_t insn_byte = clobber(fn, offset);
        caught = false;

        // nil
        if ((void*)objc_unretainedPointer(sub) == sub_arg) {
            SELF = nil;
            testprintf("  nil\n");
            CALLIT(nil, sel_arg, sel, fn);
            CALLIT(nil, sel_arg, sel, fn);
        }

        // uncached
        SELF = sub;
        testprintf("  uncached\n");
        _objc_flush_caches(object_getClass(sub));
        CALLIT(sub_arg, sel_arg, sel, fn);
        _objc_flush_caches(object_getClass(sub));
        CALLIT(sub_arg, sel_arg, sel, fn);

        // cached
        SELF = sub;
        testprintf("  cached\n");
        CALLIT(sub_arg, sel_arg, sel, fn);
        CALLIT(sub_arg, sel_arg, sel, fn);
        
        // uncached,tagged
        SELF = tagged;
        testprintf("  uncached,tagged\n");
        _objc_flush_caches(object_getClass(tagged));
        CALLIT(tagged_arg, sel_arg, sel, fn);
        _objc_flush_caches(object_getClass(tagged));
        CALLIT(tagged_arg, sel_arg, sel, fn);

        // cached,tagged
        SELF = tagged;
        testprintf("  cached,tagged\n");
        CALLIT(tagged_arg, sel_arg, sel, fn);
        CALLIT(tagged_arg, sel_arg, sel, fn);
        
        unclobber(fn, offset, insn_byte);

        // require at least one path above to trip this offset
        if (!caught) fprintf(stderr, "OFFSET %lu NOT CAUGHT\n", offset);
    }
    free(insnOffsets);
}

// x86_64
#endif


void test_basic(id receiver)
{
    id idval;
    long long llval;
    struct stret stretval;
    double fpval;
    long double lfpval;

    // message uncached 
    // message uncached long long
    // message uncached stret
    // message uncached fpret
    // message uncached fpret long double
    // message uncached noarg (as above)
    // message cached 
    // message cached long long
    // message cached stret
    // message cached fpret
    // message cached fpret long double
    // message cached noarg (as above)
    // fixme verify that uncached lookup didn't happen the 2nd time?
    SELF = receiver;
    for (int i = 0; i < 5; i++) {
        state = 0;
        idval = nil;
        idval = [receiver idret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
        testassert(state == 101);
        testassert(idval == ID_RESULT);
        
        llval = 0;
        llval = [receiver llret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
        testassert(state == 102);
        testassert(llval == LL_RESULT);
        
        stretval = zero;
        stretval = [receiver stret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
        testassert(state == 103);
        testassert(stret_equal(stretval, STRET_RESULT));
        
        fpval = 0;
        fpval = [receiver fpret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
        testassert(state == 104);
        testassert(fpval == FP_RESULT);
        
        lfpval = 0;
        lfpval = [receiver lfpret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
        testassert(state == 105);
        testassert(lfpval == LFP_RESULT);

#if __OBJC2__
        // explicitly call noarg messenger, even if compiler doesn't emit it
        state = 0;
        idval = nil;
        idval = ((typeof(idmsg0))objc_msgSend_noarg)(receiver, @selector(idret_noarg));
        testassert(state == 111);
        testassert(idval == ID_RESULT);
        
        llval = 0;
        llval = ((typeof(llmsg0))objc_msgSend_noarg)(receiver, @selector(llret_noarg));
        testassert(state == 112);
        testassert(llval == LL_RESULT);
        /*
          no objc_msgSend_stret_noarg
        stretval = zero;
        stretval = ((typeof(stretmsg0))objc_msgSend_stret_noarg)(receiver, @selector(stret_noarg));
        stretval = [receiver stret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
        testassert(state == 113);
        testassert(stret_equal(stretval, STRET_RESULT));
        */
# if !__i386__
        fpval = 0;
        fpval = ((typeof(fpmsg0))objc_msgSend_noarg)(receiver, @selector(fpret_noarg));
        testassert(state == 114);
        testassert(fpval == FP_RESULT);
# endif
# if !__i386__ && !__x86_64__
        lfpval = 0;
        lfpval = ((typeof(lfpmsg0))objc_msgSend_noarg)(receiver, @selector(lfpret_noarg));
        testassert(state == 115);
        testassert(lfpval == LFP_RESULT);
# endif
#endif
    }
}

int main()
{
  PUSH_POOL {
    int i;

    id idval;
    long long llval;
    struct stret stretval;
    double fpval;
    long double lfpval;

    uint64_t startTime;
    uint64_t totalTime;
    uint64_t targetTime;

    Method idmethod;
    Method llmethod;
    Method stretmethod;
    Method fpmethod;
    Method lfpmethod;

    id (*idfn)(id, Method, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double);
    long long (*llfn)(id, Method, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double);
    struct stret (*stretfn)(id, Method, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double);
    double (*fpfn)(id, Method, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double);
    long double (*lfpfn)(id, Method, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double);

    id (*idmsg)(id, SEL, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double) __attribute__((unused));
    id (*idmsgsuper)(struct objc_super *, SEL, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double) __attribute__((unused));
    long long (*llmsg)(id, SEL, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double) __attribute__((unused));
    struct stret (*stretmsg)(id, SEL, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double) __attribute__((unused));
    struct stret (*stretmsgsuper)(struct objc_super *, SEL, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double) __attribute__((unused));
    double (*fpmsg)(id, SEL, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double) __attribute__((unused));
    long double (*lfpmsg)(id, SEL, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double) __attribute__((unused));

    // get +initialize out of the way
    [Sub class];
#if __x86_64__
    [TaggedSub class];
#endif

    ID_RESULT = [Super new];

    Sub *sub = [Sub new];
    Super *sup = [Super new];
#if __x86_64__
    TaggedSub *tagged = TAG_VALUE(2, 999);
#endif
    
    // Basic cached and uncached dispatch.
    // Do this first before anything below caches stuff.
    test_basic(sub);
#if __x86_64__
    test_basic(tagged);
#endif

    idmethod = class_getInstanceMethod([Super class], @selector(idret::::::::::::::::::::::::::::));
    testassert(idmethod);
    llmethod = class_getInstanceMethod([Super class], @selector(llret::::::::::::::::::::::::::::));
    testassert(llmethod);
    stretmethod = class_getInstanceMethod([Super class], @selector(stret::::::::::::::::::::::::::::));
    testassert(stretmethod);
    fpmethod = class_getInstanceMethod([Super class], @selector(fpret::::::::::::::::::::::::::::));
    testassert(fpmethod);
    lfpmethod = class_getInstanceMethod([Super class], @selector(lfpret::::::::::::::::::::::::::::));
    testassert(lfpmethod);

    idfn = (id (*)(id, Method, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double)) method_invoke;
    llfn = (long long (*)(id, Method, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double)) method_invoke;
    stretfn = (struct stret (*)(id, Method, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double)) method_invoke_stret;
    fpfn = (double (*)(id, Method, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double)) method_invoke;
    lfpfn = (long double (*)(id, Method, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double)) method_invoke;

    // cached message performance
    // catches failure to cache or (abi=2) failure to fixup (#5584187)
    // fixme unless they all fail
    // `.align 4` matches loop alignment to make -O0 work
    // fill cache first
    SELF = sub;
    [sub voidret_nop];
    [sub llret_nop];
    [sub stret_nop];
    [sub fpret_nop];
    [sub lfpret_nop];
    [sub voidret_nop];
    [sub llret_nop];
    [sub stret_nop];
    [sub fpret_nop];
    [sub lfpret_nop];
    [sub voidret_nop];
    [sub llret_nop];
    [sub stret_nop];
    [sub fpret_nop];
    [sub lfpret_nop];

    // Some of these times have high variance on some compilers. 
    // The errors we're trying to catch should be catastrophically slow, 
    // so the margins here are generous to avoid false failures.

#define COUNT 1000000
    startTime = mach_absolute_time();
    ALIGN_();
    for (i = 0; i < COUNT; i++) {
        [sub voidret_nop];  // id return is too slow for perf test with ARC
    }
    totalTime = mach_absolute_time() - startTime;
    testprintf("time: idret  %llu\n", totalTime);
    targetTime = totalTime;

    startTime = mach_absolute_time();
    ALIGN_();
    for (i = 0; i < COUNT; i++) {
        [sub voidret_nop];  // id return is too slow for perf test with ARC
    }
    totalTime = mach_absolute_time() - startTime;
    testprintf("time: idret  %llu\n", totalTime);
    targetTime = totalTime;

    startTime = mach_absolute_time();
    ALIGN_();
    for (i = 0; i < COUNT; i++) {
        [sub llret_nop];
    }
    totalTime = mach_absolute_time() - startTime;
    timecheck("llret ", totalTime, targetTime * 0.7, targetTime * 2.0);

    startTime = mach_absolute_time();
    ALIGN_();
    for (i = 0; i < COUNT; i++) {
        [sub stret_nop];
    }
    totalTime = mach_absolute_time() - startTime;
    timecheck("stret ", totalTime, targetTime * 0.7, targetTime * 5.0);
        
    startTime = mach_absolute_time();
    ALIGN_();
    for (i = 0; i < COUNT; i++) {        
        [sub fpret_nop];
    }
    totalTime = mach_absolute_time() - startTime;
    timecheck("fpret ", totalTime, targetTime * 0.7, targetTime * 4.0);
        
    startTime = mach_absolute_time();
    ALIGN_();
    for (i = 0; i < COUNT; i++) {
        [sub lfpret_nop];
    }
    totalTime = mach_absolute_time() - startTime;
    timecheck("lfpret", totalTime, targetTime * 0.7, targetTime * 4.0);
#undef COUNT

    // method_invoke 
    // method_invoke long long
    // method_invoke_stret stret
    // method_invoke_stret fpret
    // method_invoke fpret long double
    SELF = sup;

    state = 0;
    idval = nil;
    idval = (*idfn)(sup, idmethod, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 1);
    testassert(idval == ID_RESULT);
    
    llval = 0;
    llval = (*llfn)(sup, llmethod, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 2);
    testassert(llval == LL_RESULT);
        
    stretval = zero;
    stretval = (*stretfn)(sup, stretmethod, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 3);
    testassert(stret_equal(stretval, STRET_RESULT));
        
    fpval = 0;
    fpval = (*fpfn)(sup, fpmethod, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 4);
    testassert(fpval == FP_RESULT);
        
    lfpval = 0;
    lfpval = (*lfpfn)(sup, lfpmethod, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 5);
    testassert(lfpval == LFP_RESULT);


    // message to nil
    // message to nil long long
    // message to nil stret
    // message to nil fpret
    // message to nil fpret long double
    state = 0;
    idval = ID_RESULT;
    idval = [(id)nil idret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    testassert(state == 0);
    testassert(idval == nil);
    
    state = 0;
    llval = LL_RESULT;
    llval = [(id)nil llret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    testassert(state == 0);
    testassert(llval == 0LL);
    
    state = 0;
    stretval = zero;
    stretval = [(id)nil stret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    testassert(state == 0);
#if __clang__
    testassert(0 == memcmp(&stretval, &zero, sizeof(stretval)));
#else
    // no stret result guarantee
#endif
    
    state = 0;
    fpval = FP_RESULT;
    fpval = [(id)nil fpret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    testassert(state == 0);
    testassert(fpval == 0.0);
    
    state = 0;
    lfpval = LFP_RESULT;
    lfpval = [(id)nil lfpret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    testassert(state == 0);
    testassert(lfpval == 0.0);

#if __OBJC2__
    // message to nil noarg
    // explicitly call noarg messenger, even if compiler doesn't emit it
    state = 0;
    idval = ID_RESULT;
    idval = ((typeof(idmsg0))objc_msgSend_noarg)(nil, @selector(idret_noarg));
    testassert(state == 0);
    testassert(idval == nil);
    
    state = 0;
    llval = LL_RESULT;
    llval = ((typeof(llmsg0))objc_msgSend_noarg)(nil, @selector(llret_noarg));
    testassert(state == 0);
    testassert(llval == 0LL);

    // no stret_noarg messenger

# if !__i386__
    state = 0;
    fpval = FP_RESULT;
    fpval = ((typeof(fpmsg0))objc_msgSend_noarg)(nil, @selector(fpret_noarg));
    testassert(state == 0);
    testassert(fpval == 0.0);
# endif
# if !__i386__ && !__x86_64__
    state = 0;
    lfpval = LFP_RESULT;
    lfpval = ((typeof(lfpmsg0))objc_msgSend_noarg)(nil, @selector(lfpret_noarg));
    testassert(state == 0);
    testassert(lfpval == 0.0);
# endif
#endif
    
    // message forwarded
    // message forwarded long long
    // message forwarded stret
    // message forwarded fpret
    // message forwarded fpret long double
    // fixme

#if __OBJC2__
    // rdar://8271364 objc_msgSendSuper2 must not change objc_super
    struct objc_super sup_st = {
        sub, 
        object_getClass(sub), 
    };

    SELF = sub;

    state = 100;
    idval = nil;
    idval = ((id(*)(struct objc_super *, SEL, int,int,int,int,int,int,int,int,int,int,int,int,int, double,double,double,double,double,double,double,double,double,double,double,double,double,double,double))objc_msgSendSuper2) (&sup_st, @selector(idret::::::::::::::::::::::::::::), 1,2,3,4,5,6,7,8,9,10,11,12,13, 1.0,2.0,3.0,4.0,5.0,6.0,7.0,8.0,9.0,10.0,11.0,12.0,13.0,14.0,15.0);
    testassert(state == 1);
    testassert(idval == ID_RESULT);
    testassert(sup_st.receiver == sub);
    testassert(sup_st.super_class == object_getClass(sub));

    state = 100;
    stretval = zero;
    stretval = ((struct stret(*)(struct objc_super *, SEL, int,int,int,int,int,int,int,int,int,int,int,int,int, double,double,double,double,double,double,double,double,double,double,double,double,double,double,double))objc_msgSendSuper2_stret) (&sup_st, @selector(stret::::::::::::::::::::::::::::), 1,2,3,4,5,6,7,8,9,10,11,12,13, 1.0,2.0,3.0,4.0,5.0,6.0,7.0,8.0,9.0,10.0,11.0,12.0,13.0,14.0,15.0);
    testassert(state == 3);
    testassert(stret_equal(stretval, STRET_RESULT));
    testassert(sup_st.receiver == sub);
    testassert(sup_st.super_class == object_getClass(sub));
#endif

#if __OBJC2__
    // Debug messengers.
    state = 0;
    idmsg = (typeof(idmsg))objc_msgSend_debug;
    idval = nil;
    idval = (*idmsg)(sub, @selector(idret::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 101);
    testassert(idval == ID_RESULT);
    
    state = 0;
    llmsg = (typeof(llmsg))objc_msgSend_debug;
    llval = 0;
    llval = (*llmsg)(sub, @selector(llret::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 102);
    testassert(llval == LL_RESULT);
    
    state = 0;
    stretmsg = (typeof(stretmsg))objc_msgSend_stret_debug;
    stretval = zero;
    stretval = (*stretmsg)(sub, @selector(stret::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 103);
    testassert(stret_equal(stretval, STRET_RESULT));
    
    state = 100;
    sup_st.receiver = sub;
    sup_st.super_class = object_getClass(sub);
    idmsgsuper = (typeof(idmsgsuper))objc_msgSendSuper2_debug;
    idval = nil;
    idval = (*idmsgsuper)(&sup_st, @selector(idret::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 1);
    testassert(idval == ID_RESULT);
    
    state = 100;
    sup_st.receiver = sub;
    sup_st.super_class = object_getClass(sub);
    stretmsgsuper = (typeof(stretmsgsuper))objc_msgSendSuper2_stret_debug;
    stretval = zero;
    stretval = (*stretmsgsuper)(&sup_st, @selector(stret::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 3);
    testassert(stret_equal(stretval, STRET_RESULT));

#if __i386__
    state = 0;
    fpmsg = (typeof(fpmsg))objc_msgSend_fpret_debug;
    fpval = 0;
    fpval = (*fpmsg)(sub, @selector(fpret::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 104);
    testassert(fpval == FP_RESULT);
#endif
#if __x86_64__
    state = 0;
    lfpmsg = (typeof(lfpmsg))objc_msgSend_fpret_debug;
    lfpval = 0;
    lfpval = (*lfpmsg)(sub, @selector(lfpret::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 105);
    testassert(lfpval == LFP_RESULT);

    // fixme fp2ret
#endif

// debug messengers
#endif


#if __x86_64__  &&  !__has_feature(objc_arc)
    // DWARF unwind tables
    // Not for ARC because the extra RR calls hit the traps at the wrong times

    // install exception handler
    struct sigaction act;
    act.sa_sigaction = sigtrap;
    act.sa_mask = 0;
    act.sa_flags = SA_SIGINFO;
    sigaction(SIGTRAP, &act, NULL);

    // use _nop methods because other methods make more calls
    // which can die in the trapped messenger

    test_dw("objc_msgSend",                   sub,tagged,@selector(idret_nop));
    test_dw("objc_msgSend_fixup",             sub,tagged,@selector(idret_nop));
    test_dw("objc_msgSend_stret",             sub,tagged,@selector(stret_nop));
    test_dw("objc_msgSend_stret_fixup",       sub,tagged,@selector(stret_nop));
    test_dw("objc_msgSend_fpret",             sub,tagged,@selector(fpret_nop));
    test_dw("objc_msgSend_fpret_fixup",       sub,tagged,@selector(fpret_nop));
    // fixme fp2ret
    test_dw("objc_msgSendSuper",              sub,tagged,@selector(idret_nop));
    test_dw("objc_msgSendSuper2",             sub,tagged,@selector(idret_nop));
    test_dw("objc_msgSendSuper2_fixup",       sub,tagged,@selector(idret_nop));
    test_dw("objc_msgSendSuper_stret",        sub,tagged,@selector(stret_nop));
    test_dw("objc_msgSendSuper2_stret",       sub,tagged,@selector(stret_nop));
    test_dw("objc_msgSendSuper2_stret_fixup", sub,tagged,@selector(stret_nop));

    // DWARF unwind tables
#endif
  } POP_POOL;
    succeed(__FILE__);
}

#endif
