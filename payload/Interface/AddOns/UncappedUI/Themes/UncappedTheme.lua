-- UncappedUIKit "Uncapped" theme -- the realm's own look.
--
-- ★ THE WHOLE THING IS A TINT. There is exactly one new asset in this theme
--   (Assets\Frames\Glow.tga, the halo) and not one replaced texture. Every
--   surface below is Blizzard's own stock art multiplied by a violet, which
--   is why the dialog border keeps its rope-and-gem relief and the corner
--   gem simply turns amethyst instead of going flat. Recolouring stock art
--   was the entire reason the previous attempt at this theme stalled
--   "pending custom art" -- it never needed any.
--
-- ⚠ The numbers are sampled from kirei's own mockup of the Dashboard rather
--   than invented, so this is meant to match a specific picture. If you are
--   re-tuning it, re-tune against that picture.
--
-- The one thing that is NOT a tint is the glow: see Effects\Glow.lua. The
-- selected button breathes on a 2.6s cycle, and that motion is the point --
-- the brief was "make it look alive", not "make it purple".

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

UncappedUIKit.RegisterTheme("Uncapped", {
    colors = {
        -- Body copy goes lavender-white rather than grey so it sits in the
        -- same family as the chrome instead of looking pasted on.
        text = { 0.86, 0.80, 0.94 },
        textMuted = { 0.66, 0.58, 0.76 },
        textDisabled = { 0.48, 0.42, 0.56 },

        -- Section headings stay gold. In the mockup they are the only warm
        -- thing on the panel and that contrast is doing real work -- everything
        -- violet reads as chrome, everything gold reads as a heading.
        gold = { 1.00, 0.82, 0.30 },

        -- Window chrome: violet multiplied over the stock dialog art.
        windowTint = { 0.72, 0.34, 1.00, 1.00 },
        windowBorderTint = { 0.88, 0.62, 1.00, 1.00 },
        bannerTint = { 0.85, 0.55, 1.00 },

        -- Content panels sit a shade deeper than the window behind them.
        panelTint = { 0.62, 0.28, 0.95, 0.95 },
        panelBorderTint = { 0.75, 0.42, 1.00, 1.00 },

        -- Buttons. buttonBG is WHITE8x8, so buttonFill is the literal final
        -- colour; buttonBorder multiplies the grey tooltip-border art.
        buttonFill = { 0.18, 0.10, 0.26, 0.92 },
        buttonBorder = { 0.52, 0.34, 0.66, 0.95 },
        buttonText = { 0.86, 0.80, 0.94 },
        buttonFillActive = { 0.36, 0.11, 0.50, 0.95 },
        buttonBorderActive = { 0.80, 0.42, 0.96 },
        buttonTextActive = { 1.00, 0.90, 0.74 },
        buttonFillDisabled = { 0.10, 0.07, 0.14, 0.55 },
        buttonBorderDisabled = { 0.30, 0.24, 0.38, 0.70 },

        rowSelected = { 0.70, 0.30, 1.00, 0.26 },
        rowSelectedText = { 1.00, 0.90, 0.74 },
        rowLine = { 0.72, 0.45, 1.00, 0.10 },

        glow = { 0.72, 0.28, 1.00 },
    },
    metrics = {
        -- How far the halo bleeds past the button, and how hard. glowAlpha is
        -- the peak of the pulse; glowPulseMin its trough. A period of 0 would
        -- pin it at full brightness and cost no OnUpdate at all, which is the
        -- setting to reach for if this ever reads as too busy.
        glowInset = 9,
        glowAlpha = 0.90,
        glowPulsePeriod = 2.6,
        glowPulseMin = 0.55,
    },
})
