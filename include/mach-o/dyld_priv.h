/* -*- mode: C++; c-basic-offset: 4; tab-width: 4 -*-
 *
 * Copyright (c) 2003-2010 Apple Inc. All rights reserved.
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
#ifndef _MACH_O_DYLD_PRIV_H_
#define _MACH_O_DYLD_PRIV_H_

#include <assert.h>
#include <stdbool.h>
#if __has_include(<unistd.h>)
#include <unistd.h>
#endif
#include <Availability.h>
#include <TargetConditionals.h>
#include <mach-o/dyld.h>
#include <uuid/uuid.h>

#if __cplusplus
extern "C" {
#endif /* __cplusplus */



//
// private interface between libSystem.dylib and dyld
//
extern void _dyld_atfork_prepare(void);
extern void _dyld_atfork_parent(void);
extern void _dyld_fork_child(void);

extern void _dyld_dlopen_atfork_prepare(void);
extern void _dyld_dlopen_atfork_parent(void);
extern void _dyld_dlopen_atfork_child(void);

typedef struct _dyld_section_location_info_s* _dyld_section_location_info_t;

// These are all the precomputed sections we know about
// Note that all changes to the order, including adding new entries, should involve
// bumping the value in SectionLocations::version
// Always add new entries to the end.  We can't reorder existing entries, as they
// are used in the open source drop of the swift runtime
enum _dyld_section_location_kind {
    // TEXT:
    _dyld_section_location_text_swift5_protos                  = 0x0,
    _dyld_section_location_text_swift5_proto,
    _dyld_section_location_text_swift5_types,
    _dyld_section_location_text_swift5_replace,
    _dyld_section_location_text_swift5_replace2,
    _dyld_section_location_text_swift5_ac_funcs,

    // DATA*:
    _dyld_section_location_objc_image_info,
    _dyld_section_location_data_sel_refs,
    _dyld_section_location_data_msg_refs,
    _dyld_section_location_data_class_refs,
    _dyld_section_location_data_super_refs,
    _dyld_section_location_data_protocol_refs,
    _dyld_section_location_data_class_list,
    _dyld_section_location_data_non_lazy_class_list,
    _dyld_section_location_data_stub_list,
    _dyld_section_location_data_category_list,
    _dyld_section_location_data_category_list2,
    _dyld_section_location_data_non_lazy_category_list,
    _dyld_section_location_data_protocol_list,
    _dyld_section_location_data_objc_fork_ok,
    _dyld_section_location_data_raw_isa,

    // Note, always add new entries before this
    _dyld_section_location_count,
};

// Contains the result from _dyld_lookup_section_info.
// Can be one of:
//   found a section: { start_address_of_section, section_size }
//   unknown section: { nullptr, -1 }
//   not in dylib   : { nullptr, 0 }
struct _dyld_section_info_result {
    void*   buffer;
    size_t  bufferSize;
};

extern struct _dyld_section_info_result _dyld_lookup_section_info(const struct mach_header* mh,
                                                                  _dyld_section_location_info_t locationHandle,
                                                                  enum _dyld_section_location_kind kind);

typedef void (*_dyld_objc_notify_mapped)(unsigned count, const char* const paths[], const struct mach_header* const mh[]);
typedef void (*_dyld_objc_notify_init)(const char* path, const struct mach_header* mh);
typedef void (*_dyld_objc_notify_unmapped)(const char* path, const struct mach_header* mh);
typedef void (*_dyld_objc_notify_patch_class)(const struct mach_header* originalMH, void* originalClass,
                                              const struct mach_header* replacementMH, const void* replacementClass);
struct _dyld_objc_notify_mapped_info {
    const struct mach_header*       mh;
    const char*                     path;
    _dyld_section_location_info_t   sectionLocationMetadata;
    uint32_t                        dyldObjCRefsOptimized   :  1,
                                    flags                   : 31;
};
typedef void (*_dyld_objc_notify_mapped2)(unsigned count, const struct _dyld_objc_notify_mapped_info infos[]);
typedef void (*_dyld_objc_notify_init2)(const struct _dyld_objc_notify_mapped_info* info);

//
// Note: only for use by objc runtime
// Register handlers to be called when objc images are mapped, unmapped, and initialized.
// Dyld will call back the "mapped" function with an array of images that contain an objc-image-info section.
// Those images that are dylibs will have the ref-counts automatically bumped, so objc will no longer need to
// call dlopen() on them to keep them from being unloaded.  During the call to _dyld_objc_notify_register(),
// dyld will call the "mapped" function with already loaded objc images.  During any later dlopen() call,
// dyld will also call the "mapped" function.  Dyld will call the "init" function when dyld would be called
// initializers in that image.  This is when objc calls any +load methods in that image.
//
void _dyld_objc_notify_register(_dyld_objc_notify_mapped    mapped,
                                _dyld_objc_notify_init      init,
                                _dyld_objc_notify_unmapped  unmapped);


struct _dyld_objc_callbacks
{
    uintptr_t version;
};

struct _dyld_objc_callbacks_v1
{
    uintptr_t                       version; // == 1
    _dyld_objc_notify_mapped        mapped;
    _dyld_objc_notify_init          init;
    _dyld_objc_notify_unmapped      unmapped;
    _dyld_objc_notify_patch_class   patches;
};

