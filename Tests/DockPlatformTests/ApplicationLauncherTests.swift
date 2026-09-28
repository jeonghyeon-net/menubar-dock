import Foundation
import Testing
import DockDomain
@testable import DockPlatform

@MainActor
struct ApplicationLauncherTests {
    @Test("연속 실행 요청은 하나의 OS 요청 결과를 공유한다")
    func coalescesPendingLaunches() async throws {
        let fixture = try PlatformFixture()
        let entry = try fixture.entry()
        let backend = TestLaunchingBackend()
        backend.suspends = true
        let launcher = ApplicationLauncher(backend: backend)
        let first = Task { try await launcher.open(entry) }
        await backend.waitUntilOpenRequested()
        var second: Task<Void, Error>?
        await withCheckedContinuation { continuation in
            second = Task { @MainActor in
                continuation.resume()
                try await launcher.open(entry)
            }
        }
        #expect(backend.openedURLs.count == 1)
        backend.complete(with: .success(runningSnapshot(url: fixture.applicationURL)))
        try await first.value
        try await second?.value
        #expect(backend.openedURLs.count == 1)
    }

    @Test("한 대기자가 취소되어도 이미 전달된 공통 실행 요청은 유지한다")
    func cancellationDoesNotRelaunch() async throws {
        let fixture = try PlatformFixture()
        let entry = try fixture.entry()
        let backend = TestLaunchingBackend()
        backend.suspends = true
        let launcher = ApplicationLauncher(backend: backend)
        let first = Task { try await launcher.open(entry) }
        await backend.waitUntilOpenRequested()
        first.cancel()
        backend.complete(with: .success(runningSnapshot(url: fixture.applicationURL)))
        try await first.value
        #expect(backend.openedURLs.count == 1)
    }

    @Test("실행 중인 앱에는 reopen과 활성화를 요청하고 숨김을 해제한다")
    func activatesRunningApplication() async throws {
        let fixture = try PlatformFixture()
        let backend = TestLaunchingBackend()
        backend.runningApplications = [runningSnapshot(url: fixture.applicationURL, hidden: true)]
        let launcher = ApplicationLauncher(backend: backend)
        try await launcher.open(fixture.entry())
        #expect(backend.requestedActivations == [false])
        #expect(backend.activated == [123])
        #expect(backend.unhidden == [123])
    }

    @Test("같은 bundle ID인 다른 위치의 설치본은 새 실행 대상과 구분한다")
    func distinguishesInstallations() async throws {
        let fixture = try PlatformFixture()
        let other = try PlatformFixture(name: "Other")
        let backend = TestLaunchingBackend()
        backend.runningApplications = [runningSnapshot(url: other.applicationURL)]
        let launcher = ApplicationLauncher(backend: backend)
        try await launcher.open(fixture.entry())
        #expect(backend.requestedActivations == [true])
        #expect(backend.activated.isEmpty)
        #expect(backend.openedURLs == [canonicalApplicationURL(fixture.applicationURL)])
    }

    @Test("활성화 거절을 성공으로 보고하지 않는다")
    func propagatesActivationRejection() async throws {
        let fixture = try PlatformFixture()
        let backend = TestLaunchingBackend()
        backend.runningApplications = [runningSnapshot(url: fixture.applicationURL)]
        backend.acceptsActivation = false
        let launcher = ApplicationLauncher(backend: backend)
        await #expect(throws: ApplicationLaunchError.activationRejected) {
            try await launcher.open(fixture.entry())
        }
    }

    @Test("실행 실패 후 사용자의 다음 요청을 새로 처리할 수 있다")
    func failedRequestCanBeRetried() async throws {
        let fixture = try PlatformFixture()
        let entry = try fixture.entry()
        let backend = TestLaunchingBackend()
        backend.failure = .applicationUnavailable
        let launcher = ApplicationLauncher(backend: backend)
        await #expect(throws: ApplicationLaunchError.applicationUnavailable) {
            try await launcher.open(entry)
        }
        backend.failure = nil
        try await launcher.open(entry)
        #expect(backend.openedURLs.count == 2)
    }

    @Test("종료 요청은 선택한 설치본의 모든 인스턴스에만 전달한다")
    func quitUsesExactInstallation() throws {
        let fixture = try PlatformFixture()
        let other = try PlatformFixture(name: "Other")
        let backend = TestLaunchingBackend()
        backend.runningApplications = [
            runningSnapshot(url: fixture.applicationURL, pid: 1),
            runningSnapshot(url: other.applicationURL, pid: 2),
            runningSnapshot(url: fixture.applicationURL, pid: 3),
        ]
        backend.rejectsTermination = [3]
        let launcher = ApplicationLauncher(backend: backend)
        #expect(!launcher.quit(try fixture.entry()))
        #expect(backend.terminated == [1, 3])
        #expect(backend.runningApplications.count == 3)
    }
}

@MainActor
private final class TestLaunchingBackend: ApplicationLaunchingBackend {
    var runningApplications: [RunningAppSnapshot] = []
    var openedURLs: [URL] = []
    var requestedActivations: [Bool] = []
    var activated: [Int32] = []
    var unhidden: [Int32] = []
    var terminated: [Int32] = []
    var rejectsTermination: Set<Int32> = []
    var acceptsActivation = true
    var suspends = false
    var failure: ApplicationLaunchError?
    private var continuation: CheckedContinuation<RunningAppSnapshot, Error>?
    private var started: CheckedContinuation<Void, Never>?

    func openApplication(at url: URL, activates: Bool) async throws -> RunningAppSnapshot {
        openedURLs.append(url)
        requestedActivations.append(activates)
        if let failure { throw failure }
        if suspends {
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                started?.resume()
                started = nil
            }
        }
        return runningApplications.first { canonicalApplicationURL($0.bundleURL ?? url) == url }
            ?? runningSnapshot(url: url)
    }

    func waitUntilOpenRequested() async {
        if !openedURLs.isEmpty { return }
        await withCheckedContinuation { started = $0 }
    }

    func complete(with result: Result<RunningAppSnapshot, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    func activate(_ application: RunningAppSnapshot) -> Bool {
        activated.append(application.processIdentifier)
        return acceptsActivation
    }

    func hide(_ application: RunningAppSnapshot) -> Bool { true }

    func unhide(_ application: RunningAppSnapshot) -> Bool {
        unhidden.append(application.processIdentifier)
        return true
    }

    func terminate(_ application: RunningAppSnapshot) -> Bool {
        terminated.append(application.processIdentifier)
        return !rejectsTermination.contains(application.processIdentifier)
    }

    func reveal(_ url: URL) {}
}
