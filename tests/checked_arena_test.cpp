#include "../app/Madeira/CheckedArena.h"
#include <algorithm>
#include <cassert>
#include <iostream>
#include <thread>
#include <vector>

int main() {
    std::size_t checks = 0;
    auto check = [&](bool condition) { ++checks; assert(condition); };
    std::atomic<std::size_t> cursor{0};
    Madeira::ArenaReservation result{111, 222};
    constexpr auto maximum = std::numeric_limits<std::size_t>::max();
    check(!Madeira::reserveArena(cursor, 1024, 0, 16, result));
    check(!Madeira::reserveArena(cursor, 1024, 1, 0, result));
    check(!Madeira::reserveArena(cursor, 1024, 1, 3, result));
    check(!Madeira::reserveArena(cursor, 1024, maximum, 16, result));
    check(cursor == 0 && result.offset == 111 && result.size == 222);
    check(Madeira::reserveArena(cursor, 1024, 1, 16, result));
    check(result.offset == 0 && result.size == 16 && cursor == 16);
    check(!Madeira::reserveArena(cursor, 1024, 1024, 16, result));
    check(cursor == 16);
    check(Madeira::reserveArena(cursor, 1024, 1008, 16, result));
    check(result.offset == 16 && result.size == 1008 && cursor == 1024);
    for (int i = 0; i < 10000; ++i) {
        check(!Madeira::reserveArena(cursor, 1024, 1, 16, result));
        check(cursor == 1024);
    }
    cursor = maximum - 4;
    check(!Madeira::reserveArena(cursor, maximum, 1, 16, result));
    check(cursor == maximum - 4);
    cursor = 7;
    check(Madeira::reserveArena(cursor, 128, 2, 16, result));
    check(result.offset == 16 && result.size == 16 && cursor == 32);
    cursor = 1025;
    check(!Madeira::reserveArena(cursor, 1024, 1, 16, result));
    check(Madeira::arenaContainsAddress(maximum - 10, 11, maximum));
    check(!Madeira::arenaContainsAddress(100, 10, 99));
    check(Madeira::arenaContainsAddress(100, 10, 100));
    check(Madeira::arenaContainsAddress(100, 10, 109));
    check(!Madeira::arenaContainsAddress(100, 10, 110));
    check(!Madeira::arenaContainsAddress(100, 0, 100));

    constexpr std::size_t workers = 32, iterations = 4000, alignment = 256;
    const std::size_t capacity = workers * iterations * alignment;
    cursor = 0;
    std::atomic<bool> begin{false};
    std::vector<std::vector<Madeira::ArenaReservation>> allocations(workers);
    std::vector<std::thread> threads;
    for (std::size_t i = 0; i < workers; ++i) {
        threads.emplace_back([&, i] {
            allocations[i].reserve(iterations);
            while (!begin.load(std::memory_order_acquire)) std::this_thread::yield();
            for (std::size_t j = 0; j < iterations; ++j) {
                Madeira::ArenaReservation got{};
                bool success = Madeira::reserveArena(cursor, capacity, 1 + (j % alignment), alignment, got);
                assert(success);
                allocations[i].push_back(got);
            }
        });
    }
    begin.store(true, std::memory_order_release);
    for (auto& thread : threads) thread.join();
    std::vector<Madeira::ArenaReservation> all;
    for (const auto& ranges : allocations) all.insert(all.end(), ranges.begin(), ranges.end());
    std::sort(all.begin(), all.end(), [](auto a, auto b) { return a.offset < b.offset; });
    check(all.size() == workers * iterations && cursor == capacity);
    for (std::size_t i = 0; i < all.size(); ++i) {
        check(all[i].offset == i * alignment && all[i].size == alignment);
    }
    check(!Madeira::reserveArena(cursor, capacity, 1, alignment, result));
    check(cursor == capacity);
    std::cout << "Checked arena: " << checks << " checks passed (128,000 allocations on 32 threads)\n";
}