struct _dyld_objc_callbacks_v2
{
    uintptr_t                       version; // == 2
    _dyld_objc_notify_mapped2       mapped;
    _dyld_objc_notify_init2         init;
    _dyld_objc_notify_unmapped      unmapped;
    _dyld_objc_notify_patch_class   patches;
};


// Exists in Mac OS X 13.0 and later
// Exists in iOS 16.0 and later
// Exists in watchOS 9.0 and later
// Exists in tvOS 16.0 and later.
void _dyld_objc_register_callbacks(const struct _dyld_objc_callbacks*);


//
// get slide for a given loaded mach_header  
// Mac OS X 10.6 and later
//
extern intptr_t _dyld_get_image_slide(const struct mach_header* mh);



struct dyld_unwind_sections
{
	const struct mach_header*		mh;
	const void*						dwarf_section;
	uintptr_t						dwarf_section_length;
	const void*						compact_unwind_section;
	uintptr_t						compact_unwind_section_length;
};


//
// Returns true iff some loaded mach-o image contains "addr".
//	info->mh							mach header of image containing addr
//  info->dwarf_section					pointer to start of __TEXT/__eh_frame section
//  info->dwarf_section_length			length of __TEXT/__eh_frame section
//  info->compact_unwind_section		pointer to start of __TEXT/__unwind_info section
//  info->compact_unwind_section_length	length of __TEXT/__unwind_info section
//
// Exists in Mac OS X 10.6 and later 
#if !__USING_SJLJ_EXCEPTIONS__
extern bool _dyld_find_unwind_sections(void* addr, struct dyld_unwind_sections* info);
#endif


//
// This is an optimized form of dladdr() that only returns the dli_fname field.
//
// Exists in Mac OS X 10.6 and later 
extern const char* dyld_image_path_containing_address(const void* addr);


//
// This is an optimized form of dladdr() that only returns the dli_fbase field.
// Return NULL, if address is not in any image tracked by dyld.
//
// Exists in Mac OS X 10.11 and later
extern const struct mach_header* dyld_image_header_containing_address(const void* addr);

//
// Return the mach header of the process
//
// Exists in Mac OS X 10.16 and later
extern const struct mach_header* _dyld_get_prog_image_header(void);

//
// Return the mach header of the binary returned by dlopen
//
// Exists in Mac OS X 13.0 and later
extern const struct mach_header* _dyld_get_dlopen_image_header(void* handle);

typedef uint32_t dyld_platform_t;

typedef struct {
    dyld_platform_t platform;
    uint32_t        version;
} dyld_build_version_t;

// Returns the active platform of the process
extern dyld_platform_t dyld_get_active_platform(void) __API_AVAILABLE(macos(10.14), ios(12.0), watchos(5.0), tvos(12.0));

// Base platforms are platforms that have version numbers (macOS, iOS, watchos, tvOS, bridgeOS)
// All other platforms are mapped to a base platform for version checks

// It is intended that most code in the OS will use the version set constants, which will correctly deal with secret and future
// platforms. For example:

//  if (dyld_program_sdk_at_least(dyld_fall_2018_os_versions)) {
//      New behaviour for programs built against the iOS 12, tvOS 12, watchOS 5, macOS 10.14, or bridgeOS 3 (or newer) SDKs
//  } else {
//      Old behaviour
//  }

// In cases where more precise control is required (such as APIs that were added to varions platforms in different years)
// the os specific values may be used instead. Unlike the version set constants, the platform specific ones will only ever
// return true if the running binary is the platform being testsed, allowing conditions to be built for specific platforms
// and releases that came out at different times. For example:

//  if (dyld_program_sdk_at_least(dyld_platform_version_iOS_12_0)
//      || dyld_program_sdk_at_least(dyld_platform_version_watchOS_6_0)) {
//      New behaviour for programs built against the iOS 12 (fall 2018), watchOS 6 (fall 2019) (or newer) SDKs
//  } else {
//      Old behaviour all other platforms, as well as older iOSes and watchOSes
//  }

extern dyld_platform_t dyld_get_base_platform(dyld_platform_t platform) __API_AVAILABLE(macos(10.14), ios(12.0), watchos(5.0), tvos(12.0));

// SPI to ask if a platform is a simulation platform
extern bool dyld_is_simulator_platform(dyld_platform_t platform) __API_AVAILABLE(macos(10.14), ios(12.0), watchos(5.0), tvos(12.0));

// Takes a version and returns if the image was built againt that SDK or newer
// In the case of multi_plaform mach-o's it tests against the active platform
extern bool dyld_sdk_at_least(const struct mach_header* mh, dyld_build_version_t version) __API_AVAILABLE(macos(10.14), ios(12.0), watchos(5.0), tvos(12.0));

// Takes a version and returns if the image was built with that minos version or newer
// In the case of multi_plaform mach-o's it tests against the active platform
extern bool dyld_minos_at_least(const struct mach_header* mh, dyld_build_version_t version) __API_AVAILABLE(macos(10.14), ios(12.0), watchos(5.0), tvos(12.0));

// Convenience versions of the previous two functions that run against the the main executable
extern bool dyld_program_sdk_at_least(dyld_build_version_t version) __API_AVAILABLE(macos(10.14), ios(12.0), watchos(5.0), tvos(12.0));
extern bool dyld_program_minos_at_least(dyld_build_version_t version) __API_AVAILABLE(macos(10.14), ios(12.0), watchos(5.0), tvos(12.0));

