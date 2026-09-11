/* Production scheduling/layout policy; this does not run Core Animation. */
#include <assert.h>
#include <stdint.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include "../app/Madeira/Winios/CursorMailbox.h"
static unsigned long checks;
#define CHECK(x) do { ++checks; assert(x); } while (0)
static madeira_cursor_mailbox threaded;
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static unsigned counter, wakeups;
static void *publish_many(void *ctx) {
    (void)ctx;
    for (unsigned i = 0; i < 25000; ++i) {
        pthread_mutex_lock(&mutex);
        int value = (int)++counter;
        if (madeira_cursor_publish(&threaded, value, -value, false)) ++wakeups;
        pthread_mutex_unlock(&mutex);
    }
    return NULL;
}
int main(void) {
    madeira_cursor_mailbox q = {0}; int x = 0, y = 0;
    CHECK(!madeira_cursor_take(&q, true, &x, &y));
    CHECK(madeira_cursor_publish(&q, 1, 2, false));
    for (int i = 2; i < 100000; ++i) CHECK(!madeira_cursor_publish(&q, i, -i, false));
    CHECK(q.scheduled && madeira_cursor_take(&q, true, &x, &y));
    CHECK(x == 99999 && y == -99999 && !q.scheduled);
    CHECK(!madeira_cursor_take(&q, true, &x, &y));
    CHECK(madeira_cursor_publish(&q, 10, 20, false));
    CHECK(!madeira_cursor_publish(&q, 30, 40, true));
    CHECK(madeira_cursor_take(&q, false, &x, &y) && x == 30 && y == 40 && q.scheduled);
    CHECK(!madeira_cursor_take(&q, true, &x, &y)); // old queued task cannot restore 10,20
    CHECK(!q.scheduled && x == 30 && y == 40);
    CHECK(madeira_cursor_publish(&q, 50, 60, false));
    CHECK(!madeira_cursor_publish(&q, 70, 80, true));
    CHECK(madeira_cursor_take(&q, false, &x, &y));
    CHECK(!madeira_cursor_publish(&q, 90, 100, false)); // old wake-up is still pending
    CHECK(madeira_cursor_take(&q, true, &x, &y) && x == 90 && y == 100);
    CHECK(!madeira_cursor_publish(&q, INT_MIN, INT_MAX, true));
    CHECK(madeira_cursor_take(&q, false, &x, &y) && x == INT_MIN && y == INT_MAX);
    size_t bytes = 0;
    CHECK(!madeira_cursor_layout(1, 1, NULL));
    CHECK(!madeira_cursor_layout(-1, 16, &bytes));
    CHECK(!madeira_cursor_layout(16, 0, &bytes));
    CHECK(!madeira_cursor_layout(INT_MAX, INT_MAX, &bytes));
    CHECK(!madeira_cursor_layout(1025, 1, &bytes));
    CHECK(!madeira_cursor_layout(1, 1025, &bytes));
    for (int w = 1; w <= 1024; ++w) {
        CHECK(madeira_cursor_layout(w, 1024, &bytes) && bytes == (size_t)w * 4096);
        CHECK(madeira_cursor_layout(1024, w, &bytes) && bytes == (size_t)w * 4096);
    }
    pthread_t workers[8];
    for (unsigned i = 0; i < 8; ++i) CHECK(!pthread_create(&workers[i], NULL, publish_many, NULL));
    for (unsigned i = 0; i < 8; ++i) CHECK(!pthread_join(workers[i], NULL));
    CHECK(counter == 200000 && wakeups == 1);
    CHECK(madeira_cursor_take(&threaded, true, &x, &y) && x == 200000 && y == -200000);
    printf("Cursor mailbox: %lu checks passed (200,000 concurrent publishes; one pending UI wake-up)\n", checks);
    return 0;
}
