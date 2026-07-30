# custom_skills

이 프로젝트는 개인적으로 사용하기 위해 만든 skills들의 모음집이다.

## 목차

| 이름 | 종류 | 하는 일 | 상태 |
| --- | --- | --- | --- |
| [`custom-skills-guide`](skills/custom-skills-guide/SKILL.md) | skill | 이 레포의 카탈로그·구조·규칙 안내 (메타) | 안정 |
| [`git-commit-pr`](skills/git-commit-pr/SKILL.md) | skill | 커밋 메시지·푸시·PR을 대형 OSS 관행에 맞춰 작성 | 안정 |

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
