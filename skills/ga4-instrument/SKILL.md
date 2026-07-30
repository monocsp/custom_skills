---
name: ga4-instrument
description: "특정 기능의 특정 지점에 GA4 분석을 마찰0·실수0으로 심는다. 메인 에이전트가 Agent 툴로 4개 서브에이전트(flow-analyzer → placement-advisor → safety-checker → verifier)를 순차 스폰해 ① 플로우 분석 ② 어디에 무엇을 심을지 의견 ③ PII·레이어·네이밍·5중 가드 검증 ④ 구현 후 게이트·계약테스트·DebugView 확인까지 돈다. 하네스 단일 출처(analytics-ga4-architecture/-implementation-plan/-decisions/event-naming)를 강제한다. 트리거 — \"X 기능의 Y 지점에 GA4 달아줘\", \"여기에 분석 이벤트 심어줘\", \"이 화면/버튼 GA4 계측\", \"애널리틱스 붙여줘\". 또는 기획자 CSV(트래킹플랜)를 주며 \"이 표/CSV 대로 GA4 심어줘\"(모드 B — CSV 검증→코드생성→등록, 예외처리 포함)."
---

# /ga4-instrument — GA4 계측을 4스테이지 서브에이전트로 심기

> 정책: 이 repo 의 GA4 는 **재발명 금지**다. 이벤트 카탈로그·validator·5중 가드·네이밍·PII 규칙은
> 이미 4개 문서에 굳어 있다(아래 §재료). 이 스킬은 그 규칙을 **강제·적용**할 뿐, 새 패턴을 만들지 않는다.
>
> 정책: 이 4스테이지(flow-analyzer→placement-advisor→safety-checker→verifier)는 **비투표 순차 특화 파이프라인**이라
> 공유 `isolated-adversarial-verifier`(P5·P6 용 다수결 워커)를 쓰지 않는다 — **메인 에이전트가 Agent 툴로 서브에이전트를 직접 스폰**해
> 돌린다(각 스테이지 프롬프트는 이 본문에 내장). `.claude/workflows` 는 없다.
> 스테이지 사이 산출물은 메인 에이전트가 받아 다음 스테이지 프롬프트에 끼워 넣는다.
>
> 정책: 이 스킬이 도는 동안 **git 상태 변경 금지** — `checkout`/`switch`/`branch`/`commit`/`stash` 안 한다.
> 분석 스테이지(①②③)는 **Read 전용**. 구현은 ③ 승인 후 메인 에이전트가 하고, ④ 가 검증한다.

## 언제 도나 — 두 입력 모드

- **모드 A (자유형식):** "X 기능의 Y 지점에 GA4 달아줘" · "이 화면/버튼 계측" · "분석 이벤트 심어줘". → 스테이지 ①(flow-analyzer)부터.
- **모드 B (CSV 트래킹플랜):** 기획자가 채운 CSV 를 주며 "이 표/CSV 대로 GA4 심어줘". → 아래 **§입력 모드 B** 절차(스테이지 ①을 CSV 파싱+검증으로 대체하고, 이벤트별로 ②③④).

어느 쪽이든 골격은 같다: **검증 → 배치(어디에 무엇을) → 구현 → 게이트.** 대상이 모호하면 1줄만 되묻는다.

## 입력 모드 B — CSV 트래킹플랜 (기획자 표 → 등록)

배경·포맷은 [`docs/renew-guide/analytics-ga4/planner-pipeline-plan.md`](../../../docs/renew-guide/analytics-ga4/planner-pipeline-plan.md)
(§2.2 포맷 · §2.4 lint · §2.5 흐름 · §2.10 교차검증). 기획자 칸(`무엇을`·`언제`·`왜 알고 싶나`·`같이 알고 싶은 것`)은
평문이고, 기술 칸(`기능`·`종류`·`이벤트명`·`파라미터`)은 개발자/AI가 채운다.

### 모드 B 절차

**B0. CSV 확보** — 경로/첨부 확인. 없으면 → '예외: CSV 없음'.

**B1. 검증(가드 사전판) — 통과해야 진행.**
```
dart run tool/analytics_plan/plan_tool.dart <csv>
```
종료코드 1(위반)이면 **멈춘다.** 어느 행·무슨 위반(PII 키·자유텍스트·예약어·형식·40자 초과)인지 + 안전대안
(예: `comment_text`→`has_comment`, 감정 원값→`mood_scale_bucket` 버킷)을 보고하고 **고친 CSV를 다시** 받는다.

