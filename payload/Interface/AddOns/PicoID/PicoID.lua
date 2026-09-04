------------------------------------------------------------------
-- PicoID v1.14 — imprinted-proc inventory viewer (WotLK 3.3.5a)
-- Shows every equipped item with the procs imprinted on it:
--   Item - Imprinted proc - Proc ID - Item of origin
-- Duplicated procs are shown in red (they never fire twice).
--
-- Originally by Mhortai (v1.13), shipped on Uncapped with realm-side fixes.
--
-- ⚠ It does NOT only listen. It sends two verbs -- ICINV (COST_HEAVY, 6 tokens)
--   and USPELLDMG (COST_MEDIUM, 2) -- into a per-player token bucket of 60 burst
--   / 6 per second that is SHARED with every other addon on the account
--   (src/server/game/Handlers/AddonThrottle.cpp). A verb the bucket cannot afford
--   is dropped: not answered, not queued, not retried.
--
-- v1.14 changes, all of them about that:
--   * removed the prefetch that queued every proc on every soulbound item and
--     re-sent the unanswered ones twice a second. At the measured worst case on
--     this realm (39 procs) that was 78 messages/second, 26x the budget, and it
--     fired at login and on every gear change with the window shut.
--   * damage is now fetched once, on hover, and never retried in a loop
--   * ICINV debounced to one per 10s
--   * the 810 KB of proc/drop tables moved to the PicoIDData LoadOnDemand addon
--   * stopped overwriting UncappedSoulForge's tooltip on its on-use buttons
--   * PicoIDExport no longer grows by 3 lines per Print, forever
--   * clicking a row no longer force-opens the chat box and steals WASD
------------------------------------------------------------------

local ADDON_NAME = "PicoID"

local DEFAULTS = {
    minimap    = true,
    minimapPos = 200,     -- angle (degrees) around the minimap
    fontSize   = 13,
    opacity    = 0.8,
}

local db  -- SavedVariables (PicoIDDB), set on ADDON_LOADED

--[[ ★★ THE TABLES LIVE IN A SEPARATE LoadOnDemand ADDON, AND THAT IS NOT TIDINESS.
  PicoID_ProcDB.lua (575 KB, 9,591 entries) and PicoID_DropDB.lua (235 KB, 5,332)
  used to be listed in PicoID.toc, so 810 KB of Lua source was parsed at EVERY
  login by EVERY player, including everyone who never opens the window. This realm
  has split three tables out for exactly this reason already -- UncappedTransmogData
  (797 KB), UncappedQuestData (628 KB) and UncappedLootFeedSources (490 KB).

  ⚠ PicoIDData MUST stay force-enabled in the launcher manifest. LoadAddOn() on a
    DISABLED addon returns nil, "DISABLED" -- it cannot be loaded at all -- so an
    unticked data addon means the proc and origin columns are permanently empty
    with no error. Every reader below nil-guards, so it degrades to "-" rather
    than throwing, which is precisely why it would go unreported.               ]]
local dataLoaded = false
local function EnsureData()
    if dataLoaded then return true end
    if PicoID_ProcDB then dataLoaded = true; return true end       -- already in memory
    if not IsAddOnLoaded("PicoIDData") then
        local ok, reason = LoadAddOn("PicoIDData")
        if not ok then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff2020PicoID|r: could not load PicoIDData ("
                .. tostring(reason) .. "). Proc names and origins will be blank -- "
                .. "re-tick PicoID Data in the AddOns list.")
            dataLoaded = true   -- warn once, not on every refresh
            return false
        end
    end
    dataLoaded = true
    return true
end

-- Prefer SchoolPop's database when both addons are installed (same data)
local function ProcDB()    EnsureData() return SchoolPop_ProcDB or PicoID_ProcDB end
local function AbilityDB() EnsureData() return SchoolPop_AbilityDB or PicoID_AbilityDB end
local function ManualDB()  EnsureData() return SchoolPop_ProcDB_Manual or PicoID_ProcDB_Manual end

--=================== UNCAPPED WIRE LISTENER ======================
-- The server sends imprinted (soulbound) procs to the Uncapped addon
-- over CHAT_MSG_ADDON, prefix "UNC":
--   ICITEM:E:<slot> | ICITEM:B:<bag>:<slot>   start of one item
--   ICIPROC:<spellId>:<trigger>:<chance>:<mag> a proc on that item
--   ICINVEND                                   end of the inventory
-- PicoID listens to the same stream and never sends anything.
local UNC_PREFIX = "UNC"
local boundStaging, boundCur = {}, nil
local boundByKey = {}
local boundProcInfo = {}
local boundReceived = false
local RefreshList  -- forward declaration

