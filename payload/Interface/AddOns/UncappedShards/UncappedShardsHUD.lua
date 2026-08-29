--[[ Shards of the Seven -- the combat HUD and the target overlay.

     WHY THIS IS A SEPARATE FILE FROM THE LEDGER
     -------------------------------------------
     This file owns the addon's only OnUpdate and the only code that walks
     WorldFrame's children. Both run every frame, in combat, on every client, so
     this is by far the likeliest file in the addon to throw -- and a runtime
     error here must not be able to take the ledger and the rite down with it.
     WoW compiles each .lua in a .toc separately, so even a syntax error in this
     file leaves /shards working. Same boundary argument that put the server half
     in its own module and this addon outside UncappedItemCustomize.

     WHAT IT DRAWS, AND WHY EACH PIECE IS HERE RATHER THAN ON AN AURA
     ---------------------------------------------------------------
     * MOMENTUM (Kharaz) -- the stack count and the remaining window.
       Deliberately NOT an aura, for two independent reasons:
         - The stack count on the wire is a uint8
           (AuraApplication::BuildUpdatePacket, SpellAuras.cpp:213) AND is
           clamped to the spell's DBC StackAmount (Aura::ModStackAmount,
           SpellAuras.cpp:1013). Momentum is designed uncapped; an aura would
           silently wrap at 255 and there would be no error anywhere.
         - Every stack change is an SMSG_AURA_UPDATE. A big AoE pull would be a
           packet per kill per player, which is exactly what the design forbids.
       ShardSpells.h records the same decision on the server side.
     * RAMPAGE (Kharaz, breakpoint 300) -- read from the real aura
       ShardSpells::RAMPAGE, because that aura's own duration IS the timer.
     * FALSEHOODS (Thessial) -- a count against a cap. Falsehoods are separate
       units, so there is nothing on the player to hang an aura on.
     * MAERITH -- the reflected share, as a percentage.
       ⚠ The WARD is deliberately NOT drawn here. ShardSpells::ANGUISH_WARD is a
         genuine SPELL_AURA_SCHOOL_ABSORB, and UncappedShieldBar already renders
         every absorb the server feeds it (absorb_shield_feed.cpp sums the aura
         type generically). A second shield number on this HUD would be a second
         source of truth for one value, and they would disagree the first time
         one of them lagged.
     * DREAD / TREMBLING / AGONY -- read off the TARGET's own debuffs and redrawn
       beside its nameplate. The stock client puts a stack number in a twelve
       pixel corner of the target frame and nothing at all on the plate.

     THE WINDOW TICKS HERE, NOT ON THE SERVER
     ----------------------------------------
     Momentum's window is 1.0s at rank 1. A server push per change would be a
     packet per kill; a push per tick would be a packet per frame. So the server
     sends the window and how much of it is left ONCE, and this file counts it
     down against GetTime(). The bar is cosmetic. The server's timer is
     authoritative and nothing in here is allowed to decide a stack has expired.

     ⚠ Rebased off GetTime(), never accumulated from `elapsed`. Summing elapsed
       drifts with framerate and loses whole seconds across a stall.
]]

local ADDON = "UncappedShards"

