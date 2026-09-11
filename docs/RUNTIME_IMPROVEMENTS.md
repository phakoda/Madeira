# Runtime quality pass

Starting point: `9f492bc`, preserving the supplied `improvements/ios-stability`
history. New branch: `improvements/runtime-quality`.

## Controller compile fix

Qualified the shared `MetalBackedView.cursor` with `Self` inside the controller
pointer method. Swift syntax parsing alone did not detect this static/instance
member error. The actual method was extracted and typechecked against minimal
boundary stubs; this is not an Apple SDK typecheck of the full UI.

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
