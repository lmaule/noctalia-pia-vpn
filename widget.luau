--!nonstrict
-- Bar widget: a shield that says whether traffic is protected.
-- Left click opens the panel, right click connects or disconnects.

local shared = require("./shared.luau")

local function render()
  local status = shared.status()
  local kind = shared.kind(status)

  barWidget.setGlyph(shared.glyphFor(kind))
  barWidget.setGlyphColor(shared.colorFor(kind), "script")

  local mode = noctalia.getConfig("label") or "none"
  local text = ""
  if not barWidget.isVertical() then
    if mode == "region" and (kind == "connected" or kind == "busy") then
      text = shared.regionShort(status.region)
    elseif mode == "ip" and kind == "connected" then
      text = shared.ipLabel(status.vpnip)
    elseif mode == "status" then
      text = shared.stateLabel(status)
    end
  end
  barWidget.setText(text)

  local rows = { { noctalia.tr("field.status"), shared.stateLabel(status) } }
  if kind == "connected" or kind == "busy" or kind == "disconnected" then
    table.insert(rows, { noctalia.tr("field.region"), shared.regionName(status.region) })
  end
  if kind == "connected" then
    table.insert(rows, { noctalia.tr("field.vpn_ip"), shared.ipLabel(status.vpnip) })
    table.insert(rows, { noctalia.tr("field.protocol"), shared.protocolName(status.protocol) })
  end
  if kind == "connected" or kind == "disconnected" then
    table.insert(rows, { noctalia.tr("hint.right_click"),
                         noctalia.tr(kind == "connected" and "action.disconnect" or "action.connect") })
  end
  barWidget.setTooltip(rows)
end

noctalia.state.watch("status", render)
noctalia.state.watch("pending", render)
render()

function onClick()
  noctalia.togglePanel(shared.PANEL_ID)
end

function onRightClick()
  shared.toggleConnection(function(err)
    noctalia.notifyError(noctalia.tr("title"), err)
  end)
end

function onConfigChanged()
  render()
end