-- ---------------------------------------------------------------------------
-- ⚠⚠ THE SPELL IDS. THIS IS A CONTRACT WITH mod-shards/src/ShardSpells.h.
--
-- These are OUR OWN spells (owner ruling 2026-08-18: "make your own auras, don't
-- reuse anything you don't have to"), authored into the client's Spell.dbc and
-- shipped in patch-enUS-U. Nothing here is a borrowed Blizzard row, so the names
-- and tooltips the default UI draws are already the right words and this file
-- does not have to relabel anything.
--
-- ⚠ THE CLIENT PATCH IS LOAD-BEARING FOR THIS FILE TOO. An id with no client
--   Spell.dbc row draws nothing -- no icon, no name, no tooltip -- because
--   SMSG_AURA_UPDATE carries only the id and every visible property is a
--   client-side lookup. If the rows below did not reach players, this overlay
--   still works (it matches on id, not on anything the client had to resolve),
--   but the stock debuff icon beside it will be blank. Spell 850565 "Mending
--   Fatigue" is the standing example of that having happened.
--
-- ⚠ If ShardSpells.h changes one of these, this file goes silently wrong: the
--   overlay simply shows nothing and nobody gets an error. Change both.
-- ---------------------------------------------------------------------------
local SPELL_DREAD     = 850600   -- Spell.dbc row carries StackAmount 99
local SPELL_TREMBLING = 850601
local SPELL_AGONY     = 850602   -- Spell.dbc row carries StackAmount 99
local SPELL_RAMPAGE   = 850604   -- Kharaz breakpoint 300, on the player

local ICON  = UncappedShards_ICON  or {}
local C     = UncappedShards_COLOR or {}
local GOLD  = C.GOLD  or { 1.00, 0.82, 0.30 }
local RED   = C.RED   or { 0.90, 0.16, 0.16 }
local DIM   = C.DIM   or { 0.45, 0.45, 0.48 }
local PALE  = C.PALE  or { 0.78, 0.78, 0.82 }

-- Verified present in the shipped client MPQs, same sweep as the ledger's gems.
local ICON_MOMENTUM  = "Interface\\Icons\\Ability_Warrior_Rampage"
local ICON_FALSEHOOD = "Interface\\Icons\\Spell_Shadow_RaiseDead"
local ICON_MAERITH   = "Interface\\Icons\\Spell_Shadow_LifeDrain"

local DEFAULTS = {
    enabled = true,
    target  = true,          -- the DREAD/AGONY block over the target
    locked  = true,
    scale   = 1.0,
    point   = "CENTER", x = -260, y = -80,
}

local db                     -- UncappedShardsDB.hud, filled at ADDON_LOADED

local hud = {
    momentum = 0, perStack = 0,
    windowSec = 0, remainSec = 0, baseAt = 0,
    falsehoods = 0, falsehoodCap = 0,
    reflect = 0, leech = 0,
    stamp = 0,
}

-- The server feeds this a few times a second while something is running. If it
-- stops -- zoning, a disconnect, a map that is not ticking -- a HUD still showing
-- twenty-four stacks is worse than no HUD at all, so it puts itself away.
local STALE_AFTER = 4.0

-- SetShown does not exist in 3.3.5a. One helper rather than if/else at every
-- visibility change below.
local function Shown(obj, v)
    if v then obj:Show() else obj:Hide() end
end

local function Label(parent, size, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetFont("Fonts\\FRIZQT__.TTF", size or 12, "OUTLINE")
    fs:SetJustifyH(justify or "LEFT")
    return fs
end

-- ---------------------------------------------------------------------------
-- the HUD frame
-- ---------------------------------------------------------------------------

local hf = CreateFrame("Frame", "UncappedShardsHUD", UIParent)
hf:SetSize(200, 52)
hf:SetPoint("CENTER", -260, -80)
hf:SetMovable(true)
hf:SetClampedToScreen(true)
hf:EnableMouse(false)
hf:RegisterForDrag("LeftButton")
hf:SetScript("OnDragStart", function(self)
    if db and not db.locked then self:StartMoving() end
end)
hf:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    if not db then return end
    local p, _, _, x, y = self:GetPoint()
    db.point, db.x, db.y = p, x, y
end)
hf:Hide()

hf.bg = hf:CreateTexture(nil, "BACKGROUND")
hf.bg:SetAllPoints(hf)
hf.bg:SetTexture(0, 0, 0)
hf.bg:SetAlpha(0.45)

-- Momentum ------------------------------------------------------------------
hf.momIcon = hf:CreateTexture(nil, "ARTWORK")
hf.momIcon:SetSize(16, 16)
hf.momIcon:SetPoint("TOPLEFT", 5, -5)
hf.momIcon:SetTexture(ICON_MOMENTUM)

hf.momText = Label(hf, 13)
hf.momText:SetPoint("LEFT", hf.momIcon, "RIGHT", 5, 0)

hf.momTime = Label(hf, 12, "RIGHT")
hf.momTime:SetPoint("TOPRIGHT", -6, -6)

hf.momBar = CreateFrame("StatusBar", nil, hf)
hf.momBar:SetSize(188, 6)
hf.momBar:SetPoint("TOPLEFT", 6, -24)
hf.momBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
hf.momBar:SetMinMaxValues(0, 1)
hf.momBar:SetValue(0)
hf.momBar.bg = hf.momBar:CreateTexture(nil, "BACKGROUND")
hf.momBar.bg:SetAllPoints(hf.momBar)
hf.momBar.bg:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
hf.momBar.bg:SetVertexColor(0.12, 0.12, 0.12, 0.9)

-- Falsehoods ----------------------------------------------------------------
hf.falIcon = hf:CreateTexture(nil, "ARTWORK")
hf.falIcon:SetSize(14, 14)
hf.falIcon:SetPoint("TOPLEFT", 6, -34)
hf.falIcon:SetTexture(ICON_FALSEHOOD)

hf.falText = Label(hf, 12)
hf.falText:SetPoint("LEFT", hf.falIcon, "RIGHT", 5, 0)

-- Maerith -------------------------------------------------------------------
hf.maeIcon = hf:CreateTexture(nil, "ARTWORK")
hf.maeIcon:SetSize(14, 14)
hf.maeIcon:SetPoint("TOPRIGHT", -6, -34)
hf.maeIcon:SetTexture(ICON_MAERITH)

hf.maeText = Label(hf, 11, "RIGHT")
hf.maeText:SetPoint("RIGHT", hf.maeIcon, "LEFT", -4, 0)

hf:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Shards", GOLD[1], GOLD[2], GOLD[3])

    if hud.momentum > 0 then
        -- hud.dmgPct, not stacks x perStack. The server sends the finished
        -- number; multiplying it out here is the "copy of a curve that will
        -- disagree the first time it is retuned" this file's own header warns
        -- against, and the field was being parsed and thrown away.
        GameTooltip:AddLine(string.format("Momentum x%d  --  %+.1f%% damage",
            hud.momentum, hud.dmgPct), PALE[1], PALE[2], PALE[3])
        GameTooltip:AddLine(string.format(
            "The window is %.1fs. Kill inside it or Momentum leaves you.",
            hud.windowSec), 0.62, 0.62, 0.68, true)
    end

    if hud.falsehoodCap > 0 then
        GameTooltip:AddLine(string.format("Falsehoods  %d / %d",
            hud.falsehoods, hud.falsehoodCap), PALE[1], PALE[2], PALE[3])
        GameTooltip:AddLine("They fight for nobody and fall apart on their own. "
            .. "There is nothing to command and nothing to keep alive.",
            0.62, 0.62, 0.68, true)
    end

    if hud.reflect > 0 then
        GameTooltip:AddLine(string.format("Anguish  --  %.0f%% turned outward, %.0f%% drunk back",
            hud.reflect, hud.leech), PALE[1], PALE[2], PALE[3])
        -- Said plainly because it is the whole shard and it is counter-intuitive.
        GameTooltip:AddLine("Nothing is prevented. You take every hit in full, and "
            .. "you stay standing only while you are killing.", 0.62, 0.62, 0.68, true)
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cff808080/shardhud unlock to move it.|r")
    GameTooltip:Show()
end)
hf:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- ---------------------------------------------------------------------------
-- the target overlay
--
-- 3.3.5a has no C_NamePlate, and a nameplate carries no unit token of any kind.
-- The only way to find one is to walk WorldFrame's children and recognise the
-- shape -- which is exactly what Uncapped64bitUI already does to position its
-- floating combat text (Uncapped64bitUI.lua, LooksLikeNameplate/TargetPlate).
--
-- That code is DUPLICATED here rather than shared. Its helpers are file-locals
-- in another addon, and reaching across addons for them would make this file
-- fail to load whenever that one is disabled -- for a purely cosmetic anchor.
--
-- ⚠ THE MATCH IS BY NAME, AND THAT IS THE CEILING OF THE TECHNIQUE. Two mobs
--   with the same name in one pack cannot be told apart, so the overlay follows
--   the TARGET only and falls back to the target frame when no plate is up.
--   That is not a gap to close later; there is no unit identity on a 3.3.5
--   nameplate to close it with.
-- ---------------------------------------------------------------------------

