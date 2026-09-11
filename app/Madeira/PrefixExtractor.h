#ifndef PREFIX_EXTRACTOR_H
#define PREFIX_EXTRACTOR_H

#ifdef __cplusplus
extern "C" {
#endif

// Validates/stages a gzip tar rooted at prefix/, then installs MISSING files
// below dest_dir. Existing regular files are preserved, never truncated. The
// destination's parent must exist. Links/devices/sparse members are rejected.
// Returns 0 on success, -1 on error. On validation failure nothing is installed;
// on a later I/O failure complete files may remain for retry, but the template
// completion stamp is not published before the other members are installed.
int madeira_extract_prefix_tgz(const char *tgz_path, const char *dest_dir);

// Minimal startup gate: nonempty regular stamp/registries and real drive_c dir.
// Does NOT certify the contents/compatibility of an existing Wine registry.
int madeira_prefix_is_ready(const char *dest_dir);

#ifdef __cplusplus
}
#endif
#endif
