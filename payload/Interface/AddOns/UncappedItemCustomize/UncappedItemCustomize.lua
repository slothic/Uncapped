--[[
  Uncapped Item Customize
  ------------------------
  Workbench for adding custom (64-bit) stats AND procs to a specific item instance.

  Transport (matches the rest of the UNC pipe):
    * SEND    : SendAddonMessage("REAGENTBANK", body, "WHISPER", UnitName("player"))
    * RECEIVE : CHAT_MSG_ADDON, arg1 == "UNC", arg2 == body.

  Everything on the wire is numeric (item entries, ITEM_MOD stat ints, spell ids);
  this addon resolves item/spell names + icons itself (GetItemInfo / GetSpellInfo).

  /ic       open/close        /icdebug   toggle verbose wire logging
]]

local SEND_PREFIX = "REAGENTBANK"
local PIPE_PREFIX = "UNC"

-- ---- debug ---------------------------------------------------------------
local DEBUG = true
local function dbg(...)
  if not DEBUG then return end
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[IC]|r " .. table.concat(parts, " "))
end
local function msg(text)
  DEFAULT_CHAT_FRAME:AddMessage("|cffffd200Item Customize:|r " .. text)
end

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
}
local function statName(t) return STAT_NAMES[t] or ("Stat #" .. tostring(t)) end

local TRIGGER_NAMES = { [0]="On Use", [1]="On Equip", [2]="On Hit", [3]="On Cast" }
local function triggerName(t) return TRIGGER_NAMES[t] or ("Trigger " .. tostring(t)) end
local function spellName(id)
  local n = GetSpellInfo(id)
  return n or ("Spell #" .. tostring(id))
end

-- Hidden scanning tooltip so result rows can show a short "what it does" snippet.
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

-- ---- state ---------------------------------------------------------------
local state = {
  cfg = { addCost = 1, refundPct = 20, maxRank = 1000 },
  honor = 0, arena = 0,
  catalogue = {},
  equip = {}, equipComplete = false,
  bench = nil,               -- { guid, entry, stats={}, procs={} }
  addType = nil,             -- selected stat type
  allProcs = {},             -- full pool: array of { id, name } sorted by name
  allAccum = {},             -- accumulator while ICPALL chunks arrive
  procResults = {},          -- spell ids currently displayed (all, or name-filtered)
  addTrigger = 1,            -- selected trigger for a new proc (default On Equip)
  tipCache = {},             -- locKey -> { stats={{type,value}}, procs={{spellId,trigger}} }
  tipStaging = {},           -- being filled by the current ICITEMS response
}

local function send(body)
  dbg("-> " .. body)
  SendAddonMessage(SEND_PREFIX, body, "WHISPER", UnitName("player"))
end

-- ============================ UI ==========================================
local UI
local rows = { equip = {}, stat = {}, proc = {}, result = {} }

