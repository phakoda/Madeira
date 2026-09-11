# iOS stability and performance pass

Starting revision: `97e2ce2` (the uploaded archive). Work is on
`improvements/ios-stability`; the original `main` history is preserved.

## Validation boundary

This editing environment has Linux, Clang, Python and Swift, but no Apple SDK,
Xcode, iPhone, or Metal device. The connected terminal was unavailable. Portable
production logic can be compiled and exercised here; iOS rendering, games,
thermal behaviour, signing and device frame rates cannot be certified here.
The archive has empty FEX, Wine and DXMT submodules. Their pinned revisions are
preserved, not replaced by arbitrary upstream versions. Direct Git fetch was
attempted but network access from the build container was unavailable.

This is a source improvement pass, not a claim that every game is glitch-free.
Existing bundled libraries are input artifacts, not newly rebuilt libraries.

## Audit priorities

1. Input queue overflow, event order and cancelled gestures must not leave keys
   or mouse buttons held.
2. Rendering geometry, surface lifetime and Core Animation updates must be
   deterministic. Never trade correctness for speculative fast-math or weaker
   guest memory ordering.
3. Diagnostics must be bounded and inexpensive by default.
4. Prefix installation must detect corrupt/truncated archives rather than
   silently succeeding with a damaged Wine prefix.
5. Tests must exercise the actual shared production helpers, not replicas.

## Baseline

The existing portable remote-Metal wire suite runs: **63 checks, 0 failures**.
The complete remote-Metal suite additionally needs DXMT's populated submodule
and a macOS Metal daemon, and was not run here.

Further changes, test commands and device acceptance checks are recorded below
as they are implemented.

## Input queue (first implementation commit)

Replaced silent overflow drops with adjacent-motion coalescing, preferential
motion eviction, and bounded authoritative state reconciliation when the queue
contains transitions only. Relative samples sum without signed overflow; absolute
samples retain the latest position without crossing button/key/wheel barriers.
Wine pumps are serialized through delivery, without holding the producer lock
across Wine IPC, and have a finite work budget. Added an explicit release-all API.

Normal input no longer formats/flushes per-event logs or dumps window trees and
all thread stacks unless diagnostics are enabled. Regression tests compile the
**actual production header**, including a deterministic 200,000-event stress run,
held-key/button overflow, cancellation, motion ordering, and integer boundaries.
ASan/UBSan result: **200,991 input checks; 63 existing wire checks; zero failures**.
At pathological transition-only overflow, historic taps can still be lost; the
contract is bounded memory and eventual correct held state, not lossless unbounded
input buffering.
