#!/usr/bin/env python3
"""Write, sign or verify a release's update manifest.

The app's updater downloads `release-manifest.json` and its signature
`release-manifest.json.sig` from the newest release and installs nothing the
signature does not cover, and no file whose size or SHA-256 differs from what
the manifest lists (`crates/pocket-codex-bridge/src/engine/updates`).

    collect: release_manifest.py collect <assets-dir> <tag> <commit>
    sign:    release_manifest.py sign release-manifest.json --key private.pem
    verify:  release_manifest.py verify release-manifest.json --public public.pem

Signing needs OpenSSL 3 (`pkeyutl -rawin`). The signature file holds the
base64 of the 64-byte Ed25519 signature over the manifest's exact bytes.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = 'release-manifest.json'
SKIP = {MANIFEST, MANIFEST + '.sig', 'SHA256SUMS'}


def versions():
    """The app version and build of this checkout, which must agree."""
    pubspec = re.search(r'(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
                        (ROOT / 'apps/flutter/pubspec.yaml').read_text())
    cargo = re.search(r'(?ms)^\[workspace\.package\].*?^version\s*=\s*"([^"]+)"',
                      (ROOT / 'Cargo.toml').read_text())
    if pubspec is None or cargo is None:
        raise ValueError('pubspec.yaml or Cargo.toml has no version')
    if pubspec[1] != cargo[1]:
        raise ValueError(f'pubspec.yaml {pubspec[1]} and Cargo.toml {cargo[1]} disagree')
    return pubspec[1], int(pubspec[2])


def digest(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def collect(assets, tag, commit):
    """The manifest of every file in `assets`, for the release tagged `tag`."""
    version, build = versions()
    # A version tag must be this version; a manual run on a branch (a draft)
    # carries the branch name instead.
    if re.fullmatch(r'v\d+\.\d+\.\d+', tag) and tag != f'v{version}':
        raise ValueError(f'tag {tag} does not match version {version}')
    files = sorted(p for p in assets.iterdir() if p.is_file() and p.name not in SKIP)
    for file in files:
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', file.name):
            raise ValueError(f'{file.name} is not a plain file name')
    if not files:
        raise ValueError('the release has no files')
    return {
        'version': version,
        'build': build,
        'tag': tag,
        'commit': commit,
        'assets': [{'name': f.name, 'size': f.stat().st_size, 'sha256': digest(f)} for f in files],
    }


def sign(manifest, key):
    with tempfile.TemporaryDirectory() as work:
        raw = Path(work) / 'signature'
        subprocess.run(['openssl', 'pkeyutl', '-sign', '-rawin', '-inkey', str(key),
                        '-in', str(manifest), '-out', str(raw)], check=True)
        signature = raw.read_bytes()
    if len(signature) != 64:
        raise ValueError('the key did not produce an Ed25519 signature')
    output = manifest.with_name(manifest.name + '.sig')
    output.write_text(base64.b64encode(signature).decode() + '\n')
    return output


def verify(manifest, public_key):
    signature = manifest.with_name(manifest.name + '.sig')
    with tempfile.TemporaryDirectory() as work:
        raw = Path(work) / 'signature'
        raw.write_bytes(base64.b64decode(signature.read_text().strip()))
        subprocess.run(['openssl', 'pkeyutl', '-verify', '-rawin', '-pubin', '-inkey', str(public_key),
                        '-in', str(manifest), '-sigfile', str(raw)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    gather = commands.add_parser('collect')
    gather.add_argument('assets', type=Path)
    gather.add_argument('tag')
    gather.add_argument('commit')
    gather.add_argument('--out', type=Path, default=Path(MANIFEST))
    signing = commands.add_parser('sign')
    signing.add_argument('manifest', type=Path)
    signing.add_argument('--key', type=Path, required=True)
    checking = commands.add_parser('verify')
    checking.add_argument('manifest', type=Path)
    checking.add_argument('--public', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'collect':
        manifest = collect(args.assets, args.tag, args.commit)
        args.out.write_text(json.dumps(manifest, indent=2) + '\n')
        (args.out.parent / 'SHA256SUMS').write_text(
            ''.join(f"{a['sha256']}  {a['name']}\n" for a in manifest['assets']))
        print(args.out)
    elif args.command == 'sign':
        print(sign(args.manifest, args.key))
    else:
        verify(args.manifest, args.public)


if __name__ == '__main__':
    main()