**B2. 개발자 칸 채우기(비었으면).**
- `이벤트명` 비면 AI가 `기능_action`(snake·≤40·예약어 아님)으로 작명.
- `파라미터` 비면 `같이 알고 싶은 것`(평문)을 `키=후보1|후보2`로 번역 — **후보 필수**(자유텍스트 금지), 감정=버킷, bool→`1`/`0`. 허용목록(6키) 밖 키는 `new_params` 로 표시(→ `AnalyticsParams` 등록 대상).
- 채운 CSV로 **B1 재검증.**

**B3. 이벤트별 배치·안전 검증 — 스테이지 ②③ 재사용.**
CSV 각 행을 결정트리로 분류(행동/화면/탭)하고, 스테이지 ②(placement-advisor)·③(safety-checker) 프롬프트에
**그 행(무엇을·언제·기능·파라미터)**을 넣어 돌린다. ③ 가 BLOCK 이면 그 이벤트만 멈추고 보고(주로 PII·레이어).
**발화 위치(cubit·분기)가 `언제`로 안 잡히면 1줄 되묻는다.**

**B4. 구현 — 기존 §구현 절차.** 행동=클래스+(새 키→`AnalyticsParams`)+cubit `track()`(+미주입이면 module/app 배선)+`allEvents`+blocTest · 화면=GoRoute `name:` 만 · 탭=공유 `UiTapEvent`.

**B5. 검증 — 스테이지 ④ verifier.** 게이트 + 계약·완전성 + blocTest + grep. 끝나면 CSV `status`를 `implemented`로.

### 모드 B 예외 처리

| 상황 | 처리 |
|---|---|
| **CSV 없음** | "기획자 표(CSV) 주세요 — 양식은 `ai_specs/analytics/dolomood_app_events_reference.csv` 참고". 단발 1개면 모드 A(자유형식) 전환 제안. |
| 필수 헤더 칸(`기능`·`종류`·`이벤트명`·`파라미터`) 빠짐 | 도구가 알려줌 → 칸 보완 요청. |
| 검증 위반(PII·자유텍스트·예약어·형식·한도) | **멈춤.** 행+위반+안전대안 보고 → 고친 CSV 재요청(B1). 절대 위반 채로 구현 안 함. |
| 개발자 칸 비어 있음(기획자만 채움) | AI가 B2로 채움. 발화위치 애매하면 1줄 되물음. |
| 이미 있는 이벤트(중복) | `allEvents`·`<f>_events.dart` 실측 → 중복이면 스킵하고 보고. |
| cubit 이 `AnalyticsService` 미주입 | `<f>_module.dart`+`app.dart` 배선까지(구현 절차). |
| 한 CSV에 이벤트 여러 개 | 이벤트별로 B3~B4 반복. |
| GA4 콘솔 설정(`key_event`·맞춤측정기준·user property) | 코드 아님 — "콘솔에서 사람이 켜야 함(소급 불가)"을 PR 본문 체크리스트로 남김. |

## 하네스 재료 (단일 출처 — 스테이지가 참조할 정확한 섹션)

모든 스테이지는 아래를 ground truth 로 삼는다. 눈대중·기억 금지 — 규칙은 항상 이 문서들이 SSOT.

| 재료 | 경로 | 무엇을 |
|---|---|---|
| 결정 트리 · 5중 가드 · recipe | `docs/renew-guide/analytics-ga4/implementation-plan.md` **§3**(§3.0 결정트리, §3.4 5중 가드) | 어디에 무엇을 심나 / 어떤 가드가 어떤 실수를 잡나 |
| Q1~Q7 확정 결정 | `implementation-plan.md` **§1 표** + `decisions.md` | 카탈로그 위치·ui_tap 주체·동의·login_method·dwell 정책 |
| 새 이벤트 추가 워크플로(6스텝) + validator | `architecture.md` **§9** | 클래스 1개 추가 절차 + `_validate` 규칙 |
| 아키텍처(레이어·카탈로그·DI·observer·user property) | `architecture.md` **§5·§6·§7·§8·§12** | 발화 주체·screen_view 경계·체류시간 |
| 네이밍 · 파라미터 · PII · user property 단일출처 | `event-naming.md` **전문**(§1 이름·§3 파라미터·§4 한도·§5 예약어·§6 PII·§7 user property·§9 체크리스트) | 모든 이름/키/값 판정 |

