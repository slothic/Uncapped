--[[
  Uncapped Quests -- every quest objective in your log, pinned on the world map.

  There is deliberately NO shipped quest database here. The 3.3.5a client
  already has this data: the server ships quest POI records on request
  (CMSG_QUEST_POI_QUERY, backed by the world DB's quest_poi / quest_poi_points
  -- 18,784 rows covering 8,953 of our 9,464 quests) and the client exposes
  them through QuestPOIGetIconInfo and GetQuestWorldMapAreaID. What Blizzard's
  world map does NOT do is draw more than the single quest you have selected in
  the quest log.

  So this walks the quest log, asks the client where each quest's objectives
  are, and pins them all at once. Realm-custom quests come along for free as
  soon as they have quest_poi rows -- nothing to regenerate, nothing to ship,
  and it can never drift out of date the way a static database does.

  That last point is why QuestHelper is gone: it carried a huge static database
  that knew nothing about our custom content and threw Lua errors on top of it
  (pulled 2026-07-20, force-disabled in the manifest since).

  Coexisting with WDM: both hook WorldMapFrame_Update and anchor to
  WorldMapButton (the frame the map art itself is drawn on), so pins land in
  the right place on WDM's map as well as Blizzard's. WDM's own POIs are a
  separate module and are untouched.

  GOTCHA: GetQuestLogTitle does NOT return a quest ID on 3.3.5a -- that return
  arrived in a later expansion. The ID has to come from GetQuestLink and be
  parsed out of the hyperlink. Getting this wrong silently pins nothing.
]]

local ADDON = "UncappedQuests"

-- Shared with UncappedQuestsArrow.lua: the arrow needs the same objective list
-- the map pins use, but across every zone rather than just the one on screen.
UncappedQuests = UncappedQuests or {}
local UQ = UncappedQuests

-- ---------------------------------------------------------------------------
-- Per-quest player overrides
--
-- Two decisions a player can make about a single quest, shared by all four
-- files (map pins, arrow, available-quest pins, ledger):
--
--   deferred   "not right now" -- keep it, but sort it to the BACK of the
--              arrow's route instead of letting distance decide.
--   ignored    "stop showing me this" -- drop it from the pins and the route
--              entirely.
--
-- These live on the addon table rather than in any one file's locals because
-- all of them need the same answer, and in SavedVariables because the whole
-- complaint about the old right-click send-to-back was that it did NOT
-- survive -- BuildRoute re-ran every 2 seconds and threw the decision away.
--
-- Read straight out of UncappedQuestsDB rather than a captured `db` local:
-- these are callable before this file's ADDON_LOADED has run, and a nil-guard
-- is cheaper than depending on file load order.
-- ---------------------------------------------------------------------------

local function OverrideSet(key)
    local s = UncappedQuestsDB
    if not s then return nil end
    s[key] = s[key] or {}
    return s[key]
end

function UQ.IsDeferred(questID)
    local t = questID and OverrideSet("deferredQuests")
    return (t and t[questID]) and true or false
end

function UQ.SetDeferred(questID, on)
    local t = questID and OverrideSet("deferredQuests")
    if t then t[questID] = on and true or nil end
end

function UQ.ToggleDeferred(questID)
    local on = not UQ.IsDeferred(questID)
    UQ.SetDeferred(questID, on)
    return on
end

function UQ.IsIgnored(questID)
    local t = questID and OverrideSet("ignoredQuests")
    return (t and t[questID]) and true or false
end

function UQ.SetIgnored(questID, on)
    local t = questID and OverrideSet("ignoredQuests")
    if t then t[questID] = on and true or nil end
end

function UQ.ToggleIgnored(questID)
    local on = not UQ.IsIgnored(questID)
    UQ.SetIgnored(questID, on)
    return on
end

-- Count + clear, for the settings page: an override a player cannot find again
-- is a trap, so both sets need a visible escape hatch.
function UQ.CountOverrides()
    local d, i = 0, 0
    local s = UncappedQuestsDB
    if s then
        for _ in pairs(s.deferredQuests or {}) do d = d + 1 end
        for _ in pairs(s.ignoredQuests or {}) do i = i + 1 end
    end
    return d, i
end

function UQ.ClearOverrides()
    local s = UncappedQuestsDB
    if s then s.deferredQuests, s.ignoredQuests = {}, {} end
end

-- Pins are NOT bound by the client's 25 quest slots -- that is the whole point
-- of the ledger, and a quest can contribute several objective locations besides.
-- This is purely a sanity ceiling on how many frames one map may draw.
local MAX_PINS = 80

-- The three markers players already know, used with their real meanings:
--   grey "?"   a quest you are ON, work still to do   -> objective
--   gold "?"   finished, hand it in here              -> turn-in
--   gold "!"   a quest you could pick UP here         -> giver (opt-in)
--
-- An earlier attempt drew objectives as a solid colour via SetTexture(r,g,b).
-- That fills the ENTIRE frame, so a 28px pin became a 28px yellow block.
-- Our own texture, generated by tools/Make-BlobTexture.py.
--
-- Blizzard's UI-QuestBlob-Inside / -Outside are present in the client MPQs
-- (verified with StormLib) but they are the FILL and BORDER TILES fed to the
-- engine's spline blob renderer -- not circular sprites. Stretched over a
-- square frame they draw as flat rectangles, which is precisely what happened.
-- Existing and being the right shape are different questions, and the first one
-- is the only one a file listing can answer.
--
-- The engine path that uses them properly is the DrawQuestBlob widget method,
-- which only renders quests occupying one of the client's 25 quest-log slots --
-- no use for ledger quests, which is the whole point here.
--
-- So: a soft-edged disc with known geometry, white so SetVertexColor tints it
-- per quest state. Alpha carries the shape; corners are fully transparent.
local BLOB_TEXTURE = "Interface\\AddOns\\UncappedQuests\\blob_circle.tga"

