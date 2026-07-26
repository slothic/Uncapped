-- =====================================================================
-- Uncapped Vault -- the infinite bag.
--
-- A searchable, scrollable, infinitely-stacking item window that reads
-- like a real bag (a grid of item-slot buttons), not a dialog. The server
-- is the authoritative store; this addon is only a window onto it and asks
-- for a page of results at a time (search/sort/paging all run server-side).
--
-- One payload, two behaviours (like devUncapped64): on the DEV realm it runs
-- LIVE against the server vault (VLT* comms over the shared addon pipe); on
-- every other realm it stays a local PREVIEW with demo items until the vault
-- ships to prod. Flip FORCE_LIVE (or add the realm) when that happens.
-- =====================================================================

local ADDON_PIPE_PREFIX = "UNC"          -- server ADDON_MESSAGE_PREFIX (replies come in on this)
local TRANSPORT_PREFIX  = "REAGENTBANK"  -- shared server addon transport (we send on this)

local FORCE_LIVE = true   -- vault is live on prod (2026-07-26); live on every realm now
local function realmIsDev()
    local r = GetRealmName()
    return r and string.find(string.lower(r), "dev", 1, true) ~= nil
end
-- DEMO = local preview (demo items); not DEMO = live server comms.
local DEMO = not (FORCE_LIVE or realmIsDev())

-- ---- layout constants -------------------------------------------------
local COLS      = 10          -- slots per row
local ROWS      = 7           -- visible rows (a page is COLS*ROWS slots)
local SLOT      = 37          -- slot button size
local GAP       = 4           -- spacing between slots
local STEP      = SLOT + GAP  -- grid pitch / faux-scroll row height
local PAD       = 18          -- interior padding from the frame edge
local HEADER    = 60          -- header band height (title + search row)

local QCOLOR = ITEM_QUALITY_COLORS   -- [q] = {r,g,b,hex}

-- ---- big-number formatting -------------------------------------------
-- "Infinite stacking" means counts blow past normal stack caps, so 1,240,000
-- must read cleanly. 999 -> "999", 12,400 -> "12.4k", 3.5M -> "3.5M".
local function FmtCount(n)
    if n <= 1 then return "" end
    if n < 1000 then return tostring(n) end
    if n < 1e6 then
        local s = string.format("%.1fk", n / 1e3)
        return (s:gsub("%.0k", "k"))
    end
    if n < 1e9 then
        local s = string.format("%.1fM", n / 1e6)
        return (s:gsub("%.0M", "M"))
    end
    local s = string.format("%.1fB", n / 1e9)
    return (s:gsub("%.0B", "B"))
end

-- Thousands-separated full number, for tooltips / footer.
local function Commafy(n)
    local s = tostring(n)
    local k
    repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
    return s
end

