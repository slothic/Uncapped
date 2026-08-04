-- UncappedLootFeed -- loot as it happens, with a watchlist, as a Dashboard tab.
--
-- WHY A CLIENT-ONLY FEED  (unchanged, and load-bearing)
--   CHAT_MSG_LOOT already carries every line the player is entitled to see,
--   including OTHER group members' loot ("Bob receives loot: ..."). So the
--   interesting case -- knowing the thing you are farming just dropped for
--   someone else -- needs no server feed at all. Adding one would have put a
--   message on the wire per drop per player, which is precisely the standing
--   traffic that was removed from the HP feed.
--
--   The cost is that it only sees loot while you are in range to be told, which
--   is the same limit chat has, and is what a player expects.
--
-- THE WATCHLIST  (unchanged)
--   Matching is by item ID, resolved from the item link, NOT by name. Names are
--   localised and several unrelated items share one; an id cannot be ambiguous.
--
--   Stored account-wide (SavedVariables, not PerCharacter) because a farm target
--   is an account-level intention -- re-adding it on every alt is exactly the
--   friction this exists to remove.
--
-- WHAT CHANGED: NO MORE STANDALONE WINDOW
--   This used to build its own backdrop window mirroring StatFeed's. It is now a
--   Dashboard tab (UncappedLootFeed_UI.lua embeds into the Dashboard's content
--   panel like Soul Forge and the Vault do), so there is one window, one title
--   bar and one resize grip for the whole suite instead of a third style. The
--   old window's saved geometry keys are purged in InitDB below.
--
--   This file is now the ENGINE only: it owns the feed ring, the watchlist and
--   the event handling, and knows nothing about frames. It keeps recording loot
--   whether or not the Dashboard has ever been opened, so opening the tab shows
--   history rather than starting empty.
--
-- ROWS ARE STRUCTURED, NOT PRE-RENDERED TEXT
--   Entries used to be built into a finished string at capture time. They are
--   now records, because the UI needs the id (to show an icon and to make the
--   row clickable) and the count/name separately. Rendering moved to the UI.

local ADDON = "UncappedLootFeed"

local LF = _G.UncappedLootFeed or {}
_G.UncappedLootFeed = LF

LF.ADDON = ADDON
LF.version = "0.2"

local DEFAULTS = {
    maxLines    = 100,      -- ring size; older entries fall off
    sound       = true,     -- play a sound when a watched item drops
    alert       = true,     -- raid-warning banner when a watched item drops
    watchedOnly = false,    -- feed filter; OFF by default -- the feed shows ALL loot
    watch       = {},       -- [itemId] = itemName, kept for display only
}

local db
local feed = {}   -- newest LAST; the UI reverses for display

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

    -- Leftovers from the standalone window, which no longer exists. Dropped
    -- rather than migrated -- the Dashboard owns window geometry now.
    db.point, db.x, db.y = nil, nil, nil
    db.width, db.height, db.bgAlpha, db.shown = nil, nil, nil, nil

    LF.db = db
end

function LF.GetDB()
    if not db then InitDB() end
    return db
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
LF.LinkToItemId = LinkToItemId

-- Accept a link, a bare id, or a name. Returns id, name -- or nil when it cannot
-- be resolved, which the caller must treat as "reject", never as a silent no-op.
--
-- The name path now goes through the baked table first, so it works on a cold
-- cache; it used to depend on the client having seen the item this session,
-- which after a WDB wipe meant "never".
local function ResolveItem(input)
    if not input or input == "" then return nil end
    local Data = _G.UncappedLootFeedData

    local id = LinkToItemId(input)
    if not id then id = tonumber(input:match("^%s*(%d+)%s*$") or "") end

    if id then
        return id, (Data and Data.NameFor(id)) or GetItemInfo(id) or ("item " .. id)
    end

    if Data then
        -- Deliberately NOT limit 1: the cap is applied during the scan, in entry
        -- order, BEFORE results are ranked -- so asking for one result returns
        -- the lowest-id match rather than the best one. That resolved
        -- "Thunderfury" to the DEPRECATED duplicate (17802) instead of the real
        -- item (19019). Take the full ranked list and use its best entry.
        local hits = Data.Search(input)
        if hits[1] then return hits[1].id, hits[1].name end
    end

    local name, link = GetItemInfo(input)
    if link then
        local lid = LinkToItemId(link)
        if lid then return lid, name end
    end

    return nil
end
LF.ResolveItem = ResolveItem

-- ---------------------------------------------------------------------------
-- Feed
-- ---------------------------------------------------------------------------
local function Notify()
    if LF.UI and LF.UI.Refresh then LF.UI.Refresh() end
end

