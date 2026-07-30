---
name: visual-verify
description: 화면 구현 후 "Figma 디자인 vs 실제 구현 화면"을 위젯 단위로 시각 대조 검증한다. ① Figma frame 을 extract_doc 으로 실측 추출(PNG+tree.json) 또는 docs/designs 의 기존 추출물 재사용 ② iPhone 시뮬레이터에 QA 토큰으로 띄워 해당 flow 의 모든 상태(빈/로딩/성공/에러/입력단계/시트/토스트)를 전수 캡처 ③ P1 산출 `<feature>.rois.json`(위젯 ROI 계약)의 중요 위젯을 Figma tree ↔ ui_describe_all(QaRegion 키=AXUniqueId 정확일치)로 이어 위젯별 크롭 페어 + 번호 오버뷰 생성(widget_roi_compare, blocker 키 미노출=preflight FAIL), 정렬 잔차 detector(align_crop_diff)로 누락영역 보충 ④ 위젯별 크롭을 codex + 격리 서브에이전트 3명에게 1개씩 줘 적대 교차검증(자평 금지·다수결) ⑤ 차이 박스 주석 → 위젯단위 diff MD → 수정 → 재검증 반복. 트리거 — "이 화면 Figma 랑 맞는지 비교해줘", "디자인 대조 검증", "visual verify", "구현 화면 vs 시안 검증", "픽셀 비교", "위젯 매핑 맞나 봐줘". 7단계 개발 루프의 'sim 검증(QA+codex+visual)' 중 visual 담당.
---

# /visual-verify — Figma 시안 vs 구현 화면 위젯 단위 적대 대조

> 정책: **검증 단위 = 위젯(ROI)**. LLM 통짜 눈대중 대신 `widget_roi_compare.py` 로 위젯별 크롭 페어를 만들어 judge 에게
> 1개씩 준다(§3 1차 경로). 눈대중 금지 — "비슷해 보인다" 로 PASS 하지 않는다.
> Figma 측 실측 = `extract_doc` 의 `*.tree.json`(좌표·색·폰트) 또는 `<feature>.rois.json` 의 `figma_bbox`. 구현 측 =
> 시뮬레이터 `ui_describe_all`(**QaRegion 심은 키는 `AXUniqueId` 로 정확일치; raw ValueKey 만인 위젯은 null → 라벨 폴백**)
> + `screenshot`(픽셀).
> 색·radius·그림자·장식 카드는 a11y 에 안 뜨니 크롭 시각판정 + `align_crop_diff` 백스톱으로 본다(ui_describe_all 로 단정 금지).
>
> 정책: 검증은 **iPhone 시뮬레이터**로 한다(모델 고정 없음). 여러 sim 이 부팅돼 있으면 그중 하나를 골라 세션
> 내내 그 UDID 로 고정한다(다른 개발자의 flutter run 침범 금지). 비교는 절대 px 가 아니라 비율로 보니 어떤
> iPhone 이든 무방 — 단 좌표·스케일은 그 sim 의 실제 논리 해상도를 쓴다(아래 좌표 규약).
>
> 정책: 한 화면이 아니라 그 **flow 의 상태 전수**를 본다 — 빈·로딩·성공·에러·입력 각 단계·오버레이·시트·
> 토스트까지. 상태 하나라도 빠지면 그 상태의 드리프트를 못 잡는다.
>
> 정책: 자평 금지. ③의 후보는 codex + 격리 서브에이전트의 **다수결**로만 확정한다(2명 이상이 같은 위젯을
> 짚어야 confirmed). ①~④ 는 읽기·실행 전용(코드·git 무변경), ⑥ 수정만 메인이 하고 ⑦로 재검증한다.

## 언제 도나 — 입력

화면/flow 하나를 구현(또는 수정)한 직후, "시안대로 됐나"를 객관적으로 확인할 때. 인자로 셋을 받는다:

- **화면/기능명** — 예: `app_lock`, `settings`, `notice`. (구현 파일 `lib/feature/<f>/ui/<f>_page.dart` 기준.)
- **Figma node-id 또는 url** — 그 flow 의 frame(들). `?node-id=1234-5678` 또는 풀 url. 상태가 여럿이면 상태별 frame.
- **네비게이션 경로 + 상태 진입 방법** — 앱 실행 후 화면까지 가는 탭 순서, 그리고 각 상태를 어떻게 띄우는지
  (예: "토글 ON → PIN 2회 입력 → 완료", "콜드스타트 → 잠금화면").

