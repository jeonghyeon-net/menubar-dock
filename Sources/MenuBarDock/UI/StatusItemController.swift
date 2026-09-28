import AppKit
import Combine
import DockDomain

/// 앱마다 독립된 시스템 상태 항목을 만든다. 슬롯은 위치를, 도메인 목록은 앱 순서를 소유한다.
@MainActor
final class StatusItemController: NSObject {
    private final class Slot {
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
        let height: CGFloat
    }

    private let model: DockPresentationModel
    private let makeStatusItem: (CGFloat) -> NSStatusItem
    private let removeStatusItem: (NSStatusItem) -> Void
    private var slots: [Slot] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var observations: [NSObjectProtocol] = []
    private var renderedState: RenderState?
    private var isTornDown = false
    private(set) var renderCount = 0

    init(
        model: DockPresentationModel,
        makeStatusItem: ((CGFloat) -> NSStatusItem)? = nil,
        removeStatusItem: ((NSStatusItem) -> Void)? = nil
    ) {
        self.model = model
        self.makeStatusItem = makeStatusItem ?? { NSStatusBar.system.statusItem(withLength: $0) }
        self.removeStatusItem = removeStatusItem ?? { NSStatusBar.system.removeStatusItem($0) }
        super.init()
        model.$items.combineLatest(model.$preferences).sink { [weak self] _, _ in
            // Published는 값 변경 전에 알리므로 다음 실행 구간에서 최신 투영을 읽는다.
            Task { @MainActor in self?.update() }
        }.store(in: &subscriptions)
        for name in [NSApplication.didChangeScreenParametersNotification, NSWindow.didMoveNotification, NSWindow.didChangeBackingPropertiesNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                // 실제 상태 항목 이동만 순서 재계산에 사용한다. 다른 앱 창 이벤트는 무시한다.
                let movedWindow = (notification.object as? NSWindow).map(ObjectIdentifier.init)
                Task { @MainActor in
                    guard let self else { return }
                    if name != NSApplication.didChangeScreenParametersNotification,
                       !self.slots.contains(where: { $0.item.button?.window.map(ObjectIdentifier.init) == movedWindow }) { return }
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
        let visible = Array(model.items.prefix(preferences.maxVisibleApps))
        resizeSlots(to: visible.count)
        let ordered = orderedSlots()
        let state = RenderState(items: visible, preferences: preferences, slotOrder: ordered.map(\.number), height: NSStatusBar.system.thickness)
        // 시스템 외관 변경은 표준 버튼이 처리한다. 동일한 앱/순서의 이미지를 반복 교체하지 않는다.
        guard renderedState != state else { return }
        renderedState = state
        renderCount += 1
        let iconSize = CGFloat(preferences.iconSize)
        for (slot, entry) in zip(ordered, visible) {
            slot.appID = entry.id
            slot.item.length = CGFloat(preferences.slotWidth)
            guard let button = slot.item.button else { continue }
            let image = model.imageForApp(entry.app).copy() as? NSImage
            image?.size = NSSize(width: iconSize, height: iconSize)
            button.image = image
            button.toolTip = entry.app.name
            button.setAccessibilityLabel(entry.app.name)
            button.setAccessibilityHelp("앱 열기")
        }
    }

    private func resizeSlots(to count: Int) {
        if count < slots.count {
            for slot in slots.filter({ $0.number >= count }) {
                removeStatusItem(slot.item)
            }
            slots.removeAll { $0.number >= count }
        }
        guard count > slots.count else { return }
        // 새 상태 항목은 왼쪽에 추가된다. 최초 생성 때 0번 슬롯이 왼쪽이 되도록 역순 생성한다.
        for number in (slots.count..<count).reversed() {
            let item = makeStatusItem(CGFloat(model.preferences.slotWidth))
            item.autosaveName = "MenuBarDock.AppSlot.\(number)"
            item.behavior = []
            item.menu = nil
            if let button = item.button {
                button.target = self
                button.action = #selector(activate(_:))
                button.sendAction(on: .leftMouseUp)
                button.imagePosition = .imageOnly
                button.imageScaling = .scaleNone
            }
            slots.append(Slot(number: number, item: item))
        }
    }

    private func orderedSlots() -> [Slot] {
        let fallback = slots.sorted { $0.number < $1.number }
        let positioned = fallback.compactMap { slot -> (Slot, NSRect)? in
            guard let window = slot.item.button?.window, window.isVisible,
                  window.frame.width > 0, window.frame.height > 0,
                  let screen = window.screen,
                  screen.frame.contains(NSPoint(x: window.frame.midX, y: window.frame.midY)) else { return nil }
            return (slot, window.frame)
        }
        // 초기 배치·숨겨진 메뉴 막대·노치에 가려진 항목은 유효 좌표가 없을 수 있다.
        // 모두 같은 메뉴 막대에 있을 때만 실제 좌우 위치를 사용한다.
        guard positioned.count == slots.count,
              let first = positioned.first?.1,
              positioned.allSatisfy({ abs($0.1.midY - first.midY) < 1 }),
              Set(positioned.map { $0.1.minX }).count == positioned.count else { return fallback }
        return positioned.sorted { $0.1.minX < $1.1.minX }.map(\.0)
    }

    @objc private func activate(_ sender: NSStatusBarButton) {
        guard !isTornDown, let id = slots.first(where: { $0.item.button === sender })?.appID else { return }
        model.perform(.open(id))
    }
}
