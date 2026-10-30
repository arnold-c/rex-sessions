# rex-sessions

A session picker for [Rex](https://www.superlogical.com/rex), like
[sesh](https://github.com/joshmedeski/sesh) for tmux:

- fuzzy-find a session, or a repo to start one in, with a live preview
- pin sessions, reorder the pins, and jump to them with `cmd+alt+1`–`9`
- browse and switch to sessions on your other Rex servers (`alt-r`)
- toggle back to the last session

## Requirements

- Rex, with **Remote Control** turned on in the app's settings so the
  picker can switch the app's session
- `python3` (3.9+) and `fzf` on each server
- optional: `zoxide` (`alt-z` lists any directory it knows) and `sesh`
  (directory previews)

## Install

Clone this repo, then link it to `~/.local/share/rex-sessions`:

```sh
git clone https://github.com/arnold-c/rex-sessions ~/src/rex-sessions
ln -s ~/src/rex-sessions ~/.local/share/rex-sessions
```

Then, in `~/.config/rex/init.lua`:

```lua
local root = os.getenv("HOME") .. "/.local/share/rex-sessions/lua/"
package.path = root .. "?.lua;" .. root .. "?/init.lua;" .. package.path

require("rex_sessions").setup()
```

With one machine, the link is optional: point `root` at the clone. With
several, it lets the clone live anywhere on each one (see
[Remote servers](#remote-servers)).

### Multiple machines

Give the package **the same path relative to `$HOME` on every machine**,
e.g. `~/.local/share/rex-sessions`, as a symlink to wherever that
machine keeps the clone:

```sh
# laptop
ln -s ~/Documents/Repos/rex-sessions ~/.local/share/rex-sessions
# server, with repos on another disk
ln -s /Volumes/Data/Repos/rex-sessions ~/.local/share/rex-sessions
```

Then the same `init.lua` works on both. Point it at the link, not at
`$REPOS` or the clone: the Rex server may not have your shell's
environment, and a picker opened in a session on another machine looks
for the package at this machine's path, relative to `$HOME`.

With Nix and home-manager, choose each machine's clone by host name:

```nix
{ config, osConfig, ... }:

let
  home = config.home.homeDirectory;
  repos =
    if osConfig.networking.hostName == "server" then
      "/Volumes/Data/Repos"
    else
      "${home}/Documents/Repos";
in
{
  xdg.dataFile."rex-sessions".source =
    config.lib.file.mkOutOfStoreSymlink "${repos}/rex-sessions";
}
```

## Options

Defaults shown:

```lua
require("rex_sessions").setup({
	-- Where repos are looked for on each server: the first that exists.
	-- `~` and `$NAME` are expanded on that server.
	repos = { "$REPOS", "~/Documents/Repos" },
	-- A key, a list of keys, or false. `pin` is followed by 1-9.
	keys = { pick = "cmd+k", last = "cmd+l", pin = "cmd+alt+" },
	-- true: pressing a pin key again returns to the last session.
	pin_keys_toggle = false,
	-- Keys that toggle between a session and the last one, creating it in
	-- `cwd` if missing.
	toggles = {
		-- { keys = "cmd+c", label = "dotfiles", cwd = "~/.config" },
	},
	-- The shell that starts the picker, interactively so fzf and python3
	-- are on its PATH. Defaults to $SHELL.
	shell = nil,
	-- This package's directory, absolute or relative to $HOME. Found from
	-- the module's path by default.
	root = nil,
})
```

## Picker keys

| Key | Does |
| --- | --- |
| `enter` | switch to the session, creating it in the repo if needed |
| `alt-s` | this machine's server |
| `alt-r` | cycle through the remote servers that answer |
| `alt-z` | directories from zoxide |
| `alt-p` | pin or unpin |
| `alt-u` / `alt-d` | move a pin up or down |
| `alt-x` | close the session (pinned sessions are kept) |

## Remote servers

The picker lists the servers from your Rex hosts (`rex hosts`).

- To browse a server with `alt-r`, set this package up in that server's
  config too, with `repos` pointing at that machine's repos. The picker
  asks each server's own config for its repos, pins, and sessions.
- To open the picker while you're in a session on another server,
  install it there at the same path relative to `$HOME` (see
  [Multiple machines](#multiple-machines)), with `python3` and `fzf`.
  Keys run on your own machine's server, which passes its path for the
  picker, but the picker starts on the session's server.
- To use the pin keys while you're in a session on another server, set
  this package up in that server's config too. The keys go to that
  server's pins, which a hidden terminal there reads with
  `rex do list_pins`.

Pins are stored on the server whose sessions they are
(`$XDG_STATE_HOME/rex/pins`), so every picker shows the same ones, and
the pin keys follow the pins of the session you're in.

## Actions

`setup()` defines these actions, which you can also bind yourself:
`pick_repo_session`, `last_session`, `toggle_session` (`label`, `cwd`),
`goto_pin` (`index`, `toggle`), and the ones the picker uses:
`list_repos`, `list_pins`, `switch_session`, `toggle_pin`, `move_pin`,
`kill_session`.