셋 중 모호한 게 있으면 **1줄만 되묻는다**(특히 네비 경로·상태 진입). 그다음 1)~7) 을 순서대로 돈다.

## 재료 — 단일 출처 (눈대중·기억 금지)

| 재료 | 경로 | 무엇을 |
|---|---|---|
| 기존 Figma 추출물 | `docs/designs/<area>/<state>.{png,tree.json,texts.json}` | **있으면 재추출 말고 그걸 쓴다**(375 프레임 2x export) |
| Figma 추출 도구 | `.claude/skills/figma-sync/tool/bin/extract_doc.dart` + 그 `SKILL.md` 모드2 | 없을 때만 frame → PNG(2x)+tree.json |
| tree 평탄화 헬퍼 | `.claude/skills/visual-verify/tool/tree_flatten.py` | tree.json → 노드별 frame-relative 실측 표 |
| **위젯-ROI 대조**(1차) | `.claude/skills/visual-verify/tool/widget_roi_compare.py` | `--map` 에 준 rois.json 의 ROI를 Figma tree/bbox ↔ ui_describe_all 위젯으로 이어 **라벨없는 크롭 페어 + 번호 오버뷰 + rough_metric** 생성(=judge 입력) |
| **크롭 detector 백스톱** | `.claude/skills/visual-verify/tool/align_crop_diff.py` | Figma↔sim 정렬 후 잔차 핫스팟 → rois.json 에 **없는** 의심영역만 보충. NCC 는 gate 아닌 정렬 메타데이터 |
| **ROI 계약(기계 SSOT)** | `docs/renew-guide/impl/settings/<feature>.rois.json` | `[{screen, state, roi_id, label, qa_key?, importance, figma_bbox(375pt)|figma_node}]`. **Phase 1(feature-plan) 산출물, 커밋 대상**(docs/designs 는 gitignored — 거기 두면 계약이 증발). §3 표·번호박스는 이것의 뷰. 황금 예시 `notification-setting.rois.json` |
| 번호박스 주석 | `docs/renew-guide/impl/settings-understanding/annotate.py` | 단일 캡처 위 번호박스(widget_roi_compare 가 overview 자동생성) |
| 위젯 매핑 형식 | `docs/renew-guide/impl/understanding-doc-format.md` §3 | §3 표·번호박스 = rois.json 의 **뷰**(표기 형식 참조용 — SSOT 는 rois.json) |
| QA 토큰 실행 | `config/dev.secrets.json`(gitignored, `debugSignIn`) | dev 자동로그인 + 실데이터 |
| sim 검증 선례 | `docs/renew-guide/analytics-ga4/verification.md` §3 | 부팅 sim UDID·MCP 드라이브 |

좌표·스케일 규약(전 스테이지 공유):
- **frame-relative = `node.bbox − root.bbox`**(root = tree 최상위 frame). ③④의 박스 위치는 이걸 쓴다.
- 시뮬 **논리 좌표 = 부팅된 sim 의 논리 해상도**(`ui_describe_all` 이 보고하는 값 — 예 iPhone 16 Pro=402×874, SE=375×667). `ui_describe_all`·`ui_find_element`·`ui_tap` 전부 이 좌표계.
- 시뮬 **캡처 PNG = native = 논리 × 배율(devicePixelRatio, Pro 계열 3x)**. 박스를 캡처 픽셀에 얹을 땐 논리 좌표에 그 배율을 곱한다(예 16 Pro=×3).
- Figma baseline = **375pt**, 구현 = **sim 논리 폭**(예 402pt). screenutil 이 `.w` 를 `deviceWidth/375` 로 비례 스케일하니
  절대 px 비교 금지 — **비율·상대위치·형태·색·굵기**로 본다(`tree_flatten --device-width <sim 논리 폭>` 로 환산값 인용).

---

## 1) 화면 상태 전수 캡처 (sim)

먼저 그 flow 의 **상태 매트릭스**를 적는다(빈·로딩·성공·에러·입력 각 단계·오버레이·시트·토스트). 빠짐없이.

QA 토큰은 `--dart-define-from-file` 로 빌드에 박혀 `debugSignIn` 이 읽는다. 그래서 **최초 1회만 `flutter run`
으로 설치**하면, 이후 상태 재진입은 `simctl launch` relaunch 만으로 자동로그인이 유지된다(재빌드 불필요).

