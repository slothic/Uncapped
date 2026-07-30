--[[
    Stat Feed -- the Dungeon Stats window.

    The server sends stat gains as ADDON messages rather than chat, so they
    never touch the default chat frame. See lua_scripts/dungeonstats.lua, which
    routes them through SendAddonMessage with the prefix below, in the form:

        You received <n> <StatName> for killing <Creature>.
        Your pet also received <n> <StatName>.

    On top of the raw feed this tracks what you have earned THIS SESSION: a
    running total, a per-hour pace, and a per-stat breakdown. Pet mirror lines
    are shown in the feed but never counted -- they are the pet's stats, not
    yours.

    Session tracking, the pace counter and the collapse button are based on
    Stat Feed Plus by MentalMonk, folded into the shipped addon.

    Written for the 3.3.5a client: no BackdropTemplate, no C_ namespace, and
    event handlers can read either the arg1..argN globals or the handler
    parameters; 3.3.5 provides both.

    /statfeed          toggle the window          (/sfp is a short alias)
    /statfeed clear    clear the feed log
    /statfeed session  reset the session counters
    /statfeed reset    put the window back in the middle of the screen
]]

local ADDON_NAME   = "StatFeed"
local ADDON_PREFIX = "DSTATS"
local TICK_SECONDS = 1        -- how often the clock/pace repaint while shown

-- ---------------------------------------------------------------------------
-- Layout constants. Everything below the summary block is anchored, not
-- hard-placed, so the window lays out correctly at any size the user drags it
-- to.
-- ---------------------------------------------------------------------------
local PAD          = 12       -- left/right inset
local HEADER_H     = 30       -- title bar
local SUMMARY_ROW  = 22       -- one line of the "this session" block
local STAT_ROW     = 18       -- one stat line
local CREDIT_H     = 16       -- reserved strip at the bottom for the credit
local COMPACT_H    = HEADER_H + (SUMMARY_ROW * 3) + CREDIT_H + 14
local MIN_WIDTH    = 240      -- narrower than this and the stat rows collide
local LOG_MIN_H    = 42       -- ~3 feed lines; below this the feed is pointless
local EXPANDED_MIN            -- smallest usable expanded height; derived below

local DEFAULTS = {
    point      = "CENTER",
    x          = 250,
    y          = 0,
    width      = 340,
    height     = 380,
    shown      = true,
    collapsed  = false,
    maxLines   = 200,
    bgAlpha    = 0.78,
    showBars   = true,
    titleColor = { 0.61, 0.76, 0.26 }, -- |cff9CC243
    layout     = 3,                    -- bump to force a one-time re-size
}

-- Stat display order, matched to what dungeonstats.lua can award. Each entry
-- carries its accent colour and how to read the player's current value, so the
-- update loop is a table walk instead of a chain of comparisons.
local STATS = {
    { key = "Strength",       r = 1.00, g = 0.45, b = 0.38, unitStat = 1 },
    { key = "Agility",        r = 0.58, g = 0.90, b = 0.45, unitStat = 2 },
    { key = "Stamina",        r = 0.98, g = 0.72, b = 0.36, unitStat = 3 },
    { key = "Intellect",      r = 0.45, g = 0.72, b = 1.00, unitStat = 4 },
    { key = "Spirit",         r = 0.82, g = 0.74, b = 1.00, unitStat = 5 },
    { key = "Spell Power",    r = 1.00, g = 0.55, b = 0.92, spellPower = true },
    { key = "Defense Rating", r = 0.66, g = 0.82, b = 0.95, rating = "CR_DEFENSE_SKILL" },
    { key = "Expertise",      r = 1.00, g = 0.86, b = 0.45, rating = "CR_EXPERTISE" },
}

