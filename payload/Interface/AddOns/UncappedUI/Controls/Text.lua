-- UncappedUI Controls.Text -- theme-aware font string helper.

local UncappedUI = _G.UncappedUI
if not UncappedUI then return end

local function ApplyTextSkin(fs, theme)
    local template = (theme.fonts and theme.fonts[fs.styleKey]) or "GameFontHighlightSmall"
    fs:SetFontObject(template)
end

-- styleKey indexes theme.fonts (see DefaultTheme.lua): "title", "normal",
-- "normalSmall", "highlight", "highlightSmall", "disableSmall".
function UncappedUI.CreateText(parent, styleKey, point, rel, relPoint, x, y, text)
    local theme = UncappedUI.GetActiveTheme()
    local template = (theme.fonts and theme.fonts[styleKey]) or "GameFontHighlightSmall"
    local fs = parent:CreateFontString(nil, "OVERLAY", template)
    fs:SetPoint(point or "CENTER", rel or parent, relPoint or point or "CENTER", x or 0, y or 0)
    fs:SetText(text or "")
    fs.styleKey = styleKey
    UncappedUI.Register(fs, ApplyTextSkin)
    return fs
end
