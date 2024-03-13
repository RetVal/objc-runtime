/*
 * Copyright (c) 2004-2008 Apple Inc. All rights reserved.
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
#include <assert.h>

#include "objc-private.h"

/**********************************************************************
* Object Layouts.
*
* Layouts are used by the garbage collector to identify references from
* the object to other objects.
* 
* Layout information is in the form of a '\0' terminated byte string. 
* Each byte contains a word skip count in the high nibble and a
* consecutive references count in the low nibble. Counts that exceed 15 are
* continued in the succeeding byte with a zero in the opposite nibble. 
* Objects that should be scanned conservatively will have a NULL layout.
* Objects that have no references have a empty byte string.
*
* Example;
* 
*   For a class with pointers at offsets 4,12, 16, 32-128
*   the layout is { 0x11, 0x12, 0x3f, 0x0a, 0x00 } or
*       skip 1 - 1 reference (4)
*       skip 1 - 2 references (12, 16)
*       skip 3 - 15 references (32-88)
*       no skip - 10 references (92-128)
*       end
* 
**********************************************************************/


/**********************************************************************
* compress_layout
* Allocates and returns a compressed string matching the given layout bitmap.
**********************************************************************/
static unsigned char *
compress_layout(const uint8_t *bits, size_t bitmap_bits, bool weak)
{
    bool all_set = YES;
    bool none_set = YES;
    unsigned char *result;

    // overallocate a lot; reallocate at correct size later
    unsigned char * const layout = (unsigned char *)
        calloc(bitmap_bits + 1, 1);
    unsigned char *l = layout;

    size_t i = 0;
    while (i < bitmap_bits) {
        size_t skip = 0;
        size_t scan = 0;

        // Count one range each of skip and scan.
        while (i < bitmap_bits) {
            uint8_t bit = (uint8_t)((bits[i/8] >> (i % 8)) & 1);
            if (bit) break;
            i++;
            skip++;
        }
        while (i < bitmap_bits) {
            uint8_t bit = (uint8_t)((bits[i/8] >> (i % 8)) & 1);
            if (!bit) break;
            i++;
            scan++;
            none_set = NO;
        }

        // Record skip and scan
        if (skip) all_set = NO;
        if (scan) none_set = NO;
        while (skip > 0xf) {
            *l++ = 0xf0;
            skip -= 0xf;
        }
        if (skip || scan) {
            *l = (uint8_t)(skip << 4);    // NOT incremented - merges with scan
            while (scan > 0xf) {
                *l++ |= 0x0f;  // May merge with short skip; must calloc
                scan -= 0xf;
            }
            *l++ |= scan;      // NOT checked for zero - always increments
                               // May merge with short skip; must calloc
        }
    }
    
    // insert terminating byte
    *l++ = '\0';
    
    // return result
    if (none_set  &&  weak) {
        result = NULL;  // NULL weak layout means none-weak
    } else if (all_set  &&  !weak) {
        result = NULL;  // NULL ivar layout means all-scanned
    } else {
        result = (unsigned char *)strdup((char *)layout); 
    }
    free(layout);
    return result;
}


static void set_bits(layout_bitmap bits, size_t which, size_t count)
{
    // fixme optimize for byte/word at a time
    size_t bit;
    for (bit = which; bit < which + count  &&  bit < bits.bitCount; bit++) {
        bits.bits[bit/8] |= 1 << (bit % 8);
    }
    if (bit == bits.bitCount  &&  bit < which + count) {
        // couldn't fit full type in bitmap
        _objc_fatal("layout bitmap too short");
    }
}

static void clear_bits(layout_bitmap bits, size_t which, size_t count)
{
    // fixme optimize for byte/word at a time
    size_t bit;
    for (bit = which; bit < which + count  &&  bit < bits.bitCount; bit++) {
        bits.bits[bit/8] &= ~(1 << (bit % 8));
    }
    if (bit == bits.bitCount  &&  bit < which + count) {
        // couldn't fit full type in bitmap
        _objc_fatal("layout bitmap too short");
    }
}

static void move_bits(layout_bitmap bits, size_t src, size_t dst, 
                      size_t count)
{
    // fixme optimize for byte/word at a time

    if (dst == src) {
        return;
    }
    else if (dst > src) {
        // Copy backwards in case of overlap
        size_t pos = count;
        while (pos--) {
            size_t srcbit = src + pos;
            size_t dstbit = dst + pos;
            if (bits.bits[srcbit/8] & (1 << (srcbit % 8))) {
                bits.bits[dstbit/8] |= 1 << (dstbit % 8);
            } else {
                bits.bits[dstbit/8] &= ~(1 << (dstbit % 8));
            }
        }
    }
    else {
        // Copy forwards in case of overlap
        size_t pos;
        for (pos = 0; pos < count; pos++) {
            size_t srcbit = src + pos;
            size_t dstbit = dst + pos;
            if (bits.bits[srcbit/8] & (1 << (srcbit % 8))) {
                bits.bits[dstbit/8] |= 1 << (dstbit % 8);
            } else {
                bits.bits[dstbit/8] &= ~(1 << (dstbit % 8));
            }
        }
    }
}

