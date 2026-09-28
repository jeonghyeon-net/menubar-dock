import Foundation
import DockDomain

public struct SpotlightSearchUpdate: Sendable {
    public let results: [SearchResult]
    public let isComplete: Bool
    public let errorMessage: String?

    public init(results: [SearchResult], isComplete: Bool, errorMessage: String? = nil) {
        self.results = results
        self.isComplete = isComplete
        self.errorMessage = errorMessage
    }
}

@MainActor
public protocol SpotlightSearching: AnyObject {
    func search(_ text: String, receive: @escaping @MainActor (SpotlightSearchUpdate) -> Void)
    func cancel()
}

/// NSMetadataItem과 조회 객체는 OS 경계 안에 두고 URL·문자열만 외부로 전달한다.
struct SpotlightMetadataResult {
    let url: URL
    let name: String
}

@MainActor
protocol SpotlightQuerying: AnyObject {
    var resultCount: Int { get }
    func start(predicate: NSPredicate, receive: @escaping @MainActor (Bool) -> Void) -> Bool
    func result(at index: Int) -> SpotlightMetadataResult?
    func disableUpdates()
    func enableUpdates()
    func stop()
}

@MainActor
public final class SpotlightSearchService: SpotlightSearching {
    private static let resultPolicy = SpotlightResultPolicy()
    private let makeQuery: @MainActor () -> any SpotlightQuerying
    private let resolveResult: @MainActor (SpotlightMetadataResult) -> SearchResult?
    private let maximumResults: Int
    private var query: (any SpotlightQuerying)?
    private var requestID: UUID?
    private var rankingText = ""
    private var receive: (@MainActor (SpotlightSearchUpdate) -> Void)?
    private var snapshotTask: Task<Void, Never>?
    private var snapshotRequested = false
    private var completionRequested = false

    public convenience init() {
        self.init(makeQuery: { MetadataQueryBackend() }, resolveResult: Self.resolve, maximumResults: 50)
    }

    init(
        makeQuery: @escaping @MainActor () -> any SpotlightQuerying,
        resolveResult: @escaping @MainActor (SpotlightMetadataResult) -> SearchResult? = SpotlightSearchService.resolve,
        maximumResults: Int = 50
    ) {
        self.makeQuery = makeQuery
        self.resolveResult = resolveResult
        self.maximumResults = min(max(1, maximumResults), 50)
    }

    public func search(_ text: String, receive: @escaping @MainActor (SpotlightSearchUpdate) -> Void) {
        cancel()
        guard let predicate = Self.predicate(for: text) else {
            receive(SpotlightSearchUpdate(results: [], isComplete: true))
            return
        }
        let id = UUID()
        requestID = id
        rankingText = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.receive = receive
        receive(SpotlightSearchUpdate(results: [], isComplete: false))
        // 수신자가 초기 상태를 처리하며 닫거나 새 검색을 시작할 수도 있다.
        guard requestID == id else { return }
        let query = makeQuery()
        self.query = query
        let started = query.start(predicate: predicate) { [weak self] complete in
            self?.consume(requestID: id, isComplete: complete)
        }
        if !started, requestID == id {
            let callback = self.receive
            cancel()
            callback?(SpotlightSearchUpdate(
                results: [], isComplete: true, errorMessage: "Spotlight 검색을 시작하지 못했습니다. 다시 입력해 주세요."
            ))
        }
    }

    public func cancel() {
        requestID = nil
        rankingText = ""
        receive = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        snapshotRequested = false
        completionRequested = false
        let previous = query
        query = nil
        previous?.stop()
    }

