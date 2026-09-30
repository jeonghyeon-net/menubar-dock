import AppKit
import DockDomain
import DockPlatform
import DockShortcuts

/// 외부 앱을 열지 않고 제품 창의 field editor와 이벤트 큐를 사용한다.
@main
@MainActor
struct SwitcherInputCheck {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        let probe = SearchInputProbe()
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            print("실패: 검색 입력 검사 제한 시간 초과")
            exit(1)
        }
        DispatchQueue.main.async {
            Task { @MainActor in
                do { try await probe.run() }
                catch { probe.fail("검사 중 오류: \(error.localizedDescription)") }
            }
        }
        application.run()
    }
}

@MainActor
private final class SearchInputProbe {
    private let entries = [
        ("Finder", "/System/Library/CoreServices/Finder.app"),
        ("Safari", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"),
        ("Terminal", "/System/Applications/Utilities/Terminal.app"),
    ].enumerated().map { index, app in
        AppEntry(id: AppID(rawValue: "input-\(index)"), name: app.0, bundlePath: app.1, isPinned: true)
    }
    private lazy var results = entries.map {
        SearchResult(url: URL(fileURLWithPath: $0.bundlePath), name: $0.name, kind: .application)
    }
    private let search = ProbeSearch()
    private var actions: [DockUIAction] = []
    private var window: NSWindow?
    private lazy var model = DockPresentationModel(imageForApp: { NSWorkspace.shared.icon(forFile: $0.bundlePath) }) { [weak self] in
        self?.actions.append($0)
    }
    private lazy var switcher = SwitcherController(model: model, search: search)

    private var openedResults: [SearchResult] { actions.compactMap { if case let .openSearchResult(result) = $0 { result } else { nil } } }
    private var openedApps: [AppID] { actions.compactMap { if case let .open(id) = $0 { id } else { nil } } }

    func run() async throws {
        if CommandLine.arguments.contains("--global-shortcuts") {
            try await checkGlobalShortcuts()
            exit(0)
        }
        model.apps = entries
        model.items = entries.map { DockItem(app: $0, isRunning: false) }
        try await show()
        try saveSnapshot(option: "--idle-snapshot")
        let input = field()
        let originalEditor = editor()
        // 이벤트 큐를 통해 입력하므로 currentEvent와 field editor의 실제 키 처리도 거친다.
        try await key(15, characters: "r")
        try await settleSearch("r", count: 1)
        search.deliver(results, request: 0)
        require(field() === input && editor() === originalEditor, "결과 수신 중 입력창 또는 field editor 교체")
        require(window?.firstResponder === originalEditor, "결과 수신 뒤 입력 포커스 상실")
        checkApplicationRows()
        try saveSnapshot(option: "--snapshot")
        try await key(125, characters: "\u{f701}")
        require(table().selectedRow == 1, "아래 방향키가 검색 결과를 선택하지 않음")
        let caret = editor().selectedRange().location
        try await key(123, characters: "\u{f702}")
        require(editor().selectedRange().location == max(0, caret - 1), "왼쪽 키가 검색어 caret을 이동하지 않음")
        require(table().selectedRow == 1, "왼쪽 키가 검색 결과 선택을 변경함")
        try await key(124, characters: "\u{f703}")
        require(editor().selectedRange().location == caret, "오른쪽 키가 검색어 caret을 복원하지 않음")
        require(table().selectedRow == 1, "오른쪽 키가 검색 결과 선택을 변경함")
        // 전역 이동 뒤 로컬 ⌘ Space가 선택을 다시 옮기거나 공백을 입력하면 실패한다.
        switcher.advance(direction: 1)
        try await key(49, characters: " ", flags: .command)
        require(table().selectedRow == 2 && field().stringValue == "r", "⌘ Space가 중복 이동하거나 검색어에 공백을 입력함")
        switcher.advance(direction: -1)
        try await key(49, characters: " ", flags: [.command, .shift])
        require(table().selectedRow == 1 && field().stringValue == "r", "⇧⌘ Space가 중복 이동하거나 검색어를 변경함")
        search.deliver([results[0]], request: 0)
        try await clickEmptyResultsArea()
        require(window?.firstResponder === originalEditor, "검색 결과 빈 영역 클릭 후 입력 포커스 상실")

        editor().insertText("new", replacementRange: NSRange(location: 0, length: editor().string.utf16.count))
        search.deliver([results[0]], request: 0)
        try await key(36, characters: "\r")
        require(openedResults.isEmpty && switcher.isVisible, "검색 변경 직후 오래된 결과를 실행함")
        try await settleSearch("new", count: 2)
        search.deliver([results[1]], request: 1)
        try await key(36, characters: "\r")
        require(openedResults == [results[1]] && !switcher.isVisible, "Enter가 현재 검색 결과를 정확히 실행하지 않음")
        require(model.apps == entries, "검색 결과가 저장된 앱 목록을 변경함")

        try await show()
        editor().insertText("same", replacementRange: NSRange(location: 0, length: 0))
        try await settleSearch("same", count: 3)
        let cancellationCount = search.cancelCount
        switcher.close()
        require(search.cancelCount > cancellationCount, "창 닫을 때 검색 취소 누락")
        try await show()
        editor().insertText("same", replacementRange: NSRange(location: 0, length: 0))
        try await settleSearch("same", count: 4)
        search.deliver([results[0]], request: 2)
        try await key(36, characters: "\r")
        require(openedResults.count == 1 && switcher.isVisible, "재개한 동일 검색에 이전 세션 결과가 들어옴")
        search.deliver(results, request: 3)
        try await key(53, characters: "\u{1b}")
        require(field().stringValue.isEmpty && switcher.isVisible, "첫 Escape가 검색어만 비우지 않음")
        try await key(36, characters: "\r")
        require(openedApps == [entries[1].id], "검색 종료 후 원래 앱 선택을 복원하지 않음")
        try await show()
        try await key(53, characters: "\u{1b}")
        require(!switcher.isVisible, "빈 검색에서 Escape로 닫히지 않음")

        try await show()
        let compositionEditor = editor()
        compositionEditor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        require(compositionEditor.hasMarkedText(), "한글 조합 텍스트가 생성되지 않음")
        let requestsBeforeComposition = search.queries.count
        let commandsBeforeComposition = openedApps.count + openedResults.count
        try await Task.sleep(for: .milliseconds(150))
        require(search.queries.count == requestsBeforeComposition, "조합 중인 한글로 검색을 시작함")
        try await key(36, characters: "\r")
        require(openedApps.count + openedResults.count == commandsBeforeComposition, "한글 조합 확정 Enter가 항목을 실행함")
        require(switcher.isVisible, "한글 조합 확정 Enter가 창을 닫음")
        require(!compositionEditor.hasMarkedText(), "Enter 뒤 한글 조합이 확정되지 않음")
        require(field().stringValue == "ㅎ", "한글 조합 확정 뒤 검색어 불일치")
        try await settleSearch("ㅎ", count: requestsBeforeComposition + 1)
        switcher.tearDown()
        print("통과: 앱 아이콘·15pt 이름 한 줄·실제 검색 입력·포커스 유지·빈 영역 클릭·caret·방향키·Enter·Esc·⌘ Space 양방향 중복·공백 방지·늦은 응답·창 재개·한글 조합 확정 후 검색")
        exit(0)
    }

    private func show() async throws {
        switcher.show(direction: 1, currentID: entries[0].id)
        window = NSApp.windows.first { $0.title == "앱 선택" && $0.isVisible }
        require(window != nil, "선택 창 없음")
        require(window?.makeFirstResponder(field()) == true, "검색창을 first responder로 설정할 수 없음")
        try await waitUntil("선택 창의 키보드 입력 준비") {
            guard let window, let editor = field().currentEditor() as? NSTextView else { return false }
            return window.isKeyWindow && NSApp.keyWindow === window && window.firstResponder === editor
        }
    }

    private func checkGlobalShortcuts() async throws {
        let domain = "net.jeonghyeon.MenuBarDock.GlobalInputCheck.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else { fail("단축키 검사 저장소 생성 실패") }
        defer { defaults.removePersistentDomain(forName: domain) }
        let override = SpotlightShortcutOverride()
        var cycles: [Int] = []
        let shortcuts = GlobalShortcutService(defaults: defaults, prepareRegistration: { _ in try override.prepare() }) {
            cycles.append($0)
        }
        defer { shortcuts.stop() }
        try shortcuts.setEnabled(true)
        for (index, modifiers) in ["command down", "{command down, shift down}", "command down"].enumerated() {
            // AppKit의 로컬 큐 대신 System Events로 WindowServer의 전역 입력 경로를 통과한다.
            let status = try await Task.detached {
                let sender = Process()
                sender.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                sender.arguments = ["-e", "tell application \"System Events\" to key code 49 using \(modifiers)"]
                try sender.run()
                sender.waitUntilExit()
                return sender.terminationStatus
            }.value
            require(status == 0, "System Events 키 입력 전송 실패")
            try await waitUntil("전역 단축키 \(index + 1)회 전달") { cycles.count >= index + 1 }
            try await Task.sleep(for: .milliseconds(120))
            require(cycles.count == index + 1, "키를 놓은 뒤 중복 또는 반복 입력 발생")
        }
        require(cycles == [1, -1, 1], "⌘ Space 정방향·역방향 순서 불일치")
        try shortcuts.suspend(true)
        try shortcuts.suspend(false)
        shortcuts.stop()
        print("통과: Spotlight 설정 자동 해제·실제 Carbon 전역 ⌘ Space/⇧⌘ Space 입력·키 해제·기록 중지/복구·등록 해제")
    }

    private func field() -> NSSearchField {
        guard let field = probeDescendants(window?.contentView).compactMap({ $0 as? NSSearchField }).first else { fail("검색창 없음") }
        return field
    }

    private func editor() -> NSTextView {
        guard let editor = field().currentEditor() as? NSTextView else { fail("검색 field editor 없음") }
        return editor
    }

    private func table() -> NSTableView {
        guard let table = probeDescendants(window?.contentView).compactMap({ $0 as? NSTableView }).first else { fail("검색 결과 table 없음") }
        return table
    }

    private func checkApplicationRows() {
        require(field().placeholderString == "앱 검색" && field().accessibilityLabel() == "앱 검색", "검색창 앱 전용 안내 누락")
        window?.contentView?.layoutSubtreeIfNeeded()
        let table = table()
        require(table.numberOfRows == results.count, "앱 검색 결과 행 수 불일치")
        for (row, result) in results.enumerated() {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView else { fail("앱 검색 행 없음") }
            cell.layoutSubtreeIfNeeded()
            let labels = probeDescendants(cell).compactMap { $0 as? NSTextField }
            require(labels.count == 1 && labels.first?.stringValue == result.name, "앱 이름 외의 경로 또는 보조 텍스트가 남아 있음")
            require(labels.first?.font?.pointSize == 15, "앱 이름 글자 크기 불일치")
            require(cell.imageView?.image != nil && cell.imageView?.frame.size == NSSize(width: 32, height: 32), "앱 아이콘 크기 불일치")
            require(labels.first?.frame.midY == cell.bounds.midY && cell.imageView?.frame.midY == cell.bounds.midY, "앱 이름과 아이콘이 수직 중앙에 맞지 않음")
            require(cell.toolTip == nil && cell.accessibilityLabel() == result.name, "앱 이름에 불필요한 경로 안내가 남아 있음")
            require(table.rect(ofRow: row).maxY <= table.visibleRect.maxY, "앱 검색 결과 행 아래쪽이 잘림")
        }
    }

    private func key(_ code: UInt16, characters: String, flags: NSEvent.ModifierFlags = []) async throws {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code
        ) else { fail("키 이벤트 생성 실패") }
        NSApp.postEvent(event, atStart: false)
        try await Task.sleep(for: .milliseconds(30))
    }

