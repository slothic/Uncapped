-- UncappedDashboard -- launcher shell: one master window (built in
-- DashboardButtons.lua) holding the button stack on the left and a
-- content panel on the right that swaps what it shows based on the
-- selected button. For now only the Dashboard tab's content (Overview +
-- Modules) is real; the other buttons switch the tab but their real
-- windows aren't wired up yet (see UncappedDashboard_UI.lua).

local max, min = math.max, math.min

local Core = _G.UncappedDashboard or {}
_G.UncappedDashboard = Core

Core.version = "0.0.0"
Core.ADDON = "UncappedDashboard"
Core.callbacks = Core.callbacks or {}

-- `hint` is the slash command that already opens that addon today, shown
-- as a placeholder in the content pane until this button opens the real
-- window directly. Keep in sync with each addon's own SLASH_* registration.
Core.TABS = {
    { key = "dashboard", label = "Dashboard" },
    { key = "forge", label = "Forge", addon = "UncappedForge", hint = "/forge" },
    -- [Uncapped] The Soulforge ships as the UncappedItemCustomize folder on
    -- this realm -- the addon was renamed in its UI and slash commands but the
    -- folder kept its original name so players' SavedVariables survive. Draft
    -- said "UncappedSoulForge", which matches nothing installed.
    { key = "soulforge", label = "Soulforge", addon = "UncappedItemCustomize", hint = "/soulforge" },
    { key = "anima", label = "Anima", addon = "UncappedAnima", hint = "/anima" },
    { key = "vault", label = "Vault", addon = "UncappedVault", hint = "/vault" },
    { key = "transmog", label = "Transmog", addon = "UncappedTransmog", hint = "/transmog" },
    { key = "statfeed", label = "Stat Feed", addon = "StatFeed", hint = "/statfeed" },
    { key = "questlog", label = "Quest Log", addon = "UncappedQuests", hint = "/uquests" },
    { key = "tutorial", label = "Tutorial", addon = "UncappedTutorial" },
    { key = "utilities", label = "Utilities", addon = "UncappedOptions", hint = "/uncapped" },
    { key = "beastiary", label = "Beastiary" },
    { key = "soulscrolls", label = "Soul Scrolls", addon = "UncappedScrolls", hint = "/scrolls" },
}

-- Toggles shown in the Dashboard tab's "Modules" section. Purely a saved
-- on/off preference for now (UncappedDashboard_UI.lua persists it to
-- db.modules) -- nothing actually enables/disables these features yet.
Core.MODULES = {
    { key = "statfeed", label = "Stat Feed" },
    { key = "autoloot", label = "Autoloot" },
    { key = "aoeloot", label = "AoE Loot" },
    { key = "autodisenchant", label = "Autodisenchant" },
}

local state = {
    tab = "dashboard",
}
Core.state = state

local function CopyDefault(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = x end
    return t
end

function Core.GetDB()
    UncappedDashboardDB = UncappedDashboardDB or {}
    local db = UncappedDashboardDB
    -- Size only -- no point/x/y here. DashboardButtons.lua always opens
    -- the window centered on screen (computed fresh from db.width/height
    -- every session, see Buttons.Build) and passes persistPosition=false
    -- to CreateWindow, so position is never read from or written to this
    -- table at all -- only size persists across sessions.
    local defaults = {
        width = 600,
        height = 480,
        lastTab = "dashboard",
    }
    for k, v in pairs(defaults) do
        if db[k] == nil then db[k] = CopyDefault(v) end
    end

    -- Purge leftovers from earlier designs: db.contentPos (the two-window
    -- version's separate content-window position/size) and point/
    -- relativePoint/x/y (position used to persist before this window
    -- always opened centered).
    db.contentPos = nil
    db.point, db.relativePoint, db.x, db.y = nil, nil, nil, nil

    -- Guarded since DashboardButtons.lua may not have loaded/registered
    -- yet; falls back to sane literals otherwise.
    local minW = (Core.Buttons and Core.Buttons.GetMinWidth and Core.Buttons.GetMinWidth()) or 540
    local maxW = (Core.Buttons and Core.Buttons.GetMaxWidth and Core.Buttons.GetMaxWidth()) or 740
    db.width = max(minW, min(maxW, tonumber(db.width) or defaults.width))
    local minH = (Core.Buttons and Core.Buttons.GetRequiredHeight and Core.Buttons.GetRequiredHeight()) or 480
    db.height = max(minH, min(700, tonumber(db.height) or defaults.height))

    db.modules = db.modules or {}
    for _, mod in ipairs(Core.MODULES) do
        if db.modules[mod.key] == nil then db.modules[mod.key] = true end
    end

    return db
end

local function Notify(reason)
    if Core.UI and Core.UI.Refresh then Core.UI.Refresh(reason) end
end

function Core.RegisterUI(ui)
    Core.UI = ui
end

function Core.IsValidTab(key)
    for _, tab in ipairs(Core.TABS) do
        if tab.key == key then return true end
    end
    return false
end

function Core.SetTab(key)
    if not Core.IsValidTab(key) then return end
    state.tab = key
    Core.GetDB().lastTab = key
    Notify("tab")
end

local function Toggle()
    if Core.UI and Core.UI.Toggle then Core.UI.Toggle() end
end
Core.Toggle = Toggle

local init = CreateFrame("Frame")
init:RegisterEvent("PLAYER_LOGIN")
init:SetScript("OnEvent", function()
    local db = Core.GetDB()
    if Core.IsValidTab(db.lastTab) then
        state.tab = db.lastTab
    end
end)

SLASH_UNCAPPEDDASHBOARD1 = "/dashboard"
SLASH_UNCAPPEDDASHBOARD2 = "/udash"
SlashCmdList["UNCAPPEDDASHBOARD"] = Toggle
