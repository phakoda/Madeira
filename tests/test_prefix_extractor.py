#!/usr/bin/env python3
"""Black-box regression tests of the actual C installer, including shipped data."""
import gzip
import hashlib
import io
from pathlib import Path
import random
import subprocess
import sys
import tarfile
import tempfile

DRIVER = Path(sys.argv[1]).resolve()
ROOT = Path(__file__).resolve().parents[1]
checks = 0

def check(ok, message):
    global checks
    checks += 1
    if not ok:
        raise AssertionError(message)

def archive(entries, format=tarfile.USTAR_FORMAT, pax_headers=None):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode='w', format=format, pax_headers=pax_headers) as tar:
        for name, data, kind, metadata in entries:
            info = tarfile.TarInfo(name)
            info.type = kind
            info.mode = 0o755 if kind == tarfile.DIRTYPE else 0o644
            info.linkname = metadata.get('linkname', '')
            info.pax_headers = metadata.get('pax', {})
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return raw.getvalue()

def entry(name, data=b'', kind=tarfile.REGTYPE, **metadata):
    return ('prefix/' + name, data, kind, metadata)

with tempfile.TemporaryDirectory(prefix='madeira-prefix-tests-') as tmp:
    root = Path(tmp)
    case_number = 0

    def run(label, payload, expected=True, setup=None, inspect=None):
        global case_number
        case_number += 1
        case = root / str(case_number)
        case.mkdir()
        tgz, dest = case / 'input.tgz', case / 'installed'
        tgz.write_bytes(payload)
        dest.mkdir()
        if setup:
            setup(dest)
        before = {p.relative_to(dest): p.read_bytes() for p in dest.rglob('*') if p.is_file() and not p.is_symlink()}
        result = subprocess.run([str(DRIVER), str(tgz), str(dest)], capture_output=True, timeout=10)
        check((result.returncode == 0) == expected,
              f'{label}: exit={result.returncode} {result.stderr.decode(errors="replace")}')
        check(b'AddressSanitizer' not in result.stderr and b'runtime error:' not in result.stderr,
              f'{label}: sanitizer failure {result.stderr}')
        check(not list(dest.glob('.madeira-seed.*')), label + ': leaked staging directory')
        for path, data in before.items():
            check((dest / path).read_bytes() == data, label + ': modified existing user file')
        if not expected:
            check(not (dest / '.update-timestamp').exists(), label + ': marked failed install complete')
        if inspect:
            inspect(dest)
        return dest

    base = [entry('', kind=tarfile.DIRTYPE), entry('system.reg', b'new registry\n'),
            entry('.update-timestamp', b'complete\n'), entry('drive_c/file.bin', bytes(range(256)) * 333)]
    raw = archive(base)
    basic = run('ustar with padding', gzip.compress(raw))
    check((basic / 'drive_c/file.bin').read_bytes() == base[-1][1], 'binary file byte-for-byte')
    check((basic / 'system.reg').read_bytes() == b'new registry\n', 'registry extracted')

    long_name = 'drive_c/' + 'a' * 90 + '/' + 'b' * 80 + '/file.txt'
    for fmt, label in [(tarfile.USTAR_FORMAT, 'ustar prefix'), (tarfile.PAX_FORMAT, 'PAX path'), (tarfile.GNU_FORMAT, 'GNU longname')]:
        dest = run(label, gzip.compress(archive(base + [entry(long_name, b'long name')], format=fmt)))
        check((dest / long_name).read_bytes() == b'long name', label + ': lost/truncated path')
    run('PAX size', gzip.compress(archive(base + [entry('pax', b'payload', pax={'size': '7'})], format=tarfile.PAX_FORMAT)))
    run('global harmless metadata', gzip.compress(archive(base, format=tarfile.PAX_FORMAT, pax_headers={'comment': 'metadata'})))
    run('global path unsupported', gzip.compress(archive(base, format=tarfile.PAX_FORMAT, pax_headers={'path': 'prefix/override'})), False)
    run('PAX sparse unsupported', gzip.compress(archive(base + [entry('sparse', pax={'GNU.sparse.map': '0,10'})], format=tarfile.PAX_FORMAT)), False)
    # Mac tar emits a ustar prefix field for some 100+ byte paths in the real template.
    shipped = (ROOT / 'app/Madeira/prefix-template.tar.gz').read_bytes()
    actual = run('bundled template', shipped)
    with tarfile.open(fileobj=io.BytesIO(shipped), mode='r:gz') as tar:
        for info in tar:
            relative = Path(info.name).relative_to('prefix')
            path = actual / relative
            if info.isdir():
                check(path.is_dir(), 'missing bundled directory: ' + info.name)
            elif info.isfile():
                data = tar.extractfile(info).read()
                check(path.is_file() and hashlib.sha256(path.read_bytes()).digest() == hashlib.sha256(data).digest(),
                      'bundled data mismatch: ' + info.name)
    check(len(list(actual.rglob('*'))) == 137, 'unexpected or truncated bundled path')
    def ready(path):
        return subprocess.run([str(DRIVER), '--ready', str(path)], capture_output=True, timeout=5).returncode == 0
    check(ready(actual), 'shipped prefix must pass minimum readiness gate')
    check(not ready(basic), 'incomplete registry set cannot start')
    for filename in ['.update-timestamp', 'system.reg', 'user.reg', 'userdef.reg']:
        saved = (actual / filename).read_bytes()
        (actual / filename).write_bytes(b'')
        check(not ready(actual), 'empty essential file cannot start: ' + filename)
        (actual / filename).unlink()
        check(not ready(actual), 'missing essential file cannot start: ' + filename)
        (actual / filename).symlink_to('/nonexistent')
        check(not ready(actual), 'symlink essential file cannot start: ' + filename)
        (actual / filename).unlink()
        (actual / filename).write_bytes(saved)
    check(ready(actual), 'readiness restored after files restored')

    def preserve(dest):
        (dest / 'system.reg').write_bytes(b'user registry - do not replace')
        (dest / 'drive_c').mkdir()
        (dest / 'drive_c/save.dat').write_bytes(b'user save data')
    run('resume preserves registry and saves', gzip.compress(raw), setup=preserve)
    outside = root / 'outside'; outside.mkdir()
    (outside / 'untouched').write_bytes(b'outside data')
    run('existing symlink parent', gzip.compress(raw), False,
        setup=lambda d: (d / 'drive_c').symlink_to(outside, target_is_directory=True))
    check(sorted(p.name for p in outside.iterdir()) == ['untouched'], 'followed destination symlink')
    run('file-directory collision', gzip.compress(raw), False, setup=lambda d: (d / 'system.reg').mkdir())
    run('duplicate file', gzip.compress(archive(base + [entry('system.reg', b'duplicate')])), False)
    run('duplicate directories', gzip.compress(archive(base + [entry('drive_c', kind=tarfile.DIRTYPE)])))
    run('empty gzip', gzip.compress(b''), False)
    run('empty tar', gzip.compress(bytes(1024)), False)
    run('not gzip', raw, False)
    run('truncated header', gzip.compress(raw[:200]), False)
    run('truncated file', gzip.compress(raw[:2100]), False)
    run('truncated gzip trailer', gzip.compress(raw)[:-8], False)
    crc = bytearray(gzip.compress(raw)); crc[-8] ^= 0x10
    run('gzip CRC corruption', bytes(crc), False)
    # The final file has a complete body, followed by only ONE end block.
    effective = sum(512 + ((len(e[1]) + 511) // 512) * 512 for e in base)
    run('missing second end block', gzip.compress(raw[:effective + 512]), False)
    run('garbage after tar EOF', gzip.compress(raw + b'nonzero'), False)
    for bad in ['', '/absolute', '../escape', 'prefix/../escape', 'prefix/drive_c/../../escape',
                'elsewhere/file', 'prefix/.madeira-seed.owned/file', 'prefix/' + '/'.join(['deep'] * 65),
                'prefix/' + 'x' * 256, 'prefix/trailing/']:
        items = base + [(bad, b'x', tarfile.REGTYPE, {})]
        run('invalid path ' + repr(bad), gzip.compress(archive(items, format=tarfile.PAX_FORMAT)), False)
    for kind in [tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE, tarfile.CHRTYPE, tarfile.BLKTYPE, b'Z']:
        run('unsupported type ' + repr(kind), gzip.compress(archive(base + [entry('special', kind=kind, linkname='../outside')], format=tarfile.GNU_FORMAT)), False)
    run('directory payload', gzip.compress(archive(base + [entry('dirdata', b'bad', kind=tarfile.DIRTYPE)])), False)
    huge = tarfile.TarInfo('prefix/huge'); huge.size = 512 * 1024 * 1024 + 1
    run('excessive declared size', gzip.compress(huge.tobuf() + bytes(1024)), False)
    late_bad = bytearray(raw); late_bad[2560] ^= 0x20  # corrupt a late header after the stamp
    run('late corruption does not publish earlier files', gzip.compress(late_bad), False,
        inspect=lambda d: check(not list(d.iterdir()), 'partially installed corrupt archive'))
    # Recomputed checksums exercise field parsing rather than checksum rejection.
    for value in [b'77777777777\0', b'00000000009\0', b'\xff' * 12, b'-0000000001\0']:
        header = bytearray(raw[:512]); header[124:136] = value
        header[148:156] = b' ' * 8
        header[148:156] = f'{sum(header):06o}\0 '.encode()
        run('invalid/bounded numeric field', gzip.compress(header + raw[512:]), False)
    rng = random.Random(2417)
    for n in range(128):
        changed = bytearray(raw)
        # A single non-checksum byte change in a header must be detected.
        pos = rng.choice([i for i in range(512) if not 148 <= i < 156])
        changed[pos] ^= rng.randrange(1, 256)
        run('checksum mutation ' + str(n), gzip.compress(changed), False)
    print(f'Prefix installation: {checks} checks passed ({case_number} fixtures; 138 shipped members compared)')
