--[[
  Uncapped Quests -- the quest ledger window.

  The client can only render 25 quests: its player descriptor block has exactly
  25 quest slots and the field after them is already equipment (see
  docs\design\QUEST_LOG_CAP.md). The server holds everything past that in the
  ledger -- fully tracked, fully credited, simply not drawable by Blizzard's
  quest log. This window is where those live.

  Layout follows the Vault rework so the suite reads as one product: tab strip,
  search, category sidebar with counts, a list in the middle, a detail pane on
  the right with the actions for the selection, an info panel under it, and
  pagination along the bottom.

  Transport (see quest_ledger_comms_playerscript.cpp):
    RECEIVE  CHAT_MSG_ADDON, prefix "UNC"
             QLB:<slotted>:<total>:<limit>
             QLQ:<id>:<lvl>:<slotted>:<complete>:<zone>:<title>
             QLO:<id>:<idx>:<have>:<need>:<label>
             QLE
             QLTB:<id> / QLTO:<id>:<seq>:<chunk> / QLTD:... / QLTE:<id>
    SEND     SendAddonMessage("REAGENTBANK", ..., "WHISPER", <self>)
             QLGET | QLSLOT:<id> | QLUNSLOT:<id> | QLTXT:<id>

  Parsing is deliberately anchored per line. Never widen an existing QL* line --
  append a new command instead, or every already-published client silently drops
  the field.

  The QLT* text burst is a SEPARATE burst on purpose and is routed away from the
  ledger parser entirely (see the QLT branch in the CHAT_MSG_ADDON handler): a
  ledger line outside a QLB..QLE run is dropped, and QLE swaps the whole quest
  list, so anything landing inside a run would take the player's list with it.
]]

local UQ = UncappedQuests
local ADDON = "UncappedQuests"

local TRANSPORT_PREFIX = "REAGENTBANK"   -- what the server listens on
local PIPE = "UNC"                       -- what the server answers on

-- Rows drawn at once. The list SCROLLS rather than paginating: the frames are
-- reused and only the window into the data moves, so a 200-quest ledger costs
-- exactly as many frames as a 3-quest one.
local ROWS_VISIBLE = 13
local ROW_HEIGHT = 31
local MAX_SLOTS = 25

local TABS = {
    { key = "all",      label = "All" },
    { key = "log",      label = "In Log" },
    { key = "ledger",   label = "Ledger" },
    { key = "complete", label = "Complete" },
}

-- Live state, rebuilt wholesale on every QLB..QLE burst.
local ledger = {}          -- [questId] = { id, level, slotted, complete, zone, title, objectives = {} }
local order = {}           -- stable display order
local counts = { slotted = 0, total = 0, limit = 0 }

local db
local defaults = {
    -- Opening the quest log shows the ledger instead. On by default: Blizzard's
    -- log physically cannot show more than 25 quests, so on this realm it is an
    -- incomplete view of what you are carrying.
    takeOverQuestLog = true,
}

local ui = {}
local view = { tab = "all", zone = nil, search = "", selected = nil }

-- Any filter change scrolls back to the top: keeping the old offset against a
-- shorter result set lands you past the end, which reads as "no results".
local function ResetScroll()
    if ui.scroll then FauxScrollFrame_SetOffset(ui.scroll, 0) end
    if UncappedQuestLedgerScrollScrollBar then
        UncappedQuestLedgerScrollScrollBar:SetValue(0)
    end
end

-- ---------------------------------------------------------------------------
-- transport
-- ---------------------------------------------------------------------------

-- Published on UQ, not file-local: UncappedQuestsAvailable.lua needs the same
-- pipe to ask the server which quests are takeable, and a local here is simply
-- invisible over there.
function UQ.Send(msg)
    SendAddonMessage(TRANSPORT_PREFIX, msg, "WHISPER", UnitName("player"))
end

local Send = UQ.Send

-- ---------------------------------------------------------------------------
-- quest text -- the description and objectives paragraphs
--
-- Blizzard's quest log reads these off the client's own quest template. That
-- only works for a quest holding one of the 25 log slots: everything else in
-- the ledger has NO client-side data whatsoever -- no description, no
-- objectives text -- because the template only ever reaches the client through
-- the quest log. (CMSG_QUEST_QUERY does fetch a template into the client cache
-- for any quest, and the server answers it, but 3.3.5a exposes no Lua accessor
-- for a cached template with no log slot: GetQuestLogQuestText is indexed by
-- log entry, and that is the whole set the ledger exists to escape.)
--
-- So: the client's own copy when there is a log slot, free and instant, and
-- otherwise ask the server -- for the SELECTED quest only, never for the list.
-- ---------------------------------------------------------------------------

-- [questId] = { state = "asking"|"ready", asked = <time>, desc = "", obj = "" }
local questText = {}
local textIncoming = {}           -- [questId] = { desc = {}, obj = {} } mid-burst

-- A server reply that never comes must not leave the pane saying "Loading..."
-- for the rest of the session -- an old worldserver, or a quest that has since
-- left the ledger, both look like silence from here.
local TEXT_TIMEOUT = 6

-- The client normally does these substitutions itself. Server-sent text is raw,
-- so they happen here: $B/$b line break, $N name, $C class, $R race, and
-- $Gmale:female; gendered wording.
-- Replacements go in as FUNCTIONS, not as strings: gsub reads '%' in a
-- replacement string as a capture reference and throws on a stray one, and
-- these values are names we do not control.
local function Substitute(s)
    if not s or s == "" then return "" end

    -- $G first: it is the only token carrying its own punctuation, and running
    -- the others first would have them chew through its arguments.
    local male = (UnitSex("player") == 2)
    s = s:gsub("%$[Gg]([^:;]*):([^;]*);", function(m, f) return male and m or f end)

    s = s:gsub("%$[Bb]", function() return "\n" end)
    s = s:gsub("%$[Nn]", function() return UnitName("player") or "" end)
    s = s:gsub("%$[Cc]", function() return UnitClass("player") or "" end)
    s = s:gsub("%$[Rr]", function() return UnitRace("player") or "" end)
    return s
end

-- Chunks 1..n back into one string, stopping at the first gap rather than
-- letting table.concat throw on a hole. A truncated paragraph beats a Lua error
-- in the middle of drawing the window.
local function Join(parts)
    local out = {}
    local i = 1
    while parts[i] do
        out[i] = parts[i]
        i = i + 1
    end
    return table.concat(out)
end

-- The client's own copy, for a quest that currently holds a log slot.
--
-- GetQuestLogQuestText answers for whatever SelectQuestLogEntry last picked, so
-- the selection is moved and put straight back: it is what Blizzard's quest log
-- and the world map both read to decide which quest they are showing, and
-- leaving it moved would quietly retarget them.
local function LocalQuestText(questID)
    local index = UQ.QuestLogIndex and UQ.QuestLogIndex(questID)
    if not index then return nil end

    local previous = GetQuestLogSelection and GetQuestLogSelection() or nil
    SelectQuestLogEntry(index)
    local desc, obj = GetQuestLogQuestText()
    if previous and previous > 0 then SelectQuestLogEntry(previous) end

    -- Already substituted and localised by the client, so it skips Substitute.
    if desc and desc ~= "" then return desc, obj or "" end
    return nil
end

-- The text for one quest, fetching it if this is the first time it has been
-- asked for. Always returns a state the detail pane can draw: "ready",
-- "asking", or "failed".
--
-- Called from the render path, so it has to be cheap on the common case and it
-- has to stop asking eventually -- a request per redraw against a server that
-- is not answering is how this ends up in a bug report about lag.
local function QuestText(questID)
    if not questID then return nil end

    local t = questText[questID]

    if t and (t.state == "ready" or t.state == "failed") then
        return t
    end

    if t and t.state == "asking" then
        if (GetTime() - (t.asked or 0)) < TEXT_TIMEOUT then return t end
        if (t.tries or 0) >= 2 then
            questText[questID] = { state = "failed" }
            return questText[questID]
        end
        t.asked, t.tries = GetTime(), (t.tries or 0) + 1
        Send("QLTXT:" .. questID)
        return t
    end

    local desc, obj = LocalQuestText(questID)
    if desc then
        questText[questID] = { state = "ready", desc = desc, obj = obj }
        return questText[questID]
    end

    questText[questID] = { state = "asking", asked = GetTime(), tries = 1 }
    Send("QLTXT:" .. questID)
    return questText[questID]
