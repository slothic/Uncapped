--[[ ==========================================================================
     UncappedKeystone -- the Dashboard's "M+ Rewards" tab.

     Owner request, 2026-08-11: "a place to preview rewards, with + and minus and
     picking a dungeon/raid".

     WHAT IT IS FOR
     --------------
     The Mythic+ payout is two terms multiplied together:

         reward  =  CLEAR SIZE  x  KEY BONUS

     CLEAR SIZE is how much dungeon you kill, measured in Utgarde Keeps -- so a
     long instance pays more than a short one, and a raid pays exactly what a
     dungeon of the same size pays. KEY BONUS rises linearly with keystone level
     (it used to double; the 2026-08-14 progression reset made every curve linear).

     Both halves are legible on their own, and the whole point of this panel is
     that a player can SEE the second one compound. Pick a map, hold down [+],
     watch the numbers pull away. That is the argument for pushing, made with the
     player's own numbers instead of a patch note.

     WHERE THE NUMBERS COME FROM
     ---------------------------
     ★ NOTHING HERE IS A COPY OF THE FORMULA'S CONSTANTS. On open, the client
       asks MRWQ and the server replies with the anchor, the Anima rate and the
       doubling interval it is actually paying with, plus one CLEAR SIZE per map
       computed from that map's own spawn table. This addon multiplies. So a
       `.reload config` retune moves this panel too, and the panel cannot drift
       into advertising a payout the server stopped making -- which is exactly
       the bug the keystone NPC had, quoting gold that was never granted.

     ⚠ IT IS AN ESTIMATE OF A FULL CLEAR, AND IT SAYS SO ON SCREEN. The server
       pays for what you actually killed; this quotes the enemy-forces gate plus
       every boss, which is the least a completed run kills. Clear more than the
       gate and you earn more than the panel showed -- never less.

     ⚠ DEGRADE, NEVER ERROR. This ships in a payload release and first runs on a
       live client against whatever server build is up. An older server never
       answers MRWQ, and the panel says so after a timeout instead of sitting on
       "Loading..." forever.

     3.3.5a: no BackdropTemplate, no C_Timer (hence the OnUpdate timeout), and
     arg1..argN globals on some event paths.

       /keystone        open it
       /keystone sync   force a refresh
     ========================================================================== ]]

local ADDON_PIPE_PREFIX = "UNC"          -- server -> client
local TRANSPORT_PREFIX  = "REAGENTBANK"  -- client -> server (shared transport)

local REPLY_TIMEOUT = 6.0

local COLOR_HEAD  = "|cff9CC243"
local COLOR_LABEL = "|cffffffff"
local COLOR_VALUE = "|cffffff00"
local COLOR_DIM   = "|cff888888"
local COLOR_GOOD  = "|cff1eff00"

