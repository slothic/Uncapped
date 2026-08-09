-- UncappedLootFeed_Popout -- the stand-alone loot window (report #125).
--
-- WHAT WAS ACTUALLY ASKED FOR
--   "Make a popout loot window like the Stat feed. I like being able to see
--   what I am looting and what is going into my vault. This was trackable
--   through the personal channel" -- plus, from two other reports, "make the
--   Loot Feed window resizeable".
--
--   So the shape of the answer is fixed by the request: a small window you leave
--   open while you play, not a tab you have to go and open. The Dashboard tab
--   stays exactly as it is and keeps its job -- searching 25,000 items to build a
--   watchlist is not something you do in a 340px window -- and both views read
--   the same ring, through the same filters, painted by the same row factory.
--   Nothing here re-implements the feed; it is a second window onto it.
--
-- STYLE: StatFeedPlus, as asked
--   The summary block at the top, the paired hairline dividers under it, the
--   quiet GameFontHighlightSmall stream below and the resize grip in the corner
--   are all StatFeedPlus's rhythm. The CHROME is UncappedUIKit's window, which
--   resolves to the same dark dialog backdrop and gold title StatFeedPlus draws
--   by hand -- so it matches the reference and the rest of the suite at once,
--   and inherits drag, resize, Escape-to-close and saved geometry instead of
--   reimplementing four things that are easy to get subtly wrong.
--
-- THROTTLED REPAINTS
--   A tab repaints when a player clicks; this window is open while an AoE pull
--   dies, and every single loot line calls into the engine's Notify. So a change
--   only marks the window dirty and an OnUpdate repaints at most a few times a
--   second. Without that, a big pull repaints a 12-row list 60 times in a
--   second, all of it thrown away before a frame is drawn.

local LF = _G.UncappedLootFeed
if not LF then return end

local UIKit = _G.UncappedUIKit
if not UIKit or not UIKit.CreateWindow then
    -- No chat noise here: the Dashboard tab already tells the player when
    -- UncappedUI is missing, and one warning is enough. The engine's
    -- LF.TogglePopout says so too when someone actually asks for the window.
    return
end

local Rows = LF.Rows
if not Rows then return end

local PAD        = 14
local SUMMARY_H  = 58
-- Taken from the filter bar itself rather than restated, so the window cannot
-- end up reserving a different amount of room than the bar actually needs.
local FILTER_H   = LF.Filters and LF.Filters.HEIGHT or 66
local FOOTER_H   = 20
local TITLE_H    = 30

local DEFAULT_W, DEFAULT_H = 380, 400
local MIN_W, MIN_H = 320, 240

local win, summary, filterHost, filters, listHost, scroll, statusText, compactBtn
local rows = {}
local visibleRows = 6
local list = {}
local dirty = false
local sinceRepaint, sinceClock = 0, 0

local Popout = {}
LF.Popout = Popout

local function Data()
    return _G.UncappedLootFeedData
end

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------
local function Comma(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local k
    repeat s, k = string.gsub(s, "^(%-?%d+)(%d%d%d)", "%1,%2") until k == 0
    return s
end

local function Duration(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    return string.format("%02d:%02d:%02d",
        math.floor(seconds / 3600), math.floor((seconds % 3600) / 60), seconds % 60)
end

-- StatFeedPlus's divider: a black hairline with a lighter one directly under it.
-- Two textures rather than one 2px line -- the pair is what gives it the etched
-- look instead of a drawn-on stripe.
local function Divider(parent, y)
    local shadow = parent:CreateTexture(nil, "ARTWORK")
    shadow:SetTexture(0, 0, 0, 0.85)
    shadow:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, y)
    shadow:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PAD, y)
    shadow:SetHeight(1)

    local light = parent:CreateTexture(nil, "ARTWORK")
    light:SetTexture(0.55, 0.55, 0.55, 0.55)
    light:SetPoint("TOPLEFT", shadow, "BOTTOMLEFT", 0, -1)
    light:SetPoint("TOPRIGHT", shadow, "BOTTOMRIGHT", 0, -1)
    light:SetHeight(1)

    return shadow, light
end

local function SummaryRow(parent, index, label, r, g, b)
    local y = -4 - (index - 1) * 17

    local name = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, y)
    name:SetText(label)
    name:SetTextColor(1, 0.82, 0)

    local value = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    value:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PAD, y)
    value:SetJustifyH("RIGHT")
    value:SetTextColor(r, g, b)
    return value
end

