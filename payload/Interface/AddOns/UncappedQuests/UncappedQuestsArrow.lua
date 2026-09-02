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
    -- Sits just under the arrow by default, so the thing you press and the thing
    -- telling you where to go read as one unit.
    useButtonPoint = { "CENTER", "UIParent", "CENTER", 0, 128 },
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
--
-- ...which is precisely what the old `or UncappedMapAreas[clientAreaID]`
-- fallback delivered. The +1 is not a heuristic, it is how the client reports
-- every map area (UQ.CurrentDbcArea applies the same correction with no
-- fallback at all), so the raw id is never the right key -- it is the NEXT
-- zone's key. The table is sparse but clustered (...11, 13, 14, 15, 16, 17,
-- 19, 20...), so adjacent pairs exist throughout and that branch fired
-- wherever the correct row was missing, returning the neighbour's rectangle.
-- No answer beats a wrong one: the caller below and PlayerNode both already
-- fail safe on nil.
function UQ.WorldPos(clientAreaID, mx, my)
    if not (UncappedMapAreas and clientAreaID) then return nil end
    local a = UncappedMapAreas[clientAreaID - 1]
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
    -- ★ [#765] THROTTLE ON TIME ALONE. `cachedPos and ...` meant the throttle only
    -- applied once there WAS a position -- so the one case that costs anything, having
    -- none (an instance: the client reports no world position there), re-ran
    -- GetPlayerMapPosition and SetMapToCurrentZone on EVERY FRAME for as long as the
    -- player was inside. SetMapToCurrentZone repoints the world map and fires
    -- WORLD_MAP_UPDATE; doing that 45 times a second in a dungeon is the same bill the
    -- blocked Hide was running up, and it is not even combat-gated.
    if (now - cachedAt) < POS_INTERVAL then return cachedPos end
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
    -- The throttle now runs on time alone, so the stamp has to be cleared too or a zone
    -- change would wait out the rest of the interval before the arrow could re-acquire.
    cachedAt = 0
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
local routeLogIndex = {}

local function BuildRoute(player)
    local pending = {}

    -- One quest-log pass for the whole route. UQ.QuestLogIndex is a full walk
    -- with a GetQuestLink and a string.match per entry, and this used to call
    -- it once per pending objective -- every ROUTE_INTERVAL, and again
    -- synchronously on every right-click of the arrow.
    local logIndex = UQ.QuestLogIndexMap and UQ.QuestLogIndexMap(routeLogIndex)

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
                questIndex = logIndex and logIndex[o.questID] or nil,
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

-- Say so. The three lines above ARE the "heading" sheet applied by hand -- size
-- and texture both -- so the marker UseSheet reads has to agree, or it describes
-- a state the frame is not in. Leaving it nil here is how the two got to
-- disagree in the first place. (UseSheet no longer trusts it alone, but a marker
-- that lies is still worth not writing.)
arrow.uqSheet = "heading"

-- ---------------------------------------------------------------------------
-- Use button -- press the item the nearest objective wants
-- ---------------------------------------------------------------------------
--
-- SecureActionButtonTemplate because USING an item is a protected action: it has
-- to come from a real hardware click on a secure button, and no amount of Lua
-- can fake it. The consequence is that the item it points at can only be changed
-- OUT of combat -- SetAttribute is blocked once the lockdown is on. So whatever
-- it resolved to when combat started is what it stays until combat ends, which
-- is the standard behaviour for every button of this kind and worth knowing
-- rather than being surprised by.
--
-- It follows the SAME target the arrow points at, so "the objective you are
-- being sent to" and "the thing you press when you get there" can never
-- disagree.

local useButton = CreateFrame("Button", "UncappedQuestUseButton", UIParent, "SecureActionButtonTemplate")
useButton:SetWidth(40)
useButton:SetHeight(40)
useButton:SetMovable(true)
useButton:EnableMouse(true)
useButton:RegisterForDrag("LeftButton")
useButton:RegisterForClicks("AnyUp")
useButton:SetAttribute("type", "item")
useButton:Hide()

useButton.icon = useButton:CreateTexture(nil, "BACKGROUND")
useButton.icon:SetAllPoints()
useButton.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

useButton.border = useButton:CreateTexture(nil, "OVERLAY")
useButton.border:SetAllPoints()
useButton.border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
useButton.border:SetTexCoord(0.2, 0.8, 0.2, 0.8)
useButton.border:SetVertexColor(1, 0.82, 0)

useButton.cd = CreateFrame("Cooldown", nil, useButton, "CooldownFrameTemplate")
useButton.cd:SetAllPoints()

useButton.count = useButton:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
useButton.count:SetPoint("BOTTOMRIGHT", -2, 2)

useButton:SetScript("OnDragStart", function(self)
    if not db.arrowLocked then self:StartMoving() end
end)
useButton:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint()
    db.useButtonPoint = { p, "UIParent", rp, x, y }
end)

