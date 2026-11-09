--!nonstrict
-- The PIA panel: sign in, see what the tunnel is doing, pick a location and
-- change the few settings piactl exposes. All work goes through bin/pia.sh;
-- live status comes from the service through shared state.

local shared = require("./shared.luau")
local tr = shared.tr

local render

-- ── state ───────────────────────────────────────────────────────────────────
-- Module globals outlive a close, so reopening shows the last view at once.

local isOpen = false
local tab = "locations"            -- "locations" | "settings"
local query = ""
local username = ""
local password = ""
local formGen = 0                  -- bumps to give the login inputs fresh keys (clears them)
local busy = ""                    -- "" | "login" | "logout" | "region" | "setting"
local errorText = ""
local confirmLogout = false
local regionsLoading = false
local chosenRegion = nil           -- optimistic until the daemon reports it
local favorites = {}
local expandedCountries = {}       -- country name -> unfolded in the Locations list
local overrides = {}               -- setting -> value, optimistic until the daemon agrees

local PROTOCOLS = { "wireguard", "openvpn" }

-- ── persistence ─────────────────────────────────────────────────────────────

local function favoritesPath()
  local data = noctalia.pluginDataDir()
  return data ~= nil and data ~= "" and data .. "/favorites.json" or nil
end

local function loadFavorites()
  local path = favoritesPath()
  if path == nil or not noctalia.fileExists(path) then return end
  local decoded = noctalia.json.decode(noctalia.readFile(path) or "")
  if type(decoded) == "table" then
    favorites = {}
    for _, id in ipairs(decoded) do favorites[id] = true end
  end
end

local function saveFavorites()
  local path = favoritesPath()
  if path == nil then return end
  local list = {}
  for id in pairs(favorites) do table.insert(list, id) end
  table.sort(list)
  noctalia.writeFile(path, noctalia.json.encode(list))
end

loadFavorites()

-- ── helpers ─────────────────────────────────────────────────────────────────

local function regions()
  local r = noctalia.state.get("regions")
  return type(r) == "table" and r or {}
end

