-- UncappedMythic
--
-- The keystone run HUD. When the server starts a timed Mythic+ run it sends the
-- time remaining, keystone level and the enemy-forces GOAL; this addon then shows
-- a movable panel with:
--   * a countdown timer (green -> red when the timer expires),
--   * an enemy-forces bar that runs 0-100% of what you actually need to kill,
--   * a boss log with engage markers and kill splits.
--
-- Rides the player's personal channel like the other Uncapped addons, and
-- filters the UMS / UMT / UMR / UMB protocol lines out of chat.
--
-- Two things the server owns that this addon used to guess at, and must not
-- guess at again -- both were real bugs:
--
--   * The enemy-forces GOAL. The bar used to run 0-100% of the dungeon's whole
--     trash count with the completion mark at 70%, so players read "82%" as
--     "not done" when the run was long since complete, and a Scarlet Monastery
--     wing (whose gate counts only that wing) could read 35% on a finished key.
--     The server now sends the required kill count and this bar treats it as
--     100%. There is no client-side threshold any more.
--
--   * The TIME REMAINING. The countdown used to tick down the raw time limit
--     while the server was charging a death penalty against it, so runs failed
--     with time still showing. The server now sends remaining-after-penalty and
--     re-sends it on every death.

-- Defaults for every saved setting (persisted in UncappedMythicDB).
local DEFAULTS = {
    -- Report #207: 0 = AUTO, show every boss the run actually has.
    --
    -- This used to be a flat 6, which was not a frame-pool limit (the pool has
    -- always grown on demand) but a render limit: RefreshBossLog only ever drew
    -- rows 1..bossLines, so on any dungeon with more than six encounters the
    -- extras arrived from the server, were stored, and were then silently
    -- dropped on the floor with nothing on screen to say so. Reported from
    -- Scholomance, which has seven. Raising 6 to 8 would just move the cliff --
    -- Karazhan and Naxxramas have far more -- so the count now follows the run.
    bossLines     = 0,                   -- boss rows to show; 0 = auto (all of them)
    -- Migration marker, and it MUST default to false. Saved settings are merged
    -- over these defaults, and an existing user has no saved value for a key that
    -- did not exist before -- so if this defaulted to true the migration below
    -- would read "already done" on the very first login and never fire, leaving
    -- everyone on their saved 6. See the ADDON_LOADED handler.
    bossLinesAuto = false,
    scale         = 1.0,                 -- HUD frame scale
    pos           = nil,                 -- saved { point=, x=, y= } after dragging
    colComplete   = { 0.1, 0.8, 0.1 },   -- enemy-forces bar, goal reached
    colIncomplete = { 0.8, 0.5, 0.1 },   -- enemy-forces bar, not there yet
    colTimerNormal  = { 0.6, 1.0, 0.6 }, -- timer, plenty of time
    colTimerLast    = { 1.0, 0.8, 0.2 }, -- timer, final minute
    colTimerExpired = { 1.0, 0.2, 0.2 }, -- timer, over the limit
}

-- Live settings table. Starts as a copy of DEFAULTS so the HUD is valid before
-- ADDON_LOADED; saved values are merged in at load and the global points here.
local db = {}
for k, v in pairs(DEFAULTS) do
    if type(v) == "table" then
        local t = {}
        for i = 1, #v do t[i] = v[i] end
        db[k] = t
    else
        db[k] = v
    end
end

-- ---------------------------------------------------------------------------
-- Frame
-- ---------------------------------------------------------------------------
local frame = CreateFrame("Frame", "UncappedMythicFrame", UIParent)
frame:SetSize(240, 150)
frame:SetPoint("TOP", UIParent, "TOP", 0, -120)
frame:SetFrameStrata("MEDIUM")
frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
    tile = true, tileSize = 32, edgeSize = 24,
    insets = { left = 8, right = 8, top = 8, bottom = 8 },
})
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, _, x, y = self:GetPoint()
    db.pos = { point = point, x = x, y = y }
end)
frame:Hide()

-- Restore the saved HUD position, or fall back to the default anchor.
local function ApplyPosition()
    frame:ClearAllPoints()
    if db.pos then
        frame:SetPoint(db.pos.point, UIParent, db.pos.point, db.pos.x, db.pos.y)
    else
        frame:SetPoint("TOP", UIParent, "TOP", 0, -120)
    end
end

frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
frame.title:SetPoint("TOP", frame, "TOP", 0, -12)
frame.title:SetTextColor(1.0, 0.82, 0.0)

-- Big countdown timer.
frame.timer = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
frame.timer:SetPoint("TOP", frame.title, "BOTTOM", 0, -4)

-- Enemy-forces bar.
frame.bar = CreateFrame("StatusBar", nil, frame)
frame.bar:SetSize(200, 16)
frame.bar:SetPoint("TOP", frame.timer, "BOTTOM", 0, -6)
frame.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
frame.bar:SetMinMaxValues(0, 1)
frame.bar:SetValue(0)
frame.bar.bg = frame.bar:CreateTexture(nil, "BACKGROUND")
frame.bar.bg:SetAllPoints(frame.bar)
frame.bar.bg:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
frame.bar.bg:SetVertexColor(0.15, 0.15, 0.15, 0.8)

frame.barText = frame.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
frame.barText:SetPoint("CENTER", frame.bar, "CENTER", 0, 0)

-- Boss log rows.
frame.bossRows = {}
local function EnsureBossRow(i)
    if frame.bossRows[i] then return frame.bossRows[i] end
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", frame.bar, "BOTTOMLEFT", 0, -4 - (i - 1) * 14)
    fs:SetJustifyH("LEFT")
    fs:SetWidth(200)
    frame.bossRows[i] = fs
    return fs
end
for i = 1, db.bossLines do EnsureBossRow(i) end

-- ---------------------------------------------------------------------------
-- Run state
-- ---------------------------------------------------------------------------
local run = {
    active = false,
    timed = false,       -- dungeon keystone (has a countdown) vs untimed raid
    startTime = 0,       -- GetTime() when `limit` was last rebased by the server
    limit = 0,           -- seconds remaining as of startTime (penalty already taken off)
    level = 0,
    token = nil,         -- server run id; a resync carries the same one
    trashKilled = 0,
    trashNeeded = 0,     -- kills required to complete == the bar's 100%
    bosses = {},      -- ordered list of { name=, done=, split= }
    bossIndex = {},   -- name -> index into bosses
}

local function fmtTime(seconds)
    local neg = seconds < 0
    seconds = math.abs(math.floor(seconds))
    local m = math.floor(seconds / 60)
    local s = seconds - m * 60
    return string.format("%s%d:%02d", neg and "-" or "", m, s)
end

-- Report #207: how many boss rows this run should be drawing right now.
--
-- One definition, used by both the renderer and the frame sizer so they can
-- never disagree about how tall the log is. bossLines = 0 means auto: every boss
-- the run has. A non-zero value is an explicit user cap, for anyone who would
-- rather keep the HUD short on a long raid.
local function VisibleBossCount()
    local n = #run.bosses
    if db.bossLines and db.bossLines > 0 and db.bossLines < n then
        return db.bossLines
    end
    return n
end

local function ResizeFrame()
    local rows = VisibleBossCount()
    -- Plus the "... and N more" line RefreshBossLog adds when a user cap is
    -- hiding bosses, or the frame would clip its own overflow notice.
    if #run.bosses > rows then rows = rows + 1 end
    local base = run.timed and 96 or 72   -- no timer row on an untimed raid
    frame:SetHeight(base + rows * 14 + 12)
end

-- Only 5-man dungeon keystones run against the clock. Raids in the hotzone /
-- keystone system are untimed, so there's no countdown to show for them.
local function InRaidInstance()
    local _, itype = IsInInstance()
    return itype == "raid"
end

-- Show/hide the countdown and pull the enemy-forces bar up to fill its place.
local function ApplyTimerVisibility()
    frame.bar:ClearAllPoints()
    if run.timed then
        frame.timer:Show()
        frame.bar:SetPoint("TOP", frame.timer, "BOTTOM", 0, -6)
    else
        frame.timer:Hide()
        frame.bar:SetPoint("TOP", frame.title, "BOTTOM", 0, -6)
    end
