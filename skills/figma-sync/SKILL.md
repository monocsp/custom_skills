---
name: figma-sync
description: Figma 실측값을 snapshot JSON + design_system Dart 상수로 동기화 (+ 화면 PNG/tree.json 추출). 도구는 이 skill 폴더 안에 내장 — 앱 코드/게이트에 안 잡힘.
---

Figma 가 디자인 SSOT. 이 skill 은 Figma API 에서 실측값을 기계 판독해
**snapshot JSON(git-tracked) → `lib/design_system/generated/{slug}_tokens.dart` 상수**로 고정한다.
눈대중 금지 — 수치는 항상 snapshot/tree.json 이 ground truth.

도구는 `.claude/skills/figma-sync/tool/` 에 내장 (dolomoodProto `tools/figma_extractor` 이식,
외부 의존성 0개). 자체 pubspec 으로 격리되어 있어 앱 빌드·`flutter analyze`·custom_lint 에 잡히지 않는다.
**생성/삭제 댄스 불필요** — 도구는 여기 상주하고, 산출물만 리포에 남는다.

## 사전 조건

- `.claude/skills/figma-sync/.env` 에 `FIGMA_TOKEN`(PAT) + `FIGMA_FILE_KEY`. 같은 폴더의 `.gitignore` 가
  이 `.env`(및 `tool/.env`)를 추적에서 빼므로 토큰은 커밋되지 않는다. 세 모드(figma_sync·extract_doc·sync_icons)
  모두 실행 위치에서 위로 `.env` 를 탐색하므로 **스킬 폴더 `.env` 가 우선, 리포 루트 `/.env` 는 fallback** 이다.
  (`tool/` 에서 실행할 때 `tool/.env` 가 있으면 그게 더 우선 — 평소엔 스킬 폴더 `.env` 하나만 둔다.)
- 최초 1회: `cd .claude/skills/figma-sync/tool && dart pub get`
- fvm 환경이면 `fvm dart` 로 실행

### .env 설정 (없거나 키 누락 시)

도구가 토큰/`.env` 누락 오류 — extract_doc 는 `오류: .env 못 찾음`(파일 없음) 또는
`오류: .env에 FIGMA_TOKEN 필요`(키 없음), 둘 다 exit 1; figma_sync·sync_icons 는
`FIGMA_TOKEN / FIGMA_FILE_KEY 필요 (.env 또는 환경변수)`(exit 65) — 를 내면 **아래 순서**로 해결한다.

**0. 먼저 메인 워크트리 `.env` 를 복사한다(손 근사 금지).** 이 워크트리(orca 세션 등)에 `.env`/토큰이 없으면, 메인 레포의 스킬 `.env` 를 그대로 가져온다 — git 이 아니라 **파일 복사**라 `cross-workspace-git-eperm` 갓챠와 무관하다:
   ```bash
   MAIN=/Users/pcs/Documents/GitHub/FmMentalCare/dolomood-app-renew   # 메인 워크트리(레포) 경로 — 다르면 조정
   cp "$MAIN/.claude/skills/figma-sync/.env" .claude/skills/figma-sync/.env
   ```
   (스킬 `.gitignore` 로 보호되니 복사해도 커밋 안 됨.)
**0b. 그래도 토큰이 없으면 즉시 멈추고 사용자에게 알린다.** "FIGMA_TOKEN 이 이 워크트리·메인 어디에도 없다 — `.env` 에 넣어달라"고 요청하고 **대기**한다. ⛔ **토큰이 없다고 Figma 값을 손으로 추정·근사(hand-authored SVG·CustomPaint·tree.json bbox 눈대중)하지 말 것** — AGENTS.md "Figma 벡터는 SVG export만" 위반이다(도구가 막힌 것 ≠ 사람이 막힌 것; 물으면 대개 즉시 받는다).

**최초 발급(메인에도 없을 때)** 은 아래대로:

