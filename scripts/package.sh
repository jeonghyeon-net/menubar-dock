#!/bin/bash
# 같은 번들로 ZIP과 DMG를 만들고 완성된 배포 폴더만 교체한다.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
if [ "${BUILD_ARCH:-arm64}" != arm64 ]; then
    printf 'BUILD_ARCH는 arm64만 지원합니다.\n' >&2
    exit 1
fi
task_version="$(python3 scripts/package_metadata.py version "${MENUBAR_VERSION:-$(./scripts/version.sh)}")"
task_build_number="$(./scripts/version.sh --build-number)"
task_commit="$(git rev-parse HEAD)"
task_build="${MENUBAR_BUILD_DIR:-$task_root/build}"
# 일반 패키지와 공개 릴리즈는 서로의 산출물 폴더를 교체하지 않는다.
task_dist="${MENUBAR_DIST_DIR:-$task_root/dist/packages/$task_version}"
if [ "${SKIP_BUILD:-0}" != 1 ]; then ./scripts/build-app.sh; fi
task_build="$(cd "$task_build" && pwd -P)"
task_app="$task_build/Menu Bar Dock.app"
# SKIP_BUILD도 요청 버전, 현재 커밋, arm64를 검사하여 오래된 바이너리의 이름만 바꾸지 않는다.
python3 scripts/package_metadata.py inspect "$task_app" --version "$task_version" --build-number "$task_build_number" --commit "$task_commit"
mkdir -p "$(dirname "$task_dist")"
task_dist="$(cd "$(dirname "$task_dist")" && pwd -P)/$(basename "$task_dist")"
python3 scripts/package_metadata.py check-output "$task_dist"
task_stage="$(mktemp -d "$(dirname "$task_dist")/.package.XXXXXX")"
cleanup() {
    if [ ! -e "$task_dist" ] && [ -d "$task_stage/previous" ]; then
        mv "$task_stage/previous" "$task_dist"
    fi
    rm -rf "$task_stage"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$task_stage/output" "$task_stage/image"
# 패키징 중 원본 앱이 바뀌어도 두 형식은 동일한 스냅샷을 담는다.
ditto "$task_app" "$task_stage/image/Menu Bar Dock.app"
task_snapshot="$task_stage/image/Menu Bar Dock.app"
python3 scripts/package_metadata.py inspect "$task_snapshot" --version "$task_version" --build-number "$task_build_number" --commit "$task_commit"
task_name="MenuBarDock-${task_version}-arm64"
ditto -c -k --sequesterRsrc --keepParent "$task_snapshot" "$task_stage/output/$task_name.zip"
ln -s /Applications "$task_stage/image/Applications"
hdiutil create -volname 'Menu Bar Dock' -srcfolder "$task_stage/image" -format UDZO "$task_stage/output/$task_name.dmg"
if [ -n "${SIGNING_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$task_stage/output/$task_name.dmg"
fi
python3 scripts/package_metadata.py write "$task_snapshot" "$task_stage/output"
python3 scripts/package_metadata.py verify "$task_stage/output"
if [ -e "$task_dist" ]; then mv "$task_dist" "$task_stage/previous"; fi
mv "$task_stage/output" "$task_dist"
printf '\n배포 파일: %s\n' "$task_dist"
