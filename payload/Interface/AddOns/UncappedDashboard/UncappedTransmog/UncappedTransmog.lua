-- =====================================================================
-- Uncapped Transmog -- the appearance collection.
--
-- A retail-style wardrobe: slot tabs down the side, a searchable grid of
-- every look in the game, and a live 3D preview of your character wearing
-- the one under the cursor. Collected and uncollected appearances sit side
-- by side, so the window doubles as a checklist of what is still out there
-- and where it drops.
--
--
-- APPEARANCES, NOT ITEMS
--
-- The unit here is a DISPLAY ID, not an item id. Roughly 30,000 item
-- entries collapse into 18,019 distinct looks, because dozens of entries
-- share one model -- every tier of "Ravager's Chestpiece" is one appearance.
-- Listing items instead of looks would show the same chest forty times.
--
-- The server speaks the same language: it syncs the displayids the account
-- has unlocked, and when an appearance is applied it resolves that displayid
-- back to a concrete item entry the account actually owns. So this addon
-- never needs to know which of the forty entries you collected.
--
--
-- WHY THERE IS A GENERATED DATA FILE
--
-- UncappedTransmogData.lua carries name, quality, class, subclass and item
-- level for all 18,019 looks. It has to be baked in, because the client's
-- own item cache is empty for anything you have never seen -- GetItemInfo
-- returns nil, and searching 18k appearances by name would otherwise mean
-- 18k server queries. Regenerate it whenever item_template changes, with
-- azerothcore-wotlk/tools/generate_transmog_appearance_db.sh.
--
-- Icons and 3D models are NOT in that file: the client resolves both from
-- its own DBCs for any real 3.3.5a item, with no server round-trip. Every
-- transmoggable item on this realm is a stock entry, so previews always
-- work offline.
-- =====================================================================

local ADDON_PIPE_PREFIX = "UNC"          -- server -> client (replies arrive here)
local TRANSPORT_PREFIX  = "REAGENTBANK"  -- client -> server (shared addon transport)

local HIDDEN_DISPLAY = 1   -- reserved displayid meaning "hide this slot"

-- ---- layout -----------------------------------------------------------
-- The grid is sized so the filter row fits inside it: three dropdowns need
-- ~470px, and a 6-column grid was only 306 wide, which pushed the third
-- dropdown clean outside the frame.
local COLS       = 9
local ROWS       = 6
local CELL       = 46
local CELL_GAP   = 6
local CELL_STEP  = CELL + CELL_GAP
local PREVIEW_W  = 232
local PAD        = 16
local TAB        = 28   -- slot tab button size
local TAB_STEP   = TAB + 2
local SCROLLBAR  = 24   -- reserved so the scrollbar sits inside the frame
local HEADER     = 78   -- title band above the search row

local QCOLOR = ITEM_QUALITY_COLORS

