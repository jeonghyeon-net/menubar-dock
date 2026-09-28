#!/bin/bash
# Swift Package의 실행 파일과 리소스를 배포 가능한 앱 번들로 구성한다.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
task_config="${CONFIGURATION:-release}"
task_arch="${BUILD_ARCH:-arm64}"
if [ "$task_arch" != arm64 ]; then
    printf 'BUILD_ARCH는 arm64만 지원합니다.\n' >&2
    exit 1
fi
task_version="$(python3 scripts/package_metadata.py version "${MENUBAR_VERSION:-$(./scripts/version.sh)}")"
task_build_number="$(./scripts/version.sh --build-number)"
task_commit="$(git rev-parse HEAD)"
task_out="${MENUBAR_BUILD_DIR:-$task_root/build}"
mkdir -p "$task_out"
task_out="$(cd "$task_out" && pwd -P)"
task_destination="$task_out/Menu Bar Dock.app"
# 실행 중인 Mach-O를 덮어쓰면 지연 로드 시 서명 검증이 실패할 수 있다.
# 릴리즈는 별도 출력 폴더를 사용하며 개발 앱은 종료하거나 덮어쓰지 않는다.
check_destination_idle() {
    if /bin/ps -ww -axo comm= | /usr/bin/grep -Fx "$task_destination/Contents/MacOS/MenuBarDock" >/dev/null; then
        printf '해당 출력 폴더의 앱이 실행 중입니다. MENUBAR_BUILD_DIR로 다른 폴더를 지정해 주세요.\n' >&2
        exit 1
    fi
}
check_destination_idle
swift build -c "$task_config" --arch "$task_arch"
task_bin="$(swift build -c "$task_config" --arch "$task_arch" --show-bin-path)"
task_stage="$(mktemp -d "$task_out/.app-build.XXXXXX")"
cleanup() {
    # 교체 중 실패하거나 중단되면 이전 앱을 복구한다.
    if [ ! -e "$task_destination" ] && [ -d "$task_stage/previous.app" ]; then
        mv "$task_stage/previous.app" "$task_destination"
    fi
    rm -rf "$task_stage"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
task_app="$task_stage/Menu Bar Dock.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
cp "$task_bin/MenuBarDock" "$task_app/Contents/MacOS/MenuBarDock"
# 추적 중인 plist 대신 복사본에 버전과 소스 커밋을 기록한다.
python3 - Config/Info.plist "$task_app/Contents/Info.plist" "$task_version" "$task_build_number" "$task_commit" <<'PY'
import plistlib
import sys
from pathlib import Path
source, destination, version, build, commit = sys.argv[1:]
info = plistlib.loads(Path(source).read_bytes())
info.update(CFBundleShortVersionString=version, CFBundleVersion=build, MenuBarDockGitCommit=commit)
Path(destination).write_bytes(plistlib.dumps(info, sort_keys=False))
PY
printf 'APPL????' > "$task_app/Contents/PkgInfo"
# SwiftPM accessor가 Bundle.main.bundleURL 기준으로 찾는 dependency bundle도 함께 배치한다.
for task_bundle in "$task_bin"/*.bundle; do
    [ -d "$task_bundle" ] || continue
    ditto "$task_bundle" "$task_app/$(basename "$task_bundle")"
done
if [ ! -f "$task_out/AppIcon.icns" ] || [ scripts/make-icon.swift -nt "$task_out/AppIcon.icns" ]; then
    swift scripts/make-icon.swift "$task_out"
    iconutil -c icns "$task_out/AppIcon.iconset" -o "$task_out/AppIcon.icns"
fi
cp "$task_out/AppIcon.icns" "$task_app/Contents/Resources/AppIcon.icns"
if [ -n "${SIGNING_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$task_app"
else
    codesign --force --sign - --timestamp=none "$task_app"
fi
python3 scripts/package_metadata.py inspect "$task_app" --version "$task_version" --build-number "$task_build_number" --commit "$task_commit"
# 빌드 도중 사용자가 앱을 실행했을 가능성도 교체 직전에 확인한다.
check_destination_idle
if [ -e "$task_destination" ]; then mv "$task_destination" "$task_stage/previous.app"; fi
mv "$task_app" "$task_destination"
printf '\n앱 생성 완료: %s\n' "$task_destination"
