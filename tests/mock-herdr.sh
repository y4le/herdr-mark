#!/usr/bin/env bash
#
# Stand-in for the herdr CLI, just enough of `pane` and `notification` for
# herdr-mark. It keeps panes (id, tab, workspace, metadata) in a JSON state
# file, applies herdr's move/swap rules, and logs every call.
#
#   HERDR_MARK_TEST_STATE  JSON state file (see tests/test.sh for the shape)
#   HERDR_MARK_TEST_LOG    file that receives one line per call
#
# Fault injection:
#   HERDR_MARK_TEST_FAIL_MOVES  space-separated ordinals of `pane move` calls
#                               that herdr refuses (changed=false), e.g. "2 3"
#   HERDR_MARK_TEST_FAIL_SWAP   1 = every `pane swap` is refused

# shellcheck disable=SC2016 # single-quoted strings are jq programs with $vars
set -euo pipefail

: "${HERDR_MARK_TEST_STATE:?}"
: "${HERDR_MARK_TEST_LOG:?}"
printf '%s\n' "$*" >>"$HERDR_MARK_TEST_LOG"

state() { cat "$HERDR_MARK_TEST_STATE"; }

update() {
  local next
  next=$(jq "$@" "$HERDR_MARK_TEST_STATE")
  printf '%s\n' "$next" >"$HERDR_MARK_TEST_STATE"
}

pane_json() {
  state | jq -c --arg id "$1" '.panes[] | select(.pane_id == $id)
    | if .tokens == {} then del(.tokens) else . end'
}

require_pane() {
  [[ -n $(pane_json "$1") ]] || {
    printf '{"error":{"code":"pane_not_found","message":"pane %s not found"}}\n' "$1"
    exit 1
  }
}

ws_of() { printf '%s\n' "${1%%:*}"; }

# Keep a BSP tree per tab so tests can check that a sequence restores the
# original split shape, direction, and ratio, not merely pane membership.
tree_ops='
  def first_leaf: if type == "string" then . else .a | first_leaf end;
  def drop_leaf($id):
    if type == "string" then if . == $id then null else . end
    else (.a | drop_leaf($id)) as $a | (.b | drop_leaf($id)) as $b
      | if $a == null then $b elif $b == null then $a else .a = $a | .b = $b end
    end;
  def insert_leaf($target; $new; $dir; $ratio):
    if type == "string" then
      if . == $target then {d: $dir, r: $ratio, a: ., b: $new} else . end
    else .a |= insert_leaf($target; $new; $dir; $ratio)
      | .b |= insert_leaf($target; $new; $dir; $ratio)
    end;
  def swap_leaves($a; $b):
    if type == "string" then
      if . == $a then $b elif . == $b then $a else . end
    else .a |= swap_leaves($a; $b) | .b |= swap_leaves($a; $b) end;
  def render($rect; $path):
    if type == "string" then {panes: [{pane_id: ., rect: $rect}], splits: []}
    else . as $n
      | (if $n.d == "right" then ($rect.width * $n.r | floor)
         else ($rect.height * $n.r | floor) end) as $first
      | (if $n.d == "right"
         then {x: $rect.x, y: $rect.y, width: $first, height: $rect.height}
         else {x: $rect.x, y: $rect.y, width: $rect.width, height: $first}
         end) as $ra
      | (if $n.d == "right"
         then {x: ($rect.x + $first), y: $rect.y,
               width: ($rect.width - $first), height: $rect.height}
         else {x: $rect.x, y: ($rect.y + $first),
               width: $rect.width, height: ($rect.height - $first)}
         end) as $rb
      | ($n.a | render($ra; ($path + "0"))) as $a
      | ($n.b | render($rb; ($path + "1"))) as $b
      | {panes: ($a.panes + $b.panes),
         splits: ([{id: ("split_" + $path), direction: $n.d,
                    ratio: $n.r, rect: $rect}] + $a.splits + $b.splits)}
    end;
'

report_metadata() {
  local id=$1
  shift
  require_pane "$id"
  while (($#)); do
    case $1 in
      --source) shift ;;
      --title) update --arg id "$id" --arg v "$2" '(.panes[] | select(.pane_id == $id) | .title) = $v'; shift ;;
      --clear-title) update --arg id "$id" '(.panes[] | select(.pane_id == $id) | .title) = null' ;;
      --token)
        update --arg id "$id" --arg k "${2%%=*}" --arg v "${2#*=}" \
          '(.panes[] | select(.pane_id == $id) | .tokens[$k]) = $v'
        shift
        ;;
      --clear-token)
        update --arg id "$id" --arg k "$2" '(.panes[] | select(.pane_id == $id) | .tokens) |= del(.[$k])'
        shift
        ;;
    esac
    shift
  done
  echo '{"result":{"type":"ok"}}'
}

