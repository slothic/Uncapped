-- UncappedScrolls
--
-- A status window for every customization-scroll bonus on the account.
--
-- The scrolls are consumables: they are destroyed on use and leave behind no
-- item, no aura and no tooltip. The only feedback a player ever got was the chat
-- line printed at the moment of clicking, so after a relog there was no way to
-- answer "how much gather range do I actually have?" or "which instances did my
-- Fortune scrolls land on?". This window is that answer.
--
-- Everything shown is server-authoritative -- the client stores nothing but the
-- window position. Open it, the addon asks (SCRGET), the server bursts the
-- current values back and the window renders them.
--
--   /scrolls        toggle the window
--   /scrolls sync   force a refresh
--
-- Wire format is documented server-side in mod-scroll-bonuses/src/scroll_status_comms.cpp.

local ADDON_PIPE_PREFIX = "UNC"          -- server -> client (replies arrive here)
local TRANSPORT_PREFIX  = "REAGENTBANK"  -- client -> server (shared addon transport)

-- ---------------------------------------------------------------------------
-- State. Rebuilt wholesale on every burst -- there is no incremental update, so
-- a dropped line can never leave a stale row behind.
-- ---------------------------------------------------------------------------
local state = {
    gatherRange = 0,
    yieldPct    = 0,
    delver      = 0,
    questCount  = 0,
    questMult   = 1,
    professions = {},   -- { name, cur, max }
    fortune     = {},   -- { mapName, bonus }
    fortuneAll  = 0,    -- total server-side, may exceed #fortune (list is capped)
    received    = false,
}

local pending = nil     -- burst being assembled; swapped into `state` at SCREND

local COLOR_HEAD  = "|cff33ff99"   -- section headings (matches the scroll chat colour)
local COLOR_LABEL = "|cffffffff"
local COLOR_VALUE = "|cffffff00"
local COLOR_DIM   = "|cff888888"

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------
local WIDTH, HEIGHT = 360, 440
local ROW_H         = 14
local FORTUNE_ROWS  = 8

local frame = CreateFrame("Frame", "UncappedScrollsFrame", UIParent)
frame:SetWidth(WIDTH)
frame:SetHeight(HEIGHT)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
frame:SetFrameStrata("DIALOG")
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
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    UncappedScrollsDB = UncappedScrollsDB or {}
    UncappedScrollsDB.pos = { point = point, relPoint = relPoint, x = x, y = y }
end)
frame:Hide()

-- Escape closes it, like every other panel on the realm.
tinsert(UISpecialFrames, "UncappedScrollsFrame")

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", frame, "TOP", 0, -16)
title:SetText("Scroll Bonuses")

local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -5)

-- Body lines: a fixed column of font strings, filled top-down by Render(). Using
-- a fixed pool rather than creating strings per refresh keeps the window from
-- leaking frames every time it is opened.
local lines = {}
local function AcquireLine(index, yOffset)
    local fs = lines[index]
    if not fs then
        fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetJustifyH("LEFT")
        fs:SetWidth(WIDTH - 50)
        lines[index] = fs
    end
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, yOffset)
    fs:Show()
    return fs
end

-- ---- Fortune list (scrolling) ---------------------------------------------
local fortuneScroll = CreateFrame("ScrollFrame", "UncappedScrollsFortuneScroll", frame, "FauxScrollFrameTemplate")
fortuneScroll:SetWidth(WIDTH - 60)
fortuneScroll:SetHeight(FORTUNE_ROWS * ROW_H)

local fortuneRows = {}
for i = 1, FORTUNE_ROWS do
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetJustifyH("LEFT")
    fs:SetWidth(WIDTH - 60)
    fs:Hide()
    fortuneRows[i] = fs
end

local function RefreshFortuneRows()
    local offset = FauxScrollFrame_GetOffset(fortuneScroll) or 0
    for i = 1, FORTUNE_ROWS do
        local entry = state.fortune[i + offset]
        local fs = fortuneRows[i]
        if entry then
            fs:SetText(string.format("%s%s  %s+%.2f%%|r", COLOR_LABEL, entry.name, COLOR_VALUE, entry.bonus))
            fs:Show()
        else
            fs:Hide()
        end
    end
    FauxScrollFrame_Update(fortuneScroll, #state.fortune, FORTUNE_ROWS, ROW_H)
end

fortuneScroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, RefreshFortuneRows)
end)

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------
local function Render()
    local i, y = 1, -46

    local function Head(text)
        local fs = AcquireLine(i, y)
        fs:SetText(COLOR_HEAD .. text .. "|r")
        i, y = i + 1, y - (ROW_H + 4)
    end

    local function Row(label, value)
        local fs = AcquireLine(i, y)
        fs:SetText(string.format("%s%s|r  %s%s|r", COLOR_LABEL, label, COLOR_VALUE, value))
        i, y = i + 1, y - ROW_H
    end

    local function Note(text)
        local fs = AcquireLine(i, y)
        fs:SetText(COLOR_DIM .. text .. "|r")
        i, y = i + 1, y - ROW_H
    end

    if not state.received then
        Head("Account-wide")
        Note("Waiting for the server...")
        for n = i, #lines do lines[n]:Hide() end
        fortuneScroll:Hide()
        for n = 1, FORTUNE_ROWS do fortuneRows[n]:Hide() end
        return
    end

    Head("Account-wide")
    Row("Scroll of Reach",  string.format("+%.0f yd gather / auto-loot range", state.gatherRange))
    Row("Scroll of Bounty", string.format("+%d%% gathering yield", state.yieldPct))
    Row("Quest bonus",      string.format("x%.1f arena points  %s(%d quests)|r",
        state.questMult, COLOR_DIM, state.questCount))

    y = y - 6
    Head("This character")
    Row("Scroll of the Delver", string.format("+%d dungeon stat roll", state.delver))

    if #state.professions > 0 then
        for n = 1, #state.professions do
            local p = state.professions[n]
            Row(p.name, string.format("%d / %d", p.cur, p.max))
        end
    else
        Note("No professions learned.")
    end

    y = y - 6
    if state.fortuneAll > #state.fortune then
        Head(string.format("Scroll of Fortune  (showing %d of %d)", #state.fortune, state.fortuneAll))
    else
        Head(string.format("Scroll of Fortune  (%d)", state.fortuneAll))
    end

    for n = i, #lines do lines[n]:Hide() end

    -- Anchor the Fortune list under whatever the sections above ended up using,
    -- so a character with six professions does not overlap it.
    if #state.fortune > 0 then
        fortuneScroll:ClearAllPoints()
        fortuneScroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, y - 2)
        fortuneScroll:Show()
        for n = 1, FORTUNE_ROWS do
            fortuneRows[n]:ClearAllPoints()
            fortuneRows[n]:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, y - 2 - (n - 1) * ROW_H)
        end
        RefreshFortuneRows()
    else
        fortuneScroll:Hide()
        for n = 1, FORTUNE_ROWS do fortuneRows[n]:Hide() end
        local fs = AcquireLine(i, y)
        fs:SetText(COLOR_DIM .. "No Fortune bonuses yet." .. "|r")
    end
