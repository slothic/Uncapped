-- UncappedUIKit Controls.EditBox -- themed search box (InputBoxTemplate +
-- placeholder text + magnifying-glass icon). Wire up filtering by setting
-- box.OnQueryChanged = function(text) ... end after creation.

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

local function ApplySearchSkin(box, theme)
    box.icon:SetTexture(theme.textures.searchIcon)
end

function UncappedUIKit.CreateSearchBox(parent, width, height, placeholderText)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetWidth(width or 200)
    box:SetHeight(height or 26)
    box:SetAutoFocus(false)
    -- InputBoxTemplate starts its text hard against the left edge, which puts
    -- the first characters typed straight on top of the magnifier below.
    box:SetTextInsets(20, 0, 0, 0)

    box.placeholder = UncappedUIKit.CreateText(box, "disableSmall", "LEFT", box, "LEFT", 24, 1, placeholderText or "")
    box.icon = box:CreateTexture(nil, "OVERLAY")
    box.icon:SetWidth(16); box.icon:SetHeight(16)
    box.icon:SetPoint("LEFT", 6, 0)

    box:SetScript("OnTextChanged", function(self)
        local text = self:GetText() or ""
        if text == "" then self.placeholder:Show() else self.placeholder:Hide() end
        if self.OnQueryChanged then self.OnQueryChanged(text) end
    end)
    box:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)

    UncappedUIKit.Register(box, ApplySearchSkin)
    return box
end
