-- UncappedTempo
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
-- Everything shown here comes from the server over the TEMPO* protocol (see
-- modules/mod-time-stats). The client is a renderer: it holds no opinion about
-- what a rank costs, what the cap is, or whether you can afford it. Every panel
-- redraw is driven by a fresh TEMPOSTAT block, and the server re-sends that
-- block after every purchase attempt, successful or not.
--
-- 3.3.5a client: no BackdropTemplate, no C_Timer, arg1..argN globals in event
-- handlers on some paths, and GetSpellInfo(id) is the only reliable way to get
-- an icon path that is guaranteed to exist in this client's Spell.dbc.

local ADDON_PIPE_PREFIX = "UNC"           -- server -> client replies
local TRANSPORT_PREFIX  = "REAGENTBANK"   -- client -> server transport (shared)

local TITLE = "Tempo"

local FRAME_WIDTH  = 470
local CARD_HEIGHT  = 84
local CARD_INSET   = 16

-- ---------------------------------------------------------------------------
-- Stat definitions. `index` is the server's wire index -- the order is part of
-- the protocol contract (see StatId in time_stats.cpp), so this table is
-- append-only and must not be reordered.
--
-- `icon` is a spell id, not a texture path: GetSpellInfo reads the client's own
-- Spell.dbc, so the icon is guaranteed to resolve. Hardcoded texture names are
-- how you ship a question mark to everyone -- plenty of icon names that exist
-- on retail were never in 3.3.5a.
-- ---------------------------------------------------------------------------
local STATS = {
    {
        index = 0,
        name  = "Cooldown Reduction",
        icon  = 14185,   -- Preparation
        blurb = "Shortens your ability cooldowns.",
        help  = "Reduces the real cooldown of your abilities. Worth most to specs whose damage is gated behind cooldowns rather than cast time.",
    },
    {
        index = 1,
        name  = "Time Manipulation",
        icon  = 16880,   -- Nature's Grace
        blurb = "Shortens your global cooldown.",
        help  = "Reduces the global cooldown between abilities. Worth most if you are GCD-locked -- that is, if you always have another button ready before the GCD is up.",
    },
    {
        index = 2,
        name  = "Alacrity",
        icon  = 12472,   -- Icy Veins
        blurb = "Shortens your cast times.",
        help  = "Reduces spell cast time. This is the caster's stat: if your damage is limited by how long Fireball takes, nothing else on this list helps you.",
    },
    {
        index = 3,
        name  = "Swiftness",
        icon  = 2825,    -- Bloodlust
        blurb = "Speeds up your melee and ranged attacks.",
        help  = "Reduces melee and ranged swing time. More auto-attacks means more damage and more chances for your item procs to fire.",
    },
}

-- ---------------------------------------------------------------------------
-- SavedVariables
-- ---------------------------------------------------------------------------
local DEFAULTS = {
    lastAmount = 1,   -- remembered buy quantity
}

local db

local function InitDB()
    if type(UncappedTempoDB) ~= "table" then UncappedTempoDB = {} end
    db = UncappedTempoDB
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
    return db
end

InitDB()

-- ---------------------------------------------------------------------------
-- Server-supplied state. `state[index]` is filled by TEMPOSTAT lines.
-- ---------------------------------------------------------------------------
local state = {}          -- [wireIndex] = { rank, maxRank, pct, maxPct, cost = {..} }
local arenaPoints = 0
local haveData = false

local frame, cards, pointsText, statusText

local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"

local function Send(msg)
    SendAddonMessage(TRANSPORT_PREFIX, msg, "WHISPER", UnitName("player"))
end

local function RequestState()
    Send("TEMPOOPEN")
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

local function BuildCard(parent, def, yOffset)
    local card = CreateFrame("Frame", nil, parent)
    card:SetWidth(FRAME_WIDTH - (CARD_INSET * 2) - 8)
    card:SetHeight(CARD_HEIGHT)
    card:SetPoint("TOPLEFT", parent, "TOPLEFT", CARD_INSET + 4, yOffset)
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
        local btn = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
        btn:SetHeight(20)
        btn:SetWidth(98)
        if prev then
            btn:SetPoint("LEFT", prev, "RIGHT", 4, 0)
        else
            btn:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -6)
        end
        btn:SetText(amount.label)
        btn.amount = amount
        btn.statIndex = def.index

        btn:SetScript("OnClick", function(self)
            Send(string.format("TEMPOBUY:%d:%d", self.statIndex, self.amount.count))
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
                        string.format("Cost: %s arena points", Comma(cost)),
                        affordable and 0.4 or 1, affordable and 1 or 0.3, affordable and 0.4 or 0.3)
                    if not affordable then
                        GameTooltip:AddLine(string.format("You have %s.", Comma(arenaPoints)), 1, 0.3, 0.3)
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

local function RefreshAll()
    if not frame then return end
    if pointsText then
        pointsText:SetText(string.format("Arena points: |cffffd100%s|r", Comma(arenaPoints)))
    end
    if statusText then
        statusText:SetText(haveData and "" or "|cff888888Waiting for the server...|r")
    end
    for _, card in ipairs(cards or {}) do
        RefreshCard(card)
    end
end

