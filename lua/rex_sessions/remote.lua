-- Running this package's actions on another server, from a key action.
--
-- Key actions run on the app's own server (see client.lua), but some
-- state, such as pins, lives on the session's server and only its config
-- can read it. Lua can't invoke another server's actions, so run
-- `rex do` there in a hidden terminal (a detached block in the session)
-- and read the result from its screen.

local util = require("rex_sessions.util")

local check = util.check

local M = {}

-- Printed with the action's exit status once its result is on screen.
-- Letters and underscores only, so it's also a plain Lua pattern.
local DONE = "rex_sessions_done"

-- Seconds to wait for the result. Rex stops a config action after 30.
local TIMEOUT = 10

-- Runs on the session's server as: sh -c SCRIPT sh ACTION. Rex puts its
-- `rex` first on a terminal's PATH. The sleep keeps the result on screen
-- until it's read, and closes the block if the key action never does.
local SCRIPT = [[
rex do "$1" 2>&1
echo "]] .. DONE .. [[ $?"
sleep 60
]]

local function screen_text(api, session_id, block_id)
	local screen = check(api.call("block.method", {
		session_id = session_id,
		block_id = block_id,
		method = "format",
		args = { trim = true, unwrap = true },
	}))
	return screen.content or ""
end

-- The action's output and exit status, or nil until DONE is on screen.
local function finished(text)
	local output, status = text:match("^%s*(.-)%s*" .. DONE .. " (%d+)")
	return output, tonumber(status)
end

local function wait_for_result(api, session_id, block_id)
	local deadline = os.time() + TIMEOUT
	while true do
		local output, status = finished(screen_text(api, session_id, block_id))
		if status then
			return output, status
		end
		if os.time() >= deadline then
			error("no answer after " .. TIMEOUT .. "s", 0)
		end
		rex.exec({ "/bin/sleep", "0.02" })
	end
end

-- The result of action `name` run by `server`'s config, in its session
-- `session_id`, or nil if it returns nothing. Fails with the action's
-- error, e.g. when that server hasn't set this package up.
function M.invoke(server, session_id, name)
	local api = rex.server(server)
	local block_id = check(api.call("session.new_block", {
		session_id = session_id,
		flavor = util.SHELL,
		label = "rex-sessions",
		options = {
			shell = "none",
			command = { "/bin/sh", "-c", SCRIPT, "sh", name },
			size = { columns = 400, rows = 50 },
		},
	})).block_id
	local ok, output, status = pcall(wait_for_result, api, session_id, block_id)
	api.call("block.close", { session_id = session_id, block_id = block_id })
	if not ok or status ~= 0 then
		error(name .. " on " .. server .. ": " .. output, 0)
	end
	if output ~= "" then
		return check(rex.json.decode(output))
	end
end

return M
