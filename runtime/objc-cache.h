
#ifndef _OBJC_CACHE_H
#define _OBJC_CACHE_H

#include "objc-private.h"

__BEGIN_DECLS

extern IMP cache_getImp(Class cls, SEL sel);

extern void cache_fill(Class cls, SEL sel, IMP imp);

extern void cache_eraseMethods(Class cls, method_list_t *mlist);

extern void cache_eraseImp(Class cls, SEL sel, IMP imp);

extern void cache_eraseImp_nolock(Class cls, SEL sel, IMP imp);

extern void cache_erase_nolock(cache_t *cache);

extern void cache_collect(bool collectALot);

__END_DECLS

#endif
