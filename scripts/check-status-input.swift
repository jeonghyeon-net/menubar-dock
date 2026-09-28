import AppKit
import DockDomain

/// Swift Testing의 async main과 AppKit의 버튼 추적 루프를 분리해 실제 이벤트 전달을 검증한다.
@main
@MainActor
struct StatusInputCheck {
    static func fail(_ message: String) -> Never {
        print("실패: \(message)")
        exit(1)
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let entries = [
            ("Finder", "/System/Library/CoreServices/Finder.app"),
            ("Safari", "/Applications/Safari.app"),
            ("캘린더", "/System/Applications/Calendar.app"),
            ("메모", "/System/Applications/Notes.app"),
            ("터미널", "/System/Applications/Utilities/Terminal.app"),
            ("시스템 설정", "/System/Applications/System Settings.app"),
            ("메일", "/System/Applications/Mail.app"),
            ("미리보기", "/System/Applications/Preview.app")
        ].enumerated().map { index, fixture in
            AppEntry(id: AppID(rawValue: "system-fixture-\(index)"), name: fixture.0, bundlePath: fixture.1)
        }
        var opened: [AppID] = []
        var settingsActions = 0
        var items: [NSStatusItem] = []
        var removedItems: [NSStatusItem] = []
        var removedLabels: [String] = []
        // 외부 앱이나 설정 창을 실행하지 않는다. production controller가 전달한 명령만 기록한다.
        let model = DockPresentationModel(imageForApp: { NSWorkspace.shared.icon(forFile: $0.bundlePath) }) { action in
            switch action {
            case let .open(id): opened.append(id)
            case .settings: settingsActions += 1
            default: break
            }
        }
        model.preferences.maxVisibleApps = entries.count
        model.items = entries.map { DockItem(app: $0, isRunning: false) }
        // 메뉴 presenter를 대체하지 않는다. 실제 제품의 NSMenu.popUp 경로를 실행한다.
        let controller = StatusItemController(model: model, makeStatusItem: { length in
            let item = NSStatusBar.system.statusItem(withLength: length)
            items.append(item)
            return item
        }, removeStatusItem: { item in
            removedItems.append(item)
            removedLabels.append(item.button?.accessibilityLabel() ?? "이름 없음")
            NSStatusBar.system.removeStatusItem(item)
        })
        let popups = PopupRecorder()
        // GUI 세션이 없는 환경에서도 영원히 입력을 기다리지 않는 일회성 종료 제한이다.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            print("실패: AppKit 입력 검증 제한 시간 초과. 로그인된 macOS GUI 세션에서 실행해 주세요.")
            exit(1)
        }
        // 시스템 상태 항목의 최초 레이아웃이 완료될 한 번의 실행 구간을 준다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            var buttons: [NSStatusBarButton] = []
            for (index, entry) in entries.enumerated() {
                guard let button = items.first(where: { $0.button?.accessibilityLabel() == entry.name })?.button else {
                    fail("\(entry.name) 상태 버튼 없음")
                }
                sendClick(button: button, type: .leftMouseDown, sequence: index)
                guard opened.count == index + 1, opened.last == entry.id else { fail("\(entry.name) 왼클릭 명령 불일치") }
                let imageSize = button.image?.size ?? .zero
                guard imageSize == NSSize(width: model.preferences.iconSize, height: model.preferences.iconSize),
                      imageSize.width <= button.bounds.width,
                      imageSize.height <= button.bounds.height else { fail("\(entry.name) 요청 크기 또는 버튼 영역 불일치") }
                let windowPadding = (button.window?.frame.width ?? button.bounds.width) - button.bounds.width
                print("크기: \(entry.name), 버튼 \(button.bounds.size), 아이콘 \(imageSize), 슬롯 \(model.preferences.slotWidth), macOS 창 추가 폭 \(windowPadding)pt")
                buttons.append(button)
            }
            guard opened == entries.map(\.id), popups.began == 0 else { fail("왼클릭에 메뉴 또는 잘못된 앱이 열림") }
            print("통과: 독립 NSStatusItem \(entries.count)개의 hitTest → leftMouseDown → leftMouseUp → AppID 전달")
            for (index, button) in buttons.enumerated() {
                sendClick(button: button, type: .rightMouseDown, sequence: entries.count + index)
                guard popups.began == index + 1, popups.ended == index + 1,
                      settingsActions == index + 1, opened.count == entries.count else { fail("우클릭 메뉴 또는 설정 선택 불일치") }
            }
            print("통과: 우클릭 \(entries.count)회 → 실제 NSMenu tracking 시작/종료 → 설정 선택, 앱 실행 없음")
            guard let first = buttons.first else { fail("버튼 없음") }
            sendClick(button: first, type: .leftMouseDown, flags: .control, sequence: entries.count * 2)
            guard popups.began == entries.count + 1, popups.ended == entries.count + 1,
                  settingsActions == entries.count + 1, opened.count == entries.count else { fail("Control 클릭 설정 불일치") }
            print("통과: Control 클릭 → 실제 메뉴 → 설정 선택")
            // 접근성 API 호출 뒤 실제 전달된 AppID와 메뉴 개수로 결과를 판정한다.
            _ = first.accessibilityPerformPress()
            guard opened.count == entries.count + 1,
                  opened.last == entries.first?.id, popups.began == entries.count + 1 else {
                fail("접근성 press가 앱을 열지 않음: 현재 이벤트 \(String(describing: NSApp.currentEvent?.type))")
            }
            print("통과: 접근성 press → 앱 실행, 메뉴 없음")
            let beforeSizing = opened.count
            verifyRequestedSizes(model: model, controller: controller, button: first)
            guard Array(opened.dropFirst(beforeSizing)) == Array(repeating: entries[0].id, count: 5) else {
                fail("크기 변경 후 왼클릭 대상 불일치")
            }
            if let path = ProcessInfo.processInfo.environment["MENU_BAR_SNAPSHOT_PATH"] {
                writeAppearanceSnapshot(buttons: buttons, path: path)
            }
            verifyRemovalIdentity(model: model, controller: controller, items: { items }, removedItems: { removedItems }, removedLabels: { removedLabels })
            verifyTransientLayoutFallback(entries: Array(entries.prefix(3)))
            popups.tearDown()
            controller.tearDown()
            exit(0)
        }
        app.run()
    }

    private static func verifyRemovalIdentity(
        model: DockPresentationModel, controller: StatusItemController, items: () -> [NSStatusItem],
        removedItems: () -> [NSStatusItem], removedLabels: () -> [String]
    ) {
        let original = model.items
        let previous = Dictionary(uniqueKeysWithValues: items().compactMap { item in
            item.button?.accessibilityLabel().map { ($0, ObjectIdentifier(item)) }
        })
        // 번호 끝 슬롯과 다른 앱을 골라 실제 삭제 경계를 검사한다.
        guard let target = items().first(where: { $0.autosaveName == "MenuBarDock.AppSlot.0" }),
              let name = target.button?.accessibilityLabel() else { fail("제거 검사 대상 없음") }
        let before = removedItems().count
        model.items.removeAll { $0.app.name == name }
        controller.update()
        let removed = Array(removedItems().dropFirst(before))
        let labels = Array(removedLabels().dropFirst(before))
        guard removed.count == 1, removed.first === target else {
            fail("요청한 앱과 다른 네이티브 슬롯 삭제: 요청 \(name), 실제 \(labels)")
        }
        for item in items() where !removedItems().contains(where: { $0 === item }) {
            guard let label = item.button?.accessibilityLabel(), previous[label] == ObjectIdentifier(item) else {
                fail("삭제 중 남은 앱 이미지가 다른 슬롯으로 이동")
            }
        }
        print("통과: 앱 제거 시 해당 네이티브 슬롯만 삭제, 나머지 앱의 슬롯·이미지 연결 유지")
        func active() -> [NSStatusItem] { items().filter { item in !removedItems().contains { $0 === item } } }
        func verifyCount() {
            let current = active()
            let expected = model.items.prefix(model.preferences.maxVisibleApps)
            guard current.count == expected.count,
                  Set(current.compactMap(\.autosaveName)).count == current.count,
                  Set(current.compactMap { $0.button?.accessibilityLabel() }) == Set(expected.map { $0.app.name }) else {
                fail("개수 변경 중 중복 번호·누락된 앱·빈 슬롯 발생")
            }
        }
        // 슬롯 0을 비운 뒤 다시 늘려 번호 재사용을 거친다.
        model.items = original
        controller.update()
        verifyCount()
        while !model.items.isEmpty {
            model.items.remove(at: model.items.count / 2)
            controller.update()
            verifyCount()
        }
        model.items = original
        model.preferences.maxVisibleApps = 3
        controller.update()
        verifyCount()
        model.preferences.maxVisibleApps = original.count
        controller.update()
        verifyCount()
        print("통과: 빈 번호 재사용, 반복 감소→빈 목록→재생성, 초과 항목 개수 제한")
    }

    private static func verifyTransientLayoutFallback(entries: [AppEntry]) {
        var items: [NSStatusItem] = []
        var hasValidFrames = true
        let model = DockPresentationModel(imageForApp: { NSWorkspace.shared.icon(forFile: $0.bundlePath) }, perform: { _ in })
        model.items = entries.map { DockItem(app: $0, isRunning: false) }
        let controller = StatusItemController(model: model, makeStatusItem: { width in
            let item = NSStatusBar.system.statusItem(withLength: width)
            items.append(item)
            return item
        }, frameForStatusItem: { item in
            guard hasValidFrames, let name = item.autosaveName,
                  let number = Int(name.split(separator: ".").last ?? "") else { return nil }
            // Cmd-드래그나 저장된 위치로 번호와 실제 좌우 순서가 달라진 경우를 재현한다.
            let positions: [Int: CGFloat] = [0: 80, 1: 120, 2: 40]
            let position = positions[number] ?? 0
            return NSRect(x: position, y: 100, width: 24, height: 24)
        })
        defer { controller.tearDown() }
        let before = items.map { $0.button?.accessibilityLabel() }
        hasValidFrames = false
        controller.update()
        guard items.map({ $0.button?.accessibilityLabel() }) == before else {
            fail("일시적 좌표 누락이 기존 앱을 다른 슬롯으로 재배정")
        }
        hasValidFrames = true
        controller.update()
        guard items.map({ $0.button?.accessibilityLabel() }) == before else { fail("좌표 복구 후 앱 순서 변경") }
        print("통과: 실제 순서와 다른 슬롯 번호에서도 좌표 누락·복구 중 앱 연결 유지")
    }

    private static func verifyRequestedSizes(model: DockPresentationModel, controller: StatusItemController, button: NSStatusBarButton) {
        let original = model.preferences
        defer { model.preferences = original; controller.update() }
        model.preferences.slotWidth = 40
        var areas: [Int] = []
        for (index, requested) in [16.0, 20.0, 24.0, 28.0, 32.0].enumerated() {
            model.preferences.iconSize = requested
            controller.update()
            sendClick(button: button, type: .leftMouseDown, sequence: 100 + index)
            guard button.image?.size == NSSize(width: requested, height: requested),
                  let imageRect = button.cell?.imageRect(forBounds: button.bounds),
                  imageRect.size == NSSize(width: requested, height: requested), button.bounds.contains(imageRect),
                  let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { fail("요청한 \(requested)pt가 실제 렌더 영역과 다름") }
            button.cacheDisplay(in: button.bounds, to: bitmap)
            var opaquePixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                    opaquePixels += 1
                }
            }
            areas.append(opaquePixels)
            print("크기 회귀: 요청 \(requested)pt, 버튼 \(button.bounds.size), 실제 imageRect \(imageRect), 픽셀 면적 \(opaquePixels)")
        }
        guard zip(areas, areas.dropFirst()).allSatisfy({ pair in pair.0 < pair.1 }) else { fail("서로 다른 크기 설정의 실제 픽셀 면적이 증가하지 않음") }
        model.preferences.slotWidth = 22
        model.preferences.iconSize = 32
        controller.update()
        guard button.bounds.width == 32,
              button.cell?.imageRect(forBounds: button.bounds).size == NSSize(width: 32, height: 32) else {
            fail("좁은 슬롯에서 아이콘이 축소되거나 겹침")
        }
        print("통과: 16/20/24/28/32pt 실제 픽셀 면적 증가, 크기 변경 후 왼클릭, 좁은 슬롯 자동 확보")
    }

    private static func sendClick(button: NSStatusBarButton, type: NSEvent.EventType, flags: NSEvent.ModifierFlags = [], sequence: Int) {
        guard let window = button.window, let content = window.contentView else { fail("상태 창 없음") }
        button.layoutSubtreeIfNeeded()
        let location = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let hitPoint = content.superview?.convert(location, from: nil) ?? location
        guard content.hitTest(hitPoint) === button else { fail("hitTest가 독립 버튼에 도달하지 않음") }
        guard let down = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: sequence * 2 + 1, clickCount: 1, pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: type == .rightMouseDown ? .rightMouseUp : .leftMouseUp,
            location: location, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime + 0.001, windowNumber: window.windowNumber,
            context: nil, eventNumber: sequence * 2 + 2, clickCount: 1, pressure: 0
        ) else { fail("마우스 이벤트 생성 실패") }
        // target/action 직접 호출 없이 NSApplication → NSWindow → NSStatusBarButton 추적을 통과한다.
        NSApp.postEvent(up, atStart: true)
        NSApp.sendEvent(down)
    }

    /// 실제 시스템 버튼을 각각 cacheDisplay한 외관 참고 이미지다. 전체 메뉴 막대의 스크린샷은 아니다.
    private static func writeAppearanceSnapshot(buttons: [NSStatusBarButton], path: String) {
        let size = NSSize(width: buttons.reduce(0) { $0 + $1.bounds.width }, height: buttons.map(\.bounds.height).max() ?? 0)
        guard size.width > 0, size.height > 0 else { fail("외관 이미지 크기 없음") }
        let rendered = NSImage(size: size)
        rendered.lockFocus()
        var x: CGFloat = 0
        for button in buttons {
            guard let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { fail("버튼 bitmap 생성 실패") }
            button.cacheDisplay(in: button.bounds, to: bitmap)
            bitmap.draw(in: NSRect(x: x, y: 0, width: button.bounds.width, height: button.bounds.height))
            x += button.bounds.width
        }
        rendered.unlockFocus()
        guard let tiff = rendered.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { fail("PNG 변환 실패") }
        do { try data.write(to: URL(fileURLWithPath: path)) } catch { fail(error.localizedDescription) }
        print("버튼 외관 이미지: \(path) (\(bitmap.pixelsWide) × \(bitmap.pixelsHigh))")
    }
}

