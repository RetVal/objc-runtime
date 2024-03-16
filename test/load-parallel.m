/*
TEST_CONFIG OS=!exclavekit
TEST_BUILD
    $C{COMPILE} $DIR/load-parallel00.m -install_name $T{DYLIBDIR}/load-parallel00.dylib -o load-parallel00.dylib -dynamiclib
    $C{COMPILE} $DIR/load-parallel.m -x none load-parallel00.dylib -o load-parallel.exe -DCOUNT=10

    $C{COMPILE} $DIR/load-parallel0.m -x none load-parallel00.dylib -install_name $T{DYLIBDIR}/load-parallel0.dylib -o load-parallel0.dylib -dynamiclib -DN=0
    $C{COMPILE} $DIR/load-parallel0.m -x none load-parallel00.dylib -install_name $T{DYLIBDIR}/load-parallel1.dylib -o load-parallel1.dylib -dynamiclib -DN=1
    $C{COMPILE} $DIR/load-parallel0.m -x none load-parallel00.dylib -install_name $T{DYLIBDIR}/load-parallel2.dylib -o load-parallel2.dylib -dynamiclib -DN=2
    $C{COMPILE} $DIR/load-parallel0.m -x none load-parallel00.dylib -install_name $T{DYLIBDIR}/load-parallel3.dylib -o load-parallel3.dylib -dynamiclib -DN=3
    $C{COMPILE} $DIR/load-parallel0.m -x none load-parallel00.dylib -install_name $T{DYLIBDIR}/load-parallel4.dylib -o load-parallel4.dylib -dynamiclib -DN=4
    $C{COMPILE} $DIR/load-parallel0.m -x none load-parallel00.dylib -install_name $T{DYLIBDIR}/load-parallel5.dylib -o load-parallel5.dylib -dynamiclib -DN=5
    $C{COMPILE} $DIR/load-parallel0.m -x none load-parallel00.dylib -install_name $T{DYLIBDIR}/load-parallel6.dylib -o load-parallel6.dylib -dynamiclib -DN=6
    $C{COMPILE} $DIR/load-parallel0.m -x none load-parallel00.dylib -install_name $T{DYLIBDIR}/load-parallel7.dylib -o load-parallel7.dylib -dynamiclib -DN=7
    $C{COMPILE} $DIR/load-parallel0.m -x none load-parallel00.dylib -install_name $T{DYLIBDIR}/load-parallel8.dylib -o load-parallel8.dylib -dynamiclib -DN=8
    $C{COMPILE} $DIR/load-parallel0.m -x none load-parallel00.dylib -install_name $T{DYLIBDIR}/load-parallel9.dylib -o load-parallel9.dylib -dynamiclib -DN=9
END
*/

#include "test.h"

#include <dlfcn.h>
#include <pthread.h>

#ifndef COUNT
#error -DCOUNT=c missing
#endif

extern atomic_int state;

void *thread(void *arg)
{
    uintptr_t num = (uintptr_t)arg;
    char *buf;

    asprintf(&buf, "load-parallel%lu.dylib", (unsigned long)num);
    testprintf("%s\n", buf);
    void *dlh = dlopen(buf, RTLD_LAZY);
    if (!dlh) {
        fail("dlopen failed: %s", dlerror());
    }
    free(buf);

    return NULL;
}

int main()
{
    pthread_t t[COUNT];
    uintptr_t i;

    for (i = 0; i < COUNT; i++) {
        pthread_create(&t[i], NULL, thread, (void *)i);
    }

    for (i = 0; i < COUNT; i++) {
        pthread_join(t[i], NULL);
    }

    testprintf("loaded %d/%d\n", (int)state, COUNT*26);
    testassert(state == COUNT*26);

    succeed(__FILE__);
}
