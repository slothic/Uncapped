--[[
    Stat Feed -- a small movable window for Dungeon Stats gains.

    The server sends these as ADDON messages rather than chat, so they never
    touch the default chat frame. See lua_scripts/dungeonstats.lua, which
    routes them through SendAddonMessage with the prefix below.

    Written for the 3.3.5a client: no BackdropTemplate, no C_ namespace, and
    event handlers can read either the arg1..argN globals or handler
--    parameters; 3.3.5 provides both.

    /statfeed         toggle the window
    /statfeed clear   clear the log
    /statfeed reset   put the window back in the middle of the screen
]]

local ADDON_PREFIX = "DSTATS"

local DEFAULTS = {
    point      = "CENTER",
    x          = 250,
    y          = 0,
    width      = 320,
    height     = 180,
    shown      = true,
    maxLines   = 200,
    bgAlpha    = 0.7,
    titleColor = { 0.61, 0.76, 0.26 }, -- |cff9CC243
}

local frame

-- Merge saved settings over the defaults, so a new option added later does
-- not break an existing saved table.
local function GetDB()
    StatFeedDB = StatFeedDB or {}
    for k, v in pairs(DEFAULTS) do
        if StatFeedDB[k] == nil then
            if type(v) == "table" then
                -- Copy, so we never mutate the DEFAULTS table in place.
                local t = {}
                for i, vv in pairs(v) do t[i] = vv end
                StatFeedDB[k] = t
            else
                StatFeedDB[k] = v
            end
        end
    end
    return StatFeedDB
end

local function SavePosition()
    local db = GetDB()
    local point, _, _, x, y = frame:GetPoint()
    db.point = point
    db.x = x
    db.y = y
    db.width = frame:GetWidth()
    db.height = frame:GetHeight()
end

local function BuildWindow()
    local db = GetDB()

    frame = CreateFrame("Frame", "StatFeedFrame", UIParent)
    frame:SetWidth(db.width)
    frame:SetHeight(db.height)
    frame:SetPoint(db.point, UIParent, db.point, db.x, db.y)
    frame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 16,
        insets = { left = 5, right = 5, top = 5, bottom = 5 }
    })
    frame:SetBackdropColor(0, 0, 0, db.bgAlpha)

    -- Drag to move, from anywhere on the frame.
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function() frame:StartMoving() end)
    frame:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        SavePosition()
    end)

    -- Resize grip in the bottom-right, like the default chat frames.
    frame:SetResizable(true)
    frame:SetMinResize(200, 100)

    local grip = CreateFrame("Button", nil, frame)
    grip:SetWidth(16)
    grip:SetHeight(16)
    grip:SetPoint("BOTTOMRIGHT", -6, 6)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        SavePosition()
    end)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("Stat Feed")
    title:SetTextColor(db.titleColor[1], db.titleColor[2], db.titleColor[3])
    frame.title = title

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function()
        frame:Hide()
        GetDB().shown = false
    end)

    -- ScrollingMessageFrame keeps the newest line at the bottom and drops the
    -- oldest once the cap is reached, which is what we want for a feed.
    local log = CreateFrame("ScrollingMessageFrame", nil, frame)
    log:SetPoint("TOPLEFT", 12, -30)
    log:SetPoint("BOTTOMRIGHT", -12, 10)
    log:SetFontObject(GameFontHighlightSmall)
    log:SetJustifyH("LEFT")
    log:SetFading(false)
    log:SetMaxLines(db.maxLines)
    log:EnableMouseWheel(true)
    log:SetScript("OnMouseWheel", function(_, delta)
        -- 3.3.5 passes delta as the global `arg1` in some paths; accept both.
        local d = delta or arg1
        if d > 0 then log:ScrollUp() else log:ScrollDown() end
    end)

    frame.log = log

    if not db.shown then
        frame:Hide()
    end
end

