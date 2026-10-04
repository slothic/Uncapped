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

local FLIP_WINDOW     = 3     -- seconds within which a big move must be undone to be a flip
local FLIP_RETURN     = 0.15  -- how close to the starting fraction the undo must land
local MISMATCH_SECONDS = 1.5  -- how long native and bar must disagree before we report it
local flipFrom, flipAt, flipDir, mismatchSince = nil, 0, 0, nil
local fullAt, zeroAt = nil, nil   -- last time at >=90% / at <=3%, for the zero-flip test

local STREAM_STEP   = 0.10   -- send when health moved this fraction of max since the last line
local STREAM_BEAT   = 10     -- ...or at least this often, seconds
local STREAM_RATE   = 3      -- token bucket refill, lines per second
local STREAM_BUCKET = 6      -- burst allowance
local streamFrac, streamAt, streamTokens, streamClock = nil, 0, STREAM_BUCKET, 0

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

    -- Selected display value and raw server feed are distinct. The formatter may
    -- reject a stale UHP:S; calling that cache the bar produced false mismatches.
    local barFrac, barAge, barTxt = nil, nil, ""
    local feedTxt = ""
    if type(Uncapped64bitUI_SelfHealth) == "function" then
        local bcur, bmax, age, fcur, fmax = Uncapped64bitUI_SelfHealth()
        if bcur and bmax and bmax > 0 then
            barFrac, barAge = bcur / bmax, age
            barTxt = string.format(" bar=%.3f age=%.1f", barFrac * 100, age)
        end
        if fcur and fmax and fmax > 0 then
            feedTxt = string.format(" feed=%.3f", fcur / fmax * 100)
        end
    end

    local life = (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) and "dead" or "alive"
    local line = string.format("hp=%d max=%d pct=%.3f%s%s %s %s", hp, max, frac * 100, barTxt, feedTxt, life, reason)
    Push(line)
    WriteLocal(line)

    -- ★ CONTINUOUS FEED. Nobody has to notice a bounce and type anything: the client
    -- tells the server what its health field says, and addon_pipe.log keeps it.
    -- Sent when health has moved >= STREAM_STEP of max since the last line we sent, or
    -- as a heartbeat every STREAM_BEAT seconds, and through a token bucket so a
    -- flapping bar cannot flood the throttled addon channel -- which would cost us the
    -- very samples we want. A full->0->full swing is two 100% moves, so it always
    -- qualifies. Line: HPT:S:<hp>:<max>:<pct>:<barpct|->:<barage|->:<clock>:<reason>
    local now = Now()
    streamTokens = math.min(STREAM_BUCKET, streamTokens + (now - streamClock) * STREAM_RATE)
    streamClock = now
    if streamTokens >= 1
       and (not streamFrac or math.abs(frac - streamFrac) >= STREAM_STEP
            or now - streamAt >= STREAM_BEAT) then
        streamTokens = streamTokens - 1
        streamFrac, streamAt = frac, now
        SendAddonMessage(ADDON_PREFIX, string.format("HPT:S:%d:%d:%.1f:%s:%s:%.1f:%s%s %s",
            hp, max, frac * 100,
            barFrac and string.format("%.1f", barFrac * 100) or "-",
            barAge and string.format("%.1f", barAge) or "-",
            now, string.sub(reason, 1, 60), feedTxt, life), "WHISPER", UnitName("player"))
    end

    -- ★ A bounce is a FLIP: an unexplained big move that is undone within FLIP_WINDOW.
    -- A single big unexplained move is an ordinary heal, a death, a revive or a
    -- percent-health boss mechanic -- 09-19 traced 129 bursts from 34 players and every
    -- one read was one of those, so the old "any big move" trigger only buried the signal.
    local t = Now()
    if lastFrac and reason == "-" then
        local delta = frac - lastFrac
        if delta > BOUNCE_FRACTION or delta < -BOUNCE_FRACTION then
            if flipFrom and (t - flipAt) <= FLIP_WINDOW and math.abs(frac - flipFrom) <= FLIP_RETURN
               and (delta > 0) ~= (flipDir > 0) then
                local why = string.format("flip from=%.3f to=%.3f back=%.3f", flipFrom, lastFrac, frac)
                WriteLocal("BOUNCE " .. why)
                Burst(string.format("%.2f:%.2f:%.2f", flipFrom, lastFrac, frac))
                flipFrom = nil
            else
                flipFrom, flipAt, flipDir = lastFrac, t, delta
            end
        end
    end

    -- ★ FULL -> ~0 -> FULL, whatever the combat log says. The flip test above only counts
    -- moves with NO combat-log reason, so a swing to zero that arrives with a damage event
    -- attached was classed as explained and ignored -- which is precisely the reported
    -- symptom ("full hp to 0"). A real death is excluded: a corpse does not climb back to
    -- full inside FLIP_WINDOW without a resurrect, and UnitIsDeadOrGhost covers that.
    if frac >= 0.9 then
        fullAt = t
    end
    if frac <= 0.03 and fullAt and (t - fullAt) <= FLIP_WINDOW
       and not (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) then
        zeroAt = t
    end
    if frac >= 0.9 and zeroAt and (t - zeroAt) <= FLIP_WINDOW then
        WriteLocal(string.format("BOUNCE zero-flip full->0->full in %.1fs", t - zeroAt))
        Burst(string.format("zero:%.2f", frac))
        zeroAt = nil
    end

    -- ★ The other failure: the native field and our bar disagree and stay that way.
    -- Sustained, because the two feeds legitimately differ for a frame or two.
    if barFrac and math.abs(barFrac - frac) > BOUNCE_FRACTION then
        mismatchSince = mismatchSince or t
        if t - mismatchSince >= MISMATCH_SECONDS then
            WriteLocal(string.format("BAR-MISMATCH native=%.3f bar=%.3f age=%.1f", frac, barFrac, barAge))
            Burst(string.format("bar:%.2f:%.2f:%.0f", frac, barFrac, barAge))
            mismatchSince = nil
        end
    else
        mismatchSince = nil
    end

    lastFrac, lastHP, lastMax = frac, hp, max
end

local f = CreateFrame("Frame")
local lastPredictionReport = -30
local function ReportPrediction()
    local ok, prediction = pcall(GetCVar, "predictedHealth")
    if not ok or prediction == nil then return end
    local native = "absent"
    if type(UncappedHealthPrediction) == "function" then
        local good, status = pcall(UncappedHealthPrediction)
        if good and type(status) == "string" then native = status end
    end
    SendAddonMessage(ADDON_PREFIX, "HPT:P:" .. tostring(prediction) .. ":native=" .. native,
        "WHISPER", UnitName("player"))
    lastPredictionReport = Now()
end
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("UNIT_HEALTH")
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

f:SetScript("OnEvent", function(self, event, ...)
    local e = event or _G.event

    if e == "PLAYER_ENTERING_WORLD" then
        lastFrac = nil
        WriteLocal("---- entering world ----")
        -- Record the actual client policy separately from sampled health. The
        -- native predictor can repaint between UNIT_HEALTH events.
        ReportPrediction()
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
    if Now() - lastPredictionReport >= 30 then ReportPrediction() end
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