end

local function RefreshBossLog()
    -- Report #207: draw exactly as many rows as this run needs, creating them on
    -- demand. EnsureBossRow has always been an unbounded lazy pool -- the only
    -- thing capping the log at six was this loop's upper bound.
    local shown = VisibleBossCount()
    for i = 1, shown do
        EnsureBossRow(i):Show()
        local b = run.bosses[i]
        if b then
            if b.done then
                -- Fight duration first, run split second and dimmer. A bare time
                -- beside a boss name reads as "how long that took", so the number
                -- in that position must be the one people assume it is; the split
                -- keeps its place for anyone actually tracking a run, in brackets
                -- where it cannot be mistaken for the fight length.
                if b.duration then
                    frame.bossRows[i]:SetText(string.format(
                        "|cff00ff00v|r %s  |cffaaaaaa%s|r |cff666666(@%s)|r",
                        b.name, fmtTime(b.duration), fmtTime(b.split)))
                else
                    -- Engage never seen, so no duration exists. Show the split
                    -- explicitly marked rather than unlabelled where a duration
                    -- would normally sit.
                    frame.bossRows[i]:SetText(string.format(
                        "|cff00ff00v|r %s  |cff666666(@%s)|r", b.name, fmtTime(b.split)))
                end
            else
                frame.bossRows[i]:SetText(string.format("|cffffcc00>|r %s", b.name))
            end
        else
            frame.bossRows[i]:SetText("")
        end
    end

    -- Anything the pool still holds beyond what this run needs (a previous,
    -- longer dungeon, or a user cap that was just lowered) is blanked and
    -- hidden rather than left showing a stale name.
    for i = shown + 1, #frame.bossRows do
        frame.bossRows[i]:SetText("")
        frame.bossRows[i]:Hide()
    end

    -- Report #207: say so when a user cap is hiding bosses, instead of the log
    -- just stopping. The old fixed 6 gave no indication at all that a seventh
    -- boss existed, which is why this was reported as the tracker being broken
    -- rather than as a setting.
    local total = #run.bosses
    if total > shown then
        local more = EnsureBossRow(shown + 1)
        more:Show()
        more:SetText(string.format("|cff808080... and %d more (raise the row limit)|r", total - shown))
    end

    ResizeFrame()
end

-- Grow/shrink the visible boss rows live when the count setting changes.
-- RefreshBossLog owns both the creation and the hiding now, so this only has to
-- record the new cap and repaint.
local function ApplyBossLines(n)
    db.bossLines = n
    RefreshBossLog()
end

-- The bar is 0-100% of what the run actually REQUIRES, not of the dungeon's
-- whole trash count. Kills past the goal are surplus and are not shown -- the
-- bar (and the count, and the percentage) all stop at the goal, so "100%" means
-- exactly "this part of the run is done" with no 70% notch to interpret.
local function RefreshBar()
    local needed = run.trashNeeded
    local shown = run.trashKilled
    if needed > 0 and shown > needed then shown = needed end

    local frac = 0
    if needed > 0 then
        frac = shown / needed
    end
    frame.bar:SetValue(frac)
    if frac >= 1 then
        local c = db.colComplete                     -- goal reached
        frame.bar:SetStatusBarColor(c[1], c[2], c[3])
    else
        local c = db.colIncomplete                   -- not yet
        frame.bar:SetStatusBarColor(c[1], c[2], c[3])
    end
    frame.barText:SetText(string.format("Enemy Forces  %d / %d  (%d%%)",
        shown, needed, math.floor(frac * 100 + 0.5)))
end

frame:SetScript("OnUpdate", function(self)
    if not run.active or not run.timed then return end
    local remaining = run.limit - (GetTime() - run.startTime)
    if remaining < 0 then remaining = 0 end   -- hold at 0:00, never wrap to negative
    self.timer:SetText(fmtTime(remaining))
    if remaining <= 0 then
        local c = db.colTimerExpired                 -- over the timer
        self.timer:SetTextColor(c[1], c[2], c[3])
    elseif remaining <= 60 then
        local c = db.colTimerLast                     -- last minute
        self.timer:SetTextColor(c[1], c[2], c[3])
    else
        local c = db.colTimerNormal
        self.timer:SetTextColor(c[1], c[2], c[3])
    end
end)

-- ---------------------------------------------------------------------------
-- Protocol
-- ---------------------------------------------------------------------------
-- `remaining` is seconds left with the death penalty already subtracted, and
-- `token` identifies the run. A message carrying the SAME token as the run we are
-- already showing is a resync -- a death, a reconnect, a re-entry after a
-- worldserver restart -- and must keep the boss log and kill count it has already
-- built. Only a different token is a new run and wipes them. Before the token
-- existed every resync cleared the boss log, so reconnecting mid-key showed an
-- empty boss list for a dungeon you were most of the way through.
local function StartRun(remaining, level, trashNeeded, token)
    local sameRun = (token ~= nil and run.token ~= nil and token == run.token)

    run.active = true
    -- Timed only for a real dungeon keystone with a limit; raids are untimed.
    run.timed = (remaining and remaining > 0) and not InRaidInstance()
    run.startTime = GetTime()
    run.limit = remaining
    run.level = level
    run.token = token
    run.trashNeeded = trashNeeded

    if not sameRun then
        run.trashKilled = 0
        run.bosses = {}
        run.bossIndex = {}
    end

    frame.title:SetText("Mythic+ Keystone +" .. level)
    ApplyTimerVisibility()
    RefreshBar()
    RefreshBossLog()
    frame:Show()
end

-- Timer-only resync (UMR). Rebases the countdown without touching the bar or
-- the boss log -- sent on every death, so the penalty shows up on the clock the
-- instant it is charged instead of only being felt when the run fails.
local function ResyncTimer(remaining)
    if not run.active then return end
    run.startTime = GetTime()
    run.limit = remaining
end

-- `engagedAt` is a local GetTime() stamp, not a server value.
--
-- The server sends a SPLIT with the kill -- seconds since the run began -- which
-- is the right thing for a splits board but is not how long the fight took. Those
-- read the same for the first boss and diverge badly by the last: a Black Temple
-- run on 2026-08-04 showed 54:58 against the Illidari Council for a fight that
-- lasted about fifty seconds, and it was reported as the timer being broken.
--
-- Timing it client-side needs no wire change and no server rebuild, and works on
-- untimed raids where there is no countdown to derive elapsed from. If the engage
-- was never seen -- addon loaded mid-fight, or a resync -- duration stays nil and
-- the row falls back to showing the split alone.
local function EngageBoss(name)
    if run.bossIndex[name] then return end
    table.insert(run.bosses, { name = name, done = false, split = 0, engagedAt = GetTime() })
    run.bossIndex[name] = #run.bosses
    RefreshBossLog()
end

local function KillBoss(name, split)
    local idx = run.bossIndex[name]
    if not idx then
        -- Kill without a preceding engage: nothing to measure from.
        table.insert(run.bosses, { name = name, done = true, split = split })
        run.bossIndex[name] = #run.bosses
    else
        local b = run.bosses[idx]
        b.done  = true
        b.split = split
        if b.engagedAt then
            b.duration = GetTime() - b.engagedAt
        end
    end
    RefreshBossLog()
end

local function UpdateTrash(killed, needed)
    run.trashKilled = killed
    run.trashNeeded = needed
    RefreshBar()
end

