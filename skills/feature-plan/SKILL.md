---
name: feature-plan
description: "설정 기능 하나를 코딩 전에 Figma 실측→플로우(mermaid)→개발계획서→QA 시나리오로 글로 못 박고, 끝에 사람 승인으로 State·Cubit 공개 API 를 동결하는 Phase 1 — '계획'·'이해도/개발계획서'·'스펙 정리'·'착수 전 정리'·'상태/Cubit 시그니처 초안' 같은 말이 나오면 Phase 를 명시 안 해도 코드는 안 짜니 이 스킬을 쓴다. 여기 Figma 는 계획용 실측일 뿐(토큰 동기화=figma-sync·시안 대조=visual-verify 아님), 구현은 승인 뒤 feature-implement. 트리거 — '이 기능 계획 짜줘', '이해도/개발계획서 써줘', 'Phase 1 시작', '스펙 승인받게 정리해줘', 'figma 재서 화면·플로우·상태 계획으로 정리', 'QA 시나리오/Cubit 시그니처 미리 써두자', '[Figma 링크/기획서] 주며 이거 개발할거야/이거 만들자'(킥오프 — 그 프레임을 extract_doc 실측해 계획부터, =P1a), 또는 develop-looping-process 가 라우팅."
---

# /feature-plan — Figma 실측→플로우→개발계획서→QA 시나리오, 끝에 사람 승인(State·Cubit API 동결)

> 정책: 이 스킬이 도는 동안 git 상태 변경 금지 — checkout/switch/branch/commit/stash/push 안 한다. 작업 브랜치 feat/settings 유지.
> 정책: 범위는 부탁받은 기능·이 Phase 만. 새 디바이스·도구·능동 확장 전 보고 후 멈춘다.
> 정책: 자기 작업을 자기가 "됐다" 판정 금지 — 검증은 격리 에이전트 2~3 + codex 다수결(자평 금지).

이건 재발명이 아니다. 마스터 프로세스는 [`development-process.md §3`](../../../docs/renew-guide/impl/settings/development-process.md) 이 단일 출처. 이해도 문서 형식은 [`understanding-doc-format.md`](../../../docs/renew-guide/impl/understanding-doc-format.md), 스펙 스켈레톤은 [`ai_specs/_template.md`](../../../ai_specs/_template.md), 황금 예시는 [`settings-understanding/account-main.md`](../../../docs/renew-guide/impl/settings-understanding/account-main.md). 이 스킬은 그 §3 을 순서대로 강제·적용할 뿐이다. Phase 1 은 라인 코딩이 아니라 **글로 못 박고 승인받는** 단계다.

> **P1b 스펙-작성 오케스트레이션(신규, 프로토타입 검증됨 2026-07-07)** — figma-sync(extract_doc) 를 맨 앞 P1a 로 두고, 아래 1.1~1.4 를 4단계 서브에이전트 팬아웃(이해→결정→합성→적대검증)으로 도는 설계가 [`spec-orchestration.md`](../../../docs/renew-guide/impl/settings/spec-orchestration.md) 에 있다. 서버 준비도(`server_readiness`)·Entity 동결·경계(port-only vs port+DTO)·목 계획·**동결 규율**(미결은 동결 금지)를 스펙에 담는다(`_template.md` 에 반영됨). critic=gap-surfacer(검증 역할)·QA/개발 로스터 상세는 `spec-orchestration.md`(스펙 콘텐츠 아니라 프로세스). 실제 워크플로 배선은 리드 승인 후 — 그 전엔 이 스킬이 아래 순차 절차로, 스펙엔 그 새 섹션들을 채운다.

## 언제

- "<기능> 계획/이해도/개발계획서 써줘" · "Phase 1 시작" · "스펙 승인받게 정리해줘". 또는 develop-looping-process 오케스트레이터가 진행판을 읽고 이 기능 P1 로 라우팅.
- 입력 = 대상 기능 하나(설정 9기능 중: 계정·로그인정보·알림·공지·앱정보·의견·문의·앱잠금·회원탈퇴) **또는 Figma 기획서 링크/node-id**. Figma 링크로 "이거 개발" 킥오프면 1.1(=P1a)이 그 프레임을 `extract_doc` 로 실측해 시작한다. 대상이 모호하면 1줄만 되묻는다.
- 한 번에 한 기능만. 병렬로 여러 기능 계획을 펼치지 않는다(§0 기능 단위 직렬).

## 선행 조건 (들어오기 전)

