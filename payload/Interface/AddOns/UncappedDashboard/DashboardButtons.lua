-- DashboardButtons -- the master window for the whole Dashboard: banner,
-- title, close button, drag/resize chrome, and the vertical button stack
-- (Core.TABS) on its left side. UncappedDashboard_UI.lua builds its
-- content panel directly into this same window (anchored off
-- Buttons.GetNavPanel()) rather than in a separate window, so there's
-- only ever one frame, one title bar, one resize grip for the whole UI.

local Core = _G.UncappedDashboard
if not Core then return end

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

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
-- Reserved below the button stack for the Gold/Arena Points footer (see
-- Buttons.Build) -- two lines at GameFontHighlightSmall's own line height
-- plus a little breathing room between them and the last button.
local FOOTER_HEIGHT = 40

local PANEL_WIDTH = BUTTON_WIDTH + PANEL_PAD * 2
local PANEL_HEIGHT = (-BUTTON_START_Y) + (#Core.TABS - 1) * BUTTON_SPACING + BUTTON_HEIGHT + PANEL_BOTTOM_PAD + FOOTER_HEIGHT
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
    local panel = UncappedUIKit.CreatePanel(parent)
    panel:SetPoint("TOPLEFT", WINDOW_MARGIN, -TOP_INSET)
    panel:SetPoint("BOTTOMLEFT", WINDOW_MARGIN, BOTTOM_INSET)
    panel:SetWidth(PANEL_WIDTH)
    return panel
end

-- Shift-click/ctrl-click move this button's tab up/down in the saved order
-- (Core.MoveTab) instead of switching to it -- keeps reordering on the same
-- buttons players already click, no separate edit mode or drag needed.
-- Positioning happens separately, in Buttons.RefreshOrder -- this only
-- creates the button, since it's built once but may be repositioned many
-- times as the player reorders.
local function CreateNavButton(panel, tab)
    local b = UncappedUIKit.CreateButton(panel, tab.label, BUTTON_WIDTH, BUTTON_HEIGHT)
    if tab.disabled then b:SetAlpha(0.5) end
    b:SetScript("OnClick", function()
        if IsShiftKeyDown() then
            Core.MoveTab(tab.key, -1)
        elseif IsControlKeyDown() then
            Core.MoveTab(tab.key, 1)
        elseif not tab.disabled then
            Core.SetTab(tab.key)
        end
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(tab.label)
        if tab.disabled then
            GameTooltip:AddLine("Not available yet", 1, 0.35, 0.25)
        end
        GameTooltip:AddLine("Shift-click: move up", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Ctrl-click: move down", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

-- Re-centers the window on screen at its current size -- same TOPLEFT-anchor
-- math Build() uses to open centered, just recomputed against whatever size
-- the resize grip left it at. Passed as CreateWindow's onResizeStop, so it
-- fires once the user releases the grip rather than continuously while
-- dragging (a live re-anchor mid-drag would fight StartSizing's own anchor).
local function RecenterWindow(win)
    local screenW, screenH = UIParent:GetWidth(), UIParent:GetHeight()
    local w, h = win:GetWidth(), win:GetHeight()
    win:ClearAllPoints()
    win:SetPoint("TOPLEFT", UIParent, "TOPLEFT", (screenW - w) / 2, -(screenH - h) / 2)
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

    window = UncappedUIKit.CreateWindow({
        name = "UncappedDashboardFrame",
        title = "Dashboard",
        width = DEFAULT_WIDTH, height = REQUIRED_HEIGHT,
        minWidth = MIN_WIDTH, minHeight = REQUIRED_HEIGHT,
        maxWidth = MAX_WIDTH, maxHeight = MAX_HEIGHT,
        resizable = true,
        persistPosition = false,
        onResizeStop = RecenterWindow,
        db = db,
        -- Below the bags, not above them. The kit defaults to HIGH, which is the
        -- same strata Blizzard's ContainerFrames use, so the tie broke on frame
        -- level and the dashboard covered the bags you were trying to drag out
        -- of -- the one thing the Vault tab exists to receive.
        strata = "MEDIUM",
    })

    navPanel = CreateNavPanel(window)

    for _, tab in ipairs(Core.TABS) do
        navButtons[tab.key] = CreateNavButton(navPanel, tab)
    end
    Buttons.RefreshOrder()

    -- Gold/Arena Points -- pinned to the nav panel itself (not any one tab's
    -- content), so they stay visible no matter which tab is active, per
    -- request. Placeholder values: neither has a real data source wired up
    -- yet (Vault's own copy of the Gold line was the same static string
    -- before it moved here).
    local arenaPointsText = navPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    arenaPointsText:SetPoint("BOTTOMLEFT", navPanel, "BOTTOMLEFT", PANEL_PAD, 22)
    arenaPointsText:SetPoint("BOTTOMRIGHT", navPanel, "BOTTOMRIGHT", -PANEL_PAD, 22)
    arenaPointsText:SetJustifyH("RIGHT")
    arenaPointsText:SetText("Arena Points: |cffffd10012,450|r")

    local goldText = navPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    goldText:SetPoint("BOTTOMLEFT", navPanel, "BOTTOMLEFT", PANEL_PAD, 6)
    goldText:SetPoint("BOTTOMRIGHT", navPanel, "BOTTOMRIGHT", -PANEL_PAD, 6)
    goldText:SetJustifyH("RIGHT")
    goldText:SetText("12,450 |TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t 87 |TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t 42 |TInterface\\MoneyFrame\\UI-CopperIcon:12:12:2:0|t")

    window:Hide()
end

-- Re-anchors the (already-built) nav buttons top-to-bottom to match the
-- player's current saved order (Core.OrderedTabs) -- called once from
-- Build() and again from Core.MoveTab whenever that order changes.
function Buttons.RefreshOrder()
    if not navPanel then return end
    local y = BUTTON_START_Y
    for _, tab in ipairs(Core.OrderedTabs()) do
        local b = navButtons[tab.key]
        if b then
            b:ClearAllPoints()
            b:SetPoint("TOP", navPanel, "TOP", 0, y)
            y = y - BUTTON_SPACING
        end
    end
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

function Buttons.GetMaxHeight()
    return MAX_HEIGHT
end

-- SetMinResize takes both dimensions at once, so the width and height floors
-- set by whichever tab is active are tracked here and reapplied together --
-- otherwise raising one would silently reset the other back to its opts.*
-- value from Buttons.Build.
local currentMinWidth = MIN_WIDTH
local currentMinHeight = REQUIRED_HEIGHT

local function ApplyMinResize()
    if not window then return end
    window:SetMinResize(currentMinWidth, currentMinHeight)
    local w, h = window:GetWidth(), window:GetHeight()
    if w < currentMinWidth or h < currentMinHeight then
        window:SetWidth(math.max(w, currentMinWidth))
        window:SetHeight(math.max(h, currentMinHeight))
    end
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
    currentMinWidth = math.min(minW, MAX_WIDTH)
    ApplyMinResize()
end

-- Same idea, but for the window's total height -- e.g. Anima wants enough
-- height to show all 4 cards of a tree without scrolling. `windowHeight` is
-- the full window height a tab needs; pass nil/0 to fall back to
-- REQUIRED_HEIGHT (what the nav button column alone needs).
function Buttons.SetMinContentHeight(windowHeight)
    if not window then return end
    currentMinHeight = math.min(math.max(REQUIRED_HEIGHT, windowHeight or 0), MAX_HEIGHT)
    ApplyMinResize()
end

function Buttons.SetTitle(text)
    if window then window.titleText:SetText(text or "") end
end

-- Re-highlights whichever button matches Core.state.tab.
function Buttons.RefreshActive()
    if not window then return end
    for _, tab in ipairs(Core.TABS) do
        UncappedUIKit.SetButtonActive(navButtons[tab.key], tab.key == Core.state.tab)
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
