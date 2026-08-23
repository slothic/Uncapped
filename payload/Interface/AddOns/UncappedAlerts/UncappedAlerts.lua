-- UncappedAlerts
--
-- Warns when the server announces a restart, and closes the game when -- and
-- only when -- the restart ships a new client payload.
--
-- TWO MODES. The server tells us which one applies (UMODE:U / UMODE:N):
--
--   update    The launcher can only replace addon and patch files while WoW is
--             closed. A player who sits on the "disconnected" dialog through
--             this kind of restart comes back on stale files and then reports
--             working features as broken. Quitting is mandatory here -- there is
--             deliberately no way to opt out.
--
--   noupdate  A plain restart with nothing new to download. Warn them so they
--             are not caught mid-fight, then get out of the way: there is no
--             reason to close a client that has nothing to update, and making
--             people relaunch for no benefit is exactly the frustration this
--             mode exists to remove.
--
-- Defaults to `update` when the server has said nothing. Coming back on stale
-- files is the bad failure; an unnecessary relaunch is merely annoying.
--
-- WHY A COUNTDOWN, AND NOT "QUIT WHEN DISCONNECTED":
--
-- WotLK has no "you were disconnected" event. On a real disconnect the client
-- tears the in-game UI down almost immediately, so an addon waiting to confirm
-- the drop is unloaded before it can act. The quit therefore has to happen
-- BEFORE the server goes down, while the UI is alive and code is guaranteed to
-- run. The countdown is the visible warning; in `update` mode the quit at the
-- end is not optional.
--
--   /alerts            show settings
--   /alerts sound      toggle the warning sound
--   /alerts time <s>   set the countdown length
--   /alerts test       preview the warning window (15s, current mode)
--   /alerts reset      move the window and bar back to their default spots
--   /alerts testsound  play the alert sound
--   /alerts testquit   quit right now, to check it works on your client


--[[
    KitButton -- the in-house widget kit's button, with a guarded fall back to
    the raw Blizzard template.

    Guarded rather than calling UncappedUIKit directly because this addon lists
    UncappedUI as an OPTIONAL dependency: if it is absent or errored during load,
    an unguarded call is a nil index at build time and the whole window dies.
    Same shape as the fallback in UncappedKeystoneRun.

    ⚠ Resolved at FILE SCOPE on purpose. A `local UIKit` declared partway down
      and used above that line silently reads the nil GLOBAL of the same name --
      it parses fine and only errors when the window opens.
]]
local UIKit = _G.UncappedUIKit
local function KitButton(parent, label, w, h)
    if UIKit and UIKit.CreateButton then
        return UIKit.CreateButton(parent, label or "", w, h)
    end
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    if w then b:SetWidth(w) end
    if h then b:SetHeight(h) end
    b:SetText(label or "")
    return b
end

local DEFAULT_COUNTDOWN = 45

UncappedAlertsDB = UncappedAlertsDB or {}

local function Setting(key, fallback)
    if UncappedAlertsDB[key] == nil then
        UncappedAlertsDB[key] = fallback
    end
    return UncappedAlertsDB[key]
end

local countdown = nil
local elapsed = 0

-- The countdown ticker is ATTACHED only while a countdown is running, and torn
-- down the moment it ends. `frame` below is parented to UIParent and shown, so a
-- permanently-installed OnUpdate would run every single frame for the whole
-- session just to evaluate "if not countdown then return end" -- and `countdown`
-- is non-nil only for the few seconds before a realm restart. Same
-- self-cancelling shape UncappedChat.lua uses for its login retry.
-- Forward-declared: the ticker needs helpers defined further down, but the
-- window's "Quit now" button (above it) has to be able to stop it.
local StartCountdown, StopCountdown

-- Set when the settings page is built (below). Lets the /alerts commands repaint
-- an already-open page so the checkbox/slider never show a stale value.
local RefreshAlertsPanel = nil

-- Set from the server's UMODE line. Not saved between sessions: it describes
-- one specific restart, and a stale value from last week is worse than the
-- default.
local restartNeedsUpdate = true

