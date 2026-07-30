# develop-looping-process — 검증 가능한 상태 머신 설계 (정본)

> 작성 2026-07-24. 이 문서는 `develop-looping-process` 스킬을 **"문서로만 존재하는 상태 머신" → "검증 가능한 상태 머신"**으로 승격하는 설계 정본이다. 입력 = `develop-looping-process-review.md`(codex 적대 논의 완료) + KICKOFF. 사용자 결정 3건 동결(아래 §0). codex + 격리 검증자 적대 검토 대상.

---

## 0. 동결된 결정 (사용자, 2026-07-24)

1. **범위** = 완전 승격. codex 로드맵 step 0~3(데드락 해소 → 스키마+validator+순수 route → migration → 증거 이벤트 분리). **step 4(P1b 배선·컨벤션 강제승격)는 이 작업 범위 밖**(제어면 안정 후).
2. **구현 형태** = 구조화 SSOT + validator(도구화). 기계가독 상태파일이 SSOT, validator 가 불변식 강제, `status.md` 는 생성 뷰.
3. **트랙 모델** = 정식 도입. 브랜치·워크트리·재진입을 1급으로. 직렬 원칙 = "브랜치당 in-flight 1개".

## 1. 왜 (한 문장)

지금 라우터는 **손상된 마크다운 표를 LLM 이 자연어로 해석**해 라우팅한다 — 결정적이어야 할 함수가 비결정적이고, 검증 불가능하다. 상태를 기계가독 파일로 옮기고, 라우팅을 **순수 함수 `route(state)` 로 계산**하고, 불변식을 **validator 스크립트로 강제**하면 상태 머신이 검증 가능해진다.

## 2. 기술 선택 (근거)

| 항목 | 선택 | 근거 |
|---|---|---|
| 상태 파일 포맷 | **JSON** (`develop-looping-process-state.json`) | python3 있으나 pyyaml 없음 → YAML 은 파서 취약. JSON=stdlib 무의존. 사람 대면물은 생성된 `status.md` 라 JSON 가독성 약점 무의미. |
| 툴 언어 | **python3 stdlib** (`scripts/dlp.py`) | 앱 dart 게이트와 **격리**(figma-sync python 선례 — "게이트에 안 잡힘"). `flutter analyze`/`custom_lint`/`test` 무관. |
| 쓰기 경로 | **툴 뮤테이션 서브커맨드** | 손편집 JSON 취약 → skill 이 `dlp set-phase`/`dlp add-evidence` 로 안전·원자·재검증. |
| 라우팅 | **`dlp route` 가 계산** | LLM 해석 제거. SKILL.md 는 "툴 돌려 결과 따름". |

**결합 안 함**: `scripts/dlp.py` 는 `lib/`·`test/` 밖이라 `flutter analyze`/`flutter test` 가 안 본다. local_ci 게이트에도 (지금은) 안 넣는다 — 이건 하네스 도구지 앱 코드가 아니다. (후속: `dlp validate` 를 local_ci 에 opt-in 추가는 step 4 이후 판단.)

---

## 3. Step 0 — 트랙 모델 & 데드락 해소

### 3.1 진단 재확인

- 라우터 규칙: **in-flight ≥2 → 멈춤**(`SKILL.md:126`).
- 현실: 진행판 14행(설정 9 + 별도 트랙 5)이 전부 mid-pipeline(P1~P3 pass, 미완) → "has pass but not done" 을 in-flight 로 **파생**하면 14개가 다 in-flight → **라우터는 항상 정지**해야 한다(`status.md:44` 자인).
- 우회: 사람이 손으로 "이거 해" 로 몰아 규칙을 무시 중 → 규칙이 죽음.

### 3.2 뿌리 = 직렬 단위 오정의

직렬(serial)의 목적은 **파일 충돌·검증 맥락 오염 방지**다(`development-process.md:44`). 충돌은 **브랜치/워크트리 단위**에서 일어난다. 다른 브랜치의 작업은 물리적으로 안 부딪힌다. 그런데 규칙은 "표 전체에 1개" 라 브랜치를 모른다.

**해소: 직렬 단위 = 브랜치.** 규칙 = **"한 브랜치에 in-flight(active) 트랙 1개"**. 브랜치가 다르면 병렬 허용. → `feat/settings` 가 account 를 몰고, `feature/emotion-*` 가 감정대화를 독립으로 몰아도 위반 아님.

### 3.3 "in-flight 는 파생 아니라 명시 상태"

핵심 교정: in-flight 를 "pass 있고 미완" 으로 **파생하면 안 된다**(그게 지금 데드락의 기제). 트랙에 **명시 `status`** 를 둔다:

- `active` — 라우터가 지금 이 트랙을 몰고 있음. **브랜치당 최대 1개**(validator 강제).
- `parked` — 진행됐으나 지금 안 몲(예: ad-hoc 으로 P1~P3 만 됨, PR 보류, 타 워크트리 이관).
- `done` — 현재 리비전이 완료 불변식 통과(P1~P6).

serial invariant = `∀ branch: count(tracks where status==active) ≤ 1`. parked/done 은 안 센다. → 데드락 해소.

### 3.4 엔티티 모델 (codex ER 스케치 반영)

```
BRANCH 1─* TRACK 1─* REVISION 1─* PHASE_RUN
                       REVISION 1─* EVIDENCE
                       REVISION 1─* CYCLE
TRACK.parent_track ─> TRACK   (스코프확장 lineage: ai-direct.parent = emotion-conversation)
```

- **BRANCH** — 물리 직렬 단위. `{worktree, sim, release:{status, pr}}`. P7(PR)은 브랜치 릴리스 마일스톤: 그 브랜치의 모든 트랙 done → PR.
- **TRACK** — 한 작업 줄기(≈ 지금 표의 한 행). `{id, feature, title, branch, parent_track, status, current_rev}`. 설정 9기능 = feat/settings 위 9트랙. 감정대화 = 자기 브랜치 1트랙(리비전 V2~V6).
- **REVISION** — 재진입 단위(V2→V6). `{rev, approved, phases, counts, blocks, evidence, cycles, notes_ref}`. 스코프 확장 = 새 리비전.
- **PHASE_RUN** — P1~P7 각각의 상태. `{status, ...phase별 부가}`.
- **EVIDENCE** — append-only 증거(§6).
- **CYCLE** — 라운드별 발견/해결/잔여(§6, 사이클 원장 흡수).

---

## 4. Step 1 — state.json 스키마

