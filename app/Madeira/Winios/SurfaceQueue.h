/* Bounded full-surface mailbox. Caller supplies a mutex and owns payloads.
 * A ticket belongs to ONE scheduled main-queue task. Replacement keeps its
 * ticket; invalidation/reuse gets a new ticket so stale tasks cannot consume
 * a newer window's frame. No UIKit or allocation in the tested policy.
 * GPL-3.0-or-later. */
#ifndef MADEIRA_SURFACE_QUEUE_H
#define MADEIRA_SURFACE_QUEUE_H
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#define MADEIRA_SURFACE_SLOTS 64u
#define MADEIRA_SURFACE_BYTES ((size_t)128 * 1024 * 1024)
#define MADEIRA_SURFACE_DIMENSION 16384

typedef struct {
    uintptr_t key;
    uint64_t ticket;
    size_t bytes;
    int width, height, stride;
    void *payload;
} madeira_surface_frame;

typedef struct {
    madeira_surface_frame slots[MADEIRA_SURFACE_SLOTS];
    size_t bytes;
    unsigned count;
    uint64_t next_ticket, coalesced, rejected;
} madeira_surface_queue;

static inline bool madeira_surface_layout(int width, int height, int stride, size_t *bytes) {
    if (!bytes || width <= 0 || height <= 0 || stride <= 0 ||
        width > MADEIRA_SURFACE_DIMENSION || height > MADEIRA_SURFACE_DIMENSION ||
        width > stride / 4 || stride % 4 || (size_t)stride > SIZE_MAX / (size_t)height)
        return false;
    size_t total = (size_t)stride * (size_t)height;
    if (total > MADEIRA_SURFACE_BYTES) return false;
    *bytes = total;
    return true;
}

/* On success the queue owns frame.payload; on failure ownership stays with
 * caller. *retired, when nonnull, belongs to the caller and must be released.
 * Schedule exactly one task for a nonzero *schedule_ticket, under the SAME
 * lock used to enqueue destroy tasks, to preserve lifetime ordering. */
static inline bool madeira_surface_push(madeira_surface_queue *q, madeira_surface_frame frame,
                                       void **retired, uint64_t *schedule_ticket) {
    *retired = NULL;
    *schedule_ticket = 0;
    if (!frame.key || !frame.payload || !frame.bytes || frame.bytes > MADEIRA_SURFACE_BYTES) {
        ++q->rejected;
        return false;
    }
    unsigned slot = MADEIRA_SURFACE_SLOTS, empty = MADEIRA_SURFACE_SLOTS;
    for (unsigned i = 0; i < MADEIRA_SURFACE_SLOTS; ++i) {
        if (q->slots[i].key == frame.key) { slot = i; break; }
        if (!q->slots[i].key && empty == MADEIRA_SURFACE_SLOTS) empty = i;
    }
    bool replacing = slot < MADEIRA_SURFACE_SLOTS;
    if (!replacing) slot = empty;
    size_t old = replacing ? q->slots[slot].bytes : 0;
    if (slot == MADEIRA_SURFACE_SLOTS || frame.bytes > MADEIRA_SURFACE_BYTES - (q->bytes - old) ||
        (!replacing && q->next_ticket == UINT64_MAX)) {
        ++q->rejected;
        return false;
    }
    if (replacing) {
        frame.ticket = q->slots[slot].ticket;
        *retired = q->slots[slot].payload;
        ++q->coalesced;
    } else {
        frame.ticket = ++q->next_ticket;
        *schedule_ticket = frame.ticket;
        ++q->count;
    }
    q->bytes = q->bytes - old + frame.bytes;
    q->slots[slot] = frame;
    return true;
}

static inline bool madeira_surface_take(madeira_surface_queue *q, uintptr_t key, uint64_t ticket,
                                       madeira_surface_frame *frame) {
    for (unsigned i = 0; i < MADEIRA_SURFACE_SLOTS; ++i) {
        if (q->slots[i].key != key || q->slots[i].ticket != ticket) continue;
        *frame = q->slots[i];
        q->bytes -= frame->bytes;
        --q->count;
        memset(&q->slots[i], 0, sizeof(q->slots[i]));
        return true;
    }
    return false;
}

static inline void *madeira_surface_invalidate(madeira_surface_queue *q, uintptr_t key) {
    for (unsigned i = 0; i < MADEIRA_SURFACE_SLOTS; ++i) {
        if (q->slots[i].key != key || !key) continue;
        madeira_surface_frame frame;
        if (madeira_surface_take(q, key, q->slots[i].ticket, &frame)) return frame.payload;
    }
    return NULL;
}
#endif
