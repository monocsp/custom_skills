---
name: feature-gap-fix
description: "Phase 6 — Phase 5(scenario-audit)가 이미 찾아둔 시나리오 GAP·NEEDS_SIM 을 실제로 닫는 단계다(갭을 새로 찾는 게 아니라 고치는 쪽 — 찾기·판정은 feature-scenario-audit): 루트 원인으로 묶어 고치고, 버그마다 회귀 테스트로 경로를 잠그고, NEEDS_SIM 은 위젯/상태주입 테스트로 HANDLED·INTENDED·GAP 재분류한 뒤, 적대 재검증 다수결로 닫힘을 확인한다. 트리거 — '이 기능 갭 고쳐줘', 'GAP 수정', 'scenario-gaps 닫아줘', 'needs_sim 확정해 닫기', '회귀 테스트 붙여 갭 닫기', 'Phase 6' 라고만 해도(기능명 안 대도) 이 스킬을 쓴다."
---

# /feature-gap-fix — GAP 루트원인 수정 + 회귀 테스트 + 적대 재검증(닫힘 확인)

> 정책: 이 스킬이 도는 동안 git 상태 변경 금지 — checkout/switch/branch/commit/stash/push 안 한다. 작업 브랜치 feat/settings 유지.
> 정책: 범위는 부탁받은 기능·이 Phase 만. 새 디바이스·도구·능동 확장 전 보고 후 멈춘다.
> 정책: 자기 작업을 자기가 "됐다" 판정 금지 — 검증은 독립 격리 에이전트 ≥3 다수결(codex 는 보너스, 자평 금지).

## 언제

- Phase 5(`/feature-scenario-audit`)가 `scenario-gaps.md` 에 이 기능의 GAP(실결함) **또는 NEEDS_SIM**(코드만으론 확정 못 한 잠재 결함)을 남겼고, 그걸 닫으라고 지시받았을 때.
- 입력 = 대상 기능 이름 + `scenario-gaps.md` 의 GAP 행(HIGH 우선) **+ NEEDS_SIM 목록**. INTENDED·HANDLED 는 대상 아님. **NEEDS_SIM 은 대상이다** — 위젯/상태주입 테스트로 실제 동작을 확정해 HANDLED(회귀 테스트로 잠금)/INTENDED/GAP 중 하나로 재분류한다(불확실을 그대로 두고 완료하지 않는다).
- 마스터 프로세스 = `docs/renew-guide/impl/settings/development-process.md` §8(Phase 6). 실행 세부 = `docs/renew-guide/impl/settings/scenario-gaps-fix-plan.md`.

## 선행 조건 (들어오기 전)

`docs/renew-guide/impl/settings/develop-looping-process-status.md` 에서 이 기능 행을 읽는다.
- 직전 Phase(P5 = `feature-scenario-audit`) 셀이 ✅ 여야 진입. 아니면 멈추고 "P5 미완 — 먼저 /feature-scenario-audit" 로 알린다.
- **`open_gaps` 와 `needs_sim` 둘 다 0 이면** 닫을 게 없다 — 멈추고 **P6=`N/A`**(실행 안 함, 건너뜀)로 두고 next 로 넘긴다(라우터·P5 도 갭 없으면 P6=`N/A` 로 본다 — ✅ 로 표시하지 않는다). 둘 중 하나라도 >0 이면 이 스킬이 그걸 닫고, 다 닫은 뒤에만 P6=✅.
- **직렬 preflight.** 다른 기능이 in-flight(✅ 셀 있고 미완)면 멈추고 그 기능을 먼저 끝내라고 보고한다.
- 상태판이 없으면 오케스트레이터 `/develop-looping-process` 가 아직 안 돈 것 — 멈추고 알린다(여기서 만들지 않는다).

## 절차 (순서 고정)

development-process.md §8 + scenario-gaps-fix-plan.md §2~§3 을 그대로 따른다.

