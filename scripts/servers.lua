-- Servers for session-picker.py, one tab-separated line each:
--   client LABEL   the label of the app that opened the picker
--   home MODE      the server on the machine that app runs on
--   remote MODE    each other server this one can reach
-- MODE is `local` for this server, or `remote:LABEL` for one of its hosts
-- (`rex hosts`).
--
-- The action opening the picker runs on the app's own server, even for a
-- remote session, so `client_id` may be from any server: look on each.
-- An app has the same label on every server, and its own machine is the
-- one it reaches over a Unix socket. Without a match, fall back to the
-- only app attached to this session, then to this server.
-- Usage: rex do scripts/servers.lua --args '{"client_id": "client:…"}'

local client_id = (rex.args or {}).client_id

local function apps(api, filter)
	local listed = api.call("client.list", filter)
	return listed and listed.clients or {}
end

local function app_label(app)
	return app.info and app.info.label
end

local servers = { { mode = "local" } }
for _, label in ipairs(rex.servers() or {}) do
	table.insert(servers, { mode = "remote:" .. label, label = label })
end

-- A server's apps, asked for on first use. An unreachable remote (a
-- laptop that's asleep) makes the picker wait out its connection
-- timeout, so the searches below start here and stop at the first
-- match: from the app's own machine, no remote is asked at all.
local function server_apps(server)
	if not server.apps then
		local api = server.label and rex.server(server.label) or rex
		server.apps = apps(api, { kinds = { "app" } })
	end
	return server.apps
end

local function client_label()
	if client_id and client_id ~= "" then
		for _, server in ipairs(servers) do
			for _, app in ipairs(server_apps(server)) do
				if app.client_id == client_id then
					return app_label(app)
				end
			end
		end
	end
	local attached = rex.session_id and apps(rex, { kinds = { "app" }, session_id = rex.session_id }) or {}
	if #attached == 1 then
		return app_label(attached[1])
	end
end

local function runs_on(server, label)
	for _, app in ipairs(server_apps(server)) do
		if app_label(app) == label and app.principal.transport == "unix" then
			return true
		end
	end
	return false
end

local label = client_label()
local home = 1
for i, server in ipairs(servers) do
	if label and runs_on(server, label) then
		home = i
		break
	end
end

print("client\t" .. (label or ""))
print("home\t" .. servers[home].mode)
for i, server in ipairs(servers) do
	if i ~= home then
		print("remote\t" .. server.mode)
	end
end
