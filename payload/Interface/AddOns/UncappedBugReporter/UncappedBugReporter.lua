--[[
  Uncapped Bug Reporter -- a friendlier front end for the existing !bug command,
  not a new one.

  Players already have a working path: type "!bug <message>" into the World
  channel, and the server watches that channel for the trigger and relays it
  to Discord (replying with its own usage message if the text after "!bug " is
  empty). There is no client -> server addon-message path on this realm's pipe
  (see UncappedChat.lua's design note on why its own input box posts to the
  World channel instead) -- so this addon sends reports out the exact same way,
  it just gives players a proper multi-line window to write them in instead of
  a one-line chat box, plus a live character counter (chat messages truncate
  silently past the client's own length cap) and automatic zone context so
  "where" is never left blank.

  Wire format:
    !bug [<title>] <message> (<zone context>)

  The title rides in its own [brackets] so the Discord side can pull it out
  with one pattern (Lua: ^!bug%s*%[(.-)%]%s*(.*)$) and use it verbatim,
  instead of synthesizing one by truncating the message body mid-word (which
  is what produced titles like "...it says it pro**" in the existing bug
  tracker before this addon existed). /bug <message> with no title (the quick
  chat-only path) falls back to that same truncate-the-message behavior, so it
  degrades to what already worked rather than sending a blank title.

  Transport:
    SEND : SendChatMessage("!bug [title] message", "CHANNEL", nil, <World channel id>)

  Slash commands:
    /bug              opens the report window
    /bug <message>     sends immediately, no window, title auto-derived
    /bugreport         alias for /bug
]]

local ADDON = "UncappedBugReporter"
local WORLD_CHANNEL = "World"
local BUG_PREFIX = "!bug "
local MAX_MESSAGE = 255 -- SendChatMessage's own hard cap on this client
local MAX_TITLE = 80    -- keeps "[title]" from eating the whole message budget

UncappedBugReporter = UncappedBugReporter or {}
local BR = UncappedBugReporter
BR.MAX_TITLE = MAX_TITLE
-- Message budget: total cap minus "!bug ", the "[]" wrapper, and one space
-- before the message -- computed against the shortest possible title (empty)
-- so it's always a safe upper bound regardless of the title actually used.
BR.MAX_REPORT = MAX_MESSAGE - #BUG_PREFIX - 3

local DEFAULTS = {
    point = { "CENTER", "UIParent", "CENTER", 0, 80 },
}

local db

local function InitDB()
    if type(UncappedBugReporterDB) ~= "table" then UncappedBugReporterDB = {} end
    db = UncappedBugReporterDB
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
end

function BR.GetDB()
    return db
end

--- Find the numeric index of the World channel, or nil if not currently in it.
local function WorldChannelIndex()
    local id = GetChannelName(WORLD_CHANNEL)
    if id and id > 0 then return id end
    return nil
end

--- JoinPermanentChannel (not /join) is what makes the client remember the
--- channel across sessions -- same technique UncappedChat uses to fix "not in
--- World chat" for players who don't have that addon loaded. Called lazily
--- (on login, and again as a fallback right before sending) rather than at
--- ADDON_LOADED, since the channel list isn't populated that early.
local function EnsureWorldChannel()
    if WorldChannelIndex() then return end
    JoinPermanentChannel(WORLD_CHANNEL, nil, 1, false)
end

--- Appends "(Zone - SubZone)" so a report is never missing "where" even if the
--- player forgets to type it. GetSubZoneText() is often "" outdoors or the
--- same as the zone name in an instance, so it's only added when it actually
--- adds information.
local function WithZoneContext(text)
    local zone, sub = GetZoneText() or "", GetSubZoneText() or ""
    local where
    if sub ~= "" and sub ~= zone then
        where = zone .. " - " .. sub
    else
        where = zone
    end
    if where == "" then return text end
    return text .. " (" .. where .. ")"
end

--- Derives a title the same way the Discord side already used to (before it
--- had a real title to work with): the message itself, cut to MAX_TITLE.
--- Used for the quick /bug <message> chat-only path, which has no separate
--- title field to draw on.
local function DeriveTitle(message)
    if #message <= MAX_TITLE then return message end
    return message:sub(1, MAX_TITLE)
end

--- Sends one bug report over the World channel. Returns true if it went out,
--- false (with a chat explanation) if it couldn't.
function BR.Send(title, message)
    message = (message or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if message == "" then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff8040[Bug Report]|r Type what happened, where, and how to repeat it.")
        return false
    end

    title = (title or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if title == "" then title = DeriveTitle(message) end
    if #title > MAX_TITLE then title = title:sub(1, MAX_TITLE) end

    local id = WorldChannelIndex()
    if not id then
        EnsureWorldChannel()
        id = WorldChannelIndex()
    end
    if not id then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff8040[Bug Report]|r Not in the World channel yet -- try again in a moment.")
        return false
    end

    -- Trim to the channel's own cap rather than letting SendChatMessage do it
    -- silently -- a report cut off mid-sentence with no warning is worse than
    -- one visibly shortened here. The title (already capped above) rides
    -- inside its own brackets so the Discord side can pull it out verbatim
    -- instead of synthesizing one by truncating the message body.
    local full = BUG_PREFIX .. "[" .. title .. "] " .. WithZoneContext(message)
    if #full > MAX_MESSAGE then
        full = full:sub(1, MAX_MESSAGE)
    end

    SendChatMessage(full, "CHANNEL", nil, id)
    DEFAULT_CHAT_FRAME:AddMessage("|cffff8040[Bug Report]|r Sent -- thank you!")
    return true
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------
SLASH_UNCAPPEDBUGREPORTER1 = "/bug"
SLASH_UNCAPPEDBUGREPORTER2 = "/bugreport"
SlashCmdList["UNCAPPEDBUGREPORTER"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "" then
        if BR.UI and BR.UI.Open then BR.UI.Open() end
        return
    end
    -- No title field on this quick path -- Send() derives one from the
    -- message itself.
    BR.Send(nil, msg)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" then
        if name == ADDON then InitDB() end
        return
    end
    -- PLAYER_ENTERING_WORLD
    EnsureWorldChannel()
end)
