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
    @Test("v2의 과대한 기본값만 조용히 보정하고 사용자 앱과 설정을 보존한다", arguments: [
        (40.0, 24.0, false),
        (28.0, 28.0, false),
        (56.0, 32.0, true),
    ])
    func correctsOversizedDefaultWithoutResettingUserConfiguration(_ values: (Double, Double, Bool)) async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanUp() }
        var original = configuration("고정 앱")
        let excluded = AppEntry(
            id: AppID(rawValue: "excluded-id"), name: "제외 앱", bundleIdentifier: "test.excluded",
            bundlePath: "/Applications/Excluded.app", isExcluded: true,
            lastSeen: Date(timeIntervalSince1970: 2_000)
        )
        original.apps.append(excluded)
        original.order.insert(excluded.id, at: 0)
        original.preferences = DockPreferences(iconSize: values.0, slotWidth: 46, maxVisibleApps: 9, showsRunningApps: false, shortcutEnabled: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let encoded = try encoder.encode(original)
        try encoded.write(to: fixture.primary)

        let result = try await fixture.repository.load()
        var expected = original
        expected.preferences.iconSize = values.1
        #expect(result.configuration == expected)
        #expect((result.warning != nil) == values.2)
        #expect(!result.isReadOnly)
        #expect(result.configuration.schemaVersion == 2)
        #expect(try Data(contentsOf: fixture.primary) == encoded)

        try await fixture.repository.save(result.configuration, revision: 1)
        #expect(try Data(contentsOf: fixture.backup) == encoded)
        let reopened = try await ConfigurationRepository(directory: fixture.directory).load()
        #expect(reopened.configuration == expected)
        #expect(reopened.warning == nil)
    }

    @Test("v2 크기 필드가 없으면 24pt 아이콘과 30pt 영역을 사용한다")
    func currentSchemaMissingDimensionsUseCorrectedDefaults() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanUp() }
        try Data(#"{"schemaVersion":2,"preferences":{}}"#.utf8).write(to: fixture.primary)
        let result = try await fixture.repository.load()
        #expect(result.configuration == DockConfiguration(preferences: DockPreferences(iconSize: 24, slotWidth: 30)))
        #expect(result.warning == nil)
    }

    @Test("v1 설정을 읽고 저장해도 앱·순서·고정·제외와 이전 정상 원본을 보존한다")
    func migratesLegacyConfigurationWithoutLosingUserPolicy() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanUp() }
        let legacy = Data(#"""
        {
          "schemaVersion": 1,
          "apps": [
            {"id":"pinned","name":"고정 앱","bundleIdentifier":"com.example.pinned","bundlePath":"/Applications/Pinned.app","bookmarkData":"AQID","isPinned":true,"isExcluded":false,"lastSeen":1000000},
            {"id":"excluded","name":"제외 앱","bundleIdentifier":"com.example.excluded","bundlePath":"/Applications/Excluded.app","isPinned":false,"isExcluded":true,"lastSeen":2000000}
          ],
          "order": ["excluded", "pinned"],
          "preferences": {"iconSize":18,"iconSpacing":4,"maxVisibleApps":9,"showsRunningApps":false,"isCompact":true,"shortcutEnabled":false}
        }
        """#.utf8)
        try legacy.write(to: fixture.primary)

        let result = try await fixture.repository.load()
        let migrated = result.configuration
        #expect(!result.isReadOnly)
        #expect(result.warning == nil)
        #expect(migrated.schemaVersion == 2)
        #expect(migrated.order == [AppID(rawValue: "excluded"), AppID(rawValue: "pinned")])
        #expect(migrated.apps == [
            AppEntry(id: AppID(rawValue: "pinned"), name: "고정 앱", bundleIdentifier: "com.example.pinned", bundlePath: "/Applications/Pinned.app", bookmarkData: Data([1, 2, 3]), isPinned: true, lastSeen: Date(timeIntervalSince1970: 1_000)),
            AppEntry(id: AppID(rawValue: "excluded"), name: "제외 앱", bundleIdentifier: "com.example.excluded", bundlePath: "/Applications/Excluded.app", isExcluded: true, lastSeen: Date(timeIntervalSince1970: 2_000)),
        ])
        #expect(migrated.preferences == DockPreferences(iconSize: 24, slotWidth: 30, maxVisibleApps: 9, showsRunningApps: false, shortcutEnabled: false))
        #expect(try Data(contentsOf: fixture.primary) == legacy)

        try await fixture.repository.save(migrated, revision: 1)
        #expect(try Data(contentsOf: fixture.backup) == legacy)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.primary)) as? [String: Any])
        let preferences = try #require(saved["preferences"] as? [String: Any])
        #expect(saved["schemaVersion"] as? Int == 2)
        #expect(preferences["slotWidth"] as? Double == 30)
        #expect(preferences["iconSpacing"] == nil)
        #expect(preferences["isCompact"] == nil)
        #expect(try await ConfigurationRepository(directory: fixture.directory).load().configuration == migrated)
    }

    @Test("v1 사용자 크기·간격은 새 범위 안에서 변환한다", arguments: [
        (24.0, 8.0, 24.0, 34.0),
        (16.0, -100.0, 16.0, 22.0),
        (100.0, 100.0, 32.0, 60.0),
    ])
    func legacyCustomDimensionsAreMappedAndBounded(_ values: (Double, Double, Double, Double)) async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanUp() }
        let legacy = Data("{\"schemaVersion\":1,\"preferences\":{\"iconSize\":\(values.0),\"iconSpacing\":\(values.1)}}".utf8)
        try legacy.write(to: fixture.primary)
        let result = try await fixture.repository.load()
        #expect(result.configuration.preferences.iconSize == values.2)
        #expect(result.configuration.preferences.slotWidth == values.3)
        #expect(!result.isReadOnly)
    }

    @Test("형식 번호나 선택 설정이 없던 v1 파일에도 새 기본값을 적용한다", arguments: [
        #"{"schemaVersion":1}"#,
        #"{"preferences":{"iconSize":18,"iconSpacing":4,"isCompact":true}}"#,
    ])
    func legacyMissingFieldsReceiveCurrentDefaults(_ json: String) async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanUp() }
        try Data(json.utf8).write(to: fixture.primary)
        #expect(try await fixture.repository.load().configuration == DockConfiguration())
    }

    @Test("손상된 설정은 v1 백업에서 복구하면서 현재 형식으로 저장한다")
    func legacyBackupRecoversIntoCurrentSchema() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanUp() }
        let legacy = Data(#"{"schemaVersion":1,"preferences":{"iconSize":18,"iconSpacing":7,"maxVisibleApps":3}}"#.utf8)
        let corrupt = Data("broken primary".utf8)
        try corrupt.write(to: fixture.primary)
        try legacy.write(to: fixture.backup)
        let result = try await fixture.repository.load()
        let expected = DockConfiguration(preferences: DockPreferences(iconSize: 24, slotWidth: 33, maxVisibleApps: 3))
        #expect(result.configuration == expected)
        #expect(result.warning != nil)
        #expect(try Data(contentsOf: fixture.backup) == legacy)
        #expect(try await ConfigurationRepository(directory: fixture.directory).load().configuration == expected)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.primary)) as? [String: Any])
        #expect(saved["schemaVersion"] as? Int == 2)
        let preserved = try #require(fixture.files().first { $0.lastPathComponent.contains(".corrupt-") })
        #expect(try Data(contentsOf: preserved) == corrupt)
    }

    @Test("v2 값은 v1 기본값 변환을 다시 적용하지 않는다")
    func currentSchemaDoesNotReapplyLegacyMigration() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanUp() }
        try Data(#"{"schemaVersion":2,"preferences":{"iconSize":18,"slotWidth":28,"iconSpacing":12,"isCompact":true}}"#.utf8).write(to: fixture.primary)
        let result = try await fixture.repository.load()
        #expect(result.configuration.preferences == DockPreferences(iconSize: 18, slotWidth: 28))
        try await fixture.repository.save(result.configuration, revision: 1)
        #expect(try await ConfigurationRepository(directory: fixture.directory).load().configuration == result.configuration)
    }

    @Test("잘못된 형식 저장은 revision을 소비하거나 정상 파일을 바꾸지 않는다")
    func failedSchemaSaveDoesNotConsumeRevision() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanUp() }
        let initial = configuration("이전 상태")
        try await fixture.repository.save(initial, revision: 5)
        let previous = try Data(contentsOf: fixture.primary)
        var invalid = configuration("지원하지 않는 상태")
        invalid.schemaVersion = 0
        await #expect(throws: ConfigurationRepositoryError.invalidSchema(0)) {
            try await fixture.repository.save(invalid, revision: 10)
        }
        #expect(try Data(contentsOf: fixture.primary) == previous)
        let expected = configuration("성공한 상태")
        try await fixture.repository.save(expected, revision: 10)
        try await fixture.repository.save(initial, revision: 9)
        #expect(try await fixture.repository.load().configuration == expected)
    }

    @Test("v1을 변환해도 미래 형식 백업이 있으면 양쪽 원본을 보호한다")
    func migrationDoesNotOverwriteFutureBackup() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanUp() }
        let legacy = Data(#"{"schemaVersion":1,"preferences":{"iconSize":18,"iconSpacing":4}}"#.utf8)
        let future = Data(#"{"schemaVersion":3,"preferences":"future"}"#.utf8)
        try legacy.write(to: fixture.primary)
        try future.write(to: fixture.backup)
        let result = try await fixture.repository.load()
        #expect(result.configuration == DockConfiguration())
        await #expect(throws: ConfigurationRepositoryError.futureSchema(3)) {
            try await fixture.repository.save(result.configuration, revision: 1)
        }
        #expect(try Data(contentsOf: fixture.primary) == legacy)
        #expect(try Data(contentsOf: fixture.backup) == future)
        #expect(try fixture.files().count == 2)
    }

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
        invalid.preferences.slotWidth = -1
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