// Function that walks through the load commands and calls the internal block for every version found
// Intended as a fallback for very complex (and rare) version checks, or for tools that need to
// print our everything for diagnostic reasons
extern void dyld_get_image_versions(const struct mach_header* mh, void (^callback)(dyld_platform_t platform, uint32_t sdk_version, uint32_t min_version)) __API_AVAILABLE(macos(10.14), ios(12.0), watchos(5.0), tvos(12.0));

// Convienence constants for dyld version SPIs.

// Because we now have so many different OSes with different versions these version set values are intended to
// to provide a more convenient way to version check. They may be used instead of platform specific version in
// dyld_sdk_at_least(), dyld_minos_at_least(), dyld_program_sdk_at_least(), and dyld_program_minos_at_least().
// Since they are references into a lookup table they MUST NOT be used by any code that does not ship as part of
// the OS, as the values may change and the tables in older OSes may not have the necessary values for back
// deployed binaries. These values are future proof against new platforms being added, and any checks against
// platforms that did not exist at the epoch of a version set will return true since all versions of that platform
// are inherently newer.

//@VERSION_DEFS@

//
// This finds the SDK version a binary was built against.
// Returns zero on error, or if SDK version could not be determined.
//
// Exists in Mac OS X 10.8 and later 
// Exists in iOS 6.0 and later
extern uint32_t dyld_get_sdk_version(const struct mach_header* mh);


//
// This finds the SDK version that the main executable was built against.
// Returns zero on error, or if SDK version could not be determined.
//
// Note on watchOS, this returns the equivalent iOS SDK version number
// (i.e an app built against watchOS 2.0 SDK returne 9.0).  To see the
// platform specific sdk version use dyld_get_program_sdk_watch_os_version().
//
// Exists in Mac OS X 10.8 and later 
// Exists in iOS 6.0 and later
extern uint32_t dyld_get_program_sdk_version(void);

#if TARGET_OS_WATCH
// watchOS only.
// This finds the Watch OS SDK version that the main executable was built against.
// Exists in Watch OS 2.0 and later
extern uint32_t dyld_get_program_sdk_watch_os_version(void) __API_AVAILABLE(watchos(2.0));


// watchOS only.
// This finds the Watch min OS version that the main executable was built to run on.
// Note: dyld_get_program_min_os_version() returns the iOS equivalent (e.g. 9.0)
//       whereas this returns the raw watchOS version (e.g. 2.0).
// Exists in Watch OS 3.0 and later
extern uint32_t dyld_get_program_min_watch_os_version(void) __API_AVAILABLE(watchos(3.0));
#endif

#if TARGET_OS_BRIDGE
// bridgeOS only.
// This finds the bridgeOS SDK version that the main executable was built against.
// Exists in bridgeOSOS 2.0 and later
extern uint32_t dyld_get_program_sdk_bridge_os_version(void) __API_AVAILABLE(bridgeos(2.0));

// bridgeOS only.
// This finds the Watch min OS version that the main executable was built to run on.
// Note: dyld_get_program_min_os_version() returns the iOS equivalent (e.g. 9.0)
//       whereas this returns the raw bridgeOS version (e.g. 2.0).
// Exists in bridgeOS 2.0 and later
extern uint32_t dyld_get_program_min_bridge_os_version(void) __API_AVAILABLE(bridgeos(2.0));
#endif

//
// This finds the min OS version a binary was built to run on.
// Returns zero on error, or if no min OS recorded in binary.
//
// Exists in Mac OS X 10.8 and later 
// Exists in iOS 6.0 and later
extern uint32_t dyld_get_min_os_version(const struct mach_header* mh);


//
// This finds the min OS version the main executable was built to run on.
// Returns zero on error, or if no min OS recorded in binary.
//
// Exists in Mac OS X 10.8 and later 
// Exists in iOS 6.0 and later
extern uint32_t dyld_get_program_min_os_version(void);




//
// Returns true if any OS dylib has overridden its copy in the shared cache
// Returns false for iOS unzippered twins in the shared cache overriding
// their macOS counterpart in catalyst mode.
//
// Exists in iPhoneOS 3.1 and later 
// Exists in Mac OS X 10.10 and later
extern bool dyld_shared_cache_some_image_overridden(void);


	
//
// Returns if the process is setuid or is code signed with entitlements.
// NOTE: It is safe to call this prior to malloc being initialized.  This function
// is guaranteed to not call malloc, or depend on its state.
//
// Exists in Mac OS X 10.9 and later
extern bool dyld_process_is_restricted(void);



//
// Returns path used by dyld for standard dyld shared cache file for the current arch.
//
// Exists in Mac OS X 10.11 and later
extern const char* dyld_shared_cache_file_path(void);



//
// Returns if there are any inserted (via DYLD_INSERT_LIBRARIES) or interposing libraries.
//
// Exists in Mac OS X 10.15 and later
extern bool dyld_has_inserted_or_interposing_libraries(void);

//
// Return true if dyld contains a fix for a specific identifier. Intended for staging breaking SPI
// changes
//
// Exists in macOS 10.16, iOS 14, tvOS14, watchOS 7 and later

