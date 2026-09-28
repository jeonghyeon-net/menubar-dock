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
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 228),
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
        let width = min(max(360, CGFloat(items.count) * 88 + 40), min(capturedScreenFrame?.width ?? 760, 760) - 32)
        panel.setContentSize(NSSize(width: width, height: 228))
        let content = SwitcherContentView(frame: NSRect(x: 0, y: 0, width: width, height: 228))
        content.handleKey = { [weak self] event in self?.handleKey(event) }
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .followsWindowActiveState
        content.wantsLayer = true
        content.layer?.cornerRadius = 18
        content.layer?.masksToBounds = true
        content.setAccessibilityLabel("앱 선택. 방향키로 이동하고 Enter로 열기, Escape로 취소")
        panel.contentView = content

        let selectedName = items.first(where: { $0.id == session.selectedID })?.app.name
        let title = NSTextField(labelWithString: selectedName ?? "표시할 앱이 없습니다")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 20, y: 181, width: width - 40, height: 26)
        title.lineBreakMode = .byTruncatingTail
        content.addSubview(title)

        selectedButtons.removeAll()
        if items.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "설정에서 앱을 추가하거나 실행 중인 앱 표시를 켜세요.")
            empty.alignment = .center
            empty.textColor = .secondaryLabelColor
            empty.frame = NSRect(x: 30, y: 95, width: width - 60, height: 48)
            content.addSubview(empty)
        } else {
            let scroll = NSScrollView(frame: NSRect(x: 16, y: 58, width: width - 32, height: 112))
            scroll.drawsBackground = false
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            let document = NSView(frame: NSRect(x: 0, y: 0, width: max(scroll.bounds.width, CGFloat(items.count) * 88), height: 96))
            let horizontalInset = max(0, (document.bounds.width - CGFloat(items.count) * 88) / 2)
            var selectedRect: NSRect?
            for (index, item) in items.enumerated() {
                let tileRect = NSRect(x: horizontalInset + CGFloat(index) * 88, y: 0, width: 84, height: 96)
                let tile = NSView(frame: tileRect)
                tile.wantsLayer = true
                tile.layer?.cornerRadius = 12
                if item.id == session.selectedID {
                    tile.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.20).cgColor
                    tile.layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
                    tile.layer?.borderWidth = 2
                    selectedRect = tileRect
                }
                let button = NSButton(image: model.imageForApp(item.app), target: self, action: #selector(clickApp(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(item.id.rawValue)
                button.isBordered = false
                button.imageScaling = .scaleProportionallyUpOrDown
                button.frame = NSRect(x: 14, y: 27, width: 56, height: 56)
                button.setAccessibilityLabel("\(item.app.name) 열기")
                button.setAccessibilityValue(item.id == session.selectedID ? "선택됨" : "")
                button.toolTip = item.app.name
                selectedButtons[item.id] = button
                tile.addSubview(button)
                let label = NSTextField(labelWithString: item.app.name)
                label.font = .systemFont(ofSize: 11)
                label.alignment = .center
                label.lineBreakMode = .byTruncatingTail
                label.frame = NSRect(x: 4, y: 6, width: 76, height: 16)
                tile.addSubview(label)
                document.addSubview(tile)
            }
            scroll.documentView = document
            content.addSubview(scroll)
            if let selectedRect { document.scrollToVisible(selectedRect) }
        }
        let footer = NSTextField(labelWithString: "← → 이동    ↵ 열기    esc 취소")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.frame = NSRect(x: 22, y: 20, width: width - 102, height: 18)
        content.addSubview(footer)
        let settings = NSButton(title: "설정…", target: self, action: #selector(openSettings))
        settings.bezelStyle = .rounded
        settings.frame = NSRect(x: width - 83, y: 14, width: 68, height: 28)
        content.addSubview(settings)
        if panel.isKeyWindow { panel.makeFirstResponder(content) }
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