```bash
# 부팅된 iPhone 시뮬레이터 UDID 확인 → 하나 골라 세션 내내 그 UDID 로 고정
xcrun simctl list devices booted | grep iPhone

# 최초 1회 — QA 토큰 박힌 dev 빌드 설치 (실데이터 자동로그인)
flutter run --flavor dev \
  --dart-define-from-file=config/dev.json \
  --dart-define-from-file=config/dev.secrets.json \
  -d <고른 sim UDID>

# 이후 상태 재진입 — relaunch 만으로 로그인 유지 (토큰이 빌드에 박힘)
xcrun simctl launch    <고른 sim UDID> com.dolomood.dev
# 콜드스타트가 필요한 상태(예: 앱잠금 잠금화면)는 terminate 후 launch
xcrun simctl terminate <고른 sim UDID> com.dolomood.dev
xcrun simctl launch    <고른 sim UDID> com.dolomood.dev
```

네비게이션·캡처는 ios-simulator MCP 로(전부 sim 논리 좌표):
- `mcp__ios-simulator__ui_describe_all` — 현재 화면 위젯 트리(논리 좌표·라벨·`qa_*` 키). **구현 측 실측 원천.**
- `mcp__ios-simulator__ui_find_element` — 라벨/키로 위젯 찾아 좌표 얻기.
- `mcp__ios-simulator__ui_tap` / `ui_swipe` — 인자의 네비 경로대로 진입(가능하면 `qa_*` 키, 없으면 좌표).
- `mcp__ios-simulator__screenshot` — 대상 상태 도달 후 캡처 → 스크래치패드 `sim_<state>.png`.

**상태가 로직상 잠기면 그 flow 를 실제로 태운다.** 예: 앱잠금이면 설정 토글 ON → numpad 로 PIN 2회 등록 →
완료 토스트 → terminate/launch 로 콜드스타트 → 잠금화면. 매 상태 도달은 `ui_describe_all` 의 `qa_*` 키/타이틀로
검증한 뒤 캡처한다(엉뚱한 화면 캡처 방지).

> Figma 실측물이 `docs/designs/<area>/*.{png,tree.json,texts.json}` 에 이미 있으면 **재추출하지 말고** 그걸 쓴다.
> 없을 때만 추출하고, 추출 직후 `tree_flatten` 으로 기대값 표를 뽑는다:
>
> ```bash
> cd .claude/skills/figma-sync/tool
> dart run bin/extract_doc.dart --url "https://www.figma.com/design/<FILE>/x?node-id=<1234-5678>" \
>   --out <작업폴더>/<state> --out-direct --force-overwrite
> cd -  # 작업 루트로
> python3 .claude/skills/visual-verify/tool/tree_flatten.py \
>   <작업폴더>/<state>/<state>.tree.json --device-width 402 --min-w 6
> ```

## 2) 좌 Figma · 우 구현 stitch (PIL)

상태마다 Figma PNG 와 sim 캡처를 **같은 높이로 리사이즈해 가로로 붙이고** 상단에 라벨을 박는다. 한 장에 두
시안이 나란히 있어야 사람·리뷰어 모두 1:1로 본다. 절대 px 가 아니라 **비율**로 비교한다는 걸 라벨에 명시.

```python
# scratch/stitch.py  — python3 scratch/stitch.py FIGMA.png SIM.png OUT.png
import sys
from PIL import Image, ImageDraw

H, PAD, LAB = 1400, 24, 44
def fit(p):
    im = Image.open(p).convert("RGB")
    return im.resize((int(im.width * H / im.height), H))

fig, impl = fit(sys.argv[1]), fit(sys.argv[2])
cv = Image.new("RGB", (fig.width + impl.width + PAD * 3, H + LAB + PAD), "white")
cv.paste(fig, (PAD, LAB)); cv.paste(impl, (fig.width + PAD * 2, LAB))
d = ImageDraw.Draw(cv)
d.text((PAD, 12), "FIGMA (375pt)", fill="black")
d.text((fig.width + PAD * 2, 12), "IMPL (sim, 비례비교)", fill="black")
cv.save(sys.argv[3])
```

```bash
python3 scratch/stitch.py docs/designs/app-lock/lock.png scratch/sim_lock.png scratch/stitch_lock.png
```

## 3) 위젯-ROI 대조 입력 생성 → 적대 비교 (자평 금지 · 다수결)

