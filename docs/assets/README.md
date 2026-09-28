# 문서 이미지

- `menu-bar-hero.png`: README 대표 이미지. 2026-09-28, macOS 27에서 실행한 Menu Bar Dock 1.0.3의 실제 메뉴 막대 영역을 캡처했다. 오른쪽에는 macOS의 일반 상태 항목도 보인다. 1210×78px 원본을 605px 너비로 표시해 Retina 해상도를 유지한다.
- `settings.png`: Finder 숨기기 옵션을 포함한 실제 설정 뷰를 시스템 앱 6개로 렌더링한 이미지. README에서는 접힌 영역 안에서 540px 너비로 표시한다. `./scripts/check-settings-input.sh --snapshot docs/assets/settings.png`로 다시 생성한다. 개인 설정이나 화면 배경을 포함하지 않는다.
- `app-icon.png`: `scripts/make-icon.swift`의 256px 출력. 흰 타일 위에 흑연색 메뉴 막대 심볼 하나를 그리며 재질은 원본에 포함되어 있다. macOS가 정적 ICNS에 자동으로 추가하는 효과가 아니다. 시안은 내장 imagegen으로 탐색했고 배포 아이콘은 투명한 윤곽과 작은 크기의 선명도를 위해 AppKit 벡터로 렌더링한다.
- `settings-1.0.3.png`: 1.0.3 검증 기록에 사용한 이전 단일 설정 창 캡처.
- `switcher.png`: 1.0.4의 실제 앱 선택 뷰를 시스템 앱 3개로 렌더링한 이미지. README의 단축키 설명에서 420px 너비로 표시한다.
- `search.png`: 같은 뷰의 앱 검색 결과. 실제 설치된 Finder·Safari·Terminal을 검증용 결과로 주입해 아이콘과 이름 한 줄을 확인한다. 개인 검색 결과나 경로는 포함하지 않는다.
- `menu-bar.png`: 입력 검증 도구가 실제 시스템 버튼을 개별 렌더해 나란히 배치한 참고 이미지. 데스크톱 메뉴 막대 전체 캡처와 구별한다.
- `appearance.png`: 1.0.2의 표시 설정 기록.
- `inactive-display-reference.png`: 비활성 디스플레이 문제를 기록한 사용자 참고 이미지.
- `touch-bar-reference.jpeg`: 사용자가 지정한 [Jablíčkář.cz 기사](https://jablickar.cz/ko/touch-bar-na-windows/)의 대표 사진. Windows 작업 표시줄을 Touch Bar에 표시한 참고 사례이며 Menu Bar Dock의 제품 화면은 아니다. [원본 JPEG](https://jablickar.cz/wp-content/uploads/2019/08/Windows-Touch-Bar-1.jpeg)를 2026-09-28에 내려받았고, 1000×750px 원본을 편집 없이 보관한다. 이 외부 사진은 프로젝트의 MIT 라이선스 적용 대상에서 제외하며 권리는 원저작자에게 있다.

실제 앱 캡처에는 아이콘이나 동작을 합성하지 않는다. 대표 화면은 메뉴 막대를 우선하고, 설정·키보드 선택 패널은 해당 기능 설명에 배치한다.

선택 패널과 검색 이미지는 다음 명령으로 다시 생성한다.

```sh
./scripts/check-switcher-input.sh --idle-snapshot docs/assets/switcher.png --snapshot docs/assets/search.png
```
