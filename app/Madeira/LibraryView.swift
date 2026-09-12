import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import UIKit

// A quiet, warm charcoal shell lets the library artwork carry the color.
enum MadeiraStyle {
    static let background = Color(red: 0.045, green: 0.060, blue: 0.057)
    static let surface = Color(red: 0.085, green: 0.105, blue: 0.095)
    static let accent = Color(red: 0.81, green: 0.91, blue: 0.62)
    static let secondary = Color(red: 0.61, green: 0.66, blue: 0.62)
}

private enum LibrarySheet: Identifiable {
    case add, details(UUID), installed
    var id: String {
        switch self {
        case .add: return "add"
        case .details(let id): return id.uuidString
        case .installed: return "installed"
        }
    }
}

@MainActor
struct ContentView: View {
    @StateObject private var library = LibraryStore()
    @StateObject private var session = EmulatorSession()
    @State private var selectedTab = 0
    @State private var query = ""
    @State private var filter = "All"
    @State private var sheet: LibrarySheet?
    @State private var picker = false
    @State private var pendingPicker = false
    @State private var pendingLaunch: LibraryItem?
    @State private var importKind: LibraryItem.Kind = .game
    @State private var importTypes: [UTType] = [.folder]
    @State private var notice: String?
    @AppStorage("library.listLayout") private var listLayout = false
    @AppStorage("library.sort") private var sort = "Recently added"
    @Environment(\.dynamicTypeSize) private var typeSize

