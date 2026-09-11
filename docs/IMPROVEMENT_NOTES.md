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

## Touch, geometry, and display bridge

On-screen controls now have source ownership: releasing one W/arrow/mouse control
cannot release another control that still holds the same input. Gesture-state
cancellation, disappearing/remapped controls, view detachment, and application
focus loss release their held inputs. Trackpad touches are restricted to the
actual input view; a finger pressing another control no longer becomes a scroll
finger. A second finger ends an existing drag before scrolling. Cumulative travel
prevents a slow scroll from becoming a right-click. Direct input tracks a single
owning touch, and gesture timing uses a monotonic clock. Sensitivity and desktop
sizes are validated before integer conversion. Software keyboard modifier taps
participate in source ownership; non-ASCII letter expansions are no longer sent
as misleading ASCII letters (full Unicode input remains unsupported).

Presentation aspect-fits the current drawable rather than hard-coding 4:3, while
input maps into Wine's logical desktop size. DXMT remains the sole drawableSize
writer. The process-lifetime Metal layer is preserved across reattachment, hidden
on detachment, and its frame changes do not implicitly animate. A lightweight
four-times-per-second active-view check catches swapchain resolution changes;
this timer and the idle-timer override stop on loss of focus.

The macdrv display shim now owns a separate window-data record per acquisition,
removing the shared HWND race between swapchain creators. Existing optional
private display tuning uses signature-checked scalar invocation instead of
passing NSNumber object pointers to BOOL/integer setters. Unsupported signatures
are skipped. Set `MADEIRA_DISABLE_PRIVATE_DISPLAY_TUNING=1` before layer creation
to disable that pre-existing workaround. This is not a claim of public-API-only
or App Store compatibility; its device behavior still needs A/B validation.

Portable Swift tests: **10,026 geometry and input-ownership checks passed**.
UIKit source was syntax-parsed, not SDK-typechecked or device-tested.

## Desktop/GDI compositor

The real compositor now uses a tested full-surface mailbox: one pending immutable
frame per HWND, with dimensions/stride traveling together with the pixels. A
new frame replaces a superseded complete image, rather than allocating another
main-queue presentation closure. Main-queue tickets distinguish window reuse;
destroy invalidates the old pending frame before enqueueing removal. This relies
on Wine's normal contract that no new flush is issued for a destroyed window.
The queue is bounded to 64 pending HWNDs and 128 MiB of pending DIB data, with
power-of-two pressure reports. These are queue resource limits, **not** an iOS
jetsam estimate or a limit on all live textures or transient copies.

Image dimensions, row alignment, row capacity, overflow, and the byte ceiling are
checked before copying. Wine producer calls now own an autorelease pool. Ordinary
frames bypass diagnostic hashing/census/tree work entirely. The main-thread path
uses a cached sRGB color space, honors opaque BGRX semantics, disables implicit
contents/geometry animation, and clears all window-associated metadata on destroy.
Cursor placement is recalculated when the desktop layout changes. No speculative
alpha reinterpretation, GPU fast-math change, or shader-output hack was applied.

Portable production-policy result: **20,157 surface layout/mailbox checks passed**
under ASan/UBSan, including 10,000 successive frames for one HWND, pending-window
reuse, stale tasks, budget exhaustion/recovery, and malformed layouts. Actual
Core Animation/Metal output, color fidelity, and GPU timing require the device
checks below; they cannot be certified by these host-side tests.

## Logging correctness and bounded work

Replaced index-based pending UI updates with locked, bounded signature buckets
and stable record IDs. Each flush merges and publishes once; repeated messages
in the same batch are counted exactly. Regexes are compiled once. The tail is
the sole UI feed for persisted records, preventing callback/tail double-counts.
Swift log writes use one locked O_APPEND descriptor rather than opening a handle
per event. FEX/JIT callbacks persist through that sink, with stderr as fallback;
ntdll's source logger likewise chooses file or stderr, not both. The ntdll change
requires rebuilding its native library; the bundled binary remains unchanged.

The serial tail has one timer and one descriptor owner. It handles observed
truncation and inode replacement, idempotent start/stop, retry cancellation,
split UTF-8/CRLF, and oversized lines with bounded memory. Each read turn has a
256 KiB work budget. The console Clear button now clears the console only: it
never replaces the log inode underneath native writers. Complete logs remain
on disk. This pass bounds the UI queue, not the total on-disk log size.

