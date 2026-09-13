# Native Wine32 backend

Madeira routes native 32-bit EXEs and 32-bit MSI sessions through an x86 interpreter with software guest memory translation. Wine and the Windows program run inside the guest address space. The original 64-bit Wine/FEX route remains separate.

## Execution architecture

The native [BoxedWine engine](https://github.com/danoon2/Boxedwine/tree/296ff0fa14e0dd1debb0f5898e2e33504f2ad066) provides an existing interpreter and software MMU used throughout x86 CPU execution and emulated Linux system calls. Running its full 32-bit Wine distribution keeps Wine's pointer-bearing structures inside the guest address space. It avoids having to marshal every WOW64/native-Wine structure in Madeira's current ARM64EC port.

The embedded adapter forces sparse guest memory by setting `disableLinearMemory` before startup. No native JIT configuration is enabled. `LaunchPlan` selects this backend for PE machine `0x014C`. The existing 64-bit Wine/FEX backend handles supported 64-bit machine values. The standalone `GuestMemory32` service is tested separately; this execution route uses BoxedWine's MMU.

The released browser build was considered and rejected. Its release notes explicitly exclude Direct3D and OpenGL. That would leave the requested game support incomplete. The native engine supports desktop OpenGL through an OSMesa adapter, which renders into its X11 drawable and then presents through SDL textures. The iOS route needs a real iOS build of software Mesa, not a browser-only substitute or a GLES flag standing in for desktop OpenGL.

## Build and first execution proof

`build/boxedwine/runtime.json` pins the engine source revision and hashes the source archive and complete Wine 11 filesystem. `fetch.py` verifies those hashes before use and extracts source files without using upstream's prebuilt desktop frameworks. All its HTTP requests carry the requested User-Agent.

`build/boxedwine/CMakeLists.txt` builds the native interpreter for the first host execution test. `.github/workflows/wine32-runtime.yml` compiles a real i386 Windows PE and launches it through BoxedWine and Wine32 with sparse memory enabled. The probe checks Windows page allocation/protection, data spanning guest pages, guest threads, interlocked operations, registry creation, and persistent file output to a mounted directory. A host process exit code alone is insufficient; CI requires the exact file written by the Windows program. Further steps install that EXE using a real MSI, launch the installed copy in a later session, and verify all 4096 pixels of a Direct3D 9 render target read back by an x86 Windows graphics probe.

No local compilation is permitted for this work. Compile and execution results come from GitHub Actions. This host proof is a step toward integration and does not establish iOS support.

## Embedded lifecycle and current evidence

`embedded.h` exposes start, one bounded CPU/input tick, stop, and a persistent error message. The host calls it serially on the UI thread. `prepare_embedded.py` separates upstream startup from its blocking loop and retains mounted ZIP files until cleanup. Fatal engine errors return through the C boundary. Failed cleanup prevents another session from reusing uncertain global state. Explicitly mounted Wine drives receive guest write permissions, so imported games can create saves next to their executable.

`build_guest_graphics.py` compiles the i386 GL bridge from the same pinned source as the interpreter. It packages that bridge and the required version 10 ABI marker in `madeira-graphics.zip`. This ZIP precedes the original Wine ZIP, preserving its checksum while selecting matching GL entry points.

`build/mesa-ios` produces a pinned static Mesa 25.0.7 softpipe library with LLVM disabled. `prepare_ios.py` binds OSMesa statically and adapts SDL's UIKit presentation. SDL's controller attaches as a child of the app's display host. Logical rendering preserves guest pixel proportions and maps input back to guest coordinates. Keyboard and fullscreen updates respect the embedded host's bounds.

SDL's Metal shaders are regenerated for the selected SDK. The pinned SDL's UIKit raise hook restores an OpenGL context only in builds that include OpenGL ES, avoiding a null callback in Metal-only builds. `namespace_softfloat.py` isolates BoxedWine's floating-point symbols from FEX's incompatible variants; the compiled archive is checked for unprefixed exports before linkage.

The default guest desktop is 1280 × 720, with a resolution picker in Settings. XRandR advertises that configured mode and the supported alternatives. SDL draws guest cursors over the desktop and refreshes its point-to-pixel ratio when UIKit resizes the embedded view. Cursor queries, warps, and input events use the same logical coordinates. Changing a parent window's cursor refreshes child windows that inherit it. The X11 adapter returns a true Boolean from successful `XQueryPointer` calls; the upstream adapter returned the numeric error code `Success`, which is zero.

The native AddressSanitizer suite passed on the final runtime revision in [run 34743445564](https://github.com/phakoda/Madeira/actions/runs/34743445564). The ARM64 iOS Simulator suite passed all four stages in [run 34743445559](https://github.com/phakoda/Madeira/actions/runs/34743445559): guest memory/thread/registry/file operations, MSI installation, relaunch of the installed EXE, and Direct3D 9. Windows reported the expected 1280 × 720 desktop, successfully queried its cursor after a warp, and received left and right clicks within four guest pixels of the target. The graphics stage checked all 4096 render-target pixels. An actual Simulator screenshot contained 3,855 green pixels and 3,092 pixels from the guest's magenta test cursor. The fixture also received Tab and Enter, replaced the display host between sessions, and rendered inside an inset viewport. Both device and Simulator builds passed final runtime packaging and executable linkage in that run.

The initial regression run failed with Windows reporting 800 × 600. Subsequent checks exposed the missing XRandR mode, a false return from `XQueryPointer`, stale SDL scaling after UIKit resizing, and a cursor that failed to refresh over a child window. The final screenshot is captured only after the Windows window acknowledges both clicks. Simulator pointer injection exercises SDL and Wine input delivery; physical touch delivery through the SwiftUI screen still needs an installed-device check.

The screenshot runner acknowledges the captured frame through the native UIKit host, which sends Enter to the guest. It does not depend on the guest discovering a new host-created file in its cached directory listing. A host exit code or offscreen readback alone cannot pass this fixture.

## App integration

`Wine32Session.swift` owns a bounded interpreter tick on the main run loop. `Wine32Display` embeds SDL's UIKit controller inside the session screen. Returning to the library detaches the view and keeps the guest running. The keyboard button uses SDL text input, and the toolbar sends Escape, Tab, and Enter. End session closes the interpreter after a confirmation. A later 32-bit session reuses the persistent filesystem.

Imported folders remain under `Documents/wine/drive_c/Madeira/Imports`. The 32-bit runtime mounts that drive as `D:`. Wine32 installs apps into its own `C:` under `Documents/wine32/home/username/.wine/drive_c`. Library entries retain their volume, and installed-app discovery scans both drives. Older manifests retain their original drive and MSI runtime.

New MSI imports default to 32-bit Windows. Details includes an explicit installer-runtime choice because MSI files have no PE entry point. Selecting 64-bit Windows preserves the existing MSI launch path. EXE runtime selection always follows the actual PE header.

`package_ios.py` combines the interpreter, isolated SoftFloat, SDL, and static OSMesa archives. It links a smoke executable against that final archive, then packages the full Wine ZIP, matching graphics overlay, provenance, and library notices. The manual **Build Madeira IPA** workflow builds the guest GL bridge on Linux and the native runtime on its macOS runner before Xcode builds the app.

## Remaining validation

Library tests and the complete iOS Swift type check passed in [run 34742004540](https://github.com/phakoda/Madeira/actions/runs/34742004540). No app or emulator was compiled or run locally. The full IPA is built separately by the user's manual workflow; these targeted CI checks do not substitute for installing that IPA on a device.

Device acceptance must cover touch coordinates, text input, rotation, returning to the library, audio, and the supplied game. The 32-bit display currently uses SDL input; Madeira's native64 controller-to-keyboard mapping and FPS counter do not measure or control this backend.

The user reported that the Steam installer completed using Enter, but checking for updates terminated Madeira to the iPhone Home Screen. The iOS exception or Jetsam report is still needed to diagnose that termination. The display and pointer changes do not establish a fix for Steam's updater crash.

The supplied game and Steam installer have not been executed on the user's device by this work. CPU interpretation and software graphics can be slow. A 32-bit installer that launches 64-bit components cannot run those components inside the x86 guest.
