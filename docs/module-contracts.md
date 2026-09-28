# 구현 경계 계약

## DockDomain (Foundation만 사용)

- `AppID`: String rawValue, Hashable/Codable/Sendable, 기본 생성자는 UUID. `init(rawValue:)`.
- `AppEntry`: Identifiable/Codable/Equatable/Sendable. public var `id: AppID`, `name: String`, `bundleIdentifier: String?`, `bundlePath: String`, `bookmarkData: Data?`, `isPinned: Bool`, `isExcluded: Bool`, `lastSeen: Date`.
- `DockPreferences`: Codable/Equatable/Sendable. public var `iconSize: Double = 18`, `iconSpacing: Double = 4`, `maxVisibleApps: Int = 6`, `showsRunningApps: Bool = true`, `isCompact: Bool = false`, `shortcutEnabled: Bool = true`. 검증/정규화 제공.
- `DockConfiguration`: Codable/Equatable/Sendable. `schemaVersion: Int`, `apps: [AppEntry]`, `order: [AppID]`, `preferences: DockPreferences`. 기본 생성자. 중복·범위 정규화.
- `DockItem`: Equatable/Sendable/Identifiable. `app: AppEntry`, `isRunning: Bool`, id는 app.id.
- `DockCatalog`: 값 타입 aggregate. `configuration: DockConfiguration`, init(configuration:), upsert(AppEntry), pin(AppID, Bool), exclude(AppID, Bool), remove(AppID), move(fromOffsets: IndexSet, toOffset: Int), updatePreferences(DockPreferences), orderedApps, visibleItems(runningIDs: Set<AppID>). 순서 불변식 보장.
- `SwitcherSession`: 순서/선택만 관리. init(ids: [AppID], currentID: AppID?, direction: Int), `selectedID`, `ids`, move(Int), reconcile(validIDs: Set<AppID>).

## DockPersistence

`ConfigurationRepository` actor. init(directory: URL), load() throws -> ConfigurationLoadResult, save(DockConfiguration, revision: UInt64) throws.
`ConfigurationLoadResult`는 `configuration`, `warning: String?`, `isReadOnly: Bool`을 제공한다. 미래 schema를 덮어쓰지 않는다. 저장은 원자 교체와 마지막 정상 백업, revision 역전 방지를 수행한다.

## DockPlatform

모든 AppKit 연동은 명시적 MainActor. NSRunningApplication/NSImage를 도메인에 전달하지 않는다.

- `RunningAppSnapshot`: Sendable 값. `processIdentifier: Int32`, `bundleURL: URL?`, `bundleIdentifier: String?`, `name: String`, `isRegular: Bool`, `isActive: Bool`, `isHidden: Bool`, `launchDate: Date?`.
- `WorkspaceMonitor`: init(), start(onChange: @escaping @MainActor ([RunningAppSnapshot]) -> Void), stop(), snapshot() -> [RunningAppSnapshot]. 실행/종료/활성/숨김/wake 이벤트 기반.
- `ApplicationResolver`: init(), resolve(url: URL) throws -> AppEntry, refresh(AppEntry) -> AppEntry? (bookmark 복원).
- `ApplicationLauncher`: init(), open(AppEntry) async throws, hide(AppEntry), unhide(AppEntry), quit(AppEntry) -> Bool, reveal(AppEntry). 동일 앱 실행 요청 합치기.
- `IconRepository`: init(), image(for: AppEntry) -> NSImage, invalidate(). 캐시 비용 제한.
- `LoginItemService`: init(), isEnabled: Bool, statusDescription: String, setEnabled(Bool) throws.

## MenuBarDock

조립·AppModel·단축키 수명은 메인 작업자 책임이다. UI 작업자는 `UI/` 내부의 presentation model/콜백 계약을 정의해 공유한다. 도메인/OS 경계를 직접 호출하지 않고 model/callback으로 연결한다.

공유 파일인 Package.swift와 문서/스크립트는 메인 작업자가 관리한다. 각 작업자는 자신의 소스/테스트만 수정하고 다른 작업자의 변경을 되돌리지 않는다.