local function loadRegions(force)
  if regionsLoading or (#regions() > 0 and not force) then return end
  regionsLoading = true
  shared.call("regions", function(result, err)
    regionsLoading = false
    if result ~= nil and not err then
      noctalia.state.set("regions", result.regions or {})
    end
    if isOpen then render() end
  end)
end

local function fail(message)
  busy = ""
  errorText = message or tr("error.generic")
  if isOpen then render() end
end

local function settingValue(status, key)
  if overrides[key] ~= nil then return overrides[key] end
  return status[key]
end

local function nothing()
  return ui.box({ width = 0, height = 0 })
end

-- A glyph in a soft tinted disc, the visual anchor of every state.
local function badge(glyph, color, size)
  size = size or 64
  return ui.column({ width = size, height = size, radius = size / 2, fill = `{color}/0.14`,
                     align = "center", justify = "center" }, {
    ui.glyph({ name = glyph, size = math.floor(size * 0.5), color = color }),
  })
end

local function header(status)
  local kids = {
    ui.glyph({ name = "shield-lock", size = 18, color = "primary" }),
    ui.label({ text = tr("title"), fontSize = 15, fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
  }
  local k = shared.kind(status)
  if k ~= "signedout" and k ~= "loading" then
    table.insert(kids, ui.button({ key = "refresh", glyph = "refresh", variant = "ghost", controlSize = "sm",
                                   tooltip = tr("action.refresh"), onClick = "onRefresh" }))
  end
  table.insert(kids, ui.button({ key = "close", glyph = "x", variant = "ghost", controlSize = "sm",
                                 tooltip = tr("action.close"), onClick = "onCloseClicked" }))
  return ui.row({ key = "header", gap = 10, align = "center" }, kids)
end

local function errorBanner()
  if errorText == "" then return nothing() end
  return ui.row({ key = "error_banner", gap = 8, align = "center", padding = 10, radius = 10,
                  fill = "error_container" }, {
    ui.glyph({ name = "alert-triangle", size = 16, color = "on_error_container" }),
    ui.label({ text = errorText, fontSize = 12, color = "on_error_container", flexGrow = 1, maxLines = 3 }),
    ui.button({ key = "error_dismiss", glyph = "x", variant = "ghost", controlSize = "sm",
                onClick = function() errorText = ""; render() end }),
  })
end

-- ── message views (missing client, stopped daemon, loading) ─────────────────

local function messageView(key, glyph, color, title, body, command, actions)
  local kids = {
    ui.spacer({ flexGrow = 1 }),
    badge(glyph, color, 72),
    ui.label({ text = title, fontSize = 18, fontWeight = "bold", textAlign = "center" }),
    ui.label({ text = body, fontSize = 13, color = "on_surface_variant", textAlign = "center", maxLines = 4 }),
  }
  if command ~= nil then
    table.insert(kids, ui.row({ gap = 8, align = "center", paddingH = 12, paddingV = 8, radius = 10,
                                fill = "surface_container" }, {
      ui.glyph({ name = "terminal", size = 14, color = "on_surface_variant" }),
      ui.label({ text = command, fontSize = 12, fontFamily = "monospace", flexGrow = 1, maxLines = 1 }),
      ui.button({ key = `copy_{key}`, glyph = "copy", variant = "ghost", controlSize = "sm",
                  tooltip = tr("action.copy"),
                  onClick = function()
                    noctalia.copyToClipboard(command, "text/plain")
                    noctalia.notify(tr("title"), tr("notify.copied"))
                  end }),
    }))
  end
  if actions ~= nil then
    table.insert(kids, ui.row({ gap = 8, justify = "center" }, actions))
  end
  table.insert(kids, ui.spacer({ flexGrow = 1 }))
  return ui.column({ key = `msg_{key}`, flexGrow = 1, gap = 14, align = "center", paddingH = 12 }, kids)
end

local function retryButton()
  return ui.button({ key = "retry", text = tr("action.retry"), glyph = "refresh", variant = "outline",
                     onClick = "onRefresh" })
end

-- ── sign-in view ────────────────────────────────────────────────────────────

local function loginView()
  local signingIn = busy == "login"
  local userHint = nothing()
  local u = shared.trim(username)
  if u ~= "" and not string.match(u, "^[pP]%d+$") then
    userHint = ui.label({ text = tr("login.username_hint"), fontSize = 11, color = "tertiary" })
  end
  return ui.column({ key = "view_login", flexGrow = 1, gap = 16, align = "stretch", paddingH = 8 }, {
    ui.spacer({ flexGrow = 1 }),
    ui.column({ gap = 10, align = "center" }, {
      badge("shield-lock", "primary", 72),
      ui.label({ text = tr("login.title"), fontSize = 20, fontWeight = "bold", textAlign = "center" }),
      ui.label({ text = tr("login.subtitle"), fontSize = 13, color = "on_surface_variant",
                 textAlign = "center", maxLines = 2 }),
    }),
    errorBanner(),
    ui.column({ gap = 6, align = "stretch" }, {
      ui.label({ text = tr("login.username"), fontSize = 12, fontWeight = "bold", color = "on_surface_variant" }),
      ui.input({ key = `username_{formGen}`, value = username, placeholder = "p1234567",
                 focus = username == "", enabled = not signingIn,
                 onChange = function(v) username = v end,
                 onSubmit = function(v) username = v; onSignIn() end }),
      userHint,
    }),
    ui.column({ gap = 6, align = "stretch" }, {
      ui.label({ text = tr("login.password"), fontSize = 12, fontWeight = "bold", color = "on_surface_variant" }),
      ui.input({ key = `password_{formGen}`, value = "", password = true, placeholder = "••••••••",
                 enabled = not signingIn,
                 onChange = function(v) password = v end,
                 onSubmit = function(v) password = v; onSignIn() end }),
    }),
    ui.button({ key = `signin_{signingIn and "busy" or "idle"}`,
                text = signingIn and tr("login.signing_in") or tr("login.sign_in"),
                glyph = signingIn and "clock" or "arrow-right", variant = "primary", controlSize = "lg",
                enabled = not signingIn, onClick = "onSignIn" }),
    ui.spacer({ flexGrow = 1 }),
    ui.row({ gap = 6, align = "center", justify = "center" }, {
      ui.glyph({ name = "lock", size = 12, color = "on_surface_variant" }),
      ui.label({ text = tr("login.privacy"), fontSize = 11, color = "on_surface_variant",
                 textAlign = "center", maxLines = 2 }),
    }),
  })
end

-- ── connected / disconnected view ───────────────────────────────────────────

local function stat(key, label, value, glyph)
  return ui.column({ key = `stat_{key}`, flexGrow = 1, gap = 2, align = "start", minWidth = 0 }, {
    ui.row({ gap = 4, align = "center" }, {
      ui.glyph({ name = glyph, size = 12, color = "on_surface_variant" }),
      ui.label({ text = label, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.label({ text = value, fontSize = 13, fontWeight = "bold", maxLines = 1 }),
  })
end

local function heroCard(status)
  local kind = shared.kind(status)
  local color = shared.colorFor(kind)
  local regionId = chosenRegion or status.region
  local regionLine = shared.regionName(regionId)
  local subtitle
  if kind == "connected" then
    subtitle = tr("hero.connected_to", { region = regionLine })
  elseif kind == "busy" then
    subtitle = regionLine
  else
    subtitle = tr("hero.ready", { region = regionLine })
  end

  local connected = kind == "connected"
  local button
  if kind == "busy" then
    button = ui.button({ key = "conn_busy", text = tr("action.cancel"), glyph = "x", variant = "outline",
                         controlSize = "lg", enabled = shared.pending() ~= "disconnecting",
                         onClick = "onToggleConnection" })
  elseif connected then
    button = ui.button({ key = "conn_on", text = tr("action.disconnect"), glyph = "plug-connected-x",
                         variant = "outline", controlSize = "lg", onClick = "onToggleConnection" })
  else
    button = ui.button({ key = "conn_off", text = tr("action.connect"), glyph = "plug-connected",
                         variant = "primary", controlSize = "lg", onClick = "onToggleConnection" })
  end

  return ui.column({ key = `hero_{kind}`, gap = 16, padding = 18, radius = 16, align = "stretch",
                     fill = connected and "primary/0.08" or "surface_container",
                     border = connected and "primary/0.35" or "outline_variant", borderWidth = 1 }, {
    ui.row({ gap = 16, align = "center" }, {
      badge(shared.glyphFor(kind), color, 60),
      ui.column({ gap = 4, flexGrow = 1, align = "start" }, {
        ui.label({ text = shared.stateLabel(status), fontSize = 20, fontWeight = "bold",
                   color = connected and "primary" or "on_surface", maxLines = 1 }),
        ui.label({ text = subtitle, fontSize = 13, color = "on_surface_variant", maxLines = 1 }),
      }),
    }),
    ui.row({ gap = 12, align = "start" }, {
      stat("vpnip", tr("field.vpn_ip"), connected and shared.ipLabel(status.vpnip) or "—", "lock"),
      stat("pubip", tr("field.public_ip"), shared.ipLabel(status.pubip), "world"),
    }),
    ui.row({ gap = 12, align = "start" }, {
      stat("protocol", tr("field.protocol"), shared.protocolName(settingValue(status, "protocol")), "route"),
      stat("port", tr("field.port"), connected and shared.portLabel(status) or "—", "network"),
    }),
    button,
  })
end

local function tabButton(id, labelKey, glyph)
  return ui.button({ key = `tab_{id}_{tab == id and "on" or "off"}`, text = tr(labelKey), glyph = glyph,
                     variant = tab == id and "secondary" or "ghost", controlSize = "sm", flexGrow = 1,
                     onClick = function() tab = id; confirmLogout = false; render() end })
end

-- ── locations tab ───────────────────────────────────────────────────────────

-- One selectable server. `child` rows sit under their country's header, so
-- they only need the city and are indented past the header's globe.
local function regionRow(id, status, child)
  local current = (chosenRegion or status.region) == id
  local fav = favorites[id] == true
  local country, city = shared.regionParts(id)
  local textKids
  if child then
    textKids = {
      ui.label({ text = city ~= "" and city or tr("locations.standard"), fontSize = 13, maxLines = 1,
                 fontWeight = current and "bold" or "normal", color = current and "primary" or "on_surface" }),
    }
  else
    textKids = {
      ui.label({ text = country, fontSize = 13, fontWeight = current and "bold" or "normal", maxLines = 1,
                 color = current and "primary" or "on_surface" }),
    }
    if city ~= "" then
      table.insert(textKids, ui.label({ text = city, fontSize = 11, color = "on_surface_variant", maxLines = 1 }))
    end
  end
  local trailing = nothing()
  if current then
    trailing = ui.glyph({ name = "check", size = 16, color = "primary" })
  end
  local favButton = id == "auto" and ui.column({ width = 28, height = 28 }, {})
    or ui.button({ key = `fav_{id}_{fav and "on" or "off"}`, glyph = fav and "star-filled" or "star",
                   variant = "ghost", controlSize = "sm", width = 28, height = 28, glyphSize = 14,
                   tooltip = tr(fav and "action.unfavorite" or "action.favorite"),
                   onClick = function()
                     favorites[id] = (not fav) or nil
                     saveFavorites()
                     render()
                   end })
  local kids = {}
  if child then
    -- Lines the city up under the country name, past the header's glyph.
    table.insert(kids, ui.column({ width = 16, height = 16 }, {}))
  end
  table.insert(kids, ui.glyph({ name = id == "auto" and "bolt" or "map-pin", size = child and 14 or 16,
                                color = current and "primary" or "on_surface_variant" }))
  table.insert(kids, ui.column({ gap = 0, flexGrow = 1, align = "start" }, textKids))
  table.insert(kids, trailing)
  table.insert(kids, favButton)
  return ui.row({ key = `region_{child and "c" or "r"}_{id}_{current and "on" or "off"}`, gap = 10,
                  align = "center", paddingH = 8, paddingV = child and 4 or 6, radius = 10,
                  fill = current and "primary/0.10" or nil,
                  tooltip = id,
                  onClick = function() onSelectRegion(id) end }, kids)
end

-- A country with several servers: one row that folds its cities away. It
-- shows the city you are on while folded, so nothing is hidden that matters.
local function countryRow(country, ids, status, open)
  local currentId = chosenRegion or status.region
  local holdsCurrent = table.find(ids, currentId) ~= nil
  local subtitle = tr("locations.count", { n = #ids })
  if holdsCurrent then
    local _, city = shared.regionParts(currentId)
    subtitle = city ~= "" and city or tr("locations.standard")
  end
  local state = `{open and "open" or "shut"}_{holdsCurrent and "cur" or "no"}`
  return ui.row({ key = `country_{country}_{state}`, gap = 10, align = "center",
                  paddingH = 8, paddingV = 6, radius = 10,
                  fill = (holdsCurrent and not open) and "primary/0.10" or (open and "surface_container" or nil),
                  onClick = function()
                    expandedCountries[country] = not open
                    render()
                  end }, {
    ui.glyph({ name = "world", size = 16, color = holdsCurrent and "primary" or "on_surface_variant" }),
    ui.column({ gap = 0, flexGrow = 1, align = "start" }, {
      ui.label({ text = country, fontSize = 13, maxLines = 1,
                 fontWeight = holdsCurrent and "bold" or "normal",
                 color = holdsCurrent and "primary" or "on_surface" }),
      ui.label({ text = subtitle, fontSize = 11, maxLines = 1,
                 color = holdsCurrent and "primary" or "on_surface_variant" }),
    }),
    (holdsCurrent and not open) and ui.glyph({ name = "check", size = 16, color = "primary" }) or nothing(),
    ui.column({ width = 28, height = 28, align = "center", justify = "center" }, {
      ui.glyph({ name = open and "chevron-down" or "chevron-right", size = 16, color = "on_surface_variant" }),
    }),
  })
end

local function sectionLabel(text)
  return ui.row({ key = `section_{text}`, paddingH = 8, paddingV = 4 }, {
    ui.label({ text = string.upper(text), fontSize = 10, fontWeight = "bold", color = "on_surface_variant" }),
  })
end

local function matches(id, q)
  if q == "" then return true end
  local hay = string.lower(id .. " " .. shared.regionName(id))
  return string.find(hay, q, 1, true) ~= nil
end

-- Inside a country: the plain server first, cities A–Z, streaming last.
local function cityRank(id)
  local _, city = shared.regionParts(id)
  if city == "" then return 0 end
  if string.find(string.lower(city), "streaming", 1, true) then return 2 end
  return 1
end

local function locationsTab(status)
  local all = regions()
  local q = string.lower(shared.trim(query))
  local favRows = {}

  -- Bucket servers by country, in alphabetical order of country then city.
  local groups, order = {}, {}
  for _, id in ipairs(all) do
    if id ~= "auto" then
      local country = shared.regionParts(id)
      if groups[country] == nil then
        groups[country] = {}
        table.insert(order, country)
      end
      table.insert(groups[country], id)
    end
  end
  table.sort(order)

  local rows = {}
  for _, country in ipairs(order) do
    local ids = groups[country]
    table.sort(ids, function(a, b)
      local ra, rb = cityRank(a), cityRank(b)
      if ra ~= rb then return ra < rb end
      return shared.regionName(a) < shared.regionName(b)
    end)
    local hits = {}
    for _, id in ipairs(ids) do
      if matches(id, q) then
        table.insert(hits, id)
        if favorites[id] then table.insert(favRows, regionRow(id, status, false)) end
      end
    end
    if #ids == 1 then
      if #hits == 1 then table.insert(rows, regionRow(ids[1], status, false)) end
    elseif #hits > 0 then
      -- A search opens every country it finds something in.
      local open = q ~= "" or expandedCountries[country] == true
      table.insert(rows, countryRow(country, ids, status, open))
      if open then
        for _, id in ipairs(hits) do
          table.insert(rows, regionRow(id, status, true))
        end
      end
    end
  end

  local list = {}
  if matches("auto", q) then
    table.insert(list, regionRow("auto", status, false))
  end
  if #favRows > 0 then
    table.insert(list, sectionLabel(tr("locations.favorites")))
    for _, r in ipairs(favRows) do table.insert(list, r) end
  end
  if #rows > 0 then
    table.insert(list, sectionLabel(tr("locations.all")))
    for _, r in ipairs(rows) do table.insert(list, r) end
  end
  if #all == 0 then
    list = { ui.label({ text = regionsLoading and tr("locations.loading") or tr("locations.none"),
                        fontSize = 12, color = "on_surface_variant" }) }
  elseif #list == 0 then
    list = { ui.label({ text = tr("locations.no_match"), fontSize = 12, color = "on_surface_variant" }) }
  end

  return ui.column({ key = "tab_locations", flexGrow = 1, gap = 10, align = "stretch" }, {
    ui.input({ key = "search", value = query, placeholder = tr("locations.search"),
               onChange = function(v) query = v; render() end }),
    ui.scroll({ key = "region_list", flexGrow = 1, gap = 2 }, list),
  })
end

-- ── settings tab ────────────────────────────────────────────────────────────

local function settingRow(key, glyph, title, body, control)
  return ui.row({ key = `setting_{key}`, gap = 12, align = "center", padding = 12, radius = 12,
                  fill = "surface_container" }, {
    ui.glyph({ name = glyph, size = 18, color = "on_surface_variant" }),
    ui.column({ gap = 2, flexGrow = 1, align = "start" }, {
      ui.label({ text = title, fontSize = 13, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = body, fontSize = 11, color = "on_surface_variant", maxLines = 2 }),
    }),
    control,
  })
end

local function settingsTab(status)
  local proto = settingValue(status, "protocol") or "wireguard"
  local protoIndex = proto == "openvpn" and 1 or 0
  local pf = settingValue(status, "requestportforward") == "true"
  local lan = settingValue(status, "allowlan") == "true"
  local applying = busy == "setting"

  local accountRow
  if confirmLogout then
    accountRow = ui.column({ key = "account_confirm", gap = 10, padding = 12, radius = 12,
                             fill = "error_container", align = "stretch" }, {
      ui.label({ text = tr("account.confirm"), fontSize = 12, color = "on_error_container", maxLines = 3 }),
      ui.row({ gap = 8, justify = "end" }, {
        ui.button({ key = "logout_cancel", text = tr("action.cancel"), variant = "ghost", controlSize = "sm",
                    onClick = function() confirmLogout = false; render() end }),
        ui.button({ key = "logout_go", text = busy == "logout" and tr("account.signing_out") or tr("account.sign_out"),
                    variant = "destructive", controlSize = "sm", enabled = busy == "",
                    onClick = "onSignOut" }),
      }),
    })
  else
    accountRow = settingRow("account", "user", status.username ~= "" and status.username or tr("account.title"),
      tr("account.signed_in"),
      ui.button({ key = "logout", text = tr("account.sign_out"), glyph = "logout", variant = "ghost",
                  controlSize = "sm", enabled = busy == "",
                  onClick = function() confirmLogout = true; render() end }))
  end

  local note = nothing()
  if shared.kind(status) == "connected" then
    note = ui.label({ text = tr("settings.reconnect_note"), fontSize = 11, color = "on_surface_variant",
                      maxLines = 2 })
  end

  return ui.scroll({ key = "tab_settings", flexGrow = 1, gap = 8 }, {
    settingRow("protocol", "route", tr("settings.protocol"), tr("settings.protocol_desc"),
      ui.select({ key = `protocol_{protoIndex}`, options = { "WireGuard", "OpenVPN" }, selectedIndex = protoIndex,
                  width = 130, controlSize = "sm", enabled = not applying,
                  onChange = function(index) onSetting("protocol", PROTOCOLS[(tonumber(index) or 0) + 1]) end })),
    settingRow("pf", "network", tr("settings.port_forward"), tr("settings.port_forward_desc"),
      ui.toggle({ key = `pf_{pf}`, checked = pf, enabled = not applying,
                  onChange = function(v) onSetting("requestportforward", v == "true" and "true" or "false") end })),
    settingRow("lan", "world-pin", tr("settings.allow_lan"), tr("settings.allow_lan_desc"),
      ui.toggle({ key = `lan_{lan}`, checked = lan, enabled = not applying,
                  onChange = function(v) onSetting("allowlan", v == "true" and "true" or "false") end })),
    note,
    ui.spacer({ height = 6 }),
    accountRow,
  })
end

local function mainView(status)
  return ui.column({ key = "view_main", flexGrow = 1, gap = 14, align = "stretch" }, {
    heroCard(status),
    errorBanner(),
    ui.row({ key = "tabs", gap = 6, padding = 4, radius = 10, fill = "surface_container_low" }, {
      tabButton("locations", "tab.locations", "map-pin"),
      tabButton("settings", "tab.settings", "adjustments"),
    }),
    tab == "locations" and locationsTab(status) or settingsTab(status),
  })
end

-- ── frame ───────────────────────────────────────────────────────────────────

render = function()
  if not isOpen then return end
  local status = shared.status()
  local kind = shared.kind(status)

  -- Drop optimistic values the daemon now reports itself.
  if chosenRegion ~= nil and status.region == chosenRegion then chosenRegion = nil end
  for key, value in pairs(overrides) do
    if status[key] == value then overrides[key] = nil end
  end

  local body
  if kind == "loading" then
    body = messageView("loading", "shield-half", "on_surface_variant", tr("state.loading"), tr("msg.loading"))
  elseif kind == "missing" then
    body = messageView("missing", "shield-x", "error", tr("msg.missing_title"), tr("msg.missing_body"),
                       "yay -S piavpn-bin", { retryButton() })
  elseif kind == "offline" then
    body = messageView("offline", "shield-x", "error", tr("msg.offline_title"), tr("msg.offline_body"),
                       "sudo systemctl enable --now piavpn.service", { retryButton() })
  elseif kind == "signedout" then
    body = loginView()
  else
    loadRegions(false)
    body = mainView(status)
  end

  panel.render(ui.column({ flexGrow = 1, gap = 14, align = "stretch" }, {
    header(status),
    body,
  }))
end

noctalia.state.watch("status", function() render() end)
noctalia.state.watch("pending", function() render() end)

-- ── handlers ────────────────────────────────────────────────────────────────

function onOpen(_context)
  isOpen = true
  confirmLogout = false
  shared.requestRefresh()
  render()
end

function onClose()
  isOpen = false
  password = ""
end

function onCloseClicked()
  panel.close()
end

function onRefresh()
  errorText = ""
  shared.requestRefresh()
  if shared.kind() ~= "signedout" then loadRegions(true) end
  render()
end

function onSignIn()
  if busy ~= "" then return end
  local user = shared.trim(username)
  if user == "" or password == "" then
    fail(tr("login.missing"))
    return
  end
  local data = noctalia.pluginDataDir()
  if data == nil or data == "" then
    fail(tr("error.generic"))
    return
  end
  -- piactl only takes credentials from a file. It is created 0600 inside the
  -- plugin's private (0700) data dir, and the engine shreds it right after.
  local file = `{data}/login-{noctalia.nowMs()}.cred`
  local ok = noctalia.writeFile(file, `{user}\n{password}\n`)
  password = ""
  if not ok then
    fail(tr("error.generic"))
    return
  end
  busy = "login"
  errorText = ""
  render()
  shared.call(`login {shared.shellQuote(file)}`, function(_, err)
    if noctalia.fileExists(file) then noctalia.removeFile(file) end
    busy = ""
    if err then
      formGen += 1     -- fresh, empty password box
      fail(err)
      return
    end
    username, formGen = "", formGen + 1
    tab = "locations"
    noctalia.notify(tr("title"), tr("notify.signed_in", { user = user }))
    shared.requestRefresh()
    loadRegions(true)
    render()
  end)
end

function onSignOut()
  if busy ~= "" then return end
  busy = "logout"
  render()
  shared.call("logout", function(_, err)
    busy = ""
    confirmLogout = false
    if err then fail(err); return end
    noctalia.state.set("regions", {})
    shared.requestRefresh()
    render()
  end)
end

function onToggleConnection()
  errorText = ""
  shared.toggleConnection(function(err) fail(err) end)
  render()
end

function onSelectRegion(id)
  local status = shared.status()
  if busy ~= "" or (chosenRegion or status.region) == id and shared.kind(status) == "connected" then return end
  busy = "region"
  chosenRegion = id
  errorText = ""
  render()
  shared.call(`set-region {shared.shellQuote(id)}`, function(_, err)
    busy = ""
    if err then
      chosenRegion = nil
      fail(err)
      return
    end
    -- PIA moves a live tunnel by itself; from idle, picking a place means "go there".
    if shared.kind() == "disconnected" and noctalia.getConfig("connect_on_select") ~= false then
      shared.toggleConnection(function(e) fail(e) end)
    end
    shared.requestRefresh()
    render()
  end)
end

function onSetting(key, value)
  if busy ~= "" then return end
  busy = "setting"
  overrides[key] = value
  render()
  shared.call(`set {key} {shared.shellQuote(value)}`, function(_, err)
    busy = ""
    if err then
      overrides[key] = nil
      fail(err)
      return
    end
    shared.requestRefresh()
    render()
  end)
end
