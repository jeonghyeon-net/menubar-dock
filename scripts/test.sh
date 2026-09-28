#!/bin/bash
# 일부 Command Line Tools 배포판은 Swift Testing 매크로 위치를 자동으로 전달하지 않는다.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
task_developer="$(xcode-select -p)"
task_plugin="$task_developer/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$task_plugin" ]; then
    # AppKit 테스트는 프로세스의 NSApplication·포커스를 공유하므로 suite 사이도 직렬 실행한다.
    swift test --no-parallel -Xswiftc -load-plugin-library -Xswiftc "$task_plugin" "$@"
else
    # macOS 기본 Bash 3에서는 nounset 상태의 빈 배열 확장이 오류가 된다.
    swift test --no-parallel "$@"
fi
