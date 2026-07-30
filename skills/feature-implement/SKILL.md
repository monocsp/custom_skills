---
name: feature-implement
description: "Phase 2 — 승인된 계획서·스펙을 TDD(RED→GREEN)로 실제 코드로 채워 게이트 초록까지 간다. 기능 구현·코드 작성을 요청하면 'Phase 2'·'TDD'·레이어명을 명시 안 해도 이 스킬을 쓴다 — model·provider·repository·cubit+state·ui 를 ui→cubit→repository→provider→apimanager 한 단계씩(DS-first·순수 Dart·screenutil) 만들고 module 을 app.dart 에 배선한다. 계획 수립(Phase 1)은 feature-plan, 시각대조는 visual-verify, QA 리뷰는 feature-runtime-qa, GA4 계측은 ga4-instrument. 트리거 — '이 기능 구현해줘', 'Phase 2 시작', '계획 승인됐으니 cubit·provider 만들어줘', 'bloc_test RED 부터 짜서 구현까지', '레이어 채우고 게이트 초록까지'."
---

# /feature-implement — 승인된 계획을 TDD 로 채워 게이트 초록까지

> 정책: 이 스킬이 도는 동안 git 상태 변경 금지 — checkout/switch/branch/commit/stash/push 안 한다. 작업 브랜치 feat/settings 유지.
> 정책: 범위는 부탁받은 기능·이 Phase 만. 새 디바이스·도구·능동 확장 전 보고 후 멈춘다.
> 정책: 자기 작업을 자기가 "됐다" 판정 금지 — 검증은 격리 에이전트 2~3 + codex 다수결(자평 금지).

이 스킬은 구현 스킬이다. 산출물의 옳고 그름은 다음 Phase(3·4·5)의 적대 검증이 가른다 — 여기서는 게이트 초록만 자기 판정한다.

## 언제

- 한 기능의 **Phase 1(이해·계획)이 사람 승인**을 받아 State·Cubit 공개 API 가 동결된 뒤.
- 입력: `ai_specs/<feature>.md`(승인 스펙) + `docs/renew-guide/impl/settings/<feature>.md`(§1.3 개발계획·연동·DS 매핑 / §1.4 QA 수용조건) + `docs/renew-guide/impl/settings/<feature>.rois.json`(위젯 ROI 계약 — qa_key·importance·figma_bbox, P1 승인으로 동결).
- 마스터 프로세스 = [`development-process.md §4 Phase 2`](../../../docs/renew-guide/impl/settings/development-process.md). 앱 규칙 = [`AGENTS.md`](../../../AGENTS.md) (Feature generation · Architecture invariants · Error contract). 구조 참고 = `tool/harness_reference/example_auth/`.

## 선행 조건 (들어오기 전)

진행판 `docs/renew-guide/impl/settings/develop-looping-process-status.md` 에서 이 기능 행을 읽는다.

- **P1 셀이 ✅ 이고 `approved=yes` 여야** 들어온다. 아니면 멈추고 "Phase 1 미완/미승인 — /feature-plan 먼저" 로 알린다.
- **직렬 preflight.** 다른 기능이 in-flight(✅ 셀 있고 미완)면 멈추고 그 기능을 먼저 끝내라고 보고한다 — 한 번에 한 기능만.
- 스펙·계획서에 State 변형·Cubit 공개 메서드 시그니처·DS 매핑·DoloErrorKind 가 채워져 있는지 확인. 비어 있으면 구현하지 말고 Phase 1 로 되돌린다(승인 게이트를 건너뛰지 않는다 — development-process.md §1).
- 진입 즉시 이 행의 P2 셀을 🔄 로 바꾼다.

## 절차 (순서 고정)

`development-process.md §4` · `AGENTS.md Feature generation` 그대로.

