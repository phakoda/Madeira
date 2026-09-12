#include "boxedwine.h"
#include "startupArgs.h"
#include "knativesystem.h"
#include "knativesocket.h"
#include "embedded.h"
#include <SDL.h>
#include <memory>
#include <stdexcept>
#include <string>

namespace {
std::unique_ptr<StartUpArgs> session;
std::string lastError;
bool platformInitialized = false;
bool ticking = false;
bool poisoned = false;

bool closeSession() {
    try {
        if (session) session->finish();
        session.reset();
        if (platformInitialized) KNativeSystem::cleanup();
        platformInitialized = false;
        return true;
    } catch (const std::exception& error) {
        // A failed cleanup leaves process-global engine state untrustworthy.
        // Keep the failure visible and refuse to start another session.
        lastError += std::string(" Cleanup failed: ") + error.what();
        poisoned = true;
        return false;
    } catch (...) {
        lastError += " Cleanup failed with an unknown exception.";
        poisoned = true;
        return false;
    }
}
}

// Upstream fatal errors unwind into the C boundary instead of exiting the app.
void madeiraWine32Fatal(const char* message) {
    throw std::runtime_error(message ? message : "Wine32 engine failure");
}

bool isMainthread() { return true; }

// Retained for StartUpArgs::apply linkage. Embedded callers use tick(), and
// must never accidentally enter upstream's blocking application loop.
bool doMainLoop() {
    madeiraWine32Fatal("Blocking main loop called in embedded Wine32");
    return false;
}

extern "C" int madeira_wine32_start(int argc, const char** argv) {
    if (session || ticking || poisoned) return 0;
    lastError.clear();
    if (argc < 2 || !argv) {
        lastError = "A guest command and runtime arguments are required.";
        return 0;
    }
    for (int i = 0; i < argc; ++i) {
        if (!argv[i]) {
            lastError = "A runtime argument is null.";
            return 0;
        }
    }
    try {
        session = std::make_unique<StartUpArgs>();
        if (!session->parseStartupArgs(argc, argv) || session->shouldStartUI()) {
            throw std::runtime_error("Invalid Wine32 launch arguments");
        }
        session->disableLinearMemory = true;
        KSystem::startMicroCounter();
        // Fs::nativePathSeperator is initialized by begin(). Before that,
        // upstream's native parent-path helper dereferences an empty BString.
        std::string executablePath = argv[0];
        const auto separator = executablePath.find_last_of("/\\");
        executablePath = separator == std::string::npos ? "" : executablePath.substr(0, separator + 1);
        KSystem::exePath = BString::copy(executablePath.c_str());
        Platform::init();
        SDL_SetMainReady();
        platformInitialized = true;
        if (!KNativeSystem::init(session->videoOption, true)) {
            throw std::runtime_error(SDL_GetError());
        }
        if (!session->begin()) throw std::runtime_error("Wine32 could not start the guest process");
        return 1;
    } catch (const std::exception& error) {
        lastError = error.what();
    } catch (...) {
        lastError = "Unknown Wine32 startup failure";
    }
    closeSession();
    return 0;
}

extern "C" int madeira_wine32_tick(void) {
    if (poisoned) return -1;
    if (!session) return lastError.empty() ? 0 : -1;
    if (ticking) return 1; // UIKit can reenter while SDL pumps native events.
    ticking = true;
    bool running = false;
    try {
        if (KSystem::getProcessCount()) {
            runSlice();
            running = KNativeSystem::getCurrentInput()->processEvents();
            if (running) {
                KNativeSystem::tick();
                checkWaitingNativeSockets(0);
                running = KSystem::getRunningProcessCount() != 0;
            }
        }
    } catch (const std::exception& error) {
        lastError = error.what();
    } catch (...) {
        lastError = "Unknown Wine32 execution failure";
    }
    ticking = false;
    if (!lastError.empty() || !running) {
        closeSession();
        return lastError.empty() ? 0 : -1;
    }
    return 1;
}

extern "C" int madeira_wine32_stop(void) {
    if (ticking) {
        KNativeSystem::postQuit();
        return 1;
    }
    return !poisoned && closeSession();
}

extern "C" const char* madeira_wine32_error(void) {
    return lastError.c_str();
}
