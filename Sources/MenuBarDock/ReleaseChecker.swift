import Foundation

enum ReleaseStatus: Equatable, Sendable {
    case current
    case unpublished
    case available(version: String, url: URL)
}

enum ReleaseCheckError: Error, LocalizedError {
    case invalidResponse
    case unavailable(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "업데이트 정보를 확인할 수 없습니다. 잠시 후 다시 시도해 주세요."
        case .unavailable(let code): "업데이트 서버에 연결할 수 없습니다(\(code)). 잠시 후 다시 시도해 주세요."
        }
    }
}

/// 명시적인 업데이트 확인 때만 통신한다. 다운로드한 실행 파일을 자동 실행하지 않는다.
actor ReleaseChecker {
    static let repository = "jeonghyeon-net/menubar-dock"

    func check(currentVersion: String) async throws -> ReleaseStatus {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest") else {
            throw ReleaseCheckError.invalidResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MenuBarDock/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ReleaseCheckError.invalidResponse }
        if response.statusCode == 404 { return .unpublished }
        guard response.statusCode == 200 else { throw ReleaseCheckError.unavailable(response.statusCode) }
        return try Self.interpret(data, currentVersion: currentVersion)
    }

    static func interpret(_ data: Data, currentVersion: String) throws -> ReleaseStatus {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease,
              let version = versionParts(release.tag_name),
              let current = versionParts(currentVersion),
              let url = URL(string: release.html_url),
              url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil,
              url.path.hasPrefix("/\(repository)/releases/tag/") else {
            throw ReleaseCheckError.invalidResponse
        }
        return current.lexicographicallyPrecedes(version)
            ? .available(version: release.tag_name, url: url) : .current
    }

    private static func versionParts(_ version: String) -> [Int]? {
        let raw = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let components = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else { return nil }
        let values = components.compactMap { Int($0) }
        guard values.count == 3, values.allSatisfy({ $0 >= 0 }) else { return nil }
        return values
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let draft: Bool
        let prerelease: Bool
    }
}
