-- UncappedLootFeed_Filters -- the filter bar, in the Vault's idiom, built once
-- and used by both views.
--
-- ⚠ UIKit is resolved HERE, at file scope, not inside the builder. It used to be
--   a local declared partway down and was then used ABOVE that line by a later
--   edit -- which silently reads the nil GLOBAL of the same name rather than the
--   local, and errors at call time. Keep it at the top.
local UIKit = _G.UncappedUIKit
--
-- WHY IT LOOKS LIKE THE VAULT'S
--   Asked for directly ("use same style of filters as the vault"), and it is the
--   right call anyway: the Vault, the wardrobe and this feed are three windows
--   over the same loot, and a player who has learned one dropdown has learned
--   all three. What replaced the old chip row is exactly the Vault's furniture --
--   a labelled UIDropDownMenuTemplate per axis, a UICheckButtonTemplate for the
--   one boolean, and a plain button for the escape hatch.
--
-- ⚠ EVERYTHING DEFAULTS TO SHOWING EVERYTHING, and that is a rule, not a
--   default anyone may quietly tune. "Show all loot as default, then players can
--   filter out" -- so every control here starts in its widest position, and
--   nothing in this file may ever ship a narrower one. A feed that hides
--   something the player did not ask to hide is indistinguishable from the bug
--   that #214 was reported as.
--
-- SOURCES IS A MULTI-CHECK, NOT A PICK-ONE
--   Bags / Vault / Others are three independent yes-no answers, and collapsing
--   them into one "pick a source" dropdown would have made "everything except
--   other players" unexpressible -- which is the single most likely thing anyone
--   wants to turn off. So it is a checkbox menu (keepShownOnClick), and the
--   closed button summarises the state.

local LF = _G.UncappedLootFeed
if not LF then return end

local Filters = {}
LF.Filters = Filters

local uid = 0
local function NextName(prefix)
    uid = uid + 1
    return "UncappedLootFeedFilter" .. prefix .. uid
end

-- Lit = INCLUDED, everywhere. The inverse reads the same on screen and means
-- the opposite, which is the ambiguity that makes a filter feel broken.
local SOURCES = {
    { key = "showBags",   label = "Bags",          short = "Bags" },
    { key = "showVault",  label = "Vault",         short = "Vault" },
    { key = "showOthers", label = "Other players", short = "Others" },
}

-- A floor rather than a set: "Rare+" is what someone filtering a loot feed
-- means, where the Vault's exact-quality picker suits a storage list.
local QUALITY = {
    { value = 0, text = "Any quality" },
    { value = 2, text = "Uncommon or better" },
    { value = 3, text = "Rare or better" },
    { value = 4, text = "Epic or better" },
    { value = 5, text = "Legendary" },
}

local function QualityText()
    for _, q in ipairs(QUALITY) do
        if q.value == (LF.GetFilter("minQuality") or 0) then return q.text end
    end
    return QUALITY[1].text
end

