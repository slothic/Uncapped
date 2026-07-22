-- UncappedHotzones
--
-- A thin scrolling bar pinned to the very top of the screen that lists the
-- currently-active Mythic+ hotzones: RAIDS in red, DUNGEONS in cyan, each with a
-- live "time left" countdown.
--
-- The server pushes the list on the player's personal channel (RBHOT) on login
-- and every ~15s (so it also picks up the hourly rotation); the countdown is
-- ticked down locally between pushes. The RBHOT lines are filtered out of chat.

local SPEED = 55  -- scroll speed, pixels/second

-- ---------------------------------------------------------------------------
-- Bar frame: full screen width so the text simply scrolls off the screen edges
-- (WotLK 3.3.5 has no child-clipping, so we let the viewport do the clipping).
-- ---------------------------------------------------------------------------
local bar = CreateFrame("Frame", "UncappedHotzoneBar", UIParent)
bar:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, -1)
bar:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", 0, -1)
bar:SetHeight(18)
bar:SetFrameStrata("LOW")
bar:Hide()

bar.bg = bar:CreateTexture(nil, "BACKGROUND")
bar.bg:SetAllPoints(bar)
bar.bg:SetTexture(0, 0, 0)
bar.bg:SetAlpha(0.55)

bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
bar.text:SetPoint("LEFT", bar, "LEFT", 0, 0)
bar.text:SetJustifyH("LEFT")

-- Data: list of { name, kind, expiry } (expiry = GetTime() + secondsRemaining).
local zones = {}
local offset = 0
local rebuildAcc = 1

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
        local color = (z.kind == "raid") and "ffff4040" or "ff3ce7ff"
        local left = fmtRemaining(z.expiry - now)
        table.insert(parts, string.format("|c%s%s|r |cffaaaaaa(%s, %s left)|r        ", color, z.name, z.kind, left))
    end
    bar.text:SetText(table.concat(parts))
    bar:Show()
end

bar:SetScript("OnUpdate", function(self, delta)
    if #zones == 0 then return end

    -- Rebuild ~once a second so the countdowns tick.
    rebuildAcc = rebuildAcc + delta
    if rebuildAcc >= 1 then
        rebuildAcc = 0
        BuildText()
    end

    -- Scroll left; when the whole string has passed, wrap to the right edge.
    offset = offset - SPEED * delta
    local tw = self.text:GetStringWidth()
    if offset < -tw then
        offset = self:GetWidth()
    end
    self.text:SetPoint("LEFT", self, "LEFT", offset, 0)
end)

-- RBHOT:<name>~<kind>~<remaining>|<name>~<kind>~<remaining>   (payload may be empty)
local function OnData(payload)
    zones = {}
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

    if offset >= 0 then
        offset = bar:GetWidth()  -- start off the right edge
    end
    rebuildAcc = 1
    BuildText()
end

-- Keep the protocol line out of chat.
ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", function(self, event, msg)
    if msg and msg:find("^RBHOT:") then
        return true
    end
    return false
end)

local listener = CreateFrame("Frame")
listener:RegisterEvent("CHAT_MSG_CHANNEL")
listener:RegisterEvent("ADDON_LOADED")
listener:SetScript("OnEvent", function(self, event, a1, a2)
    if event == "ADDON_LOADED" then
        if a1 == "UncappedHotzones" then
            JoinChannelByName(UnitName("player"))
        end
        return
    end

    -- CHAT_MSG_CHANNEL: a1 = message, a2 = author (our own name on the pipe).
    if a2 ~= UnitName("player") or not a1 then
        return
    end

    local payload = a1:match("^RBHOT:(.*)$")
    if payload ~= nil then
        OnData(payload)
    end
end)

SLASH_UNCAPPEDHOTZONE1 = "/hotzones"
SlashCmdList["UNCAPPEDHOTZONE"] = function()
    OnData("Icecrown Citadel~raid~5400|The Deadmines~dungeon~1800")
end
