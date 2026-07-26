--[[
  Uncapped Item Customize  ->  Soulbinding
  ----------------------------------------
  Consume a source item to copy its stat block + procs onto a target ("bench")
  item, additively. Deposit an equipped item as the target, then soulbind bag
  items into it (one at a time, or all at once).

  Transport (matches the rest of the UNC pipe):
    * SEND    : SendAddonMessage("REAGENTBANK", body, "WHISPER", UnitName("player"))
    * RECEIVE : CHAT_MSG_ADDON, arg1 == "UNC", arg2 == body.

  Everything on the wire is numeric (item entries, ITEM_MOD stat ints, spell ids);
  this addon resolves item/spell names + icons itself (GetItemInfo / GetSpellInfo).

  /soulbind, /sb   open/close        /sbdebug   toggle verbose wire logging
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
  DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[IC]|r " .. table.concat(parts, " "))
end
local function msg(text)
  DEFAULT_CHAT_FRAME:AddMessage("|cffffd200Soulbinding:|r " .. text)
end

-- ---- name tables ---------------------------------------------------------
local STAT_NAMES = {
  [0]="Mana",[1]="Health",[3]="Agility",[4]="Strength",[5]="Intellect",[6]="Spirit",[7]="Stamina",
  [12]="Defense Rating",[13]="Dodge Rating",[14]="Parry Rating",[15]="Block Rating",
  [16]="Melee Hit Rating",[17]="Ranged Hit Rating",[18]="Spell Hit Rating",
  [19]="Melee Crit Rating",[20]="Ranged Crit Rating",[21]="Spell Crit Rating",
  [28]="Melee Haste Rating",[29]="Ranged Haste Rating",[30]="Spell Haste Rating",
  [31]="Hit Rating",[32]="Crit Rating",[33]="Hit Avoidance",[34]="Crit Avoidance",
  [35]="Resilience Rating",[36]="Haste Rating",[37]="Expertise Rating",
  [38]="Attack Power",[39]="Ranged Attack Power",[41]="Spell Healing",[42]="Spell Damage",
  [43]="Mana Regen",[44]="Armor Penetration",[45]="Spell Power",[46]="Health Regen",
  [47]="Spell Penetration",[48]="Block Value",
  -- resistance pseudo-codes (60 + school): 1=holy .. 6=arcane
  [61]="Holy Resistance",[62]="Fire Resistance",[63]="Nature Resistance",
  [64]="Frost Resistance",[65]="Shadow Resistance",[66]="Arcane Resistance",
}
local function statName(t) return STAT_NAMES[t] or ("Stat #" .. tostring(t)) end

local TRIGGER_NAMES = { [0]="On Use", [1]="On Equip", [2]="On Hit", [3]="On Cast" }
local function triggerName(t) return TRIGGER_NAMES[t] or ("Trigger " .. tostring(t)) end

-- How a proc is LABELLED to the player. Only On Hit / On Cast actually roll the
-- soulbind chance; On Equip is a passive (always active) and On Use is a clicky.
-- Calling those "On Equip"/"On Use" plus a % chance is what confused everyone, so
-- passives read "Passive" and never show a chance.
local TRIGGER_LABEL = { [0]="On Use", [1]="Passive", [2]="On Hit", [3]="On Cast" }
local function triggerLabel(t) return TRIGGER_LABEL[t] or ("Trigger " .. tostring(t)) end
local function spellName(id)
  local n = GetSpellInfo(id)
  return n or ("Spell #" .. tostring(id))
end

-- magnitude percent (100 = 1.0x) -> tidy "1.5" style multiplier string
local function fmtMult(magPct)
  local m = (tonumber(magPct) or 100) / 100
  local s = string.format("%.2f", m)
  s = s:gsub("0+$", ""):gsub("%.$", "")
  return s
end

-- The mechanic clause for a proc. Chance-rolled procs (On Hit / On Cast) show
-- their % chance; passives and on-use effects have no chance, so they show only
-- how far their effect has been upgraded (the power multiplier) -- which is the
-- ONLY thing re-soulbinding raises for them.
local function procMechanic(p)
  local mult = fmtMult(p.mag)
  if p.trigger == 2 or p.trigger == 3 then
    if mult ~= "1" then
      return string.format("%d%% chance, %sx power", p.chance or 0, mult)
    end
    return string.format("%d%% chance", p.chance or 0)
  end
  -- Passive / On Use: no chance, just the (upgradable) effect strength.
  if mult ~= "1" then
    return string.format("%sx power", mult)
  end
  return "base effect"
end

-- Hidden scanning tooltip so rows can show a short "what it does" snippet.
local scanTip = CreateFrame("GameTooltip", "ICScanTip", nil, "GameTooltipTemplate")
local descCache = {}
local function spellDesc(id)
  if descCache[id] ~= nil then return descCache[id] end
  scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
  scanTip:ClearLines()
  scanTip:SetHyperlink("spell:" .. id)
  local best = ""   -- the longest tooltip line is almost always the description
  for i = 2, scanTip:NumLines() do
    local fs = _G["ICScanTipTextLeft" .. i]
    local t = fs and fs:GetText()
    if t and #t > #best then best = t end
  end
  if #best > 92 then best = best:sub(1, 90) .. "..." end
  descCache[id] = best
  return best
end

-- ---- animation constants (ported from SoulbindPreview: anim #6 Soul Wisps) --
local SPARK  = "Interface\\Cooldown\\star4"
local GLOW   = "Interface\\SpellActivationOverlay\\IconAlert"
local BORDER = "Interface\\Buttons\\UI-ActionButton-Border"
local SND_GATHER = "Sound\\Spells\\SimonGame_Visual_GameStart.wav"
local SND_SEAL   = "Sound\\Spells\\SoulstoneResurrection_Base.wav"

local function clamp01(x) return x < 0 and 0 or (x > 1 and 1 or x) end
local function easeOut(p) p = clamp01(p); return 1 - (1 - p) * (1 - p) end
local function easeIn(p)  p = clamp01(p); return p * p end
local function easeInOut(p) p = clamp01(p); return p < 0.5 and 2*p*p or 1 - (-2*p+2)^2/2 end

-- ---- state ---------------------------------------------------------------
local state = {
  bench = nil,                 -- { guid, entry, stats={{type,value}}, procs={{spellId,trigger,chance,mag}} }
  bags = {}, bagsStaging = {}, -- source candidates { {bag,slot,entry} }
  details = {},                -- rendered accumulated stat/proc rows for the bench
}

local function send(body)
  dbg("-> " .. body)
  SendAddonMessage(SEND_PREFIX, body, "WHISPER", UnitName("player"))
end

-- ---- soulbound-item tooltip cache ----------------------------------------
-- Data is keyed by CLIENT slot position because the 3.3.5 item link/tooltip API
-- exposes no item-instance GUID. Keys match what the tooltip hooks compute:
--   "E:<invSlot>"      equipped, invSlot 1..19        (SetInventoryItem "player")
--   "B:<bag>:<slot>"   bags, bag 0=backpack / 1..4, slot 1-based  (SetBagItem)
-- Each entry: { stats = {{type,value}...}, procs = {{spellId,trigger,chance,mag}...} }.
-- Built into `sbStaging` as ICITEM/ICISTAT/ICIPROC arrive, swapped in on ICINVEND.
local sbInv = {}
local sbStaging, sbCurKey = {}, nil

-- ============================ UI ==========================================
local UI
local sourceRows, detailRows = {}, {}

local DETAIL_ROWS, DETAIL_H = 5, 22
local SOURCE_ROWS, SOURCE_H = 6, 30

local function BuildUI()
  if UI then return UI end

  local f = CreateFrame("Frame", "UncappedItemCustomizeFrame", UIParent)
  f:SetWidth(440); f:SetHeight(600); f:SetPoint("CENTER")
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
  banner:SetWidth(320); banner:SetHeight(60); banner:SetPoint("TOP", 0, 12)
  local title = f:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
  title:SetPoint("TOP", banner, "TOP", 0, -19); title:SetText("Soulbinding")

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT",-6,-6)

  -- ============ DEPOSIT panel (shown when there is no bench target) =========
  local dp = CreateFrame("Frame", nil, f)
  dp:SetPoint("TOPLEFT",20,-52); dp:SetPoint("BOTTOMRIGHT",-20,20); f.depositPanel = dp

  local dollHint = dp:CreateFontString(nil,"OVERLAY","GameFontNormal")
  dollHint:SetPoint("TOP",0,-4); dollHint:SetWidth(390)
  dollHint:SetText("Click an equipped item to deposit it as the target you want to empower.")

  local LEFT   = { "HeadSlot","NeckSlot","ShoulderSlot","BackSlot","ChestSlot","ShirtSlot","TabardSlot","WristSlot" }
  local RIGHT  = { "HandsSlot","WaistSlot","LegsSlot","FeetSlot","Finger0Slot","Finger1Slot","Trinket0Slot","Trinket1Slot" }
  local BOTTOM = { "MainHandSlot","SecondaryHandSlot","RangedSlot" }
  f.dollSlots = {}

  local function makeSlot(name, x, y)
    local id = GetInventorySlotInfo(name)
    local b = CreateFrame("Button", nil, dp)
    b:SetWidth(40); b:SetHeight(40); b:SetPoint("TOPLEFT", x, y)
    b:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8X8",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    b:SetBackdropColor(0, 0, 0, 0.6)
    b:SetBackdropBorderColor(0.45, 0.40, 0.55)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 4, -4); b.icon:SetPoint("BOTTOMRIGHT", -4, 4)
    b.icon:SetTexCoord(0.08,0.92,0.08,0.92)
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    b.slotId = id; b.slotName = name
    b:SetScript("OnClick", function(self)
      if GetInventoryItemTexture("player", self.slotId) then send("ICDEPOSIT:"..(self.slotId-1)) else msg("That slot is empty.") end
    end)
    b:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      if GetInventoryItemLink("player", self.slotId) then GameTooltip:SetInventoryItem("player", self.slotId)
      else GameTooltip:SetText("Empty " .. name:gsub("Slot","")) end
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.dollSlots[#f.dollSlots+1] = b
  end

  local topY, stepY = -34, -50
  for i, s in ipairs(LEFT)   do makeSlot(s, 8,   topY + (i-1)*stepY) end
  for i, s in ipairs(RIGHT)  do makeSlot(s, 352, topY + (i-1)*stepY) end
  for i, s in ipairs(BOTTOM) do makeSlot(s, 120 + (i-1)*50, -448) end

  -- ============ WORK panel (shown once a bench target exists) ==============
  local wp = CreateFrame("Frame", nil, f)
  wp:SetPoint("TOPLEFT",20,-52); wp:SetPoint("BOTTOMRIGHT",-20,20); f.workPanel = wp

  -- target item icon (also the animation anchor)
  local benchItem = CreateFrame("Frame", nil, wp)
  benchItem:SetWidth(40); benchItem:SetHeight(40)
  benchItem:SetPoint("CENTER", wp, "TOPLEFT", 30, -30)
  benchItem.icon = benchItem:CreateTexture(nil,"ARTWORK")
  benchItem.icon:SetAllPoints(); benchItem.icon:SetTexCoord(0.08,0.92,0.08,0.92)
  local benchFrameTex = benchItem:CreateTexture(nil,"OVERLAY")
  benchFrameTex:SetPoint("TOPLEFT",-5,5); benchFrameTex:SetPoint("BOTTOMRIGHT",5,-5)
  benchFrameTex:SetTexture("Interface\\Buttons\\UI-Quickslot2")
  f.benchItem = benchItem
  benchItem:EnableMouse(true)
  benchItem:SetScript("OnEnter", function(self)
    if not (state.bench and state.bench.entry) then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink("item:"..state.bench.entry); GameTooltip:Show()
  end)
  benchItem:SetScript("OnLeave", function() GameTooltip:Hide() end)

  local benchLabel = wp:CreateFontString(nil,"OVERLAY","GameFontHighlightLarge")
  benchLabel:SetPoint("LEFT", benchItem, "RIGHT", 10, 6); benchLabel:SetWidth(230); benchLabel:SetJustifyH("LEFT")
  f.benchLabel = benchLabel
  local benchSub = wp:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
  benchSub:SetPoint("TOPLEFT", benchLabel, "BOTTOMLEFT", 0, -2); benchSub:SetText("Target item (soulbound)")

  local retrieveBtn = CreateFrame("Button", nil, wp, "UIPanelButtonTemplate")
  retrieveBtn:SetWidth(78); retrieveBtn:SetHeight(20); retrieveBtn:SetPoint("TOPRIGHT",0,-4); retrieveBtn:SetText("Retrieve")
  retrieveBtn:SetScript("OnClick", function() send("ICRETRIEVE") end)

  -- accumulated stats/procs header + divider
  local detailHdr = wp:CreateFontString(nil,"OVERLAY","GameFontNormal")
  detailHdr:SetPoint("TOPLEFT",2,-62); detailHdr:SetText("|cff9a7bffBound powers|r")
  local dLine = wp:CreateTexture(nil,"ARTWORK"); dLine:SetTexture("Interface\\Buttons\\WHITE8X8")
  dLine:SetGradientAlpha("HORIZONTAL", 0.55,0.35,0.95,0.6, 0.55,0.35,0.95,0.0)
  dLine:SetHeight(2); dLine:SetWidth(300); dLine:SetPoint("TOPLEFT", 2, -78)

  local detailScroll = CreateFrame("ScrollFrame", "ICDetailScroll", wp, "FauxScrollFrameTemplate")
  detailScroll:SetPoint("TOPLEFT", 6, -84)
  detailScroll:SetWidth(384); detailScroll:SetHeight(DETAIL_ROWS * DETAIL_H)
  detailScroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, DETAIL_H, function() if UI then UI:UpdateDetails() end end)
  end)
  detailScroll:EnableMouseWheel(true)
  detailScroll:SetScript("OnMouseWheel", function(self, delta)
    local sb = _G["ICDetailScrollScrollBar"]; if sb then sb:SetValue(sb:GetValue() - delta * DETAIL_H) end
  end)
  f.detailScroll = detailScroll

  for i = 1, DETAIL_ROWS do
    local r = CreateFrame("Frame", nil, wp)
    r:SetWidth(378); r:SetHeight(DETAIL_H - 2)
    r:SetPoint("TOPLEFT", detailScroll, "TOPLEFT", 0, -(i-1)*DETAIL_H)
    r:EnableMouse(true)
    r:SetScript("OnEnter", function(self)
      if not self.sid then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink("spell:" .. self.sid); GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r.icon = r:CreateTexture(nil,"ARTWORK"); r.icon:SetWidth(16); r.icon:SetHeight(16)
    r.icon:SetPoint("LEFT",2,0); r.icon:SetTexCoord(0.08,0.92,0.08,0.92)
    r.text = r:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    r.text:SetPoint("LEFT",22,0); r.text:SetWidth(330); r.text:SetJustifyH("LEFT")
    -- per-power remove: strips just this bound stat/proc off the target
    r.removeBtn = CreateFrame("Button", nil, r)
    r.removeBtn:SetWidth(18); r.removeBtn:SetHeight(18); r.removeBtn:SetPoint("RIGHT", 0, 0)
    r.removeBtn:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    r.removeBtn:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Highlight")
    r.removeBtn:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText("Remove this bound power"); GameTooltip:Show()
    end)
    r.removeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r.removeBtn:SetScript("OnClick", function()
      local e = r.detail
      if not e then return end
      local itemName = state.bench and (GetItemInfo(state.bench.entry) or ("Item "..state.bench.entry)) or "the target"
      StaticPopup_Show("UNCAPPED_IC_REMOVE", e.label or "this power", itemName, e)
    end)
    detailRows[i] = r; r:Hide()
  end

  local emptyDetail = wp:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
  emptyDetail:SetPoint("TOPLEFT",8,-90); emptyDetail:SetWidth(360); emptyDetail:SetJustifyH("LEFT")
  emptyDetail:SetText("No stats or procs bound yet. Soulbind an item below.")
  f.emptyDetail = emptyDetail

  -- source list header + divider
  local srcHdr = wp:CreateFontString(nil,"OVERLAY","GameFontNormal")
  srcHdr:SetPoint("TOPLEFT",2,-202); srcHdr:SetText("|cff40c0f0Items in your bags|r")
  local sLine = wp:CreateTexture(nil,"ARTWORK"); sLine:SetTexture("Interface\\Buttons\\WHITE8X8")
  sLine:SetGradientAlpha("HORIZONTAL", 0.25,0.60,0.90,0.6, 0.25,0.60,0.90,0.0)
  sLine:SetHeight(2); sLine:SetWidth(300); sLine:SetPoint("TOPLEFT", 2, -218)
  local srcNote = wp:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
  srcNote:SetPoint("TOPLEFT",2,-222); srcNote:SetText("Soulbinding an item consumes it permanently.")

  local sourceScroll = CreateFrame("ScrollFrame", "ICSourceScroll", wp, "FauxScrollFrameTemplate")
  sourceScroll:SetPoint("TOPLEFT", 6, -238)
  sourceScroll:SetWidth(384); sourceScroll:SetHeight(SOURCE_ROWS * SOURCE_H)
  sourceScroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, SOURCE_H, function() if UI then UI:UpdateSources() end end)
  end)
  sourceScroll:EnableMouseWheel(true)
  sourceScroll:SetScript("OnMouseWheel", function(self, delta)
    local sb = _G["ICSourceScrollScrollBar"]; if sb then sb:SetValue(sb:GetValue() - delta * SOURCE_H) end
  end)
  f.sourceScroll = sourceScroll

  local srcInset = CreateFrame("Frame", nil, wp)
  srcInset:SetPoint("TOPLEFT", 2, -234); srcInset:SetPoint("TOPRIGHT", -2, -234)
  srcInset:SetHeight(SOURCE_ROWS * SOURCE_H + 8)
  srcInset:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 } })
  srcInset:SetBackdropColor(0, 0, 0, 0.35); srcInset:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.6)
  srcInset:SetFrameLevel(sourceScroll:GetFrameLevel()-1 >= 0 and sourceScroll:GetFrameLevel()-1 or 0)

  for i = 1, SOURCE_ROWS do
    local r = CreateFrame("Frame", nil, wp)
    r:SetWidth(372); r:SetHeight(SOURCE_H - 2)
    r:SetPoint("TOPLEFT", sourceScroll, "TOPLEFT", 0, -(i-1)*SOURCE_H)
    r.iconBtn = CreateFrame("Button", nil, r)
    r.iconBtn:SetWidth(24); r.iconBtn:SetHeight(24); r.iconBtn:SetPoint("LEFT",2,0)
    r.iconBtn.tex = r.iconBtn:CreateTexture(nil,"ARTWORK")
    r.iconBtn.tex:SetAllPoints(); r.iconBtn.tex:SetTexCoord(0.08,0.92,0.08,0.92)
    r.iconBtn:SetScript("OnEnter", function(self)
      if not r.entry then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink("item:"..r.entry); GameTooltip:Show()
    end)
    r.iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r.name = r:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    r.name:SetPoint("LEFT",32,0); r.name:SetWidth(240); r.name:SetJustifyH("LEFT")
    r.btn = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
    r.btn:SetWidth(74); r.btn:SetHeight(20); r.btn:SetPoint("RIGHT",2,0); r.btn:SetText("Soulbind")
    r.btn:SetScript("OnClick", function()
      if r.bag and r.slot then send("ICSB:"..r.bag..":"..r.slot) end
    end)
    sourceRows[i] = r; r:Hide()
  end

  local emptySource = wp:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
  emptySource:SetPoint("TOP", sourceScroll, "TOP", 0, -30); emptySource:SetWidth(340)
  emptySource:SetText("No bag items with stats or procs to soulbind.")
  f.emptySource = emptySource

  -- Soulbind ALL
  local allBtn = CreateFrame("Button", nil, wp, "UIPanelButtonTemplate")
  allBtn:SetWidth(200); allBtn:SetHeight(24); allBtn:SetPoint("BOTTOM",0,4)
  allBtn:SetText("Soulbind ALL in bags")
  allBtn:SetScript("OnClick", function()
    local n = state.bench and (GetItemInfo(state.bench.entry) or ("Item "..state.bench.entry)) or "the target"
    StaticPopup_Show("UNCAPPED_IC_SOULBIND_ALL", n)
  end)
  f.allBtn = allBtn

  wp:Hide()

  -- ============ animation engine (ported: SoulbindPreview anim #6) =========
  local ITEM_SIZE, BASE_X, BASE_Y = 40, 30, -30
  local itemGlow = benchItem:CreateTexture(nil,"OVERLAY")
  itemGlow:SetBlendMode("ADD"); itemGlow:SetTexture(GLOW); itemGlow:SetPoint("CENTER")
  itemGlow:SetWidth(ITEM_SIZE*2); itemGlow:SetHeight(ITEM_SIZE*2); itemGlow:SetAlpha(0)
  local itemBorder = benchItem:CreateTexture(nil,"OVERLAY")
  itemBorder:SetBlendMode("ADD"); itemBorder:SetTexture(BORDER); itemBorder:SetPoint("CENTER")
  itemBorder:SetWidth(ITEM_SIZE*1.6); itemBorder:SetHeight(ITEM_SIZE*1.6); itemBorder:SetAlpha(0)

  local fx = CreateFrame("Frame", nil, UIParent)
  fx:SetWidth(700); fx:SetHeight(700); fx:SetFrameStrata("FULLSCREEN_DIALOG")
  local flash = UIParent:CreateTexture(nil, "OVERLAY")
  flash:SetBlendMode("ADD"); flash:SetTexture(1,1,1); flash:SetAllPoints(UIParent)
  flash:SetAlpha(0); flash:SetDrawLayer("OVERLAY", 7)

  local tasks, pool = {}, {}
  local driver = CreateFrame("Frame")
  local function addTask(fn) tasks[#tasks + 1] = { fn = fn, t = 0 } end
  driver:SetScript("OnUpdate", function(_, dt)
    for i = #tasks, 1, -1 do
      local task = tasks[i]; task.t = task.t + dt
      if task.fn(task.t, dt) then table.remove(tasks, i) end
    end
  end)
  local function getTex()
    local t = table.remove(pool)
    if not t then t = fx:CreateTexture(nil, "OVERLAY") end
    t:SetParent(fx); t:SetTexture(SPARK); t:SetBlendMode("ADD")
    t:SetVertexColor(1,1,1); t:SetAlpha(1); t:ClearAllPoints(); t:Show()
    return t
  end
  local function release(t) t:Hide(); t:ClearAllPoints(); pool[#pool + 1] = t end
  local function spark(o)
    local t = getTex()
    if o.tex then t:SetTexture(o.tex) end
    if o.color then t:SetVertexColor(o.color[1], o.color[2], o.color[3]) end
    local fi, fo = o.fadeIn or 0.15, o.fadeOut or 0.3
    addTask(function(elapsed)
      local p = elapsed / o.dur
      if p >= 1 then release(t); return true end
      local x, y = o.pos(p)
      local s = o.sz and o.sz(p) or o.size
      t:SetWidth(s); t:SetHeight(s)
      t:SetPoint("CENTER", fx, "CENTER", x, y)
      local a = 1
      if p < fi then a = p / fi elseif p > (1 - fo) then a = (1 - p) / fo end
      t:SetAlpha(a * (o.alpha or 1))
      return false
    end)
  end
  local function pulse(color, maxSize, dur, startSize)
    spark({ tex = GLOW, color = color, dur = dur, fadeIn = 0.05, fadeOut = 0.6,
      pos = function() return 0, 0 end,
      sz = function(p) return (startSize or 40) + (maxSize - (startSize or 40)) * easeOut(p) end,
      alpha = 0.8 })
  end
  local function itemEmpower(dur, peak, color)
    itemGlow:SetVertexColor(color[1], color[2], color[3])
    addTask(function(elapsed)
      local p = elapsed / dur
      if p >= 1 then itemGlow:SetAlpha(0); return true end
      local a = math.sin(p * math.pi)
      itemGlow:SetAlpha(a * (peak or 0.9))
      local s = ITEM_SIZE*1.6 + ITEM_SIZE*1.1 * a
      itemGlow:SetWidth(s); itemGlow:SetHeight(s)
      return false
    end)
  end
  local function itemBounce(dur, strength)
    addTask(function(elapsed)
      local p = elapsed / dur
      if p >= 1 then benchItem:SetScale(1); benchItem:SetPoint("CENTER", wp, "TOPLEFT", BASE_X, BASE_Y); return true end
      local s = math.sin(p * math.pi)
      benchItem:SetScale(1 + (strength or 0.35) * s)
      benchItem:SetPoint("CENTER", wp, "TOPLEFT", BASE_X, BASE_Y + 22 * s)
      return false
    end)
  end
  local function itemBorderFlash(dur, color)
    itemBorder:SetVertexColor(color[1], color[2], color[3])
    addTask(function(elapsed)
      local p = elapsed / dur
      if p >= 1 then itemBorder:SetAlpha(0); return true end
      itemBorder:SetAlpha(math.sin(p * math.pi))
      return false
    end)
  end
  local function screenFlash(peak, dur, color)
    if color then flash:SetVertexColor(color[1], color[2], color[3]) else flash:SetVertexColor(1,1,1) end
    addTask(function(elapsed)
      local p = elapsed / dur
      if p >= 1 then flash:SetAlpha(0); return true end
      flash:SetAlpha((1 - p) * peak)
      return false
    end)
  end
  local function after(t, fn)
    addTask(function(elapsed) if elapsed >= t then fn(); return true end return false end)
  end

  -- Soul Wisps: purple wisps gather on wavy paths, item empowers + pops, seal.
  function f:PlaySoulWisps()
    if not benchItem:IsVisible() then return end
    fx:ClearAllPoints(); fx:SetPoint("CENTER", benchItem, "CENTER", 0, 0)
    local col = { 0.72, 0.45, 1.0 }   -- spectral purple
    PlaySoundFile(SND_GATHER)          -- gathering shimmer
    local N = 12
    for i = 1, N do
      after((i / N) * 0.4, function()
        local ang0 = math.random() * math.pi * 2
        local r0 = 180 + math.random() * 60
        local wob = 40 + math.random() * 30
        local wfreq = 2 + math.random() * 2
        local sx, sy = math.cos(ang0) * r0, math.sin(ang0) * r0
        local px, py = -math.sin(ang0), math.cos(ang0)   -- perpendicular
        spark({ color = col, size = 22, dur = 1.1, fadeIn = 0.15, fadeOut = 0.25,
          pos = function(p)
            local e = easeInOut(p)
            local w = math.sin(p * math.pi * wfreq) * wob * (1 - p)
            return sx * (1 - e) + px * w, sy * (1 - e) + py * w
          end,
          sz = function(p) return 22 * (0.6 + 0.4 * math.sin(p * math.pi)) end })
      end)
    end
    itemEmpower(1.4, 0.85, col)
    after(1.15, function()
      itemBounce(0.5, 0.3); itemBorderFlash(0.6, col)
      pulse(col, 280, 0.7); screenFlash(0.3, 0.5, col)
      PlaySoundFile(SND_SEAL)
    end)
  end

  UI = f
  return f
end

-- ---- methods -------------------------------------------------------------
local function attachMethods()
  if UI.UpdateDetails then return end

  function UI:UpdateDetails()
    local list = state.details
    FauxScrollFrame_Update(self.detailScroll, #list, DETAIL_ROWS, DETAIL_H)
    if #list == 0 then self.emptyDetail:Show() else self.emptyDetail:Hide() end
    local offset = FauxScrollFrame_GetOffset(self.detailScroll)
    for i = 1, DETAIL_ROWS do
      local r = detailRows[i]
      local e = list[i + offset]
      if e then
        r.sid = e.sid; r.detail = e
        if e.icon then r.icon:SetTexture(e.icon); r.icon:Show() else r.icon:Hide() end
        r.text:SetText(e.text)
        r:Show()
      else
        r.sid = nil; r.detail = nil; r:Hide()
      end
    end
  end

  function UI:UpdateSources()
    local list = state.bags
    FauxScrollFrame_Update(self.sourceScroll, #list, SOURCE_ROWS, SOURCE_H)
    if #list == 0 then self.emptySource:Show() else self.emptySource:Hide() end
    local offset = FauxScrollFrame_GetOffset(self.sourceScroll)
    for i = 1, SOURCE_ROWS do
      local r = sourceRows[i]
      local e = list[i + offset]
      if e then
        local iname, _, _, _, _, _, _, _, _, itex = GetItemInfo(e.entry)
        r.bag = e.bag; r.slot = e.slot; r.entry = e.entry
        r.iconBtn.tex:SetTexture(itex or QUESTION)
        r.name:SetText(iname or ("Item " .. e.entry))
        r:Show()
      else
        r.bag = nil; r.slot = nil; r.entry = nil; r:Hide()
      end
    end
  end

  function UI:RefreshDoll()
    for _, b in ipairs(self.dollSlots) do
      b.icon:SetTexture(GetInventoryItemTexture("player", b.slotId) or QUESTION)
    end
  end

  -- Build the merged accumulated stat/proc display list from the bench.
  local function buildDetails()
    local out = {}
    if state.bench then
      for _, s in ipairs(state.bench.stats) do
        out[#out+1] = {
          kind = "stat", statType = s.type,
          label = string.format("+%s %s", tostring(s.value), statName(s.type)),
          text = string.format("|cff20ff20+%s|r %s", tostring(s.value), statName(s.type)),
        }
      end
      for _, p in ipairs(state.bench.procs) do
        local nm, _, icon = GetSpellInfo(p.spellId)
        out[#out+1] = {
          kind = "proc", spellId = p.spellId, trigger = p.trigger,
          sid = p.spellId, icon = icon,
          label = nm or ("Spell #"..p.spellId),
          text = string.format("|cffc080f0%s|r |cff888888(%s)|r — %s",
            nm or ("Spell #"..p.spellId), triggerLabel(p.trigger), procMechanic(p)),
        }
      end
    end
    state.details = out
  end

  function UI:Refresh()
    if not state.bench then
      self.workPanel:Hide(); self.depositPanel:Show()
      self:RefreshDoll()
      return
    end
    self.depositPanel:Hide(); self.workPanel:Show()
    local bname, _, _, _, _, _, _, _, _, btex = GetItemInfo(state.bench.entry)
    self.benchItem.icon:SetTexture(btex or QUESTION)
    self.benchLabel:SetText("|cffffff00" .. (bname or ("Item "..state.bench.entry)) .. "|r")
    buildDetails()
    self:UpdateDetails()
    self:UpdateSources()
  end
end

-- ============================ receive =====================================
local function OnLine(body)
  dbg("<- " .. body)
  local cmd, rest = body:match("^(%u+):?(.*)$")
  if not cmd then cmd = body; rest = "" end

  if cmd == "ICBENCH" then
    if rest == "0" then
      state.bench = nil
      if UI then UI:Refresh() end   -- empty bench sends no ICBENCHEND; switch back to the deposit menu now
    else
      local guid, entry = rest:match("^(%d+):(%d+)$")
      if guid then state.bench = { guid = tonumber(guid), entry = tonumber(entry), stats = {}, procs = {} } end
    end
  elseif cmd == "ICBSTAT" then          -- <statType>:<value>  (value int64 as string)
    local t, v = rest:match("^(%d+):(%-?%d+)$")
    if t and state.bench then table.insert(state.bench.stats, { type = tonumber(t), value = v }) end
  elseif cmd == "ICBPROC" then          -- <spellId>:<trigger>:<chancePctInt>:<magPctInt>
    local sid, tr, ch, mg = rest:match("^(%d+):(%d+):(%d+):(%d+)$")
    if sid and state.bench then
      table.insert(state.bench.procs, { spellId = tonumber(sid), trigger = tonumber(tr), chance = tonumber(ch), mag = tonumber(mg) })
    end
  elseif cmd == "ICBENCHEND" then
    if UI then UI:Refresh() end
  elseif cmd == "ICBAG" then            -- <bag>:<slot>:<entry>
    local bag, slot, entry = rest:match("^(%-?%d+):(%d+):(%d+)$")
    if bag then table.insert(state.bagsStaging, { bag = tonumber(bag), slot = tonumber(slot), entry = tonumber(entry) }) end
  elseif cmd == "ICBAGEND" then         -- <count>
    state.bags = state.bagsStaging
    state.bagsStaging = {}
    if UI then UI:UpdateSources() end
  elseif cmd == "ICEQUIP" then
    -- deposit candidates (existing); this addon uses the client-side paper doll,
    -- so we accept and ignore the list to keep the pipe quiet.
  elseif cmd == "ICEQUIPEND" then
    -- no-op (paper doll reads equipment locally)
  elseif cmd == "ICITEM" then           -- <tag>  begins one soulbound item (E:n or B:b:s)
    sbCurKey = rest
    sbStaging[rest] = { stats = {}, procs = {} }
  elseif cmd == "ICISTAT" then          -- <statType>:<value>  (value int64 as string)
    local t, v = rest:match("^(%d+):(%-?%d+)$")
    if t and sbCurKey and sbStaging[sbCurKey] then
      table.insert(sbStaging[sbCurKey].stats, { type = tonumber(t), value = v })
    end
  elseif cmd == "ICIPROC" then          -- <spellId>:<trigger>:<chancePctInt>:<magPctInt>
    local sid, tr, ch, mg = rest:match("^(%d+):(%d+):(%d+):(%d+)$")
    if sid and sbCurKey and sbStaging[sbCurKey] then
      table.insert(sbStaging[sbCurKey].procs,
        { spellId = tonumber(sid), trigger = tonumber(tr), chance = tonumber(ch), mag = tonumber(mg) })
    end
  elseif cmd == "ICINVEND" then         -- swap the freshly-built cache in
    sbInv = sbStaging
    sbStaging = {}
    sbCurKey = nil
  elseif cmd == "ICBOUND" then          -- <sourceEntry>  (single soulbind ok)
    local entry = tonumber(rest)
    local nm = entry and GetItemInfo(entry) or nil
    msg("Soulbound " .. (nm or ("item " .. tostring(rest))) .. " into your target.")
    if UI then UI:PlaySoulWisps() end
    send("ICBENCH"); send("ICBAGS"); send("ICINV")
  elseif cmd == "ICBOUNDALL" then       -- <count>
    local n = tonumber(rest) or 0
    msg(string.format("Soulbound %d item%s into your target.", n, n == 1 and "" or "s"))
    if UI then UI:PlaySoulWisps() end
    send("ICBENCH"); send("ICBAGS"); send("ICINV")
  elseif cmd == "ICREMOVED" then       -- <statType>:<honorRefund>:<arenaRefund>  (server also re-sends the bench)
    local t = tonumber(rest:match("^(%-?%d+)"))
    msg("Removed " .. (t and statName(t) or "a stat") .. " from your target.")
  elseif cmd == "ICPREMOVED" then      -- <spellId>:<honorRefund>:<arenaRefund>
    local sid = tonumber(rest:match("^(%d+)"))
    msg("Removed " .. (sid and spellName(sid) or "a proc") .. " from your target.")
  elseif cmd == "ICCFG" then
    -- minimal cfg on open; nothing the new UI needs, accept quietly.
  elseif cmd == "ICERR" then
    local op, reason = rest:match("^(%a+):(.+)$")
    msg("|cffff4040" .. tostring(op) .. " failed:|r " .. tostring(reason))
  else
    dbg("unhandled:", body)
  end
end

-- ---- StaticPopup: confirm Soulbind ALL -----------------------------------
StaticPopupDialogs["UNCAPPED_IC_SOULBIND_ALL"] = {
  text = "Consume ALL items in your bags that have stats/procs and bind them into %s?\n\nThis cannot be undone.",
  button1 = ACCEPT, button2 = CANCEL,
  OnAccept = function() send("ICSBALL") end,
  timeout = 0, whileDead = 1, hideOnEscape = 1, showAlert = 1,
}

-- ---- StaticPopup: confirm removing one bound power -----------------------
-- Removal strips a single soulbound stat/proc off the target. It does NOT give
-- back the item that was consumed to grant it, so we confirm first.
StaticPopupDialogs["UNCAPPED_IC_REMOVE"] = {
  text = "Remove |cffffffff%s|r from %s?\n\nThe item that granted it is not returned.",
  button1 = ACCEPT, button2 = CANCEL,
  OnAccept = function(self, e)
    if not e then return end
    if e.kind == "stat" then send("ICREMOVE:" .. e.statType)
    elseif e.kind == "proc" then send("ICPREMOVE:" .. e.spellId) end
  end,
  timeout = 0, whileDead = 1, hideOnEscape = 1, showAlert = 1,
}

-- ============================ tooltip injection ===========================
-- Append the cached soulbound data onto GameTooltip AFTER the default tooltip
-- builds (hooksecurefunc), then Show() to resize. Data is matched by the client
-- slot key. Guard against double-injection by scanning for our marker line: a
-- "Set" method rebuilds the tooltip from scratch (wiping our lines), so if the
-- marker is still present the tooltip was not rebuilt and we must not re-append.
--
-- Short bound-power blocks stay inline. Once a block would be long it overflows
-- the bottom of the screen with no way to read it, so past a threshold we move it
-- into a scrollable panel anchored to the tooltip and leave only a pointer inline.
local SB_MARK = "|cff66ccffSoulbound|r"
local TIP_MAX_INLINE = 12          -- bound-power lines shown inline before switching to the panel
local TIP_ROWS, TIP_ROW_H = 16, 14

-- ---- scrollable companion panel ------------------------------------------
-- Hide is deferred so the player can slide the cursor off the item and onto the
-- panel to scroll it: leaving the item schedules a hide, entering the panel
-- cancels it, leaving the panel hides it immediately.
local sbTip
local sbTipHideDue
local sbTipHideTimer = CreateFrame("Frame")
sbTipHideTimer:Hide()
local function cancelSbTipHide() sbTipHideDue = nil; sbTipHideTimer:Hide() end
local function scheduleSbTipHide()
  if sbTip and sbTip:IsShown() then sbTipHideDue = 0.25; sbTipHideTimer:Show() end
end
sbTipHideTimer:SetScript("OnUpdate", function(self, elapsed)
  if not sbTipHideDue then self:Hide(); return end
  sbTipHideDue = sbTipHideDue - elapsed
  if sbTipHideDue <= 0 then
    sbTipHideDue = nil; self:Hide()
    if sbTip and not MouseIsOver(sbTip) then sbTip:Hide() end
  end
end)

local function buildSbTip()
  if sbTip then return sbTip end
  local f = CreateFrame("Frame", "ICSoulboundTip", UIParent)
  f:SetFrameStrata("TOOLTIP"); f:SetFrameLevel(100)
  f:SetWidth(288); f:SetHeight(TIP_ROWS * TIP_ROW_H + 40)
  f:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 } })
  f:SetBackdropColor(0.03, 0.02, 0.05, 0.95)
  f:SetBackdropBorderColor(0.55, 0.4, 0.9, 0.9)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:Hide()

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 12, -10); title:SetText(SB_MARK)

  local scroll = CreateFrame("ScrollFrame", "ICSoulboundTipScroll", f, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 8, -28); scroll:SetWidth(256); scroll:SetHeight(TIP_ROWS * TIP_ROW_H)
  scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, TIP_ROW_H, function() f:Fill() end)
  end)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local sb = _G["ICSoulboundTipScrollScrollBar"]; if sb then sb:SetValue(sb:GetValue() - delta * TIP_ROW_H * 3) end
  end)
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
  f:SetScript("OnLeave", function() f:Hide() end)

  sbTip = f
  return f
