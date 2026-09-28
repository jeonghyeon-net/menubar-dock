#!/bin/bash
# 실제 UI 소스를 별도 컴파일해 AppKit 주 실행 루프에서 메뉴 막대 클릭을 검증한다.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/menubar-dock-input.XXXXXX")"
task_arch="$(uname -m)"
trap 'rm -rf "$task_build"' EXIT
task_flags=(-swift-version 6 -warnings-as-errors -target "$task_arch-apple-macos14.0")
xcrun swiftc "${task_flags[@]}" -emit-module -emit-library -module-name DockDomain \
    "$task_root"/Sources/DockDomain/*.swift \
    -emit-module-path "$task_build/DockDomain.swiftmodule" -o "$task_build/libDockDomain.dylib"
xcrun swiftc "${task_flags[@]}" -emit-module -emit-library -module-name DockShortcuts \
    "$task_root"/Sources/DockShortcuts/*.swift \
    -emit-module-path "$task_build/DockShortcuts.swiftmodule" -o "$task_build/libDockShortcuts.dylib"
xcrun swiftc "${task_flags[@]}" -I "$task_build" -L "$task_build" -lDockDomain -lDockShortcuts \
    -Xlinker -rpath -Xlinker "$task_build" \
    "$task_root/Sources/MenuBarDock/UI/DockPresentationModel.swift" \
    "$task_root/Sources/MenuBarDock/UI/StatusItemController.swift" \
    "$task_root/scripts/check-status-input.swift" -o "$task_build/check-status-input"
"$task_build/check-status-input"
