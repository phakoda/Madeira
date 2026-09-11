#include "../app/Madeira/Winios/SurfaceQueue.h"
#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
static unsigned checks;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr,"line %d: %s\n",__LINE__,#x); abort(); } } while(0)
static madeira_surface_frame frame(uintptr_t key, uintptr_t value, size_t bytes) {
    return (madeira_surface_frame){.key=key,.payload=(void *)value,.bytes=bytes,.width=64,.height=64,.stride=256};
}
int main(void) {
    size_t bytes = 99;
    CHECK(madeira_surface_layout(1920,1080,7680,&bytes) && bytes == 8294400);
    CHECK(madeira_surface_layout(3,2,16,&bytes) && bytes == 32); // padded rows
    CHECK(!madeira_surface_layout(0,1,4,&bytes));
    CHECK(!madeira_surface_layout(1,-1,4,&bytes));
    CHECK(!madeira_surface_layout(10,10,36,&bytes));
    CHECK(!madeira_surface_layout(10,10,-40,&bytes));
    CHECK(!madeira_surface_layout(INT_MAX,INT_MAX,INT_MAX,&bytes));
    CHECK(!madeira_surface_layout(10,10,41,&bytes));
    CHECK(!madeira_surface_layout(16384,16384,65536,&bytes));
    CHECK(!madeira_surface_layout(1,1,4,NULL));
    madeira_surface_queue q = {0}; void *retired; uint64_t ticket, first;
    CHECK(madeira_surface_push(&q,frame(1,1,16384),&retired,&ticket));
    CHECK(ticket != 0 && retired == NULL); first = ticket;
    for (uintptr_t n=2; n<=10000; ++n) {
        CHECK(madeira_surface_push(&q,frame(1,n,16384),&retired,&ticket));
        CHECK(!ticket && retired == (void *)(n-1) && q.count == 1 && q.bytes == 16384);
    }
    madeira_surface_frame result;
    CHECK(madeira_surface_take(&q,1,first,&result));
    CHECK(result.payload == (void *)10000 && !q.count && !q.bytes);
    CHECK(!madeira_surface_take(&q,1,first,&result));
    CHECK(madeira_surface_push(&q,frame(1,10,16),&retired,&ticket)); first=ticket;
    CHECK(madeira_surface_invalidate(&q,1)==(void *)10);
    CHECK(madeira_surface_push(&q,frame(1,11,16),&retired,&ticket));
    CHECK(ticket != first && !madeira_surface_take(&q,1,first,&result));
    CHECK(madeira_surface_take(&q,1,ticket,&result) && result.payload == (void *)11);
    for (unsigned i=1;i<=MADEIRA_SURFACE_SLOTS;++i)
        CHECK(madeira_surface_push(&q,frame(i,i,8),&retired,&ticket));
    CHECK(!madeira_surface_push(&q,frame(65,65,8),&retired,&ticket));
    CHECK(!ticket && retired==NULL && q.count==64);
    for (unsigned i=1;i<=64;++i) CHECK(madeira_surface_invalidate(&q,i)==(void *)(uintptr_t)i);
    CHECK(!q.bytes && !q.count);
    CHECK(madeira_surface_push(&q,frame(1,1,MADEIRA_SURFACE_BYTES),&retired,&ticket));
    CHECK(!madeira_surface_push(&q,frame(2,2,1),&retired,&ticket));
    CHECK(madeira_surface_push(&q,frame(1,2,4),&retired,&ticket) && retired==(void *)1);
    CHECK(q.bytes==4 && q.count==1);
    CHECK(madeira_surface_invalidate(&q,1)==(void *)2);
    q.next_ticket=UINT64_MAX;
    CHECK(!madeira_surface_push(&q,frame(1,1,4),&retired,&ticket));
    CHECK(!madeira_surface_push(&q,frame(0,1,4),&retired,&ticket));
    CHECK(!madeira_surface_push(&q,frame(1,0,4),&retired,&ticket));
    printf("Surface layout/mailbox: %u checks passed\n",checks);
}
