# 기여 안내

## 개발 환경

- Apple Silicon Mac, macOS 14 이상
- Swift 6.2 이상의 Command Line Tools 또는 Xcode
- `make check`로 빌드/테스트, `make app`으로 앱 번들 생성

## 구조와 작성 규칙

도메인 용어는 [CONTEXT.md](CONTEXT.md), 책임 경계는 [모듈 계약](docs/module-contracts.md)을 따릅니다. 도메인은 Foundation만 사용하고 OS 연동/UI의 실패를 명시적으로 처리합니다. 코드 주석과 문서는 한국어로 작성합니다.

수정하는 불변식과 오류 경계에 테스트를 추가하고 `make check`를 통과시켜 주세요. 다중 화면 렌더링 수정에는 두 화면의 활성/비활성 비교 기록을 남겨 주세요. `force unwrap`, 무분별한 동시 실행, idle polling을 피합니다.

현재 프로젝트는 관리자의 요청에 따라 `main` 단일 브랜치로 관리하며 PR 흐름을 사용하지 않습니다. 커밋은 검증 가능한 작은 단위로 만들고 목적을 제목에 적습니다. 배포 자격 증명과 사용자 설정은 저장소에 포함하지 않습니다.
