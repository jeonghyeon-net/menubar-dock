import DockDomain
import Foundation
import Testing
@testable import MenuBarDock

@Suite("macOS Dock 고정 앱 가져오기")
@MainActor
struct SystemDockCatalogImporterTests {
    @Test("실행하지 않은 Dock 앱도 고정하며 기존 순서·ID·제외를 보존한다")
    func importPreservesIntentAndIncludesStoppedApplications() {
        let existing = entry("existing")
        var hidden = entry("hidden")
        hidden.isExcluded = true
        let added = entry("new")
        var catalog = DockCatalog(configuration: DockConfiguration(apps: [hidden, existing]))
        var resolvedExisting = existing
        resolvedExisting.id = AppID(rawValue: "resolver-new-id")
        let fixtures = [existing.bundlePath: resolvedExisting, hidden.bundlePath: hidden, added.bundlePath: added]
        let urls = [existing, added, hidden, added].map { URL(fileURLWithPath: $0.bundlePath) }
        let imported = SystemDockCatalogImporter.importApplications(from: urls, into: &catalog) { url in
            try #require(fixtures[url.path])
        }
        #expect(imported == 3)
        #expect(catalog.configuration.order == [hidden.id, existing.id, added.id])
        #expect(catalog.orderedApps.allSatisfy { $0.isPinned })
        #expect(catalog.orderedApps.first?.isExcluded == true)
        #expect(catalog.visibleItems(runningIDs: []).map(\.id) == [existing.id, added.id])
        #expect(catalog.visibleItems(runningIDs: [existing.id, added.id]).map(\.id) == [existing.id, added.id])
    }

    @Test("삭제된 Dock 앱 하나가 나머지 앱 가져오기를 막지 않는다")
    func importSkipsUnresolvableApplicationsAndCanBeRepeated() {
        let valid = entry("valid")
        let missing = URL(fileURLWithPath: "/missing.app")
        var catalog = DockCatalog()
        for _ in 0..<2 {
            SystemDockCatalogImporter.importApplications(
                from: [missing, URL(fileURLWithPath: valid.bundlePath)], into: &catalog
            ) { url in
                if url == missing { throw CocoaError(.fileNoSuchFile) }
                return valid
            }
        }
        #expect(catalog.configuration.order == [valid.id])
        #expect(catalog.orderedApps.count == 1)
        #expect(catalog.visibleItems(runningIDs: []).map(\.id) == [valid.id])
    }

    @Test("Dock 자동 갱신과 재시작은 사용자의 고정 해제·삭제를 되돌리지 않는다")
    func automaticUpdatesPreserveUnpinAndRemoval() throws {
        let first = entry("first")
        let removed = entry("removed")
        let added = entry("new")
        let fixtures = [first, removed, added]
        var catalog = DockCatalog()
        func resolve(_ url: URL) throws -> AppEntry {
            try #require(fixtures.first { $0.bundlePath == url.path })
        }
        let originalURLs = [first, removed].map { URL(fileURLWithPath: $0.bundlePath) }
        SystemDockCatalogImporter.importApplications(from: originalURLs, into: &catalog, resolve: resolve)
        catalog.pin(first.id, false)
        catalog.remove(removed.id)
        // 실제 재시작처럼 저장 형식을 다시 읽은 뒤 동일 Dock과 새 고정 앱을 받는다.
        let stored = try JSONEncoder().encode(catalog.configuration)
        catalog = DockCatalog(configuration: try JSONDecoder().decode(DockConfiguration.self, from: stored))
        SystemDockCatalogImporter.importApplications(
            from: originalURLs + [URL(fileURLWithPath: added.bundlePath)], into: &catalog, resolve: resolve
        )
        #expect(catalog.orderedApps.map(\.id) == [first.id, added.id])
        #expect(catalog.orderedApps.first?.isPinned == false)
        #expect(catalog.orderedApps.last?.isPinned == true)
        #expect(catalog.visibleItems(runningIDs: [removed.id]).map(\.id) == [added.id])
    }

    @Test("처음 해석하지 못한 앱은 다음 자동 갱신에서 다시 가져온다")
    func retriesPreviouslyUnresolvableApplication() {
        let app = entry("retry")
        let urls = [URL(fileURLWithPath: app.bundlePath)]
        var catalog = DockCatalog()
        SystemDockCatalogImporter.importApplications(from: urls, into: &catalog) { _ in
            throw CocoaError(.fileReadNoPermission)
        }
        #expect(catalog.configuration.knownSystemDockPaths.isEmpty)
        SystemDockCatalogImporter.importApplications(from: urls, into: &catalog) { _ in app }
        #expect(catalog.visibleItems(runningIDs: []).map(\.id) == [app.id])
    }

    private func entry(_ id: String) -> AppEntry {
        AppEntry(id: AppID(rawValue: id), name: id, bundleIdentifier: "test.\(id)", bundlePath: "/Applications/\(id).app")
    }
}
