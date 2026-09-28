import AppKit
import DockDomain
import OSLog

public enum ApplicationLaunchError: LocalizedError, Sendable, Equatable {
    case applicationUnavailable
    case differentInstallation

    public var errorDescription: String? {
        switch self {
        case .applicationUnavailable: "앱이 실행되기 전에 종료되었습니다. 다시 선택해 주세요."
        case .differentInstallation: "선택한 설치 위치와 실행된 앱이 일치하지 않습니다. 설정에서 앱 경로를 확인해 주세요."
        }
    }
}

/// 실제 프로세스를 조작하지 않고 실행 정책을 검증하기 위한 OS 경계다.
@MainActor
protocol ApplicationLaunchingBackend: AnyObject {
    var runningApplications: [RunningAppSnapshot] { get }
    func openApplication(at url: URL, activates: Bool) async throws -> RunningAppSnapshot
    func hide(_ application: RunningAppSnapshot) -> Bool
    func unhide(_ application: RunningAppSnapshot) -> Bool
    func terminate(_ application: RunningAppSnapshot) -> Bool
    func reveal(_ url: URL)
}

@MainActor
public final class ApplicationLauncher {
    private struct PendingLaunch {
        let id: UUID
        let task: Task<Void, Error>
    }

    private let backend: any ApplicationLaunchingBackend
    private let resolver: ApplicationResolver
    private var pending: [URL: PendingLaunch] = [:]
    private let logger = Logger(subsystem: "app.menubardock", category: "application-launcher")

    public convenience init() {
        self.init(backend: WorkspaceLaunchingBackend(), resolver: ApplicationResolver())
    }

    init(backend: any ApplicationLaunchingBackend, resolver: ApplicationResolver = ApplicationResolver()) {
        self.backend = backend
        self.resolver = resolver
    }

    public func open(_ entry: AppEntry) async throws {
        guard let refreshed = resolver.refresh(entry) else {
            throw ApplicationResolutionError.missingApplication
        }
        let url = canonicalApplicationURL(URL(fileURLWithPath: refreshed.bundlePath))
        if let existing = pending[url] {
            try await existing.task.value
            return
        }
        let requestID = UUID()
        // 대기자의 취소가 이미 전달한 OS 실행 요청을 취소하거나 중복 실행하지 않게 한다.
        let task = Task { @MainActor [backend] in
            // 기존 앱도 활성화를 포함한 reopen 요청 하나로 연다. 별도의 활성화 요청은
            // 비동기 복귀 뒤 사용자 입력과 분리될 수 있으므로 Launch Services에 맡긴다.
            let application = try await backend.openApplication(at: url, activates: true)
            guard application.bundleURL.map(canonicalApplicationURL) == url else {
                throw ApplicationLaunchError.differentInstallation
            }
        }
        pending[url] = PendingLaunch(id: requestID, task: task)
        defer {
            if pending[url]?.id == requestID { pending.removeValue(forKey: url) }
        }
        try await task.value
    }

    public func hide(_ entry: AppEntry) {
        for application in matchingApplications(entry) {
            if !backend.hide(application) {
                logger.notice("앱 숨김 요청이 수락되지 않았습니다.")
            }
        }
    }

    public func unhide(_ entry: AppEntry) {
        for application in matchingApplications(entry) {
            if !backend.unhide(application) {
                logger.notice("앱 표시 요청이 수락되지 않았습니다.")
            }
        }
    }

    /// true는 정상 종료 요청의 수락이며 실제 종료는 WorkspaceMonitor에서 확인한다.
    public func quit(_ entry: AppEntry) -> Bool {
        let applications = matchingApplications(entry)
        guard !applications.isEmpty else { return false }
        var accepted = true
        for application in applications {
            if !backend.terminate(application) { accepted = false }
        }
        return accepted
    }

    public func reveal(_ entry: AppEntry) {
        let url = resolver.refresh(entry).map { URL(fileURLWithPath: $0.bundlePath) }
            ?? URL(fileURLWithPath: entry.bundlePath)
        backend.reveal(url)
    }

    private func matchingApplications(_ entry: AppEntry) -> [RunningAppSnapshot] {
        let path = resolver.refresh(entry)?.bundlePath ?? entry.bundlePath
        let url = canonicalApplicationURL(URL(fileURLWithPath: path))
        return backend.runningApplications.filter { $0.bundleURL.map(canonicalApplicationURL) == url }
    }
}

@MainActor
private final class WorkspaceLaunchingBackend: ApplicationLaunchingBackend {
    private let workspace = NSWorkspace.shared

    var runningApplications: [RunningAppSnapshot] {
        workspace.runningApplications.filter { !$0.isTerminated }.map { RunningAppSnapshot(application: $0) }
    }

    func openApplication(at url: URL, activates: Bool) async throws -> RunningAppSnapshot {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = true
        let application = try await workspace.openApplication(at: url, configuration: configuration)
        guard !application.isTerminated else { throw ApplicationLaunchError.applicationUnavailable }
        return RunningAppSnapshot(application: application)
    }

    func hide(_ snapshot: RunningAppSnapshot) -> Bool {
        application(snapshot)?.hide() ?? false
    }

    func unhide(_ snapshot: RunningAppSnapshot) -> Bool {
        application(snapshot)?.unhide() ?? false
    }

    func terminate(_ snapshot: RunningAppSnapshot) -> Bool {
        application(snapshot)?.terminate() ?? false
    }

    func reveal(_ url: URL) {
        workspace.activateFileViewerSelecting([url])
    }

    private func application(_ snapshot: RunningAppSnapshot) -> NSRunningApplication? {
        // 스냅샷 이후 PID가 재사용되어도 다른 프로세스에 종료/숨김 요청을 보내지 않는다.
        guard let application = NSRunningApplication(processIdentifier: snapshot.processIdentifier),
              !application.isTerminated,
              application.bundleURL.map(canonicalApplicationURL) == snapshot.bundleURL.map(canonicalApplicationURL),
              application.launchDate == snapshot.launchDate
        else {
            return nil
        }
        return application
    }
}
