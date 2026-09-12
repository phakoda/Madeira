# Native 32-bit Windows support

Native x86 support is not implemented in the current Madeira IPA. It cannot be enabled by changing the executable validator or FEX's mode setting alone.

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
- The IPA's current build and packaging paths do not provide a complete i386 Wine runtime and iOS-compatible WOW64 bridge.

No linker changes to remove page zero, architecture-check bypass, or unsupported mode toggle were added.

## Translation-layer requirements

`app/Madeira/GuestMemory32.h` and `GuestMemory32.cpp` now implement a process-owned sparse guest memory service. It reserves 32-bit address ranges, commits zeroed backing on demand, translates checked reads/writes/instruction fetches, enforces 4 KiB software permissions, and provides serialized compare/exchange and scoped native access. See [the memory service contract and integration status](GUEST_MEMORY_TRANSLATION.md).

This is an implemented memory component, not an enabled Wine/FEX backend. The current executable launch restriction remains. Neither SteamSetup.exe nor a native x86 game can run through this service yet.

A software memory translation layer is a possible engineering route. It must keep 32-bit guest addresses separate from their host backing addresses throughout instruction execution, memory allocation, PE loading, Wine API pointer conversion, callbacks, exceptions, thread state, and shared memory. Translating CPU instructions alone does not satisfy those requirements.

The other architectural option is a full-system x86 emulator with a separate Windows installation. That would be a separate backend rather than enabling the current Wine/FEX integration.

Working support needs a native x86 test program and a real 32-bit installer to execute on the target iOS device, with file I/O, process creation, callbacks, and graphics checked. This update does not claim those capabilities.

## JIT control

**Enable JIT** is available in the library and Settings, independent of importing or launching an app. It opens StikDebug with Madeira's bundle ID and the bundled `madeira-jit.js` payload. The query preserves base64 characters. A standalone request does not start Wine; a request from a waiting launch continues that launch after JIT is detected. Native startup disables additional JIT requests.

No compilation or device execution was performed locally. GitHub Actions has regression tests for x64 versus x86 detection and StikDebug URL construction.
