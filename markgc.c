/*
 * Copyright (c) 2007-2009 Apple Inc.  All Rights Reserved.
 * 
 * @APPLE_LICENSE_HEADER_START@
 * 
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */

#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdbool.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <mach-o/fat.h>
#include <mach-o/arch.h>
#include <mach-o/loader.h>

// from "objc-private.h"
// masks for objc_image_info.flags
#define OBJC_IMAGE_IS_REPLACEMENT (1<<0)
#define OBJC_IMAGE_SUPPORTS_GC (1<<1)
#define OBJC_IMAGE_REQUIRES_GC (1<<2)
#define OBJC_IMAGE_OPTIMIZED_BY_DYLD (1<<3)

bool debug;
bool verbose;
bool quiet;
bool rrOnly;
bool patch = true;
bool unpatch = false;

struct gcinfo {
        bool hasObjC;
        bool hasInfo;
        uint32_t flags;
        char *arch;
} GCInfo[4];

void dumpinfo(char *filename);

int Errors = 0;
char *FileBase;
size_t FileSize;
const char *FileName;

int main(int argc, char *argv[]) {
    //NSAutoreleasePool *pool = [NSAutoreleasePool new];
    int i;
    //dumpinfo("/System/Library/Frameworks/AppKit.framework/AppKit");
    if (argc == 1) {
        printf("Usage: markgc [-v] [-r] [--] library_or_executable_image [image2 ...]\n");
        printf(" changes Garbage Collection readiness of named images, ignoring those without ObjC segments\n");
        printf("  -p        - patch RR binary to (apparently) support GC (default)\n");
        printf("  -u        - unpatch GC binary to RR only\n");
        printf("\nAuthor: blaine@apple.com\n");
        exit(0);
    }
    for (i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "-v")) {
            verbose = true;
            continue;
        }
        if (!strcmp(argv[i], "-d")) {
            debug = true;
            continue;
        }
        if (!strcmp(argv[i], "-q")) {
            quiet = true;
            continue;
        }
        if (!strcmp(argv[i], "-p")) {
            patch = true;
            continue;
        }
        if (!strcmp(argv[i], "-u")) {
            unpatch = true;
            patch = false;
            continue;
        }
        dumpinfo(argv[i]);
    }
    return Errors;
}

struct imageInfo {
    uint32_t version;
    uint32_t flags;
};

void patchFile(uint32_t value, size_t offset) {
    int fd = open(FileName, 1);
    off_t lresult = lseek(fd, offset, SEEK_SET);
    if (lresult == -1) {
        printf("couldn't seek to 0x%lx position on fd %d\n", offset, fd);
        ++Errors;
        return;
    }
    size_t wresult = write(fd, &value, 4);
    if (wresult != 4) {
        ++Errors;
        printf("didn't write new value\n");
    }
    else {
        printf("patched %s at offset 0x%lx\n", FileName, offset);
    }
    close(fd);
}

uint32_t iiflags(struct imageInfo *ii, size_t size, bool needsFlip) {
    if (needsFlip) {
        ii->flags = OSSwapInt32(ii->flags);
    }
    if (debug) printf("flags->%x, nitems %lu\n", ii->flags, size/sizeof(struct imageInfo));
    uint32_t support_mask = OBJC_IMAGE_SUPPORTS_GC;
    uint32_t flags = ii->flags;
    if (patch && (flags & support_mask) != support_mask) {
        //printf("will patch %s at offset %p\n", FileName, (char*)(&ii->flags) - FileBase);
        uint32_t newvalue = flags | support_mask;
        if (needsFlip) newvalue = OSSwapInt32(newvalue);
        patchFile(newvalue, (char*)(&ii->flags) - FileBase);
    }
    if (unpatch && (flags & support_mask) == support_mask) {
        uint32_t newvalue = flags & ~support_mask;
        if (needsFlip) newvalue = OSSwapInt32(newvalue);
        patchFile(newvalue, (char*)(&ii->flags) - FileBase);
    }
    for(unsigned niis = 1; niis < size/sizeof(struct imageInfo); ++niis) {
        if (needsFlip) ii[niis].flags = OSSwapInt32(ii[niis].flags);
        if (ii[niis].flags != flags) {
            // uh, oh.
            printf("XXX ii[%d].flags %x != ii[0].flags %x\n", niis, ii[niis].flags, flags);
            ++Errors;
        }
    }
    return flags;
}