local frame = CreateFrame("Frame")

-- Every way this client might be persuaded to exit, in order of preference.
-- ForceQuit skips the logout timer. Quit is the ordinary exit. Logout at least
-- gets the player to the character screen, which still releases the addon files
-- the launcher wants to replace.
local function QuitGame()
    if type(ForceQuit) == "function" then
        ForceQuit()
        return "ForceQuit"
    elseif type(Quit) == "function" then
        Quit()
        return "Quit"
    elseif type(Logout) == "function" then
        Logout()
        return "Logout"
    end

    return nil
end

-- The custom alert, shipped alongside the addon as alert.mp3.
--
-- 3.3.5 plays .mp3 and .ogg from an addon folder, but only if the file is
-- present when the client STARTS -- there is no runtime loading. The launcher
-- ships whatever sits in the addon directory, so the file simply being here is
-- enough.
local CUSTOM_ALERT = "Interface\\AddOns\\UncappedAlerts\\alert.mp3"

local function PlayAlertSound()
    PlaySoundFile(CUSTOM_ALERT)
end

-- ===========================================================================
-- The restart window.
--
-- This used to be a StaticPopup, which was the wrong tool. A StaticPopup lands
-- dead centre, cannot be moved, and in `update` mode had hideOnEscape = 0 and a
-- single "Quit now" button -- so a player who got one mid-fight had a modal box
-- sitting over their action bars for the full countdown with no way to push it
-- aside, and the only button on offer read as "end my session immediately".
--
-- The replacement is an ordinary movable frame:
--
--   * drag it anywhere; the position is remembered per character.
--   * Escape, the [X], or "Hide" collapse it to a small countdown bar that can
--     itself be dragged and clicked to restore. Nothing is ever stuck in front
--     of your screen.
--   * hiding NEVER cancels anything. In `update` mode the quit still lands, and
--     the window says so plainly rather than relying on being unclosable. It
--     also forces itself back at the last-call mark so a minimised window can
--     never let the client close unannounced.
--   * the countdown is a real clock (m:ss) that recolours as it runs down,
--     instead of a number buried in a sentence.
-- ===========================================================================

-- Re-assert a hidden window at this many seconds left, so nobody is surprised.
local LAST_CALL_SECONDS = 10

local TEXT_UPDATE   = "This restart ships a client update, so the game will close itself when the countdown ends. The launcher will patch you and you can log straight back in."
local TEXT_NOUPDATE = "Nothing to download -- your game will stay open. The realm will drop briefly and you can log straight back in once it is up."

local HINT_UPDATE   = "Closing is required for this update. Hiding this window will not stop it."
local HINT_NOUPDATE = "You can dismiss this safely."

local restartWindow, restartBar
local suppressBar = false

local function BodyText()
    return restartNeedsUpdate and TEXT_UPDATE or TEXT_NOUPDATE
end

local function ClockText(seconds)
    if seconds >= 60 then
        return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
    end
    return string.format("%d", seconds)
end

-- Green while there is time, amber as it gets close, red at last call.
local function ClockColour(seconds)
    if seconds <= LAST_CALL_SECONDS then
        return 1.0, 0.35, 0.35
    elseif seconds <= 30 then
        return 1.0, 0.82, 0.0
    end
    return 0.45, 1.0, 0.45
end

local function SavePos(frame, key)
    local point, _, relativePoint, x, y = frame:GetPoint()
    UncappedAlertsDB[key] = { point = point, relativePoint = relativePoint, x = x, y = y }
end

local function RestorePos(frame, key, default)
    local p = UncappedAlertsDB[key]
    frame:ClearAllPoints()
    if p and p.point then
        frame:SetPoint(p.point, UIParent, p.relativePoint or p.point, p.x or 0, p.y or 0)
    else
        frame:SetPoint(default.point, UIParent, default.point, default.x, default.y)
    end

    -- Player window zoom, hooked in here rather than at each call site: both of
    -- this addon's frames (the restart window and the minimised bar) go through
    -- RestorePos, and this is the first moment either has an anchor for the zoom
    -- system to rewrite. Registering the same frame twice just refreshes it.
    --
    -- savePosition reuses SavePos so a zoom change persists the same shape a
    -- drag does; without it the pre-zoom offsets would be restored on the next
    -- login and the window would appear to have moved on its own.
    if UncappedScale_Register then
        UncappedScale_Register(frame, {
            group = "alerts",
            savePosition = function(self) SavePos(self, key) end,
        })
    end
