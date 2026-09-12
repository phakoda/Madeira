#ifndef MADEIRA_GUEST_MEMORY32_H
#define MADEIRA_GUEST_MEMORY32_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Process-owned software address space. Guest addresses are never host pointers.
 * This service does not enable the existing Wine/FEX runtime's 32-bit mode.
 * All access must use these functions. Host VM protections do not enforce guest
 * permissions. No executable host memory or JIT allocation is used here. */
typedef struct gm32_space gm32_space;
typedef uint32_t gm32_address;

enum { GM32_PAGE_SIZE = 4096, GM32_ALLOCATION_GRANULARITY = 65536 };
enum { GM32_READ = 1, GM32_WRITE = 2, GM32_EXECUTE = 4 };

typedef enum gm32_status {
    GM32_OK = 0,
    GM32_INVALID_ARGUMENT,
    GM32_INVALID_RANGE,
    GM32_MISALIGNED,
    GM32_CONFLICT,
    GM32_UNRESERVED,
    GM32_UNCOMMITTED,
    GM32_ACCESS_DENIED,
    GM32_NO_MEMORY,
    GM32_NONCONTIGUOUS,
    GM32_INTERNAL_ERROR
} gm32_status;

/* For access failures address identifies the first invalid guest byte/page.
 * These are memory-service results, not delivered Windows exceptions. */
typedef struct gm32_result {
    gm32_status status;
    gm32_address address;
    unsigned access;
} gm32_result;

typedef struct gm32_page_info {
    gm32_address allocation_base;
    uint64_t allocation_size;
    unsigned permissions;
    int committed;
} gm32_page_info;

/* max_committed_bytes is a page-aligned backing budget, excluding metadata.
 * Zero permits reservations but no commits. A 64-bit host is required.
 * Destroy only after all callers have stopped; it is not a cancellation API. */
gm32_result gm32_create(uint64_t max_committed_bytes, gm32_space **out);
void gm32_destroy(gm32_space *space);

/* A zero preferred base chooses the first free 64 KiB-aligned range. An explicit
 * base must be 64 KiB-aligned. Sizes are nonzero multiples of 4 KiB. The low
 * 64 KiB stays unavailable. Output arguments are unchanged on failure.
 * Release requires an exact allocation base and frees that entire reservation. */
gm32_result gm32_reserve(gm32_space *, gm32_address preferred, uint64_t size,
                         gm32_address *out);
gm32_result gm32_release(gm32_space *, gm32_address allocation_base);

/* Mapping ranges must be page-aligned and wholly within one reservation.
 * Commit allocates zeroed backing only for new pages; recommit preserves both
 * contents and permissions of existing pages. Use protect to change permissions.
 * Permissions=0 means committed/no-access. Decommit is idempotent inside a
 * reservation; recommitting decommitted pages yields zeros.
 * Failures leave mappings, permissions and contents unchanged. */
gm32_result gm32_commit(gm32_space *, gm32_address, uint64_t size, unsigned permissions);
gm32_result gm32_protect(gm32_space *, gm32_address, uint64_t size, unsigned permissions);
gm32_result gm32_decommit(gm32_space *, gm32_address, uint64_t size);
gm32_result gm32_query(gm32_space *, gm32_address, gm32_page_info *out);

/* Each operation validates the entire span before copying. Spans may cross
 * pages and adjacent reservations, but must not wrap past 0x100000000.
 * Zero-size copies succeed without dereferencing a buffer or guest address.
 * CPU effective-address wrapping must happen before entering this API.
 * Fetch checks EXECUTE, independently of READ. Caller-owned buffers must be
 * valid for size bytes and must not alias guest backing. */
gm32_result gm32_read(gm32_space *, gm32_address, void *destination, size_t size);
gm32_result gm32_write(gm32_space *, gm32_address, const void *source, size_t size);
gm32_result gm32_fetch(gm32_space *, gm32_address, void *destination, size_t size);

/* Little-endian 1/2/4/8-byte CAS, including unaligned and cross-page operands.
 * It is serialized with every other service operation. Expected/desired must
 * fit the width. On success observed receives the old value and exchanged says
 * whether desired was stored. Both READ and WRITE permissions are required.
 * This does not supply FEX's full atomic instruction or memory-ordering backend. */
gm32_result gm32_compare_exchange(gm32_space *, gm32_address, size_t width,
                                  uint64_t expected, uint64_t desired,
                                  uint64_t *observed, int *exchanged);

typedef struct gm32_span {
    gm32_address address;
    size_t size;
    const unsigned char *bytes;
    unsigned char *writable_bytes; /* NULL unless WRITE was requested. */
} gm32_span;
typedef void (*gm32_span_visitor)(const gm32_span *, void *context);

/* Synchronous native access to a nonempty span within ONE guest page. Valid
 * larger spans return NONCONTIGUOUS, never an implicit staging buffer. Range,
 * mapping and permission errors take precedence over contiguity. The callback
 * runs with the space locked: it must not reenter this space, wait for another
 * user of it, throw a C++ exception, or retain the pointer. Use checked copies
 * for longer buffers. Asynchronous native calls need a separate lifetime and
 * marshaling design. All writers, including callbacks, share the CAS lock. */
gm32_result gm32_with_span(gm32_space *, gm32_address, size_t size, unsigned access,
                           gm32_span_visitor, void *context);

#ifdef __cplusplus
}
#endif
#endif
