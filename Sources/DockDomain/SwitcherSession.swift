import Foundation

/// 호출 당시 순서를 고정하므로 앱 실행 알림이 선택 대상을 바꾸지 않는다.
public struct SwitcherSession: Equatable, Sendable {
    public private(set) var ids: [AppID]
    public private(set) var selectedID: AppID?

    public init(ids: [AppID], currentID: AppID?, direction: Int) {
        var seen = Set<AppID>()
        self.ids = ids.filter { seen.insert($0).inserted }
        guard !self.ids.isEmpty else {
            selectedID = nil
            return
        }
        if let currentID, self.ids.contains(currentID) {
            selectedID = currentID
            move(direction)
        } else {
            selectedID = direction < 0 ? self.ids.last : self.ids.first
        }
    }

    public mutating func move(_ distance: Int) {
        guard !ids.isEmpty else { selectedID = nil; return }
        guard let selectedID, let index = ids.firstIndex(of: selectedID) else {
            self.selectedID = distance < 0 ? ids.last : ids.first
            return
        }
        // Int.min도 안전하게 처리하며 큰 이동 값을 배열 길이로 먼저 줄인다.
        let offset = distance % ids.count
        let target = (index + offset + ids.count) % ids.count
        self.selectedID = ids[target]
    }

    public mutating func reconcile(validIDs: Set<AppID>) {
        let previous = ids
        let previousIndex = selectedID.flatMap { previous.firstIndex(of: $0) }
        ids.removeAll { !validIDs.contains($0) }
        guard !ids.isEmpty else { selectedID = nil; return }
        if let selectedID, validIDs.contains(selectedID) { return }
        // 삭제된 선택 항목 뒤에서 처음 살아 있는 항목을 고르고 끝에서는 순환한다.
        if let previousIndex {
            for offset in 1...previous.count {
                let candidate = previous[(previousIndex + offset) % previous.count]
                if validIDs.contains(candidate) { selectedID = candidate; return }
            }
        }
        selectedID = ids.first
    }
}
