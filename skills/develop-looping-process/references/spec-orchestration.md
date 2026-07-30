# P1b 스펙-작성 오케스트레이션 (figma-sync 부터 · 4단계 서브에이전트)

> 상태: **프로토타입 검증됨(notice, 2026-07-07)**. feature-plan Phase 1 의 §1.1~1.4 를 이 오케스트레이션으로 교체하는 게 목표. 지금은 이 문서가 설계 정본이고, 실제 스킬 배선(§배선 잔여)은 리드 승인 후.
> 관련: [development-process.md](development-process.md) §3 · [feature-plan SKILL](../../../../.claude/skills/feature-plan/SKILL.md) · [understanding-doc-format.md](../understanding-doc-format.md) · 스펙 스켈레톤 [`ai_specs/_template.md`](../../../../ai_specs/_template.md)

## 왜

서버 작업이 피처 개발보다 느리다. 계약 없는 상태에서 화면·상태·에러 표면을 짜야 하니, **도메인(Entity)을 먼저 얼리고 백엔드 없이 개발**할 수 있어야 한다. 그리고 좋은 스펙은 사람 손 하나로 쓰기엔 챙길 게 많다(서버 준비도·Entity·경계·목·에러·테스트·ROI·DS) — 그래서 **분석을 서브에이전트로 팬아웃**한다.

## 아키텍처 결정 (codex 협의 + notice 프로토타입 실증)

- **포트는 백엔드 피처 전부 기본.** 추상 remote-source 포트(public=Entity) + mock provider, repository 는 `ApiResult<Entity>`. 비용 ~10줄(push `DeviceMetadataSource` 템플릿). 일관성은 포트에서 산다.
- **DTO 를 Entity 와 별도 타입/파일로 쪼개는 건 신호 있을 때만** — 읽기≠쓰기 실사용 · 도메인 불변식 · 멀티소스 · 장기오프라인 · 비항등 변환. `model==entity` 면 안 쪼갬(항등 mapper 낭비). 현 AGENTS.md "단일 모델 기본"과 정합. **전면 Entity+DTO 강제 아님.**
- **`server_readiness` 가 분기점.** `unknown` → Entity fixture(가짜 JSON 금지)·DTO 는 실계약 오면 T1. `built/draft` → 실 JSON 알아 그때 결정. (설정 9기능 = built, `_api/*.json` 역추출 계약 존재. "서버 지연 새 피처" = unknown.)
- mock 은 DTO flag 가 아니라 **provider 레벨** 물건(포트 뒤 `mock_remote_provider` vs `api_remote_provider`).

## 플로우

```
develop-looping-process (라우터) ── P1 미완 진입
  → P1a  figma-sync extract_doc → docs/designs/settings/<f>/*.tree.json (캐시, 있으면 재사용)   ◀ 시작점
  → P1b  스펙 오케스트레이션 4단계 (아래)  [+ _api/<f>.json 서버계약]
  → ⛔ 사람 승인 → Entity·State·Cubit API·readiness·경계 동결 (approved=yes)
  → feature-implement (P2) …
```

figma 를 맨 앞에서 한 번 뽑아 tree.json 으로 캐시하면, 아래 `figma-measurer` 가 그걸 **읽기만** 한다 — 병렬 에이전트 4개가 각자 Figma API 를 때리는 flaky/rate-limit 이 사라지고, P3 visual-verify 도 같은 추출물을 재사용한다.

## 로스터 (P1b 스펙+QA)

> **주의 — 아래 로스터는 설계다(아직 자동 배선 전).** 현재는 feature-plan §1.1~1.4 순차 절차가 이 역할을 대행하고, 서브에이전트 팬아웃 실배선은 리드 승인 후(↓ 배선 잔여). ⭐=신규, ⭐QA=QA 오케스트레이션 신규.

