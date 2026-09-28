import Foundation
import Testing
@testable import MenuBarDock

struct ReleaseCheckerTests {
    private func payload(version: String, url: String = "https://github.com/jeonghyeon-net/menubar-dock/releases/tag/v1.1.0", draft: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": version, "html_url": url, "draft": draft, "prerelease": false,
        ])
    }

    @Test func newerReleaseUsesNumericVersionComparison() throws {
        let result = try ReleaseChecker.interpret(payload(version: "v1.10.0"), currentVersion: "1.9.0")
        guard case .available(let version, _) = result else { Issue.record("새 버전을 찾아야 한다"); return }
        #expect(version == "v1.10.0")
    }

    @Test func sameOrOlderReleaseDoesNotRequestDowngrade() throws {
        #expect(try ReleaseChecker.interpret(payload(version: "v1.0.0"), currentVersion: "1.0.0") == .current)
        #expect(try ReleaseChecker.interpret(payload(version: "v0.9.0"), currentVersion: "1.0.0") == .current)
    }

    @Test(arguments: [
        "https://github.com.evil.example/jeonghyeon-net/menubar-dock/releases/tag/v1.1.0",
        "https://github.com/other/repository/releases/tag/v1.1.0",
        "http://github.com/jeonghyeon-net/menubar-dock/releases/tag/v1.1.0",
        "https://attacker@github.com/jeonghyeon-net/menubar-dock/releases/tag/v1.1.0",
    ])
    func rejectsUntrustedReleaseLinks(_ url: String) throws {
        let data = try payload(version: "v1.1.0", url: url)
        #expect(throws: (any Error).self) { try ReleaseChecker.interpret(data, currentVersion: "1.0.0") }
    }

    @Test func rejectsDraftAndMalformedVersion() throws {
        let draft = try payload(version: "v1.1.0", draft: true)
        #expect(throws: (any Error).self) { try ReleaseChecker.interpret(draft, currentVersion: "1.0.0") }
        let invalid = try payload(version: "v1.x.0")
        #expect(throws: (any Error).self) { try ReleaseChecker.interpret(invalid, currentVersion: "1.0.0") }
    }
}
