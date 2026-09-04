-- UncappedUIKit Effects.Nebula -- a slow, layered, scrolling starfield for the
-- background of a panel. This is the "alive" that a tint alone cannot buy.
--
-- ★ HOW THE SCROLL AVOIDS THE TEXTURE-WRAP QUESTION ENTIRELY.
--   Each asset is 512x512 holding a 2x2 repeat of a 256x256 seamless tile, so
--   its content period is exactly 0.5 in texture coordinates. We show a
--   0.5-wide window and slide its origin over [0, 0.5). Every coordinate stays
--   inside [0,1], and sliding the origin off the end is invisible because the
--   image genuinely repeats there.
--
--   The obvious alternative -- let the offset run past 1.0 and rely on the
--   sampler to wrap -- was rejected on purpose. This client's Lua accepts
--   coordinates far outside [0,1] without complaint, but whether the sampler
--   WRAPS or CLAMPS is not something we could confirm, and a clamping sampler
--   smears the edge pixels into streaks instead of tiling. That failure would
--   only ever show up in game. This approach cannot fail that way.
--
-- ★ PARALLAX IS THE WHOLE EFFECT. Three layers at different speeds and
--   directions read as depth; any single scrolling layer reads as a moving
--   wallpaper. The stars drift slowest because they are meant to be furthest
--   away, and they twinkle instead of moving much.
--
-- ⚠ NEVER ATTACH THIS TO AN ALWAYS-ON HUD. StatFeed, UncappedChat, the
--   Mythic run frame, the Shards HUD and UncappedPanel are all on screen for
--   the entire play session; a permanent per-frame animation behind them is a
--   cost the player never asked for and never dismisses. This belongs on
--   panels the player deliberately opens.

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

local pairs = pairs
local sin, pi = math.sin, math.pi
local GetTime = GetTime

local TEX_A     = "Interface\\AddOns\\UncappedUI\\Assets\\Patterns\\Cloud01"
local TEX_B     = "Interface\\AddOns\\UncappedUI\\Assets\\Patterns\\Cloud11"
local TEX_STARS = "Interface\\AddOns\\UncappedUI\\Assets\\Patterns\\Cloud18"
local FILL      = "Interface\\Buttons\\WHITE8x8"

-- Content period of every layer asset, in texture coordinates. Baked into the
-- art (2x2 of a seamless tile); do not change one without the other.
local PERIOD = 0.5

local live = setmetatable({}, { __mode = "k" })
local driver
local Tick

local function Enrol(neb)
    if not neb.enabled or not neb.owner:IsVisible() then
        live[neb] = nil
        return
    end
    live[neb] = true
    if not driver then driver = CreateFrame("Frame") end
    driver:SetScript("OnUpdate", Tick)
end

Tick = function()
    local now = GetTime()
    local any = false
    for neb in pairs(live) do
        if neb.owner:IsVisible() then
            any = true
            for i = 1, #neb.layers do
                local L = neb.layers[i]
                local ox = (now * L.sx) % PERIOD
                local oy = (now * L.sy) % PERIOD
                -- ★ L.w IS THE CLOUD-SIZE DIAL. The window is w wide, so a SMALLER w
                --   shows less of the tile stretched over the same panel -- bigger,
                --   thicker-looking clouds. It costs nothing: same texture, same
                --   draw, one number.
                --
                -- ⚠ w must never exceed PERIOD. ox runs up to PERIOD, so ox+w can
                --   reach 2*PERIOD = 1.0 and not a pixel more -- past that the
                --   coordinate leaves [0,1] and we are back to relying on the
                --   sampler to wrap, which is the thing this whole design avoids.
                L.tex:SetTexCoord(ox, ox + L.w, oy, oy + L.w)
                if L.twinkle then
                    -- Slow global shimmer. Not per-star -- that would need one
                    -- texture per star -- but enough that the field is not static.
                    local k = (sin(now * (2 * pi) / L.twinkle) + 1) * 0.5
                    L.tex:SetAlpha(L.alpha * (0.72 + 0.28 * k))
                end
            end
        end
    end
    if not any then driver:SetScript("OnUpdate", nil) end
end

