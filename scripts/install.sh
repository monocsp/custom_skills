#!/usr/bin/env bash
#
# custom_skills → ~/.claude 심볼릭 링크 설치기
#
#   ./scripts/install.sh              링크 걸기
#   ./scripts/install.sh --dry-run    무엇을 할지만 출력하고 아무것도 바꾸지 않음
#   ./scripts/install.sh --uninstall  이 저장소를 가리키는 링크만 제거
#
# 원칙 (docs/INSTALL.md 의 설치 인터페이스 명세를 따른다):
#   - 저장소가 원본이다. 복사하지 않고 링크만 건다.
#   - 대상에 실체 파일/디렉터리가 있으면 절대 옮기거나 지우지 않는다.
#     충돌을 보고하고 마이그레이션 절차로 안내한 뒤 종료 코드로 알린다.
#   - 항목 단위로 링크한다. ~/.claude/skills 디렉터리 자체를 통째로 바꾸지 않는다.
#     (이 저장소가 관리하지 않는 다른 로컬 스킬을 보존하기 위해)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"

DRY_RUN=0
UNINSTALL=0
CONFLICTS=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)   sed -n '3,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "알 수 없는 옵션: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
run() { if [ "$DRY_RUN" -eq 1 ]; then say "      [dry-run] $*"; else "$@"; fi; }

# .installignore 에 적힌 이름은 링크하지 않는다. 저장소에는 두되 전역 설치는 막을 때 쓴다.
IGNORE_FILE="$REPO/.installignore"
is_ignored() {
  [ -f "$IGNORE_FILE" ] || return 1
  local name="$1" line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"                    # 주석 제거
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -n "$line" ] || continue
    [ "$line" = "$name" ] && return 0
  done < "$IGNORE_FILE"
  return 1
}

# $1=저장소 항목 절대경로  $2=링크로 만들 대상 경로
link_one() {
  local src="$1" dest="$2" name; name="$(basename "$dest")"

  if [ -L "$dest" ]; then
    local current; current="$(readlink "$dest")"
    if [ "$current" = "$src" ]; then
      say "  =  $name (이미 연결됨)"
      return 0
    fi
    say "  ~  $name (링크 교체)"
    say "      이전: $current"
    say "      이후: $src"
    run ln -sfn "$src" "$dest"
    return 0
  fi

  if [ -e "$dest" ]; then
    # 실체 파일/디렉터리 — 데이터에 손대지 않는다
    say "  !  $name — 실체 항목이 이미 있어 건너뜀"
    say "      경로: $dest"
    say "      docs/INSTALL.md 의 '같은 이름의 실체 폴더 마이그레이션' 절차를 따른 뒤 다시 실행하세요."
    CONFLICTS=$((CONFLICTS + 1))
    return 0
  fi

  say "  +  $name"
  run ln -sfn "$src" "$dest"
}

unlink_one() {
  local src="$1" dest="$2" name; name="$(basename "$dest")"

  if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
    return 0
  fi
  if [ ! -L "$dest" ]; then
    say "  s  $name (실체 항목이므로 건너뜀)"
    return 0
  fi
  if [ "$(readlink "$dest")" != "$src" ]; then
    say "  s  $name (다른 곳을 가리키는 링크이므로 건너뜀 → $(readlink "$dest"))"
    return 0
  fi

  say "  -  $name"
  run rm "$dest"
}

# $1=저장소 하위 디렉터리  $2=~/.claude 하위 디렉터리  $3=glob 패턴
sync_dir() {
  local sub="$1" target_sub="$2" pattern="$3"
  local src_dir="$REPO/$sub" target_dir="$CLAUDE_HOME/$target_sub"

  [ -d "$src_dir" ] || return 0

  local -a items=()
  local -a skipped=()
  local src name
  for src in "$src_dir"/$pattern; do
    [ -e "$src" ] || continue
    name="$(basename "$src")"
    case "$name" in .gitkeep|.DS_Store) continue ;; esac
    if is_ignored "$name"; then skipped+=("$name"); continue; fi
    items+=("$src")
  done

  if [ "${#skipped[@]}" -gt 0 ] && [ "$UNINSTALL" -eq 0 ]; then
    say "$sub/ — .installignore 로 제외 ${#skipped[@]}건: ${skipped[*]}"
  fi

  if [ "${#items[@]}" -eq 0 ]; then
    say "$sub/ — 항목 없음, 건너뜀"
    return 0
  fi

  say "$sub/ → $target_dir/"
  [ "$UNINSTALL" -eq 1 ] || run mkdir -p "$target_dir"

  for src in "${items[@]}"; do
    if [ "$UNINSTALL" -eq 1 ]; then
      unlink_one "$src" "$target_dir/$(basename "$src")"
    else
      link_one "$src" "$target_dir/$(basename "$src")"
    fi
  done
}

say "저장소: $REPO"
say "대상:   $CLAUDE_HOME"
[ "$DRY_RUN"   -eq 1 ] && say "모드:   dry-run (아무것도 바꾸지 않음)"
[ "$UNINSTALL" -eq 1 ] && say "모드:   uninstall"
say ""

# skills/ 는 디렉터리 단위, agents/ 와 commands/ 는 .md 파일 단위로 링크한다.
# Claude Code 가 각각 ~/.claude/skills/<name>/SKILL.md 와 ~/.claude/agents/<name>.md
# 위치에서 찾기 때문이다.
sync_dir "skills"   "skills"   "*"
sync_dir "agents"   "agents"   "*.md"
sync_dir "commands" "commands" "*.md"

say ""
if [ "$UNINSTALL" -eq 1 ]; then
  say "해제 완료. 저장소 원본과 마이그레이션 백업은 그대로 남아 있습니다."
  exit 0
fi

if [ "$CONFLICTS" -gt 0 ]; then
  say "충돌 $CONFLICTS 건 — 위 항목은 연결되지 않았습니다. 데이터는 그대로입니다."
  say "확인: ls -la $CLAUDE_HOME/skills"
  exit 1
fi

say "완료. 확인: ls -la $CLAUDE_HOME/skills"
say "새 스킬은 Claude Code 세션을 새로 시작해야 인식됩니다."