    private func settleSearch(_ query: String, count: Int) async throws {
        // 디바운스와 AppKit 입력 처리는 비동기다. 경과 시간 대신 요청 도착을 확인한다.
        try await waitUntil("검색 요청 \(count)회 도착") {
            require(search.queries.count <= count, "예상보다 많은 검색 요청")
            guard search.queries.count == count else { return false }
            require(search.queries.last == query, "검색 요청의 검색어 불일치")
            return field().stringValue == query && editor().string == query && !editor().hasMarkedText()
        }
        require(search.queries.count == count && search.queries.last == query,
                "검색어 또는 요청 수 불일치: 기대 \(count)회, 실제 \(search.queries.count)회, 창 \(switcher.isVisible), 조합 중 \(editor().hasMarkedText())")
    }

    private func waitUntil(_ description: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else { fail("\(description) 제한 시간 초과") }
            // 검사 프로세스만 잠깐 양보하여 AppKit 이벤트와 제품의 디바운스 작업을 진행한다.
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func clickEmptyResultsArea() async throws {
        window?.contentView?.layoutSubtreeIfNeeded()
        let table = table()
        let point = NSPoint(x: table.bounds.midX, y: table.bounds.maxY - 2)
        require(table.row(at: point) == -1, "빈 영역 클릭 검사 좌표에 결과 행이 있음")
        let location = table.convert(point, to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) else { fail("마우스 이벤트 생성 실패") }
            NSApp.postEvent(event, atStart: false)
        }
        try await Task.sleep(for: .milliseconds(30))
    }

