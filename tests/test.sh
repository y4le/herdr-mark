#!/usr/bin/env bash
#
# Offline tests: run herdr-mark against tests/mock-herdr.sh.
#
# Fixture (focus on w1:p2):
#   workspace w1, tab w1:t1: w1:p1, w1:p2
#   workspace w1, tab w1:t2: w1:p3
#   workspace w2, tab w2:t1: w2:p4

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HERDR_BIN_PATH="$root/tests/mock-herdr.sh"
export HERDR_MARK_TEST_STATE="$tmp/state.json"
export HERDR_MARK_TEST_LOG="$tmp/calls.log"

failures=0
current=""

reset() {
  cat >"$HERDR_MARK_TEST_STATE" <<'EOF'
{
  "focused": "w1:p2",
  "view_workspace": "w1",
  "view_tab": "w1:t1",
  "next": 10,
  "moves": 0,
  "swaps": 0,
  "splits": 0,
  "closes": 0,
  "zoomed_tabs": [],
  "trees": {
    "w1:t1": {"d": "right", "r": 0.5, "a": "w1:p1", "b": "w1:p2"},
    "w1:t2": "w1:p3",
    "w2:t1": "w2:p4"
  },
  "panes": [
    {"pane_id": "w1:p1", "tab_id": "w1:t1", "workspace_id": "w1", "tokens": {}, "title": null},
    {"pane_id": "w1:p2", "tab_id": "w1:t1", "workspace_id": "w1", "tokens": {}, "title": null},
    {"pane_id": "w1:p3", "tab_id": "w1:t2", "workspace_id": "w1", "tokens": {}, "title": null},
    {"pane_id": "w2:p4", "tab_id": "w2:t1", "workspace_id": "w2", "tokens": {}, "title": null}
  ]
}
EOF
  : >"$HERDR_MARK_TEST_LOG"
}

# mark <pane>: mark a pane directly in the fixture.
mark() {
  local next
  next=$(jq --arg id "$1" '(.panes[] | select(.pane_id == $id)) |= (.tokens.mark = "1" | .title = "◆ marked")' \
    "$HERDR_MARK_TEST_STATE")
  printf '%s\n' "$next" >"$HERDR_MARK_TEST_STATE"
}

zoom() {
  local next
  next=$(jq --arg t "$1" '.zoomed_tabs += [$t]' "$HERDR_MARK_TEST_STATE")
  printf '%s\n' "$next" >"$HERDR_MARK_TEST_STATE"
}

# on <pane> <args…>: run herdr-mark as a plugin action with <pane> focused.
# Sets $rc and $out; never aborts the test run.
on() {
  local pane=$1
  shift
  rc=0
  out=$(env -u HERDR_ACTIVE_PANE_ID HERDR_PANE_ID="$pane" HERDR_MARK_NOTIFY="${NOTIFY:-0}" \
    bash "$root/herdr-mark" "$@" 2>"$tmp/stderr") || rc=$?
}

field() {
  jq -r --arg id "$1" ".panes[] | select(.pane_id == \$id) | $2" "$HERDR_MARK_TEST_STATE"
}

marked_ids() {
  jq -r '[.panes[] | select(.tokens.mark == "1") | .pane_id] | join(" ")' "$HERDR_MARK_TEST_STATE"
}

tree() {
  jq -r --arg tab "$1" '
    def show: if type == "string" then .
      else (.d[0:1] + (.r | tostring) + "(" + (.a | show) + "," + (.b | show) + ")") end;
    .trees[$tab] | if . == null then "missing" else show end
  ' "$HERDR_MARK_TEST_STATE"
}

check() {
  local what=$1 got=$2 want=$3
  if [[ $got != "$want" ]]; then
    echo "  FAIL [$current] $what: got '$got', want '$want'" >&2
    failures=$((failures + 1))
  fi
}

called() { grep -Fxq -- "$1" "$HERDR_MARK_TEST_LOG" && echo yes || echo no; }
calls_matching() { grep -c -- "$1" "$HERDR_MARK_TEST_LOG" || true; }

t() {
  current=$1
  reset
}

