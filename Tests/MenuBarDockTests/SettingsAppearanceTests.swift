import AppKit
import DockDomain
import Testing
@testable import MenuBarDock

@Suite(.serialized)
@MainActor
struct SettingsAppearanceTests {
    @Test func allSettingsAreAvailableTogetherWithoutTabsOrCards() throws {
        let fixture = AppearanceFixture()
        defer { fixture.settings.close() }
        fixture.settings.show()
        let window = try #require(fixture.settings.window)
        let views = appearanceDescendants(of: window.contentView)
        #expect(!views.contains { $0 is NSTabView })
        #expect(views.compactMap { $0 as? NSBox }.allSatisfy { $0.boxType == .separator })
        #expect(views.compactMap { $0 as? NSScrollView }.allSatisfy { $0.borderType == .noBorder })
        #expect(views.contains { ($0 as? NSSlider)?.accessibilityLabel() == "아이콘 크기" })
        #expect(views.contains { ($0 as? NSSlider)?.accessibilityLabel() == "아이콘 간격" })
        #expect(views.contains { ($0 as? NSButton)?.accessibilityLabel() == "다음 앱 단축키 변경" })
        #expect(views.contains { ($0 as? NSTableView)?.accessibilityLabel() == "숨길 앱" })
        #expect(!views.contains { ($0 as? NSButton)?.title == "Dock 가져오기" })
    }

    @Test func savedAndHiddenRowsRemainVisibleAtMinimumWindowSize() throws {
        let fixture = AppearanceFixture()
        let app = AppEntry(id: AppID(rawValue: "hidden-row"), name: "이름이 아주 긴 등록 앱", bundlePath: "/fixture/Hidden.app")
        fixture.model.apps = [app]
        fixture.model.hiddenApps = [app]
        fixture.model.hiddenSavedAppIDs = [app.id]
        defer { fixture.settings.close() }
        fixture.settings.show()
        let window = try #require(fixture.settings.window)
        window.setContentSize(window.contentMinSize)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let tables = appearanceDescendants(of: content).compactMap { $0 as? NSTableView }
        #expect(tables.count == 2)
        for table in tables {
            let scroll = try #require(table.enclosingScrollView)
            let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
            #expect(cell.frame.maxX <= scroll.contentView.bounds.width)
            #expect(cell.frame.height >= 20)
        }
        let saved = try #require(tables.first { $0.accessibilityLabel() == "항상 표시할 앱" })
        let cell = try #require(saved.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let hiddenHint = try #require(appearanceDescendants(of: cell).compactMap { $0 as? NSTextField }.first { $0.stringValue == "숨김" })
        #expect(cell.bounds.contains(hiddenHint.frame))
        let left = saved.convert(saved.bounds, to: content)
        let hidden = try #require(tables.first { $0.accessibilityLabel() == "숨길 앱" })
        let right = hidden.convert(hidden.bounds, to: content)
        #expect(left.maxX < right.minX)
    }

    @Test func restoringIconLayoutPreservesTheOtherPreferences() async throws {
        let original = DockPreferences(
            iconSize: 32, slotWidth: 54, maxVisibleApps: 3,
            showsRunningApps: false, shortcutEnabled: false, hidesFinder: true
        )
        let fixture = AppearanceFixture(preferences: original)
        defer { fixture.settings.close() }
        fixture.settings.show()
        let reset = try fixture.resetButton()
        let action = try #require(reset.action)
        #expect(reset.sendAction(action, to: reset.target))
        let updated = try #require(fixture.changes.last)
        #expect(updated.iconSize == 24)
        #expect(updated.slotWidth == 24)
        #expect(updated.maxVisibleApps == original.maxVisibleApps)
        #expect(updated.showsRunningApps == original.showsRunningApps)
        #expect(updated.shortcutEnabled == original.shortcutEnabled)
        #expect(updated.hidesFinder == original.hidesFinder)
        await Task.yield()
        await Task.yield()
        let values = appearanceDescendants(of: fixture.settings.window?.contentView).compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(values.contains("24pt"))
        #expect(values.contains("0pt"))
    }

