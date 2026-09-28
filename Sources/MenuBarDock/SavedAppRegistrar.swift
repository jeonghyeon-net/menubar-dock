import DockDomain
import Foundation

enum SavedAppRegistrationError: LocalizedError, Equatable {
    case alreadySaved(String)
    case missingReplacement
    case invalidIdentifier

    var errorDescription: String? {
        switch self {
        case .alreadySaved(let name): "\(name)은(는) 이미 항상 표시할 앱 목록에 있습니다. 기존 항목을 선택해 주세요."
        case .missingReplacement: "위치를 변경할 앱이 목록에서 제거되었습니다. 다시 추가해 주세요."
        case .invalidIdentifier: "앱 식별자를 확인할 수 없어 등록하지 못했습니다. 다시 선택해 주세요."
        }
    }
}

/// 명시적인 앱 추가와 위치 재지정을 저장 목록의 ID·순서 정책에 연결한다.
@MainActor
enum SavedAppRegistrar {
    @discardableResult
    static func register(_ app: AppEntry, replacing id: AppID? = nil, in catalog: inout DockCatalog) throws -> AppID {
        guard !app.id.rawValue.isEmpty else { throw SavedAppRegistrationError.invalidIdentifier }
        let path = canonicalPath(app.bundlePath)
        let matches = catalog.orderedApps.filter { canonicalPath($0.bundlePath) == path }
        var registered = catalog
        var incoming = app
        if let id {
            guard catalog.savedApps.contains(where: { $0.id == id }) else {
                throw SavedAppRegistrationError.missingReplacement
            }
            let savedIDs = Set(catalog.savedApps.map(\.id))
            if let duplicate = matches.first(where: { $0.id != id && savedIDs.contains($0.id) }) {
                throw SavedAppRegistrationError.alreadySaved(duplicate.name)
            }
            // 자동 감지된 임시 항목은 등록된 앱에 합치며 재감지 억제 기록을 만들지 않는다.
            for duplicate in matches where duplicate.id != id {
                registered.remove(duplicate.id, suppressRediscovery: false)
            }
            incoming.id = id
        } else if let existing = matches.first {
            incoming.id = existing.id
        }
        guard let registeredID = registered.upsertRestoring(incoming) else {
            throw SavedAppRegistrationError.invalidIdentifier
        }
        registered.save(registeredID)
        catalog = registered
        return registeredID
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
