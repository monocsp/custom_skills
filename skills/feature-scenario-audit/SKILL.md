---
name: feature-scenario-audit
description: "Phase 5 — 코드 정독으로 엣지 견고성을 판정한다(HANDLED/GAP/INTENDED/NEEDS_SIM). 런타임으로 다 못 도는 엣지(강제종료 타이밍·딥링크·동시성·재진입·백그라운드 복귀 stale)를 기능별 격리 에이전트가 파일:라인 근거로 적대 판정'만' 하고(고치는 건 Phase 6 feature-gap-fix) scenario-gaps.md 에 집계한다. 엣지가 코드로 다 막혔는지 읽어서 확인·감사할 땐 기능명이나 Phase 를 안 적어도 이 스킬을 쓴다 — 시뮬 런타임 시나리오 검증(feature-runtime-qa)이나 갭 수정과 다르다. 트리거 — '시나리오 갭 검증', '엣지 견고성 코드정독', 'scenario audit', 'Phase 5 시나리오 적대검증', '이 기능 엣지 다 처리됐나 코드로 확인', '강제종료·딥링크 엣지 GAP 코드로 잡아줘', '엣지 케이스 코드로 감사해줘'."
---

# /feature-scenario-audit — 코드 정독으로 엣지 견고성 판정(Phase 5)

> 정책: 이 스킬이 도는 동안 git 상태 변경 금지 — checkout/switch/branch/commit/stash/push 안 한다. 작업 브랜치 feat/settings 유지.
> 정책: 범위는 부탁받은 기능·이 Phase 만. 새 디바이스·도구·능동 확장 전 보고 후 멈춘다.
> 정책: 자기 작업을 자기가 "됐다" 판정 금지 — 검증은 독립 격리 에이전트 ≥3 다수결(codex 는 보너스, 자평 금지).

## 언제

설정 9기능 개발 루프에서 한 기능이 **Phase 4(코드리뷰 + 런타임 QA)를 PASS 한 직후**. 인자 = 기능명 하나(`account`·`login-info`·`notification`·`notice`·`app-info`·`feedback`·`inquiry`·`app-lock`·`withdraw`). 런타임으로 전수하기 어려운 엣지 — 강제종료 타이밍·딥링크·동시성·재진입·백그라운드 복귀 — 를 **코드 정독으로** 판정한다. Phase 4 런타임 검증과 상보다(런타임=고신뢰·일부, 정독=광범위·전수). 프로세스 단일 출처 = `docs/renew-guide/impl/settings/development-process.md` §7.

## 선행 조건 (들어오기 전)

진행판 `docs/renew-guide/impl/settings/develop-looping-process-status.md` 에서 이 기능 행을 읽는다.
- **P4 셀이 ✅ 인지 확인.** 아니면 멈추고 "P4(코드리뷰+런타임 QA) 미완 — feature-runtime-qa 먼저" 라고 알린다.
- P4 이전(P1~P3)이 ✅ 인지도 확인. 순서를 건너뛴 흔적이 있으면 멈추고 보고한다.
- **직렬 preflight.** 다른 기능이 in-flight(✅ 셀 있고 미완)면 멈추고 그 기능을 먼저 끝내라고 보고한다.
- 이 기능의 엣지 시나리오 원천이 `scenario-matrix.md`(유저81+엣지145, HIGH17)에 있는지 확인. 없으면 Phase 1(1.4)이 빠진 것 — 멈추고 알린다.

조건 미충족이면 **자동 진행하지 말고** 어느 Phase 로 되돌아가야 하는지만 보고한다.

## 절차 (순서 고정)

development-process.md §7 을 따른다.

1. **대상 엣지 컴파일.** `scenario-matrix.md` 에서 이 기능의 **HIGH-risk 시나리오 + 완전성 비평**(무엇이 빠졌나)을 추린다. 런타임으로 안정 재현 안 되는 것 위주 — 강제종료/콜드스타트·딥링크(`state.extra` null)·동시성·in-flight 이탈·백그라운드 복귀 stale·재인증 세션 정합. Phase 4 에서 이미 런타임으로 확인된 항목은 상보 표시만 남기고 중복 판정하지 않는다.

