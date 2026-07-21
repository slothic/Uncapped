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

local BOSS_LINES = 6           -- how many boss rows the log can show
local TRASH_GOAL = 0.70        -- fraction of trash needed to complete

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
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:Hide()

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
for i = 1, BOSS_LINES do
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", frame.bar, "BOTTOMLEFT", 0, -4 - (i - 1) * 14)
    fs:SetJustifyH("LEFT")
    fs:SetWidth(200)
    frame.bossRows[i] = fs
end

-- ---------------------------------------------------------------------------
-- Run state
-- ---------------------------------------------------------------------------
local run = {
    active = false,
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
    local rows = math.min(#run.bosses, BOSS_LINES)
    frame:SetHeight(96 + rows * 14 + 12)
end

local function RefreshBossLog()
    for i = 1, BOSS_LINES do
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

local function RefreshBar()
    local frac = 0
    if run.trashTotal > 0 then
        frac = run.trashKilled / run.trashTotal
    end
    if frac > 1 then frac = 1 end
    frame.bar:SetValue(frac)
    if frac >= TRASH_GOAL then
        frame.bar:SetStatusBarColor(0.1, 0.8, 0.1)   -- enough to complete
    else
        frame.bar:SetStatusBarColor(0.8, 0.5, 0.1)   -- not yet
    end
    frame.barText:SetText(string.format("Enemy Forces  %d / %d  (%d%%)",
        run.trashKilled, run.trashTotal, math.floor(frac * 100 + 0.5)))
end

frame:SetScript("OnUpdate", function(self)
    if not run.active then return end
    local remaining = run.limit - (GetTime() - run.startTime)
    self.timer:SetText(fmtTime(remaining))
    if remaining <= 0 then
        self.timer:SetTextColor(1.0, 0.2, 0.2)       -- over the timer
    elseif remaining <= 60 then
        self.timer:SetTextColor(1.0, 0.8, 0.2)       -- last minute
    else
        self.timer:SetTextColor(0.6, 1.0, 0.6)
    end
end)

-- ---------------------------------------------------------------------------
-- Protocol
-- ---------------------------------------------------------------------------
local function StartRun(limit, level, trashTotal)
    run.active = true
    run.startTime = GetTime()
    run.limit = limit
    run.level = level
    run.trashKilled = 0
    run.trashTotal = trashTotal
    run.bosses = {}
    run.bossIndex = {}

    frame.title:SetText("Mythic+ Keystone +" .. level)
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

local listener = CreateFrame("Frame")
listener:RegisterEvent("CHAT_MSG_CHANNEL")
listener:RegisterEvent("ADDON_LOADED")
listener:RegisterEvent("PLAYER_ENTERING_WORLD")
listener:SetScript("OnEvent", function(self, event, a1, a2)
    if event == "ADDON_LOADED" then
        if a1 == "UncappedMythic" then
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

    -- CHAT_MSG_CHANNEL: a1 = message, a2 = author (our own name on the pipe).
    if a2 ~= UnitName("player") or not a1 then
        return
    end

    local limit, level, total = a1:match("^RBMS:(%d+):(%d+):(%d+)$")
    if limit then
        StartRun(tonumber(limit), tonumber(level), tonumber(total))
        return
    end

    local killed, ttotal = a1:match("^RBMT:(%d+):(%d+)$")
    if killed then
        UpdateTrash(tonumber(killed), tonumber(ttotal))
        return
    end

    -- RBMB:e:<name>  (engage)   or   RBMB:k:<name>:<seconds>  (kill)
    local ename = a1:match("^RBMB:e:(.+)$")
    if ename then
        EngageBoss(ename)
        return
    end
    local kname, ksplit = a1:match("^RBMB:k:(.+):(%d+)$")
    if kname then
        KillBoss(kname, tonumber(ksplit))
        return
    end
end)

-- ---------------------------------------------------------------------------
-- Slash: toggle / test
-- ---------------------------------------------------------------------------
SLASH_UNCAPPEDMYTHIC1 = "/mplus"
SlashCmdList["UNCAPPEDMYTHIC"] = function(arg)
    if arg == "test" then
        StartRun(1800, 7, 120)
        EngageBoss("Rhahk'Zor")
        KillBoss("Rhahk'Zor", 74)
        UpdateTrash(88, 120)
        EngageBoss("Mr. Smite")
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
