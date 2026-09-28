import DockDomain
import Testing

@Suite("키보드 선택 세션")
struct SwitcherSessionTests {
    let ids = ["a", "b", "c", "d"].map { AppID(rawValue: $0) }

    @Test("현재 앱 기준 다음·이전으로 시작하고 끝에서 순환한다")
    func startsAdjacentToCurrentApp() {
        #expect(SwitcherSession(ids: ids, currentID: ids[1], direction: 1).selectedID == ids[2])
        #expect(SwitcherSession(ids: ids, currentID: ids[1], direction: -1).selectedID == ids[0])
        #expect(SwitcherSession(ids: ids, currentID: ids[3], direction: 1).selectedID == ids[0])
        #expect(SwitcherSession(ids: ids, currentID: ids[0], direction: -1).selectedID == ids[3])
    }

    @Test("현재 앱이 없는 경우 이동 방향의 첫 항목을 선택한다")
    func startsAtBoundaryWithoutCurrentApp() {
        #expect(SwitcherSession(ids: ids, currentID: nil, direction: 1).selectedID == ids.first)
        #expect(SwitcherSession(ids: ids, currentID: AppID(), direction: -1).selectedID == ids.last)
    }

    @Test("선택 중 새 앱은 추가하지 않고 사라진 항목 뒤의 다음 후보를 선택한다")
    func reconciliationPreservesSessionSnapshot() {
        var session = SwitcherSession(ids: ids, currentID: ids[0], direction: 1)
        session.reconcile(validIDs: [ids[0], ids[3], AppID(rawValue: "new")])
        #expect(session.ids == [ids[0], ids[3]])
        #expect(session.selectedID == ids[3])
        session.reconcile(validIDs: [ids[0]])
        #expect(session.selectedID == ids[0])
        session.reconcile(validIDs: [])
        #expect(session.ids.isEmpty)
        #expect(session.selectedID == nil)
    }

    @Test("선택 항목이 살아 있으면 앞 항목이 제거되어도 대상을 바꾸지 않는다")
    func removalBeforeSelectionDoesNotShiftIt() {
        var session = SwitcherSession(ids: ids, currentID: ids[1], direction: 1)
        session.reconcile(validIDs: [ids[2], ids[3]])
        #expect(session.selectedID == ids[2])
    }

    @Test("비어 있거나 하나인 목록에서도 반복 입력이 안전하다")
    func emptyAndSingleItemSessions() {
        var empty = SwitcherSession(ids: [], currentID: nil, direction: 1)
        empty.move(-1)
        #expect(empty.selectedID == nil)
        var single = SwitcherSession(ids: [ids[0], ids[0]], currentID: ids[0], direction: -1)
        single.move(Int.min)
        single.move(Int.max)
        #expect(single.ids == [ids[0]])
        #expect(single.selectedID == ids[0])
    }

    @Test("한 바퀴 이동하거나 반대 이동하면 같은 선택으로 돌아온다")
    func navigationIsReversible() {
        for direction in [-10, -1, 0, 1, 10] {
            var session = SwitcherSession(ids: ids, currentID: ids[1], direction: 1)
            let start = session.selectedID
            session.move(direction)
            session.move(-direction)
            #expect(session.selectedID == start)
            session.move(ids.count)
            #expect(session.selectedID == start)
        }
    }
}
