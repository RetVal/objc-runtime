/*
 * Copyright (c) 1999-2007 Apple Inc.  All Rights Reserved.
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

/***********************************************************************
* objc-initialize.m
* +initialize support
**********************************************************************/

/***********************************************************************
 * Thread-safety during class initialization
 *
 * Initial state: CLS_INITIALIZING and CLS_INITIALIZED both clear. 
 * During initialization: CLS_INITIALIZING is set
 * After initialization: CLS_INITIALIZING clear and CLS_INITIALIZED set.
 * CLS_INITIALIZING and CLS_INITIALIZED are never set at the same time.
 * CLS_INITIALIZED is never cleared once set.
 *
 * Only one thread is allowed to actually initialize a class and send 
 * +initialize. Enforced by allowing only one thread to set CLS_INITIALIZING.
 *
 * Additionally, threads trying to send messages to a class must wait for 
 * +initialize to finish. During initialization of a class, that class's 
 * method cache is kept empty. objc_msgSend will revert to 
 * class_lookupMethodAndLoadCache, which checks CLS_INITIALIZED before 
 * messaging. If CLS_INITIALIZED is clear but CLS_INITIALIZING is set, 
 * the thread must block, unless it is the thread that started 
 * initializing the class in the first place. 
 *
 * Each thread keeps a list of classes it's initializing.
 *
 * Changes to `CLS_INITIALIZED` and `CLS_INITIALIZING` are synchronized using a
 * per-class recursive lock. This lock is obtained using
 * `_objc_sync_enter/exit_kind` with `SyncKind::classInitialize`.
 *
 * The lock is also used to wait on another thread that's performing
 * initialization. We don't really care which thread performs initialization, as
 * long as some thread does, so the first thread to successfully acquire the
 * lock will perform the initialization. Threads that need a class to be
 * initialized will acquire the lock. If they're the first one to acquire,
 * they'll see the class as not yet initialized, so they can begin the process.
 * If they're not first, they'll block on the lock until initialization is
 * complete, then acquire it, see the class as initialized, and immediately
 * return.
 *
 * Initialization must also be synchronized with changes to willInitializeFuncs.
 * A newly added function is immediately called with all existing initialized
 * classes, and is then called as new classes are initialized. We must not have
 * any races that result in classes being initialized simultaneously with a call
 * to _objc_addWillInitializeClassFunc being dropped or notified twice.
 *
 * To address this, we have classInitLock. This is held when locating all
 * existing initializing/initialized classes, and when adding a new function to
 * willInitializeFuncs. It's also acquired when marking a class as initializing.
 * This ensures that both parts see a consistent view of which classes are
 * initializing and which are not.
 *
 * Below is a diagram of the various execution paths. Each state in the diagram
 * lists which locks are held during that part of the process: 🔒 RL (runtime
 * lock), C (class-specific lock), IN (classInitLock).
 *
 * ┌──────────────────────────────────────┐
 * │       initializeAndMaybeRelock       │
 * │                🔒 RL                 │
 * └──────────────────────────────────────┘
 *   │
 *   │ Release runtime lock
 *   ∨
 * ┌──────────────────────────────────────┐
 * │        initializeNonMetaClass        │
 * └──────────────────────────────────────┘
 *   │
 *   │ Acquire class lock
 *   ∨
 * ┌──────────────────────────────────────┐        ┌───────────────────────────┐
 * │        Class is initialized?         │        │    Already waited for     │
 * │                🔒 C                  │  Yes   │    initializing thread    │
 * │                                      │ ─────> │           🔒 C            │
 * └──────────────────────────────────────┘        └───────────────────────────┘
 *   │                                               │
 *   │                                               │ Release class lock
 *   │ No                                            │ Acquire runtime lock
 *   │                                               ∨
 *   │                                             ┌───────────────────────────┐
 *   │                                             │          Return           │
 *   │                                             │          🔒 RL            │
 *   │                                             └───────────────────────────┘
 *   │                                               ∧
 *   │                                               │ Release class lock
 *   │                                               │ Acquire runtime lock
 *   ∨                                               │
 * ┌──────────────────────────────────────┐        ┌───────────────────────────┐
 * │        Class is initializing?        │  Yes   │ Re-entered initialization │
 * │                🔒 C                  │ ─────> │           🔒 C            │
 * └──────────────────────────────────────┘        └───────────────────────────┘
 *   │
 *   │ No
 *   ∨
 * ┌──────────────────────────────────────┐
 * │    We are the initializing thread    │
 * │                🔒 C                  │
 * └──────────────────────────────────────┘
 *   │
 *   │ Acquire classInitLock
 *   ∨
 * ┌──────────────────────────────────────┐
 * │         Set CLS_INITIALIZING         │
 * │              🔒 C, IN                │
 * └──────────────────────────────────────┘
 *   │
 *   │
 *   ∨
 * ┌──────────────────────────────────────┐
 * │       Copy willInitializeFuncs       │
 * │              🔒 C, IN                │
 * └──────────────────────────────────────┘
 *   │
 *   │ Release classInitLock
 *   ∨
 * ┌──────────────────────────────────────┐
 * │          Call funcs in copy          │
 * │        of willInitializeFuncs        │
 * │                🔒 C                  │
 * └──────────────────────────────────────┘
 *   │
 *   │
 *   ∨
 * ┌──────────────────────────────────────┐
 * │           Send +initialize           │
 * │                🔒 C                  │
 * └──────────────────────────────────────┘
 *   │
 *   │
 *   ∨
 * ┌──────────────────────────────────────┐        ┌───────────────────────────┐
 * │ Is superclass finished initializing? │  No    │ Add class to pending map  │
 * │                🔒 C                  │ ─────> │           🔒 C            │
 * └──────────────────────────────────────┘        └───────────────────────────┘
 *   │                                               │
 *   │ Yes                                           │
 *   ∨                                               ∨
 * ┌──────────────────────────────────────┐        ┌───────────────────────────┐
 * │         Set CLS_INITIALIZED          │        │   Keep class lock until   │
 * │                🔒 C                  │        │   superclass finishes!    │
 * │                                      │        │           🔒 C            │
 * └──────────────────────────────────────┘        └───────────────────────────┘
 *   │                                               │
 *   │ Release class lock                            │
 *   │ Acquire runtime lock                          │ Acquire runtime lock
 *   ∨                                               ∨
 * ┌──────────────────────────────────────┐        ┌───────────────────────────┐
 * │    Release pending subclass locks    │        │          Return           │
 * │                🔒 C                  │        │         🔒 C, RL          │
 * └──────────────────────────────────────┘        └───────────────────────────┘
 *   │
 *   │
 *   ∨
 * ┌──────────────────────────────────────┐
 * │                Return                │
 * │                🔒 RL                 │
 * └──────────────────────────────────────┘
 *
 *
 *
 *
 *
 *
 * ┌──────────────────────────────────────┐
 * │   _objc_addWillInitializeClassFunc   │
 * └──────────────────────────────────────┘
 *   │
 *   │ Acquire classInitLock
 *   ∨
 * ┌──────────────────────────────────────┐
 * │        Find all initializing         │
 * │       and initialized classes        │
 * │                🔒 IN                 │
 * └──────────────────────────────────────┘
 *   │
 *   │
 *   ∨
 * ┌──────────────────────────────────────┐
 * │           Add new func to            │
 * │         willInitializeFuncs          │
 * │                🔒 IN                 │
 * └──────────────────────────────────────┘
 *   │
 *   │ Release classInitLock
 *   ∨
 * ┌──────────────────────────────────────┐
 * │        Call new function with        │
 * │        existing initializing         │
 * │       and initialized classes        │
 * └──────────────────────────────────────┘
 **********************************************************************/

