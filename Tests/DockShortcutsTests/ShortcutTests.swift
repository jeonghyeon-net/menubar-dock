import AppKit
import Foundation
import Testing
@testable import DockShortcuts

@MainActor
struct ShortcutTests {
    @Test("기본 조합은 Option Tab과 역방향이며 실제 키 이벤트에서 복원된다")
    func defaultBindingsAndInput() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option, .shift, .capsLock],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48
        ))
        #expect(ShortcutBinding.from(event: event) == .backwardDefault)
        #expect(ShortcutBinding.forwardDefault.displayName == "⌥⇥")
        #expect(ShortcutBinding.backwardDefault.displayName == "⌥⇧⇥")
    }

    @Test("수정 키 없는 조합과 앱 종료 같은 예약 조합을 거절한다")
    func rejectsUnsafeCombinations() {
        let plain = ShortcutBinding(keyCode: 0, modifiers: 0, character: "A")
        let quit = binding(keyCode: 12, modifiers: [.command], character: "Q")
        let switcher = binding(keyCode: 48, modifiers: [.command], character: "⇥")
        #expect(throws: ShortcutError.invalidCombination) { try plain.validate() }
        #expect(throws: ShortcutError.reservedCombination) { try quit.validate() }
        #expect(throws: ShortcutError.reservedCombination) { try switcher.validate() }
    }

    @Test("같은 상태를 반복 적용해도 등록을 반복하거나 기존 키를 잃지 않는다")
    func enablingIsIdempotent() throws {
        let fixture = try ShortcutFixture()
        let service = GlobalShortcutService(defaults: fixture.defaults, backend: fixture.backend) { _ in }
        defer { service.stop() }
        try service.setEnabled(true)
        try service.setEnabled(true)
        #expect(fixture.backend.registrationCount == 2)
        #expect(fixture.backend.registered.count == 2)
        try service.setEnabled(false)
        #expect(fixture.backend.registered.isEmpty)
    }

    @Test("초기 역방향 등록이 충돌하면 정방향도 해제하고 실패를 전달한다")
    func initialConflictDoesNotPartiallyEnable() throws {
        let fixture = try ShortcutFixture()
        fixture.backend.failureCalls = [2]
        let service = GlobalShortcutService(defaults: fixture.defaults, backend: fixture.backend) { _ in }
        defer { service.stop() }
        #expect(throws: ShortcutError.registrationFailed(-9878)) { try service.setEnabled(true) }
        #expect(fixture.backend.registered.isEmpty)
        fixture.backend.failureCalls = []
        #expect(throws: ShortcutError.registrationFailed(-9878)) { try service.setEnabled(true) }
        #expect(fixture.backend.registrationCount == 2)
        try service.setEnabled(false)
        try service.setEnabled(true)
        #expect(fixture.backend.registered.count == 2)
    }

    @Test("표시 문자열이 달라도 같은 키 조합은 양 방향에 중복 지정할 수 없다")
    func rejectsDuplicateBindings() throws {
        let fixture = try ShortcutFixture()
        let service = GlobalShortcutService(defaults: fixture.defaults, backend: fixture.backend) { _ in }
        defer { service.stop() }
        let duplicate = binding(keyCode: 48, modifiers: [.option], character: "다른 표시")
        #expect(throws: ShortcutError.duplicateCombination) {
            try service.setBinding(duplicate, for: .backward)
        }
        #expect(service.binding(for: .backward) == .backwardDefault)
    }

    @Test("변경한 조합이 충돌하면 등록과 영속 설정을 이전 상태로 복구한다")
    func updateRollsBackOnConflict() throws {
        let fixture = try ShortcutFixture()
        let service = GlobalShortcutService(defaults: fixture.defaults, backend: fixture.backend) { _ in }
        defer { service.stop() }
        try service.setEnabled(true)
        fixture.backend.failureCalls = [4]
        let proposed = binding(keyCode: 0, modifiers: [.control, .option], character: "A")
        #expect(throws: ShortcutError.registrationFailed(-9878)) {
            try service.setBinding(proposed, for: .forward)
        }
        #expect(service.binding(for: .forward) == .forwardDefault)
        #expect(fixture.backend.registered[.forward] == .forwardDefault)
        #expect(fixture.backend.registered[.backward] == .backwardDefault)
        let restored = GlobalShortcutService(defaults: fixture.defaults, backend: FakeShortcutBackend()) { _ in }
        defer { restored.stop() }
        #expect(restored.binding(for: .forward) == .forwardDefault)
    }

    @Test("단축키 기록 중에도 충돌을 검사하고 입력 등록은 중지 상태로 유지한다")
    func suspendedRecordingValidatesConflict() throws {
        let fixture = try ShortcutFixture()
        let service = GlobalShortcutService(defaults: fixture.defaults, backend: fixture.backend) { _ in }
        defer { service.stop() }
        try service.setEnabled(true)
        try service.suspend(true)
        #expect(fixture.backend.registered.isEmpty)
        fixture.backend.failureCalls = [3]
        let proposed = binding(keyCode: 0, modifiers: [.control, .option], character: "A")
        #expect(throws: ShortcutError.registrationFailed(-9878)) {
            try service.setBinding(proposed, for: .forward)
        }
        #expect(fixture.backend.registered.isEmpty)
        fixture.backend.failureCalls = []
        try service.setBinding(proposed, for: .forward)
        #expect(fixture.backend.registered.isEmpty)
        try service.suspend(false)
        #expect(fixture.backend.registered[.forward] == proposed)
    }

    @Test("설정은 같은 저장소에서 재생성해도 유지되고 reset은 기본값으로 복구한다")
    func persistsAndResetsBindings() throws {
        let fixture = try ShortcutFixture()
        let service = GlobalShortcutService(defaults: fixture.defaults, backend: fixture.backend) { _ in }
        defer { service.stop() }
        let proposed = binding(keyCode: 0, modifiers: [.control, .option], character: "A")
        try service.setBinding(proposed, for: .forward)
        let restored = GlobalShortcutService(defaults: fixture.defaults, backend: FakeShortcutBackend()) { _ in }
        defer { restored.stop() }
        #expect(restored.binding(for: .forward) == proposed)
        try restored.reset()
        #expect(restored.binding(for: .forward) == .forwardDefault)
        #expect(restored.binding(for: .backward) == .backwardDefault)
    }

    @Test("기록 종료 시 재등록 실패를 알리고 사용자가 다시 켜면 복구된다")
    func failedResumeDoesNotRemainSuspended() throws {
        let fixture = try ShortcutFixture()
        let service = GlobalShortcutService(defaults: fixture.defaults, backend: fixture.backend) { _ in }
        defer { service.stop() }
        try service.setEnabled(true)
        try service.suspend(true)
        fixture.backend.failureCalls = [3]
        #expect(throws: ShortcutError.registrationFailed(-9878)) { try service.suspend(false) }
        #expect(fixture.backend.registered.isEmpty)
        fixture.backend.failureCalls = []
        try service.setEnabled(false)
        try service.setEnabled(true)
        #expect(fixture.backend.registered.count == 2)
    }

    @Test("롤백까지 실패하면 상태를 숨기지 않고 조합 재지정으로 복구한다")
    func rollbackFailureCanBeRecovered() throws {
        let fixture = try ShortcutFixture()
        let service = GlobalShortcutService(defaults: fixture.defaults, backend: fixture.backend) { _ in }
        defer { service.stop() }
        try service.setEnabled(true)
        fixture.backend.failureCalls = [3, 4]
        let proposed = binding(keyCode: 0, modifiers: [.control, .option], character: "A")
        #expect(throws: ShortcutError.rollbackFailed) { try service.setBinding(proposed, for: .forward) }
        #expect(fixture.backend.registered.isEmpty)
        fixture.backend.failureCalls = []
        try service.setBinding(proposed, for: .forward)
        #expect(fixture.backend.registered[.forward] == proposed)
        try service.setEnabled(true)
    }

    @Test("키 한 번은 한 번 이동하고 해제한 키의 중복 이벤트나 타이머가 계속 이동시키지 않는다")
    func pressReleaseRoutesOnce() async throws {
        let fixture = try ShortcutFixture()
        var cycles: [Int] = []
        let service = GlobalShortcutService(defaults: fixture.defaults, backend: fixture.backend) { cycles.append($0) }
        defer { service.stop() }
        try service.setEnabled(true)
        fixture.backend.emit(.forward, pressed: true)
        fixture.backend.emit(.forward, pressed: true)
        fixture.backend.emit(.forward, pressed: false)
        fixture.backend.emit(.backward, pressed: true)
        fixture.backend.emit(.backward, pressed: false)
        try await Task.sleep(for: .milliseconds(650))
        #expect(cycles == [1, -1])
        try service.suspend(true)
        fixture.backend.emit(.forward, pressed: true)
        #expect(cycles == [1, -1])
    }

    @Test("종료하면 등록과 이벤트 처리가 모두 해제된다")
    func stopReleasesResources() throws {
        let fixture = try ShortcutFixture()
        var count = 0
        let service = GlobalShortcutService(defaults: fixture.defaults, backend: fixture.backend) { _ in count += 1 }
        try service.setEnabled(true)
        service.stop()
        fixture.backend.emit(.forward, pressed: true)
        #expect(fixture.backend.registered.isEmpty)
        #expect(fixture.backend.stopped)
        #expect(count == 0)
    }

    @Test("선택 완료나 취소 뒤 누른 키를 놓기 전까지 패널을 다시 열지 않는다")
    func cancelledPressCannotReopenSwitcher() async throws {
        let fixture = try ShortcutFixture()
        var cycles: [Int] = []
        let service = GlobalShortcutService(defaults: fixture.defaults, backend: fixture.backend) { cycles.append($0) }
        defer { service.stop() }
        try service.setEnabled(true)
        fixture.backend.emit(.forward, pressed: true)
        service.cancelCurrentPress()
        service.cancelCurrentPress()
        fixture.backend.emit(.forward, pressed: true)
        try await Task.sleep(for: .milliseconds(650))
        #expect(cycles == [1])
        fixture.backend.emit(.forward, pressed: false)
        fixture.backend.emit(.forward, pressed: true)
        fixture.backend.emit(.forward, pressed: false)
        #expect(cycles == [1, 1])
    }

    @Test("취소된 키와 겹쳐 누른 반대 방향도 모두 해제한 뒤 다시 사용할 수 있다")
    func overlappingPressAfterCancellationWaitsForRelease() throws {
        let fixture = try ShortcutFixture()
        var cycles: [Int] = []
        let service = GlobalShortcutService(defaults: fixture.defaults, backend: fixture.backend) { cycles.append($0) }
        defer { service.stop() }
        try service.setEnabled(true)
        fixture.backend.emit(.forward, pressed: true)
        service.cancelCurrentPress()
        fixture.backend.emit(.backward, pressed: true)
        fixture.backend.emit(.forward, pressed: false)
        fixture.backend.emit(.backward, pressed: true)
        #expect(cycles == [1])
        fixture.backend.emit(.backward, pressed: false)
        fixture.backend.emit(.backward, pressed: true)
        fixture.backend.emit(.backward, pressed: false)
        #expect(cycles == [1, -1])
    }

    @Test("첫 이동 콜백에서 곧바로 취소해도 반복 타이머를 새로 만들지 않는다")
    func immediateCancellationConsumesCurrentPress() async throws {
        let fixture = try ShortcutFixture()
        var count = 0
        var service: GlobalShortcutService?
        service = GlobalShortcutService(defaults: fixture.defaults, backend: fixture.backend) { _ in
            count += 1
            service?.cancelCurrentPress()
        }
        defer {
            service?.stop()
            service = nil
        }
        try service?.setEnabled(true)
        fixture.backend.emit(.forward, pressed: true)
        fixture.backend.emit(.forward, pressed: true)
        try await Task.sleep(for: .milliseconds(650))
        #expect(count == 1)
        fixture.backend.emit(.forward, pressed: false)
        fixture.backend.emit(.forward, pressed: true)
        fixture.backend.emit(.forward, pressed: false)
        #expect(count == 2)
    }
}

