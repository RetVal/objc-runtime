/*
 * Copyright (c) 1999-2003, 2005-2007 Apple Inc.  All Rights Reserved.
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
/*
 *	objc-errors.m
 * 	Copyright 1988-2001, NeXT Software, Inc., Apple Computer, Inc.
 */

#include <TargetConditionals.h>
#include <stdio.h>
#include <stdarg.h>

#include "objc-private.h"

mutex_t crashlog_lock;

crashreporter_annotations_t gCRAnnotations;

#if TARGET_OS_EXCLAVEKIT
static inline int getpid(void)
{
    return 1;
}

void _objc_inform_now_and_on_crash(const char *fmt, ...)
{
    va_list ap;
    char *buf;

    va_start(ap, fmt);
    _objc_vasprintf(&buf, fmt, ap);
    va_end(ap);
    printf("objc[%d]: %s\n", getpid(), buf);
    free(buf);
}

void __objc_error(id rcv, const char *fmt, ...)
{
    va_list ap;
    char *buf;

    va_start(ap, fmt);
    _objc_vasprintf(&buf, fmt, ap);
    va_end(ap);
    _objc_fatal("%s: %s", object_getClassName(rcv), buf);
}

void _objc_inform(const char *fmt, ...)
{
    va_list ap;
    char *buf;

    va_start(ap, fmt);
    _objc_vasprintf(&buf, fmt, ap);
    va_end(ap);
    printf("objc[%d]: %s\n", getpid(), buf);
    free(buf);
}

void _objc_fatal(const char *fmt, ...)
{
    va_list ap;
    char *buf;

    va_start(ap, fmt);
    _objc_vasprintf(&buf, fmt, ap);
    va_end(ap);
    printf("objc[%d]: %s\n", getpid(), buf);
    abort();
}

#else

#include <sandbox/private.h>
#include <_simple.h>

// Return true if c is a UTF8 continuation byte
static bool isUTF8Continuation(char c)
{
    return (c & 0xc0) == 0x80;  // continuation byte is 0b10xxxxxx
}

// Add "message" to any forthcoming crash log.
static void _objc_crashlog(const char *message)
{
    char *newmsg;

#if 0
    {
        // for debugging at BOOT time.
        extern char **_NSGetProgname(void);
        FILE *crashlog = fopen("/_objc_crash.log", "a");
        setbuf(crashlog, NULL);
        fprintf(crashlog, "[%s] %s\n", *_NSGetProgname(), message);
        fclose(crashlog);
        sync();
    }
#endif

    mutex_locker_t lock(crashlog_lock);

    char *oldmsg = (char *)CRGetCrashLogMessage();
    size_t oldlen;
    const size_t limit = 8000;

    if (!oldmsg) {
        newmsg = strdup(message);
    } else if ((oldlen = strlen(oldmsg)) > limit) {
        // limit total length by dropping old contents
        char *truncmsg = oldmsg + oldlen - limit;
        // advance past partial UTF-8 bytes
        while (isUTF8Continuation(*truncmsg)) truncmsg++;
        _objc_asprintf(&newmsg, "... %s\n%s", truncmsg, message);
    } else {
        _objc_asprintf(&newmsg, "%s\n%s", oldmsg, message);
    }

    if (newmsg) {
        // Strip trailing newline
        char *c = &newmsg[strlen(newmsg)-1];
        if (*c == '\n') *c = '\0';
        
        if (oldmsg) free(oldmsg);
        CRSetCrashLogMessage(newmsg);
    }
}

// Returns true if logs should be sent to stderr as well as syslog.
// Copied from CFUtilities.c
static bool also_do_stderr(void) 
{
    struct stat st;
    int ret = fstat(STDERR_FILENO, &st);
    if (ret < 0) return false;
    mode_t m = st.st_mode & S_IFMT;
    if (m == S_IFREG  ||  m == S_IFSOCK  ||  m == S_IFIFO  ||  m == S_IFCHR) {
        return true;
    }
    return false;
}

// Print "message" to the console.
static void _objc_syslog(const char *message)
{
    bool do_stderr = true;

    if (sandbox_check(getpid(), "network-outbound",
                      SANDBOX_FILTER_PATH, "/private/var/run/syslog")) {
        _simple_asl_log(ASL_LEVEL_ERR, nil, message);
        do_stderr = also_do_stderr();
    }

    if (do_stderr) {
        write(STDERR_FILENO, message, strlen(message));
    }
}