| 단계 | 에이전트 | 책임 |
|---|---|---|
| ① 이해(병렬, 읽기) | `figma-measurer` | tree.json → 화면·상태·ROI 후보 |
| | `server-scout` ⭐ | `_api/<f>.json`+원본앱 → readiness 판정 + endpoints + wire shape |
| | `entity-modeler` ⭐ | 화면이 쓰는 **앱 facing Entity**(wire 아님) — 동결 대상 |
| | `flow-behavior` | GWT 인수조건 + mermaid + State 변형 + DoloErrorKind |
| | `existing-pattern-scout` ⭐QA | 주변 피처/모듈/테스트 관례(레이어·DS·module 배선) — 구조 정합 |
| ② 결정(병렬) | `boundary-decider` ⭐ | port-only vs port+DTO(신호 규칙) + 캐시 계획 |
| | `mock-designer` ⭐ | Entity fixture(정상/빈/엣지) + 주입 DoloError → 표면 |
| | `ds-test-planner` | DS 매핑 + qa_key ROI + RED bloc_test + 계약테스트 계획 |
| | `qa-scenario-designer` ⭐QA | flow/spec → **spec-time** GWT QA 시나리오(개발 후 아님) |
| | `edge-boundary-hunter` ⭐QA | 경계값·무효상태·재시도·오프라인·빈데이터·stale·중복탭·재진입 |
| | `test-contract-planner` ⭐QA | 시나리오마다 검증타겟 매핑(bloc_test\|widget\|runtime\|visual\|audit) |
| | `qa-traceability-librarian` ⭐QA | `<f>.scenario_matrix.json` 유지 — 드리프트 방지 |
| ③ 합성(배리어) | `spec-synthesizer` | 전부를 `ai_specs/<f>.md`+개발계획서+scenario_matrix 로 조립(동결 규율) |
| ④ 검증 | `spec-critic` ×3 | 격리 적대(재사용 `isolated-adversarial-verifier`) — gap 표면화 |
| | `codex` repo-aware | 아키텍처·테스트가능성·DS레지스트리·레이어경계·시나리오↔테스트 정합(격리 스킵틱과 **다른 렌즈**) |

배리어는 **한 곳뿐** — ③ 합성이 ①②의 모든 산출을 기다린다. ②는 특정 ①출력만 기다리는 pipeline 부분의존이라 완전 배리어가 아니다 → `pipeline` + ③ 앞 단일 배리어. medium = **Workflow 스크립트**.

## QA 는 spec-time, 개발은 레이어/위젯 이원화 (codex 검증 2026-07-07)

**① QA 시나리오는 spec-time(P1b)에 쓴다 — 개발 "후" 아님.** 인수조건=bloc_test 로 TDD 를 끄는 게 목적. 개발 후 발견은 별개로 분류: P5(scenario-audit)가 "구현을 봐야만 아는" 엣지(동시성·복귀 stale·라우트 상태)를 잡아 scenario-gaps → P6 회귀테스트. **감사가 정본 인수 suite 를 나중에 지어내게 두지 않는다**(그러면 TDD 약화).

**② scenario_matrix 로 추적** — `docs/renew-guide/impl/settings/<f>.scenario_matrix.json`: `scenario_id · source(spec|edge|p5_gap|regression) · qa_keys · state_variants · cubit_methods · error_kinds · verification(bloc_test|widget_test|runtime_qa|visual_verify|audit_only) · test_refs · status`. 라이트 검증기(후속): 동결 시나리오는 검증타겟 ≥1, `rois.json` 의 모든 qa_key 는 시각/런타임/의도적-노트 중 하나로 참조. **시나리오·ROI·테스트가 3개로 따로 놀며 드리프트하는 걸 막는다.**

**③ visual-verify 재료**(Figma 화면 이미지)는 이미 P1a `extract_doc`(PNG+tree.json, `docs/designs/` gitignore)가 뽑고 `clean_qa_artifacts.sh` 가 정리한다 — 새로 만들 것 없음. P3 편의로 비교용 md 만 추가.

