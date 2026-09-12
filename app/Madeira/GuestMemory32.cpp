#include "GuestMemory32.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <new>
#include <vector>

static_assert(sizeof(void *) == 8, "GuestMemory32 requires a 64-bit host");

namespace {
constexpr uint64_t AddressLimit = UINT64_C(1) << 32;
constexpr uint32_t PageMask = GM32_PAGE_SIZE - 1;
constexpr unsigned AllPermissions = GM32_READ | GM32_WRITE | GM32_EXECUTE;
using Bytes = std::array<unsigned char, GM32_PAGE_SIZE>;

struct Page {
    std::unique_ptr<Bytes> bytes;
    unsigned permissions = 0;
};
using Leaf = std::array<Page, 1024>;

gm32_result result(gm32_status status, gm32_address address = 0, unsigned access = 0) {
    return {status, address, access};
}

bool validRange(gm32_address address, uint64_t size) {
    return size <= AddressLimit - address;
}

gm32_result mappingRange(gm32_address address, uint64_t size) {
    if (!size || !validRange(address, size)) return result(GM32_INVALID_RANGE, address);
    if ((address & PageMask) || (size & PageMask)) return result(GM32_MISALIGNED, address);
    return result(GM32_OK);
}
} // namespace

struct gm32_space {
    std::mutex mutex;
    // Intervals describe reserved address space without allocating page tables.
    std::map<gm32_address, uint64_t> reservations;
    // Leaves exist only for committed pages. Backing is ordinary heap memory;
    // 4 KiB software permissions do not depend on the host's VM page size.
    std::array<std::unique_ptr<Leaf>, 1024> leaves;
    uint64_t committed = 0;
    uint64_t budget;

    explicit gm32_space(uint64_t limit) : budget(limit) {}

    Page *page(uint32_t number) {
        auto &leaf = leaves[number >> 10];
        return leaf ? &(*leaf)[number & 1023] : nullptr;
    }

    auto reservation(gm32_address address) {
        auto it = reservations.upper_bound(address);
        if (it == reservations.begin()) return reservations.end();
        --it;
        return uint64_t(address) - it->first < it->second ? it : reservations.end();
    }

    gm32_result reservedRange(gm32_address address, uint64_t size) {
        auto r = mappingRange(address, size);
        if (r.status != GM32_OK) return r;
        auto it = reservation(address);
        if (it == reservations.end()) return result(GM32_UNRESERVED, address);
        const uint64_t end = uint64_t(it->first) + it->second;
        if (uint64_t(address) + size > end)
            return result(GM32_UNRESERVED, static_cast<gm32_address>(end));
        return result(GM32_OK);
    }

    gm32_result check(gm32_address address, uint64_t size, unsigned access) {
        if (!validRange(address, size)) return result(GM32_INVALID_RANGE, address, access);
        const uint64_t end = uint64_t(address) + size;
        for (uint64_t at = address; at < end; at = (at & ~uint64_t(PageMask)) + GM32_PAGE_SIZE) {
            auto guest = static_cast<gm32_address>(at);
            Page *p = page(guest / GM32_PAGE_SIZE);
            if (!p || !p->bytes) {
                return result(reservation(guest) == reservations.end() ? GM32_UNRESERVED : GM32_UNCOMMITTED,
                              guest, access);
            }
            if ((p->permissions & access) != access) return result(GM32_ACCESS_DENIED, guest, access);
        }
        return result(GM32_OK);
    }

    // Caller has checked every page and holds mutex. No allocations below.
    void copy(gm32_address address, void *buffer, size_t size, bool intoGuest) {
        auto *host = static_cast<unsigned char *>(buffer);
        uint64_t at = address;
        while (size) {
            size_t offset = at & PageMask;
            size_t count = std::min(size, size_t(GM32_PAGE_SIZE) - offset);
            auto *backing = page(static_cast<uint32_t>(at / GM32_PAGE_SIZE))->bytes->data() + offset;
            if (intoGuest) std::memcpy(backing, host, count);
            else std::memcpy(host, backing, count);
            at += count;
            host += count;
            size -= count;
        }
    }

    void discard(gm32_address address, uint64_t size) {
        const uint64_t end = uint64_t(address) + size;
        for (uint64_t at = address; at < end; at += GM32_PAGE_SIZE) {
            Page *p = page(static_cast<uint32_t>(at / GM32_PAGE_SIZE));
            if (p && p->bytes) {
                p->bytes.reset();
                p->permissions = 0;
                committed -= GM32_PAGE_SIZE;
            }
        }
        // Release empty leaves too, so repeated sparse commits cannot retain
        // metadata for every region ever touched.
        const size_t first = address >> 22;
        const size_t last = (end - 1) >> 22;
        for (size_t i = first; i <= last; ++i) {
            if (leaves[i] && std::none_of(leaves[i]->begin(), leaves[i]->end(),
                                        [](const Page &p) { return bool(p.bytes); }))
                leaves[i].reset();
        }
    }
};

