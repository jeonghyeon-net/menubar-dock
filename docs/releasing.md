# 빌드와 릴리스

앱 설치는 [시작하기](../README.md#시작하기), 소스 빌드는 [개발 안내](../CONTRIBUTING.md#소스에서-빌드하고-실행)를 따릅니다. 내려받은 파일의 [체크섬 확인](#다운로드-파일-확인선택)은 선택 사항입니다.

릴리스는 로컬 Mac에서 명시적으로 실행합니다. `main`을 커밋·푸시한 뒤 `mise run release`를 실행하면 검사, 패키징, 한국어 릴리스 노트, Git 태그, GitHub Release 게시를 순서대로 수행합니다. 일반 커밋·푸시로는 릴리스가 시작되지 않습니다.

## 준비

- Apple Silicon Mac, macOS 14 이상, 로그인된 데스크톱 세션
- Swift 6.2 이상의 Xcode 또는 Command Line Tools
- Python 3.9 이상: 버전·배포 메타데이터와 게시 도구에 사용하며 앱에는 포함하지 않음
- Git 전체 이력과 인증된 [GitHub CLI](https://cli.github.com/)
- [mise](https://mise.jdx.dev/) 또는 Make

```sh
mise trust
mise run toolchain
gh auth status --hostname github.com
```

서명 인증서는 선택 사항입니다. 인증서를 지정하지 않으면 ad-hoc 서명으로 만들고, 릴리스 본문에 Developer ID 서명·Apple 공증이 없음을 표시합니다.

## 명령

| 명령 | 동작 |
| --- | --- |
| `mise run version` | 현재 커밋의 릴리스 버전 계산 |
| `mise run version -- --build-number` | 앱 빌드 번호 계산 |
| `mise run release-test` | 임시 Git 이력·배포 파일로 버전, 노트, 무결성, 게시 실패 경로 검사 |
| `mise run check` | 릴리스 도구, Swift 빌드·테스트, 실제 AppKit 입력 검사 |
| `mise run package-test` | 개발용 패키지 생성과 ZIP·DMG 실제 내용 검사 |
| `mise run release-plan` | 버전·원격·작업 상태 확인. 빌드·태그·게시 없음 |
| `mise run release-prepare` | 전체 검사, 격리된 릴리스 빌드, 패키지, 노트 생성. 태그·게시 없음 |
| `mise run release` | 전체 검증 후 태그·첨부 파일·한국어 노트 게시 |
| `mise run release-notes -- <버전> <커밋> <배포 폴더>` | 검증된 파일로 릴리스 본문 출력 |

Make에서도 `make version`, `make release-test`, `make package-test`, `make release-plan`, `make release-prepare`, `make release`를 사용할 수 있습니다. 두 진입점은 같은 스크립트를 호출합니다.

## 버전 규칙

[버전 계산기](../scripts/version.sh)는 현재 커밋에서 첫 번째 부모를 따라 이어지는 이력의 정식 `vX.Y.Z` 태그를 기준으로 합니다.

1. 대상 커밋에 정식 태그가 있으면 그 버전을 사용합니다.
2. 대상에 태그가 없으면 해당 이력의 가장 높은 버전에서 패치 번호를 1 올립니다.
3. 정식 태그가 하나도 없으면 대상 커밋의 `Config/Info.plist`에 있는 초기 버전 `1.0.3`을 사용합니다.

한 커밋의 여러 정식 버전 태그, 얕은 Git 복제, 범위를 넘는 버전 숫자는 거부합니다. 다른 계보의 태그나 미리 보기 태그는 다음 버전에 영향을 주지 않습니다. 현재는 정식 패치 릴리스만 자동 증가합니다.

빌드 번호는 첫 번째 부모를 따라 센 커밋 수입니다. 빌드할 때 앱 복사본의 `CFBundleShortVersionString`, `CFBundleVersion`, `MenuBarDockGitCommit`을 채우므로 추적 중인 `Config/Info.plist`를 매번 수정하지 않습니다. 앱의 버전 표시, 패키지 파일명, manifest와 릴리스 태그는 같은 계산값을 사용합니다.

## 배포 패키지 생성과 필수 검증

`mise run package`는 기본적으로 `build/`에 앱을, `dist/packages/<버전>/`에 다음 파일을 만듭니다. 아래 `1.0.3`은 첫 릴리스의 예시입니다.

```text
build/Menu Bar Dock.app
dist/packages/1.0.3/MenuBarDock-1.0.3-arm64.zip
dist/packages/1.0.3/MenuBarDock-1.0.3-arm64.dmg
dist/packages/1.0.3/SHA256SUMS
dist/packages/1.0.3/release-manifest.json
```

ZIP과 DMG는 같은 앱 스냅샷을 담습니다. DMG에는 `Applications` 바로가기가 있습니다. `SHA256SUMS`에는 각 배포 파일의 SHA-256과 파일명을 기록합니다.

`release-manifest.json`은 버전, 빌드 번호, 대상 Git 커밋, 아키텍처, 최소 macOS 버전, 실제 서명 상태, 각 파일의 크기와 SHA-256을 기록합니다. 파일명만 바꿔 오래된 앱을 새 버전으로 게시하지 못하도록 앱 내부 정보도 대조합니다.

[패키지 검사](../scripts/check-package.sh)는 ZIP을 임시 폴더에 풀고 DMG를 읽기 전용으로 마운트합니다. 두 번들의 서명·버전·커밋·arm64·리소스·자체 진단과 파일 일치를 검사한 뒤 마운트를 해제합니다. 잘못된 체크섬, 다른 버전의 파일 혼합, 번들 밖을 가리키는 ZIP 경로를 거부합니다.

배포자는 두 패키지의 무결성과 내용을 모두 검증해야 합니다. `mise run package-test`는 이 검사를 실행하며, `release-prepare`와 `release`도 같은 검사를 포함합니다. 일반 사용자의 선택적 체크섬 확인과 관계없이 게시 전 검증은 필수입니다.

릴리스 명령은 실행 중인 개발 앱을 교체하지 않도록 `build/release-<버전>/`와 `dist/releases/<버전>/`를 사용합니다. 일반 빌드·패키지의 출력은 `MENUBAR_BUILD_DIR`와 `MENUBAR_DIST_DIR`로 지정할 수 있습니다. 일반 패키지는 출력 폴더에 다른 사용자 자료가 있으면 교체하지 않습니다. 릴리스와 다른 빌드를 같은 작업 디렉터리에서 동시에 실행하지 마세요.

## 게시 절차

변경 사항과 [변경 기록](../CHANGELOG.md)을 검토하고 `main`에 커밋·푸시합니다. 그다음 작업 디렉터리가 깨끗한 상태에서 실행합니다.

```sh
mise run release-plan
mise run release-prepare
```

`dist/releases/<버전>/release-notes.md`와 배포 파일을 검토한 뒤 게시합니다.

```sh
mise run release
```

게시 명령은 다음 순서를 따릅니다.

1. 브랜치가 `main`인지, 미커밋·미추적 파일이 없는지, origin의 읽기·푸시 주소가 이 저장소인지 확인합니다.
2. 원격 `main`·태그를 가져와 현재 커밋과 비교하고, GitHub 인증과 같은 버전의 기존 릴리스를 확인합니다.
3. 전체 로컬 검사와 arm64 Release 빌드, ZIP·DMG 검사, 실제 시작·설정 저장·정상 종료 검사를 수행합니다.
4. 실제 커밋 범위로 한국어 본문을 생성합니다. 제목은 `vX.Y.Z`만 사용하고 본문에 대상 커밋·파일별 SHA-256·서명 상태를 넣습니다.
5. 대상 커밋에 주석 태그를 만들고 푸시한 뒤 GitHub에 초안을 만듭니다.
6. ZIP, DMG, `SHA256SUMS`, `release-manifest.json`을 첨부합니다. 파일을 다시 내려받아 로컬 파일과 바이트 단위로 비교합니다.
7. 커밋·태그·초안 상태를 다시 확인하고 정식 릴리스로 공개합니다. 이때 최신 릴리스로 지정되어 앱의 업데이트 확인에서도 조회할 수 있습니다.

이미 게시된 버전은 첨부 파일을 내려받아 검증한 뒤 종료합니다. 기존 태그를 이동하거나 공개된 바이너리를 교체하지 않습니다. 업로드 실패로 남은 초안은 로컬 배포 폴더를 유지하고 같은 명령을 다시 실행하면 이어갑니다. 기존 첨부 파일과 로컬 파일이 다르거나 로컬 원본을 잃었다면 덮어쓰지 않고 중단합니다.

생성·업로드·공개 명령이 성공해도 GitHub 조회에 반영되는 데 시간이 걸릴 수 있습니다. 이때만 즉시 조회와 1초 간격의 추가 조회 3회로 상태를 확인합니다. 쓰기 명령 자체는 반복하지 않습니다. 조회 오류나 릴리스 ID 변경, 예상 밖 첨부 파일은 즉시 중단하며, 제한 시간 안에 확인되지 않으면 초안과 파일을 보존합니다. 같은 커밋에서 명령을 다시 실행해 이어갈 수 있습니다.

공개된 릴리스의 설명만 고칠 때는 해당 버전의 첨부 파일을 새 임시 폴더로 내려받아 `release-notes`로 본문을 생성합니다. 패키지를 다시 빌드하지 말고 `gh release edit --title <태그> --notes-file <본문 파일>`로 제목·본문만 수정합니다.

## 서명과 공증

Developer ID Application 인증서와 `notarytool` 키체인 프로필이 준비되어 있다면 다음처럼 실행합니다.

```sh
export SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
export NOTARY_PROFILE='menubar-dock-notary'
mise run release
```

`SIGNING_IDENTITY`만 지정하면 Developer ID로 서명합니다. `NOTARY_PROFILE`도 지정하면 앱을 Apple에 제출해 공증 티켓을 붙인 뒤 ZIP·DMG를 다시 만들고, DMG도 공증합니다. 최종 티켓이 포함된 파일로 체크섬과 manifest를 다시 생성합니다. 티켓·서명·Gatekeeper 검사에 실패하면 게시하지 않습니다.

`mise run notarize`로 게시 없이 서명·공증된 패키지만 만들 수도 있습니다. 자격 증명은 사용자 키체인에 보관하고 저장소와 로그에는 기록하지 않습니다. 공증을 수행하지 않은 파일을 공증 완료로 표시하지 않습니다.

## 다운로드 파일 확인(선택)

체크섬 확인은 설치에 필요한 단계가 아닙니다. 다운로드한 파일의 무결성을 직접 확인하려는 경우에만 사용합니다. DMG로 설치한다면 ZIP이나 `release-manifest.json`을 추가로 받을 필요가 없습니다.

내려받은 DMG와 **같은 릴리스**의 `SHA256SUMS`를 같은 폴더에 놓고, 터미널에서 그 폴더로 이동합니다. 다음은 `1.0.3` DMG 하나만 검사하는 예시입니다. 파일명은 실제 내려받은 버전으로 바꿉니다.

```sh
awk '$2 == "MenuBarDock-1.0.3-arm64.dmg" { print }' SHA256SUMS | shasum -a 256 -c -
```

파일명 뒤에 `OK`가 나오면 체크섬이 일치합니다. 오류가 나거나 `OK`가 없으면 파일명과 릴리스 버전을 확인합니다. ZIP을 선택했다면 위 파일명만 해당 ZIP 이름으로 바꾸면 됩니다.

## 실제 확인 범위

패키지 검사는 다른 Mac에서 다운로드한 앱의 최초 설치를 대신하지 않습니다. 다음 항목은 실제로 수행한 결과만 [검증 기록](verification/)에 남깁니다.

- Applications에서 실행, Finder 재실행으로 설정 열기, 로그인 시작 등록·해제
- 메뉴 막대의 앱별 클릭·순서 저장, Option+Tab 전체 목록·반복 입력·단축키 충돌
- 화면 배율·비활성 디스플레이·노치·Spaces·전체 화면과 장시간 사용
- 지원 macOS 버전별 실제 동작과 다운로드 파일의 Gatekeeper 허용 상태

## 진단

| 옵션 | 동작 |
| --- | --- |
| `--self-test` | 번들 ID, `LSUIElement`, 앱 아이콘, 기본 설정 검사 후 종료 |
| `--smoke-test --data-directory <임시 경로>` | 별도 JSON 저장 경로에서 시작·저장·정상 종료 |
| `--show-settings` | 시작 후 설정 창 표시 |

`smoke-test`는 임시 JSON 디렉터리를 사용합니다. 단축키 UserDefaults와 로그인 항목은 macOS의 별도 저장소이므로 이 검사에서 변경하지 않습니다. 진단 로그의 사용자 앱 경로와 이름은 기본적으로 비공개로 처리합니다.