end

local function showSbTip(lines)
  local f = buildSbTip()
  f.lines = lines
  local sb = _G["ICSoulboundTipScrollScrollBar"]; if sb then sb:SetValue(0) end
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", GameTooltip, "TOPRIGHT", 6, 0)
  f:Show(); f:Fill()
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
    scheduleSbTipHide()   -- hovered something without soulbound data: drop any open panel
    return
  end
  if alreadyInjected(tt) then return end   -- already injected on this build

  -- Flatten the bound powers to display lines once (shared by inline + panel).
  local lines = {}
  for _, s in ipairs(e.stats) do
    lines[#lines+1] = { text = "+" .. tostring(s.value) .. " " .. statName(s.type), r = 0.12, g = 1, b = 0.12 }
  end
  for _, p in ipairs(e.procs) do
    lines[#lines+1] = { text = spellName(p.spellId) .. " (" .. triggerLabel(p.trigger) .. ") — " .. procMechanic(p),
      r = 0.75, g = 0.5, b = 0.94 }
  end

  tt:AddLine(" ")
  tt:AddLine(SB_MARK)
  if #lines <= TIP_MAX_INLINE then
    for _, ln in ipairs(lines) do tt:AddLine(ln.text, ln.r, ln.g, ln.b) end
    if sbTip and sbTip:IsShown() then sbTip:Hide() end   -- short: no panel needed
  else
    tt:AddLine("|cffffd200" .. #lines .. " bound powers|r — scroll the panel to view", 1, 1, 1)
    showSbTip(lines)
  end
  tt:Show()
end

-- Leaving the item hides the tooltip; schedule the panel to follow unless the
-- cursor lands on it (to scroll). Entering a new item re-runs Inject, which
-- cancels the schedule if that item is also soulbound.
GameTooltip:HookScript("OnHide", function() scheduleSbTipHide() end)

hooksecurefunc(GameTooltip, "SetBagItem", function(tt, bag, slot)
  Inject(tt, "B:" .. bag .. ":" .. slot)
end)
hooksecurefunc(GameTooltip, "SetInventoryItem", function(tt, unit, invSlot)
  if unit == "player" then Inject(tt, "E:" .. invSlot) end
end)

-- ============================ events / slash ==============================
-- Lightweight timer for ICINV requests: a PLAYER_LOGIN warm-up (~2s) and a
-- BAG_UPDATE debounce (~0.3s) so a burst of bag events sends only one request.
local invTimer = CreateFrame("Frame")
local invDue = nil
invTimer:Hide()
invTimer:SetScript("OnUpdate", function(self, elapsed)
  if not invDue then self:Hide(); return end
  invDue = invDue - elapsed
  if invDue <= 0 then
    invDue = nil
    self:Hide()
    send("ICINV")
  end
end)
local function requestInvIn(delay) invDue = delay; invTimer:Show() end
local function requestInv() send("ICINV") end

local listener = CreateFrame("Frame")
listener:RegisterEvent("CHAT_MSG_ADDON")
listener:RegisterEvent("PLAYER_LOGIN")
listener:RegisterEvent("BAG_UPDATE")
listener:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
listener:RegisterEvent("UNIT_INVENTORY_CHANGED")
listener:SetScript("OnEvent", function(self, event, a1, a2)
  if event == "CHAT_MSG_ADDON" then
    if a1 == PIPE_PREFIX and a2 and a2:sub(1,2) == "IC" then OnLine(a2) end
    return
  end
  if event == "PLAYER_LOGIN" then
    dbg("loaded. /soulbind (or /sb) to open.")
    requestInvIn(2)                       -- warm the soulbound tooltip cache
    return
  end
  if event == "BAG_UPDATE" then requestInvIn(0.3) end
  if event == "PLAYER_EQUIPMENT_CHANGED" then requestInv() end
  if event == "UNIT_INVENTORY_CHANGED" and a1 == "player" then requestInv() end
  -- keep the paper doll / source list live while the window is open
  if UI and UI:IsShown() then
    if event == "PLAYER_EQUIPMENT_CHANGED" and UI.RefreshDoll and not state.bench then UI:RefreshDoll() end
  end
end)

SLASH_ICUST1 = "/soulbind"
SLASH_ICUST2 = "/sb"
SlashCmdList["ICUST"] = function()
  BuildUI(); attachMethods()
  if UI:IsShown() then
    UI:Hide()
  else
    state.bench = nil; state.bags = {}; state.bagsStaging = {}; state.details = {}
    UI:Show(); UI:Refresh()
    dbg("opening -> ICOPEN"); send("ICOPEN")
  end
end

SLASH_ICDEBUG1 = "/sbdebug"
SlashCmdList["ICDEBUG"] = function() DEBUG = not DEBUG; msg("debug " .. (DEBUG and "ON" or "OFF")) end

dbg("file parsed.")