namespace {
template <typename Operation>
gm32_result locked(gm32_space *space, Operation operation) {
    if (!space) return result(GM32_INVALID_ARGUMENT);
    try {
        std::lock_guard<std::mutex> guard(space->mutex);
        return operation();
    } catch (const std::bad_alloc &) {
        return result(GM32_NO_MEMORY);
    } catch (...) {
        // No C++ exception may cross the C ABI. API misuse by a native visitor
        // can still have changed bytes before throwing; it is not a transaction.
        return result(GM32_INTERNAL_ERROR);
    }
}

gm32_result transfer(gm32_space *space, gm32_address address, void *buffer,
                     size_t size, unsigned access, bool intoGuest) {
    if (size && !buffer) return result(GM32_INVALID_ARGUMENT, address, access);
    return locked(space, [&] {
        auto r = space->check(address, size, access);
        if (r.status == GM32_OK) space->copy(address, buffer, size, intoGuest);
        return r;
    });
}
} // namespace

extern "C" gm32_result gm32_create(uint64_t budget, gm32_space **out) {
    if (!out || budget > AddressLimit || (budget & PageMask)) return result(GM32_INVALID_ARGUMENT);
    try {
        *out = new gm32_space(budget);
        return result(GM32_OK);
    } catch (const std::bad_alloc &) {
        return result(GM32_NO_MEMORY);
    } catch (...) {
        return result(GM32_INTERNAL_ERROR);
    }
}

extern "C" void gm32_destroy(gm32_space *space) { delete space; }

extern "C" gm32_result gm32_reserve(gm32_space *space, gm32_address preferred,
                                    uint64_t size, gm32_address *out) {
    if (!out) return result(GM32_INVALID_ARGUMENT);
    auto r = mappingRange(preferred, size);
    if (r.status != GM32_OK) return r;
    if (preferred % GM32_ALLOCATION_GRANULARITY) return result(GM32_MISALIGNED, preferred);
    return locked(space, [&] {
        uint64_t base = preferred ? preferred : GM32_ALLOCATION_GRANULARITY;
        for (const auto &entry : space->reservations) {
            if (base + size <= entry.first) break;
            if (base < uint64_t(entry.first) + entry.second) {
                if (preferred) return result(GM32_CONFLICT, preferred);
                base = (uint64_t(entry.first) + entry.second + GM32_ALLOCATION_GRANULARITY - 1)
                       & ~uint64_t(GM32_ALLOCATION_GRANULARITY - 1);
            }
        }
        if (base >= AddressLimit || size > AddressLimit - base) return result(GM32_NO_MEMORY);
        space->reservations.emplace(static_cast<gm32_address>(base), size);
        *out = static_cast<gm32_address>(base);
        return result(GM32_OK);
    });
}

extern "C" gm32_result gm32_release(gm32_space *space, gm32_address base) {
    return locked(space, [&] {
        auto it = space->reservations.find(base);
        if (it == space->reservations.end()) return result(GM32_UNRESERVED, base);
        space->discard(base, it->second);
        space->reservations.erase(it);
        return result(GM32_OK);
    });
}

extern "C" gm32_result gm32_commit(gm32_space *space, gm32_address address,
                                   uint64_t size, unsigned permissions) {
    if (permissions & ~AllPermissions) return result(GM32_INVALID_ARGUMENT, address);
    return locked(space, [&] {
        auto r = space->reservedRange(address, size);
        if (r.status != GM32_OK) return r;
        const uint64_t end = uint64_t(address) + size;
        uint64_t needed = 0;
        for (uint64_t at = address; at < end; at += GM32_PAGE_SIZE) {
            Page *p = space->page(static_cast<uint32_t>(at / GM32_PAGE_SIZE));
            if (!p || !p->bytes) needed += GM32_PAGE_SIZE;
        }
        if (needed > space->budget - space->committed) return result(GM32_NO_MEMORY, address);

        struct Pending { uint32_t number; std::unique_ptr<Bytes> bytes; };
        std::vector<Pending> pending;
        std::vector<std::pair<size_t, std::unique_ptr<Leaf>>> newLeaves;
        pending.reserve(static_cast<size_t>(needed / GM32_PAGE_SIZE));
        for (size_t i = address >> 22; i <= (end - 1) >> 22; ++i) {
            if (!space->leaves[i]) newLeaves.emplace_back(i, std::make_unique<Leaf>());
        }
        for (uint64_t at = address; at < end; at += GM32_PAGE_SIZE) {
            const auto number = static_cast<uint32_t>(at / GM32_PAGE_SIZE);
            Page *p = space->page(number);
            if (!p || !p->bytes) pending.push_back({number, std::make_unique<Bytes>()});
        }
        // All allocations succeeded. The following publication cannot throw.
        for (auto &leaf : newLeaves) space->leaves[leaf.first] = std::move(leaf.second);
        for (auto &entry : pending) {
            Page *p = space->page(entry.number);
            p->bytes = std::move(entry.bytes);
            p->permissions = permissions;
        }
        space->committed += needed;
        return result(GM32_OK);
    });
}

