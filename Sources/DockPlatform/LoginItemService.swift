import ServiceManagement

@MainActor
public final class LoginItemService {
    public init() {}

    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: "로그인할 때 자동으로 시작합니다."
        case .notRegistered: "자동 시작이 꺼져 있습니다."
        case .requiresApproval: "시스템 설정 > 일반 > 로그인 항목에서 허용해 주세요."
        case .notFound: "앱을 응용 프로그램 폴더에 설치한 후 다시 시도해 주세요."
        @unknown default: "로그인 항목의 상태를 확인할 수 없습니다."
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled { try service.register() }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
    }
}
