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
"$herdr" workspace list >/dev/null 2>&1 || { echo "live: no running herdr server" >&2; exit 1; }
original_ws=$("$herdr" api snapshot | jq -r '.result.snapshot.focused_workspace_id')
tmp=$(mktemp -d)

scratch=()
cleanup() {
  local ws
  for ws in "${scratch[@]}"; do "$herdr" workspace close "$ws" >/dev/null 2>&1 || true; done
  [[ -z $original_ws ]] || "$herdr" workspace focus "$original_ws" >/dev/null 2>&1 || true
  rm -rf "$tmp"
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
  env -u HERDR_ACTIVE_PANE_ID HERDR_BIN_PATH="${TEST_HERDR_BIN:-$herdr}" HERDR_PANE_ID="$pane" HERDR_MARK_NOTIFY=0 \
    bash "$root/herdr-mark" "$@" 2>"$tmp/last-error" || rc=$?
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

t "cross-tab join"
c=$("$herdr" tab create --workspace "$ws" --no-focus | jq -r .result.root_pane.pane_id)
on "$a" toggle
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

t "cross-tab swap keeps the two tab ids"
old_b_tab=$(tab_of "$b")
old_c_tab=$(tab_of "$c")
on "$b" toggle
on "$c" swap
check rc "$rc" 0
check "b tab" "$(tab_of "$b")" "$old_c_tab"
check "c tab" "$(tab_of "$c")" "$old_b_tab"
check marked "$(marked)" ""

t "cross-workspace swap preserves each pane's rectangle"
old_c_rect=$("$herdr" pane layout --pane "$c" | jq -c --arg id "$c" '.result.layout.panes[] | select(.pane_id == $id) | .rect')
old_d_rect=$("$herdr" pane layout --pane "$d" | jq -c --arg id "$d" '.result.layout.panes[] | select(.pane_id == $id) | .rect')
c_terminal=$("$herdr" pane get "$c" | jq -r .result.pane.terminal_id)
d_terminal=$("$herdr" pane get "$d" | jq -r .result.pane.terminal_id)
on "$c" toggle
on "$d" swap
check rc "$rc" 0
new_c=$("$herdr" pane list --workspace "$ws2" | jq -r --arg id "$c_terminal" '.result.panes[] | select(.terminal_id == $id) | .pane_id')
new_d=$("$herdr" pane list --workspace "$ws1" | jq -r --arg id "$d_terminal" '.result.panes[] | select(.terminal_id == $id) | .pane_id')
check "c workspace" "${new_c%%:*}" "$ws2"
check "d workspace" "${new_d%%:*}" "$ws1"
check "c rectangle" "$("$herdr" pane layout --pane "$new_c" | jq -c --arg id "$new_c" '.result.layout.panes[] | select(.pane_id == $id) | .rect')" "$old_d_rect"
check "d rectangle" "$("$herdr" pane layout --pane "$new_d" | jq -c --arg id "$new_d" '.result.layout.panes[] | select(.pane_id == $id) | .rect')" "$old_c_rect"
check "c focused" "$("$herdr" pane layout --pane "$new_c" | jq -r .result.layout.focused_pane_id)" "$new_c"
check marked "$(marked)" ""

t "two single-pane workspaces swap without losing tabs"
new_workspace
single_a_ws=$ws
single_a="$ws:p1"
single_a_tab=$(tab_of "$single_a")
new_workspace
single_b_ws=$ws
single_b="$ws:p1"
single_b_tab=$(tab_of "$single_b")
before_single_ws=$("$herdr" api snapshot | jq -r .result.snapshot.focused_workspace_id)
on "$single_a" toggle
on "$single_b" swap
check rc "$rc" 0
check "a tabs" "$(tab_count "$single_a_ws")" 1
check "b tabs" "$(tab_count "$single_b_ws")" 1
check "a tab kept" "$("$herdr" tab list --workspace "$single_a_ws" | jq -r '.result.tabs[0].tab_id')" "$single_a_tab"
check "b tab kept" "$("$herdr" tab list --workspace "$single_b_ws" | jq -r '.result.tabs[0].tab_id')" "$single_b_tab"
check helpers "$("$herdr" pane list | jq '[.result.panes[] | select(.tokens.swap_helper == "1")] | length')" 0
check marked "$(marked)" ""
check view "$("$herdr" api snapshot | jq -r .result.snapshot.focused_workspace_id)" "$before_single_ws"

t "cross-workspace swap preserves a nested split and shell processes"
new_workspace
cherry_ws=$ws
cherry_m="$ws:p1"
cherry_x=$(split "$cherry_m" right)
split "$cherry_x" down >/dev/null
new_workspace
cherry_t="$ws:p1"
before_m_layout=$("$herdr" pane layout --pane "$cherry_m" | jq -c '.result.layout.splits | map({direction, ratio, rect})')
before_t_layout=$("$herdr" pane layout --pane "$cherry_t" | jq -c '.result.layout.splits | map({direction, ratio, rect})')
before_m_rect=$("$herdr" pane layout --pane "$cherry_m" | jq -c --arg id "$cherry_m" '.result.layout.panes[] | select(.pane_id == $id) | .rect')
before_t_rect=$("$herdr" pane layout --pane "$cherry_t" | jq -c --arg id "$cherry_t" '.result.layout.panes[] | select(.pane_id == $id) | .rect')
cherry_m_pid=$("$herdr" pane process-info --pane "$cherry_m" | jq -r .result.process_info.shell_pid)
cherry_t_pid=$("$herdr" pane process-info --pane "$cherry_t" | jq -r .result.process_info.shell_pid)
cherry_m_terminal=$("$herdr" pane get "$cherry_m" | jq -r .result.pane.terminal_id)
cherry_t_terminal=$("$herdr" pane get "$cherry_t" | jq -r .result.pane.terminal_id)
on "$cherry_m" toggle
on "$cherry_t" swap
check rc "$rc" 0
new_m=$("$herdr" pane list | jq -r --arg id "$cherry_m_terminal" '.result.panes[] | select(.terminal_id == $id) | .pane_id')
new_t=$("$herdr" pane list | jq -r --arg id "$cherry_t_terminal" '.result.panes[] | select(.terminal_id == $id) | .pane_id')
check "m workspace" "${new_m%%:*}" "${cherry_t%%:*}"
check "t workspace" "${new_t%%:*}" "$cherry_ws"
check "m rectangle" "$("$herdr" pane layout --pane "$new_m" | jq -c --arg id "$new_m" '.result.layout.panes[] | select(.pane_id == $id) | .rect')" "$before_t_rect"
check "t rectangle" "$("$herdr" pane layout --pane "$new_t" | jq -c --arg id "$new_t" '.result.layout.panes[] | select(.pane_id == $id) | .rect')" "$before_m_rect"
check "m tab splits" "$("$herdr" pane layout --pane "$new_t" | jq -c '.result.layout.splits | map({direction, ratio, rect})')" "$before_m_layout"
check "t tab splits" "$("$herdr" pane layout --pane "$new_m" | jq -c '.result.layout.splits | map({direction, ratio, rect})')" "$before_t_layout"
check "m shell" "$("$herdr" pane process-info --pane "$new_m" | jq -r .result.process_info.shell_pid)" "$cherry_m_pid"
check "t shell" "$("$herdr" pane process-info --pane "$new_t" | jq -r .result.process_info.shell_pid)" "$cherry_t_pid"
check "m focused" "$("$herdr" pane layout --pane "$new_m" | jq -r .result.layout.focused_pane_id)" "$new_m"
check marked "$(marked)" ""

t "a refused second move restores the original live layouts"
new_workspace
fault_m="$ws:p1"
split "$fault_m" right >/dev/null
new_workspace
fault_t="$ws:p1"
fault_m_terminal=$("$herdr" pane get "$fault_m" | jq -r .result.pane.terminal_id)
fault_m_layout=$("$herdr" pane layout --pane "$fault_m" | jq -c '.result.layout | {splits: [.splits[] | {direction, ratio, rect}], panes: [.panes[].rect]}')
fault_t_layout=$("$herdr" pane layout --pane "$fault_t" | jq -c '.result.layout | {splits: [.splits[] | {direction, ratio, rect}], panes: [.panes[].rect]}')
on "$fault_m" toggle
printf '0\n' >"$tmp/move-count"
export HERDR_MARK_TEST_REAL_HERDR="$herdr"
export HERDR_MARK_TEST_MOVE_COUNTER="$tmp/move-count"
export HERDR_MARK_TEST_FAIL_MOVE=2
TEST_HERDR_BIN="$root/tests/fail-shim.sh" on "$fault_t" swap
unset HERDR_MARK_TEST_REAL_HERDR HERDR_MARK_TEST_MOVE_COUNTER HERDR_MARK_TEST_FAIL_MOVE
check rc "$rc" 1
restored_m=$("$herdr" pane list | jq -r --arg id "$fault_m_terminal" '.result.panes[] | select(.terminal_id == $id) | .pane_id')
check "m layout" "$("$herdr" pane layout --pane "$restored_m" | jq -c '.result.layout | {splits: [.splits[] | {direction, ratio, rect}], panes: [.panes[].rect]}')" "$fault_m_layout"
check "t layout" "$("$herdr" pane layout --pane "$fault_t" | jq -c '.result.layout | {splits: [.splits[] | {direction, ratio, rect}], panes: [.panes[].rect]}')" "$fault_t_layout"
check marked "$(marked)" "$restored_m"
check "error names marked pane" "$(grep -Fc "$restored_m is still marked" "$tmp/last-error")" 1
check peers "$("$herdr" pane list | jq '[.result.panes[] | select(.tokens["swap-peer"] == "1")] | length')" 0
on "$fault_t" clear

t "swap returns to the viewed target tab with the marked pane focused"
new_workspace
view_m="$ws:p1"
split "$view_m" right >/dev/null
view_tab_info=$("$herdr" tab create --workspace "$ws" --no-focus)
view_t=$(jq -r .result.root_pane.pane_id <<<"$view_tab_info")
view_target_tab=$(jq -r .result.tab.tab_id <<<"$view_tab_info")
"$herdr" workspace focus "$ws" >/dev/null
"$herdr" tab focus "$view_target_tab" >/dev/null
on "$view_m" toggle
on "$view_t" swap
check rc "$rc" 0
check "viewed tab" "$("$herdr" api snapshot | jq -r .result.snapshot.focused_tab_id)" "$view_target_tab"
check "focused pane" "$("$herdr" api snapshot | jq -r .result.snapshot.focused_pane_id)" "$view_m"
check marked "$(marked)" ""

if ((failures)); then
  echo "$failures live check(s) failed" >&2
  exit 1
fi
echo "all live tests passed"
