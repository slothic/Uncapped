-- UncappedUIKit Controls.Checkbox -- UICheckButtonTemplate with a themed box,
-- tick and label.
--
-- ★ THIS FILE USED TO SAY BLIZZARD'S CHECKBOX "ISN'T PRACTICALLY RE-SKINNABLE
--   IN 3.3.5a WITHOUT A FULL CUSTOM TEMPLATE". That was wrong, and it left the
--   single most obvious clash on the whole panel: a stock blue-and-gold tick
--   sitting on a violet surface. A CheckButton exposes SetNormalTexture,
--   SetPushedTexture, SetHighlightTexture, SetCheckedTexture and
--   SetDisabledCheckedTexture per INSTANCE -- the template only supplies the
--   defaults, and every one of them can be replaced after the fact.
--
-- ★ A TICKED BOX IS GOLD. Ticked means "this one is on", which is the same
--   idea as a selected button, and the theme reserves gold for exactly that.
--
-- The stock texture paths live in DefaultTheme, so the "Default" theme restores
-- Blizzard's own art through the same code path rather than special-casing.

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

local unpack = unpack

local function Paint(getTex, setTex, path, colour)
    if not path then return end
    setTex(path)
    local t = getTex()
    if t and colour then t:SetVertexColor(colour[1], colour[2], colour[3]) end
    if t and colour and colour[4] then t:SetAlpha(colour[4]) end
    return t
end

-- ★ The BOX follows the tick's colour, not just the tick. A gold tick inside a
--   violet box reads as two unrelated things; the whole control going gold reads
--   as one control that is switched on. Re-run on every click, because the
--   normal texture is not state-aware the way the checked texture is.
local function TintBox(cb, theme)
    local n = cb:GetNormalTexture()
    if not n then return end
    local c = theme.colors
    local col = (cb:GetChecked() and c.checkBoxTintChecked) or c.checkBoxTint
    if col then n:SetVertexColor(col[1], col[2], col[3]) end
end

local function ApplyCheckboxSkin(cb, theme)
    local t, c = theme.textures, theme.colors

    Paint(function() return cb:GetNormalTexture() end,
          function(p) cb:SetNormalTexture(p) end,
          t.checkBox, c.checkBoxTint)

    Paint(function() return cb:GetPushedTexture() end,
          function(p) cb:SetPushedTexture(p) end,
          t.checkBoxPushed or t.checkBox, c.checkBoxTintPushed or c.checkBoxTint)

    Paint(function() return cb:GetHighlightTexture() end,
          function(p) cb:SetHighlightTexture(p) end,
          t.checkBoxHighlight or t.checkBox, c.checkBoxTintHighlight)

    Paint(function() return cb:GetCheckedTexture() end,
          function(p) cb:SetCheckedTexture(p) end,
          t.checkMark, c.checkMarkTint)

    Paint(function() return cb:GetDisabledCheckedTexture() end,
          function(p) cb:SetDisabledCheckedTexture(p) end,
          t.checkMark, c.checkMarkTintDisabled)

    TintBox(cb, theme)

    -- ⚠ The box and the tick are separate textures at the same size, so a tick
    --   authored to sit INSIDE its box must not be drawn at the box's full
    --   extent or it touches the rim. Blizzard's own art overhangs deliberately;
    --   ours does not, hence the inset.
    local inset = (theme.metrics and theme.metrics.checkMarkInset) or 0
    local chk = cb:GetCheckedTexture()
    if chk and inset > 0 then
        chk:ClearAllPoints()
        chk:SetPoint("TOPLEFT", cb, "TOPLEFT", inset, -inset)
        chk:SetPoint("BOTTOMRIGHT", cb, "BOTTOMRIGHT", -inset, inset)
    end
end

--[[
    `get`/`set` are optional and mirror CreateDropdown's shape. Added 2026-08-16
    during a UI audit: the kit's dropdown bound to a value and its checkbox did
    not, so every caller hand-wrote the same three lines (initial SetChecked, an
    OnClick that writes through, and a refresh that re-reads). That asymmetry is
    part of why 9 checkbox sites skipped the kit.

    With a binding, `cb:Refresh()` re-reads the source of truth -- which is what
    a panel wants after any external change, and what the hand-written versions
    consistently forgot.

    ⚠ `name` is accepted because UICheckButtonTemplate derives `<name>Text` from
      it. Callers that never touch that global should pass nil.
]]
function UncappedUIKit.CreateCheckbox(parent, label, get, set, name)
    local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    cb.text = UncappedUIKit.CreateText(cb, "highlightSmall", "LEFT", cb, "RIGHT", 4, 0, label or "")

    if get then
        cb:SetChecked(get() and true or false)
        function cb:Refresh()
            self:SetChecked(get() and true or false)
        end
    end

    if set then
        cb:SetScript("OnClick", function(self)
            set(self:GetChecked() and true or false)
        end)
    end

    -- Keep the box colour in step with the tick however the state changes:
    -- a click, or a caller writing the value straight through SetChecked.
    local baseSetChecked = cb.SetChecked
    function cb:SetChecked(v)
        baseSetChecked(self, v)
        TintBox(self, UncappedUIKit.GetActiveTheme())
    end
    cb:HookScript("OnClick", function(self)
        TintBox(self, UncappedUIKit.GetActiveTheme())
    end)

    UncappedUIKit.Register(cb, ApplyCheckboxSkin)
    return cb
end
