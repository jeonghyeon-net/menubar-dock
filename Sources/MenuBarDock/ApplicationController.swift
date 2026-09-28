import AppKit
import DockDomain
import DockPersistence
import DockPlatform
import DockShortcuts
import OSLog
import UniformTypeIdentifiers

/// 도메인과 어댑터를 조립한다. 뷰는 명령을 보내고 이 객체만 영속 상태를 변경한다.
@MainActor
final class ApplicationController {
    private var catalog = DockCatalog()
    private let repository: ConfigurationRepository
    private let monitor = WorkspaceMonitor()
    private let resolver = ApplicationResolver()
    private let launcher = ApplicationLauncher()
    private let icons = IconRepository()
    private let login = LoginItemService()
    private let releaseChecker = ReleaseChecker()
    private let logger = Logger(subsystem: "net.jeonghyeon.MenuBarDock", category: "application")
    private let signposter = OSSignposter(subsystem: "net.jeonghyeon.MenuBarDock", category: "interaction")
    private var snapshots: [RunningAppSnapshot] = []
    private var revision: UInt64 = 0
    private var saveTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var commandTasks: [AppID: Task<Void, Never>] = [:]
    private var isReadOnly = false
    private var isTerminating = false
    private var pendingShowSettings = false
    private var pendingSettingsTab: SettingsWindowController.Tab?
    private(set) var started = false

    private(set) lazy var presentation = DockPresentationModel(
        imageForApp: { [weak self] app in self?.icons.image(for: app) ?? NSImage() },
        perform: { [weak self] action in self?.perform(action) }
    )
    private var statusItem: StatusItemController?
    private var switcher: SwitcherController?
    private var settings: SettingsWindowController?
    private lazy var shortcuts = GlobalShortcutService { [weak self] direction in self?.cycle(direction) }

    init(directory: URL) { repository = ConfigurationRepository(directory: directory) }

    func start(showSettings: Bool) async {
        do {
            let result = try await repository.load()
            catalog = DockCatalog(configuration: result.configuration)
            isReadOnly = result.isReadOnly
            presentation.notice = result.warning
        } catch {
            // 읽기 실패를 초기화로 오인해 기존 파일을 덮어쓰지 않는다.
            isReadOnly = true
            presentation.notice = "설정을 읽지 못해 읽기 전용으로 시작했습니다. \(error.localizedDescription)"
        }
        guard !Task.isCancelled else { return }
        // 이동한 앱은 bookmark로 복구하되 사용자 ID와 순서를 유지한다.
        for app in catalog.orderedApps {
            if let refreshed = resolver.refresh(app) { catalog.upsert(refreshed) }
        }
        presentation.isReadOnly = isReadOnly
        switcher = SwitcherController(model: presentation)
        settings = SettingsWindowController(model: presentation)
        monitor.start { [weak self] snapshot in self?.receive(snapshot) }
        publish()
        statusItem = StatusItemController(model: presentation)
        started = true
        if showSettings || pendingShowSettings {
            settings?.show(tab: pendingSettingsTab)
            pendingShowSettings = false
            pendingSettingsTab = nil
        }
    }

    func showSwitcher() { cycle(1) }

    func showSettings(tab: SettingsWindowController.Tab? = nil) {
        if let settings {
            settings.show(tab: tab)
        } else {
            pendingShowSettings = true
            pendingSettingsTab = tab
        }
        refreshLoginStatus()
    }

    private func receive(_ newSnapshots: [RunningAppSnapshot]) {
        guard !isTerminating else { return }
        let interval = signposter.beginInterval("event-to-render")
        defer { signposter.endInterval("event-to-render", interval) }
        snapshots = newSnapshots
        let old = catalog.configuration
        WorkspaceCatalogReconciler.reconcile(
            catalog: &catalog, snapshots: newSnapshots,
            ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier, now: Date(),
            resolve: { try resolver.resolve(url: $0) }, refresh: { resolver.refresh($0) }
        )
        catalog.pruneHistory(runningIDs: runningIDs)
        publish()
        if catalog.configuration != old { scheduleSave() }
    }

    private var runningIDs: Set<AppID> {
        WorkspaceCatalogReconciler.runningIDs(catalog: catalog, snapshots: snapshots)
    }

    private var currentAppID: AppID? {
        WorkspaceCatalogReconciler.currentAppID(catalog: catalog, snapshots: snapshots)
    }

