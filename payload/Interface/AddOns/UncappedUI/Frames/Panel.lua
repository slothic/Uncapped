-- UncappedUIKit Frames.Panel -- a themed sub-panel: the bordered boxes used for
-- sidebars, detail panes and info panes.
--
-- A panel is built in up to five layers, and a theme decides which exist:
--
--   nebula   (BACKGROUND -4..-1)  scrolling starfield, opt-in per panel
--   backdrop (BACKGROUND 0 / BORDER 0)  the classic tiled fill + edge
--   vignette (BORDER -2)          darkening that hugs the inside of the rim
--   rim      (BORDER 1)           the crisp rounded outline
--   contents (ARTWORK / OVERLAY)  whatever the caller puts in
--
-- ★ Under the stock "Default" theme only the backdrop exists -- the rim and
--   vignette have no texture, the nebula has zero alpha, and each of those
--   collapses to a handful of permanently hidden textures. The old look is
--   unchanged and costs nothing extra.

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

-- Whether THIS theme lights the nebula up at all. Derived from the theme rather
-- than read off the nebula's own cached flag on purpose: ApplyAll() walks its
-- widget table in arbitrary order, so on a live /uitheme switch the panel can be
-- re-skinned BEFORE the nebula is, and would then paint an opaque fill over a
-- starfield that is about to turn on.
local function ThemeLightsNebula(theme)
    local m = theme.metrics or {}
    return (m.nebulaAlphaA or 0) > 0 or (m.nebulaAlphaB or 0) > 0 or (m.nebulaAlphaStars or 0) > 0
end

local function ApplyPanelSkin(panel, theme)
    local c, m, t = theme.colors, theme.metrics, theme.textures
    local bgKey = panel.light and "panelBGLight" or "panelBG"

    panel:SetBackdrop({
        bgFile = t[bgKey] or t.panelBG,
        edgeFile = t.panelEdge,
        tile = true, tileSize = 16, edgeSize = m.panelEdgeSize,
        insets = m.panelInsets,
    })

    local tint = c.panelTint or { 1, 1, 1, 1 }
    local alpha = tint[4] or 1

    -- ⚠ A panel showing a nebula must not paint an opaque fill on top of it.
    --   The nebula owns its own base colour (colors.nebulaBase), so the backdrop
    --   fill drops out entirely rather than being layered under it.
    if panel.nebula and ThemeLightsNebula(theme) then alpha = 0 end
    panel:SetBackdropColor(tint[1], tint[2], tint[3], alpha)

    local e = c.panelBorderTint or { 1, 1, 1, 1 }
    panel:SetBackdropBorderColor(e[1], e[2], e[3], e[4] or 1)

    local corner = m.panelCorner or 12

    local rimTint = c.panelRimTint
    if t.panelRim and rimTint and (rimTint[4] or 1) > 0 then
        panel.rim:SetTexture(t.panelRim)
        panel.rim:SetVertexColor(rimTint[1], rimTint[2], rimTint[3])
        panel.rim:SetAlpha(rimTint[4] or 1)
        panel.rim:SetGeometry(0, corner)
        panel.rim:Show()
    else
        panel.rim:Hide()
    end

    local vigAlpha = m.panelVignetteAlpha or 0
    if t.panelVignette and vigAlpha > 0 then
        panel.vignette:SetTexture(t.panelVignette)
        panel.vignette:SetVertexColor(1, 1, 1)
        panel.vignette:SetAlpha(vigAlpha)
        panel.vignette:SetGeometry(0, corner)
        panel.vignette:Show()
    else
        panel.vignette:Hide()
    end
end

-- opts.light:  use the light marble background instead of the dark one.
-- opts.nebula: give this panel a scrolling starfield background.
--              ⚠ Panels only -- never an always-on HUD. See Effects\Nebula.lua.
function UncappedUIKit.CreatePanel(parent, opts)
    local panel = CreateFrame("Frame", nil, parent)
    panel.light = opts and opts.light or false

    if opts and opts.nebula and UncappedUIKit.AttachNebula then
        panel.nebula = UncappedUIKit.AttachNebula(panel)
    end

    panel.vignette = UncappedUIKit.CreateNineSlice(panel, { layer = "BORDER", sublayer = -2 })
    panel.rim = UncappedUIKit.CreateNineSlice(panel, { layer = "BORDER", sublayer = 1 })

    function panel:SetLight(light)
        self.light = light and true or false
        ApplyPanelSkin(self, UncappedUIKit.GetActiveTheme())
    end

    UncappedUIKit.Register(panel, ApplyPanelSkin)
    return panel
end
