import AppKit
import DockDomain

/// 실제 NSSlider 추적 중 모델 갱신이 손잡이 좌표를 덮어쓰는지 검사한다.
@main
@MainActor
struct SettingsInputCheck {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let snapshotPath: String?
        if arguments.count == 2, arguments[0] == "--snapshot", !arguments[1].isEmpty {
            snapshotPath = arguments[1]
        } else if arguments.isEmpty || arguments == ["--spacing"] {
            snapshotPath = nil
        } else {
            print("사용법: check-settings-input [--spacing | --snapshot <PNG 경로>]")
            exit(1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        if let snapshotPath {
            let snapshot = SettingsSnapshot()
            snapshot.settings.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                snapshot.write(to: URL(fileURLWithPath: snapshotPath))
            }
            app.run()
            return
        }
        let probe = SliderProbe()
        probe.settings.show()
        guard !descendants(probe.settings.window?.contentView).contains(where: { $0 is NSTabView }) else {
            print("실패: 설정 창에 탭이 남아 있습니다.")
            exit(1)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            print("실패: 설정 입력 검사 제한 시간 초과")
            exit(1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { probe.run() }
        app.run()
    }
}

/// 문서 이미지는 개인 화면 대신 고정된 시스템 앱만 넣은 실제 설정 뷰에서 만든다.
@MainActor
private final class SettingsSnapshot {
    let model: DockPresentationModel
    let settings: SettingsWindowController

    init() {
        let safariPaths = [
            "/Applications/Safari.app", "/System/Applications/Safari.app",
            "/System/Cryptexes/App/System/Applications/Safari.app"
        ]
        let safariPath = URL(fileURLWithPath: safariPaths.first { FileManager.default.fileExists(atPath: $0) } ?? safariPaths[0])
            .resolvingSymlinksInPath().standardizedFileURL.path
        model = DockPresentationModel(imageForApp: { NSWorkspace.shared.icon(forFile: $0.bundlePath) }, perform: { _ in })
        model.apps = [
            AppEntry(id: AppID(rawValue: "snapshot.finder"), name: "Finder", bundleIdentifier: "com.apple.finder",
                     bundlePath: "/System/Library/CoreServices/Finder.app", isPinned: true),
            AppEntry(id: AppID(rawValue: "snapshot.safari"), name: "Safari", bundleIdentifier: "com.apple.Safari",
                     bundlePath: safariPath, isPinned: true),
            AppEntry(id: AppID(rawValue: "snapshot.terminal"), name: "Terminal", bundleIdentifier: "com.apple.Terminal",
                     bundlePath: "/System/Applications/Utilities/Terminal.app", isPinned: true),
            AppEntry(id: AppID(rawValue: "snapshot.notes"), name: "Notes", bundleIdentifier: "com.apple.Notes",
                     bundlePath: "/System/Applications/Notes.app", isPinned: true),
            AppEntry(id: AppID(rawValue: "snapshot.preview"), name: "Preview", bundleIdentifier: "com.apple.Preview",
                     bundlePath: "/System/Applications/Preview.app", isPinned: true),
            AppEntry(id: AppID(rawValue: "snapshot.settings"), name: "System Settings", bundleIdentifier: "com.apple.systempreferences",
                     bundlePath: "/System/Applications/System Settings.app", isPinned: true)
        ]
        settings = SettingsWindowController(model: model)
        // 기존 프레임 자동 저장 값이 문서 이미지 크기를 바꾸지 않게 한다.
        settings.window?.setContentSize(NSSize(width: 540, height: 600))
    }

    func write(to url: URL) {
        guard let content = settings.window?.contentView else { fail("설정 뷰 없음") }
        // 시스템 창 배경까지 함께 그려 투명한 본문 위의 텍스트가 사라지지 않게 한다.
        let view = content.superview ?? content
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fail("설정 비트맵 생성 실패") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fail("PNG 변환 실패") }
        do {
            try png.write(to: url, options: .atomic)
            print("통과: 시스템 앱 \(model.apps.count)개의 실제 설정 뷰 PNG 저장")
            settings.close()
            exit(0)
        } catch {
            fail("PNG 저장 실패: \(error.localizedDescription)")
        }
    }

    private func fail(_ message: String) -> Never {
        print("실패: \(message)")
        exit(1)
    }
}

@MainActor
private final class SliderProbe: NSObject {
    lazy var model: DockPresentationModel = DockPresentationModel(imageForApp: { _ in NSImage() }) { [weak self] action in
        guard let self, case let .preferences(value) = action else { return }
        model.preferences = value.normalized()
    }
    lazy var settings = SettingsWindowController(model: model)
    private var slider: NSSlider?
    private var originalTarget: AnyObject?
    private var originalAction: Selector?
    private var nativeValue: Double?
    private var observedValues: [Double] = []
    private var echoes: [(Double, Double)] = []
    private var changedFrames = 0
    private var trackingSamples = 0
    private var frame = NSRect.zero
    private var step = 0
    private var timer: Timer?
    private let checksSpacing = CommandLine.arguments.contains("--spacing")
    private let positions: [CGFloat] = [0.08, 0.17, 0.29, 0.42, 0.57, 0.69, 0.83, 0.96, 1.3, 1.6, 0.73, 0.31, -0.4, -0.8, 0.47, 0.62]