    private func publish() {
        let items = catalog.visibleItems(runningIDs: runningIDs)
        if presentation.items != items { presentation.items = items }
        if presentation.apps != catalog.orderedApps { presentation.apps = catalog.orderedApps }
        if presentation.preferences != catalog.configuration.preferences {
            presentation.preferences = catalog.configuration.preferences
        }
        do { try shortcuts.setEnabled(catalog.configuration.preferences.shortcutEnabled) }
        catch { presentation.notice = error.localizedDescription }
        refreshShortcutLabels()
        refreshLoginStatus()
    }

    private func refreshLoginStatus() {
        presentation.loginEnabled = login.isEnabled
        presentation.loginStatus = login.statusDescription
    }

    private func cycle(_ direction: Int) {
        guard !isTerminating else { return }
        let interval = signposter.beginInterval("switcher-open")
        defer { signposter.endInterval("switcher-open", interval) }
        if switcher?.isVisible == true { switcher?.advance(direction: direction) }
        else { switcher?.show(direction: direction, currentID: currentAppID) }
    }

    private func mutate(_ change: (inout DockCatalog) -> Void) {
        guard !isTerminating else { return }
        guard !isReadOnly else {
            presentation.notice = "설정 파일을 보호하기 위해 읽기 전용으로 실행 중입니다."
            publish()
            return
        }
        let previous = catalog.configuration
        change(&catalog)
        publish()
        if previous != catalog.configuration { scheduleSave() }
    }

    private func perform(_ action: DockUIAction) {
        guard !isTerminating else { return }
        switch action {
        case .open(let id): open(id)
        case .pin(let id, let value): mutate { $0.pin(id, value) }
        case .exclude(let id, let value): mutate { $0.exclude(id, value) }
        case .remove(let id):
            // 실행 중 앱은 다음 관찰에서 다시 추가되지 않도록 제외 상태로 남긴다.
            // inout 변경 중 runningIDs를 읽으면 같은 catalog를 중첩 접근하므로 먼저 캡처한다.
            let isRunning = runningIDs.contains(id)
            mutate { value in
                if isRunning { value.pin(id, false); value.exclude(id, true) }
                else { value.remove(id) }
            }
        case .move(let offsets, let destination): mutate { $0.move(fromOffsets: offsets, toOffset: destination) }
        case .preferences(let value): mutate { $0.updatePreferences(value) }
        case .addApps: chooseApplications(replacing: nil)
        case .replaceApp(let id): chooseApplications(replacing: id)
        case .login(let enabled):
            do { try login.setEnabled(enabled) }
            catch { report(error) }
            refreshLoginStatus()
        case .hide(let id): withApp(id) { launcher.hide($0) }
        case .unhide(let id): withApp(id) { launcher.unhide($0) }
        case .quitApp(let id):
            withApp(id) { app in
                if !launcher.quit(app) { presentation.notice = "종료 요청을 전달하지 못했습니다. 앱의 상태를 확인해 주세요."; showSettings() }
            }
        case .reveal(let id): withApp(id) { launcher.reveal($0) }
        case .settings: showSettings()
        case .appearanceSettings: showSettings(tab: .appearance)
        case .help: showHelp()
        case .quit: NSApp.terminate(nil)
        case .dismissNotice: presentation.notice = nil
        case .checkForUpdates: checkForUpdates()
        case .shortcut(let action, let binding):
            do { try shortcuts.setBinding(binding, for: action) }
            catch { presentation.notice = error.localizedDescription }
            refreshShortcutLabels()
        case .suspendShortcuts(let suspended):
            do { try shortcuts.suspend(suspended) }
            catch { presentation.notice = error.localizedDescription }
        case .resetShortcuts:
            do { try shortcuts.reset() }
            catch { presentation.notice = error.localizedDescription }
            refreshShortcutLabels()
        case .cancelShortcutPress: shortcuts.cancelCurrentPress()
        }
    }

    private func withApp(_ id: AppID, perform: (AppEntry) -> Void) {
        guard let app = catalog.orderedApps.first(where: { $0.id == id }) else { return }
        perform(app)
    }

