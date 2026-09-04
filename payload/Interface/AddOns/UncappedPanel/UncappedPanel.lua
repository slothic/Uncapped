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

local floor, min, max, random = math.floor, math.min, math.max, math.random
local tinsert, tremove = table.insert, table.remove
local sub, gsub = string.sub, string.gsub
local tonumber, tostring, type, pairs = tonumber, tostring, type, pairs

local DEFAULTS = {
    relativeTo = "UIParent",
    point = "CENTER",
    relativePoint = "CENTER",
    x = 0,
    y = 0,
    shown = true,
    aoeLoot = false,
    layout = 4,
    orderLayout = 1,
}

local BASE_TOOL_BUTTONS = {
    { id = "dungeonStats", label = "Dungeon Stats", command = ".ds",       icon = "Interface\\Icons\\INV_Misc_Note_01" },
    { id = "reset",        label = "Reset",         command = ".reset",    icon = "Interface\\Icons\\INV_Misc_Rune_01" },
    { id = "auto",         label = "Auto",          command = ".auto",     icon = "Interface\\Icons\\Ability_Rogue_Sprint" },
    { id = "aoeLoot",      label = "Aoe Loot",      toggle = "aoeLoot",    icon = "Interface\\Icons\\INV_Misc_Bag_08" },
    { id = "statFeed",     label = "Stat Feed",     command = "/statfeed", icon = "Interface\\Icons\\INV_Misc_Book_09" },
    -- [#892] Both of these were already live on the server and neither was
    -- reachable from anywhere a player looks. Two separate players got stuck in
    -- the Ulduar tram trench -- in combat, so .reset and the hearthstone were
    -- both refused -- and one of them said so in guild chat rather than knowing
    -- there was a command for it. .dropcombat shipped for #856 and was never
    -- surfaced; .unstuck has always existed and is not in COMMANDS.md either.
    { id = "unstuck",      label = "Unstuck",       command = ".unstuck",  icon = "Interface\\Icons\\Spell_Nature_Astralrecal" },
    { id = "dropCombat",   label = "Drop Combat",   command = ".dropcombat", icon = "Interface\\Icons\\Ability_Rogue_Feint" },
}
DEFAULTS.visibleIcons = #BASE_TOOL_BUTTONS

local RANDOM_ICONS = {
    "Interface\\Icons\\INV_Misc_Gear_01",
    "Interface\\Icons\\INV_Misc_Gem_01",
    "Interface\\Icons\\INV_Misc_Key_03",
    "Interface\\Icons\\INV_Misc_Map_01",
    "Interface\\Icons\\INV_Misc_Orb_01",
    "Interface\\Icons\\INV_Misc_PocketWatch_01",
    "Interface\\Icons\\INV_Misc_QuestionMark",
    "Interface\\Icons\\INV_Scroll_03",
    "Interface\\Icons\\Spell_Arcane_PortalDalaran",
    "Interface\\Icons\\Spell_Holy_MagicalSentry",
}

local TOOL_BUTTONS = {}
local TOOL_BY_ID = {}
local BASE_TOOL_BY_ID = {}
for i = 1, #BASE_TOOL_BUTTONS do
    BASE_TOOL_BY_ID[BASE_TOOL_BUTTONS[i].id] = true
end

local DEFAULT_ORDER = {
    "statFeed",
    "reset",
    "dungeonStats",
    "auto",
    "aoeLoot",
}

local function AddRuntimeTool(tool)
    TOOL_BUTTONS[#TOOL_BUTTONS + 1] = tool
    TOOL_BY_ID[tool.id] = tool
end

local function RebuildTools(db)
    while #TOOL_BUTTONS > 0 do tremove(TOOL_BUTTONS) end
    for id in pairs(TOOL_BY_ID) do TOOL_BY_ID[id] = nil end

    for i = 1, #BASE_TOOL_BUTTONS do
        AddRuntimeTool(BASE_TOOL_BUTTONS[i])
    end

    local custom = db and db.customButtons
    if type(custom) ~= "table" then return end

    local used = {}
    for i = 1, #BASE_TOOL_BUTTONS do used[BASE_TOOL_BUTTONS[i].id] = true end
    for i = 1, #custom do
        local saved = custom[i]
        if type(saved) == "table" then
            local id = tostring(saved.id or "")
            if id ~= "" and not used[id] then
                used[id] = true
                AddRuntimeTool({
                    id = id,
                    label = tostring(saved.label or ("Custom " .. i)),
                    command = tostring(saved.command or ""),
                    icon = tostring(saved.icon or RANDOM_ICONS[1]),
                    custom = true,
                })
            end
        end
    end
end

RebuildTools()

local function BarWidth(count)
    count = max(1, min(#TOOL_BUTTONS, tonumber(count) or #TOOL_BUTTONS))
    return PAD * 2 + (BUTTON_SIZE * count) + (GAP * (count - 1))
end

local HEIGHT = PAD * 2 + BUTTON_SIZE

local frame
local CopyDefaults
local buttons = {}
local orderButtons = {}
local orderHolder
local visibleSlider
local visibleSliderHigh
local customNameBox
local customCommandBox
local optionsBuilt = false
local draggingOrderSlot
local dbReady = false
local commandRunner
local DeleteCustomButton

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

local function RandomIcon()
    return RANDOM_ICONS[random(1, #RANDOM_ICONS)]
end

local function TrimText(text)
    text = tostring(text or "")
    text = gsub(text, "^%s+", "")
    return gsub(text, "%s+$", "")
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
    UncappedPanelDB.customCounter = floor(SavedNumber(UncappedPanelDB.customCounter, 0, 0) + 0.5)
    if type(UncappedPanelDB.customButtons) ~= "table" then UncappedPanelDB.customButtons = {} end

    local cleanCustom = {}
    local usedCustom = {}
    for i = 1, #UncappedPanelDB.customButtons do
        local saved = UncappedPanelDB.customButtons[i]
        if type(saved) == "table" then
            local id = tostring(saved.id or "")
            if id ~= "" and not BASE_TOOL_BY_ID[id] and not usedCustom[id] then
                usedCustom[id] = true
                tinsert(cleanCustom, {
                    id = id,
                    label = tostring(saved.label or ("Custom " .. i)),
                    command = tostring(saved.command or ""),
                    icon = tostring(saved.icon or RANDOM_ICONS[1]),
                })
            end
        end
    end
    UncappedPanelDB.customButtons = cleanCustom
    RebuildTools(UncappedPanelDB)

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
    for i = 1, #TOOL_BUTTONS do
        local id = TOOL_BUTTONS[i].id
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

    -- [Uncapped] Bare EditBox, built up by hand -- NOT ChatFrameEditBoxTemplate.
    --
    -- ChatEdit_SendText runs the command and then tears the box down again:
    -- ChatEdit_ParseText -> ChatEdit_OnEscapePressed -> ChatEdit_DeactivateChat,
    -- and that last one indexes editBox.header unguarded (ChatFrame.lua:3417).
    -- A bare CreateFrame("EditBox") has no header, so every panel button that
    -- ran a slash command threw
    --     attempt to index field 'header' (a nil value)
    -- AFTER the command had already gone through -- which is why the buttons
    -- looked like they worked while filling the error frame. Reported in game.
    --
    -- That was "fixed" by inheriting ChatFrameEditBoxTemplate instead, but its
    -- <OnLoad> runs ChatEdit_OnLoad synchronously INSIDE CreateFrame -- before
    -- commandRunner.chatFrame is assigned below -- and ChatEdit_OnLoad indexes
    -- self.chatFrame unconditionally (ChatFrame.lua:3306), since the template
    -- assumes it's inheriting into a real chat frame's own edit box, not a
    -- synthetic one parented to UIParent. That threw
    --     attempt to index field 'chatFrame' (a nil value)
    -- on every load. Reported in game. Back to a bare EditBox, but this time
    -- with every field ChatEdit_OnLoad would have set supplied by hand, so
    -- neither bug's code path can fire again.
    commandRunner = CreateFrame("EditBox", "UncappedPanelCommandRunner", UIParent)
    commandRunner:Hide()
    commandRunner:SetAutoFocus(false)
    commandRunner:SetFontObject(ChatFontNormal)
    commandRunner.chatType = "SAY"
    commandRunner.chatFrame = DEFAULT_CHAT_FRAME
    commandRunner.historyLines = {}
    commandRunner.historyIndex = 0
    commandRunner.addHistoryLine = true
    if commandRunner.SetAttribute then commandRunner:SetAttribute("chatType", "SAY") end

    commandRunner.header = commandRunner:CreateFontString(nil, "ARTWORK", "ChatFontNormal")
    commandRunner.header:Hide()

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
    return data.command or ""
end

local function RunButton(data)
    local db = CopyDefaults()
    local command = ButtonCommand(data, db)
    if command == "" then
        Chat(C_PANEL .. data.label .. " has no command assigned yet.")
        return
    end
    if RunTypedCommand(command) and data.toggle == "aoeLoot" then
        db.aoeLoot = not db.aoeLoot
    end
end

local function OnToolButtonClick(self, mouseButton)
    local buttonName = mouseButton or arg1
    if buttonName == "RightButton" and IsShiftKeyDown and IsShiftKeyDown() then
        if DeleteCustomButton then DeleteCustomButton(self.data) end
        return
    end
    if buttonName == "LeftButton" or not buttonName then
        RunButton(self.data)
    end
end

local function OnToolButtonEnter(self)
    local data = self.data
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(data.label)
    local command = ButtonCommand(data)
    if command ~= "" then
        GameTooltip:AddLine(command, 1, 0.82, 0)
    else
        GameTooltip:AddLine("No command assigned", 0.7, 0.7, 0.7)
    end
    if data.custom then
        GameTooltip:AddLine("Shift-right-click to delete", 1, 0.35, 0.25)
    else
        GameTooltip:AddLine("Built-in button", 0.5, 0.5, 0.5)
    end
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
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
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
    button.icon = icon

    button:SetScript("OnClick", OnToolButtonClick)
    button:SetScript("OnEnter", OnToolButtonEnter)
    button:SetScript("OnLeave", HideTooltip)

    return button
end

local function EnsurePanelButtons()
    if not frame then return end

    for i = 1, #TOOL_BUTTONS do
        local tool = TOOL_BUTTONS[i]
        if not buttons[tool.id] then
            buttons[tool.id] = CreateToolButton(frame, tool)
        else
            buttons[tool.id].data = tool
            buttons[tool.id].icon:SetTexture(tool.icon)
        end
    end
end

local function RemoveOrderId(db, id)
    for i = #db.order, 1, -1 do
        if db.order[i] == id then tremove(db.order, i) end
    end
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
    for id, button in pairs(buttons) do
        if not TOOL_BY_ID[id] then button:Hide() end
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
    --[[ ⚠ ESCAPE MUST NOT CLOSE THIS. Do not re-add UISpecialFrames here.

         Added by the 2026-08-16 UI style audit on the reasoning that "siblings of
         this window had these and it did not", and removed the same day for the
         same reason StatFeedFrame was: this is a BAR, not a dialog. It is a
         toolbar you position once and leave up while you play, so it belongs with
         UncappedChat and the Loot Feed popout -- both deliberately off the list --
         rather than with the bug reporter and the forge preview, which are opened,
         used and dismissed.

         Escape is pressed constantly for unrelated reasons (game menu, clearing a
         target, stopping a cast) and every one of them was taking the bar away.

         Close it with /upanel. ]]
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

    EnsurePanelButtons()
    RelayoutPanel()

    -- Player window zoom (ESC > Interface > AddOns > Uncapped, or /uiscale).
    --
    -- Registered AFTER AnchorFrame so the bar already has its anchor: the zoom
    -- system rewrites those offsets to hold the bar on the same spot on screen,
    -- and there is nothing to rewrite before the first SetPoint.
    --
    -- The bar may be anchored to the MINIMAP rather than to UIParent, which is
    -- fine and needs no special case: offsets are in the anchored frame's own
    -- units either way, and the minimap's screen position does not depend on
    -- this frame's scale.
    --
    -- OrderSlotUnderCursor's hit-testing needs nothing either -- it already
    -- divides GetCursorPosition() (raw pixels) by the button's EFFECTIVE scale
    -- rather than assuming 1, so it follows the zoom for free.
    if UncappedScale_Register then
        UncappedScale_Register(frame, { group = "panel", savePosition = SavePosition })
    end

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

local function CreateOrderButton(holder, slot)
    local button = CreateFrame("Button", nil, holder)
    button:SetWidth(ORDER_BUTTON_SIZE)
    button:SetHeight(ORDER_BUTTON_SIZE)
    button.slot = slot
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
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
    button:SetScript("OnMouseUp", function(self, mouseButton)
        local buttonName = mouseButton or arg1
        if buttonName == "RightButton" and IsShiftKeyDown and IsShiftKeyDown() then
            if DeleteCustomButton then DeleteCustomButton(self.tool) end
            draggingOrderSlot = nil
            return
        end
        FinishOrderDrag()
    end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if self.tool then
            GameTooltip:SetText(self.tool.label)
            local command = ButtonCommand(self.tool)
            if command ~= "" then
                GameTooltip:AddLine(command, 1, 0.82, 0)
            else
                GameTooltip:AddLine("No command assigned", 0.7, 0.7, 0.7)
            end
            if self.tool.custom then
                GameTooltip:AddLine("Shift-right-click to delete", 1, 0.35, 0.25)
            end
        end
        GameTooltip:AddLine("Drag to reorder", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    orderButtons[slot] = button
    return button
end

local function EnsureOrderEditorSlots()
    if not orderHolder then return end

    orderHolder:SetWidth((ORDER_BUTTON_SIZE * #TOOL_BUTTONS) + (ORDER_GAP * max(0, #TOOL_BUTTONS - 1)))
    for slot = 1, #TOOL_BUTTONS do
        local button = orderButtons[slot] or CreateOrderButton(orderHolder, slot)
        button:ClearAllPoints()
        button:SetPoint("LEFT", orderHolder, "LEFT", (slot - 1) * (ORDER_BUTTON_SIZE + ORDER_GAP), 0)
        button.slot = slot
        button:Show()
    end
    for slot = #TOOL_BUTTONS + 1, #orderButtons do
        if orderButtons[slot] then orderButtons[slot]:Hide() end
    end
end

local function CreateOrderEditor(parent, y)
    orderHolder = CreateFrame("Frame", nil, parent)
    orderHolder:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, y)
    orderHolder:SetHeight(ORDER_BUTTON_SIZE + ORDER_GAP)

    EnsureOrderEditorSlots()
    RefreshOrderEditor()
    return orderHolder
end

local function CreateOptionEditBox(L, label, width)
    local fs = L.panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", L.panel, "TOPLEFT", 16, L.y)
    fs:SetText(label)
    L:advance(16)

    local box = CreateFrame("EditBox", nil, L.panel, "InputBoxTemplate")
    box:SetPoint("TOPLEFT", L.panel, "TOPLEFT", 20, L.y)
    box:SetWidth(width or 260)
    box:SetHeight(22)
    box:SetAutoFocus(false)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    L:advance(32)
    return box
end

local function RefreshVisibleSlider()
    if not visibleSlider then return end

    visibleSlider:SetMinMaxValues(1, #TOOL_BUTTONS)
    if visibleSliderHigh then visibleSliderHigh:SetText(tostring(#TOOL_BUTTONS)) end
    visibleSlider:SetValue(CopyDefaults().visibleIcons)
end

DeleteCustomButton = function(data)
    if not data then return end
    if not data.custom then
        Chat(C_PANEL .. "built-in buttons cannot be deleted. Move them right or lower Icons visible to hide them.")
        return
    end

    local db = CopyDefaults()
    for i = #db.customButtons, 1, -1 do
        if db.customButtons[i].id == data.id then tremove(db.customButtons, i) end
    end
    RemoveOrderId(db, data.id)
    RebuildTools(db)
    db.visibleIcons = min(#TOOL_BUTTONS, max(1, db.visibleIcons))

    if buttons[data.id] then buttons[data.id]:Hide() end
    EnsureOrderEditorSlots()
    RelayoutPanel()
    RefreshOrderEditor()
    RefreshVisibleSlider()
    Chat(C_PANEL .. "deleted " .. C_CMD .. data.label .. C_RESET .. ".")
end

local function NewCustomButton()
    local db = CopyDefaults()
    db.customButtons = db.customButtons or {}

    local label = TrimText(customNameBox and customNameBox:GetText())
    local command = TrimText(customCommandBox and customCommandBox:GetText())
    if label == "" then
        Chat(C_PANEL .. "enter a button name first.")
        return
    end
    if command == "" then
        Chat(C_PANEL .. "enter a command first.")
        return
    end

    local id
    repeat
        db.customCounter = floor(SavedNumber(db.customCounter, 0, 0) + 1)
        id = "custom" .. db.customCounter
    until not TOOL_BY_ID[id]

    local custom = {
        id = id,
        label = label,
        command = command,
        icon = RandomIcon(),
    }
    tinsert(db.customButtons, custom)

    RebuildTools(db)
    tinsert(db.order, custom.id)
    db.visibleIcons = min(#TOOL_BUTTONS, db.visibleIcons + 1)

    EnsurePanelButtons()
    EnsureOrderEditorSlots()
    RelayoutPanel()
    RefreshOrderEditor()
    RefreshVisibleSlider()
    if customNameBox then customNameBox:SetText("") end
    if customCommandBox then customCommandBox:SetText("") end
    Chat(C_PANEL .. "created " .. C_CMD .. custom.label .. C_RESET .. " with a random icon.")
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

    visibleSlider = L:Slider("Icons visible", 1, #TOOL_BUTTONS, 1,
        function() return CopyDefaults().visibleIcons end,
        function(v)
            CopyDefaults().visibleIcons = v
            RelayoutPanel()
            RefreshOrderEditor()
        end, "%d")
    if visibleSlider and visibleSlider.GetName then
        visibleSliderHigh = _G[visibleSlider:GetName() .. "High"]
    end

    L:Gap(6)
    L:Header("Icon Order")
    L:Note("Drag icons left or right to change the toolbar order. Custom buttons can be deleted with shift-right-click.", 32)
    CreateOrderEditor(L.panel, L.y)
    L:advance(44)

    L:Gap(4)
    L:Header("Custom Button")
    customNameBox = CreateOptionEditBox(L, "Button name", 260)
    customCommandBox = CreateOptionEditBox(L, "Chat command", 260)
    L:Button("Add custom button", NewCustomButton, 170)

    L:Button("Reset icon order", function()
        local db = CopyDefaults()
        db.order = {}
        for i = 1, #DEFAULT_ORDER do db.order[i] = DEFAULT_ORDER[i] end
        for i = 1, #TOOL_BUTTONS do
            local id = TOOL_BUTTONS[i].id
            local exists
            for j = 1, #db.order do
                if db.order[j] == id then exists = true; break end
            end
            if not exists then tinsert(db.order, id) end
        end
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
        if loadedName == ADDON_NAME or loadedName == "UncappedOptions" then
            TryBuild()
        end
    elseif eventName == "PLAYER_LOGIN" then
        TryBuild(true)
    end
end)

SLASH_UNCAPPEDPANEL1 = "/uncappedpanel"
SLASH_UNCAPPEDPANEL2 = "/upanel"
SlashCmdList["UNCAPPEDPANEL"] = TogglePanel
