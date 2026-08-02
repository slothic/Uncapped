-- UncappedUIKit Frames.Panel -- themed backdrop sub-panel (the bordered boxes
-- used for sidebars, detail panes, info panes, etc). Backgrounds are tiled
-- (see ApplyPanelSkin) rather than stretched, so the same cloudy/patchy
-- Blizzard marble texture scales cleanly to any panel size without
-- blurring -- that's the "stretchable" background technique. Pass
-- opts.light = true for the light marble variant instead of dark.

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

local function ApplyPanelSkin(panel, theme)
    local bgKey = panel.light and "panelBGLight" or "panelBG"
    panel:SetBackdrop({
        bgFile = theme.textures[bgKey] or theme.textures.panelBG,
        edgeFile = theme.textures.panelEdge,
        tile = true, tileSize = 16, edgeSize = theme.metrics.panelEdgeSize,
        insets = theme.metrics.panelInsets,
    })
    local c = theme.colors.panelTint or { 1, 1, 1, 1 }
    panel:SetBackdropColor(c[1], c[2], c[3], c[4] or 1)
end

-- opts.light: use the light marble background instead of the dark one.
function UncappedUIKit.CreatePanel(parent, opts)
    local panel = CreateFrame("Frame", nil, parent)
    panel.light = opts and opts.light or false
    function panel:SetLight(light)
        self.light = light and true or false
        ApplyPanelSkin(self, UncappedUIKit.GetActiveTheme())
    end
    UncappedUIKit.Register(panel, ApplyPanelSkin)
    return panel
end
