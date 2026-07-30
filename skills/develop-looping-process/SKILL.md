---
name: develop-looping-process
description: "설정 기능 하나를 '계획→구현→시각검증→QA→시나리오점검→갭수정→PR' 7단계로 처음부터 끝까지 굴려주는 개발 진행 담당(오케스트레이터). 각 단계를 직접 하는 게 아니라, 진행판(develop-looping-process-state.json — scripts/dlp.py 도구가 읽음)을 근거로 '이 기능이 지금 몇 단계까지 왔는지' 를 판정한 뒤 다음 단계 스킬을 대신 불러주고, 순서·사람 승인·게이트 초록·수렴(2연속 통과)만 지킨다. 한마디로 '이 기능 어디까지 됐고 다음에 뭘 하면 되지?' 를 대신 판단해 다음 작업으로 넘겨주는 스킬. 단계를 콕 집지 않고 '알아서 다음으로 진행해줘' 류면 이걸 쓴다. 트리거 — '[Figma 기획서/링크]를 주며 이거 개발할거야/이거 만들자/이 화면 개발'(**새 기능 킥오프** — 진행판에 올리고 P1 figma-sync 실측부터 시작), '다음 뭐 해야 해', '이 기능 다음 단계/스텝', '지금 어느 단계야', '설정 개발 어디까지 됐어', '이 기능 프로세스대로 계속 진행', 'develop-looping-process 돌려'/'개발 루프 돌려', '진행판 보고 다음 알려줘'. 다만 '계획 짜줘'(feature-plan)·'구현해줘'(feature-implement)·'QA 리뷰'(feature-runtime-qa)·'갭 고쳐'(feature-gap-fix)처럼 특정 단계를 딱 지정하면 그 스킬로 바로 간다. 그리고 루프를 다 돌면(또는 '몇 사이클 돌았어'·'사이클 보고해줘'·'루프 요약' 요청 시) 기능마다 몇 바퀴를 돌았고 사이클마다 몇 개 발견·해결·잔여였는지 원장을 읽어 표로 최종 보고한다."
---

# /develop-looping-process — 기능 하나를 7단계 개발 루프로 끝까지 굴리는 진행 담당(라우터)

> 정책: 이 스킬이 도는 동안 git 상태 변경 금지 — checkout/switch/branch/commit/stash/push 안 한다. 작업 브랜치 유지.
> 정책: 범위는 부탁받은 기능·Phase 만. 새 디바이스·도구·능동 확장 전 보고 후 멈춘다.
> 정책: 자기 작업을 자기가 "됐다" 판정 금지 — 검증은 격리 에이전트 2~3 + codex 다수결(자평 금지).

## 무엇 — 역할 한정

이 스킬은 **라우터**다. 각 Phase 가 "무엇을 어떻게" 하는지는 아래 Phase 스킬이 이미 갖고 있다.
여기서는 **지금 어느 Phase 인지 판정 → 다음 스킬 호출 → 게이트·핸드오프·수렴만 강제**한다.
절대 각 Phase 절차를 이 파일에 복붙하지 않는다(재발명 금지). 프로세스 원문 = `docs/renew-guide/impl/settings/development-process.md`.

> **2026-07-24 — "검증 가능한 상태 머신"으로 승격.** 이 라우터는 이제 **손상 가능한 마크다운 표를 읽어 해석하지 않는다.** 상태는 기계가독 `develop-looping-process-state.json`(SSOT)에 있고, **`scripts/dlp.py` 가 순수 함수로 다음 액션을 계산**한다(`dlp route`). 불변식은 validator 가 강제하고(`dlp validate`), `status.md` 는 그 **생성 뷰**다(손편집 금지). 설계 정본 = [`dlp-state-machine-design.md`](../../../docs/renew-guide/impl/settings/dlp-state-machine-design.md) (v2·v3 절이 상위 규정 — v3 이 최신).

## 상태 머신 — SSOT · 도구 · 모델