extern "C" gm32_result gm32_protect(gm32_space *space, gm32_address address,
                                    uint64_t size, unsigned permissions) {
    if (permissions & ~AllPermissions) return result(GM32_INVALID_ARGUMENT, address);
    return locked(space, [&] {
        auto r = space->reservedRange(address, size);
        if (r.status != GM32_OK) return r;
        r = space->check(address, size, 0);
        if (r.status != GM32_OK) return r;
        const uint64_t end = uint64_t(address) + size;
        for (uint64_t at = address; at < end; at += GM32_PAGE_SIZE)
            space->page(static_cast<uint32_t>(at / GM32_PAGE_SIZE))->permissions = permissions;
        return result(GM32_OK);
    });
}

extern "C" gm32_result gm32_decommit(gm32_space *space, gm32_address address, uint64_t size) {
    return locked(space, [&] {
        auto r = space->reservedRange(address, size);
        if (r.status != GM32_OK) return r;
        space->discard(address, size);
        return result(GM32_OK);
    });
}

extern "C" gm32_result gm32_query(gm32_space *space, gm32_address address, gm32_page_info *out) {
    if (!out) return result(GM32_INVALID_ARGUMENT, address);
    return locked(space, [&] {
        auto it = space->reservation(address);
        if (it == space->reservations.end()) return result(GM32_UNRESERVED, address);
        Page *p = space->page(address / GM32_PAGE_SIZE);
        *out = {it->first, it->second, p ? p->permissions : 0, p && p->bytes ? 1 : 0};
        return result(GM32_OK);
    });
}

extern "C" gm32_result gm32_read(gm32_space *s, gm32_address a, void *p, size_t n) {
    return transfer(s, a, p, n, GM32_READ, false);
}
extern "C" gm32_result gm32_write(gm32_space *s, gm32_address a, const void *p, size_t n) {
    return transfer(s, a, const_cast<void *>(p), n, GM32_WRITE, true);
}
extern "C" gm32_result gm32_fetch(gm32_space *s, gm32_address a, void *p, size_t n) {
    return transfer(s, a, p, n, GM32_EXECUTE, false);
}

extern "C" gm32_result gm32_compare_exchange(gm32_space *space, gm32_address address,
                                             size_t width, uint64_t expected, uint64_t desired,
                                             uint64_t *observed, int *exchanged) {
    if (!observed || !exchanged || (width != 1 && width != 2 && width != 4 && width != 8))
        return result(GM32_INVALID_ARGUMENT, address);
    if (width < 8 && ((expected | desired) >> (width * 8))) return result(GM32_INVALID_ARGUMENT, address);
    return locked(space, [&] {
        auto r = space->check(address, width, GM32_READ | GM32_WRITE);
        if (r.status != GM32_OK) return r;
        unsigned char bytes[8]{};
        space->copy(address, bytes, width, false);
        uint64_t old = 0;
        for (size_t i = 0; i < width; ++i) old |= uint64_t(bytes[i]) << (i * 8);
        if (old == expected) {
            for (size_t i = 0; i < width; ++i) bytes[i] = static_cast<unsigned char>(desired >> (i * 8));
            space->copy(address, bytes, width, true);
        }
        *observed = old;
        *exchanged = old == expected;
        return result(GM32_OK);
    });
}

extern "C" gm32_result gm32_with_span(gm32_space *space, gm32_address address,
                                      size_t size, unsigned access, gm32_span_visitor visitor,
                                      void *context) {
    if (!visitor || !size || !access || (access & ~AllPermissions))
        return result(GM32_INVALID_ARGUMENT, address, access);
    return locked(space, [&] {
        auto r = space->check(address, size, access);
        if (r.status != GM32_OK) return r;
        if (size > GM32_PAGE_SIZE - (address & PageMask)) return result(GM32_NONCONTIGUOUS, address, access);
        auto *bytes = space->page(address / GM32_PAGE_SIZE)->bytes->data() + (address & PageMask);
        const gm32_span span{address, size, bytes, (access & GM32_WRITE) ? bytes : nullptr};
        visitor(&span, context);
        return result(GM32_OK);
    });
}