2. **적대 코드 정독(격리 에이전트 ≥3, 병렬).** 아래 "## 적대 서브에이전트" 프롬프트로 메인이 Agent 툴로 **선언형 공유 검증자 `isolated-adversarial-verifier`**(subagent_type)를 **한 메시지에 3개 동시** 스폰한다. 각자 같은 엣지 목록을 받아 파일을 정독하고 시나리오마다 판정한다:
   - **HANDLED** — 코드/테스트로 처리됨(근거 파일:라인).
   - **GAP** — 실결함(데이터 손실·중복·오삭제·크래시·조용한 실패).
   - **INTENDED** — 의도된 동작(원본 parity·명세대로).
   - **NEEDS_SIM** — 코드만으론 확정 불가 → 위젯테스트/안전한 sim 경로 필요.
   근거는 **반드시 파일:라인**. 추측·"아마" 금지.

3. **다수결·수렴(§1b).** 독립 검증자 ≥3 다수결. **동수·불확실은 GAP 기본값**(놓치는 쪽보다 과검출이 안전). 자기 작업의 검증자에 자신을 넣지 않는다. codex 를 보조 한 표로 붙일 수 있다(있으면 좋고 없어도 합의 성립). **새 발견 없는 라운드가 연속 2회**면 수렴 종료 — **단발 1회로 "깨끗" 판정 금지**(꼬리를 놓친다). 같은 루프를 3회 돌아도 안 닫히면 자동 반복을 멈추고 사람에게 에스컬레이션(스펙·하네스 문제일 수 있음).

4. **집계(scenario-gaps.md).** confirmed 판정을 `docs/renew-guide/impl/settings/scenario-gaps.md` 형식대로 적는다 — §1 기능별 GAP/HANDLED/INTENDED/NEEDS_SIM 카운트, 그리고 GAP 은 기능·시나리오·verdict·file:line·근거로. HIGH 는 상세(§3)로 승격. 여러 기능에 반복되는 GAP 은 §2 루트 원인(교차 패턴, A~H)으로 묶어 다음 Phase 6 의 공용 헬퍼 후보로 남긴다.

5. **메타 루프(§12).** GAP 을 잡을 때마다 *이 결함을 하네스(lint·템플릿·게이트·스킬)가 막을 수 있었나?* 를 묻는다. 막을 수 있었으면 백로그로 적어 다음 기능엔 자동 차단되게 한다(예: in-flight 이탈 가드 부재 → `BusyPopGuard` 믹스인 + lint). 코드만 고치고 끝내지 않는다.

## 산출물 / 핸드오프

- **집계** → `docs/renew-guide/impl/settings/scenario-gaps.md`(기능별 카운트 + GAP 상세 + 루트 원인 + NEEDS_SIM 목록). GAP 판정 근거는 파일:라인.
- **메타 루프(§12) 기록.** 잡은 GAP 마다 `harness_feedback: none|lint|template|gate|skill` 한 줄을 scenario-gaps.md 에 남긴다(하네스가 막을 수 있었나 — §12 표의 빈 칸이 백로그).
- **진행판 갱신** → `docs/renew-guide/impl/settings/develop-looping-process-status.md` 이 기능 행:
  - **P5 셀 → ✅**.
  - **`open_gaps` 컬럼 = confirmed GAP 개수**(INTENDED/HANDLED 미포함). 이 컬럼은 P5 전용이다.
  - **`needs_sim` 컬럼 = NEEDS_SIM 개수.** 별도 병기 아님 — **완료를 막는 blocking count** 다. NEEDS_SIM 은 §1b "불확실은 결함 기본값"에 해당하니, 위젯/상태주입 테스트로 HANDLED/INTENDED/GAP 확정 전엔 이 기능을 완료로 넘기지 않는다.
  - **next 컬럼**:
    - `open_gaps > 0` **또는** `needs_sim > 0` → **feature-gap-fix**(Phase 6). gap-fix 가 GAP 은 고치고 NEEDS_SIM 은 위젯/상태주입 테스트로 확정한다.
    - `open_gaps == 0` **그리고** `needs_sim == 0` → 이 기능 완료(P6=`N/A`). **남은 기능이 있으면** 다음 기능 **feature-plan**, **9기능이 전부 끝났으면** **pr**.
- develop-looping-process 오케스트레이터는 이 표만 읽어 다음 스킬로 라우팅한다.

## 강제 / 금지 (가드)

