--[[
    Uncapped stat display -- shows Time Manipulation, Cooldown Reduction and
    Multicast inside the AllStats character-sheet panel, styled like the other
    rows, on an extended grey background so the section stays inside the box.

    Values come from the server (lua_scripts/time_stats_feed) over the "UTS"
    addon channel. We post-hook PrintStats so it refreshes with the panel.

    3.3.5a client: hooksecurefunc, arg1.. globals available.
]]

local PREFIX = "UTS"

local tmPct, cdrPct, mcPct = 0, 0, 0
local built  = false
local hooked = false
local tmVal, cdrVal, mcVal

local function RequestStats()
    SendAddonMessage(PREFIX, "REQ", "WHISPER", UnitName("player"))
end

-- One label(left, yellow) + value(right, green) row, matching AllStats' rows.
local function MakeRow(anchorFrame, yoff, labelText)
    local row = CreateFrame("Frame", nil, AllStatsFrame)
    row:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", 0, yoff)
    row:SetPoint("RIGHT", AllStatsFrameStatResil, "RIGHT", 0, 0)
    row:SetHeight(13)
    local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")   -- yellow label
    lbl:SetPoint("LEFT", 2, 0)
    lbl:SetText(labelText)
    local val = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    val:SetPoint("RIGHT", -2, 0)
    val:SetTextColor(0.3, 1.0, 0.3)                                            -- green value
    return row, val
end

local function ExtendBox()
    -- Grow the grey background downward so our section sits inside the box.
    if _G["UncappedStatsBg"] or not (AllStatsFrameMiddle7 and AllStatsFrameBottom) then
        return
    end
    local ext = AllStatsFrame:CreateTexture("UncappedStatsBg", "BACKGROUND")
    ext:SetTexture("Interface\\PaperDollInfoFrame\\UI-Character-StatBackground")
    ext:SetTexCoord(0, 0.8984375, 0.125, 0.1953125)     -- the repeatable middle slice
    ext:SetWidth(115)
    ext:SetHeight(64)
    ext:SetPoint("TOPLEFT", AllStatsFrameMiddle7, "BOTTOMLEFT", 0, 0)
    AllStatsFrameBottom:ClearAllPoints()
    AllStatsFrameBottom:SetPoint("TOPLEFT", ext, "BOTTOMLEFT", 0, 0)
    AllStatsFrame:SetHeight(AllStatsFrame:GetHeight() + 64)
end

local function Build()
    if built then return end
    if not (AllStatsFrame and AllStatsFrameStatResil) then return end
    built = true

    ExtendBox()

    local row1
    row1, tmVal = MakeRow(AllStatsFrameStatResil, -13, "Time Manip:")    -- gap for header
    local hdr = AllStatsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hdr:SetPoint("BOTTOM", row1, "TOP", 0, -2)
    hdr:SetText("Uncapped")

    local row2
    row2, cdrVal = MakeRow(row1, 1, "Cooldown:")
    _, mcVal = MakeRow(row2, 1, "Multicast:")
end

local function Refresh()
    Build()
    if tmVal  then tmVal:SetText(string.format("%d%%",  math.floor(tmPct  * 100 + 0.5))) end
    if cdrVal then cdrVal:SetText(string.format("%d%%", math.floor(cdrPct * 100 + 0.5))) end
    if mcVal  then mcVal:SetText(string.format("%d%%",  mcPct)) end
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
            local m = tonumber(string.match(a2, "MC:(%d+)"))
            if c then cdrPct = c end
            if t then tmPct = t end
            if m then mcPct = m end
            Refresh()
        end
    end
end)
