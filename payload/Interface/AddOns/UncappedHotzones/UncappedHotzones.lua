-- UncappedHotzones
--
-- A thin scrolling bar pinned to the very top of the screen that lists the
-- currently-active Mythic+ hotzones: RAIDS in red, DUNGEONS in cyan, each with a
-- live "time left" countdown.
--
-- The server pushes the list on the player's personal channel (UHOT) on login
-- and every ~15s (so it also picks up the hourly rotation); the countdown is
-- ticked down locally between pushes. The UHOT lines are filtered out of chat.

-- ---------------------------------------------------------------------------
-- Settings. Live values live in `db`; they are persisted to the account-wide
-- UncappedHotzonesDB SavedVariable at ADDON_LOADED (see the loader at the
-- bottom). Every knob is applied both on load and on change, so the in-game
-- settings page (ESC > Interface > AddOns > Uncapped > Hotzones) works live.
-- ---------------------------------------------------------------------------
local defaults = {
    enabled      = true,                    -- show the hotzone bar at all
    speed        = 55,                       -- scroll speed, pixels/second
    height       = 16,                       -- bar height, pixels
    bgAlpha      = 0.55,                      -- dark background opacity
    raidColor    = { 1.0, 0.25, 0.25 },      -- RAID entry colour (was ffff4040)
    dungeonColor = { 0.235, 0.905, 1.0 },    -- DUNGEON entry colour (was ff3ce7ff)
}

-- Start from a private copy of the defaults so the frame below can be built with
-- sane values; the loader re-points `db` at the saved table and re-applies.
local db = {}
for k, v in pairs(defaults) do
    if type(v) == "table" then db[k] = { v[1], v[2], v[3] } else db[k] = v end
end

local panelRefreshers = {}   -- settings widgets to resync after the DB loads

-- ---------------------------------------------------------------------------
-- Bar frame: full screen width so the text scrolls off the screen edges (WotLK
-- 3.3.5 has no child-clipping, so the viewport does the clipping).
--
-- The dark background sits at LOW strata (tucked BEHIND the minimap, as before),
-- but the scrolling text lives in a child frame one strata HIGHER, so it draws
-- cleanly OVER the player's buff icons rather than being hidden behind them.
-- ---------------------------------------------------------------------------
local bar = CreateFrame("Frame", "UncappedHotzoneBar", UIParent)
bar:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
bar:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", 0, 0)
bar:SetHeight(db.height)
bar:SetFrameStrata("LOW")
bar:Hide()

bar.bg = bar:CreateTexture(nil, "BACKGROUND")
bar.bg:SetAllPoints(bar)
bar.bg:SetTexture(0, 0, 0)
bar.bg:SetAlpha(db.bgAlpha)

-- Text layer, raised above the buffs so the text is never clipped by them.
local textLayer = CreateFrame("Frame", nil, bar)
textLayer:SetAllPoints(bar)
textLayer:SetFrameStrata("HIGH")

bar.text = textLayer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
bar.text:SetJustifyH("LEFT")
bar.text:SetPoint("LEFT", textLayer, "LEFT", 0, 0)

-- Player window zoom (ESC > Interface > AddOns > Uncapped, or /uiscale).
--
-- ⚠ THIS IS A SCREEN-EDGE STRIP, NOT A WINDOW, so it opts out of both of the
-- zoom system's position fix-ups:
--
--   keepPosition = false  its anchors are TOPLEFT/TOPRIGHT of UIParent at
--                         offset 0, so it spans the screen at any scale and
--                         there is no offset worth rewriting.
--   clamp        = false  the clamp keeps at least 60 units of a frame on
--                         screen; a bar deliberately flush with the top edge
--                         and only ~20 units tall reads as "off screen" to
--                         that rule and would be shoved 40 units DOWN into the
--                         middle of the player's buffs.
--
-- What the zoom does do here is scale the bar's height and its text, which is
-- the whole point of the setting -- and that is exactly why ScreenWidth below
-- had to change.
if UncappedScale_Register then
    UncappedScale_Register(bar, { keepPosition = false, clamp = false })
end

-- The scroll distance, in BAR units.
--
-- ⚠ It cannot be UIParent:GetWidth() any more. That is measured in UIParent
-- units, while `offset` is a SetPoint offset on a font string inside the bar
-- and scrollWidth is GetStringWidth() -- both in the BAR's units. Once the bar
-- carries the player's zoom the two scales differ, and mixing them made the
-- text wrap early (zoomed in) or crawl in from off-screen (zoomed out). This is
-- the GetScale/GetEffectiveScale drift bug in miniature.
--
-- Still derived from UIParent rather than bar:GetWidth(), for the original
-- reason: GetWidth() can read stale/zero before the first layout, which reset
-- the scroll early and left the text crawling only part-way across.
local function ScreenWidth()
    local barEff = bar:GetEffectiveScale()
    local uiEff = UIParent:GetEffectiveScale()
    local w = UIParent:GetWidth() or 1024
    if barEff and barEff > 0 and uiEff and uiEff > 0 then
        return w * uiEff / barEff
    end
    return w
