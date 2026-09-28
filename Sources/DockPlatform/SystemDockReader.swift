import AppKit
import CoreFoundation

public enum SystemDockReaderError: LocalizedError, Equatable, Sendable {
    case unavailablePreferences
    case invalidApplicationList

    public var errorDescription: String? {
        switch self {
        case .unavailablePreferences: "macOS Dock 설정을 읽지 못했습니다. 잠시 후 다시 가져와 주세요."
        case .invalidApplicationList: "macOS Dock의 고정 앱 목록을 읽을 수 없습니다."
        }
    }
}

/// macOS Dock의 고정 앱을 읽기만 한다. 앱 실행이나 Dock 설정 변경은 수행하지 않는다.
@MainActor
public final class SystemDockReader {
    private let readDomain: () throws -> [String: Any]?
    private let finderURL: URL
    private let applicationExists: (URL) -> Bool
    private let resolveBookmark: (Data) -> URL?
    private let resolveBundle: (String) -> URL?

    public convenience init() {
        self.init(
            readDomain: {
                // 파일 변경 뒤에도 UserDefaults 객체의 이전 스냅샷을 재사용하지 않는다.
                let identifier = "com.apple.dock" as CFString
                CFPreferencesAppSynchronize(identifier)
                return CFPreferencesCopyMultiple(nil, identifier, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any]
            },
            finderURL: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
            applicationExists: { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            },
            resolveBookmark: { data in
                var stale = false
                return try? URL(
                    resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                    relativeTo: nil, bookmarkDataIsStale: &stale
                )
            },
            resolveBundle: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        )
    }

    init(
        readDomain: @escaping () throws -> [String: Any]?, finderURL: URL,
        applicationExists: @escaping (URL) -> Bool,
        resolveBookmark: @escaping (Data) -> URL?,
        resolveBundle: @escaping (String) -> URL?
    ) {
        self.readDomain = readDomain
        self.finderURL = finderURL
        self.applicationExists = applicationExists
        self.resolveBookmark = resolveBookmark
        self.resolveBundle = resolveBundle
    }

    public func applicationURLs() throws -> [URL] {
        guard let domain = try readDomain() else { throw SystemDockReaderError.unavailablePreferences }
        guard let tiles = domain["persistent-apps"] as? [Any] else { throw SystemDockReaderError.invalidApplicationList }
        var applications: [URL] = []
        var seenPaths = Set<String>()

        func append(_ url: URL) {
            guard let application = existingApplication(url), seenPaths.insert(application.path).inserted else { return }
            applications.append(application)
        }

        // Finder는 persistent-apps에 없는 시스템 고정 항목이므로 명시적으로 앞에 둔다.
        append(finderURL)
        for value in tiles {
            guard let tile = value as? [String: Any], tile["tile-type"] as? String == "file-tile",
                  let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let path = file["_CFURLString"] as? String,
                  let url = URL(string: path), isLocalApplicationURL(url) else { continue }
            if let application = existingApplication(url) {
                append(application)
                continue
            }
            // 저장 경로가 사라진 경우만 복원을 시도해 유효한 별도 설치본을 다른 앱으로 바꾸지 않는다.
            if let bookmark = data["book"] as? Data,
               let restored = resolveBookmark(bookmark), let application = existingApplication(restored) {
                append(application)
                continue
            }
            if let identifier = data["bundle-identifier"] as? String, !identifier.isEmpty,
               let resolved = resolveBundle(identifier) {
                append(resolved)
            }
        }
        return applications
    }

    private func existingApplication(_ url: URL) -> URL? {
        guard isLocalApplicationURL(url) else { return nil }
        let canonical = canonicalApplicationURL(url)
        guard isLocalApplicationURL(canonical), applicationExists(canonical) else { return nil }
        return canonical
    }

    private func isLocalApplicationURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return url.isFileURL && (host.isEmpty || host == "localhost") && url.path.hasPrefix("/")
            && url.pathExtension.lowercased() == "app" && url.query == nil && url.fragment == nil
    }
}
