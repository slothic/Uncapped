--[[
  Uncapped Quests -- waypoint arrow and objective routing.

  Points a rotating arrow at whichever objective you should do next, and works
  that out by routing rather than by picking the closest one and stopping there:
  nearest-neighbour from your position, then a 2-opt pass to unpick the crossed
  edges greedy always leaves behind. That is the part QuestHelper did that a
  plain "nearest objective" arrow does not -- the closest objective is often the
  wrong one to walk to first if it sends you back the way you came.

  EVERYTHING HERE WORKS IN RAW SERVER WORLD COORDINATES, in yards, and compares
  positions only within one mapID. That is deliberate, and replaced an earlier
  version built on Astrolabe. The history is worth keeping because every bug in
  it came from the same root:

    * Astrolabe works in continent/zone INDICES. Quest data is keyed by map AREA
      id. Nothing in the client maps between them, so the addon rebuilt the
      mapping at runtime by cycling SetMapZoom over all ~108 zones -- which
      drags the world map around as a visible side effect.
    * Astrolabe's WorldMapSize has a catch-all metatable returning a zero-SIZED
      zone for anything it does not recognise, so a mismatched index did not
      fail loudly: ComputeDistance multiplied by a zero width and returned
      EXACTLY 0. Bogus "0 yards" candidates then beat every real one, and the
      arrow confidently pointed at a quest giver on the far side of Northrend.
    * Astrolabe:GetCurrentPlayerPosition() calls SetMapToCurrentZone/SetMapZoom
      when the open map is not showing your zone. Called from an OnUpdate that
      re-dragged the map every frame: the client crawled with the map open, and
      right-click-to-zoom-out looked broken because the zoom was undone before
      the next frame drew.

  UncappedMapAreas (shipped, generated) removes the whole class: it carries each
  map area's world-coordinate bounds, so this file converts ONLY the player's
  own position, and only when the client did not already hand it over.
]]

local UQ = UncappedQuests
local ADDON = "UncappedQuests"

local ARROW_TEXTURE      = "Interface\\AddOns\\UncappedQuests\\arrow_image"
local ARROW_DOWN_TEXTURE = "Interface\\AddOns\\UncappedQuests\\arrow_image_down"

-- Positions on different maps share no coordinate space. Reachable, but last.
local UNREACHABLE = 1e9

local ROUTE_INTERVAL = 2.0      -- seconds between full re-routes
local POS_INTERVAL   = 0.25     -- seconds between player position samples

local defaults = {
    arrowEnabled = true,
    arrowScale   = 1.0,
    arrowLocked  = false,
    arrowPoint   = { "CENTER", "UIParent", "CENTER", 0, 180 },
}

-- Private copy of the defaults up front: the settings page is built while this
-- file runs, before ADDON_LOADED provides the SavedVariable, and UncappedUI's
-- Slider formats its getter's result immediately -- nil there kills the file
-- and takes every slash command below it with it.
local db = {}
for k, v in pairs(defaults) do db[k] = v end

local panelRefreshers = {}
local route = {}
local target
local sinceRoute = ROUTE_INTERVAL

-- ---------------------------------------------------------------------------
-- coordinates
-- ---------------------------------------------------------------------------

-- Normalised position on a map area -> raw world coordinates.
-- Inverse of the transform in tools/Generate-QuestGivers.py. The axes
-- transpose: screen x comes from the Left/Right (world Y) bounds and screen y
-- from Top/Bottom (world X).
-- OFF BY ONE, and it is the client's, not ours: GetCurrentMapAreaID() and
-- GetQuestWorldMapAreaID() both return the WorldMapArea DBC id PLUS ONE.
--
-- Measured, not guessed. Standing at the Argent Tournament the client reported
-- area 493, but the position is inside area 492's bounds at (0.697, 0.229) --
-- and feeding those same normalised coords to 493's bounds reproduced the wrong
-- world position exactly (6628, 3887 instead of 8471, 1076, ~3400 yards out).
--
-- It fails silently because the neighbouring zone's bounds are a perfectly
-- valid rectangle: you get a confident, plausible, completely wrong answer.
-- The fallback covers any id where the offset does not hold.
function UQ.WorldPos(clientAreaID, mx, my)
    if not (UncappedMapAreas and clientAreaID) then return nil end
    local a = UncappedMapAreas[clientAreaID - 1] or UncappedMapAreas[clientAreaID]
    if not a then return nil end
    local mapID, left, right, top, bottom = a[1], a[2], a[3], a[4], a[5]
    -- Degenerate (zero-span) bounds -- some WorldMapArea rows ship all-zero in
    -- the DBC (Dalaran, plus instance maps like The Nexus). Computing against
    -- them collapses every position to world-origin (0,0), which read as the
    -- player being ~4000 yards from where they stand. Better no answer than a
    -- confidently wrong one. Dalaran itself is given real bounds in the data;
    -- this is the backstop for anything else.
    if (top - bottom) == 0 or (left - right) == 0 then return nil end
    return mapID, top - my * (top - bottom), left - mx * (left - right)
