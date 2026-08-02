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

-- This server has no PvP content, so the default "PVP" micro-button (bottom
-- of the main menu bar) and its default H keybind (TOGGLEPVPFRAME) would
-- otherwise just open a frame with nothing useful in it. Repointed to open
-- the Dashboard instead: reassign the global function the click/keybind
-- actually calls, rather than touching Bindings.xml or the button's own
-- OnClick script. The icon is a stock Blizzard texture standing in until
-- real Uncapped theme art exists (see AI Context.md's note on Draft\UI\'s
-- placeholder theme).
local function InstallPVPButtonHook()
    if TogglePVPFrame then
        TogglePVPFrame = Toggle
    end
    if PVPMicroButton then
        -- Blizzard's micro-button art is more than just the swappable Normal/
        -- Pushed/Disabled textures -- there's baked-in border/icon artwork as
        -- other texture regions on the same button, inherited with whatever
        -- size/anchor the ORIGINAL (taller, label-inclusive) micro-button
        -- graphic used. Left alone, that art still shows through/behind our
        -- replacement (reported: old icon visible in front, ours sitting too
        -- high) and our new textures inherit the wrong offset/size. Hiding
        -- every texture region first, then explicitly centering/sizing only
        -- the ones we actually set, avoids both problems regardless of what
        -- those regions happen to be named.
        for i = 1, select("#", PVPMicroButton:GetRegions()) do
            local region = select(i, PVPMicroButton:GetRegions())
            if region and region.GetObjectType and region:GetObjectType() == "Texture" then
                region:Hide()
            end
        end

        -- Explicit fixed size, centered -- an edge-inset fill still came out
        -- too tall since the button itself is taller than a plain icon
        -- needs to be. CENTER + a fixed size doesn't depend on
        -- GetWidth/GetHeight (which can read 0/stale at PLAYER_LOGIN before
        -- the micro bar has finished laying itself out) at all, so it's
        -- still safe regardless of timing.
        local ICON_SIZE = 16
        local function SkinTexture(tex)
            if not tex then return end
            tex:ClearAllPoints()
            tex:SetPoint("CENTER", PVPMicroButton, "CENTER", 0, 0)
            tex:SetWidth(ICON_SIZE)
            tex:SetHeight(ICON_SIZE)
            tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            tex:Show()
        end

        PVPMicroButton:SetNormalTexture("Interface\\Icons\\Trade_Engineering")
        PVPMicroButton:SetPushedTexture("Interface\\Icons\\Trade_Engineering")
        PVPMicroButton:SetDisabledTexture("Interface\\Icons\\Trade_Engineering")
        PVPMicroButton:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

        SkinTexture(PVPMicroButton:GetNormalTexture())
        SkinTexture(PVPMicroButton:GetPushedTexture())
        SkinTexture(PVPMicroButton:GetDisabledTexture())
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
