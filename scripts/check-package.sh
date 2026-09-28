#!/bin/bash
# 실제 다운로드 파일에서 앱을 꺼내 검증한다. 사용자 앱과 설정은 변경하지 않는다.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
task_dist="${1:-${MENUBAR_DIST_DIR:-}}"
if [ -z "$task_dist" ]; then
    task_version="$(python3 scripts/package_metadata.py version "${MENUBAR_VERSION:-$(./scripts/version.sh)}")"
    task_dist="$task_root/dist/packages/$task_version"
fi
task_dist="$(cd "$task_dist" && pwd -P)"
python3 scripts/package_metadata.py verify "$task_dist"
task_name="$(python3 - "$task_dist/release-manifest.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as stream:
    manifest = json.load(stream)
print('MenuBarDock-' + manifest['version'] + '-arm64')
PY
)"
task_signing="$(python3 - "$task_dist/release-manifest.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as stream:
    print(json.load(stream)['signing'])
PY
)"
task_stage="$(mktemp -d "${TMPDIR:-/tmp}/menubar-dock-check.XXXXXX")"
task_mounted=0
cleanup() {
    task_status=$?
    if [ "$task_mounted" = 1 ]; then
        if ! hdiutil detach "$task_stage/mount" >/dev/null; then
            printf 'DMG 마운트 해제에 실패했습니다: %s\n' "$task_stage/mount" >&2
            # 마운트가 남은 폴더는 삭제하지 않는다.
            exit 1
        fi
    fi
    rm -rf "$task_stage"
    exit "$task_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
python3 scripts/package_metadata.py zip "$task_dist/$task_name.zip"
mkdir -p "$task_stage/zip" "$task_stage/mount"
ditto -x -k "$task_dist/$task_name.zip" "$task_stage/zip"
python3 scripts/package_metadata.py inspect "$task_stage/zip/Menu Bar Dock.app" --manifest-directory "$task_dist"
python3 scripts/package_metadata.py self-test "$task_stage/zip/Menu Bar Dock.app"
if [ "$task_signing" != ad-hoc ]; then
    codesign --verify --strict "$task_dist/$task_name.dmg"
fi
if [ "$task_signing" = notarized ]; then
    xcrun stapler validate "$task_dist/$task_name.dmg"
    spctl --assess --type execute -v "$task_stage/zip/Menu Bar Dock.app"
    spctl --assess --type open --context context:primary-signature -v "$task_dist/$task_name.dmg"
fi
hdiutil verify "$task_dist/$task_name.dmg" >/dev/null
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$task_stage/mount" "$task_dist/$task_name.dmg" >/dev/null
task_mounted=1
if [ ! -L "$task_stage/mount/Applications" ] || [ "$(readlink "$task_stage/mount/Applications")" != /Applications ]; then
    printf 'DMG의 Applications 설치 링크가 올바르지 않습니다.\n' >&2
    exit 1
fi
python3 scripts/package_metadata.py inspect "$task_stage/mount/Menu Bar Dock.app" --manifest-directory "$task_dist"
python3 scripts/package_metadata.py self-test "$task_stage/mount/Menu Bar Dock.app"
# ZIP과 DMG 앱의 파일/서명 리소스가 같은지 확인한다.
diff -rq "$task_stage/zip/Menu Bar Dock.app" "$task_stage/mount/Menu Bar Dock.app"
printf 'ZIP·DMG 실제 번들, 서명, 버전, 리소스, 자체 진단 검증 통과\n'