local function LooksLikeNameplate(f)
    if f:GetName() then return false end
    if f:GetNumChildren() < 1 then return false end
    local hb = select(1, f:GetChildren())
    return hb ~= nil and hb.GetObjectType and hb:GetObjectType() == "StatusBar"
end

local function NameplateName(f)
    local regions = { f:GetRegions() }
    for i = 1, #regions do
        local r = regions[i]
        if r.GetObjectType and r:GetObjectType() == "FontString" then
            local t = r:GetText()
            -- The name, not the level number sitting beside it.
            if t and t ~= "" and not tonumber(t) then return t end
        end
    end
    return nil
end

local plate, plateName

local function TargetPlate()
    if not UnitExists("target") or UnitIsDeadOrGhost("target") then return nil end
    local tname = UnitName("target")
    -- Cached and then REVALIDATED, never simply trusted: plates are recycled, so
    -- a cached frame can be showing a different mob a moment later. Walking every
    -- WorldFrame child once a frame during a big pull is real cost, which is why
    -- the cache exists at all.
    if plate and plate:IsShown() and plateName == tname
        and NameplateName(plate) == tname then
        return plate
    end
    plate, plateName = nil, nil
    local kids = { WorldFrame:GetChildren() }
    for i = 1, #kids do
        local f = kids[i]
        if f:IsShown() and LooksLikeNameplate(f) and NameplateName(f) == tname then
            plate, plateName = f, tname
            return f
        end
    end
    return nil
