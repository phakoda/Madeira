# Runtime quality pass

Starting point: `9f492bc`, preserving the supplied `improvements/ios-stability`
history. New branch: `improvements/runtime-quality`.

## Delivery and verification summary

This is a source update, **not a newly built or device-tested IPA**. The final
executable source/tests were checked at `2995da60381a4edc97389df663728fc6c75d5338`;
the later handoff/documentation commit adds no executable changes. The host is
Linux x86_64 with Clang 17.0.0, Swift 6.2.1 and Python 3.13.5. It has no Apple SDK,
Xcode, iOS device or Metal runtime. Existing input artifacts and engine pins are
preserved; missing engines/native libraries were not silently replaced.

Both full-suite runs passed:

| Executed suite | Sanitized-run checks | Unsanitized-run checks |
| --- | ---: | ---: |
| Remote-Metal portable wire/decoder | 63 | 63 |
| Input queue | 200,991 | 200,991 |
| Cursor mailbox and image bounds | 102,087 | 102,087 |
| Surface layout/mailbox | 20,157 | 20,157 |
| Audio driver, mocked Apple/Nt boundaries | 1,308,168 | 1,261,131 |
| Geometry/input ownership | 10,026 | 10,026 |
| Logging | 1,061 | 1,061 |
| Prefix installation | 850 | 850 |
| Frame-rate sampling | 110,208 | 110,208 |
| Checked arena | 148,025 | 148,025 |
| Controller/keyboard | 121,928 | 121,928 |
| Physical mouse and production pointer routing | 200,054 | 200,054 |
| Remote-runner failure behavior | 17 | 17 |
| Template tooling | 7 | 7 |
| Native build orchestration, mocked compiler/SDK | 49 | 49 |

Counts include loop/stress assertions, not that many independent scenarios or
games. The audio count depends on host scheduling and underrun frequency; both
runs transfer and verify one million sequenced frames. C/C++ use ASan/UBSan in
the first run; Swift is compiled with warnings as errors, not those sanitizers.
The second run disables sanitizers but retains `-O1`; it is not a Release
performance benchmark. No ThreadSanitizer run is claimed.

Raw output: [sanitized](validation/runtime-portable-asan.txt) and
[unsanitized](validation/runtime-portable-nosan.txt). All 19 project Swift sources
also passed syntax parsing and source-membership checks. Modified shell scripts
passed `bash -n`; `git diff --check` and a standalone `git fsck --full` passed.
A combined validation command initially reached its time limit after the full
unsanitized suite passed; the standalone Git integrity retry completed normally.

For the missing inputs, native rebuild steps and Apple checks, read
[the native build handoff](NATIVE_BUILD_HANDOFF.md). For unexecuted hardware
acceptance cases, use [the device checklist](DEVICE_VALIDATION.md). The earlier
[verification report](VERIFICATION.md) describes only the supplied prior pass.

## New commit sequence

The implementation was committed in stages, not flattened into one final diff:

```
f44c0de fix(input): qualify shared cursor in controller pointer routing
ef8deee fix(audio): enforce format, buffer, allocation and stream lifecycle contracts
f2c5871 feat(audio): implement volume, bounded realtime rendering and underrun-safe clocks
e9891f3 feat(input): add surface-scoped physical mice with owned buttons and precise motion
113382b perf(cursor): coalesce background moves and avoid redundant main-queue dispatch
6ec746c fix(build): isolate native objects and publish archives transactionally
2995da6 test: exercise production pointer routing and add Apple audio validation gate
```

A final documentation commit records the complete results and handoff. The
archive includes `.git`, original branches/history and the current branch, so
`git log 9f492bc..HEAD` and `git diff 9f492bc..HEAD` show this pass independently.
No commits were pushed to an external repository.

## Controller compile fix

Qualified the shared `MetalBackedView.cursor` with `Self` inside the controller
pointer method. Swift syntax parsing alone did not detect this static/instance
member error. The actual method was extracted and typechecked against minimal
boundary stubs and exercised for absolute/relative movement, edge clamps,
resize and shared position. It is now part of the repeatable mouse suite, not
a one-off check. This is not an Apple SDK typecheck of the full UI.

## Audio client contracts

