-- UncappedForge
--
-- A crafting window that replaces Blizzard's TradeSkillFrame, because that
-- frame cannot be made to do what this realm needs:
--
--   * Materials live in the Vault, not in bags. The SERVER counts vault
--     materials towards a craft, but the 3.3.5 client re-checks reagents
--     locally and greys out its own Create button, and neither that button's
--     state nor GetTradeSkillInfo's "numAvailable" can be hooked or overridden
--     from an addon. So this window never touches Blizzard's buttons: it asks
--     the server to cast the recipe, and the client's opinion never comes up.
--   * No tools. A Blacksmith Hammer is never consumed, so the Forge does not
--     ask for one -- it just says what the recipe would normally want.
--   * Intermediates. Ask for a Copper Chestplate holding only ore and it
--     smelts the bars first.
--   * Bulk milling / prospecting / disenchanting straight out of the vault.
--
-- Everything shown here comes from the server (FRG* protocol, see
-- forge_comms_playerscript.cpp) -- the client is a renderer, and holds no
-- authority over what can be crafted or spent.


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

local ADDON_PIPE_PREFIX = "UNC"           -- server replies arrive on this prefix
local TRANSPORT_PREFIX  = "REAGENTBANK"   -- shared client->server transport

-- ---------------------------------------------------------------------------
-- SavedVariables
-- ---------------------------------------------------------------------------
local DEFAULTS = {
    replaceTradeSkill = true,   -- open the Forge instead of Blizzard's window
    autoIntermediates = true,   -- craft missing sub-components automatically
    craftableOnly     = false,  -- list filter
    -- [owner request 2026-08-17] Widens craftableOnly to include recipes that are
    -- not craftable now but whose every missing reagent is vendor-sold for gold.
    -- Only meaningful while craftableOnly is on; with the filter off, everything
    -- is listed anyway and this changes nothing.
    buyableToo        = false,
    sortMode          = "name",  -- "name" or "difficulty"
    -- [#922] The bulk-processing views keep their OWN sort and material filter.
    -- Sharing sortMode with the recipe list is what caused the reported bug in the
    -- first place: one control, two lists, and only one of them listening.
    procSortMode      = "count", -- "count", "name" or "difficulty" (= disenchant skill)
    procMaterial      = 0,       -- 0 = any; otherwise a material item id
    lastAmount        = 1,
    sourceRows        = 14,     -- "where to farm" visible rows
    sourceRowHeight   = 20,     -- "where to farm" row height (px)
    savePos           = true,   -- remember the dragged "where to farm" position
    -- db.sourcePos is written on drag; absent until then, so no default here
    -- (a nil value in this table would not be stored as a key anyway).
}

local db

local function InitDB()
    if type(UncappedForgeDB) ~= "table" then UncappedForgeDB = {} end
    db = UncappedForgeDB
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
    return db
end

InitDB()

-- ---------------------------------------------------------------------------
-- State, all server-supplied
-- ---------------------------------------------------------------------------
local professions = {}      -- ordered { skill=, rank=, max=, name= }
local recipes = {}          -- ordered { spell=, item=, yield=, skill=, min=, tlow=, thigh=, tool= }
local recipesBySpell = {}
-- [owner request 2026-08-17] spellId -> true for recipes the server says are not
-- craftable now but whose every missing reagent is vendor-sold for gold (FRGVEND).
-- A SET rather than a field on the recipe, because it arrives on its own row type --
-- see the FRGVEND note in forge_comms_playerscript.cpp for why it is not an 11th
-- FRGREC field. Empty against an old server, which simply hides the extra rows.
local buyableSet = {}

--[[ ===========================================================================
     [#1199] RECIPES THAT ENCHANT SOMETHING YOU ALREADY OWN.

     spellId -> { class = <ITEM_CLASS_*>, sub = <subclass bitmask>,
                  inv = <inventory-type bitmask>, minlvl = <required-level floor> }

     43 profession recipes -- all nine engineering tinkers, the tailoring
     embroideries, the eight leatherworking fur linings, the inscriptions and the
     ring enchants -- do not CREATE an item. They enchant a piece of gear you are
     already carrying. CraftingIndex only indexes SPELL_EFFECT_CREATE_ITEM and the
     enchants that carry a vellum ItemType, so these have never appeared in the
     Forge at all: not craftable, not listed, not searchable.

     The three numbers are the spell's own `EquippedItemClass`,
     `EquippedItemSubClassMask` and `EquippedItemInventoryTypeMask` -- the same
     three the core itself checks in Item::IsFitToSpellRequirements. Passing them
     to the client rather than making the client guess is the whole point: nothing
     in the addon knows that a Frag Belt goes on a WAIST and only a WAIST.

     ⚠ A SET, ON ITS OWN ROW TYPE (FRGGEAR), never an 11th FRGREC field. The recipe
       pattern has exactly ten captures and an eleventh field makes it MISS, which
       is an EMPTY RECIPE LIST rather than a cosmetic glitch -- forge_comms_
       playerscript.cpp spells this out at the FRGVEND site, and this follows it.
       A new client against an old server simply receives none of these rows and
       shows no gear-target recipes, which is exactly today's behaviour.

     ⚠ On their ordinary FRGREC row these recipes carry item = 0, yield = 0 and
       target = 0, and there is no FRGPROD for them. `maxc` is how many
       APPLICATIONS the materials support. Everything downstream that reads
       `recipe.item` has to tolerate a zero -- see RecipeIcon and RecipeName.

     ⚠ Replaced wholesale at FRGEND and NOT touched at FRGCNTEND. A counts-only
       refresh does not carry these rows (the masks cannot change), so committing
       an empty staging table there would wipe the set on the first craft.
     ========================================================================== ]]
local gearTargets = {}

local filtered = {}         -- current visible subset of `recipes`
local filteredProc = {}     -- current visible subset of `processable`

-- ---------------------------------------------------------------------------
-- Search
--
-- ONE box drives both lists. The window only ever shows one of them at a time
-- (recipes, or the bulk mill/prospect/disenchant list -- picked from the same
-- profession dropdown), so a second box would be a control that is inert most
-- of the time. The query lives here rather than being read back out of the
-- EditBox because ApplyFilter runs from the comms handler, which fires long
-- before the frame is built.
--
-- Matching is forgiving: lowercased, plain substring (find with plain=true, so
-- a player typing "(" or "-" cannot throw a malformed-pattern error), and split
-- on whitespace into tokens that must ALL appear -- "copper bar" finds "Copper
-- Bar" whichever order the words are typed in.
-- ---------------------------------------------------------------------------
local SEARCH_DEBOUNCE = 0.12
local SEARCH_HINT = { craft = "Search recipes..." }

-- The `kinds` bitmask on a FRGPROCROW: which bulk operations this stack actually
-- supports. The detail pane already described them correctly; the BUTTONS did not
-- consult it, so a render-only stack still offered Mill/Prospect/Disenchant --
-- three controls that could not do anything with what you had selected.
local KIND_MILL       = 1
local KIND_PROSPECT   = 2
local KIND_DISENCHANT = 4
local KIND_RENDER     = 8

--[[
    The bulk-processing VIEWS.

    Owner 2026-08-12: rendering and disenchanting each get their own tab. They used
    to share one "Bulk processing" list that showed every processable stack and all
    four action buttons regardless of what the selected row supported.

    Table-driven rather than three near-identical branches: a view is just a label,
    a kinds mask and a search hint, so the list filter, the dropdown, the search
    hint and the button row all read from ONE place. Adding a fourth is a row here
    and nothing else -- which is the only reason splitting these is cheap.

    `mask` does double duty: it filters the LIST to rows that support the view, and
    it gates which BUTTONS may appear (intersected with the row's own kinds, so a
    stack that mills but cannot prospect only offers Mill).
]]
local PROC_VIEWS = {
    mill = {
        label = "Milling",
        mask  = KIND_MILL,
        hint  = "Search herbs...",
        blurb = { "Every herb in your Vault that can be milled.",
                  "Pick a row, then Mill All." },
    },
    prospect = {
        label = "Prospecting",
        mask  = KIND_PROSPECT,
        hint  = "Search ore...",
        blurb = { "Every ore in your Vault that can be prospected.",
                  "Pick a row, then Prospect All." },
    },
    disenchant = {
        label = "Disenchanting",
        mask  = KIND_DISENCHANT,
        hint  = "Search gear to disenchant...",
        blurb = { "Everything in your Vault that can be disenchanted.",
                  "Pick a row, then Disenchant All." },
    },
    render = {
        label = "Rendering",
        mask  = KIND_RENDER,
        hint  = "Search things to render...",
        --[[
            ⚠ [#812] THE THIRD LINE IS A SIGNPOST, NOT FILLER.

            The report that asked for grey/white junk gear to be renderable in
            bulk from the Vault used the words "via bulk processing" -- i.e. it
            asked for it HERE, on this tab, which is the obvious place to look
            for it. It is not here, and it is not here for a reason:

              * this tab drives CRAFTING conversions -- mill, prospect,
                disenchant, render -- each of which is a real spell that turns a
                stack into another ITEM. "Souls" is not an item any of them can
                produce.
              * its rows come from the server's commodity snapshot, which is
                random_prop_id 0 only. Gear that rolled a suffix is invisible to
                it, so half of the grey and white gear in a Vault could never
                appear on this list at all.

            The Soulforge panel owns junk-gear-to-souls, along with the whitelist,
            the quest reserves and the consent dialog that guard it. So the answer
            to "why isn't my grey gear in the Rendering list" is one line, in the
            place the player is already looking, rather than a second half-copy of
            those rules bolted on here.
        ]]
        blurb = { "Everything in your Vault that renders down into something else.",
                  "Pick a row, then Render All.",
                  "Junk GEAR is not here: grey and white weapons and armour render into "
                  .. "souls, from Soul Forge \226\134\146 Render junk gear." },
    },
}

-- Dropdown order. A plain table so the order is deliberate rather than whatever
-- pairs() happens to yield -- that ordering is not stable across sessions.
local PROC_VIEW_ORDER = { "mill", "prospect", "disenchant", "render" }

local function ProcView(mode)
    return mode and PROC_VIEWS[mode] or nil
end

local searchRaw = ""        -- exactly what was typed, for the "no matches" line
local searchQuery = ""      -- trimmed + lowercased
local searchTokens = {}     -- lowercased words, all required
local searchNumeric = nil   -- the query when it is all digits, for id fallback
local searchWait = nil      -- seconds left on the debounce, nil when idle

local function SetSearchQuery(text)
    searchRaw = text or ""
    searchQuery = searchRaw:lower():gsub("^%s+", ""):gsub("%s+$", "")

    searchTokens = {}
    for word in searchQuery:gmatch("%S+") do
        searchTokens[#searchTokens + 1] = word
    end

    searchNumeric = (searchQuery ~= "" and searchQuery:match("^%d+$")) or nil
end

-- Typing does NOT filter on the spot. The pass is cheap now (see SortRecipes)
-- but it is still a walk over every recipe the character knows, and a held-down
-- key repeats faster than that is worth doing; this coalesces a burst of
-- keystrokes into one pass a fraction of a second after typing settles, which
-- reads as instant. The ticker's OnUpdate runs it -- see below.
local function QueueSearch(text)
    SetSearchQuery(text)
    searchWait = SEARCH_DEBOUNCE
end

-- `lower` is nil for a row whose display name has not resolved yet. Those stay
-- visible on an empty query, and stay REACHABLE on a typed one by matching the
-- raw item id -- silently dropping them would make the search lie about what is
-- in the list. The id is only consulted for such rows, so an ordinary word
-- search never picks up stray id matches.
local function MatchesSearch(lower, fallbackId)
    if #searchTokens == 0 then return true end

    if not lower then
        return (searchNumeric ~= nil) and (fallbackId ~= nil)
            and tostring(fallbackId):find(searchNumeric, 1, true) ~= nil
    end

    for i = 1, #searchTokens do
        if not lower:find(searchTokens[i], 1, true) then return false end
    end
    return true
end

local selectedSkill = nil   -- profession tab
local selectedSpell = nil
local mats = {}             -- spellId -> { {item=, per=, have=, icon=} }
local prodIcon = {}         -- spellId -> icon path
local plan = { steps = {}, needs = {}, total = 0, feasible = true }
local quote = nil           -- { cost=, buy=, tokenOnly=, unbuyable= }
local processable = {}      -- { item=, count=, kinds= }
local job = nil             -- { done=, total=, crafted= } while a job runs

--[[ ★ [DE-02] Where the last craft's output actually went.

     FRGDONE's two success strings used to append the literal " into your
     Vault". Right for both normal output paths -- DoCreateItem is
     vault-intercepted, and AutoStoreLoot now diverts to the forge sink during
     a vault-output cast -- but ForgeCraft::ProductMustGoToBags forces
     ITEM_CLASS_CONTAINER products to bags, so a tailor crafting a Frostweave
     Bag was told it was in a window it is not in.

     Carried on its OWN line rather than as a new FRGDONE field, for the same
     reason as the #922 rows above: FRGDONE's failure token is captured with
     `(.*)$`, so a fourth positional field would be read by every un-updated
     client as part of the failure string and printed as "failed (...)".
     An unknown verb is simply ignored instead.

     Set by FRGDEST, consumed by the next FRGDONE, and nil against a server
     that does not send it -- which degrades to exactly today's wording. ]]
local craftDest = nil       -- "bags" | "vault" | nil (= unknown, assume vault)

-- [#922] Disenchant-only attributes, arriving on their own row types so an
-- un-updated client is unaffected. Empty against an old server, which is what makes
-- the new sort and filter degrade to the old behaviour instead of erroring.
local procAttr = {}         -- item -> { skill=, tier= }
local tierMats = {}         -- tier -> { [materialItemId] = true }
local matPresent = {}       -- materialItemId -> true, for building the dropdown

--[[
    Report #737: "Forge moving on to a new recipe if there's no mats for current
    -- works only on the 'craft' button, doesn't work on 'craft all'."

    ★ THE AUTO-ADVANCE WAS WIRED TO A FAILURE, AND CRAFT ALL DOES NOT FAIL.

    "Craft" sends whatever is in the Amount box. Ask for 20 with materials for 3
    and the server refuses the plan with "missing" -- a failure string, which is
    what the FRGDONE handler watches for, so the selection moves on. Correct.

    "Craft All" sends exactly MaxCraftable(), i.e. precisely what the materials
    support. It therefore succeeds, every time, by construction. The run ends
    with an EMPTY failure and the advance never fires -- not because anything
    went wrong, but because nothing did. The button that most needs to move on is
    the one that can never trigger the move.

    So the trigger cannot be the failure; it has to be the STATE AFTERWARDS.
    This holds the spell id of a clean run until its refreshed counts land, and
    the FRGMAT handler advances if the recipe can no longer be made at all.

    ⚠ It waits for FRGMAT rather than deciding immediately, because the counts in
      `mats` at FRGDONE time are the PRE-craft ones -- they would say the recipe
      is still makeable and the advance would never fire for the opposite reason.
      FRGDONE already re-asks (Send "FRGMATS:"), so this costs no extra traffic.
]]
local advanceWhenMatsLand = nil

local frame, listScroll, listButtons, detail, progress
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"

local function Send(msg)
    SendAddonMessage(TRANSPORT_PREFIX, msg, "WHISPER", UnitName("player"))
end

-- ---------------------------------------------------------------------------
-- Item name/icon resolution
--
-- 3.3.5 GetItemInfo does NOT fetch an uncached item, it just returns nil
-- forever -- and materials that go straight to the vault never pass through a
-- player's bags, so they are frequently uncached. A hidden tooltip
-- SetHyperlink forces the server-side item query; the retry ticker re-renders
-- as the data lands. Each item is queried exactly ONCE: firing repeatedly
-- floods the client's item-query throttle and the names never resolve at all,
-- which is the bug the vault window shipped with twice.
-- ---------------------------------------------------------------------------
local scanHost = CreateFrame("Frame")
scanHost:Hide()
local scanTip = CreateFrame("GameTooltip", "UncappedForgeScanTip", scanHost, "GameTooltipTemplate")
local queried = {}

local function ItemName(itemId)
    if not itemId or itemId == 0 then return nil end
    local name = GetItemInfo(itemId)
    if name then return name end

    if not queried[itemId] then
        queried[itemId] = true
        scanTip:SetOwner(scanHost, "ANCHOR_NONE")
        scanTip:SetHyperlink("item:" .. itemId)
        scanTip:Hide()
    end
    return nil
end

-- The display name for a RECIPE row.
--
-- Uses the crafting spell's own name, not the produced item's. GetItemInfo needs
-- the item to be in the client's cache, and a crafter's products routinely are
-- NOT: they go straight from the craft into the Vault without ever sitting in a
-- bag, so the list rendered as "item 10001", "item 10002" for a whole profession.
-- GetSpellInfo reads Spell.dbc, which ships with the client and is always
-- present, so a recipe name resolves on the first frame with no cache and no
-- round trip. For crafting spells the spell name IS the product name ("Black
-- Mageweave Robe"); for enchants it is the enchant ("Enchant Bracer - ..."),
-- which reads better than the scroll's name anyway.
--
-- Resolved names are REMEMBERED. This is called once per visible row per render,
-- once per recipe per filter pass, and twice per comparison by the sort
-- comparator -- and this realm has no profession cap, so one profession can be
-- most of the game's recipes. Uncached, a single keystroke in the search box
-- meant tens of thousands of GetSpellInfo calls. Only REAL names are cached:
-- the "item 12345" placeholder has to be retried until the item cache fills in.
local recipeNameCache = {}   -- spellId -> resolved display name
local recipeNameLower = {}   -- spellId -> the same, lowercased, for search
local namesChanged = false   -- a name resolved since the last filter pass

local function RecipeName(recipe)
    if not recipe then return nil end

    local cached = recipeNameCache[recipe.spell]
    if cached then return cached end

    local name = GetSpellInfo(recipe.spell)
    if not name or name == "" then name = ItemName(recipe.item) end

    if name and name ~= "" then
        recipeNameCache[recipe.spell] = name
        recipeNameLower[recipe.spell] = name:lower()
        namesChanged = true
        return name
    end

    return "item " .. tostring(recipe.item)
end

-- nil while the name is still unresolved -- see MatchesSearch, which treats
-- that case as "reachable by id" rather than "no match".
local function RecipeNameLower(recipe)
    RecipeName(recipe)                  -- fills the cache when it can
    return recipeNameLower[recipe.spell]
end

-- The display name for a BULK-PROCESSING row. FRGPROCROW carries the item's
-- real name inline from the server (WireName), so these resolve on arrival with
-- no item cache and no round trip; ItemName is only a backstop for a row that
-- somehow arrived without one.
local function ProcessName(entry)
    return entry.name or ItemName(entry.item) or ("item " .. tostring(entry.item))
end

local function ProcessNameLower(entry)
    if entry.lower then return entry.lower end

    local name = entry.name or ItemName(entry.item)
    if name and name ~= "" then
        entry.lower = name:lower()
        return entry.lower
    end
    return nil
end

local function ItemIcon(itemId, serverIcon)
    if serverIcon and serverIcon ~= "" then return serverIcon end
    if itemId and itemId ~= 0 and GetItemIcon then
        local icon = GetItemIcon(itemId)
        if icon then return icon end
    end
    return QUESTION_MARK
end

-- [#1199] A gear-target recipe has NO product item, so ItemIcon(0) would draw a
-- question mark for all 43 of them. The spell's own icon is the right picture --
-- it is what the trade window shows for a tinker -- so fall back to that.
local function RecipeIcon(recipe)
    if recipe.item and recipe.item ~= 0 then
        return ItemIcon(recipe.item, prodIcon and prodIcon[recipe.spell])
    end
    local _, _, spellIcon = GetSpellInfo(recipe.spell)
    return spellIcon or QUESTION_MARK
end

local function Commafy(n)
    n = tostring(n or 0)
    local out = n:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

local function Money(copper)
    copper = tonumber(copper) or 0
    if copper == 0 then return "free" end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = Commafy(g) .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 then parts[#parts + 1] = c .. "c" end
    return table.concat(parts, " ")
end

-- ---------------------------------------------------------------------------
-- Recipe difficulty colour, the same bands the default window uses
-- ---------------------------------------------------------------------------
local DIFFICULTY = {
    optimal    = { 1.00, 0.50, 0.25 },  -- orange
    medium     = { 1.00, 1.00, 0.00 },  -- yellow
    easy       = { 0.25, 0.75, 0.25 },  -- green
    trivial    = { 0.50, 0.50, 0.50 },  -- grey
}

local function SkillRank(skillLine)
    for _, prof in ipairs(professions) do
        if prof.skill == skillLine then return prof.rank end
    end
    return 0
end

-- Difficulty as a sortable rank, hardest first, mirroring the colour ladder the
-- default tradeskill window uses: optimal (orange/red) -> medium (yellow) ->
-- easy (green) -> trivial (grey). Kept in lockstep with DifficultyColor below --
-- if the two ever disagree the list sorts into an order its own colours contradict.
local DIFFICULTY_RANK = { optimal = 1, medium = 2, easy = 3, trivial = 4 }

-- ★★ [#790] tlow AND thigh WERE USED THE WRONG WAY ROUND, and `min` is unusable.
--
-- In 3.3.5 TrivialSkillLineRankHigh is the GREY point and ...Low is the YELLOW point,
-- with Low < High in every row of the shipped data. Testing tlow first therefore caught
-- everything at or above YELLOW and called it trivial, and made the "easy" branch
-- unreachable.
--
-- And MinSkillLineRank is 1 for every crafting recipe in the game -- gathering skills use
-- it, recipes do not -- so `rank >= recipe.min + 25` was `rank >= 26`, always true, which
-- made "optimal" unreachable as well.
--
-- Net effect at this realm's automatic Grand Master 450: 558 of 566 Jewelcrafting recipes
-- tied at "trivial", the comparator fell through to its alphabetical tiebreak, and sorting
-- by difficulty produced the A-Z list. Green sits midway between yellow and grey, exactly
-- as the client's own tradeskill window does it.
local function DifficultyTier(recipe)
    local rank   = SkillRank(recipe.skill)
    local grey   = recipe.thigh or 0
    local yellow = recipe.tlow or 0
    local green  = (grey > 0 and yellow > 0) and math.floor((grey + yellow) / 2) or 0

    if grey   > 0 and rank >= grey   then return "trivial" end
    if green  > 0 and rank >= green  then return "easy"    end
    if yellow > 0 and rank >= yellow then return "medium"  end
    return "optimal"
end

local function DifficultyColor(recipe)
    return DIFFICULTY[DifficultyTier(recipe)]
end

--[[
    [#697] 3D model preview of a recipe's product.

    ★ Equippable only. `GetItemInfo`'s 9th return is the equip location, and it is
      "" for every trade good, potion, gem and glyph -- which is most of what the
      Forge makes. DressUpModel:TryOn on one of those does nothing at all, so the
      button is hidden rather than left to click into silence.

    ⚠ GetItemInfo answers only for items in the client's cache. A miss returns nil,
      which is NOT "not equippable" -- so a miss hides the button for now and the
      next RefreshDetail re-asks. This realm ships a prebuilt item cache, so the
      miss window is small, but treating nil as "no" permanently would be wrong.

    ⚠ TryOn WITHOUT SetUnit -- see the identical note in UncappedTransmog. SetUnit
      reloads the model asynchronously and swallows a TryOn issued right after it.
]]
local previewFrame
local function EquipLocOf(itemId)
    if not itemId or itemId == 0 then return nil end
    local _, _, _, _, _, _, _, _, equipSlot = GetItemInfo(itemId)
    return equipSlot
end

function ShowModelPreview(itemId)
    local equipSlot = EquipLocOf(itemId)
    if not equipSlot or equipSlot == "" then return end

    if not previewFrame then
        previewFrame = CreateFrame("Frame", "UncappedForgePreview", UIParent)
        previewFrame:SetWidth(240)
        previewFrame:SetHeight(320)
        previewFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        -- Escape closes it, and it follows the Dashboard's zoom. Both were
        -- missing when this frame was added earlier today; a UI audit found it
        -- alongside six other pop-outs whose siblings had one or both. A
        -- UIParent-parented window that ignores the zoom slider is the visible
        -- symptom -- the suite half-scales and looks broken.
        tinsert(UISpecialFrames, "UncappedForgePreview")
        if UncappedScale_Register then
            UncappedScale_Register(previewFrame, { group = "dashboard" })
        end
        previewFrame:SetFrameStrata("DIALOG")
        previewFrame:SetMovable(true)
        previewFrame:EnableMouse(true)
        previewFrame:RegisterForDrag("LeftButton")
        previewFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
        previewFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
        previewFrame:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })

        previewFrame.title = previewFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        previewFrame.title:SetPoint("TOP", previewFrame, "TOP", 0, -16)
        previewFrame.title:SetPoint("LEFT", previewFrame, "LEFT", 16, 0)
        previewFrame.title:SetPoint("RIGHT", previewFrame, "RIGHT", -16, 0)

        previewFrame.model = CreateFrame("DressUpModel", "UncappedForgePreviewModel", previewFrame)
        previewFrame.model:SetPoint("TOPLEFT", previewFrame, "TOPLEFT", 16, -38)
        previewFrame.model:SetPoint("BOTTOMRIGHT", previewFrame, "BOTTOMRIGHT", -16, 40)

        previewFrame.close = KitButton(previewFrame, "", 80, 20)
        previewFrame.close:SetPoint("BOTTOM", previewFrame, "BOTTOM", 0, 14)
        previewFrame.close:SetText("Close")
        previewFrame.close:SetScript("OnClick", function() previewFrame:Hide() end)
    end

    previewFrame.title:SetText(ItemName(itemId) or ("item " .. tostring(itemId)))

    -- Reset to the player's own body, THEN dress. SetUnit is legitimate here (and
    -- required) because this frame shows a different item each time it opens --
    -- unlike the wardrobe, where every preview targets the same slot. The TryOn is
    -- deferred to the next frame so the asynchronous reload cannot eat it.
    previewFrame.model:SetUnit("player")
    previewFrame:Show()

    local pending = itemId
    previewFrame:SetScript("OnUpdate", function(self)
        self:SetScript("OnUpdate", nil)
        self.model:TryOn(pending)
    end)
end

--[[ ===========================================================================
     [#1199] THE GEAR-TARGET PICKER.

     A tinker, an embroidery, a fur lining or a ring enchant needs an ITEM to be
     applied to. The craft button opens this list instead of starting a job, the
     player picks a piece, and the bag/slot of that piece rides along with the
     craft request.

     ---------------------------------------------------------------------------
     WIRE FORMAT -- agreed with the server half, 2026-09-03. Both ends match this.

       server -> client, in the FRGGET burst, flushed BEFORE FRGEND, chunked at
       230 bytes like every other row type:

         FRGGEAR:spell,class,subClassMask,invTypeMask,minItemLevel;spell,...;

           class         SpellInfo::EquippedItemClass -- always >= 0 on these rows
           subClassMask  SpellInfo::EquippedItemSubClassMask
           invTypeMask   SpellInfo::EquippedItemInventoryTypeMask
           minItemLevel  floor on the target's RequiredLevel (ItemLevel if it has none)

         ⚠ The two masks are int32 and MAY CARRY THE TOP BIT, so they arrive as
           signed decimals and are compared with bit.band -- not with arithmetic
           that would read a negative as "unrestricted". 0 means "any".

       client -> server, when the player picks a target:

         FRGENCH:<spellId>:<bag>:<slot>

         ★★ ITS OWN VERB, NOT EXTRA FRGCRAFT FIELDS. HandleCraft does
            ParseFields(args, 4) and returns on any other count, so widening
            FRGCRAFT would break every ordinary craft against a server that has
            not updated -- and this realm patches the CLIENT FIRST, always, so
            that window is real and people are inside it. An unknown verb is
            simply dropped by an old server.

         ★★ THERE IS NO COUNT FIELD AND THERE MUST NOT BE ONE. The server casts
            exactly once per message. "Apply this tinker to twenty items" is not a
            feature anyone agreed to, and a count field is how it would arrive.

         ★★ bag/slot are the CLIENT's own coordinates, 1-BASED IN EVERY CASE:
              bag 0        backpack,        slot 1..GetContainerNumSlots(0)
              bag 1..4     equipped bags,   slot 1..GetContainerNumSlots(bag)
              bag 255      your own EQUIPPED gear, slot = INVSLOT_* (1 head .. 19 tabard)
            No translation to server inventory positions happens here -- the
            server half does that. (This is deliberately NOT the ICEXI/ICSOCKI
            convention on the UNC pipe, which sends server positions; FRG* is a
            different protocol with a different owner.)

       server -> client on success, immediately before its FRGDONE:

         FRGENCHOK:<spellId>:<itemEntry>
         FRGDONE:0:

         ⚠ THAT FRGDONE PRINTS NOTHING. Its success branch needs crafted > 0, and
           "produced 0 item(s) into your Vault" would be a lie. So the success
           sentence a player actually reads is written off FRGENCHOK, in this
           addon. Without it the craft succeeds in silence -- which is the exact
           shape of report #240, and the whole reason this feature exists.

     ⚠ THE SERVER RE-CHECKS THE ITEM AND IS THE AUTHORITY. The filter here is a
       convenience and deliberately FAILS OPEN (see ItemFitsTarget): 3.3.5a's
       GetItemInfo returns LOCALISED class/subclass NAMES rather than ids, so an
       unmappable name lets the item through to be judged properly rather than
       hiding gear the player can see in their own bags with no explanation.
     ========================================================================== ]]

-- INVTYPE token (GetItemInfo's 9th return) -> the numeric INVTYPE_* that
-- EquippedItemInventoryTypeMask is a bitmask over. A fixed 3.3.5a enum.
local INVTYPE_ID = {
    INVTYPE_HEAD = 1, INVTYPE_NECK = 2, INVTYPE_SHOULDER = 3, INVTYPE_BODY = 4,
    INVTYPE_CHEST = 5, INVTYPE_WAIST = 6, INVTYPE_LEGS = 7, INVTYPE_FEET = 8,
    INVTYPE_WRIST = 9, INVTYPE_HAND = 10, INVTYPE_FINGER = 11, INVTYPE_TRINKET = 12,
    INVTYPE_WEAPON = 13, INVTYPE_SHIELD = 14, INVTYPE_RANGED = 15, INVTYPE_CLOAK = 16,
    INVTYPE_2HWEAPON = 17, INVTYPE_BAG = 18, INVTYPE_TABARD = 19, INVTYPE_ROBE = 20,
    INVTYPE_WEAPONMAINHAND = 21, INVTYPE_WEAPONOFFHAND = 22, INVTYPE_HOLDABLE = 23,
    INVTYPE_AMMO = 24, INVTYPE_THROWN = 25, INVTYPE_RANGEDRIGHT = 26,
    INVTYPE_QUIVER = 27, INVTYPE_RELIC = 28,
}

--[[ Bit N of a server mask.

     ⚠ bit.band, NOT arithmetic. These are int32 and may carry the top bit, so a
       mask can arrive NEGATIVE -- and `mask <= 0 means unrestricted` would then
       silently accept every item for exactly the rules most worth honouring.
       ZERO, and only zero, is "any"; that is the server's own rule and matches
       Item::IsFitToSpellRequirements.

     bit.lshift rather than 2^n so nothing is handed a float to normalise. ]]
local function MaskHas(mask, n)
    mask = tonumber(mask) or 0
    if mask == 0 then return true end
    if not n or n < 0 or n > 31 then return false end
    return bit.band(mask, bit.lshift(1, n)) ~= 0
end

--[[ Numeric item class / subclass, which 3.3.5a's GetItemInfo does NOT give us --
     it returns the localised NAMES ("Armor", "Cloth"). The auction API returns the
     same names in a fixed order, so the ids are recovered by position, once, on
     first use.

     Only Weapon and Armor subclasses are mapped: an enchant's EquippedItemClass is
     one of those two in every case this feature covers, and a table for the other
     nine classes would be nine more chances to be wrong about an order nothing
     here reads. ]]
local classIds, subclassIds
local AH_CLASS_ID = { 2, 4, 1, 0, 16, 7, 6, 11, 9, 3, 15 }
local AH_SUBCLASS_ID = {
    [2] = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 13, 14, 15, 16, 18, 19, 20 },  -- weapon
    [4] = { 0, 1, 2, 3, 4, 6, 7, 8, 9, 10 },                              -- armor
}

local function BuildItemTypeMap()
    if classIds then return end
    classIds, subclassIds = {}, {}
    local names = { GetAuctionItemClasses() }
    for i = 1, #names do
        local id = AH_CLASS_ID[i]
        if id then
            classIds[names[i]] = id
            local order = AH_SUBCLASS_ID[id]
            if order then
                local subNames = { GetAuctionItemSubClasses(i) }
                local map = {}
                for k = 1, #subNames do
                    if order[k] then map[subNames[k]] = order[k] end
                end
                subclassIds[id] = map
            end
        end
    end
end

-- Does this item satisfy the recipe's three equipped-item rules?
--
-- ⚠ FAILS OPEN on anything it cannot resolve. A nil GetItemInfo (uncached item) or
--   an unmapped class name lets the piece through to the server, which checks it
--   properly. Hiding a piece the player can see in their bags, with no explanation,
--   is the worse failure -- and the server refusing it says why.
local INV_WEAPON   = 13   -- ⚠ NOT named INVTYPE_WEAPON: that is a real Blizzard
                          --   global holding the localised string "One-Hand", and a
                          --   file-scope local of that name would shadow it chunk-wide.
local INV_MAINHAND = 21
local INV_OFFHAND  = 22

local function ItemFitsTarget(link, req)
    if not link or not req then return false end
    local _, _, _, iLevel, reqLevel, cls, sub, _, equipLoc = GetItemInfo(link)
    -- Not equippable at all: never a target, whatever the masks say.
    if not equipLoc or equipLoc == "" then return false end

    --[[ The inventory-type rule, with the core's own special case.

         Item::IsFitToSpellRequirements accepts a plain INVTYPE_WEAPON item against
         a mask that asks for a MAINHAND or an OFFHAND -- a one-handed sword is a
         legal target for "main hand only". Leaving that out would hide every
         one-hander from Socket One-Handed Weapon, which is one of the 43. ]]
    local invId = INVTYPE_ID[equipLoc]
    local invMask = tonumber(req.inv) or 0
    if invMask ~= 0 then
        local ok = MaskHas(invMask, invId)
        if not ok and invId == INV_WEAPON then
            ok = MaskHas(invMask, INV_MAINHAND)
                or MaskHas(invMask, INV_OFFHAND)
        end
        if not ok then return false end
    end

    -- The level floor. RequiredLevel first, ItemLevel when the piece has none --
    -- the same fallback the server applies, so the two agree on a heirloom.
    local floorLvl = tonumber(req.minlvl) or 0
    if floorLvl > 0 then
        local lvl = (reqLevel and reqLevel > 0) and reqLevel or (iLevel or 0)
        if lvl < floorLvl then return false end
    end

    BuildItemTypeMap()
    local clsId = cls and classIds[cls]
    if req.class and req.class >= 0 and clsId and clsId ~= req.class then return false end
    if clsId and subclassIds[clsId] then
        local subId = sub and subclassIds[clsId][sub]
        if subId and not MaskHas(req.sub, subId) then return false end
    end
    return true
end

-- Every eligible piece, equipped first and then the bags.
--
-- ★ The bag/slot pair stored on each row is EXACTLY what FRGENCH sends: the
--   client's own numbering, 1-based, with 255 standing for "worn". No translation
--   to server inventory positions happens on this side -- see the wire note above.
local function CollectTargets(req)
    local out = {}

    -- Worn gear. bag 255, slot = the client's INVSLOT_* (1 head .. 19 tabard).
    for slot = 1, 19 do
        local link = GetInventoryItemLink("player", slot)
        if link and ItemFitsTarget(link, req) then
            out[#out + 1] = { link = link, bag = 255, slot = slot,
                              where = "Equipped",
                              tex = GetInventoryItemTexture("player", slot) }
        end
    end

    -- Backpack (bag 0) and the four equipped bags, slots 1-based as the client
    -- numbers them.
    for bag = 0, NUM_BAG_SLOTS do
        for s = 1, (GetContainerNumSlots(bag) or 0) do
            local link = GetContainerItemLink(bag, s)
            if link and ItemFitsTarget(link, req) then
                out[#out + 1] = { link = link, bag = bag, slot = s,
                                  where = (bag == 0) and "Backpack" or ("Bag " .. bag),
                                  tex = (GetContainerItemInfo(bag, s)) }
            end
        end
    end

    return out
end

local targetPicker
local TP_ROWS, TP_H = 9, 28

local function BuildTargetPicker()
    if targetPicker then return targetPicker end

    local f = CreateFrame("Frame", "UncappedForgeTargetPicker", UIParent)
    f:SetWidth(320)
    f:SetHeight(TP_ROWS * TP_H + 96)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    -- Escape closes it and it follows the Dashboard zoom -- both of which the model
    -- preview above had to be retrofitted with. Done here at build time instead.
    tinsert(UISpecialFrames, "UncappedForgeTargetPicker")
    if UncappedScale_Register then UncappedScale_Register(f, { group = "dashboard" }) end
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -16)
    f.title:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -16)
    f.title:SetJustifyH("LEFT")

    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.hint:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -36)
    f.hint:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -36)
    f.hint:SetJustifyH("LEFT")
    f.hint:SetText("Pick the piece to apply it to.")

    f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.empty:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -76)
    f.empty:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -76)
    f.empty:SetJustifyH("LEFT")
    f.empty:Hide()

    local scroll = CreateFrame("ScrollFrame", "UncappedForgeTargetScroll", f,
                               "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -56)
    scroll:SetWidth(262)
    scroll:SetHeight(TP_ROWS * TP_H)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, TP_H, function() f:Fill() end)
    end)
    f.scroll = scroll

    f.rows = {}
    for i = 1, TP_ROWS do
        local r = CreateFrame("Button", nil, f)
        r:SetHeight(TP_H - 2)
        r:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(i - 1) * TP_H)
        r:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 0, -(i - 1) * TP_H)
        r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetWidth(24); r.icon:SetHeight(24)
        r.icon:SetPoint("LEFT", 2, 0)
        r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.name:SetPoint("TOPLEFT", 30, -1); r.name:SetPoint("TOPRIGHT", -4, -1)
        r.name:SetJustifyH("LEFT")

        r.where = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        r.where:SetPoint("TOPLEFT", 30, -13); r.where:SetPoint("TOPRIGHT", -4, -13)
        r.where:SetJustifyH("LEFT")

        r:SetScript("OnClick", function(self)
            if not self.data or not f.onChoose then return end
            local chosen, cb = self.data, f.onChoose
            -- Closed BEFORE the callback: the callback sends the craft and the
            -- job progress bar takes over, and a picker still sitting on top of it
            -- invites a second click on a slot that is already being enchanted.
            f:Hide()
            cb(chosen)
        end)
        r:SetScript("OnEnter", function(self)
            if not self.data then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self.data.link)
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r:Hide()
        f.rows[i] = r
    end

    f.close = KitButton(f, "", 90, 22)
    f.close:SetPoint("BOTTOM", f, "BOTTOM", 0, 16)
    f.close:SetText("Cancel")
    f.close:SetScript("OnClick", function() f:Hide() end)

    function f:Fill()
        local list = self.items or {}
        FauxScrollFrame_Update(self.scroll, #list, TP_ROWS, TP_H)
        local offset = FauxScrollFrame_GetOffset(self.scroll)
        for i = 1, TP_ROWS do
            local r, d = self.rows[i], list[i + offset]
            if d then
                r.data = d
                r.icon:SetTexture(d.tex or QUESTION_MARK)
                r.name:SetText(d.link)          -- the link renders with its quality colour
                r.where:SetText("|cff808080" .. d.where .. "|r")
                r:Show()
            else
                r.data = nil
                r:Hide()
            end
        end
        if #list == 0 then self.empty:Show() else self.empty:Hide() end
    end

    targetPicker = f
    return f
end

local function ShowTargetPicker(title, req, onChoose)
    local f = BuildTargetPicker()
    f.title:SetText(title or "Choose an item")
    f.onChoose = onChoose
    f.items = CollectTargets(req)
    f.empty:SetText("|cffff8040Nothing you are carrying can take this.|r\n\n"
        .. "It goes on a specific kind of gear -- check the recipe's own requirement, "
        .. "and remember it can be applied to a piece you are wearing.")
    local sb = _G["UncappedForgeTargetScrollScrollBar"]
    if sb then sb:SetValue(0) end
    f:Show()
    f:Fill()
end

-- How many of this recipe the stored materials support.
--
-- The server sends this per recipe in FRGREC, because working it out here would
-- need every reagent count for every recipe. Once a recipe is SELECTED we also
-- have its exact reagent rows, which are fresher than the list snapshot (a
-- finished craft updates them), so those win when present.
local function MaxCraftable(spellId)
    local list = mats[spellId]
    if list and #list > 0 then
        local best = nil
        for _, mat in ipairs(list) do
            if mat.per > 0 then
                local possible = math.floor(mat.have / mat.per)
                if not best or possible < best then best = possible end
            end
        end
        if best then return best end
    end

    local recipe = recipesBySpell[spellId]
    return recipe and recipe.maxc or nil
end

-- ===========================================================================
-- Server comms
-- ===========================================================================
local staging = { profs = {}, recs = {}, steps = {}, needs = {}, proc = {}, vend = {},
                  pattr = {}, pmats = {},
                  gear = {} }  -- [#1199] FRGGEAR rows, committed at FRGEND only
local syncNeedsFull = false   -- a rank row for an unknown profession forces a full fetch

-- Sorting is done once over the MASTER list, not once per filter pass. The
-- order does not depend on the query or on which profession is showing, and
-- re-sorting was the expensive half of filtering: the comparator resolves two
-- names per comparison, so a keystroke used to cost O(n log n) name lookups
-- over a list that -- with no profession cap on this realm -- can be every
-- recipe in the game. Set sortDirty when the recipes, the sort mode, the skill
-- ranks (they decide the difficulty tiers) or a resolved name actually change.
local sortDirty = true

local function SortRecipes()
    if not sortDirty then return end
    sortDirty = false

    if db.sortMode == "level" then
        -- [#790] Highest recipe level first. `min` cannot be used -- it is 1 for every
        -- crafting recipe -- so this ranks on the yellow threshold, which is the recipe's
        -- real skill level plus a constant and therefore orders identically. Puts the
        -- max-level gem cuts at the top, which is the whole request.
        table.sort(recipes, function(a, b)
            local la, lb = a.tlow or 0, b.tlow or 0
            if la ~= lb then return la > lb end
            return (RecipeName(a) or "") < (RecipeName(b) or "")
        end)
    elseif db.sortMode == "difficulty" then
        --[[
            Hardest first (the ones still granting skill).

            ★★ [owner report 2026-08-16: "difficulty sorting is meh"] THE TIER
               ALONE IS NEARLY USELESS ON THIS REALM, and the note above says why
               without drawing the conclusion: every character is automatically
               Grand Master, so 558 of 566 Jewelcrafting recipes are "trivial".
               A four-bucket sort where everything lands in one bucket is not a
               sort -- it fell straight through to the alphabetical tiebreak, which
               is what made it feel like the mode did nothing.

               So the tier is now only the FIRST key. Inside a tier -- which in
               practice means inside the single enormous "trivial" bucket -- rows
               are ordered by their GREY point descending: the recipe that stayed
               useful the longest comes first. That is the closest thing to
               "difficulty" that still varies once your skill is maxed, and it puts
               the max-level cuts and the current-tier gear at the top where
               someone sorting by difficulty is looking.

            ⚠ Grey (`thigh`), not yellow (`tlow`), as the secondary key: grey is
              the point the recipe stops granting skill at all, so it orders by
              how advanced the recipe is even for rows whose yellow points tie.
              Yellow is kept as a third key for the rows where grey ties too.
        ]]
        table.sort(recipes, function(a, b)
            local ra, rb = DIFFICULTY_RANK[DifficultyTier(a)], DIFFICULTY_RANK[DifficultyTier(b)]
            if ra ~= rb then return ra < rb end

            local ga, gb = a.thigh or 0, b.thigh or 0
            if ga ~= gb then return ga > gb end

            local ya, yb = a.tlow or 0, b.tlow or 0
            if ya ~= yb then return ya > yb end

            return (RecipeName(a) or "") < (RecipeName(b) or "")
        end)
    else
        table.sort(recipes, function(a, b)
            return (RecipeName(a) or "") < (RecipeName(b) or "")
        end)
    end
end

--[[
    [#922] Sort the BULK-PROCESSING list.

    ★ THE BUG THIS EXISTS FOR. The window has one sort dropdown; it sorted `recipes`.
      The Disenchant tab renders `processable`, which was ordered exactly once -- by
      stack size, at FRGPROCEND -- and by nothing else, ever. The dropdown stayed on
      screen there, accepted "Difficulty", relabelled itself and changed nothing.

    Kept as its own function against its own db key rather than folded into
    SortRecipes: the two lists have genuinely different sort axes ("difficulty" means
    the skill-up colour ladder for a recipe and the required disenchant skill here),
    and one setting driving both is what produced the original defect.

    Unlike SortRecipes there is no dirty flag. This list is at most a few hundred rows
    and is only re-sorted when it arrives or when the setting changes, not per
    keystroke -- the expense SortRecipes' flag exists to avoid does not apply.
]]
local function SortProcessable()
    local mode = db.procSortMode

    if mode == "difficulty" then
        table.sort(processable, function(a, b)
            -- Hardest first, matching the recipe list's own direction. A row with no
            -- attributes (millable, prospectable, or an old server that sends none)
            -- has no skill to compare, so it sorts to the bottom rather than
            -- interleaving at zero and looking like the sort is broken.
            local sa = procAttr[a.item] and procAttr[a.item].skill or -1
            local sb = procAttr[b.item] and procAttr[b.item].skill or -1
            if sa ~= sb then return sa > sb end
            return (ProcessName(a) or "") < (ProcessName(b) or "")
        end)
    elseif mode == "name" then
        table.sort(processable, function(a, b)
            return (ProcessName(a) or "") < (ProcessName(b) or "")
        end)
    else
        -- "count", and the default: biggest pile first, which is what this list did
        -- before and is still the most useful order for bulk work.
        table.sort(processable, function(a, b) return a.count > b.count end)
    end
end

local function ApplyFilter()
    SortRecipes()

    -- Search composes with the profession dropdown and the craftable-only tick
    -- rather than replacing them: typing narrows what those two already chose.
    filtered = {}
    for _, recipe in ipairs(recipes) do
        local ok = (not selectedSkill) or recipe.skill == selectedSkill

        if ok then ok = MatchesSearch(RecipeNameLower(recipe), recipe.item) end

        if ok and db.craftableOnly then
            local possible = MaxCraftable(recipe.spell)
            -- Unknown (never asked) is kept: hiding recipes we simply have not
            -- fetched material counts for would make the list look broken.
            ok = (possible == nil) or possible > 0

            -- [owner request 2026-08-17] "...or buyable" widens the tick above rather
            -- than replacing it, so the two compose the way the search and the
            -- profession dropdown already do.
            --
            -- ⚠ Read from buyableSet, NOT recomputed here. Whether a reagent is
            --   vendor-sold for gold depends on ExtendedCost, stock limits, an
            --   excluded vendor and BuyPrice -- none of which the client can see. The
            --   server owns that rule (ForgeCraft::IsGoldBuyable) and a client-side
            --   guess would quietly disagree with what the Buy button actually does.
            if not ok and db.buyableToo then
                ok = buyableSet[recipe.spell] and true or false
            end
        end

        if ok then filtered[#filtered + 1] = recipe end
    end

    -- The same box filters the bulk-processing view, which is the other list
    -- this window can show. `processable` arrives already ordered by stack size
    -- (see FRGPROCEND), so this only ever drops rows -- never reorders them.
    -- [Custom] The Rendering tab is this same list restricted to rows that can
    -- ACTUALLY render. No new server call and no protocol change: `kinds` already
    -- rides on every FRGPROCROW, it was simply never used to filter.
    local view = frame and ProcView(frame.mode)

    filteredProc = {}
    for _, entry in ipairs(processable) do
        -- No view (still on a crafting tab) keeps every row: the list is not on
        -- screen, and filtering it to nothing would only make a later switch
        -- flash empty before the next ApplyFilter.
        local kindOk = (not view)
            or (bit.band(entry.kinds or 0, view.mask) ~= 0)

        --[[
            [#922] "Only show me things that could give me Arcane Dust."

            ⚠ Applied ONLY on the disenchant view. The material a row yields is a
              disenchant concept -- milling and prospecting have their own outputs and
              are sent no tier at all -- so letting this filter run on those tabs would
              empty them for a reason the player cannot see. That is the same shape as
              the bug being fixed here, one tab over.

            The answer comes from the server's yield table, not from a guess: the
            client has no way to know what an item breaks down into.
        ]]
        if kindOk and view and view.mask == KIND_DISENCHANT and db.procMaterial ~= 0 then
            local attr = procAttr[entry.item]
            local mats = attr and tierMats[attr.tier]
            kindOk = (mats and mats[db.procMaterial]) and true or false
        end

        if kindOk and MatchesSearch(ProcessNameLower(entry), entry.item) then
            filteredProc[#filteredProc + 1] = entry
        end
    end
end

-- Forward locals: the comms handler below fires before these are defined, and
-- professions/recipes arrive asynchronously after the window is already open.
local RefreshList, RefreshDetail, RefreshProgress, BuildProfessionTabs, ResetScroll
-- [#922] Shows/hides and repopulates the controls that belong to one list or the
-- other. Forward-declared because the FRGPROCEND handler calls it and the UI that
-- defines it is built several hundred lines below.
local RefreshProcControls

-- Forward-declared for the same reason as the line above: the FRGDONE handler
-- calls it and sits ~200 lines ABOVE where SelectRecipe (which it needs) is
-- defined. Declaring it here and assigning it later is what keeps it from being
-- a nil global at call time.
local AdvanceToNextCraftable

local comms = CreateFrame("Frame")
comms:RegisterEvent("CHAT_MSG_ADDON")
comms:SetScript("OnEvent", function(_, _, prefix, body)
    if prefix ~= ADDON_PIPE_PREFIX or not body then return end

    if body:find("^FRGPROF:") then
        for skill, rank, max, name in body:gmatch("(%d+),(%d+),(%d+),([^;]*);") do
            staging.profs[#staging.profs + 1] = {
                skill = tonumber(skill), rank = tonumber(rank), max = tonumber(max), name = name }
        end

    elseif body:find("^FRGSYNC:") then
        -- Rank-only update. Applied in place so difficulty colours re-shade after a
        -- skill-up without refetching hundreds of recipe rows.
        for skill, rank, max in body:gmatch("(%d+),(%d+),(%d+);") do
            skill, rank, max = tonumber(skill), tonumber(rank), tonumber(max)
            local found = false
            for _, prof in ipairs(professions) do
                if prof.skill == skill then
                    prof.rank, prof.max = rank, max
                    found = true
                    break
                end
            end
            -- A profession we have never seen means a brand new one was learned;
            -- the count check below will pull the full list.
            if not found then syncNeedsFull = true end
        end

    elseif body:find("^FRGSYNCEND:") then
        local count = tonumber(body:match("^FRGSYNCEND:(%d+)$"))
        if count and (syncNeedsFull or count ~= #recipes) then
            -- The known-recipe set actually changed: now it is worth the full list.
            syncNeedsFull = false
            Send("FRGGET")
        else
            -- Ranks only. Re-render so colours and the profession label update.
            -- Ranks decide the difficulty tiers, so a difficulty sort is stale.
            sortDirty = true
            BuildProfessionTabs()
            ApplyFilter()
            RefreshList()
            RefreshDetail()
        end

    elseif body:find("^FRGREC:") then
        for spell, item, yield, skill, minR, tlow, thigh, tool, maxc, target in
            body:gmatch("(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+);") do
            staging.recs[#staging.recs + 1] = {
                spell = tonumber(spell), item = tonumber(item), yield = tonumber(yield),
                skill = tonumber(skill), min = tonumber(minR),
                tlow = tonumber(tlow), thigh = tonumber(thigh), tool = tonumber(tool),
                maxc = tonumber(maxc), target = tonumber(target) }
        end

    --[[
        FRGCNT / FRGCNTEND -- counts-only refresh (owner report 2026-08-16).

        ★ Updates `maxc` IN PLACE on the existing recipe objects rather than
          staging a new list. There is no staging buffer here on purpose: a counts
          refresh must never be able to replace or reorder the recipe list, only
          correct the numbers on it. If a spell is unknown (the player learned a
          recipe since the last full fetch) the row is ignored -- FRGSYNC is what
          notices the recipe COUNT changed and triggers a real re-fetch.
    ]]
    --[[
        FRGVEND -- the "...or buyable" set (owner request 2026-08-17).

        Staged, never applied directly, and committed only at FRGEND / FRGCNTEND.
        ★ The commit REPLACES the set rather than merging into it, which is what
          makes "no longer buyable" expressible: the server sends only the spells
          that ARE buyable, so a recipe that dropped out simply stops appearing in
          the burst. Merging would make the set grow forever and never un-tick.
        ⚠ Must be matched BEFORE FRGREC would be tried by any looser pattern -- it is
          its own prefix, so order in this chain is not load-bearing today, but the
          two share the FRG prefix and a future `find` without the `^` anchor would
          make it matter.
    ]]
    elseif body:find("^FRGVEND:") then
        for spell in body:gmatch("(%d+);") do
            staging.vend[tonumber(spell)] = true
        end

    --[[
        [#1199] FRGGEAR:spell,class,subClassMask,invTypeMask,minItemLevel;...

        Recipes that enchant a piece of gear you already own. Its own row type for
        exactly the reason FRGVEND is -- see the long note at `gearTargets` and at
        the FRGVEND site in forge_comms_playerscript.cpp.

        ⚠ The two masks are int32 and may carry the TOP BIT, so they can arrive as
          negative decimals. The pattern accepts a leading minus -- written `%-`,
          because a bare `-` after a capture group is Lua's lazy quantifier -- and
          MaskHas compares them with bit.band rather than arithmetic.

        Staged, and committed ONLY at FRGEND (not at FRGCNTEND) -- the counts
        refresh does not carry these rows, so replacing there would empty the set.
    ]]
    elseif body:find("^FRGGEAR:") then
        for spell, cls, sub, inv, minlvl in
            body:gmatch("(%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+);") do
            staging.gear[tonumber(spell)] = {
                class = tonumber(cls), sub = tonumber(sub), inv = tonumber(inv),
                minlvl = tonumber(minlvl) }
        end

    --[[
        [#1199] FRGENCHOK:<spellId>:<itemEntry> -- the enchant landed.

        ★ THIS IS THE ONLY THING THAT TELLS THE PLAYER IT WORKED. The FRGDONE that
          follows carries crafted = 0 and an empty failure, and that handler's
          success branch requires crafted > 0 -- correctly, because "produced 0
          item(s) into your Vault" would be a lie about a recipe that produces
          nothing. So a silent FRGDONE plus no line here is a craft that appears to
          do nothing at all, which is precisely the report #240 shape this whole
          feature exists to end.

        Arrives BEFORE its FRGDONE, so nothing here has to be deferred.
    ]]
    elseif body:find("^FRGENCHOK:") then
        local spellId, itemEntry = body:match("^FRGENCHOK:(%d+):(%d+)$")
        if spellId then
            local what = GetSpellInfo(tonumber(spellId)) or "That enchantment"
            local onto = ItemName(tonumber(itemEntry)) or "your item"
            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                "|cffff8040[Forge]|r applied |cffffffff%s|r to |cffffffff%s|r.", what, onto))
        end

    elseif body:find("^FRGCNT:") then
        for spell, maxc in body:gmatch("(%d+),(%d+);") do
            local recipe = recipesBySpell[tonumber(spell)]
            if recipe then recipe.maxc = tonumber(maxc) end
        end

    elseif body:find("^FRGCNTEND:") then
        -- A craft moves material, so a recipe the player never touched can start or
        -- stop being buyable. Replaced wholesale for the same reason as at FRGEND.
        buyableSet = staging.vend
        staging.vend = {}

        -- ⚠ Both are needed. The craftable-only tick filters ON the count, and the
        --   "craftable" sort mode ORDERS on it, so a changed count can change both
        --   which rows show and what order they are in.
        sortDirty = true
        ApplyFilter()
        RefreshDetail()

    elseif body:find("^FRGEND:") then
        professions = staging.profs
        recipes = staging.recs
        staging.profs, staging.recs = {}, {}

        -- Committed with the list it describes, in the same frame, so the filter can
        -- never run against a buyable set belonging to a previous fetch.
        buyableSet = staging.vend
        staging.vend = {}

        -- [#1199] Same commit point, same reason: a gear-target rule must never be
        -- attached to a recipe list from a previous fetch. Replaced wholesale, so a
        -- recipe that stops being gear-targeted stops opening the picker.
        gearTargets = staging.gear
        staging.gear = {}

        recipesBySpell = {}
        for _, recipe in ipairs(recipes) do
            recipesBySpell[recipe.spell] = recipe
            ItemName(recipe.item)   -- warm the name cache for the list
        end

        if not selectedSkill and professions[1] then selectedSkill = professions[1].skill end

        sortDirty = true    -- a brand new list, in whatever order the server sent it

        -- Tabs are built HERE as well as on open: the profession list arrives
        -- asynchronously, so on the very first open there was nothing to build
        -- from yet and the window came up with no tabs at all.
        BuildProfessionTabs()
        ApplyFilter()
        RefreshList()
        RefreshDetail()

    elseif body:find("^FRGMAT:") then
        local spellId = tonumber(body:match("^FRGMAT:(%d+):"))
        if spellId then
            -- UPSERT BY ITEM ID, not replace. A row carries the icon and the item
            -- name inline, so it runs 45-70 bytes rather than ~20: five reagents
            -- pass the 255-byte addon limit, the server's Chunker splits them over
            -- two messages, and replacing keeps only the last chunk. Keying on item
            -- id still cannot double -- this is re-requested after every craft, and
            -- a re-sent row overwrites its own key instead of piling up.
            local list = mats[spellId] or {}
            local byItem = {}
            for i, mat in ipairs(list) do byItem[mat.item] = i end
            -- The NAME is last and parsed as "everything up to the ;", so an item
            -- name containing a comma cannot shift the fields after it.
            for item, per, have, icon, name in body:gmatch("(%d+),(%d+),(%d+),([^,]*),([^;]*);") do
                local row = { item = tonumber(item), per = tonumber(per), have = tonumber(have),
                    icon = (icon ~= "" and ("Interface\\Icons\\" .. icon)) or nil,
                    name = (name ~= "" and name) or nil }
                local at = byItem[row.item]
                if at then
                    list[at] = row
                else
                    list[#list + 1] = row
                    byItem[row.item] = #list
                end
            end
            mats[spellId] = list
            if spellId == selectedSpell then
                ApplyFilter()   -- fresher counts can change the craftable filter
                RefreshDetail()
            end

            --[[
                Report #737, second half. A craft that ENDED CLEANLY still leaves
                you on a recipe you may no longer be able to make -- see the note
                on advanceWhenMatsLand. These are the fresh counts, so now the
                question can be answered honestly.

                Cleared BEFORE advancing, not after: AdvanceToNextCraftable calls
                SelectRecipe, which sends FRGMATS for the NEW recipe, and that
                reply lands back here. Leaving the flag set would walk the list.

                MaxCraftable() falls back to the list snapshot when a recipe has
                no reagent rows, and that snapshot is stale between full fetches
                -- so `possible` may be nil for the row we are on. nil is treated
                as "do not move", because moving off a recipe on the strength of a
                number we never asked for is worse than leaving the player where
                they chose to be.
            ]]
            if advanceWhenMatsLand == spellId and spellId == selectedSpell then
                advanceWhenMatsLand = nil
                local possible = MaxCraftable(spellId)
                if possible and possible <= 0 then
                    AdvanceToNextCraftable()
                end
            end
        end

    elseif body:find("^FRGPROD:") then
        local spellId, item, icon = body:match("^FRGPROD:(%d+):(%d+),([^;]*)$")
        if spellId then
            spellId = tonumber(spellId)
            if icon and icon ~= "" then prodIcon[spellId] = "Interface\\Icons\\" .. icon end
            ItemName(tonumber(item))
            if spellId == selectedSpell then RefreshDetail() end
        end

    elseif body:find("^FRGPLANROW:") then
        -- 6-field rows carry the step kind and a preset label (harvest steps have
        -- no spell to name themselves from); label is last and may contain commas,
        -- so it is parsed as "up to the ;".
        --
        -- Falls back to the legacy 4-field row, so this addon keeps working against
        -- a server that has not been updated yet -- otherwise publishing the client
        -- ahead of the server empties the "Will also make first" list. Same
        -- backward-compatible parse the Vault window uses for its row format.
        local any6 = false
        for spell, item, crafts, depth, kind, label in
            body:gmatch("(%d+),(%d+),(%d+),(%d+),(%d+),([^;]*);") do
            any6 = true
            staging.steps[#staging.steps + 1] = { spell = tonumber(spell), item = tonumber(item),
                crafts = tonumber(crafts), depth = tonumber(depth), kind = tonumber(kind),
                label = (label ~= "" and label) or nil }
        end

        if not any6 then
            for spell, item, crafts, depth in body:gmatch("(%d+),(%d+),(%d+),(%d+);") do
                staging.steps[#staging.steps + 1] = { spell = tonumber(spell), item = tonumber(item),
                    crafts = tonumber(crafts), depth = tonumber(depth), kind = 0 }
            end
        end

    elseif body:find("^FRGPLANNEED:") then
        for item, missing, name in body:gmatch("(%d+),(%d+),([^;]*);") do
            staging.needs[#staging.needs + 1] = { item = tonumber(item), missing = tonumber(missing),
                name = (name ~= "" and name) or nil }
        end

    elseif body:find("^FRGPLANEND:") then
        local spellId, total, feasible = body:match("^FRGPLANEND:(%d+):(%d+):(%d+)$")
        spellId = tonumber(spellId)
        -- Discard a plan response for a recipe the player has since clicked away
        -- from -- otherwise a late reply for the OLD recipe can clobber `plan`
        -- after SelectRecipe already reset it for the new one, and the buy
        -- button below reads `plan.needs` without knowing whose plan it is.
        if spellId == selectedSpell then
            plan = { steps = staging.steps, needs = staging.needs,
                     total = tonumber(total) or 0, feasible = (feasible == "1"),
                     spell = spellId }
            RefreshDetail()
        end
        staging.steps, staging.needs = {}, {}

    elseif body:find("^FRGPROG:") then
        local done, total, crafted = body:match("^FRGPROG:(%d+):(%d+):(%d+)$")
        if done then
            job = { done = tonumber(done), total = tonumber(total), crafted = tonumber(crafted) }
            RefreshProgress()
        end

    -- [DE-02] Optional, and always sent BEFORE the FRGDONE it describes.
    elseif body:find("^FRGDEST:") then
        craftDest = body:match("^FRGDEST:(%a+)$")

    elseif body:find("^FRGDONE:") then
        local crafted, failure = body:match("^FRGDONE:(%d+):(.*)$")
        crafted = tonumber(crafted) or 0
        job = nil
        RefreshProgress()

        -- [DE-02] Consume the destination hint. Absent (old server, or an
        -- ordinary vault-bound craft) reads as the Vault, which is what every
        -- output path except a container product actually does.
        local where = (craftDest == "bags") and " into your bags" or " into your Vault"
        craftDest = nil

        local FAILURES = {
            reagents  = "ran out of materials",
            -- Two causes now, and the second is the common one on a bulk render:
            -- a conversion has to hold its source as a REAL item to cast from,
            -- so a full bag stops it even when the output is the Vault.
            bagsfull  = "your bags are full -- clear a slot, or send the output to your Vault",
            uniquecap = "you already have as many of that as you can own",
            novellum  = "out of vellums, or no free bag slot to hold one",
            nospace   = "no free bag space -- a scroll still needs one slot to be made in",
            dead      = "you can't craft while dead",
            unknown   = "you don't know that recipe",
            busy      = "a craft is already running",
            missing   = "you're missing materials it can't make or buy",
            outofmats = "not enough of that material left",
            -- Report #467: this line exists so "bags are full" stops being the
            -- server's catch-all guess. A conversion can only cast from a plain
            -- Vault stack, so material sitting in your BANK -- or still loading
            -- right after you log in -- is counted but cannot be spent.
            unreachablemats = "that material isn't in your Vault where the Forge can reach it "
                .. "-- bank stock doesn't count. Deposit it, or try again in a moment",
            -- Report #479: a render source is only off-limits while the quest
            -- that wants it is in your log. The server names the quest in a
            -- separate chat line -- the wire format has no field for it.
            questlocked = "a quest in your log is still waiting on that material",
            harvestshort = "the milling/prospecting didn't turn up enough -- it's a roll, so try again",
            cannot    = "that can't be processed",
            money     = "you can't afford that",
            cancelled = "cancelled",
            offline   = "you went offline",
            noplan    = "nothing to do",

            -- [#1199] The gear-enchant refusals (FRGENCH). Named rather than left
            -- to the "failed (token)" fallback, because every one of them has an
            -- action attached and a raw token has none.
            noitem       = "that item isn't there any more -- it moved or was used",
            badtarget    = "that enchant doesn't go on that item",
            itemlowlevel = "that item's level is too low for this enchant",
            -- The core refuses to overwrite a use-effect enchant, because doing so
            -- would destroy the clicky the item was carrying.
            onuseenchant = "that item already carries a use-effect enchant, and this "
                .. "would replace it",
            maxsockets   = "that item already has as many sockets as it can hold",
        }

        -- A bulk craft that runs out of a scarcer reagent partway through (e.g.
        -- Inscription hitting the end of a rare pigment) still crafted > 0
        -- items before stopping. Reporting that as two separate lines --
        -- a failure ("ran out of materials") immediately followed by a success
        -- ("produced Nx item(s)") -- reads as a straight contradiction. One
        -- combined line when both are true; the original single-line behavior
        -- is unchanged when only one of them is.
        if crafted > 0 and failure and failure ~= "" then
            local why = FAILURES[failure] or ("failed (" .. failure .. ")")
            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                "|cffff8040[Forge]|r produced |cffffffff%s|r item(s)%s, then stopped -- %s.",
                Commafy(crafted), where, why))
        elseif failure and failure ~= "" then
            local why = FAILURES[failure] or ("failed (" .. failure .. ")")
            DEFAULT_CHAT_FRAME:AddMessage("|cffff8040[Forge]|r " .. why)
        elseif crafted > 0 then
            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                "|cffff8040[Forge]|r produced |cffffffff%s|r item(s)%s.",
                Commafy(crafted), where))
        end

        -- Counts moved; re-ask rather than guessing at them locally. A craft is
        -- also the main way skill goes up, so re-check ranks and the recipe count.
        if selectedSpell then Send("FRGMATS:" .. selectedSpell) end
        Send("FRGPROCLIST")
        Send("FRGSYNC")

        -- ★ [owner report 2026-08-16] "after a craft the numbers available don't
        --   update". FRGMATS above only refreshes the SELECTED recipe's reagent
        --   rows; every other row in the list draws its number from `maxc`, which
        --   arrives with FRGREC and was therefore frozen at whatever it was when
        --   the window opened. A craft consumes material that other recipes share,
        --   so one craft can change every count on screen.
        Send("FRGCOUNTS")

        -- [Custom] Owner request: a Craft All that ends because the materials ran
        -- out leaves you on a recipe you can no longer make. Move to the next one
        -- you can, so a profession grind does not need a click between every
        -- batch. Only these failures mean "out of stock" -- a full bag or a
        -- missing vellum is a different problem and the player should stay put
        -- and see it rather than have the selection moved out from under them.
        local OUT_OF_MATERIALS = {
            reagents        = true,
            outofmats       = true,
            missing         = true,
            unreachablemats = true,
        }

        advanceWhenMatsLand = nil

        if frame and frame.mode == "craft" then
            if failure and OUT_OF_MATERIALS[failure] then
                AdvanceToNextCraftable()
            elseif (not failure or failure == "") and crafted > 0 and selectedSpell then
                -- Report #737. A CLEAN finish is exactly what "Craft All" always
                -- produces, so this is the branch that actually fires for it. The
                -- decision waits for the refreshed counts requested just above --
                -- see the note on advanceWhenMatsLand and the FRGMAT handler.
                advanceWhenMatsLand = selectedSpell
            end
        end

    elseif body:find("^FRGPROCROW:") then
        -- `perOp` arrives from the server rather than being assumed here. It used
        -- to be a client-side constant (5, or 1 for disenchant), which stopped
        -- being expressible the moment rendering landed: a render's rate is set
        -- per SOURCE by that source's own spell, 100 junk meat per Rendered
        -- Tallow at the bottom band and 15 at the top, and nothing in the client
        -- can see a custom spell's reagent count.
        for item, count, kinds, perOp, name in body:gmatch("(%d+),(%d+),(%d+),(%d+),([^;]*);") do
            staging.proc[#staging.proc + 1] = { item = tonumber(item), count = tonumber(count),
                kinds = tonumber(kinds), perOp = tonumber(perOp),
                name = (name ~= "" and name) or nil }
        end

    --[[
        FRGPROCX / FRGDEMAT -- the Disenchant tab's own attributes ([#922]).

        Staged like everything else and committed at FRGPROCEND, so the list and the
        data describing it are never applied a burst apart. Both are absent from an
        old server, which leaves the tables empty and the tab behaving exactly as it
        did before.
    ]]
    elseif body:find("^FRGPROCX:") then
        for item, skill, tier in body:gmatch("(%d+),(%d+),(%d+);") do
            staging.pattr[tonumber(item)] = { skill = tonumber(skill), tier = tonumber(tier) }
        end

    elseif body:find("^FRGDEMAT:") then
        for tier, mat in body:gmatch("(%d+),(%d+);") do
            tier = tonumber(tier)
            staging.pmats[tier] = staging.pmats[tier] or {}
            staging.pmats[tier][tonumber(mat)] = true
        end

    elseif body:find("^FRGPROCEND:") then
        processable = staging.proc
        procAttr    = staging.pattr
        tierMats    = staging.pmats
        staging.proc, staging.pattr, staging.pmats = {}, {}, {}

        -- Which materials are actually reachable from what this player is holding.
        -- Rebuilt from scratch every burst so a material that is no longer reachable
        -- stops being offered, rather than lingering as a filter that matches nothing.
        matPresent = {}
        for _, entry in ipairs(processable) do
            local attr = procAttr[entry.item]
            local mats = attr and tierMats[attr.tier]
            if mats then
                for mat in pairs(mats) do
                    matPresent[mat] = true
                    ItemName(mat)   -- warm the cache so the dropdown has names to show
                end
            end
        end

        -- ⚠ If the selected material has gone, fall back to "any" rather than leaving
        --   a filter selected that can only ever produce an empty list.
        if db.procMaterial ~= 0 and not matPresent[db.procMaterial] then
            db.procMaterial = 0
        end

        SortProcessable()
        ApplyFilter()   -- rebuilds filteredProc against the current query
        if frame and ProcView(frame.mode) then
            -- Guarded like the mode switches: this is assigned when the window is
            -- built, and a burst arriving before that would otherwise be a nil call.
            if RefreshProcControls then RefreshProcControls() end
            RefreshList()
        end

    elseif body:find("^FRGQUOTED:") then
        local cost, buy, tokenOnly, unbuyable = body:match("^FRGQUOTED:(%d+):(%d+):(%d+):(%d+)$")
        if cost then
            quote = { cost = tonumber(cost), buy = tonumber(buy),
                      tokenOnly = tonumber(tokenOnly), unbuyable = tonumber(unbuyable) }
            RefreshDetail()
        end

    elseif body:find("^FRGBOUGHT:") then
        local cost, kinds = body:match("^FRGBOUGHT:(%d+):(%d+)$")
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "|cffff8040[Forge]|r bought %s material type(s) for %s -- sent to your Vault.",
            kinds or "?", Money(cost)))
        quote = nil
        if selectedSpell then Send("FRGMATS:" .. selectedSpell) end
        -- Buying materials moves counts for every recipe sharing them, exactly as
        -- a craft does. Same refresh.
        Send("FRGCOUNTS")

    -- "Where do I farm this?" replies. These use the older RB* protocol rather
    -- than FRG*, because the server handler is shared with the reagent-bank
    -- channel and predates the Forge -- see the source-panel block near the
    -- bottom of this file. Buffer until the terminator, then draw once.
    --
    -- USRC:<itemId>:<kind>:<chanceTenths>:<spawns>:<dungeon>:<name>|<zone>|<via>
    elseif body:find("^USRC:") then
        local kind, chance, spawns, dungeon, rest =
            body:match("^USRC:%d+:(%d+):(%d+):(%d+):(%d+):(.*)$")
        if rest then
            local name, zone, via = rest:match("^(.-)|(.-)|(.*)$")
            UncappedForge_SourceBufferAdd({
                kind = tonumber(kind) or 1,
                chance = tonumber(chance) or 0,
                spawns = tonumber(spawns) or 0,
                dungeon = (tonumber(dungeon) or 0) ~= 0,
                name = name or rest,
                zone = zone or "",
                via = via or "",
            })
        end

    elseif body:find("^USRCEND:") then
        UncappedForge_ShowSources(UncappedForge_SourcePendingName())
    end
end)

-- Names arriving from the item cache change what the list should say, so
-- re-render periodically while anything is still unresolved.
--
-- Also runs the search box's debounce (see QueueSearch), which is why the first
-- block is per-frame rather than on the 0.5s beat -- half a second between
-- typing a letter and the list moving would feel broken.
local ticker = CreateFrame("Frame")
local sinceTick = 0
ticker:SetScript("OnUpdate", function(_, elapsed)
    if searchWait then
        searchWait = searchWait - elapsed
        if searchWait <= 0 then
            searchWait = nil
            ApplyFilter()
            -- Back to the top: the row you were scrolled to has nothing to do
            -- with the rows a new query leaves behind.
            ResetScroll()
            RefreshList()
        end
    end

    sinceTick = sinceTick + elapsed
    if sinceTick < 0.5 then return end
    sinceTick = 0

    if frame and frame:IsShown() then
        -- A name that only just arrived from the item cache changes both the
        -- sort order and what the search can find, so re-filter -- but only when
        -- something actually resolved, not on every beat.
        --
        -- ★ [DE-13] The two refreshes live INSIDE this branch now. They used to
        -- run unconditionally on the 0.5s beat, redrawing byte-identical text
        -- twice a second for as long as the window was open -- and
        -- RefreshDetail rebuilds every line of the pane. `namesChanged` is the
        -- precise signal that something resolved, and all sixteen other code
        -- paths that change data already call these explicitly.
        if namesChanged then
            namesChanged = false
            sortDirty = true
            ApplyFilter()
            RefreshList()
            RefreshDetail()
        end
    end
end)

-- ===========================================================================
-- UI
-- ===========================================================================
-- ROWS is now how many rows currently FIT (recomputed on resize, see
-- listScroll's OnSizeChanged below) -- MAX_ROWS is just the size of the
-- pooled button/row frames, generous enough for a tall window.
local ROWS, ROW_HEIGHT = 14, 22
local MAX_ROWS = 30
-- No title/banner/close row anymore (see BuildFrame) -- shifted up ~30px
-- from the original standalone-window offsets.
local LIST_TOP = -46
-- Space reserved at the bottom of the frame for the amount/craft/buy row,
-- the process-mode buttons, the output checkboxes, and the progress bar --
-- listFrame/detail stop this far above the frame's bottom edge rather than
-- filling all the way down into them.
local BOTTOM_RESERVE = 90

-- FauxScrollFrame's scrollbar is a GLOBAL named "<frameName>ScrollBar" in 3.3.5.
-- There is no `.ScrollBar` field on the frame -- that is a later-expansion thing,
-- and touching it here would be a nil index every time a tab was clicked.
function ResetScroll()
    if not listScroll then return end
    FauxScrollFrame_SetOffset(listScroll, 0)
    local bar = _G["UncappedForgeScrollScrollBar"]
    if bar then bar:SetValue(0) end
end

local function RequestedAmount()
    local amount = tonumber(frame and frame.amount and frame.amount:GetText() or "") or 1
    if amount < 1 then amount = 1 end
    if amount > 10000 then amount = 10000 end
    return math.floor(amount)
end

-- Asks the server what making the current amount would actually involve, so the
-- detail pane can show the intermediates and the gaps BEFORE anything is spent.
-- Deliberately not fired per keystroke; see the amount box handlers.
local function RequestPlan()
    if not selectedSpell then return end
    staging.steps, staging.needs = {}, {}
    Send(string.format("FRGPLAN:%d:%d:%d", selectedSpell, RequestedAmount(),
        db.autoIntermediates and 1 or 0))
end

local function SelectRecipe(spellId)
    selectedSpell = spellId
    quote = nil
    -- Any pending #737 advance belonged to the recipe we are leaving. Choosing a
    -- recipe by hand is the player overriding it, and a stale flag would move
    -- them off their own choice the moment its counts arrived.
    advanceWhenMatsLand = nil
    plan = { steps = {}, needs = {}, total = 0, feasible = true }
    staging.steps, staging.needs = {}, {}
    if spellId then
        Send("FRGMATS:" .. spellId)
        RequestPlan()
    end
    RefreshList()
    RefreshDetail()
end

--[[
    Move the selection to the next recipe you can still make.

    Owner request 2026-08-12: after "Craft All" empties a material you are left
    staring at a recipe that can no longer be made, and picking the next one by
    hand is the annoying part of grinding a profession.

    Assigned (not declared) here: this is the forward-declared local from the top
    of the file, and it CANNOT be defined earlier because it calls SelectRecipe,
    which is defined directly above. The FRGDONE handler that calls it lives ~200
    lines further up.

    Searches from the CURRENT position and wraps, so it walks the list in the
    order you see it and eventually returns to the top rather than jumping around.

    ⚠ It deliberately does NOT re-request material counts first. Those arrive
    asynchronously (FRGMAT), so the numbers it reads are the ones from before the
    craft -- fresh enough to rank other recipes, and the panel self-corrects a
    moment later when the new counts land. Waiting for them would mean the
    selection visibly lurches a second after the craft ends, which is worse.
]]
function AdvanceToNextCraftable()
    if not selectedSpell or #filtered == 0 then
        return
    end

    local start = 0
    for i, recipe in ipairs(filtered) do
        if recipe.spell == selectedSpell then
            start = i
            break
        end
    end

    for step = 1, #filtered do
        local recipe = filtered[((start - 1 + step) % #filtered) + 1]
        if recipe.spell ~= selectedSpell then
            local possible = MaxCraftable(recipe.spell)
            -- `nil` means "never asked", which is not the same as "cannot make"
            -- -- skip it rather than landing the player on an unknown.
            if possible and possible > 0 then
                SelectRecipe(recipe.spell)
                DEFAULT_CHAT_FRAME:AddMessage(string.format(
                    "|cffff8040[Forge]|r moved on to |cffffffff%s|r (enough for %s).",
                    RecipeName(recipe) or ("spell " .. recipe.spell), Commafy(possible)))
                return
            end
        end
    end
end

function RefreshList()
    if not frame or not listButtons then return end

    local isProcess = ProcView(frame.mode) ~= nil
    local source = isProcess and filteredProc or filtered
    local offset = FauxScrollFrame_GetOffset(listScroll) or 0

    FauxScrollFrame_Update(listScroll, #source, ROWS, ROW_HEIGHT)

    -- An empty list with no explanation reads as a broken window rather than a
    -- filter with no hits, and now that a search can empty it that is a state
    -- players will hit routinely.
    if frame.emptyText then
        if #source > 0 then
            frame.emptyText:Hide()
        else
            if searchQuery ~= "" then
                -- Escape the pipe: a query containing "|c" would otherwise be
                -- read back as a colour escape and eat the rest of the line.
                frame.emptyText:SetText("Nothing here matches \""
                    .. searchRaw:gsub("|", "||") .. "\".")
            elseif isProcess then
                frame.emptyText:SetText("Nothing in your Vault can be milled, prospected or disenchanted.")
            elseif db.craftableOnly then
                frame.emptyText:SetText("Nothing here can be made from what you have stored. "
                    .. "Untick \"Craftable only\" to see the rest.")
            else
                frame.emptyText:SetText("No recipes to show.")
            end
            frame.emptyText:Show()
        end
    end

    for i = 1, MAX_ROWS do
        local button = listButtons[i]
        local entry = (i <= ROWS) and source[offset + i] or nil

        if not entry then
            button:Hide()
        else
            button:Show()

            if isProcess then
                local name = ProcessName(entry)
                button.icon:SetTexture(ItemIcon(entry.item))
                button.label:SetText(string.format("%s |cff808080x%s|r", name, Commafy(entry.count)))
                button.label:SetTextColor(1, 1, 1)
                button.right:SetText("")
                button.entry = entry
                button.spell = nil
            else
                local name = RecipeName(entry)
                if entry.yield > 1 then name = name .. " |cff808080x" .. entry.yield .. "|r" end

                local colour = DifficultyColor(entry)
                -- [#1199] RecipeIcon, not ItemIcon: a gear-target recipe has no
                -- product item and would otherwise draw a question mark.
                button.icon:SetTexture(RecipeIcon(entry))
                button.label:SetText(name)
                button.label:SetTextColor(colour[1], colour[2], colour[3])

                local possible = MaxCraftable(entry.spell)
                button.right:SetText(possible and possible > 0 and ("|cff40ff40" .. Commafy(possible) .. "|r") or "")
                button.entry = nil
                button.spell = entry.spell
            end

            --[[
                Selection highlight, for BOTH kinds of row.

                It used to test `button.spell` only. A processing row deliberately
                sets `spell = nil` and carries `entry` instead, so the bulk lists
                never highlighted anything: you clicked a meat, the detail pane
                changed, and the list gave you no clue which line you were on.
                Owner, with a screenshot of exactly that: "I can't see that i have
                highlight crawler meat, can you? :P"

                Compared by IDENTITY, not by item id -- `detail.processEntry` IS
                one of the entries in this list, so the pointer test is exact and
                needs no key.
            ]]
            local selectedRow
            if button.spell then
                selectedRow = (button.spell == selectedSpell)
            else
                selectedRow = (button.entry ~= nil and button.entry == detail.processEntry)
            end

            if selectedRow then
                button.highlight:Show()
            else
                button.highlight:Hide()
            end
        end
    end
end

-- The detail pane is rebuilt from scratch on every refresh: it is small, it
-- changes shape (reagent count varies, plan rows appear and vanish), and
-- pooling widgets for it was not worth the bookkeeping.
function RefreshDetail()
    if not frame or not detail then return end

    for _, line in ipairs(detail.lines) do line:Hide() end
    for _, btn in ipairs(detail.clicks) do btn:Hide() end
    detail.lineCount = 0

    -- clickItem/clickName make the row a "where do I farm this?" target.
    local function AddLine(text, r, g, b, indent, clickItem, clickName)
        detail.lineCount = detail.lineCount + 1
        local index = detail.lineCount
        local top = -34 - (index - 1) * 14
        local left = 10 + (indent or 0)

        local line = detail.lines[index]
        if not line then
            line = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            line:SetJustifyH("LEFT")
            detail.lines[index] = line
        end
        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", detail, "TOPLEFT", left, top)
        line:SetPoint("RIGHT", detail, "RIGHT", -10, 0)
        line:SetText(text)
        line:SetTextColor(r or 1, g or 1, b or 1)
        line:Show()

        if clickItem then
            local btn = detail.clicks[index]
            if not btn then
                btn = CreateFrame("Button", nil, detail)
                btn:SetHeight(14)
                btn:SetScript("OnClick", function(self)
                    UncappedForge_QuerySources(self.item, self.itemName)
                end)
                btn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                    GameTooltip:SetText(self.itemName or "Material")
                    GameTooltip:AddLine("Click to see where this drops -- the creature or node, "
                        .. "the drop chance and the zone.", 1, 1, 1, true)
                    GameTooltip:Show()
                end)
                btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                detail.clicks[index] = btn
            end
            btn.item, btn.itemName = clickItem, clickName
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", detail, "TOPLEFT", left, top)
            btn:SetPoint("RIGHT", detail, "RIGHT", -10, 0)
            btn:Show()
        end
    end

    local procView = ProcView(frame.mode)
    if procView then
        detail.title:SetText(procView.label)
        for _, line in ipairs(procView.blurb) do
            AddLine(line, 0.8, 0.8, 0.8)
        end
        AddLine(" ")
        local selected = detail.processEntry
        -- `or 0`: a row arriving without kinds used to reach bit.band(nil, ...),
        -- which is a hard Lua error and takes the whole detail pane down with it.
        local selKinds = selected and selected.kinds or 0
        if selected then
            local name = ProcessName(selected)
            local perOp = selected.perOp or 5
            AddLine(name .. "  |cff808080x" .. Commafy(selected.count) .. "|r", 1, 0.82, 0)
            if bit.band(selKinds, KIND_MILL) ~= 0 then AddLine("Millable (5 per operation)", 0.6, 1, 0.6) end
            if bit.band(selKinds, KIND_PROSPECT) ~= 0 then AddLine("Prospectable (5 per operation)", 0.6, 1, 0.6) end
            if bit.band(selKinds, KIND_DISENCHANT) ~= 0 then AddLine("Disenchantable", 0.6, 1, 0.6) end
            if bit.band(selKinds, KIND_RENDER) ~= 0 then
                -- The rate is per source and worth stating plainly: it is the
                -- difference between 15 and 100 of the same-looking pile.
                AddLine(string.format("Renders down (%d per operation, %s total)",
                    perOp, Commafy(math.floor(selected.count / perOp))), 0.6, 1, 0.6)
            end
        else
            AddLine("Nothing selected.", 0.6, 0.6, 0.6)
        end

        detail.craft:Hide()
        detail.craftAll:Hide()
        detail.buy:Hide()
        detail.preview:Hide()   -- [#697] processing view has no craftable product
        -- The bulk buttons occupy this row now; the amount box shares its anchor
        -- and would be drawn underneath them.
        if frame.amount then frame.amount:Hide() end
        if frame.amountLabel then frame.amountLabel:Hide() end

        --[[
            A button appears only when the VIEW offers it AND the SELECTED row can
            actually take it.

            Both halves matter. The view keeps Rendering from showing a Mill
            button; the row's own kinds keep a stack that mills but cannot prospect
            from offering Prospect All. Previously all four showed unconditionally,
            so three of them were usually wrong for whatever was selected -- which
            is what made this screen feel broken.

            With nothing selected there is nothing to act on, so none show.

            ★ ANCHOR THE VISIBLE ONE TO THE BASE SLOT. The four are chained
              left-to-right (prospect -> mill, disenchant -> prospect, ...), and a
              hidden frame still resolves its anchor -- so a lone Render button
              would draw in the fourth slot with three button-widths of empty space
              to its left. Re-pointing the one we show is the whole fix.
        ]]
        local kinds = selKinds
        local shown = nil

        --[[
            How many operations the selected stack can actually pay for.

            Owner's screenshot: Crawler Meat x37, "Renders down (100 per operation,
            0 total)", and a fully-lit Render All underneath it. The pane already
            said it was impossible; the button still looked ready, and pressing it
            just returned "outofmats". Greying it says the same thing before the
            click instead of after.

            The per-operation cost mirrors what the pane prints directly above --
            `perOp` from the server for a render (it varies 100 down to 15 by source
            ilvl, which is exactly why it cannot be a constant), and the fixed rates
            the pane hardcodes for the rest. Reusing the displayed numbers means the
            button and the text can never disagree.
        ]]
        local function OpsAvailable(entry, kindBit)
            if not entry or not entry.count then return 0 end

            local per
            if kindBit == KIND_RENDER then
                per = entry.perOp or 1
            elseif kindBit == KIND_DISENCHANT then
                per = 1
            else
                per = 5     -- mill and prospect
            end

            if per < 1 then per = 1 end
            return math.floor(entry.count / per)
        end

        local function GateButton(button, kindBit)
            if not button then return end
            if bit.band(procView.mask, kindBit) ~= 0 and bit.band(kinds, kindBit) ~= 0 then
                if not shown then
                    button:ClearAllPoints()
                    button:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 400, 60)
                    shown = button
                end
                button:Show()

                if OpsAvailable(selected, kindBit) > 0 then
                    button:Enable()
                else
                    button:Disable()
                end
            else
                button:Hide()
            end
        end

        GateButton(detail.mill,       KIND_MILL)
        GateButton(detail.prospect,   KIND_PROSPECT)
        GateButton(detail.disenchant, KIND_DISENCHANT)
        GateButton(detail.render,     KIND_RENDER)
        return
    end

    detail.mill:Hide()
    detail.prospect:Hide()
    detail.disenchant:Hide()
    detail.render:Hide()
    if frame.amount then frame.amount:Show() end
    if frame.amountLabel then frame.amountLabel:Show() end
    detail.craft:Show()
    detail.craftAll:Show()

    local recipe = selectedSpell and recipesBySpell[selectedSpell]
    if not recipe then
        detail.title:SetText("No recipe selected")
        detail.productIcon:SetTexture(QUESTION_MARK)
        AddLine("Pick a recipe on the left.", 0.6, 0.6, 0.6)
        detail.craft:Disable()
        detail.craftAll:Disable()
        detail.buy:Hide()
        detail.preview:Hide()   -- [#697] nothing selected, nothing to model
        return
    end

    -- [#1199] Resolved HERE rather than at the button block below, because it also
    -- decides the material arithmetic: a gear-target recipe is always one
    -- application, so the "have / need" column must be priced at 1 and not at
    -- whatever number is still sitting in the (hidden) Amount box.
    local gearReq = gearTargets[recipe.spell]

    local name = RecipeName(recipe)
    detail.title:SetText(recipe.yield > 1 and (name .. " x" .. recipe.yield) or name)
    -- [#1199] RecipeIcon falls back to the spell's own icon for the 43 recipes
    -- that produce no item at all.
    detail.productIcon:SetTexture(RecipeIcon(recipe))

    -- [#697] Only wearable products can be modelled. Re-evaluated on every refresh
    -- rather than cached, because GetItemInfo may simply not have answered yet the
    -- first time this recipe was drawn.
    local equipSlot = EquipLocOf(recipe.item)
    if equipSlot and equipSlot ~= "" then
        detail.preview:Show()
    else
        detail.preview:Hide()
    end

    local amount = gearReq and 1 or RequestedAmount()

    AddLine("Materials (Vault + bags)  |cff808080-- click one to find it|r", 1, 0.82, 0)
    local list = mats[recipe.spell]
    if not list then
        AddLine("...", 0.6, 0.6, 0.6)
    else
        for _, mat in ipairs(list) do
            local matName = mat.name or ItemName(mat.item) or ("item " .. mat.item)
            local need = mat.per * amount
            local enough = mat.have >= need
            AddLine(string.format("%s  %s / %s", matName, Commafy(mat.have), Commafy(need)),
                enough and 0.4 or 1, enough and 1 or 0.4, 0.4, 8, mat.item, matName)
        end
    end

    -- Enchants are cast ON a vellum, which is consumed and turned into the
    -- scroll. It is already listed as a material above; this says WHY, and warns
    -- about the one bag slot the scroll needs even with Vault output, which is
    -- enforced by Spell::CheckItems and cannot be skipped.
    if recipe.target and recipe.target > 0 then
        local vellumName = ItemName(recipe.target) or ("item " .. recipe.target)
        AddLine(" ")
        AddLine("Cast on: " .. vellumName, 0.7, 0.85, 1)
        AddLine("Keep one bag slot free for the scroll.", 0.6, 0.6, 0.6)
    end

    if recipe.tool and recipe.tool > 0 then
        local toolName = ItemName(recipe.tool) or ("item " .. recipe.tool)
        AddLine(" ")
        AddLine("Normally needs: " .. toolName .. " (not required here)", 0.6, 0.6, 0.6)
    end

    -- Plan preview: only interesting when it found sub-crafts or gaps.
    if plan.spell == recipe.spell and (#plan.steps > 1 or #plan.needs > 0) then
        AddLine(" ")
        if #plan.steps > 1 then
            AddLine("Will also make first:", 1, 0.82, 0)
            for _, step in ipairs(plan.steps) do
                if step.spell ~= recipe.spell then
                    -- Harvest steps arrive pre-labelled ("Mill Silverleaf -> Alabaster
                    -- Pigment"); they have no spell to name them from.
                    local stepName = step.label or GetSpellInfo(step.spell)
                        or ItemName(step.item) or ("item " .. step.item)
                    AddLine(string.format("%s x%s", stepName, Commafy(step.crafts)), 0.7, 0.85, 1, 8)
                end
            end
        end
        if #plan.needs > 0 then
            AddLine("Still missing:  |cff808080-- click one to find it|r", 1, 0.4, 0.4)
            for _, need in ipairs(plan.needs) do
                local needName = need.name or ItemName(need.item) or ("item " .. need.item)
                AddLine(string.format("%s x%s", needName, Commafy(need.missing)),
                    1, 0.5, 0.5, 8, need.item, needName)
            end
        end
    end

    if quote then
        AddLine(" ")
        if quote.buy > 0 then
            AddLine(string.format("Buyable from a vendor: %s", Money(quote.cost)), 0.6, 1, 0.6)
        end
        if quote.tokenOnly > 0 then
            AddLine(string.format("%d only sold for tokens/honour", quote.tokenOnly), 1, 0.8, 0.4)
        end
        if quote.unbuyable > 0 then
            AddLine(string.format("%d must be gathered", quote.unbuyable), 1, 0.8, 0.4)
        end
    end

    --[[ [#1199] A recipe that enchants gear you already own.

         Neither the Amount box nor "Craft All" means anything here: the recipe
         applies ONE enchant to ONE item, and offering "Craft All" over a tinker
         would promise a number the server can never deliver. The craft button
         becomes the door to the picker instead, and says so on its face. ]]
    if gearReq then
        AddLine(" ")
        AddLine("Applied to an item you already own.", 0.7, 0.85, 1)
        AddLine("Nothing is created -- pick the piece when you press the button.", 0.6, 0.6, 0.6)

        detail.craftAll:Hide()
        if frame.amount then frame.amount:Hide() end
        if frame.amountLabel then frame.amountLabel:Hide() end
        detail.preview:Hide()   -- there is no product to model
        detail.craft:SetText("Choose item\226\128\166")
        detail.craft:Enable()

        -- The shortfall pricing still applies -- a tinker has reagents like anything
        -- else -- so this row keeps behaving exactly as it does for every other
        -- recipe rather than being hidden along with the amount box.
        if plan.spell == recipe.spell and #plan.needs > 0 then
            detail.buy:Show()
            detail.buy:SetText(quote and quote.buy > 0 and "Buy them" or "Price missing mats")
        else
            detail.buy:Hide()
        end
        return
    end
    detail.craft:SetText("Craft")

    -- Both buttons stay enabled even at zero direct materials: with
    -- intermediates on, the server may well be able to make it anyway by
    -- smelting or tanning first, and it is the authority on that.
    detail.craft:Enable()
    detail.craftAll:Enable()

    if plan.spell == recipe.spell and #plan.needs > 0 then
        detail.buy:Show()
        detail.buy:SetText(quote and quote.buy > 0 and "Buy them" or "Price missing mats")
    else
        detail.buy:Hide()
    end
end

function RefreshProgress()
    if not progress then return end

    if not job then
        progress:Hide()
        return
    end

    progress:Show()
    progress.bar:SetMinMaxValues(0, math.max(1, job.total))
    progress.bar:SetValue(job.done)
    progress.text:SetText(string.format("%s / %s crafts -- %s made",
        Commafy(job.done), Commafy(job.total), Commafy(job.crafted)))
end

-- The profession picker.
--
-- This was a row of buttons, one per profession, laid out left to right. With a
-- character who has levelled everything -- Tailoring, Enchanting, Leatherworking,
-- Blacksmithing, Alchemy, Cooking, First Aid, Mining, Engineering, Jewelcrafting,
-- Inscription -- the row was several times wider than the window and ran off the
-- side of the screen, so the last professions were simply unreachable. A dropdown
-- is a fixed width whatever the character knows.
--
-- The bulk-processing views live in the same dropdown rather than as separate
-- buttons: they are other views of the same window, and one control that always
-- says what you are looking at beats several that can disagree. Since 2026-08-12
-- there is one entry per operation (Milling, Prospecting, Disenchanting,
-- Rendering) instead of a single mixed "Bulk processing" list.
-- The one search box serves both lists, so its greyed hint says which one it is
-- pointed at right now.
local function UpdateSearchHint()
    if not (frame and frame.search and frame.search.placeholder) then return end
    local view = ProcView(frame.mode)
    frame.search.placeholder:SetText(view and view.hint or SEARCH_HINT.craft)
end

local function ProfessionLabel()
    local view = frame and ProcView(frame.mode)
    if view then return view.label end

    for _, prof in ipairs(professions) do
        if prof.skill == selectedSkill then
            local name = prof.name ~= "" and prof.name or ("skill " .. prof.skill)
            return string.format("%s (%d)", name, prof.rank)
        end
    end

    return "Select a profession"
end

function BuildProfessionTabs()
    if not frame or not frame.profDrop then return end

    UIDropDownMenu_Initialize(frame.profDrop, function(_, level)
        for _, prof in ipairs(professions) do
            local name = prof.name ~= "" and prof.name or ("skill " .. prof.skill)
            local info = UIDropDownMenu_CreateInfo()
            info.text = string.format("%s (%d/%d)", name, prof.rank, prof.max)
            info.value = prof.skill
            info.checked = (frame.mode == "craft" and prof.skill == selectedSkill)
            info.func = function()
                frame.mode = "craft"
                selectedSkill = prof.skill
                -- [#922] Before ApplyFilter: the material filter only applies on the
                -- disenchant view, and the controls have to agree with the list the
                -- filter is about to build.
                if RefreshProcControls then RefreshProcControls() end
                ApplyFilter()
                ResetScroll()
                UpdateSearchHint()
                UIDropDownMenu_SetText(frame.profDrop, ProfessionLabel())
                RefreshList()
                RefreshDetail()
            end
            UIDropDownMenu_AddButton(info, level)
        end

        -- One entry per bulk-processing view. Same list underneath, filtered by the
        -- view's kinds mask -- so each tab shows only what it can actually act on.
        for _, key in ipairs(PROC_VIEW_ORDER) do
            local view = PROC_VIEWS[key]
            local entry = UIDropDownMenu_CreateInfo()
            entry.text = view.label
            entry.value = key
            entry.checked = (frame.mode == key)
            entry.func = function()
                frame.mode = key
                -- Re-asked per switch: the list is the player's VAULT, which the
                -- job they just ran will have changed.
                Send("FRGPROCLIST")
                -- [#922] Same ordering reason as the craft branch above.
                if RefreshProcControls then RefreshProcControls() end
                ApplyFilter()   -- the query carries over to this list too
                ResetScroll()
                -- Selecting a row in one view and switching leaves a selection the
                -- new view may not contain at all, and the detail pane would then
                -- describe something the list no longer shows.
                detail.processEntry = nil
                UpdateSearchHint()
                UIDropDownMenu_SetText(frame.profDrop, ProfessionLabel())
                RefreshList()
                RefreshDetail()
            end
            UIDropDownMenu_AddButton(entry, level)
        end
    end)

    UIDropDownMenu_SetWidth(frame.profDrop, 190)
    UIDropDownMenu_SetText(frame.profDrop, ProfessionLabel())
end

-- Lives inside the Dashboard's content panel (see EmbedInto below) -- no own
-- backdrop/title/close/drag, since the Dashboard's master window already
-- provides all of that chrome. The recipe list and detail pane stretch with
-- whatever size the Dashboard window currently has (listFrame stretches
-- vertically with a dynamically recomputed row count, same technique as
-- Soul Forge's equipped-gear list; detail stretches both ways to fill
-- whatever's left to its right); the bottom amount/craft/checkbox row keeps
-- its original fixed layout, same as Soul Forge's own action buttons.
local function BuildFrame(parent)
    if frame then return end

    frame = CreateFrame("Frame", "UncappedForgeFrame", parent or UIParent)
    frame:SetPoint("TOPLEFT"); frame:SetPoint("BOTTOMRIGHT")
    frame:Hide()
    frame.mode = "craft"

    -- Profession picker (see BuildProfessionTabs). Populated once the server's
    -- profession list lands, which is after this frame is built.
    local profDrop = CreateFrame("Frame", "UncappedForgeProfDrop", frame, "UIDropDownMenuTemplate")
    profDrop:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -10)
    frame.profDrop = profDrop

    -- Search box.
    --
    -- Filters whichever list is showing -- recipes, or the bulk
    -- mill/prospect/disenchant list -- and narrows what the profession dropdown
    -- and the craftable-only tick already chose rather than overriding them.
    --
    -- Built from the shared UncappedUI kit so it matches the Vault's and the
    -- wardrobe's boxes (magnifier, greyed hint, Escape clears). The kit is
    -- guaranteed loaded by the time this runs -- the Dashboard's own UI bails
    -- out without it, and this panel is embedded in that UI -- so the fallback
    -- below is only for anyone embedding the Forge somewhere else.
    local search
    if UncappedUIKit and UncappedUIKit.CreateSearchBox then
        search = UncappedUIKit.CreateSearchBox(frame, 170, 20, SEARCH_HINT.craft)
        search.OnQueryChanged = QueueSearch
    else
        search = CreateFrame("EditBox", "UncappedForgeSearch", frame, "InputBoxTemplate")
        search:SetWidth(170)
        search:SetHeight(20)
        search:SetAutoFocus(false)
        search:SetTextInsets(20, 0, 0, 0)

        search.placeholder = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        search.placeholder:SetPoint("LEFT", search, "LEFT", 24, 1)
        search.placeholder:SetText(SEARCH_HINT.craft)

        search.icon = search:CreateTexture(nil, "OVERLAY")
        search.icon:SetWidth(16)
        search.icon:SetHeight(16)
        search.icon:SetPoint("LEFT", search, "LEFT", 6, 0)
        search.icon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")

        search:SetScript("OnTextChanged", function(self)
            local text = self:GetText() or ""
            if text == "" then self.placeholder:Show() else self.placeholder:Hide() end
            QueueSearch(text)
        end)
        search:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    end

    search:SetPoint("TOPLEFT", frame, "TOPLEFT", 240, -16)
    -- Enter is not needed (the list already follows the typing) -- it just drops
    -- focus, so the next keypress goes back to moving the character.
    search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    frame.search = search

    -- Craftable-only filter
    local onlyCheck = CreateFrame("CheckButton", "UncappedForgeOnly", frame, "UICheckButtonTemplate")
    onlyCheck:SetWidth(22)
    onlyCheck:SetHeight(22)
    onlyCheck:SetPoint("LEFT", search, "RIGHT", 8, 0)
    onlyCheck:SetChecked(db.craftableOnly)
    local onlyLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    onlyLabel:SetPoint("LEFT", onlyCheck, "RIGHT", 2, 0)
    onlyLabel:SetText("Craftable only")

    --[[
        "...or buyable" -- owner request 2026-08-17.

        Widens the tick to its left rather than standing on its own, so it is shown
        DISABLED whenever "Craftable only" is off. With that filter off every recipe
        is listed already, so an enabled-looking tick that changed nothing would read
        as broken -- which is precisely the complaint #922 was filed about, one tab
        over.
    ]]
    local buyCheck = CreateFrame("CheckButton", "UncappedForgeBuyable", frame, "UICheckButtonTemplate")
    buyCheck:SetWidth(22)
    buyCheck:SetHeight(22)
    buyCheck:SetPoint("LEFT", onlyLabel, "RIGHT", 10, 0)
    buyCheck:SetChecked(db.buyableToo)
    buyCheck:SetScript("OnClick", function(self)
        db.buyableToo = self:GetChecked() and true or false
        ApplyFilter()
        ResetScroll()
        RefreshList()
    end)

    local buyLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    buyLabel:SetPoint("LEFT", buyCheck, "RIGHT", 2, 0)
    buyLabel:SetText("...or buyable")

    -- Wired by hand rather than left to `self.tooltipText`: UICheckButtonTemplate
    -- does not show that field on its own outside Blizzard's options frames, so
    -- setting it would have looked like a tooltip and shown nothing.
    buyCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("...or buyable", 1, 0.82, 0)
        GameTooltip:AddLine("Also lists recipes you cannot make yet whose missing "
            .. "materials can all be bought for gold.", 1, 1, 1, true)
        GameTooltip:AddLine("Needs \"Craftable only\" ticked -- with it off, "
            .. "everything is listed anyway.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    buyCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local function UpdateBuyableEnabled()
        if db.craftableOnly then
            buyCheck:Enable()
            buyLabel:SetTextColor(1, 0.82, 0)
        else
            buyCheck:Disable()
            buyLabel:SetTextColor(0.5, 0.5, 0.5)
        end
    end

    onlyCheck:SetScript("OnClick", function(self)
        db.craftableOnly = self:GetChecked() and true or false
        UpdateBuyableEnabled()
        ApplyFilter()
        ResetScroll()
        RefreshList()
    end)

    UpdateBuyableEnabled()

    --[[
        Sort mode. Two lists, two sets of options, ONE dropdown.

        ★★ [#922] THE REPORTED BUG. This control used to offer the recipe options on
           every tab and write only `db.sortMode`, which only the recipe list reads --
           so on the Disenchant tab it accepted "Difficulty", relabelled itself, and
           sorted nothing. It now asks which list is showing and drives that one.

        "Difficulty" honestly means different things on the two: the orange/yellow/
        green/grey skill-up ladder for a recipe, and the required disenchant skill for
        an item being broken down. There is no colour ladder on the thing you feed in,
        so the label is kept and the measure changes with the list -- which is what a
        player means when they ask for it on either tab.
    ]]
    local RECIPE_SORTS = {
        { value = "name",       text = "Name" },
        { value = "level",      text = "Skill level" },   -- [#790]
        { value = "difficulty", text = "Difficulty" },
    }

    -- Count first: it is the order this list has always used and the most useful one
    -- for bulk work, so it stays the default rather than being quietly replaced.
    local PROC_SORTS = {
        { value = "count",      text = "Amount held" },
        { value = "name",       text = "Name" },
        { value = "difficulty", text = "Difficulty" },
    }

    local function ActiveSorts()
        return ProcView(frame.mode) and PROC_SORTS or RECIPE_SORTS
    end

    local function ActiveSortValue()
        return ProcView(frame.mode) and db.procSortMode or db.sortMode
    end

    local sortDrop = CreateFrame("Frame", "UncappedForgeSortDrop", frame, "UIDropDownMenuTemplate")
    sortDrop:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 8, -10)
    frame.sortDrop = sortDrop

    local function sortText(value)
        for _, entry in ipairs(ActiveSorts()) do
            if entry.value == value then return entry.text end
        end
        return ActiveSorts()[1].text
    end

    UIDropDownMenu_Initialize(sortDrop, function(_, level)
        local active = ActiveSortValue()
        for _, entry in ipairs(ActiveSorts()) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = entry.text
            info.value = entry.value
            info.checked = (active == entry.value)
            info.func = function()
                if ProcView(frame.mode) then
                    db.procSortMode = entry.value
                    SortProcessable()
                else
                    db.sortMode = entry.value
                    sortDirty = true
                end
                UIDropDownMenu_SetText(sortDrop, entry.text)
                ApplyFilter()
                ResetScroll()
                RefreshList()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UIDropDownMenu_SetWidth(sortDrop, 100)
    UIDropDownMenu_SetText(sortDrop, sortText(ActiveSortValue()))

    local sortLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sortLabel:SetPoint("RIGHT", sortDrop, "LEFT", -2, 0)
    sortLabel:SetText("Sort")

    --[[
        [#922] Material filter -- "show me only the things that could give me Arcane
        Dust". The reporter framed it as "pick TBC", and on this axis those are the
        same request: each expansion's enchanting materials are distinct, so choosing
        Arcane Dust IS choosing Burning Crusade gear. Filtering on the material is the
        version that cannot drift, because it is read from the server's own yield
        table rather than from a hand-kept expansion list.

        Disenchant-only, and hidden everywhere else -- see the note in ApplyFilter.
    ]]
    local matDrop = CreateFrame("Frame", "UncappedForgeMatDrop", frame, "UIDropDownMenuTemplate")
    matDrop:SetPoint("RIGHT", sortLabel, "LEFT", -8, 0)
    frame.matDrop = matDrop

    local function MaterialText()
        if db.procMaterial == 0 then return "Any material" end
        return ItemName(db.procMaterial) or ("item " .. db.procMaterial)
    end

    UIDropDownMenu_Initialize(matDrop, function(_, level)
        local any = UIDropDownMenu_CreateInfo()
        any.text = "Any material"
        any.value = 0
        any.checked = (db.procMaterial == 0)
        any.func = function()
            db.procMaterial = 0
            UIDropDownMenu_SetText(matDrop, MaterialText())
            ApplyFilter()
            ResetScroll()
            RefreshList()
        end
        UIDropDownMenu_AddButton(any, level)

        -- Sorted by name so the menu is stable between openings; `pairs` order over
        -- the material set is not, and a dropdown that reshuffles itself is its own
        -- small bug report.
        local ordered = {}
        for mat in pairs(matPresent) do ordered[#ordered + 1] = mat end
        table.sort(ordered, function(a, b)
            return (ItemName(a) or tostring(a)) < (ItemName(b) or tostring(b))
        end)

        for _, mat in ipairs(ordered) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = ItemName(mat) or ("item " .. mat)
            info.value = mat
            info.checked = (db.procMaterial == mat)
            info.func = function()
                db.procMaterial = mat
                UIDropDownMenu_SetText(matDrop, MaterialText())
                ApplyFilter()
                ResetScroll()
                RefreshList()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UIDropDownMenu_SetWidth(matDrop, 130)
    UIDropDownMenu_SetText(matDrop, MaterialText())

    --[[
        Which controls belong to which list.

        ★ The craftable ticks are recipe-only and were ALSO sitting on the processing
          tabs doing nothing -- the same defect as the sort, just less noticed because
          nobody had complained about them yet. They are hidden there now rather than
          left as two more controls that lie.
    ]]
    function RefreshProcControls()
        if not frame then return end

        local view = ProcView(frame.mode)
        local isDisenchant = view and view.mask == KIND_DISENCHANT

        if view then
            onlyCheck:Hide(); onlyLabel:Hide()
            buyCheck:Hide();  buyLabel:Hide()
        else
            onlyCheck:Show(); onlyLabel:Show()
            buyCheck:Show();  buyLabel:Show()
            UpdateBuyableEnabled()
        end

        if isDisenchant then
            matDrop:Show()
            UIDropDownMenu_SetText(matDrop, MaterialText())
        else
            matDrop:Hide()
        end

        -- The sort dropdown stays on every tab -- it now has something real to do on
        -- all of them -- but its options and its label follow the list being shown.
        UIDropDownMenu_SetText(sortDrop, sortText(ActiveSortValue()))
    end

    RefreshProcControls()

    -- Recipe list -- fixed width, but stretches vertically with the window;
    -- ROWS (how many rows currently fit) is recomputed on resize, same
    -- technique as Soul Forge's equipped-gear list.
    local listFrame = CreateFrame("Frame", nil, frame)
    listFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, LIST_TOP)
    listFrame:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 18, BOTTOM_RESERVE)
    listFrame:SetWidth(330)

    listScroll = CreateFrame("ScrollFrame", "UncappedForgeScroll", listFrame, "FauxScrollFrameTemplate")
    listScroll:SetAllPoints(listFrame)
    listScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, RefreshList)
    end)
    listScroll:SetScript("OnSizeChanged", function(self, w, h)
        ROWS = math.max(1, math.floor(h / ROW_HEIGHT))
        RefreshList()
    end)

    listButtons = {}
    for i = 1, MAX_ROWS do
        local button = CreateFrame("Button", nil, listFrame)
        button:SetWidth(310)
        button:SetHeight(ROW_HEIGHT)
        button:SetPoint("TOPLEFT", listFrame, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)

        button.highlight = button:CreateTexture(nil, "BACKGROUND")
        button.highlight:SetAllPoints()
        button.highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        button.highlight:SetBlendMode("ADD")
        button.highlight:Hide()

        button.icon = button:CreateTexture(nil, "ARTWORK")
        button.icon:SetWidth(18)
        button.icon:SetHeight(18)
        button.icon:SetPoint("LEFT", button, "LEFT", 2, 0)

        button.label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        button.label:SetPoint("LEFT", button.icon, "RIGHT", 4, 0)
        button.label:SetJustifyH("LEFT")
        button.label:SetWidth(210)

        button.right = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        button.right:SetPoint("RIGHT", button, "RIGHT", -4, 0)

        button:SetScript("OnClick", function(self)
            if ProcView(frame.mode) then
                detail.processEntry = self.entry
                RefreshDetail()
            elseif self.spell then
                SelectRecipe(self.spell)
            end
        end)

        -- Hovering used to always ask for the ITEM tooltip, which rendered as a
        -- bare red "Retrieving item information" for anything the client had not
        -- cached -- i.e. most of a crafter's own products, since they never sit
        -- in a bag. The item tooltip is still the best answer when it can
        -- actually be drawn, so: use it when the item IS cached, otherwise fall
        -- back to the SPELL tooltip, which comes from Spell.dbc and so always
        -- renders (and for a recipe it describes what the craft produces).
        --
        -- Asking for the item link also warms the cache, so a second hover
        -- usually upgrades to the full item tooltip with stats.
        button:SetScript("OnEnter", function(self)
            local recipe = self.spell and recipesBySpell[self.spell]
            local itemId = (self.entry and self.entry.item) or (recipe and recipe.item)
            local cached = itemId and itemId > 0 and GetItemInfo(itemId)

            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")

            if cached then
                GameTooltip:SetHyperlink("item:" .. itemId)
            elseif self.spell then
                GameTooltip:SetHyperlink("spell:" .. self.spell)
                if itemId and itemId > 0 then ItemName(itemId) end   -- warm for next hover
            elseif self.entry then
                -- Processing rows are plain items with no spell to fall back on;
                -- show what the server already told us rather than a red stub.
                GameTooltip:SetText(self.entry.name or ("item " .. tostring(self.entry.item)), 1, 1, 1)
                GameTooltip:AddLine("In your Vault: " .. Commafy(self.entry.count), 0.7, 0.85, 1)
                if itemId and itemId > 0 then ItemName(itemId) end
            else
                GameTooltip:Hide()
                return
            end

            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)

        button:Hide()
        listButtons[i] = button
    end

    -- Shown by RefreshList when the current filters leave the list empty.
    -- Parented to listFrame so it sits exactly where the missing rows would.
    frame.emptyText = listFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.emptyText:SetPoint("TOPLEFT", listFrame, "TOPLEFT", 4, -6)
    frame.emptyText:SetWidth(300)
    frame.emptyText:SetJustifyH("LEFT")
    frame.emptyText:Hide()

    -- Detail pane -- fills whatever space is left to the right of the list,
    -- both ways, instead of a fixed width/height. Its own content (AddLine)
    -- already anchors off `detail`'s own RIGHT edge, so it needed no changes.
    detail = CreateFrame("Frame", nil, frame)
    detail:SetPoint("TOPLEFT", listFrame, "TOPRIGHT", 20, 0)
    detail:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -18, BOTTOM_RESERVE)
    detail.lines = {}
    detail.lineCount = 0
    -- Invisible click targets laid over material rows ("where do I farm this?").
    -- Pooled by line index alongside detail.lines.
    detail.clicks = {}

    detail.productIcon = detail:CreateTexture(nil, "ARTWORK")
    detail.productIcon:SetWidth(28)
    detail.productIcon:SetHeight(28)
    detail.productIcon:SetPoint("TOPLEFT", detail, "TOPLEFT", 8, 0)

    detail.title = detail:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    detail.title:SetPoint("LEFT", detail.productIcon, "RIGHT", 6, 0)
    detail.title:SetPoint("RIGHT", detail, "RIGHT", -90, 0)
    detail.title:SetJustifyH("LEFT")

    --[[
        [#697] "Add a way to preview an item from the forge to see what it looks
        like." Owner ruling: a full 3D model, not just an icon.

        ★ IN ITS OWN FRAME, not inline in the detail pane. The pane's material
          rows (AddLine) anchor off `detail`'s own RIGHT edge, so a model dropped
          into the pane would sit underneath them at every window width. A
          separate frame also means the preview can be bigger than the pane would
          ever allow.

        ⚠ Reuses the wardrobe's mechanism and its hard-won caveat: TryOn WITHOUT a
          preceding SetUnit. SetUnit reloads the model asynchronously and discards
          a TryOn issued immediately after it -- that is what made the wardrobe
          preview silently do nothing, and it would do the same here.
    ]]
    detail.preview = KitButton(detail, "", 74, 20)
    detail.preview:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -8, 2)
    detail.preview:SetText("Preview")
    detail.preview:SetScript("OnClick", function()
        local recipe = selectedSpell and recipesBySpell[selectedSpell]
        if recipe then ShowModelPreview(recipe.item) end
    end)
    detail.preview:Hide()

    -- Amount + action buttons
    local amount = CreateFrame("EditBox", "UncappedForgeAmount", frame, "InputBoxTemplate")
    amount:SetWidth(50)
    amount:SetHeight(20)
    amount:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 400, 60)
    amount:SetAutoFocus(false)
    amount:SetNumeric(true)
    amount:SetText(tostring(db.lastAmount or 1))
    amount:SetScript("OnTextChanged", function()
        db.lastAmount = RequestedAmount()
        RefreshDetail()
    end)
    -- Re-plan only once the number is settled. Doing it in OnTextChanged would
    -- send a plan request per keystroke -- typing "500" would ask three times.
    amount:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        RequestPlan()
    end)
    amount:SetScript("OnEditFocusLost", function() RequestPlan() end)
    amount:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    frame.amount = amount

    local amountLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    amountLabel:SetPoint("RIGHT", amount, "LEFT", -4, 0)
    amountLabel:SetText("Amount")
    -- Stored on the frame so RefreshDetail can hide it together with the box.
    -- ⚠ The bulk buttons anchor to the SAME point as `amount` (BOTTOMLEFT 400,60)
    --   because the two are alternative modes of one row -- never both at once.
    --   The label was the one piece nobody remembered to switch off, so "Mill All"
    --   drew straight over "Amount [10000]".
    frame.amountLabel = amountLabel

    local function StartCraft(count)
        if not selectedSpell then return end
        -- ⚠ EXACTLY FOUR FIELDS, unchanged. HandleCraft does ParseFields(args, 4)
        --   and returns on any other count, so this line must never grow -- see
        --   [#1199], which needed a target and got its own verb (FRGENCH) rather
        --   than a fifth field here.
        Send(string.format("FRGCRAFT:%d:%d:%d:%d", selectedSpell, count,
            db.autoIntermediates and 1 or 0, 0))
        job = { done = 0, total = count, crafted = 0 }
        RefreshProgress()
    end

    --[[ [#1199] Apply a gear enchant to one chosen item.

         ★ NO JOB IS OPENED. There is no slice runner behind this: the server casts
           once per FRGENCH and answers with FRGENCHOK + FRGDONE:0:. Setting `job`
           here would raise a progress bar that nothing ever advances and that only
           the FRGDONE would clear.

         ★ NO COUNT ON THE WIRE, by agreement. One message, one application. ]]
    local function StartEnchant(target)
        if not selectedSpell or not target then return end
        Send(string.format("FRGENCH:%d:%d:%d", selectedSpell, target.bag, target.slot))
    end

    detail.craft = KitButton(frame, "", 90, 22)
    detail.craft:SetPoint("LEFT", amount, "RIGHT", 8, 0)
    detail.craft:SetText("Craft")
    detail.craft:SetScript("OnClick", function()
        -- [#1199] A gear-target recipe has no amount and no product: it applies
        -- ONE enchant to ONE piece you already own, so the button asks which piece
        -- rather than starting a job.
        local req = selectedSpell and gearTargets[selectedSpell]
        if req then
            ShowTargetPicker(RecipeName(recipesBySpell[selectedSpell]), req, StartEnchant)
            return
        end
        StartCraft(RequestedAmount())
    end)

    detail.craftAll = KitButton(frame, "", 90, 22)
    detail.craftAll:SetPoint("LEFT", detail.craft, "RIGHT", 4, 0)
    detail.craftAll:SetText("Craft All")
    detail.craftAll:SetScript("OnClick", function()
        -- "All" means what the materials currently support. With intermediates
        -- on, the server may well manage more than this by smelting -- but
        -- promising a number we cannot compute client-side would be worse.
        local possible = MaxCraftable(selectedSpell)
        if possible and possible > 0 then StartCraft(possible) end
    end)

    detail.buy = KitButton(frame, "", 150, 22)
    detail.buy:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 24, 60)
    detail.buy:SetText("Price missing mats")
    detail.buy:SetScript("OnClick", function(self)
        if not selectedSpell then return end
        local args = string.format("%d:%d:%d", selectedSpell, RequestedAmount(),
            db.autoIntermediates and 1 or 0)
        -- First press prices it, second press commits. The label is set from
        -- the quote state in RefreshDetail, so it cannot drift out of step
        -- with what a press will actually do.
        if quote and quote.buy > 0 then
            Send("FRGBUY:" .. args)
        else
            Send("FRGQUOTE:" .. args)
        end
    end)
    detail.buy:Hide()

    -- Bulk processing buttons. Shown only on a processing view, and only when the
    -- view AND the selected row both support that operation -- see RefreshDetail.
    local function StartProcess(kind)
        local entry = detail.processEntry
        if not entry then return end
        -- The row carries its own rate; the old (kind == 2) and 1 or 5 could not
        -- express a render, whose rate is per source. Falling back to 1 rather
        -- than 5 for a row from an older server overstates the operation count,
        -- which the server clamps anyway -- the reverse would understate it and
        -- silently leave materials behind.
        local perOp = entry.perOp
        if not perOp or perOp < 1 then perOp = 1 end
        local ops = math.floor(entry.count / perOp)
        if ops < 1 then return end
        --[[
            The server clamps a single request, and the clamp is no longer one
            number -- so neither is this, or the progress bar promises a total the
            run will never reach.

            Mill / prospect / disenchant ROLL A LOOT TABLE per operation. There is
            no closed form for a roll, so those stay at 10,000 a press exactly as
            before.

            RENDER (kind 3) does not roll. It is a conversion -- a fixed number of
            source items in, a fixed number out -- so the server resolves the whole
            pile as arithmetic and a 2.6-million meat stack is ONE press instead of
            the 261 this used to require.

            ⚠ The server decides for itself and clamps again; this only keeps the
              progress bar honest. An older server that does not know the higher
              ceiling will clamp to 10,000 and the bar corrects itself on the first
              FRGPROG.
        ]]
        local cap = (kind == 3) and 1000000 or 10000
        if ops > cap then ops = cap end
        Send(string.format("FRGPROC:%d:%d:%d", kind, entry.item, ops))
        job = { done = 0, total = ops, crafted = 0 }
        RefreshProgress()
    end

    detail.mill = KitButton(frame, "", 100, 22)
    detail.mill:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 400, 60)
    detail.mill:SetText("Mill All")
    detail.mill:SetScript("OnClick", function() StartProcess(0) end)
    detail.mill:Hide()

    detail.prospect = KitButton(frame, "", 100, 22)
    detail.prospect:SetPoint("LEFT", detail.mill, "RIGHT", 4, 0)
    detail.prospect:SetText("Prospect All")
    detail.prospect:SetScript("OnClick", function() StartProcess(1) end)
    detail.prospect:Hide()

    detail.disenchant = KitButton(frame, "", 100, 22)
    detail.disenchant:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 400, 34)
    detail.disenchant:SetText("Disenchant All")
    detail.disenchant:SetScript("OnClick", function() StartProcess(2) end)
    detail.disenchant:Hide()

    detail.render = KitButton(frame, "", 100, 22)
    detail.render:SetPoint("LEFT", detail.disenchant, "RIGHT", 4, 0)
    detail.render:SetText("Render All")
    detail.render:SetScript("OnClick", function() StartProcess(3) end)
    detail.render:Hide()

    -- Output destination: there is no longer a choice. Owner ruling 2026-08-12 --
    -- the Forge always banks to the Vault and players withdraw what they need.
    -- The checkbox that used to sit here is gone; subCheck takes its anchor so
    -- the row does not shift.
    local subCheck = CreateFrame("CheckButton", "UncappedForgeSubs", frame, "UICheckButtonTemplate")
    subCheck:SetWidth(22)
    subCheck:SetHeight(22)
    subCheck:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 22, 34)
    subCheck:SetChecked(db.autoIntermediates)
    subCheck:SetScript("OnClick", function(self)
        db.autoIntermediates = self:GetChecked() and true or false
        RequestPlan()
    end)
    local subLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subLabel:SetPoint("LEFT", subCheck, "RIGHT", 2, 0)
    subLabel:SetText("Make missing parts")

    -- Progress
    progress = CreateFrame("Frame", nil, frame)
    progress:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 24, 14)
    progress:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -24, 14)
    progress:SetHeight(16)
    progress:Hide()

    progress.bar = CreateFrame("StatusBar", nil, progress)
    progress.bar:SetAllPoints()
    progress.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    progress.bar:SetStatusBarColor(0.9, 0.5, 0.2)
    progress.bar:SetMinMaxValues(0, 1)
    progress.bar:SetValue(0)

    progress.text = progress:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    progress.text:SetPoint("CENTER", progress, "CENTER", 0, 0)

    -- Parented to `progress`, not `frame`: a Stop button that outlived the
    -- progress bar would sit there cancelling a job that had already finished.
    local cancel = KitButton(progress, "", 60, 18)
    cancel:SetPoint("RIGHT", progress, "RIGHT", 0, 0)
    cancel:SetText("Stop")
    cancel:SetScript("OnClick", function() Send("FRGCANCEL") end)
    progress.cancel = cancel
end

-- ===========================================================================
-- Dashboard embedding
-- ===========================================================================
-- The Dashboard hosts this panel directly inside its own window instead of
-- the Forge owning a window of its own -- see UncappedDashboard_UI.lua,
-- which calls EmbedInto once (to build the frame into its content group)
-- and Activate every time the Forge tab is selected. The "Where to farm"
-- popup (sourceFrame, below) stays a separate floating window -- it's
-- triggered by clicking a specific material, not "the Forge screen" itself.
local Forge = _G.UncappedForge or {}
_G.UncappedForge = Forge
Forge.UI = {}

function Forge.UI.EmbedInto(parent)
    BuildFrame(parent)
    frame:Show()
    return frame
end

function Forge.UI.Activate()
    if not frame then return end
    Send("FRGGET")
    Send("FRGPROCLIST")
    if selectedSpell then Send("FRGMATS:" .. selectedSpell) end
    BuildProfessionTabs()
    RefreshList()
    RefreshDetail()
    RefreshProgress()
end

-- Content-panel width (not window width) the Forge needs: its original
-- standalone design (720 wide) already comfortably fits the list column,
-- detail column, and the widest bottom-row button group without overlap,
-- plus the embedded group's own 6px padding on each side = 732.
function Forge.UI.GetMinWidth()
    return 732
end

-- Switches the Dashboard to the Forge tab, opening it if it's closed. Used
-- by the TRADE_SKILL_SHOW replacement and the settings-page "Open the Forge"
-- button -- the Forge has no window of its own anymore to open directly.
local function OpenInDashboard()
    local Dashboard = _G.UncappedDashboard
    if not Dashboard then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff8040[Forge]|r now lives inside the Dashboard -- load UncappedDashboard to use it.")
        return
    end
    Dashboard.SetTab("forge")
    if not (Dashboard.UI and Dashboard.UI.IsShown and Dashboard.UI.IsShown()) then
        Dashboard.Toggle()
    end
end

-- ---------------------------------------------------------------------------
-- Replacing the default tradeskill window
--
-- The recipe list still has to be REQUESTED by casting the profession spell,
-- which opens Blizzard's frame -- so this closes it on show and opens the Forge
-- instead. HookScript rather than replacing OnShow: other addons hook that
-- frame too, and whoever ran first should keep working.
-- ---------------------------------------------------------------------------
local watcher = CreateFrame("Frame")
watcher:RegisterEvent("ADDON_LOADED")
watcher:RegisterEvent("TRADE_SKILL_SHOW")

-- Keeping the window current.
--
-- The recipe list and the skill ranks behind the difficulty colours were read
-- ONCE when the window opened, so learning a recipe or gaining a skill point left
-- the list stale until it was closed and reopened.
--
-- These events ask the server for a rank/count summary (FRGSYNC), not the whole
-- list -- a full profession is hundreds of rows and a bulk craft gains skill
-- continuously, so refetching everything on each point would flood the pipe. The
-- server replies with the full list only when the recipe COUNT actually moved.
watcher:RegisterEvent("SKILL_LINES_CHANGED")     -- a skill point, incl. from crafting
watcher:RegisterEvent("LEARNED_SPELL_IN_TAB")    -- trained or discovered a recipe
watcher:RegisterEvent("CHAT_MSG_SKILL")          -- backstop; some gains only surface here

local lastSync = 0

watcher:SetScript("OnEvent", function(_, event, arg1)
    -- UncappedDashboard, not UncappedForge: this file ships inside the Dashboard
    -- now, so that is the addon whose SavedVariables load. The main-chunk InitDB()
    -- runs before they do, and `db` would keep pointing at the throwaway table.
    if event == "ADDON_LOADED" and arg1 == "UncappedDashboard" then
        InitDB()
        -- db.sortMode may have just changed under us (the throwaway table had
        -- the default), and the sort only re-runs when it is told to.
        sortDirty = true
        return
    end

    if event == "SKILL_LINES_CHANGED" or event == "LEARNED_SPELL_IN_TAB"
        or event == "CHAT_MSG_SKILL" then
        -- Only while the window is open, and at most once a second: these fire in
        -- bursts (every point of a bulk craft) and the reply is a round trip.
        if frame and frame:IsShown() then
            local now = GetTime()
            if now - lastSync > 1 then
                lastSync = now
                Send("FRGSYNC")
            end
        end
        return
    end

    if event == "TRADE_SKILL_SHOW" and db.replaceTradeSkill then
        -- TRADE_SKILL_SHOW is not "a profession was opened". It fires for every
        -- tradeskill window in the game, and 3.3.5a builds several class
        -- abilities as tradeskills: Death Knight Runeforging (skill line 776),
        -- rogue Poisons, hunter Beast Training. Replacing those wholesale meant a
        -- DK literally could not runeforge -- the window was hidden and the Forge
        -- opened over it, showing nothing, because the server's recipe index
        -- deliberately excludes class skills (CraftingIndex.cpp only accepts
        -- SKILL_CATEGORY_PROFESSION and SKILL_CATEGORY_SECONDARY). Report #184.
        --
        -- CloseTradeSkill() below is the half that actually broke it: it ends the
        -- server-side tradeskill session, so bailing out has to happen BEFORE it,
        -- not just before the OpenInDashboard.
        --
        -- The test is maxRank, not the skill's name: class tradeskills report a
        -- tiny max while any real profession has a max of at least 75, and
        -- unlike a string compare that holds on every locale.
        --
        -- ⚠ 2026-08-08, reports #290/#291: the threshold below used to be
        -- `skillMax == 0`, which is the reasoning above written down wrongly.
        -- Runeforging does NOT report 0 -- every Death Knight on this realm has
        -- character_skills (skill 776) value 1, max 1. So the bail-out never
        -- fired, CloseTradeSkill() ran, and #184 was only ever half fixed: a DK
        -- still could not runeforge, which blocks "Runeforging: Preparation for
        -- Battle", the SECOND quest of the starting zone. Nobody could level a
        -- new Death Knight past it.
        --
        -- 75 is the real boundary and it is not a guess: apprentice rank in
        -- every profession and secondary skill caps at 75, so no window we do
        -- want to replace can ever come in under it.
        if IsTradeSkillLinked and IsTradeSkillLinked() then
            return   -- someone else's linked profession -- never ours to replace
        end

        local _, _, skillMax = GetTradeSkillLine()
        if not skillMax or skillMax < 75 then
            return   -- Runeforging / Poisons / Beast Training: leave Blizzard's window alone
        end

        -- Hiding it here rather than in a TradeSkillFrame OnShow hook: the
        -- frame is loaded on demand (Blizzard_TradeSkillUI), so it may not
        -- exist yet the first time a profession is opened.
        if TradeSkillFrame and TradeSkillFrame:IsShown() then
            HideUIPanel(TradeSkillFrame)
        end
        CloseTradeSkill()
        OpenInDashboard()
    end
end)

-- ---------------------------------------------------------------------------
-- "Where do I farm this?"
--
-- Ported out of ReagentBankCraft 2026-07-31. It used to hang off Blizzard's
-- TradeSkill reagent buttons, which the Forge replaces -- so for anyone using
-- the Forge (the default) it had quietly become unreachable.
--
-- Server side is unchanged and needs no rebuild: USOURCE goes out on the same
-- REAGENTBANK transport the Forge already uses, and the USRC/USRCEND replies
-- arrive as UNC addon messages, which the comms handler above already receives.
--
-- Sources arrive one line at a time (USRC) followed by a terminator
-- (USRCEND), so lines accumulate in sourceBuffer and the window only redraws
-- once the terminator lands. Redrawing per line would flicker and, worse, show
-- a half-populated list as if it were complete.
-- ---------------------------------------------------------------------------
local SOURCE_KIND = {
    [1] = "Drops from", [2] = "Gathered from", [3] = "Fished in",
    [4] = "Skinned from", [5] = "Crafted from",
}
local SOURCE_DEFAULT_POS = { "CENTER", "CENTER", 260, 0 }

local sourceFrame = CreateFrame("Frame", "UncappedForgeSourceFrame", UIParent)
sourceFrame:SetSize(430, 340)
sourceFrame:SetFrameStrata("DIALOG")
sourceFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
sourceFrame:SetMovable(true)
sourceFrame:EnableMouse(true)
sourceFrame:RegisterForDrag("LeftButton")
sourceFrame:SetScript("OnDragStart", sourceFrame.StartMoving)
sourceFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    if db and db.savePos then
        local point, _, relPoint, x, y = self:GetPoint()
        db.sourcePos = { point, relPoint, x, y }
    end
end)
sourceFrame:Hide()
tinsert(UISpecialFrames, "UncappedForgeSourceFrame")   -- Escape closes it

local function RestoreSourceWindow()
    local p = (db and db.savePos) and db.sourcePos or nil
    sourceFrame:ClearAllPoints()
    if p then
        sourceFrame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        sourceFrame:SetPoint(SOURCE_DEFAULT_POS[1], UIParent,
            SOURCE_DEFAULT_POS[2], SOURCE_DEFAULT_POS[3], SOURCE_DEFAULT_POS[4])
    end

    -- Player window zoom. This window parents to UIParent rather than to the
    -- Dashboard (it opens beside the Forge tab, not inside it), so it inherits
    -- no scale and owns its own.
    --
    -- ⚠ Registered HERE, not at file scope where the frame is created: the
    -- frame has no anchor until this function runs, and the zoom system's
    -- re-anchoring works by rewriting anchor offsets. Registering it unanchored
    -- would apply the scale with nothing to correct, and the position restored
    -- above would then be off by the zoom factor. Re-registering is just a
    -- refresh, so running on every open is free.
    --
    -- savePosition matters because this is one of the few Uncapped windows that
    -- REMEMBERS where it was dragged (db.sourcePos). A zoom change rewrites its
    -- offsets to hold it on the same spot; without writing those corrected
    -- numbers back, the next open would restore the pre-zoom ones and the
    -- window would appear to jump.
    if UncappedScale_Register then
        UncappedScale_Register(sourceFrame, {
            -- A Dashboard pop-out: follows the Dashboard slider so the two zoom together.
            group = "dashboard",
            savePosition = function(self)
                if not (db and db.savePos) then return end
                local point, _, relPoint, x, y = self:GetPoint()
                if not point then return end
                db.sourcePos = { point, relPoint, x, y }
            end,
        })
    end
end

sourceFrame.title = sourceFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
sourceFrame.title:SetPoint("TOPLEFT", 20, -18)
sourceFrame.title:SetText("Where to farm")

sourceFrame.close = CreateFrame("Button", nil, sourceFrame, "UIPanelCloseButton")
sourceFrame.close:SetPoint("TOPRIGHT", -8, -8)

-- Visible rows. The full result set lives in the buffer and this window scrolls
-- through it -- common materials have dozens of sources and a fixed short panel
-- simply hid most of them. Re-read from the DB on each open so the settings
-- sliders take effect next time; RenderSources and the scroll handler capture
-- them as upvalues, so reassigning here updates every closure.
local SOURCE_VISIBLE_ROWS = 14
local SOURCE_ROW_HEIGHT = 20
local sourceBuffer = {}
local pendingSourceName

sourceFrame.lines = {}

-- (Re)creates and repositions the visible rows to match the current DB sizing.
-- Extra rows from a previous, larger build are hidden rather than destroyed.
local function RebuildSourceRows()
    SOURCE_VISIBLE_ROWS = (db and db.sourceRows) or 14
    SOURCE_ROW_HEIGHT = (db and db.sourceRowHeight) or 20
    for i = 1, SOURCE_VISIBLE_ROWS do
        local fs = sourceFrame.lines[i]
        if not fs then
            fs = sourceFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetWidth(365)
            fs:SetJustifyH("LEFT")
            sourceFrame.lines[i] = fs
        end
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", 22, -38 - (i - 1) * SOURCE_ROW_HEIGHT)
        fs:Show()
    end
    for i = SOURCE_VISIBLE_ROWS + 1, #sourceFrame.lines do
        sourceFrame.lines[i]:SetText("")
        sourceFrame.lines[i]:Hide()
    end
end

RebuildSourceRows()

-- FauxScrollFrame is the 3.3.5 way to scroll a fixed set of rows over a longer
-- list: the rows never move, the offset into the data changes.
sourceFrame.scroll = CreateFrame("ScrollFrame", "UncappedForgeSourceScroll", sourceFrame, "FauxScrollFrameTemplate")
sourceFrame.scroll:SetPoint("TOPLEFT", 16, -34)
sourceFrame.scroll:SetPoint("BOTTOMRIGHT", -34, 14)

local function RenderSources()
    local offset = FauxScrollFrame_GetOffset(sourceFrame.scroll) or 0

    for i = 1, SOURCE_VISIBLE_ROWS do
        sourceFrame.lines[i]:SetText("")
    end

    if #sourceBuffer == 0 then
        sourceFrame.lines[1]:SetText("|cffff8800No known source -- it may come from a quest, a nested loot table, or crafting.|r")
        FauxScrollFrame_Update(sourceFrame.scroll, 0, SOURCE_VISIBLE_ROWS, SOURCE_ROW_HEIGHT)
        return
    end

    for row = 1, SOURCE_VISIBLE_ROWS do
        local src = sourceBuffer[row + offset]
        if src then
            if src.kind == 5 then
                -- Crafted: no drop chance or location, just what it is made
                -- from and which profession makes it.
                local prof = (src.zone ~= "") and (" (" .. src.zone .. ")") or ""
                sourceFrame.lines[row]:SetText(string.format("|cffffd100Crafted from|r %s%s", src.name, prof))
            else
                -- Chance arrives in tenths of a percent; 0 means genuinely
                -- unknown (an equal-chance loot group), so show "?" not "0%".
                local chanceText = (src.chance > 0) and string.format("%.1f%%", src.chance / 10) or "?"
                local where = (src.zone ~= "" and src.zone) or "unknown area"
                local spawns = (src.spawns > 0) and (" x" .. src.spawns) or ""
                local via = (src.via ~= "") and ("|cff888888 [" .. src.via .. "]|r") or ""
                -- Dungeon sources are marked and sorted to the top.
                local tag = src.dungeon and "|cff66bbff[Dungeon]|r " or ""
                sourceFrame.lines[row]:SetText(string.format("%s|cffffd100%s|r %s - |cff00ff00%s|r in %s%s%s",
                    tag, SOURCE_KIND[src.kind] or "From", src.name, chanceText, where, spawns, via))
            end
        end
    end

    FauxScrollFrame_Update(sourceFrame.scroll, #sourceBuffer, SOURCE_VISIBLE_ROWS, SOURCE_ROW_HEIGHT)
end

sourceFrame.scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, SOURCE_ROW_HEIGHT, RenderSources)
end)

-- Called from the comms handler when USRCEND lands.
function UncappedForge_ShowSources(itemName)
    RebuildSourceRows()
    RestoreSourceWindow()
    sourceFrame.title:SetText("Where to farm: " .. (itemName or "item"))
    FauxScrollFrame_SetOffset(sourceFrame.scroll, 0)
    sourceFrame.scroll:SetVerticalScroll(0)
    RenderSources()
    sourceFrame:Show()
end

function UncappedForge_QuerySources(itemId, itemName)
    if not itemId then return end
    sourceBuffer = {}
    pendingSourceName = itemName
    Send("USOURCE:" .. itemId)
end

-- Exposed for the comms handler, which is defined above this block.
function UncappedForge_SourceBufferAdd(entry)
    tinsert(sourceBuffer, entry)
end

function UncappedForge_SourcePendingName()
    return pendingSourceName
end

-- No standalone /forge command: this window is a Dashboard tab now, opened via
-- /dashboard, so a dedicated slash command would just duplicate that entry point.

-- ---------------------------------------------------------------------------
-- Options page in the Uncapped hub (ESC > Interface > AddOns > Uncapped)
-- ---------------------------------------------------------------------------
if UncappedUI then
    local panel, L = UncappedUI.CreatePanel("Forge", "Craft from your Vault")

    L:Note("The Forge crafts server-side, so it can spend materials sitting in " ..
           "your Vault and never asks for a hammer, rod or other tool.")
    L:Gap()

    L:Check("Open the Forge instead of the default crafting window",
        function() return db.replaceTradeSkill end,
        function(value) db.replaceTradeSkill = value end)

    -- "Send finished items to the Vault" removed 2026-08-12: it is no longer a
    -- choice, the Forge always banks to the Vault.

    L:Check("Automatically make missing components",
        function() return db.autoIntermediates end,
        function(value) db.autoIntermediates = value end)

    L:Gap()
    L:Header("Where to farm")
    L:Note("Click any material in a recipe to see what drops it. Sizing takes " ..
           "effect the next time the window is opened.", 28)
    L:Slider("Visible rows", 5, 30, 1,
        function() return db.sourceRows end,
        function(value) db.sourceRows = value end, "%d")
    L:Slider("Row height", 12, 28, 1,
        function() return db.sourceRowHeight end,
        function(value) db.sourceRowHeight = value end, "%d")
    L:Check("Remember its window position",
        function() return db.savePos end,
        function(value) db.savePos = value end)
    L:Button("Reset its position", function() db.sourcePos = nil end, 180)

    L:Gap()
    L:Button("Open the Forge", function() OpenInDashboard() end)
end
