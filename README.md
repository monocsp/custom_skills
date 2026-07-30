# custom_skills

이 프로젝트는 개인적으로 사용하기 위해 만든 skills들의 모음집이다.

## 목차

### 스킬

| 이름 | 하는 일 | 버전 |
| --- | --- | --- |
| [`custom-skills-guide`](skills/custom-skills-guide/SKILL.md) | 이 레포의 카탈로그·구조·규칙 안내 (메타) | v1.0.0 |
| [`git-commit-pr`](skills/git-commit-pr/SKILL.md) | 커밋 메시지·푸시·PR을 대형 OSS 관행에 맞춰 작성 | v1.0.0 |
| [`humanize-korean`](skills/humanize-korean/SKILL.md) | AI가 쓴 한글의 "AI 티"를 탐지·분류해 자연스럽게 윤문 | v1.5.0 |

### 에이전트

전부 [`humanize-korean`](skills/humanize-korean/SKILL.md) 파이프라인 소속이다.
Claude Code가 `~/.claude/agents/*.md` 를 평평하게만 인식하므로 스킬 폴더가 아니라
[`agents/`](agents/) 에 둔다 ([이유](docs/CONVENTIONS.md)).

| 이름 | 역할 |
| --- | --- |
| [`ai-tell-detector`](agents/ai-tell-detector.md) | AI 티 구간 탐지 → JSON 리포트 |
| [`korean-style-rewriter`](agents/korean-style-rewriter.md) | 탐지 구간을 수술적으로 윤문 |
| [`naturalness-reviewer`](agents/naturalness-reviewer.md) | 잔존 AI 티 / 과윤문 판정 |
| [`content-fidelity-auditor`](agents/content-fidelity-auditor.md) | 원문 대비 의미 훼손 감사 |
| [`humanize-monolith`](agents/humanize-monolith.md) | 단일 호출 Fast Path 윤문 |
| [`korean-ai-tell-taxonomist`](agents/korean-ai-tell-taxonomist.md) | AI 티 분류 체계 관리 (SSOT) |
| [`taxonomy-gap-analyzer`](agents/taxonomy-gap-analyzer.md) | 본진 분류 ↔ 외부 연구 갭 분석 |
| [`translationese-research-distiller`](agents/translationese-research-distiller.md) | 번역투 학술 보고서 구조화 증류 |
| [`korean-translation-scholar`](agents/korean-translation-scholar.md) | 번역학 인용 계보 큐레이션 |
| [`post-editese-metric-engineer`](agents/post-editese-metric-engineer.md) | post-editese 정량 지표 엔지니어링 |
| [`quick-rules-integrator`](agents/quick-rules-integrator.md) | 슬림 룰북 통합·회귀 검증 |
| [`humanize-web-architect`](agents/humanize-web-architect.md) | 웹 서비스 확장 설계 |

## 구조

```
custom_skills/
├── docs/                   # 사람이 읽는 문서
│   ├── CONVENTIONS.md      # 작성·배치 규칙 (새 스킬 만들기 전 필독)
│   └── INSTALL.md          # 설치·마이그레이션
├── skills/<name>/SKILL.md  # 스킬 본체 (평평하게 — 카테고리 폴더 금지)
│   ├── references/         # 길어지는 상세 규칙
│   └── scripts/            # 결정론적 처리
├── agents/<name>.md        # 서브에이전트 (평평하게)
├── commands/<name>.md      # 슬래시 커맨드
└── scripts/install.sh      # 레포 → ~/.claude 심볼릭 링크
```

`skills/` 와 `agents/` 를 평평하게 두는 이유, 폴더를 중첩하면 왜 로드되지 않는지는
[`docs/CONVENTIONS.md`](docs/CONVENTIONS.md) 참조.

## 설치

```bash
./scripts/install.sh --dry-run   # 무엇을 할지 먼저 확인
./scripts/install.sh             # ~/.claude 로 심볼릭 링크
```

복사가 아니라 링크라서 이 레포가 항상 원본이다. 자세한 절차와 기존 스킬
마이그레이션은 [`docs/INSTALL.md`](docs/INSTALL.md).
