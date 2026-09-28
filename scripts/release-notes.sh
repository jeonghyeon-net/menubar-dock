#!/bin/bash
# 실제 배포 파일 검증이 끝난 뒤에만 한국어 릴리스 설명을 출력한다.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$task_root/scripts/release_metadata.py" notes "$@"
