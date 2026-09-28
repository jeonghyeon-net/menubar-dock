import AppKit
import DockDomain
import Testing
@testable import MenuBarDock

extension NativeUIBehaviorTests {
    @Test("상태 메뉴는 임시 앱을 목록에 추가하고 등록 앱은 제거하는 명령만 제공한다", arguments: [false, true])
    func statusMenuMatchesSavedListMembership(_ saved: Bool) throws {
        _ = NSApplication.shared
        let entry = AppEntry(id: AppID(rawValue: "menu-app"), name: "메뉴 앱", bundlePath: "/fixture/menu.app", isPinned: saved)
        var actions: [DockUIAction] = []
        let model = DockPresentationModel(imageForApp: { _ in NSImage(size: NSSize(width: 24, height: 24)) }) {
            actions.append($0)
        }
        model.items = [DockItem(app: entry, isRunning: true)]
        var statusItem: NSStatusItem?
        var menu: NSMenu?
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0
        ))
        let controller = StatusItemController(model: model, makeStatusItem: { length in
            let item = NSStatusBar.system.statusItem(withLength: length)
            statusItem = item
            return item
        }, currentEvent: { event }, menuPresenter: { presented, _ in menu = presented })
        defer { controller.tearDown() }
        let button = try #require(statusItem?.button)
        let buttonAction = try #require(button.action)
        #expect(button.sendAction(buttonAction, to: button.target))
        let presented = try #require(menu)
        #expect(presented.item(withTitle: "고정") == nil)
        #expect(presented.item(withTitle: "목록에서 숨기기") == nil)
        let command = try #require(presented.item(withTitle: saved ? "목록에서 제거" : "목록에 추가"))
        let commandAction = try #require(command.action)
        #expect(command.state == .off)
        #expect(NSApp.sendAction(commandAction, to: command.target, from: command))
        #expect(actions.count == 1)
        if saved {
            #expect(actions.contains { if case .remove(entry.id) = $0 { true } else { false } })
        } else {
            #expect(actions.contains { if case .save(entry.id) = $0 { true } else { false } })
        }

        model.isReadOnly = true
        #expect(button.sendAction(buttonAction, to: button.target))
        let disabled = try #require(menu?.item(withTitle: command.title))
        #expect(!disabled.isEnabled)
    }
}
