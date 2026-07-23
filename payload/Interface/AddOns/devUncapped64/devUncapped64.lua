-- devUncapped64  (DEV-ONLY -- rename to Uncapped* before the launcher push)
--
-- Shows the server's REAL health numbers (past the 32-bit client wall) on the
-- default unit frames, plus the power (mana/rage/energy/runic) numbers, with
-- Blizzard's own bar text suppressed so nothing flashes in behind ours.
--
-- Wire (personal channel, filtered out of chat):
--   RBHP:S:<realCur>:<realMax>                     -- the player themselves
--   RBHP:T:<realCur>:<realMax>:<visMax>:<stacks>   -- current target (may be a boss)
--   RBHP:U:<guidLow>:<realCur>:<realMax>           -- a group member (party/raid)
--
-- Health is proxied on the wire (proxy% == real%), so we reconstruct real from
-- the native bar: for an overflow boss (stacks>0) real = visible + stacks*(visMax/2);
-- otherwise real = (nativeCur/nativeMax) * realMax. Power is NOT proxied (it still
-- fits 32-bit), so those numbers are read straight from the client.

local ADDON_NAME = "devUncapped64"

-- ---------------------------------------------------------------------------
-- Dev-realm gate.
-- ---------------------------------------------------------------------------
-- This addon drives the DEV realm's experimental 64-bit systems (real HP / stat /
-- damage / heal feeds that only the dev worldserver sends). The launcher ships it
-- to everyone, but on the live realm there is no such feed and its combat-text
-- replacement + frame overlays must stay dormant so live players are unaffected.
-- So unless we're on the dev realm ("Uncapped-DEV"), bail out before doing anything.
-- GetRealmName() is reliably populated by the time an addon's file executes on 3.3.5.
do
    local realm = GetRealmName()
    if not realm or not string.find(string.lower(realm), "dev", 1, true) then
        return
    end
end

-- ---------------------------------------------------------------------------
-- Number formatting
-- ---------------------------------------------------------------------------
-- Truncated/abbreviated: 1234 -> 1.2k, 2.8m, 4.53b, 9.99t. Shared by HP,
-- damage, and stat displays so everything reads the same way.
local function Abbrev(n)
    if n >= 1e12 then return string.format("%.2fT", n / 1e12) end
    if n >= 1e9  then return string.format("%.2fB", n / 1e9)  end
    if n >= 1e6  then return string.format("%.2fM", n / 1e6)  end
    if n >= 1e3  then return string.format("%.1fK", n / 1e3)  end
    return string.format("%d", math.floor(n + 0.5))
end

-- Forward declaration: the real-damage floater lives in the FCT section (bottom
-- of the file), but the channel handler (above it) needs to call it.
local ShowRealDamage
local ShowRealHeal

-- ---------------------------------------------------------------------------
-- Overlay font strings, anchored to (and hidden with) a status bar.
-- ---------------------------------------------------------------------------
local function MakeLabel(anchor)
    if not anchor then return nil end
    local f = CreateFrame("Frame", nil, anchor)
    f:SetFrameStrata("HIGH")
    f:SetAllPoints(anchor)
    local fs = f:CreateFontString(nil, "OVERLAY")
    fs:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    fs:SetPoint("CENTER", anchor, "CENTER", 0, 0)
    fs:SetTextColor(1, 1, 1)
    fs:SetText("")
    return fs
end

-- Suppress a Blizzard status-bar's own text so it can't clash with ours.
local function SuppressBarText(bar)
    if not bar then return end
    local fs = bar.TextString
    if not fs and bar.GetName and bar:GetName() then
        fs = _G[bar:GetName() .. "Text"]
    end
    if not fs then return end
    fs:SetText("")
    fs:Hide()
    if not fs.__uncapped64Hidden then
        fs.__uncapped64Hidden = true
        hooksecurefunc(fs, "Show", function(self) self:Hide() end)  -- post-hook, no taint
    end
end

