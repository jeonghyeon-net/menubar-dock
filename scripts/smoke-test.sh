#!/bin/bash
# 실제 AppKit 실행 루프의 시작·최종 저장·종료를 시간 제한 안에 검증한다.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
task_dir="$(mktemp -d "${TMPDIR:-/tmp}/menubar-dock-smoke.XXXXXX")"
task_pid=''
cleanup() {
    if [ -n "$task_pid" ]; then kill "$task_pid" 2>/dev/null || true; fi
    rm -rf "$task_dir"
}
trap cleanup EXIT
'build/Menu Bar Dock.app/Contents/MacOS/MenuBarDock' --smoke-test --data-directory "$task_dir" > "$task_dir/run.log" 2>&1 &
task_pid=$!
for task_second in {1..20}; do
    if ! kill -0 "$task_pid" 2>/dev/null; then break; fi
    sleep 1
done
if kill -0 "$task_pid" 2>/dev/null; then
    cat "$task_dir/run.log"
    printf '앱 시작/저장/종료가 20초 안에 완료되지 않았습니다.\n' >&2
    exit 1
fi
wait "$task_pid"
task_pid=''
cat "$task_dir/run.log"
grep -q 'SMOKE: started=true' "$task_dir/run.log"
test -s "$task_dir/preferences.json"
test -s "$task_dir/preferences.backup.json"
printf '실제 앱 시작·저장·정상 종료 검증 통과\n'