local function AddLine(msg)
    if frame and frame.log then
        frame.log:AddMessage(msg)
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("CHAT_MSG_ADDON")
-- Reads the event and its arguments from PARAMETERS, falling back to the
-- globals.
--
-- Both conventions work on 3.3.5: handlers set via SetScript receive
-- (self, event, ...), and the older `event` / `arg1` / `argN` globals are also
-- still populated -- those were not dropped until Cataclysm. The original
-- global-only form was fine; the `or` fallbacks simply mean this keeps working
-- if the file is ever reused on a client where only one convention holds.
events:SetScript("OnEvent", function(self, evt, a1, a2)
    local e = evt or event
    local p1 = a1 or arg1
    local p2 = a2 or arg2

    if e == "ADDON_LOADED" then
        if p1 == "StatFeed" then
            BuildWindow()
        end
        return
    end

    if e == "CHAT_MSG_ADDON" then
        -- p1 = prefix, p2 = message
        if p1 == ADDON_PREFIX then
            AddLine(p2)
        end
    end
end)

-- Recenter and restore default size; shared by /statfeed reset and the
-- options-panel "Reset position & size" button.
local function ResetWindow()
    if not frame then return end
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", DEFAULTS.x, DEFAULTS.y)
    frame:SetWidth(DEFAULTS.width)
    frame:SetHeight(DEFAULTS.height)
    frame:Show()
    GetDB().shown = true
    SavePosition()
end

SLASH_STATFEED1 = "/statfeed"
SlashCmdList["STATFEED"] = function(msg)
    msg = string.lower(msg or "")

    if msg == "clear" then
        if frame and frame.log then frame.log:Clear() end
        return
    end

    if msg == "reset" then
        ResetWindow()
        return
    end

    if frame then
        if frame:IsShown() then
            frame:Hide()
            GetDB().shown = false
        else
            frame:Show()
            GetDB().shown = true
        end
    end
end

-- Settings page under ESC > Interface > AddOns > Uncapped > Stat Feed.
-- Guarded: the shared UncappedUI library is provided by another addon and may
-- not be present.
if UncappedUI then
    local panel, L = UncappedUI.CreatePanel("Stat Feed", "The Dungeon Stats feed window.")

    L:Header("Window")

    L:Check("Show Stat Feed window",
        function() return GetDB().shown end,
        function(v)
            GetDB().shown = v
            if frame then
                if v then frame:Show() else frame:Hide() end
            end
        end)

    local widthSlider = L:Slider("Window width", 200, 600, 10,
        function() return GetDB().width end,
        function(v)
            GetDB().width = v
            if frame then frame:SetWidth(v) end
        end, "%d px")

    local heightSlider = L:Slider("Window height", 100, 500, 10,
        function() return GetDB().height end,
        function(v)
            GetDB().height = v
            if frame then frame:SetHeight(v) end
        end, "%d px")

    L:Header("Feed")

    L:Slider("Scrollback lines", 50, 500, 10,
        function() return GetDB().maxLines end,
        function(v)
            GetDB().maxLines = v
            if frame and frame.log then frame.log:SetMaxLines(v) end
        end, "%d")

    L:Header("Appearance")

    L:Slider("Background opacity", 0.0, 1.0, 0.05,
        function() return GetDB().bgAlpha end,
        function(v)
            GetDB().bgAlpha = v
            if frame then frame:SetBackdropColor(0, 0, 0, v) end
        end, "%.2f")

    L:Color("Title colour",
        function()
            local c = GetDB().titleColor
            return c[1], c[2], c[3]
        end,
        function(r, g, b)
            GetDB().titleColor = { r, g, b }
            if frame and frame.title then frame.title:SetTextColor(r, g, b) end
        end)

    L:Gap(6)

    L:Button("Reset position & size", function()
        ResetWindow()
        widthSlider.uncappedRefresh()
        heightSlider.uncappedRefresh()
    end)
end
