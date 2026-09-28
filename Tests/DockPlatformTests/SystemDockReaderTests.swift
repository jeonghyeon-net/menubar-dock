import Foundation
import Testing
@testable import DockPlatform

@MainActor
@Suite("macOS Dock 고정 앱 읽기")
struct SystemDockReaderTests {
    private let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")

    @Test("Finder를 앞에 두고 Dock 순서를 유지하며 경로 표기 중복을 제거한다")
    func preservesDockOrderAndCanonicalIdentity() throws {
        let first = URL(fileURLWithPath: "/Applications/First App.app")
        let second = URL(fileURLWithPath: "/Applications/Second.app")
        let duplicate = URL(fileURLWithPath: "/Applications/Unused/../First App.app")
        let reader = makeReader(tiles: [tile(first), tile(second), tile(duplicate), tile(finder)], existing: [finder, first, second])
        #expect(try reader.applicationURLs() == [finder, first, second])
    }

    @Test("웹 링크·폴더·구분자·잘못된 항목은 앱으로 가져오지 않는다")
    func rejectsNonApplicationEntries() throws {
        let valid = URL(fileURLWithPath: "/Applications/Valid.app")
        let web = try #require(URL(string: "https://example.com/Fake.app"))
        let remote = try #require(URL(string: "file://remote-host/Applications/Remote.app"))
        let folder = URL(fileURLWithPath: "/Applications/Folder")
        let reader = makeReader(tiles: [
            tile(web), tile(remote), tile(folder),
            ["tile-type": "spacer-tile", "tile-data": ["file-data": ["_CFURLString": valid.absoluteString]]],
            ["tile-type": "file-tile", "tile-data": ["file-data": ["_CFURLString": 17]]],
            "bad tile", tile(valid),
        ], existing: [valid, web, remote, folder])
        #expect(try reader.applicationURLs() == [valid])
    }

    @Test("정상 빈 Dock 목록은 존재하는 Finder만 반환한다")
    func emptyDockIsAValidImport() throws {
        #expect(try makeReader(tiles: [], existing: [finder]).applicationURLs() == [finder])
        #expect(try makeReader(tiles: [], existing: []).applicationURLs().isEmpty)
    }

    @Test("설정 자체를 읽지 못한 경우 빈 목록으로 성공 처리하지 않는다")
    func unavailableOrMalformedPreferencesCanBeRetried() {
        let unavailable = SystemDockReader(
            readDomain: { nil }, finderURL: finder, applicationExists: { _ in true },
            resolveBookmark: { _ in nil }, resolveBundle: { _ in nil }
        )
        #expect(throws: SystemDockReaderError.unavailablePreferences) { try unavailable.applicationURLs() }
        let malformed = SystemDockReader(
            readDomain: { ["persistent-apps": "not a list"] }, finderURL: finder, applicationExists: { _ in true },
            resolveBookmark: { _ in nil }, resolveBundle: { _ in nil }
        )
        #expect(throws: SystemDockReaderError.invalidApplicationList) { try malformed.applicationURLs() }
    }

    @Test("기존 경로가 유효하면 bookmark와 bundle ID가 가리키는 다른 설치를 사용하지 않는다")
    func existingPathWinsOverFallbacks() throws {
        let direct = URL(fileURLWithPath: "/Applications/Direct.app")
        var bookmarkLookups = 0
        var bundleLookups = 0
        let reader = makeReader(
            tiles: [tile(direct, bookmark: Data([1]), identifier: "test.direct")], existing: [direct],
            bookmark: { _ in bookmarkLookups += 1; return direct },
            bundle: { _ in bundleLookups += 1; return direct }
        )
        #expect(try reader.applicationURLs() == [direct])
        #expect(bookmarkLookups == 0)
        #expect(bundleLookups == 0)
    }

    @Test("사라진 경로는 bookmark부터 복구하고 실패 시 bundle ID를 사용한다")
    func missingPathsUseValidatedFallbacksInOrder() throws {
        let missing = URL(fileURLWithPath: "/Applications/Before.app")
        let moved = URL(fileURLWithPath: "/Applications/After.app")
        let byBundle = URL(fileURLWithPath: "/Applications/Bundle.app")
        var bundleIdentifiers: [String] = []
        let reader = makeReader(
            tiles: [
                tile(missing, bookmark: Data([1]), identifier: "test.bookmark"),
                tile(missing, bookmark: Data([2]), identifier: "test.bundle"),
                tile(missing, identifier: "test.invalid"),
            ], existing: [moved, byBundle],
            bookmark: { $0 == Data([1]) ? moved : nil },
            bundle: { identifier in
                bundleIdentifiers.append(identifier)
                return identifier == "test.bundle" ? byBundle : URL(string: "https://example.com/Fake.app")
            }
        )
        #expect(try reader.applicationURLs() == [moved, byBundle])
        #expect(bundleIdentifiers == ["test.bundle", "test.invalid"])
    }

    private func makeReader(
        tiles: [Any], existing: [URL], bookmark: @escaping (Data) -> URL? = { _ in nil },
        bundle: @escaping (String) -> URL? = { _ in nil }
    ) -> SystemDockReader {
        let paths = Set(existing.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        return SystemDockReader(
            readDomain: { ["persistent-apps": tiles] }, finderURL: finder,
            applicationExists: { paths.contains($0.path) }, resolveBookmark: bookmark, resolveBundle: bundle
        )
    }

    private func tile(_ url: URL, bookmark: Data? = nil, identifier: String? = nil) -> [String: Any] {
        var data: [String: Any] = ["file-data": ["_CFURLString": url.absoluteString]]
        if let bookmark { data["book"] = bookmark }
        if let identifier { data["bundle-identifier"] = identifier }
        return ["tile-type": "file-tile", "tile-data": data]
    }
}
