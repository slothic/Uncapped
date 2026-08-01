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

local FORGE_TITLE = "Uncapped Forge"

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
local function RecipeName(recipe)
    if not recipe then return nil end

    local spellName = GetSpellInfo(recipe.spell)
    if spellName and spellName ~= "" then return spellName end

    return ItemName(recipe.item) or ("item " .. tostring(recipe.item))
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

local function ApplyFilter()
    filtered = {}
    local search = frame and frame.search and frame.search:GetText() or ""
    search = search:lower()

    for _, recipe in ipairs(recipes) do
        local ok = (not selectedSkill) or recipe.skill == selectedSkill

        if ok and search ~= "" then
            local name = RecipeName(recipe)
            ok = name and name:lower():find(search, 1, true) ~= nil or false
        end

        if ok and db.craftableOnly then
            local possible = MaxCraftable(recipe.spell)
            -- Unknown (never asked) is kept: hiding recipes we simply have not
            -- fetched material counts for would make the list look broken.
            ok = (possible == nil) or possible > 0
        end

        if ok then filtered[#filtered + 1] = recipe end
    end

    if db.sortMode == "difficulty" then
        -- Hardest first (the ones still granting skill), then alphabetical inside
        -- each tier so the order is stable rather than arbitrary within a colour.
        table.sort(filtered, function(a, b)
            local ra, rb = DIFFICULTY_RANK[DifficultyTier(a)], DIFFICULTY_RANK[DifficultyTier(b)]
            if ra ~= rb then return ra < rb end
            return (RecipeName(a) or "") < (RecipeName(b) or "")
        end)
    else
        table.sort(filtered, function(a, b)
            return (RecipeName(a) or "") < (RecipeName(b) or "")
        end)
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
            -- UPSERT BY ITEM ID, not replace, and not blind append.
            --
            -- This used to replace the whole list on every message, on the stated
            -- assumption that "a recipe has at most 8 reagents at ~20 bytes a row,
            -- so the whole set always arrives in one message". That estimate was
            -- wrong by a factor of three: a row is `id,per,have,ICON,NAME;` and
            -- carries the icon ("INV_Misc_Gem_Opal_01") and the item name inline,
            -- so it runs 45-70 bytes. Five reagents exceed the 255-byte addon
            -- message limit, the server's Chunker splits them over two messages,
            -- and replacing meant every chunk but the LAST was silently discarded.
            --
            -- Consequences, both reported in-game: the material panel only listed
            -- the tail of the reagent set, hiding the ones the player had none of;
            -- and MaxCraftable took its minimum over that partial set, so Bronze
            -- Band of Force showed 254 craftable (509 Shadowgem / 2) while the
            -- server -- which plans against the REAL reagent list -- refused with
            -- "missing materials you cannot purchase", those being the Malachite
            -- and Bronze Setting the window never showed.
            --
            -- Keying on item id keeps the original no-doubling property that
            -- motivated the replace: this is re-requested after every craft, and
            -- re-sent rows overwrite their own key instead of piling up.
            local list = mats[spellId] or {}
            local byItem = {}
            for i, mat in ipairs(list) do
                byItem[mat.item] = i
            end

            -- The NAME is last and parsed as "everything up to the ;", so an item
            -- name containing a comma cannot shift the fields after it.
            for item, per, have, icon, name in body:gmatch("(%d+),(%d+),(%d+),([^,]*),([^;]*);") do
                local row = { item = tonumber(item), per = tonumber(per), have = tonumber(have),
                    icon = (icon ~= "" and ("Interface\\Icons\\" .. icon)) or nil,
                    name = (name ~= "" and name) or nil }

                local at = byItem[row.item]
                if at then
                    list[at] = row              -- refreshed count for a reagent we already had
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
        plan = { steps = staging.steps, needs = staging.needs,
                 total = tonumber(total) or 0, feasible = (feasible == "1"),
                 spell = tonumber(spellId) }
        staging.steps, staging.needs = {}, {}
        RefreshDetail()

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
            bagsfull  = "your bags are full -- switch the output to your Vault",
            uniquecap = "you already have as many of that as you can own",
            novellum  = "out of vellums, or no free bag slot to hold one",
            nospace   = "no free bag space -- a scroll still needs one slot to be made in",
            dead      = "you can't craft while dead",
            unknown   = "you don't know that recipe",
            busy      = "a craft is already running",
            missing   = "you're missing materials it can't make or buy",
            outofmats = "not enough of that material left",
            cannot    = "that can't be processed",
            money     = "you can't afford that",
            cancelled = "cancelled",
            offline   = "you went offline",
            noplan    = "nothing to do",
        }

        if failure and failure ~= "" then
            local why = FAILURES[failure] or ("failed (" .. failure .. ")")
            DEFAULT_CHAT_FRAME:AddMessage("|cffff8040[Forge]|r " .. why)
        end
        if crafted > 0 then
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
        for item, count, kinds, name in body:gmatch("(%d+),(%d+),(%d+),([^;]*);") do
            staging.proc[#staging.proc + 1] = { item = tonumber(item), count = tonumber(count),
                kinds = tonumber(kinds), name = (name ~= "" and name) or nil }
        end

    elseif body:find("^FRGPROCEND:") then
        processable = staging.proc
        staging.proc = {}
        table.sort(processable, function(a, b) return a.count > b.count end)
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
    -- RBSRC:<itemId>:<kind>:<chanceTenths>:<spawns>:<dungeon>:<name>|<zone>|<via>
    elseif body:find("^RBSRC:") then
        local kind, chance, spawns, dungeon, rest =
            body:match("^RBSRC:%d+:(%d+):(%d+):(%d+):(%d+):(.*)$")
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

    elseif body:find("^RBSRCEND:") then
        UncappedForge_ShowSources(UncappedForge_SourcePendingName())
    end
