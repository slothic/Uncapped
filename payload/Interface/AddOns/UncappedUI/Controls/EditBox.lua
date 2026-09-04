-- UncappedUIKit Controls.EditBox -- themed search box (InputBoxTemplate +
-- placeholder text + magnifying-glass icon). Wire up filtering by setting
-- box.OnQueryChanged = function(text) ... end after creation.
--
-- ⚠ OnQueryChanged is DEBOUNCED (0.25s after the last keystroke), so it is not
-- called once per character. Clearing the box still fires immediately.

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

-- ★ InputBoxTemplate draws its own gold-brown chrome as three textures
--   (left/middle/right). On a violet panel that gold is the wrong temperature
--   and it is the last stock-looking thing on a search field.
--
-- ⚠ Those textures are reached by walking GetRegions(), NOT by global name.
--   Every edit box in this kit is created with a nil name, so the usual
--   "<name>Left"/"<name>Middle"/"<name>Right" globals do not exist for them --
--   which is exactly why this was never skinned before.
--
--   Textures the KIT itself adds (the magnifier) are tagged and skipped, or the
--   chrome tint would repaint them too.
local function TintInputChrome(box, theme)
    local tint = theme.colors and theme.colors.editBoxTint
    if not tint then return end
    local n = select("#", box:GetRegions())
    for i = 1, n do
        local r = select(i, box:GetRegions())
        if r and r.GetObjectType and r:GetObjectType() == "Texture" and not r.uncappedOwned then
            r:SetVertexColor(tint[1], tint[2], tint[3])
        end
    end
end

local function ApplySearchSkin(box, theme)
    box.icon:SetTexture(theme.textures.searchIcon)
    local ic = theme.colors and theme.colors.editBoxIconTint
    if ic then box.icon:SetVertexColor(ic[1], ic[2], ic[3]) end
    TintInputChrome(box, theme)
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
    box.icon.uncappedOwned = true   -- excluded from the chrome tint above
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

    -- This control was never registered with the theme at all, so it kept
    -- Blizzard's gold chrome under every theme while the search box next to it
    -- changed. Same widget, two different looks, on the same panel.
    UncappedUIKit.Register(box, TintInputChrome)

    return box
end
