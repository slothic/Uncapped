--[[ ==========================================================================
     UncappedLFG -- the Mythic+ noticeboard. Report #605.

     Owner ruling 2026-08-15, and the whole design follows from it:

       * NOTICEBOARD, NOT MATCHMAKER. You queue, you SEE who is waiting, and
         whoever queued first starts it with however many are there. No minimum
         size, no roles -- at this realm's population a queue that waits for a
         tank and a healer never pops, and a queue that never pops is a button
         people stop pressing.
       * QUEUE BY LEVEL. You pick the level; you only ever see people who picked
         the same one and are entitled to it.
       * READY CHECK FIRST. Nobody is yanked out of what they were doing.
       * DUNGEONS AND RAIDS, up to 40 -- this realm raised the instance cap, so
         the "group" the server builds may be a full raid.

     ★★ THE PANEL DECIDES NOTHING, same rule as the keystone panel next door. It
        renders what the server sent and sends what was pressed. Entitlement, map
        eligibility, leadership and the ready check all live server-side, and every
        action is answered with FULL STATE rather than an acknowledgement -- so a
        refused join and an accepted one are indistinguishable from here. That is
        what stops this drifting away from the server.

     ⚠ DEGRADE, NEVER ERROR. This ships in a payload release and will first run
       against whatever server build happens to be up. An older server never
       answers MLFQ, so the panel says so after a timeout rather than sitting on
       "Loading..." forever.

     3.3.5a: no C_Timer (hence OnUpdate for timers), no BackdropTemplate.

       /mlfg          open it
       /mlfg sync     force a refresh
     ========================================================================== ]]

local ADDON_PIPE_PREFIX = "UNC"          -- server -> client
local TRANSPORT_PREFIX  = "REAGENTBANK"  -- client -> server (shared transport)

local REPLY_TIMEOUT = 6.0

local COLOR_HEAD  = "|cff9CC243"
local COLOR_LABEL = "|cffffffff"
local COLOR_VALUE = "|cffffff00"
local COLOR_DIM   = "|cff888888"
local COLOR_GOOD  = "|cff1eff00"
local COLOR_BAD   = "|cffff5555"

local LFG = _G.UncappedLFG or {}
_G.UncappedLFG = LFG
LFG.UI = {}

local format, strmatch, strsub, strtrim, strlower =
    string.format, string.match, string.sub, strtrim, string.lower

-- Server-owned. Never computed here.
local state = {
    loaded    = false,
    mapId     = 0,
    level     = 0,
    isLeader  = false,
    count     = 0,
    checking  = false,
    secsLeft  = 0,
    members   = {},   -- { {name=, ready=} }
    message   = nil,
}

-- The level the player has *selected* in the UI. This one IS local -- it is a
-- form field, not server state, and it is only meaningful until Queue is pressed.
local pickLevel = 1

local frame, widgets = nil, {}
local pending = false
local pendingSince = 0

local function Send(msg)
    SendAddonMessage(TRANSPORT_PREFIX, msg, "WHISPER", UnitName("player"))
end

local function Request()
    pending = true
    pendingSince = GetTime()
    Send("MLFQ")
end

--[[ ------------------------------------------------------------------------
     Incoming
  -------------------------------------------------------------------------- ]]
local building = nil

