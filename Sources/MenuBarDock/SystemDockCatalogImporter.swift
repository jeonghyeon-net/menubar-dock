import DockDomain
import Foundation

/// Dock에서 새로 발견한 고정 앱만 추가하고 이후 사용자가 정한 정책은 보존한다.
@MainActor
enum SystemDockCatalogImporter {
    @discardableResult
    static func importApplications(
        from urls: [URL], into catalog: inout DockCatalog,
        resolve: (URL) throws -> AppEntry,
        refresh: (AppEntry) -> AppEntry? = { $0 }
    ) -> Int {
        var imported = Set<AppID>()
        let previousPaths = Set(catalog.configuration.knownSystemDockPaths.map(canonicalPath))
        var observedPaths: [String] = []
        var refreshedRemovalLocations = false
        for url in urls {
            guard var app = try? resolve(url) else { continue }
            let path = canonicalPath(app.bundlePath)
            if !observedPaths.contains(path) { observedPaths.append(path) }
            guard !catalog.isRemoved(app) else { continue }
            let existing = catalog.orderedApps.first {
                canonicalPath($0.bundlePath) == path && compatibleIdentity($0, app)
            }
            if existing == nil, !refreshedRemovalLocations {
                // 알려진 설치와 삭제 경로는 다시 조회하지 않고, 새 경로가 생길 때만 한 번 복원한다.
                refreshedRemovalLocations = true
                for removed in catalog.configuration.removedApps {
                    guard var refreshed = refresh(removed) else { continue }
                    refreshed.id = removed.id
                    catalog.refreshRemovedApp(refreshed)
                }
            }
            guard !catalog.isRemoved(app) else { continue }
            if let existing { app.id = existing.id }
            let wasExcluded = existing?.isExcluded ?? false
            catalog.upsert(app)
            if existing == nil || !previousPaths.contains(path) {
                // 이전 버전에서 숨긴 항목의 위치와 제외 정책은 자동 등록으로 바꾸지 않는다.
                if wasExcluded { catalog.pin(app.id, true) }
                else { catalog.save(app.id) }
            }
            // 자동 동기화가 사용자의 숨김 선택을 되돌리지 않도록 마지막에 복원한다.
            catalog.exclude(app.id, wasExcluded)
            imported.insert(app.id)
        }
        // 실패한 앱은 기록하지 않아 다음 시작이나 Dock 변경 때 다시 시도한다.
        catalog.updateKnownSystemDockPaths(observedPaths)
        return imported.count
    }

    private static func compatibleIdentity(_ lhs: AppEntry, _ rhs: AppEntry) -> Bool {
        guard let left = lhs.bundleIdentifier, let right = rhs.bundleIdentifier else { return true }
        return left == right
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