/***********************************************************************
 *  +initialize deadlock case when a class is marked initializing while 
 *  its superclass is initialized. Solved by completely initializing 
 *  superclasses before beginning to initialize a class.
 *
 *  OmniWeb class hierarchy:
 *                 OBObject 
 *                     |    ` OBPostLoader
 *                 OFObject
 *                 /     \
 *      OWAddressEntry  OWController
 *                        | 
 *                      OWConsoleController
 *
 *  Thread 1 (evil testing thread):
 *    initialize OWAddressEntry
 *    super init OFObject
 *    super init OBObject		     
 *    [OBObject initialize] runs OBPostLoader, which inits lots of classes...
 *    initialize OWConsoleController
 *    super init OWController - wait for Thread 2 to finish OWController init
 *
 *  Thread 2 (normal OmniWeb thread):
 *    initialize OWController
 *    super init OFObject - wait for Thread 1 to finish OFObject init
 *
 *  deadlock!
 *
 *  Solution: fully initialize super classes before beginning to initialize 
 *  a subclass. Then the initializing+initialized part of the class hierarchy
 *  will be a contiguous subtree starting at the root, so other threads 
 *  can't jump into the middle between two initializing classes, and we won't 
 *  get stuck while a superclass waits for its subclass which waits for the 
 *  superclass.
 **********************************************************************/

