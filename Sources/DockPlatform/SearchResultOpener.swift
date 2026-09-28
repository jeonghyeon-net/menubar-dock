import AppKit
import DockDomain

public enum SearchResultOpenError: LocalizedError, Equatable, Sendable {
    case notFileURL
    case unavailable
    case cannotOpen

    public var errorDescription: String? {
        switch self {
        case .notFileURL: "로컬 파일이나 앱을 선택해 주세요."
        case .unavailable: "항목을 찾을 수 없거나 접근할 수 없습니다. 다시 검색해 주세요."
        case .cannotOpen: "항목을 열 수 없습니다. 파일 위치나 접근 권한을 확인해 주세요."
        }
    }
}

/// 검색 실행은 메뉴 막대 목록의 추가·정렬·삭제 기록을 변경하지 않는다.
@MainActor
public final class SearchResultOpener {
    private let openApplication: @MainActor (URL) async throws -> Void
    private let openDocument: @MainActor (URL) async throws -> Void

    public convenience init() {
        let resolver = ApplicationResolver()
        let launcher = ApplicationLauncher()
        self.init(openApplication: { url in
            try await launcher.open(resolver.resolve(url: url))
        }, openDocument: { url in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            configuration.promptsUserIfNeeded = false
            _ = try await NSWorkspace.shared.open(url, configuration: configuration)
        })
    }

    init(
        openApplication: @escaping @MainActor (URL) async throws -> Void,
        openDocument: @escaping @MainActor (URL) async throws -> Void
    ) {
        self.openApplication = openApplication
        self.openDocument = openDocument
    }

    public func open(_ result: SearchResult) async throws {
        guard result.url.isFileURL else { throw SearchResultOpenError.notFileURL }
        let url = canonicalApplicationURL(result.url)
        guard FileManager.default.fileExists(atPath: url.path), FileManager.default.isReadableFile(atPath: url.path) else {
            throw SearchResultOpenError.unavailable
        }
        if result.kind == .application {
            if let expected = result.bundleIdentifier, Bundle(url: url)?.bundleIdentifier != expected {
                throw SearchResultOpenError.unavailable
            }
            try await openApplication(url)
        } else {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let matchesKind = result.kind == .folder ? values?.isDirectory == true : values?.isRegularFile == true
            guard matchesKind, url.pathExtension.lowercased() != "app" else { throw SearchResultOpenError.unavailable }
            do { try await openDocument(url) }
            catch { throw SearchResultOpenError.cannotOpen }
        }
    }
}
