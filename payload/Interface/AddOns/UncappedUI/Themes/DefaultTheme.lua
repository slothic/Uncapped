-- UncappedUIKit Default theme -- stock WoW appearance. Every value here is a
-- real, ready-to-use Blizzard texture/font/color; this is the theme every
-- other theme falls back to for any key it doesn't override.
--
-- ★ A NOTE ON THE KEYS ADDED FOR THE "Uncapped" THEME (2026-09-04). Several
--   values below -- the button state colours especially -- used to be
--   hardcoded inside Controls\Button.lua, Windows\Window.lua and
--   Navigation\Sidebar.lua. A theme could swap every texture in the kit and
--   still not change the colour of a selected button, which is most of what
--   a player actually sees. They are theme keys now.
--
--   Every one of them is set here to exactly the literal it replaced, so
--   "Default" renders pixel-for-pixel as it did before. Nothing about the
--   stock look changed; it just became overridable.

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
        panelBorderTint = { 1, 1, 1, 1 },

        -- Window chrome. All neutral: before these existed CreateWindow set
        -- no backdrop colour at all, which is the same as multiplying by white.
        windowTint = { 1, 1, 1, 1 },
        windowBorderTint = { 1, 1, 1, 1 },
        bannerTint = { 1, 1, 1 },

        -- Button states, lifted verbatim out of Controls\Button.lua.
        buttonFill = { 0.05, 0.05, 0.05, 0.88 },
        buttonBorder = { 0.30, 0.27, 0.20, 0.95 },
        buttonText = { 0.85, 0.85, 0.85 },
        buttonFillActive = { 0.25, 0.18, 0.02, 0.92 },
        buttonBorderActive = { 1.00, 0.82, 0.22 },
        buttonTextActive = { 1.00, 0.82, 0.22 },
        buttonFillDisabled = { 0.05, 0.05, 0.05, 0.55 },
        buttonBorderDisabled = { 0.20, 0.18, 0.15, 0.70 },

        -- Selected row in a sidebar list, lifted out of Navigation\Sidebar.lua
        -- (which drew gold at 0.18 alpha and coloured the label gold).
        rowSelected = { 1.00, 0.82, 0.22, 0.18 },
        rowSelectedText = { 1.00, 0.82, 0.22 },
        rowLine = { 1, 1, 1, 0.06 },

        -- Tint applied to the halo in Effects\Glow.lua. Irrelevant while
        -- metrics.glowAlpha is 0, but kept real so a theme that only turns the
        -- glow on still gets a sane colour.
        glow = { 0.68, 0.28, 1.00 },
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
        glow = "Interface\\AddOns\\UncappedUI\\Assets\\Frames\\Glow",
    },
    metrics = {
        panelEdgeSize = 12,
        panelInsets = { left = 4, right = 4, top = 4, bottom = 4 },
        buttonEdgeSize = 10,
        buttonInsets = { left = 2, right = 2, top = 2, bottom = 2 },
        windowEdgeSize = 32,
        windowInsets = { left = 11, right = 12, top = 12, bottom = 11 },

        -- ★ glowAlpha 0 switches the effect off entirely, which is what keeps
        --   "Default" stock. Effects\Glow.lua treats a zero peak as "no glow"
        --   and never even enrols the widget in the pulse driver, so the stock
        --   theme costs exactly one hidden texture per glow-capable widget and
        --   zero OnUpdate time.
        glowInset = 6,
        glowAlpha = 0,
        glowPulsePeriod = 0,
        glowPulseMin = 0.5,
    },
})
