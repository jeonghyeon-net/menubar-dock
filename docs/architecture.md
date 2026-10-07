# 기술 스택과 아키텍처

2026-09-28 · 현재 구현 기준. 검증 결과와 남은 실기기 검증은 [구현 기록](implementation-plan.md)에 구분한다.

## 제품 계약

사용자가 정한 순서를 유지하는 메뉴 막대 런처다. 설정에는 **항상 표시할 앱** 단일 목록을 제공한다. 미등록 실행 앱을 앞쪽에, 등록 앱을 뒤쪽에 지정 순서대로 표시하며 두 그룹에 같은 앱을 중복 표시하지 않는다. 실행 앱 자동 표시는 설정으로 끌 수 있다. 앱 활성화는 각 그룹의 상대 순서를 바꾸지 않는다. 실행 중 점·밑줄·배지와 예약 공간은 없다.

단축키는 Command+Space / Shift+Command+Space 이동, Enter 실행, Esc 취소다. Command를 놓아도 실행하지 않는다. 사용자가 조합을 변경할 수 있다. 이미 실행된 앱에는 표준 reopen/activate 요청을 보내고, 종료된 앱은 실행한다. 새 창의 디스플레이 강제 지정과 다른 앱 창 이동은 사용자 요청으로 제외했다.

선택 패널의 검색은 `NSMetadataQuery`로 macOS Spotlight 인덱스를 읽는다. `SearchSession`은 검색어별 결과와 선택을 관리하고, `SpotlightSearchService`는 OS 조회·취소·결과 변환을 담당한다. `SwitcherController`는 입력창을 유지한 채 앱 전환과 검색 결과를 전환한다. 새 입력마다 이전 요청을 취소하고 요청 세대 번호도 비교하여 늦은 응답을 버린다. 한글 조합 중에는 검색과 실행을 보류하며, 검색 결과 열기는 `SearchResultOpener`를 통해 처리한다. 검색 명령은 catalog의 등록·순서·제외 상태를 변경하지 않는다. 검색으로 새 앱을 실행했을 때의 Workspace 이벤트는 기존 자동 표시 정책을 따른다.

직접 파일을 순회하거나 새 검색 DB를 만들지 않는다. Spotlight 조회 조건에서 앱 번들로 범위를 제한하고 이름·표시 이름을 검색한다. 결과 변환 단계에서도 실행 가능한 앱 번들인지 검증하며 숨김 항목·SDK·프레임워크·앱 번들 내부를 제외한다. 검색 결과에는 아이콘과 앱 이름 한 줄만 표시한다. 결과는 작은 배치로 처리하며 입력·취소에 실행 기회를 돌려주고, 상위 50개만 유지한다. 검색어·결과를 영속화하지 않는다. 공개 API의 범위와 수명 관리는 [Apple의 NSMetadataQuery 문서](https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/SpotlightQuery/Concepts/QueryingMetadata.html)를 따른다.

## 기술 선택

| 영역 | 구현 |
| --- | --- |
| 언어·플랫폼 | Swift 6 모드, Swift 6.2+, macOS 14+, arm64 |
| 앱 수명 | NSApplicationDelegate, LSUIElement |
| 메뉴 막대 | 앱별 NSStatusItem과 NSStatusBarButton |
| 설정·선택 | AppKit 단일 설정 창 / NSTableView / NSPanel |
| OS 연동 | NSWorkspace, NSRunningApplication, SMAppService |
| 단축키 | Carbon RegisterEventHotKey, 조합만 등록 |
| 저장 | Codable JSON, actor, 원자 교체, 정상 백업 |
| 진단 | OSLog Logger, OSSignposter |
| 테스트 | Swift Testing, 주입 가능한 OS 경계, AppKit responder 테스트 |
| 빌드·배포 | Swift Package, mise 로컬 검증, 앱 번들·DMG 스크립트 |
| 업데이트 | 사용자가 요청할 때 GitHub Releases 확인 |

외부 패키지 의존성은 없다. [빌드 결정](adr/0001-native-package-app.md), [AppKit·단축키 결정](adr/0002-appkit-and-system-hotkeys.md), [업데이트 결정](adr/0003-explicit-update-check.md), [로컬 릴리스 결정](adr/0004-local-versioned-releases.md)에 근거와 트레이드오프를 남겼다. Developer ID 인증서가 있으면 Hardened Runtime 서명과 공증을 수행할 수 있다. 인증서 없는 빌드는 ad-hoc 서명이다.

