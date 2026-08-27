-- Uncapped64bitUI -- shows the server's REAL 64-bit numbers past the 32-bit client wall.
--
-- Shows the server's REAL health numbers (past the 32-bit client wall) on the
-- default unit frames, plus the power (mana/rage/energy/runic) numbers, with
-- Blizzard's own bar text suppressed so nothing flashes in behind ours.
--
-- Wire (personal channel, filtered out of chat):
--   UHP:S:<realCur>:<realMax>                     -- the player themselves
--   UHP:T:<realCur>:<realMax>:<visMax>:<guidLow>  -- current target (may be a boss)
--   UHP:U:<guidLow>:<realCur>:<realMax>           -- a group member (party/raid)
--
-- Health is proxied on the wire (proxy% == real%), so we reconstruct real from
-- the native bar: real = (nativeCur/nativeMax) * realMax. Power is NOT proxied
-- (it still fits 32-bit), so those numbers are read straight from the client.
--
-- The 4th field of UHP:T was <stacks>, a retired mechanism pinned to 0 (it used to
-- carry a boss's banked HP-overflow phases; creatures hold a true 64-bit pool now).
-- ★ [#998] It now carries the target's guidLow instead. A UHP:T line previously
-- identified nobody, so one still in flight when the player switched target painted
-- the new target at the old one's scale -- and the visMax comparison that was meant
-- to catch that is pinned to exactly 2e9 for every unit above the proxy budget, so it
-- could never reject anything for the units it existed to protect. Same field count,
-- so an older addon build still parses the line and ignores the value as it always did.
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
-- Truncated/abbreviated: 1234 -> 1.23K, 2.80M, 4.53B, 9.99T, 5.17Qa, 9.22Qi.
-- Shared by HP, damage and stat displays so everything reads the same way.
--
-- ★★ [audit 2026-08-22 NC-04] THIS MIRRORS FormatMagnitude IN UncappedCT.dll,
--    AND MUST KEEP DOING SO. The DLL rewrites the number the ENGINE draws over a
--    mob's body; this formats the same number everywhere Lua paints it --
--    scrolling combat text, the chat log, health bars, the character sheet.
--
--    They disagreed. The DLL had Qa and Qi and truncated to two decimals; this
--    stopped at T, printed no decimals there, and ROUNDED. So a 9.22e18 hit read
--    "9.22Qi" on the body floater and "9223231T" in the chat log AT THE SAME
--    INSTANT, and 1,999,999,999 read "1.99B" in one place and "2.00B" in the
--    other. One hit, two numbers, on screen together.
--
--    Truncated and not rounded for the DLL's reason: 999.999T reads as 999.99T
--    rather than 1000.00T. The fraction is dropped entirely when it is zero, so
--    a flat two billion is "2B" and not "2.00B".
--
--    The fraction is floor(n / (scale/100)) % 100 rather than a subtraction of
--    the whole part -- the same expression the DLL uses, so the two cannot drift
--    apart on a rounding edge. And `whole` is always under 1000 within its own
--    tier, which matters: this client's Lua is a 32-bit build, so
--    string.format("%d", 9.2e18) would not survive the trip.
local function Abbrev(n)
    n = tonumber(n) or 0
    if n < 0 then return string.format("%d", math.ceil(n)) end

    local scale, suffix
    if     n >= 1e18 then scale, suffix = 1e18, "Qi"
    elseif n >= 1e15 then scale, suffix = 1e15, "Qa"
    elseif n >= 1e12 then scale, suffix = 1e12, "T"
    elseif n >= 1e9  then scale, suffix = 1e9,  "B"
    elseif n >= 1e6  then scale, suffix = 1e6,  "M"
    elseif n >= 1e3  then scale, suffix = 1e3,  "K"
    else return string.format("%d", math.floor(n)) end

    local whole = math.floor(n / scale)
    local frac  = math.floor(n / (scale / 100)) % 100
    if frac > 0 then
        return string.format("%d.%02d%s", whole, frac, suffix)
    end
    return string.format("%d%s", whole, suffix)
end

-- Forward declaration: the real-damage floater lives in the FCT section (bottom
-- of the file), but the channel handler (above it) needs to call it.
local ShowRealDamage
local ShowRealHeal

-- Forward declarations for the combat-text correction feed (UCT), which lives
-- with the rest of the combat text at the bottom of the file. The channel
-- handler above it has to hand corrections in, and PLAYER_ENTERING_WORLD has to
-- push the hide-under threshold up, so both need names that exist by then.
local CT_Ingest
local CT_PushHideUnder
local CT_ApplyBlizzardSurfaces

-- Forward declarations for the config/options plumbing at the bottom of the file
-- (referenced by the ADDON_LOADED handler and slash commands above them).
local InitSavedVars
local RefreshOptionsPanel
local ApplyStatusTextDefaults
local ApplyCameraZoomDefaults
local ApplyFloatingCombatTextRepair

-- ---------------------------------------------------------------------------
-- Bar text: wrap Blizzard's formatter instead of overlaying it.
-- ---------------------------------------------------------------------------
-- This used to build our own FontString over every bar, blank Blizzard's, and
-- re-hide it each time it tried to Show -- three mechanisms fighting the default
-- UI for the same pixels, all of which had to be re-applied whenever a frame was
-- created or recycled (hence the SuppressBlizzardText calls scattered through the
-- event handler).
--
-- Blizzard already repaints every unit-frame bar's text through a single
-- function, TextStatusBar_UpdateTextString, on exactly the events that change the
-- value. Post-hooking that and rewriting the digits in place gets the same result
-- with none of the fighting: Blizzard keeps ownership of layout, font, colour,
-- anchoring and the statusText CVar modes, and we substitute only the number.
--
-- Three things fall out of this for free:
--   * every bar Blizzard drives is covered -- target, focus, pet, raid, boss --
--     not just the six frames the old hardcoded UNITS table listed;
--   * third-party unit frames built on the stock template work too;
--   * the 10Hz driver goes away, because Blizzard's own event cadence is already
--     the right one (see the note where the driver used to be).
--
-- hooksecurefunc is a post-hook, so none of this taints the secure path.

-- The bar's unit token. Blizzard sets .unit on unit-frame bars in
-- UnitFrame_Initialize; fall back to the parent's unit for bars belonging to a
-- custom frame built from the same template.
local function BarUnit(bar)
    if bar.unit then return bar.unit end
    local p = bar.GetParent and bar:GetParent()
    return p and p.unit or nil
end

-- The FontString a bar paints its value into. Most bars carry it as .TextString,
-- but some only have the globally-named one the template creates ("<bar>Text"),
-- so both are tried -- the overlay code this replaced made the same allowance and
-- dropping it would silently skip those bars.
local function BarTextString(bar)
    local fs = bar.TextString
    if not fs and bar.GetName and bar:GetName() then
        fs = _G[bar:GetName() .. "Text"]
    end
    return fs
end

-- Is this the parent frame's HEALTH bar rather than its power bar? Both are
-- painted by the same formatter, but only health is proxied, so only health needs
-- substituting -- power still fits 32-bit and Blizzard's own text is correct.
local function IsHealthBar(bar)
    local p = bar.GetParent and bar:GetParent()
    if p then
        if p.healthbar == bar then return true end
        if p.manabar == bar then return false end
    end
    -- Custom frame: fall back on the name, which the stock template derives from
    -- the parent ("...HealthBar" / "...ManaBar").
    local n = bar.GetName and bar:GetName()
    return n ~= nil and n:find("HealthBar") ~= nil
end

-- ---------------------------------------------------------------------------
-- State fed by the server.
-- ---------------------------------------------------------------------------
local selfData   = nil   -- { max }
local targetData = nil   -- { max, visMax, guid }   [#998] guid replaced the retired stacks
local byGuid     = {}    -- [guidLow] = { max }   (group members)

-- [absorb] Remaining shield on the player and on the current target, from UABS.
--
-- Server-fed and not derivable here: 3.3.5a has no client API for remaining
-- absorb at all (UnitAura gives duration and stacks, never the amount), so
-- unlike health there is no "the client already knows" case -- if the feed is
-- silent, we genuinely do not know, and show nothing rather than guess.
local absorbSelf, absorbTarget = 0, 0

-- [spell tooltips] Server-computed damage per spell, keyed by spellId, plus the
-- set already asked about so a hover storm sends one request rather than one per
-- frame. Declared up here because the channel handler (above the tooltip code)
-- writes into them. Both are wiped on a gear change -- see spellDmgWatcher.
local spellDmgCache = {}
local spellDmgAsked = {}

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

-- The low 32 bits of a unit's GUID -- the same number the server sends in UHP:U.
--
-- ★ [audit 2026-08-22 AN-10] TAKE THE LAST EIGHT HEX DIGITS, NEVER ALL SIXTEEN.
-- This used to parse the whole 16-digit string. Lua 5.1's based tonumber is
-- strtoul, and unsigned long is 32 bits in this client's build, so ANY guid with
-- a non-zero high half came back saturated at 4294967295 -- one value, shared by
-- every such unit. Player guids happen to carry no high bits, which is the only
-- reason it never misfired; the assumption was stated in a comment and defended
-- by nothing. Slicing the last eight digits is what the server actually computes
-- (GetRawValue() & 0xFFFFFFFF) and is what CT_Low already does, so the two key
-- derivations in this file now agree by construction instead of by luck.
local function GuidLow(unit)
    local g = UnitGUID(unit)
    if not g then return nil end
    return tonumber(g:sub(-8), 16)
end

-- Unit tokens that can be showing another player from the UHP:U feed. Used to
-- turn a GUID-keyed update back into the frames that need repainting. Party
-- frames only: raid frames are not driven by the stock unit-frame formatter, so
-- there is nothing here for them to refresh.
local GROUP_UNITS = { "party1", "party2", "party3", "party4", "target", "focus" }

-- The client's own max-health field, but ONLY when it is provably the real
-- number rather than a proxy.
--
-- HealthProxyOf returns the value UNCHANGED whenever the real max fits under
-- HEALTH_PROXY_BUDGET, and above it pins the visible max to exactly the budget.
-- So a visible max STRICTLY below the budget is not a proxy at all: it IS the
-- real figure, already here, the instant the unit exists -- which covers
-- essentially everything anyone meets outside a deep keystone.
--
-- "Strictly" carries weight. A visible max of exactly the budget is ambiguous:
-- it is either a unit whose real max happens to land there, or ANY saturated
-- unit whatsoever. That case is not trusted, and the feed answers instead.
--
-- This applies to PLAYERS too. An earlier version excluded them, believing player
-- health to be "proxied regardless of size". SetRealMaxHealth says otherwise --
-- below the budget it writes the real value into the proxy field verbatim, for
-- players exactly as for creatures. That mistaken exclusion is the whole reason
-- the server still had to send a line for every unsaturated player in the group.
local function NativeMaxIfExact(unit)
    local vmax = UnitHealthMax(unit)
    if vmax and vmax > 0 and vmax < HEALTH_PROXY_BUDGET then return vmax end
    return nil
end

local function HpInfoFor(unit)
    if unit == "player" then
        if selfData then return selfData.max, 0, nil end
        local vmax = NativeMaxIfExact(unit)
        if vmax then return vmax, 0, nil end
    elseif unit == "target" then
        -- [#998] targetData.stacks is gone (the slot carries a guid now); the middle
        -- return stays 0, which is what the retired field always evaluated to anyway.
        if targetData then return targetData.max, 0, targetData.visMax end
        -- Fallback: a group member we already have HP for (UHP:T can lag by a
        -- tick, and a far player only resolves once the server catches up).
        local low = GuidLow(unit)
        if low then
            local d = byGuid[low]
            if d then return d.max, 0, nil end
        end

        local vmax = NativeMaxIfExact(unit)
        if vmax then return vmax, 0, nil end
    else
        local low = GuidLow(unit)
        if low then
            local d = byGuid[low]
            if d then return d.max, 0, nil end
        end

        local vmax = NativeMaxIfExact(unit)
        if vmax then return vmax, 0, nil end
    end
    return nil
end

-- The real current/max pair for a unit, or nil when there is nothing to
-- substitute -- either the server has not answered yet, or (the common case) the
-- client's own field is already the real number because the unit sits below the
-- proxy budget. Returning nil is what lets Blizzard's own text stand unmodified.
local function RealHealthPair(unit)
    -- [audit 2026-08-22 AN-05] The <stacks> banked-HP-overflow branch that used
    -- to sit here has been removed. It was unreachable in production: the only
    -- producer of the field hardcodes a literal 0 (mythic_plus_worldscript.cpp),
    -- and UHP:S / UHP:U carry no stacks field at all -- creatures hold a true
    -- 64-bit pool now, which is what the header comment at the top of this file
    -- means by "retired". The field is still parsed and still ignored, so a line
    -- from an older worldserver is accepted rather than rejected; only /dev64's
    -- smoke line ever put a non-zero value in it.
    local rmax = HpInfoFor(unit)
    if not rmax then return nil end

    local nmax = UnitHealthMax(unit)
    local frac = (nmax > 0) and (UnitHealth(unit) / nmax) or 0
    return frac * rmax, rmax
end

-- Bars we have seen Blizzard paint, grouped by unit token, so a feed update can
-- ask for a repaint of exactly the bars that show that unit. Weak keys: a frame
-- that goes away (a raid frame on group change) must not be pinned here.
--
-- Populated from inside the hook rather than from a fixed list, so a bar we have
-- never painted -- and which therefore has nothing to refresh -- is never in it.
local barsByUnit = setmetatable({}, { __mode = "k" })

local function RememberBar(unit, bar)
    local t = barsByUnit[unit]
    if not t then
        t = setmetatable({}, { __mode = "k" })
        barsByUnit[unit] = t
    end
    t[bar] = true
end

-- Substitute the real number into a bar Blizzard has just painted. Bails out
-- (leaving Blizzard's text exactly as written) for power bars, for units we have
-- no real figure for, and when the bar is not showing text at all.
local function ApplyRealBarText(bar)
    if type(bar) ~= "table" then return end
    local fs = BarTextString(bar)
    if not fs then return end
    if not IsHealthBar(bar) then return end

    local unit = BarUnit(bar)
    if not unit or not UnitExists(unit) then return end
    RememberBar(unit, bar)

    -- Percentage display needs no substitution at all. The proxy is proportional
    -- (proxy% == real%), so the percentage Blizzard already wrote is correct at
    -- any scale -- it is only the absolute numbers that saturate. Leaving this
    -- mode alone also means a player who prefers percentages keeps exactly the
    -- stock UI, which the old always-on overlay took away from them.
    -- Mirrors TextStatusBar_UpdateTextString's own condition verbatim (see
    -- FrameXML/TextStatusBar.lua): a single boolean CVar, which any individual
    -- bar may override in either direction. There is no "both" mode on 3.3.5a --
    -- an earlier version of this checked a "statusTextDisplay" CVar for
    -- "PERCENT"/"BOTH", and no such CVar exists on this client, so the guard
    -- never once fired.
    if (GetCVarBool("statusTextPercentage") or bar.showPercentage) and not bar.showNumeric then
        return
    end

    -- Absorb shield, appended as "(+12.4B)".
    --
    -- Text rather than a filled overlay on the bar. A retail-style overlay reads
    -- better, but it means positioning a texture against a bar whose width, art
    -- and anchoring differ across every unit frame and every third-party addon --
    -- a lot of ways to end up with a stray rectangle on someone's screen. The
    -- text rides the substitution that is already proven to work everywhere.
    --
    -- Shown on the player and target only, because those are the only two the
    -- feed carries; a party frame with no shield figure simply omits it rather
    -- than implying zero.
    local shield = 0
    if unit == "player" then shield = absorbSelf
    elseif unit == "target" then shield = absorbTarget end

    local cur, max = RealHealthPair(unit)
    if not cur then
        -- No real-health substitution needed, but there may still be a shield
        -- worth showing -- append it to whatever Blizzard already wrote rather
        -- than dropping the information.
        if shield > 0 then
            local t = fs:GetText()
            if t and t ~= "" and not t:find("(+", 1, true) then
                fs:SetText(t .. "  |cff40c0ff(+" .. Abbrev(shield) .. ")|r")
            end
        end
        return
    end

    local text = Abbrev(cur) .. "  /  " .. Abbrev(max)
    if shield > 0 then
        text = text .. "  |cff40c0ff(+" .. Abbrev(shield) .. ")|r"
    end
    fs:SetText(text)
end

if type(TextStatusBar_UpdateTextString) == "function" then
    hooksecurefunc("TextStatusBar_UpdateTextString", ApplyRealBarText)
end

-- Ask Blizzard to repaint a unit's bars.
--
-- The hook above only fires when Blizzard itself decides to repaint -- damage
-- taken, target switched, power spent. A line arriving on our channel changes a
-- number Blizzard has no reason to know changed, so the feed has to poke it.
-- This is the replacement for the old 10Hz driver: instead of re-rendering
-- everything 10 times a second on the chance something moved, we repaint the
-- affected unit at the moment we learn it moved.
local function RefreshUnitBars(unit)
    local t = unit and barsByUnit[unit]
    if not t then return end
    if type(TextStatusBar_UpdateTextString) ~= "function" then return end
    for bar in pairs(t) do
        if BarTextString(bar) then TextStatusBar_UpdateTextString(bar) end
    end
end

-- ---------------------------------------------------------------------------
-- Channel plumbing.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Uncapped character sheet (AllStats integration).
--
-- The AllStats addon paints the whole paperdoll stat panel using the stock
-- client APIs, which read 32-bit wire fields -- so once a stat is inflated past
-- ~2.1e9 they show a low, capped number when you press C. The server feeds us
-- the REAL values over the channel (UALL:...); right after AllStats repaints
-- its panel we overwrite the affected lines with the real, truncated numbers.
-- The percentage lines (crit/dodge/parry/block) and mana regen already carry
-- real values (they live in float fields), so those we just truncate in place.
-- ---------------------------------------------------------------------------
local realStats = {}   -- latest values from UALL
local allPending = {}  -- buffered UALLA/UALLB halves until both have arrived

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

-- [deep-keystone] The UHP real* fields are a MANTISSA; the server appends a health
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
    -- Per-hit combat-text corrections. Tested FIRST and returned on immediately:
    -- this is the only line on the pipe that arrives at combat cadence, and every
    -- pattern below would otherwise be tried against it on every hit.
    local corrections = msg:match("^UCT:(.+)$")
    if corrections then
        if CT_Ingest then CT_Ingest(corrections) end
        return
    end

    -- Spell tooltip damage, answering a USPELLDMG request. Cached until gear
    -- changes; no reply at all is a valid answer and leaves the tooltip bare.
    -- ★ [audit 2026-08-22 NC-14] THREE CAPTURES, THREE VARIABLES. The pattern
    --   always had three and only two were bound, so the top of the range was
    --   matched and then silently thrown away. The server happens to send
    --   min == max today (spell_tooltip_comms_playerscript.cpp writes `total`
    --   twice), so nothing was visibly lost -- but the moment it sends a real
    --   range the tooltip would have shown the low end and called it the answer.
    local dmgSpell, dmgMin, dmgMax = msg:match("^USPELLDMGR:(%d+):(%d+):(%d+)$")
    if dmgSpell then
        spellDmgCache[tonumber(dmgSpell)] = { tonumber(dmgMin), tonumber(dmgMax) }
        return
    end

    -- Absorb shields: one line carries both ends. "0:0" arrives once when the
    -- last shield expires, which is what clears the readout -- the server's dedup
    -- then goes quiet until something changes.
    local aSelf, aTarget = msg:match("^UABS:(%d+):(%d+)$")
    if aSelf then
        absorbSelf   = tonumber(aSelf)   or 0
        absorbTarget = tonumber(aTarget) or 0
        RefreshUnitBars("player")
        RefreshUnitBars("target")
        return
    end

    local sCur, sMax, sExp = msg:match("^UHP:S:(%d+):(%d+):?(%d*)$")
    if sMax then
        selfData = { max = ApplyHpExponent(tonumber(sMax), sExp) }
        RefreshUnitBars("player")
        return
    end

    -- Comprehensive real character-sheet stats (past the 32-bit wire wall).
    -- UALL now arrives as two halves (UALLA + UALLB).
    --
    -- Sixteen 64-bit fields is ~277 bytes at trillion scale, past the client's
    -- 255-byte addon-message cap -- it would have truncated silently on exactly
    -- the scaled characters this feed exists for. The halves are buffered and
    -- applied together, so a dropped or reordered one never paints a half-filled
    -- stat panel. "UALL:" (undivided) is still accepted from any realm still
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

    local bodyA = msg:match("^UALLA:(.+)$")
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

    local bodyB = msg:match("^UALLB:(.+)$")
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
    if msg:find("^UALL:") then
        ApplyRealStats(Tokens(msg))
        return
    end

    -- Real (trillion-scale) outgoing melee/spell hit, past the 32-bit combat-log wall.
    local dmg = msg:match("^UDMG:(%d+)$")
    if dmg then
        if ShowRealDamage then ShowRealDamage(tonumber(dmg)) end
        return
    end

    -- Real (trillion-scale) outgoing heal, past the 32-bit combat-log wall.
    local heal = msg:match("^UHEAL:(%d+)$")
    if heal then
        if ShowRealHeal then ShowRealHeal(tonumber(heal)) end
        return
    end

    -- [#998] The 4th field used to be a retired, ignored <stacks> slot; it now carries
    -- the guid of the unit this line describes. Same field count, so this parse is
    -- unchanged in shape -- only the meaning of a value we were already reading.
    local tCur, tMax, tVis, tGuid, tExp = msg:match("^UHP:T:(%d+):(%d+):(%d+):(%d+):?(%d*)$")
    if tMax then
        --[[
          ★★ [#998] REJECT A LINE THAT IS ABOUT SOMEBODY ELSE.

          This assignment used to be unconditional, and the two guards downstream that
          were meant to catch a mismatch both compare UnitHealthMax("target") to visMax.
          Above 2 billion the server pins visMax to exactly 2e9 for EVERY unit, so both
          comparisons become 2e9 == 2e9 and never reject anything -- for exactly the
          units they exist to protect.

          The visible result is the reported one: an in-flight line about a mob with
          865 trillion health lands after you have switched to one with 874 billion, and
          the new target's bar is painted at the old target's scale until the next pass
          corrects it. Switch back and it lurches the other way. It only ever happens
          above 2e9, because below that the exact value is used and no substitution
          occurs.

          A guid comparison cannot degenerate. If the line is not about the unit we are
          currently looking at, it is dropped -- the server re-sends on target change, so
          nothing is lost by ignoring a stale one.
        ]]
        local low = tonumber(tGuid)
        if low and low ~= 0 and GuidLow("target") and low ~= GuidLow("target") then
            return
        end

        targetData = { max = ApplyHpExponent(tonumber(tMax), tExp), visMax = tonumber(tVis), guid = low }
        RememberTargetHp(targetData)
        RefreshUnitBars("target")
        return
    end

    local uLow, uCur, uMax, uExp = msg:match("^UHP:U:(%d+):(%d+):(%d+):?(%d*)$")
    if uMax then
        local low = tonumber(uLow)
        byGuid[low] = { max = ApplyHpExponent(tonumber(uMax), uExp) }

        -- Repaint whichever frames currently show that player. The feed is keyed
        -- by GUID, not by unit token, and the same character can be on several
        -- frames at once (party3 and target and focus), so every token that
        -- resolves to this GUID is refreshed rather than just the first.
        for _, u in ipairs(GROUP_UNITS) do
            if GuidLow(u) == low then RefreshUnitBars(u) end
        end
        return
    end
end

-- Keep our protocol lines out of chat.
ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", function(self, event, msg)
    if msg and (msg:find("^UHP:") or msg:find("^UALL:") or msg:find("^UDMG:")
        or msg:find("^UHEAL:") or msg:find("^UCT:")) then
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

    -- Repaint on this frame rather than waiting. Blizzard repaints the target
    -- bars on its own for the target switch, but it does so with whatever it
    -- knew before the line above restored our cached figures, so the substitution
    -- would otherwise land one repaint late.
    RefreshUnitBars("target")
end

-- ===========================================================================
-- BANNED / MAP-RESTRICTED EFFECT MARKERS ON ITEM TOOLTIPS  (report #456)
-- ===========================================================================
--
-- A 3.3.5a item tooltip is assembled by the CLIENT out of its own cached copy
-- of item_template. The server never composes that text and physically cannot
-- append a line to it -- which is why a player holding an item whose effect the
-- realm has switched off reads a perfectly normal proc line, tries to extract
-- it, and gets a bare refusal with nothing to read. That was #456.
--
-- So the server sends the SET OF ITEMS and we draw the line. Two sets, because
-- the realm has two different rulings and they must not read the same:
--
--   banItems[entry]        the effect cannot be extracted or soulbound off it
--   restrictItems[entry]   = mapId; the effect only functions on that map
--
-- ★ Item entries, not spell ids. All this hook has is a link. There is no way
-- to get from a rendered "Equip: Increases spell damage by 325" line back to
-- the spell that produced it, so the item id is the only key the two sides can
-- share. The server derives the sets by walking item_template once at startup.
--
-- Declared HERE, above the listener, so both the message handler below and the
-- tooltip hook much further down capture the same upvalues.
local banItems       = {}    -- [itemId] = true
local partialItems   = {}    -- [itemId] = true; banned, but only SOME of its effects (#788)
local restrictItems  = {}    -- [itemId] = mapId
local restrictMaps   = {}    -- [mapId]  = map name, sent by the server
local banFeedLoaded  = false
local banFeedAskedAt = 0

local BAN_PIPE_PREFIX = "REAGENTBANK"   -- client -> server half of the UNC pipe

local function RequestBanFeed()
    if type(SendAddonMessage) ~= "function" then return end
    -- Throttled: a realm running an older worldserver simply never answers, and
    -- a tooltip-driven retry must not turn that into a message every hover.
    local now = GetTime()
    if banFeedAskedAt > 0 and (now - banFeedAskedAt) < 60 then return end
    banFeedAskedAt = now
    pcall(SendAddonMessage, BAN_PIPE_PREFIX, "ICBAN", "WHISPER", UnitName("player"))
end

-- Fill a set from one chunked "a,b,c" payload. The server splits the list
-- across as many messages as it needs to stay under the 255-byte addon-message
-- cap, and every chunk is independent -- order does not matter and a lost one
-- costs exactly the items it carried, never the whole feed.
local function AbsorbBanChunk(payload, mapId)
    for id in payload:gmatch("(%d+)") do
        local n = tonumber(id)
        if n then
            if mapId then restrictItems[n] = mapId else banItems[n] = true end
        end
    end
end

local function OnBanLine(msg)
    local body = msg:match("^ICBAN:(.*)$")
    if body then AbsorbBanChunk(body); return true end

    -- [#788] A subset of the ICBAN entries: items where only SOME of the effects are
    -- banned. No pattern collision with the line above -- "^ICBAN:" needs the colon
    -- immediately, and this has a P there.
    local pBody = msg:match("^ICBANP:(.*)$")
    if pBody then
        for id in pBody:gmatch("(%d+)") do
            local n = tonumber(id)
            if n then partialItems[n] = true end
        end
        return true
    end

    if msg:find("^ICBANEND:") then
        banFeedLoaded = true
        return true
    end

    local mapId, mapName = msg:match("^ICBANM:(%d+):(.+)$")
    if mapId then
        restrictMaps[tonumber(mapId)] = mapName
        return true
    end

    local rMap, rBody = msg:match("^ICBANR:(%d+):(.*)$")
    if rMap then
        AbsorbBanChunk(rBody, tonumber(rMap))
        return true
    end

    if msg:find("^ICBANREND:") then return true end
    return false
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
        end
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        -- Late enough that the client's own CVar load has finished and will not
        -- overwrite us (see the note on ApplyStatusTextDefaults).
        if ApplyStatusTextDefaults then ApplyStatusTextDefaults() end
        if ApplyCameraZoomDefaults then ApplyCameraZoomDefaults() end
        -- [#926] Same timing requirement as the two above: the client's own CVar load
        -- must have finished, or it overwrites the repair on the way in.
        if ApplyFloatingCombatTextRepair then ApplyFloatingCombatTextRepair() end
    end

    if event == "PLAYER_ENTERING_WORLD" or event == "PARTY_MEMBERS_CHANGED" then
        -- Nothing to re-apply as frames come and go: the formatter hook is
        -- installed once on the shared function, so a bar created later is
        -- covered the first time Blizzard paints it.
        --
        -- Creature GUIDs do not survive a world change, and a fresh keystone can
        -- rescale the same mobs, so start the cache clean rather than carry
        -- entries that can only ever be wrong or dead.
        if event == "PLAYER_ENTERING_WORLD" then
            WipeHpCache()
            -- The ban sets are static realm data; ask once a session and keep
            -- them. The throttle in RequestBanFeed absorbs the repeat entries
            -- (every zone-in fires this event).
            if not banFeedLoaded then RequestBanFeed() end
        end
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

    -- ★★ EVERY PREFIX OnLine PARSES MUST BE LISTED HERE. This is the only real
    -- call site (the definition is above; /dev64 below injects test lines), so a
    -- prefix missing from this list is a feed that arrives, is dropped, and
    -- leaves no trace anywhere: the server keeps sending, the parse branch never
    -- runs, and nothing on either end ever reports a fault.
    --
    -- UABS: and USPELLDMGR: were both omitted, and both features were dead from
    -- the day they shipped -- the shield suffix on the unit-frame bars never
    -- rendered once, and "Approx. N with your stats" was requested, computed,
    -- replied and binned on every single hover.
    --
    -- ⚠ Adding a branch to OnLine? Add its prefix here IN THE SAME EDIT.
    if msg:find("^UHP:") or msg:find("^UALL") or msg:find("^UDMG:")
        or msg:find("^UHEAL:") or msg:find("^UCT:")
        or msg:find("^UABS:") or msg:find("^USPELLDMGR:") then
        OnLine(msg)
    elseif msg:find("^ICBAN") then
        OnBanLine(msg)
    end
end)

-- Local smoke test (no server): /dev64
SLASH_DEVUNCAPPED641 = "/dev64"
SlashCmdList["DEVUNCAPPED64"] = function()
    OnLine("UHP:S:1500000000:1500000000")
    OnLine("UHP:T:87500000000:90000000000:1000000000:170")
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
--   minFloat     - hide any floater below this value entirely (0 = show all)
--   legacyFct    - draw with our own floaters instead of the scrolling region
local CFG_DEFAULTS = {
    wiggleAmp = 10, wiggleFreq = 4.0, healDrop = 120, selfHealDrop = 30,
    spreadX = 25, spreadY = 30, normalSize = 20, critSize = 34,
    critPop = 54, popTime = 0.15, font = "morpheus",
    minFloat = 0,
    legacyFct = false,
}
local Cfg = {}
for k, v in pairs(CFG_DEFAULTS) do Cfg[k] = v end

-- Parse a human-written threshold into a number: "500k", "2.5M", "1b", "750000".
--
-- The inverse of Abbrev, and it has to exist because nobody is going to type
-- 500000000000 into a box -- the whole UI speaks in K/M/B/T, so the input must
-- too. Forgiving about case, spaces and thousands separators; strict about
-- everything else, returning nil so a typo is REJECTED rather than silently
-- becoming a threshold that hides every number in the game.
local function ParseAbbrev(s)
    if type(s) == "number" then return s end
    if type(s) ~= "string" then return nil end
    s = s:gsub("%s+", ""):gsub(",", "")
    if s == "" then return 0 end
    local num, suf = s:match("^(%d+%.?%d*)([KkMmBbTt]?)$")
    if not num then return nil end
    local v = tonumber(num)
    if not v then return nil end
    return v * (({ k = 1e3, m = 1e6, b = 1e9, t = 1e12 })[suf:lower()] or 1)
end

-- Is this floater too small to be worth drawing?
--
-- Applies to incoming as well as outgoing, and to crits as well as ordinary hits.
-- Both are deliberate: a number too small to read is too small to matter in
-- either direction, and a crit under the player's own threshold is still noise.
-- One rule with no exceptions, so the setting behaves exactly as it reads --
-- "hide under this value" hiding some things under that value would be worse
-- than not having it.
--
-- Defined up here rather than beside the FCT handlers because ShowRealDamage /
-- ShowRealHeal (the UDMG/UHEAL feed path) sit above them and need it too;
-- anything declared later would be captured as nil.
--
-- ONE EXCEPTION, AND IT IS THE OTHER HALF OF REPORTS #199 / #221.
--
-- A drawn number that lands inside the wire band is not a number: it is a
-- SATURATED hit whose true magnitude has been encoded into the low bits (server
-- side, WireMagnitude in Damage64Log.h). Whatever it reads as -- always around
-- 2.14B -- the hit itself was at least 2,147,483,520 and in practice far larger.
-- Comparing that against a threshold players set in the TRILLIONS hid precisely
-- the biggest hits in the game while letting small ones through, which is the
-- exact inversion the server side of this filter had. Fail open: a saturated hit
-- is never "too small to be worth drawing".
--
-- Only the band is exempted, not everything above CT_MATCH_FLOOR. A genuine,
-- unsaturated hit that would have landed in the band is pushed to BAND_BASE - 1
-- by the encoder precisely so the band means one thing, and that value still
-- means what it says -- so it stays filterable.
-- ★★ MASTER SWITCH for this addon's own floating combat text. Retired
--    2026-08-08 (owner's call) because UncappedCT.dll now corrects the ENGINE
--    body floaters directly and renders them as K/M/B/T, which is strictly
--    better: over the body rather than off to the side, and one renderer to keep
--    in step with the wire format instead of two.
--
--    Left as a named flag rather than ripped out. The drawing code below is
--    still reached by the /dev64 settings preview, and a single false is a much
--    smaller thing to reason about -- and to reverse -- than a partially deleted
--    pipeline.
local FCT_ADDON_DRAWS = false

local CT_BAND_BASE_MIN = 2145386496   -- WireMagnitude::BAND_BASE
local CT_BAND_BASE_MAX = 2147483647   -- INT32_MAX

-- ★ [audit 2026-08-22 AN-14] The digits every encoded value necessarily starts
-- with ("214" today), used as a PLAIN-find rejection gate on the chat rewriter.
--
-- Every chat line the client prints -- guild, whisper, say, the lot -- passes
-- through CT_RewriteChatLine, and its first test was a Lua PATTERN find for a
-- ten-digit run. That runs the pattern engine over the whole line every time. A
-- plain find is a memchr-style scan with no engine at all, and since the whole
-- point of the band is that it sits just under INT32_MAX, any line carrying an
-- encoded number MUST contain this substring. So ordinary chat is rejected for a
-- fraction of the old cost and the pattern test only sees the few lines that
-- could plausibly match.
--
-- Derived from the two bounds rather than written as a literal, so widening the
-- band can never silently turn this gate into a filter that drops real lines.
-- Computed once at load; nil (gate disabled) if the bounds ever share no prefix.
local CT_BAND_DIGIT_HINT
do
    local lo, hi = tostring(CT_BAND_BASE_MIN), tostring(CT_BAND_BASE_MAX)
    local n = 0
    while n < #lo and n < #hi and lo:byte(n + 1) == hi:byte(n + 1) do n = n + 1 end
    CT_BAND_DIGIT_HINT = (#lo == #hi and n > 0) and lo:sub(1, n) or nil
end

-- ---------------------------------------------------------------------------
-- Decoding the wire band
-- ---------------------------------------------------------------------------
-- A saturated hit does not arrive as a number; it arrives as a mini-float packed
-- into the low 21 bits above BAND_BASE (server side: WireMagnitude in
-- Damage64Log.h). 6-bit exponent, 15-bit mantissa with an implicit leading 1:
--
--     wire = BAND_BASE + (exponent * 32768) + mantissa
--     real = (mantissa + 32768) * 2^exponent
--
-- ★ THIS IS WHY THE SERVER'S CORRECTION FEED IS DEAD, AND WHY THAT IS FINE.
--
--   The feed used to send one addon message per saturated hit carrying the true
--   figure. It cannot fire any more: every caller now pins on the ENCODED value,
--   which lives in [2145386496, 2147483647], and the server's own gate needs a
--   value clearing 2147483520 -- i.e. exponent 63, which Encode never emits
--   (it caps at 47). The two sides disagreed in the same direction: CT_MATCH_FLOOR
--   below is 2147483008, ABOVE BAND_BASE, so this addon would have refused to
--   look up an encoded hit even if one had been sent.
--
--   Re-opening the feed would have been the wrong repair anyway. It puts one
--   message on the wire per saturated hit, and a 250-mob AoE tick produces 250
--   of them -- exactly the flood the band encoding was invented to remove.
--   Decoding here costs nothing, works for every hit including ones no feed
--   would have been allowed to cover, and cannot be rate-limited away.
--
-- ⚠ PRECISION. ~4.5 significant digits, by construction. The melee packet writes
--   each sub-damage as float32 as well as uint32, and float32 near 2^31 can only
--   represent multiples of 256, so the low 8 bits of the code may be lost in
--   transit. The mantissa is laid out LOW precisely so that costs ~0.4% of the
--   displayed figure instead of corrupting the exponent. These numbers are drawn
--   abbreviated ("4.7T"), so the error is invisible at the size it applies to.
--
-- Exponents above 47 are refused here exactly as they are on the server: the
-- mantissa carries 16 bits, so 63 - 16 = 47 is the largest shift that cannot
-- overflow, and a foreign value that merely happens to land in the band must be
-- passed through untouched rather than mangled into nonsense.
local CT_MANTISSA_STEP = 32768        -- 1 << WireMagnitude::MANTISSA_BITS
local CT_MAX_EXPONENT  = 47           -- WireMagnitude::MAX_EXPONENT

local function CT_DecodeBand(wire)
    if type(wire) ~= "number" then return nil end
    if wire < CT_BAND_BASE_MIN or wire > CT_BAND_BASE_MAX then return nil end

    local code     = wire - CT_BAND_BASE_MIN
    local exponent = math.floor(code / CT_MANTISSA_STEP)
    if exponent > CT_MAX_EXPONENT then return nil end

    local mantissa = (code - exponent * CT_MANTISSA_STEP) + CT_MANTISSA_STEP
    return mantissa * (2 ^ exponent)
end

local function FctBelowThreshold(amount)
    local m = Cfg.minFloat or 0
    if m <= 0 or not amount then return false end
    if amount >= CT_BAND_BASE_MIN and amount <= CT_BAND_BASE_MAX then return false end
    return amount < m
end

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

    -- The status-text migration is NOT run here -- see ApplyStatusTextDefaults
    -- below, which PLAYER_ENTERING_WORLD drives instead.
    if RefreshOptionsPanel then RefreshOptionsPanel() end
end

-- ★★ A ONE-SHOT MIGRATION MUST VERIFY, NOT ASSUME. [audit 2026-08-22 AN-02]
--
-- pcall(SetCVar, ...) proves only that the call did not raise, and every migration below
-- is guarded by a SavedVariables flag that never runs again. An unverified write plus an
-- eagerly-set flag is therefore a repair that marks itself successful while doing nothing,
-- on every account, permanently. That is exactly what happened to the #926 floater repair
-- (three CVars this client does not have, flag set on the way IN, pcall's answer thrown
-- away), and to two earlier attempts at the status-text one -- which is why its flag is
-- already at version 3.
--
-- So: write it, READ IT BACK, and let the caller decide what to do with the answer. The
-- read-back is what catches the case pcall cannot -- a name the client does not know
-- (GetCVar returns nil) and a value the client refuses and quietly leaves alone.
--
-- ⚠ Placement is load-bearing: ApplyFloatingCombatTextRepair captures this as an upvalue,
--   so a definition BELOW the call site would silently resolve to a global nil.
local function SetCVarVerified(name, want)
    if not pcall(SetCVar, name, want) then return false end
    local ok, got = pcall(GetCVar, name)
    if not ok or got == nil then return false end   -- no such CVar on this client
    return tostring(got) == tostring(want)
end


-- One-time status-text migration. Runs on PLAYER_ENTERING_WORLD, NOT ADDON_LOADED.
--
-- Bar text now rides on Blizzard's own status text rather than an overlay drawn
-- over it, so the text has to be switched on and in a numeric mode or there is
-- nothing for the hook to substitute into. Two things made earlier attempts at
-- this silently do nothing:
--
--   * Wrong CVar names. 3.3.5a has no single "statusText", and no
--     "statusTextDisplay" at all. Visibility is one CVar per frame type and
--     numeric-vs-percentage is a separate boolean. Every bad name was swallowed
--     by pcall, so there was no error to explain the non-effect. Names below are
--     taken from FrameXML/TextStatusBar.lua and InterfaceOptionsPanels.xml.
--   * Wrong timing. Setting them during ADDON_LOADED is too early -- the client
--     finishes loading its own saved CVars afterwards and overwrites them.
--
-- Flag is versioned because two earlier broken attempts already set flags of
-- their own on tester accounts; reusing a name would permanently skip exactly
-- the people who still need this to run.
ApplyStatusTextDefaults = function()
    local db = Uncapped64bitUIDB
    if not db or db.statusTextMigrated3 then return end
    db.statusTextMigrated3 = true

    for _, cv in ipairs({ "playerStatusText", "targetStatusText",
                          "partyStatusText", "petStatusText" }) do
        pcall(SetCVar, cv, "1")
    end
    pcall(SetCVar, "statusTextPercentage", "0")
end

-- One-time repair of the engine floater CVars (report #926, "Custom Battle text not
-- working -- the dmg numbers etc not working or showing at all").
--
-- ★★ THE ENGINE FLOATERS ARE THE ONLY RENDERER LEFT, SO ONE CVAR AT 0 IS A BLANK SCREEN.
--
-- Since 2026-08-08 this addon does not draw combat text (FCT_ADDON_DRAWS is false) and
-- CT_ApplyBlizzardSurfaces pins SHOW_COMBAT_TEXT to "0", so Blizzard's scrolling region is
-- off on purpose. Everything the player sees comes from UncappedCT.dll -- which detours
-- sub_7E6030, the world-text choke point, and therefore only ever rewrites a floater the
-- engine has ALREADY decided to emit. The decision is made upstream in sub_722340, which
-- reads CombatDamage / PetMeleeDamage / CombatHealing (NativeCT/notes/CLIENT_MAP.md:41-47,
-- :124-132). With one of those at 0 the engine emits nothing, the DLL has nothing to
-- correct, and the player has no combat numbers at all. That is exactly the report.
--
-- ⚠⚠ THE NAMES, AND THE MISTAKE THIS REPLACES. This client is 3.3.5a and has NO
--   floatingCombatText* CVars at all. The first attempt at this repair -- shipped
--   2026-08-18 as the answer to #926 -- set floatingCombatTextCombatDamage / ...Healing /
--   ...State, so it did nothing whatsoever. Those are the same three names the retired
--   DisableBlizzardFCT used, which means the premise the first attempt was written on --
--   "this addon turned them off, so it must turn them back on" -- was ALSO wrong: that
--   code never switched anything off either. Verified from the binary, not remembered:
--       grep -a -o -E "floatingCombatText[A-Za-z]*" Client\...\UncappedClient.dat
--   returns nothing, while CombatDamage / CombatHealing / PetMeleeDamage / PetSpellDamage
--   / CombatLogPeriodicSpells are all present with their description strings; and the
--   client's own options table -- Interface\FrameXML\InterfaceOptionsPanels.lua:1244-1247
--   -- names the same four as its Combat panel checkboxes. UncappedPerf.lua already had
--   them right. [audit 2026-08-22 AN-02 / NC-11]
--
-- ⚠ fctCombatState IS a real CVar on this client, and it is NOT the fix. It is the Lua
--   scrolling system's, not the engine's, and we pin that system off deliberately -- so
--   setting it either does nothing or drags back the second renderer 2026-08-08 removed.
--   Renaming the third name was the obvious move and it is the wrong one; it is DROPPED.
--   CombatLogPeriodicSpells is left alone too: a player with only that at 0 still sees
--   direct hits, so it is not the "nothing at all" case, and the /uperf checkbox does not
--   own it -- turning it on here would make the repair and the control disagree.
--
-- ★★ THE FLAG NOW RECORDS THE OUTCOME, NOT THE ATTEMPT, and that is the part worth
--   copying everywhere. Version 1 set its flag on the FIRST line and threw pcall's answer
--   away, so a repair that did nothing marked itself done on every account that logged in
--   -- and correcting the names alone would still have reached nobody. Each write is now
--   read back through SetCVarVerified, and the flag is set only once every one of them is
--   proven to have stuck. A repair that fails stays armed and tries again next login.
--
-- ⚠ The flag is versioned for the reason recorded on ApplyStatusTextDefaults: every
--   account that has logged in since 2026-08-18 already carries fctCVarRepaired1 from the
--   attempt that did nothing, so reusing that name would permanently skip precisely the
--   players who still have no numbers.
ApplyFloatingCombatTextRepair = function()
    local db = Uncapped64bitUIDB
    if not db or db.fctCVarRepaired2 then return end

    -- ★ A player who has actually used the /uperf checkbox has made this choice out loud.
    --   Record the repair as not-needed rather than leaving it armed to override them.
    if db.perf and db.perf.fctChoice then
        db.fctCVarRepaired2 = true
        return
    end

    -- The four the /uperf checkbox owns, so the repair and the control agree about what
    -- "damage numbers" means. PetSpellDamage has no checkbox anywhere in the stock client
    -- UI, which is exactly why it needs setting here.
    local GATES = { "CombatDamage", "CombatHealing", "PetMeleeDamage", "PetSpellDamage" }

    local changed, allTook = false, true
    for _, cv in ipairs(GATES) do
        local ok, before = pcall(GetCVar, cv)
        if ok and before == "0" then changed = true end
        if not SetCVarVerified(cv, "1") then allTook = false end
    end

    if not allTook then
        -- ⚠ DO NOT SET THE FLAG. This is the whole point of the rewrite: a repair that did
        --   not work must not claim it did. Count the failures so a later session finds
        --   evidence instead of silence -- version 1 left none.
        db.fctCVarRepairFailures = (db.fctCVarRepairFailures or 0) + 1
        -- Bounded on purpose. Retrying is right while it might yet work; retrying FOREVER
        -- would re-force these on every zone-in and take the choice away from a player who
        -- turned them off. Three logins covers a transient; after that we stop and SAY SO,
        -- because a silent give-up is how this bug survived a fix in the first place.
        if db.fctCVarRepairFailures >= 3 then
            db.fctCVarRepaired2 = true
            if DEFAULT_CHAT_FRAME then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff4040[Uncapped]|r couldn't switch your combat "
                    .. "numbers back on -- this client refused the setting. Please report that, "
                    .. "and try Interface options -> Uncapped -> Performance in the meantime.")
            end
        end
        return
    end

    db.fctCVarRepaired2      = true
    db.fctCVarRepaired1      = nil   -- set by the attempt that did nothing; it means nothing
    db.fctCVarRepairFailures = nil

    if changed and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff40ff40[Uncapped]|r Your combat numbers were switched "
            .. "off in the client's own settings, so nothing was drawing them. Turned back on. "
            .. "If that was on purpose, the switch is Interface options -> Uncapped -> "
            .. "Performance -> \"Show damage numbers over enemies\".")
    end
end

-- Same shape and same reasoning as ApplyStatusTextDefaults directly above: driven by
-- PLAYER_ENTERING_WORLD rather than ADDON_LOADED, because the client finishes loading
-- its own saved CVars after ADDON_LOADED and would overwrite us; and gated on a
-- versioned SavedVariables flag, so a player who deliberately zooms back in keeps
-- their choice instead of having it re-forced on every login.
--
-- ★ WHY AN ADDON AND NOT A CLIENT PATCH: the ceiling is a CVar, not a compiled
--   constant, and the client's own options panel already exposes half of it.
--   Interface\FrameXML\InterfaceOptionsPanels.lua line 1440 -- extracted from
--   patch-enUS-3.MPQ with Launcher\tools\mpq\mpqlib.py, not remembered -- reads:
--       cameraDistanceMaxFactor = { text = "MAX_FOLLOW_DIST", minValue = 1, maxValue = 2, ... }
--   so 2.0 is the client's OWN maximum for the factor. Almost nobody has moved that
--   slider off its default of 1, which is why "let me zoom out further" reads as a
--   missing feature when half of it shipped with the game.
--
--   The other half is cameraDistanceMax, which the client registers with a default of
--   15.0 (the literal sits beside the CVar name in the client binary) and which has NO
--   slider at all -- there is no way for a player to raise it from the interface.
--   Effective maximum zoom is cameraDistanceMax x cameraDistanceMaxFactor.
--
-- ⚠ 50 IS A REQUEST, NOT A VERIFIED CEILING. The client keeps a registered range per
--   CVar ("Value out of range (%f - %f)" lives in the same string block in the binary)
--   and that upper bound was never proved. So the value is asked for and then READ
--   BACK: whatever the client actually granted is what gets recorded, and a refusal
--   degrades to "we kept the factor bump", never to a broken camera. Do NOT replace
--   this with a bare SetCVar and a remembered number -- that is precisely the mistake
--   the 777-versus-1277 farclip note exists to prevent.
ApplyCameraZoomDefaults = function()
    local db = Uncapped64bitUIDB
    if not db or db.cameraZoomMigrated1 then return end
    db.cameraZoomMigrated1 = true

    -- Factor first: 2.0 is proven from the client's own options panel, so if only one
    -- of the two takes, this is the one worth having.
    pcall(SetCVar, "cameraDistanceMaxFactor", "2")
    pcall(SetCVar, "cameraDistanceMax", "50")

    -- Record what the client actually accepted, so a later session can find out whether
    -- the 50 was honoured without having to guess at it again.
    local ok, granted = pcall(GetCVar, "cameraDistanceMax")
    db.cameraDistanceMaxGranted = ok and tonumber(granted) or nil
end

-- (The old DisableBlizzardFCT lived here. It turned off Blizzard's floating AND
-- scrolling combat text so our own floaters owned every kind of combat feedback.
-- Only half of that survives -- see CT_ApplyBlizzardSurfaces down in the
-- combat-text section, which still suppresses the ENGINE floaters but now hands
-- the scrolling region the numbers instead of silencing it.)

local MISS_TEXT = {
    MISS = "Miss", DODGE = "Dodge", PARRY = "Parry", BLOCK = "Block",
    DEFLECT = "Deflect", ABSORB = "Absorb", IMMUNE = "Immune",
    RESIST = "Resist", EVADE = "Evade", REFLECT = "Reflect",
}

-- [audit 2026-08-22 AN-03] Commafy() and SCHOOL_COLOR were removed here. Both
-- were file-locals with no reader anywhere in the addon -- nothing outside the
-- file could ever have reached them. Commafy was also wrong above 1e15, where
-- tostring() (%.14g) emits scientific notation its comma loop cannot match, so
-- it would have printed "9.2233720368548e+18" untouched the first time a real
-- number reached it. Everything on screen goes through Abbrev(), which mirrors
-- the DLL's FormatMagnitude. If a grouped-digits format is ever wanted, write it
-- against that contract rather than restoring this.

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

-- ★ [audit 2026-08-22 AN-16] Forward declaration for the animator, so the spawn
-- function below can ARM it. The frame is left with no OnUpdate at load and only
-- carries one while fctActive is non-empty. It used to run every frame for the
-- whole session, walking an empty list -- and since FCT_ADDON_DRAWS is false the
-- list is empty except during the options preview, so it was a per-frame call to
-- do nothing, on every client, forever.
local fctAnimate

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
    -- ★ [AN-16] Arm on the transition from empty to one; the animator disarms
    -- itself on the way back. Re-setting an already-set OnUpdate every spawn
    -- would be harmless but pointless, so it is gated on the count.
    if #fctActive == 1 then fctHost:SetScript("OnUpdate", fctAnimate) end
end

-- Assigns the forward-declared handler: the server feeds real (trillion-scale)
-- melee hits over the channel when they're past the 32-bit combat-log wall.
--
-- LEGACY ONLY now. UDMG/UHEAL carry a SUM -- every saturated hit a player landed
-- inside the server's merge window, added together and drawn as one number. That
-- was the right answer while the only alternative was a stack of thirty pinned
-- numbers on one spot, but it is not what happened, and the UCT feed replaces it
-- with the truth per hit. Drawing both would put a merged total on screen
-- alongside the individual hits it is made of.
--
-- The parse stays either way: the server still sends these, the legacy renderer
-- still wants them, and a realm running an older worldserver has nothing else.
ShowRealDamage = function(real)
    if not FCT_ADDON_DRAWS then return end
    if not Cfg.legacyFct then return end
    if FctBelowThreshold(real) then return end
    FctSpawnText(Abbrev(real) .. "!", true, 1.0, 0.82, 0.0, true)
end

-- Real (trillion-scale) outgoing heal, fed over the channel when the client's
-- own combat log would show the 32-bit-capped value. Heal green, "+" prefix.
ShowRealHeal = function(real)
    if not FCT_ADDON_DRAWS then return end
    if not Cfg.legacyFct then return end
    if FctBelowThreshold(real) then return end
    FctSpawnText("+" .. Abbrev(real), true, 0.4, 1.0, 0.4, true, true)
end

fctAnimate = function(self, dt)
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
    -- ★ [AN-16] Nothing left to animate: stop being called. FctSpawnText re-arms.
    if #fctActive == 0 then self:SetScript("OnUpdate", nil) end
end

local fctPlayerGUID

local function FctMine(guid) return guid == fctPlayerGUID or guid == UnitGUID("pet") end

-- ===========================================================================
-- CORRECTED COMBAT TEXT
--
-- The problem, established by disassembling the client and not worth
-- re-deriving: the combat-text event marshaller does a SIGNED 32-bit load
-- (fild dword ptr [esi+4], 0x0081AD70) and only then widens to double for
-- lua_pushnumber, and every numeric combat-text slot goes through the %d
-- handler. Anything past 2^31 is destroyed BEFORE Lua is handed it. There is no
-- arrangement of addon code that gets a real number down that pipe.
--
-- So we let the client draw whatever it gets, and correct it before it renders.
-- The server sends the true 64-bit figure out of band on the UCT feed, keyed by
-- the exact pinned value the client will draw plus the source and target GUIDs;
-- we hold a short-lived table of those and substitute on the way to the screen.
--
-- WHAT WE DRAW INTO
--
-- Blizzard's scrolling combat text (the LoadOnDemand Blizzard_CombatText addon;
-- 3.3.5a has no FrameXML/CombatText.lua). It renders in a FIXED screen region,
-- which is the entire reason for moving: our own floaters anchor outgoing
-- numbers to the target's nameplate or unit frame, and a boss scaled to several
-- times its normal size puts that anchor somewhere the number should never be.
-- Incoming numbers never had that problem -- GetIncomingPos is already a fixed
-- point -- but they move too, because splitting one kind of combat text across
-- two renderers would look worse than either.
--
-- WHAT WE CANNOT DRAW
--
-- The numbers that fly off a unit's body are drawn by the game engine. They are
-- unreachable from Lua entirely -- no hook, no event, no frame -- so they can
-- only ever show the pinned value. CT_ApplyBlizzardSurfaces keeps them switched
-- off rather than leaving an uncorrectable 2.1B beside every corrected number.
--
-- FAILURE IS INVISIBLE, BY CONSTRUCTION
--
-- Everything below is all-or-nothing: the scrolling region is used only when the
-- renderer AND the event takeover are both in place (ctScrollReady). If either
-- fails -- the LoadOnDemand addon missing, a client that names things
-- differently, another addon holding the same seam -- we fall straight back to
-- the floaters this addon already had, with the corrections still applied. A
-- correction that never arrives leaves the ordinary pinned number on screen.
-- Nothing here can produce a blank, and nothing here runs outside a pcall that
-- could throw in combat.
-- ===========================================================================

-- The value the wire pins a saturated hit to: 2^31 - 128, matching
-- Damage64Log::SATURATION_FLOOR and UncappedCombatText::WIRE_CEILING server-side.
local CT_WIRE_CEILING = 2147483520

-- How far a drawn number may sit from the pinned value the server told us about
-- and still be considered the same hit.
--
-- Exact equality does NOT work, and this is the reason. Melee sub-damage rides
-- the wire as a float32 (`data << float(tmpDamage[i])` in
-- Unit::SendAttackStateUpdate), and float32 spacing at 2^31 is 2^31/2^23 = 256.
-- So the number Lua is handed can differ from the integer the server wrote by up
-- to half a step in either direction, and a saturated melee hit lands on a
-- coarse 256-wide grid rather than on one exact value.
--
-- There is a second, smaller source of drift in the same direction. The melee
-- packet carries the summed "Full damage" as an int32 (clamped at INT32_MAX,
-- 2147483647) and each sub-damage as a float32 (clamped at 2147483520). Which of
-- the two the client's combat log reports does not matter as long as the
-- tolerance spans the 127 between them, and it does.
--
-- 512 is two float steps: comfortably past any rounding the round-trip can
-- introduce, past that 127, and still 0.00002% of the magnitude being matched --
-- far too tight to bind two hits that are genuinely different. The one thing it can do
-- is pair a correction with an unsaturated hit that happens to land within 512
-- of the ceiling; that requires a real hit of ~2,147,483,100 from the same
-- source to the same target inside the TTL, and the result would be a number of
-- the right order of magnitude rather than a wrong one.
local CT_TOLERANCE = 512

-- Below this a drawn number is its own truth and is never looked up. This is
-- what stops the correction table being consulted for ordinary hits at all.
local CT_MATCH_FLOOR = CT_WIRE_CEILING - CT_TOLERANCE

-- How long a correction stays usable, and how many are kept.
--
-- A correction is sent in the same server tick as the hit it belongs to, so it
-- is normally consumed within a frame or two. The TTL exists for the case where
-- it is not: a correction that arrives too late must expire rather than attach
-- itself to some unrelated later hit. Three seconds is far longer than the feed
-- ever needs and far shorter than a fight.
--
-- The cap is the other half of the same rule -- a long fight cannot grow this
-- table, because the oldest entry is discarded to make room. Both bounds are
-- deliberately generous compared to what the feed actually produces (the server
-- refuses to send more than a dozen corrections per player per tick), so hitting
-- either one means something upstream is already wrong.
local CT_TTL = 3.0
local CT_MAX_PENDING = 64

local ctPending = {}   -- FIFO; oldest first
local ctSelfLow        -- low 32 bits of the player's own GUID

-- ★ [audit 2026-08-22 AN-16] Arms the combat-text driver's OnUpdate. Forward
-- declared because the ingest below runs long before the driver frame is
-- created, and the driver must only be running while there is something for it
-- to do -- a queued line to draw next frame, or a correction still inside its
-- TTL. It used to hold an OnUpdate for the whole session to service a purge that
-- fires once a second and, out of combat, has nothing to purge.
local CT_ArmDriver = function() end

-- A SECOND copy of every correction, consumed independently.
--
-- The combat-log chat tab and the floating number describe the same hit, so if
-- they drew from one list the first of them to run would take the entry and the
-- other would print the pinned value. Two lists, each seeing every correction
-- exactly once, is the whole fix -- and it costs one extra small table per hit.
local ctPendingChat = {}

-- The 32 bits both sides agree on.
--
-- Lua sees a GUID as "0x" plus 16 hex digits; the server computes
-- ObjectGuid::GetRawValue() & 0xFFFFFFFF. The last eight hex digits ARE that
-- value, so the two derive the same key from the same unit without either side
-- having to reproduce the other's GUID layout. Half the bytes of a full GUID,
-- which matters against the client's 255-byte addon-message ceiling.
local function CT_Low(guid)
    if type(guid) ~= "string" then return nil end
    return tonumber(guid:sub(-8), 16)
end

-- Parse a UCT line. Malformed entries are skipped rather than erroring: this
-- runs inside combat and a protocol hiccup must cost a number, never a frame.
CT_Ingest = function(body)
    local now = GetTime()
    for entry in body:gmatch("[^;]+") do
        local kind, src, dst, pin, real = entry:match("^(%a)(%x+),(%x+),(%d+),(%d+)$")
        if kind then
            local rec = {
                kind = kind,
                src  = tonumber(src, 16),
                dst  = tonumber(dst, 16),
                pin  = tonumber(pin),
                real = tonumber(real),
                t    = now,
            }

            if #ctPending >= CT_MAX_PENDING then table.remove(ctPending, 1) end
            ctPending[#ctPending + 1] = rec

            -- Shared by reference: nothing ever mutates a correction, only
            -- removes it from one list or the other.
            if #ctPendingChat >= CT_MAX_PENDING then table.remove(ctPendingChat, 1) end
            ctPendingChat[#ctPendingChat + 1] = rec

            CT_ArmDriver()   -- [AN-16] there is now something to purge
        end
    end
end

local function CT_PurgeList(list)
    local now = GetTime()
    for i = #list, 1, -1 do
        if now - list[i].t > CT_TTL then table.remove(list, i) end
    end
end

local function CT_Purge()
    CT_PurgeList(ctPending)
    CT_PurgeList(ctPendingChat)
end

-- Claim the correction for one drawn number, or nil.
--
-- `src` and `dst` may be nil for "don't care" -- the incoming path knows the
-- number landed on us but not who threw it, because the client's own combat-text
-- event carries no GUIDs at all.
--
-- Consuming is deliberate: each correction describes exactly one hit, and two
-- hits that saturate to the same value must take two different entries. Oldest
-- first, so a burst is matched in the order it was dealt.
--
-- Note what is NOT needed here. Corrections from other people's hits cannot
-- collide with ours, because they are never sent to us: the server addresses
-- each one to the two players party to the hit and stamps both GUIDs on it. The
-- keying below separates OUR simultaneous hits from each other; cross-player
-- leakage is prevented a step earlier, where it cannot be got wrong.
local function CT_Take(kind, src, dst, amount)
    -- The band decodes to its own truth, so it is answered before the correction
    -- table is consulted at all -- no GUID match, no TTL, no budget, and it works
    -- for a 250-target AoE tick where a message-based feed could not.
    --
    -- Checked BEFORE the CT_MATCH_FLOOR gate on purpose: that floor is 2147483008
    -- and BAND_BASE is 2145386496, so most encoded hits sit below it and the old
    -- ordering rejected them before anyone could look.
    local decoded = CT_DecodeBand(amount)
    if decoded then return decoded end

    if not amount or amount < CT_MATCH_FLOOR then return nil end
    local now = GetTime()
    for i = 1, #ctPending do
        local p = ctPending[i]
        if now - p.t <= CT_TTL
            and p.kind == kind
            and (src == nil or p.src == src)
            and (dst == nil or p.dst == dst)
            and math.abs(amount - p.pin) <= CT_TOLERANCE then
            table.remove(ctPending, i)
            return p.real
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Blizzard's scrolling region
-- ---------------------------------------------------------------------------
-- Two seams are taken, and neither is useful without the other:
--
--   * CombatText_AddMessage, kept as a direct reference so our own numbers go in
--     without passing back through anything we (or another addon) wrapped;
--   * the frame's OnEvent, so the message types WE draw are dropped before
--     Blizzard formats them. Precisely those types -- mana, honour, reputation,
--     combo points, aura gains and incoming avoidance stay Blizzard's, because
--     silencing the whole event to stop two damage numbers would take a dozen
--     unrelated ones with it.
--
-- ctScrollReady is set only when both are held. Half of this installed is worse
-- than none of it: the renderer without the takeover draws every number twice.
local ctOriginalAdd
local ctScrollReady = false

-- How many messages the event takeover has actually dropped.
--
-- This is a self-check on the one assumption in here that cannot be verified
-- from the code: that CT_WE_DRAW below lists the message-type names this client
-- really uses. If it does, this climbs the first time anything hits us and
-- Blizzard's own damage and heal lines never reach CombatText_AddMessage at all.
-- If a name is wrong it stays at zero, and the wrapper uses that to tell a
-- duplicate of a number we already drew from a message genuinely worth passing
-- through. See CT_InstallMessageWrapper.
local ctSuppressed = 0

local CT_WE_DRAW = {
    DAMAGE = true, DAMAGE_CRIT = true,
    SPELL_DAMAGE = true, SPELL_DAMAGE_CRIT = true,
    PERIODIC_DAMAGE = true, SPELL_PERIODIC_DAMAGE = true,
    HEAL = true, HEAL_CRIT = true,
    SPELL_HEAL = true, SPELL_HEAL_CRIT = true,
    PERIODIC_HEAL = true,
}

-- The animation Blizzard will run our line through.
--
-- Resolved per call, not once: COMBAT_TEXT_SCROLL_FUNCTION follows the player's
-- float-mode setting and is rewritten by CombatText_UpdateDisplayedMessages, so
-- a cached reference would pin them to whatever mode was live when we started.
-- Passing a nil here would not fail in our pcall -- Blizzard stores it on the
-- font string and calls it later, from its own OnUpdate -- so it is checked
-- before the region is claimed at all.
local function CT_ScrollFn()
    local named = type(COMBAT_TEXT_SCROLL_FUNCTION) == "string" and _G[COMBAT_TEXT_SCROLL_FUNCTION]
    if type(named) == "function" then return named end
    if type(CombatText_StandardScroll) == "function" then return CombatText_StandardScroll end
    if type(CombatText_FountainScroll) == "function" then return CombatText_FountainScroll end
    return nil
end

local function CT_ClaimScrollRegion()
    if ctScrollReady then return true end

    -- LoadOnDemand: nothing exists until something asks for it.
    if not CombatText_AddMessage and LoadAddOn then
        pcall(LoadAddOn, "Blizzard_CombatText")
    end
    if type(CombatText_AddMessage) ~= "function" or not CombatTextFrame then return false end
    if not CT_ScrollFn() then return false end

    local original = CombatText_AddMessage
    local origOnEvent = CombatTextFrame:GetScript("OnEvent") or CombatText_OnEvent
    if type(origOnEvent) ~= "function" then return false end

    local ok = pcall(function()
        CombatTextFrame:SetScript("OnEvent", function(self, event, ...)
            if event == "COMBAT_TEXT_UPDATE" then
                local messageType = ...
                if CT_WE_DRAW[messageType] then
                    ctSuppressed = ctSuppressed + 1
                    return
                end
            end
            return origOnEvent(self, event, ...)
        end)
    end)
    if not ok then return false end

    ctOriginalAdd = original
    ctScrollReady = true
    return true
end

-- Put one line into the scrolling region. Returns false when the region is not
-- ours, which is the caller's cue to fall back to our own floaters.
local function CT_Scroll(text, r, g, b, crit)
    if not ctScrollReady or not ctOriginalAdd then return false end
    local scrollFn = CT_ScrollFn()
    if not scrollFn then return false end
    -- displayType "crit" is what makes Blizzard use its larger crit font, which
    -- is the same distinction our own renderer draws with the size pop.
    return (pcall(ctOriginalAdd, text, scrollFn, r, g, b, crit and "crit" or nil, nil))
end

-- ---------------------------------------------------------------------------
-- The one-frame hold
-- ---------------------------------------------------------------------------
-- Every number worth correcting is held back for one full frame before it is
-- drawn, and this is the only reason the whole scheme lands on the right hit.
--
-- The server flushes corrections at the end of the same world tick that produced
-- the combat-log packets, so a correction is always one or two packets BEHIND
-- the hit it describes. The client fires COMBAT_LOG_EVENT_UNFILTERED while it is
-- still working through that burst -- drawing there would consult a table that
-- does not yet contain the answer. Waiting until the next OnUpdate guarantees
-- the whole burst has been processed first.
--
-- The cost is one frame, 16ms at 60fps. Nobody can see it, and the alternative
-- (reaching into Blizzard's live animation list to rewrite a string that is
-- already on screen) is both fragile and visibly wrong for a frame anyway.
local ctQueue, ctFrame, ctPurgeAccum = {}, 0, 0
local ctDriver = CreateFrame("Frame")

-- The queue drains every frame, so it should never hold more than one frame's
-- worth. The cap is there for the case where that assumption is wrong -- a UI
-- error that kills the driver, a stall -- so the failure is "some numbers are
-- missing" rather than a table that grows until the client runs out of memory.
local CT_MAX_QUEUE = 256

local function CT_Enqueue(rec)
    if #ctQueue >= CT_MAX_QUEUE then table.remove(ctQueue, 1) end
    rec.frame = ctFrame
    ctQueue[#ctQueue + 1] = rec
    CT_ArmDriver()   -- [AN-16] there is now something to draw next frame
end

-- Draw one of our own (combat-log driven) lines, correction applied.
local function CT_DrawOwn(rec)
    local amount = CT_Take(rec.kind, rec.src, rec.dst, rec.amount) or rec.amount

    -- The threshold is enforced server-side now (it never sends the packet), but
    -- it is still checked here: a realm running an older worldserver, and the
    -- legacy renderer, both need it, and a second check costs one comparison.
    if FctBelowThreshold(amount) then return end

    local text = (rec.kind == "h" and "+" or "") .. Abbrev(amount) .. (rec.crit and "!" or "")
    if not CT_Scroll(text, rec.r, rec.g, rec.b, rec.crit) then
        FctSpawnText(text, rec.crit, rec.r, rec.g, rec.b, not rec.incoming, rec.kind == "h")
    end
end

-- Re-issue a message Blizzard tried to send while a correction was still in
-- flight. Only reached when the event takeover is NOT in place for that type --
-- a safety net for anything Blizzard still emits with a pinned number in it.
local function CT_DrawBlizzard(rec)
    local real = CT_Take(rec.heal and "h" or "d", nil, ctSelfLow, rec.amount)
              or CT_Take(rec.heal and "d" or "h", nil, ctSelfLow, rec.amount)
    local message = rec.message
    if real then
        -- numStr is digits, so it is its own pattern, and Abbrev never produces
        -- a '%' -- neither side of the substitution can be reinterpreted.
        message = message:gsub(rec.numStr, Abbrev(real), 1)
    end
    if ctOriginalAdd then
        pcall(ctOriginalAdd, message, rec.scrollFunction, rec.r, rec.g, rec.b,
            rec.displayType, rec.isStaggered)
    end
end

local function CT_Drive(self, dt)
    ctPurgeAccum = ctPurgeAccum + dt
    if ctPurgeAccum >= 1.0 then
        ctPurgeAccum = 0
        if #ctPending > 0 or #ctPendingChat > 0 then CT_Purge() end
    end

    if #ctQueue > 0 then
        local i = 1
        while i <= #ctQueue do
            local rec = ctQueue[i]
            -- Strictly less-than: an entry stamped during THIS frame's event
            -- processing has rec.frame == ctFrame and waits for the next pass.
            if rec.frame < ctFrame then
                table.remove(ctQueue, i)
                if rec.blizzard then CT_DrawBlizzard(rec) else CT_DrawOwn(rec) end
            else
                i = i + 1
            end
        end
    end

    ctFrame = ctFrame + 1

    -- ★ [AN-16] Nothing queued and nothing to purge: stop being called. Both
    -- fill points (CT_Enqueue, CT_Ingest) re-arm. ctFrame stops advancing while
    -- idle, which is harmless -- the queue's one-frame delay is measured against
    -- the value stamped at enqueue time, and the first tick after re-arming
    -- still sees rec.frame == ctFrame and waits, exactly as before.
    if #ctQueue == 0 and #ctPending == 0 and #ctPendingChat == 0 then
        self:SetScript("OnUpdate", nil)
    end
end

CT_ArmDriver = function()
    if not ctDriver:GetScript("OnUpdate") then
        ctPurgeAccum = 0
        ctDriver:SetScript("OnUpdate", CT_Drive)
    end
end

-- Wrap CombatText_AddMessage so anything Blizzard (or another addon) pushes into
-- the scrolling region gets the same treatment. Installed separately from the
-- event takeover because it is useful on its own: even with the takeover in
-- place, a message type we did not list still arrives here and still gets its
-- number fixed rather than showing 2,147,483,520.
local ctWrapped = false
local function CT_InstallMessageWrapper()
    if ctWrapped or type(CombatText_AddMessage) ~= "function" then return end
    ctWrapped = true

    local passthrough = CombatText_AddMessage
    if not ctOriginalAdd then ctOriginalAdd = passthrough end

    CombatText_AddMessage = function(message, scrollFunction, r, g, b, displayType, isStaggered)
        if type(message) == "string" then
            -- Prefer the run behind a sign: Blizzard writes damage as "-N" and
            -- healing as "+N", sometimes after the healer's name. A bare "%d+"
            -- would find the "1" in "Player1" instead of the number.
            local numStr = message:match("[%+%-](%d+)") or message:match("%d+")
            local amount = numStr and tonumber(numStr)
            if amount and amount >= CT_MATCH_FLOOR then
                -- A pinned number that reached this wrapper while we are drawing
                -- everything ourselves AND the event takeover has never once
                -- fired means the takeover is not matching this client's type
                -- names -- so this is Blizzard's copy of a hit we have already
                -- queued. Drop it. Doubling every incoming number is a visible,
                -- permanent bug that would need a payload republish; the cost of
                -- being wrong the other way is one lost number, once, before the
                -- first genuine suppression.
                if ctScrollReady and ctSuppressed == 0 then return end

                -- Pinned, and the correction for it is very likely one packet
                -- behind. Swallow it and re-issue next frame rather than draw a
                -- number we already know to be wrong.
                CT_Enqueue({
                    blizzard = true,
                    message = message, numStr = numStr, amount = amount,
                    heal = message:find("%+") ~= nil,
                    scrollFunction = scrollFunction, r = r, g = g, b = b,
                    displayType = displayType, isStaggered = isStaggered,
                })
                return
            end
        end
        return passthrough(message, scrollFunction, r, g, b, displayType, isStaggered)
    end
end

-- ---------------------------------------------------------------------------
-- The combat log chat tab
-- ---------------------------------------------------------------------------
-- The third surface, and the one with the weakest keying, for a reason that
-- cannot be engineered around: a chat line is TEXT. It names units, it does not
-- carry their GUIDs, so a correction can only be matched to it by the number
-- itself. Both other surfaces are driven by events that hand us both GUIDs, and
-- both use them.
--
-- What that costs, stated plainly: in a group, a line describing somebody ELSE's
-- saturated hit can consume a correction that belonged to one of ours, so
-- attributions in the scrollback can drift during heavy raid combat. What it
-- cannot do is show another player's number -- their corrections are never sent
-- to this client at all -- so the failure is our own figure printed against the
-- wrong line, in a log, rather than a leak.
--
-- Weighed against the alternative, which is the tab showing 2147483520 for every
-- hit on the realm forever, that is worth taking. A line with no matching
-- correction is left exactly as Blizzard wrote it.
local function CT_TakeChat(amount)
    local now = GetTime()
    for i = 1, #ctPendingChat do
        local p = ctPendingChat[i]
        if now - p.t <= CT_TTL and math.abs(amount - p.pin) <= CT_TOLERANCE then
            table.remove(ctPendingChat, i)
            return p.real
        end
    end
    return nil
end

local function CT_RewriteChatLine(msg)
    if type(msg) ~= "string" then return msg end

    -- Cheapest gate first: a PLAIN find (no pattern engine) for the digits every
    -- encoded value must begin with. See CT_BAND_DIGIT_HINT above -- on this
    -- realm the saturated band is the common case in the combat-log tab, so the
    -- ten-digit pattern test below was being paid on every guild line, whisper
    -- and emote to catch it. This rejects all of those first.
    if CT_BAND_DIGIT_HINT and not msg:find(CT_BAND_DIGIT_HINT, 1, true) then return msg end

    -- Second gate. Only a ten-digit run can possibly be a pinned combat number,
    -- so a line that merely mentions "214" costs one failed pattern find.
    if not msg:find("%d%d%d%d%d%d%d%d%d%d") then return msg end

    -- ⚠ NO `#ctPendingChat == 0` EARLY-OUT ANY MORE.
    --   It used to bail here when the correction queue was empty, which since the
    --   feed went dead is ALWAYS -- so the combat log tab showed the raw pinned
    --   ~2.14B for every big hit on the realm and nothing could ever change it.
    --   Band decoding needs no queue, so the gate that used to be free is now the
    --   thing standing in the way.

    for numStr in msg:gmatch("%d+") do
        local n = tonumber(numStr)
        if n and n >= CT_BAND_BASE_MIN and n <= CT_BAND_BASE_MAX then
            -- Band first, correction table second -- same reasoning as CT_Take.
            local real = CT_DecodeBand(n) or (n >= CT_MATCH_FLOOR and CT_TakeChat(n) or nil)
            if real then
                -- Every occurrence of that digit run, not just the first: the
                -- same figure is repeated in the "(N overkill)" and "(N
                -- absorbed)" tails of the same line and they are the same hit.
                return (msg:gsub(numStr, Abbrev(real)))
            end
        end
    end

    return msg
end

-- Replace AddMessage on the frame rather than post-hooking it: hooksecurefunc
-- runs AFTER the call and cannot change what was printed, and there is nothing
-- secure about a chat frame to protect.
local function CT_HookChatFrame(frame)
    if type(frame) ~= "table" or frame.__uncappedCombatText then return end
    if type(frame.AddMessage) ~= "function" then return end
    frame.__uncappedCombatText = true

    local original = frame.AddMessage
    frame.AddMessage = function(self, message, ...)
        return original(self, CT_RewriteChatLine(message), ...)
    end
end

-- Every chat window, not just the combat-log tab. Players merge the combat log
-- into whichever window they like, and a hook that only covered ChatFrame2 would
-- quietly do nothing for most of them.
local function CT_InstallChatHooks()
    for i = 1, (NUM_CHAT_WINDOWS or 7) do
        CT_HookChatFrame(_G["ChatFrame" .. i])
    end
end

-- ---------------------------------------------------------------------------
-- Which of the client's combat-text surfaces are switched on
-- ---------------------------------------------------------------------------
CT_ApplyBlizzardSurfaces = function()
    -- The chat tab is still ours: it shows the same encoded number the floating
    -- text does, and nothing outside Lua rewrites chat.
    CT_InstallChatHooks()

    --[[ ★★ THIS ADDON NO LONGER DRAWS FLOATING COMBAT TEXT. Retired 2026-08-08.

         UncappedCT.dll draws the ENGINE body floaters and corrects them itself:
         it hooks the one function every floater passes through, decodes the wire
         band, and renders the real magnitude abbreviated as K / M / B / T. See
         NativeCT/src/UncappedCT.c and docs/design/NATIVE_COMBAT_TEXT.md.

         So the scrolling renderer below became a SECOND, worse copy of a solved
         problem -- numbers off to the side instead of over the body, and one more
         thing to keep in step with the wire format. Owner's call: prune it.

         ⚠ THE ENGINE FLOATERS MUST NOW BE LEFT ALONE.
           This function used to force floatingCombatTextCombatDamage/Healing/State
           to "0", on the reasoning that engine floaters "are not reachable from
           Lua, so they can only ever show the pinned value". That was true before
           the DLL shipped and is now exactly backwards -- switching them off here
           would turn OFF the only correct renderer and leave players with no
           floating numbers at all. The CVars are deliberately untouched.

         What this addon still owns, and why it is NOT being pruned wholesale:
           * the wire-band decode (CT_DecodeBand) -- shared with the chat rewrite
           * the combat-log chat tab rewriting
           * 64-bit health/number display and the paperdoll stat panel
           * the /hideunder threshold plumbing
    ]]

    -- Blizzard's own scrolling region stays OFF. The DLL draws over the body; a
    -- scroll on the side would be the same hit reported twice, in two places, in
    -- two formats.
    if COMBAT_TEXT_TYPE_INFO then
        SHOW_COMBAT_TEXT = "0"
        if CombatText_UpdateDisplayedMessages then pcall(CombatText_UpdateDisplayedMessages) end
    end
end

-- ---------------------------------------------------------------------------
-- Pushing the hide-under threshold to the server
-- ---------------------------------------------------------------------------
-- The filtering itself now happens server-side: a spell, periodic or heal packet
-- under the threshold is not sent to this player at all. That is cheaper than
-- sending it for the client to discard, and unlike the old client-side test it
-- also silences combat text we do not own. (Melee stays client-side -- see the
-- note on /hideunder for why its packet cannot be withheld.)
--
-- Formatted with %.0f rather than %d ON PURPOSE. The client's Lua is a 32-bit
-- build, so string.format("%d", 5e12) wraps -- and on this realm a threshold in
-- the trillions is the ordinary case, not an edge one.
CT_PushHideUnder = function()
    local n = Cfg.minFloat or 0

    if type(SendAddonMessage) == "function" then
        pcall(SendAddonMessage, "REAGENTBANK", string.format("UHIDE:%.0f", n),
            "WHISPER", UnitName("player"))
    end

    -- ★ [#558 / #447] The DLL needs it too, and this is the only half that can
    -- filter MELEE.
    --
    -- The server drops spell, periodic and heal packets under the threshold
    -- before they are sent, but melee is exempt on purpose: its packet also
    -- drives the weapon-swing animation, so withholding it would stop characters
    -- swinging. That exemption was covered by this addon filtering melee itself
    -- -- right up until it stopped drawing floating combat text (2026-08-08) and
    -- UncappedCT.dll took over the engine's body floaters. The filter went with
    -- the renderer, so melee and pet auto-attacks have had none since.
    --
    -- Passed as a STRING for the same reason the UHIDE line above is formatted
    -- with %.0f: this client's Lua is a 32-bit build, and a threshold in the
    -- trillions is the ordinary case here rather than an edge one.
    --
    -- pcall'd and existence-checked because the DLL is optional -- a player
    -- running the stock exe has no such global, and must lose nothing but this.
    if type(UncappedCT_SetHideUnder) == "function" then
        pcall(UncappedCT_SetHideUnder, string.format("%.0f", n))
    end
end

-- ---------------------------------------------------------------------------
-- Combat-log routing
-- ---------------------------------------------------------------------------
local function FctDamage(srcGUID, dstGUID, amount, crit, isSpell)
    -- ★ RETIRED 2026-08-08: this addon no longer draws floating combat text.
    --   UncappedCT.dll corrects the ENGINE body floaters (K/M/B/T) -- see
    --   CT_ApplyBlizzardSurfaces. Returning here rather than deleting the
    --   pipeline below keeps one honest off-switch instead of a half-removed
    --   renderer, and the enqueue/draw machinery is still referenced by the
    --   /dev64 preview.
    if not FCT_ADDON_DRAWS then return end

    if not amount or amount <= 0 then return end

    local outgoing = FctMine(srcGUID)
    if not outgoing and dstGUID ~= fctPlayerGUID then return end

    if Cfg.legacyFct then
        -- At/above the wall the client only ever sees the pinned value, and the
        -- merged UDMG feed draws the real one, so drop ours to avoid a double.
        -- The corrected path below needs no such rule: it fixes the number in
        -- place instead of letting a second feed draw a second number.
        if amount >= CT_MATCH_FLOOR then return end
        if FctBelowThreshold(amount) then return end
        local label = Abbrev(amount) .. (crit and "!" or "")
        if outgoing then
            -- melee auto-attacks white, spells/skills yellow; crit -> big=true,
            -- which drives the size pop in the animation loop.
            if isSpell then FctSpawnText(label, crit, 1.0, 0.82, 0.0, true)
            else FctSpawnText(label, crit, 1, 1, 1, true) end
        else
            FctSpawnText(label, crit, 1.0, 0.4, 0.4, false)
        end
        return
    end

    local r, g, b
    if not outgoing then      r, g, b = 1.0, 0.4, 0.4      -- damage you take
    elseif isSpell then       r, g, b = 1.0, 0.82, 0.0     -- your spells/skills
    else                      r, g, b = 1.0, 1.0, 1.0 end  -- your auto-attacks

    CT_Enqueue({
        kind = "d", crit = crit and true or false, incoming = not outgoing,
        src = CT_Low(srcGUID), dst = CT_Low(dstGUID), amount = amount,
        r = r, g = g, b = b,
    })
end

-- Miss/dodge/parry/block/absorb/immune/resist -- avoided attacks. No number, so
-- nothing to correct and nothing to hold a frame for.
local function FctMiss(srcGUID, dstGUID, missType)
    -- ★ RETIRED 2026-08-08: this addon no longer draws floating combat text.
    --   UncappedCT.dll corrects the ENGINE body floaters (K/M/B/T) -- see
    --   CT_ApplyBlizzardSurfaces. Returning here rather than deleting the
    --   pipeline below keeps one honest off-switch instead of a half-removed
    --   renderer, and the enqueue/draw machinery is still referenced by the
    --   /dev64 preview.
    if not FCT_ADDON_DRAWS then return end

    local label = MISS_TEXT[missType] or "Miss"
    if FctMine(srcGUID) then
        -- Your attack was avoided.
        if Cfg.legacyFct or not CT_Scroll(label, 0.85, 0.85, 0.85, false) then
            FctSpawnText(label, false, 0.85, 0.85, 0.85, true)
        end
    elseif dstGUID == fctPlayerGUID then
        -- You avoided one. Left to Blizzard when the scrolling region is ours --
        -- its own MISS/DODGE/PARRY messages are deliberately NOT in CT_WE_DRAW,
        -- so they still arrive, and drawing over them would double them. In
        -- either mode where that region is silent, we draw it or nobody does.
        if Cfg.legacyFct or not ctScrollReady then
            FctSpawnText(label, false, 0.85, 0.95, 1.0, false)
        end
    end
end

local function FctHeal(srcGUID, dstGUID, amount, crit)
    -- ★ RETIRED 2026-08-08: this addon no longer draws floating combat text.
    --   UncappedCT.dll corrects the ENGINE body floaters (K/M/B/T) -- see
    --   CT_ApplyBlizzardSurfaces. Returning here rather than deleting the
    --   pipeline below keeps one honest off-switch instead of a half-removed
    --   renderer, and the enqueue/draw machinery is still referenced by the
    --   /dev64 preview.
    if not FCT_ADDON_DRAWS then return end

    if not amount or amount <= 0 then return end

    local outgoing = FctMine(srcGUID)
    if not outgoing and dstGUID ~= fctPlayerGUID then return end

    if Cfg.legacyFct then
        if amount >= CT_MATCH_FLOOR then return end   -- UHEAL feed covers these
        if FctBelowThreshold(amount) then return end
        local label = "+" .. Abbrev(amount)
        if dstGUID == fctPlayerGUID then
            FctSpawnText(label, crit, 0.4, 1.0, 0.4, false, true)
        else
            FctSpawnText(label, crit, 0.4, 1.0, 0.4, true, true)
        end
        return
    end

    -- `incoming` only decides where the FALLBACK floater starts, so it reads the
    -- destination rather than the source: a heal you cast on yourself belongs
    -- over you, not over your target.
    CT_Enqueue({
        kind = "h", crit = crit and true or false, incoming = (dstGUID == fctPlayerGUID),
        src = CT_Low(srcGUID), dst = CT_Low(dstGUID), amount = amount,
        r = 0.4, g = 1.0, b = 0.4,
    })
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
    ctSelfLow = CT_Low(fctPlayerGUID)

    -- Re-assert which combat-text surfaces are ours on every world-enter: the
    -- client reloads its own CVars behind us, and the scrolling region has to be
    -- re-claimed after a UI reload. (Nameplates are no longer force-held on here
    -- -- see the one-time warning below.)
    CT_ApplyBlizzardSurfaces()

    -- The hide-under threshold lives client-side but is ENFORCED server-side, so
    -- it has to be re-sent whenever the session might be new to it: a fresh
    -- login, a zone change, a worldserver restart the client did not notice.
    -- Idempotent, and one message.
    CT_PushHideUnder()

    --[[ ★ ONE-TIME NOTICE, and it is not optional politeness.
         [audit 2026-08-22 NC-02, client half]

         The DLL-side filter compared the threshold against the ABBREVIATED label
         ("3.20B"), so it could not judge anything at or above a million -- which
         on this realm is every hit. Anyone who set a threshold weeks ago has been
         carrying a live setting that did nothing, and the build that fixes NC-02
         makes it bite for the first time. Being told beats rediscovering it as
         "my auto-attacks vanished and I don't know why".

         ⚠ SHIP THIS WITH THE DLL, NOT AFTER IT. Without the notice the fix takes
           numbers away from people who never asked again.

         Versioned flag, like statusTextMigrated3 above: reusing a name would
         permanently skip exactly the people who need to be told. Top-level on
         `db`, not under `db.fct`, so InitSavedVars' `for k in pairs(Cfg)` loop
         never touches it. ]]
    local db = Uncapped64bitUIDB
    if db and not db.hideUnderFixNotice1 then
        db.hideUnderFixNotice1 = true
        local m = Cfg.minFloat or 0
        if m > 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cff40ff40[Uncapped]|r your |cffffff00/hideunder|r "
                .. "threshold is " .. Abbrev(m) .. ", and it now hides auto-attacks too -- "
                .. "it had been failing on anything over a million. "
                .. "|cffffff00/hideunder 0|r shows everything again.")
        end
    end
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
    -- Preview whatever the player will actually see. In the corrected mode the
    -- sliders above are not driving anything, so previewing the floaters would
    -- demonstrate a renderer that is switched off.
    if not Cfg.legacyFct and ctScrollReady then
        -- Trillion-scale figures built by scaling a SMALL random. math.random
        -- takes C ints in Lua 5.1, and the client's Lua is a 32-bit build, so
        -- handing it 9e11 directly is undefined rather than merely large.
        local function big(lo, hi) return math.random(lo, hi) * 1e9 end
        CT_Scroll(Abbrev(big(100, 900)) .. "!", 1, 1, 1, true)          -- melee crit
        CT_Scroll(Abbrev(big(10, 80)), 1, 1, 1, false)                  -- melee hit
        CT_Scroll(Abbrev(big(100, 900)) .. "!", 1.0, 0.82, 0.0, true)   -- spell crit
        CT_Scroll(Abbrev(big(10, 80)), 1.0, 0.82, 0.0, false)           -- spell hit
        CT_Scroll(Abbrev(big(10, 500)), 1.0, 0.4, 0.4, false)           -- taken
        CT_Scroll("Dodge", 0.85, 0.85, 0.85, false)
        CT_Scroll("+" .. Abbrev(big(1, 40)), 0.4, 1.0, 0.4, false)      -- heal
        return
    end

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
-- UALL feed), so there is nothing worth salvaging in the tooltip. Remove it
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

-- Rows whose true value the server already sends in the UALL feed, with the
-- label to head the tooltip with. Only these can be stated truthfully; anything
-- not listed keeps whatever AllStats built.
local STAT_TOOLTIP_SOURCE = {
    ["1"]           = { key = "str",   label = STAT_STRENGTH  or "Strength"      },
    ["2"]           = { key = "agi",   label = STAT_AGILITY   or "Agility"       },
    ["3"]           = { key = "sta",   label = STAT_STAMINA   or "Stamina"       },
    ["4"]           = { key = "int",   label = STAT_INTELLECT or "Intellect"     },
    ["5"]           = { key = "spi",   label = STAT_SPIRIT    or "Spirit"        },
    ["MeleePower"]  = { key = "map",   label = MELEE_ATTACK_POWER  or "Attack Power" },
    ["RangePower"]  = { key = "rap",   label = RANGED_ATTACK_POWER or "Ranged Attack Power" },
    ["SpellDamage"] = { key = "sp",    label = "Spell Power"    },
    ["SpellHeal"]   = { key = "heal",  label = "Healing Power"  },
    ["Armor"]       = { key = "armor", label = ARMOR or "Armor" },
    ["Defense"]     = { key = "def",   label = DEFENSE or "Defense" },
    ["MeleeExpert"] = { key = "exp",   label = "Expertise"      },
}

-- Repair the stat-panel hover instead of deleting it.
--
-- This used to strip the tooltips outright: AllStats paints its rows with the
-- stock PaperDollFrame_Set* helpers, which also install Blizzard's tooltip
-- handlers, and those recompute from the 32-bit client fields. On a scaled
-- character the hover then flatly contradicted the row it was attached to --
-- Strength reading 3.45B in the panel while its tooltip claimed "Increases
-- Attack Power by -294967316", a plain int32 wrap.
--
-- Deleting them did stop the contradiction, but it also took away every stat
-- tooltip on the character sheet, permanently, for everyone. The panel itself is
-- repainted from the UALL feed and is correct -- so the same feed can supply the
-- hover, and the information comes back instead of going away.
--
-- Only rows the feed actually carries are rewritten. Blizzard's SECOND line
-- (tooltip2) is dropped for those rows rather than recomputed, because it states
-- a DERIVED effect ("increases attack power by N") whose formula is class- and
-- talent-specific. Replicating that here would create a second source of truth
-- that silently drifts from the server's. A true headline beats a plausible
-- guess, so the row states what the stat IS and stops there.
local function FixStatTooltips()
    local r = realStats
    for _, suffix in ipairs(STAT_ROWS) do
        local f = _G["AllStatsFrameStat" .. suffix]
        if f then
            local src = STAT_TOOLTIP_SOURCE[suffix]
            local v = src and r and r[src.key]
            if v then
                f.tooltip  = HIGHLIGHT_FONT_COLOR_CODE .. src.label .. " " .. Abbrev(v) .. FONT_COLOR_CODE_CLOSE
                f.tooltip2 = nil
            end
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
local function InstallStatTooltipFixer()
    if type(PrintStats) ~= "function" then return false end
    hooksecurefunc("PrintStats", FixStatTooltips)
    return true
end

if not InstallStatTooltipFixer() then
    -- Load-order fallback: wait until AllStats is in, then hook.
    local waiter = CreateFrame("Frame")
    waiter:RegisterEvent("ADDON_LOADED")
    waiter:RegisterEvent("PLAYER_LOGIN")
    waiter:SetScript("OnEvent", function(self)
        if InstallStatTooltipFixer() then
            self:UnregisterAllEvents()
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Item tooltips (haste stat lines AND proc / equip-effect lines like Tempest
-- Keep's "chance to increase attack speed by N%") are handled by the unified
-- RewriteTooltipLines below, which also hooks OnTooltipSetItem. It substitutes
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
-- ★ [audit 2026-08-22 AN-15] The guard finds are PLAIN finds (`, 1, true`) and
-- the substitution chain is split into a haste half and a speed half, each run
-- only when the line actually contains that word.
--
-- Every pattern below contains the literal "haste" or the literal "speed", so a
-- line with neither could not have matched any of them -- skipping them is a
-- cost saving with no behaviour change. The relative ORDER of the surviving
-- gsubs is unchanged, which is what matters: the chain runs most-specific first
-- ("20% melee haste" must become "20% critical strike damage", not "20% melee
-- critical strike damage"), so it must not be reordered or collapsed.
--
-- ⚠ Deliberately NOT "bail after the first substitution", which is what the
-- audit line suggested. One line can legitimately need two of these -- "increases
-- haste rating by 300 and attack speed by 5%" needs the first gsub AND one from
-- the speed half -- so an early bail would silently leave half of it relabelled.
-- The substituted text ("critical strike damage") contains neither guard word,
-- so the two flags stay valid for the whole chain.
local function rewriteHasteLine(t)
    local low = t:lower()
    if low:find("movement speed", 1, true) or low:find("run speed", 1, true) then return t end
    if low:find("reduc", 1, true) or low:find("slow", 1, true) or low:find("decreas", 1, true)
       or low:find("lower", 1, true) or low:find("cast time", 1, true)
       or low:find("casting time", 1, true) then return t end   -- slow -> leave
    if not (low:find("increas", 1, true) or low:find("improv", 1, true) or low:find("grant", 1, true)
            or low:find("gain", 1, true) or low:find("provid", 1, true) or low:find("boost", 1, true)
            or low:find("haste rating", 1, true)) then return t end

    local hasHaste = low:find("haste", 1, true) ~= nil
    local hasSpeed = low:find("speed", 1, true) ~= nil

    local s = t
    if hasHaste then
        s = s:gsub("[Hh]aste [Rr]ating by (%d+)", function(n) return CDMG .. " by " .. fmtCd(tonumber(n)/1000) .. "%" end)
        s = s:gsub("(%d+)%s+[Hh]aste [Rr]ating", function(n) return fmtCd(tonumber(n)/1000) .. "% " .. CDMG end)
        s = s:gsub("(%d+%%)%s*[Mm]elee [Hh]aste", "%1 " .. CDMG)
        s = s:gsub("(%d+%%)%s*[Ss]pell [Hh]aste",  "%1 " .. CDMG)
        s = s:gsub("(%d+%%)%s*[Rr]anged [Hh]aste", "%1 " .. CDMG)
        s = s:gsub("(%d+%%)%s*[Hh]aste",           "%1 " .. CDMG)
    end
    if hasSpeed then
        s = s:gsub("[Mm]elee, ranged, and spell casting speed", CDMG)
        s = s:gsub("[Mm]elee and ranged attack speed", CDMG)
        s = s:gsub("[Aa]ttack and casting speed", CDMG)
        s = s:gsub("[Mm]elee attack speed", CDMG)
        s = s:gsub("[Rr]anged attack speed", CDMG)
        s = s:gsub("[Aa]ttack speed", CDMG)
        s = s:gsub("[Cc]asting speed", CDMG)
    end
    if hasHaste then
        s = s:gsub("[Ss]pell [Hh]aste", CDMG)
        s = s:gsub("[Mm]elee [Hh]aste", CDMG)
        s = s:gsub("[Rr]anged [Hh]aste", CDMG)
        s = s:gsub("[Hh]aste [Rr]ating", CDMG)
        s = s:gsub("[Hh]aste", CDMG)
    end
    return s
end
-- Abbreviate any large number embedded in a line of tooltip text.
--
-- Threshold matches AbbrevRow's, and for the same reason: below 100k the raw
-- figure reads better than an abbreviation -- "45231" is perfectly legible and
-- "45.2K" throws away precision for nothing. Above it, an unabbreviated number on
-- a scaled realm is a wall of digits nobody parses at a glance.
--
-- Deliberately conservative about what it matches. Item level, required level,
-- durability, stack sizes and every other small integer fall under the threshold
-- and are left exactly alone, so this cannot quietly rewrite "Requires Level 80".
--
-- ★ [audit 2026-08-22 AN-15] The gsub callback is a FILE-LOCAL, not a closure
-- built on every call. This runs per line per column of every tooltip -- an
-- auction list or a full bag re-runs it for each item hovered -- and the old
-- shape allocated a fresh function object each time, straight into the string
-- and garbage churn the realm's FPS profile is dominated by.
local function AbbrevBigNumber(n)
    local v = tonumber(n)
    if v and v >= 100000 then return Abbrev(v) end
    return n
end

local function AbbrevNumbersIn(s)
    -- ★ Reject first, with one pattern find, before running a gsub with a
    -- callback over the whole string. The threshold is 100000, so nothing
    -- without six consecutive digits can ever be substituted -- and the vast
    -- majority of tooltip lines ("Binds when picked up", "Requires Level 80")
    -- have none. The test can only ever be a FALSE POSITIVE (leading zeros), so
    -- it cannot skip a line the gsub would have changed.
    if not s:find("%d%d%d%d%d%d") then return s end
    return (s:gsub("%d+%.?%d*", AbbrevBigNumber))
end

-- One pass over a tooltip's lines doing both jobs: the haste -> crit-damage
-- relabel (only on lines that mention it) and large-number abbreviation (on every
-- line, including the right-hand column, where item tooltips put armour values,
-- damage ranges and stat totals).
--
-- ★ [audit 2026-08-22 AN-15] Two allocations per line were removed here: the
-- `{ "TextLeft", "TextRight" }` table, which was built fresh for EVERY line of
-- EVERY tooltip and handed to ipairs, and one of the two name concatenations,
-- now hoisted so the frame-name prefix is built once per tooltip instead of
-- twice per line. The two columns are unrolled because they do different work
-- anyway -- only the left one carries prose the haste relabel can apply to.
local function RewriteTooltipLines(tt)
    if not tt or not tt.GetName then return end
    local name = tt:GetName()
    if not name then return end

    local leftPrefix  = name .. "TextLeft"
    local rightPrefix = name .. "TextRight"

    for i = 1, tt:NumLines() do
        -- Left column: prose. Haste relabel then abbreviation.
        local fs = _G[leftPrefix .. i]
        local t = fs and fs:GetText()
        if t and t ~= "" then
            local nt = t
            -- ★ Two PLAIN finds on the raw text before paying for :lower().
            -- "aste"/"peed" are the case-insensitive tails of Haste/Speed, so
            -- anything the guard below could match contains one of them; almost
            -- no tooltip line does, and those lines now allocate no lowercase
            -- copy at all.
            if t:find("aste", 1, true) or t:find("peed", 1, true) then
                local low = t:lower()
                if low:find("haste", 1, true) or low:find("attack speed", 1, true)
                   or low:find("casting speed", 1, true) then
                    nt = rewriteHasteLine(nt)
                end
            end
            nt = AbbrevNumbersIn(nt)
            if nt ~= t then fs:SetText(nt) end
        end

        -- Right column: bare values (armour, damage ranges, stat totals). Never
        -- a sentence, so no haste relabel -- abbreviation only.
        fs = _G[rightPrefix .. i]
        t = fs and fs:GetText()
        if t and t ~= "" then
            local nt = AbbrevNumbersIn(t)
            if nt ~= t then fs:SetText(nt) end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Spell tooltip damage.
-- ---------------------------------------------------------------------------
-- The $s placeholders were stripped from the spell descriptions in the MPQ, so
-- tooltips read "dealing Holy damage" with no figure. They had to go: the client
-- fills them from int32 spell data, which at this realm's scaling rendered as a
-- wrapped negative. The number is therefore injected here instead.
--
-- Request/reply rather than a push. Pushing a value for every spell in the book,
-- kept current as gear changes, is exactly the standing traffic just removed from
-- the HP feed; a tooltip is opened rarely and deliberately, so we ask only when
-- one is opened. The answer is cached and the cache is dropped when gear changes,
-- since that is what moves the number.
--
-- Fail-silent by design: no reply means the tooltip is left exactly as it is
-- today. A missing number is a non-improvement; a confidently wrong one is worse
-- than what we started with, on a realm where nobody can eyeball the magnitude.
local function RequestSpellDamage(spellId)
    if not spellId or spellDmgCache[spellId] or spellDmgAsked[spellId] then return end
    spellDmgAsked[spellId] = true
    SendAddonMessage("REAGENTBANK", "USPELLDMG:" .. spellId, "WHISPER", UnitName("player"))
end

-- Gear (or anything else that moves spell power) invalidates every cached
-- figure. Cheaper and far more reliable than trying to work out which spells a
-- given item affects.
local spellDmgWatcher = CreateFrame("Frame")
spellDmgWatcher:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
spellDmgWatcher:RegisterEvent("UNIT_INVENTORY_CHANGED")
spellDmgWatcher:SetScript("OnEvent", function()
    spellDmgCache = {}
    spellDmgAsked = {}
end)

local function AppendSpellDamage(tt)
    if not tt or not tt.GetSpell then return end

    local _, _, spellId = tt:GetSpell()
    if not spellId then return end

    local dmg = spellDmgCache[spellId]
    if not dmg then
        RequestSpellDamage(spellId)
        return          -- answer arrives asynchronously; next hover shows it
    end

    -- Guard against stacking the line if the tooltip is re-rendered without
    -- being cleared.
    local name = tt:GetName()
    if name then
        for i = 1, tt:NumLines() do
            local fs = _G[name .. "TextLeft" .. i]
            local t  = fs and fs:GetText()
            if t and t:find("Approx.", 1, true) then return end
        end
    end

    -- One figure when the server sent one, a range when it sent two. [NC-14]
    if dmg[2] and dmg[2] > dmg[1] then
        tt:AddLine("Approx. " .. Abbrev(dmg[1]) .. " - " .. Abbrev(dmg[2])
                   .. " with your stats", 1, 0.82, 0)
    else
        tt:AddLine("Approx. " .. Abbrev(dmg[1]) .. " with your stats", 1, 0.82, 0)
    end
    tt:Show()   -- re-fit; the tooltip has grown by a line
end

-- ---------------------------------------------------------------------------
-- The banned / map-restricted effect line (report #456; sets fed above).
-- ---------------------------------------------------------------------------
--
-- Says what is actually TRUE of the item, which is narrower than "disabled":
-- the blacklist stops an effect being MOVED (extraction, soulbind, the addable
-- catalogue), and the map restriction stops it FUNCTIONING off one map. A single
-- "disabled on this realm" line would be a lie about an effect the player can
-- watch working, and a tooltip that lies is worse than the silence #456 was
-- opened about.
--
-- Fail-silent by design: no feed, no line. An unmarked tooltip is exactly what
-- players have today, so a realm that never answers loses nothing.
local BAN_MARKER = "Uncapped:"   -- how the re-render guard recognises our own lines

local function AppendBanNote(tt)
    if not tt or not tt.GetItem then return end
    if not banFeedLoaded then RequestBanFeed() end

    local ok, _, link = pcall(tt.GetItem, tt)
    if not ok or not link then return end

    local id = tonumber(link:match("item:(%d+)"))
    if not id then return end

    local banned  = banItems[id]
    local mapId   = restrictItems[id]
    if not banned and not mapId then return end

    -- A tooltip that is re-rendered without being cleared would otherwise stack
    -- the line every pass (same guard AppendSpellDamage uses).
    local name = tt:GetName()
    if name then
        for i = 1, tt:NumLines() do
            local fs = _G[name .. "TextLeft" .. i]
            local t  = fs and fs:GetText()
            if t and t:find(BAN_MARKER, 1, true) then return end
        end
    end

    if mapId then
        local where = restrictMaps[mapId] or "one raid"
        tt:AddLine(BAN_MARKER .. " this effect only works in " .. where .. ".", 1, 0.5, 0.2, true)
    end
    if banned then
        -- [#788] Say WHICH is true. Val'anyr's cosmetic glow is banned and its real proc
        -- extracts fine, so the flat line was a lie about the effect the player actually
        -- wanted -- and a tooltip that lies is worse than one that says nothing. Amber
        -- rather than red: this is a caveat, not a refusal.
        if partialItems[id] then
            tt:AddLine(BAN_MARKER .. " one of this item's effects cannot be extracted or soulbound. The rest can.",
                1, 0.6, 0.3, true)
        else
            tt:AddLine(BAN_MARKER .. " this effect cannot be extracted or soulbound.", 1, 0.3, 0.3, true)
        end
    end
    tt:Show()   -- re-fit; the tooltip has grown
end

for _, tname in ipairs({ "GameTooltip", "ItemRefTooltip", "ShoppingTooltip1", "ShoppingTooltip2" }) do
    local tt = _G[tname]
    if tt and tt.HookScript then
        tt:HookScript("OnTooltipSetSpell", RewriteTooltipLines)
        tt:HookScript("OnTooltipSetSpell", AppendSpellDamage)
        tt:HookScript("OnTooltipSetItem",  RewriteTooltipLines)   -- item stat + proc-effect lines
        tt:HookScript("OnTooltipSetItem",  AppendBanNote)         -- banned / map-restricted effects
        tt:HookScript("OnTooltipSetUnit",  RewriteTooltipLines)   -- creature hover: level, health
    end
end

-- ---------------------------------------------------------------------------
-- Pet stat panel.
-- ---------------------------------------------------------------------------
-- The pet sheet is computed entirely client-side from the pet's own fields, so
-- unlike the character sheet there is no feed to substitute from. The numbers it
-- shows are still true up to the cap -- they are simply long enough at this
-- realm's scale to run past the edge of their frames and become unreadable.
--
-- So this abbreviates in place and does not invent anything: purely a legibility
-- fix, which is exactly why it is safe to apply blind where the character sheet
-- needed the server to answer first. If pet stats ever saturate, that wants the
-- feed treatment instead, and this will not paper over it -- a capped number
-- abbreviates to a capped number.
--
-- Placed after AbbrevNumbersIn deliberately: it is a local, so anything above its
-- definition would capture nil.
local PET_STAT_FRAMES = {
    "PetStatFrame1", "PetStatFrame2", "PetStatFrame3", "PetStatFrame4", "PetStatFrame5",
    "PetArmorFrame", "PetAttackPowerFrame", "PetDamageFrame", "PetSpellDamageFrame",
    "PetMagicResFrame1", "PetMagicResFrame2", "PetMagicResFrame3",
    "PetMagicResFrame4", "PetMagicResFrame5", "PetMagicResFrame6",
}

local function AbbrevPetFrame(name)
    local f = _G[name]
    if not f then return end

    local fs = _G[name .. "StatText"]
    if fs then
        local t = fs:GetText()
        if t and t ~= "" then
            local nt = AbbrevNumbersIn(t)
            if nt ~= t then fs:SetText(nt) end
        end
    end

    -- The hover strings are rebuilt by PetPaperDollFrame_UpdateStats on every
    -- refresh, so rewriting them from a post-hook is safe: ours is always the
    -- last word, and never compounds on an already-abbreviated string.
    if f.tooltip  then f.tooltip  = AbbrevNumbersIn(f.tooltip)  end
    if f.tooltip2 then f.tooltip2 = AbbrevNumbersIn(f.tooltip2) end
end

local function FixPetStats()
    for _, n in ipairs(PET_STAT_FRAMES) do AbbrevPetFrame(n) end
end

if type(PetPaperDollFrame_UpdateStats) == "function" then
    hooksecurefunc("PetPaperDollFrame_UpdateStats", FixPetStats)
end

-- ---------------------------------------------------------------------------
-- Pet tab self-heal (report #151: "no pet tab, and no level 1 mount").
--
-- The Pet tab of the character sheet is CharacterFrameTab2. Blizzard's
-- PetPaperDollFrame_UpdateIsAvailable() hides it whenever, at the instant it
-- runs, the player has no pet UI and GetNumCompanions("CRITTER") and
-- GetNumCompanions("MOUNT") are both zero -- and the only things that ever call
-- it are the pet events and COMPANION_LEARNED / COMPANION_UNLEARNED.
--
-- That makes the hidden state LATCH. PLAYER_ENTERING_WORLD does not re-evaluate
-- it, a class with no combat pet gets no pet events to re-evaluate it either,
-- and once the tab is hidden ToggleCharacter() refuses to open the frame
-- (PetPaperDollFrame.hidden is set), so the one remaining path that would have
-- re-run the check -- showing the frame -- is closed off too. A player who is
-- unlucky about WHEN the client recounted its companions loses the tab for the
-- rest of the session, and with it the only place mounts are listed. Which
-- reads exactly like "I don't have a mount".
--
-- Re-running the check on login and whenever the spellbook changes costs
-- nothing and turns a stuck session into a self-correcting one.
-- Deliberately one-way: this only ever RESTORES the tab, it never hides one.
-- Calling UpdateIsAvailable() outright would also take the tab away on a
-- transient zero -- and its "nothing to show" branch would eject the player
-- from the frame they were reading. Hiding is still Blizzard's job, on its own
-- events; all we do is undo a latch that should not have happened.
local petTabWatcher = CreateFrame("Frame")
petTabWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
petTabWatcher:RegisterEvent("SPELLS_CHANGED")
petTabWatcher:SetScript("OnEvent", function()
    if not CharacterFrameTab2 or CharacterFrameTab2:IsShown() then return end
    if not (HasPetUI() or GetNumCompanions("CRITTER") > 0 or GetNumCompanions("MOUNT") > 0) then return end

    if type(PetPaperDollFrame_UpdateIsAvailable) == "function" then
        PetPaperDollFrame_UpdateIsAvailable()
    end
end)

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

-- (The stat-guessing tables that used to live here were removed 2026-08-12 along
--  with the annotation they fed -- see RewriteSpellTooltip. We show the real
--  computed damage now, so guessing which stat produced it is both unnecessary
--  and, as reported for Ferocious Bite, wrong.)
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
    --[[
        ⚠⚠ THE ", based on your <stat>." ANNOTATION WAS REMOVED 2026-08-12.

        It existed for a world that no longer exists. When the $s placeholders were
        stripped from the descriptions, a tooltip read "dealing Holy damage" with no
        number at all, so the line was annotated with whichever stat the ability
        scaled from -- better than nothing when nothing was the alternative.

        We now send the REAL computed damage (USPELLDMG / USPELLDMGR), so the number
        is on the tooltip and the annotation is pure downside: it was a GUESS, and it
        guessed from the player's CLASS and the damage SCHOOL named in the text. That
        is wrong for any ability whose scaling disagrees with its class default --
        reported for a druid's Ferocious Bite, an energy finisher scaling off attack
        power, which the class default confidently labelled "based on your spell
        power". A player reading that builds the wrong character.

        ★ Do not reintroduce a stat label unless the SERVER supplies which stat it
          actually used. Inferring it client-side cannot be made correct: the same
          school, the same class and the same wording legitimately scale from
          different stats, which is exactly why this was wrong. The number is the
          honest thing to show, and we already show it.
    ]]
    for i = 2, tooltip:NumLines() do
        local fs = _G[tooltip:GetName() .. "TextLeft" .. i]
        if fs then
            local text = fs:GetText()
            if text then
                local stripped = StripComputedFigures(text)

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
--
-- ⚠ NOT WIRED TO THE UNCAPPED WINDOW ZOOM, and there is nothing here to wire.
-- This addon owns exactly two UIParent frames and neither is a window:
--
--   * this one, which is an ESC > Interface > AddOns PAGE. Blizzard reparents
--     it into InterfaceOptionsFramePanelContainer and sizes it to that
--     container, so scaling it would leave a mis-sized page inside a
--     stock-sized frame -- Blizzard's own UI Scale slider is what moves it.
--   * fctHost, the floating-combat-text layer, which is not a frame the player
--     places or reads at leisure but a screen-space layer whose numbers are
--     positioned from nameplate/target centres in UIParent units. Its size is
--     already player-controlled by the font-size sliders on this very page.
--
-- The CenterInUIParent helper up by fctHost is the reason that stays true: it
-- normalises through GetEffectiveScale, so it keeps working over any scaled
-- frame it is asked about.
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
-- [#766] This page was still selling a feature that was retired on 2026-08-08. The addon
-- stopped drawing its own floating text when the DLL took over the engine's body floaters
-- and corrected them to real 64-bit values, but the copy here still said "switch them on
-- at the bottom" -- so a player with no numbers ticked a box that nothing reads any more
-- and concluded the combat text was broken. Say what is actually true.
optSub:SetText("|cffff8040Your damage numbers are now drawn by the game engine, over the "
    .. "enemy's body, and corrected to real 64-bit values -- this addon no longer draws "
    .. "its own.|r  Turn them on or off under |cffffd100Uncapped > Performance|r, and hide "
    .. "small hits with |cffffff00/hideunder 500m|r.  The sliders below only affect the "
    .. "classic floating numbers, which are not currently drawn.")

-- ★ EVERYTHING BELOW BUILDS INTO A SCROLLING BODY, NOT INTO THE PANEL.
--
-- This page is two columns of sliders plus a font picker, two buttons and a
-- checkbox. On a 768-tall client that last checkbox sits underneath the Interface
-- frame's own Okay/Cancel row and cannot be clicked -- reported with a screenshot,
-- arrow pointing straight at it.
--
-- Rather than shrink the page, the body scrolls. UncappedUI.MakeScrollable is the
-- same helper the fourteen shared settings pages use, so they all behave alike.
--
-- ⚠ `or optPanel` IS LOAD-ORDER INSURANCE, NOT DECORATION. UncappedOptions is an
--   OptionalDep, so it is normally loaded first and the helper exists -- but a
--   player who disables it must still get a working page, just an unscrolled one.
--   Every widget below anchors to optBody, which is either the scroll child or the
--   panel itself, and the offsets work in both.
local optBody = (UncappedUI and UncappedUI.MakeScrollable
    and UncappedUI.MakeScrollable(optPanel, -72)) or optPanel

-- Absolute-positioned page, so the scroll child cannot learn its own height from
-- a layout cursor the way the shared pages do. Lowest widget is the legacy
-- checkbox at -352 plus its own height; 400 clears it with a little air.
if optBody ~= optPanel then optBody:SetHeight(400) end

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
    local s = CreateFrame("Slider", name, optBody, "OptionsSliderTemplate")
    -- Anchor to the panel EDGE (not a hardcoded x) so the layout fits whatever
    -- width the Interface options panel actually gives us on this client.
    s:SetPoint(point, optBody, point, xOff, yOff)
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
        MakeSlider(meta, "TOPLEFT",  16,  -8 - (i - 1) * 50)
    else
        MakeSlider(meta, "TOPRIGHT", -16, -8 - (i - 1 - SLIDER_HALF) * 50)
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

local fontHeader = optBody:CreateFontString(nil, "ARTWORK", "GameFontNormal")
fontHeader:SetPoint("TOPLEFT", optBody, "TOPLEFT", 20, -256)
fontHeader:SetText("Combat font")

local fontDrop = CreateFrame("Frame", "Uncapped64FontDropdown", optBody, "UIDropDownMenuTemplate")
fontDrop:SetPoint("TOPLEFT", optBody, "TOPLEFT", 4, -276)
local fontProbe = optBody:CreateFontString(nil, "OVERLAY")   -- offscreen; tests loadability
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
local previewBtn = CreateFrame("Button", nil, optBody, "UIPanelButtonTemplate")
previewBtn:SetWidth(110)
previewBtn:SetHeight(24)
previewBtn:SetPoint("TOPLEFT", optBody, "TOPLEFT", 20, -318)
previewBtn:SetText("Preview")
previewBtn:SetScript("OnClick", function() FctPreview() end)

local resetBtn = CreateFrame("Button", nil, optBody, "UIPanelButtonTemplate")
resetBtn:SetWidth(150)
resetBtn:SetHeight(24)
resetBtn:SetPoint("TOPLEFT", optBody, "TOPLEFT", 140, -318)
resetBtn:SetText("Reset to defaults")

-- ---------------------------------------------------------------------------
-- Classic floating numbers.
-- ---------------------------------------------------------------------------
-- Kept, not deleted, and off by default.
--
-- The scrolling column is the right default and fixes the actual complaint: an
-- outgoing number used to be anchored to the target's nameplate or unit frame,
-- and a boss scaled several times its normal size puts that anchor somewhere the
-- number has no business being. A fixed screen region cannot be moved by
-- anything a creature does.
--
-- But the floaters are not a mistake to be undone. They are the fallback the
-- corrected path automatically drops to when the scrolling region cannot be
-- claimed, so the code has to stay live rather than rot behind a flag; and the
-- crit pop, the sway and the font picker are a look somebody deliberately tuned.
-- Making it a switch costs one checkbox and settles the argument in the player's
-- favour instead of ours.
local legacyCheck = CreateFrame("CheckButton", "Uncapped64LegacyFctCheck", optBody, "InterfaceOptionsCheckButtonTemplate")
legacyCheck:SetPoint("TOPLEFT", optBody, "TOPLEFT", 20, -352)
-- [#766] Retired 2026-08-08 -- FCT_ADDON_DRAWS gates the whole path in front of this, so
-- the box wrote a saved variable nothing reads. Greyed rather than removed so a player who
-- remembers ticking it can see what happened to it.
_G["Uncapped64LegacyFctCheckText"]:SetText("|cff808080Classic floating numbers (retired -- see above)|r")
legacyCheck.tooltipText = "Draws damage and healing as floating numbers over the units involved, "
    .. "the way this addon did before. Outgoing numbers follow the target, so they can "
    .. "land off-position on a heavily scaled boss. The sliders and font above only "
    .. "affect this mode."
legacyCheck:SetScript("OnClick", function(self)
    Cfg.legacyFct = self:GetChecked() and true or false
    if Uncapped64bitUIDB and Uncapped64bitUIDB.fct then
        Uncapped64bitUIDB.fct.legacyFct = Cfg.legacyFct
    end
    if CT_ApplyBlizzardSurfaces then CT_ApplyBlizzardSurfaces() end
end)
legacyCheck:Disable()   -- [#766] nothing reads Cfg.legacyFct any more

local function ApplyDefaults()
    for k, v in pairs(CFG_DEFAULTS) do
        Cfg[k] = v
        if Uncapped64bitUIDB and Uncapped64bitUIDB.fct then Uncapped64bitUIDB.fct[k] = v end
    end
    FCT_FONT = FCT_FONTS[Cfg.font] or FCT_FONT
    if CT_ApplyBlizzardSurfaces then CT_ApplyBlizzardSurfaces() end
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
    legacyCheck:SetChecked(Cfg.legacyFct and true or false)
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

-- ---------------------------------------------------------------------------
-- Public API for the combat-text threshold.
-- ---------------------------------------------------------------------------
-- Exposed so other addons -- specifically the Dashboard's settings tab -- can read
-- and write this without reaching into Uncapped64bitUIDB. A second addon poking at
-- this one's SavedVariables layout would break silently the day that layout
-- changed, and neither side would be obviously at fault.
--
-- The parser and formatter are exported alongside the setter deliberately. A UI
-- that formatted or parsed the value its own way would drift from how every other
-- number in the game is written, which is the entire point of having one Abbrev.

function UncappedFCT_GetHideUnder()
    return Cfg.minFloat or 0
end

-- Returns the value actually stored, or nil when `v` could not be parsed. Callers
-- must treat nil as "reject the input" -- never as zero, which would turn a typo
-- into "show everything" silently.
function UncappedFCT_SetHideUnder(v)
    local n = ParseAbbrev(v)
    if not n then return nil end

    Cfg.minFloat = n
    Uncapped64bitUIDB = Uncapped64bitUIDB or {}
    Uncapped64bitUIDB.fct = Uncapped64bitUIDB.fct or {}
    Uncapped64bitUIDB.fct.minFloat = n
    -- The threshold is enforced server-side (the packet is never sent), so the
    -- setter is where it has to go up. Every route in -- the slash command, the
    -- Dashboard box, anything else that ever calls this -- lands here, which is
    -- why the push lives on the setter rather than beside any one of them.
    if CT_PushHideUnder then CT_PushHideUnder() end
    if RefreshOptionsPanel then RefreshOptionsPanel() end
    return n
end

function UncappedFCT_ParseAbbrev(s) return ParseAbbrev(s) end
function UncappedFCT_Abbrev(n)      return Abbrev(n)      end

-- ★ The real, uncapped stat totals from the UALL feed, for the rest of the suite.
--
-- Any addon that reads UnitStat / GetSpellBonusDamage / GetCombatRating is reading
-- an int32 wire field the server deliberately SATURATES at MAX_STAT_VALUE =
-- 2,000,000,000 (Unit.h:63) -- which is the whole reason this feed exists. Two
-- Uncapped windows quoting different Strengths for the same character is a worse
-- failure than one of them being capped, so the cache is published rather than
-- left private to the character sheet.
--
-- Keys are the UALL field names: str agi sta int spi map rap sp heal armor def
-- exp mmin mmax rmin rmax critdmg. ⚠ `def` is the defence SKILL and `exp` is
-- expertise POINTS -- neither is the RATING of the same name. Callers wanting a
-- rating must not use these two.
--
-- Returns nil -- never 0 -- when the feed has not arrived, so a caller can tell
-- "no feed yet" from "genuinely zero" and fall back instead of painting a blank.
function UncappedFCT_RealStat(key)
    local v = realStats[key]
    if type(v) ~= "number" then return nil end
    return v
end

-- Hide combat text below a threshold: /hideunder 500m   (/hideunder 0 = show all)
--
-- Accepts the same K/M/B/T vocabulary the rest of the UI speaks, so the value can
-- be typed the way it is read. A malformed argument is refused outright rather
-- than coerced -- "hide under 0" and "hide under everything" are one typo apart,
-- and guessing between them would silently blank the player's combat text.
--
-- THE FILTER MOVED SERVER-SIDE, AND IT IS A DIFFERENT SETTING NOW.
--
-- It used to drop numbers after the packet had already arrived. The server now
-- declines to send the spell-damage, periodic-aura and heal packets at all,
-- which is what makes it cover combat text this addon does not own -- Blizzard's
-- included -- and what saves the bandwidth on a realm where an AoE pull is a
-- hundred packets a second.
--
-- Melee auto-attacks are the exception, because their packet is also what plays
-- the weapon swing on every client watching; filtering it would stop weapons
-- moving. Those are still hidden the old way, here on the client, which is why
-- FctBelowThreshold survives.
--
-- The other trade, stated because a player will notice it: the combat-log CHAT
-- TAB is fed by the same packets, so a filtered hit disappears from there too.
-- There is no way to have one without the other; they are the same message.
-- Anyone who wants the full log back sets /hideunder 0.
SLASH_UNCAPPEDHIDEUNDER1 = "/hideunder"
SlashCmdList["UNCAPPEDHIDEUNDER"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")

    if msg == "" then
        local cur = UncappedFCT_GetHideUnder()
        if cur > 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cff40ff40[Uncapped]|r hiding combat text under " ..
                Abbrev(cur) .. ".  /hideunder 0 to show everything.")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cff40ff40[Uncapped]|r showing all combat text. " ..
                "Try |cffffff00/hideunder 500m|r to hide small hits.")
        end
        return
    end

    local v = UncappedFCT_SetHideUnder(msg)
    if not v then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4040[Uncapped]|r could not read \"" .. msg ..
            "\". Use a number, optionally with K, M, B or T -- e.g. |cffffff00500m|r.")
        return
    end

    if v > 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cff40ff40[Uncapped]|r hiding combat text under " .. Abbrev(v)
            .. ".  Spell and periodic hits that small also leave your combat log tab -- "
            .. "the server stops sending them, and it is the same message.")
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff40ff40[Uncapped]|r showing all combat text.")
    end
end