-- Biggest a painted area may get, as a fraction of the map's width. Quest POI
-- polygons can legitimately span most of a zone, and drawn at true size a few
-- of those bury the map underneath.
local BLOB_MAX_FRACTION = 0.11

-- Opacity when every area is painted at once. Far fainter than the hover blob:
-- twenty overlapping discs stack, and each one is competing with the map art.
local BLOB_ALPHA_ALL = 0.30

local ICON_OBJECTIVE = "Interface\\GossipFrame\\IncompleteQuestIcon"
local ICON_TURNIN    = "Interface\\GossipFrame\\ActiveQuestIcon"
local ICON_GIVER     = "Interface\\GossipFrame\\AvailableQuestIcon"

-- SetTexture on a path that does not exist fails SILENTLY, leaving the texture
-- empty -- an invisible pin rather than an error. Same failure mode the font
-- loader in Uncapped64bitUI guards against, so the same shape of guard.
local function SafeSetTexture(tex, path, fallback)
    tex:SetTexture(path)
    if not tex:GetTexture() and fallback then
        tex:SetTexture(fallback)
    end
end

local defaults = {
    enabled       = true,
    showCompleted = true,
    showNumbers   = true,
    iconSize      = 36,
    -- Where to hand in. Only ever drawn for quests that are actually finished.
    showTurnIns   = true,
    -- Paint the objective AREA, not just a point, when the quest data says the
    -- objective covers real ground.
    showBlobs     = true,
    -- Only while pointing at a pin. Blizzard paints exactly one blob -- the
    -- selected quest -- and that restraint is what keeps its map readable.
    blobsOnHover  = true,
    -- Quest givers you could pick NEW quests up from. Off by default: the map
    -- is for what you still have to do, and these bury it.
    showGivers    = false,
    -- Blizzard's own POI display can only ever cover the 25 quests the client
    -- has slots for, so leaving it on means the map behaves differently above
    -- and below the cap, and draws a second, incomplete set of markers on top
    -- of ours. The questPOI CVar switches it off cleanly.
    hideBlizzardPOI = true,
}

-- Start from a private copy of the defaults. The settings page is built while
-- this file executes, which is BEFORE ADDON_LOADED hands us the SavedVariable --
-- and UncappedUI's Slider calls its getter immediately and formats the result,
-- so a nil here aborts the rest of the file (taking every slash command with it).
local db = {}
for k, v in pairs(defaults) do db[k] = v end

local pins = {}
local panelRefreshers = {}   -- settings widgets to resync once the DB loads

-- ---------------------------------------------------------------------------
-- pins
-- ---------------------------------------------------------------------------

-- Client quest-log index for a quest id, or nil when it is held in the ledger
-- and therefore not in the log at all.
function UQ.QuestLogIndex(questID)
    if not questID then return nil end
    for i = 1, (GetNumQuestLogEntries() or 0) do
        local _, _, _, _, isHeader = GetQuestLogTitle(i)
        local link = (not isHeader) and GetQuestLink and GetQuestLink(i) or nil
        if link and tonumber(link:match("|Hquest:(%d+):")) == questID then
            return i
        end
    end
    return nil
end

-- Blizzard's POI layer, on or off to match the setting. Restoring it on the way
-- out matters: this is a CVar, so it persists after the addon is gone, and
-- silently leaving a player's map objectives switched off forever would be a
-- nasty parting gift.
function UQ.ApplyBlizzardPOI()
    if not SetCVar then return end
    SetCVar("questPOI", (db and db.hideBlizzardPOI) and "0" or "1")
    if WorldMapFrame_Update and WorldMapFrame and WorldMapFrame:IsShown() then
        WorldMapFrame_Update()
    end
end

-- A distance in world yards, as pixels on the map currently drawn.
--
-- The map area's world extent comes from the shipped bounds table, so this is
-- the same arithmetic the pin positions use -- a blob and its pin can never
-- disagree about scale.
function UQ.YardsToPixels(dbcArea, yards, mapPixelWidth)
    if not yards or yards <= 0 then return nil end

    local a = UncappedMapAreas and UncappedMapAreas[dbcArea]
    if not a then return nil end

    local worldWidth = a[2] - a[3]      -- left - right, in yards
    if worldWidth <= 0 then return nil end

    return (yards / worldWidth) * mapPixelWidth
end

-- Fill an arbitrary polygon with horizontal bands.
--
-- 3.3.5a has no polygon primitive, so the shape is rasterised the way a
-- scanline filler does it: slice the outline into horizontal strips, intersect
-- each strip with the edges, and draw a rectangle between each entering and
-- leaving pair. Rectangles are the one thing this API is good at.
--
-- The alternative was stretching a disc to the bounding box, which turns a road
-- into an oval -- the right size and the wrong shape.
--
-- Concave outlines and shapes that split into two spans on a line both fall out
-- of handling every crossing pair, not just the first and last.
local BLOB_BANDS = 26
local FILL_TEXTURE = "Interface\\Buttons\\WHITE8X8"

