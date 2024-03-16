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

#include "objc-private.h"
#include "objc-sync.h"

//
// Allocate a lock only when needed.  Since few locks are needed at any point
// in time, keep them on a single list.
//


typedef struct alignas(CacheLineSize) SyncData {
    struct SyncData* nextData;
    DisguisedPtr<objc_object> object;
    SyncKind kind;
    int32_t threadCount;  // number of THREADS using this block
    recursive_mutex_t mutex;

    bool matches(id matchObject, SyncKind matchKind) {
        ASSERT(matchKind != SyncKind::invalid);
        ASSERT(kind != SyncKind::invalid);
        return object == matchObject && kind == matchKind;
    }
} SyncData;

typedef struct {
    SyncData *data;
    unsigned int lockCount;  // number of times THIS THREAD locked this block
} SyncCacheItem;

typedef struct SyncCache {
    unsigned int allocated;
    unsigned int used;
    SyncCacheItem list[0];
} SyncCache;

/*
  Fast cache: two fixed pthread keys store a single SyncCacheItem. 
  This avoids malloc of the SyncCache for threads that only synchronize 
  a single object at a time.
  SYNC_DATA_DIRECT_KEY  == SyncCacheItem.data
  SYNC_COUNT_DIRECT_KEY == SyncCacheItem.lockCount
 */

// Enabled if we have direct keys or compiler thread locals
#if SUPPORT_DIRECT_THREAD_KEYS || SUPPORT_THREAD_LOCAL
#define ENABLE_FAST_CACHE 1
#else
#define ENABLE_FAST_CACHE 0
#endif

#if ENABLE_FAST_CACHE
static tls_direct_fast(SyncData *, tls_key::sync_data) syncData;
static tls_direct_fast(uintptr_t, tls_key::sync_count) syncLockCount;
#endif

struct SyncList {
    SyncData *_data;
    spinlock_t _lock;

    SyncList() : _data(nil), _lock(fork_unsafe) { }

    void lock() {
        _lock.lock();
    }

    void unlock() {
        _lock.unlock();
    }

    void reset() {
        _lock.reset();
    }
};

// Use multiple parallel lists to decrease contention among unrelated objects.
#define LOCK_FOR_OBJ(obj) sDataLists[obj]._lock
#define LIST_FOR_OBJ(obj) sDataLists[obj]._data
static StripedMap<SyncList> sDataLists;


enum usage { ACQUIRE, RELEASE, CHECK };

static SyncCache *fetch_cache(bool create)
{
    _objc_pthread_data *data;

    data = _objc_fetch_pthread_data(create);
    if (!data) return NULL;

    if (!data->syncCache) {
        if (!create) {
            return NULL;
        } else {
            int count = 4;
            data->syncCache = (SyncCache *)
                calloc(1, sizeof(SyncCache) + count*sizeof(SyncCacheItem));
            data->syncCache->allocated = count;
        }
    }

    // Make sure there's at least one open slot in the list.
    if (data->syncCache->allocated == data->syncCache->used) {
        data->syncCache->allocated *= 2;
        data->syncCache = (SyncCache *)
            realloc(data->syncCache, sizeof(SyncCache) 
                    + data->syncCache->allocated * sizeof(SyncCacheItem));
    }

    return data->syncCache;
}


void _destroySyncCache(struct SyncCache *cache)
{
    if (cache) free(cache);
}

// Remove the current thread's SyncCache, if there is one. For use on the child
// side of a fork().
static void clearSyncCache()
{
    if (_objc_pthread_data *data = _objc_fetch_pthread_data(false)) {
        _destroySyncCache(data->syncCache);
        data->syncCache = NULL;
    }
#if ENABLE_FAST_CACHE
    syncData = NULL;
    syncLockCount = 0;
#endif
}

