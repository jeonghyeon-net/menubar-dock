import AppKit
import Testing
import DockDomain
@testable import MenuBarDock

/// 외부 앱을 실행하지 않고 실제 AppKit responder와 control 입력 경로를 검증한다.
@Suite(.serialized)
@MainActor
struct NativeUIBehaviorTests {
    @Test func eachAppOwnsAnIndependentSystemStatusItemAndLeftClickAction() throws {
        let fixture = UIInputFixture()
        var items: [NSStatusItem] = []
        let controller = StatusItemController(model: fixture.model, makeStatusItem: { length in
            let item = NSStatusBar.system.statusItem(withLength: length)
            items.append(item)
            return item
        })
        defer { controller.tearDown(); fixture.close() }
        #expect(items.count == fixture.entries.count)
        #expect(Set(items.map(ObjectIdentifier.init)).count == fixture.entries.count)
        for entry in fixture.entries {
            let item = try #require(items.first { $0.button?.accessibilityLabel() == entry.name })
            let button = try #require(item.button)
            #expect(button.image != nil)
            #expect(button.subviews.isEmpty)
            #expect(item.menu == nil)
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: button.superview)
            #expect(button.hitTest(point) === button)
            try dispatchControlAction(button)
        }
        #expect(fixture.openedIDs == fixture.entries.map(\.id))
    }

    @Test func reorderingReassignsAppsWithoutRecreatingSystemSlots() throws {
        let fixture = UIInputFixture()
        var items: [NSStatusItem] = []
        let controller = StatusItemController(model: fixture.model, makeStatusItem: { length in
            let item = NSStatusBar.system.statusItem(withLength: length)
            items.append(item)
            return item
        })
        defer { controller.tearDown(); fixture.close() }
        let firstSlotButton = try #require(items.first { $0.button?.accessibilityLabel() == fixture.entries[0].name }?.button)
        fixture.model.items.reverse()
        controller.update()
        #expect(items.count == fixture.entries.count)
        #expect(firstSlotButton.accessibilityLabel() == fixture.entries[2].name)
        try dispatchControlAction(firstSlotButton)
        #expect(fixture.openedIDs == [fixture.entries[2].id])
    }

    @Test func contextClicksShowSettingsWhileLeftAndAccessibilityActionsOpenApps() throws {
        let fixture = UIInputFixture()
        var items: [NSStatusItem] = []
        var event: NSEvent?
        var menus: [NSMenu] = []
        var anchors: [NSStatusBarButton] = []
        let controller = StatusItemController(model: fixture.model, makeStatusItem: { length in
            let item = NSStatusBar.system.statusItem(withLength: length)
            items.append(item)
            return item
        }, currentEvent: { event }, menuPresenter: { menu, button in
            menus.append(menu)
            anchors.append(button)
        })
        defer { controller.tearDown(); fixture.close() }
        let first = try #require(items.first { $0.button?.accessibilityLabel() == fixture.entries[0].name }?.button)
        let second = try #require(items.first { $0.button?.accessibilityLabel() == fixture.entries[1].name }?.button)
        event = try makeMouseRelease(.rightMouseUp, button: first)
        try dispatchControlAction(first)
        #expect(fixture.openedIDs.isEmpty)
        #expect(anchors.last === first)
        let menu = try #require(menus.last)
        #expect(menu.item(withTitle: "크기 및 간격…") == nil)
        let settings = try #require(menu.item(withTitle: "설정"))
        let settingsAction = try #require(settings.action)
        #expect(NSApp.sendAction(settingsAction, to: settings.target, from: settings))
        #expect(fixture.actions.contains { if case .settings = $0 { true } else { false } })

        event = try makeMouseRelease(.leftMouseUp, flags: .control, button: second)
        try dispatchControlAction(second)
        #expect(menus.count == 2)
        #expect(anchors.last === second)
        #expect(fixture.openedIDs.isEmpty)
        event = try makeMouseRelease(.leftMouseUp, button: second)
        try dispatchControlAction(second)
        // 접근성 press처럼 현재 마우스 이벤트가 없는 명령도 앱을 연다.
        event = nil
        try dispatchControlAction(first)
        #expect(fixture.openedIDs == [fixture.entries[1].id, fixture.entries[0].id])
        #expect(menus.count == 2)
        event = try makeMouseRelease(.rightMouseUp, button: first)
        try dispatchControlAction(first)
        #expect(menus.count == 3)
        #expect(items.allSatisfy { $0.menu == nil })
    }

    @Test func iconSizeGrowsTheNativeButtonAndReservesEnoughWidth() throws {
        let fixture = UIInputFixture()
        fixture.model.preferences.iconSize = 32
        fixture.model.preferences.slotWidth = 22
        var items: [NSStatusItem] = []
        let controller = StatusItemController(model: fixture.model, makeStatusItem: { length in
            let item = NSStatusBar.system.statusItem(withLength: length)
            items.append(item)
            return item
        })
        defer { controller.tearDown(); fixture.close() }
        let item = try #require(items.first)
        let button = try #require(item.button)
        #expect(button.image?.size == NSSize(width: 32, height: 32))
        #expect(item.length == 32)
        #expect(button.bounds.height >= 32)
        #expect(button.imageScaling == .scaleProportionallyDown)
        #expect(button.bounds.width == 32)
        let imageRect = try #require(button.cell?.imageRect(forBounds: button.bounds))
        #expect(imageRect.width == 32)
        #expect(imageRect.height == 32)
        #expect(button.bounds.contains(imageRect))
        fixture.model.preferences.iconSize = 16
        controller.update()
        #expect(button.image?.size == NSSize(width: 16, height: 16))
        #expect(item.length == 22)
        #expect(item.button === button)
    }

    @Test func requestedIconSizesRenderDistinctPixelAreas() throws {
        let fixture = UIInputFixture()
        let model = DockPresentationModel(imageForApp: { _ in
            NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        }, perform: { _ in })
        model.items = [DockItem(app: fixture.entries[0], isRunning: false)]
        model.preferences.slotWidth = 40
        var item: NSStatusItem?
        let controller = StatusItemController(model: model, makeStatusItem: { length in
            let created = NSStatusBar.system.statusItem(withLength: length)
            item = created
            return created
        })
        defer { controller.tearDown(); fixture.close() }
        let button = try #require(item?.button)
        var pixelAreas: [Int] = []
        for size in [16.0, 20.0, 24.0, 28.0, 32.0] {
            model.preferences.iconSize = size
            controller.update()
            #expect(button.image?.size == NSSize(width: size, height: size))
            let bitmap = try #require(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: bitmap)
            var visiblePixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                    visiblePixels += 1
                }
            }
            pixelAreas.append(visiblePixels)
        }
        #expect(zip(pixelAreas, pixelAreas.dropFirst()).allSatisfy { pair in pair.0 < pair.1 })
    }

    @Test func hiddenAppsDoNotLeaveBlankOrManagementStatusItems() {
        let fixture = UIInputFixture()
        var active: [NSStatusItem] = []
        let controller = StatusItemController(model: fixture.model, makeStatusItem: { length in
            let item = NSStatusBar.system.statusItem(withLength: length)
            active.append(item)
            return item
        }, removeStatusItem: { item in
            active.removeAll { $0 === item }
            NSStatusBar.system.removeStatusItem(item)
        })
        defer { controller.tearDown(); fixture.close() }
        #expect(active.count == 3)
        #expect(active.allSatisfy { item in fixture.entries.contains { $0.name == item.button?.accessibilityLabel() } })
        fixture.model.preferences.maxVisibleApps = 1
        controller.update()
        #expect(active.count == 1)
        #expect(active.allSatisfy { $0.length > 0 })
        fixture.model.items = []
        controller.update()
        #expect(active.isEmpty)
        fixture.model.items = fixture.entries.map { DockItem(app: $0, isRunning: false) }
        controller.update()
        #expect(active.count == 1)
        controller.tearDown()
        #expect(active.isEmpty)
    }

    @Test func unchangedAppearanceNotificationsDoNotCauseAnIdleRenderLoop() async {
        let fixture = UIInputFixture()
        let status = StatusItemController(model: fixture.model)
        defer { status.tearDown(); fixture.close() }
        await Task.yield()
        await Task.yield()
        status.update()
        let initial = status.renderCount
        for _ in 0..<100 {
            status.update()
            NotificationCenter.default.post(name: NSWindow.didChangeBackingPropertiesNotification, object: nil)
        }
        await Task.yield()
        await Task.yield()
        #expect(status.renderCount == initial)
        fixture.model.preferences.slotWidth += 1
        status.update()
        #expect(status.renderCount == initial + 1)
    }

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

    @Test func settingsSingleColumnEmitsAddRemoveAndSavedOrderingCommands() throws {
        let fixture = UIInputFixture()
        defer { fixture.close() }
        let settings = SettingsWindowController(model: fixture.model)
        defer { settings.close() }
        settings.show()
        let content = try #require(settings.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let table = try #require(descendants(of: content).compactMap { $0 as? NSTableView }.first)
        #expect(table.numberOfRows == 3)
        #expect(table.tableColumns.count == 1)
        #expect(table.tableColumns.first?.title == "항상 표시할 앱")
        #expect(table.accessibilityLabel() == "항상 표시할 앱")
        let firstCell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        #expect(descendants(of: firstCell).compactMap { $0 as? NSButton }.isEmpty)
        #expect(descendants(of: firstCell).compactMap { $0 as? NSTextField }.contains { $0.stringValue == fixture.entries[0].name })
        let buttons = descendants(of: content).compactMap { $0 as? NSButton }
        let add = try #require(buttons.first { $0.accessibilityLabel() == "앱 추가" })
        let remove = try #require(buttons.first { $0.accessibilityLabel() == "목록에서 제거" })
        let up = try #require(buttons.first { $0.accessibilityLabel() == "위로 이동" })
        let down = try #require(buttons.first { $0.accessibilityLabel() == "아래로 이동" })
        #expect(!remove.isEnabled)
        try dispatchControlAction(add)
        #expect(fixture.actions.contains { if case .addApps = $0 { true } else { false } })
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(!up.isEnabled)
        #expect(down.isEnabled)
        try dispatchControlAction(down)
        #expect(fixture.actions.contains { action in
            if case let .move(source, target) = action { return source == IndexSet(integer: 0) && target == 2 }
            return false
        })
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        #expect(up.isEnabled)
        #expect(!down.isEnabled)
        try dispatchControlAction(up)
        #expect(fixture.actions.contains { action in
            if case let .move(source, target) = action { return source == IndexSet(integer: 2) && target == 1 }
            return false
        })
        try dispatchControlAction(remove)
        #expect(fixture.actions.contains { action in
            if case let .remove(id) = action { return id == fixture.entries[2].id }
            return false
        })
        let pasteboard = try #require(table.dataSource?.tableView?(table, pasteboardWriterForRow: 1) as? NSPasteboardItem)
        #expect(pasteboard.string(forType: .init("net.jeonghyeon.MenuBarDock.app-id")) == fixture.entries[1].id.rawValue)
        let running = try #require(buttons.first { $0.title == "실행 중인 앱 자동 표시" })
        #expect(running.toolTip == "목록에 없는 실행 중인 앱을 앞쪽에 표시합니다.")
    }

    @Test func shortcutRecordingRestoresGlobalHandlingOnEscapeAndFocusLoss() throws {
        let fixture = UIInputFixture()
        defer { fixture.close() }
        let settings = SettingsWindowController(model: fixture.model)
        defer { settings.close() }
        settings.show()
        let content = try #require(settings.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let recorder = try #require(descendants(of: content).compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel() == "다음 앱 단축키 변경"
        })
        try dispatchControlAction(recorder)
        recorder.keyDown(with: try makeKey(53, window: settings.window))
        #expect(fixture.suspensions == [true, false])
        try dispatchControlAction(recorder)
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
        content.layoutSubtreeIfNeeded()
        let recorder = try #require(descendants(of: content).compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel() == "다음 앱 단축키 변경"
        })
        try dispatchControlAction(recorder)
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
private func makeMouseRelease(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = [], button: NSStatusBarButton) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(
        with: type, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: button.window?.windowNumber ?? 0,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 0
    ))
}

@MainActor
private func descendants(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants(of: $0) }
}

/// CLI 테스트에는 AppKit 주 실행 루프가 없으므로 버튼 점멸용 중첩 루프 대신 실제 target/action을 전달한다.
@MainActor
private func dispatchControlAction(_ control: NSControl) throws {
    let action = try #require(control.action)
    #expect(control.sendAction(action, to: control.target))
}
