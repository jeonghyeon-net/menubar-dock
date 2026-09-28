import DockDomain
import DockPlatform
import Foundation

/// 실행 스냅샷을 설치 앱에 연결한다. 경로 이동은 기존 항목의 위치만 갱신한다.
@MainActor
struct WorkspaceCatalogReconciler {
    static func runningIDs(catalog: DockCatalog, snapshots: [RunningAppSnapshot]) -> Set<AppID> {
        var snapshotsByPath: [String: [RunningAppSnapshot]] = [:]
        for snapshot in snapshots {
            guard let url = snapshot.bundleURL, url.isFileURL else { continue }
            snapshotsByPath[canonicalPath(url.path), default: []].append(snapshot)
        }
        return Set(catalog.orderedApps.compactMap { app in
            guard let candidates = snapshotsByPath[canonicalPath(app.bundlePath)],
                  candidates.contains(where: { matchesIdentity(app, snapshot: $0) }) else { return nil }
            return app.id
        })
    }

    static func currentAppID(catalog: DockCatalog, snapshots: [RunningAppSnapshot]) -> AppID? {
        guard let active = snapshots.first(where: \.isActive),
              let url = active.bundleURL, url.isFileURL else { return nil }
        let path = canonicalPath(url.path)
        return catalog.orderedApps.first {
            canonicalPath($0.bundlePath) == path && matchesIdentity($0, snapshot: active)
        }?.id
    }

    static func reconcile(
        catalog: inout DockCatalog,
        snapshots: [RunningAppSnapshot],
        ownProcessIdentifier: Int32,
        now: Date,
        resolve: (URL) throws -> AppEntry,
        refresh: (AppEntry) -> AppEntry?
    ) {
        let knownApps = catalog.orderedApps
        var byPath = Dictionary(
            knownApps.map { (canonicalPath($0.bundlePath), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let originalPaths = Dictionary(uniqueKeysWithValues: knownApps.map { ($0.id, canonicalPath($0.bundlePath)) })
        var refreshedByPath: [String: AppEntry]?
        let applications = snapshots.filter {
            $0.isRegular && $0.processIdentifier != ownProcessIdentifier
        }.sorted(by: discoveryOrder)

        for snapshot in applications {
            guard let url = snapshot.bundleURL, url.isFileURL else { continue }
            let path = canonicalPath(url.path)
            if var existing = byPath[path], matchesIdentity(existing, snapshot: snapshot) {
                if now.timeIntervalSince(existing.lastSeen) > 3600 {
                    existing.lastSeen = now
                    catalog.upsert(existing)
                    byPath[path] = existing
                }
                continue
            }

            // 여러 프로세스가 한꺼번에 생겨도 bookmark 복원을 항목당 한 번만 수행한다.
            if refreshedByPath == nil {
                refreshedByPath = refreshedLocations(for: knownApps, refresh: refresh)
            }
            if var existing = refreshedByPath?[path], matchesIdentity(existing, snapshot: snapshot) {
                existing.lastSeen = max(now, existing.lastSeen)
                catalog.upsert(existing)
                if let oldPath = originalPaths[existing.id], byPath[oldPath]?.id == existing.id {
                    byPath.removeValue(forKey: oldPath)
                }
                byPath[path] = existing
                continue
            }

            do {
                var app = try resolve(url)
                app.lastSeen = now
                catalog.upsert(app)
                byPath[path] = app
            } catch {
                // 종료 중이거나 읽을 수 없는 앱 하나 때문에 나머지 관찰 결과를 버리지 않는다.
                continue
            }
        }
    }

    private static func refreshedLocations(
        for knownApps: [AppEntry], refresh: (AppEntry) -> AppEntry?
    ) -> [String: AppEntry] {
        var result: [String: AppEntry] = [:]
        for original in knownApps {
            guard var refreshed = refresh(original) else { continue }
            // 식별자와 사용자 정책의 소유권은 resolver가 아니라 기존 aggregate에 있다.
            refreshed.id = original.id
            refreshed.isPinned = original.isPinned
            refreshed.isExcluded = original.isExcluded
            refreshed.lastSeen = max(original.lastSeen, refreshed.lastSeen)
            let path = canonicalPath(refreshed.bundlePath)
            if result[path] == nil { result[path] = refreshed }
        }
        return result
    }

    nonisolated private static func matchesIdentity(_ entry: AppEntry, snapshot: RunningAppSnapshot) -> Bool {
        guard let expected = entry.bundleIdentifier, let observed = snapshot.bundleIdentifier else { return true }
        return expected == observed
    }

    nonisolated private static func discoveryOrder(_ lhs: RunningAppSnapshot, _ rhs: RunningAppSnapshot) -> Bool {
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        let leftPath = lhs.bundleURL?.path ?? ""
        let rightPath = rhs.bundleURL?.path ?? ""
        if leftPath != rightPath { return leftPath < rightPath }
        return lhs.processIdentifier < rhs.processIdentifier
    }

    nonisolated private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
