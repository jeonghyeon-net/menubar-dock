import AppKit

public enum ShortcutAction: String, Codable, CaseIterable, Sendable {
    case forward
    case backward
}

public struct ShortcutBinding: Codable, Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt64
    public let character: String

    public init(keyCode: UInt32, modifiers: UInt64, character: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.supportedModifiers
        self.character = String(character.prefix(8))
    }

    public static let forwardDefault = ShortcutBinding(
        keyCode: 48, modifiers: UInt64(NSEvent.ModifierFlags.option.rawValue), character: "⇥"
    )
    public static let backwardDefault = ShortcutBinding(
        keyCode: 48, modifiers: UInt64(NSEvent.ModifierFlags([.option, .shift]).rawValue), character: "⇥"
    )

    public var displayName: String {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        return (flags.contains(.control) ? "⌃" : "")
            + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "")
            + (flags.contains(.command) ? "⌘" : "")
            + (Self.specialCharacters[keyCode] ?? character.uppercased())
    }

    @MainActor
    public static func from(event: NSEvent) -> Self? {
        guard event.type == .keyDown, event.keyCode <= 127 else { return nil }
        let binding = Self(
            keyCode: UInt32(event.keyCode),
            modifiers: UInt64(event.modifierFlags.rawValue),
            character: Self.specialCharacters[UInt32(event.keyCode)] ?? event.charactersIgnoringModifiers ?? ""
        )
        guard (try? binding.validate()) != nil else { return nil }
        return binding
    }

    func validate() throws {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        guard keyCode <= 127,
              !Set<UInt32>([54, 55, 56, 57, 58, 59, 60, 61, 62, 63]).contains(keyCode),
              !flags.intersection([.command, .control, .option]).isEmpty,
              !character.isEmpty,
              character.count <= 8,
              modifiers & ~Self.supportedModifiers == 0
        else { throw ShortcutError.invalidCombination }
        // 앱 전환/종료/강제 종료/화면 잠금과 같은 시스템 기본 조합은 가로채지 않는다.
        if flags.contains(.command), [12, 13, 4, 46, 48, 49, 53].contains(keyCode) {
            throw ShortcutError.reservedCombination
        }
        if flags == .control, [49, 123, 124, 125, 126].contains(keyCode) {
            throw ShortcutError.reservedCombination
        }
    }

    func hasSameCombination(as other: Self) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    private static let supportedModifiers = UInt64(NSEvent.ModifierFlags([.command, .control, .option, .shift]).rawValue)
    private static let specialCharacters: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 76: "⌤", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
        107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
}

public enum ShortcutError: LocalizedError, Equatable, Sendable {
    case invalidCombination
    case reservedCombination
    case duplicateCombination
    case registrationFailed(Int32)
    case rollbackFailed

    public var errorDescription: String? {
        switch self {
        case .invalidCombination: "Command, Control, Option 중 하나와 일반 키를 함께 눌러 주세요."
        case .reservedCombination: "macOS의 기본 동작에 사용하는 단축키입니다. 다른 조합을 선택해 주세요."
        case .duplicateCombination: "다음 앱과 이전 앱에 서로 다른 단축키를 지정해 주세요."
        case .registrationFailed: "단축키를 등록하지 못했습니다. 다른 앱에서 사용 중인지 확인하거나 조합을 바꿔 주세요."
        case .rollbackFailed: "기존 단축키를 복구하지 못했습니다. 단축키를 다시 켜거나 다른 조합을 지정해 주세요."
        }
    }
}
