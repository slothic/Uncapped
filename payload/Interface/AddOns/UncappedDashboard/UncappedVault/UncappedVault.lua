-- UncappedVault -- core vault state and server transport.
-- Derived from UncappedVault's live VLT* protocol, bag hooks, item-cache
-- warming, and withdraw/deposit behaviour.

local ADDON_PIPE_PREFIX = "UNC"
local TRANSPORT_PREFIX = "REAGENTBANK"
local ADDON = "UncappedVault"
-- Bump this whenever the MEANING of a cached field changes, not just its shape.
-- v2: the server now reports quest-shaped items as class 12 so they file under
-- "Quest Items". Rows cached under v1 carry the item's real class (Bloodcap is
-- 15/MISC), so without a bump every existing client keeps showing them in
-- Miscellaneous forever -- a cached snapshot means no snapshot is ever requested.
local CACHE_VERSION = 2
--[[ Full-resync interval.

     This used to be the ONLY way the window ever learned the vault had changed,
     which is why it was 300s: nothing pushed, so it had to poll. The server now
     sends VLTUPD whenever a row moves, so this is no longer the mechanism -- it
     is a backstop for the cases where a push can go missing, and those are
     EVENTS rather than durations: the native handler table is zeroed on
     reconnect, and the DLL capability flag is cleared on login rather than
     logout, so a crash or a kick can leave it stale.

     Lengthened rather than deleted, deliberately. Deleting it without
     event-driven resync on reconnect would trade a wasteful poll for a silent
     failure mode; a long backstop costs one snapshot per quarter hour.
]]
local RECACHE_INTERVAL = 900

local floor, min, max = math.floor, math.min, math.max
local format, lower, find, match, gmatch = string.format, string.lower, string.find, string.match, string.gmatch
local strsub = string.sub
local tinsert, tremove, sort = table.insert, table.remove, table.sort
local tconcat = table.concat

local Core = _G.UncappedVault or {}
_G.UncappedVault = Core

Core.version = "0.0.1"
Core.ADDON = ADDON
Core.callbacks = Core.callbacks or {}

-- ★ [DE-14] Demo mode is gone.
--
-- It was unreachable at compile time: FORCE_LIVE was a file-local `true` that
-- nothing ever reassigned, so `Core.demo = not (FORCE_LIVE or RealmIsDev())`
-- was permanently false. With it went RealmIsDev, the 12-row DEMO_ITEMS
-- table, LoadDemo and twelve `if Core.demo` guards -- including a whole
-- client-side withdraw simulation inside Core.Withdraw that could never run.

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
--[[ ★ [DE-06] The DERIVED view is behind Core.items, and nobody is looking.

     Raised whenever an update lands while the Vault panel is off screen and the
     Rebuild+repaint is therefore skipped -- see FlushVaultUpdate and the warmer.
     Deliberately a Core field rather than a file-local, for exactly the reason
     cacheDirty is one: the places that raise it and the places that clear it are
     five hundred and fifteen hundred lines apart, and a local declared at either
     end is invisible at the other.

     ⚠ IT MEANS "THE SCREEN IS STALE", NOT "THE TABLES ARE". Core.items is always
     current -- the message handler writes it before any of this runs. Clear it
     only alongside a real Notify(), never after a bare Core.Rebuild(). ]]
Core.displayDirty = false

