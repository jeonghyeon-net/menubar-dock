import Foundation
import Testing
@testable import DockPlatform

@MainActor
struct ApplicationResolverTests {
    @Test("앱 이름과 실행 위치를 확인하고 복원 가능한 bookmark를 만든다")
    func resolvesApplication() throws {
        let fixture = try PlatformFixture()
        let entry = try fixture.entry()
        #expect(entry.name == "테스트 앱")
        #expect(entry.bundleIdentifier == "tests.menubardock.fixture")
        #expect(entry.bundlePath == canonicalApplicationURL(fixture.applicationURL).path)
        #expect(entry.bookmarkData?.isEmpty == false)
    }

    @Test("심볼릭 링크로 추가해도 실제 설치 경로를 사용한다")
    func resolvesSymbolicLink() throws {
        let fixture = try PlatformFixture()
        let alias = fixture.directory.appendingPathComponent("Linked.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.applicationURL)
        let entry = try ApplicationResolver().resolve(url: alias)
        #expect(entry.bundlePath == canonicalApplicationURL(fixture.applicationURL).path)
    }

    @Test("손상된 bookmark는 유효한 저장 경로로 복구하며 사용자 상태를 보존한다")
    func invalidBookmarkFallsBack() throws {
        let fixture = try PlatformFixture()
        var entry = try fixture.entry()
        entry.bookmarkData = Data([1, 2, 3])
        entry.isPinned = true
        entry.isExcluded = true
        entry.lastSeen = Date(timeIntervalSince1970: 321)
        let refreshed = try #require(ApplicationResolver().refresh(entry))
        #expect(refreshed.id == entry.id)
        #expect(refreshed.isPinned)
        #expect(refreshed.isExcluded)
        #expect(refreshed.lastSeen == entry.lastSeen)
        #expect(refreshed.bookmarkData != entry.bookmarkData)
    }

    @Test("이름이 바뀐 앱은 bookmark로 찾아 같은 앱 식별자를 유지한다")
    func movedApplicationUsesBookmark() throws {
        let fixture = try PlatformFixture()
        let entry = try fixture.entry()
        let movedURL = fixture.directory.appendingPathComponent("Moved.app")
        try FileManager.default.moveItem(at: fixture.applicationURL, to: movedURL)
        let refreshed = try #require(ApplicationResolver().refresh(entry))
        #expect(refreshed.id == entry.id)
        #expect(refreshed.bundlePath == canonicalApplicationURL(movedURL).path)
    }

    @Test("저장된 식별자와 다른 앱을 자동 대체하지 않는다")
    func rejectsReplacedApplication() throws {
        let fixture = try PlatformFixture()
        var entry = try fixture.entry()
        entry.bundleIdentifier = "another.application"
        #expect(ApplicationResolver().refresh(entry) == nil)
    }

    @Test("실행 파일이 없는 앱 번들은 실행 대상으로 받아들이지 않는다")
    func rejectsIncompleteBundle() throws {
        let fixture = try PlatformFixture(executable: false)
        #expect(throws: ApplicationResolutionError.missingExecutable) {
            try ApplicationResolver().resolve(url: fixture.applicationURL)
        }
    }

    @Test("원격 URL과 일반 디렉터리를 앱으로 받아들이지 않는다")
    func rejectsNonApplication() throws {
        let fixture = try PlatformFixture()
        let remote = try #require(URL(string: "https://example.com/app.app"))
        #expect(throws: ApplicationResolutionError.notFileURL) {
            try ApplicationResolver().resolve(url: remote)
        }
        #expect(throws: ApplicationResolutionError.invalidApplication) {
            try ApplicationResolver().resolve(url: fixture.directory)
        }
    }
}
