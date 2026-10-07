import DockDomain
import Foundation
import Testing

private func entry(_ id: String, pinned: Bool = false, seen: Date = Date(timeIntervalSince1970: 1_000)) -> AppEntry {
    AppEntry(id: AppID(rawValue: id), name: id, bundlePath: "/Applications/\(id).app", isPinned: pinned, lastSeen: seen)
}

@Suite("도크 순서와 사용자 정책")
struct DockCatalogTests {
    @Test("Finder 숨김은 등록·임시 표시만 거르고 해제하면 저장 상태와 원순서를 복원한다", arguments: [false, true])
    func hidingFinderOnlyFiltersItsBundleIdentity(_ pinned: Bool) {
        var finder = entry("finder", pinned: pinned)
        finder.name = "시스템 파일 관리자"
        finder.bundleIdentifier = "com.apple.finder"
        var sameName = entry("another-finder", pinned: true)
        sameName.name = "Finder"
        sameName.bundleIdentifier = "example.finder"
        var unknownIdentity = entry("unknown", pinned: true)
        unknownIdentity.name = "Finder"
        let first = entry("first", pinned: true)
        let last = entry("last", pinned: true)
        let original = DockConfiguration(apps: [first, finder, sameName, unknownIdentity, last]).normalized()
        var catalog = DockCatalog(configuration: original)
        let running: Set<AppID> = [finder.id]
        let originalVisible = catalog.visibleItems(runningIDs: running)
        let saved = catalog.savedApps
        catalog.hideApp(finder)
        #expect(catalog.visibleItems(runningIDs: running) == originalVisible.filter { $0.id != finder.id })
        #expect(catalog.savedApps == saved)
        #expect(catalog.configuration.apps == original.apps)
        #expect(catalog.configuration.order == original.order)
        #expect(catalog.configuration.removedApps.isEmpty)
        catalog.restoreHiddenApp(finder.id)
        #expect(catalog.visibleItems(runningIDs: running) == originalVisible)
        #expect(catalog.configuration == original)
    }

    @Test("저장 목록에는 항상 표시 앱만 남고 미등록 실행 앱은 앞에 한 번씩 표시한다")
    func savedProjectionSeparatesTemporaryAppsAndHonorsLegacyExclusions() {
        let first = entry("first", pinned: true)
        let temporary = entry("temporary")
        var hidden = entry("hidden", pinned: true)
        hidden.isExcluded = true
        let second = entry("second", pinned: true)
        let anotherTemporary = entry("another-temporary")
        let stopped = entry("stopped")
        let removed = entry("removed", pinned: true)
        let apps = [first, temporary, hidden, second, anotherTemporary, stopped, removed]
        var catalog = DockCatalog(configuration: DockConfiguration(apps: apps))
        catalog.remove(removed.id)
        let originalOrder = catalog.configuration.order
        let runningIDs: Set<AppID> = [first.id, temporary.id, hidden.id, anotherTemporary.id, removed.id]
        #expect(catalog.savedApps == [first, second])
        let visible = catalog.visibleItems(runningIDs: runningIDs)
        #expect(visible.map(\.id) == [temporary.id, anotherTemporary.id, removed.id, first.id, second.id])
        #expect(visible.map(\.isRunning) == [true, true, true, true, false])
        #expect(Set(visible.map(\.id)).count == visible.count)
        #expect(catalog.visibleItems(runningIDs: []).map(\.id) == [first.id, second.id])
        #expect(catalog.configuration.order == originalOrder)
        catalog.updatePreferences(DockPreferences(showsRunningApps: false))
        #expect(catalog.visibleItems(runningIDs: runningIDs).map(\.id) == [first.id, second.id])
    }

    @Test("새 저장과 숨김 앱 재등록은 저장 목록 끝에 추가하고 반복 저장은 순서를 유지한다")
    func savingAppendsNewEntriesButPreservesAlreadySavedOrder() {
        let first = entry("first", pinned: true)
        let temporary = entry("temporary")
        var hidden = entry("hidden", pinned: true)
        hidden.isExcluded = true
        let last = entry("last", pinned: true)
        var catalog = DockCatalog(configuration: DockConfiguration(apps: [first, temporary, hidden, last]))
        catalog.save(temporary.id)
        #expect(catalog.savedApps.map(\.id) == [first.id, last.id, temporary.id])
        #expect(catalog.configuration.order == [first.id, hidden.id, last.id, temporary.id])
        catalog.save(hidden.id)
        #expect(catalog.savedApps.map(\.id) == [first.id, last.id, temporary.id, hidden.id])
        #expect(catalog.savedApps.allSatisfy { $0.isPinned && !$0.isExcluded })
        let saved = catalog.configuration
        catalog.save(first.id)
        catalog.save(temporary.id)
        catalog.save(AppID(rawValue: "unknown"))
        #expect(catalog.configuration == saved)
        catalog.pin(last.id, false)
        catalog.save(last.id)
        #expect(catalog.savedApps.map(\.id) == [first.id, temporary.id, hidden.id, last.id])
    }

