import DockDomain
import DockPlatform
import Foundation
import Testing
@testable import MenuBarDock

@MainActor
@Suite("실행 스냅샷과 설치 앱 연결")
struct WorkspaceCatalogReconcilerTests {
    private let now = Date(timeIntervalSince1970: 100_000)

    @Test("등록 해제한 실행 앱의 이동은 임시 ID와 억제 기록을 보존하고 bookmark는 한 번만 조회한다")
    func movedUnpinnedApplicationKeepsTemporaryIdentityAndRefreshIsBounded() throws {
        let removed = app("removed", path: "/Applications/Before.app")
        let anotherRemoved = app("another-removed", path: "/Applications/Hidden.app")
        let retained = app("retained", path: "/Applications/Retained.app")
        let added = app("added", path: "/Applications/Added.app")
        var moved = removed
        moved.id = AppID(rawValue: "new-resolution-id")
        moved.bundlePath = "/Applications/Folder/After.app"
        moved.bookmarkData = Data([7, 8])
        var catalog = DockCatalog(configuration: DockConfiguration(apps: [removed, retained, anotherRemoved]))
        catalog.remove(removed.id)
        catalog.remove(anotherRemoved.id)
        var refreshCounts: [AppID: Int] = [:]
        var resolvedPaths: [String] = []
        let snapshots = [snapshot(moved, pid: 1), snapshot(moved, pid: 2), snapshot(added, pid: 3), snapshot(retained, pid: 4)]
        for _ in 0..<2 {
            WorkspaceCatalogReconciler.reconcile(
                catalog: &catalog, snapshots: snapshots, ownProcessIdentifier: 999, now: now,
                resolve: { url in
                    resolvedPaths.append(url.path)
                    return url.path == moved.bundlePath ? moved : added
                },
                refresh: { original in
                    refreshCounts[original.id, default: 0] += 1
                    return original.id == removed.id ? moved : original
                }
            )
        }
        #expect(catalog.orderedApps.map(\.id) == [removed.id, retained.id, anotherRemoved.id, added.id])
        let running = WorkspaceCatalogReconciler.runningIDs(catalog: catalog, snapshots: snapshots)
        #expect(catalog.visibleItems(runningIDs: running).map(\.id) == [removed.id, retained.id, added.id])
        #expect(catalog.savedApps.isEmpty)
        #expect(resolvedPaths == [added.bundlePath])
        #expect(refreshCounts == [removed.id: 1, anotherRemoved.id: 1, retained.id: 1])
        let preserved = try #require(catalog.configuration.removedApps.first { $0.id == removed.id })
        #expect(preserved.bundlePath == moved.bundlePath)
        #expect(preserved.bookmarkData == moved.bookmarkData)
        #expect(catalog.isAutomaticPinningSuppressed(moved))
    }

    @Test("이전 삭제 기록 여러 개를 임시 앱으로 복원하며 종료·재실행과 명시적 재등록을 구분한다")
    func legacyRemovedApplicationsReturnOnlyWhileRunning() {
        var first = app("saved-first", path: "/Applications/First.app")
        first.isPinned = true
        var last = app("saved-last", path: "/Applications/Last.app")
        last.isPinned = true
        var removed = (0..<3).map { index in
            var entry = app("removed-\(index)", path: "/Applications/Removed\(index).app")
            entry.isPinned = true
            return entry
        }
        removed[1].bundleIdentifier = removed[0].bundleIdentifier
        removed[2].isExcluded = true
        var catalog = DockCatalog(configuration: DockConfiguration(
            apps: [first, last], order: [last.id, first.id], removedApps: removed
        ))
        let observed = removed.enumerated().map { snapshot($0.element, pid: Int32($0.offset + 1)) }
            + [snapshot(removed[0], pid: 10)]
        var resolutions = 0
        var refreshes = 0
        func update(_ snapshots: [RunningAppSnapshot]) -> [AppID] {
            WorkspaceCatalogReconciler.reconcile(
                catalog: &catalog, snapshots: snapshots, ownProcessIdentifier: 999, now: now,
                resolve: { _ in resolutions += 1; return removed[0] },
                refresh: { refreshes += 1; return $0 }
            )
            return catalog.visibleItems(runningIDs: WorkspaceCatalogReconciler.runningIDs(catalog: catalog, snapshots: snapshots)).map(\.id)
        }
        let savedIDs = [last.id, first.id]
        let expected = removed.map(\.id) + savedIDs
        #expect(update(observed) == expected)
        #expect(update(observed) == expected)
        #expect(catalog.savedApps.map(\.id) == savedIDs)
        #expect(catalog.orderedApps.count == 5)
        #expect(update([]) == savedIDs)
        catalog.pruneHistory(runningIDs: [], now: .distantFuture, maximumEntries: 0)
        #expect(catalog.orderedApps.count == 2)
        #expect(update(observed) == expected)
        #expect(catalog.savedApps.map(\.id) == savedIDs)
        #expect(resolutions == 0)
        #expect(refreshes == 0)
        catalog.save(removed[1].id)
        #expect(catalog.savedApps.map(\.id) == savedIDs + [removed[1].id])
        #expect(!catalog.isAutomaticPinningSuppressed(removed[1]))
        #expect(catalog.configuration.removedApps.map(\.id) == [removed[0].id, removed[2].id])
    }

