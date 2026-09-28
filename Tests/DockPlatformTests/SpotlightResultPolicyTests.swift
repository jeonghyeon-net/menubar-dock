import Foundation
import Testing
import DockDomain
@testable import DockPlatform

@Suite(.serialized)
@MainActor
struct SpotlightResultPolicyTests {
    @Test("SDK·프레임워크·플러그인·앱 내부의 실행 가능한 중첩 앱도 제외한다")
    func rejectsImplementationAppsBeforeSystemAppExceptions() throws {
        let fixture = try PlatformFixture()
        let policy = SpotlightResultPolicy(homeDirectory: fixture.directory.appendingPathComponent("Users/Test"), systemRoot: fixture.directory)
        let paths = [
            "Library/Developer/SDKs/MacOSX.sdk/Applications/Safari.app",
            "Library/Caches/Cached.app",
            "Library/Logs/Helper.app", "Library/Preferences/Helper.app",
            "Users/Test/Library/Developer/Xcode/DerivedData/Build.app",
            "Users/Test/Library/Caches/Helper.app", "Users/Test/Library/Containers/Helper.app",
            "SDK.framework/Versions/A/Helper.app", "Tools.plugin/Contents/Helper.app",
            "Tools.bundle/Contents/Helper.app", "Worker.xpc/Contents/Helper.app",
            "Parent.app/Contents/Helper.app", "System/Library/PrivateFrameworks/Helper.app",
            "System/Library/CoreServices/Agent.app", "usr/bin/Agent.app", "usr/sbin/Agent.app",
            "usr/lib/Agent.app", "usr/libexec/Agent.app"
        ]
        for path in paths {
            let app = try copyApplication(fixture, to: path)
            #expect(SpotlightSearchService.resolve(.init(url: app, name: "앱"), policy: policy) == nil)
        }
    }

    @Test("Application Support와 usr/local의 독립 앱·설치 링크는 유지하고 중첩 보조 앱은 제외한다")
    func preservesApplicationSupportAndUnixLocalInstallations() throws {
        let fixture = try PlatformFixture()
        let policy = SpotlightResultPolicy(homeDirectory: fixture.directory.appendingPathComponent("Users/Test"), systemRoot: fixture.directory)
        let paths = [
            "Library/Application Support/Standalone.app",
            "Users/Test/Library/Application Support/JetBrains/Toolbox/apps/IDE.app",
            "usr/local/Cellar/emacs/30.1/Emacs.app"
        ]
        for (index, path) in paths.enumerated() {
            let app = try copyApplication(fixture, to: path)
            #expect(SpotlightSearchService.resolve(.init(url: app, name: "독립 앱"), policy: policy)?.kind == .application)
            let link = fixture.directory.appendingPathComponent("Applications/Installed-\(index).app")
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
            #expect(SpotlightSearchService.resolve(.init(url: link, name: "설치 링크"), policy: policy)?.url == canonicalApplicationURL(app))
            let helper = try copyApplication(fixture, to: path + "/Contents/Helper.app")
            #expect(SpotlightSearchService.resolve(.init(url: helper, name: "중첩 보조 앱"), policy: policy) == nil)
        }
    }

    @Test("독립 설치 앱과 시스템 앱은 유지하고 일반 폴더 이름은 과잉 차단하지 않는다")
    func preservesStandaloneAndSystemApplicationLocations() throws {
        let fixture = try PlatformFixture()
        let policy = SpotlightResultPolicy(homeDirectory: fixture.directory.appendingPathComponent("Users/Test"), systemRoot: fixture.directory)
        let paths = [
            "Applications/Safari.app", "Users/Test/Applications/Editor.app",
            "System/Applications/Notes.app", "System/Cryptexes/App/System/Applications/Safari.app",
            "System/Library/CoreServices/Finder.app", "System/Library/CoreServices/Applications/Archive Utility.app",
            "opt/homebrew/Caskroom/editor/1.0/Editor.app", "Volumes/External/Applications/Editor.app",
            "Users/Test/Documents/Library/Caches/Editor.app", "Users/Test/Library/Caches Archive/Editor.app",
            "SDK.framework-notes/Editor.app"
        ]
        for path in paths {
            let app = try copyApplication(fixture, to: path)
            #expect(SpotlightSearchService.resolve(.init(url: app, name: "앱"), policy: policy)?.kind == .application)
        }
    }

    @Test("심볼릭 링크와 Finder 별칭의 원본·대상 경로를 모두 검사한다")
    func checksBothLocationsForSymlinksAndAliases() throws {
        let fixture = try PlatformFixture()
        let policy = SpotlightResultPolicy(homeDirectory: fixture.directory.appendingPathComponent("Users/Test"), systemRoot: fixture.directory)
        let valid = try copyApplication(fixture, to: "opt/homebrew/Caskroom/editor/1.0/Editor.app")
        let cached = try copyApplication(fixture, to: "Library/Caches/Helper.app")
        let cases = [
            ("Applications/Editor.app", valid, true),
            ("Applications/Helper.app", cached, false),
            ("Library/Caches/External.app", valid, false)
        ]
        for (path, target, expected) in cases {
            let link = fixture.directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let resolved = SpotlightSearchService.resolve(.init(url: link, name: "링크"), policy: policy)
            #expect((resolved != nil) == expected)
            if expected { #expect(resolved?.url == canonicalApplicationURL(valid)) }
            let alias = link.appendingPathExtension("alias")
            let bookmark = try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
            try URL.writeBookmarkData(bookmark, to: alias)
            let aliasResult = SpotlightSearchService.resolve(.init(url: alias, name: "별칭"), policy: policy)
            #expect((aliasResult != nil) == expected)
            if expected { #expect(aliasResult?.url == canonicalApplicationURL(valid)) }
        }
    }

    @Test("실제 Finder와 Safari 설치 앱을 실행하지 않고 해석한다")
    func resolvesInstalledFinderAndSafari() throws {
        for path in ["/System/Library/CoreServices/Finder.app", "/Applications/Safari.app"] {
            let result = try #require(SpotlightSearchService.resolve(.init(url: URL(fileURLWithPath: path), name: "시스템 앱")))
            #expect(result.kind == .application)
            #expect(result.url.pathExtension == "app")
        }
    }
}

private func copyApplication(_ fixture: PlatformFixture, to path: String) throws -> URL {
    let target = fixture.directory.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixture.applicationURL, to: target)
    return target
}
