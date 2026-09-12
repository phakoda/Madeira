#include "../app/Madeira/GuestMemory32.h"

#include <array>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <future>
#include <memory>
#include <new>
#include <thread>
#include <vector>

// Deterministically fail each allocation made during a commit. Other tests run
// with injection disabled. This exercises the actual production allocator path.
static std::atomic<long> failAfter{-1};
void *operator new(std::size_t size) {
    long left = failAfter.load();
    if (left >= 0 && failAfter.fetch_sub(1) == 0) throw std::bad_alloc();
    if (void *p = std::malloc(size ? size : 1)) return p;
    throw std::bad_alloc();
}
void operator delete(void *p) noexcept { std::free(p); }
void operator delete(void *p, std::size_t) noexcept { std::free(p); }

#define CHECK(condition) do { if (!(condition)) { \
    std::fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); std::abort(); \
} } while (0)
#define OK(expression) CHECK((expression).status == GM32_OK)
#define STATUS(expression, code) CHECK((expression).status == (code))

using Space = std::unique_ptr<gm32_space, decltype(&gm32_destroy)>;
constexpr uint32_t Base = 0x00400000;
constexpr uint64_t Limit = UINT64_C(1) << 32;
constexpr unsigned RW = GM32_READ | GM32_WRITE;

static Space makeSpace(uint64_t budget = 16 * GM32_PAGE_SIZE) {
    gm32_space *space = nullptr;
    OK(gm32_create(budget, &space));
    return Space(space, &gm32_destroy);
}

static void reserve(gm32_space *s, uint32_t address, uint64_t size) {
    uint32_t actual = 0;
    OK(gm32_reserve(s, address, size, &actual));
    CHECK(actual == address);
}

static unsigned char readByte(gm32_space *s, uint32_t address) {
    unsigned char value = 0;
    OK(gm32_read(s, address, &value, 1));
    return value;
}

static void reservationsAndLimits() {
    auto s = makeSpace(0);
    uint32_t out = 123;
    STATUS(gm32_reserve(s.get(), Base, 0, &out), GM32_INVALID_RANGE);
    CHECK(out == 123);
    STATUS(gm32_reserve(s.get(), Base + 4096, 4096, &out), GM32_MISALIGNED);
    STATUS(gm32_reserve(s.get(), Base, 4095, &out), GM32_MISALIGNED);
    STATUS(gm32_reserve(s.get(), 0xffff0000, 0x11000, &out), GM32_INVALID_RANGE);
    reserve(s.get(), Base, 0x20000);
    STATUS(gm32_reserve(s.get(), Base, 4096, &out), GM32_CONFLICT);
    STATUS(gm32_reserve(s.get(), Base + 0x10000, 0x20000, &out), GM32_CONFLICT);
    STATUS(gm32_reserve(s.get(), Base - 0x10000, 0x20000, &out), GM32_CONFLICT);
    STATUS(gm32_release(s.get(), Base + 4096), GM32_UNRESERVED);
    STATUS(gm32_commit(s.get(), Base, 4096, RW), GM32_NO_MEMORY);
    OK(gm32_release(s.get(), Base));
    STATUS(gm32_release(s.get(), Base), GM32_UNRESERVED);
    OK(gm32_reserve(s.get(), 0, 4096, &out));
    CHECK(out == 0x10000);
    OK(gm32_reserve(s.get(), 0, 4096, &out));
    CHECK(out == 0x20000);
    OK(gm32_release(s.get(), 0x10000));
    OK(gm32_reserve(s.get(), 0, 4096, &out));
    CHECK(out == 0x10000);

    auto full = makeSpace(0);
    reserve(full.get(), 0x10000, Limit - 0x10000);
    STATUS(gm32_reserve(full.get(), 0, 4096, &out), GM32_NO_MEMORY);
    gm32_page_info info{};
    OK(gm32_query(full.get(), UINT32_MAX, &info));
    CHECK(info.allocation_size == Limit - 0x10000 && !info.committed);
    STATUS(gm32_query(full.get(), 0, &info), GM32_UNRESERVED);
    OK(gm32_release(full.get(), 0x10000));

    auto high = makeSpace();
    reserve(high.get(), 0xffff0000, 0x10000);
    OK(gm32_commit(high.get(), 0xfffff000, 4096, RW));
    const unsigned char byte = 0x7b;
    OK(gm32_write(high.get(), UINT32_MAX, &byte, 1));
    CHECK(readByte(high.get(), UINT32_MAX) == byte);
    unsigned char output[2] = {5, 6};
    STATUS(gm32_read(high.get(), UINT32_MAX, output, 2), GM32_INVALID_RANGE);
    CHECK(output[0] == 5 && output[1] == 6);
    STATUS(gm32_write(high.get(), UINT32_MAX, output, 2), GM32_INVALID_RANGE);
    CHECK(readByte(high.get(), UINT32_MAX) == byte);
    STATUS(gm32_read(high.get(), Base, output, SIZE_MAX), GM32_INVALID_RANGE);
    STATUS(gm32_commit(high.get(), 0xfffff000, 8192, RW), GM32_INVALID_RANGE);
    OK(gm32_read(high.get(), UINT32_MAX, nullptr, 0));
    OK(gm32_write(high.get(), 0, nullptr, 0));
}