> **1차 경로 = 위젯-ROI(권장). stitch 통짜 눈대중은 fallback 으로 강등**(rois.json 이 없고 즉석 ROI 작성조차 불가한 빠른확인·정렬 붕괴 시만).
> 근거: LLM 은 통짜 화면에서 정밀 공간 비교가 약하다. **검증 단위를 "명시된 중요 위젯(ROI)"으로 쪼개** judge 에게
> 라벨없는 크롭 페어를 1개씩 준다(에이전트가 "이 박스가 무슨 위젯인지" 알면 훨씬 정확). 정렬 스파이크 실증:
> Figma↔sim 은 "가로=폭비율 + 세로=단일 오프셋(자동)"으로 NCC 0.93~0.99 정합.

**(0) 입력 준비.** 상태별로 Figma `png`(+가능하면 `tree.json`), sim `screenshot`, `ui_describe_all` JSON 을 저장한다.
ROI 목록은 **P1 산출물 `docs/renew-guide/impl/settings/<feature>.rois.json`** 을 그대로 쓴다(기능당 1개, qa_key·importance·
figma_bbox 는 P1 승인으로 동결 — 여기서 새로 만들지 않는다). 없는 옛 화면만 즉석 작성하되(즉석본=스크래치, 미커밋·비동결 — P1 승인 계약 아님) **중요 위젯만 10~25개**(전체
a11y 노드 ROI화 금지 — Stack/리스트셀 폭증. 중첩은 parent/group 기본).

```bash
# 라이브 sim 주의: 여러 sim 이 부팅돼 있으면 반드시 --udid/-u 로 고른 sim 만 타겟(다른 개발자의 flutter run 침범 금지).
python3 .claude/skills/visual-verify/tool/widget_roi_compare.py \
  --figma-png <figma.png> --sim-png <sim.png> \
  --map docs/renew-guide/impl/settings/<feature>.rois.json --screen <screen> --state <state> \
  --sim-describe <ui_describe_all.json> [--figma-tree <tree.json>] \
  --sim-width <sim 논리 폭> \
  --out <작업폴더>/roi
# --sim-width = 부팅 sim 논리 폭(ui_describe_all 루트 폭; 예 16 Pro 402·SE 375). 생략 시 402(16 Pro) 기본 — 다른 기기면 필수 지정(안 주면 조직적 오차).
# → overview.png(번호박스), roi_<id>.png(좌Figma·우구현 크롭 페어), roi_compare.json(present·rough_metric)
# 백스톱: rois.json 에 없는 의심영역 보충 (align 도 같은 --sim-width)
python3 .claude/skills/visual-verify/tool/align_crop_diff.py <figma.png> <sim.png> --sim-width <sim 논리 폭> --out <작업폴더>/backstop
```

> **라이브 sim 실측 규약(검증됨):** ① **`QaRegion` 으로 심은 키와 DS 인터랙션 컴포넌트의 qa 키는 `AXUniqueId` 로
> 노출**된다(`Semantics.identifier` → iOS accessibilityIdentifier; frame = 실제 bounds) — 도구가 `qa_key_exact` 로
> 정확일치 매칭한다. DS 는 컴포넌트가 자기 `ValueKey('qa_...')` 를 **스스로 미러링**한다(`design_system/components/
> base/qa_key_id.dart` — DoloToggle·DoloBottomButton·DoloDialogButton·DoloIconButton, 2026-07-03). **그 외 raw
> `ValueKey` 만 있는 위젯(구형 화면·미지원 컴포넌트)은 여전히 null** → 라벨(AXLabel)+위치 폴백. ② QaRegion 을
> 안 씌운 장식 카드 컨테이너는 a11y 트리에 안 뜬다 — 그 ROI 는 자식 union 근사가 되므로 rough_metric 크기차 **단독
> FAIL 금지**(a11y bounds ≠ paint). ③ `rough_metric` 은 **2-tier** — `outlier`(약한 플래그, 시각 확인 필요) /
> **`machine_vote`**(|dw|·|dcx| ≥ 0.06 = 근사 오차로 설명 안 되는 폭·위치 드리프트 → **다수결에 기계표 1로 합류**하는
> confirmed 후보). 통제 실험(2026-07-02, inquiry 보내기 버튼 ~11% 폭 결함) 실증: **타이트 크롭은 대칭 여백을 정규화로
> 지워** 격리 시각 3인 중 2인이 놓쳤고, 이 기계표·overview·stitch 가 잡았다. 단 기계표는 자동 확정이 아니라 1표 — 라벨
> 폴백이 카드 내부 텍스트 노드에 붙으면 dw 오탐이 나므로(input_card 사례, **카드류 ROI 에 qa_key 필수인 이유**) judge 가
> 밴드 크롭으로 기각할 수 있다. ④ blocker ROI 의 qa_key 가 안 잡히면 **⛔ PREFLIGHT FAIL**(키 드리프트·미노출) — 대조를
> 진행하지 말고 P2 로 되돌린다. ⑤ 도구 자동 산출 2종: **`alignment_outlier`**(figma 에선 같은 좌x 정렬 그룹인데 impl 에서
> 혼자 어긋난 위젯 — "버튼만 홀로 inset" 류의 도구화)와 **풀-밴드 크롭 `roi_*_band.png`**(edge_sensitive 또는 machine_vote
> ROI 를 화면 좌우 끝까지 잘라 위 FIGMA/아래 IMPL — 빨간 틱 = figma 기대 경계. 폭/여백 판정은 타이트 크롭이 아니라 이걸로).

