#!/bin/bash
# 명시적으로 실행한 경우에만 로컬 검증과 GitHub 릴리스 게시를 수행한다.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$task_root/scripts/release.py" "$@"
