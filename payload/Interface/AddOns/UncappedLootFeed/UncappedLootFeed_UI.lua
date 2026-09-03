-- UncappedLootFeed_UI -- the Loot Feed's Dashboard tab.
--
-- Lives inside the Dashboard's content panel (see EmbedInto at the bottom) --
-- no own backdrop/title/close/drag, since the Dashboard's master window already
-- provides all of that chrome.
--
-- TWO VIEWS, ONE LIST
--   "Feed" is every loot line seen this session; "Watchlist" is what you are
--   farming for, and doubles as the item browser -- typing in the search box
--   swaps the list to matches from the baked item table so you can click one to
--   start watching it. Both views share one row pool and one paint function,
--   because a row is the same thing in both: an icon, a name, and a watched
--   marker.
--
-- WHAT THIS FILE NO LONGER OWNS  (#125)
--   Rows and filters moved out to UncappedLootFeed_Rows.lua and
--   UncappedLootFeed_Filters.lua when the pop-out window arrived, because both
--   views draw the identical thing and the first difference to creep in would
--   have been the watched-item highlight -- the one part the owner asked to be
--   unmistakable. This file is now layout and view switching only.
--
-- THE FILTER BAR IS THE VAULT'S  (asked for directly)
--   The chip row that used to live here was replaced by the Vault's furniture:
--   a sources dropdown, a quality dropdown, a checkbox and a "Show all" escape
--   hatch. See UncappedLootFeed_Filters.lua for why sources is a multi-check
--   and why every control starts at its widest setting.

local LF = _G.UncappedLootFeed
if not LF then return end

local UIKit = _G.UncappedUIKit
if not UIKit then
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4040[Loot Feed]|r requires UncappedUI, which isn't loaded -- enable it in AddOns and reload.")
    end
    return
end

local Rows = LF.Rows
if not Rows then return end

local ROW_H = Rows.H
local PAD   = 12
-- View buttons (row 1, 24 high at y -10) over the filter bar (two rows,
-- LF.Filters.HEIGHT, hosted at y -40). 108 clears both with air above the list.
local HEADER_H  = 108
local FOOTER_H  = 26    -- status line below it

local frame, scroll, searchBox, clearBtn, popoutBtn, statusText
local feedBtn, watchBtn
local filterHost, filters
local rows = {}
local visibleRows = 8

local mode = "feed"     -- "feed" | "watch"
local list = {}         -- what the rows are currently painted from

local function Data()
    return _G.UncappedLootFeedData
end

-- ---------------------------------------------------------------------------
-- List building
-- ---------------------------------------------------------------------------
-- One shape for both views so the shared painter stays a single function:
--   { id, label, sub, icon, watched, link, plain, vault }
local function BuildList()
    local D = Data()
    local out = {}

    if mode == "feed" then
        for _, e in ipairs(LF.GetFeed()) do
            out[#out + 1] = Rows.Describe(e)
        end
        return out
    end

    -- Watchlist view. A non-empty search turns it into the item browser.
    local query = searchBox and (searchBox:GetText() or "") or ""
    query = query:gsub("^%s+", ""):gsub("%s+$", "")

    if query ~= "" then
        if not (D and D.IsReady()) then return out end
        for _, hit in ipairs(D.Search(query)) do
            out[#out + 1] = {
                id      = hit.id,
                label   = D.ColoredName(hit.id, hit.name, hit.q),
                -- The source line earns its place most here: this is the list
                -- someone reads while deciding what to go and farm.
                sub     = D.SourceLine and D.SourceLine(hit.id, false) or nil,
                watched = LF.IsWatched(hit.id),
            }
        end
        return out
    end

    for _, it in ipairs(LF.GetWatchlist()) do
        out[#out + 1] = {
            id      = it.id,
            label   = D and D.ColoredName(it.id, it.name, it.q) or it.name,
            sub     = (D and D.SourceLine) and D.SourceLine(it.id, false) or nil,
            watched = true,
        }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Rows
-- ---------------------------------------------------------------------------
local function AcquireRow(i)
    local row = rows[i]
    if row then return row end

    row = Rows.Create(frame)
    row:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -HEADER_H - (i - 1) * ROW_H)
    row:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(PAD + 22), -HEADER_H - (i - 1) * ROW_H)
    rows[i] = row
    return row
end

