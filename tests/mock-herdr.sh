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
  local id=$1 new_tab=0 tab="" focus=0 cur_tab ws new_id n
  shift
  require_pane "$id"
  while (($#)); do
    case $1 in
      --new-tab) new_tab=1 ;;
      --tab) tab=$2; shift ;;
      --target-pane | --split | --ratio) shift ;;
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
  new_id=$id
  if [[ $(ws_of "$tab") != "$ws" ]]; then
    new_id="$(ws_of "$tab"):p$n"
  fi
  update --arg id "$id" --arg new "$new_id" --arg tab "$tab" \
    '(.panes[] | select(.pane_id == $id)) |= (.pane_id = $new | .tab_id = $tab | .workspace_id = ($tab | split(":")[0]))'
  ((focus)) && update --arg id "$new_id" '.focused = $id'
  move_result "$new_id" "$id" true ""
}

swap() {
  local src="" dst="" reason="" changed=true
  while (($#)); do
    case $1 in
      --source-pane) src=$2; shift ;;
      --target-pane) dst=$2; shift ;;
    esac
    shift
  done
  if [[ ${HERDR_MARK_TEST_FAIL_SWAP:-0} == 1 ]]; then
    reason=injected changed=false
  elif [[ $(pane_json "$src" | jq -r .tab_id) != $(pane_json "$dst" | jq -r .tab_id) ]]; then
    reason=cross_tab changed=false
  else
    update --arg id "$src" '.focused = $id'
  fi
  jq -nc --argjson changed "$changed" --arg reason "$reason" \
    '{result: {swap: {changed: $changed, reason: (if $reason == "" then null else $reason end)}}}'
}

case "${1:-} ${2:-}" in
  "pane list") state | jq -c '{result: {panes: [.panes[] | if .tokens == {} then del(.tokens) else . end]}}' ;;
  "pane get") require_pane "$3" && jq -nc --argjson p "$(pane_json "$3")" '{result: {pane: $p}}' ;;
  "pane current") jq -nc --argjson p "$(pane_json "$(state | jq -r .focused)")" '{result: {pane: $p}}' ;;
  "pane layout")
    require_pane "$4"
    state | jq -c --arg tab "$(pane_json "$4" | jq -r .tab_id)" \
      '{result: {layout: {tab_id: $tab, zoomed: (.zoomed_tabs | index($tab) != null)}}}'
    ;;
  "pane report-metadata") shift 2 && report_metadata "$@" ;;
  "pane move") shift 2 && move "$@" ;;
  "pane swap") shift 2 && swap "$@" ;;
  "notification show") echo '{"result":{"type":"ok"}}' ;;
  *) echo "mock-herdr: unsupported: $*" >&2 && exit 2 ;;
esac
