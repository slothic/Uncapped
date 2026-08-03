-- UncappedVault -- core vault state and server transport.
-- Derived from UncappedVault's live VLT* protocol, bag hooks, demo data shape,
-- item-cache warming, and withdraw/deposit behaviour.

local ADDON_PIPE_PREFIX = "UNC"
local TRANSPORT_PREFIX = "REAGENTBANK"
local FORCE_LIVE = true
local ADDON = "UncappedVault"
local CACHE_VERSION = 1
local RECACHE_INTERVAL = 300

local floor, min, max = math.floor, math.min, math.max
local format, lower, find, match, gmatch = string.format, string.lower, string.find, string.match, string.gmatch
local tinsert, tremove, sort = table.insert, table.remove, table.sort

local Core = _G.UncappedVault or {}
_G.UncappedVault = Core

Core.version = "0.0.1"
Core.ADDON = ADDON
Core.callbacks = Core.callbacks or {}

local function RealmIsDev()
    local r = GetRealmName and GetRealmName()
    return r and find(lower(r), "dev", 1, true) ~= nil
end

Core.demo = not (FORCE_LIVE or RealmIsDev())

local DEMO_ITEMS = {
    { e = 49623, q = 5, c = 1,   n = "Shadowmourne",                         i = "Interface\\Icons\\INV_Axe_113", cls = 2,  sub = 1,  ilvl = 80 },
    { e = 33470, q = 3, c = 200, n = "Frostweave Cloth",                     i = "Interface\\Icons\\INV_Fabric_Frostweave", cls = 7, sub = 5, ilvl = 1 },
    { e = 36910, q = 2, c = 150, n = "Titanium Ore",                         i = "Interface\\Icons\\INV_Ore_Titanium_01", cls = 7, sub = 7, ilvl = 1 },
    { e = 40211, q = 1, c = 20,  n = "Potion of Speed",                      i = "Interface\\Icons\\INV_Potion_108", cls = 0, sub = 1, ilvl = 1 },
    { e = 34057, q = 4, c = 5,   n = "Abyss Crystal",                        i = "Interface\\Icons\\INV_Enchant_VoidCrystal", cls = 7, sub = 12, ilvl = 1 },
    { e = 40905, q = 4, c = 1,   n = "Relentless Gladiator's Plate Chestpiece", i = "Interface\\Icons\\INV_Chest_Plate_25", cls = 4, sub = 4, ilvl = 80 },
    { e = 33568, q = 2, c = 80,  n = "Heavy Borean Leather",                 i = "Interface\\Icons\\INV_Misc_LeatherScrap_08", cls = 7, sub = 6, ilvl = 1 },
    { e = 22449, q = 3, c = 12,  n = "Large Prismatic Shard",                i = "Interface\\Icons\\INV_Enchant_ShardPrismaticLarge", cls = 7, sub = 12, ilvl = 1 },
    { e = 43543, q = 1, c = 3,   n = "Glyph of Frost Strike",                i = "Interface\\Icons\\INV_Inscription_MajorGlyph00", cls = 16, sub = 6, ilvl = 1 },
    { e = 52325, q = 2, c = 25,  n = "Volatile Fire",                        i = "Interface\\Icons\\Spell_Fire_FelFire", cls = 7, sub = 10, ilvl = 1 },
    { e = 36931, q = 4, c = 1,   n = "Ilvl 200 Epic Gem",                    i = "Interface\\Icons\\INV_Misc_Gem_Diamond_06", cls = 3, sub = 0, ilvl = 200 },
    { e = 43102, q = 3, c = 2,   n = "Crusader Orb",                         i = "Interface\\Icons\\Spell_Frost_FrozenOrb", cls = 7, sub = 10, ilvl = 1 },
}

Core.items = Core.items or {}
Core.filtered = Core.filtered or {}
Core.gridLayout = Core.gridLayout or {}
Core.categories = Core.categories or {}
Core.subcategoryCounts = Core.subcategoryCounts or {}
Core.selectedItem = nil
Core.totalItems = 0
Core.spaceUsed = 0
Core.depositCount = 0
Core.withdrawCount = 0
Core.cacheLoaded = false
Core.cacheDirty = false

local state = {
    query = "",
    category = "all",
    subcategory = "all",
    quality = -1,
    slot = "all",
    sort = "recent",
    sortAsc = false,
    page = 1,
    pageSize = 12,
    gridPageSize = 104,
    viewMode = "list",
    mode = "browse",
}
Core.state = state

local QUALITY_LABELS = {
    [-1] = "All Qualities",
    [0] = "Poor",
    [1] = "Common",
    [2] = "Uncommon",
    [3] = "Rare",
    [4] = "Epic",
    [5] = "Legendary",
}
Core.QUALITY_LABELS = QUALITY_LABELS