Compiled production Swift helpers passed **1,061 logging checks**, including
64,000 concurrent bucketed events and 1,000 concurrent file appends, stable IDs,
rotation/truncation, descriptor reuse, failed writes, and stop-before-open.
UIKit/SwiftUI integration remains syntax-only validated on this host.

## Prefix installation and startup integrity

Replaced the 512-byte-copy, unchecked tar reader with a 64 KiB streaming
installer. It handles the actual bundled template's ustar prefix names, PAX
path/size records, and GNU long names; validates tar checksums, declared sizes,
member paths/types, both end blocks, and the gzip CRC/trailer; and bounds entries,
depth, metadata, individual files, and total decompressed bytes. Symlink/hardlink,
device, and sparse archive entries are deliberately rejected (the bundled
archive has none). Unexpected archive roots and reserved staging paths fail.

All extraction is private staging first. Only after full archive validation are
complete, fsynced files linked into the prefix. Existing regular files, including
registries and saves, are preserved. The completion marker is installed last.
A merge I/O error can leave complete new files for a non-destructive retry; this
is not a claim of an atomic whole-directory replacement or power-loss proofing.
Staging is cleaned on ordinary failures. Destination-relative directory walks
never follow symlinks. The caller supplies an existing destination parent.

A portable readiness gate checks essential files before Wine startup. Prefix
preparation errors now propagate to wineserver_start; Wine refuses to start
without its server. Registry/profile repair no longer runs again from the Wine
process thread after the server already owns the registry. dosdevices/c: repair
will only replace a symlink, never recursively delete an existing user directory.
Existing damaged registries are not silently overwritten with default data.

**850 assertions across 174 archive fixtures passed under ASan/UBSan**, including
128 deterministic header mutations and comparison of every one of the **138
shipped template members** (32 regular files byte-for-byte via SHA-256 and 106
directories). Tests cover long names, corrupt headers/trailers, truncation,
partial-seed recovery, preserved user data, links, conflicting file types,
resource limits, and missing/empty essential prefix files. Objective-C startup
integration still requires an Apple build and a fresh-prefix device test.

## Honest, lower-overhead performance telemetry

The overlay now has one 250 ms sampler/publication timer instead of separate
100 ms sample and 250 ms display timers. Hidden overlays stop sampling; inactive
or detached views release their refresh request. Per-view refresh leases prevent
rotation teardown from cancelling a newly attached overlay's request. Requested
refresh ranges are bounded by the screen's reported maximum; power/thermal
policy can still lower actual refresh. The pacing button no longer shares its
tap handler with hiding the readout.

The production FPS sampler uses monotonic time, bounded history, and reset/wrap
handling, not wrapping unsigned subtraction. Tests also exposed a low-FPS bias
in the old "stop at the third change" window: three frames in a cherry-picked
2.25 seconds could show 1.33 FPS for a 1 FPS stream. Duration-based adaptation
avoids that bias. The counter measures guest presents, not physical scanouts.

Memory warning colors use the OS's live process-available-memory estimate,
not a hard-coded 4 GiB jetsam limit. Failed footprint readings are shown as
unknown rather than zero. Available memory is an estimate, never a guarantee
that a particular allocation will succeed or a fixed termination threshold.

**110,208 portable sampler assertions passed**, covering steady 19/60/120 FPS,
1 FPS, stalls, count reset and UInt64 rollover, duplicate/invalid/backwards
clock samples, and bounded history under 1,000 Hz sampling. UIKit/QuartzCore
lifecycle and the OS memory query need device validation. References:
Apple, *Optimize for variable refresh rate displays*, WWDC21 session 10147;
Apple, *Profile and optimize your game's memory*, WWDC22 session 10106.

## Translation bridge allocation safety

The FEX bridge's bump allocator now uses checked alignment and atomic compare/
exchange reservation. Oversized, zero, exhausted, and overflowed requests fail
without consuming remaining capacity; the old fetch_add consumed capacity even
on failure and could wrap. Address containment no longer adds base+capacity.
Normal successful allocations no longer format per-allocation log lines.
Executable-memory setup, guest ordering, code generation, cache coherency, and
pool lifetime/reclamation policy are unchanged. This does not rebuild or alter
the missing FEX engine submodule.

**148,025 assertions passed under ASan/UBSan**, including **128,000 successful
non-overlapping reservations on 32 threads**, overflow/alignment boundaries and
repeated exhaustion/recovery checks. This is allocation correctness testing,
not a measured game-FPS improvement or a ThreadSanitizer result.
