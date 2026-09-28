import AppKit
import DockDomain

/// 실제 NSSlider 추적 중 모델 갱신이 손잡이 좌표를 덮어쓰는지 검사한다.
@main
@MainActor
struct SettingsInputCheck {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
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
