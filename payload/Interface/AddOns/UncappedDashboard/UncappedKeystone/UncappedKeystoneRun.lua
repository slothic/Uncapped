--[[ ==========================================================================
     UncappedKeystoneRun -- managing and STARTING your key, without the item.

     Owner ruling 2026-08-12: "let's move the ENTIRE mythic keystone into the
     dashboard." Design: docs/design/MYTHIC_DASHBOARD.md.

     WHY THIS EXISTS
     ---------------
     The keystone is an ITEM you right-click. That item runs on the shared custom
     use-spell 46331, which demands a unit target and refuses while mounted --
     report #655, verbatim: "mythic keystone need to target self, or it says too
     far away, it also doesn't work when mounted". And a gossip menu opened from a
     bag item is unreachable once you are mid-run and want to stop looping (#657).

     A panel has none of those properties. It opens mounted, in combat, mid-run,
     dead, anywhere.

     ★ THIS DOES NOT FIX 46331 -- it removes the KEYSTONE from that spell's blast
       radius. The sacks, scrolls and multitools still share it.

     ★★ THE PANEL DECIDES NOTHING. It renders what the server sent and sends what
        the player pressed. Every level clamp, every "can you start here" rule and
        every option lives server-side, and every action reply is a FULL STATE
        message -- so the panel never predicts a new value, it is told one. A
        clamped or refused change is indistinguishable from an accepted one from
        here, which is exactly what stops this drifting away from the server.

     NO DUNGEON PICKER, DELIBERATELY. Owner: the dungeon is whichever one you walk
     into; the level is your highest clear + 1, floored at 1. You may step DOWN to
     farm lower. There is no map list here and there is not meant to be -- the map
     picker on the Rewards tab exists to preview payouts, which is a different job.

     ⚠ DEGRADE, NEVER ERROR. Ships in a payload release and first runs against
       whatever server build is up. An older server never answers MKSQ; the panel
       says so after a timeout instead of sitting on "Loading..." forever.

     3.3.5a: no C_Timer (hence OnUpdate for the timeout), no BackdropTemplate.

       /mkey            open it
       /mkey sync       force a refresh
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

local Run = _G.UncappedKeystoneRun or {}
_G.UncappedKeystoneRun = Run
Run.UI = {}

-- Server-owned state. Nothing here is ever computed locally; see the header.
local state = {
    level       = 0,
    startHere   = false,   -- can start a run right now, where you stand
    startAtAll  = false,   -- key is otherwise valid (wrong place is the only issue)
    loop        = false,
    autostart   = false,
    locked      = false,
    highest     = 0,
    reason      = nil,     -- human text for why Start is unavailable
    loaded      = false,
    waiting     = false,
    timedOut    = false,
}

local frame, widgets

local function Send(msg)
    SendAddonMessage(TRANSPORT_PREFIX, msg, "WHISPER", UnitName("player"))
end

local function Request()
    state.waiting  = true
    state.timedOut = false
    Send("MKSQ")
end
Run.Request = Request

--[[ ------------------------------------------------------------------------
     Wire
     ------------------------------------------------------------------------
     MKSH:<level>:<startHere>:<startAtAll>:<loop>:<auto>:<lock>:<highest>
     MKSR:<reason>     only when something is blocked
     MKSE              end of state
  -------------------------------------------------------------------------- ]]
local function HandleMessage(msg)
    if msg == "MKSE" then
        state.loaded  = true
        state.waiting = false
        if Run.Render then Run.Render() end
        return true
    end

    if strsub(msg, 1, 5) == "MKSR:" then
        state.reason = strsub(msg, 6)
        return true
    end

    if strsub(msg, 1, 5) == "MKSH:" then
        -- A fresh state message supersedes the previous one entirely, so the
        -- old blocking reason must go with it -- otherwise a reason that no
        -- longer applies survives into a state that has no MKSR at all.
        state.reason = nil

        -- [#832] `heroic` is the eighth field, appended by the server. Parsed with
        -- an optional group so this addon still reads a seven-field line from an
        -- older worldserver instead of rejecting the whole message and going blank.
        local lvl, here, atAll, loop, auto, lock, highest, heroic =
            strmatch(strsub(msg, 6), "^(%-?%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):?(%d*)$")
        if not lvl then return true end

        state.level      = tonumber(lvl) or 0
        state.startHere  = (here  == "1")
        state.startAtAll = (atAll == "1")
        state.loop       = (loop  == "1")
        state.autostart  = (auto  == "1")
        state.locked     = (lock  == "1")
        state.highest    = tonumber(highest) or 0
        state.heroic     = (heroic == "1")
        return true
    end

    return false
end

--[[ ------------------------------------------------------------------------
     Rendering
  -------------------------------------------------------------------------- ]]
--[[
    ⚠ DEFINED HERE, ABOVE ITS FIRST USE, AND THAT IS NOT COSMETIC.

    This lived down in the frame-building section, BELOW SetToggle. In Lua a
    `local function` only becomes visible to closures created after it, so
    SetToggle compiled `SetButtonLabel` as a GLOBAL lookup and blew up the first
    time a toggle rendered:

        attempt to call global 'SetButtonLabel' (a nil value)

    ★ luac -p CANNOT catch this -- it is valid syntax and a runtime nil. Syntax
      checking a Lua file proves it parses, not that its locals are in scope where
      they are used. Order matters, so keep helpers above their callers.
]]
local function SetButtonLabel(b, label)
    -- ★ Kept as a one-liner rather than deleted. As of 2026-08-16 the kit button
    --   overrides SetText properly (it used to write to a font string it never
    --   created, so relabelling silently did nothing), which means plain SetText
    --   is now correct for BOTH kit and Blizzard buttons. This wrapper stays only
    --   so its callers read the same either way -- there is no longer a fork.
    b:SetText(label)
end

local function SetToggle(btn, on, label)
    SetButtonLabel(btn, (on and (COLOR_GOOD .. "ON|r  ") or (COLOR_DIM .. "OFF|r ")) .. COLOR_LABEL .. label .. "|r")
end

function Run.Render()
    if not frame or not frame:IsShown() or not widgets then return end

    if state.timedOut then
        widgets.status:SetText(COLOR_DIM ..
            "This server build doesn't answer the keystone panel yet. Use the keystone item for now.|r")
        widgets.level:SetText("")
        return
    end

    if not state.loaded then
        widgets.status:SetText(COLOR_DIM .. "Loading...|r")
        widgets.level:SetText("")
        return
    end

    widgets.level:SetText(COLOR_LABEL .. "Keystone level  " .. COLOR_VALUE .. "+" .. state.level .. "|r")
    -- The ceiling is best-clear + 1 (server: MythicPlus::EntitledKeystoneLevel).
    -- Derived here rather than sent, because `highest` is already in the state
    -- message and a second field carrying the same fact is a second field that
    -- can disagree with the first.
    --
    -- Shown even when the player is nowhere near it: "why can I not go higher"
    -- is the question this line exists to answer BEFORE it is asked, and a
    -- stepper that silently refuses reads as a broken button.
    local cap = (state.highest or 0) + 1
    if state.level >= cap then
        widgets.highest:SetText(COLOR_DIM .. "Best clear: +" .. state.highest
            .. "  --  at your limit, clear +" .. state.level .. " to unlock +" .. (state.level + 1) .. "|r")
    else
        widgets.highest:SetText(COLOR_DIM .. "Best clear: +" .. state.highest
            .. "  (max +" .. cap .. ")|r")
    end

    SetToggle(widgets.loop, state.loop, "Loop on clear")
    SetToggle(widgets.auto, state.autostart, "Autostart")
    SetToggle(widgets.lock, state.locked, "Lock level")
    SetToggle(widgets.heroic, state.heroic, "Force heroic")   -- [#832]

    -- Start is enabled ONLY on the server's answer for "here". The reason text
    -- carries the rest; we never guess at it.
    if state.startHere then
        widgets.start:Enable()
        widgets.status:SetText(COLOR_GOOD .. "Ready to start.|r")
    else
        widgets.start:Disable()
        widgets.status:SetText((state.reason and (COLOR_BAD .. state.reason .. "|r"))
            or (COLOR_DIM .. "You can't start a run from here.|r"))
    end
end

--[[ ------------------------------------------------------------------------
     Frame
  -------------------------------------------------------------------------- ]]
--[[
    ⚠ USE THE HOUSE WIDGET KIT, NOT UIPanelButtonTemplate.

    The first version of this panel used raw Blizzard `UIPanelButtonTemplate`
    buttons. They came out red and chunky against every other Uncapped panel,
    which are all UncappedUI -- and they OVERLAPPED, because that template draws
    a border wider than the width you set, so buttons spaced for their logical
    width collide once they render.

    UncappedUIKit.CreateButton is the same control the Dashboard, the Vault and
    the loot feed use, so this panel now looks like it belongs to the addon it
    ships inside.

    ★ The fallback is deliberate and must stay: UncappedUI is a separate addon in
      the payload, and if a player has it disabled this panel degrades to plain
      buttons instead of erroring on a nil global. Ugly beats broken.
]]
local function MakeButton(parent, label, w, onClick)
    local b
    if UncappedUIKit and UncappedUIKit.CreateButton then
        b = UncappedUIKit.CreateButton(parent, label, w, 24)
    else
        b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        b:SetWidth(w)
        b:SetHeight(24)
        b:SetText(label)
    end
    b:SetScript("OnClick", onClick)
    return b
end


local function BuildFrame(parent)
    if frame then return frame end

    frame = CreateFrame("Frame", "UncappedKeystoneRunFrame", parent)
    frame:SetAllPoints(parent)

    widgets = {}

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -14)
    title:SetText(COLOR_HEAD .. "Your Keystone|r")

    widgets.level = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    widgets.level:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -14)

    widgets.highest = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    widgets.highest:SetPoint("TOPLEFT", widgets.level, "BOTTOMLEFT", 0, -4)

    -- Steppers. The server owns the clamp; -10/-1/+1/+10 just send a delta.
    local function Step(delta)
        return function()
            Send("MKSL:" .. delta)
        end
    end

    -- ⚠ SPACING: step is button width PLUS a real gap. The first version used
    -- 42-wide buttons 46 apart and they still collided, because the Blizzard
    -- template draws wider than its SetWidth. 54/62 leaves the gap visible with
    -- the kit and survives the fallback too.
    local BTN_W, BTN_STEP = 54, 62
    local x = 0
    for _, spec in ipairs({ { "-10", -10 }, { "-1", -1 }, { "+1", 1 }, { "+10", 10 } }) do
        local b = MakeButton(frame, spec[1], BTN_W, Step(spec[2]))
        -- -28 not -10: the row sat on top of the "Best clear" line above it.
        b:SetPoint("TOPLEFT", widgets.highest, "BOTTOMLEFT", x, -28)
        x = x + BTN_STEP
    end

    -- Toggles. Each sends and waits to be told the new value.
    local function Toggle(opt, get)
        return function()
            Send("MKSO:" .. opt .. ":" .. (get() and "0" or "1"))
        end
    end

    -- The toggle column hangs off the STEPPER row, not off `highest`, so the two
    -- groups can never be anchored into each other again.
    widgets.loop = MakeButton(frame, "", 170, Toggle("loop", function() return state.loop end))
    widgets.loop:SetPoint("TOPLEFT", widgets.highest, "BOTTOMLEFT", 0, -66)

    widgets.auto = MakeButton(frame, "", 170, Toggle("auto", function() return state.autostart end))
    widgets.auto:SetPoint("TOPLEFT", widgets.loop, "BOTTOMLEFT", 0, -8)

    widgets.lock = MakeButton(frame, "", 170, Toggle("lock", function() return state.locked end))
    widgets.lock:SetPoint("TOPLEFT", widgets.auto, "BOTTOMLEFT", 0, -8)

    -- [#832] "The Hug option to start keystones lacks the ability to force the
    -- dungeon to heroic mode the way keystone item does." It does now -- this is
    -- the same setting the item's own toggle writes, which until now had exactly
    -- one caller and no way to reach it from the dashboard.
    widgets.heroic = MakeButton(frame, "", 170, Toggle("heroic", function() return state.heroic end))
    widgets.heroic:SetPoint("TOPLEFT", widgets.lock, "BOTTOMLEFT", 0, -8)

    widgets.start = MakeButton(frame, "Start the run", 170, function()
        Send("MKST")
    end)
    widgets.start:SetPoint("TOPLEFT", widgets.heroic, "BOTTOMLEFT", 0, -22)

    widgets.status = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    widgets.status:SetPoint("TOPLEFT", widgets.start, "BOTTOMLEFT", 0, -14)
    widgets.status:SetWidth(320)
    widgets.status:SetJustifyH("LEFT")

    -- 3.3.5a has no C_Timer: the reply timeout is an OnUpdate accumulator, and it
    -- exists so a server that never answers produces a sentence rather than a
    -- permanent "Loading...".
    local elapsed = 0
    frame:SetScript("OnUpdate", function(self, dt)
        if not state.waiting then
            elapsed = 0
            return
        end
        elapsed = elapsed + dt
        if elapsed >= REPLY_TIMEOUT then
            state.waiting  = false
            state.timedOut = true
            elapsed = 0
            Run.Render()
        end
    end)

    return frame
end

--[[ ------------------------------------------------------------------------
     Dashboard embedding -- same contract the Rewards tab uses.
  -------------------------------------------------------------------------- ]]
function Run.UI.EmbedInto(parent)
    local f = BuildFrame(parent)
    f:Show()
    return f
end

function Run.UI.Activate()
    if frame then frame:Show() end
    Request()
    Run.Render()
end

function Run.UI.GetMinWidth()  return 360 end
function Run.UI.GetMinHeight() return 300 end

--[[ ------------------------------------------------------------------------
     Comms + slash command
  -------------------------------------------------------------------------- ]]
local comms = CreateFrame("Frame")
comms:RegisterEvent("CHAT_MSG_ADDON")
comms:SetScript("OnEvent", function(_, _, prefix, message)
    if prefix ~= ADDON_PIPE_PREFIX then return end
    HandleMessage(message)
end)

SLASH_UNCAPPEDMKEY1 = "/mkey"
SlashCmdList["UNCAPPEDMKEY"] = function(arg)
    if arg and strlower(strtrim(arg)) == "sync" then
        Request()
        DEFAULT_CHAT_FRAME:AddMessage(COLOR_HEAD .. "[Keystone]|r refreshing...")
        return
    end

    local Dashboard = _G.UncappedDashboard
    if not Dashboard then
        DEFAULT_CHAT_FRAME:AddMessage(COLOR_HEAD ..
            "[Keystone]|r lives inside the Dashboard -- load UncappedDashboard to use it.")
        return
    end

    Dashboard.SetTab("keystone")
    if not (Dashboard.UI and Dashboard.UI.IsShown and Dashboard.UI.IsShown()) then
        Dashboard.Toggle()
    end
    Request()
end