코드 seam(현 상태 — Phase 3 시점 스냅샷. 스테이지 ①이 항상 재실측):

이미 깔린 것(재발명 금지 — grep 으로 실측 후 그대로 쓴다):
- `lib/core/telemetry/analytics_service.dart` — `abstract interface class AnalyticsService`(`track`/`setEnabled`/`setConsent`/`setUserId`/`setUserProperty`/`navigatorObserver`).
- `lib/core/telemetry/analytics_event.dart` — `abstract base class AnalyticsEvent`(`name`/`params`). **서브클래스 4개 존재**: `events/ui_tap_event.dart`(공통 `UiTapEvent`), `feature/auth/analytics/auth_events.dart`(`LoginStart`/`LoginSuccess`/`LoginFailureEvent`).
- `lib/core/telemetry/analytics_event_validator.dart` — **validator(가드 ⑤ 코어)**: name 형식/40자/예약접두사/REPLACE_ME, params allowlist+PII 키 denylist+`String|num`.
- `lib/core/telemetry/analytics_params.dart` — **키 allowlist 6개**(`feature`/`source`/`method`/`result`/`error_kind`/`element`). 새 키는 여기 + `all` 에 등록.
- `lib/core/telemetry/firebase_analytics_service.dart` — 실 SDK 구현. `track` 은 try/catch 자기흡수(throw 안 함) — `unawaited` 안전의 전제.
- `lib/core/telemetry/noop_analytics_service.dart` — web/dry-run/테스트 무동작.
- `lib/app/app.dart` — `RepositoryProvider<AnalyticsService>.value(value: analytics)` 노출(cubit 이 `context.read` 로 받음).
- `lib/app/router/app_router.dart` — **`observers: [analytics.navigatorObserver()]` 배선 완료, GoRoute `name:` 8개 전부 부여됨** → screen_view 작동 중. 새 라우트는 `name:` 만 채우면 됨(`require_goroute_name` lint 강제).
- 가드: `harness_lints` 의 `no_firebase_analytics_outside_telemetry`·`require_goroute_name`(custom_lint), `scripts/local_ci.sh`(firebase 격리 grep), `scripts/verify_lints.sh`(fixture), `test/core/telemetry/analytics_event_contract_test.dart`(계약테스트 `allEvents` + **완전성 검사**: 미등록 이벤트는 게이트가 막음).
- 카탈로그 문서(사람용 거울): `docs/renew-guide/analytics-ga4/event-catalog.md`.

아직 없는 것(필요할 때 신설):
- `lib/core/telemetry/analytics_user_property.dart`(user property key enum — 인터페이스엔 `setUserId`/`setUserProperty` 있으나 typed wrapper 미생성).
- 계측 대상 feature 의 `lib/feature/<f>/analytics/<f>_events.dart`(auth 외엔 그 feature 계측 시 생성).

> **현 단계 주의:** 이 repo 는 GA4 Phase 가 진행 중이다. 스테이지 ①은 항상 위 seam 을 grep/Read 로
> **실측**해 "이미 있는 것 vs 신설할 것"을 그 시점 기준으로 다시 확인한다(문서의 GAP 표는 스냅샷이라 드리프트 가능).

## 결정 트리 (모든 스테이지가 공유하는 1장)

`implementation-plan.md §3.0` 의 트리. 대상 지점을 이 셋 중 하나로 분류하는 게 ①②의 핵심:

```
새 상호작용에 분석을 붙여야 하나?
├─ ① 화면에 "들어왔다" (라우트 진입/페이지 전환)
│     → 아무 이벤트도 안 짠다. observer 자동 screen_view. GoRoute 에 name: 만.
├─ ② 의미 있는 액션 (저장 성공/실패·가입완료·에러 — result/error_kind 가 의미 있는 것)
│     → cubit 이 typed 이벤트 발화: 이벤트클래스 1개 + cubit 분기 unawaited(track) + 계약테스트 등록.
└─ ③ 평범한 탭 (설정 아이콘·닫기·메뉴 — 결과 없음)
      → 새 이벤트 안 만든다. 공유 UI 인프라(DS)가 ui_tap + params (500종 한도 보호).
```

