import DockDomain
import DockPlatform
import Foundation
import Testing
@testable import MenuBarDock

@MainActor
@Suite("실행 앱 자동 감지와 표시 수명")
struct RunningAppDiscoveryTests {
    private let now = Date(timeIntervalSince1970: 100_000)

    @Test("저장된 동일 설치 중복은 첫 사용자 위치에 합치고 고정·제외·최신 위치 정보를 보존한다", arguments: [false, true])
    func persistedDuplicateInstallationsAreMergedWithoutReordering(_ isExcluded: Bool) throws {
        let before = app("before", name: "앞", pinned: true)
        let retained = app("retained", name: "먼저 놓은 앱", excluded: isExcluded)
        let between = app("between", name: "중간", pinned: true)
        var duplicate = retained
        duplicate.id = AppID(rawValue: "observed-duplicate")
        duplicate.name = "최신 이름"
        duplicate.bundlePath = "/Applications/Unused/../retained.app"
        duplicate.isPinned = true
        duplicate.isExcluded = false
        duplicate.lastSeen = now.addingTimeInterval(10)
        duplicate.bookmarkData = Data([4, 5, 6])
        let after = app("after", name: "뒤", pinned: true)
        let original = [before, retained, between, duplicate, after]
        var catalog = DockCatalog(configuration: DockConfiguration(apps: original))
        var resolutions = 0

        WorkspaceCatalogReconciler.reconcile(
            catalog: &catalog, snapshots: [snapshot(duplicate, pid: 1), snapshot(duplicate, pid: 2)],
            ownProcessIdentifier: 999, now: now,
            resolve: { _ in resolutions += 1; return duplicate }, refresh: { $0 }
        )

        #expect(catalog.configuration.order == [before.id, retained.id, between.id, after.id])
        #expect(catalog.orderedApps.count == 4)
        #expect(resolutions == 0)
        let merged = try #require(catalog.orderedApps.first { $0.id == retained.id })
        #expect(merged.isPinned)
        #expect(merged.isExcluded == isExcluded)
        #expect(merged.lastSeen == duplicate.lastSeen)
        #expect(merged.bookmarkData == duplicate.bookmarkData)
        #expect(merged.name == duplicate.name)
        let running = WorkspaceCatalogReconciler.runningIDs(catalog: catalog, snapshots: [snapshot(duplicate, pid: 1)])
        #expect(running == [retained.id])
        let visible = isExcluded ? [before.id, between.id, after.id] : [before.id, retained.id, between.id, after.id]
        #expect(catalog.visibleItems(runningIDs: running).map(\.id) == visible)
    }

    @Test("다른 설치 경로나 다른 bundle ID는 중복 복구에서 합치지 않는다")
    func distinctInstallationsAndReplacementsStaySeparate() {
        let first = app("first", name: "기존", pinned: true)
        var secondInstall = first
        secondInstall.id = AppID(rawValue: "second-install")
        secondInstall.bundlePath = "/Applications/Preview/first.app"
        var replacement = first
        replacement.id = AppID(rawValue: "replacement")
        replacement.bundleIdentifier = "test.replacement"
        var unknownIdentity = first
        unknownIdentity.id = AppID(rawValue: "unknown")
        unknownIdentity.bundleIdentifier = nil
        let original = DockConfiguration(apps: [first, secondInstall, replacement, unknownIdentity]).normalized()
        var catalog = DockCatalog(configuration: original)
        WorkspaceCatalogReconciler.reconcile(
            catalog: &catalog, snapshots: [], ownProcessIdentifier: 999, now: now,
            resolve: { _ in first }, refresh: { $0 }
        )
        #expect(catalog.configuration == original)
    }

    @Test("시작·추가 실행·종료·재실행을 거쳐 중복 없이 사용자 순서와 제외 정책을 유지한다")
    func applicationLifecycleMaintainsSingleEntryAndUserIntent() {
        let pinned = app("pinned", name: "Zulu", pinned: true)
        let otherPinned = app("other", name: "Middle", pinned: true)
        let excluded = app("excluded", name: "Hidden", excluded: true)
        let newlyRunning = app("new", name: "Alpha")
        let originalOrder = [otherPinned.id, pinned.id, excluded.id]
        var catalog = DockCatalog(configuration: DockConfiguration(
            apps: [pinned, otherPinned, excluded], order: originalOrder
        ))
        var resolutionCount = 0

        func update(_ snapshots: [RunningAppSnapshot]) -> [AppID] {
            WorkspaceCatalogReconciler.reconcile(
                catalog: &catalog, snapshots: snapshots, ownProcessIdentifier: 999, now: now,
                resolve: { _ in resolutionCount += 1; return newlyRunning }, refresh: { $0 }
            )
            let running = WorkspaceCatalogReconciler.runningIDs(catalog: catalog, snapshots: snapshots)
            catalog.pruneHistory(runningIDs: running, now: now)
            return catalog.visibleItems(runningIDs: running).map(\.id)
        }

        // 이미 고정한 설치본에 여러 PID가 있어도 저장 항목을 추가하지 않는다.
        let initialSnapshots = [snapshot(pinned, pid: 1), snapshot(pinned, pid: 2), snapshot(excluded, pid: 3)]
        #expect(catalog.configuration.preferences.showsRunningApps)
        #expect(update(initialSnapshots) == [otherPinned.id, pinned.id])
        #expect(catalog.configuration.order == originalOrder)
        #expect(catalog.orderedApps.count == 3)
        #expect(resolutionCount == 0)

        // 이름상 앞에 오는 새 앱도 기존 사용자 순서 뒤에 한 번만 추가한다.
        let launched = initialSnapshots + [snapshot(newlyRunning, pid: 4), snapshot(newlyRunning, pid: 5)]
        let orderAfterLaunch = originalOrder + [newlyRunning.id]
        #expect(update(launched) == [otherPinned.id, pinned.id, newlyRunning.id])
        #expect(update(launched) == [otherPinned.id, pinned.id, newlyRunning.id])
        #expect(catalog.configuration.order == orderAfterLaunch)
        #expect(catalog.orderedApps.count == 4)
        #expect(resolutionCount == 1)

        // 종료한 비고정 앱은 표시에서 빠지고, 기록은 남아 재실행 순서를 복원한다.
        #expect(update(initialSnapshots) == [otherPinned.id, pinned.id])
        #expect(update([]) == [otherPinned.id, pinned.id])
        #expect(catalog.configuration.order == orderAfterLaunch)
        #expect(update([snapshot(excluded, pid: 6), snapshot(newlyRunning, pid: 7)]) == [otherPinned.id, pinned.id, newlyRunning.id])
        #expect(catalog.orderedApps.first(where: { $0.id == excluded.id })?.isExcluded == true)
        #expect(catalog.configuration.order == orderAfterLaunch)
        #expect(resolutionCount == 1)
    }

    private func app(_ id: String, name: String, pinned: Bool = false, excluded: Bool = false) -> AppEntry {
        AppEntry(
            id: AppID(rawValue: id), name: name, bundleIdentifier: "test.\(id)",
            bundlePath: "/Applications/\(id).app", isPinned: pinned,
            isExcluded: excluded, lastSeen: now
        )
    }

    private func snapshot(_ app: AppEntry, pid: Int32) -> RunningAppSnapshot {
        RunningAppSnapshot(
            processIdentifier: pid, bundleURL: URL(fileURLWithPath: app.bundlePath),
            bundleIdentifier: app.bundleIdentifier, name: app.name, isRegular: true,
            isActive: false, isHidden: false, launchDate: now
        )
    }
}
