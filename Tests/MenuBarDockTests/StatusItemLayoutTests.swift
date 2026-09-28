import AppKit
import DockDomain
import Testing
@testable import MenuBarDock

// AppKit 창을 쓰는 기존 직렬 suite와 함께 실행해 다른 패널의 포커스를 빼앗지 않는다.
extension NativeUIBehaviorTests {
    @Test("첫·중간·끝 앱 제거 시 해당 시스템 슬롯만 없애고 남은 앱의 연결을 유지한다")
    func removingAnAppKeepsSurvivingSlotsBoundToTheirApps() throws {
        for index in 0..<3 {
            let fixture = StatusLayoutFixture()
            defer { fixture.controller.tearDown() }
            let target = try #require(fixture.active.first { $0.button?.accessibilityLabel() == fixture.entries[index].name })
            let previous = fixture.bindings
            fixture.model.items.remove(at: index)
            fixture.controller.update()
            #expect(fixture.removed.count == 1)
            #expect(fixture.removed.first === target)
            for item in fixture.active {
                #expect(previous[ObjectIdentifier(item)] == item.button?.accessibilityLabel())
            }
            try fixture.checkActions()
        }
    }

    @Test("번호와 실제 위치가 달라도 일시 좌표 누락·중복·다른 높이에서 순서를 되돌리지 않는다")
    func invalidFramesPreserveLastKnownPhysicalOrder() throws {
        let fixture = StatusLayoutFixture(positions: [0: 80, 1: 120, 2: 40])
        defer { fixture.controller.tearDown() }
        let previous = fixture.bindings
        let original = fixture.positions
        fixture.positions = [:]
        fixture.controller.update()
        #expect(fixture.bindings == previous)
        fixture.positions = [0: 40, 1: 40, 2: 40]
        fixture.controller.update()
        #expect(fixture.bindings == previous)
        fixture.positions = original
        fixture.verticalOffset = 8
        fixture.controller.update()
        #expect(fixture.bindings == previous)
        fixture.verticalOffset = 0
        fixture.controller.update()
        #expect(fixture.bindings == previous)
        try fixture.checkActions()
    }

    @Test("슬롯 번호가 비어도 개수 증감·초과 항목·빈 목록에서 중복이나 빈 슬롯을 남기지 않는다")
    func resizingWithNumberGapsKeepsTheRequestedCountAndActions() throws {
        let fixture = StatusLayoutFixture()
        defer { fixture.controller.tearDown() }
        fixture.model.items.removeFirst()
        fixture.controller.update()
        #expect(fixture.active.count == 2)
        fixture.model.items.append(DockItem(app: fixture.entries[0], isRunning: false))
        fixture.controller.update()
        #expect(fixture.active.count == 3)
        #expect(Set(fixture.active.compactMap(\.autosaveName)).count == 3)
        try fixture.checkActions()
        fixture.model.preferences.maxVisibleApps = 1
        fixture.controller.update()
        #expect(fixture.active.count == 1)
        try fixture.checkActions()
        fixture.model.items = []
        fixture.controller.update()
        #expect(fixture.active.isEmpty)
        fixture.model.preferences.maxVisibleApps = 3
        fixture.model.items = fixture.entries.map { DockItem(app: $0, isRunning: false) }
        fixture.controller.update()
        #expect(fixture.active.count == 3)
        #expect(Set(fixture.active.compactMap(\.autosaveName)).count == 3)
        try fixture.checkActions()
    }
}

@MainActor
private final class StatusLayoutFixture {
    let entries = (0..<3).map { AppEntry(id: AppID(rawValue: "layout-\($0)"), name: "앱 \($0)", bundlePath: "/fixture/\($0).app") }
    var positions: [Int: CGFloat]
    var verticalOffset: CGFloat = 0
    var active: [NSStatusItem] = []
    var removed: [NSStatusItem] = []
    var opened: [AppID] = []
    let model: DockPresentationModel
    private(set) lazy var controller = makeController()

    init(positions: [Int: CGFloat] = [0: 40, 1: 80, 2: 120]) {
        _ = NSApplication.shared
        self.positions = positions
        model = DockPresentationModel(imageForApp: { _ in NSImage(size: NSSize(width: 24, height: 24)) }, perform: { _ in })
        model.perform = { [weak self] action in if case let .open(id) = action { self?.opened.append(id) } }
        model.items = entries.map { DockItem(app: $0, isRunning: false) }
        _ = controller
    }

    private func makeController() -> StatusItemController {
        StatusItemController(model: model, makeStatusItem: { [weak self] width in
            let item = NSStatusBar.system.statusItem(withLength: width)
            self?.active.append(item)
            return item
        }, removeStatusItem: { [weak self] item in
            self?.removed.append(item)
            self?.active.removeAll { $0 === item }
            NSStatusBar.system.removeStatusItem(item)
        }, currentEvent: { nil }, frameForStatusItem: { [weak self] item in
            guard let self, let name = item.autosaveName,
                  let number = Int(name.split(separator: ".").last ?? ""), let x = self.positions[number] else { return nil }
            return NSRect(x: x, y: 100 + (number == 0 ? self.verticalOffset : 0), width: 24, height: 24)
        })
    }

    var bindings: [ObjectIdentifier: String] {
        Dictionary(uniqueKeysWithValues: active.compactMap { item in
            item.button?.accessibilityLabel().map { (ObjectIdentifier(item), $0) }
        })
    }

    func checkActions() throws {
        opened = []
        for item in active {
            let button = try #require(item.button)
            let label = try #require(button.accessibilityLabel())
            let expected = try #require(entries.first { $0.name == label })
            let action = try #require(button.action)
            #expect(NSApp.sendAction(action, to: button.target, from: button))
            #expect(opened.last == expected.id)
        }
        #expect(Set(opened) == Set(model.items.prefix(model.preferences.maxVisibleApps).map(\.id)))
    }
}