## 절차 — 메인 에이전트가 Agent 툴로 4스테이지 순차 스폰

각 스테이지는 **별도 서브에이전트 1개**로 스폰한다(Agent 툴, `general-purpose` 류). 프롬프트는 아래 블록을
**그대로** 복사해 머리에 `[대상] feature=<…>, 지점=<…>` 를 채우고, **직전 스테이지의 출력을 통째로** 붙인다.
서브에이전트 결과(텍스트)를 메인이 받아 다음 스테이지로 넘긴다. ①②③ 은 Read 전용, ④ 만 실행을 검증한다.

스테이지 게이트: **③ safety-checker 가 BLOCK 을 내면 멈춘다.** 메인이 ② 안을 고쳐 ③ 을 다시 돌린다.
PASS 가 나야 구현 → ④.

---

### 스테이지 ① flow-analyzer (스폰: 서브에이전트 1)

목적: 대상 feature 의 플로우를 상세 분석해 ②가 판단할 재료를 만든다. **코드를 안 바꾼다(Read 전용).**

> 서브에이전트 프롬프트(이 블록째 복사):
>
> ```
> 너는 GA4 계측의 flow-analyzer 다. 대상: feature=<FEATURE>, 계측 지점=<지점 설명>.
> repo: 이 워킹디렉토리. git 상태 변경 금지(Read/Grep 전용, checkout/commit 금지).
>
> 할 일 — 아래를 실측(Read/Grep)해 보고하라:
> 1. 레이어 플로우: lib/feature/<FEATURE>/ 의 ui_page → cubit(메서드·상태union) → repository(ApiResult<T>) →
>    provider 를 따라가며, 대상 지점이 흐름의 어디에 해당하는지 지목한다. (cubit 의 public 메서드 시그니처를
>    그대로 인용 — ②가 발화 자리를 정확히 찍게.)
> 2. 사용자 여정: 사용자가 이 지점에 "어디서 들어와(source) 무엇을 하고(action) 어디로 가나". 진입 경로
>    후보(home/push/deep_link/retry_button 등)를 적는다.
> 3. 상태·분기: cubit 의 성공/실패 분기를 나열한다. 실패는 DoloError 의 kind/actionKind 가 무엇이 될 수 있는지
>    (error.kind.name / actionKind.name 후보)까지. 재진입 가드(if (state.isLoading) return) 위치도.
> 4. 의미 있는 액션 후보: 이 지점에서 "기록할 가치 있는 행동"을 결정트리 ①/②/③ 로 분류한다(화면진입/의미액션/평범탭).
>    각 후보에 대해: 분류 + 이유 + (②면) 성공/실패 양쪽 발화 필요 여부.
> 5. 데이터 민감도 스캔: 이 플로우가 다루는 값 중 PII·정신건강 자유텍스트(이메일·닉네임·토큰·memo·diary·
>    mood 원문·raw backend msg)가 무엇인지 미리 식별한다(③ 안전검증의 입력).
> 6. 현 seam 실측: 이 feature 의 cubit 이 이미 AnalyticsService 를 주입받는지, 라우트에 name:/observers 가 있는지,
>    lib/feature/<FEATURE>/analytics/ 가 있는지 grep 으로 확인해 "이미 있음/신설" 을 표로.
>
> 참조(읽고 따르라): docs/renew-guide/analytics-ga4/implementation-plan.md §3.0(결정트리),
>   architecture.md §5(레이어)·§7(발화 주체), event-naming.md §6(PII).
>
> 출력: 위 1~6 을 간결한 구조로. 추측 금지 — 실측한 파일:라인 근거를 붙여라. 코드는 안 바꾼다.
> ```

메인은 ①의 출력을 그대로 보관해 ②에 넘긴다.

---

### 스테이지 ② placement-advisor (스폰: 서브에이전트 2)

목적: ①을 받아 **결정 트리대로** "어디에 무엇을(이벤트명·params·user property)" 심을지 구체안을 낸다.

