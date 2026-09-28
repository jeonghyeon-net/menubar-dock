import Foundation

public struct DockPreferences: Codable, Equatable, Sendable {
    public var iconSize: Double
    public var slotWidth: Double
    public var maxVisibleApps: Int
    public var showsRunningApps: Bool
    public var shortcutEnabled: Bool

    public init(
        iconSize: Double = 24, slotWidth: Double = 24, maxVisibleApps: Int = 6,
        showsRunningApps: Bool = true, shortcutEnabled: Bool = true
    ) {
        self.iconSize = iconSize
        self.slotWidth = slotWidth
        self.maxVisibleApps = maxVisibleApps
        self.showsRunningApps = showsRunningApps
        self.shortcutEnabled = shortcutEnabled
    }

    public func normalized() -> Self {
        var copy = self
        copy.iconSize = iconSize.isFinite ? min(max(iconSize, 16), 32) : 24
        copy.slotWidth = slotWidth.isFinite ? min(max(slotWidth, 16), 60) : 24
        copy.slotWidth = min(max(copy.slotWidth, copy.iconSize), copy.iconSize + 28)
        copy.maxVisibleApps = min(max(maxVisibleApps, 1), 20)
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case iconSize, slotWidth, maxVisibleApps, showsRunningApps, shortcutEnabled
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        iconSize = try values.decodeIfPresent(Double.self, forKey: .iconSize) ?? 24
        slotWidth = try values.decodeIfPresent(Double.self, forKey: .slotWidth) ?? 24
        maxVisibleApps = try values.decodeIfPresent(Int.self, forKey: .maxVisibleApps) ?? 6
        showsRunningApps = try values.decodeIfPresent(Bool.self, forKey: .showsRunningApps) ?? true
        shortcutEnabled = try values.decodeIfPresent(Bool.self, forKey: .shortcutEnabled) ?? true
    }
}

public struct DockConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var apps: [AppEntry]
    public var order: [AppID]
    public var preferences: DockPreferences
    /// 이전 저장 이름을 유지한다. 현재 의미는 실행 숨김이 아닌 Dock 자동 등록 억제 기록이다.
    public var removedApps: [AppEntry]
    public var knownSystemDockPaths: [String]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion, apps: [AppEntry] = [],
        order: [AppID] = [], preferences: DockPreferences = DockPreferences(),
        removedApps: [AppEntry] = [], knownSystemDockPaths: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.apps = apps
        self.order = order
        self.preferences = preferences
        self.removedApps = removedApps
        self.knownSystemDockPaths = knownSystemDockPaths
    }

    /// 잘못된 참조를 제거하되 저장된 사용자 순서를 우선하여 복원한다.
    public func normalized() -> Self {
        var copy = self
        var removedIDs = Set<AppID>()
        copy.removedApps = removedApps.filter { !$0.id.rawValue.isEmpty && removedIDs.insert($0.id).inserted }
        let removedEntries = copy.removedApps
        var knownIDs = Set<AppID>()
        copy.apps = apps.filter { app in
            !app.id.rawValue.isEmpty && knownIDs.insert(app.id).inserted
        }.map { app in
            var observed = app
            if removedEntries.contains(where: { $0.id == app.id || sameInstallation($0, app) }) {
                observed.isPinned = false
            }
            return observed
        }
        var orderedIDs = Set<AppID>()
        copy.order = order.filter { knownIDs.contains($0) && orderedIDs.insert($0).inserted }
        for app in copy.apps where orderedIDs.insert(app.id).inserted {
            copy.order.append(app.id)
        }
        copy.preferences = preferences.normalized()
        var knownPaths = Set<String>()
        copy.knownSystemDockPaths = knownSystemDockPaths.filter { !$0.isEmpty }.map(installationPath)
            .filter { knownPaths.insert($0).inserted }
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, apps, order, preferences, removedApps, knownSystemDockPaths
        case hasImportedSystemDock
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        apps = try values.decodeIfPresent([AppEntry].self, forKey: .apps) ?? []
        order = try values.decodeIfPresent([AppID].self, forKey: .order) ?? []
        preferences = try values.decodeIfPresent(DockPreferences.self, forKey: .preferences) ?? DockPreferences()
        removedApps = try values.decodeIfPresent([AppEntry].self, forKey: .removedApps) ?? []
        if let knownPaths = try values.decodeIfPresent([String].self, forKey: .knownSystemDockPaths) {
            knownSystemDockPaths = knownPaths
        } else {
            // 이전 일회성 가져오기를 완료한 앱은 이미 알려진 것으로 두어 수동 고정 해제를 존중한다.
            let imported = try values.decodeIfPresent(Bool.self, forKey: .hasImportedSystemDock) ?? false
            knownSystemDockPaths = imported ? apps.map(\.bundlePath) : []
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(apps, forKey: .apps)
        try values.encode(order, forKey: .order)
        try values.encode(preferences, forKey: .preferences)
        try values.encode(removedApps, forKey: .removedApps)
        try values.encode(knownSystemDockPaths, forKey: .knownSystemDockPaths)
    }
}

// 실제 심볼릭 링크 해석은 OS 경계에서 수행한다. 도메인은 전달받은 설치 경로의 표기만 정리한다.
func installationPath(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

func sameInstallation(_ lhs: AppEntry, _ rhs: AppEntry) -> Bool {
    guard !lhs.bundlePath.isEmpty, !rhs.bundlePath.isEmpty,
          installationPath(lhs.bundlePath) == installationPath(rhs.bundlePath) else { return false }
    guard let left = lhs.bundleIdentifier, let right = rhs.bundleIdentifier else { return true }
    return left == right
}