    @Test("동일 경로가 다른 앱으로 대체되면 새 설치만 실행 중·현재 앱으로 연결한다")
    func processProjectionDistinguishesReplacementAtSamePath() {
        let old = app("old", path: "/Applications/Shared.app")
        let replacement = app("replacement", path: old.bundlePath)
        let catalog = DockCatalog(configuration: DockConfiguration(apps: [old, replacement]))
        let snapshots = [snapshot(replacement, active: true)]
        let running = WorkspaceCatalogReconciler.runningIDs(catalog: catalog, snapshots: snapshots)
        #expect(running == [replacement.id])
        #expect(catalog.visibleItems(runningIDs: running).map(\.id) == [replacement.id])
        #expect(WorkspaceCatalogReconciler.currentAppID(catalog: catalog, snapshots: snapshots) == replacement.id)
    }

    @Test("프로세스 연결은 같은 bundle ID의 다른 설치를 구분하고 ID가 없으면 경로로 확인한다")
    func processProjectionRespectsInstallationAndUnknownIdentifier() {
        let stable = app("stable", path: "/Applications/Editor.app")
        var preview = app("preview", path: "/Applications/Preview/Editor.app")
        preview.bundleIdentifier = stable.bundleIdentifier
        let catalog = DockCatalog(configuration: DockConfiguration(apps: [stable, preview]))
        let previewSnapshots = [snapshot(preview, active: true)]
        #expect(WorkspaceCatalogReconciler.runningIDs(catalog: catalog, snapshots: previewSnapshots) == [preview.id])
        #expect(WorkspaceCatalogReconciler.currentAppID(catalog: catalog, snapshots: previewSnapshots) == preview.id)

        var unknownIdentity = preview
        unknownIdentity.bundleIdentifier = nil
        let unknownSnapshots = [snapshot(unknownIdentity, active: true)]
        #expect(WorkspaceCatalogReconciler.runningIDs(catalog: catalog, snapshots: unknownSnapshots) == [preview.id])
        #expect(WorkspaceCatalogReconciler.currentAppID(catalog: catalog, snapshots: unknownSnapshots) == preview.id)
        #expect(WorkspaceCatalogReconciler.currentAppID(catalog: catalog, snapshots: [snapshot(preview)]) == nil)
    }

    @Test("실행 중 경로 이동은 원래 ID·순서·고정·제외를 보존한다")
    func movedApplicationRetainsUserPolicyAndOrder() throws {
        let first = app("first", path: "/Applications/First.app")
        var moved = app("moved", path: "/Applications/Before.app")
        moved.isPinned = true
        moved.isExcluded = true
        let last = app("last", path: "/Applications/Last.app")
        var catalog = DockCatalog(configuration: DockConfiguration(apps: [first, moved, last]))
        var resolved = app("temporary-resolver-id", path: "/Applications/Folder/After.app")
        resolved.bundleIdentifier = moved.bundleIdentifier
        resolved.bookmarkData = Data([9, 8, 7])
        var resolveCount = 0

        WorkspaceCatalogReconciler.reconcile(
            catalog: &catalog, snapshots: [snapshot(resolved)], ownProcessIdentifier: 999, now: now,
            resolve: { _ in resolveCount += 1; return resolved },
            refresh: { $0.id == moved.id ? resolved : $0 }
        )

        #expect(catalog.configuration.order == [first.id, moved.id, last.id])
        #expect(catalog.orderedApps.count == 3)
        let retained = try #require(catalog.orderedApps.first { $0.id == moved.id })
        #expect(retained.bundlePath == resolved.bundlePath)
        #expect(retained.bookmarkData == resolved.bookmarkData)
        #expect(retained.isPinned)
        #expect(retained.isExcluded)
        #expect(retained.lastSeen == now)
        #expect(resolveCount == 0)
    }