static void permissionsAndCopies() {
    auto s = makeSpace();
    reserve(s.get(), Base, 4 * 4096);
    std::array<unsigned char, 8192> bytes{};
    std::array<unsigned char, 8192> output{};
    for (size_t i = 0; i < bytes.size(); ++i) bytes[i] = static_cast<unsigned char>(i * 7 + 3);
    STATUS(gm32_read(s.get(), Base, output.data(), 1), GM32_UNCOMMITTED);
    OK(gm32_commit(s.get(), Base, 3 * 4096, RW));
    OK(gm32_read(s.get(), Base, output.data(), output.size()));
    for (auto b : output) CHECK(b == 0);
    OK(gm32_write(s.get(), Base + 4000, bytes.data(), bytes.size()));
    OK(gm32_read(s.get(), Base + 4000, output.data(), output.size()));
    CHECK(bytes == output);

    OK(gm32_protect(s.get(), Base + 4096, 4096, GM32_READ));
    const unsigned char before = readByte(s.get(), Base + 4095);
    auto fault = gm32_write(s.get(), Base + 4095, bytes.data(), 2);
    CHECK(fault.status == GM32_ACCESS_DENIED && fault.address == Base + 4096 && fault.access == GM32_WRITE);
    CHECK(readByte(s.get(), Base + 4095) == before);
    STATUS(gm32_protect(s.get(), Base, 4 * 4096, GM32_EXECUTE), GM32_UNCOMMITTED);
    // A failed protect cannot change earlier pages.
    OK(gm32_write(s.get(), Base, bytes.data(), 1));
    STATUS(gm32_fetch(s.get(), Base, output.data(), 1), GM32_ACCESS_DENIED);

    OK(gm32_protect(s.get(), Base, 2 * 4096, GM32_EXECUTE));
    OK(gm32_fetch(s.get(), Base + 4095, output.data(), 2));
    CHECK(output[0] == bytes[95] && output[1] == bytes[96]);
    output.fill(0xdd);
    STATUS(gm32_read(s.get(), Base, output.data(), output.size()), GM32_ACCESS_DENIED);
    for (auto b : output) CHECK(b == 0xdd);
    OK(gm32_protect(s.get(), Base + 4096, 4096, 0));
    output.fill(0xee);
    fault = gm32_fetch(s.get(), Base + 4095, output.data(), 2);
    CHECK(fault.status == GM32_ACCESS_DENIED && fault.address == Base + 4096);
    CHECK(output[0] == 0xee && output[1] == 0xee);
    gm32_page_info info{};
    OK(gm32_query(s.get(), Base + 4096, &info));
    CHECK(info.committed && info.permissions == 0);
    STATUS(gm32_protect(s.get(), Base, 4096, 8), GM32_INVALID_ARGUMENT);
    STATUS(gm32_commit(s.get(), Base, 4096, 8), GM32_INVALID_ARGUMENT);
    STATUS(gm32_commit(s.get(), Base + 1, 4096, RW), GM32_MISALIGNED);
    STATUS(gm32_decommit(s.get(), Base + 3 * 4096, 8192), GM32_UNRESERVED);
    STATUS(gm32_read(s.get(), Base, nullptr, 1), GM32_INVALID_ARGUMENT);
    STATUS(gm32_read(nullptr, Base, output.data(), 1), GM32_INVALID_ARGUMENT);
}