## P2 개발 오케스트레이션 — 로직=레이어 슬라이스, UI=ROI/위젯 슬라이스

**"화면당 위젯단위"는 UI 엔 맞지만 P2 전체의 단위로는 틀리다** — cubit/state/repository 는 위젯이 아니라 **행위(behavior) 모양**이라, 처음부터 위젯별로 쪼개면 공유 상태가 파편화된다. 그래서 이원화(codex 지적):

| 순서 | 에이전트 | 단위 |
|---|---|---|
| 1 | `structure-mapper` (+codex: 코딩 전 관례 정합) | 동결 Entity/spec → 프로젝트 파일/모듈 |
| 2 | `red-test-writer` | scenario_matrix → RED bloc_test (**시나리오 단위**) |
| 3 | `layer-implementer` | model→provider→repository→cubit (**행위 슬라이스**, 시나리오 테스트 초록까지) |
| 4 | `ui-slice-planner` | rois.json → 화면 ROI 클러스터(페이지셸→주요섹션→반복행/카드→빈/에러/로딩→인터랙션; leaf 원자화 금지) |
| 5 | `widget-slice-implementer` (+**클러스터마다 codex**: DS·qa키·상태렌더·에러표면·screenutil·raw자산) | UI ROI 클러스터 (**위젯 슬라이스**) |
| 6 | `gate-runner` | format·analyze·custom_lint·test |

**로직은 레이어별, UI 는 ROI/위젯별** — 한 단위를 전 레이어에 강제하지 않는다. 사용자가 원한 "위젯단위 진행 체감"은 4~5단계가 준다.

## 동결 규율 (freeze-discipline) — HARD

synthesizer 가 "분석한 것의 합집합"을 동결하면 안 된다. **동결 = 결정된 것의 교집합.**

- openQuestion 과 조금이라도 엮인 항목은 **frozenArtifacts 에 절대 넣지 마라** — 소속 미정·미검증 가정·디자인 미확정·서버 미검증 경로는 전부 openQuestions 로 빼고 본문엔 `PROPOSED`(제안·미동결)로만.
- 목록 시점에 아직 인스턴스화 안 된 DetailCubit 메서드 호출 같은 **구조적 모순을 동결 금지**(소속을 openQuestion 으로).
- 서버가 비페이지네이션(hasMore 고정 false)이면 loadMore/pageScope 를 동결하지 말고 유지-vs-제거를 openQuestion 으로.
- **동결 필드에 미동결 필드값을 단언하는 테스트도 금지**(예: page 미동결인데 테스트가 page==1 단언).
- figma 상태 인벤토리를 본문에 넣어 State union 과 1:1 대조 가능하게.

## critic = 게이트가 아니라 gap-surfacer (핵심)

**정직한 스펙(openQuestion 을 성실히 남긴)은 엄격한 스킵틱한테서 zero-gap PASS 를 못 받는다** — "불확실=GAPS 기본값"이라서. PASS 를 억지로 쫓으면 synthesizer 가 정당한 미결을 숨겨 역효과(§자기검증 금지 변형).

그래서 critic 의 GAPS 는 "스펙이 나쁘다"가 아니라 **"사람 승인에 올릴 결정 대기 목록"**이다. gap 을 두 버킷으로:

- **(a) synth-fixable(정합성)** — 동결 테스트가 미동결 필드 단언, qa_key 누락, ErrorScopeKey 미정의 등 → synth 1~2 라운드 재run 으로 닫는다.
- **(b) needs-human-decision** — 상세 실패 retryExhausted 승격 기제, 라이브 응답 미캡처, status 필터 책임 등 → **openQuestion 으로 사람 승인에서 답한다.**

**수렴 기준 = "새 HIGH/구조 gap 0" 이지 "gap 0" 이 아니다.** (b) 가 남은 채 사람에게 올리는 게 올바른 산출.

