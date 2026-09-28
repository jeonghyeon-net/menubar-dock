#!/usr/bin/env python3
"""배포 번들의 실제 메타데이터와 다운로드 파일의 무결성을 검증한다."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import stat
import zipfile
import sys

VERSION_PATTERN = re.compile(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\Z")
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}\Z")
HASH_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
SIGNING_STATES = {"ad-hoc", "developer-id", "notarized"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True, check=False)
    require(result.returncode == 0, f"명령 실패 ({args[0]}): {(result.stderr or result.stdout).strip()}")
    return result.stdout.strip(), result.stderr.strip()


def validate_version(version):
    require(isinstance(version, str) and VERSION_PATTERN.fullmatch(version), "버전은 X.Y.Z 형식이어야 합니다.")
    return version


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def has_notarization_ticket(path):
    ticket = subprocess.run(["/usr/bin/xcrun", "stapler", "validate", str(path)], capture_output=True, text=True)
    return ticket.returncode == 0


def inspect_bundle(app):
    """표시용 파일명이 아니라 서명된 번들 안의 값을 기준으로 판단한다."""
    app = Path(app)
    require(app.is_dir() and not app.is_symlink(), f"앱 번들을 찾을 수 없습니다: {app}")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    version = validate_version(info.get("CFBundleShortVersionString"))
    build = info.get("CFBundleVersion")
    commit = info.get("MenuBarDockGitCommit")
    require(isinstance(build, str) and re.fullmatch(r"[1-9]\d*", build), "앱 빌드 번호가 없거나 잘못되었습니다. 다시 빌드하세요.")
    require(isinstance(commit, str) and COMMIT_PATTERN.fullmatch(commit), "앱의 Git 커밋 정보가 없습니다. 다시 빌드하세요.")
    require(info.get("CFBundleIdentifier") == "net.jeonghyeon.MenuBarDock", "다른 앱의 번들은 배포할 수 없습니다.")
    require(info.get("CFBundleExecutable") == "MenuBarDock", "앱 실행 파일명이 잘못되었습니다.")
    minimum = info.get("LSMinimumSystemVersion")
    require(isinstance(minimum, str) and re.fullmatch(r"\d+\.\d+(?:\.\d+)?", minimum), "최소 macOS 버전이 없습니다.")
    binary = app / "Contents/MacOS/MenuBarDock"
    architecture, _ = run("/usr/bin/lipo", "-archs", str(binary))
    require(architecture == "arm64", f"arm64 단일 아키텍처 앱만 지원합니다: {architecture}")
    require((app / "Contents/Resources/AppIcon.icns").is_file(), "앱 아이콘 리소스가 없습니다.")
    run("/usr/bin/codesign", "--verify", "--strict", str(app))
    _, signature = run("/usr/bin/codesign", "-dvvv", str(app))
    if "Signature=adhoc" in signature:
        signing = "ad-hoc"
    else:
        require("Authority=Developer ID Application:" in signature, "배포는 Developer ID Application 또는 ad-hoc 서명만 지원합니다.")
        signing = "notarized" if has_notarization_ticket(app) else "developer-id"
    return dict(version=version, buildNumber=build, commit=commit, architecture=architecture,
                minimumMacOS=minimum, signing=signing)


def compare_bundle(metadata, version=None, build=None, commit=None, manifest=None):
    for field, expected in (("version", version), ("buildNumber", build), ("commit", commit)):
        if expected is not None:
            require(metadata[field] == expected, f"앱 {field} 불일치: {metadata[field]} (요청: {expected}). 다시 빌드하세요.")
    if manifest:
        for field in ("version", "buildNumber", "commit", "architecture", "minimumMacOS"):
            require(metadata[field] == manifest[field], f"번들/manifest의 {field} 값이 일치하지 않습니다.")
        # 배포 전체의 공증이 끝나기 전에도 내부 앱의 공증은 완료되어 있을 수 있다.
        permitted_signing = {
            "ad-hoc": {"ad-hoc"},
            "developer-id": {"developer-id", "notarized"},
            "notarized": {"notarized"},
        }
        require(metadata["signing"] in permitted_signing[manifest["signing"]],
                "번들/manifest의 signing 값이 일치하지 않습니다.")


def write_metadata(app, directory):
    directory = Path(directory)
    metadata = inspect_bundle(app)
    basename = f"MenuBarDock-{metadata['version']}-{metadata['architecture']}"
    artifacts = []
    for extension in ("zip", "dmg"):
        name = f"{basename}.{extension}"
        path = directory / name
        require(path.is_file() and not path.is_symlink(), f"배포 파일이 없습니다: {name}")
        artifacts.append(dict(name=name, sha256=digest(path), bytes=path.stat().st_size))
    # 공증된 앱을 다시 패키징하면 새 DMG에는 ticket이 없으므로 전체 공증으로 표시하지 않는다.
    if metadata["signing"] == "notarized" and not has_notarization_ticket(directory / f"{basename}.dmg"):
        metadata["signing"] = "developer-id"
    manifest = dict(schemaVersion=1, **metadata, artifacts=artifacts)
    (directory / "release-manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    # 내려받은 폴더에서 shasum -c로 검증할 수 있도록 경로를 넣지 않는다.
    (directory / "SHA256SUMS").write_text("".join(f"{item['sha256']}  {item['name']}\n" for item in artifacts))
    return manifest


def verify_metadata(directory):
    directory = Path(directory)
    for filename in ("release-manifest.json", "SHA256SUMS"):
        require((directory / filename).is_file() and not (directory / filename).is_symlink(), f"배포 메타데이터가 없습니다: {filename}")
    manifest = json.loads((directory / "release-manifest.json").read_text())
    required = {"schemaVersion", "version", "buildNumber", "commit", "architecture", "minimumMacOS", "signing", "artifacts"}
    require(isinstance(manifest, dict) and set(manifest) == required, "배포 manifest 필드가 누락되었거나 알 수 없는 필드가 있습니다.")
    require(type(manifest["schemaVersion"]) is int and manifest["schemaVersion"] == 1, "지원하지 않는 배포 manifest 형식입니다.")
    validate_version(manifest["version"])
    require(isinstance(manifest["buildNumber"], str) and re.fullmatch(r"[1-9]\d*", manifest["buildNumber"]), "잘못된 빌드 번호입니다.")
    require(isinstance(manifest["commit"], str) and COMMIT_PATTERN.fullmatch(manifest["commit"]), "잘못된 Git 커밋입니다.")
    require(manifest["architecture"] == "arm64", "arm64 배포만 지원합니다.")
    require(isinstance(manifest["minimumMacOS"], str) and re.fullmatch(r"\d+\.\d+(?:\.\d+)?", manifest["minimumMacOS"]), "잘못된 최소 macOS 버전입니다.")
    require(isinstance(manifest["signing"], str) and manifest["signing"] in SIGNING_STATES, "잘못된 서명 상태입니다.")
    artifacts = manifest["artifacts"]
    require(isinstance(artifacts, list) and len(artifacts) == 2, "ZIP과 DMG 두 배포 파일이 필요합니다.")
    names = [f"MenuBarDock-{manifest['version']}-arm64.{extension}" for extension in ("zip", "dmg")]
    checksums = []
    for artifact, expected in zip(artifacts, names):
        require(isinstance(artifact, dict) and set(artifact) == {"name", "sha256", "bytes"}, "잘못된 배포 파일 메타데이터입니다.")
        require(artifact["name"] == expected, f"배포 파일명 불일치: {expected}")
        require(isinstance(artifact["sha256"], str) and HASH_PATTERN.fullmatch(artifact["sha256"]), "잘못된 SHA-256입니다.")
        require(type(artifact["bytes"]) is int and artifact["bytes"] > 0, "잘못된 배포 파일 크기입니다.")
        path = directory / expected
        require(path.is_file() and not path.is_symlink(), f"배포 파일이 없습니다: {expected}")
        require(path.stat().st_size == artifact["bytes"], f"배포 파일 크기 불일치: {expected}")
        require(digest(path) == artifact["sha256"], f"배포 파일 SHA-256 불일치: {expected}")
        checksums.append(f"{artifact['sha256']}  {expected}\n")
    require((directory / "SHA256SUMS").read_text() == "".join(checksums), "SHA256SUMS가 manifest와 일치하지 않거나 상대 파일명 형식이 아닙니다.")
    require({path.name for path in directory.iterdir() if path.suffix in (".zip", ".dmg")} == set(names), "다른 버전의 배포 파일이 섞여 있습니다.")
    return manifest




def check_output_directory(path):
    """기존 배포 산출물만 있는 폴더를 교체하여 사용자 자료를 보존한다."""
    path = Path(path)
    require(path.name not in ("", ".", "..") and not path.is_symlink(), "안전한 배포 출력 폴더를 지정하세요.")
    if not path.exists():
        return
    require(path.is_dir(), "배포 출력 경로가 폴더가 아닙니다.")
    for item in path.iterdir():
        allowed = item.name in ("SHA256SUMS", "release-manifest.json", "release-notes.md") or re.fullmatch(
            r"MenuBarDock-\d+\.\d+\.\d+-arm64\.(zip|dmg)", item.name)
        require(allowed and item.is_file() and not item.is_symlink(),
                f"배포 폴더에 다른 자료가 있습니다. 별도 MENUBAR_DIST_DIR를 지정하세요: {item.name}")


def verify_zip(path):
    """풀기 전에 경로 이탈과 외부를 가리키는 심볼릭 링크를 거부한다."""
    with zipfile.ZipFile(path) as archive:
        require(archive.testzip() is None, "ZIP 데이터가 손상되었습니다.")
        for member in archive.infolist():
            parts = Path(member.filename).parts
            require(parts and parts[0] in ("Menu Bar Dock.app", "__MACOSX") and ".." not in parts,
                    f"ZIP에 허용하지 않는 경로가 있습니다: {member.filename}")
            if stat.S_ISLNK(member.external_attr >> 16):
                target = archive.read(member).decode("utf-8")
                resolved = os.path.normpath(os.path.join(os.path.dirname(member.filename), target))
                require(not os.path.isabs(target) and resolved.startswith(parts[0] + "/"),
                        f"ZIP 링크가 번들 밖을 가리킵니다: {member.filename}")


def self_test(app):
    result = subprocess.run([str(Path(app) / "Contents/MacOS/MenuBarDock"), "--self-test"],
                            capture_output=True, text=True, timeout=20)
    require(result.returncode == 0, f"패키지 내부 앱 자체 진단 실패: {result.stderr or result.stdout}")
    report = json.loads(result.stdout)
    require(isinstance(report, dict) and bool(report) and all(value is True for value in report.values()),
            "패키지 내부 앱 리소스 진단이 실패했습니다.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    version = commands.add_parser("version")
    version.add_argument("value")
    inspect = commands.add_parser("inspect")
    inspect.add_argument("app")
    inspect.add_argument("--version")
    inspect.add_argument("--build-number")
    inspect.add_argument("--commit")
    inspect.add_argument("--manifest-directory")
    write = commands.add_parser("write")
    write.add_argument("app")
    write.add_argument("directory")
    verify = commands.add_parser("verify")
    verify.add_argument("directory")
    output = commands.add_parser("check-output")
    output.add_argument("directory")
    zip_check = commands.add_parser("zip")
    zip_check.add_argument("path")
    check = commands.add_parser("self-test")
    check.add_argument("app")
    args = parser.parse_args()
    if args.command == "version":
        print(validate_version(args.value))
    elif args.command == "inspect":
        metadata = inspect_bundle(args.app)
        manifest = verify_metadata(args.manifest_directory) if args.manifest_directory else None
        compare_bundle(metadata, args.version, args.build_number, args.commit, manifest)
        print(json.dumps(metadata, ensure_ascii=False))
    elif args.command == "check-output":
        check_output_directory(args.directory)
    elif args.command == "zip":
        verify_zip(args.path)
    elif args.command == "self-test":
        self_test(args.app)
    elif args.command == "write":
        write_metadata(args.app, args.directory)
    else:
        verify_metadata(args.directory)
        print("배포 manifest·SHA-256 검증 통과")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, plistlib.InvalidFileException, zipfile.BadZipFile, subprocess.TimeoutExpired) as error:
        print(f"오류: {error}", file=sys.stderr)
        sys.exit(1)
