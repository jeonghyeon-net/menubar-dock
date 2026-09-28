# Menu Bar Dock

자주 쓰는 앱을 메뉴 막대에 놓고, 정해 둔 순서대로 여는 macOS 앱입니다. Swift 6와 AppKit으로 만들며 Apple Silicon용 `arm64` 앱 번들을 생성합니다.

![Menu Bar Dock 앱 선택 패널](docs/assets/switcher.png)

[시작하기](#시작하기) · [사용 안내](docs/user-guide.md) · [개발과 기여](CONTRIBUTING.md) · [아키텍처](docs/architecture.md) · [배포](docs/releasing.md)

## 시작하기

Apple Silicon Mac과 Swift 6.2 이상의 Xcode 또는 Command Line Tools가 필요합니다. 빌드 대상은 macOS 14 이상이며, 실제 확인한 환경과 남은 검증 항목은 [검증 기록](docs/implementation-plan.md)에 있습니다.

[mise](https://mise.jdx.dev/)가 설치되어 있다면 다음 명령으로 앱을 만듭니다.

```sh
git clone https://github.com/jeonghyeon-net/menubar-dock.git
cd menubar-dock
mise trust
mise run app
open "build/Menu Bar Dock.app"
```

`mise`는 저장소의 개발 명령을 실행합니다. Swift와 macOS SDK는 `xcode-select`로 선택된 Apple 도구 체인을 사용하며, 외부 Swift 패키지는 내려받지 않습니다. `mise` 없이 시작하려면 `make app`을 실행해도 같은 빌드 스크립트를 사용합니다.

첫 실행에서는 설정 창이 열립니다. 기존 Menu Bar Dock을 사용 중이라면 먼저 종료해 주세요. 계속 사용할 앱은 `Applications` 폴더로 옮긴 뒤 실행합니다. 서명 인증서를 지정하지 않은 로컬 빌드는 ad-hoc 서명이며, Developer ID 서명·공증을 거친 공개 배포본과 구분합니다.

현재 버전은 **1.0.2**입니다. `mise run package`를 실행하면 `dist/MenuBarDock-1.0.2-arm64.dmg`와 ZIP을 만듭니다. 서명과 배포 절차는 [빌드와 배포](docs/releasing.md)를 참고하세요.

## 앱 열기와 설정

- 메뉴 막대에는 **앱 아이콘만** 표시합니다. 각 아이콘을 왼쪽 클릭하면 앱을 실행하거나 기존 앱으로 전환합니다.
- 아이콘을 **우클릭 → 설정…**하면 설정이 열립니다. **크기 및 간격…**은 표시 탭으로 바로 이동합니다. Control-클릭, 앱 재실행, `Option+Tab` 패널의 톱니 버튼으로도 접근할 수 있습니다.
- 설정의 **앱** 탭에서 `+`로 앱을 추가하고, 행을 선택한 뒤 `↑`·`↓` 버튼이나 드래그로 순서를 바꿉니다.
- **고정**한 앱은 종료 후에도 표시됩니다. **표시**를 끄면 메뉴 막대와 선택 패널에서 제외됩니다.
- 아이콘은 기본 24pt이며 실제 버튼 안에 맞춰 표시합니다. 크기·영역 너비·개수를 조절하고 크기와 너비만 기본값으로 되돌릴 수 있습니다. 메뉴 막대에 다 들어가지 않는 앱도 `Option+Tab` 선택 패널에서 열 수 있습니다.

![앱 목록과 고정·표시·순서를 조절하는 설정 화면](docs/assets/settings.png)

실행 중인 일반 앱은 자동 감지합니다. 같은 설치 앱의 여러 창·프로세스와 고정 목록은 하나로 합칩니다. 종료한 앱은 고정한 경우에만 남으며, 제외한 앱은 다시 나타나지 않습니다. 기본 메뉴 막대 표시 한도는 6개이고 설정에서 늘릴 수 있습니다.

앱 실행과 활성화는 저장된 순서를 바꾸지 않습니다. 실행 중 점·밑줄·배지는 표시하지 않으며, 새 앱의 창 위치는 macOS와 해당 앱이 결정합니다. 메뉴 막대가 가려졌을 때도 Finder에서 Menu Bar Dock을 다시 열면 설정에 접근할 수 있습니다.

## 키보드로 선택하기

| 키 | 동작 |
| --- | --- |
| `Option+Tab` | 선택 패널 열기 또는 다음 앱 선택 |
| `Shift+Option+Tab` | 이전 앱 선택 |
| 방향키 | 패널 안에서 이동 |
| `Enter` | 선택한 앱 열기 |
| `Esc` | 취소 |

선택 패널에는 메뉴 막대의 최대 표시 개수와 관계없이 표시 대상 앱 전체가 나타납니다. Option 키를 놓아도 앱이 열리지 않습니다. Enter로 선택을 확정합니다. 패널의 톱니 버튼으로 설정을 열고 **단축키** 탭에서 다음·이전 단축키를 바꿀 수 있습니다.

## 로컬 개발 명령

| 명령 | 결과 |
| --- | --- |
| `mise run toolchain` | 선택된 Swift 버전과 Apple 개발 도구 경로 확인 |
| `mise run check` | 경고를 오류로 처리하는 빌드와 자동 테스트 |
| `mise run input-check` | 독립 메뉴 막대 버튼의 실제 AppKit 마우스 입력 경로 검사 |
| `mise run app` | `build/Menu Bar Dock.app` 생성 |
| `mise run run` | 앱을 빌드한 뒤 실행 |
| `mise run smoke` | 앱을 빌드한 뒤 실제 시작·설정 저장·정상 종료 검사 |
| `mise run package` | `dist/`에 ZIP·DMG·체크섬 생성 |

명령 정의는 [mise.toml](mise.toml), 빌드·테스트·패키징 구현은 [scripts/](scripts/)에 있습니다. 자동 테스트와 실기기 확인 범위는 구분해 검증 기록에 남깁니다.

## 코드와 문서

```text
DockDomain       앱 순서·고정·제외·표시 정책과 선택 세션
DockPersistence  JSON 저장, 원자 교체, 손상 복구
DockPlatform     앱 감지·실행·아이콘·로그인 항목
DockShortcuts    전역 단축키 등록·저장·충돌 복구
MenuBarDock      앱 수명, 유스케이스 조립, AppKit 화면
```

도메인은 Foundation만 참조합니다. 앱 목록과 설정은 이 Mac에 저장하고, 업데이트 확인은 사용자가 요청할 때 실행합니다.

| 문서 | 내용 |
| --- | --- |
| [사용 안내](docs/user-guide.md) | 설치, 설정, 단축키, 문제 해결 |
| [개발과 기여](CONTRIBUTING.md) | 로컬 작업 흐름, 책임 경계, 검증 기준 |
| [아키텍처](docs/architecture.md) · [모듈 계약](docs/module-contracts.md) | 상태와 데이터 흐름, 모듈별 책임 |
| [설계 결정](docs/adr/) | 기술 선택의 이유와 변경 기록 |
| [구현·검증 기록](docs/implementation-plan.md) | 진행 단계, 실행한 검사, 남은 확인 범위 |
| [빌드와 배포](docs/releasing.md) | 앱 번들, 패키지, 서명·공증, 게시 절차 |
| [보안](SECURITY.md) · [변경 기록](CHANGELOG.md) | 보안 제보와 버전별 변경 |

개발은 `main`에서 진행하며 검증한 변경을 직접 커밋·푸시합니다. PR과 GitHub Actions workflow는 사용하지 않습니다.

[EthanSK/Menu-Bar-Dock](https://github.com/EthanSK/Menu-Bar-Dock)의 사용 경험을 참고해 별도 코드로 구현했습니다. [MIT 라이선스](LICENSE)로 배포합니다.
