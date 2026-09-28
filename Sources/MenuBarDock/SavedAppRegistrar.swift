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
    static func register(
        _ app: AppEntry, replacing id: AppID? = nil, in catalog: inout DockCatalog,
        refresh: (AppEntry) -> AppEntry? = { $0 }
    ) throws -> AppID {
        guard !app.id.rawValue.isEmpty else { throw SavedAppRegistrationError.invalidIdentifier }
        var registered = catalog
        // 명시적 등록이 workspace 관찰보다 먼저 올 수 있으므로 현재 bookmark 위치를 먼저 확인한다.
        // 갱신도 복사본에만 적용하여 이후 충돌 오류가 나면 기존 설정을 그대로 보존한다.
        refreshLocations(in: &registered, refresh: refresh)
        let path = canonicalPath(app.bundlePath)
        let matches = registered.orderedApps.filter {
            canonicalPath($0.bundlePath) == path && compatibleIdentity($0, app)
        }
        var incoming = app
        if let id {
            guard registered.savedApps.contains(where: { $0.id == id }) else {
                throw SavedAppRegistrationError.missingReplacement
            }
            let savedIDs = Set(registered.savedApps.map(\.id))
            if let duplicate = matches.first(where: { $0.id != id && savedIDs.contains($0.id) }) {
                throw SavedAppRegistrationError.alreadySaved(duplicate.name)
            }
            // 자동 감지된 임시 항목은 등록된 앱에 합치며 자동 등록 억제 기록을 만들지 않는다.
            for duplicate in matches where duplicate.id != id {
                registered.discard(duplicate.id)
            }
            incoming.id = id
        } else {
            let suppressed = registered.configuration.removedApps.first {
                canonicalPath($0.bundlePath) == path && compatibleIdentity($0, app)
            }
            // 이미 등록한 항목은 유지하고, 재등록할 때는 새 관찰 ID보다 이전 설치 ID를 우선한다.
            let selectedID = matches.first(where: { $0.isPinned && !$0.isExcluded })?.id
                ?? suppressed?.id ?? matches.first?.id
            if let selectedID {
                incoming.id = selectedID
                for duplicate in matches where duplicate.id != selectedID { registered.discard(duplicate.id) }
            }
        }
        guard let registeredID = registered.upsertRestoring(incoming) else {
            throw SavedAppRegistrationError.invalidIdentifier
        }
        registered.save(registeredID)
        catalog = registered
        return registeredID
    }

    private static func refreshLocations(in catalog: inout DockCatalog, refresh: (AppEntry) -> AppEntry?) {
        let live = catalog.orderedApps
        let liveIDs = Set(live.map(\.id))
        let suppressed = catalog.configuration.removedApps
        let known = live + suppressed.filter { !liveIDs.contains($0.id) }
        var refreshedByID: [AppID: AppEntry] = [:]
        for entry in known {
            guard var updated = refresh(entry), compatibleIdentity(entry, updated) else { continue }
            updated.id = entry.id
            updated.isPinned = entry.isPinned
            updated.isExcluded = entry.isExcluded
            updated.bookmarkData = updated.bookmarkData ?? entry.bookmarkData
            updated.lastSeen = max(entry.lastSeen, updated.lastSeen)
            refreshedByID[entry.id] = updated
            if liveIDs.contains(entry.id) { catalog.upsert(updated) }
        }
        for entry in suppressed {
            if let updated = refreshedByID[entry.id] { catalog.refreshRemovedApp(updated) }
        }
    }

    private static func compatibleIdentity(_ lhs: AppEntry, _ rhs: AppEntry) -> Bool {
        guard let left = lhs.bundleIdentifier, let right = rhs.bundleIdentifier else { return true }
        return left == right
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