private func binding(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, character: String) -> ShortcutBinding {
    ShortcutBinding(keyCode: keyCode, modifiers: UInt64(modifiers.rawValue), character: character)
}

@MainActor
private final class ShortcutFixture {
    let domain: String
    let defaults: UserDefaults
    let backend = FakeShortcutBackend()

    init() throws {
        domain = "tests.menubardock.shortcuts.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: domain))
    }

    isolated deinit { defaults.removePersistentDomain(forName: domain) }
}

@MainActor
private final class FakeShortcutBackend: ShortcutRegistering {
    var registered: [ShortcutAction: ShortcutBinding] = [:]
    var registrationCount = 0
    var failureCalls: Set<Int> = []
    var stopped = false
    private var handler: (@MainActor (ShortcutAction, Bool) -> Void)?

    func register(_ binding: ShortcutBinding, action: ShortcutAction) throws {
        registrationCount += 1
        if failureCalls.contains(registrationCount) { throw ShortcutError.registrationFailed(-9878) }
        registered[action] = binding
    }

    func unregisterAll() { registered.removeAll() }
    func setHandler(_ handler: @escaping @MainActor (ShortcutAction, Bool) -> Void) { self.handler = handler }
    func stop() {
        stopped = true
        unregisterAll()
    }
    func emit(_ action: ShortcutAction, pressed: Bool) { handler?(action, pressed) }
}
