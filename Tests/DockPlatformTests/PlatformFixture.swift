import Foundation
import DockDomain
@testable import DockPlatform

/// 실제 실행 없이 bundle과 bookmark 검증에 쓰는 격리된 테스트 앱이다.
final class PlatformFixture {
    let directory: URL
    let applicationURL: URL

    init(name: String = "Fixture", identifier: String = "tests.menubardock.fixture", executable: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        applicationURL = directory.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: String] = [
            "CFBundleName": name,
            "CFBundleDisplayName": "테스트 앱",
            "CFBundleIdentifier": identifier,
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Fixture",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        if executable {
            let file = macOS.appendingPathComponent("Fixture")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func entry() throws -> AppEntry {
        try ApplicationResolver().resolve(url: applicationURL)
    }
}

func runningSnapshot(url: URL, pid: Int32 = 123, hidden: Bool = false, active: Bool = false) -> RunningAppSnapshot {
    RunningAppSnapshot(
        processIdentifier: pid,
        bundleURL: url,
        bundleIdentifier: "tests.menubardock.fixture",
        name: "테스트 앱",
        isRegular: true,
        isActive: active,
        isHidden: hidden,
        launchDate: Date(timeIntervalSince1970: 100)
    )
}