/// 실제 열린 메뉴를 짧게 추적한 뒤 선택하고 닫아 검증 중 사용자 입력을 요구하지 않는다.
@MainActor
private final class PopupRecorder: NSObject {
    var began = 0
    var ended = 0

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidBegin(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidEnd(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
    }

    @objc private func menuDidBegin(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu, settingsIndex(in: menu) != nil else { return }
        guard menu.items.map(\.title) == ["목록에 추가", "설정", "종료"],
              menu.items.allSatisfy({ !$0.isSeparatorItem && $0.keyEquivalent.isEmpty }) else {
            StatusInputCheck.fail("메뉴 순서 또는 간소화 구성 불일치")
        }
        began += 1
        let timer = Timer(timeInterval: 0.03, target: self, selector: #selector(selectAndClose(_:)), userInfo: menu, repeats: false)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    @objc private func selectAndClose(_ timer: Timer) {
        guard let menu = timer.userInfo as? NSMenu, let selectionIndex = settingsIndex(in: menu) else { return }
        menu.performActionForItem(at: selectionIndex)
        menu.cancelTrackingWithoutAnimation()
    }

    @objc private func menuDidEnd(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu, settingsIndex(in: menu) != nil else { return }
        ended += 1
    }

    private func settingsIndex(in menu: NSMenu) -> Int? {
        menu.items.firstIndex { item in
            guard let action = item.representedObject as? DockUIAction else { return false }
            if case .settings = action { return true }
            return false
        }
    }

    func tearDown() { NotificationCenter.default.removeObserver(self) }
}