static void recommitAndIsolation() {
    auto s = makeSpace(4 * 4096);
    auto other = makeSpace();
    reserve(s.get(), Base, 4 * 4096);
    reserve(other.get(), Base, 4096);
    OK(gm32_commit(s.get(), Base, 4 * 4096, RW));
    OK(gm32_commit(other.get(), Base, 4096, RW));
    const unsigned char value = 0xa7;
    for (unsigned i = 0; i < 4; ++i) OK(gm32_write(s.get(), Base + i * 4096, &value, 1));
    CHECK(readByte(other.get(), Base) == 0);
    OK(gm32_protect(s.get(), Base, 4096, GM32_READ));
    OK(gm32_commit(s.get(), Base, 4096, RW));
    STATUS(gm32_write(s.get(), Base, &value, 1), GM32_ACCESS_DENIED);
    CHECK(readByte(s.get(), Base) == value);
    OK(gm32_decommit(s.get(), Base + 4096, 4096));
    OK(gm32_decommit(s.get(), Base + 4096, 4096));
    CHECK(readByte(s.get(), Base) == value && readByte(s.get(), Base + 8192) == value);
    CHECK(readByte(s.get(), Base + 12288) == value);
    OK(gm32_commit(s.get(), Base + 4096, 4096, RW));
    CHECK(readByte(s.get(), Base + 4096) == 0);
    OK(gm32_release(s.get(), Base));
    reserve(s.get(), Base, 4 * 4096);
    OK(gm32_commit(s.get(), Base, 4 * 4096, RW));
    CHECK(readByte(s.get(), Base) == 0);
}

static void adjacentReservations() {
    auto s = makeSpace();
    reserve(s.get(), Base, 0x10000);
    reserve(s.get(), Base + 0x10000, 0x10000);
    uint32_t boundary = Base + 0x10000;
    STATUS(gm32_commit(s.get(), boundary - 4096, 8192, RW), GM32_UNRESERVED);
    OK(gm32_commit(s.get(), boundary - 4096, 4096, RW));
    OK(gm32_commit(s.get(), boundary, 4096, RW));
    const unsigned char bytes[2] = {0x12, 0x34};
    OK(gm32_write(s.get(), boundary - 1, bytes, 2));
    unsigned char output[2]{};
    OK(gm32_read(s.get(), boundary - 1, output, 2));
    CHECK(std::memcmp(bytes, output, 2) == 0);
    OK(gm32_release(s.get(), Base));
    output[0] = output[1] = 0xff;
    STATUS(gm32_read(s.get(), boundary - 1, output, 2), GM32_UNRESERVED);
    CHECK(output[0] == 0xff && output[1] == 0xff);
    CHECK(readByte(s.get(), boundary) == 0x34);
}

