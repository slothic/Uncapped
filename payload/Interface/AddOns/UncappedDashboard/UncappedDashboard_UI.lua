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

-- Module checkboxes, kept so they can be re-read when the Dashboard tab is
-- shown. The content pane is built exactly once (BuildContent's `built` guard),
-- so a tick set at build time would otherwise never notice the player toggling
-- the same feature by its own slash command afterwards.
local moduleChecks = {}

local function RefreshModuleChecks()
    for _, cb in ipairs(moduleChecks) do
        if cb.RefreshFromModule then cb.RefreshFromModule() end
    end
end
local built = false

-- Tabs whose addon builds its own panel directly into the content group
-- (via <Addon>.UI.EmbedInto/Activate) rather than showing the slash-command
-- placeholder -- keyed by tab key -> the addon's global table name. Add an
-- entry here once an addon has been reworked to embed the same way Soul
-- Forge was (see UncappedSoulForge.lua's EmbedInto).
local EMBEDDED_TABS = {
    soulforge   = "UncappedSoulForge",
    -- ⚠ Extraction lives in the SAME FILE as Soul Forge (UncappedSoulForge.lua)
    -- but must be its own global: this table maps one tab key to one global
    -- name, and `soulforge` already claims UncappedSoulForge. See the
    -- UncappedExtraction block at the bottom of that file.
    extraction  = "UncappedExtraction",
    anima       = "UncappedAnima",
    forge       = "UncappedForge",
    vault       = "UncappedVault",
    soulscrolls = "UncappedScrolls",
    transmog    = "UncappedTransmog",
    progress    = "UncappedProgress",
    prestige    = "UncappedPrestige",
    keystone    = "UncappedKeystone",
    -- Loot Feed is a separate addon (UncappedLootFeed), not a folder under this
    -- one -- it embeds the same way regardless, since this lookup is by global
    -- name and happens at BuildContent time, long after every addon has loaded.
    lootfeed    = "UncappedLootFeed",
    appearance  = "UncappedAppearance",
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

    -- These apply for real as of 2026-08-16 -- see the note on Core.MODULES.
    -- Where a module can report its true state (mod.get), that wins over the
    -- saved preference: the window may have been closed by its own slash command
    -- since this was last ticked, and showing a stale tick is how a working
    -- control still reads as broken.
    for _, mod in ipairs(Core.MODULES) do
        local cb = UncappedUIKit.CreateCheckbox(group, mod.label)
        cb:SetPoint("TOPLEFT", group, "TOPLEFT", PAD, y)

        -- Core.GetDB() is called fresh rather than captured once: this runs long
        -- after build time, and a captured table would drift from the one OnClick
        -- writes to if GetDB ever re-resolves it.
        local function refresh()
            if mod.get then
                cb:SetChecked(mod.get() and true or false)
            else
                cb:SetChecked(Core.GetDB().modules[mod.key] ~= false)
            end
        end
        refresh()

        cb:SetScript("OnClick", function(self)
            local want = self:GetChecked() and true or false
            -- Persist first so the preference survives even when the module is
            -- momentarily unavailable (load order, addon disabled).
            Core.GetDB().modules[mod.key] = want
            if mod.set and not mod.set(want) then
                -- Could not apply it -- put the tick back rather than leave the
                -- player looking at a control that claims a state it never set.
                refresh()
            end
        end)
        cb.RefreshFromModule = refresh
        moduleChecks[#moduleChecks + 1] = cb

        -- A toggle whose reach is wider than its label says gets that spelled
        -- out next to it rather than left for the player to discover.
        if mod.note then
            local note = UncappedUIKit.CreateText(group, "disableSmall", "TOPLEFT", group, "TOPLEFT", PAD + 148, y - 4,
                mod.note)
            note:SetWidth(300)
            note:SetJustifyH("LEFT")
        end

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

    -- ★ nebula = the scrolling starfield background (Effects/Nebula.lua). This is
    --   the big surface the player actually looks at, so it is the one that gets
    --   it. The nav panel next door deliberately does NOT -- two competing
    --   parallax fields side by side read as a bug, not as depth.
    --
    --   Safe here because the Dashboard is a panel the player opens: the scroll
    --   driver is gated on OnShow/OnHide and a closed Dashboard costs nothing.
    contentPanel = UncappedUIKit.CreatePanel(window, { nebula = true })
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
    --
    -- ★ [DP-09] The GROUPS are made here; the PANELS are not.
    --
    -- An empty Frame is a handful of bytes. EmbedInto is not: eleven panels
    -- built in the one frame the Dashboard is first opened meant Transmog's
    -- 14 slot tabs, a DressUpModel and 54 grid cells of 5 textures each,
    -- Keystone's three sub-panels, and the three largest files in the bundle
    -- (Vault, Forge, SoulForge) all constructing at once -- a visible hitch
    -- on the first /dashboard of every session, paid in full by players who
    -- only ever open one tab. Each panel is now built the first time its tab
    -- is actually activated; see EnsureEmbedded.
    --
    -- Load order in the .toc is unaffected: that governs file execution, not
    -- frame building.
    for tabKey in pairs(EMBEDDED_TABS) do
        local group = CreateFrame("Frame", nil, contentPanel)
        group:SetPoint("TOPLEFT", 6, -6)
        group:SetPoint("BOTTOMRIGHT", -6, 6)
        group:Hide()
        embeddedGroups[tabKey] = group
    end

    built = true
end

-- [DP-09] Builds one embedded panel, once. The flag is set BEFORE EmbedInto
-- runs so a panel that errors half-way through construction is not retried on
-- every single click of its tab.
local embedded = {}
local function EnsureEmbedded(tabKey)
    if not tabKey or embedded[tabKey] then return end
    local group = embeddedGroups[tabKey]
    if not group then return end
    embedded[tabKey] = true
    local addon = _G[EMBEDDED_TABS[tabKey]]
    if addon and addon.UI and addon.UI.EmbedInto then
        addon.UI.EmbedInto(group)
    end
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
        RefreshModuleChecks()
        dashboardGroup:Show()
        return
    end

    -- [DP-09] First activation of this tab is what builds its panel.
    EnsureEmbedded(Core.state.tab)

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
