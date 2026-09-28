import AppKit
import DockDomain

public enum ApplicationResolutionError: LocalizedError, Equatable, Sendable {
    case notFileURL
    case missingApplication
    case invalidApplication
    case missingExecutable

    public var errorDescription: String? {
        switch self {
        case .notFileURL: "로컬 응용 프로그램을 선택해 주세요."
        case .missingApplication: "응용 프로그램을 찾을 수 없습니다. 설정에서 경로를 다시 지정해 주세요."
        case .invalidApplication: "실행할 수 있는 .app 응용 프로그램을 선택해 주세요."
        case .missingExecutable: "이 응용 프로그램에는 실행 가능한 파일이 없습니다. 앱을 다시 설치해 주세요."
        }
    }
}

@MainActor
public final class ApplicationResolver {
    public init() {}

    public func resolve(url: URL) throws -> AppEntry {
        guard url.isFileURL else { throw ApplicationResolutionError.notFileURL }
        let canonicalURL = canonicalApplicationURL(url)
        guard FileManager.default.fileExists(atPath: canonicalURL.path) else {
            throw ApplicationResolutionError.missingApplication
        }
        let values = try canonicalURL.resourceValues(forKeys: [.isDirectoryKey])
        guard canonicalURL.pathExtension.lowercased() == "app", values.isDirectory == true,
              let bundle = Bundle(url: canonicalURL)
        else { throw ApplicationResolutionError.invalidApplication }
        let packageType = bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String
        // 시스템 Finder만 APPL 대신 FNDR을 사용한다. 다른 FNDR 번들까지 일반 앱으로 허용하지 않는다.
        let isSystemFinder = packageType == "FNDR" && bundle.bundleIdentifier == "com.apple.finder"
            && canonicalURL.path == "/System/Library/CoreServices/Finder.app"
        guard packageType == "APPL" || isSystemFinder else { throw ApplicationResolutionError.invalidApplication }
        guard let executableURL = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path)
        else { throw ApplicationResolutionError.missingExecutable }

        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        let name = [displayName, bundleName, canonicalURL.deletingPathExtension().lastPathComponent]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "이름 없는 앱"
        // sandbox 권한을 요구하지 않는 위치 추적용 bookmark만 저장한다.
        let bookmark = try canonicalURL.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil
        )
        return AppEntry(
            name: name,
            bundleIdentifier: bundle.bundleIdentifier,
            bundlePath: canonicalURL.path,
            bookmarkData: bookmark
        )
    }

    public func refresh(_ entry: AppEntry) -> AppEntry? {
        var candidates: [URL] = []
        if let bookmark = entry.bookmarkData {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                candidates.append(resolved)
            }
        }
        candidates.append(URL(fileURLWithPath: entry.bundlePath))
        for url in candidates {
            guard var updated = try? resolve(url: url) else { continue }
            // 같은 위치가 전혀 다른 앱으로 대체된 경우 자동 실행하지 않는다.
            if let expected = entry.bundleIdentifier, updated.bundleIdentifier != expected { continue }
            updated.id = entry.id
            updated.isPinned = entry.isPinned
            updated.isExcluded = entry.isExcluded
            updated.lastSeen = entry.lastSeen
            return updated
        }
        return nil
    }
}
