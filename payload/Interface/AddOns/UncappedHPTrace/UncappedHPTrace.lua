--[[
    UncappedHPTrace -- catch a health bar that bounces, with the reason beside it.

    ★ WHY THIS EXISTS

    Players reported "full health no health full health no health ... and splat":
    a bar flipping between full and empty and then a death behind a healthy-looking
    bar. A fix shipped 2026-09-18 (the UHP:S feed going silent while the interface
    addon stayed latched onto its last value), but nothing on the client could
    CONFIRM it, and a bar is a client-side artefact -- the server can only ever say
    what it sent, never what was drawn.

    ★ THE THREE SOURCES, AND WHY ALL THREE ARE NEEDED

      1. What the server SENT       -- addon_pipe.log, UHP:S lines, already live
      2. What the client FIELD says -- UnitHealth("player"), recorded here
      3. WHY it moved               -- the heal or the hit, recorded here

    A bounce in (2) with (1) steady means the client is lying and the latch is the
    cause. A bounce in (1) too means the server is, and the diagnosis was wrong.
    Without (3) either is just a number changing, which is what a health bar does
    all day.

    ★ TWO SINKS, ON PURPOSE

      local  UncappedHPTrace(text)  -- the DLL's bridge; every sample, full
                                       fidelity, bounded at 8 MB. Deep dives.
      server REAGENTBANK self-whisper -- a short burst when a bounce is DETECTED.
                                       Lands in addon_pipe.log centrally, so the
                                       data arrives without asking anyone for a file.

    The burst is the one that matters for "have the data in a week". The local
    file is what you read once a burst tells you where to look.

    ⚠ Rate-limited hard. This runs on every player's client, in combat, and the
      addon channel is throttled server-side -- a chatty diagnostic would be
      dropped precisely when something interesting is happening.
]]

local ADDON_PREFIX   = "REAGENTBANK"   -- the client->server transport (self-whisper only)
local RING_SIZE      = 24              -- samples kept around a bounce
local BURST_COOLDOWN = 30              -- seconds between server bursts
local BURST_LINES    = 8               -- lines sent per burst, newest last

-- A jump of more than this fraction of max health, with nothing in the combat log
-- to explain it, is what we call a bounce. Deliberately coarse: the reported
-- symptom is full<->empty, not jitter, and a low threshold would fire on ordinary
-- big hits at this realm's scale.
local BOUNCE_FRACTION = 0.35

local ring, ringPos, ringCount = {}, 0, 0
local lastFrac, lastHP, lastMax = nil, nil, nil
local lastBurst = 0
local pendingReason = nil   -- set by the combat log, consumed by the next sample
local addonsReported = false
local reportAt = nil        -- delayed addon census, see ScheduleAddOnReport

local function Now()
    return GetTime and GetTime() or 0
end

-- The DLL bridge is absent on a client running the addons without the payload
-- (and on the login screen before the bridge registers), so every call is guarded.
-- A missing bridge degrades to "server bursts only" rather than erroring.
local function WriteLocal(text)
    if type(UncappedHPTrace) == "function" then
        pcall(UncappedHPTrace, text)
    end
end

local function Push(text)
    ringPos = (ringPos % RING_SIZE) + 1
    ring[ringPos] = text
    if ringCount < RING_SIZE then
        ringCount = ringCount + 1
    end
end

-- Oldest-first walk of the ring, so a burst reads in chronological order.
local function Each(fn)
    local start = ringPos - ringCount
    for i = 1, ringCount do
        local idx = ((start + i - 1) % RING_SIZE) + 1
        fn(ring[idx])
    end
end

