import Foundation
import Testing
import DockDomain
@testable import DockPlatform

@Suite(.serialized)
@MainActor
struct SpotlightSearchTests {
    @Test("빈 입력은 Spotlight 조회를 만들지 않는다")
    func emptyInputCompletesWithoutQuery() {
        var creations = 0
        let service = SpotlightSearchService(makeQuery: { creations += 1; return SearchQueryStub() })
        var updates: [SpotlightSearchUpdate] = []
        service.search(" \n\t ") { updates.append($0) }
        #expect(creations == 0)
        #expect(updates.count == 1)
        #expect(updates.last?.isComplete == true)
        #expect(updates.last?.results.isEmpty == true)
    }

    @Test("공백 단어는 AND이며 별표·물음표·따옴표를 문자 그대로 검색한다")
    func predicateUsesLiteralWordsAcrossBothNames() throws {
        let predicate = try #require(SpotlightSearchService.predicate(for: "  계획 *?'  "))
        let matching = [NSMetadataItemFSNameKey: "계획.app", NSMetadataItemDisplayNameKey: "메모 *?' 초안", NSMetadataItemContentTypeKey: "com.apple.application-bundle"]
        let wildcardOnly = [NSMetadataItemFSNameKey: "계획.app", NSMetadataItemDisplayNameKey: "메모 아무거나 초안", NSMetadataItemContentTypeKey: "com.apple.application-bundle"]
        let missingWord = [NSMetadataItemFSNameKey: "다른.app", NSMetadataItemDisplayNameKey: "메모 *?' 초안", NSMetadataItemContentTypeKey: "com.apple.application-bundle"]
        #expect(predicate.evaluate(with: matching))
        #expect(!predicate.evaluate(with: wildcardOnly))
        #expect(!predicate.evaluate(with: missingWord))
        for type in ["public.plain-text", "public.folder", "com.apple.framework"] {
            var document = matching
            document[NSMetadataItemContentTypeKey] = type
            #expect(!predicate.evaluate(with: document))
        }
    }