end

-- One quest's text burst. Routed here rather than through the ledger parser
-- because it is not ledger data: see the note at the top of the file about what
-- a stray line inside a QLB..QLE run does to the player's quest list.
local function OnText(body)
    local beginId = body:match("^QLTB:(%d+)$")
    if beginId then
        textIncoming[tonumber(beginId)] = { desc = {}, obj = {} }
        return
    end

    local endId = body:match("^QLTE:(%d+)$")
    if endId then
        endId = tonumber(endId)
        local buf = textIncoming[endId]
        textIncoming[endId] = nil
        if buf then
            questText[endId] = {
                state = "ready",
                desc = Substitute(Join(buf.desc)),
                obj = Substitute(Join(buf.obj)),
            }
            if view.selected == endId and UQ.RenderLedger then UQ.RenderLedger() end
        end
        return
    end

    -- Chunks are placed by their sequence number rather than appended: they
    -- arrive in order today, and this costs nothing to not depend on that.
    local did, dseq, dchunk = body:match("^QLTD:(%d+):(%d+):(.*)$")
    if did then
        local buf = textIncoming[tonumber(did)]
        if buf then buf.desc[tonumber(dseq) + 1] = dchunk end
        return
    end

    local oid, oseq, ochunk = body:match("^QLTO:(%d+):(%d+):(.*)$")
    if oid then
        local buf = textIncoming[tonumber(oid)]
        if buf then buf.obj[tonumber(oseq) + 1] = ochunk end
        return
    end
end

-- ---------------------------------------------------------------------------
-- filtering
-- ---------------------------------------------------------------------------

local function ZoneName(zone)
    if UncappedZoneNames and UncappedZoneNames[zone] then
        return UncappedZoneNames[zone]
    end
    -- Negative GetZoneOrSort values are quest SORTS (professions, classes),
    -- not real zones, so there is deliberately no name for them.
    if zone and zone < 0 then return "Other" end
    return "Zone " .. tostring(zone)
end

local function MatchesTab(q)
    if view.tab == "log" then return q.slotted end
    if view.tab == "ledger" then return not q.slotted end
    if view.tab == "complete" then return q.complete end
    return true
end

local function MatchesSearch(q)
    if view.search == "" then return true end
    return tostring(q.title):lower():find(view.search, 1, true) ~= nil
end

-- Zone filter is applied LAST so the sidebar counts reflect the current tab and
-- search -- otherwise a category would advertise rows the list refuses to show.
-- Sort keys, in the order the header button cycles through them.
local SORTS = {
    { key = "name",  label = "Name" },
    { key = "area",  label = "Area" },
    { key = "level", label = "Level" },
    { key = "id",    label = "ID" },
}

local function SortValue(q, key)
    if key == "area" then
        return tostring(ZoneName(q.zone) or ""):lower()
    elseif key == "level" then
        return tonumber(q.level) or 0
    elseif key == "id" then
        return tonumber(q.id) or 0
    end
    return tostring(q.title or ""):lower()
end

local function ApplySort(list)
    local key = view.sort or "name"
    local desc = view.sortDesc and true or false

    table.sort(list, function(a, b)
        local va, vb = SortValue(a, key), SortValue(b, key)
        if va ~= vb then
            if desc then return va > vb end
            return va < vb
        end
        -- Tiebreak on id, ALWAYS ascending. table.sort is not stable, so equal
        -- keys would otherwise shuffle between redraws and the list would
        -- visibly twitch every time the ledger refreshes.
        return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
    end)

    return list
end