-- =====================================================================
-- Demo data. Real WotLK item IDs so tooltips/icons resolve; explicit
-- quality + fallback icon so the look is correct even offline. Ordered
-- roughly as looted (drives the "Recent" sort). `added` = insertion order.
-- =====================================================================
local DEMO_ITEMS = {
    -- ores / bars
    { e = 36910, q = 1, c = 1240000, n = "Titanium Ore",      i = "Interface\\Icons\\INV_Ore_Titanium_01" },
    { e = 36912, q = 1, c = 3480921, n = "Saronite Ore",      i = "Interface\\Icons\\INV_Ore_Cobalt_02" },
    { e = 36909, q = 1, c = 842300,  n = "Cobalt Ore",        i = "Interface\\Icons\\INV_Ore_Cobalt_01" },
    { e = 3858,  q = 1, c = 61240,   n = "Mithril Ore",       i = "Interface\\Icons\\INV_Ore_Mithril_01" },
    { e = 2770,  q = 1, c = 5300,    n = "Copper Ore",        i = "Interface\\Icons\\INV_Ore_Copper_01" },
    { e = 41163, q = 1, c = 88450,   n = "Titanium Bar",      i = "Interface\\Icons\\INV_Ingot_Titansteel_Blue" },
    { e = 37663, q = 1, c = 152900,  n = "Saronite Bar",      i = "Interface\\Icons\\INV_Ingot_Cobalt" },
    -- herbs
    { e = 36901, q = 1, c = 214000,  n = "Goldclover",        i = "Interface\\Icons\\INV_Misc_Herb_GoldClover" },
    { e = 36903, q = 1, c = 133700,  n = "Adder's Tongue",    i = "Interface\\Icons\\INV_Misc_Herb_AddersTongue" },
    { e = 36905, q = 1, c = 98120,   n = "Lichbloom",         i = "Interface\\Icons\\INV_Misc_Herb_Lichbloom" },
    { e = 36906, q = 1, c = 87400,   n = "Icethorn",          i = "Interface\\Icons\\INV_Misc_Herb_Icethorn" },
    { e = 36907, q = 1, c = 45900,   n = "Talandra's Rose",   i = "Interface\\Icons\\INV_Misc_Herb_TalandrasRose" },
    { e = 36908, q = 1, c = 3120,    n = "Frost Lotus",       i = "Interface\\Icons\\INV_Misc_Herb_FrostLotus" },
    -- cloth
    { e = 33470, q = 1, c = 402000,  n = "Frostweave Cloth",  i = "Interface\\Icons\\INV_Fabric_Frostweave" },
    { e = 21877, q = 1, c = 76500,   n = "Netherweave Cloth", i = "Interface\\Icons\\INV_Fabric_Mooncloth_Dreamweave" },
    { e = 14047, q = 1, c = 44200,   n = "Runecloth",         i = "Interface\\Icons\\INV_Fabric_PurpleFire_01" },
    { e = 2589,  q = 1, c = 12800,   n = "Linen Cloth",       i = "Interface\\Icons\\INV_Fabric_Linen_01" },
    -- leather
    { e = 33568, q = 1, c = 187400,  n = "Borean Leather",    i = "Interface\\Icons\\INV_Misc_LeatherScrap_08" },
    { e = 4304,  q = 1, c = 33100,   n = "Thick Leather",     i = "Interface\\Icons\\INV_Misc_LeatherScrap_02" },
    { e = 8170,  q = 1, c = 9400,    n = "Rugged Leather",    i = "Interface\\Icons\\INV_Misc_LeatherScrap_11" },
    -- enchanting mats
    { e = 34054, q = 2, c = 512000,  n = "Infinite Dust",     i = "Interface\\Icons\\INV_Enchant_DustArcane" },
    { e = 34052, q = 2, c = 18700,   n = "Dream Shard",       i = "Interface\\Icons\\INV_Enchant_EssenceAstralLarge" },
    { e = 34057, q = 3, c = 2140,    n = "Abyss Crystal",     i = "Interface\\Icons\\INV_Enchant_VoidCrystal" },
    { e = 22450, q = 3, c = 640,     n = "Void Crystal",      i = "Interface\\Icons\\INV_Enchant_VoidCrystal" },
    -- gems (uncommon)
    { e = 36917, q = 2, c = 3400,    n = "Bloodstone",        i = "Interface\\Icons\\INV_Misc_Gem_BloodGem_02" },
    { e = 36923, q = 2, c = 2900,    n = "Chalcedony",        i = "Interface\\Icons\\INV_Misc_Gem_Sapphire_02" },
    { e = 36926, q = 2, c = 2600,    n = "Shadow Crystal",    i = "Interface\\Icons\\INV_Misc_Gem_Diamond_02" },
    { e = 36929, q = 2, c = 3100,    n = "Huge Citrine",      i = "Interface\\Icons\\INV_Misc_Gem_Opal_02" },
    -- gems (epic)
    { e = 36934, q = 4, c = 84,      n = "Cardinal Ruby",     i = "Interface\\Icons\\INV_Jewelcrafting_CardinalRuby_02" },
    { e = 36933, q = 4, c = 61,      n = "Ametrine",          i = "Interface\\Icons\\INV_Jewelcrafting_Ametrine_02" },
    -- consumables
    { e = 33447, q = 1, c = 9999,    n = "Runic Healing Potion", i = "Interface\\Icons\\INV_Potion_131" },
    { e = 33448, q = 1, c = 8420,    n = "Runic Mana Potion", i = "Interface\\Icons\\INV_Potion_137" },
    { e = 40211, q = 1, c = 2140,    n = "Potion of Speed",   i = "Interface\\Icons\\INV_Potion_108" },
    { e = 46377, q = 3, c = 1250,    n = "Flask of Endless Rage", i = "Interface\\Icons\\INV_Potion_41" },
    { e = 46376, q = 3, c = 980,     n = "Flask of the Frost Wyrm", i = "Interface\\Icons\\INV_Potion_97" },
    { e = 42995, q = 1, c = 640,     n = "Rhinolicious Wyrmsteak", i = "Interface\\Icons\\INV_Misc_Food_65" },
    -- junk (poor) + common
    { e = 6532,  q = 0, c = 214,     n = "Small Furry Paw",   i = "Interface\\Icons\\INV_Misc_MonsterClaw_03" },
    { e = 6948,  q = 1, c = 3,       n = "Hearthstone",       i = "Interface\\Icons\\INV_Misc_Rune_01" },
    -- gear -- shown STACKED (identical drops collapse into one counted slot)
    { e = 39292, q = 2, c = 12,      n = "Reinforced Cobalt Helm",  i = "Interface\\Icons\\INV_Helmet_154" },
    { e = 43102, q = 3, c = 4,       n = "Frozen Orb",        i = "Interface\\Icons\\Spell_Frost_FrozenOrb" },
    { e = 40684, q = 3, c = 2,       n = "Mirror of Truth",   i = "Interface\\Icons\\Spell_Holy_SummonChampion" },
    -- legendaries (small counts -- proves even uniques stack in the vault)
    { e = 19019, q = 5, c = 2,       n = "Thunderfury, Blessed Blade of the Windseeker", i = "Interface\\Icons\\INV_Sword_39" },
    { e = 17182, q = 5, c = 1,       n = "Sulfuras, Hand of Ragnaros", i = "Interface\\Icons\\INV_Hammer_Unique_Sulfuras" },
    { e = 32837, q = 5, c = 1,       n = "Warglaive of Azzinoth", i = "Interface\\Icons\\INV_Weapon_Glave_01" },
    { e = 49623, q = 5, c = 1,       n = "Shadowmourne",      i = "Interface\\Icons\\INV_Axe_113" },
    { e = 46017, q = 5, c = 1,       n = "Val'anyr, Hammer of Ancient Kings", i = "Interface\\Icons\\INV_Mace_128" },
}