end

local function CenterInUIParent(f)
    if not f or not f:IsShown() then return nil end
    local x, y = f:GetCenter()
    if not x then return nil end
    local s = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
    return x * s, y * s
end

local tf = CreateFrame("Frame", "UncappedShardsTargetOverlay", UIParent)
tf:SetSize(180, 30)
tf:SetPoint("CENTER")
tf:Hide()

tf.dread = Label(tf, 12, "CENTER")
tf.dread:SetPoint("TOP", 0, 0)
tf.agony = Label(tf, 12, "CENTER")
tf.agony:SetPoint("TOP", tf.dread, "BOTTOM", 0, -1)

-- ---------------------------------------------------------------------------
-- reading the markers
--
-- ⚠ UnitDebuff's ELEVENTH return (spellId) is NOT PROVEN on this client build.
--   The client's own FrameXML never reads past the eighth -- TargetFrame.lua
--   stops at `isMine` -- so nothing in the shipped UI demonstrates it exists.
--   Matching on id is still the right call now that the spells are ours (a name
--   match would be locale-bound and would collide with any future rename), so
--   this fails SAFE and SAYS SO: with no id the overlay draws nothing, and
--   `/shardhud diag` reports why instead of leaving somebody to guess.
--
--   If the probe reports ids ARE available, nothing needs changing. If it
--   reports they are not, the fallback is a client-side lookup by
--   GetSpellInfo(id) name -- which works only because the rows are now ours and
--   the realm is enUS-only.
-- ---------------------------------------------------------------------------

local idsSeen, idsMissing = false, false

-- The eighth return is the caster. Blizzard's own FrameXML names it `isMine`
-- while the API documents a unit token, so accept both shapes rather than
-- betting on one. Absent means "this build does not report it" and we fail open:
-- showing somebody else's Dread is a smaller error than showing none of yours.
local function IsMine(caster)
    if caster == nil then return true end
    if caster == true then return true end
    return caster == "player" or caster == "pet" or caster == "vehicle"
end

local tDread, tAgony, tTrembling = 0, 0, false

