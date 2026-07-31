--[[
  Uncapped Quests -- the "go pick up a quest" arrow.

  Separate arrow, separate toggle, separate colour from the objective arrow, and
  it answers a different question: not "where do I finish what I have" but
  "where is the nearest quest I could take and have not already done".

  The client cannot answer that on its own. Quest POI data only covers quests
  already in your log, so the giver locations come from UncappedQuestGivers.lua,
  generated from this realm's own world DB (tools/Generate-QuestGivers.py).
  Which of them are actually available IS client-side though:

    QueryQuestsCompleted()  asks the server for the completed-quest set
    GetQuestsCompleted(t)   fills t[questID] = true once QUEST_QUERY_COMPLETE fires

  so the filtering costs nothing and is always right for this character.

  WORK SPLIT, which matters -- there are 7,461 givers:
    * byMap      built ONCE. Which map a giver stands on never changes.
    * eligible   rebuilt only when the answer could have changed: quest log,
                 completed set, level, or the map you are standing on.
    * the scan   walks `eligible` only, so the 3s tick stays cheap.
  An earlier version filtered all 7,461 every 3 seconds and stuttered on the
  beat, which is exactly what it sounds like from the outside.

  Inside an instance there is no world position -- and no map to point at. Rather
  than just hiding, it names what is in here with you ("Gary has a quest for you
  in here: ..."), matching the instance by name because the client never exposes
  a numeric map id to Lua.
]]

local UQ = UncappedQuests
local ADDON = "UncappedQuests"

local ARROW_TEXTURE = "Interface\\AddOns\\UncappedQuests\\arrow_image"
local SCAN_INTERVAL = 3.0

local defaults = {
    availEnabled   = false,     -- opt-in: this is the "what else is here" mode
    availScale     = 1.0,
    availMaxLevel  = 3,         -- ignore givers this far above the player
    availPoint     = { "CENTER", "UIParent", "CENTER", 160, 180 },
}

-- Private copy of the defaults up front -- see UncappedQuestsArrow.lua for why
-- a nil db while the settings page is being built takes the whole file down.
local db = {}
for k, v in pairs(defaults) do db[k] = v end

local panelRefreshers = {}
local completed = {}
local haveCompleted = false

local byMap                     -- [mapID] = { {qid, e}, ... }   static
local eligible = {}             -- candidates on the player's current map
local eligibleMap               -- which map `eligible` was built for
local eligibleDirty = true

local target
local sinceScan = SCAN_INTERVAL
local instanceNote

-- Race bit for the allowable-races mask. Keyed by the client's race token.
local RACE_BIT = {
    Human = 1, Orc = 2, Dwarf = 4, NightElf = 8, Scourge = 16,
    Tauren = 32, Gnome = 64, Troll = 128, BloodElf = 512, Draenei = 1024,
}

local function PlayerRaceMask()
    local _, token = UnitRace("player")
    return RACE_BIT[token or ""] or 0
end

-- Quests already in the log are not "available" even though they are not
-- completed either.
local function QuestsInLog()
    -- Prefer the LEDGER: it lists everything held, where the client's quest log
    -- stops at the 25 it has slots for. Asking the client alone made an
    -- off-slot quest look untaken, so the arrow kept pointing at the giver it
    -- had just come from.
    if UQ.HeldQuests then
        local held, ok = UQ.HeldQuests()
        if ok then return held end
    end

    local inLog = {}
    for i = 1, (GetNumQuestLogEntries() or 0) do
        local _, _, _, _, isHeader = GetQuestLogTitle(i)
        local link = (not isHeader) and GetQuestLink and GetQuestLink(i) or nil
        local id = link and tonumber(link:match("|Hquest:(%d+):"))
        if id then inLog[id] = true end
    end
    return inLog
end

-- ---------------------------------------------------------------------------
-- indexes
-- ---------------------------------------------------------------------------

local function BuildIndex()
    if byMap or not UncappedQuestGivers then return end
    byMap = {}
    for qid, e in pairs(UncappedQuestGivers) do
        local m = e[1]
        local bucket = byMap[m]
        if not bucket then bucket = {}; byMap[m] = bucket end
        bucket[#bucket + 1] = { qid = qid, e = e }
    end
end

-- Server's verdict on which candidates are genuinely takeable, keyed by quest
-- id. Empty until the first QLOK reply lands.
local verified, verifiedPending, verifiedAt = nil, false, 0

-- The client CANNOT decide this on its own. Prerequisite chains, exclusive
-- groups, class/skill/reputation gates and quest-chain state are all server
-- side; a local guess at level and race points the player at quest givers who
-- will never offer them anything, which is exactly what it did.
local function VerifyCandidates(ids)
    if #ids == 0 or verifiedPending then return end
    verifiedPending = true

    -- Sent as questId,giverEntry pairs. The entry lets the server confirm that
    -- giver actually offers the quest right now, which is the only way to catch
    -- event-gated givers -- an out-of-season candy bucket passes every
    -- player-side check and offers nothing.
    local chunk = {}
    for i = 1, #ids do
        local e = UncappedQuestGivers and UncappedQuestGivers[ids[i]]
        chunk[#chunk + 1] = ids[i] .. "," .. tostring((e and e[9]) or 0)
        if #chunk >= 15 or i == #ids then
            if UQ.Send then UQ.Send("QLCHK:" .. table.concat(chunk, ",")) end
            chunk = {}
        end
    end
end

function UQ.OnVerifiedAvailable(list, done)
    if not verified then verified = {} end
    for id in tostring(list):gmatch("%d+") do
        verified[tonumber(id)] = true
    end
    if done then
        verifiedPending = false
        verifiedAt = GetTime()
        eligibleDirty = true
    end
end

function UQ.ResetVerifiedAvailable()
    verified, verifiedPending = nil, false
    verifiedAt = 0

    -- `eligible` is DERIVED from the verdict, so dropping one must drop the
    -- other. Without this, Scan happily kept using a list built from a verdict
    -- that no longer existed -- which is why taking a quest left the arrow on
    -- the giver it came from until a reload rebuilt everything from scratch.
    -- The callers that set eligibleDirty themselves were masking it; the paths
    -- that did not (an off-slot accept raises no client event) were not.
    eligibleDirty = true
end

-- The server's verdict has a shelf life. Quest-log changes and levelling are
-- re-asked immediately, but availability also moves on reputation, skill, and
-- chains completed elsewhere -- none of which raise an event this addon sees.
-- Left alone, the set silently ages and the arrow keeps pointing at givers whose
-- quests are long gone.
local VERIFY_TTL = 60

local function BuildEligible(mapID)
    eligible, eligibleMap, eligibleDirty = {}, mapID, false

    local bucket = byMap and byMap[mapID]
    if not bucket then return end

    local inLog = QuestsInLog()
    local level = UnitLevel("player") or 1
    local raceMask = PlayerRaceMask()
    local maxLevel = level + (db.availMaxLevel or 3)

    -- Cheap local pass first: it is only a PRE-filter to keep the list we ask
    -- the server about small. The server's answer is what actually decides.
    local candidates = {}
    for _, r in ipairs(bucket) do
        local e = r.e
        local minLevel, questLevel, races = e[4], e[5], e[6]

        -- A giver whose SPAWN is event-controlled is not standing there unless
        -- that event is running. The quest itself passes every other check --
        -- an out-of-season candy bucket is a real, takeable, permanently
        -- related quest attached to a gameobject that does not exist.
        local ev = e[10] or 0
        local spawned = (ev == 0) or (UQ.ActiveEvents and UQ.ActiveEvents[ev])

        if spawned
           and (not completed[r.qid]) and (not inLog[r.qid])
           and level >= minLevel
           and (questLevel <= 0 or questLevel <= maxLevel)
           and (races == 0 or raceMask == 0 or bit.band(races, raceMask) ~= 0) then
            candidates[#candidates + 1] = r.qid
        end
    end

    if not verified then
        VerifyCandidates(candidates)
        return          -- nothing shown until the server has ruled
    end

    for _, r in ipairs(bucket) do
        local e = r.e
        local minLevel, questLevel, races = e[4], e[5], e[6]

        local ev2 = e[10] or 0
        local spawned2 = (ev2 == 0) or (UQ.ActiveEvents and UQ.ActiveEvents[ev2])

        if verified[r.qid] and spawned2
           and (not completed[r.qid]) and (not inLog[r.qid])
           and level >= minLevel
           and (questLevel <= 0 or questLevel <= maxLevel)
           and (races == 0 or raceMask == 0 or bit.band(races, raceMask) ~= 0) then
            eligible[#eligible + 1] = {
                questID = r.qid,
                map = mapID, wx = e[2], wy = e[3],
                giver = e[7], title = e[8], questLevel = questLevel,
            }
        end
    end
end

-- ---------------------------------------------------------------------------
-- scan
-- ---------------------------------------------------------------------------

local function ScanInstance()
    instanceNote = nil
    if not (IsInInstance and IsInInstance()) then return end
    if not (UncappedQuestGiverMaps and byMap) then return end

    local instanceName = GetInstanceInfo and GetInstanceInfo()
    if not instanceName then return end

    local inLog = QuestsInLog()
    local level = UnitLevel("player") or 1
    local name, quest, extra = nil, nil, 0

    for mapID, label in pairs(UncappedQuestGiverMaps) do
        if label == instanceName then
            for _, r in ipairs(byMap[mapID] or {}) do
                local e = r.e
                if (not completed[r.qid]) and (not inLog[r.qid]) and level >= e[4] then
                    if name then extra = extra + 1
                    else name, quest = e[7], e[8] end
                end
            end
        end
    end

    if not name then return end
    if extra > 0 then
        instanceNote = string.format("%s has a quest for you in here: %s |cff808080(+%d more)|r",
            name, quest, extra)
    else
        instanceNote = string.format("%s has a quest for you in here: %s", name, quest)
    end
end

local function Scan(player)
    target = nil
    BuildIndex()
    ScanInstance()

    if not player then return end

    -- Age out a stale verdict even when nothing raised an event.
    if verified and (GetTime() - verifiedAt) > VERIFY_TTL then
        UQ.ResetVerifiedAvailable()
        eligibleDirty = true
    end

    if eligibleDirty or eligibleMap ~= player.map then BuildEligible(player.map) end

    local bestD, best
    for _, cand in ipairs(eligible) do
        local d = UQ.WorldDistance(player, cand)
        if d and (not bestD or d < bestD) then bestD, best = d, cand end
    end
    target = best
end

-- ---------------------------------------------------------------------------
-- arrow
-- ---------------------------------------------------------------------------

local arrow = CreateFrame("Button", "UncappedQuestAvailArrow", UIParent)
arrow:SetWidth(56)
arrow:SetHeight(42)
arrow:SetMovable(true)
arrow:EnableMouse(true)
arrow:RegisterForDrag("LeftButton")
arrow:Hide()

arrow.tex = arrow:CreateTexture(nil, "OVERLAY")
arrow.tex:SetAllPoints()
arrow.tex:SetTexture(ARROW_TEXTURE)
-- Held a constant teal, where the objective arrow shifts red->yellow->green with
-- how well you are facing it. One glance tells you which arrow you are reading.
arrow.tex:SetVertexColor(0.2, 0.9, 1.0)

-- Names itself, same as the objective arrow. Teal to match its own tint, so the
-- caption and the arrow it belongs to read as one thing.
arrow.caption = arrow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
arrow.caption:SetPoint("BOTTOM", arrow, "TOP", 0, 26)
arrow.caption:SetText("|cff33e6ffPick up|r")

arrow.title = arrow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
arrow.title:SetPoint("BOTTOM", arrow, "TOP", 0, 2)
arrow.title:SetTextColor(0.2, 0.9, 1.0)

arrow.dist = arrow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
arrow.dist:SetPoint("TOP", arrow, "BOTTOM", 0, -2)

arrow:SetScript("OnDragStart", function(self)
    if not db.arrowLocked then self:StartMoving() end
end)
arrow:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint()
    db.availPoint = { p, "UIParent", rp, x, y }
end)

arrow:SetScript("OnEnter", function(self)
    if not target then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Pick up", 0.2, 0.9, 1.0)
    GameTooltip:AddLine("The nearest quest you can take and have not done.", 0.7, 0.7, 0.7)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(target.title or "", 1, 1, 1)
    GameTooltip:AddLine("From " .. (target.giver or "?"), 0.8, 0.8, 0.8)
    if target.questLevel and target.questLevel > 0 then
        GameTooltip:AddLine("Level " .. target.questLevel, 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
end)
arrow:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- The in-instance message, standing in for the arrow in the same screen slot.
local note = CreateFrame("Frame", "UncappedQuestAvailNote", UIParent)
note:SetWidth(320)
note:SetHeight(40)
note:Hide()
note.text = note:CreateFontString(nil, "OVERLAY", "GameFontNormal")
note.text:SetAllPoints()
note.text:SetJustifyH("CENTER")
note.text:SetTextColor(0.4, 1.0, 0.4)

local function ApplyLayout()
    local p = db.availPoint or defaults.availPoint
    arrow:SetScale(db.availScale or 1)
    arrow:ClearAllPoints()
    arrow:SetPoint(p[1], UIParent, p[3], p[4], p[5])
    note:ClearAllPoints()
    note:SetPoint(p[1], UIParent, p[3], p[4], p[5])
end

-- Driven from an always-shown frame, not the arrow: OnUpdate never fires on a
-- hidden frame, and the arrow starts hidden.
local driver = CreateFrame("Frame")

driver:SetScript("OnUpdate", function(_, elapsed)
    local self = arrow

    if not db.availEnabled then
        self:Hide(); note:Hide()
        return
    end

    local player = UQ.PlayerNode()

    sinceScan = sinceScan + elapsed
    if sinceScan >= SCAN_INTERVAL then
        sinceScan = 0
        Scan(player)
    end

    -- No world position: we are in an instance, so say what is in here instead
    -- of pointing at nothing.
    if not player then
        self:Hide()
        if instanceNote then
            note.text:SetText(instanceNote)
            note:Show()
        else
            note:Hide()
        end
        return
    end

    note:Hide()

    if not target then
        self:Hide()
        return
    end

    local dist, dx, dy = UQ.WorldDistance(player, target)
    if not dist then
        self:Hide()
        return
    end

    self:Show()
    UQ.SetArrowHeading(self.tex, UQ.Bearing(dx, dy))

    if self.uqTarget ~= target then
        self.uqTarget = target
        -- Quest name AND giver. Showing only the giver made it impossible to
        -- tell "still pointing at the quest you just took" from "pointing at
        -- the NEXT quest the same NPC offers" -- givers routinely hold several.
        self.title:SetText((target.title or "?") .. "\n|cff808080" .. (target.giver or "") .. "|r")
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
f:RegisterEvent("QUEST_QUERY_COMPLETE")
f:RegisterEvent("QUEST_LOG_UPDATE")
f:RegisterEvent("PLAYER_LEVEL_UP")

f:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        UncappedQuestsDB = UncappedQuestsDB or {}
        local s = UncappedQuestsDB
        for k, v in pairs(defaults) do
            if s[k] == nil then s[k] = v end
        end
        db = s
        ApplyLayout()
        for _, r in ipairs(panelRefreshers) do r() end
        return
    end

    if event == "QUEST_QUERY_COMPLETE" then
        completed = {}
        GetQuestsCompleted(completed)
        haveCompleted = true
        UQ.ResetVerifiedAvailable()
        eligibleDirty = true
        return
    end

    if event == "QUEST_LOG_UPDATE" or event == "PLAYER_LEVEL_UP" then
        -- Taking, finishing or levelling can all change what is takeable, so
        -- the server's verdict has to be re-asked rather than reused.
        UQ.ResetVerifiedAvailable()
        eligibleDirty = true
        return
    end

    -- PLAYER_ENTERING_WORLD: ask once. Without the completed set every quest
    -- the character has ever done would look available.
    eligibleDirty = true
    if not haveCompleted and QueryQuestsCompleted then
        QueryQuestsCompleted()
    end
end)

-- ---------------------------------------------------------------------------
-- settings + slash
-- ---------------------------------------------------------------------------

if UncappedUI then
    local panel, L = UncappedUI.CreatePanel("Available quests",
        "A second arrow pointing at the nearest quest you can pick up and have not already completed.")

    L:Header("Available-quest arrow")
    panelRefreshers[#panelRefreshers + 1] = L:Check("Show available-quest arrow",
        function() return db.availEnabled end,
        function(v) db.availEnabled = v; eligibleDirty = true end).uncappedRefresh
    panelRefreshers[#panelRefreshers + 1] = L:Slider("Arrow scale", 0.5, 2.0, 0.05,
        function() return db.availScale end,
        function(v) db.availScale = v; ApplyLayout() end, "%.2f").uncappedRefresh
    panelRefreshers[#panelRefreshers + 1] = L:Slider("Ignore quests this far above you", 0, 15, 1,
        function() return db.availMaxLevel end,
        function(v) db.availMaxLevel = v; eligibleDirty = true end, "%d").uncappedRefresh

    L:Gap(6)
    L:Note("|cff808080Giver locations come from the realm's own quest data. Inside an instance "
        .. "there is nothing to point at, so it names the quest giver in there with you instead.|r", 50)
end

-- Giver pins for the map area currently on screen, for the opt-in "quests you
-- could pick up" layer. Reuses the same eligibility the arrow uses, so the map
-- and the arrow never disagree about what is available.
function UQ.AvailableGiverPins(dbcArea)
    local out = {}
    if not (dbcArea and UncappedQuestGivers and UncappedMapAreas) then return out end

    BuildIndex()

    local player = UQ.PlayerNode()
    if player and (eligibleDirty or eligibleMap ~= player.map) then
        BuildEligible(player.map)
    end

    for _, cand in ipairs(eligible) do
        local mapID, mx, my = UQ.MapPos(dbcArea, cand.wx, cand.wy)
        if mapID and mx and mx >= 0 and mx <= 1 and my >= 0 and my <= 1 then
            out[#out + 1] = {
                questID = cand.questID, title = cand.title,
                giver = cand.giver, x = mx, y = my,
            }
        end
    end

    return out
end

-- Why a given quest is not a candidate, or nil if it is one.
local function Rejection(qid, e, inLog, level, raceMask, maxLevel)
    if completed[qid] then return "already completed" end
    if inLog[qid] then return "already in your log" end
    if level < e[4] then return "needs level " .. e[4] end
    local questLevel = e[5]
    if questLevel > 0 and questLevel > maxLevel then
        return "quest level " .. questLevel .. " above your cutoff (" .. maxLevel .. ")"
    end
    local races = e[6]
    if races ~= 0 and raceMask ~= 0 and bit.band(races, raceMask) == 0 then
        return "wrong race"
    end
    return nil
end

SLASH_UNCAPPEDQAVAIL1 = "/uqavail"
SlashCmdList["UNCAPPEDQAVAIL"] = function(arg)
    arg = strtrim((arg or ""):lower())

    -- Answers "why is it not pointing at the person standing right here": lists
    -- every giver near you with the verdict on each, not just the winner.
    if arg == "debug" or arg == "near" then
        local function say(s) DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[UQ]|r " .. s) end

        local player = UQ.PlayerNode()
        if not player then
            say("no world position (inside an instance?)")
            say(instanceNote or "nothing recorded in here")
            return
        end

        BuildIndex()
        if eligibleDirty or eligibleMap ~= player.map then BuildEligible(player.map) end

        local nVerified = 0
        if verified then for _ in pairs(verified) do nVerified = nVerified + 1 end end

        say(string.format("map=%d  %.0f, %.0f   |   completed set: %s   |   eligible here: %d",
            player.map, player.wx, player.wy,
            haveCompleted and "loaded" or "NOT LOADED", #eligible))
        -- The SERVER's verdict is what actually decides. An earlier version of
        -- this dump only printed the client's own crude guess and labelled it
        -- AVAILABLE, which made a server disagreement completely invisible.
        say(string.format("server verdict: %s   |   awaiting reply: %s",
            verified and (nVerified .. " takeable") or "NEVER REPLIED",
            tostring(verifiedPending)))

        local inLog = QuestsInLog()
        local level = UnitLevel("player") or 1
        local raceMask = PlayerRaceMask()
        local maxLevel = level + (db.availMaxLevel or 3)

        -- Everything within 200 yards, eligible or not, nearest first.
        local near = {}
        for _, r in ipairs((byMap and byMap[player.map]) or {}) do
            local e = r.e
            local d = UQ.WorldDistance(player, { map = e[1], wx = e[2], wy = e[3] })
            if d and d <= 200 then
                near[#near + 1] = { d = d, qid = r.qid, giver = e[7], title = e[8],
                    why = Rejection(r.qid, e, inLog, level, raceMask, maxLevel) }
            end
        end
        table.sort(near, function(a, b) return a.d < b.d end)

        if #near == 0 then
            say("no quest givers recorded within 200 yd of you")
        end
        for i = 1, math.min(#near, 8) do
            local n = near[i]
            -- Two verdicts, shown separately: the client's local pre-filter and
            -- the server's CanTakeQuest. When they disagree, that IS the bug.
            local srv
            if not verified then srv = "|cff888888server: -|r"
            elseif verified[n.qid] then srv = "|cff80ff80server: TAKEABLE|r"
            else srv = "|cffff8080server: refused|r" end

            say(string.format("  %3.0f yd  %s -- %s", n.d, n.giver, n.title))
            say(string.format("        client: %s   %s",
                n.why or "ok", srv))
        end

        say("pointing at: " .. (target and (target.giver .. " -- " .. target.title) or "nothing"))
        return
    end

    db.availEnabled = not db.availEnabled
    eligibleDirty = true
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Uncapped Quests]|r available-quest arrow "
        .. (db.availEnabled and "on" or "off") .. " |cff888888(/uqavail near)|r")
end
