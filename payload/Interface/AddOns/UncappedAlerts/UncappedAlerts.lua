-- UncappedAlerts
--
-- Warns when the server announces a restart, then closes the game when the
-- server actually drops you -- so pressing Play in the launcher picks up
-- whatever changed.
--
-- WHY QUIT AT ALL: the launcher can only replace addon and patch files while
-- WoW is closed. A player who sits on the "disconnected" dialog through a
-- restart comes back on stale files and reports working features as broken.
--
-- HOW THE DISCONNECT IS DETECTED, and why it is not simpler:
--
-- WotLK has no "you were disconnected" event. The nearest signal is
-- PLAYER_LEAVING_WORLD, which also fires every time you zone into a dungeon,
-- take a portal, or change continent. Quitting on that alone would boot people
-- out of the game for walking into an instance. Watching a hidden frame's
-- OnHide has exactly the same problem -- the UI is torn down on zoning too, so
-- it cannot tell the two apart either.
--
-- So TWO conditions must both hold:
--   1. A restart was announced recently (within ARM_WINDOW).
--   2. We leave the world and do NOT come back within GRACE seconds.
--
-- Zoning satisfies (1) only by coincidence and never satisfies (2), because
-- PLAYER_ENTERING_WORLD follows within a second or two and cancels the quit.
-- A real disconnect never fires it.
--
--   /alerts          show current settings
--   /alerts sound    toggle the warning sound
--   /alerts quit     toggle auto-close on disconnect

-- How long after an announcement a disconnect is still treated as "the restart".
local ARM_WINDOW = 30 * 60
-- How long to wait for PLAYER_ENTERING_WORLD before deciding this was a real
-- disconnect rather than a loading screen. Long enough for a slow instance
-- load, short enough that nobody is left staring at a dead client.
local GRACE = 8

UncappedAlertsDB = UncappedAlertsDB or {}

local function Setting(key, fallback)
    if UncappedAlertsDB[key] == nil then
        UncappedAlertsDB[key] = fallback
    end
    return UncappedAlertsDB[key]
end

local armedUntil = 0
local leavingAt = nil

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_SYSTEM")
frame:RegisterEvent("PLAYER_LEAVING_WORLD")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

-- ForceQuit skips the logout timer, which is what we want -- the connection is
-- already gone. Quit is the graceful fallback if this client build lacks it.
local function QuitGame()
    if type(ForceQuit) == "function" then
        ForceQuit()
    elseif type(Quit) == "function" then
        Quit()
    end
end

local function Warn()
    if Setting("sound", true) then
        -- RaidWarning cuts through combat noise; the second is a backup for
        -- anyone who has raid warning sounds turned down.
        PlaySound("RaidWarning")
        PlaySoundFile("Sound\\Interface\\LevelUp.wav")
    end

    if Setting("autoQuit", true) then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Server restart announced. The game will close itself when the server goes down, so the launcher can update you.")
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Server restart announced. Close the game and relaunch to get updates.")
    end
end

frame:SetScript("OnEvent", function(self, event, msg)
    if event == "PLAYER_LOGIN" then
        Setting("sound", true)
        Setting("autoQuit", true)
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        -- Came back: this was a loading screen, not a disconnect.
        leavingAt = nil
        return
    end

    if event == "PLAYER_LEAVING_WORLD" then
        if Setting("autoQuit", true) and GetTime() < armedUntil then
            leavingAt = GetTime()
        end
        return
    end

    if event ~= "CHAT_MSG_SYSTEM" or not msg then
        return
    end

    -- Matches the server's restart announcements. Broad on purpose: a missed
    -- warning is worse than a false positive, since arming alone does nothing
    -- visible and still requires a real disconnect to act.
    local lowered = msg:lower()
    if lowered:find("restart") or lowered:find("shutdown") or lowered:find("shutting down") then
        armedUntil = GetTime() + ARM_WINDOW
        Warn()
    end
end)

frame:SetScript("OnUpdate", function()
    if not leavingAt then
        return
    end

    if GetTime() - leavingAt >= GRACE then
        leavingAt = nil
        QuitGame()
    end
end)

SLASH_UNCAPPEDALERTS1 = "/alerts"
SlashCmdList["UNCAPPEDALERTS"] = function(arg)
    arg = (arg or ""):lower():match("^%s*(%S*)")

    if arg == "sound" then
        UncappedAlertsDB.sound = not Setting("sound", true)
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Warning sound: " .. (UncappedAlertsDB.sound and "ON" or "OFF"))
    elseif arg == "quit" then
        UncappedAlertsDB.autoQuit = not Setting("autoQuit", true)
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Close game on restart-disconnect: " .. (UncappedAlertsDB.autoQuit and "ON" or "OFF"))
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped Alerts]|r sound: "
            .. (Setting("sound", true) and "ON" or "OFF")
            .. ", close on restart-disconnect: " .. (Setting("autoQuit", true) and "ON" or "OFF"))
        DEFAULT_CHAT_FRAME:AddMessage("|cff888888/alerts sound|r or |cff888888/alerts quit|r to toggle.")
    end
end