local function BuildFrame()
    if frame then return end

    local height = 118 + (#STATS * (CARD_HEIGHT + 8)) + 30

    frame = CreateFrame("Frame", "UncappedTempoFrame", UIParent)
    frame:SetWidth(FRAME_WIDTH)
    frame:SetHeight(height)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
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
    frame:SetToplevel(true)
    frame:Hide()

    -- Escape closes it, like every other panel in the game.
    tinsert(UISpecialFrames, "UncappedTempoFrame")

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", frame, "TOP", 0, -16)
    title:SetText(TITLE)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)

    local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", frame, "TOPLEFT", CARD_INSET + 4, -42)
    subtitle:SetPoint("RIGHT", frame, "RIGHT", -(CARD_INSET + 4), 0)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetTextColor(0.75, 0.75, 0.75)
    subtitle:SetText("Haste on this realm is converted to crit damage, so these four stats are what actually make you faster. Each one is bought separately -- pick the one your rotation is limited by.")

    pointsText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pointsText:SetPoint("TOPLEFT", frame, "TOPLEFT", CARD_INSET + 4, -92)

    statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(CARD_INSET + 4), -92)

    cards = {}
    local y = -112
    for i, def in ipairs(STATS) do
        cards[i] = BuildCard(frame, def, y)
        y = y - (CARD_HEIGHT + 8)
    end

    local footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", CARD_INSET + 4, 16)
    footer:SetPoint("RIGHT", frame, "RIGHT", -(CARD_INSET + 4), 0)
    footer:SetJustifyH("LEFT")
    footer:SetText("Hover a button for its exact cost. Purchases are charged and applied by the server.")
end

local function Toggle()
    BuildFrame()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        RequestState()   -- always open on fresh numbers
        RefreshAll()
    end
end

-- ===========================================================================
-- Protocol
-- ===========================================================================

-- TEMPOSTAT:<stat>:<rank>:<maxRank>:<pctx100>:<maxPctx100>:<c1>:<c10>:<c100>:<cMax>
local function HandleStat(body)
    local idx, rank, maxRank, pct, maxPct, c1, c10, c100, cMax =
        string.match(body, "^TEMPOSTAT:(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)$")
    if not idx then return end

    state[tonumber(idx)] = {
        rank    = tonumber(rank),
        maxRank = tonumber(maxRank),
        pct     = tonumber(pct),
        maxPct  = tonumber(maxPct),
        cost    = {
            c1   = tonumber(c1),
            c10  = tonumber(c10),
            c100 = tonumber(c100),
            cMax = tonumber(cMax),
        },
    }
end

local ERRORS = {
    disabled         = "Tempo stats are currently disabled on this realm.",
    bad_stat         = "That stat does not exist.",
    max_rank         = "You are already at maximum rank in that stat.",
    not_enough_arena = "You do not have enough arena points for that.",
    parse            = "The server could not read that request.",
}

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff40c0f0Tempo:|r " .. msg)
end

local function HandleMessage(body)
    if string.sub(body, 1, 9) == "TEMPOSTAT" then
        HandleStat(body)
        return
    end

    local pts = string.match(body, "^TEMPOPTS:(%d+)$")
    if pts then
        arenaPoints = tonumber(pts)
        return
    end

    if body == "TEMPOEND" then
        haveData = true
        RefreshAll()
        return
    end

    local statIdx, count, cost = string.match(body, "^TEMPOBOUGHT:(%d+):(%d+):(%d+)$")
    if statIdx then
        local def = STATS[tonumber(statIdx) + 1]
        Print(string.format("Bought %s %s for |cffffd100%s|r arena points.",
            Comma(count), def and def.name or "rank", Comma(cost)))
        return
    end

    local err = string.match(body, "^TEMPOERR:(.+)$")
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
    local panel, L = UncappedUI.CreatePanel("Tempo",
        "Cooldown Reduction, Time Manipulation, Alacrity and Swiftness -- the four stats that replace haste on this realm.")

    L:Header("Opening the window")
    L:Note("Type /tempo, or click the button below. The window always refreshes from the server when it opens, so the ranks and prices you see are live.", 40)

    local btn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    btn:SetWidth(160)
    btn:SetHeight(22)
    btn:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, L.y)
    btn:SetText("Open Tempo")
    btn:SetScript("OnClick", function()
        if InterfaceOptionsFrame then InterfaceOptionsFrame:Hide() end
        BuildFrame()
        frame:Show()
        RequestState()
    end)
    L:advance(32)

    L:Gap(6)
    L:Header("What each stat does")
    for _, def in ipairs(STATS) do
        L:Note("|cffffd100" .. def.name .. "|r -- " .. def.help, 40)
    end

    UncappedTempoPanel = panel
end

-- ===========================================================================
-- Events / slash
-- ===========================================================================
SLASH_UNCAPPEDTEMPO1 = "/tempo"
SLASH_UNCAPPEDTEMPO2 = "/uncappedtempo"
SlashCmdList["UNCAPPEDTEMPO"] = function() Toggle() end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:SetScript("OnEvent", function(self, e, a1, a2)
    e  = e  or event
    a1 = a1 or arg1
    a2 = a2 or arg2

    if e == "ADDON_LOADED" then
        if a1 == "UncappedTempo" then
            InitDB()
        end
    elseif e == "PLAYER_ENTERING_WORLD" then
        -- Prime the cache so the first /tempo opens already populated. The
        -- window itself re-requests on open, so a dropped message here only
        -- costs the very first frame, never a stale price.
        RequestState()
    elseif e == "CHAT_MSG_ADDON" then
        if a1 == ADDON_PIPE_PREFIX and a2 and string.sub(a2, 1, 5) == "TEMPO" then
            HandleMessage(a2)
        end
    end
end)