local state = {
    query = "",
    category = "all",
    subcategory = "all",
    quality = -1,
    -- Equipment slot ("head", "twohand", ...). Orthogonal to category/
    -- subcategory on purpose: "Plate" in the sidebar + "Chest" here is the
    -- question report #218 actually asked, and it needs both axes at once.
    equipSlot = "all",
    -- Hide anything this character's class cannot use. Off by default -- see
    -- SetClassOnly.
    classOnly = false,
    sort = "recent",
    sortAsc = false,
    page = 1,
    pageSize = 12,
    gridCols = 1,
    gridAvail = 0,
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

--[[ Equipment slot -- the one gearing dimension the wire does NOT carry.

     custom_vault_item denormalises class/subclass/quality/item_level precisely
     so this browser can bucket items without touching the client's item cache,
     and the VLTROW format ships all four. InventoryType is not among them, so
     the thing report #218 asks for by name ("maybe even each equipment slot")
     is the only part with no server-side answer.

     It is still resolvable here: GetItemInfo's 9th return is the equip-location
     TOKEN ("INVTYPE_HEAD"), not a localised string, so it is safe to key on --
     SubcategoryFor has keyed on it for necks/rings/trinkets since day one.
     What changes is that the answer is now resolved ONCE and cached onto the
     row (and saved with it), instead of re-queried for every armour and weapon
     row on every rebuild -- i.e. on every keystroke in the search box, which a
     ten-thousand-row vault feels.

     Normalised to our own short keys rather than kept as INVTYPE_* strings so
     the several tokens that mean one slot to a player (CHEST/ROBE,
     RANGED/RANGEDRIGHT) collapse into one bucket. ]]
local EQUIP_FROM_INVTYPE = {
    INVTYPE_HEAD = "head",
    INVTYPE_NECK = "neck",
    INVTYPE_SHOULDER = "shoulder",
    INVTYPE_CLOAK = "back",
    INVTYPE_CHEST = "chest",
    INVTYPE_ROBE = "chest",
    INVTYPE_BODY = "shirt",
    INVTYPE_TABARD = "tabard",
    INVTYPE_WRIST = "wrist",
    INVTYPE_HAND = "hands",
    INVTYPE_WAIST = "waist",
    INVTYPE_LEGS = "legs",
    INVTYPE_FEET = "feet",
    INVTYPE_FINGER = "finger",
    INVTYPE_TRINKET = "trinket",
    INVTYPE_WEAPON = "onehand",
    INVTYPE_2HWEAPON = "twohand",
    INVTYPE_WEAPONMAINHAND = "mainhand",
    INVTYPE_WEAPONOFFHAND = "offhand",
    INVTYPE_HOLDABLE = "held",
    INVTYPE_SHIELD = "shield",
    INVTYPE_RANGED = "ranged",
    INVTYPE_RANGEDRIGHT = "ranged",
    INVTYPE_THROWN = "thrown",
    INVTYPE_RELIC = "relic",
    INVTYPE_BAG = "bag",
    INVTYPE_QUIVER = "bag",
    INVTYPE_AMMO = "ammo",
}

-- Paper-doll order, top-down then weapons, so the Slot dropdown and the
-- "sort by slot" column both read the way a character sheet does rather than
-- alphabetically (Back, Chest, Feet, Finger, Hands, Head... helps nobody).
local EQUIP_SLOT_ORDER = {
    "head", "neck", "shoulder", "back", "chest", "shirt", "tabard",
    "wrist", "hands", "waist", "legs", "feet", "finger", "trinket",
    "onehand", "mainhand", "offhand", "twohand", "held", "shield",
    "ranged", "thrown", "relic", "bag", "ammo",
}
Core.EQUIP_SLOT_ORDER = EQUIP_SLOT_ORDER

local EQUIP_LABELS = {
    head = "Head", neck = "Neck", shoulder = "Shoulder", back = "Back",
    chest = "Chest", shirt = "Shirt", tabard = "Tabard", wrist = "Wrist",
    hands = "Hands", waist = "Waist", legs = "Legs", feet = "Feet",
    finger = "Finger", trinket = "Trinket",
    onehand = "One-Hand", mainhand = "Main Hand", offhand = "Off Hand",
    twohand = "Two-Hand", held = "Held In Off-hand", shield = "Shield",
    ranged = "Ranged", thrown = "Thrown", relic = "Relic",
    bag = "Bag", ammo = "Ammo",
}
Core.EQUIP_LABELS = EQUIP_LABELS

local EQUIP_SLOT_INDEX = {}
for i, key in ipairs(EQUIP_SLOT_ORDER) do EQUIP_SLOT_INDEX[key] = i end

-- Defined up here rather than beside the proficiency tables further down
-- because GetDB reads it, and GetDB comes first.
local playerClass
local function PlayerClass()
    if not playerClass and UnitClass then
        playerClass = select(2, UnitClass("player"))
    end
    return playerClass
end
Core.PlayerClass = PlayerClass

--[[ Sorting BY STAT -- report #308.

     ★ PER-STAT KEYS, NOT A "TOTAL STATS" NUMBER, and that is the whole design
     decision. Summing an item's stats gives a figure with no meaning: 40 Stamina
     + 30 Crit Rating is not "70 good", and the piece that wins such a ranking is
     whichever one spent its budget on the cheapest stats. Worse, the honest
     version of "how much stat is on this item" ALREADY EXISTS and is already a
     column -- that is precisely what item level encodes -- so a totals sort would
     be a noisier duplicate of Level that disagreed with it. Nobody looking at a
     vault full of mythic-bag gear wants "most stats"; they want "my highest
     Strength pieces", which is a question only a per-stat key can answer.

     Values come from GetItemStats, which the 3.3.5a client does export (verified
     in the client binary, along with every ITEM_MOD_* key named below). It needs
     an item LINK and therefore a warm item cache -- see StatsFor.

     ⚠ ARMOUR AND RESISTANCES ARE DELIBERATELY ABSENT. 3.3.5a's GetItemStats has
     no ITEM_MOD_ARMOR and no RESISTANCEn_NAME key -- neither string exists in the
     client at all -- so an "Armor" entry could only ever sort every item as 0.
     An option that silently does nothing is worse than an option that is missing.

     `tokens` is tried in order and the FIRST hit wins, never a sum: the plain and
     _SHORT spellings are two names for one stat, and Spell Power / Spell Damage
     likewise, so adding them would double-count.
]]
local STAT_SORTS = {
    { key = "strength",    label = "Strength",       tokens = { "ITEM_MOD_STRENGTH_SHORT", "ITEM_MOD_STRENGTH" } },
    { key = "agility",     label = "Agility",        tokens = { "ITEM_MOD_AGILITY_SHORT", "ITEM_MOD_AGILITY" } },
    { key = "stamina",     label = "Stamina",        tokens = { "ITEM_MOD_STAMINA_SHORT", "ITEM_MOD_STAMINA" } },
    { key = "intellect",   label = "Intellect",      tokens = { "ITEM_MOD_INTELLECT_SHORT", "ITEM_MOD_INTELLECT" } },
    { key = "spirit",      label = "Spirit",         tokens = { "ITEM_MOD_SPIRIT_SHORT", "ITEM_MOD_SPIRIT" } },
    { key = "ap",          label = "Attack Power",   tokens = { "ITEM_MOD_ATTACK_POWER_SHORT", "ITEM_MOD_ATTACK_POWER" } },
    { key = "sp",          label = "Spell Power",    tokens = { "ITEM_MOD_SPELL_POWER_SHORT", "ITEM_MOD_SPELL_POWER", "ITEM_MOD_SPELL_DAMAGE_DONE", "ITEM_MOD_SPELL_HEALING_DONE" } },
    { key = "crit",        label = "Crit Rating",    tokens = { "ITEM_MOD_CRIT_RATING_SHORT", "ITEM_MOD_CRIT_RATING" } },
    { key = "haste",       label = "Haste Rating",   tokens = { "ITEM_MOD_HASTE_RATING_SHORT", "ITEM_MOD_HASTE_RATING" } },
    { key = "hit",         label = "Hit Rating",     tokens = { "ITEM_MOD_HIT_RATING_SHORT", "ITEM_MOD_HIT_RATING" } },
    { key = "expertise",   label = "Expertise",      tokens = { "ITEM_MOD_EXPERTISE_RATING_SHORT", "ITEM_MOD_EXPERTISE_RATING" } },
    { key = "arp",         label = "Armor Pen",      tokens = { "ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT", "ITEM_MOD_ARMOR_PENETRATION_RATING" } },
    { key = "resilience",  label = "Resilience",     tokens = { "ITEM_MOD_RESILIENCE_RATING_SHORT", "ITEM_MOD_RESILIENCE_RATING" } },
    { key = "defense",     label = "Defense Rating", tokens = { "ITEM_MOD_DEFENSE_SKILL_RATING_SHORT", "ITEM_MOD_DEFENSE_SKILL_RATING" } },
    { key = "dodge",       label = "Dodge Rating",   tokens = { "ITEM_MOD_DODGE_RATING_SHORT", "ITEM_MOD_DODGE_RATING" } },
    { key = "parry",       label = "Parry Rating",   tokens = { "ITEM_MOD_PARRY_RATING_SHORT", "ITEM_MOD_PARRY_RATING" } },
    { key = "block",       label = "Block Value",    tokens = { "ITEM_MOD_BLOCK_VALUE_SHORT", "ITEM_MOD_BLOCK_VALUE" } },
    { key = "mp5",         label = "Mana per 5 sec", tokens = { "ITEM_MOD_POWER_REGEN_SHORT", "ITEM_MOD_POWER_REGEN", "ITEM_MOD_MANA_REGENERATION" } },
}
Core.STAT_SORTS = STAT_SORTS

-- Sort key strings live on the defs themselves so nothing ever spells one out
-- by hand. STAT_BY_SORTKEY is the reverse map the sorters and the UI both read.
local STAT_BY_SORTKEY = {}
for _, def in ipairs(STAT_SORTS) do
    def.sortKey = "stat:" .. def.key
    STAT_BY_SORTKEY[def.sortKey] = def
end
Core.STAT_BY_SORTKEY = STAT_BY_SORTKEY

-- The sort keys SORTERS (defined much further down, after the helpers it needs)
-- actually implements. Duplicated up here for the same reason as PlayerClass:
-- GetDB validates the saved sort and GetDB comes first. Any key added to SORTERS
-- must be added here too, or it will be silently rejected on load and fall back
-- to "recent".
--
-- The stat keys avoid that trap entirely by being GENERATED from STAT_SORTS in
-- both places, here and at SORTERS, so the pair cannot drift no matter how many
-- stats get added. Only the six fixed keys are still written twice, and those
-- have not changed since report #267.
local SORT_KEYS = {
    name = true, level = true, rarity = true, quantity = true,
    slot = true, recent = true,
}
for _, def in ipairs(STAT_SORTS) do
    SORT_KEYS[def.sortKey] = true
end
Core.SORT_KEYS = SORT_KEYS

-- MUST list every category CategoryFor() can return (see CLASS_CAT and
-- SUB_TRADE_CAT below). This is not just the sidebar's row order: BuildGridLayout
-- walks THIS table to emit the grid's buckets, so a category missing here is
-- rendered nowhere in grid view at all -- not even under "All Categories" -- and
-- has no sidebar row to filter by either. "gem" and "glyph" were both mapped in
-- CLASS_CAT and given full SUBCATEGORY_DEFS, a Slot dropdown entry and a
-- SLOT_LABELS label, but never added here, so every gem and every glyph in the
-- Vault was invisible in grid view (reported: "glyphs don't show up at all").
local CATEGORY_ORDER = {
    "all", "weapon", "armor", "ammo", "consumable", "trade", "enchanting",
    "jewelcrafting", "engineering", "leatherworking", "tailoring",
    "cooking", "herbalism", "mining", "gem", "glyph", "recipe", "quest",
    "misc", "other",
}

local CATEGORY_LABELS = {
    all = "All Categories",
    weapon = "Weapons",
    armor = "Armor",
    ammo = "Ammunition",
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

-- ⚠ THESE ARE ITEM *CLASS* IDS AND THE NUMBERING IS A TRAP. Class 6 is
-- PROJECTILE (arrows and bullets); TRADE GOODS is class 7. Mapping 6 to "trade"
-- did not merely put ammo in the wrong bucket -- it made ammo inherit the TRADE
-- subcategory names, which are keyed by subclass. Arrows are subclass 2 and
-- bullets subclass 3, so the Vault confidently filed every arrow you owned under
-- "Explosives" and every bullet under "Devices" (report #296).
-- Class 11 (Quiver) had no entry at all. Quivers are containers rather than
-- ammunition, so they go to misc rather than joining the new category, where
-- their own subclasses (2 = Quiver, 3 = Ammo Pouch) would collide all over again.
local CLASS_CAT = {
    [0] = "consumable",
    [2] = "weapon",
    [3] = "gem",
    [4] = "armor",
    [5] = "trade",
    [6] = "ammo",
    [7] = "trade",
    [9] = "recipe",
    [11] = "misc",
    [12] = "quest",
    [15] = "misc",
    [16] = "glyph",
}

-- Trade-goods SUBCLASS -> its own top-level category, for the ones that clearly
-- belong to one profession. Anything not listed stays under Trade Goods and gets
-- a subcategory from SUBCATEGORY_DEFS.trade instead.
--
-- ⚠ SUBCLASS 11 IS THE CATCH-ALL "OTHER", NOT ENGINEERING (report #315). It used
-- to map here to "engineering", which is why clams were filed as engineering
-- mats -- Small Barnacled Clam, Big-mouth Clam and Thick-shelled Clam are all
-- class 7 subclass 11, along with 173 other unrelated oddments. It now falls
-- through to Trade Goods -> Other, which is exactly what subclass 11 means.
--
-- Engineering instead takes the three subclasses that ARE engineering: Parts,
-- Explosives and Devices. Their defs moved out of SUBCATEGORY_DEFS.trade to
-- SUBCATEGORY_DEFS.engineering to match, or they would have become unreachable
-- entries under a category nothing routes to any more.
local SUB_TRADE_CAT = {
    [1] = "engineering",
    [2] = "engineering",
    [3] = "engineering",
    [4] = "jewelcrafting",
    [5] = "tailoring",
    [6] = "leatherworking",
    [7] = "mining",
    [9] = "herbalism",
    [10] = "trade",
    [12] = "enchanting",
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
        { key = "offhand", label = "Off-Hand", eqs = { offhand = true, held = true } },
        { key = "misc", label = "Miscellaneous", sub = 14 },
        { key = "dagger", label = "Daggers", sub = 15 },
        { key = "thrown", label = "Thrown", sub = 16 },
        { key = "crossbow", label = "Crossbows", sub = 18 },
        { key = "wand", label = "Wands", sub = 19 },
        { key = "fishing", label = "Fishing Poles", sub = 20 },
    },
    armor = {
        { key = "neck", label = "Necklaces", eq = "neck" },
        { key = "finger", label = "Rings", eq = "finger" },
        { key = "trinket", label = "Trinkets", eq = "trinket" },
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
    ammo = {
        { key = "arrow", label = "Arrows", sub = 2 },
        { key = "bullet", label = "Bullets", sub = 3 },
    },
    -- Parts / Explosives / Devices moved here from `trade` with report #315: those
    -- three subclasses now route to Engineering, so leaving their defs under Trade
    -- Goods would have left three entries nothing can ever reach.
    engineering = {
        { key = "parts", label = "Parts", sub = 1 },
        { key = "explosives", label = "Explosives", sub = 2 },
        { key = "devices", label = "Devices", sub = 3 },
    },
    trade = {
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
        classOnly = false,
        sort = "recent",
        sortAsc = false,
    }
    for k, v in pairs(defaults) do
        if db[k] == nil then db[k] = CopyDefault(v) end
    end
    db.viewMode = (db.viewMode == "grid") and "grid" or "list"
    state.viewMode = db.viewMode
    -- Report #267: the chosen sort used to live in `state` only, so every
    -- login reset the vault to "recent" -- picking Rarity fixed the window for
    -- exactly as long as you kept it open, which is a fair part of why it read
    -- as "bit all over". Validated against SORT_KEYS rather than trusted, so a
    -- SavedVariables file written by a newer build (or hand-edited) can't leave
    -- state.sort pointing at a sorter that does not exist here.
    if not SORT_KEYS[db.sort] then db.sort = "recent" end
    db.sortAsc = db.sortAsc and true or false
    state.sort, state.sortAsc = db.sort, db.sortAsc
    -- Saved per ACCOUNT, like everything else in UncappedVaultDB, but the
    -- answer is per CHARACTER: a paladin's "my class only" must not still be
    -- narrowing to plate when you log in on the mage. Stored as the class token
    -- it was set for, and only honoured when that matches who is logged in.
    local cls = PlayerClass()
    state.classOnly = (cls ~= nil and db.classOnly == cls)
    return db
end

function Core.Comma(n)
    local s = tostring(floor(tonumber(n) or 0))
    local k
    repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
    return s
end

--[[
    [#809] Short form for places with no room for the full number.

    The grid cell is 38px and the count label has no width set at all, so a
    six-digit stack runs straight across the neighbouring item. Live vault data at
    the time of writing: 163 stacks over 1,000 and 20 over 10,000, topping out at
    235,345 Silk Cloth -- so the overflow is real today, even though the reporter's
    "1 million" case does not exist yet.

    ★ Threshold is 10,000, NOT 1,000. Below that the comma form is the same width
      and strictly more informative: "1,240" beats "1.2K" in the same space. This
      matches the threshold StatFeed already uses, so the two agree on screen.

    ⚠ Anywhere this is used, the EXACT count must still be reachable -- the
      tooltips carry it. Abbreviating without that just deletes information.
]]
function Core.Abbrev(n)
    local v = floor(tonumber(n) or 0)
    if v < 10000 then
        return Core.Comma(v)
    end

    local units = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
    for _, u in ipairs(units) do
        if v >= u[1] then
            local scaled = v / u[1]
            -- One decimal below 10 (9.4M), none above (94M) -- keeps it to at most
            -- four characters, which is what actually has to fit.
            local fmt = scaled < 10 and "%.1f%s" or "%.0f%s"
            return format(fmt, scaled, u[2])
        end
    end

    return Core.Comma(v)
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

--[[ Equipment slot for a row, resolved once and remembered.

     it.eq is tri-state on purpose:
       nil -- never resolved. The client's item cache had no answer yet, so we
              know nothing. Callers that HIDE things must treat this as "show".
       ""  -- resolved, and the item does not go in an equipment slot at all
              (ore, a potion, a glyph). Cached so trade goods stop re-querying.
       key -- one of EQUIP_SLOT_ORDER.

     GetItemInfo returning nil is the cold-cache signal; an equippable item
     whose cache entry exists always has a non-empty 9th return. Core.EnqueueWarm
     already asks the server for every row's cache entry on snapshot and on
     cache load, so cold is a startup condition, not a steady state -- and the
     warmer's Notify("icons") re-runs Rebuild as answers land, so buckets fill
     in rather than staying wrong. ]]
local function EquipSlotFor(it)
    local cached = it.eq
    if cached ~= nil then
        if cached == "" then return nil end
        return cached
    end

    local name, _, _, _, _, _, _, _, equipLoc = GetItemInfo(it.e)
    if not name then return nil end

    it.eq = EQUIP_FROM_INVTYPE[equipLoc or ""] or ""
    Core.cacheDirty = true
    if it.eq == "" then return nil end
    return it.eq
end
Core.EquipSlotFor = EquipSlotFor

--[[ "Only what my class can use."

     Report #218 is a GEARING request ("would make gearing up from mythic bags
     a lot easier"), and the biggest single cut is the three armour types the
     player will never equip. This narrows exactly three item classes -- weapons,
     armour, glyphs -- and nothing else. A filter that also hid your ore would
     not be a gearing filter, it would be the next bug report.

     Deliberately class PROFICIENCY, not "spec". A fury warrior sees every
     weapon a warrior can hold, because the alternative is guessing at builds. ]]
--[[ Armour subclass: 1 cloth, 2 leather, 3 mail, 4 plate.

     TWO entries per class, because armour proficiency is LEARNED, not innate --
     report #234, a level 19 hunter shown mail he cannot wear until 40. Warriors,
     paladins and death knights train plate at 40; hunters and shamans train mail
     at 40. Until then they wear the tier below, and a filter called "only gear I
     can use" that shows them the tier above is lying.

     Death knights start at 55 so their `early` value is unreachable in practice;
     it is filled in rather than left nil so nobody has to wonder whether the
     omission was deliberate. ]]
local ARMOR_TRAIN_LEVEL = 40
local ARMOR_SPEC = {
    WARRIOR = 4, PALADIN = 4, DEATHKNIGHT = 4,
    HUNTER = 3, SHAMAN = 3,
    ROGUE = 2, DRUID = 2,
    MAGE = 1, WARLOCK = 1, PRIEST = 1,
}
local ARMOR_SPEC_EARLY = {
    WARRIOR = 3, PALADIN = 3, DEATHKNIGHT = 3,
    HUNTER = 2, SHAMAN = 2,
    ROGUE = 2, DRUID = 2,
    MAGE = 1, WARLOCK = 1, PRIEST = 1,
}

-- The armour tier this character can actually wear right now.
local function ArmorSpecFor(class)
    if (UnitLevel("player") or 0) >= ARMOR_TRAIN_LEVEL then
        return ARMOR_SPEC[class]
    end
    return ARMOR_SPEC_EARLY[class]
end

--[[ Required level, cached onto the row exactly like it.eq above.

     GetItemInfo's 5th return is minLevel. Same contract as the equip-slot cache:
     a nil answer means the item cache has not replied YET, not that the item has
     no requirement -- so it is stored as 0 (no requirement) only once GetItemInfo
     has actually answered, and until then callers must not hide anything. ]]
local function MinLevelFor(it)
    local cached = it.rl
    if cached ~= nil then return cached end

    local name, _, _, _, minLevel = GetItemInfo(it.e)
    if not name then return nil end

    it.rl = tonumber(minLevel) or 0
    Core.cacheDirty = true
    return it.rl
end
Core.MinLevelFor = MinLevelFor

-- Armour subclasses 7-10 are the class relic slots; each belongs to exactly one.
local RELIC_SUB = { PALADIN = 7, DRUID = 8, SHAMAN = 9, DEATHKNIGHT = 10 }
local SHIELD_CLASSES = { WARRIOR = true, PALADIN = true, SHAMAN = true }

-- Glyph subclass IS the class id, which is why glyphs get to play here at all.
local GLYPH_CLASS_ID = {
    WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4, PRIEST = 5,
    DEATHKNIGHT = 6, SHAMAN = 7, MAGE = 8, WARLOCK = 9, DRUID = 11,
}

local function Prof(...)
    local t = {}
    for i = 1, select("#", ...) do t[select(i, ...)] = true end
    return t
end

-- Weapon subclass ids, 3.3.5a: 0 axe1, 1 axe2, 2 bow, 3 gun, 4 mace1, 5 mace2,
-- 6 polearm, 7 sword1, 8 sword2, 10 staff, 13 fist, 15 dagger, 16 thrown,
-- 18 crossbow, 19 wand.
local WEAPON_PROFICIENCY = {
    WARRIOR     = Prof(0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 13, 15, 16, 18),
    PALADIN     = Prof(0, 1, 4, 5, 6, 7, 8),
    HUNTER      = Prof(0, 1, 2, 3, 6, 7, 8, 10, 13, 15, 16, 18),
    ROGUE       = Prof(0, 2, 3, 4, 7, 13, 15, 16, 18),
    PRIEST      = Prof(4, 10, 15, 19),
    DEATHKNIGHT = Prof(0, 1, 4, 5, 6, 7, 8),
    SHAMAN      = Prof(0, 1, 4, 5, 10, 13, 15),
    MAGE        = Prof(7, 10, 15, 19),
    WARLOCK     = Prof(7, 10, 15, 19),
    DRUID       = Prof(4, 5, 6, 10, 13, 15),
}

local function IsRelevantToPlayer(it)
    local class = PlayerClass()
    if not class then return true end

    local cls = tonumber(it.cls) or 15
    local sub = tonumber(it.sub) or 0

    --[[ LEVEL FIRST, and it applies to every class of item, not just gear.

         Report #234: a level 19 hunter had "only gear I can use" on and was still
         shown every high-level weapon in the vault. Proficiency was the only test,
         so a level 1 rogue and a level 80 rogue saw an identical list.

         Deliberately NOT gated on cls, because a required level means the same
         thing on a weapon, a piece of armour and a use-item.

         nil means GetItemInfo has not answered yet -- never hide on a
         not-yet-known answer, same rule the armour branch already follows for
         it.eq. Hiding something the player owns because a cache was cold is the
         one failure this toggle must not have. ]]
    local minLevel = MinLevelFor(it)
    if minLevel and minLevel > (UnitLevel("player") or 0) then
        return false
    end

    if cls == 16 then
        local id = GLYPH_CLASS_ID[class]
        return (not id) or sub == id
    end

    if cls == 2 then
        local prof = WEAPON_PROFICIENCY[class]
        if not prof then return true end
        -- 14 miscellaneous and 20 fishing poles are not class-gated.
        if sub == 14 or sub == 20 then return true end
        return prof[sub] == true
    end

    if cls == 4 then
        --[[ Slot decides before subclass, and it has to.

             A cloak is armour subclass CLOTH and a ring/neck/trinket is armour
             subclass MISC, so judging armour by subclass alone would hide every
             cloak in the vault from a paladin -- the exact "my gear vanished"
             failure this toggle must not have. ]]
        local eq = EquipSlotFor(it)
        -- Never hide what we could not judge: nil eq here means the item cache
        -- has not answered yet, not that the item has no slot (that is "").
        if it.eq == nil then return true end
        if eq == "back" or eq == "neck" or eq == "finger" or eq == "trinket" then return true end

        if sub == 0 then return true end
        if sub == 6 then return SHIELD_CLASSES[class] == true end
        if sub >= 7 and sub <= 10 then return RELIC_SUB[class] == sub end
        -- ArmorSpecFor, not ARMOR_SPEC: a hunter is leather until 40 (report #234).
        return ArmorSpecFor(class) == sub
    end

    return true
end
Core.IsRelevantToPlayer = IsRelevantToPlayer

local function SubcategoryFor(it, cat)
    local defs = SUBCATEGORY_DEFS[cat]
    if not defs then return "all" end

    -- Slot-keyed buckets (necks/rings/trinkets, and off-hands which span two
    -- equip locations) win over subclass-keyed ones, since a ring's armour
    -- subclass is only ever MISC.
    if cat == "armor" or cat == "weapon" then
        local eq = EquipSlotFor(it)
        if eq then
            for i = 1, #defs do
                if defs[i].eq == eq then return defs[i].key end
                if defs[i].eqs and defs[i].eqs[eq] then return defs[i].key end
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

-- Is the vault window actually on screen? Resolved defensively: the UI half is a
-- separate file and may not have registered yet, and a nil here must mean
-- "assume hidden and be cheap", never an error on the update path.
--
-- ★ [DE-06] Moved up here from the flusher block. It has no load-time
-- dependency of its own (Core.UI is populated at runtime by RegisterUI), and
-- both callers that need it -- the flusher AND the item-cache warmer -- now sit
-- on opposite sides of Notify. One definition, not two that can drift.
local function VaultWindowShown()
    local ui = Core.UI
    if not ui then return false end
    if type(ui.IsShown) == "function" then
        local ok, shown = pcall(ui.IsShown)
        if ok then return shown and true or false end
    end
    local f = ui.frame
    if f and type(f.IsShown) == "function" then return f:IsShown() and true or false end
    return false
end

--[[ ★★ [DE-05] THE NARROWING FAST PATH.

     Set by Core.SetQuery when the new query is the old one plus more characters,
     and consumed by the very next Core.Rebuild. Nothing else ever sets it, so
     every other rebuild -- a snapshot, a deposit, a withdraw, a name arriving from
     the item cache, a category click -- takes the full pass exactly as before.

     The invariant it rests on, stated out loud because breaking it shows the
     player a WRONG LIST rather than an error:

       Core.filtered was built from the CURRENT value of every filter except the
       query, and from `narrowFrom` as the query.

     That holds because SetQuery is the only thing that changes the query, it
     changes nothing else, and it sets narrowFrom and calls Notify in the same
     synchronous breath -- no frame boundary, no event, nothing can run between.
     ⚠ If SetQuery is ever made to defer its Notify, narrowFrom must be cleared
       rather than carried across the gap.

     Why it is worth having: a longer query can only ever REMOVE rows. The match is
     a plain substring test, so if the old query is a prefix of the new one, any
     name containing the new one already contained the old one. The new result set
     is therefore a subset of the old one IN THE SAME ORDER -- no re-count, no
     re-categorise, and above all NO RE-SORT. ]]
local narrowFrom = nil

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
    local nq = lower(q or "")
    -- ⚠ EditBox:SetText fires OnTextChanged even when the text did not change, and
    --   this window's own Escape handler does exactly that. Without this guard a
    --   bare Escape on an already-empty box cost a full rebuild of a 4,000-row vault.
    if nq == (state.query or "") then return end

    -- Only ever a STRICT extension: "fro" -> "fros" narrows; "fros" -> "fro" (a
    -- backspace) and "fro" -> "ice" (a paste) do not, and take the full pass.
    -- Extending "" counts -- the previous set was everything, so the first
    -- character of a query narrows from it just as well as the fifth does.
    local old = state.query or ""
    narrowFrom = (#nq > #old and strsub(nq, 1, #old) == old) and old or nil

    state.query = nq
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
    state.equipSlot = "all"
    state.page = 1
    Notify("filter")
end

function Core.SetQuality(q)
    state.quality = tonumber(q) or -1
    state.page = 1
    Notify("filter")
end

function Core.SetEquipSlot(slot)
    state.equipSlot = slot or "all"
    state.page = 1
    Notify("filter")
end

--[[ Deliberately defaults OFF and is not sticky across classes.

     The tempting default is ON -- a paladin genuinely does not care about
     cloth. But this is a STORAGE window, and a storage window that silently
     shows you less than you put in it reads as data loss, not as a filter.
     People also gear alts out of this vault, which is the case that makes
     "hide what you cannot wear" wrong by default.

     The compromise is that when it IS on, Core.hiddenByClass carries the count
     it removed so the footer can say so out loud. ]]
function Core.SetClassOnly(on)
    on = on and true or false
    -- Written to the DB BEFORE state, because GetDB re-derives state.classOnly
    -- from the stored value on its way out and would otherwise clobber this.
    -- Stored as the class token so it cannot leak onto another character; false
    -- rather than nil when off, so the default merge leaves it alone.
    Core.GetDB().classOnly = on and (PlayerClass() or false) or false
    state.classOnly = on
    state.page = 1
    Notify("filter")
end

function Core.ToggleClassOnly()
    Core.SetClassOnly(not state.classOnly)
end

-- Clicking the column you are already sorted by flips the direction; clicking
-- any other column switches to it, descending (= "best first" for every key
-- except name).
--
-- GetDB is called FIRST and deliberately: it re-derives state.sort/sortAsc from
-- the stored values on its way out, so calling it after deciding would quietly
-- undo the decision -- the same trap SetClassOnly documents.
function Core.SetSort(key)
    local db = Core.GetDB()
    local sort, asc
    if state.sort == key then
        sort, asc = state.sort, not state.sortAsc
    else
        sort, asc = (SORT_KEYS[key] and key or "recent"), false
    end
    db.sort, db.sortAsc = sort, asc
    state.sort, state.sortAsc = sort, asc
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

Core.gridPages = Core.gridPages or {}

local GRID_ROW_PX  = 44   -- GRID_SLOT (38) + GRID_GAP (6)
local GRID_HEAD_PX = 36   -- GRID_HEADER_H (30) + GRID_GAP (6)

-- Page boundaries for the grid, walked exactly the way RefreshGrid draws.
--
-- This used to be a single gridPageSize: a flat rows*cols CELL count that the
-- pager then used to slice gridLayout, which is a list of ENTRIES. Those are not
-- the same unit. Category headers are entries that occupy no cell -- a header
-- closes whatever row is in progress and then takes a full-width line of its
-- own -- so a page budgeted for rows*cols cells was handed rows*cols entries and
-- drew far more rows than fit. The overflow ran off the bottom of the panel
-- (and off the screen on a maximised window), and because one "page" now
-- swallowed the whole vault, PageCount came back as 1 and there was nothing to
-- turn to. Both halves of report #130 are that one unit mismatch.
--
-- Cost each entry in PIXELS instead, mirroring RefreshGrid's own cursor, and
-- keep real per-page boundaries rather than a size.
function Core.BuildGridPages()
    local pages = Core.gridPages
    while #pages > 0 do tremove(pages) end

    local cols  = max(1, state.gridCols or 1)
    local avail = max(GRID_ROW_PX, state.gridAvail or GRID_ROW_PX)
    local n = #Core.gridLayout
    if n == 0 then
        pages[1] = { 1, 0 }
        return
    end

    local i = 1
    while i <= n do
        local first = i
        local y, col = 0, 0          -- y: rows already closed; col: row in progress
        while i <= n do
            local e = Core.gridLayout[i]
            local ny, ncol = y, col
            if e.header then
                if ncol > 0 then ny = ny + GRID_ROW_PX; ncol = 0 end
                ny = ny + GRID_HEAD_PX
            else
                ncol = ncol + 1
                if ncol >= cols then ny = ny + GRID_ROW_PX; ncol = 0 end
            end
            local used = ny + (ncol > 0 and GRID_ROW_PX or 0)
            if i > first and used > avail then break end
            y, col = ny, ncol
            i = i + 1
        end
        -- A lone entry taller than the whole budget still has to land
        -- somewhere, or this loops forever on it.
        if i == first then i = first + 1 end
        pages[#pages + 1] = { first, i - 1 }
    end
end

-- Grid metrics from the UI, in the units the layout actually uses: icon columns
-- across, and pixels of vertical room a page has.
function Core.SetGridMetrics(cols, availPx)
    cols = math.floor(tonumber(cols) or 0)
    availPx = math.floor(tonumber(availPx) or 0)
    if cols < 1 then cols = 1 end
    if availPx < GRID_ROW_PX then availPx = GRID_ROW_PX end
    if cols == state.gridCols and availPx == state.gridAvail then return end
    state.gridCols, state.gridAvail = cols, availPx
    Core.BuildGridPages()
    state.page = max(1, min(Core.PageCount(), state.page))
    Notify("pagesize")
end

local SORTERS = {
    name = function(a, b)
        local an, bn = ResolveName(a), ResolveName(b)
        if an == bn then return (a.e or 0) < (b.e or 0) end
        return an < bn
    end,
    --[[ Report #267: "organise by level as well as rarity -- at the moment
         bit all over".

         Rarity and level are not competing sorts, they are one ordering with
         two keys, and the missing piece was only ever the tiebreak. Sorting by
         Rarity used to fall through to NAME inside a quality band, so a vault
         full of epics came out alphabetical -- an ilvl 284 helm sitting under
         an ilvl 80 one because A comes before R. Rarity now breaks ties on item
         level, and Level breaks ties on rarity, so whichever column you click
         the other is still doing useful work and both read as "best first".

         ilvl is already on the wire (the 8-field VLT row -- see ParseRows), so
         this costs nothing extra to fetch. Items the server reports at 0 (a
         handful of legacy rows) sort to the bottom of their band rather than
         disappearing. ]]
    level = function(a, b)
        if (a.ilvl or 0) ~= (b.ilvl or 0) then return (a.ilvl or 0) > (b.ilvl or 0) end
        if (a.q or 0) ~= (b.q or 0) then return (a.q or 0) > (b.q or 0) end
        return ResolveName(a) < ResolveName(b)
    end,
    rarity = function(a, b)
        if (a.q or 0) ~= (b.q or 0) then return (a.q or 0) > (b.q or 0) end
        if (a.ilvl or 0) ~= (b.ilvl or 0) then return (a.ilvl or 0) > (b.ilvl or 0) end
        return ResolveName(a) < ResolveName(b)
    end,
    quantity = function(a, b)
        if (a.c or 0) ~= (b.c or 0) then return (a.c or 0) > (b.c or 0) end
        return ResolveName(a) < ResolveName(b)
    end,
    -- Sorts by real equipment slot in paper-doll order first (head, neck,
    -- shoulder, ...), so "sort by slot" on a pile of mythic-bag gear actually
    -- groups the helms together. Items with no slot fall to the end and keep
    -- the old type-name ordering among themselves.
    slot = function(a, b)
        local ai = EQUIP_SLOT_INDEX[EquipSlotFor(a) or ""] or 999
        local bi = EQUIP_SLOT_INDEX[EquipSlotFor(b) or ""] or 999
        if ai ~= bi then return ai < bi end
        local as, bs = SlotFor(a), SlotFor(b)
        if as ~= bs then return as < bs end
        if (a.ilvl or 0) ~= (b.ilvl or 0) then return (a.ilvl or 0) > (b.ilvl or 0) end
        return ResolveName(a) < ResolveName(b)
    end,
    recent = function(a, b)
        return (a.added or 0) > (b.added or 0)
    end,
}

--[[ Stat lookup for a row, memoised per (entry, random property).

     NOT stored on the row and NOT persisted, unlike it.eq and it.rl. Those are
     one scalar each; this is a whole table per item, and writing a thousand of
     them into SavedVariables every session would cost far more than recomputing
     them -- GetItemStats is a local call against a cache the warmer already
     fills. The values are also a pure function of (entry, suffix), so nothing
     about them can go stale while the client runs.

     Tri-state, exactly like EquipSlotFor:
       nil    -- never asked
       false  -- asked while the client's item cache was cold. NOT "no stats":
                 the answer is unknown, and it is retried once the warmer has an
                 entry (see the invalidation in the warmer's OnUpdate).
       table  -- the client's answer, possibly empty for ore and potions.

     ⚠ MEMOISING THE COLD CASE IS LOAD-BEARING, not just a speed-up. table.sort
     raises "invalid order function for sorting" if a comparator's answers change
     underneath it, and an item cache entry can land at any moment. Freezing each
     row's value for the duration of a sort makes that impossible; the warmer only
     clears memos from its own OnUpdate, never mid-comparison. ]]
local statMemo = {}

local function StatsFor(it)
    local e = it.e
    if not e or e <= 0 then return false end

    local rp = tonumber(it.rp) or 0
    local perEntry = statMemo[e]
    if perEntry then
        local memo = perEntry[rp]
        if memo ~= nil then return memo end
    else
        perEntry = {}
        statMemo[e] = perEntry
    end

    -- GetItemStats wants a LINK, and a link only means anything once the client
    -- has the entry cached -- GetItemInfo returning nil is that signal, the same
    -- one EquipSlotFor and MinLevelFor use.
    local name, link = GetItemInfo(e)
    if not name then
        perEntry[rp] = false
        return false
    end

    --[[ Suffixed rows get a link built by hand rather than GetItemInfo's, which
         always describes suffix 0. The suffix's own stats are derived by the
         client from the suffix id and the item's stat budget, so the trailing
         uniqueId (a server-side seed) is genuinely not needed and 0 is correct.

         If a client ever declines to read the hand-built link, the fallback is
         the item's BASE stats, which is a mildly wrong ordering rather than a
         broken one -- worth knowing, since it is the part of this that is not
         verified in game. ]]
    if rp ~= 0 then
        link = format("item:%d:0:0:0:0:0:%d:0", e, rp)
    end

    local ok, stats = pcall(GetItemStats, link)
    if not ok or type(stats) ~= "table" then stats = false end
    perEntry[rp] = stats
    return stats
end

-- 0 for "this item does not have that stat" AND for "we do not know yet". Both
-- sort to the bottom of the list, which is the same treatment ilvl 0 already
-- gets, and unknowns correct themselves as the warmer fills the item cache.
local function StatValueFor(it, sortKey)
    local def = STAT_BY_SORTKEY[sortKey]
    local stats = def and StatsFor(it)
    if not stats then return 0 end

    for i = 1, #def.tokens do
        local v = stats[def.tokens[i]]
        if v then return tonumber(v) or 0 end
    end
    return 0
end
Core.StatValueFor = StatValueFor

-- Generated from the same table SORT_KEYS was, so a stat can never be offered
-- without a sorter behind it or given a sorter the saved-preference check will
-- reject. Ties fall through to item level and then rarity, matching what report
-- #267 established for every other column: whichever key you picked, the others
-- keep doing useful work rather than dumping you into alphabetical order.
for _, def in ipairs(STAT_SORTS) do
    local sortKey = def.sortKey
    SORTERS[sortKey] = function(a, b)
        local av, bv = StatValueFor(a, sortKey), StatValueFor(b, sortKey)
        if av ~= bv then return av > bv end
        if (a.ilvl or 0) ~= (b.ilvl or 0) then return (a.ilvl or 0) > (b.ilvl or 0) end
        if (a.q or 0) ~= (b.q or 0) then return (a.q or 0) > (b.q or 0) end
        return ResolveName(a) < ResolveName(b)
    end
end

--[[ Grid buckets.

     Headers used to be top-level categories and only that, so drilling into
     Armor gave one "Armor" header and then an undifferentiated wall of icons --
     precisely the "comb through it all" report #218 describes, just in icon
     form. When a category with subcategories is selected and no single
     subcategory is pinned, bucket by SUBCATEGORY instead, so Armor shows
     Plate / Mail / Leather / Cloth / Rings / Trinkets headers.

     The page pager below costs entries in pixels and treats any header the
     same, so emitting more of them needs nothing from it. ]]
local function BuildGridLayout()
    local grid = Core.gridLayout
    while #grid > 0 do tremove(grid) end

    --[[ ★ [DE-05] NO SORT HERE. There used to be one and it could never change
         anything: Core.Rebuild sorts Core.filtered with this exact comparator
         immediately before calling us, and the buckets below are filled by walking
         Core.filtered in order -- so every bucket arrives already sorted. It was a
         second full O(n log n) pass per rebuild, over the same data, for the same
         answer.

         ⚠ It was also mildly HARMFUL: table.sort is not stable, so re-sorting an
           already-sorted list could permute rows the comparator calls equal and
           leave grid view in a different order from list view. Dropping it makes
           the two agree.

         ⚠ If BuildGridLayout ever gains a caller that has not sorted Core.filtered
           first, this has to come back. Today Core.Rebuild is the only one. ]]
    local function Emit(key, label, bucket)
        if not bucket or #bucket == 0 then return end
        grid[#grid + 1] = { header = true, key = key, label = label, count = #bucket }
        for i = 1, #bucket do
            grid[#grid + 1] = { item = bucket[i] }
        end
    end

    local cat = state.category or "all"
    local defs = (state.subcategory or "all") == "all" and SUBCATEGORY_DEFS[cat] or nil

    if defs then
        local bySub = {}
        for _, it in ipairs(Core.filtered) do
            local key = SubcategoryFor(it, cat)
            local bucket = bySub[key]
            if not bucket then bucket = {}; bySub[key] = bucket end
            bucket[#bucket + 1] = it
        end
        for _, def in ipairs(defs) do
            Emit(def.key, def.label, bySub[def.key])
            bySub[def.key] = nil
        end
        -- SubcategoryFor's catch-all bucket. Nothing in SUBCATEGORY_DEFS claims
        -- it, so without this it would render nowhere -- the same way gems and
        -- glyphs went invisible when they were missing from CATEGORY_ORDER.
        Emit("other", "Other", bySub.other)
        return
    end

    local byCategory = {}
    for _, it in ipairs(Core.filtered) do
        local key = CategoryFor(it)
        local bucket = byCategory[key]
        if not bucket then bucket = {}; byCategory[key] = bucket end
        bucket[#bucket + 1] = it
    end

    for _, key in ipairs(CATEGORY_ORDER) do
        if key ~= "all" then
            Emit(key, CATEGORY_LABELS[key] or key, byCategory[key])
        end
    end
end

function Core.Rebuild()
    local q = state.query or ""

    --[[ [DE-05] The narrowing fast path -- see the note above Notify.

         Everything the full pass below computes EXCEPT `filtered` is
         query-independent: totalItems, spaceUsed, hiddenByClass, the sidebar
         counts, the subcategory counts, the Slot dropdown's contents and
         Core.categories are all accumulated ABOVE the query test and are
         identical for "fro" and "fros". So a narrowing keystroke needs to prune
         the existing result set and rebuild the grid layout, and nothing else --
         no walk of Core.items, no counting, and no sort, because removing rows
         from a sorted list leaves it sorted.

         The equipSlot auto-reset further down cannot fire here for the same
         reason: it keys off eqCounts, which a query cannot change.

         ⚠ The grid build is gated on view mode for the same reason it is at the
           tail of the full pass -- see the [DE-08] note there. ]]
    local narrow = narrowFrom
    narrowFrom = nil
    if narrow and q ~= "" then
        local filtered = Core.filtered
        local keep = 0
        for i = 1, #filtered do
            local it = filtered[i]
            if lower(ResolveName(it)):find(q, 1, true) then
                keep = keep + 1
                filtered[keep] = it
            end
        end
        for _ = #filtered, keep + 1, -1 do tremove(filtered) end

        if state.viewMode == "grid" then
            BuildGridLayout()
            Core.BuildGridPages()
        end
        local pages = Core.PageCount()
        if state.page > pages then state.page = pages end
        return
    end

    local category = state.category or "all"
    local subcategory = state.subcategory or "all"
    local quality = tonumber(state.quality) or -1
    local equipSlot = state.equipSlot or "all"
    local classOnly = state.classOnly and true or false
    local filtered = Core.filtered
    while #filtered > 0 do tremove(filtered) end

    Core.totalItems, Core.spaceUsed = 0, 0
    Core.hiddenByClass = 0
    local counts = {}
    local subCounts = {}
    -- Which equipment slots this vault actually contains, so the Slot dropdown
    -- can offer only those. Twenty-five dead menu entries on an account that
    -- banked nothing but ore is not a sub-section, it is a wall.
    local eqCounts = {}
    for _, key in ipairs(CATEGORY_ORDER) do counts[key] = 0 end
    for _, it in ipairs(Core.items) do
        local name = ResolveName(it)
        local cat = CategoryFor(it)
        local subcat = SubcategoryFor(it, cat)
        local eq = EquipSlotFor(it)
        local count = tonumber(it.c) or 0
        Core.totalItems = Core.totalItems + count
        Core.spaceUsed = Core.spaceUsed + 1

        --[[ classOnly is a HIDE, not a filter, so it is applied here -- above
             the counting -- rather than alongside query/quality/slot below.

             The sidebar counts have to agree with what the sidebar shows. If
             this were just another clause in the filter test, a paladin with
             "my class only" on would see "Armor 412" in the sidebar and 96 rows
             in the table, and the first thing anyone does with that is report
             it as a counting bug. ]]
        if classOnly and not IsRelevantToPlayer(it) then
            Core.hiddenByClass = Core.hiddenByClass + count
        else
            counts.all = (counts.all or 0) + count
            counts[cat] = (counts[cat] or 0) + count
            subCounts[cat] = subCounts[cat] or {}
            subCounts[cat][subcat] = (subCounts[cat][subcat] or 0) + count
            if eq then eqCounts[eq] = (eqCounts[eq] or 0) + count end

            if (q == "" or lower(name):find(q, 1, true))
                and (category == "all" or category == cat)
                and (subcategory == "all" or subcategory == subcat)
                and (quality < 0 or (it.q or 0) == quality)
                and (equipSlot == "all" or eq == equipSlot) then
                filtered[#filtered + 1] = it
            end
        end
    end

    -- Rebuilt in place: the UI's dropdown reads this list every refresh.
    local eqRows = Core.equipSlots or {}
    Core.equipSlots = eqRows
    while #eqRows > 0 do tremove(eqRows) end
    for _, key in ipairs(EQUIP_SLOT_ORDER) do
        if eqCounts[key] then
            eqRows[#eqRows + 1] = { key = key, label = EQUIP_LABELS[key] or key, count = eqCounts[key] }
        end
    end
    -- A slot the player has filtered down to can still empty out (they emptied
    -- it, or turned "my class only" on). Drop back to All rather than leaving
    -- the window stuck on a selection with no way to tell it is stuck.
    if equipSlot ~= "all" and not eqCounts[equipSlot] then
        state.equipSlot = "all"
        state.page = 1
        -- One re-run, never a loop: the pass below cannot take this branch
        -- again now that the selection is "all".
        return Core.Rebuild()
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

    -- ★ [DE-08] Grid layout only in grid view.
    --
    -- BuildGridLayout buckets every filtered row, RE-SORTS every bucket with
    -- the comparator Rebuild just used, and allocates one fresh table per
    -- item -- and nothing reads any of it unless viewMode is "grid" (list is
    -- the default). It ran on every Rebuild, so it doubled the sort cost and
    -- added N table allocations to every filter, sort and live update for the
    -- majority of players, compounding every other Rebuild cost.
    --
    -- Switching view goes through Core.SetViewMode -> Notify -> Rebuild with
    -- viewMode already set, so entering grid always builds a fresh layout.
    if state.viewMode == "grid" then
        BuildGridLayout()
        Core.BuildGridPages()
    end
    local pages = Core.PageCount()
    if state.page > pages then state.page = pages end
end

function Core.PageCount()
    if state.viewMode == "grid" then
        return max(1, #Core.gridPages)
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
    local out = {}
    local bounds = Core.gridPages[state.page]
    if not bounds then return out end
    for i = bounds[1], bounds[2] do
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
--[[ `queried` maps entry -> the GetTime() at which we asked the server for it,
     NOT a plain "asked already" boolean.

     ★ IT USED TO BE A BOOLEAN THAT WAS NEVER CLEARED, and that is what made a
     lost answer permanent. One CMSG_ITEM_QUERY_SINGLE went out per entry per
     session; if the reply never came back the row stayed `item 54581` for the
     rest of the session and no amount of reopening the window would re-ask.

     A timestamp lets the warmer notice an answer that never arrived and ask
     again (QUERY_TIMEOUT below), so a dropped reply heals itself. ]]
local queried, pending, warmQueue = {}, {}, {}
local iconsDirty = false
local staging = {}

local function EnqueueWarm(e)
    if pending[e] or GetItemInfo(e) then return end
    pending[e] = true
    warmQueue[#warmQueue + 1] = e
end
Core.EnqueueWarm = EnqueueWarm

--[[ ★ [DE-07] O(1) row lookup.

     FindRow used to be a linear scan over the whole vault, and it is called
     ONCE PER ROW inside the VLTROWUPD loop, the VLTUPD loop and VLTWDONE. A
     burst during a pull -- several rows per message, many messages a second --
     was therefore k x N field comparisons per second on the UI thread over a
     4,000-row table, and none of it was covered by the flush coalescer: the
     coalescer defers SaveCache/Push/Notify, the scan runs inline on the frame
     the message lands.

     Kept honest by construction rather than by discipline:
       - the index is LAZY. nil means "stale", and the next FindRow rebuilds
         it. Bulk paths (ClearItems, snapshot refill, cache load) just drop it
         and pay one rebuild.
       - single appends patch it in place, so a VLTROWUPD loop that adds a row
         and then looks another one up does not rebuild per iteration.
       - removals drop it. They are rare (a stack hitting zero) and the tremove
         they accompany is O(N) anyway.
     e/rp never change on a live row -- only `c` does -- so a key cannot go
     stale under a row that is still in the table. ]]
local rowIndex   -- nil = stale, rebuilt on next FindRow

local function RowKey(e, rp) return (e or 0) .. ":" .. (rp or 0) end

local function InvalidateRowIndex() rowIndex = nil end

local function IndexRow(it)
    if rowIndex and it then rowIndex[RowKey(it.e, it.rp or 0)] = it end
end

local function ClearItems()
    while #Core.items > 0 do tremove(Core.items) end
    InvalidateRowIndex()
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
        -- Resolved equipment slot ("head", "" for unequippable, nil for
        -- not-yet-known). Saved with the row so a returning player gets the
        -- slot sub-sections populated on the very first frame instead of
        -- watching them fill in as the item cache warms.
        eq = it.eq,
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
    local db = Core.GetDB()
    db.cacheVersion = CACHE_VERSION
    db.cacheSavedAt = nil
    db.cachedItems = {}
    Core.cacheLoaded = false
    Core.cacheDirty = false
end

function Core.LoadCache()
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
    -- Also push on the CACHED path, not just after a fresh snapshot. A login
    -- with a valid SavedVariables cache requests no snapshot at all, so without
    -- this the client-side counts would stay empty for the whole session.
    -- Resolved through Core because the function is defined further down.
    if Core.PushVaultCountsToClient then Core.PushVaultCountsToClient() end
    Notify("cache")
    -- Same reason as in FinalizeSnapshot: Rebuild resolved equipment slots for
    -- rows saved before that field existed, and they are worth keeping.
    if Core.cacheDirty then Core.SaveCache() end
    return true
end

--[[ ★★ THE WARMER IS CLOSED-LOOP. It never has more than MAX_INFLIGHT questions
     outstanding at once, and it only asks a new one when an old one has been
     answered (or has timed out).

     It used to be OPEN-loop: 10 queries every 0.2s, unconditionally, until the
     queue was empty. That is 50 CMSG_ITEM_QUERY_SINGLE per second sustained,
     and it is what broke the Vault for the accounts that use it most.

     The arithmetic, from report "withdrew an item and it is stuck on
     'Retrieving item information'":

       * The launcher wipes Cache\WDB on EVERY launch (WdbCleaner -- the cache is
         keyed by entry id and is not namespaced per realm, so another server's
         item 900400 would silently become ours). So the client starts every
         session knowing NOTHING about any item, and a 3,901-row vault is 3,901
         cold entries.
       * Server-side, WorldSession::Update answers at most 150 packets per
         session per world tick. At a healthy ~50ms tick that is ~3,000/s and the
         old warmer's 50/s was invisible. At the 8s tick the realm is running
         right now it collapses to ~19/s -- and that 150 is shared with movement,
         spells and chat.
       * So the warmer was posting 50 questions a second into a pipe answering
         19, and the backlog only grew. The item you just WITHDREW is queued
         behind those thousands of pending questions, so its tooltip sits on
         "Retrieving item information..." for minutes. Same single cause as the
         `item 54581` placeholder names in the window itself -- there is only one
         failure here, not two.

     Bounding the outstanding set fixes both regimes at once. On a healthy server
     answers land within a frame or two, so MAX_INFLIGHT clears every pass and
     throughput is ~100/s -- FASTER than the old 50/s. On a struggling one it
     self-paces down to whatever the server can actually answer, which leaves the
     client's OWN queries (the bag item you just withdrew) near the front of the
     queue instead of behind 3,900 of ours.

     ⚠ Do not "optimise" this back into an unconditional fire loop. The whole
     point is that the rate is set by the ANSWERS, not by our timer. ]]
local MAX_INFLIGHT = 20

--[[ Re-ask after this long with no answer.

     Deliberately generous. It is a recovery path for an answer that was genuinely
     dropped (a query posted while the player was mid-map-transfer is discarded
     server-side once WorldSession::Update's hold buffer is full), not a
     retransmit timer -- a slow server must be allowed to be slow, or a retry
     storm makes the queue it is stuck behind longer. ]]
local QUERY_TIMEOUT = 20

local warmer = CreateFrame("Frame")
local warmAcc = 0
warmer:SetScript("OnUpdate", function(_, dt)
    if #warmQueue == 0 then return end
    warmAcc = warmAcc + (dt or arg1 or 0)
    if warmAcc < 0.2 then return end
    warmAcc = 0

    local now = GetTime and GetTime() or 0

    --[[ Count what is still outstanding, and expire anything past the timeout so
         it becomes askable again. Counted fresh each pass rather than tracked as
         a running total: an entry leaves the outstanding set by being ANSWERED,
         which happens in the loop below, and a counter maintained across passes
         would drift the first time a row was removed by any other path. ]]
    local inflight = 0
    for e, askedAt in pairs(queried) do
        if now - askedAt > QUERY_TIMEOUT then
            queried[e] = nil
        else
            inflight = inflight + 1
        end
    end

    for i = #warmQueue, 1, -1 do
        local e = warmQueue[i]
        if GetItemInfo(e) then
            pending[e] = nil
            queried[e] = nil
            tremove(warmQueue, i)
            -- Drop any "asked while cold" answer StatsFor recorded for this
            -- entry, so the stat sorts pick it up on the Notify("icons")
            -- rebuild below instead of treating it as a statless item forever.
            -- Cleared by ENTRY, which is why the memo is nested by entry: every
            -- suffix variant of this item was cold for the same reason.
            statMemo[e] = nil
            iconsDirty = true
        elseif not queried[e] and inflight < MAX_INFLIGHT then
            queried[e] = now
            inflight = inflight + 1
            scanTip:SetHyperlink("item:" .. e)
        end
    end
    if iconsDirty then
        iconsDirty = false
        --[[ ★★ [DE-06] The same gate as the flusher, and this is the HARSHER of
             the two sites by an order of magnitude.

             The launcher wipes Cache\WDB on every launch (the arithmetic is
             spelled out above), so EVERY session begins with the entire vault
             cold -- ~3,800 entries on the realm's largest. This branch is then
             reached on essentially every 0.2s pass for the ~40 seconds it takes
             to warm them: ~190 full Rebuilds in the first minute of every login,
             before the player has clicked anything, whether or not the Dashboard
             has ever been opened.

             ⚠ AND REBUILD IS A QUERY FAUCET WHILE COLD. ResolveName and
             EquipSlotFor each call GetItemInfo for every row still unresolved,
             which during a warm-up is nearly all of them -- so this was firing up
             to 2xN cache lookups five times a second, straight past the closed
             loop MAX_INFLIGHT exists to enforce. Read the ★★ note above: the
             rate is supposed to be set by the ANSWERS, not by a timer. Rebuild
             was quietly breaking that.

             Deferring costs nothing. The only thing Rebuild does with a warmed
             answer is write it into it.n / it.eq for display, and the single
             Rebuild that runs when the panel is next opened reads every one of
             them out of a WDB that is warm by then, in one pass. ]]
        if VaultWindowShown() then
            Core.displayDirty = false
            Notify("icons")
        else
            Core.displayDirty = true
        end
        --[[ Persist ONCE, when the queue finally drains.

             Notify above re-runs Rebuild, which is what resolves and caches
             each row's equipment slot as its item-cache entry lands -- so the
             slot data is only worth saving after the last one has. Saving on
             every flush instead would rewrite the whole SavedVariables table
             five times a second for the length of a cold warm-up. ]]
        if #warmQueue == 0 and Core.cacheDirty then Core.SaveCache() end
    end
end)

function Core.Send(msg)
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
    if not rowIndex then
        rowIndex = {}
        for i = 1, #Core.items do
            local it = Core.items[i]
            rowIndex[RowKey(it.e, it.rp or 0)] = it
        end
    end
    return rowIndex[RowKey(e, rp)]
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
        local fresh = CopyItem(item)
        Core.items[#Core.items + 1] = fresh
        IndexRow(fresh)                      -- [DE-07]
    end

    Core.depositCount = Core.depositCount + 1
    EnqueueWarm(item.e)
    -- ★ [DE-12] Mark, do not save. SaveCache deep-copies the ENTIRE vault --
    -- a fresh 13-field table per row -- so on a 4,000-row vault one drag
    -- deposit was 4,000 table allocations and ~52,000 field writes, and
    -- shift-clicking down a page was a visible hitch per click. The flusher's
    -- 15s save, the warm-queue drain and the logout force-flush all already
    -- honour Core.cacheDirty; SavedVariables is only ever read at login.
    Core.cacheDirty = true
    Notify("deposit")
end

function Core.Withdraw(item, count)
    if not item then return end
    count = max(1, min(tonumber(count) or 1, tonumber(item.c) or 1))
    -- ★ [DE-03] The COUNT goes out as %s, not %d.
    --
    -- The server sends a vault amount as uint64 (loot_vault_comms_playerscript
    -- .cpp:144) and parses this field back as text -- but Lua 5.1 on this
    -- 32-bit client casts %d through a 32-bit lua_Integer, so a single stack
    -- over 2,147,483,647 went out wrapped. Latent (the largest stack recorded
    -- on this realm is 235,345 Silk Cloth) and wrong on a field the server
    -- deliberately widened. %.0f is exact to 2^53 and never uses exponent
    -- form the way tostring() renders 1e15.
    --
    -- [DE-14] The dead client-side demo simulation that used to sit here went
    -- with demo mode; it could not run.
    Core.Send(format("VLTWD:%d:%d:%s", item.e, item.rp or 0, format("%.0f", count)))
end

-- Bulk deposit: hand the whole decision to the server.
--
-- Deliberately NOT a loop of VLTDEP over our own bags. That would be 50+ addon
-- messages in one burst (the chat throttle drops those), and the client cannot
-- see the keep-in-bags rule, so it would have to guess which items are eligible
-- and would drift from the loot path the moment that rule changed. One token,
-- server decides, server replies with a summary.
function Core.DepositAllBags()
    Core.Send("VLTDEPALL")
end

--[[ lastPickup names the bag slot the cursor's item came from, because the
     cursor itself cannot tell the server WHICH copy you picked up -- only
     PickupContainerItem knows that.

     ⚠ IT MUST BE CLEARED BY EVERY OTHER WAY OF FILLING THE CURSOR, or a stale
     pair deposits the wrong item. Picking up an EQUIPPED BAG goes through
     PickupBagFromSlot, not PickupContainerItem, so before this the cursor held a
     bag while lastPickup still pointed at whatever you last dragged out of a
     container -- and dropping it on the Vault window would have banked that
     other item instead. Harmless while bags were refused outright; a live hazard
     now that they are not (#348). Same for equipment, merchant and loot
     pickups: if we did not put it on the cursor from a container, we do not know
     what is on the cursor, and we refuse rather than guess. ]]
local lastPickup
if hooksecurefunc then
    hooksecurefunc("PickupContainerItem", function(bag, slot)
        lastPickup = { bag = bag, slot = slot }
    end)

    local function forgetPickup() lastPickup = nil end
    for _, api in ipairs({ "PickupBagFromSlot", "PickupInventoryItem", "PickupMerchantItem",
                           "PickupItem", "PickupLootItem", "PickupTradeMoney", "ClearCursor" }) do
        if type(_G[api]) == "function" then hooksecurefunc(api, forgetPickup) end
    end
end

function Core.DepositCursor()
    if not CursorHasItem() then return end
    local t, _, cursorLink = GetCursorInfo()
    --[[ Second guard on top of the pickup hooks: if that slot now reports a
         DIFFERENT item, the pair is stale and we must not act on it.

         ⚠ Only a different NON-NIL link disqualifies it. Whether the source slot
         still reports its item while the item sits on the cursor is a client
         detail I could not verify from here, and reading it as "stale" would
         break the ordinary drag-and-drop deposit for everyone -- far worse than
         the rare case this catches. Silence is treated as "no evidence". ]]
    if t == "item" and lastPickup and cursorLink then
        local slotLink = GetContainerItemLink(lastPickup.bag, lastPickup.slot)
        if slotLink and slotLink ~= cursorLink then
            lastPickup = nil
        end
    end
    if t == "item" and lastPickup then
        -- Read the pair into locals FIRST: ClearCursor is hooked above to forget
        -- lastPickup, so touching it after the call would index a nil.
        local bag, slot = lastPickup.bag, lastPickup.slot
        lastPickup = nil
        Core.Send(format("VLTDEP:%d:%d", bag, slot))
        ClearCursor()
        ApplyDepositToCache(CaptureBagItem(bag, slot))
        return
    end
    ClearCursor()
end

if hooksecurefunc then
    hooksecurefunc("HandleModifiedItemClick", function(link)
        if not link then return end
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

--[[ Row parsing and snapshot finalisation, factored out of the addon-message
     handler so the native channel can reuse both verbatim.

     The native frame carries the IDENTICAL row text -- it just arrives whole
     instead of in 240-byte chunks -- so sharing the parser is what keeps the two
     transports from drifting apart. If the row format ever changes, it changes
     in exactly one place. ]]
local function ParseRows(text)
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
    -- Legacy 5-field rows, for a server older than the 8-field format.
    if not any8 then
        for e, rp, c, q, icon in gmatch(text, "(%-?%d+),(%-?%d+),(%d+),(%d+),([^;]*);") do
            staging[#staging + 1] = {
                e = tonumber(e), rp = tonumber(rp), c = tonumber(c), q = tonumber(q),
                icon = (icon ~= "" and ("Interface\\Icons\\" .. icon)) or nil,
                n = "",
            }
        end
    end
end

--[[ Push item totals into the injected DLL, so the CLIENT counts vault stock.

     The 3.3.5 client works out quest objective progress ("3/5") and tradeskill
     reagent availability by scanning bags itself, in the engine -- neither number
     comes from the server. So a vaulted turn-in item shows 0/5 even when the
     server will happily accept the hand-in, and a recipe greys out even when the
     server would allow the craft. No Lua wrapper reaches either: both live below
     FrameXML. UncappedCT.dll hooks the engine's count function and adds whatever
     we hand it here.

     Totals are summed ACROSS SUFFIXES because the engine counts by item entry --
     the vault keys rows on (entry, randomPropertyId), so several rows can be the
     same item.

     Silently skipped when the DLL is absent. The hook is scoped to a handful of
     call sites, so this can only ever affect those; everything else keeps the
     stock bags-only answer.
]]
local function PushVaultCountsToClient()
    if type(UncappedVault_SetCounts) ~= "function" then return end

    local totals = {}
    for _, it in ipairs(Core.items) do
        local e = it.e
        if e and e > 0 and it.c and it.c > 0 then
            totals[e] = (totals[e] or 0) + it.c
        end
    end

    local parts, n = {}, 0
    for e, c in pairs(totals) do
        n = n + 1
        parts[n] = e .. ":" .. floor(c)
    end

    pcall(UncappedVault_SetCounts, tconcat(parts, ";"))

    --[[ Nudge the tradeskill window, or it renders one craft behind.

         The engine now returns vault-inclusive reagent counts, but the Blizzard
         tradeskill frame only re-queries them on its OWN events. So after a
         craft the numbers we just pushed sit unread until the NEXT craft fires a
         TRADE_SKILL_UPDATE -- which is exactly the "first smelt didn't tick, the
         second one did" symptom: the display was always one operation stale.

         Guarded on every name: Blizzard_TradeSkillUI is load-on-demand, so none
         of this exists until the player has opened a profession at least once.
    ]]
    if TradeSkillFrame and TradeSkillFrame:IsShown() then
        --[[ Force a full skill-list REBUILD.

             This is the part that actually moves the "create all" figure, and it
             took a per-call trace of the engine to find. Two things re-read item
             counts, and only one of them re-reads on demand:

               GetTradeSkillReagentInfo  -- re-queried on any frame refresh, so
                                            the reagent line was always correct
               the craftable count       -- computed ONCE, for every reagent of
                                            every recipe, during a wholesale list
                                            rebuild

             So redrawing rows (TradeSkillFrame_Update) or re-picking the recipe
             (TradeSkillFrame_SetSelection) both leave the craftable number at
             whatever the last rebuild produced. Re-applying the item-level filter
             to its OWN current value forces the rebuild with no visible change to
             what the player has selected or filtered.
        ]]
        -- Re-applying the filter to its OWN value does nothing: the client
        -- early-outs when the value has not changed. Nudge it off and back so
        -- each transition forces the rebuild, restoring what the player had.
        if type(GetTradeSkillItemLevelFilter) == "function"
            and type(SetTradeSkillItemLevelFilter) == "function" then
            local lo, hi = GetTradeSkillItemLevelFilter()
            lo, hi = lo or 0, hi or 0
            pcall(SetTradeSkillItemLevelFilter, lo, (hi == 0) and 1 or 0)
            pcall(SetTradeSkillItemLevelFilter, lo, hi)
        end

        -- And ask the frame's own handler to run the TRADE_SKILL_UPDATE path,
        -- which is what rebuilds after a craft. Belt and braces: whichever of
        -- these actually triggers the rebuild, the other is harmless.
        local onEvent = TradeSkillFrame.GetScript and TradeSkillFrame:GetScript("OnEvent")
        if onEvent then
            pcall(onEvent, TradeSkillFrame, "TRADE_SKILL_UPDATE")
        end

        -- Re-render the list...
        if type(TradeSkillFrame_Update) == "function" then
            pcall(TradeSkillFrame_Update)
        end

        --[[ ...and re-select the current recipe, which is the part that actually
             matters.

             TradeSkillFrame_Update only redraws ROWS. The "create all" maximum
             lives in the quantity input box and is computed once, in
             TradeSkillFrame_SetSelection, when a recipe is picked -- so
             re-rendering leaves it at whatever it was when you selected the
             recipe. That is why the figure only moved on the SECOND craft: the
             first craft's completion re-selected the recipe, revealing the
             count from before it.
        ]]
        if type(TradeSkillFrame_SetSelection) == "function"
            and type(GetTradeSkillSelectionIndex) == "function" then
            local sel = GetTradeSkillSelectionIndex()
            if sel and sel > 0 then
                pcall(TradeSkillFrame_SetSelection, sel)
            end
        end
    end

    --[[ Nudge the QUEST objective tracker, for exactly the reason the tradeskill
         window above needs nudging -- this is the same bug on a surface nobody
         covered.

         The engine now answers quest item counts with the vault included (the
         hooked sites in UncappedCT), but Blizzard's objective tracker and quest
         log only re-read them on their OWN events: QUEST_LOG_UPDATE, and bag
         changes. Loot that is auto-deposited goes STRAIGHT TO THE VAULT and never
         touches a bag, so no event fires and the tracker keeps drawing the number
         it drew last time.

         That is the "objective tracker not updating" report, and it is why
         opening the ledger appeared to fix it -- the ledger burst forced a redraw
         as a side effect, so the tracker looked broken until something unrelated
         made it repaint.

         So: after the counts land, tell the quest UI to repaint. Both calls are
         cheap and idempotent, and each is guarded because a stripped or replaced
         UI may not define them.

         ⚠ Deliberately NOT firing a fake QUEST_LOG_UPDATE. That event is watched
         by half the addon ecosystem (and by our own ledger), and synthesising it
         to repaint one frame would have every listener re-derive its whole world
         several times a minute. Call the two redraws we actually want instead. ]]
    if type(QuestWatch_Update) == "function" then
        pcall(QuestWatch_Update)
    end
    if QuestLogFrame and QuestLogFrame:IsShown() and type(QuestLog_Update) == "function" then
        pcall(QuestLog_Update)
    end

    --[[ The ledger's own map pins and objective arrow read the same counts, so
         they go stale in the same breath.

         ⚠ `UncappedQuests`, not `UQ`. UQ is only a FILE-LOCAL alias inside the
         UncappedQuests addon (`local UQ = UncappedQuests` at the top of each of
         its files); from this addon it is simply nil, and the whole block would
         have silently done nothing. Guarded anyway -- UncappedQuests is a
         separate addon and can be absent or disabled. ]]
    local uq = UncappedQuests
    if uq and type(uq.RefreshPins) == "function" then
        pcall(uq.RefreshPins)
    end
end
Core.PushVaultCountsToClient = PushVaultCountsToClient

local function FinalizeSnapshot()
    ClearItems()
    for idx, it in ipairs(staging) do
        it.added = #staging - idx
        Core.items[#Core.items + 1] = it
        EnqueueWarm(it.e)
    end
    staging = {}
    Core.cacheLoaded = true
    Core.SaveCache()
    PushVaultCountsToClient()
    Notify("snapshot")
    --[[ Second, conditional save.

         The Rebuild inside Notify is what resolves each row's equipment slot
         for the items the client's item cache already knew about -- and that
         happens after the save above, so without this those answers are thrown
         away and re-derived every single login. Not merged INTO the first save
         because the first one is the one that must survive a broken UI refresh:
         a snapshot has to reach SavedVariables whether or not the window
         redraws cleanly. ]]
    if Core.cacheDirty then Core.SaveCache() end
    if pendingManualRefresh then
        pendingManualRefresh = false
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff40c0ff[Vault]|r refreshed.") end
    end
end

--[[ Native path: the entire snapshot in one frame on topic "VAULT".

     Payload is "<total>\n" followed by the same rows the chunked path sends. The
     count is checked rather than trusted -- a mismatch means the payload was
     truncated or the format drifted, and it is worth saying so out loud rather
     than silently showing someone a vault that is missing items.

     Registration is conditional and failure is not an error: without the DLL,
     UncappedNative is absent or unavailable and the server keeps chunking. ]]
if UncappedNative and UncappedNative.IsAvailable() then
    UncappedNative.Register("VAULT", function(payload)
        local nl = find(payload, "\n", 1, true)
        if not nl then return end

        local claimed = tonumber(strsub(payload, 1, nl - 1))
        staging = {}
        ParseRows(strsub(payload, nl + 1))

        if claimed and claimed ~= #staging and DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage(format(
                "|cff40c0ff[Vault]|r snapshot mismatch: server sent %d rows, parsed %d. Please report this.",
                claimed, #staging))
        end

        FinalizeSnapshot()
    end)
end

--[[ ★ [#675 / #666] COALESCE THE LIVE-UPDATE STORM.

     The server sends a VLTUPD "whenever the vault moves for any reason", and on
     this realm the vault moves constantly: every auto-banked drop, every craft
     output, every sack the player auto-consumes. Each of those used to run,
     inline, on the frame the message arrived:

       Core.SaveCache()            -- deep-copies EVERY row into SavedVariables
       PushVaultCountsToClient()   -- walks every row, builds one big string
       Notify("update")            -- Core.Rebuild: walks every row, categorises,
                                      counts, filters and SORTS the result

     Three full passes over a vault that is routinely thousands of rows, per
     item. That is precisely the reported shape of #666 -- "it currently makes a
     frame drop every time it auto consumes" -- and during a big pull, where loot
     banks continuously, it is a frame drop that never stops.

     Nothing here needs to be immediate. The amounts on the wire are ABSOLUTE, so
     applying the last one is the same as applying all of them; the table itself
     is still updated the instant the message lands (above), and only the three
     EXPENSIVE consequences are deferred. What the player can see updates on the
     interval below, which is a quarter second while the window is actually open.

     SaveCache is deferred hardest, because nothing reads it until the next
     login: it is persistence, not display. It is forced out on logout so the
     delay can never cost a session's worth of updates. ]]
local FLUSH_INTERVAL_OPEN   = 0.25   -- vault window visible: keep it feeling live
local FLUSH_INTERVAL_CLOSED = 1.5    -- nothing on screen reads this; be cheap
local SAVE_INTERVAL         = 15     -- SavedVariables is only read at login

local dirty, dirtyReason = false, "update"
local lastSave = 0
local flusher = CreateFrame("Frame")
local flushAcc = 0

local function FlushVaultUpdate(force)
    if not dirty then
        -- [DE-12] A deposit or a withdraw sets cacheDirty without setting
        -- `dirty` (nothing about them needs coalescing -- they repaint at
        -- once). Logout must still write that out: it is the only moment the
        -- deferred save cannot be deferred again.
        if force and Core.cacheDirty then Core.SaveCache() end
        return
    end
    dirty = false

    local now = GetTime and GetTime() or 0
    if force or (now - lastSave) >= SAVE_INTERVAL then
        lastSave = now
        Core.SaveCache()
    else
        -- Not saved yet, but the rows have moved -- make sure whoever saves next
        -- (the warmer's drain, a snapshot, logout) knows there is something to write.
        Core.cacheDirty = true
    end

    --[[ ★★ ALWAYS, WINDOW OR NO WINDOW. This one is not a repaint.

         PushVaultCountsToClient is what the ENGINE reads. The 3.3.5 client works
         out quest objective progress ("3/5") and tradeskill reagent availability
         by counting bags itself, below FrameXML, and UncappedCT.dll hooks that
         count to add the vault's stock. Gate this and a player farming a vaulted
         turn-in watches it sit at 0/5 while it drops -- with the Dashboard shut,
         which is exactly when they are farming it. ]]
    PushVaultCountsToClient()

    --[[ ★★ [DE-06] BUT THE REPAINT WAITS FOR SOMEBODY TO BE LOOKING.

         Notify is Core.Rebuild() + Core.UI.Refresh(): a walk of every row that
         resolves a name and an equip slot each, two O(n log n) sorts, one fresh
         table per row for the grid layout, and then a pass over every widget in
         the panel. On the realm's largest vault that is 3,802 rows and ~3,900
         table allocations, and it was being done for a panel nobody could see.

         The interval above only ever made that CHEAPER, never SKIPPED, and
         "cheaper" is the wrong axis when the result is discarded unseen. There
         was no fallback early-out to save it either: Core.UI is registered
         unconditionally at load (UncappedVault_UI.lua:8) and `frame` survives
         the whole session once the Dashboard has been opened once, so
         UI.Refresh's nil-guard never fires again.

         ⚠ NOTHING IS LOST BY WAITING. Core.items was updated the instant the
         message landed; only the DERIVED view (filtered/categories/gridLayout)
         and the pixels are deferred. UI.Activate (UncappedVault_UI.lua)
         rebuilds and repaints both, unconditionally, every single time the Vault
         tab is selected -- so the window is already correct the moment it opens.
         displayDirty is the belt to that braces: it covers a future path that
         reaches the screen without going through Activate. An update that lands
         while hidden and is never drawn would be a far worse bug than the cost
         this removes. ]]
    if VaultWindowShown() then
        Core.displayDirty = false
        Notify(dirtyReason)
        dirtyReason = "update"
    else
        Core.displayDirty = true
    end
end

flusher:SetScript("OnUpdate", function(self, dt)
    --[[ ★ [DE-06] Pay the deferred repaint the moment the panel is on screen.

         ⚠ THIS MUST STAY ABOVE THE `if not dirty` LINE. A repaint can be owed
         long after the last update landed -- dirty is already false by then --
         so putting this below the early-out is the one edit that reintroduces
         the exact regression the flag exists to prevent: a vault the player
         opens to find frozen at the state it had ten minutes ago.

         Costs one VaultWindowShown() per frame ONLY while a repaint is actually
         owed AND the window is shut -- never on an idle client, and never once
         the debt is paid. In practice it fires on nothing at all, because
         UI.Activate already does the same Rebuild+Refresh on every Vault-tab
         selection and every one of the three Buttons.Show() call sites is
         followed immediately by UncappedDashboard.UI.Refresh(). It is here so
         that stops being something a future edit has to remember. ]]
    if Core.displayDirty and VaultWindowShown() then
        Core.displayDirty = false
        Notify(dirtyReason)
        dirtyReason = "update"
    end

    if not dirty then return end
    flushAcc = flushAcc + (dt or arg1 or 0)
    local interval = VaultWindowShown() and FLUSH_INTERVAL_OPEN or FLUSH_INTERVAL_CLOSED
    if flushAcc < interval then return end
    flushAcc = 0
    FlushVaultUpdate(false)
end)

-- Logout is the one moment the deferred SaveCache must not be deferred: it is
-- the only reader of that table, and it reads it next login.
flusher:RegisterEvent("PLAYER_LOGOUT")
flusher:RegisterEvent("PLAYER_LEAVING_WORLD")
flusher:SetScript("OnEvent", function() FlushVaultUpdate(true) end)

--[[ Mark the vault changed. Cheap by construction -- two assignments -- so it is
     safe to call once per incoming message however fast they arrive.

     The tradeskill window is the one exception that still goes out immediately:
     its craftable counts are computed once during a wholesale list rebuild and
     then sit stale until something forces another (see the long note in
     PushVaultCountsToClient), so a deferred push there reads as "the first smelt
     didn't tick". It is only reachable while a profession window is open, which
     is never during the pull this whole mechanism exists for. ]]
local function MarkVaultDirty(reason)
    dirty = true
    if reason then dirtyReason = reason end
    flushAcc = 0

    if TradeSkillFrame and TradeSkillFrame:IsShown() then
        FlushVaultUpdate(false)
    end
end

local comms = CreateFrame("Frame")
comms:RegisterEvent("CHAT_MSG_ADDON")
comms:SetScript("OnEvent", function(_, _, a1, a2)
    if a1 ~= ADDON_PIPE_PREFIX or not a2 then return end
    local text = a2
    --[[ Tested BEFORE "^VLTROW:" deliberately.

         The two are already unambiguous -- "^VLTROW:" requires the colon, and
         this line spells VLTROWUPD: -- but that safety rests entirely on an
         anchor and a colon that a later edit could relax without noticing.
         Matching the longer token first makes the order do the work instead. ]]
    if find(text, "^VLTROWUPD:") then
        --[[ Stacks the server has just CREATED, in the full snapshot row format.

             ★ THIS IS WHAT KEEPS A BRAND-NEW ROW OFF THE SNAPSHOT PATH. VLTUPD
             below carries an amount and nothing else, so a row we have never
             seen cannot be built from it -- that branch asks for a whole new
             snapshot instead. ~30 KB, over a pipe the client itself throttles,
             for every distinct item that reaches the Vault for the first time. A
             player farming a quest item hits that on the very first drop; and if
             one of those requests is throttled away the row never arrives at
             all, because every later VLTUPD for it lands in the same unknown-row
             branch and bails out again. The count then stays frozen wherever it
             was.

             That is the reported symptom: "Skullsplitter Tusk 0/18" sitting at
             zero while tusks keep dropping, with the Quest Ledger showing the
             right number the whole time -- the ledger is server-fed and never
             consults this table. It looked self-healing because anything that
             forced a snapshot to land (opening the window, the 300s ticker) fixed
             it until the next new item.

             Arrives BEFORE the VLTUPD for the same tick, so by the time that one
             is parsed the row exists and its unknown-row branch never fires.

             Amounts are ABSOLUTE, as everywhere in this protocol, so a row that
             turns out to already exist is simply corrected -- applying this twice
             is harmless.

             `icon` comes through EMPTY: it lives only in the server's icon table
             and is not worth a query per tick. ItemIcon() already falls back to
             GetItemInfo(), and the next full snapshot fills it in. ]]
        local touched = false
        for e, rp, c, q, cls, subc, ilvl, icon in gmatch(text, "(%-?%d+),(%-?%d+),(%d+),(%d+),(%d+),(%d+),(%d+),([^;]*);") do
            e, rp, c = tonumber(e), tonumber(rp), tonumber(c)
            local it = FindRow(e, rp)
            if it then
                if it.c ~= c then it.c = c touched = true end
            else
                local fresh = CopyItem({
                    e = e, rp = rp, c = c, q = tonumber(q),
                    cls = tonumber(cls), sub = tonumber(subc), ilvl = tonumber(ilvl),
                    icon = (icon ~= "" and ("Interface\\Icons\\" .. icon)) or nil,
                    n = "",
                })
                Core.items[#Core.items + 1] = fresh
                IndexRow(fresh)              -- [DE-07]
                EnqueueWarm(e)
                touched = true
            end
        end

        if touched then
            MarkVaultDirty("update")
        end
    elseif find(text, "^VLTROW:") then
        ParseRows(text)
    elseif find(text, "^VLTEND:") then
        FinalizeSnapshot()
    elseif find(text, "^VLTUPD:") then
        --[[ Rows the server changed since it last told us.

             Sent whenever the vault moves for any reason -- a craft, a quest
             turn-in, loot banking -- rather than only on an explicit refresh.
             Before this the window (and the DLL's client-side counts) stayed
             frozen at load time, so a max-craftable figure would sit still while
             the materials behind it were being spent.

             Amounts are ABSOLUTE, so applying one twice is harmless and a dropped
             message self-corrects on the next update for that row. Amount 0 means
             the stack is gone.
        ]]
        local touched = false
        for e, rp, amount in gmatch(text, "(%d+),(%-?%d+),(%d+);") do
            e, rp, amount = tonumber(e), tonumber(rp), tonumber(amount)
            local it = FindRow(e, rp)
            if amount <= 0 then
                if it then
                    for k, v in ipairs(Core.items) do
                        if v == it then tremove(Core.items, k) break end
                    end
                    InvalidateRowIndex()     -- [DE-07]
                    if Core.selectedItem == it then Core.selectedItem = nil end
                    touched = true
                end
            elseif it then
                if it.c ~= amount then it.c = amount touched = true end
            else
                -- A row we have never seen: the server knows the amount but not
                -- the display fields, so ask for a full snapshot rather than
                -- inventing an entry the window cannot render.
                Core.RequestSnapshot()
                return
            end
        end

        if touched then
            MarkVaultDirty("update")
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
                    InvalidateRowIndex()     -- [DE-07]
                    if Core.selectedItem == it then Core.selectedItem = nil end
                end
            end
            Core.withdrawCount = Core.withdrawCount + 1
            -- [DE-12] Mark, do not deep-copy the whole vault per right-click.
            Core.cacheDirty = true
            if DEFAULT_CHAT_FRAME then
                DEFAULT_CHAT_FRAME:AddMessage(format("|cff40c0ff[Vault]|r withdrew |cffffffff%sx|r %s", Core.Comma(given), GetItemInfo(e) or ("item " .. e)))
            end
            Notify("withdraw")
        end
    --[[ Wording deliberately UNCHANGED, so this file is safe to ship ahead of the
         server that learns to send VLTWDNONE.

         Until that server is live, VLTWDFAIL still covers both causes, and
         narrowing this text to "no room in your bags" would make it confidently
         wrong for the holds-none case -- worse than the vague version it
         replaced. It can be narrowed once VLTWDNONE is actually being sent. ]]
    elseif find(text, "^VLTWDFAIL:") then
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff40c0ff[Vault]|r couldn't withdraw -- bags full, or not enough left in the vault.") end
    --[[ The vault holds none of that item. A DIFFERENT failure from bags-full and
         it needs the opposite reaction: making room will never help.

         Report #238: a player tried to pull a Mythic keystone out and got
         "bags full, or not enough left in the vault" -- one message covering both
         causes. Keystones are deliberately never vaultable (they are consumed
         from bags to start a run, so a vaulted one makes the whole system
         unreachable), which is why the vault held none. The old wording read as
         transient, so the obvious response was to free bag slots and retry, which
         could not have worked. ]]
    --[[ Keys are a trap of their own. Player::CanStoreItem sends a keyring-family
         item to the KEYRING and returns the failure immediately if it won't fit --
         it never falls back to ordinary bag slots. So this fails with the bags
         wide open, and "bags full" sends the player to clear space that was never
         the problem. Report #238, The Violet Hold Key. ]]
    elseif find(text, "^VLTWDKEYRING:") then
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff40c0ff[Vault]|r couldn't withdraw -- your keyring is full. Keys only go in the keyring, never in bags, so free a keyring slot rather than bag space.") end
    elseif find(text, "^VLTWDNONE:") then
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff40c0ff[Vault]|r couldn't withdraw -- the vault holds none of that. Some items (keystones, hearthstone, class reagents) are deliberately kept in your bags and never stored.") end
    elseif find(text, "^VLTDEPALLDONE:") then
        local stacks, items, kept = match(text, "^VLTDEPALLDONE:(%d+):(%d+):(%d+)$")
        if stacks then
            stacks, items, kept = tonumber(stacks), tonumber(items), tonumber(kept)
            Core.depositCount = Core.depositCount + stacks
            if DEFAULT_CHAT_FRAME then
                if stacks > 0 then
                    DEFAULT_CHAT_FRAME:AddMessage(format(
                        "|cff40c0ff[Vault]|r deposited |cffffffff%s|r item(s) in |cffffffff%s|r stack(s).",
                        Core.Comma(items), Core.Comma(stacks)))
                else
                    DEFAULT_CHAT_FRAME:AddMessage("|cff40c0ff[Vault]|r nothing in your bags to deposit.")
                end
                if kept > 0 then
                    DEFAULT_CHAT_FRAME:AddMessage(format(
                        "|cff40c0ff[Vault]|r |cffffd100%d|r item(s) stay in your bags on purpose.", kept))
                end
            end
            Notify("deposit")
        end
    elseif find(text, "^VLTDEPFAIL:") then
        local why = match(text, "^VLTDEPFAIL:(%a+)")
        -- [#1072] Optional 3rd field naming WHICH keep rule refused it. "kept" alone
        -- covered six different rules and this code could only describe one of them,
        -- so a class reagent was explained to players as a part-looted container.
        -- nil on an older server, which falls through to the original wording.
        local keptWhy = match(text, "^VLTDEPFAIL:kept:(%a+)")
        local reason = (why == "quest" and "quest items") or (why == "bag" and "bags")
            or (why == "bound" and "soulbound items") or "that item"
        if why == "bagitems" then
            -- Bags CAN be deposited now (#348) -- but only empty ones. Destroying
            -- a loaded bag destroys what is inside it, and the Vault stores a
            -- count with nowhere to put contents.
            if DEFAULT_CHAT_FRAME then
                DEFAULT_CHAT_FRAME:AddMessage("|cff40c0ff[Vault]|r that bag still has things in it "
                    .. "-- empty it first, then deposit the bag.")
            end
        elseif why == "kept" then
            -- Each of these is a genuinely different reason, and telling the player the
            -- wrong one is worse than telling them nothing -- they go looking for loot
            -- inside a stack of fish scales.
            local msg
            if keptWhy == "reagent" then
                msg = "that one stays in your bags -- it's a class reagent, and spells "
                    .. "spend those straight out of your bags."
            elseif keptWhy == "key" then
                msg = "that's a key -- it has to be on you to open what it opens."
            elseif keptWhy == "worlduse" then
                -- [#1103] Without this branch a Gni'kiv Medallion falls through to the
                -- "unrep" fallback below and is explained as holding loot or charges,
                -- which is report #1072 reproduced word for word. A wrong explanation
                -- is worse than none: it sends the player looking for the wrong thing.
                msg = "that one gets clicked on something out in the world -- a door, an "
                    .. "altar, a pile of bones -- and you can't click what's in the Vault."
            elseif keptWhy == "questuse" then
                msg = "a quest wants you to click that one, and you can't click "
                    .. "something that's in the Vault."
            elseif keptWhy == "dungeonquest" then
                msg = "you're on a dungeon quest that wants that one, so it stays on you "
                    .. "until you're done."
            elseif keptWhy == "playerlist" then
                msg = "you asked for that one to stay in your bags -- `/keep remove` to undo."
            elseif keptWhy == "builtin" then
                msg = "the realm keeps that one on you on purpose."
            else
                -- "unrep", and the fallback for an older server that sends a bare "kept".
                -- Things the Vault stores as a COUNT would lose what makes them
                -- individual: a part-looted lockbox would come back unopened, a
                -- half-used trinket would come back full.
                msg = "that one stays in your bags -- it holds something of its own "
                    .. "(loot inside it, or charges left), and the Vault only stores a count."
            end

            if DEFAULT_CHAT_FRAME then
                DEFAULT_CHAT_FRAME:AddMessage("|cff40c0ff[Vault]|r " .. msg)
            end
        elseif DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cff40c0ff[Vault]|r can't deposit " .. reason .. ".")
        end
        --[[ The optimistic local cache already counted this deposit
             (ApplyDepositToCache runs the moment the drag is sent, so the row
             appears instantly instead of a round trip later). A REFUSAL leaves
             that phantom row behind -- the window says the bag is banked while
             it is still in your hands. Re-ask for the truth; the server sends no
             snapshot on the failure path. ]]
        if Core.RequestSnapshot then Core.RequestSnapshot() end
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
    -- [DE-14] Was `if Core.demo then LoadDemo() else <this> end`. Demo mode was
    -- unreachable, so only this branch ever ran. Left as a plain do-block
    -- rather than de-indented, so the long #407 note below stays put.
    do
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff40c0ff[Vault]|r ready -- type |cffffd100/dashboard|r to open it.") end
        --[[ ★★ [Custom] Report #407 -- "Vault is slowly refreshing. After a couple of
             relogs it starts to show exact number of items left in the vault."

             THE STALE NUMBER WAS THIS ADDON'S OWN SAVEDVARIABLES COPY, not the
             server's count and not the client engine's cached item string. Checked
             all three before changing anything:

               - The server cache (VaultCache, src/server/game/Loot/VaultCache.cpp)
                 is NOT the #256 "loads once at startup" shape. Every writer keeps
                 it honest: LootVault::Ingest -> NoteExternalChange, Withdraw and
                 StoredMaterials::Consume all notify it, a change that lands while
                 the login SELECT is still in flight sets reloadWhenLoaded and
                 forces a re-read, and the load is keyed on !vault.loaded so it
                 self-heals.
               - The snapshot the server sends (SendVault) reads custom_vault_item
                 straight from the DB, so it cannot lag the writers either.
               - The server does PUSH row updates: the comms playerscript drains
                 VaultCache::TakeDirty every player tick with PUSH_INTERVAL_MS = 0.

             What was actually wrong is the line this replaces:

                 if not Core.LoadCache() then Core.RequestSnapshot() end

             LoadCache returns true whenever SavedVariables holds a cache of the
             current CACHE_VERSION -- so a client that has ever seen the Vault asks
             the server for NOTHING at login and paints last session's numbers. And
             SavedVariables is only written to disk on a clean exit, so a crash or a
             disconnect silently throws away every push applied that session; the
             file can be arbitrarily older than the vault.

             That also explains the oddly specific "after a couple of relogs".
             Nothing corrects the numbers on a timescale the player notices except
             two accidents: the 900s recache ticker, and the unknown-row branch in
             the VLTUPD handler, which only fires a fresh snapshot when a pushed row
             is one the stale cache has never seen. Relog, and the 3s post-login bag
             sweep banks the backlog and pushes those rows -- so the numbers snap
             exact on whichever relog happens to bank something new. Exactly the
             reported symptom.

             Fix: still load the cache, so the window paints instantly with no blank
             frame, but ALWAYS ask for a fresh snapshot on top of it. Deliberately
             without cleanCache: FinalizeSnapshot already does a full ClearItems and
             refill on VLTEND, so the cached rows stay on screen right up until the
             authoritative ones replace them, instead of the window emptying while
             the snapshot is in flight.

             ⚠ NOT also hooked to opening the window, though that is the other
             obvious place. SendVault runs a SYNCHRONOUS SELECT over
             custom_vault_item on the character DB, and a player toggling the
             Dashboard tab could fire those back to back. One snapshot per login is
             bounded and is the same query an uncached client already ran; per-open
             is not. The refresh button (Core.ManualRefresh) remains the on-demand
             path. ]]
        Core.LoadCache()
        Core.RequestSnapshot()
        StartRecacheTicker()
    end
end)

-- No standalone /vault command: this window is a Dashboard tab now, opened via
-- /dashboard, so a dedicated slash command would just duplicate that entry point.