end

-- ---------------------------------------------------------------------------
-- Comms
-- ---------------------------------------------------------------------------
local function Request()
    SendAddonMessage(TRANSPORT_PREFIX, "SCRGET", "WHISPER", UnitName("player"))
end

local comms = CreateFrame("Frame")
comms:RegisterEvent("CHAT_MSG_ADDON")
comms:RegisterEvent("ADDON_LOADED")
comms:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "ADDON_LOADED" then
        if a1 ~= "UncappedScrolls" then return end
        UncappedScrollsDB = UncappedScrollsDB or {}
        local p = UncappedScrollsDB.pos
        if p then
            frame:ClearAllPoints()
            frame:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
        end
        return
    end

    local prefix, text = a1, a2
    if prefix ~= ADDON_PIPE_PREFIX or not text then return end
    if text:sub(1, 3) ~= "SCR" then return end

    -- Any SCR line other than SCREND belongs to a burst in flight. The first one
    -- seen opens a fresh accumulator, so a second request while one is arriving
    -- replaces the old burst rather than merging with it.
    if not pending then
        pending = { professions = {}, fortune = {}, fortuneAll = 0,
                    gatherRange = 0, yieldPct = 0, delver = 0, questCount = 0, questMult = 1 }
    end

    local range, yield = text:match("^SCRACC:([%d%.%-]+):(%d+)$")
    if range then
        pending.gatherRange = tonumber(range) or 0
        pending.yieldPct    = tonumber(yield) or 0
        return
    end

    local delver = text:match("^SCRCHR:(%d+)$")
    if delver then
        pending.delver = tonumber(delver) or 0
        return
    end

    local qcount, qmult = text:match("^SCRQST:(%d+):([%d%.]+)$")
    if qcount then
        pending.questCount = tonumber(qcount) or 0
        pending.questMult  = tonumber(qmult) or 1
        return
    end

    -- Profession and map names can contain spaces and apostrophes but never a
    -- colon, so anchoring the numeric tail is enough to split them safely.
    local pname, cur, max = text:match("^SCRPRF:(.+):(%d+):(%d+)$")
    if pname then
        tinsert(pending.professions, { name = pname, cur = tonumber(cur), max = tonumber(max) })
        return
    end

    local mname, bonus = text:match("^SCRFOR:(.+):([%d%.%-]+)$")
    if mname then
        tinsert(pending.fortune, { name = mname, bonus = tonumber(bonus) or 0 })
        return
    end

    local total = text:match("^SCREND:(%d+)$")
    if total then
        pending.fortuneAll = tonumber(total) or #pending.fortune
        pending.received   = true
        state   = pending
        pending = nil
        if frame:IsShown() then Render() end
        return
    end
end)

-- ---------------------------------------------------------------------------
-- Entry points
-- ---------------------------------------------------------------------------
local function Toggle()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        Render()      -- paint immediately with what we have
        Request()     -- then refresh
    end
end

SLASH_UNCAPPEDSCROLLS1 = "/scrolls"
SLASH_UNCAPPEDSCROLLS2 = "/scroll"
SlashCmdList["UNCAPPEDSCROLLS"] = function(arg)
    arg = (arg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if arg == "sync" then
        Request()
        DEFAULT_CHAT_FRAME:AddMessage(COLOR_HEAD .. "[Scrolls]|r Refreshing...")
        return
    end
    Toggle()
end

-- Settings page (ESC > Interface > AddOns > Uncapped > Scrolls). Provided by the
-- shared UncappedUI widget library (UncappedOptions addon); guard on it so the
-- window still works standalone if that addon is missing.
if UncappedUI then
    local _, L = UncappedUI.CreatePanel("Scrolls",
        "Every customization-scroll bonus on your account -- Reach, Bounty, Fortune, Mastery and Delver.")

    L:Header("Scroll bonuses")
    L:Button("Open Scroll Bonuses", Toggle, 180)
    L:Note("Shows what each scroll you have used is actually giving you, including which "
        .. "instances your Scroll of Fortune bonuses landed on, plus your account-wide "
        .. "quest bonus to arena points. Also available with /scrolls.", 48)
end