    @Test("같은 앱의 여러 프로세스와 반복 스냅샷은 중복 항목을 만들지 않는다")
    func duplicateProcessesAndSnapshotsResolveOnlyOnce() {
        let observed = app("new", path: "/Applications/New.app")
        let snapshots = [snapshot(observed, pid: 1), snapshot(observed, pid: 2)]
        var catalog = DockCatalog()
        var resolveCount = 0
        for _ in 0..<2 {
            WorkspaceCatalogReconciler.reconcile(
                catalog: &catalog, snapshots: snapshots, ownProcessIdentifier: 999, now: now,
                resolve: { _ in resolveCount += 1; return observed }, refresh: { $0 }
            )
        }
        #expect(catalog.orderedApps.map(\.id) == [observed.id])
        #expect(resolveCount == 1)
    }

    @Test("같은 경로의 교체 앱을 재해석해도 실제 유지 ID로 캐시하여 중복 프로세스를 합친다")
    func resolvedInstallationUsesRetainedIdentityWithinTheSnapshotBatch() {
        let replaced = app("replaced", path: "/Applications/Shared.app")
        let retained = app("retained", path: replaced.bundlePath)
        let added = app("added", path: "/Applications/Added.app")
        var resolved = retained
        resolved.id = AppID(rawValue: "fresh-resolver-id")
        var catalog = DockCatalog(configuration: DockConfiguration(apps: [replaced, retained]))
        var resolvedPaths: [String] = []
        let snapshots = [snapshot(retained, pid: 1), snapshot(retained, pid: 2), snapshot(added, pid: 3)]
        WorkspaceCatalogReconciler.reconcile(
            catalog: &catalog, snapshots: snapshots, ownProcessIdentifier: 999, now: now,
            resolve: { url in
                resolvedPaths.append(url.path)
                return url.path == added.bundlePath ? added : resolved
            }, refresh: { $0 }
        )
        #expect(resolvedPaths == [added.bundlePath, retained.bundlePath])
        #expect(catalog.orderedApps.map(\.id) == [replaced.id, retained.id, added.id])
        #expect(WorkspaceCatalogReconciler.runningIDs(catalog: catalog, snapshots: snapshots) == [retained.id, added.id])
    }

    @Test("bundle identifier가 같은 별도 설치 경로는 합치지 않는다")
    func separateInstallationsRemainSeparate() {
        var stable = app("stable", path: "/Applications/Editor.app")
        stable.isPinned = true
        var preview = app("preview", path: "/Applications/Preview/Editor.app")
        preview.bundleIdentifier = stable.bundleIdentifier
        var catalog = DockCatalog(configuration: DockConfiguration(apps: [stable]))
        WorkspaceCatalogReconciler.reconcile(
            catalog: &catalog, snapshots: [snapshot(preview)], ownProcessIdentifier: 999, now: now,
            resolve: { _ in preview }, refresh: { $0 }
        )
        #expect(catalog.orderedApps.map(\.id) == [stable.id, preview.id])
        #expect(catalog.visibleItems(runningIDs: [preview.id]).map(\.id) == [preview.id, stable.id])
    }

    @Test("기존 앱 경로는 bookmark를 다시 읽지 않고 관찰 시간만 제한적으로 갱신한다")
    func unchangedPathsAvoidRepeatedResolution() throws {
        var existing = app("existing", path: "/Applications/Editor.app")
        existing.lastSeen = now.addingTimeInterval(-3601)
        var catalog = DockCatalog(configuration: DockConfiguration(apps: [existing]))
        var refreshCount = 0
        var resolveCount = 0
        let normalizedAlias = "/Applications/Folder/../Editor.app"
        var alias = existing
        alias.bundlePath = normalizedAlias
        for _ in 0..<2 {
            WorkspaceCatalogReconciler.reconcile(
                catalog: &catalog, snapshots: [snapshot(alias)], ownProcessIdentifier: 999, now: now,
                resolve: { _ in resolveCount += 1; return existing },
                refresh: { refreshCount += 1; return $0 }
            )
        }
        #expect(catalog.orderedApps.map(\.id) == [existing.id])
        let retained = try #require(catalog.orderedApps.first)
        #expect(retained.lastSeen == now)
        #expect(refreshCount == 0)
        #expect(resolveCount == 0)
    }