static void allocationRollback() {
    // Budget rejection must not partially commit an earlier page.
    auto limited = makeSpace(4096);
    reserve(limited.get(), Base, 8192);
    STATUS(gm32_commit(limited.get(), Base, 8192, RW), GM32_NO_MEMORY);
    unsigned char byte = 1;
    STATUS(gm32_read(limited.get(), Base, &byte, 1), GM32_UNCOMMITTED);
    OK(gm32_commit(limited.get(), Base, 4096, RW));

    bool reachedSuccess = false;
    for (long fail = 0; fail < 32; ++fail) {
        auto s = makeSpace(3 * 4096);
        // New commit crosses a top-level page-table boundary and allocates
        // both a leaf and data pages, while one existing page must survive.
        reserve(s.get(), 0x3f0000, 0x20000);
        OK(gm32_commit(s.get(), 0x3fe000, 4096, RW));
        const unsigned char marker = 0x77;
        OK(gm32_write(s.get(), 0x3fe000, &marker, 1));
        failAfter.store(fail);
        auto r = gm32_commit(s.get(), 0x3fe000, 3 * 4096, RW);
        failAfter.store(-1);
        CHECK(readByte(s.get(), 0x3fe000) == marker);
        if (r.status == GM32_OK) { reachedSuccess = true; break; }
        CHECK(r.status == GM32_NO_MEMORY);
        gm32_page_info info{};
        OK(gm32_query(s.get(), 0x3ff000, &info));
        CHECK(!info.committed);
        OK(gm32_query(s.get(), 0x400000, &info));
        CHECK(!info.committed);
        OK(gm32_commit(s.get(), 0x3ff000, 8192, RW));
        CHECK(readByte(s.get(), 0x400000) == 0);
    }
    CHECK(reachedSuccess);
}

static void nativeSpansAndAtomics() {
    auto s = makeSpace();
    reserve(s.get(), Base, 8192);
    OK(gm32_commit(s.get(), Base, 8192, RW));
    int visits = 0;
    auto visitor = [](const gm32_span *span, void *context) {
        ++*static_cast<int *>(context);
        CHECK(span->address == Base + 7 && span->size == 3);
        CHECK(reinterpret_cast<uintptr_t>(span->bytes) != span->address);
        CHECK(span->writable_bytes != nullptr);
        std::memset(span->writable_bytes, 0xa5, span->size);
    };
    OK(gm32_with_span(s.get(), Base + 7, 3, RW, visitor, &visits));
    CHECK(visits == 1 && readByte(s.get(), Base + 8) == 0xa5);
    STATUS(gm32_with_span(s.get(), Base + 4095, 2, RW, visitor, &visits), GM32_NONCONTIGUOUS);
    STATUS(gm32_with_span(s.get(), Base, 1, 8, visitor, &visits), GM32_INVALID_ARGUMENT);
    STATUS(gm32_with_span(s.get(), Base, 0, RW, visitor, &visits), GM32_INVALID_ARGUMENT);
    CHECK(visits == 1);
    OK(gm32_with_span(s.get(), Base + 7, 1, GM32_READ,
        [](const gm32_span *span, void *) {
            CHECK(!span->writable_bytes && span->bytes[0] == 0xa5);
        }, nullptr));

    for (size_t width : {size_t(1), size_t(2), size_t(4), size_t(8)}) {
        uint64_t observed = 0;
        int exchanged = 0;
        unsigned char zeros[8]{};
        OK(gm32_write(s.get(), Base + 4095, zeros, 8));
        OK(gm32_compare_exchange(s.get(), Base + 4095, width, 0, 0x7f, &observed, &exchanged));
        CHECK(exchanged && observed == 0);
        OK(gm32_compare_exchange(s.get(), Base + 4095, width, 0, 0x11, &observed, &exchanged));
        CHECK(!exchanged && observed == 0x7f);
    }
    uint64_t observed = 0;
    int exchanged = 0;
    OK(gm32_compare_exchange(s.get(), Base + 4095, 8, 0x7f, UINT64_C(0x8877665544332211), &observed, &exchanged));
    CHECK(exchanged);
    CHECK(readByte(s.get(), Base + 4095) == 0x11 && readByte(s.get(), Base + 4102) == 0x88);
    STATUS(gm32_compare_exchange(s.get(), Base, 3, 0, 1, &observed, &exchanged), GM32_INVALID_ARGUMENT);
    STATUS(gm32_compare_exchange(s.get(), Base, 1, 0, 256, &observed, &exchanged), GM32_INVALID_ARGUMENT);
    OK(gm32_protect(s.get(), Base + 4096, 4096, GM32_READ));
    STATUS(gm32_compare_exchange(s.get(), Base + 4095, 8, UINT64_C(0x8877665544332211), 0,
                                &observed, &exchanged), GM32_ACCESS_DENIED);
    CHECK(readByte(s.get(), Base + 4095) == 0x11);
}

