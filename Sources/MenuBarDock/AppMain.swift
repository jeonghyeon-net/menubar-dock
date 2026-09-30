import AppKit
import DockDomain
import DockPlatform

@main
@MainActor
enum MenuBarDockMain {
    static func main() {
        let application = NSApplication.shared
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTest.run())
        }
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        ApplicationMenu.install(delegate: delegate)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: ApplicationController?
    private var starting: Task<Void, Never>?
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        let directory: URL
        if let index = arguments.firstIndex(of: "--data-directory"), arguments.indices.contains(index + 1) {
            directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("net.jeonghyeon.MenuBarDock", isDirectory: true)
        }
        let firstLaunch = !FileManager.default.fileExists(atPath: directory.appendingPathComponent("preferences.json").path)
        let controller = ApplicationController(directory: directory, allowsGlobalShortcuts: !arguments.contains("--smoke-test"))
        self.controller = controller
        starting = Task {
            await controller.start(showSettings: firstLaunch || arguments.contains("--show-settings"))
            if arguments.contains("--smoke-test") {
                try? await Task.sleep(for: .seconds(3))
                print("SMOKE: started=\(controller.started) items=\(controller.presentation.items.count) windows=\(NSApp.windows.count)")
                // terminateLater의 중첩 실행 루프를 Swift 작업 안에서 시작하지 않는다.
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showSettings()
        return true
    }

    @objc func openSettings(_ sender: Any?) { controller?.showSettings() }
    @objc func openSwitcher(_ sender: Any?) { controller?.showSwitcher() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller, controller.started else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        controller.saveBeforeTermination { [self] saved in
            if !saved {
                let alert = NSAlert()
                alert.messageText = "설정을 저장하지 못했습니다"
                alert.informativeText = "종료하면 마지막 변경 내용이 저장되지 않을 수 있습니다."
                alert.addButton(withTitle: "앱으로 돌아가기")
                alert.addButton(withTitle: "저장하지 않고 종료")
                if alert.runModal() == .alertFirstButtonReturn {
                    terminationPending = false
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            controller.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        starting?.cancel()
        controller?.stop()
    }
}

/// 배포 번들 자체를 검사하는 무부작용 진단 진입점이다.
@MainActor
enum SelfTest {
    static func run() -> Int32 {
        let info = Bundle.main.infoDictionary ?? [:]
        let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        let checks: [String: Bool] = [
            "bundleIdentifier": Bundle.main.bundleIdentifier == "net.jeonghyeon.MenuBarDock",
            "agentApplication": info["LSUIElement"] as? Bool == true,
            "appIcon": icon.flatMap(NSImage.init(contentsOf:)) != nil,
            "defaultPreferences": DockPreferences().normalized() == DockPreferences(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]),
           let report = String(data: data, encoding: .utf8) { print(report) }
        return checks.values.allSatisfy { $0 } ? 0 : 1
    }
}
