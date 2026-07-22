-- UncappedRewards
--
-- The Mythic+ completion window. When you finish a keystone the server sends the
-- FULL reward list (RBCHEST) and your global rank for the clear (RBRANK); this
-- pops a shiny frame with a gold screen-flash, your rank + clear time, and a
-- SCROLLABLE list of everything you won (mouse wheel to scroll).
--
-- Rides the player's personal channel like the other addons, and filters the
-- RBCHEST / RBRANK lines out of chat so only the window shows them.

local VISIBLE = 10  -- reward rows visible at once (rest reached by scrolling)

local frame = CreateFrame("Frame", "UncappedRewardFrame", UIParent)
frame:SetSize(360, 400)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
frame:SetFrameStrata("HIGH")
frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
frame:SetMovable(true)
frame:EnableMouse(true)
frame:EnableMouseWheel(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:Hide()

-- Golden glow behind the window contents, alpha-pulsed for the "shiny".
frame.glow = frame:CreateTexture(nil, "BACKGROUND")
frame.glow:SetTexture("Interface\\Cooldown\\star4")
frame.glow:SetBlendMode("ADD")
frame.glow:SetPoint("CENTER", frame, "CENTER", 0, 20)
frame.glow:SetSize(260, 260)
frame.glow:SetVertexColor(1.0, 0.9, 0.4)

-- The chest icon.
frame.chest = frame:CreateTexture(nil, "ARTWORK")
frame.chest:SetTexture("Interface\\Icons\\INV_Misc_Ticket_Tarot_Stack_01")
frame.chest:SetSize(58, 58)
frame.chest:SetPoint("TOP", frame, "TOP", 0, -22)
frame.chestBorder = frame:CreateTexture(nil, "OVERLAY")
frame.chestBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
frame.chestBorder:SetSize(80, 80)
frame.chestBorder:SetPoint("CENTER", frame.chest, "CENTER", 11, -11)

frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
frame.title:SetPoint("TOP", frame.chest, "BOTTOM", 0, -6)
frame.title:SetTextColor(1.0, 0.82, 0.0)

-- Rank + clear time (filled by RBRANK).
frame.rank = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
frame.rank:SetPoint("TOP", frame.title, "BOTTOM", 0, -4)

-- Scroll hint / position readout.
frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
frame.hint:SetPoint("TOP", frame.rank, "BOTTOM", 0, -4)

frame.lines = {}
for i = 1, VISIBLE do
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("TOP", frame.hint, "BOTTOM", 0, -4 - (i - 1) * 18)
    fs:SetWidth(320)
    frame.lines[i] = fs
end

frame.close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
frame.close:SetPoint("TOPRIGHT", -6, -6)

-- ---------------------------------------------------------------------------
-- Contents + scrolling
-- ---------------------------------------------------------------------------
local entries = {}
local scroll = 0
local pulse = 0

local function fmtMs(ms)
    ms = tonumber(ms) or 0
    local totalSec = math.floor(ms / 1000)
    return string.format("%d:%02d.%03d", math.floor(totalSec / 60), totalSec % 60, ms % 1000)
end

local function RenderList()
    for i = 1, VISIBLE do
        local e = entries[scroll + i]
        if e then
            frame.lines[i]:SetText(string.format("|cff00ff00+%s|r  %s", e.count, e.name))
        else
            frame.lines[i]:SetText("")
        end
    end

    if #entries > VISIBLE then
        local last = math.min(scroll + VISIBLE, #entries)
        frame.hint:SetText(string.format("%d-%d of %d  (scroll)", scroll + 1, last, #entries))
    elseif #entries > 0 then
        frame.hint:SetText(string.format("%d reward%s", #entries, #entries == 1 and "" or "s"))
    else
        frame.hint:SetText("")
    end
end

frame:SetScript("OnMouseWheel", function(self, dir)
    if #entries <= VISIBLE then return end
    scroll = scroll - dir                 -- wheel up = towards the top
    if scroll < 0 then scroll = 0 end
    local maxScroll = #entries - VISIBLE
    if scroll > maxScroll then scroll = maxScroll end
    RenderList()
end)

frame:SetScript("OnUpdate", function(self, delta)
    pulse = pulse + delta * 2.2
    self.glow:SetAlpha(0.35 + 0.30 * (math.sin(pulse) * 0.5 + 0.5))
    local s = 250 + 20 * (math.sin(pulse * 0.7) * 0.5 + 0.5)
    self.glow:SetSize(s, s)
    -- No auto-close: stays until the player closes it (X button).
end)

-- Screen-wide gold flash.
local screenGlow = CreateFrame("Frame", "UncappedRewardScreenGlow", UIParent)
screenGlow:SetAllPoints(UIParent)
screenGlow:SetFrameStrata("MEDIUM")
screenGlow:Hide()
screenGlow.core = screenGlow:CreateTexture(nil, "ARTWORK")
screenGlow.core:SetAllPoints(screenGlow)
screenGlow.core:SetTexture("Interface\\Cooldown\\star4")
screenGlow.core:SetBlendMode("ADD")
screenGlow.core:SetVertexColor(1.0, 0.85, 0.35)
screenGlow.halo = screenGlow:CreateTexture(nil, "ARTWORK")
screenGlow.halo:SetPoint("CENTER", screenGlow, "CENTER")
screenGlow.halo:SetSize(UIParent:GetWidth() * 1.6, UIParent:GetHeight() * 1.6)
screenGlow.halo:SetTexture("Interface\\Cooldown\\star4")
screenGlow.halo:SetBlendMode("ADD")
screenGlow.halo:SetVertexColor(1.0, 0.78, 0.25)

local flash = 0
screenGlow:SetScript("OnUpdate", function(self, delta)
    flash = flash - delta
    if flash <= 0 then
        self:Hide()
        return
    end
    local a = flash / 1.5
    self.core:SetAlpha(0.55 * a)
    self.halo:SetAlpha(0.40 * a)
end)

local function ScreenFlash()
    flash = 1.5
    screenGlow.core:SetAlpha(0.55)
    screenGlow.halo:SetAlpha(0.40)
    screenGlow:Show()
end

-- The level the currently-shown window is for (to match a following RBRANK).
local shownLevel = nil

local function Show(level, list)
    shownLevel = level
    entries = list
    scroll = 0
    pulse = 0

    frame.title:SetText("Keystone +" .. level .. "!")
    frame.rank:SetText("|cffaaaaaacalculating rank...|r")
    RenderList()

    frame:Show()
    ScreenFlash()
    PlaySound("LevelUp")
    PlaySoundFile("Sound\\Interface\\LevelUp2.wav")
end

local function SetRank(level, rank, total, durationMs, bestMs)
    if shownLevel ~= level then return end
    local line = string.format("Cleared in |cffffffff%s|r  --  rank |cffffd100#%d|r of %d", fmtMs(durationMs), rank, total)
    if tonumber(bestMs) and tonumber(bestMs) > 0 and tonumber(bestMs) < tonumber(durationMs) then
        line = line .. string.format("   |cffaaaaaa(best %s)|r", fmtMs(bestMs))
    end
    frame.rank:SetText(line)
end

-- Hide the protocol lines from chat.
ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", function(self, event, msg)
    if msg and (msg:find("^RBCHEST:") or msg:find("^RBRANK:")) then
        return true
    end
    return false
end)

local listener = CreateFrame("Frame")
listener:RegisterEvent("CHAT_MSG_CHANNEL")
listener:RegisterEvent("ADDON_LOADED")
listener:SetScript("OnEvent", function(self, event, a1, a2)
    if event == "ADDON_LOADED" then
        if a1 == "UncappedRewards" then
            JoinChannelByName(UnitName("player"))
        end
        return
    end

    if a2 ~= UnitName("player") or not a1 then
        return
    end

    -- RBCHEST:<level>:<name>x<count>|<name>x<count>|...
    local level, rest = a1:match("^RBCHEST:(%d+):(.*)$")
    if level then
        local list = {}
        for chunk in rest:gmatch("[^|]+") do
            local name, count = chunk:match("^(.-)x(%d+)$")
            if name then
                table.insert(list, { name = name, count = count })
            end
        end
        Show(tonumber(level) or 0, list)
        return
    end

    -- RBRANK:<map>:<level>:<rank>:<total>:<durationMs>:<bestMs>
    local rmap, rlevel, rrank, rtotal, rms, rbest = a1:match("^RBRANK:(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)$")
    if rlevel then
        SetRank(tonumber(rlevel), tonumber(rrank), tonumber(rtotal), tonumber(rms), tonumber(rbest))
        return
    end
end)

SLASH_UNCAPPEDREWARD1 = "/rewardtest"
SlashCmdList["UNCAPPEDREWARD"] = function()
    local list = {}
    for i = 1, 24 do
        table.insert(list, { name = "Reward Item " .. i, count = tostring(i * 5) })
    end
    Show(37, list)
    SetRank(37, 3, 51, 128640, 121003)
end
