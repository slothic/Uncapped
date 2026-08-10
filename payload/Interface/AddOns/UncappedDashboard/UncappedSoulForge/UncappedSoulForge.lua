--[[
  Uncapped Soulforge  (formerly Item Customize / Soulbinding)
  -----------------------------------------------------------
  Two systems:
    * The Soulforge -- a per-account bar. Junk gear you don't want is eaten for
      "souls"; each time the bar fills, a global EXTRACTION multiplier rises a
      little (forever). Auto-consume (ICAC) and Auto-melt (ICAO), both off by
      default, feed it as you play; the whitelist protects named items from
      being picked up by either. There is no manual single-item feed.
    * Soulbinding -- feed an EXACT DUPLICATE of an item you're WEARING onto it to
      extract (the current multiplier) of its stats and ramp its procs. "Soulbind
      Duplicates" does it in bulk from your bags + vault.

  Transport (matches the rest of the UNC pipe):
    * SEND    : SendAddonMessage("REAGENTBANK", body, "WHISPER", UnitName("player"))
    * RECEIVE : CHAT_MSG_ADDON, arg1 == "UNC", arg2 == body.

  Soul Forge is a Dashboard tab (opened via /dashboard, not its own window).
  /extract, /ex and /socket, /sock still open their own standalone popups.
  /sbdebug   toggle verbose wire logging
]]

local SEND_PREFIX = "REAGENTBANK"
local PIPE_PREFIX = "UNC"
local QUESTION    = "Interface\\Icons\\INV_Misc_QuestionMark"

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
  whitelist = {},        -- current whitelist item names
  wlStaging = {},
  wlSuggest = {},        -- item-name search suggestions (server ICINAME search)
  wlSuggestStaging = {},
  equipped = {},         -- rendered rows: your equipped items that carry bonuses
  exItems = {},          -- extraction picker: key "bag:slot" -> {bag,slot,entry,equipped,procs={}}
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