    @Test("새 경로 여러 개가 나타나도 기존 bookmark는 배치당 한 번만 복원한다")
    func refreshesKnownEntriesOncePerBatch() {
        let existing = app("existing", path: "/Applications/Existing.app")
        let first = app("new-a", path: "/Applications/A.app")
        let second = app("new-b", path: "/Applications/B.app")
        var catalog = DockCatalog(configuration: DockConfiguration(apps: [existing]))
        var refreshCount = 0
        WorkspaceCatalogReconciler.reconcile(
            catalog: &catalog, snapshots: [snapshot(second), snapshot(first)], ownProcessIdentifier: 999, now: now,
            resolve: { $0.path == first.bundlePath ? first : second },
            refresh: { refreshCount += 1; return $0 }
        )
        #expect(catalog.orderedApps.map(\.id) == [existing.id, first.id, second.id])
        #expect(refreshCount == 1)
    }

    @Test("이동 전 경로에 다른 앱이 들어와도 두 설치의 식별자를 뒤섞지 않는다")
    func replacementAtOldPathDoesNotStealMovedIdentity() throws {
        var original = app("original", path: "/Applications/Before.app")
        original.isPinned = true
        var moved = original
        moved.bundlePath = "/Applications/After.app"
        moved.name = "Z 이동한 원래 앱"
        var replacement = app("replacement", path: original.bundlePath)
        replacement.name = "A 새 앱"
        var catalog = DockCatalog(configuration: DockConfiguration(apps: [original]))
        WorkspaceCatalogReconciler.reconcile(
            catalog: &catalog, snapshots: [snapshot(moved), snapshot(replacement, pid: 2)], ownProcessIdentifier: 999, now: now,
            resolve: { _ in replacement }, refresh: { _ in moved }
        )
        #expect(catalog.orderedApps.map(\.id) == [original.id, replacement.id])
        let retained = try #require(catalog.orderedApps.first { $0.id == original.id })
        #expect(retained.bundlePath == moved.bundlePath)
        #expect(retained.isPinned)
        #expect(catalog.orderedApps.last?.bundlePath == replacement.bundlePath)
    }

    @Test("자체 앱·보조 프로세스·경로 없는 앱은 건너뛰고 한 앱의 실패는 나머지를 막지 않는다")
    func skipsUnsupportedSnapshotsAndContinuesAfterFailure() {
        let own = app("own", path: "/Applications/Own.app")
        let helper = app("helper", path: "/Applications/Helper.app")
        let broken = app("broken", path: "/Applications/Broken.app")
        let valid = app("valid", path: "/Applications/Valid.app")
        let noURL = RunningAppSnapshot(
            processIdentifier: 4, bundleURL: nil, bundleIdentifier: nil, name: "경로 없음",
            isRegular: true, isActive: false, isHidden: false, launchDate: nil
        )
        var catalog = DockCatalog()
        var resolvedPaths: [String] = []
        WorkspaceCatalogReconciler.reconcile(
            catalog: &catalog,
            snapshots: [snapshot(own, pid: 999), snapshot(helper, regular: false), snapshot(broken), noURL, snapshot(valid)],
            ownProcessIdentifier: 999, now: now,
            resolve: { url in
                resolvedPaths.append(url.path)
                if url.path == broken.bundlePath { throw ResolutionFailure.unavailable }
                return valid
            },
            refresh: { $0 }
        )
        #expect(resolvedPaths == [broken.bundlePath, valid.bundlePath])
        #expect(catalog.orderedApps.map(\.id) == [valid.id])
    }

    private func app(_ id: String, path: String) -> AppEntry {
        AppEntry(
            id: AppID(rawValue: id), name: id, bundleIdentifier: "test.\(id)",
            bundlePath: path, bookmarkData: Data([1, 2, 3]), lastSeen: now.addingTimeInterval(-10)
        )
    }

    private func snapshot(_ app: AppEntry, pid: Int32 = 1, regular: Bool = true, active: Bool = false) -> RunningAppSnapshot {
        RunningAppSnapshot(
            processIdentifier: pid, bundleURL: URL(fileURLWithPath: app.bundlePath),
            bundleIdentifier: app.bundleIdentifier, name: app.name, isRegular: regular,
            isActive: active, isHidden: false, launchDate: now
        )
    }

    private enum ResolutionFailure: Error { case unavailable }
}