- **SSOT = `docs/renew-guide/impl/settings/develop-looping-process-state.json`** (커밋 대상, 기계가독). 사람 대면 표 `develop-looping-process-status.md` 는 `dlp render` 로 뽑는 **생성물** — 직접 고치지 말고 state 를 뮤테이션한다.
- **도구 = `python3 scripts/dlp.py`** (stdlib only, 앱 dart 게이트와 격리 — `flutter analyze/test` 무관). 서브커맨드: `validate` · `route` · `render[ --check]` · `selftest` · `audit[ --source --out]` + 뮤테이션(`add-track`·`set-phase`·`approve`·`add-evidence`·`set-counts`·`add-cycle`·`set-track-status`·`mark-track-done`·`set-release`·`set-sim`·`set-head`·`add-block`/`resolve-block`·`add-await`/`resolve-await`·`add-deferred`·`add-handoff`·`add-cross-cutting`/`close-cross-cutting`·`set-needs-human`/`clear-needs-human`). 모든 뮤테이션은 kind별 필수필드·불변식을 검증하고 실패 시 거부한다.
- **트랙 모델**: `BRANCH ⊃ TRACK ⊃ REVISION ⊃ {PHASE_RUN · EVIDENCE · CYCLE}`. **직렬 = 한 브랜치에 active 트랙 1개**(브랜치가 다르면 병렬 OK → 데드락 해소). in-flight 를 "pass 있고 미완" 으로 파생하지 않고 **명시 상태**로 둔다: `active`(지금 몲) / `parked`(멈춤) / `done`.
- **완료 = `completion_predicate`**(route·validator 가 공유하는 단일 술어): `승인(logic&ui)` ∧ `P2 GREEN@head` ∧ `P3(streak≥2 또는 skip)` ∧ `P4` ∧ `P5(streak≥2)` ∧ `counts 0/0` ∧ `P6` ∧ `미해소 ⛔BLOCK 없음`. **어느 것도 산출물로 추정하지 않는다** — 증거·카운트가 명시돼야 한다.

## 한 번 도는 법 (dlp 가 판정, 라우터는 실행·기록만)

1. **preflight** — 상태가 성한지 먼저 검사:
   ```bash
   python3 scripts/dlp.py validate && python3 scripts/dlp.py selftest && python3 scripts/dlp.py render --check
   ```
   하나라도 실패하면 멈추고 사람에게 보고한다(상태 불변식 깨짐 / 라우팅 회귀 / 뷰 드리프트 — 뷰는 `dlp render` 로 복구).
2. **다음 액션 계산** — `python3 scripts/dlp.py route`. 브랜치별로 `ACTION(→스킬)` · `STOP` · `DONE` 을 낸다(순수 계산, LLM 해석 아님).
3. **STOP 이면 멈추고 사람에게 보고.** 정지 사유(=사람 결정점) 그대로: 승인 대기 · ⛔BLOCK · 에스컬레이션(round>3) · "active 트랙 미지정"(활성화 결정) · 직렬 위반 · sim UDID 미지정 · branch needs_human. **스스로 승인·강행 금지.** (게이트 RED·미검증 phase 는 STOP 이 아니라 `ACTION(→feature-implement/…)` 으로 루프백한다 — 사람 개입 불필요.)
4. **ACTION 이면 그 스킬을 `Skill` 툴로 호출**한다(route 가 준 스킬·사유대로). P3=`visual-verify`·P7=`pr`·P2 계측=`ga4-instrument`·실측=`figma-sync` 는 기존 스킬 그대로.
5. **스킬이 끝나면 dlp 뮤테이션으로 결과를 기록**한다(`set-phase`·`add-evidence`·`add-cycle`·`set-counts`…). 모든 뮤테이션은 **끝에 자동으로 validate+render** 하니, 상태를 깨는 기록은 거부돼(파일 안 바뀜) 라우팅이 늘 성하다. **P3(`visual-verify`)·P7(`pr`)·종단(`designer-handoff-report`)은 진행판을 모르는(ledger-blind) 스킬이라, 그 전이는 라우터가 소유해 기록**한다(P3 `set-phase … --clean-streak`·preflight FAIL→P2 되돌림·`set-release`·트랙 브랜치 이관은 `add-handoff`).
6. 막힘 없으면 2로 반복하고, 정지점(승인·에스컬레이션·전 기능 완료)에서 멈춘다.

## 강제 게이트 (route 가 STOP 으로 표면화 · validator 가 뮤테이션에서 거부)