extern bool _dyld_has_fix_for_radar(const char *rdar);


//
// <rdar://problem/13820686> for OpenGL to tell dyld it is ok to deallocate a memory based image when done.
//
// Exists in Mac OS X 10.9 and later
#define NSLINKMODULE_OPTION_CAN_UNLOAD                  0x20


//
// Update all bindings on specified image. 
// Looks for uses of 'replacement' and changes it to 'replacee'.
// NOTE: this is less safe than using static interposing via DYLD_INSERT_LIBRARIES
// because the running program may have already copy the pointer values to other
// locations that dyld does not know about.
//
struct dyld_interpose_tuple {
	const void* replacement;
	const void* replacee;
};
extern void dyld_dynamic_interpose(const struct mach_header* mh, const struct dyld_interpose_tuple array[], size_t count);


struct dyld_shared_cache_dylib_text_info {
	uint64_t		version;		// current version 2
	// following fields all exist in version 1
	uint64_t		loadAddressUnslid;
	uint64_t		textSegmentSize; 
	uuid_t			dylibUuid;
	const char*		path;			// pointer invalid at end of iterations
	// following fields all exist in version 2
	uint64_t        textSegmentOffset;  // offset from start of cache
};
typedef struct dyld_shared_cache_dylib_text_info dyld_shared_cache_dylib_text_info;


#ifdef __BLOCKS__
//
// Given the UUID of a dyld shared cache file, this function will attempt to locate the cache
// file and if found iterate all images, returning info about each one.  Returns 0 on success.
//
// Exists in Mac OS X 10.11 and later
//           iOS 9.0 and later
extern int dyld_shared_cache_iterate_text(const uuid_t cacheUuid, void (^callback)(const dyld_shared_cache_dylib_text_info* info));


//
// Given the UUID of a dyld shared cache file, and a NULL terminated array of extra directory paths to search,
// this function will scan the standard and extra directories looking for a cache file that matches the UUID
// and if found iterate all images, returning info about each one.  Returns 0 on success.
//
// Exists in Mac OS X 10.12 and later
//           iOS 10.0 and later
extern int dyld_shared_cache_find_iterate_text(const uuid_t cacheUuid, const char* extraSearchDirs[], void (^callback)(const dyld_shared_cache_dylib_text_info* info));
#endif /* __BLOCKS */


//
// Returns if the specified address range is in a dyld owned memory
// that is mapped read-only and will never be unloaded.
//
// Exists in Mac OS X 10.12 and later
//           iOS 10.0 and later
extern bool _dyld_is_memory_immutable(const void* addr, size_t length);


//
// Finds the UUID (from LC_UUID load command) of given image.
// Returns false if LC_UUID is missing or mach_header is malformed.
//
// Exists in Mac OS X 10.12 and later
// Exists in iOS 10.0 and later
extern bool _dyld_get_image_uuid(const struct mach_header* mh, uuid_t uuid);


//
// Gets the UUID of the dyld shared cache in the current process.
// Returns false if there is no dyld shared cache in use by the processes.
//
// Exists in Mac OS X 10.12 and later
// Exists in iOS 10.0 and later
extern bool _dyld_get_shared_cache_uuid(uuid_t uuid);


//
// Returns the start address of the dyld cache in the process and sets length to the size of the cache.
// Returns NULL if the process is not using a dyld shared cache
//
// Exists in Mac OS X 10.13 and later
// Exists in iOS 11.0 and later
extern const void* _dyld_get_shared_cache_range(size_t* length);


//
// Returns if the currently active dyld shared cache is optimized.
// Note: macOS does not use optimized caches and will always return false.
//
// Exists in Mac OS X 10.15 and later
// Exists in iOS 13.0 and later
extern bool _dyld_shared_cache_optimized(void);


//
// Returns if the currently active dyld shared cache was built locally.
//
// Exists in Mac OS X 10.15 and later
// Exists in iOS 13.0 and later
extern bool _dyld_shared_cache_is_locally_built(void);

//
// Returns if the given app needs a closure built.
//
// Exists in Mac OS X 10.15 and later
// Exists in iOS 13.0 and later
extern bool dyld_need_closure(const char* execPath, const char* dataContainerRootDir);


struct dyld_image_uuid_offset {
    uuid_t                      uuid;
	uint64_t                    offsetInImage;
    const struct mach_header*   image;
};

//
// Given an array of addresses, returns info about each address.
// Common usage is the array or addresses was produced by a stack backtrace.
// For each address, returns the where that image was loaded, the offset
// of the address in the image, and the image's uuid.  If a specified
// address is unknown to dyld, all fields will be returned a zeros.
//
// Exists in macOS 10.14 and later
// Exists in iOS 12.0 and later
extern void _dyld_images_for_addresses(unsigned count, const void* addresses[], struct dyld_image_uuid_offset infos[]);


//
// Lets you register a callback which is called each time an image is loaded and provides the mach_header*, path, and
// whether the image may be unloaded later.  During the call to _dyld_register_for_image_loads(), the callback is called
// once for each image currently loaded.
//
// Exists in macOS 10.14 and later
// Exists in iOS 12.0 and later
extern void _dyld_register_for_image_loads(void (*func)(const struct mach_header* mh, const char* path, bool unloadable));




