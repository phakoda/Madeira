#!/usr/bin/env python3
"""Offline failure-propagation tests; fake compiler/fixtures, NO Metal/network."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
checks = 0

def check(condition: bool, message: str) -> None:
    global checks
    checks += 1
    if not condition:
        raise AssertionError(message)

with tempfile.TemporaryDirectory(prefix='madeira-runner-fixtures.') as work:
    root = Path(work)
    remote = root / 'research/remote-metal'
    remote.mkdir(parents=True)
    for name in ['run-tests.sh', 'protocol.h']:
        shutil.copyfile(ROOT / 'research/remote-metal' / name, remote / name)
    headers = root / 'research/dxmt/src/winemetal/unix'
    headers.mkdir(parents=True)
    for name in ['wmt_remote_pack.h', 'wmt_remote_client.h']:
        (headers / name).touch()
    compiler = root / 'fake-compiler'
    compiler.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
with open(os.environ['COMPILER_LOG'], 'a') as f: f.write('compile\\n')
if os.environ.get('COMPILE_STATUS') == '9': sys.exit(9)
out = pathlib.Path(sys.argv[sys.argv.index('-o')+1])
status = os.environ.get('TEST_STATUS', '0')
if os.environ.get('FAIL_SUITE', 'wire_test') != out.name: status = '0'
out.write_text('#!/usr/bin/env bash\\necho first-line\\necho last-line\\nexit ' + status + '\\n')
out.chmod(0o755)
''')
    compiler.chmod(0o755)
    temp = root / 'tmp'; temp.mkdir()
    log = root / 'compiles.log'
    env = {**os.environ, 'CC': str(compiler), 'TMPDIR': str(temp),
           'RMETAL_TOKEN': 'offline-fixture-not-a-secret', 'COMPILER_LOG': str(log)}
    def run(*args: str, **settings: str) -> subprocess.CompletedProcess[str]:
        if log.exists(): log.unlink()
        return subprocess.run(['bash', str(remote / 'run-tests.sh'), *args],
                              env={**env, **settings}, text=True, capture_output=True, timeout=20)
    result = run()
    check(result.returncode == 2, 'requires explicit host; never contacts hard-coded machine')
    check(not log.exists(), 'no compile without host')
    result = run('offline.invalid', TEST_STATUS='7')
    check(result.returncode == 7, 'wire failure propagates through output formatting')
    check('first-line' in result.stderr and 'last-line' in result.stderr, 'full failure output retained')
    check(log.read_text().count('compile') == 1, 'stop before later suites')
    check(not list(temp.iterdir()), 'failed run cleans private output directory')
    result = run('offline.invalid', COMPILE_STATUS='9')
    check(result.returncode == 9, 'compiler failure propagates')
    check(log.read_text().count('compile') == 1, 'no stale test after failed build')
    check(not list(temp.iterdir()), 'compile failure cleanup')
    result = run('offline.invalid', TEST_STATUS='7', FAIL_SUITE='rmreplay')
    check(result.returncode == 7, 'last suite failure propagates')
    check(log.read_text().count('compile') == 5, 'all earlier stages were rebuilt')
    result = run('offline.invalid')
    check(result.returncode == 0, 'successful fixture run')
    check(log.read_text().count('compile') == 5, 'all five binaries rebuilt')
    check('replay:' in result.stdout, 'final success summary')
    check(not list(temp.iterdir()), 'successful run cleanup')
    (headers / 'wmt_remote_pack.h').unlink()
    result = run('offline.invalid')
    check(result.returncode == 2 and 'Missing pinned DXMT' in result.stderr, 'missing source preflight')
    check(not log.exists(), 'no compile on missing submodule')
print(f'Remote runner: {checks} offline checks passed (not a Metal integration run)')