-- ---------------------------------------------------------------------------
-- The frames we decorate: unit token + its health bar + its power bar.
-- ---------------------------------------------------------------------------
local UNITS = {
    { unit = "player", hp = PlayerFrameHealthBar,       pp = PlayerFrameManaBar },
    { unit = "target", hp = TargetFrameHealthBar,       pp = TargetFrameManaBar },
    { unit = "party1", hp = PartyMemberFrame1HealthBar, pp = PartyMemberFrame1ManaBar },
    { unit = "party2", hp = PartyMemberFrame2HealthBar, pp = PartyMemberFrame2ManaBar },
    { unit = "party3", hp = PartyMemberFrame3HealthBar, pp = PartyMemberFrame3ManaBar },
    { unit = "party4", hp = PartyMemberFrame4HealthBar, pp = PartyMemberFrame4ManaBar },
}

for _, e in ipairs(UNITS) do
    e.hpLabel = MakeLabel(e.hp)
    e.ppLabel = MakeLabel(e.pp)
end

local function SuppressBlizzardText()
    for _, e in ipairs(UNITS) do
        SuppressBarText(e.hp)
        SuppressBarText(e.pp)
    end
end

-- ---------------------------------------------------------------------------
-- State fed by the server.
-- ---------------------------------------------------------------------------
local selfData   = nil   -- { max }
local targetData = nil   -- { max, visMax, stacks }
local byGuid     = {}    -- [guidLow] = { max }   (group members)

-- Player GUIDs carry no high bits, so the full 0x-hex string parses to the low
-- counter -- the same number the server sends in RBHP:U.
local function GuidLow(unit)
    local g = UnitGUID(unit)
    if not g then return nil end
    return tonumber(string.sub(g, 3), 16)
end

local function HpInfoFor(unit)
    if unit == "player" then
        if selfData then return selfData.max, 0, nil end
    elseif unit == "target" then
        if targetData then return targetData.max, targetData.stacks or 0, targetData.visMax end
        -- Fallback: a group member we already have HP for (RBHP:T can lag by a
        -- tick, and a far player only resolves once the server catches up).
        local low = GuidLow(unit)
        if low then
            local d = byGuid[low]
            if d then return d.max, 0, nil end
        end
    else
        local low = GuidLow(unit)
        if low then
            local d = byGuid[low]
            if d then return d.max, 0, nil end
        end
    end
    return nil
end

local function RenderHp(unit, label)
    if not label then return end
    if not UnitExists(unit) then label:SetText(""); return end
    local rmax, stacks, visMax = HpInfoFor(unit)
    if not rmax then label:SetText(""); return end

    local cur, max
    if stacks and stacks > 0 and visMax then
        local phase = math.floor(visMax / 2)
        cur = UnitHealth(unit) + stacks * phase
        max = visMax + stacks * phase
    else
        local nmax = UnitHealthMax(unit)
        local frac = (nmax > 0) and (UnitHealth(unit) / nmax) or 0
        cur = frac * rmax
        max = rmax
    end
    label:SetText(Abbrev(cur) .. "  /  " .. Abbrev(max))
end

-- Power (mana/rage/energy/focus/runic) is not proxied -- read it natively.
local function RenderPower(unit, label)
    if not label then return end
    if not UnitExists(unit) then label:SetText(""); return end
    local max = UnitPowerMax(unit)
    if not max or max <= 0 then label:SetText(""); return end
    label:SetText(Abbrev(UnitPower(unit)) .. "  /  " .. Abbrev(max))
end

-- One driver frame for every overlay.
local driver = CreateFrame("Frame")
local acc = 0
driver:SetScript("OnUpdate", function(self, delta)
    acc = acc + delta
    if acc < 0.1 then return end
    acc = 0
    for _, e in ipairs(UNITS) do
        RenderHp(e.unit, e.hpLabel)
        RenderPower(e.unit, e.ppLabel)
    end
end)

-- ---------------------------------------------------------------------------
-- Channel plumbing.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Uncapped character sheet (AllStats integration).
--
-- The AllStats addon paints the whole paperdoll stat panel using the stock
-- client APIs, which read 32-bit wire fields -- so once a stat is inflated past
-- ~2.1e9 they show a low, capped number when you press C. The server feeds us
-- the REAL values over the channel (RBALL:...); right after AllStats repaints
-- its panel we overwrite the affected lines with the real, truncated numbers.
-- The percentage lines (crit/dodge/parry/block) and mana regen already carry
-- real values (they live in float fields), so those we just truncate in place.
-- ---------------------------------------------------------------------------
local realStats = {}   -- latest values from RBALL

