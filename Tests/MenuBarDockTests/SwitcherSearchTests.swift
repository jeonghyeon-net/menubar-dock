import AppKit
import DockDomain
import DockPlatform
import Testing
@testable import MenuBarDock

// 기존 AppKit 입력 suite의 직렬 실행을 공유하여 창 사이의 포커스 경쟁을 피한다.
extension NativeUIBehaviorTests {
    @Test func searchTypingPreservesTheFieldEditorAndRejectsOldResults() async throws {
        let fixture = SearchInputFixture()
        defer { fixture.close() }
        try fixture.show()
        let field = try fixture.field()
        let editor = try fixture.editor()
        editor.insertText("old", replacementRange: NSRange(location: 0, length: 0))
        try await fixture.waitForQuery("old")
        fixture.search.deliver([fixture.results[0]], request: 0)
        #expect(fixture.window?.firstResponder === editor)
        #expect(try fixture.field() === field)
        #expect(try fixture.editor() === editor)

        editor.insertText("current", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        fixture.command("insertNewline:")
        #expect(fixture.openedResults.isEmpty)
        #expect(fixture.switcher.isVisible)
        fixture.search.deliver([fixture.results[0]], request: 0)
        fixture.command("insertNewline:")
        #expect(fixture.openedResults.isEmpty)
        try await fixture.waitForQuery("current", count: 2)
        fixture.search.deliver([fixture.results[1]], request: 1)
        fixture.command("insertNewline:")
        #expect(fixture.openedResults == [fixture.results[1]])
        #expect(fixture.model.apps == fixture.entries)
        #expect(!fixture.switcher.isVisible)
    }

    @Test func searchArrowsSelectResultsWhileHorizontalArrowsMoveTheCaret() async throws {
        let fixture = SearchInputFixture()
        defer { fixture.close() }
        try fixture.show()
        let editor = try fixture.editor()
        editor.insertText("report", replacementRange: NSRange(location: 0, length: 0))
        try await fixture.waitForQuery("report")
        fixture.search.deliver(fixture.results, request: 0)
        fixture.command("moveDown:")
        let table = try fixture.table()
        #expect(table.selectedRow == 1)
        let originalCaret = editor.selectedRange().location
        fixture.command("moveLeft:")
        #expect(editor.selectedRange().location == originalCaret - 1)
        #expect(table.selectedRow == 1)
        fixture.command("moveRight:")
        #expect(editor.selectedRange().location == originalCaret)
        #expect(table.selectedRow == 1)
        fixture.command("moveUp:")
        #expect(table.selectedRow == 0)
        fixture.command("moveUp:")
        #expect(table.selectedRow == fixture.results.count - 1)
        fixture.command("insertNewline:")
        #expect(fixture.openedResults == [fixture.results[2]])
        #expect(fixture.model.apps == fixture.entries)
    }

    @Test func escapeClearsSearchAndRestoresTheOriginalAppSelectionBeforeClosing() async throws {
        let fixture = SearchInputFixture()
        defer { fixture.close() }
        try fixture.show()
        try fixture.editor().insertText("query", replacementRange: NSRange(location: 0, length: 0))
        try await fixture.waitForQuery("query")
        fixture.search.deliver(fixture.results, request: 0)
        fixture.command("moveDown:")
        fixture.command("cancelOperation:")
        #expect(try fixture.field().stringValue.isEmpty)
        #expect(fixture.switcher.isVisible)
        fixture.command("insertNewline:")
        #expect(fixture.openedAppIDs == [fixture.entries[1].id])
        #expect(fixture.openedResults.isEmpty)
        try fixture.show()
        fixture.command("cancelOperation:")
        #expect(!fixture.switcher.isVisible)
    }

    @Test func closingCancelsSearchAndAReopenedIdenticalQueryRejectsPreviousCallbacks() async throws {
        let fixture = SearchInputFixture()
        defer { fixture.close() }
        try fixture.show()
        try fixture.editor().insertText("same", replacementRange: NSRange(location: 0, length: 0))
        try await fixture.waitForQuery("same")
        let cancellations = fixture.search.cancelCount
        fixture.switcher.close()
        #expect(fixture.search.cancelCount > cancellations)
        try fixture.show()
        try fixture.editor().insertText("same", replacementRange: NSRange(location: 0, length: 0))
        try await fixture.waitForQuery("same", count: 2)
        fixture.search.deliver([fixture.results[0]], request: 0)
        fixture.command("insertNewline:")
        #expect(fixture.openedResults.isEmpty)
        #expect(fixture.switcher.isVisible)
        fixture.search.deliver([fixture.results[2]], request: 1)
        fixture.command("insertNewline:")
        #expect(fixture.openedResults == [fixture.results[2]])
    }

    @Test func markedKoreanTextDoesNotStartSearchOrConfirmAResult() async throws {
        let fixture = SearchInputFixture()
        defer { fixture.close() }
        try fixture.show()
        let editor = try fixture.editor()
        editor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        #expect(editor.hasMarkedText())
        let consumed = fixture.switcher.control(try fixture.field(), textView: editor, doCommandBy: NSSelectorFromString("insertNewline:"))
        #expect(!consumed)
        #expect(fixture.openedResults.isEmpty)
        #expect(fixture.openedAppIDs.isEmpty)
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.search.queries.isEmpty)
        #expect(fixture.switcher.isVisible)
    }
}