-- Smallest height that still fits the whole expanded window: summary block,
-- every stat row, the divider gap, a usable feed and the credit strip. Derived
-- from the constants above (and from #STATS) so adding a stat or changing a row
-- height can't silently push content out through the bottom of the frame.
EXPANDED_MIN = HEADER_H + 12 + (SUMMARY_ROW * 3)        -- top of the stat block
             + (#STATS * STAT_ROW + 4)                  -- the stat block
             + 12 + LOG_MIN_H                           -- gap + feed
             + (PAD + CREDIT_H - 6)                     -- bottom inset
EXPANDED_MIN = math.ceil(EXPANDED_MIN / 10) * 10

-- Spelling variants the server may send, mapped to the display name above.
-- Keys are lower-cased with spaces/underscores/hyphens/dots removed.
local STAT_ALIASES = {
    str = "Strength",           strength = "Strength",
    agi = "Agility",            agility = "Agility",
    sta = "Stamina",            stam = "Stamina",             stamina = "Stamina",
    int = "Intellect",          intellect = "Intellect",
    spi = "Spirit",             spirit = "Spirit",
    sp = "Spell Power",         spellpower = "Spell Power",   spellpowerrating = "Spell Power",
    def = "Defense Rating",     defense = "Defense Rating",   defence = "Defense Rating",
    defenserating = "Defense Rating",  defencerating = "Defense Rating",
    exp = "Expertise",          expertise = "Expertise",      expertiserating = "Expertise",
}

local C_LABEL  = "|cffe9b518"   -- the server's own gold
local C_AMOUNT = "|cff9CC243"   -- the server's own green
local C_TARGET = "|cff5af304"
local C_GAIN   = "|cff00e5ff"
local C_OFF    = "|cff808080"
local C_RESET  = "|r"

-- Locals for the hot paths (upvalue lookups beat globals in 5.1).
local floor, max, abs, format, gsub, match, lower = math.floor, math.max, math.abs,
    string.format, string.gsub, string.match, string.lower

local frame, log, statBlock
local BuildOptions       -- forward declaration; defined at the bottom
local rows        = {}   -- display name -> widget set
local earned      = {}   -- display name -> gained this session
local totalEarned = 0
local peakStat    = 0    -- largest single-stat gain, for the share bars
local sessionStart = 0
local tickElapsed  = 0
local dirty        = true  -- set when something changed; cleared by Repaint

-- ---------------------------------------------------------------------------
-- Saved variables
-- ---------------------------------------------------------------------------
local function GetDB()
    StatFeedDB = StatFeedDB or {}
    local db = StatFeedDB

    -- Read the saved layout version BEFORE the defaults are filled in: the loop
    -- below would stamp the current version onto an old DB, and the migration
    -- that follows would then think it had already run.
    local savedLayout = db.layout or 0

    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then
            if type(v) == "table" then
                local t = {}
                for i, vv in pairs(v) do t[i] = vv end
                db[k] = t
            else
                db[k] = v
            end
        end
    end

    -- The window grew when the session block was added; resize saved layouts
    -- from before that once, so an old install isn't left with a cramped frame.
    if savedLayout < DEFAULTS.layout then
        db.width  = DEFAULTS.width
        db.height = DEFAULTS.height
        db.layout = DEFAULTS.layout
    end

    -- Belt and braces: the rows, dividers and feed are anchored to the top of
    -- the frame, so a height smaller than the content draws them below the
    -- window's bottom edge. Never trust a saved size that can't hold it.
    if (db.height or 0) < EXPANDED_MIN then db.height = DEFAULTS.height end
    if (db.width or 0) < MIN_WIDTH then db.width = MIN_WIDTH end

    return db
end

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------
local function Commas(value)
    local n = floor((tonumber(value) or 0) + 0.5)
    local text = tostring(abs(n))
    while true do
        local count
        text, count = gsub(text, "^(%d+)(%d%d%d)", "%1,%2")
        if count == 0 then break end
    end
    if n < 0 then return "-" .. text end
    return text
end

-- Compact form for the per-stat column, where totals can run long.
local function Short(value)
    local n = floor((tonumber(value) or 0) + 0.5)
    local a = abs(n)
    local sign = (n < 0) and "-" or ""
    if a >= 1000000 then
        return sign .. format("%.2fm", a / 1000000)
    elseif a >= 10000 then
        return sign .. floor(a / 1000) .. "k"
    end
    return Commas(n)
end

local function Clock(seconds)
    seconds = max(0, floor(seconds or 0))
    return format("%02d:%02d:%02d", floor(seconds / 3600), floor((seconds % 3600) / 60), seconds % 60)
end

local function StripColors(text)
    text = gsub(tostring(text or ""), "|c%x%x%x%x%x%x%x%x", "")
    return (gsub(text, "|r", ""))
end

local function Trim(text)
    text = gsub(tostring(text or ""), "^%s+", "")
    return (gsub(text, "%s+$", ""))
end

local function NormalizeStat(name)
    return STAT_ALIASES[gsub(lower(tostring(name or "")), "[%s_%-%.]", "")]
end

-- Only touch the font string when the text actually changed: SetText on a
-- FontString re-lays it out every call, and most ticks change nothing.
local function SetTextCached(fs, text)
    if fs.cachedText ~= text then
        fs.cachedText = text
        fs:SetText(text)
    end
end

-- ---------------------------------------------------------------------------
-- Reading the player's live stats (for the row totals and the tooltip)
-- ---------------------------------------------------------------------------
local function CurrentStat(info)
    if info.unitStat then
        local _, effective = UnitStat("player", info.unitStat)
        return effective or 0
    elseif info.spellPower then
        local best = 0
        if GetSpellBonusDamage then
            for school = 2, 7 do
                local v = GetSpellBonusDamage(school)
                if v and v > best then best = v end
            end
        end
        if best == 0 and GetSpellBonusHealing then
            best = GetSpellBonusHealing() or 0
        end
        return best
    elseif info.rating then
        local index = _G[info.rating]
        if GetCombatRating and index then
            return GetCombatRating(index) or 0
        end
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- Session bookkeeping
-- ---------------------------------------------------------------------------
local function ResetSession()
    totalEarned = 0
    peakStat    = 0
    for i = 1, #STATS do
        local info = STATS[i]
        earned[info.key]    = 0
        info.startValue     = CurrentStat(info)
    end
    sessionStart = GetTime()
    dirty = true
end

local function CaptureBaseline()
    for i = 1, #STATS do
        local info = STATS[i]
        if not info.startValue or info.startValue == 0 then
            info.startValue = CurrentStat(info)
        end
    end
end

local function RecordGain(amount, statName)
    amount = tonumber(amount)
    local key = NormalizeStat(statName)
    if not amount or amount <= 0 or not key or earned[key] == nil then return end

    totalEarned  = totalEarned + amount
    earned[key]  = earned[key] + amount
    if earned[key] > peakStat then peakStat = earned[key] end
    dirty = true
end

-- ---------------------------------------------------------------------------
-- Painting
-- ---------------------------------------------------------------------------
local function Repaint(force)
    if not frame or not frame:IsShown() then return end

    local elapsed = max(1, GetTime() - sessionStart)
    SetTextCached(frame.totalText, Commas(totalEarned))
    -- Pace is meaningless in the first minute, so the divisor is floored there
    -- rather than letting a single kill read as "180,000 an hour".
    SetTextCached(frame.rateText, Commas(totalEarned * 3600 / max(60, elapsed)))
    SetTextCached(frame.clockText, Clock(elapsed))

    if not (dirty or force) then return end
    dirty = false

    if GetDB().collapsed then return end

    local showBars = GetDB().showBars
    for i = 1, #STATS do
        local info = STATS[i]
        local row  = rows[info.key]
        local gain = earned[info.key] or 0

        if gain > 0 then
            SetTextCached(row.value, Short(CurrentStat(info)) .. "  " .. C_AMOUNT .. "+" .. Short(gain) .. C_RESET)
        else
            SetTextCached(row.value, Short(CurrentStat(info)) .. "  " .. C_OFF .. "+0" .. C_RESET)
        end

        if showBars and gain > 0 and peakStat > 0 then
            row.bar:SetWidth(max(1, (statBlock:GetWidth() - 4) * (gain / peakStat)))
            row.bar:Show()
        else
            row.bar:Hide()
        end
    end
end

-- ---------------------------------------------------------------------------
-- Feed lines
-- ---------------------------------------------------------------------------
local function AddLine(text)
    if log then log:AddMessage(text) end
end

-- Recolour the server's line so the number and the stat name stand out, and
-- spell "DefenseRating" the way the rows do. Falls back to the raw line if the
-- server ever sends something in a shape we don't know.
local function FormatFeedLine(clean)
    local prefix, amount, stat, middle, target =
        match(clean, "^([Yy]ou received )(%d[%d,]*)%s+([%a%s]+)( for killing )(.*)$")
    if prefix then
        return C_LABEL .. prefix .. C_RESET .. C_AMOUNT .. amount .. C_RESET
            .. " " .. C_GAIN .. (NormalizeStat(stat) or Trim(stat)) .. C_RESET
            .. C_LABEL .. middle .. C_RESET .. C_TARGET .. target .. C_RESET
    end

    prefix, amount, stat = match(clean, "^([Yy]our pet a?l?s?o? ?received )(%d[%d,]*)%s+([%a%s]+%.?)$")
    if prefix then
        return C_OFF .. prefix .. C_RESET .. C_AMOUNT .. amount .. C_RESET
            .. " " .. C_GAIN .. (NormalizeStat(gsub(stat, "%.$", "")) or Trim(stat)) .. C_RESET
    end

    return C_LABEL .. clean .. C_RESET
end

local function IsPetLine(clean)
    local l = lower(clean)
    return match(l, "^your pet a?l?s?o? ?received") ~= nil or match(l, "^pet received") ~= nil
end

local function HandleFeed(message)
    local clean = Trim(StripColors(message))
    if clean == "" then return end

    AddLine(FormatFeedLine(clean))

    -- Pet gains mirror to the owner's feed but are the pet's stats; showing
    -- them is useful, counting them would inflate the session total.
    if IsPetLine(clean) then return end

    local amount, stat = match(clean, "^[Yy]ou received (%d[%d,]*) (.-) for killing .+$")
    if amount then
        -- Parenthesised: gsub returns (string, count), and the count would
        -- otherwise slide into the statName argument.
        RecordGain((gsub(amount, ",", "")), stat)
        Repaint()
    end
end

-- ---------------------------------------------------------------------------
-- Collapse / expand
-- ---------------------------------------------------------------------------
local COLLAPSE_TEX = {
    [true]  = { "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up",
                "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Down" },
    [false] = { "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up",
                "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Down" },
}

local function ApplyCollapse()
    if not frame then return end
    local db = GetDB()
    local c  = db.collapsed and true or false

    local tex = COLLAPSE_TEX[c]
    frame.collapseButton:SetNormalTexture(tex[1])
    frame.collapseButton:SetPushedTexture(tex[2])

    if c then
        statBlock:Hide()
        log:Hide()
        frame.midDivider:Hide()
        frame.lowDivider:Hide()
        frame.grip:Hide()
        frame:SetMinResize(MIN_WIDTH, COMPACT_H)
        frame:SetHeight(COMPACT_H)
    else
        statBlock:Show()
        log:Show()
        frame.midDivider:Show()
        frame.lowDivider:Show()
        frame.grip:Show()
        frame:SetMinResize(MIN_WIDTH, EXPANDED_MIN)
        frame:SetHeight(db.height or DEFAULTS.height)
        dirty = true
        Repaint(true)
    end
end

local function SavePosition()
    if not frame then return end
    local db = GetDB()
    local point, _, _, x, y = frame:GetPoint()
    db.point = point or DEFAULTS.point
    db.x     = x or DEFAULTS.x
    db.y     = y or DEFAULTS.y
    db.width = frame:GetWidth()
    if not db.collapsed then
        db.height = frame:GetHeight()
    end
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------
local function Divider(parent, yOffset, anchorTo)
    local shadow = parent:CreateTexture(nil, "ARTWORK")
    shadow:SetTexture(0, 0, 0, 0.85)
    shadow:SetHeight(1)
    local glow = parent:CreateTexture(nil, "ARTWORK")
    glow:SetTexture(0.55, 0.55, 0.55, 0.5)
    glow:SetHeight(1)
    glow:SetPoint("TOPLEFT", shadow, "BOTTOMLEFT", 0, 0)
    glow:SetPoint("TOPRIGHT", shadow, "BOTTOMRIGHT", 0, 0)

    if anchorTo then
        shadow:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, yOffset)
        shadow:SetPoint("TOPRIGHT", anchorTo, "BOTTOMRIGHT", 0, yOffset)
    else
        shadow:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD + 2, yOffset)
        shadow:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -(PAD + 2), yOffset)
    end

    -- One handle that hides/shows both halves.
    return { Show = function() shadow:Show(); glow:Show() end,
             Hide = function() shadow:Hide(); glow:Hide() end }
