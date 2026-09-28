import Foundation

/// Spotlight의 검색 결과를 OS 객체에 의존하지 않는 값으로 전달한다.
public struct SearchResult: Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case application
        case folder
        case file
    }

    public let url: URL
    public let name: String
    public let kind: Kind
    public let bundleIdentifier: String?

    public var id: String { url.standardizedFileURL.path }

    public init(url: URL, name: String, kind: Kind, bundleIdentifier: String? = nil) {
        self.url = url
        self.name = name
        self.kind = kind
        self.bundleIdentifier = bundleIdentifier
    }
}
