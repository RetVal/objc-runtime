#!/bin/sh

# Check ObjC headers for unwanted defines exposed to clients.

TESTINCLUDEDIR=$1; shift
TESTLOCALINCLUDEDIR=$1; shift
COMPILE_C=$1; shift
COMPILE_CXX=$1; shift
COMPILE_M=$1; shift
COMPILE_MM=$1; shift
VERBOSE=$1; shift

# stop after any command error
set -e

# echo commands when verbose
if [ "$VERBOSE" != "0" ]; then
    set -x
fi

FILES="$TESTINCLUDEDIR/objc/*.h $TESTLOCALINCLUDEDIR/objc/*.h"
CFLAGS='-fsyntax-only -Wno-unused-function -D_OBJC_PRIVATE_H_'

INCLUDES=$(grep -h '#include' $FILES | grep -v '<objc/' \
    | sed 's/^#include \(.*\)$/#if __has_include(\1)\n#include \1\n#endif/g')

sort $(dirname $0)/defines.expected > defines.expected

ERROR=

extract_defines() {
    echo "$INCLUDES" | $1 - -dM -E \
        | sed 's/\(#define [_A-Za-z][_A-Za-z0-9]*\).*/\1/g' \
        | sort | uniq
}

get_new_lines() {
    diff -u -U 0 $1 $2 | grep -v "^+++" | grep "^+" | cut -c2- || true
}

run_test() {
    extract_defines "$1 $CFLAGS" > base-defines
    extract_defines "$1 $CFLAGS $FILES" > objc-defines
    get_new_lines base-defines objc-defines > objc-defines-only
    if [[ ! -s objc-defines-only ]]; then
        echo "ERROR: objc-defines-only is somehow empty."
        exit 1
    fi
    get_new_lines defines.expected objc-defines-only > objc-defines-unexpected
    if [[ -s objc-defines-unexpected ]]; then
        echo "ERROR: unknown #defines found in headers. If these are expected, add them to test/defines.expected."
        echo "$1"
        cat objc-defines-unexpected
        ERROR=1
    fi
    rm base-defines objc-defines objc-defines-only objc-defines-unexpected
}

run_test "$COMPILE_C $CFLAGS"
run_test "$COMPILE_CXX $CFLAGS"
run_test "$COMPILE_M $CFLAGS"
run_test "$COMPILE_MM $CFLAGS"
for STDC in '99' '11' ; do
    run_test "$COMPILE_C $CFLAGS -std=c$STDC"
    run_test "$COMPILE_M $CFLAGS -std=c$STDC"
done
for STDCXX in '98' '03' '11' '14' '17' ; do
    run_test "$COMPILE_CXX $CFLAGS -std=c++$STDCXX"
    run_test "$COMPILE_MM $CFLAGS -std=c++$STDCXX"
done

if [[ $ERROR == "" ]]; then
    echo "No unexpected #defines found."
else
    echo "Unknown #defines found in headers."
fi
