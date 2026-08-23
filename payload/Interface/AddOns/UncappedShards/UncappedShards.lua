--[[ Shards of the Seven -- client half.

     Two windows:
       * the LEDGER (/shards)  -- all seven listed whether held or not, the three
                                  slots, and a detail pane showing the selected
                                  shard's breakpoint ladder and progress along it.
       * the RITE              -- opened by the server when a Mythic+ run completes.
                                  It gates the M+ loop, so four other people are
                                  waiting behind it.

     TRANSPORT
       Outbound state arrives ONLY over the native data pipe (the per-player chat
       channel is retired). Topics:
         SHARD      panel state    "<n>\n" HDR:slots:bestKey:s2:s3  then id:rank:slot:prime
         SHARDRITE  the rite       "<n>\n" HDR:keyLevel:remainingMs then id:from:chance:done
       An empty SHARDRITE payload (0 offers) closes the window -- that is how a
       resolved or timed-out rite dismisses itself without a second message type.

       Inbound is addon messages and structurally always will be: a custom opcode is
       server->client only, because the DLL has no idea when the session is ready.
         SHDGET / SHDEQUIP:<id>:<slot> / SHDUNEQUIP:<slot> / SHDTRY:<id>

     ⚠ IF THIS FILE IS STALE AND THE SERVER IS NOT, nothing errors -- the DLL routes a
       topic only to whichever addon registered it, so the frame goes to nobody and the
       window is simply empty. That degrades safely on purpose: the rite's server-side
       timeout TAKES the remaining attempts rather than forfeiting them, so a player on
       an old addon still gets every rank-up, they just do not get to watch. ]]

local ADDON = "UncappedShards"
local TRANSPORT_PREFIX = "REAGENTBANK"

local function Send(msg)
    SendAddonMessage(TRANSPORT_PREFIX, msg, "WHISPER", UnitName("player"))
end

-- ---------------------------------------------------------------------------
-- the catalogue
--
-- Breakpoints are the content, not decoration. With a 500-rank span "rank 62" means
-- nothing on its own -- what a player is climbing toward is the next RUNG. Every
-- ladder here mirrors docs/design/SHARDS_OF_THE_SEVEN.md; if one changes there it
-- has to change here, because this is what a player actually reads.
-- ---------------------------------------------------------------------------

local PRIME, LESSER = true, false

local SHARDS = {
    [1] = { name = "Vorrath",  domain = "Hatred",      prime = PRIME,
            blurb = "Your abilities arc to nearby enemies.",
            steps = { {50,  "arcs may strike targets already hit"},
                      {150, "arcs carry your debuffs"},
                      {300, "your damage scales with how many hate you"},
                      {500, "arcs seek those who hate you most"} } },
    [2] = { name = "Nihilar",  domain = "Terror",      prime = PRIME,
            blurb = "Your abilities stack Dread. At the threshold they tremble --\nstill fighting, but barely.",
            steps = { {50,  "Dread spreads from those who die trembling"},
                      {150, "trembling attacks miss; trembling casters fumble"},
                      {300, "Dread cuts enemy healing and shielding"},
                      {500, "your presence alone applies Dread"} } },
    [3] = { name = "Kharaz",   domain = "Destruction", prime = PRIME,
            blurb = "Every kill stacks Momentum. Stop killing and it leaves you.",
            steps = { {50,  "Momentum decays one stack at a time"},
                      {150, "Momentum also speeds your cooldowns"},
                      {300, "Rampage at high stacks; killing blows refund"},
                      {500, "the window pauses out of combat -- carry a chain"} } },
    [4] = { name = "Quorren",  domain = "Pain",        prime = LESSER,
            blurb = "Agony stacks. What dies carrying it gives back the last\nthree seconds of everything you did to it.",
            steps = { {50,  "slower decay, and a five second window"},
                      {150, "the splash applies Agony to all it catches"},
                      {300, "a splash that kills can splash again"},
                      {500, "the window reaches ten seconds"} } },
    [5] = { name = "Maerith",  domain = "Anguish",     prime = LESSER,
            blurb = "Healing barely reaches you. What strikes you is turned\noutward, and you drink what it lands on.",
            steps = { {50,  "all damage reflects, not only blows"},
                      {150, "surplus becomes a shield"},
                      {300, "the share grows with how many surround you"},
                      {500, "anguish radiates unbidden"} } },
    [6] = { name = "Ulgoth",   domain = "Sin",         prime = LESSER,
            blurb = "What dies stains the ground, and the ground remembers.",
            steps = { {25,  "stains merge where they overlap"},
                      {50,  "stains pull enemies toward their centre"},
                      {100, "merged fields grow a hotter core"},
                      {150, "deaths inside deepen the field"},
                      {250, "the field slows; the pull strengthens"},
                      {350, "a mature field creeps outward"},
                      {500, "it lasts the whole fight"} } },
    [7] = { name = "Thessial", domain = "Lies",        prime = LESSER,
            blurb = "What you kill gets back up, and it is no longer theirs.",
            steps = { {50,  "falsehoods stand longer and strike harder"},
                      {150, "a falsehood's kill raises that corpse too"},
                      {300, "falsehoods detonate as they crumble"},
                      {500, "elites rise, and stand until put down"} } },
}