static SyncData* id2data(id object, SyncKind kind, enum usage why)
{
    ASSERT(kind != SyncKind::invalid);
    spinlock_t *lockp = &LOCK_FOR_OBJ(object);
    SyncData **listp = &LIST_FOR_OBJ(object);
    SyncData* result = NULL;

#if ENABLE_FAST_CACHE
    // Check per-thread single-entry fast cache for matching object
    bool fastCacheOccupied = NO;
    SyncData *data = syncData;
    if (data) {
        fastCacheOccupied = YES;

        if (data->matches(object, kind)) {
            // Found a match in fast cache.
            result = data;
            if (result->threadCount <= 0  ||  syncLockCount <= 0) {
                _objc_fatal("id2data fastcache is buggy");
            }

            switch(why) {
            case ACQUIRE: {
                ++syncLockCount;
                break;
            }
            case RELEASE:
                if (--syncLockCount == 0) {
                    // remove from fast cache
                    syncData = nullptr;
                    // atomic because may collide with concurrent ACQUIRE
                    AtomicDecrement(&result->threadCount);
                }
                break;
            case CHECK:
                // do nothing
                break;
            }

            return result;
        }
    }
#endif // ENABLE_FAST_CACHE

    // Check per-thread cache of already-owned locks for matching object
    SyncCache *cache = fetch_cache(NO);
    if (cache) {
        unsigned int i;
        for (i = 0; i < cache->used; i++) {
            SyncCacheItem *item = &cache->list[i];
            if (!item->data->matches(object, kind)) continue;

            // Found a match.
            result = item->data;
            if (result->threadCount <= 0  ||  item->lockCount <= 0) {
                _objc_fatal("id2data cache is buggy");
            }
                
            switch(why) {
            case ACQUIRE:
                item->lockCount++;
                break;
            case RELEASE:
                item->lockCount--;
                if (item->lockCount == 0) {
                    // remove from per-thread cache
                    cache->list[i] = cache->list[--cache->used];
                    // atomic because may collide with concurrent ACQUIRE
                    AtomicDecrement(&result->threadCount);
                }
                break;
            case CHECK:
                // do nothing
                break;
            }

            return result;
        }
    }

    // Thread cache didn't find anything.
    // Walk in-use list looking for matching object
    // Spinlock prevents multiple threads from creating multiple 
    // locks for the same new object.
    // We could keep the nodes in some hash table if we find that there are
    // more than 20 or so distinct locks active, but we don't do that now.
    
    lockp->lock();

    {
        SyncData* p;
        SyncData* firstUnused = NULL;
        for (p = *listp; p != NULL; p = p->nextData) {
            if ( p->matches(object, kind) ) {
                result = p;
                // atomic because may collide with concurrent RELEASE
                AtomicIncrement(&result->threadCount);
                goto done;
            }
            if ( (firstUnused == NULL) && (p->threadCount == 0) )
                firstUnused = p;
        }
    
        // no SyncData currently associated with object
        if ( (why == RELEASE) || (why == CHECK) )
            goto done;
    
        // an unused one was found, use it
        if ( firstUnused != NULL ) {
            result = firstUnused;
            result->object = (objc_object *)object;
            result->kind = kind;
            result->threadCount = 1;
            goto done;
        }
    }

    // Allocate a new SyncData and add to list.
    // XXX allocating memory with a global lock held is bad practice,
    // might be worth releasing the lock, allocating, and searching again.
    // But since we never free these guys we won't be stuck in allocation very often.
    posix_memalign((void **)&result, alignof(SyncData), sizeof(SyncData));
    result->object = (objc_object *)object;
    result->kind = kind;
    result->threadCount = 1;
    new (&result->mutex) recursive_mutex_t(fork_unsafe);
    result->nextData = *listp;
    *listp = result;
    
 done:
    lockp->unlock();
    if (result) {
        // Only new ACQUIRE should get here.
        // All RELEASE and CHECK and recursive ACQUIRE are 
        // handled by the per-thread caches above.
        if (why == RELEASE) {
            // Probably some thread is incorrectly exiting 
            // while the object is held by another thread.
            return nil;
        }
        if (why != ACQUIRE) _objc_fatal("id2data is buggy");
        if (!result->matches(object, kind)) _objc_fatal("id2data is buggy");

#if ENABLE_FAST_CACHE
        if (!fastCacheOccupied) {
            // Save in fast thread cache
            syncData = result;
            syncLockCount = 1;
        } else
#endif // ENABLE_FAST_CACHE
        {
            // Save in thread cache
            if (!cache) cache = fetch_cache(YES);
            cache->list[cache->used].data = result;
            cache->list[cache->used].lockCount = 1;
            cache->used++;
        }
    }

    return result;
}


BREAKPOINT_FUNCTION(
    void objc_sync_nil(void)
);


// Begin synchronizing on 'obj'. 
// Allocates recursive mutex associated with 'obj' if needed.
// Returns OBJC_SYNC_SUCCESS once lock is acquired.  
int objc_sync_enter(id obj)
{
    int result = _objc_sync_enter_kind(obj, SyncKind::atSynchronize);
    if (result != OBJC_SYNC_SUCCESS)
        OBJC_DEBUG_OPTION_REPORT_ERROR(DebugSyncErrors,
            "objc_sync_enter(%p) returned error %d", obj, result);
    return result;
}

