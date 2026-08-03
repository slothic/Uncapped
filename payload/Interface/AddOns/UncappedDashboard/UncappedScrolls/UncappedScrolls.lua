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
--   /scrolls        open it (switches the Dashboard to the Soul Scrolls tab)
--   /scrolls sync   force a refresh
--
-- Wire format is documented server-side in mod-scroll-bonuses/src/scroll_status_comms.cpp.
--
-- Lives inside the Dashboard's content panel (see EmbedInto below) -- no own
-- backdrop/title/close/drag, since the Dashboard's master window already
-- provides all of that chrome. Internal layout stays the fixed-pixel size the
-- standalone window used (it's a plain text listing, nothing to reflow), with
-- GetMinWidth/GetMinHeight telling the Dashboard how much room that needs.

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

local frame, fortuneScroll
local lines = {}
local fortuneRows = {}

-- Body lines: a fixed column of font strings, filled top-down by Render(). Using
-- a fixed pool rather than creating strings per refresh keeps the window from
-- leaking frames every time it is opened.
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

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------
local function Render()
    if not frame then return end
    local i, y = 1, -14

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

local function BuildFrame(parent)
    if frame then return end

    frame = CreateFrame("Frame", "UncappedScrollsFrame", parent or UIParent)
    frame:SetPoint("TOPLEFT"); frame:SetPoint("BOTTOMRIGHT")

    fortuneScroll = CreateFrame("ScrollFrame", "UncappedScrollsFortuneScroll", frame, "FauxScrollFrameTemplate")
    fortuneScroll:SetWidth(WIDTH - 60)
    fortuneScroll:SetHeight(FORTUNE_ROWS * ROW_H)
    fortuneScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, RefreshFortuneRows)
    end)

    for i = 1, FORTUNE_ROWS do
        local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetJustifyH("LEFT")
        fs:SetWidth(WIDTH - 60)
        fs:Hide()
        fortuneRows[i] = fs
    end

    frame:Hide()
end

-- ---------------------------------------------------------------------------
-- Comms
-- ---------------------------------------------------------------------------
local function Request()
    SendAddonMessage(TRANSPORT_PREFIX, "SCRGET", "WHISPER", UnitName("player"))
end

local comms = CreateFrame("Frame")
comms:RegisterEvent("CHAT_MSG_ADDON")
comms:SetScript("OnEvent", function(_, event, a1, a2)
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
        if frame and frame:IsShown() then Render() end
        return
    end
end)

-- ===========================================================================
-- Dashboard embedding
-- ===========================================================================
-- The Dashboard hosts this panel directly inside its own window instead of
-- Scrolls owning a window of its own -- see UncappedDashboard_UI.lua, which
-- calls EmbedInto once (to build the frame into its content group) and
-- Activate every time the Soul Scrolls tab is selected.
local Scrolls = _G.UncappedScrolls or {}
_G.UncappedScrolls = Scrolls
Scrolls.UI = {}

function Scrolls.UI.EmbedInto(parent)
    BuildFrame(parent)
    frame:Show()
    return frame
end

function Scrolls.UI.Activate()
    if not frame then return end
    Render()      -- paint immediately with whatever's cached
    Request()     -- then refresh
end

-- Content-panel width (not window width) Scrolls needs: its original
-- standalone window's width (360) plus the embedded group's own 6px padding
-- on each side = 372.
function Scrolls.UI.GetMinWidth()
    return 372
end

-- Full window height (not content height) Scrolls needs: its original
-- standalone window's height (440) plus the Dashboard window's own chrome
-- (title/banner + margins) that a standalone window didn't have to account
-- for, ~72px.
function Scrolls.UI.GetMinHeight()
    return 512
end

-- Switches the Dashboard to the Soul Scrolls tab, opening it if it's closed.
-- Used by the settings-page button -- Scrolls has no window of its own
-- anymore to open directly.
local function OpenInDashboard()
    local Dashboard = _G.UncappedDashboard
    if not Dashboard then
        DEFAULT_CHAT_FRAME:AddMessage(COLOR_HEAD .. "[Scrolls]|r now lives inside the Dashboard -- load UncappedDashboard to use it.")
        return
    end
    Dashboard.SetTab("soulscrolls")
    if not (Dashboard.UI and Dashboard.UI.IsShown and Dashboard.UI.IsShown()) then
        Dashboard.Toggle()
    end
end

-- ---------------------------------------------------------------------------
-- Entry points
-- ---------------------------------------------------------------------------
-- Opening the window is now /dashboard's job (this is just a Dashboard tab), so
-- /scrolls only survives for its "sync" argument -- a distinct data-refresh
-- action, not a window toggle.
SLASH_UNCAPPEDSCROLLS1 = "/scrolls"
SlashCmdList["UNCAPPEDSCROLLS"] = function(arg)
    arg = (arg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if arg == "sync" then
        Request()
        DEFAULT_CHAT_FRAME:AddMessage(COLOR_HEAD .. "[Scrolls]|r Refreshing...")
    else
        DEFAULT_CHAT_FRAME:AddMessage(COLOR_HEAD .. "[Scrolls]|r type |cffffd100/dashboard|r to open Scroll Bonuses, or |cffffd100/scrolls sync|r to refresh.")
    end
end

-- Settings page (ESC > Interface > AddOns > Uncapped > Scrolls). Provided by the
-- shared UncappedUI widget library (UncappedOptions addon); guard on it so the
-- settings page just doesn't appear if that addon is missing.
if UncappedUI then
    local _, L = UncappedUI.CreatePanel("Scrolls",
        "Every customization-scroll bonus on your account -- Reach, Bounty, Fortune, Mastery and Delver.")

    L:Header("Scroll bonuses")
    L:Button("Open Scroll Bonuses", OpenInDashboard, 180)
    L:Note("Shows what each scroll you have used is actually giving you, including which "
        .. "instances your Scroll of Fortune bonuses landed on, plus your account-wide "
        .. "quest bonus to arena points. Also available with /scrolls.", 48)
end
