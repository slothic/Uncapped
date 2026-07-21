--[[
    Uncapped stat display -- shows Time Manipulation and Cooldown Reduction
    inside the AllStats character-sheet panel.

    The values come from the server (lua_scripts/time_stats_feed) over the "UTS"
    addon channel. We post-hook AllStats' PrintStats so the two lines render
    alongside the rest of the stats and refresh with them -- no edits to the
    third-party AllStats addon itself.

    3.3.5a client: hooksecurefunc, arg1.. globals available.
]]

local PREFIX = "UTS"

local tmPct, cdrPct = 0, 0
local line1, line2
local hooked = false

local function RequestStats()
    SendAddonMessage(PREFIX, "REQ", "WHISPER", UnitName("player"))
end

local function Refresh()
    if not AllStatsFrame then return end
    if not line1 then
        line1 = AllStatsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        line1:SetPoint("BOTTOMLEFT", AllStatsFrame, "BOTTOMLEFT", 14, 26)
        line2 = AllStatsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        line2:SetPoint("BOTTOMLEFT", AllStatsFrame, "BOTTOMLEFT", 14, 12)
    end
    line1:SetText(string.format("|cff66ccffTime Manipulation:|r %d%%", math.floor(tmPct * 100 + 0.5)))
    line2:SetText(string.format("|cff66ccffCooldown Reduction:|r %d%%", math.floor(cdrPct * 100 + 0.5)))
end

local function TryHook()
    if hooked then return end
    if type(PrintStats) == "function" then
        hooksecurefunc("PrintStats", Refresh)
        hooked = true
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:SetScript("OnEvent", function(self, e, a1, a2)
    e  = e  or event
    a1 = a1 or arg1
    a2 = a2 or arg2

    if e == "PLAYER_LOGIN" then
        TryHook()
    elseif e == "PLAYER_ENTERING_WORLD" then
        TryHook()
        RequestStats()
    elseif e == "CHAT_MSG_ADDON" then
        if a1 == PREFIX and a2 then
            local c = tonumber(string.match(a2, "CDR:([%d%.]+)"))
            local t = tonumber(string.match(a2, "TM:([%d%.]+)"))
            if c then cdrPct = c end
            if t then tmPct = t end
            Refresh()
        end
    end
end)