end

-- Data: list of { name, kind, expiry } (expiry = GetTime() + secondsRemaining).
local zones = {}
local offset = ScreenWidth()
local rebuildAcc = 1
local started = false      -- has the first data arrived (start the scroll once)?
local scrollWidth = 1500   -- reset distance; refreshed to the real text width each rebuild

-- Convert a {r,g,b} (0-1) colour to a "rrggbb" hex string for the |cffRRGGBB
-- escape. Read live from `db` so a colour change on the settings page shows up on
-- the next rebuild (~1s).
local function chan(x) return math.floor(math.min(1, math.max(0, x)) * 255 + 0.5) end
local function kindHex(kind)
    local c = (kind == "raid") and db.raidColor or db.dungeonColor
    return string.format("%02x%02x%02x", chan(c[1]), chan(c[2]), chan(c[3]))
end

local function fmtRemaining(sec)
    sec = math.max(0, math.floor(sec))
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    if h > 0 then return string.format("%dh%02dm", h, m) end
    if m > 0 then return string.format("%dm", m) end
    return "<1m"
end

local function BuildText()
    if #zones == 0 then
        bar.text:SetText("")
        bar:Hide()
        return
    end

    local now = GetTime()
    local parts = { "|cffffd100MYTHIC+ HOTZONES|r    " }
    for _, z in ipairs(zones) do
        local color = "ff" .. kindHex(z.kind)
        local left = fmtRemaining(z.expiry - now)
        table.insert(parts, string.format("|c%s%s|r |cffaaaaaa(%s, %s left)|r        ", color, z.name, z.kind, left))
    end
    bar.text:SetText(table.concat(parts))
    -- Only reveal the bar if the player hasn't disabled it on the settings page.
    if db.enabled then bar:Show() else bar:Hide() end

    -- Cache the real rendered width for the scroll-reset. Ignore a bogus 0 (can
    -- happen if measured before layout) and keep the last good value.
    local w = bar.text:GetStringWidth()
    if w and w > 10 then
        scrollWidth = w
    end
end

bar:SetScript("OnUpdate", function(self, delta)
    if not db.enabled then return end
    if #zones == 0 then return end

    -- Rebuild ~once a second so the countdowns tick.
    rebuildAcc = rebuildAcc + delta
    if rebuildAcc >= 1 then
        rebuildAcc = 0
        BuildText()
    end

    -- Scroll left across the WHOLE screen; when the string has fully passed the
    -- left edge, wrap back to the right edge.
    offset = offset - db.speed * delta
    if offset < -scrollWidth then
        offset = ScreenWidth()
    end
    self.text:SetPoint("LEFT", textLayer, "LEFT", offset, 0)
end)

-- Push every live setting onto the bar. Called on load (after the DB is read)
-- and whenever the settings page toggles enable/disable, so nothing is stale.
local function ApplyBar()
    bar:SetHeight(db.height)
    bar.bg:SetAlpha(db.bgAlpha)
    if db.enabled and #zones > 0 then
        BuildText()          -- rebuild + Show with current colours
    else
        bar:Hide()
    end
end

-- UHOT:<name>~<kind>~<remaining>|<name>~<kind>~<remaining>   (payload may be empty)
local function OnData(payload, append)
    -- The server chunks the list across messages (255-byte pipe cap): the first
    -- "UHOT:" resets, each following "UHOT+:" appends. Only reset on the first.
    if not append then zones = {} end
    local now = GetTime()
    for chunk in payload:gmatch("[^|]+") do
        local name, kind, rem = chunk:match("^(.-)~(%a+)~(%d+)$")
        if name then
            table.insert(zones, { name = name, kind = kind, expiry = now + tonumber(rem) })
        end
    end

    if #zones == 0 then
        bar:Hide()
        return
    end

    -- Start the scroll from the right edge only ONCE. The server re-pushes the
    -- hotzone list every ~15s; resetting offset on every push was restarting the
    -- scroll before it could reach the left edge -- the "only scrolls halfway" bug.
    if not started then
        started = true
        offset = ScreenWidth()
    end
    rebuildAcc = 1
    BuildText()
end

-- Keep the protocol line out of chat.
ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", function(self, event, msg)
    if msg and msg:find("^UHOT") then
        return true
    end
    return false
end)

-- Prefix for the whole server->client pipe (see the transport note below).
local ADDON_PIPE_PREFIX = "UNC"

