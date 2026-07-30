---
name: git-commit-pr
description: >
  커밋 메시지 작성, 브랜치 푸시, Pull Request 생성을 대형 오픈소스(Conventional Commits·
  Angular·Kubernetes·Linux 커널·Chris Beams)의 관행에 맞춰 수행한다.
  트리거 — "커밋해줘", "커밋 메시지 써줘", "commit", "이거 푸시해줘", "push",
  "PR 올려줘", "PR 만들어줘", "pull request", "머지 요청", "커밋 나눠줘",
  "커밋 메시지 이거 괜찮아?", "PR 설명 써줘", "브랜치 파서 올려줘".
  리뷰어가 읽을 것을 전제로 "무엇을"이 아니라 "왜"를 남기는 것이 목적.
---

# 커밋 · 푸시 · PR

버전: v1.0.0

## 0. 먼저 확인할 것

**커밋·푸시·PR은 사용자가 요청했을 때만 한다.** 코드를 고쳤다는 이유로 자동으로
커밋하지 않는다. 요청받았다면 순서대로:

```bash
git status                    # 의도치 않은 파일이 섞였는지
git diff --stat               # 변경 규모
git log --oneline -10         # ← 가장 중요
```

**기존 레포의 커밋 스타일이 이 스킬의 기본값을 이긴다.** `git log` 를 읽고
그 레포가 Conventional Commits를 쓰는지, 대문자로 시작하는지, 스코프를 쓰는지
먼저 파악한 뒤 거기에 맞춘다. 새 레포이거나 관습이 없을 때만 아래 기본값을 쓴다.

## 1. 커밋 단위 나누기

한 커밋 = **한 가지 논리적 변경**. 되돌릴 때 이것만 되돌릴 수 있는가로 판단한다.

- 리팩터링과 기능 추가를 한 커밋에 섞지 않는다. 리뷰어가 어느 줄이 동작을
  바꾸는지 구분할 수 없게 된다.
- 포맷팅·이름 변경 같은 잡음은 별도 커밋으로 분리한다.
- 반대로 25개짜리 잘게 쪼갠 커밋도 리뷰가 어렵다. "논리적으로 구분되는 덩어리"가 기준이지
  개수를 늘리는 게 목적이 아니다.

## 2. 커밋 메시지

```
<type>(<scope>): <제목 50자 내외, 명령형, 마침표 없음>

무엇을 바꿨는지가 아니라 왜 바꿨는지. 기존 동작은 어땠고 왜 문제였는지.
72자에서 줄바꿈. 코드를 보면 아는 내용(how)은 쓰지 않는다.

Refs: #123
```

검증법: **"If applied, this commit will ___"** 문장에 제목을 넣어 말이 되면 통과.
`Add cache layer` ✓ / `Added cache layer` ✗ / `Adding cache` ✗

기본 type: `feat` `fix` `docs` `refactor` `perf` `test` `build` `ci` `chore`
파괴적 변경: `feat(api)!:` 또는 본문 뒤 `BREAKING CHANGE: 설명`

**`Fixes #123` / `Closes #123` 를 커밋 메시지에 쓰지 않는다.** 이슈 연결은 PR 본문에
쓴다. 커밋에 쓰면 체리픽·리베이스로 커밋이 여러 번 옮겨 다닐 때마다 의도치 않게
이슈가 닫힌다(Kubernetes가 명시적으로 금지하는 이유). 커밋에서 참조만 하려면 `Refs: #123`.

상세 규칙·타입별 판단 기준·안티패턴 → `references/commit-message.md`

## 3. 푸시

```bash
git branch --show-current
```

- `main` / `master` 에서 작업 중이면 **먼저 브랜치를 판다**. 브랜치명은
  `feat/short-slug`, `fix/short-slug`, `docs/short-slug`.
- 첫 푸시는 `git push -u origin <branch>`.
- `--force` 는 쓰지 않는다. 되돌려야 하면 `--force-with-lease`, 그것도 사용자 확인 후.
- 인증·권한 오류(403, `Permission to ... denied`, `could not read Username`)가 나면
  자격증명 문제이지 코드 문제가 아니다. 계정이 여러 개인 환경이라면 해당 레포의
  로컬 지침(`CLAUDE.local.md`)에 폴백 절차가 있는지 먼저 확인한다.

## 4. PR

```bash
gh pr create --title "..." --body "..."
```

제목은 커밋 제목과 같은 규칙(명령형, 50자 내외). 본문 구성:

```markdown
## 무엇을
한두 문장 요약.

## 왜
해결하려는 문제. 이슈가 있으면 Fixes #123.

## 어떻게
리뷰어가 놓치기 쉬운 설계 판단, 대안을 버린 이유.

## 확인
- [ ] 테스트 통과
- [ ] (UI 변경이면) before/after 스크린샷
```

- 레포에 `.github/pull_request_template.md` 가 있으면 **그 템플릿이 우선**이다.
- PR은 작게. 리뷰에 4시간 걸리는 PR은 방치된다. 작고 명백한 PR 100개가
  리뷰 불가능한 덩어리 10개보다 낫다.
- 리뷰어가 헷갈릴 만한 곳은 PR에 셀프 코멘트를 달아 미리 설명한다.
- AI 도구가 크게 관여한 변경이면 그 사실을 PR 본문에 밝힌다(Kubernetes 등이 요구).

템플릿 전문·규모 기준·리뷰 대응 → `references/pr-description.md`

## 5. 하지 말 것

- 요청 없는 커밋·푸시·PR
- `git add -A` 로 무심코 전체 스테이징 (`.env`, 로컬 설정, 빌드 산출물이 섞인다)
- `.gitignore` 된 파일을 `git add -f` 로 강제 추가
- 커밋 메시지에 비밀키·토큰·내부 URL
- 실패한 테스트를 "고쳐졌다"고 보고하고 커밋
- 사용자가 만든 커밋을 임의로 `--amend` 하거나 히스토리 재작성
