import Foundation
import Combine

enum LibraryVolume: String, Codable, Sendable {
    case native64, wine32
}

enum WindowsRuntime: String, Codable, Sendable {
    case native64, wine32
}

struct LibraryItem: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case game, installer }

    let id: UUID
    var name: String
    var kind: Kind
    /// Paths are relative to the selected drive_c. Missing volume preserves
    /// libraries saved before the separate Wine32 prefix was introduced.
    var volume: LibraryVolume? = nil
    var resolvedVolume: LibraryVolume { volume ?? .native64 }
    /// MSI packages have no PE entry point. The setup's required architecture
    /// is selected in Details; existing entries keep their previous runtime.
    var installerRuntime: WindowsRuntime? = nil
    var executable: String?
    var directory: String
    var addedAt: Date
    var lastPlayedAt: Date?
    var favorite = false
    var arguments: [String] = []

    var needsExecutable: Bool { executable == nil }
    var subtitle: String {
        if needsExecutable { return "Choose an executable" }
        return kind == .installer ? "Windows installer" : "Windows game"
    }
}

struct ExecutableChoice: Identifiable, Sendable {
    let path: String
    var machine: UInt16? = nil
    var volume: LibraryVolume = .native64
    var id: String { volume.rawValue + ":" + path }
    var architectureLabel: String { LibraryFiles.architectureLabel(machine) }
    var name: String { (path as NSString).lastPathComponent }
}

enum LibraryError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

enum LibraryFiles {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var prefix: URL { documents.appendingPathComponent("wine", isDirectory: true) }
    static var drive: URL { Self.prefix.appendingPathComponent("drive_c", isDirectory: true) }
    static var wine32Root: URL { documents.appendingPathComponent("wine32", isDirectory: true) }
    static var wine32Drive: URL {
        wine32Root.appendingPathComponent("home/username/.wine/drive_c", isDirectory: true)
    }
    static func drive(for volume: LibraryVolume) -> URL {
        volume == .wine32 ? wine32Drive : drive
    }
    static var manifest: URL { documents.appendingPathComponent("madeira-library.json") }