-- =====================================================================
-- Live state
-- =====================================================================
local ALL       = {}      -- full item list (from demo or server)
local view      = {}      -- filtered + sorted list currently displayed
local sortKey   = "count"
local query     = ""

local frame               -- main window
local slots     = {}      -- pool of COLS*ROWS slot buttons
local scroll              -- FauxScrollFrame
local footer              -- summary fontstring
local pendingIcons = false -- a visible item isn't in the client's cache yet

-- Item-cache warming.
--
-- 3.3.5's GetItemInfo() does NOT ask the server for an item it has never seen,
-- so a freshly-migrated stack shows a blank icon forever. We force the fetch
-- with a hidden scanning tooltip (SetHyperlink triggers the item query); the
-- client then caches the result to disk (Cache\WDB), so it is instant on every
-- later session. The whole vault is warmed in the BACKGROUND the moment its
-- snapshot arrives at login -- so icons are ready before you even open it --
-- at a steady trickle, each item queried EXACTLY ONCE (re-querying every tick
-- is what jammed the client's query throttle before and left icons stuck).
local scanParent = CreateFrame("Frame")
scanParent:Hide()   -- a tooltip parented to a hidden frame never renders, but its query still fires
local scanTip = CreateFrame("GameTooltip", "UncappedVaultScanTip", scanParent, "GameTooltipTemplate")
scanTip:SetOwner(scanParent, "ANCHOR_NONE")

local queried    = {}   -- item entries already queried (never re-query)
local pending    = {}   -- item entries currently queued for warming
local warmQueue  = {}
local iconsDirty = false -- an icon resolved; the window (if open) should re-render

local function enqueueWarm(e)
    if pending[e] or GetItemInfo(e) then return end   -- already queued, or already cached
    pending[e] = true
    warmQueue[#warmQueue + 1] = e
end

-- Steady background warmer: fires a few new queries per tick, drops items as
-- they resolve. Runs whether or not the window is open.
local warmer = CreateFrame("Frame")
local warmAcc = 0
warmer:SetScript("OnUpdate", function(_, dt)
    if #warmQueue == 0 then return end
    warmAcc = warmAcc + dt
    if warmAcc < 0.2 then return end
    warmAcc = 0
    local fired = 0
    for i = #warmQueue, 1, -1 do
        local e = warmQueue[i]
        if GetItemInfo(e) then
            pending[e] = nil
            table.remove(warmQueue, i)
            iconsDirty = true
        elseif not queried[e] and fired < 10 then
            queried[e] = true
            scanTip:SetHyperlink("item:" .. e)
            fired = fired + 1
        end
    end
end)

-- Track the last bag slot an item was picked up from, so a drag-drop onto the
-- vault window knows exactly which stack to deposit.
local lastPickup
if hooksecurefunc then
    hooksecurefunc("PickupContainerItem", function(bag, slot)
        lastPickup = { bag = bag, slot = slot }
    end)
end
local function DepositCursor()
    if DEMO then ClearCursor(); return end   -- preview build: deposit is server-only
    if not CursorHasItem() then return end
    local t = GetCursorInfo()
    if t == "item" and lastPickup then
        VaultSend(string.format("VLTDEP:%d:%d", lastPickup.bag, lastPickup.slot))
    end
    ClearCursor()
end

-- =====================================================================
-- Filter + sort
-- =====================================================================
local SORTERS = {
    name    = function(a, b) return a.n < b.n end,
    count   = function(a, b) if a.c ~= b.c then return a.c > b.c end return a.n < b.n end,
    quality = function(a, b) if a.q ~= b.q then return a.q > b.q end return a.n < b.n end,
    recent  = function(a, b) return (a.added or 0) > (b.added or 0) end,
}

local function Rebuild()
    wipe(view)
    local q = query:lower()
    for _, it in ipairs(ALL) do
        -- Live rows arrive name-less (server sends numbers only); resolve the
        -- name lazily from the client's item cache so text search works.
        if it.n == nil or it.n == "" then it.n = GetItemInfo(it.e) or "" end
        if q == "" or it.n:lower():find(q, 1, true) then
            view[#view + 1] = it
        end
    end
    table.sort(view, SORTERS[sortKey] or SORTERS.count)
end

-- =====================================================================
-- Rendering
-- =====================================================================
local function UpdateFooter()
    local stacks, total = #view, 0
    for _, it in ipairs(view) do total = total + it.c end
    footer:SetText(string.format(
        "|cffffd100%s|r stacks   |cff808080/|r   |cffffd100%s|r items%s",
        Commafy(stacks), Commafy(total),
        (query ~= "" and "   |cff808080(filtered)|r" or "")))
end

local function ShowTooltip(btn)
    GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
    local it = btn.item
    -- Real item tooltip when the client knows the item; otherwise a clean
    -- name/quality line from our stored data.
    local link = select(2, GetItemInfo(it.e))
    if link then
        GameTooltip:SetHyperlink(link)
    else
        local col = QCOLOR[it.q] or QCOLOR[1]
        GameTooltip:SetText(it.n, col.r, col.g, col.b)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(string.format("In vault: |cffffffff%s|r", Commafy(it.c)), 0.4, 0.8, 1)
    GameTooltip:AddLine("Right-click to withdraw one", 0.5, 0.5, 0.5)
    GameTooltip:AddLine("Shift-right-click to withdraw an amount", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function RefreshSlots()
    pendingIcons = false
    local offset = FauxScrollFrame_GetOffset(scroll) or 0
    local rows = math.ceil(#view / COLS)
    FauxScrollFrame_Update(scroll, rows, ROWS, STEP)

    for idx = 1, COLS * ROWS do
        local btn = slots[idx]
        local dataIndex = offset * COLS + idx
        local it = view[dataIndex]
        if it then
            btn.item = it
            local tex = it.icon or select(10, GetItemInfo(it.e)) or it.i   -- server-sent icon first
            if not tex then
                tex = "Interface\\Icons\\INV_Misc_QuestionMark"
                pendingIcons = true
                enqueueWarm(it.e)   -- make sure this on-screen item is in the warm queue
            end
            _G[btn:GetName() .. "IconTexture"]:SetTexture(tex)
            local cf = _G[btn:GetName() .. "Count"]
            local txt = FmtCount(it.c)
            cf:SetText(txt)
            if txt ~= "" then cf:Show() else cf:Hide() end
            -- quality glow on the slot (hidden for poor/common)
            local col = QCOLOR[it.q]
            if it.q and it.q >= 2 and col then
                btn.glow:SetVertexColor(col.r, col.g, col.b)
                btn.glow:Show()
            else
                btn.glow:Hide()
            end
            btn:Show()
        else
            btn.item = nil
            btn:Hide()
        end
    end
    UpdateFooter()
end

-- =====================================================================
-- Withdraw (demo: decrement locally. real build: send IVAULT WITHDRAW)
-- =====================================================================
local function DoWithdraw(it, count)
    count = math.min(count, it.c)
    if count <= 0 then return end
    if DEMO then
        it.c = it.c - count
        if it.c <= 0 then
            for k, v in ipairs(ALL) do if v == it then table.remove(ALL, k) break end end
        end
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "|cff40c0ff[Vault]|r withdrew |cffffffff%sx|r %s", Commafy(count), it.n))
        Rebuild()
        RefreshSlots()
    else
        -- Server is authoritative; the row updates when VLTWDONE comes back.
        VaultSend(string.format("VLTWD:%d:%d:%d", it.e, it.rp or 0, count))
    end
end

StaticPopupDialogs["UNCAPPEDVAULT_WITHDRAW"] = {
    text = "Withdraw how many %s?",
    button1 = ACCEPT, button2 = CANCEL,
    hasEditBox = true, maxLetters = 12,
    OnShow = function(self) self.editBox:SetText("1"); self.editBox:HighlightText() end,
    OnAccept = function(self)
        local it = self.data
        local n = tonumber(self.editBox:GetText())
        if it and n then DoWithdraw(it, math.floor(n)) end
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        local it = parent.data
        local n = tonumber(self:GetText())
        if it and n then DoWithdraw(it, math.floor(n)) end
        parent:Hide()
    end,
    timeout = 0, whileDead = true, hideOnEscape = true,
}

local function SlotOnClick(btn, mouse)
    if CursorHasItem() then DepositCursor(); return end   -- clicked a slot holding an item -> deposit
    local it = btn.item
    if not it then return end
    if mouse == "RightButton" then
        if IsShiftKeyDown() then
            local dlg = StaticPopup_Show("UNCAPPEDVAULT_WITHDRAW", it.n)
            if dlg then dlg.data = it end
        else
            DoWithdraw(it, 1)
        end
    end
end

-- =====================================================================
-- Build the window
-- =====================================================================
-- =====================================================================
-- Dynamic grid. Slots are made on demand; COLS/ROWS are recomputed from the
-- window's current size so the grid reflows as it's resized.
-- =====================================================================
local function createSlot(idx)
    local btn = CreateFrame("Button", "UncappedVaultSlot" .. idx, frame, "ItemButtonTemplate")
    btn:SetWidth(SLOT); btn:SetHeight(SLOT)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local glow = btn:CreateTexture(nil, "OVERLAY")
    glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    glow:SetBlendMode("ADD"); glow:SetAlpha(0.75)
    glow:SetWidth(SLOT + 22); glow:SetHeight(SLOT + 22)
    glow:SetPoint("CENTER"); glow:Hide()
    btn.glow = glow
    btn:SetScript("OnClick", SlotOnClick)
    btn:SetScript("OnReceiveDrag", DepositCursor)
    btn:SetScript("OnEnter", ShowTooltip)
    btn:SetScript("OnLeave", GameTooltip_Hide)
    slots[idx] = btn
    return btn
end

local function Relayout()
    if not frame or not scroll then return end
    -- Fit as many whole slot columns/rows as the current window allows.
    COLS = math.max(4, math.min(24, math.floor((frame:GetWidth()  - PAD * 2 - 22 + GAP) / STEP)))
    ROWS = math.max(3, math.min(20, math.floor((frame:GetHeight() - HEADER - 40 + GAP) / STEP)))
    local need = COLS * ROWS
    for idx = 1, need do
        local btn = slots[idx] or createSlot(idx)
        local r = math.floor((idx - 1) / COLS)
        local c = (idx - 1) % COLS
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", scroll, "TOPLEFT", c * STEP, -r * STEP)
    end
    for idx = need + 1, #slots do slots[idx]:Hide() end   -- surplus from a larger prior size
    scroll:SetWidth(COLS * STEP - GAP)
    scroll:SetHeight(ROWS * STEP - GAP)
    RefreshSlots()
end

local function BuildFrame()
    local W = PAD * 2 + COLS * STEP - GAP + 22   -- +bar gutter
    local H = HEADER + ROWS * STEP - GAP + 44    -- +footer

    frame = CreateFrame("Frame", "UncappedVaultFrame", UIParent)
    frame:SetWidth(W)
    frame:SetHeight(H)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint()
        UncappedVaultDB = UncappedVaultDB or {}
        UncappedVaultDB.pos = { p, rp, x, y }
    end)
    tinsert(UISpecialFrames, "UncappedVaultFrame")   -- ESC closes it

    -- Drag an item from your bags onto the window (or click the window while
    -- holding one) to deposit it into the vault.
    frame:SetScript("OnReceiveDrag", DepositCursor)
    frame:SetScript("OnMouseUp", function(_, b)
        if b == "LeftButton" and CursorHasItem() then DepositCursor() end
    end)
    -- Retry icon resolution until the client has cached every visible item
    -- (GetItemInfo returns nil the first time for an uncached item).
    frame:SetScript("OnUpdate", function(self, dt)
        self._t = (self._t or 0) + dt
        if self._t < 0.15 then return end
        self._t = 0
        if iconsDirty then iconsDirty = false; RefreshSlots() end
    end)

    -- title banner (the classic gold header)
    local banner = frame:CreateTexture(nil, "ARTWORK")
    banner:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    banner:SetWidth(256); banner:SetHeight(64)
    banner:SetPoint("TOP", 0, 12)
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", banner, "TOP", 0, -14)
    title:SetText(DEMO and "Vault  |cff808080(preview)|r" or "Vault")

    -- close button
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    -- search box
    local search = CreateFrame("EditBox", "UncappedVaultSearch", frame, "InputBoxTemplate")
    search:SetPoint("TOPLEFT", PAD + 6, -HEADER + 26)
    search:SetWidth(180); search:SetHeight(20)
    search:SetAutoFocus(false)
    local ph = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ph:SetPoint("LEFT", 4, 0)
    ph:SetText("Search...")
    search:SetScript("OnTextChanged", function(self)
        query = self:GetText() or ""
        if query == "" then ph:Show() else ph:Hide() end
        Rebuild()
        _G["UncappedVaultScrollScrollBar"]:SetValue(0)   -- back to top on new filter
        RefreshSlots()
    end)
    search:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    local mag = frame:CreateTexture(nil, "OVERLAY")
    mag:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
    mag:SetWidth(14); mag:SetHeight(14)
    mag:SetPoint("RIGHT", search, "RIGHT", -4, 0)

    -- sort dropdown
    local sortDD = CreateFrame("Frame", "UncappedVaultSort", frame, "UIDropDownMenuTemplate")
    sortDD:SetPoint("TOPRIGHT", -PAD - 4, -HEADER + 34)
    local SORT_CHOICES = {
        { v = "count",   t = "Quantity" },
        { v = "quality", t = "Quality" },
        { v = "name",    t = "Name" },
        { v = "recent",  t = "Recently added" },
    }
    local function labelFor(v) for _, c in ipairs(SORT_CHOICES) do if c.v == v then return c.t end end end
    UIDropDownMenu_Initialize(sortDD, function()
        for _, c in ipairs(SORT_CHOICES) do
            local info = UIDropDownMenu_CreateInfo()
            info.text, info.value = c.t, c.v
            info.checked = (sortKey == c.v)
            info.func = function()
                sortKey = c.v
                UncappedVaultDB = UncappedVaultDB or {}
                UncappedVaultDB.sort = c.v
                UIDropDownMenu_SetSelectedValue(sortDD, c.v)
                UIDropDownMenu_SetText(sortDD, c.t)
                Rebuild(); RefreshSlots()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetWidth(sortDD, 110)
    UIDropDownMenu_SetSelectedValue(sortDD, sortKey)
    UIDropDownMenu_SetText(sortDD, labelFor(sortKey))
    local sortLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sortLabel:SetPoint("BOTTOMLEFT", sortDD, "TOPLEFT", 20, 0)
    sortLabel:SetText("Sort")

    -- interior "bag" backing behind the grid
    local gridTop = -HEADER
    local inner = frame:CreateTexture(nil, "BACKGROUND")
    inner:SetTexture(0, 0, 0, 0.35)
    inner:SetPoint("TOPLEFT", PAD - 6, gridTop + 4)
    inner:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD - 8, 34)

    -- faux scroll over the grid area
    scroll = CreateFrame("ScrollFrame", "UncappedVaultScroll", frame, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", PAD, gridTop)
    scroll:SetWidth(COLS * STEP - GAP)
    scroll:SetHeight(ROWS * STEP - GAP)
    scroll:SetScript("OnVerticalScroll", function(self, delta)
        FauxScrollFrame_OnVerticalScroll(self, delta, STEP, RefreshSlots)
    end)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        local bar = _G["UncappedVaultScrollScrollBar"]
        bar:SetValue(bar:GetValue() - delta * STEP)   -- one row per wheel tick
    end)

    -- (slot buttons are created + laid out by Relayout, at the end of BuildFrame)

    -- footer summary
    footer = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    footer:SetPoint("BOTTOMLEFT", PAD + 2, 18)
    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMRIGHT", -PAD - 12, 18)
    hint:SetText("Drag items here to deposit  |cff808080/|r  right-click to withdraw")

    -- resize: a grip in the bottom-right corner; the grid reflows to fit.
    frame:SetResizable(true)
    frame:SetMinResize(PAD * 2 + 4 * STEP - GAP + 22, HEADER + 3 * STEP - GAP + 44)
    frame:SetMaxResize(PAD * 2 + 24 * STEP - GAP + 22, HEADER + 20 * STEP - GAP + 44)
    local grip = CreateFrame("Button", nil, frame)
    grip:SetWidth(16); grip:SetHeight(16)
    grip:SetPoint("BOTTOMRIGHT", -5, 7)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        UncappedVaultDB = UncappedVaultDB or {}
        UncappedVaultDB.size = { frame:GetWidth(), frame:GetHeight() }
        Relayout()
    end)
    frame:SetScript("OnSizeChanged", function() Relayout() end)

    Relayout()   -- build + place the initial grid
    frame:Hide()
end

-- =====================================================================
-- Public open/close/toggle
-- =====================================================================
local function Open()
    if not frame then BuildFrame() end
    if UncappedVaultDB and UncappedVaultDB.pos then
        local p, rp, x, y = unpack(UncappedVaultDB.pos)
        frame:ClearAllPoints(); frame:SetPoint(p, UIParent, rp, x, y)
    end
    if UncappedVaultDB and UncappedVaultDB.size then
        frame:SetWidth(UncappedVaultDB.size[1])
        frame:SetHeight(UncappedVaultDB.size[2])   -- fires OnSizeChanged -> Relayout
    end
    wipe(queried); wipe(pending); wipe(warmQueue)   -- fresh retry pass for anything still uncached
    for _, it in ipairs(ALL) do enqueueWarm(it.e) end
    Rebuild(); RefreshSlots()
    frame:Show()
    if not DEMO then VaultSend("VLTGET") end   -- pull a fresh snapshot
end

local function Toggle()
    if frame and frame:IsShown() then frame:Hide() else Open() end
end

-- =====================================================================
-- Data source
-- =====================================================================
local function LoadDemo()
    wipe(ALL)
    for k, src in ipairs(DEMO_ITEMS) do
        ALL[#ALL + 1] = { e = src.e, q = src.q, c = src.c, n = src.n, i = src.i, added = #DEMO_ITEMS - k }
    end
end

-- =====================================================================
-- Server comms (live mode). We send VLT* commands over the shared addon
-- transport ("REAGENTBANK"); the server routes them to the vault handler and
-- replies over prefix "UNC", which the client never renders.
--   send:  VLTGET | VLTWD:<entry>:<rpid>:<count>
--   recv:  VLTROW:e,rp,c,q;...  VLTEND:<n>  VLTWDONE:e:rp:given:remaining  VLTWDFAIL:e:rp
-- =====================================================================
function VaultSend(msg)
    SendAddonMessage(TRANSPORT_PREFIX, msg, "WHISPER", UnitName("player"))
end

local staging = {}
local function findRow(e, rp)
    for _, it in ipairs(ALL) do
        if it.e == e and (it.rp or 0) == rp then return it end
    end
end

local comms = CreateFrame("Frame")
comms:RegisterEvent("CHAT_MSG_ADDON")
comms:SetScript("OnEvent", function(_, _, a1, a2)
    if a1 ~= ADDON_PIPE_PREFIX or not a2 then return end
    local text = a2
    if text:find("^VLTROW:") then
        for e, rp, c, q, icon in string.gmatch(text, "(%-?%d+),(%-?%d+),(%d+),(%d+),([^;]*);") do
            staging[#staging + 1] = { e = tonumber(e), rp = tonumber(rp), c = tonumber(c), q = tonumber(q),
                icon = (icon ~= "" and ("Interface\\Icons\\" .. icon)) or nil, n = "" }
        end
    elseif text:find("^VLTEND:") then
        ALL = staging
        staging = {}
        for idx, it in ipairs(ALL) do it.added = #ALL - idx end
        for _, it in ipairs(ALL) do enqueueWarm(it.e) end   -- warm the whole vault now, in the background
        if frame and frame:IsShown() then Rebuild(); RefreshSlots() end
    elseif text:find("^VLTWDONE:") then
        local e, rp, given, remaining = text:match("^VLTWDONE:(%d+):(%-?%d+):(%d+):(%d+)$")
        if e then
            e, rp, given, remaining = tonumber(e), tonumber(rp), tonumber(given), tonumber(remaining)
            local it = findRow(e, rp)
            if it then
                it.c = remaining
                if remaining <= 0 then
                    for k, v in ipairs(ALL) do if v == it then table.remove(ALL, k) break end end
                end
            end
            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                "|cff40c0ff[Vault]|r withdrew |cffffffff%sx|r %s", Commafy(given), GetItemInfo(e) or ("item " .. e)))
            Rebuild(); RefreshSlots()
        end
    elseif text:find("^VLTWDFAIL:") then
        DEFAULT_CHAT_FRAME:AddMessage("|cff40c0ff[Vault]|r couldn't withdraw -- bags full, or not enough left in the vault.")
    elseif text:find("^VLTDEPFAIL:") then
        local why = text:match("^VLTDEPFAIL:(%a+)")
        local reason = (why == "quest" and "quest items") or (why == "bag" and "bags")
            or (why == "bound" and "soulbound items") or "that item"
        DEFAULT_CHAT_FRAME:AddMessage("|cff40c0ff[Vault]|r can't deposit " .. reason .. ".")
    end
end)

