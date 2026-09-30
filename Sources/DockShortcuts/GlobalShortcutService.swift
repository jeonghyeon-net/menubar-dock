import AppKit
import Carbon.HIToolbox

@MainActor
protocol ShortcutRegistering: AnyObject {
    func register(_ binding: ShortcutBinding, action: ShortcutAction) throws
    func unregisterAll()
    func setHandler(_ handler: @escaping @MainActor (ShortcutAction, Bool) -> Void)
    func stop()
}

@MainActor
public final class GlobalShortcutService {
    private struct Preferences: Codable {
        var forward: ShortcutBinding = .forwardDefault
        var backward: ShortcutBinding = .backwardDefault
        var defaultsVersion: Int? = 2
    }

    private let defaults: UserDefaults
    private let backend: any ShortcutRegistering
    private let onCycle: (Int) -> Void
    private let prepareRegistration: ([ShortcutBinding]) throws -> (() throws -> Void)
    private var preferences: Preferences
    private var isEnabled = false
    private var isSuspended = false
    private var hasRegistrations = false
    private var registrationFailure: (any Error)?
    private var heldAction: ShortcutAction?
    private var suppressedActions: Set<ShortcutAction> = []
    private var repeatTimer: Timer?
    private var terminationObserver: NSObjectProtocol?
    private static let preferencesKey = "global-shortcuts.v1"

    public convenience init(
        defaults: UserDefaults = .standard,
        prepareRegistration: @escaping ([ShortcutBinding]) throws -> (() throws -> Void) = { _ in {} },
        onCycle: @escaping (Int) -> Void
    ) {
        self.init(defaults: defaults, backend: CarbonShortcutBackend(), prepareRegistration: prepareRegistration, onCycle: onCycle)
    }

    init(
        defaults: UserDefaults, backend: any ShortcutRegistering,
        prepareRegistration: @escaping ([ShortcutBinding]) throws -> (() throws -> Void) = { _ in {} },
        onCycle: @escaping (Int) -> Void
    ) {
        self.defaults = defaults
        self.backend = backend
        self.onCycle = onCycle
        self.prepareRegistration = prepareRegistration
        if let data = defaults.data(forKey: Self.preferencesKey),
           var saved = try? JSONDecoder().decode(Preferences.self, from: data),
           (try? Self.validate(saved)) != nil {
            if saved.defaultsVersion == nil {
                let oldForward = ShortcutBinding(keyCode: 48, modifiers: UInt64(NSEvent.ModifierFlags.option.rawValue), character: "⇥")
                let oldBackward = ShortcutBinding(keyCode: 48, modifiers: UInt64(NSEvent.ModifierFlags([.option, .shift]).rawValue), character: "⇥")
                // 두 방향 모두 이전 기본값인 경우만 옮겨 사용자 지정 조합을 보존한다.
                if saved.forward.hasSameCombination(as: oldForward), saved.backward.hasSameCombination(as: oldBackward) {
                    saved = Preferences()
                }
                saved.defaultsVersion = 2
                if let encoded = try? JSONEncoder().encode(saved) { defaults.set(encoded, forKey: Self.preferencesKey) }
            }
            preferences = saved
        } else {
            preferences = Preferences()
        }
        backend.setHandler { [weak self] action, isPressed in self?.receive(action, isPressed: isPressed) }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    isolated deinit { stop() }

    public func setEnabled(_ enabled: Bool) throws {
        guard isEnabled != enabled else {
            if let registrationFailure { throw registrationFailure }
            return
        }
        cancelRepeat()
        isEnabled = enabled
        registrationFailure = nil
        if enabled, !isSuspended {
            do { try register(preferences) }
            catch {
                registrationFailure = error
                throw error
            }
        } else {
            backend.unregisterAll()
            hasRegistrations = false
        }
    }

    public func setBinding(_ binding: ShortcutBinding, for action: ShortcutAction) throws {
        var proposed = preferences
        switch action {
        case .forward: proposed.forward = binding
        case .backward: proposed.backward = binding
        }
        try replace(with: proposed)
    }

    public func reset() throws { try replace(with: Preferences()) }

    public func binding(for action: ShortcutAction) -> ShortcutBinding {
        switch action {
        case .forward: preferences.forward
        case .backward: preferences.backward
        }
    }

    public func suspend(_ suspended: Bool) throws {
        guard isSuspended != suspended else { return }
        cancelRepeat()
        isSuspended = suspended
        if suspended {
            backend.unregisterAll()
            hasRegistrations = false
        } else if isEnabled {
            do {
                try register(preferences)
                registrationFailure = nil
            } catch {
                registrationFailure = error
                throw error
            }
        }
    }

    /// 선택 패널을 닫을 때 현재 키 누름이 패널을 다시 열지 않도록 해제까지 소비한다.
    public func cancelCurrentPress() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        if let heldAction { suppressedActions.insert(heldAction) }
        heldAction = nil
    }

