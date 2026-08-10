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

local ADDON_PIPE_PREFIX = "UNC"           -- server replies arrive on this prefix
local TRANSPORT_PREFIX  = "REAGENTBANK"   -- shared client->server transport

-- ---------------------------------------------------------------------------
-- SavedVariables
-- ---------------------------------------------------------------------------
local DEFAULTS = {
    replaceTradeSkill = true,   -- open the Forge instead of Blizzard's window
    outputToVault     = true,   -- finished items go to the vault
    autoIntermediates = true,   -- craft missing sub-components automatically
    craftableOnly     = false,  -- list filter
    sortMode          = "name",  -- "name" or "difficulty"
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
local SEARCH_HINT = { craft = "Search recipes...", process = "Search materials..." }

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

local function DifficultyTier(recipe)
    local rank = SkillRank(recipe.skill)
    if recipe.tlow > 0 and rank >= recipe.tlow then return "trivial" end
    if recipe.thigh > 0 and rank >= recipe.thigh then return "easy" end
    if rank >= recipe.min + 25 then return "medium" end
    return "optimal"
end

local function DifficultyColor(recipe)
    return DIFFICULTY[DifficultyTier(recipe)]
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
local staging = { profs = {}, recs = {}, steps = {}, needs = {}, proc = {} }
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

    if db.sortMode == "difficulty" then
        -- Hardest first (the ones still granting skill), then alphabetical inside
        -- each tier so the order is stable rather than arbitrary within a colour.
        table.sort(recipes, function(a, b)
            local ra, rb = DIFFICULTY_RANK[DifficultyTier(a)], DIFFICULTY_RANK[DifficultyTier(b)]
            if ra ~= rb then return ra < rb end
            return (RecipeName(a) or "") < (RecipeName(b) or "")
        end)
    else
        table.sort(recipes, function(a, b)
            return (RecipeName(a) or "") < (RecipeName(b) or "")
        end)
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
        end

        if ok then filtered[#filtered + 1] = recipe end
    end

    -- The same box filters the bulk-processing view, which is the other list
    -- this window can show. `processable` arrives already ordered by stack size
    -- (see FRGPROCEND), so this only ever drops rows -- never reorders them.
    filteredProc = {}
    for _, entry in ipairs(processable) do
        if MatchesSearch(ProcessNameLower(entry), entry.item) then
            filteredProc[#filteredProc + 1] = entry
        end
    end
end

-- Forward locals: the comms handler below fires before these are defined, and
-- professions/recipes arrive asynchronously after the window is already open.
local RefreshList, RefreshDetail, RefreshProgress, BuildProfessionTabs, ResetScroll

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

    elseif body:find("^FRGEND:") then
        professions = staging.profs
        recipes = staging.recs
        staging.profs, staging.recs = {}, {}

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

    elseif body:find("^FRGDONE:") then
        local crafted, failure = body:match("^FRGDONE:(%d+):(.*)$")
        crafted = tonumber(crafted) or 0
        job = nil
        RefreshProgress()

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
                Commafy(crafted), db.outputToVault and " into your Vault" or "", why))
        elseif failure and failure ~= "" then
            local why = FAILURES[failure] or ("failed (" .. failure .. ")")
            DEFAULT_CHAT_FRAME:AddMessage("|cffff8040[Forge]|r " .. why)
        elseif crafted > 0 then
            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                "|cffff8040[Forge]|r produced |cffffffff%s|r item(s)%s.",
                Commafy(crafted), db.outputToVault and " into your Vault" or ""))
        end

        -- Counts moved; re-ask rather than guessing at them locally. A craft is
        -- also the main way skill goes up, so re-check ranks and the recipe count.
        if selectedSpell then Send("FRGMATS:" .. selectedSpell) end
        Send("FRGPROCLIST")
        Send("FRGSYNC")

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

    elseif body:find("^FRGPROCEND:") then
        processable = staging.proc
        staging.proc = {}
        table.sort(processable, function(a, b) return a.count > b.count end)
        ApplyFilter()   -- rebuilds filteredProc against the current query
        if frame and frame.mode == "process" then RefreshList() end

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
        if namesChanged then
            namesChanged = false
            sortDirty = true
            ApplyFilter()
        end
        RefreshList()
        RefreshDetail()
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
    plan = { steps = {}, needs = {}, total = 0, feasible = true }
    staging.steps, staging.needs = {}, {}
    if spellId then
        Send("FRGMATS:" .. spellId)
        RequestPlan()
    end
    RefreshList()
    RefreshDetail()
end

