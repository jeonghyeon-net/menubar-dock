import AppKit
import Testing
import DockDomain
@testable import DockPlatform

@MainActor
struct WorkspaceAndIconTests {
    @Test("중복 start와 stop이 observer를 중복 유지하지 않는다")
    func monitorLifecycle() {
        let monitor = WorkspaceMonitor()
        var oldCallbackCount = 0
        var snapshots: [[RunningAppSnapshot]] = []
        monitor.start { _ in oldCallbackCount += 1 }
        monitor.start { snapshots.append($0) }
        #expect(oldCallbackCount == 1)
        #expect(snapshots.count == 1)
        monitor.stop()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(snapshots.count == 1)
    }

    @Test("활성화 payload는 실제 활성 상태와 별개로 반영된다")
    func activationPayloadIsAuthoritative() {
        let monitor = WorkspaceMonitor()
        var snapshots: [[RunningAppSnapshot]] = []
        monitor.start { snapshots.append($0) }
        defer { monitor.stop() }
        // CLI 테스트 프로세스는 Launch Services의 앱 목록에 없을 수 있다.
        guard let current = NSWorkspace.shared.runningApplications.first(where: { !$0.isTerminated && !$0.isActive }) else {
            #expect(monitor.snapshot().filter(\.isActive).count <= 1)
            return
        }
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: current]
        )
        #expect(snapshots.last?.first(where: { $0.processIdentifier == current.processIdentifier })?.isActive == true)
        #expect(monitor.snapshot().first(where: { $0.processIdentifier == current.processIdentifier })?.isActive == true)
    }

    @Test("아이콘 캐시의 비용 상한과 호출자 이미지의 독립성을 보장한다")
    func iconCacheBudgetAndIsolation() {
        let repository = IconRepository(capacity: 90_000)
        let first = AppEntry(name: "첫 앱", bundlePath: "/missing/first.app")
        let second = AppEntry(name: "둘째 앱", bundlePath: "/missing/second.app")
        let icon = repository.image(for: first)
        icon.size = NSSize(width: 1, height: 1)
        let freshCopy = repository.image(for: first)
        #expect(freshCopy.size == NSSize(width: 64, height: 64))
        #expect(!freshCopy.isTemplate)
        #expect(freshCopy.representations.count == 2)
        _ = repository.image(for: second)
        #expect(repository.cachedCount == 1)
        #expect(repository.cachedCost <= 90_000)
        repository.invalidate()
        #expect(repository.cachedCost == 0)
        #expect(repository.cachedCount == 0)
    }
}