#include "objc-private.h"
#include "message.h"
#include "objc-initialize.h"
#include "objc-sync.h"
#include "DenseMapExtras.h"

/// classInitLock synchronizes changes to `CLS_INITIALIZING` with
/// `willInitializeClass` callbacks, to ensure each callback is called exactly
/// once for each class when adding a new callback concurrently with
/// initialization.
mutex_t classInitLock;


struct _objc_willInitializeClassCallback {
    _objc_func_willInitializeClass f;
    void *context;
};
static GlobalSmallVector<_objc_willInitializeClassCallback, 1> willInitializeFuncs;


/***********************************************************************
* struct _objc_initializing_classes
* Per-thread list of classes currently being initialized by that thread. 
* During initialization, that thread is allowed to send messages to that 
* class, but other threads have to wait.
* The list is a simple array of metaclasses (the metaclass stores 
* the initialization state). 
**********************************************************************/
typedef struct _objc_initializing_classes {
    int classesAllocated;
    Class *metaclasses;
} _objc_initializing_classes;


/***********************************************************************
* _fetchInitializingClassList
* Return the list of classes being initialized by this thread.
* If create == YES, create the list when no classes are being initialized by this thread.
* If create == NO, return nil when no classes are being initialized by this thread.
**********************************************************************/
static _objc_initializing_classes *_fetchInitializingClassList(bool create)
{
    _objc_pthread_data *data;
    _objc_initializing_classes *list;
    Class *classes;

    data = _objc_fetch_pthread_data(create);
    if (data == nil) return nil;

    list = data->initializingClasses;
    if (list == nil) {
        if (!create) {
            return nil;
        } else {
            list = (_objc_initializing_classes *)
                calloc(1, sizeof(_objc_initializing_classes));
            data->initializingClasses = list;
        }
    }

    classes = list->metaclasses;
    if (classes == nil) {
        // If _objc_initializing_classes exists, allocate metaclass array, 
        // even if create == NO.
        // Allow 4 simultaneous class inits on this thread before realloc.
        list->classesAllocated = 4;
        classes = (Class *)
            calloc(list->classesAllocated, sizeof(Class));
        list->metaclasses = classes;
    }
    return list;
}

/// Iterate over all classes being initialized on the calling thread.
template <typename Fn>
static void foreachInitializingClass(const Fn &call) {
    _objc_initializing_classes *classes = _fetchInitializingClassList(false);
    if (classes) {
        for (int i = 0; i < classes->classesAllocated; i++) {
            Class cls = classes->metaclasses[i];
            if (cls)
                call(cls);
        }
    }
}

/***********************************************************************
* _destroyInitializingClassList
* Deallocate memory used by the given initialization list. 
* Any part of the list may be nil.
* Called from _objc_pthread_destroyspecific().
**********************************************************************/

void _destroyInitializingClassList(struct _objc_initializing_classes *list)
{
    if (list != nil) {
        if (list->metaclasses != nil) {
            free(list->metaclasses);
        }
        free(list);
    }
}


