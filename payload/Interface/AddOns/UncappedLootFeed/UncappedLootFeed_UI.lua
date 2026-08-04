-- UncappedLootFeed_UI -- the Loot Feed's Dashboard tab.
--
-- Lives inside the Dashboard's content panel (see EmbedInto at the bottom) --
-- no own backdrop/title/close/drag, since the Dashboard's master window already
-- provides all of that chrome. This replaces the standalone window the feed used
-- to build for itself.
--
-- TWO VIEWS, ONE LIST
--   "Feed" is every loot line seen this session; "Watchlist" is what you are
--   farming for, and doubles as the item browser -- typing in the search box
--   swaps the list to matches from the baked item table so you can click one to
--   start watching it. Both views share one row pool and one paint function,
--   because a row is the same thing in both: an icon, a name, and a watched
--   marker.
--
-- EVERY SLASH COMMAND IS REACHABLE HERE
--   want/add    -> search for the item, click it (or click any feed row)
--   unwant      -> click a watchlist row, or click a watched feed row
--   list        -> the Watchlist view IS the list
--   clear       -> the Clear button on the Feed view
--   The commands still work; see the note in UncappedLootFeed.lua for why.
--
-- WHY FEED ROWS RENDER THE RAW ITEM LINK
--   The link from the chat message carries the server's OWN name and quality
--   colour, so a feed row is always right even if the baked table is stale. The
--   baked table is only consulted where there is no link to use: the watchlist
--   and the search browser.

local LF = _G.UncappedLootFeed
if not LF then return end

local UIKit = _G.UncappedUIKit
if not UIKit then
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4040[Loot Feed]|r requires UncappedUI, which isn't loaded -- enable it in AddOns and reload.")
    end
    return
end

local ROW_H     = 22
local ICON_SIZE = 18
local PAD       = 12
local HEADER_H  = 68    -- view buttons + options row above the list
local FOOTER_H  = 26    -- status line below it

local CHECK_TEX = "Interface\\Buttons\\UI-CheckBox-Check"

local frame, scroll, searchBox, watchedOnlyCB, clearBtn, statusText
local feedBtn, watchBtn
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
-- One shape for both views so PaintRow stays a single function:
--   { id, label, icon, watched, link }
local function BuildList()
    local D = Data()
    local out = {}

    if mode == "feed" then
        for _, e in ipairs(LF.GetFeed()) do
            local who = e.mine and ("|cff40ff40" .. e.who .. "|r") or ("|cffaaaaaa" .. e.who .. "|r")
            local suffix = (e.count and e.count > 1) and ("|cffffffff x" .. e.count .. "|r") or ""
            out[#out + 1] = {
                id      = e.id,
                link    = e.link,
                label   = who .. "  " .. (e.link or "?") .. suffix,
                watched = LF.IsWatched(e.id),
            }
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
                watched = LF.IsWatched(hit.id),
                search  = true,
            }
        end
        return out
    end

    for _, it in ipairs(LF.GetWatchlist()) do
        out[#out + 1] = {
            id      = it.id,
            label   = D and D.ColoredName(it.id, it.name, it.q) or it.name,
            watched = true,
        }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Rows
-- ---------------------------------------------------------------------------
local function OnRowClick(self)
    local entry = self.entry
    if not entry or not entry.id then return end

    -- Shift-click puts the link in whatever edit box is open, which is what
    -- shift-click does everywhere else in this client.
    if IsShiftKeyDown() and entry.link and ChatEdit_InsertLink then
        ChatEdit_InsertLink(entry.link)
        return
    end

    local D = Data()
    local name = D and D.NameFor(entry.id) or nil
    local nowWatched = LF.ToggleWatch(entry.id, name)

    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|cffffd100[Loot Feed]|r %s %s.",
        nowWatched and "watching for" or "no longer watching",
        name or ("item " .. entry.id)))
end

local function OnRowEnter(self)
    local entry = self.entry
    if not entry then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if entry.link then
        GameTooltip:SetHyperlink(entry.link)
    elseif entry.id then
        GameTooltip:SetHyperlink("item:" .. entry.id)
    end
    GameTooltip:AddLine(entry.watched and "Click to stop watching" or "Click to watch this item", 0.7, 0.7, 0.7)
    if entry.link then
        GameTooltip:AddLine("Shift-click to link it in chat", 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
end

local function AcquireRow(i)
    local row = rows[i]
    if row then return row end

    row = CreateFrame("Button", nil, frame)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -HEADER_H - (i - 1) * ROW_H)
    row:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(PAD + 22), -HEADER_H - (i - 1) * ROW_H)

    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    if row:GetHighlightTexture() then row:GetHighlightTexture():SetBlendMode("ADD") end

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetWidth(ICON_SIZE)
    row.icon:SetHeight(ICON_SIZE)
    row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)
    -- Trim the stock icon border so it sits flush next to the text.
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    row.check = row:CreateTexture(nil, "OVERLAY")
    row.check:SetWidth(16)
    row.check:SetHeight(16)
    row.check:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.check:SetTexture(CHECK_TEX)
    row.check:Hide()

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.text:SetPoint("RIGHT", row.check, "LEFT", -4, 0)
    row.text:SetJustifyH("LEFT")

    row:SetScript("OnClick", OnRowClick)
    row:SetScript("OnEnter", OnRowEnter)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    rows[i] = row
    return row