    func run() {
        guard let window = settings.window else { fail("설정 창 없음") }
        window.contentView?.layoutSubtreeIfNeeded()
        guard let slider = descendants(window.contentView).compactMap({ $0 as? NSSlider }).first(where: {
            $0.accessibilityLabel() == (checksSpacing ? "아이콘 간격" : "아이콘 크기")
        }), let cell = slider.cell as? NSSliderCell else { fail("아이콘 크기 슬라이더 없음") }
        self.slider = slider
        originalTarget = slider.target
        originalAction = slider.action
        slider.target = self
        slider.action = #selector(recordAction(_:))
        frame = slider.convert(slider.bounds, to: nil)
        let knob = cell.knobRect(flipped: slider.isFlipped)
        let downPoint = slider.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil)
        timer = Timer(timeInterval: 0.02, target: self, selector: #selector(advance), userInfo: nil, repeats: true)
        if let timer {
            RunLoop.main.add(timer, forMode: .eventTracking)
            RunLoop.main.add(timer, forMode: .default)
        }
        NSApp.postEvent(event(.leftMouseDragged, location: NSPoint(x: frame.minX + frame.width * 0.08, y: frame.midY)), atStart: true)
        NSApp.sendEvent(event(.leftMouseDown, location: downPoint))
    }

    @objc private func recordAction(_ sender: NSSlider) {
        // 실제 시스템 control action을 기록한 다음 원래 제품 target/action에 그대로 전달한다.
        if (sender as? TrackingPreferenceSlider)?.isTrackingPreference == true { trackingSamples += 1 }
        nativeValue = sender.doubleValue
        observedValues.append(sender.doubleValue)
        if let originalAction { _ = NSApp.sendAction(originalAction, to: originalTarget, from: sender) }
    }

    private func finish() {
        guard let slider else { fail("완료 시 슬라이더 없음") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            guard self.observedValues.count >= 10 else { self.fail("드래그 경로 미실행: action \(self.observedValues.count)회, step \(self.step), values \(self.observedValues)") }
            guard self.observedValues.contains(where: { $0 == slider.maxValue }),
                  self.observedValues.contains(where: { $0 == slider.minValue }) else { self.fail("트랙 바깥 양끝 이동 미실행: \(self.observedValues)") }
            guard self.echoes.isEmpty else { self.fail("드래그 중 손잡이 값 덮어쓰기 \(self.echoes.count)회: \(self.echoes.prefix(3))") }
            guard self.changedFrames == 0 else { self.fail("드래그 중 슬라이더 레이아웃 변경 \(self.changedFrames)회") }
            guard self.trackingSamples > 0 else { self.fail("시스템 추적 수명 콜백 미실행") }
            guard (slider as? TrackingPreferenceSlider)?.isTrackingPreference == false else { self.fail("mouseup 뒤 추적 상태 미해제") }
            let savedValue = self.checksSpacing
                ? self.model.preferences.slotWidth - self.model.preferences.iconSize
                : self.model.preferences.iconSize
            guard slider.doubleValue == savedValue else { self.fail("최종 값 저장 불일치: \(slider.doubleValue) / \(savedValue)") }
            print("통과: \(self.checksSpacing ? "아이콘 간격" : "아이콘 크기") native long drag \(self.observedValues.count)회, 트랙 밖 양끝, 관련 없는 모델 변경, 손잡이·프레임 안정, 최종값 저장")
            self.settings.close()
            exit(0)
        }
    }

    @objc private func advance() {
        guard let slider else { fail("추적 중 슬라이더 없음") }
        if let nativeValue, abs(slider.doubleValue - nativeValue) > 0.00001 {
            echoes.append((nativeValue, slider.doubleValue))
        }
        if slider.convert(slider.bounds, to: nil) != frame { changedFrames += 1 }
        // 앱 목록이나 단축키 상태가 달라져도 전체 설정 화면은 갱신된다.
        model.forwardShortcut = "입력 검사 \(step)"
        guard step < positions.count else {
            NSApp.postEvent(event(.leftMouseUp, location: NSPoint(x: frame.midX, y: frame.midY)), atStart: true)
            timer?.invalidate()
            finish()
            return
        }
        let point = NSPoint(x: frame.minX + positions[step] * frame.width, y: frame.midY)
        NSApp.postEvent(event(.leftMouseDragged, location: point), atStart: true)
        step += 1
    }

    private func event(_ type: NSEvent.EventType, location: NSPoint) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: settings.window?.windowNumber ?? 0,
            context: nil, eventNumber: step + 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        ) else { fail("입력 이벤트 생성 실패") }
        return event
    }

    private func fail(_ message: String) -> Never {
        print("실패: \(message)")
        exit(1)
    }
}

@MainActor
private func descendants(_ view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap { descendants($0) }
}
