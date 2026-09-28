#!/bin/bash
# 사용자의 keychain profile을 사용하므로 저장소에 인증 정보를 기록하지 않는다.
set -euo pipefail
: "${NOTARY_PROFILE:?NOTARY_PROFILE keychain profile을 지정하세요}"
: "${SIGNING_IDENTITY:?Developer ID Application 서명을 지정하세요}"
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
./scripts/package.sh
task_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Config/Info.plist)"
task_dmg="dist/MenuBarDock-${task_version}-arm64.dmg"
task_zip="dist/MenuBarDock-${task_version}-arm64.zip"
# ZIP으로 앱을 먼저 공증하고 앱에 ticket을 붙인 뒤 두 배포 형식을 다시 만든다.
xcrun notarytool submit "$task_zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple 'build/Menu Bar Dock.app'
xcrun stapler validate 'build/Menu Bar Dock.app'
spctl --assess --type execute -v 'build/Menu Bar Dock.app'
SKIP_BUILD=1 ./scripts/package.sh
xcrun notarytool submit "$task_dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$task_dmg"
xcrun stapler validate "$task_dmg"
spctl --assess --type open --context context:primary-signature -v "$task_dmg"
shasum -a 256 dist/*.zip dist/*.dmg > dist/SHA256SUMS