## 경계와 데이터 흐름

```mermaid
flowchart TD
    MON[DockPlatform: WorkspaceMonitor] -->|RunningAppSnapshot| APP[ApplicationController / MainActor]
    UI[AppKit UI] -->|DockUIAction| APP
    KEY[DockShortcuts] -->|방향| APP
    APP --> DOMAIN[DockDomain: DockCatalog · SwitcherSession]
    APP <-->|configuration · revision| DISK[DockPersistence / actor]
    DOMAIN --> MODEL[DockPresentationModel]
    MODEL --> UI
    APP --> OS[DockPlatform: 실행 · 아이콘 · 로그인]
    APP --> UPDATE[ReleaseChecker / actor]
```

| 구성요소 | 책임 | 경계 |
| --- | --- | --- |
| DockCatalog aggregate | 설치 항목, 등록 순서, 실행 앱·등록 앱 표시 투영, 삭제·이력 정리 | Foundation만 참조 |
| SwitcherSession | 시작 시 순서 고정, 순환 선택, 제거된 항목 조정 | UI·프로세스에 독립 |
| ApplicationController | 이벤트 수신, 유스케이스, 저장 revision, 서비스 수명 | 유일한 영속 도메인 변경 지점 |
| ConfigurationRepository | schema 검사, 원자 저장·백업·손상 원본 보존 | actor가 파일 작업 직렬화 |
| WorkspaceMonitor | 앱 알림·KVO를 스냅샷으로 정규화 | UI 순서 정책 없음 |
| ApplicationLauncher | 정확한 설치 위치 실행, 실행 요청 병합, 프로세스 재검증 | backend 주입으로 OS 없는 테스트 |
| GlobalShortcutService | 등록 수명, 사용자 조합, 충돌 복구, 누름 반복 | 일반 키 입력 감시 없음 |
| UI controllers | 화면 표현, 입력을 명령으로 변환 | 저장·OS 실행 직접 접근 없음 |

단일 프로세스이며 helper, daemon, 데이터베이스를 두지 않는다. composition root가 서비스를 소유한다. 세부 값 타입마다 protocol을 만들지 않고 실제 외부 경계에 테스트 대역을 둔다. 동작 API는 [모듈 계약](module-contracts.md)을 따른다.

## 식별자와 순서

`AppID`는 설치 항목의 영속 UUID다. PID·앱 이름·bundle identifier를 영속 ID로 쓰지 않는다. `AppEntry`에 bundle 경로·identifier·bookmark를 저장한다. 같은 identifier라도 다른 설치 경로이면 서로 다른 항목이다. 같은 정규 경로·identifier의 저장 중복은 처음 배치한 ID와 순서에 합치고, 기존 등록·제외 정책과 최근 bookmark를 보존한다. bookmark로 이동한 앱을 복원하며, 경로를 잃으면 설정에서 다시 지정한다. `SavedAppRegistrar`는 위치 재지정 대상이 이미 임시 실행 항목에 있으면 기존 등록 ID와 순서를 유지해 병합한다. 검증 가능한 앱 번들 URL이 없는 프로세스는 목록에 넣지 않는다.

`DockConfiguration`은 항목 목록과 독립적인 `order: [AppID]`를 갖는다. `savedApps`는 항상 표시하도록 등록했고 제외되지 않은 항목만 저장 순서대로 반환하며, 설정 목록은 이 투영을 사용한다. `visibleItems(runningIDs:)`는 저장 순서에 있는 미등록 실행 앱을 먼저, `savedApps`를 나중에 연결한다. 등록 앱은 실행 여부에 따라 그룹을 옮기지 않는다.

`DockConfiguration.hiddenApps`는 등록 목록과 독립된 숨김 정책이다. 표시 투영에서 bundle identifier가 같은 앱을 제외하며 identifier가 없으면 정규 설치 경로로 구분한다. 관찰 ID·경로가 바뀌거나 이력을 정리해도 숨김 기록은 남는다. 등록 상태·순서는 바꾸지 않으며 Spotlight 검색에는 적용하지 않는다. 설정은 등록 앱과 숨김 앱을 나란히 보여 주고, 숨겨진 등록 행에는 숨김 상태를 표시한다. schema 3은 v1·v2를 읽고 이전 `hidesFinder`를 숨김 목록으로 한 번 이전한다. 구버전은 schema 3을 읽기 전용으로 보호한다.