    /// Validate persisted paths at the filesystem boundary, including symlink resolution.
    static func url(for path: String, drive: URL = LibraryFiles.drive) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." &&
            $0.rangeOfCharacter(from: CharacterSet(charactersIn: "\\:\"<>|?*").union(.controlCharacters)) == nil
        }) else { throw LibraryError.message("This library entry has an invalid file path.") }

        let root = drive.resolvingSymlinksInPath().standardizedFileURL
        var result = root
        for component in components {
            result = result.appendingPathComponent(String(component))
                .resolvingSymlinksInPath().standardizedFileURL
            guard result.path.hasPrefix(root.path + "/") else {
                throw LibraryError.message("This file is outside the Windows drive.")
            }
        }
        return result
    }

    static func directoryURL(_ path: String, drive: URL = LibraryFiles.drive) throws -> URL {
        if path.isEmpty { return drive.resolvingSymlinksInPath().standardizedFileURL }
        return try url(for: path, drive: drive)
    }

    static func windowsPath(_ path: String, drive: URL = LibraryFiles.drive) throws -> String {
        _ = try url(for: path, drive: drive)
        let value = "C:\\" + path.replacingOccurrences(of: "/", with: "\\")
        guard value.utf8.count < 480 else {
            throw LibraryError.message("This path is too long for the emulator. Move the game into a shorter folder path.")
        }
        return value
    }

    static func executables(in directory: String? = nil, drive: URL = LibraryFiles.drive) throws -> [ExecutableChoice] {
        let fm = FileManager.default
        let canonicalDrive = drive.resolvingSymlinksInPath().standardizedFileURL
        let root = try directory.map { try directoryURL($0, drive: drive) } ?? canonicalDrive
        guard fm.fileExists(atPath: root.path) else { return [] }

        var results: [ExecutableChoice] = []
        var pending = [root]
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]

        while let folder = pending.popLast() {
            let entries = try fm.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
            for file in entries {
                let values = try file.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true { continue }

                let resolved = file.resolvingSymlinksInPath().standardizedFileURL
                guard resolved.path.hasPrefix(canonicalDrive.path + "/") else {
                    throw LibraryError.message("The Windows drive contains a file outside its root.")
                }

                if values.isDirectory == true {
                    if directory == nil,
                       folder.standardizedFileURL == canonicalDrive,
                       ["windows", "madeira"].contains(file.lastPathComponent.lowercased()) {
                        continue
                    }
                    pending.append(resolved)
                    continue
                }

                guard values.isRegularFile == true, file.pathExtension.lowercased() == "exe" else { continue }
                let relative = String(resolved.path.dropFirst(canonicalDrive.path.count + 1))
                _ = try url(for: relative, drive: drive)
                results.append(ExecutableChoice(path: relative, machine: try? executableMachine(relative, drive: drive)))
            }
        }

        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func installedExecutables() throws -> [ExecutableChoice] {
        try [LibraryVolume.native64, .wine32].flatMap { volume in
            try executables(drive: drive(for: volume)).map { choice in
                ExecutableChoice(path: choice.path, machine: choice.machine, volume: volume)
            }
        }
    }

    /// Copies the entire folder, including DLLs and data, while the provider grants access.
    /// A staging directory is published by rename only after the copy has completed.
    static func importFile(_ source: URL, as kind: LibraryItem.Kind, drive: URL = LibraryFiles.drive) throws -> LibraryItem {
        let fm = FileManager.default
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let base = "Madeira/Imports/\(id.uuidString)"
        let destination = try url(for: base, drive: drive)
        let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
        guard !destination.path.hasPrefix(resolvedSource.path + "/") else {
            throw LibraryError.message("Choose a game folder, not Madeira's own Documents or Windows drive folder.")
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(id.uuidString).partial")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var published = false
        defer { if !published { try? fm.removeItem(at: staging) } }
        var coordinationError: NSError?
        var copyResult: Result<(Bool, String), Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            copyResult = Result {
                let values = try readable.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else {
                    throw LibraryError.message("Choose the original file or folder instead of a symbolic link.")
                }
                let isFolder = values.isDirectory == true
                if !isFolder && !["exe", "msi"].contains(readable.pathExtension.lowercased()) {
                    throw LibraryError.message("Choose a Windows .exe, .msi, or a game folder.")
                }
                if isFolder {
                    // Reject links rather than copying references that break outside the provider.
                    var traversalError: Error?
                    guard let files = fm.enumerator(at: readable, includingPropertiesForKeys: [.isSymbolicLinkKey],
                        errorHandler: { _, error in traversalError = error; return false }) else {
                        throw LibraryError.message("The selected folder could not be read.")
                    }
                    for case let file as URL in files {
                        if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                            throw LibraryError.message("This folder contains symbolic links. Import a folder containing the actual game files.")
                        }
                    }
                    if let traversalError { throw traversalError }
                    try fm.copyItem(at: readable, to: staging.appendingPathComponent("Files"))
                } else {
                    try fm.createDirectory(at: staging.appendingPathComponent("Files"), withIntermediateDirectories: true)
                    try fm.copyItem(at: readable, to: staging.appendingPathComponent("Files").appendingPathComponent(readable.lastPathComponent))
                }
                return (isFolder, readable.lastPathComponent)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let copyResult else { throw LibraryError.message("The file provider did not return the selected files.") }
        let (isFolder, filename) = try copyResult.get()
        try fm.moveItem(at: staging, to: destination)
        do {
            let directory = base + "/Files"
            let choices = try executables(in: directory, drive: drive)
            if isFolder && choices.isEmpty {
                throw LibraryError.message("No Windows executable was found in this folder. Choose an extracted game folder containing an .exe.")
            }
            let executable = isFolder ? (choices.count == 1 ? choices[0].path : nil) : directory + "/" + filename
            if let executable { _ = try windowsPath(executable, drive: drive) }
            published = true
            return LibraryItem(id: id,
                name: isFolder ? filename : (filename as NSString).deletingPathExtension,
                kind: isFolder ? .game : (filename.lowercased().hasSuffix(".msi") ? .installer : kind),
                installerRuntime: filename.lowercased().hasSuffix(".msi") ? .wine32 : nil,
                executable: executable, directory: directory, addedAt: Date())
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    static func architectureLabel(_ machine: UInt16?) -> String {
        switch machine {
        case .some(0x014c): return "x86 · 32-bit"
        case .some(0x8664): return "x64 · 64-bit"
        case .some(0xaa64): return "ARM64 · 64-bit"
        case .some(0xa641): return "ARM64EC · 64-bit"
        case .some(0xa64e): return "ARM64X · 64-bit"
        case .some(let value): return String(format: "Unknown architecture · 0x%04X", value)
        case .none: return "Architecture unavailable"
        }
    }

    /// Read the COFF Machine field from the selected file, never infer it from its name.
    static func executableMachine(_ path: String, drive: URL = LibraryFiles.drive) throws -> UInt16? {
        let file = try url(for: path, drive: drive)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw LibraryError.message("The executable is missing. Choose another executable or import the game again.")
        }
        if file.pathExtension.lowercased() == "msi" { return nil }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 64) ?? Data()
        guard header.count == 64, header[0] == 0x4d, header[1] == 0x5a else {
            throw LibraryError.message("This file is not a Windows executable.")
        }
        let offset = (0..<4).reduce(UInt64(0)) { $0 | UInt64(header[60 + $1]) << (8 * $1) }
        try handle.seek(toOffset: offset)
        let pe = try handle.read(upToCount: 6) ?? Data()
        guard pe.count == 6, Array(pe.prefix(4)) == [0x50, 0x45, 0, 0] else {
            throw LibraryError.message("The Windows executable has an unreadable PE header.")
        }
        return UInt16(pe[4]) | (UInt16(pe[5]) << 8)
    }

    static func validateExecutable(_ path: String, drive: URL = LibraryFiles.drive) throws {
        guard let machine = try executableMachine(path, drive: drive) else { return }
        guard [UInt16(0x014c), 0x8664, 0xaa64, 0xa641, 0xa64e].contains(machine) else {
            throw LibraryError.message("\((path as NSString).lastPathComponent) uses \(architectureLabel(machine)), which this build does not support.")
        }
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []
    @Published private(set) var operation: String?
    @Published var error: String?
    private var loadFailed = false
    private let manifestURL: URL
    var isBusy: Bool { operation != nil }

    init(manifestURL: URL = LibraryFiles.manifest) {
        self.manifestURL = manifestURL
        do {
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                let decoded = try JSONDecoder().decode([LibraryItem].self, from: Data(contentsOf: manifestURL))
                guard Set(decoded.map(\.id)).count == decoded.count else {
                    throw LibraryError.message("The saved library contains duplicate entries.")
                }
                items = decoded
            }
        } catch {
            loadFailed = true
            self.error = "The saved library could not be opened. Your game files are still on the Windows drive. \(error.localizedDescription)"
        }
    }

    private func save(_ updated: [LibraryItem]) throws {
        guard !loadFailed else { throw LibraryError.message("Repair or restore madeira-library.json in Files before changing the library. Your existing library will not be overwritten.") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(updated).write(to: manifestURL, options: .atomic)
        items = updated
    }

    func importURL(_ url: URL, kind: LibraryItem.Kind) async -> UUID? {
        guard !isBusy, !loadFailed else { return nil }
        operation = "Copying \(url.lastPathComponent)…"
        defer { operation = nil }
        do {
            let item = try await Task.detached(priority: .userInitiated) {
                try LibraryFiles.importFile(url, as: kind)
            }.value
            do { try save(items + [item]) }
            catch {
                // This UUID directory belongs only to the uncommitted import.
                let directory = try LibraryFiles.url(for: "Madeira/Imports/\(item.id.uuidString)")
                _ = await Task.detached { try? FileManager.default.removeItem(at: directory) }.value
                throw error
            }
            return item.id
        } catch { self.error = error.localizedDescription; return nil }
    }

    func update(_ item: LibraryItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = items
        updated[index] = item
        do { try save(updated) } catch { self.error = error.localizedDescription }
    }

    func remove(_ item: LibraryItem) {
        // Removing a shortcut must never remove the game's files or saves.
        do { try save(items.filter { $0.id != item.id }) } catch { self.error = error.localizedDescription }
    }

    func addInstalled(_ choice: ExecutableChoice) -> UUID? {
        if let existing = items.first(where: { $0.executable == choice.path && $0.resolvedVolume == choice.volume }) { return existing.id }
        do {
            _ = try LibraryFiles.windowsPath(choice.path, drive: LibraryFiles.drive(for: choice.volume))
            let item = LibraryItem(id: UUID(), name: (choice.name as NSString).deletingPathExtension,
                kind: .game, volume: choice.volume, executable: choice.path,
                directory: (choice.path as NSString).deletingLastPathComponent, addedAt: Date())
            try save(items + [item])
            return item.id
        } catch { self.error = error.localizedDescription; return nil }
    }
}