function RefreshList()
    if not frame or not listButtons then return end

    local isProcess = frame.mode == "process"
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
                button.icon:SetTexture(ItemIcon(entry.item))
                button.label:SetText(name)
                button.label:SetTextColor(colour[1], colour[2], colour[3])

                local possible = MaxCraftable(entry.spell)
                button.right:SetText(possible and possible > 0 and ("|cff40ff40" .. Commafy(possible) .. "|r") or "")
                button.entry = nil
                button.spell = entry.spell
            end

            if (button.spell and button.spell == selectedSpell) then
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

    if frame.mode == "process" then
        detail.title:SetText("Bulk processing")
        AddLine("Everything in your Vault that can be milled, prospected,", 0.8, 0.8, 0.8)
        AddLine("disenchanted or rendered down. Pick a row, then a button.", 0.8, 0.8, 0.8)
        AddLine(" ")
        local selected = detail.processEntry
        if selected then
            local name = ProcessName(selected)
            local perOp = selected.perOp or 5
            AddLine(name .. "  |cff808080x" .. Commafy(selected.count) .. "|r", 1, 0.82, 0)
            if bit.band(selected.kinds, 1) ~= 0 then AddLine("Millable (5 per operation)", 0.6, 1, 0.6) end
            if bit.band(selected.kinds, 2) ~= 0 then AddLine("Prospectable (5 per operation)", 0.6, 1, 0.6) end
            if bit.band(selected.kinds, 4) ~= 0 then AddLine("Disenchantable", 0.6, 1, 0.6) end
            if bit.band(selected.kinds, 8) ~= 0 then
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
        detail.mill:Show()
        detail.prospect:Show()
        detail.disenchant:Show()
        detail.render:Show()
        return
    end

    detail.mill:Hide()
    detail.prospect:Hide()
    detail.disenchant:Hide()
    detail.render:Hide()
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
        return
    end

    local name = RecipeName(recipe)
    detail.title:SetText(recipe.yield > 1 and (name .. " x" .. recipe.yield) or name)
    detail.productIcon:SetTexture(ItemIcon(recipe.item, prodIcon[recipe.spell]))

    local amount = RequestedAmount()

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
-- Bulk processing lives in the same dropdown rather than as a separate button:
-- it is another view of the same window, and one control that always says what
-- you are looking at beats two that can disagree.
-- The one search box serves both lists, so its greyed hint says which one it is
-- pointed at right now.
local function UpdateSearchHint()
    if not (frame and frame.search and frame.search.placeholder) then return end
    frame.search.placeholder:SetText(
        (frame.mode == "process") and SEARCH_HINT.process or SEARCH_HINT.craft)
end

