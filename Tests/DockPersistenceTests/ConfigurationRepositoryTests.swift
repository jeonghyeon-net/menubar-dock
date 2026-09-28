import DockDomain
import DockPersistence
import Foundation
import Testing

private struct RepositoryFixture {
    let directory: URL
    let repository: ConfigurationRepository

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MenuBarDockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        repository = ConfigurationRepository(directory: directory)
    }

    var primary: URL { directory.appendingPathComponent("preferences.json") }
    var backup: URL { directory.appendingPathComponent("preferences.backup.json") }
    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    func files() throws -> [URL] { try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
}

private func configuration(_ name: String) -> DockConfiguration {
    let app = AppEntry(
        id: AppID(rawValue: "stable-id"), name: name, bundleIdentifier: "com.example.app",
        bundlePath: "/Applications/Test.app", bookmarkData: Data([1, 2, 3]), isPinned: true,
        lastSeen: Date(timeIntervalSince1970: 1_000)
    )
    return DockConfiguration(apps: [app], order: [app.id])
}

@Suite("설정 저장과 복구")
struct ConfigurationRepositoryTests {
    @Test("첫 실행과 다른 저장소 인스턴스의 재실행 사이에 설정을 보존한다")
    func persistsAcrossInstances() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanUp() }
        let initial = try await fixture.repository.load()
        #expect(initial.configuration == DockConfiguration())
        #expect(initial.warning == nil)
        #expect(!initial.isReadOnly)
        let expected = configuration("앱 이름")
        try await fixture.repository.save(expected, revision: 0)
        let reopened = try await ConfigurationRepository(directory: fixture.directory).load()
        #expect(reopened.configuration == expected)
        #expect(reopened.warning == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.backup.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.primary.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test("늦게 도착한 저장과 같은 revision의 중복 저장은 최신 값을 덮지 않는다")
    func rejectsStaleRevisions() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanUp() }
        let newest = configuration("최신")
        try await fixture.repository.save(newest, revision: 10)
        try await fixture.repository.save(configuration("과거"), revision: 1)
        try await fixture.repository.save(configuration("중복"), revision: 10)
        #expect(try await fixture.repository.load().configuration == newest)
    }

    @Test("동시에 도착한 저장 요청은 가장 큰 revision의 상태로 수렴한다")
    func concurrentSavesKeepNewestRevision() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanUp() }
        let repository = fixture.repository
        try await withThrowingTaskGroup(of: Void.self) { group in
            for revision in 1...40 {
                group.addTask {
                    try await repository.save(configuration("revision-\(revision)"), revision: UInt64(revision))
                }
            }
            try await group.waitForAll()
        }
        #expect(try await repository.load().configuration == configuration("revision-40"))
    }

    @Test("손상된 설정은 직전 정상 백업으로 복구하고 손상 원본은 남긴다")
    func corruptPrimaryRecoversPreviousGoodBackup() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanUp() }
        let previous = configuration("이전 정상 설정")
        try await fixture.repository.save(previous, revision: 1)
        try await fixture.repository.save(configuration("다음 설정"), revision: 2)
        let corrupted = Data("{broken".utf8)
        try corrupted.write(to: fixture.primary)
        let result = try await ConfigurationRepository(directory: fixture.directory).load()
        #expect(result.configuration == previous)
        #expect(result.warning != nil)
        #expect(!result.isReadOnly)
        let preserved = try #require(fixture.files().first { $0.lastPathComponent.contains(".corrupt-") })
        #expect(try Data(contentsOf: preserved) == corrupted)
        #expect(try await ConfigurationRepository(directory: fixture.directory).load().configuration == previous)
    }

    @Test("최초 저장 직후 설정이 손상되어도 첫 백업으로 복구한다")
    func firstSaveHasRecoverableBackup() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanUp() }
        let expected = configuration("첫 설정")
        try await fixture.repository.save(expected, revision: 1)
        try Data([0, 1, 2]).write(to: fixture.primary)
        #expect(try await ConfigurationRepository(directory: fixture.directory).load().configuration == expected)
    }

    @Test("설정과 백업이 모두 손상되면 두 원본을 보존하고 기본값으로 시작한다")
    func bothCorruptFilesArePreserved() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanUp() }
        try Data("bad primary".utf8).write(to: fixture.primary)
        try Data("bad backup".utf8).write(to: fixture.backup)
        let result = try await fixture.repository.load()
        #expect(result.configuration == DockConfiguration())
        #expect(result.warning != nil)
        #expect(try fixture.files().filter { $0.lastPathComponent.contains(".corrupt-") }.count == 2)
        try await fixture.repository.save(configuration("복구 후 저장"), revision: 1)
        #expect(try await fixture.repository.load().configuration == configuration("복구 후 저장"))
    }

    @Test("미래 형식은 본문을 해석하거나 덮어쓰지 않는다")
    func futureSchemaRemainsUntouched() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanUp() }
        let future = Data(#"{"schemaVersion":99,"apps":"알 수 없는 미래 표현"}"#.utf8)
        try future.write(to: fixture.primary)
        let result = try await fixture.repository.load()
        #expect(result.isReadOnly)
        #expect(result.warning != nil)
        await #expect(throws: ConfigurationRepositoryError.futureSchema(99)) {
            try await fixture.repository.save(configuration("덮어쓰기"), revision: 1)
        }
        #expect(try Data(contentsOf: fixture.primary) == future)
        #expect(try fixture.files().count == 1)
    }

    @Test("load를 생략하거나 실행 중 미래 설정이 생겨도 원본을 보호한다")
    func saveAlsoChecksExternalFutureSchema() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanUp() }
        let future = Data(#"{"schemaVersion":7}"#.utf8)
        try future.write(to: fixture.primary)
        await #expect(throws: ConfigurationRepositoryError.futureSchema(7)) {
            try await fixture.repository.save(configuration("새 설정"), revision: 1)
        }
        #expect(try Data(contentsOf: fixture.primary) == future)
    }

    @Test("미래 형식의 백업도 복구나 저장 중 삭제하지 않는다")
    func futureBackupRemainsUntouched() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanUp() }
        let future = Data(#"{"schemaVersion":8}"#.utf8)
        try future.write(to: fixture.backup)
        let result = try await fixture.repository.load()
        #expect(result.isReadOnly)
        await #expect(throws: ConfigurationRepositoryError.futureSchema(8)) {
            try await fixture.repository.save(configuration("새 설정"), revision: 1)
        }
        #expect(try Data(contentsOf: fixture.backup) == future)
        #expect(!FileManager.default.fileExists(atPath: fixture.primary.path))
    }

    @Test("정상 백업만 남아 있으면 기본값을 만들기 전에 복구한다")
    func missingPrimaryRecoversBackup() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanUp() }
        let expected = configuration("저장한 앱")
        try await fixture.repository.save(expected, revision: 1)
        try FileManager.default.removeItem(at: fixture.primary)
        let result = try await ConfigurationRepository(directory: fixture.directory).load()
        #expect(result.configuration == expected)
        #expect(result.warning != nil)
    }

    @Test("설정 디렉터리를 쓸 수 없는 실패는 호출자에게 전달한다")
    func filesystemFailureIsNotSilenced() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanUp() }
        let file = fixture.directory.appendingPathComponent("file-instead-of-directory")
        let original = Data("keep me".utf8)
        try original.write(to: file)
        let repository = ConfigurationRepository(directory: file)
        await #expect(throws: (any Error).self) {
            try await repository.save(configuration("저장 실패"), revision: 1)
        }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test("정규화 후 저장한 순서는 재실행해도 변하지 않는다")
    func normalizedConfigurationSurvivesRoundTrip() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanUp() }
        var invalid = configuration("앱")
        invalid.order = [AppID(rawValue: "missing"), invalid.apps[0].id, invalid.apps[0].id]
        invalid.preferences.iconSpacing = -1
        try await fixture.repository.save(invalid, revision: 1)
        #expect(try await fixture.repository.load().configuration == invalid.normalized())
    }

    @Test("읽기 전 손상된 파일을 저장으로 교체해도 원본과 첫 백업을 남긴다")
    func savingOverCorruptFilePreservesRecoveryPath() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanUp() }
        let corrupt = Data("incomplete file".utf8)
        try corrupt.write(to: fixture.primary)
        let expected = configuration("복구한 설정")
        try await fixture.repository.save(expected, revision: 1)
        #expect(FileManager.default.fileExists(atPath: fixture.backup.path))
        let preserved = try #require(fixture.files().first { $0.lastPathComponent.contains(".corrupt-") })
        #expect(try Data(contentsOf: preserved) == corrupt)
        try corrupt.write(to: fixture.primary)
        #expect(try await ConfigurationRepository(directory: fixture.directory).load().configuration == expected)
    }
}