    public func stop() {
        cancelRepeat()
        backend.stop()
        isEnabled = false
        isSuspended = false
        hasRegistrations = false
        registrationFailure = nil
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
            terminationObserver = nil
        }
    }

    private func replace(with proposed: Preferences) throws {
        try Self.validate(proposed)
        let encoded = try JSONEncoder().encode(proposed)
        cancelRepeat()
        if isEnabled, !isSuspended {
            let shouldRestore = hasRegistrations
            backend.unregisterAll()
            hasRegistrations = false
            do {
                try register(proposed)
                registrationFailure = nil
            } catch {
                let proposedError = error
                if shouldRestore {
                    do {
                        try register(preferences)
                        registrationFailure = nil
                    } catch {
                        registrationFailure = ShortcutError.rollbackFailed
                        throw ShortcutError.rollbackFailed
                    }
                } else {
                    registrationFailure = proposedError
                }
                throw proposedError
            }
        } else if isEnabled {
            // 기록 중에는 잠시 시험 등록하여 충돌을 확인하고 즉시 다시 해제한다.
            try register(proposed)
            backend.unregisterAll()
            hasRegistrations = false
        }
        preferences = proposed
        registrationFailure = nil
        defaults.set(encoded, forKey: Self.preferencesKey)
    }

    private func register(_ preferences: Preferences) throws {
        let rollbackSystemSettings = try prepareRegistration([preferences.forward, preferences.backward])
        do {
            try backend.register(preferences.forward, action: .forward)
            try backend.register(preferences.backward, action: .backward)
            hasRegistrations = true
        } catch {
            backend.unregisterAll()
            hasRegistrations = false
            do { try rollbackSystemSettings() }
            catch { throw ShortcutError.rollbackFailed }
            throw error
        }
    }

    private static func validate(_ preferences: Preferences) throws {
        try preferences.forward.validate()
        try preferences.backward.validate()
        guard !preferences.forward.hasSameCombination(as: preferences.backward) else {
            throw ShortcutError.duplicateCombination
        }
    }

    private func receive(_ action: ShortcutAction, isPressed: Bool) {
        guard isEnabled, !isSuspended, hasRegistrations else { return }
        if !isPressed {
            suppressedActions.remove(action)
            if heldAction == action { cancelRepeat() }
            return
        }
        // 취소된 누름이 남아 있는 동안 다른 방향을 겹쳐 눌러도 새 선택을 시작하지 않는다.
        // 겹친 조합도 각자의 release를 받아야 다음 독립된 입력을 허용한다.
        guard suppressedActions.isEmpty else {
            suppressedActions.insert(action)
            return
        }
        guard heldAction != action else { return }
        cancelRepeat()
        heldAction = action
        onCycle(action == .forward ? 1 : -1)
        guard isEnabled, !isSuspended, heldAction == action else { return }
        // 키를 누르는 동안만 타이머를 소유하며 해제/중지 시 즉시 없앤다.
        let timer = Timer(
            fire: Date(timeIntervalSinceNow: max(0.25, NSEvent.keyRepeatDelay)),
            interval: max(0.05, NSEvent.keyRepeatInterval),
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let action = self.heldAction, self.isEnabled, !self.isSuspended else { return }
                self.onCycle(action == .forward ? 1 : -1)
            }
        }
        repeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        heldAction = nil
        suppressedActions.removeAll()
    }
}

