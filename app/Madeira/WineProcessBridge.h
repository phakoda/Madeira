#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Seed/validate the prefix BEFORE wineserver starts. Returns 0 or -1.
int madeira_seed_prefix_if_needed(const char *prefix_path);

// Start Wine process initialization on a background thread.
// Must be called AFTER wineserver is running.
// prefix_path: path to the Wine prefix directory
// Returns 0 on success, -1 on error.
int wine_process_start(const char *prefix_path);

// Check if Wine process is running
int wine_process_is_running(void);

// Last completed top-level Windows process exit code.
int wine_process_last_exit_code(void);

// Steam S0 net-test VPN gate: write C:\madeira-continue.flag into the
// prefix's drive_c so the paused winhttp-test.exe resumes to the Steam
// stage. Called by the "Continue Net Test" UI button after the user has
// detached the JIT debugger and switched VPNs. Returns 0 on success.
int madeira_write_continue_flag(void);

#ifdef __cplusplus
}
#endif