local function HandleMessage(msg)
    if not msg then return end

    -- MLFH:<mapId>:<level>:<isLeader>:<count>:<checking>:<secsLeft>
    local mapId, level, leader, count, checking, secs =
        strmatch(msg, "^MLFH:(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)$")
    if mapId then
        building = {
            mapId    = tonumber(mapId) or 0,
            level    = tonumber(level) or 0,
            isLeader = (leader == "1"),
            count    = tonumber(count) or 0,
            checking = (checking == "1"),
            secsLeft = tonumber(secs) or 0,
            members  = {},
        }
        return
    end

    -- MLFP:<name>:<readyState>
    local pname, pready = strmatch(msg, "^MLFP:(.+):(%d+)$")
    if pname and building then
        building.members[#building.members + 1] =
            { name = pname, ready = tonumber(pready) or 0 }
        return
    end

    -- MLFM:<text>
    local text = strmatch(msg, "^MLFM:(.+)$")
    if text then
        DEFAULT_CHAT_FRAME:AddMessage(COLOR_HEAD .. "[Mythic+ LFG]|r " .. text)
        return
    end

    -- MLFC:<seconds> -- ready check opened. Deliberately noisy: a prompt you miss
    -- is a group you get dropped from.
    local secsC = strmatch(msg, "^MLFC:(%d+)$")
    if secsC then
        DEFAULT_CHAT_FRAME:AddMessage(COLOR_HEAD .. "[Mythic+ LFG]|r " ..
            COLOR_GOOD .. "Ready check! " .. COLOR_LABEL ..
            "Answer within " .. secsC .. " seconds." .. "|r")
        PlaySound("ReadyCheck")
        if LFG.UI.Refresh then LFG.UI.Refresh() end
        return
    end

    if msg == "MLFE" then
        pending = false
        if building then
            state.loaded   = true
            state.mapId    = building.mapId
            state.level    = building.level
            state.isLeader = building.isLeader
            state.count    = building.count
            state.checking = building.checking
            state.secsLeft = building.secsLeft
            state.members  = building.members
            building = nil
        end
        if LFG.UI.Refresh then LFG.UI.Refresh() end
        return
    end
end

--[[ ------------------------------------------------------------------------
     UI
  -------------------------------------------------------------------------- ]]
-- ⚠ House widget kit, not UIPanelButtonTemplate -- see the long note in
-- UncappedKeystoneRun.lua. The fallback stays so a player with UncappedUI
-- disabled gets plain buttons rather than a nil-global error.
local function MakeButton(parent, label, w, onClick)
    local b
    if UncappedUIKit and UncappedUIKit.CreateButton then
        b = UncappedUIKit.CreateButton(parent, label, w or 120, 22)
    else
        b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        b:SetWidth(w or 120)
        b:SetHeight(22)
        b:SetText(label)
    end
    b:SetScript("OnClick", onClick)
    return b
end

local function BuildFrame(parent)
    if frame then return frame end

    frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -12)
    title:SetText(COLOR_HEAD .. "Mythic+ Group Finder|r")

    -- Wraps to the panel rather than to a hard 330px. The Dashboard is
    -- resizable, so a fixed width either leaves a gutter on a wide window or
    -- runs under the controls on a narrow one.
    widgets.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    widgets.hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    widgets.hint:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
    widgets.hint:SetJustifyH("LEFT")
    widgets.hint:SetText(COLOR_DIM ..
        "Pick a keystone level and queue. Everyone waiting on that level is in the " ..
        "same queue, wherever they are -- the dungeon is chosen when it pops. " ..
        "Whoever's been waiting longest can start it with however many are there.|r")

    -- Level stepper, and it is the ENTIRE queue: you pick a level, the pop picks
    -- the dungeon. No map picker here, deliberately.
    --
    -- -18 rather than -14: the hint above is two lines on most window widths and
    -- one on a wide one, and at -14 the readout sat tight against whichever it
    -- happened to be.
    widgets.level = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    widgets.level:SetPoint("TOPLEFT", widgets.hint, "BOTTOMLEFT", 0, -18)

    widgets.minus = MakeButton(frame, "-", 26, function()
        if pickLevel > 1 then pickLevel = pickLevel - 1 end
        if LFG.UI.Refresh then LFG.UI.Refresh() end
    end)
    widgets.minus:SetPoint("TOPLEFT", widgets.level, "BOTTOMLEFT", 0, -8)

    widgets.plus = MakeButton(frame, "+", 26, function()
        pickLevel = pickLevel + 1
        if LFG.UI.Refresh then LFG.UI.Refresh() end
    end)
    widgets.plus:SetPoint("LEFT", widgets.minus, "RIGHT", 4, 0)

    widgets.queue = MakeButton(frame, "Queue", 120, function()
        -- ★★ LEVEL ONLY. The pop picks the dungeon.
        --
        -- ⚠ This used to send `GetInstanceInfo()`'s map id -- "wherever you are
        --   standing". Opened anywhere you would actually use a group finder (the
        --   Mall, a city, anywhere outside an instance) that is not a Mythic Plus
        --   map, so the server refused it with "That dungeon is not part of
        --   Mythic Plus" and the button never worked. Do not reintroduce a map
        --   here: there is no dungeon picker in this panel and there is not meant
        --   to be one.
        Send("MLFJ:" .. tostring(pickLevel))
    end)
    widgets.queue:SetPoint("LEFT", widgets.plus, "RIGHT", 12, 0)

    widgets.leave = MakeButton(frame, "Leave", 100, function() Send("MLFL") end)
    widgets.leave:SetPoint("LEFT", widgets.queue, "RIGHT", 6, 0)

    widgets.roster = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    widgets.roster:SetPoint("TOPLEFT", widgets.minus, "BOTTOMLEFT", 0, -16)
    widgets.roster:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
    widgets.roster:SetJustifyH("LEFT")
    widgets.roster:SetJustifyV("TOP")

    widgets.start = MakeButton(frame, "Start the group", 150, function() Send("MLFS") end)
    widgets.start:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 42)

    widgets.accept = MakeButton(frame, "I'm ready", 110, function() Send("MLFR:1") end)
    widgets.accept:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 14)

    widgets.decline = MakeButton(frame, "Decline", 110, function() Send("MLFR:0") end)
    widgets.decline:SetPoint("LEFT", widgets.accept, "RIGHT", 6, 0)

    widgets.status = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    widgets.status:SetPoint("BOTTOMLEFT", widgets.start, "TOPLEFT", 0, 8)

    -- Timeout watchdog: never sit on "Loading..." forever against an old server.
    frame:SetScript("OnUpdate", function()
        if pending and (GetTime() - pendingSince) > REPLY_TIMEOUT then
            pending = false
            state.loaded = false
            widgets.status:SetText(COLOR_BAD ..
                "No answer from the server -- it may not have the group finder yet.|r")
        end
    end)

    return frame
