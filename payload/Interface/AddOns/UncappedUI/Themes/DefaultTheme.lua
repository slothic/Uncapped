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
        textValue = { 1.00, 1.00, 0.00 },
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
        -- Per-state halo colours. Omitted by a theme, both fall back to `glow`.
        glowActive = { 0.68, 0.28, 1.00 },
        glowHover = { 0.68, 0.28, 1.00 },
        checkBoxTint = { 1, 1, 1 },
        checkBoxTintChecked = { 1, 1, 1 },
        checkBoxTintPushed = { 1, 1, 1 },
        checkBoxTintHighlight = { 1, 1, 1 },
        checkMarkTint = { 1, 1, 1 },
        checkMarkTintDisabled = { 0.5, 0.5, 0.5 },
        closeGlyphTint = { 1, 1, 1 },
        closeGlyphTintHover = { 1, 1, 1 },
        scrollThumbTint = { 1, 1, 1 },
        scrollTrackTint = { 1, 1, 1 },
        editBoxTint = { 1, 1, 1 },
        editBoxIconTint = { 1, 1, 1 },

        -- Decorative layers, all alpha 0 = off. A theme turns one on simply by
        -- giving it a non-zero alpha; nothing else has to change.
        panelRimTint = { 1, 1, 1, 0 },
        buttonRim = { 1, 1, 1, 0 },
        buttonRimActive = { 1, 1, 1, 0 },
        buttonRimDisabled = { 1, 1, 1, 0 },
        nebulaBase = { 0, 0, 0, 0 },
        nebulaTintA = { 1, 1, 1 },
        nebulaTintB = { 1, 1, 1 },
        nebulaTintStars = { 1, 1, 1 },
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
        searchIcon = "Interface\\Common\\UI-Searchbox-Icon",
        resizeGripUp = "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up",
        resizeGripHighlight = "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight",
        resizeGripDown = "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down",
        glow = "Interface\\AddOns\\UncappedUI\\Assets\\Frames\\Glow",
        -- Decorative art. Present here so the keys are discoverable, but every
        -- one is switched off below by a zero alpha/metric, so "Default" draws
        -- none of them and stays stock.
        panelRim = "Interface\\AddOns\\UncappedUI\\Assets\\Frames\\PanelRim",
        panelVignette = "Interface\\AddOns\\UncappedUI\\Assets\\Frames\\PanelVignette",
        buttonRim = "Interface\\AddOns\\UncappedUI\\Assets\\Frames\\PanelRim",
        gloss = "Interface\\AddOns\\UncappedUI\\Assets\\Frames\\Gloss",
        nebulaA = "Interface\\AddOns\\UncappedUI\\Assets\\Patterns\\Cloud01",
        nebulaB = "Interface\\AddOns\\UncappedUI\\Assets\\Patterns\\Cloud11",
        -- ⚠ A STARFIELD, not a cloud tile. This pointed at Cloud18 for a while
        --   after the hand-authored Stars.tga was superseded by the pattern
        --   library, which meant the star layer was quietly a third cloud and
        --   the panel had no stars in it at all.
        nebulaStars = "Interface\\AddOns\\UncappedUI\\Assets\\Patterns\\Star02",
        -- Stock checkbox/close/scrollbar art. Named here so "Default" restores
        -- Blizzard's own textures through exactly the same code path a custom
        -- theme uses, rather than the widgets special-casing an absent key.
        checkBox = "Interface\\Buttons\\UI-CheckBox-Up",
        checkBoxPushed = "Interface\\Buttons\\UI-CheckBox-Down",
        checkBoxHighlight = "Interface\\Buttons\\UI-CheckBox-Highlight",
        checkMark = "Interface\\Buttons\\UI-CheckBox-Check",
        closeGlyph = nil,      -- nil = keep UIPanelCloseButton's own art
        scrollThumb = nil,
        scrollTrack = nil,
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

        panelCorner = 12,
        panelVignetteAlpha = 0,
        buttonCorner = 10,
        buttonGlossAlpha = 0,
        buttonGlossHeight = 0.5,

        -- ★ Nebula. All three alphas at 0 means Effects\Nebula.lua never enrols
        --   in its scroll driver at all, so the stock theme costs zero per-frame
        --   work -- not "a cheap OnUpdate", none.
        nebulaAlphaA = 0,
        nebulaAlphaB = 0,
        nebulaAlphaStars = 0,
        nebulaSpeedA = 0.0060,
        nebulaSpeedB = 0.0105,
        nebulaSpeedStars = 0.0016,
        nebulaTwinklePeriod = 0,
        nebulaScaleA = 0.5,
        nebulaScaleB = 0.5,
        nebulaScaleStars = 0.5,
        checkMarkInset = 0,
    },
})