    @Test("실제 Spotlight query가 한 단어와 여러 단어 predicate를 수용한다")
    func nativeQueryAcceptsPredicateStructure() throws {
        for text in ["synthetic-\(UUID().uuidString)", "synthetic-\(UUID().uuidString) *?'"] {
            let query = NSMetadataQuery()
            let predicate = try #require(SpotlightSearchService.predicate(for: text))
            query.predicate = predicate
            // 인덱스나 개인 결과에 의존하지 않고 SDK의 predicate 변환을 실행한다.
            query.searchScopes = [FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)]
            query.operationQueue = .main
            #expect(query.start())
            query.stop()
        }
    }

    @Test("다음 검색을 시작하면 이전 알림이 늦게 도착해도 섞이지 않는다")
    func replacingSearchRejectsOldCallback() async {
        let first = SearchQueryStub(results: [metadata("first")])
        let second = SearchQueryStub(results: [metadata("second")])
        var queries = [first, second]
        let service = SpotlightSearchService(makeQuery: { queries.removeFirst() }, resolveResult: result)
        var oldUpdates: [SpotlightSearchUpdate] = []
        var newUpdates: [SpotlightSearchUpdate] = []
        service.search("first") { oldUpdates.append($0) }
        await withCheckedContinuation { continuation in
            service.search("second") { update in
                newUpdates.append(update)
                if update.isComplete { continuation.resume() }
            }
            first.deliver(complete: true)
            second.deliver(complete: true)
        }
        #expect(first.stops == 1)
        #expect(oldUpdates.count == 1)
        #expect(newUpdates.last?.results.map(\.name) == ["second"])
        #expect(newUpdates.last?.isComplete == true)
    }

    @Test("패널 닫기로 취소한 검색은 뒤늦은 결과를 전달하지 않는다")
    func cancellationRejectsLateResults() {
        let query = SearchQueryStub(results: [metadata("cancelled")])
        let service = SpotlightSearchService(makeQuery: { query }, resolveResult: result)
        var updates: [SpotlightSearchUpdate] = []
        service.search("cancelled") { updates.append($0) }
        service.cancel()
        query.deliver(complete: false)
        query.deliver(complete: true)
        #expect(query.stops == 1)
        #expect(updates.count == 1)
    }

    @Test("검색 시작 실패는 완료 오류로 알리고 조회를 정리한다")
    func startFailureIsVisibleAndCleanedUp() {
        let query = SearchQueryStub(startsSuccessfully: false)
        let service = SpotlightSearchService(makeQuery: { query })
        var updates: [SpotlightSearchUpdate] = []
        service.search("failure") { updates.append($0) }
        #expect(query.stops == 1)
        #expect(updates.last?.isComplete == true)
        #expect(updates.last?.errorMessage?.isEmpty == false)
    }

    @Test("배치 읽기의 갱신 잠금을 풀고 완료 때 관찰을 끝낸다")
    func resultSnapshotsBalanceLocksAndFinish() async {
        let query = SearchQueryStub(results: [metadata("one"), nil, metadata("one"), metadata("two")])
        let service = SpotlightSearchService(makeQuery: { query }, resolveResult: result)
        let update = await finalUpdate(service: service, query: query, text: "items")
        // 완료 후 늦게 도착한 갱신은 새 배치나 잠금을 만들지 않는다.
        query.deliver(complete: false)
        #expect(query.disables == 1)
        #expect(query.enables == 1)
        #expect(query.readOutsideLock == false)
        #expect(query.stops == 1)
        #expect(update.results.map(\.name) == ["one", "two"])
    }

    @Test("최종 결과는 50개로 제한하되 앞의 무효 후보가 뒤의 정상 결과를 가리지 않는다")
    func boundsResultsWithoutDroppingLateValidCandidates() async {
        let many = SearchQueryStub(results: (0..<100).map { metadata("item-\($0)") })
        let service = SpotlightSearchService(makeQuery: { many }, resolveResult: result)
        let update = await finalUpdate(service: service, query: many, text: "items")
        #expect(update.results.count == 50)
        #expect(many.reads == 100)
        let invalid = SearchQueryStub(results: Array(repeating: nil, count: 300) + [metadata("valid")])
        let rejectedService = SpotlightSearchService(makeQuery: { invalid }, resolveResult: result)
        let late = await finalUpdate(service: rejectedService, query: invalid, text: "valid")
        #expect(late.results.map(\.name) == ["valid"])
        #expect(invalid.reads == 301)
        #expect(invalid.disables == invalid.enables)
    }

    @Test("정확·접두 일치와 앱 우선순위를 적용한 뒤 결과 개수를 제한한다")
    func rankingKeepsStrongAppMatchesAboveManyFiles() async {
        let names = (0..<400).map { metadata("a code file \($0)") }
            + [metadata("Code Editor"), metadata("CÓDE"), metadata("code"), metadata("code notes")]
        let query = SearchQueryStub(results: names)
        let service = SpotlightSearchService(makeQuery: { query }, resolveResult: { metadata in
            SearchResult(url: metadata.url, name: metadata.name,
                         kind: ["Code Editor", "CÓDE"].contains(metadata.name) ? .application : .file)
        })
        let results = await finalUpdate(service: service, query: query, text: "cODe").results
        #expect(results.count == 50)
        #expect(Array(results.prefix(4).map(\.name)) == ["CÓDE", "code", "Code Editor", "code notes"])
    }

    @Test("대량 결과를 읽는 배치 사이에 다른 MainActor 작업이 취소할 수 있다")
    func cancellationRunsBetweenSmallBatches() async {
        let query = SearchQueryStub(results: (0..<1_000).map { metadata("item-\($0)") })
        let service = SpotlightSearchService(makeQuery: { query }, resolveResult: result)
        await withCheckedContinuation { continuation in
            query.onEnable = { continuation.resume() }
            service.search("item") { update in
                if !update.results.isEmpty { Task { @MainActor in service.cancel() } }
            }
            query.deliver(complete: true)
        }
        #expect(query.reads <= 64)
        #expect(query.stops == 1)
        #expect(query.disables == query.enables)
    }

    @Test("서비스 해제도 실행 중 조회를 정리한다")
    func deinitializationStopsQuery() {
        let query = SearchQueryStub()
        var service: SpotlightSearchService? = SpotlightSearchService(makeQuery: { query })
        service?.search("query") { _ in }
        service = nil
        #expect(query.stops == 1)
    }

    @Test("실행 가능한 앱만 반환하고 문서·폴더·숨김·앱 내부·없는 경로는 제외한다")
    func resolvesAccessibleSyntheticItems() throws {
        let fixture = try PlatformFixture()
        let document = fixture.directory.appendingPathComponent("document.txt")
        try Data("synthetic fixture".utf8).write(to: document)
        let hidden = fixture.directory.appendingPathComponent(".hidden.txt")
        try Data().write(to: hidden)
        let inside = fixture.applicationURL.appendingPathComponent("Contents/Info.plist")
        #expect(SpotlightSearchService.resolve(SpotlightMetadataResult(url: fixture.applicationURL, name: "앱"))?.kind == .application)
        for url in [fixture.directory, document, hidden, inside, fixture.directory.appendingPathComponent("missing")] {
            #expect(SpotlightSearchService.resolve(SpotlightMetadataResult(url: url, name: "거절")) == nil)
        }
        let remote = try #require(URL(string: "https://example.invalid/file.txt"))
        #expect(SpotlightSearchService.resolve(SpotlightMetadataResult(url: remote, name: "원격")) == nil)
    }

    @Test("별칭 앱은 중복 제거하되 같은 번들 ID의 다른 설치는 남긴다")
    func canonicalPathsDeduplicateOnlyTheSameInstallation() async throws {
        let first = try PlatformFixture(name: "First")
        let second = try PlatformFixture(name: "Second")
        let alias = first.directory.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first.applicationURL)
        let query = SearchQueryStub(results: [first.applicationURL, alias, second.applicationURL].map {
            SpotlightMetadataResult(url: $0, name: "앱")
        })
        let service = SpotlightSearchService(makeQuery: { query })
        let results = await finalUpdate(service: service, query: query, text: "앱").results
        #expect(results.count == 2)
        #expect(Set(results.map(\.bundleIdentifier)).count == 1)
        #expect(Set(results.map(\.id)).count == 2)
    }

    @Test("Safari 검색에서 SDK 프레임워크와 링크 스텁을 결과로 반환하지 않는다")
    func rejectsSDKFrameworkAndLinkStubAtResolutionBoundary() throws {
        let fixture = try PlatformFixture()
        let sdk = fixture.directory.appendingPathComponent("Library/Developer/CommandLineTools/SDKs/MacOSX.sdk")
        let framework = sdk.appendingPathComponent("System/Library/Frameworks/Safari.framework")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        let stub = framework.appendingPathComponent("Safari.tbd")
        try Data().write(to: stub)
        #expect(SpotlightSearchService.resolve(SpotlightMetadataResult(url: framework, name: "Safari.framework")) == nil)
        #expect(SpotlightSearchService.resolve(SpotlightMetadataResult(url: stub, name: "Safari.tbd")) == nil)
    }

    @Test("검색 실행은 검증한 앱만 OS 경계로 전달한다")
    func openerRoutesWithoutLaunchingRealApplications() async throws {
        let fixture = try PlatformFixture()
        let file = fixture.directory.appendingPathComponent("document.txt")
        try Data().write(to: file)
        var applications: [AppEntry] = []
        let opener = SearchResultOpener(openApplication: { applications.append($0) })
        try await opener.open(SearchResult(url: fixture.applicationURL, name: "앱", kind: .application))
        for item in [SearchResult(url: file, name: "문서", kind: .file), SearchResult(url: fixture.directory, name: "폴더", kind: .folder)] {
            await #expect(throws: SearchResultOpenError.notApplication) { try await opener.open(item) }
        }
        #expect(applications.map(\.bundlePath) == [canonicalApplicationURL(fixture.applicationURL).path])
        #expect(applications.first?.bookmarkData != nil)
    }

    @Test("사라진 경로와 비파일 URL은 OS 열기 전에 거절한다")
    func openerRejectsUnavailableTargets() async throws {
        let fixture = try PlatformFixture()
        var calls = 0
        let opener = SearchResultOpener(openApplication: { _ in calls += 1 })
        let remote = try #require(URL(string: "https://example.invalid/file"))
        await #expect(throws: SearchResultOpenError.notFileURL) {
            try await opener.open(SearchResult(url: remote, name: "원격", kind: .file))
        }
        await #expect(throws: SearchResultOpenError.unavailable) {
            try await opener.open(SearchResult(url: fixture.directory.appendingPathComponent("missing.app"), name: "없음", kind: .application))
        }
        #expect(calls == 0)
    }

    @Test("선택 이후 앱 ID나 항목 종류가 바뀌면 다른 대상으로 실행하지 않는다")
    func openerRejectsReplacedResults() async throws {
        let fixture = try PlatformFixture()
        var calls = 0
        let opener = SearchResultOpener(openApplication: { _ in calls += 1 })
        await #expect(throws: SearchResultOpenError.unavailable) {
            try await opener.open(SearchResult(url: fixture.applicationURL, name: "앱", kind: .application, bundleIdentifier: "different.app"))
        }
        await #expect(throws: SearchResultOpenError.notApplication) {
            try await opener.open(SearchResult(url: fixture.applicationURL, name: "문서", kind: .file))
        }
        let invalid = try PlatformFixture(executable: false)
        await #expect(throws: SearchResultOpenError.unavailable) {
            try await opener.open(SearchResult(url: invalid.applicationURL, name: "실행 파일 없음", kind: .application))
        }
        #expect(calls == 0)
    }

    @Test("앱 실행 실패는 파일 경로를 노출하지 않는 오류로 변환한다")
    func applicationFailureUsesLocalizedError() async throws {
        let fixture = try PlatformFixture()
        let opener = SearchResultOpener(openApplication: { _ in throw CocoaError(.fileReadNoPermission) })
        await #expect(throws: SearchResultOpenError.cannotOpen) {
            try await opener.open(SearchResult(url: fixture.applicationURL, name: "앱", kind: .application))
        }
    }
}

