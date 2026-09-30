import AppKit
import Combine
import DockDomain
import DockShortcuts

@MainActor
final class SettingsWindowController: NSWindowController {
    private let model: DockPresentationModel
    private let noticeView = NSStackView()
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private var subscription: AnyCancellable?
    private let applications: ApplicationsSettingsPage
    private let appearance: AppearanceSettingsPage
    private let shortcuts: ShortcutSettingsPage

    init(model: DockPresentationModel) {
        self.model = model
        applications = ApplicationsSettingsPage(model: model)
        appearance = AppearanceSettingsPage(model: model)
        shortcuts = ShortcutSettingsPage(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.title = "Menu Bar Dock"
        window.contentMinSize = NSSize(width: 520, height: 600)
        window.setFrameAutosaveName("MenuBarDock.Settings.SingleWindow")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        subscription = model.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildContent() {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 10
        container.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        window?.contentView = container
        noticeView.orientation = .horizontal
        noticeView.alignment = .top
        noticeView.spacing = 8
        noticeLabel.font = .systemFont(ofSize: 12)
        noticeLabel.textColor = .systemOrange
        noticeLabel.isSelectable = true
        noticeLabel.maximumNumberOfLines = 3
        noticeView.addArrangedSubview(noticeLabel)
        noticeView.addArrangedSubview(toolbarButton("×", label: "알림 닫기") { [weak model] in model?.perform(.dismissNotice) })
        for view in [noticeView, applications, separator(), appearance, separator(), shortcuts, HelpSettingsPage(model: model)] {
            container.addArrangedSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -32).isActive = true
        }
        applications.heightAnchor.constraint(greaterThanOrEqualToConstant: 198).isActive = true
        applications.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    private func refresh() {
        noticeLabel.stringValue = model.notice ?? ""
        noticeLabel.toolTip = model.notice
        noticeView.isHidden = model.notice == nil
        applications.refresh()
        appearance.refresh()
        shortcuts.refresh()
    }

    private func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }
}

@MainActor
private final class ApplicationsSettingsPage: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private static let dragType = NSPasteboard.PasteboardType("net.jeonghyeon.MenuBarDock.app-id")
    private let model: DockPresentationModel
    private let table = NSTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let addButton: ActionButton
    private let removeButton: ActionButton
    private let upButton: ActionButton
    private let downButton: ActionButton
    private let moreButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var displayedApps: [AppEntry] = []
    private var displayedReadOnly = false

