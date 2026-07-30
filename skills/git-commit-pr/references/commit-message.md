# 커밋 메시지 상세 규칙

## 형식

```
<type>(<scope>): <description>

<body>

<footer>
```

`<type>` 뒤 콜론과 **공백 한 칸**은 필수다. 스코프는 선택.

## 7가지 기본 규칙 (Chris Beams)

1. 제목과 본문을 빈 줄로 분리한다
2. 제목은 50자 내외 (GitHub는 50자에서 경고, 72자에서 잘라낸다)
3. 제목 첫 글자 처리는 아래 "대소문자 충돌" 참조
4. 제목 끝에 마침표를 찍지 않는다 — 글자 수만 낭비한다
5. 제목은 명령형으로 쓴다
6. 본문은 72자에서 줄바꿈한다 (들여쓰기 여유를 두고 80자 이내 유지)
7. 본문은 **what/why**를 쓰고 **how**는 쓰지 않는다 — how는 코드에 이미 있다

### 명령형 판정

> "If applied, this commit will ___"

| ✓ | ✗ |
| --- | --- |
| `Fix race condition in worker pool` | `Fixed race condition` |
| `Add retry to upload handler` | `Adding retry` / `Adds retry` |
| `Remove deprecated config flag` | `Removal of deprecated flag` |

Git 자신이 커밋을 만들 때 명령형을 쓴다(`Merge branch...`, `Revert...`).
그 관습에 맞추는 것이다.

## type 선택

| type | 쓸 때 | SemVer |
| --- | --- | --- |
| `feat` | 사용자에게 보이는 새 기능 | MINOR |
| `fix` | 버그 수정 | PATCH |
| `docs` | 문서만 변경 | - |
| `refactor` | 동작 변화 없는 구조 변경 | - |
| `perf` | 성능 개선 | - |
| `test` | 테스트 추가·수정 | - |
| `build` | 빌드 시스템·의존성 | - |
| `ci` | CI 설정·스크립트 | - |
| `chore` | 그 외 잡무 | - |

**판단이 갈리는 경우:**

- 버그를 고치려고 리팩터링했다 → `fix`. 사용자에게 보이는 결과가 기준이다.
- 리팩터링하다 보니 버그가 사라졌다 → `refactor` + 본문에 그 사실을 적는다.
- 내부 함수를 추가했지만 아직 아무도 호출하지 않는다 → `feat` 아님. `chore` 나 `refactor`.
- 의존성 버전을 올려 취약점을 막았다 → `fix(deps)`.
- `chore` 는 마지막 수단이다. 남발하면 CHANGELOG에서 아무 정보도 안 준다.

## scope

영향받는 모듈·패키지 이름. 이 레포라면 스킬 이름이 자연스럽다.

```
feat(git-commit-pr): add PR template detection
docs(conventions): clarify agent placement rule
```

- 여러 곳에 걸치면 생략한다. 억지로 붙이지 않는다.
- 파일명을 스코프로 쓰지 않는다. 파일은 옮겨 다니지만 커밋은 영구적이다.

## 파괴적 변경

두 가지 방법이 있고 **둘 다 써도 된다**.

```
feat(api)!: drop support for Node 18
```

```
feat(api): drop support for Node 18

BREAKING CHANGE: Node 18 이하에서 동작하지 않는다.
Node 20 이상으로 올린 뒤 `npm rebuild` 를 한 번 실행해야 한다.
```

`!` 는 눈에 띄고, `BREAKING CHANGE:` 푸터는 마이그레이션 방법을 적을 자리를 준다.
파괴적 변경이면 **어떻게 고쳐야 하는지**를 반드시 함께 적는다.

## 본문 작성법

본문은 "리뷰어가 이 diff를 보고 던질 질문"에 미리 답하는 자리다.

