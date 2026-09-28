#!/bin/bash
# mise와 make, 릴리스에서 같은 검증 경로를 사용한다.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
./scripts/test-release-metadata.sh
./scripts/test-package-metadata.sh
./scripts/test-release-publish.sh
swift build -Xswiftc -warnings-as-errors
./scripts/test.sh
./scripts/check-status-input.sh
./scripts/check-settings-input.sh
./scripts/check-switcher-input.sh