@MainActor
private final class SearchInputFixture {
    let entries = (0..<3).map {
        AppEntry(id: AppID(rawValue: "search-fixture-\($0)"), name: "앱 \($0)", bundlePath: "/fixture/\($0).app", isPinned: true)
    }
    let results = [
        SearchResult(url: URL(fileURLWithPath: "/fixture/Report.app"), name: "Report", kind: .application),
        SearchResult(url: URL(fileURLWithPath: "/fixture/Reports"), name: "Reports", kind: .folder),
        SearchResult(url: URL(fileURLWithPath: "/fixture/report.pdf"), name: "report.pdf", kind: .file),
    ]
    let search = ControllableSearch()
    var actions: [DockUIAction] = []
    var window: NSWindow?
    lazy var model = DockPresentationModel(imageForApp: { _ in NSImage(size: NSSize(width: 32, height: 32)) }) { [weak self] in
        self?.actions.append($0)
    }
    lazy var switcher = SwitcherController(model: model, search: search)

    init() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        if !application.isRunning { application.finishLaunching() }
        model.apps = entries
        model.items = entries.map { DockItem(app: $0, isRunning: false) }
    }

    var openedResults: [SearchResult] { actions.compactMap { if case let .openSearchResult(result) = $0 { result } else { nil } } }
    var openedAppIDs: [AppID] { actions.compactMap { if case let .open(id) = $0 { id } else { nil } } }

    func show() throws {
        switcher.show(direction: 1, currentID: entries[0].id)
        let candidate = NSApp.windows.first { $0.title == "앱 선택" && $0.isVisible }
        let openedWindow: NSWindow = try #require(candidate)
        window = openedWindow
        #expect(window?.makeFirstResponder(try field()) == true)
    }

    func field() throws -> NSSearchField {
        let candidate = searchDescendants(window?.contentView).compactMap { $0 as? NSSearchField }.first
        return try #require(candidate)
    }

    func editor() throws -> NSTextView { try #require(try field().currentEditor() as? NSTextView) }

    func table() throws -> NSTableView {
        let candidate = searchDescendants(window?.contentView).compactMap { $0 as? NSTableView }.first
        return try #require(candidate)
    }

    func command(_ selector: String) {
        (window?.firstResponder as? NSTextView)?.doCommand(by: NSSelectorFromString(selector))
    }

    func waitForQuery(_ query: String, count: Int = 1) async throws {
        try await Task.sleep(for: .milliseconds(150))
        #expect(search.queries.count == count)
        #expect(search.queries.last == query)
    }

    func close() { switcher.tearDown() }
}

@MainActor
private final class ControllableSearch: SpotlightSearching {
    var queries: [String] = []
    var callbacks: [@MainActor (SpotlightSearchUpdate) -> Void] = []
    var cancelCount = 0

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
private func searchDescendants(_ view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap { searchDescendants($0) }
}