local ORDER_PRIME  = { 1, 2, 3 }
local ORDER_LESSER = { 4, 5, 6, 7 }

local GOLD  = { 1.00, 0.82, 0.30 }
local RED   = { 0.90, 0.16, 0.16 }
local DIM   = { 0.45, 0.45, 0.48 }
local PALE  = { 0.78, 0.78, 0.82 }
local GREEN = { 0.30, 0.85, 0.35 }

-- ---------------------------------------------------------------------------
-- the gems
--
-- Seven distinct colours, one per Evil. Every path below was checked against the
-- shipped client's MPQs (locale-enUS, patch-enUS, -2, -3) rather than typed from
-- memory: a texture path the client cannot resolve draws a BLACK SQUARE and
-- reports nothing anywhere -- no error, no log line -- so a typo here stays
-- invisible until a player asks why their shard has no picture.
-- ---------------------------------------------------------------------------

local ICON = {
    [1] = "Interface\\Icons\\INV_Misc_Gem_Bloodstone_03",       -- Vorrath   Hatred
    [2] = "Interface\\Icons\\INV_Misc_Gem_EbonDraenite_03",     -- Nihilar   Terror
    [3] = "Interface\\Icons\\INV_Misc_Gem_FlameSpessarite_03",  -- Kharaz    Destruction
    [4] = "Interface\\Icons\\INV_Misc_Gem_Amethyst_03",         -- Quorren   Pain
    [5] = "Interface\\Icons\\INV_Misc_Gem_Sapphire_03",         -- Maerith   Anguish
    [6] = "Interface\\Icons\\INV_Misc_Gem_DeepPeridot_03",      -- Ulgoth    Sin
    [7] = "Interface\\Icons\\INV_Misc_Gem_Opal_03",             -- Thessial  Lies
}
local ICON_SEALED = "Interface\\Icons\\INV_Misc_Gem_Stone_01"

-- Published to UncappedShardsHUD.lua, which needs the same gems and the same
-- palette. Exported rather than duplicated: two copies of a colour table drift,
-- and the drift shows up as a HUD that does not match the panel it belongs to.
UncappedShards_ICON  = ICON
UncappedShards_COLOR = { GOLD = GOLD, RED = RED, DIM = DIM, PALE = PALE, GREEN = GREEN }

-- ---------------------------------------------------------------------------
-- state -- exactly what the last frame said, nothing derived and cached
-- ---------------------------------------------------------------------------

local held    = {}    -- [shardId] = { rank = n, slot = -1|0|1|2, prime = bool }
local hdr     = { slots = 1, bestKey = 0, s2 = 10, s3 = 25 }
local rite    = nil   -- { keyLevel, remainingMs, offers = { {id, from, chance, done} } }
local selected = 1

--[[ Set the first time a SHARD frame arrives; until then the panel has never been told
     anything and an empty ledger is a LIE rather than a fact. See the retry at the
     bottom of this file for why one SHDGET is not enough. ]]
local gotState = false

-- Forward declaration: the event frame is created BEFORE the retry block that defines
-- this, and a `local function` declared later would not be visible to that closure.
local ResetShardStateRetry

-- ---------------------------------------------------------------------------
-- small helpers
-- ---------------------------------------------------------------------------