-- ---------------------------------------------------------------------------
-- Surviving /reload  (report #433)
-- ---------------------------------------------------------------------------
-- ★ THE SERVER CANNOT SEE A /reload. It fires no login and no map-enter hook, so
--   none of the three things that push run state (OnPlayerEnterAll, run start,
--   and a death's UMR) happen. The state push is event-driven, never periodic --
--   there is no heartbeat to wait for -- and the addon has no way to ask for one:
--   it sends the server nothing at all, and mod-mythic-plus registers no incoming
--   addon-message handler to answer with if it did.
--
-- ★ AND THE MESSAGES THAT DO KEEP ARRIVING CANNOT BRING THE HUD BACK. StartRun is
--   the only path with a frame:Show(); UMR early-returns on `not run.active`, and
--   UMT/UMB quietly accumulate into a frame nobody can see. So the HUD stayed
--   hidden for the rest of the key, and leaving and re-entering the instance was
--   the only recovery.
--
-- The fix is entirely client-side because the information never actually left the
-- client -- it was only being thrown away. `run` is rebuilt from defaults on load,
-- and is not in SavedVariables. Park a snapshot in the saved table on the way out
-- and put it back on the way in.
--
-- ★ THE SNAPSHOT MUST NOT SURVIVE A RELOG, only a reload, or a stale HUD would
--   appear on a run that has since ended. Two independent stamps say which one
--   happened, and both must agree:
--     GetTime() is monotonic within one client PROCESS and restarts near zero with
--       a new one, so a snapshot from a previous session reads as being in the
--       future and is refused.
--     time() is wall clock, which catches the rare fresh session that has already
--       been up longer than the saved GetTime().
--   A reload clears both in seconds; anything slower is treated as a new session
--   and the HUD waits for the server, exactly as it does today.
--
-- The timer needs no adjustment: run.startTime is a GetTime() stamp and GetTime()
-- does not restart across a reload, so the countdown resumes where it was.
local RUN_CACHE_MAX_AGE = 60

local function SnapshotRun()
    if not run.active then
        db.runCache = nil
        return
    end

    db.runCache = {
        savedAt     = GetTime(),
        savedAtReal = time(),
        run         = run,
    }
end

local function RestoreRun()
    local cache = db.runCache
    db.runCache = nil

    if type(cache) ~= "table" or type(cache.run) ~= "table" then return end
    if not IsInInstance() then return end

    local since = GetTime() - (cache.savedAt or 0)
    if since < 0 or since > RUN_CACHE_MAX_AGE then return end
    if (time() - (cache.savedAtReal or 0)) > RUN_CACHE_MAX_AGE then return end

    local saved = cache.run
    if not saved.active then return end

    run.active      = true
    run.timed       = saved.timed or false
    run.startTime   = saved.startTime or GetTime()
    run.limit       = saved.limit or 0
    run.level       = saved.level or 0
    run.token       = saved.token
    run.trashKilled = saved.trashKilled or 0
    run.trashNeeded = saved.trashNeeded or 0
    run.bosses      = saved.bosses or {}
    run.bossIndex   = saved.bossIndex or {}

    frame.title:SetText("Mythic+ Keystone +" .. run.level)
    ApplyTimerVisibility()
    RefreshBar()
    RefreshBossLog()
    frame:Show()
end

-- Hide the protocol lines from chat.
ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", function(self, event, msg)
    if msg and (msg:find("^UMS:") or msg:find("^UMT:") or msg:find("^UMR:") or msg:find("^UMB:")) then
        return true
    end
    return false
end)

-- Prefix for the whole server->client pipe (see the transport note below).
local ADDON_PIPE_PREFIX = "UNC"

local listener = CreateFrame("Frame")
listener:RegisterEvent("CHAT_MSG_CHANNEL")
listener:RegisterEvent("CHAT_MSG_ADDON")
listener:RegisterEvent("ADDON_LOADED")
listener:RegisterEvent("PLAYER_ENTERING_WORLD")
-- Both fire on /reload, and either one is early enough to park the run before the
-- saved variables are written -- see SnapshotRun (report #433). Both are taken
-- rather than one because the pair is not documented to fire in a fixed order, and
-- a snapshot written twice costs nothing.
listener:RegisterEvent("PLAYER_LEAVING_WORLD")
listener:RegisterEvent("PLAYER_LOGOUT")
listener:SetScript("OnEvent", function(self, event, a1, a2)
    if event == "ADDON_LOADED" then
        if a1 == "UncappedMythic" then
            -- Load saved settings (account-wide), filling any missing key from
            -- DEFAULTS, then point the global at our live table so edits persist.
            if type(UncappedMythicDB) == "table" then
                local s = UncappedMythicDB
                for k in pairs(DEFAULTS) do
                    if s[k] ~= nil then db[k] = s[k] end
                end
                -- [affix] Carry the affix sub-table across explicitly. It is not a
                -- DEFAULTS key, and DEFAULTS' table values are ARRAY-copied above
                -- (for i = 1, #v), which would flatten a string-keyed table to
                -- empty anyway. Without this the affix settings reset every login.
                if type(s.affix) == "table" then db.affix = s.affix end
                -- Same reason, for the in-flight run parked by SnapshotRun: it is
                -- not a DEFAULTS key, so the merge above would drop it and the
                -- reload it exists to survive would still blank the HUD (#433).
                if type(s.runCache) == "table" then db.runCache = s.runCache end
            end
            -- Report #207: one-time migration off the old fixed 6.
            --
            -- Changing the DEFAULT to auto does nothing for anyone who has
            -- already logged in once: their saved 6 is merged back in above and
            -- keeps truncating Scholomance exactly as before. Everyone still
            -- sitting on the stale default is moved to auto once, and the marker
            -- means someone who deliberately picks 6 afterwards keeps it.
            if not db.bossLinesAuto then
                db.bossLinesAuto = true
                if db.bossLines == 6 then db.bossLines = 0 end
            end

            UncappedMythicDB = db
            frame:SetScale(db.scale)
            ApplyPosition()
            ApplyBossLines(db.bossLines)
            -- Affix settings load from the SAME db table, so it has to happen after
            -- the line above has finished rebuilding it -- hence a direct call
            -- rather than a second ADDON_LOADED handler racing this one.
            if UncappedMythicAffixLoad then UncappedMythicAffixLoad() end
            if UncappedMythicRefresh then UncappedMythicRefresh() end
            JoinChannelByName(UnitName("player"))
        end
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        -- Left the instance -> the run is over for this client; put the HUD away.
        if run.active and not IsInInstance() then
            run.active = false
            frame:Hide()
        elseif not run.active then
            -- A /reload arrives here with `run` freshly rebuilt from defaults and
            -- nothing on the wire that could ever refill it. RestoreRun self-guards
            -- on being in an instance and on the snapshot being from this session,
            -- and clears the snapshot either way (report #433).
            RestoreRun()
        end
        return
    end

    if event == "PLAYER_LEAVING_WORLD" or event == "PLAYER_LOGOUT" then
        SnapshotRun()
        return
    end

    -- Two transports, on purpose.
    --
    -- CHAT_MSG_ADDON is where the pipe is moving: the client never renders it,
    -- so the protocol can no longer leak into chat when an addon fails to load.
    -- CHAT_MSG_CHANNEL is the old transport, kept because one payload serves
    -- both realms and a realm still running the previous worldserver would go
    -- silent otherwise. Drop the channel branch once every realm is converted.
    --
    --   CHAT_MSG_ADDON   : a1 = prefix, a2 = body
    --   CHAT_MSG_CHANNEL : a1 = body,   a2 = author (our own name on the pipe)
    local msg
    if event == "CHAT_MSG_ADDON" then
        if a1 ~= ADDON_PIPE_PREFIX then return end
        msg = a2
    else
        if a2 ~= UnitName("player") then return end
        msg = a1
    end
    if not msg then
        return
    end

    -- UMS:<remainingSec>:<level>:<requiredKills>:<runToken>
    local remaining, level, needed, token = msg:match("^UMS:(%d+):(%d+):(%d+):(%d+)$")
    if remaining then
        StartRun(tonumber(remaining), tonumber(level), tonumber(needed), tonumber(token))
        return
    end

    -- Older 3-field form (a realm still on the previous worldserver). No run
    -- token, so every one of these is treated as a fresh run.
    local oldLimit, oldLevel, oldTotal = msg:match("^UMS:(%d+):(%d+):(%d+)$")
    if oldLimit then
        StartRun(tonumber(oldLimit), tonumber(oldLevel), tonumber(oldTotal), nil)
        return
    end

    -- UMR:<remainingSec> -- timer rebase only (death penalty applied).
    local resync = msg:match("^UMR:(%d+)$")
    if resync then
        ResyncTimer(tonumber(resync))
        return
    end

    -- UMT:<killed>:<requiredKills>
    local killed, needKills = msg:match("^UMT:(%d+):(%d+)$")
    if killed then
        UpdateTrash(tonumber(killed), tonumber(needKills))
        return
    end

    -- UMB:e:<name>  (engage)   or   UMB:k:<name>:<seconds>  (kill)
    local ename = msg:match("^UMB:e:(.+)$")
    if ename then
        EngageBoss(ename)
        return
    end
    local kname, ksplit = msg:match("^UMB:k:(.+):(%d+)$")
    if kname then
        KillBoss(kname, tonumber(ksplit))
        return
    end
end)

-- ---------------------------------------------------------------------------
-- Settings page (ESC > Interface > AddOns > Uncapped > Mythic+ HUD)
-- ---------------------------------------------------------------------------
if UncappedUI then
    local refreshers = {}
    local function track(w)
        refreshers[#refreshers + 1] = w.uncappedRefresh
        return w
    end

    -- Colour helpers: DB stores { r, g, b }; the widget wants get()->r,g,b / set(r,g,b).
    local function colGet(key)
        return function() local c = db[key]; return c[1], c[2], c[3] end
    end
    local function colSet(key, apply)
        return function(r, g, b) db[key] = { r, g, b }; if apply then apply() end end
    end

    local panel, L = UncappedUI.CreatePanel("Mythic+ HUD",
        "The keystone-run HUD: countdown timer, enemy-forces bar and boss splits.")

    L:Header("Layout")
    -- Report #207: 0 is AUTO and is the default -- the log grows to fit whatever
    -- the dungeon has. The slider is now a cap for anyone who wants the HUD kept
    -- short, not the thing that decides how many bosses exist. Top end raised to
    -- 20 so an explicit cap can still cover the longest raid.
    track(L:Slider("Boss log rows (0 = auto, fit the dungeon)", 0, 20, 1,
        function() return db.bossLines end,
        function(v) ApplyBossLines(v) end, "%d"))
    track(L:Slider("HUD scale", 0.5, 2.0, 0.05,
        function() return db.scale end,
        function(v) db.scale = v; frame:SetScale(v) end, "%.2f"))
    L:Button("Reset HUD position", function() db.pos = nil; ApplyPosition() end, 180)

    L:Gap(6)
    L:Header("Enemy forces")
    L:Note("|cff808080The bar runs 0-100% of what the run requires -- 100% means done. The goal comes from the server, so there is nothing to configure here.|r", 32)
    track(L:Color("Enemy-forces complete colour",   colGet("colComplete"),   colSet("colComplete", RefreshBar)))
    track(L:Color("Enemy-forces incomplete colour", colGet("colIncomplete"), colSet("colIncomplete", RefreshBar)))

    L:Gap(6)
    L:Header("Timer")
    track(L:Color("Timer normal colour",      colGet("colTimerNormal"),  colSet("colTimerNormal")))
    track(L:Color("Timer last-minute colour", colGet("colTimerLast"),    colSet("colTimerLast")))
    track(L:Color("Timer expired colour",     colGet("colTimerExpired"), colSet("colTimerExpired")))

    L:Gap(6)
    L:Note("|cff808080Colours, scale and boss-row count update the HUD live; the saved HUD position restores on login. Use /mplus test to preview.|r", 40)

    UncappedMythicPanel = panel
    function UncappedMythicRefresh()
        for _, r in ipairs(refreshers) do r() end
    end
end

-- ---------------------------------------------------------------------------
-- Slash: toggle / test / config
-- ---------------------------------------------------------------------------
SLASH_UNCAPPEDMYTHIC1 = "/mplus"
SlashCmdList["UNCAPPEDMYTHIC"] = function(arg)
    if arg == "config" or arg == "options" then
        if UncappedUI and UncappedMythicPanel then
            UncappedUI.Open(UncappedMythicPanel)
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Uncapped Mythic+|r: settings page unavailable (UncappedOptions not loaded).")
        end
        return
    end
    if arg == "test" then
        -- 84 required (70% of a 120-mob dungeon); 61 killed -> ~73% of the goal.
        StartRun(1800, 7, 84, 1)
        EngageBoss("Rhahk'Zor")
        KillBoss("Rhahk'Zor", 74)
        UpdateTrash(61, 84)
        EngageBoss("Mr. Smite")
        return
    end
    if arg == "testdeath" then
        -- Same run token -> a resync: the boss log and bar must survive, only the
        -- clock moves (this is what a death now does).
        StartRun(1800, 7, 84, 1)
        EngageBoss("Rhahk'Zor")
        KillBoss("Rhahk'Zor", 74)
        UpdateTrash(61, 84)
        ResyncTimer(1650)
        DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Uncapped Mythic+|r: timer resynced to 27:30 -- boss log should be intact.")
        return
    end
    if arg == "testraid" then
        StartRun(0, 3, 140, 2)   -- limit 0 -> untimed run, previews the no-timer raid HUD
        EngageBoss("Magtheridon")
        UpdateTrash(140, 140)
        return
    end
    if frame:IsShown() then
        frame:Hide()
    elseif run.active then
        frame:Show()
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Uncapped Mythic+|r: no active keystone run.")
    end
end

-- ===========================================================================
-- AFFIX STRIP + ANNOUNCEMENTS
-- ===========================================================================
--
-- Lives in THIS file rather than its own on purpose. A .lua added to the .toc
-- is only picked up when the client next launches -- /reload re-runs the files
-- the client already knows about, so a new file silently does nothing until a
-- full restart. Keeping it here means /reload is enough to iterate on it.
--
-- Two pieces:
--
--   * A strip of affix icons hanging under the keystone HUD. Hover one for its
--     name and what it actually does to you.
--   * An announcement: a card appears centre-screen with the affix name, plays a
--     voice line, then shrinks and flies into its slot on the strip -- so the
--     thing you just heard visibly becomes the icon you'll be reading for the
--     rest of the run.
--
-- The strip anchors OUTSIDE the HUD's bottom edge, so the layout maths in
-- ResizeFrame (tuned around the timer, bar and boss rows) did not have to
-- change. It is still a CHILD of the frame, so it inherits show/hide, scale
-- and dragging for free.
--
-- Voice lines are Diablo III hero barks, extracted per docs/ops/CASC_ASSET_EXTRACTION.md
-- and converted to .wav -- 3.3.5a's PlaySoundFile does NOT accept .ogg (GTFO ships
-- .wav for exactly this reason). Each affix is NAMED after its line, which is why
-- they read the way they do.

local HUD = frame   -- the HUD frame created at the top of this file

local SOUND_DIR = "Interface\\AddOns\\UncappedMythic\\Sounds\\"
local ICON_DIR  = "Interface\\Icons\\"

-- Animation beats, seconds. HOLD is sized to the longest voice line (~2.6s) so a
-- clip is never cut off by the card leaving; the shortest ("Vengeance!", 1.07s)
-- simply finishes early and the card sits a moment longer. Driving the card off a
-- fixed beat rather than clip length keeps every affix feeling the same weight.
local GROW, HOLD, FLY = 0.25, 1.70, 0.55

-- ---------------------------------------------------------------------------
-- Catalogue
-- ---------------------------------------------------------------------------
-- Named after the voice line each one carries. `tag` is the spoken words, shown
-- on the card and in the tooltip so the audio and the text agree.
--
-- Icon paths are cosmetic: 3.3.5a renders a missing texture as blank rather than
-- erroring, so a wrong name costs an empty square and nothing else. These are
-- WotLK-era names (mostly Death Knight, which shipped with 3.0) but they are not
-- verified against the client's MPQ -- if any square is blank, that's why.
local AFFIX = {
    decay = {
        name = "Decay",
        tag  = "Decay and rot!",
        desc = "Enemies leave pools of acid beneath whoever they are attacking.\nStanding in one stacks a rot that keeps eating after you leave.",
        counter = "Move out. The pool grows -- it does not follow.",
        icon = "Spell_Shadow_DeathAndDecay", sound = "decay",
        color = { 0.55, 0.85, 0.30 },
    },
    finecorpse = {
        name = "Fine Corpses",
        tag  = "You will make a fine corpse.",
        desc = "Slain enemies detonate a few seconds after they fall, marking the\nground first. Anyone still standing there is left at 1% health and\nlaunched skyward -- and the fall will finish the job.",
        counter = "Step off the corpse. Caught anyway, the airtime is yours --\ninstant heal, Divine Shield, or a potion before you land.",
        icon = "Spell_Shadow_AnimateDead", sound = "finecorpse",
        color = { 0.90, 0.45, 0.15 },
    },
    thecycle = {
        name = "The Cycle",
        tag  = "All must serve the Cycle.",
        desc = "Trash enemies split in two when they die, at reduced health and\ndamage. The halves can split once more.",
        counter = "Pull smaller. Save your AoE for the second wave.",
        icon = "Spell_Shadow_RaiseDead", sound = "thecycle",
        color = { 0.65, 0.40, 0.85 },
    },
    endlesstide = {
        name = "Endless Tide",
        tag  = "Break beneath the endless tide!",
        desc = "Stone falls without end. A patch of ground is marked near you,\nand four seconds later it collapses for 80% of your health.",
        counter = "Walk out of the marked ground. Four seconds is plenty --\nif you are looking down.",
        icon = "Spell_Nature_Earthquake", sound = "endlesstide",
        color = { 0.40, 0.70, 0.95 },
    },
    bloodletting = {
        name = "Bloodletting",
        tag  = "Bleed, you filth!",
        desc = "Every enemy you kill opens a wound. You bleed for 5% of your\nmaximum health over 5 seconds, and each kill adds another.",
        counter = "Stagger your kills instead of cleaving a whole pack down at once.",
        icon = "Ability_Rogue_Rupture", sound = "bloodletting",
        color = { 0.85, 0.15, 0.20 },
    },
    vengeance = {
        name = "Vengeance",
        tag  = "Vengeance!",
        desc = "Each slain enemy sends a fast shade after one player. It cannot be\ntanked and it will not stop.",
        counter = "Kite it, root it, or burst it down. It leaves on its own.",
        icon = "Ability_Warrior_Revenge", sound = "vengeance",
        color = { 0.95, 0.80, 0.25 },
    },
    weakenedflesh = {
        name = "Weakened Flesh",
        tag  = "Your flesh is weak!",
        desc = "Taking damage sears the wound shut. For 4 seconds afterwards you\nreceive 90% less healing from every source.",
        counter = "You will not be healed through this -- break contact, or\nmitigate instead of leaning on the healer.",
        icon = "Spell_Shadow_UnholyFrenzy", sound = "weakenedflesh",
        color = { 0.70, 0.75, 0.55 },
    },
    sundered = {
        name = "Sundered",
        tag  = "Your defenses are nothing!",
        desc = "Every enemy that dies makes its surviving allies hit harder and\nheals them, stacking.",
        counter = "Bring the pack down evenly and finish it together.",
        icon = "Ability_Warrior_Sunder", sound = "sundered",
        color = { 0.95, 0.55, 0.35 },
    },
    hubris = {
        name = "Hubris",
        tag  = "I am so good I astound myself.",
        desc = "Showing off pays. Your damage climbs for every second you stand\nperfectly still, and collapses the instant you move.",
        counter = "None needed -- this one is a temptation, not a threat. Every\nother affix in the run wants you moving.",
        icon = "Ability_Warrior_InnerRage", sound = "hubris",
        color = { 0.95, 0.90, 0.60 },
    },
    -- The five below draw their voice line from D_Hero_Taunt rather than CriticalHit,
    -- so they are a different set of speakers from the first ten. Wording confirmed by
    -- ear 2026-07-30 and checked against Conv_Hero_Taunt.stl.
    wardingorbs = {
        name = "Warding Orbs",
        tag  = "Are you bent on self-destruction?",   -- Taunt 0053
        desc = "An unstable orb forms near a player in combat and lights up at once.\nSix seconds later it detonates for 30-40% of the health of anyone\nwithin 15 yards who can see it.",
        counter = "Destroy it. Any spec can, in a cast or two -- and killing it\nmeans nothing happens at all.",
        icon = "Spell_Nature_WispSplode", sound = "wardingorbs",
        color = { 0.45, 0.80, 0.95 },
    },
    duplicate = {
        name = "Twinned",
        tag  = "The darkness in you cannot match what's within me.",   -- Taunt 0144
        desc = "Some trash enemies arrive alongside a duplicate of themselves.",
        counter = "Nothing to dodge -- the pack is simply bigger than it looks.\nPull accordingly.",
        icon = "Spell_Magic_LesserInvisibilty", sound = "duplicate",
        color = { 0.70, 0.70, 0.80 },
    },
    cursed = {
        name = "Cursed",
        tag  = "Your blood will fall like rain.",   -- Taunt 0067
        desc = "A curse lands on a random player and detonates 8 seconds later,\nhitting the whole group.",
        counter = "Cleanse it. With nobody who can, it falls off on its own after\n3 seconds of taking no damage.",
        icon = "Spell_Shadow_CurseOfSargeras", sound = "cursed",
        color = { 0.60, 0.30, 0.70 },
    },
    frenzy = {
        name = "Frenzy",
        tag  = "You're almost not worth it.",   -- Taunt 0099
        desc = "Past 60% of the run timer, bosses gain stacking haste and damage\nfor the rest of the fight.",
        counter = "A kill window, not a healing check. Hold burst for it.",
        icon = "Ability_Racial_BloodRage", sound = "frenzy",
        color = { 0.95, 0.30, 0.20 },
    },
    bulwark = {
        name = "Bulwark",
        tag  = "I am too much for you.",   -- Taunt 0091
        desc = "Bosses periodically shield themselves for 5% of their maximum\nhealth. Fail to break it within 8 seconds and they heal that much.",
        counter = "Burst the shield down. This is a damage check on a timer.",
        icon = "Spell_Holy_PowerWordShield", sound = "bulwark",
        color = { 0.85, 0.85, 0.45 },
    },
    storm = {
        name = "Storm",
        tag  = "The storm breaks!",
        desc = "Lightning marks a player, then strikes three seconds later.\nAnyone else within 8 yards is chained for 60% as much.",
        counter = "Spread. You get the three seconds the mark is on you -- use them.",
        icon = "Spell_Nature_Lightning", sound = "storm",
        color = { 0.55, 0.75, 1.00 },
    },
}

-- Fixed display order, so the strip never reshuffles between runs.
-- Fixed display order, so the strip never reshuffles between runs. Roughly grouped:
-- environmental hazards, then debuffs, then death-triggered, then boss-only.
local ORDER = {
    "endlesstide", "storm", "wardingorbs",
    "sundered", "weakenedflesh", "cursed",
    "bloodletting", "decay", "finecorpse", "thecycle", "duplicate", "vengeance",
    "frenzy", "bulwark", "hubris",
}

-- Hard cap on simultaneous affixes. Three is a set you can hold in your head and
-- plan around; more becomes noise, and the intro that introduces them has to fit in
-- the opening freeze (3 x 2.85s of animation = 8.55s, inside a 10s window).
-- Enforced here as a backstop -- the server also has to respect it, because the
-- affix count comes from the DB and a config mistake must not be able to exceed it.
local MAX_ACTIVE = 3

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
local cfg = { sound = true, animate = true, strip = true }

-- ---------------------------------------------------------------------------
-- The strip
-- ---------------------------------------------------------------------------
local strip = CreateFrame("Frame", "UncappedMythicAffixStrip", HUD)
strip:SetPoint("TOP", HUD, "BOTTOM", 0, -2)
strip:SetSize(200, 30)
strip:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
    tile = true, tileSize = 32, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})

strip.empty = strip:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
strip.empty:SetPoint("CENTER", strip, "CENTER", 0, 0)
strip.empty:SetText("No affixes")

local active = {}      -- ordered list of affix keys currently in play
local slots = {}       -- reusable icon buttons

local function EnsureSlot(i)
    if slots[i] then return slots[i] end
    local b = CreateFrame("Button", nil, strip)
    b:SetSize(22, 22)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints(b)
    b.border = b:CreateTexture(nil, "OVERLAY")
    b.border:SetPoint("TOPLEFT", b, "TOPLEFT", -1, 1)
    b.border:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 1, -1)
    b.border:SetTexture("Interface\\Buttons\\WHITE8X8")
    b.border:SetDrawLayer("BACKGROUND")
    b:SetScript("OnEnter", function(self)
        local a = AFFIX[self.affixKey]
        if not a then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(a.name, a.color[1], a.color[2], a.color[3])
        -- `tag` is the spoken words. Some affixes have a clip whose exact wording is
        -- not transcribed yet; show nothing rather than a guess.
        if a.tag and a.tag ~= "" then
            GameTooltip:AddLine('"' .. a.tag .. '"', 0.6, 0.6, 0.6, true)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(a.desc, 1, 1, 1, true)
        if a.counter then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Counterplay: " .. a.counter, 0.4, 0.9, 0.4, true)
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- Clicking an icon replays that affix's announcement -- the quickest way to
    -- hear a line again without going through the settings page.
    b:SetScript("OnClick", function(self)
        if self.affixKey then UncappedMythicAffix_Announce(self.affixKey, true) end
    end)
    slots[i] = b
    return b
end

-- Preview button, pinned to the right end of the strip.
local preview = CreateFrame("Button", nil, strip)
preview:SetSize(18, 18)
preview:SetPoint("RIGHT", strip, "RIGHT", -6, 0)
preview.tex = preview:CreateTexture(nil, "ARTWORK")
preview.tex:SetAllPoints(preview)
preview.tex:SetTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
preview:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Preview announcements", 1, 0.82, 0)
    GameTooltip:AddLine("Plays the intro for every affix in this run, in order.\nWith no run active, previews all of them.", 1, 1, 1, true)
    GameTooltip:Show()
end)
preview:SetScript("OnLeave", function() GameTooltip:Hide() end)
preview:SetScript("OnClick", function() UncappedMythicAffix_Preview() end)

local function LayoutStrip()
    local n = #active
    for i = 1, math.max(n, #slots) do
        local b = slots[i]
        if i <= n then
            b = EnsureSlot(i)
            local a = AFFIX[active[i]]
            b.affixKey = active[i]
            b.icon:SetTexture(ICON_DIR .. a.icon)
            -- Reset alpha explicitly: an announcement dims its destination icon and
            -- only restores it on landing, so an interrupted one must not leave the
            -- slot permanently dimmed.
            b.icon:SetAlpha(1)
            b.border:SetVertexColor(a.color[1], a.color[2], a.color[3], 0.9)
            b:ClearAllPoints()
            b:SetPoint("LEFT", strip, "LEFT", 8 + (i - 1) * 26, 0)
            b:Show()
        elseif b then
            b:Hide()
        end
    end
    -- No SetShown in 3.3.5a -- that is a later addition, so show/hide explicitly.
    if n == 0 then strip.empty:Show() else strip.empty:Hide() end
    -- Width tracks the icon count plus room for the preview button.
    strip:SetWidth(math.max(200, 8 + n * 26 + 34))
    if cfg.strip then strip:Show() else strip:Hide() end
end

-- ---------------------------------------------------------------------------
-- The announcement card
-- ---------------------------------------------------------------------------
local card = CreateFrame("Frame", "UncappedMythicAffixCard", UIParent)
card:SetSize(340, 92)
card:SetFrameStrata("DIALOG")
card:SetPoint("CENTER", UIParent, "CENTER", 0, 140)
card:Hide()
card:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
    tile = true, tileSize = 32, edgeSize = 26,
    insets = { left = 9, right = 9, top = 9, bottom = 9 },
})

card.icon = card:CreateTexture(nil, "ARTWORK")
card.icon:SetSize(46, 46)
card.icon:SetPoint("LEFT", card, "LEFT", 18, 0)

card.kicker = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
card.kicker:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 12, -1)
card.kicker:SetText("AFFIX")
card.kicker:SetTextColor(0.65, 0.60, 0.50)

