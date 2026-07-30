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
    lastAmount        = 1,
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

local function DifficultyColor(recipe)
    local rank = SkillRank(recipe.skill)
    if recipe.tlow > 0 and rank >= recipe.tlow then return DIFFICULTY.trivial end
    if recipe.thigh > 0 and rank >= recipe.thigh then return DIFFICULTY.easy end
    if rank >= recipe.min + 25 then return DIFFICULTY.medium end
    return DIFFICULTY.optimal
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

    table.sort(filtered, function(a, b)
        return (RecipeName(a) or "") < (RecipeName(b) or "")
    end)
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
            -- REPLACE, never append. A recipe has at most 8 reagents at ~20
            -- bytes a row, so the whole set always arrives in one message -- and
            -- this is re-requested after every craft, so accumulating into a
            -- staged list would double the reagent rows each time round.
            local list = {}
            -- The NAME is last and parsed as "everything up to the ;", so an item
            -- name containing a comma cannot shift the fields after it.
            for item, per, have, icon, name in body:gmatch("(%d+),(%d+),(%d+),([^,]*),([^;]*);") do
                list[#list + 1] = { item = tonumber(item), per = tonumber(per), have = tonumber(have),
                    icon = (icon ~= "" and ("Interface\\Icons\\" .. icon)) or nil,
                    name = (name ~= "" and name) or nil }
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
        for spell, item, crafts, depth in body:gmatch("(%d+),(%d+),(%d+),(%d+);") do
            staging.steps[#staging.steps + 1] = { spell = tonumber(spell), item = tonumber(item),
                crafts = tonumber(crafts), depth = tonumber(depth) }
            ItemName(tonumber(item))
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

        -- Counts moved; re-ask rather than guessing at them locally.
        if selectedSpell then Send("FRGMATS:" .. selectedSpell) end
        Send("FRGPROCLIST")

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
    detail.lineCount = 0

    local function AddLine(text, r, g, b, indent)
        detail.lineCount = detail.lineCount + 1
        local line = detail.lines[detail.lineCount]
        if not line then
            line = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            line:SetJustifyH("LEFT")
            detail.lines[detail.lineCount] = line
        end
        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", detail, "TOPLEFT", 10 + (indent or 0), -34 - (detail.lineCount - 1) * 14)
        line:SetPoint("RIGHT", detail, "RIGHT", -10, 0)
        line:SetText(text)
        line:SetTextColor(r or 1, g or 1, b or 1)
        line:Show()
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

    AddLine("Materials (Vault + bags)", 1, 0.82, 0)
    local list = mats[recipe.spell]
    if not list then
        AddLine("...", 0.6, 0.6, 0.6)
    else
        for _, mat in ipairs(list) do
            local matName = mat.name or ItemName(mat.item) or ("item " .. mat.item)
            local need = mat.per * amount
            local enough = mat.have >= need
            AddLine(string.format("%s  %s / %s", matName, Commafy(mat.have), Commafy(need)),
                enough and 0.4 or 1, enough and 1 or 0.4, 0.4, 8)
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
                    local stepName = GetSpellInfo(step.spell) or ItemName(step.item)
                        or ("item " .. step.item)
                    AddLine(string.format("%s x%s", stepName, Commafy(step.crafts)), 0.7, 0.85, 1, 8)
                end
            end
        end
        if #plan.needs > 0 then
            AddLine("Still missing:", 1, 0.4, 0.4)
            for _, need in ipairs(plan.needs) do
                local needName = need.name or ItemName(need.item) or ("item " .. need.item)
                AddLine(string.format("%s x%s", needName, Commafy(need.missing)), 1, 0.5, 0.5, 8)
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
watcher:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "UncappedForge" then
        InitDB()
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
    L:Button("Open the Forge", function() Open() end)
end
