-- Uncapped64bitUI -- shows the server's REAL 64-bit numbers past the 32-bit client wall.
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
-- the native bar: real = (nativeCur/nativeMax) * realMax. Power is NOT proxied
-- (it still fits 32-bit), so those numbers are read straight from the client.
--
-- The <stacks> field is a retired mechanism, now always 0. It used to carry a
-- boss's banked HP-overflow phases; creatures hold a true 64-bit pool instead.
-- It stays on the wire only so an older addon build keeps parsing the line.
--
-- Targeting is deliberately NOT gated on the feed arriving. Below
-- HEALTH_PROXY_BUDGET the client's own max-health field is the real number
-- rather than a proxy, so for ordinary targets the readout is derived locally on
-- the same frame the target changes and the push that follows merely confirms
-- it. Only saturated units (deep-keystone creatures) and other players actually
-- need the server, and those answer instantly on re-target from a session cache
-- of what we last saw.

local ADDON_NAME = "Uncapped64bitUI"

-- Addon-message prefix for the server->client pipe. Must match
-- ReagentBankChannelProtocol::ADDON_MESSAGE_PREFIX on the server.
local ADDON_PIPE_PREFIX = "UNC"

-- Must match Unit::HEALTH_PROXY_BUDGET on the server (Unit.h).
--
-- Below this figure the client's own max-health field is the REAL value, not a
-- proxy -- HealthProxyOf passes it through untouched. At or above it the field
-- is pinned to the budget and the true number only exists server-side. That
-- boundary is what lets the target readout answer instantly in the common case
-- without ever inventing a number in the uncommon one.
local HEALTH_PROXY_BUDGET = 2000000000

-- The dev-realm gate that used to sit here has been REMOVED (2026-07-23).
--
-- It bailed out of this entire file unless GetRealmName() contained "dev", because
-- at the time only the dev worldserver sent the RB* feeds and the overlays had to
-- stay dormant for live players. Both halves of that reasoning are now obsolete:
-- the 64-bit pipeline shipped to the live realm, so live sends the same feeds, and
-- this addon is the only thing filtering the RB* protocol out of chat. With the gate
-- in place, live players got the raw protocol spammed into chat several times a
-- second and no real numbers -- while the addon still showed as enabled, loaded
-- without error, and registered no slash commands, because execution stopped here.
--
-- If a realm ever needs it dormant again, gate the individual feeds, not the file.

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

-- Forward declarations for the config/options plumbing at the bottom of the file
-- (referenced by the ADDON_LOADED handler and slash commands above them).
local InitSavedVars
local RefreshOptionsPanel

-- ---------------------------------------------------------------------------
-- Overlay font strings, anchored to (and hidden with) a status bar.
-- ---------------------------------------------------------------------------
local function MakeLabel(anchor)
    if not anchor then return nil end
    local f = CreateFrame("Frame", nil, anchor)
    -- Stay in the anchor's strata (a unit-frame bar, normally MEDIUM) rather than
    -- forcing HIGH. Forcing a strata lifted the label out of the unit-frame layer,
    -- so the HP text kept drawing on top of the world map, static-popup dialogs and
    -- other higher-strata UI. Matching the anchor's strata and only bumping the
    -- frame level keeps the text above the bar's own art while still being covered
    -- by the map and dialogs exactly like the unit frame it annotates.
    f:SetFrameStrata(anchor:GetFrameStrata())
    f:SetFrameLevel(anchor:GetFrameLevel() + 5)
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

-- What we last knew about a unit's real HP, keyed by full GUID string.
--
-- The server's target feed is a push, so on a fresh target there is always a
-- window where we have nothing to draw -- which is what players experienced as
-- "targeting is laggy". Re-targeting something we have already seen this session
-- should never pay that cost twice, so the last known figures are kept here and
-- restored the moment the target changes.
--
-- Creature GUIDs are per-spawn and a boss's stack count moves during a fight, so
-- this is deliberately session-only (never saved) and wiped on a world change,
-- where every cached creature GUID is dead anyway.
local hpCacheByGuid  = {}
local hpCacheCount   = 0
local HP_CACHE_LIMIT = 500

local function WipeHpCache()
    hpCacheByGuid = {}
    hpCacheCount = 0
end

local function RememberTargetHp(d)
    local g = UnitGUID("target")
    if not g then return end

    -- A push that was in flight while the player switched target describes the
    -- PREVIOUS unit. Storing it under the current GUID would mean confidently
    -- painting one mob's numbers onto another, so require the visible max the
    -- server measured to match the unit actually under the cursor now.
    if UnitHealthMax("target") ~= d.visMax then return end

    if hpCacheByGuid[g] == nil then
        if hpCacheCount >= HP_CACHE_LIMIT then WipeHpCache() end
        hpCacheCount = hpCacheCount + 1
    end
    hpCacheByGuid[g] = d
end

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

        -- Nothing from the server yet -- but often we do not need it.
        --
        -- The proxy in UNIT_FIELD_MAXHEALTH is not always an approximation. The
        -- server's HealthProxyOf returns the real value UNCHANGED whenever the
        -- real max fits under HEALTH_PROXY_BUDGET (2e9), and only compresses
        -- above that, pinning the visible max to exactly the budget. So a visible
        -- max strictly below 2e9 is not a proxy at all: it IS the real number,
        -- already on the client, the instant the unit exists.
        --
        -- That covers essentially everything anyone targets outside a deep
        -- keystone, and waiting on a push to be told a number we already hold is
        -- the whole of the perceived delay.
        --
        -- At or above the budget the value is saturated and the real one is
        -- unknowable here, so we show nothing and let the feed answer. Same for
        -- players, whose health is proxied regardless of size. Guessing there
        -- would paint a confidently wrong, far-too-small number, and a number
        -- that is wrong without looking wrong is worse than a blank frame.
        if not UnitIsPlayer(unit) then
            local vmax = UnitHealthMax(unit)
            if vmax and vmax > 0 and vmax < HEALTH_PROXY_BUDGET then return vmax, 0, nil end
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
local allPending = {}  -- buffered RBALLA/RBALLB halves until both have arrived

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

    -- [Haste->CritDamage] Haste no longer speeds anything on this realm; it grants
    -- crit damage. Repurpose the now-inert "Spell Haste" row into a Crit Damage
    -- readout: relabel it and show the haste-derived crit-damage percent.
    local hLabel = _G["AllStatsFrameStatSpellHasteLabel"]
    if hLabel then hLabel:SetText("Crit Damage") end
    if r.critdmg then SetRow("SpellHaste", WHITE .. "+" .. r.critdmg .. "%|r") end

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

