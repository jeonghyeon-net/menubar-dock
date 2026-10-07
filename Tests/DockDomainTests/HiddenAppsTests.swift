import DockDomain
import Foundation
import Testing

struct HiddenAppsTests {
    @Test("여러 앱 숨김은 재관찰·Dock 등록·이동·재시작 뒤에도 유지하며 해제 시 저장 순서를 복원한다")
    func hidingPreservesRegistrationAndSurvivesRediscovery() throws {
        let first = app("first", pinned: true)
        let middle = app("middle", pinned: true)
        let last = app("last", pinned: true)
        let temporary = app("temporary")
        var catalog = DockCatalog(configuration: DockConfiguration(apps: [first, middle, temporary, last]))
        let originalOrder = catalog.configuration.order
        catalog.hideApp(middle)
        catalog.hideApp(temporary)
        catalog.hideApp(middle)
        #expect(catalog.configuration.hiddenApps.count == 2)
        #expect(catalog.visibleItems(runningIDs: [temporary.id]).map(\.id) == [first.id, last.id])
        #expect(catalog.savedApps.map(\.id) == [first.id, middle.id, last.id])
        var moved = temporary
        moved.id = AppID(rawValue: "new-observation")
        moved.bundlePath = "/Applications/Moved.app"
        moved.isPinned = true
        catalog.upsert(moved)
        #expect(catalog.isHidden(moved))
        catalog.pruneHistory(runningIDs: [], now: .distantFuture, maximumEntries: 0)
        #expect(catalog.configuration.hiddenApps.count == 2)
        #expect(catalog.configuration.hiddenApps.last?.bundlePath == moved.bundlePath)
        let encoded = try JSONEncoder().encode(catalog.configuration)
        catalog = DockCatalog(configuration: try JSONDecoder().decode(DockConfiguration.self, from: encoded))
        #expect(catalog.isHidden(moved))
        catalog.restoreHiddenApp(middle.id)
        #expect(catalog.visibleItems(runningIDs: []).map(\.id) == [first.id, middle.id, last.id])
        #expect(catalog.configuration.order.filter { originalOrder.contains($0) } == originalOrder.filter { $0 != temporary.id })
    }

    @Test("앱 이름과 관찰 ID는 숨김 기준이 아니며 번들 ID 없는 앱은 설치 경로로 구분한다")
    func identityMatchingDoesNotHideUnrelatedApps() {
        let original = app("original")
        var duplicate = original
        duplicate.id = AppID()
        duplicate.bundlePath = "/Applications/Copy.app"
        var sameName = app("other")
        sameName.name = original.name
        var noIdentity = app("no-identity")
        noIdentity.bundleIdentifier = nil
        var catalog = DockCatalog()
        catalog.hideApp(original)
        catalog.hideApp(duplicate)
        catalog.hideApp(noIdentity)
        #expect(catalog.configuration.hiddenApps.count == 2)
        #expect(catalog.isHidden(duplicate))
        #expect(!catalog.isHidden(sameName))
        var relocated = noIdentity
        relocated.id = AppID()
        relocated.bundlePath = "/Applications/../Applications/no-identity.app"
        #expect(catalog.isHidden(relocated))
        relocated.bundlePath = "/Applications/Other.app"
        #expect(!catalog.isHidden(relocated))
    }

    @Test("고정 해제·재등록은 숨김 정책을 변경하지 않는다")
    func removingAndSavingDoNotOverrideHiddenPolicy() {
        let original = app("saved", pinned: true)
        var catalog = DockCatalog(configuration: DockConfiguration(apps: [original]))
        catalog.hideApp(original)
        catalog.remove(original.id)
        #expect(catalog.visibleItems(runningIDs: [original.id]).isEmpty)
        catalog.save(original.id)
        #expect(catalog.visibleItems(runningIDs: [original.id]).isEmpty)
        catalog.restoreHiddenApp(original.id)
        #expect(catalog.visibleItems(runningIDs: []).map(\.id) == [original.id])
    }

    @Test("같은 등록 ID가 다른 앱에 재사용되어도 두 숨김 항목을 독립적으로 해제한다")
    func replacingSavedIdentityDoesNotCollideWithHiddenSelection() throws {
        let first = app("first")
        var second = app("second")
        second.id = first.id
        var catalog = DockCatalog()
        catalog.hideApp(first)
        catalog.hideApp(second)
        #expect(catalog.configuration.normalized().hiddenApps.count == 2)
        #expect(Set(catalog.configuration.hiddenApps.map(\.id)).count == 2)
        let secondID = try #require(catalog.configuration.hiddenApps.last).id
        catalog.restoreHiddenApp(first.id)
        #expect(!catalog.isHidden(first))
        #expect(catalog.isHidden(second))
        catalog.restoreHiddenApp(secondID)
        #expect(!catalog.isHidden(second))
    }

    @Test("Finder 호환 설정은 정규화 한 번으로 이전되어 숨김 해제 후 다시 생기지 않는다")
    func finderMigrationIsIdempotent() throws {
        let configuration = DockConfiguration(preferences: DockPreferences(hidesFinder: true)).normalized()
        #expect(!configuration.preferences.hidesFinder)
        #expect(configuration.hiddenApps.map(\.bundleIdentifier) == ["com.apple.finder"])
        #expect(configuration.normalized() == configuration)
        var catalog = DockCatalog(configuration: configuration)
        catalog.restoreHiddenApp(try #require(configuration.hiddenApps.first).id)
        #expect(catalog.configuration.normalized().hiddenApps.isEmpty)
    }

    private func app(_ id: String, pinned: Bool = false) -> AppEntry {
        AppEntry(id: AppID(rawValue: id), name: "앱", bundleIdentifier: "example.\(id)",
                 bundlePath: "/Applications/\(id).app", isPinned: pinned, lastSeen: Date(timeIntervalSince1970: 1_000))
    }
}