local Keystone = _G.UncappedKeystone or {}
_G.UncappedKeystone = Keystone
Keystone.UI = {}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
-- Filled from the wire. `tuning` stays nil until the server answers, and every
-- render path checks it -- that is what makes the no-answer case a message
-- rather than an arithmetic error on nil.
local tuning            -- { anchor, animaRate, doubleEvery, hotzone }
--[[ [#942] Which map ids are hotzones RIGHT NOW, as a set, from MRWZ.
     `tuning.hotzone` has always carried the MULTIPLIER; this is the missing
     half that says what to apply it to. Eight maps are live at any moment, so
     this is a set rather than a single id, and empty is a normal answer. ]]
local hotMaps = {}
local maps = {}         -- array of { id, size, raid, name }
local pending = false   -- a request is in flight
local requestedAt = 0
local answered = false

local selected          -- index into `maps`
local level = 10
local filter = "all"    -- all | dungeon | raid

local frame, listScroll, listButtons, statusText
local previewTexts = {}
local levelText

--[[ ------------------------------------------------------------------------
     [#708] COLLAPSIBLE GROUPS FOR THE MAP LIST.

     "almost impossible too find anything due too all being jumbled up" -- and
     that is an accurate description rather than a complaint about taste. The
     list is 74 maps in an 18-row window, sorted by CLEAR SIZE descending, so
     Deadmines sits between two raids and there is no order the eye can follow.

     ★ WHY THE EXPANSION IS A CLIENT-SIDE TABLE AND NOT A WIRE FIELD.

       The server's row format is `<id>,<size>,<raid>,<name>` and the pattern
       that reads it (see HandleMessage) captures the NAME GREEDILY AS THE LAST
       FIELD -- `(.*)$` -- because a map name may itself contain a comma. So a
       new field inserted BEFORE the name breaks every client already deployed,
       and a new field AFTER it is swallowed by the name capture and can never
       be read. Neither half of that is worth a wire break for a label.

       Map ids are frozen WotLK content: 3.3.5a will not ship a 75th instance,
       so this table cannot rot the way a copied CONSTANT can. And anything it
       does not recognise lands in "Other" rather than vanishing -- a map the
       server starts advertising that this table has never heard of must still
       be pickable.
  -------------------------------------------------------------------------- ]]
local MAP_EXPANSION = {
    -- Classic
    [33]  = "classic",  -- Shadowfang Keep
    [34]  = "classic",  -- The Stockade
    [36]  = "classic",  -- The Deadmines
    [43]  = "classic",  -- Wailing Caverns
    [47]  = "classic",  -- Razorfen Kraul
    [48]  = "classic",  -- Blackfathom Deeps
    [70]  = "classic",  -- Uldaman
    [90]  = "classic",  -- Gnomeregan
    [109] = "classic",  -- Sunken Temple
    [129] = "classic",  -- Razorfen Downs
    [189] = "classic",  -- Scarlet Monastery
    [209] = "classic",  -- Zul'Farrak
    [229] = "classic",  -- Blackrock Spire
    [230] = "classic",  -- Blackrock Depths
    [249] = "classic",  -- Onyxia's Lair (raid)
    [289] = "classic",  -- Scholomance
    [309] = "classic",  -- Zul'Gurub (raid)
    [329] = "classic",  -- Stratholme
    [349] = "classic",  -- Maraudon
    [389] = "classic",  -- Ragefire Chasm
    [409] = "classic",  -- Molten Core (raid)
    [429] = "classic",  -- Dire Maul
    [469] = "classic",  -- Blackwing Lair (raid)
    [509] = "classic",  -- Ruins of Ahn'Qiraj (raid)
    [531] = "classic",  -- Temple of Ahn'Qiraj (raid)

    -- The Burning Crusade
    [269] = "tbc",      -- The Black Morass
    [532] = "tbc",      -- Karazhan (raid)
    [534] = "tbc",      -- Hyjal Summit (raid)
    [540] = "tbc",      -- The Shattered Halls
    [542] = "tbc",      -- The Blood Furnace
    [543] = "tbc",      -- Hellfire Ramparts
    [544] = "tbc",      -- Magtheridon's Lair (raid)
    [545] = "tbc",      -- The Steamvault
    [546] = "tbc",      -- The Underbog
    [547] = "tbc",      -- The Slave Pens
    [548] = "tbc",      -- Serpentshrine Cavern (raid)
    [550] = "tbc",      -- Tempest Keep (raid)
    [552] = "tbc",      -- The Arcatraz
    [553] = "tbc",      -- The Botanica
    [554] = "tbc",      -- The Mechanar
    [555] = "tbc",      -- Shadow Labyrinth
    [556] = "tbc",      -- Sethekk Halls
    [557] = "tbc",      -- Mana-Tombs
    [558] = "tbc",      -- Auchenai Crypts
    [560] = "tbc",      -- Old Hillsbrad Foothills
    [564] = "tbc",      -- Black Temple (raid)
    [565] = "tbc",      -- Gruul's Lair (raid)
    [568] = "tbc",      -- Zul'Aman (raid)
    [580] = "tbc",      -- Sunwell Plateau (raid)
    [585] = "tbc",      -- Magisters' Terrace

    -- Wrath of the Lich King. Naxxramas (533) is filed here, not under Classic:
    -- the 3.3.5 client's map 533 IS the Northrend re-issue, which is what a
    -- player on this realm actually walks into.
    [533] = "wrath",    -- Naxxramas (raid)
    [574] = "wrath",    -- Utgarde Keep
    [575] = "wrath",    -- Utgarde Pinnacle
    [576] = "wrath",    -- The Nexus
    [578] = "wrath",    -- The Oculus
    [595] = "wrath",    -- The Culling of Stratholme
    [599] = "wrath",    -- Halls of Stone
    [600] = "wrath",    -- Drak'Tharon Keep
    [601] = "wrath",    -- Azjol-Nerub
    [602] = "wrath",    -- Halls of Lightning
    [603] = "wrath",    -- Ulduar (raid)
    [604] = "wrath",    -- Gundrak
    [608] = "wrath",    -- Violet Hold
    [615] = "wrath",    -- The Obsidian Sanctum (raid)
    [616] = "wrath",    -- The Eye of Eternity (raid)
    [619] = "wrath",    -- Ahn'kahet: The Old Kingdom
    [624] = "wrath",    -- Vault of Archavon (raid)
    [631] = "wrath",    -- Icecrown Citadel (raid)
    [632] = "wrath",    -- The Forge of Souls
    [649] = "wrath",    -- Trial of the Crusader (raid)
    [650] = "wrath",    -- Trial of the Champion
    [658] = "wrath",    -- Pit of Saron
    [668] = "wrath",    -- Halls of Reflection
    [724] = "wrath",    -- The Ruby Sanctum (raid)
}

-- Six groups (expansion x dungeon/raid) plus the catch-all. Order here is the
-- order they appear in the list; a group with no maps under the current filter
-- emits NO header at all, so picking "Raids" does not paint three empty
-- "... Dungeons" titles.
local GROUPS = {
    { key = "classic_dungeon", expac = "classic", label = "Classic Dungeons" },
    { key = "classic_raid",    expac = "classic", label = "Classic Raids" },
    { key = "tbc_dungeon",     expac = "tbc",     label = "Burning Crusade Dungeons" },
    { key = "tbc_raid",        expac = "tbc",     label = "Burning Crusade Raids" },
    { key = "wrath_dungeon",   expac = "wrath",   label = "Wrath Dungeons" },
    { key = "wrath_raid",      expac = "wrath",   label = "Wrath Raids" },
    { key = "other",           expac = "other",   label = "Other" },
}

local function GroupKeyFor(m)
    local expac = MAP_EXPANSION[m.id]
    if not expac then return "other" end
    return expac .. (m.raid and "_raid" or "_dungeon")
end

-- ---------------------------------------------------------------------------
-- SavedVariables -- the collapsed/expanded state of those groups.
--
-- ⚠ UncappedKeystoneDB is ALREADY declared in UncappedDashboard.toc and was
--   used by nothing: a free registered slot, so this needs no .toc change.
--
-- ⚠ NIL MEANS COLLAPSED, and that is the whole point. Six header rows is the
--   answer to "impossible to find anything"; opening on 74 rows with headers
--   added is the same complaint plus decoration. Reading the default off nil
--   (rather than writing `true` for every key at init) also means a group key
--   added to GROUPS later starts collapsed for players who already have a
--   saved table, instead of springing open on them.
-- ---------------------------------------------------------------------------
local collapsed = {}

local function InitDB()
    if type(UncappedKeystoneDB) ~= "table" then UncappedKeystoneDB = {} end
    if type(UncappedKeystoneDB.collapsed) ~= "table" then
        UncappedKeystoneDB.collapsed = {}
    end
    collapsed = UncappedKeystoneDB.collapsed
end

InitDB()

local function IsCollapsed(key)
    return collapsed[key] ~= false
end

-- Session-only, deliberately NOT saved: see the auto-expand in HandleMessage.
local autoExpanded = false

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function Comma(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

-- Payouts here run from tens to tens of millions. A raw comma'd integer stops
-- being readable somewhere around seven digits, and the exact ones digit of a
-- 12-million Anima payout is not information anybody wants.
local function Abbrev(n)
    n = tonumber(n) or 0
    if n >= 1e9 then return string.format("%.2fB", n / 1e9) end
    if n >= 1e6 then return string.format("%.2fM", n / 1e6) end
    return Comma(n)
end

local function Send(msg)
    if not SendAddonMessage then return end
    SendAddonMessage(TRANSPORT_PREFIX, msg, "WHISPER", UnitName("player"))
end

local function Request()
    if pending then return end
    pending = true
    answered = false
    requestedAt = GetTime()
    Send("MRWQ")
end

--[[ ------------------------------------------------------------------------
     The KEY BONUS, exactly as the server computes it.

     ★★ LINEAR, NOT EXPONENTIAL. This was `2 ^ ((lvl-1) / per)` and the server
     went linear on 2026-08-14 with the progression reset. Nobody changed this
     copy, so the Reward Preview has been promising numbers the server stopped
     paying: at +21 it advertised 256x where the server pays 9x, a 28x
     over-promise, and 315x at +31.

     The server's own note on the constant (mythic_plus.cpp, GetRewardMultipliers)
     spells the table out and ends "that mistake has been made once already; do
     not make it again". It was made again, here, on the client side.

     ⚠ `tuning.doubleEvery` keeps its name for wire compatibility, but it is no
       longer a doubling period -- it is the number of keystone levels per +1.0x.
  -------------------------------------------------------------------------- ]]
local function KeyBonus(lvl)
    if not tuning then return 1 end
    local per = tuning.doubleEvery
    if not per or per <= 0 then per = 5 end
    return 1 + (math.max(lvl, 1) - 1) / per
end

local function FilteredMaps()
    if filter == "all" then return maps end
    local out = {}
    for _, m in ipairs(maps) do
        if (filter == "raid") == (m.raid) then out[#out + 1] = m end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Wire
-- ---------------------------------------------------------------------------
local function HandleMessage(msg)
    if msg == "MRWE" then
        pending = false
        answered = true
        -- Longest first is the useful default: the panel's whole argument is that
        -- size and depth both pay, and opening on the biggest instance makes the
        -- size half visible before the player touches anything.
        table.sort(maps, function(a, b)
            if a.size ~= b.size then return a.size > b.size end
            return (a.name or "") < (b.name or "")
        end)
        if not selected and #maps > 0 then selected = 1 end
        -- [#708] Everything starts collapsed, so the ONE group holding the
        -- auto-selected map is opened on the first sync of the session --
        -- otherwise the readout on the right describes a map that is nowhere
        -- on screen, which is a worse first impression than the jumble was.
        -- Once per session only: after that the player's own collapses are
        -- what the panel is for, and re-opening the biggest map's group on
        -- every tab visit would quietly undo them.
        if not autoExpanded and maps[selected] then
            autoExpanded = true
            collapsed[GroupKeyFor(maps[selected])] = false
        end
        if Keystone.Render then Keystone.Render() end
        return
    end

    local head = string.match(msg, "^MRWH:(.+)$")
    if head then
        local a, r, d, h = string.match(head, "^([%d%.%-]+):([%d%.%-]+):([%d%.%-]+):([%d%.%-]+)$")
        if a then
            tuning = {
                anchor      = tonumber(a) or 24,
                -- [#910] Offline fallbacks, only used if the server never sends a
                -- header. Both were stale: the anima rate was halved to 87.5 on
                -- 2026-08-15b and the hotzone multiplier is 5, not 2.
                animaRate   = tonumber(r) or 87.5,
                doubleEvery = tonumber(d) or 5,
                hotzone     = tonumber(h) or 5,
            }
            -- A fresh header means a fresh table; without this a second sync
            -- would append every map a second time.
            maps = {}
            selected = nil
            -- [#942] Cleared with the map table, not on MRWZ: a server that has
            -- no hotzones sends an EMPTY MRWZ, and a server too old to send MRWZ
            -- at all sends none. Both must end up with an empty set rather than
            -- with the previous sync's hotzones still marked.
            hotMaps = {}
        end
        return
    end

    -- [#942] MRWZ:<id>,<id>,... -- the maps that are hot right now. Its own
    -- message id on purpose: appending a field to MRWH or MRWM would break
    -- their anchored patterns on an un-updated client instead of degrading.
    local hot = string.match(msg, "^MRWZ:(.*)$")
    if hot then
        hotMaps = {}
        for id in string.gmatch(hot, "%d+") do
            hotMaps[tonumber(id)] = true
        end
        return
    end

    local body = string.match(msg, "^MRWM:(.+)$")
    if not body then return end

    for row in string.gmatch(body, "([^;]+)") do
        local id, size, raid, name = string.match(row, "^(%d+),([%d%.%-]+),(%d+),(.*)$")
        if id then
            maps[#maps + 1] = {
                id   = tonumber(id),
                size = tonumber(size) or 0,
                raid = (raid == "1"),
                name = name ~= "" and name or ("Map " .. id),
            }
        end
    end
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------
local ROW_H, ROWS = 16, 18

--[[ ------------------------------------------------------------------------
     [#708] The flat DISPLAY-ROW array: group headers and map rows interleaved,
     in the order they are painted.

     Flattening is what keeps the change contained. The FauxScrollFrame goes on
     counting rows exactly as it did, the 18 list buttons go on being 18 list
     buttons, and nothing outside this function has to learn that grouping
     exists -- a row is either a header or a map, and that is the whole model.

     ⚠ Sorted ALPHABETICALLY inside a group, but only in these throwaway
       buckets. `maps` itself keeps the size-descending sort MRWE applies,
       because `selected` is an index INTO `maps` and the default selection is
       "the biggest instance" -- re-sorting the real array would silently point
       the selection at a different map.
  -------------------------------------------------------------------------- ]]
local function BuildDisplayRows()
    local buckets = {}
    for _, m in ipairs(FilteredMaps()) do
        local key = GroupKeyFor(m)
        if not buckets[key] then buckets[key] = {} end
        buckets[key][#buckets[key] + 1] = m
    end

    local rows = {}
    for _, g in ipairs(GROUPS) do
        local bucket = buckets[g.key]
        -- No maps under the current filter means NO header -- otherwise the
        -- "Raids" filter shows three empty "... Dungeons" titles.
        if bucket and #bucket > 0 then
            rows[#rows + 1] = { header = true, key = g.key, label = g.label, count = #bucket }
            if not IsCollapsed(g.key) then
                table.sort(bucket, function(a, b) return (a.name or "") < (b.name or "") end)
                for _, m in ipairs(bucket) do
                    rows[#rows + 1] = { map = m }
                end
            end
        end
    end
    return rows
end

local function RenderList()
    if not listButtons then return end
    local rows = BuildDisplayRows()
    local offset = FauxScrollFrame_GetOffset(listScroll) or 0

    --[[ ⚠ CLAMP BEFORE THE FAUX UPDATE, NOT AFTER.

         Collapsing a group shortens the list, and a stale offset then scrolls
         past the end and paints eighteen empty rows.

         It is NOT enough to let FauxScrollFrame_Update's SetMinMaxValues clamp
         it for us: that fires the scrollbar's OnValueChanged, which re-enters
         RenderList through OnVerticalScroll, and when that inner render
         finishes the OUTER call carries on painting from its own stale local
         `offset` -- so the correct render is immediately overwritten by the
         wrong one. Clamping here means both renders agree.

         FauxScrollFrame_SetOffset only writes frame.offset (no scrollbar, no
         re-entry), so this is safe to call from inside the render.
      ]]
    local maxOffset = math.max(0, #rows - ROWS)
    if offset > maxOffset then
        offset = maxOffset
        FauxScrollFrame_SetOffset(listScroll, offset)
    end

    FauxScrollFrame_Update(listScroll, #rows, ROWS, ROW_H)

    for i = 1, ROWS do
        local btn = listButtons[i]
        local row = rows[i + offset]
        btn.text:ClearAllPoints()
        if row and row.header then
            -- [+] / [-] plus the label and how many maps are under it. The old
            -- dim "[R]" raid tag is gone: raids have their own sections now, so
            -- it only repeated the header once per row.
            btn.text:SetPoint("LEFT", 4, 0)
            btn.text:SetWidth(182)
            btn.text:SetText(string.format("%s[%s] %s|r %s(%d)|r",
                COLOR_HEAD, IsCollapsed(row.key) and "+" or "-", row.label,
                COLOR_DIM, row.count))
            btn.groupKey = row.key
            btn.mapRef = nil
            btn.hl:Hide()
            btn:Show()
        elseif row then
            local m = row.map
            local isSel = (maps[selected] == m)
            -- Indented, so a map reads as sitting UNDER its header rather than
            -- as another entry in the same column.
            btn.text:SetPoint("LEFT", 16, 0)
            btn.text:SetWidth(170)
            btn.text:SetText(string.format("%s%s|r",
                isSel and COLOR_VALUE or COLOR_LABEL, m.name))
            btn.groupKey = nil
            btn.mapRef = m
            btn:Show()
            if isSel then btn.hl:Show() else btn.hl:Hide() end
        else
            btn.text:SetPoint("LEFT", 4, 0)
            btn.groupKey = nil
            btn.mapRef = nil
            btn:Hide()
        end
    end
end

local function SetLine(key, text)
    if previewTexts[key] then previewTexts[key]:SetText(text) end
end

function Keystone.Render()
    if not frame then return end

    if levelText then
        levelText:SetText(string.format("%s+%d|r", COLOR_VALUE, level))
    end

    RenderList()

    if not tuning then
        SetLine("map", COLOR_DIM .. (answered and "No map data." or "Loading...") .. "|r")
        for _, k in ipairs({ "size", "bonus", "hot", "sacks", "anima", "note", "compare" }) do SetLine(k, "") end
        return
    end

    local m = maps[selected]
    if not m then
        SetLine("map", COLOR_DIM .. "Pick a dungeon or raid on the left.|r")
        for _, k in ipairs({ "size", "bonus", "hot", "sacks", "anima", "note", "compare" }) do SetLine(k, "") end
        return
    end

    local bonus = KeyBonus(level)
    --[[ [#942] The hotzone multiplies the SAME base the payout multiplies
         (mult.base = size x key x hotzone), so it belongs inside these two
         numbers rather than printed alongside them as an afterthought. The
         report was "SSC isn't getting the hotzone buff at all" from a player
         whose every SSC run recorded hotzone = 1 -- the buff applied, this
         panel just quoted a figure with no hotzone in it and was believed. ]]
    local hotMult = (m.id and hotMaps[m.id]) and (tuning.hotzone or 1) or 1
    local sacks = math.max(1, math.floor(tuning.anchor * m.size * bonus * hotMult + 0.5))
    local anima = math.max(1, math.floor(tuning.animaRate * m.size * bonus * hotMult + 0.5))

    SetLine("map", string.format("%s%s|r  %s", COLOR_HEAD, m.name,
        m.raid and (COLOR_DIM .. "(raid)|r") or (COLOR_DIM .. "(dungeon)|r")))

    SetLine("size", string.format("%sClear size|r    %s%.2f|r  %s(1.00 = one Utgarde Keep)|r",
        COLOR_LABEL, COLOR_VALUE, m.size, COLOR_DIM))
    -- "+1.0x every N levels", not "doubles" -- the curve is linear since the
    -- 2026-08-14 reset. See the note on KeyBonus above.
    SetLine("bonus", string.format("%sKey bonus|r     %sx%.1f|r  %s(+1.0x every %.1f levels)|r",
        COLOR_LABEL, COLOR_VALUE, bonus, COLOR_DIM, tuning.doubleEvery))

    -- Says "already counted" out loud. A multiplier printed next to a total is
    -- ambiguous about whether the total includes it, and guessing wrong in
    -- either direction produces a reward report.
    if hotMult > 1 then
        SetLine("hot", string.format("%sHOTZONE|r       %sx%g|r  %s(live now -- already in the numbers below)|r",
            COLOR_GOOD, COLOR_VALUE, hotMult, COLOR_DIM))
    else
        SetLine("hot", "")
    end

    SetLine("sacks", string.format("%sSacks|r         %s%s|r", COLOR_LABEL, COLOR_GOOD, Abbrev(sacks)))
    -- [#910] SoulRush no longer affects Anima -- SoulRush.ArenaPctPerClear has been 0
    -- since the 2026-08-14 reset, so ArenaMultiplier returns exactly 1.0 and this line
    -- was naming a bonus that does not exist. The reporter spotted that himself.
    SetLine("anima", string.format("%sAnima|r         %s%s|r  %s(before your quest bonus)|r",
        COLOR_LABEL, COLOR_GOOD, Abbrev(anima), COLOR_DIM))

    -- The comparison IS the feature. A number on its own does not tell anyone
    -- whether pushing is worth it; "x4.0 what a +10 pays" does.
    local ref = 10
    if level ~= ref then
        local refBonus = KeyBonus(ref)
        SetLine("compare", string.format("%sThat is x%.1f what a +%d on this map pays.|r",
            COLOR_HEAD, bonus / refBonus, ref))
    else
        SetLine("compare", COLOR_DIM .. "Move the key up and down to compare.|r")
    end

    SetLine("note", COLOR_DIM ..
        "Estimate for a full clear (required trash + every boss). Clear more, earn more.|r")
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
local function StepLevel(delta)
    level = math.max(1, math.min(200, level + delta))
    Keystone.Render()
end

--[[ ------------------------------------------------------------------------
     ⚠ USE THE HOUSE WIDGET KIT, NOT UIPanelButtonTemplate.

     This is the same note UncappedKeystoneRun.lua carries, and it is here
     because this file did not follow it. The sub-tab strip below already builds
     through UncappedUIKit; the filter row did not, so All / Dungeons / Raids
     rendered as red Blizzard buttons in the middle of a panel where every other
     control is UncappedUI. That template also draws a border wider than the
     width you set, so a row spaced for its logical width collides once it
     renders.

     ★ The fallback is deliberate and must stay: UncappedUI is a separate addon
       in the payload, and if a player has it disabled this panel degrades to
       plain buttons instead of erroring on a nil global. Ugly beats broken.
  -------------------------------------------------------------------------- ]]
local function MakeButton(parent, label, w, onClick)
    local b
    if UncappedUIKit and UncappedUIKit.CreateButton then
        b = UncappedUIKit.CreateButton(parent, label, w, 22)
    else
        b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        b:SetWidth(w)
        b:SetHeight(22)
        b:SetText(label)
    end
    b:SetScript("OnClick", onClick)
    return b
end

local function BuildFrame(parent)
    if frame then
        frame:SetParent(parent)
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", 0, 0)
        frame:SetPoint("BOTTOMRIGHT", 0, 0)
        return frame
    end

    frame = CreateFrame("Frame", "UncappedKeystoneFrame", parent)
    frame:SetPoint("TOPLEFT", 0, 0)
    frame:SetPoint("BOTTOMRIGHT", 0, 0)

    --[[ ----------------------------------------------------------------------
         SUB-TABS -- and why Mythic+ gets exactly ONE dashboard tab.

         Owner ruling 2026-08-12: the whole keystone system moves into the
         Dashboard. It cannot move as four tabs. UncappedDashboardConfig.lua
         documents the nav column's budget: 15 tabs today, ONE slot left, 17
         clips off the bottom of the window -- and the 16th alone drops the
         window's zoom ceiling to ~1.01 for everyone, because REQUIRED_HEIGHT is
         in window units and the player's zoom multiplies it.

         So everything M+ lives behind this strip instead: Your Keystone, Reward
         Preview, and later Affixes / History / Leaderboard. Costs zero nav slots
         and leaves the zoom ceiling where it is.

         ★ ADD SECTIONS HERE, NOT TO Core.TABS.
      ------------------------------------------------------------------------ ]]
    local SUBTAB_H = 26

    local sections, subButtons = {}, {}
    local activeSection

    -- Forward-declared so the buttons can call it before the sections table is
    -- populated at the bottom of this function.
    local ShowSection

    local strip = CreateFrame("Frame", nil, frame)
    strip:SetPoint("TOPLEFT", 0, 0)
    strip:SetPoint("TOPRIGHT", 0, 0)
    strip:SetHeight(SUBTAB_H)

    local SUBTABS = {
        { key = "keystone", label = "Your Keystone" },
        { key = "lfg",      label = "Group Finder" },   -- [#605]
        { key = "rewards",  label = "Reward Preview" },
    }

    --[[
        ⚠ HOUSE WIDGET KIT, NOT UIPanelButtonTemplate.

        These started as raw Blizzard buttons and looked like it -- red and boxy
        against a Dashboard where every other control is UncappedUI. The kit also
        gives a proper SELECTED state (SetButtonActive), which a tab strip needs
        and the Blizzard template does not have.

        ★ Fallback kept on purpose: UncappedUI is a separate addon in the payload.
          With it disabled this degrades to plain buttons rather than erroring on a
          nil global, on the Dashboard's most-used tab.
    ]]
    local sx = 8
    for _, spec in ipairs(SUBTABS) do
        local w = max(104, strlen(spec.label) * 9)
        local b
        if UncappedUIKit and UncappedUIKit.CreateButton then
            b = UncappedUIKit.CreateButton(strip, spec.label, w, 22)
        else
            b = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
            b:SetWidth(w)
            b:SetHeight(22)
            b:SetText(spec.label)
        end
        b:SetPoint("TOPLEFT", sx, -2)
        b:SetScript("OnClick", function() ShowSection(spec.key) end)
        subButtons[spec.key] = b
        sx = sx + w + 8   -- +8, not +4: the old gap let the labels crowd together
    end

    -- Shows one section and hides the rest. A section is just a list of regions,
    -- so a FontString parented straight to `frame` is as hideable as a Frame is --
    -- which matters because the reward preview's heading and formula line are
    -- exactly that.
    ShowSection = function(key)
        if not sections[key] then return end
        activeSection = key

        for k, parts in pairs(sections) do
            local on = (k == key)
            for _, region in ipairs(parts) do
                if region then
                    if on then region:Show() else region:Hide() end
                end
            end
            -- Selected state via the kit (the gold "current tab" look). Disable()
            -- was the first attempt and it just greys the label out, which reads
            -- as "this tab is unavailable" rather than "you are on this tab".
            if subButtons[k] then
                if UncappedUIKit and UncappedUIKit.SetButtonActive then
                    UncappedUIKit.SetButtonActive(subButtons[k], on)
                elseif on then
                    subButtons[k]:Disable()
                else
                    subButtons[k]:Enable()
                end
            end
        end

        -- Let a section refresh itself as it comes into view, so switching to it
        -- never shows a stale number.
        if key == "keystone" and _G.UncappedKeystoneRun and _G.UncappedKeystoneRun.UI then
            _G.UncappedKeystoneRun.UI.Activate()
        elseif key == "lfg" and _G.UncappedLFG and _G.UncappedLFG.UI then
            _G.UncappedLFG.UI.Activate()
        elseif key == "rewards" then
            Keystone.Render()
            Request()
        end
    end
    Keystone.ShowSection = function(key) if ShowSection then ShowSection(key) end end
    Keystone.CurrentSection = function() return activeSection or "keystone" end

    --[[ ----------------------------------------------------------------------
         ★ EVERY rewards-only region is parented HERE, not to `frame` (#895).

         Hiding this section is then hiding ONE frame, so a region can never be
         left out of a hand-maintained list again -- which is exactly what #895
         was. The three filter buttons and the status line hung off `frame` and
         were never added to sections["rewards"], so ShowSection() could not hide
         them and they stayed painted on top of whichever sub-tab you were
         actually looking at. The default sub-tab is `keystone`, so the very
         first thing a player saw was the run panel's "Keystone level" and "Best
         clear" lines sitting underneath the All / Dungeons / Raids row.

         ⚠ If you add a rewards-only widget, parent it to `body`. If you parent
         it to `frame` it will bleed onto the other sub-tabs and nothing will
         warn you.
      ------------------------------------------------------------------------ ]]
    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", 0, -SUBTAB_H)
    body:SetPoint("BOTTOMRIGHT", 0, 0)

    local title = body:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 8, -6)
    title:SetText("Mythic+ Reward Preview")

    local formula = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    formula:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    formula:SetText(COLOR_DIM .. "reward = clear size x key bonus|r")

    -- ---- left: map list ----
    local listBg = CreateFrame("Frame", nil, body)
    -- Anchored below, once the filter row exists, so the gap is derived from the
    -- row rather than hand-computed. The old value was a literal -28 == 22px of
    -- button + 2 + 4 slack, which silently ate the list the moment a label got
    -- wider or a fourth filter appeared.
    listBg:SetWidth(210)
    listBg:SetHeight(ROWS * ROW_H + 8)

    local filterAll, filterDun, filterRaid
    -- Which filter is on was previously not drawn at all -- the three buttons
    -- looked identical whichever one you had picked, so the only way to know was
    -- to read the list and infer it. The kit has an active state for exactly
    -- this ("filter chips" in Controls/Button.lua), so use it.
    local function PaintFilters()
        if not (UncappedUIKit and UncappedUIKit.SetButtonActive) then return end
        UncappedUIKit.SetButtonActive(filterAll,  filter == "all")
        UncappedUIKit.SetButtonActive(filterDun,  filter == "dungeon")
        UncappedUIKit.SetButtonActive(filterRaid, filter == "raid")
    end
    local function SetFilter(f)
        filter = f
        PaintFilters()
        FauxScrollFrame_SetOffset(listScroll, 0)
        -- ⚠ THE GLOBAL, NOT A FIELD. FauxScrollFrameTemplate exposes its
        --   scrollbar as _G["<frameName>ScrollBar"]; there is no `.ScrollBar`
        --   member on the scroll frame, so the old `if listScroll.ScrollBar`
        --   was always false and this line had never once fired. The offset
        --   above was reset while the scrollbar thumb stayed where it was.
        local sb = _G["UncappedKeystoneListScrollBar"]
        if sb then sb:SetValue(0) end
        Keystone.Render()
    end
    filterAll  = MakeButton(body, "All", 56, function() SetFilter("all") end)
    filterDun  = MakeButton(body, "Dungeons", 76, function() SetFilter("dungeon") end)
    filterRaid = MakeButton(body, "Raids", 60, function() SetFilter("raid") end)
    filterAll:SetPoint("TOPLEFT", formula, "BOTTOMLEFT", 0, -6)
    filterDun:SetPoint("LEFT", filterAll, "RIGHT", 2, 0)
    filterRaid:SetPoint("LEFT", filterDun, "RIGHT", 2, 0)

    -- The list hangs off the FILTER ROW, so a taller or wider row pushes it down
    -- instead of overlapping it. See the note at listBg's creation.
    listBg:SetPoint("TOPLEFT", filterAll, "BOTTOMLEFT", 0, -6)

    -- Paint the starting selection, or the panel opens with nothing lit.
    PaintFilters()

    listScroll = CreateFrame("ScrollFrame", "UncappedKeystoneList", listBg, "FauxScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", 0, -4)
    listScroll:SetWidth(190)
    listScroll:SetHeight(ROWS * ROW_H)
    listScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, RenderList)
    end)

    listButtons = {}
    for i = 1, ROWS do
        local b = CreateFrame("Button", nil, listBg)
        b:SetWidth(188)
        b:SetHeight(ROW_H)
        if i == 1 then
            b:SetPoint("TOPLEFT", listScroll, "TOPLEFT", 0, 0)
        else
            b:SetPoint("TOPLEFT", listButtons[i - 1], "BOTTOMLEFT", 0, 0)
        end

        local hl = b:CreateTexture(nil, "BACKGROUND")
        hl:SetAllPoints(b)
        hl:SetTexture(0.35, 0.28, 0.62, 0.55)
        hl:Hide()
        b.hl = hl

        local t = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        t:SetPoint("LEFT", 4, 0)
        t:SetJustifyH("LEFT")
        t:SetWidth(180)
        b.text = t

        b:SetScript("OnClick", function(self)
            -- A header row toggles its group and repaints; it never touches the
            -- selection, so collapsing the group you are reading does not throw
            -- away the readout on the right.
            if self.groupKey then
                -- ⚠ Written out rather than as `a and false or nil`: that idiom
                --   collapses to nil for BOTH branches, because `true and false`
                --   is false and `false or nil` is nil. Storing nil for the
                --   collapsed case is deliberate -- nil IS collapsed (see
                --   IsCollapsed), so the saved table only ever holds the groups
                --   the player deliberately opened.
                if IsCollapsed(self.groupKey) then
                    collapsed[self.groupKey] = false
                else
                    collapsed[self.groupKey] = nil
                end
                RenderList()
                return
            end
            if not self.mapRef then return end
            for idx, m in ipairs(maps) do
                if m == self.mapRef then selected = idx; break end
            end
            Keystone.Render()
        end)
        listButtons[i] = b
    end

    -- ---- right: the stepper and the readout ----
    local right = CreateFrame("Frame", nil, body)
    right:SetPoint("TOPLEFT", listBg, "TOPRIGHT", 18, 0)
    right:SetPoint("BOTTOMRIGHT", -8, 8)

    --[[ ----------------------------------------------------------------------
         Register the two sections, then open on the keystone.

         `keystone` is the default deliberately: managing and STARTING a key is
         what people came for once the item is gone, and the reward preview is
         the thing you consult occasionally. It is also the section that answers
         reports #655 and #657.

         The run panel lives in its own file so this one keeps doing one job.
         Guarded because the two ship as separate files in the same payload and a
         partial install must degrade to "the preview still works", not to a Lua
         error on the Dashboard's most-used tab.
      ------------------------------------------------------------------------ ]]
    -- ONE region (#895). Everything rewards-only is parented to `body`, so this
    -- list cannot go stale the way the old
    --     { title, formula, listBg, right }
    -- did -- it silently omitted the three filter buttons and statusText.
    sections["rewards"] = { body }

    if _G.UncappedKeystoneRun and _G.UncappedKeystoneRun.UI then
        local runFrame = _G.UncappedKeystoneRun.UI.EmbedInto(frame)
        if runFrame then
            -- EmbedInto anchors to fill its parent; re-anchor under the strip so
            -- the sub-tabs stay clickable.
            runFrame:ClearAllPoints()
            runFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -SUBTAB_H)
            runFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
            sections["keystone"] = { runFrame }
        end
    end

    -- [#605] The Group Finder, embedded exactly like the run panel above and
    -- guarded for the same reason: the two ship as separate files in one payload,
    -- and a partial install must degrade to "the other tabs still work".
    if _G.UncappedLFG and _G.UncappedLFG.UI then
        local lfgFrame = _G.UncappedLFG.UI.EmbedInto(frame)
        if lfgFrame then
            lfgFrame:ClearAllPoints()
            lfgFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -SUBTAB_H)
            lfgFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
            sections["lfg"] = { lfgFrame }
        end
    end

    if not sections["lfg"] then
        -- Same rule as the keystone sub-tab: a button that does nothing when
        -- pressed is worse than no button.
        if subButtons["lfg"] then subButtons["lfg"]:Hide() end
    end

    if not sections["keystone"] then
        -- No run panel in this install: drop its sub-tab rather than leaving a
        -- button that does nothing when pressed.
        if subButtons["keystone"] then subButtons["keystone"]:Hide() end
        ShowSection("rewards")
    else
        ShowSection("keystone")
    end

    local keyLabel = right:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    keyLabel:SetPoint("TOPLEFT", 0, 0)
    keyLabel:SetText("Keystone level")

    local minus10 = MakeButton(right, "-10", 40, function() StepLevel(-10) end)
    local minus1  = MakeButton(right, "-", 28, function() StepLevel(-1) end)
    local plus1   = MakeButton(right, "+", 28, function() StepLevel(1) end)
    local plus10  = MakeButton(right, "+10", 40, function() StepLevel(10) end)

    minus10:SetPoint("TOPLEFT", keyLabel, "BOTTOMLEFT", 0, -6)
    minus1:SetPoint("LEFT", minus10, "RIGHT", 3, 0)

    levelText = right:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    levelText:SetPoint("LEFT", minus1, "RIGHT", 10, 0)
    levelText:SetWidth(56)
    levelText:SetJustifyH("CENTER")

    plus1:SetPoint("LEFT", levelText, "RIGHT", 10, 0)
    plus10:SetPoint("LEFT", plus1, "RIGHT", 3, 0)

    local order = { "map", "size", "bonus", "hot", "sacks", "anima", "compare", "note" }
    local anchor = minus10
    local gaps = { map = -16, size = -10, bonus = -2, hot = -8, sacks = -12, anima = -2, compare = -14, note = -8 }
    for _, key in ipairs(order) do
        local style = (key == "map") and "GameFontNormalLarge" or "GameFontHighlightSmall"
        local fs = right:CreateFontString(nil, "OVERLAY", style)
        fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, gaps[key])
        fs:SetJustifyH("LEFT")
        fs:SetWidth(340)
        previewTexts[key] = fs
        anchor = fs
    end

    -- `body`, not `frame` (#895): parented to the tab it would otherwise print
    -- its "no reward preview yet" line across every sub-tab from.
    statusText = body:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    statusText:SetPoint("BOTTOMLEFT", 8, 6)

    -- Timeout watcher. One unanswered request is enough to know this server has
    -- no MRWQ handler; re-opening the tab is the manual retry.
    frame:SetScript("OnUpdate", function()
        if pending and (GetTime() - requestedAt) > REPLY_TIMEOUT then
            pending = false
            answered = true
            if statusText then
                statusText:SetText("The server did not answer -- this realm build has no reward preview yet.")
            end
            Keystone.Render()
        end
    end)

    return frame
end

-- ---------------------------------------------------------------------------
-- Dashboard embedding
-- ---------------------------------------------------------------------------
function Keystone.UI.EmbedInto(parent)
    BuildFrame(parent)
    frame:Show()
    return frame
end

function Keystone.UI.Activate()
    if not frame then return end

    -- Refresh whichever SECTION is open rather than always the reward preview.
    -- ShowSection already knows how to bring a section up to date, so re-showing
    -- the current one is both the refresh and the guarantee that the strip's
    -- enabled/disabled states match what is on screen.
    if Keystone.ShowSection and Keystone.CurrentSection then
        Keystone.ShowSection(Keystone.CurrentSection())
        return
    end

    Keystone.Render()   -- paint from cache first
    Request()           -- then refresh
end

-- List 210 + gap 18 + the readout's 340 + padding on both sides.
function Keystone.UI.GetMinWidth()
    return 210 + 18 + 340 + 30
end

function Keystone.UI.GetMinHeight()
    return 40 + (ROWS * ROW_H) + 40 + 72
end

-- ---------------------------------------------------------------------------
-- Events / slash
-- ---------------------------------------------------------------------------
local comms = CreateFrame("Frame")
comms:RegisterEvent("CHAT_MSG_ADDON")
comms:RegisterEvent("ADDON_LOADED")
comms:SetScript("OnEvent", function(self, event, a1, a2)
    event = event or _G.event
    a1 = a1 or _G.arg1
    a2 = a2 or _G.arg2

    if event == "ADDON_LOADED" then
        -- ⚠ "UncappedDashboard", not "UncappedKeystone": this file SHIPS INSIDE
        --   the Dashboard and is not an addon in its own right, so that is the
        --   addon whose SavedVariables load.
        --
        -- ⚠ And it must re-run at all: the main chunk's InitDB() above runs
        --   BEFORE SavedVariables are loaded, so without this `collapsed` stays
        --   pointed at the throwaway table it built and every group the player
        --   opens is silently forgotten at logout.
        if a1 == "UncappedDashboard" then
            InitDB()
            RenderList()
        end
        return
    end

    if event ~= "CHAT_MSG_ADDON" then return end
    if a1 ~= ADDON_PIPE_PREFIX or not a2 then return end
    -- "MRW" is this panel's own three-letter space on the shared pipe.
    if string.sub(a2, 1, 3) ~= "MRW" then return end
    HandleMessage(a2)
end)

local function OpenInDashboard()
    local Dashboard = _G.UncappedDashboard
    if not Dashboard then
        DEFAULT_CHAT_FRAME:AddMessage(COLOR_HEAD .. "[M+ Rewards]|r lives inside the Dashboard -- load UncappedDashboard to use it.")
        return
    end
    Dashboard.SetTab("keystone")
    if not (Dashboard.UI and Dashboard.UI.IsShown and Dashboard.UI.IsShown()) then
        Dashboard.Toggle()
    end
end

SLASH_UNCAPPEDKEYSTONE1 = "/keystone"
SLASH_UNCAPPEDKEYSTONE2 = "/ukeystone"
SlashCmdList["UNCAPPEDKEYSTONE"] = function(arg)
    arg = string.lower(arg or "")
    arg = string.gsub(arg, "^%s+", "")
    if arg == "sync" then
        pending = false
        Request()
        DEFAULT_CHAT_FRAME:AddMessage(COLOR_HEAD .. "[M+ Rewards]|r refreshing...")
        return
    end
    OpenInDashboard()
end
