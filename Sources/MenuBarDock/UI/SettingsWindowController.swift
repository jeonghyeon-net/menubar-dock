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
            contentRect: NSRect(x: 0, y: 0, width: 710, height: 610),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.title = "Menu Bar Dock 설정"
        window.minSize = NSSize(width: 620, height: 530)
        window.setFrameAutosaveName("MenuBarDock.Settings")
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
        container.spacing = 12
        container.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        window?.contentView = container

        noticeView.orientation = .horizontal
        noticeView.alignment = .top
        noticeView.spacing = 10
        let warning = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "안내") ?? NSImage())
        warning.contentTintColor = .systemOrange
        warning.setContentHuggingPriority(.required, for: .horizontal)
        noticeLabel.font = .systemFont(ofSize: 12)
        noticeLabel.isSelectable = true
        let dismiss = ActionButton(title: "닫기") { [weak model] in model?.perform(.dismissNotice) }
        noticeView.addArrangedSubview(warning)
        noticeView.addArrangedSubview(noticeLabel)
        noticeView.addArrangedSubview(dismiss)
        container.addArrangedSubview(noticeView)

        let tabs = NSTabView()
        tabs.tabViewType = .topTabsBezelBorder
        for (name, view) in [
            ("앱과 순서", applications as NSView),
            ("메뉴 막대", appearance as NSView),
            ("단축키", shortcuts as NSView),
            ("사용 안내", HelpSettingsPage(model: model) as NSView),
        ] {
            let item = NSTabViewItem(identifier: name)
            item.label = name
            item.view = view
            tabs.addTabViewItem(item)
        }
        container.addArrangedSubview(tabs)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        noticeView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tabs.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -32),
            noticeView.widthAnchor.constraint(equalTo: tabs.widthAnchor),
            tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])
        tabs.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    private func refresh() {
        noticeLabel.stringValue = model.notice ?? ""
        noticeView.isHidden = model.notice == nil
        applications.refresh()
        appearance.refresh()
        shortcuts.refresh()
    }
}