- **승인 게이트.** `approved.logic&ui` + 승인 증거(`kind=approval`) 없이는 P2/P3 진입 불가(validator `I-A`). ui 승인은 rois 다이제스트도 요구. `logic_only` 는 P2 로직 절반만 열고 **P3 진입 금지**.
- **게이트 초록.** P2 pass = 양 절반 pass + 최신 P2 gate `GREEN@head`. **코드가 바뀌어 새 P2 gate 가 찍히면 하위 phase(P3~P6) pass 를 자동 무효화**(stale GREEN 차단).
- **기능 단위 직렬 = 브랜치당 active 1개**(`I-B`). 같은 브랜치에서 둘째 트랙을 activate 하려는 뮤테이션은 거부된다. 여러 기능이라도 **브랜치가 다르면 병렬 OK**(예: `feat/settings` 와 `feature/emotion-*`).
- **수렴.** P3·P5 는 **clean_streak≥2**(무발견 2연속)라야 완료로 친다(단발 금지). route 가 강제.
- **에스컬레이션.** 같은 루프 round>3 → route 가 `STOP`(사람에게 — 스펙·하네스 문제 가능).
- **⛔BLOCK(명시 요청 이견).** 사용자 리터럴 요청과 판단이 충돌하면 `dlp add-block`(하드) → route `STOP`. `resolve-block` 전엔 그 트랙 done 불가(명시 요청을 "이미 정상" 으로 강등·은폐 금지 — AGENTS.md Explicit request contract). 외부 대기(BE·디자이너)는 `add-await`(소프트, 비차단)로 구분한다.
- **파괴적 액션 금지.** 회원탈퇴 최종 제출은 sim/MCP 에서 누르지 않는다 — 위젯/cubit 테스트로만.

## 새 기능 킥오프 — Figma 기획서로 시작

사용자가 Figma 기획서(링크/node-id)를 주며 "이거 개발할거야"·"이거 만들자" 라고 하면 새 기능 7-Phase 루프 시작 신호다. 바로 코드부터 짜지 않는다:

1. **기능 식별·명명**(모호하면 1줄 되묻기), snake_case feature 명 확정.
2. **트랙 추가** — `dlp add-track <id> --feature <f> --title <t> --branch <b>` (phases 전부 `unknown`·`status:parked` 골격을 만들고 자동 validate). 그다음 `dlp set-track-status <id> active`(그 브랜치에 다른 active 트랙 있으면 뮤테이션이 거부 → "먼저 그거 끝내라" 보고).
3. **P1 으로** — `dlp route` 가 `feature-plan` 을 낸다. 그 Figma URL/node-id 를 함께 넘겨 P1a(`figma-sync extract_doc` 실측)부터: **P1a figma-sync → P1b 스펙 → ⛔사람 승인(`dlp approve`) → P2 → …**. (P1b 4단계 팬아웃은 설계·미배선 — `feature-plan` §1.1~1.4 순차 대행. 상세 `spec-orchestration.md`.)

## 사이클·증거·핸드오프 — 이제 커밋되는 state.json 안에 (구 gitignored 원장 폐기)

라운드마다 발견/해결/잔여는 `dlp add-cycle`, 게이트/리뷰/라이브E2E/회귀/승인/머지 증거는 `dlp add-evidence`(kind별 필수필드) 로 **커밋 대상 state.json** 에 append 된다(설계 §R12). gitignore 로 잃던 실행 이력이 감사·핸드오프 가능해졌다. 종단/요청 시 `dlp render` 가 사이클 롤업·라운드별 상세를 뷰로 뽑는다. 사람이 "몇 사이클 돌았어"·"루프 요약" 을 물으면 state.json 의 `cycles`/`evidence` 를 읽어 표로 보고한다.

## 재사용 스킬 로스터

- 새 Phase 스킬: `feature-plan`(P1) · `feature-implement`(P2) · `feature-runtime-qa`(P4) · `feature-scenario-audit`(P5) · `feature-gap-fix`(P6).
- 종단(전 기능 완료 후): `designer-handoff-report`(완성 화면 SE·16Pro·Figma 3열 리포트 — 판정 아님).
- 기존 스킬(그대로 호출): `visual-verify`(P3) · `pr`(P7) · `ga4-instrument`(P2 계측) · `figma-sync`(실측) · `humanize-korean`(한국어 산출물 자가검열).
- `.claude/agents/` 선언형 검증자 둘: `isolated-adversarial-verifier`(읽기전용, P5·P6) · `runtime-qa-verifier`(sim/MCP, Edit/Write 차단, P4). 없는 스킬은 부르지 않는다.

## 진행판 초기화 / 마이그레이션

state.json 이 없거나 구 마크다운 표에서 옮겨야 하면 **`python3 scripts/dlp.py audit`** 로 구 `status.md` 의 모순(순서 역행·다중 wip·counts null·셀/프로즈 불일치·파손행)을 자동 검출한다 → 리포트는 `develop-looping-process-migration-report.md`. **추정 금지** — 모호·모순은 `unknown`/needs_human 으로 표면화하고, 사람이 state.json 을 저작(활성화·counts 확정·리비전 manifest 결정)한다. 어떤 트랙도 산출물만 보고 `done` 으로 자동확정하지 않는다. 거대/파손 셀 raw 는 `dlp-notes/` 에 보존된다.
