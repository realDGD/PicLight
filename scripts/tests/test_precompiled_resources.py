"""Cache policy and packaging preflight; no Swift build or Apple compiler needed."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]


class PrecompiledResourcesTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.cache = self.root / "Resources/Precompiled"
        self.write("PicViewMac/Shaders/ImageShaders.metal", b"shader source")
        self.write("Resources/AppIcon/PicLight.icon/icon.json", b"icon document")
        self.write("Resources/AppIcon/PicLight.icon/Assets/foreground.png", b"icon artwork")
        self.write("Resources/AppIcon/PicLight.icns", b"classic icon")
        self.write("Resources/Precompiled/Assets.car", b"compiled icon")
        self.write("Resources/Precompiled/default.metallib", b"compiled shader")
        self.manifest = {
            "schema": 1,
            "resources": {
                "icon": {
                    "configuration": {"recipe": 1, "platform": "macosx", "target_device": "mac",
                                      "minimum_system_version": "14.0", "app_icon": "PicLight"},
                    "inputs": self.hashes("Resources/AppIcon"),
                    "artifact": {"path": "Assets.car", "sha256": self.digest(b"compiled icon")},
                },
                "metal": {
                    "configuration": {"recipe": 1, "platform": "macosx",
                                      "target": "air64-apple-macos14.0"},
                    "inputs": self.hashes("PicViewMac/Shaders"),
                    "artifact": {"path": "default.metallib", "sha256": self.digest(b"compiled shader")},
                },
            },
        }
        self.save_manifest()
        self.environment = dict(os.environ, PATH="/nonexistent", MINIMUM_SYSTEM_VERSION="14.0")

    @staticmethod
    def digest(data):
        return hashlib.sha256(data).hexdigest()

    def hashes(self, relative):
        return {p.relative_to(self.root).as_posix(): self.digest(p.read_bytes())
                for p in (self.root / relative).rglob("*") if p.is_file()}

    def write(self, relative, data):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def save_manifest(self):
        (self.cache / "manifest.json").write_text(json.dumps(self.manifest))

    def run_helper(self, command="check", *arguments):
        return subprocess.run([sys.executable, str(SCRIPTS / "precompile-resources.py"), command,
                               "--root", str(self.root), *arguments], env=self.environment,
                              capture_output=True, text=True, timeout=10)

    def assert_rejected(self, result):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("update", result.stderr)

    def test_matching_resources_need_no_compiler(self):
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_shader_artwork_and_classic_icon_changes_reject_stale_cache(self):
        for relative in ("PicViewMac/Shaders/ImageShaders.metal",
                         "Resources/AppIcon/PicLight.icon/Assets/foreground.png",
                         "Resources/AppIcon/PicLight.icns"):
            with self.subTest(relative=relative):
                path = self.root / relative
                original = path.read_bytes()
                path.write_bytes(original + b" changed")
                self.assert_rejected(self.run_helper())
                path.write_bytes(original)

    def test_added_source_and_deployment_change_reject_cache(self):
        self.write("Resources/AppIcon/PicLight.icon/Assets/extra.svg", b"new layer")
        self.assert_rejected(self.run_helper())
        (self.root / "Resources/AppIcon/PicLight.icon/Assets/extra.svg").unlink()
        self.assert_rejected(self.run_helper("check", "--minimum-system-version", "15.0"))

    def test_missing_or_corrupt_artifact_and_manifest_reject_cache(self):
        library = self.cache / "default.metallib"
        library.write_bytes(b"corrupted")
        self.assert_rejected(self.run_helper())
        library.unlink()
        self.assert_rejected(self.run_helper())
        library.write_bytes(b"compiled shader")
        (self.cache / "manifest.json").write_text("{broken")
        self.assert_rejected(self.run_helper())

    def test_unchanged_update_preserves_files_without_compilers(self):
        before = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.cache.iterdir()}
        result = self.run_helper("update")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(before, {p.name: (p.read_bytes(), p.stat().st_mtime_ns)
                                  for p in self.cache.iterdir()})

    def test_failed_refresh_keeps_previous_resources(self):
        before = {p.name: p.read_bytes() for p in self.cache.iterdir()}
        self.write("PicViewMac/Shaders/ImageShaders.metal", b"new shader")
        result = self.run_helper("update")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.cache.iterdir()})

    def packaging_environment(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copy2(SCRIPTS / "build-release.sh", scripts)
        shutil.copy2(SCRIPTS / "precompile-resources.py", scripts)
        tools = self.root / "tools"
        tools.mkdir()
        (tools / "python3").symlink_to(sys.executable)
        (tools / "dirname").symlink_to("/usr/bin/dirname")
        swift = tools / "swift"
        swift.write_text('#!/bin/bash\ntouch "$PWD/swift-was-called"\nexit 91\n')
        swift.chmod(0o755)
        self.write("dist/PicLight.app/preserve", b"previous app")
        return dict(self.environment, PATH=str(tools) + ":/usr/bin:/bin")

    def test_stale_resources_stop_packaging_before_swift_and_preserve_app(self):
        # The old script called Swift before discovering unavailable resources.
        environment = self.packaging_environment()
        self.write("PicViewMac/Shaders/ImageShaders.metal", b"changed shader")
        result = subprocess.run(["/bin/bash", str(self.root / "scripts/build-release.sh")],
                                env=environment, capture_output=True, text=True, timeout=10)
        self.assert_rejected(result)
        self.assertFalse((self.root / "swift-was-called").exists())
        self.assertEqual((self.root / "dist/PicLight.app/preserve").read_bytes(), b"previous app")

    def test_signing_failure_preserves_app_and_removes_staging(self):
        environment = self.packaging_environment()
        tools = self.root / "tools"
        (tools / "swift").write_text('#!/bin/bash\nif [[ "$*" == *--show-bin-path* ]]; then\n'
                                     '  printf "%s\\n" "$FAKE_BIN_DIR"\nfi\n')
        (tools / "codesign").write_text('#!/bin/bash\nexit 92\n')
        (tools / "codesign").chmod(0o755)
        binary_dir = self.root / "binaries"
        self.write("binaries/PicViewMac", b"executable")
        (binary_dir / "PicViewMac").chmod(0o755)
        (binary_dir / "PicViewMac_PicViewMac.bundle/Contents/Resources").mkdir(parents=True)
        environment["FAKE_BIN_DIR"] = str(binary_dir)
        result = subprocess.run(["/bin/bash", str(self.root / "scripts/build-release.sh")],
                                env=environment, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 92, result.stdout + result.stderr)
        self.assertEqual((self.root / "dist/PicLight.app/preserve").read_bytes(), b"previous app")
        self.assertEqual(list((self.root / "dist").iterdir()), [self.root / "dist/PicLight.app"])

    def test_packaging_defaults_to_clt_and_honors_explicit_override(self):
        environment = self.packaging_environment()
        (self.root / "tools/swift").write_text('#!/bin/bash\nprintf "%s" "$DEVELOPER_DIR" '
                                              '> "$PWD/selected-developer"\nexit 91\n')
        for override, expected in ((None, "/Library/Developer/CommandLineTools"),
                                   ("/explicit/developer", "/explicit/developer")):
            with self.subTest(override=override):
                if override is None:
                    environment.pop("DEVELOPER_DIR", None)
                else:
                    environment["DEVELOPER_DIR"] = override
                result = subprocess.run(["/bin/bash", str(self.root / "scripts/build-release.sh")],
                                        env=environment, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 91, result.stdout + result.stderr)
                self.assertEqual((self.root / "selected-developer").read_text(), expected)

    def test_homebrew_can_disable_nested_swiftpm_sandbox_for_both_build_calls(self):
        environment = self.packaging_environment()
        tools = self.root / "tools"
        (tools / "swift").write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$PWD/swift-arguments"\n'
                                     'if [[ "$*" == *--show-bin-path* ]]; then\n'
                                     '  printf "%s\\n" "$FAKE_BIN_DIR"\nfi\n')
        (tools / "codesign").write_text('#!/bin/bash\nexit 92\n')
        (tools / "codesign").chmod(0o755)
        self.write("binaries/PicViewMac", b"executable")
        binary_dir = self.root / "binaries"
        (binary_dir / "PicViewMac").chmod(0o755)
        (binary_dir / "PicViewMac_PicViewMac.bundle/Contents/Resources").mkdir(parents=True)
        environment.update(FAKE_BIN_DIR=str(binary_dir), PICLIGHT_SWIFTPM_DISABLE_SANDBOX="1")
        result = subprocess.run(["/bin/bash", str(self.root / "scripts/build-release.sh")],
                                env=environment, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 92, result.stdout + result.stderr)
        calls = (self.root / "swift-arguments").read_text().splitlines()
        self.assertEqual(len(calls), 2)
        self.assertTrue(all("--disable-sandbox" in call.split() for call in calls), calls)


if __name__ == "__main__":
    unittest.main()