local function Colour(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end

local function Backdrop(f, alpha)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    f:SetBackdropColor(0, 0, 0, alpha or 0.92)
end

local function Label(parent, size, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetFont("Fonts\\FRIZQT__.TTF", size or 12)
    fs:SetJustifyH(justify or "LEFT")
    return fs
end

-- The rung a rank is walking toward, and how far along it is. Returns nil once every
-- rung is behind you -- past the last breakpoint there is nothing new to show, which
-- is exactly what a soft cap means.
local function NextStep(shardId, rank)
    local def = SHARDS[shardId]
    if not def then return nil end
    local prev = 0
    for _, s in ipairs(def.steps) do
        if rank < s[1] then return s[1], s[2], prev end
        prev = s[1]
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- tooltips
--
-- House shape, the same one UncappedMythic's affix buttons use: a coloured
-- title, a dim subtitle, a blank separator, then body text.
--
-- ⚠ AddLine's FIFTH argument is wrapText, and it is the only thing that stops a
--   long line running off the edge of the screen. A tooltip written without it
--   looks fine on the author's monitor and is unreadable at 1280 wide.
-- ---------------------------------------------------------------------------

local ROMAN = { "I", "II", "III" }

local function ShardTip(owner, shardId, anchor)
    local def = SHARDS[shardId]
    if not def then return end
    local mine = held[shardId]

    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    GameTooltip:AddLine(def.name:upper() .. ", SHARD OF " .. def.domain:upper(),
        RED[1], RED[2], RED[3])
    GameTooltip:AddLine(def.prime and "Prime Evil" or "Lesser Evil",
        DIM[1], DIM[2], DIM[3])
    GameTooltip:AddLine(" ")
    -- The blurb carries a hard newline sized for the panel's fixed width. A
    -- tooltip wraps for itself, so that break would only make a ragged line.
    GameTooltip:AddLine((def.blurb:gsub("\n", " ")), 1, 1, 1, true)

    if mine then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Rank " .. mine.rank, GOLD[1], GOLD[2], GOLD[3])

        -- ★ The rung, not the rank. Across a 500-rank span "rank 62" means
        -- nothing on its own; what a player is climbing toward is the next
        -- breakpoint, so that is what the tooltip leads with.
        local nextAt, what, prevAt = NextStep(shardId, mine.rank)
        if nextAt then
            GameTooltip:AddLine(string.format("Next at %d, %d to go:",
                nextAt, nextAt - mine.rank), 0.62, 0.62, 0.68)
            GameTooltip:AddLine(what, PALE[1], PALE[2], PALE[3], true)
        else
            GameTooltip:AddLine("Every rite is behind you.", 0.62, 0.62, 0.68, true)
        end

        if mine.slot and mine.slot >= 0 then
            GameTooltip:AddLine("Equipped in slot " .. (ROMAN[mine.slot + 1] or "?"),
                GREEN[1], GREEN[2], GREEN[3])
        end
    else
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Not held.", DIM[1], DIM[2], DIM[3])
        GameTooltip:AddLine("Shards drop from kills inside a hotzone and nowhere else. "
            .. "A repeat always rerolls into one you do not have, so nothing is ever wasted.",
            0.62, 0.62, 0.68, true)
    end

    if def.prime then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("At most one Prime Evil may be equipped.", 0.90, 0.60, 0.20, true)
    end

    GameTooltip:Show()
end

local function SlotTip(owner, slotIndex)
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:AddLine("Shard slot " .. (ROMAN[slotIndex + 1] or "?"), GOLD[1], GOLD[2], GOLD[3])

    if slotIndex >= hdr.slots then
        local need = (slotIndex == 1) and hdr.s2 or hdr.s3
        GameTooltip:AddLine("Sealed.", DIM[1], DIM[2], DIM[3])
        GameTooltip:AddLine("Opens when you complete a +" .. need .. " key. "
            .. "Your deepest so far is +" .. hdr.bestKey .. ".", 0.62, 0.62, 0.68, true)
        GameTooltip:Show()
        return
    end

    local occupant
    for id, mine in pairs(held) do
        if mine.slot == slotIndex then occupant = id end
    end

    if occupant then
        GameTooltip:AddLine(SHARDS[occupant].name .. ", rank " .. held[occupant].rank,
            PALE[1], PALE[2], PALE[3])
    else
        GameTooltip:AddLine("Empty.", DIM[1], DIM[2], DIM[3])
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cff808080Left-click places the shard selected on the left. "
        .. "Right-click empties the slot.|r", nil, nil, nil, true)
    -- Said here rather than buried in a help panel: a player who tries to swap
    -- mid-key and is refused should already have been told why, by the thing
    -- they were about to click.
    GameTooltip:AddLine("|cff808080Slots lock once a Mythic+ run is under way -- you may "
        .. "only change them during the opening countdown.|r", nil, nil, nil, true)
    GameTooltip:Show()
end

-- ---------------------------------------------------------------------------
-- the ledger
-- ---------------------------------------------------------------------------

local panel = CreateFrame("Frame", "UncappedShardsPanel", UIParent)
panel:SetSize(620, 420)
panel:SetPoint("CENTER")
panel:SetMovable(true)
panel:EnableMouse(true)
panel:RegisterForDrag("LeftButton")
panel:SetScript("OnDragStart", panel.StartMoving)
panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
panel:SetFrameStrata("DIALOG")
panel:Hide()
Backdrop(panel)
tinsert(UISpecialFrames, "UncappedShardsPanel")   -- Escape closes it

panel.title = Label(panel, 15)
panel.title:SetPoint("TOPLEFT", 20, -18)
panel.title:SetText("SHARDS OF THE SEVEN")
Colour(panel.title, RED)

panel.depth = Label(panel, 11, "RIGHT")
panel.depth:SetPoint("TOPRIGHT", -44, -20)
Colour(panel.depth, DIM)

local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -8, -8)

