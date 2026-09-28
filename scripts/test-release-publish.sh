#!/bin/bash
# 실제 원격 호출 없이 게시 명령의 실패·재개·불변성 경계를 검사한다.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$task_root/scripts/test-release-publish.py" "$@"