@MainActor
private final class CarbonShortcutBackend: ShortcutRegistering {
    private static let signature: OSType = 0x4D42444B
    private var references: [ShortcutAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var handler: (@MainActor (ShortcutAction, Bool) -> Void)?

    isolated deinit { stop() }

    func setHandler(_ handler: @escaping @MainActor (ShortcutAction, Bool) -> Void) {
        self.handler = handler
    }

    func register(_ binding: ShortcutBinding, action: ShortcutAction) throws {
        try installHandlerIfNeeded()
        var reference: EventHotKeyRef?
        let keyID = EventHotKeyID(signature: Self.signature, id: action == .forward ? 1 : 2)
        // 비독점 등록은 타 앱의 독점 등록에 가려져도 성공하므로 충돌을 감지할 수 없다.
        let status = RegisterEventHotKey(
            binding.keyCode, Self.carbonModifiers(binding.modifiers), keyID,
            GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &reference
        )
        // Spotlight를 시스템 설정에서 해제해도 macOS가 조합의 독점권을 유지할 수 있다.
        // 해당 기본 조합만 일반 등록을 허용하며 나머지 키의 충돌 검사는 유지한다.
        var result = status
        if status == eventHotKeyExistsErr, binding.hasSameCombination(as: .forwardDefault) {
            var hotkeys: Unmanaged<CFArray>?
            let copied = CopySymbolicHotKeys(&hotkeys)
            let values = hotkeys?.takeRetainedValue() as? [[String: Any]]
            let systemUsesCommandSpace = values?.contains {
                ($0[kHISymbolicHotKeyCode as String] as? UInt32) == binding.keyCode
                    && ($0[kHISymbolicHotKeyModifiers as String] as? UInt32) == Self.carbonModifiers(binding.modifiers)
                    && ($0[kHISymbolicHotKeyEnabled as String] as? Bool) == true
            } ?? true
            if copied == noErr, !systemUsesCommandSpace {
                result = RegisterEventHotKey(binding.keyCode, Self.carbonModifiers(binding.modifiers), keyID,
                                            GetEventDispatcherTarget(), 0, &reference)
            }
        }
        guard result == noErr, let reference else { throw ShortcutError.registrationFailed(result) }
        references[action] = reference
    }

    func unregisterAll() {
        for reference in references.values { UnregisterEventHotKey(reference) }
        references.removeAll()
    }

    func stop() {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    private func installHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                // 애플리케이션 event target은 등록한 주 실행 루프에서 호출한다.
                return MainActor.assumeIsolated {
                    Unmanaged<CarbonShortcutBackend>.fromOpaque(context).takeUnretainedValue().receive(event)
                }
            }, events.count, &events, context, &eventHandler
        )
        guard status == noErr else { throw ShortcutError.registrationFailed(status) }
    }

    private func receive(_ event: EventRef) -> OSStatus {
        var keyID = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &keyID
        )
        guard status == noErr, keyID.signature == Self.signature,
              let action = keyID.id == 1 ? ShortcutAction.forward : keyID.id == 2 ? ShortcutAction.backward : nil,
              references[action] != nil
        else { return OSStatus(eventNotHandledErr) }
        handler?(action, GetEventKind(event) == UInt32(kEventHotKeyPressed))
        return noErr
    }

    private static func carbonModifiers(_ raw: UInt64) -> UInt32 {
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(raw))
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