-- [#1126] An EXACT caster match beats the fail-open one.
--
-- IsMine above deliberately fails open on a nil caster, and until now that could
-- never mislead anyone: Agony could not stack per caster, so a target carried at
-- most one copy and "somebody's" was always "yours". Setting
-- SPELL_ATTR3_DOT_STACKING_RULE on 850602 fixed the overwriting between party
-- members -- and in doing so made a boss able to carry up to five Agonies at once.
-- Last match wins, so a single out-of-range copy reporting a nil caster would show
-- a party member's stacks as yours.
--
-- So: keep failing open (still better than showing nothing), but the moment a copy
-- reports player/pet/vehicle outright, that one wins and nothing later overrides it.
local function ReadTarget()
    local dread, agony, trembling = 0, 0, false
    local dreadExact, agonyExact = false, false
    for i = 1, 40 do
        local name, _, _, count, _, _, _, caster, _, _, spellId = UnitDebuff("target", i)
        if not name then break end
        if type(spellId) == "number" then idsSeen = true else idsMissing = true end
        if IsMine(caster) and type(spellId) == "number" then
            -- A stack of 1 arrives as 0 on a non-stacking aura; show it as one.
            local n = count or 0
            if n < 1 then n = 1 end
            local exact = (caster == "player" or caster == "pet" or caster == "vehicle")
            if spellId == SPELL_DREAD then
                if exact or not dreadExact then dread = n end
                if exact then dreadExact = true end
            elseif spellId == SPELL_AGONY then
                if exact or not agonyExact then agony = n end
                if exact then agonyExact = true end
            elseif spellId == SPELL_TREMBLING then
                trembling = true
            end
        end
    end
    return dread, agony, trembling
end

local rampage = false

local function ReadPlayer()
    for i = 1, 40 do
        local name, _, _, _, _, _, _, _, _, _, spellId = UnitBuff("player", i)
        if not name then break end
        if spellId == SPELL_RAMPAGE then return true end
    end
    return false
end

local function RedrawTarget()
    if not db or not db.enabled or not db.target then tf:Hide() return end
    if tDread == 0 and tAgony == 0 then tf:Hide() return end

    if tDread > 0 then
        -- Trembling is read from its OWN marker aura and never recomputed from
        -- the stack count against a threshold this file believes in. Duplicating
        -- the rank-to-threshold curve here would make the HUD lie the first time
        -- the server retuned it, and nothing would ever report the disagreement.
        if tTrembling then
            tf.dread:SetText(string.format("|cffff4040DREAD x%d|r   |cffffdd40TREMBLING|r", tDread))
        else
            tf.dread:SetText(string.format("|cffff4040DREAD x%d|r", tDread))
        end
    else
        tf.dread:SetText("")
    end

    if tAgony > 0 then
        tf.agony:SetText(string.format("|cffc060ffAGONY x%d|r", tAgony))
    else
        tf.agony:SetText("")
    end

    tf:Show()
end

-- ---------------------------------------------------------------------------
-- the tick
--
-- ★ ONE OnUpdate, and it lives on a frame that is ALWAYS SHOWN. A hidden frame
--   gets no OnUpdate in 3.3.5, so hanging the staleness check on `hf` itself
--   would stop it running in exactly the state where a stale value is waiting to
--   reappear -- the trap UncappedShieldBar documents at its own `comms` frame.
-- ---------------------------------------------------------------------------

local driver = CreateFrame("Frame")
local sinceText = 0
local targetAuraDirty, sinceTarget = false, 0

driver:SetScript("OnUpdate", function(_, elapsed)
    if not db then return end

    local now = GetTime()

    -- Target debuffs, coalesced. 3.3.5 has no RegisterUnitEvent, so UNIT_AURA
    -- arrives for EVERY unit, and "target" on a raid boss carries every raider's
    -- debuffs -- many events a second, each of which used to run a 40-slot
    -- UnitDebuff scan and then repaint unconditionally. The event now only
    -- raises a flag: the scan runs at most 10 Hz, and the repaint only when one
    -- of the three numbers this HUD actually draws has moved.
    sinceTarget = sinceTarget + elapsed
    if targetAuraDirty and sinceTarget >= 0.1 then
        sinceTarget, targetAuraDirty = 0, false
        local d, a, t = ReadTarget()
        if d ~= tDread or a ~= tAgony or t ~= tTrembling then
            tDread, tAgony, tTrembling = d, a, t
            RedrawTarget()
        end
    end

    if hud.stamp > 0 and now - hud.stamp > STALE_AFTER then
        hud.momentum, hud.falsehoods, hud.reflect = 0, 0, 0
        hud.remainSec, hud.stamp = 0, 0
        hf:Hide()
    end

    if hf:IsShown() then
        -- The bar every frame: it is one SetValue, and it is the thing that has
        -- to look smooth against a 1.0-second window at rank 1. The text at
        -- roughly 10 Hz, because a number changing sixty times a second is
        -- unreadable and costs a SetText each time.
        local left = hud.remainSec - (now - hud.baseAt)
        if left < 0 then left = 0 end
        local frac = 0
        if hud.windowSec > 0 then frac = left / hud.windowSec end
        if frac > 1 then frac = 1 end
        hf.momBar:SetValue(frac)

        if frac <= 0 then
            hf.momBar:SetStatusBarColor(0.35, 0.10, 0.10)
        elseif frac < 0.34 then
            hf.momBar:SetStatusBarColor(0.95, 0.35, 0.10)
        else
            hf.momBar:SetStatusBarColor(0.90, 0.16, 0.16)
        end

        sinceText = sinceText + elapsed
        if sinceText > 0.1 then
            sinceText = 0
            hf.momTime:SetText(string.format("%.1fs", left))
        end
    end

    -- Re-anchored every frame because a nameplate moves every frame. Cheap:
    -- TargetPlate() only rewalks WorldFrame when its cache misses.
    if tf:IsShown() then
        local p = TargetPlate()
        local x, y
        if p then
            x, y = CenterInUIParent(p)
            if x then y = y + 30 end
        end
        if not x and TargetFrame and TargetFrame:IsShown() and UnitExists("target") then
            x, y = CenterInUIParent(TargetFrame)
            if x then y = y - 34 end
        end
        if x then
            tf:ClearAllPoints()
            tf:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
        else
            tf:Hide()
        end
    end
end)

-- ---------------------------------------------------------------------------
-- the wire -- topic SHARDHUD
--
--   Same count-then-rows shape as SHARD and SHARDRITE, so the addon still runs
--   one parser style:
--
--       <n>
--       MOM:<stacks>:<windowMs>:<remainMs>:<perStackBp>:<dmgBp>:<cdrOwnBp>:<cdrTotalBp>:<flags>:<rank>
--       FAL:<count>:<cap>
--       MAE:<reflectPct x100>:<leechPct x100>
--
--     ⚠ ONE FRAME, THREE CONTRIBUTORS, ONE SENDER. The server assembles all three rows and
--       sends once, because this parser zeroes every state before it reads -- so three
--       separate frames on this topic would each wipe the other two, and each shard would
--       look intermittently broken depending on which fired last.
--
--   A row is simply ABSENT when that shard is not equipped. A payload claiming
--   zero rows means "nothing is running" and puts the HUD away -- the same way
--   an empty SHARDRITE closes the rite, so there is no second message type whose
--   only job is to say stop.
--
--   ⚠ SERVER-SIDE SEND RULES THIS FILE DEPENDS ON:
--     - Coalesce at about 100ms, but ALWAYS flush when `stacks` changes. The
--       window is 1.0s at rank 1, so a 250ms coalesce would put a 25% error on
--       the bar in exactly the case where the bar matters.
--     - Send a zeroing frame on leaving combat and on a map change. The 4-second
--       staleness guard here is a backstop, not the mechanism.
--     - Do not send at all when no shard with a HUD state is equipped. Most
--       players hold none of the three.
--
--   pctPerStack is sent rather than derived from a rank, deliberately: anything
--   this file recomputes from a rank is a copy of a curve that will disagree the
--   first time the curve is retuned.
-- ---------------------------------------------------------------------------

local function SplitLines(payload)
    local out, at, n = {}, 1, #payload
    while at <= n do
        local nl = payload:find("\n", at, true)
        if not nl then out[#out + 1] = payload:sub(at) break end
        if nl > at then out[#out + 1] = payload:sub(at, nl - 1) end
        at = nl + 1
    end
    return out
end

local function Redraw()
    if not db or not db.enabled then hf:Hide() return end

    local showMom = hud.momentum > 0
    local showFal = hud.falsehoodCap > 0
    local showMae = hud.reflect > 0

    if not (showMom or showFal or showMae) then hf:Hide() return end

    Shown(hf.momIcon, showMom)
    Shown(hf.momBar,  showMom)
    Shown(hf.momTime, showMom)
    Shown(hf.momText, showMom)
    if showMom then
        -- Either source may say rampage is up: `rampage` is the player's own
        -- aura as scanned here, hud.rampage is flags bit 16 as the server sees
        -- it. They agree in practice, and taking both means neither a missed
        -- aura event nor a coalesced push can drop the word off the HUD.
        if rampage or hud.rampage then
            hf.momText:SetText(string.format(
                "MOMENTUM  |cffffdd40x%d|r  |cffff6020RAMPAGE|r", hud.momentum))
        else
            hf.momText:SetText(string.format(
                "MOMENTUM  |cffffdd40x%d|r  |cff909090%+.0f%%|r",
                hud.momentum, hud.dmgPct))
        end
    end

    Shown(hf.falIcon, showFal)
    Shown(hf.falText, showFal)
    if showFal then
        hf.falText:SetText(string.format("FALSEHOODS   %d / %d",
            hud.falsehoods, hud.falsehoodCap))
    end

    Shown(hf.maeIcon, showMae)
    Shown(hf.maeText, showMae)
    if showMae then
        -- The reflected share only. The WARD is UncappedShieldBar's to draw.
        hf.maeText:SetText(string.format("%.0f%%", hud.reflect))
    end

    hf:Show()
end

local function OnHud(payload)
    local lines = SplitLines(payload)
    local claimed = tonumber(lines[1] or "0") or 0

    -- ⚠ EVERY state is zeroed before parsing, which is exactly why the server must send all
    --   three rows in ONE frame. A row absent from this frame means that shard has nothing
    --   live, and the HUD must stop drawing it.
    hud.momentum, hud.perStack   = 0, 0
    hud.windowSec, hud.remainSec = 0, 0
    hud.dmgPct, hud.cdrPct, hud.cdrTotal = 0, 0, 0
    hud.flags, hud.rank, hud.rampage = 0, 0, false
    hud.falsehoods, hud.falsehoodCap = 0, 0
    hud.reflect, hud.leech = 0, 0
    hud.momMalformed = false
    hud.baseAt = GetTime()
    hud.stamp  = hud.baseAt

    if claimed == 0 then
        hf:Hide()
        return
    end

    for i = 2, #lines do
        local line = lines[i]
        local tag = line:sub(1, 3)
        if tag == "MOM" then
            --[[ MOM:<stacks>:<windowMs>:<remainMs>:<perStackBp>:<dmgBp>:<cdrOwnBp>:<cdrTotalBp>:<flags>:<rank>

                 ⚠ NINE FIELDS. This row started at four and grew, and an anchored pattern
                   fails CLOSED -- MOM simply never matches, the HUD sits empty, and nothing
                   errors anywhere. So the count is asserted rather than assumed: if the
                   server ever adds a field without this being widened, /shardhud diag says
                   so instead of the bar quietly never appearing.

                 flags: 1 decay-one-at-a-time (50) | 2 cdr live (150)
                        4 rampage unlocked (300)   | 8 pause available (500)
                        16 rampage ACTIVE now ]]
            local s, w, r, p, dmg, cdr, cdrTot, flags, rank =
                line:match("^MOM:(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)$")
            if s then
                hud.momentum   = tonumber(s)
                hud.windowSec  = tonumber(w) / 1000
                hud.remainSec  = tonumber(r) / 1000
                hud.perStack   = tonumber(p) / 100
                hud.dmgPct     = tonumber(dmg) / 100
                hud.cdrPct     = tonumber(cdr) / 100
                hud.cdrTotal   = tonumber(cdrTot) / 100
                hud.flags      = tonumber(flags)
                hud.rank       = tonumber(rank)
                hud.rampage    = bit.band(hud.flags, 16) ~= 0
            else
                hud.momMalformed = true
            end
        elseif tag == "FAL" then
            local c, cap = line:match("^FAL:(%d+):(%d+)$")
            if c then
                hud.falsehoods   = tonumber(c)
                hud.falsehoodCap = tonumber(cap)
            end
        elseif tag == "MAE" then
            local rf, lc = line:match("^MAE:(%d+):(%d+)$")
            if rf then
                hud.reflect = tonumber(rf) / 100
                hud.leech   = tonumber(lc) / 100
            end
        end
    end

    Redraw()
end

-- ---------------------------------------------------------------------------
-- wiring
-- ---------------------------------------------------------------------------

--[[ Registration is conditional and its absence is not an error. Without the DLL
     UncappedNative is simply not there, and a client that cannot see this HUD
     still gets every point of Momentum it earned -- it just does not get to
     watch. Same degrade-safely argument as the ledger's topics. ]]
if UncappedNative and UncappedNative.IsAvailable() then
    UncappedNative.Register("SHARDHUD", OnHud)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_TARGET_CHANGED")
ev:RegisterEvent("UNIT_AURA")
ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        UncappedShardsDB = UncappedShardsDB or {}
        UncappedShardsDB.hud = UncappedShardsDB.hud or {}
        db = UncappedShardsDB.hud
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then db[k] = v end
        end
        hf:ClearAllPoints()
        hf:SetPoint(db.point, UIParent, db.point, db.x, db.y)
        hf:SetScale(db.scale)
        hf:EnableMouse(not db.locked)
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        -- Registered here as well as at file load: the DLL builds its Lua
        -- bindings when the world state comes up, so on a very early load
        -- IsAvailable() can have been false above. Register is idempotent.
        if UncappedNative and UncappedNative.IsAvailable() then
            UncappedNative.Register("SHARDHUD", OnHud)
        end
        plate, plateName = nil, nil
        return
    end

    if event == "PLAYER_TARGET_CHANGED" then
        plate, plateName = nil, nil
        -- Immediate: a new target has to paint at once, and any scan the
        -- throttle below was still holding is about the OLD one.
        targetAuraDirty, sinceTarget = false, 0
        tDread, tAgony, tTrembling = ReadTarget()
        RedrawTarget()
        return
    end

    -- UNIT_AURA. Flag only -- the driver does the scan, at most 10 Hz, and only
    -- repaints on a real change. See the note there.
    if arg1 == "target" then
        targetAuraDirty = true
    elseif arg1 == "player" then
        local was = rampage
        rampage = ReadPlayer()
        if was ~= rampage and hf:IsShown() then Redraw() end
    end
end)

-- ---------------------------------------------------------------------------
-- settings
-- ---------------------------------------------------------------------------

-- Held so /shardhud can push its changes back into the settings page. Without
-- this, unlocking from chat and then opening ESC > Interface shows a checkbox
-- still claiming the HUD is locked -- the house pattern is to call the widget's
-- own uncappedRefresh rather than to let the two drift.
local lockCheck, scaleSlider

if UncappedUI then
    local panel, L = UncappedUI.CreatePanel("Shards",
        "The Shards of the Seven combat HUD -- Momentum, Falsehoods, and Dread/Agony over your target.")

    L:Header("Combat HUD")
    L:Check("Show the shard HUD",
        function() return db and db.enabled end,
        function(v) db.enabled = v; if v then Redraw() else hf:Hide() end end)
    L:Check("Show Dread and Agony over the target",
        function() return db and db.target end,
        function(v) db.target = v; RedrawTarget() end)
    lockCheck = L:Check("Lock the HUD in place",
        function() return db and db.locked end,
        function(v) db.locked = v; hf:EnableMouse(not v) end)
    scaleSlider = L:Slider("HUD scale", 0.6, 1.6, 0.05,
        function() return (db and db.scale) or 1 end,
        function(v) db.scale = v; hf:SetScale(v) end, "%.2f")

    L:Gap(6)
    L:Note("|cff808080The HUD appears on its own when a shard that has something to show "
        .. "is equipped -- there is nothing to turn on. Dread and Agony are read from the "
        .. "target's own debuffs, so they follow the target's nameplate when one is up and "
        .. "sit under the target frame when one is not.|r", 58)
end

SLASH_UNCAPPEDSHARDSHUD1 = "/shardhud"
local function RefreshPanel()
    if lockCheck and lockCheck.uncappedRefresh then lockCheck.uncappedRefresh() end
    if scaleSlider and scaleSlider.uncappedRefresh then scaleSlider.uncappedRefresh() end
end

SlashCmdList["UNCAPPEDSHARDSHUD"] = function(msg)
    msg = string.lower(msg or "")

    if msg == "unlock" then
        db.locked = false
        hf:EnableMouse(true)
        RefreshPanel()
        DEFAULT_CHAT_FRAME:AddMessage("|cffffdd40Shards:|r HUD unlocked -- drag it, then /shardhud lock.")
        -- Shown with sample values so there is something to grab when nothing is
        -- actually running. Cleared by the next real frame, or by /shardhud lock.
        --
        -- ⚠ NINE MOM fields, matching the parser. This sample was left at the
        --   four it was born with, so it failed the anchored match, set
        --   hud.momMalformed, and left the momentum icon/bar/text hidden -- the
        --   one part of the HUD you most need to see in order to place it. It
        --   also made /shardhud diag announce in red that the addon was out of
        --   date, which was never true. Widen this WITH the parser.
        OnHud("3\nMOM:24:3400:2600:400:9600:0:0:5:3\nFAL:3:10\nMAE:2200:2600\n")

    elseif msg == "lock" then
        db.locked = true
        hf:EnableMouse(false)
        RefreshPanel()
        DEFAULT_CHAT_FRAME:AddMessage("|cffffdd40Shards:|r HUD locked.")

    elseif msg == "reset" then
        db.point, db.x, db.y = DEFAULTS.point, DEFAULTS.x, DEFAULTS.y
        db.scale = DEFAULTS.scale
        hf:ClearAllPoints()
        hf:SetPoint(db.point, UIParent, db.point, db.x, db.y)
        hf:SetScale(db.scale)
        RefreshPanel()
        DEFAULT_CHAT_FRAME:AddMessage("|cffffdd40Shards:|r HUD position reset.")

    elseif msg == "diag" then
        -- Answers the one question this file cannot answer for itself: does
        -- UnitDebuff report a spell id on this build? Target something with any
        -- debuff on it first, or this has nothing to measure.
        DEFAULT_CHAT_FRAME:AddMessage("|cffffdd40Shards HUD:|r native pipe "
            .. ((UncappedNative and UncappedNative.IsAvailable()) and "available" or "ABSENT"))
        if not idsSeen and not idsMissing then
            DEFAULT_CHAT_FRAME:AddMessage("  no debuff has been read yet -- target something "
                .. "with a debuff on it and run this again.")
        elseif idsMissing and not idsSeen then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff2020  UnitDebuff returns NO spell id on this "
                .. "client. Dread/Agony cannot be matched and the overlay will stay blank. "
                .. "Report this.|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("  UnitDebuff spell ids: |cff40ff40available|r")
        end
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "  last frame: momentum %d, falsehoods %d/%d, reflect %.0f%%, %.1fs ago",
            hud.momentum, hud.falsehoods, hud.falsehoodCap, hud.reflect,
            (hud.stamp > 0) and (GetTime() - hud.stamp) or 0))

        --[[ ⚠ The one failure this file CANNOT show you any other way. An anchored pattern
             fails closed: if the server widens the MOM row without this parser being widened
             to match, the match simply returns nil, the bar never appears, and nothing
             errors. Reported here rather than left to be guessed at. ]]
        if hud.momMalformed then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff2020  the MOM row did not match -- the "
                .. "server's format has changed and this addon is out of date. The Momentum "
                .. "bar will stay blank until it is updated.|r")
        end

    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffffdd40Shards HUD:|r /shardhud unlock | lock | reset | diag")
    end
end
