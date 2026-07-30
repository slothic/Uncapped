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
                -- [affix] Carry the affix sub-table across explicitly. It is not a
                -- DEFAULTS key, and DEFAULTS' table values are ARRAY-copied above
                -- (for i = 1, #v), which would flatten a string-keyed table to
                -- empty anyway. Without this the affix settings reset every login.
                if type(s.affix) == "table" then db.affix = s.affix end
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
local CARD_SCALE_END = 0.32

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
        desc = "Slain enemies detonate a few seconds after they fall, marking the\nground before they go off.",
        counter = "Step off the corpse. The marker is the warning.",
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
        desc = "The ground heaves at a fixed interval, hitting everyone and\ninterrupting anyone standing too close to an ally.",
        counter = "Spread before the next wave. Watch the timer, not the ground.",
        icon = "Spell_Nature_Earthquake", sound = "endlesstide",
        color = { 0.40, 0.70, 0.95 },
    },
    bloodletting = {
        name = "Bloodletting",
        tag  = "Bleed, you filth!",
        desc = "The dead leave pools of blood. Enemies standing in one heal;\nyou take damage.",
        counter = "Drag the pack off its own dead.",
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
        desc = "Melee hits stack a debuff that cuts the healing you receive.",
        counter = "Let it fall off. Rotate cooldowns instead of out-healing it.",
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
        desc = "Running ahead of the clock empowers what is left of the dungeon.\nThe better you are doing, the harder it pushes back.",
        counter = "Nothing -- this is the price of a fast run.",
        icon = "Ability_Warrior_InnerRage", sound = "hubris",
        color = { 0.95, 0.90, 0.60 },
    },
}

-- Fixed display order, so the strip never reshuffles between runs.
local ORDER = {
    "endlesstide", "sundered", "weakenedflesh", "bloodletting",
    "decay", "finecorpse", "thecycle", "vengeance", "hubris",
}

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
        GameTooltip:AddLine('"' .. a.tag .. '"', 0.6, 0.6, 0.6, true)
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
local function OffsetFromUIParentCenter(f)
    local fx, fy = f:GetCenter()
    local px, py = UIParent:GetCenter()
    if not fx or not px then return 0, 0 end
    local fs, ps = f:GetEffectiveScale(), UIParent:GetEffectiveScale()
    return (fx * fs - px * ps) / ps, (fy * fs - py * ps) / ps
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
    card.tag:SetText('"' .. a.tag .. '"')
    card:SetBackdropBorderColor(a.color[1], a.color[2], a.color[3])

    -- Target the slot this affix will occupy, so the card flies to where its icon
    -- actually ends up. Falls back to the strip itself when the affix is not in
    -- the active set (previewing with no run).
    local target = strip
    for i, k in ipairs(active) do
        if k == key and slots[i] then target = slots[i] end
    end

    anim = { key = key, t = 0, phase = "grow", target = target }
    card:SetScale(1)
    card:SetAlpha(0)
    card:ClearAllPoints()
    card:SetPoint("CENTER", UIParent, "CENTER", 0, 140)
    card:Show()

    if cfg.sound then PlaySoundFile(SOUND_DIR .. a.sound .. ".wav") end
end

card:SetScript("OnUpdate", function(self, elapsed)
    if not anim then return end
    anim.t = anim.t + elapsed

    if anim.phase == "grow" then
        local p = math.min(anim.t / GROW, 1)
        self:SetAlpha(p)
        self:SetScale(0.7 + 0.3 * p)
        if p >= 1 then anim.phase, anim.t = "hold", 0 end

    elseif anim.phase == "hold" then
        self:SetAlpha(1)
        self:SetScale(1)
        if anim.t >= HOLD then
            -- Capture the flight target now: the strip has finished laying out by
            -- this point, so the slot position is final.
            anim.tx, anim.ty = OffsetFromUIParentCenter(anim.target)
            anim.phase, anim.t = "fly", 0
        end

    elseif anim.phase == "fly" then
        local p = math.min(anim.t / FLY, 1)
        local e = p * p * (3 - 2 * p)               -- smoothstep
        local x = 0 + (anim.tx or 0) * e
        local y = 140 + ((anim.ty or 0) - 140) * e
        self:ClearAllPoints()
        self:SetPoint("CENTER", UIParent, "CENTER", x, y)
        self:SetScale(1 + (CARD_SCALE_END - 1) * e)
        self:SetAlpha(1 - e * 0.9)
        if p >= 1 then
            self:Hide()
            self:SetScale(1)
            self:SetAlpha(1)
            anim = nil
            BeginNext()
        end
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
        if want[k] then active[#active + 1] = k end
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
--   RBMA:<key>,<key>,...   set the run's affix list (announces newcomers)
--   RBMX:<key>             announce one affix right now (it triggered)
--
-- Keys are the catalogue keys above, not numeric ids, so a server-side reorder
-- cannot silently repoint an affix at the wrong card.
ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", function(self, event, msg)
    if msg and (msg:find("^RBMA:") or msg:find("^RBMX:")) then return true end
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

    local list = msg:match("^RBMA:(.*)$")
    if list then
        local keys = {}
        for k in list:gmatch("[^,]+") do keys[#keys + 1] = k end
        UncappedMythicAffix_SetActive(keys, true)
        return
    end

    local one = msg:match("^RBMX:(%S+)$")
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

    if arg == "" or arg == "demo" then
        ShowHudForDemo()
        UncappedMythicAffix_SetActive(ORDER, false)
        UncappedMythicAffix_Preview()
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

    DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Uncapped Mythic+|r: /mpa [demo | strip | clear | list | <affix key>]")
end
