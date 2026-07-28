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
-- filters the RBMS / RBMT / RBMR / RBMB protocol lines out of chat.
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
    bossLines     = 6,                   -- how many boss rows the log can show
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

local function ResizeFrame()
    local rows = math.min(#run.bosses, db.bossLines)
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
    for i = 1, db.bossLines do
        local b = run.bosses[i]
        if b then
            if b.done then
                frame.bossRows[i]:SetText(string.format("|cff00ff00v|r %s  |cffaaaaaa%s|r", b.name, fmtTime(b.split)))
            else
                frame.bossRows[i]:SetText(string.format("|cffffcc00>|r %s", b.name))
            end
        else
            frame.bossRows[i]:SetText("")
        end
    end
    ResizeFrame()
end

-- Grow/shrink the pool of boss rows live when the count setting changes.
local function ApplyBossLines(n)
    db.bossLines = n
    for i = 1, n do EnsureBossRow(i):Show() end
    for i = n + 1, #frame.bossRows do
        frame.bossRows[i]:SetText("")
        frame.bossRows[i]:Hide()
    end
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

-- Timer-only resync (RBMR). Rebases the countdown without touching the bar or
-- the boss log -- sent on every death, so the penalty shows up on the clock the
-- instant it is charged instead of only being felt when the run fails.
local function ResyncTimer(remaining)
    if not run.active then return end
    run.startTime = GetTime()
    run.limit = remaining
end

local function EngageBoss(name)
    if run.bossIndex[name] then return end
    table.insert(run.bosses, { name = name, done = false, split = 0 })
    run.bossIndex[name] = #run.bosses
    RefreshBossLog()
end

local function KillBoss(name, split)
    local idx = run.bossIndex[name]
    if not idx then
        table.insert(run.bosses, { name = name, done = true, split = split })
        run.bossIndex[name] = #run.bosses
    else
        run.bosses[idx].done = true
        run.bosses[idx].split = split
    end
    RefreshBossLog()
end

local function UpdateTrash(killed, needed)
    run.trashKilled = killed
    run.trashNeeded = needed
    RefreshBar()
end

-- Hide the protocol lines from chat.
ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", function(self, event, msg)
    if msg and (msg:find("^RBMS:") or msg:find("^RBMT:") or msg:find("^RBMR:") or msg:find("^RBMB:")) then
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
            end
            UncappedMythicDB = db
            frame:SetScale(db.scale)
            ApplyPosition()
            ApplyBossLines(db.bossLines)
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
        end
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

    -- RBMS:<remainingSec>:<level>:<requiredKills>:<runToken>
    local remaining, level, needed, token = msg:match("^RBMS:(%d+):(%d+):(%d+):(%d+)$")
    if remaining then
        StartRun(tonumber(remaining), tonumber(level), tonumber(needed), tonumber(token))
        return
    end

    -- Older 3-field form (a realm still on the previous worldserver). No run
    -- token, so every one of these is treated as a fresh run.
    local oldLimit, oldLevel, oldTotal = msg:match("^RBMS:(%d+):(%d+):(%d+)$")
    if oldLimit then
        StartRun(tonumber(oldLimit), tonumber(oldLevel), tonumber(oldTotal), nil)
        return
    end

    -- RBMR:<remainingSec> -- timer rebase only (death penalty applied).
    local resync = msg:match("^RBMR:(%d+)$")
    if resync then
        ResyncTimer(tonumber(resync))
        return
    end

    -- RBMT:<killed>:<requiredKills>
    local killed, needKills = msg:match("^RBMT:(%d+):(%d+)$")
    if killed then
        UpdateTrash(tonumber(killed), tonumber(needKills))
        return
    end

    -- RBMB:e:<name>  (engage)   or   RBMB:k:<name>:<seconds>  (kill)
    local ename = msg:match("^RBMB:e:(.+)$")
    if ename then
        EngageBoss(ename)
        return
    end
    local kname, ksplit = msg:match("^RBMB:k:(.+):(%d+)$")
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
    track(L:Slider("Boss log rows shown", 3, 12, 1,
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
