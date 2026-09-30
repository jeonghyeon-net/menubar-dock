# 구현 경계 계약

## DockDomain (Foundation만 사용)

- `AppID`: String rawValue, Hashable/Codable/Sendable, 기본 생성자는 UUID. `init(rawValue:)`.
- `AppEntry`: Identifiable/Codable/Equatable/Sendable. public var `id: AppID`, `name: String`, `bundleIdentifier: String?`, `bundlePath: String`, `bookmarkData: Data?`, `isPinned: Bool`, `isExcluded: Bool`, `lastSeen: Date`. `isPinned`·`isExcluded`는 기존 저장 파일과 호환하기 위해 유지하며, UI에서는 등록 목록으로 표현한다.
- `DockPreferences`: Codable/Equatable/Sendable. public var `iconSize: Double = 24`, `slotWidth: Double = 24`, `maxVisibleApps: Int = 6`, `showsRunningApps: Bool = true`, `shortcutEnabled: Bool = true`. 검증/정규화 제공. `slotWidth >= iconSize`를 보장한다.
- `DockConfiguration`: Codable/Equatable/Sendable. `schemaVersion: Int`, `apps: [AppEntry]`, `order: [AppID]`, `preferences: DockPreferences`, `removedApps: [AppEntry]`, `knownSystemDockPaths: [String]`. 기본 생성자. 중복·범위 정규화.
- `DockItem`: Equatable/Sendable/Identifiable. `app: AppEntry`, `isRunning: Bool`, id는 app.id.
- `DockCatalog`: 값 타입 aggregate. `configuration: DockConfiguration`, `init(configuration:)`, `upsert(AppEntry) -> AppID?`, `save(AppID)`, `remove(AppID)`, `discard(AppID)`, `upsertRestoring(AppEntry) -> AppID?`, `isAutomaticPinningSuppressed(AppEntry)`, `moveSaved(fromOffsets: IndexSet, toOffset: Int)`, `updatePreferences(DockPreferences)`, `orderedApps`, `savedApps`, `visibleItems(runningIDs: Set<AppID>)`.
- `orderedApps`는 자동 감지 이력을 포함한 전체 저장 순서, `savedApps`는 등록했고 제외되지 않은 항목의 부분 목록이다. `visibleItems`는 미등록 실행 앱을 앞에, 등록 앱을 뒤에 배치한다. 각 그룹 안에서 저장 순서를 보존하고 같은 ID를 중복 표시하지 않는다.
- `save`는 새로 등록한 항목을 등록 목록 끝에 추가하며 이미 등록한 항목의 순서는 유지한다. `moveSaved`의 인덱스는 `savedApps` 기준으로 해석하고 미등록 이력의 상대 순서를 보존한다. 기존 `pin`·`exclude`·전체 목록 `move`는 내부 저장 호환과 도메인 연산으로 남으며 새 설정 UI의 명령으로 사용하지 않는다.
- `SwitcherSession`: 순서/선택만 관리. `init(ids: [AppID], currentID: AppID?, direction: Int)`, `selectedID`, `ids`, `move(Int)`, `reconcile(validIDs: Set<AppID>)`.

## DockPersistence

`ConfigurationRepository` actor. `init(directory: URL)`, `load() throws -> ConfigurationLoadResult`, `save(DockConfiguration, revision: UInt64) throws`.
`ConfigurationLoadResult`는 `configuration`, `warning: String?`, `isReadOnly: Bool`을 제공한다. 미래 schema를 덮어쓰지 않는다. 저장은 원자 교체와 마지막 정상 백업, revision 역전 방지를 수행한다.

## DockPlatform

모든 AppKit 연동은 명시적 MainActor. NSRunningApplication/NSImage를 도메인에 전달하지 않는다.

- `RunningAppSnapshot`: Sendable 값. `processIdentifier: Int32`, `bundleURL: URL?`, `bundleIdentifier: String?`, `name: String`, `isRegular: Bool`, `isActive: Bool`, `isHidden: Bool`, `launchDate: Date?`.
- `WorkspaceMonitor`: `init()`, `start(onChange: @escaping @MainActor ([RunningAppSnapshot]) -> Void)`, `stop()`, `snapshot() -> [RunningAppSnapshot]`. 실행/종료/활성/숨김/wake 이벤트 기반.
- `ApplicationResolver`: `init()`, `resolve(url: URL) throws -> AppEntry`, `refresh(AppEntry) -> AppEntry?` (bookmark 복원).
- `ApplicationLauncher`: `init()`, `open(AppEntry) async throws`, `hide(AppEntry)`, `unhide(AppEntry)`, `quit(AppEntry) -> Bool`, `reveal(AppEntry)`. 동일 앱 실행 요청 합치기.
- `IconRepository`: `init()`, `image(for: AppEntry) -> NSImage`, `invalidate()`. 캐시 비용 제한.
- `LoginItemService`: `init()`, `isEnabled: Bool`, `statusDescription: String`, `setEnabled(Bool) throws`.

## MenuBarDock

조립·AppModel·단축키 수명은 메인 작업자 책임이다. UI 작업자는 `UI/` 내부의 presentation model/콜백 계약을 정의해 공유한다. 도메인/OS 경계를 직접 호출하지 않고 model/callback으로 연결한다.

공유 파일인 Package.swift와 문서/스크립트는 메인 작업자가 관리한다. 각 작업자는 자신의 소스/테스트만 수정하고 다른 작업자의 변경을 되돌리지 않는다.

## DockShortcuts

AppKit/Carbon 경계다. 다른 로컬 target에 의존하지 않는다.

