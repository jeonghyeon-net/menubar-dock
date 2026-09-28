import Foundation
import DockDomain

public enum SearchResultOpenError: LocalizedError, Equatable, Sendable {
    case notFileURL
    case notApplication
    case unavailable
    case cannotOpen

    public var errorDescription: String? {
        switch self {
        case .notFileURL: "로컬 응용 프로그램을 선택해 주세요."
        case .notApplication: "실행할 수 있는 응용 프로그램을 선택해 주세요."
        case .unavailable: "항목을 찾을 수 없거나 접근할 수 없습니다. 다시 검색해 주세요."
        case .cannotOpen: "응용 프로그램을 열 수 없습니다. 앱 위치나 접근 권한을 확인해 주세요."
        }
    }
}

/// 검색 실행은 메뉴 막대 목록의 추가·정렬·삭제 기록을 변경하지 않는다.
@MainActor
public final class SearchResultOpener {
    private let openApplication: @MainActor (AppEntry) async throws -> Void

    public convenience init() {
        let launcher = ApplicationLauncher()
        self.init(openApplication: { try await launcher.open($0) })
    }

    init(
        openApplication: @escaping @MainActor (AppEntry) async throws -> Void
    ) {
        self.openApplication = openApplication
    }

    public func open(_ result: SearchResult) async throws {
        guard result.url.isFileURL else { throw SearchResultOpenError.notFileURL }
        guard result.kind == .application else { throw SearchResultOpenError.notApplication }
        // 선택 뒤 삭제·교체되거나 링크 대상이 바뀌었을 수 있어 검색 정책과 실행 파일을 다시 검증한다.
        guard let current = SpotlightSearchService.resolve(SpotlightMetadataResult(url: result.url, name: result.name)),
              let entry = try? ApplicationResolver().resolve(url: current.url) else {
            throw SearchResultOpenError.unavailable
        }
        if let expected = result.bundleIdentifier, entry.bundleIdentifier != expected {
            throw SearchResultOpenError.unavailable
        }
        do { try await openApplication(entry) }
        catch { throw SearchResultOpenError.cannotOpen }
    }
}
