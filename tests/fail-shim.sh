#!/usr/bin/env bash
# Refuse one pane move while forwarding every other command to the real CLI.
set -euo pipefail

: "${HERDR_MARK_TEST_REAL_HERDR:?}"
: "${HERDR_MARK_TEST_MOVE_COUNTER:?}"
: "${HERDR_MARK_TEST_FAIL_MOVE:?}"

if [[ ${1:-} == pane && ${2:-} == move ]]; then
  n=$(cat "$HERDR_MARK_TEST_MOVE_COUNTER")
  n=$((n + 1))
  printf '%s\n' "$n" >"$HERDR_MARK_TEST_MOVE_COUNTER"
  if ((n == HERDR_MARK_TEST_FAIL_MOVE)); then
    echo '{"result":{"move_result":{"changed":false,"reason":"injected"}}}'
    exit 0
  fi
fi

exec "$HERDR_MARK_TEST_REAL_HERDR" "$@"