local function SourceText()
    local on = {}
    for _, s in ipairs(SOURCES) do
        if LF.GetFilter(s.key) ~= false then on[#on + 1] = s.short end
    end
    if #on == #SOURCES then return "All sources" end
    if #on == 0 then return "|cffff8080Nothing shown|r" end
    return table.concat(on, " + ")
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
-- TWO ROWS, ALWAYS -- dropdowns above, the checkbox and the escape hatch below.
--
-- One row would fit the Dashboard tab and overflow the pop-out window, which is
-- 360px wide by design. Sizing it per caller means two layouts to keep working
-- at every window width, and the failure mode is a "Show all" button sitting on
-- top of a label. Two rows fit everything down to the window's minimum width
-- and cost 26 pixels in the one place that has plenty.
Filters.HEIGHT = 66

-- opts:
--   x, y        offsets from parent's TOPLEFT for the first control
--   onChange    called after any change, so the caller can repaint and reset
--               its scroll offset (a shorter list at the old offset paints
--               empty, which looks exactly like the filter having eaten
--               everything)
--   width       sources dropdown width, default 92 (quality gets +20: its
--               captions are the longest text on the bar)
function Filters.Build(parent, opts)
    opts = opts or {}
    local x = opts.x or 10
    local y = opts.y or -6
    local ddWidth = opts.width or 92
    local onChange = opts.onChange or function() end
    -- 34, not 26: UIDropDownMenuTemplate draws a good deal taller than the
    -- 22px box it looks like, and a tighter gap puts the checkbox under the
    -- dropdown's own chrome where it cannot be clicked.
    local ROW2 = y - 34

    local bar = CreateFrame("Frame", nil, parent)
    bar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    bar:SetHeight(Filters.HEIGHT)

    local self = { frame = bar }

    -- ---- sources (multi-check) -------------------------------------------
    -- UIDropDownMenuTemplate carries ~16px of invisible left chrome, so its
    -- anchor is pulled back to make the visible box line up with everything
    -- else on the row. Same correction the Vault applies.
    local sourceDD = CreateFrame("Frame", NextName("Source"), bar, "UIDropDownMenuTemplate")
    sourceDD:SetPoint("TOPLEFT", bar, "TOPLEFT", x - 16, y)
    UIDropDownMenu_SetWidth(sourceDD, ddWidth)
    UIDropDownMenu_Initialize(sourceDD, function()
        for _, spec in ipairs(SOURCES) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = spec.label
            info.isNotRadio = true
            info.keepShownOnClick = 1
            info.checked = LF.GetFilter(spec.key) ~= false
            --[[ The client has ALREADY flipped the tick by the time this runs
                 (UIDropDownMenuButton_OnClick handles keepShownOnClick itself)
                 and hands the new state in as the fourth argument. Toggling the
                 saved value here instead would fight it: the menu would show one
                 thing and the feed would do the other. ]]
            info.func = function(_, _, _, checked)
                LF.SetFilter(spec.key, checked and true or false)
                UIDropDownMenu_SetText(sourceDD, SourceText())
                onChange()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetText(sourceDD, SourceText())

    -- ---- quality floor ----------------------------------------------------
    local qualityDD = CreateFrame("Frame", NextName("Quality"), bar, "UIDropDownMenuTemplate")
    qualityDD:SetPoint("LEFT", sourceDD, "RIGHT", 4, 0)
    UIDropDownMenu_SetWidth(qualityDD, ddWidth + 20)
    UIDropDownMenu_Initialize(qualityDD, function()
        for _, q in ipairs(QUALITY) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = q.text
            info.value = q.value
            info.checked = (LF.GetFilter("minQuality") or 0) == q.value
            info.func = function()
                LF.SetFilter("minQuality", q.value)
                UIDropDownMenu_SetSelectedValue(qualityDD, q.value)
                UIDropDownMenu_SetText(qualityDD, q.text)
                onChange()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetSelectedValue(qualityDD, LF.GetFilter("minQuality") or 0)
    UIDropDownMenu_SetText(qualityDD, QualityText())

    -- ---- watched only -----------------------------------------------------
    -- Kit checkbox with a get/set binding (UI audit, 2026-08-16). The kit wraps
    -- the same UICheckButtonTemplate, so SetChecked/GetChecked are unchanged --
    -- the label just comes themed instead of hand-anchored.
    local watchedCheck = UIKit.CreateCheckbox(bar, "Only watched",
        function() return LF.GetFilter("watchedOnly") end,
        function(on)
            LF.SetFilter("watchedOnly", on)
            onChange()
        end,
        NextName("Watched"))
    watchedCheck:SetWidth(22)
    watchedCheck:SetHeight(22)
    watchedCheck:SetPoint("TOPLEFT", bar, "TOPLEFT", x, ROW2)

    local function Tip(widget, title, body)
        widget:SetScript("OnEnter", function(w)
            GameTooltip:SetOwner(w, "ANCHOR_TOP")
            GameTooltip:SetText(title)
            GameTooltip:AddLine(body, 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    -- OnClick is already taken above, and SetScript would replace it -- so the
    -- tooltip goes on OnEnter/OnLeave only, which Tip does.
    Tip(watchedCheck, "Only watched",
        "Show only items on your watchlist. Everything else is still being recorded -- turn this off to see it again.")

    -- ---- escape hatch -----------------------------------------------------
    -- Present ONLY while something is narrowing the feed, so it reads as "undo
    -- what you just did" rather than as a permanent button whose effect nobody
    -- can guess.
    local reset = UIKit.CreateButton(bar, "Show all", 74, 22)
    reset:SetPoint("TOPRIGHT", bar, "TOPRIGHT", -(opts.rightPad or 12), ROW2)
    reset:SetScript("OnClick", function()
        LF.ResetFilters()
        self.Refresh()
        onChange()
    end)
    reset:Hide()

    function self.Refresh()
        UIDropDownMenu_SetText(sourceDD, SourceText())
        UIDropDownMenu_SetSelectedValue(qualityDD, LF.GetFilter("minQuality") or 0)
        UIDropDownMenu_SetText(qualityDD, QualityText())
        watchedCheck:SetChecked(LF.GetFilter("watchedOnly") and true or false)
        if LF.AnyFilterActive() then reset:Show() else reset:Hide() end
    end

    self.Refresh()
    return self
end
