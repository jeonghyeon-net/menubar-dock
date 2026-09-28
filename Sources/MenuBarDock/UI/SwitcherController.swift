import AppKit
import Combine
import DockDomain

@MainActor
final class SwitcherController: NSObject, NSWindowDelegate {
    private let model: DockPresentationModel
    private var session: SwitcherSession?
    private var panel: SwitcherPanel?
    private var subscription: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var selectedButtons: [AppID: NSButton] = [:]
    private var capturedScreenFrame: NSRect?

    var isVisible: Bool { panel?.isVisible == true }

    init(model: DockPresentationModel) {
        self.model = model
        super.init()
        subscription = model.$items.sink { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isVisible else { return }
                // 이전 알림의 payload가 새로 열린 세션을 비우지 않도록 현재 투영을 사용한다.
                self.session?.reconcile(validIDs: Set(self.model.items.map(\.id)))
                self.render()
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.close() } }
    }

    func show(direction: Int, currentID: AppID?) {
        if isVisible { advance(direction: direction); return }
        session = SwitcherSession(ids: model.items.map(\.id), currentID: currentID, direction: direction)
        let mouseLocation = NSEvent.mouseLocation
        capturedScreenFrame = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        let panel = makePanel()
        self.panel = panel
        render()
        if let frame = capturedScreenFrame {
            let origin = NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2)
            panel.setFrameOrigin(origin)
        } else { panel.center() }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
        announceSelection()
    }

    func advance(direction: Int) {
        guard isVisible else { show(direction: direction, currentID: nil); return }
        session?.move(direction)
        render()
        announceSelection()
    }

    func close() {
        let closingPanel = panel
        let hadSession = session != nil
        panel = nil
        session = nil
        selectedButtons.removeAll()
        capturedScreenFrame = nil
        if hadSession { model.perform(.cancelShortcutPress) }
        closingPanel?.orderOut(nil)
    }

    func tearDown() {
        close()
        subscription = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    private func makePanel() -> SwitcherPanel {
        let panel = SwitcherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 116),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.title = "앱 선택"
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        return panel
    }

    private func render() {
        guard let panel, let session else { return }
        let itemMap = Dictionary(uniqueKeysWithValues: model.items.map { ($0.id, $0) })
        let items = session.ids.compactMap { itemMap[$0] }
        let width = min(max(220, CGFloat(items.count) * 64 + 32), min(capturedScreenFrame?.width ?? 760, 760) - 32)
        panel.setContentSize(NSSize(width: width, height: 116))
        let content = SwitcherContentView(frame: NSRect(x: 0, y: 0, width: width, height: 116))
        content.handleKey = { [weak self] event in self?.handleKey(event) }
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .followsWindowActiveState
        content.wantsLayer = true
        content.layer?.cornerRadius = 18
        content.layer?.masksToBounds = true
        // layer의 모서리만 자르면 behindWindow 재질은 사각형으로 남는다.
        // AppKit의 material/shadow 마스크에도 같은 윤곽을 전달한다.
        content.maskImage = Self.roundedMaterialMask(size: content.bounds.size, radius: 18)
        content.setAccessibilityLabel("앱 선택. 방향키로 이동하고 Enter로 열기, Escape로 취소")
        panel.contentView = content

        let selectedName = items.first(where: { $0.id == session.selectedID })?.app.name
        let title = NSTextField(labelWithString: selectedName ?? "표시할 앱이 없습니다")
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.alignment = .center
        title.frame = NSRect(x: 40, y: 10, width: width - 80, height: 18)
        title.lineBreakMode = .byTruncatingTail
        content.addSubview(title)

        selectedButtons.removeAll()
        if items.isEmpty {
            let add = NSButton(title: "앱 추가…", target: self, action: #selector(addApps))
            add.bezelStyle = .rounded
            add.frame = NSRect(x: (width - 100) / 2, y: 45, width: 100, height: 28)
            content.addSubview(add)
        } else {
            let scroll = NSScrollView(frame: NSRect(x: 16, y: 34, width: width - 32, height: 68))
            scroll.drawsBackground = false
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            let document = NSView(frame: NSRect(x: 0, y: 0, width: max(scroll.bounds.width, CGFloat(items.count) * 64), height: 64))
            let horizontalInset = max(0, (document.bounds.width - CGFloat(items.count) * 64) / 2)
            var selectedRect: NSRect?
            for (index, item) in items.enumerated() {
                let tileRect = NSRect(x: horizontalInset + CGFloat(index) * 64, y: 0, width: 60, height: 64)
                let tile = NSView(frame: tileRect)
                tile.wantsLayer = true
                tile.layer?.cornerRadius = 12
                if item.id == session.selectedID {
                    tile.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).cgColor
                    selectedRect = tileRect
                }
                let button = NSButton(image: model.imageForApp(item.app), target: self, action: #selector(clickApp(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(item.id.rawValue)
                button.isBordered = false
                button.imageScaling = .scaleProportionallyUpOrDown
                // 타일 전체가 클릭 영역이다. 아이콘 밖의 여백도 같은 앱을 선택한다.
                button.frame = tile.bounds
                button.image = model.imageForApp(item.app).copy() as? NSImage
                button.image?.size = NSSize(width: 44, height: 44)
                button.imageScaling = .scaleNone
                button.setAccessibilityLabel("\(item.app.name) 열기")
                button.setAccessibilityValue(item.id == session.selectedID ? "선택됨" : "")
                button.toolTip = item.app.name
                selectedButtons[item.id] = button
                tile.addSubview(button)
                document.addSubview(tile)
            }
            scroll.documentView = document
            content.addSubview(scroll)
            if let selectedRect { document.scrollToVisible(selectedRect) }
        }
        // 메뉴 막대에는 앱 아이콘만 둔다. 관리는 선택 패널의 작은 설정 버튼으로 연다.
        let settings = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "설정") ?? NSImage(),
                                target: self, action: #selector(openSettings))
        settings.isBordered = false
        settings.contentTintColor = .secondaryLabelColor
        settings.toolTip = "설정"
        settings.setAccessibilityLabel("설정")
        settings.frame = NSRect(x: width - 34, y: 8, width: 22, height: 22)
        content.addSubview(settings)
        panel.invalidateShadow()
        if panel.isKeyWindow { panel.makeFirstResponder(content) }
    }

    /// NSVisualEffectView.maskImage는 재질과 윈도우 그림자에 함께 적용된다.
    static func roundedMaterialMask(size: NSSize, radius: CGFloat) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
    }

    private func handleKey(_ event: NSEvent) {
        // Option+Tab은 전역 단축키 경로만 처리해 같은 입력이 두 번 이동하지 않게 한다.
        if event.keyCode == 48 && event.modifierFlags.contains(.option) { return }
        switch event.keyCode {
        case 123, 126: advance(direction: -1)
        case 124, 125: advance(direction: 1)
        case 48: advance(direction: event.modifierFlags.contains(.shift) ? -1 : 1)
        case 36, 76: confirmSelection()
        case 53: close()
        default: break
        }
    }

    private func confirmSelection() {
        guard let id = session?.selectedID else { return }
        close()
        model.perform(.open(id))
    }

    private func announceSelection() {
        guard let id = session?.selectedID, let button = selectedButtons[id] else { return }
        NSAccessibility.post(element: button, notification: .focusedUIElementChanged)
    }

    @objc private func clickApp(_ sender: NSButton) {
        guard let identifier = sender.identifier else { return }
        let id = AppID(rawValue: identifier.rawValue)
        close()
        model.perform(.open(id))
    }

    @objc private func addApps() { close(); model.perform(.addApps) }
    @objc private func openSettings() { close(); model.perform(.settings) }
}

@MainActor
private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class SwitcherContentView: NSVisualEffectView {
    var handleKey: ((NSEvent) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { handleKey?(event) }
    override func cancelOperation(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        handleKey?(event)
    }
}