1. **묶기(루트 원인).** `scenario-gaps.md` 의 GAP 을 증상이 아니라 루트 원인으로 군집한다. 같은 원인이 여러 기능에 반복되면(예: 로딩 중 pop, resume 미갱신) 화면마다 고치지 말고 공용 헬퍼·믹스인 한 번으로 — `BusyPopGuard`/`ResumeRefreshMixin` 류(fix-plan §3 루트원인표). 이게 §12 메타 루프의 산물이다.
2. **parity 먼저.** 각 묶음에 대해 원본 `/Users/pcs/Documents/GitHub/FmMentalCare/dolomood-app` 을 대조해 fix-plan §1 의 3판정 중 하나를 낸다 — 원본에 있음(=회귀, 이식·우선순위↑) / 원본에도 없음(=신규 강화, 사용자 합의) / 원본 다른 구조(=수단 확인, seam 이면 백엔드 의존 표기). **원본은 읽기만.** 회원탈퇴는 지시상 parity 확인만·수정 보류(fix-plan §1 주).
3. **우선순위 수정.** 데이터 손실·중복·오삭제·크래시가 위, 조용한 실패·정합이 아래. 레이어 경계·에러 계약(`ApiResult`/`DoloError`)·DS-first 를 지키며 최소 변경으로. 큰 변경(전역 위젯·라우팅)은 승인 게이트(fix-plan §2 스테이지2).
4. **회귀 테스트(RED→GREEN).** 버그마다 실패부터 하는 테스트를 붙인다 — 파일 상단 `@Tags(['regression'])`, cubit/위젯 단위로 그 경로를 재현. 먼저 빨간지 확인하고(현 코드에서 fail) 고쳐서 초록. 파괴적 경로(탈퇴 제출)는 실행 대신 상태주입 테스트로.
5. **적대 재검증(§1b).** Phase 5 동형(`/feature-scenario-audit`)을 이 기능에 재실행 — 아래 "적대 서브에이전트" 프롬프트로 격리 검증자 ≥3(codex 는 보너스)을 스폰해 각 GAP·NEEDS_SIM 을 재판정. **닫힘 = 재판정이 GAP→HANDLED 로 뒤집히고 그 경로를 회귀 테스트가 잠근** 순간. 수렴 = 새 GAP 발견 없는 라운드 2연속. 잔존이면 3~4 로 되돌린다. **같은 갭이 3회 안 닫히면 자동반복 멈추고 사람에게**(스펙·하네스 문제일 수 있다).
6. **메타 루프(§12).** 닫은 각 결함마다 묻는다 — *이걸 하네스(lint·템플릿·게이트·스킬)가 막을 수 있었나?* 가능하면 추가해 다음 기능엔 자동 차단(컨벤션→강제 승격; §12 표의 빈 칸이 백로그). 공용 믹스인/헬퍼도 여기 산물 — 만들었으면 재발까지 막을 lint 를 제안한다.
7. **게이트.** `dart format . && flutter analyze && dart run custom_lint && flutter test` 초록. analyze 와 custom_lint 는 별개 단계. 모델 변경 시 `dart run build_runner build --delete-conflicting-outputs`.
8. **한국어 산출물 자가검열.** `scenario-gaps-fix-plan.md`·`scenario-gaps.md` 갱신 문구는 `/humanize-korean` 으로 AI 티(번역투·상투구·과한 불릿) 제거.

## 산출물 / 핸드오프

- 수정 코드 = `lib/feature/<feature>/` (+ 공용화 시 `lib/core/**` 믹스인/헬퍼).
- 회귀 테스트 = `test/feature/<feature>/**_test.dart` (`@Tags(['regression'])`).
- 갭 상태 갱신 = `docs/renew-guide/impl/settings/scenario-gaps.md`(해당 행 GAP→HANDLED + 재검증 근거 파일:라인) · 수정 기록 = `docs/renew-guide/impl/settings/scenario-gaps-fix-plan.md`.
- 메타 루프 산물(있으면) = 새 lint 규칙/템플릿 제안 또는 §12 표 갱신.

**상태판 갱신** — `docs/renew-guide/impl/settings/develop-looping-process-status.md` 의 이 기능 행에서:
- `open_gaps` → 재검증 후 잔존 GAP 수. `needs_sim` → 재검증 후 잔존 NEEDS_SIM 수(테스트로 확정한 만큼 감소).
- `gate` → `GREEN`(4단계 통과).
- `P6` 셀 → **✅ 는 `open_gaps`=0 **그리고** `needs_sim`=0 일 때만**(GAP·NEEDS_SIM 이 남았는데 ✅ 로 표시하지 않는다 — 완료 판정이 오염된다). 잔존이면 `P6`=🔄.
- `next` → **`open_gaps`=0 · `needs_sim`=0(모든 GAP 이 HANDLED + 회귀 테스트로 잠기고 NEEDS_SIM 확정)일 때**: 다음 기능이 남았으면 `feature-plan`, 이 기능이 마지막이면 `pr`. 아직 잔존이면 `next`=`feature-gap-fix`(재진입, 같은 갭 3회 초과 시 `사람 확인` 에스컬레이션).

`/develop-looping-process` 는 이 표만 읽어 다음 스킬로 라우팅한다.

## 강제 / 금지 (가드)