local function Visible(includeZone)
    local out = {}
    for _, id in ipairs(order) do
        local q = ledger[id]
        if q and MatchesTab(q) and MatchesSearch(q) then
            if not includeZone or not view.zone or q.zone == view.zone then
                out[#out + 1] = q
            end
        end
    end
    return ApplySort(out)
end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------

local function ObjectiveSummary(q)
    if q.complete then return "|cff40ff40Ready to turn in|r" end
    if #q.objectives == 0 then return "|cff808080No tracked objectives|r" end

    local done = 0
    for _, o in ipairs(q.objectives) do
        if o.have >= o.need then done = done + 1 end
    end
    return string.format("|cffb0b0b0%d / %d objectives|r", done, #q.objectives)
end

-- The detail pane's text block, in Blizzard's own order: the objectives
-- paragraph, the objective counters, then a Description header and the
-- description itself.
--
-- Placed by an explicit running offset rather than by chaining each piece under
-- the last, so a section with nothing in it leaves no gap behind -- and so the
-- scroll child can be told exactly how tall the text really is, which is what
-- the scrollbar sizes itself from.
local function LayoutDetailText(blocks)
    local y = 0

    for _, b in ipairs(blocks) do
        local fs = b.fs
        if b.text and b.text ~= "" then
            fs:SetText(b.text)
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", ui.textBody, "TOPLEFT", 0, -(y + (b.gap or 0)))
            fs:Show()
            y = y + (b.gap or 0) + math.max(fs:GetStringHeight() or 0, fs:GetHeight() or 0, 10)
        else
            fs:SetText("")
            fs:Hide()
        end
    end

    ui.textBody:SetHeight(math.max(y + 8, 1))
end

local function RenderDetail()
    local q = view.selected and ledger[view.selected]

    if not q then
        ui.detailTitle:SetText("")
        ui.detailSub:SetText("")
        LayoutDetailText({
            { fs = ui.txtObjectives, text = "" },
            { fs = ui.txtProgress,   text = "|cff808080Select a quest.|r" },
            { fs = ui.txtDescHead,   text = "" },
            { fs = ui.txtDesc,       text = "" },
            { fs = ui.txtNote,       text = "" },
        })
        ui.actionSlot:Hide()
        ui.actionUnslot:Hide()
        ui.actionPin:Hide()
        ui.actionTrack:Hide()
        return
    end

    ui.detailTitle:SetText(q.title)
    ui.detailSub:SetText(string.format("Level %d  -  %s", q.level, ZoneName(q.zone)))

    -- A new selection starts at the top of its own text, not wherever the last
    -- quest happened to be scrolled to.
    if ui.shownQuest ~= q.id then
        ui.shownQuest = q.id
        if ui.textScroll then ui.textScroll:SetVerticalScroll(0) end
        local bar = _G["UncappedQuestLedgerDetailScrollScrollBar"]
        if bar then bar:SetValue(0) end
    end

    local lines = {}
    if q.complete then
        lines[#lines + 1] = "|cff40ff40Ready to turn in.|r"
    end
    for _, o in ipairs(q.objectives) do
        local colour = (o.have >= o.need) and "40ff40" or "ffffff"
        lines[#lines + 1] = string.format("|cff%s%s: %d / %d|r", colour, o.label, o.have, o.need)
    end
    if #q.objectives == 0 and not q.complete then
        lines[#lines + 1] = "|cff808080No tracked objectives.|r"
    end

    local t = QuestText(q.id)
    local objText, descText, note = "", "", ""
    if not t or t.state == "asking" then
        note = "|cff808080Fetching quest text...|r"
    elseif t.state == "failed" then
        note = "|cff808080Quest text is unavailable right now.|r"
    else
        objText, descText = t.obj or "", t.desc or ""
        -- Some quests genuinely carry neither -- mostly the ones that complete
        -- the moment you take them. Say so rather than leaving a blank pane
        -- that reads as something still loading.
        if objText == "" and descText == "" then
            note = "|cff808080This quest has no description.|r"
        end
    end

    LayoutDetailText({
        { fs = ui.txtObjectives, text = objText,                                   gap = 0 },
        { fs = ui.txtProgress,   text = table.concat(lines, "\n"),                 gap = 10 },
        { fs = ui.txtDescHead,   text = (descText ~= "") and "|cffffd100Description|r" or "", gap = 14 },
        { fs = ui.txtDesc,       text = descText,                                  gap = 6 },
        { fs = ui.txtNote,       text = note,                                      gap = 12 },
    })

    ui.actionPin:Show()
    ui.actionPin:SetText(q.pinned and "Stop keeping in log" or "Keep in quest log")

    -- Resolved every render rather than trusted from q.slotted alone: the ledger
    -- row is server state, and the log index is client state that can be a beat
    -- behind it. Asking the log directly means the button can never offer to
    -- track a quest the client cannot actually key a watch on.
    local watchIndex = UQ.QuestLogIndex and UQ.QuestLogIndex(q.id) or nil
    ui.actionTrack:Show()
    if watchIndex then
        ui.actionTrack:Enable()
        ui.actionTrack:SetText(IsQuestWatched(watchIndex) and "Stop tracking" or "Track on screen")
    else
        ui.actionTrack:Disable()
        ui.actionTrack:SetText("Track on screen")
    end

    -- A COMPLETE quest must stay slotted: turn-in packets are keyed by slot, so
    -- pushing it out of the log would make it unhandinable until put back.
    if q.slotted then
        ui.actionSlot:Hide()
        ui.actionUnslot:Show()
        if q.complete then
            ui.actionUnslot:Disable()
        else
            ui.actionUnslot:Enable()
        end
    else
        ui.actionUnslot:Hide()
        ui.actionSlot:Show()
        -- Needs a free slot, unless it is complete, in which case the server
        -- will evict an incomplete quest to make room.
        if counts.slotted < MAX_SLOTS or q.complete then
            ui.actionSlot:Enable()
        else
            ui.actionSlot:Disable()
        end
    end
end

local function RenderSidebar()
    local all = Visible(false)

    local zones, seen = {}, {}
    for _, q in ipairs(all) do
        if not seen[q.zone] then
            seen[q.zone] = { zone = q.zone, n = 0 }
            zones[#zones + 1] = seen[q.zone]
        end
        seen[q.zone].n = seen[q.zone].n + 1
    end
    table.sort(zones, function(a, b) return ZoneName(a.zone) < ZoneName(b.zone) end)

    for i, row in ipairs(ui.zoneRows) do
        local z = zones[i - 1]          -- row 1 is the "All Categories" header
        if i == 1 then
            row.zone = nil
            row.label:SetText("All Categories")
            row.count:SetText(#all)
            row:Show()
        elseif z then
            row.zone = z.zone
            row.label:SetText(ZoneName(z.zone))
            row.count:SetText(z.n)
            row:Show()
        else
            row:Hide()
        end

        if row:IsShown() then
            local active = (row.zone == view.zone)
            row.bg:SetAlpha(active and 0.55 or 0)
            row.label:SetTextColor(active and 1 or 0.85, active and 0.82 or 0.85, active and 0 or 0.85)
        end
    end
end

local function RenderList()
    local rows = Visible(true)

    ui.header:SetText(string.format("%s  |cff808080(%d)|r",
        view.zone and ZoneName(view.zone) or "All Quests", #rows))

    -- FauxScrollFrame: Blizzard's own pattern for long lists on this client.
    -- It scrolls a VIEW over the data rather than creating a frame per row.
    FauxScrollFrame_Update(ui.scroll, #rows, ROWS_VISIBLE, ROW_HEIGHT)
    local first = FauxScrollFrame_GetOffset(ui.scroll)
    for i, row in ipairs(ui.rows) do
        local q = rows[first + i]
        if q then
            row.questId = q.id
            row.title:SetText(string.format("|cff%s[%d]|r %s",
                q.complete and "40ff40" or "ffd100", q.level, q.title))
            row.status:SetText(ObjectiveSummary(q))
            row.tag:SetText(q.slotted and "|cff60a0ffIn Log|r" or "|cff808080Ledger|r")
            row.bg:SetAlpha(view.selected == q.id and 0.55 or 0)
            row:Show()
        else
            row.questId = nil
            row:Hide()
        end
    end
end

local function Render()
    if not ui.frame or not ui.frame:IsShown() then return end

    local complete = 0
    for _, q in pairs(ledger) do
        if q.complete then complete = complete + 1 end
    end

    -- The four ledger counters live on this one line now. They used to have a
    -- panel of their own under the detail pane, which is space the quest
    -- description needs a great deal more than four numbers do.
    ui.status:SetText(string.format(
        "|cff808080%d held  -  %d of %d quest log slots used  -  %d waiting in the ledger  -  "
        .. "%d ready to turn in  -  room for %d|r",
        counts.total, counts.slotted, MAX_SLOTS,
        math.max(0, counts.total - counts.slotted), complete, counts.limit))

    RenderSidebar()
    RenderList()
    RenderDetail()
end

UQ.RenderLedger = Render

-- ---------------------------------------------------------------------------
-- frame
-- ---------------------------------------------------------------------------

local BACKDROP = {
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
}

local PANEL = {
    bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

local function Panel(parent)
    local p = CreateFrame("Frame", nil, parent)
    p:SetBackdrop(PANEL)
    p:SetBackdropColor(0, 0, 0, 0.55)
    p:SetBackdropBorderColor(0.35, 0.35, 0.4, 1)
    return p
end

local function BuildFrame()
    -- 1000 wide, up from 900: the detail pane is a quest PAGE now -- objectives
    -- and description, laid out like Blizzard's -- and 240px of column was a
    -- word or two per line.
    local f = CreateFrame("Frame", "UncappedQuestLedgerFrame", UIParent)
    f:SetWidth(1000)
    f:SetHeight(600)
    f:SetPoint("CENTER")
    f:SetBackdrop(BACKDROP)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("HIGH")
    f:Hide()
    ui.frame = f

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -16)
    title:SetText("|cffffd100Quest Ledger|r")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)

    -- tabs
    ui.tabs = {}
    for i, t in ipairs(TABS) do
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetWidth(90)
        b:SetHeight(24)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 20 + (i - 1) * 94, -44)
        b:SetText(t.label)
        b:SetScript("OnClick", function()
            view.tab, view.selected = t.key, nil
            ResetScroll()
            Render()
        end)
        ui.tabs[t.key] = b
    end

    -- sort: one button that cycles the key, and flips direction when you click
    -- the key it is already on. Cheaper on space than four headers, and the
    -- label always states the current state rather than implying it.
    local sortBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    sortBtn:SetWidth(140)
    sortBtn:SetHeight(24)
    sortBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 20 + #TABS * 94, -44)
    ui.sortBtn = sortBtn

    ui.RefreshSort = function()
        local key = view.sort or "name"
        local label = key
        for _, s in ipairs(SORTS) do
            if s.key == key then label = s.label end
        end
        sortBtn:SetText("Sort: " .. label .. (view.sortDesc and " |cff808080v|r" or " |cff808080^|r"))
    end

    sortBtn:SetScript("OnClick", function(_, button)
        local key = view.sort or "name"
        if button == "RightButton" then
            view.sortDesc = not view.sortDesc
        else
            local index = 1
            for i, s in ipairs(SORTS) do
                if s.key == key then index = i end
            end
            view.sort = SORTS[(index % #SORTS) + 1].key
        end
        ui.RefreshSort()
        ResetScroll()
        Render()
    end)
    sortBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    sortBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Sort")
        GameTooltip:AddLine("Left-click cycles name / area / level / id.", 1, 1, 1)
        GameTooltip:AddLine("Right-click reverses the order.", 1, 1, 1)
        GameTooltip:Show()
    end)
    sortBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ui.RefreshSort()

    -- search
    local searchBox = CreateFrame("EditBox", "UncappedQuestLedgerSearch", f, "InputBoxTemplate")
    searchBox:SetWidth(200)
    searchBox:SetHeight(20)
    -- Clear of the sort button, which ends at 20 + #TABS*94 + 140 = 536 with
    -- four tabs, and short of the Blizzard-log button, which starts at
    -- 1000 - 118 - 110 = 772.
    searchBox:SetPoint("TOPLEFT", f, "TOPLEFT", 552, -46)
    searchBox:SetAutoFocus(false)
    searchBox:SetScript("OnTextChanged", function(self)
        view.search = strtrim((self:GetText() or ""):lower())
        ResetScroll()
        Render()
    end)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local ph = searchBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ph:SetPoint("LEFT", searchBox, "LEFT", 4, 0)
    ph:SetText("Search quests...")
    searchBox:SetScript("OnEditFocusGained", function() ph:Hide() end)
    searchBox:SetScript("OnEditFocusLost", function(self)
        if (self:GetText() or "") == "" then ph:Show() end
    end)

    local blizz = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    blizz:SetWidth(110)
    blizz:SetHeight(22)
    blizz:SetPoint("TOPRIGHT", f, "TOPRIGHT", -118, -45)
    blizz:SetText("Blizzard log")
    blizz:SetScript("OnClick", function() UQ.OpenBlizzardQuestLog() end)
    blizz:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Open Blizzard's quest log", 1, 1, 1)
        GameTooltip:AddLine("For sharing and abandoning, which only it can do.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    blizz:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local refresh = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refresh:SetWidth(90)
    refresh:SetHeight(22)
    refresh:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -45)
    refresh:SetText("Refresh")
    refresh:SetScript("OnClick", function() Send("QLGET") end)

    -- sidebar
    local side = Panel(f)
    side:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -78)
    side:SetWidth(200)
    side:SetHeight(460)

    ui.zoneRows = {}
    for i = 1, 20 do
        local row = CreateFrame("Button", nil, side)
        row:SetWidth(188)
        row:SetHeight(20)
        row:SetPoint("TOPLEFT", side, "TOPLEFT", 6, -6 - (i - 1) * 21)

        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        row.bg:SetAlpha(0)

        row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.label:SetPoint("LEFT", row, "LEFT", 6, 0)
        row.count = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.count:SetPoint("RIGHT", row, "RIGHT", -6, 0)

        row:SetScript("OnClick", function(self)
            view.zone = self.zone
            view.selected = nil
            ResetScroll()
            Render()
        end)
        row:Hide()
        ui.zoneRows[i] = row
    end

    -- list
    local list = Panel(f)
    list:SetPoint("TOPLEFT", side, "TOPRIGHT", 12, 0)
    list:SetWidth(400)
    list:SetHeight(460)

    ui.header = list:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ui.header:SetPoint("TOPLEFT", list, "TOPLEFT", 10, -10)

    ui.scroll = CreateFrame("ScrollFrame", "UncappedQuestLedgerScroll", list, "FauxScrollFrameTemplate")
    ui.scroll:SetPoint("TOPLEFT", list, "TOPLEFT", 6, -30)
    ui.scroll:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", -28, 10)
    ui.scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, Render)
    end)

    ui.rows = {}
    for i = 1, ROWS_VISIBLE do
        local row = CreateFrame("Button", nil, list)
        row:SetWidth(384)
        row:SetHeight(30)
        row:SetPoint("TOPLEFT", list, "TOPLEFT", 8, -32 - (i - 1) * 31)

        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        row.bg:SetAlpha(0)

        row.title = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.title:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -3)
        row.title:SetWidth(300)
        row.title:SetJustifyH("LEFT")

        row.status = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.status:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 6, 3)

        row.tag = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.tag:SetPoint("RIGHT", row, "RIGHT", -6, 0)

        row:SetScript("OnClick", function(self)
            view.selected = self.questId
            Render()
        end)
        row:Hide()
        ui.rows[i] = row
    end

    -- detail: the quest page. Full column height -- the Ledger Info panel that
    -- used to sit under it moved to the status line at the bottom of the window.
    local detail = Panel(f)
    detail:SetPoint("TOPLEFT", list, "TOPRIGHT", 12, 0)
    detail:SetWidth(336)
    detail:SetHeight(460)

    ui.detailTitle = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    ui.detailTitle:SetPoint("TOPLEFT", detail, "TOPLEFT", 12, -12)
    ui.detailTitle:SetWidth(310)
    ui.detailTitle:SetJustifyH("LEFT")
    ui.detailTitle:SetTextColor(1, 0.82, 0)

    ui.detailSub = detail:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ui.detailSub:SetPoint("TOPLEFT", ui.detailTitle, "BOTTOMLEFT", 0, -4)

    -- The scrolling text block. A real ScrollFrame rather than the
    -- FauxScrollFrame the list uses: that one scrolls a fixed number of
    -- identical rows, and this is one continuous piece of prose whose height is
    -- only known once it has been laid out.
    --
    -- NAMED, because UIPanelScrollFrameTemplate builds its scrollbar as
    -- $parentScrollBar -- on an unnamed parent there is nothing to hang it off.
    --
    -- The bottom stops 104px short of the panel: the track button is the topmost
    -- of the three action rows at y=68 and is 24 tall, so that is exactly clear
    -- of all of them. Was 76 while pin (y=40) was the topmost -- this number has
    -- to move with whichever button is highest, or the prose runs under it.
    local textScroll = CreateFrame("ScrollFrame", "UncappedQuestLedgerDetailScroll", detail,
        "UIPanelScrollFrameTemplate")
    textScroll:SetPoint("TOPLEFT", ui.detailSub, "BOTTOMLEFT", 0, -10)
    textScroll:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", -30, 104)
    ui.textScroll = textScroll

    local textBody = CreateFrame("Frame", nil, textScroll)
    textBody:SetWidth(280)
    textBody:SetHeight(1)
    textScroll:SetScrollChild(textBody)
    ui.textBody = textBody

    -- Driven through the scrollbar rather than SetVerticalScroll, so the thumb
    -- follows the wheel instead of sitting still while the text moves. The
    -- direct call is the fallback for when the bar is not there.
    textScroll:EnableMouseWheel(true)
    textScroll:SetScript("OnMouseWheel", function(self, delta)
        local bar = _G["UncappedQuestLedgerDetailScrollScrollBar"]
        if bar then
            bar:SetValue(bar:GetValue() - delta * 26)
        else
            local range = self:GetVerticalScrollRange() or 0
            self:SetVerticalScroll(math.min(range, math.max(0, self:GetVerticalScroll() - delta * 26)))
        end
    end)

    -- The pieces of the page, in Blizzard's order. Widths are set here and the
    -- vertical placement is done per render by LayoutDetailText.
    local function TextLine(font, r, g, b)
        local fs = textBody:CreateFontString(nil, "OVERLAY", font)
        fs:SetWidth(280)
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("TOP")
        fs:SetPoint("TOPLEFT", textBody, "TOPLEFT", 0, 0)
        if r then fs:SetTextColor(r, g, b) end
        return fs
    end

    ui.txtObjectives = TextLine("GameFontHighlightSmall")            -- objectives paragraph
    ui.txtProgress   = TextLine("GameFontHighlightSmall")            -- the counters
    ui.txtDescHead   = TextLine("GameFontNormalSmall")               -- "Description"
    ui.txtDesc       = TextLine("GameFontHighlightSmall", 0.9, 0.9, 0.9)
    ui.txtNote       = TextLine("GameFontDisableSmall")              -- fetching / unavailable

    ui.actionSlot = CreateFrame("Button", nil, detail, "UIPanelButtonTemplate")
    ui.actionSlot:SetWidth(296); ui.actionSlot:SetHeight(24)
    ui.actionSlot:SetPoint("BOTTOM", detail, "BOTTOM", 0, 12)
    ui.actionSlot:SetText("Show in Quest Log")
    ui.actionSlot:SetScript("OnClick", function()
        if view.selected then Send("QLSLOT:" .. view.selected) end
    end)

    ui.actionUnslot = CreateFrame("Button", nil, detail, "UIPanelButtonTemplate")
    ui.actionUnslot:SetWidth(296); ui.actionUnslot:SetHeight(24)
    ui.actionUnslot:SetPoint("BOTTOM", detail, "BOTTOM", 0, 12)
    ui.actionUnslot:SetText("Move to Ledger")
    ui.actionUnslot:SetScript("OnClick", function()
        if view.selected then Send("QLUNSLOT:" .. view.selected) end
    end)

    -- Pin: opt this quest out of the automatic zone management, so it stays in
    -- the log wherever you walk. Sits above the slot/unslot button, which share
    -- one anchor because only one of them is ever shown.
    ui.actionPin = CreateFrame("Button", nil, detail, "UIPanelButtonTemplate")
    ui.actionPin:SetWidth(296); ui.actionPin:SetHeight(24)
    ui.actionPin:SetPoint("BOTTOM", detail, "BOTTOM", 0, 40)
    ui.actionPin:SetScript("OnClick", function()
        local q = view.selected and ledger[view.selected]
        if not q then return end
        Send("QLPIN:" .. view.selected .. ":" .. (q.pinned and "0" or "1"))
    end)
    ui.actionPin:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Keep in quest log")
        GameTooltip:AddLine(
            "Your log fills itself with the quests for the zone you are in, and clears "
            .. "them out when you leave. A kept quest is never removed automatically.",
            1, 1, 1, true)
        GameTooltip:Show()
    end)
    ui.actionPin:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Track: report #101. The ledger replaced Blizzard's quest log, and the one
    -- behaviour that never came across with it was clicking a quest title to put
    -- it in (or take it out of) the tracker down the right-hand side of the
    -- screen. That tracker is still Blizzard's own WatchFrame, so this drives
    -- Blizzard's watch list rather than reimplementing one.
    --
    -- The watch API is keyed on the quest LOG INDEX, not the quest id, which has
    -- two consequences that shape everything below: a quest that is not holding a
    -- log slot cannot be tracked at all (nothing to key on -- the button is shown
    -- disabled rather than hidden, so the connection to "Show in Quest Log" is
    -- visible instead of the control silently vanishing), and the index shifts
    -- whenever the log changes, so it is resolved at the moment it is used and
    -- never cached on the row.
    ui.actionTrack = CreateFrame("Button", nil, detail, "UIPanelButtonTemplate")
    ui.actionTrack:SetWidth(296); ui.actionTrack:SetHeight(24)
    ui.actionTrack:SetPoint("BOTTOM", detail, "BOTTOM", 0, 68)
    ui.actionTrack:SetScript("OnClick", function()
        local q = view.selected and ledger[view.selected]
        if not q then return end
        local index = UQ.QuestLogIndex and UQ.QuestLogIndex(q.id)
        if not index then return end
        -- Blizzard's own idiom from _QuestLog_ToggleQuestWatch (QuestLogFrame.lua).
        -- The cap is checked BEFORE adding because AddQuestWatch past the limit
        -- fails silently -- the button would appear to do nothing at all.
        if IsQuestWatched(index) then
            RemoveQuestWatch(index)
        else
            if GetNumQuestWatches() >= MAX_WATCHABLE_QUESTS then
                UIErrorsFrame:AddMessage(
                    string.format(QUEST_WATCH_TOO_MANY, MAX_WATCHABLE_QUESTS), 1.0, 0.1, 0.1, 1.0)
                return
            end
            AddQuestWatch(index)
        end
        if WatchFrame_Update then WatchFrame_Update() end
        Render()
    end)
    ui.actionTrack:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Track on screen")
        if self:IsEnabled() == 1 then
            GameTooltip:AddLine(
                "Show or hide this quest's objectives in the tracker down the right-hand "
                .. "side of the screen.", 1, 1, 1, true)
        else
            GameTooltip:AddLine(
                "Only a quest that is in your quest log can be tracked. Use \"Show in Quest "
                .. "Log\" first.", 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    ui.actionTrack:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- The four ledger counters that used to sit in a panel here now share the
    -- status line below, which had the room going spare -- see Render.
    ui.status = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ui.status:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 24, 18)

    return f
end

-- ---------------------------------------------------------------------------
-- protocol
-- ---------------------------------------------------------------------------

local pending = nil

-- ---------------------------------------------------------------------------
-- "Quest complete" toast
--
-- A ledger quest has no client log entry, so NONE of Blizzard's completion
-- feedback fires for it: no sound, no objective-tracker flash, nothing. You
-- gathered the last item and the game said absolutely nothing. This is that
-- missing beat, and nothing more -- it is deliberately not a StaticPopup,
-- because a modal box you have to dismiss every time a quest ticks over is
-- worse than silence.
--
-- The arrow moving on to the next thing is handled separately, and already
-- works: BuildRoute drops a completed quest's OBJECTIVE pins and picks up its
-- TURN-IN pin instead, so the next re-route naturally points at the hand-in.
-- ---------------------------------------------------------------------------
local announced = {}          -- [questId] = true once its completion was shown
local toast

local function ShowCompleteToast(title)
    if not toast then
        toast = CreateFrame("Frame", "UncappedQuestCompleteToast", UIParent)
        toast:SetWidth(340)
        toast:SetHeight(52)
        toast:SetPoint("TOP", UIParent, "TOP", 0, -150)
        toast:SetFrameStrata("HIGH")
        toast:Hide()

        toast.head = toast:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        toast.head:SetPoint("TOP", toast, "TOP", 0, 0)
        toast.head:SetText("|cffffd100Quest Complete|r")

        toast.body = toast:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        toast.body:SetPoint("TOP", toast.head, "BOTTOM", 0, -6)
        toast.body:SetWidth(330)
        toast.body:SetJustifyH("CENTER")

        toast.left = 0
        toast:SetScript("OnUpdate", function(self, elapsed)
            self.left = self.left - elapsed
            if self.left <= 0 then
                self:Hide()
            elseif self.left < 1 then
                self:SetAlpha(self.left)   -- fade rather than vanish
            end
        end)
    end

    toast.body:SetText(title or "")
    toast:SetAlpha(1)
    toast.left = 4
    toast:Show()

    PlaySound("QUESTCOMPLETED")
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Quest complete: |cffffffff" .. (title or "?") .. "|r")
end

-- Diff the freshly-swapped ledger against what we have already announced.
-- Driven off the burst rather than off each objective line: counts arrive one
-- QLO at a time, and firing on those would announce a quest the moment its
-- FIRST objective filled.
local function AnnounceNewlyComplete()
    for questId, q in pairs(ledger) do
        if q.complete then
            if not announced[questId] then
                announced[questId] = true
                ShowCompleteToast(q.title)
            end
        else
            -- Turned in, or progress lost (an item sold, a quest abandoned and
            -- retaken). Either way it may legitimately complete again.
            announced[questId] = nil
        end
    end

    -- Drop quests that have left the ledger entirely, so the table cannot grow
    -- for the whole session.
    for questId in pairs(announced) do
        if not ledger[questId] then
            announced[questId] = nil
        end
    end
end

-- The FIRST burst after login is the baseline, not news: everything already
-- complete when you logged in would otherwise toast all at once.
local seenFirstBurst = false

local function OnLine(body)
    if body == "QLE" then
        if pending then
            ledger, order, counts = pending.ledger, pending.order, pending.counts
            pending = nil
        end

        if seenFirstBurst then
            AnnounceNewlyComplete()
        else
            seenFirstBurst = true
            for questId, q in pairs(ledger) do
                if q.complete then announced[questId] = true end
            end
        end

        Render()
        -- Pins and arrow read this too, so a fresh burst has to redraw them
        -- even when the ledger window itself is closed.
        if UQ.RefreshPins then UQ.RefreshPins() end
        -- The ledger just changed, so the available-quest verdict is suspect.
        if UQ.ResetVerifiedAvailable then UQ.ResetVerifiedAvailable() end
        return
    end

    local a, b, c = body:match("^QLB:(%d+):(%d+):(%d+)$")
    if a then
        -- A burst replaces the whole ledger, so it is accumulated off to the
        -- side and swapped in at QLE. Mutating the live tables as lines arrive
        -- would leave the window rendering a half-updated set if the burst were
        -- ever cut short.
        pending = {
            ledger = {}, order = {},
            counts = { slotted = tonumber(a), total = tonumber(b), limit = tonumber(c) },
        }
        return
    end

    local id, lvl, slotted, complete, zone, title =
        body:match("^QLQ:(%d+):(%-?%d+):(%d):(%d):(%-?%d+):(.+)$")
    if id and pending then
        id = tonumber(id)
        pending.ledger[id] = {
            id = id, level = tonumber(lvl), slotted = slotted == "1",
            complete = complete == "1", zone = tonumber(zone), title = title,
            objectives = {}, poi = {},
        }
        pending.order[#pending.order + 1] = id
        return
    end

    local oid, idx, have, need, label = body:match("^QLO:(%d+):(%d+):(%d+):(%d+):(.+)$")
    if oid and pending then
        local q = pending.ledger[tonumber(oid)]
        if q then
            q.objectives[#q.objectives + 1] = {
                index = tonumber(idx), have = tonumber(have),
                need = tonumber(need), label = label,
            }
        end
        return
    end

    -- Pinned: this quest is held in the log by the player and is exempt from the
    -- automatic zone management. Only sent when true, so absence means unpinned.
    local pinId = body:match("^QLPN:(%d+):1$")
    if pinId and pending then
        local q = pending.ledger[tonumber(pinId)]
        if q then q.pinned = true end
        return
    end

    -- The quest's usable item, for the objective arrow's Use button.
    --
    -- Server-sent because the client's own GetQuestLogSpecialItemInfo only
    -- answers for quests occupying one of its 25 log slots, and the ledger
    -- exists precisely to hold the ones that do not. Only sent for quests whose
    -- source item actually has an on-use spell, so its presence means "there IS
    -- something to press here".
    local useId, useItem = body:match("^QLUI:(%d+):(%d+)$")
    if useId and pending then
        local q = pending.ledger[tonumber(useId)]
        if q then q.useItem = tonumber(useItem) end
        return
    end

    -- The objective's TARGET ENTRY: positive is a creature, negative a
    -- gameobject. Feeds the mouseover tooltip, which asks "does this thing count
    -- for anything I am carrying?" -- see UQ.QuestsForTarget below.
    local rid, ridx, rentry = body:match("^QLR:(%d+):(%d+):(%-?%d+)$")
    if rid and pending then
        local q = pending.ledger[tonumber(rid)]
        if q then
            q.targets = q.targets or {}
            q.targets[tonumber(ridx)] = tonumber(rentry)
        end
        return
    end

    -- Objective LOCATION. area is the raw WorldMapArea DBC id and wx/wy are
    -- world coordinates -- see UQ.MapPos, which must NOT apply the client's -1.
    -- Widened with a radius. Safe to widen rather than append only because QLP
    -- has never shipped -- both ends of this wire are unpublished and change
    -- together. Once it is out, append a new command instead: every already
    -- published parser is anchored and would silently drop the whole line.
    local pid, pidx, area, wx, wy, halfX, halfY =
        body:match("^QLP:(%d+):(%-?%d+):(%d+):(%-?%d+):(%-?%d+):(%d+):(%d+)$")
    if pid and pending then
        local q = pending.ledger[tonumber(pid)]
        if q then
            q.poi[#q.poi + 1] = {
                index = tonumber(pidx), area = tonumber(area),
                wx = tonumber(wx), wy = tonumber(wy),
                -- Half-extents in yards, PER AXIS. halfX runs along world X,
                -- which is the map's vertical; halfY along world Y, horizontal.
                halfX = tonumber(halfX) or 0, halfY = tonumber(halfY) or 0,
                verts = nil,
            }
        end
        return
    end

    -- The objective's actual outline, world coordinates, flat x,y,x,y list.
    -- Matched to its POI by (questId, objectiveIndex) because a quest can have
    -- several areas and they arrive interleaved.
    local vid, vidx, vlist = body:match("^QLV:(%d+):(%-?%d+):(.+)$")
    if vid and pending then
        local q = pending.ledger[tonumber(vid)]
        if q then
            local want = tonumber(vidx)
            for _, p in ipairs(q.poi) do
                if p.index == want and not p.verts then
                    local pts = {}
                    for n in vlist:gmatch("%-?%d+") do
                        pts[#pts + 1] = tonumber(n)
                    end
                    -- Need at least a triangle to fill anything.
                    if #pts >= 6 then p.verts = pts end
                    break
                end
            end
        end
        return
    end
end

-- The single source of objective locations, for the map pins and the arrow
-- alike. Everything held is in here, whether or not the client has a slot for
-- it -- which is the point: QuestPOIGetIconInfo can only ever answer for the 25
-- the client knows, so it cannot cover the ledger.
-- Every quest currently HELD, ledger included. The client's own quest log only
-- knows the 25 with slots, so anything past that reads as "not taken" to code
-- that asks the client -- which is exactly how the available-quest arrow ended
-- up still pointing at a giver whose quest was already in hand.
function UQ.HeldQuests()
    local held = {}
    for id in pairs(ledger) do held[id] = true end
    return held, next(ledger) ~= nil
end

-- The ledger's own objective list for a quest: { label, have, need, done }.
--
-- The client's GetQuestLogLeaderBoard can only answer for the 25 quests that
-- have a log slot, so anything past that -- which is the entire reason the
-- ledger exists -- had no objective text anywhere in the UI. The server already
-- sends all of it on QLO, so this is a lookup rather than a query.
function UQ.QuestObjectives(questID)
    local out = {}
    local q = questID and ledger[questID]
    if not q then return out end

    for _, obj in ipairs(q.objectives or {}) do
        out[#out + 1] = {
            label = obj.label, have = obj.have, need = obj.need,
            done = (obj.have or 0) >= (obj.need or 0),
        }
    end

    return out
end

-- The single objective worth pointing a player at: the first UNFINISHED one.
-- Returns nil when the quest is done, which the caller reads as "go hand it in".
function UQ.FirstIncompleteObjective(questID)
    for _, obj in ipairs(UQ.QuestObjectives(questID)) do
        if not obj.done then
            return obj
        end
    end
    return nil
end

-- Title straight off the ledger, for anywhere holding only a quest id.
function UQ.QuestTitle(questID)
    local q = questID and ledger[questID]
    return q and q.title or nil
end

-- The item this quest wants you to USE, or nil if it has none.
--
-- Server-sent (QLUI) rather than read from GetQuestLogSpecialItemInfo, because
-- that API only knows about quests holding one of the client's 25 log slots --
-- which is the minority of what a player carries here.
function UQ.QuestUseItem(questID)
    local q = questID and ledger[questID]
    return q and q.useItem or nil
end

-- Every quest this creature/gameobject counts towards, with progress.
-- `entry` is positive for a creature, negative for a gameobject, matching how
-- the DB stores RequiredNpcOrGo and what QLR sends.
--
-- Only INCOMPLETE objectives are returned: once you have your 10/10 the mob has
-- stopped being interesting, and saying otherwise sends people to kill things
-- they do not need.
function UQ.QuestsForTarget(entry)
    local out = {}
    if not entry then return out end

    for _, id in ipairs(order) do
        local q = ledger[id]
        if q and q.targets then
            for idx, want in pairs(q.targets) do
                if want == entry then
                    for _, obj in ipairs(q.objectives) do
                        if obj.index == idx and obj.have < obj.need then
                            out[#out + 1] = { title = q.title, have = obj.have, need = obj.need }
                        end
                    end
                end
            end
        end
    end

    return out
end

-- Which of a quest's objectives are already finished, keyed the way the POI
-- data keys them.
--
-- These are two different index spaces and they only agree by accident. Our own
-- objective index is the RAW TEMPLATE SLOT -- 0-3 for kill/interact objectives
-- and 4-9 for item objectives, which is how the server sends them. A POI's
-- ObjectiveIndex is a position in the quest log's objective LIST, which is
-- compacted: empty slots are skipped and what remains is numbered from zero,
-- kills first and then items.
--
-- "Heroes of Darrowshire" is the worked example: two item objectives, so our
-- slots are 4 and 5 while the POIs are 0 and 1. Matching those raw would have
-- found nothing and kept painting both areas -- which is the bug this exists to
-- fix. Sorting by slot and taking the ordinal converts one space to the other.
--[[ Which objectives are finished, keyed by the index quest_poi uses.

     ★ KEY BY THE OBJECTIVE'S REAL INDEX, NOT ITS ORDINAL POSITION.

     This used to sort the objectives and key the result by ordinal (0, 1, 2...).
     That silently mis-keys every ITEM objective, because the two index spaces
     are not the same:

       creature / GO objectives   index 0..3
       item objectives            index QUEST_OBJECTIVES_COUNT + i, i.e. 4..7

     and quest_poi.ObjectiveIndex stores the REAL index. Worked example, quest
     577 "Some Assembly Required" -- one item objective, so:

       server sends   QLO index 4
       quest_poi has  ObjectiveIndex 4 (the objective area), -1 (the turn-in)
       old code wrote done[0]; the lookup asked done[4] -> nil -> "not done"

     So a finished collect-N-items objective was never recognised as finished and
     the arrow kept routing the player back to where they had already been.

     ★ This is also why "kill quests work, item quests don't" -- creature
     objectives sit at 0..3, where ordinal and real index coincide by accident,
     so they were never affected and the bug looked like it was about item drops
     specifically. It was about the keying all along. ]]
local function ObjectivesDoneByPoiIndex(q)
    local done = {}
    for _, obj in ipairs(q.objectives or {}) do
        if obj.index then
            done[obj.index] = (obj.need or 0) > 0 and (obj.have or 0) >= obj.need
        end
    end
    return done
end

function UQ.LedgerPins()
    local out = {}
    for _, id in ipairs(order) do
        local q = ledger[id]
        if q then
            local objDone = ObjectivesDoneByPoiIndex(q)
            for _, p in ipairs(q.poi) do
                local mapID, mx, my = UQ.MapPos(p.area, p.wx, p.wy)
                -- ObjectiveIndex -1 is the TURN-IN location, not something to
                -- go and do -- and it is the majority of the POI data. Showing
                -- both at once buries the actual objectives under a field of
                -- hand-in markers.
                local isTurnIn = (p.index or 0) < 0

                -- Already done? Then this area is finished with, even though the
                -- quest as a whole is not. An unknown index stays visible: a POI
                -- we cannot match is far better shown than silently dropped.
                local objDoneHere = (not isTurnIn) and (objDone[p.index or 0] == true) or false

                if mapID and mx and mx >= 0 and mx <= 1 and my >= 0 and my <= 1 then
                    out[#out + 1] = {
                        questID = q.id, title = q.title, isComplete = q.complete,
                        slotted = q.slotted, dbcArea = p.area, map = mapID,
                        x = mx, y = my, wx = p.wx, wy = p.wy,
                        objIndex = p.index, isTurnIn = isTurnIn,
                        objDone = objDoneHere,
                        -- Yards, per axis. Converted to map pixels at draw time,
                        -- since that depends on the zone's world size and the
                        -- current size of the map frame.
                        halfX = p.halfX or 0, halfY = p.halfY or 0,
                        verts = p.verts,
                    }
                end
            end
        end
    end
    return out
end

local listener = CreateFrame("Frame")
listener:RegisterEvent("ADDON_LOADED")
listener:RegisterEvent("CHAT_MSG_ADDON")
listener:RegisterEvent("PLAYER_ENTERING_WORLD")
listener:RegisterEvent("QUEST_LOG_UPDATE")

-- Looting a quest ITEM has to refresh the ledger too.
--
-- Item objective counts are computed SERVER-side from the player's bags (see
-- the QLO item loop), so the client cannot recount them itself -- and
-- QUEST_LOG_UPDATE does not fire for a quest with no log slot, which is every
-- ledger quest. Without this, picking up the tenth boar liver left the map pin,
-- the arrow and the ledger all reading 9/10 until some unrelated refresh
-- happened along.
--
-- DEBOUNCED rather than put on the shared 4-second throttle below: that would
-- mean up to four seconds of staring at a stale count after looting the thing,
-- which is the complaint. This fires shortly after bag activity STOPS, so
-- emptying a full corpse still costs exactly one request.
local bagDebounce = CreateFrame("Frame")
local bagPending = nil

bagDebounce:RegisterEvent("BAG_UPDATE")
bagDebounce:SetScript("OnEvent", function()
    bagPending = GetTime() + 0.4
end)
bagDebounce:SetScript("OnUpdate", function()
    if bagPending and GetTime() >= bagPending then
        bagPending = nil
        Send("QLGET")
    end
end)

-- The map pins and the arrow both read the ledger now, so it has to stay fresh
-- even when the window is shut. QUEST_LOG_UPDATE fires often, hence the
-- throttle: one refresh per few seconds is plenty for objective counts.
local REFRESH_INTERVAL = 4
local lastRefresh = 0
local refreshQueued = false

-- TRAILING edge. A leading-edge-only throttle drops whatever lands inside the
-- window, and if nothing fires afterwards that update is lost for good -- which
-- is exactly what happens on the kill that COMPLETES a quest: it follows the
-- previous kill closely, so its QUEST_LOG_UPDATE falls inside the window, and
-- there is no ninth mob to fire a tenth event. The ledger (and therefore the map
-- pins and the arrow, which both read it) kept showing the quest as incomplete
-- and pointing at the kill area instead of the turn-in until some unrelated
-- refresh happened along. Queue the dropped tick and let it fire when the
-- interval is up.
listener:SetScript("OnUpdate", function()
    if not refreshQueued then return end
    if GetTime() - lastRefresh < REFRESH_INTERVAL then return end
    refreshQueued = false
    lastRefresh = GetTime()
    Send("QLGET")
end)

--[[ One QL* line, from whichever transport carried it.

     Factored out because the ledger now arrives two ways -- as individual addon
     messages, or as one native frame whose lines are split apart below -- and
     both must dispatch IDENTICALLY. Calling OnLine directly from the native path
     would have quietly skipped QLOK/QLEV/QLT, which are handled here and not
     there. ]]
local function DispatchLine(message)
    -- Server's verdict on which quests are genuinely takeable. Routed here
    -- because this frame already owns the QL* pipe.
    if message:sub(1, 5) == "QLOK:" then
        if UQ.OnVerifiedAvailable then UQ.OnVerifiedAvailable(message:sub(6), false) end
        return
    end
    -- Which game events are running. Cached on UQ so the giver filter can
    -- drop quests whose giver only spawns during a holiday.
    if message:sub(1, 5) == "QLEV:" then
        UQ.ActiveEvents = UQ.ActiveEvents or {}
        for id in message:sub(6):gmatch("%d+") do
            UQ.ActiveEvents[tonumber(id)] = true
        end
        return
    end

    if message == "QLOKEND" then
        if UQ.OnVerifiedAvailable then UQ.OnVerifiedAvailable("", true) end
        return
    end

    -- One quest's description text. Kept OUT of OnLine deliberately: that
    -- parser is the ledger burst, and a QLT line is not ledger data. It is
    -- also why the tag is QLT* and not a widened QLQ -- see the file header.
    if message:sub(1, 3) == "QLT" then
        OnText(message)
        return
    end

    OnLine(message)
end

--[[ Native path: the whole QLB..QLE burst in one frame on topic "QLEDGER".

     The lines are byte-identical to the ones the addon-message path sends; only
     the packaging differs. That is the point -- an addon message caps at 255
     bytes, so a ~100-quest ledger is several hundred of them, and the window
     only swaps in a new quest list when the closing QLE lands. A burst the
     client throttles away leaves the previous snapshot on screen with nothing
     to signal it went stale. A single frame cannot be caught half-way.

     Registration is conditional and failure is not an error: without the DLL,
     UncappedNative is absent and the server keeps sending addon messages. ]]
if UncappedNative and UncappedNative.IsAvailable() then
    --[[ Tell the server THIS ADDON can decode the frame.

         The DLL's own announcement is not the same claim: it says the opcode
         handler exists, and that handler only routes a frame to whichever addon
         registered its topic. Announcing native is UncappedUI's job, and a client
         can have an up-to-date UncappedUI alongside a copy of THIS file that
         predates the QLEDGER topic -- in which case a frame routes to nobody and
         the ledger window is simply empty. So the claim has to come from here.

         Deferred to PLAYER_ENTERING_WORLD because the addon pipe is not usable at
         file-load time. Until it lands the server chunks, which is correct and is
         what every client did before today. ]]
    local announce = CreateFrame("Frame")
    announce:RegisterEvent("PLAYER_ENTERING_WORLD")
    announce:SetScript("OnEvent", function(self)
        self:UnregisterAllEvents()
        Send("QLNATIVE:1")
    end)

    UncappedNative.Register("QLEDGER", function(payload)
        local at, n = 1, #payload
        while at <= n do
            local nl = payload:find("\n", at, true)
            if not nl then
                DispatchLine(payload:sub(at))
                return
            end

            -- A trailing newline makes the last slice empty; skip rather than
            -- feed the parsers an empty string.
            if nl > at then DispatchLine(payload:sub(at, nl - 1)) end
            at = nl + 1
        end
    end)
end

listener:SetScript("OnEvent", function(_, event, prefix, message)
    if event == "ADDON_LOADED" then
        -- `prefix` carries the addon name for this event.
        if prefix ~= ADDON then return end
        UncappedQuestsDB = UncappedQuestsDB or {}
        db = UncappedQuestsDB
        for k, v in pairs(defaults) do
            if db[k] == nil then db[k] = v end
        end
        UQ.HookQuestLog()
        return
    end

    if event == "CHAT_MSG_ADDON" then
        if prefix ~= PIPE or not message then return end
        if message:sub(1, 2) ~= "QL" then return end

        DispatchLine(message)
        return
    end

    local now = GetTime()
    if now - lastRefresh < REFRESH_INTERVAL then
        refreshQueued = true
        return
    end
    lastRefresh = now
    refreshQueued = false
    Send("QLGET")
end)

-- ---------------------------------------------------------------------------
-- slash
-- ---------------------------------------------------------------------------

local function Toggle()
    if not ui.frame then BuildFrame() end
    if ui.frame:IsShown() then
        ui.frame:Hide()
    else
        ui.frame:Show()
        Send("QLGET")       -- always open against fresh state
        Render()
    end
end

UQ.ToggleLedger = Toggle

-- Open the ledger ON a quest, instead of merely opening the ledger.
--
-- Left-clicking the arrow for a ledger quest used to call Toggle and stop there,
-- dropping the player into a list of everything they hold with no sign of which
-- quest the arrow had been pointing at -- and past one screenful, not even on
-- the visible page.
--
-- The filters are cleared first because any one of them can hide the target: a
-- zone picked earlier, a search still in the box, or a tab the quest does not
-- match. Opening "at" a quest that the list is filtering out would be the same
-- bug wearing a different hat.
function UQ.FocusLedgerQuest(questID)
    if not questID or not ledger[questID] then
        -- Nothing to focus on -- fall back to just opening the window, which is
        -- still better than doing nothing.
        if not ui.frame or not ui.frame:IsShown() then Toggle() end
        return
    end

    if not ui.frame then BuildFrame() end

    view.tab, view.zone, view.search = "all", nil, ""
    local searchBox = _G["UncappedQuestLedgerSearch"]
    if searchBox then searchBox:SetText("") end
    view.selected = questID

    ui.frame:Show()
    Send("QLGET")           -- same as Toggle: open against fresh state

    -- Put the row on the page. FauxScrollFrame offsets are in ROWS, but its
    -- scrollbar is in PIXELS, and the two have to be set together or the bar
    -- ends up describing a position the list is not actually at. Centring the
    -- row reads better than putting it flush at the top; clamping to
    -- #rows - ROWS_VISIBLE stops the last page scrolling past the end into
    -- blank rows.
    local rows = Visible(true)
    local idx
    for i, q in ipairs(rows) do
        if q.id == questID then
            idx = i
            break
        end
    end
    if idx then
        local maxOffset = math.max(0, #rows - ROWS_VISIBLE)
        local offset = math.min(math.max(0, idx - math.floor(ROWS_VISIBLE / 2) - 1), maxOffset)
        FauxScrollFrame_SetOffset(ui.scroll, offset)
        local bar = _G["UncappedQuestLedgerScrollScrollBar"]
        if bar then bar:SetValue(offset * ROW_HEIGHT) end
    end

    Render()
end

-- ---------------------------------------------------------------------------
-- Quest log takeover
-- ---------------------------------------------------------------------------
-- Opening the quest log -- key bind, micro button, anything that calls
-- ToggleQuestLog -- lands here instead. Blizzard's log can only ever show 25
-- quests, so on this realm it is the incomplete view.
--
-- HideUIPanel rather than :Hide(): the quest log is a managed UI panel, and
-- hiding it directly leaves the panel manager believing the slot is still
-- occupied, which shoves the next window that opens off to one side.
--
-- `bypass` is what the "Blizzard log" button sets, so there is still a way to
-- reach the original for anything only it can do (sharing, abandoning).

local bypass = false

function UQ.OpenBlizzardQuestLog()
    bypass = true
    if ui.frame then ui.frame:Hide() end
    ShowUIPanel(QuestLogFrame)
    bypass = false
end

function UQ.HookQuestLog()
    if not QuestLogFrame then return end

    QuestLogFrame:HookScript("OnShow", function()
        if bypass or not db or not db.takeOverQuestLog then return end

        HideUIPanel(QuestLogFrame)

        if not ui.frame then BuildFrame() end

        --[[ TOGGLE, not open.

             ToggleQuestLog decides what to do by asking whether QuestLogFrame is
             shown -- and we hide it a line above, every time. So on the second
             press it still looks closed to Blizzard, gets shown again, lands back
             in this hook, and re-opens the ledger. The key could only ever open;
             it could never close. Reported as "pressing L opens the new quest
             log, but pressing it again doesn't close it".

             Toggling on OUR frame instead is what makes the second press mean
             what the player expects. The Blizzard-log button is unaffected: it
             sets `bypass` and returns above this. ]]
        if ui.frame:IsShown() then
            ui.frame:Hide()
            return
        end

        ui.frame:Show()
        Send("QLGET")
        Render()
    end)
end

if UncappedUI then
    local panel, L = UncappedUI.CreatePanel("Quest ledger",
        "Everything you are carrying, including the quests Blizzard's log cannot show.")

    L:Header("Quest log")
    L:Check("Open the ledger instead of Blizzard's quest log",
        function() return db and db.takeOverQuestLog end,
        function(v) if db then db.takeOverQuestLog = v end end)

    L:Gap(6)
    L:Note("|cff808080Blizzard's log can only ever display 25 quests. The ledger shows all of "
        .. "them; the 'Blizzard log' button inside it opens the original for sharing and "
        .. "abandoning.|r", 50)
end

SLASH_UNCAPPEDQLEDGER1 = "/qledger"
SLASH_UNCAPPEDQLEDGER2 = "/ql"
SlashCmdList["UNCAPPEDQLEDGER"] = function() Toggle() end