local function FillPolygon(frame, pts, r, g, b)
    frame.bands = frame.bands or {}
    local used = 0

    local minY, maxY = pts[2], pts[2]
    for i = 2, #pts, 2 do
        if pts[i] < minY then minY = pts[i] end
        if pts[i] > maxY then maxY = pts[i] end
    end
    if maxY - minY <= 0 then return 0 end

    local bandH = (maxY - minY) / BLOB_BANDS

    for b = 0, BLOB_BANDS - 1 do
        -- Sample through the middle of the band so edges are not double counted.
        local y = minY + (b + 0.5) * bandH

        local xs = {}
        local n = #pts / 2
        for i = 1, n do
            local j = (i % n) + 1
            local x1, y1 = pts[i * 2 - 1], pts[i * 2]
            local x2, y2 = pts[j * 2 - 1], pts[j * 2]
            if (y1 <= y and y2 > y) or (y2 <= y and y1 > y) then
                xs[#xs + 1] = x1 + (y - y1) / (y2 - y1) * (x2 - x1)
            end
        end
        table.sort(xs)

        for k = 1, #xs - 1, 2 do
            local x1, x2 = xs[k], xs[k + 1]
            if x2 - x1 > 0 then
                used = used + 1
                local t = frame.bands[used]
                if not t then
                    t = frame:CreateTexture(nil, "ARTWORK")
                    frame.bands[used] = t
                end
                t:SetTexture(FILL_TEXTURE)
                t:SetVertexColor(r, g, b, 0.45)
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", frame, "TOPLEFT", x1, -(y - minY))
                t:SetWidth(x2 - x1)
                -- Slight overlap, or rounding leaves hairline gaps between bands.
                t:SetHeight(bandH + 1)
                t:Show()
            end
        end
    end

    for i = used + 1, #frame.bands do frame.bands[i]:Hide() end
    return used
end

-- The world map sits in a very high frame strata when maximised, and
-- GameTooltip does not -- so a GameTooltip opened over the FULLSCREEN map draws
-- BEHIND it and looks like nothing happened. FrameXML ships WorldMapTooltip for
-- exactly this; Zygor uses it for the same reason.
-- OUR OWN tooltip frame, not GameTooltip and not WorldMapTooltip.
--
-- Both of those are owned by Blizzard's map code, which sets, re-owns and hides
-- them from its own OnUpdate as the cursor moves over the map -- so a tooltip we
-- populate can be cleared before it is ever drawn, which is exactly what
-- "hovering a pin shows nothing" looked like. An earlier fix chased the TEXT
-- being wrong; the text was fine, the frame was being taken away.
--
-- A private GameTooltip-templated frame cannot be reclaimed by anyone else. It
-- is parented to WorldMapFrame so it inherits the map's strata (the fullscreen
-- map sits above almost everything) and then raised above it explicitly.
local uqTooltip
local function MapTooltip()
    if not uqTooltip then
        uqTooltip = CreateFrame("GameTooltip", "UncappedQuestTooltip", UIParent, "GameTooltipTemplate")
    end

    -- Re-parented on every use: WorldMapFrame may not exist when this file runs,
    -- and the map switches between windowed and fullscreen, which changes the
    -- strata it needs to sit above.
    local host = _G.WorldMapFrame or UIParent
    uqTooltip:SetParent(host)
    uqTooltip:SetFrameStrata("TOOLTIP")
    uqTooltip:SetFrameLevel((host:GetFrameLevel() or 0) + 50)
    return uqTooltip
end

local function PinTooltip(pin)
    if not pin.questID then return end

    local tip = MapTooltip()
    tip:SetOwner(pin, "ANCHOR_RIGHT")

    -- Ledger quests are not in the client log, so the title comes off the pin
    -- rather than from GetQuestLogTitle.
    local title, level, isComplete = pin.pinTitle, nil, pin.pinComplete
    if pin.questIndex then
        local logTitle, logLevel = GetQuestLogTitle(pin.questIndex)
        -- GetQuestLogTitle returns nil for a header row or a stale index. Only
        -- take it when it actually answered, or a good pinTitle gets replaced
        -- with UNKNOWN -- which is what "hovering a pin shows no quest name"
        -- looked like.
        if logTitle and logTitle ~= "" then
            title, level = logTitle, logLevel
            isComplete = select(6, GetQuestLogTitle(pin.questIndex))
        end
    end

    -- Last resort: the ledger knows every held quest by id, log slot or not.
    if not title or title == "" then
        title = (UQ.QuestTitle and UQ.QuestTitle(pin.questID)) or nil
    end

    tip:AddLine(title or UNKNOWN, 1, 1, 1)
    if level then
        tip:AddLine("Level " .. level, 0.7, 0.7, 0.7)
    end
    if not pin.questIndex then
        tip:AddLine("In your ledger", 0.4, 0.8, 1)
    end

    -- GetQuestLogLeaderBoard reads from the SELECTED quest on some paths, so
    -- pass the index explicitly rather than relying on the current selection.
    -- Only the client log can answer this; a ledger quest's objectives are
    -- shown in /ql instead, where the server-sent counts live.
    local n = pin.questIndex and (GetNumQuestLeaderBoards(pin.questIndex) or 0) or 0
    if n > 0 then
        tip:AddLine(" ")
        for j = 1, n do
            local text, _, finished = GetQuestLogLeaderBoard(j, pin.questIndex)
            if text then
                if finished then
                    tip:AddLine(" - " .. text, 0.4, 0.8, 0.4)
                else
                    tip:AddLine(" - " .. text, 0.9, 0.9, 0.9)
                end
            end
        end
    elseif UQ.QuestObjectives then
        -- A LEDGER quest has no log slot, so GetQuestLogLeaderBoard above
        -- answers nothing for it and the tooltip used to show a bare title with
        -- no objectives at all. The server already sent them; read them here.
        local objectives = UQ.QuestObjectives(pin.questID)
        if #objectives > 0 then
            tip:AddLine(" ")
            for _, obj in ipairs(objectives) do
                local line = string.format(" - %s: %d/%d", obj.label or "?", obj.have or 0, obj.need or 0)
                if obj.done then
                    tip:AddLine(line, 0.4, 0.8, 0.4)
                else
                    tip:AddLine(line, 0.9, 0.9, 0.9)
                end
            end
        end
    end

    if isComplete then
        tip:AddLine(" ")
        tip:AddLine("Ready to turn in.", 0.4, 0.9, 0.4)
    end

    tip:AddLine(" ")
    tip:AddLine("|cff808080Click to select in the quest log.|r")
    tip:Show()
