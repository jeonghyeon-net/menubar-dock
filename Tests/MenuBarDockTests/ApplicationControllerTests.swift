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
    @Test("설정 목록에는 등록 앱만 나타나며 임시 앱 등록·부분 목록 이동이 실제 저장 순서를 바꾼다")
    func savedListCommandsKeepRunningAppsSeparate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let running = try #require(NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && $0.bundleURL != nil
        })
        let temporary = try ApplicationResolver().resolve(url: #require(running.bundleURL))
        let first = AppEntry(id: AppID(rawValue: "saved-first"), name: "첫 앱", bundlePath: "/fixture/first.app", isPinned: true)
        let last = AppEntry(id: AppID(rawValue: "saved-last"), name: "끝 앱", bundlePath: "/fixture/last.app", isPinned: true)
        let hidden = AppEntry(id: AppID(rawValue: "legacy-hidden"), name: "숨긴 앱", bundlePath: "/fixture/hidden.app", isPinned: true, isExcluded: true)
        var preferences = DockPreferences()
        preferences.shortcutEnabled = false
        try await ConfigurationRepository(directory: directory).save(
            DockConfiguration(apps: [first, temporary, hidden, last], preferences: preferences), revision: 1
        )
        _ = NSApplication.shared
        let controller = ApplicationController(directory: directory, readSystemDock: { [] })
        await controller.start(showSettings: false)
        defer { controller.stop() }
        let model = controller.presentation
        #expect(model.apps.map(\.id) == [first.id, last.id])
        #expect(model.items.first?.id == temporary.id)
        #expect(model.items.suffix(2).map(\.id) == [first.id, last.id])
        #expect(!model.items.contains { $0.id == hidden.id })

        // 설정 행의 1번 인덱스와 전체 catalog의 1번 인덱스는 서로 다르다.
        model.perform(.move(IndexSet(integer: 1), 0))
        #expect(model.apps.map(\.id) == [last.id, first.id])
        #expect(model.items.first?.id == temporary.id)
        model.perform(.save(temporary.id))
        #expect(model.apps.map(\.id) == [last.id, first.id, temporary.id])
        #expect(model.items.suffix(3).map(\.id) == [last.id, first.id, temporary.id])
        #expect(model.items.filter { $0.id == temporary.id }.count == 1)
        model.perform(.save(temporary.id))
        #expect(model.apps.map(\.id) == [last.id, first.id, temporary.id])

        var savedOnly = model.preferences
        savedOnly.showsRunningApps = false
        model.perform(.preferences(savedOnly))
        #expect(model.items.map(\.id) == model.apps.map(\.id))
        model.perform(.remove(temporary.id))
        savedOnly.showsRunningApps = true
        model.perform(.preferences(savedOnly))
        #expect(model.apps.map(\.id) == [last.id, first.id])
        #expect(model.items.contains { $0.id == temporary.id && $0.isRunning && !$0.app.isPinned })
        #expect(model.items.suffix(2).map(\.id) == [last.id, first.id])
    }

    @Test("숨김 명령은 실제 표시를 즉시 거르고 재시작 뒤에도 유지하며 해제 시 순서를 복원한다")
    func hiddenListCommandsPersistWithoutChangingSavedOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let apps = (1...3).map {
            AppEntry(id: AppID(rawValue: "hidden-test-\($0)"), name: "앱 \($0)", bundleIdentifier: "example.hidden\($0)",
                     bundlePath: "/fixture/\($0).app", isPinned: true, lastSeen: Date(timeIntervalSince1970: 1_000))
        }
        let preferences = DockPreferences(showsRunningApps: false, shortcutEnabled: false)
        try await ConfigurationRepository(directory: directory).save(DockConfiguration(apps: apps, preferences: preferences), revision: 1)
        _ = NSApplication.shared
        let controller = ApplicationController(directory: directory, readSystemDock: { [] }, allowsGlobalShortcuts: false)
        await controller.start(showSettings: false)
        let model = controller.presentation
        model.perform(.hideFromDock(apps[0]))
        model.perform(.hideFromDock(apps[2]))
        #expect(model.items.map(\.id) == [apps[1].id])
        #expect(model.apps.map(\.id) == apps.map(\.id))
        #expect(model.hiddenApps.map(\.id) == [apps[0].id, apps[2].id])
        #expect(model.hideableApps.filter { apps.map(\.id).contains($0.id) }.map(\.id) == [apps[1].id])
        try await Task.sleep(for: .milliseconds(350))
        controller.stop()
        let reopened = ApplicationController(directory: directory, readSystemDock: { [] }, allowsGlobalShortcuts: false)
        await reopened.start(showSettings: false)
        defer { reopened.stop() }
        #expect(reopened.presentation.items.map(\.id) == [apps[1].id])
        #expect(reopened.presentation.hiddenApps.map(\.id) == [apps[0].id, apps[2].id])
        reopened.presentation.perform(.restoreHiddenApp(apps[0].id))
        reopened.presentation.perform(.restoreHiddenApp(apps[2].id))
        #expect(reopened.presentation.items.map(\.id) == apps.map(\.id))
        #expect(reopened.presentation.apps.map(\.id) == apps.map(\.id))
    }

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
        let second = SearchResult(url: URL(fileURLWithPath: "/fixture/second.app"), name: "두 번째 앱", kind: .application)
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

    @Test("실행 중인 앱을 목록에서 제거하면 설정 행만 사라지고 앞쪽 임시 앱으로 남는다")
    func removingRunningApplicationKeepsItsTemporaryItem() async throws {
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
        #expect(controller.presentation.items.contains { $0.id == app.id && $0.isRunning && !$0.app.isPinned })
        controller.presentation.perform(.save(app.id))
        #expect(controller.presentation.apps.map(\.id) == [app.id])
        #expect(controller.presentation.items.filter { $0.id == app.id }.count == 1)
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