local function Burst(why)
    local now = Now()
    if now - lastBurst < BURST_COOLDOWN then
        return
    end
    lastBurst = now

    -- Header first so a truncated burst is still attributable.
    SendAddonMessage(ADDON_PREFIX, "HPT:B:" .. why, "WHISPER", UnitName("player"))

    local lines, keep = {}, {}
    Each(function(t) lines[#lines + 1] = t end)
    -- Newest BURST_LINES, oldest first.
    for i = math.max(1, #lines - BURST_LINES + 1), #lines do
        keep[#keep + 1] = lines[i]
    end
    for i = 1, #keep do
        -- 255 bytes is the client's hard addon-message cap; well clear of it.
        SendAddonMessage(ADDON_PREFIX, "HPT:L:" .. string.sub(keep[i], 1, 200),
                         "WHISPER", UnitName("player"))
    end
end

--[[
    The addon census -- every addon installed, enabled or not.

    ★ WHY IT BELONGS IN A HEALTH-BAR TRACE

    The player's health bar is not necessarily OURS. A third-party unit-frame
    addon draws its own, from its own cached numbers, and would bounce for
    reasons nothing on our side can see. If the players reporting a bounce all
    run the same frame addon, that is the answer and it is not the latch.

    It also answers the other recurring question cheaply: third-party addons are
    what blow the server-side addon throttle, and until now identifying them
    meant asking the player to list them by hand.

    Enabled AND disabled are both reported: a disabled addon is still installed,
    still updated, and still the thing a player re-enables between two reports.

    ⚠ DELAYED. Login is exactly when the addon channel is busiest and the
      server-side throttle is already dropping commands -- sending a census into
      that costs us the census. A few seconds later the channel is idle.
]]
local function ReportAddOns()
    if addonsReported or not GetNumAddOns then
        return
    end
    addonsReported = true

    local n = GetNumAddOns() or 0
    WriteLocal(string.format("---- addons installed: %d ----", n))

    -- "+Name" enabled, "-Name" disabled, trailing "!" if the client says it
    -- cannot load (missing dependency, wrong interface version, corrupt).
    local batch, line = {}, ""
    for i = 1, n do
        local name, _, _, enabled, loadable = GetAddOnInfo(i)
        name = tostring(name)
        local mark = (enabled and "+" or "-") .. name .. (loadable and "" or "!")

        WriteLocal("addon " .. mark)

        -- Pack several per message; 255 bytes is the client's hard cap and the
        -- prefix costs some of it, so 180 is the working budget.
        if string.len(line) + string.len(mark) + 1 > 180 then
            batch[#batch + 1] = line
            line = mark
        else
            line = (line == "") and mark or (line .. "," .. mark)
        end
    end
    if line ~= "" then
        batch[#batch + 1] = line
    end

    SendAddonMessage(ADDON_PREFIX, "HPT:A:" .. n, "WHISPER", UnitName("player"))
    for i = 1, #batch do
        SendAddonMessage(ADDON_PREFIX, "HPT:A" .. i .. ":" .. batch[i],
                         "WHISPER", UnitName("player"))
    end
end

local function ScheduleAddOnReport()
    reportAt = Now() + 12
end

local function Sample(tag)
    local hp  = UnitHealth("player") or 0
    local max = UnitHealthMax("player") or 0
    if max <= 0 then
        return
    end

    local frac = hp / max
    local reason = pendingReason or tag or "-"
    pendingReason = nil

    local line = string.format("hp=%d max=%d pct=%.3f %s", hp, max, frac * 100, reason)
    Push(line)
    WriteLocal(line)

    -- A bounce is a big move with nothing in the combat log to account for it.
    if lastFrac and reason == "-" then
        local delta = frac - lastFrac
        if delta > BOUNCE_FRACTION or delta < -BOUNCE_FRACTION then
            local why = string.format("delta=%.3f from=%.3f to=%.3f unexplained",
                                      delta, lastFrac, frac)
            WriteLocal("BOUNCE " .. why)
            Burst(string.format("%.2f:%.2f", lastFrac, frac))
        end
    end

    lastFrac, lastHP, lastMax = frac, hp, max
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("UNIT_HEALTH")
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

f:SetScript("OnEvent", function(self, event, ...)
    local e = event or _G.event

    if e == "PLAYER_ENTERING_WORLD" then
        lastFrac = nil
        WriteLocal("---- entering world ----")
        Sample("enter")
        ScheduleAddOnReport()
        return
    end

    if e == "UNIT_HEALTH" then
        local unit = ...
        if unit == "player" or (not unit and arg1 == "player") then
            Sample(nil)
        end
        return
    end

    if e == "COMBAT_LOG_EVENT_UNFILTERED" then
        -- 3.3.5a argument order, which has NO hideCaster field:
        --   timestamp, event, sourceGUID, sourceName, sourceFlags,
        --   destGUID, destName, destFlags, ...
        local _, sub, _, srcName, _, dstGUID, _, _, a9, a10, a11, a12 = ...
        if not sub or dstGUID ~= UnitGUID("player") then
            return
        end

        -- Only what MOVES the player's own health, and only enough of it to
        -- explain a sample. Everything else is noise in a file someone has to read.
        if sub == "SPELL_HEAL" or sub == "SPELL_PERIODIC_HEAL" then
            -- a9 = spellId, a10 = spellName, a12 = amount
            pendingReason = string.format("HEAL %s from %s amount=%s",
                tostring(a10), tostring(srcName), tostring(a12))
        elseif sub == "SPELL_DAMAGE" or sub == "SPELL_PERIODIC_DAMAGE" then
            pendingReason = string.format("DMG %s from %s amount=%s",
                tostring(a10), tostring(srcName), tostring(a12))
        elseif sub == "SWING_DAMAGE" then
            -- No spell fields on a swing: amount is the first event argument.
            pendingReason = string.format("SWING from %s amount=%s",
                tostring(srcName), tostring(a9))
        elseif sub == "ENVIRONMENTAL_DAMAGE" then
            pendingReason = string.format("ENV %s amount=%s",
                tostring(a9), tostring(a10))
        end
        return
    end
end)

-- The census is the only thing here that needs a clock; everything else is
-- event-driven. Detached from the event frame so a stuck handler cannot stop it.
local driver = CreateFrame("Frame")
driver:SetScript("OnUpdate", function()
    if reportAt and Now() >= reportAt then
        reportAt = nil
        ReportAddOns()
    end
end)

SLASH_UNCAPPEDHPTRACE1 = "/hptrace"
SlashCmdList["UNCAPPEDHPTRACE"] = function(arg)
    if arg == "burst" then
        lastBurst = 0
        Burst("manual")
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[HPTrace]|r sent a manual burst.")
        return
    end
    if arg == "addons" then
        addonsReported = false
        ReportAddOns()
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[HPTrace]|r sent the addon census.")
        return
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[HPTrace]|r "
        .. ringCount .. " samples held, local bridge "
        .. (type(UncappedHPTrace) == "function" and "present" or "ABSENT")
        .. ". /hptrace burst | /hptrace addons")
end