end

-- World coordinates -> normalised position on a map area, the inverse of
-- WorldPos above.
--
-- Takes the RAW WorldMapArea DBC id, NOT the client's +1 flavour. Server-sent
-- POI data carries the dbc id directly, so applying the -1 correction here
-- would land on the neighbouring zone -- the exact bug that put the player in
-- Ymirheim when they were standing at the Argent Tournament.
function UQ.MapPos(dbcAreaID, wx, wy)
    local a = UncappedMapAreas and UncappedMapAreas[dbcAreaID]
    if not a then return nil end

    local mapID, left, right, top, bottom = a[1], a[2], a[3], a[4], a[5]
    local width, height = left - right, top - bottom
    if width == 0 or height == 0 then return nil end

    return mapID, (left - wy) / width, (top - wx) / height
end

-- The client reports map areas one higher than the DBC id. Everything that
-- compares a server-sent area against "the map on screen" goes through here so
-- the correction lives in exactly one place.
function UQ.CurrentDbcArea()
    local id = GetCurrentMapAreaID and GetCurrentMapAreaID()
    return id and (id - 1) or nil
end

-- Straight-line yards, or nil when the two points are not on the same map.
function UQ.WorldDistance(a, b)
    if not (a and b) or a.map ~= b.map then return nil end
    local dx, dy = b.wx - a.wx, b.wy - a.wy
    return math.sqrt(dx * dx + dy * dy), dx, dy
end

local WorldPos, WorldDistance = UQ.WorldPos, UQ.WorldDistance

local cachedPos, cachedAt = nil, 0

-- GetPlayerMapPosition reports against whatever map is CURRENTLY DISPLAYED, and
-- returns 0,0 when that is not the player's own zone. The cheap path is the
-- common one: if the client already gave us a position, no map call is needed
-- at all. Only when it did not, and only when the player is not looking at the
-- map, do we re-point it -- never from a hot loop, never while the map is open.
function UQ.PlayerNode()
    local now = GetTime()
    if cachedPos and (now - cachedAt) < POS_INTERVAL then return cachedPos end
    cachedAt = now

    local mx, my = GetPlayerMapPosition("player")
    if (not mx or (mx == 0 and my == 0)) then
        if WorldMapFrame and WorldMapFrame:IsShown() then return cachedPos end
        SetMapToCurrentZone()
        mx, my = GetPlayerMapPosition("player")
        -- Still nothing: an instance, or otherwise off the world map.
        if not mx or (mx == 0 and my == 0) then return nil end
    end

    local mapID, wx, wy = WorldPos(GetCurrentMapAreaID(), mx, my)
    if not mapID then return cachedPos end

    cachedPos = { map = mapID, wx = wx, wy = wy }
    return cachedPos
end

function UQ.ForgetPlayerPos()
    cachedPos = nil
end

local PlayerNode = UQ.PlayerNode

-- ---------------------------------------------------------------------------
-- routing
-- ---------------------------------------------------------------------------

local function Dist(a, b)
    return (WorldDistance(a, b)) or UNREACHABLE
end

