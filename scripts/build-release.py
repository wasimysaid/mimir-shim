#!/usr/bin/env python3
"""Build and verify one native Mimir release with its matching skill directory."""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile

TARGETS = {
    'linux-x64': 'x86_64-unknown-linux-musl',
    'windows-x64': 'x86_64-pc-windows-msvc',
    'darwin-x64': 'x86_64-apple-darwin',
    'darwin-arm64': 'aarch64-apple-darwin',
}


def version(binary):
    return subprocess.check_output([str(binary), '--version'], text=True).strip().removeprefix('mimir ').removeprefix('v')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--platform', required=True, choices=TARGETS)
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    source = args.source_dir.resolve()
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=True)
    target = TARGETS[args.platform]
    executable = 'mimir.exe' if args.platform == 'windows-x64' else 'mimir'
    archive_format = 'zip' if args.platform == 'windows-x64' else 'gztar'
    subprocess.run(['cargo', 'build', '--locked', '--release', '--target', target,
                    '-p', 'mimir-cli', '--bin', 'mimir'], cwd=source, check=True)
    binary = source / 'target' / target / 'release' / executable
    expected = args.version.removeprefix('v')
    assert version(binary) == expected, 'Built version differs from requested release'
    with tempfile.TemporaryDirectory(prefix='mimir-release-') as temporary:
        stage = Path(temporary) / 'stage'
        stage.mkdir()
        shutil.copy2(binary, stage / executable)
        skill = source / '.agents/skills/configure-mimir'
        bundled = stage / 'skills/configure-mimir'
        bundled.mkdir(parents=True)
        shutil.copy2(skill / 'SKILL.md', bundled / 'SKILL.md')
        shutil.copytree(skill / 'references', bundled / 'references')
        assert (stage / 'skills/configure-mimir/SKILL.md').is_file()
        archive = Path(shutil.make_archive(str(output / f'mimir-{args.platform}'), archive_format, stage))
        verify = Path(temporary) / 'verify'
        shutil.unpack_archive(archive, verify)
        (verify / executable).chmod(0o755)
        assert version(verify / executable) == expected, 'Archived executable failed verification'
        for reference in (stage / 'skills').rglob('*'):
            if reference.is_file():
                assert (verify / reference.relative_to(stage)).read_bytes() == reference.read_bytes()
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_name(archive.name + '.sha256').write_text(f'{digest}  {archive.name}\n')
    print(f'Verified {archive.name}: Mimir {expected}, complete configure-mimir skill')


if __name__ == '__main__':
    main()