end)

-- Names arriving from the item cache change what the list should say, so
-- re-render periodically while anything is still unresolved.
local ticker = CreateFrame("Frame")
local sinceTick = 0
ticker:SetScript("OnUpdate", function(_, elapsed)
    sinceTick = sinceTick + elapsed
    if sinceTick < 0.5 then return end
    sinceTick = 0

    if frame and frame:IsShown() then
        RefreshList()
        RefreshDetail()
    end
end)

-- ===========================================================================
-- UI
-- ===========================================================================
-- 14 rows at 22px starting at -76 ends at -384, clearing the bottom controls in
-- a 500-tall frame. The first version used 16 rows in a 460-tall frame, which ran
-- the list straight down through the amount box and the checkboxes.
local ROWS, ROW_HEIGHT = 14, 22
local FRAME_WIDTH, FRAME_HEIGHT = 720, 500
local LIST_TOP = -76

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
    local source = isProcess and processable or filtered
    local offset = FauxScrollFrame_GetOffset(listScroll) or 0

    FauxScrollFrame_Update(listScroll, #source, ROWS, ROW_HEIGHT)

    for i = 1, ROWS do
        local button = listButtons[i]
        local entry = source[offset + i]

        if not entry then
            button:Hide()
        else
            button:Show()

            if isProcess then
                local name = entry.name or ItemName(entry.item) or ("item " .. entry.item)
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
        AddLine("Everything in your Vault that can be milled, prospected or", 0.8, 0.8, 0.8)
        AddLine("disenchanted. Pick a row on the left, then a button below.", 0.8, 0.8, 0.8)
        AddLine(" ")
        local selected = detail.processEntry
        if selected then
            local name = selected.name or ItemName(selected.item) or ("item " .. selected.item)
            AddLine(name .. "  |cff808080x" .. Commafy(selected.count) .. "|r", 1, 0.82, 0)
            if bit.band(selected.kinds, 1) ~= 0 then AddLine("Millable (5 per operation)", 0.6, 1, 0.6) end
            if bit.band(selected.kinds, 2) ~= 0 then AddLine("Prospectable (5 per operation)", 0.6, 1, 0.6) end
            if bit.band(selected.kinds, 4) ~= 0 then AddLine("Disenchantable", 0.6, 1, 0.6) end
        else
            AddLine("Nothing selected.", 0.6, 0.6, 0.6)
        end

        detail.craft:Hide()
        detail.craftAll:Hide()
        detail.buy:Hide()
        detail.mill:Show()
        detail.prospect:Show()
        detail.disenchant:Show()
        return
    end

    detail.mill:Hide()
    detail.prospect:Hide()
    detail.disenchant:Hide()
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

    if #plan.needs > 0 then
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
            ResetScroll()
            UIDropDownMenu_SetText(frame.profDrop, ProfessionLabel())
            RefreshList()
            RefreshDetail()
        end
        UIDropDownMenu_AddButton(sep, level)
    end)

    UIDropDownMenu_SetWidth(frame.profDrop, 190)
    UIDropDownMenu_SetText(frame.profDrop, ProfessionLabel())
end

