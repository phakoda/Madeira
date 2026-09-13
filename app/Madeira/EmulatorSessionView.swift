import SwiftUI

@MainActor
struct EmulatorSessionView: View {
    @ObservedObject var session: EmulatorSession
    @ObservedObject private var input = InputSettings.shared
    @Environment(\.verticalSizeClass) private var verticalSize
    @AppStorage("session.showFPS") private var showFPS = false
    @State private var confirmStop = false

    private var showsDisplay: Bool { session.phase == .running || session.phase == .starting }
    var body: some View {
        Group {
            if showsDisplay {
                if verticalSize == .compact {
                    HStack(spacing: 0) {
                        display
                        VStack(spacing: 18) {
                            libraryButton
                            Spacer(minLength: 0)
                            keyboardButton
                            pointerButton
                            closeWindowButton
                            if showFPS && session.runtime == .native64 { FPSOverlay(compact: true) }
                        }
                        .padding(.vertical, 12).frame(width: 100)
                        .background(MadeiraStyle.background)
                    }
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            libraryButton
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(session.title).font(.headline).lineLimit(1)
                                Text(session.status).font(.caption).foregroundStyle(MadeiraStyle.secondary)
                            }
                        }
                        .padding(16)
                        display
                        if session.phase == .starting {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Starting Windows. This can take a moment.").font(.caption)
                            }.padding(12)
                        }
                        HStack(spacing: 18) {
                            keyboardButton
                            if session.runtime == .wine32 {
                                interpreterKey("Esc", scancode: 41)
                                interpreterKey("Tab", scancode: 43)
                                interpreterKey("↵", scancode: 40)
                            } else {
                                HoldKeyView(label: "Esc", vk: 0x1B)
                                HoldKeyView(label: "Tab", vk: 0x09)
                                HoldKeyView(label: "↵", vk: 0x0D)
                            }
                            Spacer(minLength: 0)
                            pointerButton
                            closeWindowButton
                        }
                        .padding(16)
                        if showFPS && session.runtime == .native64 { FPSOverlay().padding(.horizontal, 16) }
                    }
                }
            } else { sessionMessage }
        }
        .background(MadeiraStyle.background.ignoresSafeArea())
        .tint(MadeiraStyle.accent)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .confirmationDialog("End the 32-bit Windows session?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("End session", role: .destructive) { session.stopWine32() }
        } message: {
            Text("Exit the game or installer first to save your work. Ending the session closes every 32-bit Windows app.")
        }
        .onDisappear {
            MetalBackedView.keyboardTarget?.resignFirstResponder()
            GuestInput.shared.releaseAll()
            TouchControlsHost.hide()
            JoystickPadState.shared.hidden = true
            MetalHostView.shared.isHidden = true
        }
    }

    @ViewBuilder private var display: some View {
        if session.runtime == .wine32 {
            Wine32Display()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .accessibilityLabel("32-bit Windows display")
                .accessibilityHint("Tap the Windows display to click. Use the keyboard button to type.")
        } else {
            MadeiraMetalView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .onAppear {
                    JoystickPadState.shared.hidden = false
                    TouchControlsHost.attach()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                    TouchControlsHost.attach()
                }
                .onDisappear { TouchControlsHost.hide() }
                .accessibilityLabel("Windows display")
                .accessibilityHint("Use touch as a trackpad. Tap to click, two-finger tap to right-click.")
        }
    }
    private func interpreterKey(_ label: String, scancode: Int32) -> some View {
        Button(label) {
            madeira_wine32_key(scancode, 1)
            madeira_wine32_key(scancode, 0)
        }.frame(minWidth: 44, minHeight: 44)
    }
    private var libraryButton: some View {
        Button { session.presented = false } label: {
            Label("Library", systemImage: "chevron.left").font(.subheadline.weight(.semibold)).frame(minHeight: 44)
        }
    }
    private var keyboardButton: some View {
        Button {
            if session.runtime == .wine32 { madeira_wine32_show_keyboard() }
            else { MetalBackedView.toggleKeyboard() }
        } label: {
            Image(systemName: "keyboard").font(.title3).frame(minWidth: 44, minHeight: 44)
        }.accessibilityLabel("Show or hide keyboard")
    }
    @ViewBuilder private var pointerButton: some View {
        if session.runtime == .native64 {
            Button { input.relative.toggle() } label: {
                Image(systemName: input.relative ? "scope" : "cursorarrow.motionlines")
                    .font(.title3).frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(input.relative ? "Switch to trackpad pointer" : "Switch to mouse look")
        }
    }
    @ViewBuilder private var closeWindowButton: some View {
        if session.runtime == .wine32 {
            Button { confirmStop = true } label: {
                Image(systemName: "stop.circle").font(.title3).frame(minWidth: 44, minHeight: 44)
            }.accessibilityLabel("End Windows session")
        } else {
            Button {
                let source = UUID()
                GuestInput.shared.state.set(.key(0x12), down: true, source: source)
                GuestInput.shared.state.set(.key(0x73), down: true, source: source)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { GuestInput.shared.state.release(source: source) }
            } label: {
                Image(systemName: "xmark.rectangle").font(.title3).frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Close the current Windows window")
        }
    }

    private var sessionMessage: some View {
        VStack(spacing: 0) {
            HStack { libraryButton; Spacer() }.padding(20)
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: session.phase == .needsJIT || session.phase == .enablingJIT ? "bolt.circle" : "desktopcomputer")
                        .font(.system(size: 64, weight: .ultraLight)).foregroundStyle(MadeiraStyle.accent)
                    Text(session.title).font(.title.bold()).multilineTextAlignment(.center)
                    Text(session.status).font(.headline).foregroundStyle(MadeiraStyle.secondary)
                    switch session.phase {
                    case .preparing, .starting:
                        ProgressView().controlSize(.large)
                        Text("Preparing your Windows environment. Your files will stay in Madeira.")
                    case .needsJIT, .enablingJIT:
                        Text("Madeira uses JIT to run Windows apps. Enable it with StikDebug, then return here to continue.")
                        if session.phase == .enablingJIT { ProgressView() }
                        else {
                            Button("Enable JIT & continue") { session.enableJIT() }
                                .buttonStyle(.borderedProminent).foregroundStyle(MadeiraStyle.background)
                        }
                        Button("Cancel launch") { session.cancelPreparation() }.frame(minHeight: 44)
                    case .failed(let message): Text(message)
                    case .finished:
                        Text(session.runtime == .wine32
                            ? "Return to the library to start another game. Use Find installed apps to add programs you installed in Windows."
                            : "Your files and installed apps are saved. To add an installed app, return to the library and select Find installed apps. Close and reopen Madeira before starting another Windows session.")
                    case .idle: Text("Choose a game or installer from your library to get started.")
                    case .running: EmptyView()
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460).padding(28).frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
        }
    }
}