/*
 * _objc_error is the default *_error handler.
 */
__attribute__((noreturn, cold, format(printf, 2, 0)))
void _objc_error(id self, const char *fmt, va_list ap) 
{ 
    char *buf;
    _objc_vasprintf(&buf, fmt, ap);
    _objc_fatal("%s: %s", object_getClassName(self), buf);
}

/*
 * this routine handles errors that involve an object (or class).
 */
void __objc_error(id rcv, const char *fmt, ...) 
{ 
    va_list vp; 

    va_start(vp,fmt); 
    _objc_error (rcv, fmt, vp);  /* In case (*_error)() returns. */
    va_end(vp);
}

static __attribute__((noreturn, cold, format(printf, 3, 0)))
void _objc_fatalv(uint64_t reason, uint64_t flags, const char *fmt, va_list ap)
{
    char *buf1;
    _objc_vasprintf(&buf1, fmt, ap);

    char *buf2;
    _objc_asprintf(&buf2, "objc[%d]: %s\n", getpid(), buf1);
    _objc_syslog(buf2);

    if (DebugDontCrash) {
        char *buf3;
        _objc_asprintf(&buf3, "objc[%d]: HALTED\n", getpid());
        _objc_syslog(buf3);
        _Exit(1);
    }
    else {
        _objc_crashlog(buf1);
        abort_with_reason(OS_REASON_OBJC, reason, buf1, flags);
    }
}

void _objc_fatal_with_reason(uint64_t reason, uint64_t flags, 
                             const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    _objc_fatalv(reason, flags, fmt, ap);
}

void _objc_fatal(const char *fmt, ...)
{
    va_list ap; 
    va_start(ap,fmt); 
    _objc_fatalv(OBJC_EXIT_REASON_UNSPECIFIED, 
                 OS_REASON_FLAG_ONE_TIME_FAILURE, 
                 fmt, ap);
}

/*
 * this routine handles soft runtime errors...like not being able
 * add a category to a class (because it wasn't linked in).
 */
void _objc_inform(const char *fmt, ...)
{
    va_list ap; 
    char *buf1;
    char *buf2;

    va_start (ap,fmt); 
    _objc_vasprintf(&buf1, fmt, ap);
    va_end (ap);

    _objc_asprintf(&buf2, "objc[%d]: %s\n", getpid(), buf1);
    _objc_syslog(buf2);

    free(buf2);
    free(buf1);
}


/* 
 * Like _objc_inform(), but prints the message only in any 
 * forthcoming crash log, not to the console.
 */
void _objc_inform_on_crash(const char *fmt, ...)
{
    va_list ap; 
    char *buf1;
    char *buf2;

    va_start (ap,fmt); 
    _objc_vasprintf(&buf1, fmt, ap);
    va_end (ap);

    _objc_asprintf(&buf2, "objc[%d]: %s\n", getpid(), buf1);
    _objc_crashlog(buf2);

    free(buf2);
    free(buf1);
}


/* 
 * Like calling both _objc_inform and _objc_inform_on_crash.
 */
void _objc_inform_now_and_on_crash(const char *fmt, ...)
{
    va_list ap; 
    char *buf1;
    char *buf2;

    va_start (ap,fmt); 
    _objc_vasprintf(&buf1, fmt, ap);
    va_end (ap);

    _objc_asprintf(&buf2, "objc[%d]: %s\n", getpid(), buf1);
    _objc_crashlog(buf2);
    _objc_syslog(buf2);

    free(buf2);
    free(buf1);
}

#endif // !TARGET_OS_EXCLAVEKIT

BREAKPOINT_FUNCTION( 
    void _objc_warn_deprecated(void)
);

void _objc_inform_deprecated(const char *oldf, const char *newf)
{
    if (PrintDeprecation) {
        if (newf) {
            _objc_inform("The function %s is obsolete. Use %s instead. Set a breakpoint on _objc_warn_deprecated to find the culprit.", oldf, newf);
        } else {
            _objc_inform("The function %s is obsolete. Do not use it. Set a breakpoint on _objc_warn_deprecated to find the culprit.", oldf);
        }
    }
    _objc_warn_deprecated();
}