//
// Lets you register a callback which is called for bulk notifications of images loaded. During the call to
// _dyld_register_for_bulk_image_loads(), the callback is called once with all images currently loaded.
// Then later during dlopen() the callback is called once with all newly images.
//
// Exists in macOS 10.15 and later
// Exists in iOS 13.0 and later
extern void _dyld_register_for_bulk_image_loads(void (*func)(unsigned imageCount, const struct mach_header* mhs[], const char* paths[]));


//
// DriverKit main executables do not have an LC_MAIN.  Instead DriverKit.framework's initializer calls
// _dyld_register_driverkit_main() with a function pointer that dyld should call into instead
// of using LC_MAIN.
//
extern void _dyld_register_driverkit_main(void (*mainFunc)(void));


//
// This is similar to _dyld_shared_cache_contains_path(), except that it returns the canonical
// shared cache path for the given path.
//
// Exists in macOS 10.16 and later
// Exists in iOS 14.0 and later
extern const char* _dyld_shared_cache_real_path(const char* path);


//
// Dyld has a number of modes. This function returns the mode for the current process.
// dyld2 is the classic "interpreter" way to run.
// dyld3 runs by compiling down and caching what dyld needs to do into a "closure".
//
// Exists in macOS 10.16 and later
// Exists in iOS 14.0 and later
//
#define DYLD_LAUNCH_MODE_USING_CLOSURE               0x00000001     // dyld4: 0 => main is JITLoader, 1=> main is PrebuiltLoader
#define DYLD_LAUNCH_MODE_BUILT_CLOSURE_AT_LAUNCH     0x00000002     // dyld4: currently unused
#define DYLD_LAUNCH_MODE_CLOSURE_SAVED_TO_FILE       0x00000004     // dyld4: built and wrote PrebuiltLoaderSet to disk
#define DYLD_LAUNCH_MODE_CLOSURE_FROM_OS             0x00000008     // dyld4: PrebuiltLoaderSet used was built into dyld cache
#define DYLD_LAUNCH_MODE_MINIMAL_CLOSURE             0x00000010     // dyld4: unused
#define DYLD_LAUNCH_MODE_HAS_INTERPOSING             0x00000020     // dyld4: process has interposed symbols
#define DYLD_LAUNCH_MODE_OPTIMIZED_DYLD_CACHE        0x00000040     // dyld4: dyld shared cache is optimized (stubs eliminated)
extern uint32_t _dyld_launch_mode(void);


//
// When dyld must terminate a process because of a required dependent dylib
// could not be loaded or a symbol is missing, dyld calls abort_with_reason()
// using one of the following error codes.
//
#define DYLD_EXIT_REASON_DYLIB_MISSING          1
#define DYLD_EXIT_REASON_DYLIB_WRONG_ARCH       2
#define DYLD_EXIT_REASON_DYLIB_WRONG_VERSION    3
#define DYLD_EXIT_REASON_SYMBOL_MISSING         4
#define DYLD_EXIT_REASON_CODE_SIGNATURE         5
#define DYLD_EXIT_REASON_FILE_SYSTEM_SANDBOX    6
#define DYLD_EXIT_REASON_MALFORMED_MACHO        7
#define DYLD_EXIT_REASON_OTHER                  9

//
// When it has more information about the termination, dyld will use abort_with_payload().
// The payload is a dyld_abort_payload structure.  The fixed fields are offsets into the
// payload for the corresponding string.  If the offset is zero, that string is not available.
//
struct dyld_abort_payload {
	uint32_t version;                   // first version is 1
	uint32_t flags;                     // 0x00000001 means dyld terminated at launch, backtrace not useful
	uint32_t targetDylibPathOffset;     // offset in payload of path string to dylib that could not be loaded
	uint32_t clientPathOffset;          // offset in payload of path string to image requesting dylib
	uint32_t symbolOffset;              // offset in payload of symbol string that could not be found
	// string data
};
typedef struct dyld_abort_payload dyld_abort_payload;


// These global variables are implemented in libdyld.dylib
// Old programs that used crt1.o also defined these globals.
// The ones in dyld are not used when an old program is run.
extern int          NXArgc;
extern const char** NXArgv;
extern       char** environ;       // POSIX says this not const, because it pre-dates const
extern const char*  __progname;


// called by libSystem_initializer only
extern void _dyld_initializer(void);

// never called from source code. Used by static linker to implement lazy binding
extern void dyld_stub_binder(void) __asm__("dyld_stub_binder");

// never call from source code.  Used by closure builder to bind missing lazy symbols to
extern void _dyld_missing_symbol_abort(void);

// Called only by objc to see if dyld has uniqued this selector.
// Returns the value if dyld has uniqued it, or nullptr if it has not.
// Note, this function must be called after _dyld_objc_notify_register.
//
// Exists in Mac OS X 10.15 and later
// Exists in iOS 13.0 and later
extern const char* _dyld_get_objc_selector(const char* selName);


// Called only by objc to see if dyld has pre-optimized classes with this name.
// The callback will be called once for each class with the given name where
// isLoaded is true if that class is in a binary which has been previously passed
// to the objc load notifier.
// Note you can set stop to true to stop iterating.
// Also note, this function must be called after _dyld_objc_notify_register.
//
// Exists in Mac OS X 10.15 and later
// Exists in iOS 13.0 and later
extern void _dyld_for_each_objc_class(const char* className,
                                      void (^callback)(void* classPtr, bool isLoaded, bool* stop));