-- =====================================================================
-- Init
-- =====================================================================
local init = CreateFrame("Frame")
init:RegisterEvent("PLAYER_LOGIN")
init:SetScript("OnEvent", function()
    UncappedVaultDB = UncappedVaultDB or {}
    if UncappedVaultDB.sort then sortKey = UncappedVaultDB.sort end
    if DEMO then
        LoadDemo()
        if not UncappedVaultDB.previewShown then
            UncappedVaultDB.previewShown = true   -- first login only; never auto-pop again
            DEFAULT_CHAT_FRAME:AddMessage("|cff40c0ff[Vault]|r preview installed -- type |cffffd100/vault|r to open it anytime.")
            Open()
        end
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff40c0ff[Vault]|r ready -- type |cffffd100/vault|r to open your vault.")
        VaultSend("VLTGET")   -- warm the snapshot so it's ready on first open
    end

    -- Follow the bags: open the vault when bags open, close it when they close.
    -- Works with the default UI and the popular bag replacements. (Preview build
    -- stays out of the way -- no auto-pop on the live realm.)
    if not DEMO then
        local function openVault()  if not (frame and frame:IsShown()) then Open() end end
        local function closeVault() if frame and frame:IsShown() then frame:Hide() end end

        -- Window frames of the popular bag replacements. bagsVisible() READS the
        -- real state -- we never flip-track a toggle (that inverts as soon as the
        -- tracked state drifts, which is exactly the ArkInventory bug).
        local BAG_FRAMES = {
            "ARKINV_Frame1",                            -- ArkInventory (bags = location 1)
            "BagnonFrameinventory", "BagnonInventory",  -- Bagnon
            "CombuctorFrameinventory", "Combuctor",     -- Combuctor
            "OneBagFrame",                              -- OneBag3
            "AdiBagsContainer1",                        -- AdiBags
            "BaganatorSingleViewBackpackViewFrame",     -- Baganator
            "cargBags_Default_Main",                    -- cargBags
            "BagginsForm1",                             -- Baggins
        }
        local function bagsVisible()
            for _, name in ipairs(BAG_FRAMES) do
                local f = _G[name]
                if f and f:IsShown() then return true end
            end
            for i = 0, 4 do
                if IsBagOpen(i) then return true end
            end
            return false
        end

        -- Any bag event -> next frame, set the vault to match reality. Coalesces
        -- the burst of events when several bag frames open/close at once.
        local watcher = CreateFrame("Frame"); watcher:Hide()
        watcher:SetScript("OnUpdate", function(self)
            self:Hide()
            if bagsVisible() then openVault() else closeVault() end
        end)
        local function sync() watcher:Show() end

        -- Default bags fire ContainerFrame_OnShow/OnHide. We deliberately drive
        -- everything off the actual bag WINDOWS (below) rather than the bag
        -- functions -- a window we don't recognise then simply doesn't sync,
        -- instead of wrongly closing the vault when its bags open.
        hooksecurefunc("ContainerFrame_OnShow", sync)
        hooksecurefunc("ContainerFrame_OnHide", sync)

        -- Hook each popular addon's window directly, so its own show/hide
        -- (incl. ESC) drives the sync. Hooked only if present; some are lazy.
        local hooked = {}
        local function hookFrames()
            for _, name in ipairs(BAG_FRAMES) do
                local f = _G[name]
                if f and not hooked[name] and f.HookScript then
                    hooked[name] = true
                    f:HookScript("OnShow", sync)
                    f:HookScript("OnHide", sync)
                end
            end
        end
        hookFrames()
        local poller, acc, tries = CreateFrame("Frame"), 0, 0
        poller:SetScript("OnUpdate", function(self, dt)   -- catch lazily-created frames
            acc = acc + dt
            if acc < 2 then return end
            acc, tries = 0, tries + 1
            hookFrames()
            if tries >= 15 then self:SetScript("OnUpdate", nil); self:Hide() end
        end)
    end
end)

SLASH_UNCAPPEDVAULT1 = "/vault"
SlashCmdList["UNCAPPEDVAULT"] = Toggle
