#!/usr/bin/env python3
"""Build the matching i386 GL bridge in CI and package its runtime overlay."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get('GITHUB_ACTIONS') != 'true':
        parser.error('Compile this fixture only in GitHub Actions')
    manifest = json.loads(Path(__file__).with_name('runtime.json').read_text())
    revision = (args.source / '.madeira-source-revision').read_text().strip()
    if revision != manifest['source']['revision']:
        parser.error('Guest GL must be built from the pinned interpreter revision')
    directory = args.source / 'tools/opengl'
    subprocess.run(['bash', 'buildgl.sh'], cwd=directory, check=True)
    bridge = (directory / 'libGL.so.1').read_bytes()
    if bridge[:5] != b'\x7fELF\x01' or int.from_bytes(bridge[18:20], 'little') != 3:
        raise RuntimeError('Guest OpenGL bridge is not an i386 ELF')
    # Upstream's version >= 10 selects the current direct-call-frame GL ABI.
    # The overlay must precede the original Wine ZIP, whose version 6 bridge
    # is intentionally rejected by the pinned interpreter.
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in [('version.txt', b'10\n'), ('lib/libGL.so.1', bridge)]:
            entry = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, data)
    args.output.with_suffix('.json').write_text(json.dumps({
        'sourceRevision': revision, 'guestABI': 10,
        'bridgeSHA256': hashlib.sha256(bridge).hexdigest(),
        'overlaySHA256': hashlib.sha256(args.output.read_bytes()).hexdigest()
    }, indent=2) + '\n')


if __name__ == '__main__':
    main()