end

local function SummaryLine(parent, index, label, r, g, b)
    local y = -(HEADER_H + 6 + (index - 1) * SUMMARY_ROW)

    local caption = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    caption:SetPoint("TOPLEFT", PAD + 2, y)
    caption:SetText(label)
    caption:SetTextColor(0.75, 0.75, 0.75)

    local value = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    value:SetPoint("TOPRIGHT", -(PAD + 4), y + 1)
    value:SetTextColor(r, g, b)
    return value
end

local function BuildWindow()
    local db = GetDB()

    frame = CreateFrame("Frame", "StatFeedFrame", UIParent)
    frame:SetWidth(db.width)
    frame:SetHeight(db.height)
    frame:SetPoint(db.point, UIParent, db.point, db.x, db.y)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 16,
        insets = { left = 5, right = 5, top = 5, bottom = 5 }
    })
    frame:SetBackdropColor(0, 0, 0, db.bgAlpha)

    frame:SetMovable(true)
    frame:SetResizable(true)
    frame:SetMinResize(MIN_WIDTH, EXPANDED_MIN)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
        dirty = true
    end)
    -- Bars are sized off the frame width, so a resize has to repaint them.
    frame:SetScript("OnSizeChanged", function() dirty = true end)

    -- Title -----------------------------------------------------------------
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", PAD + 2, -11)
    title:SetText("Stat Feed")
    title:SetTextColor(db.titleColor[1], db.titleColor[2], db.titleColor[3])
    frame.title = title

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 1)
    close:SetScript("OnClick", function()
        frame:Hide()
        GetDB().shown = false
    end)

    local collapse = CreateFrame("Button", nil, frame)
    collapse:SetWidth(26)
    collapse:SetHeight(26)
    collapse:SetPoint("TOPRIGHT", -22, -2)
    collapse:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")
    collapse:GetHighlightTexture():SetBlendMode("ADD")
    collapse:SetScript("OnClick", function()
        local d = GetDB()
        if not d.collapsed then d.height = frame:GetHeight() end
        d.collapsed = not d.collapsed
        ApplyCollapse()
        SavePosition()
    end)
    collapse:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(GetDB().collapsed and "Expand" or "Collapse")
        GameTooltip:Show()
    end)
    collapse:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frame.collapseButton = collapse

    -- A thin accent under the title, fading out to the right.
    local accent = frame:CreateTexture(nil, "ARTWORK")
    accent:SetTexture(1, 1, 1)
    accent:SetHeight(2)
    accent:SetPoint("TOPLEFT", PAD + 2, -(HEADER_H - 4))
    accent:SetPoint("TOPRIGHT", -(PAD + 2), -(HEADER_H - 4))
    if accent.SetGradientAlpha then
        accent:SetGradientAlpha("HORIZONTAL",
            db.titleColor[1], db.titleColor[2], db.titleColor[3], 0.85,
            db.titleColor[1], db.titleColor[2], db.titleColor[3], 0.0)
    else
        accent:SetTexture(db.titleColor[1], db.titleColor[2], db.titleColor[3], 0.6)
    end
    frame.accent = accent

    -- Session summary -------------------------------------------------------
    frame.totalText = SummaryLine(frame, 1, "This session",  0.35, 1.00, 0.20)
    frame.rateText  = SummaryLine(frame, 2, "Stats / hour",  0.30, 0.68, 1.00)
    frame.clockText = SummaryLine(frame, 3, "Session time",  1.00, 0.82, 0.00)

    frame.midDivider = Divider(frame, -(HEADER_H + 6 + SUMMARY_ROW * 3 + 4))

    -- Per-stat rows ---------------------------------------------------------
    statBlock = CreateFrame("Frame", nil, frame)
    statBlock:SetPoint("TOPLEFT", PAD + 2, -(HEADER_H + 12 + SUMMARY_ROW * 3))
    statBlock:SetPoint("TOPRIGHT", -(PAD + 2), -(HEADER_H + 12 + SUMMARY_ROW * 3))
    statBlock:SetHeight(#STATS * STAT_ROW + 4)

    for i = 1, #STATS do
        local info = STATS[i]
        local y    = -((i - 1) * STAT_ROW) - 2
        local row  = {}

        -- Share bar: how big this stat's gain is next to the biggest one.
        -- Sits in BACKGROUND so the text reads over it.
        row.bar = statBlock:CreateTexture(nil, "BACKGROUND")
        row.bar:SetTexture(info.r, info.g, info.b, 0.16)
        row.bar:SetHeight(STAT_ROW - 4)
        row.bar:SetPoint("TOPLEFT", 0, y + 1)
        row.bar:SetWidth(1)
        row.bar:Hide()

        row.name = statBlock:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("TOPLEFT", 2, y)
        row.name:SetWidth(120)
        row.name:SetJustifyH("LEFT")
        row.name:SetText(info.key)
        row.name:SetTextColor(info.r, info.g, info.b)

        row.value = statBlock:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.value:SetPoint("TOPRIGHT", -2, y)
        row.value:SetJustifyH("RIGHT")

        -- Hover target spanning the row, for the starting/current/added detail.
        row.hit = CreateFrame("Frame", nil, statBlock)
        row.hit:SetPoint("TOPLEFT", 0, y + 2)
        row.hit:SetPoint("TOPRIGHT", 0, y + 2)
        row.hit:SetHeight(STAT_ROW)
        row.hit:EnableMouse(true)
        row.hit.info = info
        row.hit:SetScript("OnEnter", function(self)
            local s = self.info
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(s.key, s.r, s.g, s.b)
            GameTooltip:AddLine("At login: " .. Commas(s.startValue or 0), 1, 1, 1)
            GameTooltip:AddLine("Now: " .. Commas(CurrentStat(s)), 0, 0.9, 1)
            GameTooltip:AddLine("Earned this session: +" .. Commas(earned[s.key] or 0), 0.35, 1, 0.2)
            GameTooltip:Show()
        end)
        row.hit:SetScript("OnLeave", function() GameTooltip:Hide() end)

        rows[info.key] = row
    end

    frame.lowDivider = Divider(frame, -4, statBlock)

    -- Feed ------------------------------------------------------------------
    log = CreateFrame("ScrollingMessageFrame", nil, frame)
    log:SetPoint("TOPLEFT", statBlock, "BOTTOMLEFT", 0, -12)
    log:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -(PAD + 2), PAD + CREDIT_H - 6)
    log:SetFontObject(GameFontHighlightSmall)
    log:SetJustifyH("LEFT")
    log:SetFading(false)
    log:SetMaxLines(db.maxLines)
    log:EnableMouseWheel(true)
    log:SetScript("OnMouseWheel", function(_, delta)
        -- 3.3.5 passes delta as the global `arg1` in some paths; accept both.
        local d = delta or arg1
        if d and d > 0 then log:ScrollUp() else log:ScrollDown() end
    end)
    frame.log = log

    -- Credit ----------------------------------------------------------------
    local credit = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    credit:SetPoint("BOTTOMRIGHT", -26, 10)
    credit:SetText("Made by MentalMonk")
    credit:SetTextColor(0.45, 0.45, 0.45)
    frame.credit = credit

    -- Resize grip, like the default chat frames.
    local grip = CreateFrame("Button", nil, frame)
    grip:SetWidth(16)
    grip:SetHeight(16)
    grip:SetPoint("BOTTOMRIGHT", -6, 6)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        SavePosition()
        dirty = true
        Repaint(true)
    end)
    frame.grip = grip

    -- The tick lives on the window itself: a hidden frame gets no OnUpdate, so
    -- a closed Stat Feed costs nothing per frame.
    frame:SetScript("OnUpdate", function(self, elapsed)
        tickElapsed = tickElapsed + (elapsed or arg1 or 0)
        if tickElapsed >= TICK_SECONDS then
            tickElapsed = 0
            Repaint()
        end
    end)

    if not db.shown then frame:Hide() end
    ApplyCollapse()
    Repaint(true)
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("CHAT_MSG_ADDON")
-- Both conventions work on 3.3.5: handlers set via SetScript receive
-- (self, event, ...), and the older `event` / `arg1` / `argN` globals are also
-- still populated -- those were not dropped until Cataclysm.
events:SetScript("OnEvent", function(self, evt, a1, a2)
    local e  = evt or event
    local p1 = a1 or arg1
    local p2 = a2 or arg2

    if e == "ADDON_LOADED" then
        if p1 == ADDON_NAME then
            GetDB()
            ResetSession()
            BuildWindow()
            BuildOptions()
            if RegisterAddonMessagePrefix then RegisterAddonMessagePrefix(ADDON_PREFIX) end
        end
        return
    end

    if e == "PLAYER_ENTERING_WORLD" then
        -- Stats read as 0 until the player object is fully loaded, so the
        -- login baseline is taken (or corrected) here.
        CaptureBaseline()
        dirty = true
        Repaint(true)
        if RegisterAddonMessagePrefix then RegisterAddonMessagePrefix(ADDON_PREFIX) end
        return
    end

    if e == "CHAT_MSG_ADDON" and p1 == ADDON_PREFIX then
        HandleFeed(p2)
    end
end)

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------
local function ResetWindow()
    if not frame then return end
    local db = GetDB()
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", DEFAULTS.x, DEFAULTS.y)
    frame:SetWidth(DEFAULTS.width)
    db.height = DEFAULTS.height
    frame:SetHeight(db.collapsed and COMPACT_H or DEFAULTS.height)
    frame:Show()
    db.shown = true
    SavePosition()
    dirty = true
    Repaint(true)
