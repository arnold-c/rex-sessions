-- Constants and helpers shared by the rex_sessions modules.

local M = {}

M.HOME = os.getenv("HOME")
M.SHELL = "com.superlogical.terminal.shell"
M.TERMINAL = "com.superlogical.terminal"

function M.check(result, err)
	if err ~= nil then
		error(err, 0)
	end
	return result
end

-- PATH with a leading ~ and any $NAME expanded from this server's
-- environment. An unset variable expands to "".
function M.expand(path)
	local expanded = path:gsub("^~", M.HOME):gsub("%$([%w_]+)", function(name)
		return os.getenv(name) or ""
	end)
	return expanded
end

-- A key option as a list: a key, a list of keys, or false/nil for none.
function M.keys(value)
	if type(value) == "string" then
		return { value }
	end
	return value or {}
end

return M