card.name = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
card.name:SetPoint("TOPLEFT", card.kicker, "BOTTOMLEFT", 0, -1)

card.tag = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
card.tag:SetPoint("TOPLEFT", card.name, "BOTTOMLEFT", 0, -3)
card.tag:SetWidth(230)
card.tag:SetJustifyH("LEFT")
card.tag:SetTextColor(0.72, 0.68, 0.58)

-- Offset of a frame's centre from UIParent's centre, in UIParent units.
-- Both frames can sit at different effective scales (the HUD is user-scalable),
-- so normalise through effective scale or the card lands short of the strip.
-- A frame's centre in UIParent coordinate units, measured from UIParent's
-- BOTTOM-LEFT. GetCenter() reports in the frame's own scale, so convert up to real
-- pixels and back down into UIParent units -- the HUD is user-scalable, so its
-- scale and UIParent's are usually different.
local function CenterInUIParent(f)
    if not f then return nil end
    local x, y = f:GetCenter()
    if not x then return nil end
    -- TEXTURES ARE NOT FRAMES. card.icon and slot.icon are LayoutFrames: they have
    -- GetCenter() but GetEffectiveScale() only exists on Frame, so calling it on a
    -- texture errors -- and because that threw from inside OnUpdate it aborted the
    -- handler before the phase advanced, so it re-threw every single frame (1026
    -- errors in one demo). Read the scale off the nearest Frame instead.
    local scaler = f.GetEffectiveScale and f or f:GetParent()
    if not scaler or not scaler.GetEffectiveScale then return nil end
    local s = scaler:GetEffectiveScale() / UIParent:GetEffectiveScale()
    return x * s, y * s
