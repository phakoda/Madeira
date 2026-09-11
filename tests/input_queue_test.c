#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include "../app/Madeira/Winios/InputQueue.h"
static unsigned checks;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #x); abort(); } } while (0)
static winios_input_event_t key(int vk, int down) {
    return (winios_input_event_t){WINIOS_EV_KEY, vk, 0, down ? 0u : WINIOS_KEYUP, 0};
}
static void drain(madeira_input_queue *q) {
    winios_input_event_t e; unsigned n = 0;
    while (madeira_input_pop(q, &e)) CHECK(++n <= WINIOS_RING_SIZE + 261);
}
static void coalescing(void) {
    madeira_input_queue q = {0}; winios_input_event_t e;
    for (int i = 0; i < 10000; ++i)
        madeira_input_push(&q, (winios_input_event_t){0, 1, -2, WINIOS_MOVE, 0});
    CHECK(q.count == 1 && q.coalesced == 9999);
    CHECK(madeira_input_pop(&q, &e) && e.x == 10000 && e.y == -20000);
    madeira_input_push(&q, (winios_input_event_t){0, 1, 2, WINIOS_MOVE | WINIOS_ABSOLUTE, 0});
    madeira_input_push(&q, (winios_input_event_t){0, 3, 4, WINIOS_MOVE | WINIOS_ABSOLUTE, 0});
    CHECK(madeira_input_pop(&q, &e) && e.x == 3 && e.y == 4);
    madeira_input_push(&q, (winios_input_event_t){0, INT_MAX, INT_MIN, WINIOS_MOVE, 0});
    madeira_input_push(&q, (winios_input_event_t){0, 1, -1, WINIOS_MOVE, 0});
    CHECK(q.count == 2);
    drain(&q);
}
static void ordering(void) {
    madeira_input_queue q = {0}; winios_input_event_t e;
    madeira_input_push(&q, (winios_input_event_t){0, 1, 0, WINIOS_MOVE, 0});
    madeira_input_push(&q, key(65, 1));
    madeira_input_push(&q, (winios_input_event_t){0, 2, 0, WINIOS_MOVE, 0});
    madeira_input_push(&q, key(65, 0));
    CHECK(q.count == 4);
    CHECK(madeira_input_pop(&q, &e) && e.type == 0 && e.x == 1);
    CHECK(madeira_input_pop(&q, &e) && e.type == 1 && e.flags == 0);
    CHECK(madeira_input_pop(&q, &e) && e.type == 0 && e.x == 2);
    CHECK(madeira_input_pop(&q, &e) && e.type == 1 && e.flags == WINIOS_KEYUP);
    CHECK(!madeira_input_pop(&q, &e));
}
static void overflow(void) {
    madeira_input_queue q = {0}; winios_input_event_t e;
    madeira_input_push(&q, key(65, 1)); drain(&q);
    madeira_input_push(&q, (winios_input_event_t){0, 0, 0, 0x2, 0}); drain(&q);
    for (unsigned i = 0; i < WINIOS_RING_SIZE; ++i) madeira_input_push(&q, key(66, i & 1));
    madeira_input_push(&q, key(65, 0));
    CHECK(q.sync_pending && q.resyncs == 1);
    /* These changes occur AFTER the snapshot and must not be reordered. */
    madeira_input_push(&q, key(67, 1));
    madeira_input_push(&q, (winios_input_event_t){0, 0, 0, 0x4, 0});
    drain(&q);
    CHECK(!q.delivered_keys[65] && q.delivered_keys[66] && q.delivered_keys[67]);
    CHECK(q.delivered_buttons == 0);
    madeira_input_release_all(&q); drain(&q);
    for (unsigned k = 0; k < 256; ++k) CHECK(q.delivered_keys[k] == 0);
    /* When the only expendable item is motion, remove it rather than an edge. */
    madeira_input_push(&q, (winios_input_event_t){0, 1, 1, WINIOS_MOVE, 0});
    for (unsigned i = 1; i < WINIOS_RING_SIZE; ++i) madeira_input_push(&q, key(65, i & 1));
    madeira_input_push(&q, key(65, 0));
    CHECK(q.count == WINIOS_RING_SIZE && q.dropped_motion == 1);
    drain(&q); CHECK(q.delivered_keys[65] == 0);
    madeira_input_push(&q, key(-1, 1)); madeira_input_push(&q, key(256, 1));
    CHECK(!madeira_input_pop(&q, &e));
    /* Both extra mouse buttons and middle button release on deactivation. */
    madeira_input_push(&q, (winios_input_event_t){0, 0, 0, 0x20 | 0x80, 3});
    drain(&q); CHECK(q.delivered_buttons == 28);
    madeira_input_release_all(&q); drain(&q); CHECK(q.delivered_buttons == 0);
}
static uint32_t rng = 0x52613;
static uint32_t next(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }
static void stress(void) {
    madeira_input_queue q = {0}; winios_input_event_t e;
    for (unsigned n = 0; n < 200000; ++n) {
        uint32_t r = next();
        if ((r & 15) == 0) madeira_input_pop(&q, &e);
        else if ((r & 3) == 0)
            madeira_input_push(&q, (winios_input_event_t){0, (int)(r % 1000) - 500, 1, WINIOS_MOVE, 0});
        else madeira_input_push(&q, key(1 + (int)(r % 255), (r >> 20) & 1));
        CHECK(q.count <= WINIOS_RING_SIZE);
    }
    drain(&q);
    CHECK(memcmp(q.desired_keys, q.delivered_keys, 256) == 0);
    CHECK(q.desired_buttons == q.delivered_buttons);
    madeira_input_release_all(&q); drain(&q);
    CHECK(memcmp(q.desired_keys, q.delivered_keys, 256) == 0);
}
int main(void) { coalescing(); ordering(); overflow(); stress(); printf("Input queue: %u checks passed\n", checks); }
