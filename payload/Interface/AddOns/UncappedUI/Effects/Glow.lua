-- UncappedUIKit Effects.Glow -- the halo that makes a control feel lit.
--
-- Geometry is delegated to Effects\NineSlice.lua, so the halo is the same
-- THICKNESS IN PIXELS on all four sides of any frame, whatever its aspect.
--
-- Two intensities, because a control that only reacts when selected still feels
-- dead: the SELECTED one glows fully and breathes, and whatever the mouse is
-- over glows faintly and steadily.

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

local pairs = pairs
local sin, pi = math.sin, math.pi
local GetTime = GetTime

-- Folder name, NOT the Lua namespace: Build-Payload.ps1 copies
-- client_addons\<dir> straight to Interface\AddOns\<dir>.
local GLOW_TEXTURE = "Interface\\AddOns\\UncappedUI\\Assets\\Frames\\Glow"

local pulsing = setmetatable({}, { __mode = "k" })
local driver
-- Forward-declared: Repaint references it, and it is defined after Repaint.
-- Declaring it here keeps it a LOCAL -- written as a bare `function DriverTick()`
-- it would have become a global and been visible to every other addon.
local DriverTick

-- ★ THE HALO IS TINTED PER STATE, not once at skin time. Selection is GOLD and
--   ambient chrome is violet, so the colour -- not just the brightness -- is what
--   tells you which control you have picked. Tinting once would have forced
--   selected and hovered to share a hue and thrown that away.
local function StateOf(glow)
    if glow.active then return glow.peak, glow.tintActive end
    if glow.hover then return glow.peak * 0.42, glow.tintHover end
    return 0, nil
end

local function Repaint(glow)
    local level, tint = StateOf(glow)
    if level <= 0 then
        pulsing[glow] = nil
        glow.ns:Hide()
        return
    end
    if tint then glow.ns:SetVertexColor(tint[1], tint[2], tint[3]) end
    glow.ns:SetAlpha(level)
    glow.ns:Show()
    -- Only the SELECTED control breathes. A hover glow that also pulsed would
    -- make the whole panel twitch as the mouse crossed it.
    if glow.active and (glow.period or 0) > 0 then
        pulsing[glow] = true
        if not driver then driver = CreateFrame("Frame") end
        driver:SetScript("OnUpdate", DriverTick)
    else
        pulsing[glow] = nil
    end
end

DriverTick = function()
    local now = GetTime()
    local any = false
    for glow in pairs(pulsing) do
        -- ⚠ Skip anything whose window is closed. Without this the driver keeps
        --   recomputing alpha for every glow in every hidden panel in the suite.
        if glow.owner:IsVisible() then
            local phase = (sin(now * (2 * pi) / glow.period) + 1) * 0.5
            glow.ns:SetAlpha(glow.trough + (glow.peak - glow.trough) * phase)
        end
        any = true
    end
    if not any then driver:SetScript("OnUpdate", nil) end
end

local function ApplyGlowSkin(glow, theme)
    local c, m = theme.colors or {}, theme.metrics or {}
    local base = c.glow or { 1, 1, 1 }
    local ins = m.glowInset or 0

    -- Both fall back to the single `glow` colour, so a theme that defines only
    -- that one (the stock "Default") behaves exactly as it did before.
    glow.tintActive = c.glowActive or base
    glow.tintHover = c.glowHover or base

    glow.ns:SetTexture((theme.textures and theme.textures.glow) or GLOW_TEXTURE)
    -- Corner size tracks the inset: the halo's falloff IS its thickness.
    glow.ns:SetGeometry(ins, ins)

    glow.peak = m.glowAlpha or 0
    glow.period = m.glowPulsePeriod or 0
    glow.trough = m.glowPulseMin or 0.5
    Repaint(glow)
end

-- Attaches (once) a themed halo to `frame`. Safe to call repeatedly.
--
-- ⚠ The handle is a plain Lua table, not a frame. ThemeManager only uses a
--   registered widget as a table key and hands it back to the apply function, so
--   a table is legal there -- and it has to be one, because `frame` itself is
--   already registered with its own skin function and registering it twice would
--   silently replace that.
function UncappedUIKit.AttachGlow(frame)
    if not frame then return nil end
    if frame.uncappedGlow then return frame.uncappedGlow end

    local glow = {
        owner = frame,
        active = false,
        hover = false,
        ns = UncappedUIKit.CreateNineSlice(frame, {
            texture = GLOW_TEXTURE,
            layer = "BACKGROUND",
            sublayer = -8,
            blend = "ADD",
        }),
    }
    frame.uncappedGlow = glow
    UncappedUIKit.Register(glow, ApplyGlowSkin)
    return glow
end

function UncappedUIKit.SetGlowActive(frame, active)
    local glow = frame and frame.uncappedGlow
    if not glow then return end
    glow.active = active and true or false
    Repaint(glow)
end

-- Faint steady halo under the cursor. Ignored while the control is selected,
-- which already glows harder.
function UncappedUIKit.SetGlowHover(frame, hover)
    local glow = frame and frame.uncappedGlow
    if not glow then return end
    glow.hover = hover and true or false
    Repaint(glow)
end
