---
name: feature-runtime-qa
description: "Phase 4 — 구현 끝난 기능을 실빌드 sim(MCP)에 올려 코드리뷰(레이어·에러계약·DS·계측)+QA checklist+QA 시나리오 런타임을 한 단계에서 격리 다수결로 적대 검증한다. Figma 픽셀대조(visual-verify·Phase 3)도, 코드정독 엣지감사(feature-scenario-audit·Phase 5)도, 순수 diff 버그헌팅도 아닌 '실행 검증'이 이 스킬만의 지점이다. 트리거 — 'QA 리뷰', '코드리뷰+시뮬 검증', '실빌드로 체크리스트/시나리오 돌려줘', '구현 끝났으니 QA 검증 단계 진행', 'marionette 로 런타임 확인', 'Phase 4'. '리뷰'라는 말을 안 붙여도 구현 완료 기능을 sim 으로 실행 검증하려 하거나 develop-looping-process 가 P4 로 라우팅하면 이 스킬을 쓴다."
---

# /feature-runtime-qa — 코드·DS·계측 리뷰 + QA checklist/시나리오 런타임 적대 검증 (Phase 4)

> 정책: 이 스킬이 도는 동안 git 상태 변경 금지 — checkout/switch/branch/commit/stash/push 안 한다. 작업 브랜치 feat/settings 유지.
> 정책: 범위는 부탁받은 기능·이 Phase 만. 새 디바이스·도구·능동 확장 전 보고 후 멈춘다.
> 정책: 자기 작업을 자기가 "됐다" 판정 금지 — 검증은 독립 격리 에이전트 ≥3 다수결(codex 는 보너스, 자평 금지).

## 언제

- Phase 2(feature-implement) 로 구현이 끝난 기능을 실제로 빌드해 검증할 때.
- develop-looping-process 가 진행판을 읽어 P4 로 라우팅했을 때. 단독 호출도 가능하되 선행 조건을 먼저 본다.
- 입력: 대상 기능명. 근거 = `ai_specs/<feature>.md`(승인된 State/Cubit API), 1.4 QA checklist/시나리오(feature-plan 산출), `docs/renew-guide/impl/settings/scenario-matrix.md`(시나리오 형식).

## 선행 조건 (들어오기 전)

1. `docs/renew-guide/impl/settings/develop-looping-process-status.md` 에서 이 기능 행을 읽는다.
2. **P2(feature-implement) 셀 ✅ + `gate`=GREEN, 그리고 P3(visual-verify) 셀 ✅ 여야** 들어온다. Phase 3(visual-verify)을 건너뛰고 오면 안 된다(§5→§6 순서). P2 진입 자체가 `approved=yes`(Phase 1 스펙 승인) 전제였다.
2b. **직렬 preflight.** 다른 기능이 in-flight(✅ 셀 있고 미완)면 멈추고 그 기능을 먼저 끝내라고 보고한다.
3. **visual-verify 는 기존 스킬이라 진행판을 스스로 갱신하지 않는다** — Phase 3 를 태운 뒤 P3=✅ 를 기록하는 건 오케스트레이터 `develop-looping-process`(또는 visual-verify 를 돌린 사람)의 몫이다. 단독 호출인데 P3 셀이 비어 있고 visual-verify 를 실제로 돌린 흔적(캡처·diff md)이 있으면 P3=✅ 로 보정하고 진행하되, 흔적이 없으면 멈추고 "visual-verify(Phase 3) 먼저" 라고 알린다.
4. 어느 조건이든 미충족이면 멈추고 알린다: "P4 는 P2✅+`gate`=GREEN + P3✅ 후. 현재 P2=<상태>, gate=<값>, P3=<상태> — 빠진 Phase 먼저." 진행판에 행이 없으면 develop-looping-process 로 초기화하라고 알린다.

## 절차 (순서 고정)