void printflags(uint32_t flags) {
    if (flags & 0x1) printf(" F&C");
    if (flags & 0x2) printf(" GC");
    if (flags & 0x4) printf(" GC-only");
    else printf(" RR");
}

/*
void doimageinfo(struct imageInfo *ii, uint32_t size, bool needsFlip) {
    uint32_t flags = iiflags(ii, size, needsFlip);
    printflags(flags);
}
*/


void dosect32(void *start, struct section *sect, bool needsFlip, struct gcinfo *gcip) {
    if (debug) printf("section %s from segment %s\n", sect->sectname, sect->segname);
    if (strcmp(sect->segname, "__OBJC")) return;
    gcip->hasObjC = true;
    if (strcmp(sect->sectname, "__image_info")) return;
    gcip->hasInfo = true;
    if (needsFlip) {
        sect->offset = OSSwapInt32(sect->offset);
        sect->size = OSSwapInt32(sect->size);
    }
    // these guys aren't inline - they point elsewhere
    gcip->flags = iiflags(start + sect->offset, sect->size, needsFlip);
}

void dosect64(void *start, struct section_64 *sect, bool needsFlip, struct gcinfo *gcip) {
    if (debug) printf("section %s from segment %s\n", sect->sectname, sect->segname);
    if (strcmp(sect->segname, "__OBJC") && strcmp(sect->segname, "__DATA")) return;
    if (strcmp(sect->sectname, "__image_info") && strncmp(sect->sectname, "__objc_imageinfo", 16)) return;
    gcip->hasObjC = true;
    gcip->hasInfo = true;
    if (needsFlip) {
        sect->offset = OSSwapInt32(sect->offset);
        sect->size = OSSwapInt64(sect->size);
    }
    // these guys aren't inline - they point elsewhere
    gcip->flags = iiflags(start + sect->offset, (size_t)sect->size, needsFlip);
}

void doseg32(void *start, struct segment_command *seg, bool needsFlip, struct gcinfo *gcip) {
    // lets do sections
    if (needsFlip) {
        seg->fileoff = OSSwapInt32(seg->fileoff);
        seg->nsects = OSSwapInt32(seg->nsects);
    }
    if (debug) printf("segment name: %s, nsects %d\n", seg->segname, seg->nsects);
    if (seg->segname[0]) {
        if (strcmp("__OBJC", seg->segname)) return;
    }
    struct section *sect = (struct section *)(seg + 1);
    for (uint32_t nsects = 0; nsects < seg->nsects; ++nsects) {
        // sections directly follow
        
        dosect32(start, sect + nsects, needsFlip, gcip);
    }
}
void doseg64(void *start, struct segment_command_64 *seg, bool needsFlip, struct gcinfo *gcip) {
    if (debug) printf("segment name: %s\n", seg->segname);
    if (seg->segname[0] && strcmp("__OBJC", seg->segname) && strcmp("__DATA", seg->segname)) return;
    gcip->hasObjC = true;
    // lets do sections
    if (needsFlip) {
        seg->fileoff = OSSwapInt64(seg->fileoff);
        seg->nsects = OSSwapInt32(seg->nsects);
    }
    struct section_64 *sect = (struct section_64 *)(seg + 1);
    for (uint32_t nsects = 0; nsects < seg->nsects; ++nsects) {
        // sections directly follow
        
        dosect64(start, sect + nsects, needsFlip, gcip);
    }
}

#if 0
/*
 * A variable length string in a load command is represented by an lc_str
 * union.  The strings are stored just after the load command structure and
 * the offset is from the start of the load command structure.  The size
 * of the string is reflected in the cmdsize field of the load command.
 * Once again any padded bytes to bring the cmdsize field to a multiple
 * of 4 bytes must be zero.
 */
union lc_str {
	uint32_t	offset;	/* offset to the string */
#ifndef __LP64__
	char		*ptr;	/* pointer to the string */
#endif 
};