move_result() {
  jq -nc --argjson pane "$(pane_json "$1")" --arg prev "$2" --argjson changed "$3" --arg reason "$4" \
    '{result: {move_result: {pane: $pane, previous_pane_id: $prev, changed: $changed,
      reason: (if $reason == "" then null else $reason end)}}}'
}

move() {
  local id=$1 new_tab=0 tab="" focus=0 cur_tab ws new_id n target="" split=right ratio=0.5
  shift
  require_pane "$id"
  while (($#)); do
    case $1 in
      --new-tab) new_tab=1 ;;
      --tab) tab=$2; shift ;;
      --target-pane) target=$2; shift ;;
      --split) split=$2; shift ;;
      --ratio) ratio=$2; shift ;;
      --focus) focus=1 ;;
    esac
    shift
  done
  update '.moves += 1'
  if [[ " ${HERDR_MARK_TEST_FAIL_MOVES:-} " == *" $(state | jq .moves) "* ]]; then
    move_result "$id" "$id" false injected
    return
  fi
  cur_tab=$(pane_json "$id" | jq -r .tab_id)
  n=$(state | jq .next)
  update '.next += 1'
  ws=$(ws_of "$id")
  if ((new_tab)); then
    tab="$ws:t$n"
  elif [[ $tab == "$cur_tab" ]]; then
    move_result "$id" "$id" false same_tab
    return
  fi
  if ((!new_tab)) && [[ -z ${tab:-} || $(state | jq -r --arg tab "$tab" '.trees[$tab] // empty') == "" ]]; then
    move_result "$id" "$id" false not_found
    return
  fi
  new_id=$id
  if [[ $(ws_of "$tab") != "$ws" ]]; then
    new_id="$(ws_of "$tab"):p$n"
  fi
  if ((!new_tab)) && [[ -z $target ]]; then
    target=$(state | jq -r --arg tab "$tab" "$tree_ops .trees[\$tab] | first_leaf")
  fi
  update --arg id "$id" --arg new "$new_id" --arg tab "$tab" --arg cur "$cur_tab" \
    --arg target "$target" --arg dir "$split" --argjson ratio "$ratio" --argjson new_tab "$new_tab" \
    "$tree_ops
      (.trees[\$cur] | drop_leaf(\$id)) as \$remaining
      | if \$remaining == null then del(.trees[\$cur]) else .trees[\$cur] = \$remaining end
      | if \$new_tab == 1 then .trees[\$tab] = \$new
        else .trees[\$tab] |= insert_leaf(\$target; \$new; \$dir; \$ratio) end
      | (.panes[] | select(.pane_id == \$id)) |=
          (.pane_id = \$new | .tab_id = \$tab | .workspace_id = (\$tab | split(\":\")[0]))"
  if ((focus)); then
    update --arg id "$new_id" --arg ws "$(ws_of "$tab")" --arg tab "$tab" \
      '.focused = $id | .view_workspace = $ws | .view_tab = $tab'
  fi
  move_result "$new_id" "$id" true ""
}

swap() {
  local src="" dst="" reason="" changed=true tab
  while (($#)); do
    case $1 in
      --source-pane) src=$2; shift ;;
      --target-pane) dst=$2; shift ;;
    esac
    shift
  done
  update '.swaps += 1'
  if [[ ${HERDR_MARK_TEST_FAIL_SWAP:-0} == 1 ||
        " ${HERDR_MARK_TEST_FAIL_SWAPS:-} " == *" $(state | jq .swaps) "* ]]; then
    reason=injected changed=false
  elif [[ $(pane_json "$src" | jq -r .tab_id) != $(pane_json "$dst" | jq -r .tab_id) ]]; then
    reason=cross_tab changed=false
  else
    tab=$(pane_json "$src" | jq -r .tab_id)
    update --arg src "$src" --arg dst "$dst" --arg tab "$tab" \
      "$tree_ops .trees[\$tab] |= swap_leaves(\$src; \$dst) | .focused = \$src"
  fi
  jq -nc --argjson changed "$changed" --arg reason "$reason" \
    '{result: {swap: {changed: $changed, reason: (if $reason == "" then null else $reason end)}}}'
}

split_pane() {
  local id="" dir=right ratio=0.5 focus=0 tab ws n new
  while (($#)); do
    case $1 in
      --direction) dir=$2; shift ;;
      --ratio) ratio=$2; shift ;;
      --focus) focus=1 ;;
      --no-focus) ;;
      --cwd | --env) shift ;;
      *) id=$1 ;;
    esac
    shift
  done
  require_pane "$id"
  update '.splits += 1'
  if [[ " ${HERDR_MARK_TEST_FAIL_SPLITS:-} " == *" $(state | jq .splits) "* ]]; then
    echo '{"error":{"code":"injected","message":"split refused"}}'
    return 1
  fi
  tab=$(pane_json "$id" | jq -r .tab_id)
  ws=$(ws_of "$id")
  n=$(state | jq .next)
  new="$ws:p$n"
  update --arg id "$id" --arg new "$new" --arg tab "$tab" --arg ws "$ws" \
    --arg dir "$dir" --argjson ratio "$ratio" \
    "$tree_ops .next += 1
      | .trees[\$tab] |= insert_leaf(\$id; \$new; \$dir; \$ratio)
      | .panes += [{pane_id: \$new, tab_id: \$tab, workspace_id: \$ws,
                    tokens: {}, title: null}]"
  ((focus)) && update --arg id "$new" --arg ws "$ws" --arg tab "$tab" \
    '.focused = $id | .view_workspace = $ws | .view_tab = $tab'
  jq -nc --argjson p "$(pane_json "$new")" '{result: {pane: $p}}'
}

