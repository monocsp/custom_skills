# 설정화면 visual-verify 검증 프로세스 (화면당 9단계)

> app-lock 에서 검증된 루프를 나머지 화면(login-info · notification · notice · feedback · app-info · withdraw)에 그대로 적용하는 순서·체크·유의점. 한 화면을 끝까지 돌린 뒤 다음으로 넘어간다(병렬 수정은 파일 충돌 위험이라 화면 단위 직렬). 도구 레시피는 `.claude/skills/visual-verify` 와 동일.

## 재료 위치
- Figma 실측: `docs/designs/settings/<area>/*.{png,tree.json,texts.json}`(375 프레임, 2x export). `tree.json`=bbox(프레임상대=node-root), `texts.json`=색(#hex)/폰트크기.
- **위젯 ROI 계약**: `docs/renew-guide/impl/settings/<feature>.rois.json`(P1 산출, 커밋 대상) — 위젯-ROI 대조(`widget_roi_compare.py`)의 기계 입력. QaRegion 심은 qa_key 는 `ui_describe_all` 의 `AXUniqueId` 로 정확일치 매칭, blocker 키 미노출=preflight FAIL(P2 반려). 상세는 `.claude/skills/visual-verify/SKILL.md` §3.
- sim: iPhone 16 Pro `0AE0A335-DA12-4BF3-B341-49686714651F` + QA 토큰(config/dev.secrets.json, relaunch 유지).
- 산출물: gitignore 영역 `docs/designs/settings/<area>/_vv-<screen>/`(stitch·주석·diff MD 사본), 작업본은 scratchpad.

## 순서 (화면당)

**0. 스코프 — 플로우/상태 전수 목록**
- 화면의 모든 상태를 적는다: 기본 · 빈(empty) · 로딩 · 성공 · 에러 · 입력단계 · 시트/오버레이 · 토스트 · 서브화면 · 다단계 플로우(예: withdraw 1~6).
- 각 상태마다 대응 Figma 프레임 파일을 찾아 매핑(없으면 "Figma 부재—디자이너 대기"로 명시, 추정 금지).

**1. 캡처 (sim, 순차)**
- QA 토큰 빌드 relaunch → 각 상태를 **실제 flow 로 진입**해 캡처(빈/에러도 조건 만들어 띄운다). `ui_describe_all`/`ui_find_element` 로 내비, `screenshot` 로 저장. 좌표=논리 402×874(ui_tap), 캡처=native 1206×2622(3x).
- 잠금화면류는 **콜드스타트(앱 완전 종료 후 재실행) 경로**로도 캡처(설정 플로우 캡처만으로 끝내지 말 것).

**2. stitch + 위젯단위 diff MD**
- 좌Figma·우구현 같은 높이로 stitch(PIL). Figma `tree.json` 좌표 + `texts.json` 색/폰트로 **위젯 하나하나** 대조: 존재 · 위치앵커 · 아이콘형태 · 색(#hex 실측) · 폰트크기/굵기 · 간격.
- 차이를 **이미지에 색박스+번호 주석**(PIL). diff MD 표 작성: `위젯 | Figma(실측) | 구현 | kind | 심각도 | intended_staging | fix_hint`.

**3. 적대 다수결 검증 (자평 금지)**
- 상태마다 격리 에이전트 3명 + codex(이미지) 가 **독립** 비교 → 합의(agree_count≥2=confirmed). codex 는 대용량 stitch 6장+ 한번에 주면 hang → 상태별 1장 또는 소수로.
- 데이터/환경 차이는 결함 아님(아래 유의점). intended staging 은 차이로 기록하되 표시.

**4. 수정 핸드오프 (에이전트)**
- 확정 diff MD 를 수정 에이전트에 넘긴다. HIGH 부터. 제약: screenutil(.w/.h/.sp/.r)·`context.appColors` 토큰(raw hex 금지)·ui/ 만·DS-first·기존 qa_* 키 유지. 게이트(`dart format && flutter analyze && dart run custom_lint && flutter test`) green. 커밋은 오케스트레이터(나)가.

**5. codex 평가**
- 수정 후 codex 가 before/after 재평가(고친 게 맞는지, 회귀 없는지).

**6. 재 visual verify**
- 재빌드·재캡처·2~3 반복. before/after stitch 로 대조. **HIGH 0 될 때까지** 루프.

**7. 기능 QA 체크리스트**
- 화면 기능 동작 체크리스트 작성 + sim 실행: 탭·입력·네비게이션·복사·토글·에러표면·재진입가드·뒤로가기. 각 항목 PASS/FAIL 캡처.

**8. 시나리오 검증 (계획 → 실행)**
- understanding 문서의 Given-When-Then 시나리오별로 **검증 방법**(sim 조작 / bloc_test / 위젯test)을 계획표로 적고 실제 검증. 빠진 시나리오·테스트 갭은 보강(app-lock dot 시나리오9 처럼).

**9. 커밋 + 기록**
- 수정·테스트 커밋. 검증 기록 MD(차이표·다수결결과·QA·시나리오) 남김. 산출이미지는 gitignore 영역.

## 유의점 (결함 아님 — 올리지 말 것)
- **데이터 의존**: 소셜 아이콘 종류(QA계정 구글만), 유저ID 값, 공지/문의 건수 → 실데이터라 다름. UI 버그 아님.
- **환경 산물**: 상태바 시계(9:41 vs 실시각)·DEBUG 리본·Dynamic Island·세이프에어리어 수직오프셋(375 vs 402). 비율 보존되면 결함 아님.
- **Figma 375 vs 구현 402**: 절대 px 금지, 비례/상대위치로 판단.
- **sim 한계**: 생체 라벨(`getEnrolledBiometrics` 빈값→"생체 인증", 실기기는 "Face ID"); 키보드 IME 가 ASCII 깨뜨림; codex 대용량 이미지 hang; "Matching Face" 메뉴는 Simulator 포커스 필요.
- **intended staging**: 2차로 미룬 요소(있으면)는 차이로 기록하되 별도 표시. 확정 전 사용자/설계서로 staging 여부 확인.

## 유의점 (꼭 잡을 것)
- **색은 texts.json 실측 #hex 로 픽셀 대조** — 토큰 오용(textSecondary #48403c vs textTertiary #827873) 같은 미묘한 차이를 눈대중 말고 샘플링으로.
- **muted vs 진한색** 구분(pill·footer·힌트). Figma 약한 회색이면 textTertiary.
- **아이콘 형태**(⌫ vs 🗑️, chevron 유무) — 자산 자체가 다른지 확인.
- **레이아웃 앵커**(하단 docking vs 중앙) — SPACE_BETWEEN 같은 프레임 구조 차이가 "전혀 다름"의 주원인.
- **잠금화면은 콜드스타트 경로 포함**, 다단계 플로우(withdraw)는 단계 전부.
- **치수 숫자만 보지 말고 실제 시각적 존재감(대비·명도·가독성)을 본다.** 예: 문의 삭제 X 버튼이 `22.w`(원본 20)로 숫자는 더 컸지만, 밝은 원+회색 X(저대비)라 사진 위에서 흐릿·작아 보였다 — 원본은 진회색 원+흰 X(고대비). "22 vs 20 미세차"로 넘긴 게 오판. 작은 아이콘/뱃지/버튼은 **배경 위 대비와 실제 크롭 확대**로 판정하고, 원본 대비 존재감이 약하면 결함으로 잡는다.

## 진행 순서(화면)
login-info → notification → notice → feedback → app-info → withdraw. (문의하기=webview 제외.)
