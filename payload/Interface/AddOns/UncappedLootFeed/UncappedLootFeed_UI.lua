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
--   baked table is only consulted where there is no link to use: the watchlist,
--   the search browser, and Vault rows (which arrive as a bare item id -- see the
--   ULFV note in UncappedLootFeed.lua). For those the link is looked up LAZILY at
--   paint time rather than captured, because a Vault item is very often one the
--   client has not cached yet and a link captured at capture time would stay nil
--   for the rest of the session.
--
-- FILTERS  (#214)
--   The first column of a feed row is its SOURCE -- "You", another player's name,
--   or "Vault" -- because after the Vault cutover that is the thing a player most
--   needs to tell apart. The filter row toggles those three sources and applies a
--   quality floor; the engine owns the actual predicate (LF.Passes), this file
--   only draws the switches.

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
-- View buttons (row 1) + source chips (row 2) + quality/reset (row 3).
local HEADER_H  = 100
local FOOTER_H  = 26    -- status line below it

local CHECK_TEX = "Interface\\Buttons\\UI-CheckBox-Check"

-- The Vault's own blue, the same one UncappedVault prefixes its chat lines with,
-- so "this went to the Vault" reads as the same thing in both places.
local VAULT_COLOR = "|cff40c0ff"

local frame, scroll, searchBox, clearBtn, statusText
local feedBtn, watchBtn
local filterRow, qualityBtn, watchedBtn, resetBtn
local sourceChips = {}
local rows = {}
local visibleRows = 8

local mode = "feed"     -- "feed" | "watch"
local list = {}         -- what the rows are currently painted from

-- The quality floor cycles rather than dropping a menu down: the values are a
-- short ordered ladder, and a cycling chip uses only widgets already proven in
-- this panel. Right-click walks it backwards so the last step is never a full
-- lap. "Any" is first so the default is one click from anywhere.
local QUALITY_STEPS = {
    { value = 0, label = "Any",       hex = "|cffffffff" },
    { value = 2, label = "Uncommon+", hex = "|cff1eff00" },
    { value = 3, label = "Rare+",     hex = "|cff0070dd" },
    { value = 4, label = "Epic+",     hex = "|cffa335ee" },
    { value = 5, label = "Legendary", hex = "|cffff8000" },
}

local function QualityIndex(value)
    for i, step in ipairs(QUALITY_STEPS) do
        if step.value == (value or 0) then return i end
    end
    return 1
end

local function Data()
    return _G.UncappedLootFeedData
end

-- ---------------------------------------------------------------------------
-- List building
-- ---------------------------------------------------------------------------
-- A Vault row arrives as a bare item id. Prefer a real link when the client has
-- one (identical rendering to a bag row, tooltip and shift-click included), and
-- fall back to the baked table's coloured name when it does not -- which is the
-- common case for something the player has never held.
local function ResolveLink(e)
    if e.link then return e.link end
    if not e.id then return nil end
    local _, live = GetItemInfo(e.id)
    return live
end

-- One shape for both views so PaintRow stays a single function:
--   { id, label, icon, watched, link }
local function BuildList()
    local D = Data()
    local out = {}

    if mode == "feed" then
        for _, e in ipairs(LF.GetFeed()) do
            if e.overflow then
                -- Tail of a batched bulk deposit -- see ULFVX in the engine.
                out[#out + 1] = {
                    label = VAULT_COLOR .. "Vault|r  |cffaaaaaa... and "
                        .. e.overflow .. " more stack" .. ((e.overflow == 1) and "" or "s") .. " banked|r",
                    plain = true,
                }
            else
                -- First column is the SOURCE, and Vault gets its own colour: the
                -- whole point of #214 is being able to see at a glance that the
                -- item went somewhere other than your bags.
                local source
                if e.src == LF.SRC_VAULT then
                    source = VAULT_COLOR .. "Vault|r"
                elseif e.mine then
                    source = "|cff40ff40" .. (e.who or "You") .. "|r"
                else
                    source = "|cffaaaaaa" .. (e.who or "?") .. "|r"
                end

                local link = ResolveLink(e)
                local name = link or (D and D.ColoredName(e.id)) or ("item " .. tostring(e.id))
                local suffix = (e.count and e.count > 1) and ("|cffffffff x" .. e.count .. "|r") or ""

                out[#out + 1] = {
                    id      = e.id,
                    link    = link,
                    label   = source .. "  " .. name .. suffix,
                    watched = LF.IsWatched(e.id),
                    vault   = (e.src == LF.SRC_VAULT),
                }
            end
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

    -- The batched-deposit tail has no item behind it, so there is nothing to
    -- link and nothing to watch -- say what it is instead of showing a bare
    -- "click to watch" on a row that does not respond to clicks.
    if entry.plain then
        GameTooltip:SetText("Vault", 0.25, 0.75, 1)
        GameTooltip:AddLine("A bulk deposit banked more stacks than the feed lists individually.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
        return
    end

    if entry.link then
        GameTooltip:SetHyperlink(entry.link)
    elseif entry.id then
        GameTooltip:SetHyperlink("item:" .. entry.id)
    end
    if entry.vault then
        GameTooltip:AddLine("Went straight to your Vault, not your bags.", 0.25, 0.75, 1)
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

    -- Vault rows get a faint blue wash behind them as well as the "Vault" label,
    -- so the distinction survives a player skimming the list rather than reading
    -- the first word of every line.
    row.tint = row:CreateTexture(nil, "BACKGROUND")
    row.tint:SetAllPoints(row)
    row.tint:SetTexture(0.10, 0.42, 0.68, 0.15)
    row.tint:Hide()

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
    -- A plain row (the batched-deposit tail) has no item, so no icon to draw --
    -- IconFor would hand back the question mark, which reads like a broken item.
    if entry.plain then
        row.icon:SetTexture(nil)
    else
        row.icon:SetTexture(D and D.IconFor(entry.id) or nil)
    end
    row.text:SetText(entry.label or "")
    if entry.watched then row.check:Show() else row.check:Hide() end
    if entry.vault or entry.plain then row.tint:Show() else row.tint:Hide() end
    row:Show()
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
-- Filters and view switching
-- ---------------------------------------------------------------------------
-- SOURCE chips are lit when the source is INCLUDED, so "lit = you can see it".
-- The inverse (lit = filtered out) reads the same on screen and means the
-- opposite, which is exactly the ambiguity that makes a filter feel broken.
--
-- The RESTRICTION controls -- quality floor, "Watched only" -- are lit when they
-- are doing something, and they live on their own row for that reason: a row
-- where half the chips mean "included" and half mean "restricted" is unreadable
-- however each one is labelled.
local function RefreshFilterWidgets()
    for _, chip in ipairs(sourceChips) do
        UIKit.SetButtonActive(chip.btn, LF.GetFilter(chip.key) ~= false)
    end

    if watchedBtn then
        UIKit.SetButtonActive(watchedBtn, LF.GetFilter("watchedOnly") == true)
    end

    if qualityBtn then
        local step = QUALITY_STEPS[QualityIndex(LF.GetFilter("minQuality"))]
        qualityBtn.text:SetText(step.hex .. step.label .. "|r")
        UIKit.SetButtonActive(qualityBtn, step.value > 0)
    end

    if resetBtn then
        if LF.AnyFilterActive() then resetBtn:Show() else resetBtn:Hide() end
    end
end

local function ApplyMode()
    UIKit.SetButtonActive(feedBtn, mode == "feed")
    UIKit.SetButtonActive(watchBtn, mode == "watch")

    if mode == "feed" then
        searchBox:Hide()
        filterRow:Show()
        clearBtn:Show()
        RefreshFilterWidgets()
    else
        searchBox:Show()
        filterRow:Hide()
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

    clearBtn = UIKit.CreateButton(frame, "Clear", 70, 24)
    clearBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(PAD + 4), -10)
    clearBtn:SetScript("OnClick", function() LF.ClearFeed() end)

    -- ---- filter rows (feed view) -----------------------------------------
    -- Everything filter-related lives in one container so switching views is a
    -- single Show/Hide instead of a list of widgets that has to be kept in step
    -- with whatever gets added next.
    filterRow = CreateFrame("Frame", nil, frame)
    filterRow:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    filterRow:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    filterRow:SetHeight(HEADER_H)

    local CHIP_H, CHIP_GAP = 22, 6

    -- A change that alters what is on screen must also drop the scroll offset:
    -- a shorter list at the old offset paints empty, which looks exactly like
    -- the filter having eaten everything.
    local function AfterFilterChange()
        RefreshFilterWidgets()
        if scroll then FauxScrollFrame_SetOffset(scroll, 0) end
        local sb = _G["UncappedLootFeedScrollScrollBar"]
        if sb then sb:SetValue(0) end
        Rebuild()
    end

    local function Tooltip(button, title, body)
        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(title)
            GameTooltip:AddLine(body, 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    -- Row 2: which SOURCES are shown at all. Lit = included.
    local CHIPS = {
        { key = "showBags",   label = "Bags",   tip = "Loot that landed in your bags." },
        { key = "showVault",  label = "Vault",  tip = "Loot the server routed straight to your Vault. These never appear in the chat loot log at all, so this feed is the only place you see them." },
        { key = "showOthers", label = "Others", tip = "Loot other players in your group picked up." },
    }

    local CHIP_W = 74
    local prev
    for _, spec in ipairs(CHIPS) do
        local btn = UIKit.CreateButton(filterRow, spec.label, CHIP_W, CHIP_H)
        if prev then
            btn:SetPoint("LEFT", prev, "RIGHT", CHIP_GAP, 0)
        else
            btn:SetPoint("TOPLEFT", filterRow, "TOPLEFT", PAD, -40)
        end
        prev = btn

        btn:SetScript("OnClick", function()
            -- `== false` rather than `not`: these default to nil-means-true for
            -- a save file written before the filters existed, and `not nil` would
            -- turn the first click into a no-op that looks like a dead button.
            LF.SetFilter(spec.key, LF.GetFilter(spec.key) == false)
            AfterFilterChange()
        end)
        Tooltip(btn, spec.label, spec.tip)

        sourceChips[#sourceChips + 1] = { key = spec.key, btn = btn }
    end

    -- Row 3: RESTRICTIONS, plus the escape hatch out of any filter state.
    UIKit.CreateText(filterRow, "disableSmall", "TOPLEFT", filterRow, "TOPLEFT", PAD + 2, -72, "Quality")

    qualityBtn = UIKit.CreateButton(filterRow, "Any", 100, CHIP_H)
    qualityBtn:SetPoint("TOPLEFT", filterRow, "TOPLEFT", PAD + 56, -68)
    qualityBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    qualityBtn:SetScript("OnClick", function(self, button)
        local i = QualityIndex(LF.GetFilter("minQuality"))
        local step = (button == "RightButton") and -1 or 1
        i = ((i - 1 + step) % #QUALITY_STEPS) + 1
        LF.SetFilter("minQuality", QUALITY_STEPS[i].value)
        AfterFilterChange()
    end)
    qualityBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Minimum quality")
        GameTooltip:AddLine("Hide anything below this. Click to step up, right-click to step back.", 0.7, 0.7, 0.7, true)
        GameTooltip:AddLine("Items whose quality this client doesn't know yet are always shown.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    qualityBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    watchedBtn = UIKit.CreateButton(filterRow, "Watched only", 100, CHIP_H)
    watchedBtn:SetPoint("LEFT", qualityBtn, "RIGHT", CHIP_GAP, 0)
    watchedBtn:SetScript("OnClick", function()
        LF.SetFilter("watchedOnly", not LF.GetFilter("watchedOnly"))
        AfterFilterChange()
    end)
    Tooltip(watchedBtn, "Watched only",
        "Show only items on your watchlist. Everything else is still being recorded -- turn this off to see it again.")

    -- Only present when something is actually filtering, so it reads as "undo
    -- what you just did" rather than as a permanent button nobody knows the
    -- effect of. Hidden state is set by RefreshFilterWidgets.
    resetBtn = UIKit.CreateButton(filterRow, "Show all", 80, CHIP_H)
    resetBtn:SetPoint("TOPRIGHT", filterRow, "TOPRIGHT", -(PAD + 4), -68)
    resetBtn:SetScript("OnClick", function()
        LF.ResetFilters()
        AfterFilterChange()
    end)
    resetBtn:Hide()

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
    LF.GetDB()          -- make sure saved filters exist before they are painted
    ApplyMode()         -- which calls RefreshFilterWidgets for the feed view
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
--
-- The filter chip row is narrower than that (4 x 66 + 3 x 5 gaps + padding =
-- ~307), so it does not raise the floor -- deliberately sized to fit inside the
-- width the rows already demanded rather than forcing the window wider.
function LF.UI.GetMinWidth()
    return 420
end

-- Full WINDOW height (not content height) for a list worth scrolling: 12 rows
-- (264) plus the header (100: view buttons, filter chips, quality row) and
-- footer (26) = 390, plus the Dashboard window's own chrome (title/banner +
-- margins) ~72 = 462. Rounded up so the list never opens shorter than the nav
-- column beside it.
function LF.UI.GetMinHeight()
    return 512
end