`save(id)`는 미등록 항목을 등록 목록 끝에 추가한다. 이미 등록한 항목은 순서를 유지한다. `moveSaved(fromOffsets:toOffset:)`는 설정에 보이는 부분 목록의 인덱스로 이동하며, 미등록 이력의 상대 순서를 바꾸지 않는다. `+`와 아이콘 메뉴의 **목록에 추가**는 같은 등록 정책을 사용한다. 파일 선택으로 추가할 때는 등록 복사본의 bookmark를 먼저 복구해, 앱 이동 직후에도 기존 ID를 찾아 끝에 저장하고 충돌 시 원래 설정을 보존한다. 자동 감지와 활성화 이벤트는 기존 등록 순서를 덮지 않는다.

이전 저장 파일과의 호환을 위해 `isPinned`·`isExcluded` 필드는 유지한다. 등록 상태는 `isPinned`, 과거 제외 상태는 `isExcluded`로 읽지만 화면에는 고정·표시 체크를 노출하지 않는다. 비고정·비실행·비제외 이력은 90일/256개 상한으로 정리하고 등록·제외·실행 항목은 보호한다. 목록에서 제거하면 고정만 해제한다. 실행 중이면 앞쪽 임시 그룹에 남고 종료하면 사라진다. 이전 삭제 기록도 실행 앱을 숨기지 않으며, Dock이 자동으로 다시 고정하는 것만 막는다.

실행 상태는 `RunningAppSnapshot`으로 분리한다. PID에 bundle URL과 launchDate를 함께 비교하여 PID가 재사용된 뒤 다른 프로세스를 숨기거나 종료하지 않는다. 모든 AppKit 작업은 MainActor에서 수행한다. 파일 저장은 actor에 보내고 늦은 revision을 거절한다.

## 시작·이벤트·종료

설정 로드·v1 마이그레이션 → bookmark 복구 → macOS Dock 감시·초기 반영 → UI controller 준비 → 관찰 시작·초기 스냅샷 → 최종 표시 목록 → 앱별 status item 게시 순서다. 초기 빈 슬롯을 여러 개 생성하지 않는다. 시작 중 Finder 재실행 요청은 설정이 준비될 때 처리한다.

