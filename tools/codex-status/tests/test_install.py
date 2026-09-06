"""Exercise the installer in an isolated home; never launch the app or stop user processes."""
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == "Darwin" and platform.machine() == "arm64",
                     "installation/signing checks require an Apple Silicon Mac")
class InstallTests(unittest.TestCase):
    def run_install(self, root, version):
        commands = root / "commands"
        commands.mkdir(exist_ok=True)
        probe = commands / "sw_vers"
        probe.write_text(f"#!/bin/sh\nprintf '%s\\n' '{version}'\n")
        probe.chmod(0o755)
        env = dict(os.environ, PATH=f"{commands}:{os.environ.get('PATH', '')}",
                   CODEX_STATUS_TEST_HOME=str(root / "user"),
                   CODEX_STATUS_SKIP_STOP="1", CODEX_STATUS_SKIP_LAUNCH="1")
        return subprocess.run(["/bin/zsh", str(ROOT / "install.sh")], env=env,
                              text=True, capture_output=True)

    def existing_install(self, root):
        app = root / "user/Applications/Codex 状态.app"
        app.mkdir(parents=True)
        (app / "sentinel").write_text("old app")
        config = root / "user/.config/quota-widget/config.json"
        config.parent.mkdir(parents=True)
        config.write_text('{"keep": true}')
        return app, config

    def test_older_system_leaves_install_and_configuration_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, config = self.existing_install(root)
            result = self.run_install(root, "13.6.9")
            self.assertEqual(result.returncode, 4, result.stderr)
            self.assertIn("macOS 14.0", result.stdout)
            self.assertEqual((app / "sentinel").read_text(), "old app")
            self.assertEqual(config.read_text(), '{"keep": true}')
            self.assertFalse((root / "user/.Trash").exists())
            self.assertFalse((config.parent / "quota_fetch.py").exists())

    def test_supported_versions_install_signed_app_and_preserve_configuration(self):
        # Simulates version detection only; this does not prove execution on macOS 14.6.
        for version in ("14.0", "14.6", "26.0"):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                app, config = self.existing_install(root)
                result = self.run_install(root, version)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("未启动", result.stdout)
                self.assertTrue((app / "Contents/MacOS/AIQuota").is_file())
                for name in ["diagnostics.py", "quota_fetch.py", "status_engine.py", "status_logs.py", "status_proxy.py"]:
                    self.assertTrue((app / "Contents/Resources" / name).is_file())
                self.assertEqual(config.read_text(), '{"keep": true}')
                backups = list((root / "user/.Trash").glob("*/sentinel"))
                self.assertEqual(len(backups), 1)
                self.assertEqual(backups[0].read_text(), "old app")
                subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)


if __name__ == "__main__":
    unittest.main()
