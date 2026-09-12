#ifndef MADEIRA_WINE32_EMBEDDED_H
#define MADEIRA_WINE32_EMBEDDED_H

#ifdef __cplusplus
extern "C" {
#endif

// The engine owns process-global state. Call every function serially on the
// host UI thread, and run only one session at a time. Arguments are copied
// during start. Include argv[0] and the guest command, as for boxedmain.
// Start always selects the interpreter's sparse guest-address translation.
int madeira_wine32_start(int argc, const char** argv);

// Run one scheduler slice and process pending input without sleeping.
// Returns 1 while running, 0 after normal completion, or -1 on engine failure.
int madeira_wine32_tick(void);

// Close the current session and flush its persistent filesystem.
// Returns 1 on success, 0 on cleanup failure. Safe when already stopped.
int madeira_wine32_stop(void);

// Valid until the next start; empty after a successful start. Guest Windows
// exit codes are separate from engine failures and are not represented here.
const char* madeira_wine32_error(void);

#ifdef __cplusplus
}
#endif
#endif
