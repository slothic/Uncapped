-- UncappedRewards
--
-- The Mythic+ completion window. When you finish a keystone the server sends the
-- FULL reward list (UCHEST) and your global rank for the clear (URANK); this
-- pops a shiny frame with a gold screen-flash, your rank + clear time, and a
-- SCROLLABLE list of everything you won (mouse wheel to scroll).
--
-- Transport: CHAT_MSG_ADDON on the shared "UNC" prefix. The client never renders
-- an addon message, so nothing needs filtering out of chat. The reward list is
-- chunked (UCHEST / UCHEST+) because it routinely outruns the 255-byte cap.

local VISIBLE = 10   -- reward rows visible at once (rest reached by scrolling); driven by db.rows
local MAXROWS = 20   -- font strings pre-created so "rows shown" can change live

-- ---------------------------------------------------------------------------
-- Settings (SavedVariables: UncappedRewardsDB). db holds the live values; the
-- panel's get()/set() read and write it, and the global points at it so edits
-- persist. Defaults below are applied on load AND on every change.
-- ---------------------------------------------------------------------------
local DEFAULTS = {
    rows = 10,                          -- reward rows shown at once (5-20)
    sound = true,                       -- play the reward fanfare
    flash = true,                       -- screen flash on reward
    autoClose = 0,                      -- auto-close after N seconds (0 = never)
    glowColor = { 1.0, 0.9, 0.4 },      -- chest glow tint
    flashColor = { 1.0, 0.85, 0.35 },   -- screen-flash tint
    pos = nil,                          -- saved popup position (point/relPoint/x/y) or nil
}
local function copyDefaults()
    return {
        rows = DEFAULTS.rows,
        sound = DEFAULTS.sound,
        flash = DEFAULTS.flash,
        autoClose = DEFAULTS.autoClose,
        glowColor = { DEFAULTS.glowColor[1], DEFAULTS.glowColor[2], DEFAULTS.glowColor[3] },
        flashColor = { DEFAULTS.flashColor[1], DEFAULTS.flashColor[2], DEFAULTS.flashColor[3] },
        pos = nil,
    }
end
local db = copyDefaults()
local refreshPanel               -- assigned when the settings page is built (guarded)

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
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    -- Movable but not otherwise auto-saved: remember where the player dropped it.
    local point, _, relPoint, x, y = self:GetPoint()
    db.pos = { point = point, relPoint = relPoint, x = x, y = y }
end)
frame:Hide()

-- Player window zoom (ESC > Interface > AddOns > Uncapped, or /uiscale).
-- savePosition mirrors OnDragStop above: a zoom change rewrites this window's
-- anchor offsets so it stays on the same spot on screen, and the corrected
-- numbers -- not the pre-zoom ones -- are what ApplyPosition must restore next
-- time.
--
-- The full-screen gold flash (UncappedRewardScreenGlow, further down) is NOT
-- registered: it is SetAllPoints(UIParent) with textures sized from
-- UIParent:GetWidth(), so scaling it would size the flash in the wrong units
-- and leave an unlit border round the screen. A screen effect has no zoom.
if UncappedScale_Register then
    UncappedScale_Register(frame, {
        group = "rewards",
        savePosition = function(self)
            -- Only once the player has actually dragged it: while db.pos is nil
            -- ApplyPosition owns the default anchor, and writing here would
            -- promote that default into a placement they never made (and would
            -- make "Reset position" on the settings page a one-shot).
            if not db.pos then return end
            local point, _, relPoint, x, y = self:GetPoint()
            if point then db.pos = { point = point, relPoint = relPoint, x = x, y = y } end
        end,
    })
end

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

-- Rank + clear time (filled by URANK).
frame.rank = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
frame.rank:SetPoint("TOP", frame.title, "BOTTOM", 0, -4)

-- Scroll hint / position readout.
frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
frame.hint:SetPoint("TOP", frame.rank, "BOTTOM", 0, -4)

frame.lines = {}
for i = 1, MAXROWS do
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
local closeTimer = nil   -- seconds until auto-close (nil = disabled), set in Show()

local function fmtMs(ms)
    ms = tonumber(ms) or 0
    local totalSec = math.floor(ms / 1000)
    return string.format("%d:%02d.%03d", math.floor(totalSec / 60), totalSec % 60, ms % 1000)
end

local function RenderList()
    for i = 1, MAXROWS do
        local e = (i <= VISIBLE) and entries[scroll + i] or nil
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
    -- Optional auto-close (db.autoClose seconds); 0/nil = stays until the X button.
    if closeTimer then
        closeTimer = closeTimer - delta
        if closeTimer <= 0 then
            closeTimer = nil
            self:Hide()
        end
    end
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