end

local function Toggle()
    if not frame then return end
    if frame:IsShown() then
        frame:Hide()
        GetDB().shown = false
    else
        frame:Show()
        GetDB().shown = true
        dirty = true
        Repaint(true)
    end
end

SLASH_STATFEED1 = "/statfeed"
SLASH_STATFEED2 = "/sfp"
SlashCmdList["STATFEED"] = function(msg)
    msg = Trim(lower(msg or ""))

    if msg == "clear" then
        if log then log:Clear() end
    elseif msg == "session" then
        ResetSession()
        AddLine("|cff9CC243Session counters reset.|r")
        Repaint(true)
    elseif msg == "reset" then
        ResetWindow()
    else
        Toggle()
    end
end

-- ---------------------------------------------------------------------------
-- Settings page: ESC > Interface > AddOns > Uncapped > Stat Feed.
-- Guarded: the shared UncappedUI library is provided by another addon and may
-- not be present.
--
-- Built from ADDON_LOADED rather than at file scope: SavedVariables are loaded
-- after the addon's Lua runs, so a panel built here would read its widget
-- states off the defaults instead of the player's saved ones.
-- ---------------------------------------------------------------------------
function BuildOptions()
    if not UncappedUI then return end

    local panel, L = UncappedUI.CreatePanel("Stat Feed", "The Dungeon Stats feed window.")

    L:Header("Window")

    L:Check("Show Stat Feed window",
        function() return GetDB().shown end,
        function(v)
            GetDB().shown = v
            if frame then
                if v then frame:Show(); dirty = true; Repaint(true) else frame:Hide() end
            end
        end)

    L:Check("Collapse to the session summary",
        function() return GetDB().collapsed end,
        function(v)
            local db = GetDB()
            if frame and not db.collapsed then db.height = frame:GetHeight() end
            db.collapsed = v
            ApplyCollapse()
        end)

    local widthSlider = L:Slider("Window width", MIN_WIDTH, 600, 10,
        function() return GetDB().width end,
        function(v)
            GetDB().width = v
            if frame then frame:SetWidth(v); dirty = true end
        end, "%d px")

    local heightSlider = L:Slider("Window height", EXPANDED_MIN, 700, 10,
        function() return GetDB().height end,
        function(v)
            GetDB().height = v
            if frame and not GetDB().collapsed then frame:SetHeight(v) end
        end, "%d px")

    L:Header("Feed")

    L:Slider("Scrollback lines", 50, 500, 10,
        function() return GetDB().maxLines end,
        function(v)
            GetDB().maxLines = v
            if log then log:SetMaxLines(v) end
        end, "%d")

    L:Header("Appearance")

    L:Check("Show per-stat share bars",
        function() return GetDB().showBars end,
        function(v)
            GetDB().showBars = v
            dirty = true
            Repaint(true)
        end)

    L:Slider("Background opacity", 0.0, 1.0, 0.05,
        function() return GetDB().bgAlpha end,
        function(v)
            GetDB().bgAlpha = v
            if frame then frame:SetBackdropColor(0, 0, 0, v) end
        end, "%.2f")

    L:Color("Title colour",
        function()
            local c = GetDB().titleColor
            return c[1], c[2], c[3]
        end,
        function(r, g, b)
            GetDB().titleColor = { r, g, b }
            if frame then
                frame.title:SetTextColor(r, g, b)
                if frame.accent.SetGradientAlpha then
                    frame.accent:SetGradientAlpha("HORIZONTAL", r, g, b, 0.85, r, g, b, 0.0)
                else
                    frame.accent:SetTexture(r, g, b, 0.6)
                end
            end
        end)

    L:Gap(6)

    L:Button("Reset session counters", function()
        ResetSession()
        Repaint(true)
    end)

    L:Button("Reset position & size", function()
        ResetWindow()
        widthSlider.uncappedRefresh()
        heightSlider.uncappedRefresh()
    end)
end
