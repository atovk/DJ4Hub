#!/usr/bin/env python3
"""Exercise upgrades in temporary directories without starting a device service."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "The installer targets macOS")
class InstallTests(unittest.TestCase):
    def setUp(self):
        self.sandbox = tempfile.TemporaryDirectory(prefix="dj4hub-install-test-")
        self.addCleanup(self.sandbox.cleanup)
        root = Path(self.sandbox.name)
        self.package = root / "package"
        self.installed = root / "installed"
        self.command = root / "commands" / "dj4ghub"
        for directory in (self.package / "bin", self.package / "lib", self.command.parent):
            directory.mkdir(parents=True)
        source = Path(__file__).resolve().parents[1] / "packaging" / "install"
        shutil.copy2(source, self.package / "install")
        # Native, inert fixtures satisfy the architecture check; they never run.
        for name in ("bin/dj4ghub-macos", "lib/libusb-1.0.0.dylib"):
            shutil.copy("/usr/bin/true", self.package / name)
        self.launcher = "#!/bin/sh\nexit 0\n"
        (self.package / "dj4ghub").write_text(self.launcher)
        (self.package / "dj4ghub").chmod(0o755)
        self.environment = {
            **os.environ,
            "DJ4GHUB_INSTALL_NO_SUDO": "1",
            "DJ4GHUB_INSTALL_DIR": str(self.installed),
            "DJ4GHUB_COMMAND_PATH": str(self.command),
        }

    def run_installer(self):
        return subprocess.run(
            ["sh", str(self.package / "install")],
            env=self.environment, capture_output=True, text=True, timeout=20,
        )

    def old_install(self, stop_status):
        self.installed.mkdir()
        self.old_launcher = f'#!/bin/sh\n[ "$1" = stop ] || exit 99\nexit {stop_status}\n'
        (self.installed / "dj4ghub").write_text(self.old_launcher)
        (self.installed / "dj4ghub").chmod(0o755)
        self.command.symlink_to(self.installed / "dj4ghub")

    def assert_installed(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.command.read_text(), self.launcher)
        self.assertTrue((self.installed / "bin/dj4ghub-macos").is_file())

    def test_fresh_install(self):
        self.assert_installed(self.run_installer())

    def test_upgrade_after_successful_stop(self):
        self.old_install(0)
        self.assert_installed(self.run_installer())

    def test_failed_stop_preserves_existing_install(self):
        self.old_install(1)
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.command.read_text(), self.old_launcher)
        self.assertFalse((self.installed / "bin").exists())


if __name__ == "__main__":
    unittest.main()