// Called only by objc to see if dyld has pre-optimized protocols with this name.
// The callback will be called once for each protocol with the given name where
// isLoaded is true if that protocol is in a binary which has been previously passed
// to the objc load notifier.
// Note you can set stop to true to stop iterating.
// Also note, this function must be called after _dyld_objc_notify_register.
//
// Exists in Mac OS X 10.15 and later
// Exists in iOS 13.0 and later
extern void _dyld_for_each_objc_protocol(const char* protocolName,
                                         void (^callback)(void* protocolPtr, bool isLoaded, bool* stop));

// Called only by lldb to visit every objc Class in the shared cache hash table
//
// Exists in Mac OS X 12.0 and later
// Exists in iOS 15.0 and later
extern void _dyld_visit_objc_classes(void (^callback)(const void* classPtr));

// Called only by libobjc to get the number of classes in the shared cache hash table
//
// Exists in Mac OS X 12.0 and later
// Exists in iOS 15.0 and later
extern uint32_t _dyld_objc_class_count(void);

// Called only by libobjc to check if relative method lists are the new large caches format
//
// Exists in Mac OS X 12.0 and later
// Exists in iOS 15.0 and later
extern bool _dyld_objc_uses_large_shared_cache(void);


enum _dyld_protocol_conformance_result_kind {
  _dyld_protocol_conformance_result_kind_found_descriptor,
  _dyld_protocol_conformance_result_kind_found_witness_table,
  _dyld_protocol_conformance_result_kind_not_found,
  _dyld_protocol_conformance_result_kind_definitive_failure
  // Unknown values will be considered to be a non-definitive failure, so we can
  // add more response kinds later if needed without a synchronized submission.
};

struct _dyld_protocol_conformance_result {
    // Note this is really a _dyld_protocol_conformance_result_kind in disguise
    uintptr_t kind;

    // Contains a ProtocolConformanceDescriptor iff `kind` is _dyld_protocol_conformance_result_kind_found_descriptor
    // Contains a WitnessTable iff `kind` is _dyld_protocol_conformance_result_kind_found_witness_table
    const void *value;
};

// Called only by Swift to see if dyld has pre-optimized protocol conformances for the given
// protocolDescriptor/metadataType and typeDescriptor.
//
// Exists in Mac OS X 12.0 and later
// Exists in iOS 15.0 and later
extern struct _dyld_protocol_conformance_result
_dyld_find_protocol_conformance(const void *protocolDescriptor,
                                const void *metadataType,
                                const void *typeDescriptor);

// Called only by Swift to see if dyld has pre-optimized protocol conformances for the given
// foreign type descriptor name and protocol
//
// Exists in Mac OS X 12.0 and later
// Exists in iOS 15.0 and later
extern struct _dyld_protocol_conformance_result
_dyld_find_foreign_type_protocol_conformance(const void *protocol,
                                             const char *foreignTypeIdentityStart,
                                             size_t foreignTypeIdentityLength);

// Called only by Swift to check what version of the optimizations are available.
//
// Exists in Mac OS X 12.0 and later
// Exists in iOS 15.0 and later
// Exists in watchOS 8.0 and later
// Exists in tvOS 15.0 and later.

extern uint32_t _dyld_swift_optimizations_version(void) __API_AVAILABLE(macos(12.0), ios(15.0), watchos(8.0), tvos(15.0));

// Swift uses this define to guard for the above symbol being available at build time
#define DYLD_FIND_PROTOCOL_CONFORMANCE_DEFINED 1

// Called only by Swift to check if dyld has pre-optimized protocol conformances in the closure
// for the given on-disk mach_header containing a __swift5_proto section
//
// Exists in Mac OS X 13.0 and later
// Exists in iOS 16.0 and later
extern bool _dyld_has_preoptimized_swift_protocol_conformances(const struct mach_header* mh);

// Called only by Swift to see if dyld has pre-optimized protocol conformances for the given
// protocolDescriptor/metadataType and typeDescriptor in the closure on disk.
//
// Exists in Mac OS X 13.0 and later
// Exists in iOS 16.0 and later
extern struct _dyld_protocol_conformance_result
_dyld_find_protocol_conformance_on_disk(const void *protocolDescriptor,
                                        const void *metadataType,
                                        const void *typeDescriptor,
                                        uint32_t flags);

// Called only by Swift to see if dyld has pre-optimized protocol conformances for the given
// foreign type descriptor name and protocol in the closure on disk.
//
// Exists in Mac OS X 13.0 and later
// Exists in iOS 16.0 and later
extern struct _dyld_protocol_conformance_result
_dyld_find_foreign_type_protocol_conformance_on_disk(const void *protocol,
                                                     const char *foreignTypeIdentityStart,
                                                     size_t foreignTypeIdentityLength,
                                                     uint32_t flags);

// Swift uses this define to guard for the above symbols being available at build time
#define DYLD_FIND_PROTOCOL_ON_DISK_CONFORMANCE_DEFINED 1

// called by exit() before it calls cxa_finalize() so that thread_local
// objects are destroyed before global objects.
extern void _tlv_exit(void);

typedef enum {
    dyld_objc_string_kind
} DyldObjCConstantKind;

