# 킥오프 — develop-looping-process 스킬 개선 작업

> 이 워크트리(`dolomood-app-renew-dlp-skill`, 브랜치 `feat/home-dlp-skill`)는 **develop-looping-process 스킬(및 관련 하네스 문서) 개선 전용**으로 분리했다. feat/home 본류에 엮인 다른 브랜치들과 격리하려는 목적. 앱 코드는 건드리지 않는다.

## 먼저 읽어라

1. **`docs/renew-guide/impl/settings/develop-looping-process-review.md`** — 이 작업의 입력. 스킬 현 구조(Part 1) + 개선 진단·우선순위·to-be 데이터모델(Part 2)이 도식과 함께 정리돼 있다. **codex 적대 논의를 이미 거친 산출물**이다.
2. 대상 파일들:
   - `.claude/skills/develop-looping-process/SKILL.md` (라우터 본체)
   - `docs/renew-guide/impl/settings/development-process.md` (프로세스 원문 SSOT)
   - `docs/renew-guide/impl/settings/spec-orchestration.md` (P1b 설계, 미배선)
   - `docs/renew-guide/impl/settings/develop-looping-process-status.md` (진행판 — 표 파손·`?` 값 있음)
   - 로스터 드리프트 동기화 대상: `AGENTS.md`, `development-process.md §11`(둘 다 "스킬 열하나"인데 실제 18개)

## 목표 (codex 재프레이밍)

> 이 스킬을 **"문서로만 존재하는 상태 머신" → "검증 가능한 상태 머신"**으로 승격한다. 지금은 결정적이어야 할 라우팅을 LLM이 손상된 마크다운을 읽어 해석하는 "검증되지 않은 수동 인터프리터" 상태다.

## 착수 전 — 사용자와 결정할 3가지 (review.md 말미)

구현 시작 전에 이 셋을 사용자에게 확인하고 동결하라(범위가 이걸로 갈린다):

1. **범위**: 상태 머신 승격(스키마+validator+순수 route, 도구화)까지 갈지 vs 응급처치(표 파손 복구 + 데드락 규칙 정정 + 로스터 동기화)만 먼저 할지.
2. **구현 형태**: 상태를 YAML/JSON front-matter로 두고 `status.md`를 **생성물**로 뽑을지 vs 사람이 손유지하되 규율만 조일지.
3. **트랙 모델**: emotion/mypage 같은 별도 트랙을 진행판이 정식 모델링하게 스키마 확장할지.

## 우선순위 로드맵 (codex 합의 — "notes 분리만 먼저"는 반대)

```
0 · 데드락 해소 (직렬 원칙 재정의 — 지금 규칙상 라우터는 항상 정지해야 함: SKILL:126 vs status:41)
1 · 상태 스키마 + validator + 순수 route()  (track_id·scope_revision·parent_track / unknown 정식상태 / next는 계산)
2 · 진행판 migration/audit  (모순 자동검출→사람 해소 · 산출물로 PASS·승인·streak 추정 금지)
3 · append-only 증거를 커밋가능 구조데이터로  (status.md·rollup은 생성물 · 긴 notes는 링크+reason code)
── 여기까지 제어면 안정화 후 ──
4 · P1b 스펙 오케스트레이션 배선 · 컨벤션→강제 승격
```

## 확진된 즉시 수정거리 (근거는 review.md 표 참조)

- **표 스키마 파손**: `status.md`의 contract-resync 행이 비이스케이프 `|`로 14열→19열 깨짐.
- **데드락**: "in-flight ≥2면 정지" 규칙 vs "9기능 전부 in-flight" 현실.
- **로스터 드리프트**: 문서 "열하나" vs 실제 18개(신규 7).
- **단일 gate가 증거 파괴** / **완료판정이 전체경로 미증명** / **`?`·`—`·`⏸` 스키마 밖 값** / **SSOT 의미론 충돌**(원문 §1.5 P1-logic/P1-ui vs 라우터 단일 P1 yes/no).

## 작업 규율

- **이 워크트리에서만**. git checkout/switch로 브랜치 바꾸지 말 것. 다른 워크트리 건드리지 말 것.
- 커밋/푸시는 사용자 요청 시에만.
- 스킬 md만 바꾸면 dart 게이트는 무관하지만, 혹시 dart/lint를 건드리면 `dart format . && flutter analyze && dart run custom_lint && flutter test` 초록 확인.
- 큰 설계 결정은 codex와 상의(`codex exec --sandbox read-only ...`).
- 한국어 산출물은 `humanize-korean`으로 AI 티 자가검열.

## 이 작업 자체는 7-Phase 루프 대상이 아님

이건 설정 **기능** 개발이 아니라 **하네스(스킬) 자체**를 고치는 메타 작업이다. `develop-looping-process` 루프를 이 작업에 적용하지 말 것 — 위 로드맵대로 직접 진행한다.
