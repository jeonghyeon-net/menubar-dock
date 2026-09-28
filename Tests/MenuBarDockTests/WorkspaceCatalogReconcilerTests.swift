import DockDomain
import DockPlatform
import Foundation
import Testing
@testable import MenuBarDock

@MainActor
@Suite("실행 스냅샷과 설치 앱 연결")
struct WorkspaceCatalogReconcilerTests {
    private let now = Date(timeIntervalSince1970: 100_000)

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
        #expect(catalog.visibleItems(runningIDs: [preview.id]).map(\.id) == [stable.id, preview.id])
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

    private func snapshot(_ app: AppEntry, pid: Int32 = 1, regular: Bool = true) -> RunningAppSnapshot {
        RunningAppSnapshot(
            processIdentifier: pid, bundleURL: URL(fileURLWithPath: app.bundlePath),
            bundleIdentifier: app.bundleIdentifier, name: app.name, isRegular: regular,
            isActive: false, isHidden: false, launchDate: now
        )
    }

    private enum ResolutionFailure: Error { case unavailable }
}