WorkspaceMonitor는 runningApplications KVO와 실행·종료·활성화·숨김·wake 알림을 사용한다. 활성화 알림 payload를 보존하고 accessor를 다시 읽어 덮지 않는다. 초기·wake 등에서 스냅샷을 조정하며 주기 polling은 없다. [실행 앱 KVO](https://developer.apple.com/documentation/appkit/nsworkspace/runningapplications), [종료 알림의 범위](https://developer.apple.com/documentation/appkit/nsworkspace/didterminateapplicationnotification).

설정은 변경 후 180ms 동안 합쳐 저장한다. 종료 시 변경 수신을 멈추고 최신 revision을 저장한 뒤 관찰자·단축키·패널을 해제한다. 저장 실패는 종료를 취소하거나 사용자가 명시적으로 저장 없이 종료할 수 있도록 안내한다. 일반 저장 실패도 설정에 표시한다.

## 메뉴 막대와 디스플레이

앱 하나가 독립된 `NSStatusItem`과 `NSStatusBarButton` 하나를 갖는다. 표준 버튼의 `.leftMouseUp` target/action이 그 슬롯의 AppID를 열기 명령으로 전달한다. `.rightMouseUp`과 Control-클릭은 그 버튼에 고정된 `NSMenu`를 열며 앱 실행 요청을 보내지 않는다. 합성 이미지, 부모 버튼 안의 자식 버튼, 클릭 좌표를 앱 ID로 변환하는 입력 처리는 사용하지 않는다.

원본 Menu-Bar-Dock의 `MenuBarItem` / `MenuBarItems`처럼 물리적 슬롯과 앱 항목을 분리한다. 유효한 메뉴 막대 좌표가 모두 준비되면 슬롯을 왼쪽부터 정렬하고 도메인의 최종 표시 순서를 대응시킨다. 초기 배치는 생성 순서를 사용하고, 재배치 중 좌표가 비거나 겹치면 마지막 유효 순서를 유지한다. 각 슬롯의 autosaveName은 생존하는 동안 유지한다. 앱 수가 줄면 표시에서 빠지는 앱의 실제 슬롯을 제거하여 남은 앱의 이미지가 다른 슬롯으로 옮겨 갔다가 사라지지 않게 한다. 길이 0인 예약 항목은 두지 않는다.

기본 아이콘은 24pt(16–32pt), 추가 간격은 0pt(0–28pt)다. 원본의 custom image view와 표준 버튼의 렌더링 경계는 다르므로 원본의 40pt 수치를 그대로 사용하지 않는다. 이미지에는 요청한 크기를 그대로 적용한다. 표준 버튼이 이미지 크기에 맞춰 높이를 결정하므로 이전 버튼 높이를 크기의 상한으로 사용하지 않는다. 영역 너비는 아이콘 크기와 추가 간격의 합이다. 0pt에서는 앱이 여백을 추가하지 않으며 macOS가 각 독립 상태 항목에 붙이는 기본 여백은 남는다. 아이콘 크기를 바꿔도 추가 간격을 보존한다. 이미지 크기를 바꿀 때는 독립 복사본을 사용한다. 강제 aqua/darkAqua, 고정 대비 필터, 강제 active material을 사용하지 않는다. 표준 시스템 버튼이 외관과 입력을 담당한다.

상단에는 앱 아이콘만 표시한다. 관리용 말줄임표나 런처 glyph는 없다. 표시 개수를 넘긴 앱은 Command+Space 선택 패널에서 열고, 우클릭 또는 Control-클릭 메뉴에서 모든 옵션이 있는 단일 설정 창을 연다. Finder에서 앱 재실행 또는 선택 패널의 톱니 버튼으로도 설정을 연다. 앱이 없으면 상태 항목도 없다. 첫 실행은 설정을 열어 앱을 추가할 수 있게 한다.

사용자 [회귀 참고 이미지](assets/inactive-display-reference.png)의 흰색 번짐과 청록색 편향은 두 화면에서 비교해야 한다. 외관 강제 지정을 제거한 것만으로 이 문제가 해결됐다고 확정하지 않는다. 노치나 메뉴 폭 때문에 항목이 가려지면 표시 개수를 줄이거나 키보드 선택 패널을 사용한다. `isVisible`은 가림 판정 수단이 아니다. [Apple 문서](https://developer.apple.com/documentation/appkit/nsstatusitem/isvisible).

## 키보드와 실행

선택 패널은 생성 시 nonactivatingPanel 스타일을 고정한 NSPanel이다. 위쪽에 네이티브 검색창을 유지하고 아래에는 앱 아이콘과 선택 이름 또는 검색 결과 목록을 표시한다. 높이는 표시 중인 내용에 맞춰 조절한다. 앱 선택 화면의 작은 톱니 버튼으로 설정을 연다. 둥근 layer와 함께 NSVisualEffectView.maskImage를 적용하여 배경 재질과 그림자도 같은 윤곽으로 자른다. [재질 마스크 계약](https://developer.apple.com/documentation/appkit/nsvisualeffectview/maskimage). 마우스가 있는 화면의 visibleFrame에 표시하며, 화면 구성 변경 시 닫는다. 타 앱 창 위치를 조사하지 않는다. [NSPanel 스타일](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel).

세션이 열릴 때 목록 순서를 고정한다. 선택 도중 새 앱은 추가하지 않고 사라진 항목만 제거한다. 현재 앱이 없으면 정방향 첫 항목·역방향 마지막 항목부터 시작한다. 방향키·Tab도 이동하며 Return/keypad Enter로 실행한다. 검색 중 좌우 방향키는 글자 커서를 움직이고, Escape는 검색어를 지운 뒤 비어 있는 상태에서 패널을 닫는다. 전역 단축키와 패널 입력이 중복 이동하지 않도록 등록 조합은 전역 경로에서 처리한다.

기본 조합은 ⌘ Space와 ⇧⌘ Space다. Carbon에는 지정 조합 두 개만 등록한다. 설정 기록 동안 등록을 중지하고 재개하며, 충돌 때 이전 조합을 복구한다. 키를 누르는 동안에만 반복 타이머가 있고 release/suspend/stop 시 제거한다. 단축키 실패해도 마우스와 설정에 접근할 수 있다.

`DockPlatform.SpotlightShortcutOverride`는 ⌘ Space를 등록하기 전에 같은 조합인 Spotlight 시스템 항목 64만 해제하고 변경을 적용한다. 두 키 중 하나라도 등록에 실패하면 이번 시스템 설정 변경을 복구한다. 다른 단축키 항목과 사용자가 따로 지정한 Spotlight 조합은 보존한다. 성공한 해제는 앱 종료 후에도 유지한다. macOS가 해제한 Spotlight 조합의 독점권을 유지하면, ⌘ Space만 Spectacle/MASShortcut과 같은 일반 Carbon 등록으로 전환한다. 먼저 `CopySymbolicHotKeys`로 활성 시스템 충돌이 없는지 확인하며 다른 조합은 독점 등록을 유지한다. 자세한 근거와 한계는 [단축키 설계 결정](adr/0005-command-space-override.md)에 있다.

단축키 저장 데이터에는 기본값 세대를 기록한다. 이전 기본 조합 두 개를 함께 쓰던 설정만 한 번 이전하며, 새 버전에서 사용자가 다시 지정한 조합은 다음 시작에도 유지한다. 선택 패널은 표시 문자열이 아니라 현재 등록한 키 코드·수정 키와 비교해 중복 입력을 소비한다.

ApplicationLauncher는 같은 설치 경로의 진행 중 요청을 합친다. NSWorkspace.openApplication에 `createsNewApplicationInstance=false`, `allowsRunningApplicationSubstitution=false`를 명시한다. 신규·기존 앱 모두 activates=true인 표준 open/reopen 요청을 한 번 보낸다. 비활성 reopen 후 별도 activate를 보내던 경로는 제거했다. 다른 설치 위치가 반환되거나 OS가 실행을 거절하면 오류를 전달한다. 사용자 의도 없는 재시도나 강제 focus 탈취는 없다. [OpenConfiguration](https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration).

앱 종료 Bool은 요청 수락 여부이며 실제 종료는 이벤트로 확인한다. 저장 대화상자로 종료가 취소되면 계속 실행 중인 앱이다. [terminate 계약](https://developer.apple.com/documentation/appkit/nsrunningapplication/terminate()).

## 저장·보안·배포

`~/Library/Application Support/net.jeonghyeon.MenuBarDock/preferences.json`에 schema 2, 앱, order, 표시 설정을 저장한다. 1.0.1에서 저장한 40pt 기본값은 로드 시 24pt로 보정하며 앱·순서·고정·제외는 유지한다. 아이콘보다 좁은 기존 영역 너비는 손상 경고 없이 넓힌다. 단축키 조합만 UserDefaults에 단독 저장한다. 로그인 상태는 SMAppService에서 읽는다.

- 파일은 원자 교체, 정상 백업, 오래된 revision 거부로 보호한다.
- 손상 JSON은 별도 파일로 보존하고 백업 또는 기본값으로 복구한다.
- 미래 schema는 읽기 전용으로 열고 원본과 백업을 덮지 않는다.
- 디렉터리 0700, 설정 파일 0600 권한을 사용한다.
- 프로세스 목록·아이콘·선택 상태는 영속화하지 않는다.
- 자동 네트워크 통신·원격 분석이 없다. 업데이트 확인은 사용자 명령으로만 실행한다.
- 업데이트 URL은 HTTPS, GitHub 호스트, 이 저장소의 releases/tag 경로를 검증한다.

타 앱 정상 종료 기능을 포함하므로 App Sandbox를 사용하지 않는 직접 배포다. 손쉬운 사용·입력 모니터링·화면 기록·관리자 권한은 요구하지 않는다. Developer ID·공증은 [배포 절차](releasing.md)에 별도 기록한다.

## 성능과 검증 범위

이벤트 기반 갱신, 외부 런타임 없음, 16MiB 아이콘 캐시, 작은 도메인 값 연산, idle polling 없음으로 불필요한 작업을 줄였다. arm64 빌드는 Rosetta를 요구하지 않는다. 이를 기존 앱 대비 성능 개선 수치로 주장하지 않는다.

OSSignposter에 event-to-render, switcher-open, launch-request 구간을 남긴다. Release 앱에서 idle CPU·메모리·키 입력 지연을 측정하며 타 앱의 시작 시간과 우리 요청 전달 시간을 구분한다. Instruments 장시간 사용, 실제 두 화면/Spaces/로그인 부팅 검증은 자동 단위 테스트와 별도다.

소스는 Sources의 다섯 모듈, Tests의 대응 테스트, Config/Info.plist, scripts, docs로 구성한다. 프로젝트는 main 하나로 운영한다. GitHub Actions는 사용하지 않으며 mise 또는 Makefile의 명시적인 로컬 명령으로 빌드·테스트·패키징·번들 self-test를 수행한다.

## 단일 설정 창과 슬라이더 입력

설정에는 탭이나 카드 배경을 두지 않는다. 위쪽 **항상 표시할 앱** 목록만 스크롤하고 아래쪽 크기·자동 표시·단축키와 하단 도움말을 한 창에서 사용한다. 목록에는 앱 이름과 추가·제거·순서 이동 조작만 제공하며, 고정·표시 체크 열은 두지 않는다. 실행 중인 미등록 앱은 설정 목록에 넣지 않는다.

슬라이더가 추적 중일 때는 저장값을 손잡이에 되쓰지 않는다. 손잡이는 AppKit이 추적하고 표시 레이블과 명령 값만 정수로 변환한다. 같은 값의 로그인·단축키 상태를 중복 게시하지 않아 불필요한 전체 설정 갱신도 줄인다.

## macOS Dock 자동 감지

`SystemDockReader`는 com.apple.dock의 persistent-apps를 읽고 Finder와 설치된 로컬 앱 URL만 반환한다. `SystemDockMonitor`는 설정 파일과 부모 디렉터리의 변경 이벤트를 감시하여 원자 교체 뒤에도 갱신한다. 짧은 debounce와 실제 앱 목록 비교를 거치며 polling이나 Dock 파일 변경은 하지 않는다.

`SystemDockCatalogImporter`는 같은 설치 경로·호환되는 identifier를 기존 ID에 연결한다. `knownSystemDockPaths`를 기록하여 처음 발견한 Dock 항목만 등록 목록 끝에 Dock 순서대로 추가한다. 사용자의 고정 해제와 과거 제외 기록은 되돌리지 않는다. 이미 등록한 앱의 순서는 유지하며 macOS Dock에서 빠진 항목도 자동으로 제거하지 않는다. 해석 실패한 경로는 성공 기록에서 제외하여 다음 시작·변경 이벤트 때 재시도한다.

`−`는 항목의 ID와 순서를 유지한 채 고정·제외를 해제한다. 호환 필드 `removedApps`에는 Dock 자동 고정을 억제할 기록을 남긴다. 실행 앱 관찰은 이 기록에 있는 앱도 같은 ID의 임시 항목으로 연결하고, bookmark로 이동한 설치 경로를 갱신한다. 종료한 앱은 표시에서만 빠지므로 재실행해도 등록 목록의 순서를 바꾸지 않는다. 명시적 추가는 억제 기록을 해제하고 등록 목록 끝에 저장한다. 내부 중복 정리는 고정 해제와 별도 연산으로 처리하며 억제 기록을 만들지 않는다. 저장 형식은 schema 2와 호환된다.

## 릴리스 도구

배포 앱과 분리된 Python 3 표준 라이브러리 도구가 Git 태그 기반 버전, 한국어 변경 노트, 패키지 manifest와 게시 순서를 관리한다. `release.py`는 검증된 `main`에서만 태그·초안·첨부 파일을 생성하고, 업로드한 파일을 다시 내려받아 일치할 때 공개한다. 앱은 기존 `ReleaseChecker`로 공개된 최신 정식 릴리스를 읽으며 자동 설치는 하지 않는다. 명령과 파일 계약은 [배포 안내](releasing.md), 실행 결과는 [릴리스 도구 검증](verification/2026-09-28-release-pipeline.md)에 정리한다.
