-- UncappedPrestige
--
-- The Dashboard's "Prestige" tab: the profession prestige ladder, per
-- profession, with the one thing neither the chat line nor `.prestige` shows --
-- PROGRESS. The ladder doubles every level, so "how far off am I" is the only
-- question a crafter actually has, and until this panel there was nowhere to
-- read it.
--
-- ★★ THE ONE THING THIS PANEL EXISTS TO GET RIGHT: A PRESTIGE LEVEL MEANS THREE
--    DIFFERENT THINGS, AND EVERY CARD MUST SAY WHICH
--
--    Enchanting / Tailoring / Leatherworking / Engineering / Inscription
--        enchant magnitude (1.1^P) AND extra crafted items. Enchanting also has
--        weapon procs, which scale on how OFTEN they fire and how HARD they hit.
--    Alchemy / Blacksmithing / Jewelcrafting
--        extra crafted items only. ⚠ Blacksmithing CANNOT get the enchant half:
--        measured against the client DBCs, none of its 525 recipes carries an
--        enchant effect, and every chain, spike, stone and buckle is stackable
--        so no crafter can be recorded on one. NOTHING HERE MAY IMPLY OTHERWISE.
--    Herbalism / Mining / Skinning
--        a bigger haul (1.1^P) and a better shot at rare materials. Mining also
--        gets the extra-item bonus, on smelting.
--
--    Telling a miner "your enchants are 46% stronger" is a real bug that shipped
--    in the level-up chat line and was fixed on 2026-08-10. It is not
--    reintroduced here, and the way it is kept out is structural rather than
--    careful: THIS ADDON HOLDS NO LIST OF WHICH PROFESSION GETS WHAT. The server
--    sends a flags field per profession, derived at startup from
--    SkillLineAbility.dbc by the same test the scaling reader itself applies,
--    and every sentence below is gated on those flags. A profession with no
--    enchant recipes physically cannot render an enchant sentence.
--
-- EVERYTHING NUMERIC IS SERVER-AUTHORITATIVE. The percentages, the level, the
-- ladder costs and the next-level preview all come off the wire already
-- derived, computed by ProfessionPrestige/ProfessionYield's own functions --
-- the ones the gameplay paths call. Retuning ProfessionYield.* in
-- worldserver.conf moves what this panel says, with no addon change. Same rule
-- the Anima and Progress tabs follow.
--
-- ⚠ DEGRADE, NEVER ERROR. This module ships in a payload release, so the first
--   time it ever runs is on a live player's client against whatever server build
--   is up. An older server that has never heard of PRSGET simply never replies,
--   and the panel says so after a timeout rather than sitting on "Waiting..."
--   forever or throwing. Every frame lookup is guarded, every wire field is
--   defaulted, and the two cosmetic lookup tables below fall back rather than
--   fail.
--
-- Wire format is documented server-side in
-- src/server/scripts/Custom/prestige_comms_playerscript.cpp.
--
-- 3.3.5a client: no BackdropTemplate, no C_Timer (hence the OnUpdate timeout),
-- arg1..argN globals on some event paths, and GetSpellInfo(id) is the only
-- reliable icon source -- which is exactly how the profession icons below are
-- fetched.
--
--   /prestige        open it (switches the Dashboard to the Prestige tab)
--   /prestige sync   force a refresh

local ADDON_PIPE_PREFIX = "UNC"          -- server -> client (replies arrive here)
local TRANSPORT_PREFIX  = "REAGENTBANK"  -- client -> server (shared addon transport)

-- How long to wait before declaring the server doesn't answer. Not a retry
-- timer: one unanswered request is enough to know this build has no PRSGET
-- handler, and hammering it would be pointless traffic. Re-opening the tab asks
-- again, which is the manual retry.
local REPLY_TIMEOUT = 6.0

local COLOR_HEAD  = "|cff9CC243"   -- section headings (the StatFeed green)
local COLOR_LABEL = "|cffffffff"
local COLOR_VALUE = "|cffffff00"
local COLOR_DIM   = "|cff888888"
local COLOR_GOOD  = "|cff1eff00"
local COLOR_WARN  = "|cffff6060"

-- Payout flags, as sent in PRSROW field 2. Kept in step with
-- PrestigePayoutFlags in prestige_comms_playerscript.cpp.
local F_ENCHANT = 1
local F_PROC    = 2
local F_CRAFT   = 4
local F_GATHER  = 8
local F_RARE    = 16

-- ---------------------------------------------------------------------------
-- ★ COSMETIC LOOKUPS ONLY -- READ THIS BEFORE ADDING TO EITHER TABLE.
--
-- Neither of these decides ANYTHING. They add an icon and a noun to a card
-- whose every number, and every claim about what prestige pays, arrived from
-- the server. A skill id missing from either one renders a question-mark icon
-- and a generic noun -- dull, never wrong -- which is the same "degrade to a
-- dull label" rule the Progress tab's WING_NAMES follows.
--
-- The icons come from each profession's apprentice spell, because GetSpellInfo
-- is the only reliable icon source on 3.3.5a. If a spell id is ever wrong the
-- texture simply comes back nil and the fallback is used.
-- ---------------------------------------------------------------------------
local PROFESSION_SPELL = {
    [164] = 2018,     -- Blacksmithing
    [165] = 2108,     -- Leatherworking
    [171] = 2259,     -- Alchemy
    [182] = 2366,     -- Herbalism
    [186] = 2575,     -- Mining
    [197] = 3908,     -- Tailoring
    [202] = 4036,     -- Engineering
    [333] = 7411,     -- Enchanting
    [393] = 8613,     -- Skinning
    [755] = 25229,    -- Jewelcrafting
    [773] = 45357,    -- Inscription
}
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- What a "node" is called for each gathering profession, and what its rare
-- materials look like, so the gathering sentences read like a person wrote them
-- instead of like a stat block. `nil` for anything unlisted -> the generic form.
--
-- ⚠ `rare` STARTS A SENTENCE. Keep every one of them capitalised -- a smoke run
-- caught "the rare gems in a vein are +10% more likely." reading as a fragment.
local GATHER_WORDS = {
    [182] = { node = "herb you pick",   rare = "Frost Lotus and the other rare herbs" },
    [186] = { node = "vein you mine",   rare = "The rare gems in a vein" },
    [393] = { node = "corpse you skin", rare = "Rare leathers and furs" },
}