end

-- The flying icon.
--
-- This is a SEPARATE frame from the card, and it animates with SetSize rather than
-- SetScale, for one reason that cost a rewrite: **a frame's SetPoint offsets are
-- expressed in that frame's own scale units.** Shrinking the card with SetScale
-- therefore shrank its anchor offsets too, dragging it back toward UIParent's
-- centre instead of out to the strip -- which looked like the card sliding
-- sideways and fading out mid-screen. SetSize leaves the anchor maths alone, so
-- the flyer goes exactly where it is told and arrives at icon size.
local flyer = CreateFrame("Frame", nil, UIParent)
flyer:SetFrameStrata("TOOLTIP")
flyer:SetSize(46, 46)
flyer:Hide()
flyer.icon = flyer:CreateTexture(nil, "ARTWORK")
flyer.icon:SetAllPoints(flyer)
flyer.ring = flyer:CreateTexture(nil, "BACKGROUND")
flyer.ring:SetPoint("TOPLEFT", flyer, "TOPLEFT", -2, 2)
flyer.ring:SetPoint("BOTTOMRIGHT", flyer, "BOTTOMRIGHT", 2, -2)
flyer.ring:SetTexture("Interface\\Buttons\\WHITE8X8")

-- ---------------------------------------------------------------------------
-- The opening freeze
-- ---------------------------------------------------------------------------
-- The server roots everyone for a few seconds at run start so the affix intro can
-- play before anyone pulls. It has to be the server that freezes: movement is
-- server-authoritative and an addon cannot hold a player in place. All this frame
-- does is explain the pause, so nobody reads a frozen character as a bug.
local intro = CreateFrame("Frame", nil, UIParent)
intro:SetSize(360, 46)
intro:SetPoint("CENTER", UIParent, "CENTER", 0, 28)
intro:SetFrameStrata("DIALOG")
intro:Hide()

