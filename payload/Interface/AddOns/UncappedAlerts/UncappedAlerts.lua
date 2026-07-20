-- UncappedAlerts
--
-- Warns when the server announces a restart and closes the game so the
-- launcher can patch you on the way back in.
--
-- WHY QUIT AT ALL: the launcher can only replace addon and patch files while
-- WoW is closed. A player who sits on the "disconnected" dialog through a
-- restart comes back on stale files and reports working features as broken.
-- Quitting is therefore mandatory -- there is deliberately no way to opt out.
--
-- WHY A COUNTDOWN, AND NOT "QUIT WHEN DISCONNECTED":
--
-- WotLK has no "you were disconnected" event. On a real disconnect the client
-- tears the in-game UI down almost immediately, so an addon waiting to confirm
-- the drop is unloaded before it can act. The quit therefore has to happen
-- BEFORE the server goes down, while the UI is alive and code is guaranteed to
-- run. The countdown is the visible warning; the quit at the end is not
-- optional.
--
--   /alerts            show settings
--   /alerts sound      toggle the warning sound
--   /alerts time <s>   set the countdown length
--   /alerts testsound  play the alert sound
--   /alerts testquit   quit right now, to check it works on your client

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

-- Warning popup. One button only -- "Quit now" to skip the wait. There is no
-- cancel: closing the game is mandatory, so the dialog cannot be dismissed and
-- the countdown quits regardless of what happens to the popup.
StaticPopupDialogs["UNCAPPED_RESTART_WARNING"] = {
    text = "Server restart incoming.\n\nThe game will close so the launcher can update you.\n\nClosing in %d seconds...",
    button1 = "Quit now",
    OnAccept = function()
        countdown = nil
        QuitGame()
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 0,
    showAlert = 1,
    preferredIndex = 3,
}

local function Warn()
    if Setting("sound", true) then
        PlayAlertSound()
    end

    countdown = Setting("countdown", DEFAULT_COUNTDOWN)
    elapsed = 0

    local popup = StaticPopup_Show("UNCAPPED_RESTART_WARNING", countdown)
    if popup then
        popup.text:SetFormattedText(StaticPopupDialogs["UNCAPPED_RESTART_WARNING"].text, countdown)
    end
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

frame:SetScript("OnUpdate", function(self, delta)
    if not countdown then
        return
    end

    elapsed = elapsed + delta
    if elapsed < 1 then
        return
    end
    elapsed = 0

    countdown = countdown - 1

    if countdown <= 0 then
        countdown = nil
        QuitGame()
        return
    end

    -- Keep the visible countdown current if the popup is up. If it is not
    -- (dismissed, replaced, whatever), the quit still lands above -- there is
    -- no path that cancels it.
    local popup = StaticPopup_FindVisible("UNCAPPED_RESTART_WARNING")
    if popup then
        popup.text:SetFormattedText(StaticPopupDialogs["UNCAPPED_RESTART_WARNING"].text, countdown)
    end
end)

-- The server sends RBQUIT:<seconds> on the addon channel a few seconds before
-- the world goes down. This is the authoritative trigger -- it carries the real
-- remaining time and needs no text parsing, unlike the built-in countdown which
-- the client renders itself from a localised string.
--
-- Filtered out of chat so "RBQUIT:5" is never visible.
ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", function(self, event, msg)
    if msg and msg:find("^RBQUIT:") then
        return true
    end
    return false
end)

local quitListener = CreateFrame("Frame")
quitListener:RegisterEvent("CHAT_MSG_CHANNEL")
quitListener:SetScript("OnEvent", function(self, event, text, sender)
    if sender ~= UnitName("player") or not text then
        return
    end

    if not text:match("^RBQUIT:(%d+)$") then
        return
    end

    countdown = nil
    StaticPopup_Hide("UNCAPPED_RESTART_WARNING")

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
            .. ", countdown " .. Setting("countdown", DEFAULT_COUNTDOWN) .. "s. The game always closes on a restart.")
        DEFAULT_CHAT_FRAME:AddMessage("|cff888888/alerts sound|r, |cff888888/alerts time <seconds>|r, |cff888888/alerts testsound|r, |cff888888/alerts testquit|r")
    end
end