/***********************************************************************
* _thisThreadIsInitializingClass
* Return TRUE if this thread is currently initializing the given class.
**********************************************************************/
bool _thisThreadIsInitializingClass(Class cls)
{
    int i;

    _objc_initializing_classes *list = _fetchInitializingClassList(NO);
    if (list) {
        cls = cls->getMeta();
        for (i = 0; i < list->classesAllocated; i++) {
            if (cls == list->metaclasses[i]) return YES;
        }
    }

    // no list or not found in list
    return NO;
}


/***********************************************************************
* _setThisThreadIsInitializingClass
* Record that this thread is currently initializing the given class. 
* This thread will be allowed to send messages to the class, but 
*   other threads will have to wait.
**********************************************************************/
static void _setThisThreadIsInitializingClass(Class cls)
{
    int i;
    _objc_initializing_classes *list = _fetchInitializingClassList(YES);
    cls = cls->getMeta();
  
    // paranoia: explicitly disallow duplicates
    for (i = 0; i < list->classesAllocated; i++) {
        if (cls == list->metaclasses[i]) {
            _objc_fatal("thread is already initializing this class!");
            return; // already the initializer
        }
    }
  
    for (i = 0; i < list->classesAllocated; i++) {
        if (! list->metaclasses[i]) {
            list->metaclasses[i] = cls;
            return;
        }
    }

    // class list is full - reallocate
    list->classesAllocated = list->classesAllocated * 2 + 1;
    list->metaclasses = (Class *) 
        realloc(list->metaclasses,
                          list->classesAllocated * sizeof(Class));
    // zero out the new entries
    list->metaclasses[i++] = cls;
    for ( ; i < list->classesAllocated; i++) {
        list->metaclasses[i] = nil;
    }
}


/***********************************************************************
* _setThisThreadIsNotInitializingClass
* Record that this thread is no longer initializing the given class. 
**********************************************************************/
static void _setThisThreadIsNotInitializingClass(Class cls)
{
    int i;

    _objc_initializing_classes *list = _fetchInitializingClassList(NO);
    if (list) {
        cls = cls->getMeta();
        for (i = 0; i < list->classesAllocated; i++) {
            if (cls == list->metaclasses[i]) {
                list->metaclasses[i] = nil;
                return;
            }
        }
    }

    // no list or not found in list
    _objc_fatal("thread is not initializing this class!");  
}


// Provide helpful messages in stack traces.
OBJC_EXTERN __attribute__((noinline, used, visibility("hidden")))
void lockClass(Class cls)
    asm("_WAITING_FOR_A_CLASS_+initialize_LOCK");

void lockClass(Class cls) {
    if (PrintInitializing) {
        _objc_inform("INITIALIZE: thread %p: acquiring lock for "
                     "+[%s initialize]", objc_thread_self(), cls->nameForLogging());
    }

    int result = _objc_sync_enter_kind(cls->getMeta(), SyncKind::classInitialize);
    (void)result;
    ASSERT(result == OBJC_SYNC_SUCCESS);
}

static void unlockClass(Class cls) {
    int result = _objc_sync_exit_kind(cls->getMeta(), SyncKind::classInitialize);
    (void)result;
    ASSERT(result == OBJC_SYNC_SUCCESS);
}

static void assertClassLocked(Class cls) {
    _objc_sync_assert_locked(cls->getMeta(), SyncKind::classInitialize);
}

static void assertClassUnlocked(Class cls) {
    _objc_sync_assert_unlocked(cls->getMeta(), SyncKind::classInitialize);
}


typedef struct PendingInitialize {
    Class subclass;
    struct PendingInitialize *next;

    PendingInitialize(Class cls) : subclass(cls), next(nullptr) { }
} PendingInitialize;

typedef objc::DenseMap<Class, PendingInitialize *> PendingInitializeMap;
static PendingInitializeMap *pendingInitializeMap;
mutex_t pendingInitializeMapLock;

