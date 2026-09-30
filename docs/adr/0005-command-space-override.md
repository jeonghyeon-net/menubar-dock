# ⌘ Space와 Spotlight 시스템 설정

2026-09-30. 앱 선택의 기본 키를 ⌘ Space / ⇧⌘ Space로 바꾸고 macOS 설정보다 우선 사용한다.

## 오픈소스 근거

- [Spectacle의 단축키 관리자](https://github.com/eczarny/spectacle/blob/e75c341ec2cba179c1bb8aa726a870c4132207df/Spectacle/Sources/SpectacleShortcutManager.m)는 `RegisterEventHotKey`, `GetEventDispatcherTarget`, 일반 등록 옵션을 사용한다.
- [Rectangle의 단축키 관리자](https://github.com/rxhanson/Rectangle/blob/c0ae7f87abe66f66b2857fbd4ad19ef802a9b43a/Rectangle/ShortcutManager.swift)는 MASShortcut에 등록을 맡긴다.
- [MASShortcut의 등록 구현](https://github.com/cocoabits/MASShortcut/blob/6f2603c6b6cc18f64a799e5d2c9d3bbc467c413a/Framework/Monitoring/MASHotKey.m)도 같은 일반 Carbon 등록을 사용한다. [검증기](https://github.com/cocoabits/MASShortcut/blob/6f2603c6b6cc18f64a799e5d2c9d3bbc467c413a/Framework/Model/MASShortcutValidator.m)는 `CopySymbolicHotKeys`로 켜진 시스템 조합을 확인한다.

소스의 API 사용과 수명 관리를 참고했으며 라이브러리나 코드를 복사해 포함하지 않는다. 기존 앱의 접근성 권한은 타 앱 창 제어에도 필요하므로 이를 단축키 가로채기 구현의 근거로 보지 않는다.

## 선택

`DockPlatform`에서 CFPreferences로 `com.apple.symbolichotkeys`의 Spotlight 항목 64만 변경한다. 켜진 키가 ⌘ Space일 때만 해제하고 다른 조합·항목·원래 키 값은 그대로 둔다. `activateSettings -u`를 실행해 현재 세션에 적용하며 실행 시간은 3초로 제한한다. 도구가 없거나 설정 저장·적용에 실패하면 오류를 반환한다.

`DockShortcuts`는 플랫폼의 준비 콜백 뒤 두 조합을 등록한다. ⌘ Space의 독점 등록이 충돌하면 활성 시스템 조합이 없는지 먼저 확인하고 일반 등록으로 전환한다. 나머지 조합의 독점 등록·오류 처리는 유지한다. 두 번째 키 등록까지 성공해야 완료이며 실패하면 등록과 이번 시스템 설정 변경을 복구한다. 복구 중 사용자가 바꾼 Spotlight 값이나 다른 항목은 덮어쓰지 않는다.

정상 적용한 Spotlight 해제는 사용자 설정으로 유지하며 앱 종료 시 자동 복구하지 않는다. 복구는 Menu Bar Dock의 키를 끄거나 변경한 뒤 시스템 설정에서 Spotlight를 다시 켜는 방식이다. 사용자 안내와 설정 화면에 이 동작을 명시한다.

## 범위와 한계

일반 키 감시용 event tap이나 접근성 권한을 앱에 추가하지 않는다. Carbon 일반 등록은 다른 앱의 독점 등록을 강제로 빼앗지 못한다. 같은 키를 사용하는 별도 런처의 설정은 사용자 안내에 따라 해제해야 한다.

Spotlight 설정 적용 도구는 macOS 내부 경로에 있으므로 지원 OS별 실제 확인이 필요하다. macOS 27에서 전역 이벤트 전달을 확인했으며 macOS 14–26 전체를 검증했다고 주장하지 않는다. 실패 시 수동 설정 경로를 알려 주고 메뉴 막대의 마우스 조작은 계속 제공한다.

기본값 이전 세대를 저장하여 이전 기본 조합 두 개만 한 번 이전한다. 선택 패널의 로컬 입력 제외도 현재 키 코드와 수정 키를 사용한다. 배포 시작 검사는 이 서비스 자체를 시작하지 않아 사용자 설정에 영향을 주지 않는다.
