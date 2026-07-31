-- UncappedPanel -- small in-game toolbox for common Uncapped commands.
-- Written for the 3.3.5a client.

if UncappedPanelLoaded then return end
UncappedPanelLoaded = true

local ADDON_NAME = "UncappedPanel"

local PAD = 6
local BUTTON_SIZE = 28
local ICON_SIZE = 28
local GAP = 1
local ORDER_BUTTON_SIZE = 30
local ORDER_ICON_SIZE = 24
local ORDER_GAP = 6

local C_PANEL = "|cff40ff40[Uncapped Panel]|r "
local C_CMD = "|cffffd100"
local C_RESET = "|r"

local floor, min, max = math.floor, math.min, math.max
local tinsert, tremove = table.insert, table.remove
local sub = string.sub
local tonumber, type, pairs = tonumber, type, pairs

local DEFAULTS = {
    relativeTo = "UIParent",
    point = "CENTER",
    relativePoint = "CENTER",
    x = 0,
    y = 0,
    shown = true,
    aoeLoot = false,
    visibleIcons = 10,
    layout = 4,
    orderLayout = 1,
}

local TOOL_BUTTONS = {
    { id = "dungeonStats", label = "Dungeon Stats", command = ".ds",       icon = "Interface\\Icons\\INV_Misc_Note_01" },
    { id = "reset",        label = "Reset",         command = ".reset",    icon = "Interface\\Icons\\INV_Misc_Rune_01" },
    { id = "auto",         label = "Auto",          command = ".auto",     icon = "Interface\\Icons\\Ability_Rogue_Sprint" },
    { id = "solo",         label = "Solo",          command = ".solo",     icon = "Interface\\Icons\\Ability_Warrior_BattleShout" },
    { id = "aoeLoot",      label = "Aoe Loot",      toggle = "aoeLoot",    icon = "Interface\\Icons\\INV_Misc_Bag_08" },
    { id = "statFeed",     label = "Stat Feed",     command = "/statfeed", icon = "Interface\\Icons\\INV_Misc_Book_09" },
    { id = "soulForge",    label = "Soul Forge",    command = "/sf",       icon = "Interface\\Icons\\INV_Enchant_ShardPrismaticLarge" },
    { id = "forge",        label = "Forge",         command = "/forge",    icon = "Interface\\Icons\\Trade_BlackSmithing" },
    { id = "transmog",     label = "Transmog",      command = "/transmog", icon = "Interface\\Icons\\INV_Chest_Cloth_17" },
    { id = "vault",        label = "Vault",         command = "/vault",    icon = "Interface\\Icons\\INV_Misc_Bag_10_Blue" },
}
DEFAULTS.visibleIcons = #TOOL_BUTTONS

local TOOL_BY_ID = {}
for i = 1, #TOOL_BUTTONS do
    local tool = TOOL_BUTTONS[i]
    TOOL_BY_ID[tool.id] = tool
end

local DEFAULT_ORDER = {
    "statFeed",
    "soulForge",
    "forge",
    "solo",
    "reset",
    "dungeonStats",
    "auto",
    "aoeLoot",
    "transmog",
    "vault",
}

