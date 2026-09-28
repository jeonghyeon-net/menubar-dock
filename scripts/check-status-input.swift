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
        var items: [NSStatusItem] = []
        // 외부 앱은 실행하지 않는다. production controller가 전달한 AppID만 경계에서 기록한다.
        let model = DockPresentationModel(imageForApp: { NSWorkspace.shared.icon(forFile: $0.bundlePath) }) {
            if case let .open(id) = $0 { opened.append(id) }
        }
        model.preferences.maxVisibleApps = entries.count
        model.items = entries.map { DockItem(app: $0, isRunning: false) }
        let controller = StatusItemController(model: model, makeStatusItem: { length in
            let item = NSStatusBar.system.statusItem(withLength: length)
            items.append(item)
            return item
        })
        // GUI 세션이 없는 환경에서도 영원히 입력을 기다리지 않는 일회성 종료 제한이다.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            print("실패: AppKit 입력 검증 제한 시간 초과. 로그인된 macOS GUI 세션에서 실행해 주세요.")
            exit(1)
        }
        // 시스템 상태 항목의 최초 레이아웃이 완료될 한 번의 실행 구간을 준다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            var buttons: [NSStatusBarButton] = []
            for (index, entry) in entries.enumerated() {
                guard let button = items.first(where: { $0.button?.accessibilityLabel() == entry.name })?.button,
                      let window = button.window, let content = window.contentView else { fail("\(entry.name) 상태 버튼 없음") }
                button.layoutSubtreeIfNeeded()
                let location = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                let hitPoint = content.superview?.convert(location, from: nil) ?? location
                guard content.hitTest(hitPoint) === button else { fail("\(entry.name) hitTest가 독립 버튼에 도달하지 않음") }
                guard let down = NSEvent.mouseEvent(
                    with: .leftMouseDown, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: index * 2 + 1, clickCount: 1, pressure: 1
                ), let up = NSEvent.mouseEvent(
                    with: .leftMouseUp, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime + 0.001, windowNumber: window.windowNumber,
                    context: nil, eventNumber: index * 2 + 2, clickCount: 1, pressure: 0
                ) else { fail("마우스 이벤트 생성 실패") }
                // target/action 직접 호출 없이 NSApplication → NSWindow → NSStatusBarButton 추적을 통과한다.
                app.postEvent(up, atStart: true)
                app.sendEvent(down)
                guard opened.count == index + 1, opened.last == entry.id else { fail("\(entry.name) 클릭 명령 불일치") }
                buttons.append(button)
            }
            guard opened == entries.map(\.id) else { fail("앱 클릭 순서 불일치") }
            print("통과: 독립 NSStatusItem \(entries.count)개의 hitTest → mouseDown → mouseUp → AppID 전달")
            if let path = ProcessInfo.processInfo.environment["MENU_BAR_SNAPSHOT_PATH"] {
                writeAppearanceSnapshot(buttons: buttons, path: path)
            }
            controller.tearDown()
            exit(0)
        }
        app.run()
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
