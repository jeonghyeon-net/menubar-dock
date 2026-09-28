#!/usr/bin/env python3
"""main의 검증된 패키지만 게시하고 중단된 초안은 첨부 파일을 보존하며 재개한다."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

REPOSITORY = "jeonghyeon-net/menubar-dock"
ROOT = Path(__file__).resolve().parent.parent
STABLE_TAG = re.compile(r"v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")


class ReleaseError(Exception):
    """게시 전에 사용자가 해결할 수 있는 릴리스 조건 오류."""


class Publisher:
    def __init__(self, root=ROOT):
        self.root = Path(root)
        self.env = os.environ.copy()
        self.env["PYTHONDONTWRITEBYTECODE"] = "1"
        self.env["GH_HOST"] = "github.com"

    def run(self, *args, check=True):
        result = subprocess.run(args, cwd=self.root, env=self.env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if check and result.returncode:
            raise ReleaseError(f"명령 실패: {' '.join(args)}\n{result.stderr.strip()}\n{result.stdout.strip()}")
        return result

    def git(self, *args):
        return self.run("git", *args).stdout.strip()

    def step(self, *args):
        print(f"실행: {' '.join(args)}", flush=True)
        result = subprocess.run(args, cwd=self.root, env=self.env)
        if result.returncode:
            raise ReleaseError(f"검증 또는 게시 명령이 실패했습니다: {' '.join(args)}")

    def remote_refs(self):
        refs = {}
        for line in self.git("ls-remote", "origin", "refs/heads/main", "refs/tags/v*").splitlines():
            sha, ref = line.split("\t", 1)
            refs[ref] = sha
        return refs

    def preflight(self, expected_commit=None):
        if self.git("branch", "--show-current") != "main":
            raise ReleaseError("릴리스는 main 브랜치에서만 실행할 수 있습니다.")
        if self.git("status", "--porcelain", "--untracked-files=all"):
            raise ReleaseError("변경 사항을 검증·커밋·푸시한 뒤 릴리스를 실행하세요.")
        allowed = {f"git@github.com:{REPOSITORY}.git", f"https://github.com/{REPOSITORY}.git",
                   f"https://github.com/{REPOSITORY}", f"ssh://git@github.com/{REPOSITORY}.git"}
        for args in (("remote", "get-url", "origin"), ("remote", "get-url", "--push", "origin")):
            if self.git(*args) not in allowed:
                raise ReleaseError("origin의 읽기·푸시 주소가 이 프로젝트의 GitHub 저장소와 다릅니다.")
        commit = self.git("rev-parse", "HEAD")
        if expected_commit and expected_commit != commit:
            raise ReleaseError("검증 도중 HEAD가 변경됐습니다. 새 커밋에서 다시 실행하세요.")
        refs = self.remote_refs()
        if refs.get("refs/heads/main") != commit:
            raise ReleaseError("현재 main과 원격 main이 다릅니다. 변경 사항을 먼저 동기화하세요.")
        self.run("gh", "auth", "status", "--hostname", "github.com")
        self.run("gh", "api", f"repos/{REPOSITORY}")
        return commit, refs

    def release_info(self, tag):
        # 태그 조회 API는 공개된 릴리스만 보장하므로 초안을 포함하는 목록을 읽는다.
        # 페이지를 끝까지 조회하고, 네트워크·권한 오류는 '아직 없음'으로 바꾸지 않는다.
        result = self.run("gh", "api", f"repos/{REPOSITORY}/releases?per_page=100", "--paginate", "--slurp")
        pages = json.loads(result.stdout)
        if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
            raise ReleaseError("GitHub 릴리스 목록의 응답 형식이 올바르지 않습니다.")
        matches = [release for page in pages for release in page if release.get("tag_name") == tag]
        if len(matches) > 1:
            raise ReleaseError(f"같은 태그의 릴리스가 여러 개입니다: {tag}")
        return matches[0] if matches else None

    def validate_tag(self, tag, commit, refs):
        local = self.run("git", "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}", check=False)
        if local.returncode == 0 and local.stdout.strip() != commit:
            raise ReleaseError(f"{tag} 태그가 다른 커밋을 가리킵니다. 기존 태그를 덮어쓰지 않습니다.")
        remote = refs.get(f"refs/tags/{tag}^{{}}", refs.get(f"refs/tags/{tag}"))
        if remote and remote != commit:
            raise ReleaseError(f"원격 {tag} 태그가 다른 커밋을 가리킵니다.")

    def manifest(self, directory, version, commit):
        self.run("python3", "scripts/package_metadata.py", "verify", str(directory))
        data = json.loads((directory / "release-manifest.json").read_text())
        if data["version"] != version or data["commit"] != commit:
            raise ReleaseError("패키지의 버전·대상 커밋이 이번 릴리스와 다릅니다.")
        return data

    def verify_remote(self, tag, version, commit, local=None):
        info = self.release_info(tag)
        if not info or info.get("prerelease"):
            raise ReleaseError("정식 릴리스 정보를 확인할 수 없습니다.")
        expected = {f"MenuBarDock-{version}-arm64.zip", f"MenuBarDock-{version}-arm64.dmg",
                    "SHA256SUMS", "release-manifest.json"}
        assets = info.get("assets", [])
        if len(assets) != len(expected) or {a["name"] for a in assets} != expected:
            raise ReleaseError("릴리스 첨부 파일 목록이 ZIP·DMG·체크섬·manifest와 다릅니다.")
        if any(a.get("state") != "uploaded" for a in assets):
            raise ReleaseError("업로드가 완료되지 않은 첨부 파일이 있습니다.")
        with tempfile.TemporaryDirectory(prefix="menubar-release-download-") as tmp:
            directory = Path(tmp)
            self.run("gh", "release", "download", tag, "--repo", REPOSITORY, "--dir", str(directory))
            self.manifest(directory, version, commit)
            if local:
                for name in expected:
                    if (directory / name).read_bytes() != (local / name).read_bytes():
                        raise ReleaseError(f"업로드 후 내용이 달라졌습니다: {name}")
        return info

    def upload_missing(self, info, tag, directory, names):
        assets = {asset["name"]: asset for asset in info.get("assets", [])}
        if len(assets) != len(info.get("assets", [])) or set(assets) - set(names):
            raise ReleaseError("초안에 예상하지 못한 첨부 파일이 있습니다. 기존 파일을 보존하고 중단합니다.")
        for name in names:
            if name in assets:
                # 재시도는 이미 올라간 바이트가 같을 때만 이어간다. --clobber는 사용하지 않는다.
                with tempfile.TemporaryDirectory(prefix="menubar-release-existing-") as tmp:
                    self.run("gh", "release", "download", tag, "--repo", REPOSITORY,
                             "--pattern", name, "--dir", tmp)
                    if (Path(tmp) / name).read_bytes() != (directory / name).read_bytes():
                        raise ReleaseError(f"초안의 기존 첨부 파일과 로컬 파일이 다릅니다: {name}")
            else:
                self.step("gh", "release", "upload", tag, str(directory / name), "--repo", REPOSITORY)

    def execute(self, dry_run=False, prepare=False):
        commit, refs = self.preflight()
        if not dry_run:
            self.step("git", "fetch", "origin", "main", "--tags")
            commit, refs = self.preflight(commit)
        else:
            for ref, sha in refs.items():
                if ref.endswith("^{}") or not ref.startswith("refs/tags/"):
                    continue
                tag = ref.removeprefix("refs/tags/")
                if STABLE_TAG.fullmatch(tag):
                    local = self.run("git", "rev-parse", "--verify", ref, check=False)
                    if local.returncode or local.stdout.strip() != sha:
                        raise ReleaseError("원격 태그와 로컬 태그가 다릅니다. git fetch origin --tags 후 다시 확인하세요.")
        version = self.run("./scripts/version.sh", commit).stdout.strip()
        tag = f"v{version}"
        if not STABLE_TAG.fullmatch(tag):
            raise ReleaseError("버전 계산 결과가 X.Y.Z 형식이 아닙니다.")
        self.validate_tag(tag, commit, refs)
        info = self.release_info(tag)
        directory = self.root / "dist" / "releases" / version
        print(f"대상: {REPOSITORY} / {tag} / {commit}\n파일: {directory}", flush=True)
        if dry_run:
            status = "이미 게시됨" if info and not info["draft"] else "기존 초안 재개" if info else "새 릴리스"
            print(f"계획: {status}. 버전·커밋·원격 확인만 수행했습니다. 빌드·태그·게시 없음.")
            return
        if info and not info["draft"]:
            if f"refs/tags/{tag}" not in refs:
                raise ReleaseError("게시된 릴리스에 대응하는 원격 태그가 없습니다.")
            self.verify_remote(tag, version, commit)
            print(f"이미 게시된 릴리스를 확인했습니다: {info['html_url']}")
            return
        build_dir = self.root / "build" / f"release-{version}"
        self.env.update(MENUBAR_BUILD_DIR=str(build_dir), MENUBAR_DIST_DIR=str(directory),
                        MENUBAR_VERSION=version, CONFIGURATION="release", BUILD_ARCH="arm64")
        self.env.pop("SKIP_BUILD", None)
        self.step("./scripts/check.sh")
        if info:
            if not directory.exists():
                raise ReleaseError("중단된 초안의 로컬 배포 파일이 없습니다. 기존 파일을 복원한 뒤 다시 실행하세요.")
            self.manifest(directory, version, commit)
            self.step("./scripts/check-package.sh", str(directory))
        else:
            if self.env.get("NOTARY_PROFILE") and not self.env.get("SIGNING_IDENTITY"):
                raise ReleaseError("공증하려면 SIGNING_IDENTITY도 지정해야 합니다.")
            self.step("./scripts/notarize.sh" if self.env.get("NOTARY_PROFILE") else "./scripts/package.sh")
            self.step("./scripts/check-package.sh", str(directory))
            self.step("./scripts/smoke-test.sh")
        metadata = self.manifest(directory, version, commit)
        notes = self.run("./scripts/release-notes.sh", version, commit, str(directory)).stdout
        notes_path = directory / "release-notes.md"
        notes_path.write_text(notes)
        print(f"릴리스 노트: {notes_path}\n서명 상태: {metadata['signing']}", flush=True)
        if prepare:
            print("패키지·릴리스 노트 검증 완료. Git 태그와 GitHub 릴리스는 만들지 않았습니다.")
            return
        _, refs = self.preflight(commit)
        self.validate_tag(tag, commit, refs)
        if self.run("git", "rev-parse", "--verify", f"refs/tags/{tag}", check=False).returncode:
            self.step("git", "tag", "-a", tag, commit, "-m", f"Menu Bar Dock {version}")
        self.step("git", "push", "origin", f"refs/tags/{tag}")
        # 첨부 파일을 모두 검증한 뒤 초안을 공개하므로 불완전한 릴리스가 최신 버전이 되지 않는다.
        if not info:
            self.step("gh", "release", "create", tag, "--repo", REPOSITORY, "--verify-tag",
                      "--target", commit, "--title", tag, "--notes-file", str(notes_path), "--draft")
        current = self.release_info(tag)
        if not current or not current["draft"]:
            raise ReleaseError("게시 도중 릴리스 상태가 변경됐습니다. 첨부 파일을 수정하지 않습니다.")
        names = [a["name"] for a in metadata["artifacts"]] + ["SHA256SUMS", "release-manifest.json"]
        self.upload_missing(current, tag, directory, names)
        verified = self.verify_remote(tag, version, commit, directory)
        if not verified["draft"]:
            raise ReleaseError("첨부 파일 검증 중 다른 작업이 릴리스를 게시했습니다. 기존 릴리스를 수정하지 않습니다.")
        _, refs = self.preflight(commit)
        self.validate_tag(tag, commit, refs)
        current = self.release_info(tag)
        if not current or not current["draft"] or current["id"] != verified["id"]:
            raise ReleaseError("공개 직전에 릴리스 상태가 변경됐습니다. 기존 릴리스를 수정하지 않습니다.")
        self.step("gh", "release", "edit", tag, "--repo", REPOSITORY, "--verify-tag", "--title", tag,
                  "--notes-file", str(notes_path), "--draft=false", "--latest")
        published = self.release_info(tag)
        if not published or published["draft"] or published.get("prerelease"):
            raise ReleaseError("릴리스 공개 상태를 확인하지 못했습니다. 같은 명령으로 다시 확인하세요.")
        print(f"게시 완료: {published['html_url']}")


def main():
    parser = argparse.ArgumentParser(description="검증된 main 커밋의 macOS 패키지를 GitHub Release로 게시합니다.")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--dry-run", action="store_true", help="버전·커밋·원격 조건만 읽어서 확인")
    group.add_argument("--prepare", action="store_true", help="검사·패키징·릴리스 노트 생성까지만 수행")
    args = parser.parse_args()
    publisher = Publisher()
    try:
        if args.dry_run:
            publisher.execute(dry_run=True)
            return 0
        # 같은 checkout의 빌드·게시가 겹쳐 서로 다른 파일을 첨부하는 일을 막는다.
        lock_path = Path(publisher.git("rev-parse", "--git-path", "menubar-release.lock"))
        if not lock_path.is_absolute():
            lock_path = ROOT / lock_path
        with lock_path.open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ReleaseError("다른 릴리스 작업이 실행 중입니다.")
            publisher.execute(args.dry_run, args.prepare)
    except (ReleaseError, OSError, ValueError, KeyError) as error:
        print(f"릴리스 중단: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