local SLOT_LABELS = {
    all = "All Slots",
    weapon = "Weapons",
    armor = "Armor",
    consumable = "Consumables",
    trade = "Trade Goods",
    gem = "Gems",
    glyph = "Glyphs",
    recipe = "Recipes",
    quest = "Quest Items",
    misc = "Miscellaneous",
}
Core.SLOT_LABELS = SLOT_LABELS

-- MUST list every category CategoryFor() can return (see CLASS_CAT and
-- SUB_TRADE_CAT below). This is not just the sidebar's row order: BuildGridLayout
-- walks THIS table to emit the grid's buckets, so a category missing here is
-- rendered nowhere in grid view at all -- not even under "All Categories" -- and
-- has no sidebar row to filter by either. "gem" and "glyph" were both mapped in
-- CLASS_CAT and given full SUBCATEGORY_DEFS, a Slot dropdown entry and a
-- SLOT_LABELS label, but never added here, so every gem and every glyph in the
-- Vault was invisible in grid view (reported: "glyphs don't show up at all").
local CATEGORY_ORDER = {
    "all", "weapon", "armor", "consumable", "trade", "enchanting",
    "jewelcrafting", "engineering", "leatherworking", "tailoring",
    "cooking", "herbalism", "mining", "gem", "glyph", "recipe", "quest",
    "misc", "other",
}

local CATEGORY_LABELS = {
    all = "All Categories",
    weapon = "Weapons",
    armor = "Armor",
    consumable = "Consumables",
    trade = "Trade Goods",
    enchanting = "Enchanting",
    jewelcrafting = "Jewelcrafting",
    engineering = "Engineering",
    leatherworking = "Leatherworking",
    tailoring = "Tailoring",
    cooking = "Cooking",
    herbalism = "Herbalism",
    mining = "Mining",
    gem = "Gems",
    glyph = "Glyphs",
    recipe = "Recipes",
    quest = "Quest Items",
    misc = "Miscellaneous",
    other = "Other",
}
Core.CATEGORY_LABELS = CATEGORY_LABELS
Core.CATEGORY_COUNT = #CATEGORY_ORDER - 1

local CLASS_CAT = {
    [0] = "consumable",
    [2] = "weapon",
    [3] = "gem",
    [4] = "armor",
    [5] = "trade",
    [6] = "trade",
    [7] = "trade",
    [9] = "recipe",
    [12] = "quest",
    [15] = "misc",
    [16] = "glyph",
}

local SUB_TRADE_CAT = {
    [5] = "tailoring",
    [6] = "leatherworking",
    [7] = "mining",
    [9] = "herbalism",
    [10] = "trade",
    [11] = "engineering",
    [12] = "enchanting",
    [4] = "jewelcrafting",
}

