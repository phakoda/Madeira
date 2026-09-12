# Guest memory translation

## Status

`app/Madeira/GuestMemory32.cpp` implements a sparse 32-bit guest address space with a C interface in `GuestMemory32.h`. The source is registered in the Xcode target and tested by a separate GitHub Actions workflow and the IPA workflow. **Wine and FEX do not yet consume this interface. Native 32-bit installers and games remain unsupported.**

The implementation uses ordinary host heap allocations. On iOS these live outside the low 4 GiB reservation. Guest address `0x00400000` is a page-table key, never a native pointer. This does not change native address-space protections, JIT allocation, debugger behavior, entitlements, or the current x64 launch path.

## Usage

Each future guest process owns a separate space. Reserve an address range, commit pages, and copy bytes through the service. The configured backing budget is independent of reserved address space and excludes page-table metadata.

```c
gm32_space *memory = NULL;
gm32_address image = 0;
gm32_result status = gm32_create(256ull * 1024 * 1024, &memory);
if (status.status != GM32_OK) return;
status = gm32_reserve(memory, 0x00400000, 65536, &image);
if (status.status == GM32_OK)
    status = gm32_commit(memory, image, 4096, GM32_READ | GM32_WRITE);
if (status.status == GM32_OK) {
    const unsigned char code[] = {0x31, 0xc0, 0xc3};
    status = gm32_write(memory, image, code, sizeof(code));
}
if (status.status == GM32_OK)
    status = gm32_protect(memory, image, 4096, GM32_EXECUTE);
if (status.status == GM32_OK) {
    unsigned char instruction[3];
    status = gm32_fetch(memory, image, instruction, sizeof(instruction));
    /* Bytes were copied for a decoder. No x86 instructions ran. */
}
gm32_destroy(memory);
```

The API reports the first invalid guest address for a failed memory access. Instruction fetch requires EXECUTE even on execute-only pages; ordinary reads require READ. Guest executable bytes remain non-executable host data. A failed multi-page copy leaves the guest and caller's output buffer unchanged.

The reservation base uses Windows' 64 KiB allocation granularity. Commit, protect, and decommit use 4 KiB guest pages. They must stay within one reservation. A copy may cross adjacent reservations. The exclusive address-space limit is represented with 64-bit arithmetic, so an access ending exactly at `0x100000000` succeeds and one extending past it fails. Effective-address wrapping belongs in the future CPU consumer before it calls the service.

Commit preserves the contents and permissions of already committed pages. New pages are zeroed. Decommit drops backing, and recommit creates new zeroed pages. Committed/no-access differs from uncommitted. Release requires the original allocation base. The low 64 KiB cannot be allocated.

## Native buffers and concurrency

`gm32_read`, `gm32_write`, and `gm32_fetch` copy arbitrarily long valid spans, including page boundaries. Sparse guest pages do not promise contiguous native backing.

`gm32_with_span` lends one page's native backing to a synchronous callback after checking the requested permissions. A valid span crossing a page boundary returns `GM32_NONCONTIGUOUS`; range, mapping, and permission errors take precedence. It does not return a temporary buffer with hidden copyback. Its read pointer is const, and its writable pointer is present only when WRITE was requested. Callers must use the pointer only for the requested operation during the callback.

All operations, including native callbacks and compare/exchange, hold one mutex per space. A callback cannot reenter the same space, wait for another caller of that space, retain the pointer, or throw. Destroy requires all callers to have stopped. This interface does not support a native API retaining a buffer after return or reentering Wine from inside a callback.

Compare/exchange handles little-endian operands of 1, 2, 4, or 8 bytes, including unaligned operands crossing pages. It is atomic relative to other service operations. It does not implement the full x86 atomic instruction set, FEX memory ordering, a lock-free translated-code fast path, Windows guard-page faults, or write-watch.

## Design decision

Two independent designs compared a sparse page table with a rebased contiguous 4 GiB window. A separate review chose sparse backing for its address-space feasibility on iOS. The implementation uses reservation intervals plus a two-level table with 1024 entries at each level. Empty reservations consume no page tables; only committed regions allocate leaves. Empty leaves are freed after decommit/release.

