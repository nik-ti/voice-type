"""Checks packaging failure behavior without compiling models or replacing the real app.
Run with python3 -m unittest discover -s Tests/PackagingTests.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class PackagingTests(unittest.TestCase):
    def test_failed_build_preserves_existing_app_from_any_working_directory(self):
        script = Path(__file__).resolve().parents[2] / "package_app.sh"
        with tempfile.TemporaryDirectory(prefix="voice type packaging ") as temporary:
            root = Path(temporary)
            shutil.copy2(script, root / "package_app.sh")
            old = root / "VoiceType.app" / "Contents" / "MacOS"
            old.mkdir(parents=True)
            (old / "VoiceType").write_text("working original")
            binaries = root / "fake-bin"
            binaries.mkdir()
            swift = binaries / "swift"
            swift.write_text("#!/bin/sh\nexit 29\n")
            swift.chmod(0o755)
            environment = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}", VOICETYPE_INSTALL_DIR=str(root))
            elsewhere = root / "elsewhere"
            elsewhere.mkdir()
            for working_directory in (root, elsewhere):
                result = subprocess.run(["bash", str(root / "package_app.sh")], cwd=working_directory,
                                        env=environment, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((old / "VoiceType").read_text(), "working original")
                self.assertFalse((root / ".build" / "package.lock").exists())
                self.assertFalse((elsewhere / ".build").exists())
