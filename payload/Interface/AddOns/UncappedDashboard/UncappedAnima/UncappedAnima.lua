-- UncappedAnima
--
-- The purchase window for the four "tempo" stats.
--
-- Haste is repurposed on this realm: haste rating and every haste aura are
-- converted to crit damage, so nothing in the game shortens a cast, a swing, a
-- cooldown or the GCD on its own. These four stats give each of those back as a
-- separately purchased axis:
--
--   Cooldown Reduction -- ability cooldowns
--   Time Manipulation  -- the global cooldown
--   Alacrity           -- cast time
--   Swiftness          -- melee and ranged swing time
--
-- Everything shown here comes from the server over the ANIMA* protocol (see
-- modules/mod-time-stats). The client is a renderer: it holds no opinion about
-- what a rank costs, what the cap is, or whether you can afford it. Every panel
-- redraw is driven by a fresh ANIMASTAT block, and the server re-sends that
-- block after every purchase attempt, successful or not.
--
-- As of this session, that extends to WHICH stats exist at all: ANIMALIST
-- requests the stat/spell definition list itself (name/icon/blurb/help/tree
-- per stat, see the protocol section near CommitDefinitions), so adding or
-- rebalancing a stat no longer needs an addon update, just a server-side
-- change. DEFAULT_STATS (near the top of this file) is only the fallback
-- shown until that reply lands -- or forever, against an older server build
-- that doesn't send one, which is a supported, non-broken state.
--
-- 3.3.5a client: no BackdropTemplate, no C_Timer, arg1..argN globals in event
-- handlers on some paths, and GetSpellInfo(id) is the only reliable way to get
-- an icon path that is guaranteed to exist in this client's Spell.dbc.


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

-- Gold active state on a kit button; falls back to the Blizzard template's
-- locked PUSHED look when the kit is absent. Split out because SetButtonActive
-- indexes button.text, which the raw fallback above does not create.
local function KitSetActive(b, on)
    if UIKit and UIKit.SetButtonActive and b.text then
        UIKit.SetButtonActive(b, on)
    elseif on then
        b:SetButtonState("PUSHED", true)
    else
        b:SetButtonState("NORMAL")
    end
end

local ADDON_PIPE_PREFIX = "UNC"           -- server -> client replies
local TRANSPORT_PREFIX  = "REAGENTBANK"   -- client -> server transport (shared)

-- 96 (not 84): a card's icon (36) + bar (9, with 6px gaps) + button row (20)
-- adds up to 87px of content before any bottom padding -- 84 was clipping
-- the buy buttons a few pixels past the card's own bottom edge/border.
local CARD_HEIGHT  = 96
local CARD_GAP     = 8
local ROW_H        = CARD_HEIGHT + CARD_GAP
local CARD_INSET   = 16

-- A card's buy-button row (+1/+10/+100/Max: 98*4 + 4*3 = 404) starts 10px in
-- from the card's own left edge, so the card needs at least 404 + 10 left +
-- 10 right padding = 424 to hold it without compressing the buttons. Cards
-- normally stretch to fill whatever width Relayout gives them, but never
-- narrower than this floor -- see Relayout's math.max(availWidth, ...) --
-- so even if the Dashboard window somehow got narrower than Anima.UI.
-- GetMinWidth() allows for, the buttons still wouldn't get squeezed.
local MIN_CARD_WIDTH = 424

-- ---------------------------------------------------------------------------
-- Stat definitions -- now server-driven (see the ANIMALIST/ANIMADEF/
-- ANIMABLURB/ANIMAHELP/ANIMALISTEND protocol further down) instead of a
-- fixed table shipped in the addon, so adding, removing, or rebalancing a
-- stat's name/icon/description no longer needs an addon update. This table
-- is only the FALLBACK shown until the server's reply lands -- or forever,
-- if talking to a server build that doesn't implement ANIMALIST yet, so
-- this migration is purely additive/backward-compatible. CommitDefinitions
-- (below) replaces `STATS` wholesale the moment ANIMALISTEND arrives.
--
-- `index` is the wire index used by ANIMASTAT/ANIMABUY/ANIMABOUGHT
-- regardless of whether a definition came from here or the server --
-- append-only in this fallback, and must match whatever the server sends
-- for any stat it also defines.
--
-- `icon` is a spell id, not a texture path: GetSpellInfo reads the client's own
-- Spell.dbc, so the icon is guaranteed to resolve. Hardcoded texture names are
-- how you ship a question mark to everyone -- plenty of icon names that exist
-- on retail were never in 3.3.5a.
-- ---------------------------------------------------------------------------
local DEFAULT_STATS = {
    {
        tree  = "tempo",
        index = 0,
        name  = "Cooldown Reduction",
        icon  = 14185,   -- Preparation
        blurb = "Shortens your ability cooldowns.",
        help  = "Reduces the real cooldown of your abilities. Worth most to specs whose damage is gated behind cooldowns rather than cast time.",
    },
    {
        tree  = "tempo",
        index = 1,
        name  = "Time Manipulation",
        icon  = 16880,   -- Nature's Grace
        blurb = "Shortens your global cooldown.",
        help  = "Reduces the global cooldown between abilities. Worth most if you are GCD-locked -- that is, if you always have another button ready before the GCD is up.",
    },
    {
        tree  = "tempo",
        index = 2,
        name  = "Alacrity",
        icon  = 12472,   -- Icy Veins
        blurb = "Shortens your cast times.",
        help  = "Reduces spell cast time. This is the caster's stat: if your damage is limited by how long Fireball takes, nothing else on this list helps you.",
    },
    {
        tree  = "tempo",
        index = 3,
        name  = "Swiftness",
        icon  = 2825,    -- Bloodlust
        blurb = "Speeds up your melee and ranged attacks.",
        help  = "Reduces melee and ranged swing time. More auto-attacks means more damage and more chances for your item procs to fire.",
    },

    -- ⚠ The DEFENCE tree -- Evasion (4), Deflection (5), Bulwark (6) and
    -- Resolve (7) -- was RETIRED on 2026-08-12 and every rank refunded. The
    -- entries are gone from this fallback, and the server's own definitions
    -- for those wire indices are filtered out on arrival; see RETIRED_TREES.
}
local STATS = DEFAULT_STATS
-- def.index -> def, rebuilt alongside STATS. A plain STATS[idx+1] positional
-- lookup only works if wire indices are contiguous from 0 with no gaps --
-- true of the fallback table, but not something a server-driven list should
-- be trusted to preserve, so lookups by wire index go through this instead.
local STATS_BY_INDEX = {}
local function IndexStats()
    STATS_BY_INDEX = {}
    for _, def in ipairs(STATS) do
        STATS_BY_INDEX[def.index] = def
    end