end

-- Paint EVERY area belonging to one quest, not just the pin under the cursor.
--
-- A quest with several objective areas -- "kill 10 of these, spread over three
-- camps" -- gets one pin and one blob per area, and hovering used to light only
-- the single area you happened to be pointing at. That is actively misleading:
-- it reads as "this is where the quest is" when two more camps count just as
-- much. Matching on questID lights all of them together.
local function SetQuestBlobs(questID, shown)
    if not questID then return end

    for i = 1, #pins do
        local other = pins[i]
        -- Only pins currently on the map: the pool is reused between draws and
        -- a retired pin keeps its old questID, so a stale one would light a blob
        -- for a quest that is no longer shown.
        if other and other:IsShown() and other.questID == questID and other.blobReady then
            if shown then
                other.blob:SetAlpha(1)
                other.blob:Show()
            else
                other.blob:Hide()
            end
        end
    end
end

local function CreatePin(i)
    local pin = CreateFrame("Button", "UncappedQuestPOI" .. i, WorldMapButton)
    pin:SetWidth(defaults.iconSize)
    pin:SetHeight(defaults.iconSize)

    -- Above the map art and WDM's own POIs, but NOT raised to a higher strata:
    -- putting pins in TOOLTIP strata draws them over the tooltip they open.
    pin:SetFrameLevel(WorldMapButton:GetFrameLevel() + 5)

    -- The painted area. Its own frame, because it is sized from the objective's
    -- real world radius while the icon stays a constant readable size -- parent
    -- them together and a big area would give you a giant icon.
    pin.blob = CreateFrame("Frame", nil, WorldMapButton)
    pin.blob:SetFrameLevel(WorldMapButton:GetFrameLevel() + 3)   -- under the pins
    pin.blob.fill = pin.blob:CreateTexture(nil, "ARTWORK")
    pin.blob.fill:SetAllPoints()
    pin.blob:Hide()

    pin.icon = pin:CreateTexture(nil, "OVERLAY")
    pin.icon:SetAllPoints()

    -- Numbers sit as a corner badge, not dead centre: centred, they cover the
    -- very icon they are labelling. NumberFont* are the outlined faces, which
    -- stay readable over the map's warm parchment where a plain font does not.
    pin.label = pin:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    pin.label:SetPoint("BOTTOMRIGHT", pin, "BOTTOMRIGHT", 2, -2)
    pin.label:SetTextColor(1, 1, 1)

    -- A mouse-enabled frame CONSUMES every click over it, whether or not it is
    -- registered for that button -- there is no pass-through in this API. Left
    -- unregistered, each pin would punch a dead hole in the map where
    -- right-click-to-zoom-out silently stops working. So take right-click too
    -- and hand it straight back to the map.
    pin:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    pin:SetScript("OnEnter", function(self)
        PinTooltip(self)
        -- Show THIS quest's area while you are pointing at it. One blob at a
        -- time is the whole reason Blizzard's map stays legible.
        if db.showBlobs and db.blobsOnHover then
            SetQuestBlobs(self.questID, true)
        end
    end)
    pin:SetScript("OnLeave", function(self)
        MapTooltip():Hide()
        if db.blobsOnHover then SetQuestBlobs(self.questID, false) end
    end)
    pin:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            if type(WorldMapButton_OnClick) == "function" then
                WorldMapButton_OnClick(WorldMapButton, "RightButton")
            elseif GetCurrentMapZone() ~= 0 then
                SetMapZoom(GetCurrentMapContinent(), 0)
            end
            return
        end

        -- Always open the ledger on this quest, same as the arrow. Splitting on
        -- questIndex meant only quests PAST the client's 25 log slots opened
        -- anything -- the rest went to SelectQuestLogEntry, which selects a row
        -- inside Blizzard's quest log, and that window is hooked and replaced by
        -- the ledger here, so the click did nothing visible.
        if self.questIndex then
            SelectQuestLogEntry(self.questIndex)
            if QuestLog_Update then QuestLog_Update() end
            if WorldMapFrame_Update then WorldMapFrame_Update() end
        end

        if UQ.FocusLedgerQuest then
            UQ.FocusLedgerQuest(self.questID)
        elseif UQ.ToggleLedger then
            UQ.ToggleLedger()
        end
    end)

    pin:Hide()
    pins[i] = pin
    return pin