> 서브에이전트 프롬프트(머리에 ①출력 전체를 붙여 복사):
>
> ```
> 너는 GA4 계측의 placement-advisor 다. 대상: feature=<FEATURE>, 지점=<지점 설명>.
> 아래는 flow-analyzer(①)의 출력이다:
> <① 출력 전체>
>
> 할 일 — 결정 트리(implementation-plan §3.0)로 각 후보를 닫고 구체 배치안을 내라:
> A. 분류 확정: 각 후보를 ①화면진입 / ②의미액션 / ③평범탭 중 하나로 못 박는다.
>    - ①화면진입 → 이벤트 0개. "GoRoute 에 name:'<page>_page' 추가 + observer 배선(미배선이면)" 만 적는다
>      (architecture §6). cubit 이 ScreenOpened 류를 또 쏘지 말 것(중복 = 데이터 2배, §6.3).
>    - ②의미액션 → 이벤트 클래스 1개를 설계한다(아래 형식). 성공/실패 양쪽 발화 여부 명시.
>    - ③평범탭 → 새 이벤트 금지. 공유 UI 인프라의 UiTapEvent(feature/location/element params)로. (Q2 동결:
>      feature page 가 FirebaseAnalytics 직접 호출 금지 — context.read<AnalyticsService>().track(UiTapEvent(...)) 만.)
> B. 이벤트 설계(②마다): 다음을 표로 제시.
>    - name: feature_action, snake_case, ≤40자 (event-naming §1). 화면진입이면 이 칸 없음.
>    - 발화 위치: 어느 cubit 의 어느 메서드, 성공/실패 어느 분기. unawaited(_analytics.track(...)).
>    - params: 키는 AnalyticsParams.* 상수만(리터럴 금지). 공통 어휘(feature/source/location/element/method/
>      result/error_kind/action_kind/origin) 우선(event-naming §3). 값은 String|num 만(bool→1/0). PII·감정원문
>      금지 — 감정은 mood_scale_bucket(low|mid|high)만. error_kind/action_kind 는 DoloError enum .name.
>      → 새 키가 필요하면 "AnalyticsParams 에 등록할 키" 로 따로 표시(allowlist 갱신 대상).
>    - 카탈로그 위치(Q1 동결): 공통이면 lib/core/telemetry/events/, feature 고유면
>      lib/feature/<FEATURE>/analytics/<FEATURE>_events.dart.
>    - 계약테스트 등록: test/core/telemetry/analytics_event_contract_test.dart 의 allEvents 리스트에 추가할 인스턴스.
> C. user property(해당 시): event-naming §7 의 7개 키(auth_state/login_method/push_opt_in/app_flavor/
>    app_locale/notification_enabled/onboarding_done)만. 값은 문자열(bool 금지: push_opt_in='granted'|'denied').
>    소유 cubit·발화 시점 지목(Q4: login_method=마지막 성공, AuthCubit 소유).
> D. 한도 점검: 이벤트당 params ≤25, 새 이벤트가 500종 한도에 합당한지(버튼마다 새 이벤트 금지 → ui_tap 으로).
>
> 참조: implementation-plan §3.0/§3.3, architecture §9(새 이벤트 6스텝)·§5.4(카탈로그·AnalyticsParams), event-naming 전문.
> 출력: A~D 를 구현 가능한 구체안으로(파일경로·클래스명·params 표·발화 위치 라인 후보). 코드는 안 바꾼다.
> ```

메인은 ②의 출력(배치안)을 보관해 ③에 넘긴다.

---

### 스테이지 ③ safety-checker (스폰: 서브에이전트 3)

목적: ②안을 적대적으로 검증한다. **하나라도 걸리면 BLOCK** — 메인이 ②를 고쳐 재검증.