-- The value FontString for an AllStats row: StatFrameTemplate names it
-- "<frameName>StatText" (e.g. AllStatsFrameStat1 -> AllStatsFrameStat1StatText).
local function AllStatsFS(row)
    return _G["AllStatsFrameStat" .. row .. "StatText"]
end

local WHITE = "|cffffffff"
local function W(v) return WHITE .. Abbrev(v or 0) .. "|r" end

local function SetRow(row, text)
    local fs = AllStatsFS(row)
    if fs and text then fs:SetText(text) end
end

-- Truncate any large number already present in a row's text (for the real-but-
-- huge percentage / regen lines). Values under 100k are left untouched.
local function AbbrevRow(row)
    local fs = AllStatsFS(row)
    if not fs then return end
    local t = fs:GetText()
    if not t then return end
    fs:SetText((t:gsub("%d+%.?%d*", function(n)
        local v = tonumber(n)
        if v and v >= 100000 then return Abbrev(v) end
        return n
    end)))
end

local function ApplyAllStatsReal()
    local r = realStats
    if not r.str or not AllStatsFS("1") then return end   -- no feed yet / AllStats not loaded

    SetRow("1", W(r.str)); SetRow("2", W(r.agi)); SetRow("3", W(r.sta))
    SetRow("4", W(r.int)); SetRow("5", W(r.spi))

    SetRow("MeleePower", W(r.map))
    SetRow("MeleeDamage", WHITE .. Abbrev(r.mmin) .. " - " .. Abbrev(r.mmax) .. "|r")
    SetRow("MeleeExpert", W(r.exp))

    SetRow("RangePower", W(r.rap))
    if r.rmax and r.rmax > 0 then
        SetRow("RangeDamage", WHITE .. Abbrev(r.rmin) .. " - " .. Abbrev(r.rmax) .. "|r")
    end

    SetRow("SpellDamage", W(r.sp))
    SetRow("SpellHeal", W(r.heal))

    SetRow("Armor", W(r.armor))
    SetRow("Defense", W(r.def))

    -- Real-but-huge derived lines: truncate the client's own value in place.
    AbbrevRow("MeleeCrit"); AbbrevRow("RangeCrit"); AbbrevRow("SpellCrit")
    AbbrevRow("Dodge"); AbbrevRow("Parry"); AbbrevRow("Block")
    AbbrevRow("SpellRegen")
end

-- Hook AllStats' PrintStats so our overwrite runs immediately after each repaint.
local allStatsHooked = false
local function EnsureAllStatsHook()
    if allStatsHooked or type(PrintStats) ~= "function" then return end
    hooksecurefunc("PrintStats", ApplyAllStatsReal)
    allStatsHooked = true
end

local function OnLine(msg)
    local sCur, sMax = msg:match("^RBHP:S:(%d+):(%d+)$")
    if sMax then
        selfData = { max = tonumber(sMax) }
        return
    end

    -- Comprehensive real character-sheet stats (past the 32-bit wire wall).
    if msg:find("^RBALL:") then
        local p = {}
        for tok in msg:gmatch("%-?%d+") do p[#p + 1] = tonumber(tok) end
        realStats = {
            str = p[1], agi = p[2], sta = p[3], int = p[4], spi = p[5],
            map = p[6], rap = p[7], sp = p[8], heal = p[9], armor = p[10],
            def = p[11], exp = p[12], mmin = p[13], mmax = p[14], rmin = p[15], rmax = p[16],
        }
        EnsureAllStatsHook()
        if CharacterFrame and CharacterFrame:IsShown() then ApplyAllStatsReal() end
        return
    end

    -- Real (trillion-scale) outgoing melee/spell hit, past the 32-bit combat-log wall.
    local dmg = msg:match("^RBDMG:(%d+)$")
    if dmg then
        if ShowRealDamage then ShowRealDamage(tonumber(dmg)) end
        return
    end

    -- Real (trillion-scale) outgoing heal, past the 32-bit combat-log wall.
    local heal = msg:match("^RBHEAL:(%d+)$")
    if heal then
        if ShowRealHeal then ShowRealHeal(tonumber(heal)) end
        return
    end

    local tCur, tMax, tVis, tStacks = msg:match("^RBHP:T:(%d+):(%d+):(%d+):(%d+)$")
    if tMax then
        targetData = { max = tonumber(tMax), visMax = tonumber(tVis), stacks = tonumber(tStacks) }
        return
    end

    local uLow, uCur, uMax = msg:match("^RBHP:U:(%d+):(%d+):(%d+)$")
    if uMax then
        byGuid[tonumber(uLow)] = { max = tonumber(uMax) }
        return
    end
end

-- Keep our protocol lines out of chat.
ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", function(self, event, msg)
    if msg and (msg:find("^RBHP:") or msg:find("^RBALL:") or msg:find("^RBDMG:") or msg:find("^RBHEAL:")) then
        return true
    end
    return false
end)

