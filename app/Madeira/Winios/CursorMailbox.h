/* Latest cursor position, with at most one queued UI wake-up. Callers hold
 * their own mutex; only the UI thread takes positions. No allocation/SDK.
 * GPL-3.0-or-later. */
#ifndef MADEIRA_CURSOR_MAILBOX_H
#define MADEIRA_CURSOR_MAILBOX_H
#include <stdbool.h>
#include <stddef.h>

typedef struct {
    int x, y;
    bool dirty, scheduled;
} madeira_cursor_mailbox;

/* On the main thread, publish then take inline WITHOUT retiring a queued task.
 * Otherwise a background publish could enqueue another task while the old task
 * was still waiting. A queued task always reads the latest point, never a point
 * captured in its block before a newer inline update. */
static inline bool madeira_cursor_publish(madeira_cursor_mailbox *q, int x, int y, bool on_main) {
    q->x = x; q->y = y; q->dirty = true;
    if (on_main || q->scheduled) return false;
    q->scheduled = true;
    return true;
}
static inline bool madeira_cursor_take(madeira_cursor_mailbox *q, bool queued_task, int *x, int *y) {
    if (queued_task) q->scheduled = false;
    if (!q->dirty) return false;
    *x = q->x; *y = q->y; q->dirty = false;
    return true;
}

/* A cursor is not a desktop surface. Bound image allocation to 4 MiB and check
 * dimensions before calculating its stride or byte count. */
static inline bool madeira_cursor_layout(int w, int h, size_t *bytes) {
    if (!bytes || w <= 0 || h <= 0 || w > 1024 || h > 1024) return false;
    *bytes = (size_t)w * (size_t)h * 4;
    return true;
}
#endif
