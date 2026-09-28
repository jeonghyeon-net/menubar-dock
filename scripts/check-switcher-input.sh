#!/bin/bash
# 별도 AppKit 주 실행 루프에서 검색창의 실제 텍스트 입력과 키 이벤트를 검사한다.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/menubar-dock-switcher.XXXXXX")"
task_arch="$(uname -m)"
trap 'rm -rf "$task_build"' EXIT
task_flags=(-swift-version 6 -warnings-as-errors -target "$task_arch-apple-macos14.0")
xcrun swiftc "${task_flags[@]}" -emit-module -emit-library -module-name DockDomain \
    "$task_root"/Sources/DockDomain/*.swift \
    -emit-module-path "$task_build/DockDomain.swiftmodule" -o "$task_build/libDockDomain.dylib"
xcrun swiftc "${task_flags[@]}" -emit-module -emit-library -module-name DockShortcuts \
    "$task_root"/Sources/DockShortcuts/*.swift \
    -emit-module-path "$task_build/DockShortcuts.swiftmodule" -o "$task_build/libDockShortcuts.dylib"
xcrun swiftc "${task_flags[@]}" -emit-module -emit-library -module-name DockPlatform \
    -I "$task_build" -L "$task_build" -lDockDomain \
    "$task_root"/Sources/DockPlatform/*.swift \
    -emit-module-path "$task_build/DockPlatform.swiftmodule" -o "$task_build/libDockPlatform.dylib"
xcrun swiftc "${task_flags[@]}" -I "$task_build" -L "$task_build" -lDockDomain -lDockShortcuts -lDockPlatform \
    -Xlinker -rpath -Xlinker "$task_build" \
    "$task_root/Sources/MenuBarDock/UI/DockPresentationModel.swift" \
    "$task_root/Sources/MenuBarDock/UI/SwitcherController.swift" \
    "$task_root/Sources/MenuBarDock/UI/SwitcherSearchResultsView.swift" \
    "$task_root/scripts/check-switcher-input.swift" -o "$task_build/check-switcher-input"
"$task_build/check-switcher-input" "$@"
