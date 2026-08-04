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

-- A plain value input, as opposed to CreateSearchBox above.
--
-- Kept separate rather than adding flags to the search box, because the two want
-- opposite behaviour in three places: no magnifier and no left inset to clear it,
-- Escape RESTORES the committed value instead of blanking the field (blanking a
-- settings box on Escape loses the setting), and it commits on Enter / focus-loss
-- rather than firing on every keystroke.
--
-- Set box.OnCommit = function(text) return accepted end. Returning false marks the
-- input rejected and reverts to the last good value, so a typo cannot be stored.
-- box:SetValue(text) refreshes the field and the remembered value together.
function UncappedUIKit.CreateValueBox(parent, width, height, placeholderText)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetWidth(width or 120)
    box:SetHeight(height or 26)
    box:SetAutoFocus(false)
    box:SetTextInsets(6, 6, 0, 0)

    box.placeholder = UncappedUIKit.CreateText(box, "disableSmall", "LEFT", box, "LEFT", 8, 1, placeholderText or "")
    box.committed = ""

    local function refreshPlaceholder(self)
        if (self:GetText() or "") == "" then self.placeholder:Show() else self.placeholder:Hide() end
    end

    function box:SetValue(text)
        self.committed = text or ""
        self:SetText(self.committed)
        refreshPlaceholder(self)
    end

    local function commit(self)
        local text = self:GetText() or ""
        if self.OnCommit and self.OnCommit(text) == false then
            -- Rejected: put the last good value back rather than leaving invalid
            -- text sitting in a box that looks saved.
            self:SetText(self.committed)
        else
            self.committed = text
        end
        refreshPlaceholder(self)
        self:ClearFocus()
    end

    box:SetScript("OnTextChanged", refreshPlaceholder)
    box:SetScript("OnEnterPressed", commit)
    box:SetScript("OnEditFocusLost", commit)
    box:SetScript("OnEscapePressed", function(self)
        self:SetText(self.committed)
        refreshPlaceholder(self)
        self:ClearFocus()
    end)

    return box
end
