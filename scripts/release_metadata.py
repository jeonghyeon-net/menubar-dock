#!/usr/bin/env python3
"""Git 이력과 검증된 배포 파일에서 버전·릴리스 설명을 만든다."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import plistlib
import re
import string
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
REPOSITORY_URL = "https://github.com/jeonghyeon-net/menubar-dock"
VERSION_PATTERN = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", re.ASCII)
MAX_COMPONENT = 2_147_483_647


class MetadataError(Exception):
    """불완전한 이력이나 배포 자료로 잘못된 릴리스를 만들지 않는다."""


def git(*arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(ROOT), *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if result.returncode:
        raise MetadataError("Git 이력을 읽을 수 없습니다: " + result.stderr.strip())
    return result.stdout.rstrip("\n")


def version_parts(value: str) -> tuple[int, int, int]:
    match = VERSION_PATTERN.fullmatch(value)
    if not match:
        raise MetadataError("버전은 앞자리 0이 없는 X.Y.Z 형식이어야 합니다: " + value)
    # Python의 정수 문자열 길이 제한에 도달하기 전에 명시적으로 거부한다.
    if any(len(part) > 10 for part in match.groups()):
        raise MetadataError("버전 숫자가 허용 범위를 넘었습니다: " + value)
    parts = tuple(int(part) for part in match.groups())
    if any(part > MAX_COMPONENT for part in parts):
        raise MetadataError("버전 숫자가 허용 범위를 넘었습니다: " + value)
    return parts


def resolve_commit(target: str) -> str:
    if git("rev-parse", "--is-shallow-repository") != "false":
        raise MetadataError("전체 Git 이력이 필요합니다. 얕은 복제에서는 버전을 계산하지 않습니다.")
    return git("rev-parse", "--verify", "--end-of-options", target + "^{commit}")


def ancestry_tags(commit: str) -> list[tuple[tuple[int, int, int], str, str]]:
    ancestors = set(git("rev-list", "--first-parent", commit).splitlines())
    tags = []
    for tag in git("tag", "--list").splitlines():
        if not tag.startswith("v") or not VERSION_PATTERN.fullmatch(tag[1:]):
            continue
        # 태그 이름이 숫자로 보여도 다른 계보의 버전은 현재 릴리스에 영향을 주지 않는다.
        tagged_commit = git("rev-parse", "--verify", "refs/tags/" + tag + "^{commit}")
        if tagged_commit in ancestors:
            tags.append((version_parts(tag[1:]), tag, tagged_commit))
    return tags


def release_version(commit: str) -> str:
    tags = ancestry_tags(commit)
    exact_tags = [tag for _, tag, target in tags if target == commit]
    if len(exact_tags) > 1:
        raise MetadataError("한 커밋에 여러 릴리스 버전이 지정되어 있습니다: " + ", ".join(sorted(exact_tags)))
    if exact_tags:
        return exact_tags[0][1:]
    if tags:
        latest, _, _ = max(tags)
        if latest[2] == MAX_COMPONENT:
            raise MetadataError("패치 버전이 허용 범위를 넘습니다. 새 major/minor 버전을 지정해야 합니다.")
        return ".".join(str(part) for part in (latest[0], latest[1], latest[2] + 1))
    try:
        # 초기 버전도 작업 중인 Info.plist가 아닌 해당 커밋에 저장된 값을 사용한다.
        plist = plistlib.loads(git("show", commit + ":Config/Info.plist").encode("utf-8"))
        seed = plist["CFBundleShortVersionString"]
        if not isinstance(seed, str):
            raise ValueError("CFBundleShortVersionString은 문자열이어야 합니다.")
        version_parts(seed)
        return seed
    except (KeyError, ValueError, plistlib.InvalidFileException) as error:
        raise MetadataError("초기 버전을 Config/Info.plist에서 읽을 수 없습니다: " + str(error)) from error


def build_number(commit: str) -> str:
    count = git("rev-list", "--first-parent", "--count", commit)
    if not count.isascii() or not count.isdecimal() or int(count) < 1:
        raise MetadataError("빌드 번호를 계산할 수 없습니다.")
    return count


def escape_subject(subject: str) -> str:
    # 커밋 제목의 Markdown·HTML·사용자 멘션을 데이터로 표시한다. 코드 펜스도 열리지 않는다.
    normalized = " ".join("".join(character for character in subject if character.isprintable() or character.isspace()).split())
    fragments = []
    for token in re.split(r"(@[A-Za-z0-9_/\-]+)", normalized):
        escaped = "".join("&#" + str(ord(character)) + ";" if character in string.punctuation else character for character in token)
        # GitHub는 HTML entity의 @도 멘션으로 바꾼다. 코드 영역은 멘션 후처리에서 제외된다.
        fragments.append("<code>" + escaped + "</code>" if token.startswith("@") else escaped)
    return "".join(fragments)


def verified_manifest(directory: Path) -> dict:
    result = subprocess.run(
        [sys.executable, str(ROOT / "scripts/package_metadata.py"), "verify", str(directory)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if result.returncode:
        raise MetadataError("배포 파일 검증에 실패했습니다: " + (result.stderr or result.stdout).strip())
    try:
        return json.loads((directory / "release-manifest.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise MetadataError("배포 명세를 읽을 수 없습니다: " + str(error)) from error


def release_notes(version: str, target: str, directory: Path) -> str:
    parts = version_parts(version)
    commit = resolve_commit(target)
    tag = "v" + version
    if tag in git("tag", "--list").splitlines() and resolve_commit("refs/tags/" + tag) != commit:
        raise MetadataError("릴리스 태그가 대상 커밋과 다릅니다: " + tag)
    expected_version = release_version(commit)
    if version != expected_version:
        raise MetadataError("요청 버전과 대상 커밋의 버전이 다릅니다: " + version + " / " + expected_version)
    manifest = verified_manifest(directory)
    for key, expected in (("version", version), ("commit", commit), ("buildNumber", build_number(commit))):
        if manifest.get(key) != expected:
            raise MetadataError("배포 명세의 " + key + " 값이 대상 커밋과 다릅니다.")
    previous = [entry for entry in ancestry_tags(commit) if entry[0] < parts and entry[2] != commit]
    previous_tag = max(previous)[1] if previous else None
    commit_range = (previous_tag + ".." if previous_tag else "") + commit
    changes = git("log", "--first-parent", "--reverse", "-z", "--format=%H%x00%s", commit_range).split("\0")
    lines = ["## 변경 사항", ""]
    for index in range(0, len(changes) - 1, 2):
        sha, subject = changes[index:index + 2]
        lines.append("- " + escape_subject(subject) + " ([" + sha[:7] + "](" + REPOSITORY_URL + "/commit/" + sha + "))")
    if previous_tag:
        # 게시 전에도 확인할 수 있도록 태그 대신 검증한 대상 SHA를 비교 URL의 끝점으로 쓴다.
        lines.extend(["", "[이전 버전과 비교](" + REPOSITORY_URL + "/compare/" + previous_tag + "..." + commit + ")"])
    signing_text = {
        "ad-hoc": "Ad-hoc 서명 · Apple 공증 없음",
        "developer-id": "앱 Developer ID Application 서명 · 배포 파일 전체 공증 미완료",
        "notarized": "Developer ID Application 서명 · Apple 공증 및 티켓 부착 완료",
    }
    lines.extend([
        "", "## 배포 정보", "",
        "- 버전: `" + version + "` (빌드 `" + manifest["buildNumber"] + "`)",
        "- 대상 커밋: `" + commit + "`",
        "- 지원 환경: macOS " + manifest["minimumMacOS"] + " 이상 · Apple Silicon (`arm64`)",
        "- 서명: " + signing_text[manifest["signing"]],
        "", "| 파일 | SHA-256 |", "| --- | --- |",
    ])
    for artifact in manifest["artifacts"]:
        lines.append("| `" + artifact["name"] + "` | `" + artifact["sha256"] + "` |")
    lines.extend([
        "", "[설치·사용 안내](" + REPOSITORY_URL + "/blob/" + commit + "/README.md#시작하기) · "
        "[배포·검증 안내](" + REPOSITORY_URL + "/blob/" + commit + "/docs/releasing.md)",
    ])
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    version_parser = commands.add_parser("version", help="태그와 main 계보에서 버전 계산")
    version_parser.add_argument("--build-number", action="store_true", help="first-parent 커밋 개수를 출력")
    version_parser.add_argument("target", nargs="?", default="HEAD", help="대상 커밋 또는 태그")
    notes_parser = commands.add_parser("notes", help="검증된 패키지의 한국어 설명 생성")
    notes_parser.add_argument("version")
    notes_parser.add_argument("target")
    notes_parser.add_argument("directory", type=Path)
    arguments = parser.parse_args()
    try:
        if arguments.command == "version":
            commit = resolve_commit(arguments.target)
            print(build_number(commit) if arguments.build_number else release_version(commit))
        else:
            # 검증 실패 시 stdout에 부분적인 설명을 남기지 않는다.
            print(release_notes(arguments.version, arguments.target, arguments.directory), end="")
        return 0
    except (MetadataError, OSError, KeyError, TypeError) as error:
        print("릴리스 메타데이터 오류: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
