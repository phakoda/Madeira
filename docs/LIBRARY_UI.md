# Madeira library UI

The app opens to a saved game library with search, favorites, sorting, grid and list layouts, and a recent-game card. Settings contains input options, the Windows desktop, help, and diagnostics. Emulator sessions open full-screen. The native64 runtime retains the existing Metal display and input bridges. The x86 runtime presents an SDL view with its own touch and keyboard handling.

The design reference was MeloNX's [game cards](https://git.ryujinx.app/projects/MeloNX/src/branch/master/src/MeloNX/MeloNX/UI/Main/GamesList/Elements/GameCardView.swift) and [game library](https://git.ryujinx.app/projects/MeloNX/src/branch/master/src/MeloNX/MeloNX/UI/Main/GamesList/GamesListView.swift). Madeira uses an original charcoal and pale-green theme with typographic fallback covers. No MeloNX artwork or source files were copied.

## Imports and installation

- **Import game folder** copies the complete folder into `Documents/wine/drive_c/Madeira/Imports/<UUID>/Files`. One discovered executable is selected automatically. Multiple executables require a choice.
- **Open an installer** imports an EXE or MSI and opens its details. **Run installer** launches it in the Windows desktop. MSI packages use `msiexec.exe /i`. The user completes the Windows installer normally.
- **Add an executable** copies a standalone EXE. Apps with external DLLs or assets need a folder import.
- **Find installed apps** scans both Windows drives, excluding the Windows system directory and Madeira's imported payloads. Selecting an executable adds a shortcut without copying or moving the installation.
- Files can also send EXE and MSI documents to Madeira through **Open in**. Receiving a document imports it; the user chooses when to run it.

Installer folders can be imported through the folder action. Select the setup executable and change **Launch as** to **Windows installer**. This preserves companion CAB and data files.

Files are read under security-scoped access and file coordination. Copies use a unique staging directory, then a rename; failed imports remove their staged data. A JSON manifest stores paths relative to `drive_c`, so app-container relocation does not invalidate shortcuts. A damaged manifest produces an error and is not silently overwritten. Removing a shortcut preserves game files and saves.

Game folders may contain `cover.jpg`, `cover.png`, `folder.jpg`, or `folder.png`. The UI downsamples these images for library tiles. Games without artwork receive a generated letter cover.

## Launch behavior and limits

`LaunchPlan` validates the selected executable and constructs an argument array. The bridge reads that array as JSON, preserving spaces and Unicode. A working-directory override lets installers find adjacent files even when explorer or msiexec is the initial executable. Direct game launches read `steam_appid.txt` beside the executable when present. The bridge no longer assigns Thumper's identity to every app.

The existing Wine and FEX process state cannot safely be reset in place. One native session runs per Madeira process. Returning to the library leaves that session running; the session banner resumes it. After a 64-bit session ends, Madeira must be closed and reopened. The 32-bit interpreter supports successive sessions. Installed files and library entries persist. A zero exit code refers to the top-level Windows process, not proof that an installer completed successfully.

The PE header selects the native64 or interpreted x86 runtime. New MSI imports default to x86, with a 32-bit or 64-bit runtime choice in Details. MSI validation cannot establish the architecture of every embedded component. Installers, games, graphics APIs, DRM, and required Windows services remain subject to the existing engine's compatibility limits.

## Validation

No code was compiled locally for this change. Local checks cover project registration, document types, launch wiring, plist validity, diff whitespace, and source syntax inspection. They do not establish Swift type correctness, rendered UI behavior, or successful Windows installation.

GitHub Actions runs `python3 tests/check-library-source.py` and `bash tests/run-library-tests.sh` before building the IPA. The latter compiles production library and launch-plan code into a temporary macOS test executable. It covers complete folder copies, multiple executable selection, MSI arguments containing spaces and Unicode, working directories, PE validation, path rejection, failed-copy cleanup, repeated imports, installed-app discovery, persistence, and corrupt-manifest protection.

After building the IPA, device acceptance should cover:

1. Import a complete game folder from both local Files storage and a file provider. Confirm files remain available after relaunch.
2. Import an EXE installer and an MSI with spaces in its filename. Run their setup wizards, find the installed executables, then reopen Madeira and launch them.
3. Import a folder with multiple EXEs. Select each executable and confirm that its PE architecture selects the corresponding runtime.
4. Return to the library while a game runs, then resume. Confirm the Metal view and touch overlays stay hidden over the library.
5. Rotate on iPhone and iPad. Test the keyboard, physical mouse, controller, and touch controls inside the full-screen session.
6. Check search, favorites, sorting, list layout, large accessibility text, artwork, and errors for missing files or full storage.

The library and Settings include a standalone **Enable JIT** button. See [native 32-bit support findings](32_BIT_SUPPORT.md) for the Steam installer and x86 runtime constraints.
