---
name: pr
description: dev/main 대상 PR 생성(base 인자) — 로컬 CI(scripts/local_ci.sh) green 강제, 정형 체크리스트(.github/PULL_REQUEST_TEMPLATE.md) + [QA-POINT] 수집으로 본문 구성, 그리고 체크리스트를 isolate 2채널 + codex 3채널로 적대 검증해 기계검증 항목은 자동 체크한다. 커밋 본문·PR 산문은 humanize-korean 으로 다듬고 최대한 일상어로(내부 약어 AC/Phase/mutation 등은 풀어 씀), 👤 사람확인 항목은 근거를 풀어 써 읽기 쉽게 만든다. GitHub Actions 는 수동 전용이라 이 스킬이 유일한 PR 게이트다. (feature → dev; dev→main 은 릴리스 시점 별도 PR)
---

# /pr — 로컬 게이트 + 3채널 검증 기반 PR 생성

> 정책(2026-06-11): Actions 자동 실행은 과금 방지로 꺼져 있다(ci.yml 은 workflow_dispatch 수동 전용).
> **PR 의 품질 증거는 이 스킬이 로컬에서 만든다.**
>
> 정책(2026-06-25): **feature 브랜치 PR 의 base 는 `dev`**. `main` 직접 PR 금지(`main`·`dev` 직접 push 도
> pre-push 훅 차단). `dev`→`main` 은 릴리스 시점 별도 PR.
>
> 정책(2026-07-01): **체크리스트 자동 검증.** 정형 체크리스트 + QA-POINT 를 isolate 1차 감사관 +
> isolate 적대적 반증자 + codex(가능 시) 3채널로 검증한다. **기계검증 항목만** 3채널 만장일치 + mutation
> 실증 시 봇이 자동 체크(🤖). **시각 정합·UX 등 사람판단 항목은 자동 체크 금지**(👤, 봇 의견만 첨부).

## base 결정 (Git-Flow-lite)

`/pr [base]` 인자로 base. **기본 = `dev`**(`feat|fix/* → dev`). 릴리스는 `/pr main`(`dev → main`).
인자 없으면 `dev`. 현재 브랜치가 `dev` 면 base 는 `main`(dev→main 릴리스). 아래 `<base>` = 이 값.

## 절차 (순서 고정)

### 0. QA·Figma 산물 정리 (필수)
```bash
scripts/clean_qa_artifacts.sh
```
- `docs/designs/` 하위 이미지(sim_*/figma_* 등)는 커밋 안 함. **보존**: `docs/designs/**/*.md` ·
  `docs/figma-snapshots/` · `assets/` · `lib/design_system/generated/`.
- **가드**: 정리 후 `git diff --cached --name-only | grep -E 'docs/designs/.*\.(png|jpe?g|webp)$'` 가 비어야 함.

### 1. 작업 커밋 확정 (검증 전 필수)
- 변경이 미커밋이면 **논리적(thematic) Conventional 커밋**으로 묶어 커밋한다. 버그 수정엔 실패-먼저 회귀테스트
  (`@Tags(['regression'])`)를 동봉(DoD). 커밋 본문에 검증 포인트는 `[QA-POINT]` 줄로.
- **커밋 본문은 `humanize-korean` 스킬로 다듬고, 최대한 일상어로 쓴다** — 제목(Conventional prefix)은 그대로
  두고, 본문 한국어 설명만 AI 티(번역투·상투구·과한 불릿·이모지)를 걷어내 사람이 쓴 톤으로. **약어·내부용어
  (Phase 번호·ACnn·mutation·fanout 등)를 그대로 쓰지 말고, 처음 나올 때 한 번 풀어 쓴다**(예: "AC10" →
  "자정 자동 갱신 요구사항(AC10)"). `[QA-POINT]` 줄과 Co-Authored-By 트레일러는 형식 그대로 유지.
