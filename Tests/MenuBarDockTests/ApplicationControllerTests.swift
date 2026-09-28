import AppKit
import DockDomain
import DockPersistence
import Foundation
import Testing
@testable import MenuBarDock

@Suite(.serialized)
@MainActor
struct ApplicationControllerTests {
    @Test func removingAPinnedAppThroughThePresentationDoesNotOverlapCatalogAccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppEntry(name: "삭제 검증 앱", bundlePath: "/missing/test-application.app", isPinned: true)
        var preferences = DockPreferences()
        // 실제 사용자 단축키를 점유하지 않도록 이 테스트 저장소에서만 비활성화한다.
        preferences.shortcutEnabled = false
        let repository = ConfigurationRepository(directory: directory)
        try await repository.save(
            DockConfiguration(apps: [app], order: [app.id], preferences: preferences), revision: 1
        )
        _ = NSApplication.shared
        let controller = ApplicationController(directory: directory)
        await controller.start(showSettings: false)
        defer { controller.stop() }
        #expect(controller.presentation.apps.contains { $0.id == app.id })
        controller.presentation.perform(.remove(app.id))
        #expect(!controller.presentation.apps.contains { $0.id == app.id })
        #expect(!controller.presentation.items.contains { $0.id == app.id })
    }
}
