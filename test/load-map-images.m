// TEST_CONFIG MEM=mrc

#include "test.h"
#include "testroot.i"
#include <objc/objc-internal.h>

#include "swift-class-def.m"

#if __LP64__

typedef struct mach_header_64 headerType;
typedef struct segment_command_64 segmentType;
typedef struct section_64 sectionType;
static uint32_t magic = MH_MAGIC_64;
static uint32_t segmentCmd = LC_SEGMENT_64;

#else

typedef struct mach_header headerType;
typedef struct segment_command segmentType;
typedef struct section sectionType;
static uint32_t magic = MH_MAGIC;
static uint32_t segmentCmd = LC_SEGMENT;

#endif

EXTERN_C Class swiftInit(Class cls __unused, void *arg __unused)
{
    _objc_realizeClassFromSwift(cls, cls);
    return cls;
}

SWIFT_CLASS(DynamicClass, TestRoot, swiftInit);

int main()
{
    const char *path = NULL;
    struct { uint32_t version, flags; } imageInfo = {};

    struct Header {
        headerType machHeader;
        segmentType segments[1];
        sectionType sections[2];
    };
    struct Header header = {
        .machHeader = {
            .magic = magic,
            .ncmds = 1,
            .sizeofcmds = sizeof(header.segments) + sizeof(header.sections),
        },
        .segments = {
            {
                .cmd = segmentCmd,
                .cmdsize = sizeof(header.segments) + sizeof(header.sections),
                .segname = "__DATA",
                .nsects = 2,
            },
        },
        .sections = {
            {
                // .sectname = "__objc_classlist",
                .segname = "__DATA",
                .addr = (uintptr_t)&RawDynamicClass - (uintptr_t)&header,
                .size = sizeof(uintptr_t),
            },
            {
                // .sectname = "__objc_imageinfo",
                .segname = "__DATA",
                .addr = (uintptr_t)&imageInfo - (uintptr_t)&header,
                .size = sizeof(imageInfo),
            },
        },
    };
    strncpy(header.sections[0].sectname, "__objc_classlist", 16);
    strncpy(header.sections[1].sectname, "__objc_imageinfo", 16);

    const struct mach_header *headerPtr = (struct mach_header *)&header;
    _objc_map_images(1, &path, &headerPtr);
    _objc_load_image(path, headerPtr);

    testassert(objc_getClass("DynamicClass"));

    succeed(__FILE__);
}