local SUBCATEGORY_DEFS = {
    weapon = {
        { key = "axe1", label = "One-Handed Axes", sub = 0 },
        { key = "axe2", label = "Two-Handed Axes", sub = 1 },
        { key = "bow", label = "Bows", sub = 2 },
        { key = "gun", label = "Guns", sub = 3 },
        { key = "mace1", label = "One-Handed Maces", sub = 4 },
        { key = "mace2", label = "Two-Handed Maces", sub = 5 },
        { key = "polearm", label = "Polearms", sub = 6 },
        { key = "sword1", label = "One-Handed Swords", sub = 7 },
        { key = "sword2", label = "Two-Handed Swords", sub = 8 },
        { key = "staff", label = "Staves", sub = 10 },
        { key = "fist", label = "Fist Weapons", sub = 13 },
        { key = "offhand", label = "Off-Hand", equips = { INVTYPE_WEAPONOFFHAND = true, INVTYPE_HOLDABLE = true } },
        { key = "misc", label = "Miscellaneous", sub = 14 },
        { key = "dagger", label = "Daggers", sub = 15 },
        { key = "thrown", label = "Thrown", sub = 16 },
        { key = "crossbow", label = "Crossbows", sub = 18 },
        { key = "wand", label = "Wands", sub = 19 },
        { key = "fishing", label = "Fishing Poles", sub = 20 },
    },
    armor = {
        { key = "neck", label = "Necklaces", equip = "INVTYPE_NECK" },
        { key = "finger", label = "Rings", equip = "INVTYPE_FINGER" },
        { key = "trinket", label = "Trinkets", equip = "INVTYPE_TRINKET" },
        { key = "misc", label = "Miscellaneous", sub = 0 },
        { key = "cloth", label = "Cloth", sub = 1 },
        { key = "leather", label = "Leather", sub = 2 },
        { key = "mail", label = "Mail", sub = 3 },
        { key = "plate", label = "Plate", sub = 4 },
        { key = "shield", label = "Shields", sub = 6 },
        { key = "libram", label = "Librams", sub = 7 },
        { key = "idol", label = "Idols", sub = 8 },
        { key = "totem", label = "Totems", sub = 9 },
        { key = "sigil", label = "Sigils", sub = 10 },
    },
    consumable = {
        { key = "generic", label = "Consumables", sub = 0 },
        { key = "potion", label = "Potions", sub = 1 },
        { key = "elixir", label = "Elixirs", sub = 2 },
        { key = "flask", label = "Flasks", sub = 3 },
        { key = "scroll", label = "Scrolls", sub = 4 },
        { key = "food", label = "Food & Drink", sub = 5 },
        { key = "enhancement", label = "Item Enhancements", sub = 6 },
        { key = "bandage", label = "Bandages", sub = 7 },
        { key = "other", label = "Other", sub = 8 },
    },
    trade = {
        { key = "parts", label = "Parts", sub = 1 },
        { key = "explosives", label = "Explosives", sub = 2 },
        { key = "devices", label = "Devices", sub = 3 },
        { key = "jewelcrafting", label = "Jewelcrafting", sub = 4 },
        { key = "cloth", label = "Cloth", sub = 5 },
        { key = "leather", label = "Leather", sub = 6 },
        { key = "metalstone", label = "Metal & Stone", sub = 7 },
        { key = "meat", label = "Meat", sub = 8 },
        { key = "herb", label = "Herbs", sub = 9 },
        { key = "elemental", label = "Elemental", sub = 10 },
        { key = "other", label = "Other", sub = 11 },
        { key = "enchanting", label = "Enchanting", sub = 12 },
    },
    gem = {
        { key = "red", label = "Red", sub = 0 },
        { key = "blue", label = "Blue", sub = 1 },
        { key = "yellow", label = "Yellow", sub = 2 },
        { key = "purple", label = "Purple", sub = 3 },
        { key = "green", label = "Green", sub = 4 },
        { key = "orange", label = "Orange", sub = 5 },
        { key = "meta", label = "Meta", sub = 6 },
        { key = "simple", label = "Simple", sub = 7 },
        { key = "prismatic", label = "Prismatic", sub = 8 },
    },
    glyph = {
        { key = "warrior", label = "Warrior", sub = 1 },
        { key = "paladin", label = "Paladin", sub = 2 },
        { key = "hunter", label = "Hunter", sub = 3 },
        { key = "rogue", label = "Rogue", sub = 4 },
        { key = "priest", label = "Priest", sub = 5 },
        { key = "deathknight", label = "Death Knight", sub = 6 },
        { key = "shaman", label = "Shaman", sub = 7 },
        { key = "mage", label = "Mage", sub = 8 },
        { key = "warlock", label = "Warlock", sub = 9 },
        { key = "druid", label = "Druid", sub = 11 },
    },
}
Core.SUBCATEGORY_DEFS = SUBCATEGORY_DEFS