-- [deep-keystone] The RBHP real* fields are a MANTISSA; the server appends a health
-- EXPONENT so effective HP == mantissa * 2^exponent. Past keystone ~+45 the mantissa
-- alone reads as a boss at a small fraction of its real health.
--
-- The exponent field is OPTIONAL on the wire: an older worldserver omits it, so every
-- pattern below matches ":?(%d*)" and this treats an empty capture as 0. That keeps one
-- addon build working against both server versions.
local function ApplyHpExponent(value, exponent)
    local e = tonumber(exponent)
    if not e or e <= 0 then return value end
    return value * (2 ^ e)
end

local function OnLine(msg)
    local sCur, sMax, sExp = msg:match("^RBHP:S:(%d+):(%d+):?(%d*)$")
    if sMax then
        selfData = { max = ApplyHpExponent(tonumber(sMax), sExp) }
        return
    end

    -- Comprehensive real character-sheet stats (past the 32-bit wire wall).
    -- RBALL now arrives as two halves (RBALLA + RBALLB).
    --
    -- Sixteen 64-bit fields is ~277 bytes at trillion scale, past the client's
    -- 255-byte addon-message cap -- it would have truncated silently on exactly
    -- the scaled characters this feed exists for. The halves are buffered and
    -- applied together, so a dropped or reordered one never paints a half-filled
    -- stat panel. "RBALL:" (undivided) is still accepted from any realm still
    -- running the older worldserver.
    local function ApplyRealStats(p)
        realStats = {
            str = p[1], agi = p[2], sta = p[3], int = p[4], spi = p[5],
            map = p[6], rap = p[7], sp = p[8], heal = p[9], armor = p[10],
            def = p[11], exp = p[12], mmin = p[13], mmax = p[14], rmin = p[15], rmax = p[16],
            critdmg = p[17],
        }
        EnsureAllStatsHook()
        if CharacterFrame and CharacterFrame:IsShown() then ApplyAllStatsReal() end
    end

    local function Tokens(body)
        local t = {}
        for tok in body:gmatch("%-?%d+") do t[#t + 1] = tonumber(tok) end
        return t
    end

    local bodyA = msg:match("^RBALLA:(.+)$")
    if bodyA then
        allPending.a = Tokens(bodyA)
        if allPending.b then
            local p = {}
            for i = 1, 8 do p[i] = allPending.a[i] end
            for i = 1, 9 do p[8 + i] = allPending.b[i] end
            ApplyRealStats(p)
        end
        return
    end

    local bodyB = msg:match("^RBALLB:(.+)$")
    if bodyB then
        allPending.b = Tokens(bodyB)
        if allPending.a then
            local p = {}
            for i = 1, 8 do p[i] = allPending.a[i] end
            for i = 1, 9 do p[8 + i] = allPending.b[i] end
            ApplyRealStats(p)
        end
        return
    end

    -- Legacy single-message form.
    if msg:find("^RBALL:") then
        ApplyRealStats(Tokens(msg))
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

    local tCur, tMax, tVis, tStacks, tExp = msg:match("^RBHP:T:(%d+):(%d+):(%d+):(%d+):?(%d*)$")
    if tMax then
        targetData = { max = ApplyHpExponent(tonumber(tMax), tExp), visMax = tonumber(tVis), stacks = tonumber(tStacks) }
        RememberTargetHp(targetData)
        return
    end

    local uLow, uCur, uMax, uExp = msg:match("^RBHP:U:(%d+):(%d+):(%d+):?(%d*)$")
    if uMax then
        byGuid[tonumber(uLow)] = { max = ApplyHpExponent(tonumber(uMax), uExp) }
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
    -- Restore what we already know about this unit instead of blanking and
    -- waiting for the next push. A boss we have targeted before this fight comes
    -- back with its real (overflow-inclusive) figures immediately; anything we
    -- have not seen falls through to the creature path in HpInfoFor, which needs
    -- no server data at all.
    targetData = nil

    local g = UnitGUID("target")
    if g then
        local c = hpCacheByGuid[g]
        -- Only trust the cached entry if the unit still measures the same. A
        -- recycled GUID, or a mob rescaled by a different keystone level, must
        -- not inherit stale numbers.
        if c and UnitHealthMax("target") == c.visMax then
            targetData = c
        end
    end

    -- Paint on this frame. The driver would otherwise get to it up to 100ms
    -- later, which is exactly the kind of small hitch this change exists to
    -- remove -- there is no point sourcing the number instantly and then sitting
    -- on it.
    if UNITS[2] then
        RenderHp("target", UNITS[2].hpLabel)
        RenderPower("target", UNITS[2].ppLabel)
    end
end

local listener = CreateFrame("Frame")
listener:RegisterEvent("ADDON_LOADED")
listener:RegisterEvent("PLAYER_ENTERING_WORLD")
listener:RegisterEvent("PARTY_MEMBERS_CHANGED")
listener:RegisterEvent("CHAT_MSG_CHANNEL")
listener:RegisterEvent("CHAT_MSG_ADDON")
listener:RegisterEvent("PLAYER_TARGET_CHANGED")
listener:SetScript("OnEvent", function(self, event, a1, a2)
    if event == "ADDON_LOADED" then
        if a1 == ADDON_NAME then
            InitSavedVars()   -- SavedVariables are guaranteed present now
            JoinChannelByName(UnitName("player"))
            SuppressBlizzardText()
        end
        return
    end

    if event == "PLAYER_ENTERING_WORLD" or event == "PARTY_MEMBERS_CHANGED" then
        SuppressBlizzardText()  -- (re)hide Blizzard text as frames come/go
        -- Creature GUIDs do not survive a world change, and a fresh keystone can
        -- rescale the same mobs, so start the cache clean rather than carry
        -- entries that can only ever be wrong or dead.
        if event == "PLAYER_ENTERING_WORLD" then WipeHpCache() end
        return
    end

    if event == "PLAYER_TARGET_CHANGED" then
        OnTargetChanged()
        return
    end

    -- Two transports, on purpose.
    --
    -- CHAT_MSG_ADDON is where the pipe is moving: the client never renders it,
    -- so the protocol can no longer leak into chat when an addon fails to load.
    -- CHAT_MSG_CHANNEL is the old transport, kept because one payload serves
    -- both realms and a realm still running the previous worldserver would go
    -- silent otherwise. Drop the channel branch once every realm is converted.
    --
    --   CHAT_MSG_ADDON   : a1 = prefix, a2 = body
    --   CHAT_MSG_CHANNEL : a1 = body,   a2 = author (our own name on the pipe)
    local msg
    if event == "CHAT_MSG_ADDON" then
        if a1 ~= ADDON_PIPE_PREFIX then return end
        msg = a2
    else
        if a2 ~= UnitName("player") then return end
        msg = a1
    end
    if not msg then return end

    if msg:find("^RBHP:") or msg:find("^RBALL") or msg:find("^RBDMG:") or msg:find("^RBHEAL:") then
        OnLine(msg)
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
-- with our own, driven from the combat log. Blizzard-style: outgoing floats up
-- over the TARGET (its nameplate when shown, else the target frame), incoming
-- floats up over YOU; crits pop bigger. Live font: /dev64font, test: /dev64dmg.
-- ===========================================================================
local FONT_DIR = "Interface\\AddOns\\Uncapped64bitUI\\fonts\\"
local FCT_FONTS = {
    -- Built into the WoW client -- always present on every install.
    skurri   = "Fonts\\SKURRI.TTF",     -- the classic spiky WoW combat font
    arial    = "Fonts\\ARIALN.TTF",     -- condensed, clean, very readable
    morpheus = "Fonts\\MORPHEUS.TTF",   -- ornate fantasy serif
    friz     = "Fonts\\FRIZQT__.TTF",   -- default UI font
    -- Bundled with this addon (SIL OFL 1.1, from Google Fonts).
    -- Licences travel with them: fonts/LICENSES-OFL.txt.
    bangers   = FONT_DIR .. "Bangers-Regular.ttf",      -- comic impact
    anton     = FONT_DIR .. "Anton-Regular.ttf",        -- heavy condensed
    bebas     = FONT_DIR .. "BebasNeue-Regular.ttf",    -- tall caps
    russo     = FONT_DIR .. "RussoOne-Regular.ttf",     -- techno bold
    fjalla    = FONT_DIR .. "FjallaOne-Regular.ttf",    -- bold display
    metamorph = FONT_DIR .. "Metamorphous-Regular.ttf", -- fantasy
    righteous = FONT_DIR .. "Righteous-Regular.ttf",    -- retro rounded
    bungee    = FONT_DIR .. "Bungee-Regular.ttf",       -- chunky signage
    titan     = FONT_DIR .. "TitanOne-Regular.ttf",     -- cartoon bold
    creepster = FONT_DIR .. "Creepster-Regular.ttf",    -- horror
    pixel     = FONT_DIR .. "PressStart2P-Regular.ttf", -- pixel/8-bit
}
-- Live, user-tunable FCT settings. These are the defaults; they are overwritten
-- from SavedVariables (Uncapped64bitUIDB.fct) at ADDON_LOADED, and edited live
-- from the options panel (ESC > Interface > AddOns > "Uncapped 64-bit UI") and
-- /dev64font. Every FCT closure below reads them straight off this table, so a
-- change takes effect on the very next number that floats.
--   wiggleAmp    - how far heals sway side-to-side as they rise (px)
--   wiggleFreq   - how fast that sway oscillates (rad/s; lower = slower)
--   healDrop     - how far BELOW the target heals start (float up under its plate)
--   selfHealDrop - same for self-heals (start at your character, so a smaller drop)
--   spreadX/Y    - random scatter of each number's start point (breaks the baseline)
--   normalSize   - font size of ordinary (non-crit) hits and heals (px)
--   critSize     - font size a crit starts at, before it pops (px)
--   critPop      - font size crits grow to just after they land (px)
--   popTime      - seconds that crit grow-in takes
--   font         - key into FCT_FONTS (see the picker in the options panel)
local CFG_DEFAULTS = {
    wiggleAmp = 10, wiggleFreq = 4.0, healDrop = 120, selfHealDrop = 30,
    spreadX = 25, spreadY = 30, normalSize = 20, critSize = 34,
    critPop = 54, popTime = 0.15, font = "morpheus",
}
local Cfg = {}
for k, v in pairs(CFG_DEFAULTS) do Cfg[k] = v end

-- The resolved font path, kept in sync with Cfg.font. Reassigned at ADDON_LOADED
-- and whenever the font changes from the panel or /dev64font.
local FCT_FONT = FCT_FONTS[Cfg.font] or FCT_FONTS.morpheus

-- Assigned to the forward-declared InitSavedVars; runs once at ADDON_LOADED, when
-- Uncapped64bitUIDB is guaranteed loaded. Pulls saved tunables over the defaults,
-- resolves the font, and (on a brand-new install only) turns nameplates on once
-- so the over-target/over-ally combat text works out of the box.
InitSavedVars = function()
    Uncapped64bitUIDB = Uncapped64bitUIDB or {}
    local db = Uncapped64bitUIDB
    db.fct = db.fct or {}
    for k in pairs(Cfg) do
        if db.fct[k] ~= nil then Cfg[k] = db.fct[k] end
    end
    FCT_FONT = FCT_FONTS[Cfg.font] or FCT_FONTS.morpheus
    if not db.initialized then
        db.initialized = true
        pcall(SetCVar, "nameplateShowEnemies", "1")
        pcall(SetCVar, "nameplateShowFriends", "1")
    end
    if RefreshOptionsPanel then RefreshOptionsPanel() end
end

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
-- Blizzard-style anchoring: outgoing floats up over the TARGET (its nameplate
-- when one is shown, else the target frame); incoming floats up over YOU.
local function LooksLikeNameplate(f)
    if f:GetName() then return false end
    if f:GetNumChildren() < 1 then return false end
    local hb = select(1, f:GetChildren())
    return hb ~= nil and hb.GetObjectType and hb:GetObjectType() == "StatusBar"
end

local function NameplateName(f)
    for _, r in ipairs({ f:GetRegions() }) do
        if r.GetObjectType and r:GetObjectType() == "FontString" then
            local t = r:GetText()
            if t and t ~= "" and not tonumber(t) then return t end   -- name, not the level number
        end
    end
    return nil
end

local plateCache, plateCacheName
local function TargetPlate()
    if not UnitExists("target") or UnitIsDeadOrGhost("target") then return nil end
    local tname = UnitName("target")
    if plateCache and plateCache:IsShown() and plateCacheName == tname
        and NameplateName(plateCache) == tname then
        return plateCache
    end
    plateCache, plateCacheName = nil, nil
    for _, f in ipairs({ WorldFrame:GetChildren() }) do
        if f:IsShown() and LooksLikeNameplate(f) and NameplateName(f) == tname then
            plateCache, plateCacheName = f, tname
            return f
        end
    end
    return nil
end

local function CenterInUIParent(frame)
    if not frame or not frame:IsShown() then return nil end
    local x, y = frame:GetCenter()
    if not x then return nil end
    local s = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    return x * s, y * s
end

local function GetOutgoingPos()
    local plate = TargetPlate()
    if plate then
        local x, y = CenterInUIParent(plate)
        if x then return x, y + 24 end
    end
    if TargetFrame and TargetFrame:IsShown() and UnitExists("target") then
        local x, y = CenterInUIParent(TargetFrame)
        if x then return x, y - 18 end
    end
    return GetScreenWidth() * 0.5, GetScreenHeight() * 0.70
end

local function GetIncomingPos()
    return GetScreenWidth() * 0.5, GetScreenHeight() * 0.42
end

local fctPool, fctActive = {}, {}

-- Apply the current combat font at a given size, ALWAYS leaving a usable font set.
-- SetFont returns false (without setting anything) when the font file can't be
-- loaded -- most commonly a bundled font that was added while the client was
-- already running, which the client only picks up on a full restart. If we left
-- it there, the next SetText() would throw "Font not set", so fall back to a
-- built-in client font that is guaranteed to be loadable.
local FCT_FALLBACK_FONT = "Fonts\\FRIZQT__.TTF"
local function SafeSetFont(fs, size)
    if not fs:SetFont(FCT_FONT, size, "OUTLINE") then
        fs:SetFont(FCT_FALLBACK_FONT, size, "OUTLINE")
    end
end

-- Spawn any floating text (a damage number, a heal, or a "Dodge"/"Parry"/etc).
-- outgoing=true floats up over the target; false floats up over the player.
local function FctSpawnText(text, big, r, g, b, outgoing, heal)
    local x, y
    if outgoing then
        x, y = GetOutgoingPos()
    else
        x, y = GetIncomingPos()
    end
    x = x + math.random(-Cfg.spreadX, Cfg.spreadX)
    -- Scatter the start height too, so numbers don't all lift off one flat line.
    y = y + math.random(-Cfg.spreadY, Cfg.spreadY)
    -- Heals begin well UNDER the unit and float up to sit under the nameplate.
    if heal then y = y - (outgoing and Cfg.healDrop or Cfg.selfHealDrop) end
    local fs = table.remove(fctPool) or fctHost:CreateFontString(nil, "OVERLAY")
    local base = big and Cfg.critSize or Cfg.normalSize
    SafeSetFont(fs, base)
    fs:SetText(text)
    fs:SetTextColor(r, g, b)
    fs:SetAlpha(1)
    fs:ClearAllPoints()
    fs:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
    fs:Show()
    fctActive[#fctActive + 1] = { fs = fs, x = x, y0 = y, t = 0, dur = big and 1.6 or 1.2,
        rise = big and 95 or 70, wiggle = true, phase = math.random() * 6.2832,
        pop = big or false, base = base }
end

-- Assigns the forward-declared handler: the server feeds real (trillion-scale)
-- melee hits over the channel when they're past the 32-bit combat-log wall.
ShowRealDamage = function(real)
    FctSpawnText(Abbrev(real) .. "!", true, 1.0, 0.82, 0.0, true)
end

-- Real (trillion-scale) outgoing heal, fed over the channel when the client's
-- own combat log would show the 32-bit-capped value. Heal green, "+" prefix.
ShowRealHeal = function(real)
    FctSpawnText("+" .. Abbrev(real), true, 0.4, 1.0, 0.4, true, true)
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
            -- Crit "pop": grow from base size up to Cfg.critPop over the first
            -- Cfg.popTime seconds, then hold -- it visibly scales bigger just
            -- after it lands.
            if a.pop and not a.popped then
                if a.t >= Cfg.popTime then
                    SafeSetFont(a.fs, Cfg.critPop)
                    a.popped = true
                else
                    local pp = a.t / Cfg.popTime
                    local size = a.base + (Cfg.critPop - a.base) * (1 - (1 - pp) * (1 - pp))
                    SafeSetFont(a.fs, math.floor(size + 0.5))
                end
            end
            local wx = a.x
            if a.wiggle then
                wx = wx + math.sin(a.t * Cfg.wiggleFreq + a.phase) * Cfg.wiggleAmp
            end
            a.fs:SetPoint("CENTER", UIParent, "BOTTOMLEFT", wx, a.y0 + a.rise * p)
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

local function FctDamage(srcGUID, dstGUID, amount, crit, isSpell)
    if not amount or amount <= 0 then return end
    if FctMine(srcGUID) and amount >= FCT_REAL_WALL then return end
    local label = Abbrev(amount) .. (crit and "!" or "")
    if FctMine(srcGUID) then
        -- your damage: melee auto-attacks = white, spells/skills = yellow.
        -- crit -> big=true, which drives the size pop in the animation loop.
        if isSpell then FctSpawnText(label, crit, 1.0, 0.82, 0.0, true)
        else FctSpawnText(label, crit, 1, 1, 1, true) end
    elseif dstGUID == fctPlayerGUID then
        FctSpawnText(label, crit, 1.0, 0.4, 0.4, false)   -- damage you take
    end
end

-- Miss/dodge/parry/block/absorb/immune/resist -- avoided attacks.
local function FctMiss(srcGUID, dstGUID, missType)
    local label = MISS_TEXT[missType] or "Miss"
    if FctMine(srcGUID) then
        FctSpawnText(label, false, 0.85, 0.85, 0.85, true)   -- your attack was avoided
    elseif dstGUID == fctPlayerGUID then
        FctSpawnText(label, false, 0.85, 0.95, 1.0, false)     -- you avoided one
    end
end

local function FctHeal(srcGUID, dstGUID, amount, crit)
    if not amount or amount <= 0 then return end
    if FctMine(srcGUID) and amount >= FCT_REAL_WALL then return end  -- RBHEAL feed covers my own trillion heals
    if dstGUID == fctPlayerGUID then
        FctSpawnText("+" .. Abbrev(amount), crit, 0.4, 1.0, 0.4, false, true)
    elseif FctMine(srcGUID) then
        FctSpawnText("+" .. Abbrev(amount), crit, 0.4, 1.0, 0.4, true, true)
    end
end

local function FctOnCombatLog(...)
    local subevent = select(2, ...)
    local srcGUID  = select(3, ...)
    local dstGUID  = select(6, ...)
    if subevent == "SWING_DAMAGE" then
        local amount, overkill, school, resisted, blocked, absorbed, critical = select(9, ...)
        FctDamage(srcGUID, dstGUID, amount, critical, false)  -- melee swing -> white
    elseif subevent == "SWING_MISSED" then
        local missType = select(9, ...)
        FctMiss(srcGUID, dstGUID, missType)
    elseif subevent == "SPELL_DAMAGE" or subevent == "RANGE_DAMAGE" or subevent == "SPELL_PERIODIC_DAMAGE"
        or subevent == "DAMAGE_SHIELD" or subevent == "SPELL_BUILDING_DAMAGE" or subevent == "DAMAGE_SPLIT" then
        local spellId, spellName, spellSchool, amount, overkill, school, resisted, blocked, absorbed, critical = select(9, ...)
        FctDamage(srcGUID, dstGUID, amount, critical, true)  -- spell/skill -> yellow
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
    -- Keep Blizzard's OWN floating/scrolling combat text off on every world-enter
    -- so it never doubles up with ours. (Nameplates are no longer force-held on
    -- here -- see the one-time warning below.)
    DisableBlizzardFCT()
end)

-- Nameplates power the over-target / over-ally combat text: a unit's on-screen
-- position is read from its nameplate. We used to FORCE them on and re-assert on
-- every CVar change, but players disliked losing the ability to turn them off.
-- Now InitSavedVars just defaults them on for a fresh install; the first time a
-- player turns them off we tell them EXACTLY what they're giving up, remember we
-- said it, and never override or nag them again.
local function NameplatesOff()
    return GetCVar("nameplateShowEnemies") ~= "1" or GetCVar("nameplateShowFriends") ~= "1"
end

StaticPopupDialogs["UNCAPPED64_NAMEPLATE_WARNING"] = {
    text = "|cff40ff40Uncapped floating combat text|r\n\n"
        .. "Your outgoing damage floats over your target, and your heals float over the "
        .. "ally you healed -- both are positioned by reading that unit's nameplate.\n\n"
        .. "You just turned nameplates |cffff2020OFF|r. While they're off:\n\n"
        .. "|cffff8080-|r your damage numbers pile up in the center of the screen instead of over the enemy\n"
        .. "|cffff8080-|r heals you cast on other players no longer appear over them at all\n\n"
        .. "(Numbers over yourself are unaffected.)\n\n"
        .. "Press |cffffd100V|r, or use Interface > Names, to turn them back on. "
        .. "This warning only appears once.",
    button1 = OKAY,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local npWatch = CreateFrame("Frame")
local function MaybeWarnNameplatesOff()
    if not Uncapped64bitUIDB then return end   -- SavedVariables not loaded yet
    if Uncapped64bitUIDB.nameplateWarningShown then
        npWatch:SetScript("OnUpdate", nil)
        npWatch:UnregisterAllEvents()
        return
    end
    if NameplatesOff() then
        Uncapped64bitUIDB.nameplateWarningShown = true
        StaticPopup_Show("UNCAPPED64_NAMEPLATE_WARNING")
        npWatch:SetScript("OnUpdate", nil)
        npWatch:UnregisterAllEvents()
    end
end
-- CVAR_UPDATE catches the Interface panel and /console; the V key doesn't always
-- fire it, so a light poll backstops it. Both stop the instant the warning fires.
npWatch:RegisterEvent("CVAR_UPDATE")
npWatch:SetScript("OnEvent", MaybeWarnNameplatesOff)
local npWatchAccum = 0
npWatch:SetScript("OnUpdate", function(self, dt)
    npWatchAccum = npWatchAccum + dt
    if npWatchAccum < 0.5 then return end
    npWatchAccum = 0
    MaybeWarnNameplatesOff()
end)

SLASH_DEV64FONT1 = "/dev64font"
SlashCmdList["DEV64FONT"] = function(msg)
    local key = (msg or ""):lower():gsub("%s", "")
    if FCT_FONTS[key] then
        FCT_FONT = FCT_FONTS[key]
        Cfg.font = key
        if Uncapped64bitUIDB and Uncapped64bitUIDB.fct then Uncapped64bitUIDB.fct.font = key end
        if RefreshOptionsPanel then RefreshOptionsPanel() end
        DEFAULT_CHAT_FRAME:AddMessage("|cff40ff40[dev64]|r combat font -> " .. key)
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff40ff40[dev64]|r use /fct to pick a font, or one of: "
            .. "morpheus, skurri, friz, arial, bangers, anton, bebas, russo, fjalla, "
            .. "metamorph, righteous, bungee, titan, creepster, pixel")
    end
end

-- A sample burst of every FCT flavour, for tuning. Shared by /dev64dmg and the
-- options panel's Preview button.
local function FctPreview()
    FctSpawnText(Abbrev(math.random(100000000, 2000000000)) .. "!", true, 1, 1, 1, true)          -- melee crit (white, pops)
    FctSpawnText(Abbrev(math.random(1000000, 50000000)), false, 1, 1, 1, true)                    -- melee hit (white)
    FctSpawnText(Abbrev(math.random(1000000, 50000000)) .. "!", true, 1.0, 0.82, 0.0, true)       -- spell crit (yellow, pops)
    FctSpawnText(Abbrev(math.random(1000000, 50000000)), false, 1.0, 0.82, 0.0, true)             -- spell hit (yellow)
    FctSpawnText(Abbrev(math.random(50000000, 900000000)), false, 1.0, 0.4, 0.4, false)            -- taken
    FctSpawnText("Dodge", false, 0.85, 0.95, 1.0, false)                                            -- avoided
    FctSpawnText("Parry", false, 0.85, 0.95, 1.0, false)
    FctSpawnText("+" .. Abbrev(math.random(5000000, 80000000)), false, 0.4, 1.0, 0.4, false, true) -- target heal
    FctSpawnText("+" .. Abbrev(math.random(5000000, 80000000)), true, 0.4, 1.0, 0.4, false, true)  -- self heal crit
end

SLASH_DEV64DMG1 = "/dev64dmg"
SlashCmdList["DEV64DMG"] = FctPreview

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
-- Item tooltips (haste stat lines AND proc / equip-effect lines like Tempest
-- Keep's "chance to increase attack speed by N%") are handled by the unified
-- RewriteSpellHaste below, which also hooks OnTooltipSetItem. It substitutes
-- in place, so proc text keeps its "chance on hit..." context (a whole-line
-- rewrite would have destroyed it). See the spell / talent tooltip section.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Spell / talent tooltips: haste is Crit Damage now.
--
-- Rewrites POSITIVE haste on spell/talent tooltips into crit damage, on the
-- rendered text (real numbers): "attack and casting speed by 3%" -> "critical
-- strike damage by 3%" (1:1), and "haste rating by 340" -> "...by 0.34%" (/1000).
-- Slows (Curse of Tongues, Thunderclap: "reduces ... speed") and movement speed
-- are left untouched by the guard, so no debuff tooltip is mangled.
-- ---------------------------------------------------------------------------
local CDMG = "critical strike damage"
local function fmtCd(n)
    n = tonumber(n) or 0
    if n == math.floor(n) then return string.format("%d", n) end
    return string.format("%.2f", n)
end
local function rewriteHasteLine(t)
    local low = t:lower()
    if low:find("movement speed") or low:find("run speed") then return t end
    if low:find("reduc") or low:find("slow") or low:find("decreas") or low:find("lower")
       or low:find("cast time") or low:find("casting time") then return t end   -- slow -> leave
    if not (low:find("increas") or low:find("improv") or low:find("grant") or low:find("gain")
            or low:find("provid") or low:find("boost") or low:find("haste rating")) then return t end
    local s = t
    s = s:gsub("[Hh]aste [Rr]ating by (%d+)", function(n) return CDMG .. " by " .. fmtCd(tonumber(n)/1000) .. "%" end)
    s = s:gsub("(%d+)%s+[Hh]aste [Rr]ating", function(n) return fmtCd(tonumber(n)/1000) .. "% " .. CDMG end)
    s = s:gsub("(%d+%%)%s*[Mm]elee [Hh]aste", "%1 " .. CDMG)
    s = s:gsub("(%d+%%)%s*[Ss]pell [Hh]aste",  "%1 " .. CDMG)
    s = s:gsub("(%d+%%)%s*[Rr]anged [Hh]aste", "%1 " .. CDMG)
    s = s:gsub("(%d+%%)%s*[Hh]aste",           "%1 " .. CDMG)
    s = s:gsub("[Mm]elee, ranged, and spell casting speed", CDMG)
    s = s:gsub("[Mm]elee and ranged attack speed", CDMG)
    s = s:gsub("[Aa]ttack and casting speed", CDMG)
    s = s:gsub("[Mm]elee attack speed", CDMG)
    s = s:gsub("[Rr]anged attack speed", CDMG)
    s = s:gsub("[Aa]ttack speed", CDMG)
    s = s:gsub("[Cc]asting speed", CDMG)
    s = s:gsub("[Ss]pell [Hh]aste", CDMG)
    s = s:gsub("[Mm]elee [Hh]aste", CDMG)
    s = s:gsub("[Rr]anged [Hh]aste", CDMG)
    s = s:gsub("[Hh]aste [Rr]ating", CDMG)
    s = s:gsub("[Hh]aste", CDMG)
    return s
end
local function RewriteSpellHaste(tt)
    if not tt or not tt.GetName then return end
    local name = tt:GetName()
    if not name then return end
    for i = 1, tt:NumLines() do
        local fs = _G[name .. "TextLeft" .. i]
        local t = fs and fs:GetText()
        if t then
            local low = t:lower()
            if low:find("haste") or low:find("attack speed") or low:find("casting speed") then
                local nt = rewriteHasteLine(t)
                if nt ~= t then fs:SetText(nt) end
            end
        end
    end
end
for _, tname in ipairs({ "GameTooltip", "ItemRefTooltip", "ShoppingTooltip1", "ShoppingTooltip2" }) do
    local tt = _G[tname]
    if tt and tt.HookScript then
        tt:HookScript("OnTooltipSetSpell", RewriteSpellHaste)
        tt:HookScript("OnTooltipSetItem",  RewriteSpellHaste)   -- item stat + proc-effect lines
    end
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

-- What to credit a spell's scaling to, resolved in this order:
--   1. SPELL_SCALING_OVERRIDE, keyed by exact spell name
--   2. "Physical damage" in the text                  -> attack power
--   3. the caster's class, for classes that have only one relevant stat
--   4. the damage school named in the text
--
-- Step 3 matters: a Warrior, Rogue, Hunter or Death Knight has no meaningful
-- spell power, so crediting one of their abilities to it is simply wrong even
-- when the ability deals magic damage. Casters are the mirror image.
local AP, SP = "attack power", "spell power"

local CLASS_DEFAULT_STAT = {
    WARRIOR     = AP,
    ROGUE       = AP,
    HUNTER      = AP,
    DEATHKNIGHT = AP,
    MAGE        = SP,
    WARLOCK     = SP,
    PRIEST      = SP,
}
-- PALADIN, DRUID and SHAMAN are deliberately absent: each has both melee and
-- caster specs, so the school named in the tooltip is the better signal.

local SCHOOL_STAT = {
    ["Physical"] = AP,
    ["Holy"]     = SP,
    ["Fire"]     = SP,
    ["Frost"]    = SP,
    ["Arcane"]   = SP,
    ["Nature"]   = SP,
    ["Shadow"]   = SP,
}

-- Abilities whose scaling the rules above get wrong. Mostly hybrid melee
-- abilities that deal magic damage but scale from attack power. Extend freely --
-- one line each, and it wins over everything else.
local SPELL_SCALING_OVERRIDE = {
    -- Paladin: melee-weapon abilities dealing Holy damage
    ["Seal of Righteousness"]   = AP,
    ["Seal of Vengeance"]       = AP,
    ["Seal of Corruption"]      = AP,
    ["Seal of Command"]         = AP,
    ["Crusader Strike"]         = AP,
    ["Divine Storm"]            = AP,
    ["Hammer of the Righteous"] = AP,
    ["Shield of Righteousness"] = AP,
    ["Avenger's Shield"]        = SP,
    ["Hammer of Wrath"]         = SP,
    -- Shaman: Nature damage off weapon/attack power
    ["Stormstrike"]             = AP,
    ["Lava Lash"]               = AP,
    -- Druid: Feral abilities
    ["Swipe (Bear)"]            = AP,
    ["Maul"]                    = AP,
    -- Death Knight: Shadow/Frost damage scaling from attack power
    ["Death Coil"]              = AP,
    ["Icy Touch"]               = AP,
    ["Howling Blast"]           = AP,
    ["Death and Decay"]         = AP,
    ["Scourge Strike"]          = AP,
    -- Hunter: Nature/Arcane stings off ranged attack power
    ["Serpent Sting"]           = AP,
    ["Arcane Shot"]             = AP,
    ["Explosive Shot"]          = AP,
}

-- Remove figures that came from the client's own arithmetic. Ranges go first,
-- then any remaining number of four or more digits -- that threshold keeps the
-- genuinely useful small ones ("for 3 sec", "within 8 yards") intact.
-- Remove ONLY figures the client worked out from your stats.
--
-- The previous version deleted any number of four or more digits and annotated
-- any line containing the word "damage". That was far too broad: "Improved
-- Cleave -- Increases the bonus damage done by your Cleave ability by 40%" has
-- no computed figure at all, yet it was being rewritten to claim it scaled with
-- spell power. Every talent, racial, passive, buff and item mentioning damage or
-- healing hit the same problem.
--
-- So match the specific shapes WoW uses for a computed figure: a number, or a
-- range, sitting directly against a damage/healing/restore phrase. Percentages,
-- durations, ranks, cooldowns, radii and talent scaling are all left untouched --
-- the client did not derive those from your stats, so they were never wrong.
--
-- Returns the new text and whether anything was actually removed. The caller
-- annotates only when something was, which is what keeps talents out of this.
local function StripComputedFigures(text)
    local changed = false
    local function drop(replacement)
        return function(captured)
            changed = true
            return replacement == "%1" and captured or replacement
        end
    end

    -- Integer figures only: [%d,] not [%d,%.]. Including '.' in the class made the
    -- match swallow the sentence's full stop along with the number.
    --
    -- "Causes 576761472 to 576761600 Holy damage" -> "Causes Holy damage"
    text = text:gsub("%d[%d,]*%s+to%s+%d[%d,]*%s+(%a*%s*damage)", drop("%1"))
    -- "Deals 12345 Fire damage" / "for 12345 damage" -> drops just the number
    text = text:gsub("%d[%d,]*%s+(%a+%s+damage)", drop("%1"))
    text = text:gsub("%d[%d,]*%s+(damage)", drop("%1"))
    -- Healing and restoration: "restoring 12345 health"
    text = text:gsub("%d[%d,]*%s+to%s+%d[%d,]*%s+(health)", drop("%1"))
    text = text:gsub("%d[%d,]*%s+(health)", drop("%1"))
    -- "Heals a friendly target for 12345." -- the "for" goes too, or the sentence
    -- ends on a dangling preposition.
    text = text:gsub("([Hh]eals?[%a%s]-)for%s+%d[%d,]*%s+to%s+%d[%d,]*", drop("%1"))
    text = text:gsub("([Hh]eals?[%a%s]-)for%s+%d[%d,]*", drop("%1"))

    if not changed then
        return text, false
    end

    -- Tidy the gaps the removals leave behind.
    text = text:gsub("%s%s+", " ")
    text = text:gsub("%s+([%.,])", "%1")
    text = text:gsub("^%s+", "")
    return text, true
end

local function RewriteSpellTooltip(tooltip)
    -- 3.3.5 has no GetSpellName() on tooltips; the name is simply the first
    -- left-hand line, which is also what the override table is keyed on.
    local nameFS = _G[tooltip:GetName() .. "TextLeft1"]
    local spellName = nameFS and nameFS:GetText() or nil
    local governing = spellName and SPELL_SCALING_OVERRIDE[spellName] or nil
    local annotated = false

    local _, playerClass = UnitClass("player")

    for i = 2, tooltip:NumLines() do
        local fs = _G[tooltip:GetName() .. "TextLeft" .. i]
        if fs then
            local text = fs:GetText()
            if text then
                local stripped, removed = StripComputedFigures(text)

                -- Annotate only where a computed figure was actually removed.
                -- A line that merely mentions damage -- every talent, racial and
                -- passive in the game -- is left exactly as Blizzard wrote it.
                if removed and not annotated then
                    -- Physical always means attack power. Otherwise fall back to
                    -- the caster's class where that is unambiguous, and only then
                    -- to the school named in the line.
                    local stat = governing
                    if not stat and text:find("Physical") then
                        stat = AP
                    end
                    if not stat then
                        stat = CLASS_DEFAULT_STAT[playerClass]
                    end
                    if not stat then
                        for school, mapped in pairs(SCHOOL_STAT) do
                            if text:find(school) then
                                stat = mapped
                                break
                            end
                        end
                    end
                    stat = stat or SP

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

-- ---------------------------------------------------------------------------
-- Load banner.
--
-- This addon is the only thing filtering the RB* protocol out of chat and the
-- only thing rendering real numbers past the 32-bit wall, so "is it actually
-- running on this realm?" needs a definite answer rather than an inference from
-- whether chat looks wrong. Addon state is per character per realm, so it can
-- differ between realms on the same client with nothing else to show for it.
-- ---------------------------------------------------------------------------
local banner = CreateFrame("Frame")
banner:RegisterEvent("PLAYER_LOGIN")
banner:SetScript("OnEvent", function(self)
    local realm = GetRealmName and GetRealmName() or "?"
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff40ff40Uncapped 64-bit UI|r loaded on |cffffd100" .. realm ..
        "|r - RB* protocol filtered, real numbers active.")
    self:UnregisterAllEvents()
end)

-- ---------------------------------------------------------------------------
-- Options panel: ESC > Interface > AddOns > "Uncapped 64-bit UI".
--
-- Live sliders + font picker for the FCT tunables. Every change writes straight
-- to Cfg and SavedVariables and takes effect on the next number that floats --
-- there's no Apply step. RefreshOptionsPanel() re-syncs every widget from Cfg
-- (used after InitSavedVars loads the saved values, and after /dev64font).
-- ---------------------------------------------------------------------------
local optPanel = CreateFrame("Frame", "Uncapped64bitUIOptions", UIParent)
-- Nest under the shared "Uncapped" hub (registered by UncappedOptions). If that
-- addon is missing, a .parent naming a non-existent category just falls back to
-- a top-level entry, so this is safe either way.
optPanel.name = "Combat Text"
optPanel.parent = "Uncapped"

local optTitle = optPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
optTitle:SetPoint("TOPLEFT", 16, -16)
optTitle:SetText("Uncapped 64-bit UI  |cff808080-|r  Floating Combat Text")

local optSub = optPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
optSub:SetPoint("TOPLEFT", optTitle, "BOTTOMLEFT", 0, -8)
optSub:SetPoint("RIGHT", optPanel, "RIGHT", -16, 0)   -- wrap to the real panel width
optSub:SetJustifyH("LEFT")
optSub:SetText("Tune how your damage and healing numbers look and move. Changes apply "
    .. "instantly; click Preview to see a sample burst.")

-- One slider bound to a Cfg key. Writes Cfg + SavedVariables live and snaps to step.
local SLIDERS = {
    { key = "normalSize",   label = "Normal text size",   min = 10,   max = 48,  step = 1,    fmt = "%d px" },
    { key = "critSize",     label = "Crit text size",     min = 16,   max = 60,  step = 1,    fmt = "%d px" },
    { key = "critPop",      label = "Crit pop size",      min = 16,   max = 96,  step = 1,    fmt = "%d px" },
    { key = "popTime",      label = "Crit pop time",      min = 0.05, max = 0.5, step = 0.05, fmt = "%.2f s" },
    { key = "wiggleAmp",    label = "Heal sway distance", min = 0,    max = 30,  step = 1,    fmt = "%d px" },
    { key = "wiggleFreq",   label = "Heal sway speed",    min = 0,    max = 10,  step = 0.5,  fmt = "%.1f" },
    { key = "healDrop",     label = "Target heal drop",   min = 0,    max = 250, step = 5,    fmt = "%d px" },
    { key = "selfHealDrop", label = "Self heal drop",     min = 0,    max = 150, step = 5,    fmt = "%d px" },
    { key = "spreadX",      label = "Horizontal spread",  min = 0,    max = 60,  step = 1,    fmt = "%d px" },
    { key = "spreadY",      label = "Vertical spread",    min = 0,    max = 60,  step = 1,    fmt = "%d px" },
}

local sliderWidgets = {}
local function MakeSlider(meta, point, xOff, yOff)
    local name = "Uncapped64Slider_" .. meta.key
    local s = CreateFrame("Slider", name, optPanel, "OptionsSliderTemplate")
    -- Anchor to the panel EDGE (not a hardcoded x) so the layout fits whatever
    -- width the Interface options panel actually gives us on this client.
    s:SetPoint(point, optPanel, point, xOff, yOff)
    s:SetWidth(185)
    s:SetMinMaxValues(meta.min, meta.max)
    s:SetValueStep(meta.step)
    _G[name .. "Low"]:SetText(tostring(meta.min))
    _G[name .. "High"]:SetText(tostring(meta.max))
    local caption = _G[name .. "Text"]
    local function label(v) caption:SetText(meta.label .. ":  |cffffd100" .. string.format(meta.fmt, v) .. "|r") end
    s.__label = label
    s:SetValue(Cfg[meta.key])
    label(Cfg[meta.key])
    s:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value / meta.step + 0.5) * meta.step   -- snap to step
        Cfg[meta.key] = value
        if Uncapped64bitUIDB and Uncapped64bitUIDB.fct then Uncapped64bitUIDB.fct[meta.key] = value end
        label(value)
    end)
    sliderWidgets[meta.key] = s
    return s
