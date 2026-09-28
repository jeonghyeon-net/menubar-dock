#!/bin/bash
# 임시 Git 저장소와 가짜 배포 파일만 사용하므로 현재 태그·패키지는 바꾸지 않는다.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$task_root/scripts/test-release-metadata.py" "$@"