## 프로토타입 증거 (notice, 2026-07-07)

- ✅ `boundary-decider` 가 독립적으로 **port-only · splitSignals=[]** 도출 = 손 debate 한 결론을 기계 재현(민감필드는 오히려 DTO 반대 근거라고까지). readiness=built 정확.
- ✅ **freeze-discipline 자기교정 실증**: v1(규율 전) critic gap **20개·HIGH 2**(목록시점 DetailCubit 호출 구조버그 + 페이지네이션 gold-plating 동결) → v2(규율 후) **13개·HIGH 0**. 최악 클래스가 닫힘.
- v2 잔여 13 = (a) 정합성 + (b) 사람 결정 = 위 "gap-surfacer" 해석대로 정상.
- 워크플로 `wf_7cdaa7d2-739`(11에이전트, v1 639k→v2 230k 토큰 캐시). 초안 산출 scratchpad `notice-spec-DRAFT{,-v2}.md`.

## 데모 실증 — QA/개발 로스터 (inquiry, 2026-07-07 · wf_1f4e45a1)

업데이트된 로스터(신규 QA 에이전트 5종 포함)를 inquiry(폼+이미지+제출)에 **15에이전트**로 실행:

- **산출**: QA 시나리오 **39** · 엣지 **53**(10카테고리: boundary 13·invalid 10·offline/stale/dup-tap/re-entry 5·…) · `scenario_matrix` **102행 + 14 gap 자진 신고** · 스펙 25k자(frozen 20·openQ 9). readiness=built·boundary=port-only.
- `qa-scenario-designer` — critic 전원 "spec-time GWT 상위권"(실 구현 submitScope·delete 404멱등·faq_variant·피드백 👍/👎 scope 분리·retryExhausted 3-strike 정확 반영).
- `qa-traceability-librarian` — scenario↔qa_key↔state↔cubit↔error↔test 배선 + **detail 이미지·faq_variant·force-quit·딥링크 미커버를 self-flag**(설계 핵심이 작동 = 드리프트 자진 지도화).
- `existing-pattern-scout` + `repo-aware`(codex 대역) — 격리 critic 이 놓칠 **as-built 결함 포착**(InquiryReply 에 isLike 필드 없음·MediaPicker 권한거부는 빈배열 → permissionDenied 경로 부재). **다른 렌즈** 실증.
- **critic 3/3 GAPS** — gap-surfacer 로선 정상. 두 부류: (a) **이미 구현된 피처**라 생긴 as-built 시그니처 드리프트(`submit(content)` vs 실제 named — 신규 P1 엔 무관) + (b) matrix 자진신고 커버리지 gap(도구가 제대로 일한 증거).
- **배운 점**: 부분구현 피처엔 synthesizer 전에 `structure-mapper` 가 실코드 시그니처를 대조해 동결 fidelity 를 맞춰야 한다. 비용 **1.27M토큰/24분** → "이 깊이가 필요한 피처에만 풀가동" 판단 필요. 초안 스펙 scratchpad `inquiry-demo-spec.md`.

## 배선 잔여 (리드 승인 후)

1. **feature-plan P1 실제 배선** — §1.1~1.4 를 이 워크플로 호출로 교체(오케스트레이터가 P1a/P1b 를 부르게). 지금은 additive: 템플릿·이 문서·critic 재사용까지만 반영, 기존 순차 절차는 유지.
2. **import-ban custom_lint 2~3개** — `no_dto_import_outside_provider` · `entity_no_json_serializable` · repository→port 의존. 나머지(항등 mapper·계약 흔들림 판정)는 타입해석 필요 → 코드리뷰. 드리프트 관찰 전 8개 선제 제작은 과투자.
3. **critic 버킷 자동분류** — (a) synth-fixable 는 자동 재run, (b) 는 사람 승인으로. 지금은 수동.