1. `.claude/skills/figma-sync/.env` 파일을 만들고 두 줄을 넣는다:
   ```
   FIGMA_TOKEN=figd_여기에_본인_PAT
   FIGMA_FILE_KEY=<디자인 파일 키>
   ```
   - `FIGMA_FILE_KEY` 는 Figma URL 의 `/design/<이 구간>/...`. (extract_doc 는 `--url` 로 주면 생략 가능.)
2. **PAT(Personal Access Token) 발급**: Figma 로그인 → 좌상단 계정 → **Settings → Security →
   Personal access tokens → Generate new token**. 스코프는 **File content = Read-only** 면 충분(나머지 No access).
   생성 직후 `figd_...` 가 **한 번만** 보이니 즉시 복사해 위 `FIGMA_TOKEN` 에 붙인다.
3. 토큰은 비밀이다 — `.env` 는 위 `.gitignore` 로 보호되지만, 값 자체를 채팅·커밋·로그에 노출하지 말 것.

## 모드 1: 토큰 동기화 (디자인시스템 적용의 본명)

```
/figma-sync {slug}
```

1. **Role map 확인**: `tool/config/figma-snapshot-{slug}.json` 존재 확인.
   없으면 사용자에게 Figma URL(또는 node ID들)을 받아 role map 초안 작성 → 사용자 검토 후 진행.
   (작성법: `tool/config/README.md`)
2. **실행**:
   ```bash
   cd .claude/skills/figma-sync/tool
   dart run bin/figma_sync.dart --slug {slug} --dry-run   # 미리보기
   dart run bin/figma_sync.dart --slug {slug}             # 실제 생성
   ```
3. **산출물**:
   - `docs/figma-snapshots/{slug}.json` — 기계 SSOT (git-tracked, PR 리뷰는 이 diff 로)
   - `lib/design_system/generated/{slug}_tokens.dart` — `abstract final class {Slug}Tokens` 상수
4. **변경 요약**: `git diff docs/figma-snapshots/{slug}.json` 으로 Figma 변경점 보고.
5. **적용 원칙**: 위젯/테마 코드는 raw 숫자 하드코딩 대신 생성된 토큰 상수 참조.
   생성 파일은 "DO NOT EDIT" — 값 바꾸려면 Figma 수정 후 재실행.
   기존 `tokens.dart`(AppGlassStyles 등 ThemeExtension)와의 연결은 사람이 작성하는
   design_system 코드에서 토큰 상수를 참조하는 방식으로.

Exit codes: 0 성공 · 2 노드 미해석(fail-closed, snapshot 미작성) · 65 .env 누락 · 66 Figma API 에러 · 67 config 결함.

## 모드 2: 화면/문서 추출 (PNG + tree.json + md)

시각 레퍼런스가 필요할 때 (구현 전 화면 확인, 디자인 비교):

```bash
cd .claude/skills/figma-sync/tool
dart run bin/extract_doc.dart --url "https://www.figma.com/file/...?node-id=..." --dry-run
dart run bin/extract_doc.dart --url "..."        # 실제 추출
# 또는 --page "페이지명" / --node "1097:63359"
```

- 출력: `docs/designs/{slug}/` 에 frame 당 `*.png + *.tree.json + *.md (+ texts.json, typography.md)`
- `--dry-run` 으로 frame 개수/크기 먼저 확인. 8000px 초과 대형 frame 은 sub-frame 분해
  (`--node` 로 개별 추출) 권장.
- **`--url`/`--node` 는 SECTION 을 주는 게 기본이다.** FRAME 을 직접 주면 도구가 그 프레임의 *하위* 프레임들을
  추출 대상으로 잡아 정작 그 프레임에 붙은 어노테이션·정책을 놓친다(2026-07-15 실측).
- **📌 Dev Mode 어노테이션은 md 맨 위 `## 📌 Figma Dev Mode 어노테이션` 섹션 + tree.json `annotations` 에 나온다.
  기획 정책이 여기에만 적힌 경우가 많으니 구현 전 반드시 읽어라.** 어노 host 는 TEXT 가 아닌 게 대부분이라
  (실측: 71 host 중 69% 가 VECTOR/FRAME/INSTANCE) `texts.json` 을 아무리 grep 해도 안 나온다 —
  **"texts.json 에 없음 ≠ Figma 에 없음"**(기존 Do NOT 의 "`AppIcons` 에 없음 ≠ 자산 없음"과 동형).
  2026-07-15 이전 추출물엔 이 섹션이 없다(도구가 버렸음) → 그때 산출물은 **재추출해야 정책이 온전하다**.