// CF constants such as CFString's can be moved in to a contiguous range of
// shared cache memory.  This returns true if the given pointer is to an object of
// the given kind.
//
// Exists in Mac OS X 10.16 and later
// Exists in iOS 14.0 and later
extern bool _dyld_is_objc_constant(DyldObjCConstantKind kind, const void* addr);


// temp exports to keep tapi happy, until ASan stops using dyldVersionNumber
extern double      dyldVersionNumber;
extern const char* dyldVersionString;

// True if dyld told objc to patch classes
extern uint8_t dyld_process_has_objc_patches;

// Symbol flags type for symbols defined via the pseudo-dylibs APIs.
typedef uint64_t _dyld_pseudodylib_symbol_flags;

// Flag values for _dyld_pseudodylib_symbol_flags.
#define DYLD_PSEUDODYLIB_SYMBOL_FLAGS_NONE 0
#define DYLD_PSEUDODYLIB_SYMBOL_FLAGS_FOUND 1
#define DYLD_PSEUDODYLIB_SYMBOL_FLAGS_WEAK_DEF 2
#define DYLD_PSEUDODYLIB_SYMBOL_FLAGS_CALLABLE 4

typedef void (*_dyld_pseudodylib_dispose_error_message)(char *err_msg);
typedef char* (*_dyld_pseudodylib_initialize)(void* pd_ctx, const void* mh);
typedef char* (*_dyld_pseudodylib_deinitialize)(void* pd_ctx, const void* mh);
typedef char* (*_dyld_pseudodylib_lookup_symbols)(void* pd_ctx, const void* mh, const char *names[], size_t num_names,
                                                   void* addrs[], _dyld_pseudodylib_symbol_flags flags[]);
typedef int (*_dyld_pseudodylib_lookup_address)(void* pd_ctx, const void* mh, const void* addr, struct dl_info* dl);
typedef char* (*_dyld_pseudodylib_find_unwind_sections)(void* pd_ctx, const void* mh, const void* addr, bool* found, struct dyld_unwind_sections* info);

// Versioned struct to hold pseudo-dylib callbacks.
// See _dyld_pseudodylib_callbacks_v1.
struct _dyld_pseudodylib_callbacks {
    uintptr_t version;
};

// Callbacks to implement pseudo-dylib behavior.
//
// dispose_error_message will be called to destroy error messages returned by the other callbacks.
// initialize will be called by dlopen to run initializers in the pseudo-dylib.
// deinitialize will be called by dlclose to run deinitializers.
// lookup_symbols will be called to find the address of symbols defined by the pseudo-dylib (e.g. by dlsym).
// lookup_address will be called by dladdr to find information about the given address.
// find_unwind_sections will be called by _dyld_find_unwind_sections.
struct _dyld_pseudodylib_callbacks_v1 {
    uintptr_t version; // == 1
    _dyld_pseudodylib_dispose_error_message dispose_error_message;
    _dyld_pseudodylib_initialize initialize;
    _dyld_pseudodylib_deinitialize deinitialize;
    _dyld_pseudodylib_lookup_symbols lookup_symbols;
    _dyld_pseudodylib_lookup_address lookup_address;
    _dyld_pseudodylib_find_unwind_sections find_unwind_sections;
};

typedef struct _dyld_pseudodylib_callbacks_opaque*
    _dyld_pseudodylib_callbacks_handle;
typedef struct _dyld_pseudodylib_opaque* _dyld_pseudodylib_handle;

// pseudo-dylib registration SPIs.
//
// These APIs can be used to register "pseudo-dylibs" which present as dylibs when accessed via the dlfcn.h functions
// (dlopen, dlclose, dladdr, dlsym), but are backed by a set of callbacks rather than a full mach-o image.
//
// _dyld_pseudodylib_register_callbacks is used to register a set of callbacks that can be shared between multiple
// pseudo-dylibs. On success, _dyld_pseudodylib_register_callbacks will return a handle that can be used in calls
// to register pseudo-dylib instances (see _dyld_pseudodylib_register below). On failure it will return null.
// Registered callbacks should be deregistered by calling _dyld_pseudodylib_deregister_callbacks once all pseudo-dylibs
// using the callbacks have been deregistered.
//
// _dyld_pseudodylib_register is used to register an instance of a pseudo-dylib. This can be thought of as equivalent
// to creating a dylib on disk: the pseudo-dylib is not yet open, but can be found via its install-name by dlopen.
// Registration takes the address range that the pseudo-dylib can occupy, and this range must start with a valid mach
// header and load commands containing, at minimum, an LC_VERSION_MIN and LC_ID_DYLIB command identifying the pseudo-dylib's
// install name. The callbacks argument identifies the set of callbacks to use for this pseudo-dylib instance, and the
// opaque context pointer will be passed to each of these callbacks. Once a pseduo-dylib is no longer needed it should be
// deregistered by calling _dyld_pseudodylib_deregister (equivalent to "rm'ing" a dylib on disk).
//
// Exists in Mac OS X 14.0 and later
// Exists in iOS 17.0 and later
extern _dyld_pseudodylib_callbacks_handle _dyld_pseudodylib_register_callbacks(const struct _dyld_pseudodylib_callbacks* callbacks);
extern void _dyld_pseudodylib_deregister_callbacks(_dyld_pseudodylib_callbacks_handle callbacks_handle);
extern _dyld_pseudodylib_handle _dyld_pseudodylib_register(
    void* addr, size_t size, _dyld_pseudodylib_callbacks_handle callbacks_handle, void* context);
