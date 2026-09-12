#include "embedded.h"
#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

int main(int argc, char** argv) {
    int repeats = 1;
    std::vector<const char*> arguments(argv, argv + argc);
    if (argc > 2 && std::strcmp(argv[1], "--host-repeat-twice") == 0) {
        repeats = 2;
        arguments.erase(arguments.begin() + 1);
    }
    // Verify rejection does not leave global engine state occupied.
    if (madeira_wine32_start(0, nullptr) != 0) return 2;
    for (int iteration = 0; iteration < repeats; ++iteration) {
        if (!madeira_wine32_start(static_cast<int>(arguments.size()), arguments.data())) {
            std::fprintf(stderr, "Start failed: %s\n", madeira_wine32_error());
            return 1;
        }
        int state;
        while ((state = madeira_wine32_tick()) == 1) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        if (state < 0 || !madeira_wine32_stop()) {
            std::fprintf(stderr, "Session failed: %s\n", madeira_wine32_error());
            return 1;
        }
    }
    return 0;
}