local function ProfessionLabel()
    if frame and frame.mode == "process" then return "Bulk processing" end

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
                ApplyFilter()
                ResetScroll()
                UpdateSearchHint()
                UIDropDownMenu_SetText(frame.profDrop, ProfessionLabel())
                RefreshList()
                RefreshDetail()
            end
            UIDropDownMenu_AddButton(info, level)
        end

        local sep = UIDropDownMenu_CreateInfo()
        sep.text = "Bulk processing"
        sep.value = "process"
        sep.checked = (frame.mode == "process")
        sep.func = function()
            frame.mode = "process"
            Send("FRGPROCLIST")
            ApplyFilter()   -- the query carries over to this list too
            ResetScroll()
            UpdateSearchHint()
            UIDropDownMenu_SetText(frame.profDrop, ProfessionLabel())
            RefreshList()
            RefreshDetail()
        end
        UIDropDownMenu_AddButton(sep, level)
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
    onlyCheck:SetScript("OnClick", function(self)
        db.craftableOnly = self:GetChecked() and true or false
        ApplyFilter()
        RefreshList()
    end)
    local onlyLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    onlyLabel:SetPoint("LEFT", onlyCheck, "RIGHT", 2, 0)
    onlyLabel:SetText("Craftable only")

    -- Sort mode. Difficulty sorts hardest first, in the same order as the colour
    -- ladder (orange -> yellow -> green -> grey), which puts everything still
    -- worth skill points at the top of the list.
    local SORTS = {
        { value = "name",       text = "Name" },
        { value = "difficulty", text = "Difficulty" },
    }

    local sortDrop = CreateFrame("Frame", "UncappedForgeSortDrop", frame, "UIDropDownMenuTemplate")
    sortDrop:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 8, -10)
    frame.sortDrop = sortDrop

    local function sortText(value)
        for _, entry in ipairs(SORTS) do
            if entry.value == value then return entry.text end
        end
        return "Name"
    end

    UIDropDownMenu_Initialize(sortDrop, function(_, level)
        for _, entry in ipairs(SORTS) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = entry.text
            info.value = entry.value
            info.checked = (db.sortMode == entry.value)
            info.func = function()
                db.sortMode = entry.value
                sortDirty = true
                UIDropDownMenu_SetText(sortDrop, entry.text)
                ApplyFilter()
                ResetScroll()
                RefreshList()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UIDropDownMenu_SetWidth(sortDrop, 90)
    UIDropDownMenu_SetText(sortDrop, sortText(db.sortMode))

    local sortLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sortLabel:SetPoint("RIGHT", sortDrop, "LEFT", -2, 0)
    sortLabel:SetText("Sort")

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
            if frame.mode == "process" then
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
    detail.title:SetPoint("RIGHT", detail, "RIGHT", -8, 0)
    detail.title:SetJustifyH("LEFT")

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

    local function StartCraft(count)
        if not selectedSpell then return end
        Send(string.format("FRGCRAFT:%d:%d:%d:%d", selectedSpell, count,
            db.autoIntermediates and 1 or 0, db.outputToVault and 0 or 1))
        job = { done = 0, total = count, crafted = 0 }
        RefreshProgress()
    end

    detail.craft = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    detail.craft:SetWidth(90)
    detail.craft:SetHeight(22)
    detail.craft:SetPoint("LEFT", amount, "RIGHT", 8, 0)
    detail.craft:SetText("Craft")
    detail.craft:SetScript("OnClick", function() StartCraft(RequestedAmount()) end)

    detail.craftAll = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    detail.craftAll:SetWidth(90)
    detail.craftAll:SetHeight(22)
    detail.craftAll:SetPoint("LEFT", detail.craft, "RIGHT", 4, 0)
    detail.craftAll:SetText("Craft All")
    detail.craftAll:SetScript("OnClick", function()
        -- "All" means what the materials currently support. With intermediates
        -- on, the server may well manage more than this by smelting -- but
        -- promising a number we cannot compute client-side would be worse.
        local possible = MaxCraftable(selectedSpell)
        if possible and possible > 0 then StartCraft(possible) end
    end)

    detail.buy = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    detail.buy:SetWidth(150)
    detail.buy:SetHeight(22)
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

    -- Bulk processing buttons, shown only on the processing tab
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
        -- The server clamps a single request to 10,000 operations (MAX_BATCH),
        -- so clamp here too or the progress bar promises a total the run will
        -- never reach: a 2.6-million meat pile is five presses, and the bar has
        -- to say 10,000 each time rather than 43,565 once. Press again for the
        -- rest -- the row's count refreshes when the run finishes.
        if ops > 10000 then ops = 10000 end
        Send(string.format("FRGPROC:%d:%d:%d", kind, entry.item, ops))
        job = { done = 0, total = ops, crafted = 0 }
        RefreshProgress()
    end

    detail.mill = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    detail.mill:SetWidth(100)
    detail.mill:SetHeight(22)
    detail.mill:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 400, 60)
    detail.mill:SetText("Mill All")
    detail.mill:SetScript("OnClick", function() StartProcess(0) end)
    detail.mill:Hide()

    detail.prospect = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    detail.prospect:SetWidth(100)
    detail.prospect:SetHeight(22)
    detail.prospect:SetPoint("LEFT", detail.mill, "RIGHT", 4, 0)
    detail.prospect:SetText("Prospect All")
    detail.prospect:SetScript("OnClick", function() StartProcess(1) end)
    detail.prospect:Hide()

    detail.disenchant = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    detail.disenchant:SetWidth(100)
    detail.disenchant:SetHeight(22)
    detail.disenchant:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 400, 34)
    detail.disenchant:SetText("Disenchant All")
    detail.disenchant:SetScript("OnClick", function() StartProcess(2) end)
    detail.disenchant:Hide()

    detail.render = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    detail.render:SetWidth(100)
    detail.render:SetHeight(22)
    detail.render:SetPoint("LEFT", detail.disenchant, "RIGHT", 4, 0)
    detail.render:SetText("Render All")
    detail.render:SetScript("OnClick", function() StartProcess(3) end)
    detail.render:Hide()

    -- Output destination
    local vaultCheck = CreateFrame("CheckButton", "UncappedForgeVaultOut", frame, "UICheckButtonTemplate")
    vaultCheck:SetWidth(22)
    vaultCheck:SetHeight(22)
    vaultCheck:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 22, 34)
    vaultCheck:SetChecked(db.outputToVault)
    vaultCheck:SetScript("OnClick", function(self)
        db.outputToVault = self:GetChecked() and true or false
    end)
    local vaultLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    vaultLabel:SetPoint("LEFT", vaultCheck, "RIGHT", 2, 0)
    vaultLabel:SetText("Finished items to Vault")

    local subCheck = CreateFrame("CheckButton", "UncappedForgeSubs", frame, "UICheckButtonTemplate")
    subCheck:SetWidth(22)
    subCheck:SetHeight(22)
    subCheck:SetPoint("LEFT", vaultLabel, "RIGHT", 12, 0)
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
    local cancel = CreateFrame("Button", nil, progress, "UIPanelButtonTemplate")
    cancel:SetWidth(60)
    cancel:SetHeight(18)
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

_G.UncappedForge_Toggle = OpenInDashboard

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
watcher:RegisterEvent("PLAYER_LOGIN")
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

    L:Check("Send finished items to the Vault",
        function() return db.outputToVault end,
        function(value) db.outputToVault = value end)

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