end
IndexStats()

local TREES = {
    { key = "tempo",   label = "Tempo",
      note = "Haste is converted to crit damage on this realm, so these are what actually make you faster. The first four trim the time a cast, swing, cooldown or GCD takes; Multicast skips the time entirely by repeating the cast for free. Buy the one your rotation is limited by." },
    { key = "utility", label = "Utility",
      note = "Quality-of-life stats that work everywhere, mounted or on foot, keystone or open world." },
}

-- ★ [DP-03] Dropping the four defence entries from DEFAULT_STATS is NOT
-- enough on its own. `SendDefinitions` still loops 0..STAT_COUNT and
-- STAT_TREE[4..7] is still "defence" (mod-time-stats/src/time_stats.cpp:210),
-- so CommitDefinitions would put every one of them straight back -- priced,
-- rank 0 after the refund, and therefore drawn with a live Buy button that
-- the server answers with `coming_soon`.
--
-- Filtered by TREE NAME rather than by wire index on purpose: the index list
-- is the server's to change, the tree name is what the client already models,
-- and a stat moved to a live tree keeps working without a client change.
local RETIRED_TREES = {
    defence = true,   -- retired 2026-08-12, all ranks refunded
}

-- ---------------------------------------------------------------------------
-- SavedVariables
-- ---------------------------------------------------------------------------
local DEFAULTS = {
    lastAmount = 1,        -- remembered buy quantity
    tree       = "tempo",  -- which tab was open last
}

local db

local function InitDB()
    if type(UncappedAnimaDB) ~= "table" then UncappedAnimaDB = {} end
    db = UncappedAnimaDB
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
    return db
end

InitDB()

-- ---------------------------------------------------------------------------
-- Server-supplied state. `state[index]` is filled by ANIMASTAT lines.
-- ---------------------------------------------------------------------------
local state = {}          -- [wireIndex] = { rank, maxRank, pct, maxPct, cost = {..} }
local arenaPoints = 0
local haveData = false

-- Server-supplied stat DEFINITIONS (name/icon/blurb/help/tree), as opposed to
-- the live numeric `state` above -- see ANIMALIST/ANIMADEF/... further down.
-- `defStaging[index]` accumulates ANIMADEF/ANIMABLURB/ANIMAHELP lines as they
-- arrive (order not guaranteed), committed to `STATS` as a batch on
-- ANIMALISTEND -- same "stage then swap" shape Soul Forge uses for its
-- equipped-item tooltip cache, so a definition never renders half-built.
local defStaging = {}      -- [index] = { index=, tree=, icon=, name=, blurb=, help= }

local frame, cards, pointsText, statusText, tabButtons, treeNote
local animaScroll
local visibleRows = 4   -- both trees have exactly 4 stats; recomputed on resize, see BuildFrame

local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"

local function Send(msg)
    SendAddonMessage(TRANSPORT_PREFIX, msg, "WHISPER", UnitName("player"))
end

local function RequestState()
    Send("ANIMAOPEN")
end

-- Requests the stat/spell DEFINITION list (name/icon/blurb/help/tree) --
-- unlike RequestState, this is definitional data, not live numbers, so it's
-- only sent once at login (see PLAYER_ENTERING_WORLD below), not re-sent
-- every time the Anima tab is activated.
local function RequestDefinitions()
    Send("ANIMALIST")
end

local function IconFor(spellId)
    local _, _, icon = GetSpellInfo(spellId)
    return icon or QUESTION_MARK
end

-- Thousands separators. 3.3.5a has no built-in for this and arena costs at the
-- top of the curve run to seven digits, which is unreadable unbroken.
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

-- Server sends percentages as hundredths of a percent, so it never has to
-- explain its curve or its cap to the client.
local function FormatPct(hundredths)
    return string.format("%.1f%%", (hundredths or 0) / 100)