local function OnUncappedLine(body)
    local cmd, rest = string.match(body, "^(%u+):?(.*)$")
    if not cmd then return end
    if cmd == "ICITEM" then
        boundCur = rest
        boundStaging[rest] = boundStaging[rest] or {}
    elseif cmd == "ICIPROC" then
        local sid, tr, ch, mg = string.match(rest, "^(%d+):(%d+):(%d+):(%d+)")
        if not sid then sid = string.match(rest, "^(%d+)") end
        if sid and boundCur then
            table.insert(boundStaging[boundCur], { spellId = tonumber(sid),
                chance = tonumber(ch), mag = tonumber(mg) or 100, bases = {} })
        end
    elseif cmd == "ICIPROCBP" then
        local cur = boundCur and boundStaging[boundCur]
        local last = cur and cur[#cur]
        if last then
            local v = {}
            for n in string.gmatch(rest, "(%d+)") do v[#v + 1] = tonumber(n) end
            last.bases = v
        end
    elseif cmd == "ICIPROCFACT" then
        local sc, rs, sp, ap = string.match(rest, "^(%d+):(%d+):(%d+):(%d+)$")
        local cur = boundCur and boundStaging[boundCur]
        local last = cur and cur[#cur]
        if last and sc then
            last.stackCap = tonumber(sc) or 0
            last.rankScales = (tonumber(rs) or 0) == 1
            last.spPct = tonumber(sp) or 0
            last.apPct = tonumber(ap) or 0
        end
    elseif cmd == "ICINVEND" then
        boundByKey = boundStaging
        boundProcInfo = {}
        for _, procs in pairs(boundByKey) do
            for _, p in ipairs(procs) do boundProcInfo[p.spellId] = p end
        end
        boundStaging, boundCur = {}, nil
        boundReceived = true
        if RefreshList then RefreshList() end
        -- ⚠ NO PREFETCH HERE. This branch runs whenever the server pushes the
        -- soulbound stream, which UncappedSoulForge does 2s after PLAYER_LOGIN and
        -- 0.3s after EVERY equipment change -- with the PicoID window closed and
        -- possibly never opened. Firing a per-proc burst from here landed it on
        -- the same bucket as the 28-token zone-in. Damage is fetched on hover.
    end
end

--====================== ORIGIN RESOLUTION ========================
local function Commas(n)
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

local function PickSource(value)
    if type(value) == "string" then return value end
    if type(value) ~= "table" then return nil end
    if #value == 1 then return value[1] end
    local shown = {}
    for i = 1, math.min(3, #value) do shown[i] = value[i] end
    local s = table.concat(shown, " / ")
    if #value > 3 then s = s .. " / ..." end
    return s
end

local function OriginOf(spellId)
    local m = ManualDB()
    if m and m[spellId] then return PickSource(m[spellId]) end
    local a = AbilityDB()
    if a and a[spellId] then return a[spellId] .. " (ability)" end
    local p = ProcDB()
    if p and p[spellId] then return PickSource(p[spellId]) end
    return "-"
end

--========================= THE WINDOW ============================
local frame = CreateFrame("Frame", "PicoIDFrame", UIParent)
frame:SetWidth(560)
frame:SetHeight(300)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
frame:SetMovable(true)
frame:SetResizable(true)
frame:SetMinResize(360, 140)
frame:SetMaxResize(1000, 700)
do local w, h = UIParent:GetWidth(), UIParent:GetHeight()
   if w and h then frame:SetMaxResize(math.min(1000, w - 20), math.min(700, h - 20)) end end
frame:SetClampedToScreen(true)
frame:SetFrameStrata("MEDIUM")
frame:EnableMouse(true)
frame:SetBackdrop({
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
frame:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
frame:Hide()
tinsert(UISpecialFrames, "PicoIDFrame")  -- Esc closes it

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOPLEFT", 10, -6)
title:SetText("PicoID - imprinted procs on equipped items")

-- Real columns: header row + pooled row-frames in a scroll frame.
local COLS = {
    { title = "Item",           w = 0.26 },
    { title = "Imprinted proc", w = 0.20 },
    { title = "Proc ID",        w = 0.09 },
    { title = "Item of origin", w = 0.25 },
    { title = "Dropped by",     w = 0.20 },
}

local function DropText(spellId)
    EnsureData()
    local d = PicoID_DropDB and PicoID_DropDB[spellId]
    if not d then return "-" end
    return table.concat(d, ", ")
end

--[[ ★★★ ONE ASK PER PROC, ON HOVER, NEVER RETRIED IN A LOOP.
  What was here before: a prefetch that queued EVERY proc on EVERY soulbound item
  (bags included, not just the 19 worn slots) and an OnUpdate that re-sent every
  unanswered one twice a second.

  USPELLDMG costs 2 tokens against a 60-burst / 6-per-second bucket
  (src/server/game/Handlers/AddonThrottle.cpp), so the sustainable rate is three
  per second. With N procs the old code demanded 4N tokens/second: break-even was
  N <= 1.5, and 86% of imprint owners on this realm are at N >= 2. The measured
  worst case is N = 39 -- 78 messages/second, 26x the budget, and the FIRST tick
  alone overdraws the whole bucket. Everything else the account sends is then
  dropped too, which is how one addon produces four unrelated-looking bug reports.

  Worse, the "stops after ~10s" bound could never fire: RequestSpellDamage reset
  dmgTries unconditionally, and the item primer calls RefreshList (and therefore
  the prefetch) on roughly half of all frames for three seconds after every open.

  The shipped Uncapped64bitUI does this correctly and this now matches it: ask
  once, only for the proc actually being hovered, and fail silently. A dropped
  answer is retried by the player hovering again -- which is a hardware event, is
  self-limiting, and cannot storm.                                             ]]
local spellDmg  = {}      -- spellId -> {min, max} once the server answers
local dmgAsked  = {}      -- spellId -> true while one ask is outstanding
local DMG_TIMEOUT = 6

local function RequestSpellDamage(spellId)
    if not spellId or spellDmg[spellId] or dmgAsked[spellId] then return end
    dmgAsked[spellId] = true
    SendAddonMessage("REAGENTBANK", "USPELLDMG:" .. spellId, "WHISPER", UnitName("player"))
    -- A plain timeout, because the ask can be dropped and then nothing ever
    -- arrives. Clearing the flag lets a later deliberate hover try once more;
    -- it does NOT re-send on its own.
    local f = CreateFrame("Frame")
    local left = DMG_TIMEOUT
    f:SetScript("OnUpdate", function(self, dt)
        left = left - dt
        if left > 0 then return end
        self:SetScript("OnUpdate", nil)
        if not spellDmg[spellId] then dmgAsked[spellId] = nil end
    end)
end
local function AbbrevNum(n)
    n = tonumber(n) or 0
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
    if frac > 0 then return string.format("%d.%02d%s", whole, frac, suffix) end
    return string.format("%d%s", whole, suffix)
end

local function ShowProcTooltip(anchor, spellId)
    GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
    GameTooltip:AddLine(GetSpellInfo(spellId) or "Proc", 1, 0.82, 0)
    local p = boundProcInfo[spellId]
    local dmg = spellDmg[spellId]
    if dmg then
        if dmg[2] and dmg[2] > dmg[1] then
            GameTooltip:AddLine("Approx. " .. AbbrevNum(dmg[1]) .. " - " .. AbbrevNum(dmg[2])
                .. " with your stats", 1, 0.82, 0)
        else
            GameTooltip:AddLine("Approx. " .. AbbrevNum(dmg[1]) .. " with your stats", 1, 0.82, 0)
        end
    else
        RequestSpellDamage(spellId)
        GameTooltip:AddLine("Calculating with your stats...", 0.6, 0.6, 0.6)
    end
    if p then
        if p.chance and p.chance > 0 then GameTooltip:AddLine(string.format("Proc chance: %d%%", p.chance), 0.7, 0.7, 0.7) end
        if p.stackCap and p.stackCap > 1 then GameTooltip:AddLine("Stacks up to " .. p.stackCap, 0.7, 0.7, 0.7) end
    end
    GameTooltip:Show()
end
local ROW_H = 17

local scroll = CreateFrame("ScrollFrame", "PicoIDScroll", frame, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 8, -44)
scroll:SetPoint("BOTTOMRIGHT", -30, 40)

local content = CreateFrame("Frame", nil, scroll)
content:SetWidth(1)
content:SetHeight(1)
scroll:SetScrollChild(content)

local header = {}
for c = 1, #COLS do
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetJustifyH("LEFT")
    fs:SetHeight(14)
    fs:SetText(COLS[c].title)
    header[c] = fs
end
local headerLine = frame:CreateTexture(nil, "ARTWORK")
headerLine:SetTexture(1, 0.82, 0)
headerLine:SetHeight(1)
headerLine:SetAlpha(0.5)

local rowPool = {}
local usedRows = 0
local function AcquireRow(index)
    local row = rowPool[index]
    if not row then
        row = CreateFrame("Button", nil, content)
        row.picoRow = true      -- our tag; see the USPELLDMGR tooltip repaint
        row:SetHeight(ROW_H)
        row:EnableMouse(true)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture(1, 1, 1, 0.06)
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetTexture(0, 0, 0, 0)
        row:SetScript("OnEnter", function(self)
            if self.spellId then ShowProcTooltip(self, self.spellId) end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:RegisterForClicks("LeftButtonUp")
        row:SetScript("OnClick", function(self)
            if not self.spellId then return end
            local pname = GetSpellInfo(self.spellId) or "Proc"
            local text = "[" .. pname .. "] (" .. self.spellId .. ")"
            local edit = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
                or ChatEdit_ChooseBoxForSend and ChatEdit_ChooseBoxForSend()
            -- ⚠ Only insert into a chat box the player already has open. Forcing
            -- one open steals keyboard focus, so the next WASD press walks into
            -- the edit box instead of the character.
            if edit and edit:IsShown() then
                edit:Insert(text)
                edit:SetFocus()
            end
        end)
        row.cells = {}
        for c = 1, #COLS do
            local fs = row:CreateFontString(nil, "OVERLAY")
            fs:SetFont("Fonts\\ARIALN.TTF", db and db.fontSize or 13, "")
            fs:SetJustifyH("LEFT")
            fs:SetHeight(ROW_H)
            row.cells[c] = fs
        end
        rowPool[index] = row
    end
    return row
end

-- totals line (left) and duplicate warning (right of it)
local totals = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
totals:SetPoint("BOTTOMLEFT", 10, 6)
totals:SetJustifyH("LEFT")

local warning = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
warning:SetPoint("LEFT", totals, "RIGHT", 12, 0)
warning:SetPoint("RIGHT", -10, 0)
warning:SetJustifyH("LEFT")
warning:SetTextColor(1, 0.3, 0.3)
warning:Hide()

local function Layout()
    local width = scroll:GetWidth()
    if not width or width < 50 then return end
    content:SetWidth(width)
    local x = 0
    for c, col in ipairs(COLS) do
        local w = math.floor(width * col.w) - 6
        header[c]:ClearAllPoints()
        header[c]:SetPoint("TOPLEFT", frame, "TOPLEFT", 8 + x, -28)
        header[c]:SetWidth(w)
        for i = 1, usedRows do
            local fs = rowPool[i].cells[c]
            fs:ClearAllPoints()
            fs:SetPoint("LEFT", rowPool[i], "LEFT", x, 0)
            fs:SetWidth(w)
        end
        x = x + math.floor(width * col.w)
    end
    headerLine:ClearAllPoints()
    headerLine:SetPoint("TOPLEFT", 8, -42)
    headerLine:SetPoint("TOPRIGHT", -30, -42)
end
frame:SetScript("OnSizeChanged", function() Layout() end)

local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", 3, 3)
close:SetWidth(24)
close:SetHeight(24)

local grip = CreateFrame("Button", nil, frame)
grip:SetWidth(16)
grip:SetHeight(16)
grip:SetPoint("BOTTOMRIGHT", -2, 2)
grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
grip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing() end)

local rows = {}  -- plain-text rows for Print

local function ApplyLook()
    for _, row in ipairs(rowPool) do
        for _, fs in ipairs(row.cells) do
            fs:SetFont("Fonts\\ARIALN.TTF", db.fontSize, "")
        end
    end
    frame:SetBackdropColor(0, 0, 0, db.opacity)
end


-- On 3.3.5a GetItemInfo returns nil until the item is cached; prime the cache
-- for every equipped item and re-render as names resolve, so the list fills in
-- quickly on the first open instead of showing "slot N".
local PicoID_itemPrimer = CreateFrame("Frame")
PicoID_itemPrimer:Hide()
local primerElapsed, primerRepaint = 0, 0
PicoID_itemPrimer:SetScript("OnUpdate", function(self, dt)
    primerElapsed = primerElapsed + dt
    local allKnown = true
    for slot = 1, 19 do
        local link = GetInventoryItemLink("player", slot)
        if link and not GetItemInfo(link) then allKnown = false end
    end
    if allKnown or primerElapsed > 3 then
        self:Hide(); primerElapsed = 0; primerRepaint = 0
        RefreshList()   -- final re-render with everything cached
    else
        -- ⚠ An accumulator, not a frame-parity test. `floor(elapsed*5) % 2 == 0`
        -- is true on roughly half of ALL frames, so this relaid out every row on
        -- ~90 frames of the 3-second window. This realm already has a measured
        -- FPS problem caused by action-bar repaint storms; four repaints a second
        -- is plenty for items trickling out of the cache.
        primerRepaint = primerRepaint + dt
        if primerRepaint >= 0.25 then
            primerRepaint = 0
            RefreshList()
        end
    end
end)

RefreshList = function()
    if not frame:IsShown() then return end
    rows = {}
    local n = 0
    local function AddRow(cols, r, g, b, idWhite)
        n = n + 1
        local row = AcquireRow(n)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(n - 1) * ROW_H)
        row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
        for c = 1, #COLS do
            row.cells[c]:SetText(cols[c] or "")
            if c == 3 and idWhite then
                row.cells[c]:SetTextColor(1, 1, 1)
            else
                row.cells[c]:SetTextColor(r, g, b)
            end
        end
        row.spellId = cols.spellId
        if cols.dup then row.bg:SetTexture(1, 0, 0, 0.18) else row.bg:SetTexture(0, 0, 0, 0) end
        row:Show()
        rows[#rows + 1] = table.concat({ cols[1] or "", cols[2] or "",
            cols[3] or "", cols[4] or "", cols[5] or "" }, "  -  ")
    end

    local itemCount, procCount, dupProcs = 0, 0, 0
    if not boundReceived then
        -- ⚠ This used to say "(is Uncapped loaded?)" unconditionally, which names
        -- the wrong cause in the common case. The usual reason nothing arrived is
        -- that the request was DROPPED by the server's addon throttle -- the exact
        -- misdiagnosis that produced four separate bug reports about four features
        -- that were all one thing. Ask UncappedThrottle, which knows.
        local UT = _G.UncappedThrottle
        if UT and UT.IsThrottled and UT.IsThrottled() then
            AddRow({ (UT.StatusText and UT.StatusText())
                     or "The server is busy and dropped the request. Reopen this window shortly." },
                1, 0.82, 0)
        else
            AddRow({ "No imprint data received from the server yet (is Uncapped loaded?)" },
                1, 0.5, 0.5)
        end
        totals:SetText("")
    else
        local count = {}
        for slot = 1, 19 do
            for _, p in ipairs(boundByKey["E:" .. slot] or {}) do
                count[p.spellId] = (count[p.spellId] or 0) + 1
            end
        end
        for sid, c in pairs(count) do
            procCount = procCount + c
            if c > 1 then dupProcs = dupProcs + 1 end
        end
        local duplicates = false
        for slot = 1, 19 do
            local link = GetInventoryItemLink("player", slot)
            if link then
                itemCount = itemCount + 1
                local name = GetItemInfo(link) or ("slot " .. slot)
                local procs = boundByKey["E:" .. slot]
                if procs and #procs > 0 then
                    for _, p in ipairs(procs) do
                        local sid = p.spellId
                        local pname = GetSpellInfo(sid) or "?"
                        local dup = (count[sid] or 0) > 1
                        if dup then duplicates = true end
                        local cols = { name, pname, tostring(sid), OriginOf(sid),
                            DropText(sid), spellId = sid, dup = dup }
                        if dup then AddRow(cols, 1, 0.25, 0.25, false)
                        else AddRow(cols, 0.75, 0.55, 1, true) end
                    end
                else
                    AddRow({ name, "-", "-", "-", "-" }, 0.6, 0.6, 0.6, false)
                end
            end
        end
        totals:SetText(string.format("|cffffd100%d|r items   |cffffd100%d|r procs%s",
            itemCount, procCount,
            dupProcs > 0 and ("   |cffff4040" .. dupProcs .. " duplicated|r") or ""))
        if duplicates then
            warning:SetText("Duplicate procs (red) fire only once, no matter how many items carry them.")
            warning:Show()
        else
            warning:Hide()
        end
    end

    for i = n + 1, usedRows do rowPool[i]:Hide() end
    usedRows = n
    content:SetHeight(math.max(1, n * ROW_H))
    Layout()
end

--========================== EXPORT ===============================
-- Addons cannot write files; Print opens a window with the list as
-- plain text pre-selected (Ctrl+C), and stores it in the PicoIDExport
-- saved variable, written to WTF\...\SavedVariables on logout/reload.
local exportFrame = CreateFrame("Frame", "PicoIDExportFrame", UIParent)
exportFrame:SetWidth(540)
exportFrame:SetHeight(380)
exportFrame:SetPoint("CENTER")
exportFrame:SetFrameStrata("DIALOG")
exportFrame:SetMovable(true)
exportFrame:EnableMouse(true)
exportFrame:SetClampedToScreen(true)
exportFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
exportFrame:Hide()
tinsert(UISpecialFrames, "PicoIDExportFrame")

local exportTitle = CreateFrame("Frame", nil, exportFrame)
exportTitle:SetPoint("TOPLEFT", 12, -12)
exportTitle:SetPoint("TOPRIGHT", -12, -12)
exportTitle:SetHeight(20)
exportTitle:EnableMouse(true)
exportTitle:RegisterForDrag("LeftButton")
exportTitle:SetScript("OnDragStart", function() exportFrame:StartMoving() end)
exportTitle:SetScript("OnDragStop", function() exportFrame:StopMovingOrSizing() end)
local exportTitleText = exportTitle:CreateFontString(nil, "OVERLAY", "GameFontNormal")
exportTitleText:SetPoint("CENTER")
exportTitleText:SetText("PicoID Export")

local exportHint = exportFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
exportHint:SetPoint("BOTTOM", 0, 20)
exportHint:SetText("Text is selected: press Ctrl+C, then paste into Word or Notepad.")

local exportScroll = CreateFrame("ScrollFrame", "PicoIDExportScroll", exportFrame,
    "UIPanelScrollFrameTemplate")
exportScroll:SetPoint("TOPLEFT", 16, -36)
exportScroll:SetPoint("BOTTOMRIGHT", -36, 40)

local exportEdit = CreateFrame("EditBox", nil, exportScroll)
exportEdit:SetMultiLine(true)
exportEdit:SetAutoFocus(false)
exportEdit:SetMaxLetters(0)
exportEdit:SetFontObject(ChatFontNormal)
exportEdit:SetWidth(480)
exportEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
exportScroll:SetScrollChild(exportEdit)

local exportClose = CreateFrame("Button", nil, exportFrame, "UIPanelCloseButton")
exportClose:SetPoint("TOPRIGHT", -6, -6)

local function DoPrint()
    local out = { "Item  -  Imprinted proc  -  Proc ID  -  Item of origin" }
    for _, r in ipairs(rows) do out[#out + 1] = r end
    if warning:IsShown() then
        out[#out + 1] = ""
        out[#out + 1] = warning:GetText()
    end
    -- ⚠ `rows = out` was here, and it fed the output back into the source list.
    -- Every Print added another header, another blank and another warning line to
    -- the SAME table -- +3 rows per click, saved to SavedVariables each time, so
    -- PicoIDExport grew without bound for the life of the character. `out` is a
    -- local render of `rows`; it must never be written back over it.
    local text = table.concat(out, "\n")
    if text == "" then text = "(nothing to export)" end
    exportEdit:SetText(text)
    exportFrame:Show()
    exportEdit:SetFocus()
    exportEdit:HighlightText()
    PicoIDExport = PicoIDExport or {}
    PicoIDExport.exportedAt = date("%Y-%m-%d %H:%M:%S")
    PicoIDExport.lines = { unpack(out) }
end

local printBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
printBtn:SetPoint("RIGHT", close, "LEFT", 2, 0)
printBtn:SetWidth(50)
printBtn:SetHeight(16)
printBtn:SetText("Print")
printBtn:SetScript("OnClick", DoPrint)

local refreshBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
refreshBtn:SetPoint("RIGHT", printBtn, "LEFT", -2, 0)
refreshBtn:SetWidth(56)
refreshBtn:SetHeight(16)
refreshBtn:SetText("Refresh")
refreshBtn:SetScript("OnClick", function() RefreshList() end)

-- Reset button: restore the default size and centre position
local resetBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
resetBtn:SetPoint("RIGHT", refreshBtn, "LEFT", -2, 0)
resetBtn:SetWidth(50)
resetBtn:SetHeight(16)
resetBtn:SetText("Reset")
resetBtn:SetScript("OnClick", function()
    frame:ClearAllPoints()
    frame:SetWidth(560)
    frame:SetHeight(300)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    Layout()
end)

-- Ask the server for a fresh soulbound-inventory stream (same request the
-- Uncapped addon uses: ICINV -> ICITEM/ICIPROC/.../ICINVEND). This makes the
-- data arrive right away instead of waiting for Uncapped's next refresh.
-- ⚠ DEBOUNCED. ICINV is the most expensive verb on this pipe -- COST_HEAVY, 6 of
-- a 60-token bucket -- and it was sent on every single window open. Ten impatient
-- clicks on the minimap button was the whole burst, after which this addon and
-- every other one on the account went quiet. The stream is also pushed by
-- UncappedSoulForge on login and on every equipment change, so a re-ask inside
-- the refresh window buys nothing.
local ICINV_MIN_INTERVAL = 10
local lastImprintAsk = 0
local function RequestImprints(force)
    local now = GetTime() or 0
    if not force and boundReceived and (now - lastImprintAsk) < ICINV_MIN_INTERVAL then return end
    lastImprintAsk = now
    SendAddonMessage("REAGENTBANK", "ICINV", "WHISPER", UnitName("player"))
end

function PicoID_Toggle()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        RefreshList()
        PicoID_itemPrimer:Show()
        RequestImprints()
    end
end

--======================= MINIMAP BUTTON ==========================
local mm = CreateFrame("Button", "PicoIDMinimapButton", Minimap)
mm:SetWidth(32)
mm:SetHeight(32)
mm:SetFrameStrata("MEDIUM")
mm:SetFrameLevel(8)
mm:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
mm:RegisterForClicks("LeftButtonUp")
mm:RegisterForDrag("LeftButton")

local mmOverlay = mm:CreateTexture(nil, "OVERLAY")
mmOverlay:SetWidth(53)
mmOverlay:SetHeight(53)
mmOverlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
mmOverlay:SetPoint("TOPLEFT")

local mmIcon = mm:CreateTexture(nil, "BACKGROUND")
mmIcon:SetWidth(20)
mmIcon:SetHeight(20)
mmIcon:SetTexture("Interface\\Icons\\INV_Misc_Spyglass_02") -- change icon here
mmIcon:SetPoint("TOPLEFT", 7, -5)

local function MinimapSetPosition()
    local angle = math.rad(db.minimapPos or 200)
    mm:ClearAllPoints()
    mm:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * 80, math.sin(angle) * 80)
end

local function UpdateMinimapButton()
    if db.minimap then
        MinimapSetPosition()
        mm:Show()
    else
        mm:Hide()
    end
end

mm:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        px, py = px / scale, py / scale
        db.minimapPos = math.deg(math.atan2(py - my, px - mx))
        MinimapSetPosition()
    end)
end)
mm:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
end)
mm:SetScript("OnClick", PicoID_Toggle)
mm:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("PicoID")
    GameTooltip:AddLine("Click: show imprinted procs", 1, 1, 1)
    GameTooltip:AddLine("Drag: move button", 1, 1, 1)
    GameTooltip:Show()
end)
mm:SetScript("OnLeave", function() GameTooltip:Hide() end)

--======================= OPTIONS PANEL ===========================
local panel = CreateFrame("Frame", "PicoIDOptionsPanel", UIParent)
panel.name = "PicoID"

local function BuildPanel()
    local t = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    t:SetPoint("TOPLEFT", 16, -12)
    t:SetText("PicoID")
    local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -2)
    sub:SetText("Lists the procs imprinted on your equipped items, with their IDs and origins.")

    local mmCheck = CreateFrame("CheckButton", "PicoIDMinimapCheck", panel, "OptionsCheckButtonTemplate")
    mmCheck:SetPoint("TOPLEFT", 8, -50)
    _G["PicoIDMinimapCheckText"]:SetText("Show minimap button")
    mmCheck:SetScript("OnClick", function(self)
        db.minimap = self:GetChecked() and true or false
        UpdateMinimapButton()
    end)
    panel.mmCheck = mmCheck

    local function MakeSlider(name, label, key, minV, maxV, step, x, y, fmt)
        local s = CreateFrame("Slider", "PicoID" .. name, panel, "OptionsSliderTemplate")
        s:SetPoint("TOPLEFT", x, y)
        s:SetWidth(160)
        s:SetMinMaxValues(minV, maxV)
        s:SetValueStep(step)
        _G[s:GetName() .. "Low"]:SetText(minV)
        _G[s:GetName() .. "High"]:SetText(maxV)
        local text = _G[s:GetName() .. "Text"]
        s:SetScript("OnValueChanged", function(self, value)
            value = math.floor(value / step + 0.5) * step
            db[key] = value
            text:SetText(label .. ": " .. string.format(fmt, value))
            ApplyLook()
        end)
        return s
    end
    panel.fontSlider = MakeSlider("Font", "Font size", "fontSize", 8, 24, 1, 16, -110, "%d")
    panel.alphaSlider = MakeSlider("Alpha", "Opacity", "opacity", 0, 1, 0.05, 210, -110, "%.2f")

    local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    open:SetPoint("TOPLEFT", 16, -160)
    open:SetWidth(120)
    open:SetHeight(22)
    open:SetText("Open PicoID")
    open:SetScript("OnClick", PicoID_Toggle)
end

panel.refresh = function()
    panel.mmCheck:SetChecked(db.minimap)
    panel.fontSlider:SetValue(db.fontSize)
    panel.alphaSlider:SetValue(db.opacity)
end
panel.okay, panel.cancel, panel.default = function() end, function() end, function() end

--========================= EVENT FRAME ===========================
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("UNIT_INVENTORY_CHANGED")

f:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_ADDON" then
        local prefix, body = ...
        if prefix == UNC_PREFIX and body then
            if string.sub(body, 1, 2) == "IC" then
                OnUncappedLine(body)
            else
                local sid, mn, mx = string.match(body, "^USPELLDMGR:(%d+):(%d+):(%d+)$")
                if sid then
                    sid = tonumber(sid)
                    spellDmg[sid] = { tonumber(mn), tonumber(mx) }
                    dmgAsked[sid] = nil
                    --[[ ⚠ `.spellId` IS NOT OURS ALONE. This used to repaint the
                      tooltip whenever ANY frame owning it happened to have a
                      matching .spellId field -- and UncappedSoulForge sets exactly
                      that on its equipped-row on-use buttons
                      (UncappedSoulForge.lua:1467) and anchors GameTooltip to them
                      on hover. So reading a clicky's cooldown line got it wiped and
                      replaced by ours. Require our own tag as well.            ]]
                    local owner = GameTooltip:GetOwner()
                    if GameTooltip:IsShown() and owner and owner.picoRow
                       and owner.spellId == sid then
                        ShowProcTooltip(owner, sid)
                    end
                end
            end
        end

    elseif event == "UNIT_INVENTORY_CHANGED" then
        if ... == "player" then
            spellDmg = {}; dmgAsked = {}
            if frame:IsShown() then RefreshList() end
        end

    elseif event == "ADDON_LOADED" and ... == ADDON_NAME then
        PicoIDDB = PicoIDDB or {}
        db = PicoIDDB
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then db[k] = v end
        end
        ApplyLook()
        UpdateMinimapButton()
        BuildPanel()
        InterfaceOptions_AddCategory(panel)
        self:UnregisterEvent("ADDON_LOADED")
    end
end)

--======================= SLASH COMMANDS ==========================
SLASH_PICOID1 = "/picoid"
SLASH_PICOID2 = "/pid"
SlashCmdList["PICOID"] = function(msg)
    if msg == "debug" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff80ffffPicoID debug|r")
        DEFAULT_CHAT_FRAME:AddMessage("  db set: " .. tostring(db ~= nil)
            .. "  boundReceived: " .. tostring(boundReceived))
        local n = 0
        for _ in pairs(boundByKey) do n = n + 1 end
        DEFAULT_CHAT_FRAME:AddMessage("  boundByKey entries: " .. n)
        local eq = 0
        for slot = 1, 19 do
            local p = boundByKey["E:" .. slot]
            if p then eq = eq + #p end
        end
        DEFAULT_CHAT_FRAME:AddMessage("  equipped procs counted: " .. eq)
        DEFAULT_CHAT_FRAME:AddMessage("  ProcDB loaded: " .. tostring(PicoID_ProcDB ~= nil)
            .. "  DropDB: " .. tostring(PicoID_DropDB ~= nil))
    else
        PicoID_Toggle()
    end
end
