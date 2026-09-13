#!/usr/bin/env python3
"""Execute the Wine32 UIKit test host in an isolated CI Simulator."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from check_screen import green_pixel_count, cursor_pixel_count


def sim(*args, **kwargs):
    return subprocess.check_output(['xcrun', 'simctl', *map(str, args)], text=True, **kwargs).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get('GITHUB_ACTIONS') != 'true':
        parser.error('This execution fixture runs only in GitHub Actions')
    runtimes = json.loads(sim('list', 'runtimes', '--json'))['runtimes']
    runtimes = [r for r in runtimes if r.get('isAvailable') and '.iOS-' in r['identifier']]
    runtime = max(runtimes, key=lambda r: tuple(map(int, r['version'].split('.'))))
    device = sim('create', 'Madeira Wine32 CI', 'com.apple.CoreSimulator.SimDeviceType.iPhone-16', runtime['identifier'])
    process = None
    report = Path('/tmp/wine32-ios-session.json')
    log = Path('/tmp/wine32-ios-session.log')
    try:
        sim('boot', device)
        sim('bootstatus', device, '-b', timeout=180)
        sim('install', device, args.app.resolve())
        container = Path(sim('get_app_container', device, 'app.madeira.wine32probe', 'data'))
        result = container / 'Documents/wine32-result.json'
        payload = container / 'Documents/payload'
        with log.open('w') as output:
            process = subprocess.Popen(['xcrun', 'simctl', 'launch', '--console', '--terminate-running-process',
                device, 'app.madeira.wine32probe'], stdout=output, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 1250
            last_stage = None
            presentation_seen = False
            while time.monotonic() < deadline:
                # The guest must process both clicks before capture. Merely
                # queuing SDL events does not mean Wine selected its cursor yet.
                if not presentation_seen and (payload / 'pointer ready.txt').exists():
                    screenshot = Path('/tmp/wine32-ios-presented.png')
                    # Allow the queued Metal frame to reach the Simulator display.
                    time.sleep(1)
                    sim('io', device, 'screenshot', screenshot)
                    green_pixels = green_pixel_count(screenshot)
                    if green_pixels < 100:
                        raise RuntimeError(f'Direct3D rendered offscreen but its green frame is missing from the iOS display: {green_pixels} pixels')
                    cursor_pixels = cursor_pixel_count(screenshot)
                    if cursor_pixels < 25:
                        raise RuntimeError(f'Guest cursor is missing from the iOS display: {cursor_pixels} pixels')
                    (payload / 'graphics captured.txt').write_text('display-verified\n')
                    presentation_seen = True
                    print(f'Confirmed {green_pixels} green pixels on the Simulator display', flush=True)
                    print(f'Confirmed {cursor_pixels} guest cursor pixels on the Simulator display', flush=True)
                if result.exists():
                    state = json.loads(result.read_text())
                    if state['detail'] != last_stage:
                        last_stage = state['detail']
                        print(state, flush=True)
                        sim('io', device, 'screenshot', f'/tmp/wine32-ios-stage-{state["completedStages"]}.png')
                    if state['status'] in ('passed', 'failed'):
                        shutil.copyfile(result, report)
                        if state['status'] != 'passed' or state['completedStages'] != 4 or not presentation_seen:
                            raise RuntimeError(f'iOS Windows execution failed: {state}')
                        return
                if process.poll() is not None:
                    raise RuntimeError(f'Simulator app exited before completing the fixtures: {process.returncode}')
                time.sleep(0.5)
            raise TimeoutError('iOS Wine32 execution exceeded the fixture deadline')
    finally:
        subprocess.run(['xcrun', 'simctl', 'io', device, 'screenshot', '/tmp/wine32-ios-final.png'], check=False)
        with Path('/tmp/wine32-ios-system.log').open('w') as diagnostics:
            try:
                subprocess.run(['xcrun', 'simctl', 'spawn', device, 'log', 'show', '--style', 'compact',
                    '--last', '5m', '--predicate',
                    'process == "MadeiraWine32Probe" OR eventMessage CONTAINS "app.madeira.wine32probe"'],
                    stdout=diagnostics, stderr=subprocess.STDOUT, timeout=20, check=False)
            except subprocess.TimeoutExpired:
                print('Simulator diagnostic log collection timed out', flush=True)
        crash_roots = [Path.home() / 'Library/Logs/DiagnosticReports',
            Path.home() / f'Library/Developer/CoreSimulator/Devices/{device}/data/Library/Logs/CrashReporter']
        for root in crash_roots:
            if root.exists():
                for crash in root.glob('MadeiraWine32Probe*'):
                    if crash.is_file():
                        shutil.copyfile(crash, Path('/tmp') / ('wine32-ios-crash-' + crash.name))
        subprocess.run(['xcrun', 'simctl', 'terminate', device, 'app.madeira.wine32probe'], check=False)
        if process:
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=10)
        subprocess.run(['xcrun', 'simctl', 'shutdown', device], check=False)
        subprocess.run(['xcrun', 'simctl', 'delete', device], check=False)


if __name__ == '__main__':
    main()