The actual production `audio_null_ios.c` is now compiled and executed on the
host against small test-only AudioUnit, Mach clock, and Nt event boundary mocks.
The initial new contract suite passes 9,669 checks with ASan/UBSan, covering
format negotiation, request pairing, duration bounds, allocation failures,
registry exhaustion, stale handles, null fallback, clock arithmetic and timer
join-before-free. Hardware behavior is not simulated or certified.

Changes:

- Validate mono/stereo interleaved PCM 8/16/24/32-bit and IEEE float32 at
  8–192 kHz, exact block alignment, byte rate, and full extensible GUID/layout.
  Unsupported compressed/surround/float64 formats are no longer falsely
  accepted. Preserve the stable endpoint identifier, improve its display name.
- Make WAVEFORMATEX's 18-byte ABI explicit. Clamp duration before multiplying
  and round frame counts up. Preserve the existing 100 ms safety floor and
  four-second maximum, pending device latency measurements.
- Preallocate both ring and scratch before publishing an opaque, non-reused
  stream handle. Allocation and registry failures leave no partially live client.
- Enforce GetBuffer/ReleaseBuffer ordering, size and flag validation, and the
  zero-frame pointer contract. Failed releases retain the outstanding request.
  No mixer-tick reallocations, including in clock-only fallback.
- Reject Reset while playing or holding a buffer; make timer control/event
  fields atomic and keep join-before-free teardown. Control/producer calls still
  rely on Wine's serialized client and COM lifetime rules, not arbitrary use of
  a stream after Release.
- Bound padding snapshots, widen time conversions, and reject unimplemented
  rate changes instead of changing only bookkeeping while hardware stays fixed.
- Gate periodic hot-path audio diagnostic counters and formatting behind the
  existing live diagnostics switch.

These changes affect `libntdll_unix.a` and require rebuilding it. Bundled binary
libraries are supplied input artifacts, not rebuilt by this host-only pass.

## Real-time audio, volume and clock

The follow-on audio suite additionally runs one million sequenced frames through
concurrent production and rendering, checking every delivered frame and every
underrun tail. The exact assertion count varies with host scheduling (over one
million checks). Sanitizers pass. Further coverage checks all negotiated PCM
widths, unaligned packed samples, float32, unity/mute/per-channel/session gain,
invalid output layouts and byte bounds, unsigned silence, and restart failure.

- Implement previously ignored master, stream-channel and session-channel volume
  by combining bounded gains on the control side. Apply them when consuming the
  queue, so volume changes affect already-buffered sound. Unity is byte-exact and
  bypasses sample arithmetic; mute uses a bulk fill. Callback loads are lock-free
  atomic integer bit patterns. Nonfinite control values cannot trigger undefined
  float-to-integer conversions or amplification.
- Validate the interleaved AudioBufferList and its byte capacity before writing;
  copy a wrapped ring in at most two chunks. There is no callback allocation,
  logging, registry lock, or Wine API call. Fill unsigned PCM8 silence with 128,
  not zero, and report fully silent output to Core Audio.
- Separate queue consumption from the rendered-frame clock. Underruns now advance
  time while padding stays zero. Stop/resume preserves position; Reset clears it;
  a failed hardware resume carries position into clock-only fallback. The clock
  remains callback-granular, not a measured speaker-latency-corrected timestamp.
- Return the documented repeated Start/Stop statuses. A failed AudioUnit stop
  does not falsely mark a still-running callback as quiescent.
- Count underruns atomically without logging from the render callback.

Contracts were cross-checked against Microsoft's IAudioRenderClient GetBuffer /
ReleaseBuffer and IAudioClient Reset / Start / Stop / IAudioClock GetPosition
references. The 37-entry dispatch ordering and audio parameter structures were
also inspected against the pinned Wine `dlls/mmdevapi/unixlib.h` at
`7817e220384e895651f868ba4d97affcf21b3816`. The tests' Apple declarations are
boundary mocks, not a substitute for compiling with the genuine Apple SDK.


## Opt-in physical mouse input