end

local WINDOW_DEFAULT = { point = "CENTER", x = 0, y = 180 }
local BAR_DEFAULT    = { point = "TOP",    x = 0, y = -120 }

local function MakeDraggable(frame, key)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePos(self, key)
    end)
end

local function BuildBar()
    local bar = CreateFrame("Button", "UncappedRestartBar", UIParent)
    bar:SetWidth(190)
    bar:SetHeight(34)
    bar:SetFrameStrata("DIALOG")
    bar:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    MakeDraggable(bar, "barPos")
    RestorePos(bar, "barPos", BAR_DEFAULT)

    bar.label = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bar.label:SetPoint("LEFT", bar, "LEFT", 10, 0)
    bar.label:SetText("Restart in")

    bar.clock = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    bar.clock:SetPoint("RIGHT", bar, "RIGHT", -10, 0)

    bar:SetScript("OnClick", function()
        bar:Hide()
        if restartWindow then
            restartWindow:Show()
        end
    end)
    bar:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Server restart")
        GameTooltip:AddLine("Click to reopen the details. Drag to move.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    bar:SetScript("OnLeave", function() GameTooltip:Hide() end)
    bar:Hide()

    return bar
end

local function BuildWindow()
    local f = CreateFrame("Frame", "UncappedRestartWindow", UIParent)
    f:SetWidth(400)
    f:SetHeight(215)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    MakeDraggable(f, "windowPos")
    RestorePos(f, "windowPos", WINDOW_DEFAULT)

    -- Escape closes it. UISpecialFrames only calls Hide(), and OnHide below is
    -- what turns any hide -- Escape, [X] or the button -- into the minimised
    -- bar, so all three routes behave identically.
    tinsert(UISpecialFrames, "UncappedRestartWindow")

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", f, "TOP", 0, -18)
    f.title:SetText("Server Restart")

    f.clock = f:CreateFontString(nil, "OVERLAY", "NumberFontNormalHuge")
    f.clock:SetPoint("TOP", f.title, "BOTTOM", 0, -10)

    f.body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.body:SetPoint("TOP", f.clock, "BOTTOM", 0, -12)
    f.body:SetWidth(340)
    f.body:SetJustifyH("CENTER")

    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.hint:SetPoint("BOTTOM", f, "BOTTOM", 0, 48)
    f.hint:SetWidth(340)
    f.hint:SetJustifyH("CENTER")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

    f.primary = KitButton(f, "", 130, 22)
    f.primary:SetPoint("BOTTOMLEFT", f, "BOTTOM", 6, 18)

    f.secondary = KitButton(f, "", 130, 22)
    f.secondary:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -6, 18)

    -- Any hide while a countdown is live becomes a minimise, unless something
    -- deliberately closed us for good (dismissed, or the countdown finished).
    f:SetScript("OnHide", function()
        if countdown and not suppressBar and restartBar then
            restartBar:Show()
        end
    end)

    f:Hide()
    return f
end

local function CloseRestartUI()
    suppressBar = true
    if restartWindow then
        restartWindow:Hide()
    end
    if restartBar then
        restartBar:Hide()
    end
    suppressBar = false
end

local function MinimiseRestartUI()
    if restartWindow then
        restartWindow:Hide()   -- OnHide raises the bar
    end
end