t "toggle marks the focused pane"
on w1:p2 toggle
check rc "$rc" 0
check marked "$(marked_ids)" w1:p2
check title "$(field w1:p2 .title)" "◆ marked"
on w1:p2 get
check get "$out" w1:p2

t "toggle on the marked pane unmarks it"
mark w1:p2
on w1:p2 toggle
check marked "$(marked_ids)" ""
check title "$(field w1:p2 .title)" null
on w1:p2 get
check "get rc" "$rc" 1

t "toggle on another pane moves the mark"
mark w1:p1
on w1:p2 toggle
check marked "$(marked_ids)" w1:p2
check "old title" "$(field w1:p1 .title)" null

t "HERDR_ACTIVE_PANE_ID (shell binding) wins over HERDR_PANE_ID"
rc=0
HERDR_ACTIVE_PANE_ID=w1:p3 HERDR_PANE_ID=w1:p2 HERDR_MARK_NOTIFY=0 bash "$root/herdr-mark" toggle 2>/dev/null || rc=$?
check marked "$(marked_ids)" w1:p3

t "falls back to the focused pane without pane env"
rc=0
env -u HERDR_ACTIVE_PANE_ID -u HERDR_PANE_ID HERDR_MARK_NOTIFY=0 bash "$root/herdr-mark" toggle 2>/dev/null || rc=$?
check marked "$(marked_ids)" w1:p2

t "same-tab join parks the pane in a new tab, then splits"
mark w1:p1
on w1:p2 join right
check rc "$rc" 0
check park "$(called "pane move w1:p1 --new-tab --no-focus")" yes
check split "$(called "pane move w1:p1 --tab w1:t1 --target-pane w1:p2 --split right --focus")" yes
check swap "$(calls_matching "pane swap")" 0
check tab "$(field w1:p1 .tab_id)" w1:t1
check marked "$(marked_ids)" ""
check title "$(field w1:p1 .title)" null
check focus "$(jq -r .focused "$HERDR_MARK_TEST_STATE")" w1:p1

t "join down splits down"
mark w1:p1
on w1:p2 join down
check split "$(called "pane move w1:p1 --tab w1:t1 --target-pane w1:p2 --split down --focus")" yes
check swap "$(calls_matching "pane swap")" 0

t "join left = split right, then swap"
mark w1:p1
on w1:p2 join left
check split "$(called "pane move w1:p1 --tab w1:t1 --target-pane w1:p2 --split right --focus")" yes
check swap "$(called "pane swap --source-pane w1:p1 --target-pane w1:p2")" yes
check marked "$(marked_ids)" ""

t "join up = split down, then swap"
mark w1:p1
on w1:p2 join up
check split "$(called "pane move w1:p1 --tab w1:t1 --target-pane w1:p2 --split down --focus")" yes
check swap "$(called "pane swap --source-pane w1:p1 --target-pane w1:p2")" yes

t "same-tab join: if the second move fails, the pane goes back to its tab"
mark w1:p1
HERDR_MARK_TEST_FAIL_MOVES=2 on w1:p2 join right
check rc "$rc" 1
check recovery "$(called "pane move w1:p1 --tab w1:t1 --split right --no-focus")" yes
check tab "$(field w1:p1 .tab_id)" w1:t1
check "still marked" "$(marked_ids)" w1:p1
check message "$(grep -c "back in its tab" "$tmp/stderr")" 1

t "same-tab join: if recovery fails too, say which tab the pane is parked in"
mark w1:p1
HERDR_MARK_TEST_FAIL_MOVES="2 3" on w1:p2 join right
check rc "$rc" 1
parked=$(field w1:p1 .tab_id)
check "parked tab" "$([[ $parked != w1:t1 ]] && echo moved)" moved
check "still marked" "$(marked_ids)" w1:p1
check message "$(grep -c "in tab $parked" "$tmp/stderr")" 1

t "cross-tab join: a failed move is reported without a recovery move"
mark w1:p3
HERDR_MARK_TEST_FAIL_MOVES=1 on w1:p2 join right
check rc "$rc" 1
check moves "$(calls_matching "pane move")" 1
check "still marked" "$(marked_ids)" w1:p3

