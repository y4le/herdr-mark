# herdr-mark

A tmux-style **marked pane** for [herdr](https://herdr.dev). Mark a pane, focus
another pane, anywhere in the session, and then either **join** the marked pane
next to it or **swap** the two. It works like tmux's `select-pane -m` combined with
`join-pane` and `swap-pane`.

It's also the easiest way to rearrange a split. For example, to turn two stacked
panes into side-by-side panes, mark the top pane, focus the bottom one, and join
left.

## Usage

With the suggested bindings (see [Install](#install); you can change any of them):

| Keys | Action |
|---|---|
| `prefix+m` | Mark the focused pane. Press it again on that pane to unmark it; press it on another pane to move the mark there. |
| `prefix+ctrl+l` / `prefix+ctrl+j` | Join the marked pane **right of** / **below** the focused pane |
| `prefix+ctrl+h` / `prefix+ctrl+k` | Join the marked pane **left of** / **above** the focused pane |
| `prefix+ctrl+s` | Swap the marked pane with the focused pane |

The marked pane shows **`◆ marked`** as its border title. Each action also shows
a herdr notification. That matters when the marked pane is the only pane in its
tab, because herdr draws no border around a lone pane (`pane_borders = "auto"`).

After a join or swap, focus goes to the pane you marked and the mark is cleared.
Joins work across tabs and workspaces. Moving a pane into another workspace gives
it a new pane id. Swaps only work within one tab, because herdr refuses to swap
across tabs; use a join instead.

## Install

Requires herdr **≥ 0.9.1** and `jq`. Tested on Linux.

```bash
herdr plugin install y4le/herdr-mark
herdr plugin action list --plugin herdr-mark
```

Then bind the actions in `~/.config/herdr/config.toml` and reload the config
(`prefix+shift+r`). The plugin doesn't set any keys itself; these are suggestions,
and any key that herdr accepts will work:

```toml
[[keys.command]]
key = "prefix+m"
type = "plugin_action"
command = "herdr-mark.toggle"
description = "mark/unmark pane"

[[keys.command]]
key = "prefix+ctrl+l"
type = "plugin_action"
command = "herdr-mark.join-right"
description = "join marked pane right of this one"

[[keys.command]]
key = "prefix+ctrl+j"
type = "plugin_action"
command = "herdr-mark.join-down"
description = "join marked pane below this one"

[[keys.command]]
key = "prefix+ctrl+h"
type = "plugin_action"
command = "herdr-mark.join-left"
description = "join marked pane left of this one"

[[keys.command]]
key = "prefix+ctrl+k"
type = "plugin_action"
command = "herdr-mark.join-up"
description = "join marked pane above this one"

[[keys.command]]
key = "prefix+ctrl+s"
type = "plugin_action"
command = "herdr-mark.swap"
description = "swap marked pane with this one"
```

herdr 0.9.1 has no default bindings for these keys. Avoid `prefix+shift+h/j/k/l`:
herdr uses them for its built-in "swap with the neighbouring pane" actions, and a
user binding on the same key silently replaces the built-in one. The `ctrl`
chords depend on herdr's kitty keyboard protocol support. If your terminal
doesn't support that protocol, `ctrl+h` and `ctrl+j` may arrive as backspace and
enter, so pick other keys. The plugin also provides `herdr-mark.clear`, which
unmarks whatever pane is marked.

## Configuration

Put `KEY=VALUE` lines in `$(herdr plugin config-dir herdr-mark)/config`. Environment
variables with the same names override the file.

| Key | Default | Meaning |
|---|---|---|
| `HERDR_MARK_TITLE` | `◆ marked` | Border title for the marked pane |
| `HERDR_MARK_NOTIFY` | `1` | Set to `0` to turn off the per-action notifications |

## How it works

`herdr-mark` is a Bash script that drives herdr's CLI (`pane list`, `pane move`,
`pane swap`, `pane report-metadata`). Some behavior comes from limits in herdr:

- **The mark is stored on the pane.** `pane report-metadata --source user.herdr-mark`
  sets a `mark` token, which lets the script find the pane again with `pane list`, and
  a border title, which is what you see. Because the mark is metadata, it moves with
  the pane and disappears when the pane closes. There's no state file.
- **The mark is a border title, not a border colour.** herdr colours only the
  focused pane's border (in the theme accent). Other panes all use one colour, and
  no API changes that. A metadata title takes priority over the pane's name and
  agent label, so while a pane is marked, `◆ marked` replaces them. The previous
  label comes back when the mark is cleared.
- **Joins within one tab take two moves.** herdr ignores a `pane move` whose target
  is in the same tab (`reason: same_tab`). The script first moves the marked pane
  into a temporary tab, then moves it back next to the target. The temporary tab
  closes once it's empty, and the pane keeps its id.
- **Left and up are a join plus a swap.** herdr can only split right of or below a
  target, so the script does that split and then swaps the two panes.
- **Failures leave the mark in place and say what happened.** The cases herdr
  would ignore are refused before anything moves: no pane is marked, the marked
  pane is the focused one, or either tab is zoomed. If the second move of a
  same-tab join still fails, the script moves the pane from the temporary tab back
  into its own tab (its exact position there is lost). If that fails too, it
  reports which tab the pane is in. If the swap in a left/up join is refused, it
  reports the side the pane actually ended up on.

The script also runs outside a keybinding. `herdr-mark toggle | join <dir> | swap
| clear | get` acts on `$HERDR_PANE_ID`, which is the pane your shell is in. It
also accepts `$HERDR_ACTIVE_PANE_ID` from a `type = "shell"` binding.

## Development

```bash
herdr plugin link .   # use this checkout instead of an installed copy
make check            # shellcheck, manifest, offline tests against a mock herdr
make live             # live tests against the running herdr server
```

`make live` builds layouts in unfocused scratch workspaces, checks the geometry
after every join and swap, and closes the scratch workspaces afterwards. It doesn't
change your focus or your other workspaces.

## License

MIT
