"""Exercise the CLI install contract without network access or user state."""
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest


INSTALLER = Path(__file__).with_name('install.sh')


@unittest.skipIf(os.name == 'nt', 'POSIX installer')
class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.archive = self.root / 'cli.tar.gz'
        curl = self.bin / 'curl'
        curl.write_text('#!/bin/sh\ncp "$TEST_ARCHIVE" "$4"\n')
        curl.chmod(0o755)
        self.destination = self.root / 'install'
        self.env = {
            **os.environ,
            'PATH': f'{self.bin}:/usr/bin:/bin',
            'POCOX_BIN_DIR': str(self.destination),
            'POCOX_VERSION': 'v9.0.0',
            'POCOX_NO_MODIFY_PATH': '1',
            'TEST_ARCHIVE': str(self.archive),
        }

    def package(self, name='pocox'):
        body = b'#!/bin/sh\necho "pocox 9.0.0"\n'
        with tarfile.open(self.archive, 'w:gz') as archive:
            info = tarfile.TarInfo(f'pocox-cli-v9.0.0-test/{name}')
            info.size = len(body)
            info.mode = 0o755
            archive.addfile(info, io.BytesIO(body))

    def install(self):
        return subprocess.run(['sh', str(INSTALLER)], env=self.env,
                              capture_output=True, text=True)

    def test_fresh_install_and_update_keep_only_the_cli(self):
        self.package()
        for _ in range(2):
            result = self.install()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(subprocess.check_output(
                [str(self.destination / 'pocox'), '--version'], text=True).strip(),
                'pocox 9.0.0')
        self.assertEqual([p.name for p in self.destination.iterdir()], ['pocox'])

    def test_desktop_launcher_is_neither_run_nor_replaced(self):
        desktop = self.bin / 'pocox-app'
        desktop.write_text('#!/bin/sh\nexit 93\n')
        desktop.chmod(0o755)
        self.package()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(desktop.read_text(), '#!/bin/sh\nexit 93\n')

    def test_archive_without_cli_does_not_replace_an_install(self):
        self.destination.mkdir()
        installed = self.destination / 'pocox'
        installed.write_text('existing installation')
        self.package('unrelated')
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual(installed.read_text(), 'existing installation')


if __name__ == '__main__':
    unittest.main()
