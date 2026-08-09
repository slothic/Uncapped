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
local arenaPointsText
local goldText

-- Thousands separators. Local rather than borrowed from Core.Comma, which
-- lives on the Vault's own table (UncappedVault), not the Dashboard's.
local function Comma(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

local function FormatMoney(copper)
    copper = tonumber(copper) or 0
    return string.format(
        "%s |TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t %d |TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t %d |TInterface\\MoneyFrame\\UI-CopperIcon:12:12:2:0|t",
        Comma(math.floor(copper / 10000)),
        math.floor((copper % 10000) / 100),
        copper % 100)
end

-- Both footers were hardcoded to "12,450" -- the comment where they were built
-- said outright that no data source was wired up. Reported as arena points
-- showing a static value that was not the character's own.
--
-- GetArenaCurrency() is the right source and needs no new protocol: the server
-- already answers the Anima window's ANIMAPTS with player->GetArenaPoints(),
-- which is this same number (mod-time-stats/src/time_stats.cpp).
local function RefreshFooter()
    if arenaPointsText then
        arenaPointsText:SetText(string.format("Anima: |cffffd100%s|r", Comma(GetArenaCurrency and GetArenaCurrency() or 0)))
    end
    if goldText then
        goldText:SetText(FormatMoney(GetMoney and GetMoney() or 0))
    end
end
Core.RefreshFooter = RefreshFooter

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
-- Reserved below the button stack for the Gold/Anima footer (see
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
local CONTENT_MAX_WIDTH = 1400 -- was 920; the screen cap below is the real limit

local MIN_WIDTH = WINDOW_MARGIN + PANEL_WIDTH + CONTENT_GAP + CONTENT_MIN_WIDTH + WINDOW_MARGIN
local DEFAULT_WIDTH = WINDOW_MARGIN + PANEL_WIDTH + CONTENT_GAP + CONTENT_DEFAULT_WIDTH + WINDOW_MARGIN
local MAX_WIDTH_ABS = WINDOW_MARGIN + PANEL_WIDTH + CONTENT_GAP + CONTENT_MAX_WIDTH + WINDOW_MARGIN
local MAX_HEIGHT_ABS = 1400

-- Related to "make the Loot Feed window resizeable" (#125). Be careful reading
-- these numbers: frame sizes are in UIParent units, NOT monitor pixels, and
-- UIParent is about 768 units tall at the default UI scale whatever the
-- monitor is (width is 768 * aspect, so ~1365 at 16:9). So the old literals --
-- 700 tall, ~1250 wide -- were already about 91% of the screen in both
-- directions, and raising them on their own would have changed almost nothing.
--
-- What they DID cost is players who turn the UI-scale slider down, which makes
-- UIParent bigger in units (~850+ tall): for them 700 really was a low
-- ceiling, and a literal cannot know that. Deriving from UIParent covers both
-- cases and cannot go stale.
--
-- The jarring half of #125 was not the ceiling at all -- see the note above
-- Buttons.Build about the window re-centering itself after every resize.
--
-- SCREEN_MARGIN is not cosmetic. Size a window flush to the screen edge and
-- the bottom-right grip ends up under that edge: SetClampedToScreen keeps the
-- frame on screen, but leaves no comfortable place to grab it and drag back.
local SCREEN_MARGIN = 60

function Buttons.GetMaxWidth()
    local screen = math.floor((UIParent:GetWidth() or 1024) - SCREEN_MARGIN)
    return math.max(MIN_WIDTH, math.min(MAX_WIDTH_ABS, screen))
end

function Buttons.GetMaxHeight()
    local screen = math.floor((UIParent:GetHeight() or 768) - SCREEN_MARGIN)
    return math.max(REQUIRED_HEIGHT, math.min(MAX_HEIGHT_ABS, screen))
end

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

-- The window used to re-center itself the instant you let go of the resize
-- grip (passed as CreateWindow's onResizeStop). That is gone: with a taller
-- ceiling you drag the grip several times to find a size you like, and having
-- the window teleport to the middle of the screen after every drag is most of
-- what made resizing feel broken rather than merely limited.
--
-- Nothing depended on it. Opening centered is Build()'s job, computed fresh
-- from the saved size each session, and the TOPLEFT anchor set there -- not
-- this function -- is what keeps the grip growing the window down-and-right
-- instead of symmetrically around its center. SetClampedToScreen keeps a
-- resize from pushing the frame off the edge.

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
        maxWidth = Buttons.GetMaxWidth(), maxHeight = Buttons.GetMaxHeight(),
        resizable = true,
        persistPosition = false,
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

    -- Gold/Anima -- pinned to the nav panel itself (not any one tab's
    -- content), so they stay visible no matter which tab is active, per
    -- request. Both read live values now; see RefreshFooter above.
    arenaPointsText = navPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    arenaPointsText:SetPoint("BOTTOMLEFT", navPanel, "BOTTOMLEFT", PANEL_PAD, 22)
    arenaPointsText:SetPoint("BOTTOMRIGHT", navPanel, "BOTTOMRIGHT", -PANEL_PAD, 22)
    arenaPointsText:SetJustifyH("RIGHT")

    goldText = navPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    goldText:SetPoint("BOTTOMLEFT", navPanel, "BOTTOMLEFT", PANEL_PAD, 6)
    goldText:SetPoint("BOTTOMRIGHT", navPanel, "BOTTOMRIGHT", -PANEL_PAD, 6)
    goldText:SetJustifyH("RIGHT")

    RefreshFooter()

    -- Refresh on open rather than on a ticker: arena points only move on a
    -- purchase or the weekly grant, and the window is the only thing that shows
    -- them. PLAYER_MONEY keeps gold honest while the window is already open --
    -- you can sell from your bags without closing it.
    window:HookScript("OnShow", RefreshFooter)

    local footerEvents = CreateFrame("Frame")
    footerEvents:RegisterEvent("PLAYER_MONEY")
    footerEvents:RegisterEvent("PLAYER_ENTERING_WORLD")
    footerEvents:SetScript("OnEvent", function()
        if window and window:IsShown() then RefreshFooter() end
    end)

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
-- without touching the ceiling -- GetMaxWidth() is the same for every tab.
-- `contentWidth` is in content-panel pixels, not window pixels; pass nil/0
-- to fall back to the general-purpose CONTENT_MIN_WIDTH floor. Widens the
-- window immediately if it's currently narrower than the new floor.
function Buttons.SetMinContentWidth(contentWidth)
    if not window then return end
    local minW = WINDOW_MARGIN + PANEL_WIDTH + CONTENT_GAP
        + math.max(CONTENT_MIN_WIDTH, contentWidth or 0) + WINDOW_MARGIN
    currentMinWidth = math.min(minW, Buttons.GetMaxWidth())
    ApplyMinResize()
end

-- Same idea, but for the window's total height -- e.g. Anima wants enough
-- height to show all 4 cards of a tree without scrolling. `windowHeight` is
-- the full window height a tab needs; pass nil/0 to fall back to
-- REQUIRED_HEIGHT (what the nav button column alone needs).
function Buttons.SetMinContentHeight(windowHeight)
    if not window then return end
    currentMinHeight = math.min(math.max(REQUIRED_HEIGHT, windowHeight or 0), Buttons.GetMaxHeight())
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