> 서브에이전트 프롬프트(②출력 전체를 붙여 복사):
>
> ```
> 너는 GA4 계측의 safety-checker 다. 아래는 placement-advisor(②)의 배치안이다:
> <② 출력 전체>
> (참고로 ①flow-analyzer 의 민감도 스캔: <①의 5번 출력>)
>
> 할 일 — 다음을 전수 검증하고 항목마다 PASS/BLOCK + 사유를 내라. 하나라도 BLOCK 이면 전체 결론 = BLOCK:
> 1. PII·정신건강 누출(event-naming §6): params/값/user property 어디에도 email·name·nickname·token·
>    memo·diary·mood 원문·raw backend msg·자유입력이 없나. 감정은 버킷(mood_scale_bucket)만인가. PII 키
>    denylist 에 걸리는 키 0인가 — **denylist 의 SSOT 는 `lib/core/telemetry/analytics_event_validator.dart`
>    의 `_piiDenylist`**(목록을 여기 옮겨 적지 말 것 — 드리프트 방지, 그 파일을 Read 해 대조).
> 2. 레이어 위반(architecture §7·§5): UI 가 직접 발화하지 않나(의미액션은 cubit 발화, 평범탭만 공유 UI 의 ui_tap).
>    feature 코드가 firebase_analytics 를 직접 import 하지 않나(반드시 AnalyticsService.track 경유). cubit 이
>    repository 우회로 analytics 를 받되 그건 무상태 부수효과 port 예외로 허용되는 범위인가.
> 3. 네이밍·한도(event-naming §1·§4·§5): name 이 ^[a-z][a-z0-9_]*$, ≤40자, feature_action 인가. 예약 접두사
>    (_/firebase_/ga_/google_/gtag.) 회피했나. 예약 이벤트명(screen_view/session_start/first_open/error 등)
>    재정의 안 했나. GA4 추천 이벤트(login/share 등)에 이미 있는 걸 중복 정의하지 않았나. params ≤25, 키 ≤40자,
>    문자열 값 ≤100자. user property ≤25개·이름 ≤24자·값 ≤36자.
> 4. screen_view 중복(architecture §6.3): 화면진입을 cubit 이벤트로 또 쏘지 않나(observer 전담). 비-라우트
>    표면(바텀시트/탭전환)만 예외 typed event 인가.
> 5. 성능·안전: 발화가 unawaited fire-and-forget 인가(UI 전이 블록 금지). track 구현 자기흡수(throw 안 함)에
>    의존하는 게 맞나. dwell 을 넣었다면 프레임마다 일 안 하고 Clock 주입·<1000ms 컷·flutter 의존 0 인가(Q6).
> 6. 5중 가드 통과(implementation-plan §3.4): ① 키가 AnalyticsParams.* 상수인가(리터럴 0) ② feature 의
>    firebase_analytics import 0(custom_lint/grep 대상) ③ 값 String|num(bool 드롭 트랩 회피, hasNote?1:0)
>    ④ 계약테스트 allEvents 리스트 등록 예정인가 ⑤ blocTest 로 cubit 발화·PII-없음 검증 예정인가.
>    REPLACE_ME 잔존 이벤트명이 없나(scaffold 유래).
>
> 참조: implementation-plan §3.4(가드)·§6(리스크), architecture §9(validator)·§10(PII 강제), event-naming §4·§5·§6.
> 출력: 1~6 각 PASS/BLOCK + 사유. 마지막 줄에 "RESULT: PASS" 또는 "RESULT: BLOCK — <고칠 것 목록>".
> ```

③ 가 BLOCK 이면 메인은 ②를 수정(또는 ②서브에이전트 재스폰)해 ③을 다시 돌린다. **PASS 후에만** 구현.

---

### 구현 (메인 에이전트가 ②③ 승인안대로 — 서브에이전트 아님)

③ PASS 후 메인이 직접 구현한다(이때만 파일 쓰기 허용). architecture §9 의 6스텝을 따른다:

1. (②면) 이벤트 클래스 추가 — `lib/feature/<f>/analytics/<f>_events.dart`(공통이면 `core/telemetry/events/`).
   params 키는 `AnalyticsParams.*` 상수만, 값 `String`/`num`(bool→`1`/`0`). 새 키는 `AnalyticsParams` + `all` 집합에 먼저 등록.
2. cubit 분기에서 `unawaited(_analytics.track(XxxEvent(...)))`. 성공/실패 분기에 `result`/`error_kind` 포함.
   cubit 이 `AnalyticsService` 미주입이면 `<f>_module.dart`의 `<f>Blocs({required AnalyticsService analytics})` +
   `app.dart` 호출처까지 배선(`HapticPort` 류 직접 주입, step-down 예외).
3. (①면) `GoRoute` 에 `name:'<page>_page'` 추가. `observers:` 미배선이면 `buildAnalyticsRouteObserver` 배선(architecture §6).
4. (③평범탭이면) 공유 UI 인프라가 `context.read<AnalyticsService>().track(UiTapEvent(...))`. feature page 직접 발화 금지.
5. 계약테스트 `test/core/telemetry/analytics_event_contract_test.dart` `allEvents` 에 인스턴스 등록.
6. cubit `blocTest` 에 `RecordingAnalytics` fake 로 발화·PII-없음 verify 추가.

---