진행판 = [`develop-looping-process-status.md`](../../../docs/renew-guide/impl/settings/develop-looping-process-status.md)(기능 × Phase P1~P7 표, 셀 ⬜/🔄/✅ + 컬럼 `approved`·`gate`·`open_gaps`·`needs_sim`·`next`·`notes`). 이게 상태 머신의 메모리다(에이전트 기억 아님).

1. 진행판을 읽는다. **파일이 없으면 develop-looping-process 초기 템플릿(9기능 전 행)을 만든다** — 이 기능 한 줄만 만들지 않는다(부분 표는 라우터를 헷갈리게 한다). 그다음 이 기능 행에서 시작.
2. **직렬 preflight.** 다른 기능이 in-flight(✅ 셀 있고 미완)면 멈추고 "먼저 <그 기능> 을 끝내라"고 보고한다 — 한 번에 한 기능만.
3. **재진입 상태 판정** (이 기능 행 P1/`approved`):
   - P1 ⬜/🔄 → 정상 진입. 아래 절차 1.1~1.4 를 (이어)쓴다. 시작 시 P1=🔄.
   - **P1 ✅ · `approved`=no → 승인 게이트에서 재개**(계획을 처음부터 다시 짜지 않는다). 산출물은 이미 있으니 사람에게 다시 올려 승인만 받는다. 승인나면 아래 "핸드오프"대로 `approved=yes`·`next=feature-implement` 를 기록하고 종료. **이 approved no→yes 기록은 feature-plan 의 몫이다**(라우터·다른 스킬이 아니라).
   - P1 ✅ · `approved`=yes → 이미 동결됨. 멈추고 "→ feature-implement" 라고 알린다.
4. 토대(Phase 0) 미완이나 잘못된 상태로 어긋나면 멈추고 사람에게 알린다. 억지로 진행하지 않는다.

## 절차 (순서 고정) — development-process.md §3

### 1.0 출처 대조 (조건부 — 다중 출처일 때만 발동, 기본 스킵)
발동 조건: 이 기능이 **Figma 외 별도 출처**(PM PDF·기획서 등)로도 존재하고 어느 게 SSOT 인지 선언 안 됐을 때. 설정 9기능처럼 출처가 Figma 하나면 **건너뛴다**(순수 오버헤드 — 안 도는 게 기본값).
- 산출(작게): ① 출처 우선순위(PDF vs Figma vs 사용자 명시지시 — 보통 갱신 Figma > 구 계획, 명시지시 최우선) ② 출처↔Figma 프레임 크로스워크 ③ **충돌·미결만**(일치는 안 적는다).
- 해소는 **기존 SSOT 에 흡수**(`ai_specs`·계획서·`<feature>.rois.json`) — 여기서 위젯→DS 매핑 표를 새로 만들지 않는다(1.3 과 중복·`understanding-doc-format.md` 의 "이중 기록 = 드리프트").
- **델타 재대조**: Figma 가 갱신돼 프레임이 증감하면 이 대조를 **바뀐 프레임만** 다시 돌려, 그게 이미 승인·동결된 계획의 가정을 흔드는지 본다(흔들면 State·Cubit·rois 변경이라 ⛔ 재승인 대상 — 조용히 반영 금지).
- 산출물이 다른 세션의 미커밋 SSOT 를 건드릴 상황이면 **patch 하지 말고 findings 문서로 넘긴다**(읽기 전용 핸드오프). 황금 예시: [`figma-92-delta-reconciliation.md`](../../../docs/renew-guide/impl/emotion-conversation/figma-92-delta-reconciliation.md)(감정대화 63→92 재추출이 계획의 deferred 9~15·가정 A2 재활성).

### 1.1 Figma 기능 파악 (실측, 눈대중 금지) + 위젯 ROI 분해·키 부여 (key-first)
figma-sync 스킬의 `extract_doc` 로 이 기능 화면을 실측한다 — 치수·색·간격·인터랙션을 `tree.json` ground truth 로 뽑는다(추측·눈대중 금지). 산출: 화면 목록 + 화면별 상태(빈/로딩/성공/실패/권한거부) + 탭→동작 매핑. webview 화면(의견·문의 외부 링크)은 Figma 정합 대상이 아니니 그 표시만.