-- Which professions' enchants a player would recognise, for the card tooltip.
-- Purely flavour: the card's enchant SENTENCE is gated on the server's flag,
-- never on this table, so an unlisted profession that gains enchant recipes
-- still says the true thing -- just without the examples.
local ENCHANT_EXAMPLES = {
    [165] = "fur linings and leg reinforcements",
    [197] = "embroideries and spellthreads",
    [202] = "tinkers",
    [333] = "every enchant you cast on your own or a trade partner's gear",
    [773] = "shoulder inscriptions",
}

-- ---------------------------------------------------------------------------
-- State. Rebuilt wholesale from each burst -- there is no incremental update, so
-- a dropped line can never leave a stale card behind. `pending` is the burst
-- being assembled and is swapped into `state` only on PRSEND, so the panel never
-- paints a half-arrived block.
-- ---------------------------------------------------------------------------
local function NewState()
    return {
        received       = false,
        enabled        = true,
        yieldEnabled   = true,
        craftsPerLevel = 0,
        maxLevel       = 0,
        craftPctPerLevel = 0,
        gatherCredit   = 1,
        rows           = {},
    }
end

local state    = NewState()
local pending  = nil
local requested = false      -- a PRSGET is in flight
local waited   = 0           -- seconds since it went out
local timedOut = false

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------
local PAD    = 18
local ROW_H  = 14
local CARD_W = 470
local CARD_H = 92            -- stride; the card frame itself is a little shorter
local MAX_CARDS = 14         -- pool ceiling: eleven professions today, headroom
local STATUS_RESERVE = 34    -- space kept clear at the bottom for the status line

local frame, listScroll, statusText
local lines = {}             -- pooled font strings for the header block
local cards = {}             -- pooled profession cards
local listTop = 0            -- y offset the card list was last anchored at

-- ---------------------------------------------------------------------------
-- Formatting helpers
-- ---------------------------------------------------------------------------

-- Thousands separators. 3.3.5a has no built-in, and the top of the ladder is
-- 500 * 2^21 -- a ten-digit number that is unreadable unbroken.
local function Comma(n)
    n = tostring(math.floor(tonumber(n) or 0))
    local out = n
    while true do
        local replaced
        out, replaced = string.gsub(out, "^(-?%d+)(%d%d%d)", "%1,%2")
        if replaced == 0 then break end
    end
    return out
end

-- Bit test without the bit library. `bit.band` does exist on 3.3.5a, but this
-- panel has no other dependency on it and arithmetic cannot be missing.
local function HasFlag(flags, mask)
    flags = tonumber(flags) or 0
    return math.floor(flags / mask) % 2 == 1
end

local function Plural(n, one, many)
    return n == 1 and one or many
end

-- Hundredths of a percent -> a readable percentage, with trailing zeroes trimmed
-- so 25 reads "0.25", 500 reads "5" and 250 reads "2.5" rather than "2.50".
--
-- ⚠ The server sends this unit because the wire is integer-only (`%d+`); at the
-- shipped 0.25%/level, whole percent would round the first three prestige levels
-- to zero and tenths would still be 20% off at prestige 1.
local function FormatHundredths(v)
    v = tonumber(v) or 0
    if v % 100 == 0 then
        return string.format("%d", v / 100)
    elseif v % 10 == 0 then
        return string.format("%.1f", v / 100)
    end
    return string.format("%.2f", v / 100)
end

