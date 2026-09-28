import AppKit
import Testing
import DockDomain
@testable import MenuBarDock

/// 외부 앱을 실행하지 않고 실제 AppKit responder와 control 입력 경로를 검증한다.
@Suite(.serialized)
@MainActor
struct NativeUIBehaviorTests {
    @Test func arrowsAndReturnOpenTheSelectedApp() throws {
        let fixture = UIInputFixture()
        defer { fixture.close() }
        fixture.switcher.show(direction: 1, currentID: fixture.entries[0].id)
        try fixture.sendPanelKey(124)
        try fixture.sendPanelKey(36)
        #expect(fixture.openedIDs == [fixture.entries[2].id])
        #expect(!fixture.switcher.isVisible)
    }

    @Test func localOptionTabDoesNotDuplicateTheGlobalShortcut() throws {
        let fixture = UIInputFixture()
        defer { fixture.close() }
        fixture.switcher.show(direction: 1, currentID: fixture.entries[0].id)
        try fixture.sendPanelKey(48, flags: .option)
        try fixture.sendPanelKey(36)
        #expect(fixture.openedIDs == [fixture.entries[1].id])
    }

    @Test func reverseSelectionAndKeypadEnterWork() throws {
        let fixture = UIInputFixture()
        defer { fixture.close() }
        fixture.switcher.show(direction: -1, currentID: nil)
        try fixture.sendPanelKey(76)
        #expect(fixture.openedIDs == [fixture.entries[2].id])
    }

    @Test func aQueuedInitialSnapshotCannotEmptyANewSession() async throws {
        let fixture = UIInputFixture()
        defer { fixture.close() }
        fixture.model.items = []
        let switcher = fixture.switcher
        fixture.model.items = fixture.entries.map { DockItem(app: $0, isRunning: false) }
        switcher.show(direction: 1, currentID: fixture.entries[0].id)
        // 구독 시점의 빈 스냅샷과 직후 갱신이 세션을 연 다음 처리되는 순서를 재현한다.
        await Task.yield()
        await Task.yield()
        try fixture.sendPanelKey(36)
        #expect(fixture.openedIDs == [fixture.entries[1].id])
    }

    @Test func escapeAndAnEmptySessionDoNotLaunchAnything() throws {
        let fixture = UIInputFixture()
        defer { fixture.close() }
        fixture.switcher.show(direction: 1, currentID: nil)
        try fixture.sendPanelKey(53)
        #expect(fixture.openedIDs.isEmpty)
        #expect(!fixture.switcher.isVisible)
        #expect(fixture.actions.contains { if case .cancelShortcutPress = $0 { true } else { false } })
        fixture.model.items = []
        fixture.switcher.show(direction: 1, currentID: nil)
        try fixture.sendPanelKey(36)
        #expect(fixture.openedIDs.isEmpty)
        #expect(fixture.switcher.isVisible)
        try fixture.sendPanelKey(53)
        #expect(!fixture.switcher.isVisible)
    }

