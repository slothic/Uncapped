--[[
    Uncapped GCD -- the client half of the per-player global cooldown.

    The server ships a Spell.dbc that removes the native GCD, so the client no
    longer draws a GCD sweep. This addon redraws it, using the player's
    Time Manipulation reduction (sent by the server, lua_scripts/time_stats_feed).

    A player with 0 Time Manipulation sees a normal ~1.5s bar (the visual they
    lost); a high-TM player sees a very short one. The bar is informational --
    the server is what actually enforces the GCD.

    3.3.5a client: no C_ChatInfo, arg1.. globals available.
]]

local PREFIX   = "UTS"
local BASE_GCD = 1.5

local tmPct, cdrPct = 0, 0
local frame

local DEFAULTS = { point = "CENTER", x = 0, y = -160, w = 200, h = 14, shown = true }

local function GetDB()
    UncappedGCDDB = UncappedGCDDB or {}
    for k, v in pairs(DEFAULTS) do
        if UncappedGCDDB[k] == nil then UncappedGCDDB[k] = v end
    end
    return UncappedGCDDB
end

local function RequestStats()
    SendAddonMessage(PREFIX, "REQ", "WHISPER", UnitName("player"))
end

local function UpdateText()
    if frame and frame.txt then
        frame.txt:SetText(string.format("TM %d%%   CDR %d%%",
            math.floor(tmPct * 100 + 0.5), math.floor(cdrPct * 100 + 0.5)))
    end
end

local function Build()
    local db = GetDB()

    frame = CreateFrame("Frame", "UncappedGCDFrame", UIParent)
    frame:SetWidth(db.w)
    frame:SetHeight(db.h + 14)
    frame:SetPoint(db.point, UIParent, db.point, db.x, db.y)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function() frame:StartMoving() end)
    frame:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        local p, _, _, x, y = frame:GetPoint()
        db.point, db.x, db.y = p, x, y
    end)

    local bar = CreateFrame("StatusBar", nil, frame)
    bar:SetPoint("BOTTOM", 0, 0)
    bar:SetWidth(db.w)
    bar:SetHeight(db.h)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(0.25, 0.6, 1.0)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(0, 0, 0, 0.5)
    frame.bar = bar

    local txt = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    txt:SetPoint("BOTTOM", bar, "TOP", 0, 2)
    frame.txt = txt

    frame.endTime = 0
    frame.gcd = 0
    bar:SetScript("OnUpdate", function()
        if frame.endTime > 0 then
            local now = GetTime()
            if now >= frame.endTime then
                frame.endTime = 0
                bar:SetValue(0)
            else
                bar:SetValue(1 - (frame.endTime - now) / frame.gcd)
            end
        end
    end)

    UpdateText()
    if not db.shown then frame:Hide() end
end

local function StartGCD()
    if not frame then return end
    local gcd = BASE_GCD * (1 - tmPct)
    if gcd <= 0.05 then return end
    frame.gcd = gcd
    frame.endTime = GetTime() + gcd
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
ev:SetScript("OnEvent", function(self, e, a1, a2)
    e  = e  or event
    a1 = a1 or arg1
    a2 = a2 or arg2

    if e == "ADDON_LOADED" then
        if a1 == "UncappedGCD" then Build() end
    elseif e == "PLAYER_ENTERING_WORLD" then
        RequestStats()
    elseif e == "CHAT_MSG_ADDON" then
        if a1 == PREFIX and a2 then
            local c = tonumber(string.match(a2, "CDR:([%d%.]+)"))
            local t = tonumber(string.match(a2, "TM:([%d%.]+)"))
            if c then cdrPct = c end
            if t then tmPct = t end
            UpdateText()
        end
    elseif e == "UNIT_SPELLCAST_SUCCEEDED" then
        if a1 == "player" then StartGCD() end
    end
end)

SLASH_UGCD1 = "/ugcd"
SlashCmdList["UGCD"] = function()
    if not frame then return end
    if frame:IsShown() then
        frame:Hide(); GetDB().shown = false
    else
        frame:Show(); GetDB().shown = true
    end
end
