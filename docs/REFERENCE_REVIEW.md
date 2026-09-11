# External reference review

These are focused source/documentation reads, not a claim to have audited or
ported entire emulators. Newly added code follows this repository's GPL-3.0-or-
later license; no third-party implementation file was copied into the tree.
Existing upstream/fork notices remain intact.

## User-provided references

**Melo-Controller** —
https://github.com/stossy11/Melo-Controller

Read `Sources/Melo-Controller/Joystick/Joystick.swift`, blob
`49ca5e4419f1ff2d6c1c98ef05495b45ae055496`. The reviewed UIKit pan handler publishes
zero on ended/cancelled gestures; the joystick uses radial normalization and a
rescaled dead zone. These behavior patterns informed input cancellation and
controller math. Madeira's window-level Metal host and source-owned key state
were retained rather than importing a UI package with a different input model.

**stossy11 repository listing** —
https://github.com/stossy11?tab=repositories

Reviewed the listing and the `stossy11/Mythic` root/submodule metadata. Mythic is a
Madeira fork with different submodule revisions; those revisions were not treated
as a safe drop-in upgrade. The uploaded Madeira commit remains the baseline.
This was discovery/metadata comparison, not a Mythic CPU/graphics code audit.

**MeloNX** — https://git.ryujinx.app/projects/MeloNX

The provided endpoint returned an Anubis “Access Denied” page, including on the
final retry. Its source was **not accessible for review** in this session.
No MeloNX-specific implementation or performance claim is made.

## Additional emulator code examined

**UTM** — https://github.com/utmapp/UTM

Read `Platform/iOS/Display/VMDisplayMetalViewController+Gamepad.m`, blob
`6ad5865a04c6bcbaf5fb3e60e21974a5bbedc6b2`: connection handling, extended-gamepad
button handlers, key/mouse mappings and stick-driven movement. Also read the
keyboard category, `VMDisplayMetalViewController+Keyboard.m`, blob
`9e83eef5afef1b142b2f01356c1ad23d6d583df2`, through its HID/PS2 tables and
pressesBegan/pressesEnded handling. Madeira's bridge takes VKs rather than UTM's
PS/2 scancodes, so those tables were not transplanted. No UTM renderer was ported.

**Pinned DXMT fork** — https://github.com/willfaust/dxmt

Read a focused range of `src/winemetal/unix/winemetal_unix.c` (approximately
1510–1650 at `b4b89f0a5a1752da3982a7b6c5575506024bf253`, blob
`54b495cb7948f910d21e88316e2b4ee423f555d4`), including compute encoding and the remote
render-packer entry path. This reinforced keeping actual production packer/decoder
coverage separate from portable wire-format checks. The pinned submodule was
empty locally, so its complete packer/client and shader pipeline were not built.
The 63-check portable wire suite is explicitly not full DXMT/GPU validation.

## Apple primary documentation checked

- Hardware key down/up and modifier events: *Support hardware keyboards in your
  app*, WWDC20 session 10109:
  https://developer.apple.com/videos/play/wwdc2020/10109/
- Extended gamepad buttons, optional thumbstick/options buttons and multiple
  controllers: *Supporting New Game Controllers*, WWDC19 session 616:
  https://developer.apple.com/videos/play/wwdc2019/616/
- Keyboard/mouse GameController framework background: WWDC20 session 10617:
  https://developer.apple.com/videos/play/wwdc2020/10617/
- System-controlled variable refresh: *Optimize for variable refresh rate
  displays*, WWDC21 session 10147:
  https://developer.apple.com/videos/play/wwdc2021/10147/
- Live process memory headroom: *Profile and optimize your game's memory*,
  WWDC22 session 10106:
  https://developer.apple.com/videos/play/wwdc2022/10106/

These references justify API/behavior choices, not successful execution on an
Apple device. See VERIFICATION.md for the actual validation boundary. Check
individual upstream contribution policies before submitting AI-assisted patches;
this pass creates local commits only and does not propose upstream contributions.


## Additional reads in the runtime-quality pass

Re-read the supplied Melo-Controller joystick at commit
`efe0373ede6ca4dc7d6533d7fa47ad52b4230fe8`; retained its zero-on-cancel behavior as a
reference rather than adding a dependency. Rechecked Mythic's root metadata:
its Wine/FEX pins differ from this archive and were not substituted blindly.

Read UTM's `Platform/iOS/Display/VMDisplayMetalViewController+Pointer.m`, blob
`b91c162848bad11755882ee6467d8b7d70c1f6ae`: GCMouse movement, Y-axis convention,
button/auxiliary handlers, disconnect cleanup and UIKit pointer/scroll paths.
The new bridge uses Madeira's own ownership and surface-scoped capture model;
it does not copy UTM source or import its SPICE stack.

Read the ring, converter and callback architecture in RetroArch's
`audio/drivers/coreaudio.c` on its `master` branch:
https://github.com/libretro/RetroArch/blob/master/audio/drivers/coreaudio.c
The bounded-copy/no-realtime-log approach and separate consumed-frame counter
are useful references. No RetroArch implementation was copied. This was a
focused source read, not a benchmark against RetroArch or a full driver audit.

Read the pinned Wine audio dispatch structures/order:
https://github.com/willfaust/wine/blob/7817e220384e895651f868ba4d97affcf21b3816/dlls/mmdevapi/unixlib.h

Microsoft's primary audio contracts were consulted for error/clock semantics:
- https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudiorenderclient-getbuffer
- https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudiorenderclient-releasebuffer
- https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient-reset
- https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient-start
- https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient-stop
- https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclock-getposition

Re-read Apple's WWDC20 session 10617 transcript and code for GCMouse callbacks,
scrolling and the distinction between relative input and top-level controller
pointer locking. The latter is explicitly not claimed by the new bridge.
