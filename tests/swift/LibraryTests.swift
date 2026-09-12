// These tests run on the macOS GitHub Actions runner, never as part of importing a game.
import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(description: message) }
}
private func expectFailure(_ message: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw TestFailure(description: message)
}

@main
struct LibraryTests {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("madeira-library-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let drive = temp.appendingPathComponent("drive_c", isDirectory: true)
        try fm.createDirectory(at: drive, withIntermediateDirectories: true)

        func write(_ relative: String, data: Data = Data("data".utf8), root: URL? = nil) throws -> URL {
            let url = (root ?? temp).appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }
        func pe(_ machine: UInt16) -> Data {
            var bytes = [UInt8](repeating: 0, count: 70)
            bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 64
            bytes[64] = 0x50; bytes[65] = 0x45
            bytes[68] = UInt8(machine & 0xff); bytes[69] = UInt8(machine >> 8)
            return Data(bytes)
        }

        _ = try write("My Game/bin/Game.EXE", data: pe(0x8664))
        _ = try write("My Game/bin/Launcher.exe", data: pe(0x14c))
        _ = try write("My Game/data/levels.bin")
        _ = try write("My Game/game.dll")
        let imported = try LibraryFiles.importFile(temp.appendingPathComponent("My Game"), as: .game, drive: drive)
        try expect(imported.executable == nil, "Multiple executables must require a choice")
        try expect(imported.name == "My Game", "Folder name must survive import")
        let copiedData = try LibraryFiles.url(for: imported.directory + "/data/levels.bin", drive: drive)
        try expect(try Data(contentsOf: copiedData) == Data("data".utf8), "Game data was not copied")
        try expect(fm.fileExists(atPath: temp.appendingPathComponent("My Game/game.dll").path), "Import moved original files")
        let choices = try LibraryFiles.executables(in: imported.directory, drive: drive)
        try expect(choices.count == 2, "Nested and uppercase executable discovery failed")
        try expect(choices.first { $0.name == "Game.EXE" }?.machine == 0x8664, "x64 game was misidentified")
        try expect(choices.first { $0.name == "Launcher.exe" }?.machine == 0x014c, "x86 launcher was misidentified")
        // Filenames are not architecture evidence.
        _ = try write("Source/LooksLike32bit.exe", data: pe(0x8664))
        let named32 = try LibraryFiles.importFile(temp.appendingPathComponent("Source/LooksLike32bit.exe"), as: .game, drive: drive)
        try LibraryFiles.validateExecutable(named32.executable!, drive: drive)
        _ = try write("Source/LooksLike64bit.exe", data: pe(0x014c))
        let named64 = try LibraryFiles.importFile(temp.appendingPathComponent("Source/LooksLike64bit.exe"), as: .game, drive: drive)
        try expectFailure("A misleading x64 filename bypassed the x86 restriction") {
            try LibraryFiles.validateExecutable(named64.executable!, drive: drive)
        }

        var game = imported
        game.executable = imported.directory + "/bin/Game.EXE"
        game.arguments = ["-dx11", "a path with spaces", "日本語"]
        _ = try write(imported.directory + "/bin/steam_appid.txt", data: Data("12345\n".utf8), root: drive)
        let plan = try LaunchPlan.make(item: game, drive: drive)
        try plan.validate()
        try expect(plan.arguments == game.arguments, "Argument boundaries changed")
        try expect(plan.steamAppID == "12345", "The selected game's app ID was not read")
        try expect(plan.workingDirectory?.hasSuffix("\\bin\\") == true, "Game working directory is wrong")
        try expect(!plan.desktop, "Games must launch directly")
        let json = try JSONEncoder().encode(plan.arguments)
        try expect(try JSONDecoder().decode([String].self, from: json) == plan.arguments, "JSON argv changed Unicode or spaces")
        try expectFailure("32-bit executable was accepted") {
            try LibraryFiles.validateExecutable(imported.directory + "/bin/Launcher.exe", drive: drive)
        }
        _ = try write("broken.exe", data: Data("not a PE".utf8), root: drive)
        try expectFailure("Invalid PE was accepted") { try LibraryFiles.validateExecutable("broken.exe", drive: drive) }
        try expectFailure("Missing executable was accepted") { try LibraryFiles.validateExecutable("missing.exe", drive: drive) }
        for path in ["../escape.exe", "/tmp/escape.exe", "a/../../escape.exe", "C:\\game.exe", "a//b.exe", "a/quoted\".exe"] {
            try expectFailure("Invalid path accepted: \(path)") { _ = try LibraryFiles.url(for: path, drive: drive) }
        }
        try fm.createSymbolicLink(at: drive.appendingPathComponent("outside"), withDestinationURL: temp)
        try expectFailure("Symlink escaped the Windows drive") { _ = try LibraryFiles.url(for: "outside/broken.exe", drive: drive) }
        try expectFailure("Long path was silently truncated") {
            _ = try LibraryFiles.windowsPath(String(repeating: "a", count: 480) + "/Game.exe", drive: drive)
        }
        try expectFailure("Importing own parent folder would recursively copy staging") {
            _ = try LibraryFiles.importFile(temp, as: .game, drive: drive)
        }

        let msi = try write("Source/My Setup 日本語.msi")
        let installer = try LibraryFiles.importFile(msi, as: .installer, drive: drive)
        let installPlan = try LaunchPlan.make(item: installer, drive: drive)
        try expect(installPlan.desktop, "Installer needs the Windows desktop")
        try expect(installPlan.arguments[1] == "C:\\windows\\system32\\msiexec.exe", "MSI did not select msiexec")
        try expect(installPlan.arguments[2] == "/i", "MSI did not request installation")
        try expect(installPlan.arguments[3].hasSuffix("My Setup 日本語.msi"), "MSI path lost spaces or Unicode")
        let exe = try write("Source/Setup.exe", data: pe(0x8664))
        let exeInstaller = try LibraryFiles.importFile(exe, as: .installer, drive: drive)
        let exePlan = try LaunchPlan.make(item: exeInstaller, drive: drive)
        try expect(exePlan.arguments.count == 2 && exePlan.arguments[1].hasSuffix("Setup.exe"), "EXE setup must launch directly in desktop")
        let duplicate = try LibraryFiles.importFile(exe, as: .installer, drive: drive)
        try expect(duplicate.directory != exeInstaller.directory, "Repeated imports collided")
        _ = try write("Program Files/Installed/App.exe", data: pe(0x8664), root: drive)
        _ = try write("windows/system32/Hidden.exe", data: pe(0x8664), root: drive)
        let installed = try LibraryFiles.executables(drive: drive)
        try expect(installed.contains { $0.path == "Program Files/Installed/App.exe" }, "Installed app was not discovered")
        try expect(!installed.contains { $0.path.hasPrefix("windows/") || $0.path.hasPrefix("Madeira/") }, "Scan exposed system DLLs or installer imports")
        let before = try fm.contentsOfDirectory(atPath: drive.appendingPathComponent("Madeira/Imports").path).sorted()
        _ = try write("Empty Game/readme.txt")
        try expectFailure("Empty folder import should fail") {
            _ = try LibraryFiles.importFile(temp.appendingPathComponent("Empty Game"), as: .game, drive: drive)
        }
        let after = try fm.contentsOfDirectory(atPath: drive.appendingPathComponent("Madeira/Imports").path).sorted()
        try expect(before == after, "Failed import left staged or published files")

        // Persist/reload favorites, executable choices and arguments; removal preserves files.
        game.favorite = true
        let manifest = temp.appendingPathComponent("library.json")
        try JSONEncoder().encode([game]).write(to: manifest)
        let store = LibraryStore(manifestURL: manifest)
        try expect(store.items == [game], "Library did not round-trip")
        game.name = "Renamed game"
        store.update(game)
        try expect(LibraryStore(manifestURL: manifest).items == [game], "Edits were not persisted")
        store.remove(game)
        try expect(store.items.isEmpty && fm.fileExists(atPath: copiedData.path), "Removing a shortcut removed game files")
        let corrupt = Data("broken manifest".utf8)
        try corrupt.write(to: manifest)
        let brokenStore = LibraryStore(manifestURL: manifest)
        brokenStore.remove(game)
        try expect(try Data(contentsOf: manifest) == corrupt, "Corrupt manifest was overwritten")
        // '+' must survive decoders that interpret it as a query-space character.
        let script = "+/8="
        guard let jitURL = StikJITRequest.url(bundleID: "com.example.madeira", scriptBase64: script),
              let components = URLComponents(url: jitURL, resolvingAgainstBaseURL: false) else {
            throw TestFailure(description: "JIT URL could not be built")
        }
        try expect(jitURL.scheme == "stikjit" && jitURL.host == "enable-jit", "Wrong StikDebug action")
        try expect(components.queryItems?.first { $0.name == "script-data" }?.value == script, "JIT script was corrupted")
        try expect(components.queryItems?.first { $0.name == "bundle-id" }?.value == "com.example.madeira", "Wrong JIT target")
        try expect(components.percentEncodedQuery?.contains("+") == false, "Base64 '+' was left ambiguous")
        print("Library tests passed: imports, paths, PE architecture, launch plans, persistence and StikDebug URL")
    }
}
