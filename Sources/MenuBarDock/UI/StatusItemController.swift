import AppKit
import Combine
import DockDomain

@MainActor
final class StatusItemController: NSObject {
    private struct Slot {
        let item: DockItem?
        let rect: NSRect
    }

    private let model: DockPresentationModel
    private let statusItem: NSStatusItem
    private var subscriptions: Set<AnyCancellable> = []
    private var observations: [NSObjectProtocol] = []
    private var slots: [Slot] = []
    private var imageSize = NSSize.zero
    private var pressedID: AppID?
    private var pressedLauncher = false
    private var menuActions: [UUID: () -> Void] = [:]
    private var appearanceObservation: NSKeyValueObservation?
    private var screenObservation: NSKeyValueObservation?

    init(model: DockPresentationModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.autosaveName = "MenuBarDock.Launcher"
        statusItem.behavior = []
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(activate(_:))
            button.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.setAccessibilityLabel("Menu Bar Dock")
            button.setAccessibilityRole(.group)
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.update() }
            }
            screenObservation = button.window?.observe(\.backingScaleFactor, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.update() }
            }
        }
        model.$items.combineLatest(model.$preferences).sink { [weak self] _, _ in
            // Published는 값 변경 전에 알리므로 다음 메인 실행 구간에서 최신 투영을 읽는다.
            Task { @MainActor in self?.update() }
        }.store(in: &subscriptions)
        for name in [NSApplication.didChangeScreenParametersNotification, NSWindow.didChangeBackingPropertiesNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.update() }
            })
        }
        if let window = statusItem.button?.window {
            observations.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: window, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.rebuildAccessibility() } })
        }
        observations.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.update() } })
        update()
    }

    func tearDown() {
        subscriptions.removeAll()
        observations.forEach { token in
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        observations.removeAll()
        appearanceObservation = nil
        screenObservation = nil
        statusItem.button?.setAccessibilityChildren([])
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func update() {
        guard let button = statusItem.button else { return }
        let preferences = model.preferences
        let height = button.bounds.height > 0 ? button.bounds.height : NSStatusBar.system.thickness
        let iconSize = min(CGFloat(preferences.iconSize), height - 4)
        let spacing = CGFloat(preferences.iconSpacing)
        let visible = preferences.isCompact ? [] : Array(model.items.prefix(preferences.maxVisibleApps))
        let needsLauncher = visible.isEmpty || visible.count < model.items.count
        slots = []
        var x: CGFloat = 0
        for item in visible {
            slots.append(Slot(item: item, rect: NSRect(x: x, y: 0, width: iconSize, height: iconSize)))
            x += iconSize + spacing
        }
        if needsLauncher {
            slots.append(Slot(item: nil, rect: NSRect(x: x, y: 0, width: iconSize, height: iconSize)))
            x += iconSize + spacing
        }
        imageSize = NSSize(width: max(iconSize, x - spacing), height: iconSize)
        var image = NSImage(size: imageSize)
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            image = composeImage(size: imageSize, slots: slots)
        }
        // 표준 status button 이미지 경로를 유지해 비활성 화면의 합성을 시스템에 맡긴다.
        button.image = image
        statusItem.length = imageSize.width + 6
        button.toolTip = "Menu Bar Dock · 앱 클릭: 열기 · 우클릭: 관리"
        rebuildAccessibility()
    }

    private func composeImage(size: NSSize, slots: [Slot]) -> NSImage {
        let result = NSImage(size: size)
        result.isTemplate = slots.allSatisfy { $0.item == nil }
        for scale in [1, 2] {
            guard let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * CGFloat(scale))),
                pixelsHigh: Int(ceil(size.height * CGFloat(scale))), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: representation) else { continue }
            representation.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            context.imageInterpolation = .high
            for slot in slots {
                let image: NSImage?
                if let item = slot.item { image = model.imageForApp(item.app) }
                else {
                    image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "모든 앱과 설정")?
                        .withSymbolConfiguration(.init(paletteColors: [.labelColor]))
                }
                image?.draw(in: slot.rect, from: .zero, operation: .sourceOver, fraction: 1)
            }
            NSGraphicsContext.restoreGraphicsState()
            result.addRepresentation(representation)
        }
        return result
    }

    private func buttonRect(for slot: Slot, button: NSStatusBarButton) -> NSRect {
        slot.rect.offsetBy(dx: (button.bounds.width - imageSize.width) / 2,
                           dy: (button.bounds.height - imageSize.height) / 2)
    }

    private func slot(at point: NSPoint, in button: NSStatusBarButton) -> Slot? {
        slots.first { buttonRect(for: $0, button: button).insetBy(dx: -CGFloat(model.preferences.iconSpacing) / 2, dy: -6).contains(point) }
    }

    @objc private func activate(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { showMenu(for: nil); return }
        if event.modifierFlags.contains(.command) { pressedID = nil; pressedLauncher = false; return }
        let point = sender.convert(event.locationInWindow, from: nil)
        let hit = slot(at: point, in: sender)
        if event.type == .leftMouseDown {
            pressedID = hit?.item?.id
            pressedLauncher = hit?.item == nil
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            pressedID = nil
            pressedLauncher = false
            showMenu(for: hit?.item)
            return
        }
        defer { pressedID = nil; pressedLauncher = false }
        guard sender.bounds.contains(point) else { return }
        if let id = pressedID, hit?.item?.id == id { model.perform(.open(id)) }
        else if pressedLauncher { showMenu(for: nil) }
    }

    private func rebuildAccessibility() {
        guard let button = statusItem.button, let window = button.window else { return }
        let children = slots.map { slot -> NSAccessibilityElement in
            let element = LauncherAccessibilityElement(press: { [weak self] in
                guard let self else { return }
                if let item = slot.item { self.model.perform(.open(item.id)) }
                else { self.showMenu(for: nil) }
            }, showMenu: { [weak self] in self?.showMenu(for: slot.item) })
            element.setAccessibilityRole(.button)
            element.setAccessibilityParent(button)
            let frame = window.convertToScreen(button.convert(buttonRect(for: slot, button: button), to: nil))
            element.setAccessibilityFrame(frame)
            element.setAccessibilityLabel(slot.item?.app.name ?? "모든 앱과 설정")
            element.setAccessibilityHelp(slot.item == nil ? "전체 앱 목록과 설정 메뉴 열기" : "누르면 앱 열기. 메뉴를 열면 앱 관리")
            return element
        }
        button.setAccessibilityChildren(children)
    }

    private func showMenu(for selected: DockItem?) {
        guard let button = statusItem.button else { return }
        menuActions.removeAll()
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let selected {
            let title = NSMenuItem(title: selected.app.name, action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            append("열기", to: menu) { [weak self] in self?.model.perform(.open(selected.id)) }
            append(selected.app.isPinned ? "고정 해제" : "메뉴 막대에 고정", to: menu, enabled: !model.isReadOnly) { [weak self] in
                self?.model.perform(.pin(selected.id, !selected.app.isPinned))
            }
            if selected.isRunning {
                append("숨기기", to: menu) { [weak self] in self?.model.perform(.hide(selected.id)) }
                append("다시 표시", to: menu) { [weak self] in self?.model.perform(.unhide(selected.id)) }
                append("앱 종료", to: menu) { [weak self] in self?.model.perform(.quitApp(selected.id)) }
            }
            append("Finder에서 보기", to: menu) { [weak self] in self?.model.perform(.reveal(selected.id)) }
            append("목록에서 제외", to: menu, enabled: !model.isReadOnly) { [weak self] in self?.model.perform(.exclude(selected.id, true)) }
            menu.addItem(.separator())
        } else {
            for item in model.items {
                let entry = append(item.app.name, to: menu) { [weak self] in self?.model.perform(.open(item.id)) }
                let image = model.imageForApp(item.app).copy() as? NSImage
                image?.size = NSSize(width: 18, height: 18)
                entry.image = image
            }
            if !model.items.isEmpty { menu.addItem(.separator()) }
        }
        if let notice = model.notice {
            let item = NSMenuItem(title: notice, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.toolTip = notice
            menu.addItem(item)
            menu.addItem(.separator())
        }
        append("앱 추가…", to: menu, enabled: !model.isReadOnly) { [weak self] in self?.model.perform(.addApps) }
        append("설정…", to: menu, key: ",") { [weak self] in self?.model.perform(.settings) }
        append("사용 안내", to: menu) { [weak self] in self?.model.perform(.help) }
        append("업데이트 확인…", to: menu) { [weak self] in self?.model.perform(.checkForUpdates) }
        menu.addItem(.separator())
        append("Menu Bar Dock 종료", to: menu, key: "q") { [weak self] in self?.model.perform(.quit) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }

    @discardableResult
    private func append(_ title: String, to menu: NSMenu, key: String = "", enabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let identifier = UUID()
        menuActions[identifier] = action
        let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: key)
        item.target = self
        item.representedObject = identifier
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? UUID else { return }
        menuActions[identifier]?()
    }
}

@MainActor
private final class LauncherAccessibilityElement: NSAccessibilityElement {
    nonisolated private let press: @MainActor @Sendable () -> Void
    nonisolated private let showMenu: @MainActor @Sendable () -> Void

    init(press: @escaping @MainActor @Sendable () -> Void, showMenu: @escaping @MainActor @Sendable () -> Void) {
        self.press = press
        self.showMenu = showMenu
        super.init()
    }

    nonisolated override func accessibilityPerformPress() -> Bool {
        let action = press
        Task { @MainActor in action() }
        return true
    }
    nonisolated override func accessibilityPerformShowMenu() -> Bool {
        let action = showMenu
        Task { @MainActor in action() }
        return true
    }
}
