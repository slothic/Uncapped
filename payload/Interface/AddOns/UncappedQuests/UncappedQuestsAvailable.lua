--[[
  Uncapped Quests -- the "go pick up a quest" arrow.

  Separate arrow, separate toggle, separate colour from the objective arrow, and
  it answers a different question: not "where do I finish what I have" but
  "where is the nearest quest I could take and have not already done".

  The client cannot answer that on its own. Quest POI data only covers quests
  already in your log, so the giver locations come from UncappedQuestGiverData.lua,
  generated from this realm's own world DB (tools/Generate-QuestGivers.py).

  [MQ-05] That table lives in the separate UncappedQuestData addon, which is
  ## LoadOnDemand: 1 -- it is 640 KB and this whole feature is opt-in and
  default off, so it is NOT parsed at login. BuildIndex() pulls it in through
  UQ.EnsureQuestData() on first use; everything here runs downstream of that.
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

local byMap                     -- [mapID] = { qid, qid, ... }   static
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

-- 1 = Alliance, 2 = Horde, matching UncappedQuestGiverTeams.
local function PlayerTeam()
    return UnitFactionGroup("player") == "Horde" and 2 or 1
end

-- Can this player actually walk up to the quest's giver and take it?
--
-- The race mask alone CANNOT answer this. Plenty of quests carry
-- AllowableRaces = 0 ("any race") while being offered by a faction-locked NPC,
-- so the mask waves them through: reported in-game as being offered "Proving
-- Grounds" from Warmaster Laggrond and "Valik" from Henchman Valik, both Horde
-- NPCs, on an Alliance character. 459 quests realm-wide are in that shape.
--
-- UncappedQuestGiverTeams lists exactly those, resolved from the giver's
-- FactionTemplate factionGroup at generation time. A quest absent from it is
-- either race-gated already or genuinely neutral, so it passes.
local function GiverReachable(questId)
    local team = UncappedQuestGiverTeams and UncappedQuestGiverTeams[questId]
    return (not team) or team == PlayerTeam()
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

-- ⚠ Quest IDS only. This used to store { qid = qid, e = e } per row, which is
--   7,461 extra two-field Lua tables held for the whole session -- several
--   hundred KB -- carrying a key alongside a value that is already reachable as
--   UncappedQuestGivers[qid]. Every reader below does that lookup instead; it is
--   one hash probe against a table it already had to hold anyway.
local function BuildIndex()
    if byMap then return end

    -- [MQ-05] This is the choke point where the 640 KB giver table is actually
    -- pulled in. It is no longer loaded at login -- it lives in the
    -- UncappedQuestData LoadOnDemand addon -- and everything that reads
    -- UncappedQuestGivers or UncappedQuestGiverMaps runs downstream of here.
    if not UQ.EnsureQuestData() then return end
    if not UncappedQuestGivers then return end

    byMap = {}
    for qid, e in pairs(UncappedQuestGivers) do
        local m = e[1]
        local bucket = byMap[m]
        if not bucket then bucket = {}; byMap[m] = bucket end
        bucket[#bucket + 1] = qid
    end
end

-- Server's verdict on which candidates are genuinely takeable, keyed by quest
-- id. Empty until the first QLOK reply lands.
local verified, verifiedPending, verifiedAt = nil, false, 0

--[[ ★★★ [#1277] THIS FILE WAS THE SINGLE BIGGEST SOURCE OF DROPPED ADDON
     COMMANDS ON THE REALM, and the two bugs behind it are both here.

     Measured on the live worldserver log for one boot: 27 distinct characters,
     20,721 commands dropped by AddonThrottle, against a peak of 13 players
     online. The reporter alone ate 10,137 drops spread over 34 SEPARATE
     MINUTES -- which is the shape that matters: a bucket pinned at zero all
     day, not one unlucky burst. Game masters hold
     RBAC_PERM_SKIP_CHECK_CHAT_SPAM and are exempt from the throttle, which is
     why nobody on staff could ever reproduce any of it.

     BUG ONE -- INVALIDATION HAD ONE GEAR, AND IT WAS THE VIOLENT ONE.
     UncappedQuestsLedger.lua calls back at the end of EVERY ledger burst, and
     the ledger is server-throttled to one burst per three seconds. That call
     used to run the FULL reset below: `verified` nilled AND `verifiedAt`
     zeroed. Zeroing the timestamp is what did the damage -- it made the
     60-second VERIFY_TTL structurally unreachable, because the clock it
     measures was reset before it could ever expire. So every three seconds the
     next scan re-asked the WHOLE continent's candidate list from scratch.

     BUG TWO -- AND IT RE-ASKED IT IN ONE FRAME. VerifyCandidates sent one
     QLCHK per 15 candidate ids with no pacing at all. A populated continent is
     several hundred candidates, so a single scan emitted twenty to forty
     messages in one frame at 2 tokens each, against a bucket of 60 that
     refills at 6 per second. The first handful landed; everything after that
     was thrown away, unanswered, and took the player's budget for every OTHER
     Uncapped feature down with it.

     ★★ SO INVALIDATION IS NOW TWO THINGS, and the distinction is the fix:

       HARD  the verdict is WRONG and must not be used -- drop it, re-ask.
             PLAYER_LEVEL_UP (every gate moves at once) and
             QUEST_QUERY_COMPLETE (the completed set was replaced wholesale).

       SOFT  the verdict is SUSPECT -- keep it, mark it stale, and let a much
             shortened TTL decide whether it is worth a round trip. The ledger
             burst and QUEST_LOG_UPDATE, i.e. everything that fires on the beat
             rather than on a real change.

     A soft invalidation still sets eligibleDirty, so BuildEligible re-runs and
     the quest you just accepted disappears from the arrow immediately -- that
     filtering is LOCAL (`inLog`) and costs no messages. What it no longer does
     is spend a continent's worth of QLCHK to learn something the client
     already knew.

     ⚠ The Vault-push / QUEST_LOG_UPDATE-storm theory was investigated and is
       REFUTED -- UncappedVault explicitly refuses to synthesise that event, and
       its PUSH_INTERVAL_MS is 0 under a static_assert that forbids anything
       else (a non-zero value there reintroduces a documented SIGSEGV shape).
       Do not go back and "fix" it there.
]]
local verifiedStale = false

-- Which map the outstanding verdict was asked FOR. The verdict is a set of
-- quest ids drawn from ONE map's candidate bucket, so carrying it across a
-- continent change means BuildEligible filters the new map's quests against a
-- verdict that was never asked about them -- and, because `verified` is
-- non-nil, never re-asks. That read to the player as the pick-up arrow simply
-- dying for a minute after every zone-in.
local verifiedMap

--[[ ★★ THE SEND QUEUE. QLCHK messages are BUILT here and SENT by the OnUpdate
     driver further down, a couple per second, instead of all at once.

     2 per second x 2 tokens = 4 tokens/s against a 6/s refill, so the pick-up
     arrow can now run flat out forever and still leave a third of the player's
     budget for everything else. Before this it could exhaust a full 60-token
     burst in a single frame.

     ⚠ DRAINED OUTSIDE THE `db.availEnabled` GATE. The map's giver-pin layer
       (UQ.AvailableGiverPins) drives BuildEligible too, so this queue can be
       filled with the arrow switched off. Draining it only while the arrow is
       on would park those asks forever.
]]
local askQueue = {}
local askNextAt = 0
local askActivityAt = 0

-- One QLCHK carries 15 ids; a continent is tens of messages. Two per second is
-- slow enough to be invisible in the budget and fast enough that a full
-- continent settles inside half a minute -- against a TTL of sixty.
local ASK_PER_SEC = 2

-- ⚠ THE WATCHDOG, and it is not optional. `verifiedPending` is a re-entry guard;
--   if it can ever get stuck true, BuildEligible stops re-asking and the feature
--   is dead until /reload. A dropped LAST chunk produces exactly that -- its
--   QLOKEND never arrives, so nothing ever clears the guard. Any silence this
--   long with an empty queue finalises the batch instead.
local ASK_SILENCE = 10

-- The server's verdict has a shelf life. Quest-log changes and levelling are
-- re-asked immediately, but availability also moves on reputation, skill, and
-- chains completed elsewhere -- none of which raise an event this addon sees.
-- Left alone, the set silently ages and the arrow keeps pointing at givers whose
-- quests are long gone.
local VERIFY_TTL = 60

-- The stale TTL, used after a SOFT invalidation. Short, because something did
-- happen and we would like to be right soon; not zero, because the whole point
-- is that the thing which happened fires every three seconds.
local VERIFY_TTL_STALE = 8

local function VerifyFinished()
    verifiedPending = false
    verifiedStale = false
    verifiedAt = GetTime()
    eligibleDirty = true
end

-- The client CANNOT decide this on its own. Prerequisite chains, exclusive
-- groups, class/skill/reputation gates and quest-chain state are all server
-- side; a local guess at level and race points the player at quest givers who
-- will never offer them anything, which is exactly what it did.
local function VerifyCandidates(ids)
    if #ids == 0 or verifiedPending then return end
    verifiedPending = true

    -- ⚠ Stamped NOW, not when the batch finishes. The TTL check in Scan reads
    --   this, and a batch that takes twenty seconds to drain would otherwise be
    --   measured against a timestamp of 0 the moment its first chunk answered --
    --   i.e. instantly expired, hard-reset mid-drain, and re-asked forever.
    verifiedAt = GetTime()
    askActivityAt = verifiedAt
    askNextAt = 0

    -- Sent as questId,giverEntry pairs. The entry lets the server confirm that
    -- giver actually offers the quest right now, which is the only way to catch
    -- event-gated givers -- an out-of-season candy bucket passes every
    -- player-side check and offers nothing.
    local chunk = {}
    for i = 1, #ids do
        local e = UncappedQuestGivers and UncappedQuestGivers[ids[i]]
        chunk[#chunk + 1] = ids[i] .. "," .. tostring((e and e[9]) or 0)
        if #chunk >= 15 or i == #ids then
            askQueue[#askQueue + 1] = "QLCHK:" .. table.concat(chunk, ",")
            chunk = {}
        end
    end
end

-- Called every frame by the driver below. Sends at most one queued QLCHK per
-- 1/ASK_PER_SEC seconds, and finalises a batch whose tail never came back.
local function DrainAskQueue()
    local now = GetTime()

    if #askQueue > 0 then
        if now >= askNextAt then
            local body = table.remove(askQueue, 1)
            if UQ.Send then UQ.Send(body) end
            askActivityAt = now
            askNextAt = now + (1 / ASK_PER_SEC)
        end
        return
    end

    if verifiedPending and (now - askActivityAt) > ASK_SILENCE then
        VerifyFinished()
    end
end

function UQ.OnVerifiedAvailable(list, done)
    if not verified then verified = {} end
    for id in tostring(list):gmatch("%d+") do
        verified[tonumber(id)] = true
    end

    askActivityAt = GetTime()

    -- Show what has been ruled on so far rather than nothing until the last
    -- chunk lands. Cheap: eligibleDirty is only CONSUMED on the 3-second scan
    -- tick, so however many chunks arrive it costs at most one extra rebuild
    -- per three seconds.
    eligibleDirty = true

    if done then
        --[[ ⚠⚠ [#1277] QLOKEND IS PER CHUNK, NOT PER BATCH.

             quest_ledger_comms_playerscript.cpp sends QLOK+QLOKEND at the end
             of every single QLCHK it handles. That was invisible while the
             whole batch went out in one frame -- the guard cleared after the
             last reply either way. The moment sending is PACED it becomes a
             live bug: the first chunk's QLOKEND would clear `verifiedPending`
             while twenty more were still queued, BuildEligible would see an
             idle verifier and start a SECOND batch on top of the first, and
             the pacing would be defeated by the thing it was added for.

             So the guard clears on the QUEUE being empty as well. Fixed here
             rather than server-side because a one-QLOKEND-per-batch server
             would break every already-shipped client that expects one per
             chunk. ]]
        if #askQueue == 0 then
            VerifyFinished()
        end
    end
end

--[[ HARD invalidation: the verdict is wrong, drop it and ask again.

     ⚠ Reserved for the events where every gate really did move at once --
       PLAYER_LEVEL_UP and QUEST_QUERY_COMPLETE. Anything that fires on a timer
       must use UQ.SoftInvalidateAvailable instead; calling this one on the
       ledger beat is precisely the bug #1277 was.
]]
function UQ.ResetVerifiedAvailable()
    verified, verifiedPending = nil, false
    verifiedAt, verifiedStale = 0, false
    verifiedMap = nil

    -- Anything still queued was built for the verdict we are throwing away, so
    -- sending it would spend budget on an answer nobody will read.
    --
    -- ⚠ Chunks already ON THE WIRE cannot be recalled, and their QLOK replies
    --   will land against the NEXT batch. Benign, and deliberately not worth a
    --   generation counter: the ids are additive, so the worst case is a batch
    --   finalising one chunk early and the shortened stale TTL asking again.
    for i = #askQueue, 1, -1 do askQueue[i] = nil end

    -- `eligible` is DERIVED from the verdict, so dropping one must drop the
    -- other. Without this, Scan happily kept using a list built from a verdict
    -- that no longer existed -- which is why taking a quest left the arrow on
    -- the giver it came from until a reload rebuilt everything from scratch.
    -- The callers that set eligibleDirty themselves were masking it; the paths
    -- that did not (an off-slot accept raises no client event) were not.
    eligibleDirty = true
end

--[[ SOFT invalidation: the verdict is SUSPECT, not wrong.

     Keeps the verdict, marks it stale so the shortened TTL applies, and
     rebuilds `eligible` -- which is the part that actually matters to the
     player, because dropping the quest they just accepted out of the arrow is
     a LOCAL filter (`inLog`) and costs no server messages at all.

     This is what the ledger burst and QUEST_LOG_UPDATE call. Both fire on the
     beat rather than on a real change in availability.
]]
function UQ.SoftInvalidateAvailable()
    -- Nothing to make stale yet, and nothing to gain from asking sooner.
    if not verified then return end

    verifiedStale = true
    eligibleDirty = true
end

local function BuildEligible(mapID)
    -- ⚠ A verdict asked about ANOTHER map's candidates answers nothing about
    --   this one, and because it is non-nil it also stops the re-ask below from
    --   ever firing. That left the pick-up arrow blank after every continent
    --   change until the 60s TTL happened to expire.
    if verified and verifiedMap ~= mapID and not verifiedPending then
        UQ.ResetVerifiedAvailable()
    end

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
    for _, qid in ipairs(bucket) do
        local e = UncappedQuestGivers[qid]
        local minLevel, questLevel, races = e[4], e[5], e[6]

        -- A giver whose SPAWN is event-controlled is not standing there unless
        -- that event is running. The quest itself passes every other check --
        -- an out-of-season candy bucket is a real, takeable, permanently
        -- related quest attached to a gameobject that does not exist.
        local ev = e[10] or 0
        local spawned = (ev == 0) or (UQ.ActiveEvents and UQ.ActiveEvents[ev])

        if spawned
           and (not completed[qid]) and (not inLog[qid])
           and level >= minLevel
           and (questLevel <= 0 or questLevel <= maxLevel)
           and (races == 0 or raceMask == 0 or bit.band(races, raceMask) ~= 0)
           and GiverReachable(qid) then
            candidates[#candidates + 1] = qid
        end
    end

    if not verified then
        VerifyCandidates(candidates)
        verifiedMap = mapID
        return          -- nothing shown until the server has ruled
    end

    for _, qid in ipairs(bucket) do
        local e = UncappedQuestGivers[qid]
        local minLevel, questLevel, races = e[4], e[5], e[6]

        local ev2 = e[10] or 0
        local spawned2 = (ev2 == 0) or (UQ.ActiveEvents and UQ.ActiveEvents[ev2])

        if verified[qid] and spawned2
           and (not completed[qid]) and (not inLog[qid])
           and level >= minLevel
           and (questLevel <= 0 or questLevel <= maxLevel)
           and (races == 0 or raceMask == 0 or bit.band(races, raceMask) ~= 0) then
            eligible[#eligible + 1] = {
                questID = qid,
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
            for _, qid in ipairs(byMap[mapID] or {}) do
                local e = UncappedQuestGivers[qid]
                if (not completed[qid]) and (not inLog[qid]) and level >= e[4] then
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
    --
    -- ⚠ `not verifiedPending` is load-bearing, not tidiness. A batch takes
    --   seconds to drain now, and `verified` becomes non-nil on its FIRST chunk
    --   -- so without this guard the very next scan would age out a verdict that
    --   is still arriving, hard-reset it, and re-ask the whole continent. That
    --   is an infinite re-ask loop, i.e. a worse version of the bug being fixed.
    local ttl = verifiedStale and VERIFY_TTL_STALE or VERIFY_TTL
    if verified and not verifiedPending and (GetTime() - verifiedAt) > ttl then
        UQ.ResetVerifiedAvailable()
        eligibleDirty = true
    end

    if eligibleDirty or eligibleMap ~= player.map then BuildEligible(player.map) end

    local bestD, best
    for _, cand in ipairs(eligible) do
        -- Filtered at selection time rather than inside BuildEligible, so
        -- ignoring a quest takes effect on the very next scan without having to
        -- invalidate and rebuild the eligibility cache.
        if not UQ.IsIgnored(cand.questID) then
            local d = UQ.WorldDistance(player, cand)
            if d and (not bestD or d < bestD) then bestD, best = d, cand end
        end
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
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cff808080Right-click to ignore this quest. It stops being suggested here and disappears from your map.|r", nil, nil, nil, true)
    GameTooltip:Show()
end)
arrow:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Right-click to ignore. The pick-up arrow always points at the NEAREST quest
-- you can take, which is exactly wrong when the nearest one is a quest you have
-- deliberately decided not to do -- it then parks on that quest forever and the
-- feature is useless until you take it. Ignoring is recorded in SavedVariables
-- (UQ.SetIgnored) and honoured by the scan above, the map pins and the objective
-- arrow's route alike, so one right-click removes the quest everywhere.
--
-- Nothing is bound to left-click: the objective arrow uses left-click to select
-- a quest in the log, but a quest you have not taken has no log entry to select.
arrow:RegisterForClicks("RightButtonUp")
arrow:SetScript("OnClick", function(_, button)
    if button ~= "RightButton" or not target then return end

    local title = target.title or "That quest"
    UQ.SetIgnored(target.questID, true)

    -- Drop it now rather than waiting for the next scan, so the arrow visibly
    -- moves on to the next quest the instant it is clicked.
    target = nil
    GameTooltip:Hide()

    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Ignoring |cffffffff" .. title
        .. "|r. Clear ignored quests in ESC > Interface > AddOns > Uncapped > Quests.")
end)

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

-- The disabled and no-target paths are the COMMON ones -- most players never
-- turn the pick-up arrow on at all -- and they used to call Hide() on both
-- frames on every single frame. The sibling arrow file already guards exactly
-- this (HideArrow, UncappedQuestsArrow.lua); this driver did not.
local function HideIf(f)
    if f:IsShown() then f:Hide() end
end

local function ShowIf(f)
    if not f:IsShown() then f:Show() end
end

driver:SetScript("OnUpdate", function(_, elapsed)
    local self = arrow

    -- ⚠ AHEAD OF THE ENABLED GATE, deliberately. UQ.AvailableGiverPins drives
    --   BuildEligible for the map's giver-pin layer, which is a separate opt-in
    --   from the arrow -- so QLCHK work can be queued with `availEnabled` false.
    --   Draining below the gate would park those asks until the player happened
    --   to switch the arrow on.
    DrainAskQueue()

    if not db.availEnabled then
        HideIf(self); HideIf(note)
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
        HideIf(self)
        if instanceNote then
            -- Same string every frame while you stand in the same instance, so
            -- only push it when it actually changes.
            if note.uqShownText ~= instanceNote then
                note.uqShownText = instanceNote
                note.text:SetText(instanceNote)
            end
            ShowIf(note)
        else
            HideIf(note)
        end
        return
    end

    HideIf(note)

    if not target then
        HideIf(self)
        return
    end

    local dist, dx, dy = UQ.WorldDistance(player, target)
    if not dist then
        HideIf(self)
        return
    end

    ShowIf(self)
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

    if event == "PLAYER_LEVEL_UP" then
        -- HARD. A level changes minLevel, questLevel and half the satisfy chain
        -- at once, so the whole verdict really is wrong. It also happens rarely
        -- enough that a full re-ask costs nothing.
        UQ.ResetVerifiedAvailable()
        eligibleDirty = true
        return
    end

    if event == "QUEST_LOG_UPDATE" then
        -- SOFT. [#1277] This fires on accepting, abandoning, completing, an
        -- objective ticking over, and repeatedly during a zone-in -- far more
        -- often than availability actually moves. The part the player sees (the
        -- quest just accepted leaving the arrow) is a LOCAL filter and needs no
        -- server round trip; the part that does need one can wait for the
        -- shortened stale TTL.
        UQ.SoftInvalidateAvailable()
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
    if not (dbcArea and UncappedMapAreas) then return out end

    -- [MQ-05] BuildIndex is what LOADS the giver table now, so it has to run
    -- before UncappedQuestGivers is tested. Testing the global first -- which is
    -- what this guard used to do -- would return empty forever and never trigger
    -- the on-demand load, silently killing the giver pin layer.
    BuildIndex()
    if not UncappedQuestGivers then return out end

    local player = UQ.PlayerNode()
    if player and (eligibleDirty or eligibleMap ~= player.map) then
        BuildEligible(player.map)
    end

    for _, cand in ipairs(eligible) do
        if not UQ.IsIgnored(cand.questID) then
            local mapID, mx, my = UQ.MapPos(dbcArea, cand.wx, cand.wy)
            if mapID and mx and mx >= 0 and mx <= 1 and my >= 0 and my <= 1 then
                out[#out + 1] = {
                    questID = cand.questID, title = cand.title,
                    giver = cand.giver, x = mx, y = my,
                }
            end
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

        -- [#1277] The pacing state. Without this the only symptom of a starved
        -- bucket was an arrow that pointed at nothing, which is indistinguishable
        -- from having no quests nearby -- and that is how 20,721 dropped commands
        -- went unnoticed for as long as they did.
        say(string.format("queued asks: %d   |   verdict age: %s   |   %s",
            #askQueue,
            verifiedAt > 0 and string.format("%.0fs", GetTime() - verifiedAt) or "n/a",
            verifiedStale and "|cffffd100STALE (short TTL)|r" or "fresh"))

        local UT = _G.UncappedThrottle
        if UT and UT.DropCount and UT.DropCount() > 0 then
            say(string.format("|cffff8040the server has dropped %d of this session's addon "
                .. "commands|r (/uthrottle)", UT.DropCount()))
        end

        local inLog = QuestsInLog()
        local level = UnitLevel("player") or 1
        local raceMask = PlayerRaceMask()
        local maxLevel = level + (db.availMaxLevel or 3)

        -- Everything within 200 yards, eligible or not, nearest first.
        local near = {}
        for _, qid in ipairs((byMap and byMap[player.map]) or {}) do
            local e = UncappedQuestGivers[qid]
            local d = UQ.WorldDistance(player, { map = e[1], wx = e[2], wy = e[3] })
            if d and d <= 200 then
                near[#near + 1] = { d = d, qid = qid, giver = e[7], title = e[8],
                    why = Rejection(qid, e, inLog, level, raceMask, maxLevel) }
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
