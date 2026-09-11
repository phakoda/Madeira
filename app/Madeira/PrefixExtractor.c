/* Bounded gzip/ustar prefix installer. Extract to a private staging directory,
 * verify the entire archive (including gzip CRC), then install complete files
 * without overwriting existing user data. Publish .update-timestamp LAST.
 * Supported: regular files, directories, ustar prefixes, local PAX path/size,
 * GNU long names, and ignorable PAX metadata. Links/devices/sparse files are
 * deliberately rejected: the bundled template contains none of them. */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#include "PrefixExtractor.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

#define BLOCK 512u
#define COPY_BYTES (64u * 1024u)
#define PATH_BYTES 4096u
#define MAX_DEPTH 64u
#define MAX_ENTRIES 100000u
#define MAX_FILE_BYTES (512ull * 1024u * 1024u)
#define MAX_TOTAL_BYTES (2ull * 1024u * 1024u * 1024u)
#define MAX_STREAM_BYTES (MAX_TOTAL_BYTES + 100ull * 1024u * 1024u)
#define STAMP ".update-timestamp"

struct reader { gzFile gz; uint64_t consumed; };

static int fail(const char *reason) {
    fprintf(stderr, "[prefix-extract] %s\n", reason);
    return -1;
}
static int read_exact(struct reader *r, void *dst, size_t length) {
    if (length > MAX_STREAM_BYTES - r->consumed) return fail("archive exceeds byte limit");
    size_t done = 0;
    while (done < length) {
        unsigned want = (unsigned)((length - done) > COPY_BYTES ? COPY_BYTES : length - done);
        int n = gzread(r->gz, (char *)dst + done, want);
        if (n <= 0) return fail("truncated or invalid gzip/tar stream");
        done += (size_t)n;
        r->consumed += (unsigned)n;
    }
    return 0;
}
static int all_zero(const unsigned char *p, size_t n) {
    for (size_t i = 0; i < n; ++i) if (p[i]) return 0;
    return 1;
}
static int octal(const unsigned char *p, size_t n, uint64_t *out) {
    uint64_t v = 0;
    size_t i = 0;
    while (i < n && p[i] == ' ') ++i;
    for (; i < n && p[i] >= '0' && p[i] <= '7'; ++i) {
        if (v > (UINT64_MAX - (p[i] - '0')) / 8) return -1;
        v = v * 8 + (p[i] - '0');
    }
    for (; i < n; ++i) if (p[i] != 0 && p[i] != ' ') return -1;
    *out = v;
    return 0;
}
static int decimal(const char *p, size_t n, uint64_t *out) {
    uint64_t v = 0;
    if (!n) return -1;
    for (size_t i = 0; i < n; ++i) {
        if (p[i] < '0' || p[i] > '9' || v > (UINT64_MAX - (p[i] - '0')) / 10) return -1;
        v = v * 10 + (p[i] - '0');
    }
    *out = v;
    return 0;
}
/* All output paths stay below prefix/. Do not silently truncate names or
 * collapse '..'. Dot/repeated-slash spelling is harmless and normalized. */
static int relative_name(const char *name, char out[PATH_BYTES]) {
    if (!*name || *name == '/') return fail("invalid absolute/empty member name");
    size_t used = 0;
    unsigned depth = 0;
    int root_seen = 0;
    while (*name) {
        while (*name == '/') ++name;
        if (!*name) break;
        const char *end = strchr(name, '/');
        size_t n = end ? (size_t)(end - name) : strlen(name);
        if (n == 1 && *name == '.') { name += n; continue; }
        if (n == 2 && name[0] == '.' && name[1] == '.') return fail("parent traversal in member name");
        if (n > 255 || ++depth > MAX_DEPTH) return fail("member path component/depth exceeds limit");
        if (!root_seen) {
            if (n != 6 || memcmp(name, "prefix", 6)) return fail("member is not rooted in prefix/");
            root_seen = 1;
        } else {
            if (!used && n >= 14 && !memcmp(name, ".madeira-seed.", 14))
                return fail("reserved staging name in archive");
            if (used + (used != 0) + n >= PATH_BYTES) return fail("member path too long");
            if (used) out[used++] = '/';
            memcpy(out + used, name, n); used += n;
        }
        name += n;
    }
    out[used] = 0;
    return root_seen ? 0 : fail("missing prefix root");
}
/* Open/create a validated relative directory chain, never following symlinks.
 * The caller owns the returned descriptor. */
