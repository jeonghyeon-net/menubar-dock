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
        var appearanceActions = 0
        var items: [NSStatusItem] = []
        // 외부 앱이나 설정 창을 실행하지 않는다. production controller가 전달한 명령만 기록한다.
        let model = DockPresentationModel(imageForApp: { NSWorkspace.shared.icon(forFile: $0.bundlePath) }) { action in
            switch action {
            case let .open(id): opened.append(id)
            case .settings: settingsActions += 1
            case .appearanceSettings: appearanceActions += 1
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
                guard imageSize.width <= min(button.bounds.width, CGFloat(model.preferences.slotWidth)) - 4,
                      imageSize.height <= button.bounds.height - 4 else { fail("\(entry.name) 아이콘이 버튼 영역을 벗어남") }
                print("크기: \(entry.name), 버튼 \(button.bounds.size), 아이콘 \(imageSize), 슬롯 \(model.preferences.slotWidth)")
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
            popups.selectionIndex = 1
            sendClick(button: first, type: .leftMouseDown, flags: .control, sequence: entries.count * 2)
            guard popups.began == entries.count + 1, popups.ended == entries.count + 1,
                  appearanceActions == 1, opened.count == entries.count else { fail("Control 클릭 표시 설정 불일치") }
            print("통과: Control 클릭 → 실제 메뉴 → 크기 및 간격 선택")
            // 접근성 API 호출 뒤 실제 전달된 AppID와 메뉴 개수로 결과를 판정한다.
            _ = first.accessibilityPerformPress()
            guard opened.count == entries.count + 1,
                  opened.last == entries.first?.id, popups.began == entries.count + 1 else {
                fail("접근성 press가 앱을 열지 않음: 현재 이벤트 \(String(describing: NSApp.currentEvent?.type))")
            }
            print("통과: 접근성 press → 앱 실행, 메뉴 없음")
            if let path = ProcessInfo.processInfo.environment["MENU_BAR_SNAPSHOT_PATH"] {
                writeAppearanceSnapshot(buttons: buttons, path: path)
            }
            popups.tearDown()
            controller.tearDown()
            exit(0)
        }
        app.run()
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
    var selectionIndex = 0

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidBegin(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidEnd(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
    }

    @objc private func menuDidBegin(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu, menu.item(at: 0)?.title == "설정…" else { return }
        began += 1
        let timer = Timer(timeInterval: 0.03, target: self, selector: #selector(selectAndClose(_:)), userInfo: menu, repeats: false)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    @objc private func selectAndClose(_ timer: Timer) {
        guard let menu = timer.userInfo as? NSMenu else { return }
        menu.performActionForItem(at: selectionIndex)
        menu.cancelTrackingWithoutAnimation()
    }

    @objc private func menuDidEnd(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu, menu.item(at: 0)?.title == "설정…" else { return }
        ended += 1
    }

    func tearDown() { NotificationCenter.default.removeObserver(self) }
}