먼저 READ: `docs/renew-guide/impl/settings/development-process.md` §6(Phase 4) · `AGENTS.md`(Architecture invariants · Error contract · Do NOT/DS-first) · `.claude/skills/visual-verify/SKILL.md`(적대·다수결·MCP 사용 패턴 템플릿). Skim: `scenario-matrix.md` 상단(시나리오 형식) · `docs/renew-guide/impl/settings/sim-verify-6screens.md`(제외 기준).

development-process.md §6 대로 셋을 **한 단계에서** 적대 검증한다.

### 6.1 코드 리뷰 (격리 에이전트 + codex 적대)

대상 = 이 기능 diff. 아래 세 축을 **각 검증자가 모두** 본다(축을 쪼개 한 명에게 하나씩 나눠 주지 않는다 — 나눠 주면 항목별 검증자가 1명뿐이라 §1b 의 "항목별 ≥3 다수결"이 성립하지 않는다).

- (a) **레이어 경계·에러 계약** — `ui` 가 cubit state 만 보는지(repository/provider/apimanager import 없음), 각 층이 한 단계 아래만 호출, `DioException→DoloError` 가 ApiManager 에만, repository 가 `ApiResult<T>` 로 래핑, cubit 재진입 가드·실패 시 이전 데이터 보존.
- (b) **UI 의 design system 준수** — raw 색/타이포/치수 없이 토큰만(`context.appColors`/`context.typography`), 프리미티브가 DS 컴포넌트로 구현되고 재발명 없음(`SnackBar`→`DoloToast`/`Switch`→`DoloToggle`/`AlertDialog`→`DoloAlertDialog` 등, `docs/design_system/component_registry.json` 대조), 자산 `Assets.*`/`AppIcons.*`, `ui/` 치수 `flutter_screenutil`(`.w/.h/.sp/.r`).
- (c) **계측 격리·네이밍** — `firebase_analytics` import 가 `lib/core/telemetry/` 밖에 없는지, cubit 이 `AnalyticsService.track` 만, `qa_<feature>_<action>` 키·i18n 키 규칙(`error.*`/`<feature>.*`/`common.*`), 새 `GoRoute` 에 `name:`.

### 6.2 QA checklist 실행

1.4 checklist(feature-plan 산출)를 **실제 빌드한 sim** 에서 한 줄씩 조작해 통과/실패를 기록한다. 항목마다 조작→관찰→판정을 남긴다. 통과/실패만 적고 추정 금지.

### 6.3 QA 시나리오 런타임 (MCP 실빌드)

1.4 시나리오대로 실제 빌드해 동작을 확인한다. 도구는 성격에 맞게 고른다.

- **ios-simulator MCP** — 좌표 탭·스와이프·스크린샷·요소조회 = 블랙박스 관찰.
- **dart MCP** — `flutter run`/hot_reload/위젯트리·런타임에러·로그 = 내부 관찰·테스트 구동.
- **marionette MCP** — `ValueKey`(`qa_*`)·텍스트로 직접 탭·입력·스크롤·핫리로드 = 결정적 조작(가장 선호).
- **강제종료·백그라운드 lifecycle** — `simctl`(terminate/launch, Device→Home). MCP 로 흉내내지 말 것.

### 판정

격리 **≥3** + codex(보너스) **다수결**(§1b, 아래 인용). codex 는 hang 등으로 빠질 수 있으니 정족수 3 을 채우는 표로 세지 않는다 — 격리 에이전트만으로 ≥3 이어야 한다. 한쪽만 짚은 항목은 재확인 — 대개 진짜 결함이다. PASS 면 Phase 5 로. 실패면 결함을 고친 뒤 **6.1 부터 다시**(6.3 만 재실행 금지 — 코드가 바뀌었으니 경계 재검).

### 수렴/정족수 (development-process.md §1b)

- 정족수 = 독립 검증자 **≥3 다수결**, 동수·불확실은 **"결함" 기본값**. 자기 작업 검증자에 자신 불포함.
- 수렴 = 새 발견 없는 라운드 **2연속**. 단발 1회로 "깨끗" 선언 금지.
- 에스컬레이션 = 같은 결함이 **한 루프 3회** 안 닫히면 자동반복 멈추고 사람에게(스펙·하네스 문제일 수 있음).

