-- Working directories of terminal blocks.

local util = require("rex_sessions.util")

local M = {}

-- The terminal reports a directory as a file:// URL when the program used
-- OSC 7 (file://host/Users/you/src), or as a plain path otherwise.
local function reported_path(pwd)
	local path = pwd:match("^file://[^/]*(.*)$")
	if not path then
		return pwd
	end
	return (path:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end))
end

-- The directory a program last reported, falling back to the foreground
-- process's cwd when none has.
function M.block_cwd(block_id)
	local reported = rex.block.call(util.TERMINAL, "pwd", { block_id = block_id })
	if reported and reported.pwd and reported.pwd ~= "" then
		return reported_path(reported.pwd)
	end
	local info = rex.block.call(util.TERMINAL, "process", { block_id = block_id })
	return info and info.foreground and info.foreground.cwd
end

return M