end

-- ---------------------------------------------------------------------------
-- objectives
-- ---------------------------------------------------------------------------

-- Every quest in the log that has a recorded objective location, in log order.
-- Returns entries of { questIndex, questID, areaID, x, y, title, isComplete }
-- with x/y normalised to the quest's OWN map area (areaID), not the map the
-- player happens to be looking at -- which is what lets the arrow route across
-- zones while the pins filter down to the visible one.
-- Objective locations used to be collected here from the client's own POI
-- API. That is gone: it could only ever answer for the 25 quests with client
-- slots, and running it alongside the server-sent data meant two sources in
-- two coordinate spaces. UQ.LedgerPins() in UncappedQuestsLedger.lua is now
-- the single source, for the map pins and the arrow alike.

-- ---------------------------------------------------------------------------
-- update
-- ---------------------------------------------------------------------------

local updating = false

local function Update()
    -- WorldMapFrame_Update is hooked, and the click handler calls it again to
    -- refresh the selection blob. Without this guard that recurses.
    if updating then return end
    updating = true

    for i = 1, #pins do
        pins[i]:Hide()
        if pins[i].blob then pins[i].blob:Hide() end
    end

    if not db or not db.enabled or not WorldMapFrame or not WorldMapFrame:IsShown() then
        updating = false
        return
    end

    -- DBC space, to match the server-sent pin areas. GetCurrentMapAreaID
    -- reports one HIGHER than the DBC id; comparing the two raw put every pin
    -- on the neighbouring zone's map.
    local currentMap = UQ.CurrentDbcArea and UQ.CurrentDbcArea()
    local width, height = WorldMapButton:GetWidth(), WorldMapButton:GetHeight()
    if not currentMap or not width or width == 0 then
        updating = false
        return
    end

    -- Pins come from the LEDGER, not from QuestPOIGetIconInfo. The client can
    -- only answer that for the 25 quests it has slots for, so it can never draw
    -- a ledger quest -- and mixing the two sources meant two coordinate spaces
    -- (the client reports area ids one higher than the DBC) and two sets of
    -- bugs. The server sends every held quest's objectives; this draws them.
    local used = 0
    for _, o in ipairs(UQ.LedgerPins and UQ.LedgerPins() or {}) do
        if used >= MAX_PINS then break end

        -- What you still have to DO, versus where you hand it in. A turn-in
        -- marker is only useful once the quest is actually finished; before
        -- that it is noise sitting on top of the objectives.
        --
        -- objDone is the same rule one objective down: a quest with two item
        -- objectives in two different places painted BOTH areas even after one
        -- of them was finished, so the map -- and the arrow reading the same
        -- pins -- claimed two destinations for one remaining task.
        local show
        if o.isTurnIn then
            show = o.isComplete and db.showTurnIns
        else
            show = not o.isComplete and not o.objDone
        end

        -- An ignored quest is hidden everywhere, not just dropped from the
        -- route -- "stop showing me this" has to mean the map too.
        if UQ.IsIgnored(o.questID) then
            show = false
        end

        if show and o.dbcArea == currentMap then
            used = used + 1
            local pin = pins[used] or CreatePin(used)

            -- A ledger quest has no client log index at all, so the tooltip and
            -- click path must both cope with questIndex being nil.
            pin.questID = o.questID
            pin.questIndex = UQ.QuestLogIndex(o.questID)
            pin.pinTitle = o.title
            pin.pinComplete = o.isComplete
            pin:SetWidth(db.iconSize)
            pin:SetHeight(db.iconSize)
            if o.isTurnIn then
                SafeSetTexture(pin.icon, ICON_TURNIN)
            else
                SafeSetTexture(pin.icon, ICON_OBJECTIVE, ICON_TURNIN)
            end
            pin.icon:SetVertexColor(1, 1, 1)
            pin.label:SetText(db.showNumbers and used or "")

            pin:ClearAllPoints()
            pin:SetPoint("CENTER", WorldMapButton, "TOPLEFT",
                o.x * width, -o.y * height)
            pin:Show()

            -- Paint the area. The radius arrives in YARDS, so it has to be
            -- converted through the zone's world size -- the same map at a
            -- different frame size, or a bigger zone, changes the pixel answer.
            -- Per axis, so the painted shape matches the objective's real
            -- proportions. World X is the map's VERTICAL axis and world Y its
            -- horizontal one -- the same transpose the pin coordinates use.
            local pxH = UQ.YardsToPixels(o.dbcArea, o.halfY, width)          -- across
            local pxV = UQ.YardsToPixels(o.dbcArea, o.halfX, width)          -- down
            local cap = width * BLOB_MAX_FRACTION
            if pxH then pxH = math.min(pxH, cap) end
            if pxV then pxV = math.min(pxV, cap) end

            -- A point objective still deserves a small area rather than nothing.
            local minPx = pin:GetWidth() * 0.6
            pxH = math.max(pxH or 0, minPx)
            pxV = math.max(pxV or 0, minPx)

            if db.showBlobs and (o.halfX > 0 or o.halfY > 0) then
                pin.blobReady = true
                pin.blob:SetWidth(pxH * 2)
                pin.blob:SetHeight(pxV * 2)
                pin.blob:ClearAllPoints()
                pin.blob:SetPoint("CENTER", pin, "CENTER", 0, 0)

                -- Blizzard paints quest areas blue, so the map reads the way
                -- players already expect. Turn-ins stay green: that is a
                -- different statement ("done, come here"), not a different quest.
                local cr, cg, cb
                if o.isTurnIn then cr, cg, cb = 0.35, 1, 0.45
                else cr, cg, cb = 0.25, 0.55, 1 end

                -- Real outline when we have one, disc only as a fallback for a
                -- POI that shipped no polygon.
                local filled = false
                if o.verts then
                    -- World -> map pixels, anchored so the frame's top-left is
                    -- the outline's own bounding box.
                    local px = {}
                    local minPX, minPY = nil, nil
                    for i = 1, #o.verts, 2 do
                        local _, mx, my = UQ.MapPos(o.dbcArea, o.verts[i], o.verts[i + 1])
                        if not mx then px = nil break end
                        local sx, sy = mx * width, my * height
                        px[#px + 1] = sx
                        px[#px + 1] = sy
                        minPX = math.min(minPX or sx, sx)
                        minPY = math.min(minPY or sy, sy)
                    end

                    if px and #px >= 6 then
                        local maxPX, maxPY = minPX, minPY
                        for i = 1, #px, 2 do
                            px[i] = px[i] - minPX
                            px[i + 1] = px[i + 1] - minPY
                            maxPX = math.max(maxPX, px[i] + minPX)
                            maxPY = math.max(maxPY, px[i + 1] + minPY)
                        end

                        pin.blob:ClearAllPoints()
                        pin.blob:SetPoint("TOPLEFT", WorldMapButton, "TOPLEFT", minPX, -minPY)
                        pin.blob:SetWidth(math.max(1, maxPX - minPX))
                        pin.blob:SetHeight(math.max(1, maxPY - minPY))
                        pin.blob.fill:Hide()
                        filled = FillPolygon(pin.blob, px, cr, cg, cb) > 0
                    end
                end

                if not filled then
                    if pin.blob.bands then
                        for _, t in ipairs(pin.blob.bands) do t:Hide() end
                    end
                    pin.blob.fill:Show()
                    SafeSetTexture(pin.blob.fill, BLOB_TEXTURE)
                    -- Alpha lives in the texture, so only the hue is set here.
                    pin.blob.fill:SetVertexColor(cr, cg, cb)
                end

                -- Blizzard paints ONE blob -- the selected quest -- and that is
                -- why its map stays readable. Drawing all of them at once is
                -- unreadable at any opacity, so the default is hover-only and
                -- "all" is a deliberately faint background wash.
                if db.blobsOnHover then
                    pin.blob:Hide()
                else
                    pin.blob:SetAlpha(BLOB_ALPHA_ALL)
                    pin.blob:Show()
                end
            else
                pin.blobReady = false
                pin.blob:Hide()
            end
        end
    end

    -- Optional, off by default: quests you could go and PICK UP. Deliberately
    -- separate from everything above -- those pins are what you already owe,
    -- these are new work, and mixing them is what made the map unreadable.
    if db.showGivers and UQ.AvailableGiverPins then
        for _, g in ipairs(UQ.AvailableGiverPins(currentMap)) do
            if used >= MAX_PINS then break end
            used = used + 1

            local pin = pins[used] or CreatePin(used)
            pin.questID = g.questID
            pin.questIndex = nil
            pin.pinTitle = g.title
            pin.pinComplete = false
            pin.pinGiver = g.giver
            pin:SetWidth(db.iconSize)
            pin:SetHeight(db.iconSize)
            SafeSetTexture(pin.icon, ICON_GIVER)
            pin.icon:SetVertexColor(1, 1, 1)
            pin.label:SetText("")

            pin:ClearAllPoints()
            pin:SetPoint("CENTER", WorldMapButton, "TOPLEFT",
                g.x * width, -g.y * height)
            pin:Show()
        end
    end

    updating = false
end

-- ---------------------------------------------------------------------------
-- events
-- ---------------------------------------------------------------------------

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("QUEST_LOG_UPDATE")
f:RegisterEvent("QUEST_POI_UPDATE")
f:RegisterEvent("WORLD_MAP_UPDATE")

f:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        UncappedQuestsDB = UncappedQuestsDB or {}
        local s = UncappedQuestsDB
        for k, v in pairs(defaults) do
            if s[k] == nil then s[k] = v end
        end
        db = s
        UQ.db = db

        -- One-time bump: raising the DEFAULT does nothing for anyone who already
        -- has a saved value, and 18px was unreadable zoomed out. This only moves
        -- people still sitting on that old default -- a size someone actually
        -- chose is left alone.
        if not s.pinSizeBumped then
            s.pinSizeBumped = true
            if s.iconSize == 18 or s.iconSize == 28 then s.iconSize = defaults.iconSize end
        end

        UQ.ApplyBlizzardPOI()
        for _, r in ipairs(panelRefreshers) do r() end   -- resync the page
        return
    end

    if event == "QUEST_LOG_UPDATE" or event == "QUEST_POI_UPDATE" then
        -- (objective cache retired; the ledger burst is the refresh now)
    end

    if event == "QUEST_LOG_UPDATE" or event == "PLAYER_LOGIN" then
        -- Asks the client to (re)fetch POI records for the current log. Without
        -- this the first map open after login has nothing to draw.
        if QuestPOIUpdateIcons then QuestPOIUpdateIcons() end
    end

    Update()
end)

-- Same hook point WDM's AtlasPOI module uses, so pins are re-laid-out on every
-- map redraw: zone change, continent change, and map resize all route through it.
if type(WorldMapFrame_Update) == "function" then
    hooksecurefunc("WorldMapFrame_Update", Update)
end

-- Windowed <-> fullscreen resizes WorldMapButton, and every pin and blob
-- position is computed from its width and height. WorldMapFrame_Update does not
-- reliably fire on that transition, so the old layout was simply kept -- which
-- is why the small map worked and the full map did not.
if WorldMapButton then
    WorldMapButton:HookScript("OnSizeChanged", function() Update() end)
    WorldMapButton:HookScript("OnShow", function() Update() end)
end

if type(WorldMapFrame_Update) == "function" then
end

-- Called by the ledger module when a fresh burst lands, so the pins follow the
-- data even with the ledger window closed.
UQ.RefreshPins = Update

-- ---------------------------------------------------------------------------
-- Map filter button
-- ---------------------------------------------------------------------------
-- Sits beside WDM's tracking button and matches its styling, rather than adding
-- entries to WDM's own menu: that menu is a local captured inside its OnClick
-- closure, so reaching it would mean re-declaring WDM's entries here and having
-- them silently drift the next time WDM is updated.

local filterButton

local function BuildFilterMenu()
    local function toggle(key, refreshPOI)
        return function()
            db[key] = not db[key]
            if refreshPOI then UQ.ApplyBlizzardPOI() end
            Update()
        end
    end

    return {
        { text = "Quest map filters", isTitle = true },
        { text = "Objective pins", keepShownOnClick = 1,
          checked = function() return db.enabled end, func = toggle("enabled") },
        { text = "Paint objective areas", keepShownOnClick = 1,
          checked = function() return db.showBlobs end, func = toggle("showBlobs") },
        { text = "Areas only when hovering", keepShownOnClick = 1,
          checked = function() return db.blobsOnHover end, func = toggle("blobsOnHover") },
        { text = "Turn-in locations", keepShownOnClick = 1,
          checked = function() return db.showTurnIns end, func = toggle("showTurnIns") },
        { text = "Quests you could pick up", keepShownOnClick = 1,
          checked = function() return db.showGivers end, func = toggle("showGivers") },
        { text = "Number the pins", keepShownOnClick = 1,
          checked = function() return db.showNumbers end, func = toggle("showNumbers") },
        { text = "Replace Blizzard's objectives", keepShownOnClick = 1,
          checked = function() return db.hideBlizzardPOI end, func = toggle("hideBlizzardPOI", true) },
    }
end

local function EnsureFilterButton()
    if filterButton or not WorldMapButton then return end

    local b = CreateFrame("Button", "UncappedQuestFilterButton", WorldMapButton)
    b:SetWidth(32)
    b:SetHeight(32)
    b:SetFrameStrata("TOOLTIP")
    b:SetFrameLevel(WorldMapButton:GetFrameLevel() + 6)

    -- Tuck in beside WDM's tracking button when it exists, otherwise take the
    -- corner it would have occupied.
    b:ClearAllPoints()
    if _G.WDM_WorldMapButton then
        b:SetPoint("TOPRIGHT", _G.WDM_WorldMapButton, "TOPLEFT", 6, 0)
    else
        b:SetPoint("TOPRIGHT", WorldMapButton, "TOPRIGHT", -4, -4)
    end

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetWidth(25); bg:SetHeight(25)
    bg:SetPoint("TOPLEFT", 2, -4)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(20); icon:SetHeight(20)
    icon:SetPoint("TOPLEFT", 6, -5)
    SafeSetTexture(icon, ICON_OBJECTIVE, ICON_TURNIN)

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetWidth(54); border:SetHeight(54)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Quest map filters", 1, 1, 1)
        GameTooltip:AddLine("What this map shows you.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local menuFrame
    b:SetScript("OnClick", function(self)
        if not menuFrame then
            menuFrame = CreateFrame("Frame", "UncappedQuestFilterMenu", UIParent, "UIDropDownMenuTemplate")
        end
        EasyMenu(BuildFilterMenu(), menuFrame, self, 0, 0, "MENU", 0)
    end)

    filterButton = b
end

-- WDM builds its button on enable, which is later than this file runs, so the
-- anchor is resolved the first time the map is actually shown.
if WorldMapFrame then
    WorldMapFrame:HookScript("OnShow", EnsureFilterButton)
end

-- ---------------------------------------------------------------------------
-- Settings page (ESC > Interface > AddOns > Uncapped > Quests). Guarded so the
-- addon still works standalone if UncappedOptions is missing.
-- ---------------------------------------------------------------------------

if UncappedUI then
    local panel, L = UncappedUI.CreatePanel("Quests",
        "Pins every quest objective in your log on the world map, not just the quest you have selected.")

    L:Header("World map pins")
    panelRefreshers[#panelRefreshers + 1] = L:Check("Show quest objective pins",
        function() return db.enabled end,
        function(v) db.enabled = v; Update() end).uncappedRefresh
    panelRefreshers[#panelRefreshers + 1] = L:Check("Paint objective areas",
        function() return db.showBlobs end,
        function(v) db.showBlobs = v; Update() end).uncappedRefresh
    panelRefreshers[#panelRefreshers + 1] = L:Check("Only when hovering a pin",
        function() return db.blobsOnHover end,
        function(v) db.blobsOnHover = v; Update() end).uncappedRefresh
    panelRefreshers[#panelRefreshers + 1] = L:Check("Show turn-in locations",
        function() return db.showTurnIns end,
        function(v) db.showTurnIns = v; Update() end).uncappedRefresh
    panelRefreshers[#panelRefreshers + 1] = L:Check("Show quests you could pick up",
        function() return db.showGivers end,
        function(v) db.showGivers = v; Update() end).uncappedRefresh
    panelRefreshers[#panelRefreshers + 1] = L:Check("Number the pins",
        function() return db.showNumbers end,
        function(v) db.showNumbers = v; Update() end).uncappedRefresh
    panelRefreshers[#panelRefreshers + 1] = L:Check("Replace Blizzard's map objectives",
        function() return db.hideBlizzardPOI end,
        function(v) db.hideBlizzardPOI = v; UQ.ApplyBlizzardPOI(); Update() end).uncappedRefresh
    panelRefreshers[#panelRefreshers + 1] = L:Slider("Pin size", 12, 56, 1,
        function() return db.iconSize end,
        function(v) db.iconSize = v; Update() end, "%d").uncappedRefresh

    L:Gap(6)
    L:Note("|cff808080Objective locations come from the realm itself, so custom quests are "
        .. "included automatically. A quest with no pin has no objective location recorded.|r", 40)

    L:Gap(6)
    L:Header("Quests you have set aside")
    L:Note("Right-clicking the objective arrow sends a quest to the back of your route; "
        .. "right-clicking the teal 'Pick up' arrow ignores a quest entirely. Both stick "
        .. "until you undo them, so this is where you get them back.", 40)

    -- The only way back for someone who ignored a quest and then forgot which:
    -- an ignored quest is invisible everywhere by design, so without this button
    -- there is no route to undoing it at all.
    local clearBtn
    clearBtn = L:Button("Clear all", function()
        UQ.ClearOverrides()
        Update()
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Cleared every set-aside and ignored quest.")
        if clearBtn and clearBtn.uncappedRefresh then clearBtn.uncappedRefresh() end
    end, 280)

    -- Label carries the counts, so the page says whether there is anything to
    -- clear rather than making it a guess.
    clearBtn.uncappedRefresh = function()
        local deferred, ignored = UQ.CountOverrides()
        clearBtn:SetText(string.format("Clear all (%d set aside, %d ignored)", deferred, ignored))
    end
    clearBtn.uncappedRefresh()
    panelRefreshers[#panelRefreshers + 1] = clearBtn.uncappedRefresh
end

SLASH_UNCAPPEDQUESTS1 = "/uquests"
SLASH_UNCAPPEDQUESTS2 = "/uq"
SlashCmdList["UNCAPPEDQUESTS"] = function()
    if not db then return end
    db.enabled = not db.enabled
    Update()
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Uncapped Quests]|r map pins "
        .. (db.enabled and "on" or "off"))
end

-- ===========================================================================
-- Mouseover tooltip: "this counts for something you are carrying"
--
-- The client's own tooltip says nothing about quests, and for a LEDGER quest it
-- could not: those have no log entry for it to read. The ledger already knows
-- every objective and, since QLR, every objective's target entry -- so the
-- answer is a lookup rather than anything expensive.
--
-- Only incomplete objectives are shown (see UQ.QuestsForTarget): a mob you have
-- already finished with is not news.
-- ===========================================================================

-- Creature entry out of a 3.3.5 GUID string.
--
-- Layout is "0x" + 4 hex high + 6 hex entry + 6 hex counter. Note the 6, not 4:
-- the widespread `sub(9, 12)` snippet reads only 16 bits of the entry, which is
-- fine for stock creatures but silently truncates this realm's custom entries
-- above 65535.
--
-- Only unit-shaped GUIDs carry an entry worth matching: F13 creature,
-- F15 vehicle. Players (0x0), items and corpses have none.
local function EntryFromGuid(guid)
    if not guid or #guid < 18 then return nil end

    local high = guid:sub(3, 5)
    if high ~= "F13" and high ~= "F15" then return nil end

    return tonumber(guid:sub(7, 12), 16)
end

local function AddQuestLines(tooltip, unit)
    if not db or not db.enabled or not UQ.QuestsForTarget then return end

    local entry = EntryFromGuid(UnitGUID(unit))
    if not entry then return end

    local hits = UQ.QuestsForTarget(entry)
    if #hits == 0 then return end

    tooltip:AddLine(" ")
    for _, hit in ipairs(hits) do
        -- Title in quest-log gold, progress dimmed behind it -- the same reading
        -- order the objective tracker uses.
        tooltip:AddDoubleLine(
            "|cffffd100" .. (hit.title or "?") .. "|r",
            string.format("|cff808080%d/%d|r", hit.have, hit.need))
    end
    tooltip:Show()   -- re-layout: lines added after the tooltip is up are clipped otherwise
end

GameTooltip:HookScript("OnTooltipSetUnit", function(self)
    local _, unit = self:GetUnit()
    if unit then
        AddQuestLines(self, unit)
    end
end)
