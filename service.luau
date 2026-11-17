--!nonstrict
-- Headless status owner. Runs `pia.sh watch` (one JSON line per change) and
-- publishes the decoded status to shared state, so the bar widget, the
-- control-centre tile and the panel all draw from one source and nothing
-- polls piactl twice.

local shared = require("./shared.luau")

local lastKind = nil
local connectedRegion = nil   -- where the tunnel last came up; nil once it is down
local connectedIp = nil
local streamSeq = 0

-- Remember when the tunnel came up, and which settings it came up with, so
-- the UI can show "connected for" and know when a reconnect would apply a
-- changed protocol or port-forwarding setting.
local function trackConnection(status)
  local up = status.state == "Connected" and status.loggedIn ~= false and status.daemon ~= false
  local since = tonumber(noctalia.state.get("connectedSince")) or 0
  if up then
    if since == 0 then
      noctalia.state.set("connectedSince", noctalia.nowMs())
      noctalia.state.set("connectedWith", {
        protocol = status.protocol,
        requestportforward = status.requestportforward,
      })
    end
  elseif since ~= 0 then
    noctalia.state.set("connectedSince", 0)
  end
end

-- Connect, disconnect and drop notifications, plus "Moved to" when the tunnel
-- changes location. The region setting changes before the tunnel moves, so a
-- move counts once the tunnel has cycled or its VPN IP has changed.
local function notifyChange(status, kind, prevKind)
  local message, isError = nil, false
  if kind == "connected" then
    if prevKind ~= "connected" then
      local moved = connectedRegion ~= nil and status.region ~= connectedRegion
      message = shared.tr(moved and "notify.moved" or "notify.connected",
                          { region = shared.regionName(status.region) })
      connectedRegion, connectedIp = status.region, status.vpnip
    elseif status.region ~= connectedRegion and status.vpnip ~= connectedIp
        and shared.ipLabel(status.vpnip) ~= "—" then
      message = shared.tr("notify.moved", { region = shared.regionName(status.region) })
      connectedRegion, connectedIp = status.region, status.vpnip
    end
  elseif kind == "disconnected" then
    if prevKind == "connected" then message = noctalia.tr("notify.disconnected") end
    connectedRegion, connectedIp = nil, nil
  elseif status.state == "Interrupted" and prevKind == "connected" then
    message, isError = noctalia.tr("notify.interrupted"), true
  end
  if message == nil or prevKind == nil or not noctalia.getConfig("notify_changes") then return end
  if isError then
    noctalia.notifyError(noctalia.tr("title"), message)
  else
    noctalia.notify(noctalia.tr("title"), message)
  end
end

local function publish(status)
  status.phase = "ready"
  local prevKind = lastKind
  noctalia.state.set("status", status)

  -- An action's optimistic state ends once the daemon agrees with it.
  -- The daemon takes over the moment it leaves "Disconnected"; a stale guess
  -- (a refused connect, say) gives up after 15 s. A reconnect is handed over
  -- as "connecting" by shared.reconnect once its new connection is asked for.
  local pending = shared.pending()
  local age = noctalia.nowMs() - (tonumber(noctalia.state.get("pendingAt")) or 0)
  if pending ~= "" and (
      (pending == "connecting" and status.state ~= nil and status.state ~= "Disconnected")
      or (pending == "disconnecting" and status.state == "Disconnected")
      or status.loggedIn == false or status.daemon == false or status.installed == false
      or age > 15000) then
    shared.setPending("")
  end

  trackConnection(status)

  local kind = shared.kind(status)
  notifyChange(status, kind, prevKind)
  lastKind = kind
end

local function onLine(line)
  local decoded = noctalia.json.decode(line or "")
  if type(decoded) == "table" then
    publish(decoded)
  end
end

local function startStream()
  streamSeq += 1
  local ok = noctalia.runStream(shared.engine("watch"), onLine)
  if not ok then
    noctalia.log("pia-vpn: could not start status stream")
  end
end

local function refreshNow()
  shared.call("status", function(result)
    if type(result) == "table" then
      publish(result)
    end
  end)
end

-- Panels and tiles ask for an immediate refresh after they change something.
noctalia.state.watch("refresh", function()
  refreshNow()
end)

-- A sign-in interrupted by a crash or logout could leave its credentials file
-- behind. The engine shreds it on every normal path; this catches the rest.
local function shredStaleCredentials()
  local data = noctalia.pluginDataDir()
  if type(data) ~= "string" or data == "" then return end
  for _, name in ipairs(noctalia.listDir(data) or {}) do
    local base = type(name) == "table" and name.name or name
    if type(base) == "string" and string.match(base, "^login%-%d+%.cred$") then
      local path = `{data}/{base}`
      noctalia.runAsync({ "shred", "-u", path }, function(result)
        if noctalia.fileExists(path) then noctalia.removeFile(path) end
      end)
    end
  end
end

shredStaleCredentials()
noctalia.state.set("status", { phase = "loading" })
noctalia.state.set("connectedSince", 0)
shared.setPending("")
startStream()
refreshNow()

-- Keybinds: noctalia msg plugin lmaule/pia-vpn:status all <toggle|connect|disconnect|refresh>
function onIpc(event, _payload)
  local function report(err)
    if err then noctalia.notifyError(noctalia.tr("title"), err) end
  end
  local kind = shared.kind()
  if event == "toggle" then
    shared.toggleConnection(report)
  elseif event == "connect" and kind == "disconnected" then
    shared.toggleConnection(report)
  elseif event == "disconnect" and (kind == "connected" or kind == "busy") then
    shared.toggleConnection(report)
  elseif event == "refresh" then
    refreshNow()
  end
end

function onResume()
  refreshNow()
end

function onConfigChanged()
  refreshNow()
end