int _objc_sync_enter_kind(id obj, SyncKind kind)
{
    int result = OBJC_SYNC_SUCCESS;

    if (obj) {
        SyncData* data = id2data(obj, kind, ACQUIRE);
        ASSERT(data);
        data->mutex.lock();
    } else {
        // @synchronized(nil) does nothing
        if (DebugNilSync) {
            _objc_inform("NIL SYNC DEBUG: @synchronized(nil); set a breakpoint on objc_sync_nil to debug");
        }
        objc_sync_nil();
        if (DebugNilSync == Fatal)
            _objc_fatal("@synchronized(nil) is fatal");
    }

    return result;
}

BOOL objc_sync_try_enter(id obj)
{
    BOOL result = YES;

    if (obj) {
        SyncData* data = id2data(obj, SyncKind::atSynchronize, ACQUIRE);
        ASSERT(data);
        result = data->mutex.tryLock();
    } else {
        // @synchronized(nil) does nothing
        if (DebugNilSync) {
            _objc_inform("NIL SYNC DEBUG: @synchronized(nil); set a breakpoint on objc_sync_nil to debug");
        }
        objc_sync_nil();
        if (DebugNilSync == Fatal)
            _objc_fatal("@synchronized(nil) is fatal");
    }

    return result;
}


// End synchronizing on 'obj'. 
// Returns OBJC_SYNC_SUCCESS or OBJC_SYNC_NOT_OWNING_THREAD_ERROR
int objc_sync_exit(id obj)
{
    int result = _objc_sync_exit_kind(obj, SyncKind::atSynchronize);
    if (result != OBJC_SYNC_SUCCESS)
        OBJC_DEBUG_OPTION_REPORT_ERROR(DebugSyncErrors,
            "objc_sync_exit(%p) returned error %d", obj, result);
    return result;
}

int _objc_sync_exit_kind(id obj, SyncKind kind)
{
    int result = OBJC_SYNC_SUCCESS;
    
    if (obj) {
        SyncData* data = id2data(obj, kind, RELEASE);
        if (!data) {
            result = OBJC_SYNC_NOT_OWNING_THREAD_ERROR;
        } else {
            bool okay = data->mutex.tryUnlock();
            if (!okay) {
                result = OBJC_SYNC_NOT_OWNING_THREAD_ERROR;
            }
        }
    } else {
        // @synchronized(nil) does nothing
    }
	

    return result;
}

void _objc_sync_exit_forked_child(id obj, SyncKind kind)
{
    SyncData *data = id2data(obj, kind, RELEASE);
    data->mutex.unlockForkedChild();
}

void _objc_sync_assert_locked(id obj, SyncKind kind)
{
#ifndef NDEBUG
    SyncData *data = id2data(obj, kind, ACQUIRE);
    ASSERT(data);
    lockdebug::assert_locked(&data->mutex);
    id2data(obj, kind, RELEASE);
#endif
}

void _objc_sync_assert_unlocked(id obj, SyncKind kind)
{
#ifndef NDEBUG
    SyncData *data = id2data(obj, kind, CHECK);
    ASSERT(data);
    lockdebug::assert_locked(&data->mutex);
#endif
}

void _objc_sync_foreach_lock(void (^call)(id obj, SyncKind kind, recursive_mutex_t *mutex))
{
    sDataLists.lockAll();

    sDataLists.forEach([&call](SyncList &list) {
        SyncData *data = list._data;
        while (data) {
            call((id)(objc_object *)data->object, data->kind, &data->mutex);
            data = data->nextData;
        }
    });

    sDataLists.unlockAll();
}

void _objc_sync_lock_atfork_prepare(void)
{
    sDataLists.lockAll();
}

void _objc_sync_lock_atfork_parent(void)
{
    sDataLists.unlockAll();
}

void _objc_sync_lock_atfork_child(void)
{
    sDataLists.forceResetAll();

    // The per-thread cache could hold stale data, clear it.
    clearSyncCache();

    // Destroy all locks we hold and start fresh. A lock can be in any of three
    // states at this point, all of which are useless:
    // 1. Held by another thread. That thread is gone and nothing is going to
    //    unlock it.
    // 2. Held by this thread. The lock is not valid in the child.
    // 3. Not held by anybody. We only keep it around for efficiency and because
    //    it's hard to safely deallocate these things. Fork is already
    //    inefficient and there are no other active threads in the child so safe
    //    deallocation is trivial.
    sDataLists.forEach([](SyncList &list) {
        SyncData *data = list._data;
        while (data) {
            SyncData *next = data->nextData;
            free(data);
            data = next;
        }
        list._data = NULL;
    });
}
