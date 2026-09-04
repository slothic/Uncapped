--[[
  UncappedThrottle -- shared client-side view of server backpressure.  [#1277]

  ===========================================================================
  WHY THIS FILE EXISTS
  ===========================================================================

  The server meters every inbound addon verb with a per-player token bucket
  (src/server/game/Handlers/AddonThrottle.{h,cpp}). When the bucket cannot
  afford what you sent, the message is DROPPED -- not answered, not queued.

  For a year that drop was completely silent, and the consequence was not
  subtle. Measured on the live realm for one boot: 27 distinct characters,
  20,721 dropped commands, against a peak of 13 players online. One reporter
  ate 10,137 of them across 34 separate minutes -- a bucket pinned at zero,
  not a burst. Every one of those rendered to the player as "the panel is
  empty" or "the button does nothing", and FOUR separate bug reports were
  filed about four different features that were all this one thing.

  ⚠ AND NOBODY COULD REPRODUCE ANY OF THEM. Game masters hold
    RBAC_PERM_SKIP_CHECK_CHAT_SPAM and AddonThrottle exempts them by design
    (diagnosing a stuck client means asking it a lot of questions fast). So
    every attempt to reproduce a report was made by an account that could not
    experience the bug.

  The server now pushes ONE generic line when it drops something:

        UNC  ->  "UTHR:<retryAfterMs>"

  ★ IT NAMES NO VERB, and it must never start to. The whole security argument
    for answering at all (written out in AddonThrottle.h) is that the notice is
    IDENTICAL for a live verb, a retired verb and a verb that never existed --
    so it partitions nothing and tells a prober only that their own bucket is
    empty, which is a fact they created. A per-verb notice would be a probe
    oracle. If you are tempted to add the verb "just for debugging", don't.

  ===========================================================================
  WHAT TO DO WITH IT
  ===========================================================================

    UncappedThrottle.IsThrottled()      -- am I inside a retry-after window
    UncappedThrottle.RetryIn()          -- seconds left, 0 when clear
    UncappedThrottle.StatusText()       -- nil, or a sentence fit for a panel
    UncappedThrottle.DropCount()        -- notices seen this session
    UncappedThrottle.OnDrop(fn)         -- fn(retrySeconds) on every notice
    UncappedThrottle.Reask(key, fn)     -- bounded, backing-off re-ask
    UncappedThrottle.Settled(key)       -- the reply arrived; stop retrying
    UncappedThrottle.Cancel(key)        -- give up on it silently

  ⚠ UTHR IS A DIAGNOSIS, NEVER A CLOCK. Do not pace normal sending off
    RetryIn(): it only ever arrives AFTER something was already thrown away, it
    is rate limited to one per two seconds server-side, and a client that waits
    on it is a client that has already lost a message. Pace your own sends
    (UncappedQuestsAvailable.lua's QLCHK queue is the worked example); use this
    to explain a failure and to re-ask once.

  ⚠ AND THE NOTICE ITSELF CAN BE DROPPED -- it rides the same wire, and it is
    rate limited, so a burst of ten drops produces one notice. Never write a
    panel that only leaves its "loading" state when a UTHR arrives. Every
    caller of Reask must ALSO have a plain timeout, which is why Reask fires
    on a timer of its own rather than waiting to be told.

  Depends on nothing -- not even UncappedUIKit. It is transport, it loads
  early, and a panel that wants it reads _G.UncappedThrottle at call time so a
  load-order mistake degrades to "no explanation" rather than to an error.
]]

local ADDON_PREFIX = "UNC"

local UT = _G.UncappedThrottle or {}
_G.UncappedThrottle = UT

UT.version = 1

-- ---------------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------------

local retryUntil = 0        -- GetTime() before which the server says not to bother
local lastDropAt = 0
local dropCount  = 0

local listeners = {}

-- key -> { fn, at, delay, tries, maxTries, onGiveUp }
-- ⚠ NO SEPARATE COUNTER. A count can disagree with the table -- a job whose fn
--   calls Settled() or re-registers its own key gets removed twice, the count goes
--   NEGATIVE, and `count == 0` is then never true again, which pins the OnUpdate
--   driver on for the rest of the session. That is exactly the always-on per-frame
--   cost this file exists to avoid. next(jobs) cannot drift from jobs.
local jobs = {}

-- ---------------------------------------------------------------------------
-- reading the state
-- ---------------------------------------------------------------------------

function UT.IsThrottled()
    return GetTime() < retryUntil
end

function UT.RetryIn()
    local left = retryUntil - GetTime()
    if left < 0 then return 0 end
    return left
end

function UT.DropCount()
    return dropCount
end

function UT.LastDropAt()
    return lastDropAt
end

-- A sentence a panel can print verbatim, or nil when there is nothing to say.
--
-- Deliberately says "the server", not "you are being rate limited": from the
-- player's chair this is the server being busy, and the one thing they can
-- usefully do is wait a moment. Naming the throttle would invite them to go
-- looking for a setting that is not theirs.
function UT.StatusText()
    local left = UT.RetryIn()
    if left <= 0 then return nil end
    if left < 1 then
        return "The server is busy. Retrying in a moment."
    end
    return string.format("The server is busy. Retrying in %d second%s.",
        math.ceil(left), math.ceil(left) == 1 and "" or "s")
end

-- fn(retrySeconds). Called for every notice, in registration order.
function UT.OnDrop(fn)
    if type(fn) == "function" then
        listeners[#listeners + 1] = fn
    end
end

-- ---------------------------------------------------------------------------
-- the bounded re-ask
-- ---------------------------------------------------------------------------

-- The driver is attached only while there is work and detached the moment there
-- is none, so an idle client pays literally nothing for this file. An always-on
-- OnUpdate that returns immediately is still a function call every frame for
-- every player forever, and this addon suite has been bitten by exactly that
-- before (see HideIf in UncappedQuestsAvailable.lua).
local driver = CreateFrame("Frame")

local function stopDriverIfIdle()
    if next(jobs) == nil then
        driver:SetScript("OnUpdate", nil)
    end
end

local function tick()
    local now = GetTime()
    for key, job in pairs(jobs) do
        if now >= job.at then
            job.tries = job.tries + 1

            local ok = pcall(job.fn)

            if not ok or job.tries >= job.maxTries then
                -- Out of attempts (or the caller's own send errored). Drop the job
                -- and let whoever asked say so -- silently retrying forever is the
                -- failure this whole file exists to stop, not a nicer version of it.
                jobs[key] = nil
                if job.onGiveUp then pcall(job.onGiveUp) end
            else
                -- Exponential, and floored by whatever the server last told us --
                -- retrying inside a known retry-after window just spends another
                -- message on a bucket we have been told is empty.
                job.delay = math.min(job.delay * 2, job.maxDelay)
                job.at = now + math.max(job.delay, UT.RetryIn() + 0.25)
            end
        end
    end
    stopDriverIfIdle()
end

--[[
  Ask again, later, at most a few times.

    key       identifies the ASK, not the caller. Re-registering the same key
              replaces the outstanding job rather than stacking a second one --
              a player clicking a panel's button four times must not produce
              four retry ladders aimed at a bucket that is already empty.
    fn        the send. Called with no arguments; errors are caught and end the
              job rather than taking the frame down.
    opts      { tries = 3, base = 1.5, maxDelay = 12, onGiveUp = function() end }

  The FIRST attempt is already delayed -- there is no immediate call. Anything
  worth re-asking has just been dropped, and re-sending it in the same frame is
  the behaviour that turned one dropped command into ten thousand.
]]
function UT.Reask(key, fn, opts)
    if type(key) ~= "string" or type(fn) ~= "function" then return end
    opts = opts or {}

    local base = opts.base or 1.5
    local existed = jobs[key] ~= nil

    jobs[key] = {
        fn       = fn,
        tries    = 0,
        maxTries = opts.tries or 3,
        delay    = base,
        maxDelay = opts.maxDelay or 12,
        onGiveUp = opts.onGiveUp,
        -- Never sooner than the server's own retry-after: the first attempt is
        -- the one most likely to land inside the window that caused the drop.
        at       = GetTime() + math.max(base, UT.RetryIn() + 0.25),
    }

    if not existed then
    end
    driver:SetScript("OnUpdate", tick)
end

-- The reply arrived. Stop retrying.
function UT.Settled(key)
    if jobs[key] then
        jobs[key] = nil
        stopDriverIfIdle()
    end
end

UT.Cancel = UT.Settled

function UT.Pending(key)
    return jobs[key] ~= nil
end

-- ---------------------------------------------------------------------------
-- the wire
-- ---------------------------------------------------------------------------

local listener = CreateFrame("Frame")
listener:RegisterEvent("CHAT_MSG_ADDON")
listener:SetScript("OnEvent", function(_, _, prefix, body)
    if prefix ~= ADDON_PREFIX or type(body) ~= "string" then return end

    local ms = body:match("^UTHR:(%d+)$")
    if not ms then return end

    -- Anchored, and the only field is a number. If a future server ever wants to
    -- say more here, it gets a NEW verb: widening this pattern would make an older
    -- client stop matching and go back to being silently starved, which is the
    -- same trap ICSF/ICSACKS documents on the Soulforge pipe.
    local seconds = (tonumber(ms) or 0) / 1000
    if seconds <= 0 then return end

    -- Clamped, even though the server ceilings it at 15s and
    -- ReagentBankChannelProtocol::IsSpoofedPipeMessage refuses a player-sent
    -- "UNC" line outright. Two independent guards is the right number for a
    -- value that would otherwise let one crafted number park every panel in the
    -- suite on "the server is busy" for the rest of the session.
    if seconds > 60 then seconds = 60 end

    local now = GetTime()
    lastDropAt = now
    dropCount = dropCount + 1

    -- Extend, never shorten: two notices in flight should leave the later window
    -- standing rather than letting a stale one clear an active one.
    local until_ = now + seconds
    if until_ > retryUntil then retryUntil = until_ end

    for i = 1, #listeners do
        pcall(listeners[i], seconds)
    end
end)

-- ---------------------------------------------------------------------------
-- /uthrottle
-- ---------------------------------------------------------------------------
--
-- ★ This exists because a GM CANNOT SEE THIS BUG. AddonThrottle exempts
--   RBAC_PERM_SKIP_CHECK_CHAT_SPAM, so every reproduction attempt on a staff
--   account is a test of a code path the player was never on. When someone
--   reports a panel as empty, this is the one question worth asking them.
SLASH_UNCAPPEDTHROTTLE1 = "/uthrottle"
SlashCmdList["UNCAPPEDTHROTTLE"] = function()
    local say = function(s) DEFAULT_CHAT_FRAME:AddMessage("|cff59bfe6[Uncapped]|r " .. s) end

    if dropCount == 0 then
        say("The server has not dropped any of this session's addon traffic.")
        return
    end

    say(string.format("The server has dropped addon traffic |cffffd100%d|r time%s this session.",
        dropCount, dropCount == 1 and "" or "s"))
    say(string.format("Last one %.0f seconds ago.", GetTime() - lastDropAt))

    local left = UT.RetryIn()
    if left > 0 then
        say(string.format("|cffff8040Still throttled|r -- clear in %.1fs.", left))
    else
        say("|cff40ff40Clear now.|r")
    end

    local n = 0
    for _ in pairs(jobs) do n = n + 1 end
    if n > 0 then
        say(string.format("%d request%s waiting to be re-asked.", n, n == 1 and "" or "s"))
    end
end