useButton:SetScript("OnEnter", function(self)
    if not self.itemId then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink("item:" .. self.itemId)
    GameTooltip:Show()
end)
useButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Which item, if any, the current objective wants pressed.
--
-- Two sources, deliberately in this order:
--   1. the server's QLUI, which covers EVERY quest including the ones held in
--      the ledger with no client log slot;
--   2. GetQuestLogSpecialItemInfo, which only knows about the 25 slotted quests
--      but catches items a quest grants mid-way rather than on accept, which
--      quest_template.StartItem does not describe.
--
-- Both are gated on actually holding the item -- a button for something not in
-- your bags is just a lie with an icon.
local function ResolveUseItem()
    if not target or not target.questID then return nil end

    local itemId = UQ.QuestUseItem and UQ.QuestUseItem(target.questID)
    if itemId and GetItemCount(itemId) > 0 then
        return itemId
    end

    if target.questIndex then
        local link = GetQuestLogSpecialItemInfo(target.questIndex)
        local fromLog = link and tonumber(link:match("item:(%d+)"))
        if fromLog and GetItemCount(fromLog) > 0 then
            return fromLog
        end
    end

    return nil
end

local function RefreshUseButton()
    -- Attributes are locked during combat. Bail rather than error; the
    -- PLAYER_REGEN_ENABLED handler below re-runs this the moment combat drops.
    if InCombatLockdown() then return end

    local itemId = ResolveUseItem()

    if itemId ~= useButton.itemId then
        useButton.itemId = itemId
        if itemId then
            local name = GetItemInfo(itemId)
            -- Prefer the name: "item:<id>" is accepted too, but a name survives
            -- the item being in a bag the id form cannot address.
            useButton:SetAttribute("item", name or ("item:" .. itemId))
            useButton.icon:SetTexture(GetItemIcon and GetItemIcon(itemId) or nil)
        end
    end

    if not itemId then
        useButton:Hide()
        return
    end

    local count = GetItemCount(itemId)
    useButton.count:SetText(count > 1 and count or "")

    local start, duration, enable = GetItemCooldown(itemId)
    if start and duration and duration > 0 then
        useButton.cd:SetCooldown(start, duration)
    else
        useButton.cd:Hide()
    end

    useButton:Show()
end

-- Combat ends: catch up on anything the lockdown blocked above.
local useCombatWatcher = CreateFrame("Frame")
useCombatWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
useCombatWatcher:RegisterEvent("BAG_UPDATE")
useCombatWatcher:SetScript("OnEvent", RefreshUseButton)

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

