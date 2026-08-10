-- UncappedOptions -- shared settings hub for the Uncapped addon suite.
--
-- Three jobs:
--   1. Expose a global widget library `UncappedUI` so every Uncapped addon can
--      build a settings page in a couple of lines instead of hand-placing frames.
--   2. Register the parent "Uncapped" category in ESC > Interface > AddOns, so
--      every addon's page nests under one heading (child.parent = "Uncapped").
--   3. Host the "Loot & Disenchant" page, which drives the server-side
--      .autodisenchant / .auto / .aoeloot commands.
--
-- This addon loads before every addon that builds a page (they list it in
-- ## OptionalDeps), so the parent category and the widget library exist before
-- any child page is built.
--
-- It loads AFTER exactly one addon: UncappedUI, which it now lists in its own
-- ## OptionalDeps. That is not a cycle -- UncappedUI references nothing here --
-- and it is what lets the window-scale slider below read the real saved value
-- while it is being built instead of showing 1.00 until the next login.
--
-- ⚠ Two different globals are both called "UncappedUI" and they are NOT the
-- same thing. `UncappedUI` (this file) is the settings-page widget library.
-- `UncappedUIKit` (the UncappedUI addon) is the in-game window toolkit and the
-- owner of the window-scale setting.

local PARENT = "Uncapped"

-- ===========================================================================
-- Widget library (global: UncappedUI)
-- ===========================================================================
UncappedUI = UncappedUI or {}
local UI = UncappedUI

local LEFT = 16               -- left inset shared by every widget
local uid = 0                 -- unique-name counter (sliders/dropdowns need names)
local function nextName(prefix)
    uid = uid + 1
    return prefix .. uid
end

-- A top-to-bottom layout cursor over a panel. Each widget is placed at the
-- current Y and advances it. Single left column, modest widths, so nothing ever
-- spills off the panel (its real width varies from client to client).
local Layout = {}
Layout.__index = Layout

function UI.Layout(panel, startY)
    return setmetatable({ panel = panel, y = startY or -16 }, Layout)
end

function Layout:advance(h) self.y = self.y - h end
function Layout:Gap(h) self:advance(h or 10) end

function Layout:Header(text)
    local fs = self.panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fs:SetPoint("TOPLEFT", self.panel, "TOPLEFT", LEFT, self.y)
    fs:SetText("|cffffd100" .. text .. "|r")
    self:advance(24)
    return fs
end

-- Wrapping help text. Caller passes an approximate pixel height (line wrapping
-- can't be measured before layout), 28 is about two lines.
function Layout:Note(text, height)
    local fs = self.panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", self.panel, "TOPLEFT", LEFT, self.y)
    fs:SetPoint("RIGHT", self.panel, "RIGHT", -16, 0)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    self:advance((height or 28) + 4)
    return fs
end

-- Checkbox. get() -> bool, set(bool) applies + persists.
function Layout:Check(label, get, set)
    local cb = CreateFrame("CheckButton", nil, self.panel, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", self.panel, "TOPLEFT", LEFT, self.y)
    cb:SetWidth(24)
    cb:SetHeight(24)
    local fs = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    fs:SetText(label)
    cb:SetChecked(get() and true or false)
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    cb.uncappedRefresh = function() cb:SetChecked(get() and true or false) end
    self:advance(26)
    return cb
end

-- Slider. get()/set(v) on a number; snaps to step; shows the live value.
function Layout:Slider(label, minV, maxV, step, get, set, fmt)
    fmt = fmt or "%.2f"
    local name = nextName("UncappedUISlider")
    local s = CreateFrame("Slider", name, self.panel, "OptionsSliderTemplate")
    s:SetPoint("TOPLEFT", self.panel, "TOPLEFT", LEFT, self.y - 14)
    s:SetWidth(250)
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step)
    _G[name .. "Low"]:SetText(tostring(minV))
    _G[name .. "High"]:SetText(tostring(maxV))
    local caption = _G[name .. "Text"]
    local function relabel(v) caption:SetText(label .. ":  |cffffd100" .. string.format(fmt, v) .. "|r") end
    s:SetValue(get())
    relabel(get())
    s:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v / step + 0.5) * step
        set(v)
        relabel(v)
    end)
    s.uncappedRefresh = function() s:SetValue(get()); relabel(get()) end
    self:advance(48)
    return s