end

-- ---------------------------------------------------------------------------
-- Buy amounts. "Max" asks for every remaining rank; the server clamps and
-- charges only what it actually grants.
-- ---------------------------------------------------------------------------
local AMOUNTS = {
    { label = "+1",   count = 1,    key = "c1"   },
    { label = "+10",  count = 10,   key = "c10"  },
    { label = "+100", count = 100,  key = "c100" },
    { label = "Max",  count = 1000, key = "cMax" },
}

-- ===========================================================================
-- Frame construction
-- ===========================================================================

local function StyleCardBackdrop(f)
    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0.06, 0.06, 0.09, 0.85)
    f:SetBackdropBorderColor(0.35, 0.32, 0.25, 1)
end

local function BuildCard(parent, def)
    local card = CreateFrame("Frame", nil, parent)
    card:SetHeight(CARD_HEIGHT)
    StyleCardBackdrop(card)
    card.def = def

    -- Icon, with the standard inset border so it reads as an item/spell icon
    -- rather than a floating square.
    local icon = card:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(36)
    icon:SetHeight(36)
    icon:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -10)
    icon:SetTexture(IconFor(def.icon))
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local iconBorder = card:CreateTexture(nil, "OVERLAY")
    iconBorder:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    iconBorder:SetWidth(60)
    iconBorder:SetHeight(60)
    iconBorder:SetPoint("CENTER", icon, "CENTER", 0, -1)
    iconBorder:SetVertexColor(0.7, 0.7, 0.7)

    local name = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 10, -1)
    name:SetText(def.name)

    local blurb = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    blurb:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -3)
    blurb:SetText(def.blurb)

    -- Current value, right-aligned and large -- the number people actually
    -- came to read.
    local value = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    value:SetPoint("TOPRIGHT", card, "TOPRIGHT", -12, -10)
    value:SetTextColor(0.35, 1.0, 0.35)
    value:SetText("--")

    local rankText = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    rankText:SetPoint("TOPRIGHT", value, "BOTTOMRIGHT", 0, -2)
    rankText:SetText("")

    -- Progress bar: rank towards the cap.
    local bar = CreateFrame("StatusBar", nil, card)
    bar:SetHeight(9)
    bar:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", 0, -6)
    bar:SetPoint("RIGHT", card, "RIGHT", -12, 0)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(0.20, 0.55, 0.85)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)

    local barBg = bar:CreateTexture(nil, "BACKGROUND")
    barBg:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
    barBg:SetAllPoints(bar)
    barBg:SetVertexColor(0.15, 0.15, 0.15, 0.8)

    -- Buy row
    local buttons = {}
    local prev
    for i, amount in ipairs(AMOUNTS) do
        local btn = KitButton(card, "", 98, 20)
        if prev then
            btn:SetPoint("LEFT", prev, "RIGHT", 4, 0)
        else
            btn:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -6)
        end
        btn:SetText(amount.label)
        btn.amount = amount
        btn.statIndex = def.index

        --[[ [#816] KEEP THE TOOLTIP ALIVE WHILE THE BUTTON IS DISABLED.
             RefreshCard disables a buy button whenever the rank is maxed, the
             cost is zero, or you cannot afford it -- and a disabled Button in
             3.3.5a fires NO OnEnter/OnLeave at all unless motion scripts are
             explicitly kept on. So the two most useful branches of the handler
             below (the "already at maximum rank" line, and the red cost + your
             balance for an unaffordable rank) were UNREACHABLE from the day
             they were written: not skipped by a test, simply never entered,
             because the mouse never reached the script. It reads as working
             code, which is why nobody found it until a player reported the
             grey buttons being silent.

             ⚠ Guarded even though this client's Button method table does have
               SetMotionScriptsWhileDisabled: KitButton has a fallback path to
               the raw Blizzard template, and a nil call here would error in
               the middle of a card build and take the whole window with it.
               Degrading to "grey buttons stay silent" costs one tooltip.
        ]]
        if btn.SetMotionScriptsWhileDisabled then
            btn:SetMotionScriptsWhileDisabled(true)
        end

        btn:SetScript("OnClick", function(self)
            Send(string.format("ANIMABUY:%d:%d", self.statIndex, self.amount.count))
            db.lastAmount = self.amount.count
        end)

        btn:SetScript("OnEnter", function(self)
            local s = state[self.statIndex]
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(def.name, 1, 0.82, 0)
            if s then
                if s.rank >= s.maxRank then
                    GameTooltip:AddLine("Already at maximum rank.", 1, 0.3, 0.3)
                else
                    local cost = s.cost[self.amount.key] or 0
                    local granted = math.min(self.amount.count, s.maxRank - s.rank)
                    GameTooltip:AddLine(string.format("Buy %d rank%s", granted, granted == 1 and "" or "s"), 1, 1, 1)
                    local affordable = arenaPoints >= cost
                    GameTooltip:AddLine(
                        string.format("Cost: %s Anima", Comma(cost)),
                        affordable and 0.4 or 1, affordable and 1 or 0.3, affordable and 0.4 or 0.3)
                    if not affordable then
                        -- The SHORTFALL, not just the balance. #816 asked for
                        -- "how much more anima you have to farm", and two
                        -- seven-digit numbers side by side leave the player
                        -- doing the subtraction in their head -- which is the
                        -- one thing a panel that already knows both figures
                        -- should never make them do.
                        GameTooltip:AddLine(
                            string.format("You have %s -- %s short.",
                                Comma(arenaPoints), Comma(cost - arenaPoints)),
                            1, 0.3, 0.3)
                    end
                end
            end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(def.help, 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        buttons[i] = btn
        prev = btn
    end

    card.value    = value
    card.rankText = rankText
    card.bar      = bar
    card.buttons  = buttons
    return card
end

local function RefreshCard(card)
    local s = state[card.def.index]
    if not s then
        card.value:SetText("--")
        card.rankText:SetText("")
        for _, btn in ipairs(card.buttons) do btn:Disable() end
        return
    end

    card.value:SetText(FormatPct(s.pct))
    card.rankText:SetText(string.format("rank %s / %s", Comma(s.rank), Comma(s.maxRank)))

    card.bar:SetMinMaxValues(0, s.maxRank > 0 and s.maxRank or 1)
    card.bar:SetValue(s.rank)

    local maxed = s.rank >= s.maxRank
    if maxed then
        card.value:SetTextColor(1.0, 0.82, 0.0)     -- gold at cap
        card.bar:SetStatusBarColor(1.0, 0.72, 0.15)
    else
        card.value:SetTextColor(0.35, 1.0, 0.35)
        card.bar:SetStatusBarColor(0.20, 0.55, 0.85)
    end

    for _, btn in ipairs(card.buttons) do
        local cost = s.cost[btn.amount.key] or 0
        if maxed or cost <= 0 or arenaPoints < cost then
            btn:Disable()
        else
            btn:Enable()
        end
    end
end

-- Show only the active tree's cards, windowed into whatever rows currently
-- fit inside animaScroll (see BuildFrame's OnSizeChanged) -- when the
-- Dashboard is shrunk below the height four cards need, this scrolls
-- instead of letting cards run off the bottom of the panel. Called on load,
-- whenever the tab changes, and whenever the scroll offset/size changes, so
-- switching tabs or resizing costs no rebuild.
local function Relayout()
    if not frame then return end

    -- [DP-03] How many cards each tree actually holds. A tree with none is a
    -- tab that leads to an empty page -- which is what the retired Defence
    -- tree became -- so it is hidden rather than drawn. Counted here and not
    -- once at build time because CommitDefinitions replaces STATS wholesale.
    local perTree = {}
    for _, card in ipairs(cards or {}) do
        local k = card.def.tree
        perTree[k] = (perTree[k] or 0) + 1
    end

    -- A remembered tab whose tree no longer exists would otherwise leave the
    -- player on an empty list with no tab lit and no obvious way back.
    if (perTree[db.tree] or 0) == 0 then
        for _, t in ipairs(TREES) do
            if (perTree[t.key] or 0) > 0 then
                db.tree = t.key
                break
            end
        end
    end

    local treeCards = {}
    for _, card in ipairs(cards or {}) do
        if card.def.tree == db.tree then treeCards[#treeCards + 1] = card end
    end

    if animaScroll then
        FauxScrollFrame_Update(animaScroll, #treeCards, visibleRows, ROW_H)
        local offset = FauxScrollFrame_GetOffset(animaScroll)
        -- Never narrower than MIN_CARD_WIDTH, even if animaScroll itself is
        -- currently narrower than that (see MIN_CARD_WIDTH's comment) -- a
        -- single TOPLEFT anchor + explicit width instead of stretching
        -- between TOPLEFT+TOPRIGHT, so the card can outgrow its container
        -- rather than ever compress its buttons.
        local cardWidth = math.max(animaScroll:GetWidth(), MIN_CARD_WIDTH)
        for _, card in ipairs(cards or {}) do card:Hide() end
        for slot = 1, visibleRows do
            local card = treeCards[slot + offset]
            if card then
                card:ClearAllPoints()
                card:SetPoint("TOPLEFT", animaScroll, "TOPLEFT", 0, -(slot - 1) * ROW_H)
                card:SetWidth(cardWidth)
                card:Show()
            end
        end
    end

    -- [DP-03] Re-anchored every relayout rather than chained once at build:
    -- the tabs are placed LEFT-of-the-previous-one, so hiding one in the
    -- middle would leave a hole exactly where it used to be.
    local prevShown
    for _, tab in ipairs(tabButtons or {}) do
        if (perTree[tab.treeKey] or 0) > 0 then
            tab:ClearAllPoints()
            if prevShown then
                tab:SetPoint("LEFT", prevShown, "RIGHT", 4, 0)
            else
                tab:SetPoint("TOPLEFT", frame, "TOPLEFT", CARD_INSET + 4, -48)
            end
            tab:Show()
            prevShown = tab
            -- House idiom (gold active state) rather than locking the Blizzard
            -- template into PUSHED. ⚠ Guarded: SetButtonActive reaches into
            -- `button.text`, which only kit buttons have -- on the raw fallback it
            -- would be a nil index, so that path keeps the old behaviour.
            KitSetActive(tab, tab.treeKey == db.tree)
        else
            tab:Hide()
        end
    end

    if treeNote then
        for _, t in ipairs(TREES) do
            if t.key == db.tree then treeNote:SetText(t.note) end
        end
    end
end

-- (Re)builds one card per entry in the current `STATS` -- called once from
-- BuildFrame (using whatever DEFAULT_STATS/STATS holds at that point) and
-- again from CommitDefinitions once the server's real list replaces it.
-- WoW 3.3.5a has no way to truly destroy a frame, so a rebuild just hides
-- the old cards and orphans them (harmless -- in practice this only ever
-- runs a second time if a server admin hot-reloads definitions and the
-- client re-requests ANIMALIST, not on every login).
local function RebuildCards()
    if not frame then return end
    for _, card in ipairs(cards or {}) do card:Hide() end
    cards = {}
    for i, def in ipairs(STATS) do
        cards[i] = BuildCard(frame, def)
    end
    Relayout()
end

local function RefreshAll()
    if not frame then return end
    if pointsText then
        pointsText:SetText(string.format("Anima: |cffffd100%s|r", Comma(arenaPoints)))
    end
    -- Deliberately NOT gated on definitions having arrived: a server build
    -- that doesn't implement ANIMALIST yet will never send ANIMALISTEND, and
    -- the addon should keep working fine off DEFAULT_STATS + live ANIMASTAT
    -- numbers in that case rather than showing "Waiting..." forever.
    if statusText then
        statusText:SetText(haveData and "" or "|cff888888Waiting for the server...|r")
    end
    for _, card in ipairs(cards or {}) do
        RefreshCard(card)
    end
end

-- Lives inside the Dashboard's content panel (see EmbedInto below) -- no own
-- backdrop/title/close/drag, since the Dashboard's master window already
-- provides all of that chrome. Cards stretch horizontally with whatever
-- width the Dashboard window currently has (see Relayout's TOPLEFT+TOPRIGHT
-- anchors); the card interiors already anchored off their own right edge,
-- so they needed no further changes.
local function BuildFrame(parent)
    if frame then return end

    frame = CreateFrame("Frame", "UncappedAnimaFrame", parent or UIParent)
    frame:SetPoint("TOPLEFT"); frame:SetPoint("BOTTOMRIGHT")
    frame:Hide()

    local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", frame, "TOPLEFT", CARD_INSET + 4, -16)
    subtitle:SetPoint("RIGHT", frame, "RIGHT", -(CARD_INSET + 4), 0)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetTextColor(0.75, 0.75, 0.75)
    -- The "(formerly Arena Points)" tail is the ONE transition string in the whole
    -- rename -- players called this currency Arena Points for weeks. Delete this
    -- parenthetical once the new name has settled; nothing else depends on it.
    subtitle:SetText("Two upgrade trees, bought with Anima (formerly Arena Points). A stat only pays off if you are actually limited by it -- pick your poison.")

    -- Tree tabs
    tabButtons = {}
    local prevTab
    for i, t in ipairs(TREES) do
        local tab = KitButton(frame, "", 110, 22)
        if prevTab then
            tab:SetPoint("LEFT", prevTab, "RIGHT", 4, 0)
        else
            tab:SetPoint("TOPLEFT", frame, "TOPLEFT", CARD_INSET + 4, -48)
        end
        tab:SetText(t.label)
        tab.treeKey = t.key
        tab:SetScript("OnClick", function(self)
            db.tree = self.treeKey
            Relayout()
            RefreshAll()
        end)
        tabButtons[i] = tab
        prevTab = tab
    end

    treeNote = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    treeNote:SetPoint("TOPLEFT", frame, "TOPLEFT", CARD_INSET + 4, -74)
    treeNote:SetPoint("RIGHT", frame, "RIGHT", -(CARD_INSET + 4), 0)
    treeNote:SetJustifyH("LEFT")
    treeNote:SetTextColor(0.65, 0.65, 0.65)

    pointsText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pointsText:SetPoint("TOPLEFT", frame, "TOPLEFT", CARD_INSET + 4, -102)

    statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(CARD_INSET + 4), -102)

    -- Cards are windowed into this the same way Soul Forge windows its
    -- equipped-gear list: FauxScrollFrame_Update/GetOffset drive which
    -- cards are currently shown (see Relayout), and OnSizeChanged
    -- recomputes how many full rows fit whenever the Dashboard window is
    -- resized. The right inset leaves room for the auto-created scrollbar.
    animaScroll = CreateFrame("ScrollFrame", "UncappedAnimaScroll", frame, "FauxScrollFrameTemplate")
    animaScroll:SetPoint("TOPLEFT", frame, "TOPLEFT", CARD_INSET + 4, -118)
    animaScroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -(CARD_INSET + 4 + 20), 48)
    animaScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, Relayout)
    end)
    animaScroll:EnableMouseWheel(true)
    animaScroll:SetScript("OnMouseWheel", function(self, delta)
        local sb = _G["UncappedAnimaScrollScrollBar"]
        if sb then sb:SetValue(sb:GetValue() - delta * ROW_H) end
    end)
    animaScroll:SetScript("OnSizeChanged", function(self, w, h)
        -- Width changes need a relayout too (card width tracks it, see
        -- MIN_CARD_WIDTH), not just height/row-count changes, so this
        -- always refreshes rather than gating on visibleRows alone.
        visibleRows = math.max(1, math.floor(h / ROW_H))
        Relayout()
    end)

    RebuildCards()

    local footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", CARD_INSET + 4, 16)
    footer:SetPoint("RIGHT", frame, "RIGHT", -(CARD_INSET + 4), 0)
    footer:SetJustifyH("LEFT")
    footer:SetText("Hover a button for its exact cost. Purchases are charged and applied by the server.")
end

-- ===========================================================================
-- Dashboard embedding
-- ===========================================================================
-- The Dashboard hosts this panel directly inside its own window instead of
-- Anima owning a window of its own -- see UncappedDashboard_UI.lua, which
-- calls EmbedInto once (to build the frame into its content group) and
-- Activate every time the Anima tab is selected.
local Anima = _G.UncappedAnima or {}
_G.UncappedAnima = Anima
Anima.UI = {}

function Anima.UI.EmbedInto(parent)
    BuildFrame(parent)
    frame:Show()
    return frame
end

function Anima.UI.Activate()
    if not frame then return end
    Relayout()
    RequestState()   -- always refresh on fresh numbers
    RefreshAll()
end

-- Content-panel width (not window width) Anima needs so a card's buy-button
-- row (+1/+10/+100/Max: 98*4 + 4*3 = 404, starting 10px in from the card's
-- own edge) doesn't overflow: 404 + 10 left + 10 right padding = 424, plus
-- the card's own 20px insets on each side of the frame (CARD_INSET+4) = 464,
-- plus the embedded group's own 6px padding on each side = 476, +4 buffer.
function Anima.UI.GetMinWidth()
    return 480
end

-- Full WINDOW height (not content height) Anima needs to show all 4 cards
-- of a tree without scrolling: 4 * ROW_H (104) = 416, plus animaScroll's own
-- 118px top offset and 48px bottom reserve (see BuildFrame) = 582, plus the
-- window chrome above/around the content area (nav-panel top/bottom insets
-- + the embedded group's own padding) = 72, +2 buffer.
function Anima.UI.GetMinHeight()
    return 656
end

-- Switches the Dashboard to the Anima tab, opening it if it's closed. Used
-- by the settings-page "Open Anima" button -- Anima has no window of its own
-- anymore to open directly.
local function OpenInDashboard()
    local Dashboard = _G.UncappedDashboard
    if not Dashboard then
        DEFAULT_CHAT_FRAME:AddMessage("|cff40c0f0Anima:|r now lives inside the Dashboard -- load UncappedDashboard to use it.")
        return
    end
    Dashboard.SetTab("anima")
    if not (Dashboard.UI and Dashboard.UI.IsShown and Dashboard.UI.IsShown()) then
        Dashboard.Toggle()
    end
end

-- ===========================================================================
-- Protocol
-- ===========================================================================

-- ANIMASTAT:<stat>:<rank>:<maxRank>:<pctx100>:<maxPctx100>:<c1>:<c10>:<c100>:<cMax>
local function HandleStat(body)
    local idx, rank, maxRank, pct, maxPct, c1, c10, c100, cMax =
        string.match(body, "^ANIMASTAT:(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)$")
    if not idx then return end

    -- maxPct is on the wire but deliberately NOT stored: nothing reads it.
    -- The ceiling is conveyed to the player through each stat's `help` text
    -- instead, which is where the server-side wording lives.
    state[tonumber(idx)] = {
        rank    = tonumber(rank),
        maxRank = tonumber(maxRank),
        pct     = tonumber(pct),
        cost    = {
            c1   = tonumber(c1),
            c10  = tonumber(c10),
            c100 = tonumber(c100),
            cMax = tonumber(cMax),
        },
    }
end

-- ---------------------------------------------------------------------------
-- Stat/spell DEFINITIONS (name/icon/blurb/help/tree) -- requested by
-- RequestDefinitions (ANIMALIST), as opposed to HandleStat's live numbers.
-- Three line types accumulate into defStaging keyed by wire index (order not
-- guaranteed), committed to STATS as a batch on ANIMALISTEND. Freeform text
-- (name/blurb/help) is always the LAST field on its line, captured with
-- `(.+)$` the same way ANIMAERR's message text is below -- safe even if the
-- text itself contains a colon.
--
--   ANIMADEF:<index>:<tree>:<spellId>:<name>
--   ANIMABLURB:<index>:<blurb>
--   ANIMAHELP:<index>:<help>
--   ANIMALISTEND
-- ---------------------------------------------------------------------------
local function StagedDef(index)
    defStaging[index] = defStaging[index] or { index = index }
    return defStaging[index]
end

local function HandleDef(body)
    local idx, tree, spellId, name = string.match(body, "^ANIMADEF:(%d+):(%a+):(%d+):(.+)$")
    if not idx then return end
    local def = StagedDef(tonumber(idx))
    def.tree = tree
    def.icon = tonumber(spellId)
    def.name = name
end

local function HandleBlurb(body)
    local idx, blurb = string.match(body, "^ANIMABLURB:(%d+):(.+)$")
    if not idx then return end
    StagedDef(tonumber(idx)).blurb = blurb
end

local function HandleHelp(body)
    local idx, help = string.match(body, "^ANIMAHELP:(%d+):(.+)$")
    if not idx then return end
    StagedDef(tonumber(idx)).help = help
end

-- Assigned by the settings-page block near the bottom of this file, which is
-- built after this function is defined. Nil when UncappedUI is absent.
local RefreshSettingsDoc

-- Swaps STATS over to the staged definitions, sorted by wire index, and
-- rebuilds the actual card frames to match -- see RebuildCards. A def
-- missing any of tree/icon/name (an ANIMADEF line never arrived, only a
-- stray ANIMABLURB/ANIMAHELP for an index the server never defined) is
-- dropped rather than rendered half-built.
local function CommitDefinitions()
    local list = {}
    for _, def in pairs(defStaging) do
        -- [DP-03] A retired tree is dropped here, not rendered and then
        -- refused at the till.
        if def.tree and def.icon and def.name and not RETIRED_TREES[def.tree] then
            list[#list + 1] = def
        end
    end
    table.sort(list, function(a, b) return a.index < b.index end)

    STATS = list
    IndexStats()
    RebuildCards()
    RefreshAll()
    -- [DP-02] The ESC > Interface page documents whatever STATS now holds.
    -- It used to be built once in the main chunk off DEFAULT_STATS and never
    -- touched again, so it described the retired Defence tree forever and
    -- never mentioned a server-defined stat such as Multicast.
    if RefreshSettingsDoc then RefreshSettingsDoc() end
end

local ERRORS = {
    disabled         = "These stats are currently disabled on this realm.",
    bad_stat         = "That stat does not exist.",
    max_rank         = "You are already at maximum rank in that stat.",
    not_enough_arena = "You do not have enough Anima for that.",
    parse            = "The server could not read that request.",
    -- The Defence tree (Evasion / Deflection / Bulwark / Resolve) was retired on
    -- 2026-08-12 and every rank refunded. The server refuses the purchase with
    -- this token; without an entry here the lookup fell through to `ERRORS[err]
    -- or err` below and printed the raw string "coming_soon" at the player.
    --
    -- ★ [DP-03] The cards themselves are gone now: the server still sends
    --   all ten stats, but RETIRED_TREES filters the defence four out in
    --   CommitDefinitions and Relayout hides a tree tab with no cards under
    --   it. This string is the belt to that braces -- it still fires if the
    --   server ever refuses a stat the client had no reason to doubt.
    coming_soon      = "That stat has been retired. Your ranks in it were refunded.",
}

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff40c0f0Anima:|r " .. msg)
end

local function HandleMessage(body)
    if string.sub(body, 1, 9) == "ANIMASTAT" then
        HandleStat(body)
        return
    end

    if string.sub(body, 1, 8) == "ANIMADEF" then
        HandleDef(body)
        return
    end

    if string.sub(body, 1, 10) == "ANIMABLURB" then
        HandleBlurb(body)
        return
    end

    if string.sub(body, 1, 9) == "ANIMAHELP" then
        HandleHelp(body)
        return
    end

    if body == "ANIMALISTEND" then
        CommitDefinitions()
        return
    end

    local pts = string.match(body, "^ANIMAPTS:(%d+)$")
    if pts then
        arenaPoints = tonumber(pts)
        return
    end

    if body == "ANIMAEND" then
        haveData = true
        RefreshAll()
        return
    end

    local statIdx, count, cost = string.match(body, "^ANIMABOUGHT:(%d+):(%d+):(%d+)$")
    if statIdx then
        local def = STATS_BY_INDEX[tonumber(statIdx)]
        Print(string.format("Bought %s %s for |cffffd100%s|r Anima.",
            Comma(count), def and def.name or "rank", Comma(cost)))
        return
    end

    local err = string.match(body, "^ANIMAERR:(.+)$")
    if err then
        Print("|cffff6060" .. (ERRORS[err] or err) .. "|r")
        return
    end
end

-- ===========================================================================
-- Settings page under the shared "Uncapped" hub (guarded -- the widget library
-- is provided by another addon and may be absent).
-- ===========================================================================
if UncappedUI then
    local panel, L = UncappedUI.CreatePanel("Anima",
        "Anima-bought upgrade trees. The list below is built from whatever the server actually offers, so it cannot drift out of date.")

    L:Header("Opening the window")
    L:Note("Type /dashboard, or click the button below. The window always refreshes from the server when it opens, so the ranks and prices you see are live.", 40)

    local btn = KitButton(panel, "", 160, 22)
    btn:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, L.y)
    btn:SetText("Open Anima")
    btn:SetScript("OnClick", function()
        if InterfaceOptionsFrame then InterfaceOptionsFrame:Hide() end
        OpenInDashboard()
    end)
    L:advance(32)

    -- ★ [DP-02] Rebuildable, not baked at load.
    --
    -- This block runs in the main chunk, long before ANIMALISTEND, so STATS is
    -- still DEFAULT_STATS here. Built once, the page therefore documented the
    -- fallback table for the whole session: it described all four retired
    -- Defence stats in the present tense, printed a Utility header with
    -- nothing under it (both live utility stats exist only server-side), and
    -- never mentioned Multicast. CommitDefinitions now calls back into this.
    --
    -- 3.3.5a cannot destroy a FontString, so a rebuild hides the old ones and
    -- rewinds the layout cursor to where the generated section began.
    local docStrings = {}
    local docStartY  = L.y

    RefreshSettingsDoc = function()
        for _, fs in ipairs(docStrings) do fs:Hide() end
        docStrings = {}
        L.y = docStartY

        for _, t in ipairs(TREES) do
            local rows = {}
            for _, def in ipairs(STATS) do
                if def.tree == t.key then rows[#rows + 1] = def end
            end
            -- A tree the server offers nothing in gets no header, for the same
            -- reason Relayout hides its tab: an empty section reads as broken.
            if #rows > 0 then
                L:Gap(6)
                docStrings[#docStrings + 1] = L:Header(t.label)
                docStrings[#docStrings + 1] = L:Note(t.note, 44)
                for _, def in ipairs(rows) do
                    docStrings[#docStrings + 1] =
                        L:Note("|cffffd100" .. def.name .. "|r -- " .. (def.help or ""), 44)
                end
            end
        end
    end

    RefreshSettingsDoc()

    UncappedAnimaPanel = panel
end

-- ===========================================================================
-- Events / slash
-- ===========================================================================
-- No standalone /anima command: this window is a Dashboard tab now, opened via
-- /dashboard, so a dedicated slash command would just duplicate that entry point.

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:SetScript("OnEvent", function(self, e, a1, a2)
    e  = e  or event
    a1 = a1 or arg1
    a2 = a2 or arg2

    if e == "ADDON_LOADED" then
        -- UncappedDashboard, not UncappedAnima: this file ships inside the
        -- Dashboard now, so that is the addon whose SavedVariables load. The
        -- main-chunk InitDB() above runs before they do, and `db` would keep
        -- pointing at the throwaway table it made.
        if a1 == "UncappedDashboard" then
            InitDB()
        end
    elseif e == "PLAYER_ENTERING_WORLD" then
        -- Prime the cache so the first /anima opens already populated. The
        -- window itself re-requests on open, so a dropped message here only
        -- costs the very first frame, never a stale price.
        RequestState()
        -- Definitions (name/icon/blurb/help/tree) are requested once here,
        -- not on every Activate like RequestState -- they're definitional,
        -- not live numbers, so there's nothing to refresh by re-asking.
        RequestDefinitions()
    elseif e == "CHAT_MSG_ADDON" then
        if a1 == ADDON_PIPE_PREFIX and a2 and string.sub(a2, 1, 5) == "ANIMA" then
            HandleMessage(a2)
        end
    end
end)


-- ---------------------------------------------------------------------------
-- The Anima rename, applied to the STOCK Blizzard UI.
--
-- The currency this realm calls Anima is, to a 3.3.5 client, still arena points.
-- So the character sheet's currency line, the PvP frame, the merchant
-- alt-currency tooltips and every "you don't have enough arena points" error
-- still said "Arena Points" after the server-side rename -- which is worse than
-- not renaming it at all, because the player is now holding two names for one
-- thing and no way to know they mean the same currency.
--
-- ⚠ THIS IS A DISCOVERY SWEEP, NOT A LIST. Hardcoding the global names is how a
-- rename ships having missed three strings nobody thought of. The client already
-- knows which of its own globals mention arena points, so it is asked rather than
-- guessed: every _G entry that is a string and mentions the phrase gets rewritten.
-- Format specifiers survive untouched because only the words are replaced.
--
-- Deliberately NOT renamed: the word "arena" on its own. Arena Team, arena
-- rating, the arena queue -- those are real arenas, not this currency.
--
-- Runs at PLAYER_LOGIN rather than ADDON_LOADED so that every other addon's
-- strings are already in place and get renamed too. The stock frames that show
-- this currency all build their text at display time from these globals, so
-- rewriting the globals is enough; there is nothing to repaint.
local ANIMA_RENAME_PAIRS = {
    { "Arena Points", "Anima" },
    { "Arena Point",  "Anima" },
    { "arena points", "anima" },
    { "arena point",  "anima" },
    { "ARENA POINTS", "ANIMA" },
    { "ARENA POINT",  "ANIMA" },
}

local function ApplyAnimaRename()
    -- Assigning to keys that already exist is safe during pairs(); only ADDING
    -- keys mid-iteration is undefined, and nothing here adds one.
    for key, value in pairs(_G) do
        -- [DP-13] Two plain finds gate the six-pair loop instead of running it
        -- on every string global in the client. Every needle in the table
        -- contains "rena" or, in the SHOUTING variant, "RENA", so this is
        -- exactly equivalent -- it just stops ~12,000 strings paying for six
        -- string.find calls each at PLAYER_LOGIN to match none of them.
        if type(key) == "string" and type(value) == "string"
           and (string.find(value, "rena", 1, true) or string.find(value, "RENA", 1, true)) then
            local rewritten = value
            for _, pair in ipairs(ANIMA_RENAME_PAIRS) do
                -- plain=true on the find: a stray '%' or '-' in a Blizzard string
                -- must not be read as a pattern.
                if string.find(rewritten, pair[1], 1, true) then
                    rewritten = string.gsub(rewritten, pair[1], pair[2])
                end
            end
            if rewritten ~= value then
                _G[key] = rewritten
            end
        end
    end
end

local animaRenameFrame = CreateFrame("Frame")
animaRenameFrame:RegisterEvent("PLAYER_LOGIN")
animaRenameFrame:SetScript("OnEvent", function()
    ApplyAnimaRename()
end)
