#ifndef _SANDBOX_PRIVATE_H_
#define _SANDBOX_PRIVATE_H_

#include <sandbox.h>

__BEGIN_DECLS


/* The following flags are reserved for Mac OS X.  Developers should not
 * depend on their availability.
 */

/*
 * @define SANDBOX_NAMED_BUILTIN   The `profile' argument specifies the
 * name of a builtin profile that is statically compiled into the
 * system.
 */
#define SANDBOX_NAMED_BUILTIN	0x0002

/*
 * @define SANDBOX_NAMED_EXTERNAL   The `profile' argument specifies the
 * pathname of a Sandbox profile.  The pathname may be abbreviated: If
 * the name does not start with a `/' it is treated as relative to
 * /usr/share/sandbox and a `.sb' suffix is appended.
 */
#define SANDBOX_NAMED_EXTERNAL	0x0003

/*
 * @define SANDBOX_NAMED_MASK   Mask for name types: 4 bits, 15 possible
 * name types, 3 currently defined.
 */
#define SANDBOX_NAMED_MASK	0x000f


/* The following definitions are reserved for Mac OS X.  Developers should not
 * depend on their availability.
 */

int sandbox_init_with_parameters(const char *profile, uint64_t flags, const char *const parameters[], char **errorbuf);

int sandbox_init_with_extensions(const char *profile, uint64_t flags, const char *const extensions[], char **errorbuf);

enum sandbox_filter_type {
	SANDBOX_FILTER_NONE,
	SANDBOX_FILTER_PATH,
	SANDBOX_FILTER_GLOBAL_NAME,
	SANDBOX_FILTER_LOCAL_NAME,
	SANDBOX_FILTER_APPLEEVENT_DESTINATION,
	SANDBOX_FILTER_RIGHT_NAME,
	SANDBOX_FILTER_KEXT_BUNDLE_ID,
};

extern const enum sandbox_filter_type SANDBOX_CHECK_NO_REPORT __attribute__((weak_import));

enum sandbox_extension_flags {
	FS_EXT_DEFAULTS =              0,
	FS_EXT_FOR_PATH =       (1 << 0),
	FS_EXT_FOR_FILE =       (1 << 1),
	FS_EXT_READ =           (1 << 2),
	FS_EXT_WRITE =          (1 << 3),
	FS_EXT_PREFER_FILEID =  (1 << 4),
};

int sandbox_check(pid_t pid, const char *operation, enum sandbox_filter_type type, ...);

int sandbox_note(const char *note);

int sandbox_suspend(pid_t pid);
int sandbox_unsuspend(void);

int sandbox_issue_extension(const char *path, char **ext_token);
int sandbox_issue_fs_extension(const char *path, uint64_t flags, char **ext_token);
int sandbox_issue_fs_rw_extension(const char *path, char **ext_token);
int sandbox_issue_mach_extension(const char *name, char **ext_token);

int sandbox_consume_extension(const char *path, const char *ext_token);
int sandbox_consume_fs_extension(const char *ext_token, char **path);
int sandbox_consume_mach_extension(const char *ext_token, char **name);

int sandbox_release_fs_extension(const char *ext_token);

int sandbox_container_path_for_pid(pid_t pid, char *buffer, size_t bufsize);

int sandbox_wakeup_daemon(char **errorbuf);

const char *_amkrtemp(const char *);

__END_DECLS

#endif /* _SANDBOX_H_ */
