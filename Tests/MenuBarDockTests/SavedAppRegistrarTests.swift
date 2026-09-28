import DockDomain
import Foundation
import Testing
@testable import MenuBarDock

@MainActor
@Suite("명시적 앱 등록과 위치 재지정")
struct SavedAppRegistrarTests {
    @Test("종료 후 이동한 앱을 즉시 재등록해도 원래 ID로 끝에 저장하고 늦은 관찰이 순서를 되돌리지 않는다", arguments: [false, true])
    func addingMovedUnpinnedApplicationPreservesIdentityAndNewSavedPosition(_ pruneObservation: Bool) throws {
        let before = app("before", pinned: true)
        let original = app("original", pinned: true)
        let after = app("after", pinned: true)
        var catalog = DockCatalog(configuration: DockConfiguration(apps: [before, original, after]))
        catalog.remove(original.id)
        if pruneObservation {
            catalog.pruneHistory(runningIDs: [], now: .distantFuture, maximumEntries: 0)
        }
        var incoming = original
        incoming.id = AppID(rawValue: "new-resolution")
        incoming.bundlePath = "/Applications/Moved/Original.app"
        incoming.bookmarkData = Data([4, 5])
        var refreshCounts: [AppID: Int] = [:]
        let restoredID = try SavedAppRegistrar.register(incoming, in: &catalog, refresh: { entry in
            refreshCounts[entry.id, default: 0] += 1
            return entry.id == original.id ? incoming : entry
        })
        #expect(restoredID == original.id)
        #expect(catalog.savedApps.map(\.id) == [before.id, after.id, original.id])
        #expect(catalog.orderedApps.count == 3)
        #expect(catalog.configuration.removedApps.isEmpty)
        #expect(refreshCounts == [before.id: 1, original.id: 1, after.id: 1])

        // 뒤늦게 시작 시점의 bookmark 갱신과 중복 정리가 실행되어도 등록 위치가 유지되어야 한다.
        for entry in catalog.orderedApps where entry.id == original.id {
            var moved = incoming
            moved.id = entry.id
            catalog.upsert(moved)
        }
        for entry in catalog.configuration.removedApps where entry.id == original.id {
            var moved = incoming
            moved.id = entry.id
            catalog.refreshRemovedApp(moved)
        }
        WorkspaceCatalogReconciler.reconcile(
            catalog: &catalog, snapshots: [], ownProcessIdentifier: 999, now: Date(),
            resolve: { _ in incoming }, refresh: { $0 }
        )
        let reopened = DockCatalog(configuration: try JSONDecoder().decode(
            DockConfiguration.self, from: JSONEncoder().encode(catalog.configuration)
        ))
        #expect(reopened.savedApps.map(\.id) == [before.id, after.id, original.id])
        #expect(reopened.orderedApps.count == 3)
    }

    @Test("이동한 이전 설치와 새 임시 감지가 겹치면 재등록은 억제 기록의 원래 ID로 한 번만 추가한다")
    func addingMovedSuppressedApplicationMergesItsTemporaryObservation() throws {
        let original = app("original", pinned: true)
        let saved = app("saved", pinned: true)
        var observed = original
        observed.id = AppID(rawValue: "observed-at-new-location")
        observed.bundlePath = "/Applications/Moved/Original.app"
        observed.isPinned = false
        let legacy = DockConfiguration(apps: [observed, saved], removedApps: [original])
        var catalog = DockCatalog(configuration: legacy)
        let id = try SavedAppRegistrar.register(observed, in: &catalog, refresh: { entry in
            entry.id == original.id ? observed : entry
        })
        #expect(id == original.id)
        #expect(catalog.orderedApps.map(\.id) == [saved.id, original.id])
        #expect(catalog.savedApps.map(\.id) == [saved.id, original.id])
        #expect(catalog.configuration.removedApps.isEmpty)
    }