- **회귀 테스트 없이 GAP 닫힘 선언 금지.** 그 경로를 잠그는 실패-우선 테스트(RED→GREEN)가 초록이어야 종료. 테스트 없이 "고쳤다"는 미종료.
- **자평으로 닫힘 판정 금지.** 닫힘은 오직 적대 재검증 다수결로(§1b 정족수). 자기 수정의 검증자에 자신 불포함.
- **게이트 초록 유지.** format·analyze·custom_lint·test 별개 4단계 전부 green. red 로 넘기지 않는다.
- **원본은 읽기만.** parity 대조 중 `dolomood-app` 을 수정하지 않는다. 회원탈퇴는 parity 확인만·수정 보류.
- **파괴적 액션 실행 금지.** 탈퇴 최종 제출 등은 sim/MCP 로 누르지 않고 상태주입·위젯/cubit 테스트로 대체.
- **에스컬레이션.** 같은 갭 3회 안 닫히면 자동반복 멈추고 사람에게 — 스펙·하네스 결함 가능성.
- **git 상태·브랜치 불변**(블록쿼트 정책). 커밋/푸시는 요청 시에만.

## 적대 서브에이전트

메인 에이전트가 **Agent 툴**로 **선언형 공유 검증자 `isolated-adversarial-verifier`(subagent_type) ≥3** 을 병렬 스폰하고, codex 를 **보너스 검증자(4번째)** 로 붙여 교차한다. 그 에이전트 파일(`.claude/agents/isolated-adversarial-verifier.md`)엔 **불변 행동만**(격리·자평금지·불확실=결함·file:line 근거·읽기전용) 담기고, **이 Phase 의 재판정 기준(HANDLED/GAP/INTENDED/NEEDS_SIM·회귀 테스트 잠금 확인)과 출력 표는 아래 task 프롬프트로** 넘긴다 — 그건 이 스킬이 소유한다. codex 는 hang 등으로 빠질 수 있으니 정족수 3 을 채우는 표로 세지 않는다 — 격리 에이전트만으로 ≥3. 각자 서로의 결과를 못 본다.

```
너는 <feature> 기능의 시나리오 갭 재검증자다. 방금 이 기능의 GAP 을 닫는 수정이 들어갔다.
자평이 아니다 — 너는 수정을 안 한 독립 검증자다. 관대하게 넘기지 마라.

입력:
- 대상 GAP 목록(파일:라인 + 원래 증상): <scenario-gaps.md 해당 기능 행 붙여넣기>
- 수정 diff / 관련 파일: lib/feature/<feature>/**, 공용 lib/core/** (있으면)
- 회귀 테스트: test/feature/<feature>/**_test.dart

할 일:
1. 각 GAP 마다 코드를 정독해 지금 상태를 재판정한다:
   HANDLED(가드가 실제로 그 경로를 막음) · GAP(아직 샘) · INTENDED(의도된 동작) · NEEDS_SIM(코드만으론 확정 불가).
   근거는 반드시 파일:라인. 추측 금지.
2. 각 HANDLED 에 대해 "회귀 테스트가 정말 그 경로를 재현하고 잠그나"를 확인한다.
   테스트가 다른 경로를 짚거나 assert 가 약하면 그 갭은 HANDLED 아님(GAP 로 되돌린다).
3. 이번 수정이 만든 새 결함(리그레션·레이어 경계 위반·DS 재발명·에러계약 깨짐)을 찾는다.
4. 강제종료 타이밍·백그라운드 전환·딥링크·재진입·동시성 엣지가 여전히 새는지 본다.

출력(구조화):
- 표: GAP id | 재판정 | 근거 파일:라인 | 회귀테스트가 잠갔나(Y/N) | 한줄 사유
- 새로 발견한 결함(있으면) 별도 목록.
동수·불확실은 GAP(결함)으로 기본값 처리하라. jsonl 원문 붙여넣기 금지 — 위 표/요약만.
```

**다수결(§1b).** 독립 격리 검증자 **≥3** 다수결(codex 는 보너스 4번째, 정족수 3 을 채우는 표로 세지 않음). 동수·불확실은 **결함(GAP 잔존)** 기본값 — 놓치는 쪽보다 과검출이 안전. 한 검증자만 짚은 항목은 재확인 대상(대개 진짜 결함). **닫힘 = 대상 GAP·NEEDS_SIM 전부 HANDLED + 회귀 테스트 잠금 확인 + 새 발견 없는 라운드 2연속.** 그 순간만 종료, 아니면 절차 3~5 반복(3회 상한 → 에스컬레이션).