/***********************************************************************
* _finishInitializing
* cls has completed its +initialize method, and so has its superclass.
* Mark cls as initialized as well, then mark any of cls's subclasses 
* that have already finished their own +initialize methods.
**********************************************************************/
static void _finishInitializing(Class cls, Class supercls)
{
    PendingInitialize *pending;

    lockdebug::assert_locked(&pendingInitializeMapLock);
    assertClassLocked(cls);
    ASSERT(!supercls  ||  supercls->isInitialized());

    if (PrintInitializing) {
        _objc_inform("INITIALIZE: thread %p: %s is fully +initialized",
                     objc_thread_self(), cls->nameForLogging());
    }

    // mark this class as fully +initialized
    cls->setInitialized();

    // cls is now fully initialized! Release the lock to unblock waiters.
    unlockClass(cls);
    _setThisThreadIsNotInitializingClass(cls);

    // mark any subclasses that were merely waiting for this class
    if (!pendingInitializeMap) return;

    auto it = pendingInitializeMap->find(cls);
    if (it == pendingInitializeMap->end()) return;

    pending = it->second;
    pendingInitializeMap->erase(it);

    // Destroy the pending table if it's now empty, to save memory.
    if (pendingInitializeMap->size() == 0) {
        delete pendingInitializeMap;
        pendingInitializeMap = nil;
    }

    while (pending) {
        PendingInitialize *next = pending->next;
        if (pending->subclass) _finishInitializing(pending->subclass, cls);
        delete pending;
        pending = next;
    }
}


/***********************************************************************
* _finishInitializingAfter
* cls has completed its +initialize method, but its superclass has not.
* Wait until supercls finishes before marking cls as initialized.
**********************************************************************/
static void _finishInitializingAfter(Class cls, Class supercls)
{
    lockdebug::assert_locked(&pendingInitializeMapLock);
    assertClassLocked(cls);

    if (PrintInitializing) {
        _objc_inform("INITIALIZE: thread %p: class %s will be marked as fully "
                     "+initialized after superclass +[%s initialize] completes",
                     objc_thread_self(), cls->nameForLogging(),
                     supercls->nameForLogging());
    }

    if (!pendingInitializeMap) {
        pendingInitializeMap = new PendingInitializeMap{10};
        // fixme pre-size this table for CF/NSObject +initialize
    }

    PendingInitialize *pending = new PendingInitialize{cls};
    auto result = pendingInitializeMap->try_emplace(supercls, pending);
    if (!result.second) {
        pending->next = result.first->second;
        result.first->second = pending;
    }
}

// Provide helpful messages in stack traces.
OBJC_EXTERN __attribute__((noinline, used, visibility("hidden")))
void callInitialize(Class cls)
    asm("_CALLING_SOME_+initialize_METHOD");


void callInitialize(Class cls)
{
    ((void(*)(Class, SEL))objc_msgSend)(cls, @selector(initialize));
    asm("");
}


/***********************************************************************
* classHasTrivialInitialize
* Returns true if the class has no +initialize implementation or 
* has a +initialize implementation that looks empty.
* Any root class +initialize implemetation is assumed to be trivial.
**********************************************************************/
static bool classHasTrivialInitialize(Class cls)
{
    if (cls->isRootClass() || cls->isRootMetaclass()) return true;

    Class rootCls = cls->ISA()->ISA()->getSuperclass();
    
    IMP rootImp = lookUpImpOrNilTryCache(rootCls, @selector(initialize), rootCls->ISA());
    IMP imp = lookUpImpOrNilTryCache(cls, @selector(initialize), cls->ISA());
    return (imp == nil  ||  imp == (IMP)&objc_noop_imp  ||  imp == rootImp);
}


/***********************************************************************
* lockAndFinishInitializing
* Mark a class as finished initializing and notify waiters, or queue for later.
* If the superclass is also done initializing, then update 
*   the info bits and notify waiting threads.
* If not, update them later. (This can happen if this +initialize 
*   was itself triggered from inside a superclass +initialize.)
**********************************************************************/
static void lockAndFinishInitializing(Class cls, Class supercls)
{
    mutex_locker_t lock(pendingInitializeMapLock);
    if (!supercls  ||  supercls->isInitialized()) {
        _finishInitializing(cls, supercls);
    } else {
        _finishInitializingAfter(cls, supercls);
    }
}


