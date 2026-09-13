import SwiftUI

struct AddToLibraryView: View {
    enum Action { case installer, folder, executable, installed }
    let choose: (Action) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Make yourself at home.")
                        .font(.system(.title, design: .rounded, weight: .bold))
                    Text("Choose how you'd like to bring an app into Madeira.")
                        .foregroundStyle(MadeiraStyle.secondary)
                    VStack(spacing: 12) {
                        option("Import game folder", detail: "Copy an extracted game with all its files.", icon: "folder.badge.plus", action: .folder)
                        option("Open an installer", detail: "Run an .exe or .msi setup inside Windows.", icon: "shippingbox", action: .installer)
                        option("Add an executable", detail: "For apps that run from a single .exe file.", icon: "doc.badge.plus", action: .executable)
                    }
                    Button { choose(.installed) } label: {
                        Label("Find installed apps", systemImage: "internaldrive")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
                    }
                    Text("Import games with their DLLs and data as a folder. Madeira selects the runtime from each executable's architecture. Compatibility depends on the game and the Windows components it uses.")
                        .font(.footnote).foregroundStyle(MadeiraStyle.secondary)
                }
                .padding(24)
            }
            .background(MadeiraStyle.background)
            .navigationTitle("Add to library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDragIndicator(.visible)
    }
    private func option(_ title: String, detail: String, icon: String, action: Action) -> some View {
        Button { choose(action) } label: {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.title2).foregroundStyle(MadeiraStyle.accent).frame(width: 32)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline).foregroundStyle(.white)
                    Text(detail).font(.subheadline).foregroundStyle(MadeiraStyle.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(MadeiraStyle.secondary)
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(MadeiraStyle.surface, in: RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
    }
}

@MainActor
struct LibraryDetailView: View {
    @ObservedObject var library: LibraryStore
    let itemID: UUID
    let launch: (LibraryItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var arguments = ""
    @State private var chooseExecutable = false
    @State private var confirmRemoval = false
    @State private var showSaved = false
    @State private var architecture = "Checking architecture…"

    private var item: LibraryItem? { library.items.first { $0.id == itemID } }
    var body: some View {
        NavigationStack {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        HStack(alignment: .bottom, spacing: 22) {
                            LibraryArtwork(item: item).frame(width: 112, height: 142)
                                .clipShape(RoundedRectangle(cornerRadius: 20))
                            VStack(alignment: .leading, spacing: 12) {
                                Text(item.kind == .installer ? "INSTALLER" : "WINDOWS")
                                    .font(.caption2.bold()).tracking(2).foregroundStyle(MadeiraStyle.accent)
                                Text(item.name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                                Button {
                                    var updated = item; updated.favorite.toggle(); library.update(updated)
                                } label: {
                                    Label(item.favorite ? "Favorited" : "Favorite", systemImage: item.favorite ? "heart.fill" : "heart")
                                        .font(.subheadline).frame(minHeight: 44)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        Button {
                            if item.needsExecutable { chooseExecutable = true }
                            else if let saved = saveEdits() { launch(saved) }
                        } label: {
                            Label(item.needsExecutable ? "Choose executable" : item.kind == .installer ? "Run installer" : "Play",
                                systemImage: item.needsExecutable ? "doc.badge.gearshape" : item.kind == .installer ? "shippingbox" : "play.fill")
                                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent).foregroundStyle(MadeiraStyle.background)
                        if item.kind == .installer {
                            Text("Complete the setup wizard in Windows. For a 32-bit session, close the installer and use the stop button to end the session. Then use Add to library → Find installed apps to choose the installed executable.")
                                .font(.subheadline).foregroundStyle(MadeiraStyle.secondary)
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Library name").font(.headline)
                            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                            Picker("Launch as", selection: Binding(get: { item.kind }, set: { kind in
                                var updated = item; updated.kind = kind; library.update(updated)
                            })) {
                                Text("Game or app").tag(LibraryItem.Kind.game)
                                Text("Windows installer").tag(LibraryItem.Kind.installer)
                            }
                            .disabled(item.executable?.lowercased().hasSuffix(".msi") == true)
                            if item.executable?.lowercased().hasSuffix(".msi") == true {
                                Picker("Installer runtime", selection: Binding(get: { item.installerRuntime ?? .native64 }, set: { runtime in
                                    var updated = item; updated.installerRuntime = runtime; library.update(updated)
                                })) {
                                    Text("32-bit Windows").tag(WindowsRuntime.wine32)
                                    Text("64-bit Windows").tag(WindowsRuntime.native64)
                                }
                                Text("Choose the architecture required by the MSI package. Each runtime has its own installed apps and Windows files.")
                                    .font(.caption).foregroundStyle(MadeiraStyle.secondary)
                            }
                            Divider()
                            Text("Executable").font(.headline)
                            Text(architecture).font(.subheadline.weight(.medium)).foregroundStyle(MadeiraStyle.accent)
                            Text(item.executable?.replacingOccurrences(of: "/", with: " / ") ?? "Choose the main .exe from this game's folder.")
                                .font(.footnote).foregroundStyle(MadeiraStyle.secondary).textSelection(.enabled)
                            if item.executable?.lowercased().hasSuffix(".msi") != true {
                                Button("Change executable") { chooseExecutable = true }.frame(minHeight: 44)
                            }
                        }
                        .padding(20).background(MadeiraStyle.surface, in: RoundedRectangle(cornerRadius: 22))
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Launch arguments").font(.headline)
                            TextField("For example: -dx11", text: $arguments, axis: .vertical)
                                .lineLimit(3...8).font(.system(.body, design: .monospaced))
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                                .padding(12).background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                            Text("One argument per line. Spaces within a line stay together; do not add surrounding quotes.")
                                .font(.caption).foregroundStyle(MadeiraStyle.secondary)
                        }
                        Button(role: .destructive) { confirmRemoval = true } label: {
                            Label("Remove from library", systemImage: "trash").frame(minHeight: 44)
                        }
                    }
                    .padding(24)
                }
                .background(MadeiraStyle.background)
                .navigationTitle("Details").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { if saveEdits() != nil { dismiss() } } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(showSaved ? "Saved" : "Save") { if saveEdits() != nil { showSaved = true } }
                    }
                }
                .onAppear { name = item.name; arguments = item.arguments.joined(separator: "\n") }
                .task(id: item.executable) {
                    guard let path = item.executable else { architecture = "No executable selected"; return }
                    architecture = "Checking architecture…"
                    let result = await Task.detached(priority: .utility) { () -> String in
                        do {
                            let machine = try LibraryFiles.executableMachine(path, drive: LibraryFiles.drive(for: item.resolvedVolume))
                            return machine.map { LibraryFiles.architectureLabel($0) } ?? "MSI package · payload architecture varies"
                        } catch { return error.localizedDescription }
                    }.value
                    if !Task.isCancelled { architecture = result }
                }
                .onChange(of: name) { _, _ in showSaved = false }
                .onChange(of: arguments) { _, _ in showSaved = false }
                .sheet(isPresented: $chooseExecutable) {
                    ExecutablePickerView(directory: item.directory, volume: item.resolvedVolume) { choice in
                        guard var updated = self.item else { return }
                        updated.executable = choice.path
                        updated.volume = choice.volume
                        library.update(updated)
                        chooseExecutable = false
                    }
                }
                .confirmationDialog("Remove \(item.name) from the library?", isPresented: $confirmRemoval, titleVisibility: .visible) {
                    Button("Remove shortcut", role: .destructive) { library.remove(item); dismiss() }
                } message: { Text("The app's files, installation, and saves will stay on your Windows drive.") }
            }
        }
        .presentationDragIndicator(.visible)
        .alert("Could not save", isPresented: Binding(get: { library.error != nil }, set: {
            if !$0 { library.error = nil }
        })) { Button("OK", role: .cancel) { library.error = nil } } message: { Text(library.error ?? "") }
    }

    @discardableResult private func saveEdits() -> LibraryItem? {
        guard var updated = item else { return nil }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { library.error = "Give this library item a name."; return nil }
        updated.name = cleaned
        updated.arguments = arguments.components(separatedBy: .newlines).filter { !$0.isEmpty }
        library.update(updated)
        return library.error == nil ? updated : nil
    }
}

