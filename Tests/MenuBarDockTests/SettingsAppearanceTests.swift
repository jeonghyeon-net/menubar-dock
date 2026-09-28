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
        #expect(views.contains { ($0 as? NSButton)?.title == "Finder 숨기기" })
        #expect(!views.contains { ($0 as? NSButton)?.title == "Dock 가져오기" })
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

    @Test func finderCheckboxPublishesPreferencesAndReflectsExternalChanges() async throws {
        let original = DockPreferences(iconSize: 20, slotWidth: 25, maxVisibleApps: 9)
        let fixture = AppearanceFixture(preferences: original)
        defer { fixture.settings.close() }
        fixture.settings.show()
        let controls = appearanceDescendants(of: fixture.settings.window?.contentView).compactMap { $0 as? NSButton }
        let checkbox = try #require(controls.first { $0.title == "Finder 숨기기" })
        let action = try #require(checkbox.action)
        #expect(checkbox.state == .off)
        // Swift Testing의 async 실행 안에 AppKit 추적 루프를 중첩하지 않고 체크 결과를 전달한다.
        checkbox.state = .on
        #expect(checkbox.sendAction(action, to: checkbox.target))
        var hidden = original
        hidden.hidesFinder = true
        #expect(fixture.changes == [hidden])
        #expect(fixture.model.preferences == hidden)
        #expect(checkbox.state == .on)
        checkbox.state = .off
        #expect(checkbox.sendAction(action, to: checkbox.target))
        #expect(fixture.changes == [hidden, original])
        #expect(fixture.model.preferences == original)
        fixture.model.preferences = hidden
        fixture.model.isReadOnly = true
        await Task.yield()
        await Task.yield()
        #expect(checkbox.state == .on)
        #expect(!checkbox.isEnabled)
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