/***********************************************************************
* performForkChildInitialize
* +initialize after fork() is problematic. It's possible for the 
* fork child process to call some +initialize that would deadlock waiting 
* for another +initialize in the parent process. 
* We wouldn't know how much progress it made therein, so we can't
* act as if +initialize completed nor can we restart +initialize
* from scratch.
*
* Instead we proceed introspectively. If the class has some
* +initialize implementation, we halt. If the class has no
* +initialize implementation of its own, we continue. Root
* class +initialize is assumed to be empty if it exists.
*
* We apply this rule even if the child's +initialize does not appear 
* to be blocked by anything. This prevents races wherein the +initialize
* deadlock only rarely hits. Instead we disallow it even when we "won" 
* the race. 
*
* Exception: processes that are single-threaded when fork() is called 
* have no restrictions on +initialize in the child. Examples: sshd and httpd.
*
* Classes that wish to implement +initialize and be callable after 
* fork() must use an atfork() handler to provoke +initialize in fork prepare.
**********************************************************************/

// Called before halting when some +initialize 
// method can't be called after fork().
BREAKPOINT_FUNCTION(
    void objc_initializeAfterForkError(Class cls)
);

void performForkChildInitialize(Class cls, Class supercls)
{
    if (classHasTrivialInitialize(cls)) {
        if (PrintInitializing) {
            _objc_inform("INITIALIZE: thread %p: skipping trivial +[%s "
                         "initialize] in fork() child process",
                         objc_thread_self(), cls->nameForLogging());
        }
        lockAndFinishInitializing(cls, supercls);
    }
    else {
        if (PrintInitializing) {
            _objc_inform("INITIALIZE: thread %p: refusing to call +[%s "
                         "initialize] in fork() child process because "
                         "it may have been in progress when fork() was called",
                         objc_thread_self(), cls->nameForLogging());
        }
        _objc_inform_now_and_on_crash
            ("+[%s initialize] may have been in progress in another thread "
             "when fork() was called.",
             cls->nameForLogging());
        objc_initializeAfterForkError(cls);
        _objc_fatal
            ("+[%s initialize] may have been in progress in another thread "
             "when fork() was called. We cannot safely call it or "
             "ignore it in the fork() child process. Crashing instead. "
             "Set a breakpoint on objc_initializeAfterForkError to debug.",
             cls->nameForLogging());
    }
}


/***********************************************************************
* class_initialize.  Send the '+initialize' message on demand to any
* uninitialized class. Force initialization of superclasses first.
**********************************************************************/
void initializeNonMetaClass(Class cls)
{
    ASSERT(!cls->isMetaClass());

    // Make sure super is done initializing BEFORE beginning to initialize cls.
    // See note about deadlock above.
    Class supercls = cls->getSuperclass();
    if (supercls  &&  !supercls->isInitialized()) {
        initializeNonMetaClass(supercls);
    }

    // Acquire the initialization lock for this class.
    lockClass(cls);

    // Now that it's acquired, there are three possibilities:
    // 1. Initialized. We waited, now it's done, return.
    // 2. Initializing.
    //    A. This thread is already initializing the class and we
    //       reacquired the recursive lock.
    //    B. We're in the child of a fork, another thread was initializing the
    //       class in the parent process, and no longer exists in the child.
    // 3. Neither. This thread won the race to initialize cls, do it.

    // Case 1, we waited.
    if (cls->isInitialized()) {
        unlockClass(cls);
        return;
    }

    // Case 2, we reentered initialization.
    if (cls->isInitializing()) {
        // Case 2A, we're not in a fork child, or we are but the class is
        // initializing on this thread, so we can just return.
        if (!MultithreadedForkChild || _thisThreadIsInitializingClass(cls)) {
            unlockClass(cls);
            return;
        } else {
            // Case 2B, we're on the child side of fork(), facing a class that
            // was initializing by some other thread when fork() was called.
            // The lock for this class has been dropped, so reacquire it here.
            lockClass(cls);
            _setThisThreadIsInitializingClass(cls);
            performForkChildInitialize(cls, supercls);
        }
    }

    // Case 3, we won the race. Set CLS_INITIALIZING and gather will-initialize
    // functions.
    SmallVector<_objc_willInitializeClassCallback, 1> localWillInitializeFuncs;
    {
        mutex_locker_t lock(classInitLock);
        cls->setInitializing();

        localWillInitializeFuncs.initFrom(willInitializeFuncs);
    }
    
    // Record that we're initializing this class so we can message it.
    _setThisThreadIsInitializingClass(cls);

    if (MultithreadedForkChild) {
        // LOL JK we don't really call +initialize methods after fork().
        performForkChildInitialize(cls, supercls);
        return;
    }

    for (auto callback : localWillInitializeFuncs)
        callback.f(callback.context, cls);

    // Send the +initialize message.
    // Note that +initialize is sent to the superclass (again) if
    // this class doesn't implement +initialize. 2157218
    if (PrintInitializing) {
        _objc_inform("INITIALIZE: thread %p: calling +[%s initialize]",
                     objc_thread_self(), cls->nameForLogging());
    }

    // Exceptions: A +initialize call that throws an exception
    // is deemed to be a complete and successful +initialize.
    //
    @try
    {
        callInitialize(cls);

        if (PrintInitializing) {
            _objc_inform("INITIALIZE: thread %p: finished +[%s initialize]",
                         objc_thread_self(), cls->nameForLogging());
        }
    }
    @catch (...) {
        if (PrintInitializing) {
            _objc_inform("INITIALIZE: thread %p: +[%s initialize] "
                         "threw an exception",
                         objc_thread_self(), cls->nameForLogging());
        }
        @throw;
    }
    @finally
    {
        // Done initializing.
        lockAndFinishInitializing(cls, supercls);
    }
}

