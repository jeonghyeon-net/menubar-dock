# Swift Package를 빌드의 기준으로 사용

AppKit 기반 arm64 앱을 Swift Package로 빌드하고 스크립트가 앱 번들·리소스·서명을 구성한다. 전체 Xcode가 없는 개발 환경에서도 같은 소스와 테스트로 실행 가능한 앱을 만들 수 있고, Xcode에서는 Package.swift를 직접 열 수 있다. Xcode 전용 UI 테스트 기능보다 재현 가능한 CLI 빌드를 우선하며, 메뉴 막대 실제 동작 검증은 별도 smoke test와 실기기 체크리스트로 수행한다.
