--[[
    Uncapped stat display -- shows Time Manipulation and Cooldown Reduction
    inside the AllStats character-sheet panel, styled like the other rows.

    Values come from the server (lua_scripts/time_stats_feed) over the "UTS"
    addon channel. We anchor a small "Uncapped" section below Resilience (the
    last AllStats row) and post-hook PrintStats so it refreshes with the panel.

    3.3.5a client: hooksecurefunc, arg1.. globals available.
]]

local PREFIX = "UTS"

local tmPct, cdrPct = 0, 0
local built  = false
local hooked = false
local tmVal, cdrVal

local function RequestStats()
    SendAddonMessage(PREFIX, "REQ", "WHISPER", UnitName("player"))
end

-- One label(left, yellow) + value(right, green) row, matching AllStats' rows.
local function MakeRow(anchorFrame, yoff)
    local row = CreateFrame("Frame", nil, AllStatsFrame)
    row:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", 0, yoff)
    row:SetPoint("RIGHT", AllStatsFrameStatResil, "RIGHT", 0, 0)
    row:SetHeight(13)
    local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")   -- yellow label
    lbl:SetPoint("LEFT", 2, 0)
    local val = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    val:SetPoint("RIGHT", -2, 0)
    val:SetTextColor(0.3, 1.0, 0.3)                                            -- green value
    return row, lbl, val
end

local function Build()
    if built then return end
    if not (AllStatsFrame and AllStatsFrameStatResil) then return end
    built = true

    local row1, lbl1, v1 = MakeRow(AllStatsFrameStatResil, -13)  -- gap for the header
    local hdr = AllStatsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hdr:SetPoint("BOTTOM", row1, "TOP", 0, -2)
    hdr:SetText("Uncapped")
    lbl1:SetText("Time Manip:")
    tmVal = v1

    local _, lbl2, v2 = MakeRow(row1, 1)
    lbl2:SetText("Cooldown:")
    cdrVal = v2
end

local function Refresh()
    Build()
    if tmVal  then tmVal:SetText(string.format("%d%%",  math.floor(tmPct  * 100 + 0.5))) end
    if cdrVal then cdrVal:SetText(string.format("%d%%", math.floor(cdrPct * 100 + 0.5))) end
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