    @Test("위치 재지정은 임시 설치와 합치면서 등록 ID·저장 순서·삭제 기록을 보존한다")
    func replacementMergesTemporaryInstallationWithoutChangingSavedIdentity() throws {
        let before = app("before", pinned: true)
        let original = app("original", pinned: true)
        let after = app("after", pinned: true)
        let temporary = app("temporary")
        var hidden = app("hidden", pinned: true)
        hidden.isExcluded = true
        var catalog = DockCatalog(configuration: DockConfiguration(apps: [temporary, before, original, hidden, after]))
        var incoming = temporary
        incoming.id = AppID(rawValue: "resolved-id")
        incoming.bundlePath = "/Applications/Folder/../temporary.app"
        incoming.name = "새 앱 위치"
        incoming.bookmarkData = Data([8, 9])
        let registeredID = try SavedAppRegistrar.register(incoming, replacing: original.id, in: &catalog)
        #expect(registeredID == original.id)
        #expect(catalog.configuration.order == [before.id, original.id, hidden.id, after.id])
        #expect(catalog.savedApps.map(\.id) == [before.id, original.id, after.id])
        #expect(catalog.configuration.removedApps.isEmpty)
        let updated = try #require(catalog.savedApps.first { $0.id == original.id })
        #expect(updated.name == incoming.name)
        #expect(updated.bookmarkData == incoming.bookmarkData)
        #expect(updated.bundlePath == incoming.bundlePath)
        #expect(updated.isPinned && !updated.isExcluded)
    }

    @Test("다른 등록 앱과 충돌하는 위치 재지정은 설명 가능한 오류로 거부하고 상태를 보존한다")
    func replacementCannotOverwriteAnotherSavedApplication() {
        let original = app("original", pinned: true)
        let other = app("other", pinned: true)
        var catalog = DockCatalog(configuration: DockConfiguration(apps: [original, other]))
        let previous = catalog.configuration
        var moved = other
        moved.bundlePath = "/Applications/Moved/Other.app"
        #expect(throws: SavedAppRegistrationError.alreadySaved(other.name)) {
            try SavedAppRegistrar.register(moved, replacing: original.id, in: &catalog, refresh: { entry in
                if entry.id == other.id { return moved }
                var updated = entry
                updated.name = "갱신된 메타데이터"
                return updated
            })
        }
        #expect(catalog.configuration == previous)
    }

    @Test("앱 선택 중 삭제된 위치 재지정 대상은 복원하지 않는다")
    func missingReplacementCannotRestoreADeletedEntry() {
        let original = app("original", pinned: true)
        let temporary = app("temporary")
        var catalog = DockCatalog(configuration: DockConfiguration(apps: [original, temporary]))
        catalog.remove(original.id)
        let previous = catalog.configuration
        #expect(throws: SavedAppRegistrationError.missingReplacement) {
            try SavedAppRegistrar.register(temporary, replacing: original.id, in: &catalog)
        }
        #expect(catalog.configuration == previous)
    }

    @Test("임시 앱 명시 등록은 기존 ID로 끝에 추가하고 반복 선택은 중복이나 재정렬을 만들지 않는다")
    func addingTemporaryApplicationIsIdempotentAndKeepsInstallationIdentity() throws {
        let temporary = app("temporary")
        let saved = app("saved", pinned: true)
        var catalog = DockCatalog(configuration: DockConfiguration(apps: [temporary, saved]))
        var incoming = temporary
        incoming.id = AppID(rawValue: "new-resolution")
        incoming.bundlePath = "/Applications/Folder/../temporary.app"
        let firstID = try SavedAppRegistrar.register(incoming, in: &catalog)
        let previous = catalog.configuration
        let repeatedID = try SavedAppRegistrar.register(incoming, in: &catalog)
        #expect(firstID == temporary.id)
        #expect(repeatedID == temporary.id)
        #expect(catalog.savedApps.map(\.id) == [saved.id, temporary.id])
        #expect(catalog.configuration == previous)
    }

    @Test("명시적 추가는 삭제된 앱을 원래 ID로 복원하고 숨김 정책을 해제한다")
    func explicitAdditionRestoresRemovedIdentityAndVisibility() throws {
        var removed = app("removed", pinned: true)
        removed.isExcluded = true
        let saved = app("saved", pinned: true)
        var catalog = DockCatalog(configuration: DockConfiguration(apps: [removed, saved]))
        catalog.remove(removed.id)
        var incoming = removed
        incoming.id = AppID(rawValue: "new-resolution")
        let restoredID = try SavedAppRegistrar.register(incoming, in: &catalog)
        #expect(restoredID == removed.id)
        #expect(catalog.savedApps.map(\.id) == [saved.id, removed.id])
        #expect(catalog.configuration.removedApps.isEmpty)
        #expect(catalog.savedApps.allSatisfy { $0.isPinned && !$0.isExcluded })
    }

    private func app(_ id: String, pinned: Bool = false) -> AppEntry {
        AppEntry(
            id: AppID(rawValue: id), name: id, bundleIdentifier: "test.\(id)",
            bundlePath: "/Applications/\(id).app", isPinned: pinned,
            lastSeen: Date(timeIntervalSince1970: 1_000)
        )
    }
}