    private var filtered: [LibraryItem] {
        library.items.filter { item in
            (query.isEmpty || item.name.localizedCaseInsensitiveContains(query)) &&
            (filter != "Games" || item.kind == .game) &&
            (filter != "Installers" || item.kind == .installer) &&
            (filter != "Favorites" || item.favorite)
        }.sorted {
            switch sort {
            case "Name": return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            case "Last played": return ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast)
            default: return $0.addedAt > $1.addedAt
            }
        }
    }
    private var recent: LibraryItem? {
        library.items.filter { $0.lastPlayedAt != nil && $0.kind == .game }
            .max { ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast) }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        masthead
                        if session.phase != .idle { sessionBanner }
                        if library.items.isEmpty { welcome }
                        else {
                            if let recent, query.isEmpty, filter == "All" { recentCard(recent) }
                            collection
                        }
                    }
                    .frame(maxWidth: 1100)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity)
                }
                .background(MadeiraStyle.background)
                .toolbar(.hidden, for: .navigationBar)
            }
            .tabItem { Label("Library", systemImage: "square.grid.2x2.fill") }
            .tag(0)
            NavigationStack {
                MadeiraSettingsView(session: session)
            }
            .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
            .tag(1)
        }
        .tint(MadeiraStyle.accent)
        .preferredColorScheme(.dark)
        .sheet(item: $sheet, onDismiss: {
            if pendingPicker { pendingPicker = false; picker = true }
            if let item = pendingLaunch { pendingLaunch = nil; launch(item) }
        }) { destination in
            switch destination {
            case .add:
                AddToLibraryView { action in
                    switch action {
                    case .installed: sheet = .installed
                    case .folder: chooseFiles(kind: .game, types: [.folder])
                    case .installer: chooseFiles(kind: .installer, types: windowsTypes)
                    case .executable: chooseFiles(kind: .game, types: [UTType(filenameExtension: "exe") ?? .data])
                    }
                }
            case .details(let id):
                LibraryDetailView(library: library, itemID: id) { item in
                    pendingLaunch = item
                    sheet = nil
                }
            case .installed:
                InstalledAppsView(library: library) { id in sheet = .details(id) }
            }
        }
        .fileImporter(isPresented: $picker, allowedContentTypes: importTypes) { result in
            switch result {
            case .success(let url): importURL(url, kind: importKind)
            case .failure(let error):
                let cocoa = error as NSError
                if cocoa.domain != NSCocoaErrorDomain || cocoa.code != NSUserCancelledError {
                    library.error = error.localizedDescription
                }
            }
        }
        .fullScreenCover(isPresented: $session.presented) {
            EmulatorSessionView(session: session)
        }
        .onOpenURL { url in
            guard url.isFileURL, ["exe", "msi"].contains(url.pathExtension.lowercased()) else { return }
            guard !library.isBusy else { notice = "Finish the current import, then open this file again."; return }
            importURL(url, kind: .installer)
        }
        .onChange(of: session.phase) { _, phase in
            if phase == .running, let id = session.libraryID,
               var item = library.items.first(where: { $0.id == id }) {
                item.lastPlayedAt = Date()
                library.update(item)
            }
        }
        .overlay {
            if let operation = library.operation {
                ZStack {
                    Color.black.opacity(0.65).ignoresSafeArea()
                    VStack(spacing: 18) {
                        ProgressView().tint(MadeiraStyle.accent).controlSize(.large)
                        Text(operation).font(.headline).multilineTextAlignment(.center)
                        Text("Keep Madeira open while your files are copied.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(32).frame(maxWidth: 340)
                    .background(MadeiraStyle.surface, in: RoundedRectangle(cornerRadius: 28))
                }
                .accessibilityAddTraits(.isModal)
            }
        }
        .alert("Madeira", isPresented: Binding(get: { library.error != nil || notice != nil }, set: {
            if !$0 { library.error = nil; notice = nil }
        })) {
            Button("OK", role: .cancel) { library.error = nil; notice = nil }
        } message: { Text(library.error ?? notice ?? "") }
    }

    private var windowsTypes: [UTType] {
        [UTType(filenameExtension: "exe") ?? .data, UTType(filenameExtension: "msi") ?? .data]
    }
    private func chooseFiles(kind: LibraryItem.Kind, types: [UTType]) {
        importKind = kind
        importTypes = types
        if sheet != nil { pendingPicker = true; sheet = nil }
        else { picker = true }
    }
    private func importURL(_ url: URL, kind: LibraryItem.Kind) {
        guard session.phase != .preparing && session.phase != .starting else {
            notice = "Wait for Windows to finish starting, then import this file again."
            return
        }
        session.presented = false
        selectedTab = 0
        Task {
            if let id = await library.importURL(url, kind: kind) { sheet = .details(id) }
        }
    }
    private func launch(_ item: LibraryItem) {
        if session.canLaunch { session.launch(item) }
        else {
            notice = session.isActive
                ? "A Windows session is already open. Resume it from the library before starting another app."
                : "Close and reopen Madeira to start another session. Your library and installed files are saved."
        }
    }

    private var masthead: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MADEIRA").font(.caption.weight(.bold)).tracking(4).foregroundStyle(MadeiraStyle.accent)
                Text("Library").font(.largeTitle.weight(.bold))
            }
            Spacer()
            Button { sheet = .add } label: {
                Image(systemName: "plus").font(.title3.weight(.semibold))
                    .foregroundStyle(MadeiraStyle.background)
                    .frame(width: 48, height: 48)
                    .background(MadeiraStyle.accent, in: Circle())
            }
            .accessibilityLabel("Add to library")
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                Spacer(minLength: 72)
                Text("ROOM FOR YOUR NEXT FAVORITE")
                    .font(.caption2.weight(.bold)).tracking(2).foregroundStyle(MadeiraStyle.accent)
                Text("Your PC games.\nA new home.")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
            }
            .padding(28)
            .frame(maxWidth: .infinity, minHeight: 260, alignment: .bottomLeading)
            .background { LibraryArtwork(item: nil) }
            .clipShape(RoundedRectangle(cornerRadius: 28))
            VStack(alignment: .leading, spacing: 10) {
                Text("Build your collection").font(.title2.bold())
                Text("Bring over a game folder, or run a Windows installer. Your games will be right here when you're ready to play.")
                    .font(.body).foregroundStyle(MadeiraStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 12) {
                Button { chooseFiles(kind: .game, types: [.folder]) } label: {
                    Label("Import game folder", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent).foregroundStyle(MadeiraStyle.background)
                Button { chooseFiles(kind: .installer, types: windowsTypes) } label: {
                    Label("Open Windows installer", systemImage: "shippingbox")
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
            }
            Button { sheet = .installed } label: {
                Label("Already installed something? Find it on your Windows drive", systemImage: "internaldrive")
                    .font(.footnote).foregroundStyle(MadeiraStyle.secondary)
                    .multilineTextAlignment(.leading).padding(.vertical, 8)
            }
        }
    }

    private var sessionBanner: some View {
        Button { session.presented = true } label: {
            HStack(spacing: 14) {
                Image(systemName: session.isActive ? "play.circle.fill" : "desktopcomputer")
                    .font(.title2).foregroundStyle(MadeiraStyle.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title).font(.subheadline.bold())
                    Text(session.status).font(.caption).foregroundStyle(MadeiraStyle.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right").foregroundStyle(MadeiraStyle.accent)
            }
            .padding(18).background(MadeiraStyle.surface, in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }

    private func recentCard(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("JUMP BACK IN").font(.caption2.bold()).tracking(2).foregroundStyle(MadeiraStyle.secondary)
            Button { sheet = .details(item.id) } label: {
                HStack(spacing: 18) {
                    LibraryArtwork(item: item).frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.name).font(.title3.bold()).lineLimit(2)
                        if let date = item.lastPlayedAt {
                            Text("Played \(date, style: .relative) ago")
                                .font(.caption).foregroundStyle(MadeiraStyle.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "play.fill").foregroundStyle(MadeiraStyle.accent).padding(10)
                }
                .padding(16).background(MadeiraStyle.surface, in: RoundedRectangle(cornerRadius: 24))
            }
            .buttonStyle(.plain)
        }
    }

    private var collection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(MadeiraStyle.secondary)
                TextField("Search your library", text: $query).autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Clear search").frame(minWidth: 44, minHeight: 44)
                }
            }
            .padding(.horizontal, 16).frame(minHeight: 50)
            .background(MadeiraStyle.surface, in: RoundedRectangle(cornerRadius: 16))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["All", "Games", "Installers", "Favorites"], id: \.self) { value in
                        Button { filter = value } label: {
                            Text(value).font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 18).frame(minHeight: 44)
                                .background(filter == value ? MadeiraStyle.accent : MadeiraStyle.surface, in: Capsule())
                                .foregroundStyle(filter == value ? MadeiraStyle.background : .white)
                        }
                        .accessibilityAddTraits(filter == value ? [.isSelected] : [])
                    }
                }
            }
            HStack {
                Text("\(filtered.count) \(filtered.count == 1 ? "item" : "items")")
                    .font(.subheadline).foregroundStyle(MadeiraStyle.secondary)
                Spacer()
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(["Recently added", "Last played", "Name"], id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("List view", isOn: $listLayout)
                } label: {
                    Label("Sort & view", systemImage: "arrow.up.arrow.down").font(.subheadline)
                        .frame(minHeight: 44)
                }
            }
            if filtered.isEmpty {
                ContentUnavailableView(query.isEmpty ? "Nothing here yet" : "No matches", systemImage: "square.grid.2x2",
                    description: Text(query.isEmpty ? "Add an item or try another collection." : "Try a different game name."))
            } else if listLayout || typeSize.isAccessibilitySize {
                LazyVStack(spacing: 12) {
                    ForEach(filtered) { item in
                        Button { sheet = .details(item.id) } label: { libraryRow(item) }
                            .buttonStyle(.plain).contextMenu { itemMenu(item) }
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 230), spacing: 18)], alignment: .leading, spacing: 26) {
                    ForEach(filtered) { item in
                        Button { sheet = .details(item.id) } label: { libraryCard(item) }
                            .buttonStyle(.plain).contextMenu { itemMenu(item) }
                    }
                }
            }
        }
    }

    private func libraryCard(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LibraryArtwork(item: item)
                .aspectRatio(0.82, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .overlay(alignment: .topTrailing) {
                    if item.favorite {
                        Image(systemName: "heart.fill").font(.caption).padding(9)
                            .background(.black.opacity(0.5), in: Circle()).padding(10)
                    }
                }
            Text(item.name).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
            Label(item.needsExecutable ? "Set up" : item.kind == .installer ? "Installer" : "Windows",
                  systemImage: item.needsExecutable ? "wrench" : item.kind == .installer ? "shippingbox" : "desktopcomputer")
                .font(.caption).foregroundStyle(MadeiraStyle.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func libraryRow(_ item: LibraryItem) -> some View {
        HStack(spacing: 16) {
            LibraryArtwork(item: item).frame(width: 72, height: 80).clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.name).font(.headline).multilineTextAlignment(.leading)
                Text(item.subtitle).font(.caption).foregroundStyle(MadeiraStyle.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(MadeiraStyle.secondary)
        }
        .padding(12).background(MadeiraStyle.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder private func itemMenu(_ item: LibraryItem) -> some View {
        Button { sheet = .details(item.id) } label: { Label("Details", systemImage: "info.circle") }
        Button {
            var updated = item; updated.favorite.toggle(); library.update(updated)
        } label: { Label(item.favorite ? "Remove favorite" : "Favorite", systemImage: "heart") }
    }
}

/// Local artwork is optional. A typographic cover gives every real import a finished tile.
struct LibraryArtwork: View {
    let item: LibraryItem?
    @State private var artwork: UIImage?
    private var tone: Color {
        let colors: [Color] = [Color(red: 0.29, green: 0.40, blue: 0.32), Color(red: 0.42, green: 0.29, blue: 0.23),
            Color(red: 0.23, green: 0.33, blue: 0.41), Color(red: 0.40, green: 0.36, blue: 0.20)]
        let hash = (item?.id.uuidString ?? "").utf8.reduce(0) { ($0 + Int($1)) % colors.count }
        return colors[hash]
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let artwork {
                    Image(uiImage: artwork).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    LinearGradient(colors: [tone, MadeiraStyle.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Canvas { context, size in
                        for index in 0..<7 {
                            let x = size.width * 0.38 + CGFloat(index) * 24
                            let rect = CGRect(x: x, y: -size.height * 0.1, width: size.width * 0.8, height: size.height * 1.4)
                            context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.08)), lineWidth: 1)
                        }
                    }
                    if let item {
                        VStack(alignment: .leading) {
                            HStack {
                                Text(item.kind == .installer ? "SETUP" : "PC").font(.caption2.bold()).tracking(3)
                                Spacer()
                                Image(systemName: item.kind == .installer ? "shippingbox" : "gamecontroller")
                            }
                            .foregroundStyle(.white.opacity(0.65))
                            Spacer()
                            Text(String(item.name.prefix(1)).uppercased())
                                .font(.system(size: min(geometry.size.width * 0.48, 100), weight: .light, design: .serif))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .padding(18)
                    }
                }
            }
        }
        .accessibilityHidden(true)
        .task(id: item?.directory) {
            artwork = nil
            guard let item else { return }
            let thumbnail = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let directory = try? LibraryFiles.directoryURL(item.directory) else { return nil }
                for name in ["cover.jpg", "cover.png", "folder.jpg", "folder.png"] {
                    let file = directory.appendingPathComponent(name)
                    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { continue }
                    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 640, kCGImageSourceCreateThumbnailWithTransform: true]
                    if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return image }
                }
                return nil
            }.value
            if !Task.isCancelled, let thumbnail { artwork = UIImage(cgImage: thumbnail) }
        }
    }
}
