# 설치 및 해제

이 저장소의 파일을 `~/.claude/`에 복사하지 않는다. `custom_skills`를 원본(source of truth)으로 두고 `scripts/install.sh`가 각 항목에 심볼릭 링크를 만든다. 따라서 수정은 항상 저장소에서 하고, `~/.claude/` 아래 링크 대상 파일을 별도 원본처럼 관리하지 않는다.

> 아래 명령과 동작은 `scripts/install.sh`의 설치 인터페이스 명세이자 현재 구현이다.
> 스크립트를 고칠 때 이 문서도 함께 갱신한다.

## 설치

저장소 루트에서 실행한다. 처음이라면 `--dry-run`으로 무엇을 바꿀지 먼저 확인한다.

```bash
cd /Users/pcs/Documents/GitHub/custom_skills
bash scripts/install.sh --dry-run   # 계획만 출력하고 아무것도 바꾸지 않는다
bash scripts/install.sh             # 실제 링크 생성
```

설치 스크립트는 다음과 같이 동작한다.

1. 스크립트 파일 위치를 기준으로 저장소의 절대 경로를 계산한다. 호출한 현재 디렉터리에 의존하지 않는다.
2. `~/.claude/skills`, `~/.claude/agents`, `~/.claude/commands`가 없으면 생성한다.
3. `skills/<name>` 각각을 `~/.claude/skills/<name>`에 링크한다.
4. `agents/<name>.md` 각각을 `~/.claude/agents/<name>.md`에 링크한다.
5. `commands/<name>.md` 각각을 `~/.claude/commands/<name>.md`에 링크한다.
6. 링크 생성에는 `ln -sfn`을 사용해 같은 링크에 재실행해도 안전한 멱등성을 보장한다.
7. 대상 경로에 같은 이름의 **실체 파일이나 실체 디렉터리**가 있으면 덮어쓰거나 삭제하지 않고 오류와 마이그레이션 안내를 출력한다. `ln -sfn`만으로 실체 디렉터리를 안전하게 교체할 수 있다고 가정해서는 안 된다.
8. 이미 올바른 저장소 항목을 가리키는 링크는 성공으로 처리한다. 다른 위치를 가리키는 링크는 기존 대상과 새 대상을 표시한 뒤 교체 사실을 알린다.
9. 한 항목에서 충돌이 나더라도 데이터에 손대지 않는다. 최종 종료 코드는 충돌 또는 실패가 있었음을 나타내야 한다.
10. 저장소에서 사라진 항목에 대응하는 오래된 링크를 자동 삭제하지 않는다. 해제는 명시적인 `--uninstall`에서만 수행한다.
11. `.gitkeep` 같은 자리표시 파일은 링크 대상에서 제외한다.

충돌이 났을 때의 실제 출력은 다음과 같다. 이때 종료 코드는 `1`이고 기존 데이터는 그대로 남는다.

```text
  !  git-commit-pr — 실체 항목이 이미 있어 건너뜀
      경로: /Users/pcs/.claude/skills/git-commit-pr
      docs/INSTALL.md 의 '같은 이름의 실체 폴더 마이그레이션' 절차를 따른 뒤 다시 실행하세요.

충돌 1 건 — 위 항목은 연결되지 않았습니다. 데이터는 그대로입니다.
```

상위 디렉터리인 `~/.claude/skills` 전체를 저장소의 `skills/`로 교체하지 않고, 그 아래 항목별로 링크한다. 이렇게 해야 이 저장소가 관리하지 않는 다른 로컬 스킬을 보존할 수 있다.

## 설치 검증

먼저 링크 목록을 확인한다.

```bash
ls -la ~/.claude/skills
ls -la ~/.claude/agents
ls -la ~/.claude/commands
```

각 스킬은 다음 형태로 보여야 한다.

```text
<name> -> /Users/pcs/Documents/GitHub/custom_skills/skills/<name>
```

개별 링크와 필수 파일을 추가로 검증한다.

```bash
skill_name='your-skill-name'
test -L "$HOME/.claude/skills/$skill_name"
test -f "$HOME/.claude/skills/$skill_name/SKILL.md"
readlink "$HOME/.claude/skills/$skill_name"
```

`test` 명령이 출력 없이 종료 코드 0을 반환하고, `readlink` 결과가 이 저장소의 해당 경로이면 정상이다. 마지막으로 Claude Code를 새로 시작한 뒤 대표 트리거 문구로 스킬이 발동하는지 확인한다. Claude Code가 실행 중 변경 사항을 즉시 다시 읽는지는 버전에 따라 다를 수 있으므로 **확인 필요**이며, 검증 시에는 재시작을 기본으로 한다.

## 같은 이름의 실체 폴더 마이그레이션