    @Test("목록 제거 후 실행 관찰은 임시 앱으로 남고 저장하면 같은 ID로 목록 끝에 등록된다")
    func removedAppCanBeSavedAgainWithoutChangingIdentity() {
        let removed = entry("removed", pinned: true)
        let retained = entry("retained", pinned: true)
        var catalog = DockCatalog(configuration: DockConfiguration(apps: [removed, retained]))
        catalog.remove(removed.id)
        catalog.upsert(removed)
        #expect(catalog.savedApps == [retained])
        #expect(catalog.visibleItems(runningIDs: [removed.id]).map(\.id) == [removed.id, retained.id])
        catalog.save(removed.id)
        #expect(catalog.savedApps.map(\.id) == [retained.id, removed.id])
        #expect(catalog.configuration.removedApps.isEmpty)
    }

    @Test("저장 앱 다중 드래그는 임시·숨김 항목의 원래 위치를 보존한다")
    func movingSavedSubsetKeepsNonSavedSlotsIntact() {
        var hidden = entry("hidden", pinned: true)
        hidden.isExcluded = true
        let apps = [entry("temporary"), entry("a", pinned: true), hidden, entry("b", pinned: true),
                    entry("stopped"), entry("c", pinned: true), entry("d", pinned: true)]
        var catalog = DockCatalog(configuration: DockConfiguration(apps: apps))
        catalog.moveSaved(fromOffsets: IndexSet([0, 2]), toOffset: 4)
        #expect(catalog.savedApps.map(\.name) == ["b", "d", "a", "c"])
        #expect(catalog.orderedApps.map(\.name) == ["temporary", "b", "hidden", "d", "stopped", "a", "c"])
        #expect(catalog.configuration.apps == apps)
        catalog.moveSaved(fromOffsets: IndexSet([2, 3]), toOffset: 0)
        #expect(catalog.savedApps.map(\.name) == ["a", "c", "b", "d"])
        #expect(catalog.orderedApps.map(\.name) == ["temporary", "a", "hidden", "c", "stopped", "b", "d"])
        let valid = catalog.configuration
        catalog.moveSaved(fromOffsets: [], toOffset: 0)
        catalog.moveSaved(fromOffsets: IndexSet([0, 4]), toOffset: 0)
        catalog.moveSaved(fromOffsets: IndexSet(integer: 0), toOffset: -1)
        catalog.moveSaved(fromOffsets: IndexSet(integer: 0), toOffset: 5)
        #expect(catalog.configuration == valid)
    }

    @Test("저장 목록의 모든 단일 이동은 항목과 나머지 상대 순서를 보존한다")
    func everySavedMovePreservesPermutationAndNonSavedPositions() {
        let apps = (0..<8).map { entry(String($0), pinned: $0.isMultiple(of: 2)) }
        let saved = apps.filter(\.isPinned)
        for source in saved.indices {
            for destination in 0...saved.count {
                var catalog = DockCatalog(configuration: DockConfiguration(apps: apps))
                catalog.moveSaved(fromOffsets: IndexSet(integer: source), toOffset: destination)
                #expect(Set(catalog.configuration.order) == Set(apps.map(\.id)))
                #expect(catalog.configuration.order.count == apps.count)
                #expect(catalog.savedApps.filter { $0.id != saved[source].id }.map(\.id) == saved.filter { $0.id != saved[source].id }.map(\.id))
                for index in apps.indices where !apps[index].isPinned {
                    #expect(catalog.configuration.order[index] == apps[index].id)
                }
            }
        }
    }

