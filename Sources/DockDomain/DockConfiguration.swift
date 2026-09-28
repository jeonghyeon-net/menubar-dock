import Foundation

public struct DockPreferences: Codable, Equatable, Sendable {
    public var iconSize: Double
    public var iconSpacing: Double
    public var maxVisibleApps: Int
    public var showsRunningApps: Bool
    public var isCompact: Bool
    public var shortcutEnabled: Bool

    public init(
        iconSize: Double = 18, iconSpacing: Double = 4, maxVisibleApps: Int = 6,
        showsRunningApps: Bool = true, isCompact: Bool = false, shortcutEnabled: Bool = true
    ) {
        self.iconSize = iconSize
        self.iconSpacing = iconSpacing
        self.maxVisibleApps = maxVisibleApps
        self.showsRunningApps = showsRunningApps
        self.isCompact = isCompact
        self.shortcutEnabled = shortcutEnabled
    }

    public func normalized() -> Self {
        var copy = self
        copy.iconSize = iconSize.isFinite ? min(max(iconSize, 14), 24) : 18
        copy.iconSpacing = iconSpacing.isFinite ? min(max(iconSpacing, 0), 12) : 4
        copy.maxVisibleApps = min(max(maxVisibleApps, 1), 20)
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case iconSize, iconSpacing, maxVisibleApps, showsRunningApps, isCompact, shortcutEnabled
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        iconSize = try values.decodeIfPresent(Double.self, forKey: .iconSize) ?? 18
        iconSpacing = try values.decodeIfPresent(Double.self, forKey: .iconSpacing) ?? 4
        maxVisibleApps = try values.decodeIfPresent(Int.self, forKey: .maxVisibleApps) ?? 6
        showsRunningApps = try values.decodeIfPresent(Bool.self, forKey: .showsRunningApps) ?? true
        isCompact = try values.decodeIfPresent(Bool.self, forKey: .isCompact) ?? false
        shortcutEnabled = try values.decodeIfPresent(Bool.self, forKey: .shortcutEnabled) ?? true
    }
}

public struct DockConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var apps: [AppEntry]
    public var order: [AppID]
    public var preferences: DockPreferences

    public init(
        schemaVersion: Int = Self.currentSchemaVersion, apps: [AppEntry] = [],
        order: [AppID] = [], preferences: DockPreferences = DockPreferences()
    ) {
        self.schemaVersion = schemaVersion
        self.apps = apps
        self.order = order
        self.preferences = preferences
    }

    /// 잘못된 참조를 제거하되 저장된 사용자 순서를 우선하여 복원한다.
    public func normalized() -> Self {
        var copy = self
        var knownIDs = Set<AppID>()
        copy.apps = apps.filter { !$0.id.rawValue.isEmpty && knownIDs.insert($0.id).inserted }
        var orderedIDs = Set<AppID>()
        copy.order = order.filter { knownIDs.contains($0) && orderedIDs.insert($0).inserted }
        for app in copy.apps where orderedIDs.insert(app.id).inserted {
            copy.order.append(app.id)
        }
        copy.preferences = preferences.normalized()
        return copy
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, apps, order, preferences }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        apps = try values.decodeIfPresent([AppEntry].self, forKey: .apps) ?? []
        order = try values.decodeIfPresent([AppID].self, forKey: .order) ?? []
        preferences = try values.decodeIfPresent(DockPreferences.self, forKey: .preferences) ?? DockPreferences()
    }
}