예를 들어 `~/.claude/skills/<name>`이 심볼릭 링크가 아닌 기존 실체 폴더라면 설치 스크립트를 먼저 실행하지 않는다. 아래 순서대로 **백업 → 저장소로 이관 → 검증 → 링크**를 진행한다.

### 1. 상태 확인

검사할 스킬 이름과 경로를 먼저 변수에 넣는다. `skill_name`은 실제 이름으로 바꾼다.
마이그레이션이 끝날 때까지 같은 셸 세션에서 아래 변수를 유지한다.

```bash
skill_name='your-skill-name'
repo_root='/Users/pcs/Documents/GitHub/custom_skills'
source_path="$HOME/.claude/skills/$skill_name"
repo_path="$repo_root/skills/$skill_name"

test -n "$skill_name"
test -e "$source_path" && test ! -L "$source_path"
test ! -e "$repo_path"
```

두 번째 검사가 성공하면 대상은 실체 항목이다. 세 번째 검사가 실패해 저장소에도 같은 이름이 이미 있으면 어느 쪽도 덮어쓰지 말고 두 내용을 비교해 수동 병합한다.

### 2. 기존 폴더 백업

백업 경로를 만든 뒤 같은 이름의 백업이 없는지 검사하고 이동한다.

```bash
backup_stamp="$(date +%Y%m%d-%H%M%S)"
backup_path="$HOME/.claude/skills/${skill_name}.backup-${backup_stamp}"

test ! -e "$backup_path"
mv "$source_path" "$backup_path"
```

백업 폴더가 존재하고 `SKILL.md`를 포함하는지 확인한다.

```bash
test -d "$backup_path"
test -f "$backup_path/SKILL.md"
```

### 3. 저장소로 이관

백업을 그대로 남긴 채 저장소에 복제한다. 복제가 성공하기 전에는 백업을 삭제하지 않는다.

```bash
cp -a "$backup_path" "$repo_path"
```

양쪽 내용을 재귀 비교한다.

```bash
diff -qr "$backup_path" "$repo_path"
```

차이가 없을 때만 다음 단계로 간다. macOS 기본 `cp`(BSD)는 `-a`를 `-pPR`의 별칭으로 지원하며, 이 환경(Darwin 25.5)에서 하위 디렉터리를 포함해 정상 동작하는 것을 확인했다. 다른 환경으로 옮길 때는 `cp -a` 대신 메타데이터를 보존하는 동등한 방법을 쓰되 `diff -qr` 검증은 그대로 수행한다.

### 4. 링크 설치 및 확인

```bash
cd /Users/pcs/Documents/GitHub/custom_skills
bash scripts/install.sh
ls -la ~/.claude/skills
test -L "$HOME/.claude/skills/$skill_name"
readlink "$HOME/.claude/skills/$skill_name"
```

링크가 저장소의 `skills/<name>`을 가리키고 Claude Code에서 정상 동작하는 것을 확인한 뒤에도 백업은 즉시 삭제하지 않는다. 충분히 사용해 데이터가 온전함을 확인한 후 사용자가 직접 보관 또는 삭제를 결정한다.

같은 충돌이 `agents/<name>.md`나 `commands/<name>.md` 실체 파일에서 발생하면 동일한 원칙을 적용한다. 먼저 이름에 타임스탬프를 붙여 백업하고, 저장소의 해당 디렉터리로 복제해 내용을 비교한 다음 링크를 설치한다.

## 해제

전체 해제는 저장소 루트에서 다음 인터페이스를 사용한다.

```bash
cd /Users/pcs/Documents/GitHub/custom_skills
bash scripts/install.sh --uninstall
```

`--uninstall`은 다음 안전 규칙을 따라야 한다.

- 이 저장소 내부를 가리키는 심볼릭 링크만 제거한다.
- `~/.claude/skills`, `~/.claude/agents`, `~/.claude/commands`의 실체 파일·실체 디렉터리는 삭제하지 않는다.
- 다른 저장소나 위치를 가리키는 링크도 삭제하지 않는다.
- 상위 디렉터리가 비어도 자동 삭제하지 않는다.
- 제거한 링크와 건너뛴 항목을 각각 출력한다.
- 저장소 원본과 마이그레이션 백업은 삭제하지 않는다.

해제 후 남은 항목을 확인한다.

```bash
ls -la ~/.claude/skills
ls -la ~/.claude/agents
ls -la ~/.claude/commands
```

개별 항목만 수동 해제해야 한다면 먼저 링크와 대상을 확인한 뒤 링크 경로만 제거한다.

```bash
skill_name='your-skill-name'
link_path="$HOME/.claude/skills/$skill_name"
test -L "$link_path"
readlink "$link_path"
unlink "$link_path"
```

`unlink`에는 저장소 원본 경로가 아니라 `~/.claude/` 아래의 확인된 심볼릭 링크 경로를 전달한다. 실체 폴더에는 실행하지 않는다.