## 산출물 / 핸드오프

- QA 리뷰 결과(리뷰 지적·checklist 통과표·시나리오 판정)는 **대상 기능 문서의 고정 섹션 `impl/settings/<feature>.md` §QA-P4 에 append** 한다(이게 §10 산출물 지도가 요구하는 "검증 기록 md" — 내구성 있는 위치). 새 독립 report 파일을 남발하지 않되, 기록은 반드시 이 섹션에 남긴다(채팅 보고만으로 끝내지 않는다).
- **메타 루프(§12) 기록.** 잡은 결함마다 `harness_feedback: none|lint|template|gate|skill` 한 줄을 §QA-P4 에 남긴다(하네스가 막을 수 있었나). 누락 시 handoff 하지 않는다.
- 한국어 산출물(문서 append·보고)은 내보내기 전 `/humanize-korean` 으로 자가검열.
- **진행판 갱신**(`docs/renew-guide/impl/settings/develop-looping-process-status.md`): 이 기능 행에서
  - `P4` 셀 → `✅` **오직 열린 리뷰 지적이 0(전부 수정 완료)일 때만**. 미해결이 남으면 `🔄` 로 두고 6.1 부터 재검(PASS = 완전 수정). 되돌리지 말고 상태 그대로 두고 보고.
  - `gate` → 이번 빌드/게이트 결과(`GREEN`/`RED`).
  - **`open_gaps`·`needs_sim` 은 건드리지 않는다** — 이 두 컬럼은 Phase 5(feature-scenario-audit) 전용이다. P4 잔여를 여기 적으면 P5 가 덮어써 사라진다.
  - `next` → **`feature-scenario-audit`** (Phase 5).

## 강제 / 금지 (가드)

- **자평 금지** — 검증자에 자신을 넣지 않는다. 6.1/6.2/6.3 판정은 전부 격리 에이전트 + codex 다수결.
- **파괴적 시나리오는 sim/MCP 에서 실행 금지** — 회원탈퇴 최종 제출 등 되돌릴 수 없는 액션은 런타임으로 태우지 말고 **위젯/cubit 테스트로 대체** 검증. 최종 제출 직전까지만 sim 으로 확인.
- **webview 화면**(의견·문의 외부 링크 등)은 Figma 정합·DS 대조 **대상 아님** — 진입/이탈만 확인.
- **제외 기준 분리**(`docs/renew-guide/impl/settings/sim-verify-6screens.md`): 데이터 차이·환경 차이·의도된 staging 차이는 결함이 아니다. 결함(코드/DS/계약 위반)과 섞지 말고 별도로 표기. **단 사용자 명시 요청 미반영은 이 제외 버킷에 넣을 수 없다** — 결함(High)으로 남기고 ⛔BLOCK 으로 사용자에게 올린다(AGENTS.md Explicit user request contract). 현재 턴/기능의 명시 요청 목록(fix-requests 불릿)을 checklist 실행 전 만들어 각 항목을 실제 빌드에서 PASS/FAIL 판정하고, 하나라도 FAIL 이면 완료 금지.
- git 상태 불변(브랜치 `feat/settings`). 코드 수정은 6.x 실패 시 최소로만 하고, 커밋은 하지 않는다(커밋은 이후 Phase/`/pr`).
- 계측 신규/변경이 필요하면 직접 심지 말고 `/ga4-instrument` 로. Figma 실측이 필요하면 `/figma-sync`.
- **메타 루프(§12)**: 결함을 잡으면 코드만 고치고 끝내지 말고 "lint·템플릿·게이트·스킬이 막을 수 있었나" 묻는다. 가능하면 하네스에 추가해 다음 기능엔 자동 차단되게 하고, 그 제안을 보고에 남긴다.

## 적대 서브에이전트

