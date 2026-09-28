#!/bin/bash
# Swift Package의 실행 파일과 리소스를 배포 가능한 앱 번들로 구성한다.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
task_config="${CONFIGURATION:-release}"
task_arch="${BUILD_ARCH:-arm64}"
task_out="$task_root/build"
task_destination="$task_out/Menu Bar Dock.app"
# 실행 중인 Mach-O를 덮어쓰면 지연 로드 시 서명 검증이 실패할 수 있다.
# 새 번들을 완성한 뒤 교체하며, 현재 앱이 실행 중이면 기존 번들을 보존한다.
if /bin/ps -ww -axo comm= | /usr/bin/grep -Fx "$task_destination/Contents/MacOS/MenuBarDock" >/dev/null; then
    printf 'Menu Bar Dock을 종료한 뒤 다시 빌드해 주세요. 실행 중인 앱은 덮어쓰지 않습니다.\n' >&2
    exit 1
fi
swift build -c "$task_config" --arch "$task_arch"
task_bin="$(swift build -c "$task_config" --arch "$task_arch" --show-bin-path)"
mkdir -p "$task_out"
task_stage="$(mktemp -d "$task_out/.app-build.XXXXXX")"
trap 'rm -rf "$task_stage"' EXIT
task_app="$task_stage/Menu Bar Dock.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
cp "$task_bin/MenuBarDock" "$task_app/Contents/MacOS/MenuBarDock"
cp Config/Info.plist "$task_app/Contents/Info.plist"
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
codesign --verify --strict "$task_app"
lipo "$task_app/Contents/MacOS/MenuBarDock" -verify_arch "$task_arch"
if [ -e "$task_destination" ]; then mv "$task_destination" "$task_stage/previous.app"; fi
if ! mv "$task_app" "$task_destination"; then
    if [ -d "$task_stage/previous.app" ]; then mv "$task_stage/previous.app" "$task_destination"; fi
    exit 1
fi
printf '\n앱 생성 완료: %s\n' "$task_destination"
