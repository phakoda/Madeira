/* Bounded guest input queue. Callers serialize push/pop with their own lock.
 * Kept free of UIKit/Wine dependencies so the production algorithm is tested.
 * Copyright (c) 2026 Madeira contributors. GPL-3.0-or-later. */
#ifndef MADEIRA_INPUT_QUEUE_H
#define MADEIRA_INPUT_QUEUE_H
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <limits.h>

#define WINIOS_RING_SIZE 256u
#define WINIOS_EV_MOUSE 0u
#define WINIOS_EV_KEY   1u
#define WINIOS_KEYUP    0x0002u
#define WINIOS_MOVE     0x0001u
#define WINIOS_ABSOLUTE 0x8000u

typedef struct {
    unsigned int type;
    int x, y;
    unsigned int flags, data;
} winios_input_event_t;

typedef struct {
    winios_input_event_t buf[WINIOS_RING_SIZE];
    unsigned head, count;
    uint8_t desired_keys[256], delivered_keys[256], sync_keys[256];
    unsigned desired_buttons, delivered_buttons, sync_buttons;
    bool sync_pending;
    unsigned sync_cursor;
    uint64_t coalesced, dropped_motion, resyncs;
} madeira_input_queue;

static inline bool madeira_input_is_motion(winios_input_event_t e) {
    return e.type == WINIOS_EV_MOUSE && e.data == 0 &&
           (e.flags == WINIOS_MOVE || e.flags == (WINIOS_MOVE | WINIOS_ABSOLUTE));
}

static inline void madeira_input_update_state(uint8_t keys[256], unsigned *buttons,
                                              winios_input_event_t e) {
    if (e.type == WINIOS_EV_KEY) {
        if (e.x > 0 && e.x < 256) keys[e.x] = !(e.flags & WINIOS_KEYUP);
        return;
    }
    static const unsigned down[] = {0x2, 0x8, 0x20, 0x80, 0x80};
    static const unsigned up[]   = {0x4, 0x10, 0x40, 0x100, 0x100};
    for (unsigned i = 0; i < 5; ++i) {
        if (i >= 3 && !(e.data & (1u << (i - 3)))) continue;
        if (e.flags & down[i]) *buttons |= 1u << i;
        if (e.flags & up[i]) *buttons &= ~(1u << i);
    }
}

/* Overflow of a transition-only queue cannot preserve every historical tap
 * without blocking the UI or allocating without bound. Reconcile to a snapshot
 * of the latest physical state instead. A dropped release must NEVER leave a
 * guest key/button held forever. Later events remain ordered AFTER this snapshot. */
static inline void madeira_input_resync(madeira_input_queue *q) {
    memcpy(q->sync_keys, q->desired_keys, sizeof(q->sync_keys));
    q->sync_buttons = q->desired_buttons;
    q->head = q->count = q->sync_cursor = 0;
    q->sync_pending = true;
    ++q->resyncs;
}

static inline void madeira_input_release_all(madeira_input_queue *q) {
    memset(q->desired_keys, 0, sizeof(q->desired_keys));
    q->desired_buttons = 0;
    madeira_input_resync(q);
}

static inline void madeira_input_push(madeira_input_queue *q, winios_input_event_t e) {
    if (e.type > WINIOS_EV_KEY ||
        (e.type == WINIOS_EV_KEY && (e.x <= 0 || e.x >= 256))) return;
    madeira_input_update_state(q->desired_keys, &q->desired_buttons, e);

    /* Adjacent motion only: never move a sample across a click/key/wheel edge.
     * Absolute positions replace; relative samples SUM (otherwise slow aiming
     * loses motion). Overflowing sums stay separate, without signed overflow. */
    if (q->count && madeira_input_is_motion(e)) {
        winios_input_event_t *last = &q->buf[(q->head + q->count - 1) % WINIOS_RING_SIZE];
        if (madeira_input_is_motion(*last) && last->flags == e.flags) {
            int64_t x = (int64_t)last->x + e.x, y = (int64_t)last->y + e.y;
            if (e.flags & WINIOS_ABSOLUTE) {
                last->x = e.x; last->y = e.y;
                ++q->coalesced;
                return;
            }
            if (x >= INT_MIN && x <= INT_MAX && y >= INT_MIN && y <= INT_MAX) {
                last->x = (int)x; last->y = (int)y;
                ++q->coalesced;
                return;
            }
        }
    }
    if (q->count == WINIOS_RING_SIZE) {
        /* Prefer discarding expendable motion, never a release. The O(n) move
         * is bounded by 256 and occurs only under pressure, not on the hot path. */
        unsigned i;
        for (i = 0; i < q->count; ++i)
            if (madeira_input_is_motion(q->buf[(q->head + i) % WINIOS_RING_SIZE])) break;
        if (i < q->count) {
            for (; i + 1 < q->count; ++i)
                q->buf[(q->head + i) % WINIOS_RING_SIZE] =
                    q->buf[(q->head + i + 1) % WINIOS_RING_SIZE];
            --q->count;
            ++q->dropped_motion;
        } else if (madeira_input_is_motion(e)) {
            ++q->dropped_motion;
            return;
        } else {
            madeira_input_resync(q);
            return; /* incoming transition is already represented by snapshot */
        }
    }
    q->buf[(q->head + q->count) % WINIOS_RING_SIZE] = e;
    ++q->count;
}

static inline bool madeira_input_pop(madeira_input_queue *q, winios_input_event_t *out) {
    if (q->sync_pending) {
        while (q->sync_cursor < 256) {
            unsigned k = q->sync_cursor++;
            if (q->delivered_keys[k] == q->sync_keys[k]) continue;
            *out = (winios_input_event_t){WINIOS_EV_KEY, (int)k, 0,
                                        q->sync_keys[k] ? 0u : WINIOS_KEYUP, 0};
            q->delivered_keys[k] = q->sync_keys[k];
            return true;
        }
        static const unsigned down[] = {0x2, 0x8, 0x20, 0x80, 0x80};
        static const unsigned up[]   = {0x4, 0x10, 0x40, 0x100, 0x100};
        while (q->sync_cursor < 261) {
            unsigned b = q->sync_cursor++ - 256, bit = 1u << b;
            if (!((q->delivered_buttons ^ q->sync_buttons) & bit)) continue;
            *out = (winios_input_event_t){WINIOS_EV_MOUSE, 0, 0,
                q->sync_buttons & bit ? down[b] : up[b], b >= 3 ? 1u << (b - 3) : 0};
            q->delivered_buttons = (q->delivered_buttons & ~bit) | (q->sync_buttons & bit);
            return true;
        }
        q->sync_pending = false;
    }
    if (!q->count) return false;
    *out = q->buf[q->head];
    q->head = (q->head + 1) % WINIOS_RING_SIZE;
    --q->count;
    madeira_input_update_state(q->delivered_keys, &q->delivered_buttons, *out);
    return true;
}
#endif