@MainActor
struct JITControlView: View {
    @ObservedObject var session: EmulatorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Button { session.enableJITFromLibrary() } label: {
                    Label("Enable JIT", systemImage: "bolt.fill")
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 36)
                }
                .buttonStyle(.bordered)
                .disabled(!session.canEnableJIT)
                .accessibilityHint("Opens StikDebug and runs Madeira's JIT script.")
                if session.jitAction == .waiting {
                    ProgressView()
                } else if session.jitAction == .enabled {
                    Label("Enabled", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(MadeiraStyle.accent)
                }
                Spacer(minLength: 0)
            }
            if case .failed(let message) = session.jitAction {
                Text(message).font(.caption).foregroundStyle(.orange)
            } else {
                Text(session.jitAction == .waiting
                    ? "Complete the request in StikDebug, then return to Madeira."
                    : "Opens StikDebug with Madeira's JIT script.")
                    .font(.caption).foregroundStyle(MadeiraStyle.secondary)
            }
        }
        .onAppear { session.refreshJITStatus() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            session.refreshJITStatus()
        }
    }
}

@MainActor
struct MadeiraSettingsView: View {
    @ObservedObject var session: EmulatorSession
    @ObservedObject private var input = InputSettings.shared
    @ObservedObject private var controllers = PhysicalControllerBridge.shared
    @ObservedObject private var mice = PhysicalMouseBridge.shared
    @AppStorage("session.showFPS") private var showFPS = false
    @AppStorage("wine32.resolution") private var wine32Resolution = Wine32Resolution.hd.rawValue

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "desktopcomputer").font(.largeTitle).foregroundStyle(MadeiraStyle.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your Windows space").font(.headline)
                        Text("Open the desktop to manage installed apps and files.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
                Button(session.canLaunch ? "Open Windows desktop" : "View current session") {
                    if session.canLaunch { session.launch(nil) } else { session.presented = true }
                }.frame(minHeight: 44)
                .disabled(session.jitAction == .waiting)
            }
            Section("JIT") {
                JITControlView(session: session)
            }
            Section("Display") {
                Toggle("Show frame rate", isOn: $showFPS)
                Picker("32-bit desktop resolution", selection: $wine32Resolution) {
                    ForEach(Wine32Resolution.allCases) { resolution in
                        Text(resolution.label).tag(resolution.rawValue)
                    }
                }
                Text("Applies to the next 32-bit session. Higher resolutions use more graphics processing. Games can select their own resolution.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Mouse look", isOn: $input.relative)
                LabeledContent("Trackpad sensitivity", value: String(format: "%.1f×", input.sensAbs))
                Slider(value: $input.sensAbs, in: 0.1...8).accessibilityLabel("Trackpad sensitivity")
                LabeledContent("Mouse look sensitivity", value: String(format: "%.1f×", input.sensRel))
                Slider(value: $input.sensRel, in: 0.1...8).accessibilityLabel("Mouse look sensitivity")
            } header: { Text("Touch input") } footer: {
                Text("Tap to click. Tap with two fingers to right-click, or move two fingers to scroll. Mouse look is useful for first-person games.")
            }
            Section {
                Toggle("Use physical controller", isOn: $input.controllerEnabled)
                LabeledContent("Connected controllers", value: "\(controllers.connectedCount)")
                LabeledContent("Look speed", value: "\(Int(input.controllerSpeed))")
                Slider(value: $input.controllerSpeed, in: 200...1600, step: 100).accessibilityLabel("Controller look speed")
                Picker("Stick dead zone", selection: $input.controllerDeadZone) {
                    Text("8%").tag(0.08); Text("12%").tag(0.12); Text("18%").tag(0.18); Text("24%").tag(0.24)
                }
            } header: { Text("Controller") } footer: {
                Text("Controller input maps to keyboard and mouse. Left stick: WASD. Right stick: mouse. A: Space. B: Ctrl. X: E. Y: R. Triggers: mouse buttons. Native XInput is not available.")
            }
            Section("Mouse") {
                Toggle("Use physical mouse", isOn: $input.mouseEnabled)
                LabeledContent("Connected mice", value: "\(mice.connectedCount)")
                Slider(value: $input.mouseSensitivity, in: 0.1...4).accessibilityLabel("Physical mouse sensitivity")
            }
            Section("Help") {
                NavigationLink("Getting started") { MadeiraHelpView() }
                NavigationLink("Diagnostics") { MadeiraDiagnosticsView() }
            }
            Section {
                LabeledContent("Madeira", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                Text("Windows apps on iOS, powered by Wine, FEX and DXMT.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .scrollContentBackground(.hidden)
        .background(MadeiraStyle.background)
    }
}

struct MadeiraHelpView: View {
    var body: some View {
        List {
            Section("Bring a game") {
                Text("Use Add to library → Import game folder to copy an extracted Windows game, including its DLLs and data. If the folder has several executables, choose the game's main .exe in Details.")
            }
            Section("Install an app") {
                Text("Use Open an installer to import an .exe or .msi, then tap Run installer. Complete the Windows setup wizard using the trackpad and keyboard controls.")
                Text("After setup, close the installer. In a 32-bit session, use the stop button to end Windows before launching another app. Return to the library and use Find installed apps to add the installed executable. If the installer needs extra files, import its entire folder and choose its setup executable.")
            }
            Section("Before you play") {
                Text("Set up StikDebug on your device. Madeira will ask to enable JIT when a session needs it. The signed app also needs the memory and virtual-address entitlements expected by this emulator.")
                Text("32-bit EXEs run through an interpreter with translated guest memory and software graphics. They do not require JIT. Speed and game compatibility vary. For MSI packages, select the required 32-bit or 64-bit runtime in Details.")
            }
            Section("Sessions and files") {
                Text("The Library button returns to your collection while Windows continues running. Use the session banner to resume. Close Windows apps using their own exit controls or the Close window button.")
                Text("32-bit sessions can be ended and restarted from the library. After a 64-bit session ends, close and reopen Madeira before starting another session.")
                Text("Removing a library item only removes its shortcut. Game files and saves stay in Madeira's Windows drive and are accessible through the Files app.")
            }
        }
        .navigationTitle("Getting started").navigationBarTitleDisplayMode(.inline)
    }
}

struct MadeiraDiagnosticsView: View {
    @ObservedObject private var logs = LogStore.shared
    @ObservedObject private var input = InputSettings.shared
    var body: some View {
        List {
            Section {
                Toggle("Detailed runtime diagnostics", isOn: $input.diagnostics)
                ShareLink(item: LibraryFiles.documents.appendingPathComponent("madeira-log.txt")) {
                    Label("Share runtime log", systemImage: "square.and.arrow.up")
                }
            } footer: { Text("Detailed logging can affect performance. Enable it when investigating a problem.") }
            Section("Recent activity") {
                ForEach(logs.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(entry.level.rawValue).foregroundStyle(entry.level == .error ? .orange : MadeiraStyle.accent)
                            Spacer()
                            Text(entry.lastTimestamp, style: .time).foregroundStyle(.secondary)
                            if entry.count > 1 { Text("×\(entry.count)").foregroundStyle(.secondary) }
                        }.font(.caption2.monospaced())
                        Text(entry.lastRaw).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics").navigationBarTitleDisplayMode(.inline)
    }
}
