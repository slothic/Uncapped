-- UncappedDashboard -- launcher shell: one master window (built in
-- DashboardButtons.lua) holding the button stack on the left and a
-- content panel on the right that swaps what it shows based on the
-- selected button. For now only the Dashboard tab's content (Overview +
-- Modules) is real; the other buttons switch the tab but their real
-- windows aren't wired up yet (see UncappedDashboard_UI.lua).

local max, min = math.max, math.min

local Core = _G.UncappedDashboard or {}
_G.UncappedDashboard = Core

Core.version = "1.0.0"
Core.ADDON = "UncappedDashboard"
Core.callbacks = Core.callbacks or {}

-- Core.TABS / Core.MODULES now live in UncappedDashboardConfig.lua, which
-- loads before this file (see UncappedDashboard.toc).

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
    -- db.tabOrder (an array of tab keys, player-editable nav button order)
    -- isn't listed here -- nil/absent already means "Core.TABS' own array
    -- order" (see Core.OrderedTabs in UncappedDashboardConfig.lua), so there's
    -- no default value to seed.
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
    -- Ceiling comes from Buttons (screen-derived) rather than a literal, so a
    -- size saved on one monitor cannot open off the bottom of a smaller one.
    local maxH = (Core.Buttons and Core.Buttons.GetMaxHeight and Core.Buttons.GetMaxHeight()) or 700
    db.height = max(minH, min(maxH, tonumber(db.height) or defaults.height))

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

-- This server has no PvP content, so the default "PVP" micro-button (bottom of
-- the main menu bar) and its default H keybind (TOGGLEPVPFRAME) would otherwise
-- just open a frame with nothing useful in it. Repointed to open the Dashboard
-- instead: reassign the global function the click/keybind actually calls, rather
-- than touching Bindings.xml or the button's own OnClick script.
--
-- ★ THE BUTTON KEEPS ITS STOCK BLIZZARD ARTWORK, DELIBERATELY.
--
--   It used to be re-skinned with Interface\Icons\Trade_Engineering as a
--   placeholder "until real Uncapped theme art exists". That art never arrived,
--   and the stand-in outlived its welcome: the Engineering icon is a GEAR WHEEL,
--   which reads as a settings button, so people saw the honour icon apparently
--   turn into a cog and reported it as a bug. A placeholder that looks like a
--   fault is worse than no placeholder.
--
--   Removed rather than swapped for a different icon. Not touching the textures
--   at all is strictly simpler than restoring them: the previous code had to
--   hide every texture region on the button first, because Blizzard's
--   micro-button art carries baked-in border/icon regions at the ORIGINAL
--   (taller, label-inclusive) size that showed through and mis-anchored anything
--   drawn over them. All of that fiddling exists only to support a custom icon.
--   No custom icon, no fiddling, no way for it to go wrong at load time.
--
-- ⚠ Known cosmetic mismatch, accepted: the button still LOOKS like the PvP
--   button and its tooltip still says so, while opening the Dashboard. That is
--   the trade for having a stock-looking UI, and it is the owner's call
--   (2026-08-08). Revisit if real theme art is ever made.
local function InstallPVPButtonHook()
    if TogglePVPFrame then
        TogglePVPFrame = Toggle
    end
end

local init = CreateFrame("Frame")
init:RegisterEvent("PLAYER_LOGIN")
init:SetScript("OnEvent", function()
    local db = Core.GetDB()
    if Core.IsValidTab(db.lastTab) then
        state.tab = db.lastTab
    end
    InstallPVPButtonHook()
end)

SLASH_UNCAPPEDDASHBOARD1 = "/dashboard"
SLASH_UNCAPPEDDASHBOARD2 = "/udash"
SlashCmdList["UNCAPPEDDASHBOARD"] = Toggle
