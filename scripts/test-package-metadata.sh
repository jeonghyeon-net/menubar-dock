#!/bin/bash
# 실제 서명 도구가 필요 없는 배포 메타데이터 회귀 테스트다.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -p 'test_package_metadata.py'