    /// CONTAINS의 값 인수를 사용하므로 따옴표·별표·물음표가 검색 문법으로 해석되지 않는다.
    static func predicate(for text: String) -> NSPredicate? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        let predicates = words.map { word in
            NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, word),
                NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemDisplayNameKey, word),
            ])
        }
        // 이름이 같아도 SDK·문서·폴더는 조회 단계에서 제외한다. AND에는 항상 두 항 이상이 있다.
        let application = NSPredicate(format: "%K == %@", NSMetadataItemContentTypeKey, "com.apple.application-bundle")
        return NSCompoundPredicate(andPredicateWithSubpredicates: [application] + predicates)
    }

    private func consume(requestID id: UUID, isComplete: Bool) {
        guard requestID == id else { return }
        snapshotRequested = true
        completionRequested = completionRequested || isComplete
        beginSnapshot(requestID: id)
    }

    private func beginSnapshot(requestID id: UUID) {
        guard snapshotTask == nil, requestID == id, let query, let callback = receive else { return }
        snapshotRequested = false
        let complete = completionRequested
        completionRequested = false
        let resolve = resolveResult
        let limit = maximumResults
        let text = rankingText
        snapshotTask = Task { @MainActor [weak self] in
            let results = await Self.collect(query: query, resolve: resolve, limit: limit, text: text) { [weak self] partial in
                guard self?.requestID == id else { return }
                callback(SpotlightSearchUpdate(results: partial, isComplete: false))
            }
            guard let results, let self, self.requestID == id else { return }
            self.snapshotTask = nil
            if complete { self.cancel() }
            callback(SpotlightSearchUpdate(results: results, isComplete: complete))
            if self.requestID == id, self.snapshotRequested { self.beginSnapshot(requestID: id) }
        }
    }

    private static func collect(
        query: any SpotlightQuerying, resolve: (SpotlightMetadataResult) -> SearchResult?, limit: Int, text: String,
        publish: ([SearchResult]) -> Void
    ) async -> [SearchResult]? {
        query.disableUpdates()
        defer { query.enableUpdates() }
        var best: [SearchResult] = []
        var published: [SearchResult] = []
        // raw 결과를 잘라 버리면 숨김 파일 다음에 있는 정상 항목을 놓친다.
        // 스냅샷의 안정성은 유지하고 작은 배치마다 입력·취소에 실행 기회를 돌려준다.
        for offset in stride(from: 0, to: query.resultCount, by: 32) {
            guard !Task.isCancelled else { return nil }
            for index in offset..<min(offset + 32, query.resultCount) {
                guard let metadata = query.result(at: index), let result = resolve(metadata),
                      !best.contains(where: { $0.id == result.id }) else { continue }
                if best.count == limit, let last = best.last, !ranksBefore(result, last, text: text) { continue }
                best.append(result)
                best.sort { ranksBefore($0, $1, text: text) }
                if best.count > limit { best.removeLast() }
            }
            if best != published { publish(best); published = best }
            await Task.yield()
        }
        return Task.isCancelled ? nil : best
    }

    private static func ranksBefore(_ left: SearchResult, _ right: SearchResult, text: String) -> Bool {
        let leftRank = matchRank(left.name, text: text)
        let rightRank = matchRank(right.name, text: text)
        if leftRank != rightRank { return leftRank < rightRank }
        if (left.kind == .application) != (right.kind == .application) { return left.kind == .application }
        let comparison = left.name.localizedStandardCompare(right.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return left.id < right.id
    }

    private static func matchRank(_ name: String, text: String) -> Int {
        if name.compare(text, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { return 0 }
        if name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil { return 1 }
        return 2
    }

    static func resolve(_ metadata: SpotlightMetadataResult) -> SearchResult? {
        resolve(metadata, policy: resultPolicy)
    }

    static func resolve(_ metadata: SpotlightMetadataResult, policy: SpotlightResultPolicy) -> SearchResult? {
        guard metadata.url.isFileURL else { return nil }
        guard let paths = resolvedPaths(metadata.url), let url = paths.last,
            url.pathExtension.lowercased() == "app", paths.allSatisfy({ policy.allowsApplicationPath($0) }),
            FileManager.default.isReadableFile(atPath: url.path),
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey]),
            values.isDirectory == true, values.isHidden != true,
            let bundle = Bundle(url: url), let executable = bundle.executableURL,
            FileManager.default.isExecutableFile(atPath: executable.path)
        else { return nil }
        let packageType = bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String
        let isSystemFinder = packageType == "FNDR" && bundle.bundleIdentifier == "com.apple.finder"
            && url.path == "/System/Library/CoreServices/Finder.app"
        guard packageType == "APPL" || isSystemFinder else { return nil }
        let name = metadata.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return SearchResult(
            url: url, name: name.isEmpty ? url.lastPathComponent : name, kind: .application, bundleIdentifier: bundle.bundleIdentifier
        )
    }

    private static func resolvedPaths(_ original: URL) -> [URL]? {
        var paths: [URL] = []
        var current = original.standardizedFileURL
        var visited: Set<URL> = []
        // 별칭의 대상은 UI·볼륨 마운트 없이 확인하고 순환이나 과도한 연결은 거절한다.
        for _ in 0..<8 {
            guard current.isFileURL, visited.insert(current).inserted else { return nil }
            paths.append(current)
            current = canonicalApplicationURL(current)
            if paths.last != current { paths.append(current) }
            guard let values = try? current.resourceValues(forKeys: [.isAliasFileKey, .isHiddenKey]),
                  values.isHidden != true else { return nil }
            guard values.isAliasFile == true else { return paths }
            guard let target = try? URL(resolvingAliasFileAt: current, options: [.withoutUI, .withoutMounting]) else { return nil }
            current = target.standardizedFileURL
        }
        return nil
    }

    isolated deinit { snapshotTask?.cancel(); query?.stop() }
}

@MainActor
private final class MetadataQueryBackend: SpotlightQuerying {
    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private var receive: (@MainActor (Bool) -> Void)?

    var resultCount: Int { query.resultCount }

    func start(predicate: NSPredicate, receive: @escaping @MainActor (Bool) -> Void) -> Bool {
        self.receive = receive
        query.predicate = predicate
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemDisplayNameKey, ascending: true)]
        query.notificationBatchingInterval = 0.15
        query.operationQueue = .main
        for name in [Notification.Name.NSMetadataQueryGatheringProgress, .NSMetadataQueryDidUpdate, .NSMetadataQueryDidFinishGathering] {
            let complete = name == .NSMetadataQueryDidFinishGathering
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.receive?(complete) }
            })
        }
        return query.start()
    }

    func result(at index: Int) -> SpotlightMetadataResult? {
        guard let item = query.result(at: index) as? NSMetadataItem else { return nil }
        let url = (item.value(forAttribute: NSMetadataItemURLKey) as? URL)
            ?? (item.value(forAttribute: NSMetadataItemPathKey) as? String).map { URL(fileURLWithPath: $0) }
        guard let url else { return nil }
        let name = (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String)
            ?? (item.value(forAttribute: NSMetadataItemFSNameKey) as? String) ?? url.lastPathComponent
        return SpotlightMetadataResult(url: url, name: name)
    }

    func disableUpdates() { query.disableUpdates() }
    func enableUpdates() { query.enableUpdates() }

    func stop() {
        receive = nil
        query.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    isolated deinit { stop() }
}