-- ★★ THE COMMENT ABOVE IS NOT TRUE WITHOUT THIS, AND THAT COST A REAL BUG.
--
-- "the next target change out of combat fixes it" is exactly what the driver
-- prevents: it latches `self.uqTarget = target` BEFORE calling RefreshItem, so
-- once the refresh is skipped under the lockdown, the `uqTarget ~= target`
-- branch never runs again for that target. The button then keeps the PREVIOUS
-- quest's item for the rest of the session.
--
-- And the routed target changes during combat precisely because you killed the
-- thing you were routed to, so this is the common case, not an edge one. There
-- is no error and nothing on screen says it is wrong -- the button simply offers
-- the wrong item. useButton already had this catch-up; this one never did.
local itemCombatWatcher = CreateFrame("Frame")
itemCombatWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
itemCombatWatcher:SetScript("OnEvent", function()
    RefreshItem(arrow, target)
end)

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
        -- Always open the ledger, on this quest.
        --
        -- This used to split on questIndex, and only the nil half worked. A quest
        -- past the client's 25 log slots has no index, so it opened the ledger --
        -- but anything still holding a slot fell through to SelectQuestLogEntry,
        -- which selects a row inside Blizzard's quest log. On this realm that
        -- window is hooked and replaced by the ledger, so nothing was ever shown
        -- and the click looked dead. That is the MAJORITY of quests, which is why
        -- the arrow still felt broken after the previous fix.
        --
        -- The ledger lists both kinds anyway -- rows are tagged "In Log" or
        -- "Ledger" -- so there is no reason to treat them differently here.
        --
        -- SelectQuestLogEntry is still called when there IS an index, purely to
        -- keep Blizzard's own selection state consistent for anything else that
        -- reads it. It is not what the player sees.
        if target.questIndex then
            SelectQuestLogEntry(target.questIndex)
            if QuestLog_Update then QuestLog_Update() end
        end

        if UQ.FocusLedgerQuest then
            UQ.FocusLedgerQuest(target.questID)
        elseif UQ.ToggleLedger then
            UQ.ToggleLedger()
        end
    end
end)

local layoutPending = false

local function ApplyLayout()
    -- ⚠ SIX blocked calls per invocation in combat. Both frames are protected --
    -- useButton is a SecureActionButtonTemplate and the arrow is the parent of
    -- one -- so SetScale/ClearAllPoints/SetPoint are all refused. The arrow-scale
    -- slider fires this from its OnValueChanged (UncappedOptions.lua), i.e. on
    -- every frame of a drag, which is the only path here that can beat the frame
    -- rate. Defer once and re-apply when the lockdown drops; do NOT retry.
    if InCombatLockdown() then
        layoutPending = true
        return
    end
    layoutPending = false

    arrow:SetScale(db.arrowScale or 1)
    arrow:ClearAllPoints()
    local p = db.arrowPoint or defaults.arrowPoint
    arrow:SetPoint(p[1], UIParent, p[3], p[4], p[5])

    -- Anchored to UIParent rather than to the arrow: the arrow hides constantly
    -- (no target, out of range, disabled) and a child would vanish with it,
    -- taking a button the player may still want to press.
    useButton:SetScale(db.arrowScale or 1)
    useButton:ClearAllPoints()
    local u = db.useButtonPoint or defaults.useButtonPoint
    useButton:SetPoint(u[1], UIParent, u[3], u[4], u[5])
end

-- Combat ends: apply the layout the lockdown refused, once.
local layoutWatcher = CreateFrame("Frame")
layoutWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
layoutWatcher:SetScript("OnEvent", function()
    if layoutPending then ApplyLayout() end
end)

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
    local sheet = SHEETS[which]
    if not sheet then return end

    -- ★ [#765] `frame` here is the arrow, and the arrow is PROTECTED (see the note
    -- on HideArrow further down). SetWidth/SetHeight are refused in combat, so the
    -- swap half-applies, the width check below reads as "not applied", and this runs
    -- again on the very next frame -- a second ADDON_ACTION_BLOCKED storm at frame
    -- rate, from the same cause. Keep the current sheet until the lockdown drops; the
    -- driver calls this every frame, so it corrects itself the instant combat ends.
    if InCombatLockdown() then return end

    --[[ ★ VERIFY, don't just trust the marker.

         The marker was the only evidence the swap had happened, which makes it
         the single point of failure for the very thing it guards: if the frame's
         real size and `uqSheet` ever disagree, the early-out reads as "already
         applied" and NOTHING EVER RETRIES. Stuck stretched until reload -- which
         is the symptom recurring after this function was supposed to have fixed
         it.

         And they started out disagreeing. The frame is built at 56x42 with the
         heading texture at creation, but `uqSheet` is left nil there, so the
         marker never described the constructed state to begin with.

         Checking the actual width costs one number compare per frame and makes
         the invariant self-healing: any drift, from any cause, is corrected on
         the next tick instead of persisting. That matters more than knowing
         which path caused it -- the previous pass tried to close the paths one
         by one and the symptom came back.

         Width alone is enough: the two sheets differ on it (56 vs 53), and it is
         set in the same breath as the height. ]]
    if frame.uqSheet == which and frame:GetWidth() == sheet.w then return end

    frame.tex:SetTexture(sheet.texture)
    frame:SetWidth(sheet.w)
    frame:SetHeight(sheet.h)
    frame.uqSheet = which