-- ---------------------------------------------------------------------------
-- Painting
-- ---------------------------------------------------------------------------
local function BuildList()
    local out = {}
    for _, e in ipairs(LF.GetFeed()) do
        out[#out + 1] = Rows.Describe(e)
    end
    return out
end

local function AcquireRow(i)
    local row = rows[i]
    if row then return row end

    row = Rows.Create(listHost)
    row:SetPoint("TOPLEFT", listHost, "TOPLEFT", 0, -(i - 1) * Rows.H)
    row:SetPoint("TOPRIGHT", listHost, "TOPRIGHT", -18, -(i - 1) * Rows.H)
    rows[i] = row
    return row
end

local function Relayout()
    if not win or not win:IsShown() then return end

    local offset = FauxScrollFrame_GetOffset(scroll) or 0
    for i = 1, visibleRows do
        Rows.Paint(AcquireRow(i), list[i + offset])
    end
    for i = visibleRows + 1, #rows do
        rows[i]:Hide()
        rows[i].entry = nil
    end

    FauxScrollFrame_Update(scroll, #list, visibleRows, Rows.H)
end

local function UpdateSummary()
    if not summary or not summary:IsShown() then return end

    local items, vault, watched, elapsed = LF.SessionStats()
    summary.items:SetText(Comma(items) .. "  |cff808080(" .. Duration(elapsed) .. ")|r")
    summary.vault:SetText(Comma(vault))
    summary.watched:SetText(Comma(watched))
end

local function UpdateStatus()
    if not statusText then return end

    -- The HIDDEN count is the important half. An empty feed with a filter on
    -- looks exactly like a feed that is receiving nothing, which is the shape
    -- #214 was reported in -- so it must never be silent about it.
    local hidden = LF.FilteredOutCount()
    if hidden > 0 then
        statusText:SetText(string.format(
            "|cff888888%d shown|r  |cffffd100%d hidden by filters|r",
            LF.FeedCount() - hidden, hidden))
    else
        statusText:SetText(string.format(
            "|cff888888%d loot lines  --  %d watched|r", LF.FeedCount(), LF.WatchCount()))
    end
end

local function Repaint()
    list = BuildList()
    UpdateSummary()
    UpdateStatus()
    if filters then filters.Refresh() end
    Relayout()
end

-- ---------------------------------------------------------------------------
-- Compact mode
-- ---------------------------------------------------------------------------
-- StatFeedPlus's collapse, pointed at what matters here: the summary block and
-- the filter bar fold away and the STREAM keeps its space, because the stream is
-- the thing someone leaves this window open for.
local function ApplyCompact()
    local db = LF.GetDB()
    local compact = db.popoutCompact and true or false

    for _, tex in ipairs(win.dividers) do
        if compact then tex:Hide() else tex:Show() end
    end
    if compact then
        summary:Hide()
        filterHost:Hide()
    else
        summary:Show()
        filterHost:Show()
    end

    listHost:ClearAllPoints()
    listHost:SetPoint("TOPLEFT", win, "TOPLEFT", PAD,
        compact and -(TITLE_H + 4) or -(TITLE_H + SUMMARY_H + FILTER_H + 12))
    listHost:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -PAD, FOOTER_H)

    if compactBtn then
        compactBtn:SetNormalTexture(compact
            and "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up"
            or "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up")
        compactBtn:SetPushedTexture(compact
            and "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Down"
            or "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Down")
    end

    Repaint()
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
local function Build()
    if win then return end

    local db = LF.GetDB()
    db.window = db.window or {}

    win = UIKit.CreateWindow({
        name       = "UncappedLootFeedWindow",
        title      = "Loot Feed",
        width      = DEFAULT_W,
        height     = DEFAULT_H,
        minWidth   = MIN_W,
        minHeight  = MIN_H,
        resizable  = true,
        movable    = true,
        strata     = "MEDIUM",
        db         = db.window,

        --[[ ⚠ ESCAPE MUST NOT CLOSE THIS. Report #384, four minutes after the
             window went live: "Escape closes the popout loot window".

             UISpecialFrames is Blizzard's "Escape closes this" list, and it is
             meant for windows you open, use and dismiss -- a loot roll, a
             vendor, a talent pane. This is not one of those. It is a panel you
             place once, size once and leave up while you play, and Escape gets
             pressed constantly for reasons that have nothing to do with it:
             opening the game menu, clearing a target, stopping a cast. Every
             one of those was taking the window away.

             ★ THE REALM HAS ALREADY DECIDED THIS EXACT QUESTION. UncappedChat
             came off UISpecialFrames for the identical complaint ("Uchat keeps
             closing when pressing Esc key meaning we have too constantly open it
             back up"), and its reasoning transfers whole -- Blizzard's own chat
             frames are not on the list either. Leaving this window on it while
             the chat window is off it would be the same frame class behaving two
             different ways in one suite.

             The kit's OTHER two windows keep the default on purpose: the
             Dashboard is a big panel you deliberately open and dismiss, which is
             exactly what the list is for, and the Demo is a dev fixture.

             Still three ways to close it: the titlebar X, the Pop out button on
             the Loot Feed tab, and /lootfeed window. ]]
        escapeClose = false,
    })

    -- Closing by the X or by Escape must be remembered, or the window comes
    -- back on the next login and reads as a bug rather than a feature.
    win:SetScript("OnHide", function()
        local d = LF.GetDB()
        if d then d.popout = false end
    end)

    -- ---- summary ----------------------------------------------------------
    summary = CreateFrame("Frame", nil, win)
    summary:SetPoint("TOPLEFT", win, "TOPLEFT", 0, -TITLE_H)
    summary:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, -TITLE_H)
    summary:SetHeight(SUMMARY_H)

    summary.items = SummaryRow(summary, 1, "Looted this session", 0.35, 1, 0.2)
    summary.vault = SummaryRow(summary, 2, "Went to your Vault", 0.25, 0.75, 1)
    summary.watched = SummaryRow(summary, 3, "Watched drops", 1, 0.82, 0)

    -- One above the filter bar and one below it, so the filters read as their
    -- own band rather than as loose furniture floating over the stream.
    local topA, topB = Divider(win, -(TITLE_H + SUMMARY_H))
    local botA, botB = Divider(win, -(TITLE_H + SUMMARY_H + FILTER_H + 6))
    win.dividers = { topA, topB, botA, botB }

    -- ---- filters ----------------------------------------------------------
    filterHost = CreateFrame("Frame", nil, win)
    filterHost:SetPoint("TOPLEFT", win, "TOPLEFT", 0, -(TITLE_H + SUMMARY_H + 4))
    filterHost:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, -(TITLE_H + SUMMARY_H + 4))
    filterHost:SetHeight(FILTER_H)

    filters = LF.Filters.Build(filterHost, {
        x = PAD,
        y = -4,
        width = 92,
        rightPad = PAD,
        onChange = function()
            if scroll then FauxScrollFrame_SetOffset(scroll, 0) end
            local sb = _G["UncappedLootFeedWindowScrollScrollBar"]
            if sb then sb:SetValue(0) end
            Repaint()
        end,
    })

    -- ---- list -------------------------------------------------------------
    listHost = CreateFrame("Frame", nil, win)

    -- Named, because mouse-wheel scrolling needs the auto-created
    -- "<name>ScrollBar" global and an anonymous frame has no predictable one.
    scroll = CreateFrame("ScrollFrame", "UncappedLootFeedWindowScroll", listHost, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", listHost, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", listHost, "BOTTOMRIGHT", -20, 0)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, Rows.H, Relayout)
    end)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local sb = _G["UncappedLootFeedWindowScrollScrollBar"]
        if sb then sb:SetValue(sb:GetValue() - (delta or 0) * Rows.H) end
    end)
    scroll:SetScript("OnSizeChanged", function(self, w, h)
        visibleRows = math.max(1, math.floor((h or 0) / Rows.H))
        Relayout()
    end)

    statusText = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    statusText:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", PAD, 8)
    statusText:SetPoint("RIGHT", win, "RIGHT", -(PAD + 18), 0)
    statusText:SetJustifyH("LEFT")

    -- ---- compact toggle ---------------------------------------------------
    compactBtn = CreateFrame("Button", nil, win)
    compactBtn:SetWidth(24)
    compactBtn:SetHeight(24)
    -- Clear of the close button, which is 32 wide anchored at -6 and so occupies
    -- everything from -38 rightwards.
    compactBtn:SetPoint("TOPRIGHT", win, "TOPRIGHT", -40, -6)
    compactBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")
    if compactBtn:GetHighlightTexture() then
        compactBtn:GetHighlightTexture():SetBlendMode("ADD")
    end
    compactBtn:SetScript("OnClick", function()
        local d = LF.GetDB()
        d.popoutCompact = not d.popoutCompact
        ApplyCompact()
    end)
    compactBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(LF.GetDB().popoutCompact and "Show totals and filters" or "Just the loot")
        GameTooltip:Show()
    end)
    compactBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- ---- ticker -----------------------------------------------------------
    -- One OnUpdate for both jobs: draining the dirty flag (see the note at the
    -- top of this file) and ticking the session clock, which has to keep moving
    -- even when no loot is arriving. Two accumulators, because they run at
    -- different rates and sharing one made each of them wrong sometimes.
    win:SetScript("OnUpdate", function(self, delta)
        delta = delta or arg1 or 0
        sinceRepaint = sinceRepaint + delta
        sinceClock = sinceClock + delta

        if dirty and sinceRepaint >= 0.2 then
            dirty, sinceRepaint, sinceClock = false, 0, 0
            Repaint()
        elseif sinceClock >= 1.0 then
            sinceClock = 0
            UpdateSummary()
        end
    end)

    ApplyCompact()
end

-- ---------------------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------------------
function Popout.Show()
    Build()
    LF.GetDB().popout = true
    win:Show()
    Repaint()
    return true
end

function Popout.Hide()
    if not win then return false end
    win:Hide()          -- OnHide clears db.popout
    return false
end

function Popout.IsShown()
    return win and win:IsShown() and true or false
end

function Popout.Toggle()
    if Popout.IsShown() then return Popout.Hide() end
    return Popout.Show()
end

-- Cheap when the window is closed, which matters because loot arrives far
-- faster than anyone clicks: mark and let the ticker do the work.
LF.RegisterView(function()
    if win and win:IsShown() then dirty = true end
end)

-- Reopen where the player left it. PLAYER_LOGIN rather than ADDON_LOADED: the
-- saved variables are loaded by then, and so is the Dashboard, so a window that
-- was open at logout is open again without a click.
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function()
    local db = LF.GetDB()
    if db and db.popout then Popout.Show() end
end)
