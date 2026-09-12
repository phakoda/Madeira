# Native Wine32 backend

The active objective is working 32-bit EXE/MSI installation and game-folder execution in the iOS app. The standalone `GuestMemory32` service does not meet that objective, because the existing Wine/FEX route still assumes guest and host pointers are identical.

## Execution architecture

The native [BoxedWine engine](https://github.com/danoon2/Boxedwine/tree/296ff0fa14e0dd1debb0f5898e2e33504f2ad066) provides an existing interpreter and software MMU used throughout x86 CPU execution and emulated Linux system calls. Running its full 32-bit Wine distribution keeps Wine's pointer-bearing structures inside the guest address space. It avoids having to marshal every WOW64/native-Wine structure in Madeira's current ARM64EC port.

The selected initial mode is the native interpreter with sparse memory, selected by `-disableLinearMemory`. No native JIT configuration is enabled. `LaunchPlan` selects this backend for PE machine `0x014C`. The existing 64-bit Wine/FEX backend handles supported 64-bit machine values.

The released browser build was considered and rejected. Its release notes explicitly exclude Direct3D and OpenGL. That would leave the requested game support incomplete. The native engine supports desktop OpenGL through an OSMesa adapter, which renders into its X11 drawable and then presents through SDL textures. The iOS route needs a real iOS build of software Mesa, not a browser-only substitute or a GLES flag standing in for desktop OpenGL.

## Build and first execution proof

`build/boxedwine/runtime.json` pins the engine source revision and hashes the source archive and complete Wine 11 filesystem. `fetch.py` verifies those hashes before use and extracts source files without using upstream's prebuilt desktop frameworks. All its HTTP requests carry the requested User-Agent.

`build/boxedwine/CMakeLists.txt` builds the native interpreter for the first host execution test. `.github/workflows/wine32-runtime.yml` compiles a real i386 Windows PE and launches it through BoxedWine and Wine32 with sparse memory enabled. The probe checks Windows page allocation/protection, data spanning guest pages, guest threads, interlocked operations, registry creation, and persistent file output to a mounted directory. A host process exit code alone is insufficient; CI requires the exact file written by the Windows program. Further steps install that EXE using a real MSI, launch the installed copy in a later session, and verify all 4096 pixels of a Direct3D 9 render target read back by an x86 Windows graphics probe.

No local compilation is permitted for this work. Compile and execution results come from GitHub Actions. This host proof is a step toward integration and does not establish iOS support.

## Embedded lifecycle and current evidence

`embedded.h` exposes start, one bounded CPU/input tick, stop, and a persistent error message. The host calls it serially on the UI thread. `prepare_embedded.py` separates upstream startup from its blocking loop and retains mounted ZIP files until cleanup. Fatal engine errors return through the C boundary. Failed cleanup prevents another session from reusing uncertain global state. Explicitly mounted Wine drives receive guest write permissions, so imported games can create saves next to their executable.

The host execution job in [run 34723989701](https://github.com/phakoda/Madeira/actions/runs/34723989701) passed the complete native x86 memory/thread/registry/file fixture, same-process restart, MSI installation, and launch of the installed executable. Its graphics stage found that the full Wine archive has a version 6 GL bridge, which the pinned interpreter rejects. The earlier startup crash was traced by AddressSanitizer to calling the filesystem parent-path helper before its separator was initialized; the adapter now derives the executable directory without that helper.

`build_guest_graphics.py` compiles the i386 GL bridge from the same pinned source as the interpreter. It packages that bridge and the required version 10 ABI marker in `madeira-graphics.zip`. This ZIP is loaded before the original Wine ZIP, preserving the original archive and its checksum while selecting the matching GL entry points. Both host and UIKit tests require this overlay. The complete native suite, including all 4096 Direct3D pixels, passed in [run 34724559257](https://github.com/phakoda/Madeira/actions/runs/34724559257).

`build/mesa-ios` produces a pinned static Mesa 25.0.7 softpipe library with LLVM disabled. Both SDK variants passed archive architecture, symbol, executable-link, and Mach-O platform checks in [run 34723653929](https://github.com/phakoda/Madeira/actions/runs/34723653929). That establishes linkage, not rendered output.

`prepare_ios.py` binds OSMesa statically and adapts SDL's UIKit presentation. `ios_view.h` attaches SDL's controller as a child of the host controller; SDL does not replace Madeira's application window. The iOS workflow also builds a small UIKit test app from `tests/wine32/ios`, with real x86 EXE/MSI fixtures and the complete Wine32 filesystem. Its Simulator run must produce guest-written results across runtime, installation, installed-EXE relaunch, and Direct3D stages. This execution check is not yet confirmed. Production packaging and launch routing are now implemented in source and await their CI results.

The interpreter and UIKit test app linked for both SDKs in [run 34724559258](https://github.com/phakoda/Madeira/actions/runs/34724559258); a subsequent check used the wrong output path and prevented Simulator execution. The link fixture now explicitly builds as a plain executable. SDL's Metal shaders are regenerated for the selected SDK, because the pinned SDL has only a prebuilt device shader library. `namespace_softfloat.py` isolates BoxedWine's floating-point symbols from FEX's incompatible variants, and the compiled archive is checked for unprefixed exports before linkage.

## App integration

`Wine32Session.swift` owns a bounded interpreter tick on the main run loop. `Wine32Display` embeds SDL's UIKit controller inside the session screen. Returning to the library detaches the view and keeps the guest running. The keyboard button uses SDL text input, and the toolbar sends Escape, Tab, and Enter. End session closes the interpreter after a confirmation. A later 32-bit session reuses the persistent filesystem.

Imported folders remain under `Documents/wine/drive_c/Madeira/Imports`. The 32-bit runtime mounts that drive as `D:`. Wine32 installs apps into its own `C:` under `Documents/wine32/home/username/.wine/drive_c`. Library entries retain their volume, and installed-app discovery scans both drives. Older manifests retain their original drive and MSI runtime.

New MSI imports default to 32-bit Windows. Details includes an explicit installer-runtime choice because MSI files have no PE entry point. Selecting 64-bit Windows preserves the existing MSI launch path. EXE runtime selection always follows the actual PE header.

`package_ios.py` combines the interpreter, isolated SoftFloat, SDL, and static OSMesa archives. It links a smoke executable against that final archive, then packages the full Wine ZIP, matching graphics overlay, provenance, and library notices. The manual **Build Madeira IPA** workflow builds the guest GL bridge on Linux and the native runtime on its macOS runner before Xcode builds the app.

## Remaining validation

The source changes do not establish game compatibility. The UIKit execution stages, complete Swift type check, and final runtime packaging must pass in GitHub Actions. Device acceptance must then cover touch coordinates, text input, rotation, returning to the library, audio, and the supplied game. The 32-bit display currently uses SDL input; Madeira's native64 controller-to-keyboard mapping and FPS counter do not measure or control this backend.

The supplied game and Steam installer have not been executed on the user's device by this work. CPU interpretation and software graphics can be slow. A 32-bit installer that launches 64-bit components cannot run those components inside the x86 guest.