end

local function PaintRow(row, entry)
    row.entry = entry
    if not entry then
        row:Hide()
        return
    end
    local D = Data()
    row.icon:SetTexture(D and D.IconFor(entry.id) or nil)
    row.text:SetText(entry.label or "")
    if entry.watched then row.check:Show() else row.check:Hide() end
    row:Show()
end

-- ---------------------------------------------------------------------------
-- Paint
-- ---------------------------------------------------------------------------
local function UpdateStatus()
    if not statusText then return end
    if mode == "feed" then
        statusText:SetText(string.format(
            "|cff888888%d loot lines  --  %d watched  --  click a row to watch that item|r",
            LF.FeedCount(), LF.WatchCount()))
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
        PaintRow(AcquireRow(i), list[i + offset])
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
        watchedOnlyCB:Show()
        clearBtn:Show()
    else
        searchBox:Show()
        watchedOnlyCB:Hide()
        clearBtn:Hide()
    end
    Rebuild()
end

local function SetMode(newMode)
    mode = newMode
    -- Scrolling position is per-view; jumping to a new list at the old offset
    -- looks like the list is empty when it is merely scrolled past the end.
    if scroll then FauxScrollFrame_SetOffset(scroll, 0) end
    local sb = _G["UncappedLootFeedScrollScrollBar"]
    if sb then sb:SetValue(0) end
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

    -- ---- search (watchlist view) -----------------------------------------
    searchBox = UIKit.CreateSearchBox(frame, 220, 24, "Search items to watch...")
    searchBox:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(PAD + 4), -10)
    searchBox.OnQueryChanged = function()
        if scroll then FauxScrollFrame_SetOffset(scroll, 0) end
        local sb = _G["UncappedLootFeedScrollScrollBar"]
        if sb then sb:SetValue(0) end
        Rebuild()
    end
    searchBox:Hide()

    -- ---- options row (feed view) -----------------------------------------
    watchedOnlyCB = UIKit.CreateCheckbox(frame, "Watched only")
    watchedOnlyCB:SetPoint("TOPLEFT", feedBtn, "BOTTOMLEFT", -2, -6)
    watchedOnlyCB:SetScript("OnClick", function(self)
        LF.GetDB().watchedOnly = self:GetChecked() and true or false
        Rebuild()
    end)

    clearBtn = UIKit.CreateButton(frame, "Clear", 70, 22)
    clearBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(PAD + 4), -40)
    clearBtn:SetScript("OnClick", function() LF.ClearFeed() end)

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
        if sb then sb:SetValue(sb:GetValue() - delta * ROW_H) end
    end)
    scroll:SetScript("OnSizeChanged", function(self, w, h)
        visibleRows = math.max(1, math.floor(h / ROW_H))
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
    local db = LF.GetDB()
    if watchedOnlyCB then watchedOnlyCB:SetChecked(db.watchedOnly and true or false) end
    ApplyMode()
end

-- Called by the engine whenever loot arrives or the watchlist changes. Cheap
-- when the tab isn't on screen, which matters because loot can arrive far
-- faster than a player clicks.
function LF.UI.Refresh()
    if not frame or not frame:IsShown() then return end
    Rebuild()
end

-- Content-panel width (not window width) the rows need: an icon (18) plus a
-- name/link column wide enough for a long item name next to a player name
-- (~330) plus the watched marker (16) and the scrollbar gutter (20), plus this
-- panel's own PAD on each side and the embedded group's 6px padding = 420.
function LF.UI.GetMinWidth()
    return 420
end

-- Full WINDOW height (not content height) for a list worth scrolling: 12 rows
-- (264) plus the header row (68) and footer (26) = 358, plus the Dashboard
-- window's own chrome (title/banner + margins) ~72 = 430. Rounded up so the
-- list never opens shorter than the nav column beside it.
function LF.UI.GetMinHeight()
    return 480
end
