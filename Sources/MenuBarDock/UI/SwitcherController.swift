import AppKit
import Combine
import DockDomain
import DockPlatform

@MainActor
final class SwitcherController: NSObject, NSWindowDelegate, NSSearchFieldDelegate {
    private let model: DockPresentationModel
    private var session: SwitcherSession?
    private var panel: SwitcherPanel?
    private var subscription: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var selectedButtons: [AppID: NSButton] = [:]
    private var capturedScreenFrame: NSRect?
    private let search: any SpotlightSearching
    private var searchSession = SearchSession()
    private var searchTask: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0
    private var isSearching = false
    private var searchError: String?
    private var content: SwitcherContentView?
    private var searchField: NSSearchField?
    private var dockView: NSView?
    private var resultsView: SwitcherSearchResultsView?

    private var hasQuery: Bool { !searchSession.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var isVisible: Bool { panel?.isVisible == true }

    init(model: DockPresentationModel, search: any SpotlightSearching = SpotlightSearchService()) {
        self.model = model
        self.search = search
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
        panel.makeFirstResponder(searchField)
        announceSelection()
    }

    func advance(direction: Int) {
        guard isVisible else { show(direction: direction, currentID: nil); return }
        if hasQuery { searchSession.move(direction) }
        else { session?.move(direction) }
        render()
        announceSelection()
    }

    func close() {
        let closingPanel = panel
        let hadSession = session != nil
        panel = nil
        searchGeneration &+= 1
        searchTask?.cancel()
        searchTask = nil
        search.cancel()
        searchSession.reset()
        content = nil
        searchField = nil
        dockView = nil
        resultsView = nil
        isSearching = false
        searchError = nil
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
        panel.isGlobalShortcut = { [weak model] in model?.isGlobalShortcut($0) == true }
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        let content = SwitcherContentView()
        content.handleKey = { [weak self] event in self?.handleKey(event) }
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .followsWindowActiveState
        content.wantsLayer = true
        content.layer?.cornerRadius = 18
        content.layer?.masksToBounds = true
        self.content = content
        panel.contentView = content

        let field = NSSearchField()
        field.placeholderString = "앱 검색"
        field.font = .systemFont(ofSize: 15)
        field.focusRingType = .none
        field.delegate = self
        field.setAccessibilityLabel("앱 검색")
        // 입력창과 field editor는 이동·검색 결과 갱신 중 교체하지 않는다.
        content.addSubview(field)
        searchField = field
        let dock = NSView()
        content.addSubview(dock)
        dockView = dock
        let results = SwitcherSearchResultsView()
        results.openResult = { [weak self] result in self?.openSearchResult(result) }
        content.addSubview(results)
        resultsView = results
        return panel
    }

    private func render() {
        guard let panel, let session, let content, let searchField, let dockView, let resultsView else { return }
        let width = min(max(420, CGFloat(session.ids.count) * 64 + 32), min(capturedScreenFrame?.width ?? 760, 620) - 32)
        let bodyHeight: CGFloat = hasQuery ? max(60, CGFloat(min(6, searchSession.results.count)) * 46 + 8) : 116
        let height = bodyHeight + 44
        let oldFrame = panel.frame
        panel.setFrame(NSRect(x: oldFrame.midX - width / 2, y: oldFrame.maxY - height, width: width, height: height), display: true)
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        searchField.frame = NSRect(x: 16, y: height - 38, width: width - 32, height: 26)
        dockView.frame = NSRect(x: 0, y: 0, width: width, height: bodyHeight)
        resultsView.frame = NSRect(x: 8, y: 6, width: width - 16, height: bodyHeight - 6)
        dockView.isHidden = hasQuery
        resultsView.isHidden = !hasQuery
        // 재질과 그림자에도 같은 마스크를 적용하여 모서리에 사각 배경이 남지 않게 한다.
        content.maskImage = Self.roundedMaterialMask(size: content.bounds.size, radius: 18)
        if hasQuery {
            let message = searchError ?? (isSearching ? "검색 중…" : "검색 결과 없음")
            resultsView.update(results: searchSession.results, selectedID: searchSession.selectedID, message: message)
        } else { renderDock(in: dockView, width: width, session: session) }
        panel.invalidateShadow()
    }

    private func renderDock(in content: NSView, width: CGFloat, session: SwitcherSession) {
        content.subviews.forEach { $0.removeFromSuperview() }
        let itemMap = Dictionary(uniqueKeysWithValues: model.items.map { ($0.id, $0) })
        let items = session.ids.compactMap { itemMap[$0] }
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
    }

    /// NSVisualEffectView.maskImage는 재질과 윈도우 그림자에 함께 적용된다.
    static func roundedMaterialMask(size: NSSize, radius: CGFloat) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        updateSearch()
    }

    private func updateSearch() {
        guard let field = searchField else { return }
        let query = field.stringValue
        searchGeneration &+= 1
        let generation = searchGeneration
        searchTask?.cancel()
        search.cancel()
        searchSession.updateQuery(query)
        searchSession.receive([], for: query)
        searchError = nil
        isSearching = hasQuery
        render()
        // 조합 중인 한글은 AppKit이 확정할 때까지 검색·실행하지 않는다.
        guard hasQuery, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
            guard let self, self.isVisible, self.searchGeneration == generation else { return }
            self.search.search(query) { [weak self] update in
                guard let self, self.isVisible, self.searchGeneration == generation else { return }
                self.searchSession.receive(update.results, for: query)
                self.isSearching = !update.isComplete
                self.searchError = update.errorMessage
                self.render()
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch NSStringFromSelector(commandSelector) {
        case "moveUp:": advance(direction: -1)
        case "moveDown:": advance(direction: 1)
        case "moveLeft:" where !hasQuery: advance(direction: -1)
        case "moveRight:" where !hasQuery: advance(direction: 1)
        case "insertTab:", "insertBacktab:":
            // 전역 경로에서 처리한 조합은 field editor에서 중복 이동하지 않는다.
            if NSApp.currentEvent.map(model.isGlobalShortcut) != true {
                advance(direction: NSStringFromSelector(commandSelector) == "insertBacktab:" ? -1 : 1)
            }
        case "insertNewline:": confirmSelection()
        case "cancelOperation:": cancelSearchOrClose()
        default: return false
        }
        return true
    }

    private func cancelSearchOrClose() {
        if hasQuery {
            searchField?.stringValue = ""
            updateSearch()
        } else { close() }
    }

    private func handleKey(_ event: NSEvent) {
        if model.isGlobalShortcut(event) { return }
        switch event.keyCode {
        case 123, 126: advance(direction: -1)
        case 124, 125: advance(direction: 1)
        case 48: advance(direction: event.modifierFlags.contains(.shift) ? -1 : 1)
        case 36, 76: confirmSelection()
        case 53: cancelSearchOrClose()
        default: break
        }
    }

    private func confirmSelection() {
        guard (searchField?.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if hasQuery {
            guard let result = searchSession.selectedResult else { return }
            openSearchResult(result)
        } else {
            guard let id = session?.selectedID else { return }
            close()
            model.perform(.open(id))
        }
    }

    private func openSearchResult(_ result: SearchResult) {
        close()
        model.perform(.openSearchResult(result))
    }

    private func announceSelection() {
        guard !hasQuery, let id = session?.selectedID, let button = selectedButtons[id] else { return }
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
    var isGlobalShortcut: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        // 검색창에 공백이 입력되거나 선택이 두 번 이동하지 않도록 창 경계에서 소비한다.
        if event.type == .keyDown, isGlobalShortcut?(event) == true { return }
        super.sendEvent(event)
    }
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