    init(model: DockPresentationModel) {
        self.model = model
        addButton = toolbarButton("+", label: "앱 추가") { [weak model] in model?.perform(.addApps) }
        removeButton = toolbarButton("−", label: "목록에서 제거", action: nil)
        upButton = toolbarButton("↑", label: "위로 이동", action: nil)
        downButton = toolbarButton("↓", label: "아래로 이동", action: nil)
        super.init(frame: .zero)
        removeButton.onAction = { [weak self] in self?.removeSelected() }
        upButton.onAction = { [weak self] in self?.moveSelection(-1) }
        downButton.onAction = { [weak self] in self?.moveSelection(1) }
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func buildContent() {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        install(content, in: self)
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.style = .plain
        table.rowHeight = 34
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.setAccessibilityLabel("항상 표시할 앱")
        table.toolTip = "드래그하거나 화살표 버튼으로 순서를 바꾸세요. 두 번 클릭하면 앱을 엽니다."
        let appColumn = NSTableColumn(identifier: .init("app"))
        appColumn.title = "항상 표시할 앱"
        appColumn.width = 480
        appColumn.minWidth = 220
        appColumn.resizingMask = .autoresizingMask
        table.addTableColumn(appColumn)
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        addFullWidth(scroll, to: content)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        addFullWidth(emptyLabel, to: content)
        moreButton.controlSize = .small
        moreButton.addItem(withTitle: "···")
        moreButton.setAccessibilityLabel("선택한 앱의 추가 작업")
        moreButton.toolTip = "선택한 앱의 추가 작업"
        for (title, action, tag) in [
            ("Finder에서 보기", #selector(revealSelected), 1),
            ("앱 위치 다시 지정…", #selector(replaceSelected), 2),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = tag
            moreButton.menu?.addItem(item)
        }
        moreButton.menu?.autoenablesItems = false
        let toolbar = horizontal([addButton, removeButton, NSView(), upButton, downButton, moreButton])
        toolbar.spacing = 4
        addFullWidth(toolbar, to: content)
    }

    func refresh() {
        let selection = selectedApp?.id
        let previousRow = table.selectedRow
        if displayedApps != model.apps || displayedReadOnly != model.isReadOnly {
            displayedApps = model.apps
            displayedReadOnly = model.isReadOnly
            table.reloadData()
            if let selection, let row = displayedApps.firstIndex(where: { $0.id == selection }) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else if previousRow >= 0, !displayedApps.isEmpty {
                table.selectRowIndexes(IndexSet(integer: min(previousRow, displayedApps.count - 1)), byExtendingSelection: false)
            } else if displayedApps.isEmpty {
                table.deselectAll(nil)
            }
        }
        addButton.isEnabled = !model.isReadOnly
        emptyLabel.stringValue = model.isReadOnly
            ? "더 새로운 버전의 설정입니다. 이 버전에서는 읽기만 가능합니다."
            : displayedApps.isEmpty ? "+ 버튼으로 앱을 추가하세요." : ""
        emptyLabel.isHidden = emptyLabel.stringValue.isEmpty
        updateSelectionControls()
    }

    private var selectedApp: AppEntry? {
        displayedApps.indices.contains(table.selectedRow) ? displayedApps[table.selectedRow] : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { displayedApps.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard displayedApps.indices.contains(row), column?.identifier.rawValue == "app" else { return nil }
        let app = displayedApps[row]
        let cell = NSView()
        let image = NSImageView(image: model.imageForApp(app))
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        image.setAccessibilityElement(false)
        let name = label(app.name, font: .systemFont(ofSize: 13))
        name.lineBreakMode = .byTruncatingTail
        name.maximumNumberOfLines = 1
        name.translatesAutoresizingMaskIntoConstraints = false
        cell.toolTip = app.bundlePath
        name.toolTip = app.bundlePath
        cell.addSubview(image)
        cell.addSubview(name)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 20), image.heightAnchor.constraint(equalToConstant: 20),
            name.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            name.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelectionControls() }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard !model.isReadOnly, displayedApps.indices.contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(displayedApps[row].id.rawValue, forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard !model.isReadOnly, operation == .above,
              info.draggingPasteboard.string(forType: Self.dragType) != nil else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        guard !model.isReadOnly, let raw = info.draggingPasteboard.string(forType: Self.dragType),
              let source = model.apps.firstIndex(where: { $0.id.rawValue == raw }) else { return false }
        model.perform(.move(IndexSet(integer: source), row))
        return true
    }

    private func updateSelectionControls() {
        let selected = selectedApp != nil
        removeButton.isEnabled = selected && !model.isReadOnly
        upButton.isEnabled = selected && table.selectedRow > 0 && !model.isReadOnly
        downButton.isEnabled = selected && table.selectedRow < displayedApps.count - 1 && !model.isReadOnly
        moreButton.isEnabled = selected
        moreButton.menu?.items.dropFirst().forEach { $0.isEnabled = selected && ($0.tag < 2 || !model.isReadOnly) }
    }

    private func moveSelection(_ direction: Int) {
        let index = table.selectedRow
        guard !model.isReadOnly, displayedApps.indices.contains(index), displayedApps.indices.contains(index + direction) else { return }
        model.perform(.move(IndexSet(integer: index), direction > 0 ? index + 2 : index - 1))
    }

    @objc private func openSelected() { if let selectedApp { model.perform(.open(selectedApp.id)) } }
    @objc private func revealSelected() { if let selectedApp { model.perform(.reveal(selectedApp.id)) } }
    @objc private func replaceSelected() { if let selectedApp { model.perform(.replaceApp(selectedApp.id)) } }
    @objc private func removeSelected() { if let selectedApp { model.perform(.remove(selectedApp.id)) } }
}

@MainActor
private final class AppearanceSettingsPage: NSView {
    private let model: DockPresentationModel
    private let running = ActionCheckbox(title: "실행 중인 앱 자동 표시", action: nil)
    private let hideFinder = ActionCheckbox(title: "Finder 숨기기", action: nil)
    private let login = ActionCheckbox(title: "로그인할 때 시작", action: nil)
    private let iconSlider = TrackingPreferenceSlider(value: 24, minValue: 16, maxValue: 32, target: nil, action: nil)
    private let spacingSlider = TrackingPreferenceSlider(value: 0, minValue: 0, maxValue: 28, target: nil, action: nil)
    private let count = NSPopUpButton()
    private let iconLabel = label("")
    private let spacingLabel = label("")
    private let loginLabel = label("", secondary: true)
    private let reset = ActionButton(title: "기본값", action: nil)

    init(model: DockPresentationModel) {
        self.model = model
        super.init(frame: .zero)
        running.onChange = { [weak self] value in self?.update(\.showsRunningApps, value) }
        hideFinder.onChange = { [weak self] value in self?.update(\.hidesFinder, value) }
        login.onChange = { [weak model] value in model?.perform(.login(value)) }
        reset.onAction = { [weak self] in self?.resetIconLayout() }
        reset.controlSize = .small
        reset.setAccessibilityLabel("아이콘 크기 및 간격 기본값")
        reset.toolTip = "아이콘 크기와 간격만 기본값으로 되돌립니다."
        running.toolTip = "목록에 없는 실행 중인 앱을 앞쪽에 표시합니다."
        hideFinder.toolTip = "메뉴 막대와 기본 앱 전환 목록에서 Finder를 숨깁니다. 앱 검색에서는 계속 찾을 수 있습니다."
        iconSlider.target = self
        iconSlider.action = #selector(changeIconSize)
        iconSlider.controlSize = .small
        iconSlider.isContinuous = true
        iconSlider.setAccessibilityLabel("아이콘 크기")
        spacingSlider.target = self
        spacingSlider.action = #selector(changeSpacing)
        spacingSlider.controlSize = .small
        spacingSlider.isContinuous = true
        spacingSlider.setAccessibilityLabel("아이콘 간격")
        spacingSlider.toolTip = "macOS 기본 간격에 더하는 여백입니다."
        count.addItems(withTitles: (1...20).map { "\($0)개" })
        count.target = self
        count.action = #selector(changeCount)
        count.setAccessibilityLabel("최대 표시 개수")
        count.controlSize = .small
        count.toolTip = "나머지 앱은 키보드 선택 패널에서 선택합니다. 기본 단축키는 ⌘ Space입니다."
        count.widthAnchor.constraint(equalToConstant: 82).isActive = true
        iconLabel.alignment = .right
        spacingLabel.alignment = .right
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        install(content, in: self)
        addFullWidth(formRow("아이콘 크기", control: iconSlider, trailing: iconLabel), to: content)
        addFullWidth(formRow("아이콘 간격", control: spacingSlider, trailing: spacingLabel), to: content)
        let countRow = formRow("최대 표시 개수", control: count)
        countRow.addArrangedSubview(reset)
        addFullWidth(countRow, to: content)
        addFullWidth(formRow("앱 목록", control: running), to: content)
        addFullWidth(formRow("", control: hideFinder), to: content)
        addFullWidth(formRow("시작", control: login), to: content)
        addFullWidth(formRow("", control: loginLabel), to: content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var hasLoginNotice: Bool {
        !model.loginStatus.isEmpty && ![
            "로그인할 때 자동으로 시작합니다.", "자동 시작이 꺼져 있습니다.",
        ].contains(model.loginStatus)
    }

    func refresh() {
        let preferences = model.preferences
        running.state = preferences.showsRunningApps ? .on : .off
        hideFinder.state = preferences.hidesFinder ? .on : .off
        login.state = model.loginEnabled ? .on : .off
        iconSlider.synchronize(value: preferences.iconSize)
        spacingSlider.synchronize(value: max(0, preferences.slotWidth - preferences.iconSize))
        iconLabel.stringValue = "\(Int(iconSlider.doubleValue.rounded()))pt"
        spacingLabel.stringValue = "\(Int(spacingSlider.doubleValue.rounded()))pt"
        count.selectItem(at: preferences.maxVisibleApps - 1)
        loginLabel.stringValue = model.loginStatus
        login.toolTip = model.loginStatus
        // 체크 상태와 중복되는 정상 안내는 생략하고 설치·승인 오류는 그대로 보여 준다.
        loginLabel.superview?.isHidden = !hasLoginNotice
        running.isEnabled = !model.isReadOnly
        hideFinder.isEnabled = !model.isReadOnly
        iconSlider.isEnabled = !model.isReadOnly
        spacingSlider.isEnabled = iconSlider.isEnabled
        count.isEnabled = iconSlider.isEnabled
        reset.isEnabled = !model.isReadOnly
    }

    private func update<Value>(_ keyPath: WritableKeyPath<DockPreferences, Value>, _ value: Value) {
        var preferences = model.preferences
        preferences[keyPath: keyPath] = value
        if preferences != model.preferences { model.perform(.preferences(preferences)) }
    }

    private func resetIconLayout() {
        guard !model.isReadOnly else { return }
        var preferences = model.preferences
        let defaults = DockPreferences()
        preferences.iconSize = defaults.iconSize
        preferences.slotWidth = defaults.slotWidth
        model.perform(.preferences(preferences))
    }

    @objc private func changeIconSize() {
        iconLabel.stringValue = "\(Int(iconSlider.doubleValue.rounded()))pt"
        var preferences = model.preferences
        let spacing = max(0, preferences.slotWidth - preferences.iconSize)
        preferences.iconSize = iconSlider.doubleValue.rounded()
        // 아이콘 크기만 바꿔도 사용자가 정한 추가 간격은 유지한다.
        preferences.slotWidth = min(60, preferences.iconSize + spacing)
        if preferences != model.preferences { model.perform(.preferences(preferences)) }
    }
    @objc private func changeSpacing() {
        spacingLabel.stringValue = "\(Int(spacingSlider.doubleValue.rounded()))pt"
        update(\.slotWidth, model.preferences.iconSize + spacingSlider.doubleValue.rounded())
    }
    @objc private func changeCount() { update(\.maxVisibleApps, count.indexOfSelectedItem + 1) }
}

@MainActor
private final class ShortcutSettingsPage: NSView {
    private let model: DockPresentationModel
    private let enabled = ActionCheckbox(title: "키보드로 앱 선택", action: nil)
    private let forward: ShortcutRecorderButton
    private let backward: ShortcutRecorderButton
    private let reset: ActionButton

    init(model: DockPresentationModel) {
        self.model = model
        forward = ShortcutRecorderButton(model: model, direction: .forward)
        backward = ShortcutRecorderButton(model: model, direction: .backward)
        reset = ActionButton(title: "단축키 기본값") { [weak model] in model?.perform(.resetShortcuts) }
        reset.controlSize = .small
        super.init(frame: .zero)
        enabled.onChange = { [weak model] value in
            guard let model else { return }
            var preferences = model.preferences
            preferences.shortcutEnabled = value
            model.perform(.preferences(preferences))
        }
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        install(content, in: self)
        addFullWidth(horizontal([enabled, NSView(), reset]), to: content)
        addFullWidth(formRow("다음 앱 선택", control: forward), to: content)
        addFullWidth(formRow("이전 앱 선택", control: backward), to: content)
        addFullWidth(label("← → 이동 · Enter 열기 · Esc 취소", secondary: true), to: content)
        addFullWidth(label("⌘ Space 사용 시 macOS의 Spotlight 단축키를 해제합니다.", secondary: true), to: content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func refresh() {
        enabled.state = model.preferences.shortcutEnabled ? .on : .off
        enabled.isEnabled = !model.isReadOnly
        let canEdit = model.preferences.shortcutEnabled && !model.isReadOnly
        forward.updateTitle(model.forwardShortcut)
        backward.updateTitle(model.backwardShortcut)
        forward.isEnabled = canEdit
        backward.isEnabled = canEdit
        reset.isEnabled = !model.isReadOnly
    }
}

/// 기록하는 동안만 전역 단축키를 멈추며 포커스 이탈과 Esc에서 반드시 복구한다.
@MainActor
private final class ShortcutRecorderButton: NSButton {
    private let model: DockPresentationModel
    private let direction: ShortcutAction
    private var isRecording = false
    private var displayTitle = ""
    private var resignObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?

    init(model: DockPresentationModel, direction: ShortcutAction) {
        self.model = model
        self.direction = direction
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
        setAccessibilityLabel(direction == .forward ? "다음 앱 단축키 변경" : "이전 앱 단축키 변경")
        toolTip = "클릭한 뒤 ⌘, ⌥ 또는 ⌃를 포함한 조합을 입력하세요. Esc로 취소합니다."
        widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        guard let window else { endRecording(); return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.endRecording() }
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.endRecording() }
        }
    }

    override func resignFirstResponder() -> Bool { endRecording(); return super.resignFirstResponder() }

    func updateTitle(_ title: String) {
        displayTitle = title
        if !isRecording { self.title = title.isEmpty ? "단축키 지정…" : title }
    }

    @objc private func beginRecording() {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        isRecording = true
        title = "키 조합 입력…"
        model.perform(.suspendShortcuts(true))
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { endRecording(); return }
        guard let binding = ShortcutBinding.from(event: event) else {
            title = "⌘, ⌥ 또는 ⌃와 함께 입력"
            NSSound.beep()
            return
        }
        model.perform(.shortcut(direction, binding))
        endRecording()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        title = displayTitle
        model.perform(.suspendShortcuts(false))
    }

    private func removeObservers() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        resignObserver = nil
        closeObserver = nil
    }

    isolated deinit { removeObservers() }
}

@MainActor
private final class HelpSettingsPage: NSView {
    init(model: DockPresentationModel) {
        super.init(frame: .zero)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let help = ActionButton(title: "사용 안내") { [weak model] in model?.perform(.help) }
        let update = ActionButton(title: "업데이트") { [weak model] in model?.perform(.checkForUpdates) }
        let quit = ActionButton(title: "종료") { [weak model] in model?.perform(.quit) }
        for button in [help, update, quit] {
            button.controlSize = .small
            button.isBordered = false
            button.font = .systemFont(ofSize: 11)
        }
        install(horizontal([label("버전 \(version)", font: .systemFont(ofSize: 11), secondary: true), NSView(), help, update, quit]), in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// 시스템 셀의 추적 수명만 관찰하고 마우스 이동과 손잡이 그리기는 AppKit에 맡긴다.
@MainActor
final class TrackingPreferenceSlider: NSSlider {
    private(set) var isTrackingPreference = false

    override class var cellClass: AnyClass? {
        get { PreferenceSliderCell.self }
        set { }
    }

    func synchronize(value: Double) {
        guard !isTrackingPreference, doubleValue.rounded() != value else { return }
        doubleValue = value
    }

    func beginPreferenceTracking() { isTrackingPreference = true }

    func finishPreferenceTracking() {
        isTrackingPreference = false
        doubleValue = doubleValue.rounded()
        _ = sendAction(action, to: target)
    }
}

@MainActor
private final class PreferenceSliderCell: NSSliderCell {
    override func startTracking(at startPoint: NSPoint, in controlView: NSView) -> Bool {
        guard super.startTracking(at: startPoint, in: controlView) else { return false }
        (controlView as? TrackingPreferenceSlider)?.beginPreferenceTracking()
        return true
    }

    override func stopTracking(last lastPoint: NSPoint, current stopPoint: NSPoint, in controlView: NSView, mouseIsUp flag: Bool) {
        super.stopTracking(last: lastPoint, current: stopPoint, in: controlView, mouseIsUp: flag)
        (controlView as? TrackingPreferenceSlider)?.finishPreferenceTracking()
    }
}

// 공통 AppKit 요소는 사용자 입력만 전달하고 도메인 정책을 소유하지 않는다.
@MainActor
private final class ActionButton: NSButton {
    var onAction: (() -> Void)?

    init(title: String, action: (() -> Void)?) {
        onAction = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        self.action = #selector(invoke)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { onAction?() }
}

@MainActor
private final class ActionCheckbox: NSButton {
    var onChange: ((Bool) -> Void)?

    init(title: String, action: ((Bool) -> Void)?) {
        onChange = action
        super.init(frame: .zero)
        self.title = title
        setButtonType(.switch)
        target = self
        self.action = #selector(invoke)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { onChange?(state == .on) }
}

@MainActor
private func label(_ value: String, font: NSFont = .systemFont(ofSize: 12), secondary: Bool = false) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: value)
    field.font = font
    field.textColor = secondary ? .secondaryLabelColor : .labelColor
    field.setContentCompressionResistancePriority(.required, for: .vertical)
    return field
}

@MainActor
private func toolbarButton(_ title: String, label: String, action: (() -> Void)?) -> ActionButton {
    let button = ActionButton(title: title, action: action)
    button.controlSize = .small
    button.font = .systemFont(ofSize: 13)
    button.setAccessibilityLabel(label)
    button.toolTip = label
    button.widthAnchor.constraint(equalToConstant: 28).isActive = true
    return button
}

@MainActor
private func horizontal(_ views: [NSView]) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 8
    return stack
}

@MainActor
private func formRow(_ title: String, control: NSView, trailing: NSView? = nil) -> NSStackView {
    let name = label(title)
    name.widthAnchor.constraint(equalToConstant: 104).isActive = true
    var views = [name, control]
    if let trailing {
        trailing.widthAnchor.constraint(equalToConstant: 38).isActive = true
        views.append(trailing)
    } else { views.append(NSView()) }
    return horizontal(views)
}

@MainActor
private func install(_ stack: NSStackView, in parent: NSView) {
    stack.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        stack.topAnchor.constraint(equalTo: parent.topAnchor),
        stack.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
    ])
}

@MainActor
private func addFullWidth(_ view: NSView, to stack: NSStackView) {
    stack.addArrangedSubview(view)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
}