-- ---------------------------------------------------------------------------
-- Paint
-- ---------------------------------------------------------------------------
local function UpdateStatus()
    if not statusText then return end
    if mode == "feed" then
        -- The hidden count is the important half. An empty feed with a filter on
        -- looks exactly like a feed that is receiving nothing, which is the shape
        -- #214 was reported in -- so it must never be silent about it.
        local hidden = LF.FilteredOutCount()
        if hidden > 0 then
            statusText:SetText(string.format(
                "|cff888888%d of %d loot lines shown  --  |cffffd100%d hidden by filters|r|cff888888  --  %d watched|r",
                LF.FeedCount() - hidden, LF.FeedCount(), hidden, LF.WatchCount()))
        else
            statusText:SetText(string.format(
                "|cff888888%d loot lines  --  %d watched  --  click a row to watch that item|r",
                LF.FeedCount(), LF.WatchCount()))
        end
        return
    end

    local query = searchBox and (searchBox:GetText() or "") or ""
    if query:gsub("%s", "") ~= "" then
        local D = Data()
        local total = (D and D.IsReady()) and D.Count() or 0
        statusText:SetText(string.format(
            "|cff888888%d match%s of %d items  --  click one to watch it|r",
            #list, (#list == 1) and "" or "es", total))
    else
        statusText:SetText(string.format(
            "|cff888888%d item%s watched  --  search above to add, click a row to remove|r",
            #list, (#list == 1) and "" or "s"))
    end
end

local function Relayout()
    if not frame or not frame:IsShown() then return end

    local offset = FauxScrollFrame_GetOffset(scroll) or 0
    for i = 1, visibleRows do
        Rows.Paint(AcquireRow(i), list[i + offset])
    end
    -- Rows left over from a taller window must not linger behind the footer.
    for i = visibleRows + 1, #rows do
        rows[i]:Hide()
        rows[i].entry = nil
    end

    FauxScrollFrame_Update(scroll, #list, visibleRows, ROW_H)
end

local function Rebuild()
    list = BuildList()
    UpdateStatus()
    -- The filter widgets are refreshed on every repaint, not only when this
    -- panel changes them: the pop-out window has a filter bar of its own over
    -- the SAME saved state, so a change made there has to move the dropdown
    -- captions here too. Without it the two windows disagree about what is
    -- being filtered, and only one of them is telling the truth.
    if mode == "feed" and filters then filters.Refresh() end
    Relayout()
end

-- ---------------------------------------------------------------------------
-- View switching
-- ---------------------------------------------------------------------------
local function ApplyMode()
    UIKit.SetButtonActive(feedBtn, mode == "feed")
    UIKit.SetButtonActive(watchBtn, mode == "watch")

    if mode == "feed" then
        searchBox:Hide()
        filterHost:Show()
        clearBtn:Show()
        if filters then filters.Refresh() end
    else
        searchBox:Show()
        filterHost:Hide()
        clearBtn:Hide()
    end
    Rebuild()
end

local function ResetScroll()
    if scroll then FauxScrollFrame_SetOffset(scroll, 0) end
    local sb = _G["UncappedLootFeedScrollScrollBar"]
    if sb then sb:SetValue(0) end
end

local function SetMode(newMode)
    mode = newMode
    -- Scrolling position is per-view; jumping to a new list at the old offset
    -- looks like the list is empty when it is merely scrolled past the end.
    ResetScroll()
    ApplyMode()
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
local function BuildFrame(parent)
    if frame then return end

    frame = CreateFrame("Frame", "UncappedLootFeedPanel", parent)
    frame:SetAllPoints(parent)

    -- ---- view buttons -----------------------------------------------------
    feedBtn = UIKit.CreateButton(frame, "Feed", 92, 24)
    feedBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -10)
    feedBtn:SetScript("OnClick", function() SetMode("feed") end)

    watchBtn = UIKit.CreateButton(frame, "Watchlist", 92, 24)
    watchBtn:SetPoint("LEFT", feedBtn, "RIGHT", 6, 0)
    watchBtn:SetScript("OnClick", function() SetMode("watch") end)

    -- ---- pop out (#125) ---------------------------------------------------
    -- Next to the view buttons rather than off in a corner: the request was for
    -- a window you keep open while you play, so the way to it should be the
    -- first thing anyone sees on the tab.
    popoutBtn = UIKit.CreateButton(frame, "Pop out", 80, 24)
    popoutBtn:SetPoint("LEFT", watchBtn, "RIGHT", 6, 0)
    popoutBtn:SetScript("OnClick", function() LF.TogglePopout() end)
    popoutBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Pop-out window")
        GameTooltip:AddLine("Opens the loot stream in its own small window you can move, resize and leave open while you play. /lootfeed window does the same.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    popoutBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- ---- search (watchlist view) -----------------------------------------
    searchBox = UIKit.CreateSearchBox(frame, 220, 24, "Search items to watch...")
    searchBox:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(PAD + 4), -10)
    searchBox.OnQueryChanged = function()
        ResetScroll()
        Rebuild()
    end
    searchBox:Hide()

    clearBtn = UIKit.CreateButton(frame, "Clear", 70, 24)
    clearBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(PAD + 4), -10)
    clearBtn:SetScript("OnClick", function() LF.ClearFeed() end)

    -- ---- filter bar (feed view) ------------------------------------------
    -- A container of its own so switching views is one Show/Hide rather than a
    -- list of widgets that has to be kept in step with whatever gets added next.
    filterHost = CreateFrame("Frame", nil, frame)
    filterHost:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -40)
    filterHost:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -40)
    filterHost:SetHeight(LF.Filters.HEIGHT)

    filters = LF.Filters.Build(filterHost, {
        x = PAD,
        y = -4,
        rightPad = PAD + 4,
        onChange = function()
            -- A change that alters what is on screen must also drop the scroll
            -- offset: a shorter list at the old offset paints empty, which looks
            -- exactly like the filter having eaten everything.
            ResetScroll()
            Rebuild()
        end,
    })

    -- ---- list -------------------------------------------------------------
    -- Created directly rather than through UIKit.CreateFauxScrollFrame so the
    -- frame gets a KNOWN name: mouse-wheel scrolling needs the auto-created
    -- "<name>ScrollBar" global, and the kit's generated name isn't predictable.
    -- Same approach UncappedAnima uses.
    scroll = CreateFrame("ScrollFrame", "UncappedLootFeedScroll", frame, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -HEADER_H)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -(PAD + 20), FOOTER_H)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, Relayout)
    end)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local sb = _G["UncappedLootFeedScrollScrollBar"]
        if sb then sb:SetValue(sb:GetValue() - (delta or 0) * ROW_H) end
    end)
    scroll:SetScript("OnSizeChanged", function(self, w, h)
        visibleRows = math.max(1, math.floor((h or 0) / ROW_H))
        Relayout()
    end)

    statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    statusText:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, 8)
    statusText:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
    statusText:SetJustifyH("LEFT")
