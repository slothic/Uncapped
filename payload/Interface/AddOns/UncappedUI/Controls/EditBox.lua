-- UncappedUIKit Controls.EditBox -- themed search box (InputBoxTemplate +
-- placeholder text + magnifying-glass icon). Wire up filtering by setting
-- box.OnQueryChanged = function(text) ... end after creation.
--
-- ⚠ OnQueryChanged is DEBOUNCED (0.25s after the last keystroke), so it is not
-- called once per character. Clearing the box still fires immediately.

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

local function ApplySearchSkin(box, theme)
    box.icon:SetTexture(theme.textures.searchIcon)
end

-- How long the box waits, after the last keystroke, before it runs the query.
local SEARCH_DEBOUNCE = 0.25

-- Attached to the box only while a query is pending, detached the moment it
-- fires -- no always-on OnUpdate.
local function SearchDebounceTick(self, elapsed)
    self.queryWait = (self.queryWait or 0) - elapsed
    if self.queryWait > 0 then
        return
    end
    self:SetScript("OnUpdate", nil)
    self.queryWait = nil
    if self.OnQueryChanged then
        self.OnQueryChanged(self:GetText() or "")
    end
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

    -- DEBOUNCED. OnTextChanged fires once per keystroke, and the heaviest
    -- consumers of this widget do a full linear scan per call -- LootFeed's
    -- 25,459-row item table, the wardrobe's ~4,550-row Off Hand pool -- plus a
    -- sort. Typing a ten-letter item name was ten complete scans and ten sorts,
    -- nine of whose results the player never saw. Fixing it here fixes every
    -- consumer of the widget at once.
    --
    -- ⚠ An EMPTY box is deliberately NOT debounced: clearing the field (or
    -- Escape, below) must restore the full list immediately, and that is the
    -- cheap path anyway.
    box:SetScript("OnTextChanged", function(self)
        local text = self:GetText() or ""
        if text == "" then self.placeholder:Show() else self.placeholder:Hide() end
        if not self.OnQueryChanged then return end

        if text == "" then
            self:SetScript("OnUpdate", nil)
            self.queryWait = nil
            self.OnQueryChanged("")
            return
        end

        self.queryWait = SEARCH_DEBOUNCE
        self:SetScript("OnUpdate", SearchDebounceTick)
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