**(적대 비교)** 상태마다 **독립 검증자 셋(격리 서브에이전트) + codex 하나**에게 **overview 1장 + ROI 크롭 페어(+백스톱 unmapped 크롭)**
를 주고 각자 **ROI(roi_id) 단위**로 불일치를 뽑게 한 뒤, 상태별 종합자가 병합·`agree_count` 집계 → **2명 이상이 짚은 것만
confirmed**. 내 ③ 판단은 표 한 칸일 뿐 자력 PASS 하지 않는다. (rois.json 도 즉석 ROI 도 없는 빠른확인만 **fallback**: 아래 §2 stitch 를
codex+격리 3명에게.)

각자 같은 JSON 스키마로 뽑는다:
`[{widget, figma, impl, kind, severity, likely_intended_staging, fix_hint}]`
— `kind` = `layout`/`icon`/`color`/`typography`/`spacing`/`presence`,
`severity` = `blocker`/`major`/`minor`/`nit`,
`likely_intended_staging` = 의도적으로 뒤로 미룬 차이면 true(예: 2차로 미룬 생체인증) → 차이로 **기록은 하되 별도 표시**, 결함 카운트엔 안 넣음.
> **⛔ staging 강등 게이트(오분류 방지).** `likely_intended_staging:true` 는 사유가 **①`no_figma_source`(Figma 원본 없음=디자이너 미작업) ②`explicitly_phase2`(명시적 2차 기능) ③`dpr_artifact`(DPR/환경)** 중 하나일 때만 — `fix_hint` 에 그 사유 토큰을 1줄로 남긴다(임의 사유 예: "figma-sync 등록 후"·"placeholder"·"추후 교체" 는 **무효** → confirmed 결함). **`kind=icon` 이고 그 위젯의 Figma 벡터 노드가 존재하면 staging 강등 절대 금지 = 기본 confirmed 결함**(Figma 에 있으면 SVG export 가 정답, CustomPaint 근사·미룸 아님. AGENTS.md DS-first · rootcause `docs/renew-guide/impl/home/rootcause-icon-custompaint-vs-figma-svg-2026-07-08.md`). 종합자는 근거 토큰 없는 staging 을 confirmed 로 되돌린다.
**단, 사용자가 명시적으로 요청한 항목(fix-requests 불릿·rois.json 요청)에는 `likely_intended_staging`(결함 카운트 제외)을 적용 금지.** 명시 요청과 배치되는 차이는 "표준이 맞다·플레이스홀더다"로 강등할 수 없고, 미반영이면 confirmed 결함(blocker)으로 남겨 사용자에게 ⛔BLOCK 으로 올린다(AGENTS.md Explicit user request contract). 아래 프리플라이트가 이를 강제한다.

> **⛔ 명시 요청 대조 프리플라이트(drift 판정 전 필수).** 이 화면의 원 요청 목록(`docs/renew-guide/impl/settings/fix-requests-*.md` 해당 화면 불릿 + `<feature>.rois.json`)을 로드해 적대 검증자에게 이미지와 **함께 입력**으로 준다. 검증자가 추가로 답하게: "원 요청 각 항목이 구현에 반영됐나? 미반영·다르게 구현된 항목은?" **한 건이라도 미반영/변경이면 PREFLIGHT FAIL** — 그 화면은 blocker 키 미노출과 동급으로 처리하고, 자의적 "결함 아님" 판정으로 진행하지 말고 사용자에게 ⛔BLOCK 으로 올린다.

