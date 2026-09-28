# UI와 전역 단축키를 시스템 프레임워크로 구현

현재 Command Line Tools의 macOS 27 SDK에는 SwiftUI 매크로 플러그인이 없어 SwiftUI 설정 화면과 KeyboardShortcuts 3.1.0을 빌드할 수 없다. 설정도 AppKit으로 구현하고 Carbon의 전역 hotkey 등록 API를 별도 `DockShortcuts` 경계에 격리한다. 앱의 기능을 유지하면서 외부 런타임 의존성과 리소스 번들 패키징을 줄일 수 있다. 일반 키 입력을 감시하는 event tap 대신 사용자가 지정한 조합만 등록한다.