- **자평 금지.** 내가 짚은 판정은 표 한 칸일 뿐 — confirmed 는 독립 검증자 다수결로만. 자기 작업 검증자에 자신 불포함.
- **동수·불확실 = GAP.** 애매하면 HANDLED 로 올리지 말고 GAP 으로 내린다(과검출이 안전).
- **에이전트 산출 jsonl 직접 tail 금지**(컨텍스트 폭주). 결과는 아래 구조화 스키마·요약으로만 받는다.
- **근거 없는 판정 금지.** 모든 verdict 는 파일:라인. 코드를 안 읽고 매트릭스만 보고 판정하지 않는다.
- **단발 수렴 금지.** "한 번 돌려 깨끗" 은 수렴 아님 — 새 발견 없는 라운드 2연속.
- **git 무변경.** 이 Phase 는 읽기·문서 집계만. 코드 수정은 Phase 6(feature-gap-fix)의 일이다 — 여기서 고치지 않는다.
- **파괴적 시나리오는 실행하지 않는다**(탈퇴 제출 등) — 코드 정독 + 위젯테스트(NEEDS_SIM)로만 본다.
- **없는 스킬·없는 경로 호출 금지.** 실재 스킬은 정의된 것만.

## 적대 서브에이전트

메인이 Agent 툴로 **선언형 공유 검증자 `isolated-adversarial-verifier`(subagent_type) ≥3 을 한 메시지에 병렬** 스폰한다(서로·내 결과 비공개). 그 에이전트 파일(`.claude/agents/isolated-adversarial-verifier.md`)엔 **불변 행동만**(격리·자평금지·불확실=결함·file:line 근거·읽기전용) 담겨 있고, **Phase 고유 판정기준은 아래 task 프롬프트로 넘긴다** — 시나리오 목록·HANDLED/GAP/INTENDED/NEEDS_SIM 스키마·출력 JSON 은 이 스킬이 소유한다(codex 는 보너스 한 표). task 프롬프트의 규칙(근거 file:line·애매하면 GAP 등)은 에이전트 불변식과 겹쳐도 그대로 둬 강조한다.

```
너는 feature-scenario-audit 의 독립 시나리오 검증자다. 대상 기능 = <feature>.
아래 엣지 시나리오 목록(scenario-matrix.md 발췌)을 각각, 코드를 직접 정독해 판정하라.

읽을 코드: lib/feature/<feature>/ 전체(cubit·state·repository·provider·ui·module) +
연관 core(세션/라이프사이클/라우팅) + test/feature/<feature>/. Read/Grep 만 쓴다. 코드·git 무변경.

엣지 목록:
<HIGH-risk + 완전성 비평 시나리오 N개 — 각 id·Given-When-Then>

판정(시나리오마다 하나):
- HANDLED   : 코드/테스트로 처리됨.        근거 file:line 필수.
- GAP       : 실결함(데이터 손실·중복·오삭제·크래시·조용한 실패). 근거 file:line + 실패 경로 서술.
- INTENDED  : 의도된 동작(원본 parity·명세대로). 근거 file:line.
- NEEDS_SIM : 코드만으론 확정 불가 → 위젯테스트/안전한 sim 필요. 왜 불가한지.

규칙: 근거는 반드시 file:line. 추측·"아마"·매트릭스만 보고 판정 금지 — 실제 코드를 읽어라.
애매하면 HANDLED 로 올리지 말고 GAP 으로 내려라(과검출이 안전).
완전성 비평도 하라 — 목록에 없지만 이 코드가 빠뜨린 엣지가 보이면 GAP 으로 추가.

출력은 JSON 배열만:
[{"scenario_id","verdict"(HANDLED|GAP|INTENDED|NEEDS_SIM),
  "evidence"("file:line 요약"),"failure_path"(GAP 이면 입력→잘못된 결과),
  "root_cause_theme"(A~H 중 해당 시, 없으면 null),"severity"(high|med|low|null)}]
같은 점·인사말·서술 산문 금지. JSON 배열 하나만.
```

**다수결 규칙** — 종합자가 검증자 3(+codex 보조)의 JSON 을 시나리오별로 병합·`agree_count` 집계:
- 2명 이상이 같은 verdict → **confirmed**.
- 판정이 갈리면(예: 2 GAP · 1 HANDLED) 다수결, **동수·불확실은 GAP**.
- GAP↔HANDLED 충돌은 보수적으로 GAP 쪽을 채택하고 file:line 을 재대조해 사실 확인.
- 한 명만 짚은 GAP 은 그 file:line 을 직접 열어 사실이면 채택, 아니면 기각(노이즈 한 줄 기록).
- **수렴** = confirmed 세트에 새 항목이 안 붙는 라운드 2연속. 3회 안 닫히면 사람에게 에스컬레이션.

한국어 집계 문서는 `humanize-korean` 으로 AI 티 자가검열(이미 깨끗하면 그대로).
