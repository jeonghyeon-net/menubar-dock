import Foundation

/// 실행 프로세스와 독립된 설치 앱의 영속 식별자다.
public struct AppID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { rawValue = UUID().uuidString }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AppEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: AppID
    public var name: String
    public var bundleIdentifier: String?
    public var bundlePath: String
    public var bookmarkData: Data?
    public var isPinned: Bool
    public var isExcluded: Bool
    public var lastSeen: Date

    public init(
        id: AppID = AppID(), name: String, bundleIdentifier: String? = nil,
        bundlePath: String, bookmarkData: Data? = nil, isPinned: Bool = false,
        isExcluded: Bool = false, lastSeen: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.bookmarkData = bookmarkData
        self.isPinned = isPinned
        self.isExcluded = isExcluded
        self.lastSeen = lastSeen
    }
}

public struct DockItem: Equatable, Sendable, Identifiable {
    public let app: AppEntry
    public let isRunning: Bool
    public var id: AppID { app.id }

    public init(app: AppEntry, isRunning: Bool) {
        self.app = app
        self.isRunning = isRunning
    }
}