- `ShortcutAction`: forward / backward.
- `ShortcutBinding`: keyCode, NSEvent modifier raw value, 표시 문자, displayName, 기본 조합과 입력 검증.
- `GlobalShortcutService`: setEnabled, setBinding, binding, reset, suspend, stop.
- `cancelCurrentPress()`: 패널을 닫을 때 현재 누름의 반복을 제거하고 release까지 재호출을 막는다.
- 등록 backend를 주입해 충돌·롤백·키 해제·재진입을 실제 시스템 설정 변경 없이 테스트한다.
- 기본 조합은 ⌘ Space / ⇧⌘ Space다. UserDefaults가 단축키 조합과 기본값 이전 세대를 단독 소유한다. 등록 실패 상태와 사용자가 원하는 enabled 상태를 구분한다.
- `ApplicationController`가 `DockPlatform.SpotlightShortcutOverride`를 등록 준비 콜백으로 연결한다. 시스템 설정 변경은 플랫폼에서, 두 키 등록과 실패 시 복구는 단축키 서비스에서 책임진다. `--smoke-test`에서는 이 경로를 실행하지 않는다.

## UI와 앱 조립

`DockPresentationModel`은 items/apps/preferences/login/notice/단축키 표시 문자열과 이미지 공급자를 제공한다. `items`는 `visibleItems`의 최종 표시 목록이며, 설정용 `apps`는 `savedApps` 투영이다. `DockUIAction`을 `ApplicationController`로 보내 유스케이스를 수행한다. `StatusItemController`, `SwitcherController`, `SettingsWindowController`는 이 모델만 읽는다.

설정은 **항상 표시할 앱** 단일 목록을 제공한다. `+`와 아이콘 메뉴의 **목록에 추가**는 등록 명령으로, 행 드래그·위아래 이동은 `moveSaved`로 연결한다. 등록 앱의 **목록에서 제거**와 설정의 `−`는 `remove`를 호출해 고정만 해제한다. 설정 행은 사라지지만 실행 중인 앱은 임시 그룹에 남고 종료하면 숨겨진다. `removedApps`는 Dock의 자동 재고정을 막는 호환 필드이며 실행 앱 감지를 막지 않는다. 명시적 추가는 이 기록을 해제한다. 아이콘 메뉴는 **목록에 추가/목록에서 제거 → 설정 → 종료** 순서이며 구분선·단축키 표시는 없다.

`WorkspaceCatalogReconciler`는 관찰 스냅샷을 catalog에 병합하고 경로 이동 시 bookmark로 기존 ID를 복구한다. 고정 해제 기록도 이동한 경로로 갱신한다. 이전에 삭제했던 실행 앱은 같은 ID의 임시 항목으로 복원하며, Dock 자동 가져오기는 고정 해제 기록을 계속 존중한다.

`SavedAppRegistrar.register(_:replacing:in:refresh:) throws`는 앱 추가와 위치 재지정의 등록 규칙을 조립 계층에서 공유한다. 주입한 resolver로 catalog 복사본의 bookmark를 먼저 복구하여 이동 직후 다시 추가해도 기존 설치 ID를 재사용한다. 충돌 시 원본은 변경하지 않는다. 재지정한 앱이 이미 임시 실행 항목으로 감지돼 있다면 기존 등록 ID와 순서를 유지해 병합한다. `ReleaseChecker` actor는 사용자 요청 때만 HTTPS API를 읽고 검증된 릴리스 페이지를 반환한다. `ApplicationMenu`는 표준 AppKit 앱·편집·윈도우 메뉴를 구성한다.

전체 소스 계약은 Swift compiler와 대응 Tests target으로 검증한다. 과거 설계의 AppStore/reducer/effect 명칭 대신 현재 구현은 ApplicationController + DockCatalog의 값 연산을 사용한다.

## 선택 패널 검색

- `SearchResult`/`SearchSession` (`DockDomain`): 파일 URL·이름·종류와 검색어별 선택 상태. 새 검색어는 결과를 즉시 비우고 동일 검색어의 갱신은 선택 ID를 보존한다.
- `SpotlightSearching` (`DockPlatform`): `search(_:receive:)`/`cancel()`. 결과·완료·오류를 `SpotlightSearchUpdate`로 전달하며 AppKit/Foundation 조회 객체는 모듈 밖으로 내보내지 않는다.
- `SpotlightSearchService`: `NSMetadataQuery`의 앱 번들 조건으로 기존 색인을 읽고 실행 가능한 앱만 반환한다. 숨김·SDK·프레임워크·앱 내부 결과를 제외한다. 취소된 요청의 콜백은 무시한다.
- `SearchResultOpener`: 앱 종류·로컬 URL·실행 가능 여부와 bundle ID를 실행 직전에 다시 검증하고 기존 resolver/launcher로 연다. 파일·폴더 결과는 거부한다.
- `SwitcherController`: 네이티브 검색 입력과 100ms 입력 지연 처리, 세션별 요청 격리, 앱 선택 복원. 검색 결과는 경로 없이 아이콘과 앱 이름만 표시한다. `DockUIAction.openSearchResult`로 실행하며 catalog에 추가하지 않는다.

`SystemDockReader.applicationURLs()`는 macOS Dock을 변경하지 않고 Finder와 고정 앱의 로컬 URL을 순서대로 읽는다. 조립 계층의 `SystemDockCatalogImporter`는 기존 ID·순서·제외·고정 해제를 유지하며 처음 발견한 Dock 앱만 등록 목록 끝에 합친다. `SystemDockMonitor.start(onChange:)`는 파일 변경 감시를 시작하며 실패 시 오류를 던진다. `stop()`은 감시와 대기 작업을 정리한다. 자동 고정 억제 기록과 기존 Dock 경로는 `removedApps`·`knownSystemDockPaths`에 저장한다.