local function isWhitelistedName(name)
  if not name then return false end
  name = name:lower()
  for _, w in ipairs(state.whitelist) do
    if w and name:find(w:lower(), 1, true) then return true end
  end
  return false
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
  sfHint:SetText("Feed junk gear to the forge to raise the extraction rate. Soulbinding a duplicate onto gear you're wearing extracts that share of its stats.")

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
  local openBtn = CreateFrame("Button", "UncappedSoulforgeSackOpen", f, "UIPanelButtonTemplate")
  openBtn:SetSize(150, 22); openBtn:SetPoint("TOPLEFT", 8, -218)
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

  local sbBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  sbBtn:SetSize(170, 24); sbBtn:SetPoint("TOPLEFT", 6, -250); sbBtn:SetText("Soulbind Duplicates")
  sbBtn:SetScript("OnClick", function() StaticPopup_Show("UNCAPPED_SF_SOULBIND_ALL") end)

  local wlBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  wlBtn:SetSize(170, 24); wlBtn:SetPoint("LEFT", sbBtn, "RIGHT", 10, 0); wlBtn:SetText("Whitelist\226\128\166")
  wlBtn:SetScript("OnClick", function() if UI and UI.OpenWhitelist then UI:OpenWhitelist() end end)

  -- ---- your soulbound gear ----
  local eqHdr = f:CreateFontString(nil,"OVERLAY","GameFontNormal")
  eqHdr:SetPoint("TOPLEFT", 6, -284); eqHdr:SetText("|cff40c0f0Your soulbound gear|r")
  local dLine = f:CreateTexture(nil,"ARTWORK"); dLine:SetTexture("Interface\\Buttons\\WHITE8X8")
  dLine:SetGradientAlpha("HORIZONTAL", 0.25,0.60,0.90,0.6, 0.25,0.60,0.90,0.0)
  dLine:SetHeight(2); dLine:SetPoint("TOPLEFT", 6, -300); dLine:SetPoint("TOPRIGHT", -6, -300)

  -- Stretches to fill whatever's left of the panel below the divider; a pool
  -- of EQ_ROWS_MAX row frames is pre-built, but only however many actually
  -- fit (recomputed on OnSizeChanged, see below) are ever shown at once.
  local scroll = CreateFrame("ScrollFrame", "UncappedSoulforgeEqScroll", f, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 8, -308); scroll:SetPoint("BOTTOMRIGHT", -23, 8)
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
    r.name:SetPoint("TOPLEFT",36,-1); r.name:SetPoint("TOPRIGHT",-4,-1); r.name:SetJustifyH("LEFT")
    r.sub = r:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
    r.sub:SetPoint("TOPLEFT",36,-15); r.sub:SetPoint("TOPRIGHT",-4,-15); r.sub:SetJustifyH("LEFT")
    eqRows[i] = r; r:Hide()
  end
  local eqEmpty = f:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
  eqEmpty:SetPoint("TOP", scroll, "TOP", 0, -30); eqEmpty:SetPoint("LEFT", scroll, "LEFT", 20, 0)
  eqEmpty:SetPoint("RIGHT", scroll, "RIGHT", -20, 0)
  eqEmpty:SetText("No soulbound bonuses yet. Soulbind duplicates onto gear you're wearing.")
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
        list[#list+1] = { slot = slot, name = name, tex = tex,
          nStats = #e.stats, nProcs = #e.procs }
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
  -- Player window zoom. This pop-out parents to UIParent, not to the Dashboard
  -- window that opens it, so it inherits nothing and has to register itself.
  -- (Anything parented INTO the Dashboard must NOT -- SetScale compounds.)
  if UncappedScale_Register then UncappedScale_Register(f) end

  local title = f:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
  title:SetPoint("TOP",0,-16); title:SetText("Whitelist")
  local sub = f:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
  sub:SetPoint("TOP",title,"BOTTOM",0,-2); sub:SetWidth(300)
  sub:SetText("Items whose name contains one of these are never auto-consumed.")
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT",-6,-6)

  -- search box (searches ALL items server-side as you type)
  local box = CreateFrame("EditBox", "UncappedSoulforgeWLBox", f, "InputBoxTemplate")
  box:SetPoint("TOPLEFT", 22, -54); box:SetSize(230, 20); box:SetAutoFocus(false)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  local add = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  add:SetSize(56, 22); add:SetPoint("LEFT", box, "RIGHT", 6, 0); add:SetText("Add")
  local function doAdd()
    local t = box:GetText()
    if t and t ~= "" then send("ICWLADD:" .. t); box:SetText(""); state.wlSuggest = {}; if WLM then WLM:UpdateSuggest() end end
  end
  add:SetScript("OnClick", doAdd)
  box:SetScript("OnEnterPressed", doAdd)
  box:SetScript("OnTextChanged", function(self, userInput)
    if not userInput then return end
    local t = self:GetText()
    if t and #t >= 2 then send("ICISEARCH:" .. t) else state.wlSuggest = {}; if WLM then WLM:UpdateSuggest() end end
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
-- Opened by ICEXOPEN (the scroll's OnUse). Pick an effect to pull from one item
-- (left) and the item to stamp it onto (right); Extract sends ICEXTRACT and the
-- server moves the proc, consumes the source item and one scroll.
local EXT
local exSrcRows, exTgtRows = {}, {}
local EXR_ROWS, EXR_H = 9, 26

local function itemDisplay(entry)
  local name, _, quality, _, _, _, _, _, _, tex = GetItemInfo(entry)
  local r, g, b = GetItemQualityColor(quality or 1)
  return name or ("Item #" .. tostring(entry)), tex or QUESTION, r, g, b
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

local function BuildExtractor()
  if EXT then return EXT end
  local f = CreateFrame("Frame", "UncappedExtractorFrame", UIParent)
  f:SetSize(500, 400)
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
  -- UIParent-parented pop-out: owns its own zoom (see BuildWhitelist above).
  if UncappedScale_Register then UncappedScale_Register(f) end

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -18); title:SetText("|cffb384ffScroll of Extraction|r")

  local sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  sub:SetPoint("TOP", 0, -40)
  sub:SetText("Pull an effect from one item and stamp it onto another.")

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -8, -8)

  local lh = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  lh:SetPoint("TOPLEFT", 20, -62); lh:SetText("1. Effect to pull")
  local rh = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  rh:SetPoint("TOPLEFT", 258, -62); rh:SetText("2. Item to receive it")

  -- Build one FauxScrollFrame column of selectable rows.
  local function buildColumn(name, x, rowStore, onClick)
    local scroll = CreateFrame("ScrollFrame", "UncappedExtractor" .. name, f, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", x, -82)
    scroll:SetSize(210, EXR_ROWS * EXR_H)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
      FauxScrollFrame_OnVerticalScroll(self, offset, EXR_H, function() if EXT then EXT:Refresh() end end)
    end)
    scroll.uncappedRowH = EXR_H
    scroll:SetScript("OnMouseWheel", function(self, delta)
      -- Clamped: see wheelScroll. This column had the same runaway as the socket list.
      wheelScroll(self, delta, self.uncappedCount or 0, EXR_ROWS, EXR_H,
        function() if EXT then EXT:Refresh() end end)
    end)
    for i = 1, EXR_ROWS do
      local r = CreateFrame("Button", nil, f); r:SetSize(206, EXR_H - 2)
      if i == 1 then r:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
      else r:SetPoint("TOPLEFT", rowStore[i-1], "BOTTOMLEFT", 0, -2) end
      r.sel = r:CreateTexture(nil, "BACKGROUND")
      r.sel:SetAllPoints(); r.sel:SetTexture(0.4, 0.3, 0.7, 0.5); r.sel:Hide()
      local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetTexture(1, 1, 1, 0.12)
      r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(EXR_H - 8, EXR_H - 8)
      r.icon:SetPoint("LEFT", 2, 0)
      r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      r.name:SetPoint("LEFT", r.icon, "RIGHT", 4, 4); r.name:SetWidth(168); r.name:SetJustifyH("LEFT")
      r.sub = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
      r.sub:SetPoint("LEFT", r.icon, "RIGHT", 4, -7); r.sub:SetWidth(168); r.sub:SetJustifyH("LEFT")
      r:SetScript("OnClick", function() if r.data then onClick(r.data) end end)
      r:Hide()
      rowStore[i] = r
    end
    return scroll
  end

  f.srcScroll = buildColumn("SrcScroll", 20, exSrcRows, function(d) state.exSelSrc = d; EXT:Refresh() end)
  f.tgtScroll = buildColumn("TgtScroll", 258, exTgtRows, function(d) state.exSelTgt = d; EXT:Refresh() end)

  f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.summary:SetPoint("BOTTOMLEFT", 20, 44); f.summary:SetPoint("BOTTOMRIGHT", -20, 44)
  f.summary:SetJustifyH("CENTER"); f.summary:SetHeight(28)

  local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  btn:SetSize(160, 26); btn:SetPoint("BOTTOM", 0, 14); btn:SetText("Extract")
  btn:SetScript("OnClick", function()
    local s, t = state.exSelSrc, state.exSelTgt
    if not s or not t then return end
    send(string.format("ICEXTRACT:%d:%d:%d:%d:%d:%d", s.bag, s.slot, s.spell, s.trigger, t.bag, t.slot))
  end)
  f.extractBtn = btn

  local function fillRow(r, d, isSource)
    r.data = d
    local nm, tex, cr, cg, cb = itemDisplay(d.entry)
    r.icon:SetTexture(tex)
    if isSource then
      r.name:SetText(nm); r.name:SetTextColor(cr, cg, cb)
      r.sub:SetText("|cffb384ff" .. procDisplayName({ spellId = d.spell })
        .. "|r  (" .. triggerLabel(d.trigger) .. ")")
    else
      r.name:SetText(nm .. (d.equipped == 1 and "  |cff40ff40[Worn]|r" or ""))
      r.name:SetTextColor(cr, cg, cb)
      r.sub:SetText("")
    end
    local selData = isSource and state.exSelSrc or state.exSelTgt
    if selData and selData.bag == d.bag and selData.slot == d.slot
       and (not isSource or selData.spell == d.spell) then r.sel:Show() else r.sel:Hide() end
    r:Show()
  end

  function f:Refresh()
    local src, tgt = state.exSources, state.exTargets
    self.srcScroll.uncappedCount = #src
    self.tgtScroll.uncappedCount = #tgt
    FauxScrollFrame_Update(self.srcScroll, #src, EXR_ROWS, EXR_H)
    FauxScrollFrame_Update(self.tgtScroll, #tgt, EXR_ROWS, EXR_H)
    local so = clampOffset(self.srcScroll, #src, EXR_ROWS)
    local to = clampOffset(self.tgtScroll, #tgt, EXR_ROWS)
    for i = 1, EXR_ROWS do
      local ds = src[i + so]; if ds then fillRow(exSrcRows[i], ds, true) else exSrcRows[i].data = nil; exSrcRows[i]:Hide() end
      local dt = tgt[i + to]; if dt then fillRow(exTgtRows[i], dt, false) else exTgtRows[i].data = nil; exTgtRows[i]:Hide() end
    end
    -- summary + button state
    local s, t = state.exSelSrc, state.exSelTgt
    if s and t then
      if s.bag == t.bag and s.slot == t.slot then
        self.summary:SetText("|cffff8040Pick a different item to receive the effect.|r")
        self.extractBtn:Disable()
      else
        local sn = itemDisplay(s.entry); local tn = itemDisplay(t.entry)
        self.summary:SetText(string.format("Move |cffb384ff%s|r\nfrom |cffffffff%s|r  onto  |cffffffff%s|r",
          spellName(s.spell), sn, tn))
        self.extractBtn:Enable()
      end
    elseif s then
      self.summary:SetText("Now choose the item on the right to receive |cffb384ff" .. spellName(s.spell) .. "|r.")
      self.extractBtn:Disable()
    else
      self.summary:SetText("Choose an effect on the left to pull.")
      self.extractBtn:Disable()
    end
  end

  EXT = f
  return f
end

-- Rebuild the source/target arrays from the staged ICEXI lines.
local function commitExtractItems()
  local sources, targets = {}, {}
  for _, it in pairs(state.exStaging) do
    tinsert(targets, { bag = it.bag, slot = it.slot, entry = it.entry, equipped = it.equipped })
    for _, pr in ipairs(it.procs) do
      tinsert(sources, { bag = it.bag, slot = it.slot, entry = it.entry, equipped = it.equipped,
                         spell = pr.spell, trigger = pr.trigger })
    end
  end
  local function byName(a, b) return (itemDisplay(a.entry)) < (itemDisplay(b.entry)) end
  table.sort(sources, byName); table.sort(targets, byName)
  state.exSources = sources
  state.exTargets = targets
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
  EXT:Show()
  EXT:Refresh()
  send("ICEXSRC")
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
  if UncappedScale_Register then UncappedScale_Register(f) end

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

  local scope = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  scope:SetSize(56, 21); scope:SetPoint("LEFT", filter, "RIGHT", 8, 0)
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

    local minus = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
    minus:SetSize(22, 20); minus:SetPoint("RIGHT", -4, 0); minus:SetText("-")
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
  local addBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  addBtn:SetSize(150, 26); addBtn:SetPoint("BOTTOMLEFT", RX, 44); addBtn:SetText("+ Add Socket")
  addBtn:SetScript("OnClick", function()
    local s = sockSel()
    if s then send(string.format("ICSOCKADD:%d:%d:%d", s.bag, s.slot, 1)) end
  end)
  f.addBtn = addBtn

  local function smallBtn(parent, text, w, amount)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, 20); b:SetText(text)
    b:SetScript("OnClick", function()
      local s = sockSel()
      if s then send(string.format("ICSOCKADD:%d:%d:%d", s.bag, s.slot, amount)) end
    end)
    return b
  end
  f.add10 = smallBtn(f, "x10", 40, 10); f.add10:SetPoint("BOTTOMLEFT", RX, 18)
  f.addAll = smallBtn(f, "x all", 48, 0); f.addAll:SetPoint("LEFT", f.add10, "RIGHT", 4, 0)

  local fillBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  fillBtn:SetSize(150, 26); fillBtn:SetPoint("BOTTOMRIGHT", -22, 44); fillBtn:SetText("Fill Empty")
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

    self.scopeBtn:SetText(state.sockScope)

    local t = state.sockTally
    self.tally:SetText(string.format("YOUR GEMS   meta |cffffffff%d|r  |cffff4040red|r %d  |cffffd020yel|r %d  |cff4080ff blue|r %d",
      t.meta or 0, t.red or 0, t.yellow or 0, t.blue or 0))
    local mult = math.max(1, t.meta or 0)
    self.metaWarn:SetText("Each meta gem you wear multiplies EVERY meta's colour requirement. "
      .. ("Wearing %d |cff59bfe6-> x%d|r"):format(t.meta or 0, mult))

    local scrolls = GetItemCount(500209) or 0
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

local function openSockets()
  BuildSocketUI()
  state.sockStaging = {}
  SOCK:Show()
  SOCK:Refresh()
  send("ICSOCKLIST")
  send("ICSOCKBAG")
end

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
  elseif cmd == "ICSFDING" then         -- <levelsGained>
    if UI then UI:Ding() end
    msg("|cff9CC243The Soulforge grows stronger!|r Extraction is now higher.")
  elseif cmd == "ICWL" then             -- <name>
    table.insert(state.wlStaging, rest)
  elseif cmd == "ICWLEND" then
    state.whitelist = state.wlStaging
    state.wlStaging = {}
    if WLM then WLM:Update() end
  elseif cmd == "ICINAME" then          -- <name>  item-name search hit
    table.insert(state.wlSuggestStaging, rest)
  elseif cmd == "ICINAMEEND" then
    state.wlSuggest = state.wlSuggestStaging
    state.wlSuggestStaging = {}
    if WLM then WLM:UpdateSuggest() end
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
    local n = tonumber(rest) or 0
    msg(string.format("Soulbound %d duplicate%s onto your gear.", n, n == 1 and "" or "s"))
    if UI then UI:Ding() end
    send("ICINV"); send("ICSF")
  elseif cmd == "ICEXOPEN" then         -- the scroll was used -> open the picker
    openExtractor()
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
  elseif cmd == "ICEXIEND" then
    commitExtractItems()
  elseif cmd == "ICEXOK" then           -- <spell>  extraction succeeded
    local sp = tonumber(rest)
    msg("|cff9CC243Extracted|r " .. (sp and spellName(sp) or "the effect")
        .. ". Soulbind duplicates into that item to upgrade it.")
    state.exSelSrc = nil; state.exSelTgt = nil
    PlaySoundFile(SND_SEAL)
  elseif cmd == "ICSOCKOPEN" then       -- a Scroll of Socket was used -> open the panel
    openSockets()
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
    if reason == "no_equipped_match" then
      msg("|cffff8040You can only soulbind a duplicate of an item you're wearing.|r")
    elseif reason == "nothing" then
      msg("|cffff8040No duplicates of your equipped gear were found.|r")
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
      .. "While Auto-consume is on, every |cffffffffuncommon, rare or epic|r weapon and armour "
      .. "piece you are |cffffffffnot wearing|r is rendered down for souls -- out of your bags "
      .. "|cffffffffand out of your Vault|r -- automatically, within seconds. It cannot be "
      .. "undone, and you are not asked again each time.\n\n"
      .. "Only the |cffffffffWhitelist|r protects an item.\n\nTurn Auto-consume on?",
  button1 = "Yes, destroy my spare gear", button2 = CANCEL,
  OnAccept = function() send("ICAC:1:CONFIRM") end,
  timeout = 60, whileDead = 1, hideOnEscape = 1, showAlert = 1,
}

StaticPopupDialogs["UNCAPPED_SF_SOULBIND_ALL"] = {
  text = "Soulbind every exact duplicate of the gear you're wearing (from bags AND vault) onto it?\n\nThe duplicates are consumed. This cannot be undone.",
  button1 = ACCEPT, button2 = CANCEL,
  OnAccept = function() send("ICSBALL") end,
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
    local scaled = scaleDescription(spellDescription(p.spellId), p.bases or {}, (p.mag or 100) / 100)
    if scaled then
      -- Pre-wrapped: a spell description is one long unbroken string, and neither render
      -- path wraps it for us (GameTooltip:AddLine stretches the tooltip across the screen;
      -- the companion panel's rows are fixed height and would overlap).
      for _, seg in ipairs(wrapText(scaled, TIP_WRAP_CHARS)) do
        lines[#lines+1] = { text = "  " .. seg, r = 0.62, g = 0.62, b = 0.72 }
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
    state.wlSuggest = {}
    WLM:Show(); WLM:Update(); WLM:UpdateSuggest(); send("ICWLIST")
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
  if event == "BAG_UPDATE" then
    requestInvIn(0.3)
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
  if event == "PLAYER_EQUIPMENT_CHANGED" then send("ICINV") end
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

SLASH_EXTRACT1 = "/extract"
SLASH_EXTRACT2 = "/ex"
SlashCmdList["EXTRACT"] = function()
  BuildExtractor()
  if EXT:IsShown() then EXT:Hide() else openExtractor() end
end

SLASH_SOCKET1 = "/socket"
SLASH_SOCKET2 = "/sock"
SlashCmdList["SOCKET"] = function()
  BuildSocketUI()
  if SOCK:IsShown() then SOCK:Hide() else openSockets() end
end

SLASH_ICDEBUG1 = "/sbdebug"
SlashCmdList["ICDEBUG"] = function() DEBUG = not DEBUG; msg("debug " .. (DEBUG and "ON" or "OFF")) end

dbg("Soulforge addon parsed.")
