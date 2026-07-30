#!/usr/bin/env bash
# codex-verify.sh — QA 체크리스트 한 항목을 codex 로 독립 검증(3채널 중 1채널).
#
# 사용:   codex-verify.sh <key> <prompt-file> [image ...]
# 출력:   stdout = verdict JSON(qa-verdict-schema.json 형식)
# 종료:   0 성공 / 127 codex 미설치 / 그 외 codex 오류 → 호출부는 이때 isolate 2번째 렌즈로 폴백.
#
# ⚠️ 호출 규약(이번 세션에서 깨졌던 부분):
#   - 프롬프트는 **stdin(`-`)** 으로 넘긴다. `codex exec -i <FILE>...` 는 greedy 라
#     뒤따르는 positional prompt 를 이미지 파일로 먹어버린다 → "No prompt provided".
#   - 빈 이미지 배열도 set -u 에서 안전하게 확장(`${imgs[@]+...}`).
#   - read-only 샌드박스로 파일 변이 금지(공유 워킹트리 보호).
set -uo pipefail

KEY="${1:?usage: codex-verify.sh <key> <prompt-file> [image ...]}"
PF="${2:?prompt-file required}"
shift 2

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="$HERE/qa-verdict-schema.json"
REPO="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || pwd)"

if ! command -v codex >/dev/null 2>&1; then
  echo "[codex-verify] codex 미설치 — isolate 2번째 렌즈로 폴백하라" >&2
  exit 127
fi

imgs=()
for f in "$@"; do imgs+=(-i "$f"); done

# prompt = stdin(-). 이미지 있으면 -i 로 첨부(codex 비전).
codex exec -s read-only -C "$REPO" --output-schema "$SCHEMA" "${imgs[@]+"${imgs[@]}"}" - < "$PF"