struct dylib {
    union lc_str  name;			/* library's path name */
    uint32_t timestamp;			/* library's build time stamp */
    uint32_t current_version;		/* library's current version number */
    uint32_t compatibility_version;	/* library's compatibility vers number*/
};

 * A dynamically linked shared library (filetype == MH_DYLIB in the mach header)
 * contains a dylib_command (cmd == LC_ID_DYLIB) to identify the library.
 * An object that uses a dynamically linked shared library also contains a
 * dylib_command (cmd == LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, or
 * LC_REEXPORT_DYLIB) for each library it uses.

struct dylib_command {
	uint32_t	cmd;		/* LC_ID_DYLIB, LC_LOAD_{,WEAK_}DYLIB,
					   LC_REEXPORT_DYLIB */
	uint32_t	cmdsize;	/* includes pathname string */
	struct dylib	dylib;		/* the library identification */
};
#endif

void dodylib(void *start, struct dylib_command *dylibCmd, bool needsFlip) {
    if (!verbose) return;
    if (needsFlip) {
    }
    size_t count = dylibCmd->cmdsize - sizeof(struct dylib_command);
    //printf("offset is %d, count is %d\n", dylibCmd->dylib.name.offset, count);
    if (dylibCmd->dylib.name.offset > count) return;
    //printf("-->%.*s<---", count, ((void *)dylibCmd)+dylibCmd->dylib.name.offset);
    if (verbose) printf("load %s\n", ((char *)dylibCmd)+dylibCmd->dylib.name.offset);
}

struct load_command *doloadcommand(void *start, struct load_command *lc, bool needsFlip, bool is32, struct gcinfo *gcip) {
    if (needsFlip) {
        lc->cmd = OSSwapInt32(lc->cmd);
        lc->cmdsize = OSSwapInt32(lc->cmdsize);
    }

    switch(lc->cmd) {
    case LC_SEGMENT_64:
	if (debug) printf("...segment64\n");
        if (is32) printf("XXX we have a 64-bit segment in a 32-bit mach-o\n");
        doseg64(start, (struct segment_command_64 *)lc, needsFlip, gcip);
        break;
    case LC_SEGMENT:
	if (debug) printf("...segment32\n");
        doseg32(start, (struct segment_command *)lc, needsFlip, gcip);
        break;
    case LC_SYMTAB: if (debug) printf("...dynamic symtab\n"); break;
    case LC_DYSYMTAB: if (debug) printf("...symtab\n"); break;
    case LC_LOAD_DYLIB:
        dodylib(start, (struct dylib_command *)lc, needsFlip);
        break;
    case LC_SUB_UMBRELLA: if (debug) printf("...load subumbrella\n"); break;
    default:    if (debug) printf("cmd is %x\n", lc->cmd); break;
    }
    
    return (struct load_command *)((void *)lc + lc->cmdsize);
}

void doofile(void *start, size_t size, struct gcinfo *gcip) {
    struct mach_header *mh = (struct mach_header *)start;
    bool isFlipped = false;
    if (mh->magic == MH_CIGAM || mh->magic == MH_CIGAM_64) {
        if (debug) printf("(flipping)\n");
        mh->magic = OSSwapInt32(mh->magic);
        mh->cputype = OSSwapInt32(mh->cputype);
        mh->cpusubtype = OSSwapInt32(mh->cpusubtype);
        mh->filetype = OSSwapInt32(mh->filetype);
        mh->ncmds = OSSwapInt32(mh->ncmds);
        mh->sizeofcmds = OSSwapInt32(mh->sizeofcmds);
        mh->flags = OSSwapInt32(mh->flags);
        isFlipped = true;
    }
    if (rrOnly && mh->filetype != MH_DYLIB) return; // ignore executables
    NXArchInfo *info = (NXArchInfo *)NXGetArchInfoFromCpuType(mh->cputype, mh->cpusubtype);
    //printf("%s:", info->description);
    gcip->arch = (char *)info->description;
    //if (debug) printf("...description is %s\n", info->description);
    bool is32 = !(mh->cputype & CPU_ARCH_ABI64);
    if (debug) printf("is 32? %d\n", is32);
    if (debug) printf("filetype -> %d\n", mh->filetype);
    if (debug) printf("ncmds -> %d\n", mh->ncmds);
    struct load_command *lc = (is32 ? (struct load_command *)(mh + 1) : (struct load_command *)((struct mach_header_64 *)start + 1));
    unsigned ncmds;
    for (ncmds = 0; ncmds < mh->ncmds; ++ncmds) {
        lc = doloadcommand(start, lc, isFlipped, is32, gcip);
    }
    //printf("\n");
}

