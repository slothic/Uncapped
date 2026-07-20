-- UncappedAlerts
--
-- Warns when the server announces a restart and closes the game so the
-- launcher can patch you on the way back in.
--
-- WHY QUIT AT ALL: the launcher can only replace addon and patch files while
-- WoW is closed. A player who sits on the "disconnected" dialog through a
-- restart comes back on stale files and reports working features as broken.
--
-- WHY A COUNTDOWN, AND NOT "QUIT WHEN DISCONNECTED":
--
-- Quitting on the disconnect itself sounds better and does not work. WotLK has
-- no "you were disconnected" event; the nearest signal, PLAYER_LEAVING_WORLD,
-- also fires on every zoning loading screen, so telling the two apart means
-- waiting several seconds to see whether PLAYER_ENTERING_WORLD follows. On a
-- real disconnect the client tears the in-game UI down almost immediately --
-- this addon is unloaded long before that wait elapses, so the quit never
-- runs. The delay that makes the detection correct is what stops it firing.
--
-- So the quit happens BEFORE the server goes down, while the UI is alive and
-- the code is guaranteed to execute. The countdown is visible and cancellable.
--
--   /alerts            show settings
--   /alerts sound      toggle the warning sound
--   /alerts quit       toggle auto-quit
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

-- Optional custom alert, shipped alongside the addon.
--
-- 3.3.5 plays .mp3 and .ogg from an addon folder, but only if the file is
-- present when the client STARTS -- there is no runtime loading. The launcher
-- ships whatever sits in the addon directory, so dropping a file in and
-- publishing is all that is required.
--
-- The built-in RaidWarning always plays first. There is no way to ask the
-- client whether a sound file exists, and a missing file fails silently, so
-- the guaranteed-audible sound goes first and the custom one layers on top.
local CUSTOM_ALERT = "Interface\\AddOns\\UncappedAlerts\\alert.mp3"

local function PlayAlertSound()
    PlaySound("RaidWarning")
    PlaySoundFile(CUSTOM_ALERT)
end

StaticPopupDialogs["UNCAPPED_RESTART_WARNING"] = {
    text = "Server restart incoming.\n\nClosing the game lets the launcher update you.\n\nQuitting in %d seconds...",
    button1 = "Quit now",
    button2 = "Stay logged in",
    OnAccept = function()
        countdown = nil
        QuitGame()
    end,
    OnCancel = function()
        countdown = nil
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Auto-quit cancelled. Restart via the launcher so your files update.")
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

    if not Setting("autoQuit", true) then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Server restart announced. Close the game and relaunch to get updates.")
        return
    end

    -- A local countdown still runs as a visible warning and a fallback, but the
    -- server's RBQUIT signal is what actually closes the game -- it fires on the
    -- real shutdown timer rather than on a guess made from an announcement.
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
        Setting("autoQuit", true)
        Setting("countdown", DEFAULT_COUNTDOWN)
        return
    end

    if event ~= "CHAT_MSG_SYSTEM" or not msg then
        return
    end

    -- Matches the server's restart announcements. Broad on purpose: a missed
    -- warning is worse than a false positive, and the popup is easily
    -- cancelled. Repeats are ignored while a countdown is already running, so
    -- the announcement spam does not restart the timer over and over.
    local lowered = msg:lower()
    if countdown then
        return
    end

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

    local popup = StaticPopup_FindVisible("UNCAPPED_RESTART_WARNING")
    if not popup then
        -- Dismissed some other way; treat that as "leave me alone".
        countdown = nil
        return
    end

    if countdown <= 0 then
        countdown = nil
        QuitGame()
        return
    end

    popup.text:SetFormattedText(StaticPopupDialogs["UNCAPPED_RESTART_WARNING"].text, countdown)
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

    local seconds = text:match("^RBQUIT:(%d+)$")
    if not seconds then
        return
    end

    if not Setting("autoQuit", true) then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Server going down in " .. seconds .. "s. Close the game and relaunch to get updates.")
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

    elseif cmd == "quit" then
        UncappedAlertsDB.autoQuit = not Setting("autoQuit", true)
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Auto-quit on restart: " .. (UncappedAlertsDB.autoQuit and "ON" or "OFF"))

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
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Played the alert. If you only heard the default warning, alert.mp3 is missing from the addon folder.")

    elseif cmd == "testquit" then
        -- Deliberately immediate and undocumented in the tooltip: the only way
        -- to find out whether this client will actually close is to try it.
        local used = QuitGame()
        if not used then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff5555[Uncapped]|r No quit function available on this client -- auto-quit cannot work here.")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Called " .. used .. "(). If you are reading this, it did nothing.")
        end

    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped Alerts]|r sound: "
            .. (Setting("sound", true) and "ON" or "OFF")
            .. ", auto-quit: " .. (Setting("autoQuit", true) and "ON" or "OFF")
            .. " (" .. Setting("countdown", DEFAULT_COUNTDOWN) .. "s)")
        DEFAULT_CHAT_FRAME:AddMessage("|cff888888/alerts sound|r, |cff888888/alerts quit|r, |cff888888/alerts time <seconds>|r, |cff888888/alerts testsound|r, |cff888888/alerts testquit|r")
    end
end
