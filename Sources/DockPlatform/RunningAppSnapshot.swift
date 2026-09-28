import AppKit

/// AppKit 객체의 수명과 격리를 도메인 밖에 유지하는 실행 앱 스냅샷이다.
public struct RunningAppSnapshot: Equatable, Sendable {
    public let processIdentifier: Int32
    public let bundleURL: URL?
    public let bundleIdentifier: String?
    public let name: String
    public let isRegular: Bool
    public let isActive: Bool
    public let isHidden: Bool
    public let launchDate: Date?

    public init(
        processIdentifier: Int32,
        bundleURL: URL?,
        bundleIdentifier: String?,
        name: String,
        isRegular: Bool,
        isActive: Bool,
        isHidden: Bool,
        launchDate: Date?
    ) {
        self.processIdentifier = processIdentifier
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.isRegular = isRegular
        self.isActive = isActive
        self.isHidden = isHidden
        self.launchDate = launchDate
    }

    @MainActor
    init(application: NSRunningApplication, activeOverride: Bool? = nil) {
        self.init(
            processIdentifier: application.processIdentifier,
            bundleURL: application.bundleURL,
            bundleIdentifier: application.bundleIdentifier,
            name: application.localizedName ?? application.bundleURL?.deletingPathExtension().lastPathComponent ?? "이름 없는 앱",
            isRegular: application.activationPolicy == .regular,
            isActive: activeOverride ?? application.isActive,
            isHidden: application.isHidden,
            launchDate: application.launchDate
        )
    }
}

/// 심볼릭 링크 표기 차이는 합치되 bundle identifier가 같은 별도 설치는 구분한다.
func canonicalApplicationURL(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
}
