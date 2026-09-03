--[[
    Uncapped stat display -- shows Time Manipulation, Cooldown Reduction,
    Multicast, Alacrity and Swiftness inside the AllStats character-sheet panel,
    styled like the other rows, on an extended grey background so the section
    stays inside the box.

    Alacrity (cast speed) and Swiftness (attack speed) are bought on the Tempo
    tab of the Anima window (/dashboard, UncappedAnima); this only displays them.

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
--
-- ★ REPORT #392 -- THE SWEEP IS GLOBAL, THE ABILITIES ARE NOT.
--
-- A global cooldown is drawn on every button at once, which is what ApplyGCD
-- does, and that was wrong for the abilities that are off it. Heroic Strike,
-- Cleave, Maul and Raptor Strike replace your next melee swing: they cost no
-- global cooldown and stay pressable *during* one, and so do the interrupts,
-- the stances, Vanish, Sprint and the racials. Painting them made a warrior
-- believe his rotation had a lockout it never had -- and the report is worth
-- reading precisely: nothing on the server had changed, only the picture.
--
-- The server is not involved either way. Every rank of Heroic Strike and
-- Cleave in the server's own Spell.dbc carries StartRecoveryCategory = 0 and
-- StartRecoveryTime = 0, so Spell::TriggerGlobalCooldown returns without
-- starting anything; the client's copy has StartRecoveryTime zeroed outright.
-- There was no global cooldown anywhere in the stack -- only this addon's swipe.
--
-- UncappedGCD_OFFGCD names those abilities. The lookup is by BUTTON, not by
-- cast, so it also covers the far commoner half of the report: casting Mortal
-- Strike used to paint a swipe over the Heroic Strike sitting next to it.
-- ===========================================================================

local gcdStart, gcdDuration = 0, 0
local gcdExpiry = 0           -- gcdStart + gcdDuration, so the hot path adds nothing
local gcdButtons              -- built lazily; nil until the first cast
local gcdForeign = {}         -- ★ [AN-11] the subset Blizzard does NOT repaint for us
local offGcdSlot = {}         -- ACTION SLOT -> true/false. Slot-keyed, so paging never invalidates it
local macroSlots = {}         -- ⚠ the slots whose name CAN change without a slot-changed event
local cdOf = setmetatable({}, { __mode = "k" })   -- button frame -> its cooldown frame, resolved once

-- Reading what an action slot HOLDS is awkward on 3.3.5 -- GetActionInfo hands
-- back a spellbook index rather than a spell id, and says nothing useful about
-- a macro. A hidden tooltip answers all three cases with the name the player
-- actually sees, which is the key UncappedGCD_OFFGCD is written in.
local scanTip = CreateFrame("GameTooltip", "UncappedGCDScanTip", UIParent, "GameTooltipTemplate")
scanTip:SetOwner(UIParent, "ANCHOR_NONE")

-- Cached per slot: a tooltip scan per button per cast would be far too much
-- work for something that only changes when the player rearranges a bar.
local function SlotIsOffGcd(slot)
    local cached = offGcdSlot[slot]
    if cached ~= nil then return cached end

    local off, read = false, false
    -- Guarded on the API as well as the table: if either is missing this answers
    -- "not off-GCD", which is the behaviour that shipped, rather than erroring.
    if UncappedGCD_OFFGCD and type(scanTip.SetAction) == "function" then
        scanTip:SetOwner(UIParent, "ANCHOR_NONE")
        scanTip:ClearLines()
        scanTip:SetAction(slot)
        local line = _G["UncappedGCDScanTipTextLeft1"]
        local name = line and line:GetText()
        if name then
            read = true
            if UncappedGCD_OFFGCD[name] then off = true end
        end
    end

    -- ⚠ NEVER CACHE A SCAN THAT READ NOTHING. A slot asked before the client has its
    -- action data -- straight off a loading screen, or mid bar-rebuild -- yields an
    -- empty tooltip, and the old code filed that silence as "not off-GCD" and kept it.
    -- That is report #392 restored by accident: a permanent phantom swipe over a
    -- Heroic Strike that was never on the global cooldown. Leaving a miss uncached
    -- costs one re-scan.
    if read then
        offGcdSlot[slot] = off
        -- ⚠ A macro is the one action whose NAME changes with no ACTIONBAR_SLOT_CHANGED
        -- behind it: /castsequence steps, and #showtooltip resolves per stance. Remember
        -- which slots those are, so a stance change can re-ask the handful that can
        -- actually have changed instead of wiping all 120.
        if GetActionText and GetActionText(slot) then macroSlots[slot] = true end
    end
    return off
end

-- Stock 3.3.5 bars plus the third-party bars the launcher can install. A name
-- that does not exist is simply skipped, so listing extras costs nothing.
local BUTTON_PREFIXES = {
    "ActionButton", "BonusActionButton",
    "MultiBarBottomLeftButton", "MultiBarBottomRightButton",
    "MultiBarRightButton", "MultiBarLeftButton",
    "BT4Button", "DominosActionButton",
}
local BUTTONS_PER_PREFIX = 120   -- stock bars stop at 12; Bartender/Dominos go higher
-- ★ [AN-13] Button names are contiguous inside a prefix -- stock runs 1..12, Dominos
-- hands out DominosActionButton1..N in order -- so the scan stops after a short run of
-- misses instead of asking the global table for all 8 x 120 names, nine in ten of which
-- have never existed on any client. The tolerance is 4 rather than 1 purely so a bar
-- addon that skips an index cannot silently truncate the list.
local GAP_TOLERANCE = 4

local function CollectButtons()
    gcdButtons, gcdForeign = {}, {}
    for k in pairs(cdOf) do cdOf[k] = nil end
    for _, prefix in ipairs(BUTTON_PREFIXES) do
        local misses = 0
        for i = 1, BUTTONS_PER_PREFIX do
            local btn = _G[prefix .. i]
            if btn then
                misses = 0
                -- Stock buttons expose <name>Cooldown; LibActionButton-based bars
                -- (Bartender4) hang it off the button as .cooldown.
                local named = _G[prefix .. i .. "Cooldown"]
                local cd = named or btn.cooldown
                if cd then
                    local entry = { btn = btn, cd = cd }
                    gcdButtons[#gcdButtons + 1] = entry
                    cdOf[btn] = cd
                    -- ★ [AN-11] A <name>Cooldown child means the button came from
                    -- ActionBarButtonTemplate, so Blizzard's ActionButton_UpdateCooldown
                    -- repaints it and our hook paints back on top of that -- it must NOT
                    -- also be swept. Dominos re-uses the stock buttons for slots 1-72 and
                    -- builds the rest from that same template, so on the shipped UI this
                    -- list comes out EMPTY. Only a LibActionButton bar the player
                    -- installed themselves lands here, and it keeps today's behaviour.
                    if not named then
                        gcdForeign[#gcdForeign + 1] = entry
                    end
                end
            else
                misses = misses + 1
                if misses >= GAP_TOLERANCE then break end
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
local function ApplyToButton(btn, cd)
    local slot = ButtonSlot(btn)
    if not slot or not HasAction(slot) then return end

    -- Off the global cooldown entirely -- still pressable, so leave it clear.
    if SlotIsOffGcd(slot) then return end

    local _, duration = GetActionCooldown(slot)
    if duration and duration > gcdDuration + 0.01 then return end

    -- Passing the ORIGINAL start (not "now") is what lets this be re-applied
    -- mid-GCD without the swipe jumping back to full.
    CooldownFrame_SetTimer(cd, gcdStart, gcdDuration, 1)
end

-- The whole-bar paint. This is the FIRST paint of a GCD window: it runs once per key
-- press, from StartGCD, and no longer on every cooldown event -- see the hook below.
local function ApplyGCD()
    if not db.showGcd then return end
    if gcdDuration <= 0 then return end
    if GetTime() >= gcdExpiry then return end   -- already expired

    if not gcdButtons then CollectButtons() end
    for _, e in ipairs(gcdButtons) do ApplyToButton(e.btn, e.cd) end
end

-- ★ [AN-11] Buttons built from ActionBarButtonTemplate are already repainted by the
-- per-button hook below, so only LibActionButton bars need this sweep -- and on the
-- shipped UI there are none, so it is a length check and a return.
local function ApplyForeign()
    if #gcdForeign == 0 then return end
    if not db.showGcd then return end
    if gcdDuration <= 0 then return end
    if GetTime() >= gcdExpiry then return end

    for _, e in ipairs(gcdForeign) do ApplyToButton(e.btn, e.cd) end
end

-- ===========================================================================
-- ★ REPORTS #428 AND #423: UNIT_SPELLCAST_SUCCEEDED IS NOT "THE PLAYER PRESSED
-- A BUTTON". IT IS "THE SERVER CAST SOMETHING AND NAMED YOU AS THE CASTER".
--
-- Every proc, every triggered sub-spell and every Multicast copy arrives on that
-- event with the player as arg1, and a proc almost always carries the SAME NAME
-- as the ability it belongs to -- a paladin's white swing procs "Seal of
-- Righteousness" (25742), which is the same name as the seal, and the seal is in
-- UncappedGCD_BASE at 1500. So the sweep was repainted on every melee swing
-- (#428, paladin in ICC), and again on every proc that Charge's and Intercept's
-- stun set off (#423).
--
-- Multicast made it worse rather than causing it: each copy fires SUCCEEDED again
-- 250..1600ms later, so one Fireball painted ~3.1s of "GCD" over a real 1.5s one.
--
-- ⚠ THE SERVER NEVER PUT A GCD ON THE PLAYER FOR ANY OF THESE. Procs and copies
-- are cast with TRIGGERED_FULL_MASK, which contains TRIGGERED_IGNORE_GCD, so
-- Spell::prepare never calls TriggerGlobalCooldown for them. This was always a
-- UI that lied, never a real cooldown -- but the bars read as permanently on
-- cooldown, which is its own kind of broken.
--
-- UNIT_SPELLCAST_SENT is the event that means the CLIENT asked to cast, i.e. the
-- player actually pressed something; nothing the server originates fires it.
-- Require one, and consume it, so exactly one sweep is painted per press no
-- matter how many casts that press turns into.
-- ===========================================================================

local sentName, sentAt = nil, 0
-- ★ [#487] Was 10 seconds, and sentName was cleared ONLY by being consumed. A press
-- that resolved to nothing -- out of mana, out of range, refused for GCD, interrupted --
-- therefore left the addon armed with that spell's name for a full ten seconds, and the
-- next server-originated cast under the same name painted a whole-bar sweep the server
-- had never applied. Des reported it as "Arcane Explosion randomly casts after combat and
-- then I can't cast anything else": a levelling mage mashing one AoE button fails presses
-- constantly, so the window was open almost permanently on exactly one spell name.
--
-- Three seconds still covers the slowest cast bar on this realm, and the FAILED /
-- INTERRUPTED handlers below close the window the moment a press is known to be dead.
local SENT_WINDOW = 3

local function StartGCD(spellName)
    if not db.showGcd then return end
    if not spellName then return end

    -- Not a cast this client asked for -- a proc, a triggered sub-spell or a
    -- Multicast copy. The server put no global cooldown on us for any of those,
    -- so neither do we.
    if sentName ~= spellName or (GetTime() - sentAt) > SENT_WINDOW then
        return
    end
    -- Consumed: the copies that follow must not re-arm the sweep.
    sentName = nil

    local base = UncappedGCD_BASE and UncappedGCD_BASE[spellName]
    if not base or base <= 0 then return end   -- off the GCD, or unknown

    -- tmPct is the Time Manipulation fraction the server sent us (0 .. 0.95).
    -- If it has not arrived yet this is simply the stock 1.5s, which is the
    -- right answer for a player with no ranks bought.
    local reduced = base * (1 - (tmPct or 0)) / 1000
    if reduced <= 0 then return end

    gcdStart, gcdDuration = GetTime(), reduced
    gcdExpiry = gcdStart + gcdDuration
    ApplyGCD()
end

-- The stock code repaints a button from GetActionCooldown, which knows nothing
-- about our GCD and would wipe the swipe the moment anything else changed. Put
-- it back for the remainder of the window.
--
-- ★ [AN-11] THIS IS THE ONLY STEADY-STATE PAINTER, and Blizzard calls it once per
-- button out of its own ACTIONBAR_UPDATE_COOLDOWN handler. cdOf resolves each button's
-- cooldown frame once for the life of the session, not once per event.
--
-- ⚠ cdOf is a side table on purpose. Stashing the frame on the button itself is the
-- obvious version and it taints a secure frame -- this UI already logs ADDON_ACTION_BLOCKED
-- 45-48 times a second and does not need help.
if type(ActionButton_UpdateCooldown) == "function" then
    hooksecurefunc("ActionButton_UpdateCooldown", function(self)
        if not db.showGcd or gcdDuration <= 0 then return end
        if GetTime() >= gcdExpiry then return end
        if not self then return end
        local cd = cdOf[self]
        if cd == nil then
            local name = self.GetName and self:GetName()
            cd = self.cooldown or (name and _G[name .. "Cooldown"]) or false
            cdOf[self] = cd
        end
        if cd then ApplyToButton(self, cd) end
    end)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
ev:RegisterEvent("UNIT_SPELLCAST_SENT")
-- [#487] A press that produced nothing must not stay armed. pcall on FAILED_QUIET
-- because RegisterEvent on an event this client does not know is a hard error, and
-- that is the one of the three not worth betting the addon's load on.
ev:RegisterEvent("UNIT_SPELLCAST_FAILED")
ev:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
pcall(ev.RegisterEvent, ev, "UNIT_SPELLCAST_FAILED_QUIET")
-- ★ [AN-11] Still registered, but it no longer sweeps the bar -- see ApplyForeign.
ev:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
-- Bars are rebuilt when the player changes them, so drop the cached FRAME list and let
-- the next cast re-scan rather than holding stale frames. ⚠ Frames only: the off-GCD
-- answers are keyed by ACTION SLOT, and paging repoints buttons at different slots
-- without changing what any slot holds -- see the handler.
ev:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
ev:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
-- Dragging an ability onto a bar changes what a slot holds without changing the
-- frames, so the off-GCD answer for that slot has to be re-asked.
ev:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
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
        -- ★ [AN-12] offGcdSlot is deliberately NOT wiped here any more. A zone-in does not
        -- change what an action slot holds, and the one hazard the wipe was really covering
        -- -- a slot scanned before the client had its action data -- is now handled at
        -- source: SlotIsOffGcd refuses to cache a scan that read nothing.
    elseif e == "UNIT_SPELLCAST_SUCCEEDED" then
        if a1 == "player" then StartGCD(a2) end
    elseif e == "UNIT_SPELLCAST_SENT" then
        -- Only the local player's own cast requests raise this.
        if a1 == "player" then sentName, sentAt = a2, GetTime() end
    elseif e == "UNIT_SPELLCAST_FAILED" or e == "UNIT_SPELLCAST_FAILED_QUIET"
        or e == "UNIT_SPELLCAST_INTERRUPTED" then
        -- [#487] This press is dead: disarm, so nothing the SERVER casts later under
        -- the same name can claim it. 3.3.5 hands these the same (unit, spellName, rank)
        -- shape as _SENT, so a2 is directly comparable to sentName; the a2 == nil arm is
        -- for the quiet variant, which does not always carry a name.
        if a1 == "player" and (a2 == nil or a2 == sentName) then sentName = nil end
    elseif e == "ACTIONBAR_UPDATE_COOLDOWN" then
        -- ⚠ Only the bars Blizzard does not repaint for us. This event fires hundreds
        -- of times a second in combat, so a full-bar sweep here redoes work the
        -- per-button hook has already done.
        ApplyForeign()
    elseif e == "ACTIONBAR_SLOT_CHANGED" then
        -- slot 0 (or none) means "everything changed"
        if a1 and a1 ~= 0 then offGcdSlot[a1] = nil else offGcdSlot, macroSlots = {}, {} end
    elseif e == "ACTIONBAR_PAGE_CHANGED" or e == "UPDATE_BONUS_ACTIONBAR" then
        -- ★ [AN-12] The frame list is dropped; the off-GCD answers are NOT. They are keyed
        -- by action slot, and a page swap or a form shift repoints buttons at other slots
        -- without altering a single slot's contents -- so wiping them bought nothing and
        -- cost a full GameTooltip:SetAction build per button on the next paint, all inside
        -- one frame. That was the druid-form and stance-dance hitch.
        -- ⚠ Macros are the exception and only macros: re-ask those few.
        gcdButtons = nil
        for s in pairs(macroSlots) do offGcdSlot[s] = nil end
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
