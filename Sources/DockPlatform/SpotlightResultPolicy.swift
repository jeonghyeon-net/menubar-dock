import Foundation

/// 검색 앱이 독립 실행 대상인지 SDK·플러그인·시스템의 내부 구성 요소인지 구분한다.
/// 경로 구성 요소로 비교하므로 Documents/Library 같은 일반 폴더 이름은 차단하지 않는다.
struct SpotlightResultPolicy: Sendable {
    private static let implementationPackages: Set<String> = ["framework", "sdk", "bundle", "plugin", "appex", "xpc", "kext", "lproj"]
    private static let documentPackages: Set<String> = ["pages", "numbers", "key", "rtfd", "photoslibrary", "playground", "xcodeproj", "xcworkspace"]
    private let infrastructureRoots: [[String]]
    private let systemRoots: [[String]]
    private let systemApplicationRoots: [[String]]

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemRoot: URL = URL(fileURLWithPath: "/", isDirectory: true)
    ) {
        let libraryInternals = [
            "Developer", "Caches", "Frameworks", "PrivateFrameworks",
            "Containers", "Group Containers", "Daemon Containers", "Logs", "Preferences",
            "Saved Application State", "WebKit", "HTTPStorages", "Cookies", "Metadata", "Safari",
            "Updates", "Apple", "LaunchAgents", "LaunchDaemons", "Extensions", "Internet Plug-Ins"
        ]
        infrastructureRoots = libraryInternals.flatMap { name in
            Self.paths(for: systemRoot.appendingPathComponent("Library/\(name)"))
                + Self.paths(for: homeDirectory.appendingPathComponent("Library/\(name)"))
        }
        // Application Support와 usr/local은 정상 앱 설치에도 쓰이므로 경로 전체를 제외하지 않는다.
        systemRoots = ["System", "usr/bin", "usr/sbin", "usr/lib", "usr/libexec", "bin", "sbin", "dev", "etc", "private/etc", "var/db", "var/log", "private/var/db", "private/var/log"]
            .flatMap { Self.paths(for: systemRoot.appendingPathComponent($0)) }
        systemApplicationRoots = [
            "System/Applications", "System/Library/CoreServices/Applications", "System/Library/CoreServices/Finder.app",
            "System/Cryptexes/App/System/Applications"
        ].flatMap { Self.paths(for: systemRoot.appendingPathComponent($0)) }
    }

    func allowsApplicationPath(_ url: URL) -> Bool {
        let components = Self.components(url)
        guard !components.contains(where: { $0.hasPrefix(".") }) else { return false }
        for (index, component) in components.enumerated() {
            let suffix = (component as NSString).pathExtension
            if Self.implementationPackages.contains(suffix) { return false }
            if index < components.count - 1, suffix == "app" || Self.documentPackages.contains(suffix) { return false }
        }
        // 앱 예외보다 먼저 적용해야 SDK나 플러그인 안의 helper.app도 새어 나오지 않는다.
        guard !infrastructureRoots.contains(where: { components.starts(with: $0) }) else { return false }
        if systemRoots.contains(where: { components.starts(with: $0) }) {
            return systemApplicationRoots.contains(where: { components.starts(with: $0) })
        }
        return true
    }

    private static func paths(for url: URL) -> [[String]] {
        [components(url), components(url.resolvingSymlinksInPath())]
    }

    private static func components(_ url: URL) -> [String] {
        url.standardizedFileURL.pathComponents.map { $0.lowercased() }
    }
}
