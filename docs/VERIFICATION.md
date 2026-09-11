# Verification report — Madeira iOS improvement pass

## Read this first

This is a **source-code update**, not a newly built IPA or a device compatibility
certification. The supplied project's original history and bundled artifacts are
preserved. The working branch is `improvements/ios-stability`, based on `97e2ce2`.
Source and tests below were verified at `d7595157b4a0de82809f4f10a128b15371d25be9`; the final documentation commit
does not change executable code.

The host is Linux x86_64, Clang 17.0.0, Swift 6.2.1, Python 3.13.5. It has no
Apple SDK, Xcode, iOS simulator, physical iOS device, or Metal runtime. The
connected terminal attempt also failed. Direct submodule fetch was attempted but
network access from the build container was unavailable. Existing libraries in
the ZIP are unchanged input artifacts, **not newly rebuilt engine libraries**.

## Executed checks

Both commands below completed successfully on the final source revision:

```sh
bash tests/run-portable.sh
SANITIZE=0 bash tests/run-portable.sh
```

| Suite | Checks per run | What actually ran |
| --- | ---: | --- |
| Existing remote-Metal wire/decoder | 63 | Portable schema/decoder C tests, not GPU execution |
| Native input queue | 200,991 | Production header: motion/order/overflow/state reconciliation; 200,000-event stress |
| Surface layout/mailbox | 20,157 | Production header: bounds, replacement, byte budget, stale task tickets |
| Geometry/input ownership | 10,026 | Production Swift helpers: aspect fit, coordinates, overlapping held sources |
| Logging | 1,061 | Production Swift: aggregation, tail, framing, 64,000 concurrent events, 1,000 appends |
| Prefix installation | 850 | Production C: 174 fixtures, all 138 shipped members compared, corruption/limits/user-file preservation |
| Frame-rate sampling | 110,208 | Production Swift: low/high rates, reset/wrap/stall/invalid clocks, bounded history |
| Checked allocation arena | 148,025 | Production C++: overflow/exhaustion, 128,000 allocations on 32 threads |
| Controller/keyboard | 121,928 | Production Swift math/ownership: radial response, 30/60/120/240 Hz integration, keys/repeats/cancellation |
| Remote-runner behavior | 17 | Offline fake compiler/test fixtures; failures propagated, no network or Metal |
| Template tooling | 7 | Real shipped-template validation, corrupt input, stubbed failing wineboot preserving old archive |
| **Total** | **613,333** | **Assertions include deterministic loops/stress checks, not 613,333 different games or scenarios** |

C/C++ suites in the first run used AddressSanitizer and UndefinedBehaviorSanitizer,
`-Wall -Wextra -Werror -g -O1` (and pthreads for the arena stress). Swift helper
executables used `-warnings-as-errors`; they were not run under those sanitizers.
The second run disables the C/C++ sanitizers but still uses `-O1`: it is not an
optimized iOS Release benchmark. Raw output is retained in
`docs/validation/portable-sanitized.txt` and `portable-unsanitized.txt`.

Additional completed checks: all **17 Swift source files** grammar-parsed;
project IDs/references and source membership checked; modified shell scripts
parsed with `bash -n`; `git diff --check` passed; `git fsck --full` passed before
packaging. Grammar/source-membership checks are not an Xcode semantic build.
The Apple typecheck script correctly exited 2 on this host with its missing-SDK
message; **no Apple typecheck was completed**. An optional Clang static-analyzer
attempt on the prefix installer exceeded the command time limit and produced no
completed result; it is not counted as a pass.

## Preserved dependency pins / native build boundary

| Submodule | Pinned commit | Supplied state |
| --- | --- | --- |
| FEX | `053c385ecc9090702e4959a1d96752ea918a6110` | Empty, not initialized |
| Wine | `7817e220384e895651f868ba4d97affcf21b3816` | Empty, not initialized |
| research/dxmt | `b4b89f0a5a1752da3982a7b6c5575506024bf253` | Empty, not initialized |

