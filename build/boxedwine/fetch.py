#!/usr/bin/env python3
"""Fetch pinned BoxedWine source and full Wine32 filesystem. Does not compile."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import tarfile
import tempfile
import urllib.request

USER_AGENT = 'OpenAI File Downloader, XaiImageApiFetch/1.0'
MANIFEST = json.loads(Path(__file__).with_name('runtime.json').read_text())


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def download(spec, destination):
    if destination.is_file() and digest(destination) == spec['sha256']:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as output:
        partial = Path(output.name)
        try:
            request = urllib.request.Request(spec['url'], headers={'User-Agent': USER_AGENT})
            with urllib.request.urlopen(request, timeout=120) as response:
                shutil.copyfileobj(response, output)
            output.flush()
            if digest(partial) != spec['sha256']:
                raise ValueError(f"SHA-256 mismatch for {spec['url']}")
            partial.replace(destination)
        finally:
            partial.unlink(missing_ok=True)


def source(cache, destination):
    spec = MANIFEST['source']
    marker = destination / '.madeira-source-revision'
    if marker.is_file() and marker.read_text().strip() == spec['revision']:
        if not (destination / 'tools/opengl/gldef.h').is_file():
            raise ValueError(f'Source cache lacks generated OpenGL headers; use a fresh --source directory: {destination}')
        return
    if destination.exists():
        raise ValueError(f'Refusing to replace an existing source directory: {destination}')
    archive = cache / 'boxedwine-source.tar.gz'
    download(spec, archive)
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.boxedwine-', dir=destination.parent))
    try:
        with tarfile.open(archive, 'r:gz') as tar:
            # Only source trees used by this build. The upstream project folder
            # contains prebuilt macOS frameworks and symlinks, which are not used.
            for member in tar:
                parts = PurePosixPath(member.name).parts[1:]
                if not parts or parts[0] not in {'include', 'source', 'platform', 'lib', 'tools', 'license.txt'}:
                    continue
                if '..' in parts or PurePosixPath(member.name).is_absolute():
                    raise ValueError('Invalid archive path')
                target = staging.joinpath(*parts)
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                elif member.isfile():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with tar.extractfile(member) as data, target.open('wb') as output:
                        shutil.copyfileobj(data, output)
                else:
                    raise ValueError(f'Unsupported source archive entry: {member.name}')
        (staging / '.madeira-source-revision').write_text(spec['revision'] + '\n')
        staging.rename(destination)
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--wine', type=Path)
    args = parser.parse_args()
    source(args.cache, args.source)
    if args.wine:
        download(MANIFEST['wine'], args.wine)
    print('Pinned BoxedWine inputs verified')


if __name__ == '__main__':
    main()
