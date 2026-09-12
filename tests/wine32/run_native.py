#!/usr/bin/env python3
"""Run a Windows fixture inside native BoxedWine, recording its real outcome."""
import argparse
from pathlib import Path
import signal
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine', type=Path, required=True)
    parser.add_argument('--rootfs', type=Path, required=True)
    parser.add_argument('--prefix', type=Path, required=True)
    parser.add_argument('--payload', type=Path, required=True)
    parser.add_argument('--result', type=Path, required=True)
    parser.add_argument('--expected', required=True)
    parser.add_argument('--name', required=True)
    parser.add_argument('--timeout', type=int, default=240)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('A guest command is required after --')
    args.result.unlink(missing_ok=True)
    log = Path('/tmp') / f'wine32-{args.name}.log'
    argv = [str(args.engine), '-root', str(args.prefix), '-zip', str(args.rootfs),
            '-mount_drive', str(args.payload), 'd', '-disableLinearMemory', '-nosound',
            '-env', 'WINEDEBUG=-all,err+all'] + command

    def screenshot(label):
        path = Path('/tmp') / f'wine32-{args.name}-{label}.png'
        try:
            subprocess.run(['import', '-window', 'root', str(path)], check=False, timeout=10)
        except (OSError, subprocess.TimeoutExpired) as error:
            print(f'Screenshot unavailable: {error}', flush=True)

    success = False
    with log.open('w') as output:
        process = subprocess.Popen(argv, stdout=output, stderr=subprocess.STDOUT)
        started = time.monotonic()
        captured = set()
        try:
            while True:
                elapsed = time.monotonic() - started
                for threshold in (15, 60, 180):
                    if elapsed >= threshold and threshold not in captured:
                        screenshot(str(threshold))
                        captured.add(threshold)
                if args.result.is_file():
                    actual = args.result.read_text()
                    if actual.strip() == args.expected:
                        success = True
                        screenshot('complete')
                        # SDL converts SIGINT into its normal quit event. Closing
                        # the emulator after the fixture finishes is separate from
                        # waiting for Wine's background desktop processes to exit.
                        if process.poll() is None:
                            process.send_signal(signal.SIGINT)
                        process.wait(timeout=30)
                        if process.returncode != 0:
                            raise RuntimeError(f'Guest succeeded, but emulator shutdown returned {process.returncode}')
                        break
                if process.poll() is not None:
                    raise RuntimeError(f'Engine exited {process.returncode} without the expected guest result')
                if elapsed >= args.timeout:
                    raise TimeoutError(f'Guest did not produce the expected result within {args.timeout} seconds')
                time.sleep(0.2)
        finally:
            if not success:
                screenshot('failure')
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            output.flush()
            print('\n'.join(log.read_text(errors='replace').splitlines()[-80:]), flush=True)
    print(f'{args.name}: verified Windows result and clean emulator shutdown', flush=True)


if __name__ == '__main__':
    main()
