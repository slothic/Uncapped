-- UncappedRewards
--
-- The dopamine window. When you beat a Mythic+ timer, the server sends the
-- crafting-mat bonus it just banked for you (RBCHEST) and this pops a shiny
-- reward frame plus a screen-wide gold flash, listing what you won.
--
-- Rides the player's personal channel like the other addons, and filters the
-- RBCHEST line out of chat so only the window shows it.

local AUTO_CLOSE = 10  -- seconds the window stays up

local frame = CreateFrame("Frame", "UncappedRewardFrame", UIParent)
frame:SetSize(340, 300)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
frame:SetFrameStrata("HIGH")
frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
frame:SetMovable(true)
frame:EnableMouse(true)
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

-- The chest icon (owner's pick).
frame.chest = frame:CreateTexture(nil, "ARTWORK")
frame.chest:SetTexture("Interface\\Icons\\INV_Misc_Ticket_Tarot_Stack_01")
frame.chest:SetSize(64, 64)
frame.chest:SetPoint("TOP", frame, "TOP", 0, -26)
frame.chestBorder = frame:CreateTexture(nil, "OVERLAY")
frame.chestBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
frame.chestBorder:SetSize(86, 86)
frame.chestBorder:SetPoint("CENTER", frame.chest, "CENTER", 11, -11)

frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
frame.title:SetPoint("TOP", frame.chest, "BOTTOM", 0, -8)
frame.title:SetTextColor(1.0, 0.82, 0.0)

frame.lines = {}
for i = 1, 8 do
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("TOP", frame.title, "BOTTOM", 0, -6 - (i - 1) * 18)
    fs:SetWidth(300)
    frame.lines[i] = fs
end

frame.close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
frame.close:SetPoint("TOPRIGHT", -6, -6)

local shownAt = 0
local pulse = 0

frame:SetScript("OnUpdate", function(self, delta)
    pulse = pulse + delta * 2.2
    self.glow:SetAlpha(0.35 + 0.30 * (math.sin(pulse) * 0.5 + 0.5))
    local s = 250 + 20 * (math.sin(pulse * 0.7) * 0.5 + 0.5)
    self.glow:SetSize(s, s)

    if shownAt > 0 and (GetTime() - shownAt) > AUTO_CLOSE then
        self:Hide()
        shownAt = 0
    end
end)

-- Screen-wide gold flash. Two white-based star glows (so gold tinting works,
-- unlike a red vignette) that burst bright on show and ease out.
local screenGlow = CreateFrame("Frame", "UncappedRewardScreenGlow", UIParent)
screenGlow:SetAllPoints(UIParent)
screenGlow:SetFrameStrata("MEDIUM") -- above the world, below the reward window
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

local function Show(level, entries)
    frame.title:SetText("Keystone +" .. level .. "!")

    for i = 1, 8 do frame.lines[i]:SetText("") end
    for i, e in ipairs(entries) do
        if i > 8 then
            frame.lines[8]:SetText("|cffaaaaaa...and more|r")
            break
        end
        frame.lines[i]:SetText(string.format("|cff00ff00+%s|r  %s", e.count, e.name))
    end

    frame:Show()
    ScreenFlash()
    shownAt = GetTime()
    pulse = 0

    PlaySound("LevelUp")
    PlaySoundFile("Sound\\Interface\\LevelUp2.wav")
end

-- Hide the protocol line from chat.
ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", function(self, event, msg)
    if msg and msg:find("^RBCHEST:") then
        return true
    end
    return false
end)

-- RBCHEST:<level>:<name>x<count>|<name>x<count>|...
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

    local level, rest = a1:match("^RBCHEST:(%d+):(.*)$")
    if not level then
        return
    end

    local entries = {}
    for chunk in rest:gmatch("[^|]+") do
        local name, count = chunk:match("^(.-)x(%d+)$")
        if name then
            table.insert(entries, { name = name, count = count })
        end
    end

    Show(tonumber(level) or 0, entries)
end)

SLASH_UNCAPPEDREWARD1 = "/rewardtest"
SlashCmdList["UNCAPPEDREWARD"] = function()
    Show(10, { { name = "Titanium Ore", count = "50" }, { name = "Frost Lotus", count = "12" }, { name = "Frostweave Cloth", count = "80" } })
end
