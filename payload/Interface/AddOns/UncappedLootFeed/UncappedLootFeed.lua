-- UncappedLootFeed -- loot as it happens, in its own window, with a watchlist.
--
-- WHY A CLIENT-ONLY FEED
--   CHAT_MSG_LOOT already carries every line the player is entitled to see,
--   including OTHER group members' loot ("Bob receives loot: ..."). So the
--   interesting case -- knowing the thing you are farming just dropped for
--   someone else -- needs no server feed at all. Adding one would have put a
--   message on the wire per drop per player, which is precisely the standing
--   traffic that was just removed from the HP feed.
--
--   The cost is that it only sees loot while you are in range to be told, which
--   is the same limit chat has, and is what a player expects.
--
-- THE WATCHLIST
--   Matching is by item ID, resolved from the item link, NOT by name. Names are
--   localised and several unrelated items share one; an id cannot be ambiguous.
--   Entries are added by link or id, so "shift-click the thing you want" works.
--
--   Stored account-wide (SavedVariables, not PerCharacter) because a farm target
--   is an account-level intention -- re-adding it on every alt is exactly the
--   friction this exists to remove.
--
-- Window deliberately mirrors StatFeed's construction (backdrop, drag, resize,
-- saved position) so it reads as part of the same UI rather than a third style.

local ADDON = "UncappedLootFeed"

local PAD          = 10
local LINE_H       = 14
local MIN_WIDTH    = 220
local MAX_WIDTH    = 520
local MIN_HEIGHT   = 90

local DEFAULTS = {
    point    = "CENTER", x = 260, y = 0,
    width    = 320, height = 200,
    bgAlpha  = 0.8,
    maxLines = 100,     -- ring size; older lines fall off the top
    shown    = false,
    sound    = true,    -- play a sound when a watched item drops
    watch    = {},      -- [itemId] = itemName, kept for display only
}

local db
local frame, scroll, content
local lines = {}        -- newest last: { text = , watched = }
local rows  = {}

-- ---------------------------------------------------------------------------
-- Saved variables
-- ---------------------------------------------------------------------------
local function InitDB()
    UncappedLootFeedDB = UncappedLootFeedDB or {}
    db = UncappedLootFeedDB
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then
            -- Tables must be copied, not shared with DEFAULTS: a nested default
            -- assigned by reference would be mutated for every future login.
            if type(v) == "table" then db[k] = {} else db[k] = v end
        end
    end
end

local function SavePosition()
    if not frame then return end
    local point, _, _, x, y = frame:GetPoint()
    db.point, db.x, db.y = point, x, y
    db.width, db.height = frame:GetWidth(), frame:GetHeight()
end

-- ---------------------------------------------------------------------------
-- Item helpers
-- ---------------------------------------------------------------------------
-- Pull the numeric id out of an item link. Everything keys on this rather than
-- on the name -- see the note at the top.
local function LinkToItemId(link)
    if not link then return nil end
    local id = link:match("|Hitem:(%d+):")
    return id and tonumber(id) or nil
end

-- Accept a link, a bare id, or a name that resolves through the client cache.
-- Returns id, name -- or nil when it cannot be resolved, which the caller must
-- treat as "reject", never as a silent no-op.
local function ResolveItem(input)
    if not input or input == "" then return nil end

    local id = LinkToItemId(input)
    if not id then id = tonumber(input:match("^%s*(%d+)%s*$") or "") end

    if id then
        local name = GetItemInfo(id)
        return id, name or ("item " .. id)
    end

    -- Name path: only works if the client has seen the item this session, which
    -- is why it is the last resort rather than the primary route.
    local name, link = GetItemInfo(input)
    if link then
        local lid = LinkToItemId(link)
        if lid then return lid, name end
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- Feed
-- ---------------------------------------------------------------------------
local function Repaint()
    if not frame or not frame:IsShown() then return end

    local visible = math.floor((frame:GetHeight() - 40) / LINE_H)
    if visible < 1 then visible = 1 end

    for i = 1, visible do
        local row = rows[i]
        if not row then
            row = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i - 1) * LINE_H)
            row:SetJustifyH("LEFT")
            rows[i] = row
        end
        row:SetWidth(frame:GetWidth() - PAD * 2)

        -- Newest at the bottom, like a chat window.
        local entry = lines[#lines - visible + i]
        row:SetText(entry and entry.text or "")
        row:Show()
    end

    for i = visible + 1, #rows do rows[i]:SetText(""); rows[i]:Hide() end
end

local function Push(text, watched)
    lines[#lines + 1] = { text = text, watched = watched }
    while #lines > db.maxLines do table.remove(lines, 1) end
    Repaint()
end

-- ---------------------------------------------------------------------------
-- Watch alerts
-- ---------------------------------------------------------------------------
local function Alert(who, link)
    -- Reuse UncappedAlerts if it is loaded rather than building a second alert
    -- system; fall back to a raid warning frame, which is the loudest thing
    -- available without one.
    local msg = (who or "You") .. ": " .. (link or "?")

    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, "Wanted item dropped!\n" .. msg, ChatTypeInfo["RAID_WARNING"])
    end
    if db.sound then
        PlaySound("LEVELUP")
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Loot Feed]|r wanted item: " .. msg)
end