static int directory_at(int root, const char *path) {
    int fd = dup(root);
    if (fd < 0) return -1;
    while (*path) {
        const char *end = strchr(path, '/');
        size_t n = end ? (size_t)(end - path) : strlen(path);
        char component[256];
        if (!n || n >= sizeof(component)) { close(fd); return -1; }
        memcpy(component, path, n); component[n] = 0;
        if (mkdirat(fd, component, 0755) && errno != EEXIST) { close(fd); return -1; }
        int next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(fd);
        if (next < 0) return -1;
        fd = next;
        path += n + (end != NULL);
    }
    return fd;
}
static int parent_at(int root, char path[PATH_BYTES], const char **leaf) {
    char *slash = strrchr(path, '/');
    if (!slash) { *leaf = path; return dup(root); }
    *slash = 0; *leaf = slash + 1;
    return directory_at(root, path);
}
static int write_all(int fd, const unsigned char *p, size_t n) {
    while (n) {
        ssize_t wrote = write(fd, p, n);
        if (wrote < 0 && errno == EINTR) continue;
        if (wrote <= 0) return -1;
        p += wrote; n -= (size_t)wrote;
    }
    return 0;
}
static int padding(struct reader *r, uint64_t size) {
    unsigned char buf[BLOCK];
    size_t n = (size_t)((BLOCK - size % BLOCK) % BLOCK);
    return read_exact(r, buf, n);
}
static int pax(const char *data, size_t n, int global, char path[PATH_BYTES],
               uint64_t *size, int *has_size) {
    size_t offset = 0;
    while (offset < n) {
        const char *record = data + offset;
        const char *space = memchr(record, ' ', n - offset);
        uint64_t length;
        if (!space || decimal(record, (size_t)(space - record), &length) ||
            length > n - offset || length <= (uint64_t)(space - record) + 2 ||
            record[length - 1] != '\n') return fail("invalid PAX record length");
        const char *key = space + 1;
        size_t body = (size_t)length - (size_t)(key - record) - 1;
        const char *eq = memchr(key, '=', body);
        if (!eq || eq == key || memchr(key, 0, body)) return fail("invalid PAX record");
        size_t k = (size_t)(eq - key), v = body - k - 1;
        if (k >= 10 && !memcmp(key, "GNU.sparse", 10)) return fail("sparse files are unsupported");
        if (k == 4 && !memcmp(key, "path", 4)) {
            if (global || !v || v >= PATH_BYTES) return fail("invalid/global PAX path");
            memcpy(path, eq + 1, v); path[v] = 0;
        } else if (k == 4 && !memcmp(key, "size", 4)) {
            if (global || decimal(eq + 1, v, size)) return fail("invalid/global PAX size");
            *has_size = 1;
        } else if ((k == 8 && !memcmp(key, "linkpath", 8)) ||
                   (k == 15 && !memcmp(key, "SCHILY.realsize", 15))) {
            return fail("link/sparse PAX metadata unsupported");
        }
        offset += (size_t)length;
    }
    return 0;
}
static int extract_to_stage(struct reader *r, int root, unsigned *files_out) {
    unsigned char header[BLOCK], buffer[COPY_BYTES];
    char pending_path[PATH_BYTES] = {0};
    uint64_t pending_size = 0, total = 0;
    int has_size = 0, expects_entry = 0;
    unsigned files = 0, entries = 0;
    for (;;) {
        if (read_exact(r, header, BLOCK)) return -1;
        if (all_zero(header, BLOCK)) {
            if (expects_entry || read_exact(r, header, BLOCK) || !all_zero(header, BLOCK))
                return fail("missing second tar end block or dangling metadata");
            /* Read through the gzip trailer: stopping at tar EOF skips CRC
             * validation and used to accept truncated/corrupt installations. */
            for (;;) {
                int n = gzread(r->gz, buffer, sizeof(buffer));
                if (n < 0) return fail("gzip checksum/trailer failure");
                if (!n) {
                    int error;
                    (void)gzerror(r->gz, &error);
                    if (error != Z_OK && error != Z_STREAM_END) return fail("incomplete gzip trailer");
                    break;
                }
                if ((uint64_t)n > MAX_STREAM_BYTES - r->consumed || !all_zero(buffer, (size_t)n))
                    return fail("unexpected/excess data after tar end");
                r->consumed += (unsigned)n;
            }
            if (!files) return fail("archive contains no regular files");
            *files_out = files;
            return 0;
        }
        if (++entries > MAX_ENTRIES) return fail("too many archive entries");
        uint64_t checksum, size, mode, sum = 0;
        if (octal(header + 148, 8, &checksum) || octal(header + 124, 12, &size) ||
            octal(header + 100, 8, &mode)) return fail("invalid tar numeric field");
        for (unsigned i = 0; i < BLOCK; ++i) sum += i >= 148 && i < 156 ? ' ' : header[i];
        if (sum != checksum) return fail("tar header checksum mismatch");
        if (memcmp(header + 257, "ustar", 5) || (header[262] && header[262] != ' '))
            return fail("unsupported tar format (expected ustar/PAX/GNU)");
        unsigned char type = header[156];
        if (type == 'x' || type == 'g' || type == 'L') {
            if (!size || size >= sizeof(buffer) || read_exact(r, buffer, (size_t)size) || padding(r, size))
                return fail("invalid/truncated extended header");
            buffer[size] = 0;
            if (type == 'L') {
                size_t len = strnlen((char *)buffer, (size_t)size);
                if (!len || len >= PATH_BYTES || !all_zero(buffer + len, (size_t)size - len))
                    return fail("invalid GNU long name");
                memcpy(pending_path, buffer, len); pending_path[len] = 0;
            } else if (pax((char *)buffer, (size_t)size, type == 'g', pending_path, &pending_size, &has_size)) return -1;
            if (type != 'g') expects_entry = 1;
            continue;
        }
        if (type != '0' && type != 0 && type != '5') return fail("unsupported member type (links/devices/sparse)");
        char name[PATH_BYTES], relative[PATH_BYTES];
        if (*pending_path) {
            memcpy(name, pending_path, strlen(pending_path) + 1);
        } else {
            size_t a = strnlen((char *)header, 100);
            /* GNU old-format bytes after magic are not the POSIX prefix. */
            size_t b = header[262] == 0 ? strnlen((char *)header + 345, 155) : 0;
            if (b) { memcpy(name, header + 345, b); name[b++] = '/'; }
            memcpy(name + b, header, a); name[a + b] = 0;
        }
        if (has_size) size = pending_size;
        pending_path[0] = 0; has_size = 0; expects_entry = 0;
        if (type != '5' && *name && name[strlen(name) - 1] == '/')
            return fail("regular file has a directory name");
        if (relative_name(name, relative)) return -1;
        if (size > MAX_FILE_BYTES || size > MAX_TOTAL_BYTES - total) return fail("prefix payload exceeds limit");
        total += size;
        if (type == '5') {
            if (size) return fail("directory has a nonempty payload");
            int fd = directory_at(root, relative);
            if (fd < 0) return fail("cannot create staged directory");
            close(fd);
            continue;
        }
        if (!*relative) return fail("regular file cannot replace prefix root");
        const char *leaf;
        int parent = parent_at(root, relative, &leaf);
        if (parent < 0) return fail("cannot open staged parent");
        int fd = openat(parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        close(parent);
        if (fd < 0) return fail("duplicate/unwritable staged file");
        int result = 0;
        uint64_t remaining = size;
        while (remaining) {
            size_t n = remaining > sizeof(buffer) ? sizeof(buffer) : (size_t)remaining;
            if (read_exact(r, buffer, n) || write_all(fd, buffer, n)) { result = -1; break; }
            remaining -= n;
        }
        if (!result && (padding(r, size) || fchmod(fd, 0644 | (mode & 0111)) || fsync(fd))) result = -1;
        if (close(fd)) result = -1;
        if (result) return fail("incomplete/unwritable staged file");
        ++files;
    }
}
static int sync_directory(int fd) {
    if (!fsync(fd) || errno == EINVAL || errno == ENOTSUP) return 0;
    return -1;
}
static int install_file(int src, int dst, const char *name) {
    if (!linkat(src, name, dst, name, 0)) return 0; /* atomic, same filesystem */
    if (errno != EEXIST) return -1;
    struct stat st;
    /* Preserve pre-existing regular files (registry, saves, etc.). Never
     * follow a symlink or overwrite a conflicting directory. */
    return !fstatat(dst, name, &st, AT_SYMLINK_NOFOLLOW) && S_ISREG(st.st_mode) ? 0 : -1;
}
static int merge_tree(int src, int dst, unsigned depth) {
    if (depth > MAX_DEPTH) return -1;
    int copy = dup(src);
    if (copy < 0) return -1;
    DIR *dir = fdopendir(copy);
    if (!dir) { close(copy); return -1; }
    int result = 0;
    struct dirent *ent;
    for (;;) {
        errno = 0; ent = readdir(dir);
        if (!ent) { if (errno) result = -1; break; }
        const char *name = ent->d_name;
        if (!strcmp(name, ".") || !strcmp(name, "..") || (!depth && !strcmp(name, STAMP))) continue;
        struct stat st;
        if (fstatat(src, name, &st, AT_SYMLINK_NOFOLLOW)) { result = -1; break; }
        if (S_ISDIR(st.st_mode)) {
            int from = openat(src, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            int to = directory_at(dst, name);
            if (from < 0 || to < 0 || merge_tree(from, to, depth + 1)) result = -1;
            if (from >= 0) close(from);
            if (to >= 0) close(to);
        } else if (!S_ISREG(st.st_mode) || install_file(src, dst, name)) result = -1;
        if (result) break;
    }
    closedir(dir);
    if (!result) result = sync_directory(dst);
    return result;
}
static void clean_tree(int root, unsigned depth) {
    if (depth > MAX_DEPTH) return;
    int copy = dup(root);
    if (copy < 0) return;
    /* dup shares the directory offset with merge_tree's descriptor. Rewind
     * before cleanup or an already-walked directory would leak every file. */
    DIR *dir = fdopendir(copy);
    if (!dir) { close(copy); return; }
    rewinddir(dir);
    struct dirent *ent;
    while ((ent = readdir(dir))) {
        const char *name = ent->d_name;
        if (!strcmp(name, ".") || !strcmp(name, "..")) continue;
        struct stat st;
        if (fstatat(root, name, &st, AT_SYMLINK_NOFOLLOW)) continue;
        if (S_ISDIR(st.st_mode)) {
            int fd = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (fd >= 0) { clean_tree(fd, depth + 1); close(fd); }
            (void)unlinkat(root, name, AT_REMOVEDIR);
        } else (void)unlinkat(root, name, 0);
    }
    closedir(dir);
}
int madeira_extract_prefix_tgz(const char *tgz_path, const char *dest_dir) {
    if (!tgz_path || !dest_dir || !*tgz_path || !*dest_dir) return fail("missing archive/destination path");
    /* Destination parent is supplied by the application, not by the archive.
     * It must already exist; do not resolve arbitrary archive-controlled roots. */
    if (mkdir(dest_dir, 0755) && errno != EEXIST) return fail("cannot create prefix directory");
    int dest = open(dest_dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (dest < 0) return fail("destination is not a real directory");
    char stage_path[PATH_BYTES];
    int n = snprintf(stage_path, sizeof(stage_path), "%s/.madeira-seed.XXXXXX", dest_dir);
    if (n < 0 || (size_t)n >= sizeof(stage_path) || !mkdtemp(stage_path)) {
        close(dest); return fail("cannot create staging directory");
    }
    const char *stage_name = strrchr(stage_path, '/') + 1;
    int stage = openat(dest, stage_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    int result = -1, published_stamp = 0;
    unsigned files = 0;
    struct reader r = { .gz = gzopen(tgz_path, "rb"), .consumed = 0 };
    if (stage >= 0 && r.gz && gzbuffer(r.gz, COPY_BYTES) == 0 && !gzdirect(r.gz))
        result = extract_to_stage(&r, stage, &files);
    if (r.gz && gzclose(r.gz) != Z_OK) result = -1;
    if (!result) {
        /* All file contents/checksums have now been validated. On a merge
         * failure, already linked files are complete and retryable; no stamp
         * is published. Existing user files are never truncated/replaced. */
        result = merge_tree(stage, dest, 0);
        struct stat stamp;
        if (!result && !fstatat(stage, STAMP, &stamp, AT_SYMLINK_NOFOLLOW)) {
            if (!S_ISREG(stamp.st_mode)) result = -1;
            else if (!linkat(stage, STAMP, dest, STAMP, 0)) published_stamp = 1;
            else result = install_file(stage, dest, STAMP);
        } else if (!result && errno != ENOENT) result = -1;
        if (!result) result = sync_directory(dest);
    }
    if (stage >= 0) { clean_tree(stage, 0); close(stage); }
    if (unlinkat(dest, stage_name, AT_REMOVEDIR) && !result) result = -1;
    if (result && published_stamp) (void)unlinkat(dest, STAMP, 0);
    close(dest);
    if (result) return fail("prefix installation failed; existing files preserved");
    fprintf(stderr, "[prefix-extract] validated %u files; seeded missing files into %s\n", files, dest_dir);
    return 0;
}

int madeira_prefix_is_ready(const char *dest_dir) {
    if (!dest_dir || !*dest_dir) return 0;
    int root = open(dest_dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root < 0) return 0;
    static const char *files[] = { STAMP, "system.reg", "user.reg", "userdef.reg" };
    struct stat st;
    int ready = 1;
    for (unsigned i = 0; i < sizeof(files) / sizeof(files[0]); ++i) {
        if (fstatat(root, files[i], &st, AT_SYMLINK_NOFOLLOW) || !S_ISREG(st.st_mode) || st.st_size <= 0) {
            ready = 0; break;
        }
    }
    if (ready && (fstatat(root, "drive_c", &st, AT_SYMLINK_NOFOLLOW) || !S_ISDIR(st.st_mode))) ready = 0;
    close(root);
    return ready;
}
