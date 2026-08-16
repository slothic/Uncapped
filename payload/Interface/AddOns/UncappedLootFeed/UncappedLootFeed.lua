-- UncappedLootFeed -- loot as it happens, with a watchlist, as a Dashboard tab.
--
-- WHY MOSTLY CLIENT-ONLY  (the original reasoning, now with one exception)
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
-- THE EXCEPTION: THE VAULT  (report #214)
--   "CHAT_MSG_LOOT carries every line" stopped being true when the Vault started
--   auto-routing loot. An item that goes straight to the Vault never generates a
--   CHAT_MSG_LOOT line at all -- the server announces it on the personal loot
--   CHANNEL instead (LootVault::Ingest -> GrandmasterLoot::NotifyPlayerChannel).
--   So the only loot still reaching this feed was what STAYS IN BAGS: quest
--   items, .keep-listed items, lockboxes -- plus other players' loot lines. Which
--   is exactly what was reported: "it only shows quest items".
--
--   The channel line cannot be scraped for it: it carries the item NAME only, and
--   everything here keys on item ID (see below). So the server now also pushes a
--   structured "ULFV:" addon message carrying the id, and this file consumes it.
--   That is ONE message per drop for the looter only -- not per player per drop,
--   which is the traffic the original note was rejecting -- and bulk operations
--   are batched server-side into a handful of messages rather than hundreds.
--
--   Bag loot and Vault loot are tagged (entry.src) and can be filtered apart, so
--   a player who does not care about the Vault stream can turn it off.
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
LF.version = "0.3"

local DEFAULTS = {
    maxLines    = 100,      -- ring size; older entries fall off
    sound       = true,     -- play a sound when a watched item drops
    alert       = true,     -- raid-warning banner when a watched item drops
    watch       = {},       -- [itemId] = itemName, kept for display only

    -- ---- pop-out window (#125: "make a popout loot window like the Stat feed")
    -- The window is a peer of the Dashboard tab, not a replacement: the tab is
    -- where you search 25,000 items to build a watchlist, the window is what you
    -- leave open while you play. Both read the same ring.
    popout        = false,  -- is the window open
    popoutCompact = false,  -- window folded down to just the stream
    popoutSource  = true,   -- show the "Drops from X in Y" line under watched rows
    window        = {},     -- point/x/y/width/height, owned by UncappedUIKit

    -- ---- feed filters (#214: "options of filtering what loot you want to see")
    -- Every one of these defaults to "show everything", because a filter a player
    -- did not ask for looks exactly like the bug this feature was reported as.
    watchedOnly = false,    -- only items on the watchlist
    minQuality  = 0,        -- 0 = any; otherwise the ITEM_QUALITY_* floor
    showBags    = true,     -- loot that landed in your bags (CHAT_MSG_LOOT)
    showVault   = true,     -- loot the server auto-routed to the Vault (ULFV)
    showOthers  = true,     -- other players' loot lines
}

local db
local feed = {}   -- newest LAST; the UI reverses for display

-- Prefix for the whole server->client addon pipe; see
-- ReagentBankChannelProtocol::ADDON_MESSAGE_PREFIX. Every server push shares it,
-- with the command tag as the first token of the body.
local ADDON_PIPE_PREFIX = "UNC"

-- Where a feed entry came from. Stored on the entry rather than derived, because
-- "it went to the Vault" is a fact about the event, not about the item.
local SRC_BAG   = "bag"
local SRC_VAULT = "vault"
LF.SRC_BAG, LF.SRC_VAULT = SRC_BAG, SRC_VAULT

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
-- TWO VIEWS NOW, so a single LF.UI hook is no longer enough: the Dashboard tab
-- and the pop-out window both paint the same ring and both have to hear about
-- every change. Views register themselves; the engine does not know or care how
-- many there are, which is what let the window be added without touching a line
-- of the tab's refresh logic.
local views = {}

function LF.RegisterView(refresh)
    if type(refresh) == "function" then
        views[#views + 1] = refresh
    end
end

local function Notify()
    -- LF.UI.Refresh is kept as well as the registry: it is the tab's published
    -- entry point and other files call it directly.
    if LF.UI and LF.UI.Refresh then LF.UI.Refresh() end
    for i = 1, #views do
        views[i]()
    end
end
LF.Notify = Notify

-- ---------------------------------------------------------------------------
-- Session totals -- the summary block at the top of the pop-out window.
-- ---------------------------------------------------------------------------
-- Counted as loot ARRIVES rather than derived from the ring, because the ring is
-- capped at maxLines and drops its oldest entries: a session total computed from
-- it would silently stop rising after 100 items, which is exactly the sort of
-- quietly-wrong number that makes people distrust the whole panel.
local session = { items = 0, stacks = 0, vault = 0, watched = 0, started = nil }

function LF.SessionStats()
    local elapsed = 0
    if session.started then elapsed = math.max(0, (GetTime() or 0) - session.started) end
    return session.items, session.vault, session.watched, elapsed, session.stacks
end

function LF.ResetSession()
    session.items, session.stacks, session.vault, session.watched = 0, 0, 0, 0
    session.started = GetTime and GetTime() or 0
    Notify()
end

local function CountSession(entry)
    if entry.overflow then return end
    if not entry.mine then return end     -- someone else's drop is not your haul
    session.items = session.items + (entry.count or 1)
    session.stacks = session.stacks + 1
    if entry.src == SRC_VAULT then session.vault = session.vault + 1 end
    if entry.watched then session.watched = session.watched + 1 end
end

local function Push(entry)
    if not session.started then session.started = GetTime and GetTime() or 0 end
    CountSession(entry)
    feed[#feed + 1] = entry
    while #feed > (db.maxLines or 100) do table.remove(feed, 1) end
    Notify()
end

-- ---------------------------------------------------------------------------
-- Filters
-- ---------------------------------------------------------------------------
-- Quality is resolved through the baked table (UncappedLootFeedData), NOT from
-- the link's colour code: the launcher wipes Cache/WDB every launch, so a link's
-- colour is the server's own answer and is always right, but a Vault entry has
-- no link at all and would otherwise be unfilterable. One source for both.
--
-- Memoised onto the entry at capture time so a repaint of a 100-row feed does
-- not do 100 lookups; recomputed later if it was unknown then (an item the
-- client had never seen and the baked table did not carry).
local function QualityOf(e)
    if e.q then return e.q end
    local Data = _G.UncappedLootFeedData
    local q = Data and Data.QualityFor(e.id)
    e.q = q
    return q
end

-- An entry is shown unless a filter positively rejects it. Unknowns pass: hiding
-- a line because a lookup failed is the same visible bug as #214 itself.
local function Passes(e)
    if e.overflow then
        -- "and N more stacks went to the Vault" -- a Vault event with no item, so
        -- it answers only to the Vault toggle.
        return db.showVault ~= false
    end

    if db.watchedOnly and db.watch[e.id] == nil then return false end

    if e.src == SRC_VAULT then
        if db.showVault == false then return false end
    elseif db.showBags == false then
        return false
    end

    if not e.mine and db.showOthers == false then return false end

    local minQ = db.minQuality or 0
    if minQ > 0 then
        local q = QualityOf(e)
        if q and q < minQ then return false end
    end

    return true
end
LF.Passes = Passes

-- Newest first, which is what a scrolling panel wants (the old chat-style
-- window put newest at the bottom because it had no scrollbar to speak of).
-- Honours every filter above.
function LF.GetFeed()
    local out = {}
    if not db then return out end
    for i = #feed, 1, -1 do
        local e = feed[i]
        if Passes(e) then out[#out + 1] = e end
    end
    return out
end

-- How many entries the filters are currently hiding, so the status line can say
-- so -- an empty feed with a filter on is otherwise indistinguishable from a
-- feed that is genuinely not receiving anything, which is how #214 read.
function LF.FilteredOutCount()
    if not db then return 0 end
    local n = 0
    for i = 1, #feed do
        if not Passes(feed[i]) then n = n + 1 end
    end
    return n
end

-- True when anything is narrowing the feed. Used by the UI to decide whether to
-- offer a "show everything" reset.
function LF.AnyFilterActive()
    if not db then return false end
    return (db.watchedOnly and true or false)
        or (db.minQuality or 0) > 0
        or db.showBags == false
        or db.showVault == false
        or db.showOthers == false
end

function LF.ResetFilters()
    if not db then return end
    db.watchedOnly = false
    db.minQuality  = 0
    db.showBags    = true
    db.showVault   = true
    db.showOthers  = true
    Notify()
end

-- Single setter so the UI never writes db keys directly and every change
-- repaints. Unknown keys are ignored rather than stored.
local FILTER_KEYS = { watchedOnly = true, minQuality = true, showBags = true, showVault = true, showOthers = true }
function LF.SetFilter(key, value)
    if not db or not FILTER_KEYS[key] then return end
    db[key] = value
    Notify()
end

function LF.GetFilter(key)
    if not db then return nil end
    return db[key]
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
    local Data = _G.UncappedLootFeedData

    Push({
        id      = id,
        link    = link,
        who     = who,
        mine    = mine,
        count   = count,
        watched = watched,
        src     = SRC_BAG,
        q       = Data and Data.QualityFor(id) or nil,
        time    = time and time() or 0,
    })

    if watched then Alert(who, link) end
end

-- ---------------------------------------------------------------------------
-- Vault loot  (server push -- see the note at the top of this file)
-- ---------------------------------------------------------------------------
-- Wire format, over the shared "UNC" pipe:
--     ULFV:<itemId>,<count>,<randomPropId>;<itemId>,<count>,<randomPropId>;...
--     ULFVX:<stacks>
--
-- One shape for both the single drop and the batched bulk case, so this is one
-- parser. Rows are deltas ("this much was just banked"), not the absolute
-- amounts VLTUPD carries -- a feed is a log of events, and two identical drops
-- are two lines, not one.
--
-- No link and no name on the wire: the id is the only thing that cannot be
-- ambiguous or localised, and the client resolves the rest itself (baked table
-- first, then whatever the live cache knows). Same rule the watchlist follows.
local function OnVaultLoot(body)
    local rows = body:match("^ULFV:(.*)$")
    if rows then
        for idText, countText, propText in rows:gmatch("(%d+),(%d+),(%-?%d+);") do
            local id = tonumber(idText)
            local count = tonumber(countText) or 1
            if id then
                local watched = db.watch[id] ~= nil
                local Data = _G.UncappedLootFeedData

                Push({
                    id      = id,
                    -- Resolved at render time instead: a Vault item is very often
                    -- one the client has never seen, so a link captured here would
                    -- be nil forever even after the cache fills in.
                    link    = nil,
                    prop    = tonumber(propText) or 0,
                    who     = "You",
                    mine    = true,
                    count   = count,
                    watched = watched,
                    src     = SRC_VAULT,
                    q       = Data and Data.QualityFor(id) or nil,
                    time    = time and time() or 0,
                })

                if watched then
                    Alert("You", (Data and Data.ColoredName(id)) or ("item " .. id))
                end
            end
        end
        return true
    end

    local more = body:match("^ULFVX:(%d+)$")
    if more then
        -- The server itemises at most 100 stacks per bulk operation; this is the
        -- tail so a big sweep does not silently look smaller than it was.
        Push({
            overflow = tonumber(more) or 0,
            src      = SRC_VAULT,
            mine     = true,
            who      = "You",
            time     = time and time() or 0,
        })
        return true
    end

    return false
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

-- The pop-out window (#125). The engine only forwards: the window itself lives
-- in UncappedLootFeed_Popout.lua and registers here when it builds, so a client
-- missing that file (or UncappedUI) degrades to the tab instead of erroring.
function LF.TogglePopout()
    if LF.Popout and LF.Popout.Toggle then return LF.Popout.Toggle() end
    DEFAULT_CHAT_FRAME:AddMessage("|cffff4040[Loot Feed]|r the pop-out window needs UncappedUI -- enable it in AddOns and reload.")
    return false
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
        --[[ Bare /lootfeed opens the POP-OUT, not the Dashboard tab.
             Owner ruling 2026-08-16, following the "Escape closes the loot feed"
             reports.

             The popout was never the problem -- it carries escapeClose = false
             and has since #384. The tab was: Escape closes the DASHBOARD, which
             is deliberate and correct for a panel you open and dismiss, and it
             took the feed down with it. So the fix is which of the two the bare
             command reaches for, not the Escape behaviour of either.

             The tab is still one click away inside the Dashboard, and
             `/lootfeed tab` asks for it by name.

             ⚠ Falls back to the tab SILENTLY when the popout cannot be built
             (UncappedUI or _Popout.lua missing) rather than calling
             LF.TogglePopout, which prints an error and opens nothing. A bare
             command has to open something. ]]
        if LF.Popout and LF.Popout.Toggle then
            LF.Popout.Toggle()
        else
            LF.ToggleTab()
        end
        return
    end

    if cmd == "tab" then
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

    -- #125 asked for this by name ("make a popout loot window like the Stat
    -- feed"), so it gets short aliases rather than living only behind a button.
    if cmd == "window" or cmd == "popout" or cmd == "pop" then
        LF.TogglePopout()
        return
    end

    if cmd == "reset" or cmd == "session" then
        LF.ResetSession()
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Loot Feed]|r session totals reset.")
        return
    end

    -- The escape hatch for a player who has filtered themselves into an empty
    -- feed and cannot find which toggle did it. Same button exists in the tab.
    if cmd == "all" or cmd == "showall" or cmd == "filters" then
        LF.ResetFilters()
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Loot Feed]|r filters cleared -- showing all loot, bags and Vault.")
        return
    end

    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Loot Feed]|r /lootfeed (pop-out) | tab | want <item> | unwant <item> | list | clear | all | reset  -- all of these are in the Dashboard's Loot Feed tab too.")
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("CHAT_MSG_LOOT")
-- Vault loot never produces a CHAT_MSG_LOOT line -- see the note at the top.
-- CHAT_MSG_ADDON is never rendered by the client, so nothing leaks into chat if
-- another addon on the same pipe is missing.
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:SetScript("OnEvent", function(self, event, a1, a2)
    if event == "ADDON_LOADED" then
        if a1 ~= ADDON then return end
        InitDB()
        return
    end

    if not db then return end

    if event == "CHAT_MSG_LOOT" then
        OnLoot(a1 or "")
        return
    end

    -- CHAT_MSG_ADDON: a1 = prefix, a2 = body.
    if event == "CHAT_MSG_ADDON" and a1 == ADDON_PIPE_PREFIX and a2 then
        OnVaultLoot(a2)
    end
end)

-- ---------------------------------------------------------------------------
-- Settings page  (ESC > Interface > AddOns > Uncapped > Loot Feed)
-- ---------------------------------------------------------------------------
-- Guarded on UncappedUI because the hub is an OPTIONAL dependency: a player who
-- has disabled UncappedOptions still gets a working feed, just without a
-- settings page. Same shape UncappedGCD uses.
--
-- Deliberately only the things that are NOT already one click away in the
-- window itself. The filters live on the feed, where you can see what they do
-- to it; putting a second copy of them in here would give two controls over one
-- state and no clue which one you last touched.
if UncappedUI then
    local panel, L = UncappedUI.CreatePanel("Loot Feed",
        "The scrolling loot stream: its pop-out window, and what it does when something you are farming for drops.")

    L:Header("Pop-out window")
    L:Note("A small window you can move, resize and leave open while you play -- the same stream as the Dashboard's Loot Feed tab. It remembers where you put it and whether it was open.", 40)

    L:Check("Show the pop-out loot window",
        function() return LF.GetDB().popout end,
        function(v)
            if v then
                if LF.Popout and LF.Popout.Show then LF.Popout.Show() end
            else
                if LF.Popout and LF.Popout.Hide then LF.Popout.Hide() end
            end
        end)

    L:Check("Show where watched items drop",
        function() return LF.GetDB().popoutSource ~= false end,
        function(v)
            LF.GetDB().popoutSource = v and true or false
            if LF.Notify then LF.Notify() end
        end)

    L:Gap(6)
    L:Header("When something you are watching drops")
    L:Note("Items on your watchlist are called out in the feed with a gold outline. These two decide how loudly it happens outside the window.", 28)

    L:Check("Play a sound",
        function() return LF.GetDB().sound end,
        function(v) LF.GetDB().sound = v and true or false end)

    L:Check("Flash a banner across the screen",
        function() return LF.GetDB().alert end,
        function(v) LF.GetDB().alert = v and true or false end)

    L:Gap(6)
    L:Header("History")
    -- "%d", because the hub's slider formats "%.2f" by default and a line count
    -- of "100.00" reads like a bug in the panel.
    L:Slider("Loot lines to keep", 25, 500, 25,
        function() return LF.GetDB().maxLines or 100 end,
        function(v)
            LF.GetDB().maxLines = v
            if LF.Notify then LF.Notify() end
        end, "%d")
    L:Note("How far back the feed remembers. Older lines fall off the end; this is only the on-screen history, nothing is lost from your bags or Vault.", 28)

    L:Button("Reset session totals", function() LF.ResetSession() end, 180)
end
