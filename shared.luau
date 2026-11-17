--!nonstrict
-- Helpers every entry needs: running the engine, reading the shared status,
-- and turning PIA's region ids and states into words people read.

local M = {}

M.PANEL_ID = "lmaule/pia-vpn:panel"

function M.shellQuote(s)
  return "'" .. string.gsub(tostring(s), "'", "'\\''") .. "'"
end

-- tr() with "{name}" placeholders filled in here, so it works on every API level.
function M.tr(key, subst)
  local text = noctalia.tr(key)
  if type(subst) == "table" then
    for k, v in pairs(subst) do
      text = string.gsub(text, "{" .. k .. "}", function() return tostring(v) end)
    end
  end
  return text
end

function M.trim(s)
  return noctalia.string.trim(tostring(s or ""))
end

function M.markerPath()
  local data = noctalia.pluginDataDir()
  return (type(data) == "string" and data ~= "") and data .. "/account" or nil
end

-- The engine ships inside the plugin, so nothing extra has to be on PATH.
function M.engine(args)
  local marker = M.markerPath()
  local env = marker ~= nil and `PIA_MARKER={M.shellQuote(marker)} ` or ""
  return `{env}bash {M.shellQuote(noctalia.pluginDir() .. "/bin/pia.sh")} {args}`
end

-- Every engine call answers with one JSON object: done(decoded) or done(nil, err).
function M.call(args, done)
  noctalia.runAsync(M.engine(args), function(result)
    if result == nil then
      if done then done(nil, noctalia.tr("error.engine")) end
      return
    end
    if result.timedOut then
      if done then done(nil, noctalia.tr("error.timeout")) end
      return
    end
    local decoded = noctalia.json.decode(result.stdout or "")
    if type(decoded) ~= "table" then
      local stderr = M.trim(result.stderr)
      if done then done(nil, stderr ~= "" and stderr or noctalia.tr("error.engine")) end
      return
    end
    if done then
      if decoded.ok then
        done(decoded, nil)
      else
        done(decoded, tostring(decoded.error or noctalia.tr("error.generic")))
      end
    end
  end)
end

-- ── shared status ───────────────────────────────────────────────────────────
-- The service publishes `status`; everything else reads it. Asking for a
-- refresh is a write to `refresh`, which the service watches.

function M.status()
  local s = noctalia.state.get("status")
  return type(s) == "table" and s or { phase = "loading" }
end

function M.requestRefresh()
  noctalia.state.set("refresh", noctalia.nowMs())
end

-- Optimistic state while an action runs, so every surface reacts at once.
function M.setPending(value)
  noctalia.state.set("pending", value or "")
  noctalia.state.set("pendingAt", noctalia.nowMs())
end

-- Connect/disconnect from any surface. Signed out (or anything not ready)
-- opens the panel instead, where the reason is explained.
function M.toggleConnection(onError)
  local status = M.status()
  local k = M.kind(status)
  if k == "connected" or (k == "busy" and M.pending() ~= "disconnecting") then
    M.setPending("disconnecting")
    M.call("disconnect", function(_, err)
      if err then M.setPending(""); if onError then onError(err) end end
      M.requestRefresh()
    end)
  elseif k == "disconnected" then
    M.setPending("connecting")
    M.call("connect", function(_, err)
      if err then M.setPending(""); if onError then onError(err) end end
      M.requestRefresh()
    end)
  elseif k ~= "busy" then
    noctalia.togglePanel(M.PANEL_ID)
  end
end

-- Disconnect, wait for the tunnel to drop, connect again: applies protocol and
-- port-forwarding changes, which PIA only reads when a connection starts.
function M.reconnect(onError)
  M.setPending("reconnecting")
  M.call("reconnect", function(_, err)
    if err then
      M.setPending("")
      if onError then onError(err) end
    else
      -- The engine has asked for the new connection: the service takes over
      -- from here, and starts the connected clock and settings afresh.
      M.setPending("connecting")
      noctalia.state.set("connectedSince", 0)
    end
    M.requestRefresh()
  end)
end

-- When the current tunnel came up (ms), or nil while there is none.
function M.connectedSince()
  local since = tonumber(noctalia.state.get("connectedSince")) or 0
  return since > 0 and since or nil
end

-- "under a minute", "12 min", "1 h 12 min"; nil when not connected.
function M.durationLabel()
  local since = M.connectedSince()
  if since == nil then return nil end
  local mins = math.floor(math.max(0, noctalia.nowMs() - since) / 60000)
  if mins < 1 then return noctalia.tr("duration.under_minute") end
  if mins < 60 then return M.tr("duration.minutes", { m = mins }) end
  return M.tr("duration.hours", { h = math.floor(mins / 60), m = mins % 60 })
end

function M.pending()
  local p = noctalia.state.get("pending")
  return type(p) == "string" and p or ""
end

