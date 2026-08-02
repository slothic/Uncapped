-- UncappedUIKit Default theme -- stock WoW appearance. Every value here is a
-- real, ready-to-use Blizzard texture/font/color; this is the theme every
-- other theme falls back to for any key it doesn't override.

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

UncappedUIKit.RegisterTheme("Default", {
    colors = {
        gold = { 1.00, 0.82, 0.22 },
        blue = { 0.30, 0.62, 1.00 },
        green = { 0.32, 1.00, 0.20 },
        purple = { 0.68, 0.28, 1.00 },
        red = { 0.72, 0.10, 0.06 },
        text = { 0.85, 0.85, 0.85 },
        textMuted = { 0.62, 0.62, 0.62 },
        textDisabled = { 0.50, 0.50, 0.50 },
        -- Near-white so the marble/cloud pattern in panelBG(Light) actually
        -- shows -- a dark tint here multiplies the texture toward solid
        -- black and hides the pattern entirely.
        panelTint = { 1, 1, 1, 0.95 },
    },
    fonts = {
        title = "GameFontNormalLarge",
        normal = "GameFontNormal",
        normalSmall = "GameFontNormalSmall",
        highlight = "GameFontHighlight",
        highlightSmall = "GameFontHighlightSmall",
        disableSmall = "GameFontDisableSmall",
    },
    textures = {
        windowBG = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        windowEdge = "Interface\\DialogFrame\\UI-DialogBox-Border",
        windowBanner = "Interface\\DialogFrame\\UI-DialogBox-Header",
        panelBG = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        panelBGLight = "Interface\\DialogFrame\\UI-DialogBox-Background",
        panelEdge = "Interface\\Tooltips\\UI-Tooltip-Border",
        buttonBG = "Interface\\Buttons\\WHITE8x8",
        buttonEdge = "Interface\\Tooltips\\UI-Tooltip-Border",
        buttonHighlight = "Interface\\QuestFrame\\UI-QuestTitleHighlight",
        rowHighlight = "Interface\\QuestFrame\\UI-QuestTitleHighlight",
        searchIcon = "Interface\\Common\\UI-Searchbox-Icon",
        resizeGripUp = "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up",
        resizeGripHighlight = "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight",
        resizeGripDown = "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down",
    },
    metrics = {
        panelEdgeSize = 12,
        panelInsets = { left = 4, right = 4, top = 4, bottom = 4 },
        buttonEdgeSize = 10,
        buttonInsets = { left = 2, right = 2, top = 2, bottom = 2 },
        windowEdgeSize = 32,
        windowInsets = { left = 11, right = 12, top = 12, bottom = 11 },
    },
})