```jsonc
{
  "schema_version": 1,
  "meta": {
    "ssot_note": "SSOT. scripts/dlp.py 로만 수정. status.md 는 생성 뷰(손편집 금지).",
    "phases": ["P1","P2","P3","P4","P5","P6","P7"],
    "phase_skill": {"P1":"feature-plan","P2":"feature-implement","P3":"visual-verify",
                    "P4":"feature-runtime-qa","P5":"feature-scenario-audit","P6":"feature-gap-fix","P7":"pr"}
  },
  "branches": {
    "feat/settings": {
      "worktree": "dolomood-app-renew (main)",
      "sim": "iPhone 16 Pro",
      "release": {"status": "pending", "pr": null},     // pending|parked|pr_open|merged
      "needs_human": null                                // or "설명…"
    }
  },
  "tracks": [
    {
      "id": "settings/account",
      "feature": "account",
      "title": "계정",
      "branch": "feat/settings",
      "parent_track": null,
      "status": "parked",                                 // active|parked|done
      "current_rev": "v1",
      "revisions": [
        {
          "rev": "v1",
          "approved": {"logic": true, "ui": true, "by": "사람", "at": "2026-07-16"},
          "phases": {
            "P1": {"status": "pass"},
            "P2": {"status": "pass"},
            "P3": {"status": "pass", "clean_streak": 2, "round": 3},
            "P4": {"status": "unknown"},
            "P5": {"status": "wip"},
            "P6": {"status": "unknown"},
            "P7": {"status": "unknown"}
          },
          "counts": {"open_gaps": null, "needs_sim": null}, // null = unknown (구 '?')
          "blocks": [],                                     // 미해소 ⛔BLOCK 항목 [{id, desc, raised_at}]
          "evidence": [
            {"kind":"gate","phase":"P2","result":"GREEN","commit":"58b6600","command":"flutter test","count":1830,"at":"2026-07-16","path":null}
          ],
          "cycles": [
            {"n":1,"phase":"P3","found":6,"resolved":0,"remaining":6,"note":"첫 대조"}
          ],
          "notes_ref": "docs/renew-guide/impl/settings/dlp-notes/settings-account.md"
        }
      ]
    }
  ]
}
```

### 4.1 enum (스키마 밖 값 금지 — validator 강제)

| 필드 | 합법 값 | 구 표의 무엇 |
|---|---|---|
| `track.status` | `active` `parked` `done` | (없음 — 신규) |
| `branch.release.status` | `pending` `parked` `pr_open` `merged` | P7 셀·`⏸` |
| `phase.status` | `unknown` `wip` `pass` `skip` | `?`→unknown, `⬜`→unknown/queued, `🔄`→wip, `✅`→pass, `N/A`→skip |
| `approved` | `{logic:bool, ui:bool, by, at}` | `no`/`yes`/(logic-only) |
| `counts.*` | 정수 ≥0, 또는 `null`(unknown) | `?`·`—` |
| `evidence.kind` | `gate` `verify` `gap` `approval` `pr` `note` | (구 gate/notes) |

`—`·`⏸`·`?` 같은 스키마 밖 값은 존재 자체가 validator FAIL. `unknown` 이 정식 상태이므로 route 는 이를 처리(총함수).

### 4.2 P1-logic / P1-ui (SSOT 의미론 충돌 해소)

`development-process.md §1.5` 는 P1 을 logic/ui 로 쪼갠다(레이아웃 미확정 시). 구 라우터는 단일 P1 yes/no 라 충돌. → `approved:{logic, ui}` 로 모델. 파생 `approved_state`:
- `logic==false` → `no`
- `logic==true && ui==false` → `logic_only`
- `logic==true && ui==true` → `yes`

route: `logic_only` 는 P2 **로직 절반**만 열고 **P3 진입 금지**(rois.json 없으면 preflight FAIL). ui 승인 후 P3. (마이 트랙 실선례.)

---

## 5. Step 1 — 불변식 (validator) & 순수 route()

### 5.1 validator 불변식 (하나라도 깨지면 비0 종료)

1. **스키마 준수** — 모든 enum·타입·필수필드. 스키마 밖 값 0.
2. **총함수 라우팅** — 모든 리비전 상태가 `route_rev` 에서 정확히 1개 액션으로 매핑(unknown 포함). 매핑 실패 상태 존재 = FAIL.
3. **브랜치 직렬** — `∀ branch: count(active tracks) ≤ 1`.
4. **컬럼 단일소유** — 각 phase/필드는 정의된 소유 Phase 만 기록(§4 소유표). evidence 로 교차검증(gate 는 phase+commit+result 3필드 필수).
5. **완료 전체경로** — `done` 리비전은 **전 경로 증명**: `approved.logic&ui` ∧ `P2=pass&최신 gate=GREEN` ∧ `P3∈{pass(streak≥2),skip}` ∧ `P4=pass` ∧ `P5=pass` ∧ `open_gaps==0` ∧ `needs_sim==0` ∧ `P6∈{pass,skip}` ∧ `blocks==[]`. 하나라도 미충족인데 done = FAIL.
6. **트랙 상태 정합** — `track.status==done` ⟺ current_rev 완료 불변식 통과. `current_rev` 는 실재 rev.
7. **parent_track 참조 무결** — 존재하는 track id.
8. **뷰 동기** — `status.md` 가 `dlp render` 출력과 바이트 일치(골든). 어긋나면 FAIL(손편집·드리프트 탐지).
9. **needs_human 게이트** — `branch.needs_human` 또는 리비전 `blocks` 비어있지 않으면 route 는 그 지점서 STOP(자동 전이 금지).

### 5.2 `route(state) → [{branch, action, reason, stop?}]` (순수·총함수)

브랜치별로 계산(브랜치는 병렬):

```
for branch B:
  if B.needs_human: emit STOP(B, B.needs_human); continue
  active = [t in B.tracks if t.status==active and not done(current_rev(t))]
  if len(active) > 1: emit STOP(B, "직렬 위반: active 트랙 2+"); continue
  if len(active) == 1: emit route_rev(active[0].current_rev); continue
  # active 0
  if all(t.status==done for t in B.tracks):
     if B.release.status==pending: emit ACTION(B, skill=pr, "전 트랙 done → P7")
     elif B.release.status==parked: emit STOP(B, "PR 보류(사용자)")
     elif B.release.status==pr_open: emit STOP(B, "PR 열림 — 머지 대기")
     else: emit DONE(B)
  else:
     # 진행할 트랙 있으나 active 지정 없음
     emit STOP(B, "active 트랙 미지정 — parked 중 하나를 activate 결정 필요")
```

`route_rev(rev)` — 순서 파이프라인, 모든 phase 상태(unknown 포함) 처리:

