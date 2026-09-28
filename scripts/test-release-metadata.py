#!/usr/bin/env python3
"""실제 임시 Git 이력으로 버전·설명 생성 경계를 검증한다."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parent


class ReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="menu bar release test ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "repository with spaces"
        self.root.mkdir()
        (self.root / "scripts").mkdir()
        for name in ("version.sh", "release-notes.sh", "release_metadata.py", "package_metadata.py"):
            shutil.copy2(SOURCE / name, self.root / "scripts" / name)
        (self.root / "Config").mkdir()
        self.write_seed("1.0.3")
        self.environment = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        self.git("-c", "init.templateDir=", "init", "-q", "-b", "main")
        self.git("config", "user.name", "Release test")
        self.git("config", "user.email", "release-test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "core.hooksPath", os.devnull)
        self.first = self.commit("초기 앱 제공")

    def run_command(self, arguments):
        return subprocess.run(arguments, cwd=self.root, env=self.environment,
                              text=True, encoding="utf-8", stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def git(self, *arguments):
        result = self.run_command(["git", *arguments])
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def commit(self, subject):
        self.git("add", ".")
        self.git("commit", "-q", "--allow-empty", "-m", subject)
        return self.git("rev-parse", "HEAD")

    def write_seed(self, value):
        with (self.root / "Config/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleShortVersionString": value, "LSMinimumSystemVersion": "14.0"}, stream)

    def version(self, *arguments):
        result = self.run_command(["bash", "scripts/version.sh", *arguments])
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def failure(self, script, *arguments):
        result = self.run_command(["bash", "scripts/" + script, *arguments])
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout, "", "실패 시 부분적인 릴리스 설명을 출력했습니다.")
        return result.stderr

    def distribution(self, version="1.0.3", target=None, signing="ad-hoc"):
        directory = self.root / "dist files with spaces"
        directory.mkdir(exist_ok=True)
        artifacts = []
        for extension in ("zip", "dmg"):
            name = "MenuBarDock-" + version + "-arm64." + extension
            data = ("독립 검증용 배포 파일 " + extension).encode("utf-8")
            (directory / name).write_bytes(data)
            artifacts.append({"name": name, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
        target = target or self.git("rev-parse", "HEAD")
        manifest = {
            "schemaVersion": 1,
            "version": version,
            "buildNumber": self.version("--build-number", target),
            "commit": target,
            "architecture": "arm64",
            "minimumMacOS": "14.0",
            "signing": signing,
            "artifacts": artifacts,
        }
        self.save_manifest(directory, manifest)
        (directory / "SHA256SUMS").write_text("".join(item["sha256"] + "  " + item["name"] + "\n" for item in artifacts), encoding="utf-8")
        return directory, manifest

    def save_manifest(self, directory, manifest):
        (directory / "release-manifest.json").write_text(json.dumps(manifest), encoding="utf-8")

    def notes(self, version="1.0.3", target="HEAD", signing="ad-hoc"):
        directory, manifest = self.distribution(version, self.git("rev-parse", target), signing)
        result = self.run_command(["bash", "scripts/release-notes.sh", version, target, str(directory)])
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout, manifest

    def test_seed_is_committed_not_working_tree_value(self):
        self.write_seed("8.8.8")
        self.assertEqual(self.version(), "1.0.3")
        self.assertEqual(self.version("--build-number"), "1")

    def test_exact_annotated_tag_is_used(self):
        self.git("tag", "-a", "v2.3.4", "-m", "검증한 버전")
        self.assertEqual(self.version(), "2.3.4")
        self.commit("수정")
        self.assertEqual(self.version(), "2.3.5")
        self.assertEqual(self.version("v2.3.4"), "2.3.4")

    def test_highest_reachable_version_wins_over_creation_order(self):
        self.git("tag", "v1.2.9")
        second = self.commit("두 번째")
        self.git("tag", "v1.2.10")
        self.commit("세 번째")
        self.git("tag", "v1.2.2")
        self.commit("네 번째")
        self.assertEqual(self.version(), "1.2.11")
        self.assertEqual(self.version(second), "1.2.10")

    def test_non_stable_or_malformed_tags_are_ignored(self):
        for tag in ("v1.03.8", "v1.2.3-beta.1", "v1.2.3+build", "release-8.0.0", "v1.2", "v1.2.bad"):
            self.git("tag", tag)
        self.assertEqual(self.version(), "1.0.3")

    def test_ambiguous_exact_versions_are_rejected(self):
        self.git("tag", "v1.0.3")
        self.git("tag", "v1.0.4")
        self.assertIn("여러 릴리스 버전", self.failure("version.sh"))

    def test_patch_overflow_is_rejected(self):
        self.git("tag", "v1.2.2147483647")
        self.commit("다음 패치")
        self.assertIn("패치 버전", self.failure("version.sh"))

    def test_oversized_version_tag_is_rejected(self):
        self.git("tag", "v99999999999999999999999999.0.0")
        self.assertIn("허용 범위", self.failure("version.sh"))

    def test_other_branch_and_future_tags_do_not_change_historical_version(self):
        self.git("checkout", "-q", "-b", "test-fixture-side")
        self.commit("옆 계보")
        self.git("tag", "v9.0.0")
        self.git("checkout", "-q", "main")
        self.assertEqual(self.version(), "1.0.3")
        self.commit("현재 계보")
        self.git("tag", "v1.0.3")
        self.assertEqual(self.version(self.first), "1.0.3")

    def test_first_parent_excludes_merged_branch_tags_and_count(self):
        self.git("tag", "v1.0.3")
        self.git("checkout", "-q", "-b", "test-fixture-side")
        self.commit("옆 계보")
        self.git("tag", "v9.0.0")
        self.git("checkout", "-q", "main")
        self.commit("main 수정")
        self.git("merge", "--no-ff", "-m", "병합", "test-fixture-side")
        self.assertEqual(self.version(), "1.0.4")
        self.assertEqual(self.version("--build-number"), "3")

    def test_shallow_history_is_rejected(self):
        (self.root / ".git/shallow").write_text(self.first + "\n", encoding="ascii")
        self.assertIn("전체 Git 이력", self.failure("version.sh"))

    def test_invalid_initial_version_is_rejected(self):
        self.write_seed("01.0.3")
        self.commit("잘못된 초기 버전")
        self.assertIn("형식", self.failure("version.sh"))

    def test_unknown_target_is_rejected(self):
        self.failure("version.sh", "does-not-exist")
        self.failure("version.sh", "--", "--help")

    def test_first_release_contains_only_target_history(self):
        self.git("tag", "v1.0.3")
        self.commit("다음 버전에서만 제공")
        notes, manifest = self.notes(target=self.first)
        self.assertIn("초기 앱 제공", notes)
        self.assertNotIn("다음 버전에서만 제공", notes)
        self.assertIn(self.first, notes)
        self.assertIn(manifest["artifacts"][0]["sha256"], notes)
        self.assertNotIn("이전 버전과 비교", notes)

    def test_notes_range_starts_after_previous_release_and_ends_at_target(self):
        self.git("tag", "v1.0.3")
        second = self.commit("아이콘 간격 수정")
        self.git("tag", "v1.0.4")
        self.commit("다음 릴리스")
        notes, _ = self.notes("1.0.4", second)
        self.assertIn("아이콘 간격 수정", notes)
        self.assertNotIn("초기 앱 제공", notes)
        self.assertNotIn("다음 릴리스", notes)
        self.assertIn("compare/v1.0.3..." + second, notes)

    def test_commit_subject_is_displayed_as_text_not_markdown(self):
        self.git("tag", "v1.0.3")
        self.commit("fix: **굵게** ~~삭제~~ `코드` <img src=x> @someone [링크](https://x) | & \\x")
        notes, _ = self.notes("1.0.4")
        self.assertIn("&#42;&#42;굵게&#42;&#42;", notes)
        self.assertIn("&#126;&#126;삭제&#126;&#126;", notes)
        self.assertIn("&#64;someone", notes)
        self.assertIn("&#60;img src&#61;x&#62;", notes)
        self.assertIn("&#96;코드&#96;", notes)
        self.assertNotIn("**굵게**", notes)
        self.assertNotIn("<img", notes)

    def test_signing_states_are_explicit(self):
        for state, expected in (("ad-hoc", "Ad-hoc 서명 · Apple 공증 없음"),
                                ("developer-id", "앱 Developer ID Application 서명 · 배포 파일 전체 공증 미완료"),
                                ("notarized", "Apple 공증 및 티켓 부착 완료")):
            with self.subTest(state=state):
                notes, _ = self.notes(signing=state)
                self.assertIn(expected, notes)

    def test_manifest_target_fields_must_match(self):
        for field, value in (("version", "1.0.8"), ("commit", "0" * 40), ("buildNumber", "999")):
            with self.subTest(field=field):
                directory, manifest = self.distribution()
                manifest[field] = value
                self.save_manifest(directory, manifest)
                self.failure("release-notes.sh", "1.0.3", "HEAD", str(directory))

    def test_modified_artifact_never_emits_partial_notes(self):
        directory, manifest = self.distribution()
        (directory / manifest["artifacts"][0]["name"]).write_text("변조", encoding="utf-8")
        self.failure("release-notes.sh", "1.0.3", "HEAD", str(directory))

    def test_bad_checksum_file_is_rejected(self):
        directory, _ = self.distribution()
        (directory / "SHA256SUMS").write_text("잘못된 체크섬\n", encoding="utf-8")
        self.failure("release-notes.sh", "1.0.3", "HEAD", str(directory))

    def test_missing_manifest_is_rejected(self):
        directory, _ = self.distribution()
        (directory / "release-manifest.json").unlink()
        self.failure("release-notes.sh", "1.0.3", "HEAD", str(directory))

    def test_unknown_signing_status_is_rejected(self):
        directory, manifest = self.distribution()
        manifest["signing"] = "probably-signed"
        self.save_manifest(directory, manifest)
        self.failure("release-notes.sh", "1.0.3", "HEAD", str(directory))

    def test_requested_version_must_match_target(self):
        directory, _ = self.distribution()
        self.failure("release-notes.sh", "1.0.4", "HEAD", str(directory))
        self.failure("release-notes.sh", "1.00.3", "HEAD", str(directory))

    def test_existing_release_tag_cannot_point_at_another_commit(self):
        self.git("checkout", "-q", "-b", "test-fixture-side")
        self.commit("다른 계보의 릴리스")
        self.git("tag", "v1.0.3")
        self.git("checkout", "-q", "main")
        directory, _ = self.distribution()
        self.assertIn("태그가 대상 커밋과 다릅니다", self.failure("release-notes.sh", "1.0.3", "HEAD", str(directory)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