-- roster rows -------------------------------------------------------------

local rows = {}

local function MakeRow(shardId, y)
    local b = CreateFrame("Button", nil, panel)
    b:SetSize(300, 16)
    b:SetPoint("TOPLEFT", 20, y)

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(14, 14)
    b.icon:SetPoint("LEFT", 0, 0)
    b.icon:SetTexture(ICON[shardId])

    b.mark = Label(b, 12);            b.mark:SetPoint("LEFT", 18, 0)
    b.name = Label(b, 12);            b.name:SetPoint("LEFT", 32, 0)
    b.dom  = Label(b, 11);            b.dom:SetPoint("LEFT", 120, 0)
    b.rank = Label(b, 11, "RIGHT");   b.rank:SetPoint("RIGHT", 0, 0)

    b:SetScript("OnClick", function() selected = shardId; panel:Refresh() end)
    b:SetScript("OnEnter", function(self) ShardTip(self, shardId, "ANCHOR_RIGHT") end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    rows[shardId] = b
    return b
end

do
    local y = -54
    local head1 = Label(panel, 11); head1:SetPoint("TOPLEFT", 20, y); head1:SetText("THE PRIME EVILS")
    Colour(head1, DIM)
    y = y - 18
    for _, id in ipairs(ORDER_PRIME) do MakeRow(id, y); y = y - 17 end

    y = y - 12
    local head2 = Label(panel, 11); head2:SetPoint("TOPLEFT", 20, y); head2:SetText("THE LESSER EVILS")
    Colour(head2, DIM)
    y = y - 18
    for _, id in ipairs(ORDER_LESSER) do MakeRow(id, y); y = y - 17 end
end

-- slots -------------------------------------------------------------------

local slots = {}

for i = 0, 2 do
    local f = CreateFrame("Button", nil, panel)
    f:SetSize(230, 40)
    f:SetPoint("TOPRIGHT", -20, -74 - i * 48)
    Backdrop(f, 0.55)

    f.roman = Label(f, 12);          f.roman:SetPoint("LEFT", 12, 0)

    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(22, 22)
    f.icon:SetPoint("LEFT", 34, 0)

    f.text  = Label(f, 12);          f.text:SetPoint("LEFT", 62, 0)
    f.rank  = Label(f, 12, "RIGHT"); f.rank:SetPoint("RIGHT", -14, 0)

    f:SetScript("OnEnter", function(self) SlotTip(self, i) end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Right-click clears the slot. Left-click puts the selected shard in it, which is
    -- the whole interaction -- pick on the left, place on the right.
    f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f:SetScript("OnClick", function(_, button)
        if SHARD_CLICK_DEBUG then
            DEFAULT_CHAT_FRAME:AddMessage("|cffffdd40shards:|r slot " .. i ..
                " click=" .. tostring(button))
        end
        if button == "RightButton" then
            Send("SHDUNEQUIP:" .. i)
        elseif selected and held[selected] then
            Send("SHDEQUIP:" .. selected .. ":" .. i)
        end
    end)

    slots[i] = f
end

local slotHead = Label(panel, 11)
slotHead:SetPoint("TOPRIGHT", -20, -56)
slotHead:SetText("EQUIPPED")
Colour(slotHead, DIM)

-- detail pane -------------------------------------------------------------

local detail = CreateFrame("Frame", nil, panel)
detail:SetPoint("BOTTOMLEFT", 16, 14)
detail:SetPoint("BOTTOMRIGHT", -16, 14)
detail:SetHeight(150)
Backdrop(detail, 0.45)

detail.title = Label(detail, 13);          detail.title:SetPoint("TOPLEFT", 16, -14)
detail.rank  = Label(detail, 13, "RIGHT"); detail.rank:SetPoint("TOPRIGHT", -16, -14)
detail.blurb = Label(detail, 11);          detail.blurb:SetPoint("TOPLEFT", 16, -34)
detail.blurb:SetWidth(560)

detail.steps = {}
for i = 1, 7 do
    local fs = Label(detail, 11)
    fs:SetPoint("TOPLEFT", 16, -68 - (i - 1) * 13)
    detail.steps[i] = fs
end

detail.bar = CreateFrame("StatusBar", nil, detail)
detail.bar:SetSize(200, 8)
detail.bar:SetPoint("BOTTOMRIGHT", -16, 14)
detail.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
detail.bar:SetStatusBarColor(0.75, 0.15, 0.15)
detail.bar:SetMinMaxValues(0, 1)

detail.barText = Label(detail, 10, "RIGHT")
detail.barText:SetPoint("BOTTOMRIGHT", -16, 26)
Colour(detail.barText, DIM)

-- ---------------------------------------------------------------------------

function panel:Refresh()
    self.depth:SetText("Deepest key: " .. hdr.bestKey)

    for id, def in pairs(SHARDS) do
        local row = rows[id]
        local mine = held[id]

        row.mark:SetText(def.prime and "|cffff3030*|r" or "|cff9080a0o|r")
        row.name:SetText(def.name:upper())
        row.dom:SetText(def.domain)

        row.icon:SetTexture(ICON[id])
        if mine then
            row.icon:SetVertexColor(1, 1, 1)
            row.icon:SetAlpha(1)
        else
            -- The colour drains out of an unheld gem rather than the gem being
            -- hidden: the ledger has to read as a set of seven from the very
            -- first one you find.
            --
            -- ⚠ SetVertexColor, not SetDesaturated. Desaturation is a
            --   driver-level path that silently no-ops on some cards, and a gem
            --   that stays bright reads as "held" on exactly those machines.
            row.icon:SetVertexColor(0.34, 0.34, 0.38)
            row.icon:SetAlpha(0.55)
        end

        if mine then
            row.rank:SetText("rank " .. mine.rank)
            Colour(row.name, id == selected and GOLD or PALE)
            Colour(row.rank, PALE)
            Colour(row.dom,  DIM)
        else
            -- Unfound shards stay listed rather than hidden, so the collection reads
            -- as a set from the very first one you find.
            row.rank:SetText("--")
            Colour(row.name, DIM)
            Colour(row.rank, DIM)
            Colour(row.dom,  DIM)
        end
    end

    for i = 0, 2 do
        local f = slots[i]
        f.roman:SetText(ROMAN[i + 1])
        Colour(f.roman, DIM)

        local occupantId
        for id, mine in pairs(held) do
            if mine.slot == i then occupantId = id end
        end

        if i >= hdr.slots then
            local need = (i == 1) and hdr.s2 or hdr.s3
            f.icon:SetTexture(ICON_SEALED)
            f.icon:SetVertexColor(0.34, 0.34, 0.38)
            f.icon:SetAlpha(0.55)
            f.text:SetText("sealed -- reach a +" .. need .. " key")
            f.rank:SetText("")
            Colour(f.text, DIM)
        elseif occupantId then
            local def = SHARDS[occupantId]
            f.icon:SetTexture(ICON[occupantId])
            f.icon:SetVertexColor(1, 1, 1)
            f.icon:SetAlpha(1)
            f.text:SetText((def.prime and "|cffff3030*|r " or "|cff9080a0o|r ") .. def.name)
            f.rank:SetText(tostring(held[occupantId].rank))
            Colour(f.text, PALE)
            Colour(f.rank, GOLD)
        else
            f.icon:SetTexture(nil)
            f.text:SetText("empty")
            f.rank:SetText("")
            Colour(f.text, DIM)
        end
    end

    local def  = SHARDS[selected]
    local mine = held[selected]
    detail.title:SetText(def.name:upper() .. ", SHARD OF " .. def.domain:upper())
    Colour(detail.title, RED)
    detail.blurb:SetText(def.blurb)
    Colour(detail.blurb, PALE)

    local rank = mine and mine.rank or 0
    detail.rank:SetText(mine and ("RANK " .. rank) or "NOT HELD")
    Colour(detail.rank, mine and GOLD or DIM)

    for i, fs in ipairs(detail.steps) do
        local s = def.steps[i]
        if not s then
            fs:SetText("")
        else
            local done = rank >= s[1]
            fs:SetText(string.format("%s  %-4d %s", done and "|cff40ff40[x]|r" or "|cff707070[ ]|r",
                s[1], s[2]))
            Colour(fs, done and PALE or DIM)
        end
    end

    local nextAt, _, prevAt = NextStep(selected, rank)
    if nextAt and mine then
        local span = nextAt - prevAt
        detail.bar:SetValue(span > 0 and ((rank - prevAt) / span) or 0)
        detail.bar:Show()
        detail.barText:SetText(rank .. " / " .. nextAt)
    else
        detail.bar:Hide()
        -- Past the last rung there is nothing further to unlock. Say so plainly
        -- rather than showing an empty bar that reads as a broken one.
        detail.barText:SetText(mine and "every rite is behind you" or "")
    end
end

-- ---------------------------------------------------------------------------
-- the rite
--
-- Gates the Mythic+ loop, so its friction is paid by four other people. It is
-- deliberately small, always in the same place, and closes itself the moment the
-- server says there is nothing left to answer.
-- ---------------------------------------------------------------------------

local rrite = CreateFrame("Frame", "UncappedShardsRite", UIParent)
rrite:SetSize(380, 210)
rrite:SetPoint("CENTER", 0, 120)
rrite:SetFrameStrata("FULLSCREEN_DIALOG")
rrite:Hide()
Backdrop(rrite)

rrite.title = Label(rrite, 15, "CENTER")
rrite.title:SetPoint("TOP", 0, -18)
rrite.title:SetText("THE SHARDS STIR")
Colour(rrite.title, RED)

rrite.sub = Label(rrite, 11, "CENTER")
rrite.sub:SetPoint("TOP", 0, -38)
Colour(rrite.sub, DIM)

rrite.timer = Label(rrite, 11, "RIGHT")
rrite.timer:SetPoint("BOTTOMRIGHT", -20, 16)
Colour(rrite.timer, DIM)

rrite.rows = {}
for i = 1, 3 do
    local r = CreateFrame("Frame", nil, rrite)
    r:SetSize(340, 26)
    r:SetPoint("TOPLEFT", 20, -60 - (i - 1) * 32)

    -- The gem sits INSIDE the row, not hanging off its left edge: the row starts
    -- at x=20 in a frame whose backdrop insets 6, so anything at a negative
    -- offset here is drawn outside the window.
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(18, 18)
    r.icon:SetPoint("LEFT", 0, 0)

    r.name   = Label(r, 12);          r.name:SetPoint("LEFT", 24, 0)
    r.change = Label(r, 11);          r.change:SetPoint("LEFT", 140, 0)
    -- Sits just left of the TRY button (70 wide), not past the frame edge.
    r.chance = Label(r, 11, "RIGHT"); r.chance:SetPoint("RIGHT", -78, 0)

    r.btn = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
    r.btn:SetSize(70, 20)
    r.btn:SetPoint("RIGHT", 0, 0)
    r.btn:SetText("TRY")

    -- The rite gates four other people's loop, so its tooltip answers the one
    -- question worth asking here and nothing else: what does this rank buy?
    r:EnableMouse(true)
    r:SetScript("OnEnter", function(self)
        if self.shardId then ShardTip(self, self.shardId, "ANCHOR_LEFT") end
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)

    rrite.rows[i] = r
end

function rrite:Refresh()
    if not rite or #rite.offers == 0 then
        self:Hide()
        return
    end

    self.sub:SetText("a +" .. rite.keyLevel .. " key, held")

    for i, r in ipairs(self.rows) do
        local o = rite.offers[i]
        if not o then
            -- Cleared, not just hidden: a stale shardId on a reused row would
            -- put the wrong shard's tooltip on the next rite.
            r.shardId = nil
            r:Hide()
        else
            r:Show()
            local def = SHARDS[o.id]
            r.shardId = o.id
            r.icon:SetTexture(ICON[o.id])
            r.name:SetText((def.prime and "|cffff3030*|r " or "|cff9080a0o|r ") .. def.name:upper())
            Colour(r.name, PALE)

            if o.done then
                r.change:SetText("")
                r.chance:SetText(o.rose and "|cff40ff40ROSE|r" or "|cff808080unmoved|r")
                r.btn:Hide()
            else
                r.change:SetText(o.from .. "  ->  " .. (o.from + 1))
                Colour(r.change, DIM)
                r.chance:SetText(o.chance >= 1 and "certain"
                    or string.format("%d%%", math.floor(o.chance * 100 + 0.5)))
                Colour(r.chance, o.chance >= 1 and GOLD or PALE)
                r.btn:Show()
                r.btn:SetScript("OnClick", function()
                    r.btn:Hide()             -- one press per shard; no double-sends
                    Send("SHDTRY:" .. o.id)
                end)
            end
        end
    end

    self:Show()
end

-- The countdown ticks client-side off the single remainingMs the server sent. Pushing
-- a frame per second per player, for five players, for a purely cosmetic number, would
-- be a packet storm for nothing -- and the server's timeout is authoritative regardless
-- of what this shows.
--
-- ⚠ REBASED OFF GetTime(), NEVER ACCUMULATED FROM `elapsed`. Summing elapsed
--   drifts with framerate and loses whole seconds across a stall or a loading
--   screen -- and on a 30-second window that leaves the number a waiting group
--   is staring at disagreeing with the server's authoritative timeout. This is
--   the shape UncappedMythic's HUD already uses (`limit - (GetTime() - start)`).
--
-- ⚠ ...and only when the displayed SECOND actually changes. The value ticks
--   once a second, so formatting it and calling SetText on every frame was
--   sixty string allocations and sixty font-string repaints per second for one
--   visible change -- and this window opens in the one moment four other
--   players are sitting waiting on it.
local riteShownSec = -1

rrite:SetScript("OnUpdate", function(self)
    if not rite or not rite.baseAt then return end
    local left = rite.remainingMs - (GetTime() - rite.baseAt) * 1000
    if left < 0 then left = 0 end
    local sec = math.floor(left / 1000)
    if sec ~= riteShownSec then
        riteShownSec = sec
        self.timer:SetText(string.format("0:%02d", sec))
    end
end)

-- ---------------------------------------------------------------------------
-- parsing
--
-- One parser per topic, both fed the same way: a count line, then rows. The count is
-- CHECKED, never trusted -- a truncated frame must render as "something is wrong"
-- rather than as a confident half-list.
-- ---------------------------------------------------------------------------

local function SplitLines(payload)
    local out, at, n = {}, 1, #payload
    while at <= n do
        local nl = payload:find("\n", at, true)
        if not nl then out[#out + 1] = payload:sub(at) break end
        if nl > at then out[#out + 1] = payload:sub(at, nl - 1) end
        at = nl + 1
    end
    return out
end

local function OnShardState(payload)
    gotState = true
    local lines = SplitLines(payload)
    local claimed = tonumber(lines[1] or "0") or 0

    held = {}
    local seen = 0

    for i = 2, #lines do
        local line = lines[i]
        if line:sub(1, 4) == "HDR:" then
            local slots, best, s2, s3 = line:match("^HDR:(%d+):(%d+):(%d+):(%d+)$")
            if slots then
                hdr.slots   = tonumber(slots)
                hdr.bestKey = tonumber(best)
                hdr.s2      = tonumber(s2)
                hdr.s3      = tonumber(s3)
            end
        else
            local id, rank, slot, prime = line:match("^(%d+):(%d+):(-?%d+):(%d+)$")
            if id then
                held[tonumber(id)] = {
                    rank  = tonumber(rank),
                    slot  = tonumber(slot),
                    prime = prime == "1",
                }
                seen = seen + 1
            end
        end
    end

    if seen ~= claimed then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cffff2020Shards:|r the ledger arrived incomplete (" .. seen .. "/" ..
            claimed .. "). Reopen it, and report this if it keeps happening.")
    end

    if not held[selected] then
        -- Keep the detail pane on something real. Prefer the first held shard, and
        -- fall back to Vorrath so the pane is never blank on a fresh character.
        selected = 1
        for id in pairs(held) do selected = id break end
    end

    panel:Refresh()
end

local function OnRite(payload)
    local lines = SplitLines(payload)
    local claimed = tonumber(lines[1] or "0") or 0

    if claimed == 0 then
        rite = nil
        riteShownSec = -1
        rrite:Hide()
        return
    end

    local prev = rite
    rite = { keyLevel = 0, remainingMs = 30000, baseAt = GetTime(), offers = {} }
    riteShownSec = -1

    for i = 2, #lines do
        local line = lines[i]
        if line:sub(1, 4) == "HDR:" then
            local key, ms = line:match("^HDR:(%d+):(%d+)$")
            if key then
                rite.keyLevel    = tonumber(key)
                rite.remainingMs = tonumber(ms)
            end
        else
            local id, from, chance, done = line:match("^(%d+):(%d+):(%d+):(%d+)$")
            if id then
                local offer = {
                    id     = tonumber(id),
                    from   = tonumber(from),
                    chance = tonumber(chance) / 10000,
                    done   = done == "1",
                }
                -- The server does not say WHETHER a resolved attempt succeeded -- the
                -- rank in the SHARD frame does. Compare against what we last knew.
                if offer.done and prev then
                    local mine = held[offer.id]
                    offer.rose = mine and mine.rank > offer.from or false
                end
                rite.offers[#rite.offers + 1] = offer
            end
        end
    end

    rrite:Refresh()
end

-- ---------------------------------------------------------------------------
-- wiring
-- ---------------------------------------------------------------------------

--[[ Registration is conditional, and its absence is not an error. Without the DLL
     UncappedNative simply is not there -- and because the rite's server-side timeout
     TAKES the outstanding attempts rather than forfeiting them, a client that cannot
     see the window still receives every rank-up it earned. ]]
if UncappedNative and UncappedNative.IsAvailable() then
    UncappedNative.Register("SHARD", OnShardState)
    UncappedNative.Register("SHARDRITE", OnRite)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        UncappedShardsDB = UncappedShardsDB or {}
        return
    end

    --[[ Ask for state here, not at file load: the addon pipe is not usable until the
         world is in. This request is also what makes a stale-addon client self-heal --
         the moment this file is new enough to have registered the topics, the very
         next SHDGET fills both windows. ]]
    -- Re-arm the retry below on EVERY entry, not just the first: a reconnect or a
    -- worldserver restart under a live client comes back through here too.
    gotState = false
    ResetShardStateRetry()
    Send("SHDGET")
end)

--[[ ★★ ONE SHDGET IS NOT ENOUGH, AND THE FAILURE IS SILENT.

     The reply comes back over the NATIVE pipe, and the server will only put a frame on
     that pipe once the client has announced "NATIVE:<version>" -- an announcement sent by
     UncappedUI, a DIFFERENT addon, also at PLAYER_ENTERING_WORLD. Whoever fires first
     wins. If our SHDGET gets there first, UncappedNativeChannel::Send returns false, the
     snapshot is DISCARDED, and nothing retries: the ledger sits empty for the whole
     session and reads exactly like "you own no shards".

     That is not a theoretical race. Across a day of logins the client received precisely
     ONE state frame -- the very first one, when the ordering happened to fall the other
     way -- and every relog after it showed an empty ledger over a database holding six
     shards.

     So: keep asking until an answer arrives. Cheap (a handful of addon messages, only on
     the way in), self-limiting, and it also covers a worldserver that restarts under a
     client that stays connected. ]]
local RETRY_EVERY  = 2.0
local RETRY_FOR    = 20.0
local retry = CreateFrame("Frame")
local sinceLast, sinceEnter = 0, 0

ResetShardStateRetry = function()
    sinceLast, sinceEnter = 0, 0
end

retry:SetScript("OnUpdate", function(_, elapsed)
    if gotState then return end
    sinceEnter = sinceEnter + elapsed
    if sinceEnter > RETRY_FOR then return end

    sinceLast = sinceLast + elapsed
    if sinceLast < RETRY_EVERY then return end
    sinceLast = 0

    if UnitName("player") then
        Send("SHDGET")
    end
end)

SLASH_UNCAPPEDSHARDS1 = "/shards"
SLASH_UNCAPPEDSHARDS2 = "/shard"
SlashCmdList["UNCAPPEDSHARDS"] = function(msg)
    -- `/shards debug` -- echo every slot click and which button caused it. Here because
    -- "the right-click does nothing" has exactly three causes (the click never reaches
    -- the frame, the frame never sends, the server refuses) and only this separates them.
    if msg == "debug" then
        SHARD_CLICK_DEBUG = not SHARD_CLICK_DEBUG
        DEFAULT_CHAT_FRAME:AddMessage("|cffffdd40shards:|r click debug " ..
            (SHARD_CLICK_DEBUG and "|cff40ff40ON|r" or "|cffff4040OFF|r"))
        return
    end

    if panel:IsShown() then
        panel:Hide()
    else
        Send("SHDGET")
        panel:Refresh()
        panel:Show()
    end
end
