import Foundation

/// 표시 순서와 사용자 정책을 한 경계 안에서 변경하는 aggregate다.
public struct DockCatalog: Sendable {
    public private(set) var configuration: DockConfiguration

    public init(configuration: DockConfiguration = DockConfiguration()) {
        self.configuration = configuration.normalized()
    }

    public var orderedApps: [AppEntry] {
        let entries = Dictionary(uniqueKeysWithValues: configuration.apps.map { ($0.id, $0) })
        return configuration.order.compactMap { entries[$0] }
    }

    /// 설정에서 관리할 항상 표시 앱만 저장 순서대로 반환한다.
    public var savedApps: [AppEntry] {
        orderedApps.filter { $0.isPinned && !$0.isExcluded }
    }

    public mutating func upsert(_ app: AppEntry) {
        guard !app.id.rawValue.isEmpty, !isRemoved(app) else { return }
        if let index = configuration.apps.firstIndex(where: { $0.id == app.id }) {
            var updated = app
            let previous = configuration.apps[index]
            // 관찰 이벤트가 고정·제외 정책과 마지막 확인 시간을 되돌리지 못하게 한다.
            updated.isPinned = previous.isPinned
            updated.isExcluded = previous.isExcluded
            updated.lastSeen = max(previous.lastSeen, app.lastSeen)
            updated.bookmarkData = app.bookmarkData ?? previous.bookmarkData
            configuration.apps[index] = updated
        } else {
            configuration.apps.append(app)
            configuration.order.append(app.id)
        }
    }

    public func isRemoved(_ app: AppEntry) -> Bool {
        configuration.removedApps.contains { $0.id == app.id || sameInstallation($0, app) }
    }

    /// 명시적으로 추가한 설치만 삭제 기록에서 복원한다. 기존 ID를 재사용하고 복원 위치는 목록 끝이다.
    @discardableResult
    public mutating func upsertRestoring(_ app: AppEntry) -> AppID? {
        guard !app.id.rawValue.isEmpty else { return nil }
        let existing = orderedApps.first { $0.id == app.id || sameInstallation($0, app) }
        let removed = configuration.removedApps.first { $0.id == app.id || sameInstallation($0, app) }
        var restored = app
        restored.id = existing?.id ?? removed?.id ?? app.id
        if let removed {
            restored.bookmarkData = app.bookmarkData ?? removed.bookmarkData
            restored.lastSeen = max(app.lastSeen, removed.lastSeen)
        }
        configuration.removedApps.removeAll {
            $0.id == restored.id || $0.id == app.id || sameInstallation($0, app)
        }
        upsert(restored)
        return restored.id
    }

    /// bookmark로 찾은 새 위치도 삭제 상태로 남겨 자동 관찰이 앱을 되살리지 않게 한다.
    public mutating func refreshRemovedApp(_ app: AppEntry) {
        guard let index = configuration.removedApps.firstIndex(where: { $0.id == app.id }) else { return }
        let previous = configuration.removedApps[index]
        var refreshed = app
        refreshed.isPinned = previous.isPinned
        refreshed.isExcluded = previous.isExcluded
        refreshed.bookmarkData = app.bookmarkData ?? previous.bookmarkData
        refreshed.lastSeen = max(app.lastSeen, previous.lastSeen)
        configuration.removedApps[index] = refreshed
        let removedIDs = Set(configuration.apps.filter { isRemoved($0) }.map(\.id))
        configuration.apps.removeAll { removedIDs.contains($0.id) }
        configuration.order.removeAll { removedIDs.contains($0) }
    }

    public mutating func pin(_ id: AppID, _ isPinned: Bool) {
        guard let index = configuration.apps.firstIndex(where: { $0.id == id }) else { return }
        configuration.apps[index].isPinned = isPinned
        if isPinned { configuration.apps[index].isExcluded = false }
    }

    /// 새 등록은 저장 목록 끝에 추가하고 이미 등록된 앱의 순서는 바꾸지 않는다.
    public mutating func save(_ id: AppID) {
        guard let index = configuration.apps.firstIndex(where: { $0.id == id }) else { return }
        let wasSaved = configuration.apps[index].isPinned && !configuration.apps[index].isExcluded
        configuration.apps[index].isPinned = true
        configuration.apps[index].isExcluded = false
        guard !wasSaved else { return }
        configuration.order.removeAll { $0 == id }
        configuration.order.append(id)
    }

