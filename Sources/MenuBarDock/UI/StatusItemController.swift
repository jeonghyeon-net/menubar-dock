import AppKit
import Combine
import DockDomain

/// 앱마다 독립된 시스템 상태 항목을 만든다. 슬롯은 위치를, 도메인 목록은 앱 순서를 소유한다.
@MainActor
final class StatusItemController: NSObject {
    private final class Slot {
        // 삭제 뒤 다른 번호가 남을 수 있다. 배열 위치가 아닌 재사용 가능한 고유 번호다.
        let number: Int
        let item: NSStatusItem
        var appID: AppID?

        init(number: Int, item: NSStatusItem) {
            self.number = number
            self.item = item
        }
    }

    private struct RenderState: Equatable {
        let items: [DockItem]
        let preferences: DockPreferences
        let slotOrder: [Int]
        let buttonSizes: [NSSize]
    }

    private let model: DockPresentationModel
    private let makeStatusItem: (CGFloat) -> NSStatusItem
    private let removeStatusItem: (NSStatusItem) -> Void
    private let currentEvent: () -> NSEvent?
    private let presentMenu: (NSMenu, NSStatusBarButton) -> Void
    private let frameForStatusItem: (NSStatusItem) -> NSRect?
    private var slots: [Slot] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var observations: [NSObjectProtocol] = []
    private var renderedState: RenderState?
    private var isTornDown = false
    private(set) var renderCount = 0

