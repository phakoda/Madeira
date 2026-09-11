# Native build handoff — runtime-quality pass

## What this archive is

An updated source tree with the complete supplied Git history plus the new local
commits. It is not an IPA, a ready-to-link native workspace, or a claim that any
particular Windows game was tested. No JIT authorization, signing, entitlement,
CPU memory-ordering or engine-version mechanism was changed in this pass.
The portable regression suite does not require the Apple SDK or engine checkout.

## Confirmed missing prerequisites in the supplied source snapshot

The engine submodules are empty; their exact Git pins are preserved:

| Path | Required pinned commit |
| --- | --- |
| `FEX` | `053c385ecc9090702e4959a1d96752ea918a6110` |
| `wine` | `7817e220384e895651f868ba4d97affcf21b3816` |
| `research/dxmt` | `b4b89f0a5a1752da3982a7b6c5575506024bf253` |

The generated Wine headers (`wine/build-macos/include/config.h`, among others),
FEX build outputs, GnuTLS development prefix, LLVM source/build trees and generated
DXMT shader headers are also absent. The project's scripts refer to those inputs.
A successful `git submodule update` alone does not create the generated toolchains.

The Xcode project expects these four additional libraries beside the app sources:

```
app/Madeira/libntdll_unix.a
app/Madeira/libwineserver.a
app/Madeira/libwin32u_unix.a
app/Madeira/libdxmt_combined.a
```

They are missing in this uploaded snapshot, as are the seven FEX-related archives
referenced under `FEX/build-ios`. The supplied GMP/GnuTLS/Nettle/Hogweed archives
are preserved, but do not substitute for their missing development headers or
for the missing Wine/FEX/DXMT archives. No binaries were newly downloaded or built.

**Important bootstrap limitation:** `build/wineserver/build.sh` is a patched
archive rebuild. It requires a pre-existing compatible `libwineserver.a`; it does
not reconstruct the full server from an empty tree. The new transactional staging
makes this failure explicit and safe, but does not invent a replacement base
archive. Recover/rebuild that base from the project's original native toolchain
before invoking the patch build. Do not rename an unrelated archive to satisfy it.

## Reproduce the host checks

From the extracted `Madeira` directory, with Clang, Clang++, Swift and Python 3:

```sh
bash tests/run-portable.sh
SANITIZE=0 bash tests/run-portable.sh
```

Both commands ran successfully on the Linux host. C/C++ tests use AddressSanitizer
and UndefinedBehaviorSanitizer by default. Swift tests and boundary mocks are
separate from the genuine Apple frameworks. The second command still uses `-O1`;
it is not an optimized iOS benchmark. See the saved logs under `docs/validation`.

## Independent Apple SDK checks

On a Mac with full Xcode selected, run:

```sh
bash tests/typecheck-ios.sh
bash tests/typecheck-audio-ios.sh
```

The first typechecks the complete project's Swift/bridge declarations, without
linking native engines. The existing UI uses iOS 26 SDK symbols, so it checks for
an iPhoneOS 26-or-newer SDK. The second checks the production audio source against
Apple AudioToolbox/Mach declarations, independently of Wine generated headers.
Neither script links or runs an app. Both intentionally exit 2 on a non-Apple
host. Their missing-SDK guards were tested here; the actual Apple checks were not.

## Prepare and build the native app

Keep a backup of a working app/prefix. Populate the exact source pins and recursive
dependencies on the build machine; do not substitute another fork's latest HEAD:

```sh
git submodule update --init --recursive
git submodule status
```

Prepare the existing project's FEX/Wine/GnuTLS/LLVM/FreeType/DXMT toolchains and
generated inputs. Consult each `build/*/build.sh` and `build/dxmt-ios/README.md`
for its inputs and output location. This pass did not verify a full clean
multi-toolchain bootstrap. In particular, the DXMT native build emits
`build/dxmt-ios/libdxmt_unix.a`; that alone is not the combined archive the app
links. Keep architecture, SDK/deployment target and ABI compatible across all
components rather than mixing arbitrary prebuilt outputs.

After those prerequisites are ready, **rebuild ntdll** to include the audio and
logging changes, and rebuild the app for the new Swift/Objective-C source:

```sh
bash build/ntdll-unix/build.sh
# With every Xcode-linked native library prepared at its expected location:
xcodebuild -project app/Madeira.xcodeproj -scheme Madeira \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

This is the required build procedure to validate, not a claim it succeeded here.
The ntdll/win32u/DXMT/wineserver-patch build scripts now isolate object files and
publish only complete archives. On a failure, the printed `.objects.*` staging
path retains diagnostic files. Fix the actual compiler error; do not copy stale
objects over the failure or bypass the publication checks. Use your own existing
signing/provisioning setup for device installation.

## Device acceptance and performance

Run `docs/DEVICE_VALIDATION.md`, including the new audio and physical-mouse cases.
Compare this runtime pass against `9f492bc` with identical device, game/save,
resolution, thermal state, pacing and diagnostics. Record visible frame-time
stalls and end-to-end input/audio latency, not just the guest-present counter.

Physical mouse capture is off by default, scoped to the guest surface, and is not
OS pointer lock. The existing controller preset is keys/mouse emulation, not a
native Windows XInput device. Audio still has a clock-only fallback, a 100 ms
minimum ring capacity, no newly implemented interruption recovery, no variable
rate resampler, and no capture/loopback/MIDI backend. These limitations are not
hidden by passing portable tests. No native GPU, CPU-instruction conformance,
thermal/battery, game compatibility or FPS measurements were made in this pass.