t "join left: a refused swap is reported and the mark is kept"
mark w1:p1
HERDR_MARK_TEST_FAIL_SWAP=1 on w1:p2 join left
check rc "$rc" 1
check tab "$(field w1:p1 .tab_id)" w1:t1
check "still marked" "$(marked_ids)" w1:p1
check message "$(grep -c "not left" "$tmp/stderr")" 1

t "swap: a refused swap keeps the mark"
mark w1:p1
HERDR_MARK_TEST_FAIL_SWAP=1 on w1:p2 swap
check rc "$rc" 1
check "still marked" "$(marked_ids)" w1:p1

t "cross-tab join moves once"
mark w1:p3
on w1:p2 join right
check rc "$rc" 0
check park "$(calls_matching "--new-tab")" 0
check tab "$(field w1:p3 .tab_id)" w1:t1
check marked "$(marked_ids)" ""

t "cross-workspace join clears the mark on the pane's new id"
mark w1:p1
on w2:p4 join down
check rc "$rc" 0
check "old id gone" "$(field w1:p1 .pane_id)" ""
new_id=$(jq -r '.panes[] | select(.tab_id == "w2:t1" and .pane_id != "w2:p4") | .pane_id' "$HERDR_MARK_TEST_STATE")
check "new id" "${new_id%%:*}" w2
check title "$(field "$new_id" .title)" null
check marked "$(marked_ids)" ""

t "swap within a tab"
mark w1:p1
on w1:p2 swap
check rc "$rc" 0
check swap "$(called "pane swap --source-pane w1:p1 --target-pane w1:p2")" yes
check marked "$(marked_ids)" ""

t "swap across tabs exchanges exact positions without a helper"
mark w1:p3
on w1:p2 swap
check rc "$rc" 0
check swap "$(calls_matching "pane swap")" 0
check moves "$(calls_matching "pane move")" 2
check helper "$(calls_matching "pane split")" 0
check tree "$(tree w1:t1)" 'r0.5(w1:p1,w1:p3)'
check tree "$(tree w1:t2)" w1:p2
check marked "$(marked_ids)" ""
check viewed_tab "$(jq -r .view_tab "$HERDR_MARK_TEST_STATE")" w1:t1

t "cross-workspace swap keeps both layouts and remaps both ids"
mark w1:p1
on w2:p4 swap
check rc "$rc" 0
moved_m=$(jq -r '.panes[] | select(.workspace_id == "w2") | .pane_id' "$HERDR_MARK_TEST_STATE")
moved_t=$(jq -r '.panes[] | select(.workspace_id == "w1" and .pane_id != "w1:p2" and .pane_id != "w1:p3") | .pane_id' "$HERDR_MARK_TEST_STATE")
check tree "$(tree w1:t1)" "r0.5($moved_t,w1:p2)"
check tree "$(tree w2:t1)" "$moved_m"
check swaps "$(calls_matching "pane swap")" 1
check helper "$(calls_matching "pane split")" 0
check marked "$(marked_ids)" ""
check peers "$(jq '[.panes[] | select(.tokens["swap-peer"] == "1")] | length' "$HERDR_MARK_TEST_STATE")" 0
check view "$(jq -r .view_workspace "$HERDR_MARK_TEST_STATE")" w1

