#!/usr/bin/env python3
"""Check iOS source registration and file-opening contracts without compiling."""
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'app/Madeira'
project = (ROOT / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
info = plistlib.loads((APP / 'Info.plist').read_bytes())

# Every Swift file must have an actual target Sources entry, not just a navigator entry.
source_phase = project.split('/* Begin PBXSourcesBuildPhase section */')[1].split('/* End PBXSourcesBuildPhase section */')[0]
for path in APP.glob('*.swift'):
    assert source_phase.count(f'/* {path.name} in Sources */') == 1, f'{path.name}: missing or duplicate Sources entry'
    assert re.search(rf'path = "?{re.escape(path.name)}"?;', project), f'{path.name}: missing file reference'

content_declarations = sum(len(re.findall(r'\bstruct ContentView\s*:', p.read_text())) for p in APP.glob('*.swift'))
assert content_declarations == 1, 'The app must have exactly one library entry point'
assert 'ContentView()' in (APP / 'MadeiraApp.swift').read_text()

extensions = {}
for declaration in info['UTImportedTypeDeclarations']:
    for extension in declaration['UTTypeTagSpecification']['public.filename-extension']:
        extensions[extension] = declaration['UTTypeIdentifier']
handlers = {t for item in info['CFBundleDocumentTypes'] for t in item['LSItemContentTypes']}
assert {'exe', 'msi'} <= extensions.keys()
assert all(extensions[extension] in handlers for extension in ['exe', 'msi'])
assert info['UIFileSharingEnabled'] and info['LSSupportsOpeningDocumentsInPlace']

bridge = (APP / 'WineProcessBridge.m').read_text()
header = (APP / 'WineProcessBridge.h').read_text()
session = (APP / 'EmulatorSession.swift').read_text()
assert 'int wine_process_last_exit_code(void)' in bridge and 'int wine_process_last_exit_code(void);' in header
assert 'MADEIRA_ARGV_JSON' in bridge and 'MADEIRA_ARGV_JSON' in session
assert 'MADEIRA_LAUNCH_CWD' in bridge and 'MADEIRA_LAUNCH_CWD' in session
assert 'setenv("SteamAppId",  "356400"' not in bridge, 'A fixed game ID would contaminate unrelated launches'
assert session.index('try ready.validate()') < session.index('madeira_seed_prefix_if_needed')
assert session.index('StikJITHelper.allocatePool') < session.index('wineserver_start(prefix)') < session.index('wine_process_start(prefix)')
resources = project.split('/* Begin PBXResourcesBuildPhase section */')[1].split('/* End PBXResourcesBuildPhase section */')[0]
assert resources.count('/* madeira-jit.js in Resources */') == 1, 'The current JIT script must ship in the IPA'
assert 'StikJITRequest.url(bundleID: bundleId, scriptBase64: resolvedScriptBase64)' in (APP / 'StikJITHelper.swift').read_text()
assert 'JITControlView(session: session)' in (APP / 'LibraryView.swift').read_text()
assert 'JITControlView(session: session)' in (APP / 'EmulatorSessionView.swift').read_text()
workflow = (ROOT / '.github/workflows/build-ipa.yml').read_text()
assert 'bash tests/run-library-tests.sh' in workflow
subprocess.run(['git', 'diff', '--check'], cwd=ROOT, check=True)
print('Library source checks passed: target membership, document types, launch wiring and diff whitespace')
print('No code was compiled. These checks do not validate Swift types, rendering or emulator behavior.')