local function OnTargetChanged()
    targetData = nil
    if UNITS[2] and UNITS[2].hpLabel then UNITS[2].hpLabel:SetText("") end
end

local listener = CreateFrame("Frame")
listener:RegisterEvent("ADDON_LOADED")
listener:RegisterEvent("PLAYER_ENTERING_WORLD")
listener:RegisterEvent("PARTY_MEMBERS_CHANGED")
listener:RegisterEvent("CHAT_MSG_CHANNEL")
listener:RegisterEvent("PLAYER_TARGET_CHANGED")
listener:SetScript("OnEvent", function(self, event, a1, a2)
    if event == "ADDON_LOADED" then
        if a1 == ADDON_NAME then
            JoinChannelByName(UnitName("player"))
            SuppressBlizzardText()
        end
        return
    end

    if event == "PLAYER_ENTERING_WORLD" or event == "PARTY_MEMBERS_CHANGED" then
        SuppressBlizzardText()  -- (re)hide Blizzard text as frames come/go
        return
    end

    if event == "PLAYER_TARGET_CHANGED" then
        OnTargetChanged()
        return
    end

    -- CHAT_MSG_CHANNEL: a1 = message, a2 = author (our own name on the pipe).
    if a2 ~= UnitName("player") or not a1 then
        return
    end
    if a1:find("^RBHP:") or a1:find("^RBALL:") or a1:find("^RBDMG:") or a1:find("^RBHEAL:") then
        OnLine(a1)
    end
end)

-- Local smoke test (no server): /dev64
SLASH_DEVUNCAPPED641 = "/dev64"
SlashCmdList["DEVUNCAPPED64"] = function()
    OnLine("RBHP:S:1500000000:1500000000")
    OnLine("RBHP:T:87500000000:90000000000:1000000000:170")
    DEFAULT_CHAT_FRAME:AddMessage("|cff40ff40[DEV] Uncapped64|r: injected test numbers.")
end

-- ===========================================================================
-- FLOATING COMBAT TEXT (merged in -- was a separate file that wouldn't load
-- without a full client restart). Replaces Blizzard's over-head damage numbers
-- with our own, driven from the combat log. Outgoing rises on the right,
-- incoming on the left; crits bigger + gold. Live font: /dev64font, test: /dev64dmg.
-- ===========================================================================
local FCT_FONTS = {
    skurri   = "Fonts\\SKURRI.TTF",     -- the classic spiky WoW combat font
    arial    = "Fonts\\ARIALN.TTF",     -- condensed, clean, very readable
    morpheus = "Fonts\\MORPHEUS.TTF",   -- ornate fantasy serif
    friz     = "Fonts\\FRIZQT__.TTF",   -- default UI font
}
local FCT_FONT = FCT_FONTS.morpheus

-- Disable Blizzard's floating combat text AND the scrolling "combat text" so
-- ours fully replaces every kind of combat feedback.
local function DisableBlizzardFCT()
    pcall(SetCVar, "floatingCombatTextCombatDamage", "0")
    pcall(SetCVar, "floatingCombatTextCombatHealing", "0")
    pcall(SetCVar, "floatingCombatTextCombatState", "0")     -- (dodge/parry/miss floaters)
    if COMBAT_TEXT_TYPE_INFO then                            -- Blizzard's scrolling combat text
        SHOW_COMBAT_TEXT = "0"
        if CombatText_UpdateDisplayedMessages then pcall(CombatText_UpdateDisplayedMessages) end
    end
end