    private func open(_ id: AppID) {
        guard commandTasks[id] == nil,
              let app = catalog.orderedApps.first(where: { $0.id == id }) else { return }
        commandTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { commandTasks[id] = nil }
            let interval = signposter.beginInterval("launch-request")
            do {
                try await launcher.open(app)
                signposter.endInterval("launch-request", interval)
            } catch {
                signposter.endInterval("launch-request", interval)
                report(error)
            }
        }
    }

    private func chooseApplications(replacing id: AppID?) {
        guard !isReadOnly else { return }
        let panel = NSOpenPanel()
        panel.title = id == nil ? "메뉴 막대에 추가할 앱 선택" : "앱 위치 다시 지정"
        panel.prompt = id == nil ? "추가" : "선택"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = id == nil
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        NSApp.activate()
        panel.begin { [weak self, weak panel] response in
            guard response == .OK, let self, let panel else { return }
            for url in panel.urls {
                do {
                    var app = try self.resolver.resolve(url: url)
                    let match = self.catalog.orderedApps.first { self.canonicalPath($0.bundlePath) == self.canonicalPath(app.bundlePath) }
                    if let id {
                        if let match, match.id != id {
                            self.presentation.notice = "이미 등록된 앱입니다. 기존 항목에서 고정 또는 순서를 변경해 주세요."
                            continue
                        }
                        app.id = id
                    } else if let match { app.id = match.id }
                    self.mutate { catalog in catalog.upsert(app); catalog.pin(app.id, true) }
                    self.icons.invalidate()
                } catch { self.report(error) }
            }
        }
    }

    private func scheduleSave() {
        guard !isReadOnly else { return }
        revision &+= 1
        let state = catalog.configuration
        let version = revision
        saveTask?.cancel()
        saveTask = Task { [weak self, repository] in
            do {
                try await Task.sleep(for: .milliseconds(180))
                try await repository.save(state, revision: version)
            } catch is CancellationError {
                // 다음 revision의 저장이 이 요청을 대체한다.
            } catch {
                self?.presentation.notice = "설정을 저장하지 못했습니다. \(error.localizedDescription)"
                self?.logger.error("설정 저장 실패")
            }
        }
    }

    func saveBeforeTermination(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        // 종료 저장 중에는 새 이벤트가 더 최신 상태를 만들지 못하도록 동결한다.
        isTerminating = true
        shortcuts.cancelCurrentPress()
        switcher?.close()
        saveTask?.cancel()
        revision &+= 1
        let state = catalog.configuration
        let version = revision
        let readOnly = isReadOnly
        Task.detached { [weak self, repository] in
            let failure: (any Error)?
            do {
                if !readOnly { try await repository.save(state, revision: version) }
                failure = nil
            } catch { failure = error }
            // AppKit의 terminateLater는 modal 모드로 기다리므로 메인 큐 대신 그 실행 루프에 전달한다.
            RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                MainActor.assumeIsolated {
                    if let self, let failure {
                        self.isTerminating = false
                        self.receive(self.monitor.snapshot())
                        self.report(failure)
                    }
                    completion(failure == nil)
                }
            }
        }
    }

    func stop() {
        started = false
        monitor.stop()
        shortcuts.stop()
        statusItem?.tearDown()
        statusItem = nil
        switcher?.tearDown()
        switcher = nil
        saveTask?.cancel()
        updateTask?.cancel()
        commandTasks.values.forEach { $0.cancel() }
    }

    private func report(_ error: any Error) {
        presentation.notice = error.localizedDescription
        let diagnostic = error as NSError
        logger.error("앱 명령 처리 실패: \(diagnostic.domain, privacy: .public) (\(diagnostic.code, privacy: .public))")
        showSettings()
    }

    private func showHelp() {
        guard let url = URL(string: "https://github.com/jeonghyeon-net/menubar-dock/blob/main/docs/user-guide.md") else { return }
        NSWorkspace.shared.open(url)
    }

    private func checkForUpdates() {
        guard updateTask == nil else { return }
        presentation.notice = "업데이트를 확인하고 있습니다…"
        updateTask = Task { [weak self] in
            guard let self else { return }
            defer { updateTask = nil }
            do {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.1"
                switch try await releaseChecker.check(currentVersion: version) {
                case .current: presentation.notice = "최신 버전입니다."
                case .unpublished: presentation.notice = "아직 게시된 배포 버전이 없습니다. 현재 설치한 앱을 계속 사용할 수 있습니다."
                case .available(let version, let url):
                    let alert = NSAlert()
                    alert.messageText = "새 버전 \(version)이 있습니다"
                    alert.informativeText = "릴리스 페이지에서 변경 내용을 확인하고 다운로드할 수 있습니다."
                    alert.addButton(withTitle: "릴리스 페이지 열기")
                    alert.addButton(withTitle: "나중에")
                    NSApp.activate()
                    if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
                    presentation.notice = nil
                }
            } catch is CancellationError {} catch { report(error) }
        }
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func refreshShortcutLabels() {
        presentation.forwardShortcut = shortcuts.binding(for: .forward).displayName
        presentation.backwardShortcut = shortcuts.binding(for: .backward).displayName
    }
}