static void concurrentAtomicsAndCopies() {
    auto s = makeSpace();
    reserve(s.get(), Base, 8192);
    OK(gm32_commit(s.get(), Base, 8192, RW));
    const uint32_t counter = Base + 4093; // unaligned, spanning separate backing pages
    std::vector<std::thread> workers;
    for (int thread = 0; thread < 4; ++thread) {
        workers.emplace_back([&] {
            for (int i = 0; i < 1000; ++i) {
                uint64_t expected = 0;
                for (;;) {
                    uint64_t observed;
                    int exchanged;
                    OK(gm32_compare_exchange(s.get(), counter, 8, expected, expected + 1, &observed, &exchanged));
                    if (exchanged) break;
                    expected = observed;
                }
            }
        });
    }
    for (auto &worker : workers) worker.join();
    uint64_t observed;
    int exchanged;
    OK(gm32_compare_exchange(s.get(), counter, 8, 4000, 0, &observed, &exchanged));
    CHECK(exchanged && observed == 4000);

    // Whole multi-page operations must not tear against another service caller.
    std::atomic<bool> done{false};
    std::thread writer([&] {
        std::array<unsigned char, 8192> data;
        for (int i = 0; i < 1000; ++i) {
            data.fill((i & 1) ? 0xaa : 0x55);
            OK(gm32_write(s.get(), Base, data.data(), data.size()));
        }
        done.store(true);
    });
    do {
        std::array<unsigned char, 8192> data{};
        OK(gm32_read(s.get(), Base, data.data(), data.size()));
        for (auto byte : data) CHECK(byte == data[0]);
    } while (!done.load());
    writer.join();
}

static void nativeSpanLifetime() {
    auto s = makeSpace();
    reserve(s.get(), Base, 4096);
    OK(gm32_commit(s.get(), Base, 4096, RW));
    const unsigned char marker = 0x93;
    OK(gm32_write(s.get(), Base, &marker, 1));
    struct Context {
        gm32_space *space;
        std::atomic<bool> entered{false};
        std::promise<gm32_result> completed;
        std::future<gm32_result> completion = completed.get_future();
        std::thread worker;
        explicit Context(gm32_space *s) : space(s) {}
    } context(s.get());
    OK(gm32_with_span(s.get(), Base, 1, GM32_READ,
        [](const gm32_span *span, void *opaque) {
            auto &c = *static_cast<Context *>(opaque);
            c.worker = std::thread([&c] {
                c.entered.store(true);
                c.completed.set_value(gm32_decommit(c.space, Base, 4096));
            });
            while (!c.entered.load()) std::this_thread::yield();
            CHECK(c.completion.wait_for(std::chrono::milliseconds(50)) == std::future_status::timeout);
            CHECK(span->bytes[0] == 0x93);
        }, &context));
    context.worker.join();
    OK(context.completion.get());
    unsigned char value = 0;
    STATUS(gm32_read(s.get(), Base, &value, 1), GM32_UNCOMMITTED);
}

int main() {
    reservationsAndLimits();
    permissionsAndCopies();
    recommitAndIsolation();
    adjacentReservations();
    allocationRollback();
    nativeSpansAndAtomics();
    concurrentAtomicsAndCopies();
    nativeSpanLifetime();
    std::puts("GuestMemory32 tests passed");
}