The input menu now includes physical mouse capture and sensitivity. Capture is
restricted to a pointer hovering inside the active guest surface, not host
controls or a presented modal. It uses the existing absolute/relative pointer
mode and public GCMouse handlers. This does **not** lock the OS pointer: moving
outside the guest releases capture, and unrestricted FPS camera movement still
needs a separately validated pointer-lock host implementation.

Implemented left/right/middle and the first two auxiliary buttons, horizontal
and vertical wheels, finite/saturating fractional motion accumulation, and
source ownership shared with touch/controller input. Disconnect, background,
modal entry, view replacement, leaving the surface and disabling the feature
invalidate old callback generations and release only their own held buttons.
Native indirect-pointer touches are not duplicated as touch taps during capture.
No polling/display-link timer was added to mouse input; it uses device callbacks
and the display's existing lifecycle check.

The real production bridge is typechecked and executed against small test-only
UIKit/GameController/Combine boundary modules. Its suite passes 200,054 checks,
including 100,000 conservation-of-motion steps, focus/rotation/disconnect,
multiple-mouse ownership, stale callback rejection, side-button payloads and
fractional wheel input. These tests do not certify Apple's real API availability,
UIKit hover ordering, external hardware or OS pointer behavior. Use the genuine
Apple-SDK typecheck and device matrix before distribution.

## Cursor rendering overhead and bounds

Absolute movement from the main/UI thread now places the cursor directly instead
of allocating another dispatch block per sample. Wine-thread motion is coalesced
into a latest-position mailbox with at most one queued UI wake-up. A queued task
cannot replay an older position over a newer inline update. This affects visual
cursor placement only; guest clicks, key transitions and motion ordering remain
in the existing native input queue.

The production scheduling/layout policy passes 102,087 sanitizer checks,
including 200,000 publishes from eight threads that require only one queued
wake-up. This is a measured task-count reduction for a blocked-UI burst, not a
game-FPS or frame-latency measurement.

Cursor image dimensions are checked before byte/stride arithmetic and limited
to 1024 × 1024 (4 MiB per submitted image); hotspots are bounded. Failed
CoreGraphics allocations now stop cleanly. Hide/show state survives creation of
the cursor layer. Core Animation behavior and visual appearance need device
validation; cursor image-shape jobs themselves are not mailbox-coalesced.


## Native build integrity

The ntdll build used to archive and publish even when compilation had failed,
allowing old object files to conceal errors. Several native scripts also reused
object directories/archive members after a source had been removed. These are
correctness problems: a successful-looking build could run different code from
what is checked into Git.

The ntdll, win32u, wineserver-patch and DXMT scripts now build in fresh, isolated
object directories. Compiler failures stop publication. A shared helper verifies
that the result is a nonempty regular archive, then copies to a temporary file
beside the destination and atomically renames it. Failed staging directories keep
compiler diagnostics; successful ones are cleaned. Win32u merges FreeType into a
separate archive rather than overwriting an input archive. DXMT uses shell arrays
for flags and includes, and ntdll/win32u source paths are quoted, including paths
containing spaces. No dependency versions, optimization levels, or FEX memory
ordering settings were changed.

An offline regression suite executes the production shell scripts and real `ar`,
with deliberately mocked compilers/SDKs. It verifies ntdll/DXMT failure and success,
stale-object exclusion, diagnostics retention, paths containing spaces, invalid
archives, and copy/archive failures. Its 49 checks passed. The common publication
helper is tested directly; the complete win32u/wineserver orchestration is not
exercised by that suite. This is not evidence of a successful Apple native build.
Wineserver remains a patch-on-existing-library build, not a clean full-source
reconstruction. Concurrent successful builds can publish in either completion
order (last completed publication wins), but cannot publish a partially copied
library.


## Independent native validation gates

`tests/typecheck-ios.sh` checks all 19 production Swift files against a genuine
Apple SDK without linking engines. The new `tests/typecheck-audio-ios.sh` checks
the actual audio driver against Apple's AudioToolbox/Mach declarations without
requiring Wine generated headers. Neither was executable on this Linux host;
both correctly report the missing Apple SDK and exit 2. They are supplied for
native validation, not recorded as successful Apple builds. The driver now also
has compile-time requirements for 32-bit float storage and always-lock-free
integer atomics so an unsupported target cannot silently use locks in the render
callback.
