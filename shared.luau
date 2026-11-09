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
  if p == "connecting" or p == "disconnecting" then return "busy" end
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
  if status.state == "Interrupted" or status.state == "Reconnecting"
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
  if kind == "missing" or kind == "offline" then return "error" end
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
