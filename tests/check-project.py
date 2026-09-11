#!/usr/bin/env python3
"""Check source membership and references; this is NOT an Xcode build/parser."""
from collections import Counter
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]

def sources() -> list[Path]:
    text = (ROOT / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
    definitions = re.findall(r'^\s*([0-9A-F]{8,24}) /\* .*? \*/ = \{', text, re.M)
    duplicate = [key for key, count in Counter(definitions).items() if count != 1]
    if duplicate:
        raise ValueError(f'Duplicate project IDs: {duplicate}')
    referenced = set(re.findall(r'\b([0-9A-F]{8,24}) /\*', text))
    missing = referenced.difference(definitions)
    if missing:
        raise ValueError(f'Undefined project references: {sorted(missing)}')
    files = {}
    for match in re.finditer(r'([0-9A-F]+) /\* .*? \*/ = \{isa = PBXFileReference; (.*?)\};', text):
        path = re.search(r'\bpath = (?:"([^"]+)"|([^;]+));', match[2])
        if path:
            files[match[1]] = path[1] or path[2]
    builds = dict(re.findall(r'([0-9A-F]+) /\* .*? \*/ = \{isa = PBXBuildFile; fileRef = ([0-9A-F]+)', text))
    phase = text.split('/* Begin PBXSourcesBuildPhase section */', 1)[1].split('/* End PBXSourcesBuildPhase section */', 1)[0]
    ids = re.findall(r'([0-9A-F]+) /\* .*? in Sources \*/', phase)
    paths = [ROOT / 'app/Madeira' / files[builds[key]] for key in ids]
    if len(paths) != len(set(paths)):
        raise ValueError('A production source is compiled more than once')
    for path in paths:
        if not path.is_file():
            raise ValueError(f'Missing source: {path.relative_to(ROOT)}')
    swift = sorted(path for path in paths if path.suffix == '.swift')
    on_disk = set((ROOT / 'app/Madeira').rglob('*.swift'))
    if set(swift) != on_disk:
        raise ValueError(f'Swift membership mismatch: {set(swift) ^ on_disk}')
    if len(re.findall(r'A100020C /\* GameController.framework in Frameworks \*/,', text)) != 1:
        raise ValueError('GameController framework must be in the link phase exactly once')
    return swift

if __name__ == '__main__':
    try:
        swift = sources()
        if len(sys.argv) == 2 and sys.argv[1] == '--swift-paths':
            print('\n'.join(str(path) for path in swift))
        elif len(sys.argv) == 1:
            print(f'Project references and source membership: passed ({len(swift)} Swift files)')
        else:
            raise ValueError('usage: check-project.py [--swift-paths]')
    except (ValueError, KeyError, IndexError) as error:
        raise SystemExit(str(error)) from error
