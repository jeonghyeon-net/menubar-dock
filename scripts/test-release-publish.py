#!/usr/bin/env python3
"""임시 파일과 subprocess 대역만으로 릴리스 게시의 실패 경계를 검사한다."""

import contextlib
import copy
import fcntl
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("release_under_test", Path(__file__).with_name("release.py"))
RELEASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELEASE)

COMMIT = "a" * 40
OTHER_COMMIT = "b" * 40
VERSION = "1.2.3"
TAG = f"v{VERSION}"
NAMES = [f"MenuBarDock-{VERSION}-arm64.zip", f"MenuBarDock-{VERSION}-arm64.dmg",
         "SHA256SUMS", "release-manifest.json"]


class FakeCommands:
    """명령 경계를 닫아 예상하지 못한 subprocess가 실제 Git·GitHub로 나가지 않게 한다."""

    def __init__(self, root):
        self.root = root
        self.directory = root / "dist" / "releases" / VERSION
        self.calls = []
        self.environments = []
        self.branch = "main"
        self.status = ""
        self.origin = f"https://github.com/{RELEASE.REPOSITORY}.git"
        self.push_origin = self.origin
        self.commit = COMMIT
        self.remote_commit = COMMIT
        self.local_tag = None
        self.remote_tag = None
        self.release = None
        self.release_pages_before_target = []
        self.remote_files = {}
        self.failures = {}
        self.lookup_error = None
        self.corrupt_download = None
        self.publish_on_readback = False
        self.replace_after_readback = False
        self.full_readback_finished = False
        self.change_commit_after_checks = False
        self.manifest_commit = COMMIT
        self.manifest_version = VERSION
        self.visibility_after_write = {}
        self.pending_visibility = []
        self.last_write = None
        self.visibility_reads = []

    def create_package(self):
        self.directory.mkdir(parents=True, exist_ok=True)
        (self.directory / NAMES[0]).write_bytes(b"independent zip fixture\x00")
        (self.directory / NAMES[1]).write_bytes(b"independent dmg fixture\xff")
        (self.directory / "SHA256SUMS").write_text("checked by package-metadata test suite\n")
        (self.directory / "release-manifest.json").write_text(json.dumps({
            "version": self.manifest_version,
            "commit": self.manifest_commit,
            "signing": "ad-hoc",
            "artifacts": [{"name": name} for name in NAMES[:2]],
        }))

    def existing_release(self, draft=True, names=None):
        self.create_package()
        self.release = {
            "id": 123, "tag_name": TAG, "draft": draft, "prerelease": False, "assets": [],
            "html_url": f"https://github.com/{RELEASE.REPOSITORY}/releases/tag/{TAG}",
        }
        self.local_tag = COMMIT
        self.remote_tag = COMMIT
        for name in NAMES if names is None else names:
            self.remote_files[name] = (self.directory / name).read_bytes()
            self.release["assets"].append({"name": name, "state": "uploaded"})

    @staticmethod
    def result(args, stdout="", stderr="", code=0):
        return subprocess.CompletedProcess(args, code, stdout, stderr)

    def run(self, args, **kwargs):
        args = tuple(str(part) for part in args)
        self.calls.append(args)
        self.environments.append(dict(kwargs["env"]))
        if Path(kwargs["cwd"]) != self.root:
            raise AssertionError("명령이 임시 검사 저장소 밖에서 실행되었습니다.")
        for prefix, error in self.failures.items():
            if args[:len(prefix)] == prefix:
                return self.result(args, stderr=error, code=1)
        if args == ("git", "branch", "--show-current"):
            return self.result(args, self.branch)
        if args[:3] == ("git", "status", "--porcelain"):
            return self.result(args, self.status)
        if args == ("git", "remote", "get-url", "origin"):
            return self.result(args, self.origin)
        if args == ("git", "remote", "get-url", "--push", "origin"):
            return self.result(args, self.push_origin)
        if args == ("git", "rev-parse", "HEAD"):
            return self.result(args, self.commit)
        if args == ("git", "rev-parse", "--git-path", "menubar-release.lock"):
            return self.result(args, str(self.root / ".git" / "menubar-release.lock"))
        if args[:3] == ("git", "ls-remote", "origin"):
            refs = f"{self.remote_commit}\trefs/heads/main\n"
            if self.remote_tag:
                refs += f"{self.remote_tag}\trefs/tags/{TAG}\n"
            return self.result(args, refs)
        if args[:3] == ("git", "rev-parse", "--verify"):
            return self.result(args, self.local_tag or "", code=0 if self.local_tag else 1)
        if args == ("git", "fetch", "origin", "main", "--tags"):
            return self.result(args)
        if args[:3] == ("git", "tag", "-a"):
            self.local_tag = args[4]
            return self.result(args)
        if args[:3] == ("git", "push", "origin"):
            self.remote_tag = self.local_tag
            return self.result(args)
        if args == ("gh", "auth", "status", "--hostname", "github.com"):
            return self.result(args)
        if args == ("gh", "api", f"repos/{RELEASE.REPOSITORY}"):
            return self.result(args, "{}")
        if args == ("gh", "api", f"repos/{RELEASE.REPOSITORY}/releases/tags/{TAG}"):
            # 이전 API로 되돌리면 초안은 404다. 초안을 반환하는 편리한 대역으로 회귀를 가리지 않는다.
            if self.release is None or self.release["draft"]:
                return self.result(args, stderr="gh: Not Found (HTTP 404)", code=1)
            return self.result(args, json.dumps(self.release))
        if args == ("gh", "api", f"repos/{RELEASE.REPOSITORY}/releases?per_page=100", "--paginate", "--slurp"):
            self.visibility_reads.append(self.last_write)
            if self.lookup_error:
                return self.result(args, stderr=self.lookup_error, code=1)
            # 같은 태그를 다른 게시자가 공개한 상태가 최종 원격 조회에 나타난다.
            if self.release and self.publish_on_readback and any(call[:3] == ("gh", "release", "upload") for call in self.calls):
                self.release["draft"] = False
            if self.release and self.replace_after_readback and self.full_readback_finished:
                self.release["id"] = 456
            visible = self.release
            if self.pending_visibility:
                response = self.pending_visibility.pop(0)
                if isinstance(response, str):
                    return self.result(args, stderr=response, code=1)
                visible = response(copy.deepcopy(self.release)) if callable(response) else response
            pages = copy.deepcopy(self.release_pages_before_target)
            pages.append([visible] if visible else [])
            return self.result(args, json.dumps(pages))
        if args[:3] == ("gh", "release", "create"):
            self.release = {
                "id": 123, "tag_name": TAG, "draft": "--draft" in args, "prerelease": False, "assets": [],
                "html_url": f"https://github.com/{RELEASE.REPOSITORY}/releases/tag/{TAG}",
            }
            self.arm_visibility("create")
            return self.result(args)
        if args[:3] == ("gh", "release", "upload"):
            path = Path(args[4])
            if path.name in self.remote_files:
                raise AssertionError("기존 첨부 파일을 다시 업로드했습니다.")
            self.remote_files[path.name] = path.read_bytes()
            self.release["assets"].append({"name": path.name, "state": "uploaded"})
            self.arm_visibility("upload")
            return self.result(args)
        if args[:3] == ("gh", "release", "download"):
            destination = Path(args[args.index("--dir") + 1])
            names = [args[args.index("--pattern") + 1]] if "--pattern" in args else list(self.remote_files)
            for name in names:
                data = self.remote_files[name]
                if name == self.corrupt_download:
                    data += b"corrupted in transit"
                (destination / name).write_bytes(data)
            if "--pattern" not in args:
                self.full_readback_finished = True
            return self.result(args)
        if args[:3] == ("gh", "release", "edit"):
            self.release["draft"] = False
            self.arm_visibility("edit")
            return self.result(args)
        if args == ("./scripts/version.sh", self.commit):
            return self.result(args, VERSION)
        if args == ("./scripts/check.sh",):
            if self.change_commit_after_checks:
                self.commit = OTHER_COMMIT
                self.remote_commit = OTHER_COMMIT
            return self.result(args)
        if args in (("./scripts/package.sh",), ("./scripts/notarize.sh",)):
            self.create_package()
            return self.result(args)
        if args[:1] in (("./scripts/check-package.sh",), ("./scripts/smoke-test.sh",)):
            return self.result(args)
        if args[:3] == ("python3", "scripts/package_metadata.py", "verify"):
            return self.result(args)
        if args[:1] == ("./scripts/release-notes.sh",):
            return self.result(args, "## 변경 사항\n\n- 릴리스 검사 자료\n")
        raise AssertionError(f"허용하지 않은 외부 명령: {args!r}")

    def arm_visibility(self, phase):
        # 쓰기는 성공했지만 후속 조회가 이전 복제본을 읽는 실제 지연을 모사한다.
        self.last_write = phase
        self.pending_visibility = list(self.visibility_after_write.get(phase, []))

    def publishing_commands(self):
        return [call for call in self.calls if call[:2] in (("git", "tag"), ("git", "push"))
                or call[:3] in (("gh", "release", "create"), ("gh", "release", "upload"), ("gh", "release", "edit"))]

    def github_mutations(self):
        return [call for call in self.publishing_commands() if call[0] == "gh"]


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="menubar-release-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / ".git").mkdir()
        self.fake = FakeCommands(self.root)
        self.publisher = RELEASE.Publisher(self.root)
        self.publisher.env.pop("SIGNING_IDENTITY", None)
        self.publisher.env.pop("NOTARY_PROFILE", None)
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(RELEASE.subprocess, "run", side_effect=self.fake.run).start()
        self.sleep = mock.patch("time.sleep").start()
        self.output = io.StringIO()
        redirect = contextlib.redirect_stdout(self.output)
        redirect.__enter__()
        self.addCleanup(redirect.__exit__, None, None, None)

    def assert_stopped(self, *, no_mutations=True, **options):
        with self.assertRaises(RELEASE.ReleaseError):
            self.publisher.execute(**options)
        if no_mutations:
            self.assertEqual(self.fake.publishing_commands(), [])

    def test_dry_run_is_read_only_even_when_release_does_not_exist(self):
        before = list(self.root.rglob("*"))
        self.publisher.execute(dry_run=True)
        self.assertEqual(self.fake.publishing_commands(), [])
        self.assertEqual(list(self.root.rglob("*")), before)
        self.assertFalse(any(call[:2] == ("git", "fetch") for call in self.fake.calls))
        self.assertFalse(any(call[0] in ("./scripts/check.sh", "./scripts/package.sh") for call in self.fake.calls))

    def test_cli_dry_run_does_not_create_a_lock_file(self):
        before = set(self.root.rglob("*"))
        with mock.patch.object(RELEASE, "ROOT", self.root), \
             mock.patch.object(RELEASE, "Publisher", return_value=self.publisher), \
             mock.patch.object(sys, "argv", ["release.py", "--dry-run"]):
            self.assertEqual(RELEASE.main(), 0)
        self.assertEqual(set(self.root.rglob("*")), before)
        self.assertEqual(self.fake.publishing_commands(), [])

    def test_prepare_builds_and_checks_without_creating_tags_or_remote_release(self):
        self.publisher.execute(prepare=True)
        self.assertTrue((self.fake.directory / "release-notes.md").is_file())
        self.assertIn(("./scripts/check.sh",), self.fake.calls)
        self.assertIn(("./scripts/smoke-test.sh",), self.fake.calls)
        self.assertEqual(self.fake.publishing_commands(), [])
        self.assertIsNone(self.fake.local_tag)
        self.assertIsNone(self.fake.release)

    def test_active_publisher_lock_refuses_second_cli_before_checks(self):
        lock_path = self.root / ".git" / "menubar-release.lock"
        with lock_path.open("a") as active_lock:
            fcntl.flock(active_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with mock.patch.object(RELEASE, "ROOT", self.root), \
                 mock.patch.object(RELEASE, "Publisher", return_value=self.publisher), \
                 mock.patch.object(sys, "argv", ["release.py"]), \
                 contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(RELEASE.main(), 1)
        self.assertEqual(self.fake.publishing_commands(), [])
        self.assertNotIn(("./scripts/check.sh",), self.fake.calls)

    def test_dirty_wrong_branch_and_wrong_origins_refuse_before_build(self):
        cases = [("status", " M Sources/file.swift\n"), ("status", "?? untracked\n"),
                 ("branch", "feature"), ("branch", ""),
                 ("origin", "https://github.com/other/repo.git"),
                 ("push_origin", "git@github.com:other/repo.git"),
                 ("remote_commit", OTHER_COMMIT)]
        for attribute, value in cases:
            with self.subTest(attribute=attribute, value=value):
                original = getattr(self.fake, attribute)
                setattr(self.fake, attribute, value)
                self.fake.calls.clear()
                self.assert_stopped()
                self.assertNotIn(("./scripts/check.sh",), self.fake.calls)
                setattr(self.fake, attribute, original)

    def test_github_lookup_failures_are_not_treated_as_missing_release(self):
        for error in ["connection timed out", "gh: Bad credentials (HTTP 401)",
                      "gh: Forbidden (HTTP 403)", "gh: Not Found (HTTP 404)",
                      "gh: Internal Server Error (HTTP 500)"]:
            with self.subTest(error=error):
                self.fake.lookup_error = error
                self.fake.calls.clear()
                self.assert_stopped()
                self.assertNotIn(("./scripts/check.sh",), self.fake.calls)

    def test_draft_on_a_later_page_is_found_and_resumed(self):
        self.fake.existing_release()
        self.fake.release_pages_before_target = [
            [{"id": number, "tag_name": f"v0.0.{number}", "draft": False} for number in range(100)],
            [{"id": 1001, "tag_name": TAG + "-rc.1", "draft": True}],
        ]
        info = self.publisher.release_info(TAG)
        self.assertIsNotNone(info)
        self.assertEqual(info["id"], self.fake.release["id"])
        self.assertTrue(info["draft"])
        self.publisher.execute()
        self.assertFalse(any(call[:3] in (("gh", "release", "create"), ("gh", "release", "upload")) for call in self.fake.calls))
        self.assertNotIn(("./scripts/package.sh",), self.fake.calls)
        self.assertFalse(self.fake.release["draft"])

    def test_successful_paginated_query_requires_an_exact_tag_match(self):
        self.fake.release_pages_before_target = [
            [{"id": 1, "tag_name": TAG + "-rc.1", "draft": False}],
            [{"id": 2, "tag_name": TAG.upper(), "draft": True}],
        ]
        self.assertIsNone(self.publisher.release_info(TAG))
        self.assertEqual(self.fake.publishing_commands(), [])

    def test_duplicate_exact_tags_across_pages_refuse_before_build(self):
        self.fake.existing_release()
        duplicate = copy.deepcopy(self.fake.release)
        duplicate["id"] = 999
        duplicate["draft"] = False
        self.fake.release_pages_before_target = [[duplicate]]
        self.assert_stopped()
        self.assertNotIn(("./scripts/check.sh",), self.fake.calls)

    def test_foreign_gh_host_is_overridden_for_reads_and_publishing(self):
        with mock.patch.dict(RELEASE.os.environ, {"GH_HOST": "enterprise.invalid"}):
            publisher = RELEASE.Publisher(self.root)
            publisher.env.pop("SIGNING_IDENTITY", None)
            publisher.env.pop("NOTARY_PROFILE", None)
            publisher.execute()
            self.assertEqual(RELEASE.os.environ["GH_HOST"], "enterprise.invalid")
        github_calls = [(args, environment) for args, environment in zip(self.fake.calls, self.fake.environments) if args[0] == "gh"]
        self.assertTrue(any(args[:3] == ("gh", "release", "edit") for args, _ in github_calls))
        self.assertTrue(all(environment.get("GH_HOST") == "github.com" for _, environment in github_calls))

    def test_auth_and_repository_access_failures_stop_before_build(self):
        for command in [("gh", "auth"), ("gh", "api", f"repos/{RELEASE.REPOSITORY}")]:
            with self.subTest(command=command):
                self.fake.failures = {command: "access denied"}
                self.fake.calls.clear()
                self.assert_stopped()
                self.assertNotIn(("./scripts/check.sh",), self.fake.calls)

    def test_dry_run_refuses_unsynchronized_remote_tag_without_fetching(self):
        self.fake.remote_tag = COMMIT
        self.assert_stopped(dry_run=True)
        self.assertFalse(any(call[:2] == ("git", "fetch") for call in self.fake.calls))

    def test_check_package_and_smoke_failures_never_create_a_tag(self):
        for command in ("./scripts/check.sh", "./scripts/package.sh", "./scripts/check-package.sh", "./scripts/smoke-test.sh"):
            with self.subTest(command=command):
                self.fake.failures = {(command,): "intentional fixture failure"}
                self.fake.calls.clear()
                self.assert_stopped()

    def test_manifest_identity_mismatch_never_creates_a_tag(self):
        for attribute, value in [("manifest_commit", OTHER_COMMIT), ("manifest_version", "9.0.0")]:
            with self.subTest(attribute=attribute):
                setattr(self.fake, attribute, value)
                self.fake.calls.clear()
                self.assert_stopped()
                self.fake.manifest_commit = COMMIT
                self.fake.manifest_version = VERSION

    def test_head_change_during_checks_refuses_tag_and_release(self):
        self.fake.change_commit_after_checks = True
        self.assert_stopped()

    def test_existing_tag_pointing_elsewhere_is_never_moved(self):
        for attribute in ("local_tag", "remote_tag"):
            with self.subTest(attribute=attribute):
                setattr(self.fake, attribute, OTHER_COMMIT)
                self.fake.calls.clear()
                self.assert_stopped()
                setattr(self.fake, attribute, None)

    def test_already_published_release_is_only_read_back(self):
        self.fake.existing_release(draft=False)
        before = copy.deepcopy(self.fake.release)
        self.publisher.execute()
        self.assertEqual(self.fake.publishing_commands(), [])
        self.assertEqual(self.fake.release, before)
        self.assertNotIn(("./scripts/check.sh",), self.fake.calls)
        self.assertTrue(any(call[:3] == ("gh", "release", "download") for call in self.fake.calls))

    def test_resume_skips_same_bytes_and_uploads_only_missing_files(self):
        self.fake.existing_release(names=NAMES[:2])
        before = dict(self.fake.remote_files)
        self.publisher.execute()
        uploaded = [Path(call[4]).name for call in self.fake.calls if call[:3] == ("gh", "release", "upload")]
        self.assertEqual(uploaded, NAMES[2:])
        self.assertTrue(all(self.fake.remote_files[name] == content for name, content in before.items()))
        self.assertFalse(self.fake.release["draft"])
        self.assertNotIn(("./scripts/package.sh",), self.fake.calls)
        self.assertFalse(any("--clobber" in call for call in self.fake.calls))

    def test_resume_refuses_changed_existing_bytes_without_overwriting_them(self):
        self.fake.existing_release()
        self.fake.remote_files[NAMES[0]] = b"different previous package"
        before = dict(self.fake.remote_files)
        self.assert_stopped(no_mutations=False)
        self.assertEqual(self.fake.github_mutations(), [])
        self.assertEqual(self.fake.remote_files, before)
        self.assertTrue(self.fake.release["draft"])

    def test_resume_without_local_original_package_refuses_rebuild(self):
        self.fake.existing_release(names=[])
        for path in self.fake.directory.iterdir():
            path.unlink()
        self.fake.directory.rmdir()
        self.assert_stopped()
        self.assertNotIn(("./scripts/package.sh",), self.fake.calls)

    def test_unexpected_draft_assets_are_preserved_and_not_published(self):
        self.fake.existing_release()
        self.fake.release["assets"].append({"name": "foreign.zip", "state": "uploaded"})
        self.fake.remote_files["foreign.zip"] = b"must remain untouched"
        before = dict(self.fake.remote_files)
        self.assert_stopped(no_mutations=False)
        self.assertEqual(self.fake.github_mutations(), [])
        self.assertEqual(self.fake.remote_files, before)

    def test_new_release_is_published_only_after_readback_and_final_preflight(self):
        self.publisher.execute()
        calls = self.fake.calls
        creation = next(call for call in calls if call[:3] == ("gh", "release", "create"))
        self.assertIn("--draft", creation)
        edit = next(index for index, call in enumerate(calls) if call[:3] == ("gh", "release", "edit"))
        readback = next(index for index, call in enumerate(calls) if call[:3] == ("gh", "release", "download") and "--pattern" not in call)
        final_status = max(index for index, call in enumerate(calls) if call[:3] == ("git", "status", "--porcelain"))
        self.assertLess(readback, final_status)
        self.assertLess(final_status, edit)
        self.assertEqual(set(self.fake.remote_files), set(NAMES))
        self.assertFalse(self.fake.release["draft"])

    def test_readback_failure_leaves_complete_draft_unpublished(self):
        self.fake.corrupt_download = NAMES[0]
        self.assert_stopped(no_mutations=False)
        self.assertTrue(self.fake.release["draft"])
        self.assertFalse(any(call[:3] == ("gh", "release", "edit") for call in self.fake.calls))
        self.sleep.assert_not_called()

    def test_release_published_by_another_process_is_not_edited_again(self):
        self.fake.publish_on_readback = True
        # 같은 바이트가 이미 공개됐다면 성공 또는 중단 모두 허용하되 다시 쓰지는 않는다.
        try:
            self.publisher.execute()
        except RELEASE.ReleaseError:
            pass
        self.assertFalse(self.fake.release["draft"])
        self.assertFalse(any(call[:3] == ("gh", "release", "edit") for call in self.fake.calls))

    def test_replacement_release_after_readback_is_not_published(self):
        self.fake.replace_after_readback = True
        self.assert_stopped(no_mutations=False)
        self.assertTrue(self.fake.release["draft"])
        self.assertFalse(any(call[:3] == ("gh", "release", "edit") for call in self.fake.calls))

    def test_failed_tag_push_does_not_create_a_github_release(self):
        self.fake.failures[("git", "push")] = "remote rejected push"
        self.assert_stopped(no_mutations=False)
        self.assertEqual(self.fake.github_mutations(), [])
        self.assertIsNone(self.fake.release)

    def test_interrupted_upload_resumes_without_replacing_uploaded_bytes(self):
        self.fake.failures[("gh", "release", "upload", TAG, str(self.fake.directory / NAMES[1]))] = "connection reset"
        self.assert_stopped(no_mutations=False)
        self.assertEqual(set(self.fake.remote_files), {NAMES[0]})
        first_bytes = self.fake.remote_files[NAMES[0]]
        self.assertTrue(self.fake.release["draft"])
        self.fake.failures.clear()
        self.fake.calls.clear()
        self.publisher.execute()
        self.assertEqual(self.fake.remote_files[NAMES[0]], first_bytes)
        uploads = [Path(call[4]).name for call in self.fake.calls if call[:3] == ("gh", "release", "upload")]
        self.assertEqual(uploads, NAMES[1:])
        self.assertFalse(self.fake.release["draft"])

    def test_publish_failure_preserves_draft_and_uploaded_bytes_for_retry(self):
        self.fake.failures[("gh", "release", "edit")] = "network interrupted"
        self.assert_stopped(no_mutations=False)
        before = dict(self.fake.remote_files)
        self.assertTrue(self.fake.release["draft"])
        self.sleep.assert_not_called()
        self.assertEqual(sum(call[:3] == ("gh", "release", "edit") for call in self.fake.calls), 1)
        self.fake.failures.clear()
        self.fake.calls.clear()
        self.publisher.execute()
        self.assertFalse(any(call[:3] == ("gh", "release", "upload") for call in self.fake.calls))
        self.assertEqual(self.fake.remote_files, before)
        self.assertFalse(self.fake.release["draft"])

    def test_new_draft_becomes_visible_on_fourth_read_without_duplicate_create(self):
        self.fake.visibility_after_write["create"] = [None, None, None]
        self.publisher.execute()
        self.assertEqual(self.fake.visibility_reads.count("create"), 4)
        self.assertEqual(self.sleep.call_args_list, [mock.call(1)] * 3)
        self.assertEqual(sum(call[:3] == ("gh", "release", "create") for call in self.fake.calls), 1)
        self.assertFalse(self.fake.release["draft"])

    def test_uploaded_assets_become_visible_without_duplicate_upload(self):
        self.fake.visibility_after_write["upload"] = [
            lambda info: {**info, "assets": []},
            lambda info: {**info, "assets": info["assets"][:2]},
            lambda info: {**info, "assets": info["assets"][:3]},
        ]
        self.publisher.execute()
        self.assertEqual(self.sleep.call_args_list, [mock.call(1)] * 3)
        uploads = [Path(call[4]).name for call in self.fake.calls if call[:3] == ("gh", "release", "upload")]
        self.assertEqual(uploads, NAMES)
        # 준비된 응답을 다시 조회하지 않고 바로 원격 바이트 검증에 사용한다.
        last_upload = max(index for index, call in enumerate(self.fake.calls) if call[:3] == ("gh", "release", "upload"))
        first_download = next(index for index, call in enumerate(self.fake.calls) if call[:3] == ("gh", "release", "download"))
        reads = [call for call in self.fake.calls[last_upload + 1:first_download] if call[:2] == ("gh", "api")]
        self.assertEqual(len(reads), 4)
        self.assertFalse(self.fake.release["draft"])

    def test_publication_becomes_visible_without_duplicate_edit(self):
        self.fake.visibility_after_write["edit"] = [lambda info: {**info, "draft": True}] * 3
        self.publisher.execute()
        self.assertEqual(self.fake.visibility_reads.count("edit"), 4)
        self.assertEqual(self.sleep.call_args_list, [mock.call(1)] * 3)
        self.assertEqual(sum(call[:3] == ("gh", "release", "edit") for call in self.fake.calls), 1)
        self.assertFalse(self.fake.release["draft"])

    def assert_visibility_timeout_preserves_results(self, phase, response, uploaded_count, published):
        self.fake.visibility_after_write[phase] = [response] * 5
        self.assert_stopped(no_mutations=False)
        self.assertEqual(self.fake.visibility_reads.count(phase), 4)
        self.assertEqual(len(self.fake.pending_visibility), 1)
        self.assertEqual(self.sleep.call_args_list, [mock.call(1)] * 3)
        self.assertEqual(self.fake.local_tag, COMMIT)
        self.assertEqual(self.fake.remote_tag, COMMIT)
        self.assertEqual(self.fake.release["draft"], not published)
        self.assertEqual(len(self.fake.remote_files), uploaded_count)
        self.assertTrue((self.fake.directory / "release-notes.md").is_file())
        for name, content in self.fake.remote_files.items():
            self.assertEqual(content, (self.fake.directory / name).read_bytes())
        self.assertEqual(sum(call[:3] == ("gh", "release", "create") for call in self.fake.calls), 1)
        self.assertEqual(sum(call[:3] == ("gh", "release", "upload") for call in self.fake.calls), uploaded_count)
        self.assertEqual(sum(call[:3] == ("gh", "release", "edit") for call in self.fake.calls), int(published))

    def test_creation_visibility_timeout_keeps_draft_and_prepared_files(self):
        self.assert_visibility_timeout_preserves_results("create", None, 0, False)

    def test_upload_visibility_timeout_keeps_all_uploaded_bytes(self):
        self.assert_visibility_timeout_preserves_results("upload", lambda info: {**info, "assets": []}, 4, False)

    def test_publication_visibility_timeout_never_repeats_edit(self):
        self.assert_visibility_timeout_preserves_results("edit", lambda info: {**info, "draft": True}, 4, True)

    def test_postwrite_lookup_errors_stop_without_waiting_or_repeating_writes(self):
        self.fake.visibility_after_write["create"] = ["gh: Not Found (HTTP 404)", None]
        self.assert_stopped(no_mutations=False)
        self.assertEqual(self.fake.visibility_reads.count("create"), 1)
        self.sleep.assert_not_called()
        self.assertEqual(sum(call[:3] == ("gh", "release", "create") for call in self.fake.calls), 1)
        self.assertEqual(self.fake.remote_files, {})
        self.assertTrue(self.fake.release["draft"])

    def test_postwrite_identity_prerelease_and_foreign_assets_fail_immediately(self):
        responses = {
            "다른 ID": lambda info: {**info, "id": 456},
            "사전 릴리스": lambda info: {**info, "prerelease": True},
            "예상 밖 파일": lambda info: {**info, "assets": [{"name": "foreign.zip", "state": "uploaded"}]},
            "중복 파일": lambda info: {**info, "assets": [info["assets"][0]] * 2},
        }
        for reason, response in responses.items():
            with self.subTest(reason=reason):
                # 같은 임시 경로를 쓰되 각 독립 실행의 서버·명령 기록은 초기화한다.
                self.fake.__init__(self.root)
                self.sleep.reset_mock()
                self.fake.visibility_after_write["upload"] = [response, None]
                self.assert_stopped(no_mutations=False)
                self.assertEqual(self.fake.visibility_reads.count("upload"), 1)
                self.sleep.assert_not_called()
                self.assertFalse(any(call[:3] == ("gh", "release", "edit") for call in self.fake.calls))
                self.assertEqual(set(self.fake.remote_files), set(NAMES))

    def test_resume_without_own_write_does_not_wait_for_missing_assets(self):
        self.fake.existing_release()
        self.fake.pending_visibility = [
            lambda info: info,
            lambda info: info,
            lambda info: {**info, "assets": info["assets"][:2]},
        ]
        self.assert_stopped(no_mutations=False)
        self.sleep.assert_not_called()
        self.assertEqual(self.fake.github_mutations(), [])

    def test_release_replaced_before_resuming_upload_is_untouched(self):
        self.fake.existing_release(names=[])
        self.fake.pending_visibility = [lambda info: info, lambda info: {**info, "id": 456}]
        self.assert_stopped(no_mutations=False)
        self.assertEqual(self.fake.github_mutations(), [])
        self.sleep.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