end

-- The ticker CANNOT live on the arrow itself: OnUpdate does not fire on a hidden
-- frame, and the arrow starts hidden, so it would sit there forever waiting for
-- the handler that was supposed to show it.
local driver = CreateFrame("Frame")

-- ★★ [#765] THE ARROW IS A PROTECTED FRAME AND NOTHING ABOUT IT SAYS SO.
--
-- `arrow.itemButton` is a SecureActionButtonTemplate parented to `arrow`, and a
-- frame with a protected descendant is itself protected. Hide/Show, SetWidth,
-- SetHeight, SetScale and SetPoint on the arrow are therefore ALL refused in
-- combat -- and every hide below runs from an OnUpdate, so a refused Hide leaves
-- the frame shown, the next frame tries again, and the client logs
-- ADDON_ACTION_BLOCKED at frame rate. Measured live at 45-48 per second.
--
-- The path that reaches it is the ordinary one, not an edge case: PlayerNode()
-- returns nil for the WHOLE time a player is inside an instance, because the
-- client reports no world position there. So every dungeon and raid boss fight
-- runs the `not player` branch on every single frame.
--
-- SetAlpha is NOT protected, so combat gets an arrow faded to nothing and the
-- real Hide happens on the first frame after the lockdown drops. This driver runs
-- every frame, so nothing extra is needed to finish the job.
--
-- useButton is itself a secure frame, so its Hide is refused too. It is left alone
-- until combat ends, which is exactly what the note above its creation already
-- describes.
local arrowFaded = false

local function HideArrow()
    if arrow:IsShown() then
        if InCombatLockdown() then
            if not arrowFaded then
                arrow:SetAlpha(0)
                arrowFaded = true
            end
            return
        end
        arrow:Hide()
    end

    if arrowFaded then
        arrow:SetAlpha(1)
        arrowFaded = false
    end
end

local function ShowArrow()
    if arrowFaded then
        arrow:SetAlpha(1)
        arrowFaded = false
    end

    -- ★★ [#765, THE OTHER HALF] The arrow is PROTECTED -- see the long note above
    -- HideArrow. #765 guarded the hide side and left this one, and a refused Show
    -- is retried by the driver's OnUpdate on EVERY FRAME for the rest of the
    -- lockdown, so the ADDON_ACTION_BLOCKED rate simply IS the frame rate. That
    -- is why 08-13's measured 45-48/sec never went to zero after #765 shipped:
    -- half the storm was fixed. Measured again 2026-09-02 at a median of 21/sec
    -- and a peak of 525/sec.
    --
    -- Skipping the call changes nothing a player can see. The Show was going to
    -- be refused either way, and the driver runs every frame, so the arrow still
    -- appears on the first frame after the lockdown drops.
    if arrow:IsShown() or InCombatLockdown() then return end
    arrow:Show()
end

local function HideUseButton()
    if useButton:IsShown() and not InCombatLockdown() then useButton:Hide() end
end

driver:SetScript("OnUpdate", function(_, elapsed)
    local self = arrow

    if not db.arrowEnabled then
        HideArrow()
        HideUseButton()
        return
    end

    local player = PlayerNode()
    if not player then
        HideArrow()
        HideUseButton()
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
        -- Same cadence as the route, deliberately: the button follows whatever
        -- the arrow is pointing at, so refreshing it anywhere else would let the
        -- two disagree. Every-frame would also mean a GetItemCount and a
        -- GetItemCooldown per frame for no benefit.
        RefreshUseButton()
    end

    if not target then
        HideArrow()
        HideUseButton()
        return
    end

    local dist, dx, dy = WorldDistance(player, target)
    if not dist then
        HideArrow()
        return
    end

    ShowArrow()

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