end

-- ---------------------------------------------------------------------------
-- Dashboard embedding
-- ---------------------------------------------------------------------------
-- The Dashboard hosts this panel directly inside its own window instead of the
-- Loot Feed owning a window of its own -- see UncappedDashboard_UI.lua, which
-- calls EmbedInto once (to build the frame into its content group) and Activate
-- every time the Loot Feed tab is selected.
LF.UI = LF.UI or {}

function LF.UI.EmbedInto(parent)
    BuildFrame(parent)
    frame:Show()
    return frame
end

function LF.UI.Activate()
    if not frame then return end
    LF.GetDB()          -- make sure saved filters exist before they are painted
    ApplyMode()         -- which refreshes the filter widgets for the feed view
end

-- Called by the engine whenever loot arrives or the watchlist changes. Cheap
-- when the tab isn't on screen, which matters because loot can arrive far
-- faster than a player clicks.
function LF.UI.Refresh()
    if not frame or not frame:IsShown() then return end
    Rebuild()
end

-- Content-panel width (not window width) the rows need: an icon (20) plus a
-- name/link column wide enough for a long item name next to a player name
-- (~330) plus the watched marker (16) and the scrollbar gutter (20), plus this
-- panel's own PAD on each side and the embedded group's 6px padding = 420.
--
-- The header row is the real floor now: three buttons (92 + 92 + 80 + gaps =
-- 276) on the left and the search box (220) on the right cannot overlap, so
-- 420 is still comfortably above what it needs.
function LF.UI.GetMinWidth()
    return 460
end

-- Full WINDOW height (not content height) for a list worth scrolling: 10 rows
-- at the taller two-line row height (300) plus the header (108: view buttons
-- over the two-row filter bar) and footer (26) = 434, plus the Dashboard
-- window's own chrome (title/banner + margins) ~72 = 498. Rounded up so the
-- list never opens shorter than the nav column beside it.
function LF.UI.GetMinHeight()
    return 512
end