local listener = CreateFrame("Frame")
listener:RegisterEvent("CHAT_MSG_CHANNEL")
listener:RegisterEvent("CHAT_MSG_ADDON")
listener:RegisterEvent("ADDON_LOADED")
listener:SetScript("OnEvent", function(self, event, a1, a2)
    if event == "ADDON_LOADED" then
        if a1 == "UncappedHotzones" then
            -- Load settings: create the SavedVariable if absent and backfill a
            -- default for every key, then point the live `db` at it so edits
            -- persist. (Reassigning the `db` upvalue updates every closure.)
            if type(UncappedHotzonesDB) ~= "table" then UncappedHotzonesDB = {} end
            local s = UncappedHotzonesDB
            for k, v in pairs(defaults) do
                if s[k] == nil then
                    if type(v) == "table" then s[k] = { v[1], v[2], v[3] } else s[k] = v end
                end
            end
            db = s
            ApplyBar()                                   -- apply on load
            for _, r in ipairs(panelRefreshers) do r() end  -- resync the page

            JoinChannelByName(UnitName("player"))
        end
        return
    end

    -- Two transports, on purpose.
    --
    -- CHAT_MSG_ADDON is where the pipe is moving: the client never renders it,
    -- so the protocol can no longer leak into chat when an addon fails to load.
    -- CHAT_MSG_CHANNEL is the old transport, kept because one payload serves
    -- both realms and a realm still running the previous worldserver would go
    -- silent otherwise. Drop the channel branch once every realm is converted.
    --
    --   CHAT_MSG_ADDON   : a1 = prefix, a2 = body
    --   CHAT_MSG_CHANNEL : a1 = body,   a2 = author (our own name on the pipe)
    local msg
    if event == "CHAT_MSG_ADDON" then
        if a1 ~= ADDON_PIPE_PREFIX then return end
        msg = a2
    else
        if a2 ~= UnitName("player") then return end
        msg = a1
    end
    if not msg then
        return
    end

    local payload = msg:match("^UHOT:(.*)$")
    if payload ~= nil then
        OnData(payload, false)   -- first message: reset the list
        return
    end
    local more = msg:match("^UHOT%+:(.*)$")
    if more ~= nil then
        OnData(more, true)       -- continuation: append to the list
    end
end)

-- ---------------------------------------------------------------------------
-- Settings page (ESC > Interface > AddOns > Uncapped > Hotzones). Provided by
-- the shared UncappedUI widget library (UncappedOptions addon); guard on it so
-- the bar still works standalone if that addon is missing.
-- ---------------------------------------------------------------------------
if UncappedUI then
    local panel, L = UncappedUI.CreatePanel("Hotzones",
        "The scrolling top-screen bar of active Mythic+ hotzones -- raids and dungeons, each with a live countdown.")

    L:Header("Hotzone bar")
    panelRefreshers[#panelRefreshers + 1] = L:Check("Show hotzone bar",
        function() return db.enabled end,
        function(v) db.enabled = v; ApplyBar() end).uncappedRefresh
    panelRefreshers[#panelRefreshers + 1] = L:Slider("Ticker scroll speed", 10, 150, 5,
        function() return db.speed end,
        function(v) db.speed = v end, "%d").uncappedRefresh
    panelRefreshers[#panelRefreshers + 1] = L:Slider("Bar height", 10, 30, 1,
        function() return db.height end,
        function(v) db.height = v; bar:SetHeight(v) end, "%d").uncappedRefresh
    panelRefreshers[#panelRefreshers + 1] = L:Slider("Bar background opacity", 0.0, 1.0, 0.05,
        function() return db.bgAlpha end,
        function(v) db.bgAlpha = v; bar.bg:SetAlpha(v) end, "%.2f").uncappedRefresh

    L:Gap(6)
    L:Header("Colours")
    panelRefreshers[#panelRefreshers + 1] = L:Color("Raid colour",
        function() return db.raidColor[1], db.raidColor[2], db.raidColor[3] end,
        function(r, g, b) db.raidColor = { r, g, b }; if #zones > 0 then BuildText() end end).uncappedRefresh
    panelRefreshers[#panelRefreshers + 1] = L:Color("Dungeon colour",
        function() return db.dungeonColor[1], db.dungeonColor[2], db.dungeonColor[3] end,
        function(r, g, b) db.dungeonColor = { r, g, b }; if #zones > 0 then BuildText() end end).uncappedRefresh

    L:Gap(6)
    L:Note("|cff808080The bar appears on its own when the server pushes active hotzones. Use /hotzones to preview it with sample data.|r", 40)
end

SLASH_UNCAPPEDHOTZONE1 = "/hotzones"
SlashCmdList["UNCAPPEDHOTZONE"] = function()
    OnData("Icecrown Citadel~raid~5400|The Deadmines~dungeon~1800")
end