```
if rev.blocks: return STOP("미해소 ⛔BLOCK")
a = approved_state(rev)
if a == no:   return P1 미완이면 ACTION(feature-plan) else STOP("승인 대기")
if a == logic_only: return ui 미완이면 ACTION(feature-plan, ui) else STOP("P1-ui 승인 대기")
# a == yes
P2 = rev.phases.P2
if P2 in {unknown,wip}: return ACTION(feature-implement)
if P2==pass and latest_gate(rev)!=GREEN: return ACTION(feature-implement, "gate RED 되돌림")
P3 = rev.phases.P3
if P3.preflight_fail: return ACTION(feature-implement, "P3 preflight FAIL→P2")
if P3 in {unknown,wip}: return ACTION(visual-verify, clean_streak 강제)
if P3==pass and streak<2 and not skip: return ACTION(visual-verify, "확인 라운드")
# P3 pass(streak≥2) or skip
P4 = rev.phases.P4
if P4 in {unknown,wip}: return ACTION(feature-runtime-qa)
P5 = rev.phases.P5
if P5 in {unknown,wip}: return ACTION(feature-scenario-audit)
if counts.open_gaps is null or counts.needs_sim is null: return ACTION(feature-scenario-audit, "카운트 미확정→재감사")
if counts.open_gaps>0 or counts.needs_sim>0: return ACTION(feature-gap-fix, escalate if P6 round>3)
if P6 in {unknown} and (P5 새 gap 있었음): return ACTION(feature-gap-fix)
return DONE(rev)   # 완료 불변식 충족
```

**총함수 증명 스케치**: approved 3값 × phase 4상태(unknown/wip/pass/skip) × counts(null/0/>0) 조합이 위 분기로 전부 덮인다. unknown counts → 재감사, unknown phase → 그 phase 실행, blocks → STOP. 매핑 없는 상태 없음. validator 불변식 2가 이를 전 리비전에 대해 재확인.

### 5.3 라우터 소유 전이 유지 (P3/P7 ledger-blind)

`visual-verify`·`pr` 은 진행판을 모른다 → 이 전이는 라우터(SKILL.md)가 `dlp` 뮤테이션으로 기록(구 SKILL.md:63-75 규율 보존): P3 clean_streak 갱신·preflight FAIL 되돌림·P7 release 마커·handoff 마커. 차이 = 이제 **손편집 아니라 `dlp set-phase P3 --clean-streak` 등 검증된 뮤테이션**.

---

## 6. Step 3 — evidence 모델 & 생성물화

### 6.1 gate 를 단일 셀에서 evidence 로

구 `gate` 컬럼 = P2·P4·P6 가 덮어써 **어느 phase·commit·scope 의 GREEN 인지 소실**(review D4). → `evidence[]` append-only. 각 gate = `{kind:gate, phase, result, commit, command, count, at}`. `latest_gate(rev)` = phase 필터 후 최신. **덮어쓰기 없음** → 감사 가능.

### 6.2 사이클 원장 흡수 (문제 #1 해소)

구 `develop-looping-process-cycles.md` = **`.gitignore` 됨(`:139`)·실물 부재** → 실행 이력 비커밋·감사 불가. → `revision.cycles[]` 로 흡수. **state.json 은 커밋 대상**이라 사이클 이력이 감사·핸드오프 가능해진다. 종단 rollup·라운드별 상세 표는 `dlp render` 가 생성. **gitignore 에서 cycles 줄 제거**(더 이상 별도 파일 없음).

### 6.3 status.md 는 생성 뷰

`dlp render` 가 state.json → `status.md`(사람 대면 표) 생성. 헤더에 "⚠ 생성물 — 손편집 금지, state.json 을 dlp 로 수정" 경고. validator 불변식 8 이 뷰 동기 강제(골든). 긴 서사 notes 는 `revision.notes_ref`(별도 md 링크)로 빼고, 표엔 reason code + 링크만.

**notes_ref 파일들**: `docs/renew-guide/impl/settings/dlp-notes/<track-id>.md`. 커밋 대상(핸드오프 서사). state.json 은 짧게 유지.

---

## 7. Step 2 — migration/audit (현 status.md → state.json)

원칙: **추정 금지.** 모호·모순은 `unknown`/`needs_human` 으로 표면화(사람 해소), 조용히 PASS·승인·streak 지어내지 않는다.

### 7.1 14행 + XC-1 매핑

- **설정 9트랙**(account…withdraw, branch feat/settings): P1~P3 = pass(provisional, 산출물 스캔 근거), P4~P7 = unknown/wip. counts = null(구 `?`). **status = parked 전부** + `branch.needs_human = "정식 P4→P7 루프의 active 트랙 미지정 — 하나를 activate 결정 필요"`. (inquiry 는 P4~P6 wip 이라 active 후보 1순위지만 지정은 사람.)
- **emotion-conversation**: 리비전 V2~V6 분해. V6 P3 재오픈·타 워크트리(feature/emotion-conv-timestamp) 이관 → status=parked + needs_human("V6 P3 재오픈·타 브랜치 이관"). 브랜치 feature/emotion-conversation-history.
- **emotion-conversation-ai-direct**: P1~P6 done, PR 보류 → track done, branch release=parked("PR 보류 사용자").
- **mypage-main**: P1~P6 done(P1 logic&ui 승인, P3~P6 커밋 근거), P7=⏸ → track done, branch feat/home-mypage release=parked("PR은 올리지말아봐").
- **emotion-conv-contract-resync**: 슬라이스 다수·P4/P5 wip·⛔B2/B3/B5/B6·GA4 착수 → status=active(자기 브랜치)? 실제 진행 중이나 미결 다수 → status=parked + needs_human(미결 ⛔B* + PR 보류) 가 더 정직. (사람 확인.)
- **bag_view_toggle**: P1~P6 done, next=pr → track done, branch release=pending.
- **XC-1**(공통 에러정책): per-track 아님 → 별도 `cross_cutting[]` 또는 done 마커. 닫힘(2026-07-02) → `{id:XC-1, status:done}` 기록.

### 7.2 자동 모순 검출 (migrate 가 리포트)

- P4=unknown 인데 P5=wip 인 행(설정 9트랙 다수, `status:10`) → "파이프라인 순서 역행" 플래그.
- counts=null 인데 P5=pass → "완료 판정 불가(카운트 미확정)" 플래그.
- 스키마 밖 값(`?`·`—`·`⏸`) → 정식 상태로 변환하며 로그.
- 표 파손행(line 23, 20파이프) → 파싱 실패시 needs_human.