```
fix(auth): keep session alive during token refresh

리프레시 요청이 500ms를 넘으면 그 사이 들어온 요청이 만료된 토큰으로
401을 받고 사용자가 로그아웃됐다. 리프레시 중에는 이전 토큰을 유효한
것으로 취급하도록 유예 구간을 뒀다.

유예 구간을 5초로 잡은 것은 p99 리프레시 지연이 1.2초라서다.
토큰 자체의 수명은 늘리지 않았다.

Refs: #412
```

포함할 것:
- 기존 동작과 그것이 왜 문제였는지
- 사용자에게 보이는 영향 (크래시, 지연, 데이터 손실)
- 숫자로 말할 수 있으면 숫자 (`p99 1.2초`, `쿼리 4회 → 1회`)
- 눈에 안 보이는 트레이드오프, 대안을 버린 이유

빼도 되는 것:
- diff를 읽으면 아는 내용 ("함수 추가함", "if문 수정함")
- "코드 정리", "약간 개선" 같은 내용 없는 문장

## 이슈 참조 — 커밋이 아니라 PR에

GitHub는 `Fixes #123`, `Closes #123`, `Resolves #123` 를 보면 이슈를 자동으로 닫는다.
**이걸 커밋 메시지에 쓰면 안 된다.** 체리픽·리베이스·백포트로 같은 커밋이 여러 브랜치를
돌아다니면 그때마다 이슈가 닫히거나 엉뚱한 PR에 연결된다.
Kubernetes는 이를 "예상치 못한 부작용"이라며 커밋 메시지 사용을 금지한다.

- 커밋에서는 `Refs: #123` 로 참조만 한다.
- 닫기 키워드는 **PR 본문**에 쓴다.

## 트레일러

키-값 형태로 본문 뒤 빈 줄 다음에 붙인다.

```
Refs: #123
Fixes: 54a4f0239f2e ("worker: reset backoff on success")
Co-Authored-By: Name <email>
```

`Fixes:` 로 이전 커밋을 지목할 때는 SHA 최소 12자 + 괄호 안에 그 커밋 제목.
(이건 이슈 번호가 아니라 커밋을 가리키는 리눅스 커널 관습이다. GitHub 이슈 닫기와 헷갈리지 말 것.)

## 안티패턴

| 나쁨 | 왜 |
| --- | --- |
| `Update code` / `수정` / `.` | 6개월 뒤 `git log` 에서 아무 정보도 못 준다 |
| `Fix bug` | 어떤 버그인지 모른다. 증상을 쓴다 |
| `WIP` | 머지 전에 정리한다. 남으면 히스토리 오염 |
| `Address review comments` | 무엇을 어떻게 바꿨는지 쓴다 |
| 제목 120자 | 로그·이메일·rebase 화면에서 잘린다 |
| 본문 없이 거대한 diff | 리뷰어가 의도를 추측하게 만든다 |

## 대소문자 충돌 — 하나만 고른다

두 관습이 정면으로 부딪힌다.

- **Chris Beams / Linux 커널 / Kubernetes**: 제목 첫 글자를 대문자로 (`Add cache layer`)
- **Conventional Commits / Angular**: type 접두사를 쓰고 뒤는 소문자 (`feat: add cache layer`)

**이 레포의 기본값: Conventional Commits (소문자).** 기계가 파싱해 CHANGELOG와
버전 범프를 자동 생성할 수 있다는 이점이 대문자 관습보다 실용적이다.
다만 **다른 레포에서 작업할 때는 `git log` 를 먼저 읽고 그 레포를 따른다.**
일관성이 어느 쪽 규칙을 고르는지보다 중요하다.

---

## 출처

- [Conventional Commits v1.0.0](https://www.conventionalcommits.org/en/v1.0.0/)
- [Chris Beams, How to Write a Git Commit Message](https://cbea.ms/git-commit/)
- [Angular Commit Message Guidelines](https://github.com/angular/angular/blob/main/contributing-docs/commit-message-guidelines.md)
- [Linux kernel, Submitting Patches](https://docs.kernel.org/process/submitting-patches.html)
- [Kubernetes, Pull Request Process](https://www.kubernetes.dev/docs/guide/pull-requests/)