@MainActor
private final class ApplicationsSettingsPage: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private static let dragType = NSPasteboard.PasteboardType("net.jeonghyeon.MenuBarDock.app-id")
    private let model: DockPresentationModel
    private let table = NSTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let addButton: ActionButton
    private let upButton: ActionButton
    private let downButton: ActionButton
    private let moreButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var displayedApps: [AppEntry] = []
    private var displayedReadOnly = false

    init(model: DockPresentationModel) {
        self.model = model
        addButton = ActionButton(title: "앱 추가…") { [weak model] in model?.perform(.addApps) }
        upButton = ActionButton(title: "↑ 위로", action: nil)
        downButton = ActionButton(title: "↓ 아래로", action: nil)
        super.init(frame: .zero)
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
        content.spacing = 12
        install(content, in: self)
        let header = horizontal([
            label("앱을 원하는 순서로", font: .systemFont(ofSize: 16, weight: .semibold)),
            NSView(), addButton,
        ])
        addFullWidth(header, to: content)
        addFullWidth(label("목록을 드래그하거나 위로·아래로 버튼으로 순서를 바꾸세요.", secondary: true), to: content)
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 49
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.setAccessibilityLabel("앱 표시 순서")
        let appColumn = NSTableColumn(identifier: .init("app"))
        appColumn.width = 410
        appColumn.minWidth = 240
        appColumn.resizingMask = .autoresizingMask
        let pinColumn = NSTableColumn(identifier: .init("pin"))
        pinColumn.width = 62
        pinColumn.minWidth = 62
        pinColumn.maxWidth = 62
        let excludeColumn = NSTableColumn(identifier: .init("exclude"))
        excludeColumn.width = 62
        excludeColumn.minWidth = 62
        excludeColumn.maxWidth = 62
        table.addTableColumn(appColumn)
        table.addTableColumn(pinColumn)
        table.addTableColumn(excludeColumn)
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        addFullWidth(scroll, to: content)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        addFullWidth(emptyLabel, to: content)
        moreButton.addItem(withTitle: "더 보기")
        for (title, action, tag) in [
            ("열기", #selector(openSelected), 0),
            ("Finder에서 보기", #selector(revealSelected), 1),
            ("앱 경로 다시 지정…", #selector(replaceSelected), 2),
            ("목록에서 제거", #selector(removeSelected), 3),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = tag
            moreButton.menu?.addItem(item)
        }
        moreButton.menu?.autoenablesItems = false
        addFullWidth(horizontal([upButton, downButton, NSView(), moreButton]), to: content)
        addFullWidth(label("고정한 앱은 종료해도 표시됩니다. 제외한 앱은 실행 중이어도 나타나지 않습니다.", secondary: true), to: content)
    }

    func refresh() {
        let selection = selectedApp?.id
        if displayedApps != model.apps || displayedReadOnly != model.isReadOnly {
            displayedApps = model.apps
            displayedReadOnly = model.isReadOnly
            table.reloadData()
            if let selection, let row = displayedApps.firstIndex(where: { $0.id == selection }) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        addButton.isEnabled = !model.isReadOnly
        emptyLabel.stringValue = model.isReadOnly
            ? "새로운 버전에서 만든 설정 파일을 보호하고 있어 변경할 수 없습니다."
            : displayedApps.isEmpty ? "아직 앱이 없습니다. 앱을 추가하거나 실행 중인 앱 자동 표시를 켜세요." : ""
        emptyLabel.isHidden = emptyLabel.stringValue.isEmpty
        updateSelectionControls()
    }

    private var selectedApp: AppEntry? {
        displayedApps.indices.contains(table.selectedRow) ? displayedApps[table.selectedRow] : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { displayedApps.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard displayedApps.indices.contains(row), let column else { return nil }
        let app = displayedApps[row]
        if column.identifier.rawValue == "pin" || column.identifier.rawValue == "exclude" {
            let isPin = column.identifier.rawValue == "pin"
            let checkbox = ActionCheckbox(title: isPin ? "고정" : "제외") { [weak model] value in
                model?.perform(isPin ? .pin(app.id, value) : .exclude(app.id, value))
            }
            checkbox.state = (isPin ? app.isPinned : app.isExcluded) ? .on : .off
            checkbox.isEnabled = !model.isReadOnly
            checkbox.setAccessibilityLabel("\(app.name) \(isPin ? "고정" : "제외")")
            return checkbox
        }
        let cell = NSView()
        let image = NSImageView(image: model.imageForApp(app))
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        image.setAccessibilityElement(false)
        let name = label(app.name, font: .systemFont(ofSize: 13, weight: .medium))
        name.lineBreakMode = .byTruncatingTail
        let path = label(app.bundlePath, font: .systemFont(ofSize: 10), secondary: true)
        path.lineBreakMode = .byTruncatingMiddle
        path.maximumNumberOfLines = 1
        path.toolTip = app.bundlePath
        let text = NSStackView(views: [name, path])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 28), image.heightAnchor.constraint(equalToConstant: 28),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            name.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor),
            path.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor),
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
    private let compact = ActionCheckbox(title: "아이콘 하나만 표시", action: nil)
    private let running = ActionCheckbox(title: "실행 중인 앱 자동 표시", action: nil)
    private let login = ActionCheckbox(title: "로그인할 때 시작", action: nil)
    private let iconSlider = NSSlider(value: 18, minValue: 14, maxValue: 24, target: nil, action: nil)
    private let spacingSlider = NSSlider(value: 4, minValue: 0, maxValue: 12, target: nil, action: nil)
    private let count = NSPopUpButton()
    private let iconLabel = label("")
    private let spacingLabel = label("")
    private let loginLabel = label("", secondary: true)

    init(model: DockPresentationModel) {
        self.model = model
        super.init(frame: .zero)
        compact.onChange = { [weak self] value in self?.update(\.isCompact, value) }
        running.onChange = { [weak self] value in self?.update(\.showsRunningApps, value) }
        login.onChange = { [weak model] value in model?.perform(.login(value)) }
        iconSlider.target = self
        iconSlider.action = #selector(changeIconSize)
        iconSlider.numberOfTickMarks = 11
        iconSlider.allowsTickMarkValuesOnly = true
        iconSlider.setAccessibilityLabel("아이콘 크기")
        spacingSlider.target = self
        spacingSlider.action = #selector(changeSpacing)
        spacingSlider.numberOfTickMarks = 13
        spacingSlider.allowsTickMarkValuesOnly = true
        spacingSlider.setAccessibilityLabel("아이콘 간격")
        count.addItems(withTitles: (1...20).map { "\($0)개" })
        count.target = self
        count.action = #selector(changeCount)
        count.setAccessibilityLabel("최대 표시 개수")
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        install(content, in: self)
        addFullWidth(sectionTitle("표시 방식"), to: content)
        content.addArrangedSubview(compact)
        addFullWidth(label("공간이 부족하면 아이콘 하나로 전체 앱 메뉴를 열 수 있습니다.", secondary: true), to: content)
        content.addArrangedSubview(running)
        addFullWidth(label("고정하지 않은 앱도 실행 중일 때 표시합니다. 상태 점이나 배지는 추가하지 않습니다.", secondary: true), to: content)
        addFullWidth(sectionTitle("아이콘 배치"), to: content)
        addFullWidth(formRow("아이콘 크기", control: iconSlider, trailing: iconLabel), to: content)
        addFullWidth(formRow("아이콘 간격", control: spacingSlider, trailing: spacingLabel), to: content)
        addFullWidth(formRow("최대 표시 개수", control: count), to: content)
        addFullWidth(label("앱 수만큼 공간을 사용하며 넘친 앱은 더 보기(···)에 표시합니다.", secondary: true), to: content)
        addFullWidth(sectionTitle("시작"), to: content)
        content.addArrangedSubview(login)
        addFullWidth(loginLabel, to: content)
        content.addArrangedSubview(NSView())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func refresh() {
        let preferences = model.preferences
        compact.state = preferences.isCompact ? .on : .off
        running.state = preferences.showsRunningApps ? .on : .off
        login.state = model.loginEnabled ? .on : .off
        iconSlider.doubleValue = preferences.iconSize
        spacingSlider.doubleValue = preferences.iconSpacing
        iconLabel.stringValue = "\(Int(preferences.iconSize))pt"
        spacingLabel.stringValue = "\(Int(preferences.iconSpacing))pt"
        count.selectItem(at: preferences.maxVisibleApps - 1)
        loginLabel.stringValue = model.loginStatus
        compact.isEnabled = !model.isReadOnly
        running.isEnabled = !model.isReadOnly
        iconSlider.isEnabled = !model.isReadOnly && !preferences.isCompact
        spacingSlider.isEnabled = iconSlider.isEnabled
        count.isEnabled = iconSlider.isEnabled
    }

    private func update<Value>(_ keyPath: WritableKeyPath<DockPreferences, Value>, _ value: Value) {
        var preferences = model.preferences
        preferences[keyPath: keyPath] = value
        model.perform(.preferences(preferences))
    }

    @objc private func changeIconSize() { update(\.iconSize, iconSlider.doubleValue.rounded()) }
    @objc private func changeSpacing() { update(\.iconSpacing, spacingSlider.doubleValue.rounded()) }
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
        reset = ActionButton(title: "기본 단축키로 복원") { [weak model] in model?.perform(.resetShortcuts) }
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
        content.spacing = 16
        install(content, in: self)
        addFullWidth(sectionTitle("전역 단축키"), to: content)
        content.addArrangedSubview(enabled)
        addFullWidth(formRow("다음 앱 선택", control: forward), to: content)
        addFullWidth(formRow("이전 앱 선택", control: backward), to: content)
        addFullWidth(label("버튼을 누른 후 사용할 조합을 입력하세요. Esc는 취소입니다. 다른 앱에서 쓰는 단축키와 겹치면 새 조합을 지정하세요.", secondary: true), to: content)
        content.addArrangedSubview(reset)
        addFullWidth(sectionTitle("선택 패널 안에서"), to: content)
        addFullWidth(formRow("이전 / 다음 앱", control: label("← / →")), to: content)
        addFullWidth(formRow("선택한 앱 열기", control: label("Enter")), to: content)
        addFullWidth(formRow("선택 취소", control: label("Esc")), to: content)
        addFullWidth(label("Option 키를 놓아도 앱이 바로 열리지 않습니다. Enter로 선택을 확정하세요.", secondary: true), to: content)
        content.addArrangedSubview(NSView())
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
        title = "키 조합을 입력하세요…"
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
}

@MainActor
private final class HelpSettingsPage: NSView {
    init(model: DockPresentationModel) {
        super.init(frame: .zero)
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 15
        installScrollable(content, in: self)
        addFullWidth(label("Menu Bar Dock", font: .systemFont(ofSize: 23, weight: .semibold)), to: content)
        addFullWidth(label("필요한 앱을, 정해 둔 순서 그대로.", secondary: true), to: content)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        addFullWidth(label("버전 \(version) · Apple Silicon · macOS 14 이상", font: .systemFont(ofSize: 11), secondary: true), to: content)
        for (title, detail) in [
            ("클릭해서 열기", "아이콘을 클릭하면 앱을 열거나 기존 창을 활성화합니다. 우클릭하면 고정, 숨기기, 종료 등 앱별 작업이 나타납니다."),
            ("순서는 한 번 정하면 그대로", "앱과 순서 탭에서 목록을 드래그하거나 위로·아래로 버튼을 누르세요. Command 키를 누르고 메뉴 막대를 드래그하면 런처 전체를 옮길 수 있습니다."),
            ("메뉴 막대가 보이지 않을 때", "노치나 다른 메뉴 때문에 공간이 부족할 수 있습니다. 단축키로 앱을 선택하거나 Finder에서 Menu Bar Dock을 다시 열어 설정을 띄우세요. 표시 개수를 줄이거나 아이콘 하나만 표시를 켜면 됩니다."),
            ("화면과 개인정보", "시스템의 외관 설정을 따르며 다른 앱 창의 위치를 바꾸지 않습니다. 손쉬운 사용·화면 기록 권한 없이 동작하고 앱 목록은 이 Mac에만 저장합니다."),
        ] {
            addFullWidth(sectionTitle(title), to: content)
            addFullWidth(label(detail, secondary: true), to: content)
        }
        addFullWidth(horizontal([
            ActionButton(title: "자세한 사용 안내") { [weak model] in model?.perform(.help) },
            ActionButton(title: "업데이트 확인…") { [weak model] in model?.perform(.checkForUpdates) },
            NSView(),
            ActionButton(title: "앱 종료") { [weak model] in model?.perform(.quit) },
        ]), to: content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
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
private func sectionTitle(_ value: String) -> NSTextField { label(value, font: .systemFont(ofSize: 13, weight: .semibold)) }

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
    name.widthAnchor.constraint(equalToConstant: 112).isActive = true
    var views = [name, control]
    if let trailing {
        trailing.widthAnchor.constraint(equalToConstant: 42).isActive = true
        views.append(trailing)
    } else { views.append(NSView()) }
    return horizontal(views)
}

@MainActor
private func install(_ stack: NSStackView, in parent: NSView) {
    stack.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 20),
        stack.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -20),
        stack.topAnchor.constraint(equalTo: parent.topAnchor, constant: 20),
        stack.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -20),
    ])
}

@MainActor
private func installScrollable(_ stack: NSStackView, in parent: NSView) {
    let scroll = NSScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    let document = FlippedSettingsDocument()
    document.translatesAutoresizingMaskIntoConstraints = false
    scroll.documentView = document
    parent.addSubview(scroll)
    install(stack, in: document)
    NSLayoutConstraint.activate([
        scroll.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
        scroll.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        scroll.topAnchor.constraint(equalTo: parent.topAnchor),
        scroll.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
    ])
}

@MainActor
private final class FlippedSettingsDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private func addFullWidth(_ view: NSView, to stack: NSStackView) {
    stack.addArrangedSubview(view)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
}
