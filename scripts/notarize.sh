#!/bin/bash
# 공증이 모두 성공한 배포 폴더만 공개 후보로 교체한다. 인증 정보는 keychain에 둔다.
set -euo pipefail
: "${NOTARY_PROFILE:?NOTARY_PROFILE keychain profile을 지정하세요}"
: "${SIGNING_IDENTITY:?Developer ID Application 서명을 지정하세요}"
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
task_build="${MENUBAR_BUILD_DIR:-$task_root/build}"
task_version="$(python3 scripts/package_metadata.py version "${MENUBAR_VERSION:-$(./scripts/version.sh)}")"
task_dist="${MENUBAR_DIST_DIR:-$task_root/dist/packages/$task_version}"
mkdir -p "$(dirname "$task_dist")"
task_dist="$(cd "$(dirname "$task_dist")" && pwd -P)/$(basename "$task_dist")"
task_stage="$(mktemp -d "$(dirname "$task_dist")/.notarize.XXXXXX")"
cleanup() {
    if [ ! -e "$task_dist" ] && [ -d "$task_stage/previous" ]; then
        mv "$task_stage/previous" "$task_dist"
    fi
    rm -rf "$task_stage"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
MENUBAR_DIST_DIR="$task_stage/output" ./scripts/package.sh
task_build="$(cd "$task_build" && pwd -P)"
task_app="$task_build/Menu Bar Dock.app"
task_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$task_app/Contents/Info.plist")"
task_name="MenuBarDock-${task_version}-arm64"
# 실제 Developer ID 서명 여부는 inspect 단계에서 검증되며 ad-hoc은 공증할 수 없다.
python3 - "$task_stage/output/release-manifest.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as stream:
    if json.load(stream)['signing'] == 'ad-hoc':
        raise SystemExit('공증에는 Developer ID Application 서명이 필요합니다.')
PY
xcrun notarytool submit "$task_stage/output/$task_name.zip" --keychain-profile "$NOTARY_PROFILE" --wait
if /bin/ps -ww -axo comm= | /usr/bin/grep -Fx "$task_app/Contents/MacOS/MenuBarDock" >/dev/null; then
    printf '실행 중인 앱에는 공증 ticket을 쓰지 않습니다. 별도 MENUBAR_BUILD_DIR를 지정하세요.\n' >&2
    exit 1
fi
xcrun stapler staple "$task_app"
xcrun stapler validate "$task_app"
spctl --assess --type execute -v "$task_app"
# 앱에 공증 ticket을 붙인 뒤 ZIP과 DMG를 함께 다시 만든다.
MENUBAR_DIST_DIR="$task_stage/output" SKIP_BUILD=1 ./scripts/package.sh
xcrun notarytool submit "$task_stage/output/$task_name.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$task_stage/output/$task_name.dmg"
xcrun stapler validate "$task_stage/output/$task_name.dmg"
spctl --assess --type open --context context:primary-signature -v "$task_stage/output/$task_name.dmg"
# DMG ticket이 해시를 바꾸므로 마지막 결과물로 manifest와 SHA256SUMS를 다시 만든다.
python3 scripts/package_metadata.py write "$task_app" "$task_stage/output"
./scripts/check-package.sh "$task_stage/output"
# 다른 자료가 든 사용자 폴더를 배포 산출물로 덮어쓰지 않는다.
python3 scripts/package_metadata.py check-output "$task_dist"
if [ -e "$task_dist" ]; then mv "$task_dist" "$task_stage/previous"; fi
mv "$task_stage/output" "$task_dist"
printf '공증된 배포 파일: %s\n' "$task_dist"
