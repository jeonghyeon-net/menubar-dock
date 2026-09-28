import AppKit

/// 설정 창을 사용할 때도 표준 편집·창 닫기·앱 종료 단축키를 제공한다.
@MainActor
enum ApplicationMenu {
    static func install(delegate: AppDelegate) {
        let bar = NSMenu()
        let application = submenu("Menu Bar Dock", in: bar)
        item("Menu Bar Dock 정보", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), in: application)
        application.addItem(.separator())
        let settings = item("설정", action: #selector(AppDelegate.openSettings(_:)), key: ",", in: application)
        settings.target = delegate
        let switcher = item("앱 선택기 열기", action: #selector(AppDelegate.openSwitcher(_:)), in: application)
        switcher.target = delegate
        application.addItem(.separator())
        item("Menu Bar Dock 가리기", action: #selector(NSApplication.hide(_:)), key: "h", in: application)
        let hideOthers = item("기타 가리기", action: #selector(NSApplication.hideOtherApplications(_:)), key: "h", in: application)
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        item("모두 보기", action: #selector(NSApplication.unhideAllApplications(_:)), in: application)
        application.addItem(.separator())
        item("종료", action: #selector(NSApplication.terminate(_:)), key: "q", in: application)

        let edit = submenu("편집", in: bar)
        item("실행 취소", action: Selector(("undo:")), key: "z", in: edit)
        let redo = item("실행 복귀", action: Selector(("redo:")), key: "z", in: edit)
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        item("오려두기", action: #selector(NSText.cut(_:)), key: "x", in: edit)
        item("복사하기", action: #selector(NSText.copy(_:)), key: "c", in: edit)
        item("붙여넣기", action: #selector(NSText.paste(_:)), key: "v", in: edit)
        item("모두 선택", action: #selector(NSText.selectAll(_:)), key: "a", in: edit)

        let window = submenu("윈도우", in: bar)
        item("닫기", action: #selector(NSWindow.performClose(_:)), key: "w", in: window)
        item("최소화", action: #selector(NSWindow.performMiniaturize(_:)), key: "m", in: window)
        NSApp.windowsMenu = window
        NSApp.mainMenu = bar
    }

    private static func submenu(_ title: String, in parent: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        parent.addItem(item)
        return menu
    }

    @discardableResult
    private static func item(_ title: String, action: Selector, key: String = "", in menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menu.addItem(item)
        return item
    }
}