    private func saveSnapshot(option: String) throws {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: option), args.indices.contains(index + 1) else { return }
        let expectedText = option == "--idle-snapshot" ? "" : "r"
        require(field().stringValue == expectedText, "검사 입력과 달라 스냅샷 저장을 중단함")
        guard let view = window?.contentView else { fail("스냅샷 대상 없음") }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fail("스냅샷 bitmap 생성 실패") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fail("스냅샷 PNG 변환 실패") }
        try data.write(to: URL(fileURLWithPath: args[index + 1]), options: .atomic)
        print("검색창 자체 렌더링 저장: \(args[index + 1])")
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fail(message) }
    }

    func fail(_ message: String) -> Never {
        print("실패: \(message), \(inputState())")
        switcher.tearDown()
        exit(1)
    }

    private func inputState() -> String {
        let input = probeDescendants(window?.contentView).compactMap { $0 as? NSSearchField }.first
        let editor = input?.currentEditor() as? NSTextView
        return "active=\(NSApp.isActive) key=\(window?.isKeyWindow == true) appKey=\(NSApp.keyWindow === window) editorFocused=\(editor != nil && window?.firstResponder === editor) field=\(String(reflecting: input?.stringValue)) editor=\(String(reflecting: editor?.string)) marked=\(editor?.hasMarkedText() == true) source=\(NSTextInputContext.current?.selectedKeyboardInputSource ?? "nil") requests=\(search.queries)"
    }
}

@MainActor
private final class ProbeSearch: SpotlightSearching {
    var queries: [String] = []
    var cancelCount = 0
    private var callbacks: [@MainActor (SpotlightSearchUpdate) -> Void] = []
    func search(_ text: String, receive: @escaping @MainActor (SpotlightSearchUpdate) -> Void) {
        queries.append(text)
        callbacks.append(receive)
    }
    func cancel() { cancelCount += 1 }
    func deliver(_ results: [SearchResult], request: Int) {
        guard callbacks.indices.contains(request) else { return }
        callbacks[request](SpotlightSearchUpdate(results: results, isComplete: true))
    }
}

@MainActor
private func probeDescendants(_ view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap { probeDescendants($0) }
}