-- ---------------------------------------------------------------------------
-- Appliers: push a db value onto the live frames. Called on load and on change.
-- ---------------------------------------------------------------------------
local function ApplyRows()
    VISIBLE = db.rows
    if VISIBLE < 1 then VISIBLE = 1 elseif VISIBLE > MAXROWS then VISIBLE = MAXROWS end
    -- Keep scroll in range for the new window size, then repaint if visible.
    local maxScroll = #entries - VISIBLE
    if maxScroll < 0 then maxScroll = 0 end
    if scroll > maxScroll then scroll = maxScroll end
    RenderList()
end

local function ApplyGlowColor()
    frame.glow:SetVertexColor(db.glowColor[1], db.glowColor[2], db.glowColor[3])
end

local function ApplyFlashColor()
    screenGlow.core:SetVertexColor(db.flashColor[1], db.flashColor[2], db.flashColor[3])
    screenGlow.halo:SetVertexColor(db.flashColor[1], db.flashColor[2], db.flashColor[3])
end

local function ApplyPosition()
    frame:ClearAllPoints()
    if db.pos then
        frame:SetPoint(db.pos.point, UIParent, db.pos.relPoint, db.pos.x, db.pos.y)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    end
end

-- The level the currently-shown window is for (to match a following URANK).
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
    closeTimer = (db.autoClose and db.autoClose > 0) and db.autoClose or nil
    if db.flash then
        ScreenFlash()
    end
    if db.sound then
        PlaySound("LevelUp")
        PlaySoundFile("Sound\\Interface\\LevelUp2.wav")
    end
end