void initGCInfo() {
    bzero((void *)GCInfo, sizeof(GCInfo));
}

void printGCInfo(char *filename) {
    if (!GCInfo[0].hasObjC) return; // don't bother
    // verify that flags are all the same
    uint32_t flags = GCInfo[0].flags;
    bool allSame = true;
    for (int i = 1; i < 4 && GCInfo[i].arch; ++i) {
        if (flags != GCInfo[i].flags) {
            allSame = false;
        }
    }
    if (rrOnly) {
        if (allSame && (flags & 0x2))
            return;
        printf("*** not all GC in %s:\n", filename);
    }
    if (allSame && !verbose) {
        printf("%s:", filename);
        printflags(flags);
        printf("\n");
    }
    else {
        printf("%s:\n", filename);
        for (int i = 0; i < 4 && GCInfo[i].arch; ++i) {
            printf("%s:", GCInfo[i].arch);
            printflags(GCInfo[i].flags);
            printf("\n");
        }
        printf("\n");
    }
}

void dofat(void *start) {
    struct fat_header *fh = start;
    bool needsFlip = false;
    if (fh->magic == FAT_CIGAM) {
        fh->nfat_arch = OSSwapInt32(fh->nfat_arch);
        needsFlip = true;
    }
    if (debug) printf("%d architectures\n", fh->nfat_arch);
    unsigned narchs;
    struct fat_arch *arch_ptr = (struct fat_arch *)(fh + 1);
    for (narchs = 0; narchs < fh->nfat_arch; ++narchs) {
        if (debug) printf("doing arch %d\n", narchs);
        if (needsFlip) {
            arch_ptr->offset = OSSwapInt32(arch_ptr->offset);
            arch_ptr->size = OSSwapInt32(arch_ptr->size);
        }
        doofile(start+arch_ptr->offset, arch_ptr->size, &GCInfo[narchs]);
        arch_ptr++;
    }
}

bool openFile(const char *filename) {
    FileName = filename;
    // get size
    struct stat statb;
    int fd = open(filename, 0);
    if (fd < 0) {
        printf("couldn't open %s for reading\n", filename);
        return false;
    }
    int osresult = fstat(fd, &statb);
    if (osresult != 0) {
        printf("couldn't get size of %s\n", filename);
        close(fd);
        return false;
    }
	if ((sizeof(size_t) == 4) && ((size_t)statb.st_size > SIZE_T_MAX)) {
        printf("couldn't malloc %llu bytes\n", statb.st_size);
        close(fd);
        return false;
	}
    FileSize = (size_t)statb.st_size;
    FileBase = malloc(FileSize);
    if (!FileBase) {
        printf("couldn't malloc %lu bytes\n", FileSize);
        close(fd);
        return false;
    }
    ssize_t readsize = read(fd, FileBase, FileSize);
    if ((readsize == -1) || ((size_t)readsize != FileSize)) {
        printf("read %ld bytes, wanted %ld\n", (size_t)readsize, FileSize);
        close(fd);
        return false;
    }
    close(fd);
    return true;
}

void closeFile() {
    free(FileBase);
}

void dumpinfo(char *filename) {
    initGCInfo();
    if (!openFile(filename)) exit(1);
    struct fat_header *fh = (struct fat_header *)FileBase;
    if (fh->magic == FAT_MAGIC || fh->magic == FAT_CIGAM) {
        dofat((void *)FileBase);
        //printGCInfo(filename);
    }
    else if (fh->magic == MH_MAGIC || fh->magic == MH_CIGAM || fh->magic == MH_MAGIC_64 || fh->magic == MH_CIGAM_64) {
        doofile((void *)FileBase, FileSize, &GCInfo[0]);
        //printGCInfo(filename);
    }
    else if (!quiet) {
        printf("don't understand %s!\n", filename);
    }
    closeFile();
 }