-- Repaint everything that depends on the mode. Called both when the window
-- opens and when a late UMODE line arrives mid-countdown, so the wording can
-- never disagree with what is about to happen.
local function ApplyPopupMode()
    if not restartWindow then
        return
    end

    restartWindow.body:SetText(BodyText())

    if restartNeedsUpdate then
        restartWindow.hint:SetText(HINT_UPDATE)
        restartWindow.primary:SetText("Quit now")
        restartWindow.primary:Show()
        restartWindow.primary:SetScript("OnClick", function()
            StopCountdown()
            CloseRestartUI()
            QuitGame()
        end)
        restartWindow.secondary:SetText("Hide")
        restartWindow.secondary:SetScript("OnClick", MinimiseRestartUI)
        restartWindow.secondary:ClearAllPoints()
        restartWindow.secondary:SetPoint("BOTTOMRIGHT", restartWindow, "BOTTOM", -6, 18)
    else
        -- Nothing is mandatory here, so there is no destructive button at all:
        -- one clear way out, centred.
        restartWindow.hint:SetText(HINT_NOUPDATE)
        restartWindow.primary:Hide()
        restartWindow.secondary:SetText("Dismiss")
        restartWindow.secondary:SetScript("OnClick", CloseRestartUI)
        restartWindow.secondary:ClearAllPoints()
        restartWindow.secondary:SetPoint("BOTTOM", restartWindow, "BOTTOM", 0, 18)
    end
end

local function RefreshPopup()
    if not countdown or not restartWindow then
        return
    end

    local text = ClockText(countdown)
    local r, g, b = ClockColour(countdown)

    restartWindow.clock:SetText(text)
    restartWindow.clock:SetTextColor(r, g, b)

    if restartBar then
        restartBar.clock:SetText(text)
        restartBar.clock:SetTextColor(r, g, b)
    end

    -- Last call: a minimised window must not let the client close unannounced.
    if restartNeedsUpdate and countdown == LAST_CALL_SECONDS and not restartWindow:IsShown() then
        if restartBar then
            restartBar:Hide()
        end
        restartWindow:Show()
    end
end

local function Warn()
    if Setting("sound", true) then
        PlayAlertSound()
    end

    StartCountdown(Setting("countdown", DEFAULT_COUNTDOWN))

    if not restartWindow then
        restartBar = BuildBar()
        restartWindow = BuildWindow()
    end

    ApplyPopupMode()

    if restartBar then
        restartBar:Hide()
    end
    restartWindow:Show()
    RefreshPopup()
end

frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_SYSTEM")

frame:SetScript("OnEvent", function(self, event, msg)
    if event == "PLAYER_LOGIN" then
        Setting("sound", true)
        Setting("countdown", DEFAULT_COUNTDOWN)
        return
    end

    if event ~= "CHAT_MSG_SYSTEM" or not msg then
        return
    end

    -- Matches the server's restart announcements. Broad on purpose: a missed
    -- warning is worse than a false positive. Repeats are ignored while a
    -- countdown is already running.
    if countdown then
        return
    end

    local lowered = msg:lower()
    if lowered:find("restart") or lowered:find("shutdown") or lowered:find("shutting down") then
        Warn()
    end
end)

local function CountdownTick(self, delta)
    if not countdown then
        -- Belt and braces: StopCountdown detaches this, so this branch should be
        -- unreachable. Keeping it means a missed detach degrades to the old
        -- always-on behaviour rather than an error.
        return
    end

    elapsed = elapsed + delta
    if elapsed < 1 then
        return
    end
    elapsed = 0

    countdown = countdown - 1

    if countdown <= 0 then
        StopCountdown()
        -- Clear the UI in BOTH modes. The old code only hid it on the noupdate
        -- path, because in update mode the client was about to vanish anyway --
        -- but QuitGame() can legitimately do nothing (no quit function on this
        -- client, see /alerts testquit), and that left a frozen "0" on screen
        -- forever with no way to dismiss it.
        CloseRestartUI()
        if restartNeedsUpdate then
            QuitGame()
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Restarting now -- no update needed, so log back in when the realm is up.")
        end
        return
    end

    -- Keep the visible countdown current, whether the window is open or
    -- minimised to the bar. Neither hiding route cancels anything: the
    -- update-mode quit still lands above.
    RefreshPopup()
end

StartCountdown = function(seconds)
    countdown = seconds
    elapsed = 0
    frame:SetScript("OnUpdate", CountdownTick)
end