local function Push(entry)
    feed[#feed + 1] = entry
    while #feed > (db.maxLines or 100) do table.remove(feed, 1) end
    Notify()
end

-- Newest first, which is what a scrolling panel wants (the old chat-style
-- window put newest at the bottom because it had no scrollbar to speak of).
-- Honours the watchedOnly filter.
function LF.GetFeed()
    local out = {}
    local onlyWatched = db and db.watchedOnly
    for i = #feed, 1, -1 do
        local e = feed[i]
        if not onlyWatched or db.watch[e.id] ~= nil then
            out[#out + 1] = e
        end
    end
    return out
end

function LF.ClearFeed()
    feed = {}
    Notify()
end

function LF.FeedCount()
    return #feed
end

-- ---------------------------------------------------------------------------
-- Watchlist
-- ---------------------------------------------------------------------------
function LF.IsWatched(id)
    return db and db.watch[tonumber(id) or -1] ~= nil
end

function LF.Watch(id, name)
    id = tonumber(id)
    if not id then return false end
    local Data = _G.UncappedLootFeedData
    db.watch[id] = name or (Data and Data.NameFor(id)) or ("item " .. id)
    Notify()
    return true
end

function LF.Unwatch(id)
    id = tonumber(id)
    if not id then return false end
    db.watch[id] = nil
    Notify()
    return true
end

function LF.ToggleWatch(id, name)
    if LF.IsWatched(id) then
        LF.Unwatch(id)
        return false
    end
    LF.Watch(id, name)
    return true
end

-- Array of { id =, name =, q = }, sorted by name so the list is stable between
-- sessions (pairs() order over the saved table is not).
function LF.GetWatchlist()
    local Data = _G.UncappedLootFeedData
    local out = {}
    if not db then return out end
    for id, name in pairs(db.watch) do
        -- Prefer a live/baked name over the one stored when it was added: an
        -- entry added from a cold cache was saved as "item 12345".
        local best = (Data and Data.NameFor(id)) or name
        if (not best or best:match("^item %d+$")) and name and name ~= "" then best = name end
        out[#out + 1] = {
            id = id,
            name = best,
            q = (Data and Data.QualityFor(id)) or 1,
        }
    end
    table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
    return out
end

function LF.WatchCount()
    local n = 0
    if db then for _ in pairs(db.watch) do n = n + 1 end end
    return n
end

-- ---------------------------------------------------------------------------
-- Watch alerts
-- ---------------------------------------------------------------------------
local function Alert(who, link)
    -- Reuse the raid warning frame rather than building a second alert system;
    -- it is the loudest thing available without one.
    local msg = (who or "You") .. ": " .. (link or "?")

    if db.alert and RaidNotice_AddMessage and RaidWarningFrame then
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
-- CHAT_MSG_LOOT covers "You receive loot: <link>x2.", "Bob receives loot:
-- <link>." and the quest/craft "receives item:" forms -- one handler serves
-- self, group and turn-ins, which is the whole reason no server feed is needed.
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

    Push({
        id      = id,
        link    = link,
        who     = who,
        mine    = mine,
        count   = count,
        watched = watched,
        time    = time and time() or 0,
    })

    if watched then Alert(who, link) end
end

-- ---------------------------------------------------------------------------
-- Opening the tab
-- ---------------------------------------------------------------------------
-- The slash commands are kept as ALIASES rather than removed: they are muscle
-- memory, they are what the Dashboard's own placeholder text tells people to
-- type, and /lootfeed is a faster way to reach the tab than opening the
-- Dashboard and clicking. They now drive the same tab the buttons do.
local TAB_KEY = "lootfeed"

function LF.OpenTab()
    local Core = _G.UncappedDashboard
    if not Core or not Core.SetTab then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4040[Loot Feed]|r needs UncappedDashboard, which isn't loaded -- enable it in AddOns and reload.")
        return false
    end
    Core.SetTab(TAB_KEY)
    if Core.UI and Core.UI.Open then Core.UI.Open() end
    return true
end

function LF.ToggleTab()
    local Core = _G.UncappedDashboard
    if not Core then return LF.OpenTab() end
    -- Already looking at this tab -> close, so /lf toggles like it used to.
    if Core.UI and Core.UI.IsShown and Core.UI.IsShown() and Core.state and Core.state.tab == TAB_KEY then
        Core.UI.Close()
        return false
    end
    return LF.OpenTab()
end

-- ---------------------------------------------------------------------------
-- Slash commands -- every one of these is now also doable in the tab
-- ---------------------------------------------------------------------------
SLASH_UNCAPPEDLOOTFEED1 = "/lootfeed"
SLASH_UNCAPPEDLOOTFEED2 = "/lf"
SlashCmdList["UNCAPPEDLOOTFEED"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = msg:match("^(%S*)%s*(.*)$")
    cmd = (cmd or ""):lower()

    if cmd == "" then
        LF.ToggleTab()
        return
    end

    if cmd == "want" or cmd == "add" then
        local id, name = ResolveItem(rest)
        if not id then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4040[Loot Feed]|r could not read that item. Shift-click an item link, or give an item id -- or just search for it in the Loot Feed tab.")
            return
        end
        LF.Watch(id, name)
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Loot Feed]|r watching for " .. (name or id) .. ".")
        return
    end

    if cmd == "unwant" or cmd == "remove" then
        local id, name = ResolveItem(rest)
        if not id then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4040[Loot Feed]|r could not read that item.")
            return
        end
        LF.Unwatch(id)
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Loot Feed]|r no longer watching " .. (name or id) .. ".")
        return
    end

    if cmd == "list" then
        local list = LF.GetWatchlist()
        if #list == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Loot Feed]|r watchlist is empty. Open the Loot Feed tab and search for an item, or /lootfeed want <item link>")
            return
        end
        for _, it in ipairs(list) do
            DEFAULT_CHAT_FRAME:AddMessage("   " .. (it.name or "?") .. "  (" .. it.id .. ")")
        end
        return
    end

    if cmd == "clear" then
        LF.ClearFeed()
        return
    end

    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Loot Feed]|r /lootfeed | want <item> | unwant <item> | list | clear  -- all of these are in the Dashboard's Loot Feed tab too.")
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
        return
    end

    if event == "CHAT_MSG_LOOT" and db then
        OnLoot(a1 or "")
    end
end)
