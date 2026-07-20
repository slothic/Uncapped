--[[
    Stat Feed -- a small movable window for Dungeon Stats gains.

    The server sends these as ADDON messages rather than chat, so they never
    touch the default chat frame. See lua_scripts/dungeonstats.lua, which
    routes them through SendAddonMessage with the prefix below.

    Written for the 3.3.5a client: no BackdropTemplate, no C_ namespace, and
    event handlers read the global arg1..argN rather than taking parameters.

    /statfeed         toggle the window
    /statfeed clear   clear the log
    /statfeed reset   put the window back in the middle of the screen
]]

local ADDON_PREFIX = "DSTATS"

local DEFAULTS = {
    point    = "CENTER",
    x        = 250,
    y        = 0,
    width    = 320,
    height   = 180,
    shown    = true,
}

local frame

-- Merge saved settings over the defaults, so a new option added later does
-- not break an existing saved table.
local function GetDB()
    StatFeedDB = StatFeedDB or {}
    for k, v in pairs(DEFAULTS) do
        if StatFeedDB[k] == nil then
            StatFeedDB[k] = v
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
    frame:SetBackdropColor(0, 0, 0, 0.7)

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
    title:SetText("|cff9CC243Stat Feed|r")

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
    log:SetMaxLines(200)
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
events:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" then
        if arg1 == "StatFeed" then
            BuildWindow()
        end
        return
    end

    if event == "CHAT_MSG_ADDON" then
        -- arg1 = prefix, arg2 = message
        if arg1 == ADDON_PREFIX then
            AddLine(arg2)
        end
    end
end)

SLASH_STATFEED1 = "/statfeed"
SlashCmdList["STATFEED"] = function(msg)
    msg = string.lower(msg or "")

    if msg == "clear" then
        if frame and frame.log then frame.log:Clear() end
        return
    end

    if msg == "reset" then
        if frame then
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", UIParent, "CENTER", DEFAULTS.x, DEFAULTS.y)
            frame:SetWidth(DEFAULTS.width)
            frame:SetHeight(DEFAULTS.height)
            frame:Show()
            GetDB().shown = true
            SavePosition()
        end
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
