import AppKit

@MainActor
public final class WorkspaceMonitor {
    private let workspace: NSWorkspace
    private var observers: [NSObjectProtocol] = []
    private var runningApplicationsObservation: NSKeyValueObservation?
    private var onChange: (@MainActor ([RunningAppSnapshot]) -> Void)?
    private var lastSnapshot: [RunningAppSnapshot]?
    private var generation: UInt64 = 0
    private var activeProcessIdentifier: Int32?

    public convenience init() {
        self.init(workspace: .shared)
    }

    init(workspace: NSWorkspace) {
        self.workspace = workspace
    }

    isolated deinit {
        stop()
    }

    public func start(onChange: @escaping @MainActor ([RunningAppSnapshot]) -> Void) {
        stop()
        self.onChange = onChange
        activeProcessIdentifier = workspace.frontmostApplication?.processIdentifier
        let currentGeneration = generation
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]

        // 초기 조회 전에 구독하여 시작 도중의 실행/종료도 놓치지 않는다.
        for name in names {
            let observer = workspace.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] notification in
                let name = notification.name
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    guard let self, self.generation == currentGeneration else { return }
                    self.receive(name: name, application: application)
                }
            }
            observers.append(observer)
        }
        runningApplicationsObservation = workspace.observe(\.runningApplications, options: [.new]) {
            [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.publish(self.snapshot())
            }
        }
        publish(snapshot())
    }

    public func stop() {
        generation &+= 1
        for observer in observers {
            workspace.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        runningApplicationsObservation?.invalidate()
        runningApplicationsObservation = nil
        onChange = nil
        lastSnapshot = nil
        activeProcessIdentifier = nil
    }

    public func snapshot() -> [RunningAppSnapshot] {
        workspace.runningApplications
            .filter { !$0.isTerminated }
            .map {
                RunningAppSnapshot(
                    application: $0,
                    activeOverride: onChange == nil ? nil : $0.processIdentifier == activeProcessIdentifier
                )
            }
            .sorted { $0.processIdentifier < $1.processIdentifier }
    }

    private func receive(name: Notification.Name, application: NSRunningApplication?) {
        guard let application else {
            activeProcessIdentifier = workspace.frontmostApplication?.processIdentifier
            publish(snapshot())
            return
        }
        // 활성화 payload가 frontmostApplication의 지연된 값으로 덮이지 않게 한다.
        if name == NSWorkspace.didActivateApplicationNotification {
            let activePID = application.processIdentifier
            activeProcessIdentifier = activePID
            var applications = workspace.runningApplications.filter { !$0.isTerminated }
            if !application.isTerminated, !applications.contains(where: { $0.processIdentifier == activePID }) {
                applications.append(application)
            }
            publish(applications.map {
                RunningAppSnapshot(application: $0, activeOverride: $0.processIdentifier == activePID)
            }.sorted { $0.processIdentifier < $1.processIdentifier })
        } else {
            if name == NSWorkspace.didDeactivateApplicationNotification || name == NSWorkspace.didTerminateApplicationNotification,
               activeProcessIdentifier == application.processIdentifier {
                activeProcessIdentifier = nil
            }
            publish(snapshot())
        }
    }

    private func publish(_ value: [RunningAppSnapshot]) {
        guard lastSnapshot != value else { return }
        lastSnapshot = value
        onChange?(value)
    }
}