extern void _dyld_pseudodylib_deregister(_dyld_pseudodylib_handle pd_handle);


// Called only by libobjc to check if dyld has loaded the image described by imageID, that contains pre-optimized categories
// The imageID parameter is a private interface between dyld and libobjc, and no assumption should be made about its value.
// Exists in Mac OS X 14.0 and later
// Exists in iOS 17.0 and later
extern bool _dyld_is_preoptimized_objc_image_loaded(uint16_t imageID);

// Called only by libobjc to access RW objc header information from the shared cache
// Exists in Mac OS X 14.0 and later
// Exists in iOS 17.0 and later
extern void* _dyld_for_objc_header_opt_rw();

// Called only by libobjc to access RO objc header information from the shared cache
// Exists in Mac OS X 14.0 and later
// Exists in iOS 17.0 and later
extern const void* _dyld_for_objc_header_opt_ro();
#if __cplusplus
}
#endif /* __cplusplus */


#ifndef DYLD_IOS_VERSION_11_0
#define DYLD_IOS_VERSION_11_0 0x000B0000
#endif

#ifndef DYLD_IOS_VERSION_11_3
#define DYLD_IOS_VERSION_11_3 0x000B0300
#endif

#ifndef DYLD_IOS_VERSION_12_0
#define DYLD_IOS_VERSION_12_0 0x000C0000
#endif

#ifndef DYLD_IOS_VERSION_12_2
#define DYLD_IOS_VERSION_12_2 0x000C0200
#endif

#ifndef DYLD_IOS_VERSION_13_0
#define DYLD_IOS_VERSION_13_0 0x000D0000
#endif

#ifndef DYLD_IOS_VERSION_13_2
#define DYLD_IOS_VERSION_13_2 0x000D0200
#endif

#ifndef DYLD_IOS_VERSION_13_4
#define DYLD_IOS_VERSION_13_4 0x000D0400
#endif

#ifndef DYLD_IOS_VERSION_14_0
#define DYLD_IOS_VERSION_14_0 0x000E0000
#endif

#ifndef DYLD_IOS_VERSION_14_2
#define DYLD_IOS_VERSION_14_2 0x000E0200
#endif

#ifndef DYLD_IOS_VERSION_14_5
#define DYLD_IOS_VERSION_14_5 0x000E0500
#endif

#ifndef DYLD_IOS_VERSION_15_0
#define DYLD_IOS_VERSION_15_0 0x000f0000
#endif

#ifndef DYLD_IOS_VERSION_15_4
#define DYLD_IOS_VERSION_15_4 0x000f0400
#endif

#ifndef DYLD_IOS_VERSION_16_0
#define DYLD_IOS_VERSION_16_0 0x00100000
#endif

#ifndef DYLD_IOS_VERSION_16_4
#define DYLD_IOS_VERSION_16_4 0x00100400
#endif

#ifndef DYLD_IOS_VERSION_17_0
#define DYLD_IOS_VERSION_17_0 0x00110000
#endif

#ifndef DYLD_IOS_VERSION_17_2
#define DYLD_IOS_VERSION_17_2 0x00110200
#endif

#ifndef DYLD_MACOSX_VERSION_10_13
#define DYLD_MACOSX_VERSION_10_13 0x000A0D00
#endif

#ifndef DYLD_MACOSX_VERSION_10_14
#define DYLD_MACOSX_VERSION_10_14 0x000A0E00
#endif

#ifndef DYLD_MACOSX_VERSION_10_15
#define DYLD_MACOSX_VERSION_10_15 0x000A0F00
#endif

#ifndef DYLD_MACOSX_VERSION_10_15_1
#define DYLD_MACOSX_VERSION_10_15_1 0x000A0F01
#endif

#ifndef DYLD_MACOSX_VERSION_10_15_4
#define DYLD_MACOSX_VERSION_10_15_4 0x000A0F04
#endif

#ifndef DYLD_MACOSX_VERSION_10_16
#define DYLD_MACOSX_VERSION_10_16 0x000A1000
#endif

#ifndef DYLD_MACOSX_VERSION_11_3
#define DYLD_MACOSX_VERSION_11_3 0x000B0300
#endif

#ifndef DYLD_MACOSX_VERSION_12_00
#define DYLD_MACOSX_VERSION_12_00 0x000c0000
#endif

#ifndef DYLD_MACOSX_VERSION_12_3
#define DYLD_MACOSX_VERSION_12_3 0x000c0300
#endif

#ifndef DYLD_MACOSX_VERSION_13_0
#define DYLD_MACOSX_VERSION_13_0 0x000d0000
#endif

#ifndef DYLD_MACOSX_VERSION_13_3
#define DYLD_MACOSX_VERSION_13_3 0x000d0300
#endif

#ifndef DYLD_MACOSX_VERSION_14_0
#define DYLD_MACOSX_VERSION_14_0 0x000e0000
#endif

#ifndef DYLD_MACOSX_VERSION_14_2
#define DYLD_MACOSX_VERSION_14_2 0x000e0200
#endif


#endif /* _MACH_O_DYLD_PRIV_H_ */