local function CopyDefault(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = x end
    return t
end

function Core.GetDB()
    UncappedVaultDB = UncappedVaultDB or {}
    local db = UncappedVaultDB
    local defaults = {
        autoBagSync = true,
        viewMode = "list",
    }
    for k, v in pairs(defaults) do
        if db[k] == nil then db[k] = CopyDefault(v) end
    end
    db.viewMode = (db.viewMode == "grid") and "grid" or "list"
    state.viewMode = db.viewMode
    return db
end

function Core.Comma(n)
    local s = tostring(floor(tonumber(n) or 0))
    local k
    repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
    return s
end

local function ResolveName(it)
    if it.n and it.n ~= "" then return it.n end
    it.n = GetItemInfo(it.e) or ""
    return it.n
end

local function CategoryFor(it)
    local cls = it.cls or 15
    local sub = it.sub or 0
    if cls == 7 and SUB_TRADE_CAT[sub] then return SUB_TRADE_CAT[sub] end
    return CLASS_CAT[cls] or "other"
end
Core.CategoryFor = CategoryFor

local function SlotFor(it)
    local cat = CategoryFor(it)
    if cat == "weapon" then return "weapon" end
    if cat == "armor" then return "armor" end
    if cat == "consumable" then return "consumable" end
    if cat == "gem" then return "gem" end
    if cat == "glyph" then return "glyph" end
    if cat == "recipe" then return "recipe" end
    if cat == "quest" then return "quest" end
    if cat == "misc" or cat == "other" then return "misc" end
    return "trade"
end
Core.SlotFor = SlotFor

local function SubcategoryFor(it, cat)
    local defs = SUBCATEGORY_DEFS[cat]
    if not defs then return "all" end

    local equipLoc
    if cat == "armor" or cat == "weapon" then
        equipLoc = select(9, GetItemInfo(it.e))
        if equipLoc and equipLoc ~= "" then
            for i = 1, #defs do
                if defs[i].equip == equipLoc then return defs[i].key end
                if defs[i].equips and defs[i].equips[equipLoc] then return defs[i].key end
            end
        end
    end

    local sub = tonumber(it.sub) or 0
    for i = 1, #defs do
        if defs[i].sub == sub then return defs[i].key end
    end
    return "other"
end
Core.SubcategoryFor = SubcategoryFor

function Core.ItemAgeText(it)
    if it and it.days then return it.days .. "d" end
    local added = it and it.added or 0
    if added <= 0 then return "2d" end
    return max(1, min(99, added)) .. "d"
end

local function Notify(reason)
    Core.Rebuild()
    if Core.UI and Core.UI.Refresh then Core.UI.Refresh(reason) end
end

function Core.RegisterUI(ui)
    Core.UI = ui
end

function Core.SetMode(mode)
    state.mode = mode or "browse"
    Notify("mode")
end

function Core.SetQuery(q)
    state.query = lower(q or "")
    state.page = 1
    Notify("filter")
end

function Core.SetCategory(cat)
    cat = cat or "all"
    if cat ~= "all" and state.category == cat and state.subcategory == "all" then
        cat = "all"
    end
    state.category = cat
    state.subcategory = "all"
    state.page = 1
    Notify("filter")
end

function Core.SetSubcategory(cat, subcat)
    state.category = cat or state.category or "all"
    state.subcategory = subcat or "all"
    state.page = 1
    Notify("filter")
end

function Core.ResetFilters()
    state.query = ""
    state.category = "all"
    state.subcategory = "all"
    state.quality = -1
    state.slot = "all"
    state.page = 1
    Notify("filter")
end

function Core.SetQuality(q)
    state.quality = tonumber(q) or -1
    state.page = 1
    Notify("filter")
end

function Core.SetSlot(slot)
    state.slot = slot or "all"
    state.page = 1
    Notify("filter")
end

function Core.SetSort(key)
    if state.sort == key then
        state.sortAsc = not state.sortAsc
    else
        state.sort = key or "recent"
        state.sortAsc = false
    end
    state.page = 1
    Notify("sort")
end

function Core.SetViewMode(mode)
    local chosen = (mode == "grid") and "grid" or "list"
    state.viewMode = chosen
    state.page = 1
    Core.GetDB().viewMode = chosen
    state.viewMode = chosen
    Notify("view")
end

function Core.SetPage(page)
    state.page = max(1, min(Core.PageCount(), tonumber(page) or 1))
    Notify("page")
end

-- List-view page size used to be a fixed 12, tuned for a tall standalone
-- window (up to 900px). Embedded in the Dashboard, whose height is capped
-- well below what 12 rows need, a fixed count either overflowed past the
-- panel's bottom edge or wasted space -- UncappedVault_UI.lua now
-- recomputes this from tablePanel's actual current height and calls this
-- whenever it changes (see RefreshRowCount there).
function Core.SetPageSize(n)
    n = math.floor(tonumber(n) or state.pageSize)
    if n < 1 then n = 1 end
    if n == state.pageSize then return end
    state.pageSize = n
    state.page = max(1, min(Core.PageCount(), state.page))
    Notify("pagesize")
end

-- Grid-view page size, same story as SetPageSize above but for gridPageSize:
-- it used to be a fixed 104, tuned for a tall standalone window, and stayed
-- fixed even after the Dashboard embed shrank the panel -- so a page kept
-- laying out 104 slots' worth of icons regardless of how many rows actually
-- fit, and the overflow rendered past gridPanel's bottom edge. UncappedVault_UI.lua
-- now recomputes this from gridPanel's actual current height and column count
-- (see RefreshGridRowCount there) and calls this whenever it changes.
function Core.SetGridPageSize(n)
    n = math.floor(tonumber(n) or state.gridPageSize)
    if n < 1 then n = 1 end
    if n == state.gridPageSize then return end
    state.gridPageSize = n
    state.page = max(1, min(Core.PageCount(), state.page))
    Notify("pagesize")
end

local SORTERS = {
    name = function(a, b)
        local an, bn = ResolveName(a), ResolveName(b)
        if an == bn then return (a.e or 0) < (b.e or 0) end
        return an < bn
    end,
    level = function(a, b)
        if (a.ilvl or 0) ~= (b.ilvl or 0) then return (a.ilvl or 0) > (b.ilvl or 0) end
        return ResolveName(a) < ResolveName(b)
    end,
    rarity = function(a, b)
        if (a.q or 0) ~= (b.q or 0) then return (a.q or 0) > (b.q or 0) end
        return ResolveName(a) < ResolveName(b)
    end,
    quantity = function(a, b)
        if (a.c or 0) ~= (b.c or 0) then return (a.c or 0) > (b.c or 0) end
        return ResolveName(a) < ResolveName(b)
    end,
    slot = function(a, b)
        local as, bs = SlotFor(a), SlotFor(b)
        if as ~= bs then return as < bs end
        return ResolveName(a) < ResolveName(b)
    end,
    recent = function(a, b)
        return (a.added or 0) > (b.added or 0)
    end,
}

local function BuildGridLayout()
    local grid = Core.gridLayout
    while #grid > 0 do tremove(grid) end

    local byCategory = {}
    for _, it in ipairs(Core.filtered) do
        local cat = CategoryFor(it)
        local bucket = byCategory[cat]
        if not bucket then bucket = {}; byCategory[cat] = bucket end
        bucket[#bucket + 1] = it
    end

    local sorter = SORTERS[state.sort] or SORTERS.recent
    for _, key in ipairs(CATEGORY_ORDER) do
        if key ~= "all" then
            local bucket = byCategory[key]
            if bucket and #bucket > 0 then
                sort(bucket, function(a, b)
                    if state.sortAsc then return sorter(b, a) end
                    return sorter(a, b)
                end)
                grid[#grid + 1] = { header = true, key = key, label = CATEGORY_LABELS[key] or key, count = #bucket }
                for i = 1, #bucket do
                    grid[#grid + 1] = { item = bucket[i] }
                end
            end
        end
    end
end

function Core.Rebuild()
    local q = state.query or ""
    local category = state.category or "all"
    local subcategory = state.subcategory or "all"
    local quality = tonumber(state.quality) or -1
    local slot = state.slot or "all"
    local filtered = Core.filtered
    while #filtered > 0 do tremove(filtered) end

    Core.totalItems, Core.spaceUsed = 0, 0
    local counts = {}
    local subCounts = {}
    for _, key in ipairs(CATEGORY_ORDER) do counts[key] = 0 end
    for _, it in ipairs(Core.items) do
        local name = ResolveName(it)
        local cat = CategoryFor(it)
        local subcat = SubcategoryFor(it, cat)
        local itemSlot = SlotFor(it)
        local count = tonumber(it.c) or 0
        Core.totalItems = Core.totalItems + count
        Core.spaceUsed = Core.spaceUsed + 1
        counts.all = (counts.all or 0) + count
        counts[cat] = (counts[cat] or 0) + count
        subCounts[cat] = subCounts[cat] or {}
        subCounts[cat][subcat] = (subCounts[cat][subcat] or 0) + count

        if (q == "" or lower(name):find(q, 1, true))
            and (category == "all" or category == cat)
            and (subcategory == "all" or subcategory == subcat)
            and (quality < 0 or (it.q or 0) == quality)
            and (slot == "all" or itemSlot == slot) then
            filtered[#filtered + 1] = it
        end
    end

    local sorter = SORTERS[state.sort] or SORTERS.recent
    sort(filtered, function(a, b)
        if state.sortAsc then return sorter(b, a) end
        return sorter(a, b)
    end)

    Core.categories = {}
    local function AddCategoryRow(key)
        Core.categories[#Core.categories + 1] = {
            kind = "category",
            key = key,
            label = CATEGORY_LABELS[key] or key,
            count = counts[key] or 0,
        }
    end
    local function AddSubcategoryRows(key)
        if SUBCATEGORY_DEFS[key] then
            Core.categories[#Core.categories + 1] = {
                kind = "subcategory",
                key = key,
                subcategory = "all",
                label = "All " .. (CATEGORY_LABELS[key] or key),
                count = counts[key] or 0,
            }
            for _, def in ipairs(SUBCATEGORY_DEFS[key]) do
                local c = subCounts[key] and subCounts[key][def.key] or 0
                Core.categories[#Core.categories + 1] = {
                    kind = "subcategory",
                    key = key,
                    subcategory = def.key,
                    label = def.label,
                    count = c,
                }
            end
        end
    end

    -- Every top-level category always stays in the list -- selecting one used
    -- to REPLACE the whole list with just "All Categories" + that category +
    -- its subcategories, so every sibling category (and the ability to scroll
    -- to one) disappeared the moment you drilled into anything. Trade Goods
    -- and Consumables have the longest subcategory lists, so losing every
    -- sibling was most visible -- and most reported -- there. Inline-expand
    -- the selected category's subcategories right after its own row instead.
    for _, key in ipairs(CATEGORY_ORDER) do
        AddCategoryRow(key)
        if key == state.category and SUBCATEGORY_DEFS[key] then
            AddSubcategoryRows(key)
        end
    end
    Core.subcategoryCounts = subCounts

    BuildGridLayout()
    local pages = Core.PageCount()
    if state.page > pages then state.page = pages end
end

function Core.PageCount()
    if state.viewMode == "grid" then
        return max(1, math.ceil(#Core.gridLayout / state.gridPageSize))
    end
    return max(1, math.ceil(#Core.filtered / state.pageSize))
end

function Core.PageItems()
    local start = ((state.page - 1) * state.pageSize) + 1
    local out = {}
    for i = start, min(#Core.filtered, start + state.pageSize - 1) do
        out[#out + 1] = Core.filtered[i]
    end
    return out
end

function Core.PageGridEntries()
    local start = ((state.page - 1) * state.gridPageSize) + 1
    local out = {}
    for i = start, min(#Core.gridLayout, start + state.gridPageSize - 1) do
        out[#out + 1] = Core.gridLayout[i]
    end
    return out
end

function Core.SelectItem(item)
    Core.selectedItem = item
    if Core.UI and Core.UI.RefreshDetails then Core.UI.RefreshDetails() end
end

local scanParent = CreateFrame("Frame")
scanParent:Hide()
local scanTip = CreateFrame("GameTooltip", "UncappedVaultScanTip", scanParent, "GameTooltipTemplate")
scanTip:SetOwner(scanParent, "ANCHOR_NONE")
local queried, pending, warmQueue = {}, {}, {}
local iconsDirty = false
local staging = {}

local function EnqueueWarm(e)
    if pending[e] or GetItemInfo(e) then return end
    pending[e] = true
    warmQueue[#warmQueue + 1] = e
end
Core.EnqueueWarm = EnqueueWarm

local function ClearItems()
    while #Core.items > 0 do tremove(Core.items) end
end

local function CopyItem(it)
    return {
        e = tonumber(it.e) or 0,
        rp = tonumber(it.rp) or 0,
        c = tonumber(it.c) or 0,
        q = tonumber(it.q) or 0,
        cls = tonumber(it.cls) or 15,
        sub = tonumber(it.sub) or 0,
        ilvl = tonumber(it.ilvl) or 1,
        icon = it.icon or it.i,
        i = it.i or it.icon,
        n = it.n or "",
        added = tonumber(it.added) or 0,
        days = tonumber(it.days) or nil,
    }
end

local function ParseItemLink(link)
    local itemString = link and match(link, "item:([^|]+)")
    if not itemString then return nil, 0 end

    local fields = {}
    for token in gmatch(itemString, "([^:]+)") do
        fields[#fields + 1] = token
    end

    return tonumber(fields[1]), tonumber(fields[7]) or 0
end

local function CaptureBagItem(bag, slot, fallbackLink)
    if not bag or not slot or not GetContainerItemInfo then return nil end

    local icon, count, _, quality, _, _, itemLink = GetContainerItemInfo(bag, slot)
    itemLink = itemLink or fallbackLink

    local e, rp = ParseItemLink(itemLink)
    if not e then return nil end

    local name, _, infoQuality, ilvl, _, _, _, _, _, infoIcon, _, classID, subclassID = GetItemInfo(e)
    return {
        e = e,
        rp = rp or 0,
        c = tonumber(count) or 1,
        q = tonumber(quality or infoQuality) or 0,
        cls = tonumber(classID) or 15,
        sub = tonumber(subclassID) or 0,
        ilvl = tonumber(ilvl) or 1,
        icon = icon or infoIcon,
        i = icon or infoIcon,
        n = name or "",
        added = 0,
    }
end

function Core.SaveCache()
    if Core.demo then return end
    local db = Core.GetDB()
    db.cacheVersion = CACHE_VERSION
    db.cacheSavedAt = time and time() or floor(GetTime() or 0)
    db.cachedItems = {}
    for i = 1, #Core.items do
        db.cachedItems[i] = CopyItem(Core.items[i])
    end
    Core.cacheDirty = false
end

function Core.ClearCache()
    if Core.demo then return end
    local db = Core.GetDB()
    db.cacheVersion = CACHE_VERSION
    db.cacheSavedAt = nil
    db.cachedItems = {}
    Core.cacheLoaded = false
    Core.cacheDirty = false
end

function Core.LoadCache()
    if Core.demo then return false end
    local db = Core.GetDB()
    if db.cacheVersion ~= CACHE_VERSION or type(db.cachedItems) ~= "table" or #db.cachedItems == 0 then
        return false
    end

    ClearItems()
    for i = 1, #db.cachedItems do
        local it = CopyItem(db.cachedItems[i])
        Core.items[#Core.items + 1] = it
        EnqueueWarm(it.e)
    end
    Core.cacheLoaded = true
    Notify("cache")
    return true
end

local warmer = CreateFrame("Frame")
local warmAcc = 0
warmer:SetScript("OnUpdate", function(_, dt)
    if #warmQueue == 0 then return end
    warmAcc = warmAcc + (dt or arg1 or 0)
    if warmAcc < 0.2 then return end
    warmAcc = 0
    local fired = 0
    for i = #warmQueue, 1, -1 do
        local e = warmQueue[i]
        if GetItemInfo(e) then
            pending[e] = nil
            tremove(warmQueue, i)
            iconsDirty = true
        elseif not queried[e] and fired < 10 then
            queried[e] = true
            scanTip:SetHyperlink("item:" .. e)
            fired = fired + 1
        end
    end
    if iconsDirty then
        iconsDirty = false
        Notify("icons")
    end
end)

function Core.Send(msg)
    if Core.demo then return end
    if SendAddonMessage then
        SendAddonMessage(TRANSPORT_PREFIX, msg, "WHISPER", UnitName("player"))
    end
end

function Core.RequestSnapshot(cleanCache)
    staging = {}
    if cleanCache then Core.ClearCache() end
    Core.Send("VLTGET")
end

local recacheTicker = CreateFrame("Frame")
recacheTicker:Hide()
recacheTicker.elapsed = 0
recacheTicker:SetScript("OnUpdate", function(self, dt)
    if Core.demo then
        self:Hide()
        return
    end

    self.elapsed = (self.elapsed or 0) + (dt or arg1 or 0)
    if self.elapsed < RECACHE_INTERVAL then return end
    self.elapsed = 0
    Core.RequestSnapshot(true)
end)

local function StartRecacheTicker()
    recacheTicker.elapsed = 0
    recacheTicker:Show()
end

-- Seconds left until the automatic recache -- read by the UI's refresh-button
-- tooltip. Not meaningful (and not shown) while the ticker isn't running yet.
function Core.SecondsUntilRecache()
    if not recacheTicker:IsShown() then return nil end
    return max(0, RECACHE_INTERVAL - (recacheTicker.elapsed or 0))
end

-- Manual refresh: same full resync the auto-recache does, and resets the
-- ticker so it doesn't also fire moments later on its own. pendingManualRefresh
-- flags the chat confirmation below to fire once VLTEND actually lands --
-- not on the click itself, so the message means the data really did arrive.
local pendingManualRefresh = false
function Core.ManualRefresh()
    pendingManualRefresh = true
    Core.RequestSnapshot(true)
end

local function FindRow(e, rp)
    for _, it in ipairs(Core.items) do
        if it.e == e and (it.rp or 0) == rp then return it end
    end
end

local function ApplyDepositToCache(item)
    if not item or not item.e then return end

    local row = FindRow(item.e, item.rp or 0)
    if row then
        row.c = (tonumber(row.c) or 0) + max(1, tonumber(item.c) or 1)
        row.q = tonumber(row.q) or tonumber(item.q) or 0
        row.cls = tonumber(row.cls) or tonumber(item.cls) or 15
        row.sub = tonumber(row.sub) or tonumber(item.sub) or 0
        row.ilvl = tonumber(row.ilvl) or tonumber(item.ilvl) or 1
        row.icon = row.icon or item.icon
        row.i = row.i or item.i
        row.n = (row.n and row.n ~= "" and row.n) or item.n or ""
    else
        Core.items[#Core.items + 1] = CopyItem(item)
    end

    Core.depositCount = Core.depositCount + 1
    EnqueueWarm(item.e)
    Core.SaveCache()
    Notify("deposit")
end

function Core.Withdraw(item, count)
    if not item then return end
    count = max(1, min(tonumber(count) or 1, tonumber(item.c) or 1))
    if Core.demo then
        item.c = max(0, (item.c or 0) - count)
        Core.withdrawCount = Core.withdrawCount + 1
        if item.c <= 0 then
            for i, it in ipairs(Core.items) do
                if it == item then tremove(Core.items, i); break end
            end
            if Core.selectedItem == item then Core.selectedItem = nil end
        end
        Notify("withdraw")
        return
    end
    Core.Send(format("VLTWD:%d:%d:%d", item.e, item.rp or 0, count))
end

local lastPickup
if hooksecurefunc then
    hooksecurefunc("PickupContainerItem", function(bag, slot)
        lastPickup = { bag = bag, slot = slot }
    end)
end

function Core.DepositCursor()
    if Core.demo then ClearCursor(); return end
    if not CursorHasItem() then return end
    local t = GetCursorInfo()
    if t == "item" and lastPickup then
        Core.Send(format("VLTDEP:%d:%d", lastPickup.bag, lastPickup.slot))
        ClearCursor()
        ApplyDepositToCache(CaptureBagItem(lastPickup.bag, lastPickup.slot))
        lastPickup = nil
        return
    end
    ClearCursor()
end

if hooksecurefunc then
    hooksecurefunc("HandleModifiedItemClick", function(link)
        if Core.demo or not link then return end
        if not (Core.UI and Core.UI.IsShown and Core.UI.IsShown()) then return end
        if not (IsControlKeyDown() or IsShiftKeyDown()) then return end
        for bag = 0, 4 do
            for slot = 1, GetContainerNumSlots(bag) do
                if GetContainerItemLink(bag, slot) == link then
                    local item = CaptureBagItem(bag, slot, link)
                    Core.Send(format("VLTDEP:%d:%d", bag, slot))
                    ApplyDepositToCache(item)
                    return
                end
            end
        end
    end)
end

local function LoadDemo()
    while #Core.items > 0 do tremove(Core.items) end
    for k, src in ipairs(DEMO_ITEMS) do
        Core.items[#Core.items + 1] = {
            e = src.e, rp = src.rp or 0, q = src.q, c = src.c, n = src.n, i = src.i,
            icon = src.i, cls = src.cls, sub = src.sub, ilvl = src.ilvl,
            added = k, days = min(99, k + 1),
        }
    end
    Notify("demo")
end
Core.LoadDemo = LoadDemo

local comms = CreateFrame("Frame")
comms:RegisterEvent("CHAT_MSG_ADDON")
comms:SetScript("OnEvent", function(_, _, a1, a2)
    if a1 ~= ADDON_PIPE_PREFIX or not a2 then return end
    local text = a2
    if find(text, "^VLTROW:") then
        local any8 = false
        for e, rp, c, q, cls, subc, ilvl, icon in gmatch(text, "(%-?%d+),(%-?%d+),(%d+),(%d+),(%d+),(%d+),(%d+),([^;]*);") do
            any8 = true
            staging[#staging + 1] = {
                e = tonumber(e), rp = tonumber(rp), c = tonumber(c), q = tonumber(q),
                cls = tonumber(cls), sub = tonumber(subc), ilvl = tonumber(ilvl),
                icon = (icon ~= "" and ("Interface\\Icons\\" .. icon)) or nil,
                n = "",
            }
        end
        if not any8 then
            for e, rp, c, q, icon in gmatch(text, "(%-?%d+),(%-?%d+),(%d+),(%d+),([^;]*);") do
                staging[#staging + 1] = {
                    e = tonumber(e), rp = tonumber(rp), c = tonumber(c), q = tonumber(q),
                    icon = (icon ~= "" and ("Interface\\Icons\\" .. icon)) or nil,
                    n = "",
                }
            end
        end
    elseif find(text, "^VLTEND:") then
        ClearItems()
        for idx, it in ipairs(staging) do
            it.added = #staging - idx
            Core.items[#Core.items + 1] = it
            EnqueueWarm(it.e)
        end
        staging = {}
        Core.cacheLoaded = true
        Core.SaveCache()
        Notify("snapshot")
        if pendingManualRefresh then
            pendingManualRefresh = false
            if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff40c0ff[Vault]|r refreshed.") end
        end
    elseif find(text, "^VLTWDONE:") then
        local e, rp, given, remaining = match(text, "^VLTWDONE:(%d+):(%-?%d+):(%d+):(%d+)$")
        if e then
            e, rp, given, remaining = tonumber(e), tonumber(rp), tonumber(given), tonumber(remaining)
            local it = FindRow(e, rp)
            if it then
                it.c = remaining
                if remaining <= 0 then
                    for k, v in ipairs(Core.items) do if v == it then tremove(Core.items, k); break end end
                    if Core.selectedItem == it then Core.selectedItem = nil end
                end
            end
            Core.withdrawCount = Core.withdrawCount + 1
            Core.SaveCache()
            if DEFAULT_CHAT_FRAME then
                DEFAULT_CHAT_FRAME:AddMessage(format("|cff40c0ff[Vault]|r withdrew |cffffffff%sx|r %s", Core.Comma(given), GetItemInfo(e) or ("item " .. e)))
            end
            Notify("withdraw")
        end
    elseif find(text, "^VLTWDFAIL:") then
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff40c0ff[Vault]|r couldn't withdraw -- bags full, or not enough left in the vault.") end
    elseif find(text, "^VLTDEPFAIL:") then
        local why = match(text, "^VLTDEPFAIL:(%a+)")
        local reason = (why == "quest" and "quest items") or (why == "bag" and "bags")
            or (why == "bound" and "soulbound items") or "that item"
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff40c0ff[Vault]|r can't deposit " .. reason .. ".") end
    end
end)

local function Toggle()
    if Core.UI and Core.UI.Toggle then Core.UI.Toggle() end
end
Core.Toggle = Toggle

local init = CreateFrame("Frame")
init:RegisterEvent("PLAYER_LOGIN")
init:SetScript("OnEvent", function()
    Core.GetDB()
    if Core.demo then
        LoadDemo()
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff40c0ff[Vault]|r preview ready -- type |cffffd100/dashboard|r to open it.") end
    else
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff40c0ff[Vault]|r ready -- type |cffffd100/dashboard|r to open it.") end
        if not Core.LoadCache() then Core.RequestSnapshot() end
        StartRecacheTicker()
    end
end)

-- No standalone /vault command: this window is a Dashboard tab now, opened via
-- /dashboard, so a dedicated slash command would just duplicate that entry point.
