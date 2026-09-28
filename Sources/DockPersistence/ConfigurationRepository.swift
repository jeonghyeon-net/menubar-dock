import DockDomain
import Foundation

public struct ConfigurationLoadResult: Sendable {
    public let configuration: DockConfiguration
    public let warning: String?
    public let isReadOnly: Bool

    public init(configuration: DockConfiguration, warning: String? = nil, isReadOnly: Bool = false) {
        self.configuration = configuration
        self.warning = warning
        self.isReadOnly = isReadOnly
    }
}

public enum ConfigurationRepositoryError: Error, LocalizedError, Equatable, Sendable {
    case futureSchema(Int)
    case invalidSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .futureSchema(let version):
            "더 최신 버전에서 저장한 설정(형식 \(version))을 보호하기 위해 저장하지 않았습니다. 앱을 업데이트해 주세요."
        case .invalidSchema(let version):
            "지원하지 않는 설정 형식(\(version))입니다."
        }
    }
}

/// 파일 접근을 직렬화하며 저장 요청 도착 순서와 상태 revision을 구분한다.
public actor ConfigurationRepository {
    public let directory: URL
    private let fileManager = FileManager.default
    private var latestSavedRevision: UInt64?
    private var protectedSchemaVersion: Int?

    private var primaryURL: URL { directory.appendingPathComponent("preferences.json") }
    private var backupURL: URL { directory.appendingPathComponent("preferences.backup.json") }

    public init(directory: URL) { self.directory = directory }

    public func load() throws -> ConfigurationLoadResult {
        try ensureDirectory()
        if fileManager.fileExists(atPath: primaryURL.path) {
            // 읽기 권한·장치 오류는 손상으로 오인하여 원본을 옮기지 않는다.
            let data = try Data(contentsOf: primaryURL)
            do {
                return try loadResult(from: data)
            } catch is DecodingError {
                return try recoverFromCorruption(at: primaryURL)
            } catch ConfigurationRepositoryError.invalidSchema {
                return try recoverFromCorruption(at: primaryURL)
            }
        }
        if fileManager.fileExists(atPath: backupURL.path) {
            return try recoverBackup(warning: "설정 파일을 찾지 못해 마지막 정상 백업을 복구했습니다.")
        }
        return ConfigurationLoadResult(configuration: DockConfiguration())
    }

    public func save(_ configuration: DockConfiguration, revision: UInt64) throws {
        if let protectedSchemaVersion { throw ConfigurationRepositoryError.futureSchema(protectedSchemaVersion) }
        if let latestSavedRevision, revision <= latestSavedRevision { return }
        guard configuration.schemaVersion == DockConfiguration.currentSchemaVersion else {
            if configuration.schemaVersion > DockConfiguration.currentSchemaVersion {
                throw ConfigurationRepositoryError.futureSchema(configuration.schemaVersion)
            }
            throw ConfigurationRepositoryError.invalidSchema(configuration.schemaVersion)
        }
        try Task.checkCancellation()
        try ensureDirectory()
        let encoded = try Self.makeEncoder().encode(configuration.normalized())
        try protectFutureBackup()
        if fileManager.fileExists(atPath: primaryURL.path) {
            let previous = try Data(contentsOf: primaryURL)
            do {
                let result = try loadResult(from: previous)
                if result.isReadOnly {
                    throw ConfigurationRepositoryError.futureSchema(protectedSchemaVersion ?? configuration.schemaVersion)
                }
                // 새 설정 쓰기가 실패하더라도 기존 정상 설정과 백업을 모두 유지한다.
                try writeAtomically(previous, to: backupURL)
            } catch is DecodingError {
                try quarantine(primaryURL)
            } catch ConfigurationRepositoryError.invalidSchema {
                try quarantine(primaryURL)
            }
        }
        if !fileManager.fileExists(atPath: backupURL.path) {
            // 최초 저장 직후 파일이 손상되어도 복구할 수 있도록 첫 백업도 만든다.
            try writeAtomically(encoded, to: backupURL)
        }
        try writeAtomically(encoded, to: primaryURL)
        latestSavedRevision = revision
    }

    private func loadResult(from data: Data) throws -> ConfigurationLoadResult {
        let version = try Self.makeDecoder().decode(SchemaEnvelope.self, from: data).schemaVersion
        if version > DockConfiguration.currentSchemaVersion {
            protectedSchemaVersion = version
            return ConfigurationLoadResult(
                configuration: DockConfiguration(),
                warning: "더 최신 앱의 설정(형식 \(version))이 있어 읽기 전용으로 시작했습니다. 원본 파일은 보존됩니다.",
                isReadOnly: true
            )
        }
        var configuration: DockConfiguration
        switch version {
        case 1:
            // 이전 화면의 크기·간격 단위는 저장 경계에서만 현재 모델로 변환한다.
            configuration = try Self.makeDecoder().decode(LegacyConfigurationV1.self, from: data).migrated()
        case DockConfiguration.currentSchemaVersion:
            configuration = try Self.makeDecoder().decode(DockConfiguration.self, from: data)
            // 초기 v2의 40pt는 잘못 배포된 기본값이다. 형식은 그대로 두고 기본값만 보정하며,
            // 정상 사용자 파일의 손상으로 안내하지 않도록 정규화 비교 전에 적용한다.
            if configuration.preferences.iconSize == 40 {
                configuration.preferences.iconSize = 24
            }
        default:
            throw ConfigurationRepositoryError.invalidSchema(version)
        }
        // 이전 버전은 두 크기를 독립적으로 허용했다. 정상 범위의 조합은 손상 경고 없이
        // 현재 화면의 추가 간격 0...28pt에 맞추고, 실제 범위 오류는 아래 정규화에서 안내한다.
        if (16.0...32.0).contains(configuration.preferences.iconSize),
           (16.0...60.0).contains(configuration.preferences.slotWidth) {
            let iconSize = configuration.preferences.iconSize
            configuration.preferences.slotWidth = min(max(configuration.preferences.slotWidth, iconSize), iconSize + 28)
        }
        let normalized = configuration.normalized()
        return ConfigurationLoadResult(
            configuration: normalized,
            warning: normalized == configuration ? nil : "설정의 중복 항목이나 잘못된 값을 정리했습니다. 저장된 앱 순서는 유지했습니다."
        )
    }

    private func recoverFromCorruption(at url: URL) throws -> ConfigurationLoadResult {
        try quarantine(url)
        if fileManager.fileExists(atPath: backupURL.path) {
            return try recoverBackup(warning: "설정 파일이 손상되어 마지막 정상 백업을 복구했습니다. 손상된 원본은 별도 파일로 보존했습니다.")
        }
        return ConfigurationLoadResult(
            configuration: DockConfiguration(),
            warning: "설정 파일이 손상되어 기본 설정으로 시작했습니다. 손상된 원본은 별도 파일로 보존했습니다."
        )
    }

    private func recoverBackup(warning: String) throws -> ConfigurationLoadResult {
        let data = try Data(contentsOf: backupURL)
        do {
            let result = try loadResult(from: data)
            if result.isReadOnly { return result }
            try writeAtomically(Self.makeEncoder().encode(result.configuration), to: primaryURL)
            return ConfigurationLoadResult(configuration: result.configuration, warning: warning)
        } catch is DecodingError {
            try quarantine(backupURL)
        } catch ConfigurationRepositoryError.invalidSchema {
            try quarantine(backupURL)
        }
        return ConfigurationLoadResult(
            configuration: DockConfiguration(),
            warning: "설정과 백업을 읽을 수 없어 기본 설정으로 시작했습니다. 손상된 파일은 별도 보존했습니다."
        )
    }

    private func protectFutureBackup() throws {
        guard fileManager.fileExists(atPath: backupURL.path) else { return }
        let data = try Data(contentsOf: backupURL)
        // 백업만 손상된 경우에도 조용히 덮어쓰지 않고 진단용 원본을 보존한다.
        do {
            let result = try loadResult(from: data)
            if result.isReadOnly {
                throw ConfigurationRepositoryError.futureSchema(protectedSchemaVersion ?? DockConfiguration.currentSchemaVersion)
            }
        } catch is DecodingError {
            try quarantine(backupURL)
        } catch ConfigurationRepositoryError.invalidSchema {
            try quarantine(backupURL)
        }
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func quarantine(_ url: URL) throws {
        let stem = url.deletingPathExtension().lastPathComponent
        let preserved = directory.appendingPathComponent("\(stem).corrupt-\(UUID().uuidString).json")
        try fileManager.moveItem(at: url, to: preserved)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
        private enum CodingKeys: String, CodingKey { case schemaVersion }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            // 형식 번호가 없던 기존 파일도 v1 규칙으로 읽어 새 기본값을 적용한다.
            schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        }
    }

    private struct LegacyConfigurationV1: Decodable {
        let apps: [AppEntry]
        let order: [AppID]
        let preferences: LegacyPreferencesV1

        private enum CodingKeys: String, CodingKey { case apps, order, preferences }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            apps = try values.decodeIfPresent([AppEntry].self, forKey: .apps) ?? []
            order = try values.decodeIfPresent([AppID].self, forKey: .order) ?? []
            preferences = try values.decodeIfPresent(LegacyPreferencesV1.self, forKey: .preferences) ?? LegacyPreferencesV1()
        }

        func migrated() -> DockConfiguration {
            DockConfiguration(apps: apps, order: order, preferences: preferences.migrated())
        }
    }

    private struct LegacyPreferencesV1: Decodable {
        var iconSize: Double = 18
        var iconSpacing: Double = 4
        var maxVisibleApps: Int = 6
        var showsRunningApps: Bool = true
        var shortcutEnabled: Bool = true

        private enum CodingKeys: String, CodingKey {
            case iconSize, iconSpacing, maxVisibleApps, showsRunningApps, shortcutEnabled
        }

        init() {}

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            iconSize = try values.decodeIfPresent(Double.self, forKey: .iconSize) ?? 18
            iconSpacing = try values.decodeIfPresent(Double.self, forKey: .iconSpacing) ?? 4
            maxVisibleApps = try values.decodeIfPresent(Int.self, forKey: .maxVisibleApps) ?? 6
            showsRunningApps = try values.decodeIfPresent(Bool.self, forKey: .showsRunningApps) ?? true
            shortcutEnabled = try values.decodeIfPresent(Bool.self, forKey: .shortcutEnabled) ?? true
        }

        func migrated() -> DockPreferences {
            // v1 기본 아이콘 크기만 새 기본값으로 바꾸고 사용자의 개별 선택은 범위 안에서 보존한다.
            // 폐기한 isCompact 값은 읽지 않아 메뉴 막대의 독립 앱 아이콘 표시를 막지 않는다.
            DockPreferences(
                iconSize: iconSize == 18 ? 24 : iconSize,
                slotWidth: 30 + (iconSpacing - 4),
                maxVisibleApps: maxVisibleApps,
                showsRunningApps: showsRunningApps,
                shortcutEnabled: shortcutEnabled
            )
        }
    }
}