local function BarWidth(count)
    count = max(1, min(#TOOL_BUTTONS, tonumber(count) or #TOOL_BUTTONS))
    return PAD * 2 + (BUTTON_SIZE * count) + (GAP * (count - 1))
end

local HEIGHT = PAD * 2 + BUTTON_SIZE

local frame
local CopyDefaults
local buttons = {}
local orderButtons = {}
local optionsBuilt = false
local draggingOrderSlot
local dbReady = false
local commandRunner

local VALID_POINTS = {
    CENTER = true,
    TOP = true, BOTTOM = true, LEFT = true, RIGHT = true,
    TOPLEFT = true, TOPRIGHT = true, BOTTOMLEFT = true, BOTTOMRIGHT = true,
}

local VALID_ANCHORS = {
    UIParent = true,
    Minimap = true,
}

local function SavedBoolean(value, fallback)
    if type(value) == "boolean" then return value end
    if value == 1 or value == "1" or value == "true" then return true end
    if value == 0 or value == "0" or value == "false" then return false end
    return fallback
end

local function SavedNumber(value, fallback, minValue, maxValue)
    local n = tonumber(value)
    if not n then n = fallback end
    if minValue and n < minValue then n = minValue end
    if maxValue and n > maxValue then n = maxValue end
    return n
end

local function AnchorFrame()
    if not frame then return end

    local db = CopyDefaults()
    local anchor = (db.relativeTo == "Minimap" and Minimap) or UIParent
    local relativePoint = VALID_POINTS[db.relativePoint] and db.relativePoint or DEFAULTS.relativePoint
    local point = VALID_POINTS[db.point] and db.point or DEFAULTS.point

    frame:ClearAllPoints()
    frame:SetPoint(point, anchor, relativePoint, tonumber(db.x) or DEFAULTS.x, tonumber(db.y) or DEFAULTS.y)
end

local function Chat(line)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(line) end
end

CopyDefaults = function()
    if dbReady and UncappedPanelDB then return UncappedPanelDB end

    UncappedPanelDB = UncappedPanelDB or {}
    local savedLayout = tonumber(UncappedPanelDB.layout) or 0

    for k, v in pairs(DEFAULTS) do
        if UncappedPanelDB[k] == nil then UncappedPanelDB[k] = v end
    end

    if savedLayout < DEFAULTS.layout then
        UncappedPanelDB.relativeTo = DEFAULTS.relativeTo
        UncappedPanelDB.point = DEFAULTS.point
        UncappedPanelDB.relativePoint = DEFAULTS.relativePoint
        UncappedPanelDB.x = DEFAULTS.x
        UncappedPanelDB.y = DEFAULTS.y
        UncappedPanelDB.layout = DEFAULTS.layout
    end

    if (tonumber(UncappedPanelDB.orderLayout) or 0) < DEFAULTS.orderLayout then
        UncappedPanelDB.order = {}
        for i = 1, #DEFAULT_ORDER do UncappedPanelDB.order[i] = DEFAULT_ORDER[i] end
        UncappedPanelDB.orderLayout = DEFAULTS.orderLayout
    end

    UncappedPanelDB.relativeTo = VALID_ANCHORS[UncappedPanelDB.relativeTo] and UncappedPanelDB.relativeTo or DEFAULTS.relativeTo
    UncappedPanelDB.point = VALID_POINTS[UncappedPanelDB.point] and UncappedPanelDB.point or DEFAULTS.point
    UncappedPanelDB.relativePoint = VALID_POINTS[UncappedPanelDB.relativePoint] and UncappedPanelDB.relativePoint or DEFAULTS.relativePoint
    UncappedPanelDB.x = SavedNumber(UncappedPanelDB.x, DEFAULTS.x)
    UncappedPanelDB.y = SavedNumber(UncappedPanelDB.y, DEFAULTS.y)
    UncappedPanelDB.shown = SavedBoolean(UncappedPanelDB.shown, DEFAULTS.shown)
    UncappedPanelDB.aoeLoot = SavedBoolean(UncappedPanelDB.aoeLoot, DEFAULTS.aoeLoot)
    UncappedPanelDB.visibleIcons = floor(SavedNumber(UncappedPanelDB.visibleIcons, #TOOL_BUTTONS, 1, #TOOL_BUTTONS) + 0.5)
    UncappedPanelDB.layout = floor(SavedNumber(UncappedPanelDB.layout, DEFAULTS.layout, DEFAULTS.layout) + 0.5)
    UncappedPanelDB.orderLayout = floor(SavedNumber(UncappedPanelDB.orderLayout, DEFAULTS.orderLayout, DEFAULTS.orderLayout) + 0.5)

    local cleanOrder = {}
    local used = {}
    if type(UncappedPanelDB.order) == "table" then
        for i = 1, #UncappedPanelDB.order do
            local id = UncappedPanelDB.order[i]
            if TOOL_BY_ID[id] and not used[id] then
                tinsert(cleanOrder, id)
                used[id] = true
            end
        end
    end
    for i = 1, #DEFAULT_ORDER do
        local id = DEFAULT_ORDER[i]
        if not used[id] then
            tinsert(cleanOrder, id)
            used[id] = true
        end
    end
    UncappedPanelDB.order = cleanOrder
    dbReady = true

    return UncappedPanelDB
end

local function SavePosition()
    if not frame then return end
    local db = CopyDefaults()
    local point, relativeTo, relativePoint, x, y = frame:GetPoint()
    db.point = point or DEFAULTS.point
    db.relativeTo = (relativeTo == Minimap) and "Minimap" or "UIParent"
    db.relativePoint = relativePoint or DEFAULTS.relativePoint
    db.x = floor((x or DEFAULTS.x) + 0.5)
    db.y = floor((y or DEFAULTS.y) + 0.5)
end

local function GetCommandRunner()
    if commandRunner then return commandRunner end

    commandRunner = CreateFrame("EditBox", nil, UIParent)
    commandRunner:Hide()
    commandRunner:SetAutoFocus(false)
    commandRunner.chatType = "SAY"
    commandRunner.chatFrame = DEFAULT_CHAT_FRAME
    if commandRunner.SetAttribute then commandRunner:SetAttribute("chatType", "SAY") end
    return commandRunner
end

local function RunTypedCommand(command)
    if not command or command == "" then return false end

    if sub(command, 1, 1) ~= "/" and SendChatMessage then
        SendChatMessage(command, "SAY")
        return true
    end

    local editBox = GetCommandRunner()
    if not editBox or not ChatEdit_SendText then
        Chat(C_PANEL .. "could not run " .. C_CMD .. command .. C_RESET .. " because the chat edit box is unavailable.")
        return false
    end

    editBox.chatType = "SAY"
    editBox.chatFrame = DEFAULT_CHAT_FRAME
    if editBox.SetAttribute then editBox:SetAttribute("chatType", "SAY") end
    editBox:SetText(command)
    ChatEdit_SendText(editBox, 0)
    editBox:SetText("")
    return true
end

local function ButtonCommand(data, db)
    if data.toggle == "aoeLoot" then
        db = db or CopyDefaults()
        return ".aoeloot " .. (db.aoeLoot and "off" or "on")
    end
    return data.command
end

local function RunButton(data)
    local db = CopyDefaults()
    local command = ButtonCommand(data, db)
    if RunTypedCommand(command) and data.toggle == "aoeLoot" then
        db.aoeLoot = not db.aoeLoot
    end
end

local function OnToolButtonClick(self)
    RunButton(self.data)
end

local function OnToolButtonEnter(self)
    local data = self.data
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(data.label)
    GameTooltip:AddLine(ButtonCommand(data), 1, 0.82, 0)
    GameTooltip:Show()
end

local function HideTooltip()
    GameTooltip:Hide()
end

local function CreateToolButton(parent, data)
    local button = CreateFrame("Button", nil, parent)
    button.data = data
    button:SetWidth(BUTTON_SIZE)
    button:SetHeight(BUTTON_SIZE)
    button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    if button:GetHighlightTexture() then button:GetHighlightTexture():SetBlendMode("ADD") end

    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(button)
    bg:SetTexture(0.08, 0.09, 0.10, 0.82)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(ICON_SIZE)
    icon:SetHeight(ICON_SIZE)
    icon:SetPoint("CENTER", 0, 0)
    icon:SetTexture(data.icon)

    button:SetScript("OnClick", OnToolButtonClick)
    button:SetScript("OnEnter", OnToolButtonEnter)
    button:SetScript("OnLeave", HideTooltip)

    return button
end

local function RelayoutPanel()
    if not frame then return end

    local db = CopyDefaults()
    local visible = db.visibleIcons
    frame:SetWidth(BarWidth(visible))
    frame:SetHeight(HEIGHT)

    for i = visible + 1, #db.order do
        local button = buttons[db.order[i]]
        if button then button:Hide() end
    end

    for i = 1, visible do
        local button = buttons[db.order[i]]
        if button then
            button:ClearAllPoints()
            button:SetPoint("LEFT", frame, "LEFT", PAD + ((i - 1) * (BUTTON_SIZE + GAP)), 0)
            button:Show()
        end
    end
end

local function BuildPanel()
    if frame then return end

    local db = CopyDefaults()

    frame = CreateFrame("Frame", "UncappedPanelFrame", UIParent)
    frame:SetWidth(BarWidth(db.visibleIcons))
    frame:SetHeight(HEIGHT)
    AnchorFrame()
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    frame:SetBackdropColor(0, 0, 0, 0.84)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Move Me")
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)

    for i = 1, #TOOL_BUTTONS do
        local tool = TOOL_BUTTONS[i]
        buttons[tool.id] = CreateToolButton(frame, tool)
    end
    RelayoutPanel()

    if not db.shown then frame:Hide() end
end

local function TogglePanel()
    BuildPanel()
    local db = CopyDefaults()
    if frame:IsShown() then
        frame:Hide()
        db.shown = false
    else
        frame:Show()
        db.shown = true
    end
end

local function RefreshOrderEditor()
    local db = CopyDefaults()
    for slot = 1, #orderButtons do
        local button = orderButtons[slot]
        local tool = TOOL_BY_ID[db.order[slot]]
        if button and tool then
            button.icon:SetTexture(tool.icon)
            button.slotText:SetText(slot)
            button.tool = tool
            if draggingOrderSlot == slot then
                button:SetAlpha(0.45)
            elseif slot > db.visibleIcons then
                button:SetAlpha(0.35)
            else
                button:SetAlpha(1)
            end
        end
    end
end

local function MoveOrderSlot(fromSlot, toSlot)
    local db = CopyDefaults()
    if not fromSlot or not toSlot or fromSlot == toSlot then return end
    if fromSlot < 1 or fromSlot > #db.order or toSlot < 1 or toSlot > #db.order then return end

    local id = tremove(db.order, fromSlot)
    tinsert(db.order, toSlot, id)

    RelayoutPanel()
    RefreshOrderEditor()
end

local function OrderSlotUnderCursor()
    local cursorX, cursorY = GetCursorPosition()

    for slot = 1, #orderButtons do
        local button = orderButtons[slot]
        if button and button:IsShown() then
            local scale = button:GetEffectiveScale() or UIParent:GetEffectiveScale()
            local x = cursorX / scale
            local y = cursorY / scale
            local left, right, top, bottom = button:GetLeft(), button:GetRight(), button:GetTop(), button:GetBottom()
            if left and right and top and bottom and x >= left and x <= right and y <= top and y >= bottom then
                return slot
            end
        end
    end
end

local function FinishOrderDrag()
    if not draggingOrderSlot then return end

    local fromSlot = draggingOrderSlot
    local toSlot = OrderSlotUnderCursor()
    draggingOrderSlot = nil

    if toSlot and toSlot ~= fromSlot then
        MoveOrderSlot(fromSlot, toSlot)
    else
        RefreshOrderEditor()
    end
end

local function CreateOrderEditor(parent, y)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, y)
    holder:SetWidth((ORDER_BUTTON_SIZE * #TOOL_BUTTONS) + (ORDER_GAP * (#TOOL_BUTTONS - 1)))
    holder:SetHeight(ORDER_BUTTON_SIZE + ORDER_GAP)

    for slot = 1, #TOOL_BUTTONS do
        local button = CreateFrame("Button", nil, holder)
        button:SetWidth(ORDER_BUTTON_SIZE)
        button:SetHeight(ORDER_BUTTON_SIZE)
        button:SetPoint("LEFT", holder, "LEFT", (slot - 1) * (ORDER_BUTTON_SIZE + ORDER_GAP), 0)
        button.slot = slot
        button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        if button:GetHighlightTexture() then button:GetHighlightTexture():SetBlendMode("ADD") end

        local bg = button:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(button)
        bg:SetTexture(0.08, 0.09, 0.10, 0.86)

        local icon = button:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(ORDER_ICON_SIZE)
        icon:SetHeight(ORDER_ICON_SIZE)
        icon:SetPoint("CENTER", 0, 0)
        button.icon = icon

        local slotText = button:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        slotText:SetPoint("BOTTOMRIGHT", -1, 1)
        button.slotText = slotText

        button:SetScript("OnMouseDown", function(self, mouseButton)
            local buttonName = mouseButton or arg1
            if buttonName == "LeftButton" then
                draggingOrderSlot = self.slot
                RefreshOrderEditor()
            end
        end)
        button:SetScript("OnMouseUp", FinishOrderDrag)
        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.tool then
                GameTooltip:SetText(self.tool.label)
                GameTooltip:AddLine(ButtonCommand(self.tool), 1, 0.82, 0)
            end
            GameTooltip:AddLine("Drag to reorder", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)

        orderButtons[slot] = button
    end

    RefreshOrderEditor()
    return holder
end

local function BuildOptions()
    if optionsBuilt or not UncappedUI then return end
    optionsBuilt = true

    local _, L = UncappedUI.CreatePanel("Command Panel", "Configure the Uncapped icon toolbox.")

    L:Header("Toolbar")

    L:Check("Show panel",
        function() return CopyDefaults().shown end,
        function(v)
            local d = CopyDefaults()
            d.shown = v
            BuildPanel()
            if v then frame:Show() else frame:Hide() end
        end)

    L:Slider("Icons visible", 1, #TOOL_BUTTONS, 1,
        function() return CopyDefaults().visibleIcons end,
        function(v)
            CopyDefaults().visibleIcons = v
            RelayoutPanel()
            RefreshOrderEditor()
        end, "%d")

    L:Gap(6)
    L:Header("Icon Order")
    L:Note("Drag icons left or right to change the toolbar order.", 16)
    CreateOrderEditor(L.panel, L.y)
    L:advance(44)

    L:Button("Reset icon order", function()
        local db = CopyDefaults()
        db.order = {}
        for i = 1, #DEFAULT_ORDER do db.order[i] = DEFAULT_ORDER[i] end
        db.orderLayout = DEFAULTS.orderLayout
        RelayoutPanel()
        RefreshOrderEditor()
    end, 150)
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")

local function TryBuild(doneAfterThisEvent)
    BuildPanel()
    BuildOptions()
    if doneAfterThisEvent or (frame and optionsBuilt) then
        events:UnregisterAllEvents()
    end
end

events:SetScript("OnEvent", function(_, evt, addonName)
    local eventName = evt or event
    local loadedName = addonName or arg1
    if eventName == "ADDON_LOADED" then
        if loadedName == "Uncapped" or loadedName == ADDON_NAME or loadedName == "UncappedOptions" then
            TryBuild()
        end
    elseif eventName == "PLAYER_LOGIN" then
        TryBuild(true)
    end
end)

SLASH_UNCAPPEDPANEL1 = "/uncappedpanel"
SLASH_UNCAPPEDPANEL2 = "/upanel"
SlashCmdList["UNCAPPEDPANEL"] = TogglePanel
