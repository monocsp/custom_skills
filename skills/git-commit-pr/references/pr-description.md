# PR 작성 상세 규칙

## 순서

```bash
git branch --show-current            # main이면 브랜치부터 판다
git log origin/main..HEAD --oneline  # 이 PR에 들어갈 커밋 확인
git diff origin/main...HEAD --stat   # 규모 확인
ls .github/pull_request_template.md  # 템플릿 있으면 그게 우선
gh pr create --title "..." --body "..."
```

`gh pr create --fill` 은 커밋 메시지를 그대로 PR 본문에 넣는다. 커밋이 하나이고
그 메시지가 충분할 때만 쓴다. 커밋이 여러 개면 직접 쓴다.

## 제목

커밋 제목과 같은 규칙. 명령형, 50자 내외, 마침표 없음.
레포가 Conventional Commits를 쓰면 PR 제목에도 붙인다 — squash merge 시
PR 제목이 그대로 커밋 메시지가 되기 때문이다.

```
feat(auth): add refresh token rotation
```

`Update stuff`, `버그 수정`, `PR` 같은 제목은 머지 후 히스토리에 영구히 남는다.

## 본문 템플릿

```markdown
## 무엇을
(한두 문장. 리뷰어가 첫 5초에 읽는 부분)

## 왜
(해결하려는 문제. 재현 조건이나 사용자 영향)
Fixes #123

## 어떻게
(설계 판단, 고려했다 버린 대안과 그 이유)

## 확인
- [ ] 테스트 통과 (`npm test`)
- [ ] 수동 확인: (구체적 시나리오)
- [ ] before/after 스크린샷 (UI 변경 시)

## 리뷰어에게
(특별히 봐줬으면 하는 곳, 확신이 덜한 부분, 후속 작업으로 미룬 것)
```

작은 PR이면 `무엇을` / `왜` 만 있어도 된다. 형식을 채우는 게 목적이 아니다.

## 이슈 연결

닫기 키워드는 **PR 본문에** 쓴다 (커밋 메시지에는 쓰지 않는다 —
`commit-message.md` 의 "이슈 참조" 참조).

- `Fixes #123` / `Closes #123` / `Resolves #123` → 머지 시 이슈 자동 종료
- 닫지 않고 참조만 → `Refs #123`, `Related to #123`
- 다른 레포 이슈 → `Fixes owner/repo#123`

## 크기

리뷰에 4시간이 걸리는 PR은 방치되거나 대충 승인된다.
**작고 명백한 PR 100개가 리뷰 불가능한 덩어리 10개보다 낫다.**

PR이 커졌을 때 쪼개는 축:
1. 순수 리팩터링 / 동작 변경 — 이 둘은 반드시 분리한다
2. 기반 작업(인터페이스·마이그레이션) / 그 위의 기능
3. 자동 생성 파일(lock, 스냅샷, 빌드 산출물) — 별도 커밋으로라도 분리

정말 못 쪼개면 PR 본문에 **읽는 순서**를 적어준다.
> 리뷰 순서: `types.ts` → `client.ts` → 나머지는 호출부 수정

## PR 안의 커밋

- 논리적으로 구분되는 단위로 나눈다. 25개짜리 커밋은 그 자체로 리뷰 부담이다.
- **squash 해야 하는 것** — "리뷰 반영", "오타", "테스트 고침" 같은 수습 커밋.
  이런 건 히스토리에 남을 가치가 없다.
- **squash 하면 안 되는 것** — 독립적으로 의미 있는 단계들.
  되돌릴 때 이 중 하나만 되돌리고 싶다면 남겨야 한다.

## 리뷰 대응

- 리뷰어가 헷갈릴 만한 줄에는 **PR을 올리자마자 셀프 코멘트**를 단다.
  질문이 오기 전에 답하는 게 왕복을 줄인다.
- 지적을 반영한 커밋은 `fix(auth): validate exp claim before use` 처럼
  무엇을 바꿨는지 쓴다. `Address feedback` 은 정보가 없다.
- 반영하지 않기로 했으면 이유를 답글로 남긴다. 조용히 무시하지 않는다.
- force push는 리뷰 중인 코멘트를 diff에서 떼어놓는다. 리뷰가 시작된 뒤에는
  덧붙이는 커밋으로 대응하고, 정리는 머지 시점 squash에 맡긴다.

## AI 관여 고지

Kubernetes를 비롯한 여러 프로젝트가 **AI 도구가 크게 관여한 PR은 그 사실을
밝히도록 요구**한다. 리뷰어가 검증 강도를 조절할 수 있게 하기 위해서다.
"리뷰어에게" 섹션에 한 줄 적는다.

> 이 PR의 초안은 Claude Code로 작성했고, 테스트는 로컬에서 직접 돌려 확인했습니다.

## 하지 말 것

- 초록 CI를 확인하지 않고 리뷰 요청
- 본문이 `.` 이거나 비어 있는 PR
- 관련 없는 변경 끼워넣기 ("겸사겸사 포맷팅도 돌렸습니다")
- 리뷰 중 조용한 force push로 히스토리 갈아엎기
- 승인받은 PR에 새 기능 추가 후 그대로 머지

---

## 출처

- [Kubernetes, Pull Request Process](https://www.kubernetes.dev/docs/guide/pull-requests/)
- [Kubernetes, Contributor Cheatsheet](https://www.kubernetes.dev/docs/contributor-cheatsheet/)
- [Conventional Commits v1.0.0](https://www.conventionalcommits.org/en/v1.0.0/)
- [Chris Beams, How to Write a Git Commit Message](https://cbea.ms/git-commit/)
