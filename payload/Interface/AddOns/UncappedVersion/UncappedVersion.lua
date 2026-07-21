--[[
    Uncapped Version -- client-side half of the version gate.

    On entering the world this reports its baked-in CLIENT_VERSION to the server
    (a whisper-to-self ADDON message, the standard client->server channel). The
    server (lua_scripts/version_gate.lua) replies:
        OLD:<n>  -> show the "out of date" window and force quit in 10s
        OK       -> nothing, carry on
    It also answers a server "REQ" nudge with its version.

    Bump CLIENT_VERSION to match REQUIRED_CLIENT_VERSION on the server for every
    release that ships a new payload. This file rides in the launcher payload,
    so an updated client automatically reports the new number; a stale client
    keeps reporting the old one and gets evicted.

    Written for the 3.3.5a client: no C_ChatInfo prefix registration, no
    BackdropTemplate, and event args are available as both parameters and the
    arg1..argN globals.
]]

local CLIENT_VERSION = 2
local PREFIX         = "UVER"
local QUIT_SECONDS   = 10

local function SendVersion()
    SendAddonMessage(PREFIX, "V:" .. CLIENT_VERSION, "WHISPER", UnitName("player"))
end

local evictionShown = false
local function ShowEviction()
    if evictionShown then return end
    evictionShown = true

    local f = CreateFrame("Frame", "UncappedVersionEvict", UIParent)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:SetWidth(440)
    f:SetHeight(150)
    f:SetPoint("CENTER", 0, 120)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 16,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    f:SetBackdropColor(0, 0, 0, 1)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -18)
    title:SetText("|cffff2020Your client is out of date|r")

    local body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    body:SetPoint("TOP", title, "BOTTOM", 0, -12)
    body:SetWidth(400)
    body:SetText("Please close the game and restart through the Uncapped launcher to update.")

    local count = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    count:SetPoint("BOTTOM", 0, 18)
    count:SetText("Closing in " .. QUIT_SECONDS .. "s...")

    -- Countdown lives on its own driver frame, independent of the dialog, so it
    -- cannot be cancelled by hiding or closing the window.
    local remaining = QUIT_SECONDS
    local acc = 0
    local driver = CreateFrame("Frame")
    driver:SetScript("OnUpdate", function(self, elapsed)
        acc = acc + (elapsed or arg1 or 0)
        if acc >= 1 then
            acc = acc - 1
            remaining = remaining - 1
            if remaining <= 0 then
                ForceQuit()
                return
            end
            count:SetText("Closing in " .. remaining .. "s...")
        end
    end)
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("CHAT_MSG_ADDON")
events:SetScript("OnEvent", function(self, evt, a1, a2)
    local e  = evt or event
    local p1 = a1 or arg1
    local p2 = a2 or arg2

    if e == "PLAYER_ENTERING_WORLD" then
        SendVersion()
        return
    end

    if e == "CHAT_MSG_ADDON" then
        if p1 ~= PREFIX then return end
        if p2 == "REQ" then
            SendVersion()
        elseif type(p2) == "string" and string.sub(p2, 1, 4) == "OLD:" then
            ShowEviction()
        end
        -- "OK" -> nothing
    end
end)
