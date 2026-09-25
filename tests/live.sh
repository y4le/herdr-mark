#!/usr/bin/env bash
#
# Live tests against the running herdr server. They build layouts in unfocused
# scratch workspaces, run herdr-mark as a plugin action would (HERDR_PANE_ID
# set to the "focused" pane), check the resulting geometry, then close the
# scratch workspaces. Your focus and other workspaces are left alone.
#
#   HERDR_BIN_PATH  herdr binary to use (default: herdr on PATH)

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
herdr=${HERDR_BIN_PATH:-herdr}
command -v "$herdr" >/dev/null || { echo "live: herdr not found" >&2; exit 1; }
"$herdr" pane current >/dev/null 2>&1 || { echo "live: no running herdr server" >&2; exit 1; }

scratch=()
cleanup() {
  local ws
  for ws in "${scratch[@]}"; do "$herdr" workspace close "$ws" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

failures=0
current=""

# new_workspace: create an unfocused scratch workspace and set $ws to its id.
# (Not called in $(…): the cleanup list has to be updated in this shell.)
new_workspace() {
  ws=$("$herdr" workspace create --no-focus --label "herdr-mark-live" --cwd /tmp |
    jq -r .result.workspace.workspace_id)
  scratch+=("$ws")
}

split() {
  "$herdr" pane split "$1" --direction "$2" --no-focus | jq -r .result.pane.pane_id
}

on() {
  local pane=$1
  shift
  rc=0
  env -u HERDR_ACTIVE_PANE_ID HERDR_BIN_PATH="$herdr" HERDR_PANE_ID="$pane" HERDR_MARK_NOTIFY=0 \
    bash "$root/herdr-mark" "$@" 2>/dev/null || rc=$?
}

# geometry <pane>: "id@x,y" for every pane in its tab, top-left first.
geometry() {
  "$herdr" pane layout --pane "$1" |
    jq -r '[.result.layout.panes | sort_by(.rect.y, .rect.x)[] | "\(.pane_id)@\(.rect.x),\(.rect.y)"] | join(" ")'
}

# arrangement <a> <b>: how b sits relative to a (right-of | below | left-of | above).
arrangement() {
  "$herdr" pane layout --pane "$1" | jq -r --arg a "$1" --arg b "$2" '
    .result.layout.panes as $p
    | ($p[] | select(.pane_id == $a) | .rect) as $ra
    | ($p[] | select(.pane_id == $b) | .rect) as $rb
    | if $rb.x > $ra.x then "right-of" elif $rb.x < $ra.x then "left-of"
      elif $rb.y > $ra.y then "below" elif $rb.y < $ra.y then "above" else "same" end'
}

marked() { "$herdr" pane list | jq -r '[.result.panes[] | select(.tokens.mark == "1") | .pane_id] | join(" ")'; }
title() { "$herdr" pane get "$1" | jq -r '.result.pane.title'; }
tab_of() { "$herdr" pane get "$1" | jq -r '.result.pane.tab_id'; }
tab_count() { "$herdr" tab list --workspace "$1" | jq '.result.tabs | length'; }

check() {
  if [[ $2 != "$3" ]]; then
    echo "  FAIL [$current] $1: got '$2', want '$3'" >&2
    failures=$((failures + 1))
  fi
}

t() { current=$1; }

[[ -z $(marked) ]] || { echo "live: a pane is already marked; run 'herdr-mark clear' first" >&2; exit 1; }

new_workspace
a="$ws:p1"
b=$(split "$a" right)

t "mark and unmark"
on "$b" toggle
check marked "$(marked)" "$b"
on "$a" toggle
check "mark moved" "$(marked)" "$a"
check "old title" "$(title "$b")" null
check title "$(title "$a")" "◆ marked"
on "$a" toggle
check marked "$(marked)" ""
check title "$(title "$a")" null

for dir in down left up right; do
  t "same-tab join $dir"
  on "$a" toggle
  on "$b" join "$dir"
  check rc "$rc" 0
  want=$(case $dir in right) echo right-of ;; down) echo below ;; left) echo left-of ;; up) echo above ;; esac)
  check "a relative to b" "$(arrangement "$b" "$a")" "$want"
  check tabs "$(tab_count "$ws")" 1
  check marked "$(marked)" ""
done

t "same-tab swap"
before=$(geometry "$a")
on "$a" toggle
on "$b" swap
check rc "$rc" 0
check swapped "$(geometry "$a")" "$(sed "s/$a@/X@/; s/$b@/$a@/; s/X@/$b@/" <<<"$before")"
check marked "$(marked)" ""

t "cross-tab join, and cross-tab swap is refused"
c=$("$herdr" tab create --workspace "$ws" --no-focus | jq -r .result.root_pane.pane_id)
on "$a" toggle
on "$c" swap
check "swap rc" "$rc" 1
check "still marked" "$(marked)" "$a"
on "$c" join right
check rc "$rc" 0
check tab "$(tab_of "$a")" "$(tab_of "$c")"
check "a relative to c" "$(arrangement "$c" "$a")" right-of
check marked "$(marked)" ""

t "zoomed tab is refused"
on "$b" toggle
"$herdr" pane zoom "$c" --on >/dev/null
on "$c" join down
check rc "$rc" 1
"$herdr" pane zoom "$c" --off >/dev/null
on "$b" clear
check marked "$(marked)" ""

t "cross-workspace join gives the pane a new id and clears the mark"
ws1=$ws
new_workspace
ws2=$ws
ws=$ws1
d="$ws2:p1"
on "$a" toggle
on "$d" join down
check rc "$rc" 0
moved=$("$herdr" pane layout --pane "$d" | jq -r --arg d "$d" '.result.layout.panes[] | select(.pane_id != $d) | .pane_id')
check "new id workspace" "${moved%%:*}" "$ws2"
check "moved relative to d" "$(arrangement "$d" "$moved")" below
check title "$(title "$moved")" null
check marked "$(marked)" ""

if ((failures)); then
  echo "$failures live check(s) failed" >&2
  exit 1
fi
echo "all live tests passed"