-- ---------------------------------------------------------------------------
-- The sentences.
--
-- ★★ EVERY ONE OF THESE IS GATED ON A SERVER FLAG. Do not add a branch that
--    tests a skill id -- that is exactly how the "your enchants are 46%
--    stronger" bug reached a miner, and the whole shape of this protocol exists
--    to make the mistake unavailable rather than merely discouraged.
--
-- Returns at most three lines, which is the worst case by construction:
-- Enchanting (enchant + procs + crafting) and Mining (crafting + gathering +
-- rare) are the two professions that reach three, and nothing reaches four. The
-- card's fixed height depends on that. If a fourth payout is ever added, raise
-- CARD_H and the pay-line pool together.
-- ---------------------------------------------------------------------------
local function PayoutLines(d)
    local out = {}

    local function add(text)
        if #out < 3 then out[#out + 1] = text end
    end

    if HasFlag(d.flags, F_ENCHANT) and d.multPct > 0 then
        add(string.format("Enchants you cast land %s+%d%%|r stronger.", COLOR_VALUE, d.multPct))
        if HasFlag(d.flags, F_PROC) then
            add("Weapon procs fire more often AND hit harder.")
        end
    end

    -- ★ craftPct arrives in HUNDREDTHS of a percent (25 = 0.25%). The server cannot
    -- send a decimal: this whole line is matched with `%d+`, and "0.25" fails the
    -- match and silently zeroes the entire config. See prestige_comms_playerscript.
    --
    -- ⚠ It used to be whole percent AND it meant something else -- extra copies of
    -- whatever you crafted. That payout was removed on 2026-08-15 (it compounded
    -- across crafting chains and was being melted back into materials); a craft now
    -- renders Soulforge food instead. REQUIRED_CLIENT_VERSION was bumped with it, so
    -- an addon this old cannot be connected and reading 25 as "25%".
    if HasFlag(d.flags, F_CRAFT) and d.craftPct > 0 then
        add(string.format("A %s%s%%|r chance to render Soulforge food on every craft.",
            COLOR_VALUE, FormatHundredths(d.craftPct)))
    end

    if HasFlag(d.flags, F_GATHER) and d.gatherPct > 0 then
        local words = GATHER_WORDS[d.skillId]
        add(string.format("You get %s+%d%%|r more from every %s.",
            COLOR_VALUE, d.gatherPct, words and words.node or "node"))
    end

    if HasFlag(d.flags, F_RARE) and d.rarePct > 0 then
        local words = GATHER_WORDS[d.skillId]
        add(string.format("%s are %s+%d%%|r more likely.",
            words and words.rare or "Rare materials", COLOR_VALUE, d.rarePct))
    end

    return out
end

