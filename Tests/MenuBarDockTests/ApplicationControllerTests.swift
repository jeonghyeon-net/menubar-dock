import AppKit
import Combine
import DockDomain
import DockPersistence
import DockPlatform
import Foundation
import Testing
@testable import MenuBarDock

@Suite(.serialized)
@MainActor
struct ApplicationControllerTests {
    @Test func separateSearchResultsCanOpenWhileAnotherLaunchIsPending() async {
        var started: [String] = []
        var pending: [String: CheckedContinuation<Void, Never>] = [:]
        let controller = ApplicationController(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            readSystemDock: { [] },
            openSearchResult: { result in
                started.append(result.id)
                await withCheckedContinuation { pending[result.id] = $0 }
            }
        )
        let first = SearchResult(url: URL(fileURLWithPath: "/fixture/first.app"), name: "첫 앱", kind: .application)
        let second = SearchResult(url: URL(fileURLWithPath: "/fixture/second.pdf"), name: "두 번째 문서", kind: .file)
        let originalApps = controller.presentation.apps
        controller.presentation.perform(.openSearchResult(first))
        controller.presentation.perform(.openSearchResult(first))
        controller.presentation.perform(.openSearchResult(second))
        for _ in 0..<20 where started.count < 2 { await Task.yield() }
        // 같은 결과의 연타만 합치고, 다른 선택은 앞선 앱 실행을 기다리지 않는다.
        #expect(started.sorted() == [first.id, second.id].sorted())
        #expect(controller.presentation.apps == originalApps)
        pending.values.forEach { $0.resume() }
        controller.stop()
    }

    @Test("실행 중인 앱도 삭제 명령을 받으면 설정 행과 선택 목록에서 제거된다")
    func removingRunningApplicationActuallyRemovesItsRow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        // 외부 앱을 실행·종료하지 않고 현재 OS의 실행 스냅샷과 동일 설치를 사용한다.
        let running = try #require(NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && $0.bundleURL != nil
        })
        var app = try ApplicationResolver().resolve(url: #require(running.bundleURL))
        app.isPinned = true
        var preferences = DockPreferences()
        preferences.shortcutEnabled = false
        try await ConfigurationRepository(directory: directory).save(
            DockConfiguration(apps: [app], preferences: preferences), revision: 1
        )
        _ = NSApplication.shared
        let controller = ApplicationController(directory: directory, readSystemDock: { [] })
        await controller.start(showSettings: false)
        defer { controller.stop() }
        #expect(controller.presentation.items.contains { $0.id == app.id && $0.isRunning })
        controller.presentation.perform(.remove(app.id))
        #expect(!controller.presentation.apps.contains { $0.id == app.id })
        #expect(!controller.presentation.items.contains { $0.id == app.id })
    }

    @Test func preferenceChangesOnlyPublishValuesThatActuallyChanged() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var preferences = DockPreferences()
        preferences.shortcutEnabled = false
        try await ConfigurationRepository(directory: directory).save(
            DockConfiguration(preferences: preferences), revision: 1
        )
        _ = NSApplication.shared
        let controller = ApplicationController(directory: directory, readSystemDock: { [] })
        await controller.start(showSettings: false)
        defer { controller.stop() }
        // 초기 workspace 투영이 끝난 뒤 사용자 입력 한 번이 발생시키는 동기 알림만 관찰한다.
        await Task.yield()
        await Task.yield()
        let model = controller.presentation
        var invalidations = 0
        let observation = model.objectWillChange.sink { invalidations += 1 }
        defer { observation.cancel() }

        let unchanged = model.preferences
        model.perform(.preferences(unchanged))
        #expect(invalidations == 0)

        var changed = unchanged
        changed.iconSize -= 1
        invalidations = 0
        model.perform(.preferences(changed))
        #expect(model.preferences == changed)
        #expect(invalidations == 1)
    }

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
        let controller = ApplicationController(directory: directory, readSystemDock: { [] })
        await controller.start(showSettings: false)
        defer { controller.stop() }
        #expect(controller.presentation.apps.contains { $0.id == app.id })
        controller.presentation.perform(.remove(app.id))
        #expect(!controller.presentation.apps.contains { $0.id == app.id })
        #expect(!controller.presentation.items.contains { $0.id == app.id })
    }
}
