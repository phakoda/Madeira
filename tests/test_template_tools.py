#!/usr/bin/env python3
"""Host wrapper and early-build-failure tests; no Wine or Apple SDK required."""
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
    if not condition: raise AssertionError(message)

with tempfile.TemporaryDirectory(prefix='madeira-template-tools.') as tmp:
    temp = Path(tmp)
    result = subprocess.run(['bash', str(ROOT / 'tools/check-prefix-template.sh')],
                            capture_output=True, text=True, timeout=20)
    check(result.returncode == 0, f'shipped template: {result.stderr}')
    corrupt = temp / 'corrupt.tar.gz'; corrupt.write_bytes(b'not a gzip tar archive')
    result = subprocess.run(['bash', str(ROOT / 'tools/check-prefix-template.sh'), str(corrupt)],
                            capture_output=True, text=True, timeout=20)
    check(result.returncode != 0, 'corrupt template cannot pass a shell pipeline')
    check('OK --' not in result.stdout, 'no success claim after corruption')
    project = temp / 'isolated-project'
    (project / 'scripts').mkdir(parents=True)
    (project / 'app/Madeira').mkdir(parents=True)
    shutil.copyfile(ROOT / 'scripts/build-prefix-snapshot.sh', project / 'scripts/build-prefix-snapshot.sh')
    output = project / 'app/Madeira/prefix-template.tar.gz'
    output.write_bytes(b'original template must survive failed rebuild')
    failed_wineboot = temp / 'wineboot'
    failed_wineboot.write_text('''#!/usr/bin/env bash
mkdir -p "$WINEPREFIX"
printf 'incomplete' > "$WINEPREFIX/.update-timestamp"
echo 'fixture: wineboot failed after its marker appeared'
exit 23
''')
    failed_wineboot.chmod(0o755)
    work = temp / 'work'; work.mkdir()
    result = subprocess.run(['bash', str(project / 'scripts/build-prefix-snapshot.sh')],
                            env={**os.environ, 'WINE': shutil.which('true'), 'WINEBOOT': str(failed_wineboot),
                                 'TMPDIR': str(work)}, capture_output=True, text=True, timeout=20)
    check(result.returncode == 23, 'wineboot failure must propagate even after marker creation')
    check(output.read_bytes() == b'original template must survive failed rebuild', 'failed build preserves original archive')
    check('fixture: wineboot failed' in result.stderr, 'failure output preserved')
    check(not list(work.iterdir()), 'failed build cleans private work directory')
print(f'Template tools: {checks} checks passed (Wine was stubbed only for the failure test)')