These pins have not been replaced by upstream HEADs. The missing engines were
not fully audited or rebuilt. The focused `build/ntdll-unix/server_ios.c` logging
change only takes effect after rebuilding `libntdll_unix.a`. App-side .m/.mm/.c
changes take effect when the app is rebuilt. A previous binary in the archive
cannot demonstrate the new code's behavior.

On a Mac with full Xcode, the first independent check is:

```sh
bash tests/typecheck-ios.sh
```

It checks all project Swift against the iPhoneOS SDK and bridging declarations
without linking native libraries. The existing UI contains iOS 26 SDK symbols,
so this requires an iPhoneOS 26-or-newer SDK even though the project deployment
setting remains iOS 17. This host did not certify deployment-version compatibility
of the separately built native libraries.

Before a full native build, populate the exact pinned submodules and their
recursive dependencies, then prepare the project's generated FEX/Wine/LLVM
headers and static libraries using its existing toolchain/build scripts:

```sh
git submodule update --init --recursive
git submodule status
# After the required generated headers and libraries exist:
xcodebuild -project app/Madeira.xcodeproj -scheme Madeira \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

This is a build gate, not a claim that submodule checkout alone makes the entire
multi-toolchain project buildable. The supplied `build/*/build.sh` scripts have
additional generated-header/toolchain requirements. Select your own signing team
for installation; signing/JIT enablement mechanisms were not changed by this pass.
Do not push these local commits to any remote without the repository owner's
approval. Keep a backup of a working app and its prefix before device testing.

## Functional changes to try

Physical controllers are **off by default**. In portrait, open the game-controller
menu and enable “Controller → keys + mouse”; it lists mappings and speed/dead-zone
settings. Use Relative pointer mode for games expecting mouse look. This is a
keyboard/mouse preset, **not XInput, DirectInput, analog guest axes or rumble**.
Re-press/recenter controls after capture or dead-zone changes. Tap the keyboard
button to focus the guest before using physical keys. The current key mapping is
US-layout/generic modifiers, not full Unicode/IME or side-specific modifier support.

Quiet diagnostics are the default. The memory readout now uses a live OS estimate
and FPS measures guest-present calls, not proof that every frame reached scanout.
The landscape HUD has a real trailing gutter; the game aspect-fits the remaining
area. Rendering resolution and guest CPU memory ordering were not loosened to
manufacture a higher reported FPS.

## Important limits and remaining validation

No device screenshot comparison, GPU validation, CPU instruction-conformance
suite, shader compiler/conformance suite, audio test, game compatibility run,
energy/thermal measurement, or before/after game-FPS benchmark ran here. The
full remote-Metal integration suite needs the populated DXMT submodule plus a
running, explicitly selected macOS Metal host; only its portable wire suite and
runner failure behavior were executed here.

Queue bounds apply to **pending** compositor data (128 MiB/64 HWND slots), not all
retained Core Animation images, textures, in-progress copies or total process
memory. A pathological transition-only input overflow can lose historical taps;
the guarantee is bounded storage and eventual correct held state. Prefix merging
preserves existing regular files, but a late I/O error can leave complete newly
installed files for a retry; it is not atomic whole-prefix replacement or
power-loss certification. Readiness checks file presence/type/nonempty size, not
registry semantic validity. Existing damaged registries are not silently replaced.
The log UI is bounded; the complete on-disk log is not capped in this pass.

The original optional private display tuning remains runtime-checked and can be
disabled with `MADEIRA_DISABLE_PRIVATE_DISPLAY_TUNING=1`. This is not an App Store
compliance statement or a guarantee that an undocumented display workaround will
behave consistently across iOS versions.

Use `docs/DEVICE_VALIDATION.md` for the unexecuted release-acceptance checklist,
`docs/IMPROVEMENT_NOTES.md` for implementation details/tradeoffs, and
`docs/REFERENCE_REVIEW.md` for exactly which external code was examined.