- **왜 검증 전에 커밋?** 3채널 검증의 반증자가 mutation testing 으로 파일을 변이→복원하는데, 미커밋 상태면
  그 `git restore` 가 **내 미커밋 수정을 clobber** 한다(실제 발생). 커밋 후 검증하면 worktree 격리 사본이
  HEAD(=커밋 트리)에서 떠 안전하고, 검증 대상도 명확해진다.
- 푸시: `git push -u origin <브랜치>`(feature 브랜치는 훅 통과). base 보다 많이 뒤처졌으면 먼저 최신 `<base>`
  를 머지해 충돌을 해소한다(머지 후 게이트 재실행).

### 2. 로컬 CI 실행 (필수)
```bash
scripts/local_ci.sh        # ci.yml 1:1 패리티
```
- codegen → format → analyze → custom_lint → 경계/asset/SnackBar/actionKind 가드 → verify_lints →
  i18n parity → test → gitleaks(전체 히스토리) → web 릴리스 빌드.
- **PIPESTATUS 주의**: `local_ci.sh | tee log` 는 tee 의 exit(0)을 반환해 실패를 가린다 →
  `set -o pipefail` 또는 리다이렉트 후 `echo $?` 로 **진짜 종료코드**를 확인하라.
- 빨강이면 중단·수정·재실행. 마지막 "ALL GREEN" 줄을 본문 증거로.

### 3. 체크리스트 구성 (정형 템플릿 + QA-POINT)
- **정형 체크리스트**: `.github/PULL_REQUEST_TEMPLATE.md` 의 항목(유명 repo·Google eng-practices·DoD 발췌,
  각 항목에 `🤖[기계검증]`/`👤[사람판단]` 라벨)을 본문에 싣는다.
- **QA-POINT(피처별)**: ```git log origin/<base>..HEAD --grep='\[QA-POINT\]' --format='- [ ] %s'``` 로 수집.
- 각 항목을 검증 spec 으로 변환: `{ key, claim(검증 가능한 한 문장), files:[diff 에서 관련 파일], goldens:[시각이면], kind:'machine'|'human' }`.
  - `kind='machine'` = 테스트/grep/스펙으로 자동 검증 가능(로직·계약·토큰 값·회귀 커버). `kind='human'` = 실기 시각 정합·UX·가독성.

### 4. 3채널 QA 자동 검증 (기본 항상 실행)
> 비용 큼(이 단계가 수십만~1M 토큰). 그래도 **기본 풀가동**(품질 우선). 항목 수가 많으면 machine 항목 위주로.

1. **isolate 2채널**(1차 감사관 + 적대적 반증자) — 워크플로로:
   ```
   Workflow({ scriptPath: ".claude/skills/pr/qa-verify.workflow.js", args: { items: [ …위 spec… ] } })
   ```
   machine 항목의 반증자는 **worktree 격리**에서 mutation testing(값 변이→테스트 FAIL 확인→원복)으로 회귀가
   load-bearing 임을 실증한다(스크립트가 자동 설정).
2. **codex 3번째 채널**(가능 시) — 항목마다 프롬프트 파일을 만들어 병렬:
   ```bash
   .claude/skills/pr/codex-verify.sh <key> <prompt-file> [golden.png ...]   # stdout = verdict JSON
   ```
   `codex` 없거나 비정상 종료(exit≠0)면 **isolate 2번째 렌즈로 폴백**하고 본문에 "codex 불가" 표기.
   (codex 규약: 프롬프트는 stdin, `-i` 는 greedy — 스크립트가 처리.)
