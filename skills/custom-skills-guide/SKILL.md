---
name: custom-skills-guide
description: >
  이 사용자가 직접 만들어 관리하는 스킬 컬렉션(custom_skills 레포)의 카탈로그·구조·규칙 안내.
  트리거 — "내 스킬 뭐 있어", "어떤 스킬 써야 해", "스킬 목록 보여줘", "커스텀 스킬",
  "이 레포 구조 설명", "스킬 어디에 넣어", "새 스킬 추가하려면", "에이전트는 어디에 두나",
  "스킬 설치 어떻게 해", "심볼릭 링크 다시 걸어줘".
  라우팅과 안내만 담당하고 개별 작업 자체는 해당 스킬로 넘긴다.
---

# custom_skills 안내

버전: v1.0.0

사용자가 개인용으로 만든 Claude Code 스킬·에이전트 모음. 레포가 원본이고
`~/.claude/` 로 심볼릭 링크해서 쓴다.

## 이 스킬의 범위

**한다** — 이 레포에 뭐가 있는지, 어디에 넣는지, 이 레포의 규칙이 뭔지 안내.
**안 한다** — 개별 스킬의 실제 작업. 아래 표에서 맞는 스킬로 넘긴다.
**안 한다** — 스킬 작성 방법론 일반론. 그건 `skill-creator` 스킬 담당이다.
새 스킬을 처음부터 만들어 달라는 요청이면 `skill-creator` 를 쓰되,
이 레포의 배치·네이밍 규칙은 `docs/CONVENTIONS.md` 를 따르게 한다.

## 카탈로그

| 이름 | 종류 | 언제 |
| --- | --- | --- |
| `custom-skills-guide` | skill | 이 레포 자체에 대한 메타 질문 |
| `git-commit-pr` | skill | 커밋 메시지 작성, 푸시, PR 생성 |
| `humanize-korean` | skill | AI가 쓴 한글의 "AI 티" 탐지·윤문 |
| 에이전트 12개 | agents | 전부 `humanize-korean` 파이프라인 소속 |
| 개발 루프 11개 | skills | `develop-looping-process` 외 — **분석 중, 전역 설치 금지** |
| 검증자 2개 | agents | `isolated-adversarial-verifier` · `runtime-qa-verifier` |

**개발 루프 파이프라인은 아직 링크 대상이 아니다.** 특정 Flutter 프로젝트에 결합돼
있어 전역 설치하면 무관한 작업에서 발동한다. 구조를 물으면
`skills/develop-looping-process/references/loop-overview.md` 로 안내한다.

`~/.claude` 에는 이 레포가 관리하지 않는 스킬도 함께 있다(`skill-creator`, `md-to-pdf`,
`orca-cli` 등). 링크가 아니라 실체이거나 다른 저장소를 가리키는 항목이며,
`install.sh --uninstall` 은 그것들을 건드리지 않는다.

> 스킬을 추가하면 이 표와 `README.md` 목차를 **같이** 갱신한다.

## 구조

```
custom_skills/
├── README.md              # 사람용 카탈로그 (GitHub 첫 화면)
├── docs/                  # 사람용 문서
│   ├── CONVENTIONS.md     # 작성·배치 규칙  ← 새 스킬 만들기 전 필독
│   └── INSTALL.md         # 심볼릭 링크 설치·마이그레이션
├── skills/<name>/SKILL.md # 스킬 본체
│   ├── references/        # 길어지는 상세 규칙·표·플레이북
│   └── scripts/           # 결정론적 처리는 코드로
├── agents/<name>.md       # 서브에이전트
├── commands/<name>.md     # 슬래시 커맨드
└── scripts/install.sh     # 레포 → ~/.claude 링크
```

## 배치 규칙 (틀리면 로드가 안 된다)

1. **`skills/` 는 평평하게.** Claude Code는 `~/.claude/skills/<name>/SKILL.md`
   딱 한 단계만 인식한다. `skills/korean/humanize/SKILL.md` 처럼 카테고리 폴더를
   끼우면 발견되지 않는다. 분류는 폴더가 아니라 README 표로 한다.
2. **에이전트는 스킬 폴더 안에 넣지 않는다.** `~/.claude/agents/*.md` 에 평평하게
   있어야 로드된다. 소속 관계는 README 표에 표기해서 드러낸다.
3. **복사 말고 심볼릭 링크.** `scripts/install.sh` 가 `ln -sfn` 으로 건다.
   레포가 항상 원본이라 "어느 쪽이 최신인지" 문제가 생기지 않는다.

## description 이 전부다

스킬은 frontmatter `description` 매칭으로 발동한다. 두 가지를 동시에 지켜야 한다.

- **넓혀야 할 것** — 사용자가 실제로 칠 법한 표현을 여러 개 나열한다.
  한 가지 표현만 적으면 조금만 다르게 말해도 안 걸린다.
- **좁혀야 할 것** — 다른 스킬의 트리거 동사를 넣지 않는다. 넣으면 그 스킬을
  가로채서 정작 작업은 안 하고 설명만 하고 끝난다. 이 스킬이 "윤문"을 트리거에
  넣지 않은 이유가 그것이다.

자세한 규칙과 체크리스트는 `docs/CONVENTIONS.md`.
