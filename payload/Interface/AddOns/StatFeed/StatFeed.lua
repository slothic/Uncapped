--[[
    Stat Feed -- the Dungeon Stats window.

    The server sends stat gains as ADDON messages rather than chat, so they
    never touch the default chat frame. See lua_scripts/dungeonstats.lua, which
    routes them through SendAddonMessage with the prefix below, in the form:

        You received <n> <StatName> for killing <Creature>.
        Your pet also received <n> <StatName>.

    Ruling #620 adds an optional trailing " (HOTZONE)" to the first form when the
    kill happened inside a live hotzone. It sits AFTER the full stop on purpose, so
    it lands in the trailing capture and neither parser below had to change; the
    display code splits it back out and colours it separately.

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
local BUNDLE_ADDON_NAME = "Uncapped"
local ADDON_PREFIX = "DSTATS"
local TICK_SECONDS = 1        -- how often the clock/pace repaint while shown
local STARTUP_DELAY_SECONDS = 5
local BASELINE_RETRY_SECONDS = 8
local BASELINE_RETRY_INTERVAL = 0.5

-- ---------------------------------------------------------------------------
-- Layout constants. Everything below the summary block is anchored, not
-- hard-placed, so the window lays out correctly at any size the user drags it
-- to.
-- ---------------------------------------------------------------------------
local PAD          = 12       -- left/right inset
local HEADER_H     = 30       -- title bar
local SUMMARY_ROW  = 22       -- one line of the "this session" block
local STAT_ROW     = 18       -- one stat line
local STAT_TOP_GAP = 17       -- gap from the summary divider to Strength
local CREDIT_H     = 16       -- reserved strip at the bottom for the credit
local COMPACT_H    = HEADER_H + (SUMMARY_ROW * 3) + 14
local MIN_WIDTH    = 220      -- narrower than this and the stat rows collide
-- Reported as "make the Stat Feed window re-sizeable" (#126). It always had a
-- grip; what it did not have was anywhere to go. The default width IS
-- MIN_WIDTH (220) and the default height IS the expanded minimum (330), so the
-- window opens pinned against both floors -- the only direction available is
-- bigger -- and the width ceiling sat at 400. Grabbing the grip and having it
-- stop after 180 pixels reads as "does not resize", not "resizes a little".
--
-- Every width-dependent measurement in here is proportional (LayoutStatColumns
-- splits the block by fraction; the earned-stat bars are a share of it), so
-- there was never a layout reason for a ceiling that low.
--
-- FOLLOW-UP: 720 was still a literal, while the HEIGHT ceiling right below it
-- had already been rewritten to measure the screen. Those two should never have
-- been decided differently -- frame sizes are UIParent units and UIParent is
-- ~1365 units wide at 16:9 default scale, so 720 was a little over half the
-- screen and, worse, OnSizeChanged actively SNAPS the frame back to it mid-drag.
-- A grip that yanks the window back out of your hand is the exact complaint in
-- #126, just at a bigger number than before. Derived the same way as the height.
local MAX_WIDTH_ABS = 1400    -- absolute; the screen below is the real ceiling
-- Height is the honest half: frame sizes are UIParent units, not monitor
-- pixels, and UIParent is ~768 units tall at the default UI scale on any
-- monitor -- so the old 700 was already ~91% of the screen and there was
-- nothing to win. It only bites players who turn the UI-scale slider down,
-- which makes UIParent taller in units. Derived rather than a literal so that
-- case is covered without pretending the common one was broken.
local MAX_HEIGHT_ABS = 1100   -- absolute; the screen below is the real ceiling
-- Not cosmetic: size a window flush to the screen edge and the bottom-right
-- grip ends up under that edge with no comfortable way to drag it back.
local SCREEN_MARGIN = 60
local BAR_WIDTH_BONUS = 50    -- minimum visual weight added to earned stat bars
local LOG_MIN_H    = 32       -- ~2 feed lines; below this the feed is pointless
local STAT_BLOCK_TOP          -- top offset for the stat rows
local FEED_ONLY_TOP           -- top offset for the feed when stat rows are hidden
local FEED_TOP_GAP = 12
local FEED_BOTTOM_INSET       -- bottom offset for the feed
local EXPANDED_MIN            -- smallest usable expanded height; derived below
local FEED_ONLY_MIN           -- expanded minimum when the stat rows are hidden

local DEFAULTS = {
    point      = "BOTTOMRIGHT",
    x          = -20,
    y          = 20,
    width      = 220,
    height     = 330,
    shown      = true,
    collapsed  = false,
    maxLines   = 200,
    bgAlpha    = 0.78,
    showBars   = true,
    showStats  = true,
    titleColor = { 0.61, 0.76, 0.26 }, -- |cff9CC243
    layout     = 7,                    -- bump to force a one-time re-size
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
STAT_BLOCK_TOP = HEADER_H + STAT_TOP_GAP + (SUMMARY_ROW * 3)
FEED_ONLY_TOP = HEADER_H + 6 + (SUMMARY_ROW * 3) + 14
FEED_BOTTOM_INSET = PAD + CREDIT_H - 6
EXPANDED_MIN = STAT_BLOCK_TOP                           -- top of the stat block
             + (#STATS * STAT_ROW + 4)                  -- the stat block
             + FEED_TOP_GAP + LOG_MIN_H                 -- gap + feed
             + FEED_BOTTOM_INSET                        -- bottom inset
EXPANDED_MIN = math.ceil(EXPANDED_MIN / 10) * 10
FEED_ONLY_MIN = FEED_ONLY_TOP + LOG_MIN_H + FEED_BOTTOM_INSET
FEED_ONLY_MIN = math.ceil(FEED_ONLY_MIN / 10) * 10

local function ExpandedMinHeight(showStats)
    return showStats and EXPANDED_MIN or FEED_ONLY_MIN
end

-- Height ceiling, measured against the screen rather than a literal. The old
-- one was 700, which was most of a monitor when it was written and half a
-- window now. math.* spelled out because the floor/min/max locals are
-- declared further down the file than this.
local function MaxHeight()
    local screen = math.floor((UIParent:GetHeight() or 768) - SCREEN_MARGIN)
    return math.max(EXPANDED_MIN, math.min(MAX_HEIGHT_ABS, screen))
end

-- Same rule for width. Kept as a function rather than a constant computed once
-- at load: UIParent's size in units changes when the player moves the UI-scale
-- slider, and a ceiling captured at login would then be wrong for the rest of
-- the session in whichever direction the slider moved.
local function MaxWidth()
    local screen = math.floor((UIParent:GetWidth() or 1024) - SCREEN_MARGIN)
    return math.max(MIN_WIDTH, math.min(MAX_WIDTH_ABS, screen))
end

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
local C_HOT    = "|cffff4040"   -- matches the server's own hotzone red
local C_RESET  = "|r"

-- Ruling #620: the server appends this marker to a stat line when the kill happened
-- inside a live hotzone. It is deliberately placed AFTER the full stop so it lands
-- inside the trailing "(.*)" capture of the feed pattern below -- which keeps both
-- that pattern and the session-total pattern matching unchanged, but means the
-- marker arrives glued to the creature's NAME and has to be split back out.
local HOTZONE_PATTERN = "%s*%(HOTZONE%)%s*$"
local HOTZONE_LABEL   = "(HOTZONE)"

-- Locals for the hot paths (upvalue lookups beat globals in 5.1).
local floor, min, max, abs, format, gsub, match, lower = math.floor, math.min, math.max,
    math.abs, string.format, string.gsub, string.match, string.lower

local frame, log, statBlock
local BuildOptions       -- forward declaration; defined at the bottom
local Repaint
local rows        = {}   -- display name -> widget set
local earned      = {}   -- display name -> gained this session
local totalEarned = 0
local sessionStart = 0
local tickElapsed  = 0
local dirty        = true  -- set when something changed; cleared by Repaint
local startupDelayPending = false
local startupDelayElapsed = 0
local baselineCorrectionPending = false
local baselineCorrectionStarted = 0
local baselineRetryElapsed = 0
local lastStatBlockWidth = 0

-- ---------------------------------------------------------------------------
-- Saved variables
-- ---------------------------------------------------------------------------
local VALID_POINTS = {
    CENTER = true,
    TOP = true, BOTTOM = true, LEFT = true, RIGHT = true,
    TOPLEFT = true, TOPRIGHT = true, BOTTOMLEFT = true, BOTTOMRIGHT = true,
}

local function CopyDefault(value)
    if type(value) ~= "table" then return value end
    local t = {}
    for i, v in pairs(value) do t[i] = v end
    return t
end

local function SavedNumber(value, fallback, minValue, maxValue)
    local n = tonumber(value)
    if not n then n = fallback end
    if minValue and n < minValue then n = minValue end
    if maxValue and n > maxValue then n = maxValue end
    return n
end

local function SavedBoolean(value, fallback)
    if type(value) == "boolean" then return value end
    if value == 1 or value == "1" or value == "true" then return true end
    if value == 0 or value == "0" or value == "false" then return false end
    return fallback
end

local function SavedColor(value, fallback)
    if type(value) ~= "table" then return CopyDefault(fallback) end

    local r = tonumber(value[1])
    local g = tonumber(value[2])
    local b = tonumber(value[3])
    if not r or not g or not b then return CopyDefault(fallback) end

    return {
        SavedNumber(r, fallback[1], 0, 1),
        SavedNumber(g, fallback[2], 0, 1),
        SavedNumber(b, fallback[3], 0, 1),
    }
end

local function GetDB()
    StatFeedDB = StatFeedDB or {}
    local db = StatFeedDB

    -- Read the saved layout version BEFORE the defaults are filled in: the loop
    -- below would stamp the current version onto an old DB, and the migration
    -- that follows would then think it had already run.
    local savedLayout = tonumber(db.layout) or 0

    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then
            db[k] = CopyDefault(v)
        end
    end

    -- The window grew when the session block was added; resize saved layouts
    -- from before that once, so an old install isn't left with a cramped frame.
    if savedLayout < DEFAULTS.layout then
        db.width  = DEFAULTS.width
        db.height = DEFAULTS.height
        db.point = DEFAULTS.point
        db.x = DEFAULTS.x
        db.y = DEFAULTS.y
        db.collapsed = DEFAULTS.collapsed
        db.shown = DEFAULTS.shown
        db.layout = DEFAULTS.layout
    end

    db.point = VALID_POINTS[db.point] and db.point or DEFAULTS.point
    db.x = SavedNumber(db.x, DEFAULTS.x)
    db.y = SavedNumber(db.y, DEFAULTS.y)
    db.width = SavedNumber(db.width, DEFAULTS.width, MIN_WIDTH, MaxWidth())
    db.shown = SavedBoolean(db.shown, DEFAULTS.shown)
    db.collapsed = SavedBoolean(db.collapsed, DEFAULTS.collapsed)
    db.maxLines = floor(SavedNumber(db.maxLines, DEFAULTS.maxLines, 50, 500))
    db.bgAlpha = SavedNumber(db.bgAlpha, DEFAULTS.bgAlpha, 0, 1)
    db.showBars = SavedBoolean(db.showBars, DEFAULTS.showBars)
    db.showStats = SavedBoolean(db.showStats, DEFAULTS.showStats)
    db.height = SavedNumber(db.height, DEFAULTS.height, ExpandedMinHeight(db.showStats), MaxHeight())
    db.titleColor = SavedColor(db.titleColor, DEFAULTS.titleColor)
    db.layout = floor(SavedNumber(db.layout, DEFAULTS.layout, DEFAULTS.layout))

    -- Belt and braces: the rows, dividers and feed are anchored to the top of
    -- the frame, so a height smaller than the content draws them below the
    -- window's bottom edge. Never trust a saved size that can't hold it.
    if (db.height or 0) < ExpandedMinHeight(db.showStats) then
        db.height = ExpandedMinHeight(db.showStats)
    end
    if (db.height or 0) > MaxHeight() then db.height = MaxHeight() end
    if (db.width or 0) < MIN_WIDTH then db.width = MIN_WIDTH end
    if (db.width or 0) > MaxWidth() then db.width = MaxWidth() end

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
        return true
    end
    return false
end

local function LayoutStatColumns()
    if not statBlock then return end

    local width = statBlock:GetWidth()
    local addedW = 48

    for i = 1, #STATS do
        local row = rows[STATS[i].key]
        if row and row.added then
            local textW = row.added:GetStringWidth() or 0
            if textW + 12 > addedW then addedW = textW + 12 end
        end
    end

    addedW = min(max(addedW, 48), max(48, floor(width * 0.38)))

    local startW = max(44, floor((width - addedW - 16) * 0.32))
    local nameW = max(60, width - startW - addedW - 16)

    for i = 1, #STATS do
        local row = rows[STATS[i].key]
        if row then
            row.name:SetWidth(nameW)
            row.start:SetWidth(startW)
            row.added:SetWidth(addedW)
        end
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
local function ResetSession(correctOnNextWorld)
    totalEarned = 0
    for i = 1, #STATS do
        local info = STATS[i]
        earned[info.key]    = 0
        info.startValue     = CurrentStat(info)
    end
    sessionStart = GetTime()
    baselineCorrectionPending = correctOnNextWorld and true or false
    baselineCorrectionStarted = baselineCorrectionPending and sessionStart or 0
    baselineRetryElapsed = 0
    dirty = true
end

local function CaptureBaseline()
    if not baselineCorrectionPending then return false end

    local changed = false
    local waitingForStats = false
    for i = 1, #STATS do
        local info = STATS[i]
        if not info.startValue or info.startValue == 0 then
            local current = CurrentStat(info)
            if current ~= 0 then
                info.startValue = current
                changed = true
            else
                waitingForStats = true
            end
        end
    end

    if not waitingForStats or (GetTime() - baselineCorrectionStarted) >= BASELINE_RETRY_SECONDS then
        baselineCorrectionPending = false
        baselineCorrectionStarted = 0
        baselineRetryElapsed = 0
    end

    if changed then dirty = true end
    return changed
end

local function StartStartupDelay()
    totalEarned = 0
    for i = 1, #STATS do
        local info = STATS[i]
        earned[info.key] = 0
        info.startValue = 0
    end
    sessionStart = GetTime()
    startupDelayPending = true
    startupDelayElapsed = 0
    baselineCorrectionPending = false
    baselineCorrectionStarted = 0
    baselineRetryElapsed = 0
    dirty = true
end

local function FinishStartupDelay()
    startupDelayPending = false
    startupDelayElapsed = 0
    ResetSession(true)
    CaptureBaseline()
    if Repaint then Repaint(true) end
end

local function RecordGain(amount, statName)
    amount = tonumber(amount)
    local key = NormalizeStat(statName)
    if not amount or amount <= 0 or not key or earned[key] == nil then return end

    totalEarned  = totalEarned + amount
    earned[key]  = earned[key] + amount
    dirty = true
end

-- ---------------------------------------------------------------------------
-- Painting
-- ---------------------------------------------------------------------------
function Repaint(force)
    if not frame or not frame:IsShown() then return end

    local elapsed = max(1, GetTime() - sessionStart)
    SetTextCached(frame.totalText, Commas(totalEarned))
    -- Pace is meaningless in the first minute, so the divisor is floored there
    -- rather than letting a single kill read as "180,000 an hour".
    SetTextCached(frame.rateText, Commas(totalEarned * 3600 / max(60, elapsed)))
    SetTextCached(frame.clockText, Clock(elapsed))

    if not (dirty or force) then return end
    dirty = false

    local db = GetDB()
    if db.collapsed or not db.showStats then return end

    local showBars = db.showBars
    local blockWidth = statBlock:GetWidth()
    local textChanged = force or blockWidth ~= lastStatBlockWidth
    for i = 1, #STATS do
        local info = STATS[i]
        local row  = rows[info.key]
        local gain = earned[info.key] or 0

        if gain > 0 then
            if SetTextCached(row.added, C_AMOUNT .. "+" .. Short(gain) .. C_RESET) then textChanged = true end
        else
            if SetTextCached(row.added, C_OFF .. "+0" .. C_RESET) then textChanged = true end
        end
        if SetTextCached(row.start, Short(info.startValue or 0)) then textChanged = true end
    end

    if textChanged then
        LayoutStatColumns()
        lastStatBlockWidth = blockWidth
    end

    local barMaxWidth = blockWidth - 4
    for i = 1, #STATS do
        local info = STATS[i]
        local row  = rows[info.key]
        local gain = earned[info.key] or 0

        if showBars and gain > 0 and totalEarned > 0 then
            local share = min(1, max(0, gain / totalEarned))
            row.bar:SetWidth(min(barMaxWidth, (barMaxWidth * share) + BAR_WIDTH_BONUS))
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
        -- Ruling #620: split the hotzone marker back out of the creature-name
        -- capture and colour it on its own. Leaving it in would paint it in the
        -- target colour, i.e. as though the creature were called
        -- "Svala Sorrowgrave. (HOTZONE)" -- which reads as a bug, not a bonus.
        -- Parenthesised so gsub's second return (the count) cannot slide into the
        -- next expression.
        local hot = ""
        if match(target, HOTZONE_PATTERN) then
            target = (gsub(target, HOTZONE_PATTERN, ""))
            hot = " " .. C_HOT .. HOTZONE_LABEL .. C_RESET
        end

        return C_LABEL .. prefix .. C_RESET .. C_AMOUNT .. amount .. C_RESET
            .. " " .. C_GAIN .. (NormalizeStat(stat) or Trim(stat)) .. C_RESET
            .. C_LABEL .. middle .. C_RESET .. C_TARGET .. target .. C_RESET .. hot
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

local function LayoutFeed(showStats)
    if not frame or not statBlock or not log then return end

    log:ClearAllPoints()
    if showStats then
        log:SetPoint("TOPLEFT", statBlock, "BOTTOMLEFT", 0, -FEED_TOP_GAP)
    else
        log:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + 2, -FEED_ONLY_TOP)
    end
    log:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -(PAD + 2), FEED_BOTTOM_INSET)
end

local function ApplyStatVisibility()
    if not frame or not statBlock or not log then return end

    local db = GetDB()
    local showStats = db.showStats and true or false

    if frame.statToggle then frame.statToggle:SetChecked(showStats) end

    LayoutFeed(showStats)
    if showStats then
        statBlock:Show()
        frame.lowDivider:Show()
        frame:SetMinResize(MIN_WIDTH, EXPANDED_MIN)
        if frame:GetHeight() < EXPANDED_MIN then frame:SetHeight(EXPANDED_MIN) end
    else
        statBlock:Hide()
        frame.lowDivider:Hide()
        frame:SetMinResize(MIN_WIDTH, FEED_ONLY_MIN)
        if frame:GetHeight() < FEED_ONLY_MIN then frame:SetHeight(FEED_ONLY_MIN) end
    end
end

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
        if frame.credit then frame.credit:Hide() end
        frame:SetMinResize(MIN_WIDTH, COMPACT_H)
        frame:SetHeight(COMPACT_H)
    else
        log:Show()
        frame.midDivider:Show()
        frame.grip:Show()
        if frame.credit then frame.credit:Show() end
        ApplyStatVisibility()
        frame:SetHeight(db.height or DEFAULTS.height)
        if frame:GetHeight() < ExpandedMinHeight(db.showStats) then
            frame:SetHeight(ExpandedMinHeight(db.showStats))
        end
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

-- Re-derived rather than set once at build. UIParent's size IN UNITS changes
-- when the player moves the UI-scale slider or the resolution changes, so a
-- ceiling captured at login is wrong for the rest of the session -- too low for
-- someone who scaled down (the original #126 complaint), and too high for
-- someone who scaled up, which lets the grip drag the frame off the screen.
--
-- Also pulls the frame back inside a ceiling that just shrank: SetMaxResize
-- constrains future drags, it does not resize a frame that is already bigger.
local function ApplyResizeCeiling()
    if not frame then return end

    local maxW, maxH = MaxWidth(), MaxHeight()
    if frame.SetMaxResize then frame:SetMaxResize(maxW, maxH) end

    local w, h = frame:GetWidth(), frame:GetHeight()
    local over = false
    if w > maxW then frame:SetWidth(maxW); over = true end
    if h > maxH and not GetDB().collapsed then frame:SetHeight(maxH); over = true end
    if over then
        SavePosition()
        dirty = true
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
    --[[ ⚠ ESCAPE MUST NOT CLOSE THIS. Do not re-add UISpecialFrames here.

         The 2026-08-16 UI style audit added it on the reasoning that "siblings of
         this window had these and it did not", and players reported it closing on
         Escape the same day. The audit was right about the siblings and wrong
         about the class: UISpecialFrames is for windows you open, use and dismiss
         -- a vendor, a talent pane, the Dashboard. This is a FEED. It is placed
         once and left up while you play, and Escape gets pressed constantly for
         unrelated reasons: opening the game menu, clearing a target, stopping a
         cast. Every one of those was taking the feed away.

         ★ THE REALM HAS DECIDED THIS TWICE ALREADY, both times the same way.
         UncappedChat came off the list ("Uchat keeps closing when pressing Esc
         key meaning we have too constantly open it back up"), and the Loot Feed
         popout was kept off it for report #384, four minutes after going live.
         Blizzard's own chat frames are not on the list either. A feed and a
         dialog are different frame classes and a consistency pass over the two
         is how this got reintroduced.

         Close it with /statfeed, or its own titlebar. ]]
    if UncappedScale_Register then UncappedScale_Register(frame, { group = "dashboard" }) end
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
    ApplyResizeCeiling()
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
        dirty = true
    end)
    -- Bars are sized off the frame width, so a resize has to repaint them.
    --
    -- No width clamp here any more. SetMaxResize already stops the grip at the
    -- ceiling, so this second clamp only ever fired when the two disagreed --
    -- and when it did it called SetWidth from inside OnSizeChanged, i.e. it
    -- re-entered itself mid-drag to yank the frame back. That is what "the
    -- window won't resize" felt like from the player's side (#126).
    frame:SetScript("OnSizeChanged", function()
        dirty = true
    end)

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

    local statsToggle = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    statsToggle:SetWidth(20)
    statsToggle:SetHeight(20)
    statsToggle:SetPoint("RIGHT", collapse, "LEFT", -5, 0)
    statsToggle:SetChecked(db.showStats and true or false)
    statsToggle:SetScript("OnClick", function(self)
        local d = GetDB()
        d.showStats = self:GetChecked() and true or false
        ApplyCollapse()
        SavePosition()
    end)
    statsToggle:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText((GetDB().showStats and "Hide" or "Show") .. " Stats")
        GameTooltip:Show()
    end)
    statsToggle:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frame.statToggle = statsToggle

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
    statBlock:SetPoint("TOPLEFT", PAD + 2, -STAT_BLOCK_TOP)
    statBlock:SetPoint("TOPRIGHT", -(PAD + 2), -STAT_BLOCK_TOP)
    statBlock:SetHeight(#STATS * STAT_ROW + 4)

    for i = 1, #STATS do
        local info = STATS[i]
        local y    = -((i - 1) * STAT_ROW) - 2
        local row  = {}

        -- Share bar: this stat's share of the whole session's stat gains.
        -- Sits in BACKGROUND so the text reads over it.
        row.bar = statBlock:CreateTexture(nil, "BACKGROUND")
        row.bar:SetTexture(info.r, info.g, info.b, 0.16)
        row.bar:SetHeight(STAT_ROW - 4)
        row.bar:SetPoint("TOPLEFT", 0, y + 1)
        row.bar:SetWidth(1)
        row.bar:Hide()

        row.name = statBlock:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("TOPLEFT", 2, y)
        row.name:SetJustifyH("LEFT")
        row.name:SetText(info.key)
        row.name:SetTextColor(info.r, info.g, info.b)

        row.start = statBlock:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.start:SetPoint("TOPLEFT", row.name, "TOPRIGHT", 8, 0)
        row.start:SetJustifyH("RIGHT")
        row.start:SetTextColor(0.78, 0.78, 0.78)

        row.added = statBlock:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.added:SetPoint("TOPLEFT", row.start, "TOPRIGHT", 8, 0)
        row.added:SetPoint("TOPRIGHT", -2, y)
        row.added:SetJustifyH("RIGHT")

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
    LayoutFeed(db.showStats)
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
-- The resize ceiling is measured against UIParent, which changes size in units
-- when either of these fires -- see ApplyResizeCeiling. #126.
events:RegisterEvent("UI_SCALE_CHANGED")
events:RegisterEvent("DISPLAY_SIZE_CHANGED")
events:SetScript("OnUpdate", function(self, elapsed)
    if startupDelayPending then
        startupDelayElapsed = startupDelayElapsed + (elapsed or arg1 or 0)
        if startupDelayElapsed >= STARTUP_DELAY_SECONDS then
            FinishStartupDelay()
        end
        return
    end

    if not baselineCorrectionPending then return end
    baselineRetryElapsed = baselineRetryElapsed + (elapsed or arg1 or 0)
    if baselineRetryElapsed < BASELINE_RETRY_INTERVAL then return end
    baselineRetryElapsed = 0
    if CaptureBaseline() then Repaint(true) end
end)
-- Both conventions work on 3.3.5: handlers set via SetScript receive
-- (self, event, ...), and the older `event` / `arg1` / `argN` globals are also
-- still populated -- those were not dropped until Cataclysm.
events:SetScript("OnEvent", function(self, evt, a1, a2)
    local e  = evt or event
    local p1 = a1 or arg1
    local p2 = a2 or arg2

    if e == "ADDON_LOADED" then
        if p1 == ADDON_NAME or p1 == BUNDLE_ADDON_NAME then
            GetDB()
            StartStartupDelay()
            BuildWindow()
            BuildOptions()
            if RegisterAddonMessagePrefix then RegisterAddonMessagePrefix(ADDON_PREFIX) end
        end
        return
    end

    if e == "PLAYER_ENTERING_WORLD" then
        -- Stats read as 0 until the player object is fully loaded, so the
        -- login baseline is taken after a short delay. Later world entries
        -- should only run the existing baseline correction path.
        if startupDelayPending then
            StartStartupDelay()
        else
            CaptureBaseline()
        end
        dirty = true
        Repaint(true)
        if RegisterAddonMessagePrefix then RegisterAddonMessagePrefix(ADDON_PREFIX) end
        return
    end

    if e == "UI_SCALE_CHANGED" or e == "DISPLAY_SIZE_CHANGED" then
        ApplyResizeCeiling()
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
    frame:SetPoint(DEFAULTS.point, UIParent, DEFAULTS.point, DEFAULTS.x, DEFAULTS.y)
    frame:SetWidth(DEFAULTS.width)
    db.height = DEFAULTS.height
    db.collapsed = false
    frame:SetHeight(DEFAULTS.height)
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
    local heightSlider

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

    L:Check("Show Stats",
        function() return GetDB().showStats end,
        function(v)
            GetDB().showStats = v
            ApplyCollapse()
            SavePosition()
            if heightSlider then heightSlider.uncappedRefresh() end
        end)

    -- Both sliders take their ceiling from the same functions the resize grip
    -- does. They used to be literals (MAX_WIDTH, and a bare 700 for height),
    -- which is how the height slider ended up capping 400px BELOW what the grip
    -- would let you drag to after the grip's own ceiling was raised -- two
    -- controls for one number, disagreeing. #126.
    local widthSlider = L:Slider("Window width", MIN_WIDTH, MaxWidth(), 10,
        function() return GetDB().width end,
        function(v)
            GetDB().width = v
            if frame then frame:SetWidth(v); dirty = true end
        end, "%d px")

    heightSlider = L:Slider("Window height", FEED_ONLY_MIN, MaxHeight(), 10,
        function()
            local db = GetDB()
            return max(db.height, ExpandedMinHeight(db.showStats))
        end,
        function(v)
            local db = GetDB()
            v = max(v, ExpandedMinHeight(db.showStats))
            db.height = v
            if frame and not db.collapsed then frame:SetHeight(v) end
        end, "%d px")

    L:Header("Feed")

    L:Slider("Scrollback lines", 50, 500, 10,
        function() return GetDB().maxLines end,
        function(v)
            GetDB().maxLines = v
            if log then log:SetMaxLines(v) end
        end, "%d")

    L:Header("Appearance")

    L:Check("Show stat bars",
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





-- ---------------------------------------------------------------------------
-- ★ [#952] Blizzard bug: Enter in a gossip code box throws the number away.
--
-- Interface/FrameXML/StaticPopup.lua, GOSSIP_ENTER_CODE:
--     EditBoxOnEnterPressed = function(self, data)
--         local parent = self:GetParent();
--         SelectGossipOption(data, parent.editBox:GetText());   -- no `true`
--         parent:Hide();
--     end,
--
-- OnAccept, twelve lines above, passes a THIRD argument -- confirmed = true.
-- The Enter handler does not, so the client treats it as the FIRST click on a
-- coded option, re-arms the popup instead of sending the code, and then
-- parent:Hide() closes it. Net effect: Enter behaves exactly like Cancel and
-- the typed amount is discarded. Reported as "when you have the box open too
-- type the amount in if u press enter it closes it".
--
-- This is realm-wide, not just Dungeon Stats -- the other coded-gossip user is
-- the transmog item search.
--
-- SelectGossipOption is NOT protected in 3.3.5, so a plain table override is
-- enough: no taint, no hardware-event requirement.
-- ---------------------------------------------------------------------------
local gossipCode = StaticPopupDialogs and StaticPopupDialogs["GOSSIP_ENTER_CODE"]
if gossipCode then
    gossipCode.EditBoxOnEnterPressed = function(self, data)
        local parent = self:GetParent()
        SelectGossipOption(data, parent.editBox:GetText(), true)
        parent:Hide()
    end
end
