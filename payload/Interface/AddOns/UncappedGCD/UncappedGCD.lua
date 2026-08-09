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
    showGcd   = true,                -- draw the global cooldown on the action bars
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
    L:Header("Action bars")
    L:Note("Draws the global cooldown sweep on your action buttons. The client cannot show this on its own here, because removing its built-in 1.5s lockout is what lets Time Manipulation shorten the GCD at all -- so this draws it back at YOUR length, not a fixed 1.5 seconds.", 40)
    panelRefreshers[#panelRefreshers + 1] = L:Check("Show global cooldown on action bars",
        function() return db.showGcd end,
        function(v) db.showGcd = v end).uncappedRefresh

    L:Gap(6)
    L:Header("Appearance")
    panelRefreshers[#panelRefreshers + 1] = L:Color("Value colour",
        function() return db.color[1], db.color[2], db.color[3] end,
        function(r, g, b) db.color = { r, g, b }; ApplyColor() end).uncappedRefresh

    UncappedGCDPanel = panel
end

-- ===========================================================================
-- THE GLOBAL COOLDOWN SWIPE.
--
-- WHY THIS EXISTS AT ALL. Haste is repurposed on this realm, and the global
-- cooldown is bought back as the "Time Manipulation" stat, applied server-side.
-- The 3.3.5 client, however, runs its OWN global cooldown from Spell.dbc's
-- StartRecoveryTime and REFUSES to send a cast while that local timer is
-- running -- so a player who had bought the GCD down to 0.8s would still have
-- been told "Spell is not ready yet" for the full 1.5s. The fix was a client
-- patch zeroing StartRecoveryTime, which works, at the cost of the action-bar
-- swipe disappearing for everyone. This draws it back, at the player's REAL
-- length rather than a fixed 1.5s.
--
-- WHERE THE NUMBERS COME FROM. The patch zeroes StartRecoveryTime but leaves
-- StartRecoveryCategory alone, so the client still knows WHICH spells use a GCD
-- and only lost HOW LONG. The server's own Spell.dbc was never patched, so it
-- still has the durations; tools/gen_gcd.py reads them out of it and writes
-- UncappedGCD_Data.lua. That table lists only spells that DO trigger a GCD --
-- anything absent is treated as off-GCD, so an unknown or custom spell draws
-- nothing, which is exactly the behaviour players have today. Failing that way
-- round matters: a missing swipe is invisible, a phantom swipe on an ability
-- that is actually ready is a UI that lies.
--
-- Keyed by NAME, not id, because 3.3.5's UNIT_SPELLCAST_SUCCEEDED hands us a
-- name. Ranks of one ability share a GCD, so the collapse is lossless.
-- ===========================================================================

local gcdStart, gcdDuration = 0, 0
local gcdButtons              -- built lazily; nil until the first cast

-- Stock 3.3.5 bars plus the third-party bars the launcher can install. A name
-- that does not exist is simply skipped, so listing extras costs nothing.
local BUTTON_PREFIXES = {
    "ActionButton", "BonusActionButton",
    "MultiBarBottomLeftButton", "MultiBarBottomRightButton",
    "MultiBarRightButton", "MultiBarLeftButton",
    "BT4Button", "DominosActionButton",
}
local BUTTONS_PER_PREFIX = 120   -- stock bars stop at 12; Bartender/Dominos go higher

local function CollectButtons()
    gcdButtons = {}
    for _, prefix in ipairs(BUTTON_PREFIXES) do
        for i = 1, BUTTONS_PER_PREFIX do
            local btn = _G[prefix .. i]
            if btn then
                -- Stock buttons expose <name>Cooldown; LibActionButton-based bars
                -- (Bartender4, Dominos) hang it off the button as .cooldown.
                local cd = _G[prefix .. i .. "Cooldown"] or btn.cooldown
                if cd then
                    gcdButtons[#gcdButtons + 1] = { btn = btn, cd = cd }
                end
            end
        end
    end
end

local function ButtonSlot(btn)
    if btn.action then return btn.action end
    if btn.GetAttribute then return btn:GetAttribute("action") end
    return nil
end

-- Paint one button, unless a REAL cooldown longer than the GCD is already
-- running on it -- stomping that with a 1.4s swipe would hide a 5-minute
-- cooldown and is the classic way these addons go wrong.
local function ApplyToButton(entry)
    local slot = ButtonSlot(entry.btn)
    if not slot or not HasAction(slot) then return end

    local _, duration = GetActionCooldown(slot)
    if duration and duration > gcdDuration + 0.01 then return end

    -- Passing the ORIGINAL start (not "now") is what lets this be re-applied
    -- mid-GCD without the swipe jumping back to full.
    CooldownFrame_SetTimer(entry.cd, gcdStart, gcdDuration, 1)
end

local function ApplyGCD()
    if not db.showGcd then return end
    if gcdDuration <= 0 then return end
    if GetTime() >= gcdStart + gcdDuration then return end   -- already expired

    if not gcdButtons then CollectButtons() end
    for _, entry in ipairs(gcdButtons) do ApplyToButton(entry) end
end

local function StartGCD(spellName)
    if not db.showGcd then return end
    if not spellName then return end

    local base = UncappedGCD_BASE and UncappedGCD_BASE[spellName]
    if not base or base <= 0 then return end   -- off the GCD, or unknown

    -- tmPct is the Time Manipulation fraction the server sent us (0 .. 0.95).
    -- If it has not arrived yet this is simply the stock 1.5s, which is the
    -- right answer for a player with no ranks bought.
    local reduced = base * (1 - (tmPct or 0)) / 1000
    if reduced <= 0 then return end

    gcdStart, gcdDuration = GetTime(), reduced
    ApplyGCD()
end

-- The stock code repaints a button from GetActionCooldown, which knows nothing
-- about our GCD and would wipe the swipe the moment anything else changed. Put
-- it back for the remainder of the window.
if type(ActionButton_UpdateCooldown) == "function" then
    hooksecurefunc("ActionButton_UpdateCooldown", function(self)
        if not db.showGcd or gcdDuration <= 0 then return end
        if GetTime() >= gcdStart + gcdDuration then return end
        if not self then return end
        local cd = self.cooldown or (self:GetName() and _G[self:GetName() .. "Cooldown"])
        if cd then ApplyToButton({ btn = self, cd = cd }) end
    end)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
ev:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
-- Bars are rebuilt when the player changes them, so drop the cached list and
-- let the next cast re-scan rather than holding stale frames.
ev:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
ev:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
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
                if s.showGcd   ~= nil then db.showGcd   = s.showGcd   end
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
        gcdButtons = nil            -- bars may have been rebuilt on the loading screen
    elseif e == "UNIT_SPELLCAST_SUCCEEDED" then
        if a1 == "player" then StartGCD(a2) end
    elseif e == "ACTIONBAR_UPDATE_COOLDOWN" then
        ApplyGCD()                  -- repaint over the stock refresh, if ours is still live
    elseif e == "ACTIONBAR_PAGE_CHANGED" or e == "UPDATE_BONUS_ACTIONBAR" then
        gcdButtons = nil
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