-- =====================================================================
-- Slots
--
-- `pool` is the SUPERSET of inventory types that could ever apply to this
-- slot; IsEligible below narrows it against whatever is actually equipped,
-- because the real rules are target-dependent (an equipped shield accepts
-- other shields, an equipped sword accepts any melee weapon).
-- =====================================================================
local SLOTS = {
    { slot = 0,  label = "Head",      pool = { 1 },  icon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Head" },
    { slot = 2,  label = "Shoulders", pool = { 3 },  icon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Shoulder" },
    { slot = 3,  label = "Shirt",     pool = { 4 },  icon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Shirt" },
    { slot = 4,  label = "Chest",     pool = { 5, 20 }, icon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Chest" },
    { slot = 5,  label = "Waist",     pool = { 6 },  icon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Waist" },
    { slot = 6,  label = "Legs",      pool = { 7 },  icon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Legs" },
    { slot = 7,  label = "Feet",      pool = { 8 },  icon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Feet" },
    { slot = 8,  label = "Wrists",    pool = { 9 },  icon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Wrists" },
    { slot = 9,  label = "Hands",     pool = { 10 }, icon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Hands" },
    { slot = 14, label = "Back",      pool = { 16 }, icon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Chest" },
    { slot = 15, label = "Main Hand", pool = { 13, 17, 21, 22 }, icon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-MainHand" },
    { slot = 16, label = "Off Hand",  pool = { 13, 17, 21, 22, 14, 23 }, icon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-SecondaryHand" },
    { slot = 17, label = "Ranged",    pool = { 15, 25, 26 }, icon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Ranged" },
    { slot = 18, label = "Tabard",    pool = { 19 }, icon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Tabard" },
}

local SLOT_BY_ID = {}
for _, s in ipairs(SLOTS) do SLOT_BY_ID[s.slot] = s end

-- Weapon subclasses that occupy the ranged slot. Ranged and melee never mix,
-- the one weapon restriction this realm kept -- the models do not render
-- correctly on the wrong kind of weapon.
local RANGED_SUB = { [2] = true, [3] = true, [18] = true, [19] = true, [16] = true }

-- Armor that can sit in an off hand: buckler, shield, or a misc "held in
-- off-hand" item such as a tome.
local function IsOffhandArmor(sub, inv)
    return sub == 5 or sub == 6 or (sub == 0 and inv == 23)
end

local ARMOR_SUB_NAME = {
    [0] = "Miscellaneous", [1] = "Cloth", [2] = "Leather", [3] = "Mail",
    [4] = "Plate", [5] = "Buckler", [6] = "Shield", [7] = "Libram",
    [8] = "Idol", [9] = "Totem", [10] = "Sigil",
}
local WEAPON_SUB_NAME = {
    [0] = "Axe", [1] = "Two-Handed Axe", [2] = "Bow", [3] = "Gun",
    [4] = "Mace", [5] = "Two-Handed Mace", [6] = "Polearm", [7] = "Sword",
    [8] = "Two-Handed Sword", [10] = "Staff", [13] = "Fist Weapon",
    [14] = "Miscellaneous", [15] = "Dagger", [16] = "Thrown",
    [18] = "Crossbow", [19] = "Wand", [20] = "Fishing Pole",
}

local SOURCE_KIND = {
    [1] = "Drops from", [2] = "Found in", [3] = "Fished up in",
    [4] = "Skinned from", [5] = "Crafted",
}

-- =====================================================================
-- Appearance rows
--
-- Rows live as packed strings ("entry:disp:quality:class:sub:ilvl:name")
-- and are parsed into tables lazily. 18k tables up front costs several
-- megabytes and a visible hitch at load; parsed-on-demand costs nothing
-- until a slot is actually opened, and name search runs straight over the
-- raw strings as a single C-side string.find.
-- =====================================================================
local rowCache = {}   -- [invType] = { parsed rows }

local function ParsedRows(invType)
    local cached = rowCache[invType]
    if cached then return cached end

    local out = {}
    local raw = UncappedTransmogData and UncappedTransmogData[invType]
    if raw then
        for i = 1, #raw do
            local entry, disp, q, cls, sub, ilvl, name =
                raw[i]:match("^(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(.*)$")
            if entry then
                out[#out + 1] = {
                    entry = tonumber(entry), disp = tonumber(disp), q = tonumber(q),
                    cls = tonumber(cls), sub = tonumber(sub), ilvl = tonumber(ilvl),
                    inv = invType, name = name, lname = name:lower(),
                }
            end
        end
    end

    rowCache[invType] = out
    return out
end

-- =====================================================================
-- State
-- =====================================================================
local collection   = {}   -- [displayId] = true
local collCount    = 0
local favorites    = {}   -- [displayId] = true
local equipment    = {}   -- [slot] = { entry, fakeEntry, fakeDisp, cls, sub, inv }
local outfits        = {}   -- [presetId] = { name, items = { [slot] = {entry, disp} } }
local outfitStaging  = {}   -- filled while a TMSET batch streams in
local outfitBatchDone = true
local maxSets        = 10

local currentSlot  = 0
local selected     = nil  -- selected row (a parsed appearance)
local previewEntry = nil  -- item entry the 3D model is currently wearing
local query        = ""
local filterOwned  = "all"   -- all | collected | missing | favorites
-- nil means "any". Poor gear is quality 0, so a numeric sentinel would
-- collide with it -- hence nil rather than 0.
local filterQuality = nil
local filterSub    = nil     -- armor or weapon subclass; nil = any
local results      = {}
local sourceLines  = {}
local sourceFor    = nil

local frame, grid, modelFrame, scroll, sourceText, countText, subDD
local slotButtons  = {}
local cells        = {}

-- FauxScrollFrame keeps its offset and its scrollbar widget in step only if
-- both are reset; setting the offset alone leaves the thumb stranded.
local function ResetScroll()
    if not scroll then return end
    FauxScrollFrame_SetOffset(scroll, 0)
    local bar = _G[scroll:GetName() .. "ScrollBar"]
    if bar then bar:SetValue(0) end
end

-- =====================================================================
-- Packed-set decoding
--
-- The server sends the collection as sorted displayids, delta-encoded,
-- varint-packed and base64'd -- a 5,000-look collection lands under 4KB
-- instead of tens of kilobytes of text through a 255-byte chat transport.
-- =====================================================================
local B64_INDEX = {}
do
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 1, #alphabet do B64_INDEX[alphabet:sub(i, i)] = i - 1 end
end

local function DecodePacked(encoded)
    local bytes, n = {}, 0
    local acc, bits = 0, 0

    for i = 1, #encoded do
        local v = B64_INDEX[encoded:sub(i, i)]
        if v then
            acc = acc * 64 + v
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                local shift = 2 ^ bits
                local byte = math.floor(acc / shift)
                acc = acc - byte * shift
                n = n + 1
                bytes[n] = byte
            end
        end
    end

    local values, count = {}, 0
    local running, shift, cur = 0, 1, 0

    for i = 1, n do
        local byte = bytes[i]
        if byte >= 128 then
            cur = cur + (byte - 128) * shift
            shift = shift * 128
        else
            cur = cur + byte * shift
            running = running + cur
            count = count + 1
            values[count] = running
            cur, shift = 0, 1
        end
    end

    return values, count
end

-- =====================================================================
-- Comms
-- =====================================================================
local function Send(msg)
    SendAddonMessage(TRANSPORT_PREFIX, msg, "WHISPER", UnitName("player"))
end

-- One buffer per stream. The collection and the favourites list are both
-- requested at login and arrive chunked, so a single shared buffer would
-- interleave them into garbage.
local packBuffers = { TMPK = {}, TMFAVPK = {} }

local function ApplyCollection(values)
    wipe(collection)
    for i = 1, #values do collection[values[i]] = true end
    collCount = #values
end

-- =====================================================================
-- Eligibility -- mirrors the server's CanTransmogrifyItemWithItem
--
-- Kept in sync with transmog.conf as it stands on this realm:
-- AllowMixedWeaponTypes = LOOSE, AllowMixedArmorTypes = 1,
-- AllowMixedOffhandArmorTypes = 1. The server re-validates every apply, so
-- a drift here shows a look that cannot be used -- it can never let one
-- through that should not be.
-- =====================================================================
local function IsEligible(row, eq)
    if not eq or not eq.entry or eq.entry == 0 then return false end
    if row.cls ~= eq.cls then return false end

    -- Applying the look you are already wearing is rejected server-side.
    if row.disp == eq.disp then return false end

    if eq.cls == 2 then -- weapon
        local srcRanged = RANGED_SUB[row.sub] and true or false
        local dstRanged = RANGED_SUB[eq.sub] and true or false
        return srcRanged == dstRanged
    end

    if eq.cls == 4 then -- armor: mixed types allowed, so only slot shape matters
        if row.inv == eq.inv then return true end
        if (row.inv == 5 or row.inv == 20) and (eq.inv == 5 or eq.inv == 20) then return true end
        if IsOffhandArmor(row.sub, row.inv) and IsOffhandArmor(eq.sub, eq.inv) then return true end
        return false
    end

    return false
end

-- =====================================================================
-- Filtering
-- =====================================================================
local function PassesFilters(row)
    if query ~= "" and not row.lname:find(query, 1, true) then return false end
    if filterQuality and row.q ~= filterQuality then return false end
    if filterSub and row.sub ~= filterSub then return false end

    if filterOwned == "collected" then
        if not collection[row.disp] then return false end
    elseif filterOwned == "missing" then
        if collection[row.disp] then return false end
    elseif filterOwned == "favorites" then
        if not favorites[row.disp] then return false end
    end

    return true
end

local function Rebuild()
    wipe(results)

    local def = SLOT_BY_ID[currentSlot]
    local eq = equipment[currentSlot]
    if not def then return end

    local seen = {}
    for _, invType in ipairs(def.pool) do
        for _, row in ipairs(ParsedRows(invType)) do
            if not seen[row.disp] and IsEligible(row, eq) and PassesFilters(row) then
                seen[row.disp] = true
                results[#results + 1] = row
            end
        end
    end

    -- Collected first, then favourites, then quality, then name: the looks you
    -- can actually use right now belong at the top.
    table.sort(results, function(a, b)
        local ca, cb = collection[a.disp] and 1 or 0, collection[b.disp] and 1 or 0
        if ca ~= cb then return ca > cb end
        local fa, fb = favorites[a.disp] and 1 or 0, favorites[b.disp] and 1 or 0
        if fa ~= fb then return fa > fb end
        if a.q ~= b.q then return a.q > b.q end
        return a.name < b.name
    end)
end

-- =====================================================================
-- 3D preview
-- =====================================================================
-- SetUnit resets camera and facing, so the framing has to be re-applied after
-- every one or the model snaps back to its default off-centre pose.
local function ApplyModelFraming()
    if modelFrame.SetPosition then modelFrame:SetPosition(modelFrame.zoom or 0, 0, -0.15) end
    if modelFrame.SetRotation then modelFrame:SetRotation(modelFrame.rotation or 0.35) end
end

-- Put the model back in the character's real, currently-worn gear.
local function ResetModel()
    if not modelFrame then return end
    modelFrame:SetUnit("player")
    ApplyModelFraming()
    previewEntry = nil
end

-- Show one appearance on the model.
--
-- Deliberately NO SetUnit here. Every appearance in a slot tab targets the SAME
-- equipment slot, so TryOn replaces that slot rather than stacking onto it --
-- there is nothing to reset between previews.
--
-- Calling SetUnit first was actively wrong: it reloads the entire model, which
-- is ASYNCHRONOUS, so the TryOn issued immediately afterwards was discarded
-- when the reload completed. The model just snapped back to the player's real
-- gear and hovering looked like it did nothing at all.
local function PreviewItem(entry)
    if not modelFrame or not entry then return end
    if previewEntry == entry then return end
    modelFrame:TryOn(entry)
    previewEntry = entry
end

-- =====================================================================
-- Cells
-- =====================================================================
local pendingIcons = false
local scanTip = CreateFrame("GameTooltip", "UncappedTransmogScanTip", nil, "GameTooltipTemplate")
scanTip:SetOwner(UIParent, "ANCHOR_NONE")

-- GetItemIcon reads the client's own item DBC and answers for items the
-- player has never seen; GetItemInfo only answers for cached items. Try the
-- cheap path first, then the cache, then nudge the cache and show a
-- placeholder until it fills in.
local iconQueried = {}

local function IconFor(entry)
    if GetItemIcon then
        local tex = GetItemIcon(entry)
        if tex then return tex end
    end

    local tex = select(10, GetItemInfo(entry))
    if tex then return tex end

    -- Ask the server for this item exactly once. Without the guard, every
    -- repaint of a grid of uncached items would fire a fresh query storm.
    if not iconQueried[entry] then
        iconQueried[entry] = true
        scanTip:SetHyperlink("item:" .. entry)
    end
    pendingIcons = true
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function PaintCell(cell, row)
    cell.row = row

    if not row then
        cell:Hide()
        return
    end

    cell:Show()
    cell.icon:SetTexture(IconFor(row.entry))

    local owned = collection[row.disp]
    if owned then
        cell.icon:SetDesaturated(false)
        cell.icon:SetAlpha(1)
    else
        -- Uncollected looks stay visible but drained, so the grid reads as a
        -- checklist rather than hiding what you are hunting for.
        cell.icon:SetDesaturated(true)
        cell.icon:SetAlpha(0.45)
    end

    local col = QCOLOR[row.q]
    if col then
        cell.border:SetVertexColor(col.r, col.g, col.b, owned and 1 or 0.35)
        cell.border:Show()
    else
        cell.border:Hide()
    end

    if favorites[row.disp] then cell.star:Show() else cell.star:Hide() end

    if equipment[currentSlot] and equipment[currentSlot].fakeDisp == row.disp then
        cell.active:Show()
    else
        cell.active:Hide()
    end

    if selected and selected.disp == row.disp then
        cell.selection:Show()
    else
        cell.selection:Hide()
    end
end

local function RefreshGrid()
    if not frame or not frame:IsShown() then return end

    local offset = FauxScrollFrame_GetOffset(scroll) or 0
    local rows = math.ceil(#results / COLS)

    FauxScrollFrame_Update(scroll, rows, ROWS, CELL_STEP)

    for i = 1, COLS * ROWS do
        local index = offset * COLS + i
        PaintCell(cells[i], results[index])
    end

    if countText then
        local eq = equipment[currentSlot]
        if not eq or eq.entry == 0 then
            -- An empty slot has nothing to transmogrify, and a silently blank
            -- grid reads as a broken addon.
            countText:SetText("|cffff5555Nothing equipped in this slot|r")
        elseif #results == 0 then
            countText:SetText("|cff808080No appearances match these filters|r")
        else
            local owned = 0
            for i = 1, #results do
                if collection[results[i].disp] then owned = owned + 1 end
            end
            countText:SetText(string.format("|cffffd100%d|r / |cffffffff%d|r collected", owned, #results))
        end
    end
end

local function Refresh()
    Rebuild()
    RefreshGrid()
end

-- =====================================================================
-- Tooltip
-- =====================================================================
local function ShowCellTooltip(cell)
    local row = cell.row
    if not row then return end

    GameTooltip:SetOwner(cell, "ANCHOR_RIGHT")

    local col = QCOLOR[row.q] or QCOLOR[1]
    GameTooltip:SetText(row.name, col.r, col.g, col.b)

    local subName = (row.cls == 2 and WEAPON_SUB_NAME[row.sub]) or (row.cls == 4 and ARMOR_SUB_NAME[row.sub])
    if subName then
        GameTooltip:AddLine(subName, 0.8, 0.8, 0.8)
    end
    if row.ilvl and row.ilvl > 0 then
        GameTooltip:AddLine("Item Level " .. row.ilvl, 0.8, 0.8, 0.8)
    end

    GameTooltip:AddLine(" ")
    if collection[row.disp] then
        GameTooltip:AddLine("Collected", 0.1, 1, 0.1)
        GameTooltip:AddLine("Click to wear this appearance.", 0.5, 0.5, 0.5)
    else
        GameTooltip:AddLine("Not collected", 1, 0.3, 0.3)
        GameTooltip:AddLine("Click to see where it comes from.", 0.5, 0.5, 0.5)
    end
    GameTooltip:AddLine("Right-click to favourite.", 0.5, 0.5, 0.5)

    GameTooltip:Show()
end

-- =====================================================================
-- Actions
-- =====================================================================
local function SelectRow(row)
    selected = row
    PreviewItem(row.entry)

    -- Source lookup is throttled server-side, so ask only on an explicit
    -- selection -- never on hover.
    if sourceFor ~= row.disp then
        sourceFor = row.disp
        wipe(sourceLines)
        if sourceText then sourceText:SetText("|cff808080Looking up sources...|r") end
        Send("TMSRC:" .. row.disp)
    end

    RefreshGrid()
end

local function ApplySelected()
    if not selected then return end

    if not collection[selected.disp] then
        DEFAULT_CHAT_FRAME:AddMessage("|cff9d4edd[Transmog]|r you haven't collected that appearance yet.")
        return
    end

    Send(string.format("TMAPPLY:%d:%d", currentSlot, selected.disp))
end

local function ClearSlot()
    Send(string.format("TMAPPLY:%d:0", currentSlot))
end

local function HideSlot()
    Send(string.format("TMAPPLY:%d:%d", currentSlot, HIDDEN_DISPLAY))
end

local function ToggleFavorite(row)
    if not row then return end
    local on = not favorites[row.disp]
    favorites[row.disp] = on or nil
    Send(string.format("TMFAV:%d:%d", row.disp, on and 1 or 0))
    RefreshGrid()
end

-- Rebuild the subclass dropdown for the current slot, listing only the
-- subclasses that actually occur among this slot's eligible appearances.
local function RebuildSubFilter()
    if not subDD then return end

    local def = SLOT_BY_ID[currentSlot]
    local eq = equipment[currentSlot]

    local present = {}
    if def then
        for _, invType in ipairs(def.pool) do
            for _, row in ipairs(ParsedRows(invType)) do
                if IsEligible(row, eq) then present[row.sub] = true end
            end
        end
    end

    local names = (eq and eq.cls == 2) and WEAPON_SUB_NAME or ARMOR_SUB_NAME
    local choices = { { value = nil, text = "Any type" } }
    for sub in pairs(present) do
        if names[sub] then choices[#choices + 1] = { value = sub, text = names[sub] } end
    end
    table.sort(choices, function(a, b)
        if a.value == nil then return true end
        if b.value == nil then return false end
        return a.text < b.text
    end)

    UIDropDownMenu_Initialize(subDD, function()
        for _, choice in ipairs(choices) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = choice.text
            info.func = function()
                filterSub = choice.value
                UIDropDownMenu_SetText(subDD, choice.text)
                ResetScroll()
                Refresh()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetText(subDD, "Any type")
end

local function SelectSlot(slotId)
    currentSlot = slotId
    selected = nil
    sourceFor = nil
    filterSub = nil
    wipe(sourceLines)
    if sourceText then sourceText:SetText("") end

    for _, btn in ipairs(slotButtons) do
        if btn.slotId == slotId then
            btn:SetChecked(true)
        else
            btn:SetChecked(false)
        end
    end

    ResetScroll()
    RebuildSubFilter()
    ResetModel()
    Refresh()
end

-- =====================================================================
-- Frame construction
-- =====================================================================
-- Lives inside the Dashboard's content panel (see EmbedInto below) -- no own
-- backdrop/title/close/drag, since the Dashboard's master window already
-- provides all of that chrome. Internal layout keeps the fixed-pixel sizing
-- the standalone window used (grid/model/dropdowns all anchor off each other
-- or off frame's own edges) -- frame now fills whatever space the embedded
-- group gives it instead of being SetWidth/SetHeight to a fixed W/H.
local function BuildFrame(parent)
    if frame then return end

    local gridW = COLS * CELL_STEP - CELL_GAP

    frame = CreateFrame("Frame", "UncappedTransmogFrame", parent or UIParent)
    frame:SetPoint("TOPLEFT"); frame:SetPoint("BOTTOMRIGHT")
    frame:EnableMouse(true)
    frame:Hide()

    -- Icons resolve asynchronously for items the client has never cached;
    -- repaint until they have all landed.
    frame:SetScript("OnUpdate", function(self, dt)
        self._t = (self._t or 0) + dt
        if self._t < 0.2 then return end
        self._t = 0
        if pendingIcons then
            pendingIcons = false
            RefreshGrid()
        end
    end)

    -- Still fires correctly under the Dashboard's embedding: a frame's own
    -- OnShow/OnHide react to effective (parent-chain) visibility, not just
    -- its own Show/Hide calls, so this still tracks the Transmog tab being
    -- switched to/away from even though EmbedInto only calls frame:Show()
    -- once and the Dashboard's tab group is what actually shows/hides it.
    frame:SetScript("OnShow", function() Send("TMWIN:1") end)
    frame:SetScript("OnHide", function() Send("TMWIN:0") end)

    -- ---- slot tabs (left edge of the preview) --------------------------
    local firstTab
    for i, def in ipairs(SLOTS) do
        local btn = CreateFrame("CheckButton", "UncappedTransmogSlot" .. def.slot, frame)
        btn:SetWidth(TAB); btn:SetHeight(TAB)
        btn.slotId = def.slot

        if i == 1 then
            btn:SetPoint("TOPLEFT", PAD, -HEADER)
            firstTab = btn
        else
            btn:SetPoint("TOPLEFT", slotButtons[i - 1], "BOTTOMLEFT", 0, -(TAB_STEP - TAB))
        end

        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
        icon:SetTexture(def.icon)
        btn.iconTex = icon

        btn:SetCheckedTexture("Interface\\Buttons\\CheckButtonHilight")
        btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")

        btn:SetScript("OnClick", function(self)
            SelectSlot(self.slotId)
        end)
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(def.label)
            local eq = equipment[self.slotId]
            if not eq or eq.entry == 0 then
                GameTooltip:AddLine("Nothing equipped in this slot.", 1, 0.3, 0.3)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        slotButtons[i] = btn
    end

    -- ---- 3D preview ----------------------------------------------------
    modelFrame = CreateFrame("DressUpModel", "UncappedTransmogModel", frame)
    modelFrame:SetPoint("TOPLEFT", firstTab, "TOPRIGHT", 8, 0)
    modelFrame:SetWidth(PREVIEW_W)
    modelFrame:SetHeight(ROWS * CELL_STEP + 60)
    modelFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    modelFrame:SetUnit("player")
    modelFrame:EnableMouse(true)
    modelFrame:EnableMouseWheel(true)

    -- Explicit framing. Left to its own devices the model sits off-centre and
    -- oddly cropped; this squares it up and turns the character slightly so the
    -- silhouette reads, the way the dressing room does.
    if modelFrame.SetPosition then modelFrame:SetPosition(0, 0, -0.15) end
    if modelFrame.SetRotation then modelFrame:SetRotation(0.35) end

    -- Drag to spin, wheel to zoom. Both guarded: Model methods vary between
    -- 3.3.5a builds and a missing one would otherwise error every frame.
    modelFrame.rotation = 0.35
    modelFrame:SetScript("OnMouseDown", function(self)
        self.dragging = true
        self.lastX = GetCursorPosition()
    end)
    modelFrame:SetScript("OnMouseUp", function(self) self.dragging = false end)
    modelFrame:SetScript("OnUpdate", function(self)
        if not self.dragging then return end
        local x = GetCursorPosition()
        local dx = x - (self.lastX or x)
        self.lastX = x
        if dx ~= 0 and self.SetRotation then
            self.rotation = self.rotation + dx * 0.02
            self:SetRotation(self.rotation)
        end
    end)
    modelFrame:SetScript("OnMouseWheel", function(self, delta)
        if not self.SetPosition then return end
        self.zoom = math.max(-1.5, math.min(2.5, (self.zoom or 0) + delta * 0.25))
        self:SetPosition(self.zoom, 0, -0.15)
    end)

    -- ---- action buttons under the preview ------------------------------
    local applyBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    applyBtn:SetWidth(74); applyBtn:SetHeight(22)
    applyBtn:SetPoint("TOPLEFT", modelFrame, "BOTTOMLEFT", 0, -6)
    applyBtn:SetText("Wear")
    applyBtn:SetScript("OnClick", ApplySelected)

    local hideBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    hideBtn:SetWidth(74); hideBtn:SetHeight(22)
    hideBtn:SetPoint("LEFT", applyBtn, "RIGHT", 4, 0)
    hideBtn:SetText("Hide slot")
    hideBtn:SetScript("OnClick", HideSlot)

    local clearBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    clearBtn:SetWidth(74); clearBtn:SetHeight(22)
    clearBtn:SetPoint("LEFT", hideBtn, "RIGHT", 4, 0)
    clearBtn:SetText("Reset")
    clearBtn:SetScript("OnClick", ClearSlot)

    -- ---- search + filters ----------------------------------------------
    local search = CreateFrame("EditBox", "UncappedTransmogSearch", frame, "InputBoxTemplate")
    search:SetPoint("TOPLEFT", modelFrame, "TOPRIGHT", 22, 0)
    search:SetWidth(200); search:SetHeight(20)
    search:SetAutoFocus(false)
    local ph = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ph:SetPoint("LEFT", 4, 0)
    ph:SetText("Search appearances...")
    search:SetScript("OnTextChanged", function(self)
        query = (self:GetText() or ""):lower()
        if query == "" then ph:Show() else ph:Hide() end
        ResetScroll()
        Refresh()
    end)
    search:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)

    local ownedDD = CreateFrame("Frame", "UncappedTransmogOwnedDD", frame, "UIDropDownMenuTemplate")
    ownedDD:SetPoint("TOPLEFT", search, "BOTTOMLEFT", -20, -6)
    local OWNED_CHOICES = {
        { value = "all",        text = "All appearances" },
        { value = "collected",  text = "Collected" },
        { value = "missing",    text = "Not collected" },
        { value = "favorites",  text = "Favourites" },
    }
    UIDropDownMenu_SetWidth(ownedDD, 108)
    UIDropDownMenu_Initialize(ownedDD, function()
        for _, choice in ipairs(OWNED_CHOICES) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = choice.text
            info.func = function()
                filterOwned = choice.value
                UIDropDownMenu_SetText(ownedDD, choice.text)
                FauxScrollFrame_SetOffset(scroll, 0)
                Refresh()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetText(ownedDD, "All appearances")

    local qualityDD = CreateFrame("Frame", "UncappedTransmogQualityDD", frame, "UIDropDownMenuTemplate")
    qualityDD:SetPoint("LEFT", ownedDD, "RIGHT", -12, 0)
    local QUALITY_CHOICES = {
        { value = nil, text = "Any quality" },
        { value = 7,   text = "Heirloom" },
        { value = 6,   text = "Artifact" },
        { value = 5,   text = "Legendary" },
        { value = 4,   text = "Epic" },
        { value = 3,   text = "Rare" },
        { value = 2,   text = "Uncommon" },
        { value = 1,   text = "Common" },
        { value = 0,   text = "Poor" },
    }
    UIDropDownMenu_SetWidth(qualityDD, 86)
    UIDropDownMenu_Initialize(qualityDD, function()
        for _, choice in ipairs(QUALITY_CHOICES) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = choice.text
            info.func = function()
                filterQuality = choice.value
                UIDropDownMenu_SetText(qualityDD, choice.text)
                ResetScroll()
                Refresh()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetText(qualityDD, "Any quality")

    -- Subclass filter. Its contents depend on the slot: armour slots list
    -- cloth/leather/mail/plate, weapon slots list sword/axe/staff/... There is
    -- no useful single list, so it is rebuilt whenever the slot changes.
    subDD = CreateFrame("Frame", "UncappedTransmogSubDD", frame, "UIDropDownMenuTemplate")
    subDD:SetPoint("LEFT", qualityDD, "RIGHT", -12, 0)
    UIDropDownMenu_SetWidth(subDD, 100)

    countText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    countText:SetPoint("RIGHT", frame, "TOPRIGHT", -PAD - SCROLLBAR, -HEADER - 10)
    countText:SetJustifyH("RIGHT")

    -- ---- grid ----------------------------------------------------------
    -- Anchored off the model rather than off a dropdown, so the grid's left
    -- edge does not drift when a dropdown's width changes.
    grid = CreateFrame("Frame", nil, frame)
    grid:SetPoint("TOPLEFT", modelFrame, "TOPRIGHT", 22, -56)
    grid:SetWidth(gridW)
    grid:SetHeight(ROWS * CELL_STEP)

    scroll = CreateFrame("ScrollFrame", "UncappedTransmogScroll", grid, "FauxScrollFrameTemplate")
    scroll:SetAllPoints()
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, CELL_STEP, RefreshGrid)
    end)

    for i = 1, COLS * ROWS do
        local cell = CreateFrame("Button", "UncappedTransmogCell" .. i, grid)
        cell:SetWidth(CELL); cell:SetHeight(CELL)

        local col = (i - 1) % COLS
        local row = math.floor((i - 1) / COLS)
        cell:SetPoint("TOPLEFT", col * CELL_STEP, -row * CELL_STEP)

        cell.icon = cell:CreateTexture(nil, "ARTWORK")
        cell.icon:SetPoint("TOPLEFT", 2, -2)
        cell.icon:SetPoint("BOTTOMRIGHT", -2, 2)
        cell.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

        cell.border = cell:CreateTexture(nil, "OVERLAY")
        cell.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        cell.border:SetBlendMode("ADD")
        cell.border:SetPoint("CENTER")
        cell.border:SetWidth(CELL * 1.6); cell.border:SetHeight(CELL * 1.6)

        cell.selection = cell:CreateTexture(nil, "OVERLAY")
        cell.selection:SetTexture("Interface\\Buttons\\CheckButtonHilight")
        cell.selection:SetBlendMode("ADD")
        cell.selection:SetAllPoints()
        cell.selection:Hide()

        -- Marks the appearance currently worn in this slot.
        cell.active = cell:CreateTexture(nil, "OVERLAY")
        cell.active:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        cell.active:SetVertexColor(0.2, 1, 0.2)
        cell.active:SetBlendMode("ADD")
        cell.active:SetPoint("CENTER")
        cell.active:SetWidth(CELL * 1.6); cell.active:SetHeight(CELL * 1.6)
        cell.active:Hide()

        cell.star = cell:CreateTexture(nil, "OVERLAY")
        cell.star:SetTexture("Interface\\Common\\ReputationStar")
        cell.star:SetTexCoord(0, 0.5, 0, 0.5)
        cell.star:SetWidth(14); cell.star:SetHeight(14)
        cell.star:SetPoint("TOPLEFT", 0, 0)
        cell.star:Hide()

        cell:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
        cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        cell:SetScript("OnClick", function(self, button)
            if not self.row then return end
            if button == "RightButton" then
                ToggleFavorite(self.row)
            else
                SelectRow(self.row)
            end
        end)
        cell:SetScript("OnDoubleClick", function(self)
            if self.row and collection[self.row.disp] then
                SelectRow(self.row)
                ApplySelected()
            end
        end)
        cell:SetScript("OnEnter", function(self)
            ShowCellTooltip(self)
            -- Hover previews the look without asking the server anything.
            if self.row then PreviewItem(self.row.entry) end
        end)
        cell:SetScript("OnLeave", function()
            GameTooltip:Hide()
            -- Fall back to the selected look, but do NOT reset to real gear
            -- otherwise: sweeping the cursor off a cell would reload the whole
            -- model, and the wardrobe is meant to hold the last thing you
            -- looked at, the way the retail one does.
            if selected then PreviewItem(selected.entry) end
        end)

        cells[i] = cell
    end

    -- ---- source panel --------------------------------------------------
    sourceText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sourceText:SetPoint("TOPLEFT", grid, "BOTTOMLEFT", 0, -10)
    sourceText:SetPoint("RIGHT", frame, "RIGHT", -PAD - SCROLLBAR, 0)
    sourceText:SetJustifyH("LEFT")
    sourceText:SetJustifyV("TOP")
    sourceText:SetHeight(60)
    sourceText:SetText("")

    local outfitsBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    outfitsBtn:SetWidth(90); outfitsBtn:SetHeight(22)
    -- Bottom RIGHT, not bottom left: the slot-tab column runs the full height of
    -- the left edge and a button there sits on top of the last tab.
    outfitsBtn:SetPoint("BOTTOMRIGHT", -PAD - SCROLLBAR, PAD - 4)
    outfitsBtn:SetText("Outfits")
    outfitsBtn:SetScript("OnClick", function()
        Send("TMSETS")
        if UncappedTransmogOutfits then UncappedTransmogOutfits() end
    end)
end

-- =====================================================================
-- Outfits window
-- =====================================================================
local outfitFrame

function UncappedTransmogOutfits()
    if not outfitFrame then
        outfitFrame = CreateFrame("Frame", "UncappedTransmogOutfitFrame", UIParent)
        outfitFrame:SetWidth(280); outfitFrame:SetHeight(320)
        outfitFrame:SetPoint("CENTER", 340, 0)
        outfitFrame:SetFrameStrata("DIALOG")
        outfitFrame:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
        outfitFrame:EnableMouse(true)
        outfitFrame:SetMovable(true)
        outfitFrame:RegisterForDrag("LeftButton")
        outfitFrame:SetScript("OnDragStart", outfitFrame.StartMoving)
        outfitFrame:SetScript("OnDragStop", outfitFrame.StopMovingOrSizing)
        tinsert(UISpecialFrames, "UncappedTransmogOutfitFrame")

        local title = outfitFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", 0, -16)
        title:SetText("Saved Outfits")

        local close = CreateFrame("Button", nil, outfitFrame, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -6, -6)

        outfitFrame.rows = {}
        for i = 1, 10 do
            local row = CreateFrame("Frame", nil, outfitFrame)
            row:SetPoint("TOPLEFT", 18, -40 - (i - 1) * 24)
            row:SetWidth(244); row:SetHeight(22)

            local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            label:SetPoint("LEFT", 2, 0)
            label:SetWidth(120)
            label:SetJustifyH("LEFT")
            row.label = label

            local use = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            use:SetWidth(52); use:SetHeight(20)
            use:SetPoint("RIGHT", -58, 0)
            use:SetText("Wear")
            row.use = use

            local del = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            del:SetWidth(52); del:SetHeight(20)
            del:SetPoint("RIGHT", -2, 0)
            del:SetText("Delete")
            row.del = del

            outfitFrame.rows[i] = row
        end

        local nameBox = CreateFrame("EditBox", "UncappedTransmogOutfitName", outfitFrame, "InputBoxTemplate")
        nameBox:SetPoint("BOTTOMLEFT", 22, 44)
        nameBox:SetWidth(150); nameBox:SetHeight(20)
        nameBox:SetAutoFocus(false)
        nameBox:SetMaxLetters(40)
        outfitFrame.nameBox = nameBox

        local saveBtn = CreateFrame("Button", nil, outfitFrame, "UIPanelButtonTemplate")
        saveBtn:SetWidth(80); saveBtn:SetHeight(22)
        saveBtn:SetPoint("LEFT", nameBox, "RIGHT", 8, 0)
        saveBtn:SetText("Save current")
        saveBtn:SetScript("OnClick", function()
            local name = nameBox:GetText()
            if not name or name == "" then
                DEFAULT_CHAT_FRAME:AddMessage("|cff9d4edd[Transmog]|r name the outfit first.")
                return
            end
            Send("TMSETSAVE:" .. name)
            nameBox:SetText("")
        end)

        local hint = outfitFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hint:SetPoint("BOTTOM", 0, 22)
        hint:SetText("Saves whatever you are currently transmogrified into.")
    end

    for i, row in ipairs(outfitFrame.rows) do
        local outfit = outfits[i - 1]
        if outfit then
            row.label:SetText(outfit.name)
            row.use:SetScript("OnClick", function() Send("TMSETUSE:" .. (i - 1)) end)
            row.del:SetScript("OnClick", function() Send("TMSETDEL:" .. (i - 1)) end)
            row:Show()
        else
            row:Hide()
        end
    end

    outfitFrame:Show()
end

-- =====================================================================
-- Dashboard embedding
-- =====================================================================
-- The Dashboard hosts this panel directly inside its own window instead of
-- Transmog owning a window of its own -- see UncappedDashboard_UI.lua,
-- which calls EmbedInto once (to build the frame into its content group)
-- and Activate every time the Transmog tab is selected. The Outfits popup
-- stays a separate floating window -- it's triggered by clicking the
-- "Outfits" button, not "the Transmog screen" itself.
local Transmog = _G.UncappedTransmog or {}
_G.UncappedTransmog = Transmog
Transmog.UI = {}

function Transmog.UI.EmbedInto(parent)
    BuildFrame(parent)
    frame:Show()
    return frame
end

function Transmog.UI.Activate()
    if not frame then return end
    -- Cheap when nothing changed: the server answers a matching count with a
    -- single line and sends no payload.
    Send("TMSYNC:" .. collCount)
    Send("TMEQ")
    Send("TMSETS")
    SelectSlot(currentSlot)
end

-- Content-panel width (not window width) Transmog needs: PAD + slot-tab
-- column + 3D preview + grid + scrollbar reserve + PAD (802, the original
-- standalone window's own width formula) plus the embedded group's own 6px
-- padding on each side = 814.
function Transmog.UI.GetMinWidth()
    return 814
end

-- Full window height (not content height) Transmog needs: tall enough for
-- all 14 slot tabs to clear the action-button row (554, the original
-- standalone window's own height formula) plus the Dashboard window's own
-- chrome (title/banner + margins) that a standalone window didn't have to
-- account for, ~72px.
function Transmog.UI.GetMinHeight()
    return 626
end

-- Switches the Dashboard to the Transmog tab, opening it if it's closed.
-- Used by the server-initiated TMOPEN request and the settings-page button --
-- Transmog has no window of its own anymore to open directly.
local function OpenInDashboard()
    local Dashboard = _G.UncappedDashboard
    if not Dashboard then
        DEFAULT_CHAT_FRAME:AddMessage("|cff9d4edd[Transmog]|r now lives inside the Dashboard -- load UncappedDashboard to use it.")
        return
    end
    Dashboard.SetTab("transmog")
    if not (Dashboard.UI and Dashboard.UI.IsShown and Dashboard.UI.IsShown()) then
        Dashboard.Toggle()
    end
end

-- =====================================================================
-- Comms handler
-- =====================================================================
local comms = CreateFrame("Frame")
comms:RegisterEvent("CHAT_MSG_ADDON")
comms:SetScript("OnEvent", function(_, _, prefix, text)
    if prefix ~= ADDON_PIPE_PREFIX or not text then return end
    if text:sub(1, 2) ~= "TM" then return end

    if text:find("^TMOPEN") then
        OpenInDashboard()

    elseif text:find("^TMHI:") then
        local _, sets, maxN = text:match("^TMHI:(%d+):(%d+):(%d+)")
        if maxN then maxSets = tonumber(maxN) end

    elseif text:find("^TMPK:") then
        local seq, chunk = text:match("^TMPK:(%d+):(.*)$")
        if seq then
            if tonumber(seq) == 0 then wipe(packBuffers.TMPK) end
            table.insert(packBuffers.TMPK, chunk)
        end

    elseif text:find("^TMPKEND:") then
        local encoded = table.concat(packBuffers.TMPK)
        wipe(packBuffers.TMPK)
        local values = DecodePacked(encoded)
        ApplyCollection(values)
        UncappedTransmogDB.collection = encoded
        UncappedTransmogDB.collectionCount = collCount
        Refresh()

    elseif text:find("^TMSYNCOK:") then
        -- Cached collection is current; nothing to do.

    elseif text:find("^TMNEW:") then
        local disp = tonumber(text:match("^TMNEW:(%d+)"))
        if disp and not collection[disp] then
            collection[disp] = true
            collCount = collCount + 1
            -- The cached blob is now stale. Drop it so the next open resyncs
            -- rather than trusting a count that no longer matches its payload.
            UncappedTransmogDB.collection = nil
            UncappedTransmogDB.collectionCount = nil
            Refresh()
        end

    elseif text:find("^TMFAVPK:") then
        local seq, chunk = text:match("^TMFAVPK:(%d+):(.*)$")
        if seq then
            if tonumber(seq) == 0 then wipe(packBuffers.TMFAVPK) end
            table.insert(packBuffers.TMFAVPK, chunk)
        end

    elseif text:find("^TMFAVPKEND:") then
        local values = DecodePacked(table.concat(packBuffers.TMFAVPK))
        wipe(packBuffers.TMFAVPK)
        wipe(favorites)
        for i = 1, #values do favorites[values[i]] = true end
        RefreshGrid()

    elseif text:find("^TMEQ:") then
        local slot, entry, disp, fakeEntry, fakeDisp, cls, sub, inv =
            text:match("^TMEQ:(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)$")
        if slot then
            equipment[tonumber(slot)] = {
                entry = tonumber(entry), disp = tonumber(disp),
                fakeEntry = tonumber(fakeEntry), fakeDisp = tonumber(fakeDisp),
                cls = tonumber(cls), sub = tonumber(sub), inv = tonumber(inv),
            }
        end

    elseif text:find("^TMEQEND") then
        -- Eligibility and the subclass list both depend on what is equipped,
        -- and the window is opened before this snapshot lands.
        if frame and frame:IsShown() then
            RebuildSubFilter()
            Refresh()
        end

    elseif text:find("^TMR:") then
        local slot, disp, ok = text:match("^TMR:(%d+):(%d+):(%d+)")
        if ok == "1" then
            PlaySound("igCharacterInfoTab")
        end

    elseif text:find("^TMSET:") then
        -- Outfits stream as a fresh full list each time. Staging, then swapping
        -- at the terminator, is what makes a delete actually disappear -- writing
        -- straight into `outfits` would only ever add.
        if outfitBatchDone then wipe(outfitStaging); outfitBatchDone = false end
        local id, name = text:match("^TMSET:(%d+):(.*)$")
        if id then
            outfitStaging[tonumber(id)] = { name = name, items = {} }
        end

    elseif text:find("^TMSETI:") then
        local id, slot, entry, disp = text:match("^TMSETI:(%d+):(%d+):(%d+):(%d+)$")
        if id and outfitStaging[tonumber(id)] then
            outfitStaging[tonumber(id)].items[tonumber(slot)] = { entry = tonumber(entry), disp = tonumber(disp) }
        end

    elseif text:find("^TMSETEND:") then
        local _, maxN = text:match("^TMSETEND:(%d+):(%d+)")
        if maxN then maxSets = tonumber(maxN) end

        wipe(outfits)
        for id, outfit in pairs(outfitStaging) do outfits[id] = outfit end
        wipe(outfitStaging)
        outfitBatchDone = true

        if outfitFrame and outfitFrame:IsShown() then UncappedTransmogOutfits() end

    elseif text:find("^TMSRC:") then
        local disp, kind, chance, spawns, dungeon, rest =
            text:match("^TMSRC:(%d+):(%d+):(%d+):(%d+):(%d+):(.*)$")
        if disp and tonumber(disp) == sourceFor then
            local name, zone = rest:match("^([^|]*)|([^|]*)|")
            local verb = SOURCE_KIND[tonumber(kind)] or "From"
            local pct = tonumber(chance) / 10
            local line = string.format("|cffffd100%s|r %s", verb, name or "?")
            if zone and zone ~= "" then line = line .. string.format(" |cff808080(%s)|r", zone) end
            if pct > 0 then line = line .. string.format(" |cff40c0ff%.1f%%|r", pct) end
            if dungeon == "1" then line = line .. " |cffa335ee[Dungeon]|r" end
            sourceLines[#sourceLines + 1] = line
        end

    elseif text:find("^TMSRCEND:") then
        local disp, count = text:match("^TMSRCEND:(%d+):(%d+)")
        if disp and tonumber(disp) == sourceFor and sourceText then
            if #sourceLines == 0 then
                sourceText:SetText("|cff808080No known source -- this look may come from a vendor, a quest, or an old world event.|r")
            else
                -- Only the first few fit the panel.
                local shown = {}
                for i = 1, math.min(3, #sourceLines) do shown[i] = sourceLines[i] end
                sourceText:SetText(table.concat(shown, "\n"))
            end
        end
    end
end)

-- =====================================================================
-- Init
-- =====================================================================
local init = CreateFrame("Frame")
init:RegisterEvent("PLAYER_LOGIN")
init:SetScript("OnEvent", function()
    UncappedTransmogDB = UncappedTransmogDB or {}

    -- Restore the cached collection before saying hello, so a window opened
    -- immediately has something to draw and the sync becomes a no-op.
    if UncappedTransmogDB.collection then
        local values = DecodePacked(UncappedTransmogDB.collection)
        ApplyCollection(values)
    end

    Send("TMHELLO")
    Send("TMFAVGET")

    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff9d4edd[Transmog]|r type |cffffd100/dashboard|r to open your appearance collection.")
end)

-- No standalone /transmog command: this window is a Dashboard tab now, opened via
-- /dashboard, so a dedicated slash command would just duplicate that entry point.

-- =====================================================================
-- Settings hub panel
-- =====================================================================
if UncappedUI then
    local panel, L = UncappedUI.CreatePanel("Transmog",
        "The appearance collection: browse every look in the game, preview it in 3D, and see where it drops.")

    L:Header("Collection")
    L:Note("Appearances unlock account-wide as you loot, equip, disenchant and forge gear.", 30)
    L:Button("Open the collection", function() OpenInDashboard() end, 160)
    L:Button("Resync collection", function()
        -- Forces a full resend by claiming an impossible count.
        UncappedTransmogDB.collection = nil
        UncappedTransmogDB.collectionCount = nil
        Send("TMSYNC:4294967295")
    end, 160)

    UncappedTransmogPanel = panel
end
