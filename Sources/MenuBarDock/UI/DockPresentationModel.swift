import AppKit
import Combine
import DockDomain
import DockShortcuts

/// 화면은 명령을 전달하고, 영속 상태와 운영체제 부작용은 조립 계층에서 처리한다.
@MainActor
enum DockUIAction {
    case open(AppID)
    case pin(AppID, Bool)
    case exclude(AppID, Bool)
    case remove(AppID)
    case move(IndexSet, Int)
    case preferences(DockPreferences)
    case addApps
    case replaceApp(AppID)
    case login(Bool)
    case hide(AppID)
    case unhide(AppID)
    case quitApp(AppID)
    case reveal(AppID)
    case settings
    case appearanceSettings
    case help
    case checkForUpdates
    case shortcut(ShortcutAction, ShortcutBinding)
    case suspendShortcuts(Bool)
    case resetShortcuts
    case cancelShortcutPress
    case quit
    case dismissNotice
}

@MainActor
final class DockPresentationModel: ObservableObject {
    @Published var items: [DockItem] = []
    @Published var apps: [AppEntry] = []
    @Published var preferences = DockPreferences()
    @Published var loginEnabled = false
    @Published var loginStatus = ""
    @Published var notice: String?
    @Published var isReadOnly = false
    @Published var forwardShortcut = "⌥⇥"
    @Published var backwardShortcut = "⇧⌥⇥"

    let imageForApp: (AppEntry) -> NSImage
    var perform: (DockUIAction) -> Void

    init(
        imageForApp: @escaping (AppEntry) -> NSImage,
        perform: @escaping (DockUIAction) -> Void
    ) {
        self.imageForApp = imageForApp
        self.perform = perform
    }
}