- tree.json 의 TEXT 노드에 `fakeBold` 필드가 있으면 일반 Text 대신 stroke 로 굵기를 흉내낸
  디자인이므로 구현 시 주의.

## 모드 3: 아이콘 동기화 (② Theme > Icon → PNG 에셋 + manifest + AppIcons)

`icons/normal` 프레임(node 4051:1118)의 COMPONENT_SET 변형들을 PNG 1x/2x/3x 로
추출해 기계 동기화 체인에 넣는다 (codex 평가 M9 해소):

```bash
cd .claude/skills/figma-sync/tool
dart run bin/sync_icons.dart --dry-run   # 디스크 대비 추가/삭제/이름변경 예상만 출력
dart run bin/sync_icons.dart             # 실제 동기화
```

- **산출물**:
  - `assets/icons/{,2.0x/,3.0x/}{name}.png` — scale 1/2/3 PNG (고아 PNG 는 자동 삭제)
  - `docs/figma-snapshots/icons.manifest.json` — SSOT (nodeId·세트·변형·크기·PNG FNV-1a64)
  - `lib/design_system/app_icons.dart` — `AppIcons` 카탈로그 (DO NOT EDIT, dart format 적용)
- **이름 정규화 규칙**: `bin/sync_icons.dart` 헤더가 SSOT (app_icons.dart 헤더에도 동일 문서화) —
  세트 kebab→snake, `Property 1=Default` 무접미사, 변형 `_<값>` 접미사, 세트명==변형값 축약,
  동명 충돌 `_<가로px>` 접미사, `_blank`/문서 프레임/렌더 불가 노드(4051:1400) 제외.
- **무결성**: `test/design_system/app_icons_test.dart` 가 manifest ↔ 카탈로그 ↔ 디스크 PNG
  (FNV-1a 3해상도 전수)를 대조한다 — 아이콘을 수기로 바꾸면 테스트가 깨진다. 재동기화로 해결.
- Figma images API 가 null 을 반환하는 노드는 스킵 + stderr 기록 (50개 배치, 실패 1회 재시도).

## 산출물 취급

| 경로 | git | 비고 |
|---|---|---|
| `docs/figma-snapshots/*.json` | ✅ 커밋 | 기계 SSOT — PR diff 리뷰 대상 |
| `lib/design_system/generated/*_tokens.dart` | ✅ 커밋 | 생성물이지만 빌드 입력이므로 커밋 |
| `docs/figma-snapshots/icons.manifest.json` | ✅ 커밋 | 아이콘 SSOT — 무결성 테스트가 PNG 해시 대조 |
| `assets/icons/**`, `lib/design_system/app_icons.dart` | ✅ 커밋 | sync_icons.dart 생성물 (빌드 입력) |
| `docs/designs/**` (PNG/tree.json) | 상황별 | 스펙 근거로 쓰면 커밋, 일회성 확인이면 미커밋 |
| `.env` | ❌ 금지 | gitignored |
| `tool/.dart_tool/`, `tool/pubspec.lock` | ❌ | gitignored / 로컬 전용 |

## 주의

- 게이트(`scripts/local_ci.sh`)는 이 도구를 건드리지 않는다 — analyzer 는 숨김 폴더(`.claude/`)를 스캔하지 않고, 자체 pubspec 으로 패키지도 분리됨.
- 토큰을 생성했으면 게이트 실행 전 `dart format lib/design_system/generated/` 1회 (생성기 출력이 포맷과 다를 수 있음).
- Figma file key 가 디자인시스템 파일과 다른 파일이면 `.env` 의 `FIGMA_FILE_KEY` 교체 후 실행.
