-- Pinned sessions, stored on the server whose sessions they are so every
-- picker shows the same ones. Each line of the file is `label<TAB>dir`;
-- the dir lets a closed pinned session be recreated.

local util = require("rex_sessions.util")

local M = {}

M.FILE = (os.getenv("XDG_STATE_HOME") or util.HOME .. "/.local/state") .. "/rex/pins"

function M.read()
	local pins = {}
	local file = io.open(M.FILE)
	if file then
		for line in file:lines() do
			local label, dir = line:match("^([^\t]+)\t?(.*)$")
			if label then
				table.insert(pins, { label = label, dir = dir ~= "" and dir or nil })
			end
		end
		file:close()
	end
	return pins
end

function M.write(pins)
	util.check(rex.exec({ "/bin/mkdir", "-p", M.FILE:match("^(.*)/") }))
	local file = assert(io.open(M.FILE, "w"))
	for _, pin in ipairs(pins) do
		file:write(pin.label, "\t", pin.dir or "", "\n")
	end
	file:close()
end

function M.index(pins, label)
	for i, pin in ipairs(pins) do
		if pin.label == label then
			return i
		end
	end
end

-- Pins in the order the picker numbers them and the pin keys follow: open
-- ones (given their session_id) in the order of `sessions` (the server's,
-- which the app's sidebar shows and its drags change), then closed ones
-- in the file's order.
function M.ordered(sessions)
	local pins = M.read()
	local by_label = {}
	for _, pin in ipairs(pins) do
		by_label[pin.label] = pin
	end
	local ordered = {}
	for _, session in ipairs(sessions) do
		local pin = by_label[session.label]
		if pin and not pin.session_id then
			pin.session_id = session.session_id
			table.insert(ordered, pin)
		end
	end
	for _, pin in ipairs(pins) do
		if not pin.session_id then
			table.insert(ordered, pin)
		end
	end
	return ordered
end

return M