-- Client-side name filter over the full pool. Empty query = show everything.
local function filterProcs(q)
  q = tostring(q or ""):lower()
  state.procResults = {}
  for _, e in ipairs(state.allProcs) do
    if q == "" or e.name:lower():find(q, 1, true) then
      table.insert(state.procResults, e.id)
    end
  end
  if UI then
    local sb = _G["ICResultScrollScrollBar"]; if sb then sb:SetValue(0) end
    if UI.editPanel then UI.editPanel.searchHdr:SetText(string.format("%d of %d spells (type to filter):", #state.procResults, #state.allProcs)) end
    UI:UpdateResults()
  end
end

local function BuildUI()
  if UI then return UI end

  local f = CreateFrame("Frame", "UncappedItemCustomizeFrame", UIParent)
  f:SetWidth(460); f:SetHeight(600); f:SetPoint("CENTER")
  -- ornate border only; the fill is our own opaque textured panel below
  f:SetBackdrop({
    edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border", edgeSize=32,
    insets={left=11,right=12,top=12,bottom=11} })
  -- opaque backing (so the world doesn't bleed through) + a stone texture over it
  local solidBg = f:CreateTexture(nil,"BACKGROUND")
  solidBg:SetPoint("TOPLEFT",11,-11); solidBg:SetPoint("BOTTOMRIGHT",-12,11)
  solidBg:SetTexture(0.05, 0.04, 0.035, 1)
  local stoneBg = f:CreateTexture(nil,"BACKGROUND")
  stoneBg:SetAllPoints(solidBg)
  stoneBg:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Background")
  stoneBg:SetHorizTile(true); stoneBg:SetVertTile(true); stoneBg:SetAlpha(0.82)
  f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetClampedToScreen(true); f:Hide()

  -- gold header banner with the title
  local banner = f:CreateTexture(nil,"ARTWORK")
  banner:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
  banner:SetWidth(340); banner:SetHeight(60); banner:SetPoint("TOP", 0, 12)
  local title = f:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
  title:SetPoint("TOP", banner, "TOP", 0, -19); title:SetText("Item Customization")

  local honor = f:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
  honor:SetPoint("TOPRIGHT",-30,-18); f.honor = honor

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT",-6,-6)

  local hint = f:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
  hint:SetPoint("TOPLEFT",22,-42); hint:SetWidth(410); hint:SetJustifyH("LEFT"); f.hint = hint

  -- DEPOSIT panel: a character-sheet-style paper-doll. Click an equipped slot to
  -- deposit that item. Uses the client's own empty-slot art (GetInventorySlotInfo).
  local dp = CreateFrame("Frame", nil, f)
  dp:SetPoint("TOPLEFT",20,-64); dp:SetPoint("BOTTOMRIGHT",-20,20); f.depositPanel = dp

  local dollHint = dp:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
  dollHint:SetPoint("TOP",0,-2); dollHint:SetWidth(400); dollHint:SetText("Click an equipped item to deposit it for customizing.")

  local LEFT   = { "HeadSlot","NeckSlot","ShoulderSlot","BackSlot","ChestSlot","ShirtSlot","TabardSlot","WristSlot" }
  local RIGHT  = { "HandsSlot","WaistSlot","LegsSlot","FeetSlot","Finger0Slot","Finger1Slot","Trinket0Slot","Trinket1Slot" }
  local BOTTOM = { "MainHandSlot","SecondaryHandSlot","RangedSlot" }
  f.dollSlots = {}

  local function makeSlot(name, x, y)
    local id, emptyTex = GetInventorySlotInfo(name)
    local b = CreateFrame("Button", nil, dp)
    b:SetWidth(40); b:SetHeight(40); b:SetPoint("TOPLEFT", x, y)
    -- clean slot frame: dark bg + thin border, no overlapping textures
    b:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8X8",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    b:SetBackdropColor(0, 0, 0, 0.6)
    b:SetBackdropBorderColor(0.45, 0.45, 0.45)
    -- ONE icon texture: the equipped item, or the empty-slot silhouette when empty
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 4, -4); b.icon:SetPoint("BOTTOMRIGHT", -4, 4)
    b.emptyTex = emptyTex
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

  local topY, stepY = -28, -50   -- stepY is negative = downward
  for i, s in ipairs(LEFT)  do makeSlot(s, 8,   topY + (i-1)*stepY) end
  for i, s in ipairs(RIGHT) do makeSlot(s, 372, topY + (i-1)*stepY) end
  for i, s in ipairs(BOTTOM) do makeSlot(s, 130 + (i-1)*50, -450) end

  -- EDIT panel
  local ep = CreateFrame("Frame", nil, f)
  ep:SetPoint("TOPLEFT",20,-64); ep:SetPoint("BOTTOMRIGHT",-20,20); f.editPanel = ep

  ep.benchIcon = ep:CreateTexture(nil,"ARTWORK")
  ep.benchIcon:SetWidth(20); ep.benchIcon:SetHeight(20); ep.benchIcon:SetPoint("TOPLEFT",2,-1)
  ep.benchIcon:SetTexCoord(0.08,0.92,0.08,0.92)
  ep.benchLabel = ep:CreateFontString(nil,"OVERLAY","GameFontHighlight")
  ep.benchLabel:SetPoint("TOPLEFT",26,-3); ep.benchLabel:SetWidth(390); ep.benchLabel:SetJustifyH("LEFT")

  -- ---- STATS band (fixed) --------------------------------------------
  local statHdr = ep:CreateFontString(nil,"OVERLAY","GameFontNormal")
  statHdr:SetPoint("TOPLEFT",2,-24); statHdr:SetText("|cff40c0f0Stats|r")
  local statLine = ep:CreateTexture(nil,"ARTWORK"); statLine:SetTexture("Interface\\Buttons\\WHITE8X8")
  statLine:SetGradientAlpha("HORIZONTAL", 0.25,0.60,0.90,0.6, 0.25,0.60,0.90,0.0)
  statLine:SetHeight(2); statLine:SetWidth(300); statLine:SetPoint("TOPLEFT", 2, -40)

  -- add-stat controls: pick a stat type, Add for 1 honor (starts at rank 1).
  -- Bigger values come from upgrading the rank with arena (per-row buttons).
  local addStatBtn = CreateFrame("Button", nil, ep, "UIPanelButtonTemplate")
  addStatBtn:SetWidth(96); addStatBtn:SetHeight(20); addStatBtn:SetPoint("TOPRIGHT",0,-150); addStatBtn:SetText("Add (1 honor)")
  ep.addStatBtn = addStatBtn

  local statDrop = CreateFrame("Frame","UncappedICStatDropdown",ep,"UIDropDownMenuTemplate")
  statDrop:SetPoint("TOPLEFT",-14,-146); ep.statDrop = statDrop

  local costText = ep:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
  costText:SetPoint("TOPLEFT",6,-172); costText:SetText("Add a stat for 1 honor, then upgrade its rank with arena points.")
  ep.costText = costText

  -- ---- PROCS band (fixed) --------------------------------------------
  local procHdr = ep:CreateFontString(nil,"OVERLAY","GameFontNormal")
  procHdr:SetPoint("TOPLEFT",2,-196); procHdr:SetText("|cffc040f0Procs|r")
  local procLine = ep:CreateTexture(nil,"ARTWORK"); procLine:SetTexture("Interface\\Buttons\\WHITE8X8")
  procLine:SetGradientAlpha("HORIZONTAL", 0.75,0.25,0.90,0.6, 0.75,0.25,0.90,0.0)
  procLine:SetHeight(2); procLine:SetWidth(300); procLine:SetPoint("TOPLEFT", 2, -212)

  -- add-proc: search + trigger + results (fixed lower band)
  local searchBox = CreateFrame("EditBox","UncappedICSearchBox",ep,"InputBoxTemplate")
  searchBox:SetWidth(150); searchBox:SetHeight(18); searchBox:SetPoint("TOPLEFT",10,-320)
  searchBox:SetAutoFocus(false); searchBox:SetMaxLetters(40); ep.searchBox = searchBox

  local searchBtn = CreateFrame("Button", nil, ep, "UIPanelButtonTemplate")
  searchBtn:SetWidth(60); searchBtn:SetHeight(20); searchBtn:SetPoint("LEFT",searchBox,"RIGHT",6,0); searchBtn:SetText("Clear")
  searchBtn:SetScript("OnClick", function() searchBox:SetText(""); filterProcs("") end)
  -- instant client-side filter over the full pool as you type
  searchBox:SetScript("OnTextChanged", function(self) filterProcs(self:GetText()) end)
  searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

  local trigDrop = CreateFrame("Frame","UncappedICTrigDropdown",ep,"UIDropDownMenuTemplate")
  trigDrop:SetPoint("LEFT",searchBtn,"RIGHT",-4,0); ep.trigDrop = trigDrop

  local searchHdr = ep:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
  searchHdr:SetPoint("TOPLEFT",12,-344); searchHdr:SetText(""); ep.searchHdr = searchHdr

  -- scrollable results list: name + a short "what it does" snippet per row
  local RESULT_ROWS, RESULT_H = 5, 26
  ep.RESULT_ROWS, ep.RESULT_H = RESULT_ROWS, RESULT_H
  -- recessed panel behind the results so the list reads as its own area
  local resultInset = CreateFrame("Frame", nil, ep)
  resultInset:SetPoint("TOPLEFT", 2, -358); resultInset:SetPoint("TOPRIGHT", -2, -358)
  resultInset:SetHeight(RESULT_ROWS * RESULT_H + 8)
  resultInset:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 } })
  resultInset:SetBackdropColor(0, 0, 0, 0.35)
  resultInset:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.6)
  local resultScroll = CreateFrame("ScrollFrame", "ICResultScroll", ep, "FauxScrollFrameTemplate")
  resultScroll:SetPoint("TOPLEFT", 6, -362)
  resultScroll:SetWidth(392); resultScroll:SetHeight(RESULT_ROWS * RESULT_H)
  resultScroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, RESULT_H, function() if UI then UI:UpdateResults() end end)
  end)
  resultScroll:EnableMouseWheel(true)
  resultScroll:SetScript("OnMouseWheel", function(self, delta)
    local sb = _G["ICResultScrollScrollBar"]
    if sb then sb:SetValue(sb:GetValue() - delta * RESULT_H) end
  end)
  ep.resultScroll = resultScroll

  for i = 1, RESULT_ROWS do
    local r = CreateFrame("Frame", nil, ep)
    r:SetWidth(384); r:SetHeight(RESULT_H - 2)
    r:SetPoint("TOPLEFT", resultScroll, "TOPLEFT", 0, -(i-1)*RESULT_H)
    r:EnableMouse(true)
    r:SetScript("OnEnter", function(self)
      if not self.sid then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink("spell:" .. self.sid); GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r.name = r:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); r.name:SetPoint("TOPLEFT",2,-1); r.name:SetWidth(300); r.name:SetJustifyH("LEFT")
    r.desc = r:CreateFontString(nil,"OVERLAY","GameFontDisableSmall"); r.desc:SetPoint("TOPLEFT",8,-13); r.desc:SetWidth(305); r.desc:SetJustifyH("LEFT")
    r.add = CreateFrame("Button", nil, r, "UIPanelButtonTemplate"); r.add:SetWidth(46); r.add:SetHeight(18); r.add:SetPoint("RIGHT",4,3); r.add:SetText("Add")
    r.add:SetScript("OnClick", function() if r.sid then send("ICPADD:"..r.sid..":"..state.addTrigger) end end)
    rows.result[i] = r
    r:Hide()
  end

  -- ---- retrieve (bottom) ---------------------------------------------
  local retrieveBtn = CreateFrame("Button", nil, ep, "UIPanelButtonTemplate")
  retrieveBtn:SetWidth(150); retrieveBtn:SetHeight(22); retrieveBtn:SetPoint("BOTTOMLEFT",0,0); retrieveBtn:SetText("Retrieve to bags")
  retrieveBtn:SetScript("OnClick", function() send("ICRETRIEVE") end)

  -- stat dropdown
  UIDropDownMenu_Initialize(statDrop, function()
    for _, t in ipairs(state.catalogue) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = statName(t); info.value = t
      info.func = function(self)
        state.addType = self.value
        UIDropDownMenu_SetSelectedValue(statDrop, self.value)
        UIDropDownMenu_SetText(statDrop, statName(self.value))
      end
      UIDropDownMenu_AddButton(info)
    end
  end)
  UIDropDownMenu_SetWidth(statDrop, 120); UIDropDownMenu_SetText(statDrop, "Choose a stat")

  -- trigger dropdown
  UIDropDownMenu_Initialize(trigDrop, function()
    for t = 1, 3 do  -- On-equip / On-hit / On-cast selectable here; On-use (0) too
      local info = UIDropDownMenu_CreateInfo()
      info.text = triggerName(t); info.value = t
      info.func = function(self)
        state.addTrigger = self.value
        UIDropDownMenu_SetSelectedValue(trigDrop, self.value)
        UIDropDownMenu_SetText(trigDrop, triggerName(self.value))
      end
      UIDropDownMenu_AddButton(info)
    end
    local info = UIDropDownMenu_CreateInfo()
    info.text = triggerName(0); info.value = 0
    info.func = function(self)
      state.addTrigger = 0
      UIDropDownMenu_SetSelectedValue(trigDrop, 0)
      UIDropDownMenu_SetText(trigDrop, triggerName(0))
    end
    UIDropDownMenu_AddButton(info)
  end)
  UIDropDownMenu_SetWidth(trigDrop, 90); UIDropDownMenu_SetText(trigDrop, triggerName(state.addTrigger))

  addStatBtn:SetScript("OnClick", function()
    if not state.addType then msg("Pick a stat first."); return end
    send("ICADD:" .. state.addType)
  end)

  ep:Hide()   -- edit panel stays hidden until a bench item exists (Refresh toggles)

  UI = f
  return f
