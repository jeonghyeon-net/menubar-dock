import Foundation
import Testing
@testable import DockPlatform

@MainActor
@Suite("Dock 변경 감시", .serialized)
struct SystemDockMonitorTests {
    @Test("원자 교체 이후 같은 파일의 직접 쓰기도 감지한다")
    func atomicReplacementReconnectsForFollowingInPlaceWrites() async throws {
        let fixture = try DockMonitorFixture()
        defer { fixture.remove() }
        try fixture.write(["A"])
        let changes = DockChangeInbox()
        let monitor = fixture.monitor()
        try monitor.start { changes.receive() }
        defer { monitor.stop() }

        try fixture.write(["A", "B"])
        try await changes.wait(until: 1)
        // 고정 앱과 무관한 Dock 속성이나 다른 앱의 plist는 가져오기를 다시 발생시키지 않는다.
        try fixture.write(["A", "B"], orientation: "left")
        try Data("other preferences".utf8).write(to: fixture.directory.appendingPathComponent("other.plist"), options: .atomic)
        try await Task.sleep(for: .milliseconds(100))
        #expect(changes.count == 1)

        try fixture.write(["A", "B", "C"], atomic: false)
        try await changes.wait(until: 2)
        #expect(changes.count == 2)
    }

    @Test("초기 파일 부재·삭제 뒤에도 부모 감시로 다시 연결한다")
    func missingFileAndRecreationRemainObservable() async throws {
        let fixture = try DockMonitorFixture()
        defer { fixture.remove() }
        let changes = DockChangeInbox()
        let monitor = fixture.monitor()
        try monitor.start { changes.receive() }
        defer { monitor.stop() }
        try await Task.sleep(for: .milliseconds(100))
        try fixture.write(["A"])
        try await changes.wait(until: 1)
        try FileManager.default.removeItem(at: fixture.url)
        try await Task.sleep(for: .milliseconds(100))
        #expect(changes.count == 1)
        try fixture.write(["B"])
        try await changes.wait(until: 2)
    }

    @Test("일시 읽기 실패는 새 파일 이벤트 없이 제한된 재시도로 복구한다")
    func transientReadFailureRetriesWithoutLosingTheUpdate() async throws {
        let fixture = try DockMonitorFixture()
        defer { fixture.remove() }
        try fixture.write(["A"])
        var failures = 0
        let monitor = fixture.monitor { url in
            if failures > 0 {
                failures -= 1
                throw CocoaError(.fileReadUnknown)
            }
            return try Data(contentsOf: url)
        }
        let changes = DockChangeInbox()
        try monitor.start { changes.receive() }
        defer { monitor.stop() }
        failures = 2
        try fixture.write(["A", "B"])
        try await changes.wait(until: 1)
        #expect(failures == 0)
        #expect(changes.count == 1)
    }

    @Test("손상 중에는 정상 목록을 유지하고 재시도 종료 후 다음 변경을 기다린다")
    func malformedPayloadDoesNotPublishOrPollForever() async throws {
        let fixture = try DockMonitorFixture()
        defer { fixture.remove() }
        try fixture.write(["A"])
        var reads = 0
        let monitor = fixture.monitor { url in
            reads += 1
            return try Data(contentsOf: url)
        }
        let changes = DockChangeInbox()
        try monitor.start { changes.receive() }
        defer { monitor.stop() }
        try Data("incomplete plist".utf8).write(to: fixture.url, options: .atomic)
        try await Task.sleep(for: .milliseconds(150))
        let exhaustedReads = reads
        try await Task.sleep(for: .milliseconds(100))
        #expect(reads == exhaustedReads)
        #expect(changes.count == 0)
        try fixture.write(["A", "B"])
        try await changes.wait(until: 1)
    }

    @Test("중지는 예약 알림까지 취소하고 재시작은 현재 목록을 기준값으로 삼는다")
    func stopAndRestartDiscardOldEvents() async throws {
        let fixture = try DockMonitorFixture()
        defer { fixture.remove() }
        try fixture.write(["A"])
        let changes = DockChangeInbox()
        let monitor = fixture.monitor()
        try monitor.start { changes.receive() }
        try fixture.write(["A", "B"])
        monitor.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(changes.count == 0)
        try monitor.start { changes.receive() }
        defer { monitor.stop() }
        try fixture.write(["A", "B", "C"])
        try await changes.wait(until: 1)
    }

    @Test("부모 디렉터리를 감시할 수 없으면 시작 실패를 호출자에게 전달한다")
    func unavailableDirectoryThrows() throws {
        let fixture = try DockMonitorFixture()
        fixture.remove()
        let monitor = fixture.monitor()
        #expect(throws: POSIXError.self) { try monitor.start {} }
        monitor.stop()
    }
}

@MainActor
private struct DockMonitorFixture {
    let directory: URL
    var url: URL { directory.appendingPathComponent("com.apple.dock.plist") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("dock-monitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func monitor(readData: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }) -> SystemDockMonitor {
        SystemDockMonitor(preferencesURL: url, debounce: .milliseconds(15), retryDelays: [.milliseconds(20), .milliseconds(30)], readData: readData)
    }

    func write(_ names: [String], orientation: String = "bottom", atomic: Bool = true) throws {
        let plist: [String: Any] = ["persistent-apps": names.map { ["tile-type": "file-tile", "name": $0] }, "orientation": orientation]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        if atomic {
            try data.write(to: url, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
private final class DockChangeInbox {
    private struct Timeout: Error {}
    private(set) var count = 0
    private var waiter: (target: Int, continuation: CheckedContinuation<Void, any Error>)?
    private var timeoutTask: Task<Void, Never>?

    func receive() {
        count += 1
        if let waiter, count >= waiter.target {
            self.waiter = nil
            timeoutTask?.cancel()
            waiter.continuation.resume()
        }
    }

    func wait(until target: Int) async throws {
        if count >= target { return }
        try await withCheckedThrowingContinuation { continuation in
            waiter = (target, continuation)
            timeoutTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, let waiter = self.waiter else { return }
                self.waiter = nil
                waiter.continuation.resume(throwing: Timeout())
            }
        }
    }
}
