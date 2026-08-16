-- UncappedUIKit Controls.Checkbox -- wraps the stock UICheckButtonTemplate
-- with a themed label. Same caveat as Dropdown.lua: Blizzard's checkbox
-- textures aren't practically re-skinnable in 3.3.5a without a full
-- custom template, so this renders the same under every theme for now.

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

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

    return cb
end