StopCountdown = function()
    countdown = nil
    frame:SetScript("OnUpdate", nil)
end

-- Server -> client lines on the addon channel:
--   UMODE:U / UMODE:N   sent when a countdown starts; says whether this
--                         restart ships a new payload.
--   UQUIT:<seconds>      sent a few seconds before the world goes down, in
--                         update mode only. Authoritative: it carries the real
--                         remaining time and needs no text parsing, unlike the
--                         built-in countdown which the client renders itself
--                         from a localised string.
--
-- Prefix for the whole server->client pipe (see the transport note below).
local ADDON_PIPE_PREFIX = "UNC"

local quitListener = CreateFrame("Frame")
quitListener:RegisterEvent("CHAT_MSG_ADDON")
quitListener:SetScript("OnEvent", function(self, event, a1, a2)
    -- ONE transport. The per-player chat channel this used to also listen on was
    -- retired when the server moved the whole UNC pipe to CHAT_MSG_ADDON
    -- (ReagentBankChannelProtocol.cpp:79-96 -- SendResponse is now the only
    -- sender and it never Say()s). The channel branch and the CHAT_MSG_CHANNEL
    -- chat filter are gone: an addon message is never rendered, so there is
    -- nothing left to filter, and the dead filter was running on every real
    -- World-chat line.
    --
    --   CHAT_MSG_ADDON : a1 = prefix, a2 = body
    if a1 ~= ADDON_PIPE_PREFIX then return end
    local text = a2
    if not text then
        return
    end

    local mode = text:match("^UMODE:(%a)$")
    if mode then
        restartNeedsUpdate = (mode == "U")
        -- A countdown may already be running off the chat announcement, so
        -- repaint it rather than leaving the wrong wording on screen.
        ApplyPopupMode()
        RefreshPopup()
        return
    end

    if not text:match("^UQUIT:(%d+)$") then
        return
    end

    StopCountdown()
    CloseRestartUI()

    if Setting("sound", true) then
        PlayAlertSound()
    end

    QuitGame()
end)

SLASH_UNCAPPEDALERTS1 = "/alerts"
SlashCmdList["UNCAPPEDALERTS"] = function(arg)
    arg = (arg or ""):lower()
    local cmd, rest = arg:match("^%s*(%S*)%s*(.*)$")

    if cmd == "sound" then
        UncappedAlertsDB.sound = not Setting("sound", true)
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Warning sound: " .. (UncappedAlertsDB.sound and "ON" or "OFF"))

    elseif cmd == "time" then
        local seconds = tonumber(rest)
        if seconds and seconds >= 5 and seconds <= 600 then
            UncappedAlertsDB.countdown = math.floor(seconds)
            DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Countdown set to " .. UncappedAlertsDB.countdown .. "s.")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff5555[Uncapped]|r Give a number of seconds between 5 and 600.")
        end

    elseif cmd == "test" then
        -- Preview the real window, in whichever mode the server last set, with
        -- a short countdown. The only honest way to check the wording, the
        -- position and the minimise behaviour without waiting for a deploy --
        -- and in noupdate mode nothing closes at the end, so it is safe.
        StartCountdown(15)
        if not restartWindow then
            restartBar = BuildBar()
            restartWindow = BuildWindow()
        end
        ApplyPopupMode()
        restartBar:Hide()
        restartWindow:Show()
        RefreshPopup()
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Previewing the restart window in "
            .. (restartNeedsUpdate and "|cffff5555update|r (it WILL close the game at zero)" or "|cff55ff55no-update|r") .. " mode.")

    elseif cmd == "reset" then
        UncappedAlertsDB.windowPos = nil
        UncappedAlertsDB.barPos = nil
        if restartWindow then
            RestorePos(restartWindow, "windowPos", WINDOW_DEFAULT)
        end
        if restartBar then
            RestorePos(restartBar, "barPos", BAR_DEFAULT)
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Restart window position reset.")

    elseif cmd == "testsound" then
        PlayAlertSound()
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Played the alert. If you heard nothing, alert.mp3 is missing from the addon folder.")

    elseif cmd == "testquit" then
        -- Immediate: the only way to know whether this client will actually
        -- close is to try it.
        local used = QuitGame()
        if not used then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff5555[Uncapped]|r No quit function available on this client -- auto-quit cannot work here.")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Called " .. used .. "(). If you are reading this, it did nothing.")
        end

    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped Alerts]|r sound: "
            .. (Setting("sound", true) and "ON" or "OFF")
            .. ", countdown " .. Setting("countdown", DEFAULT_COUNTDOWN) .. "s.")
        DEFAULT_CHAT_FRAME:AddMessage("|cff888888The game only closes on a restart that ships a client update; the server says which.|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cff888888The warning window can be dragged, and Escape or Hide shrinks it to a small bar you can click to reopen.|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cff888888/alerts sound|r, |cff888888/alerts time <seconds>|r, |cff888888/alerts test|r, |cff888888/alerts reset|r, |cff888888/alerts testsound|r, |cff888888/alerts testquit|r")
    end

    -- Keep an open settings page in step with changes made via chat command.
    if RefreshAlertsPanel then
        RefreshAlertsPanel()
    end