end

function LFG.UI.Refresh()
    if not frame then return end

    -- ⚠ Keyed on the LEVEL, not the map. The queue is level-only since 2026-08-16
    -- and the server sends mapId 0 for every entry, so `state.mapId ~= 0` reported
    -- every queued player as not queued.
    local queued = state.loaded and state.level ~= 0

    widgets.level:SetText(COLOR_LABEL .. "Level to queue for  " ..
        COLOR_VALUE .. "+" .. pickLevel .. "|r")

    if queued then
        local lines = {}
        for i = 1, #state.members do
            local m = state.members[i]
            local mark = COLOR_DIM .. "waiting|r"
            if m.ready == 1 then mark = COLOR_GOOD .. "ready|r"
            elseif m.ready == 2 then mark = COLOR_BAD .. "declined|r" end
            lines[#lines + 1] = "  " .. m.name .. "   " .. mark
        end
        widgets.roster:SetText(COLOR_LABEL .. "In the queue for +" .. state.level ..
            "  (" .. state.count .. ")|r\n" .. table.concat(lines, "\n"))
        widgets.leave:Enable()
    else
        widgets.roster:SetText(COLOR_DIM .. "You are not in a queue.|r")
        widgets.leave:Disable()
    end

    -- Start is the leader's button and only means anything with company.
    if queued and state.isLeader and state.count > 1 and not state.checking then
        widgets.start:Enable()
    else
        widgets.start:Disable()
    end

    if state.checking then
        widgets.accept:Enable()
        widgets.decline:Enable()
        widgets.status:SetText(COLOR_GOOD .. "Ready check running" ..
            (state.secsLeft > 0 and ("  (" .. state.secsLeft .. "s)") or "") .. "|r")
    else
        widgets.accept:Disable()
        widgets.decline:Disable()
        if queued and not state.isLeader then
            widgets.status:SetText(COLOR_DIM ..
                "Waiting for the group's starter to begin.|r")
        elseif queued and state.count <= 1 then
            widgets.status:SetText(COLOR_DIM ..
                "You're the only one here so far. Others queueing for +" ..
                state.level .. " will show up.|r")
        else
            widgets.status:SetText("")
        end
    end
end

-- Same contract as UncappedKeystoneRun: EmbedInto returns a frame the Keystone
-- tab re-anchors under its sub-tab strip, and Activate refreshes on the way in so
-- switching to the tab never shows a stale roster.
function LFG.UI.EmbedInto(parent)
    local f = BuildFrame(parent)
    f:Show()
    return f
end

function LFG.UI.Activate()
    if frame then frame:Show() end
    Request()
    if LFG.UI.Refresh then LFG.UI.Refresh() end
end

function LFG.UI.GetMinWidth()  return 360 end
function LFG.UI.GetMinHeight() return 320 end

--[[ ------------------------------------------------------------------------
     Comms + slash command
  -------------------------------------------------------------------------- ]]
local comms = CreateFrame("Frame")
comms:RegisterEvent("CHAT_MSG_ADDON")
comms:SetScript("OnEvent", function(_, _, prefix, message)
    if prefix ~= ADDON_PIPE_PREFIX then return end
    -- [DP-12] Cheap prefix reject FIRST. The UNC pipe is shared by every panel
    -- and carries well over a hundred lines a second in an AoE Mythic+ pull;
    -- every LFG verb is MLF*, so this drops the other panels' traffic before
    -- HandleMessage allocates a single strmatch capture.
    if strsub(message or "", 1, 3) ~= "MLF" then return end
    HandleMessage(message)
end)

SLASH_UNCAPPEDMLFG1 = "/mlfg"
SlashCmdList["UNCAPPEDMLFG"] = function(arg)
    if arg and strlower(strtrim(arg)) == "sync" then
        Request()
        DEFAULT_CHAT_FRAME:AddMessage(COLOR_HEAD .. "[Mythic+ LFG]|r refreshing...")
        return
    end

    local Dashboard = _G.UncappedDashboard
    if not Dashboard then
        DEFAULT_CHAT_FRAME:AddMessage(COLOR_HEAD ..
            "[Mythic+ LFG]|r lives inside the Dashboard -- load UncappedDashboard to use it.")
        return
    end

    -- ★ THE HOUSE IDIOM, NOT A BESPOKE ONE. Every other tab opens itself with
    -- SetTab + Toggle-if-hidden -- /mkey next door, Anima, Forge, Vault, Transmog,
    -- Progress, Prestige, Scrolls and the Loot Feed all read identically. This file
    -- ended in `if Dashboard.Open then Dashboard:Open("keystone") end` instead, and
    -- UncappedDashboard has never had an Open(): the guard swallowed the miss, so
    -- /mlfg, the I key and the LFD micro button all did nothing at all, silently,
    -- from 2026-08-16 to 2026-08-22. Match the neighbours; do not invent a door.
    Dashboard.SetTab("keystone")
    if not (Dashboard.UI and Dashboard.UI.IsShown and Dashboard.UI.IsShown()) then
        Dashboard.Toggle()
    end

    -- ⚠ OPENING THE TAB IS NOT OPENING THE NOTICEBOARD. All of M+ is ONE nav tab
    -- with a sub-tab strip inside it (see the SUB-TABS block in UncappedKeystone.lua),
    -- so the lines above land on whichever sub-tab was last open -- "Your Keystone"
    -- by default. Without this, /mlfg still costs a click to reach what it names.
    --
    -- Keystone.ShowSection is assigned inside BuildFrame, which the open above has
    -- just run; guarded anyway, because a partial install (no UncappedUI, no keystone
    -- panel) never builds the strip and must degrade rather than error. ShowSection
    -- calls LFG.UI.Activate(), which does the Request() itself -- hence the else
    -- branch rather than a second Request() that would double every keypress.
    local Keystone = _G.UncappedKeystone
    if Keystone and Keystone.ShowSection then
        Keystone.ShowSection("lfg")
    else
        Request()
    end
end