local function ApplyNebulaSkin(neb, theme)
    local c, m, t = theme.colors or {}, theme.metrics or {}, theme.textures or {}

    local base = c.nebulaBase or { 0, 0, 0, 0 }
    neb.fill:SetTexture(FILL)
    neb.fill:SetVertexColor(base[1], base[2], base[3])
    neb.fill:SetAlpha(base[4] or 0)

    -- Clamped, not trusted: these are player-editable, and a w above PERIOD
    -- silently pushes the texture coordinate past 1.0.
    local function clampW(v)
        v = v or PERIOD
        if v > PERIOD then return PERIOD end
        if v < 0.06 then return 0.06 end
        return v
    end

    local defs = {
        { tex = t.nebulaA or TEX_A,     tint = c.nebulaTintA or { 1, 1, 1 }, alpha = m.nebulaAlphaA or 0,
          w = clampW(m.nebulaScaleA),
          sx = (m.nebulaSpeedA or 0.0060), sy = (m.nebulaSpeedA or 0.0060) * 0.62 },
        { tex = t.nebulaB or TEX_B,     tint = c.nebulaTintB or { 1, 1, 1 }, alpha = m.nebulaAlphaB or 0,
          w = clampW(m.nebulaScaleB),
          sx = -(m.nebulaSpeedB or 0.0105), sy = (m.nebulaSpeedB or 0.0105) * 0.55 },
        { tex = t.nebulaStars or TEX_STARS, tint = c.nebulaTintStars or { 1, 1, 1 }, alpha = m.nebulaAlphaStars or 0,
          w = clampW(m.nebulaScaleStars),
          sx = (m.nebulaSpeedStars or 0.0016), sy = (m.nebulaSpeedStars or 0.0016) * 0.7,
          twinkle = m.nebulaTwinklePeriod or 0 },
    }

    local on = false
    for i = 1, #neb.layers do
        local L, d = neb.layers[i], defs[i]
        L.tex:SetTexture(d.tex)
        L.tex:SetVertexColor(d.tint[1], d.tint[2], d.tint[3])
        L.tex:SetAlpha(d.alpha)
        L.alpha, L.sx, L.sy, L.twinkle, L.w = d.alpha, d.sx, d.sy, d.twinkle, d.w
        -- Paint the new window immediately: a paused or hidden panel would
        -- otherwise keep the old scale until the driver next ticks.
        L.tex:SetTexCoord(0, d.w, 0, d.w)
        if d.alpha > 0 then L.tex:Show(); on = true else L.tex:Hide() end
    end

    -- A theme that sets no nebula alphas (i.e. stock "Default") switches the
    -- whole thing off, driver included, without any caller knowing.
    neb.enabled = on
    if (base[4] or 0) > 0 then neb.fill:Show() else neb.fill:Hide() end
    Enrol(neb)
end

-- Attaches (once) a scrolling nebula behind `frame`'s contents.
--
-- ⚠ The layers sit at BACKGROUND sublevels -4..-1, i.e. BELOW anything the
--   panel draws at ARTWORK/OVERLAY but ABOVE nothing else -- so a panel that
--   wants a nebula must not also paint an opaque backdrop background over it.
--   Frames\Panel.lua drops its backdrop fill to zero alpha when a nebula is present.
function UncappedUIKit.AttachNebula(frame)
    if not frame then return nil end
    if frame.uncappedNebula then return frame.uncappedNebula end

    local neb = { owner = frame, layers = {}, enabled = false }

    neb.fill = frame:CreateTexture(nil, "BACKGROUND")
    neb.fill:SetDrawLayer("BACKGROUND", -4)
    neb.fill:SetAllPoints(frame)

    for i = 1, 3 do
        local t = frame:CreateTexture(nil, "BACKGROUND")
        t:SetDrawLayer("BACKGROUND", -4 + i)
        t:SetBlendMode("ADD")
        t:SetAllPoints(frame)
        t:Hide()
        neb.layers[i] = { tex = t, alpha = 0, sx = 0, sy = 0 }
    end

    -- Visibility gating. A closed panel must cost nothing per frame, which is
    -- the same rule StatFeed's repaint tick and the kit's glow driver follow.
    frame:HookScript("OnShow", function() Enrol(neb) end)
    frame:HookScript("OnHide", function() live[neb] = nil end)

    frame.uncappedNebula = neb
    UncappedUIKit.Register(neb, ApplyNebulaSkin)
    return neb
end