이어서 **화면을 위젯 단위로 분해하며 각 ROI 에 `qa_key`·`importance`·`figma_bbox`(tree.json 실측)를 먼저 부여**한다
— 위젯 분해 = 키 부여 = ROI 정의 = 구현 단위가 한 번에 1:1 (구현 중 키 붙이기 아님). 기준은
[`understanding-doc-format.md §3`](../../../docs/renew-guide/impl/understanding-doc-format.md) 의 3질문
(누르나/시나리오 존재검증/독립 ROI 박스 → 키; group 기본, leaf 남발 금지; 중간지대는 importance 승격) —
산출을 기능당 1개 `docs/renew-guide/impl/settings/<feature>.rois.json`(기계 계약, 커밋 대상) 초안으로 적는다.
황금 예시 [`notification-setting.rois.json`](../../../docs/renew-guide/impl/settings/notification-setting.rois.json).

### 1.2 플로우 파악 (mermaid)
1.1 화면들을 mermaid `flowchart` 로 잇는다 — 화면 전이와 분기(성공→다음, 실패→토스트, 뒤로가기→폐기, 권한거부→재요청 등). 이게 1.4 QA 시나리오의 뼈대다. 사람이 한눈에 흐름을 검토할 수 있어야 한다.

### 1.3 상세 개발계획서 (Cubit·연동·DS 매핑)
[`understanding-doc-format.md`](../../../docs/renew-guide/impl/understanding-doc-format.md) §1~§5 형식으로 `docs/renew-guide/impl/settings/<feature>.md` 에, 그리고 승인 스펙 `ai_specs/<feature>.md`(템플릿 복사)에 다음을 못 박는다. 형식은 황금 예시 `account-main.md` 를 그대로 따른다.
- **Cubit / State**: 기본 4(Initial/Loading/Success/Failure) + 기능별 변형(`<Feature><Variant>`), Cubit **공개 메서드 시그니처**. ← 승인 후 동결 대상.
- **연동 사슬**: `repository → provider(remote/local) → apimanager` 호출 사슬, 주입할 디바이스 port(Biometric/Haptic/Link 등), 외부 의존(OAuth·hive·permission), 호출 엔드포인트.
- **발생 가능 `DoloErrorKind`** 와 UI 의 `actionKind` 분기(retry/contactSupport/openSettings/message/silent).
- **DS 컴포넌트 매핑**: 화면에 필요한 UI 프리미티브마다 [`component_registry.json`](../../../docs/design_system/component_registry.json) 에서 매칭 entry(`replacement`)를 **미리** 적는다(SnackBar→DoloToast, Switch→DoloToggle 등). 매칭 없으면 새 DS 컴포넌트를 제안·명시. 여기가 raw 위젯 재발명을 **설계 단계에서** 차단하는 자리 — Phase 4 코드리뷰까지 미루지 않는다.
- **위젯 ROI·qa_key 매핑**: §3 표(| 번호 | 위젯 | Figma 실측 | qa_key | importance | 구현 |)와 번호박스 이미지로
  1.1 의 `<feature>.rois.json` 을 **뷰로 렌더**한다(표를 SSOT 로 쓰지 않는다 — 계약은 rois.json). 구현(P2)은 이
  qa_key 를 계약대로 심고(그룹 ROI=`QaRegion`, DS 인터랙 위젯=기존 `ValueKey` — 같은 키 겹쳐 감싸기 금지),
  P2 끝 노출 preflight 는 qa_key 마다 확인하되 **blocker 미노출만 P2 미완** 판정. P3 visual-verify 가 이 키로 대조.

### 1.4 QA checklist + QA 시나리오
검증 기준을 **미리** 쓴다(Phase 4·5 가 이걸 그대로 실행한다). 계획서 §QA 와 `scenario-matrix.md` 에 축적.
- **QA checklist**: 화면별 조작 점검표(이 버튼→이 화면, 이 토글 ON→이 영역 펼침, 빈/에러 상태 렌더 등).
- **QA 시나리오**: 유저 시나리오(정상 흐름) + 엣지 시나리오(강제종료·백그라운드 전환·네트워크 실패·권한 거부·재진입·딥링크)를 Given-When-Then 으로. 1.2 플로우의 각 분기가 최소 한 시나리오가 되게.

### 끝 — 사람 승인 게이트 (하드)
한국어 산출물(계획서·스펙)은 humanize-korean 으로 AI 티 자가검열한 뒤 사람에게 올린다. 승인받으면 **State·Cubit 공개 API + ROI 계약(`<feature>.rois.json` 의 qa_key 집합·importance) 동결**. 중간지대 위젯(키 애매)의 승격 여부도 이 승인에서 사람이 확정한다. 승인 전엔 Phase 2 시작 금지(이 스킬은 코드를 짜지 않는다). 반려면 1.1~1.4 로 되돌아가 고치고 재승인.