1. **스캐폴드.** `scripts/new_feature.sh <feature>` — example_auth 를 `lib/feature/<feature>/`(+`test/feature/<feature>/`)로 결정적 복사·리네임. 그다음 채운다.
2. **테스트부터 (RED).** §1.4 수용조건을 `blocTest` act/expect 로 옮긴다. **성공 · 실패 · 재진입 가드(`if (state.isLoading) return;`)를 반드시 포함.** 구현 전에 돌려서 빨간지 확인 — GREEN 부터 짜지 않는다. **RED 증거를 남긴다** — 실행한 테스트 명령과 실패 출력 요약(`red_test_command`/`red_result`)을 feature 문서(`impl/settings/<feature>.md` §구현)나 진행판 `notes` 에 적는다. RED 증거 없이는 P2 를 완료(✅)로 표시하지 않는다(TDD 를 건너뛴 흔적이 남게).
3. **레이어를 채운다 (한 단계 아래만 호출).**
   - `model/<f>_model.dart` — 단일 `Equatable` + `json_serializable`, 수동 `copyWith`. JSON 필드 바꾸면 `dart run build_runner build --delete-conflicting-outputs`.
   - `provider/<f>_remote_provider.dart` — 주입된 `ApiManager` 호출, JSON→model, 직렬화 실패만 `DoloError(kind: serialization)` 로 재맵.
   - `provider/<f>_local_provider.dart` — 캐시 필요할 때만(`hive_ce`, toJson 저장 / fromJson 복원).
   - `repository/<f>_repository.dart` — provider 조합, **항상 `ApiResult<T>` 반환**: `try { Success } on DoloError { Failure }`. 둘 다 있으면 cache-then-refresh.
   - `cubit/<f>_cubit.dart`(+`<f>_state.dart`) — `ApiResult` 소비 → sealed `Equatable` state union(`<Feature><Variant>`, 기본 4 + 기능별) emit. **재진입 가드 · 실패 시 이전 데이터 보존.**
   - **로직은 순수 Dart** — cubit/repository/provider/apimanager 는 `package:flutter/...` import 금지(`package:bloc`/`dio` 만). cubit→repository 만(provider/apimanager 직접 호출 금지). 무상태 디바이스 부수효과 port(Haptic/Bgm 등)만 cubit 직접 주입 예외.
4. **UI 는 DS 우선.** §1.3 DS 매핑대로 구현.
   - raw 등가물 재발명 금지: `SnackBar`→`DoloToast`/`GlobalToastCubit.show`, `Switch`→`DoloToggle`, `ElevatedButton`→`DoloBottomButton`, `AlertDialog`→`DoloAlertDialog`, 아이콘 `Image.asset`→`DoloAssetIcon`. 매칭은 `docs/design_system/component_registry.json` 에서 찾는다.
   - 색·타이포는 `context.appColors`/`context.typography` 토큰만. 자산은 `Assets.*`/`AppIcons.*`(raw `'assets/...'` 문자열 금지).
   - 치수는 screenutil `.w/.h/.sp/.r`(Figma 375×812 기준) — `ui/` 에 raw px 금지.
   - **상태는 cubit 우선, `setState` 지양.** 위젯 로컬 상태 불가피하면 `ValueNotifier`+`ValueListenableBuilder`. `setState` 는 최후수단 — 리빌드되는 서브트리 자식이 전부 `StatelessWidget` 일 때만.
   - `BlocConsumer`/`BlocBuilder`, 사용자 텍스트는 i18n 키만. UI 는 `actionKind` 로 분기(raw category 금지).
   - **qa 키는 `<feature>.rois.json` 의 qa_key 를 그대로**(임의 발명 금지 — 계약과 한 글자라도 다르면 P3 preflight FAIL).
     그룹 ROI(카드/행/섹션/상태 표면)는 **`QaRegion`**(`lib/core/qa/qa_region.dart` — 한 키를 ValueKey+`Semantics.identifier`
     둘 다에 미러링 → 테스트·visual-verify 양쪽 노출)으로 감싼다. 인터랙션 위젯(DoloToggle/버튼 등)은 기존처럼
     `key: ValueKey('qa_...')` — DS 컴포넌트가 그 키를 **스스로 identifier 로 미러링**한다(`design_system/components/base/
     qa_key_id.dart`; DoloToggle·DoloBottomButton·DoloDialogButton·DoloIconButton 적용, 새 인터랙션 DS 도 같은 패턴 필수).
     **DS 위젯을 같은 키의 QaRegion 으로 겹쳐 감싸지 말 것**(ValueKey 중복 → find.byKey 2개).
5. **계측은 의미 있는 액션만.** cubit 성공/실패 분기에서 `unawaited(_analytics.track(XxxEvent(...)))`. 심을 지점이 있으면 **`/ga4-instrument` 스킬에 위임**(PII·정신건강 자유텍스트 금지). 화면 진입은 observer 자동 — 새 `GoRoute` 엔 `name:`(screen_name) 필수(`require_goroute_name` lint 강제).
6. **키 노출 preflight (위젯테스트, 게이트에 포함).** `<feature>.rois.json` 의 qa_key 마다 해당 화면을 pump 하고
   확인하는 테스트를 `test/feature/<feature>/ui/` 에 둔다(`tester.ensureSemantics()` 필요 — 패턴: `test/core/qa/qa_region_test.dart`).
   **범위는 importance 로 갈린다**: `blocker` 키 = `find.byKey` **와** `find.bySemanticsIdentifier` 둘 다 `findsOneWidget`
   필수(QaRegion 으로 심어야 성립). `normal` 키 = `find.byKey` 만 필수(identifier 는 권장 — raw ValueKey 만인 DS 위젯은
   P3 에서 라벨 폴백 경고로 허용). **blocker 키가 하나라도 안 잡히면(누락·중복·오타 = 키 드리프트) P2 미완** —
   P3 visual-verify 진입 금지. sim 불필요(순수 위젯테스트라 `flutter test` 에 포함).