    init(
        model: DockPresentationModel,
        makeStatusItem: ((CGFloat) -> NSStatusItem)? = nil,
        removeStatusItem: ((NSStatusItem) -> Void)? = nil,
        currentEvent: (() -> NSEvent?)? = nil,
        menuPresenter: ((NSMenu, NSStatusBarButton) -> Void)? = nil,
        frameForStatusItem: ((NSStatusItem) -> NSRect?)? = nil
    ) {
        self.model = model
        self.makeStatusItem = makeStatusItem ?? { NSStatusBar.system.statusItem(withLength: $0) }
        self.removeStatusItem = removeStatusItem ?? { NSStatusBar.system.removeStatusItem($0) }
        self.currentEvent = currentEvent ?? { NSApp.currentEvent }
        self.frameForStatusItem = frameForStatusItem ?? Self.visibleFrame
        self.presentMenu = menuPresenter ?? { menu, button in
            button.highlight(true)
            defer { button.highlight(false) }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        }
        super.init()
        model.$items.combineLatest(model.$preferences).sink { [weak self] _, _ in
            // Published는 값 변경 전에 알리므로 다음 실행 구간에서 최신 투영을 읽는다.
            Task { @MainActor in self?.update() }
        }.store(in: &subscriptions)
        for name in [NSApplication.didChangeScreenParametersNotification, NSWindow.didMoveNotification,
                     NSWindow.didResizeNotification, NSWindow.didChangeBackingPropertiesNotification,
                     NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                // 실제 상태 항목 이동·크기만 사용하고 다른 창이나 뷰 이벤트는 무시한다.
                let source = (notification.object as? NSObject).map(ObjectIdentifier.init)
                Task { @MainActor in
                    guard let self else { return }
                    if name != NSApplication.didChangeScreenParametersNotification,
                       !self.slots.contains(where: {
                           $0.item.button.map(ObjectIdentifier.init) == source || $0.item.button?.window.map(ObjectIdentifier.init) == source
                       }) { return }
                    self.update()
                }
            })
        }
        update()
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        subscriptions.removeAll()
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
        slots.forEach { removeStatusItem($0.item) }
        slots.removeAll()
    }

    func update() {
        guard !isTornDown else { return }
        let preferences = model.preferences
        let iconSize = CGFloat(preferences.iconSize)
        let slotWidth = max(CGFloat(preferences.slotWidth), iconSize)
        let visible = Array(model.items.prefix(preferences.maxVisibleApps))
        resizeSlots(for: visible, width: slotWidth)
        for slot in slots where slot.item.length != slotWidth {
            slot.item.length = slotWidth
        }
        let ordered = orderedSlots()
        let sizes = ordered.map { $0.item.button?.bounds.size ?? .zero }
        let state = RenderState(items: visible, preferences: preferences, slotOrder: ordered.map(\.number), buttonSizes: sizes)
        // 시스템 외관 변경은 표준 버튼이 처리한다. 동일한 앱/순서의 이미지를 반복 교체하지 않는다.
        guard renderedState != state else { return }
        renderedState = state
        renderCount += 1
        for (slot, entry) in zip(ordered, visible) {
            slot.appID = entry.id
            guard let button = slot.item.button else { continue }
            // 표준 버튼은 이미지 크기에 맞춰 높이를 정한다. 이전 높이로 제한하면 큰 값으로 변경할 수 없다.
            let image = model.imageForApp(entry.app).copy() as? NSImage
            image?.size = NSSize(width: iconSize, height: iconSize)
            button.image = image
            button.toolTip = entry.app.name
            button.setAccessibilityLabel(entry.app.name)
            button.setAccessibilityHelp("앱 열기. 우클릭 또는 Control 클릭으로 설정")
        }
    }

    private func resizeSlots(for visible: [DockItem], width: CGFloat) {
        let count = visible.count
        if count < slots.count {
            let retainedIDs = Set(visible.map(\.id))
            let ordered = orderedSlots().reversed()
            let obsolete = ordered.filter { $0.appID.map { !retainedIDs.contains($0) } ?? true }
            let retained = ordered.filter { $0.appID.map { retainedIDs.contains($0) } ?? false }
            let removed = Array((obsolete + retained).prefix(slots.count - count))
            let numbers = Set(removed.map(\.number))
            // 지워질 앱의 슬롯을 직접 제거해 다른 앱의 창이 먼저 사라지는 재배치를 피한다.
            slots.removeAll { numbers.contains($0.number) }
            for slot in removed { removeStatusItem(slot.item) }
        }
        guard count > slots.count else { return }
        let usedNumbers = Set(slots.map(\.number))
        let available = (0..<count).filter { !usedNumbers.contains($0) }.prefix(count - slots.count)
        // 새 상태 항목은 왼쪽에 추가된다. 최초 생성 때 0번 슬롯이 왼쪽이 되도록 역순 생성한다.
        for number in available.reversed() {
            let item = makeStatusItem(width)
            item.autosaveName = "MenuBarDock.AppSlot.\(number)"
            item.behavior = []
            item.menu = nil
            if let button = item.button {
                button.target = self
                button.action = #selector(activate(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                button.imagePosition = .imageOnly
                button.imageScaling = .scaleProportionallyDown
                button.postsFrameChangedNotifications = true
                button.postsBoundsChangedNotifications = true
            }
            slots.insert(Slot(number: number, item: item), at: 0)
        }
    }

    private func orderedSlots() -> [Slot] {
        // 재배치 중 좌표가 비면 번호순으로 되돌리지 않고 마지막 유효 좌우 순서를 유지한다.
        let fallback = slots
        let positioned = fallback.compactMap { slot -> (Slot, NSRect)? in
            frameForStatusItem(slot.item).map { (slot, $0) }
        }
        // 초기 배치·숨겨진 메뉴 막대·노치에 가려진 항목은 유효 좌표가 없을 수 있다.
        // 모두 같은 메뉴 막대에 있을 때만 실제 좌우 위치를 사용한다.
        guard positioned.count == slots.count,
              let first = positioned.first?.1,
              positioned.allSatisfy({ abs($0.1.midY - first.midY) < 1 }),
              Set(positioned.map { $0.1.minX }).count == positioned.count else { return fallback }
        slots = positioned.sorted { $0.1.minX < $1.1.minX }.map(\.0)
        return slots
    }

    private static func visibleFrame(_ item: NSStatusItem) -> NSRect? {
        guard let window = item.button?.window, window.isVisible,
              window.frame.width > 0, window.frame.height > 0, let screen = window.screen,
              screen.frame.contains(NSPoint(x: window.frame.midX, y: window.frame.midY)) else { return nil }
        return window.frame
    }

    @objc private func activate(_ sender: NSStatusBarButton) {
        guard !isTornDown, let id = slots.first(where: { $0.item.button === sender })?.appID else { return }
        if let event = currentEvent(),
           event.type == .rightMouseUp || (event.type == .leftMouseUp && event.modifierFlags.contains(.control)) {
            showMenu(for: id, anchor: sender)
            return
        }
        model.perform(.open(id))
    }

    private func showMenu(for id: AppID, anchor: NSStatusBarButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let app = model.items.first(where: { $0.id == id })?.app {
            if app.isPinned {
                append("목록에서 제거", action: .remove(id), to: menu, enabled: !model.isReadOnly)
            } else {
                append("목록에 추가", action: .save(id), to: menu, enabled: !model.isReadOnly)
            }
        }
        append("설정", action: .settings, to: menu)
        append("종료", action: .quit, to: menu)
        presentMenu(menu, anchor)
    }

    @discardableResult
    private func append(_ title: String, action: DockUIAction, to menu: NSMenu, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard !isTornDown, sender.isEnabled, let action = sender.representedObject as? DockUIAction else { return }
        model.perform(action)
    }
}
