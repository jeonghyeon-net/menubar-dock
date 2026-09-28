# Menu Bar Dock

Dock은 숨기고, 앱은 메뉴 막대에서 여세요.

<p align="center">
  <img src="docs/assets/menu-bar-hero.png" width="605" alt="실제 macOS 메뉴 막대에 나란히 놓인 시스템 설정, ChatGPT, Safari, Slack, Notion, Visual Studio Code, Finder 아이콘">
</p>

각 앱 아이콘을 클릭하면 바로 실행하거나 전환합니다. 앱 순서·크기·간격을 조절하고, 메뉴 막대에 다 들어가지 않는 앱은 `Option+Tab`으로 선택할 수 있습니다.

[다운로드·설치](#시작하기) · [사용 안내](docs/user-guide.md) · [개발과 기여](CONTRIBUTING.md)

## 시작하기

macOS 14 이상의 Apple Silicon Mac에서 사용할 수 있습니다.

1. [최신 릴리스](https://github.com/jeonghyeon-net/menubar-dock/releases/latest)의 **Assets**에서 `.dmg` 파일을 다운로드합니다.
2. DMG를 열고 **Menu Bar Dock**을 **Applications(응용 프로그램)** 폴더로 드래그합니다.
3. 응용 프로그램 폴더에서 **Menu Bar Dock**을 실행합니다.

처음 실행하면 설정 창이 열립니다.

## 사용하기

- 메뉴 막대의 앱 아이콘을 **왼쪽 클릭**하면 앱이 열립니다.
- `Option+Tab` 패널의 **톱니 버튼**으로 설정을 엽니다. 아이콘 우클릭 메뉴나 Menu Bar Dock 재실행으로도 열 수 있습니다.
- 설정의 **항상 표시할 앱**에 `+`로 추가하고 드래그로 순서를 정합니다. `−`는 고정만 해제하며, 실행 중인 앱은 앞쪽에 남고 종료하면 사라집니다.
- 등록하지 않은 실행 중 앱은 앞쪽에, 등록한 앱은 뒤쪽에 저장한 순서로 표시합니다. 같은 앱은 한 번만 표시합니다.

macOS Dock에 고정한 앱과 Finder는 자동으로 가져옵니다. Finder가 필요 없으면 설정에서 **Finder 숨기기**를 켜세요. 아이콘 크기·간격·최대 표시 개수와 로그인할 때 시작 여부도 설정에서 바꿀 수 있습니다.

`Option+Tab`으로 앱을 고른 뒤 **Enter**로 엽니다. 패널에서 이름을 입력하면 이 Mac의 앱을 검색합니다. **Esc**는 검색어를 지우고, 검색어가 없으면 패널을 닫습니다.

<details>
<summary>설정과 키보드 선택 화면</summary>

<p align="center">
  <img src="docs/assets/settings.png" width="540" alt="항상 표시할 앱 목록, 아이콘 크기·간격, 단축키를 한 창에서 조절하는 설정">
</p>

<p align="center">
  <img src="docs/assets/switcher.png" width="420" alt="검색 입력창과 앱 아이콘을 함께 보여 주는 Option+Tab 선택 패널">
</p>

</details>

자세한 조작과 문제 해결은 [사용 안내](docs/user-guide.md)에 있습니다.

## 만든 이유

**애플은 터치바를 돌려내라!**

가뜩이나 작은 맥북 화면에서 Dock까지 한 줄을 차지하고 있는 걸 보면 속이 터집니다. 코드 한 줄, 문서 한 문단, 타임라인 한 칸이 아쉬운데 앱 아이콘들이 화면 아래에 옹기종기 모여 귀한 자리를 차지하고 있습니다. 앱을 열려고 켠 컴퓨터에서, 앱을 여는 버튼 때문에 정작 앱을 쓸 공간이 줄어드는 이 상황. 이 좁은 화면에서 Dock한테까지 월세를 내고 싶지는 않았습니다.

자동 숨김을 켜면 되지 않느냐고요? 물론 켭니다. 그런데 이제는 앱 하나 바꿀 때마다 화면 아래를 더듬어 숨어 있는 Dock을 불러내야 합니다. 숨기면 숨기는 대로 번거롭고, 펼쳐 두면 펼쳐 두는 대로 공간이 아깝습니다. 그래서 이미 화면 위에 있는 메뉴 막대에 앱을 올렸습니다. 자주 쓰는 앱을 원하는 순서대로 놓고 바로 누르면 됩니다. 화면 아래쪽은 다시 작업 공간으로 돌려받습니다. Menu Bar Dock은 이 소박하고도 지극히 정당한 공간 반환 요구에서 시작했습니다.

그리고 이쯤 되면 터치바가 생각납니다. 손가락 바로 앞에 앱 전환 버튼을 놓고, 화면은 작업에 온전히 쓰는 상상. 아래 사진처럼 Windows 작업 표시줄까지 올라갔던 그 자리에, 내가 고른 앱들을 쭉 놓고 쓰면 얼마나 좋겠습니까. 그 가능성을 떠올릴 때마다 아쉬움이 다시 끓어오릅니다. 키보드 위의 그 한 줄을 내 취향대로 쓰고 싶었습니다. 자주 여는 앱, 자주 누르는 기능, 그 순간 필요한 조작을 내 손 가까이에 두고 싶었습니다. 저는 아직 그 자리를 포기할 생각이 없습니다.

애플, 듣고 있습니까. 매일 들여다보는 작은 화면의 몇 픽셀에도 사람은 이렇게 진심입니다. 결국 앱을 메뉴 막대에 쑤셔 넣는 프로그램까지 직접 만들었습니다. 터치바가 그리워서, Dock이 차지하는 공간이 아까워서, 클릭 한 번을 더 편하게 하고 싶어서 여기까지 왔습니다. 이 저장소는 그 불만이 실행 파일이 된 결과물입니다. 터치바가 돌아오는 날까지 메뉴 막대라도 알뜰하게 써보겠습니다.

**그러니까 애플은 터치바를 돌려내라. 내 화면은 내가 쓰겠다!**

macOS의 Dock 자동 숨김과 함께 사용하면 화면 아래쪽을 더 넓게 쓸 수 있습니다.

<p align="center">
  <img src="docs/assets/touch-bar-reference.jpeg" width="500" alt="MacBook Pro에서 Windows 작업 표시줄을 화면 하단과 Touch Bar에 표시한 참고 사례">
</p>

참고 이미지: Windows 작업 표시줄을 Touch Bar에 표시한 실험. [Jablíčkář.cz 기사](https://jablickar.cz/ko/touch-bar-na-windows/)에 실린 사진입니다.

## 개발과 문서

Swift와 AppKit으로 만든 Apple Silicon용 앱입니다. 소스 빌드와 기여 방법은 [개발 안내](CONTRIBUTING.md)를 따릅니다.

- [아키텍처](docs/architecture.md) · [모듈 계약](docs/module-contracts.md) · [설계 결정](docs/adr/)
- [빌드와 배포](docs/releasing.md) · [검증 기록](docs/implementation-plan.md)
- [변경 기록](CHANGELOG.md) · [보안 문제 제보](SECURITY.md)

[EthanSK/Menu-Bar-Dock](https://github.com/EthanSK/Menu-Bar-Dock)의 사용 경험을 참고해 별도 코드로 구현했습니다. [MIT 라이선스](LICENSE)로 배포합니다.
