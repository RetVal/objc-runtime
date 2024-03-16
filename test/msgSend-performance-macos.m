// macOS builds of this test require -loah, which is not valid for other OSes.
// This test provides separate cflags for msgSend-performance.m when
// targeting macOS.
// TEST_CONFIG OS=macosx
// TEST_CFLAGS -loah

const char *FileName = __FILE__;
#define TEST_NAME FileName
#include "msgSend-performance.m"