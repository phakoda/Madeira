# Native Wine32 backend

The active objective is working 32-bit EXE/MSI installation and game-folder execution in the iOS app. The standalone `GuestMemory32` service does not meet that objective, because the existing Wine/FEX route still assumes guest and host pointers are identical.

## Execution architecture

The native [BoxedWine engine](https://github.com/danoon2/Boxedwine/tree/296ff0fa14e0dd1debb0f5898e2e33504f2ad066) provides an existing interpreter and software MMU used throughout x86 CPU execution and emulated Linux system calls. Running its full 32-bit Wine distribution keeps Wine's pointer-bearing structures inside the guest address space. It avoids having to marshal every WOW64/native-Wine structure in Madeira's current ARM64EC port.

The selected initial mode is the native interpreter with sparse memory, selected by `-disableLinearMemory`. No native JIT configuration is enabled. The current 64-bit Wine/FEX backend remains available; 32-bit launch routing must be added once the new native engine is embedded.

The released browser build was considered and rejected. Its release notes explicitly exclude Direct3D and OpenGL. That would leave the requested game support incomplete. The native engine supports desktop OpenGL through an OSMesa adapter, which renders into its X11 drawable and then presents through SDL textures. The iOS route needs a real iOS build of software Mesa, not a browser-only substitute or a GLES flag standing in for desktop OpenGL.

## Build and first execution proof

`build/boxedwine/runtime.json` pins the engine source revision and hashes the source archive and complete Wine 11 filesystem. `fetch.py` verifies those hashes before use and extracts source files without using upstream's prebuilt desktop frameworks. All its HTTP requests carry the requested User-Agent.

`build/boxedwine/CMakeLists.txt` builds the native interpreter for the first host execution test. `.github/workflows/wine32-runtime.yml` compiles a real i386 Windows PE and launches it through BoxedWine and Wine32 with sparse memory enabled. The probe checks Windows page allocation/protection, data spanning guest pages, guest threads, interlocked operations, registry creation, and persistent file output to a mounted directory. A host process exit code alone is insufficient; CI requires the exact file written by the Windows program. Further steps install that EXE using a real MSI, launch the installed copy in a later session, and verify all 4096 pixels of a Direct3D 9 render target read back by an x86 Windows graphics probe.

No local compilation is permitted for this work. Compile and execution results come from GitHub Actions. This host proof is a step toward integration and does not establish iOS support.

## Embedded lifecycle and current evidence

`embedded.h` exposes start, one bounded CPU/input tick, stop, and a persistent error message. The host calls it serially on the UI thread. `prepare_embedded.py` separates upstream startup from its blocking loop and retains mounted ZIP files until cleanup. Fatal engine errors return through the C boundary. Failed cleanup prevents another session from reusing uncertain global state. Explicitly mounted Wine drives receive guest write permissions, so imported games can create saves next to their executable.

The host execution job in [run 34723989701](https://github.com/phakoda/Madeira/actions/runs/34723989701) passed the complete native x86 memory/thread/registry/file fixture and the same-process restart fixture. Its installer and graphics stages were still running when this evidence was recorded. The earlier startup crash was traced by AddressSanitizer to calling the filesystem parent-path helper before its separator was initialized; the adapter now derives the executable directory without that helper.

`build/mesa-ios` produces a pinned static Mesa 25.0.7 softpipe library with LLVM disabled. Both SDK variants passed archive architecture, symbol, executable-link, and Mach-O platform checks in [run 34723653929](https://github.com/phakoda/Madeira/actions/runs/34723653929). That establishes linkage, not rendered output.

`prepare_ios.py` binds OSMesa statically and adapts SDL's UIKit presentation. `ios_view.h` attaches SDL's controller as a child of the host controller; SDL does not replace Madeira's application window. The iOS workflow also builds a small UIKit test app from `tests/wine32/ios`, with real x86 EXE/MSI fixtures and the complete Wine32 filesystem. Its Simulator run must produce guest-written results across runtime, installation, installed-EXE relaunch, and Direct3D stages. This execution check is not yet confirmed. The production app still needs backend packaging and launch routing.

## Work required before completion

- Build the native interpreter for iPhoneOS and Simulator, including UIKit-compatible platform code.
- Embed startup, event pumping, cancellation, and shutdown without blocking UIKit or terminating the app.
- Present SDL framebuffer output in the session view, with keyboard, pointer, touch, and audio routing.
- Build and connect software OpenGL for the game's Direct3D path; verify a real x86 graphics program.
- Bundle the full Wine32 runtime and its license/source notices, with a separate persistent prefix.
- Route x86 executables and 32-bit MSI execution to this backend. Import and mounted-directory behavior must preserve complete game folders and installed output.
- Verify installer execution, installed executable discovery, subsequent launch, persistence, callbacks, process creation, and graphics through the iOS runtime. Validate the supplied game on device without publishing the user's game files.

The goal remains active until those behaviors work. The current app's native32 restriction must not be removed merely because the host interpreter probe passes.
