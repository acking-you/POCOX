import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import release_manifest


class ReleaseManifestTests(unittest.TestCase):
    def test_signed_manifest_covers_every_release_file(self):
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            assets = work / 'assets'
            assets.mkdir()
            (assets / 'pocket-codex-app-v1.2.3-macos-arm64.dmg').write_bytes(b'dmg')
            (assets / 'SHA256SUMS').write_text('stale')
            with mock.patch.object(release_manifest, 'versions', return_value=('1.2.3', 40)):
                manifest = release_manifest.collect(assets, 'v1.2.3', 'abc')
                with self.assertRaises(ValueError):
                    release_manifest.collect(assets, 'v1.2.4', 'abc')
            self.assertEqual([a['name'] for a in manifest['assets']],
                             ['pocket-codex-app-v1.2.3-macos-arm64.dmg'])
            path = work / 'release-manifest.json'
            path.write_text(json.dumps(manifest))
            key, public = work / 'key.pem', work / 'public.pem'
            subprocess.run(['openssl', 'genpkey', '-algorithm', 'ed25519', '-out', key], check=True)
            subprocess.run(['openssl', 'pkey', '-in', key, '-pubout', '-out', public], check=True)
            release_manifest.sign(path, key)
            release_manifest.verify(path, public)
            path.write_text(json.dumps({**manifest, 'version': '9.9.9'}))
            with self.assertRaises(subprocess.CalledProcessError):
                release_manifest.verify(path, public)

    def test_checkout_versions_agree(self):
        version, build = release_manifest.versions()
        self.assertRegex(version, r'^\d+\.\d+\.\d+$')
        self.assertGreater(build, 0)


if __name__ == '__main__':
    unittest.main()
