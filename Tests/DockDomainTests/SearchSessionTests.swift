import DockDomain
import Foundation
import Testing

private func searchResult(_ name: String, kind: SearchResult.Kind = .file) -> SearchResult {
    SearchResult(url: URL(fileURLWithPath: "/Search/\(name)"), name: name, kind: kind)
}

@Suite("검색 결과와 선택 상태")
struct SearchSessionTests {
    @Test("검색어 변경 직후에는 이전 항목을 선택할 수 없고 이전 응답도 무시한다")
    func changingQueryInvalidatesSelectionAndRejectsStaleResults() {
        let old = searchResult("old.txt")
        let current = searchResult("current.txt")
        var session = SearchSession()
        session.updateQuery("old")
        session.receive([old], for: "old")
        #expect(session.selectedResult == old)

        session.updateQuery("current")
        #expect(session.results.isEmpty)
        #expect(session.selectedResult == nil)
        session.receive([old], for: "old")
        #expect(session.results.isEmpty)
        session.receive([current], for: "current")
        #expect(session.selectedResult == current)
        session.receive([old], for: "old")
        #expect(session.results == [current])
        #expect(session.selectedResult == current)
    }

    @Test("같은 검색의 후속 응답은 사용자 선택을 유지하고 삭제된 선택만 첫 항목으로 바꾼다")
    func updatesPreserveSelectionUntilResultIsRemoved() {
        let first = searchResult("first.txt")
        let selected = searchResult("selected.app", kind: .application)
        let last = searchResult("folder", kind: .folder)
        var session = SearchSession()
        session.updateQuery("name")
        session.receive([first, selected], for: "name")
        session.move(1)
        session.updateQuery("name")
        #expect(session.selectedResult == selected)

        let renamed = SearchResult(url: selected.url, name: "새 표시 이름", kind: .application, bundleIdentifier: "test.app")
        session.receive([last, renamed, first], for: "name")
        #expect(session.results == [last, renamed, first])
        #expect(session.selectedResult == renamed)
        session.receive([last, first], for: "name")
        #expect(session.selectedResult == last)
        session.receive([], for: "name")
        #expect(session.selectedID == nil)
        #expect(session.selectedResult == nil)
    }

    @Test("동일 경로 표기의 중복만 제거하고 전달받은 순서와 별도 설치는 유지한다")
    func deduplicatesStandardizedPathsWithoutReordering() {
        let app = SearchResult(url: URL(fileURLWithPath: "/Applications/Editor.app"), name: "Editor", kind: .application, bundleIdentifier: "test.editor")
        let duplicate = SearchResult(url: URL(fileURLWithPath: "/Applications/Unused/../Editor.app"), name: "중복", kind: .application)
        let secondInstallation = SearchResult(url: URL(fileURLWithPath: "/Users/test/Applications/Editor.app"), name: "Editor", kind: .application, bundleIdentifier: "test.editor")
        let file = searchResult("Editor.txt")
        var session = SearchSession()
        session.updateQuery("Editor")
        session.receive([file, app, duplicate, secondInstallation], for: "Editor")
        #expect(app.id == duplicate.id)
        #expect(session.results == [file, app, secondInstallation])
        #expect(session.selectedResult == file)
    }

    @Test("선택 이동은 양방향으로 순환하며 큰 입력에도 유효한 항목을 유지한다")
    func movementWrapsAndHandlesExtremeDistances() {
        let results = [searchResult("a"), searchResult("b"), searchResult("c")]
        var session = SearchSession()
        session.move(Int.min)
        #expect(session.selectedID == nil)
        session.updateQuery("item")
        session.receive(results, for: "item")
        session.move(-1)
        #expect(session.selectedResult == results[2])
        session.move(1)
        #expect(session.selectedResult == results[0])
        session.move(4)
        #expect(session.selectedResult == results[1])
        session.move(Int.min)
        #expect(session.selectedResult == results[2])
        session.move(Int.max)
        #expect(session.selectedResult == results[0])
        session.move(0)
        #expect(session.selectedResult == results[0])
    }

    @Test("빈 검색어와 공백 검색어는 결과를 받지 않으며 닫으면 완전히 초기화된다")
    func emptyQueryAndResetCannotRetainASelection() {
        let result = searchResult("result")
        var session = SearchSession()
        session.receive([result], for: "")
        #expect(session.results.isEmpty)
        session.updateQuery(" \n\t")
        session.receive([result], for: " \n\t")
        #expect(session.selectedResult == nil)
        session.updateQuery("result")
        session.receive([result], for: "result")
        session.updateQuery("")
        #expect(session.results.isEmpty)
        #expect(session.selectedID == nil)
        session.updateQuery("result")
        session.receive([result], for: "result")
        session.reset()
        #expect(session == SearchSession())
        session.receive([result], for: "result")
        #expect(session == SearchSession())
    }
}
