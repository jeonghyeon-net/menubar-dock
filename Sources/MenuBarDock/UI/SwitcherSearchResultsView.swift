import AppKit
import DockDomain

/// 입력 포커스를 유지한 채 결과만 갱신하는 네이티브 목록이다.
@MainActor
final class SwitcherSearchResultsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let scroll = NSScrollView()
    private let table = SearchResultsTable()
    private let message = NSTextField(labelWithString: "")
    private var results: [SearchResult] = []
    var openResult: ((SearchResult) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(openClickedResult)
        table.setAccessibilityLabel("Spotlight 검색 결과")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        addSubview(scroll)
        message.font = .systemFont(ofSize: 13)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.lineBreakMode = .byTruncatingTail
        addSubview(message)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        table.tableColumns.first?.width = scroll.contentSize.width
        message.frame = NSRect(x: 12, y: (bounds.height - 22) / 2, width: max(0, bounds.width - 24), height: 22)
    }

    func update(results: [SearchResult], selectedID: String?, message text: String) {
        if self.results != results {
            self.results = results
            table.reloadData()
        }
        if let index = results.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        } else { table.deselectAll(nil) }
        message.stringValue = text
        message.isHidden = !results.isEmpty
        scroll.isHidden = results.isEmpty
        needsLayout = true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row) else { return nil }
        let result = results[row]
        let cell = SearchResultCell(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: 44))
        cell.configure(result)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SearchResultRow()
    }

    @objc private func openClickedResult() {
        guard results.indices.contains(table.clickedRow) else { return }
        openResult?(results[table.clickedRow])
    }
}

@MainActor
private final class SearchResultsTable: NSTableView {
    // 행 아래 빈 곳이나 스크롤 영역을 눌러도 타이핑은 검색창에 이어진다.
    override var acceptsFirstResponder: Bool { false }
}

@MainActor
private final class SearchResultRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

@MainActor
private final class SearchResultCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let location = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        location.font = .systemFont(ofSize: 11)
        location.textColor = .secondaryLabelColor
        location.lineBreakMode = .byTruncatingMiddle
        addSubview(icon)
        addSubview(name)
        addSubview(location)
        imageView = icon
        textField = name
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ result: SearchResult) {
        name.stringValue = result.name
        let parent = result.url.deletingLastPathComponent().path
        location.stringValue = (parent as NSString).abbreviatingWithTildeInPath
        icon.image = NSWorkspace.shared.icon(forFile: result.url.path)
        toolTip = result.url.path
        setAccessibilityLabel("\(result.name), \(location.stringValue)")
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 8, y: 6, width: 32, height: 32)
        name.frame = NSRect(x: 50, y: 23, width: max(0, bounds.width - 62), height: 17)
        location.frame = NSRect(x: 50, y: 5, width: max(0, bounds.width - 62), height: 16)
    }
}
