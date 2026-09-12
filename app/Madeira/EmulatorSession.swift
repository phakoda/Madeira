import Foundation
import SwiftUI

@MainActor
final class EmulatorSession: ObservableObject {
    enum Phase: Equatable {
        case idle, preparing, needsJIT, enablingJIT, starting, running, finished(Int32), failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var title = "Windows desktop"
    @Published private(set) var libraryID: UUID?
    @Published var presented = false
    private var plan: LaunchPlan?
    private var monitor: Timer?
    /// The native Wine/FEX globals are process-lifetime. Do not reinitialize them after exit.
    private var hasStarted = false
    private var generation = UUID()
    var isActive: Bool { [.preparing, .needsJIT, .enablingJIT, .starting, .running].contains(phase) }
    var canLaunch: Bool { !isActive && !hasStarted }
    var status: String {
        switch phase {
        case .idle: return "Ready when you are"
        case .preparing: return "Preparing Windows…"
        case .needsJIT: return "Enable JIT to continue"
        case .enablingJIT: return "Waiting for StikDebug…"
        case .starting: return "Starting Windows…"
        case .running: return "Session running"
        case .finished(let code): return code == 0 ? "Session ended" : "Session ended with code \(code)"
        case .failed: return "Could not start"
        }
    }

    func launch(_ item: LibraryItem?) {
        guard canLaunch else { presented = true; return }
        generation = UUID()
        let request = generation
        title = item?.name ?? "Windows desktop"
        libraryID = item?.id
        phase = .preparing
        presented = true
        Task {
            do {
                let ready = try await Task.detached(priority: .userInitiated) {
                    let ready = try item.map { try LaunchPlan.make(item: $0) } ?? .windowsDesktop
                    try ready.validate()
                    guard madeira_seed_prefix_if_needed(LibraryFiles.prefix.path) == 0 else {
                        throw LibraryError.message("Windows could not be prepared. Check available storage and that the IPA includes its Windows runtime. Your imported files have been kept.")
                    }
                    return ready
                }.value
                guard generation == request else { return }
                plan = ready
                if jit_check_debugged() { start() } else { phase = .needsJIT }
            } catch {
                guard generation == request else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func enableJIT() {
        guard phase == .needsJIT else { return }
        if jit_check_debugged() { start(); return }
        guard StikJITHelper.isAvailable else {
            phase = .failed("Install and set up StikDebug, then launch this item again to enable JIT.")
            return
        }
        phase = .enablingJIT
        let request = generation
        StikJITHelper.enableJIT { [weak self] success in
            Task { @MainActor in
                guard let self, self.generation == request, self.phase == .enablingJIT else { return }
                if success { self.start() }
                else { self.phase = .failed("JIT was not enabled. Open StikDebug, check its pairing setup, then try again.") }
            }
        }
    }

    func cancelPreparation() {
        // Copying/seeding and native startup cannot be safely interrupted halfway through.
        guard phase == .needsJIT || phase == .enablingJIT else { return }
        generation = UUID()
        plan = nil
        phase = .idle
        presented = false
    }

    private func start() {
        guard let plan, !hasStarted else { return }
        hasStarted = true
        presented = true
        phase = .starting
        jit_install_trap_handler()
        let log = LogStore.shared
        log.uiPaused = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try Self.bootstrap(plan)
                }.value
                phase = .running
                monitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.checkForExit() }
                }
                checkForExit()
            } catch {
                log.uiPaused = false
                ws_log_quiet = 0
                phase = .failed(error.localizedDescription + " Close and reopen Madeira before starting another session.")
            }
        }
    }

    private func checkForExit() {
        guard phase == .running, wine_process_is_running() == 0 else { return }
        monitor?.invalidate()
        monitor = nil
        phase = .finished(wine_process_last_exit_code())
        LogStore.shared.uiPaused = false
        ws_log_quiet = 0
        GuestInput.shared.releaseAll()
    }

    /// Preserve existing opt-in configuration files while replacing the old test UI.
    nonisolated private static func applyRuntimeOverrides() {
        let overrides = [
            "madeira-wx.txt": "MADEIRA_WX",
            "madeira-mono-bridge.txt": "MADEIRA_WINEMONO_BRIDGE",
            "madeira-ctx-frame.txt": "MADEIRA_CTX_FRAME",
            "madeira-tf-trace.txt": "MADEIRA_TF_TRACE",
            "madeira-usd-time.txt": "MADEIRA_USD_TIME",
            "madeira-real-suspend.txt": "MADEIRA_REAL_SUSPEND",
            "madeira-mono-suspend.txt": "MONO_THREADS_SUSPEND",
            "madeira-apicensus.txt": "DXMT_API_CENSUS",
            "madeira-shadow.txt": "DXMT_SHADOW_PACK",
            "madeira-census.txt": "DXMT_CMD_CENSUS",
            "madeira-arena.txt": "MADEIRA_FEX_ARENA"
        ]
        for (file, variable) in overrides {
            if let text = try? String(contentsOf: LibraryFiles.documents.appendingPathComponent(file), encoding: .utf8) {
                setenv(variable, text.trimmingCharacters(in: .whitespacesAndNewlines), 1)
            }
        }
        if let text = try? String(contentsOf: LibraryFiles.documents.appendingPathComponent("madeira-remote.txt"), encoding: .utf8) {
            let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1)
            if parts.count == 2 {
                setenv("DXMT_REMOTE_METAL", String(parts[0]), 1)
                setenv("RMETAL_TOKEN", String(parts[1]), 1)
            }
        }
    }

    nonisolated private static func bootstrap(_ plan: LaunchPlan) throws {
        let log = LogStore.shared
        let arguments = try JSONEncoder().encode(plan.arguments)
        guard let json = String(data: arguments, encoding: .utf8) else {
            throw LibraryError.message("The launch arguments could not be encoded.")
        }
        setenv("MADEIRA_EXE", plan.executable, 1)
        setenv("MADEIRA_ARGV_JSON", json, 1)
        unsetenv("MADEIRA_ARGS")
        setenv("MADEIRA_USE_ARM64EC", "1", 1)
        setenv("MADEIRA_DESKTOP", plan.desktop ? "1" : "0", 1)
        setenv("MADEIRA_SCREEN_W", "1024", 1)
        setenv("MADEIRA_SCREEN_H", "768", 1)
        unsetenv("MADEIRA_INITIAL_CWD")
        for key in ["SteamAppPath", "SteamGameId", "SteamAppId"] { unsetenv(key) }
        if !plan.desktop, let cwd = plan.workingDirectory { setenv("SteamAppPath", cwd, 1) }
        if let appID = plan.steamAppID {
            setenv("SteamGameId", appID, 1)
            setenv("SteamAppId", appID, 1)
        }
        if let cwd = plan.workingDirectory { setenv("MADEIRA_LAUNCH_CWD", cwd, 1) }
        else { unsetenv("MADEIRA_LAUNCH_CWD") }

        // Retain the existing configurable pool size and renderer settings.
        var poolMB = 896
        if let text = try? String(contentsOf: LibraryFiles.documents.appendingPathComponent("madeira-pool.txt"), encoding: .utf8),
           let size = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), (256...1152).contains(size) {
            poolMB = size
        }
        if let text = try? String(contentsOf: LibraryFiles.documents.appendingPathComponent("madeira-dxmt.txt"), encoding: .utf8) {
            setenv("DXMT_CONFIG", text.trimmingCharacters(in: .whitespacesAndNewlines), 1)
        }
        applyRuntimeOverrides()
        ws_log_quiet = 1
        // Use the established allocator and detach ordering; the UI owns no JIT internals.
        guard let pool = StikJITHelper.allocatePool(poolSize: poolMB * 1024 * 1024) else {
            throw LibraryError.message("The emulator could not allocate its JIT memory.")
        }
        setenv("WINE_IOS_JIT_RX", String(format: "%lx", Int(bitPattern: pool.rx)), 1)
        setenv("WINE_IOS_JIT_RW", String(format: "%lx", Int(bitPattern: pool.rw)), 1)
        setenv("WINE_IOS_JIT_SIZE", String(format: "%lx", pool.size), 1)
        StikJITHelper.detachDebugger()
        let prefix = LibraryFiles.prefix.path
        guard wineserver_start(prefix) == 0 else {
            throw LibraryError.message("The Windows service could not start. See Diagnostics for details.")
        }
        // Match the existing native bootstrap's service startup grace period.
        Thread.sleep(forTimeInterval: 2)
        guard wineserver_is_running() != 0, wine_process_start(prefix) == 0 else {
            wineserver_stop()
            throw LibraryError.message("The Windows process could not start. See Diagnostics for details.")
        }
        log.log("Launched \(plan.title)", level: .success)
    }
}
