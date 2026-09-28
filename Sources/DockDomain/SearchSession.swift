import Foundation

/// 검색어와 선택을 함께 관리해 늦게 도착한 검색 결과가 실행 대상을 바꾸지 못하게 한다.
public struct SearchSession: Equatable, Sendable {
    public private(set) var query: String
    public private(set) var results: [SearchResult]
    public private(set) var selectedID: String?

    public init() {
        query = ""
        results = []
        selectedID = nil
    }

    public var selectedResult: SearchResult? {
        guard let selectedID else { return nil }
        return results.first { $0.id == selectedID }
    }

    public mutating func updateQuery(_ text: String) {
        guard text != query else { return }
        query = text
        // 비동기 검색을 기다리는 동안 Enter를 눌러도 이전 검색 항목을 열지 않는다.
        results = []
        selectedID = nil
    }

    public mutating func receive(_ results: [SearchResult], for query: String) {
        guard query == self.query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var seen = Set<String>()
        self.results = results.filter { seen.insert($0.id).inserted }
        if let selectedID, self.results.contains(where: { $0.id == selectedID }) { return }
        selectedID = self.results.first?.id
    }

    public mutating func move(_ distance: Int) {
        guard !results.isEmpty else { selectedID = nil; return }
        guard let selectedID, let index = results.firstIndex(where: { $0.id == selectedID }) else {
            self.selectedID = distance < 0 ? results.last?.id : results.first?.id
            return
        }
        // 큰 반복 입력과 Int.min도 배열 길이로 먼저 줄여 안전하게 순환한다.
        let offset = distance % results.count
        let target = (index + offset + results.count) % results.count
        self.selectedID = results[target].id
    }

    public mutating func reset() {
        self = SearchSession()
    }
}
