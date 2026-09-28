#!/bin/bash
# 서명된 앱을 ZIP/DMG로 묶는다. 공증은 서명 자격 증명이 있을 때 별도 수행한다.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
if [ "${SKIP_BUILD:-0}" != 1 ]; then ./scripts/build-app.sh; fi
codesign --verify --strict 'build/Menu Bar Dock.app'
mkdir -p dist
task_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Config/Info.plist)"
task_name="MenuBarDock-${task_version}-arm64"
ditto -c -k --sequesterRsrc --keepParent 'build/Menu Bar Dock.app' "dist/$task_name.zip"
task_stage="$(mktemp -d "${TMPDIR:-/tmp}/menubar-dock-package.XXXXXX")"
trap 'rm -rf "$task_stage"' EXIT
ditto 'build/Menu Bar Dock.app' "$task_stage/Menu Bar Dock.app"
ln -s /Applications "$task_stage/Applications"
hdiutil create -volname 'Menu Bar Dock' -srcfolder "$task_stage" -ov -format UDZO "dist/$task_name.dmg"
if [ -n "${SIGNING_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "dist/$task_name.dmg"
fi
shasum -a 256 "dist/$task_name.zip" "dist/$task_name.dmg" > dist/SHA256SUMS
printf '\n배포 파일: %s/dist\n' "$task_root"