intro.label = intro:CreateFontString(nil, "OVERLAY", "GameFontNormal")
intro.label:SetPoint("TOP", intro, "TOP", 0, 0)
intro.label:SetText("Affixes for this run")
intro.label:SetTextColor(0.70, 0.65, 0.55)

intro.count = intro:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
intro.count:SetPoint("TOP", intro.label, "BOTTOM", 0, -2)

local introEnd = nil        -- GetTime() the freeze lifts, or nil

local CARD_Y = 140          -- card's resting height above screen centre, UIParent units
local FLY_END_SIZE = 22     -- matches a strip slot
local LAND = 0.35           -- settle flash

-- Keep the card visually pinned while it scales. Offsets are in the card's own
-- scale units, so they have to be divided by the scale or the card drifts upward
-- as it grows.
local function PlaceCard(scale)
    card:SetScale(scale)
    card:ClearAllPoints()
    card:SetPoint("CENTER", UIParent, "CENTER", 0, CARD_Y / scale)
end

local queue = {}
local anim = nil

local function BeginNext()
    if anim or #queue == 0 then return end
    local key = table.remove(queue, 1)
    local a = AFFIX[key]
    if not a then return end

    card.icon:SetTexture(ICON_DIR .. a.icon)
    card.name:SetText(a.name)
    card.name:SetTextColor(a.color[1], a.color[2], a.color[3])
    card.tag:SetText((a.tag and a.tag ~= "") and ('"' .. a.tag .. '"') or "")
    card:SetBackdropBorderColor(a.color[1], a.color[2], a.color[3])

    -- Target the slot this affix will occupy, so the card flies to where its icon
    -- actually ends up. Falls back to the strip itself when the affix is not in
    -- the active set (previewing with no run).
    local target = strip
    for i, k in ipairs(active) do
        if k == key and slots[i] then target = slots[i] end
    end

    anim = { key = key, t = 0, phase = "grow", target = target, color = a.color }
    -- Dim the destination icon for the duration. The strip icon already exists by
    -- the time an announcement plays, so without this the flyer lands on top of an
    -- identical icon and vanishing reads as nothing happening. Dimmed, the arrival
    -- is what lights it up.
    if target and target.icon then target.icon:SetAlpha(0.25) end
    card:SetAlpha(0)
    PlaceCard(0.7)
    card:Show()

    if cfg.sound then PlaySoundFile(SOUND_DIR .. a.sound .. ".wav") end
