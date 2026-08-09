-- UncappedDashboard_UI -- content panel built directly into the master
-- window from DashboardButtons.lua (Core.Buttons), anchored off the nav
-- panel so it fills whatever space the window has to the right of the
-- buttons. There's only one window for the whole Dashboard -- this file
-- just adds a plain panel to it, not a second window -- so resizing,
-- moving, and closing all just work without any cross-window syncing.
--
-- Content swaps based on the selected button: Overview + Modules for
-- Dashboard (see BuildDashboardGroup), a slash-command placeholder for
-- everything else (see the TODO below).

local Core = _G.UncappedDashboard
if not Core then return end

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff40c0ff[Dashboard]|r requires UncappedUI, which isn't loaded -- enable it in AddOns and reload.")
    end
    return
end

local UI = {}
Core.RegisterUI(UI)

local contentPanel, dashboardGroup, placeholderGroup, placeholderBody
local built = false

-- Tabs whose addon builds its own panel directly into the content group
-- (via <Addon>.UI.EmbedInto/Activate) rather than showing the slash-command
-- placeholder -- keyed by tab key -> the addon's global table name. Add an
-- entry here once an addon has been reworked to embed the same way Soul
-- Forge was (see UncappedSoulForge.lua's EmbedInto).
local EMBEDDED_TABS = {
    soulforge   = "UncappedSoulForge",
    anima       = "UncappedAnima",
    forge       = "UncappedForge",
    vault       = "UncappedVault",
    soulscrolls = "UncappedScrolls",
    transmog    = "UncappedTransmog",
    progress    = "UncappedProgress",
    -- Loot Feed is a separate addon (UncappedLootFeed), not a folder under this
    -- one -- it embeds the same way regardless, since this lookup is by global
    -- name and happens at BuildContent time, long after every addon has loaded.
    lootfeed    = "UncappedLootFeed",
}
local embeddedGroups = {}

-- Overview stat rows: label left, value right. No real data source yet --
-- TODO wire these up once something tracks totals/conversions/dungeons.
local STAT_ROWS = {
    { key = "totalStats", label = "Total Stats" },
    { key = "conversions", label = "Conversions" },
    { key = "dungeons", label = "Dungeons" },
}
local statValues = {}

-- Overview + Uncapped News + Modules, stacked in one group so they always
-- move/resize together as "the same frame".
local function BuildDashboardGroup(group)
    local PAD = 14
    local y = -10

    UncappedUIKit.CreateText(group, "title", "TOPLEFT", group, "TOPLEFT", PAD, y, "Overview")
    y = y - 30

    for _, row in ipairs(STAT_ROWS) do
        UncappedUIKit.CreateText(group, "highlightSmall", "TOPLEFT", group, "TOPLEFT", PAD, y, row.label)
        statValues[row.key] = UncappedUIKit.CreateText(group, "highlightSmall", "TOPLEFT", group, "TOPLEFT", PAD + 150, y, "--")
        y = y - 22
    end
    y = y - 14

    UncappedUIKit.CreateText(group, "title", "TOPLEFT", group, "TOPLEFT", PAD, y, "Uncapped News")
    y = y - 26
    local news = UncappedUIKit.CreateText(group, "highlightSmall", "TOPLEFT", group, "TOPLEFT", PAD, y, "No news yet -- check back soon.")
    news:SetWidth(280)
    news:SetJustifyH("LEFT")
    y = y - 36

    UncappedUIKit.CreateText(group, "title", "TOPLEFT", group, "TOPLEFT", PAD, y, "Modules")
    y = y - 30

    -- Saved on/off preference only -- nothing actually toggles yet. See
    -- Core.MODULES / db.modules in UncappedDashboard.lua.
    local db = Core.GetDB()
    for _, mod in ipairs(Core.MODULES) do
        local cb = UncappedUIKit.CreateCheckbox(group, mod.label)
        cb:SetPoint("TOPLEFT", group, "TOPLEFT", PAD, y)
        cb:SetChecked(db.modules[mod.key] ~= false)
        cb:SetScript("OnClick", function(self)
            Core.GetDB().modules[mod.key] = self:GetChecked() and true or false
        end)
        y = y - 26
    end

    -- Combat text threshold. Unlike the toggles above, this one is LIVE.
    --
    -- The value belongs to Uncapped64bitUI, which owns the floaters, and is read
    -- and written through its UncappedFCT_* API rather than its SavedVariables --
    -- so this keeps working if that addon changes how it stores things.
    --
    -- The whole section is skipped when the API is absent, which also covers load
    -- order: no hard dependency is declared, so Uncapped64bitUI may genuinely not
    -- be present. A missing row beats a broken tab.
    if UncappedFCT_GetHideUnder then
        y = y - 10
        UncappedUIKit.CreateText(group, "title", "TOPLEFT", group, "TOPLEFT", PAD, y, "Combat Text")
        y = y - 30

        local label = UncappedUIKit.CreateText(group, "highlightSmall", "TOPLEFT", group, "TOPLEFT", PAD, y - 6,
            "Hide hits under")
        label:SetWidth(110)
        label:SetJustifyH("LEFT")

        local box = UncappedUIKit.CreateValueBox(group, 90, 24, "off")
        box:SetPoint("TOPLEFT", group, "TOPLEFT", PAD + 116, y)

        local hint = UncappedUIKit.CreateText(group, "disableSmall", "TOPLEFT", group, "TOPLEFT", PAD + 214, y - 6,
            "e.g. 500m -- blank or 0 shows everything")
        hint:SetWidth(240)
        hint:SetJustifyH("LEFT")

        local function show()
            local cur = UncappedFCT_GetHideUnder()
            box:SetValue(cur > 0 and UncappedFCT_Abbrev(cur) or "")
        end
        show()

        box.OnCommit = function(text)
            -- Empty means "off", friendlier than making someone type a 0.
            if (text or ""):match("^%s*$") then text = "0" end
            if not UncappedFCT_SetHideUnder(text) then
                return false   -- rejected; CreateValueBox reverts to the last good value
            end
            show()             -- re-render through Abbrev, so "500000000" comes back as "500.00M"
            return true
        end

        y = y - 30
    end
end

local function BuildContent()
    if built then return end
    local window = Core.Buttons.GetWindow()
    local navPanel = Core.Buttons.GetNavPanel()

    contentPanel = UncappedUIKit.CreatePanel(window)
    contentPanel:SetPoint("TOPLEFT", navPanel, "TOPRIGHT", 10, 0)
    contentPanel:SetPoint("BOTTOMRIGHT", -16, 16)

    dashboardGroup = CreateFrame("Frame", nil, contentPanel)
    dashboardGroup:SetPoint("TOPLEFT", 6, -6)
    dashboardGroup:SetPoint("BOTTOMRIGHT", -6, 6)
    BuildDashboardGroup(dashboardGroup)

    placeholderGroup = CreateFrame("Frame", nil, contentPanel)
    placeholderGroup:SetPoint("TOPLEFT", 6, -6)
    placeholderGroup:SetPoint("BOTTOMRIGHT", -6, 6)
    placeholderBody = UncappedUIKit.CreateText(placeholderGroup, "highlight", "TOPLEFT", placeholderGroup, "TOPLEFT", 14, -10, "")
    placeholderBody:SetWidth(280)
    placeholderBody:SetJustifyH("LEFT")

    -- Each embedded-tab addon builds its own panel directly into its group --
    -- see UncappedSoulForge.lua's EmbedInto -- so it resizes along with the
    -- Dashboard window like everything else in contentPanel.
    for tabKey, globalName in pairs(EMBEDDED_TABS) do
        local group = CreateFrame("Frame", nil, contentPanel)
        group:SetPoint("TOPLEFT", 6, -6)
        group:SetPoint("BOTTOMRIGHT", -6, 6)
        group:Hide()
        embeddedGroups[tabKey] = group

        local addon = _G[globalName]
        if addon and addon.UI and addon.UI.EmbedInto then
            addon.UI.EmbedInto(group)
        end
    end

    built = true
end

-- TODO: once each other addon exposes an Open()/Toggle() the same way Vault
-- does (Core.UI.Open / Core.UI.Toggle), call it here instead of showing the
-- slash-command placeholder -- e.g. `_G.UncappedForge.UI.Open()`. Add it to
-- EMBEDDED_TABS above once it's been reworked to embed directly instead.
function UI.Refresh()
    if not Core.Buttons.GetWindow() then return end
    Core.Buttons.RefreshActive()

    if not Core.Buttons.IsShown() then return end

    BuildContent()

    dashboardGroup:Hide()
    placeholderGroup:Hide()
    for _, group in pairs(embeddedGroups) do group:Hide() end

    if Core.state.tab == "dashboard" then
        Core.Buttons.SetTitle("Dashboard")
        if Core.Buttons.SetMinContentWidth then Core.Buttons.SetMinContentWidth(0) end
        if Core.Buttons.SetMinContentHeight then Core.Buttons.SetMinContentHeight(0) end
        dashboardGroup:Show()
        return
    end

    local group = embeddedGroups[Core.state.tab]
    local addon = group and _G[EMBEDDED_TABS[Core.state.tab]]
    if group and addon and addon.UI and addon.UI.Activate then
        for _, tab in ipairs(Core.TABS) do
            if tab.key == Core.state.tab then Core.Buttons.SetTitle(tab.label); break end
        end
        if Core.Buttons.SetMinContentWidth then
            local minW = addon.UI.GetMinWidth and addon.UI.GetMinWidth() or 0
            Core.Buttons.SetMinContentWidth(minW)
        end
        if Core.Buttons.SetMinContentHeight then
            local minH = addon.UI.GetMinHeight and addon.UI.GetMinHeight() or 0
            Core.Buttons.SetMinContentHeight(minH)
        end
        group:Show()
        addon.UI.Activate()
        return
    end

    if Core.Buttons.SetMinContentWidth then Core.Buttons.SetMinContentWidth(0) end
    if Core.Buttons.SetMinContentHeight then Core.Buttons.SetMinContentHeight(0) end
    placeholderGroup:Show()

    for _, tab in ipairs(Core.TABS) do
        if tab.key == Core.state.tab then
            Core.Buttons.SetTitle(tab.label)
            if tab.hint then
                placeholderBody:SetText(tab.label .. " isn't wired up here yet -- for now, use |cffffd100" .. tab.hint .. "|r to open it directly.")
            else
                placeholderBody:SetText(tab.label .. " isn't available yet.")
            end
            break
        end
    end
end

function UI.IsShown()
    return Core.Buttons.IsShown()
end

function UI.Open()
    Core.Buttons.Show()
    UI.Refresh()
end

function UI.Close()
    Core.Buttons.Hide()
end

function UI.Toggle()
    if Core.Buttons.IsShown() then UI.Close() else UI.Open() end
end