    @Test func hiddenAppMenuAndRestoreControlsHandleMultipleAppsAndReadOnlyState() async throws {
        let fixture = AppearanceFixture()
        let entries = (1...3).map { AppEntry(id: AppID(rawValue: "hide-\($0)"), name: "앱 \($0)", bundlePath: "/fixture/\($0).app") }
        fixture.model.hideableApps = entries
        defer { fixture.settings.close() }
        fixture.settings.show()
        let views = appearanceDescendants(of: fixture.settings.window?.contentView)
        let menuButton = try #require(views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "앱 숨기기" })
        let table = try #require(views.compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == "숨길 앱" })
        let restore = try #require(views.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "숨김 해제" })
        #expect(!restore.isEnabled)
        for entry in entries.prefix(2) {
            let item = try #require(menuButton.item(withTitle: entry.name))
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
            await Task.yield()
            await Task.yield()
        }
        #expect(table.numberOfRows == 2)
        #expect(fixture.model.hiddenApps == Array(entries.prefix(2)))
        table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)
        #expect(restore.isEnabled)
        #expect(restore.sendAction(try #require(restore.action), to: restore.target))
        await Task.yield()
        await Task.yield()
        #expect(table.numberOfRows == 0)
        #expect(!restore.isEnabled)
        fixture.model.hiddenApps = entries
        fixture.model.isReadOnly = true
        await Task.yield()
        await Task.yield()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(!menuButton.isEnabled)
        #expect(!restore.isEnabled)
    }

    @Test func changingIconSizePreservesSpacingAndSpacingCanReachZero() async throws {
        let fixture = AppearanceFixture(preferences: DockPreferences(iconSize: 24, slotWidth: 28))
        defer { fixture.settings.close() }
        fixture.settings.show()
        let sliders = appearanceDescendants(of: fixture.settings.window?.contentView).compactMap { $0 as? NSSlider }
        let icon = try #require(sliders.first { $0.accessibilityLabel() == "아이콘 크기" })
        let spacing = try #require(sliders.first { $0.accessibilityLabel() == "아이콘 간격" })
        let iconAction = try #require(icon.action)
        let spacingAction = try #require(spacing.action)
        #expect(spacing.minValue == 0)
        #expect(spacing.maxValue == 28)
        #expect(spacing.doubleValue == 4)
        for iconSize in [32.0, 16.0] {
            icon.doubleValue = iconSize
            #expect(icon.sendAction(iconAction, to: icon.target))
            #expect(fixture.model.preferences.iconSize == iconSize)
            #expect(fixture.model.preferences.slotWidth == iconSize + 4)
        }
        spacing.doubleValue = 0
        #expect(spacing.sendAction(spacingAction, to: spacing.target))
        #expect(fixture.model.preferences.slotWidth == fixture.model.preferences.iconSize)
        await Task.yield()
        await Task.yield()
        #expect(spacing.doubleValue == 0)
        #expect(spacing.minValue == 0)
        #expect(spacing.maxValue == 28)
    }

    @Test func readOnlySettingsCannotRestoreIconLayout() throws {
        let fixture = AppearanceFixture()
        fixture.model.isReadOnly = true
        defer { fixture.settings.close() }
        fixture.settings.show()
        let reset = try fixture.resetButton()
        #expect(!reset.isEnabled)
        #expect(fixture.changes.isEmpty)
    }

    @Test func removingRowsSelectsTheNextAppAndDisablesRemovalWhenEmpty() async throws {
        let fixture = AppearanceFixture()
        let entries = (1...3).map {
            AppEntry(id: AppID(rawValue: "row-\($0)"), name: "앱 \($0)", bundlePath: "/fixture/\($0).app")
        }
        fixture.model.apps = entries
        defer { fixture.settings.close() }
        fixture.settings.show()
        let views = appearanceDescendants(of: fixture.settings.window?.contentView)
        let table = try #require(views.compactMap { $0 as? NSTableView }.first)
        let remove = try #require(views.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "목록에서 제거" })
        let action = try #require(remove.action)
        #expect(!remove.isEnabled)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        for (remaining, selectedRow) in [(2, 1), (1, 0), (0, -1)] {
            #expect(remove.isEnabled)
            #expect(remove.sendAction(action, to: remove.target))
            await Task.yield()
            await Task.yield()
            #expect(table.numberOfRows == remaining)
            #expect(table.selectedRow == selectedRow)
        }
        #expect(fixture.removedIDs == [entries[1].id, entries[2].id, entries[0].id])
        #expect(!remove.isEnabled)
    }
}

@MainActor
private final class AppearanceFixture {
    var changes: [DockPreferences] = []
    var removedIDs: [AppID] = []
    lazy var model: DockPresentationModel = DockPresentationModel(imageForApp: { _ in NSImage() }) { [weak self] action in
        guard let self else { return }
        switch action {
        case let .preferences(preferences):
            changes.append(preferences)
            model.preferences = preferences.normalized()
        case let .hideFromDock(app):
            model.hiddenApps.append(app)
            model.hideableApps.removeAll { $0.id == app.id }
        case let .restoreHiddenApp(id):
            model.hiddenApps.removeAll { $0.id == id }
        case let .remove(id):
            removedIDs.append(id)
            model.apps.removeAll { $0.id == id }
        default: break
        }
    }
    lazy var settings = SettingsWindowController(model: model)

    init(preferences: DockPreferences = DockPreferences()) {
        _ = NSApplication.shared
        model.preferences = preferences
    }

    func resetButton() throws -> NSButton {
        try #require(appearanceDescendants(of: settings.window?.contentView).compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel() == "아이콘 크기 및 간격 기본값"
        })
    }
}

@MainActor
private func appearanceDescendants(of view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap { appearanceDescendants(of: $0) }
}
