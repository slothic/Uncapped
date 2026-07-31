--[[
    Uncapped stat display -- shows Time Manipulation, Cooldown Reduction,
    Multicast, Alacrity and Swiftness inside the AllStats character-sheet panel,
    styled like the other rows, on an extended grey background so the section
    stays inside the box.

    Alacrity (cast speed) and Swiftness (attack speed) are bought in the Tempo
    window (/tempo, UncappedTempo); this only displays them.

    Values come from the server (lua_scripts/time_stats_feed) over the "UTS"
    addon channel. We post-hook PrintStats so it refreshes with the panel.

    Settings live under ESC > Interface > AddOns > Uncapped > Character Stats
    (via the shared UncappedUI widget library, when present): toggle each row and
    recolour the values. Row visibility applies live -- the character sheet
    reflows the moment a toggle changes.

    3.3.5a client: hooksecurefunc, arg1.. globals available.
]]

local PREFIX = "UTS"

local tmPct, cdrPct, mcPct = 0, 0, 0
local alPct, swPct = 0, 0
local built  = false
local hooked = false
local tmVal, cdrVal, mcVal, alVal, swVal
local hdr
local rows = {}
local panelRefreshers = {}

-- Live settings (defaults). Merged from SavedVariables at ADDON_LOADED; the
-- global then points at this table so edits persist.
local db = {
    showTime  = true,
    showCd    = true,
    showMulti = true,
    showAlac  = true,
    showSwift = true,
    color     = { 0.3, 1.0, 0.3 },   -- green value colour
}

local function RequestStats()
    SendAddonMessage(PREFIX, "REQ", "WHISPER", UnitName("player"))
end

-- One label(left, yellow) + value(right, coloured) row, matching AllStats' rows.
-- Placement is handled by Relayout so rows can be shown/hidden live.
local function MakeRow(labelText)
    local row = CreateFrame("Frame", nil, AllStatsFrame)
    row:SetHeight(13)
    local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")   -- yellow label
    lbl:SetPoint("LEFT", 2, 0)
    lbl:SetText(labelText)
    local val = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    val:SetPoint("RIGHT", -2, 0)
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
    ext:SetHeight(104)
    ext:SetPoint("TOPLEFT", AllStatsFrameMiddle7, "BOTTOMLEFT", 0, 0)
    AllStatsFrameBottom:ClearAllPoints()
    AllStatsFrameBottom:SetPoint("TOPLEFT", ext, "BOTTOMLEFT", 0, 0)
    AllStatsFrame:SetHeight(AllStatsFrame:GetHeight() + 104)
end

-- Apply the configured value colour to every injected value fontstring.
local function ApplyColor()
    local c = db.color
    for _, r in ipairs(rows) do
        if r.val then r.val:SetTextColor(c[1], c[2], c[3]) end
    end
end

-- Show/hide + restack the enabled rows. Anchors the "Uncapped" header above the
-- first visible row. Runs on load (via Build) and whenever a toggle changes.
local function Relayout()
    if not built then return end
    local prev = nil
    local firstVisible = nil
    for _, r in ipairs(rows) do
        r.frame:ClearAllPoints()
        r.frame:SetPoint("RIGHT", AllStatsFrameStatResil, "RIGHT", 0, 0)
        if r.get() then
            if not prev then
                -- first visible row: gap left above it for the header
                r.frame:SetPoint("TOPLEFT", AllStatsFrameStatResil, "BOTTOMLEFT", 0, -13)
                firstVisible = r.frame
            else
                r.frame:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, 1)
            end
            r.frame:Show()
            prev = r.frame
        else
            r.frame:Hide()
        end
    end
    if hdr then
        if firstVisible then
            hdr:ClearAllPoints()
            hdr:SetPoint("BOTTOM", firstVisible, "TOP", 0, -2)
            hdr:Show()
        else
            hdr:Hide()
        end
    end
end

local function Build()
    if built then return end
    if not (AllStatsFrame and AllStatsFrameStatResil) then return end
    built = true

    ExtendBox()

    local r1, v1 = MakeRow("Time Manip:")
    hdr = AllStatsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hdr:SetText("Uncapped")

    local r2, v2 = MakeRow("Cooldown:")
    local r3, v3 = MakeRow("Multicast:")
    local r4, v4 = MakeRow("Alacrity:")
    local r5, v5 = MakeRow("Swiftness:")

    tmVal, cdrVal, mcVal, alVal, swVal = v1, v2, v3, v4, v5
    rows = {
        { frame = r1, val = v1, get = function() return db.showTime  end },
        { frame = r2, val = v2, get = function() return db.showCd    end },
        { frame = r3, val = v3, get = function() return db.showMulti end },
        { frame = r4, val = v4, get = function() return db.showAlac  end },
        { frame = r5, val = v5, get = function() return db.showSwift end },
    }

    Relayout()   -- apply row visibility on load
    ApplyColor() -- apply value colour on load