static void decompress_layout(const unsigned char *layout_string, layout_bitmap bits)
{
    unsigned char c;
    size_t bit = 0;
    while ((c = *layout_string++)) {
        unsigned char skip = (c & 0xf0) >> 4;
        unsigned char scan = (c & 0x0f);
        bit += skip;
        set_bits(bits, bit, scan);
        bit += scan;
    }
}


/***********************************************************************
* layout_bitmap_create
* Allocate a layout bitmap.
* The new bitmap spans the given instance size bytes.
* The start of the bitmap is filled from the given layout string (which 
*   spans an instance size of layoutStringSize); the rest is zero-filled.
* The returned bitmap must be freed with layout_bitmap_free().
**********************************************************************/
layout_bitmap 
layout_bitmap_create(const unsigned char *layout_string,
                     size_t layoutStringInstanceSize, 
                     size_t instanceSize, bool weak)
{
    layout_bitmap result;
    size_t words = instanceSize / sizeof(id);
    
    result.weak = weak;
    result.bitCount = words;
    result.bitsAllocated = words;
    result.bits = (uint8_t *)calloc((words+7)/8, 1);

    if (!layout_string) {
        if (!weak) {
            // NULL ivar layout means all-scanned
            // (but only up to layoutStringSize instance size)
            set_bits(result, 0, layoutStringInstanceSize/sizeof(id));
        } else {
            // NULL weak layout means none-weak.
        }
    } else {
        decompress_layout(layout_string, result);
    }

    return result;
}


/***********************************************************************
 * layout_bitmap_create_empty
 * Allocate a layout bitmap.
 * The new bitmap spans the given instance size bytes.
 * The bitmap is empty, to represent an object whose ivars are completely unscanned.
 * The returned bitmap must be freed with layout_bitmap_free().
 **********************************************************************/
layout_bitmap
layout_bitmap_create_empty(size_t instanceSize, bool weak)
{
    layout_bitmap result;
    size_t words = instanceSize / sizeof(id);
    
    result.weak = weak;
    result.bitCount = words;
    result.bitsAllocated = words;
    result.bits = (uint8_t *)calloc((words+7)/8, 1);

    return result;
}

void 
layout_bitmap_free(layout_bitmap bits)
{
    if (bits.bits) free(bits.bits);
}

const unsigned char * 
layout_string_create(layout_bitmap bits)
{
    const unsigned char *result =
        compress_layout(bits.bits, bits.bitCount, bits.weak);

#if DEBUG
    // paranoia: cycle to bitmap and back to string again, and compare
    layout_bitmap check = layout_bitmap_create(result, bits.bitCount*sizeof(id), 
                                               bits.bitCount*sizeof(id), bits.weak);
    unsigned char *result2 = 
        compress_layout(check.bits, check.bitCount, check.weak);
    if (result != result2  &&  0 != strcmp((char*)result, (char *)result2)) {
        layout_bitmap_print(bits);
        layout_bitmap_print(check);
        _objc_fatal("libobjc bug: mishandled layout bitmap");
    }
    free(result2);
    layout_bitmap_free(check);
#endif

    return result;
}


void
layout_bitmap_set_ivar(layout_bitmap bits, const char *type, size_t offset)
{
    // fixme only handles some types
    size_t bit = offset / sizeof(id);

    if (!type) return;
    if (type[0] == '@'  ||  0 == strcmp(type, "^@")) {
        // id
        // id *
        // Block ("@?")
        set_bits(bits, bit, 1);
    } 
    else if (type[0] == '[') {
        // id[]
        char *t;
        unsigned long count = strtoul(type+1, &t, 10);
        if (t  &&  t[0] == '@') {
            set_bits(bits, bit, count);
        }
    } 
    else if (strchr(type, '@')) {
        _objc_inform("warning: failing to set GC layout for '%s'\n", type);
    }
}



/***********************************************************************
* layout_bitmap_grow
* Expand a layout bitmap to span newCount bits. 
* The new bits are undefined.
**********************************************************************/
void 
layout_bitmap_grow(layout_bitmap *bits, size_t newCount)
{
    if (bits->bitCount >= newCount) return;
    bits->bitCount = newCount;
    if (bits->bitsAllocated < newCount) {
        size_t newAllocated = bits->bitsAllocated * 2;
        if (newAllocated < newCount) newAllocated = newCount;
        bits->bits = (uint8_t *)
            realloc(bits->bits, (newAllocated+7) / 8);
        bits->bitsAllocated = newAllocated;
    }
    ASSERT(bits->bitsAllocated >= bits->bitCount);
    ASSERT(bits->bitsAllocated >= newCount);
}