local MISS_TEXT = {
    MISS = "Miss", DODGE = "Dodge", PARRY = "Parry", BLOCK = "Block",
    DEFLECT = "Deflect", ABSORB = "Absorb", IMMUNE = "Immune",
    RESIST = "Resist", EVADE = "Evade", REFLECT = "Reflect",
}

local function Commafy(n)
    n = math.floor(n + 0.5)
    local s = tostring(n)
    local rev = s:reverse():gsub("(%d%d%d)", "%1,")
    s = rev:reverse()
    if s:sub(1, 1) == "," then s = s:sub(2) end
    return s
end

local SCHOOL_COLOR = {
    [1]  = { 1.0, 1.0, 0.6 }, [2]  = { 1.0, 0.9, 0.5 }, [4]  = { 1.0, 0.5, 0.2 },
    [8]  = { 0.3, 1.0, 0.3 }, [16] = { 0.5, 0.8, 1.0 }, [32] = { 0.6, 0.4, 1.0 },
    [64] = { 1.0, 0.6, 1.0 },
}

local fctHost = CreateFrame("Frame", nil, UIParent)
local fctOut = CreateFrame("Frame", nil, UIParent)
fctOut:SetWidth(1); fctOut:SetHeight(1)
fctOut:SetPoint("CENTER", UIParent, "CENTER", 150, -10)
local fctIn = CreateFrame("Frame", nil, UIParent)
fctIn:SetWidth(1); fctIn:SetHeight(1)
fctIn:SetPoint("CENTER", UIParent, "CENTER", -150, -10)

local fctPool, fctActive = {}, {}

