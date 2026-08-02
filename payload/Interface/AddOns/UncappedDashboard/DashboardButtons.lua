-- DashboardButtons -- the master window for the whole Dashboard: banner,
-- title, close button, drag/resize chrome, and the vertical button stack
-- (Core.TABS) on its left side. UncappedDashboard_UI.lua builds its
-- content panel directly into this same window (anchored off
-- Buttons.GetNavPanel()) rather than in a separate window, so there's
-- only ever one frame, one title bar, one resize grip for the whole UI.

local Core = _G.UncappedDashboard
if not Core then return end

local UncappedUI = _G.UncappedUI
if not UncappedUI then return end

local Buttons = {}
Core.Buttons = Buttons

local window
local navPanel
local navButtons = {}

-- Button metrics.
local BUTTON_WIDTH = 140
local BUTTON_HEIGHT = 30
local BUTTON_SPACING = 36
local BUTTON_START_Y = -14

-- Padding between the buttons and the nav panel's own border, and between
-- the nav panel and the window's outer edge.
local PANEL_PAD = 18
local WINDOW_MARGIN = 16
local TOP_INSET = 44
local BOTTOM_INSET = 16
local PANEL_BOTTOM_PAD = 16 -- breathing room below the last button, inside the panel

local PANEL_WIDTH = BUTTON_WIDTH + PANEL_PAD * 2
local PANEL_HEIGHT = (-BUTTON_START_Y) + (#Core.TABS - 1) * BUTTON_SPACING + BUTTON_HEIGHT + PANEL_BOTTOM_PAD
local REQUIRED_HEIGHT = TOP_INSET + PANEL_HEIGHT + BOTTOM_INSET

-- Content sizing is UncappedDashboard_UI.lua's concern -- it fills
-- whatever space is left via anchors, no coordination needed once the
-- window exists. These are only used to give the (shared) window
-- sensible min/max/default bounds.
local CONTENT_GAP = 10
-- General-purpose floor -- what the Dashboard tab and any not-yet-embedded
-- placeholder tab need. Embedded tabs with wider content (Soul Forge's
-- side-by-side buttons, Anima's buy-button row) raise the floor further
-- for themselves only, via SetMinContentWidth below -- they don't force
-- every other tab to also stay that wide.
local CONTENT_MIN_WIDTH = 320
local CONTENT_DEFAULT_WIDTH = 380
-- Universal ceiling: unlike the floor, this is the same for every tab.
local CONTENT_MAX_WIDTH = 920 -- was 520; +400 per request

local MIN_WIDTH = WINDOW_MARGIN + PANEL_WIDTH + CONTENT_GAP + CONTENT_MIN_WIDTH + WINDOW_MARGIN
local DEFAULT_WIDTH = WINDOW_MARGIN + PANEL_WIDTH + CONTENT_GAP + CONTENT_DEFAULT_WIDTH + WINDOW_MARGIN
local MAX_WIDTH = WINDOW_MARGIN + PANEL_WIDTH + CONTENT_GAP + CONTENT_MAX_WIDTH + WINDOW_MARGIN
local MAX_HEIGHT = 700

-- TOPLEFT + BOTTOMLEFT (both left-edge anchors, no horizontal conflict)
-- plus an explicit SetWidth -- lets the panel stretch vertically with the
-- window (now resizable) while staying a fixed width for the buttons.
local function CreateNavPanel(parent)
    local panel = UncappedUI.CreatePanel(parent)
    panel:SetPoint("TOPLEFT", WINDOW_MARGIN, -TOP_INSET)
    panel:SetPoint("BOTTOMLEFT", WINDOW_MARGIN, BOTTOM_INSET)
    panel:SetWidth(PANEL_WIDTH)
    return panel
end

local function CreateNavButton(panel, tab, y)
    local b = UncappedUI.CreateButton(panel, tab.label, BUTTON_WIDTH, BUTTON_HEIGHT)
    b:SetPoint("TOP", panel, "TOP", 0, y)
    b:SetScript("OnClick", function() Core.SetTab(tab.key) end)
    return b
end

function Buttons.Build()
    if window then return end
    local db = Core.GetDB()

    -- Always open centered on screen, computed fresh from the saved
    -- width/height every time -- persistPosition = false means
    -- CreateWindow's own SavePosition never writes point/x/y into db no
    -- matter how much the window gets dragged during a session, only
    -- width/height. db.point/x/y are still what CreateWindow actually
    -- reads for the initial anchor, though, so they're computed here.
    --
    -- A literal "CENTER" anchor would make the resize grip grow the
    -- window symmetrically around its center (the same drift bug the
    -- two-window version hit) -- computing the equivalent TOPLEFT
    -- position instead keeps the top-left corner fixed for correct
    -- bottom-right-grip resizing while still opening centered.
    local screenW, screenH = UIParent:GetWidth(), UIParent:GetHeight()
    db.point, db.relativePoint = "TOPLEFT", "TOPLEFT"
    db.x = (screenW - db.width) / 2
    db.y = -(screenH - db.height) / 2

    window = UncappedUI.CreateWindow({
        name = "UncappedDashboardFrame",
        title = "Dashboard",
        width = DEFAULT_WIDTH, height = REQUIRED_HEIGHT,
        minWidth = MIN_WIDTH, minHeight = REQUIRED_HEIGHT,
        maxWidth = MAX_WIDTH, maxHeight = MAX_HEIGHT,
        resizable = true,
        persistPosition = false,
        db = db,
    })

    navPanel = CreateNavPanel(window)

    local y = BUTTON_START_Y
    for _, tab in ipairs(Core.TABS) do
        navButtons[tab.key] = CreateNavButton(navPanel, tab, y)
        y = y - BUTTON_SPACING
    end

    window:Hide()
end

-- Returns the master window frame, or nil before Build()/Show() has run.
function Buttons.GetWindow()
    return window
end

-- Returns the button column panel, or nil before Build()/Show() has run.
-- UncappedDashboard_UI.lua anchors its content panel off this.
function Buttons.GetNavPanel()
    return navPanel
end

function Buttons.GetRequiredHeight()
    return REQUIRED_HEIGHT
end

function Buttons.GetMinWidth()
    return MIN_WIDTH
end

function Buttons.GetMaxWidth()
    return MAX_WIDTH
end

-- Raises the window's resize floor to fit the currently active tab's own
-- content (e.g. a button row that would overflow below a certain width),
-- without touching the ceiling -- MAX_WIDTH stays the same for every tab.
-- `contentWidth` is in content-panel pixels, not window pixels; pass nil/0
-- to fall back to the general-purpose CONTENT_MIN_WIDTH floor. Widens the
-- window immediately if it's currently narrower than the new floor.
function Buttons.SetMinContentWidth(contentWidth)
    if not window then return end
    local minW = WINDOW_MARGIN + PANEL_WIDTH + CONTENT_GAP
        + math.max(CONTENT_MIN_WIDTH, contentWidth or 0) + WINDOW_MARGIN
    minW = math.min(minW, MAX_WIDTH)
    window:SetMinResize(minW, REQUIRED_HEIGHT)
    if window:GetWidth() < minW then
        window:SetWidth(minW)
    end
end

function Buttons.SetTitle(text)
    if window then window.titleText:SetText(text or "") end
end

-- Re-highlights whichever button matches Core.state.tab.
function Buttons.RefreshActive()
    if not window then return end
    for _, tab in ipairs(Core.TABS) do
        UncappedUI.SetButtonActive(navButtons[tab.key], tab.key == Core.state.tab)
    end
end

function Buttons.IsShown()
    return window and window:IsShown()
end

function Buttons.Show()
    Buttons.Build()
    window:Show()
end

function Buttons.Hide()
    if window then window:Hide() end
end