-- ---------------------------------------------------------------------------
-- Loot parsing
-- ---------------------------------------------------------------------------
-- CHAT_MSG_LOOT covers both "You receive loot: <link>x2." and
-- "Bob receives loot: <link>." -- one handler serves self and group, which is
-- the whole reason no server feed is needed.
local function OnLoot(msg)
    local link = msg:match("(|c%x+|Hitem:.-|h%[.-%]|h|r)")
    if not link then return end

    local id = LinkToItemId(link)
    if not id then return end

    local count = tonumber(msg:match("x(%d+)%.?%s*$") or "") or 1

    -- Whose line is this? The self forms are the localised YOU_LOOT /
    -- YOU_RECEIVE strings; anything else names a player, so take the first word
    -- rather than trying to match every localisation.
    local who = msg:match("^(%S+) receives loot")
        or msg:match("^(%S+) receives item")
    local mine = not who
    if mine then who = "You" end

    local watched = db.watch[id] ~= nil
    local prefix  = watched and "|cffffd100* |r" or ""
    local suffix  = count > 1 and (" x" .. count) or ""
    local nameCol = mine and "|cff40ff40" or "|cffaaaaaa"

    Push(prefix .. nameCol .. who .. "|r  " .. link .. suffix, watched)

    if watched then Alert(who, link) end
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------
local function BuildFrame()
    if frame then return end

    frame = CreateFrame("Frame", "UncappedLootFeedFrame", UIParent)
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
    frame:SetMinResize(MIN_WIDTH, MIN_HEIGHT)
    if frame.SetMaxResize then frame:SetMaxResize(MAX_WIDTH, 700) end
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition() end)
    frame:SetScript("OnSizeChanged", function(self)
        if self:GetWidth() > MAX_WIDTH then self:SetWidth(MAX_WIDTH) end
        Repaint()
    end)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", PAD + 2, -11)
    title:SetText("Loot Feed")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 1)
    close:SetScript("OnClick", function() frame:Hide(); db.shown = false end)

    content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", PAD, -30)
    content:SetPoint("BOTTOMRIGHT", -PAD, PAD)

    frame:Hide()
end

local function Toggle()
    BuildFrame()
    if frame:IsShown() then
        frame:Hide(); db.shown = false
    else
        frame:Show(); db.shown = true; Repaint()
    end
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------
SLASH_UNCAPPEDLOOTFEED1 = "/lootfeed"
SLASH_UNCAPPEDLOOTFEED2 = "/lf"
SlashCmdList["UNCAPPEDLOOTFEED"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = msg:match("^(%S*)%s*(.*)$")
    cmd = (cmd or ""):lower()

    if cmd == "" then
        Toggle()
        return
    end

    if cmd == "want" or cmd == "add" then
        local id, name = ResolveItem(rest)
        if not id then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4040[Loot Feed]|r could not read that item. Shift-click an item link, or give an item id.")
            return
        end
        db.watch[id] = name
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Loot Feed]|r watching for " .. (name or id) .. ".")
        return
    end

    if cmd == "unwant" or cmd == "remove" then
        local id, name = ResolveItem(rest)
        if not id then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4040[Loot Feed]|r could not read that item.")
            return
        end
        db.watch[id] = nil
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Loot Feed]|r no longer watching " .. (name or id) .. ".")
        return
    end

    if cmd == "list" then
        local any = false
        for id, name in pairs(db.watch) do
            DEFAULT_CHAT_FRAME:AddMessage("   " .. (name or "?") .. "  (" .. id .. ")")
            any = true
        end
        if not any then
            DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Loot Feed]|r watchlist is empty. /lootfeed want <item link>")
        end
        return
    end

    if cmd == "clear" then
        lines = {}
        Repaint()
        return
    end

    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Loot Feed]|r /lootfeed | want <item> | unwant <item> | list | clear")
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("CHAT_MSG_LOOT")
ev:SetScript("OnEvent", function(self, event, a1)
    if event == "ADDON_LOADED" then
        if a1 ~= ADDON then return end
        InitDB()
        BuildFrame()
        if db.shown then frame:Show(); Repaint() end
        return
    end

    if event == "CHAT_MSG_LOOT" and db then
        OnLoot(a1 or "")
    end
end)