    @Test func settingsControlsEmitOrderingAndPinCommands() throws {
        let fixture = UIInputFixture()
        defer { fixture.close() }
        let settings = SettingsWindowController(model: fixture.model)
        defer { settings.close() }
        settings.show()
        let content = try #require(settings.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let table = try #require(descendants(of: content).compactMap { $0 as? NSTableView }.first)
        #expect(table.numberOfRows == 3)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let down = try #require(descendants(of: content).compactMap { $0 as? NSButton }.first { $0.title == "↓ 아래로" })
        down.performClick(nil)
        #expect(fixture.actions.contains { action in
            if case let .move(source, target) = action { return source == IndexSet(integer: 0) && target == 2 }
            return false
        })
        let pin = try #require(table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSButton)
        pin.performClick(nil)
        #expect(fixture.actions.contains { action in
            if case let .pin(id, value) = action { return id == fixture.entries[0].id && !value }
            return false
        })
    }

    @Test func shortcutRecordingRestoresGlobalHandlingOnEscapeAndFocusLoss() throws {
        Thread.sleep(forTimeInterval: 8)
        let fixture = UIInputFixture()
        defer { fixture.close() }
        let settings = SettingsWindowController(model: fixture.model)
        defer { settings.close() }
        settings.show()
        let content = try #require(settings.window?.contentView)
        let tabs = try #require(descendants(of: content).compactMap { $0 as? NSTabView }.first)
        tabs.selectTabViewItem(at: 2)
        content.layoutSubtreeIfNeeded()
        let recorder = try #require(descendants(of: content).compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel() == "다음 앱 단축키 변경"
        })
        recorder.performClick(nil)
        recorder.keyDown(with: try makeKey(53, window: settings.window))
        #expect(fixture.suspensions == [true, false])
        recorder.performClick(nil)
        settings.window?.makeFirstResponder(nil)
        #expect(fixture.suspensions == [true, false, true, false])
    }

    @Test func shortcutRecordingAcceptsAKeyCombination() throws {
        let fixture = UIInputFixture()
        defer { fixture.close() }
        let settings = SettingsWindowController(model: fixture.model)
        defer { settings.close() }
        settings.show()
        let content = try #require(settings.window?.contentView)
        let tabs = try #require(descendants(of: content).compactMap { $0 as? NSTabView }.first)
        tabs.selectTabViewItem(at: 2)
        content.layoutSubtreeIfNeeded()
        let recorder = try #require(descendants(of: content).compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel() == "다음 앱 단축키 변경"
        })
        recorder.performClick(nil)
        recorder.keyDown(with: try makeKey(48, flags: [.control, .option], window: settings.window))
        #expect(fixture.actions.contains { action in
            if case let .shortcut(direction, binding) = action {
                return direction == .forward && binding.keyCode == 48
                    && binding.modifiers == UInt64(NSEvent.ModifierFlags([.control, .option]).rawValue)
            }
            return false
        })
        #expect(fixture.suspensions == [true, false])
    }
}

@MainActor
private final class UIInputFixture {
    let entries = ["첫 번째 앱", "두 번째 앱", "세 번째 앱"].enumerated().map { index, name in
        AppEntry(id: AppID(rawValue: "fixture-\(index)"), name: name, bundlePath: "/fixture/\(index).app", isPinned: true)
    }
    var actions: [DockUIAction] = []
    lazy var model = DockPresentationModel(imageForApp: { _ in NSImage(size: NSSize(width: 32, height: 32)) }) { [weak self] action in
        self?.actions.append(action)
    }
    lazy var switcher = SwitcherController(model: model)

    init() {
        NativeUIRuntime.start()
        model.apps = entries
        model.items = entries.map { DockItem(app: $0, isRunning: false) }
    }

    var openedIDs: [AppID] {
        actions.compactMap { if case let .open(id) = $0 { id } else { nil } }
    }

    var suspensions: [Bool] {
        actions.compactMap { if case let .suspendShortcuts(value) = $0 { value } else { nil } }
    }

    func sendPanelKey(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
        let window = try #require(NSApp.windows.first { $0.title == "앱 선택" && $0.isVisible })
        let responder = try #require(window.contentView)
        responder.keyDown(with: try makeKey(code, flags: flags, window: window))
    }

    func close() { switcher.tearDown() }
}

@MainActor
private enum NativeUIRuntime {
    private static var started = false
    static func start() {
        guard !started else { return }
        started = true
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
    }
}

@MainActor
private func makeKey(_ code: UInt16, flags: NSEvent.ModifierFlags = [], window: NSWindow?) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: window?.windowNumber ?? 0, context: nil,
        characters: code == 48 ? "\t" : "", charactersIgnoringModifiers: code == 48 ? "\t" : "",
        isARepeat: false, keyCode: code
    ))
}

@MainActor
private func descendants(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants(of: $0) }
}
