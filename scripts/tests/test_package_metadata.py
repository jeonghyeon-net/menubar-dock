"""손상·이름 불일치·오래된 바이너리를 실제 배포 검증 경계에서 거부한다."""
import copy
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location("package_metadata", Path(__file__).resolve().parents[1] / "package_metadata.py")
metadata = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(metadata)


class PackageMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name) / "release"
        self.directory.mkdir()
        self.manifest = dict(schemaVersion=1, version="1.2.3", buildNumber="42", commit="a" * 40,
                             architecture="arm64", minimumMacOS="14.0", signing="ad-hoc", artifacts=[])
        for suffix in ("zip", "dmg"):
            name = f"MenuBarDock-1.2.3-arm64.{suffix}"
            path = self.directory / name
            path.write_bytes(("downloaded " + suffix).encode())
            self.manifest["artifacts"].append(dict(name=name, sha256=metadata.digest(path), bytes=path.stat().st_size))
        self.write_manifest()

    def write_manifest(self):
        (self.directory / "release-manifest.json").write_text(json.dumps(self.manifest))
        (self.directory / "SHA256SUMS").write_text("".join(f"{item['sha256']}  {item['name']}\n" for item in self.manifest["artifacts"]))

    def test_downloaded_checksum_files_work_outside_the_repository(self):
        download = Path(self.temporary.name) / "Downloads"
        shutil.copytree(self.directory, download)
        self.assertEqual(metadata.verify_metadata(download)["version"], "1.2.3")
        result = subprocess.run(["/usr/bin/shasum", "-a", "256", "-c", "SHA256SUMS"], cwd=download, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_same_size_modified_download_is_rejected(self):
        (self.directory / self.manifest["artifacts"][0]["name"]).write_bytes(b"corrupted! zip")
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            metadata.verify_metadata(self.directory)

    def test_stale_version_cannot_be_renamed_in_the_manifest(self):
        self.manifest["version"] = "1.2.4"
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "파일명 불일치"):
            metadata.verify_metadata(self.directory)

    def test_unlisted_stale_download_is_rejected(self):
        (self.directory / "MenuBarDock-1.2.2-arm64.zip").write_bytes(b"old")
        with self.assertRaisesRegex(ValueError, "다른 버전"):
            metadata.verify_metadata(self.directory)

    def test_checksum_paths_cannot_depend_on_the_build_machine(self):
        checksum = self.directory / "SHA256SUMS"
        checksum.write_text(checksum.read_text().replace("  MenuBarDock", "  /tmp/MenuBarDock"))
        with self.assertRaisesRegex(ValueError, "상대 파일명"):
            metadata.verify_metadata(self.directory)

    def test_missing_metadata_is_rejected(self):
        for filename in ("SHA256SUMS", "release-manifest.json"):
            with self.subTest(filename=filename):
                self.write_manifest()
                (self.directory / filename).unlink()
                with self.assertRaisesRegex(ValueError, "메타데이터가 없습니다"):
                    metadata.verify_metadata(self.directory)

    def test_unknown_signing_architecture_and_invalid_hash_are_rejected(self):
        for key, value in (("signing", "trusted"), ("architecture", "x86_64"), ("commit", "unknown"), ("buildNumber", 42)):
            with self.subTest(key=key):
                original = self.manifest[key]
                self.manifest[key] = value
                self.write_manifest()
                with self.assertRaises(ValueError):
                    metadata.verify_metadata(self.directory)
                self.manifest[key] = original

    def test_bundle_actual_version_build_commit_must_match_requested_release(self):
        inspected = {key: value for key, value in self.manifest.items() if key not in ("schemaVersion", "artifacts")}
        for kwargs in ({"version": "1.2.4"}, {"build": "43"}, {"commit": "b" * 40}):
            with self.subTest(kwargs=kwargs):
                with self.assertRaisesRegex(ValueError, "다시 빌드"):
                    metadata.compare_bundle(inspected, **kwargs)

    def test_manifest_cannot_claim_a_different_signing_status(self):
        inspected = copy.deepcopy(self.manifest)
        inspected["signing"] = "ad-hoc"
        self.manifest["signing"] = "notarized"
        with self.assertRaisesRegex(ValueError, "signing"):
            metadata.compare_bundle(inspected, manifest=self.manifest)

    def test_notarized_release_requires_both_app_and_dmg_tickets(self):
        bundle = {key: value for key, value in self.manifest.items() if key not in ("schemaVersion", "artifacts")}
        for app_signing in ("ad-hoc", "developer-id", "notarized"):
            for dmg_ticket in (False, True):
                with self.subTest(app_signing=app_signing, dmg_ticket=dmg_ticket):
                    inspected = dict(bundle, signing=app_signing)
                    with patch.object(metadata, "inspect_bundle", return_value=inspected), patch.object(
                        metadata, "has_notarization_ticket", return_value=dmg_ticket
                    ) as validate_ticket:
                        written = metadata.write_metadata("unused.app", self.directory)
                    expected = app_signing
                    if app_signing == "notarized" and not dmg_ticket:
                        expected = "developer-id"
                    self.assertEqual(written["signing"], expected)
                    self.assertEqual(metadata.verify_metadata(self.directory)["signing"], expected)
                    if app_signing == "notarized":
                        validate_ticket.assert_called_once_with(self.directory / "MenuBarDock-1.2.3-arm64.dmg")
                    else:
                        validate_ticket.assert_not_called()

    def test_bundle_signing_must_support_the_release_notarization_claim(self):
        permitted = {
            "ad-hoc": {"ad-hoc"},
            "developer-id": {"developer-id", "notarized"},
            "notarized": {"notarized"},
        }
        for release_signing, app_states in permitted.items():
            for app_signing in ("ad-hoc", "developer-id", "notarized"):
                with self.subTest(release_signing=release_signing, app_signing=app_signing):
                    manifest = dict(self.manifest, signing=release_signing)
                    inspected = dict(manifest, signing=app_signing)
                    if app_signing in app_states:
                        metadata.compare_bundle(inspected, manifest=manifest)
                    else:
                        with self.assertRaisesRegex(ValueError, "signing"):
                            metadata.compare_bundle(inspected, manifest=manifest)

    def test_bundle_inspection_rejects_actual_intel_binary(self):
        app = Path(self.temporary.name) / "Menu Bar Dock.app"
        (app / "Contents").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(
            CFBundleShortVersionString="1.2.3", CFBundleVersion="42", MenuBarDockGitCommit="a" * 40,
            CFBundleIdentifier="net.jeonghyeon.MenuBarDock", CFBundleExecutable="MenuBarDock", LSMinimumSystemVersion="14.0")))
        with patch.object(metadata, "run", return_value=("x86_64", "")):
            with self.assertRaisesRegex(ValueError, "arm64 단일"):
                metadata.inspect_bundle(app)

    def test_old_unstamped_bundle_is_rejected_before_packaging(self):
        app = Path(self.temporary.name) / "Menu Bar Dock.app"
        (app / "Contents").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(CFBundleShortVersionString="1.2.3", CFBundleVersion="5")))
        with self.assertRaisesRegex(ValueError, "Git 커밋"):
            metadata.inspect_bundle(app)

    def test_repackaging_preserves_user_files_by_refusing_the_directory(self):
        user_file = self.directory / "my-notes.txt"
        user_file.write_text("보존해야 할 사용자 메모")
        with self.assertRaisesRegex(ValueError, "다른 자료"):
            metadata.check_output_directory(self.directory)
        self.assertEqual(user_file.read_text(), "보존해야 할 사용자 메모")

    def test_repackaging_accepts_previous_downloads_and_release_notes(self):
        (self.directory / "release-notes.md").write_text("기존 릴리즈 노트")
        metadata.check_output_directory(self.directory)

    def test_zip_path_traversal_is_rejected_before_extraction(self):
        path = Path(self.temporary.name) / "untrusted.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("Menu Bar Dock.app/../../outside", "bad")
        with self.assertRaisesRegex(ValueError, "허용하지 않는 경로"):
            metadata.verify_zip(path)

    def test_zip_external_symlink_is_rejected_before_extraction(self):
        path = Path(self.temporary.name) / "untrusted.zip"
        with zipfile.ZipFile(path, "w") as archive:
            link = zipfile.ZipInfo("Menu Bar Dock.app/Contents/escape")
            link.create_system = 3
            link.external_attr = 0o120777 << 16
            archive.writestr(link, "/tmp")
        with self.assertRaisesRegex(ValueError, "번들 밖"):
            metadata.verify_zip(path)


if __name__ == "__main__":
    unittest.main()
