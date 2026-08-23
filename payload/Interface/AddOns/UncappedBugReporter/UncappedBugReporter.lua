--[[
  Uncapped Bug Reporter -- a friendlier front end for the existing !bug command,
  not a new one.

  Players already had a working path: type "!bug <message>" into the World
  channel, and the server watches that channel for the trigger and relays it
  to Discord. This addon gives them a proper multi-line window to write in
  instead of a one-line chat box, plus a live character counter and automatic
  zone context so "where" is never left blank.

  ⚠ Transport: the "!bug " chat trigger is NOT how this addon sends any more.
  Reports go out as CHUNKED ADDON MESSAGES on the REAGENTBANK prefix and are
  reassembled server-side by bug_report_chunked.cpp -- that is what lifted the
  cap from ~292 characters to 1500 (suggestion #145). The chat trigger still
  exists for players without the addon; nothing here uses it.

    SEND : SendAddonMessage("REAGENTBANK",
             "UBUGC:<i>/<n>:<b|s>:<slice>", "WHISPER", <own name>)

  Reassembled body:
    [<title>] <message> (<zone context>)

  The title rides in its own [brackets] so the Discord side can pull it out
  with one pattern (Lua: ^%s*%[(.-)%]%s*(.*)$) and use it verbatim, instead of
  synthesizing one by truncating the message body mid-word (which is what
  produced titles like "...it says it pro**" in the existing bug tracker before
  this addon existed). /bug <message> with no title (the quick one-liner path)
  falls back to that same truncate-the-message behavior, so it degrades to what
  already worked rather than sending a blank title.

  The addon still keeps the player in the World channel (EnsureWorldChannel):
  that is for reading replies and for the chat fallback, not for sending.

  Slash commands:
    /bug              opens the report window
    /bug <message>     sends immediately, no window, title auto-derived
    /bugreport         alias for /bug
]]

local ADDON = "UncappedBugReporter"
local WORLD_CHANNEL = "World"
local MAX_TITLE = 80    -- keeps "[title]" from eating the whole message budget

-- Chunked transport (suggestion #145, "give us more room to make suggestions").
--
-- SendChatMessage cannot carry more than 255 bytes, which is why in-game reports
-- topped out around 292 characters while anyone writing the same report in
-- Discord could use 1200. Nothing downstream was the limit -- the outbox already
-- took 900 and the database column is longtext -- so the whole cap was this send.
--
-- Addon messages are capped at 255 each too, so the report is split across
-- several and reassembled server-side by bug_report_chunked.cpp. Each chunk
-- carries its own index, the total and the kind, so order does not matter and a
-- lost chunk means the report never completes rather than arriving truncated.
local TRANSPORT_PREFIX = "REAGENTBANK"   -- shared client->server transport
local MAX_CHUNKS = 10                    -- must match MAX_CHUNKS server-side
local CHUNK_BODY = 180                   -- leaves room for "UBUGC:10/10:s:" and the prefix
local MAX_LONG_REPORT = 1500             -- under the server's 1800 commit trim

UncappedBugReporter = UncappedBugReporter or {}
local BR = UncappedBugReporter
BR.MAX_TITLE = MAX_TITLE
-- Message budget: total cap minus "!bug ", the "[]" wrapper, and one space
-- before the message -- computed against the shortest possible title (empty)
-- so it's always a safe upper bound regardless of the title actually used.
BR.MAX_REPORT = MAX_LONG_REPORT

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

--- The " (Zone - SubZone)" suffix, or "" if there is nothing worth saying, so a
--- report is never missing "where" even if the player forgets to type it.
--- GetSubZoneText() is often "" outdoors or the same as the zone name in an
--- instance, so it's only added when it actually adds information.
---
--- Returned SEPARATELY rather than pre-appended: the caller has to budget for it
--- before trimming, because the trim cuts from the end and that is exactly where
--- this lives.
local function ZoneSuffix()
    local zone, sub = GetZoneText() or "", GetSubZoneText() or ""
    local where
    if sub ~= "" and sub ~= zone then
        where = zone .. " - " .. sub
    else
        where = zone
    end
    if where == "" then return "" end
    return " (" .. where .. ")"
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
-- `asSuggestion` picks the transport's kind byte. It is an explicit ARGUMENT
-- rather than the old BR.sendAsSuggestion field, which was read here and set
-- precisely nowhere -- the suggestion path existed on the server and in this
-- transport, and no client route could ever reach it (report #485). That read
-- has now been removed too; a sticky flag would also mean one /suggestion
-- silently turning every later /bug into a suggestion.
function BR.Send(title, message, asSuggestion)
    local label = asSuggestion and "[Suggestion]" or "[Bug Report]"

    message = (message or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if message == "" then
        DEFAULT_CHAT_FRAME:AddMessage(asSuggestion
            and "|cffff8040[Suggestion]|r Describe the idea and what it would improve."
            or  "|cffff8040[Bug Report]|r Type what happened, where, and how to repeat it.")
        return false
    end

    title = (title or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if title == "" then title = DeriveTitle(message) end
    if #title > MAX_TITLE then title = title:sub(1, MAX_TITLE) end

    -- The title (already capped above) rides inside its own brackets so the
    -- Discord side can pull it out verbatim instead of synthesizing one by
    -- truncating the message body.
    local header = "[" .. title .. "] "
    local suffix = ZoneSuffix()

    -- Trim the MESSAGE to what is left after the wrapper, rather than trimming
    -- the assembled string. The old code built header + message + zone suffix and
    -- only then cut the whole thing to MAX_LONG_REPORT from the END -- so the
    -- longest, most detailed reports were exactly the ones that lost their
    -- location, which is the one thing the automatic zone context exists to
    -- guarantee. The editbox caps the message at 1500 and the header can add
    -- another 83 bytes on top, so this was reachable by typing.
    --
    -- Trim here rather than letting the transport do it silently -- a report cut
    -- off mid-sentence with no warning is worse than one visibly shortened.
    local budget = MAX_LONG_REPORT - #header - #suffix
    if budget < 1 then budget = 1 end
    if #message > budget then
        message = message:sub(1, budget)
        DEFAULT_CHAT_FRAME:AddMessage("|cffff8040" .. label .. "|r That was over "
            .. budget .. " characters, so the end was trimmed.")
    end

    local full = header .. message .. suffix

    local n = math.ceil(#full / CHUNK_BODY)
    if n < 1 then n = 1 end
    if n > MAX_CHUNKS then n = MAX_CHUNKS end

    local kind = asSuggestion and "s" or "b"
    for i = 1, n do
        SendAddonMessage(TRANSPORT_PREFIX,
            "UBUGC:" .. i .. "/" .. n .. ":" .. kind .. ":"
                .. full:sub((i - 1) * CHUNK_BODY + 1, i * CHUNK_BODY),
            "WHISPER", UnitName("player"))
    end

    -- No "sent!" here on purpose: the server confirms once it has reassembled
    -- every chunk, and tells you how many characters actually landed. Saying it
    -- from this side would claim success for a report that never completed.
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
    BR.Send(nil, msg, false)
end

-- Report #485: "Allow /suggestion to be created from ingame."
--
-- The server has understood the difference between a bug and a suggestion since
-- the chunked transport went in -- the kind byte is in the wire format and
-- bug_report_chunked.cpp routes on it. There was simply no way for a player to
-- SAY "this is a suggestion": /bug was the only command, and the flag it checked
-- was never set by anything. So every idea arrived filed as a bug.
--
-- Deliberately no UI here. The quick path is the whole point; someone with a
-- thought mid-dungeon types one line. The full window stays on /bug.
SLASH_UNCAPPEDSUGGESTION1 = "/suggestion"
SLASH_UNCAPPEDSUGGESTION2 = "/suggest"
SlashCmdList["UNCAPPEDSUGGESTION"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "" then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cffff8040[Suggestion]|r Usage: /suggestion <your idea>. "
            .. "Say what it would change and why it would be better.")
        return
    end
    BR.Send(nil, msg, true)
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
