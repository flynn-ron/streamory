#!/usr/bin/env python3
"""Verify sources independently of Xcode UI; optionally build the simulator App."""
import argparse
import json
import platform
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / 'build' / 'verification'

def run(label, command):
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (BUILD / (label + '.log')).write_text(result.stdout)
    print(f'{label}: {"PASS" if result.returncode == 0 else "FAIL"}', flush=True)
    if result.returncode:
        print(result.stdout[-4000:])
    return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', action='store_true', help='Also package App using an installed simulator runtime')
    args = parser.parse_args()
    BUILD.mkdir(parents=True, exist_ok=True)
    failures = []
    for label, command in [
        ('xcode-version', ['xcodebuild', '-version']),
        ('project', ['xcodebuild', '-list', '-project', 'Streamory.xcodeproj']),
        ('plist', ['plutil', '-lint', 'Streamory/Info.plist', 'Streamory/PrivacyInfo.xcprivacy', 'Streamory.xcodeproj/project.pbxproj']),
        ('core-tests', ['swift', 'test', '--scratch-path', 'build/swift-tests']),
    ]:
        if run(label, command).returncode:
            failures.append(label)
    sdk = run('simulator-sdk', ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
    if sdk.returncode == 0:
        sources = sorted(str(path.relative_to(ROOT)) for path in (ROOT / 'Streamory').rglob('*.swift'))
        architecture = 'arm64' if platform.machine() == 'arm64' else 'x86_64'
        compiled = run('native-compile', [
            'xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-emit-executable',
            '-sdk', sdk.stdout.strip(), '-target', f'{architecture}-apple-ios17.0-simulator',
            '-swift-version', '5', '-module-cache-path', str(BUILD / 'ModuleCache'),
            *sources, '-o', str(BUILD / 'Streamory-simulator'),
        ])
        if compiled.returncode:
            failures.append('native-compile')
    else:
        failures.append('simulator-sdk')
    runtime = run('runtimes', ['xcrun', 'simctl', 'list', 'runtimes', '--json'])
    ios = []
    try:
        ios = [item for item in json.loads(runtime.stdout)['runtimes']
               if item.get('isAvailable') and '.iOS-' in item.get('identifier', '')
               and int(item.get('version', '0').split('.')[0]) >= 17]
    except (ValueError, KeyError, TypeError):
        pass
    if not ios:
        print('iOS Simulator runtime unavailable: install iOS in Xcode Settings → Components.')
        print('SDK compilation does not verify App packaging, launch, UI or PhotoKit interaction.')
    if args.build:
        if not ios:
            failures.append('app-build: missing iOS runtime')
        else:
            result = run('app-build', ['xcodebuild', '-project', 'Streamory.xcodeproj', '-scheme', 'Streamory',
                '-destination', 'generic/platform=iOS Simulator', '-derivedDataPath', str(BUILD / 'DerivedData'),
                'CODE_SIGNING_ALLOWED=NO', 'build'])
            if result.returncode:
                failures.append('app-build')
    print('Logs: ' + str(BUILD))
    if failures:
        print('Failed checks: ' + ', '.join(failures))
        return 1
    print('All requested checks passed.' if args.build else 'Source checks passed; full App build was not requested.')
    return 0

if __name__ == '__main__':
    sys.exit(main())
