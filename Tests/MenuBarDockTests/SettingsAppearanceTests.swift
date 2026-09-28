import AppKit
import DockDomain
import Testing
@testable import MenuBarDock

@Suite(.serialized)
@MainActor
struct SettingsAppearanceTests {
    @Test func appearanceShortcutSelectsThePaneWithoutMovingTheTitleBar() throws {
        let fixture = AppearanceFixture()
        defer { fixture.settings.close() }
        fixture.settings.show(tab: .shortcuts)
        let window = try #require(fixture.settings.window)
        let previousFrame = window.frame
        fixture.settings.show(tab: .appearance)
        let tabs = try #require(appearanceDescendants(of: window.contentView).compactMap { $0 as? NSTabView }.first)
        #expect(tabs.selectedTabViewItem?.identifier as? String == "표시")
        #expect(window.frame.maxY == previousFrame.maxY)
        #expect(window.frame.width == previousFrame.width)
        fixture.settings.show()
        #expect(tabs.selectedTabViewItem?.identifier as? String == "표시")
    }

    @Test func restoringIconLayoutPreservesTheOtherPreferences() async throws {
        let original = DockPreferences(
            iconSize: 32, slotWidth: 54, maxVisibleApps: 3,
            showsRunningApps: false, shortcutEnabled: false
        )
        let fixture = AppearanceFixture(preferences: original)
        defer { fixture.settings.close() }
        fixture.settings.show(tab: .appearance)
        let reset = try fixture.resetButton()
        let action = try #require(reset.action)
        #expect(reset.sendAction(action, to: reset.target))
        let updated = try #require(fixture.changes.last)
        #expect(updated.iconSize == 24)
        #expect(updated.slotWidth == 30)
        #expect(updated.maxVisibleApps == original.maxVisibleApps)
        #expect(updated.showsRunningApps == original.showsRunningApps)
        #expect(updated.shortcutEnabled == original.shortcutEnabled)
        await Task.yield()
        await Task.yield()
        let values = appearanceDescendants(of: fixture.settings.window?.contentView).compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(values.contains("24pt"))
        #expect(values.contains("30pt"))
    }

    @Test func readOnlySettingsCannotRestoreIconLayout() throws {
        let fixture = AppearanceFixture()
        fixture.model.isReadOnly = true
        defer { fixture.settings.close() }
        fixture.settings.show(tab: .appearance)
        let reset = try fixture.resetButton()
        #expect(!reset.isEnabled)
        #expect(fixture.changes.isEmpty)
    }
}

@MainActor
private final class AppearanceFixture {
    var changes: [DockPreferences] = []
    lazy var model: DockPresentationModel = DockPresentationModel(imageForApp: { _ in NSImage() }) { [weak self] action in
        guard let self, case let .preferences(preferences) = action else { return }
        changes.append(preferences)
        model.preferences = preferences
    }
    lazy var settings = SettingsWindowController(model: model)

    init(preferences: DockPreferences = DockPreferences()) {
        _ = NSApplication.shared
        model.preferences = preferences
    }

    func resetButton() throws -> NSButton {
        try #require(appearanceDescendants(of: settings.window?.contentView).compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel() == "아이콘 크기 및 영역 너비 기본값"
        })
    }
}

@MainActor
private func appearanceDescendants(of view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap { appearanceDescendants(of: $0) }
}
