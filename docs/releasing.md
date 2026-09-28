# 빌드와 배포

## 로컬 앱

```sh
make check
make package
"build/Menu Bar Dock.app/Contents/MacOS/MenuBarDock" --self-test
```

출력은 `build/Menu Bar Dock.app`, `dist/MenuBarDock-1.0.0-arm64.zip`, 같은 이름의 DMG와 SHA256SUMS다. DMG에는 앱과 Applications 바로가기가 있다. 앱을 Applications로 복사한 뒤 실행한다.

빌드는 arm64 Release다. 번들 ID는 `net.jeonghyeon.MenuBarDock`, 최소 OS는 macOS 14다. 앱 자체 라이브러리만 정적으로 연결하며 외부 패키지 다운로드가 필요하지 않다. 전체 Xcode 없이 Command Line Tools로도 빌드할 수 있다. 현재 로컬 CLT는 존재하지 않는 Developer 하위 framework 검색 경로 경고를 출력하지만 Swift 코드 경고 없이 링크·실행한다.

서명 인증서가 없는 환경은 ad-hoc 서명으로 검사한다. 이는 Developer ID와 공증을 대신하지 않는다. GitHub Actions의 일반 CI 산출물도 별도 배포 인증서를 주입하지 않은 ad-hoc 빌드다. 공개 다운로드에서 Gatekeeper가 신뢰하는 배포본은 다음 절차를 완료해야 한다. 보안 기능을 전역 해제하지 않는다.

## Developer ID와 공증

Apple Developer Program의 Developer ID Application 인증서를 키체인에 설치하고 notarytool profile을 준비한다. 자격 증명은 저장소·로그에 기록하지 않는다.

```sh
export SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
export NOTARY_PROFILE='menubar-dock-notary'
./scripts/notarize.sh
```

스크립트는 Hardened Runtime 서명 → ZIP 공증 → 앱 ticket staple → ZIP/DMG 재생성 → DMG 서명·공증·staple → spctl 검사 → 체크섬 순서로 수행한다. 인증서와 profile이 없으면 시작 전에 실패한다. Apple 자격 증명이 없는 현재 개발 환경에서는 이 경로를 실제 수행하지 않았다.

## 버전과 배포 게시

1. `Config/Info.plist`의 CFBundleShortVersionString과 CFBundleVersion을 올린다.
2. CHANGELOG와 검증 기록을 갱신하고 `make check`를 통과시킨다.
3. Developer ID·공증이 끝난 산출물을 깨끗한 사용자 환경에서 설치하고 로그인 시작을 검사한다.
4. 실제 두 화면에서 활성/비활성 색상, 1x/2x, Light/Dark, 노치, Spaces, fullscreen을 검사한다.
5. 검증한 커밋으로 `vMAJOR.MINOR.PATCH` 릴리스를 게시하고 ZIP/DMG/SHA256SUMS를 첨부한다.

현재 저장소는 main 하나로 운영한다. 커밋·CI artifact 생성과 공개 GitHub Release 게시를 구분한다. 앱의 업데이트 확인은 공개된 stable 릴리스만 읽고 설치를 자동 교체하지 않는다.

## 진단

- `--self-test`: 번들 ID, LSUIElement, 앱 아이콘, 기본 설정 검증 후 종료.
- `--smoke-test --data-directory /tmp/menubar-dock-smoke`: 별도 JSON 디렉터리에서 시작하고 3초 후 정상 저장·종료. 단축키 UserDefaults와 로그인 서비스 자체는 별도 macOS 저장소이므로 이 진단에서 변경하지 않는다.
- `--show-settings`: 실행 직후 설정 창 표시.

OSLog subsystem은 앱 조립의 `net.jeonghyeon.MenuBarDock`과 플랫폼 경계의 `app.menubardock`이다. 사용자 앱 경로나 이름을 로그에 임의로 추가하지 않는다.