-- The "and here is what the next one buys you" line. At prestige 0 this is the
-- ONLY thing on the card that says anything -- and with the prestige table empty
-- realm-wide, that is the screen every player sees on day one, so it carries the
-- whole pitch rather than being a footnote.
local function NextLine(d)
    if d.nextAt <= 0 then
        return COLOR_GOOD .. "Top of the ladder -- nothing left to climb.|r"
    end

    local togo = d.nextAt - d.crafts
    if togo < 0 then togo = 0 end

    local parts = {}
    if HasFlag(d.flags, F_ENCHANT) and d.nextMultPct > 0 then
        parts[#parts + 1] = string.format("enchants +%d%%", d.nextMultPct)
    end
    if HasFlag(d.flags, F_CRAFT) and d.nextCraftPct > 0 then
        parts[#parts + 1] = string.format("soul food %s%%", FormatHundredths(d.nextCraftPct))
    end
    -- nextGatherPct is 0 when the server refused to preview it (the realm has
    -- overridden or capped the gathering curve, and it is then not computable
    -- from outside). Printing nothing beats printing a guess.
    if HasFlag(d.flags, F_GATHER) and d.nextGatherPct > 0 then
        parts[#parts + 1] = string.format("gathering +%d%%", d.nextGatherPct)
    end

    if #parts == 0 then
        return string.format("%sPrestige %d in %s more crafts.|r", COLOR_DIM, d.level + 1, Comma(togo))
    end

    return string.format("%sPrestige %d in %s more crafts:|r %s%s.|r",
        COLOR_DIM, d.level + 1, Comma(togo), COLOR_HEAD, table.concat(parts, ", "))
end

-- ---------------------------------------------------------------------------
-- Comms
-- ---------------------------------------------------------------------------
local function Send(msg)
    SendAddonMessage(TRANSPORT_PREFIX, msg, "WHISPER", UnitName("player"))
end

local Render   -- forward declaration; defined below, used by the comms handler

local function Request()
    -- Don't reset `state` -- the panel keeps rendering the last good burst while
    -- a new one is in flight, which is what makes re-opening the tab feel
    -- instant.
    pending   = nil
    requested = true
    waited    = 0
    timedOut  = false
    Send("PRSGET")
end

-- Opens (or reuses) the accumulator for the burst currently arriving. The first
-- line of a burst opens a fresh one, so a second request while one is landing
-- replaces the old burst rather than merging with it.
local function Staging()
    if not pending then pending = NewState() end
    return pending
end

-- Presentation order, and only presentation: the server sends rows in skill-id
-- order, which is meaningless to a player. What a player wants first is the
-- profession they have actually invested in, so: professions this character
-- actually has, then highest prestige, then most crafts, then alphabetical.
-- Sorting here rather than server-side keeps the server's job to facts.
local function SortRows(rows)
    table.sort(rows, function(a, b)
        local aHas = (a.skillValue or 0) > 0
        local bHas = (b.skillValue or 0) > 0
        if aHas ~= bHas then return aHas end
        if a.level ~= b.level then return a.level > b.level end
        if a.crafts ~= b.crafts then return a.crafts > b.crafts end
        return (a.name or "") < (b.name or "")
    end)
end

local function HandleMessage(text)
    -- PRSERR means the server heard us and declined (throttle). Deliberately NOT
    -- treated as "no reply": the whole point of answering a throttled request is
    -- that the client can tell a busy server apart from a server with no PRSGET
    -- handler at all. Keep the previous data on screen and stop the timeout.
    local err = string.match(text, "^PRSERR:(.+)$")
    if err then
        requested = false
        if statusText then
            if err == "busy" then
                statusText:SetText(COLOR_DIM .. "Refreshing too fast -- try again in a moment.|r")
            else
                statusText:SetText(COLOR_DIM .. err .. "|r")
            end
        end
        return
    end

    -- ⚠ Field 6 is RETIRED and deliberately parsed-then-dropped. It carried
    -- CraftStackablesOnly, which gated an extra-items payout that was replaced on
    -- 2026-08-15 by the Soulforge-food chance this card already renders -- no
    -- gameplay path consults it any more (server half: GC-16). It is still
    -- CAPTURED because this pattern is positional: a server that stops sending
    -- the field would make the whole match fail and silently break every prestige
    -- setting on this card, so the field has to leave the wire and this pattern
    -- in the same pass.
    local enabled, yield, perLevel, maxLevel, craftPct, _retired6, credit =
        string.match(text, "^PRSCFG:(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)$")
    if enabled then
        local p = Staging()
        p.enabled          = enabled == "1"
        p.yieldEnabled     = yield == "1"
        p.craftsPerLevel   = tonumber(perLevel) or 0
        p.maxLevel         = tonumber(maxLevel) or 0
        p.craftPctPerLevel = tonumber(craftPct) or 0
        p.gatherCredit     = tonumber(credit) or 1
        return
    end

    -- The profession name is LAST and captured with (.+)$ on purpose, the same
    -- rule PRGSR and ANIMADEF follow: a localised or custom skill name may
    -- contain a colon, so anchoring the numeric head and taking the rest is the
    -- only safe split.
    local skillId, flags, level, crafts, prevAt, nextAt, multPct, nextMultPct,
          craftPctNow, nextCraftPct, gatherPct, nextGatherPct, rarePct,
          enchantRecipes, skillValue, skillMax, name =
        string.match(text,
            "^PRSROW:(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(.+)$")
    if skillId then
        local p = Staging()
        tinsert(p.rows, {
            skillId        = tonumber(skillId) or 0,
            flags          = tonumber(flags) or 0,
            level          = tonumber(level) or 0,
            crafts         = tonumber(crafts) or 0,
            prevAt         = tonumber(prevAt) or 0,
            nextAt         = tonumber(nextAt) or 0,
            multPct        = tonumber(multPct) or 0,
            nextMultPct    = tonumber(nextMultPct) or 0,
            craftPct       = tonumber(craftPctNow) or 0,
            nextCraftPct   = tonumber(nextCraftPct) or 0,
            gatherPct      = tonumber(gatherPct) or 0,
            nextGatherPct  = tonumber(nextGatherPct) or 0,
            rarePct        = tonumber(rarePct) or 0,
            enchantRecipes = tonumber(enchantRecipes) or 0,
            skillValue     = tonumber(skillValue) or 0,
            skillMax       = tonumber(skillMax) or 0,
            name           = name,
        })
        return
    end

    -- PRSEND terminates the burst and is the only place `state` is replaced.
    -- Every server path ends here, including the ones with nothing to report, so
    -- "answered with nothing" and "never answered" stay distinguishable.
    local rows = string.match(text, "^PRSEND:(%d+)$")
    if rows then
        local p = Staging()
        p.received = true
        SortRows(p.rows)
        state     = p
        pending   = nil
        requested = false
        timedOut  = false
        if frame and frame:IsShown() then Render() end
        return
    end
end

-- ---------------------------------------------------------------------------
-- Frame construction
-- ---------------------------------------------------------------------------

-- Header lines: a fixed pool of font strings, re-anchored and re-filled by
-- Render(). A pool rather than fresh strings per refresh -- 3.3.5a has no way to
-- destroy a font string, so creating them per paint leaks one set per refresh
-- for the whole session.
local function AcquireLine(index, x, y, width)
    local fs = lines[index]
    if not fs then
        fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetJustifyH("LEFT")
        lines[index] = fs
    end
    fs:SetWidth(width or CARD_W)
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + (x or 0), y)
    fs:Show()
    return fs
end

-- The card tooltip: everything that did not fit on the card, plus every caveat
-- that would be dishonest to leave out. Caveats belong here rather than on the
-- card because they are true of the SYSTEM rather than of the player's current
-- level, and a card that spends three of its five lines on small print stops
-- being readable.
local function ShowCardTooltip(self)
    local d = self.entry
    if not d then return end

    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(d.name or "Profession", 1, 0.82, 0)
    GameTooltip:AddLine(string.format("Prestige %d  --  %s crafts banked", d.level, Comma(d.crafts)), 1, 1, 1)

    if d.skillValue > 0 then
        GameTooltip:AddLine(string.format("Your skill: %d / %d", d.skillValue, d.skillMax), 0.7, 0.7, 0.7)
    else
        -- Prestige is ACCOUNT-wide. A character who never learned the profession
        -- still owns the account's progress in it, and saying so is the whole
        -- reason the row is shown at all.
        GameTooltip:AddLine("Not learned on this character -- these crafts were made on another one.", 0.7, 0.7, 0.7)
    end

    if d.nextAt > 0 then
        local togo = d.nextAt - d.crafts
        if togo < 0 then togo = 0 end
        GameTooltip:AddLine(string.format("Prestige %d at %s crafts  (%s to go)",
            d.level + 1, Comma(d.nextAt), Comma(togo)), 0.7, 0.7, 0.7)
    end

    GameTooltip:AddLine(" ")
    local payouts = PayoutLines(d)
    if #payouts > 0 then
        GameTooltip:AddLine("Right now this prestige gives you:", 0.8, 0.8, 0.8)
        for _, text in ipairs(payouts) do
            -- Strip the inline colour codes: the tooltip colours whole lines
            -- itself, and leaving them in prints the escape sequences.
            GameTooltip:AddLine("  " .. string.gsub(string.gsub(text, "|c%x%x%x%x%x%x%x%x", ""), "|r", ""),
                0.6, 1, 0.6)
        end
    else
        GameTooltip:AddLine("This profession gives you nothing yet -- prestige 0 pays nothing.", 0.8, 0.8, 0.8)
    end

    GameTooltip:AddLine(" ")

    if HasFlag(d.flags, F_ENCHANT) then
        local examples = ENCHANT_EXAMPLES[d.skillId]
        if examples then
            GameTooltip:AddLine(string.format("Enchants: %s.", examples), 0.7, 0.7, 0.7, true)
        end
        if d.enchantRecipes > 0 then
            GameTooltip:AddLine(string.format("%d of this profession's recipes are enchants that prestige scales.",
                d.enchantRecipes), 0.7, 0.7, 0.7, true)
        end
        -- The caveat that catches people out. A scroll, a kit or a spellthread is
        -- a stackable ITEM: stacks merge and keep one member's data, so there is
        -- nowhere to record which crafter made which one, and no prestige can
        -- ride along.
        GameTooltip:AddLine("Only enchants you cast yourself carry prestige -- scrolls, armour kits and "
            .. "spellthreads do not.", 0.7, 0.55, 0.35, true)
    end

    -- (Removed: an "extra items are paid on stackable products" line fed by the
    -- retired CraftStackablesOnly config. The extra-items payout it described was
    -- replaced on 2026-08-15 by the Soulforge-food chance rendered above, so on
    -- any realm that set the key to 1 this tooltip advertised a reward that no
    -- longer exists. See DP-05 / GC-16.)

    if HasFlag(d.flags, F_GATHER) then
        if state.gatherCredit == 1 then
            GameTooltip:AddLine("Every node you gather also counts as one craft on this ladder.",
                0.7, 0.7, 0.7, true)
        else
            GameTooltip:AddLine(string.format("Every node you gather counts as %d crafts on this ladder.",
                state.gatherCredit), 0.7, 0.7, 0.7, true)
        end
        if HasFlag(d.flags, F_CRAFT) then
            -- Mining, and only Mining, in the shipped config. Worth saying: it is
            -- the one profession whose two payouts compound on the same ore.
            GameTooltip:AddLine("This profession is paid twice on the same material: once when you "
                .. "gather it, again when you craft with it.", 0.6, 1, 0.6, true)
        end
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Prestige is account-wide -- every character you play feeds this.", 0.5, 0.5, 0.5, true)
    GameTooltip:Show()
end

local function BuildCard(index)
    local card = cards[index]
    if card then return card end

    card = {}
    card.frame = CreateFrame("Button", nil, frame)
    card.frame:SetWidth(CARD_W)
    -- Four units shorter than the stride, so cards do not touch -- but no
    -- shorter: the "next prestige" line sits at -73 and is ~12 tall, so a frame
    -- under 85 would leave it outside the card's own hover area and the tooltip
    -- would blink off whenever the pointer crossed the line a player is most
    -- likely to be reading.
    card.frame:SetHeight(CARD_H - 4)

    card.icon = card.frame:CreateTexture(nil, "ARTWORK")
    card.icon:SetWidth(24)
    card.icon:SetHeight(24)
    card.icon:SetPoint("TOPLEFT", card.frame, "TOPLEFT", 0, -1)

    local function Cell(font, x, y, w, justify)
        local fs = card.frame:CreateFontString(nil, "OVERLAY", font)
        fs:SetWidth(w)
        fs:SetJustifyH(justify or "LEFT")
        fs:SetPoint("TOPLEFT", card.frame, "TOPLEFT", x, y)
        return fs
    end

    card.name  = Cell("GameFontNormal",        30,  0,   210, "LEFT")
    card.skill = Cell("GameFontDisableSmall", 244,  2,   110, "LEFT")
    card.level = Cell("GameFontHighlight",    358,  0,   112, "RIGHT")

    -- Progress inside the CURRENT step, not toward some absolute total: the
    -- ladder doubles, so "1,204 of 2,000" is the only framing where the bar
    -- moves at a rate that means anything.
    card.bar = CreateFrame("StatusBar", nil, card.frame)
    card.bar:SetWidth(CARD_W - 30)
    card.bar:SetHeight(11)
    card.bar:SetPoint("TOPLEFT", card.frame, "TOPLEFT", 30, -18)
    card.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    card.bar:SetStatusBarColor(0.61, 0.76, 0.26)
    card.bar:SetMinMaxValues(0, 1)
    card.bar:SetValue(0)

    card.barBg = card.bar:CreateTexture(nil, "BACKGROUND")
    card.barBg:SetAllPoints(card.bar)
    card.barBg:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
    card.barBg:SetVertexColor(0.12, 0.12, 0.12, 0.8)

    card.barText = card.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.barText:SetPoint("CENTER", card.bar, "CENTER", 0, 0)

    -- ★ NO SetWidth ON THE PAYOUT LINES, DELIBERATELY. A font string with an
    --   explicit width wraps silently, and a wrapped line inside a FIXED-HEIGHT
    --   card draws straight over the next line -- a failure that only appears
    --   for whichever player's numbers happen to be one digit too long. Without
    --   a width these never wrap; an over-long sentence overhangs the card's
    --   right edge instead, which is visible, harmless, and cannot corrupt the
    --   layout. GetMinWidth() below reserves room for the longest real sentence.
    card.pay = {}
    for i = 1, 3 do
        local fs = card.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetJustifyH("LEFT")
        fs:SetPoint("TOPLEFT", card.frame, "TOPLEFT", 30, -32 - (i - 1) * 13)
        card.pay[i] = fs
    end

    card.next = card.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.next:SetJustifyH("LEFT")
    card.next:SetPoint("TOPLEFT", card.frame, "TOPLEFT", 30, -73)

    card.frame:SetScript("OnEnter", ShowCardTooltip)
    card.frame:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Cards are children of the panel, not of the scroll frame, so the wheel
    -- does not reach the scroll bar on its own -- the pointer spends nearly all
    -- its time over a card, which would make the list feel unscrollable. Forward
    -- it explicitly, guarded on the bar existing.
    card.frame:EnableMouseWheel(true)
    card.frame:SetScript("OnMouseWheel", function(self, delta)
        local sb = _G["UncappedPrestigeListScrollScrollBar"]
        if sb then sb:SetValue(sb:GetValue() - delta * CARD_H) end
    end)

    cards[index] = card
    return card
end

-- How many cards fit right now. The Dashboard window is resizable, so this is
-- measured rather than a constant -- a fixed count either wastes half a tall
-- window or runs off the bottom of a short one. Clamped to at least one so a
-- frame that has not been laid out yet (height 0 on the very first paint) still
-- renders something.
local function VisibleCards()
    local height = frame and frame:GetHeight() or 0
    local usable = height + listTop - STATUS_RESERVE     -- listTop is negative
    local n = math.floor(usable / CARD_H)
    if n < 1 then n = 1 end
    if n > MAX_CARDS then n = MAX_CARDS end
    return n
end

local function RefreshCards()
    if not listScroll then return end

    local data = state.rows or {}
    local shown = VisibleCards()

    -- Update BEFORE reading the offset, the same order the Progress and Anima
    -- lists use: FauxScrollFrame_Update can clamp (and therefore change) the
    -- scroll position when the row count shrinks, and reading the offset first
    -- would paint one frame from a position that no longer exists.
    listScroll:SetHeight(shown * CARD_H)
    FauxScrollFrame_Update(listScroll, #data, shown, CARD_H)
    local offset = FauxScrollFrame_GetOffset(listScroll) or 0

    for i = 1, MAX_CARDS do
        local card = BuildCard(i)
        local d = (i <= shown) and data[i + offset] or nil

        if d then
            card.frame:ClearAllPoints()
            card.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, listTop - (i - 1) * CARD_H)
            -- ⚠ ON card.frame, NOT ON card. OnEnter is handed the FRAME as
            --   `self`, so the tooltip reads self.entry -- stashing it on the
            --   wrapper table instead leaves self.entry nil and the tooltip
            --   silently never appears. (That is exactly the state the Progress
            --   tab's dungeon rows are in; a smoke run caught it here.)
            card.frame.entry = d

            local spellId = PROFESSION_SPELL[d.skillId]
            local icon = nil
            if spellId and GetSpellInfo then
                local _, _, texture = GetSpellInfo(spellId)
                icon = texture
            end
            card.icon:SetTexture(icon or FALLBACK_ICON)

            card.name:SetText(COLOR_LABEL .. (d.name or "Profession") .. "|r")

            if d.skillValue > 0 then
                card.skill:SetText(string.format("%d / %d", d.skillValue, d.skillMax))
            else
                -- Not a warning, just a fact: the crafts are real and the
                -- prestige is real, they were simply earned on another character.
                card.skill:SetText("on another character")
            end

            if d.level > 0 then
                card.level:SetText(string.format("%sPrestige %d|r", COLOR_VALUE, d.level))
            else
                card.level:SetText(COLOR_DIM .. "No prestige yet|r")
            end

            -- Fill = progress through the CURRENT step. prevAt and nextAt are
            -- both sent by the server rather than derived here, so the doubling
            -- shape of the ladder stays entirely the server's business.
            local span = d.nextAt - d.prevAt
            local done = d.crafts - d.prevAt
            if d.nextAt <= 0 then
                card.bar:SetValue(1)
                card.barText:SetText(COLOR_GOOD .. "Ladder complete|r")
            elseif span > 0 then
                if done < 0 then done = 0 end
                if done > span then done = span end
                card.bar:SetValue(done / span)
                card.barText:SetText(string.format("%s%s|r / %s crafts", COLOR_VALUE, Comma(done), Comma(span)))
            else
                card.bar:SetValue(0)
                card.barText:SetText(COLOR_DIM .. Comma(d.crafts) .. " crafts|r")
            end

            local payouts = PayoutLines(d)
            for n = 1, 3 do
                if payouts[n] then
                    card.pay[n]:SetText(payouts[n])
                    card.pay[n]:Show()
                elseif n == 1 and #payouts == 0 then
                    -- Prestige 0. Say so plainly instead of leaving a blank gap,
                    -- then let the next-level line do the selling.
                    card.pay[n]:SetText(COLOR_DIM .. "Nothing boosted yet -- prestige 0 pays nothing.|r")
                    card.pay[n]:Show()
                else
                    card.pay[n]:Hide()
                end
            end

            card.next:SetText(NextLine(d))
            card.frame:Show()
        else
            card.frame.entry = nil
            card.frame:Hide()
        end
    end
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------
function Render()
    if not frame then return end

    local i, y = 1, -12

    local function Head(text)
        local fs = AcquireLine(i, 0, y)
        fs:SetText(COLOR_HEAD .. text .. "|r")
        i, y = i + 1, y - (ROW_H + 4)
    end

    -- Free text, wrapped inside `width`.
    --
    -- ★ ADVANCES BY THE MEASURED HEIGHT, NOT BY ROW_H. A font string with an
    --   explicit width wraps by itself, silently: it takes two lines of screen
    --   space while a caller advancing a fixed ROW_H thinks it took one, and the
    --   card list below is then anchored on top of the second line. Every
    --   sentence here quotes a live server number, so its length is not fixed at
    --   authoring time -- measuring removes the whole class of bug instead of
    --   requiring each string to be hand-fitted forever. Same helper, same
    --   reasoning, as the Progress tab's Note().
    local function Note(text, width)
        local fs = AcquireLine(i, 0, y, width or CARD_W)
        fs:SetText(COLOR_DIM .. text .. "|r")
        local h = fs.GetStringHeight and fs:GetStringHeight() or 0
        i, y = i + 1, y - math.max(ROW_H, math.ceil(tonumber(h) or 0))
    end

    local function Warn(text, width)
        local fs = AcquireLine(i, 0, y, width or CARD_W)
        fs:SetText(COLOR_WARN .. text .. "|r")
        local h = fs.GetStringHeight and fs:GetStringHeight() or 0
        i, y = i + 1, y - (math.max(ROW_H, math.ceil(tonumber(h) or 0)) + 4)
    end

    local function HideRest()
        for n = i, #lines do lines[n]:Hide() end
    end

    local function HideList()
        if listScroll then listScroll:Hide() end
        for n = 1, #cards do cards[n].frame:Hide() end
    end

    -- ---- not answered yet ----------------------------------------------------
    if not state.received then
        Head("Profession Prestige")
        if timedOut then
            -- The honest message. A server build without the PRSGET handler is a
            -- supported state, not a fault: this addon can ship in a payload
            -- before the matching worldserver build is deployed, and it must not
            -- read as broken while that is true.
            Note("This realm's server hasn't sent your prestige. That usually means the server hasn't "
                .. "been updated for this panel yet -- nothing is wrong with your professions. "
                .. "Try again with /prestige sync.", CARD_W)
        else
            Note("Waiting for the server...")
        end
        HideRest()
        HideList()
        if statusText then statusText:SetText("") end
        return
    end

    -- ---- switched off --------------------------------------------------------
    if not state.enabled then
        Head("Profession Prestige")
        Note("Profession prestige is switched off on this realm right now.", CARD_W)
        HideRest()
        HideList()
        if statusText then statusText:SetText("") end
        return
    end

    -- ---- the rule ------------------------------------------------------------
    Head("Profession Prestige")

    -- Written from the numbers the server actually sent rather than from prose
    -- baked in here, so retuning ProfessionPrestige.CraftsPerLevel moves this
    -- sentence instead of leaving it advertising a ladder the server stopped
    -- honouring.
    if state.craftsPerLevel > 0 then
        Note(string.format("Prestige 1 costs %s crafts. Every level after that costs double the one before, "
            .. "so the ladder never ends -- it just slows down.", Comma(state.craftsPerLevel)), CARD_W)
    end
    Note("It is account-wide: every craft, on every character you play, feeds the same ladder. "
        .. "Gathering counts too.", CARD_W)

    if not state.yieldEnabled then
        Warn("Extra items and bigger gathering hauls are switched off on this realm right now -- "
            .. "only enchant strength is being paid.", CARD_W)
    end

    y = y - 4

    -- ---- no professions ------------------------------------------------------
    if #state.rows == 0 then
        Note("You haven't taken a profession yet, so there is nothing on the ladder.", CARD_W)
        Note("Learn one from a Grandmaster trainer and start making things. Every craft counts from "
            .. "the very first one, and the count is shared across your whole account -- so alts are "
            .. "not starting over.", CARD_W)
        HideRest()
        HideList()
        if statusText then statusText:SetText("") end
        return
    end

    HideRest()

    listTop = y
    listScroll:ClearAllPoints()
    listScroll:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
    listScroll:Show()
    RefreshCards()

    if statusText then
        statusText:SetText(string.format("%s%d profession%s on the ladder. Hover a card for the details.|r",
            COLOR_DIM, #state.rows, #state.rows == 1 and "" or "s"))
    end
end

local function BuildFrame(parent)
    if frame then return end

    frame = CreateFrame("Frame", "UncappedPrestigeFrame", parent or UIParent)
    frame:SetPoint("TOPLEFT")
    frame:SetPoint("BOTTOMRIGHT")

    statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, 14)
    statusText:SetJustifyH("LEFT")
    statusText:SetWidth(CARD_W)
    statusText:SetText("")

    listScroll = CreateFrame("ScrollFrame", "UncappedPrestigeListScroll", frame, "FauxScrollFrameTemplate")
    listScroll:SetWidth(CARD_W)
    listScroll:SetHeight(CARD_H)
    listScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, CARD_H, RefreshCards)
    end)
    listScroll:EnableMouseWheel(true)
    listScroll:SetScript("OnMouseWheel", function(self, delta)
        local sb = _G["UncappedPrestigeListScrollScrollBar"]
        if sb then sb:SetValue(sb:GetValue() - delta * CARD_H) end
    end)
    listScroll:Hide()

    -- The window is resizable, and how many cards fit is measured from the
    -- frame's height (see VisibleCards), so a resize has to re-lay-out the list.
    -- Only the cards, not the whole Render: the header above them has not moved.
    frame:SetScript("OnSizeChanged", function()
        if listScroll and listScroll:IsShown() then RefreshCards() end
    end)

    -- The reply timeout. 3.3.5a has no C_Timer, so this is an OnUpdate with an
    -- accumulator -- the standard shape on this client. It only runs while the
    -- tab is visible AND a request is outstanding, so it costs nothing the rest
    -- of the time.
    frame:SetScript("OnUpdate", function(self, elapsed)
        if not requested then return end
        waited = waited + (elapsed or 0)
        if waited < REPLY_TIMEOUT then return end
        requested = false
        timedOut  = true
        pending   = nil
        Render()
    end)

    frame:Hide()
end

-- ===========================================================================
-- Dashboard embedding
-- ===========================================================================
-- The Dashboard hosts this panel inside its own window rather than Prestige
-- owning one -- see UncappedDashboard_UI.lua, which calls EmbedInto once and
-- Activate every time the Prestige tab is selected.
local Prestige = _G.UncappedPrestige or {}
_G.UncappedPrestige = Prestige
Prestige.UI = {}

function Prestige.UI.EmbedInto(parent)
    BuildFrame(parent)
    frame:Show()
    return frame
end

function Prestige.UI.Activate()
    if not frame then return end
    Render()     -- paint immediately from whatever's cached
    Request()    -- then refresh
end

-- Content-panel width: a card is 470 wide, plus PAD on the left, ~20 for the
-- scroll bar the FauxScrollFrame template creates on the right, plus the
-- embedded group's own 6px padding on each side. The card's payout sentences do
-- not wrap (see BuildCard), so this floor is what keeps the longest of them --
-- "Every craft makes 2 extra, plus a 75% shot at one more." -- inside the panel.
function Prestige.UI.GetMinWidth()
    return CARD_W + PAD + 20 + 12 + 8
end

-- Full WINDOW height (not content height): the header block runs to ~80px, four
-- cards is the smallest list worth showing at 4 * 92 = 368, the status line
-- reserves 34, and the Dashboard's own chrome above and around the content area
-- is ~72. Anything taller than this shows more cards rather than more of each
-- card -- see VisibleCards.
function Prestige.UI.GetMinHeight()
    return 80 + (4 * CARD_H) + STATUS_RESERVE + 72
end

local function OpenInDashboard()
    local Dashboard = _G.UncappedDashboard
    if not Dashboard then
        DEFAULT_CHAT_FRAME:AddMessage(COLOR_HEAD .. "[Prestige]|r lives inside the Dashboard -- load UncappedDashboard to use it.")
        return
    end
    Dashboard.SetTab("prestige")
    if not (Dashboard.UI and Dashboard.UI.IsShown and Dashboard.UI.IsShown()) then
        Dashboard.Toggle()
    end
end

-- ===========================================================================
-- Events / slash
-- ===========================================================================
local comms = CreateFrame("Frame")
comms:RegisterEvent("CHAT_MSG_ADDON")
comms:SetScript("OnEvent", function(self, event, a1, a2)
    -- 3.3.5a hands some paths the arg1..argN globals rather than parameters.
    event = event or _G.event
    a1 = a1 or _G.arg1
    a2 = a2 or _G.arg2

    if event ~= "CHAT_MSG_ADDON" then return end
    if a1 ~= ADDON_PIPE_PREFIX or not a2 then return end
    -- "PRS", not "PR": the Progress tab owns "PRG" on this same pipe, and a
    -- two-letter test would hand it every one of its own messages.
    if string.sub(a2, 1, 3) ~= "PRS" then return end
    HandleMessage(a2)
end)

SLASH_UNCAPPEDPRESTIGE1 = "/prestige"
SLASH_UNCAPPEDPRESTIGE2 = "/uprestige"
SlashCmdList["UNCAPPEDPRESTIGE"] = function(arg)
    arg = string.lower(arg or "")
    arg = string.gsub(arg, "^%s+", "")
    arg = string.gsub(arg, "%s+$", "")
    if arg == "sync" then
        Request()
        DEFAULT_CHAT_FRAME:AddMessage(COLOR_HEAD .. "[Prestige]|r Refreshing...")
    else
        OpenInDashboard()
    end
end

-- Settings page (ESC > Interface > AddOns > Uncapped > Prestige). Provided by the
-- shared UncappedUI widget library (UncappedOptions addon); guarded so the page
-- just doesn't appear if that addon is missing.
if UncappedUI then
    local _, L = UncappedUI.CreatePanel("Prestige",
        "Your account-wide profession prestige: what each profession has earned, how far the next "
        .. "level is, and exactly what that level pays for THAT profession.")

    L:Header("Prestige")
    L:Button("Open Prestige", OpenInDashboard, 180)
    L:Note("Every craft you make -- on any character on this account -- counts toward that "
        .. "profession's prestige. Prestige 1 costs a fixed number of crafts and every level after "
        .. "costs double the last, so the ladder never ends.", 48)
    L:Note("What a level pays depends on the profession: enchanters and the four professions with "
        .. "their own enchants get stronger enchants, crafters get a chance at Soulforge food, and gatherers get "
        .. "bigger hauls and better odds on rare materials. The panel says which, per profession. "
        .. "Also available with /prestige.", 60)
end
