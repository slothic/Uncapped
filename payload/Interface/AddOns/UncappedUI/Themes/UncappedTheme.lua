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
        textValue = { 1.00, 0.87, 0.42 },

        -- Section headings stay gold. In the mockup they are the only warm
        -- thing on the panel and that contrast is doing real work -- everything
        -- violet reads as chrome, everything gold reads as a heading.
        gold = { 1.00, 0.82, 0.30 },

        -- Window chrome: violet multiplied over the stock dialog art.
        -- ⚠ These are deliberately close to 1.0 on red and blue. A tint is a
        --   MULTIPLY, so a saturated violet like { 0.72, 0.34, 1.00 } does not
        --   just recolour the chrome, it darkens it by two thirds on green and
        --   the whole window goes muddy. The mockup is bright; matching it means
        --   pulling green DOWN while leaving red and blue almost untouched.
        windowTint = { 0.90, 0.42, 1.00, 1.00 },
        windowBorderTint = { 1.00, 0.70, 1.00, 1.00 },
        bannerTint = { 1.00, 0.65, 1.00 },

        -- Content panels sit a shade deeper than the window behind them.
        panelTint = { 0.80, 0.36, 1.00, 0.95 },
        -- Alpha 0: the backdrop's own SQUARE edge is switched off, because the
        -- rounded rim below is the border now. Leaving both on draws a square
        -- outline just outside a rounded one, which looks like a mistake.
        panelBorderTint = { 1, 1, 1, 0 },
        panelRimTint = { 0.62, 0.30, 0.92, 0.85 },

        buttonRim = { 0.45, 0.26, 0.62, 0.90 },
        buttonRimActive = { 1.00, 0.78, 0.30, 1.00 },
        buttonRimDisabled = { 0.30, 0.24, 0.38, 0.50 },

        -- The nebula's own base colour. The panel drops its backdrop fill to
        -- zero alpha wherever a nebula is present, so THIS is the surface.
        nebulaBase = { 0.055, 0.024, 0.094, 1.00 },

        -- ★ THE LAYER TINTS. These were missing entirely, and the consequence was
        --   not subtle: the pattern art became GREYSCALE when it was made
        --   tintable, so with no tint set it inherited Default's { 1, 1, 1 } and
        --   every cloud rendered WHITE at full strength -- a bright grey storm
        --   sitting over the whole panel instead of a deep violet nebula.
        --
        -- ⚠ Tint and alpha have to be read together. The old art had its colour
        --   BAKED IN at roughly a fifth strength, so a saturated tint at the old
        --   0.85 alpha is about three times too bright. The alphas below drop to
        --   match: peak contribution lands near the values the baked art had, and
        --   the density sliders still run the full 0-100 from there.
        nebulaTintA = { 0.62, 0.24, 0.95 },
        nebulaTintB = { 0.78, 0.30, 0.88 },
        nebulaTintStars = { 0.82, 0.80, 1.00 },

        -- Buttons. buttonBG is WHITE8x8, so buttonFill is the literal final
        -- colour; buttonBorder multiplies the grey tooltip-border art.
        buttonFill = { 0.18, 0.10, 0.26, 0.92 },
        buttonBorder = { 0.52, 0.34, 0.66, 0.00 },
        buttonText = { 0.86, 0.80, 0.94 },
        -- ★ SELECTION IS GOLD. Everything structural on this UI is violet, so
        --   violet cannot also mean "this is the one you picked" -- against a
        --   violet panel a violet highlight is just a slightly brighter panel.
        --   Gold is the only warm colour in the theme and it is reserved for
        --   exactly one job: the thing you have selected. That is the contrast
        --   the realm's own mockup had, and it is why it read instantly.
        buttonFillActive = { 0.32, 0.22, 0.04, 0.95 },
        buttonBorderActive = { 0.80, 0.42, 0.96, 0.00 },
        buttonTextActive = { 1.00, 0.91, 0.60 },
        buttonFillDisabled = { 0.10, 0.07, 0.14, 0.55 },
        buttonBorderDisabled = { 0.30, 0.24, 0.38, 0.70 },

        rowSelected = { 1.00, 0.78, 0.30, 0.22 },
        rowSelectedText = { 1.00, 0.87, 0.42 },
        rowLine = { 0.72, 0.45, 1.00, 0.10 },

        -- Ambient halo colour, and the two states that matter.
        glow = { 0.72, 0.28, 1.00 },
        glowActive = { 1.00, 0.72, 0.22 },   -- selected: gold
        glowHover = { 0.72, 0.32, 1.00 },    -- under the cursor: violet

        -- Unticked reads as chrome; ticked is gold, the same signal a selected
        -- button gives.
        checkBoxTint = { 0.58, 0.38, 0.76 },
        checkBoxTintChecked = { 1.00, 0.78, 0.30 },
        checkBoxTintPushed = { 0.75, 0.50, 0.92 },
        checkBoxTintHighlight = { 0.85, 0.60, 1.00 },
        checkMarkTint = { 1.00, 0.80, 0.32 },
        checkMarkTintDisabled = { 0.42, 0.36, 0.50 },
        closeGlyphTint = { 0.70, 0.48, 0.88 },
        closeGlyphTintHover = { 1.00, 0.78, 0.30 },
        scrollThumbTint = { 0.60, 0.34, 0.84 },
        scrollTrackTint = { 0.30, 0.18, 0.42 },
        editBoxTint = { 0.72, 0.50, 0.92 },
        editBoxIconTint = { 0.78, 0.58, 0.95 },
    },
    textures = {
        -- ★ The stock checkbox was the loudest clash left on the panel: Blizzard's
        --   blue-and-gold tick on a violet surface. These replace it outright.
        checkBox = "Interface\\AddOns\\UncappedUI\\Assets\\Frames\\CheckBox",
        checkBoxPushed = "Interface\\AddOns\\UncappedUI\\Assets\\Frames\\CheckBox",
        checkBoxHighlight = "Interface\\AddOns\\UncappedUI\\Assets\\Frames\\CheckBox",
        checkMark = "Interface\\AddOns\\UncappedUI\\Assets\\Frames\\CheckMark",
        closeGlyph = "Interface\\AddOns\\UncappedUI\\Assets\\Frames\\CloseX",
        scrollThumb = "Interface\\AddOns\\UncappedUI\\Assets\\Frames\\ScrollThumb",
        scrollTrack = "Interface\\AddOns\\UncappedUI\\Assets\\Frames\\ScrollTrack",
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

        panelCorner = 14,
        panelVignetteAlpha = 0.55,
        buttonCorner = 11,
        buttonGlossAlpha = 0.30,
        buttonGlossHeight = 0.55,

        -- ★ THE NEBULA. Three layers at different speeds and opposing directions;
        --   the parallax between them is what reads as depth. A single scrolling
        --   layer just looks like moving wallpaper.
        --
        -- ⚠ Keep these alphas low. This sits BEHIND body text, and the brief it
        --   has to satisfy is "obviously alive" and "still perfectly readable" at
        --   the same time. If it ever fights the text, drop the alphas before
        --   touching anything else -- and drop nebulaAlphaB first, it is the
        --   highest-frequency layer and the one that costs legibility fastest.
        nebulaAlphaA = 0.34,
        nebulaAlphaB = 0.26,
        nebulaAlphaStars = 0.75,
        nebulaSpeedA = 0.0060,
        nebulaSpeedB = 0.0105,
        nebulaSpeedStars = 0.0016,
        nebulaTwinklePeriod = 5.5,
        -- Window width in texture coords. 0.5 is the natural size of the tile;
        -- smaller zooms in, making the clouds bigger and thicker.
        nebulaScaleA = 0.42,
        nebulaScaleB = 0.30,
        nebulaScaleStars = 0.5,

        -- Our tick is drawn to sit inside its box, unlike Blizzard's which
        -- deliberately overhangs, so it needs pulling in off the rim.
        checkMarkInset = 5,
    },
})