end

local function Refresh()
    Build()
    if tmVal  then tmVal:SetText(string.format("%d%%",  math.floor(tmPct  * 100 + 0.5))) end
    if cdrVal then cdrVal:SetText(string.format("%d%%", math.floor(cdrPct * 100 + 0.5))) end
    if mcVal  then mcVal:SetText(string.format("%d%%",  mcPct)) end
    if alVal  then alVal:SetText(string.format("%d%%",  math.floor(alPct  * 100 + 0.5))) end
    if swVal  then swVal:SetText(string.format("%d%%",  math.floor(swPct  * 100 + 0.5))) end
end

local function TryHook()
    if hooked then return end
    if type(PrintStats) == "function" then
        hooksecurefunc("PrintStats", Refresh)
        hooked = true
    end
end

-- ===========================================================================
-- Settings page (under the shared "Uncapped" hub). Guarded: the widget library
-- is provided by another addon and may be absent.
-- ===========================================================================
if UncappedUI then
    local panel, L = UncappedUI.CreatePanel("Character Stats",
        "Show or hide the extra Uncapped rows in the character sheet's All Stats panel, and recolour their values.")

    L:Header("Rows")
    L:Note("Each toggle shows or hides its row in the All Stats panel. Changes apply immediately -- the character sheet reflows on the spot.", 28)

    panelRefreshers[#panelRefreshers + 1] = L:Check("Show Time Manipulation",
        function() return db.showTime end,
        function(v) db.showTime = v; Relayout() end).uncappedRefresh
    panelRefreshers[#panelRefreshers + 1] = L:Check("Show Cooldown Reduction",
        function() return db.showCd end,
        function(v) db.showCd = v; Relayout() end).uncappedRefresh
    panelRefreshers[#panelRefreshers + 1] = L:Check("Show Multicast %",
        function() return db.showMulti end,
        function(v) db.showMulti = v; Relayout() end).uncappedRefresh
    panelRefreshers[#panelRefreshers + 1] = L:Check("Show Alacrity (cast speed)",
        function() return db.showAlac end,
        function(v) db.showAlac = v; Relayout() end).uncappedRefresh
    panelRefreshers[#panelRefreshers + 1] = L:Check("Show Swiftness (attack speed)",
        function() return db.showSwift end,
        function(v) db.showSwift = v; Relayout() end).uncappedRefresh

    L:Gap(6)
    L:Header("Appearance")
    panelRefreshers[#panelRefreshers + 1] = L:Color("Value colour",
        function() return db.color[1], db.color[2], db.color[3] end,
        function(r, g, b) db.color = { r, g, b }; ApplyColor() end).uncappedRefresh

    UncappedGCDPanel = panel
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:SetScript("OnEvent", function(self, e, a1, a2)
    e  = e  or event
    a1 = a1 or arg1
    a2 = a2 or arg2

    if e == "ADDON_LOADED" then
        if a1 == "UncappedGCD" then
            local s = UncappedGCDDB
            if type(s) == "table" then
                if s.showTime  ~= nil then db.showTime  = s.showTime  end
                if s.showCd    ~= nil then db.showCd    = s.showCd    end
                if s.showMulti ~= nil then db.showMulti = s.showMulti end
                if s.showAlac  ~= nil then db.showAlac  = s.showAlac  end
                if s.showSwift ~= nil then db.showSwift = s.showSwift end
                if type(s.color) == "table" and s.color[1] then
                    db.color = { s.color[1], s.color[2], s.color[3] }
                end
            end
            UncappedGCDDB = db   -- persist edits to our live table
            for _, r in ipairs(panelRefreshers) do r() end
            Relayout()   -- apply loaded row visibility (no-op until Build runs)
            ApplyColor() -- apply loaded value colour
        end
    elseif e == "PLAYER_LOGIN" then
        TryHook()
    elseif e == "PLAYER_ENTERING_WORLD" then
        TryHook()
        RequestStats()
    elseif e == "CHAT_MSG_ADDON" then
        if a1 == PREFIX and a2 then
            local c = tonumber(string.match(a2, "CDR:([%d%.]+)"))
            local t = tonumber(string.match(a2, "TM:([%d%.]+)"))
            local m = tonumber(string.match(a2, "MC:(%d+)"))
            local al = tonumber(string.match(a2, "AL:([%d%.]+)"))
            local sw = tonumber(string.match(a2, "SW:([%d%.]+)"))
            if c then cdrPct = c end
            if t then tmPct = t end
            if m then mcPct = m end
            if al then alPct = al end
            if sw then swPct = sw end
            Refresh()
        end
    end
end)
