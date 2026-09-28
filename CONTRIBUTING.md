# 개발과 기여

Menu Bar Dock은 macOS 메뉴 막대에서 앱을 실행하는 네이티브 앱입니다. 설치와 사용 방법은 [README](README.md), 프로젝트 배경은 [CONTEXT.md](CONTEXT.md), 구현 경계는 [모듈 계약](docs/module-contracts.md)에 있습니다. 에이전트 작업 규칙은 [AGENTS.md](AGENTS.md)를 따릅니다.

## 환경 준비

- Apple Silicon Mac, macOS 14 이상
- Swift 6.2 이상의 Xcode 또는 Command Line Tools
- Git: 앱 번들의 버전 계산에는 전체 커밋 이력과 릴리스 태그가 필요하므로 얕은 복제를 사용하지 않습니다.
- [mise](https://mise.jdx.dev/) 또는 Make: 같은 로컬 스크립트를 실행하는 진입점입니다.

Swift와 macOS SDK는 `xcode-select`로 선택된 Apple 개발 도구를 사용합니다. `mise run toolchain`으로 실제 Swift 버전과 개발 도구 경로를 확인합니다. 지원 대상으로 선언한 환경과 실제 시험한 환경은 구분해 기록합니다.

추가 도구는 수행할 작업에 맞춰 준비합니다.

| 작업 | 추가 전제조건 |
| --- | --- |
| `build`, `test`, 세 가지 입력 검사 | Apple 개발 도구. AppKit 창을 여는 테스트·입력 검사는 로그인된 macOS 데스크톱 세션 필요 |
| `app`, `run`, `smoke`, `version`, `package`, `package-test` | Python 3.9 이상. 앱 번들의 버전·메타데이터 생성에 사용 |
| `check`, `release-test`, `release-notes` 및 메타데이터 검사 | Python 3.9 이상. Python 표준 라이브러리와 로컬 Git 사용 |
| `release-plan`, `release-prepare`, `release` | 인증된 [GitHub CLI](https://cli.github.com/), 저장소 접근 권한, 깨끗하고 원격과 일치하는 `main`, 최신 태그 |
| Developer ID 서명·공증 | Developer ID Application 인증서. 공증에는 `notarytool` 키체인 프로필도 필요 |

로컬 빌드·검증에는 GitHub 인증이 필요하지 않습니다. `check`에 포함된 릴리스 게시 테스트는 GitHub 호출을 모의 처리합니다. 실제 원격 상태를 조회하는 `release-plan`과 `release-prepare`부터 GitHub 인증이 필요하며, 게시 권한은 `release` 실행에 사용합니다. Python은 앱 번들 생성에도 필요하지만 앱 자체에 포함되지는 않습니다.

## 소스에서 빌드하고 실행

Apple 개발 도구와 Python 3.9 이상을 준비한 뒤 실행합니다.

```sh
git clone https://github.com/jeonghyeon-net/menubar-dock.git
cd menubar-dock
mise trust
mise run toolchain
mise run run
```

`run`은 arm64 앱 번들을 `build/Menu Bar Dock.app`에 생성한 뒤 엽니다. mise 없이 빌드하려면 저장소 루트에서 다음 명령을 사용합니다.

```sh
make app
open "build/Menu Bar Dock.app"
```

`make run`도 빌드와 실행을 함께 수행합니다. 빌드만 필요하면 `mise run app`, 실행 파일 컴파일만 확인하려면 `mise run build`를 사용합니다. 기본 앱 번들은 ad-hoc 서명으로 생성됩니다.

다시 빌드할 때 해당 출력 폴더의 앱을 먼저 종료합니다. 별도 출력이 필요하면 `MENUBAR_BUILD_DIR`을 지정해 `app` 스크립트를 실행하고 생성된 앱을 직접 엽니다. 같은 작업 디렉터리에서 여러 빌드·패키징 작업을 동시에 실행하지 않습니다.

## 작업 흐름

이 저장소는 `main` 브랜치 하나로 운영합니다. 별도 작업 브랜치와 PR을 만들지 않습니다. 변경 범위를 정하고 구현·검증한 뒤 검토 가능한 작은 단위로 `main`에 커밋·푸시합니다. 다른 작업자의 변경을 되돌리거나 검토하지 않은 파일을 함께 커밋하지 않습니다.

검증은 아래 로컬 명령으로 수행합니다. GitHub Actions workflow, PR 자동화, 푸시를 계기로 시작하는 배포 작업은 추가하지 않습니다. 패키지 생성과 공개 릴리스 게시도 별도 작업으로 다룹니다.

커밋 제목은 변경한 동작이 드러나도록 한국어로 작성합니다. 예를 들어 `fix: 앱 위치가 바뀌어도 등록 순서를 유지`처럼 문제와 결과를 짧게 적습니다. 변경 설명에는 이유, 사용자에게 달라지는 동작, 실행한 검사와 아직 확인하지 못한 범위를 남깁니다.

버그를 전달할 때는 앱·macOS 버전, 재현 단계, 기대 동작과 실제 동작을 적습니다. 다중 화면 문제에는 화면 배율과 활성 화면 여부를 함께 적고, 스크린샷에 개인 앱 이름이나 문서 내용이 포함되어 있는지 확인합니다.

## 명령 모음

| 명령 | 용도 |
| --- | --- |
| `mise run toolchain` | Swift 버전과 개발 도구 경로 확인 |
| `mise run build` | 개발용 실행 파일 빌드 |
| `mise run test` | Swift Testing 테스트 실행 |
| `mise run test -- --filter DockCatalogTests` | 특정 테스트 선택 |
| `mise run check` | 릴리스 도구 검사, 경고를 오류로 처리하는 빌드, Swift 테스트, 아래 세 가지 실제 입력 검사 |
| `mise run input-check` | 메뉴 막대 앱별 버튼의 실제 마우스 누름·해제 검사 |
| `mise run settings-input-check` | 크기·간격 슬라이더의 실제 드래그와 즉시 반영 검사 |
| `mise run switcher-input-check` | 앱 검색·커서·선택·취소·한글 조합·포커스 검사 |
| `mise run app` | arm64 Release 앱 번들 생성 |
| `mise run run` | 앱 번들을 빌드한 뒤 실행 |
| `mise run self-test` | 이미 빌드한 번들의 식별자·리소스 검사 |
| `mise run smoke` | 앱 빌드 후 임시 설정으로 시작·저장·정상 종료 검사 |
| `mise run package` | ZIP·DMG·SHA-256 체크섬·manifest 생성 |
| `mise run version` | 태그 기반 버전 계산 |
| `mise run version-test` | 버전·릴리스 노트 메타데이터 회귀 검사 |
| `mise run release-notes -- <버전> <커밋> <배포 폴더>` | 배포 파일과 커밋 범위에서 한국어 릴리스 본문 생성 |
| `mise run release-notes-test` | `version-test`와 같은 메타데이터 검사 실행 |
| `mise run release-test` | 버전·노트·패키지 메타데이터·게시 경계 검사 |
| `mise run package-test` | ZIP·DMG 실제 내용·서명·자체 진단 검사 |
| `mise run release-plan` | 게시 조건과 대상 확인 |
| `mise run release-prepare` | 전체 검사 후 패키지·한국어 노트 생성 |
| `mise run release` | 태그·첨부 파일을 GitHub Release에 게시 |
| `mise run notarize` | 준비된 인증서와 키체인 프로필로 서명·공증 |
| `mise run clean` | SwiftPM 빌드 캐시 정리 |

정의는 [mise.toml](mise.toml)과 [Makefile](Makefile)에 있습니다. `make check`, `make app`, `make package`도 같은 스크립트를 호출합니다. 입력 검사는 `make input-check`, `make settings-input-check`, `make switcher-input-check`로 실행할 수 있습니다. 개발 명령과 배포 명령은 필요할 때 명시적으로 실행합니다.

## 책임 경계와 코드 작성

| 모듈 | 책임 |
| --- | --- |
| `DockDomain` | 설치 앱 식별자, 등록 앱·임시 앱, 삭제 기록, 저장 순서, 선택·검색 세션 |
| `DockPersistence` | 설정 형식, 원자 저장, 백업, 손상 복구 |
| `DockPlatform` | macOS 앱 관찰·실행, Dock 동기화, bookmark, 아이콘, 로그인 항목, Spotlight 앱 검색 |
| `DockShortcuts` | 전역 키 등록, 단축키 설정, 반복 입력과 충돌 복구 |
| `MenuBarDock` | 앱 수명과 유스케이스 조립, 표시 모델, AppKit 화면 |

도메인에 AppKit 객체나 파일 접근을 넣지 않습니다. 화면은 표시 모델을 읽고 명령을 전달하며, 조립 계층이 도메인과 외부 효과를 연결합니다. 주석과 문서는 한국어로, 식별자는 일관된 영어로 작성합니다. 주석은 상태 소유권, 데이터 보존, 실패 처리의 이유를 설명합니다.

설정 목록에는 **항상 표시할 앱**에 등록된 앱만 표시합니다. 메뉴 막대와 선택 패널에서는 미등록 실행 앱을 앞에, 등록 앱을 뒤에 표시하며 각 그룹의 상대 순서를 유지합니다. 명시적으로 등록한 앱은 저장 목록 끝에 추가하고, 삭제한 앱은 자동 감지로 다시 등록하지 않습니다. 이전 설정의 숨김·삭제 기록도 보존합니다.

앱 실행·활성화 이벤트로 저장 순서를 바꾸지 않습니다. 메뉴 막대에는 앱마다 독립된 `NSStatusItem`의 표준 버튼을 사용합니다. 빈 슬롯이나 실행 중 표시를 추가하지 않으며, 다른 앱의 창을 디스플레이 사이로 옮기지 않습니다. 강제 unwrap, 무한 재시도, 주기적인 앱 목록 polling을 피합니다. 앱은 왼쪽 클릭으로 열고, 오른쪽 클릭·Control-클릭으로 설정 메뉴를 엽니다. 선택 패널의 설정 버튼도 왼쪽 클릭으로 접근할 수 있어야 합니다.

설정은 탭·카드 없는 단일 창을 유지합니다. 슬라이더 추적 중 저장값을 손잡이에 되쓰지 않고, 아이콘 크기는 숫자와 실제 렌더링을 함께 확인합니다. 검색 결과는 앱 아이콘과 이름 한 줄로 표시하며 검색만으로 등록 목록을 바꾸지 않습니다.

## 검증 기준

| 변경 영역 | 확인할 동작 |
| --- | --- |
| 앱 목록·순서 | 등록 앱과 임시 앱의 분리, 부분 목록 이동, 중복 프로세스, 삭제 후 재감지 방지, 위치 재지정과 별도 설치 구분 |
| 저장 | 손상 원본 보존, 백업 복구, 미래 형식 보호, 늦은 revision 저장 방지 |
| 단축키·선택 패널 | 실제 키 입력, 한 번의 입력과 반복 입력, Enter·Esc, 기록 취소, 충돌 복구 |
| 앱 검색 | 앱 전용 필터, 한 줄 표시, 늦은 응답 차단, 한글 조합 확정 후 검색, 입력 포커스, 결과 실행 오류 |
| 앱 수명 | 처음 실행, Finder 재실행, 최종 설정 저장, 정상 종료와 저장 실패 후 복귀 |
| 메뉴 막대·화면 | 앱별 독립 아이콘 왼쪽 클릭, 최대 개수와 전체 선택 패널, 필요한 만큼의 폭, 접근성, 배율·외관 변경 |
| 패키징 | 앱 번들 구조, arm64, 서명 상태, ZIP·DMG, 체크섬 |

동작을 바꿀 때는 해당 문제를 재현하는 테스트를 추가하고 변경 범위를 검증합니다. `mise run check`가 통과하면 필요한 실제 앱 경로를 확인합니다. AppKit 테스트는 임시 창을 열 수 있습니다. 화면 외관과 두 디스플레이의 합성 결과는 별도로 관찰해야 합니다.

문서만 바꿨다면 링크와 예제 명령을 확인합니다. 문장 자체를 검사하는 테스트는 만들지 않습니다. 빌드 성공, 자동 테스트, 실제 입력, 다중 화면 관찰, 서명·공증을 각각 수행한 범위대로 기록합니다.

## 문서와 배포

README는 일반 사용자의 간단한 설치와 사용 흐름에 집중합니다. 소스 빌드·개발 명령은 이 문서에, 상세 사용법은 [사용 안내](docs/user-guide.md)에 둡니다. 다운로드 파일의 [체크섬 확인](docs/releasing.md#다운로드-파일-확인선택)은 릴리스 문서의 선택 항목으로 안내합니다. 구조·규칙은 [아키텍처](docs/architecture.md), 선택의 근거는 [설계 결정](docs/adr/), 명령과 결과는 [검증 기록](docs/implementation-plan.md)에 남깁니다. 문서를 바꾸면 관련 링크와 현재 구현의 일치를 확인합니다.

이미지에는 이 앱의 실제 화면이나 공개해도 되는 예제를 사용합니다. 다른 저장소의 내부 화면·문서·코드를 공개 문서에 옮기지 않습니다.

앱·설치 이미지·인증서·개인 설정은 Git에 커밋하지 않습니다. 배포 준비와 게시 절차는 [빌드와 배포](docs/releasing.md)를 따릅니다. 로컬 검증을 위해 임시 공개 릴리스를 만들지 않습니다.

## 실제 입력 회귀 검사

`mise run input-check`는 로그인된 macOS GUI 세션에서 제품의 상태 항목 소스를 컴파일하고 실제 AppKit 누름·해제 이벤트를 전달합니다. 검사 중 임시 메뉴 막대 항목을 만들고 종료할 때 제거하며, 외부 앱을 실행하거나 사용자 설정을 변경하지 않습니다. `mise run check`에도 포함되어 있습니다.

`mise run settings-input-check`는 실제 크기·간격 슬라이더를 양끝과 트랙 바깥까지 드래그합니다. 모델 갱신 중 손잡이 값과 프레임의 안정성, 최종 설정값 반영을 확인합니다.

`mise run switcher-input-check`는 선택 패널의 field editor와 이벤트 큐를 통해 앱 검색 입력·커서 이동·한글 조합·결과 선택·취소를 확인합니다. 합성 앱 검색 결과를 사용하며 외부 앱을 실행하지 않습니다. 검사 창에 입력이 섞이지 않도록 다른 UI 검사를 동시에 실행하지 않습니다. 플랫폼 테스트는 Spotlight 조회 수명·취소·앱 필터·결과 정렬과 실행 오류를 별도로 검사합니다.

## 릴리스 운영

[릴리스 결정](docs/adr/0004-local-versioned-releases.md)에 따라 [scripts/version.sh](scripts/version.sh)가 현재 커밋의 첫 번째 부모 이력에 있는 정식 태그로 패치 버전을 계산합니다. 앱 복사본에 버전·빌드 번호·커밋을 기록하므로 일반 패치 릴리스마다 Info.plist를 수정하지 않습니다.

변경한 동작은 CHANGELOG에 기록하고, 게시 본문은 실제 커밋 범위와 패키지의 검증된 메타데이터에서 생성합니다. 제목의 Markdown 구두점 때문에 릴리스 본문이 깨지지 않도록 생성기가 이스케이프합니다. 새로운 게시와 기존 설명 갱신에 같은 생성기를 사용합니다.

패키징을 수정했다면 `mise run release-test`와 `mise run package-test`를 실행합니다. 게시 전에는 깨끗한 `main`을 원격과 맞추고 `mise run release-prepare` 결과를 검토합니다. 공개 릴리스의 태그나 바이너리는 교체하지 않습니다. 자세한 명령, 서명·공증과 실패 복구는 [빌드와 릴리스](docs/releasing.md)를 따릅니다.
