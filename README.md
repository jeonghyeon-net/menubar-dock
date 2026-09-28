# Menu Bar Dock

[![CI](https://github.com/jeonghyeon-net/menubar-dock/actions/workflows/ci.yml/badge.svg)](https://github.com/jeonghyeon-net/menubar-dock/actions/workflows/ci.yml)

Apple Silicon Mac용 네이티브 메뉴 막대 앱 런처입니다. **Swift 6 + AppKit**, 외부 패키지 의존성 없이 구현했습니다. macOS 14 이상에서 동작하도록 빌드합니다.

- 앱 순서를 직접 정하고, 종료·실행·활성화 후에도 유지합니다.
- 고정한 앱과 실행 중인 앱을 한 줄로 표시합니다. 실행 중 점·밑줄·배지는 없습니다.
- `Option+Tab` / `Shift+Option+Tab`으로 이동하고 `Enter`로 엽니다. `Esc`는 취소합니다.
- 앱 추가·고정·제외·순서 변경, 아이콘 크기·간격·개수, compact 모드, 로그인 시작을 설정합니다.
- 공간을 넘는 앱은 `…` 메뉴에서 열 수 있습니다.
- 비활성 화면의 표시에는 표준 `NSStatusBarButton.image`와 시스템 외관을 사용합니다.
- 타 앱 창을 강제로 옮기지 않으며 손쉬운 사용·화면 기록 권한을 요청하지 않습니다.

## 빌드 및 실행

Swift 6.2 이상의 Command Line Tools 또는 Xcode가 필요합니다. 이 저장소의 검증 환경은 macOS 27.0 / Swift 6.4 / arm64입니다.

```sh
make check
make app
open "build/Menu Bar Dock.app"
```

`make package`는 `dist/`에 arm64 앱 ZIP, 설치 DMG, SHA-256 체크섬을 만듭니다. 서명 인증서가 없으면 로컬 실행용 ad-hoc 서명입니다. 공개 배포용 Developer ID 서명·공증 방법은 [배포 안내](docs/releasing.md)를 참고하세요.

첫 실행 시 설정 창이 열립니다. 기존 Menu Bar Dock은 종료한 뒤 새 앱을 사용하세요. 메뉴 막대가 가려졌다면 Finder에서 앱을 다시 열어 설정에 접근할 수 있습니다.

## 구조

```text
DockDomain       순서·고정·제외·표시 정책과 선택 세션
DockPersistence  버전 있는 JSON, 원자 저장, 손상 복구
DockPlatform     앱 감지·실행·아이콘·로그인 항목
DockShortcuts    전역 단축키 등록·저장·충돌 복구
MenuBarDock      앱 수명과 유스케이스 조립, AppKit UI
```

도메인은 Foundation만 참조합니다. UI는 표시 모델과 명령으로 연결되고, OS 연동과 파일 저장은 별도 모듈이 담당합니다. 정책·실패 복구·키보드 동작을 자동 테스트하며, 실제 다중 화면 외관은 별도 실기기 검증 항목입니다.

- [사용 안내](docs/user-guide.md)
- [아키텍처](docs/architecture.md) · [모듈 계약](docs/module-contracts.md)
- [구현 단계와 검증 기록](docs/implementation-plan.md)
- [기존 앱 조사](docs/upstream-audit.md) · [설계 결정](docs/adr/)
- [기여 방법](CONTRIBUTING.md) · [보안](SECURITY.md) · [변경 기록](CHANGELOG.md)

[EthanSK/Menu-Bar-Dock](https://github.com/EthanSK/Menu-Bar-Dock)의 사용 경험을 참고해 별도 코드로 구현했습니다. 라이선스는 [MIT](LICENSE)입니다.
