--[[
  Uncapped Soulforge  (formerly Item Customize / Soulbinding)
  -----------------------------------------------------------
  Two systems:
    * The Soulforge -- a per-account bar. Junk gear you don't want is eaten for
      "souls"; each time the bar fills, a global EXTRACTION multiplier rises a
      little (forever). Auto-consume (ICAC) and Auto-melt (ICAO), both off by
      default, feed it as you play; the whitelist protects named items from
      being picked up by either. There is no manual single-item feed.
      [#812] "Render junk gear" (ICVRENDER) is the ON-DEMAND bulk door: one
      press renders every GREY and WHITE weapon/armour piece out of your Vault
      in one go, without turning the all-quality standing sweep on. Preview
      first, confirm second -- the server arms the confirmation, exactly as it
      does for Auto-consume.
    * Soulbinding -- feed an EXACT DUPLICATE of a piece of gear onto the copy you
      are keeping, to extract (the current multiplier) of its stats and ramp its
      procs. "Soulbind Duplicates" does it in bulk from your bags + vault.

      [#1119] WHICH COPY RECEIVES IT. The one you are WEARING, first and always.
      If you are not wearing one, an ALREADY-SOULBOUND copy in your BAGS receives
      it instead -- so an off-set piece you have been feeding for weeks keeps
      growing without having to be equipped for the click. A copy that has never
      been soulbound is never chosen as the receiver: it would be indistinguishable
      from the duplicates around it, and the sweep would eat one of a matched pair.

      ⚠ Only the BULK sweep (ICSBALL) has that fallback. The server's single-item
        soulbind is still equipped-only, which is why the "you can only soulbind a
        duplicate of an item you're wearing" refusal below is still correct.

  Transport (matches the rest of the UNC pipe):
    * SEND    : SendAddonMessage("REAGENTBANK", body, "WHISPER", UnitName("player"))
    * RECEIVE : CHAT_MSG_ADDON, arg1 == "UNC", arg2 == body.

  Soul Forge is a Dashboard tab (opened via /dashboard, not its own window).
  /extract, /ex and /socket, /sock still open their own standalone popups.
  /sbdebug   toggle verbose wire logging
]]


--[[
    KitButton -- the in-house widget kit's button, with a guarded fall back to
    the raw Blizzard template.

    Guarded rather than calling UncappedUIKit directly because this addon lists
    UncappedUI as an OPTIONAL dependency: if it is absent or errored during load,
    an unguarded call is a nil index at build time and the whole window dies.
    Same shape as the fallback in UncappedKeystoneRun.

    ⚠ Resolved at FILE SCOPE on purpose. A `local UIKit` declared partway down
      and used above that line silently reads the nil GLOBAL of the same name --
      it parses fine and only errors when the window opens.
]]
local UIKit = _G.UncappedUIKit
local function KitButton(parent, label, w, h)
    if UIKit and UIKit.CreateButton then
        return UIKit.CreateButton(parent, label or "", w, h)
    end
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    if w then b:SetWidth(w) end
    if h then b:SetHeight(h) end
    b:SetText(label or "")
    return b
end

local SEND_PREFIX = "REAGENTBANK"
local PIPE_PREFIX = "UNC"
local QUESTION    = "Interface\\Icons\\INV_Misc_QuestionMark"

-- [#1124] Scroll of Extraction as an ITEM ENTRY, i.e. one sitting in your bags
-- rather than one already absorbed into the server-side balance. See the scroll
-- count in the Extraction panel's Refresh for why both terms are needed.
local SCROLL_EXTRACTION = 500208

-- ---- debug ---------------------------------------------------------------
local DEBUG = false
local function dbg(...)
  if not DEBUG then return end
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[SF]|r " .. table.concat(parts, " "))
end
local function msg(text)
  DEFAULT_CHAT_FRAME:AddMessage("|cffffd200Soulforge:|r " .. text)
end

-- ---- name tables ---------------------------------------------------------
local STAT_NAMES = {
  [0]="Mana",[1]="Health",[3]="Agility",[4]="Strength",[5]="Intellect",[6]="Spirit",[7]="Stamina",
  [12]="Defense Rating",[13]="Dodge Rating",[14]="Parry Rating",[15]="Block Rating",
  [16]="Melee Hit Rating",[17]="Ranged Hit Rating",[18]="Spell Hit Rating",
  [19]="Melee Crit Rating",[20]="Ranged Crit Rating",[21]="Spell Crit Rating",
  [28]="Crit Damage",[29]="Crit Damage",[30]="Crit Damage",
  [31]="Hit Rating",[32]="Crit Rating",[33]="Hit Avoidance",[34]="Crit Avoidance",
  [35]="Resilience Rating",[36]="Crit Damage",[37]="Expertise Rating",
  [38]="Attack Power",[39]="Ranged Attack Power",[41]="Spell Healing",[42]="Spell Damage",
  [43]="Mana Regen",[44]="Armor Penetration",[45]="Spell Power",[46]="Health Regen",
  [47]="Spell Penetration",[48]="Block Value",
  [61]="Holy Resistance",[62]="Fire Resistance",[63]="Nature Resistance",
  [64]="Frost Resistance",[65]="Shadow Resistance",[66]="Arcane Resistance",
}
local function statName(t) return STAT_NAMES[t] or ("Stat #" .. tostring(t)) end

-- Haste is Crit Damage now: haste-rating stat types show their crit-damage
-- percent (rating / 1000), not the raw rating -- consistent with tooltips/sheet.
local HASTE_TYPES = { [28]=true, [29]=true, [30]=true, [36]=true }
local function statLineText(t, val)
  if HASTE_TYPES[t] then
    local pct = (tonumber(val) or 0) / 1000
    local s = (pct == math.floor(pct)) and string.format("%d", pct) or string.format("%.2f", pct)
    return "+" .. s .. "% Crit Damage"
  end
  return "+" .. tostring(val) .. " " .. statName(t)
end

local TRIGGER_LABEL = { [0]="On Use", [1]="Passive", [2]="On Hit", [3]="On Cast" }
local function triggerLabel(t) return TRIGGER_LABEL[t] or ("Trigger " .. tostring(t)) end
local function spellName(id)
  local n = GetSpellInfo(id)
  return n or ("Spell #" .. tostring(id))
end

-- Blizzard shipped ~211 developer-facing names in Spell.dbc -- "Item - Chamber of Aspects
-- 25 Heroic Nuker Trinket", plus [DND]/[PH]/zzOLD families -- and GetSpellInfo returns
-- them verbatim, so procs were displaying as internal build notes.
--
-- Anchored on the PREFIX deliberately: "Create Item - Fizzcrank Practice Parachute" is a
-- real, player-facing name that a substring match would mangle.
local function isDevSpellName(n)
  if not n then return false end
  return n:find("^Item %- ") ~= nil
      or n:find("^zz") ~= nil
      or n:find("%[DND%]") ~= nil
      or n:find("%[PH%]") ~= nil
end

-- Best-effort tidy for a dev name when we can't do better: drop the "Item - " prefix and
-- the internal markers, leaving e.g. "Sunwell Dungeon Melee Trinket".
local function tidyDevSpellName(n)
  n = n:gsub("^Item %- ", ""):gsub("^zzOLD%s*", ""):gsub("^zz%s*", "")
  n = n:gsub("%s*%[DND%]", ""):gsub("%s*%[PH%]", ""):gsub("%s+DND$", ""):gsub("%s+Base$", "")
  n = n:gsub("^%s+", ""):gsub("%s+$", "")
  return n ~= "" and n or nil
end

-- What to actually label a proc with.
--
-- A developer-named spell is bespoke to one item, so the server sends that item's entry
-- and its name is the one a player recognises ("Charred Twilight Scale"). Shared procs
-- like Drain Life sit on dozens of items, resolve to no entry, and keep their own name.
local function procDisplayName(p)
  local n = spellName(p.spellId)
  if not isDevSpellName(n) then return n end
  if p.srcItem and p.srcItem > 0 then
    local itemName = GetItemInfo(p.srcItem)
    if itemName then return itemName end
  end
  return tidyDevSpellName(n) or n
end

-- magnitude percent (100 = 1.0x) -> tidy "1.5" style multiplier string
local function fmtMult(magPct)
  local m = (tonumber(magPct) or 100) / 100
  local s = string.format("%.2f", m)
  s = s:gsub("0+$", ""):gsub("%.$", "")
  return s
end

-- The mechanic clause for a proc.
-- Summon procs (summonCap > 0) spend magnitude on the creatures' health and damage
-- rather than on raw effect size, and are capped at summonCap live at once -- so they
-- get their own wording instead of the generic "power" multiplier.
local function procMechanic(p)
  local mult = fmtMult(p.mag)
  local cap = p.summonCap or 0
  local power
  if cap > 0 then
    power = string.format("%sx summon health & damage", mult)
  else
    power = string.format("%sx power", mult)
  end

  local out
  if p.trigger == 2 or p.trigger == 3 then
    if mult ~= "1" then out = string.format("%d%% chance, %s", p.chance or 0, power)
    else out = string.format("%d%% chance", p.chance or 0) end
  else
    if mult ~= "1" then out = power else out = "base effect" end
  end

  if cap > 0 then out = out .. string.format(" (max %d out)", cap) end
  return out
end

-- ---- big-number formatting -----------------------------------------------
-- Soulbound procs ramp without a cap, so effect values run far past what a stock
-- tooltip ever shows. Render them with a magnitude suffix instead of 13 digits.
local NUM_SUFFIX = { "K", "M", "B", "T", "Q", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }

local function fmtBig(n)
  n = tonumber(n) or 0
  local neg = n < 0
  if neg then n = -n end

  local out
  if n < 1000 then
    -- Small values keep their exact form; a proc for "7" should not read "0K".
    out = tostring(math.floor(n + 0.5))
  else
    local i, v = 0, n
    while v >= 1000 and i < #NUM_SUFFIX do
      v = v / 1000
      i = i + 1
    end
    -- 2 significant decimals under 10, 1 under 100, none above -- keeps width steady.
    local fmt = (v < 10 and "%.2f") or (v < 100 and "%.1f") or "%.0f"
    local s = string.format(fmt, v)
    -- Trim trailing zeros ONLY past a decimal point: a blanket "0+$" strip would
    -- turn "100" into "1".
    if s:find(".", 1, true) then
      s = s:gsub("0+$", "")
      s = s:gsub("%.$", "")
    end
    out = s .. NUM_SUFFIX[i]
  end

  if neg then out = "-" .. out end
  return out
end

-- ---- spell description scraping ------------------------------------------
-- 3.3.5a has no GetSpellDescription, but spell hyperlinks work: point a hidden
-- tooltip at "spell:<id>" and read its lines. Same trick UncappedVault uses for
-- items. Cached per spell -- the text never changes for a given id.
local descScan = CreateFrame("GameTooltip", "UncappedSoulForgeDescScan", UIParent, "GameTooltipTemplate")
descScan:SetOwner(UIParent, "ANCHOR_NONE")
local descCache = {}

local function spellDescription(spellId)
  if descCache[spellId] ~= nil then
    return descCache[spellId] ~= false and descCache[spellId] or nil
  end

  descScan:SetOwner(UIParent, "ANCHOR_NONE")
  descScan:ClearLines()
  local ok = pcall(function() descScan:SetHyperlink("spell:" .. spellId) end)

  local desc
  if ok then
    -- The description is the last non-empty left line; earlier lines are the
    -- spell name, rank, cast time, range, cooldown and so on.
    for i = descScan:NumLines(), 2, -1 do
      local fs = _G["UncappedSoulForgeDescScanTextLeft" .. i]
      local txt = fs and fs:GetText()
      if txt and txt:match("%S") then
        desc = txt
        break
      end
    end
  end

  descCache[spellId] = desc or false
  return desc
end

-- Rewrite the base effect values inside a scraped description to OUR scaled values.
--
-- Only the numbers the server told us are real effect base points get touched, so a
-- "for 5 sec" duration or "40 yd" range is left alone. Longest base value first, so
-- replacing 1500 can't be pre-empted by a 500 that appears inside it. Returns nil if
-- nothing matched, which lets the caller fall back to the old "Nx power" wording
-- rather than print a description with misleading stock numbers.
local function scaleDescription(desc, bases, mult)
  if not desc or mult == 1 then return desc end

  -- Dedupe: an effect with no die sides reports min == max, and two effects can share
  -- a value. Replacing the same number twice is wasted work.
  local seen, ordered = {}, {}
  for _, b in ipairs(bases) do
    if b and b > 0 and not seen[b] then
      seen[b] = true
      table.insert(ordered, b)
    end
  end
  if #ordered == 0 then return nil end
  table.sort(ordered, function(a, b) return a > b end)

  local out, hit = desc, false
  for _, b in ipairs(ordered) do
    local scaled = fmtBig(b * mult)
    -- Frontier-bounded so 500 can't match inside 1500. %f matches an empty string,
    -- so no captures are needed and the replacement is a literal.
    local pattern = "%f[%d]" .. string.format("%d", b) .. "%f[%D]"
    local replaced, n = out:gsub(pattern, (scaled:gsub("%%", "%%%%")))
    if n > 0 then
      out, hit = replaced, true
    end
  end

  return hit and out or nil
end

-- Correct the stack count inside a scraped description.
--
-- [#999] The description is the spell's own stock text and can disagree with what the
-- server actually enforces -- the reported case said "Can be applied up to 15 times"
-- on a proc the server caps at 5. The addon used to print that verbatim because it had
-- no way to know better; the server now sends the real cap on ICIPROCFACT.
--
-- Deliberately narrow: it only rewrites a number that is immediately followed by
-- "time"/"times", so a duration, a radius or the effect's own magnitude cannot be
-- caught by it. Returns the text unchanged when there is nothing to correct, when the
-- server sent no cap, or when the two already agree.
local function fixStackCount(desc, stackCap)
  if not desc or not stackCap or stackCap <= 0 then return desc end
  return (desc:gsub("(%d+)(%s+times?)", function(n, tail)
    if tonumber(n) == stackCap then return n .. tail end
    return tostring(stackCap) .. tail
  end))
end

-- One short line saying what actually moves this proc's numbers.
--
-- [#1033] The extraction ban list told a player "nothing on this realm can scale it, so
-- every rank you poured in would be wasted" about a proc carrying a 100% spell-power
-- coefficient. Both halves of that sentence were being guessed at. They are now two
-- separate facts from the server, and they are genuinely independent -- the proc in that
-- report scales fully with spell power and not at all with rank.
local function procScalingNote(p)
  if not p or p.rankScales == nil then return nil end   -- older server, say nothing

  local from = {}
  if p.spPct and p.spPct > 0 then from[#from+1] = string.format("spell power (%d%%)", p.spPct) end
  if p.apPct and p.apPct > 0 then from[#from+1] = string.format("attack power (%d%%)", p.apPct) end

  if p.rankScales then
    if #from > 0 then
      return "Ranks raise this, and it also scales with " .. table.concat(from, " and ") .. "."
    end
    return "Ranks raise this."
  end

  if #from > 0 then
    return "Ranks do NOT raise this \226\128\148 it scales with " .. table.concat(from, " and ") .. " instead."
  end
  return "Ranks do NOT raise this, and nothing else scales it either."
end

-- Wrap `s` into a list of lines of at most `width` characters, breaking on spaces.
--
-- Both tooltip paths need this done UP FRONT rather than by the renderer:
-- GameTooltip:AddLine does not wrap, so one long spell description stretches the whole
-- tooltip across the screen; and the scrollable companion panel lays out fixed-height
-- rows, so text wrapped by the FontString would overlap the row below it. Pre-splitting
-- gives both a list of short lines, and makes #lines an honest height for the
-- inline-vs-panel decision.
-- Chars per wrapped line. Sized to the narrower of the two targets: the companion
-- panel's 248px rows in GameTooltipText, which is roughly this many characters.
local TIP_WRAP_CHARS = 46

local function wrapText(s, width)
  local out = {}
  for word in tostring(s or ""):gmatch("%S+") do
    -- A single word longer than the line (a huge number, a long spell name) would
    -- otherwise blow the width on its own, so hard-split it.
    while #word > width do
      table.insert(out, word:sub(1, width))
      word = word:sub(width + 1)
    end
    local n = #out
    if n == 0 or #out[n] + 1 + #word > width then
      table.insert(out, word)
    else
      out[n] = out[n] .. " " .. word
    end
  end
  return out
end

local SND_SEAL = "Sound\\Spells\\SoulstoneResurrection_Base.wav"

--[[ ==========================================================================
     ★★ CAPABILITY GATE -- "does this server understand mode 2 (KEEP)?"

     THE HAZARD THIS EXISTS FOR IS OUR OWN DEPLOY ORDER, NOT A BUG.

     The realm patches CLIENT FIRST, always: publish the payload, confirm the
     CDN is serving it, and only THEN take the server down -- because the
     launcher blocks PLAY on a stale client, so patching the other way round
     strands everyone. The consequence is a window of a few minutes in which
     THIS ADDON IS LIVE AGAINST THE OLD SERVER.

     An old server parses ICAO as `ParseU32(args) != 0`. It has no mode 2. So a
     player who relaunches inside that window, opens this panel and picks
     "Open them and keep everything" sends a 2, the old server reads it as
     "on" -- and MELTS THEIR GEAR. That is precisely the failure report #375 is
     about, delivered by our own deploy sequencing, to the players keenest to
     use the fix.

     THE PROOF IS FREE AND ALREADY ON THE WIRE. ICSACKS is a verb only the new
     server sends, and the new server bundles it into every reply to the ICSF
     request this addon already makes at PLAYER_LOGIN and on every tab
     activation. So no new probe is needed: receiving one IS the handshake, and
     never receiving one IS an old server.

     FAILS CLOSED, DELIBERATELY. Until an ICSACKS lands, KEEP is unavailable and
     mode 2 is not sent under any circumstance -- not by the click handler, not
     by anything. Off (0) and melt (1) stay live throughout, because both
     predate this release and mean exactly the same thing on either server. A
     greyed row for a few minutes is a nuisance; a melted stack of epics is
     unrecoverable.

     Session-scoped and a plain file-local on purpose: nothing persists it,
     nothing can copy it into saved variables, and /reload re-probes at
     PLAYER_LOGIN.
     ========================================================================== ]]
local serverKeepOk = false

--[[ ==========================================================================
     [#812] THE RENDER BUTTON'S OWN "is this server new enough?" -- AND WHY IT
     IS A SOFT TIMEOUT RATHER THAN THE HARD GATE ABOVE.

     serverKeepOk exists because an OLD server MISREADS the new value: ICAO's
     mode 2 parses as `!= 0` there, i.e. as MELT, so sending it during the
     client-first deploy window destroys gear. That is a hard gate because the
     failure is silent and irreversible.

     ICVRENDER has no such twin. It is a brand-new verb, and an old server drops
     an unrecognised verb on the floor (`return false` -- "not one of ours"). The
     worst an old server can do with it is nothing at all. So the only real
     problem is a button that appears dead for a few minutes, and the honest fix
     for that is to SAY SO after a moment rather than to lock the control.

     Nil means "not waiting". Set to GetTime() on send, cleared by any ICVR, and
     the button's OnUpdate turns a long silence into a sentence.
     ========================================================================== ]]
local renderWaitSince = nil
local RENDER_WAIT_TIMEOUT = 5

-- 211972 -> "211,972". BreakUpLargeNumbers does not exist in 3.3.5a, and the
-- top sack holder on this realm is carrying six figures of them -- an unbroken
-- run of digits there is genuinely hard to read at a glance.
local function groupDigits(n)
  local s = tostring(n or 0)
  local out = s
  repeat
    local k
    out, k = out:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
  until k == 0
  return out
end

--[[ ==========================================================================
     [#1227] THE ON-USE CLICKY'S COOLDOWN -- READ FROM THE SERVER, NOT INVENTED.

     UseProc stamps the SOURCE spell's own RecoveryTime (falling back to
     CategoryRecoveryTime) with needSendToClient = true, so the client is told
     over SMSG_SPELL_COOLDOWN like any other cooldown. That is what makes it
     survive a /reload instead of living only in this addon's memory, and it is
     why the swipe below is the server's number rather than a client-side guess.

     ⚠ Deliberately the spell's OWN timing rather than a flat module value: an
       extracted effect should fire exactly as often as the item it came from, or
       extraction becomes a way to make a clicky strictly better than its source.

     ⚠ A 1.5s swipe over a three-minute trinket effect is WORSE than no swipe at
       all -- the button would look ready and every click would be refused. So the
       local throttle paints NOTHING; it is a double-click guard and nothing else.

     ⚠ GetSpellCooldown IS AMBIGUOUS IN 3.3.5a. It takes either a spell NAME or a
       (spellbook index, bookType) pair, so a bare number can in principle be read
       as an INDEX. Both forms are therefore tried, both inside pcall, and an
       answer is only believed when it is a live cooldown of sane length:

         * the id form is what the cooldown packet actually feeds, and proc spell
           ids are five and six digits -- far past any spellbook index, so an
           index collision cannot happen with real data;
         * the name form is the fallback for a proc that IS in the player's book;
         * anything longer than a day is rejected as a misread rather than drawn.
     ========================================================================== ]]
local CD_SANE_MAX = 86400

local function useCooldownOf(spellId)
  if not spellId then return nil end

  local function believe(ok, start, duration)
    if not ok then return nil end
    start, duration = tonumber(start), tonumber(duration)
    if not start or not duration then return nil end
    if start <= 0 or duration <= 0 or duration > CD_SANE_MAX then return nil end
    return start, duration
  end

  local s, d = believe(pcall(GetSpellCooldown, spellId))
  if s then return s, d end

  local name = GetSpellInfo(spellId)
  if name then
    s, d = believe(pcall(GetSpellCooldown, name))
    if s then return s, d end
  end
  return nil
end

-- Paint one clicky button's swipe from whatever the server says is left.
--
-- Cleared rather than left alone when there is no cooldown: the row pool is
-- reused by whichever item scrolls into it, so a swipe belonging to the previous
-- occupant's spell would otherwise sit on top of a ready button.
local function armUseButton(b)
  if not b or not b.cd then return end
  if b.spellId then
    local start, duration = useCooldownOf(b.spellId)
    if start then
      CooldownFrame_SetTimer(b.cd, start, duration, 1)
      return
    end
  end
  CooldownFrame_SetTimer(b.cd, 0, 0, 0)
end

-- ---- state ---------------------------------------------------------------
local state = {
  -- autoopen is a MODE, not a flag: 0 off / 1 melt (destroys the gear) / 2 keep
  -- (opens the sacks and banks everything). Report #375 -- the melt used to be
  -- the only automatic option, which is why people were autoclicking instead.
  --
  -- sackHeld / sackPerTick / sackBurstMax / sackBurstCd all arrive from the
  -- server over ICSACKS. None of them is a client-side constant on purpose: the
  -- server owns the throttle and the cap, and a hardcoded copy here would go
  -- stale the first time either is retuned with `.reload config`.
  sf = { mult = 0.1, fill = 0, completions = 0, autoconsume = false, autoopen = 0,
         sackHeld = 0, sackPerTick = 25, sackBurstMax = 250, sackBurstCd = 10 },  -- soulforge status
  -- [#812] The last vault-junk forecast the server sent (ICVR). Never a
  -- client-side estimate: the client cannot see the Vault's quest reserves, the
  -- account whitelist or which rows duplicate worn gear, so every number the
  -- confirmation dialog quotes has to come from the server that will act on it.
  vr = { stacks = 0, pieces = 0, souls = 0 },
  whitelist = {},        -- current whitelist item names
  wlStaging = {},
  wlSuggest = {},        -- item-name search suggestions (server ICINAME search)
  wlSuggestStaging = {},
  equipped = {},         -- rendered rows: your equipped items that carry bonuses

  --[[ ★★ [#1227] THE ON-USE CLICK SURFACE, AND WHOSE COOLDOWN THIS IS.

       PROC_ON_USE (trigger 0) is a clicky. Nothing on the server ever fires one:
       ItemCustomization::UseProc sits complete, wired to the ICUSE verb, waiting
       for a client to send it -- and no shipped addon ever has. So an on-use
       effect pulled with a Scroll of Extraction landed in custom_item_proc, was
       listed in this panel labelled "On Use", and could never be used by anyone.
       Report #240 spent a scroll and a Staff of Disintegration on exactly that,
       and ExtractProc clears the target's existing procs first, so the trade was
       strictly negative. Eleven rows realm-wide are stuck in that state. These
       buttons are the missing half.

       ★★ THE SWIPE IS THE SERVER'S NUMBER. UseProc stamps the SOURCE spell's own
          RecoveryTime and sends it to the client, and useCooldownOf above reads it
          back -- see the long note there. THIS is not that:

       ⚠ useReadyAt/useCooldown are a DOUBLE-CLICK GUARD AND NOTHING ELSE, and
         they paint NO SWIPE. There is a round trip between the press and the
         cooldown packet, and without this a held button sends one
         CMSG_MESSAGECHAT per frame into that window. Drawing a 1.5s swipe for it
         would be actively harmful -- the button would read as ready 1.5s into a
         three-minute trinket effect and every click after that would be refused.

       Keyed by spellId, not by item: the server matches ICUSE on the spell id
       alone, so two items carrying the same on-use proc are one clicky. ]]
  useReadyAt = {},       -- spellId -> GetTime() before which another press is dropped
  useCooldown = 1.5,     -- seconds; the send guard only -- never drawn (see above)

  --[[ ★ [DE-09] Client-side pacing for "Soulbind Duplicates".

       One press is ~1,500 un-batched DB writes server-side (IC-11) against a
       measured ceiling of ~85 commits/sec -- about 17x over in one click --
       and the ICBOUNDALL reply then fires ICINV + ICSF, stacking a full
       inventory rescan on top. It was the ONLY bulk button in this file with
       no guard at all: the sack burst twenty lines up drives its own readyAt,
       and the junk render uses a server arm/confirm.

       ⚠ STALE AS WRITTEN, CORRECTED 2026-09-03. This used to say "the server
         has no limit of its own -- ICSBALL calls SoulbindAllDuplicates
         straight through". IC-13 has since put the real cap next to the
         handler, which is where the comment said it belonged: one sweep per
         account per second (_soulbindAllAt / SOULBIND_ALL_DEBOUNCE_MS) plus
         the shared _vaultSweepInFlight guard, so a hand-edited addon no
         longer gets through. IC-11 also batched the writes -- a press is
         about three commits now, not ~1,500.

         ★ This guard is KEPT anyway, and not merely as a courtesy. It is what
           stops the ICBOUNDALL reply's ICINV + ICSF follow-up storm, and it is
           what gives the player a button that visibly refuses instead of one
           that silently does nothing for a second. Defence in depth, on the
           side that can explain itself.

         ⚠ Do not read the server cap as a reason to delete this, and do not
           read this as a reason to relax the server cap. That trade has been
           made twice on this realm already.

       Kept in `state` rather than as file locals because the button and its
       confirm popup are ~2,400 lines apart and this chunk is already near
       Lua 5.1's 200-locals-per-chunk ceiling. ]]
  sbReadyAt  = 0,        -- GetTime() before which another press is refused
  sbInflight = false,    -- a burst is out; cleared by ICBOUNDALL
  sbCooldown = 30,       -- seconds between bursts

  -- [DE-16] `exItems` lived here with a descriptive comment and was never read
  -- or written: the two-column extraction picker it belonged to was replaced by
  -- the Extraction Wardrobe, which uses exStaging/exSources/exTargets.
  exStaging = {},        -- accumulates ICEXI lines until ICEXIEND
  exSources = {},        -- flattened source rows: one per (item, proc)
  exTargets = {},        -- one row per gear item (any -- with or without a proc)
  exSelSrc = nil,        -- selected source row (from exSources)
  exSelTgt = nil,        -- selected target row (from exTargets)
  -- Sockets (Scroll of Socket). Sockets are virtual: the 3.3.5a client can only draw
  -- an item's three template sockets plus the prismatic one, and this feature has no
  -- limit, so the whole socket view lives in this window instead of the item tooltip.
  sockStaging = {},      -- key "bag:slot" -> {bag,slot,entry,equipped,capacity,empty,gems={[entry]={count,active}}}
  sockItems = {},        -- committed, sorted list of the above
  sockSel = nil,         -- selected gear row
  sockGems = {},         -- gems in your bags: {entry, held}
  sockGemStaging = {},
  sockFillGem = nil,     -- gem entry the Fill button pours in
  sockScope = "Worn",    -- gear list filter: Worn / Bags / All
  sockFilter = "",       -- gear list name filter
  sockGemOffset = 0,     -- first visible gem row (the gem list is windowed, not a scrollframe)
  sockTally = { meta = 0, red = 0, yellow = 0, blue = 0 },  -- current gem colour counts
  sockScrolls = nil,     -- ICSOCKSCROLLS: spendable Scrolls of Socket, Vault included.
                         -- nil is "the server has not told us yet", never "none".
}

local function send(body)
  dbg("-> " .. body)
  SendAddonMessage(SEND_PREFIX, body, "WHISPER", UnitName("player"))
end

-- ---- soulbound-item tooltip cache ----------------------------------------
-- Keyed by CLIENT slot position ("E:<invSlot>" equipped / "B:<bag>:<slot>" bags);
-- built into sbStaging as ICITEM/ICISTAT/ICIPROC arrive, swapped in on ICINVEND.
local sbInv = {}
local sbStaging, sbCurKey = {}, nil

-- ============================ UI ==========================================
-- Lives INSIDE the Dashboard's content panel (see EmbedInto below) -- no own
-- backdrop/title/close/drag, since the Dashboard's master window already
-- provides all of that chrome. Every element that used to have a fixed pixel
-- width is anchored to both edges of its row instead, so it stretches with
-- whatever width the Dashboard window currently has; the equipped-gear list
-- additionally recomputes how many rows fit whenever its height changes.
local UI
local eqRows = {}
local EQ_ROWS_MAX, EQ_H = 20, 34
local eqVisibleRows = 6
-- [#1227] On-use clicky buttons reserved per gear row. Two is enough for anything
-- that exists; the row's name/sub strings reserve exactly this much width.
local EQ_USE_MAX = 2

-- [DE-15] `isWhitelistedName` was here: a linear scan over state.whitelist with
-- no callers anywhere in client_addons/. It was superseded by the lowercase
-- `state.wlSet` built at ICWLEND, for exactly the reason its own comment gave.
--
-- ★★★ [#1249] AND `state.wlSet` ALONE IS WRONG, which is what wlProtectedBy below
--     is for. The set answers "is this item name EXACTLY a whitelist entry". The
--     SERVER asks something else entirely:
--
--         ItemCustomization::IsWhitelisted  ->  lower.find(w) != npos
--
--     i.e. the whitelist entry is a SUBSTRING of the item name. So an account
--     with "serpent slicer" on the list has every item whose name contains that
--     phrase protected -- and the client drew no padlock on any of them, greyed
--     nothing, and let the player click Unlock expecting to spend a Scroll of
--     Extraction. The server then refused with a reason the panel did not
--     render. That is exactly report #1249.
--
-- ⚠ The DE-15 performance objection is still real -- this is asked once per
--   VISIBLE ROW on every redraw -- so the scan is memoised per item name and the
--   memo is thrown away wholesale at ICWLEND, which is the only moment the
--   answer can change. A player's whitelist is a handful of entries, so the scan
--   runs once per distinct item name per whitelist version.

-- Returns: the whitelist entry protecting `name`, and whether it matched
-- EXACTLY. nil when the item is not protected.
--
-- The distinction matters at the toggle: ICWLREM deletes a row by its stored
-- name, so "un-protect" only works on an exact entry. An item protected by a
-- broader phrase has to be un-protected by editing that phrase, and saying so
-- is far better than a button that reports success and changes nothing.
local function wlProtectedBy(name)
  if type(name) ~= "string" or name == "" then return nil end
  local lower = name:lower()

  if state.wlSet and state.wlSet[lower] then return lower, true end

  local memo = state.wlMatch
  if not memo then memo = {}; state.wlMatch = memo end

  local hit = memo[lower]
  if hit ~= nil then
    if hit == false then return nil end
    return hit, false
  end

  for _, n in ipairs(state.whitelist or {}) do
    n = tostring(n):lower()
    if n ~= "" and lower:find(n, 1, true) then
      memo[lower] = n
      return n, false
    end
  end

  memo[lower] = false
  return nil
end

--[[ ★★★ [#1249] SAME-NAMED PROCS, AND WHY A NAME IS NOT AN IDENTITY HERE.

     Spells 16401, 17511 and 18197 are ALL literally named "Poison" in
     Spell.dbc. procDisplayName resolves every one of them to the single word
     "Poison", so the Unlock list showed a row reading "already unlocked --
     Poison (On Hit)" next to a row the player could still unlock reading
     "Poison (On Hit)", and there was no way -- none, anywhere in the UI -- to
     tell which of the three they actually owned.

     The reporter had unlocked 17511 off a Serpent Slicer three days earlier.
     From his chair the panel was simply refusing to let him extract an item
     that had never been extracted.

     So: when a display name is shared by more than one spell the player can
     currently SEE, the spell id is appended. Only then -- putting "#16401"
     after every "Drain Life" would be noise on the 99% of rows that are
     unambiguous.

     ⚠ Ambiguity is judged over the collection AND the visible unlock sources
       TOGETHER, because that is the pair of lists the player is comparing. A
       name unique within either one but shared across both is precisely the case
       that produced the report. ]]
local procNameIds = {}

local function rebuildProcNames()
  local seen = {}
  local function note(id)
    local n = (procDisplayName({ spellId = id }) or ""):lower()
    if n == "" then return end
    if seen[n] == nil then seen[n] = id
    elseif seen[n] ~= id then seen[n] = false end
  end
  for _, e in ipairs(state.collection or {}) do note(e.spell) end
  for _, s in ipairs(state.exSources or {}) do note(s.spell) end
  procNameIds = seen
end

--[[ ★★ [#1278] THE BANNED-PROC HOLDER, AND WHY IT IS A FORWARD DECLARATION.

     The Extraction tab renders the disabled-effects list, and it must do so with
     the SAME filter and the SAME row painter the pop-out window uses -- two
     surfaces drawing one register from two code paths is how they drift.

     But bpVisible / bpPaintRow / bpRowTooltip are file locals declared ~1,300
     lines BELOW BuildExtractor, and in Lua a name referenced from a closure
     defined above its `local` does not bind to that local at all: it compiles to
     a read of the nil GLOBAL of the same name, forever, with no error until the
     moment it is called. The file's own header calls this trap out for UIKit.

     So the table is declared HERE and filled in down there. The closures capture
     `bpAPI` as an upvalue and read it at call time, by which point it is
     populated. Reordering the file would be a much larger and riskier edit for
     the same result.

  ⚠ Every consumer must therefore guard on `bpAPI` being non-nil -- it is nil
    for the whole of load, and would be nil permanently if the assignment below
    were ever moved or deleted. ]]
local bpAPI

-- The name to put in front of a player, disambiguated only when it has to be.
local function procLabel(spellId)
  local n = procDisplayName({ spellId = spellId }) or ("Spell #" .. tostring(spellId))
  if procNameIds[n:lower()] == false then
    return n .. " |cff808080#" .. tostring(spellId) .. "|r"
  end
  return n
end

local function BuildUI(parent)
  if UI then return UI end

  local f = CreateFrame("Frame", "UncappedSoulforgeFrame", parent or UIParent)
  f:SetPoint("TOPLEFT"); f:SetPoint("BOTTOMRIGHT")
  f:Hide()

  -- ---- forge bar ----
  local sfLabel = f:CreateFontString(nil,"OVERLAY","GameFontNormal")
  sfLabel:SetPoint("TOPLEFT", 6, -6); sfLabel:SetText("|cff9a7bffThe Soulforge|r")
  local sfLevel = f:CreateFontString(nil,"OVERLAY","GameFontHighlight")
  sfLevel:SetPoint("TOPRIGHT", -6, -6); f.sfLevel = sfLevel

  -- The border lives on its own wrapper frame, and the fill bar is inset
  -- inside it by the same amount as the border's own insets -- a StatusBar's
  -- fill texture is ARTWORK layer, which draws ABOVE a backdrop's BORDER
  -- layer, so putting the border directly on the bar let the square fill
  -- corners paint over the border's rounded corners. Keeping the fill
  -- strictly inside the border's edge instead of edge-to-edge with it fixes
  -- both the misalignment and lets the border's rounded corners show.
  local barFrame = CreateFrame("Frame", nil, f)
  barFrame:SetHeight(20); barFrame:SetPoint("TOPLEFT", 6, -24); barFrame:SetPoint("TOPRIGHT", -6, -24)
  barFrame:SetBackdrop({ bgFile="Interface\\Buttons\\WHITE8X8",
    edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", edgeSize=12,
    insets={left=3,right=3,top=3,bottom=3} })
  barFrame:SetBackdropColor(0,0,0,0.6); barFrame:SetBackdropBorderColor(0.4,0.4,0.5)

  -- A native StatusBar manages its own fill texture internally (anchors +
  -- texture-coordinate cropping), and fighting that from the outside with
  -- our own SetWidth calls is what caused the fill to vanish when shrinking
  -- and barely grow when growing -- two competing sizers each partially
  -- undoing the other. So this is a plain Frame with two textures instead:
  -- WE own the only formula that ever runs --
  --   fillWidth = barWidth (current, live) * value-percent
  -- computed fresh both when the value changes and whenever the bar's own
  -- size changes (the Dashboard window resizing).
  local bar = CreateFrame("Frame", nil, barFrame)
  bar:SetPoint("TOPLEFT", 3, -3); bar:SetPoint("BOTTOMRIGHT", -3, 3)

  local barBg = bar:CreateTexture(nil, "BACKGROUND")
  barBg:SetAllPoints(bar)
  barBg:SetTexture(0, 0, 0, 0.6)

  local barFill = bar:CreateTexture(nil, "ARTWORK")
  barFill:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
  barFill:SetVertexColor(0.55, 0.35, 0.95)
  barFill:SetPoint("TOPLEFT", bar, "TOPLEFT")
  barFill:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT")
  barFill:SetWidth(0.01)

  local barMin, barMax, barVal = 0, 1000, 0
  local function resyncFill()
    local pct = (barMax > barMin) and ((barVal - barMin) / (barMax - barMin)) or 0
    pct = math.max(0, math.min(1, pct))
    barFill:SetWidth(math.max(0.01, bar:GetWidth() * pct))
  end
  function bar:SetMinMaxValues(mn, mx) barMin, barMax = mn, mx; resyncFill() end
  function bar:GetMinMaxValues() return barMin, barMax end
  function bar:SetValue(v) barVal = v; resyncFill() end
  function bar:GetValue() return barVal end
  bar:SetScript("OnSizeChanged", resyncFill)

  bar:SetMinMaxValues(0, 1000); bar:SetValue(0)

  local barText = bar:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
  barText:SetPoint("CENTER"); f.sfBar = bar; f.sfBarText = barText

  local sfExtract = f:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
  sfExtract:SetPoint("TOPLEFT", 6, -50); f.sfExtract = sfExtract
  local sfHint = f:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
  sfHint:SetPoint("TOPLEFT", 6, -72); sfHint:SetPoint("TOPRIGHT", -6, -72); sfHint:SetJustifyH("LEFT")
  -- [#1119] "gear you're wearing" was a promise this button stopped keeping: the
  -- bulk sweep will now also feed an already-soulbound copy sitting in your bags.
  sfHint:SetText("Feed junk gear to the forge to raise the extraction rate. Soulbinding a duplicate onto the copy you're wearing -- or onto an already-soulbound copy in your bags -- extracts that share of its stats.")

  -- ---- controls ----
  local ac = CreateFrame("CheckButton", "UncappedSoulforgeAC", f, "InterfaceOptionsCheckButtonTemplate")
  ac:SetPoint("TOPLEFT", 4, -104)
  _G[ac:GetName().."Text"]:SetText("Auto-consume junk gear \226\134\146  souls + transmog (destroys it)")
  -- Ticking this only ASKS. The server arms a confirmation and replies ICACWARN,
  -- which raises the popup below; nothing is enabled until the player accepts it.
  -- Unticking is immediate. The box is put straight back to the server's value so
  -- it never shows a state the server has not agreed to -- the ICSF push that
  -- follows is the authority either way.
  ac:SetScript("OnClick", function(self)
    local want = self:GetChecked() and 1 or 0
    self:SetChecked(state.sf.autoconsume)
    send("ICAC:" .. want)
  end)
  f.acCheck = ac

  -- ---- Sacks of Mythic Treasures (report #375) ----------------------------
  --
  -- ⚠ THIS IS A MODE, NOT A SET OF FLAGS, AND THE UI HAS TO SAY SO.
  --
  -- Melting a sack and opening it are mutually exclusive fates for the same
  -- item, and one of them PERMANENTLY DESTROYS the gear inside. Independent
  -- checkboxes would let a player tick both and be told a lie about what is
  -- about to happen to a thousand sacks. So all three states are drawn at once,
  -- exactly one is ever lit, and clicking a row SETS that mode -- clicking the
  -- lit one is a no-op rather than "off", because a mode always has a value.
  --
  -- The destructive option carries its consequence in the label, in red, not in
  -- a tooltip: the whole of #375 is a player who could not tell the difference,
  -- and a tooltip is not shown to someone who already thinks they know what the
  -- box does.
  --
  -- The SERVER is the authority on which one is lit. Every click optimistically
  -- redraws from `state.sf.autoopen`, which is only ever written by the server's
  -- own ICSF push, so a refused or clamped change corrects itself.
  local sackHdr = f:CreateFontString(nil,"OVERLAY","GameFontNormal")
  sackHdr:SetPoint("TOPLEFT", 6, -130)
  sackHdr:SetText("|cff40c0f0Treasure sacks|r")

  local sackCount = f:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
  sackCount:SetPoint("TOPRIGHT", -8, -130); sackCount:SetJustifyH("RIGHT")
  f.sackCount = sackCount

  -- One row of the mode picker. `mode` is the value sent to the server.
  --
  -- ⚠ LABELS ARE KEPT SHORT DELIBERATELY. The Dashboard's content panel is
  -- resizable down to 320px and these FontStrings do not wrap, so a long label
  -- runs off the edge at the minimum width -- and the one that would be clipped
  -- is the one carrying "destroys". The consequence therefore lives in the
  -- LABEL, short and in red; the fuller explanation lives in the tooltip, which
  -- has room. The existing auto-consume row is the length ceiling here.
  local function modeRow(name, mode, y, label, tipTitle, tipBody, r, g, b)
    local cb = CreateFrame("CheckButton", name, f, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", 4, y)
    cb.mode = mode
    cb.label = _G[cb:GetName().."Text"]
    cb.labelOn = label
    cb.label:SetText(label)
    cb:SetScript("OnClick", function(self)
      -- ★ THE GATE IS ON THE SEND, NOT ON THE WIDGET. Disable() is how the row
      --   LOOKS unavailable; this is what makes it BE unavailable. A disabled
      --   CheckButton still runs OnClick if anything calls Click() on it, and
      --   the cost of being wrong here is a melted stack of gear, so the refusal
      --   lives next to the thing that would do the damage.
      if self.mode == 2 and not serverKeepOk then
        self:SetChecked(false)
        return
      end

      -- Always SET this mode. Unticking the live one would have to mean
      -- something, and every candidate meaning ("off"? "the other one"?) is a
      -- guess we would be making on the player's behalf about an irreversible
      -- setting. The "Leave them alone" row is the off switch, and it is right
      -- there.
      send("ICAO:" .. self.mode)
      self:SetChecked(state.sf.autoopen == self.mode)
    end)
    cb:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      if self.mode == 2 and not serverKeepOk then
        GameTooltip:AddLine(tipTitle)
        GameTooltip:AddLine("Not available yet \226\128\148 this realm is still finishing its update. "
          .. "It will switch itself on within a few minutes; nothing to do but wait.", 1, 0.82, 0, true)
      else
        GameTooltip:AddLine(tipTitle)
        GameTooltip:AddLine(tipBody, r or 1, g or 1, b or 1, true)
      end
      GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return cb
  end

  f.sackOff = modeRow("UncappedSoulforgeSackOff", 0, -150,
    "Leave them alone",
    "Leave them alone",
    "Every kind of treasure sack piles up in your bags and nothing touches them. Open them by hand whenever you like.")

  f.sackKeep = modeRow("UncappedSoulforgeSackKeep", 2, -172,
    "|cff1eff00Open them and keep everything|r",
    "Open them and keep everything",
    "EVERY treasure sack you carry -- Mythic, World, Legendary, Honor, Arena and Quest -- opens by itself, a few every five seconds. The gear, reagents and forge fuel inside go to your bags, and to your Vault once your bags are full. Nothing is destroyed.",
    0.6, 1, 0.6)
  -- The greyed-out wording for the capability gate. A separate STRING rather
  -- than SetTextColor, because the live label carries its own "|cff1eff00"
  -- escape and an embedded colour code wins over the widget's text colour.
  f.sackKeep.labelOff = "|cff808080Open them and keep everything|r |cffffd100(updating\226\128\166)|r"

  f.sackMelt = modeRow("UncappedSoulforgeSackMelt", 1, -194,
    "Melt them for souls \226\128\148 |cffff2020destroys the gear|r",
    "Melt them for souls",
    "EVERY treasure sack you carry is rendered straight down into souls, appearances and forge fuel -- Mythic, World, Legendary, Honor, Arena and Quest alike. You still get the appearance of what was inside, but THE GEAR ITSELF IS DESTROYED and never reaches your bags or your Vault. That includes the guaranteed legendary in a Sack of Legendary Treasure.",
    1, 0.4, 0.4)

  -- The "do it now" button. Everything it says -- the cap, the cooldown -- comes
  -- from the server over ICSACKS, so it can never advertise a number the server
  -- would refuse. It drives its own cooldown countdown off a local deadline
  -- rather than waiting for pushes, because with the mode OFF there are no
  -- periodic pushes to drive it.
  local openBtn = KitButton(f, "", 150, 22)
   openBtn:SetPoint("TOPLEFT", 8, -218)
  openBtn:SetScript("OnClick", function(self)
    if self.readyAt and GetTime() < self.readyAt then return end
    send("ICSACKOPEN")
  end)
  openBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Open sacks now")
    GameTooltip:AddLine(string.format("Up to %d at a time, once every %d seconds.",
      state.sf.sackBurstMax or 250, state.sf.sackBurstCd or 10), 1, 1, 1, true)
    GameTooltip:AddLine("Nothing is destroyed \226\128\148 everything inside goes to your bags, then your Vault.", 0.6, 1, 0.6, true)
    GameTooltip:Show()
  end)
  openBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- Throttled to ~4Hz: this only ever redraws a label.
  openBtn:SetScript("OnUpdate", function(self, elapsed)
    self.acc = (self.acc or 0) + elapsed
    if self.acc < 0.25 then return end
    self.acc = 0
    if UI and UI.RefreshSackButton then UI:RefreshSackButton() end
  end)
  f.sackOpenBtn = openBtn

  local sackHint = f:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
  sackHint:SetPoint("TOPLEFT", 164, -222); sackHint:SetPoint("TOPRIGHT", -6, -222)
  sackHint:SetJustifyH("LEFT")
  f.sackHint = sackHint

  local sbBtn = KitButton(f, "", 170, 24)
   sbBtn:SetPoint("TOPLEFT", 6, -250); sbBtn:SetText("Soulbind Duplicates")
  -- [DE-09] Refuse at the BUTTON as well as at the popup, so the confirm never
  -- even appears during a cooldown -- a dialog that answers "no" is worse than
  -- one that does not open. The arm itself lives in the popup's OnAccept,
  -- because that is the only thing that actually sends.
  sbBtn:SetScript("OnClick", function()
    if state.sbInflight then
      msg("Still soulbinding the last batch \226\128\148 give it a moment.")
      return
    end
    local left = (state.sbReadyAt or 0) - (GetTime() or 0)
    if left > 0 then
      msg(string.format("Soulbind Duplicates is ready again in %d second%s.",
        math.ceil(left), math.ceil(left) == 1 and "" or "s"))
      return
    end
    StaticPopup_Show("UNCAPPED_SF_SOULBIND_ALL")
  end)

  local wlBtn = KitButton(f, "", 170, 24)
   wlBtn:SetPoint("LEFT", sbBtn, "RIGHT", 10, 0); wlBtn:SetText("Whitelist\226\128\166")
  wlBtn:SetScript("OnClick", function() if UI and UI.OpenWhitelist then UI:OpenWhitelist() end end)

  -- ---- second button row --------------------------------------------------
  -- [#424] Sockets and [#688] Banned Procs.
  --
  -- ★ WHY BUTTONS HERE RATHER THAN NEW DASHBOARD TABS. The nav column is FULL:
  --   UncappedDashboardConfig.lua spells out that at 16 tabs the window's zoom
  --   ceiling collapses to ~1.01, i.e. a sixteenth tab ends zooming for everyone,
  --   and 17 clips buttons off the bottom. There are 15.
  --
  -- ★ AND WHY POPUPS RATHER THAN EMBEDDED VIEWS. This addon's own rule, stated at
  --   its dashboard-embedding block: "The Extractor, Socket, and Whitelist
  --   windows stay separate popups -- they're triggered by a specific action
  --   rather than being 'the Soul Forge screen' itself." Both of these are that
  --   shape. What #424 actually reported is that the Socket window was reachable
  --   ONLY through /socket, a command that appears in no help text -- so it had
  --   no entry point in the Dashboard at all. This is that entry point.
  --
  -- Same 170-wide geometry as the row above, so the panel's 374 min content width
  -- (see SF.UI.GetMinWidth) still holds and nothing overflows.
  local sockBtn = KitButton(f, "", 170, 24)
   sockBtn:SetPoint("TOPLEFT", 6, -278); sockBtn:SetText("Sockets\226\128\166")
  sockBtn:SetScript("OnClick", function() if UI and UI.OpenSockets then UI:OpenSockets() end end)

  local bpBtn = KitButton(f, "", 170, 24)
   bpBtn:SetPoint("LEFT", sockBtn, "RIGHT", 10, 0); bpBtn:SetText("Banned Procs\226\128\166")
  bpBtn:SetScript("OnClick", function() if UI and UI.OpenBannedProcs then UI:OpenBannedProcs() end end)

  --[[ ---- third button row: [#812] render the Vault's junk gear -------------

    THE REQUEST: "render down junk grey items and junk white items in vault via
    bulk processing to turn it into soul forge food".

    ★ WHY IT LIVES HERE AND NOT IN THE FORGE'S "Bulk processing" TAB, WHICH IS
      WHAT THE REPORTER CALLED IT.

      That tab is a CRAFTING pipeline: mill / prospect / disenchant / render,
      four spells that consume a stack and produce another ITEM (junk meat ->
      Rendered Tallow). It reads the Vault through SnapshotCommodities, which by
      definition returns only random_prop_id 0 rows -- so half of grey and white
      GEAR, the half that rolled a suffix, is invisible to it. And "souls" is not
      an item it could ever produce.

      Junk gear -> souls is the Soulforge's own operation. It already has the
      whitelist that protects a name from it, the quest reserves that hold turn-
      ins back, and the consent gate that stands in front of every destruction on
      this realm. Rebuilding any of those beside the milling UI would have been a
      second, subtly different set of rules for the same act. The Forge tab gets a
      pointer to this button instead (see UncappedForge.lua).

    ⚠ TWO PRESSES, ALWAYS. The first asks and shows the forecast; the SERVER arms
      a 60s confirmation and the popup below is the only thing that answers it.
      That is the same arm-then-answer path Auto-consume uses, deliberately reused
      rather than reinvented -- one consent mechanism, one place it can be wrong.
  ]]
  local renderBtn = KitButton(f, "", 170, 24)
   renderBtn:SetPoint("TOPLEFT", 6, -306); renderBtn:SetText("Render junk gear\226\128\166")
  renderBtn:SetScript("OnClick", function()
    -- Always a fresh ASK. The forecast in state.vr is only ever a label; nothing
    -- here can act on a stale one, because the confirm the popup sends is
    -- refused by the server unless its own arm is still live.
    renderWaitSince = GetTime()
    if UI and UI.RefreshRender then UI:RefreshRender() end
    send("ICVRENDER")
  end)
  renderBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Render junk gear")
    GameTooltip:AddLine("Turns every |cffffffffgrey|r and |cffffffffwhite|r weapon and armour piece in your "
      .. "Vault into souls, in one go. Shows you the count first and asks before it does anything.",
      1, 1, 1, true)
    GameTooltip:AddLine(" ")
    -- ⚠ THE GOLD TRADE, SAID OUT LOUD. Greys are the quality the realm otherwise
    --   auto-SELLS for gold as you loot them; anything sitting in the Vault got
    --   past that, but a player is still choosing souls over a vendor price here
    --   and should be told so before, not after.
    GameTooltip:AddLine("Greys would be worth a little gold at a vendor instead. This spends them on the "
      .. "forge, not the merchant.", 1, 0.82, 0, true)
    GameTooltip:AddLine("Never touched: quest turn-ins, anything on your |cffffffffWhitelist|r, and exact "
      .. "copies of the gear you are wearing.", 0.6, 1, 0.6, true)
    GameTooltip:AddLine("Green and better gear is left alone -- that is what Auto-consume is for.",
      0.6, 0.6, 0.6, true)
    GameTooltip:Show()
  end)
  renderBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- Throttled to ~4Hz, exactly like the sack burst button: this only ever
  -- redraws a label and times out a silent server.
  renderBtn:SetScript("OnUpdate", function(self, elapsed)
    self.acc = (self.acc or 0) + elapsed
    if self.acc < 0.25 then return end
    self.acc = 0
    if UI and UI.RefreshRender then UI:RefreshRender() end
  end)
  f.renderBtn = renderBtn

  local renderHint = f:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
  renderHint:SetPoint("TOPLEFT", 184, -310); renderHint:SetPoint("TOPRIGHT", -6, -310)
  renderHint:SetJustifyH("LEFT")
  f.renderHint = renderHint

  -- ---- your soulbound gear ----
  -- Everything below here moved down 28 to make room for the second button row,
  -- and a further 28 for the third ([#812]).
  -- The gear list is anchored BOTTOMRIGHT and recomputes how many rows fit on
  -- OnSizeChanged, so it simply shows fewer rows rather than overflowing.
  local eqHdr = f:CreateFontString(nil,"OVERLAY","GameFontNormal")
  eqHdr:SetPoint("TOPLEFT", 6, -340); eqHdr:SetText("|cff40c0f0Your soulbound gear|r")
  local dLine = f:CreateTexture(nil,"ARTWORK"); dLine:SetTexture("Interface\\Buttons\\WHITE8X8")
  dLine:SetGradientAlpha("HORIZONTAL", 0.25,0.60,0.90,0.6, 0.25,0.60,0.90,0.0)
  dLine:SetHeight(2); dLine:SetPoint("TOPLEFT", 6, -356); dLine:SetPoint("TOPRIGHT", -6, -356)

  -- Stretches to fill whatever's left of the panel below the divider; a pool
  -- of EQ_ROWS_MAX row frames is pre-built, but only however many actually
  -- fit (recomputed on OnSizeChanged, see below) are ever shown at once.
  local scroll = CreateFrame("ScrollFrame", "UncappedSoulforgeEqScroll", f, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 8, -364); scroll:SetPoint("BOTTOMRIGHT", -23, 8)
  scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, EQ_H, function() if UI then UI:RefreshEquipped() end end)
  end)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local sb = _G["UncappedSoulforgeEqScrollScrollBar"]; if sb then sb:SetValue(sb:GetValue() - delta*EQ_H) end
  end)
  scroll:SetScript("OnSizeChanged", function(self, w, h)
    local rows = math.max(1, math.floor(h / EQ_H))
    if rows ~= eqVisibleRows then
      eqVisibleRows = rows
      if UI then UI:RefreshEquipped() end
    end
  end)
  f.eqScroll = scroll

  for i = 1, EQ_ROWS_MAX do
    local r = CreateFrame("Frame", nil, f); r:SetHeight(EQ_H-2)
    r:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(i-1)*EQ_H)
    r:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 0, -(i-1)*EQ_H)
    r.icon = r:CreateTexture(nil,"ARTWORK"); r.icon:SetSize(28,28)
    r.icon:SetPoint("LEFT",2,0); r.icon:SetTexCoord(0.08,0.92,0.08,0.92)
    r.name = r:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    -- ⚠ The right inset is EQ_USE_MAX * 26 + 6, not 4: the on-use buttons below
    --   overlay this strip, and a long item name would otherwise run underneath
    --   them. Reserved unconditionally rather than re-anchored per refresh --
    --   this list redraws on every ICINVEND and every scroll tick.
    r.name:SetPoint("TOPLEFT",36,-1); r.name:SetPoint("TOPRIGHT",-58,-1); r.name:SetJustifyH("LEFT")
    r.sub = r:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
    r.sub:SetPoint("TOPLEFT",36,-15); r.sub:SetPoint("TOPRIGHT",-58,-15); r.sub:SetJustifyH("LEFT")

    --[[ [#1227] ONE BUTTON PER ON-USE PROC ON THIS PIECE.

         ★ ON THE EQUIPPED LIST AND NOWHERE ELSE, because that is precisely the
           set the server will accept. UseProc reads _equippedProcs -- the live
           cache built when a piece is put on -- so a clicky sitting on a spare in
           your bags cannot be fired, and offering a button for it would be a
           control that always answers "not_equipped".

         Built as a fixed pool of EQ_USE_MAX per row, like every other list in this
         file, so scrolling can never leak frames. The pool is small on purpose: an
         item with four separate on-use effects does not exist, and the ones past
         the pool are still readable in the tooltip. ]]
    r.useBtns = {}
    for k = 1, EQ_USE_MAX do
      local b = CreateFrame("Button", nil, r)
      b:SetWidth(24); b:SetHeight(24)
      b:SetPoint("RIGHT", r, "RIGHT", -6 - (k - 1) * 26, 0)
      b:SetNormalTexture(QUESTION)
      b:GetNormalTexture():SetTexCoord(0.08, 0.92, 0.08, 0.92)
      b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
      b:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
      -- A purple ring, so it reads as "a Soulforge power" rather than as an
      -- ordinary bag icon that happened to land in the list.
      local ring = b:CreateTexture(nil, "OVERLAY")
      ring:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
      ring:SetBlendMode("ADD")
      ring:SetPoint("CENTER"); ring:SetWidth(44); ring:SetHeight(44)
      ring:SetVertexColor(0.62, 0.38, 1)
      -- The swipe. See state.useReadyAt: this is the ADDON's throttle, not a
      -- server cooldown -- the server has none for ICUSE.
      b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
      b.cd:SetAllPoints(b)
      b:SetScript("OnClick", function(self)
        local sid = self.spellId
        if not sid then return end
        local now = GetTime() or 0
        -- Send guard only. NOT drawn: the swipe belongs to the server's cooldown,
        -- which lands a round trip later on SPELL_UPDATE_COOLDOWN.
        if now < (state.useReadyAt[sid] or 0) then return end
        state.useReadyAt[sid] = now + state.useCooldown
        send("ICUSE:" .. sid)
        -- Repaint from whatever the client already knows. Usually nothing yet on
        -- the first press, and the cooldown packet arrives moments later.
        armUseButton(self)
      end)
      b:SetScript("OnEnter", function(self)
        local p = self.proc
        if not p then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(procDisplayName(p) or "?", 0.75, 0.5, 0.94)
        GameTooltip:AddLine(triggerLabel(p.trigger) .. " \226\128\148 " .. procMechanic(p),
          0.8, 0.8, 0.8, true)
        local desc = fixStackCount(spellDescription(p.spellId), p.stackCap)
        local scaled = scaleDescription(desc, p.bases or {}, (p.mag or 100) / 100) or desc
        if scaled then GameTooltip:AddLine(scaled, 0.62, 0.62, 0.72, true) end
        GameTooltip:AddLine(" ")

        --[[ [#1227] The cooldown, in words as well as in the swipe.

             It is the SOURCE spell's own RecoveryTime -- an extracted clicky fires
             exactly as often as the item it was pulled from -- and a player looking
             at a greyed button wants the number, not just the wedge. Read from the
             same place the swipe is, so the two can never disagree. ]]
        local cdStart, cdDur = useCooldownOf(p.spellId)
        local left = cdStart and (cdStart + cdDur - (GetTime() or 0)) or 0
        if left > 0 then
          local mins = math.floor(left / 60)
          GameTooltip:AddLine(mins > 0
            and string.format("On cooldown \226\128\148 %dm %ds left.", mins, math.floor(left % 60))
            or string.format("On cooldown \226\128\148 %ds left.", math.ceil(left)),
            1, 0.5, 0.4, true)
        else
          GameTooltip:AddLine("Click to fire it. It hits your current target.", 0.6, 1, 0.6, true)
        end

        -- Said out loud, because the alternative is a player concluding the button
        -- is broken when a harmful effect with nothing to hit refuses politely.
        GameTooltip:AddLine("A harmful effect needs an enemy target; a helpful one lands on you.",
          0.6, 0.6, 0.7, true)
        GameTooltip:Show()
      end)
      b:SetScript("OnLeave", function() GameTooltip:Hide() end)
      b:Hide()
      r.useBtns[k] = b
    end

    eqRows[i] = r; r:Hide()
  end
  local eqEmpty = f:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
  eqEmpty:SetPoint("TOP", scroll, "TOP", 0, -30); eqEmpty:SetPoint("LEFT", scroll, "LEFT", 20, 0)
  eqEmpty:SetPoint("RIGHT", scroll, "RIGHT", -20, 0)
  -- [#1119] Same correction as the hint above: the receiving copy is the worn one,
  -- or an already-soulbound one in your bags.
  eqEmpty:SetText("No soulbound bonuses yet. Soulbind duplicates onto the copy you're wearing, or onto an already-soulbound copy in your bags.")
  f.eqEmpty = eqEmpty

  -- ---- ding flash ----
  local flash = f:CreateTexture(nil, "OVERLAY")
  flash:SetAllPoints(f); flash:SetTexture(1,1,1); flash:SetBlendMode("ADD"); flash:SetAlpha(0)
  f.flash = flash
  local flashDrv = CreateFrame("Frame"); flashDrv:Hide()
  local flashT = 0
  flashDrv:SetScript("OnUpdate", function(self, e)
    flashT = flashT - e
    if flashT <= 0 then flash:SetAlpha(0); self:Hide(); return end
    flash:SetVertexColor(0.7,0.5,1); flash:SetAlpha(math.min(0.5, flashT))
  end)
  function f:Ding()
    flashT = 0.6; flashDrv:Show(); PlaySoundFile(SND_SEAL)
  end

  UI = f
  return f
end

-- ---- methods -------------------------------------------------------------
local function attachMethods()
  if UI.RefreshForge then return end

  function UI:RefreshForge()
    local sf = state.sf
    self.sfLevel:SetText("Level " .. sf.completions)
    self.sfBar:SetValue(math.max(0, math.min(1000, sf.fill * 10)))
    self.sfBarText:SetText(string.format("%.1f%% to Level %d", sf.fill, sf.completions + 1))
    self.sfExtract:SetText(string.format("Extraction: |cff9CC243+%.2f%%|r of stats per soulbind", sf.mult))
    self.acCheck:SetChecked(sf.autoconsume)
    self:RefreshSacks()
    self:RefreshRender()
  end

  -- [#812] The junk-render button's label and its one line of hint.
  --
  -- Driven from state.vr, which ONLY the server writes. There is deliberately no
  -- client-side count here: the client can see its own bags, but the Vault's
  -- quest reserves, the account whitelist and "is this a copy of what I'm
  -- wearing" are all server-side, so any number this addon computed for itself
  -- would be a different number from the one that is about to be destroyed.
  function UI:RefreshRender()
    if not self.renderBtn then return end

    -- A press in flight. Say it, and time it out into an explanation rather than
    -- leaving a button that looks broken (see renderWaitSince).
    if renderWaitSince then
      if (GetTime() - renderWaitSince) < RENDER_WAIT_TIMEOUT then
        self.renderBtn:SetText("Checking\226\128\166")
        self.renderHint:SetText("|cff808080Looking through your Vault\226\128\166|r")
        return
      end
      -- ⚠ Cleared and RETURNED from in the same breath. Falling through to the
      --   forecast below would immediately overwrite this sentence with the stale
      --   count, which is precisely the state the silence means we cannot trust.
      renderWaitSince = nil
      self.renderBtn:SetText("Render junk gear\226\128\166")
      self.renderHint:SetText("|cffffd100This realm is still finishing its update \226\128\148 try again "
        .. "in a few minutes.|r")
      return
    end

    self.renderBtn:SetText("Render junk gear\226\128\166")

    local vr = state.vr
    if (vr.stacks or 0) > 0 then
      self.renderHint:SetText(string.format(
        "|cff808080%s grey/white piece(s) in your Vault \226\128\148 %s souls.|r",
        groupDigits(vr.pieces), groupDigits(vr.souls)))
    else
      self.renderHint:SetText("|cff808080Grey and white gear only. Nothing else in the Vault is touched.|r")
    end
  end

  -- Everything in the sack block. Split out because ICSACKS arrives on its own
  -- and must be able to redraw the count without touching the forge bar.
  function UI:RefreshSacks()
    -- `UI` IS the Soulforge frame (see `UI = f` in the builder), so the widgets
    -- hang off `self` directly, exactly as RefreshForge reads self.acCheck.
    local sf = state.sf
    if not self.sackOff then return end

    self.sackOff:SetChecked(sf.autoopen == 0)
    self.sackKeep:SetChecked(sf.autoopen == 2)
    self.sackMelt:SetChecked(sf.autoopen == 1)

    -- Capability gate. See serverKeepOk at the top of the file: until this
    -- server has proved it understands mode 2, KEEP is drawn as unavailable and
    -- the click handler refuses to send it. Off and melt are untouched -- both
    -- predate this release and are safe against either server.
    if serverKeepOk then
      self.sackKeep:Enable()
      self.sackKeep.label:SetText(self.sackKeep.labelOn)
    else
      self.sackKeep:Disable()
      self.sackKeep.label:SetText(self.sackKeep.labelOff)
    end

    local held = sf.sackHeld or 0
    if held > 0 then
      self.sackCount:SetText(string.format("|cffffffff%s|r held", groupDigits(held)))
    else
      self.sackCount:SetText("|cff9d9d9dnone in your bags|r")
    end

    -- Say what the current mode is actually DOING, in the present tense, so a
    -- background sweep is visibly on rather than something you have to trust.
    if sf.autoopen == 2 then
      if held > 0 then
        self.sackHint:SetText(string.format("|cff1eff00Opening|r about %d every 5 seconds.", sf.sackPerTick or 25))
      else
        self.sackHint:SetText("|cff1eff00On.|r New sacks will open as they arrive.")
      end
    elseif sf.autoopen == 1 then
      self.sackHint:SetText("|cffff2020Melting.|r You are not keeping the gear.")
    else
      self.sackHint:SetText("")
    end

    self:RefreshSackButton()
  end

  -- Label + enabled state of "Open now". Called on a ticker as well as on
  -- pushes, so the countdown runs even with the mode off (no periodic pushes).
  function UI:RefreshSackButton()
    local sf = state.sf
    if not self.sackOpenBtn then return end
    local btn = self.sackOpenBtn

    local left = btn.readyAt and math.ceil(btn.readyAt - GetTime()) or 0
    if left > 0 then
      btn:SetText(string.format("Open now (%ds)", left))
      btn:Disable()
      return
    end

    btn.readyAt = nil
    local held, cap = sf.sackHeld or 0, sf.sackBurstMax or 250
    if held <= 0 then
      btn:SetText("Open now")
      btn:Disable()
      return
    end

    -- Name the real number, not the cap: "Open 250 now" in front of a player
    -- holding 40 is a promise the server will not keep.
    btn:SetText(string.format("Open %d now", math.min(held, cap)))
    btn:Enable()
  end

  -- Build the "your soulbound gear" list from the equipped (E:) tooltip cache.
  local INV_NAMES = {
    [1]="Head",[2]="Neck",[3]="Shoulder",[5]="Chest",[6]="Waist",[7]="Legs",[8]="Feet",
    [9]="Wrist",[10]="Hands",[11]="Ring",[12]="Ring",[13]="Trinket",[14]="Trinket",
    [15]="Back",[16]="Main Hand",[17]="Off Hand",[18]="Ranged",
  }
  function UI:RefreshEquipped()
    local list = {}
    for key, e in pairs(sbInv) do
      local slot = key:match("^E:(%d+)$")
      if slot then
        slot = tonumber(slot)
        local link = GetInventoryItemLink("player", slot)
        local name = link and GetItemInfo(link) or (INV_NAMES[slot] or ("Slot " .. slot))
        local tex = GetInventoryItemTexture("player", slot)
        -- [#1227] `procs` is carried through so the row can offer a button for each
        -- PROC_ON_USE (trigger 0) entry. The counts below stay as they were.
        list[#list+1] = { slot = slot, name = name, tex = tex,
          nStats = #e.stats, nProcs = #e.procs, procs = e.procs }
      end
    end
    table.sort(list, function(a, b) return a.slot < b.slot end)
    state.equipped = list

    FauxScrollFrame_Update(self.eqScroll, #list, eqVisibleRows, EQ_H)
    if #list == 0 then self.eqEmpty:Show() else self.eqEmpty:Hide() end
    local offset = FauxScrollFrame_GetOffset(self.eqScroll)
    for i = 1, EQ_ROWS_MAX do
      local r = eqRows[i]; local e = (i <= eqVisibleRows) and list[i + offset] or nil
      if e then
        r.icon:SetTexture(e.tex or QUESTION)
        r.name:SetText(e.name)
        r.sub:SetText(string.format("|cff20ff20%d stat%s|r, |cffc080f0%d proc%s|r",
          e.nStats, e.nStats == 1 and "" or "s", e.nProcs, e.nProcs == 1 and "" or "s"))

        --[[ [#1227] Paint the on-use buttons for this piece.

             Nothing is cached across refreshes: the row pool is reused by whichever
             item scrolls into it, so a stale spellId left on a button would fire the
             PREVIOUS row's clicky. Every button is either re-pointed at a proc here
             or has its spellId cleared and is hidden. ]]
        local nUse = 0
        for _, p in ipairs(e.procs or {}) do
          if p.trigger == 0 and nUse < EQ_USE_MAX then
            nUse = nUse + 1
            local b = r.useBtns[nUse]
            b.spellId, b.proc = p.spellId, p
            local _, _, icon = GetSpellInfo(p.spellId)
            b:SetNormalTexture(icon or QUESTION)
            b:GetNormalTexture():SetTexCoord(0.08, 0.92, 0.08, 0.92)
            -- Re-arm from the SERVER's cooldown rather than leaving it blank: a
            -- scroll or an ICINVEND redraw part-way through a three-minute clicky
            -- would otherwise show a ready-looking button that is refused.
            armUseButton(b)
            b:Show()
          end
        end
        for k = nUse + 1, EQ_USE_MAX do
          local b = r.useBtns[k]
          b.spellId, b.proc = nil, nil
          b:Hide()
        end

        r:Show()
      else
        r:Hide()
      end
    end
  end

  function UI:Refresh()
    self:RefreshForge()
    self:RefreshEquipped()
  end
end

-- ============================ whitelist manager ===========================
local WLM
local wlRows, sugRows = {}, {}
local WL_ROWS, WL_H = 6, 24
local SUG_ROWS, SUG_H = 6, 22

--[[ ★★ [DE-04] THE WHITELIST SEARCH IS THE MOST EXPENSIVE KEYSTROKE ON THE REALM.

     `send("ICISEARCH:...")` is not a local filter. The server answers it with a
     leading-wildcard LIKE over the whole of `item_template`, and CMSG_MESSAGECHAT
     is PROCESS_THREADUNSAFE -- so that scan runs in World::UpdateSessions, on the
     MAIN WORLD THREAD. It does not stall one map, it stalls the world tick, for
     everybody, once per character. Typing "frostweave cloth" was fifteen of them.

     Three things pace it now, in this order:

       1. DEBOUNCE. Typing accumulates into wlSearch.pending and only the settled
          query goes out, WL_SEARCH_DEBOUNCE seconds after the last keypress.
       2. ONE IN FLIGHT. A second request is never sent while the first is
          unanswered. Replies carry no query, so two overlapping bursts of ICINAME
          lines interleave in wlSuggestStaging and the first ICINAMEEND commits a
          MIXTURE of both result sets. Serialising removes that outright, without
          changing the wire format.
       3. NO REPEATS. Re-sending the query already on screen buys nothing.

     ⚠ wlSearch.sentAt is a TIMESTAMP, not a boolean, and that is the whole point.
       A boolean in-flight flag that a lost reply never clears would leave the box
       permanently dead -- the exact failure the Vault's item-cache warmer already
       had and already fixed (see `queried` in UncappedVault.lua). If no answer
       arrives within WL_SEARCH_TIMEOUT the next query goes anyway.

     ⚠ THE SERVER HALF IS NOT OPTIONAL AND IT IS NOT HERE. This addon is
       player-editable Lua; an out-of-date client keeps typing at the old rate
       until it updates and a hand-edited one never will. The limit that actually
       protects the realm is the per-player coalescing throttle in
       item_customization_playerscript.cpp, and making the query itself cheap is
       IC-12. This half removes ~90% of the calls. It does not make one safe. ]]
local WL_SEARCH_DEBOUNCE = 0.30   -- quiet time before the settled query goes out
local WL_SEARCH_TIMEOUT  = 3.0    -- stop waiting on a reply after this
-- One table rather than six file-scope locals: this chunk is long and Lua 5.1
-- allows only 200 locals per chunk.
local wlSearch = { timer = nil, wait = nil, pending = nil, inflight = nil, sentAt = 0, last = nil }

-- Cancels anything queued or awaited, and puts the hint line back. Called when the
-- box drops below two characters, when the query is committed with Add/Enter, when
-- the window is opened, and when it is closed -- a pending send firing into a box
-- the player has finished with is a free full-table scan for nobody.
local function wlSearchReset()
  wlSearch.wait, wlSearch.pending = nil, nil
  wlSearch.inflight, wlSearch.last = nil, nil
  wlSearch.sentAt = 0
  if wlSearch.timer then wlSearch.timer:Hide() end
  if WLM and WLM.sEmpty then WLM.sEmpty:SetText("Type at least 2 letters to search all items.") end
end

-- Puts the settled query on the wire, or holds it if one is still unanswered.
-- File-scope because both the debounce ticker and the ICINAMEEND handler drive it,
-- and those live at opposite ends of this file.
local function wlSearchFlush()
  local q = wlSearch.pending
  if not q or #q < 2 then return end

  if wlSearch.inflight then
    local age = (GetTime() or 0) - (wlSearch.sentAt or 0)
    if age < WL_SEARCH_TIMEOUT then return end   -- still waiting; ICINAMEEND calls us back
    wlSearch.inflight = nil                      -- timed out; that reply is not coming
  end

  if q == wlSearch.last then wlSearch.pending = nil; return end

  wlSearch.pending  = nil
  wlSearch.last     = q
  wlSearch.inflight = q
  wlSearch.sentAt   = GetTime() or 0
  send("ICISEARCH:" .. q)
end

-- Called from OnLine when ICINAMEEND lands: the wire is free, so a query typed
-- while we were waiting can go out now.
local function wlSearchAnswered()
  wlSearch.inflight = nil
  if WLM and WLM.sEmpty then
    WLM.sEmpty:SetText(wlSearch.pending and "Searching..." or "No items match that name.")
  end
  if wlSearch.pending then wlSearchFlush() end
end

local function BuildWhitelist()
  if WLM then return WLM end
  local f = CreateFrame("Frame", "UncappedSoulforgeWL", UIParent)
  f:SetSize(340, 476); f:SetPoint("CENTER", 250, 0); f:SetFrameStrata("DIALOG")
  f:SetBackdrop({ bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border", edgeSize=32,
    insets={left=11,right=12,top=12,bottom=11} })
  f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetClampedToScreen(true); f:Hide()
  -- [DE-04] Closing the window abandons whatever was queued or awaited.
  f:SetScript("OnHide", wlSearchReset)
  -- Player window zoom. This pop-out parents to UIParent, not to the Dashboard
  -- window that opens it, so it inherits nothing and has to register itself.
  -- (Anything parented INTO the Dashboard must NOT -- SetScale compounds.)
  if UncappedScale_Register then UncappedScale_Register(f, { group = "dashboard" }) end
  -- ⚠ Escape closes it. This was the ONLY one of SoulForge's four pop-outs
  --   without it (the Extractor, Socket and Banned Procs windows all had it) --
  --   a UI audit found the omission. A modal-looking window you cannot Escape
  --   out of reads as stuck.
  tinsert(UISpecialFrames, "UncappedSoulforgeWL")

  local title = f:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
  title:SetPoint("TOP",0,-16); title:SetText("Whitelist")
  local sub = f:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
  sub:SetPoint("TOP",title,"BOTTOM",0,-2); sub:SetWidth(300)
  sub:SetText("Items whose name contains one of these are never auto-consumed.")
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT",-6,-6)

  -- search box (searches ALL items server-side, once typing settles -- see the
  -- DE-04 note above the whitelist manager for why this is not per-keystroke)
  local box = CreateFrame("EditBox", "UncappedSoulforgeWLBox", f, "InputBoxTemplate")
  box:SetPoint("TOPLEFT", 22, -54); box:SetSize(230, 20); box:SetAutoFocus(false)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  local add = KitButton(f, "", 56, 22)
   add:SetPoint("LEFT", box, "RIGHT", 6, 0); add:SetText("Add")
  local function doAdd()
    local t = box:GetText()
    if t and t ~= "" then
      wlSearchReset()   -- the query is committed; nothing queued for it is wanted
      send("ICWLADD:" .. t); box:SetText(""); state.wlSuggest = {}; if WLM then WLM:UpdateSuggest() end
    end
  end
  add:SetScript("OnClick", doAdd)
  box:SetScript("OnEnterPressed", doAdd)

  -- The debounce ticker. Hidden while idle, so it costs nothing per frame when
  -- nobody is typing -- the same shape as invTimer further down this file.
  wlSearch.timer = wlSearch.timer or CreateFrame("Frame")
  wlSearch.timer:Hide()
  wlSearch.timer:SetScript("OnUpdate", function(self, elapsed)
    if not wlSearch.wait then self:Hide(); return end
    wlSearch.wait = wlSearch.wait - (elapsed or arg1 or 0)
    if wlSearch.wait > 0 then return end
    wlSearch.wait = nil
    self:Hide()
    wlSearchFlush()
  end)

  box:SetScript("OnTextChanged", function(self, userInput)
    if not userInput then return end
    local t = self:GetText()
    if t and #t >= 2 then
      -- Queue, do not send. Every keystroke restarts the clock, so a burst of
      -- typing costs exactly one search instead of one per character.
      wlSearch.pending = t
      wlSearch.wait = WL_SEARCH_DEBOUNCE
      wlSearch.timer:Show()
      -- ⚠ Say we are looking. Leaving "type at least 2 letters" on screen while a
      --   search is already on its way is the difference between a wait that
      --   reads as fast and one that reads as broken.
      if f.sEmpty then f.sEmpty:SetText("Searching...") end
      if WLM then WLM:UpdateSuggest() end
    else
      wlSearchReset()
      state.wlSuggest = {}; if WLM then WLM:UpdateSuggest() end
    end
  end)

  -- suggestions (matching items from the whole game)
  local sHdr = f:CreateFontString(nil,"OVERLAY","GameFontNormal")
  sHdr:SetPoint("TOPLEFT",22,-84); sHdr:SetText("|cff40c0f0Matching items|r")
  local sScroll = CreateFrame("ScrollFrame", "UncappedSoulforgeSugScroll", f, "FauxScrollFrameTemplate")
  sScroll:SetPoint("TOPLEFT", 22, -100); sScroll:SetSize(290, SUG_ROWS*SUG_H)
  sScroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, SUG_H, function() f:UpdateSuggest() end)
  end)
  sScroll:EnableMouseWheel(true)
  sScroll:SetScript("OnMouseWheel", function(self, delta)
    local sb = _G["UncappedSoulforgeSugScrollScrollBar"]; if sb then sb:SetValue(sb:GetValue() - delta*SUG_H) end
  end)
  f.sScroll = sScroll
  for i = 1, SUG_ROWS do
    local r = CreateFrame("Button", nil, f); r:SetSize(284, SUG_H-2)
    r:SetPoint("TOPLEFT", sScroll, "TOPLEFT", 0, -(i-1)*SUG_H)
    r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    r.name = r:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    r.name:SetPoint("LEFT",4,0); r.name:SetWidth(250); r.name:SetJustifyH("LEFT")
    r.plus = r:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    r.plus:SetPoint("RIGHT",-4,0); r.plus:SetText("|cff20ff20+|r")
    r:SetScript("OnClick", function() if r.iname then send("ICWLADD:" .. r.iname) end end)
    sugRows[i] = r; r:Hide()
  end
  local sEmpty = f:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
  sEmpty:SetPoint("TOP", sScroll, "TOP", 0, -20); sEmpty:SetWidth(260)
  sEmpty:SetText("Type at least 2 letters to search all items.")
  f.sEmpty = sEmpty

  -- current whitelist
  local wHdr = f:CreateFontString(nil,"OVERLAY","GameFontNormal")
  wHdr:SetPoint("TOPLEFT",22,-100-(SUG_ROWS*SUG_H)-14); wHdr:SetText("|cffff6060Whitelisted|r")
  local scroll = CreateFrame("ScrollFrame", "UncappedSoulforgeWLScroll", f, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", wHdr, "BOTTOMLEFT", 0, -6); scroll:SetSize(290, WL_ROWS*WL_H)
  scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, WL_H, function() f:Update() end)
  end)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local sb = _G["UncappedSoulforgeWLScrollScrollBar"]; if sb then sb:SetValue(sb:GetValue() - delta*WL_H) end
  end)
  f.scroll = scroll
  for i = 1, WL_ROWS do
    local r = CreateFrame("Frame", nil, f); r:SetSize(284, WL_H-2)
    r:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(i-1)*WL_H)
    r.name = r:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    r.name:SetPoint("LEFT",4,0); r.name:SetWidth(230); r.name:SetJustifyH("LEFT")
    r.btn = CreateFrame("Button", nil, r)
    r.btn:SetSize(18,18); r.btn:SetPoint("RIGHT",0,0)
    r.btn:SetNormalTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")
    r.btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    r.btn:SetScript("OnClick", function() if r.wlname then send("ICWLREM:" .. r.wlname) end end)
    wlRows[i] = r; r:Hide()
  end
  local empty = f:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
  empty:SetPoint("TOP", scroll, "TOP", 0, -16); empty:SetWidth(240)
  empty:SetText("Nothing whitelisted yet.")
  f.empty = empty

  function f:UpdateSuggest()
    local list = state.wlSuggest
    FauxScrollFrame_Update(self.sScroll, #list, SUG_ROWS, SUG_H)
    if #list == 0 then self.sEmpty:Show() else self.sEmpty:Hide() end
    local offset = FauxScrollFrame_GetOffset(self.sScroll)
    for i = 1, SUG_ROWS do
      local r = sugRows[i]; local nm = list[i + offset]
      if nm then r.iname = nm; r.name:SetText(nm); r:Show() else r.iname = nil; r:Hide() end
    end
  end

  function f:Update()
    local list = state.whitelist
    FauxScrollFrame_Update(self.scroll, #list, WL_ROWS, WL_H)
    if #list == 0 then self.empty:Show() else self.empty:Hide() end
    local offset = FauxScrollFrame_GetOffset(self.scroll)
    for i = 1, WL_ROWS do
      local r = wlRows[i]; local nm = list[i + offset]
      if nm then r.wlname = nm; r.name:SetText(nm); r:Show() else r.wlname = nil; r:Hide() end
    end
  end

  WLM = f
  return f
end

-- ====================== Scroll of Extraction picker =======================
-- Opened by ICEXOPEN (the scroll's OnUse). Two modes, both in the Extraction
-- Wardrobe below: UNLOCK adds a proc you own to your collection (ICUNLOCK), and
-- APPLY stamps a collected proc onto a piece of gear (ICAPPLY), consuming one
-- scroll.
--
-- ⚠ [DE-17] This used to describe a two-column "pick a source, pick a target,
--   Extract sends ICEXTRACT" window. THAT WINDOW IS GONE, NOT HIDDEN -- see the
--   Wardrobe's own header ~100 lines below, which says so. This stale comment
--   was the ONLY remaining mention of ICEXTRACT anywhere in client_addons/, and
--   it is what made the server's still-live ICEXTRACT handler look reachable.
--   ICEXTRACT is RETIRED: nothing sends it, and the handler can be removed with
--   it (part of IC-18).
local EXT
local exSrcRows, exTgtRows = {}, {}
-- EXR_H raised 26 -> 30 alongside the wrap fix: two stacked lines at +4/-7 inside
-- 24 usable pixels were already touching before anything wrapped, so trimming the
-- text alone would have left the list cramped rather than wrong. 9 rows at 30 is
-- 36px taller, absorbed by the frame height bump below.
local EXR_ROWS, EXR_H = 9, 30

--[[
  ★★ THE EXTRACTION LIST WAS DRAWING ROWS ON TOP OF EACH OTHER (owner screenshot,
     2026-08-16). Both font strings in a row carry SetWidth(168), and a FontString
     with a width WORD-WRAPS by default -- so "Icecrown 25 Heroic Slow Melee Weapon
     Proc" became two or three lines inside a row only EXR_H (26px) tall and spilled
     straight over its neighbours. Every long item name in the list did it, which is
     why the window looked shredded rather than slightly off.

  ⚠ [DE-11] THE OLD NOTE HERE WAS WRONG, AND IT WAS THE KIND OF "KNOWN
    LIMITATION" THAT GETS COPIED INTO THE NEXT PANEL. It read "3.3.5a has no
    SetWordWrap and no SetMaxLines, so wrapping cannot be turned off". It does:
    the FontString method table in this client's Wow.exe carries SetWordWrap,
    CanWordWrap, SetNonSpaceWrap, SetIndentedWordWrap and GetIndentedWordWrap,
    and UncappedVault_UI.lua already calls SetWordWrap(false) in two live
    shipping places -- one of them inside BuildFrame, which would abort the
    whole Vault panel if the method did not exist.

    So wrapping is now turned OFF at build time on the rows this draws into
    (see the SetWordWrap calls in the row builders), which removes the overspill
    at its root rather than by keeping every string short enough to avoid it.

  ★ [DE-11] AND THE MEASURE IS MEMOISED. Trimming still happens -- an
    over-long name must still end in "..." rather than being silently clipped --
    but the binary search behind it forced a text-layout pass per probe, up to
    3 searches x ~7 probes per visible row x 9 rows = ~190 forced layouts on
    EVERY redraw, i.e. on every scroll tick. The answer only depends on the
    text, the font and the width, none of which change while scrolling, so it
    is computed once per distinct string and read back afterwards.

  ⚠ Trims the VISIBLE text only. Colour codes (|cff…|r) are re-applied around the
    result rather than trimmed through -- cutting inside an escape sequence prints
    the raw code to the player.
]]
local fitCache = {}

local function fitText(fs, text, maxWidth, colour)
  text = text or ""

  -- The font is part of the key: these rows use two different font objects at
  -- the same width, and a shared key would hand one the other's measurement.
  local path, size = fs:GetFont()
  local key = (path or "?") .. "\1" .. tostring(size) .. "\1" .. tostring(maxWidth) .. "\1" .. text

  local fitted = fitCache[key]
  if fitted == nil then
    fs:SetText(text)
    if fs:GetStringWidth() <= maxWidth then
      fitted = text
    else
      -- Binary search rather than a character-at-a-time walk: a 60-character
      -- name would otherwise cost 60 measures the first time it is seen.
      local lo, hi = 0, #text
      while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        fs:SetText(string.sub(text, 1, mid) .. "...")
        if fs:GetStringWidth() <= maxWidth then lo = mid else hi = mid - 1 end
      end
      fitted = string.sub(text, 1, lo) .. "..."
    end
    fitCache[key] = fitted
  end

  fs:SetText(colour and (colour .. fitted .. "|r") or fitted)
end

local function itemDisplay(entry)
  local name, _, quality, _, _, _, _, _, _, tex = GetItemInfo(entry)
  local r, g, b = GetItemQualityColor(quality or 1)
  return name or ("Item #" .. tostring(entry)), tex or QUESTION, r, g, b
end

-- [#1249] "from Serpent Slicer" -- the clause the report asked for.
--
-- The server has been sending source_entry in every ICCOLLROW since unlocking
-- existed; the client parsed it, stored it, and then only ever showed it on the
-- Collection tab's detail pane, which is not the screen anyone reads when a
-- row refuses to unlock. Returns nil for anything unlocked before the column
-- was recorded, and the clause is simply left off rather than replaced with the
-- word "unknown".
--
-- ⚠ Below itemDisplay ON PURPOSE. A local referenced from a closure defined
--   above its declaration reads the nil GLOBAL of that name -- the trap this
--   file's header calls out for UIKit -- and this one would only have shown up
--   as "from Item #7999" on the exact rows it was written for.
local function collectedFrom(spellId, trigger)
  local c = state.collByKey and state.collByKey[spellId .. ":" .. trigger]
  if not c or not c.src or c.src == 0 then return nil end
  local nm = itemDisplay(c.src)
  return (nm and nm ~= "") and nm or nil
end

-- Wheel-scroll a FauxScrollFrame, CLAMPED.
--
-- Blizzard's FauxScrollFrame_OnVerticalScroll sets frame.offset from the raw value it is
-- handed, not from the scrollbar's clamped value, and FauxScrollFrame_Update sets the
-- scrollbar's min/max without ever resetting frame.offset. So a wheel handler that feeds
-- its own previous offset back in ("GetOffset() - delta") climbs forever once it passes
-- the end, and the list scrolls off into blank rows. Every wheel scroll here goes through
-- this instead, which clamps against the number of rows there actually are.
local function wheelScroll(frame, delta, count, rows, height, updateFn)
  local maxOffset = math.max(0, (count or 0) - rows)
  local offset = FauxScrollFrame_GetOffset(frame) - delta
  if offset < 0 then offset = 0 elseif offset > maxOffset then offset = maxOffset end
  FauxScrollFrame_OnVerticalScroll(frame, offset * height, height, updateFn)
end

-- Pull a stale offset back into range after the list has SHRUNK (filter typed, item
-- socketed away). Same reason: nothing in the template does this for us. Returns the
-- offset that should actually be rendered.
local function clampOffset(frame, count, rows)
  local maxOffset = math.max(0, (count or 0) - rows)
  local offset = FauxScrollFrame_GetOffset(frame)
  if offset > maxOffset then
    FauxScrollFrame_SetOffset(frame, maxOffset)
    local bar = _G[frame:GetName() .. "ScrollBar"]
    if bar then bar:SetValue(maxOffset * (frame.uncappedRowH or 1)) end
    offset = maxOffset
  end
  return offset
end

--[[ ===========================================================================
     THE EXTRACTION WARDROBE  (owner ruling 2026-08-16)
     ===========================================================================

     REPLACES the old two-column "pull an effect off A, stamp it onto B" window.
     That window is gone, not hidden -- the owner asked for a replacement, and
     leaving both would mean two surfaces that can each half-do the job.

     The model it drives (server side: ItemCustomization::UnlockProc /
     ApplyCollectedProc):

       UNLOCK  burn a gear piece + a Scroll of Extraction to learn its proc
               PERMANENTLY and ACCOUNT-WIDE, exactly like an appearance.
       APPLY   stamp anything you have unlocked onto a piece of gear, one
               scroll a time, as often as you like.

     So the window has two modes: a COLLECTION you browse (grid of icons, the
     way the wardrobe works) and an UNLOCK list of gear you are carrying that
     still has something to teach.

     ⚠ Whitelisting lives here too. The Soulforge whitelist is what stops
       auto-consume eating a piece, and the moment unlocking became a reason to
       KEEP an item, "protect this from being melted" belonged on the same
       screen as "this is the item I still need". It drives the existing
       ICWLADD/ICWLREM list -- deliberately not a second, parallel list.
]]

-- Collection grid geometry. 6 x 4 cells of 42px, scrolled a ROW at a time
-- (FauxScrollFrame's unit is one row, and one row here is six icons).
local EXC_COLS, EXC_ROWS, EXC_CELL = 6, 4, 42

-- [#1278] Disabled-effects list geometry. 12 x 22 = 264px, which sits inside the
-- 270px the unlock list (EXR_ROWS x EXR_H) already occupies, so the tab costs the
-- panel no extra height in the Dashboard's content group.
local EXB_ROWS, EXB_H = 12, 22

-- The filter buttons across the top of the collection. `test` is handed the
-- collection entry and answers "does this belong under that tab".
--
-- ★ Set bonuses are trigger 0 with a spell the server marked as a set bonus; we
--   cannot see that flag from here, so the set filter matches on the NAME the
--   server already renders, which is the same string the player is reading.
local EXC_FILTERS = {
  { key = "all",  label = "All",          test = function() return true end },
  { key = "hit",  label = "On Hit",       test = function(e) return e.trigger ~= 0 end },
  { key = "pass", label = "Passive",      test = function(e) return e.trigger == 0 end },
  { key = "set",  label = "Set Bonuses",  test = function(e)
      local n = procDisplayName({ spellId = e.spell }) or ""
      return n:find("Bonus") ~= nil or n:find("[Ss]et ") ~= nil
    end },
}

-- `parent` non-nil = build INTO the Dashboard's content group (owner request
-- 2026-08-16, "add the extraction window to the dashboard"). nil = the old
-- free-floating popup, which nothing calls any more but is kept working so a
-- future caller is not silently broken.
--
-- ⚠ Embedded, the Dashboard supplies the frame, the border and the title bar, so
--   this must NOT bring its own -- a second backdrop inside the content panel
--   draws a box-in-a-box, and a second close button closes only the inner one.
local function BuildExtractor(parent)
  if EXT then return EXT end
  local embedded = parent ~= nil
  local f = CreateFrame("Frame", "UncappedExtractorFrame", parent or UIParent)

  if embedded then
    f:SetAllPoints(parent)
  else
    f:SetSize(720, 500)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 32,
      insets = { left = 11, right = 12, top = 12, bottom = 11 } })
    f:SetBackdropBorderColor(0.55, 0.4, 0.9, 1)
    f:EnableMouse(true); f:SetMovable(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true); f:Hide()
    tinsert(UISpecialFrames, "UncappedExtractorFrame")   -- Esc closes it
    if UncappedScale_Register then UncappedScale_Register(f, { group = "dashboard" }) end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -18); title:SetText("|cffb384ffExtraction|r")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -8, -8)
  end

  -- Everything below hangs off yTop, so the two layouts share one set of
  -- offsets: embedded starts at the top of the content group, floating leaves
  -- room for its own title and close button.
  local yTop = embedded and -6 or -40

  f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.sub:SetPoint("TOP", 0, yTop)

  -- ---- mode tabs --------------------------------------------------------
  --
  -- ⚠ 88 wide rather than the old 110, and the search box moved right with them.
  --   Three tabs at 110 would have run under the search box; the alternative was
  --   a second row of chrome above a panel that is already tight vertically in
  --   the Dashboard's content group.
  local function ModeButton(text, mode, x)
    local b = KitButton(f, "", 88, 22)
     b:SetPoint("TOPLEFT", x, yTop - 18); b:SetText(text)
    b:SetScript("OnClick", function()
      state.exMode = mode
      state.collSel = nil
      --[[ [#1278] REQUESTED LAZILY, ON FIRST SIGHT OF THE TAB.

           The register is ~150 spells and arrives as about fifteen addon
           messages. Most players never open this tab at all, so asking at
           login -- or worse, on every zone-in alongside the rest of the
           PLAYER_ENTERING_WORLD burst -- would spend a MEDIUM verb and a
           fifteen-message reply on nothing, for everyone, forever. Paying it
           on a click the player actually made is the right trade, and it is
           the same reason the 640 KB quest-giver table is LoadOnDemand. ]]
      if mode == "banned" and not state.bpAsked then
        state.bpAsked = true
        send("ICBPGET")

        -- [#1277] And if that one message is dropped, ask again -- twice, with
        -- backoff, then stop and let the panel say so. Without this the tab
        -- would sit on "Asking the server..." forever and the player would file
        -- the fifth report of this shape.
        local UT = _G.UncappedThrottle
        if UT and UT.Reask then
          UT.Reask("banned-procs", function()
            send("ICBPGET")
            if EXT and EXT:IsShown() then EXT:Refresh() end
          end, { tries = 2, base = 3, maxDelay = 8, onGiveUp = function()
            -- Let the player try again by re-entering the tab.
            state.bpAsked = false
            if EXT and EXT:IsShown() then EXT:Refresh() end
          end })
        end
      end
      EXT:Refresh()
    end)
    return b
  end
  f.tabColl   = ModeButton("Collection", "coll",   20)
  f.tabUnlock = ModeButton("Unlock",     "unlock", 112)

  --[[ ★★ [#1278] "Cannot see banned proc list."

       IT ALREADY EXISTED. There is a "Banned Procs..." button on the Soul Forge
       tab, a window titled "Disabled Effects", and a /bannedprocs slash command.
       The owner could not find any of them -- which is a finding about the
       INFORMATION ARCHITECTURE, not a missing feature, and the fix is to put it
       where someone goes looking for it rather than to build a second one.

       Here, specifically, because "why can I not extract this effect" and "which
       effects are switched off" are the same question asked twice, and this is
       the screen where the first one gets asked.

       ⚠ NOT A DASHBOARD NAV TAB, and this is not a style preference:
         UncappedDashboardConfig.lua records that the nav column's required
         height reaches ~700 units at 16 entries, which collapses the whole
         window's zoom ceiling to ~1.01 for every player. Extraction itself only
         exists because it could take the dead `tutorial` slot. There is no free
         slot left, so a nav tab would cost the zoom feature.

       ⚠ AND NOT A SECOND WINDOW. The pop-out stays exactly as it is -- same
         frame, same rows, same /bannedprocs -- and this tab renders the same
         data through the same filter and the same row painter (see bpAPI). Two
         surfaces that can drift apart is how the realm ended up with two
         whitelists once already. ]]
  f.tabBanned = ModeButton("Disabled",   "banned", 204)
  -- HookScript, not SetScript: UncappedUIKit.CreateButton installs its own
  -- OnEnter/OnLeave to drive the hover glow (Controls/Button.lua), and replacing
  -- them would silently take the glow off this one button.
  f.tabBanned:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Disabled effects")
    GameTooltip:AddLine("Effects switched off on this realm -- the \"banned procs\" list. "
      .. "An item carrying one still shows it on its tooltip, but it does nothing, "
      .. "and it cannot be extracted or soulbound.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  f.tabBanned:HookScript("OnLeave", function() GameTooltip:Hide() end)

  -- ---- search -----------------------------------------------------------
  local search = CreateFrame("EditBox", "UncappedExtractSearch", f, "InputBoxTemplate")
  search:SetSize(170, 20); search:SetPoint("TOPLEFT", 300, yTop - 18)
  search:SetAutoFocus(false)
  search:SetScript("OnTextChanged", function(self)
    state.exSearch = (self:GetText() or ""):lower()
    EXT:Refresh()
  end)
  search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  f.search = search

  local sLabel = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  sLabel:SetPoint("BOTTOMLEFT", search, "TOPLEFT", -4, 1); sLabel:SetText("Search")

  -- ---- filter buttons ---------------------------------------------------
  f.filterBtns = {}
  for i, fl in ipairs(EXC_FILTERS) do
    local b = KitButton(f, "", 84, 20)
     b:SetPoint("TOPLEFT", 20 + (i - 1) * 88, yTop - 44); b:SetText(fl.label)
    b:SetScript("OnClick", function()
      state.exFilter = fl.key
      EXT:Refresh()
    end)
    f.filterBtns[i] = b
  end

  -- ---- collection grid --------------------------------------------------
  local grid = CreateFrame("ScrollFrame", "UncappedExtractGrid", f, "FauxScrollFrameTemplate")
  grid:SetPoint("TOPLEFT", 20, yTop - 70)
  grid:SetSize(EXC_COLS * EXC_CELL, EXC_ROWS * EXC_CELL)
  grid:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, EXC_CELL, function() if EXT then EXT:Refresh() end end)
  end)
  grid:SetScript("OnMouseWheel", function(self, delta)
    -- Scrolls a ROW of icons at a time, so the count handed to the clamp is the
    -- number of ROWS, not the number of procs. Passing the proc count here is
    -- what would let the grid scroll far past its own content.
    wheelScroll(self, delta, self.uncappedRows or 0, EXC_ROWS, EXC_CELL,
      function() if EXT then EXT:Refresh() end end)
  end)
  f.grid = grid

  f.cells = {}
  for i = 1, EXC_COLS * EXC_ROWS do
    local c = CreateFrame("Button", nil, f)
    c:SetSize(EXC_CELL - 4, EXC_CELL - 4)
    local col, row = (i - 1) % EXC_COLS, math.floor((i - 1) / EXC_COLS)
    c:SetPoint("TOPLEFT", grid, "TOPLEFT", col * EXC_CELL, -row * EXC_CELL)
    c.icon = c:CreateTexture(nil, "ARTWORK"); c.icon:SetAllPoints()
    c.sel = c:CreateTexture(nil, "OVERLAY")
    c.sel:SetAllPoints(); c.sel:SetTexture(0.4, 0.3, 0.7, 0.45); c.sel:Hide()
    local hl = c:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetTexture(1, 1, 1, 0.2)
    c:SetScript("OnEnter", function(self)
      if not self.data then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetHyperlink("spell:" .. self.data.spell)
      GameTooltip:AddLine(triggerLabel(self.data.trigger), 0.7, 0.55, 1)
      GameTooltip:Show()
    end)
    c:SetScript("OnLeave", function() GameTooltip:Hide() end)
    c:SetScript("OnClick", function(self)
      if self.data then state.collSel = self.data; EXT:Refresh() end
    end)
    c:Hide()
    f.cells[i] = c
  end

  -- Shown instead of the grid when nothing matches, so an empty collection
  -- explains itself rather than looking broken.
  f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.empty:SetPoint("TOPLEFT", grid, "TOPLEFT", 4, -8)
  f.empty:SetWidth(EXC_COLS * EXC_CELL - 8); f.empty:SetJustifyH("LEFT")
  f.empty:Hide()

  -- ---- unlock list (same footprint as the grid; only one shows) ---------
  local ulist = CreateFrame("ScrollFrame", "UncappedExtractUnlock", f, "FauxScrollFrameTemplate")
  ulist:SetPoint("TOPLEFT", 20, yTop - 70)
  ulist:SetSize(EXC_COLS * EXC_CELL, EXC_ROWS * EXC_CELL)
  ulist:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, EXR_H, function() if EXT then EXT:Refresh() end end)
  end)
  ulist:SetScript("OnMouseWheel", function(self, delta)
    wheelScroll(self, delta, self.uncappedCount or 0, EXR_ROWS, EXR_H,
      function() if EXT then EXT:Refresh() end end)
  end)
  f.ulist = ulist

  f.urows = {}
  for i = 1, EXR_ROWS do
    local r = CreateFrame("Button", nil, f); r:SetSize(EXC_COLS * EXC_CELL - 4, EXR_H - 2)
    if i == 1 then r:SetPoint("TOPLEFT", ulist, "TOPLEFT", 0, 0)
    else r:SetPoint("TOPLEFT", f.urows[i-1], "BOTTOMLEFT", 0, -2) end
    r.sel = r:CreateTexture(nil, "BACKGROUND")
    r.sel:SetAllPoints(); r.sel:SetTexture(0.4, 0.3, 0.7, 0.5); r.sel:Hide()
    local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetTexture(1, 1, 1, 0.12)
    r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(EXR_H - 8, EXR_H - 8)
    r.icon:SetPoint("LEFT", 2, 0)
    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 4, 6); r.name:SetWidth(190); r.name:SetJustifyH("LEFT")
    r.sub = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r.sub:SetPoint("LEFT", r.icon, "RIGHT", 4, -7); r.sub:SetWidth(190); r.sub:SetJustifyH("LEFT")
    -- ★ [DE-11] A FontString with a width WORD-WRAPS by default, and two stacked
    -- lines in a 30px row is what shredded this list in 2026-08-16's screenshot.
    -- Turned off at the source. Guarded only because these rows are built before
    -- anything has proved the method exists on a given client build.
    if r.name.SetWordWrap then r.name:SetWordWrap(false) end
    if r.sub.SetWordWrap  then r.sub:SetWordWrap(false)  end
    -- A padlock, drawn when the item is on the Soulforge whitelist.
    r.lock = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.lock:SetPoint("RIGHT", -4, 0); r.lock:SetText("|cffffd100*|r"); r.lock:Hide()
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:SetScript("OnClick", function(self, button)
      if not self.data then return end
      if button == "RightButton" then
        -- Right-click protects the item from auto-consume, using the same
        -- whitelist the Soulforge window drives. Keyed on NAME, because that is
        -- what ICWLADD takes.
        local nm = itemDisplay(self.data.entry)
        if nm then
          local wl, exact = wlProtectedBy(nm)
          if exact then
            send("ICWLREM:" .. nm)
          elseif wl then
            -- [#1249] ICWLREM deletes a row BY NAME, so un-protecting an item
            -- that is only covered by a broader phrase would delete nothing and
            -- report success. Say which entry is doing it instead.
            msg(string.format("|cffffffff%s|r is protected by the whitelist entry "
              .. "|cffffd100%s|r. Remove that entry in the Whitelist window to unprotect it.", nm, wl))
            return
          else
            send("ICWLADD:" .. nm)
          end
          send("ICWLIST")
        end
        return
      end
      state.exSelSrc = self.data
      EXT:Refresh()
    end)
    -- [#1249] The row text is width-clamped and ellipsised (fitText), so the
    -- disambiguated name and the "already unlocked, from ..." clause are exactly
    -- the things most likely to be cut off. The tooltip is where they are
    -- guaranteed to be readable, spell id included -- which is also the number
    -- anyone filing a report about this will be asked for.
    r:SetScript("OnEnter", function(self)
      local d = self.data
      if not d then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText((itemDisplay(d.entry)))
      GameTooltip:AddLine(procLabel(d.spell) .. "  (" .. triggerLabel(d.trigger) .. ")", 0.7, 0.55, 1)
      GameTooltip:AddLine("Spell ID " .. tostring(d.spell), 0.6, 0.6, 0.6)

      if state.collSet and state.collSet[d.spell .. ":" .. d.trigger] then
        local from = collectedFrom(d.spell, d.trigger)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("You have already unlocked this effect"
          .. (from and (", from " .. from) or "") .. ".", 1, 0.5, 0.25, true)
      end

      local wl, exact = wlProtectedBy((itemDisplay(d.entry)))
      if wl then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(exact
          and "On your Soulforge whitelist, so it cannot be destroyed here."
          or ("Protected by the whitelist entry \"" .. wl .. "\", so it cannot be destroyed here."),
          1, 0.82, 0, true)
      end
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r:Hide()
    f.urows[i] = r
  end

  --[[ ---- disabled effects [#1278] --------------------------------------
       Full width, because this mode has no detail column -- the reason sentence
       is the second half of every row. Same footprint as the grid otherwise, so
       only one of the three lists is ever visible.

       TOPLEFT + TOPRIGHT + SetHeight, never TOPLEFT + RIGHT: anchoring RIGHT
       also pins the frame's vertical CENTRE, which fights the TOPLEFT anchor and
       leaves the height undefined. ]]
  local blist = CreateFrame("ScrollFrame", "UncappedExtractBanned", f, "FauxScrollFrameTemplate")
  blist:SetPoint("TOPLEFT", 20, yTop - 70)
  blist:SetPoint("TOPRIGHT", -34, yTop - 70)
  blist:SetHeight(EXB_ROWS * EXB_H)
  blist.uncappedRowH = EXB_H
  blist:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, EXB_H, function() if EXT then EXT:Refresh() end end)
  end)
  blist:SetScript("OnMouseWheel", function(self, delta)
    wheelScroll(self, delta, self.uncappedCount or 0, EXB_ROWS, EXB_H,
      function() if EXT then EXT:Refresh() end end)
  end)
  blist:Hide()
  f.blist = blist

  f.brows = {}
  for i = 1, EXB_ROWS do
    local r = CreateFrame("Button", nil, f)
    r:SetHeight(EXB_H)
    r:SetPoint("TOPLEFT", blist, "TOPLEFT", 0, -(i - 1) * EXB_H)
    r:SetPoint("TOPRIGHT", blist, "TOPRIGHT", 0, -(i - 1) * EXB_H)

    local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetTexture(1, 1, 1, 0.10)

    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(18, 18); r.icon:SetPoint("LEFT", 0, 0)
    r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
    r.name:SetWidth(180); r.name:SetJustifyH("LEFT")

    r.reason = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r.reason:SetPoint("LEFT", r.name, "RIGHT", 8, 0)
    r.reason:SetPoint("RIGHT", r, "RIGHT", -4, 0)
    r.reason:SetJustifyH("LEFT")

    -- The SAME tooltip the pop-out draws, through the same function.
    r:SetScript("OnEnter", function(self) if bpAPI then bpAPI.tip(self) end end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)

    r:Hide()
    f.brows[i] = r
  end

  -- ---- right-hand detail / target panel ---------------------------------
  local DETAIL_X = 20 + EXC_COLS * EXC_CELL + 16

  f.detTitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.detTitle:SetPoint("TOPLEFT", DETAIL_X, yTop - 70)
  f.detTitle:SetPoint("RIGHT", f, "RIGHT", -14, 0); f.detTitle:SetJustifyH("LEFT")

  f.detSub = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.detSub:SetPoint("TOPLEFT", DETAIL_X, yTop - 88)
  f.detSub:SetPoint("RIGHT", f, "RIGHT", -14, 0); f.detSub:SetJustifyH("LEFT")

  -- "Where does it drop?" reuses the existing USOURCE lookup rather than adding a
  -- second one -- the reply is handled by the shared USRC block further down.
  f.srcBtn = KitButton(f, "", 140, 20)
   f.srcBtn:SetPoint("TOPLEFT", DETAIL_X, yTop - 110)
  f.srcBtn:SetText("Where does it drop?")
  f.srcBtn:SetScript("OnClick", function()
    local e = state.collSel and state.collSel.src
    if e and e ~= 0 then send("USOURCE:" .. e)
    else DEFAULT_CHAT_FRAME:AddMessage("|cffb384ff[Extraction]|r No source item recorded for this effect.") end
  end)

  f.tgtHead = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.tgtHead:SetPoint("TOPLEFT", DETAIL_X, yTop - 138)
  f.tgtHead:SetText("Apply to:")

  local tscroll = CreateFrame("ScrollFrame", "UncappedExtractTargets", f, "FauxScrollFrameTemplate")
  tscroll:SetPoint("TOPLEFT", DETAIL_X, yTop - 156)
  tscroll:SetSize(238, 6 * EXR_H)
  tscroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, EXR_H, function() if EXT then EXT:Refresh() end end)
  end)
  tscroll:SetScript("OnMouseWheel", function(self, delta)
    wheelScroll(self, delta, self.uncappedCount or 0, 6, EXR_H,
      function() if EXT then EXT:Refresh() end end)
  end)
  f.tscroll = tscroll

  f.trows = {}
  for i = 1, 6 do
    local r = CreateFrame("Button", nil, f); r:SetSize(234, EXR_H - 2)
    if i == 1 then r:SetPoint("TOPLEFT", tscroll, "TOPLEFT", 0, 0)
    else r:SetPoint("TOPLEFT", f.trows[i-1], "BOTTOMLEFT", 0, -2) end
    r.sel = r:CreateTexture(nil, "BACKGROUND")
    r.sel:SetAllPoints(); r.sel:SetTexture(0.4, 0.3, 0.7, 0.5); r.sel:Hide()
    local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetTexture(1, 1, 1, 0.12)
    r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(EXR_H - 8, EXR_H - 8)
    r.icon:SetPoint("LEFT", 2, 0)
    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 4, 0); r.name:SetWidth(170); r.name:SetJustifyH("LEFT")
    if r.name.SetWordWrap then r.name:SetWordWrap(false) end   -- [DE-11]
    -- The "I am finished with this piece" tick.
    r.tick = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.tick:SetPoint("RIGHT", -4, 0); r.tick:SetText("|cff40ff40v|r"); r.tick:Hide()
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:SetScript("OnClick", function(self, button)
      if not self.data then return end
      if button == "RightButton" then
        local key = self.data.bag .. ":" .. self.data.slot
        local now = state.exDone and state.exDone[key]
        send(string.format("ICDONE:%d:%d:%d", self.data.bag, self.data.slot, now and 0 or 1))
        return
      end
      state.exSelTgt = self.data
      EXT:Refresh()
    end)
    r:SetScript("OnEnter", function(self)
      if not self.data then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(itemDisplay(self.data.entry))
      GameTooltip:AddLine("Right-click to mark this piece finished.", 0.7, 0.7, 0.7)
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r:Hide()
    f.trows[i] = r
  end

  -- ---- summary + action --------------------------------------------------
  f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.summary:SetPoint("BOTTOMLEFT", 20, 44); f.summary:SetPoint("BOTTOMRIGHT", -20, 44)
  f.summary:SetJustifyH("CENTER"); f.summary:SetHeight(28)

  f.actBtn = KitButton(f, "", 170, 26)
   f.actBtn:SetPoint("BOTTOM", -92, 14)
  f.actBtn:SetScript("OnClick", function()
    if state.exMode == "unlock" then
      local s = state.exSelSrc
      if s then send(string.format("ICUNLOCK:%d:%d:%d:%d", s.bag, s.slot, s.spell, s.trigger)) end
    else
      local c, t = state.collSel, state.exSelTgt
      if c and t then send(string.format("ICAPPLY:%d:%d:%d:%d", c.spell, c.trigger, t.bag, t.slot)) end
    end
  end)

  f.wlBtn = KitButton(f, "", 170, 26)
   f.wlBtn:SetPoint("BOTTOM", 92, 14)
  f.wlBtn:SetText("Protect from melting")
  f.wlBtn:SetScript("OnClick", function()
    local s = state.exSelSrc
    if not s then return end
    local nm = itemDisplay(s.entry)
    if not nm then return end
    local wl, exact = wlProtectedBy(nm)
    if exact then
      send("ICWLREM:" .. nm)
    elseif wl then
      msg(string.format("|cffffffff%s|r is protected by the whitelist entry "
        .. "|cffffd100%s|r. Remove that entry in the Whitelist window to unprotect it.", nm, wl))
      return
    else
      send("ICWLADD:" .. nm)
    end
    send("ICWLIST")
  end)
  f.wlBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Soulforge whitelist")
    GameTooltip:AddLine("Auto-consume will never melt an item on this list. "
      .. "Worth setting on anything you still mean to unlock.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  f.wlBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- =======================================================================
  -- Refresh
  -- =======================================================================

  -- The collection, filtered by the tab and the search box.
  local function visibleCollection()
    local out = {}
    local flt
    for _, fl in ipairs(EXC_FILTERS) do
      if fl.key == (state.exFilter or "all") then flt = fl end
    end
    local q = state.exSearch or ""
    for _, e in ipairs(state.collection or {}) do
      local ok = (not flt) or flt.test(e)
      if ok and q ~= "" then
        local n = (procDisplayName({ spellId = e.spell }) or ""):lower()
        ok = n:find(q, 1, true) ~= nil
      end
      if ok then out[#out + 1] = e end
    end
    return out
  end

  function f:Refresh()
    local mode = state.exMode or "coll"
    --[[ THE BALANCE **PLUS** WHAT IS STILL LOOSE IN THE BAGS.

         Scrolls became a held currency on 2026-08-16: the server absorbs any loose
         ones out of the bags, so GetItemCount is normally 0 even for someone with
         hundreds banked, and the balance is the number that matters. state.scrolls
         is nil until the first ICSCROLLS arrives, and nil must not read as "none" --
         it reads as "not told yet", which is why the gating below tests
         `scrolls == 0` rather than `not scrolls`.

         ★ [#1124] But the balance ONLY moves when an ICSCROLLS lands, and nothing
           sends one because a scroll dropped into your bags. So a scroll looted with
           this tab already open was in NEITHER term -- the panel kept saying "0
           scrolls held", the Unlock/Apply buttons stayed greyed, and the only way to
           see it was /reload. Adding the bag count makes the loot visible in the
           frame it lands.

         ⚠ NOT a double count. The server destroys the bag item in the very same call
           that raises the balance (the absorb is atomic), so an entry is in exactly
           one of the two terms at any instant -- never both.
    ]]
    local scrolls = (state.scrolls or 0) + (GetItemCount(SCROLL_EXTRACTION) or 0)
    self.sub:SetText("Unlock an effect once, then stamp it on anything.  "
      .. "|cffffd100" .. scrolls .. "|r scroll" .. (scrolls == 1 and "" or "s") .. " held")

    -- Tab highlight: the active one is disabled, which is the cheapest honest
    -- "you are here" this template gives us.
    self.tabColl:Enable(); self.tabUnlock:Enable(); self.tabBanned:Enable()
    if mode == "coll" then self.tabColl:Disable()
    elseif mode == "unlock" then self.tabUnlock:Disable()
    else self.tabBanned:Disable() end

    -- [#1278] Shown here rather than in two of the three branches. The Disabled
    -- tab has no action button, no summary and no detail column, and it hides
    -- them below -- so whichever branch does NOT re-show them would leave them
    -- hidden for the rest of the session once the player had visited that tab.
    self.actBtn:Show(); self.summary:Show()
    self.detTitle:Show(); self.detSub:Show()
    self.blist:Hide()
    for _, r in ipairs(self.brows) do r:Hide() end

    for i, fl in ipairs(EXC_FILTERS) do
      if (state.exFilter or "all") == fl.key then self.filterBtns[i]:Disable()
      else self.filterBtns[i]:Enable() end
      -- Filters only mean anything over the collection.
      if mode == "coll" then self.filterBtns[i]:Show() else self.filterBtns[i]:Hide() end
    end

    if mode == "coll" then
      self.ulist:Hide()
      for _, r in ipairs(self.urows) do r:Hide() end
      self.grid:Show()

      local list = visibleCollection()
      local rows = math.ceil(#list / EXC_COLS)
      self.grid.uncappedRows = rows
      FauxScrollFrame_Update(self.grid, rows, EXC_ROWS, EXC_CELL)
      local off = clampOffset(self.grid, rows, EXC_ROWS)

      for i = 1, EXC_COLS * EXC_ROWS do
        local c = self.cells[i]
        local idx = off * EXC_COLS + i
        local e = list[idx]
        if e then
          c.data = e
          local _, _, icon = GetSpellInfo(e.spell)
          c.icon:SetTexture(icon or QUESTION)
          if state.collSel and state.collSel.spell == e.spell
             and state.collSel.trigger == e.trigger then c.sel:Show() else c.sel:Hide() end
          c:Show()
        else
          c.data = nil; c:Hide()
        end
      end

      if #list == 0 then
        self.empty:Show()
        self.empty:SetText((state.collection and #state.collection > 0)
          and "|cff808080Nothing matches that filter.|r"
          or "|cff808080You have not unlocked any effects yet.\n\nSwitch to Unlock, pick a piece of gear that carries an effect, and spend a Scroll of Extraction on it. The effect is yours permanently, on every character.|r")
      else
        self.empty:Hide()
      end

      -- detail
      local c = state.collSel
      if c then
        self.detTitle:SetText("|cffb384ff" .. (procDisplayName({ spellId = c.spell }) or "?") .. "|r")
        local from = (c.src and c.src ~= 0) and itemDisplay(c.src) or nil
        self.detSub:SetText(triggerLabel(c.trigger)
          .. (from and ("\nFirst pulled from |cffffffff" .. from .. "|r") or "\n|cff808080Origin not recorded|r"))
        self.srcBtn:Show()
      else
        self.detTitle:SetText("")
        self.detSub:SetText("|cff808080Pick an effect on the left.|r")
        self.srcBtn:Hide()
      end

      -- targets
      local tgt = state.exTargets or {}
      self.tgtHead:Show(); self.tscroll:Show()
      self.tscroll.uncappedCount = #tgt
      FauxScrollFrame_Update(self.tscroll, #tgt, 6, EXR_H)
      local to = clampOffset(self.tscroll, #tgt, 6)
      for i = 1, 6 do
        local r, d = self.trows[i], tgt[i + to]
        if d then
          r.data = d
          local nm, tex, cr, cg, cb = itemDisplay(d.entry)
          r.icon:SetTexture(tex)
          fitText(r.name, nm .. (d.equipped == 1 and "  [Worn]" or ""), 160)
          r.name:SetTextColor(cr, cg, cb)
          if state.exDone and state.exDone[d.bag .. ":" .. d.slot] then r.tick:Show() else r.tick:Hide() end
          if state.exSelTgt and state.exSelTgt.bag == d.bag and state.exSelTgt.slot == d.slot
            then r.sel:Show() else r.sel:Hide() end
          r:Show()
        else
          r.data = nil; r:Hide()
        end
      end

      self.actBtn:SetText("Apply  (1 scroll)")
      self.wlBtn:Hide()
      if c and state.exSelTgt and scrolls > 0 then
        self.actBtn:Enable()
        self.summary:SetText(string.format("Stamp |cffb384ff%s|r onto |cffffffff%s|r.",
          procDisplayName({ spellId = c.spell }) or "?", (itemDisplay(state.exSelTgt.entry))))
      else
        self.actBtn:Disable()
        if scrolls == 0 then
          self.summary:SetText("|cffff8040You have no Scrolls of Extraction.|r")
        elseif not c then
          self.summary:SetText("Choose an unlocked effect, then the piece to stamp it on.")
        else
          self.summary:SetText("Now choose the piece of gear to receive it.")
        end
      end

    elseif mode == "unlock" then   -- ---- unlock mode ----
      self.grid:Hide()
      for _, c in ipairs(self.cells) do c:Hide() end
      self.empty:Hide()
      self.tgtHead:Hide(); self.tscroll:Hide()
      for _, r in ipairs(self.trows) do r:Hide() end
      self.srcBtn:Hide()
      self.ulist:Show()

      local src = state.exSources or {}
      self.ulist.uncappedCount = #src
      FauxScrollFrame_Update(self.ulist, #src, EXR_ROWS, EXR_H)
      local so = clampOffset(self.ulist, #src, EXR_ROWS)
      for i = 1, EXR_ROWS do
        local r, d = self.urows[i], src[i + so]
        if d then
          r.data = d
          local nm, tex, cr, cg, cb = itemDisplay(d.entry)
          r.icon:SetTexture(tex)
          local known = state.collSet and state.collSet[d.spell .. ":" .. d.trigger]
          fitText(r.name, nm, 180); r.name:SetTextColor(cr, cg, cb)
          --[[ ★★ [#1249] THE ROW THE REPORT WAS ABOUT.
               It used to read "already unlocked -- Poison (On Hit)" and stop
               there, which is unreadable when three different spells are all
               named "Poison" and the player owns exactly one of them. procLabel
               appends the spell id when -- and only when -- the name is shared,
               and collectedFrom names the item the copy was pulled from. ]]
          local sub = procLabel(d.spell) .. "  (" .. triggerLabel(d.trigger) .. ")"
          if known then
            local from = collectedFrom(d.spell, d.trigger)
            sub = "already unlocked -- " .. sub .. (from and (", from " .. from) or "")
          end
          fitText(r.sub, sub, 180, known and "|cff808080" or "|cffb384ff")
          -- [#1249] Substring, matching the server. See wlProtectedBy.
          if wlProtectedBy(nm) then r.lock:Show() else r.lock:Hide() end
          if state.exSelSrc and state.exSelSrc.bag == d.bag and state.exSelSrc.slot == d.slot
             and state.exSelSrc.spell == d.spell then r.sel:Show() else r.sel:Hide() end
          r:Show()
        else
          r.data = nil; r:Hide()
        end
      end

      local s = state.exSelSrc
      self.detTitle:SetText("|cffffd100Unlocking destroys the item.|r")
      self.detSub:SetText("The effect becomes yours permanently and on every character. "
        .. "Right-click a row, or use the button below, to protect a piece from auto-consume.")
      self.actBtn:SetText("Unlock  (1 scroll)")
      self.wlBtn:Show()

      local known = s and state.collSet and state.collSet[s.spell .. ":" .. s.trigger]
      --[[ ★★ [#1249] THE PADLOCKED ROW IS NOW A DISABLED BUTTON, NOT A REFUSAL.

           The server refuses a whitelisted source (UnlockProc ->
           RefuseWhitelisted -> "whitelisted"), and it always did. The client
           offered the button anyway, so the player clicked, braced for a scroll
           to be spent, and got a refusal for a rule the panel had never shown
           them -- made worse by the padlock not being drawn at all when the
           protection came from a SUBSTRING entry rather than an exact one.

           Refusing here, with the reason on screen before the click, is the
           friendly half. RefuseWhitelisted is still the real gate. ]]
      local wl, wlExact = nil, false
      if s then wl, wlExact = wlProtectedBy((itemDisplay(s.entry))) end

      if s and scrolls > 0 and not known and not wl then
        self.actBtn:Enable()
        self.summary:SetText(string.format("Destroy |cffffffff%s|r to learn |cffb384ff%s|r forever.",
          (itemDisplay(s.entry)), procLabel(s.spell)))
      else
        self.actBtn:Disable()
        if scrolls == 0 then
          self.summary:SetText("|cffff8040You have no Scrolls of Extraction.|r")
        elseif not s then
          self.summary:SetText("Choose a piece of gear to pull an effect from.")
        elseif known then
          -- Names WHICH "Poison" they already own, and where it came from.
          local from = collectedFrom(s.spell, s.trigger)
          self.summary:SetText(string.format(
            "|cff808080You have already unlocked |r|cffb384ff%s|r|cff808080 (%s)%s.|r",
            procLabel(s.spell), triggerLabel(s.trigger),
            from and ("|cff808080, from |r|cffffffff" .. from .. "|r") or ""))
        elseif wl then
          self.summary:SetText(wlExact
            and string.format("|cffffd100%s|r is on your Soulforge whitelist, so it cannot be "
              .. "destroyed. Right-click the row to unprotect it.", (itemDisplay(s.entry)))
            or string.format("|cffffd100%s|r is protected by the whitelist entry |cffffffff%s|r, "
              .. "so it cannot be destroyed. Remove that entry in the Whitelist window first.",
              (itemDisplay(s.entry)), wl))
        else
          self.summary:SetText("Choose a piece of gear to pull an effect from.")
        end
      end

    else   -- ---- disabled effects [#1278] ----
      self.grid:Hide()
      for _, c in ipairs(self.cells) do c:Hide() end
      self.ulist:Hide()
      for _, r in ipairs(self.urows) do r:Hide() end
      self.tgtHead:Hide(); self.tscroll:Hide()
      for _, r in ipairs(self.trows) do r:Hide() end
      self.srcBtn:Hide(); self.wlBtn:Hide()
      self.actBtn:Hide(); self.summary:Hide()
      self.detTitle:Hide(); self.detSub:Hide()
      self.blist:Show()

      -- Same sentence the pop-out leads with, because it is the thing the
      -- original report (#688) was actually about: the client draws an item's
      -- tooltip from its own files, so a disabled effect still LOOKS live.
      self.sub:SetText("|cffb0b0b0Switched off on this realm. An item carrying one of these still "
        .. "shows it on its tooltip -- the client draws that from its own files -- but the effect "
        .. "does nothing, and it cannot be extracted or soulbound.|r")

      -- The tab's own search box drives the SAME filter function the pop-out
      -- uses, passed as an argument rather than by writing bpFilter, so the two
      -- windows cannot fight over one string.
      -- `or ""` matters: bpVisible treats nil as "use my own bpFilter", and
      -- state.exSearch is nil until the player types something. Without it an
      -- untouched search box would silently inherit the pop-out window's filter.
      local data = (bpAPI and bpAPI.visible(state.exSearch or "")) or {}

      self.blist.uncappedCount = #data
      FauxScrollFrame_Update(self.blist, #data, EXB_ROWS, EXB_H)
      local bo = clampOffset(self.blist, #data, EXB_ROWS)
      for i = 1, EXB_ROWS do
        local r, e = self.brows[i], data[i + bo]
        if e and bpAPI then
          bpAPI.paint(r, e)
          r:Show()
        else
          r.entry = nil; r:Hide()
        end
      end

      --[[ ★ [#1277] AN EMPTY LIST THAT SAYS WHICH KIND OF EMPTY IT IS.

           "Nothing here" and "the server refused the request and nobody told
           you" looked identical on every panel in this addon, and that is the
           whole reason four separate reports were filed for one throttle bug.
           Three distinguishable states, and the busy one is read live from
           UncappedThrottle rather than latched, so it clears itself. ]]
      local total = (bpAPI and bpAPI.count()) or 0
      if #data == 0 then
        local UT = _G.UncappedThrottle
        local txt
        if total > 0 then
          txt = "|cff808080Nothing matches that search.|r"
        elseif bpAPI and bpAPI.answered() then
          txt = "|cff808080Nothing is switched off on this realm right now.|r"
        elseif UT and UT.IsThrottled() then
          txt = "|cffffd100" .. (UT.StatusText() or "The server is busy.") .. "|r"
        else
          txt = "|cff808080Asking the server\226\128\166|r"
        end
        self.empty:SetText(txt)
        self.empty:Show()
      else
        self.empty:Hide()
      end
    end
  end

  EXT = f
  return f
end

-- Rebuild the source/target arrays from the staged ICEXI lines.
local function commitExtractItems()
  local sources, targets = {}, {}
  for _, it in pairs(state.exStaging) do
    -- Worn gear is still a valid TARGET -- stamping onto it is non-destructive.
    tinsert(targets, { bag = it.bag, slot = it.slot, entry = it.entry, equipped = it.equipped })

    --[[ ★★ BUT NEVER A SOURCE. Owner incident 2026-08-16: an equipped libram was
         unlocked by accident and destroyed with everything invested in it.

         Unlocking DESTROYS the item, and the list showed worn pieces looking
         exactly like the spare ones in your bags -- so the most dangerous row in
         the window was indistinguishable from the safe ones.

         ⚠ The server refuses these too (ItemCustomization::UnlockProc and
           ExtractProc both return "equipped"). This is the friendly half; that is
           the real gate. Take the item off if you genuinely mean to burn it.
    ]]
    if it.equipped ~= 1 then
      for _, pr in ipairs(it.procs) do
        tinsert(sources, { bag = it.bag, slot = it.slot, entry = it.entry, equipped = it.equipped,
                           spell = pr.spell, trigger = pr.trigger })
      end
    end
  end
  local function byName(a, b) return (itemDisplay(a.entry)) < (itemDisplay(b.entry)) end
  table.sort(sources, byName); table.sort(targets, byName)
  state.exSources = sources
  state.exTargets = targets
  -- [#1249] Ambiguity is judged over the collection and these rows TOGETHER --
  -- see rebuildProcNames. Both commit points have to refresh it, or a name that
  -- only becomes ambiguous once the second list arrives stays undisambiguated.
  rebuildProcNames()
  -- drop selections that no longer exist
  local function stillThere(list, sel, isSrc)
    if not sel then return nil end
    for _, d in ipairs(list) do
      if d.bag == sel.bag and d.slot == sel.slot and (not isSrc or d.spell == sel.spell) then return d end
    end
    return nil
  end
  state.exSelSrc = stillThere(sources, state.exSelSrc, true)
  state.exSelTgt = stillThere(targets, state.exSelTgt, false)
  if EXT and EXT:IsShown() then EXT:Refresh() end
end

local function openExtractor()
  BuildExtractor()
  state.exStaging = {}
  state.exMode = state.exMode or "coll"
  state.exFilter = state.exFilter or "all"
  EXT:Show()
  EXT:Refresh()
  send("ICEXSRC")   -- gear I carry, plus the ICEXD "finished" marks
  send("ICCOLL")    -- everything this ACCOUNT has unlocked
  send("ICWLIST")   -- the Soulforge whitelist, so the padlocks are right
end

-- ---- Scroll of Socket ----------------------------------------------------
--
-- Sockets have no identity: every one is prismatic, they are interchangeable, and
-- nothing ever refers to "socket 3". So an item's socket state is drawn as a capacity
-- bar plus one row per DISTINCT gem -- an item with 500 sockets is still three rows.
-- Gems go in by drag-and-drop (or in bulk with Fill), and come back out destroyed.
local SOCK, sockGearRows, sockGemRows = nil, {}, {}
local SG_ROWS, SG_H = 5, 30          -- gem rows in the right panel
local SOCK_FILTERS = { "Worn", "Bags", "All" }

-- Socket colours use the core's SocketColor bits, the same ones a gem's colour mask
-- uses: a gem fits a socket when they share a bit. Meta gems carry only bit 1, so a
-- meta socket is the only place they go -- and those roll rarely.
local SOCK_COLORS = { [1] = "meta", [2] = "red", [4] = "yellow", [8] = "blue" }
local SOCK_COLOR_ORDER = { 1, 2, 4, 8 }
local SOCK_COLOR_HEX = { [1] = "ffd0c0ff", [2] = "ffff4040", [4] = "ffffd020", [8] = "ff4080ff" }

local function colorName(c) return SOCK_COLORS[c] or ("colour " .. tostring(c)) end
local function colorText(c)
  return "|c" .. (SOCK_COLOR_HEX[c] or "ffffffff") .. colorName(c) .. "|r"
end


-- The gear row the panel is currently showing, refreshed in place by commitSocketItems.
local function sockSel() return state.sockSel end

-- The gem list is a plain windowed list rather than a FauxScrollFrame (no scrollbar to
-- draw, and it is only ever a few rows tall). An item with a hundred sockets can still
-- hold far more than SG_ROWS distinct gems, so it has to be scrollable -- without this
-- the rows past the fifth simply could not be reached.
local function scrollGems(delta)
  local sel = sockSel()
  if not sel then return end
  local maxOff = math.max(0, #sel.gems - SG_ROWS)
  local o = (state.sockGemOffset or 0) - delta
  if o < 0 then o = 0 elseif o > maxOff then o = maxOff end
  state.sockGemOffset = o
  if SOCK then SOCK:Refresh() end
end

local function sendFill(gemEntry, amount)
  local s = sockSel()
  if not s or not gemEntry then return end
  send(string.format("ICSOCKSET:%d:%d:%d:%d", s.bag, s.slot, gemEntry, amount or 1))
end

local function BuildSocketUI()
  if SOCK then return SOCK end
  local f = CreateFrame("Frame", "UncappedSocketFrame", UIParent)
  f:SetSize(620, 460)
  f:SetPoint("CENTER")
  f:SetFrameStrata("HIGH")
  f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 } })
  f:SetBackdropBorderColor(0.35, 0.75, 0.9, 1)
  f:EnableMouse(true); f:SetMovable(true); f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetClampedToScreen(true); f:Hide()
  tinsert(UISpecialFrames, "UncappedSocketFrame")   -- Esc closes it
  -- UIParent-parented pop-out: owns its own zoom (see BuildWhitelist above).
  if UncappedScale_Register then UncappedScale_Register(f, { group = "dashboard" }) end

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 22, -18); title:SetText("|cff59bfe6Sockets|r")

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -8, -8)

  -- ---- left: your gear ---------------------------------------------------
  local lh = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  lh:SetPoint("TOPLEFT", 22, -48); lh:SetText("YOUR GEAR")

  local filter = CreateFrame("EditBox", "UncappedSocketFilter", f, "InputBoxTemplate")
  filter:SetSize(140, 20); filter:SetPoint("TOPLEFT", 26, -64)
  filter:SetAutoFocus(false)
  filter:SetScript("OnTextChanged", function(self)
    state.sockFilter = (self:GetText() or ""):lower()
    if SOCK then SOCK:Refresh() end
  end)
  filter:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)

  local scope = KitButton(f, "", 56, 21)
   scope:SetPoint("LEFT", filter, "RIGHT", 8, 0)
  scope:SetScript("OnClick", function()
    local i = 1
    for k, v in ipairs(SOCK_FILTERS) do if v == state.sockScope then i = k end end
    state.sockScope = SOCK_FILTERS[(i % #SOCK_FILTERS) + 1]
    SOCK:Refresh()
  end)
  f.scopeBtn = scope

  local gearScroll = CreateFrame("ScrollFrame", "UncappedSocketGear", f, "FauxScrollFrameTemplate")
  gearScroll:SetPoint("TOPLEFT", 22, -92)
  gearScroll:SetSize(226, EXR_ROWS * EXR_H)
  gearScroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, EXR_H, function() if SOCK then SOCK:Refresh() end end)
  end)
  gearScroll.uncappedRowH = EXR_H
  gearScroll:SetScript("OnMouseWheel", function(self, delta)
    wheelScroll(self, delta, SOCK and SOCK.gearCount or 0, EXR_ROWS, EXR_H,
      function() if SOCK then SOCK:Refresh() end end)
  end)
  for i = 1, EXR_ROWS do
    local r = CreateFrame("Button", nil, f); r:SetSize(222, EXR_H - 2)
    if i == 1 then r:SetPoint("TOPLEFT", gearScroll, "TOPLEFT", 0, 0)
    else r:SetPoint("TOPLEFT", sockGearRows[i-1], "BOTTOMLEFT", 0, -2) end
    r.sel = r:CreateTexture(nil, "BACKGROUND")
    r.sel:SetAllPoints(); r.sel:SetTexture(0.25, 0.5, 0.7, 0.5); r.sel:Hide()
    local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetTexture(1, 1, 1, 0.12)
    r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(EXR_H - 8, EXR_H - 8)
    r.icon:SetPoint("LEFT", 2, 0)
    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 4, 5); r.name:SetWidth(150); r.name:SetJustifyH("LEFT")
    r.sub = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r.sub:SetPoint("LEFT", r.icon, "RIGHT", 4, -7); r.sub:SetWidth(150); r.sub:SetJustifyH("LEFT")
    r.count = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.count:SetPoint("RIGHT", -6, 0)
    r:SetScript("OnClick", function()
      if r.data then
        state.sockSel = r.data
        state.sockGemOffset = 0   -- a new item starts at the top of its gem list
        SOCK:Refresh()
      end
    end)
    r:Hide()
    sockGearRows[i] = r
  end
  f.gearScroll = gearScroll

  --[[ ⚠⚠ [#1277] THIS PANEL DREW NOTHING AT ALL WHEN THE LIST WAS EMPTY.

       No string, no placeholder, not even a greyed line -- so "the server threw
       your request away", "you own no socketable gear" and "your filter matches
       nothing" were one identical blank rectangle. That is the exact reason a
       throttle bug arrived as four separate reports about four features rather
       than as one report about the throttle.

       The three states are distinguished below in Refresh, and the busy one is
       read LIVE from UncappedThrottle rather than latched, so it clears itself
       without needing another event. ]]
  f.gearEmpty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.gearEmpty:SetPoint("TOPLEFT", gearScroll, "TOPLEFT", 2, -8)
  f.gearEmpty:SetWidth(218); f.gearEmpty:SetJustifyH("LEFT")
  f.gearEmpty:Hide()

  -- ---- left footer: colour tally ----------------------------------------
  f.tally = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.tally:SetPoint("TOPLEFT", 22, -104 - EXR_ROWS * EXR_H)
  f.tally:SetWidth(226); f.tally:SetJustifyH("LEFT")

  f.metaWarn = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.metaWarn:SetPoint("TOPLEFT", f.tally, "BOTTOMLEFT", 0, -6)
  f.metaWarn:SetWidth(226); f.metaWarn:SetJustifyH("LEFT")
  f.metaWarn:SetText("Each meta gem you wear multiplies EVERY meta's colour requirement.")

  -- ---- right: the selected item -----------------------------------------
  local RX = 268
  f.itemIcon = f:CreateTexture(nil, "ARTWORK"); f.itemIcon:SetSize(32, 32)
  f.itemIcon:SetPoint("TOPLEFT", RX, -48)
  f.itemName = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.itemName:SetPoint("TOPLEFT", RX + 38, -50); f.itemName:SetWidth(290); f.itemName:SetJustifyH("LEFT")
  f.itemSub = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.itemSub:SetPoint("TOPLEFT", RX + 38, -66); f.itemSub:SetWidth(290); f.itemSub:SetJustifyH("LEFT")

  local bar = CreateFrame("StatusBar", nil, f)
  bar:SetSize(328, 14); bar:SetPoint("TOPLEFT", RX, -90)
  bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  bar:SetStatusBarColor(0.25, 0.6, 0.85)
  bar:SetMinMaxValues(0, 1); bar:SetValue(0)
  local barBg = bar:CreateTexture(nil, "BACKGROUND"); barBg:SetAllPoints(); barBg:SetTexture(0, 0, 0, 0.5)
  bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  bar.text:SetPoint("CENTER")
  f.bar = bar

  -- Gem rows: one per distinct gem in the item, which is what keeps this readable
  -- whether the item has 3 sockets or 500.
  for i = 1, SG_ROWS do
    local r = CreateFrame("Button", nil, f); r:SetSize(328, SG_H - 2)
    if i == 1 then r:SetPoint("TOPLEFT", RX, -112)
    else r:SetPoint("TOPLEFT", sockGemRows[i-1], "BOTTOMLEFT", 0, -2) end
    local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetTexture(1, 1, 1, 0.1)
    r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(SG_H - 8, SG_H - 8)
    r.icon:SetPoint("LEFT", 4, 0)
    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0); r.name:SetWidth(196); r.name:SetJustifyH("LEFT")
    r.count = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.count:SetPoint("RIGHT", -34, 0)

    local minus = KitButton(r, "", 22, 20)
     minus:SetPoint("RIGHT", -4, 0); minus:SetText("-")
    minus:SetScript("OnClick", function()
      local d, s = r.data, sockSel()
      if not d or not s then return end
      local amount = IsShiftKeyDown() and d.count or 1
      StaticPopup_Show("UNCAPPED_SOCKET_REMOVE", (itemDisplay(d.entry)), tostring(amount),
        { bag = s.bag, slot = s.slot, entry = d.entry, amount = amount, color = d.color })
    end)
    r.minus = minus

    r:SetScript("OnEnter", function(self)
      if not self.data then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetHyperlink("item:" .. self.data.entry)
      if not self.data.active then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cffff8040INACTIVE|r", 1, 1, 1)
        local t = state.sockTally
        local mult = math.max(1, t.meta or 0)
        GameTooltip:AddLine(("You wear %d meta gem%s, so every meta's colour requirement is |cffff8040x%d|r.")
          :format(t.meta or 0, (t.meta == 1) and "" or "s", mult), 1, 0.82, 0, true)
        GameTooltip:AddLine(("You have %d red, %d yellow, %d blue."):format(t.red or 0, t.yellow or 0, t.blue or 0),
          0.7, 0.7, 0.7, true)
      end
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r:EnableMouseWheel(true)
    r:SetScript("OnMouseWheel", function(_, delta) scrollGems(delta) end)
    r:Hide()
    sockGemRows[i] = r
  end

  -- ---- drop zone ---------------------------------------------------------
  local drop = CreateFrame("Button", nil, f)
  drop:SetSize(328, 44); drop:SetPoint("TOPLEFT", RX, -112 - SG_ROWS * SG_H - 4)
  drop:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
                     bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", tile = true, tileSize = 8,
                     insets = { left = 3, right = 3, top = 3, bottom = 3 } })
  drop:SetBackdropColor(0, 0, 0, 0.35)
  drop:SetBackdropBorderColor(0.4, 0.6, 0.7, 0.8)
  drop.label = drop:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  drop.label:SetPoint("CENTER")
  drop.label:SetWidth(316); drop.label:SetJustifyH("CENTER")

  -- Dropping a gem here sockets it. Shift held = pour in as many as you own, which is
  -- the only sane way to fill an item that has a hundred empty sockets.
  local function acceptCursorGem()
    local kind, _, link = GetCursorInfo()
    if kind ~= "item" or not link then return end
    local entry = tonumber(link:match("item:(%d+)"))
    ClearCursor()
    if not entry then return end
    sendFill(entry, IsShiftKeyDown() and 0 or 1)
  end
  drop:SetScript("OnReceiveDrag", acceptCursorGem)
  drop:SetScript("OnClick", acceptCursorGem)
  f.drop = drop

  -- ---- bottom: add sockets / fill ---------------------------------------
  local addBtn = KitButton(f, "", 150, 26)
   addBtn:SetPoint("BOTTOMLEFT", RX, 44); addBtn:SetText("+ Add Socket")
  addBtn:SetScript("OnClick", function()
    local s = sockSel()
    if s then send(string.format("ICSOCKADD:%d:%d:%d", s.bag, s.slot, 1)) end
  end)
  f.addBtn = addBtn

  local function smallBtn(parent, text, w, amount)
    local b = KitButton(parent, "", nil, nil)
    b:SetSize(w, 20); b:SetText(text)
    b:SetScript("OnClick", function()
      local s = sockSel()
      if s then send(string.format("ICSOCKADD:%d:%d:%d", s.bag, s.slot, amount)) end
    end)
    return b
  end
  f.add10 = smallBtn(f, "x10", 40, 10); f.add10:SetPoint("BOTTOMLEFT", RX, 18)
  f.addAll = smallBtn(f, "x all", 48, 0); f.addAll:SetPoint("LEFT", f.add10, "RIGHT", 4, 0)

  local fillBtn = KitButton(f, "", 150, 26)
   fillBtn:SetPoint("BOTTOMRIGHT", -22, 44); fillBtn:SetText("Fill Empty")
  fillBtn:SetScript("OnClick", function() sendFill(state.sockFillGem, 0) end)
  f.fillBtn = fillBtn

  -- Which gem "Fill Empty" pours in. Populated from the gems in your bags.
  local dd = CreateFrame("Frame", "UncappedSocketFillDrop", f, "UIDropDownMenuTemplate")
  dd:SetPoint("BOTTOMRIGHT", -8, 8)
  UIDropDownMenu_SetWidth(dd, 130)
  UIDropDownMenu_Initialize(dd, function()
    for _, g in ipairs(state.sockGems) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = string.format("%s (%d)", (itemDisplay(g.entry)), g.held)
      info.func = function()
        state.sockFillGem = g.entry
        UIDropDownMenu_SetText(dd, (itemDisplay(g.entry)))
        CloseDropDownMenus()
        SOCK:Refresh()
      end
      UIDropDownMenu_AddButton(info)
    end
  end)
  UIDropDownMenu_SetText(dd, "choose a gem")
  f.fillDrop = dd

  f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.hint:SetPoint("BOTTOMLEFT", 22, 20); f.hint:SetWidth(226); f.hint:SetJustifyH("LEFT")

  -- ---- render ------------------------------------------------------------
  local function visibleGear()
    local out = {}
    local scope, filt = state.sockScope, state.sockFilter
    for _, d in ipairs(state.sockItems) do
      local okScope = (scope == "All")
        or (scope == "Worn" and d.equipped == 1)
        or (scope == "Bags" and d.equipped == 0)
      local okFilt = (not filt or filt == "") or ((itemDisplay(d.entry)):lower():find(filt, 1, true) ~= nil)
      if okScope and okFilt then tinsert(out, d) end
    end
    return out
  end

  function f:Refresh()
    local gear = visibleGear()
    -- The wheel handler needs the rendered count to clamp against.
    self.gearCount = #gear
    FauxScrollFrame_Update(self.gearScroll, #gear, EXR_ROWS, EXR_H)
    local go = clampOffset(self.gearScroll, #gear, EXR_ROWS)
    local sel = sockSel()
    for i = 1, EXR_ROWS do
      local d = gear[i + go]
      local r = sockGearRows[i]
      if d then
        r.data = d
        local nm, tex, cr, cg, cb = itemDisplay(d.entry)
        r.icon:SetTexture(tex)
        r.name:SetText(nm); r.name:SetTextColor(cr, cg, cb)
        r.sub:SetText(d.equipped == 1 and "|cff40ff40worn|r" or "in bags")
        if d.capacity > 0 then
          r.count:SetText(string.format("|cff59bfe6%d|r/%d", d.capacity - d.empty, d.capacity))
        else
          r.count:SetText("|cff606060--|r")
        end
        if sel and sel.bag == d.bag and sel.slot == d.slot then r.sel:Show() else r.sel:Hide() end
        r:Show()
      else
        r.data = nil; r:Hide()
      end
    end

    -- [#1277] Say WHICH kind of empty this is. See gearEmpty above.
    if #gear == 0 then
      local st = state.sockState
      local UT = _G.UncappedThrottle
      local txt
      if st == "failed" then
        txt = "|cffff8040The server did not answer.|r\n\n|cff808080Close this window and open it "
           .. "again in a moment. If it keeps happening, /uthrottle will say whether the server is "
           .. "dropping your requests.|r"
      elseif st == "retrying" or (st ~= "ready" and UT and UT.IsThrottled()) then
        txt = "|cffffd100" .. ((UT and UT.StatusText()) or "The server is busy.") .. "|r"
      elseif st ~= "ready" then
        txt = "|cff808080Loading your gear\226\128\166|r"
      elseif (state.sockFilter or "") ~= "" then
        txt = "|cff808080Nothing matches that search.|r"
      elseif state.sockScope ~= "All" then
        txt = "|cff808080No socketable gear " .. (state.sockScope == "Worn" and "equipped" or "in your bags")
           .. ".|r\n\n|cff808080Press |cffffffff" .. state.sockScope .. "|r|cff808080 above to widen the scope.|r"
      else
        txt = "|cff808080No weapons or armour found.|r\n\n|cff808080Any weapon or armour piece can be "
           .. "socketed with a Scroll of Socket -- it does not need to have sockets already.|r"
      end
      self.gearEmpty:SetText(txt)
      self.gearEmpty:Show()
    else
      self.gearEmpty:Hide()
    end

    self.scopeBtn:SetText(state.sockScope)

    local t = state.sockTally
    self.tally:SetText(string.format("YOUR GEMS   meta |cffffffff%d|r  |cffff4040red|r %d  |cffffd020yel|r %d  |cff4080ff blue|r %d",
      t.meta or 0, t.red or 0, t.yellow or 0, t.blue or 0))
    local mult = math.max(1, t.meta or 0)
    self.metaWarn:SetText("Each meta gem you wear multiplies EVERY meta's colour requirement. "
      .. ("Wearing %d |cff59bfe6-> x%d|r"):format(t.meta or 0, mult))

    -- ⚠ THE SERVER'S COUNT, NOT GetItemCount. The Scroll of Socket is not on the bag
    --   whitelist, so "Deposit Items" moves it into the Vault -- and the Vault is
    --   invisible to Lua's GetItemCount. Measured 2026-08-22: 75 of the realm's 113
    --   scrolls were in the Vault against 38 in bags, so this line read "0" and the
    --   three Add buttons below were dead for two thirds of every scroll on the realm.
    --   ICSOCKSCROLLS is the same GetDestroyableItemCount(..., includeVault) that
    --   ICSOCKADD spends from, so what is shown and what is paid are one number.
    --
    --   ★ Unlike the Extraction panel above, the bag scan is kept as a FALLBACK and
    --     that difference is deliberate: an extraction scroll is absorbed into a
    --     server-side balance, so GetItemCount there is meaningless, while a socket
    --     scroll is still a real item. nil means "not told yet" -- against a server
    --     too old to send the verb, the bag count is the honest answer, not zero.
    local scrolls = state.sockScrolls or GetItemCount(500209) or 0
    self.hint:SetText(("|cff59bfe6%d|r Scroll%s of Socket."):format(scrolls, scrolls == 1 and "" or "s"))

    -- right panel
    if not sel then
      self.itemIcon:SetTexture(QUESTION)
      self.itemName:SetText("|cff808080Choose an item on the left|r")
      self.itemSub:SetText("")
      self.bar:SetValue(0); self.bar.text:SetText("")
      for i = 1, SG_ROWS do sockGemRows[i].data = nil; sockGemRows[i]:Hide() end
      self.drop.label:SetText("|cff606060select an item first|r")
      self.addBtn:Disable(); self.add10:Disable(); self.addAll:Disable(); self.fillBtn:Disable()
      return
    end

    local nm, tex, cr, cg, cb = itemDisplay(sel.entry)
    self.itemIcon:SetTexture(tex)
    self.itemName:SetText(nm); self.itemName:SetTextColor(cr, cg, cb)
    self.itemSub:SetText(sel.equipped == 1 and "Worn" or "In your bags")

    local filled = sel.capacity - sel.empty
    self.bar:SetMinMaxValues(0, math.max(1, sel.capacity))
    self.bar:SetValue(filled)
    self.bar.text:SetText(string.format("%d / %d sockets", filled, sel.capacity))

    -- gem rows, biggest stack first
    local rows = {}
    for _, g in ipairs(sel.gems) do
      tinsert(rows, { entry = g.entry, count = g.count, active = g.active, color = g.color })
    end
    table.sort(rows, function(a, b)
      if a.count ~= b.count then return a.count > b.count end
      return (itemDisplay(a.entry)) < (itemDisplay(b.entry))
    end)
    -- Window the gem rows, clamping a stale offset after the list shrank.
    local gemMax = math.max(0, #rows - SG_ROWS)
    if (state.sockGemOffset or 0) > gemMax then state.sockGemOffset = gemMax end
    local gemOff = state.sockGemOffset or 0

    for i = 1, SG_ROWS do
      local d = rows[i + gemOff]
      local r = sockGemRows[i]
      if d then
        r.data = d
        local gnm, gtex, gr, gg, gb = itemDisplay(d.entry)
        r.icon:SetTexture(gtex)
        r.icon:SetDesaturated(not d.active)
        local pip = "|c" .. (SOCK_COLOR_HEX[d.color] or "ffffffff") .. "*|r "
        if d.active then
          r.name:SetText(pip .. gnm); r.name:SetTextColor(gr, gg, gb)
        else
          r.name:SetText(pip .. gnm .. "  |cffff8040(inactive)|r"); r.name:SetTextColor(0.6, 0.6, 0.6)
        end
        r.count:SetText("|cffffffffx" .. d.count .. "|r")
        r:Show()
      else
        r.data = nil; r:Hide()
      end
    end
    -- The drop zone doubles as the empty-socket readout, broken out by colour: which
    -- colours you have free is the only thing that decides what you can socket.
    if #rows > SG_ROWS then
      self.drop.label:SetText(("|cffb0b0b0showing gems %d-%d of %d -- scroll the list|r")
        :format(gemOff + 1, math.min(gemOff + SG_ROWS, #rows), #rows))
    elseif sel.empty > 0 then
      local parts = {}
      for _, c in ipairs(SOCK_COLOR_ORDER) do
        local n = sel.emptyBy[c]
        if n and n > 0 then
          tinsert(parts, ("|c%s%d %s|r"):format(SOCK_COLOR_HEX[c] or "ffffffff", n, colorName(c)))
        end
      end
      self.drop.label:SetText(("drag a gem here -- empty: %s\n|cff606060(shift = fill)|r")
        :format(table.concat(parts, "  ")))
    else
      self.drop.label:SetText("|cff606060no empty sockets|r")
    end

    if scrolls > 0 then self.addBtn:Enable(); self.add10:Enable(); self.addAll:Enable()
    else self.addBtn:Disable(); self.add10:Disable(); self.addAll:Disable() end
    if sel.empty > 0 and state.sockFillGem then self.fillBtn:Enable() else self.fillBtn:Disable() end
  end

  SOCK = f
  return f
end

-- Rebuild the gear list from the staged ICSOCKI / ICSOCKG lines.
local function commitSocketItems()
  -- [#1277] ICSOCKEND is the LAST line of the burst, which is why the panel
  -- leaves its "loading" state here and not when the first ICSOCKI lands: a
  -- half-arrived list is still not an answer.
  state.sockState = "ready"
  local UT = _G.UncappedThrottle
  if UT and UT.Settled then UT.Settled("socket-open") end

  -- [#1277] The legacy rung of the re-ask ladder sends ICSOCKLIST ALONE and parks
  -- its companion here. ICSOCKLIST is the half that ends in this ICSOCKEND, so it
  -- is the half that unblocks the panel; ICSOCKBAG produces its own
  -- ICSOCKGEM/ICSOCKGEMEND burst and settles nothing. Sending the second one now
  -- rather than beside the first keeps every rung at 6 tokens instead of 12, and
  -- it only goes out once we have proof the bucket had room for the first.
  if state.sockLegacyBag then
    state.sockLegacyBag = false
    send("ICSOCKBAG")
  end

  local items = {}
  for _, it in pairs(state.sockStaging) do tinsert(items, it) end
  table.sort(items, function(a, b)
    if a.equipped ~= b.equipped then return a.equipped > b.equipped end   -- worn first
    if a.capacity ~= b.capacity then return a.capacity > b.capacity end
    return (itemDisplay(a.entry)) < (itemDisplay(b.entry))
  end)
  state.sockItems = items

  -- Re-point the selection at the refreshed row so its gem list is the new one.
  if state.sockSel then
    local found
    for _, d in ipairs(items) do
      if d.bag == state.sockSel.bag and d.slot == state.sockSel.slot then found = d; break end
    end
    state.sockSel = found
  end
  if SOCK and SOCK:IsShown() then SOCK:Refresh() end
end

--[[ ★★ [#1277] ONE VERB, NOT TWO HEAVY ONES IN THE SAME FRAME.

     This used to send ICSOCKLIST and ICSOCKBAG back to back. Both are HEAVY on
     the server's inbound throttle (6 tokens each), so TWELVE tokens had to be
     banked at the instant of the click, out of a 60-token burst that refills at
     6 per second. Anyone who had zoned in, opened another panel, or simply
     played during the preceding two seconds had one or both silently thrown
     away -- and the socket window drew an empty gear list with no explanation
     whatsoever.

     ICSOCKWIN runs both senders server-side and is priced ONCE, at 8: more than
     a single heavy verb because it genuinely is more work, less than two
     because one inventory walk feeds both replies.

  ⚠ The OLD pair is not dead code. The ladder below still falls back to it,
    because it covers a second failure mode as well as the first: a client that
    has taken this addon publish talking to a server that has not yet taken the
    matching build. This realm ships those on separate cadences and has shipped
    them out of order before. ]]
local function sockRequestMerged()
  send("ICSOCKWIN")
end

-- The old pair, SPLIT. ICSOCKLIST is the half that ends in ICSOCKEND and so the
-- half that unblocks the panel; commitSocketItems sends the companion ICSOCKBAG
-- once this one has actually been answered.
local function sockRequestLegacyList()
  state.sockLegacyBag = true
  send("ICSOCKLIST")
end

--[[ ★★ [#1277] THE RE-ASK LADDER, AND WHY NO RUNG COSTS MORE THAN THE FIRST ASK.

     The first version of this retried with the legacy pair in one frame:
     ICSOCKLIST + ICSOCKBAG, 6 + 6 = 12 tokens, sent to answer a bucket that had
     just refused an 8-token ICSOCKWIN. On the per-player bucket the backoff
     usually covered the difference. On the SHARED-ADDRESS bucket -- a household,
     a dual-boxer, anyone behind CGNAT, which is the bucket most likely to have
     refused in the first place -- it did not: the fallback was strictly more
     expensive than the thing that had just been denied, so the retry was more
     likely to be dropped than the original.

     Each rung is now at most what the first ask cost:

       1  ICSOCKWIN            8   exactly what was refused; the right retry for
                                   a drop, which is the common case by far
       2  ICSOCKLIST           6   cheaper, AND the only rung a server without
                                   ICSOCKWIN understands. Its ICSOCKBAG follows
                                   from commitSocketItems, in a later frame.
       3  (sends nothing)      0   see below

  ★ RUNG 3 SENDS NOTHING ON PURPOSE. UncappedThrottle's tick() calls onGiveUp in
    the SAME frame as the final attempt, so with a two-rung ladder the panel
    painted "The server did not answer" the instant the last request went out --
    before any reply could possibly have come back. A third rung that sends
    nothing buys rung 2 a full backoff interval (>= 8s here, and never less than
    the server's own retry-after) to be answered before the panel calls it. ]]
local sockReaskLadder =
{
  sockRequestMerged,
  sockRequestLegacyList,
  function() end,
}

local function openSockets()
  BuildSocketUI()
  state.sockStaging = {}
  state.sockLegacyBag = false
  state.sockRung = 0
  state.sockState = "loading"
  SOCK:Show()
  SOCK:Refresh()
  sockRequestMerged()

  -- [#1277] If that is dropped, walk the ladder above and only then say so,
  -- rather than sitting on an empty list forever. Settled() in commitSocketItems
  -- cancels the whole thing the moment the real reply lands.
  local UT = _G.UncappedThrottle
  if UT and UT.Reask then
    UT.Reask("socket-open", function()
      state.sockRung = (state.sockRung or 0) + 1
      local rung = sockReaskLadder[state.sockRung]
      if not rung then return end

      -- The silent last rung must not repaint: there is nothing new to report.
      if state.sockRung < #sockReaskLadder then
        state.sockState = "retrying"
        if SOCK and SOCK:IsShown() then SOCK:Refresh() end
      end

      rung()
    end, { tries = #sockReaskLadder, base = 3, maxDelay = 8, onGiveUp = function()
      -- Guarded: a reply that landed while the ladder was running has already
      -- set "ready", and must not be overwritten with a failure.
      if state.sockState ~= "ready" then
        state.sockState = "failed"
        if SOCK and SOCK:IsShown() then SOCK:Refresh() end
      end
    end })
  end
end

-- ============================ banned procs [#688] =========================
-- Des: "a better way to view the banned procs list would be nice. as it stands
-- we just have item ID numbers in a chat list."
--
-- The register itself is a compile-time constant on the server
-- (s_procSpellBlacklist) and always was -- what was missing was a way to READ
-- it. `.bannedprocs list` pages it 15 at a time into the chat frame with a name
-- and nothing else, so a player whose weapon had gone quiet got a name they
-- already knew and no reason.
--
-- ★ NAMES AND ICONS ARE RESOLVED HERE, NOT SENT. GetSpellInfo(id) reads the
--   client's own Spell.dbc, which is the same file the server reads
--   (patch-enUS-U is kept in step with it), so they cannot disagree -- and it
--   keeps a ~150-entry register down to about fifteen addon messages instead of
--   one per spell. A spell the client cannot resolve degrades to "Spell #<id>"
--   with the default question-mark icon rather than being dropped: an
--   unresolvable row still tells the player that id is switched off, which is
--   the whole point of the list.
local BP, bpRows = nil, {}
local BP_ROWS, BP_H = 14, 22
local bpReasons = {}          -- index -> sentence, replaced wholesale per burst
local bpEntries = {}          -- { spellId, reasonIdx, name } committed on ICBPEND
local bpStaging = nil
local bpFilter = ""
-- [#1278] Has a burst ever landed? An EMPTY register and a register we have not
-- been told about yet look identical, and the Disabled sub-tab has to render a
-- different sentence for each -- that indistinguishability is the shape behind
-- every "the feature is empty" report this pass closes.
local bpAnswered = false

-- Cheap and safe: GetSpellInfo returns nil for anything the client's DBC has no
-- row for, which is the only failure mode worth handling here.
local function bpSpellName(id)
  local name = GetSpellInfo and GetSpellInfo(id)
  return name or ("Spell #" .. tostring(id))
end

local function bpSpellIcon(id)
  local _, _, icon = GetSpellInfo and GetSpellInfo(id)
  return icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- [#1278] The query is a PARAMETER now. The pop-out passes nothing and keeps
-- using its own bpFilter exactly as before; the Extraction tab's Disabled
-- sub-tab passes its own search string. One filter, two windows, and neither can
-- overwrite the other's search box -- which is what sharing bpFilter would have
-- done the first time someone typed in either of them.
local function bpVisible(query)
  if query == nil then query = bpFilter end
  if query == "" then return bpEntries end
  local out = {}
  for _, e in ipairs(bpEntries) do
    local reason = bpReasons[e.reasonIdx] or ""
    if e.name:lower():find(query, 1, true) or reason:lower():find(query, 1, true) then
      tinsert(out, e)
    end
  end
  return out
end

-- [#1278] One row of the register, painted. Factored out of BuildBannedProcs so
-- the Extraction tab draws its rows through exactly this code rather than a
-- second copy that can drift. A "row" is anything carrying .icon/.name/.reason.
local function bpPaintRow(row, e)
  row.entry = e
  row.icon:SetTexture(bpSpellIcon(e.spellId))
  row.name:SetText("|cffffffff" .. e.name .. "|r")
  row.reason:SetText(bpReasons[e.reasonIdx] or "Disabled on this realm.")
end

-- The reason is truncated to one line in the row, so the full sentence -- and
-- the spell id, which is what anyone reporting a problem will be asked for --
-- lives on the tooltip.
local function bpRowTooltip(row)
  local e = row.entry
  if not e then return end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine(e.name, 1, 0.82, 0)
  GameTooltip:AddLine("Spell ID " .. tostring(e.spellId), 0.6, 0.6, 0.6)
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine(bpReasons[e.reasonIdx] or "Disabled on this realm.", 1, 1, 1, true)
  GameTooltip:Show()
end

local function BuildBannedProcs()
  if BP then return BP end

  local f = CreateFrame("Frame", "UncappedBannedProcsFrame", UIParent)
  f:SetSize(640, 420)
  f:SetPoint("CENTER")
  f:SetFrameStrata("HIGH")
  f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 } })
  f:SetBackdropBorderColor(0.35, 0.75, 0.9, 1)
  f:EnableMouse(true); f:SetMovable(true); f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetClampedToScreen(true); f:Hide()
  tinsert(UISpecialFrames, "UncappedBannedProcsFrame")   -- Esc closes it
  -- UIParent-parented pop-out: owns its own zoom, same as the Socket and
  -- Whitelist windows.
  if UncappedScale_Register then UncappedScale_Register(f, { group = "dashboard" }) end

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 22, -18); title:SetText("|cff59bfe6Disabled Effects|r")

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -8, -8)

  local blurb = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  blurb:SetPoint("TOPLEFT", 22, -46); blurb:SetPoint("TOPRIGHT", -22, -46)
  blurb:SetJustifyH("LEFT")
  -- Says the thing the report was really about: the tooltip is built by the
  -- CLIENT from its own item cache, so an item whose effect is switched off here
  -- still reads as if it works. Nothing is wrong with the item.
  blurb:SetText("|cffb0b0b0These effects are switched off on this realm. An item carrying one still shows it on "
    .. "its tooltip -- the client draws that from its own files and the server cannot edit it -- but the effect "
    .. "does nothing, and it cannot be extracted or soulbound.|r")

  local filter = CreateFrame("EditBox", "UncappedBannedProcsFilter", f, "InputBoxTemplate")
  filter:SetSize(200, 20); filter:SetPoint("TOPLEFT", 26, -92)
  filter:SetAutoFocus(false)
  filter:SetScript("OnTextChanged", function(self)
    bpFilter = (self:GetText() or ""):lower()
    if BP and BP:IsShown() then BP:Refresh() end
  end)
  filter:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)

  local filterHint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  filterHint:SetPoint("LEFT", filter, "RIGHT", 10, 0)
  filterHint:SetText("search by effect name or reason")

  local count = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  count:SetPoint("TOPRIGHT", -24, -92); count:SetJustifyH("RIGHT")
  f.count = count

  local scroll = CreateFrame("ScrollFrame", "UncappedBannedProcsScroll", f, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 24, -120); scroll:SetPoint("BOTTOMRIGHT", -34, 20)
  scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, BP_H, function() if BP then BP:Refresh() end end)
  end)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local sb = _G["UncappedBannedProcsScrollScrollBar"]
    if sb then sb:SetValue(sb:GetValue() - delta * BP_H) end
  end)
  f.scroll = scroll

  for i = 1, BP_ROWS do
    local row = CreateFrame("Button", nil, f)
    row:SetHeight(BP_H)
    row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(i - 1) * BP_H)
    row:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 0, -(i - 1) * BP_H)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18); row.icon:SetPoint("LEFT", 0, 0)
    -- Trim the stock icon border so a 18px icon does not read as a grey box.
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetWidth(180); row.name:SetJustifyH("LEFT")

    row.reason = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.reason:SetPoint("LEFT", row.name, "RIGHT", 8, 0)
    row.reason:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.reason:SetJustifyH("LEFT")

    row:SetScript("OnEnter", bpRowTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row:Hide()
    bpRows[i] = row
  end

  function f:Refresh()
    local data = bpVisible()

    FauxScrollFrame_Update(self.scroll, #data, BP_ROWS, BP_H)
    local offset = FauxScrollFrame_GetOffset(self.scroll) or 0

    for i = 1, BP_ROWS do
      local row = bpRows[i]
      local e = data[i + offset]
      if e then
        bpPaintRow(row, e)
        row:Show()
      else
        row.entry = nil
        row:Hide()
      end
    end

    if #bpEntries == 0 then
      self.count:SetText("|cff808080waiting for the server\226\128\166|r")
    elseif bpFilter ~= "" then
      self.count:SetText(string.format("|cffffd100%d|r of %d effects", #data, #bpEntries))
    else
      self.count:SetText(string.format("|cffffd100%d|r effects", #bpEntries))
    end
  end

  BP = f
  return f
end

-- Commit the staged burst. Sorted by reason group then name, so the list reads
-- as the categories it actually is rather than as spell-id order, which means
-- nothing to anyone.
local function commitBannedProcs()
  if not bpStaging then return end
  bpReasons = bpStaging.reasons
  bpEntries = bpStaging.entries
  bpStaging = nil
  bpAnswered = true

  -- [#1277] The burst arrived, so stop the bounded re-ask. Harmless when no
  -- re-ask is outstanding, which is the common case.
  local UT = _G.UncappedThrottle
  if UT and UT.Settled then UT.Settled("banned-procs") end

  for _, e in ipairs(bpEntries) do e.name = bpSpellName(e.spellId) end
  table.sort(bpEntries, function(a, b)
    if a.reasonIdx ~= b.reasonIdx then return a.reasonIdx < b.reasonIdx end
    return a.name < b.name
  end)

  if BP and BP:IsShown() then BP:Refresh() end
  -- [#1278] The Extraction tab's Disabled sub-tab renders the same register, and
  -- is very often the surface that asked for it.
  if EXT and EXT:IsShown() and state.exMode == "banned" then EXT:Refresh() end
end

local function openBannedProcs()
  BuildBannedProcs()
  BP:Show()
  BP:Refresh()
  send("ICBPGET")
end

--[[ ★★ [#1278] FILLING IN THE HOLDER DECLARED AT THE TOP OF THE FILE.

     Read the comment on `local bpAPI` up there before touching this: the whole
     reason it is a forward declaration is that BuildExtractor is defined ~1,300
     lines above these functions, and a closure that names a local declared below
     it silently reads a nil GLOBAL instead.

     Everything here is a REFERENCE to the pop-out's own machinery, never a copy.
     If a future change makes the two lists disagree, it will be because
     something was added beside this table rather than inside it. ]]
bpAPI = {
    visible  = bpVisible,
    paint    = bpPaintRow,
    tip      = bpRowTooltip,
    -- Functions rather than values: both tables are REPLACED wholesale by
    -- commitBannedProcs, so capturing them here would freeze the empty ones the
    -- file loaded with.
    count    = function() return #bpEntries end,
    answered = function() return bpAnswered end,
}

-- ============================ receive =====================================
local function OnLine(body)
  dbg("<- " .. body)
  local cmd, rest = body:match("^(%u+):?(.*)$")
  if not cmd then cmd = body; rest = "" end

  if cmd == "ICSF" then                 -- <extractPctx100>:<fillPctx10>:<completions>:<autoconsume>:<autoopen>
    local mp, fp, comp, ac, ao = rest:match("^(%d+):(%d+):(%d+):(%d+):(%d+)$")
    if mp then
      state.sf.mult = tonumber(mp) / 100
      state.sf.fill = tonumber(fp) / 10
      state.sf.completions = tonumber(comp)
      state.sf.autoconsume = ac == "1"
      state.sf.autoopen = tonumber(ao) or 0
      if UI then UI:RefreshForge() end
    end
  elseif cmd == "ICSACKS" then          -- <held>:<mode>:<perSweep>:<burstMax>:<burstCooldown>:<burstCooldownLeft>
    -- Its own verb rather than three more fields on ICSF, because the ICSF
    -- pattern above is ANCHORED: widening it would make an older addon fail the
    -- match and stop drawing the whole panel. An unknown verb just falls off the
    -- end of this chain, which is the failure mode we want in both directions.
    --
    -- A NEW addon against an OLD server never receives this line, and that
    -- silence is load-bearing: the off and melt rows still work (they ride ICSF
    -- and mean the same thing on both servers), the count and the burst button
    -- stay inert because nothing ever populates them, and KEEP stays locked --
    -- see serverKeepOk. That last one is the whole point; the rest is fallout.
    local held, mode, per, cap, cd, left = rest:match("^(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)$")
    if held then
      -- ★ THE HANDSHAKE. Only a server that knows mode 2 sends this verb at all,
      --   so receiving one -- and only receiving one -- unlocks KEEP. Set from
      --   the parsed branch, not from the verb alone, so a truncated or
      --   malformed line cannot unlock it either.
      serverKeepOk = true

      state.sf.sackHeld = tonumber(held)
      state.sf.autoopen = tonumber(mode) or 0
      state.sf.sackPerTick = tonumber(per)
      state.sf.sackBurstMax = tonumber(cap)
      state.sf.sackBurstCd = tonumber(cd)

      -- The server sends how many seconds are LEFT; the button counts down off a
      -- local deadline so it keeps ticking between pushes (with the mode off
      -- there are no periodic pushes at all).
      local remain = tonumber(left) or 0
      if UI and UI.RefreshSacks then
        if UI.sackOpenBtn then
          UI.sackOpenBtn.readyAt = (remain > 0) and (GetTime() + remain) or nil
        end
        UI:RefreshSacks()
      end
    end
  elseif cmd == "ICACWARN" then         -- <secondsToConfirm>
    -- The server has armed a confirmation and changed nothing yet. Say plainly
    -- what enabling this does; the wording is deliberately blunt, because the
    -- old one-line checkbox was not and people lost gear to it.
    -- Match the server's arm window, so the popup cannot outlive the confirmation
    -- it would send.
    StaticPopupDialogs["UNCAPPED_SF_AUTOCONSUME"].timeout = tonumber(rest) or 60
    StaticPopup_Show("UNCAPPED_SF_AUTOCONSUME")
  elseif cmd == "ICVR" then             -- [#812] <stacks>:<pieces>:<souls>:<armSeconds>
    -- The forecast, and the ONLY thing that raises the confirmation. `arm` is the
    -- server's own confirmation window in seconds, 0 meaning "there is nothing to
    -- agree to" -- so a reply of zeroes silences the dialog without any client-side
    -- rule about when the button should be inert.
    --
    -- ⚠ The popup's timeout is set FROM the server's arm, never hardcoded, for the
    --   same reason ICACWARN does it: a dialog that outlives the arm behind it
    --   sends a confirm that is refused, and the player is told "that expired" by
    --   a box that was still on their screen.
    local st, pc, sl, arm = rest:match("^(%d+):(%d+):(%d+):(%d+)$")
    if st then
      renderWaitSince = nil
      state.vr.stacks = tonumber(st) or 0
      state.vr.pieces = tonumber(pc) or 0
      state.vr.souls  = tonumber(sl) or 0
      if UI and UI.RefreshRender then UI:RefreshRender() end

      local secs = tonumber(arm) or 0
      if secs > 0 then
        StaticPopupDialogs["UNCAPPED_SF_RENDER_JUNK"].timeout = secs
        StaticPopup_Show("UNCAPPED_SF_RENDER_JUNK",
          groupDigits(state.vr.pieces), groupDigits(state.vr.souls))
      end
    end
  elseif cmd == "ICVRDONE" then         -- [#812] <stacks>:<pieces>:<souls>
    -- The server already spoke the full summary in chat (destruction is never
    -- silent -- #134), so this only clears the forecast and redraws. Adding a
    -- second sentence here would be the same event reported twice, and the
    -- Ding()/sound cue belongs to ICSFDING alone -- it means "the forge levelled",
    -- not "something was eaten", and firing it on every press would make the one
    -- moment worth noticing indistinguishable from the ordinary one.
    local st, pc, sl = rest:match("^(%d+):(%d+):(%d+)$")
    if st then
      state.vr.stacks, state.vr.pieces, state.vr.souls = 0, 0, 0
      if UI and UI.RefreshRender then UI:RefreshRender() end
      dbg("rendered", st, pc, sl)
    end
  elseif cmd == "ICSFDING" then         -- <levelsGained>
    if UI then UI:Ding() end
    msg("|cff9CC243The Soulforge grows stronger!|r Extraction is now higher.")
  elseif cmd == "ICWL" then             -- <name>
    table.insert(state.wlStaging, rest)
  elseif cmd == "ICWLEND" then
    state.whitelist = state.wlStaging
    state.wlStaging = {}
    -- ★ A lowercase SET beside the list. The extraction window asks "is this item
    --   protected?" once per visible row on every refresh, and a linear scan of
    --   the list per row per redraw is the kind of thing that only shows up as
    --   lag once someone has a long whitelist.
    state.wlSet = {}
    for _, n in ipairs(state.whitelist) do state.wlSet[tostring(n):lower()] = true end
    -- [#1249] The substring memo wlProtectedBy builds is only valid for the list
    -- it was built from. This is the one moment that list changes, so it is the
    -- one place the memo has to go.
    state.wlMatch = {}
    if WLM then WLM:Update() end
    if EXT and EXT:IsShown() then EXT:Refresh() end
  elseif cmd == "ICINAME" then          -- <name>  item-name search hit
    table.insert(state.wlSuggestStaging, rest)
  elseif cmd == "ICINAMEEND" then
    state.wlSuggest = state.wlSuggestStaging
    state.wlSuggestStaging = {}
    if WLM then WLM:UpdateSuggest() end
    -- [DE-04] The wire is free. Anything typed while this was outstanding goes now.
    wlSearchAnswered()
  elseif cmd == "ICITEM" then
    sbCurKey = rest
    sbStaging[rest] = { stats = {}, procs = {}, vestiges = 0, vestigeMult = 100 }
  elseif cmd == "ICIVEST" then
    -- <count>:<multPct> -- duplicates this item has absorbed, and what they are worth.
    -- Sent only when the count is non-zero and on its own line, so older addon builds
    -- ignore it rather than losing the item (same shape as ICIPROCBP).
    local n, m = rest:match("^(%d+):(%d+)$")
    if n and sbCurKey and sbStaging[sbCurKey] then
      sbStaging[sbCurKey].vestiges = tonumber(n)
      sbStaging[sbCurKey].vestigeMult = tonumber(m)
    end
  elseif cmd == "ICISTAT" then
    local t, v = rest:match("^(%d+):(%-?%d+)$")
    if t and sbCurKey and sbStaging[sbCurKey] then
      table.insert(sbStaging[sbCurKey].stats, { type = tonumber(t), value = v })
    end
  elseif cmd == "ICIPROC" then
    -- <spell>:<trig>:<chancePct>:<magPct>[:<summonCap>]. The cap field is newer than
    -- the addon, so fall back to the 4-field form rather than dropping the line.
    local sid, tr, ch, mg, sc = rest:match("^(%d+):(%d+):(%d+):(%d+):(%d+)$")
    if not sid then
      sid, tr, ch, mg = rest:match("^(%d+):(%d+):(%d+):(%d+)$")
    end
    if sid and sbCurKey and sbStaging[sbCurKey] then
      table.insert(sbStaging[sbCurKey].procs,
        { spellId = tonumber(sid), trigger = tonumber(tr), chance = tonumber(ch), mag = tonumber(mg),
          summonCap = tonumber(sc) or 0, bases = {} })
    end
  elseif cmd == "ICIPROCBP" then
    -- <v1>:<v2>:... -- variable-length list of unscaled values that may appear in the
    -- rendered tooltip for the ICIPROC just before it, gathered by the server across the
    -- spell's own effects and the ones it triggers. Sent as its own line so older addon
    -- builds ignore it rather than losing the proc.
    local v = {}
    for n in rest:gmatch("(%d+)") do v[#v+1] = tonumber(n) end
    if #v >= 1 and sbCurKey and sbStaging[sbCurKey] then
      local procs = sbStaging[sbCurKey].procs
      local last = procs[#procs]
      if last then last.bases = v end
    end
  elseif cmd == "ICIPROCFACT" then
    -- <stackCap>:<rankScales>:<spPct>:<apPct> -- the facts about the ICIPROC just
    -- before it. Reports #999 and #1033: the panel was stating things about a proc
    -- that were not true, because it had no source for them and fell back to the
    -- spell's stock description. Its own line, so older builds drop it (same
    -- reasoning as ICIPROCBP/ICIPROCSRC).
    local sc, rs, sp, ap = rest:match("^(%d+):(%d+):(%d+):(%d+)$")
    if sc and sbCurKey and sbStaging[sbCurKey] then
      local procs = sbStaging[sbCurKey].procs
      local last = procs[#procs]
      if last then
        last.stackCap   = tonumber(sc) or 0
        last.rankScales = (tonumber(rs) or 0) == 1
        last.spPct      = tonumber(sp) or 0
        last.apPct      = tonumber(ap) or 0
      end
    end
  elseif cmd == "ICIPROCSRC" then
    -- <itemEntry> -- the sole item carrying the ICIPROC just before it. Only sent when
    -- unambiguous, and only useful for developer-named spells (see procDisplayName).
    local e = rest:match("^(%d+)$")
    if e and sbCurKey and sbStaging[sbCurKey] then
      local procs = sbStaging[sbCurKey].procs
      local last = procs[#procs]
      if last then last.srcItem = tonumber(e) end
    end
  elseif cmd == "ICINVEND" then
    sbInv = sbStaging
    sbStaging = {}
    sbCurKey = nil
    if UI and UI:IsShown() then UI:RefreshEquipped() end
  elseif cmd == "ICBOUND" then          -- <sourceEntry>  (single soulbind ok)
    local entry = tonumber(rest)
    local nm = entry and GetItemInfo(entry) or nil
    msg("Soulbound " .. (nm or ("item " .. tostring(rest))) .. " onto your gear.")
    if UI then UI:Ding() end
    send("ICINV"); send("ICSF")
  elseif cmd == "ICBOUNDALL" then       -- <count>
    state.sbInflight = false   -- [DE-09] the burst finished; the cooldown stands
    local n = tonumber(rest) or 0
    msg(string.format("Soulbound %d duplicate%s onto your gear.", n, n == 1 and "" or "s"))
    if UI then UI:Ding() end
    send("ICINV"); send("ICSF")
  elseif cmd == "ICEXOPEN" then         -- the scroll was used -> open the picker
    -- Opens the Dashboard's Extraction tab. Falls back to the floating window if
    -- the Dashboard is not loaded, so using a scroll always shows something.
    if _G.UncappedDashboard and _G.UncappedDashboard.Buttons then
      _G.UncappedDashboard.state.tab = "extraction"
      if _G.UncappedDashboard.Buttons.Show then _G.UncappedDashboard.Buttons.Show() end
      if _G.UncappedDashboard.UI and _G.UncappedDashboard.UI.Refresh then
        _G.UncappedDashboard.UI.Refresh()
      end
    else
      openExtractor()
    end
  elseif cmd == "ICEXI" then            -- <bag>:<slot>:<entry>:<equipped>:<spell>:<trigger>
    local bag, slot, entry, eq, spell, trig = rest:match("^(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)$")
    if bag then
      local key = bag .. ":" .. slot
      local it = state.exStaging[key]
      if not it then
        it = { bag = tonumber(bag), slot = tonumber(slot), entry = tonumber(entry),
               equipped = tonumber(eq), procs = {} }
        state.exStaging[key] = it
      end
      if tonumber(spell) > 0 then
        tinsert(it.procs, { spell = tonumber(spell), trigger = tonumber(trig) })
      end
    end
  elseif cmd == "ICEXD" then            -- <bag>:<slot>  this piece is marked finished
    -- Staged into a fresh table alongside the ICEXI sweep and committed at
    -- ICEXIEND, so a piece that stops being marked actually disappears from the
    -- set rather than lingering until relog.
    local bag, slot = rest:match("^(%d+):(%d+)$")
    if bag then
      state.exDoneStaging = state.exDoneStaging or {}
      state.exDoneStaging[bag .. ":" .. slot] = true
    end
  elseif cmd == "ICEXIEND" then
    state.exDone = state.exDoneStaging or {}
    state.exDoneStaging = nil
    commitExtractItems()
  elseif cmd == "ICSCROLLS" then        -- <balance>  scrolls held as currency
    state.scrolls = tonumber(rest) or 0
    if EXT and EXT:IsShown() then EXT:Refresh() end
  elseif cmd == "ICCOLLROW" then        -- <spell>:<trigger>:<sourceEntry>
    local sp, tr, src = rest:match("^(%d+):(%d+):(%d+)$")
    if sp then
      state.collStaging = state.collStaging or {}
      tinsert(state.collStaging,
        { spell = tonumber(sp), trigger = tonumber(tr), src = tonumber(src) })
    end
  elseif cmd == "ICCOLLEND" then
    state.collection = state.collStaging or {}
    state.collStaging = nil
    -- Same reasoning as wlSet: the Unlock list asks "do I already know this?" for
    -- every visible row on every redraw.
    state.collSet = {}
    -- [#1249] The ROW as well as the flag. collSet answers "do I know this", which
    -- is all the greying-out ever needed; naming the item it came from needs the
    -- source_entry the server has been sending in ICCOLLROW all along and the
    -- client was dropping on the floor everywhere except one detail pane.
    state.collByKey = {}
    for _, e in ipairs(state.collection) do
      state.collSet[e.spell .. ":" .. e.trigger] = true
      state.collByKey[e.spell .. ":" .. e.trigger] = e
    end
    rebuildProcNames()
    -- Sorted by name so the grid has a stable, readable order rather than
    -- whatever order the rows happened to arrive in.
    table.sort(state.collection, function(a, b)
      local an = procDisplayName({ spellId = a.spell }) or ""
      local bn = procDisplayName({ spellId = b.spell }) or ""
      if an ~= bn then return an < bn end
      return a.trigger < b.trigger
    end)
    if EXT and EXT:IsShown() then EXT:Refresh() end
  elseif cmd == "ICUNLOCKED" then       -- <spell>:<trigger>
    local sp = tonumber((rest:match("^(%d+)")))
    msg("|cff9CC243Unlocked|r " .. (sp and spellName(sp) or "the effect")
        .. " -- it is yours permanently, on every character.")
    state.exSelSrc = nil
    PlaySoundFile(SND_SEAL)
  elseif cmd == "ICEXOK" then           -- <spell>  extraction succeeded
    local sp = tonumber(rest)
    msg("|cff9CC243Extracted|r " .. (sp and spellName(sp) or "the effect")
        .. ". Soulbind duplicates into that item to upgrade it.")
    state.exSelSrc = nil; state.exSelTgt = nil
    PlaySoundFile(SND_SEAL)
  elseif cmd == "ICSOCKOPEN" then       -- a Scroll of Socket was used -> open the panel
    openSockets()

  -- ---- banned-proc register [#688] ----------------------------------------
  -- Staged, then swapped in on ICBPEND, so a dropped line can never leave the
  -- panel showing half a register. The reason TABLE arrives in the same burst as
  -- the ids that index into it and is replaced with them, so an index can never
  -- point at a sentence from an older server build.
  elseif cmd == "ICBPR" then            -- <index>:<sentence>
    local idx, text = rest:match("^(%d+):(.+)$")
    if idx then
      bpStaging = bpStaging or { reasons = {}, entries = {} }
      bpStaging.reasons[tonumber(idx)] = text
    end
  elseif cmd == "ICBPS" then            -- <reasonIndex>:<id>,<id>,<id>...
    local idx, ids = rest:match("^(%d+):(.+)$")
    if idx then
      bpStaging = bpStaging or { reasons = {}, entries = {} }
      local r = tonumber(idx)
      for id in ids:gmatch("(%d+)") do
        tinsert(bpStaging.entries, { spellId = tonumber(id), reasonIdx = r })
      end
    end
  elseif cmd == "ICBPEND" then
    commitBannedProcs()
  elseif cmd == "ICSOCKI" then          -- <bag>:<slot>:<entry>:<equipped>:<capacity>:<emptyTotal>
    local bag, slot, entry, eq, cap, empty = rest:match("^(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)$")
    if bag then
      state.sockStaging[bag .. ":" .. slot] = {
        bag = tonumber(bag), slot = tonumber(slot), entry = tonumber(entry),
        equipped = tonumber(eq), capacity = tonumber(cap), empty = tonumber(empty),
        emptyBy = {}, gems = {} }
    end
  elseif cmd == "ICSOCKE" then          -- <bag>:<slot>:<socketColor>:<empty of that colour>
    local bag, slot, col, n = rest:match("^(%d+):(%d+):(%d+):(%d+)$")
    local it = bag and state.sockStaging[bag .. ":" .. slot]
    if it then it.emptyBy[tonumber(col)] = tonumber(n) end
  elseif cmd == "ICSOCKG" then          -- <bag>:<slot>:<socketColor>:<gemEntry>:<count>:<active>
    local bag, slot, col, gem, n, act = rest:match("^(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)$")
    local it = bag and state.sockStaging[bag .. ":" .. slot]
    if it then
      -- Keyed by colour AND gem: the same gem in a red and a yellow socket is two rows
      -- to look at, even though it is one effect at strength 2.
      tinsert(it.gems, { color = tonumber(col), entry = tonumber(gem),
                         count = tonumber(n), active = tonumber(act) == 1 })
    end
  elseif cmd == "ICSOCKTALLY" then      -- <meta>:<red>:<yellow>:<blue>
    local m, r, y, b = rest:match("^(%d+):(%d+):(%d+):(%d+)$")
    if m then
      state.sockTally = { meta = tonumber(m), red = tonumber(r), yellow = tonumber(y), blue = tonumber(b) }
    end
  elseif cmd == "ICSOCKSCROLLS" then    -- <spendable>  bags + bank + Vault
    -- Rides along with every ICSOCKLIST and every socket mutation, so it arrives
    -- just before ICSOCKEND and the commit below paints it. The guarded refresh is
    -- for the day something sends it on its own.
    state.sockScrolls = tonumber(rest) or 0
    if SOCK and SOCK:IsShown() then SOCK:Refresh() end
  elseif cmd == "ICSOCKEND" then
    commitSocketItems()
  elseif cmd == "ICSOCKGEM" then        -- <entry>:<held>
    local entry, held = rest:match("^(%d+):(%d+)$")
    if entry then
      tinsert(state.sockGemStaging, { entry = tonumber(entry), held = tonumber(held) })
    end
  elseif cmd == "ICSOCKGEMEND" then
    state.sockGems = state.sockGemStaging
    state.sockGemStaging = {}
    table.sort(state.sockGems, function(a, b) return (itemDisplay(a.entry)) < (itemDisplay(b.entry)) end)
    -- Keep the Fill selection pointing at a gem you still own.
    local still = nil
    for _, g in ipairs(state.sockGems) do if g.entry == state.sockFillGem then still = g.entry end end
    state.sockFillGem = still
    if SOCK and SOCK:IsShown() then
      UIDropDownMenu_SetText(SOCK.fillDrop, still and (itemDisplay(still)) or "choose a gem")
      SOCK:Refresh()
    end
  elseif cmd == "ICSOCKADDED" then      -- <added>:<colour>x<n>,<colour>x<n>...
    local n, roll = rest:match("^(%d+):(.*)$")
    n = tonumber(n) or 0
    local parts = {}
    for col, cnt in (roll or ""):gmatch("(%d+)x(%d+)") do
      tinsert(parts, cnt .. " " .. colorText(tonumber(col)))
    end
    msg(string.format("|cff59bfe6Added %d socket%s:|r %s", n, n == 1 and "" or "s",
      #parts > 0 and table.concat(parts, ", ") or "?"))
    if roll and roll:find("^1x") or (roll or ""):find(",1x") then
      msg("|cffd0c0ffA META socket!|r Meta gems fit nothing else.")
    end
    PlaySoundFile(SND_SEAL)
  elseif cmd == "ICSOCKSET" then        -- <gemEntry>:<inserted>
    local e, n = rest:match("^(%d+):(%d+)$")
    e, n = tonumber(e), tonumber(n) or 0
    msg(string.format("|cff9CC243Socketed|r %s |cffffffffx%d|r.", e and (itemDisplay(e)) or "gem", n))
    PlaySoundFile(SND_SEAL)
  elseif cmd == "ICSOCKDEL" then        -- <gemEntry>:<removed>
    local e, n = rest:match("^(%d+):(%d+)$")
    e, n = tonumber(e), tonumber(n) or 0
    msg(string.format("|cffff8040Removed and destroyed|r %s |cffffffffx%d|r.",
      e and (itemDisplay(e)) or "gem", n))
  elseif cmd == "ICERR" then
    local op, reason = rest:match("^(%a+):(.+)$")
    if reason == "equipped" then
      -- The guard added after the 2026-08-16 incident. Worth its own branch rather
      -- than a slug: this refusal is the one standing between a misclick and
      -- someone's worn gear, and it should read like a reason.
      msg("|cffff8040You are wearing that. Unlocking destroys the item -- take it off first if you really mean to.|r")
    elseif reason == "already_known" then
      --[[ ★★ [#1249] NAMES WHICH ONE, AND WHERE IT CAME FROM.

           "You have already unlocked that effect" is unanswerable when spells
           16401, 17511 and 18197 are all literally named "Poison" and the player
           owns exactly one of them. The selected row IS the request that was
           refused, so the collection entry behind it can be named -- with its
           spell id when the name is shared, and with the item it was first
           pulled from. That sentence is the whole of report #1249. ]]
      local s = state.exSelSrc
      if s then
        local from = collectedFrom(s.spell, s.trigger)
        msg("|cffff8040You have already unlocked|r |cffb384ff" .. procLabel(s.spell)
          .. "|r |cffff8040(" .. triggerLabel(s.trigger) .. ")|r"
          .. (from and (" |cffff8040from|r |cffffffff" .. from .. "|r") or ""))
      else
        msg("|cffff8040You have already unlocked that effect.|r")
      end
    elseif reason == "whitelisted" then
      --[[ [#1249] DELIBERATELY SILENT HERE.

           ItemCustomization::RefuseWhitelisted has already PSendSysMessage'd the
           full sentence, naming the item, before this token was sent. A second
           line would be the same refusal printed twice.

           What the CLIENT owes is the padlock it failed to draw -- the server
           matches whitelist entries as SUBSTRINGS and the client used to match
           them exactly, so an item covered by a broader phrase showed no lock,
           offered an enabled button, and got refused. wlProtectedBy now mirrors
           the server's rule; re-asking for the list makes the panel agree with
           it immediately rather than at the next open. ]]
      send("ICWLIST")
      if EXT and EXT:IsShown() then EXT:Refresh() end
    elseif reason == "item_locked" then
      msg("|cffff8040You marked that piece finished. Right-click it to unmark it first.|r")
    elseif reason == "not_unlocked" then
      msg("|cffff8040You have not unlocked that effect yet.|r")
    elseif reason == "no_equipped_match" then
      msg("|cffff8040You can only soulbind a duplicate of an item you're wearing.|r")
    elseif reason == "nothing" then
      -- [#1119] Not "of your equipped gear" any more -- the sweep also feeds an
      -- already-soulbound bag copy, so that wording sent people to equip a piece
      -- that was never the reason nothing happened.
      msg("|cffff8040Nothing to soulbind. A duplicate goes onto the copy you are wearing, or onto an already-soulbound copy in your bags.|r")
    elseif op == "socket" then
      local m = {
        no_scroll = "You have no Scroll of Socket.", no_item = "That item is gone.",
        not_gear = "Only weapons and armour can be socketed.",
        no_socket = "That item has no empty sockets.",
        no_fit = "No empty socket of a colour that gem fits.",
        need_meta_socket = "Meta gems only fit a META socket, and you have none empty.",
        no_gem = "That gem is gone.",
        not_gem = "That isn't a gem.", cant_use = "You can't use that gem.",
        limit = "You already carry as many of that kind of gem as you may.",
        same_item = "Pick a different item.",
      }
      msg("|cffff8040Socketing failed:|r " .. (m[reason] or tostring(reason)))
    elseif op == "use" then
      -- [#1227] The on-use clicky. Named refusals rather than a slug, because this
      -- is a button a player presses in combat and "use failed: notarget" tells
      -- them nothing about what to do differently.
      local m = {
        notarget = "Nothing to aim that at -- a harmful effect needs an enemy target.",
        -- The proc is on a piece you are not wearing (UseProc reads the equipped
        -- cache), or it is on the banned register and suppressed.
        not_equipped = "That effect is not active on anything you are wearing.",
        -- UseProc checks HasSpellCooldown BEFORE resolving a target, so this is the
        -- refusal a click during the cooldown actually gets. The swipe should have
        -- said so already; this covers the gap before the cooldown packet lands.
        cooldown = "That effect is still on cooldown.",
      }
      msg("|cffff8040" .. (m[reason] or tostring(reason)) .. "|r")
    elseif op == "unlock" then
      -- [#1249] Unlock had NO branch at all and fell through to the generic
      -- "<op> failed: <token>" slug at the bottom, so a player was shown a
      -- server-side identifier and nothing they could act on. The reasons
      -- handled above (equipped / already_known / whitelisted / no_proc) short
      -- circuit before this; these are the rest of what UnlockProc can return.
      local m = {
        parse     = "Something went wrong reading that request -- pick the row again.",
        noplayer  = "You have to be in the world to do that.",
        no_source = "That item is gone.",
        no_proc   = "That item no longer carries that effect.",
        no_scroll = "You have no Scrolls of Extraction.",
      }
      msg("|cffff8040Unlock failed:|r " .. (m[reason] or tostring(reason)))
    elseif op == "extract" then
      local m = {
        no_source = "The item to pull from is gone.", no_target = "The item to receive it is gone.",
        same_item = "Pick two different items.", bad_target = "That item can't receive an effect.",
        no_proc = "That item no longer has that effect.",
      }
      msg("|cffff8040Extraction failed:|r " .. (m[reason] or tostring(reason)))
    else
      msg("|cffff4040" .. tostring(op) .. " failed:|r " .. tostring(reason))
    end
  else
    dbg("unhandled:", body)
  end
end

-- ---- StaticPopup: confirm gem removal ------------------------------------
StaticPopupDialogs["UNCAPPED_SOCKET_REMOVE"] = {
  text = "Remove %s x%s?\n\nThe gems are destroyed. The sockets stay empty and reusable.",
  button1 = ACCEPT, button2 = CANCEL,
  -- 3.3.5a hands the payload through differently depending on how the dialog was
  -- shown, so accept it either way rather than depending on one.
  OnAccept = function(self, data)
    local d = data or (self and self.data)
    if d then send(string.format("ICSOCKDEL:%d:%d:%d:%d:%d", d.bag, d.slot, d.entry, d.amount, d.color or 0)) end
  end,
  timeout = 0, whileDead = 1, hideOnEscape = 1, showAlert = 1,
}

-- ---- StaticPopup: confirm Soulbind Duplicates ----------------------------
-- Raised by ICACWARN, never by the checkbox directly: the server arms the
-- confirmation and this is the only thing that sends the accept. The wording is
-- deliberately blunt -- the old one-line checkbox was not, and people lost gear
-- to it without ever understanding what they had switched on.
StaticPopupDialogs["UNCAPPED_SF_AUTOCONSUME"] = {
  text = "|cffff2020This permanently destroys gear.|r\n\n"
      -- ⚠ [#898] These tiers are not decoration -- this is the consent dialog for
      -- an irreversible destruction, and it must name exactly what the server
      -- will eat. "common" was added when Soulforge.SoulValue.Common went 0 -> 1.
      -- If that config value ever changes again, this line changes with it.
      .. "While Auto-consume is on, every |cffffffffcommon, uncommon, rare or epic|r weapon and armour "
      .. "piece you are |cffffffffnot wearing|r is rendered down for souls -- out of your bags "
      .. "|cffffffffand out of your Vault|r -- automatically, within seconds. It cannot be "
      .. "undone, and you are not asked again each time.\n\n"
      .. "Only the |cffffffffWhitelist|r protects an item.\n\nTurn Auto-consume on?",
  button1 = "Yes, destroy my spare gear", button2 = CANCEL,
  OnAccept = function() send("ICAC:1:CONFIRM") end,
  timeout = 60, whileDead = 1, hideOnEscape = 1, showAlert = 1,
}

-- ---- StaticPopup: confirm the [#812] vault junk render --------------------
--
-- ⚠⚠ THIS IS A CONSENT DIALOG FOR AN IRREVERSIBLE DESTRUCTION, so it obeys the
--    same rule the Auto-consume one carries: it names EXACTLY what the server
--    will eat, and if the server's rule ever changes this text changes with it.
--
--    The qualities named here are grey and white and nothing else, because that
--    is precisely what ItemCustomization::JunkRenderValue prices. It is NOT the
--    same set as Auto-consume's -- that one is common through epic and this one
--    stops at white -- and the difference is the entire reason this button
--    exists, so both dialogs have to keep saying their own truth.
--
-- ★ The COUNTS come from the server as %s arguments, never from a client-side
--   tally: the Vault's quest reserves, the account whitelist and the worn-copy
--   check are all server-side, so a locally computed number could promise a
--   destruction different from the one about to happen.
--
-- ⚠ `timeout` is overwritten from the server's arm on every raise (see the ICVR
--   handler). The 60 here is only what it is before the first one lands.
StaticPopupDialogs["UNCAPPED_SF_RENDER_JUNK"] = {
  text = "|cffff2020This permanently destroys gear.|r\n\n"
      .. "Render |cffffffff%s|r |cffffffffgrey and white|r weapon and armour piece(s) out of your "
      .. "|cffffffffVault|r into |cffffffff%s|r souls?\n\n"
      .. "Green and better gear is |cffffffffnot|r touched. Quest turn-ins, anything on your Whitelist "
      .. "and exact copies of the gear you are wearing are all held back.\n\n"
      .. "Greys would sell to a vendor for a little gold instead. This cannot be undone.",
  button1 = "Yes, render them down", button2 = CANCEL,
  OnAccept = function() send("ICVRENDER:CONFIRM") end,
  timeout = 60, whileDead = 1, hideOnEscape = 1, showAlert = 1,
}

StaticPopupDialogs["UNCAPPED_SF_SOULBIND_ALL"] = {
  -- ⚠ [#1119] THIS SENTENCE IS THE CONSENT, so it names exactly what the server
  --   will now do. It used to say "the gear you're wearing", which stopped being
  --   true when the sweep gained its bag-target fallback: a duplicate whose worn
  --   copy does not exist is fed to an ALREADY-SOULBOUND copy in your bags
  --   instead. Saying only "wearing" would consume items on a rule the player was
  --   never shown.
  text = "Soulbind every exact duplicate you own (from bags AND vault) onto the copy you keep?\n\n"
      .. "Each duplicate goes onto the copy you are |cffffffffwearing|r -- or, if you are not "
      .. "wearing one, onto an |cffffffffalready-soulbound|r copy of it in your bags.\n\n"
      .. "The duplicates are consumed. This cannot be undone.",
  button1 = ACCEPT, button2 = CANCEL,
  -- [DE-09] The arm lives here, not on the button: this is the only path that
  -- sends. Re-checked because the popup can sit on screen indefinitely
  -- (timeout = 0) and a second one can be raised behind it.
  OnAccept = function()
    if state.sbInflight then return end
    if (GetTime() or 0) < (state.sbReadyAt or 0) then return end
    state.sbInflight = true
    state.sbReadyAt  = (GetTime() or 0) + (state.sbCooldown or 30)
    send("ICSBALL")
  end,
  timeout = 0, whileDead = 1, hideOnEscape = 1, showAlert = 1,
}

-- ============================ tooltip injection ===========================
-- Append cached soulbound data onto GameTooltip after it builds; long blocks go
-- into a scrollable panel scrolled in place via a full-screen wheel catcher.
local SB_MARK = "|cff66ccffSoulbound|r"
local TIP_MAX_INLINE = 12
local TIP_ROWS, TIP_ROW_H = 16, 14

local sbTip, sbWheel
local sbTipHideDue
local sbTipHideTimer = CreateFrame("Frame")
sbTipHideTimer:Hide()

local function hideSbTip()
  if sbTip then sbTip:Hide(); sbTip.curKey = nil end
  if sbWheel then sbWheel:Hide() end
end
local function cancelSbTipHide() sbTipHideDue = nil; sbTipHideTimer:Hide() end
local function scheduleSbTipHide()
  if sbTip and sbTip:IsShown() then sbTipHideDue = 0.5; sbTipHideTimer:Show() end
end
sbTipHideTimer:SetScript("OnUpdate", function(self, elapsed)
  if not sbTipHideDue then self:Hide(); return end
  sbTipHideDue = sbTipHideDue - elapsed
  if sbTipHideDue <= 0 then
    sbTipHideDue = nil; self:Hide()
    if not (sbTip and MouseIsOver(sbTip)) then hideSbTip() end
  end
end)

local function scrollSbTip(delta)
  local sb = _G["UncappedSoulboundTipScrollScrollBar"]
  if sb then sb:SetValue(sb:GetValue() - delta * TIP_ROW_H * 3) end
end

-- ⚠ DELIBERATELY NOT REGISTERED WITH THE PLAYER'S WINDOW ZOOM.
--
-- This is not a window, it is a second panel glued to GameTooltip's right edge
-- (see showSbTip's SetPoint below). GameTooltip is a Blizzard frame at
-- UIParent's scale and the Uncapped zoom does not touch it, so scaling this
-- would leave an oversized slab hanging off a normal-sized tooltip, with the
-- 6px seam between them scaled too. It must match what it is attached to.
-- Same reason the full-screen wheel-catcher below stays unscaled.
local function buildSbTip()
  if sbTip then return sbTip end
  local f = CreateFrame("Frame", "UncappedSoulboundTip", UIParent)
  -- UIParent-parented, so it follows the Dashboard zoom only if it registers.
  -- Its four siblings all did; these two were missed (UI audit 2026-08-16).
  if UncappedScale_Register then UncappedScale_Register(f, { group = "dashboard" }) end
  f:SetFrameStrata("TOOLTIP"); f:SetFrameLevel(100)
  f:SetWidth(288); f:SetHeight(TIP_ROWS * TIP_ROW_H + 40)
  f:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 } })
  f:SetBackdropColor(0.03, 0.02, 0.05, 0.95)
  f:SetBackdropBorderColor(0.55, 0.4, 0.9, 0.9)
  f:SetClampedToScreen(true); f:EnableMouse(true); f:Hide()

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 12, -10); title:SetText(SB_MARK)

  local scroll = CreateFrame("ScrollFrame", "UncappedSoulboundTipScroll", f, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 8, -28); scroll:SetWidth(256); scroll:SetHeight(TIP_ROWS * TIP_ROW_H)
  scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, TIP_ROW_H, function() f:Fill() end)
  end)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(_, delta) scrollSbTip(delta) end)
  f.scroll = scroll

  f.rows = {}
  for i = 1, TIP_ROWS do
    local fs = f:CreateFontString(nil, "OVERLAY", "GameTooltipText")
    fs:SetPoint("TOPLEFT", scroll, "TOPLEFT", 2, -(i-1)*TIP_ROW_H)
    fs:SetWidth(248); fs:SetHeight(TIP_ROW_H); fs:SetJustifyH("LEFT")
    f.rows[i] = fs
  end

  function f:Fill()
    local lines = self.lines or {}
    FauxScrollFrame_Update(self.scroll, #lines, TIP_ROWS, TIP_ROW_H)
    local offset = FauxScrollFrame_GetOffset(self.scroll)
    for i = 1, TIP_ROWS do
      local e = lines[i + offset]
      local fs = self.rows[i]
      if e then
        fs:SetText(e.text); fs:SetTextColor(e.r or 1, e.g or 1, e.b or 1); fs:Show()
      else
        fs:Hide()
      end
    end
  end

  f:SetScript("OnEnter", function() cancelSbTipHide() end)
  f:SetScript("OnLeave", function() hideSbTip() end)

  sbWheel = CreateFrame("Frame", "UncappedSoulboundWheel", UIParent)
  -- UIParent-parented, so it follows the Dashboard zoom only if it registers.
  -- Its four siblings all did; these two were missed (UI audit 2026-08-16).
  if UncappedScale_Register then UncappedScale_Register(sbWheel, { group = "dashboard" }) end
  sbWheel:SetAllPoints(UIParent)
  sbWheel:SetFrameStrata("TOOLTIP"); sbWheel:SetFrameLevel(90)
  sbWheel:EnableMouse(false); sbWheel:EnableMouseWheel(true)
  sbWheel:SetScript("OnMouseWheel", function(_, delta) scrollSbTip(delta) end)
  sbWheel:Hide()

  sbTip = f
  return f
end

local function showSbTip(lines, key)
  local f = buildSbTip()
  f.lines = lines
  if key ~= f.curKey then
    local sb = _G["UncappedSoulboundTipScrollScrollBar"]; if sb then sb:SetValue(0) end
    f.curKey = key
  end
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", GameTooltip, "TOPRIGHT", 6, 0)
  f:Show(); f:Fill()
  sbWheel:Show()
  cancelSbTipHide()
end

local function alreadyInjected(tt)
  local name = tt:GetName()
  if not name then return false end
  for i = 1, tt:NumLines() do
    local fs = _G[name .. "TextLeft" .. i]
    if fs and fs:GetText() == SB_MARK then return true end
  end
  return false
end

local function Inject(tt, key)
  local e = sbInv[key]
  if not e then
    scheduleSbTipHide()
    return
  end
  if alreadyInjected(tt) then return end

  local lines = {}

  -- Vestiges first: the stat lines below are already scaled by them, so without this the
  -- numbers have no visible cause. A mechanic the player cannot see is a mechanic they
  -- conclude is broken.
  if (e.vestiges or 0) > 0 then
    local mult = (e.vestigeMult or 100) / 100
    lines[#lines+1] = {
      text = string.format("Vestiges: %d  (x%.2f to stats)", e.vestiges, mult),
      r = 0.72, g = 0.45, b = 1.0,
    }
  end

  for _, s in ipairs(e.stats) do
    lines[#lines+1] = { text = statLineText(s.type, s.value), r = 0.12, g = 1, b = 0.12 }
  end
  for _, p in ipairs(e.procs) do
    -- Header: what it is, how it fires, and (for chance procs) how often.
    for _, seg in ipairs(wrapText(procDisplayName(p) .. " (" .. triggerLabel(p.trigger)
        .. ") \226\128\148 " .. procMechanic(p), TIP_WRAP_CHARS)) do
      lines[#lines+1] = { text = seg, r = 0.75, g = 0.5, b = 0.94 }
    end

    -- Body: the spell's own description with its numbers rewritten to what this
    -- soulbound copy actually hits for. Falls back to no body line if the client
    -- has no description for the spell, or if none of the server's base values
    -- appear in it -- printing stock numbers next to a 367x multiplier would read
    -- as a bug, and the header already carries the multiplier.
    -- [#999] Correct the stack count FIRST, on the stock text, so the fix survives
    -- whether or not scaleDescription manages to rewrite the magnitudes below. The two
    -- are independent failures and were showing up as one confusing tooltip.
    local baseDesc = fixStackCount(spellDescription(p.spellId), p.stackCap)
    local scaled = scaleDescription(baseDesc, p.bases or {}, (p.mag or 100) / 100)

    -- [#1033] Even when the magnitudes could not be rewritten, the corrected stock text
    -- is worth more than nothing -- it is what the spell does, just at base values, and
    -- the header already says "Nx power" so nobody reads it as their own number.
    if not scaled and baseDesc and (p.mag or 100) == 100 then
      scaled = baseDesc
    end

    if scaled then
      -- Pre-wrapped: a spell description is one long unbroken string, and neither render
      -- path wraps it for us (GameTooltip:AddLine stretches the tooltip across the screen;
      -- the companion panel's rows are fixed height and would overlap).
      for _, seg in ipairs(wrapText(scaled, TIP_WRAP_CHARS)) do
        lines[#lines+1] = { text = "  " .. seg, r = 0.62, g = 0.62, b = 0.72 }
      end
    end

    -- [#1033] What actually moves this proc's numbers. Owner ruling 2026-08-25:
    -- "let the players know how to scale the proc via the interface".
    local note = procScalingNote(p)
    if note then
      for _, seg in ipairs(wrapText(note, TIP_WRAP_CHARS)) do
        lines[#lines+1] = { text = "  " .. seg, r = 0.55, g = 0.62, b = 0.55 }
      end
    end
  end

  tt:AddLine(" ")
  tt:AddLine(SB_MARK)
  if #lines <= TIP_MAX_INLINE then
    for _, ln in ipairs(lines) do tt:AddLine(ln.text, ln.r, ln.g, ln.b) end
    hideSbTip()
  else
    tt:AddLine("|cffffd200" .. #lines .. " bound powers|r \226\128\148 scroll to read them all", 1, 1, 1)
    showSbTip(lines, key)
  end
  tt:Show()
end

GameTooltip:HookScript("OnHide", function() scheduleSbTipHide() end)
hooksecurefunc(GameTooltip, "SetBagItem", function(tt, bag, slot) Inject(tt, "B:" .. bag .. ":" .. slot) end)
hooksecurefunc(GameTooltip, "SetInventoryItem", function(tt, unit, invSlot)
  if unit == "player" then Inject(tt, "E:" .. invSlot) end
end)

-- give the UI its whitelist opener now that BuildWhitelist exists
local function attachWhitelistOpener()
  if not UI or UI.OpenWhitelist then return end
  function UI:OpenWhitelist()
    BuildWhitelist()
    if WLM:IsShown() then WLM:Hide() return end
    local box = _G["UncappedSoulforgeWLBox"]; if box then box:SetText("") end
    wlSearchReset()   -- [DE-04] drop anything the last visit left queued or awaited
    state.wlSuggest = {}
    WLM:Show(); WLM:Update(); WLM:UpdateSuggest(); send("ICWLIST")
  end
end

-- Same trick for the two second-row buttons: BuildUI runs long before
-- BuildSocketUI / BuildBannedProcs are declared, so the buttons call a METHOD
-- that is attached here rather than an upvalue that would still be nil.
-- [#424] and [#688].
local function attachExtraOpeners()
  if not UI then return end

  if not UI.OpenSockets then
    function UI:OpenSockets()
      -- Toggle, matching /socket: clicking the button with the window already up
      -- closes it, which is what every other Uncapped pop-out does.
      BuildSocketUI()
      if SOCK:IsShown() then SOCK:Hide() else openSockets() end
    end
  end

  if not UI.OpenBannedProcs then
    function UI:OpenBannedProcs()
      BuildBannedProcs()
      if BP:IsShown() then BP:Hide() else openBannedProcs() end
    end
  end
end

-- ============================ events / slash ==============================
local invTimer = CreateFrame("Frame"); invTimer:Hide()
local invDue = nil
invTimer:SetScript("OnUpdate", function(self, elapsed)
  if not invDue then self:Hide(); return end
  invDue = invDue - elapsed
  if invDue <= 0 then invDue = nil; self:Hide(); send("ICINV") end
end)
local function requestInvIn(delay) invDue = delay; invTimer:Show() end

-- Last time we asked the server for a sack count off a bag change. See BAG_UPDATE.
local sackAskedAt

local listener = CreateFrame("Frame")
listener:RegisterEvent("CHAT_MSG_ADDON")
listener:RegisterEvent("PLAYER_LOGIN")
listener:RegisterEvent("BAG_UPDATE")
listener:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
-- [#1227] Fired when the client receives SMSG_SPELL_COOLDOWN, i.e. exactly when
-- UseProc's AddSpellCooldown(..., needSendToClient) lands. This is what turns the
-- clicky swipes into the server's real number instead of a guess.
listener:RegisterEvent("SPELL_UPDATE_COOLDOWN")
listener:SetScript("OnEvent", function(self, event, a1, a2)
  if event == "CHAT_MSG_ADDON" then
    if a1 == PIPE_PREFIX and a2 and a2:sub(1,2) == "IC" then OnLine(a2) end
    return
  end
  if event == "PLAYER_LOGIN" then
    requestInvIn(2)          -- warm the soulbound tooltip cache
    send("ICSF")             -- get the forge bar
    return
  end

  --[[ [#1227] Repaint the clicky swipes from the cooldown the server just sent.

       Only the swipes -- NOT a RefreshEquipped. This event fires for every
       cooldown the player starts, which in combat is constantly, and rebuilding
       the whole gear list off it would put a full inventory walk on the global
       cooldown. Walking the row pool is 40 buttons at the absolute worst and most
       of them are hidden with no spellId.

       Ungated on visibility on purpose: CooldownFrame_SetTimer on a hidden frame
       is free, and arming it here means the swipe is already correct the moment
       the tab is opened rather than a frame later. ]]
  if event == "SPELL_UPDATE_COOLDOWN" then
    for i = 1, EQ_ROWS_MAX do
      local r = eqRows[i]
      if r and r.useBtns then
        for k = 1, EQ_USE_MAX do armUseButton(r.useBtns[k]) end
      end
    end
    return
  end
  if event == "BAG_UPDATE" then
    requestInvIn(0.3)

    --[[ [#1124] Repaint the Extraction panel if it is open.

         A Scroll of Extraction looted while that tab was up stayed invisible until
         /reload: the scroll count is (balance + bag count), and BAG_UPDATE is the
         only event that can move the second term. One local redraw answers it.

         ⚠ NO send("ICCOLL") HERE, DELIBERATELY. ICCOLL is the collection burst --
           one ICCOLLROW per unlocked proc on the whole ACCOUNT -- and BAG_UPDATE
           fires several times for a single loot. That is a message storm per pickup
           for data that a bag change cannot possibly have altered. The Refresh below
           re-reads GetItemCount, which is all that actually moved.

         ⚠ IsVisible, not IsShown. EXT is a Dashboard tab: EmbedInto calls Show()
           on it once and never hides it again -- the Dashboard hides the GROUP
           around it. So IsShown() stays true for the rest of the session and this
           would redraw the whole grid on every bag change with the window shut.
           IsVisible walks the parents, which is the question actually being asked.
    ]]
    if EXT and EXT:IsVisible() then EXT:Refresh() end

    -- Keep the sack count honest while the panel is open with the mode OFF, when
    -- nothing else is pushing. Gated on the panel being VISIBLE and throttled to
    -- 2s, because BAG_UPDATE fires several times for one loot and this is the
    -- one message here that a player can trigger in a tight loop.
    if UI and UI:IsVisible() then
      local now = GetTime()
      if not sackAskedAt or (now - sackAskedAt) > 2 then
        sackAskedAt = now
        send("ICSACKS")
      end
    end
  end
  -- ★ [DE-10] DEBOUNCED, like BAG_UPDATE three lines up -- it used to send
  --   immediately. PLAYER_EQUIPMENT_CHANGED fires once PER SLOT, so an
  --   equipment-manager set swap raised up to 19 events in a single frame. Each
  --   ICINV runs SendInventorySoulbound on the map thread: 19 equipped + 16
  --   backpack + up to 4x36 bag slots walked, with an ICITEM/ICIVEST, one
  --   ICISTAT per stat and ICIPROC/ICIPROCBP/ICIPROCSRC per proc emitted for
  --   every soulbound item, each proc costing a two-level trigger-chain spell
  --   walk. Nineteen full scans and hundreds of packets for one click.
  if event == "PLAYER_EQUIPMENT_CHANGED" then requestInvIn(0.3) end
end)

-- ============================ dashboard embedding =========================
-- The Dashboard hosts this panel directly inside its own window instead of
-- Soul Forge owning a window of its own. UncappedDashboard_UI.lua calls
-- EmbedInto once (to build the frame into its content group) and Activate
-- every time the Soul Forge tab is selected. The Extractor, Socket, and
-- Whitelist windows stay separate popups -- they're triggered by a specific
-- action (using a scroll, clicking Whitelist) rather than being "the Soul
-- Forge screen" itself, so they keep their own floating frames.
local SF = _G.UncappedSoulForge or {}
_G.UncappedSoulForge = SF
SF.UI = {}

function SF.UI.EmbedInto(parent)
  BuildUI(parent)
  attachMethods()
  attachWhitelistOpener()
  attachExtraOpeners()   -- [#424] Sockets, [#688] Banned Procs
  UI:Show()
  return UI
end

function SF.UI.Activate()
  if not UI then return end
  UI:Refresh()
  -- ICSF is also the capability probe for the sack panel: a server that knows
  -- mode 2 answers it with an ICSACKS, and that reply is what unlocks the
  -- "keep everything" row (see serverKeepOk). So no separate request is needed
  -- here or at PLAYER_LOGIN -- every place that already asks for the forge bar
  -- is asking the question, and an old server simply never answers it.
  send("ICSF"); send("ICINV")
end

-- Content-panel width (not window width) Soul Forge needs so the Soulbind
-- Duplicates + Whitelist buttons don't overflow: 6px left inset + 170 +
-- 10px gap + 170 + 6px right inset = 362, plus the embedded group's own
-- 6px padding on each side (see UncappedDashboard_UI.lua) = 374.
function SF.UI.GetMinWidth()
  return 374
end

-- No standalone /soulforge, /sf, /soulbind or /sb command: this window is a
-- Dashboard tab now, opened via /dashboard, so a dedicated slash command would
-- just duplicate that entry point.

--[[
  Extraction is its own Dashboard tab (owner request 2026-08-16).

  ★ It is a SEPARATE global from UncappedSoulForge even though both live in this
    file, because the Dashboard's EMBEDDED_TABS maps one tab key to one global
    name and Soul Forge already owns `soulforge`. Two tabs, two globals.

  ⚠ It took the dead `tutorial` slot rather than becoming a SIXTEENTH tab. That
    is not tidiness: UncappedDashboardConfig.lua spells out that the nav column's
    required height reaches ~700 units at 16 tabs, which collapses the window's
    zoom ceiling to ~1.01 for everyone -- adding a tab would have cost the zoom
    feature on this window. `UncappedTutorial` does not exist as an addon and
    never did, so the slot was free. Same precedent as the Beastiary slot.
]]
local EXTRACT = _G.UncappedExtraction or {}
_G.UncappedExtraction = EXTRACT
EXTRACT.UI = {}

function EXTRACT.UI.EmbedInto(parent)
  BuildExtractor(parent)
  EXT:Show()
  return EXT
end

function EXTRACT.UI.Activate()
  if not EXT then return end
  state.exStaging = {}
  state.exMode = state.exMode or "coll"
  state.exFilter = state.exFilter or "all"
  EXT:Refresh()
  send("ICEXSRC"); send("ICCOLL"); send("ICWLIST")
end

-- The two columns plus their padding: 20 + (6 * 42 grid) + 16 gutter + 238
-- target column + 20 right inset = 546, plus the embedded group's own 6px each
-- side = 558. Below this the target list starts clipping.
function EXTRACT.UI.GetMinWidth()
  return 558
end

SLASH_EXTRACT1 = "/extract"
SLASH_EXTRACT2 = "/ex"
SlashCmdList["EXTRACT"] = function()
  -- Routes to the Dashboard tab rather than opening a second, floating copy --
  -- the same choice Soul Forge made when it stopped having its own window.
  if _G.UncappedDashboard and _G.UncappedDashboard.Buttons then
    _G.UncappedDashboard.state.tab = "extraction"
    if _G.UncappedDashboard.Buttons.Show then _G.UncappedDashboard.Buttons.Show() end
    if _G.UncappedDashboard.UI and _G.UncappedDashboard.UI.Refresh then
      _G.UncappedDashboard.UI.Refresh()
    end
  else
    -- Dashboard missing (disabled, or an error earlier in load): fall back to the
    -- floating window rather than doing nothing at all.
    BuildExtractor()
    if EXT:IsShown() then EXT:Hide() else openExtractor() end
  end
end

SLASH_SOCKET1 = "/socket"
SLASH_SOCKET2 = "/sock"
SlashCmdList["SOCKET"] = function()
  BuildSocketUI()
  if SOCK:IsShown() then SOCK:Hide() else openSockets() end
end

-- [#688] Also reachable from the Soul Forge tab's "Banned Procs..." button; the
-- slash command is the muscle-memory path for anyone who already knows
-- `.bannedprocs`, which this replaces for reading (that command still works and
-- still has `mine`, which this panel does not).
SLASH_BANNEDPROCS1 = "/bannedprocs"
SLASH_BANNEDPROCS2 = "/bprocs"
SlashCmdList["BANNEDPROCS"] = function()
  BuildBannedProcs()
  if BP:IsShown() then BP:Hide() else openBannedProcs() end
end

SLASH_ICDEBUG1 = "/sbdebug"
SlashCmdList["ICDEBUG"] = function() DEBUG = not DEBUG; msg("debug " .. (DEBUG and "ON" or "OFF")) end

dbg("Soulforge addon parsed.")
