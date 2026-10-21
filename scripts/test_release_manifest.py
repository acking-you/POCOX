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
            (assets / 'pocox-app-v1.2.3-macos-arm64.dmg').write_bytes(b'dmg')
            (assets / 'SHA256SUMS').write_text('stale')
            with mock.patch.object(release_manifest, 'versions', return_value=('1.2.3', 40)):
                manifest = release_manifest.collect(assets, 'v1.2.3', 'abc')
                with self.assertRaises(ValueError):
                    release_manifest.collect(assets, 'v1.2.4', 'abc')
            self.assertEqual([a['name'] for a in manifest['assets']],
                             ['pocox-app-v1.2.3-macos-arm64.dmg'])
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

    def test_refresh_refuses_a_different_release_or_mixed_naming(self):
        with tempfile.TemporaryDirectory() as work:
            path = Path(work) / 'manifest.json'
            data = {'tag': 'v1.2.3', 'assets': [{'name': 'pocox-app-v1.2.3-macos-arm64.dmg'}]}
            path.write_text(json.dumps(data))
            release_manifest.require_baseline(path, 'v1.2.3')
            with self.assertRaises(ValueError):
                release_manifest.require_baseline(path, 'v1.2.4')
            data['assets'].append({'name': 'legacy-app-v1.2.3-linux.zip'})
            path.write_text(json.dumps(data))
            with self.assertRaises(ValueError):
                release_manifest.require_baseline(path, 'v1.2.3')
            self.assertEqual(json.loads(path.read_text()), data)

    def test_repackaging_keeps_other_assets_and_source_identity(self):
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            image = work / 'pocox-app-v1.2.3-linux-x86_64.AppImage'
            image.write_bytes(b'old')
            other = work / 'pocox-app-v1.2.3-macos-arm64.dmg'
            other.write_bytes(b'unchanged')
            with mock.patch.object(release_manifest, 'versions', return_value=('1.2.3', 40)):
                original = release_manifest.collect(work, 'v1.2.3', 'source-commit')
            path = work / 'release-manifest.json'
            path.write_text(json.dumps(original))
            image.write_bytes(b'new dependencies')
            release_manifest.refresh_asset(path, image)
            updated = json.loads(path.read_text())
            self.assertEqual(updated['assets'][0]['sha256'], release_manifest.digest(image))
            self.assertEqual(updated['assets'][0]['size'], image.stat().st_size)
            self.assertEqual(updated['assets'][1], original['assets'][1])
            self.assertEqual({k: v for k, v in updated.items() if k != 'assets'},
                             {k: v for k, v in original.items() if k != 'assets'})
            with self.assertRaises(ValueError):
                release_manifest.refresh_asset(path, work / 'unlisted.AppImage')


if __name__ == '__main__':
    unittest.main()