## 산출물 / 핸드오프

| 산출 | 경로 |
|---|---|
| 출처 대조 findings (조건부 1.0) | `docs/renew-guide/impl/<area>/<feature>-*-reconciliation.md` — **다중 출처일 때만**, 충돌·미결만(스펙 아님·핸드오프) |
| 이해도 문서 §1~§5 | `docs/renew-guide/impl/settings/<feature>.md` |
| 승인 스펙(동결 계약) | `ai_specs/<feature>.md` — qa_key **목록+목적만**(좌표 금지 — 이중 기록 = 드리프트) |
| **위젯 ROI 계약(기계 SSOT)** | `docs/renew-guide/impl/settings/<feature>.rois.json` — 기능당 1개, **커밋 대상**(docs/designs 아님!) |
| QA checklist + 시나리오 | 계획서 §QA · `docs/renew-guide/impl/settings/scenario-matrix.md` |
| Figma 실측물 | `tree.json`/PNG — `docs/designs/**`(gitignore, 커밋 금지) |

진행판 갱신(마지막 절차, 반드시) — 세 상태를 구분한다:
- **작성 중**(1.1~1.4 미완): 이 기능 P1 셀 🔄, `approved=no`, `next=feature-plan`.
- **산출물 완성·승인 대기**(1.1~1.4 다 썼고 사람 사인만 남음): 이 기능 P1 셀 **✅**, `approved=no`, `next=사람 승인 대기`. 이게 오케스트레이터의 "P1 ✅ · approved≠yes → 멈춤" 라우팅 상태다. 세션이 여기서 끊겨도 재진입이 계획을 처음부터 다시 짜지 않고 승인 게이트에서 재개한다.
- **승인 후**: 이 기능 P1 셀 ✅, `approved=yes`, `next=feature-implement`. develop-looping-process 는 `approved=yes` 를 봐야만 feature-implement 로 라우팅한다(하드 게이트).

## 강제 / 금지 (가드)

- **승인 없이 Phase 2 없다(하드 게이트).** `approved=yes` 를 진행판에 기록하기 전엔 어떤 코드도 짜지 않고 feature-implement 를 부르지 않는다. State·Cubit 공개 API 는 승인 순간 동결 — 이후 바꾸려면 스펙 재승인(UI 병행작업이 이 계약에 의존).
- **실측은 tree.json ground truth, 눈대중 금지.** 치수·색은 `extract_doc` 값만. 화면을 눈으로 보고 짐작한 숫자를 계획서에 넣지 않는다.
- **DS 매핑 없는 프리미티브 금지.** 계획서는 raw 위젯 재발명을 설계에서 미리 막는 자리다 — 필요한 UI 프리미티브마다 `component_registry.json` replacement 를 적거나 새 DS 제안을 단다. 빈칸으로 두고 구현으로 넘기지 않는다.
- **출처 대조는 조건부·델타 (1.0).** 다중 출처(Figma+PDF 등)일 때만 돈다 — 단일 출처면 스킵. 돌더라도 산출은 **충돌·미결만**이고 위젯→DS 매핑을 재작성하지 않는다(1.3 이 SSOT). Figma 재갱신 땐 **델타만** 대조하고, 동결 계획을 흔드는 변경은 조용히 반영하지 말고 ⛔ 재승인으로 올린다.
- **키 없는 ROI 금지(key-first).** §3 표의 위젯마다 qa_key 를 정하거나(3질문 기준) 명시적으로 `-`(키 없음)로 판정한다 — 빈칸으로 구현에 넘기지 않는다. 과키잉도 금지: leaf/장식엔 안 붙인다(설정류 화면당 8~20개 감).
- **자기 승인 금지.** "됐다" 는 사람이 판정한다. 이 스킬이 스스로 승인 처리해 다음 Phase 로 넘기지 않는다.
- **파괴적/전역 결정은 계획에만, 실행은 안 함.** 회원탈퇴 최종 제출·전역 토큰 변경 같은 파급 큰 결정은 계획서에 적고 승인받되 이 Phase 에서 실행하지 않는다.
- **메타 루프(§12).** 계획 단계에서 반복되는 결함 패턴(같은 raw 위젯 재발명, 같은 엣지 누락)을 발견하면 코드가 아니라 하네스(템플릿·레지스트리·lint·이 스킬)를 고칠 수 있나 묻고, 가능하면 다음 기능엔 자동 차단되게 되먹인다.