-- What the UI should show, folding the daemon's seven states into four.
-- returns kind: "connected" | "busy" | "disconnected" | "offline" | "signedout" | "missing" | "loading"
function M.kind(status)
  status = status or M.status()
  if status.phase == "loading" then return "loading" end
  if status.installed == false then return "missing" end
  if status.daemon == false then return "offline" end
  if status.loggedIn == false then return "signedout" end
  local p = M.pending()
  if p == "connecting" or p == "disconnecting" or p == "reconnecting" then return "busy" end
  local s = status.state or ""
  if s == "Connected" then return "connected" end
  if s == "Disconnected" or s == "" then return "disconnected" end
  return "busy"
end

function M.stateLabel(status)
  status = status or M.status()
  local k = M.kind(status)
  if k == "connected" then return noctalia.tr("state.connected") end
  if k == "disconnected" then return noctalia.tr("state.disconnected") end
  if k == "missing" then return noctalia.tr("state.missing") end
  if k == "offline" then return noctalia.tr("state.offline") end
  if k == "signedout" then return noctalia.tr("state.signedout") end
  if k == "loading" then return noctalia.tr("state.loading") end
  local p = M.pending()
  if p == "disconnecting" or status.state == "Disconnecting" then
    return noctalia.tr("state.disconnecting")
  end
  if p == "reconnecting" or status.state == "Interrupted" or status.state == "Reconnecting"
      or status.state == "DisconnectingToReconnect" then
    return noctalia.tr("state.reconnecting")
  end
  return noctalia.tr("state.connecting")
end

function M.glyphFor(kind)
  if kind == "connected" then return "shield-check" end
  if kind == "busy" then return "shield-half" end
  if kind == "missing" or kind == "offline" then return "shield-x" end
  if kind == "signedout" then return "shield-lock" end
  return "shield-off"
end

function M.colorFor(kind)
  if kind == "connected" then return "primary" end
  if kind == "busy" then return "tertiary" end
  -- Unprotected traffic is the state worth noticing, so it is not grey.
  if kind == "disconnected" or kind == "missing" or kind == "offline" then return "error" end
  return "on_surface_variant"
end

-- ── regions ─────────────────────────────────────────────────────────────────
-- PIA ids are either a country ("switzerland") or a country code plus a city
-- ("us-chicago", "uk-london", "de-germany-streaming-optimized").

local COUNTRIES = {
  us = "United States", uk = "United Kingdom", ca = "Canada", au = "Australia",
  de = "Germany", nz = "New Zealand", fr = "France", it = "Italy", es = "Spain",
  nl = "Netherlands", se = "Sweden", jp = "Japan", ch = "Switzerland", no = "Norway",
  dk = "Denmark", fi = "Finland", be = "Belgium", at = "Austria", ie = "Ireland",
  pt = "Portugal", pl = "Poland", cz = "Czech Republic", ro = "Romania", ["in"] = "India",
  br = "Brazil", mx = "Mexico", ar = "Argentina", sg = "Singapore", hk = "Hong Kong",
  za = "South Africa", ae = "United Arab Emirates", il = "Israel", tr = "Turkey",
  gr = "Greece", hu = "Hungary", bg = "Bulgaria", rs = "Serbia", ua = "Ukraine",
  kr = "South Korea", tw = "Taiwan", lu = "Luxembourg", sk = "Slovakia",
  lt = "Lithuania", lv = "Latvia", ee = "Estonia", cl = "Chile", co = "Colombia",
  pe = "Peru", is = "Iceland", hr = "Croatia", si = "Slovenia", cy = "Cyprus",
  my = "Malaysia", th = "Thailand", ph = "Philippines", id = "Indonesia", vn = "Vietnam",
  eg = "Egypt", ng = "Nigeria", ke = "Kenya", ma = "Morocco", sa = "Saudi Arabia",
  qa = "Qatar", pk = "Pakistan", bd = "Bangladesh", md = "Moldova", ge = "Georgia",
}

local SMALL = { ["and"] = true, ["of"] = true, ["the"] = true }

local function titleCase(words)
  local out = {}
  for i, w in ipairs(words) do
    if i > 1 and SMALL[w] then
      table.insert(out, w)
    elseif #w <= 3 and (w == "dc" or w == "uk" or w == "us" or w == "uae") then
      table.insert(out, string.upper(w))
    else
      table.insert(out, string.upper(string.sub(w, 1, 1)) .. string.sub(w, 2))
    end
  end
  return table.concat(out, " ")
end

local function split(id)
  local words = {}
  for w in string.gmatch(string.lower(id), "[^%-_]+") do
    table.insert(words, w)
  end
  return words
end

-- returns country, city ("" when the id is a whole country)
function M.regionParts(id)
  if id == nil or id == "" then return "", "" end
  if id == "auto" then return noctalia.tr("region.auto"), "" end
  local words = split(id)
  local code = words[1]
  if #words > 1 and #code == 2 and COUNTRIES[code] ~= nil then
    local country = COUNTRIES[code]
    local rest = { table.unpack(words, 2) }
    -- "de-germany-streaming-optimized": drop the repeated country word.
    local lowerCountry = split(country)
    local i = 1
    while i <= #lowerCountry and rest[1] == lowerCountry[i] do
      table.remove(rest, 1)
      i += 1
    end
    if #rest == 0 then return country, "" end
    return country, titleCase(rest)
  end
  -- "japan-streaming-optimized" style ids keep the tail as the city.
  local tailAt = table.find(words, "streaming")
  if tailAt ~= nil and tailAt > 1 then
    return titleCase({ table.unpack(words, 1, tailAt - 1) }),
           titleCase({ table.unpack(words, tailAt) })
  end
  return titleCase(words), ""