end

-- The animation is driven by its own always-shown, contentless frame, NOT by the
-- card: a hidden frame's OnUpdate does not run in this client, and the card gets
-- hidden the moment the flyer takes over. Driving from the card meant the fly and
-- land phases never ticked at all.
local driver = CreateFrame("Frame", nil, UIParent)
driver:SetSize(1, 1)
driver:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)

driver:SetScript("OnUpdate", function(_, elapsed)
    -- Countdown first, and outside the `anim` guard: the freeze outlasts the last
    -- announcement by a second or so, so it has to keep ticking after the queue
    -- drains or the number would freeze on screen while the player still cannot move.
    if introEnd then
        local left = introEnd - GetTime()
        if left > 0 then
            intro.count:SetText(string.format("%.0f", math.ceil(left)))
            -- Amber, going red over the last two seconds.
            if left <= 2 then
                intro.count:SetTextColor(1.0, 0.35, 0.25)
            else
                intro.count:SetTextColor(1.0, 0.82, 0.0)
            end
        else
            introEnd = nil
            intro:Hide()
        end
    end

    if not anim then return end
    anim.t = anim.t + elapsed

    if anim.phase == "grow" then
        local p = math.min(anim.t / GROW, 1)
        card:SetAlpha(p)
        PlaceCard(0.7 + 0.3 * p)
        if p >= 1 then anim.phase, anim.t = "hold", 0 end

    elseif anim.phase == "hold" then
        card:SetAlpha(1)
        PlaceCard(1)
        if anim.t >= HOLD then
            -- Hand off to the flyer. Both endpoints are captured NOW: the strip has
            -- finished laying out, so the slot's position is final, and the card is
            -- about to be hidden so its icon's position must be read first.
            local sx, sy = CenterInUIParent(card.icon)
            local tx, ty = CenterInUIParent(anim.target)
            if sx and tx then
                anim.sx, anim.sy, anim.tx, anim.ty = sx, sy, tx, ty
                flyer.icon:SetTexture(card.icon:GetTexture())
                local c = anim.color
                flyer.ring:SetVertexColor(c[1], c[2], c[3], 0.9)
                flyer:SetSize(46, 46)
                flyer:ClearAllPoints()
                flyer:SetPoint("CENTER", UIParent, "BOTTOMLEFT", sx, sy)
                flyer:SetAlpha(1)
                flyer:Show()
                anim.phase, anim.t = "fly", 0
            else
                -- No usable target (strip hidden, or laid out after this fired).
                -- Skip the flight rather than animate to a garbage coordinate.
                anim.phase, anim.t = "done", 0
            end
            card:Hide()
        end

    elseif anim.phase == "fly" then
        local p = math.min(anim.t / FLY, 1)
        local e = p * p * (3 - 2 * p)               -- smoothstep
        local x = anim.sx + (anim.tx - anim.sx) * e
        local y = anim.sy + (anim.ty - anim.sy) * e
        local size = 46 + (FLY_END_SIZE - 46) * e
        flyer:ClearAllPoints()
        flyer:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
        flyer:SetSize(size, size)
        if p >= 1 then
            flyer:Hide()
            anim.phase, anim.t = "land", 0
        end

    elseif anim.phase == "land" then
        -- Settle: flash the slot's border white and ease it back to the affix
        -- colour, so the icon that just arrived is the one your eye lands on.
        local p = math.min(anim.t / LAND, 1)
        local c = anim.color
        local slot = anim.target
        if slot then
            if slot.border then
                local w = 1 - p          -- white at impact, easing to the affix colour
                slot.border:SetVertexColor(c[1] + (1 - c[1]) * w,
                                           c[2] + (1 - c[2]) * w,
                                           c[3] + (1 - c[3]) * w, 0.9)
            end
            if slot.icon then slot.icon:SetAlpha(0.25 + 0.75 * p) end
        end
        if p >= 1 then anim.phase = "done" end

    elseif anim.phase == "done" then
        card:Hide()
        card:SetAlpha(1)
        -- Never leave a slot dimmed, including when the flight was skipped for a
        -- missing target.
        if anim.target and anim.target.icon then anim.target.icon:SetAlpha(1) end
        anim = nil
        BeginNext()
    end
end)

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------
-- Queue one affix's announcement. `force` skips the animation setting so the
-- preview button and icon clicks always do something visible.
function UncappedMythicAffix_Announce(key, force)
    if not AFFIX[key] then return end
    if not cfg.animate and not force then
        if cfg.sound then PlaySoundFile(SOUND_DIR .. AFFIX[key].sound .. ".wav") end
        return
    end
    queue[#queue + 1] = key
    BeginNext()
end

-- Replace the run's affix set. Announces only what is NEW, so a mid-run resync
-- (reconnect, death, worldserver restart) re-sends the same list without
-- replaying nine voice lines at someone.
function UncappedMythicAffix_SetActive(keys, announce)
    local was = {}
    for _, k in ipairs(active) do was[k] = true end

    active = {}
    local want = {}
    for _, k in ipairs(keys) do
        if AFFIX[k] then want[k] = true end
    end
    for _, k in ipairs(ORDER) do
        if want[k] and #active < MAX_ACTIVE then active[#active + 1] = k end
    end
    LayoutStrip()

    if announce then
        for _, k in ipairs(active) do
            if not was[k] then UncappedMythicAffix_Announce(k) end
        end
    end
end

function UncappedMythicAffix_Clear()
    active = {}
    LayoutStrip()
end

-- The strip is a child of the HUD, so previewing outside a run needs the HUD up.
-- StartRun is local to UncappedMythic.lua and deliberately not reached into here;
-- the frame and its title are globals, which is enough to make the demo not look
-- like a blank panel.
local function ShowHudForDemo()
    if not HUD:IsShown() then HUD:Show() end
    local t = HUD.title and HUD.title:GetText()
    if not t or t == "" then
        HUD.title:SetText("Mythic+ Affix Preview")
    end
end

-- The run-start sequence: set this run's affixes, show the freeze countdown, and
-- introduce each affix in turn. `seconds` is how long the server is holding everyone
-- still, so the countdown matches the actual root rather than guessing.
function UncappedMythicAffix_RunIntro(keys, seconds)
    seconds = tonumber(seconds) or 10
    UncappedMythicAffix_SetActive(keys, false)      -- capped to MAX_ACTIVE
    ShowHudForDemo()

    introEnd = GetTime() + seconds
    intro.count:SetText(string.format("%.0f", math.ceil(seconds)))
    intro:Show()

    -- Announce all of them back to back. The queue already serialises, and three
    -- affixes take 8.55s against a 10s freeze, so the last one lands with room spare.
    for _, k in ipairs(active) do
        UncappedMythicAffix_Announce(k)
    end
end

function UncappedMythicAffix_Preview()
    local list = active
    if #list == 0 then list = ORDER end
    for _, k in ipairs(list) do
        queue[#queue + 1] = k
    end
    BeginNext()
end

-- ---------------------------------------------------------------------------
-- Protocol
-- ---------------------------------------------------------------------------
-- Not yet sent by the server -- the affix set is client-side test data until the
-- worldserver learns to emit it. Format is fixed here so both ends can be written
-- against it:
--
--   UMA:<key>,<key>,...   set the run's affix list (announces newcomers)
--   UMX:<key>             announce one affix right now (it triggered)
--
-- Keys are the catalogue keys above, not numeric ids, so a server-side reorder
-- cannot silently repoint an affix at the wrong card.
ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", function(self, event, msg)
    if msg and (msg:find("^UMA:") or msg:find("^UMX:") or msg:find("^UMI:")) then return true end
    return false
end)

-- Called from the main ADDON_LOADED handler above, deliberately NOT from a second
-- handler of its own: both would fire on the same event with no defined order, and
-- whichever lost the race would have its work thrown away when the other reassigned
-- UncappedMythicDB. Settings live in the same `db` table as the rest of the HUD, so
-- they persist through the addon's existing SavedVariables.
function UncappedMythicAffixLoad()
    local saved = db.affix
    if type(saved) == "table" then
        for k in pairs(cfg) do
            if saved[k] ~= nil then cfg[k] = saved[k] end
        end
    end
    db.affix = cfg
    LayoutStrip()
end

local affixListener = CreateFrame("Frame")
affixListener:RegisterEvent("CHAT_MSG_CHANNEL")
affixListener:RegisterEvent("CHAT_MSG_ADDON")
affixListener:SetScript("OnEvent", function(self, event, a1, a2)
    local msg
    if event == "CHAT_MSG_ADDON" then
        if a1 ~= ADDON_PIPE_PREFIX then return end
        msg = a2
    else
        if a2 ~= UnitName("player") then return end
        msg = a1
    end
    if not msg then return end

    -- UMI:<freezeSeconds>:<key>,<key>,... -- run start. Sent once, when the server
    -- has just rooted the group; drives the countdown and the full intro sequence.
    local secs, ilist = msg:match("^UMI:(%d+):(.*)$")
    if secs then
        local keys = {}
        for k in ilist:gmatch("[^,]+") do keys[#keys + 1] = k end
        UncappedMythicAffix_RunIntro(keys, tonumber(secs))
        return
    end

    local list = msg:match("^UMA:(.*)$")
    if list then
        local keys = {}
        for k in list:gmatch("[^,]+") do keys[#keys + 1] = k end
        UncappedMythicAffix_SetActive(keys, true)
        return
    end

    local one = msg:match("^UMX:(%S+)$")
    if one then
        UncappedMythicAffix_Announce(one)
        return
    end
end)

-- ---------------------------------------------------------------------------
-- Settings page
-- ---------------------------------------------------------------------------
if UncappedUI then
    local refreshers = {}
    local function track(w)
        refreshers[#refreshers + 1] = w.uncappedRefresh
        return w
    end

    local panel, L = UncappedUI.CreatePanel("Mythic+ Affixes",
        "The affix strip under the keystone HUD, and the announcement that introduces each one.")

    L:Header("Announcements")
    track(L:Check("Play the intro animation", function() return cfg.animate end,
        function(v) cfg.animate = v end))
    track(L:Check("Play voice lines", function() return cfg.sound end,
        function(v) cfg.sound = v end))
    L:Note("|cff808080Voice lines are Diablo III hero barks. They play on the sound-effects channel, so they follow that volume slider.|r", 32)

    L:Gap(6)
    L:Header("Strip")
    track(L:Check("Show the affix strip", function() return cfg.strip end,
        function(v) cfg.strip = v; LayoutStrip() end))
    L:Note("|cff808080Hover an icon for what the affix does and how to play against it. Click one to replay its announcement.|r", 32)

    L:Gap(6)
    L:Button("Preview all affixes", function()
        ShowHudForDemo()
        UncappedMythicAffix_SetActive(ORDER, false)
        UncappedMythicAffix_Preview()
    end, 200)
    L:Note("|cff808080Shows the HUD with every affix loaded and plays each intro in turn.|r", 28)

    UncappedMythicAffixPanel = panel
    function UncappedMythicAffixRefresh()
        for _, r in ipairs(refreshers) do r() end
    end
end

-- ---------------------------------------------------------------------------
-- Slash
-- ---------------------------------------------------------------------------
SLASH_UNCAPPEDMYTHICAFFIX1 = "/mplusaffix"
SLASH_UNCAPPEDMYTHICAFFIX2 = "/mpa"
SlashCmdList["UNCAPPEDMYTHICAFFIX"] = function(arg)
    arg = (arg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")

    -- The default demo simulates a REAL run start: three affixes drawn at random,
    -- the freeze countdown, and the intro sequence. Use `all` to audition every line.
    if arg == "" or arg == "intro" or arg == "demo" then
        local pool, pick = {}, {}
        for _, k in ipairs(ORDER) do pool[#pool + 1] = k end
        for _ = 1, MAX_ACTIVE do
            if #pool == 0 then break end
            pick[#pick + 1] = table.remove(pool, math.random(#pool))
        end
        UncappedMythicAffix_RunIntro(pick, 10)
        return
    end
    if arg == "all" then
        -- Audition every line. Deliberately does NOT touch the active set: SetActive
        -- caps at MAX_ACTIVE, so pushing 10 through it would silently drop 7. The
        -- announcements just queue, and the ones with no slot fly to the strip itself.
        ShowHudForDemo()
        for _, k in ipairs(ORDER) do UncappedMythicAffix_Announce(k, true) end
        return
    end
    if arg == "strip" then
        ShowHudForDemo()
        UncappedMythicAffix_SetActive(ORDER, false)
        DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Uncapped Mythic+|r: strip loaded with all affixes -- hover them.")
        return
    end
    if arg == "clear" then
        UncappedMythicAffix_Clear()
        return
    end
    if arg == "list" then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Uncapped Mythic+ affixes|r:")
        for _, k in ipairs(ORDER) do
            local a = AFFIX[k]
            DEFAULT_CHAT_FRAME:AddMessage(string.format("  |cff%02x%02x%02x%s|r  (%s)  \"%s\"",
                a.color[1] * 255, a.color[2] * 255, a.color[3] * 255, a.name, k, a.tag))
        end
        return
    end
    if AFFIX[arg] then
        ShowHudForDemo()
        UncappedMythicAffix_Announce(arg, true)
        return
    end

    DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Uncapped Mythic+|r: /mpa [intro | all | strip | clear | list | <affix key>]")
    DEFAULT_CHAT_FRAME:AddMessage("  |cff808080intro|r = simulate a run start (3 random affixes + freeze countdown), |cff808080all|r = hear every line")
end