    @Test("목록 제거는 실행 중 임시 표시를 허용하고 이력 정리 뒤에도 자동 고정 억제를 유지한다")
    func removalOnlySuppressesPinningAndSurvivesPruning() {
        let before = entry("before", pinned: true)
        let removed = entry("removed", pinned: true)
        let after = entry("after", pinned: true)
        var catalog = DockCatalog(configuration: DockConfiguration(apps: [before, removed, after]))
        catalog.remove(removed.id)
        #expect(catalog.savedApps == [before, after])
        #expect(catalog.configuration.order == [before.id, removed.id, after.id])
        #expect(catalog.configuration.removedApps == [removed])
        var observed = removed
        observed.id = AppID(rawValue: "new-observation-id")
        for _ in 0..<3 { catalog.upsert(observed) }
        #expect(catalog.orderedApps.count == 3)
        #expect(catalog.visibleItems(runningIDs: [removed.id]).map(\.id) == [removed.id, before.id, after.id])
        #expect(catalog.visibleItems(runningIDs: []).map(\.id) == [before.id, after.id])
        catalog.pruneHistory(runningIDs: [], now: Date.distantFuture, maximumEntries: 0)
        #expect(catalog.orderedApps == [before, after])
        #expect(catalog.isAutomaticPinningSuppressed(observed))
        #expect(catalog.configuration.removedApps == [removed])
        catalog.upsert(observed)
        #expect(catalog.configuration.order == [before.id, after.id, removed.id])
        #expect(catalog.savedApps == [before, after])
        #expect(catalog.visibleItems(runningIDs: [removed.id]).map(\.id) == [removed.id, before.id, after.id])
    }

    @Test("명시적 재추가는 삭제 기록의 ID를 재사용해 끝에 복원하고 이후 중복을 만들지 않는다")
    func explicitAdditionRestoresPersistentIdentity() throws {
        let removed = entry("removed", pinned: true)
        let other = entry("other", pinned: true)
        var catalog = DockCatalog(configuration: DockConfiguration(apps: [removed, other]))
        catalog.remove(removed.id)
        var added = removed
        added.id = AppID(rawValue: "resolver-id")
        let restoration = catalog.upsertRestoring(added)
        let restoredID = try #require(restoration)
        catalog.save(restoredID)
        #expect(restoredID == removed.id)
        #expect(catalog.configuration.removedApps.isEmpty)
        #expect(catalog.configuration.order == [other.id, removed.id])
        let repeatedRestoration = catalog.upsertRestoring(added)
        #expect(repeatedRestoration == restoredID)
        #expect(catalog.orderedApps.count == 2)
        #expect(catalog.configuration.order == [other.id, removed.id])
    }

    @Test("등록 해제한 앱이 이동해도 임시 ID를 유지하고 별도 설치와 교체 앱은 구분한다")
    func removalTracksMovedInstallationWithoutBlockingOtherApps() {
        var original = entry("removed")
        original.bundleIdentifier = "test.editor"
        var catalog = DockCatalog(configuration: DockConfiguration(apps: [original]))
        catalog.remove(original.id)
        var moved = original
        moved.bundlePath = "/Applications/Moved.app"
        moved.bookmarkData = Data([7, 8])
        catalog.refreshRemovedApp(moved)
        var observed = moved
        observed.id = AppID(rawValue: "observed")
        catalog.upsert(observed)
        #expect(catalog.orderedApps.map(\.id) == [original.id])
        #expect(catalog.orderedApps.first?.bundlePath == moved.bundlePath)
        #expect(catalog.savedApps.isEmpty)
        #expect(catalog.configuration.removedApps.first?.bookmarkData == moved.bookmarkData)
        var secondInstallation = original
        secondInstallation.id = AppID(rawValue: "separate-installation")
        catalog.upsert(secondInstallation)
        var replacement = observed
        replacement.id = AppID(rawValue: "replacement")
        replacement.bundleIdentifier = "test.other-app"
        catalog.upsert(replacement)
        #expect(catalog.orderedApps.map(\.id) == [original.id, secondInstallation.id, replacement.id])
    }

    @Test("내부 중복 정리는 삭제 기록을 만들지 않고 제외는 목록에 남는다")
    func duplicateCleanupAndExclusionDoNotSuppressInstallation() {
        let retained = entry("retained", pinned: true)
        var duplicate = retained
        duplicate.id = AppID(rawValue: "duplicate")
        var catalog = DockCatalog(configuration: DockConfiguration(apps: [retained, duplicate]))
        catalog.discard(duplicate.id)
        #expect(catalog.configuration.removedApps.isEmpty)
        catalog.exclude(retained.id, true)
        #expect(catalog.orderedApps.map(\.id) == [retained.id])
        #expect(catalog.visibleItems(runningIDs: [retained.id]).isEmpty)
        #expect(!catalog.isAutomaticPinningSuppressed(retained))
        catalog.exclude(retained.id, false)
        #expect(catalog.visibleItems(runningIDs: []).map(\.id) == [retained.id])
    }

