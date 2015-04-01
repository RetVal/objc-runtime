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


typedef struct SyncData {
    struct SyncData* nextData;
    id               object;
    int              threadCount;  // number of THREADS using this block
    recursive_mutex_t        mutex;
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

typedef struct {
    SyncData *data;
    OSSpinLock lock;

    char align[64 - sizeof (OSSpinLock) - sizeof (SyncData *)];
} SyncList __attribute__((aligned(64)));
// aligned to put locks on separate cache lines

// Use multiple parallel lists to decrease contention among unrelated objects.
#define COUNT 16
#define HASH(obj) ((((uintptr_t)(obj)) >> 5) & (COUNT - 1))
#define LOCK_FOR_OBJ(obj) sDataLists[HASH(obj)].lock
#define LIST_FOR_OBJ(obj) sDataLists[HASH(obj)].data
static SyncList sDataLists[COUNT];


enum usage { ACQUIRE, RELEASE, CHECK };

static SyncCache *fetch_cache(BOOL create)
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


static SyncData* id2data(id object, enum usage why)
{
    OSSpinLock *lockp = &LOCK_FOR_OBJ(object);
    SyncData **listp = &LIST_FOR_OBJ(object);
    SyncData* result = NULL;

#if SUPPORT_DIRECT_THREAD_KEYS
    // Check per-thread single-entry fast cache for matching object
    BOOL fastCacheOccupied = NO;
    SyncData *data = (SyncData *)tls_get_direct(SYNC_DATA_DIRECT_KEY);
    if (data) {
        fastCacheOccupied = YES;

        if (data->object == object) {
            // Found a match in fast cache.
            uintptr_t lockCount;

            result = data;
            lockCount = (uintptr_t)tls_get_direct(SYNC_COUNT_DIRECT_KEY);
            require_action_string(result->threadCount > 0, fastcache_done, 
                                  result = NULL, "id2data fastcache is buggy");
            require_action_string(lockCount > 0, fastcache_done, 
                                  result = NULL, "id2data fastcache is buggy");

            switch(why) {
            case ACQUIRE: {
                lockCount++;
                tls_set_direct(SYNC_COUNT_DIRECT_KEY, (void*)lockCount);
                break;
            }
            case RELEASE:
                lockCount--;
                tls_set_direct(SYNC_COUNT_DIRECT_KEY, (void*)lockCount);
                if (lockCount == 0) {
                    // remove from fast cache
                    tls_set_direct(SYNC_DATA_DIRECT_KEY, NULL);
                    // atomic because may collide with concurrent ACQUIRE
                    OSAtomicDecrement32Barrier(&result->threadCount);
                }
                break;
            case CHECK:
                // do nothing
                break;
            }

        fastcache_done:     
            return result;            
        }
    }
#endif

    // Check per-thread cache of already-owned locks for matching object
    SyncCache *cache = fetch_cache(NO);
    if (cache) {
        unsigned int i;
        for (i = 0; i < cache->used; i++) {
            SyncCacheItem *item = &cache->list[i];
            if (item->data->object != object) continue;

            // Found a match.
            result = item->data;
            require_action_string(result->threadCount > 0, cache_done, 
                                  result = NULL, "id2data cache is buggy");
            require_action_string(item->lockCount > 0, cache_done, 
                                  result = NULL, "id2data cache is buggy");
                
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
                    OSAtomicDecrement32Barrier(&result->threadCount);
                }
                break;
            case CHECK:
                // do nothing
                break;
            }

        cache_done:
            return result;
        }
    }

    // Thread cache didn't find anything.
    // Walk in-use list looking for matching object
    // Spinlock prevents multiple threads from creating multiple 
    // locks for the same new object.
    // We could keep the nodes in some hash table if we find that there are
    // more than 20 or so distinct locks active, but we don't do that now.
    
    OSSpinLockLock(lockp);

    {
        SyncData* p;
        SyncData* firstUnused = NULL;
        for (p = *listp; p != NULL; p = p->nextData) {
            if ( p->object == object ) {
                result = p;
                // atomic because may collide with concurrent RELEASE
                OSAtomicIncrement32Barrier(&result->threadCount);
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
            result->object = object;
            result->threadCount = 1;
            goto done;
        }
    }
                            
    // malloc a new SyncData and add to list.
    // XXX calling malloc with a global lock held is bad practice,
    // might be worth releasing the lock, mallocing, and searching again.
    // But since we never free these guys we won't be stuck in malloc very often.
    result = (SyncData*)calloc(sizeof(SyncData), 1);
    result->object = object;
    result->threadCount = 1;
    recursive_mutex_init(&result->mutex);
    result->nextData = *listp;
    *listp = result;
    
 done:
    OSSpinLockUnlock(lockp);
    if (result) {
        // Only new ACQUIRE should get here.
        // All RELEASE and CHECK and recursive ACQUIRE are 
        // handled by the per-thread caches above.
        
        require_string(result != NULL, really_done, "id2data is buggy");
        require_action_string(why == ACQUIRE, really_done, 
                              result = NULL, "id2data is buggy");
        require_action_string(result->object == object, really_done, 
                              result = NULL, "id2data is buggy");

#if SUPPORT_DIRECT_THREAD_KEYS
        if (!fastCacheOccupied) {
            // Save in fast thread cache
            tls_set_direct(SYNC_DATA_DIRECT_KEY, result);
            tls_set_direct(SYNC_COUNT_DIRECT_KEY, (void*)1);
        } else 
#endif
        {
            // Save in thread cache
            if (!cache) cache = fetch_cache(YES);
            cache->list[cache->used].data = result;
            cache->list[cache->used].lockCount = 1;
            cache->used++;
        }
    }

 really_done:
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
    int result = OBJC_SYNC_SUCCESS;

    if (obj) {
        SyncData* data = id2data(obj, ACQUIRE);
        require_action_string(data != NULL, done, result = OBJC_SYNC_NOT_INITIALIZED, "id2data failed");
	
        result = recursive_mutex_lock(&data->mutex);
        require_noerr_string(result, done, "mutex_lock failed");
    } else {
        // @synchronized(nil) does nothing
        if (DebugNilSync) {
            _objc_inform("NIL SYNC DEBUG: @synchronized(nil); set a breakpoint on objc_sync_nil to debug");
        }
        objc_sync_nil();
    }

done: 
    return result;
}


// End synchronizing on 'obj'. 
// Returns OBJC_SYNC_SUCCESS or OBJC_SYNC_NOT_OWNING_THREAD_ERROR
int objc_sync_exit(id obj)
{
    int result = OBJC_SYNC_SUCCESS;
    
    if (obj) {
        SyncData* data = id2data(obj, RELEASE); 
        require_action_string(data != NULL, done, result = OBJC_SYNC_NOT_OWNING_THREAD_ERROR, "id2data failed");
        
        result = recursive_mutex_unlock(&data->mutex);
        require_noerr_string(result, done, "mutex_unlock failed");
    } else {
        // @synchronized(nil) does nothing
    }
	
done:
    if ( result == RECURSIVE_MUTEX_NOT_LOCKED )
         result = OBJC_SYNC_NOT_OWNING_THREAD_ERROR;

    return result;
}