void _objc_addWillInitializeClassFunc(_objc_func_willInitializeClass _Nonnull func, void * _Nullable context) {
    unsigned count;
    Class *realizedClasses;

    // Fetch all currently initialized classes. Do this with classInitLock held
    // so we don't race with setting those flags.
    {
        mutex_locker_t initLock(classInitLock);
        realizedClasses = objc_copyRealizedClassList(&count);
        for (unsigned i = 0; i < count; i++) {
            // Remove uninitialized classes from the array.
            if (!realizedClasses[i]->isInitializing() && !realizedClasses[i]->isInitialized())
                realizedClasses[i] = Nil;
        }

        willInitializeFuncs.append({func, context});
    }

    // Invoke the callback for all realized classes that weren't cleared out.
    for (unsigned i = 0; i < count; i++) {
        if (Class cls = realizedClasses[i]) {
            func(context, cls);
        }
    }

    free(realizedClasses);
}

// Fork Safety or: We Tried So Hard
//
// It is impossible to make +initialize fork-safe in the general case. The
// standard approach of acquiring all locks pre-fork doesn't work, because
// another thread might be in +initialize waiting on the thread calling fork,
// and trying to wait for that to complete would result in a deadlock.
//
// We also can't forbid fork entirely. ObjC loads into everything and real
// programs do call fork. So we have to try our best.
//
// +initialize calls in progress on the forking thread (fork must have been
// called from within +initialize for that to happen) are fine. They'll resume
// in the child once fork returns. The forking thread held their initialization
// locks. Those locks are gone in the child, so we have to reacquire them.
//
// +initialize calls in progress on other threads are interrupted.
// Unfortunately, there's no way to avoid that, and no way to resume them in the
// child. If the class doesn't actually have a +initialize method (and it was
// just in the middle of running the root class's no-op +initialize) then it's
// OK, we can treat it as initialized and proceed. If the class has a custom
// +initialize implementation, then the best we can do is hope they weren't in
// the middle of anything too important, and fatal error if anything tries to
// use that class. Those locks are also gone in the child. A new attempt to
// initialize those classes will detect the situation and fault in
// performForkChildInitialize.

void classInitializeAtforkPrepare() {}

void classInitializeAtforkParent() {}

void classInitializeAtforkChild() {
    // The objc_sync machinery has destroyed all of its locks in the child.
    // Reacquire the locks for classes initializing on the current thread, so
    // that we're back in a consistent state.
    foreachInitializingClass([](Class cls){
        lockClass(cls);
    });
}

