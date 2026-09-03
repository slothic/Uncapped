-- UncappedUIKit Effects.Glow -- the "alive" layer: a soft additive halo that
-- can sit outside any frame, tinted and pulsed from the theme.
--
-- This is what separates the Uncapped look from stock WoW chrome. Everything
-- else in this kit is a flat repaint; the glow is the part that moves.
--
-- ★ THE SHAPE IS CARRIED ENTIRELY IN THE TEXTURE'S ALPHA and the RGB is pure
--   white, so a single 128x128 asset tints to any colour a theme asks for.
--   It is symmetric on both axes on purpose: it is stretched as ONE texture
--   rather than 9-sliced, which means there are no edge/corner tiles whose
--   orientation could be got wrong, and it looks identical however the client
--   decides to sample it.
--
-- ⚠ Layered at BACKGROUND/-8 so it draws BEHIND the frame's own backdrop. The
--   core of the halo therefore sits under an opaque button and only the
--   falloff escapes past the edges -- which is exactly the look, and it means
--   the glow never washes out the label sitting on top of it.

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

local pairs = pairs
local sin, pi = math.sin, math.pi
local GetTime = GetTime

-- Folder name, NOT the Lua namespace. Build-Payload.ps1 copies
-- client_addons\<dir> straight to Interface\AddOns\<dir>, so the directory
-- this file lives in is the path the client sees.
-- ⚠ The old comment in UncappedTheme.lua said "UncappedUIKit\Assets\..." --
--   that is the namespace, and no such folder has ever existed.
local GLOW_TEXTURE = "Interface\\AddOns\\UncappedUI\\Assets\\Frames\\Glow"

-- Every glow that is currently visible AND pulsing. Weak-keyed so a glow on a
-- frame that gets collected does not pin it.
local pulsing = setmetatable({}, { __mode = "k" })
local driver          -- created lazily; only exists once something pulses

local function ApplyGlowSkin(glow, theme)
    local c = theme.colors or {}
    local m = theme.metrics or {}
    local tint = c.glow or { 1, 1, 1 }
    local inset = m.glowInset or 0

    glow:SetTexture((theme.textures and theme.textures.glow) or GLOW_TEXTURE)
    glow:SetVertexColor(tint[1], tint[2], tint[3])
    glow:ClearAllPoints()
    glow:SetPoint("TOPLEFT", glow.owner, "TOPLEFT", -inset, inset)
    glow:SetPoint("BOTTOMRIGHT", glow.owner, "BOTTOMRIGHT", inset, -inset)

    -- A theme with glowAlpha 0 (the stock "Default" theme) switches the whole
    -- effect off without any caller needing to know the theme changed.
    glow.peak = m.glowAlpha or 0
    glow.period = m.glowPulsePeriod or 0
    glow.trough = m.glowPulseMin or 0.5

    UncappedUIKit.SetGlowActive(glow.owner, glow.owner.uncappedGlowOn)
end

local function DriverTick()
    local now = GetTime()
    local any = false
    for glow in pairs(pulsing) do
        any = true
        local phase = (sin(now * (2 * pi) / glow.period) + 1) * 0.5
        glow:SetAlpha(glow.trough + (glow.peak - glow.trough) * phase)
    end
    if not any then
        driver:SetScript("OnUpdate", nil)   -- nothing left to animate; stop costing frames
    end
end

-- Attaches (once) a themed halo to `frame`. Safe to call repeatedly.
function UncappedUIKit.AttachGlow(frame)
    if not frame then return nil end
    if frame.uncappedGlow then return frame.uncappedGlow end

    local glow = frame:CreateTexture(nil, "BACKGROUND")
    glow:SetDrawLayer("BACKGROUND", -8)
    glow:SetBlendMode("ADD")
    glow:SetTexture(GLOW_TEXTURE)
    glow.owner = frame
    glow:Hide()

    frame.uncappedGlow = glow
    frame.uncappedGlowOn = false

    UncappedUIKit.Register(glow, ApplyGlowSkin)
    return glow
end

-- Shows/hides the halo and enrols it in (or removes it from) the pulse driver.
function UncappedUIKit.SetGlowActive(frame, active)
    if not frame then return end
    local glow = frame.uncappedGlow
    if not glow then return end

    active = active and true or false
    frame.uncappedGlowOn = active

    -- peak 0 means "this theme has no glow" -- treat exactly like inactive.
    if not active or (glow.peak or 0) <= 0 then
        pulsing[glow] = nil
        glow:Hide()
        return
    end

    glow:SetAlpha(glow.peak)
    glow:Show()

    if (glow.period or 0) > 0 then
        pulsing[glow] = true
        if not driver then driver = CreateFrame("Frame") end
        driver:SetScript("OnUpdate", DriverTick)
    else
        pulsing[glow] = nil
    end
end
