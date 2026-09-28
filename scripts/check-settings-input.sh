#!/bin/bash
# Swift Testing과 분리된 AppKit 주 실행 루프에서 실제 슬라이더 추적을 검사한다.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/menubar-dock-settings.XXXXXX")"
task_arch="$(uname -m)"
trap 'rm -rf "$task_build"' EXIT
task_flags=(-swift-version 6 -warnings-as-errors -target "$task_arch-apple-macos14.0")
task_binary="$task_build/check-settings-input"
if [ "${1:-}" = "--snapshot" ]; then
    # 실제 제품처럼 Bundle.main에서 현재 버전을 읽되 설정 저장 공간은 분리한다.
    task_app="$task_build/Settings Input Check.app"
    task_binary="$task_app/Contents/MacOS/check-settings-input"
    mkdir -p "$task_app/Contents/MacOS"
    task_version="$("$task_root/scripts/version.sh")"
    python3 - "$task_app/Contents/Info.plist" "$task_version" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "wb") as output:
    plistlib.dump({
        "CFBundleIdentifier": "net.jeonghyeon.MenuBarDock.SettingsInputCheck",
        "CFBundleExecutable": "check-settings-input",
        "CFBundleName": "Settings Input Check",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": sys.argv[2],
        "LSUIElement": True,
    }, output)
PY
fi
xcrun swiftc "${task_flags[@]}" -emit-module -emit-library -module-name DockDomain \
    "$task_root"/Sources/DockDomain/*.swift \
    -emit-module-path "$task_build/DockDomain.swiftmodule" -o "$task_build/libDockDomain.dylib"
xcrun swiftc "${task_flags[@]}" -emit-module -emit-library -module-name DockShortcuts \
    "$task_root"/Sources/DockShortcuts/*.swift \
    -emit-module-path "$task_build/DockShortcuts.swiftmodule" -o "$task_build/libDockShortcuts.dylib"
xcrun swiftc "${task_flags[@]}" -I "$task_build" -L "$task_build" -lDockDomain -lDockShortcuts \
    -Xlinker -rpath -Xlinker "$task_build" \
    "$task_root/Sources/MenuBarDock/UI/DockPresentationModel.swift" \
    "$task_root/Sources/MenuBarDock/UI/SettingsWindowController.swift" \
    "$task_root/scripts/check-settings-input.swift" -o "$task_binary"
if [ "$#" -gt 0 ]; then
    "$task_binary" "$@"
else
    "$task_binary"
    "$task_binary" --spacing
fi
