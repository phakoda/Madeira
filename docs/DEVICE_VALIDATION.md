# Device release-acceptance checklist — NOT EXECUTED HERE

These are proposed checks for a native Apple build, not claimed test results.
Keep original `main`/`97e2ce2` available for A/B comparison and back up the app's
prefix, saves and logs. Start with diagnostics off and the controller preset off.
Do not label this build glitch-free until the relevant device/game paths pass.

## Build and startup gates

Run `tests/typecheck-ios.sh` on a Mac with the required SDK, then a full native
Debug and Release build with the exact pinned engine sources/generated headers.
Rebuild ntdll's static library to include its modified logging sink. Confirm the
Release executable still exports `macdrv_functions` and the display-shim fallback
symbols used by DXMT through dlsym (dead stripping must not remove them). Use the
project's existing signing and supported JIT setup; this pass did not change it.

On a disposable fresh app prefix, verify first launch seeds all template files,
creates the expected c: symlink and boots Wine. Repeat with an existing prefix
containing a known save and customized registry values: they must remain intact.
A deliberately corrupt test template must abort startup with a useful log and no
completion marker, not launch Wine with an empty registry. Do not perform damage
or low-disk tests against the only copy of a real user's prefix.

## Rendering and presentation

| Check | Acceptance / evidence to collect |
| --- | --- |
| 4:3, 16:9 and other supported swapchain sizes | Aspect correct; no stretch/crop; HUD outside native surface; input maps to displayed guest content |
| Portrait/landscape rotation and reattachment | Same live Metal layer retained; no black/stale layer, implicit resize animation or HUD occlusion |
| Background/foreground, lock/unlock, host sheets | No held controls on return; no dead timers or permanently blank game/desktop |
| Near-idle / 1 FPS and static desktop | Updates become visibly present without screenshots or unrelated UI re-renders; guest-present counter alone is insufficient evidence |
| Resizing/moving many desktop windows | Correct stride/crop/colors; no old-size image interpreted with new metadata |
| Window destruction/reuse under rapid flushes | No image resurrected by an old main-queue ticket; no leaks or wrong-HWND Metal layer |
| GDI text, opaque black regions, cursor | No accidental transparency, clipped glyphs or cursor drift after resize |
| Metal API validation and GPU captures | No reported resource/lifetime/synchronization errors in exercised scenes; save captures for unexpected artifacts |

Pending-frame bounds do not bound every active window's retained image/GPU
texture. Use Instruments/process footprint as well as the pending-queue model.
Evaluate the existing private display workaround on/off separately; do not infer
its effectiveness from a changing present counter alone.

## Input and functionality

Hold a touch key while pressing/releasing the same hardware/controller key. The
original held source must remain held. Repeat with two controllers, both Shift/
Ctrl sides and simultaneous pointer buttons. Cancel a gesture, rotate, unplug a
keyboard/controller or background while holding keys: no guest key/button should
remain latched. Test a second finger joining a drag; it must release the drag
before two-finger handling. Slow scrolling must not become a right-click, and a
finger on a separate on-screen control must not join the trackpad's touch set.

Enable the optional controller menu preset. Test all listed buttons on at least
one extended-gamepad controller, including disconnect/reconnect and absent
optional buttons. Verify right-stick motion continues while the stick is held
still off-center, stops at center and has comparable speed on 60/120 Hz devices.
Confirm left-stick diagonals/hysteresis and Absolute/Relative pointer modes.
This is not native XInput; games requiring a guest gamepad still need that backend.

Focus the guest keyboard view and exercise held WASD, arrows, modifiers, keypad,
function keys, repeated text, cancelled presses and reserved system shortcuts.
Check software keyboard characters do not duplicate physical key events. Test
host text fields independently; they must not type into the guest. US-layout and
generic modifiers are the implemented mapping; IME/Unicode/side-specific behavior
requires additional work rather than a false pass.

Run the project's legal graphics/input test executables and personally owned
games in both desktop and fullscreen paths. Audio, shader translation, x86 CPU
instruction correctness, launch/network/file dialogs, save/load and per-game
compatibility are separate gates not covered by the portable helper tests.

## Logs, performance and endurance

Generate a sustained diagnostic log burst, clear only the console, and verify
native and Swift writers keep appending to the same log. Check exact duplicate
counts, visible error messages, bounded UI memory and continued input responsiveness.
Then turn heavy diagnostics off for performance measurements.

For before/after measurements use the same device, game/version/save, scene,
resolution, pacing mode, thermal state, power mode and diagnostics setting. Record
more than one run. Measure frame-time distribution (including long stalls),
visible presentation, CPU/GPU time, process memory/headroom and thermal behavior;
report guest-present throughput separately from scanout. Capture both cold-start
and warmed shader/cache behavior. Exercise a longer session and app lifecycle
transitions to look for retained resources, log growth and stuck input.

No numerical performance gain is asserted by this source pass. Reduced hot-path
logging, bounded backlog and fewer UI timer publications are implementation
changes; real performance benefits and remaining visual defects require these
native measurements.
