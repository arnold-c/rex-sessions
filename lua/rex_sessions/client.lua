-- Asking this app to do something, in a session on any server.
--
-- Key actions run on the app's own server, where rex.client.queue reaches
-- the app. For another server's session, ask through that server: the app
-- connects to each host separately, with a different client_id there.

local util = require("rex_sessions.util")

local check = util.check

local M = {}

-- Key actions run on the app's own machine, so this is the app's host.
local function local_node()
	return (check(rex.exec({ "/bin/hostname", "-s" })).stdout:gsub("%s+$", ""))
end

-- This app's client on `api`, a server from rex.server(LABEL). Calls made
-- while in a remote session go to that server, so the local client_id
-- can't be looked up; match the node (e.g. Tailscale) the app connects
-- from.
local function app_client_id(api, label)
	local node = local_node()
	for _, client in ipairs(check(api.call("client.list", { kinds = { "app" } })).clients or {}) do
		if client.principal and client.principal.node == node then
			return client.client_id
		end
	end
	error("no app connected from " .. node .. " on " .. label, 0)
end

-- Performs the app's session.select with `args` (session_id, window_id?)
-- for a session on `server`: a host label, or nil for the app's own.
function M.select(ctx, server, args)
	if not server then
		rex.client.queue("session.select", args)
		return
	end
	local api = rex.server(server)
	check(api.call("client.perform", {
		client_id = app_client_id(api, server),
		action = "session.select",
		args = args,
		origin = ctx.origin,
	}))
end

return M