    public mutating func exclude(_ id: AppID, _ isExcluded: Bool) {
        guard let index = configuration.apps.firstIndex(where: { $0.id == id }) else { return }
        configuration.apps[index].isExcluded = isExcluded
    }

    public mutating func remove(_ id: AppID, suppressRediscovery: Bool = true) {
        guard let app = configuration.apps.first(where: { $0.id == id }) else { return }
        if suppressRediscovery {
            configuration.removedApps.removeAll { $0.id == id || sameInstallation($0, app) }
            configuration.removedApps.append(app)
        }
        let removedIDs = Set(configuration.apps.filter {
            $0.id == id || (suppressRediscovery && sameInstallation($0, app))
        }.map(\.id))
        configuration.apps.removeAll { removedIDs.contains($0.id) }
        configuration.order.removeAll { removedIDs.contains($0) }
    }

    /// SwiftUI 목록의 이동 계약처럼 삭제 전 배열의 삽입 위치를 받는다.
    public mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let order = configuration.order
        guard (0...order.count).contains(destination),
              offsets.allSatisfy({ order.indices.contains($0) }), !offsets.isEmpty else { return }
        let moving = offsets.map { order[$0] }
        var remaining = order.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertion = destination - offsets.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: insertion)
        configuration.order = remaining
    }

    /// 저장 목록의 인덱스만 재배치해 임시·숨김 항목의 위치와 상대 순서를 유지한다.
    public mutating func moveSaved(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let savedOrder = savedApps.map(\.id)
        guard (0...savedOrder.count).contains(destination), !offsets.isEmpty,
              offsets.allSatisfy({ savedOrder.indices.contains($0) }) else { return }
        let moving = offsets.map { savedOrder[$0] }
        var remaining = savedOrder.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertion = destination - offsets.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: insertion)
        let savedIDs = Set(savedOrder)
        let positions = configuration.order.indices.filter { savedIDs.contains(configuration.order[$0]) }
        for (position, id) in zip(positions, remaining) { configuration.order[position] = id }
    }

    public mutating func updatePreferences(_ preferences: DockPreferences) {
        configuration.preferences = preferences.normalized()
    }

    public mutating func updateKnownSystemDockPaths(_ paths: [String]) {
        var seen = Set<String>()
        configuration.knownSystemDockPaths = paths.filter { !$0.isEmpty }.map(installationPath)
            .filter { seen.insert($0).inserted }
    }

    /// 메뉴 막대의 폭 제한 전 후보다. 숨겨진 초과 항목도 선택 패널에서는 접근할 수 있다.
    public func visibleItems(runningIDs: Set<AppID>) -> [DockItem] {
        let temporary = configuration.preferences.showsRunningApps ? orderedApps.filter {
            !$0.isPinned && !$0.isExcluded && runningIDs.contains($0.id)
        } : []
        // 실행 이벤트는 저장 순서를 변경하지 않는다. 임시 앱도 기존 관찰 순서만 사용한다.
        return (temporary + savedApps).map { DockItem(app: $0, isRunning: runningIDs.contains($0.id)) }
    }

    /// 사용자가 고정·제외한 기록과 실행 중 앱을 보호하며 오래된 관찰 기록만 정리한다.
    public mutating func pruneHistory(
        runningIDs: Set<AppID>, now: Date = Date(), maximumAge: TimeInterval = 90 * 24 * 60 * 60,
        maximumEntries: Int = 256
    ) {
        let disposable = configuration.apps.filter { !$0.isPinned && !$0.isExcluded && !runningIDs.contains($0.id) }
        let expired = Set(disposable.filter { now.timeIntervalSince($0.lastSeen) > max(0, maximumAge) }.map(\.id))
        let remaining = disposable.filter { !expired.contains($0.id) }.sorted {
            if $0.lastSeen != $1.lastSeen { return $0.lastSeen > $1.lastSeen }
            return $0.id.rawValue < $1.id.rawValue
        }
        let overflow = Set(remaining.dropFirst(max(0, maximumEntries)).map(\.id))
        let removed = expired.union(overflow)
        configuration.apps.removeAll { removed.contains($0.id) }
        configuration.order.removeAll { removed.contains($0) }
    }
}