메인 에이전트가 **Agent 툴로** **선언형 `runtime-qa-verifier`(subagent_type) 격리 검증자 ≥3** 을 한 메시지에 병렬 스폰한다(각자 독립 컨텍스트, 서로 결과 안 봄). 각 검증자는 세 축 a/b/c 를 **모두** 본다(축을 나눠 주지 않는다). 이 에이전트는 P5·P6 의 읽기전용 `isolated-adversarial-verifier` 와 달리 **sim/MCP 로 실빌드를 구동**한다(Edit/Write 차단 — 코드 안 고침, 드라이버 툴은 ToolSearch 로 로드). 그 에이전트 파일(`.claude/agents/runtime-qa-verifier.md`)엔 **불변 행동 + 런타임 구동 능력만** 담기고, **세 축 기준·1.4 checklist·시나리오·출력 스키마는 아래 task 프롬프트로** 넘긴다 — 그건 이 스킬이 소유한다. codex 는 **보너스 검증자(4번째)** 로만 붙이고 정족수 3 을 채우는 표로 세지 않는다.

검증자 프롬프트(코드블록 그대로 채워서 스폰):

```
너는 dolomood-app-renew 의 격리 QA 검증자다. 대상 기능 = <feature>, 브랜치 feat/settings.
자기 작업이 아니므로 봐주지 말고 결함을 찾는다. 판단 근거는 실제 파일·실제 빌드뿐, 추정 금지.

READ: AGENTS.md(Architecture invariants · Error contract · Do NOT/DS-first),
      docs/renew-guide/impl/settings/development-process.md §6,
      ai_specs/<feature>.md, docs/design_system/component_registry.json,
      대상 기능 diff(lib/feature/<feature>/** + 관련 라우트/모듈).

검증 축 — a·b·c 를 전부 본다(나눠 받지 않는다):
  (a) 레이어 경계·에러계약: ui→cubit state 만, 한 단계 아래만 호출, DioException→DoloError 는 ApiManager 만,
      repository=ApiResult<T> 래핑, cubit 재진입 가드·실패 시 이전 데이터 보존.
  (b) DS 준수: ui 에 raw 색/타이포/치수 없음(토큰만), 프리미티브가 DS 컴포넌트(component_registry)로 구현·재발명 없음,
      자산 Assets.*/AppIcons.*, 치수 screenutil(.w/.h/.sp/.r).
  (c) 계측·네이밍: firebase_analytics 는 core/telemetry 만, cubit 은 AnalyticsService.track 만,
      qa_<feature>_<action>·i18n 키 규칙, 새 GoRoute 에 name:.

실행 검증도 한다(marionette 우선 → ios-simulator → dart MCP):
  1.4 QA checklist/시나리오를 실제 빌드에서 한 줄씩 조작→관찰→판정. 파괴적 시나리오(탈퇴 최종제출 등)는
  실행하지 말고 "위젯/cubit 테스트로 대체 검증 필요"로 표기. webview 화면은 정합 대상 아님.
  데이터/환경/의도된 staging 차이는 결함 아님 — 결함과 분리해 적어라.
  단 **사용자 명시 요청 미반영은 결함(High)** — staging 으로 강등 금지, 별도 필드로 보고(원 요청 목록을 입력으로 받아 항목별 반영 여부 판정).

출력(표): [항목 | 위반규칙(파일:라인) | 재현/근거 | 심각도 High/Med/Low | PASS|FAIL].
확실치 않으면 FAIL 기본값. 다른 검증자 결과는 보지 마라.
```

다수결 규칙:

- 항목별로 검증자 판정을 모아 **≥3 중 다수** 채택. 동수·불확실은 **결함(FAIL)**.
- 한 검증자만 짚은 항목은 버리지 말고 **재확인** — 경험상 진짜 결함인 경우가 많다.
- "깨끗" 선언은 **새 발견 없는 라운드 2연속** 일 때만. 같은 결함 한 루프 3회 미해결이면 사람에게 에스컬레이션.
