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

    public mutating func upsert(_ app: AppEntry) {
        guard !app.id.rawValue.isEmpty else { return }
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

    public mutating func pin(_ id: AppID, _ isPinned: Bool) {
        guard let index = configuration.apps.firstIndex(where: { $0.id == id }) else { return }
        configuration.apps[index].isPinned = isPinned
        if isPinned { configuration.apps[index].isExcluded = false }
    }

    public mutating func exclude(_ id: AppID, _ isExcluded: Bool) {
        guard let index = configuration.apps.firstIndex(where: { $0.id == id }) else { return }
        configuration.apps[index].isExcluded = isExcluded
    }

    public mutating func remove(_ id: AppID) {
        configuration.apps.removeAll { $0.id == id }
        configuration.order.removeAll { $0 == id }
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

    public mutating func updatePreferences(_ preferences: DockPreferences) {
        configuration.preferences = preferences.normalized()
    }

    /// 메뉴 막대의 폭 제한 전 후보다. 숨겨진 초과 항목도 선택 패널에서는 접근할 수 있다.
    public func visibleItems(runningIDs: Set<AppID>) -> [DockItem] {
        orderedApps.compactMap { app in
            let isRunning = runningIDs.contains(app.id)
            guard !app.isExcluded,
                  app.isPinned || (configuration.preferences.showsRunningApps && isRunning) else { return nil }
            return DockItem(app: app, isRunning: isRunning)
        }
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
