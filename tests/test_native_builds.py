#!/usr/bin/env python3
"""Offline build-orchestration tests; xcrun/compilation are intentionally mocked.
Real ar and shell execute. These tests NEVER build Apple binaries.
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CHECKS = 0

def check(value: bool, message: str) -> None:
    global CHECKS
    CHECKS += 1
    if not value:
        raise AssertionError(message)

def run(args, env=None, **kwargs):
    return subprocess.run(args, env=env, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=30, **kwargs)

with tempfile.TemporaryDirectory(prefix='madeira native build ') as directory:
    root = Path(directory)
    (root / 'bin').mkdir()
    (root / 'app/Madeira').mkdir(parents=True)
    (root / 'build/ntdll-unix/obj').mkdir(parents=True)
    (root / 'build/crypto-unix').mkdir(parents=True)
    (root / 'wine/dlls/ntdll/unix').mkdir(parents=True)
    script = ROOT / 'build/ntdll-unix/build.sh'
    shutil.copy2(script, root / 'build/ntdll-unix/build.sh')
    shutil.copy2(ROOT / 'build/native-build-common.sh', root / 'build/native-build-common.sh')
    generator = root / 'build/crypto-unix/gen_gnutls_symtab.sh'
    generator.write_text('#!/bin/sh\nexit 0\n'); generator.chmod(0o755)
    archive = root / 'app/Madeira/libntdll_unix.a'
    # Reproduce a stale legacy object directory containing every required object,
    # plus a removed source. A failed new compile must never consume these files.
    object_names = re.findall(r'"\$OBJ_DIR/([^"/]+)\.o"', script.read_text().split('ar rcs', 1)[1])
    for name in object_names:
        (root / 'build/ntdll-unix/obj' / (name + '.o')).write_bytes(b'STALE object')
    stale = root / 'build/ntdll-unix/obj/removed-source.o'; stale.write_bytes(b'STALE removed')
    run(['ar', 'rcs', str(root / 'build/ntdll-unix/obj/libntdll_unix.a'), str(stale)], check=True)
    for name in object_names[8:]:
        (root / 'wine/dlls/ntdll/unix' / (name + '.c')).write_text('/* mocked source */\n')
    xcrun = root / 'bin/xcrun'
    xcrun.write_text('''#!/usr/bin/env bash
set -eu
source_file= destination=
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --show-sdk-path) printf '%s\\n' '/mock Apple SDK'; exit 0 ;;
        ar)
            [[ "${FAIL_ARCHIVE:-0}" != 1 ]] || exit 13
            shift; exec "$REAL_AR" "$@" ;;
        -c) source_file="$2"; shift 2 ;;
        -o) destination="$2"; shift 2 ;;
        -isysroot) [[ "$2" == '/mock Apple SDK' ]] || exit 91; shift 2 ;;
        *) shift ;;
    esac
done
[[ -n "$source_file" && -n "$destination" ]] || exit 90
printf '%s\\n' "$source_file" >> "$COMPILE_TRACE"
name="${destination##*/}"
if [[ "${name%.o}" == "${FAIL_OBJECT:-}" ]]; then
    echo 'injected compile failure' >&2; exit 12
fi
printf 'FRESH %s' "${source_file##*/}" > "$destination"
'''); xcrun.chmod(0o755)
    env = os.environ.copy()
    env.update(PATH=str(root / 'bin') + os.pathsep + env['PATH'],
               COMPILE_TRACE=str(root / 'compile.jsonl'), REAL_AR=shutil.which('ar'))
    archive.write_bytes(b'original shipped library')
    env['FAIL_OBJECT'] = 'audio_null_ios'
    result = run(['bash', str(root / 'build/ntdll-unix/build.sh')], env=env)
    check(result.returncode != 0, 'ntdll failure must propagate')
    check(archive.read_bytes() == b'original shipped library', 'compile failure preserves app library')
    failed_dirs = list((root / 'build/ntdll-unix').glob('.objects.*'))
    check(len(failed_dirs) == 1, 'failed isolated build keeps diagnostics')
    check('injected compile failure' in (failed_dirs[0] / 'audio_null_ios.err').read_text(), 'compiler error retained')
    check(stale.read_bytes() == b'STALE removed', 'legacy directory is not mutated')
    del env['FAIL_OBJECT']
    result = run(['bash', str(root / 'build/ntdll-unix/build.sh')], env=env)
    check(result.returncode == 0, 'mocked successful build: ' + result.stderr)
    members = run(['ar', 't', str(archive)], check=True).stdout.splitlines()
    check(set(members) == {name + '.o' for name in object_names}, 'archive has exactly current members')
    check('removed-source.o' not in members, 'no stale archive member survives')
    for name in object_names:
        data = run(['ar', 'p', str(archive), name + '.o'], check=True).stdout
        check(data.startswith('FRESH '), 'current object required: ' + name)
    check(len(list((root / 'build/ntdll-unix').glob('.objects.*'))) == 1, 'successful scratch cleaned; failed logs kept')
    check(not list((root / 'app/Madeira').glob('.*.publish.*')), 'publication scratch cleaned')

    # Check the shared publisher rejects empty/invalid/empty-member archives and
    # does not overwrite the old destination on copy failure even inside `if`.
    destination = root / 'destination.a'; destination.write_bytes(b'known-good')
    helper = root / 'build/native-build-common.sh'
    for payload in [b'', b'not an archive', b'!<arch>\n']:
        bad = root / 'bad.a'; bad.write_bytes(payload)
        result = run(['bash', '-c', 'source "$1"; madeira_publish_archive "$2" "$3"',
                      'test', str(helper), str(bad), str(destination)], env=env)
        check(result.returncode != 0 and destination.read_bytes() == b'known-good', 'bad archive cannot replace destination')
    cp = root / 'bin/cp'; cp.write_text('#!/bin/sh\nexit 9\n'); cp.chmod(0o755)
    result = run(['bash', '-c', 'source "$1"; if madeira_publish_archive "$2" "$3"; then exit 0; else exit 7; fi',
                  'test', str(helper), str(archive), str(destination)], env=env)
    check(result.returncode == 7 and destination.read_bytes() == b'known-good', 'failed copy in conditional remains failure')
    check(not list(root.glob('.*.publish.*')), 'failed publish scratch cleaned')
    cp.unlink()

    # Exercise DXMT's real orchestration: paths contain spaces and a removed .o
    # in the old object directory must not leak into the published archive.
    (root / 'build/dxmt-ios/obj').mkdir(parents=True)
    shutil.copy2(ROOT / 'build/dxmt-ios/build.sh', root / 'build/dxmt-ios/build.sh')
    (root / 'build/dxmt-ios/obj/obsolete.o').write_bytes(b'STALE')
    dxmt_archive = root / 'build/dxmt-ios/libdxmt_unix.a'
    dxmt_archive.write_bytes(b'old dxmt')
    env['FAIL_OBJECT'] = 'cache'
    result = run(['bash', str(root / 'build/dxmt-ios/build.sh')], env=env)
    check(result.returncode != 0 and dxmt_archive.read_bytes() == b'old dxmt', 'DXMT compile failure preserves archive')
    del env['FAIL_OBJECT']
    result = run(['bash', str(root / 'build/dxmt-ios/build.sh')], env=env)
    check(result.returncode == 0, 'DXMT paths with spaces: ' + result.stderr)
    members = run(['ar', 't', str(dxmt_archive)], check=True).stdout.splitlines()
    check('obsolete.o' not in members and 'winemetal_unix.o' in members and len(members) == 20,
          'DXMT has only fresh expected objects')
    before = dxmt_archive.read_bytes(); env['FAIL_ARCHIVE'] = '1'
    result = run(['bash', str(root / 'build/dxmt-ios/build.sh')], env=env)
    check(result.returncode != 0 and dxmt_archive.read_bytes() == before, 'archiver failure preserves DXMT artifact')

print(f'Native build orchestration: {CHECKS} checks passed (compiler/SDK mocked; no iOS binaries built)')