-- Greedy nearest-neighbour, then 2-opt. Both are cheap at this size: the quest
-- log caps at 25, so the distance matrix is at most 25x25.
local function BuildRoute(player)
    local pending = {}

    -- Same single source as the map pins: the ledger covers every held quest,
    -- where QuestPOIGetIconInfo only ever covers the 25 with client slots. The
    -- server already sends world coordinates, so there is no conversion here at
    -- all -- and no second coordinate space to get wrong.
    for _, o in ipairs(UQ.LedgerPins and UQ.LedgerPins() or {}) do
        -- What you still have to DO, versus where you hand it in -- the same
        -- rule the map pins have always applied, which this had never mirrored.
        --
        -- Without it the route included the TURN-IN location (ObjectiveIndex -1,
        -- i.e. the questgiver) for quests that are not finished, so the arrow
        -- sent you back to the NPC you took the quest from. Item-drop quests
        -- showed it worst: Blizzard's data often records no objective polygon
        -- for "collect N of X off mobs", while the turn-in POI is always
        -- present, so the questgiver was frequently the only -- and therefore
        -- nearest -- node the quest had. It also routed you back to the
        -- objective area of quests you had ALREADY completed, the same bug
        -- mirrored.
        --
        -- objDone carries the same idea per OBJECTIVE rather than per quest: an
        -- area whose objective is already filled is not somewhere to be sent,
        -- even while the quest itself is unfinished.
        local wanted
        if o.isTurnIn then
            wanted = o.isComplete
        else
            wanted = not o.isComplete and not o.objDone
        end

        if wanted and o.map == player.map and not UQ.IsIgnored(o.questID) then
            pending[#pending + 1] = {
                map = o.map, wx = o.wx, wy = o.wy,
                questID    = o.questID,
                questIndex = UQ.QuestLogIndex and UQ.QuestLogIndex(o.questID) or nil,
                title      = o.title,
                isComplete = o.isComplete,
                isTurnIn   = o.isTurnIn,
            }
        end
    end

    local ordered, cur = {}, player
    while #pending > 0 do
        local best, bestD = 1, Dist(cur, pending[1])
        for i = 2, #pending do
            local d = Dist(cur, pending[i])
            if d < bestD then best, bestD = i, d end
        end
        cur = table.remove(pending, best)
        ordered[#ordered + 1] = cur
    end

    -- 2-opt over an open path with the start pinned to the player. Reversing
    -- ordered[i..k] only changes the two edges at the seam, so the comparison
    -- is local even though the reversal is not.
    --
    -- Distances are memoised into `dm` first. The naive version recomputed them
    -- inside the doubly-nested loop, so a full log ran on the order of 25,000
    -- sqrt calls every re-route -- felt as a periodic spike. The pass cap is
    -- also 6, not 40: on <= 25 nodes this converges in two or three, and the
    -- remainder was pure worst-case insurance nobody was collecting on.
    local n = #ordered
    local dm = {}
    local function D(a, b)
        local ka = a or 0
        local row = dm[ka]
        if not row then row = {}; dm[ka] = row end
        local v = row[b]
        if v == nil then
            v = Dist(ka == 0 and player or ordered[ka], ordered[b])
            row[b] = v
        end
        return v
    end

    local improved, guard = true, 0
    while improved and guard < 6 do
        improved, guard = false, guard + 1
        for i = 1, n - 1 do
            for k = i + 1, n do
                local before = D(i - 1, i) + ((k < n) and D(k, k + 1) or 0)
                local after  = D(i - 1, k) + ((k < n) and D(i, k + 1) or 0)

                if after < before - 0.5 then
                    local lo, hi = i, k
                    while lo < hi do
                        ordered[lo], ordered[hi] = ordered[hi], ordered[lo]
                        lo, hi = lo + 1, hi - 1
                    end
                    -- The memo is keyed by POSITION, and positions just moved.
                    dm = {}
                    improved = true
                end
            end
        end
    end

    -- "Not right now" beats distance. Deferred quests keep the optimised order
    -- the solver just worked out among themselves, but all of them sit behind
    -- everything else. Applied AFTER routing rather than by dropping them from
    -- `pending`, so a route made entirely of deferred objectives is still
    -- sensibly ordered instead of arbitrary.
    local keep, defer = {}, {}
    for _, o in ipairs(ordered) do
        if UQ.IsDeferred(o.questID) then
            defer[#defer + 1] = o
        else
            keep[#keep + 1] = o
        end
    end
    for _, o in ipairs(defer) do
        keep[#keep + 1] = o
    end

    return keep
end

-- ---------------------------------------------------------------------------
-- arrow
-- ---------------------------------------------------------------------------

-- Sized to the sprite cell's aspect ratio (56x42). A square frame stretches the
-- arrow, which is what the old hand-rotated texture needed and this does not.
local arrow = CreateFrame("Button", "UncappedQuestArrow", UIParent)
arrow:SetWidth(56)
arrow:SetHeight(42)
arrow:SetMovable(true)
arrow:EnableMouse(true)
arrow:RegisterForDrag("LeftButton")
arrow:RegisterForClicks("LeftButtonUp", "RightButtonUp")
arrow:Hide()

arrow.tex = arrow:CreateTexture(nil, "OVERLAY")
arrow.tex:SetAllPoints()
arrow.tex:SetTexture(ARROW_TEXTURE)

-- Both arrows are the same sprite and differ only by tint, which is not enough
-- on its own -- especially with the objective arrow's colour shifting red to
-- green as you turn. A standing caption says which one you are reading.
arrow.caption = arrow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
arrow.caption:SetPoint("BOTTOM", arrow, "TOP", 0, 20)
arrow.caption:SetText("|cffffd100Objective|r")

arrow.title = arrow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
arrow.title:SetPoint("BOTTOM", arrow, "TOP", 0, 2)

arrow.dist = arrow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
arrow.dist:SetPoint("TOP", arrow, "BOTTOM", 0, -2)

-- What you are actually meant to DO, under the distance. The arrow used to show
-- only the quest's title, which tells you where to stand but not what to do once
-- you are there.
arrow.objective = arrow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
arrow.objective:SetPoint("TOP", arrow.dist, "BOTTOM", 0, -2)
arrow.objective:SetWidth(220)
arrow.objective:SetJustifyH("CENTER")

-- The quest's usable item, clickable straight from the arrow.
--
-- SecureActionButtonTemplate with type="item": the click runs through the
-- secure code path, which is the only way an addon may use an item at all.
-- That also means the attributes CANNOT be changed in combat -- Blizzard locks
-- secure frames down -- so RefreshItem below skips the update rather than
-- erroring, and picks it up on the next refresh once combat ends.
arrow.itemButton = CreateFrame("Button", "UncappedQuestArrowItem", arrow, "SecureActionButtonTemplate")
arrow.itemButton:SetWidth(36)
arrow.itemButton:SetHeight(36)
arrow.itemButton:SetPoint("TOP", arrow.objective, "BOTTOM", 0, -4)
arrow.itemButton:RegisterForClicks("AnyUp")
arrow.itemButton:SetAttribute("type", "item")
arrow.itemButton:Hide()

arrow.itemButton.icon = arrow.itemButton:CreateTexture(nil, "ARTWORK")
arrow.itemButton.icon:SetAllPoints()

arrow.itemButton.border = arrow.itemButton:CreateTexture(nil, "OVERLAY")
arrow.itemButton.border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
arrow.itemButton.border:SetPoint("CENTER")
arrow.itemButton.border:SetWidth(58)
arrow.itemButton.border:SetHeight(58)

arrow.itemButton.count = arrow.itemButton:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
arrow.itemButton.count:SetPoint("BOTTOMRIGHT", -2, 2)

arrow.itemButton:SetScript("OnEnter", function(self)
    if not self.itemLink then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(self.itemLink)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cff808080Click to use.|r")
    GameTooltip:Show()
end)
arrow.itemButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

arrow.next = arrow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
arrow.next:SetPoint("TOP", arrow.itemButton, "BOTTOM", 0, -2)

-- What to do at the destination, under the distance readout.
--
-- Prefers the LEDGER's own objective list, which covers every held quest; the
-- client's GetQuestLogLeaderBoard only answers for the 25 with a log slot, and
-- those are exactly the quests the ledger exists to supplement.
local function RefreshObjective(self, target)
    if not target then
        self.objective:SetText("")
        return
    end

    if target.isTurnIn or target.isComplete then
        self.objective:SetText("|cff40ff40Ready to turn in|r")
        return
    end

    local obj = UQ.FirstIncompleteObjective and UQ.FirstIncompleteObjective(target.questID)
    if obj then
        self.objective:SetText(string.format("%s  |cff808080%d/%d|r",
            obj.label or "?", obj.have or 0, obj.need or 0))
        return
    end

    -- Fall back to the client log for a quest the ledger has not answered for.
    local n = target.questIndex and (GetNumQuestLeaderBoards(target.questIndex) or 0) or 0
    for j = 1, n do
        local text, _, finished = GetQuestLogLeaderBoard(j, target.questIndex)
        if text and not finished then
            self.objective:SetText(text)
            return
        end
    end

    self.objective:SetText("")
end

-- The quest's usable item, if it has one.
--
-- GetQuestLogSpecialItemInfo is the same source the default quest tracker uses
-- for its item button, and it needs a LOG INDEX -- so a ledger quest past the
-- 25-slot wall has no item here. That is a client limitation, not an oversight:
-- nothing client-side can resolve an item for a quest the client does not know
-- it has.
local function RefreshItem(self, target)
    local button = self.itemButton

    -- Secure frames are locked during combat. Leave whatever is already there
    -- rather than erroring; the next target change out of combat fixes it.
    if InCombatLockdown() then
        return
    end

    -- Guarded: this API is the quest tracker's own, but a missing global here
    -- would throw on every target change, and a hard error in an OnUpdate path
    -- takes the whole addon down with it.
    local link, texture, charges
    if target and target.questIndex and type(GetQuestLogSpecialItemInfo) == "function" then
        link, texture, charges = GetQuestLogSpecialItemInfo(target.questIndex)
    end

    if not link or not texture then
        button.itemLink = nil
        button:SetAttribute("item", nil)
        button:Hide()
        return
    end

    button.itemLink = link
    button.icon:SetTexture(texture)
    button.count:SetText((charges and charges > 1) and charges or "")
    -- The link works as the attribute value and is unambiguous where a plain
    -- name is not (two items can share a name across item levels).
    button:SetAttribute("item", link)
    button:Show()
end

-- Frame selection for the TomTom-derived arrow art. See LICENSE-arrow.txt --
-- the textures and this logic come from TomTom via QuestHelper's arrow.lua,
-- under a 3-clause BSD licence whose notice ships alongside them.
--
-- These are PRE-RENDERED SPRITE SHEETS, not a rotated texture: 512x512 holding
-- 108 headings in a 9-wide grid of 56x42 cells. That is why it looks smooth --
-- rotating a texture by hand (the old approach here) samples outside [0,1] at
-- the corners and clamps, which frays the edges.
local ARROW_CELLS, ARROW_COLS = 108, 9
local ARROW_W, ARROW_H, SHEET = 56, 42, 512

-- The arrival animation is a second sheet: 55 frames of 53x70, played at 20fps.
local DOWN_FRAMES, DOWN_COLS = 55, 9
local DOWN_W, DOWN_H = 53, 70
local ARRIVE_YARDS = 10

local function SetCell(tex, cell, cols, cw, ch)
    local column = cell % cols
    local row = math.floor(cell / cols)
    tex:SetTexCoord(
        (column * cw) / SHEET, ((column + 1) * cw) / SHEET,
        (row * ch) / SHEET,    ((row + 1) * ch) / SHEET)
end

function UQ.SetArrowHeading(tex, angle)
    SetCell(tex, math.floor(angle / (math.pi * 2) * ARROW_CELLS + 0.5) % ARROW_CELLS,
        ARROW_COLS, ARROW_W, ARROW_H)
end

function UQ.SetArrowArriving(tex)
    SetCell(tex, math.floor(math.fmod(GetTime() * 20, DOWN_FRAMES)),
        DOWN_COLS, DOWN_W, DOWN_H)
end

-- World coordinates put +X north and +Y west, so dx is the northward component
-- and dy the westward one. The bearing counted ANTICLOCKWISE from north is then
-- atan2(west, north) = atan2(dy, dx), which is the same sense GetPlayerFacing
-- uses -- so the two SUBTRACT to give the angle relative to where the player is
-- looking.
--
-- This previously read atan2(-dy, dx) + facing, which is the exact NEGATION:
-- a mirrored arrow, correct only when the target was dead ahead or behind.
-- Cross-checked against TomTom's own implementation, which computes
-- atan2(-dx, -dy) - facing over Astrolabe's east/south deltas -- the same thing
-- once the axes are matched up. (Note TomTom works in DEGREES there: WoW's
-- global atan2 returns degrees, unlike math.atan2. We use math.atan2.)
function UQ.Bearing(dx, dy)
    return math.atan2(dy, dx) - (GetPlayerFacing() or 0)
end

-- Three-stop colour blend. There is NO ColorGradient global on 3.3.5a -- it is
-- absent from the client binary entirely; QuestHelper carries its own local
-- copy in arrow.lua, and calling it without bringing the definition across
-- threw once per frame. Same BSD-licensed origin as the rest of the arrow (see
-- LICENSE-arrow.txt), rewritten for the fixed three-stop case used here.
local function Gradient3(perc, r1, g1, b1, r2, g2, b2, r3, g3, b3)
    if perc <= 0 then return r1, g1, b1 end
    if perc >= 1 then return r3, g3, b3 end

    if perc < 0.5 then
        local t = perc * 2
        return r1 + (r2 - r1) * t, g1 + (g2 - g1) * t, b1 + (b2 - b1) * t
    end

    local t = (perc - 0.5) * 2
    return r2 + (r3 - r2) * t, g2 + (g3 - g2) * t, b2 + (b3 - b2) * t
end

arrow:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Objective", 1, 0.82, 0)
    GameTooltip:AddLine("What to do next, ordered by travel distance.", 0.7, 0.7, 0.7)
    if target then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(target.title or "", 1, 1, 1)
        if target.isComplete then
            GameTooltip:AddLine("Ready to turn in.", 0.4, 0.9, 0.4)
        end
    end
    GameTooltip:AddLine(" ")
    if target and UQ.IsDeferred(target.questID) then
        GameTooltip:AddLine("|cff808080Left-click selects the quest. Right-click restores it to its normal place.|r")
    else
        GameTooltip:AddLine("|cff808080Left-click selects the quest. Right-click sends it to the back (right-click again to undo).|r")
    end
    GameTooltip:Show()
end)
arrow:SetScript("OnLeave", function() GameTooltip:Hide() end)

arrow:SetScript("OnDragStart", function(self)
    if not db.arrowLocked then self:StartMoving() end
end)
arrow:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint()
    db.arrowPoint = { p, "UIParent", rp, x, y }
end)

arrow:SetScript("OnClick", function(self, button)
    if not target then return end
    if button == "RightButton" then
        -- Push this objective to the back of the route rather than dropping it,
        -- so "not right now" does not mean "never".
        --
        -- This used to reorder the `route` array in place, which looked right
        -- for about two seconds and then undid itself: the ticker below rebuilds
        -- the whole route from scratch every ROUTE_INTERVAL, sorted by travel
        -- distance, so the demoted objective was immediately promoted back to
        -- the front. The decision has to be recorded somewhere BuildRoute reads,
        -- which is what UQ.SetDeferred does -- and being in SavedVariables it now
        -- also survives a relog.
        --
        -- Toggling, not one-way: right-clicking the same quest again brings it
        -- back, otherwise there is no way to undo a misclick short of the
        -- settings page.
        local nowDeferred = UQ.ToggleDeferred(target.questID)
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r "
            .. (target.title or "That quest")
            .. (nowDeferred and " sent to the back of your route." or " restored to its normal place."))
        -- Re-route immediately so the arrow visibly moves on the click instead
        -- of waiting out the rest of the tick interval.
        local player = PlayerNode()
        if player then
            route = BuildRoute(player) or route
        end
        target = route[1]
    else
        -- A ledger quest has no client log index at all -- that is the entire
        -- reason the ledger exists -- so questIndex is legitimately nil for any
        -- quest past the client's 25 slots. Passing nil straight to
        -- SelectQuestLogEntry throws "Usage: SelectQuestLogEntry(index)", which
        -- is what players were seeing on left-click. The map pin has always
        -- guarded this; the arrow never did. Same fallback: send them to the
        -- one window that CAN show the quest.
        if not target.questIndex then
            -- Open the ledger ON this quest, not just open the ledger. Landing
            -- on an unfiltered list and having to find the quest by hand is the
            -- thing the click was supposed to save.
            if UQ.FocusLedgerQuest then
                UQ.FocusLedgerQuest(target.questID)
            elseif UQ.ToggleLedger then
                UQ.ToggleLedger()
            end
            return
        end

        SelectQuestLogEntry(target.questIndex)
        if QuestLog_Update then QuestLog_Update() end
    end
end)

local function ApplyLayout()
    arrow:SetScale(db.arrowScale or 1)
    arrow:ClearAllPoints()
    local p = db.arrowPoint or defaults.arrowPoint
    arrow:SetPoint(p[1], UIParent, p[3], p[4], p[5])
end

-- Switch between the two sprite sheets ATOMICALLY.
--
-- The arrow is drawn by windowing a sheet with SetTexCoord, so the texture, the
-- cell geometry and the frame's own size are three halves of one thing: window a
-- 53x70 sheet into a 56x42 frame and you get a stretched arrow with a slice of
-- the neighbouring cell hanging off it, which is exactly what a player caught on
-- screen.
--
-- This used to be three separate calls guarded by a self.arriving flag that was
-- set FIRST, which makes a half-applied swap reachable: anything that stops the
-- handler partway -- and it calls into routing, the ledger and Blizzard's quest
-- API -- leaves the flag claiming the swap happened when only part of it did,
-- and the guard then reads as done so nothing ever retries. That is a stuck
-- state until reload, and it is the only way the two can disagree.
--
-- Which of those paths actually bit is not established; closing the window is
-- cheaper than proving it.
--
-- So: one function, size and texture together, and the marker written LAST, only
-- once everything it stands for has actually been applied. Re-entering with the
-- sheet already set costs one string compare.
local SHEETS = {
    heading = { texture = ARROW_TEXTURE,      w = ARROW_W, h = ARROW_H },
    down    = { texture = ARROW_DOWN_TEXTURE, w = DOWN_W,  h = DOWN_H },
}

local function UseSheet(frame, which)
    if frame.uqSheet == which then return end

    local sheet = SHEETS[which]
    if not sheet then return end

    frame.tex:SetTexture(sheet.texture)
    frame:SetWidth(sheet.w)
    frame:SetHeight(sheet.h)
    frame.uqSheet = which
end

-- The ticker CANNOT live on the arrow itself: OnUpdate does not fire on a hidden
-- frame, and the arrow starts hidden, so it would sit there forever waiting for
-- the handler that was supposed to show it.
local driver = CreateFrame("Frame")

driver:SetScript("OnUpdate", function(_, elapsed)
    local self = arrow

    if not db.arrowEnabled then
        self:Hide()
        return
    end

    local player = PlayerNode()
    if not player then
        self:Hide()
        return
    end

    -- Throttle on TIME ONLY. An earlier version also re-routed whenever `target`
    -- was nil, which sounds like a harmless "retry until we find something" --
    -- but having nothing to point at is the steady state whenever the log has no
    -- routable objective, so it re-ran the whole route every single frame:
    -- CollectObjectives walks the quest log calling GetQuestLink and
    -- QuestPOIGetIconInfo per quest, and an uncached POI lookup asks the SERVER.
    -- A failed route has to back off exactly like a successful one.
    sinceRoute = sinceRoute + elapsed
    if sinceRoute >= ROUTE_INTERVAL then
        sinceRoute = 0
        route = BuildRoute(player)
        target = route[1]
    end

    if not target then
        self:Hide()
        return
    end

    local dist, dx, dy = WorldDistance(player, target)
    if not dist then
        self:Hide()
        return
    end

    self:Show()

    if dist <= ARRIVE_YARDS then
        -- Arrived: swap to the animated down-arrow, held green.
        UseSheet(self, "down")
        self.tex:SetVertexColor(0, 1, 0)
        UQ.SetArrowArriving(self.tex)
    else
        UseSheet(self, "heading")

        local angle = UQ.Bearing(dx, dy)
        UQ.SetArrowHeading(self.tex, angle)

        -- Red when it is behind you, through yellow, to green when you are
        -- walking straight at it. `perc` is how aligned you are, 0..1.
        local perc = math.abs((math.pi - math.abs(angle)) / math.pi)
        if perc > 1 then perc = 2 - perc end
        self.tex:SetVertexColor(Gradient3(perc, 1, 0, 0, 1, 1, 0, 0, 1, 0))
    end

    -- Only touch the font strings when the value actually changes. Formatting
    -- and concatenating three strings per frame is pure garbage for the
    -- collector to chase, and that shows up as stutter.
    if self.uqTarget ~= target then
        self.uqTarget = target
        self.title:SetText(target.title or "")
        if target.isComplete then
            self.title:SetTextColor(0.4, 0.9, 0.4)
        else
            self.title:SetTextColor(1, 0.82, 0)
        end

        RefreshObjective(self, target)
        RefreshItem(self, target)

        local after = route[2]
        self.next:SetText(after and ("next: " .. (after.title or "")) or "")
    end

    local whole = math.floor(dist)
    if self.uqDist ~= whole then
        self.uqDist = whole
        self.dist:SetText(whole .. " yd")
    end
end)

-- ---------------------------------------------------------------------------
-- init
-- ---------------------------------------------------------------------------

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")

f:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        UncappedQuestsDB = UncappedQuestsDB or {}
        local s = UncappedQuestsDB
        for k, v in pairs(defaults) do
            if s[k] == nil then s[k] = v end
        end
        db = s

        -- Retired: an earlier build cached a runtime-derived continent/zone
        -- lookup here. It is gone, and so is the coordinate space it served.
        s.mapLookup, s.mapLookupVersion = nil, nil

        ApplyLayout()
        for _, r in ipairs(panelRefreshers) do r() end
        return
    end

    -- Changing zone or entering an instance invalidates the cached position;
    -- otherwise the arrow keeps pointing from wherever we last stood.
    UQ.ForgetPlayerPos()
end)

