import Foundation

/// Spotlight의 ⌘ Space 설정만 해제한다. 다른 시스템 단축키와 사용자 지정 키는 보존한다.
@MainActor
public final class SpotlightShortcutOverride {
    private let read: () throws -> [String: Any]
    private let write: ([String: Any]) throws -> Void
    private let apply: () throws -> Void

    public convenience init() {
        let domain = "com.apple.symbolichotkeys" as CFString
        let key = "AppleSymbolicHotKeys" as CFString
        self.init(read: {
            guard CFPreferencesAppSynchronize(domain) else { throw SpotlightOverrideError.preferences }
            guard let value = CFPreferencesCopyAppValue(key, domain) else { return [:] }
            guard let hotkeys = value as? [String: Any] else { throw SpotlightOverrideError.preferences }
            return hotkeys
        }, write: { hotkeys in
            CFPreferencesSetAppValue(key, hotkeys as CFDictionary, domain)
            guard CFPreferencesAppSynchronize(domain) else { throw SpotlightOverrideError.preferences }
        }, apply: Self.applySettings)
    }

    init(read: @escaping () throws -> [String: Any], write: @escaping ([String: Any]) throws -> Void,
         apply: @escaping () throws -> Void) {
        self.read = read
        self.write = write
        self.apply = apply
    }

    /// 등록이 실패하면 반환한 복구 작업으로 이번 변경만 되돌린다.
    public func prepare() throws -> (() throws -> Void) {
        var hotkeys = try read()
        let original = hotkeys["64"]
        let defaultEntry: [String: Any] = [
            "enabled": true,
            "value": ["type": "standard", "parameters": [32, 49, 1_048_576]],
        ]
        guard var entry = (original ?? defaultEntry) as? [String: Any] else { throw SpotlightOverrideError.preferences }
        guard (entry["enabled"] as? Bool) != false else { return {} }
        let value = entry["value"] as? [String: Any] ?? defaultEntry["value"] as? [String: Any]
        guard let parameters = value?["parameters"] as? [Int], parameters.count == 3 else {
            throw SpotlightOverrideError.preferences
        }
        guard parameters[1] == 49, parameters[2] == 1_048_576 else { return {} }
        entry["enabled"] = false
        hotkeys["64"] = entry
        let appliedEntry = entry as NSDictionary
        let rollback: () throws -> Void = { [self] in
            var current = try read()
            // 적용 뒤 사용자가 바꾼 값과 다른 시스템 항목은 덮어쓰지 않는다.
            guard let currentEntry = current["64"] as? NSDictionary, currentEntry == appliedEntry else { return }
            current["64"] = original
            try write(current)
            try apply()
        }
        do {
            try write(hotkeys)
            try apply()
        } catch {
            do { try rollback() }
            catch { throw SpotlightOverrideError.rollback }
            throw error
        }
        return rollback
    }

    private static func applySettings() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath:
            "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        process.arguments = ["-u"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        do { try process.run() }
        catch { throw SpotlightOverrideError.activation }
        guard completion.wait(timeout: .now() + 3) == .success else {
            process.terminate()
            throw SpotlightOverrideError.activation
        }
        guard process.terminationStatus == 0 else { throw SpotlightOverrideError.activation }
    }
}

public enum SpotlightOverrideError: LocalizedError, Equatable {
    case preferences, activation, rollback

    public var errorDescription: String? {
        switch self {
        case .preferences: "Spotlight 단축키 설정을 변경하지 못했습니다. 시스템 설정 → 키보드 → 키보드 단축키 → Spotlight에서 Spotlight 검색 보기를 꺼 주세요."
        case .activation: "Spotlight 단축키 변경을 적용하지 못했습니다. 시스템 설정에서 Spotlight 검색 보기 단축키를 끈 뒤 앱을 다시 실행해 주세요."
        case .rollback: "Spotlight 단축키 설정을 복구하지 못했습니다. 시스템 설정의 Spotlight 검색 보기 단축키를 확인해 주세요."
        }
    }
}