end

-- ---- methods -------------------------------------------------------------
local function attachMethods()
  function UI:RefreshHonor()
    self.honor:SetText(string.format("|cffff8040Honor:|r %d   |cff40a0ffArena:|r %d", state.honor, state.arena))
  end

  function UI:RefreshDoll()
    for _, b in ipairs(self.dollSlots) do
      -- item icon if equipped, else the empty-slot silhouette -- one texture, no overlap
      b.icon:SetTexture(GetInventoryItemTexture("player", b.slotId) or b.emptyTex)
    end
  end

  function UI:UpdateResults()
    local ep = self.editPanel
    local n = #state.procResults
    FauxScrollFrame_Update(ep.resultScroll, n, ep.RESULT_ROWS, ep.RESULT_H)
    local offset = FauxScrollFrame_GetOffset(ep.resultScroll)
    for i = 1, ep.RESULT_ROWS do
      local r = rows.result[i]
      local sid = state.procResults[i + offset]
      if sid then
        r.sid = sid
        r.name:SetText(spellName(sid) .. " |cff666666#" .. sid .. "|r")
        r.desc:SetText(spellDesc(sid))
        r:Show()
      else
        r.sid = nil; r:Hide()
      end
    end
  end

  function UI:RefreshCost() end   -- (kept as a no-op; adds are a flat honor cost now)

  function UI:Refresh()
    self:RefreshHonor()
    for _, r in ipairs(rows.equip)  do r:Hide() end
    for _, r in ipairs(rows.stat)   do r:Hide() end
    for _, r in ipairs(rows.proc)   do r:Hide() end
    for _, r in ipairs(rows.result) do r:Hide() end

    if not state.bench then
      self.editPanel:Hide(); self.depositPanel:Show()
      self.hint:SetText("")
      self:RefreshDoll()
      return
    end

    self.depositPanel:Hide(); self.editPanel:Show(); self.hint:SetText("")
    local ep = self.editPanel
    local bname, _, _, _, _, _, _, _, _, btex = GetItemInfo(state.bench.entry)
    ep.benchIcon:SetTexture(btex or "Interface\\Icons\\INV_Misc_QuestionMark")
    ep.benchLabel:SetText("Editing: |cffffff00" .. (bname or ("Item "..state.bench.entry)) .. "|r")

    -- stat rows (band y -44 .. -140): "+value StatName  R<rank>"  [Upgrade Narena] [Remove]
    local y = -44
    for i, s in ipairs(state.bench.stats) do
      local r = rows.stat[i]
      if not r then
        r = CreateFrame("Frame", nil, ep); r:SetWidth(410); r:SetHeight(18)
        r.label = r:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall"); r.label:SetPoint("LEFT",4,0); r.label:SetWidth(190); r.label:SetJustifyH("LEFT")
        r.rem = CreateFrame("Button", nil, r, "UIPanelButtonTemplate"); r.rem:SetWidth(58); r.rem:SetHeight(18); r.rem:SetPoint("RIGHT",0,0); r.rem:SetText("Remove")
        r.up  = CreateFrame("Button", nil, r, "UIPanelButtonTemplate"); r.up:SetWidth(90); r.up:SetHeight(18); r.up:SetPoint("RIGHT",r.rem,"LEFT",-3,0)
        rows.stat[i] = r
      end
      r:SetPoint("TOPLEFT",6,y)
      r.label:SetText(string.format("|cff20ff20+%s|r %s |cff888888R%d|r", s.value, statName(s.type), s.rank or 1))
      r.rem.stype = s.type
      r.rem:SetScript("OnClick", function(self2) send("ICREMOVE:"..self2.stype) end)
      if s.nextCost and s.nextCost > 0 then
        r.up:SetText("Up (" .. s.nextCost .. "\226\154\148)")   -- crossed-swords glyph = arena
        r.up:Enable(); r.up.stype = s.type
        r.up:SetScript("OnClick", function(self2) send("ICSUP:"..self2.stype) end)
      else
        r.up:SetText("Max"); r.up:Disable()
      end
      r:Show(); y = y - 20
    end

    -- proc rows (band y -216 .. -312)
    y = -216
    for i, p in ipairs(state.bench.procs) do
      local r = rows.proc[i]
      if not r then
        r = CreateFrame("Frame", nil, ep); r:SetWidth(410); r:SetHeight(20)
        r:EnableMouse(true)
        r:SetScript("OnEnter", function(self)
          if not self.sid then return end
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
          GameTooltip:SetHyperlink("spell:" .. self.sid)
          GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r.label = r:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall"); r.label:SetPoint("LEFT",4,0); r.label:SetWidth(210); r.label:SetJustifyH("LEFT")
        r.rem = CreateFrame("Button", nil, r, "UIPanelButtonTemplate"); r.rem:SetWidth(54); r.rem:SetHeight(18); r.rem:SetPoint("RIGHT",0,0); r.rem:SetText("Remove")
        r.mag = CreateFrame("Button", nil, r, "UIPanelButtonTemplate"); r.mag:SetWidth(58); r.mag:SetHeight(18); r.mag:SetPoint("RIGHT",r.rem,"LEFT",-3,0); r.mag:SetText("+M")
        r.chc = CreateFrame("Button", nil, r, "UIPanelButtonTemplate"); r.chc:SetWidth(58); r.chc:SetHeight(18); r.chc:SetPoint("RIGHT",r.mag,"LEFT",-3,0); r.chc:SetText("+C")
        rows.proc[i] = r
      end
      r:SetPoint("TOPLEFT",6,y)
      r.sid = p.spellId
      r.label:SetText(string.format("%s |cff888888(%s C%d M%d)|r", spellName(p.spellId), triggerName(p.trigger), p.chanceRank, p.magRank))
      r.rem.sid = p.spellId; r.chc.sid = p.spellId; r.mag.sid = p.spellId
      r.rem:SetScript("OnClick", function(s2) send("ICPREMOVE:"..s2.sid) end)
      -- upgrade buttons show the next arena cost; disabled at max rank
      if p.nextC and p.nextC > 0 then
        r.chc:SetText("+C " .. p.nextC); r.chc:Enable()
        r.chc:SetScript("OnClick", function(s2) send("ICPUP:"..s2.sid..":0") end)
      else r.chc:SetText("+C"); r.chc:Disable() end
      if p.nextM and p.nextM > 0 then
        r.mag:SetText("+M " .. p.nextM); r.mag:Enable()
        r.mag:SetScript("OnClick", function(s2) send("ICPUP:"..s2.sid..":1") end)
      else r.mag:SetText("+M"); r.mag:Disable() end
      r:Show(); y = y - 22
    end

    -- proc browser (scrollable list of the whole pool, filtered client-side)
    ep.searchHdr:SetText(string.format("%d of %d spells (type to filter) — add as %s:",
      #state.procResults, #state.allProcs, triggerName(state.addTrigger)))
    self:UpdateResults()
  end
end

-- ============================ receive =====================================
local requestTooltips   -- forward decl (assigned in the tooltip section below)

local function OnLine(body)
  dbg("<- " .. body)
  local cmd, rest = body:match("^(%u+):?(.*)$")
  if not cmd then cmd = body; rest = "" end

  if cmd == "ICCFG" then
    local a, pct, mr = rest:match("^(%d+):(%d+):(%d+)$")
    if a then state.cfg.addCost = tonumber(a); state.cfg.refundPct = tonumber(pct); state.cfg.maxRank = tonumber(mr) end
  elseif cmd == "ICHONOR" then
    state.honor = tonumber(rest) or 0
    if UI then UI:RefreshHonor() end
  elseif cmd == "ICARENA" then
    state.arena = tonumber(rest) or 0
    if UI then UI:RefreshHonor() end
  elseif cmd == "ICLIST" then
    state.catalogue = {}
    for n in string.gmatch(rest, "%d+") do table.insert(state.catalogue, tonumber(n)) end
  elseif cmd == "ICEQUIP" then
    if state.equipComplete then state.equip = {}; state.equipComplete = false end
    local slot, entry = rest:match("^(%d+):(%d+)$")
    if slot then table.insert(state.equip, { slot = tonumber(slot), entry = tonumber(entry) }) end
  elseif cmd == "ICEQUIPEND" then
    state.equipComplete = true
    if UI then UI:Refresh() end
  elseif cmd == "ICBENCH" then
    if rest == "0" then
      state.bench = nil; if UI then UI:Refresh() end
    else
      local guid, entry = rest:match("^(%d+):(%d+)$")
      state.bench = { guid = tonumber(guid), entry = tonumber(entry), stats = {}, procs = {} }
    end
  elseif cmd == "ICBSTAT" then   -- <type>:<rank>:<value>:<nextArenaCost>
    local t, rk, v, nc = rest:match("^(%d+):(%d+):(%-?%d+):(%d+)$")
    if t and state.bench then table.insert(state.bench.stats, { type=tonumber(t), rank=tonumber(rk), value=v, nextCost=tonumber(nc) }) end
  elseif cmd == "ICPROC" then    -- <spell>:<trig>:<cRank>:<mRank>:<nextC>:<nextM>
    local sid, tr, cr, mr, nc, nm = rest:match("^(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)$")
    if sid and state.bench then
      table.insert(state.bench.procs, { spellId=tonumber(sid), trigger=tonumber(tr), chanceRank=tonumber(cr), magRank=tonumber(mr), nextC=tonumber(nc), nextM=tonumber(nm) })
    end
  elseif cmd == "ICBENCHEND" then
    if UI then UI:Refresh() end
  elseif cmd == "ICADDED" then
    local t, cost = rest:match("^(%d+):(%d+)$")
    msg(string.format("Added %s for %s honor (rank 1). Upgrade it with arena.", statName(tonumber(t)), cost or "?"))
  elseif cmd == "ICSUPGRADED" then
    local t, cost = rest:match("^(%d+):(%d+)$")
    msg(string.format("Upgraded %s for %s arena.", statName(tonumber(t)), cost or "?"))
  elseif cmd == "ICREMOVED" then
    local t, hr, ar = rest:match("^(%d+):(%d+):(%d+)$")
    msg(string.format("Removed %s (refunded %s honor, %s arena).", statName(tonumber(t)), hr or "0", ar or "0"))
  elseif cmd == "ICPALL" then          -- a chunk of the full pool
    for n in string.gmatch(rest, "%d+") do table.insert(state.allAccum, tonumber(n)) end
  elseif cmd == "ICPALLEND" then       -- pool complete -> build sorted list, show all
    state.allProcs = {}
    for _, id in ipairs(state.allAccum) do table.insert(state.allProcs, { id = id, name = spellName(id) }) end
    state.allAccum = {}
    table.sort(state.allProcs, function(a, b) return a.name:lower() < b.name:lower() end)
    filterProcs("")
    dbg("proc pool: " .. #state.allProcs .. " spells")
  elseif cmd == "ICPRESULT" then       -- legacy server search (unused now)
    table.insert(state.procResults, tonumber(rest))
  elseif cmd == "ICPSEARCHEND" then
    if UI then UI:Refresh() end
  elseif cmd == "ICPADDED" then
    local sid, cost = rest:match("^(%d+):(%d+)$")
    msg(string.format("Added proc %s for %s honor. Upgrade chance/magnitude with arena.", spellName(tonumber(sid)), cost or "?"))
    state.procResults = {}
  elseif cmd == "ICPREMOVED" then
    local sid, hr, ar = rest:match("^(%d+):(%d+):(%d+)$")
    msg(string.format("Removed proc %s (refunded %s honor, %s arena).", spellName(tonumber(sid)), hr or "0", ar or "0"))
  elseif cmd == "ICPUPGRADED" then
    local sid, axis, cost = rest:match("^(%d+):(%d+):(%d+)$")
    msg(string.format("Upgraded %s %s for %s arena.", spellName(tonumber(sid)), (tonumber(axis)==0 and "chance" or "magnitude"), cost or "?"))
  elseif cmd == "ICTS" then
    local key, t, v = rest:match("^([%w_]+):(%d+):(%-?%d+)$")
    if key then
      state.tipStaging[key] = state.tipStaging[key] or { stats={}, procs={} }
      table.insert(state.tipStaging[key].stats, { type = tonumber(t), value = v })
    end
  elseif cmd == "ICTP" then
    local key, sid, tr = rest:match("^([%w_]+):(%d+):(%d+):%d+:%d+$")
    if key then
      state.tipStaging[key] = state.tipStaging[key] or { stats={}, procs={} }
      table.insert(state.tipStaging[key].procs, { spellId = tonumber(sid), trigger = tonumber(tr) })
    end
  elseif cmd == "ICTIPEND" then
    state.tipCache = state.tipStaging
    state.tipStaging = {}
    local n = 0; for _ in pairs(state.tipCache) do n = n + 1 end
    dbg("tooltip cache:", n, "customized item(s)")
  elseif cmd == "ICRETRIEVED" then
    if rest == "1" then
      msg("Item re-equipped — your customizations are now applied.")
    else
      msg("No free equip slot, so the item went to your bags (not lost). Re-equip it to apply the customizations.")
    end
    if requestTooltips then requestTooltips() end
  elseif cmd == "ICERR" then
    local op, reason = rest:match("^(%a+):(.+)$")
    msg("|cffff4040" .. tostring(op) .. " failed:|r " .. tostring(reason))
  else
    dbg("unhandled:", body)
  end
end

-- when a new search starts we must clear the previous results buffer
local origSend = send
send = function(body)
  if body:sub(1,10) == "ICPSEARCH:" then state.procResults = {} end
  origSend(body)
end

-- ============================ tooltips ====================================
-- Ask the server for custom data on all our items (fills tipStaging -> tipCache).
requestTooltips = function()
  state.tipStaging = {}
  send("ICITEMS")
end

-- BAG_UPDATE fires in bursts; debounce the refresh.
local refreshPending, refreshTimer = false, 0
local refreshFrame = CreateFrame("Frame")
refreshFrame:SetScript("OnUpdate", function(self, elapsed)
  if not refreshPending then return end
  refreshTimer = refreshTimer + elapsed
  if refreshTimer > 0.5 then
    refreshPending = false; refreshTimer = 0
    requestTooltips()
  end
end)
local function scheduleRefresh() refreshPending = true; refreshTimer = 0 end

-- Append custom lines to a tooltip for a given location key, if we have data.
local function appendTip(tooltip, key)
  local data = state.tipCache[key]
  if not data then return end
  tooltip:AddLine(" ")
  tooltip:AddLine("|cff00ccffCustomized|r")
  for _, s in ipairs(data.stats) do
    tooltip:AddLine(string.format("  |cff20ff20+%s|r %s", tostring(s.value), statName(s.type)))
  end
  for _, p in ipairs(data.procs) do
    tooltip:AddLine(string.format("  |cffc080f0%s|r |cff888888(%s)|r", spellName(p.spellId), triggerName(p.trigger)))
  end
  tooltip:Show()   -- re-fit the frame to the new lines
end

hooksecurefunc(GameTooltip, "SetBagItem", function(self, bag, slot)
  appendTip(self, "c" .. bag .. "_" .. slot)
end)
hooksecurefunc(GameTooltip, "SetInventoryItem", function(self, unit, invSlot)
  if unit == "player" then appendTip(self, "e" .. invSlot) end
end)

-- ============================ events / slash ==============================
local listener = CreateFrame("Frame")
listener:RegisterEvent("CHAT_MSG_ADDON")
listener:RegisterEvent("PLAYER_LOGIN")
listener:RegisterEvent("PLAYER_ENTERING_WORLD")
listener:RegisterEvent("BAG_UPDATE")
listener:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
listener:SetScript("OnEvent", function(self, event, a1, a2)
  if event == "CHAT_MSG_ADDON" then
    if a1 == PIPE_PREFIX and a2 and a2:sub(1,2) == "IC" then OnLine(a2) end
    return
  end
  if event == "PLAYER_LOGIN" then dbg("loaded. /ic to open."); return end
  if event == "PLAYER_ENTERING_WORLD" then requestTooltips(); return end
  -- keep the paper-doll live if the window is open
  if event == "PLAYER_EQUIPMENT_CHANGED" and UI and UI:IsShown() and UI.RefreshDoll then UI:RefreshDoll() end
  -- BAG_UPDATE / PLAYER_EQUIPMENT_CHANGED: items moved -> refresh tooltip cache (debounced)
  scheduleRefresh()
end)

SLASH_ICUST1 = "/ic"
SlashCmdList["ICUST"] = function()
  BuildUI(); attachMethods()
  if UI:IsShown() then UI:Hide() else
    state.equip = {}; state.bench = nil; state.procResults = {}
    UI:Show(); UI:Refresh(); dbg("opening -> ICOPEN"); send("ICOPEN")
  end
end

SLASH_ICDEBUG1 = "/icdebug"
SlashCmdList["ICDEBUG"] = function() DEBUG = not DEBUG; msg("debug " .. (DEBUG and "ON" or "OFF")) end

dbg("file parsed.")