end

-- ===========================================================================
-- Settings page (ESC > Interface > AddOns > Uncapped > Alerts).
--
-- Built with the shared UncappedUI library, which the UncappedOptions addon
-- provides at runtime. Guarded so UncappedAlerts still loads standalone if that
-- addon is absent. Every knob drives the same UncappedAlertsDB keys and helpers
-- the /alerts commands use, so the two stay in sync.
--
-- Deliberately NOT exposed: the update-mode auto-quit. Coming back on stale
-- client files is the failure this addon exists to prevent, so it must not be
-- switchable off.
-- ===========================================================================
if UncappedUI then
    -- Default "Land Here" button placement, mirroring TaxiCancel.lua's fallback.
    local TAXI_DEFAULT = { point = "TOP", relativePoint = "TOP", x = 0, y = -180 }

    local panel, L = UncappedUI.CreatePanel("Alerts",
        "Restart warnings and the Land Here flight-cancel button.")

    L:Header("Restart warnings")
    L:Note("When the server announces a restart, a countdown warns you so you are not caught mid-fight. Drag the window anywhere, or press Escape to shrink it to a small bar you can click to reopen -- it will never sit in your way. If the restart ships a client update the game closes at the end so the launcher can patch you; that part is mandatory and hiding the window does not stop it.", 56)

    local soundCheck = L:Check("Play restart-warning sound",
        function() return Setting("sound", true) end,
        function(v) UncappedAlertsDB.sound = v end)

    local countSlider = L:Slider("Restart warning countdown (seconds)", 5, 600, 5,
        function() return Setting("countdown", DEFAULT_COUNTDOWN) end,
        function(v) UncappedAlertsDB.countdown = v end,
        "%d")

    L:Button("Test warning sound", function()
        PlayAlertSound()
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Played the alert. If you heard nothing, alert.mp3 is missing from the addon folder.")
    end, 180)

    L:Gap(6)
    L:Header("Land Here button")
    L:Note("The Land Here button appears while you are flying and is draggable. If you have lost track of it, reset it to its default spot below the minimap.", 32)

    L:Button("Reset 'Land Here' button position", function()
        UncappedAlertsDB.taxiButtonPos = { point = TAXI_DEFAULT.point, relativePoint = TAXI_DEFAULT.relativePoint, x = TAXI_DEFAULT.x, y = TAXI_DEFAULT.y }
        local btn = _G.UncappedLandHereButton
        if btn then
            btn:ClearAllPoints()
            btn:SetPoint(TAXI_DEFAULT.point, UIParent, TAXI_DEFAULT.relativePoint, TAXI_DEFAULT.x, TAXI_DEFAULT.y)
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Land Here button reset to its default position.")
    end, 240)

    -- Let the /alerts commands repaint these when they change the same values.
    RefreshAlertsPanel = function()
        soundCheck.uncappedRefresh()
        countSlider.uncappedRefresh()
    end

    UncappedAlertsPanel = panel
end
