# Native 32-bit Windows support

This branch adds an x86 interpreter with guest memory translation and a full Wine32 filesystem. The app routing and IPA packaging are implemented in source. See [backend architecture and validation status](WINE32_BACKEND.md) for current execution evidence. The previously built IPA does not acquire this runtime until rebuilt.

## Use the 32-bit runtime

1. Run **Build Madeira IPA** in GitHub Actions with branch `codex/library-ui-and-installer-imports`, then install the resulting IPA.
2. Import the complete game folder and select its EXE, or open an EXE/MSI installer. Native x86 EXEs select Wine32 automatically. New MSI entries default to 32-bit Windows; their Details screen includes a runtime choice.
3. Complete setup inside Windows. Exit the installer and use **End session**, then **Find installed apps** to add its installed EXE to the library.

The interpreter does not require JIT. It keeps its Windows installation in `Documents/wine32` and mounts existing imported folders on `D:`. Reopening a 32-bit session preserves installed apps and saves.

## Files checked

The official Steam installer downloaded from Valve and the supplied game executable both have a COFF machine value of `0x014C`, a PE32 optional header, and no CLR header. Both have native 32-bit entry points. These are not cases of x64 executables being reported as x86.

`python3 tools/inspect-windows-executable.py <file.exe>` reads these fields without executing the file or compiling code. The Swift executable picker now displays the architecture read from each file, and launch errors identify the selected filename and machine value. Filenames such as `64bit.exe` do not determine architecture.

## Wine and FEX route

The pinned FEX revision includes a [WOW64 backend](https://github.com/willfaust/FEX/blob/053c385ecc9090702e4959a1d96752ea918a6110/Source/Windows/WOW64/Module.cpp). It sets FEX's 64-bit mode to zero, but also allocates syscall and Unix-call trampolines below 2 GB and uses guest addresses as host pointers. Its existence does not establish iOS compatibility.

[Apple's ARM64 Mach-O loader](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/mach_loader.c) requires a hard page-zero reservation covering the first 4 GB for ordinary ARM64 processes. The existing backend cannot put a native 32-bit Windows address into that region.

The local port has matching constraints:

- `build/ntdll-unix/env_ios.c`, `build_wow64_parameters`, allocates 32-bit process parameters below 2 GB and asserts that allocation succeeds.
- `build/ntdll-unix/virtual_ios.c` starts its address space above 4 GB and moves TEB and shared-user-data allocations above the reserved region for iOS.
- `app/Madeira/FEXBridge.mm` configures the embedded translator for 64-bit execution.
- `scripts/build-prefix-snapshot.sh` removes `windows/syswow64` from the prefix.
- The original native64 packaging lacks an i386 Wine runtime. The new backend packages a separate complete Wine32 guest filesystem.

No linker changes to remove page zero, architecture-check bypass, or unsupported mode toggle were added.

## Translation-layer requirements

`app/Madeira/GuestMemory32.h` and `GuestMemory32.cpp` now implement a process-owned sparse guest memory service. It reserves 32-bit address ranges, commits zeroed backing on demand, translates checked reads/writes/instruction fetches, enforces 4 KiB software permissions, and provides serialized compare/exchange and scoped native access. See [the memory service contract and integration status](GUEST_MEMORY_TRANSLATION.md).

The standalone service remains separate from the original Wine/FEX backend. The app's new x86 route uses BoxedWine's existing software MMU throughout instruction execution and emulated system calls. It does not reinterpret native host pointers as 32-bit guest addresses.

Running the complete Wine32 filesystem inside the interpreter keeps pointer-bearing Wine structures, callbacks, threads, and memory allocations inside the translated guest address space. This avoids trying to pass 32-bit guest pointers into the ARM64 Wine port.

The native Linux and ARM64 iOS Simulator CI suites have executed a real x86 test program, installed it through an MSI, relaunched the installed copy, and verified a Direct3D render target. The Simulator also verified visible presentation and guest keyboard input. Device game compatibility remains untested; see the execution evidence in the backend notes.

## JIT control

**Enable JIT** is available in the library and Settings, independent of importing or launching an app. It opens StikDebug with Madeira's bundle ID and the bundled `madeira-jit.js` payload. The query preserves base64 characters. A standalone request does not start Wine; a request from a waiting launch continues that launch after JIT is detected. Native startup disables additional JIT requests.

No compilation or device execution was performed locally. GitHub Actions has regression tests for x64 versus x86 detection and StikDebug URL construction.
