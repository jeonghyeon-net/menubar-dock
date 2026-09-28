import DockDomain
import Foundation
import Testing

private func entry(_ id: String, pinned: Bool = false, seen: Date = Date(timeIntervalSince1970: 1_000)) -> AppEntry {
    AppEntry(id: AppID(rawValue: id), name: id, bundlePath: "/Applications/\(id).app", isPinned: pinned, lastSeen: seen)
}

@Suite("도크 순서와 사용자 정책")
struct DockCatalogTests {
    @Test("실행·종료·메타데이터 갱신 뒤에도 사용자가 정한 상대 순서를 유지한다")
    func lifecyclePreservesOrder() {
        let apps = [entry("a", pinned: true), entry("b"), entry("c", pinned: true)]
        var catalog = DockCatalog(configuration: DockConfiguration(apps: apps, order: [apps[2].id, apps[0].id, apps[1].id]))
        let expectedOrder = catalog.configuration.order
        for app in apps.reversed() {
            catalog.upsert(app)
            #expect(catalog.configuration.order == expectedOrder)
        }
        #expect(catalog.visibleItems(runningIDs: Set(apps.map(\.id))).map(\.id) == expectedOrder)
        #expect(catalog.visibleItems(runningIDs: []).map(\.id) == [apps[2].id, apps[0].id])
        #expect(catalog.visibleItems(runningIDs: [apps[1].id]).map(\.id) == expectedOrder)
    }

    @Test("손상된 순서에서는 중복과 사라진 참조만 제거한다")
    func normalizationRepairsReferences() {
        let apps = [entry("a"), entry("b"), entry("c")]
        let configuration = DockConfiguration(
            apps: [apps[0], apps[1], apps[0], apps[2], entry("")],
            order: [apps[1].id, AppID(rawValue: "missing"), apps[1].id]
        ).normalized()
        #expect(configuration.apps.map(\.id) == apps.map(\.id))
        #expect(configuration.order == [apps[1].id, apps[0].id, apps[2].id])
        #expect(configuration.normalized() == configuration)
    }

    @Test("관찰된 기본값이 고정·제외·bookmark를 지우지 않는다")
    func observationPreservesUserPolicy() throws {
        var original = entry("a", pinned: true)
        original.isExcluded = true
        original.bookmarkData = Data([1, 2, 3])
        var catalog = DockCatalog(configuration: DockConfiguration(apps: [original]))
        var observed = entry("a", seen: Date(timeIntervalSince1970: 500))
        observed.name = "새 이름"
        catalog.upsert(observed)
        let updated = try #require(catalog.orderedApps.first)
        #expect(updated.name == "새 이름")
        #expect(updated.isPinned)
        #expect(updated.isExcluded)
        #expect(updated.bookmarkData == original.bookmarkData)
        #expect(updated.lastSeen == original.lastSeen)
        #expect(catalog.visibleItems(runningIDs: [original.id]).isEmpty)
        catalog.pin(original.id, true)
        #expect(catalog.visibleItems(runningIDs: []).map(\.id) == [original.id])
    }

    @Test("동일 bundle identifier의 다른 설치 앱은 별도로 유지한다")
    func installationsHaveDistinctIdentity() {
        var first = entry("one")
        var second = entry("two")
        first.bundleIdentifier = "com.example.editor"
        second.bundleIdentifier = first.bundleIdentifier
        var catalog = DockCatalog()
        catalog.upsert(first)
        catalog.upsert(second)
        #expect(catalog.orderedApps.count == 2)
    }

    @Test("실행 앱 자동 표시를 꺼도 고정 앱은 남고 슬롯은 예약되지 않는다")
    func projectionDoesNotReserveSlots() {
        let apps = [entry("a", pinned: true), entry("b"), entry("c", pinned: true)]
        var catalog = DockCatalog(configuration: DockConfiguration(apps: apps))
        catalog.updatePreferences(DockPreferences(maxVisibleApps: 1, showsRunningApps: false))
        let visible = catalog.visibleItems(runningIDs: Set(apps.map(\.id)))
        #expect(visible.map(\.id) == [apps[0].id, apps[2].id])
        // 폭 제한은 UI가 적용하며 선택 패널에 필요한 후보를 버리지 않는다.
        #expect(visible.count > catalog.configuration.preferences.maxVisibleApps)
        catalog.remove(apps[0].id)
        #expect(catalog.visibleItems(runningIDs: []).map(\.id) == [apps[2].id])
    }