local function BuildFrame()
    if frame then return end

    frame = CreateFrame("Frame", "UncappedForgeFrame", UIParent)
    frame:SetWidth(FRAME_WIDTH)
    frame:SetHeight(FRAME_HEIGHT)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetFrameStrata("HIGH")
    frame:Hide()
    frame.mode = "craft"

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", frame, "TOP", 0, -16)
    title:SetText(FORGE_TITLE)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)

    -- Profession picker (see BuildProfessionTabs). Populated once the server's
    -- profession list lands, which is after this frame is built.
    local profDrop = CreateFrame("Frame", "UncappedForgeProfDrop", frame, "UIDropDownMenuTemplate")
    profDrop:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -40)
    frame.profDrop = profDrop

    -- Search box
    local search = CreateFrame("EditBox", "UncappedForgeSearch", frame, "InputBoxTemplate")
    search:SetWidth(150)
    search:SetHeight(20)
    search:SetPoint("TOPLEFT", frame, "TOPLEFT", 240, -46)
    search:SetAutoFocus(false)
    search:SetScript("OnTextChanged", function()
        ApplyFilter()
        RefreshList()
    end)
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
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
    sortDrop:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 8, -40)
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

    -- Recipe list
    local listFrame = CreateFrame("Frame", nil, frame)
    listFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, LIST_TOP)
    listFrame:SetWidth(330)
    listFrame:SetHeight(ROWS * ROW_HEIGHT)

    listScroll = CreateFrame("ScrollFrame", "UncappedForgeScroll", listFrame, "FauxScrollFrameTemplate")
    listScroll:SetAllPoints(listFrame)
    listScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, RefreshList)
    end)

    listButtons = {}
    for i = 1, ROWS do
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

    -- Detail pane
    detail = CreateFrame("Frame", nil, frame)
    detail:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -18, LIST_TOP)
    detail:SetWidth(340)
    detail:SetHeight(ROWS * ROW_HEIGHT)
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
        local perOp = (kind == 2) and 1 or 5
        local ops = math.floor(entry.count / perOp)
        if ops < 1 then return end
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

    tinsert(UISpecialFrames, "UncappedForgeFrame")   -- Escape closes it
end

local function Open()
    BuildFrame()
    frame:Show()
    Send("FRGGET")
    Send("FRGPROCLIST")
    if selectedSpell then Send("FRGMATS:" .. selectedSpell) end
    BuildProfessionTabs()
    RefreshList()
    RefreshDetail()
    RefreshProgress()
end

local function Toggle()
    BuildFrame()
    if frame:IsShown() then frame:Hide() else Open() end
end

_G.UncappedForge_Toggle = Toggle

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
    if event == "ADDON_LOADED" and arg1 == "UncappedForge" then
        InitDB()
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
        -- Hiding it here rather than in a TradeSkillFrame OnShow hook: the
        -- frame is loaded on demand (Blizzard_TradeSkillUI), so it may not
        -- exist yet the first time a profession is opened.
        if TradeSkillFrame and TradeSkillFrame:IsShown() then
            HideUIPanel(TradeSkillFrame)
        end
        CloseTradeSkill()
        Open()
    end
end)

-- ---------------------------------------------------------------------------
-- "Where do I farm this?"
--
-- Ported out of ReagentBankCraft 2026-07-31. It used to hang off Blizzard's
-- TradeSkill reagent buttons, which the Forge replaces -- so for anyone using
-- the Forge (the default) it had quietly become unreachable.
--
-- Server side is unchanged and needs no rebuild: RBSOURCE goes out on the same
-- REAGENTBANK transport the Forge already uses, and the RBSRC/RBSRCEND replies
-- arrive as UNC addon messages, which the comms handler above already receives.
--
-- Sources arrive one line at a time (RBSRC) followed by a terminator
-- (RBSRCEND), so lines accumulate in sourceBuffer and the window only redraws
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

-- Called from the comms handler when RBSRCEND lands.
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
    Send("RBSOURCE:" .. itemId)
end

-- Exposed for the comms handler, which is defined above this block.
function UncappedForge_SourceBufferAdd(entry)
    tinsert(sourceBuffer, entry)
end

function UncappedForge_SourcePendingName()
    return pendingSourceName
end

SLASH_UNCAPPEDFORGE1 = "/forge"
SLASH_UNCAPPEDFORGE2 = "/uncappedforge"
SlashCmdList["UNCAPPEDFORGE"] = Toggle

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
    L:Button("Open the Forge", function() Open() end)
end