@MainActor
private final class SearchQueryStub: SpotlightQuerying {
    let results: [SpotlightMetadataResult?]
    let startsSuccessfully: Bool
    var callback: (@MainActor (Bool) -> Void)?
    var stops = 0
    var disables = 0
    var enables = 0
    var reads = 0
    var readOutsideLock = false
    var onEnable: (@MainActor () -> Void)?
    var resultCount: Int { results.count }

    init(results: [SpotlightMetadataResult?] = [], startsSuccessfully: Bool = true) {
        self.results = results
        self.startsSuccessfully = startsSuccessfully
    }

    func start(predicate: NSPredicate, receive: @escaping @MainActor (Bool) -> Void) -> Bool {
        callback = receive
        return startsSuccessfully
    }

    func result(at index: Int) -> SpotlightMetadataResult? {
        reads += 1
        if disables == enables { readOutsideLock = true }
        return results[index]
    }

    func disableUpdates() { disables += 1 }
    func enableUpdates() { enables += 1; onEnable?() }
    func stop() { stops += 1 }
    func deliver(complete: Bool) { callback?(complete) }
}

private func metadata(_ name: String) -> SpotlightMetadataResult {
    SpotlightMetadataResult(url: URL(fileURLWithPath: "/synthetic-search/\(name)"), name: name)
}

@MainActor
private func result(_ metadata: SpotlightMetadataResult) -> SearchResult? {
    SearchResult(url: metadata.url, name: metadata.name, kind: .file)
}

@MainActor
private func finalUpdate(service: SpotlightSearchService, query: SearchQueryStub, text: String) async -> SpotlightSearchUpdate {
    await withCheckedContinuation { continuation in
        service.search(text) { update in
            if update.isComplete { continuation.resume(returning: update) }
        }
        query.deliver(complete: true)
    }
}