t "cherry plan exchanges panes without disturbing a nested split"
next=$(jq '.trees["w1:t1"] = {d:"right",r:0.3,a:"w1:p1",b:{d:"down",r:0.7,a:"w1:p2",b:"w1:p3"}}
  | del(.trees["w1:t2"])
  | (.panes[] | select(.pane_id == "w1:p3") | .tab_id) = "w1:t1"' "$HERDR_MARK_TEST_STATE")
printf '%s\n' "$next" >"$HERDR_MARK_TEST_STATE"
mark w1:p1
on w2:p4 swap
check rc "$rc" 0
moved_m=$(jq -r '.panes[] | select(.workspace_id == "w2") | .pane_id' "$HERDR_MARK_TEST_STATE")
moved_t=$(jq -r '.panes[] | select(.workspace_id == "w1" and .pane_id != "w1:p2" and .pane_id != "w1:p3") | .pane_id' "$HERDR_MARK_TEST_STATE")
check tree "$(tree w1:t1)" "r0.3($moved_t,d0.7(w1:p2,w1:p3))"
check tree "$(tree w2:t1)" "$moved_m"
check swaps "$(calls_matching "pane swap")" 2
check helper "$(calls_matching "pane split")" 0

t "two lone panes use a temporary helper and keep both tabs"
mark w1:p3
on w2:p4 swap
check rc "$rc" 0
check helper "$(calls_matching "pane split")" 1
check close "$(calls_matching "pane close")" 1
check moves "$(calls_matching "pane move")" 2
check swaps "$(calls_matching "pane swap")" 0
check tabs "$(jq '.trees | length' "$HERDR_MARK_TEST_STATE")" 3
check helpers "$(jq '[.panes[] | select(.tokens.swap_helper == "1")] | length' "$HERDR_MARK_TEST_STATE")" 0
check marked "$(marked_ids)" ""

t "a refused second move restores the layout and keeps the mark"
mark w1:p1
HERDR_MARK_TEST_FAIL_MOVES=2 on w2:p4 swap
check rc "$rc" 1
recovered=$(marked_ids)
check tree "$(tree w1:t1)" "r0.5($recovered,w1:p2)"
check tree "$(tree w2:t1)" w2:p4
check "marked workspace" "${recovered%%:*}" w1

t "an unfinished peer token blocks another swap until clear"
mark w1:p1
next=$(jq '(.panes[] | select(.pane_id == "w2:p4") | .tokens["swap-peer"]) = "1"' "$HERDR_MARK_TEST_STATE")
printf '%s\n' "$next" >"$HERDR_MARK_TEST_STATE"
on w2:p4 swap
check rc "$rc" 1
check moves "$(calls_matching "pane move")" 0
on w2:p4 clear
check peers "$(jq '[.panes[] | select(.tokens["swap-peer"] == "1")] | length' "$HERDR_MARK_TEST_STATE")" 0
check marked "$(marked_ids)" ""
check peers "$(jq '[.panes[] | select(.tokens["swap-peer"] == "1")] | length' "$HERDR_MARK_TEST_STATE")" 0

t "a refused helper move restores the layout and closes the helper"
mark w1:p3
HERDR_MARK_TEST_FAIL_MOVES=2 on w2:p4 swap
check rc "$rc" 1
recovered=$(marked_ids)
check tree "$(tree w1:t2)" "$recovered"
check tree "$(tree w2:t1)" w2:p4
check helpers "$(jq '[.panes[] | select(.tokens.swap_helper == "1")] | length' "$HERDR_MARK_TEST_STATE")" 0
check "marked workspace" "${recovered%%:*}" w1

t "a refused helper split leaves both panes untouched"
mark w1:p3
HERDR_MARK_TEST_FAIL_SPLITS=1 on w2:p4 swap
check rc "$rc" 1
check moves "$(calls_matching "pane move")" 0
check tree "$(tree w1:t2)" w1:p3
check tree "$(tree w2:t1)" w2:p4
check marked "$(marked_ids)" w1:p3
check peers "$(jq '[.panes[] | select(.tokens["swap-peer"] == "1")] | length' "$HERDR_MARK_TEST_STATE")" 0

t "a failed helper close retains the mark and identifies the helper"
mark w1:p3
HERDR_MARK_TEST_FAIL_CLOSES="1 2" on w2:p4 swap
check rc "$rc" 1
check closes "$(calls_matching "pane close")" 2
check helpers "$(jq '[.panes[] | select(.tokens.swap_helper == "1")] | length' "$HERDR_MARK_TEST_STATE")" 1
check marked_count "$(jq '[.panes[] | select(.tokens.mark == "1")] | length' "$HERDR_MARK_TEST_STATE")" 1
check message "$(grep -c "temporary pane could not be closed" "$tmp/stderr")" 1

t "a refused cherry setup swap leaves its layout untouched"
next=$(jq '.trees["w1:t1"] = {d:"right",r:0.3,a:"w1:p1",b:{d:"down",r:0.7,a:"w1:p2",b:"w1:p3"}}
  | del(.trees["w1:t2"])
  | (.panes[] | select(.pane_id == "w1:p3") | .tab_id) = "w1:t1"' "$HERDR_MARK_TEST_STATE")
printf '%s\n' "$next" >"$HERDR_MARK_TEST_STATE"
mark w1:p1
HERDR_MARK_TEST_FAIL_SWAPS=1 on w2:p4 swap
check rc "$rc" 1
check tree "$(tree w1:t1)" 'r0.3(w1:p1,d0.7(w1:p2,w1:p3))'
check moves "$(calls_matching "pane move")" 0
check marked "$(marked_ids)" w1:p1

t "a refused final fixup keeps the mark and reports the displaced pane"
mark w1:p1
HERDR_MARK_TEST_FAIL_SWAPS="1 2" on w2:p4 swap
check rc "$rc" 1
check moves "$(calls_matching "pane move")" 2
check swaps "$(calls_matching "pane swap")" 2
check marked_count "$(jq '[.panes[] | select(.tokens.mark == "1")] | length' "$HERDR_MARK_TEST_STATE")" 1
check message "$(grep -c "positions need one more swap" "$tmp/stderr")" 1
check peers "$(jq '[.panes[] | select(.tokens["swap-peer"] == "1")] | length' "$HERDR_MARK_TEST_STATE")" 1
on w2:p4 clear
check peers_cleared "$(jq '[.panes[] | select(.tokens["swap-peer"] == "1")] | length' "$HERDR_MARK_TEST_STATE")" 0

t "a refused rollback leaves the moved pane marked for manual recovery"
mark w1:p1
HERDR_MARK_TEST_FAIL_MOVES="2 3" on w2:p4 swap
check rc "$rc" 1
check moves "$(calls_matching "pane move")" 3
recovered=$(marked_ids)
check marked_ws "${recovered%%:*}" w2
check marked_count "$(jq '[.panes[] | select(.tokens.mark == "1")] | length' "$HERDR_MARK_TEST_STATE")" 1
check message "$(grep -c "recovery failed" "$tmp/stderr")" 1
check "error names marked pane" "$(grep -Fc "$recovered is still marked" "$tmp/stderr")" 1

t "a refused helper rollback names the still-marked pane"
mark w1:p3
HERDR_MARK_TEST_FAIL_MOVES="2 3" on w2:p4 swap
check rc "$rc" 1
recovered=$(marked_ids)
check marked_ws "${recovered%%:*}" w2
check "error names marked pane" "$(grep -Fc "$recovered is marked" "$tmp/stderr")" 1
check helpers "$(jq '[.panes[] | select(.tokens.swap_helper == "1")] | length' "$HERDR_MARK_TEST_STATE")" 1

for case in "no mark" "marked is current" "current tab zoomed" "marked tab zoomed"; do
  t "join refuses: $case"
  case $case in
    "no mark") ;;
    "marked is current") mark w1:p2 ;;
    "current tab zoomed") mark w1:p3 && zoom w1:t1 ;;
    "marked tab zoomed") mark w1:p3 && zoom w1:t2 ;;
  esac
  on w1:p2 join right
  check rc "$rc" 1
  check moves "$(calls_matching "pane move")" 0
done

t "unknown join direction prints usage"
mark w1:p1
on w1:p2 join sideways
check rc "$rc" 2
check moves "$(calls_matching "pane move")" 0

t "unknown command prints usage"
on w1:p2 frobnicate
check rc "$rc" 2

t "title comes from the plugin config file; the environment wins"
mkdir -p "$tmp/config"
printf 'HERDR_MARK_TITLE="⚑ here"\n' >"$tmp/config/config"
HERDR_PLUGIN_CONFIG_DIR="$tmp/config" on w1:p2 toggle
check "config title" "$(field w1:p2 .title)" "⚑ here"
reset
HERDR_PLUGIN_CONFIG_DIR="$tmp/config" HERDR_MARK_TITLE="env title" on w1:p2 toggle
check "env title" "$(field w1:p2 .title)" "env title"

t "notifications are sent unless HERDR_MARK_NOTIFY=0"
NOTIFY=1 on w1:p2 toggle
check notified "$(calls_matching "notification show")" 1
reset
NOTIFY=0 on w1:p2 toggle
check silent "$(calls_matching "notification show")" 0

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all tests passed"
