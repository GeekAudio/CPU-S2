#!/usr/bin/env python3
"""Build in a temporary directory; publish only a verified application."""
import argparse
import datetime
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
VERSION = '2.5.2'


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True, cwd=ROOT)


def strip_finder_metadata(app):
    # These files were just created by this build. Clear Finder/resource-fork
    # metadata which File Provider can attach after copying into Documents.
    run('/usr/bin/xattr', '-cr', app)


def build(output):
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='cpus2-build-') as folder:
        stage = Path(folder)
        app = stage / 'CPU-S2.app'
        executable = app / 'Contents' / 'MacOS' / 'CPU-S2'
        executable.parent.mkdir(parents=True)
        resources = app / 'Contents' / 'Resources'
        resources.mkdir()
        bins = []
        helper_bins = []
        for arch in ['x86_64', 'arm64']:
            print(f'编译 {arch}', flush=True)
            obj = stage / f'probe-{arch}.o'
            binary = stage / f'CPU-S2-{arch}'
            helper_binary = stage / f'CPU-S2UpdaterHelper-{arch}'
            run('xcrun', 'swiftc', '-O', '-warnings-as-errors', '-swift-version', '5', '-parse-as-library',
                '-target', f'{arch}-apple-macos11.0', '-o', helper_binary,
                ROOT / 'Sources/UpdateInstallerCore.swift', ROOT / 'Sources/UpdaterHelper/main.swift',
                '-framework', 'Foundation')
            helper_bins.append(helper_binary)
            run('xcrun', 'clang', '-O2', '-Wall', '-Wextra', '-Werror', '-arch', arch,
                '-mmacosx-version-min=11.0', '-c', ROOT / 'Sources/Probe.c', '-o', obj)
            sources = [ROOT / 'Sources/main.swift'] + sorted(path for path in (ROOT / 'Sources').glob('*.swift') if path.name != 'main.swift')
            run('xcrun', 'swiftc', '-O', '-warnings-as-errors', '-swift-version', '5', '-target',
                f'{arch}-apple-macos11.0', '-o', binary, *sources, obj,
                '-framework', 'AppKit', '-framework', 'Foundation', '-framework', 'IOKit',
                '-framework', 'CryptoKit', '-lz')
            bins.append(binary)
        run('lipo', '-create', *bins, '-output', executable)
        helper = app / 'Contents/Helpers/CPU-S2UpdaterHelper'
        helper.parent.mkdir()
        run('lipo', '-create', *helper_bins, '-output', helper)
        run('codesign', '--force', '--sign', '-', helper)
        run('codesign', '--verify', '--strict', '--all-architectures', helper)
        shutil.copyfile(ROOT / 'Resources/AppIcon.icns', resources / 'AppIcon.icns')
        info = {
            'CFBundleName': 'CPU-S2', 'CFBundleDisplayName': 'CPU-S2',
            'CFBundleIdentifier': 'com.cpus2.CPU-S2', 'CFBundleExecutable': 'CPU-S2',
            'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': VERSION,
            'CFBundleVersion': VERSION, 'CFBundleIconFile': 'AppIcon',
            'CFBundleInfoDictionaryVersion': '6.0', 'LSMinimumSystemVersion': '11.0',
            'NSHighResolutionCapable': True, 'NSHumanReadableCopyright': 'CPU-S2 · MIT',
        }
        with (app / 'Contents/Info.plist').open('wb') as stream:
            plistlib.dump(info, stream)
        run('codesign', '--force', '--sign', '-', app)
        run('codesign', '--verify', '--deep', '--strict', '--all-architectures', app)
        # ditto avoids Finder/resource-fork metadata from synced workspace locations.
        with tempfile.TemporaryDirectory(prefix='.publish-', dir=output) as publish:
            ready = Path(publish) / app.name
            run('ditto', '--norsrc', '--noextattr', '--noacl', app, ready)
            strip_finder_metadata(ready)
            # File Provider can synthesize FinderInfo even immediately after xattr.
            # Compare every payload byte with the verified temporary app instead.
            def manifest(tree):
                return {str(path.relative_to(tree)): hashlib.sha256(path.read_bytes()).hexdigest()
                        for path in tree.rglob('*') if path.is_file()}
            if manifest(app) != manifest(ready):
                raise RuntimeError('Published application payload differs from verified build')
            destination = output / app.name
            if destination.exists():
                backup = ROOT / '备份' / f'CPU-S2-before-{VERSION}-{datetime.datetime.now():%Y%m%d-%H%M%S}-{uuid.uuid4().hex[:6]}.app'
                backup.parent.mkdir(exist_ok=True)
                os.replace(destination, backup)
                print(f'原应用已归档：{backup}')
            os.replace(ready, destination)
            # Verify payload bytes again: File Provider metadata is outside our control.
            if manifest(app) != manifest(destination):
                raise RuntimeError('Final application payload differs from verified build')
        for binary in bins:
            shutil.copyfile(binary, output / binary.name)
        run('lipo', '-archs', destination / 'Contents/MacOS/CPU-S2')
        print(f'构建完成：{destination}')
        return destination


