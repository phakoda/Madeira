import Foundation

enum Wine32Resolution: String, CaseIterable, Identifiable {
    case hd = "1280x720"
    case fullHD = "1920x1080"
    case standard = "1024x768"
    case legacy = "800x600"
    var id: String { rawValue }
    var label: String { rawValue.replacingOccurrences(of: "x", with: " × ") }
}

struct LaunchPlan: Sendable {
    let title: String
    let executable: String
    let arguments: [String]
    let workingDirectory: String?
    let desktop: Bool
    let libraryID: UUID?
    var steamAppID: String? = nil
    var runtime: WindowsRuntime = .native64
    /// Linux guest path used by the interpreter's Wine process.
    var guestWorkingDirectory: String? = nil

    static func make(item: LibraryItem, drive: URL? = nil) throws -> LaunchPlan {
        let drive = drive ?? LibraryFiles.drive(for: item.resolvedVolume)
        guard let path = item.executable else {
            throw LibraryError.message("Choose this game's executable before launching it.")
        }
        try LibraryFiles.validateExecutable(path, drive: drive)
        let machine = try LibraryFiles.executableMachine(path, drive: drive)
        let runtime: WindowsRuntime = machine.map { $0 == 0x014c ? .wine32 : .native64 }
            ?? item.installerRuntime ?? .native64
        guard item.resolvedVolume != .wine32 || runtime == .wine32 else {
            throw LibraryError.message("This is a 64-bit executable inside the 32-bit Windows installation. Install the 64-bit version in the 64-bit runtime, or choose this app's 32-bit executable.")
        }
        var windowsPath = try LibraryFiles.windowsPath(path, drive: drive)
        if runtime == .wine32 && item.resolvedVolume == .native64 {
            windowsPath = "D:" + windowsPath.dropFirst(2)
        }
        let directory = windowsPath.split(separator: "\\").dropLast().joined(separator: "\\") + "\\"
        let guestDirectory = (item.resolvedVolume == .wine32 ? "/home/username/.wine/drive_c/" : "/mnt/drive_d/")
            + (path as NSString).deletingLastPathComponent
        if item.kind == .installer || path.lowercased().hasSuffix(".msi") {
            let command = path.lowercased().hasSuffix(".msi")
                ? ["C:\\windows\\system32\\msiexec.exe", "/i", windowsPath]
                : [windowsPath]
            return LaunchPlan(title: item.name, executable: "explorer.exe",
                arguments: ["/desktop=Madeira,1024x768"] + command + item.arguments,
                workingDirectory: directory, desktop: true, libraryID: item.id,
                runtime: runtime, guestWorkingDirectory: guestDirectory)
        }
        let appIDFile = try LibraryFiles.url(for: path, drive: drive).deletingLastPathComponent().appendingPathComponent("steam_appid.txt")
        let text = (try? String(contentsOf: appIDFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let appID = text.flatMap { value -> String? in
            !value.isEmpty && value.count <= 20 && value.utf8.allSatisfy { (48...57).contains($0) } ? value : nil
        }
        return LaunchPlan(title: item.name, executable: windowsPath, arguments: item.arguments,
            workingDirectory: directory, desktop: false, libraryID: item.id, steamAppID: appID,
            runtime: runtime, guestWorkingDirectory: guestDirectory)
    }

    func validate() throws {
        guard arguments.count <= 64, arguments.allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }) else {
            throw LibraryError.message("Use at most 64 launch arguments, each no longer than 4 KB.")
        }
    }

    func wine32Arguments(rootfs: URL, graphics: URL, root: URL, sharedDrive: URL,
                         resolution: Wine32Resolution = .hd) -> [String] {
        // Overlay first: its GL bridge matches the embedded interpreter ABI.
        var result = ["madeira-wine32", "-root", root.path, "-zip", graphics.path, "-zip", rootfs.path,
            "-mount_drive", sharedDrive.path, "d", "-opengl", "osmesa",
            "-resolution", resolution.rawValue, "-scale_quality", "1",
            "-env", "WINEDEBUG=-all,err+all"]
        if let directory = guestWorkingDirectory { result += ["-w", directory] }
        if let steamAppID { result += ["-env", "SteamAppId=" + steamAppID, "-env", "SteamGameId=" + steamAppID] }
        var guestArguments = arguments
        if desktop, guestArguments.first == "/desktop=Madeira,1024x768" {
            guestArguments[0] = "/desktop=Madeira," + resolution.rawValue
        }
        return result + ["/bin/wine", executable] + guestArguments
    }

    static let windowsDesktop = LaunchPlan(title: "Windows desktop", executable: "explorer.exe",
        arguments: ["/desktop=Madeira,1024x768", "C:\\windows\\system32\\services.exe"],
        workingDirectory: nil, desktop: true, libraryID: nil)
}
