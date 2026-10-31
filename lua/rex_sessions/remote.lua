-- Running Lua on another server, from a key action.
--
-- Key actions run on the app's own server (see client.lua), but some
-- state, such as pins, lives on the session's server and only its config
-- can read it. Lua can't invoke another server's actions, so run a
-- script with `rex do -e` there, in a hidden terminal (a detached block
-- in the session), and read the result from its screen.

local util = require("rex_sessions.util")

local check = util.check

local M = {}

-- Printed before the script's output, and after it with its exit status.
-- Anything the terminal shows first, such as macOS's "Last login" line,
-- comes before BEGIN. Letters and underscores only, so they're also
-- plain Lua patterns.
local BEGIN = "rex_sessions_begin"
local DONE = "rex_sessions_done"

-- Seconds to wait for the result. Rex stops a config action after 30.
local TIMEOUT = 10

-- Runs on the session's server as: sh -c SCRIPT sh CODE. Rex puts its
-- `rex` first on a terminal's PATH. The output is printed as hex, as the
-- screen wraps and trims lines. The sleep keeps it on screen until it's
-- read, and closes the block if the key action never does.
local SCRIPT = string.format(
	[[
out=$(rex do -e "$1" 2>&1)
code=$?
echo %s
printf '%%s' "$out" | od -An -v -tx1 | tr -d ' \n'
echo
echo "%s $code"
sleep 60
]],
	BEGIN,
	DONE
)

local function screen_text(api, session_id, block_id)
	local screen = check(api.call("block.method", {
		session_id = session_id,
		block_id = block_id,
		method = "format",
		args = { trim = true, unwrap = true },
	}))
	return screen.content or ""
end

local function from_hex(text)
	return (text:gsub("%X", ""):gsub("%x%x", function(byte)
		return string.char(tonumber(byte, 16))
	end))
end

-- The script's output and exit status, or nil until DONE is on screen.
local function finished(text)
	local hex, status = text:match(BEGIN .. "(.-)" .. DONE .. " (%d+)")
	if status then
		return from_hex(hex), tonumber(status)
	end
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

-- The result of Lua `code` run as a script on `server` (`rex do -e`), in
-- its session `session_id`, or nil if it returns nothing. Fails with the
-- script's error.
function M.eval(server, session_id, code)
	local api = rex.server(server)
	local block_id = check(api.call("session.new_block", {
		session_id = session_id,
		flavor = util.SHELL,
		label = "rex-sessions",
		options = {
			shell = "none",
			command = { "/bin/sh", "-c", SCRIPT, "sh", code },
			size = { columns = 400, rows = 50 },
		},
	})).block_id
	local ok, output, status = pcall(wait_for_result, api, session_id, block_id)
	api.call("block.close", { session_id = session_id, block_id = block_id })
	if not ok or status ~= 0 then
		error(server .. ": " .. output, 0)
	end
	if output == "" then
		return nil
	end
	local result, err = rex.json.decode(output)
	if err ~= nil then
		error(server .. ": unexpected output: " .. output, 0)
	end
	return result
end

return M