def package(output, skip_build=False):
    app = output / "CPU-S2.app" if skip_build else build(output)
    destination = output / f'CPU-S2-v{VERSION}.dmg'
    zip_destination = output / f'CPU-S2-v{VERSION}.zip'
    with tempfile.TemporaryDirectory(prefix='cpus2-package-') as folder:
        stage = Path(folder)
        contents = stage / 'contents'
        contents.mkdir()
        run('ditto', '--norsrc', '--noextattr', '--noacl', app, contents / app.name)
        with (contents / app.name / 'Contents/Info.plist').open('rb') as stream:
            if plistlib.load(stream).get('CFBundleShortVersionString') != VERSION:
                raise RuntimeError('Package app version differs from release version; rebuild first')
        strip_finder_metadata(contents / app.name)
        run('codesign', '--verify', '--deep', '--strict', '--all-architectures', contents / app.name)
        helper = contents / app.name / 'Contents/Helpers/CPU-S2UpdaterHelper'
        if not helper.is_file():
            raise RuntimeError('Application is missing its automatic update helper')
        archive = stage / zip_destination.name
        run('ditto', '-c', '-k', '--keepParent', '--norsrc', '--noextattr', '--noacl', contents / app.name, archive)
        shutil.copyfile(ROOT / '使用说明.txt', contents / '使用说明.txt')
        (contents / 'Applications').symlink_to('/Applications')
        image = stage / destination.name
        run('hdiutil', 'create', '-volname', f'CPU-S2 v{VERSION}', '-srcfolder', contents,
            '-format', 'UDZO', image)
        run('hdiutil', 'verify', image)
        # Copy to a sibling temporary file before the atomic final rename.
        for source, target in [(image, destination), (archive, zip_destination)]:
            with tempfile.NamedTemporaryFile(prefix='.release-', dir=output, delete=False) as stream:
                temporary = Path(stream.name)
            try:
                shutil.copyfile(source, temporary)
                os.replace(temporary, target)
            finally:
                temporary.unlink(missing_ok=True)
        sums = ''.join(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n'
                       for path in [destination, zip_destination])
        with tempfile.NamedTemporaryFile(mode='w', prefix='.checksums-', dir=output, delete=False) as stream:
            stream.write(sums)
            checksum_file = Path(stream.name)
        os.replace(checksum_file, output / 'SHA256SUMS.txt')
        print(f'打包完成：{destination}')
        print(f'自动更新 ZIP：{zip_destination}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--package', action='store_true')
    parser.add_argument('--output', type=Path, default=ROOT / 'build')
    parser.add_argument('--skip-build', action='store_true', help='Package the current verified version without recompiling')
    arguments = parser.parse_args()
    if arguments.package:
        package(arguments.output.resolve(), skip_build=arguments.skip_build)
    else:
        if arguments.skip_build:
            parser.error('--skip-build requires --package')
        build(arguments.output.resolve())
