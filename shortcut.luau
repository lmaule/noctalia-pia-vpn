--!nonstrict
-- Control-centre tile: one press connects or disconnects.

local shared = require("./shared.luau")

local function render()
  local status = shared.status()
  local kind = shared.kind(status)
  local label = noctalia.tr("title_short")
  if kind == "connected" then
    label = shared.regionShort(status.region)
  elseif kind == "busy" then
    label = shared.stateLabel(status)
  end
  shortcut.setLabel(label)
  shortcut.setIcon("shield-check", "shield-off")
  shortcut.setActive(kind == "connected" or kind == "busy")
end

noctalia.state.watch("status", render)
noctalia.state.watch("pending", render)
render()

function onClick()
  shared.toggleConnection(function(err)
    noctalia.notifyError(noctalia.tr("title"), err)
  end)
end