7. **배선 후 게이트.** `<f>_module.dart` 를 `lib/app/app.dart`(또는 route scope)에 꽂는다. 그다음:
   ```bash
   dart format . && flutter analyze && dart run custom_lint && flutter test
   ```
   **`flutter analyze` 와 `dart run custom_lint` 는 별개 단계** — 둘 다 초록이어야 한다.

## 산출물 / 핸드오프

- 코드: `lib/feature/<feature>/`(module·model·provider·repository·cubit+state·ui).
- 테스트: `test/feature/<feature>/cubit/<f>_cubit_test.dart`(성공·실패·재진입 가드; 버그 고치면 `@Tags(['regression'])`) + `test/feature/<feature>/ui/` 키 노출 preflight 위젯테스트(6단계).
- codegen 결과: `<f>_model.g.dart`(json_serializable 변경 시).

핸드오프 — 진행판 `docs/renew-guide/impl/settings/develop-looping-process-status.md` 의 이 기능 행을 갱신한다.

- **P2 셀 → ✅** (게이트가 실제 초록이고 RED 증거가 기록됐고 **키 노출 preflight(6단계)까지 통과**했을 때만).
- **`gate` 컬럼 → `GREEN`** (대문자 고정 — 라우터가 `gate=GREEN` 을 문자열로 매칭한다. format/analyze/custom_lint/test 4개 통과). 실패 상태면 `RED`.
- **`next` 컬럼 → `visual-verify`** (Phase 3 — 기존 스킬 호출).

develop-looping-process 는 이 표만 읽어 다음 스킬로 라우팅한다.

> **주의 — P3 은 스스로 갱신되지 않는다.** `visual-verify` 는 기존 스킬이라 진행판(develop-looping-process-status.md)을 모른다. Phase 3 를 태운 뒤 **P3=✅ 를 기록하고 `next=feature-runtime-qa` 로 넘기는 건 오케스트레이터 `develop-looping-process` 의 몫**이다(visual-verify PASS 시 기록, FAIL 시 visual-verify 루프). 그래서 여기 `next` 는 `visual-verify` 로 두되, 다음 홉의 진행판 소유자는 develop-looping-process 임을 분명히 한다.

## 강제 / 금지 (가드)

- **게이트가 초록이 아니면 미완.** analyze/custom_lint/test 중 하나라도 빨가면 Phase 3 진입 금지 — 되돌아가 고친다. **에스컬레이션(§1b): 같은 게이트 실패를 3회 고쳐도 안 초록이면 자동 반복을 멈추고 사람에게 올린다** — lint 규칙·템플릿·스펙 충돌일 수 있다(코드만 붙잡지 않는다).
- **한 단계 아래만 호출 · 순수 Dart · DS-first · screenutil** 를 어겼으면(custom_lint/코드리뷰가 잡든 안 잡든) 되돌아가 고친다. `// ignore:` 로 lint 우회하지 않는다(정당한 port 예외만 사유 주석과 함께).
- **버그를 고치면 실패부터 하는 회귀 테스트(`@Tags(['regression'])`)** 를 붙여 초록 확인 — "고쳤다"만으로 넘어가지 않는다.
- **새 의존성은 채택셋 밖 추가 금지**(freezed 금지 포함). 필요하면 `docs/renew-guide/dependencies.md` 갱신 제안부터.
- **승인된 State·Cubit 공개 API 를 임의 변경 금지** — 바꿔야 하면 멈추고 Phase 1 재승인.
- **커밋·push·브랜치 전환 안 한다**(feat/settings 유지). Figma·QA 캡처 산물 커밋 금지.
- **메타 루프(§12).** 구현 중 결함을 잡으면 "코드만 고치고 끝"이 아니라 *하네스(lint·템플릿·게이트)가 막을 수 있었나?* 를 묻고, 가능하면 추가해 다음 기능엔 자동 차단되게 한다.