end

-- Colour swatch. get() -> r,g,b ; set(r,g,b) applies + persists.
function Layout:Color(label, get, set)
    local btn = CreateFrame("Button", nil, self.panel)
    btn:SetPoint("TOPLEFT", self.panel, "TOPLEFT", LEFT, self.y)
    btn:SetWidth(18)
    btn:SetHeight(18)
    local border = btn:CreateTexture(nil, "BACKGROUND")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetTexture(0, 0, 0)
    local sw = btn:CreateTexture(nil, "ARTWORK")
    sw:SetAllPoints()
    local function refresh() sw:SetTexture(get()) end
    refresh()
    local fs = btn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("LEFT", btn, "RIGHT", 6, 0)
    fs:SetText(label)
    btn:SetScript("OnClick", function()
        local r, g, b = get()
        local function apply()
            local nr, ng, nb = ColorPickerFrame:GetColorRGB()
            set(nr, ng, nb)
            refresh()
        end
        ColorPickerFrame.func = apply
        ColorPickerFrame.cancelFunc = function() set(r, g, b); refresh() end
        ColorPickerFrame.hasOpacity = false
        ColorPickerFrame.previousValues = { r, g, b }
        ColorPickerFrame:SetColorRGB(r, g, b)
        if ColorPickerFrame:IsShown() then ColorPickerFrame:Hide() end
        ColorPickerFrame:Show()
    end)
    btn.uncappedRefresh = refresh
    self:advance(26)
    return btn
end

function Layout:Button(label, onClick, width)
    local b = CreateFrame("Button", nil, self.panel, "UIPanelButtonTemplate")
    b:SetPoint("TOPLEFT", self.panel, "TOPLEFT", LEFT, self.y)
    b:SetWidth(width or 150)
    b:SetHeight(24)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    self:advance(30)
    return b
end

