#!/bin/bash
# 작업 트리의 수동 버전 수정 대신 대상 커밋의 태그와 main 계보에서 버전을 계산한다.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$task_root/scripts/release_metadata.py" version "$@"
