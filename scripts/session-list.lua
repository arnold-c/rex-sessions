-- Rows for session-picker.py: pinned entries, then sessions, then repos
-- without a session. API calls and the list_repos and list_pins actions
-- (see lua/rex_sessions/init.lua) run on the targeted server.
-- Usage: rex [-S host] do scripts/session-list.lua --args '{"server":""}'
-- Prints one tab-separated row per entry: server, kind (session|dir),
-- label, dir (to create the session in), session id, display text.

local args = rex.args or {}
local server = args.server or ""

local function fail(err)
	rex.log("error", err)
	rex.stop(1)
end

local listed, list_err = rex.call("session.list")
if not listed then
	fail(list_err)
end

local repos, repos_err = rex.invoke("list_repos")
if not repos then
	fail(repos_err)
end

local listed_pins, pins_err = rex.invoke("list_pins")
if not listed_pins then
	fail(pins_err)
end

local session_ids = {}
for _, session in ipairs(listed.sessions or {}) do
	session_ids[session.label] = session.session_id
end

local repo_dirs = {}
for _, name in ipairs(repos.repos or {}) do
	repo_dirs[name] = repos.dir .. "/" .. name
end

local function row(kind, label, dir, icon)
	local id = session_ids[label] or ""
	io.write(table.concat({ server, kind, label, dir or "", id, icon .. " " .. label }, "\t"), "\n")
end

-- Numbered, as the pin keys go to the Nth pin, in list_pins' order (the
-- sidebar's, then closed pins; see pins.ordered). Every pin gets a row
-- so the numbers match, even one with neither a session nor a dir,
-- which can then be unpinned or moved.
local pinned = {}
for i, pin in ipairs(listed_pins.pins or {}) do
	pinned[pin.label] = true
	local kind = session_ids[pin.label] and "session" or "dir"
	row(kind, pin.label, pin.dir or repo_dirs[pin.label], "📌" .. i)
end

for _, session in ipairs(listed.sessions or {}) do
	if not pinned[session.label] then
		row("session", session.label, nil, "●")
	end
end

for _, name in ipairs(repos.repos or {}) do
	if not pinned[name] and not session_ids[name] then
		row("dir", name, repo_dirs[name], " ")
	end
end