The contiguous design gives native callers longer directly mapped spans and a simpler eventual JIT address calculation. It also requires an unverified contiguous 4 GiB virtual reservation for every guest process. Sparse backing avoids that requirement. The sparse design adopted the other candidate's exact-base release semantics, distinction between committed/no-access and uncommitted pages, execute-only fetch, and checked 64-bit range ends.

Commit stages every new page and table allocation before publishing any of them. Budget exhaustion or allocation failure leaves prior mappings intact. A single mutex keeps lifetime management and mutation inside the service; future translated-code caching needs an explicit invalidation and lifetime protocol before it can bypass these calls.

## Runtime integration still required

The current route is `EmulatorSession.bootstrap` → `wine_process_start` → Wine's bundled ARM64EC libraries and `xtajit64.dll`. That DLL has its own FEXCore copy. `FEXBridge.mm` configures a separate diagnostic context; changing its 64-bit setting would not change game execution. CI currently builds Mach-O FEX static libraries and bundles the existing PE backend. Registering this memory service in the app target does not make it available to that PE backend.

The remaining work crosses these boundaries:

| Boundary | Required change |
| --- | --- |
| Wine virtual memory | Keep native allocations separate from guest reservations. `allocate_virtual_memory` currently returns `file_view.base` as both a host pointer and a Windows address. |
| PE32 loader | Split guest image identity from native backing. `map_image_into_view` currently dereferences `view->base` and uses native addresses in image mapping/relocation handling. Apply PE32 relocations to guest addresses and marshal header/section accesses. |
| Process and thread structures | Serialize PEB32, TEB32, stacks, strings, and process parameters with guest addresses. `build_wow64_parameters`, `dup_unicode_string`, and `init_teb` currently depend on low native addresses or pointer truncation. |
| FEX frontend | Replace instruction-stream dereferences with translated fetches, preserving instruction and fault behavior across page boundaries. |
| FEX execution | Cover scalar/vector loads and stores, atomics, strings, stacks, segment bases, and other memory operations. Preserve guest PC/address identity in branches and exceptions. |
| Translation cache | Invalidate blocks when guest code changes, mappings disappear, or permissions change. This service currently exposes no block-cache callback. |
| WOW64 thunks | Marshal nested pointer-bearing structures, synchronous and retained buffers, callbacks, and exception contexts. An integer-to-host-pointer cast is insufficient. |
| Process isolation and shared memory | Route each operation to the right guest space and implement shared backing where Windows requires aliases between processes. |
| Build and packaging | Build the adapted PE-side WOW64/FEX backend, expose the memory service through the Wine boundary, bundle i386 Wine libraries, and initialize an appropriate prefix. |

The pinned FEX source confirms direct instruction reads in `FEXCore/Source/Interface/Core/Frontend.cpp` and native-address memory emission in `FEXCore/Source/Interface/Core/JIT/MemoryOps.cpp` and `AtomicOps.cpp`. The [pinned WOW64 backend](https://github.com/willfaust/FEX/blob/053c385ecc9090702e4959a1d96752ea918a6110/Source/Windows/WOW64/Module.cpp) also assumes low native guest addresses. Those consumers need coordinated changes before the launch guard can be removed.

## Verification

`bash tests/run-guest-memory-tests.sh` compiles the production service, runs C++ behavioral tests with AddressSanitizer and UndefinedBehaviorSanitizer, and separately compiles a C caller to check the ABI. `Guest memory translation tests` runs on Linux and macOS in GitHub Actions. The IPA build runs the same suite before building its dependencies.

Coverage includes overlapping reservations, automatic placement, range exhaustion, the final guest byte, cross-page copies, execute-only access, failed-operation atomicity, mixed permissions within a 16 KiB region, decommit/recommit, independent spaces, allocation-failure rollback, native spans, and concurrent unaligned compare/exchange. Tests inject allocation failures into the production commit path, rather than substituting a model implementation.

No local compilation was performed. Host tests do not prove iOS integration or native x86 execution. Enabling native32 still requires device runs of a small x86 program, an installer, and the requested game through the completed Wine/FEX route.