end

-- Two even columns: the left column hugs the panel's left edge, the right column
-- its right edge. Whatever the panel's real width, both stay on it.
local SLIDER_HALF = math.ceil(#SLIDERS / 2)
for i, meta in ipairs(SLIDERS) do
    if i <= SLIDER_HALF then
        MakeSlider(meta, "TOPLEFT",  16,  -72 - (i - 1) * 50)
    else
        MakeSlider(meta, "TOPRIGHT", -16, -72 - (i - 1 - SLIDER_HALF) * 50)
    end
end

-- Font picker.
local FONT_ORDER = {
    "morpheus", "skurri", "friz", "arial",
    "bangers", "anton", "bebas", "russo", "fjalla",
    "metamorph", "righteous", "bungee", "titan", "creepster", "pixel",
}
local FONT_LABEL = {
    morpheus  = "Morpheus (WoW fantasy)",
    skurri    = "Skurri (WoW combat)",
    friz      = "Friz Quadrata (WoW UI)",
    arial     = "Arial Narrow (WoW clean)",
    bangers   = "Bangers (comic impact)",
    anton     = "Anton (heavy)",
    bebas     = "Bebas Neue (tall caps)",
    russo     = "Russo One (techno)",
    fjalla    = "Fjalla One (bold)",
    metamorph = "Metamorphous (fantasy)",
    righteous = "Righteous (retro)",
    bungee    = "Bungee (signage)",
    titan     = "Titan One (cartoon)",
    creepster = "Creepster (horror)",
    pixel     = "Press Start 2P (pixel)",
}

local fontHeader = optPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
fontHeader:SetPoint("TOPLEFT", optPanel, "TOPLEFT", 20, -320)
fontHeader:SetText("Combat font")

local fontDrop = CreateFrame("Frame", "Uncapped64FontDropdown", optPanel, "UIDropDownMenuTemplate")
fontDrop:SetPoint("TOPLEFT", optPanel, "TOPLEFT", 4, -340)
local fontProbe = optPanel:CreateFontString(nil, "OVERLAY")   -- offscreen; tests loadability
local function OnFontPicked(key)
    Cfg.font = key
    FCT_FONT = FCT_FONTS[key] or FCT_FONT
    if Uncapped64bitUIDB and Uncapped64bitUIDB.fct then Uncapped64bitUIDB.fct.font = key end
    UIDropDownMenu_SetSelectedValue(fontDrop, key)
    UIDropDownMenu_SetText(fontDrop, FONT_LABEL[key])
    -- Bundled fonts added while the client is running only register on a full
    -- restart; until then the combat text quietly uses the default. Say so.
    if not fontProbe:SetFont(FCT_FONT, 20, "OUTLINE") then
        DEFAULT_CHAT_FRAME:AddMessage("|cff40ff40[FCT]|r \"" .. (FONT_LABEL[key] or key)
            .. "\" needs a full client restart to load -- using the default font until you restart.")
    end
end
UIDropDownMenu_Initialize(fontDrop, function(self, level)
    for _, key in ipairs(FONT_ORDER) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = FONT_LABEL[key]
        info.value = key
        info.func = function() OnFontPicked(key) end   -- capture key; don't depend on self.value
        info.checked = (Cfg.font == key)
        UIDropDownMenu_AddButton(info, level)
    end
end)
UIDropDownMenu_SetWidth(fontDrop, 180)

-- Preview + Reset buttons.
local previewBtn = CreateFrame("Button", nil, optPanel, "UIPanelButtonTemplate")
previewBtn:SetWidth(110)
previewBtn:SetHeight(24)
previewBtn:SetPoint("TOPLEFT", optPanel, "TOPLEFT", 20, -382)
previewBtn:SetText("Preview")
previewBtn:SetScript("OnClick", function() FctPreview() end)

local resetBtn = CreateFrame("Button", nil, optPanel, "UIPanelButtonTemplate")
resetBtn:SetWidth(150)
resetBtn:SetHeight(24)
resetBtn:SetPoint("TOPLEFT", optPanel, "TOPLEFT", 140, -382)
resetBtn:SetText("Reset to defaults")

local function ApplyDefaults()
    for k, v in pairs(CFG_DEFAULTS) do
        Cfg[k] = v
        if Uncapped64bitUIDB and Uncapped64bitUIDB.fct then Uncapped64bitUIDB.fct[k] = v end
    end
    FCT_FONT = FCT_FONTS[Cfg.font] or FCT_FONT
    if RefreshOptionsPanel then RefreshOptionsPanel() end
end
resetBtn:SetScript("OnClick", ApplyDefaults)

-- Push every current Cfg value back into the widgets (after a load or a slash cmd).
RefreshOptionsPanel = function()
    for key, s in pairs(sliderWidgets) do
        s:SetValue(Cfg[key])
        if s.__label then s.__label(Cfg[key]) end
    end
    UIDropDownMenu_SetSelectedValue(fontDrop, Cfg.font)
    UIDropDownMenu_SetText(fontDrop, FONT_LABEL[Cfg.font] or Cfg.font)
end

optPanel.refresh = RefreshOptionsPanel
optPanel.okay    = function() end   -- changes are already applied live
optPanel.cancel  = function() end
optPanel.default = ApplyDefaults    -- the Interface panel's "Defaults" button
InterfaceOptions_AddCategory(optPanel)
RefreshOptionsPanel()

-- Open the panel directly.
SLASH_UNCAPPEDFCT1 = "/fct"
SlashCmdList["UNCAPPEDFCT"] = function()
    -- Called twice on purpose: a long-standing client quirk means the first call
    -- opens Interface options but doesn't scroll to our category.
    InterfaceOptionsFrame_OpenToCategory(optPanel)
    InterfaceOptionsFrame_OpenToCategory(optPanel)
end