struct ExecutablePickerView: View {
    var directory: String? = nil
    var volume: LibraryVolume = .native64
    let choose: (ExecutableChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [ExecutableChoice] = []
    @State private var loading = true
    @State private var error: String?
    @State private var query = ""

    private var filtered: [ExecutableChoice] {
        choices.filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Looking for Windows apps…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    ContentUnavailableView("Couldn't read the drive", systemImage: "exclamationmark.folder", description: Text(error))
                } else if choices.isEmpty {
                    ContentUnavailableView("No apps found", systemImage: "internaldrive",
                        description: Text("Finish installing an app in Windows, then check again. You can also import a game folder from Files."))
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(filtered) { choice in
                        Button { choose(choice) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(choice.name, systemImage: "app.dashed").font(.headline)
                                Text(choice.architectureLabel).font(.caption.weight(.semibold))
                                    .foregroundStyle(MadeiraStyle.accent)
                                if directory == nil {
                                    Text(choice.volume == .wine32 ? "32-bit Windows installation" : "64-bit Windows installation")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(choice.path).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(3).multilineTextAlignment(.leading)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
            .navigationTitle(directory == nil ? "Installed apps" : "Choose executable")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search executables")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task {
                do {
                    let directory = directory
                    let volume = volume
                    choices = try await Task.detached(priority: .userInitiated) {
                        if let directory {
                            return try LibraryFiles.executables(in: directory, drive: LibraryFiles.drive(for: volume)).map {
                                ExecutableChoice(path: $0.path, machine: $0.machine, volume: volume)
                            }
                        }
                        return try LibraryFiles.installedExecutables()
                    }.value
                } catch { self.error = error.localizedDescription }
                loading = false
            }
        }
    }
}

@MainActor
struct InstalledAppsView: View {
    @ObservedObject var library: LibraryStore
    let added: (UUID) -> Void
    var body: some View {
        ExecutablePickerView { choice in
            if let id = library.addInstalled(choice) { added(id) }
        }
    }
}
