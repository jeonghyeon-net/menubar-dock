import Foundation
import Testing
@testable import DockPlatform

@MainActor
struct SpotlightShortcutOverrideTests {
    @Test("기본 Spotlight만 해제하고 다른 설정과 원래 키 값을 보존한다")
    func preservesOtherSettings() throws {
        let fixture = OverrideFixture()
        let original = fixture.values as NSDictionary
        let rollback = try fixture.service.prepare()
        #expect((fixture.values["64"] as? [String: Any])?["enabled"] as? Bool == false)
        #expect((fixture.values["64"] as? [String: Any])?["value"] as? NSDictionary == OverrideFixture.spotlight["value"] as? NSDictionary)
        #expect(fixture.values["65"] as? String == "보존")
        #expect(fixture.applyCount == 1)
        try rollback()
        #expect(fixture.values as NSDictionary == original)
        #expect(fixture.applyCount == 2)
    }

    @Test("설정 파일에 없는 기본 Spotlight도 해제하고 실패 시 원래의 부재를 복원한다")
    func handlesImplicitDefaults() throws {
        let fixture = OverrideFixture()
        fixture.values.removeValue(forKey: "64")
        let rollback = try fixture.service.prepare()
        #expect((fixture.values["64"] as? [String: Any])?["enabled"] as? Bool == false)
        try rollback()
        #expect(fixture.values["64"] == nil)
        #expect(fixture.values["65"] as? String == "보존")
    }

    @Test("이미 끈 Spotlight와 사용자 지정 Spotlight 조합에는 쓰기나 적용을 하지 않는다")
    func skipsDisabledAndCustomShortcuts() throws {
        for entry: [String: Any] in [
            ["enabled": false],
            ["enabled": true, "value": ["parameters": [32, 49, 1_572_864]]],
        ] {
            let fixture = OverrideFixture()
            fixture.values["64"] = entry
            let rollback = try fixture.service.prepare()
            try rollback()
            #expect(fixture.writeCount == 0)
            #expect(fixture.applyCount == 0)
        }
    }

    @Test("시스템 적용 실패는 이번 변경을 복구하고 오류를 반환한다")
    func restoresOnApplyFailure() throws {
        let fixture = OverrideFixture()
        fixture.failApply = [1]
        let original = fixture.values as NSDictionary
        #expect(throws: SpotlightOverrideError.activation) { try fixture.service.prepare() }
        #expect(fixture.values as NSDictionary == original)
        #expect(fixture.applyCount == 2)
    }

    @Test("복구 중 동시 변경된 다른 키와 사용자가 다시 지정한 Spotlight 키를 보존한다")
    func rollbackPreservesConcurrentChanges() throws {
        let fixture = OverrideFixture()
        let rollback = try fixture.service.prepare()
        fixture.values["65"] = "새 설정"
        try rollback()
        #expect(fixture.values["65"] as? String == "새 설정")
        let secondRollback = try fixture.service.prepare()
        fixture.values["64"] = ["enabled": true, "value": ["parameters": [32, 49, 1_572_864]]]
        let changed = fixture.values as NSDictionary
        try secondRollback()
        #expect(fixture.values as NSDictionary == changed)
    }

    @Test("잘못된 설정이나 저장 실패를 성공으로 취급하지 않는다")
    func rejectsInvalidOrUnwritablePreferences() {
        let fixture = OverrideFixture()
        fixture.values["64"] = "손상"
        #expect(throws: SpotlightOverrideError.preferences) { try fixture.service.prepare() }
        #expect(fixture.writeCount == 0)
        fixture.values["64"] = OverrideFixture.spotlight
        fixture.failWrite = true
        #expect(throws: SpotlightOverrideError.preferences) { try fixture.service.prepare() }
        #expect(fixture.applyCount == 0)
    }
}

@MainActor
private final class OverrideFixture {
    static let spotlight: [String: Any] = [
        "enabled": true, "value": ["type": "standard", "parameters": [65535, 49, 1_048_576]],
    ]
    var values: [String: Any] = ["64": spotlight, "65": "보존"]
    var writeCount = 0
    var applyCount = 0
    var failWrite = false
    var failApply: Set<Int> = []
    lazy var service = SpotlightShortcutOverride(read: { [unowned self] in values }, write: { [unowned self] in
        writeCount += 1
        if failWrite { throw SpotlightOverrideError.preferences }
        values = $0
    }, apply: { [unowned self] in
        applyCount += 1
        if failApply.contains(applyCount) { throw SpotlightOverrideError.activation }
    })
}
