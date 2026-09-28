# 개발과 기여

Menu Bar Dock은 macOS 메뉴 막대에서 앱을 실행하는 네이티브 앱입니다. 사용 방법은 [README](README.md), 도메인 용어는 [CONTEXT.md](CONTEXT.md), 구현 경계는 [모듈 계약](docs/module-contracts.md)을 기준으로 합니다. 에이전트 작업 규칙은 [AGENTS.md](AGENTS.md)에 있습니다.

## 환경 준비

- Apple Silicon Mac
- Swift 6.2 이상의 Xcode 또는 Command Line Tools
- Python 3.9 이상: 표준 라이브러리만 사용하는 개발·릴리스 도구
- 인증된 GitHub CLI: 릴리스 계획 확인과 게시 시 필요
- 로그인된 macOS 데스크톱 세션: AppKit 입력·창 테스트와 실제 앱 검증에 필요합니다.
- [mise](https://mise.jdx.dev/): 저장소의 개발 명령을 한 곳에서 실행합니다.

```sh
git clone https://github.com/jeonghyeon-net/menubar-dock.git
cd menubar-dock
mise trust
mise run toolchain
mise run check
mise run run
```

Swift를 별도 런타임으로 설치하지 않습니다. macOS SDK와 함께 제공되는 Apple 도구 체인을 사용합니다. `mise run toolchain`의 출력으로 실제 사용하는 Swift와 개발 도구 경로를 확인하세요. 빌드 대상은 macOS 14 이상이며, 지원 대상으로 선언한 환경과 실제 시험한 환경을 구분해 기록합니다.

## 작업 흐름

이 저장소는 `main` 브랜치 하나로 운영합니다. 별도 작업 브랜치와 PR을 만들지 않습니다. 변경 범위를 정하고 구현·검증한 뒤 검토 가능한 작은 단위로 `main`에 커밋·푸시합니다. 다른 작업자의 변경을 되돌리거나 검토하지 않은 파일을 함께 커밋하지 않습니다.

검증은 아래 로컬 명령으로 수행합니다. GitHub Actions workflow, PR 자동화, 푸시를 계기로 시작하는 배포 작업은 추가하지 않습니다. 패키지 생성과 공개 릴리스 게시도 별도 작업으로 다룹니다.

커밋 제목은 변경한 동작이 드러나도록 한국어로 작성합니다. 예를 들어 `fix: 앱 경로가 이동해도 고정 순서를 유지`처럼 문제와 결과를 짧게 적습니다. 변경 설명에는 이유, 사용자에게 달라지는 동작, 실행한 검사와 아직 확인하지 못한 범위를 남깁니다.

버그를 전달할 때는 앱·macOS 버전, 재현 단계, 기대 동작과 실제 동작을 적습니다. 다중 화면 문제에는 화면 배율과 활성 화면 여부를 함께 적고, 스크린샷에 개인 앱 이름이나 문서 내용이 포함되어 있는지 확인합니다.

## 명령 모음

| 명령 | 용도 |
| --- | --- |
| `mise run toolchain` | Swift 버전과 개발 도구 경로 확인 |
| `mise run build` | 개발용 실행 파일 빌드 |
| `mise run test` | Swift Testing 테스트 실행 |
| `mise run test -- --filter DockCatalogTests` | 특정 테스트 선택 |
| `mise run check` | 경고를 오류로 처리하는 빌드 후 테스트 |
| `mise run app` | arm64 Release 앱 번들 생성 |
| `mise run run` | 앱 번들을 빌드한 뒤 실행 |
| `mise run self-test` | 이미 빌드한 번들의 식별자·리소스 검사 |
| `mise run smoke` | 앱 빌드 후 임시 설정으로 시작·저장·정상 종료 검사 |
| `mise run package` | ZIP·DMG·SHA-256 체크섬·manifest 생성 |
| `mise run version` | 태그 기반 버전 계산 |
| `mise run release-test` | 버전·노트·패키지 메타데이터·게시 경계 검사 |
| `mise run package-test` | ZIP·DMG 실제 내용·서명·자체 진단 검사 |
| `mise run release-plan` | 게시 조건과 대상 확인 |
| `mise run release-prepare` | 전체 검사 후 패키지·한국어 노트 생성 |
| `mise run release` | 태그·첨부 파일을 GitHub Release에 게시 |
| `mise run notarize` | 준비된 인증서와 키체인 프로필로 서명·공증 |
| `mise run clean` | SwiftPM 빌드 캐시 정리 |

정의는 [mise.toml](mise.toml)에 있습니다. 기존 `make check`, `make app`, `make package`도 사용할 수 있습니다. 같은 작업 디렉터리에서 여러 빌드·패키징 작업을 동시에 실행하지 않습니다.

## 책임 경계와 코드 작성

| 모듈 | 책임 |
| --- | --- |
| `DockDomain` | 설치 앱 식별자, 순서, 고정·제외 정책, 선택 세션 |
| `DockPersistence` | 설정 형식, 원자 저장, 백업, 손상 복구 |
| `DockPlatform` | macOS 앱 관찰·실행, bookmark, 아이콘, 로그인 항목 |
| `DockShortcuts` | 전역 키 등록, 단축키 설정, 반복 입력과 충돌 복구 |
| `MenuBarDock` | 앱 수명과 유스케이스 조립, 표시 모델, AppKit 화면 |

도메인에 AppKit 객체나 파일 접근을 넣지 않습니다. 화면은 표시 모델을 읽고 명령을 전달하며, 조립 계층이 도메인과 외부 효과를 연결합니다. 주석과 문서는 한국어로, 식별자는 일관된 영어로 작성합니다. 주석은 상태 소유권, 데이터 보존, 실패 처리의 이유를 설명합니다.

앱 실행·활성화 이벤트로 사용자 순서를 바꾸지 않습니다. 메뉴 막대에는 앱마다 독립된 `NSStatusItem`의 표준 버튼을 사용합니다. 빈 슬롯이나 실행 중 표시를 추가하지 않으며, 다른 앱의 창을 디스플레이 사이로 옮기지 않습니다. 강제 unwrap, 무한 재시도, 주기적인 앱 목록 polling을 피합니다. 각 앱 실행과 선택 패널의 설정 버튼은 왼쪽 클릭으로 접근할 수 있어야 합니다.

## 검증 기준

| 변경 영역 | 확인할 동작 |
| --- | --- |
| 앱 목록·순서 | 실행·종료 후 상대 순서, 중복 프로세스, 고정·제외, 경로 이동과 별도 설치 구분 |
| 저장 | 손상 원본 보존, 백업 복구, 미래 형식 보호, 늦은 revision 저장 방지 |
| 단축키·선택 패널 | 실제 키 입력, 한 번의 입력과 반복 입력, Enter·Esc, 기록 취소, 충돌 복구 |
| 앱 수명 | 처음 실행, Finder 재실행, 최종 설정 저장, 정상 종료와 저장 실패 후 복귀 |
| 메뉴 막대·화면 | 앱별 독립 아이콘 왼쪽 클릭, 최대 개수와 전체 선택 패널, 필요한 만큼의 폭, 접근성, 배율·외관 변경 |
| 패키징 | 앱 번들 구조, arm64, 서명 상태, ZIP·DMG, 체크섬 |

동작을 바꿀 때는 해당 문제를 재현하는 테스트를 추가하고 변경 범위를 검증합니다. `mise run check`가 통과하면 필요한 실제 앱 경로를 확인합니다. AppKit 테스트는 임시 창을 열 수 있습니다. 화면 외관과 두 디스플레이의 합성 결과는 별도로 관찰해야 합니다.

문서만 바꿨다면 링크와 예제 명령을 확인합니다. 문장 자체를 검사하는 테스트는 만들지 않습니다. 빌드 성공, 자동 테스트, 실제 입력, 다중 화면 관찰, 서명·공증을 각각 수행한 범위대로 기록합니다.

## 문서와 배포

README에는 시작 방법과 사용 흐름을, 상세 사용법은 [사용 안내](docs/user-guide.md)에 둡니다. 구조·규칙은 [아키텍처](docs/architecture.md), 선택의 근거는 [설계 결정](docs/adr/), 명령과 결과는 [검증 기록](docs/implementation-plan.md)에 남깁니다. 문서를 바꾸면 관련 링크와 현재 구현의 일치를 확인합니다.

이미지에는 이 앱의 실제 화면이나 공개해도 되는 예제를 사용합니다. 다른 저장소의 내부 화면·문서·코드를 공개 문서에 옮기지 않습니다.

앱·설치 이미지·인증서·개인 설정은 Git에 커밋하지 않습니다. 배포 준비와 게시 절차는 [빌드와 배포](docs/releasing.md)를 따릅니다. 로컬 검증을 위해 임시 공개 릴리스를 만들지 않습니다.

## 메뉴 막대 입력 회귀 검사

`mise run input-check`는 로그인된 macOS GUI 세션에서 production 상태 항목 소스를 컴파일하고 실제 AppKit 누름·해제 이벤트를 전달합니다. 검사 중 임시 메뉴 막대 항목을 만들고 종료할 때 제거하며, 외부 앱을 실행하거나 사용자 설정을 변경하지 않습니다. `mise run check`에도 포함되어 있습니다.

`mise run switcher-input-check`는 같은 선택 패널의 field editor와 이벤트 큐를 통해 검색 입력·커서 이동·한글 조합·결과 선택·취소를 확인합니다. 합성 검색 결과를 사용하며 외부 앱이나 파일을 열지 않습니다. 검사 창에 입력이 섞이지 않도록 다른 UI 검사를 동시에 실행하지 않습니다. 플랫폼 테스트는 Spotlight 조회 수명·취소·결과 정렬과 열기 오류를 별도로 검사합니다.

## 릴리스 운영

[릴리스 결정](docs/adr/0004-local-versioned-releases.md)에 따라 전체 Git 이력의 정식 태그로 패치 버전을 계산합니다. 앱 복사본에 버전·빌드 번호·커밋을 기록하므로 일반 패치 릴리스마다 Info.plist를 수정하지 않습니다.

변경한 동작은 CHANGELOG에 기록하고, 게시 본문은 실제 커밋 범위와 패키지의 검증된 메타데이터에서 생성합니다. 제목의 Markdown 구두점 때문에 릴리스 본문이 깨지지 않도록 생성기가 이스케이프합니다. 새로운 게시와 기존 설명 갱신에 같은 생성기를 사용합니다.

패키징을 수정했다면 `mise run release-test`와 `mise run package-test`를 실행합니다. 게시 전에는 깨끗한 `main`을 원격과 맞추고 `mise run release-prepare` 결과를 검토합니다. 공개 릴리스의 태그나 바이너리는 교체하지 않습니다. 자세한 명령, 서명·공증과 실패 복구는 [빌드와 릴리스](docs/releasing.md)를 따릅니다.
