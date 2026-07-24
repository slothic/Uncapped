-- UncappedMythic
--
-- The keystone run HUD. When the server starts a timed Mythic+ run it sends the
-- time limit, keystone level and total killable trash; this addon then shows a
-- movable panel with:
--   * a countdown timer (green -> red when the timer expires),
--   * an enemy-forces bar (killed / total, turns green at the 70% you need to
--     actually complete the run),
--   * a boss log with engage markers and kill splits.
--
-- Rides the player's personal channel like the other Uncapped addons, and
-- filters the RBMS / RBMT / RBMB protocol lines out of chat.

-- Defaults for every saved setting (persisted in UncappedMythicDB).
local DEFAULTS = {
    bossLines     = 6,                   -- how many boss rows the log can show
    trashGoal     = 0.70,                -- fraction of trash needed to complete
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
    startTime = 0,
    limit = 0,
    level = 0,
    trashKilled = 0,
    trashTotal = 0,
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

local function RefreshBar()
    local frac = 0
    if run.trashTotal > 0 then
        frac = run.trashKilled / run.trashTotal
    end
    if frac > 1 then frac = 1 end
    frame.bar:SetValue(frac)
    if frac >= db.trashGoal then
        local c = db.colComplete                     -- enough to complete
        frame.bar:SetStatusBarColor(c[1], c[2], c[3])
    else
        local c = db.colIncomplete                   -- not yet
        frame.bar:SetStatusBarColor(c[1], c[2], c[3])
    end
    frame.barText:SetText(string.format("Enemy Forces  %d / %d  (%d%%)",
        run.trashKilled, run.trashTotal, math.floor(frac * 100 + 0.5)))
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
local function StartRun(limit, level, trashTotal)
    run.active = true
    -- Timed only for a real dungeon keystone with a limit; raids are untimed.
    run.timed = (limit and limit > 0) and not InRaidInstance()
    run.startTime = GetTime()
    run.limit = limit
    run.level = level
    run.trashKilled = 0
    run.trashTotal = trashTotal
    run.bosses = {}
    run.bossIndex = {}

    frame.title:SetText("Mythic+ Keystone +" .. level)
    ApplyTimerVisibility()
    RefreshBar()
    RefreshBossLog()
    frame:Show()
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

local function UpdateTrash(killed, total)
    run.trashKilled = killed
    run.trashTotal = total
    RefreshBar()
end

-- Hide the protocol lines from chat.
ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", function(self, event, msg)
    if msg and (msg:find("^RBMS:") or msg:find("^RBMT:") or msg:find("^RBMB:")) then
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

    local limit, level, total = msg:match("^RBMS:(%d+):(%d+):(%d+)$")
    if limit then
        StartRun(tonumber(limit), tonumber(level), tonumber(total))
        return
    end

    local killed, ttotal = msg:match("^RBMT:(%d+):(%d+)$")
    if killed then
        UpdateTrash(tonumber(killed), tonumber(ttotal))
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
    track(L:Slider("Enemy-forces completion threshold", 0.5, 1.0, 0.05,
        function() return db.trashGoal end,
        function(v) db.trashGoal = v; RefreshBar() end, "%.2f"))
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
        StartRun(1800, 7, 120)
        EngageBoss("Rhahk'Zor")
        KillBoss("Rhahk'Zor", 74)
        UpdateTrash(88, 120)
        EngageBoss("Mr. Smite")
        return
    end
    if arg == "testraid" then
        StartRun(0, 3, 200)   -- limit 0 -> untimed run, previews the no-timer raid HUD
        EngageBoss("Magtheridon")
        UpdateTrash(140, 200)
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
