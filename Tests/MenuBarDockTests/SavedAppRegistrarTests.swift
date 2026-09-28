import DockDomain
import Foundation
import Testing
@testable import MenuBarDock

@MainActor
@Suite("명시적 앱 등록과 위치 재지정")
struct SavedAppRegistrarTests {
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
        #expect(throws: SavedAppRegistrationError.alreadySaved(other.name)) {
            try SavedAppRegistrar.register(other, replacing: original.id, in: &catalog)
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
