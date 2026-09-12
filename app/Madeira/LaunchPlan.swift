import Foundation

struct LaunchPlan: Sendable {
    let title: String
    let executable: String
    let arguments: [String]
    let workingDirectory: String?
    let desktop: Bool
    let libraryID: UUID?
    var steamAppID: String? = nil

    static func make(item: LibraryItem, drive: URL = LibraryFiles.drive) throws -> LaunchPlan {
        guard let path = item.executable else {
            throw LibraryError.message("Choose this game's executable before launching it.")
        }
        try LibraryFiles.validateExecutable(path, drive: drive)
        let windowsPath = try LibraryFiles.windowsPath(path, drive: drive)
        let directory = windowsPath.split(separator: "\\").dropLast().joined(separator: "\\") + "\\"
        if item.kind == .installer || path.lowercased().hasSuffix(".msi") {
            let command = path.lowercased().hasSuffix(".msi")
                ? ["C:\\windows\\system32\\msiexec.exe", "/i", windowsPath]
                : [windowsPath]
            return LaunchPlan(title: item.name, executable: "explorer.exe",
                arguments: ["/desktop=Madeira,1024x768"] + command + item.arguments,
                workingDirectory: directory, desktop: true, libraryID: item.id)
        }
        let appIDFile = try LibraryFiles.url(for: path, drive: drive).deletingLastPathComponent().appendingPathComponent("steam_appid.txt")
        let text = (try? String(contentsOf: appIDFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let appID = text.flatMap { value -> String? in
            !value.isEmpty && value.count <= 20 && value.utf8.allSatisfy { (48...57).contains($0) } ? value : nil
        }
        return LaunchPlan(title: item.name, executable: windowsPath, arguments: item.arguments,
            workingDirectory: directory, desktop: false, libraryID: item.id, steamAppID: appID)
    }

    func validate() throws {
        guard arguments.count <= 64, arguments.allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }) else {
            throw LibraryError.message("Use at most 64 launch arguments, each no longer than 4 KB.")
        }
    }

    static let windowsDesktop = LaunchPlan(title: "Windows desktop", executable: "explorer.exe",
        arguments: ["/desktop=Madeira,1024x768", "C:\\windows\\system32\\services.exe"],
        workingDirectory: nil, desktop: true, libraryID: nil)
}