**(a) 격리 서브에이전트 3명 — 병렬, 서로·내 결과 비공개** (Agent 툴 `general-purpose`, 한 메시지에 3개 동시):

> 너는 visual-verify 의 독립 시각 검증자다. 첨부 이미지 `scratch/stitch_lock.png` 는 좌=Figma 시안(375pt),
> 우=Flutter 구현 캡처(iPhone 시뮬레이터)를 가로로 붙인 것이다. Read 로 직접 보고, 같은 화면이어야
> 한다는 전제로 **구현이 시안과 다른 점만** 위젯 단위로 뽑아라. 절대 px 가 아니라 비율·상대위치·형태·색·굵기로
> 비교한다(screenutil 375→sim폭 비례 스케일 — sim 이 375 폭이면 1:1). 보는 항목: layout·icon·color·typography·spacing·presence(누락/잉여).
> 출력은 JSON 배열 `[{widget, figma, impl, kind, severity, likely_intended_staging, fix_hint}]` 뿐.
> 같은 점·추측은 적지 마라. 의도적으로 뒤로 미룬 듯한 차이는 `likely_intended_staging:true`. 코드는 안 본다,
> 이미지만. (실측 표가 있으면 `tree_flatten` 출력을 함께 붙여 수치 근거로 인용시킨다.)
> ⚠ **크롭 착시 경고(통제 실험 실증 — 3인 전원 오탐 냈던 함정)**: ROI 크롭은 각자 bbox 로 정규화돼 있어
> ① 폭이 다르면 종횡비가 달라져 **모서리 반경·높이가 다르게 보인다** — radius/height 는 크롭 인상이 아니라
> **tree 수치로만** 판정하라. ② 크롭에선 "화면 가장자리에서 얼마나 안쪽인지"(대칭 여백)가 안 보인다 — 폭/마진은
> **overview·`roi_*_band.png`(빨간 틱=figma 기대 경계)** 로 판정하라. `machine_votes`/`alignment_outliers`
> (roi_compare.json)가 있으면 그 ROI 를 우선 재확인하라(기계표 기각은 밴드 크롭 근거로만).

**(b) codex — 이미지 직접 비교** (stitch 1장씩, `< /dev/null` 로 비대화):

```bash
codex exec -s read-only -c approval_policy="never" --skip-git-repo-check \
  -i scratch/stitch_lock.png \
  -o scratch/codex_lock.md \
  "이 이미지는 좌=Figma 시안(375pt), 우=Flutter 구현 캡처(iPhone 시뮬레이터)를 가로로 붙인 것이다. \
같은 화면이어야 한다. 절대 px 가 아니라 비율·상대위치·형태·색·굵기로 비교하라(screenutil 375→sim폭 비례). \
위젯 단위로 layout·icon·color·typography·spacing·presence 를 보고 불일치만 JSON 배열로: \
[{widget, figma, impl, kind, severity(blocker/major/minor/nit), fix_hint}]. 같은 점·추측은 빼라." < /dev/null
```

> **codex 대용량 이미지 hang (실전 gotcha):** 큰 stitch 6장을 `-i` 로 한 번에 주면 10분+ 멈춰 안 돌아온다.
> **상태별 1장씩** 호출하고, 그래도 안 끝나면 프로세스를 kill 하고 그 상태는 격리 서브에이전트 3명 다수결로만
> 진행한다. codex 는 보조 한 표일 뿐, 없어도 합의는 성립한다.

**합의 규칙** — ③나 · (a)서브에이전트들 · (b)codex 결과를 상태별로 종합:
- 둘 이상이 같은 위젯을 짚으면 → **confirmed**(`agree_count≥2`).
- 한 명만 짚었으면 → tree.json 실측을 다시 대조해 사실이면 채택, 아니면 기각(노이즈로 한 줄 기록).
- 심각도 충돌은 보수적으로(더 높은 쪽). `likely_intended_staging` 은 confirmed 표에 두되 결함 카운트 제외.

## 4) 차이 박스 주석 (PIL)

confirmed 불일치마다 stitch 위에 **색 박스 + 번호 라벨**을 얹어 사람이 한눈에 보게 한다(①numpad ②backspace
③pill 식). 박스 위치는 Figma tree.json bbox(frame-relative = `node.bbox − root.bbox`)와 sim `ui_describe`
좌표에서 계산하되, stitch 리사이즈 비율(`H/원본높이`)과 좌/우 패널 오프셋을 곱해 맞춘다.

