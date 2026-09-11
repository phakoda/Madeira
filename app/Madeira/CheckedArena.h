#ifndef MADEIRA_CHECKED_ARENA_H
#define MADEIRA_CHECKED_ARENA_H
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace Madeira {
struct ArenaReservation { std::size_t offset; std::size_t size; };

// Reserve a disjoint aligned range. Failed requests do not advance the cursor,
// including integer overflow, exhaustion, zero size and invalid alignment.
// Relaxed ordering suffices for RESERVATION ONLY: this does not publish the
// contents of the reserved memory or replace executable-code synchronization.
inline bool reserveArena(std::atomic<std::size_t>& cursor, std::size_t capacity,
                         std::size_t requested, std::size_t alignment,
                         ArenaReservation& result) noexcept {
    if (!requested || !alignment || (alignment & (alignment - 1))) return false;
    const auto mask = alignment - 1;
    const auto maximum = std::numeric_limits<std::size_t>::max();
    if (requested > maximum - mask) return false;
    const auto size = (requested + mask) & ~mask;
    auto current = cursor.load(std::memory_order_relaxed);
    for (;;) {
        if (current > capacity || current > maximum - mask) return false;
        const auto aligned = (current + mask) & ~mask;
        if (aligned > capacity || size > capacity - aligned) return false;
        const auto next = aligned + size;
        if (cursor.compare_exchange_weak(current, next, std::memory_order_relaxed,
                                         std::memory_order_relaxed)) {
            result = {aligned, size};
            return true;
        }
    }
}
inline bool arenaContainsAddress(std::uintptr_t base, std::size_t capacity,
                                 std::uintptr_t address) noexcept {
    // Subtraction after the lower-bound check avoids overflowing base+capacity.
    return address >= base && address - base < capacity;
}
}
#endif