end

function M.regionName(id)
  local country, city = M.regionParts(id)
  if city ~= "" then
    return `{country} · {city}`
  end
  return country
end

-- A short form for the bar: the city when there is one, else the country.
function M.regionShort(id)
  local country, city = M.regionParts(id)
  return city ~= "" and city or country
end

-- ── latency ─────────────────────────────────────────────────────────────────
-- `pia.sh latency` returns the daemon's state dump plus the cli names from
-- `piactl get regions`. Locations in the dump carry an internal id and a
-- latency (ms, null until measured); the cli name is built from display
-- metadata exactly as piactl does it (cli/src/getcommand.cpp,
-- getRegionCliName). Both lists share one order (dedicated IPs, then grouped
-- locations), which is the fallback when a built name isn't a known region.

local function enUS(text)
  return type(text) == "table" and type(text["en-US"]) == "string" and text["en-US"] or ""
end

local function latencyMs(loc)
  local ms = type(loc) == "table" and tonumber(loc.latency) or nil
  return ms ~= nil and ms >= 0 and math.floor(ms + 0.5) or nil
end

-- returns { [cliName] = ms } ("auto" = the fastest location's latency)
function M.parseLatency(result)
  local out = {}
  local state = type(result) == "table" and result.state or nil
  if type(state) ~= "table" then return out end
  local meta = type(state.regionsMetadata) == "table" and state.regionsMetadata or {}
  local countries = type(meta.countryDisplays) == "table" and meta.countryDisplays or {}
  local displays = type(meta.regionDisplays) == "table" and meta.regionDisplays or {}

  -- Dump order, plus how many locations each country groups (nested naming).
  local locs, perCountry = {}, {}
  for _, loc in ipairs(type(state.dedicatedIpLocations) == "table" and state.dedicatedIpLocations or {}) do
    table.insert(locs, loc)
  end
  for _, group in ipairs(type(state.groupedLocations) == "table" and state.groupedLocations or {}) do
    local list = type(group) == "table" and type(group.locations) == "table" and group.locations or {}
    if group.code ~= nil then perCountry[group.code] = #list end
    for _, loc in ipairs(list) do table.insert(locs, loc) end
  end

  local names, known = {}, {}
  for _, name in ipairs(type(result.regions) == "table" and result.regions or {}) do
    if name ~= "auto" then
      table.insert(names, name)
      known[name] = true
    end
  end

  local function cliName(loc)
    local id = tostring(loc.id or "")
    local display = type(displays[id]) == "table" and displays[id] or {}
    local country = display.country
    local cd = country ~= nil and type(countries[country]) == "table" and countries[country] or {}
    local name
    if country ~= nil and (perCountry[country] or 0) > 1 then
      name = enUS(cd.prefix) .. enUS(display.name)
    else
      name = enUS(cd.name)
    end
    if name == "" then name = id end
    if type(loc.dedicatedIp) == "string" and loc.dedicatedIp ~= "" then
      name = `dedicated-{name}-{loc.dedicatedIp}`
    end
    return (string.gsub(string.lower(name), "%s", "-"))
  end

  local sameOrder = #names == #locs
  for i, loc in ipairs(locs) do
    if type(loc) == "table" then
      local ms = latencyMs(loc)
      if ms ~= nil then
        local name = cliName(loc)
        if not known[name] and sameOrder then name = names[i] end
        if known[name] then out[name] = ms end
      end
    end
  end

  local vpn = type(state.vpnLocations) == "table" and state.vpnLocations or {}
  out.auto = latencyMs(vpn.bestLocation)
  return out
end

-- "42 ms" and a colour role: quick, fine, slow.
function M.latencyLabel(ms)
  if ms == nil then return nil, nil end
  local color = ms < 100 and "primary" or (ms < 250 and "on_surface_variant" or "error")
  return M.tr("value.latency", { ms = ms }), color
end

function M.protocolName(p)
  if p == "wireguard" then return "WireGuard" end
  if p == "openvpn" then return "OpenVPN" end
  return p ~= nil and p ~= "" and p or "—"
end

-- piactl prints "Inactive", "Attempting", "Failed", "Unavailable" or a port.
function M.portLabel(status)
  local pf = status.portforward or ""
  if status.requestportforward ~= "true" then return noctalia.tr("value.off") end
  if string.match(pf, "^%d+$") then return pf end
  if pf == "Attempting" then return noctalia.tr("value.pf_attempting") end
  if pf == "Failed" or pf == "Unavailable" then return noctalia.tr("value.pf_unavailable") end
  return noctalia.tr("value.pf_waiting")
end

function M.ipLabel(ip)
  if ip == nil or ip == "" or ip == "Unknown" then return "—" end
  return ip
end

return M
