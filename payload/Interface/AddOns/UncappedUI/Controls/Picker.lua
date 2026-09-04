-- UncappedUIKit Controls.Picker -- a colour swatch that opens the game's own
-- colour wheel, and a labelled slider. Both exist for the Appearance panel.
--
-- ★ THE COLOUR WHEEL IS BLIZZARD'S OWN (ColorPickerFrame). Shipping a custom
--   wheel would mean re-solving hue/saturation picking, and the stock one is
--   already familiar to every player. The wiring below is lifted from working
--   3.3.5a code (UncappedOptions.lua's Layout:Color, and Recount's EditColor,
--   which is the only on-disk code that exercises the opacity slider).
--
-- ⚠ OPACITY IS INVERTED on this client: OpacitySliderFrame returns 0 for fully
--   opaque and 1 for fully transparent. Every read and write below flips it. Get
--   this wrong and alpha runs backwards, which looks like a rendering bug rather
--   than a maths error.

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

local FILL = "Interface\\Buttons\\WHITE8x8"

-- Opens the wheel on `r,g,b` (and `a`, if the caller wants opacity) and calls
-- `callback(r, g, b, a)` live as the player drags, and again on cancel with the
-- original values.
function UncappedUIKit.ShowColorPicker(r, g, b, a, callback)
    local function apply()
        local nr, ng, nb = ColorPickerFrame:GetColorRGB()
        local na = a and (1.0 - OpacitySliderFrame:GetValue()) or nil
        callback(nr, ng, nb, na)
    end

    ColorPickerFrame.func = apply
    ColorPickerFrame.opacityFunc = a and apply or nil
    ColorPickerFrame.cancelFunc = function() callback(r, g, b, a) end
    ColorPickerFrame.hasOpacity = a and true or false
    if a then ColorPickerFrame.opacity = 1.0 - a end
    ColorPickerFrame.previousValues = { r = r, g = g, b = b, a = a }
    ColorPickerFrame:SetColorRGB(r, g, b)

    -- Hide-then-show forces a fresh OnShow, so the wheel actually moves to the
    -- colour we just set instead of keeping the last one it was opened with.
    if ColorPickerFrame:IsShown() then ColorPickerFrame:Hide() end
    ColorPickerFrame:Show()
end

-- A labelled colour chip. get() -> r,g,b[,a]; set(r,g,b[,a]) is called live
-- while the player drags, so the whole UI recolours as they choose.
--
-- opts.hasOpacity  offer the opacity slider too
-- opts.width       chip width (default 26)
function UncappedUIKit.CreateColorSwatch(parent, label, get, set, opts)
    opts = opts or {}
    local size = opts.width or 26

    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(size); b:SetHeight(size)

    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetTexture(FILL)
    b.bg:SetAllPoints(b)
    b.bg:SetVertexColor(0, 0, 0, 1)

    b.chip = b:CreateTexture(nil, "ARTWORK")
    b.chip:SetTexture(FILL)
    b.chip:SetPoint("TOPLEFT", 2, -2)
    b.chip:SetPoint("BOTTOMRIGHT", -2, 2)

    b.rim = UncappedUIKit.CreateNineSlice and
        UncappedUIKit.CreateNineSlice(b, { layer = "OVERLAY", sublayer = 1 }) or nil

    b.text = UncappedUIKit.CreateText(b, "highlightSmall", "LEFT", b, "RIGHT", 8, 0, label or "")

    function b:Refresh()
        local r, g, bl, a = get()
        self.chip:SetVertexColor(r or 1, g or 1, bl or 1)
        self.chip:SetAlpha(a or 1)
    end

    b:SetScript("OnClick", function(self)
        local r, g, bl, a = get()
        UncappedUIKit.ShowColorPicker(r, g, bl, opts.hasOpacity and (a or 1) or nil,
            function(nr, ng, nb, na)
                set(nr, ng, nb, na)
                self:Refresh()
            end)
    end)

    b:SetScript("OnEnter", function(self)
        if UncappedUIKit.SetGlowHover then UncappedUIKit.SetGlowHover(self, true) end
    end)
    b:SetScript("OnLeave", function(self)
        if UncappedUIKit.SetGlowHover then UncappedUIKit.SetGlowHover(self, false) end
    end)
    if UncappedUIKit.AttachGlow then UncappedUIKit.AttachGlow(b) end

    local function ApplySwatchSkin(sw, theme)
        local c = theme.colors
        local rimCol = c.panelRimTint
        if sw.rim and theme.textures.panelRim and rimCol and (rimCol[4] or 1) > 0 then
            sw.rim:SetTexture(theme.textures.panelRim)
            sw.rim:SetVertexColor(rimCol[1], rimCol[2], rimCol[3])
            sw.rim:SetAlpha(rimCol[4] or 1)
            sw.rim:SetGeometry(0, 8)
            sw.rim:Show()
        elseif sw.rim then
            sw.rim:Hide()
        end
        sw:Refresh()
    end
    UncappedUIKit.Register(b, ApplySwatchSkin)

    return b
end

local sliderCount = 0

-- A labelled slider. get() -> number; set(v) is called on every change.
--
-- ⚠ OptionsSliderTemplate exposes its labels as GLOBALS derived from the
--   frame's name ("<name>Low" / "<name>High" / "<name>Text"), so the slider MUST
--   be given a real name -- an anonymous one cannot be labelled at all.
--
-- ⚠ SetValue is called BEFORE OnValueChanged is attached. That ordering is the
--   guard: attaching first means the initial sync-to-saved-value fires the
--   handler and writes the value straight back, which at best is a wasted write
--   and at worst clobbers a saved setting during load.
function UncappedUIKit.CreateSlider(parent, label, minV, maxV, step, get, set, fmt)
    sliderCount = sliderCount + 1
    local name = "UncappedUIKitSlider" .. sliderCount

    local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    s:SetWidth(160)
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step)

    local low, high, caption = _G[name .. "Low"], _G[name .. "High"], _G[name .. "Text"]
    if low then low:SetText("") end
    if high then high:SetText("") end

    local function relabel(v)
        if not caption then return end
        caption:SetText(fmt and fmt(v) or (label .. "  " .. tostring(v)))
    end

    s:SetValue(get())
    relabel(get())

    s:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v / step + 0.5) * step
        set(v)
        relabel(v)
    end)

    -- Lets a "reset to defaults" button push new values in without the handler
    -- firing and writing them straight back out again.
    function s:SetValueSilently(v)
        self:SetScript("OnValueChanged", nil)
        self:SetValue(v)
        relabel(v)
        self:SetScript("OnValueChanged", function(self2, nv)
            nv = math.floor(nv / step + 0.5) * step
            set(nv)
            relabel(nv)
        end)
    end

    s.Relabel = relabel
    return s
end