close_pane() {
  local id=$1 tab
  require_pane "$id"
  update '.closes += 1'
  if [[ " ${HERDR_MARK_TEST_FAIL_CLOSES:-} " == *" $(state | jq .closes) "* ]]; then
    echo '{"error":{"code":"injected","message":"close refused"}}'
    return 1
  fi
  tab=$(pane_json "$id" | jq -r .tab_id)
  update --arg id "$id" --arg tab "$tab" \
    "$tree_ops
      (.trees[\$tab] | drop_leaf(\$id)) as \$remaining
      | if \$remaining == null then del(.trees[\$tab]) else .trees[\$tab] = \$remaining end
      | .panes |= map(select(.pane_id != \$id))
      | if .focused == \$id then
          .focused = (if \$remaining == null then null else (\$remaining | first_leaf) end)
        else . end"
  echo '{"result":{"type":"pane_close"}}'
}

case "${1:-} ${2:-}" in
  "pane list") state | jq -c '{result: {panes: [.panes[] | if .tokens == {} then del(.tokens) else . end]}}' ;;
  "pane get") require_pane "$3" && jq -nc --argjson p "$(pane_json "$3")" '{result: {pane: $p}}' ;;
  "pane current") jq -nc --argjson p "$(pane_json "$(state | jq -r .focused)")" '{result: {pane: $p}}' ;;
  "pane layout")
    require_pane "$4"
    state | jq -c --arg tab "$(pane_json "$4" | jq -r .tab_id)" \
      "$tree_ops
        (.trees[\$tab] | render({x: 0, y: 0, width: 200, height: 60}; \"root\")) as \$layout
        | {result: {layout: ({tab_id: \$tab,
                              zoomed: (.zoomed_tabs | index(\$tab) != null)} + \$layout)}}"
    ;;
  "pane report-metadata") shift 2 && report_metadata "$@" ;;
  "pane move") shift 2 && move "$@" ;;
  "pane swap") shift 2 && swap "$@" ;;
  "pane split") shift 2 && split_pane "$@" ;;
  "pane close") close_pane "$3" ;;
  "api snapshot") state | jq -c '{result: {snapshot: {focused_workspace_id: .view_workspace, focused_tab_id: .view_tab}}}' ;;
  "workspace focus") update --arg ws "$3" '.view_workspace = $ws' && echo '{"result":{"type":"ok"}}' ;;
  "tab focus") update --arg tab "$3" '.view_tab = $tab | .view_workspace = ($tab | split(":")[0])' && echo '{"result":{"type":"ok"}}' ;;
  "notification show") echo '{"result":{"type":"ok"}}' ;;
  *) echo "mock-herdr: unsupported: $*" >&2 && exit 2 ;;
esac