### 스테이지 ④ verifier (스폰: 서브에이전트 4 — 구현 후)

목적: 구현이 실제로 동작하는지 독립 검증. **자기 구현 자평 금지 — 별도 서브에이전트로 적대 검증.**

> 서브에이전트 프롬프트(②안 + 구현 변경 요약을 붙여 복사):
>
> ```
> 너는 GA4 계측의 verifier 다. 메인이 아래 안대로 구현했다:
> <② 승인안 요약> / <변경된 파일 목록>
> repo: 이 워킹디렉토리. git 상태 변경 금지.
>
> 할 일 — 실제로 잘 됐는지 검증하고 PASS/FAIL 을 내라:
> 1. 게이트 green: 다음을 실행해 결과를 보고. (codegen 모델 변경 있었으면 build_runner 먼저.)
>      dart format . && flutter analyze && dart run custom_lint && flutter test
>    실패 줄을 그대로 인용. (전체가 무거우면 최소 flutter analyze + 해당 feature/telemetry 테스트.)
> 2. 계약테스트: test/core/telemetry/analytics_event_contract_test.dart 가 새 이벤트를 포함해 green 인지.
>    이벤트명 ≤40·정규식·예약접두사·allowlist·String|num·REPLACE_ME-reject 가 실제로 통과/차단되는지.
> 3. cubit blocTest: 해당 feature 의 cubit_test 가 RecordingAnalytics 로 "올바른 이벤트 발화 + PII 없음
>    (containsKey('memo') isFalse 류)"을 검증하는지.
> 4. 가드 grep 회귀: lib/feature/ 에서 firebase_analytics import 0건인가
>      grep -rn "package:firebase_analytics" lib/feature/   → 0건이어야
>    화면 계측이었으면 라우트에 name:/observers: 가 실제로 들어갔는지 grep.
> 5. DebugView 체크리스트(런타임 — 실행 가능하면): dev 빌드는 ENABLE_ANALYTICS=false 라 SDK 수집은 꺼지나
>    track 호출 자체는 흐른다. 눈으로 흐름을 보려면 DevLoggingAnalytics(있으면)/로그로 확인. 실기 DebugView 는
>    prod 토글/디버그 플래그(adb setprop debug.firebase.analytics.app / -FIRDebugEnabled)로 확인하는 절차만 안내
>    (이 스킬에서 prod 빌드 강행하지 말 것 — 절차만 체크리스트로).
>
> 참조: architecture §11(테스트)·§13(토글 검증)·§3(DebugView), implementation-plan §3.4(가드)·Phase3 DoD.
> 출력: 1~5 각 PASS/FAIL + 근거(명령 출력 발췌). 마지막 줄 "RESULT: PASS" 또는 "RESULT: FAIL — <남은 것>".
> ```

④ 가 FAIL 이면 메인이 고치고 ④ 를 다시 돌린다. PASS 면 완료.

## 완료 기준 (DoD)

- [ ] ③ safety-checker RESULT: PASS (PII·레이어·네이밍·screen_view·5중 가드 전부 통과).
- [ ] ④ verifier RESULT: PASS (게이트 green + 계약테스트 + blocTest + grep 회귀).
- [ ] 의미액션이면: 이벤트 클래스 1개 + cubit unawaited(track) + 계약테스트 등록 + blocTest. 화면이면: GoRoute `name:` + observer. 평범탭이면: 공유 UI `UiTapEvent`.
- [ ] `lib/feature/` 에 `firebase_analytics` 직접 import 0. params 키 전부 `AnalyticsParams.*` 상수. 값 `String`/`num`.
- [ ] PII·정신건강 자유텍스트 0(감정은 버킷만). 화면진입 중복 발화 0.

## 주의

- 분석 스테이지(①②③)는 **Read/Grep 전용**. 구현은 ③ PASS 후 메인만, ④ 가 검증.
- 규칙 충돌·모호 시 항상 4개 재료 문서가 SSOT — 이 스킬 본문이 아니라 그 섹션을 인용해 판정한다.
- 새 deps 금지(`firebase_analytics` 만). 멀티백엔드 fan-out 안 함(Q7 — 인터페이스 분리로 확장만 열려 있음).
- 한국어 보고/PR 본문을 쓰면 `humanize-korean` 으로 AI 티 자가검열. PR 은 `pr` 스킬(local_ci ALL GREEN 강제).
