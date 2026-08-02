-- UncappedUIKit Controls.Checkbox -- wraps the stock UICheckButtonTemplate
-- with a themed label. Same caveat as Dropdown.lua: Blizzard's checkbox
-- textures aren't practically re-skinnable in 3.3.5a without a full
-- custom template, so this renders the same under every theme for now.

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

function UncappedUIKit.CreateCheckbox(parent, label)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb.text = UncappedUIKit.CreateText(cb, "highlightSmall", "LEFT", cb, "RIGHT", 4, 0, label or "")
    return cb
end
