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

    @discardableResult
    public mutating func upsert(_ app: AppEntry) -> AppID? {
        guard !app.id.rawValue.isEmpty else { return nil }
        let suppressed = configuration.removedApps.first { $0.id == app.id || sameInstallation($0, app) }
        let existingIndex = configuration.apps.firstIndex(where: { $0.id == app.id })
            ?? configuration.apps.firstIndex(where: { sameInstallation($0, app) })
        if let index = existingIndex {
            var updated = app
            let previous = configuration.apps[index]
            updated.id = previous.id
            // 관찰 이벤트가 고정·제외 정책과 마지막 확인 시간을 되돌리지 못하게 한다.
            updated.isPinned = suppressed == nil && previous.isPinned
            updated.isExcluded = previous.isExcluded
            updated.lastSeen = max(previous.lastSeen, app.lastSeen)
            updated.bookmarkData = app.bookmarkData ?? previous.bookmarkData
            configuration.apps[index] = updated
            return updated.id
        } else {
            var observed = app
            if let suppressed {
                // 이전 삭제 기록도 실행 관찰은 허용한다. 자동 등록만 막고 기존 설치 ID를 재사용한다.
                observed.id = suppressed.id
                observed.isPinned = false
                observed.isExcluded = false
                observed.bookmarkData = app.bookmarkData ?? suppressed.bookmarkData
                observed.lastSeen = max(app.lastSeen, suppressed.lastSeen)
            }
            configuration.apps.append(observed)
            configuration.order.append(observed.id)
            return observed.id
        }
    }

    public func isAutomaticPinningSuppressed(_ app: AppEntry) -> Bool {
        configuration.removedApps.contains { $0.id == app.id || sameInstallation($0, app) }
    }

    /// 명시적으로 추가한 설치의 자동 등록 억제를 해제한다. 등록 위치는 save가 결정한다.
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
        return upsert(restored)
    }

    /// bookmark 이동을 관찰 항목과 자동 등록 억제 기록에 함께 반영한다.
    public mutating func refreshRemovedApp(_ app: AppEntry) {
        guard let index = configuration.removedApps.firstIndex(where: { $0.id == app.id }) else { return }
        let previous = configuration.removedApps[index]
        var refreshed = app
        refreshed.isPinned = previous.isPinned
        refreshed.isExcluded = previous.isExcluded
        refreshed.bookmarkData = app.bookmarkData ?? previous.bookmarkData
        refreshed.lastSeen = max(app.lastSeen, previous.lastSeen)
        configuration.removedApps[index] = refreshed
        for existing in configuration.apps where existing.id == previous.id || sameInstallation(existing, previous) {
            var updated = refreshed
            updated.id = existing.id
            upsert(updated)
        }
    }

    public mutating func pin(_ id: AppID, _ isPinned: Bool) {
        guard let index = configuration.apps.firstIndex(where: { $0.id == id }) else { return }
        configuration.apps[index].isPinned = isPinned
        if isPinned {
            configuration.apps[index].isExcluded = false
            clearAutomaticPinningSuppression(for: configuration.apps[index])
        }
    }

    /// 새 등록은 저장 목록 끝에 추가하고 이미 등록된 앱의 순서는 바꾸지 않는다.
    public mutating func save(_ id: AppID) {
        guard let index = configuration.apps.firstIndex(where: { $0.id == id }) else { return }
        let wasSaved = configuration.apps[index].isPinned && !configuration.apps[index].isExcluded
        configuration.apps[index].isPinned = true
        configuration.apps[index].isExcluded = false
        clearAutomaticPinningSuppression(for: configuration.apps[index])
        guard !wasSaved else { return }
        configuration.order.removeAll { $0 == id }
        configuration.order.append(id)
    }

    public mutating func exclude(_ id: AppID, _ isExcluded: Bool) {
        guard let index = configuration.apps.firstIndex(where: { $0.id == id }) else { return }
        configuration.apps[index].isExcluded = isExcluded
    }

    /// 목록에서 제거해도 실행 중에는 임시 앱으로 표시한다. Dock 동기화의 재등록만 억제한다.
    public mutating func remove(_ id: AppID) {
        guard let app = configuration.apps.first(where: { $0.id == id }) else { return }
        clearAutomaticPinningSuppression(for: app)
        configuration.removedApps.append(app)
        for index in configuration.apps.indices where configuration.apps[index].id == id || sameInstallation(configuration.apps[index], app) {
            configuration.apps[index].isPinned = false
            configuration.apps[index].isExcluded = false
        }
    }

    /// 내부 중복 정리만 항목을 완전히 지운다. 사용자의 등록 정책은 변경하지 않는다.
    public mutating func discard(_ id: AppID) {
        configuration.apps.removeAll { $0.id == id }
        configuration.order.removeAll { $0 == id }
    }

    private mutating func clearAutomaticPinningSuppression(for app: AppEntry) {
        configuration.removedApps.removeAll { $0.id == app.id || sameInstallation($0, app) }
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
        // Finder 숨김은 표시 후보에만 적용해 등록 상태와 사용자가 정한 순서를 보존한다.
        return (temporary + savedApps)
            .filter { !configuration.preferences.hidesFinder || $0.bundleIdentifier != "com.apple.finder" }
            .map { DockItem(app: $0, isRunning: runningIDs.contains($0.id)) }
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