/***********************************************************************
* layout_bitmap_slide
* Slide the end of a layout bitmap farther from the start.
* Slides bits [oldPos, bits.bitCount) to [newPos, bits.bitCount+newPos-oldPos)
* Bits [oldPos, newPos) are zero-filled.
* The bitmap is expanded and bitCount updated if necessary.
* newPos >= oldPos.
**********************************************************************/
void
layout_bitmap_slide(layout_bitmap *bits, size_t oldPos, size_t newPos)
{
    size_t shift;
    size_t count;

    if (oldPos == newPos) return;
    if (oldPos > newPos) _objc_fatal("layout bitmap sliding backwards");

    shift = newPos - oldPos;
    count = bits->bitCount - oldPos;
    layout_bitmap_grow(bits, bits->bitCount + shift);
    move_bits(*bits, oldPos, newPos, count);  // slide
    clear_bits(*bits, oldPos, shift);         // zero-fill
}


/***********************************************************************
* layout_bitmap_slide_anywhere
* Slide the end of a layout bitmap relative to the start.
* Like layout_bitmap_slide, but can slide backwards too.
* The end of the bitmap is truncated.
**********************************************************************/
void
layout_bitmap_slide_anywhere(layout_bitmap *bits, size_t oldPos, size_t newPos)
{
    size_t shift;
    size_t count;

    if (oldPos == newPos) return;

    if (oldPos < newPos) {
        layout_bitmap_slide(bits, oldPos, newPos);
        return;
    } 

    shift = oldPos - newPos;
    count = bits->bitCount - oldPos;
    move_bits(*bits, oldPos, newPos, count);  // slide
    bits->bitCount -= shift;
}


/***********************************************************************
* layout_bitmap_splat
* Pastes the contents of bitmap src to the start of bitmap dst.
* dst bits between the end of src and oldSrcInstanceSize are zeroed.
* dst must be at least as long as src.
* Returns YES if any of dst's bits were changed.
**********************************************************************/
bool
layout_bitmap_splat(layout_bitmap dst, layout_bitmap src, 
                    size_t oldSrcInstanceSize)
{
    bool changed;
    size_t oldSrcBitCount;
    size_t bit;

    if (dst.bitCount < src.bitCount) _objc_fatal("layout bitmap too short");

    changed = NO;
    oldSrcBitCount = oldSrcInstanceSize / sizeof(id);
    
    // fixme optimize for byte/word at a time
    for (bit = 0; bit < oldSrcBitCount; bit++) {
        int dstset = dst.bits[bit/8] & (1 << (bit % 8));
        int srcset = (bit < src.bitCount) 
            ? src.bits[bit/8] & (1 << (bit % 8))
            : 0;
        if (dstset != srcset) {
            changed = YES;
            if (srcset) {
                dst.bits[bit/8] |= 1 << (bit % 8);
            } else {
                dst.bits[bit/8] &= ~(1 << (bit % 8));
            }
        }
    }

    return changed;
}


/***********************************************************************
* layout_bitmap_or
* Set dst=dst|src.
* dst must be at least as long as src.
* Returns YES if any of dst's bits were changed.
**********************************************************************/
bool
layout_bitmap_or(layout_bitmap dst, layout_bitmap src, const char *msg)
{
    bool changed = NO;
    size_t bit;

    if (dst.bitCount < src.bitCount) {
        _objc_fatal("layout_bitmap_or: layout bitmap too short%s%s", 
                    msg ? ": " : "", msg ? msg : "");
    }
    
    // fixme optimize for byte/word at a time
    for (bit = 0; bit < src.bitCount; bit++) {
        int dstset = dst.bits[bit/8] & (1 << (bit % 8));
        int srcset = src.bits[bit/8] & (1 << (bit % 8));
        if (srcset  &&  !dstset) {
            changed = YES;
            dst.bits[bit/8] |= 1 << (bit % 8);
        }
    }

    return changed;
}


/***********************************************************************
* layout_bitmap_clear
* Set dst=dst&~src.
* dst must be at least as long as src.
* Returns YES if any of dst's bits were changed.
**********************************************************************/
bool
layout_bitmap_clear(layout_bitmap dst, layout_bitmap src, const char *msg)
{
    bool changed = NO;
    size_t bit;

    if (dst.bitCount < src.bitCount) {
        _objc_fatal("layout_bitmap_clear: layout bitmap too short%s%s", 
                    msg ? ": " : "", msg ? msg : "");
    }
    
    // fixme optimize for byte/word at a time
    for (bit = 0; bit < src.bitCount; bit++) {
        int dstset = dst.bits[bit/8] & (1 << (bit % 8));
        int srcset = src.bits[bit/8] & (1 << (bit % 8));
        if (srcset  &&  dstset) {
            changed = YES;
            dst.bits[bit/8] &= ~(1 << (bit % 8));
        }
    }

    return changed;
}


void
layout_bitmap_print(layout_bitmap bits)
{
    size_t i;
    printf("%zu: ", bits.bitCount);
    for (i = 0; i < bits.bitCount; i++) {
        int set = bits.bits[i/8] & (1 << (i % 8));
        printf("%c", set ? '#' : '.');
    }
    printf("\n");
}