migrate 산출 = state.json(초안) + `migration-report.md`(모순·needs_human 목록). 사람이 report 로 해소 후 확정.

---

## 8. dlp.py CLI 표면

| 서브커맨드 | 역할 |
|---|---|
| `validate` | 불변식 전수 검사. 비0 종료+리포트. |
| `route [--branch B]` | route(state) 출력(다음 액션·STOP·이유). |
| `render` | state.json → status.md 재생성. `--check`=골든 대조만. |
| `migrate <status.md>` | 1회성: 구 표 → state.json 초안 + migration-report.md. |
| `selftest` | route()·불변식 합성 케이스 단언(검증 가능성의 teeth). |
| `approve <track> <rev> --logic --ui --by --at` | P1 승인 기록. |
| `set-phase <track> <rev> <P#> <status> [--clean-streak N --round N --preflight-fail]` | phase 상태 갱신. |
| `set-counts <track> <rev> --open-gaps N --needs-sim N` | P5/P6 카운트. |
| `add-evidence <track> <rev> --kind --phase --result --commit --command --count` | append-only 증거. |
| `add-cycle <track> <rev> --phase --found --resolved --remaining --note` | 사이클 라운드. |
| `set-track-status <track> active\|parked\|done` | 직렬 activate/park(validator 가 브랜치당1 강제). |
| `set-release <branch> pending\|parked\|pr_open\|merged [--pr N]` | 릴리스 마커. |
| `add-block / resolve-block <track> <rev> --id --desc` | ⛔BLOCK 관리. |

모든 뮤테이션은 **끝에 validate + render 자동 실행**(원자·항상 동기). validate 실패면 롤백(파일 안 씀)+에러.

---

## 9. SKILL.md 재작성 계획

- **역할 문장 유지**: 얇은 라우터. 차이 = 표 해석 대신 **`dlp route` 호출→출력 따름**, 판정 후 `dlp` 뮤테이션으로 셀 갱신.
- **한 번 도는 법**(신):
  1. `python3 scripts/dlp.py validate` — 깨졌으면 멈춤(사람).
  2. `python3 scripts/dlp.py route` — 브랜치별 다음 액션·STOP.
  3. STOP(승인·게이트·⛔BLOCK·needs_human·직렬위반) 이면 사람에게 보고.
  4. ACTION 이면 그 Phase 스킬 호출.
  5. 스킬 종료 후 `dlp set-phase`/`add-evidence`/`add-cycle` 로 기록(P3/P7 은 라우터 소유).
  6. 반복 or 정지점서 멈춤.
- **강제 게이트 절 유지**(승인·게이트초록·직렬·수렴·에스컬레이션·⛔BLOCK·파괴적액션) — 단 "직렬" 은 **브랜치당 1개**로 재정의.
- **트랙/브랜치 개념 절 신설**.
- 킥오프·로스터·템플릿 절 갱신(state.json 템플릿은 `dlp migrate`/초기화가 생성).

## 10. 로스터 동기화 (확진 즉시수정)

- `AGENTS.md:160` + `development-process.md:230` "실재 스킬은 **열하나**" → **18**(신규 7: deploy-dev·design-system-handoff·designer-handoff-report·emotion-conversation-contract-drift·regression-sync·release·sim-video-record). 2차 낡음(드리프트 설명의 드리프트) 정정.

## 11. 범위 밖 (이 작업 안 함)

- **P1b 스펙 오케스트레이션 배선**(spec-orchestration.md) — 의도된 backlog(리드 승인 후). 제어면 안정 전 11~15 에이전트 자동화 배선은 위험.
- **자평금지·승인게이트 lint 승격** — 전이 검증(증거 요구)으로 이미 부분 흡수(evidence.kind=approval·verifier provenance). 완전 lint 화는 후속.
- **앱 코드·다른 브랜치·커밋** — 사용자 지시 시에만.

## 12. 열린 질문 (codex/사용자 검토)

- Q1. emotion-conv-contract-resync 를 `active` 로 둘까 `parked`+needs_human 으로 둘까(실제 진행 중이나 ⛔B* 미결 다수).
- Q2. 설정 9트랙의 active 지정을 migrate 가 inquiry 로 제안할까, 전부 parked+needs_human 로 사람에게 넘길까(추정 금지 원칙 vs 편의).
- Q3. XC-1 같은 교차항목을 `cross_cutting[]` 별도 배열로 둘지, 가상 트랙(branch=feat/settings, feature=XC)으로 둘지.
- Q4. `dlp validate` 를 local_ci 게이트에 넣을지(넣으면 앱 게이트와 결합 — step 4 판단으로 미룸이 안전).
- Q5. status.md 뷰 골든 동기(불변식 8)를 hard FAIL 로 할지 warn 으로 할지(손편집 실수 방지 vs 유연성).

---

# v2 — 적대검증 반영 개정 (2026-07-24, 이 절이 구 §3~§8 을 상위 규정한다)

> 검증 = codex(repo-aware) **UNSOUND** + 격리 4렌즈 패널(route-totality·schema·migration·deadlock). **아키텍처(트랙/리비전/증거/순수route/validator)는 생존**, 스펙의 정밀성·완전성 결함이 다수 수렴(HIGH 12·MED 다수). 아래는 확진 결함별 개정. **구현은 이 v2 스펙을 따른다.**
>
> 정정 1건: codex HIGH "mypage 정반대 매핑" 은 거대셀 **stale 내부서사 오독**(셀 최종 상태는 P1~P6 완주). 단 패널 migration 이 독립적으로 "우리 자신의 완료 불변식상 counts=null 이면 done 불가" 로 같은 결론(=mypage done 확정 금지)에 도달 → **결과 채택**(오독은 기각, 결론은 유지).

## R1. `completion_predicate(rev)` 단일화 — route ↔ validator 동일 술어 (codex#3, panel route#1·#2)

