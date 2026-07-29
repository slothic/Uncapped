--[[
  Uncapped Soulforge  (formerly Item Customize / Soulbinding)
  -----------------------------------------------------------
  Two systems:
    * The Soulforge -- a per-account bar. Junk gear you don't want is eaten for
      "souls"; each time the bar fills, a global EXTRACTION multiplier rises a
      little (forever). Auto-consume (off by default) feeds it as you play.
    * Soulbinding -- feed an EXACT DUPLICATE of an item you're WEARING onto it to
      extract (the current multiplier) of its stats and ramp its procs. "Soulbind
      Duplicates" does it in bulk from your bags + vault.

  Transport (matches the rest of the UNC pipe):
    * SEND    : SendAddonMessage("REAGENTBANK", body, "WHISPER", UnitName("player"))
    * RECEIVE : CHAT_MSG_ADDON, arg1 == "UNC", arg2 == body.

  /soulforge, /sf, /sb   open/close        /sbdebug   toggle verbose wire logging
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
local descScan = CreateFrame("GameTooltip", "UncappedICDescScan", UIParent, "GameTooltipTemplate")
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
      local fs = _G["UncappedICDescScanTextLeft" .. i]
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

-- ---- state ---------------------------------------------------------------
local state = {
  sf = { mult = 0.1, fill = 0, completions = 0, autoconsume = false, autoopen = false },  -- soulforge status
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
local UI
local eqRows = {}
local EQ_ROWS, EQ_H = 6, 34

local function BuildUI()
  if UI then return UI end

  local f = CreateFrame("Frame", "UncappedSoulforgeFrame", UIParent)
  f:SetWidth(400); f:SetHeight(494); f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetBackdrop({
    edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border", edgeSize=32,
    insets={left=11,right=12,top=12,bottom=11} })
  local solidBg = f:CreateTexture(nil,"BACKGROUND")
  solidBg:SetPoint("TOPLEFT",11,-11); solidBg:SetPoint("BOTTOMRIGHT",-12,11)
  solidBg:SetTexture(0.05, 0.04, 0.06, 1)
  local stoneBg = f:CreateTexture(nil,"BACKGROUND")
  stoneBg:SetAllPoints(solidBg)
  stoneBg:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Background")
  stoneBg:SetHorizTile(true); stoneBg:SetVertTile(true); stoneBg:SetAlpha(0.80)
  f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetClampedToScreen(true); f:Hide()

  local banner = f:CreateTexture(nil,"ARTWORK")
  banner:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
  banner:SetWidth(300); banner:SetHeight(60); banner:SetPoint("TOP", 0, 12)
  local title = f:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
  title:SetPoint("TOP", banner, "TOP", 0, -19); title:SetText("Soulforge")

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT",-6,-6)

  -- ---- forge bar ----
  local sfLabel = f:CreateFontString(nil,"OVERLAY","GameFontNormal")
  sfLabel:SetPoint("TOPLEFT", 22, -44); sfLabel:SetText("|cff9a7bffThe Soulforge|r")
  local sfLevel = f:CreateFontString(nil,"OVERLAY","GameFontHighlight")
  sfLevel:SetPoint("TOPRIGHT", -22, -44); f.sfLevel = sfLevel

  local bar = CreateFrame("StatusBar", nil, f)
  bar:SetSize(356, 20); bar:SetPoint("TOPLEFT", 22, -62)
  bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  bar:SetStatusBarColor(0.55, 0.35, 0.95)
  bar:SetMinMaxValues(0, 1000); bar:SetValue(0)
  bar:SetBackdrop({ bgFile="Interface\\Buttons\\WHITE8X8",
    edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", edgeSize=12,
    insets={left=3,right=3,top=3,bottom=3} })
  bar:SetBackdropColor(0,0,0,0.6); bar:SetBackdropBorderColor(0.4,0.4,0.5)
  local barText = bar:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
  barText:SetPoint("CENTER"); f.sfBar = bar; f.sfBarText = barText

  local sfExtract = f:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
  sfExtract:SetPoint("TOPLEFT", 22, -88); f.sfExtract = sfExtract
  local sfHint = f:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
  sfHint:SetPoint("TOPLEFT", 22, -110); sfHint:SetWidth(356); sfHint:SetJustifyH("LEFT")
  sfHint:SetText("Feed junk gear to the forge to raise the extraction rate. Soulbinding a duplicate onto gear you're wearing extracts that share of its stats.")

  -- ---- controls ----
  local ac = CreateFrame("CheckButton", "UncappedSoulforgeAC", f, "InterfaceOptionsCheckButtonTemplate")
  ac:SetPoint("TOPLEFT", 20, -142)
  _G[ac:GetName().."Text"]:SetText("Auto-consume junk gear \226\134\146 souls + transmog")
  ac:SetScript("OnClick", function(self) send("ICAC:" .. (self:GetChecked() and 1 or 0)) end)
  f.acCheck = ac

  local ao = CreateFrame("CheckButton", "UncappedSoulforgeAO", f, "InterfaceOptionsCheckButtonTemplate")
  ao:SetPoint("TOPLEFT", 20, -166)
  _G[ao:GetName().."Text"]:SetText("Auto-melt Sacks \226\134\146 souls + transmog + duplicates")
  ao:SetScript("OnClick", function(self) send("ICAO:" .. (self:GetChecked() and 1 or 0)) end)
  f.aoCheck = ao

  local sbBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  sbBtn:SetSize(170, 24); sbBtn:SetPoint("TOPLEFT", 22, -194); sbBtn:SetText("Soulbind Duplicates")
  sbBtn:SetScript("OnClick", function() StaticPopup_Show("UNCAPPED_SF_SOULBIND_ALL") end)

  local wlBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  wlBtn:SetSize(170, 24); wlBtn:SetPoint("TOPRIGHT", -22, -194); wlBtn:SetText("Whitelist\226\128\166")
  wlBtn:SetScript("OnClick", function() if UI and UI.OpenWhitelist then UI:OpenWhitelist() end end)

  -- ---- your soulbound gear ----
  local eqHdr = f:CreateFontString(nil,"OVERLAY","GameFontNormal")
  eqHdr:SetPoint("TOPLEFT", 22, -228); eqHdr:SetText("|cff40c0f0Your soulbound gear|r")
  local dLine = f:CreateTexture(nil,"ARTWORK"); dLine:SetTexture("Interface\\Buttons\\WHITE8X8")
  dLine:SetGradientAlpha("HORIZONTAL", 0.25,0.60,0.90,0.6, 0.25,0.60,0.90,0.0)
  dLine:SetHeight(2); dLine:SetWidth(340); dLine:SetPoint("TOPLEFT", 22, -244)

  local scroll = CreateFrame("ScrollFrame", "UncappedSoulforgeEqScroll", f, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 24, -252); scroll:SetSize(348, EQ_ROWS*EQ_H)
  scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, EQ_H, function() if UI then UI:RefreshEquipped() end end)
  end)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local sb = _G["UncappedSoulforgeEqScrollScrollBar"]; if sb then sb:SetValue(sb:GetValue() - delta*EQ_H) end
  end)
  f.eqScroll = scroll

  for i = 1, EQ_ROWS do
    local r = CreateFrame("Frame", nil, f); r:SetSize(340, EQ_H-2)
    r:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(i-1)*EQ_H)
    r.icon = r:CreateTexture(nil,"ARTWORK"); r.icon:SetSize(28,28)
    r.icon:SetPoint("LEFT",2,0); r.icon:SetTexCoord(0.08,0.92,0.08,0.92)
    r.name = r:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    r.name:SetPoint("TOPLEFT",36,-1); r.name:SetWidth(300); r.name:SetJustifyH("LEFT")
    r.sub = r:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
    r.sub:SetPoint("TOPLEFT",36,-15); r.sub:SetWidth(300); r.sub:SetJustifyH("LEFT")
    eqRows[i] = r; r:Hide()
  end
  local eqEmpty = f:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
  eqEmpty:SetPoint("TOP", scroll, "TOP", 0, -30); eqEmpty:SetWidth(320)
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
    self.aoCheck:SetChecked(sf.autoopen)
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

    FauxScrollFrame_Update(self.eqScroll, #list, EQ_ROWS, EQ_H)
    if #list == 0 then self.eqEmpty:Show() else self.eqEmpty:Hide() end
    local offset = FauxScrollFrame_GetOffset(self.eqScroll)
    for i = 1, EQ_ROWS do
      local r = eqRows[i]; local e = list[i + offset]
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
    scroll:SetScript("OnMouseWheel", function(self, delta)
      FauxScrollFrame_OnVerticalScroll(self, (FauxScrollFrame_GetOffset(self) - delta) * EXR_H, EXR_H,
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
    FauxScrollFrame_Update(self.srcScroll, #src, EXR_ROWS, EXR_H)
    FauxScrollFrame_Update(self.tgtScroll, #tgt, EXR_ROWS, EXR_H)
    local so = FauxScrollFrame_GetOffset(self.srcScroll)
    local to = FauxScrollFrame_GetOffset(self.tgtScroll)
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
      state.sf.autoopen = ao == "1"
      if UI then UI:RefreshForge() end
    end
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
    sbStaging[rest] = { stats = {}, procs = {} }
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
  elseif cmd == "ICERR" then
    local op, reason = rest:match("^(%a+):(.+)$")
    if reason == "no_equipped_match" then
      msg("|cffff8040You can only soulbind a duplicate of an item you're wearing.|r")
    elseif reason == "nothing" then
      msg("|cffff8040No duplicates of your equipped gear were found.|r")
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

-- ---- StaticPopup: confirm Soulbind Duplicates ----------------------------
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
  if event == "BAG_UPDATE" then requestInvIn(0.3) end
  if event == "PLAYER_EQUIPMENT_CHANGED" then send("ICINV") end
end)

SLASH_SOULFORGE1 = "/soulforge"
SLASH_SOULFORGE2 = "/sf"
SLASH_SOULFORGE3 = "/soulbind"
SLASH_SOULFORGE4 = "/sb"
SlashCmdList["SOULFORGE"] = function()
  BuildUI(); attachMethods(); attachWhitelistOpener()
  if UI:IsShown() then
    UI:Hide()
    if WLM then WLM:Hide() end
  else
    UI:Show(); UI:Refresh()
    send("ICSF"); send("ICINV")
  end
end

SLASH_EXTRACT1 = "/extract"
SLASH_EXTRACT2 = "/ex"
SlashCmdList["EXTRACT"] = function()
  BuildExtractor()
  if EXT:IsShown() then EXT:Hide() else openExtractor() end
end

SLASH_ICDEBUG1 = "/sbdebug"
SlashCmdList["ICDEBUG"] = function() DEBUG = not DEBUG; msg("debug " .. (DEBUG and "ON" or "OFF")) end

dbg("Soulforge addon parsed.")