-- Spawn any floating text (a damage number, a heal, or a "Dodge"/"Parry"/etc).
local function FctSpawnText(text, big, r, g, b, anchor)
    local fs = table.remove(fctPool) or fctHost:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FCT_FONT, big and 34 or 20, "OUTLINE")
    fs:SetText(text)
    fs:SetTextColor(r, g, b)
    fs:SetAlpha(1)
    fs:ClearAllPoints()
    local jitter = math.random(-30, 30)
    fs:SetPoint("CENTER", anchor, "CENTER", jitter, 0)
    fs:Show()
    fctActive[#fctActive + 1] = { fs = fs, anchor = anchor, x = jitter, t = 0, dur = big and 1.6 or 1.2, rise = big and 150 or 110 }
end

-- Assigns the forward-declared handler: the server feeds real (trillion-scale)
-- melee hits over the channel when they're past the 32-bit combat-log wall.
ShowRealDamage = function(real)
    FctSpawnText(Abbrev(real) .. "!", true, 1.0, 0.82, 0.0, fctOut)
end

-- Real (trillion-scale) outgoing heal, fed over the channel when the client's
-- own combat log would show the 32-bit-capped value. Heal green, "+" prefix.
ShowRealHeal = function(real)
    FctSpawnText("+" .. Abbrev(real), true, 0.4, 1.0, 0.4, fctOut)
end

fctHost:SetScript("OnUpdate", function(self, dt)
    for i = #fctActive, 1, -1 do
        local a = fctActive[i]
        a.t = a.t + dt
        local p = a.t / a.dur
        if p >= 1 then
            a.fs:Hide(); a.fs:ClearAllPoints()
            fctPool[#fctPool + 1] = a.fs
            table.remove(fctActive, i)
        else
            a.fs:SetPoint("CENTER", a.anchor, "CENTER", a.x, a.rise * p)
            if p > 0.55 then a.fs:SetAlpha(1 - (p - 0.55) / 0.45) end
        end
    end
end)

local fctPlayerGUID

local function FctMine(guid) return guid == fctPlayerGUID or guid == UnitGUID("pet") end

-- At/above the signed-32 combat-log wall the client only ever sees the capped
-- value, and the server feeds the REAL number over the channel (RBDMG/RBHEAL)
-- instead -- so drop our OWN combat-log floater there to avoid a stray double.
local FCT_REAL_WALL = 2147483647

local function FctDamage(srcGUID, dstGUID, amount, crit, school)
    if not amount or amount <= 0 then return end
    if FctMine(srcGUID) and amount >= FCT_REAL_WALL then return end
    if FctMine(srcGUID) then
        local c = SCHOOL_COLOR[school]
        if crit then FctSpawnText(Abbrev(amount) .. "!", true, 1.0, 0.82, 0.0, fctOut)
        elseif c then FctSpawnText(Abbrev(amount), false, c[1], c[2], c[3], fctOut)
        else FctSpawnText(Abbrev(amount), false, 1, 1, 1, fctOut) end
    elseif dstGUID == fctPlayerGUID then
        if crit then FctSpawnText(Abbrev(amount) .. "!", true, 1.0, 0.35, 0.1, fctIn)
        else FctSpawnText(Abbrev(amount), false, 1.0, 0.4, 0.4, fctIn) end
    end
end

-- Miss/dodge/parry/block/absorb/immune/resist -- avoided attacks.
local function FctMiss(srcGUID, dstGUID, missType)
    local label = MISS_TEXT[missType] or "Miss"
    if FctMine(srcGUID) then
        FctSpawnText(label, false, 0.85, 0.85, 0.85, fctOut)   -- your attack was avoided
    elseif dstGUID == fctPlayerGUID then
        FctSpawnText(label, false, 0.85, 0.95, 1.0, fctIn)     -- you avoided one
    end
end

local function FctHeal(srcGUID, dstGUID, amount, crit)
    if not amount or amount <= 0 then return end
    if FctMine(srcGUID) and amount >= FCT_REAL_WALL then return end  -- RBHEAL feed covers my own trillion heals
    if dstGUID == fctPlayerGUID then
        FctSpawnText("+" .. Abbrev(amount), crit, 0.4, 1.0, 0.4, fctIn)
    elseif FctMine(srcGUID) then
        FctSpawnText("+" .. Abbrev(amount), crit, 0.4, 1.0, 0.4, fctOut)
    end
end

local function FctOnCombatLog(...)
    local subevent = select(2, ...)
    local srcGUID  = select(3, ...)
    local dstGUID  = select(6, ...)
    if subevent == "SWING_DAMAGE" then
        local amount, overkill, school, resisted, blocked, absorbed, critical = select(9, ...)
        FctDamage(srcGUID, dstGUID, amount, critical, school)
    elseif subevent == "SWING_MISSED" then
        local missType = select(9, ...)
        FctMiss(srcGUID, dstGUID, missType)
    elseif subevent == "SPELL_DAMAGE" or subevent == "RANGE_DAMAGE" or subevent == "SPELL_PERIODIC_DAMAGE"
        or subevent == "DAMAGE_SHIELD" or subevent == "SPELL_BUILDING_DAMAGE" or subevent == "DAMAGE_SPLIT" then
        local spellId, spellName, spellSchool, amount, overkill, school, resisted, blocked, absorbed, critical = select(9, ...)
        FctDamage(srcGUID, dstGUID, amount, critical, spellSchool)
    elseif subevent == "SPELL_MISSED" or subevent == "RANGE_MISSED" or subevent == "SPELL_PERIODIC_MISSED" then
        local spellId, spellName, spellSchool, missType = select(9, ...)
        FctMiss(srcGUID, dstGUID, missType)
    elseif subevent == "SPELL_HEAL" or subevent == "SPELL_PERIODIC_HEAL" then
        local spellId, spellName, spellSchool, amount, overhealing, absorbed, critical = select(9, ...)
        FctHeal(srcGUID, dstGUID, amount, critical)
    end
end

local fctEv = CreateFrame("Frame")
fctEv:RegisterEvent("PLAYER_LOGIN")
fctEv:RegisterEvent("PLAYER_ENTERING_WORLD")
fctEv:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
fctEv:SetScript("OnEvent", function(self, event, ...)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        FctOnCombatLog(...)
        return
    end
    fctPlayerGUID = UnitGUID("player")
    DisableBlizzardFCT()
end)

SLASH_DEV64FONT1 = "/dev64font"
SlashCmdList["DEV64FONT"] = function(msg)
    local key = (msg or ""):lower():gsub("%s", "")
    if FCT_FONTS[key] then
        FCT_FONT = FCT_FONTS[key]
        DEFAULT_CHAT_FRAME:AddMessage("|cff40ff40[dev64]|r combat font -> " .. key)
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff40ff40[dev64]|r fonts: skurri, arial, morpheus, friz")
    end
end

SLASH_DEV64DMG1 = "/dev64dmg"
SlashCmdList["DEV64DMG"] = function()
    FctSpawnText(Abbrev(math.random(100000000, 2000000000)) .. "!", true, 1.0, 0.82, 0.0, fctOut)  -- crit out
    FctSpawnText(Abbrev(math.random(1000000, 50000000)), false, 1.0, 0.5, 0.2, fctOut)             -- fire hit out
    FctSpawnText(Abbrev(math.random(50000000, 900000000)), false, 1.0, 0.4, 0.4, fctIn)            -- taken
    FctSpawnText("Dodge", false, 0.85, 0.95, 1.0, fctIn)                                            -- avoided
    FctSpawnText("Parry", false, 0.85, 0.95, 1.0, fctIn)
    FctSpawnText("+" .. Abbrev(math.random(5000000, 80000000)), false, 0.4, 1.0, 0.4, fctIn)       -- heal
end

-- ---------------------------------------------------------------------------
-- Stat panel hover removal.
--
-- AllStats paints its rows with the stock PaperDollFrame_Set* helpers, which
-- also install Blizzard's tooltip handlers. Those recompute from the 32-bit
-- client fields, so on a scaled character the hover flatly contradicts the row
-- it is attached to: Strength shows 3.45B in the panel while its tooltip claims
-- "Increases Attack Power by -294967316" -- a plain int32 wrap of ~4.0e9.
--
-- The panel itself is already correct (ApplyAllStatsReal repaints it from the
-- RBALL feed), so there is nothing worth salvaging in the tooltip. Remove it
-- rather than maintain a second source of the same numbers that we would have
-- to keep in sync and that can only ever be wrong past 2^31.
--
-- AllStats re-installs these handlers on every repaint, so this has to run
-- after each one, not just once at load.
-- ---------------------------------------------------------------------------
local STAT_ROWS = {
    "1", "2", "3", "4", "5",
    "MeleeDamage", "MeleeSpeed", "MeleePower", "MeleeHit", "MeleeCrit", "MeleeExpert",
    "RangeDamage", "RangeSpeed", "RangePower", "RangeHit", "RangeCrit",
    "SpellDamage", "SpellHeal", "SpellHit", "SpellCrit", "SpellHaste", "SpellRegen",
    "Armor", "Defense", "Dodge", "Parry", "Block", "Resil",
}

local function StripStatTooltips()
    for _, suffix in ipairs(STAT_ROWS) do
        local f = _G["AllStatsFrameStat" .. suffix]
        if f then
            f:SetScript("OnEnter", nil)
            f:SetScript("OnLeave", nil)
            -- PaperDollFrame_Set* stash the strings on the frame itself; clear
            -- them too so nothing can resurrect the tooltip from stale fields.
            f.tooltip = nil
            f.tooltip2 = nil
        end
    end
end

-- Hook PrintStats, NOT NewPaperDollFrame_UpdateStats.
--
-- AllStats_OnLoad does `PaperDollFrame_UpdateStats = NewPaperDollFrame_UpdateStats`,
-- which copies the function VALUE. Hooking the NewPaperDollFrame_UpdateStats global
-- afterwards therefore does nothing: every real call goes through the reference
-- captured at load and never sees the wrapper. AllStats.xml also calls PrintStats()
-- directly, a second path that would bypass it.
--
-- PrintStats is looked up globally at call time from both paths, so hooking it
-- catches every repaint.
local function InstallStatTooltipStripper()
    if type(PrintStats) ~= "function" then return false end
    hooksecurefunc("PrintStats", StripStatTooltips)
    return true
end

if not InstallStatTooltipStripper() then
    -- Load-order fallback: wait until AllStats is in, then hook.
    local waiter = CreateFrame("Frame")
    waiter:RegisterEvent("ADDON_LOADED")
    waiter:RegisterEvent("PLAYER_LOGIN")
    waiter:SetScript("OnEvent", function(self)
        if InstallStatTooltipStripper() then
            self:UnregisterAllEvents()
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Spell tooltip: strip the computed damage / healing figures.
--
-- The client builds these itself from Spell.dbc tokens and its OWN capped stat
-- fields, so the number is wrong before it ever reaches us -- Exorcism advertises
-- "Causes 576761472 to 576761600 Holy damage" while actually hitting for 450
-- billion. There is no value we could substitute that the client would keep, and
-- no server field that feeds it, so the honest fix is to remove the figure and
-- say what the spell scales with instead.
--
-- Only lines that actually talk about damage or healing are touched; cast time,
-- range, cooldown and mana cost live on their own lines and are still correct.
-- ---------------------------------------------------------------------------

-- Which stat governs a school. Physical abilities scale from attack power,
-- everything else from spell power. Per-spell exceptions (WotLK has plenty of
-- magic-school abilities that scale off attack power) go in SPELL_SCALING_OVERRIDE
-- below, keyed by spell name.
local SCHOOL_STAT = {
    ["Physical"] = "attack power",
    ["Holy"]     = "spell power",
    ["Fire"]     = "spell power",
    ["Frost"]    = "spell power",
    ["Arcane"]   = "spell power",
    ["Nature"]   = "spell power",
    ["Shadow"]   = "spell power",
}

-- Magic-school abilities that actually scale from attack power. Extend as they
-- turn up; the school heuristic handles everything not listed.
local SPELL_SCALING_OVERRIDE = {
    ["Seal of Righteousness"]  = "attack power",
    ["Seal of Vengeance"]      = "attack power",
    ["Seal of Corruption"]     = "attack power",
    ["Hammer of the Righteous"] = "attack power",
    ["Divine Storm"]           = "attack power",
    ["Crusader Strike"]        = "attack power",
}

-- Remove figures that came from the client's own arithmetic. Ranges go first,
-- then any remaining number of four or more digits -- that threshold keeps the
-- genuinely useful small ones ("for 3 sec", "within 8 yards") intact.
local function StripComputedFigures(text)
    text = text:gsub("(%d[%d%.,]*)%s+to%s+(%d[%d%.,]*)%s*", "")
    text = text:gsub("%d[%d%.,]*", function(n)
        local digits = n:gsub("[^%d]", "")
        if #digits >= 4 then return "" end
        return n
    end)
    -- Tidy the gaps the removals leave behind.
    text = text:gsub("%s%s+", " ")
    text = text:gsub("%s+([%.,])", "%1")
    text = text:gsub("^%s+", "")
    return text
end

local function RewriteSpellTooltip(tooltip)
    -- 3.3.5 has no GetSpellName() on tooltips; the name is simply the first
    -- left-hand line, which is also what the override table is keyed on.
    local nameFS = _G[tooltip:GetName() .. "TextLeft1"]
    local spellName = nameFS and nameFS:GetText() or nil
    local governing = spellName and SPELL_SCALING_OVERRIDE[spellName] or nil
    local annotated = false

    for i = 2, tooltip:NumLines() do
        local fs = _G[tooltip:GetName() .. "TextLeft" .. i]
        if fs then
            local text = fs:GetText()
            if text and (text:find("damage") or text:find("healing") or text:find("Heals")
                         or text:find("heals")) then
                local stripped = StripComputedFigures(text)

                if not annotated then
                    -- Work out what to credit the scaling to: an explicit
                    -- override, else the school named in the line itself.
                    local stat = governing
                    if not stat then
                        for school, mapped in pairs(SCHOOL_STAT) do
                            if text:find(school) then
                                stat = mapped
                                break
                            end
                        end
                    end
                    stat = stat or "spell power"

                    -- Insert before the trailing full stop of the first sentence
                    -- so it reads naturally rather than being bolted on the end.
                    local head, tail = stripped:match("^(.-%S)%.%s*(.*)$")
                    if head then
                        stripped = head .. ", based on your " .. stat .. "."
                        if tail and tail ~= "" then
                            stripped = stripped .. " " .. tail
                        end
                    else
                        stripped = stripped .. " (based on your " .. stat .. ")"
                    end
                    annotated = true
                end

                if stripped ~= text then
                    fs:SetText(stripped)
                end
            end
        end
    end

    tooltip:Show()   -- re-fit: our text is shorter than what it measured
end

for _, tt in ipairs({ GameTooltip, ItemRefTooltip }) do
    if tt then
        tt:HookScript("OnTooltipSetSpell", RewriteSpellTooltip)
    end
end