-- "<name>x<count>|<name>x<count>|..." -> { {name=, count=}, ... }
-- Counts stay STRINGS on purpose: they are uint64 server-side and tonumber
-- would round anything past 2^53.
local function ParseRewards(rest)
    local list = {}
    for chunk in rest:gmatch("[^|]+") do
        local name, count = chunk:match("^(.-)x(%d+)$")
        if name then
            list[#list + 1] = { name = name, count = count }
        end
    end
    return list
end

-- Append a continuation chunk (UCHEST+) to the window already on screen.
-- Deliberately NOT a second Show(): that would reset the scroll, re-flash the
-- screen and re-play the fanfare once per chunk.
local function Append(list)
    for i = 1, #list do
        entries[#entries + 1] = list[i]
    end
    RenderList()
end

local function SetRank(level, rank, total, durationMs, bestMs)
    if shownLevel ~= level then return end
    local line = string.format("Cleared in |cffffffff%s|r  --  rank |cffffd100#%d|r of %d", fmtMs(durationMs), rank, total)
    if tonumber(bestMs) and tonumber(bestMs) > 0 and tonumber(bestMs) < tonumber(durationMs) then
        line = line .. string.format("   |cffaaaaaa(best %s)|r", fmtMs(bestMs))
    end
    frame.rank:SetText(line)
end

-- Prefix for the whole server->client pipe (see the transport note below).
local ADDON_PIPE_PREFIX = "UNC"

local listener = CreateFrame("Frame")
listener:RegisterEvent("CHAT_MSG_ADDON")
listener:RegisterEvent("ADDON_LOADED")
listener:SetScript("OnEvent", function(self, event, a1, a2)
    if event == "ADDON_LOADED" then
        if a1 == "UncappedRewards" then
            -- Load SavedVariables over the defaults, then point the global at the
            -- live table so panel edits (and the saved popup position) persist.
            if type(UncappedRewardsDB) ~= "table" then UncappedRewardsDB = {} end
            local s = UncappedRewardsDB
            if s.rows ~= nil then db.rows = s.rows end
            if s.sound ~= nil then db.sound = s.sound end
            if s.flash ~= nil then db.flash = s.flash end
            if s.autoClose ~= nil then db.autoClose = s.autoClose end
            if type(s.glowColor) == "table" then
                db.glowColor = { s.glowColor[1] or DEFAULTS.glowColor[1],
                                 s.glowColor[2] or DEFAULTS.glowColor[2],
                                 s.glowColor[3] or DEFAULTS.glowColor[3] }
            end
            if type(s.flashColor) == "table" then
                db.flashColor = { s.flashColor[1] or DEFAULTS.flashColor[1],
                                  s.flashColor[2] or DEFAULTS.flashColor[2],
                                  s.flashColor[3] or DEFAULTS.flashColor[3] }
            end
            if type(s.pos) == "table" and s.pos.point then
                db.pos = { point = s.pos.point, relPoint = s.pos.relPoint, x = s.pos.x, y = s.pos.y }
            end
            UncappedRewardsDB = db

            ApplyRows()
            ApplyGlowColor()
            ApplyFlashColor()
            ApplyPosition()
            if refreshPanel then refreshPanel() end
        end
        return
    end

    -- ONE transport. The per-player chat channel this used to also listen on was
    -- retired when the server moved the whole UNC pipe to CHAT_MSG_ADDON
    -- (ReagentBankChannelProtocol.cpp:79-96 -- SendResponse is now the only
    -- sender and it never Say()s). The channel branch, its JoinChannelByName and
    -- the CHAT_MSG_CHANNEL chat filter are gone: they cost every real World-chat
    -- line a pass through a dead filter, and the join burned one of the client's
    -- ten channel slots on a channel nothing publishes to.
    --
    --   CHAT_MSG_ADDON : a1 = prefix, a2 = body
    if a1 ~= ADDON_PIPE_PREFIX then return end
    local msg = a2
    if not msg then
        return
    end

    -- UCHEST:<level>:<name>x<count>|<name>x<count>|...
    --
    -- CHUNKED. The pipe truncates at 255 bytes INCLUDING the "UNC\t" prefix, so
    -- only about 240 bytes of list fit per line -- roughly ten rewards, against
    -- the fifty-odd a full clear can pay. The first "UCHEST:" opens the window,
    -- each following "UCHEST+:" appends to it. Same shape as UHOT/UHOT+.
    local level, rest = msg:match("^UCHEST:(%d+):(.*)$")
    if level then
        Show(tonumber(level) or 0, ParseRewards(rest))
        return
    end

    local morelevel, more = msg:match("^UCHEST%+:(%d+):(.*)$")
    if morelevel then
        -- The level is carried so a stale chunk cannot land on the next window.
        if shownLevel == (tonumber(morelevel) or 0) then
            Append(ParseRewards(more))
        end
        return
    end

    -- URANK:<map>:<level>:<rank>:<total>:<durationMs>:<bestMs>
    local rmap, rlevel, rrank, rtotal, rms, rbest = msg:match("^URANK:(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)$")
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

-- ---------------------------------------------------------------------------
-- Settings page (ESC > Interface > AddOns > Uncapped > Rewards). Provided by the
-- shared UncappedUI library from UncappedOptions; guard everything on it.
-- ---------------------------------------------------------------------------
if UncappedUI then
    local panel, L = UncappedUI.CreatePanel("Rewards",
        "The Mythic+ keystone reward popup: how many rows it shows, its fanfare and screen flash, auto-close, and colours.")

    local refreshers = {}
    local function track(w) refreshers[#refreshers + 1] = w.uncappedRefresh; return w end

    L:Header("Popup")
    track(L:Slider("Reward rows shown", 5, 20, 1,
        function() return db.rows end,
        function(v) db.rows = v; ApplyRows() end, "%d"))
    track(L:Slider("Auto-close after (seconds, 0 = off)", 0, 60, 5,
        function() return db.autoClose end,
        function(v) db.autoClose = v end, "%d"))

    L:Gap(6)
    L:Header("Effects")
    track(L:Check("Play reward fanfare",
        function() return db.sound end,
        function(v) db.sound = v end))
    track(L:Check("Screen flash on reward",
        function() return db.flash end,
        function(v) db.flash = v end))

    L:Gap(6)
    L:Header("Colours")
    track(L:Color("Chest glow colour",
        function() return db.glowColor[1], db.glowColor[2], db.glowColor[3] end,
        function(r, g, b) db.glowColor = { r, g, b }; ApplyGlowColor() end))
    track(L:Color("Screen-flash colour",
        function() return db.flashColor[1], db.flashColor[2], db.flashColor[3] end,
        function(r, g, b) db.flashColor = { r, g, b }; ApplyFlashColor() end))

    L:Gap(6)
    L:Header("Position")
    L:Note("The popup can be dragged anywhere and remembers where you left it. Use this to move it back to the centre.", 28)
    L:Button("Reset position", function() db.pos = nil; ApplyPosition() end, 150)

    -- Called from ADDON_LOADED after SavedVariables merge so widgets show saved values.
    refreshPanel = function()
        for _, r in ipairs(refreshers) do r() end
    end

    UncappedRewardPanel = panel
end