```python
# scratch/annot.py  — boxes = [{n,label,side('fig'|'impl'),x,y,w,h}] 는 frame-relative
import json, sys
from PIL import Image, ImageDraw
cv = Image.open(sys.argv[1]).convert("RGB"); d = ImageDraw.Draw(cv)
boxes = json.load(open(sys.argv[2]))
H, PAD, LAB = 1400, 24, 44
fig_w = int(Image.open(sys.argv[3]).width * H / Image.open(sys.argv[3]).height)  # 좌 패널 폭
def scale(b):                      # frame(375/402) → stitch 픽셀
    base = 375 if b["side"] == "fig" else 402   # 402/874 = 부팅 sim 논리크기 예시(16 Pro) — 다른 기기면 교체
    k = H / (812 if b["side"] == "fig" else 874)   # 세로 기준 리사이즈 비율
    ox = PAD if b["side"] == "fig" else fig_w + PAD * 2
    return ox + b["x"] * k, LAB + b["y"] * k, b["w"] * k, b["h"] * k
for b in boxes:
    x, y, w, h = scale(b)
    d.rectangle([x, y, x + w, y + h], outline="red", width=3)
    d.text((x, max(LAB, y - 14)), f"{b['n']} {b['label']}", fill="red")
cv.save(sys.argv[4])
```

사용자 확인용 주석본은 **gitignore 영역**에 복사한다(커밋 금지 산물): `docs/designs/<area>/_vv-<feature>/`.

## 5) 위젯단위 diff MD (수정 지시서)

상태별 confirmed 표 + 한 줄 총평으로 정리한다. 이게 6) 수정의 지시서다.

```markdown
## visual-verify: <flow> — <state> (Figma <node-id> ↔ iPhone 시뮬레이터)
- 검증자: ③나 · codex · 서브에이전트 3 → 합의(agree_count)

| # | 위젯 | Figma 실측 | 구현 | kind | severity | agree | fix_hint |
|---|---|---|---|---|---|---|---|
| 1 | numpad 키 | 72×72 · gap 12 | 64×64 · gap 8 | layout/spacing | major | 3 | `72.w` 정사각·`12.h` gap |
| 2 | backspace | 라인 아이콘 | 채움 아이콘 | icon | minor | 2 | `AppIcons.backspace` 라인형 |
| 3 | 잠금 pill | fill #433b37 r30 | r24 | color/layout | major | 2 | `30.r` |
| - | 생체 버튼 | 노출 | 없음 | presence | — | 3 | intended_staging(2차) — 결함 아님 |

총평: numpad 치수·gap 이 전반적으로 작음(HIGH). 색 토큰 1건. 생체는 의도된 2차 보류.
```

## 6) 수정

diff MD 의 **HIGH(blocker/major)부터** 고친다 — 레이아웃 앵커·아이콘 자산·색 토큰·누락 위젯. screenutil
`.w/.h/.sp/.r`·`context.appColors`·DS 컴포넌트 규칙 준수(raw px·raw color 금지 — AGENTS.md). 고친 뒤 게이트:

```bash
dart format . && flutter analyze && dart run custom_lint && flutter test
```

## 7) 재검증 (HIGH 0 될 때까지 루프)

수정 반영을 위해 재빌드/relaunch 한 뒤(`flutter run` 재실행 또는 hot restart), 2)~5) 를 다시 돈다. 새 stitch +
주석으로 **before/after 를 나란히** 대조해 그 결함이 사라졌는지·새 결함이 안 생겼는지 본다. confirmed HIGH 가
0이 될 때까지 반복한다. OS 프롬프트가 끼는 동작(생체인증 등)은 시뮬에서 **실제로 띄워** 확인한다.

---

## gotchas

- **다중 sim 부팅 시 udid 타겟 필수.** 여러 시뮬레이터가 동시에 부팅돼 있을 수 있고(다른 개발자가 SE 등에서 `flutter run`
  중일 수 있음), MCP/`simctl` 이 엉뚱한 sim 을 잡으면 남의 작업을 침범한다. **먼저 `xcrun simctl list devices booted` 로
  확인**하고, ios-simulator MCP 는 `udid` 파라미터로, `simctl` 은 UDID 인자로 **고른 sim 만** 콕 집는다. dart MCP
  `get_widget_tree` 는 실행중 flutter VM 에 붙으니(남의 run 일 수 있음) 이 스킬에선 쓰지 말 것 — 위젯 frame 은 `ui_describe_all`.