route 의 `DONE` 판정과 validator 완료 불변식(#5)이 **서로 다른 정의**라 route 가 DONE 인데 validator FAIL 인 상태가 존재했다. → **단일 함수 `completion_predicate(rev)` 정의, route·validator 가 공유**한다:

```
completion_predicate(rev) :=
  approved_state(rev)==yes
  ∧ rev.P1.logic==pass ∧ rev.P1.ui==pass
  ∧ rev.P2.logic==pass ∧ rev.P2.ui==pass ∧ latest_gate(rev,'P2')==GREEN(@head)
  ∧ rev.P3 ∈ {pass(clean_streak≥2), skip(visual_exempt)}
  ∧ rev.P4==pass
  ∧ rev.P5==pass ∧ P5.clean_streak≥2
  ∧ rev.counts.open_gaps==0 ∧ rev.counts.needs_sim==0
  ∧ rev.P6 ∈ {pass, skip(counts==0)}
  ∧ open_blocks(rev)==[]
```

- **active→done 전이를 route 가 소유**(panel route#1 치명결함: 구 설계는 active 필터가 done 리비전을 배제해 DONE 이 영원히 발화 안 됨). route: active 트랙의 current_rev 가 `completion_predicate` 참이면 `ACTION(mark-track-done)` emit → 라우터가 `set-track-status done` 실행 → 재평가. (필터는 `status==active` 만; done 여부로 배제하지 않는다.)

## R2. per-phase 허용상태 매트릭스 + 상시 단조성 불변식 (codex#2·#6, panel route#2·#3, migration#7)

`skip`·`unknown` fall-through 로 잘못된 DONE·전진이 났다. **route_rev 를 매트릭스로 재작성**하고 validator 에 **상시(비-done 포함) 불변식** 추가:

| phase | 허용 status | skip 조건 | 게이트 phase? |
|---|---|---|---|
| P1.logic / P1.ui | unknown·wip·pass | — | no(승인 증거) |
| P2.logic / P2.ui | unknown·wip·pass | — | **yes(gate GREEN@head)** |
| P3 | unknown·wip·pass·skip | `track.visual_exempt` | no |
| P4 | unknown·wip·pass | — | no |
| P5 | unknown·wip·pass | — | no |
| P6 | unknown·wip·pass·skip | `counts==0`(gap 없어 미실행) | no |

- **불변식 M(단조성, 상시):** `∀rev, phase P_k==pass ⇒ 모든 선행 P_{<k} ∈ {pass,skip}`. 그리고 `P_k==pass ∧ P_k 이후 gate phase 존재 ⇒ latest_gate(rev,'P2')==GREEN@head`. → `P2=unknown·P4=pass`, `P4=pass·gate=RED`, 순서 역행이 **mid-pipeline 에서도 FAIL**.
- **불변식 W(리비전내 직렬):** 한 rev 에서 `status==wip` 인 phase ≤1. (inquiry P4·P5·P6 3중 wip 같은 상태 = FAIL → needs_human.)

## R3. gate 증거의 head 바인딩 + 무효화 (codex#5, panel route MED)

구 "latest phase-filtered gate" 는 이후 코드변경에도 GREEN 이 살아남아 미검증 HEAD 로 완료 가능. `latest_gate` 도 phase 필터 없이 호출돼 P4/P6 의 RED 를 P2 것으로 오인.

- `evidence(kind=gate|review|live_e2e)` 는 **`head_commit` 필수**.
- `latest_gate(rev, phase)` — **phase 인자 필수**(P2 게이트는 P2 것만).
- **`GREEN@head`** = 그 gate 의 head_commit 이 리비전의 현재 head 와 일치할 때만 유효.
- **무효화 뮤테이션 규칙:** 새 P2 gate(새 head) 기록 시, 그 head 이전에 pass 된 하위 phase(P3~P6)를 **자동 unknown 으로 되돌린다**(downstream invalidation). validator 불변식: done rev 의 P2gate·P3·P4·P5 증거 head_commit 이 **일관된 단일 head**.

## R4. 승인의 증거 결합 + P1·P2 logic/ui 분리 (codex#7, panel schema MED×2, §1.5)

`approved=yes` 가 P1 상태·승인증거와 결합 안 돼 승인 전 P2 진입 가능. §1.5 의 P1-logic/ui·P2 로직/UI 절반도 미표현.

- **P1 → `{logic:{status}, ui:{status}}`**, **P2 → `{logic:{status}, ui:{status}}`**(§1.5 절반 분리).
- **불변식 A:** `approved.logic==true ⇒ P1.logic==pass ∧ ∃ evidence(kind=approval, scope=logic)`. `approved.ui==true ⇒ P1.ui==pass ∧ rois_digest 존재 ∧ ∃ evidence(kind=approval, scope=ui)`.
- `approved` 에 **`unknowns:[{desc, shakes_state:bool, resolution}]`**(§1.5 미지수 목록). 불변식: `approved.logic==true ∧ ∃ unresolved shakes_state ⇒ FAIL`.
- route: `logic_only` → P2.logic 만 열고 **P3 진입 금지**(rois 없음). ui 승인 후 P3.

## R5. P5 수렴 streak (codex#4)

P5 도 `{status, clean_streak, round}`. **완료는 P5.clean_streak≥2**(§1b 단발 clean 금지). route: `P5==pass ∧ streak<2` → `feature-scenario-audit` 재감사.

## R6. route 는 스키마-내 데이터만·escalate=STOP (panel route#4)

구 route_rev 가 `P6.round`·"(P5 새 gap 있었음)" 등 스키마 밖 값 참조 → 순수함수 아님. 그리고 escalate 를 ACTION 으로 반환(§1b 위반).

- P5·P6 에 `round`(정수) 스키마 명시. "P5 가 gap 낸 적 있나" = `P5.round≥1 ∧ 과거 cycles 에 found>0`(파생규칙 명문화, route 는 rev 필드만).
- **에스컬레이션 = `STOP(사람)`**: P3/P5/P6 `round>3` 이면 ACTION 아니라 STOP emit(자동반복 중단, §1b·SKILL 강제게이트 정합).
- `preflight_fail` 생명주기: P2 pass 뮤테이션이 자동 `false` 리셋. 불변식: `preflight_fail==true ⇒ P3∈{unknown,wip}`.
- P3 `clean_streak` 필수·기본 0(route `?? 0` 정규화). 죽은 `and not skip` 제거.

## R7. execution_context(리비전별 브랜치) + handoff 이벤트 + sim UDID lease (codex#10·#11, panel schema#3, deadlock#2)

`track.branch` 단일 문자열이라 트랙이 브랜치 갈아탐(emotion→timestamp)·같은 브랜치 다중 워크트리·공유 sim 오염을 표현 못 함.

- **branch 를 REVISION 레벨로**: `revision.exec = {repo, branch, worktree, base_commit, head_commit}`. 직렬 계산은 **현재 리비전의 exec.branch** 기준. track 에 `branch_history[]` 보조.
- **handoff = append-only 이벤트**: `revision.handoffs:[{from_ctx, to_ctx, at, reason}]`.
- **sim = UDID 자원**: `branch.sim = {udid, device, since}`. **불변식 S:** `∀ active 브랜치: sim.udid 상호 배타`(공유 시 FAIL). route: udid 충돌·미지정 → STOP. (memory `sim-shared-session-reinstall-gotcha` 재현 차단.)

## R8. needs_human 최소화 + activation gate = route STOP + clear CLI (codex#12, panel deadlock#1·LOW, panel route/schema Q2)

구 설계는 migrate 가 `branch.needs_human` 설정 → 지우는 CLI 없어 **영구 STOP 재도입**. 또 브랜치 전역 플래그가 한 트랙 이슈로 전 브랜치 STOP.

- **`branch.needs_human` 은 진짜 브랜치-전역(sim/worktree 배정)만.** 트랙 이슈는 `revision.blocks[]`(하드) 또는 `awaiting[]`(소프트).
- **설정 9트랙 activation = route 의 내장 STOP**(`active 트랙 미지정 — activate 결정 필요`)을 사람 결정 게이트로 사용. migrate 는 `branch.needs_human` 을 **안 세팅**(패널 deadlock Q2). 재개 = 문서화된 `dlp set-track-status <track> active`.
- CLI 에 **`clear-needs-human`/`set-needs-human`** 추가. `set-track-status active` 는 브랜치 needs_human 자동 클리어.

## R9. P7 단일소유 + 부분 릴리스 (codex MED, panel deadlock#2)

P7 이 `revision.phases.P7` + `branch.release` 이중 → 모순 가능.

- **P7 제거**(revision.phases 에서). **`branch.release` 유일 소유.**
- **릴리스 적격 = 브랜치의 `status∈{active,done}` 트랙(=non-parked)이 전부 done.** parked 트랙은 이 릴리스 범위 밖(의도적 제외) → 이미 done 인 트랙의 부분 릴리스가 막히지 않음.
- route: 적격 ∧ `release==pending` → `ACTION(pr)`; `parked` → STOP(사용자 보류); `pr_open` → STOP(머지대기).
- **빈 브랜치 가드(codex LOW):** `len(non-parked tracks)==0` 이면 릴리스 판정 금지(`all([])` vacuous PR 차단).

## R10. 하드 blocks vs 소프트 awaiting 분리 (panel schema#1)

BE/디자이너 대기를 `blocks[]` 에 넣으면 라우터가 최전선 트랙을 영구 STOP → 데드락 재발.

- **`blocks[]`(하드)** = ⛔BLOCK(사용자 리터럴 vs 판단 충돌). route STOP. **append-only 결정레코드**: `{id, user_literal, status:open|resolved|superseded, resolution, actor, at}`. route 는 `open` 만 센다.
- **`awaiting[]`(소프트)** = 외부 대기(BE·디자이너): `{desc, party:be|designer|user, since}`. **route 비차단.** 완료는 `done` 이되 awaiting 잔존 = `done_modulo_await`(별도 플래그, 릴리스는 사람 판단). (contract-resync ⛔B6 "BE AI 백엔드 다운" = awaiting, 하드 block 아님.)

## R11. skip 서브타입 + visual_exempt (codex MED, panel route MED, schema#2)

`skip` 이 3상황(webview영구·이 rev UI무변경·gap0파생 P6)을 뭉갬. 시각검증을 비-webview 트랙에서도 조용히 끌 수 있음.

- `track.visual_exempt:bool`(webview 등). **불변식:** `P3==skip ⇒ track.visual_exempt==true`.
- `phase.skip_reason ∈ {structural(webview), norev(이 rev UI 무변경·다음 rev 재평가), derived(counts==0→P6)}`. 완료 불변식이 서브타입별 판정.

## R12. evidence.kind 확장·타입드 payload; phases=projection (codex MED×2, panel schema MED)

- **`evidence.kind` 확장**: `gate`(phase,result,head_commit,command,count) · `review`(phase,verifier_count,verdict:SOUND|UNSOUND,round,head_commit) · `live_e2e`(device,backend,head_commit) · `regression`(test_ref,red_proven:bool) · `merge`(base,conflicts) · `approval`(scope:logic|ui,actor,artifact_digest) · `harness_feedback`(mechanism) · `note`.
- **불변식(정족수 감사):** P3/P4/P5 의 pass 는 `∃ evidence(kind=review, verifier_count≥3 or codex, verdict=SOUND, 자기검증 아님)`. 승인은 `kind=approval` 로만.
- `phases` = route 가 읽는 **현재 projection**. `evidence[]`·`cycles[]` = **append-only 감사 이력**(라운드·정족수·head 재구성 가능). 별도 phase_runs[] 테이블 대신 이 이원화로 codex "PHASE_RUN 이력" 요구 충족.

## R13. cross_cutting[] + deferred/followups + carry (codex MED×2, panel schema MED, migration MED)

- **`cross_cutting:[{id, status:open|closed, closed_at, evidence[], carry_items:[{desc, target_track, status}], deferred[]}]`** 1급 배열(가상트랙 아님). XC-1 을 여기. **carry_items** 로 활성 2 DEFER(withdrawal_page actionKind·inquiry_detail present() 테스트)를 withdraw/inquiry 트랙 `blocks|notes_ref` 에 교차링크.
- **`revision.deferred:[{desc, reason:intended|followup|harness, gate:designer|be|touch, status:deferred|proposed|dropped|triggered|done}]`** — DEFER/PROPOSED/placeholder 구조 보존(구 notes 자유문장 대체). done 은 "deferred 다 계정" 이어야.
- **`revision.harness_feedback:[{desc, mechanism}]`**(§12 메타루프 산물).

## R14. migration 규칙 강화 — "추정 금지" 를 코드로 (codex#8·#9, panel migration#1~#4·MED)

1. **블랭킷 금지 — 트랙별 실제 셀.** "설정 9 P1~P3=pass" 대신 각 셀 그대로: app-lock P3=wip·feedback P3=skip 등.
2. **done 자동확정 금지.** `done` 은 **counts 가 명시 정수 0/0 이고 completion_predicate 참일 때만.** counts=`—`/`?`→null → **절대 done 아님.** mypage(counts —)·contract-resync(counts —) = parked, `dlp set-counts` 로 사람이 P6 증거 인용해 0/0 명시해야 done 승격.
3. **셀 vs 프로즈/next 모순 = needs_human.** bag(P4~P6 셀=✅ vs 프로즈 "next=P4") → 자동 done 금지, report 로 표면화.
4. **거대셀 raw 보존·수동 manifest.** emotion V2~V6·V5-1~V5-4·contract-resync 슬라이스①~⑤ 를 **자동 분해 금지** → raw 를 `notes_ref` 로 보존 + migration issue 로 "사람이 리비전 manifest 승인". V6 미이행 지시 2건·P5 이월 5항목 → `blocks[]`/`deferred[]`.
5. **파손행(row 23) hard-fail.** 헤더 열수 불일치 → 부분파싱 금지, raw bytes+hash 를 report 에, needs_human.
6. **추가 검출기(§7.2 보강):** (e)phase 퇴행(후행 pass·선행 non-pass) (f)counts 정수인데 P5∈{unknown,wip} (g)한 rev 2+ wip (h)셀-프로즈/next 불일치. 각각 needs_human.
7. **lineage:** contract-resync.parent_track = ai-direct(→emotion). ai-direct done 이되 B7(direct 퇴역)=`deferred`.
8. **트랙별 판정(초안, 사람 확정):** ai-direct=**done**(counts 0/0·deferred[B7]·release parked) / bag=needs_human(셀-프로즈 모순) / mypage=parked(counts null→set-counts 대기·release parked) / contract-resync=parked(blocks B2-B7·A4·A5·D4 + awaiting B6 + parent) / emotion-conversation=parked(수동 manifest·handoff) / 설정9=parked(트랙별 실셀, inquiry=활성 추천후보) / XC-1=cross_cutting closed+carry.

## R15. 열린 질문 — 최종 확정 (다수결)

- **Q1** = contract-resync **parked**, 미결 ⛔ 는 `revision.blocks[]`(전수 B2·B3·B4·B5·B6·B7·A4·A5·D4), BE 대기는 `awaiting[]`. (branch.needs_human 아님.)
- **Q2** = 설정 9트랙 **전부 parked**, 자동 active 금지. migrate 는 inquiry 를 report 에 **추천 후보**로만. 재개 = 사람이 `set-track-status active`. branch.needs_human 미설정(route 내장 STOP 이 게이트).
- **Q3** = **`cross_cutting[]` 1급 배열**(가상트랙 아님).
- **Q4** = **local_ci 결합 안 함**(step 4+). 강제 = dlp 뮤테이션 말미 auto-validate + SKILL 라우터진입 preflight(`dlp validate && dlp selftest && dlp render --check`).
- **Q5** = **hard FAIL**(뷰 드리프트), 단 dlp/라우터 경로 안에서만. 에러에 `dlp render` 탈출구 병기.

## R16. dlp.py CLI 개정 (v1 §8 에 추가/변경)

추가: `clear-needs-human`/`set-needs-human <branch>` · `mark-track-done`(completion_predicate 통과 시만) · `add-await`/`resolve-await` · `add-deferred` · `add-cross-cutting`/`close-cross-cutting` · `set-counts` 는 P6 evidence 참조 강제. 변경: `add-evidence` 가 kind별 필수필드 검증(head_commit 등) · 새 P2 gate 는 downstream 자동 무효화 · 모든 뮤테이션 말미 `validate`(불변식 M·W·A·S·완료 포함)+`render`.

---

# v3 — 구현 적대검증 반영 (2026-07-24, codex + 격리 4렌즈 UNSOUND 수렴 → 이 절이 상위 규정)

> 빌드(툴·state·SKILL)를 codex + 격리 패널로 적대 검증한 결과(둘 다 UNSOUND)를 반영. 아키텍처는 유지, **enforcement 구멍**을 닫았다. `scripts/dlp.py` selftest 28케이스가 아래를 회귀로 잠근다.

## V1. 검증증거 없는 완료 차단 — I-Q 정족수 불변식 (자평 금지의 코드화, 최우선)

리뷰 최대 결함: P3/P4/P5 를 `pass` 로 찍고 done 까지 갈 때 **적대 검증 증거가 0이어도 통과**했다(도구의 존재 이유가 무너짐). → **`phase_done(P3/P4/P5)` 과 validator `I-Q` 가 SOUND 리뷰증거(`kind=review, verifier_count≥3 또는 codex, verdict=SOUND, phase 일치`)를 요구**한다. route 도 `phase_done` 을 쓰므로 증거 없는 pass 는 자동으로 그 phase 로 되돌아간다. `set-counts` 는 P5 리뷰증거를 선행 요구.

## V2. R3 head 바인딩 실동작 — stale/fabricated GREEN 차단

`gate_green_at_head` 의 head-미상 관용을 **완료판정에서 제거**: `completion_predicate` 는 `_head_ok`(P2 gate + P3/P4/P5 리뷰증거가 `exec.head_commit` 과 단일 일치, 실 커밋)를 요구. `add-evidence` 는 gate/review/live_e2e 에 `--head-commit` 필수. 새 P2 gate(새 head) 기록 시 하위 phase pass 자동 무효화. (라우팅용 `phase_done(P2)` 는 GREEN 결과만 봐서 진행은 막지 않되, done 은 head 없으면 불가.)

## V3. completion·route 가 track 을 본다 (R1 P3-skip 불일치 해소)

`completion_predicate(rev, track)`·`phase_done(rev, phase, track)` 로 시그니처 변경 — P3=skip 은 `track.visual_exempt` 일 때만 done. route 와 validator(I-V)가 동일 판정.

## V4. validator 강화 (mid-pipeline 모순·여분키·타입드 증거)

- **I-M 단조성에 P1 포함** + **I-A2**(P2.logic pass ⇒ approved.logic; P2.ui pass ⇒ approved.ui) — 승인 없이 P2 pass 차단.
- **I-PK**: phase 키 정확 집합 P1~P6 (여분 `P7`/`P9` 거부 — set-phase 도 choices 제한).
- **I-EV**: evidence kind별 필수필드(gate→phase·result, review→phase·verifier_count·verdict, …).
- **I-P6**: P6=skip ⇒ counts 0/0. **I-S**: active 브랜치 sim udid 상호배타. **I1-branch**: 트랙 branch 미지정 거부.
- **I-C** 는 `done ⇒ complete` 단방향(parked-complete 합법).

## V5. route 총함수·크래시 제거 & sim lease

- `route` 의 `sorted(..., key=lambda x: x or "")` 로 **None 브랜치 크래시 제거**. `cmd_route` 는 먼저 `validate` — bad-type state 에서 raw 스택트레이스 대신 클린 거부.
- **R6 P6 에스컬레이션을 counts 분기 앞으로** (counts 0 에서도 round>3 → STOP).
- **R7 sim lease**: sim 점유 phase(P3/P4) ACTION 인데 브랜치 `sim.udid` 미지정 → route STOP. `set-sim`/`set-head`/`add-handoff` 뮤테이션 추가.

## V6. migration 충실도 (추정 금지 재강화)

- **원본 = git HEAD 보드**(렌더로 덮이기 전) — `audit --source git:HEAD:…`(기본값), 리포트를 `--out` 파일로 write. `dlp-notes/` raw·`_original` 은 git 원본에서 실제 복원(빈 껍데기·오라벨 수정).
- **리뷰증거 없는 P3~P6 `pass`/`clean_streak` 를 전부 `unknown` 강등**(app-lock·설정·mypage·contract-resync·bag). 유일 예외 = **ai-direct**(문서화된 격리/codex 패널 증거 보유 → P4/P5 pass 유지, 단 head 미포착이라 아직 done 아님). 원본 셀은 `harness_feedback` + `notes_ref` 로 보존(손실 0).
- 마이그레이션 provenance 는 `source:"board-migration"` 태그(가짜 아티팩트 아님 명시). inquiry 는 "de-facto active·활성화 후보" 를 보존. contract-resync.parent=ai-direct. XC-1 carry 역링크 + DROP 3건.

## V7. 권위 CLI (설계 §8 표를 이걸로 대체)

`validate` · `route` · `render[ --check]` · `selftest` · `audit [--source --out]` · 뮤테이션 `add-track` `set-phase(P1~P6, --side, --clean-streak, --round, --preflight-fail, --skip-reason)` `approve(--logic --ui --at --rois-digest)` `add-evidence <kind>(kind별 필수 + gate/review/live_e2e 는 --head-commit)` `set-counts(P5 리뷰 선행)` `add-cycle` `set-track-status` `mark-track-done` `set-release` `set-sim` `set-head` `add-block`/`resolve-block` `add-await`/`resolve-await` `add-deferred` `add-handoff` `add-cross-cutting`/`close-cross-cutting` `set-needs-human`/`clear-needs-human`. (구 §8 의 `migrate`→`audit` 개명, `route --branch` 미구현, `add-evidence --kind`→위치인자.)

## V8. 미해결(설계 backlog, 의도적 미구현)

- **`approved.unknowns` 세팅 CLI 부재**(R4) — validator 는 미해결 shakes_state 미지수를 검사하나(`I-A`), 이를 기록할 뮤테이션이 없어 손편집으로만 채워진다(없으면 vacuous pass 라 안전측). 후속: `approve --unknown <desc> --shakes-state` 또는 `add-unknown`.
- **done_modulo_await** 파생 플래그(R10) — awaiting 잔존+done 구분 표기는 후속(현재 awaiting 은 비차단·render 에 개수 표시로 족).
- head/lease **실 git 연동**(현재는 기록·일관성만; 실제 커밋·UDID 존재 확인은 사람/후속). full R7(worktree·base·handoff 검증)도 부분.
- P1b 오케스트레이션·컨벤션→lint 승격(원래 step 4, 범위 밖).

## V9. 수렴 (2026-07-24) — 적대 검증 5라운드 종결

검증 궤적: 설계(UNSOUND→수정) → 구현 R1(7 HIGH 강제누락→수정) → R2(2 CRIT 수정유발→수정) → R3(malformed-input, 격리 1 SOUND/1 SwF→수정) → 자체 fuzz(systemic `_wellformed` 도입) → R4(격리 렌즈 **SOUND**·codex 는 stale 스냅샷) → R5(codex **SOUND-WITH-FIXES**: 반위조 코어·마이그레이션·과잉거부 모두 CLOSED, 잔여 LOW=numeric block.id→즉시 수정). **최종: 반위조 코어·마이그레이션 무결·라우팅 총함수·malformed 방어 모두 CLOSED(codex+격리 양측 확인).**

- **설계 노트(codex R5):** `completion_predicate(rev)`·`route_rev(rev)` 는 **리비전 단위**라 브랜치/cross_cutting 같은 **전역 손상은 못 본다**. 전역 손상 방어는 `validate`(I1-type)와 CLI 진입(`cmd_route` 가 validate 선행)이 담당한다 — 도구의 모든 공개 경로(뮤테이션 `_apply`·`cmd_route`·`cmd_validate`)가 validate 를 거치는 의도된 계층(per-rev 판정 vs 전역 무결성)이다.
- **회귀 잠금:** `selftest` = 함수 60+ 케이스 + CLI e2e(P1→DONE, 실제 커맨드 경로) + malformed fuzz(비-dict 컨테이너·값·스칼라·fail-closed·numeric id). 리뷰가 찾은 모든 구멍이 케이스로 박혀 재오픈 시 즉시 RED.

## V10. DO-NOW 운영 배치 (2026-07-25) — 루프 개선 codex+격리 권장 반영

방금 만든 상태 머신이 "0 기능 구동"(전 브랜치 parked STOP)이라는 진단에 따라, 운영을 매끄럽게 할 저비용(S) 항목을 구현. V8 backlog 일부 해소:

- **`dlp needs-human`** — route STOP(브랜치 결정점) + 트랙별 미결(⛔BLOCK·awaiting·counts 미확정·미해결 shakes_state·done후보-head누락)을 한 화면으로 집계(read-only). 마이그레이션 12결정을 6번 왕복이 아니라 한 세션에 검토.
- **`add-unknown`/`resolve-unknown`** — `approved.unknowns` 기록/해소 뮤테이션. 구 V8 "unknowns CLI 부재"로 vacuous 였던 `I-A`(미해결 shakes_state+승인=FAIL)가 이제 실제로 문다.
- **`capture-head`** — `git rev-parse HEAD` 자동 캡처 + dirty 워킹트리 거부. 구 `set-head`(임의 문자열)는 migration/admin escape hatch 로 존치. 오타·미갱신 head 사고 차단(위조 방어 아닌 accident 방어).
- **`done_modulo_await`** — completion 은 유지(awaiting 비차단)하되, 릴리스 적격 브랜치에 awaiting 잔존 시 route 가 auto-pr 대신 STOP('해소 후 pr, 또는 set-release pr_open 명시 승인'). "기능 완료"와 "BE 계약 완결" 혼동으로 인한 오릴리스 방지.
- **`development-process.md §12` 갱신** — 스펙승인·자평금지를 '강제(dlp, 경유 시)'로 이동. dlp 강제는 opt-in(코드가 dlp 우회 가능) 명시.

selftest 회귀 추가(done_modulo_await·unknown I-A·needs-human·CLU add-unknown). **여전히 backlog(V8)**: P1b 배선, tree.json→rois 생성기, review provenance 필수화, sim UDID 머신-로컬 lease, DS raw-위젯 lint(앱 워크트리에서 위반 수정과 함께), 하드 승인 강제.