    @Test("여러 행 이동은 선택 순서와 나머지 항목 순서를 모두 지킨다")
    func reorderPreservesAllEntries() {
        let apps = ["a", "b", "c", "d", "e"].map { entry($0) }
        var catalog = DockCatalog(configuration: DockConfiguration(apps: apps))
        catalog.move(fromOffsets: IndexSet([1, 3]), toOffset: 5)
        #expect(catalog.orderedApps.map(\.name) == ["a", "c", "e", "b", "d"])
        catalog.move(fromOffsets: IndexSet([3, 4]), toOffset: 0)
        #expect(catalog.orderedApps.map(\.name) == ["b", "d", "a", "c", "e"])
        let valid = catalog.configuration
        catalog.move(fromOffsets: IndexSet([8]), toOffset: 0)
        catalog.move(fromOffsets: IndexSet([0]), toOffset: -1)
        #expect(catalog.configuration == valid)
    }

    @Test("모든 단일 이동 조합은 항목을 잃거나 복제하지 않는다")
    func everyMoveMaintainsPermutation() {
        let apps = (0..<8).map { entry(String($0)) }
        for source in apps.indices {
            for destination in 0...apps.count {
                var catalog = DockCatalog(configuration: DockConfiguration(apps: apps))
                catalog.move(fromOffsets: IndexSet(integer: source), toOffset: destination)
                #expect(Set(catalog.configuration.order) == Set(apps.map(\.id)))
                #expect(catalog.configuration.order.count == apps.count)
                #expect(catalog.orderedApps.filter { $0.id != apps[source].id }.map(\.id) == apps.filter { $0.id != apps[source].id }.map(\.id))
            }
        }
    }

    @Test("이력 정리는 실행·고정·제외 기록을 보호한다")
    func historyPruningProtectsIntent() {
        let now = Date(timeIntervalSince1970: 20_000_000)
        var excluded = entry("excluded")
        excluded.isExcluded = true
        let apps = [entry("pinned", pinned: true), excluded, entry("running"), entry("expired"), entry("recent", seen: now)]
        var catalog = DockCatalog(configuration: DockConfiguration(apps: apps))
        catalog.pruneHistory(runningIDs: [apps[2].id], now: now)
        #expect(catalog.orderedApps.map(\.name) == ["pinned", "excluded", "running", "recent"])
        catalog.pruneHistory(runningIDs: [apps[2].id], now: now, maximumEntries: 0)
        #expect(catalog.orderedApps.map(\.name) == ["pinned", "excluded", "running"])
    }

    @Test("잘못된 외부 환경설정이 음수 폭이나 무한 크기를 만들지 않는다")
    func preferencesAreBounded() {
        let normalized = DockPreferences(iconSize: .infinity, slotWidth: -.infinity, maxVisibleApps: -200).normalized()
        #expect(normalized.iconSize == 24)
        #expect(normalized.slotWidth == 30)
        #expect(normalized.maxVisibleApps == 1)
        #expect(DockPreferences(iconSize: -10, slotWidth: 100, maxVisibleApps: 200).normalized() == DockPreferences(iconSize: 16, slotWidth: 60, maxVisibleApps: 20))
        #expect(DockPreferences(iconSize: 100, slotWidth: -10).normalized() == DockPreferences(iconSize: 32, slotWidth: 22))
        #expect(DockPreferences(iconSize: .nan, slotWidth: .nan).normalized() == DockPreferences())
    }

    @Test("아이콘 크기와 슬롯 폭은 독립 설정으로 보존한다")
    func iconAndSlotDimensionsAreIndependent() throws {
        let preferences = DockPreferences(iconSize: 30, slotWidth: 24)
        #expect(preferences.normalized() == preferences)
        let encoded = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(DockPreferences.self, from: encoded) == preferences)
        #expect(try JSONDecoder().decode(DockPreferences.self, from: Data("{}".utf8)) == DockPreferences(iconSize: 24, slotWidth: 30))
    }
}