    @Test("알려진 Dock 경로는 표기 중복을 없애고 현재 목록으로 교체한다")
    func knownDockPathsAreReplacedRatherThanAccumulated() {
        var catalog = DockCatalog()
        catalog.updateKnownSystemDockPaths(["/Applications/A.app", "/Applications/Unused/../A.app", "/Applications/B.app"])
        #expect(catalog.configuration.knownSystemDockPaths == ["/Applications/A.app", "/Applications/B.app"])
        catalog.updateKnownSystemDockPaths(["/Applications/B.app"])
        #expect(catalog.configuration.knownSystemDockPaths == ["/Applications/B.app"])
    }

    @Test("자동 고정 억제 기록과 실행 항목을 함께 저장해도 항목과 순서를 잃지 않는다")
    func normalizationRetainsUnpinnedLiveEntriesWithSuppressionRecords() {
        let removed = entry("removed", pinned: true)
        let first = entry("first", pinned: true)
        let last = entry("last", pinned: true)
        var observed = removed
        observed.id = AppID(rawValue: "observed-id")
        let normalized = DockConfiguration(
            apps: [first, removed, observed, last],
            order: [last.id, observed.id, removed.id, first.id],
            removedApps: [removed, removed]
        ).normalized()
        #expect(normalized.apps.map(\.id) == [first.id, removed.id, observed.id, last.id])
        #expect(normalized.apps.filter { $0.id == removed.id || $0.id == observed.id }.allSatisfy { !$0.isPinned })
        #expect(normalized.order == [last.id, observed.id, removed.id, first.id])
        #expect(normalized.removedApps == [removed])
        #expect(normalized.normalized() == normalized)
    }

    @Test("실행·종료·메타데이터 갱신 뒤에도 사용자가 정한 상대 순서를 유지한다")
    func lifecyclePreservesOrder() {
        let apps = [entry("a", pinned: true), entry("b"), entry("c", pinned: true)]
        var catalog = DockCatalog(configuration: DockConfiguration(apps: apps, order: [apps[2].id, apps[0].id, apps[1].id]))
        let expectedOrder = catalog.configuration.order
        for app in apps.reversed() {
            catalog.upsert(app)
            #expect(catalog.configuration.order == expectedOrder)
        }
        let visibleOrder = [apps[1].id, apps[2].id, apps[0].id]
        #expect(catalog.visibleItems(runningIDs: Set(apps.map(\.id))).map(\.id) == visibleOrder)
        #expect(catalog.visibleItems(runningIDs: []).map(\.id) == [apps[2].id, apps[0].id])
        #expect(catalog.visibleItems(runningIDs: [apps[1].id]).map(\.id) == visibleOrder)
        #expect(catalog.configuration.order == expectedOrder)
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
        #expect(normalized.slotWidth == 24)
        #expect(normalized.maxVisibleApps == 1)
        #expect(DockPreferences(iconSize: -10, slotWidth: 100, maxVisibleApps: 200).normalized() == DockPreferences(iconSize: 16, slotWidth: 44, maxVisibleApps: 20))
        #expect(DockPreferences(iconSize: 100, slotWidth: -10).normalized() == DockPreferences(iconSize: 32, slotWidth: 32))
        #expect(DockPreferences(iconSize: .nan, slotWidth: .nan).normalized() == DockPreferences())
    }

    @Test("추가 여백 0을 허용하면서 아이콘보다 작은 영역만 넓힌다")
    func iconAndSlotDimensionsPreserveRequiredSpace() throws {
        let preferences = DockPreferences(iconSize: 30, slotWidth: 40)
        #expect(preferences.normalized() == preferences)
        let fitted = DockPreferences(iconSize: 32, slotWidth: 30).normalized()
        #expect(fitted == DockPreferences(iconSize: 32, slotWidth: 32))
        #expect(fitted.normalized() == fitted)
        #expect(DockPreferences(iconSize: 16, slotWidth: 16).normalized() == DockPreferences(iconSize: 16, slotWidth: 16))
        #expect(DockPreferences(iconSize: 16, slotWidth: 60).normalized() == DockPreferences(iconSize: 16, slotWidth: 44))
        let encoded = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(DockPreferences.self, from: encoded) == preferences)
        #expect(try JSONDecoder().decode(DockPreferences.self, from: Data("{}".utf8)) == DockPreferences(iconSize: 24, slotWidth: 24))
    }
}