-- Dropdown. choices = { {value=, text=}, ... }; get()/set(value).
function Layout:Dropdown(label, choices, get, set, width)
    local header = self.panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    header:SetPoint("TOPLEFT", self.panel, "TOPLEFT", LEFT, self.y)
    header:SetText(label)
    self:advance(16)
    local dd = CreateFrame("Frame", nextName("UncappedUIDrop"), self.panel, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", self.panel, "TOPLEFT", LEFT - 16, self.y)
    local function textFor(v)
        for _, c in ipairs(choices) do if c.value == v then return c.text end end
        return tostring(v)
    end
    UIDropDownMenu_Initialize(dd, function(self, level)
        for _, c in ipairs(choices) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = c.text
            info.value = c.value
            info.func = function()
                set(c.value)
                UIDropDownMenu_SetSelectedValue(dd, c.value)
                UIDropDownMenu_SetText(dd, c.text)
            end
            info.checked = (get() == c.value)
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UIDropDownMenu_SetWidth(dd, width or 160)
    UIDropDownMenu_SetSelectedValue(dd, get())
    UIDropDownMenu_SetText(dd, textFor(get()))
    dd.uncappedRefresh = function()
        UIDropDownMenu_SetSelectedValue(dd, get())
        UIDropDownMenu_SetText(dd, textFor(get()))
    end
    self:advance(42)
    return dd
end

-- Create a page registered under the "Uncapped" parent. Returns the panel and a
-- layout cursor already positioned below the title/subtitle.
function UI.CreatePanel(displayName, subtitle)
    local panel = CreateFrame("Frame", nextName("UncappedPanel"), UIParent)
    panel.name = displayName
    if displayName ~= PARENT then panel.parent = PARENT end

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(displayName)

    local startY = -46
    if subtitle then
        local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
        sub:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
        sub:SetJustifyH("LEFT")
        sub:SetText(subtitle)
        startY = -62
    end
    InterfaceOptions_AddCategory(panel)
    return panel, UI.Layout(panel, startY)
end

-- Open the Interface options straight to a page (double call works around the
-- long-standing client quirk where the first call doesn't scroll to it).
function UI.Open(panel)
    InterfaceOptionsFrame_OpenToCategory(panel)
    InterfaceOptionsFrame_OpenToCategory(panel)
end

-- ===========================================================================
-- The parent "Uncapped" landing page.
-- ===========================================================================
local hub = UI.CreatePanel(PARENT, "Settings for the Uncapped realm's custom addons. Pick a page under this heading on the left.")

-- Window zoom lives on the LANDING page, not on a page of its own: it is the
-- one setting that applies to every Uncapped addon at once, so burying it
-- under any single addon's heading would be a lie about its reach.
--
-- The setting itself is owned by UncappedUI (UncappedScale.lua) and saved in
-- UncappedUIDB, NOT here: that addon is the one that actually applies it, so
-- it must be able to restore the zoom on login whether or not this options
-- addon is enabled. This page is only a control surface -- every accessor
-- below re-reads _G.UncappedUIKit at call time and no-ops when it is absent.
local function ScaleKit()
    local kit = _G.UncappedUIKit
    if kit and kit.GetUIScale and kit.SetUIScale then return kit end
    return nil
end

local function GetWindowScale()
    local kit = ScaleKit()
    if kit then return kit.GetUIScale() end
    return 1.0
end

local function SetWindowScale(v)
    local kit = ScaleKit()
    if kit then kit.SetUIScale(v) end
end

local scaleRefreshers = {}

do
    local L = UI.Layout(hub, -76)
    L:Header("Uncapped")
    L:Note("Everything that makes this realm 'uncapped' -- combat text, alerts, the Mythic+ HUD and rewards, hotzones, the reagent-bank helper, and loot automation -- is configured on the pages listed under this heading. Click one on the left to open it.", 72)

    L:Gap(8)
    L:Header("Window Scale")
    L:Note("Zooms every Uncapped window -- the Dashboard and all of its tabs, the Vault, Forge, Soul Forge, Transmog, Loot Feed, chat, the Mythic+ HUD and the rest. Blizzard's own frames are not affected; for those use the UI Scale slider on the Video options. Takes effect immediately and is remembered between sessions.", 56)

    local slider = L:Slider("Uncapped window scale", 0.5, 1.5, 0.05,
        GetWindowScale, SetWindowScale, "%.2f")
    scaleRefreshers[#scaleRefreshers + 1] = slider.uncappedRefresh

    L:Button("Reset to 100%", function()
        SetWindowScale(1.0)
        for _, r in ipairs(scaleRefreshers) do r() end
    end, 150)

    L:Note("|cff808080Windows keep their place when you change this -- anything that would land off the screen is pulled back on. The Dashboard's button column is the one window that stops zooming early: past a certain size its 15 buttons would not fit the screen height, so it grows only as far as it can still show all of them.|r", 44)
end

-- ===========================================================================
-- Loot & Disenchant page (drives server-side .autodisenchant / .auto / .aoeloot).
-- ===========================================================================

-- Runs a dot-command exactly as if the player had typed it into chat: the server
-- intercepts the leading "." and executes it. Works for the SEC_PLAYER commands
-- .autodisenchant / .auto / .aoeloot.
local function RunDotCommand(cmd)
    local eb = DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox
    if not eb then return end
    eb:SetText(cmd)
    ChatEdit_SendText(eb, 0)
    eb:SetText("")
end

-- Live settings table. Filled from SavedVariables at ADDON_LOADED; the global
-- then points at this table so edits persist. These mirror what we last SENT --
-- the server is the real source of truth (there's no clean way to read it back),
-- which the page's note makes clear.
local db = {
    de = { green = false, blue = false, purple = false, orange = false, ilvl = 0 },
    auto = true,
    aoeloot = false,
}

local refreshers = {}
local function refreshLoot()
    for _, r in ipairs(refreshers) do r() end
end

-- Build the .autodisenchant command from the checked qualities + ilvl cap.
local function ApplyDisenchant()
    local q = {}
    if db.de.green  then q[#q + 1] = "green"  end
    if db.de.blue   then q[#q + 1] = "blue"   end
    if db.de.purple then q[#q + 1] = "purple" end
    if db.de.orange then q[#q + 1] = "orange" end
    if #q == 0 then
        RunDotCommand(".autodisenchant off")
        DEFAULT_CHAT_FRAME:AddMessage("|cff40ff40[Uncapped]|r auto-disenchant disabled.")
        return
    end
    local cmd = ".autodisenchant " .. table.concat(q, ", ")
    if db.de.ilvl and db.de.ilvl > 0 then cmd = cmd .. " " .. db.de.ilvl end
    RunDotCommand(cmd)
    DEFAULT_CHAT_FRAME:AddMessage("|cff40ff40[Uncapped]|r sent: |cffffd100" .. cmd .. "|r")
end

do
    local panel, L = UI.CreatePanel("Loot & Disenchant",
        "Automate looting and disenchanting. These options send the matching server commands for you.")

    L:Header("Auto-Disenchant")
    L:Note("Automatically breaks looted gear of the ticked qualities into materials (sent to your reagent bank). Tick the qualities and set an optional item-level cap, then press Apply.", 40)

    local function deGet(k) return function() return db.de[k] end end
    local function deSet(k) return function(v) db.de[k] = v end end
    refreshers[#refreshers + 1] = L:Check("Disenchant |cff1eff00greens|r",  deGet("green"),  deSet("green")).uncappedRefresh
    refreshers[#refreshers + 1] = L:Check("Disenchant |cff0070ddblues|r",   deGet("blue"),   deSet("blue")).uncappedRefresh
    refreshers[#refreshers + 1] = L:Check("Disenchant |cffa335eepurples|r", deGet("purple"), deSet("purple")).uncappedRefresh
    refreshers[#refreshers + 1] = L:Check("Disenchant |cffff8000legendaries|r", deGet("orange"), deSet("orange")).uncappedRefresh
    refreshers[#refreshers + 1] = L:Slider("Item-level cap (0 = no cap)", 0, 300, 5,
        function() return db.de.ilvl end, function(v) db.de.ilvl = v end, "%d").uncappedRefresh
    L:Button("Apply auto-disenchant", ApplyDisenchant, 180)

    L:Gap(6)
    L:Header("Looting")
    refreshers[#refreshers + 1] = L:Check("Auto-collect loot, mining, herbs & skinning",
        function() return db.auto end,
        function(v) db.auto = v; RunDotCommand(".auto " .. (v and "on" or "off")) end).uncappedRefresh
    refreshers[#refreshers + 1] = L:Check("AOE loot (loot all nearby corpses at once)",
        function() return db.aoeloot end,
        function(v) db.aoeloot = v; RunDotCommand(".aoeloot " .. (v and "on" or "off")) end).uncappedRefresh

    L:Gap(6)
    L:Note("|cff808080These toggles send server commands and remember your last choice here. If you change them with a chat command instead, this page won't know -- reopen it after /reload to resync.|r", 40)

    UncappedLootPanel = panel
end

-- ===========================================================================
-- SavedVariables load: merge saved values, point the global at our live table.
-- ===========================================================================
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
-- The window-scale slider is built at file scope from a value owned by another
-- addon's SavedVariables (UncappedUIDB, see above). ## OptionalDeps: UncappedUI
-- makes that load first so the value is normally already right, but the slider
-- is re-synced at login anyway -- one event is a lot cheaper than a slider that
-- silently reads 1.00 while the player's windows are at 1.30.
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self, event, name)
    if event == "PLAYER_LOGIN" then
        for _, r in ipairs(scaleRefreshers) do r() end
        return
    end
    if name ~= "UncappedOptions" then return end
    if type(UncappedOptionsDB) == "table" then
        local s = UncappedOptionsDB
        if type(s.de) == "table" then
            for k, v in pairs(s.de) do db.de[k] = v end
        end
        if s.auto ~= nil then db.auto = s.auto end
        if s.aoeloot ~= nil then db.aoeloot = s.aoeloot end
    end
    UncappedOptionsDB = db   -- persist edits to our live table
    refreshLoot()
    self:UnregisterEvent("ADDON_LOADED")
end)

-- /uncapped opens the hub.
SLASH_UNCAPPEDOPTIONS1 = "/uncapped"
SlashCmdList["UNCAPPEDOPTIONS"] = function() UI.Open(hub) end