-- ---------------------------------------------------------------------------
-- settings + slash
-- ---------------------------------------------------------------------------

if UncappedUI then
    local panel, L = UncappedUI.CreatePanel("Quest arrow",
        "A rotating arrow pointing at the objective you should do next, routed rather than just nearest.")

    L:Header("Arrow")
    panelRefreshers[#panelRefreshers + 1] = L:Check("Show quest arrow",
        function() return db.arrowEnabled end,
        function(v) db.arrowEnabled = v end).uncappedRefresh
    panelRefreshers[#panelRefreshers + 1] = L:Check("Lock position",
        function() return db.arrowLocked end,
        function(v) db.arrowLocked = v end).uncappedRefresh
    panelRefreshers[#panelRefreshers + 1] = L:Slider("Arrow scale", 0.5, 2.0, 0.05,
        function() return db.arrowScale end,
        function(v) db.arrowScale = v; ApplyLayout() end, "%.2f").uncappedRefresh

    L:Gap(6)
    L:Note("|cff808080Drag the arrow to move it. Left-click selects that quest in your log; "
        .. "right-click sends the objective to the back of the route.|r", 40)
end

SLASH_UNCAPPEDQARROW1 = "/uqarrow"
SlashCmdList["UNCAPPEDQARROW"] = function(arg)
    arg = strtrim((arg or ""):lower())

    if arg == "reset" then
        db.arrowPoint = defaults.arrowPoint
        db.arrowScale = defaults.arrowScale
        ApplyLayout()
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Uncapped Quests]|r arrow reset.")
        return
    end

    -- Every precondition the ticker checks before it will show the arrow, in the
    -- order it checks them. The first "no" is the reason nothing is on screen.
    if arg == "debug" then
        local function say(k, v) DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[UQ]|r " .. k .. ": " .. tostring(v)) end

        say("arrowEnabled", db.arrowEnabled)
        say("mapAreas", UncappedMapAreas and "loaded" or "MISSING")
        say("currentArea", tostring(GetCurrentMapAreaID()))

        local p = PlayerNode()
        say("playerPos", p and string.format("map=%d  %.1f, %.1f", p.map, p.wx, p.wy)
            or "NIL - no world position (in an instance?)")

        local objs = UQ.LedgerPins and UQ.LedgerPins() or {}
        say("ledgerPins", #objs .. " (server-sent objective locations)")

        local onMap = 0
        for _, o in ipairs(objs) do
            if p and o.map == p.map then onMap = onMap + 1 end
        end
        say("sameMap", onMap .. " (objectives on your map)")
        say("target", target and (target.title or "?") or "none")

        if target and p then
            local d = WorldDistance(p, target)
            say("targetPos", string.format("map=%d  %.1f, %.1f", target.map, target.wx, target.wy))
            say("dist", tostring(d))
        end
        return
    end

    db.arrowEnabled = not db.arrowEnabled
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Uncapped Quests]|r arrow "
        .. (db.arrowEnabled and "on" or "off") .. " |cff888888(/uqarrow reset | debug)|r")
end