- **qa키 노출은 `QaRegion` 이 전제.** `Semantics.identifier` 를 심은 위젯만 `AXUniqueId` 로 잡힌다 — raw `ValueKey` 만 있는
  위젯(구형 화면·DS 내부)은 null 이라 라벨+위치 폴백. QaRegion 안 씌운 장식 카드는 트리에 없어 자식 union 근사 →
  rough_metric 크기차를 단독 결함으로 쓰지 말 것(a11y≠paint). blocker 키 미노출 = ⛔ preflight FAIL → P2 로 반려.
- **codex 대용량 이미지 hang.** 큰 stitch 여러 장을 한 번에 주면 10분+ 멈춘다. 상태별 1장씩, 안 끝나면 kill →
  격리 서브에이전트 3명 다수결로 진행. codex 는 있으면 좋은 한 표일 뿐 필수 아님.
- **ui_tap 논리좌표 vs 캡처 native.** `ui_describe_all`/`ui_tap` 은 **sim 논리 좌표**, `screenshot` PNG 은
  **native = 논리 × 배율(예 16 Pro 3x)**. 캡처 픽셀에 박스를 얹을 땐 논리 좌표에 그 배율을 곱한다. 둘을 섞으면 박스가 어긋난다.
- **simctl relaunch 가 QA 로그인을 유지.** QA 토큰이 `--dart-define-from-file` 로 빌드에 박혀 있어, 최초 1회만
  `flutter run` 으로 설치하면 이후 `simctl launch`/`terminate→launch` relaunch 만으로 자동로그인이 그대로다.
  매 상태마다 재빌드할 필요 없다(코드를 바꾼 6) 수정 뒤에만 재빌드).
- **Figma 375 vs 구현 402 비례.** 절대 px 비교 금지. screenutil 이 `.w` 를 `402/375` 로 비례 스케일하니
  비율·상대위치·형태·색·굵기로 본다. `tree_flatten --device-width 402` 의 환산값을 인용.
- **시뮬 키보드 IME 가 ASCII 를 깨뜨림.** `ui_type` 으로 PIN·영문 입력 시 한글 IME 가 물려 ASCII 가 깨질 수
  있다. 숫자패드 등은 화면의 키를 `ui_tap` 으로 직접 누르고, 입력 결과를 `ui_describe_all` 로 검증한 뒤 진행.
- **sim stale 설치.** 재빌드했는데 구 코드가 렌더되면 `xcrun simctl uninstall booted com.dolomood.dev` 후
  다시 `flutter run`.
- **빈/로그인 화면이 잡히면** QA 토큰(`config/dev.secrets.json`) 누락 — 더미 토큰이면 401 빈 화면이라 시각 검증
  불가. 토큰 채워 재설치 후 검증.

## 출력 — 불일치 표 + 권고

상태별 diff MD(§5)를 모아 보고한다. 차이는 **정직하게** — 구현이 시안과 다른 게 서버 계약/의도된 staging 이면
그 사유를 fix_hint 에 밝히고 결함 카운트에서 뺀다(추측 수치로 결함을 만들지 말 것). **단 사용자 명시 요청과 배치되는 차이는 카운트 제외 대상이 아니다** — "표준이 맞다·플레이스홀더다"로 강등하지 말고 열린 ⛔BLOCK 으로 남겨 사용자에게 올린다(위 프리플라이트). confirmed HIGH 가 0이면
**PASS**. 한국어 보고는 `humanize-korean` 으로 AI 티 자가검열(이미 깨끗하면 그대로).

## 산출물 취급

- `sim_*.png`·stitch·주석본 등 `docs/designs/**` 이미지는 **커밋 금지**(런타임 가치 0, bloat). 작업은
  스크래치패드, 사용자 확인용 주석본만 `docs/designs/<area>/_vv-<feature>/`(gitignored)에 둔다.
  `.gitignore` + `pr` 스킬 0단계(`scripts/clean_qa_artifacts.sh`)가 정리한다.
- 검증을 이해도 문서로 남기면 `docs/renew-guide/impl/<area>-understanding/<feature>.md` 형식
  (understanding-doc-format §3 의 "번호·위젯·Figma 실측·구현" 표) — 그 폴더 `img/` 이미지만 커밋 대상.
- `tree.json`/`texts.json` 은 일회성 확인이면 미커밋, 스펙 근거로 쓰면 커밋(figma-sync 산출물 취급 표 참조).