3. **종합·체크 규칙**:
   - **🤖 자동 체크**: `kind='machine'` AND (isolate 1차 + isolate 반증 + codex) **만장일치 pass** AND
     반증자 **mutation 실증** 있을 때만 `[x]` + 근거(file:line·변이 결과) 첨부.
   - **👤 사람 몫**: `kind='human'` 은 자동 체크 금지 — `[ ]` 로 두고 봇 verdict/관찰을 주석으로 첨부("실기 확인 필요").
   - **⚠️ 불일치/실패**: 한 채널이라도 fail/uncertain → `[ ]` 유지 + gap 명시. 이때 **이 세션의 루프를 돈다**:
     상세 개발계획서 작성 → (동작 변경 없이 회귀 잠금 위주로) 구현 → 3채널 **재검증** → 만장일치면 체크.
     구현이 정합한데 테스트만 없는 경우가 흔하다(회귀테스트 추가로 닫는다).
   - **flaky 의심**: 새 테스트가 가끔 실패한다고 보고되면 랜덤 순서로 10회+ 반복해 결정성 확인(누수면 수정).

### 5. PR 생성/갱신 (`gh pr create --base <base> --head <브랜치>`; 갱신은 `gh pr edit <N> --body-file`)
- 제목: 대표 커밋 Conventional 형식.
- 본문: `## 요약` · `## 커밋 구성`(표) · `## 검증 — 로컬 CI`(ALL GREEN + 실행 일시/툴체인) ·
  `## 체크리스트`(정형 + QA-POINT, 각 `[x]`/`[ ]` 에 🤖/👤 + 근거) · `## 검증 방식`(3채널·codex 가용 여부) ·
  끝에 `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- **본문 산문은 `humanize-korean` 스킬로 다듬고, 최대한 일상어로 쓴다** — 특히 `## 요약`, 그리고 각 체크 항목의
  근거/관찰 주석. 체크박스·표·라벨(🤖/👤)·파일:라인 근거·명령어 블록은 기계가 읽는 계약이라 형식 그대로 두고,
  **사람이 읽는 설명 문장만** 자연스러운 한국어로. 목표는 리뷰어가 "사람이 뭘 확인해야 하는지"를 한 번에
  읽어내는 것.
- **약어·내부용어 금지(풀어 쓰기).** `AC10`·`AC7`·`P5`·`GWT`·`mock echo`·`tautology`·`fanout`·`mutation` 처럼
  팀 내부에서만 통하는 말을 그대로 두지 않는다. 처음 나올 때 일상어로 풀어 쓴다 — 예: `AC10` → "자정이 지나면
  자동으로 갱신되는 요구사항", `GWT` → "이런 상황에서 이렇게 동작한다 형식의 요구사항", `tautology` →
  "가짜 값을 넣고 그 값이 그대로 나왔는지 보는 헛 테스트". 리뷰어가 스펙 문서를 안 열어도 문장만으로 이해되게.
- **👤 항목은 판단만 넘기지 말고 근거를 풀어 쓴다**: 무엇을·어디서(파일:라인/화면)·어떤 기준으로 봐야 하는지,
  봇 3채널이 이미 뭘 확인했고 사람 몫으로 남은 건 정확히 무엇인지 한두 문장으로 명시. "사람 확인 필요" 같은
  빈 문구 금지.
- **정직성**: 🤖 자동 체크 항목은 "기계 3채널 검증"임을, 👤 항목은 "사람 실기 확인 필요"임을 본문이 분명히 구분.

### 6. (선택) GitHub Actions 수동 검증 — 리뷰어가 원하면 `gh workflow run ci --ref <브랜치>`(과금, 기본 안 함).

## 머지 후
- `gh pr merge <N> --merge --delete-branch`(서버사이드 — 로컬 훅 우회). 머지 후 로컬 `dev` 전환·pull.
- `dev`→`main`(릴리스)에 영향 주는 변경(버전 핀·정책)이면 메모리/공지 기록.

## 주의
- 작업은 전용 worktree/브랜치에서. local_ci.sh ↔ ci.yml 스텝은 lockstep(한쪽 바꾸면 같이).
- 자동 체크는 **기계검증 + 만장일치 + mutation 실증**일 때만 — 그 외엔 사람 몫(자화자찬 방지). [[qa-independent-verification]]
- 헬퍼: `qa-verify.workflow.js`(isolate 2채널) · `codex-verify.sh`(codex 채널) · `qa-verdict-schema.json`(verdict 형식).
