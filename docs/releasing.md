# 빌드와 배포

검증과 패키징은 로컬 Mac에서 실행합니다. `main`에 커밋·푸시하는 작업, 배포 파일을 만드는 작업, GitHub Release를 게시하는 작업을 각각 구분합니다.

## 앱과 설치 파일 만들기

Apple Silicon Mac에서 Swift 6.2 이상의 Xcode 또는 Command Line Tools를 사용합니다. 저장소를 처음 받았다면 `mise trust`로 개발 명령을 확인한 뒤 실행합니다.

```sh
mise run toolchain
mise run check
mise run package
mise run self-test
mise run smoke
shasum -a 256 -c dist/SHA256SUMS
```

`mise run package`는 다음 파일을 만듭니다. 아래는 현재 **1.0.1**의 예시이며 파일명은 `Config/Info.plist`의 `CFBundleShortVersionString` 값을 따릅니다.

```text
build/Menu Bar Dock.app
dist/MenuBarDock-1.0.1-arm64.zip
dist/MenuBarDock-1.0.1-arm64.dmg
dist/SHA256SUMS
```

DMG에는 앱과 `Applications` 바로가기가 들어갑니다. DMG를 열고 앱을 `Applications`로 복사한 뒤 실행합니다. ZIP은 앱 번들을 담습니다. 현재 체크섬 파일의 경로는 저장소 루트를 기준으로 하므로 위 검증 명령도 저장소 루트에서 실행합니다.

기본 빌드는 arm64 Release이며 번들 ID는 `net.jeonghyeon.MenuBarDock`, 최소 배포 대상은 macOS 14입니다. 외부 Swift 패키지 다운로드는 없습니다. 명령 정의는 [mise.toml](../mise.toml), 구현은 [scripts/](../scripts/)에 있습니다. `make app`과 `make package`도 같은 스크립트를 호출합니다.

## 서명과 공증

`SIGNING_IDENTITY`를 지정하지 않으면 로컬 실행용 ad-hoc 서명을 사용합니다. 이 결과물에는 Developer ID 인증이나 Apple 공증이 포함되지 않습니다. 공개 다운로드용 배포본을 준비할 때는 Developer ID Application 인증서와 `notarytool` 키체인 프로필을 준비합니다.

```sh
export SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
export NOTARY_PROFILE='menubar-dock-notary'
mise run notarize
```

이 작업은 앱의 Hardened Runtime 서명, ZIP 제출, 앱 공증 ticket 첨부, ZIP·DMG 재생성, DMG 서명·공증·ticket 첨부, `spctl` 평가와 체크섬 생성을 수행합니다. 인증서나 프로필 이름이 없으면 시작 전에 중단합니다. 인증서·비밀번호·키체인 프로필 내용은 저장소나 로그에 남기지 않습니다.

서명·공증을 실행하지 않은 빌드를 공증 완료로 기록하지 않습니다. 실제 사용한 서명 종류와 Apple 제출 결과는 해당 배포의 검증 기록에 남깁니다.

## 버전과 게시

1. `main`에서 `Config/Info.plist`의 `CFBundleShortVersionString`과 `CFBundleVersion`, [변경 기록](../CHANGELOG.md)을 갱신합니다.
2. 로컬 검사와 변경 범위에 필요한 실제 동작을 확인하고, 검증 기록에 환경·명령·결과·미검증 범위를 적습니다.
3. 검증한 변경을 커밋·푸시하고, 게시할 커밋과 작업 디렉터리의 상태를 확인합니다.
4. 최종 배포 파일의 서명·공증·체크섬과 설치 후 동작을 확인합니다.
5. 게시하기로 정한 커밋에 버전 태그(예: `v1.0.1`)를 만들고 GitHub Release에 ZIP·DMG·체크섬을 첨부합니다.

일반 커밋이나 푸시는 릴리스를 게시하지 않습니다. 저장소에 GitHub Actions workflow나 자동 게시 작업을 추가하지 않습니다. 배포 파일을 확인하려고 임시 공개 릴리스를 만들거나, 이미 게시한 버전의 바이너리를 같은 이름으로 교체하지 않습니다.

릴리스 설명에는 실제 변경 사항, 대상 커밋, 서명·공증 상태, 관련 검증 기록을 적습니다. 앱의 업데이트 확인은 공개된 정식 릴리스를 조회하고 다운로드 페이지를 안내하며 설치 파일을 자동으로 교체하지 않습니다.

## 배포 전 실제 확인 범위

- `Applications`에서 실행, Finder 재실행으로 설정 열기, 로그인 시작 등록·해제
- 앱별 독립 메뉴 막대 아이콘 왼쪽 클릭, 순서 변경·저장·재실행 후 복원
- Option+Tab 전체 목록·역방향·반복 입력, Enter·Esc, 톱니 버튼으로 설정 열기, 단축키 변경과 충돌 복구
- 메뉴 막대 공간 부족과 최대 표시 개수, 활성·비활성 디스플레이, 다른 배율과 외관
- 앱 시작과 최종 저장·정상 종료, 설정 저장 실패 후 앱으로 돌아오기

최소 배포 대상을 지정하는 것만으로 모든 해당 macOS 버전의 동작이 검증되지는 않습니다. 두 화면·노치·Spaces·전체 화면·장시간 동작도 실제로 확인한 항목만 완료로 적습니다. 자동 테스트와 smoke 검사의 범위는 [개발과 기여](../CONTRIBUTING.md), 실행 결과는 [검증 기록](implementation-plan.md)에 있습니다.

## 진단 명령

| 옵션 | 동작 |
| --- | --- |
| `--self-test` | 번들 ID, `LSUIElement`, 앱 아이콘, 기본 설정을 검사하고 종료 |
| `--smoke-test --data-directory <임시 경로>` | 별도 JSON 저장 경로에서 시작한 뒤 정상 저장·종료 |
| `--show-settings` | 시작 후 설정 창 표시 |

`mise run smoke`는 임시 JSON 디렉터리를 만들고 종료까지 시간 제한을 두어 검사합니다. 단축키의 UserDefaults와 로그인 항목은 macOS의 별도 저장소를 사용하므로 JSON 경로 지정만으로 격리되지 않습니다. 이 진단에서는 단축키 설정이나 로그인 등록을 바꾸지 않습니다.

OSLog subsystem은 앱 조립의 `net.jeonghyeon.MenuBarDock`과 플랫폼 경계의 `app.menubardock`입니다. 진단을 추가할 때 사용자 앱 경로와 이름을 기본 로그에 평문으로 남기지 않습니다.
