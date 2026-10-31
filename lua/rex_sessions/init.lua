-- rex-sessions: a session picker for Rex, like sesh for tmux, with pinned
-- sessions and sessions on remote servers. See README.md.
--
-- require("rex_sessions").setup(opts) defines the actions below and binds
-- their keys. scripts/session-picker.py and scripts/session-list.lua call
-- the actions with `rex do`.

local util = require("rex_sessions.util")
local layout = require("rex_sessions.layout")
local client = require("rex_sessions.client")
local pins = require("rex_sessions.pins")
local remote = require("rex_sessions.remote")
local block_cwd = require("rex_sessions.terminal_dir").block_cwd

local check = util.check

local M = {}

-- This file, found on package.path as `require` found it: Rex doesn't
-- give loaded chunks their file name. (Lua 5.1 has no package.searchpath.)
local function module_file()
	for template in package.path:gmatch("[^;]+") do
		local file = template:gsub("%?", "rex_sessions")
		local handle = file:match("/init%.lua$") and io.open(file)
		if handle then
			handle:close()
			return file
		end
	end
end

-- This package's directory, relative to $HOME when under it. The
-- picker's shell runs on the session's server, whose $HOME may differ,
-- so a relative path finds the package there too.
local function default_root()
	local file = module_file()
	local root = file and file:match("^(.*)/lua/rex_sessions/init%.lua$")
	if not root then
		return ".config/rex/rex-sessions"
	end
	local home = util.HOME .. "/"
	return root:sub(1, #home) == home and root:sub(#home + 1) or root
end

M.defaults = {
	-- Where repos are looked for on each server: the first that exists.
	-- `~` and `$NAME` are expanded on that server.
	repos = { "$REPOS", "~/Documents/Repos" },
	-- A key, a list of keys, or false. `pin` is followed by 1-9.
	keys = {
		pick = "cmd+k",
		last = "cmd+l",
		pin = "cmd+alt+",
	},
	-- true: pressing a pin key again returns to the last session.
	pin_keys_toggle = false,
	-- Keys that toggle between a session and the last one, creating it in
	-- `cwd` if missing (expanded by the picker on the session's server):
	-- { { keys = "cmd+c", label = "dotfiles", cwd = "~/.config" } }
	toggles = {},
	-- The shell that starts the picker, interactively so its PATH (for
	-- fzf and python3) is loaded. Defaults to $SHELL on the server.
	shell = nil,
	-- This package's directory: absolute, or relative to $HOME.
	root = default_root(),
}

local options = M.defaults

local function list_sessions()
	return check(rex.call("session.list")).sessions or {}
end

local function find_session(label)
	for _, session in ipairs(list_sessions()) do
		if session.label == label then
			return session.session_id
		end
	end
end

local function session_label(session_id)
	for _, session in ipairs(list_sessions()) do
		if session.session_id == session_id then
			return session.label
		end
	end
end

-- The ID of the session after this one in the server's order, or nil.
local function session_after(session_id)
	local sessions = list_sessions()
	for i, session in ipairs(sessions) do
		if session.session_id == session_id then
			return sessions[i + 1] and sessions[i + 1].session_id
		end
	end
end

-- Where the session works: the directory of the first pane of its first
-- window, which is where `rex new --cwd` started it.
local function session_dir()
	local window = (check(rex.session.view({})).windows or {})[1]
	local layer = window and (window.layers or {})[1]
	local dir = layer and layer.layout and block_cwd(layout.any_block(layer.layout))
	return dir or error("no directory found for this session", 0)
end

local function ordered_pins()
	return pins.ordered(list_sessions())
end

-- Run on another server by session_pin: its Nth pin from list_pins,
-- with only what goto_pin needs, so the output stays short.
local REMOTE_PIN = [[
local listed = assert(rex.invoke("list_pins"))
local pin = (listed.pins or {})[%d]
if pin then
	return { label = pin.label, dir = pin.dir }
end
]]

-- The session's server's Nth pin, as in ordered_pins, or nil. Key
-- actions run on the app's own server, whose pins file isn't the one for
-- a session on another server, so ask that server's config.
local function session_pin(ctx, index)
	if not ctx.server then
		return ordered_pins()[index]
	end
	return remote.eval(ctx.server, ctx.session_id, REMOTE_PIN:format(index))
end

-- A session on any server: { server = host label, or nil for the app's
-- own, session_id = ... }. Key actions run on the app's own server, and
-- their API calls go to the session's server (ctx.server).
local function session_of(ctx)
	return { server = ctx.server, session_id = ctx.session_id }
end

local function same_session(a, b)
	return a.server == b.server and a.session_id == b.session_id
end

-- The session the last key action here ran in, and the one before it.
-- Config can't see every switch (e.g. the picker's, made on any server),
-- so each action notes where it runs: a change since the last one means
-- the app switched in between.
local current, previous

local function note_session(ctx)
	local here = session_of(ctx)
	if current and not same_session(current, here) then
		previous = current
	end
	current = here
end

local function select_session(ctx, target)
	client.select(ctx, target.server, { session_id = target.session_id })
	previous, current = session_of(ctx), target
	return target
end

local function switch_to_last_session(ctx)
	note_session(ctx)
	return select_session(ctx, previous or error("no last session", 0))
end

-- A command in a floating layer over the current window, like tmux's
-- display-popup. The layer closes when the command exits.
local function open_layer(ctx, command)
	local window = layout.current_window(check(rex.session.view({})), ctx.block_id)
	check(rex.session.new_layer({
		window_id = window and window.window_id,
		bounds = { 0.1, 0.1, 0.8, 0.8 },
		focus = true,
		layout = rex.layout.block({ flavor = util.SHELL, options = { shell = "none", command = command } }),
	}))
end

-- This config runs on the app's own server even for a remote session,
-- but the picker's shell runs on the session's server, whose $HOME may
-- differ. So let that shell resolve the picker's path and the shell.
-- $1 is the block the picker opened over, $2 the ID of the app that
-- opened it (see scripts/servers.lua), $3 the picker, $4 the shell.
local PICKER_SH = [[
export REX_PICKER_ORIGIN_BLOCK=$1 REX_PICKER_CLIENT_ID=$2
case $3 in /*) picker=$3 ;; *) picker=$HOME/$3 ;; esac
shell=${4:-${SHELL:-/bin/sh}}
shift 4
exec "$shell" -i -c 'exec python3 "$0" "$@"' "$picker" "$@"
]]

-- Runs session-picker.py with these arguments. The picker's layer
-- becomes the focused block, so pass the pane it opened over for
-- previewing the current session.
local function open_session_picker(ctx, ...)
	local picker = options.root .. "/scripts/session-picker.py"
	open_layer(ctx, {
		"/bin/sh",
		"-c",
		PICKER_SH,
		"sh",
		ctx.block_id or "",
		ctx.client_id or "",
		picker,
		options.shell or "",
		...,
	})
end

-- The first of options.repos that exists on this server.
local function repos_dir()
	for _, candidate in ipairs(options.repos) do
		local dir = util.expand(candidate)
		if dir ~= "" and check(rex.exec({ "/bin/test", "-d", dir })).ok then
			return dir
		end
	end
	error("no repos directory found", 0)
end

-- Switch to a session (on its most recent tab), creating it in `cwd` if
-- missing.
local function go_to_session(ctx, label, cwd)
	note_session(ctx)
	local session_id = find_session(label)
	if session_id then
		return select_session(ctx, { server = ctx.server, session_id = session_id })
	end
	-- Creating needs `rex new`, so let the picker script do it.
	open_session_picker(ctx, "open", "", label, cwd)
end

-- Toggle between a session and the last session.
local function toggle_session(ctx, label, cwd)
	if session_label(ctx.session_id) == label then
		return switch_to_last_session(ctx)
	end
	return go_to_session(ctx, label, cwd)
end

local function define_actions()
	-- Run on the server being browsed (`rex -S host do list_repos`), so the
	-- picker can list repos on a remote server too.
	rex.action({
		name = "list_repos",
		title = "List repos on this server",
		category = "Sessions",
		run = function()
			local dir = repos_dir()
			local found = check(rex.exec({ "/usr/bin/find", dir, "-mindepth", "1", "-maxdepth", "1", "-type", "d" }))
			local repos = {}
			for path in found.stdout:gmatch("[^\n]+") do
				table.insert(repos, path:match("[^/]+$"))
			end
			table.sort(repos)
			return { dir = dir, repos = repos }
		end,
	})

	-- Run by the picker as `rex [-S host] -C APP do switch_session` on the
	-- session's server, after it creates any new session with `rex new` (a
	-- script can't add windows to a session it isn't attached to). That
	-- may not be the app's own server, so key actions note the switch
	-- instead (see note_session). Switching the app from the CLI needs
	-- Remote Control turned on in the app's settings.
	rex.action({
		name = "switch_session",
		title = "Switch to session by name",
		description = "Switch the app to the session labelled `label`.",
		category = "Sessions",
		args = { label = "string" },
		run = function(ctx, args)
			local session_id = find_session(args.label) or error("no session named " .. args.label, 0)
			client.select(ctx, nil, { session_id = session_id })
			return { session_id = session_id }
		end,
	})

	-- Run by session-list.lua on the server being browsed.
	rex.action({
		name = "list_pins",
		title = "List pinned sessions on this server",
		category = "Sessions",
		run = function()
			return { pins = ordered_pins() }
		end,
	})

	-- Run by the picker as `rex do [-s SESSION] toggle_pin`. Without a
	-- `dir`, the pin takes the session's.
	rex.action({
		name = "toggle_pin",
		title = "Pin or unpin a session",
		category = "Sessions",
		args = { label = "string", dir = "string?" },
		run = function(_, args)
			local pinned = pins.read()
			local i = pins.index(pinned, args.label)
			if i then
				table.remove(pinned, i)
			else
				local dir = args.dir ~= "" and args.dir or session_dir()
				table.insert(pinned, { label = args.label, dir = dir })
			end
			pins.write(pinned)
			return { pinned = i == nil }
		end,
	})

	-- Run by the picker (alt-u/alt-d) as `rex do [-s SESSION] move_pin`,
	-- with `by` -1 or 1. Swaps the pin with its neighbour in ordered_pins.
	-- An open pin moves in the sidebar: just before its neighbour, or
	-- before the session after it (or to the end) going down.
	-- session.move only moves a session the call is attached to, which
	-- `-s` makes the pin's, so it's always the pin's own session that
	-- moves. Open pins come first, so an open and a closed pin can't swap.
	-- Fails if the pin can't move, so the picker leaves its cursor where
	-- it is and shows why.
	rex.action({
		name = "move_pin",
		title = "Move a pinned session up or down",
		category = "Sessions",
		args = { label = "string", by = "integer" },
		run = function(_, args)
			local ordered = ordered_pins()
			local from = pins.index(ordered, args.label) or error(args.label .. " is not pinned", 0)
			local to = from + args.by
			local pin, neighbour = ordered[from], ordered[to]
			if not neighbour or (pin.session_id == nil) ~= (neighbour.session_id == nil) then
				error("can't move " .. args.label .. " any further", 0)
			end
			if pin.session_id then
				local before = args.by < 0 and neighbour.session_id or session_after(neighbour.session_id)
				check(rex.call("session.move", { session_id = pin.session_id, before_session_id = before }))
			end
			ordered[from], ordered[to] = ordered[to], ordered[from]
			pins.write(ordered)
		end,
	})

	-- Run by the picker as `rex do -s SESSION kill_session`, so the action
	-- applies to the session it closes. Pinned sessions are kept.
	rex.action({
		name = "kill_session",
		title = "Close this session",
		category = "Sessions",
		run = function(ctx)
			local label = session_label(ctx.session_id)
			if label and pins.index(pins.read(), label) then
				error(label .. " is pinned. Unpin it (alt-p) to close it.", 0)
			end
			check(rex.call("session.destroy", { session_id = ctx.session_id }))
		end,
	})

	rex.action({
		name = "last_session",
		title = "Switch to last session",
		category = "Sessions",
		run = switch_to_last_session,
	})

	rex.action({
		name = "toggle_session",
		title = "Toggle session by name",
		category = "Sessions",
		args = { label = "string", cwd = "string" },
		run = function(ctx, args)
			return toggle_session(ctx, args.label, args.cwd)
		end,
	})

	-- Go to the Nth pin, in the order the picker shows them. Already there,
	-- it stays put, or with `toggle` returns to the last session. Pins and
	-- their sessions are the current session's server's, so in a session
	-- on another server the keys follow that server's pins.
	rex.action({
		name = "goto_pin",
		title = "Go to pinned session by number",
		category = "Sessions",
		args = { index = "integer", toggle = "boolean?" },
		run = function(ctx, args)
			local pin = session_pin(ctx, args.index) or error("no pin " .. args.index, 0)
			if args.toggle then
				return toggle_session(ctx, pin.label, pin.dir or "")
			end
			if session_label(ctx.session_id) ~= pin.label then
				return go_to_session(ctx, pin.label, pin.dir or "")
			end
		end,
	})

	rex.action({
		name = "pick_repo_session",
		title = "Pick repo session",
		description = "Fuzzy-find a session or repo, locally or on a remote server, and switch to it.",
		category = "Sessions",
		run = function(ctx)
			note_session(ctx)
			open_session_picker(ctx)
		end,
	})
end

local function bind(keys, action, args)
	for _, key in ipairs(util.keys(keys)) do
		rex.bind(key, action, args)
	end
end

local function bind_keys()
	local keys = options.keys
	bind(keys.pick, "pick_repo_session")
	bind(keys.last, "last_session")
	if keys.pin then
		for i = 1, 9 do
			rex.bind(keys.pin .. i, "goto_pin", { index = i, toggle = options.pin_keys_toggle })
		end
	end
	for _, toggle in ipairs(options.toggles) do
		bind(toggle.keys, "toggle_session", { label = toggle.label, cwd = toggle.cwd })
	end
end

local function merge(defaults, overrides)
	local merged = {}
	for key, value in pairs(defaults) do
		merged[key] = value
	end
	for key, value in pairs(overrides or {}) do
		merged[key] = value
	end
	return merged
end

-- Defines the actions and binds their keys. Call once, from the config
-- file as it loads.
function M.setup(opts)
	opts = opts or {}
	options = merge(M.defaults, opts)
	options.keys = merge(M.defaults.keys, opts.keys)
	define_actions()
	bind_keys()
end

return M
