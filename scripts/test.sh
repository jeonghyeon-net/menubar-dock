#!/bin/bash
# 일부 Command Line Tools 배포판은 Swift Testing 매크로 위치를 자동으로 전달하지 않는다.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
task_developer="$(xcode-select -p)"
task_flags=()
task_plugin="$task_developer/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$task_plugin" ]; then
    task_flags=(-Xswiftc -load-plugin-library -Xswiftc "$task_plugin")
fi
swift test "${task_flags[@]}" "$@"
