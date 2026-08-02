-- UncappedVault_UI -- table-style UI for UncappedVault.
-- Written for 3.3.5a: no BackdropTemplate and no modern C_ APIs.

local Core = _G.UncappedVault
if not Core then return end

local UI = {}
Core.RegisterUI(UI)

local floor, min, max = math.floor, math.min, math.max
local format = string.format

local PAD = 16
local LEFT_W = 240
local RIGHT_W = 260
local TOP_H = 92
local FOOTER_H = 58
local ROW_H = 48
local TABLE_HEAD_H = 34
local ICON = 36
local GRID_SLOT = 38
local GRID_GAP = 6
local GRID_COLS = 13
local GRID_HEADER_H = 30
local CATEGORY_START_Y = 74
local CATEGORY_ROW_H = 24

local frame, searchBox, categoryPanel, tablePanel, gridPanel, detailPanel, infoPanel, footerBar
local rows, catRows, gridSlots, gridHeaders = {}, {}, {}, {}
local viewButtons = {}
local qualityDD, slotDD

local GOLD = { 1.00, 0.82, 0.22 }
local BLUE = { 0.30, 0.62, 1.00 }
local GREEN = { 0.32, 1.00, 0.20 }
local PURPLE = { 0.68, 0.28, 1.00 }
local RED = { 0.72, 0.10, 0.06 }

local function RGB(c) return c[1], c[2], c[3] end

local function Panel(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0, 0, 0, 0.82)
    return f
end

local function Text(parent, template, point, rel, relPoint, x, y, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    fs:SetPoint(point, rel or parent, relPoint or point, x or 0, y or 0)
    fs:SetText(text or "")
    return fs
end

local function Button(parent, label, width, height)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(width or 90)
    b:SetHeight(height or 26)
    b:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    b:SetBackdropColor(0.05, 0.05, 0.05, 0.88)
    b:SetBackdropBorderColor(0.30, 0.27, 0.20, 0.95)
    b.text = Text(b, "GameFontHighlightSmall", "CENTER", b, "CENTER", 0, 0, label)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    if b:GetHighlightTexture() then b:GetHighlightTexture():SetBlendMode("ADD") end
    return b
end

local function SetButtonActive(b, active)
    if active then
        b:SetBackdropColor(0.25, 0.18, 0.02, 0.92)
        b:SetBackdropBorderColor(RGB(GOLD))
        b.text:SetTextColor(RGB(GOLD))
    else
        b:SetBackdropColor(0.05, 0.05, 0.05, 0.88)
        b:SetBackdropBorderColor(0.30, 0.27, 0.20, 0.95)
        b.text:SetTextColor(0.85, 0.85, 0.85)
    end
end

local function ItemName(item)
    if not item then return "" end
    return (item.n and item.n ~= "" and item.n) or GetItemInfo(item.e) or ("item " .. tostring(item.e))
end

local function ItemIcon(item)
    if not item then return "Interface\\Icons\\INV_Misc_QuestionMark" end
    local _, _, _, _, _, _, _, _, _, icon = GetItemInfo(item.e)
    return item.icon or item.i or icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function QualityColor(q)
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q or 1]
    if c then return c.r, c.g, c.b end
    if q == 5 then return 1, 0.5, 0 end
    if q == 4 then return RGB(PURPLE) end
    if q == 3 then return RGB(BLUE) end
    if q == 2 then return RGB(GREEN) end
    return 0.82, 0.82, 0.82
end

local function QualityName(q)
    return Core.QUALITY_LABELS[q or 1] or "Common"
end

local function Dropdown(parent, name, width, choices, get, set)
    local dd = CreateFrame("Frame", name, parent, "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(dd, width)
    UIDropDownMenu_Initialize(dd, function()
        for _, choice in ipairs(choices) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = choice.text
            info.value = choice.value
            info.checked = get() == choice.value
            info.func = function()
                set(choice.value)
                UIDropDownMenu_SetSelectedValue(dd, choice.value)
                UIDropDownMenu_SetText(dd, choice.text)
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    for _, choice in ipairs(choices) do
        if choice.value == get() then
            UIDropDownMenu_SetSelectedValue(dd, choice.value)
            UIDropDownMenu_SetText(dd, choice.text)
            break
        end
    end
    return dd
end

local function SortHeader(parent, label, key, x, w)
    local b = Button(parent, label, w, TABLE_HEAD_H - 6)
    b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -4)
    b.key = key
    b:SetScript("OnClick", function() Core.SetSort(key) end)
    return b
end

local function CreateRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(TABLE_HEAD_H + (index - 1) * ROW_H))
    row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    if row:GetHighlightTexture() then row:GetHighlightTexture():SetBlendMode("ADD") end

    row.line = row:CreateTexture(nil, "BACKGROUND")
    row.line:SetTexture(1, 1, 1, 0.05)
    row.line:SetPoint("BOTTOMLEFT", 4, 0)
    row.line:SetPoint("BOTTOMRIGHT", -4, 0)
    row.line:SetHeight(1)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetWidth(ICON)
    row.icon:SetHeight(ICON)
    row.icon:SetPoint("LEFT", 12, 0)

    row.name = Text(row, "GameFontHighlightSmall", "LEFT", row, "LEFT", 58, 0)
    row.name:SetWidth(150)
    row.name:SetJustifyH("LEFT")
    row.level = Text(row, "GameFontHighlightSmall", "LEFT", row, "LEFT", 236, 0)
    row.level:SetWidth(44)
    row.rarity = Text(row, "GameFontHighlightSmall", "LEFT", row, "LEFT", 300, 0)
    row.rarity:SetWidth(80)
    row.qty = Text(row, "GameFontHighlightSmall", "RIGHT", row, "LEFT", 438, 0)
    row.qty:SetWidth(64)
    row.slot = Text(row, "GameFontHighlightSmall", "LEFT", row, "LEFT", 494, 0)
    row.slot:SetWidth(130)
    row.date = Text(row, "GameFontHighlightSmall", "LEFT", row, "LEFT", 660, 0)
    row.date:SetWidth(50)

    row:SetScript("OnClick", function(self, mouse)
        if CursorHasItem() then Core.DepositCursor(); return end
        if not self.item then return end
        Core.SelectItem(self.item)
        if mouse == "RightButton" then
            Core.Withdraw(self.item, IsShiftKeyDown() and (self.item.c or 1) or 1)
        end
    end)
    row:SetScript("OnReceiveDrag", Core.DepositCursor)
    row:SetScript("OnEnter", function(self)
        if not self.item then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local link = select(2, GetItemInfo(self.item.e))
        if link then GameTooltip:SetHyperlink(link) else GameTooltip:SetText(ItemName(self.item)) end
        GameTooltip:AddLine("Right-click to withdraw one.", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Shift-right-click to withdraw all.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

local function CreateGridHeader(parent, index)
    local h = CreateFrame("Frame", nil, parent)
    h:SetHeight(GRID_HEADER_H)
    h:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, -12)
    h:SetPoint("RIGHT", parent, "RIGHT", -12, 0)
    h.bg = h:CreateTexture(nil, "BACKGROUND")
    h.bg:SetTexture(0.10, 0.10, 0.14, 0.92)
    h.bg:SetAllPoints(h)
    h.label = Text(h, "GameFontNormal", "LEFT", h, "LEFT", 16, 0)
    h.label:SetTextColor(RGB(GOLD))
    gridHeaders[index] = h
    return h
end

local function CreateGridSlot(parent, index)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(GRID_SLOT)
    b:SetHeight(GRID_SLOT)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    b:SetBackdropColor(0, 0, 0, 0.86)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 3, -3)
    b.icon:SetPoint("BOTTOMRIGHT", -3, 3)
    b.count = Text(b, "NumberFontNormal", "BOTTOMRIGHT", b, "BOTTOMRIGHT", -3, 2, "")
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    if b:GetHighlightTexture() then b:GetHighlightTexture():SetBlendMode("ADD") end
    b:SetScript("OnClick", function(self, mouse)
        if CursorHasItem() then Core.DepositCursor(); return end
        if not self.item then return end
        Core.SelectItem(self.item)
        if mouse == "RightButton" then
            Core.Withdraw(self.item, IsShiftKeyDown() and (self.item.c or 1) or 1)
        end
    end)
    b:SetScript("OnReceiveDrag", Core.DepositCursor)
    b:SetScript("OnEnter", function(self)
        if not self.item then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local link = select(2, GetItemInfo(self.item.e))
        if link then GameTooltip:SetHyperlink(link) else GameTooltip:SetText(ItemName(self.item)) end
        GameTooltip:AddLine("Right-click to withdraw one.", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Shift-right-click to withdraw all.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    gridSlots[index] = b
    return b
end

local function RefreshViewButtons()
    for mode, b in pairs(viewButtons) do
        SetButtonActive(b, Core.state.viewMode == mode)
    end
end

local function RefreshCategories()
    for i, cat in ipairs(Core.categories) do
        local row = catRows[i]
        if not row then
            row = CreateFrame("Button", nil, categoryPanel)
            row:SetHeight(CATEGORY_ROW_H)
            row:SetPoint("TOPLEFT", categoryPanel, "TOPLEFT", 8, -(CATEGORY_START_Y + (i - 1) * CATEGORY_ROW_H))
            row:SetPoint("RIGHT", categoryPanel, "RIGHT", -8, 0)
            row.selected = row:CreateTexture(nil, "BACKGROUND")
            row.selected:SetPoint("TOPLEFT", 2, -2)
            row.selected:SetPoint("BOTTOMRIGHT", -2, 2)
            row.selected:SetTexture(GOLD[1], GOLD[2], GOLD[3], 0.18)
            row.selected:Hide()
            row.label = Text(row, "GameFontHighlightSmall", "LEFT", row, "LEFT", 14, 0)
            row.count = Text(row, "GameFontHighlightSmall", "RIGHT", row, "RIGHT", -10, 0)
            row.line = row:CreateTexture(nil, "BACKGROUND")
            row.line:SetTexture(1, 1, 1, 0.06)
            row.line:SetPoint("BOTTOMLEFT", 4, 0); row.line:SetPoint("BOTTOMRIGHT", -4, 0); row.line:SetHeight(1)
            row:SetScript("OnClick", function(self)
                if self.kind == "subcategory" then
                    Core.SetSubcategory(self.key, self.subcategory)
                else
                    Core.SetCategory(self.key)
                end
            end)
            catRows[i] = row
        end
        row.kind = cat.kind or "category"
        row.key = cat.key
        row.subcategory = cat.subcategory
        row.label:SetText(cat.label)
        row.count:SetText(Core.Comma(cat.count))
        row.label:ClearAllPoints()
        if row.kind == "subcategory" then
            row.label:SetPoint("LEFT", row, "LEFT", 28, 0)
            row.count:SetTextColor(0.62, 0.62, 0.62)
        else
            row.label:SetPoint("LEFT", row, "LEFT", 12, 0)
            row.count:SetTextColor(0.82, 0.82, 0.82)
        end

        local active = (row.kind == "category" and Core.state.category == cat.key)
            or (row.kind == "subcategory" and Core.state.category == cat.key and Core.state.subcategory == cat.subcategory)
        row:SetAlpha(active and 1 or (row.kind == "subcategory" and 0.72 or 0.82))
        if active then
            if row.kind == "subcategory" then
                row.selected:SetTexture(0.30, 0.62, 1.00, 0.16)
            else
                row.selected:SetTexture(GOLD[1], GOLD[2], GOLD[3], 0.18)
            end
            row.selected:Show()
        else
            row.selected:Hide()
        end
        if active then
            row.label:SetTextColor(RGB(GOLD))
        else
            row.label:SetTextColor(0.85, 0.85, 0.85)
        end
        row:Show()
    end
    for i = #Core.categories + 1, #catRows do catRows[i]:Hide() end
end

function UI.RefreshDetails()
    if not detailPanel then return end
    local it = Core.selectedItem
    if not it then
        detailPanel.icon:Hide()
        detailPanel.name:SetText("|cffffd100Select an item|r")
        detailPanel.meta:SetText("to view details")
        detailPanel.count:SetText("")
        detailPanel.withdraw:Disable()
        return
    end
    detailPanel.icon:SetTexture(ItemIcon(it))
    detailPanel.icon:Show()
    local r, g, b = QualityColor(it.q)
    detailPanel.name:SetText(ItemName(it))
    detailPanel.name:SetTextColor(r, g, b)
    detailPanel.meta:SetText(format("%s  |cff777777-|r  %s", QualityName(it.q), Core.SLOT_LABELS[Core.SlotFor(it)] or "Item"))
    detailPanel.count:SetText("Quantity: |cffffd100" .. Core.Comma(it.c or 0) .. "|r")
    detailPanel.withdraw:Enable()
end

local function RefreshInfo()
    if not infoPanel then return end
    infoPanel.total:SetText(Core.Comma(Core.totalItems))
    infoPanel.categories:SetText(tostring(Core.CATEGORY_COUNT))
    infoPanel.space:SetText(Core.Comma(Core.spaceUsed))
    infoPanel.deposits:SetText(Core.Comma(Core.depositCount))
    infoPanel.withdrawals:SetText(Core.Comma(Core.withdrawCount))

    footerBar.label:SetText("Vault Space Used:  |cffffd100" .. Core.Comma(Core.spaceUsed) .. "|r")
end

local function RefreshRows()
    if not tablePanel then return end
    local pageItems = Core.PageItems()
    for i = 1, Core.state.pageSize do
        local row = rows[i]
        local it = pageItems[i]
        if it then
            row.item = it
            row.icon:SetTexture(ItemIcon(it))
            row.name:SetText(ItemName(it))
            row.name:SetTextColor(QualityColor(it.q))
            row.level:SetText(tostring(it.ilvl or 1))
            row.rarity:SetText(QualityName(it.q))
            row.rarity:SetTextColor(QualityColor(it.q))
            row.qty:SetText(Core.Comma(it.c or 0))
            row.slot:SetText(Core.SLOT_LABELS[Core.SlotFor(it)] or "Item")
            row.date:SetText(Core.ItemAgeText(it))
            row:Show()
        else
            row.item = nil
            row:Hide()
        end
    end
    tablePanel.pageText:SetText(format("Page %d of %d", Core.state.page, Core.PageCount()))
end

local function RefreshGrid()
    if not gridPanel then return end

    local entries = Core.PageGridEntries()
    local headerIndex, slotIndex = 0, 0
    local x, y = 12, -12
    local col = 0

    for _, entry in ipairs(entries) do
        if entry.header then
            if col > 0 then
                col = 0
                x = 12
                y = y - (GRID_SLOT + GRID_GAP)
            end
            headerIndex = headerIndex + 1
            local h = gridHeaders[headerIndex] or CreateGridHeader(gridPanel, headerIndex)
            h:ClearAllPoints()
            h:SetPoint("TOPLEFT", gridPanel, "TOPLEFT", 12, y)
            h:SetPoint("RIGHT", gridPanel, "RIGHT", -12, 0)
            h.label:SetText("-  " .. entry.label .. "  |cffb8b8b8(" .. Core.Comma(entry.count or 0) .. ")|r")
            h:Show()
            y = y - (GRID_HEADER_H + GRID_GAP)
            x = 12
            col = 0
        elseif entry.item then
            slotIndex = slotIndex + 1
            local b = gridSlots[slotIndex] or CreateGridSlot(gridPanel, slotIndex)
            local it = entry.item
            local r, g, bl = QualityColor(it.q)
            b.item = it
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", gridPanel, "TOPLEFT", x, y)
            b:SetBackdropBorderColor(r, g, bl, 0.95)
            b.icon:SetTexture(ItemIcon(it))
            if (it.c or 0) > 1 then b.count:SetText(Core.Comma(it.c)) else b.count:SetText("") end
            b:Show()

            col = col + 1
            if col >= GRID_COLS then
                col = 0
                x = 12
                y = y - (GRID_SLOT + GRID_GAP)
            else
                x = x + GRID_SLOT + GRID_GAP
            end
        end
    end

    for i = headerIndex + 1, #gridHeaders do gridHeaders[i]:Hide() end
    for i = slotIndex + 1, #gridSlots do
        gridSlots[i].item = nil
        gridSlots[i]:Hide()
    end
    gridPanel.pageText:SetText(format("Page %d of %d", Core.state.page, Core.PageCount()))
end

function UI.Refresh()
    if not frame then return end
    UIDropDownMenu_SetSelectedValue(qualityDD, Core.state.quality)
    UIDropDownMenu_SetText(qualityDD, Core.QUALITY_LABELS[Core.state.quality] or "All Qualities")
    UIDropDownMenu_SetSelectedValue(slotDD, Core.state.slot)
    UIDropDownMenu_SetText(slotDD, Core.SLOT_LABELS[Core.state.slot] or "All Slots")
    RefreshViewButtons()
    RefreshCategories()
    if Core.state.viewMode == "grid" then
        tablePanel:Hide()
        gridPanel:Show()
        RefreshGrid()
    else
        gridPanel:Hide()
        tablePanel:Show()
        RefreshRows()
    end
    RefreshInfo()
    UI.RefreshDetails()
end

function UI.IsShown()
    return frame and frame:IsShown()
end

function UI.Close()
    if frame then frame:Hide() end
end

local function SavePosition()
    local db = Core.GetDB()
    local p, _, rp, x, y = frame:GetPoint()
    db.point, db.relativePoint, db.x, db.y = p or "CENTER", rp or "CENTER", floor((x or 0) + 0.5), floor((y or 0) + 0.5)
    db.width, db.height = frame:GetWidth(), frame:GetHeight()
end

local function BuildFrame()
    if frame then return end
    local db = Core.GetDB()

    frame = CreateFrame("Frame", "UncappedVaultFrame", UIParent)
    frame:SetWidth(db.width)
    frame:SetHeight(db.height)
    frame:SetPoint(db.point, UIParent, db.relativePoint, db.x, db.y)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition() end)
    frame:SetScript("OnReceiveDrag", Core.DepositCursor)
    frame:SetScript("OnMouseUp", function(_, b) if b == "LeftButton" and CursorHasItem() then Core.DepositCursor() end end)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    frame:SetResizable(true)
    frame:SetMinResize(920, 620)
    frame:SetMaxResize(1400, 900)
    tinsert(UISpecialFrames, "UncappedVaultFrame")

    local banner = frame:CreateTexture(nil, "ARTWORK")
    banner:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    banner:SetWidth(256); banner:SetHeight(64)
    banner:SetPoint("TOP", 0, 12)
    Text(frame, "GameFontNormalLarge", "TOP", frame, "TOP", 0, -9, "Vault"):SetTextColor(RGB(GOLD))
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    searchBox = CreateFrame("EditBox", "UncappedVaultSearch", frame, "InputBoxTemplate")
    searchBox:SetPoint("TOPLEFT", PAD + 12, -54)
    searchBox:SetWidth(410); searchBox:SetHeight(26)
    searchBox:SetAutoFocus(false)
    local ph = Text(searchBox, "GameFontDisableSmall", "LEFT", searchBox, "LEFT", 24, 1, "Search items...")
    local mag = searchBox:CreateTexture(nil, "OVERLAY")
    mag:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
    mag:SetWidth(16); mag:SetHeight(16); mag:SetPoint("LEFT", 6, 0)
    searchBox:SetScript("OnTextChanged", function(self)
        local text = self:GetText() or ""
        if text == "" then ph:Show() else ph:Hide() end
        Core.SetQuery(text)
    end)
    searchBox:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)

    qualityDD = Dropdown(frame, "UncappedVaultQuality", 140, {
        { value = -1, text = "All Qualities" },
        { value = 5, text = "Legendary" },
        { value = 4, text = "Epic" },
        { value = 3, text = "Rare" },
        { value = 2, text = "Uncommon" },
        { value = 1, text = "Common" },
        { value = 0, text = "Poor" },
    }, function() return Core.state.quality end, Core.SetQuality)
    qualityDD:SetPoint("TOPLEFT", searchBox, "TOPRIGHT", 24, 5)

    slotDD = Dropdown(frame, "UncappedVaultSlot", 140, {
        { value = "all", text = "All Slots" },
        { value = "weapon", text = "Weapons" },
        { value = "armor", text = "Armor" },
        { value = "consumable", text = "Consumables" },
        { value = "trade", text = "Trade Goods" },
        { value = "gem", text = "Gems" },
        { value = "glyph", text = "Glyphs" },
        { value = "recipe", text = "Recipes" },
        { value = "quest", text = "Quest Items" },
        { value = "misc", text = "Miscellaneous" },
    }, function() return Core.state.slot end, Core.SetSlot)
    slotDD:SetPoint("LEFT", qualityDD, "RIGHT", 18, 0)

    local filter = Button(frame, "Filters", 92, 30)
    filter:SetPoint("LEFT", slotDD, "RIGHT", 18, -5)
    filter:SetScript("OnClick", function()
        searchBox:SetText("")
        Core.ResetFilters()
    end)
    local refresh = Button(frame, "R", 34, 30)
    refresh:SetPoint("LEFT", filter, "RIGHT", 10, 0)
    refresh:SetScript("OnClick", function() Core.RequestSnapshot(true); Core.Rebuild(); UI.Refresh() end)

    categoryPanel = Panel(frame)
    categoryPanel:SetPoint("TOPLEFT", PAD, -TOP_H)
    categoryPanel:SetPoint("BOTTOMLEFT", PAD, FOOTER_H + 12)
    categoryPanel:SetWidth(LEFT_W)
    Text(categoryPanel, "GameFontNormal", "TOPLEFT", categoryPanel, "TOPLEFT", 14, -14, "All Categories"):SetTextColor(RGB(GOLD))
    local viewLabel = Text(categoryPanel, "GameFontNormalSmall", "TOPLEFT", categoryPanel, "TOPLEFT", 14, -38, "View")
    viewLabel:SetTextColor(RGB(GOLD))
    local listView = Button(categoryPanel, "List", 70, 24)
    listView:SetPoint("TOPLEFT", categoryPanel, "TOPLEFT", 14, -52)
    local gridView = Button(categoryPanel, "Grid", 70, 24)
    gridView:SetPoint("LEFT", listView, "RIGHT", 8, 0)
    viewButtons.list, viewButtons.grid = listView, gridView
    listView:SetScript("OnClick", function() Core.SetViewMode("list") end)
    gridView:SetScript("OnClick", function() Core.SetViewMode("grid") end)

    detailPanel = Panel(frame)
    detailPanel:SetPoint("TOPRIGHT", -PAD, -TOP_H)
    detailPanel:SetWidth(RIGHT_W)
    detailPanel:SetHeight(390)
    detailPanel.icon = detailPanel:CreateTexture(nil, "ARTWORK")
    detailPanel.icon:SetWidth(56); detailPanel.icon:SetHeight(56)
    detailPanel.icon:SetPoint("TOP", 0, -68)
    detailPanel.name = Text(detailPanel, "GameFontNormalLarge", "CENTER", detailPanel, "CENTER", 0, 34, "|cffffd100Select an item|r")
    detailPanel.meta = Text(detailPanel, "GameFontHighlight", "TOP", detailPanel.name, "BOTTOM", 0, -8, "to view details")
    detailPanel.count = Text(detailPanel, "GameFontHighlightSmall", "TOP", detailPanel.meta, "BOTTOM", 0, -16, "")
    detailPanel.withdraw = Button(detailPanel, "Withdraw Selected", 150, 28)
    detailPanel.withdraw:SetPoint("BOTTOM", 0, 18)
    detailPanel.withdraw:SetScript("OnClick", function() Core.Withdraw(Core.selectedItem, IsShiftKeyDown() and (Core.selectedItem and Core.selectedItem.c or 1) or 1) end)

    infoPanel = Panel(frame)
    infoPanel:SetPoint("TOPRIGHT", detailPanel, "BOTTOMRIGHT", 0, -12)
    infoPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, FOOTER_H + 12)
    infoPanel:SetWidth(RIGHT_W)
    Text(infoPanel, "GameFontNormal", "TOPLEFT", infoPanel, "TOPLEFT", 16, -16, "Vault Info"):SetTextColor(RGB(GOLD))
    local labels = { "Total Items", "Categories", "Space Used", "Deposits", "Withdrawals" }
    local keys = { "total", "categories", "space", "deposits", "withdrawals" }
    for i = 1, #labels do
        Text(infoPanel, "GameFontHighlightSmall", "TOPLEFT", infoPanel, "TOPLEFT", 16, -(54 + (i - 1) * 30), labels[i])
        infoPanel[keys[i]] = Text(infoPanel, "GameFontHighlightSmall", "TOPRIGHT", infoPanel, "TOPRIGHT", -16, -(54 + (i - 1) * 30), "0")
    end
    local tx = Button(infoPanel, "View Transaction Log", 214, 28)
    tx:SetPoint("BOTTOM", 0, 16)

    tablePanel = Panel(frame)
    tablePanel:SetPoint("TOPLEFT", categoryPanel, "TOPRIGHT", 12, 0)
    tablePanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -(RIGHT_W + PAD + 12), FOOTER_H + 12)
    SortHeader(tablePanel, "Name", "name", 12, 190)
    SortHeader(tablePanel, "Lvl", "level", 230, 52)
    SortHeader(tablePanel, "Rarity", "rarity", 292, 92)
    SortHeader(tablePanel, "Quantity", "quantity", 420, 96)
    SortHeader(tablePanel, "Slot / Type", "slot", 500, 142)
    SortHeader(tablePanel, "Deposit Date", "recent", 652, 108)
    for i = 1, Core.state.pageSize do rows[i] = CreateRow(tablePanel, i) end

    local prev = Button(tablePanel, "<", 36, 28)
    prev:SetPoint("BOTTOM", tablePanel, "BOTTOM", -70, 12)
    prev:SetScript("OnClick", function() Core.SetPage(Core.state.page - 1) end)
    tablePanel.pageText = Text(tablePanel, "GameFontHighlightSmall", "BOTTOM", tablePanel, "BOTTOM", 0, 19, "Page 1 of 1")
    local next = Button(tablePanel, ">", 36, 28)
    next:SetPoint("BOTTOM", tablePanel, "BOTTOM", 70, 12)
    next:SetScript("OnClick", function() Core.SetPage(Core.state.page + 1) end)

    gridPanel = Panel(frame)
    gridPanel:SetPoint("TOPLEFT", categoryPanel, "TOPRIGHT", 12, 0)
    gridPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -(RIGHT_W + PAD + 12), FOOTER_H + 12)
    gridPanel.pageText = Text(gridPanel, "GameFontHighlightSmall", "BOTTOM", gridPanel, "BOTTOM", 0, 19, "Page 1 of 1")
    local gridPrev = Button(gridPanel, "<", 36, 28)
    gridPrev:SetPoint("BOTTOM", gridPanel, "BOTTOM", -70, 12)
    gridPrev:SetScript("OnClick", function() Core.SetPage(Core.state.page - 1) end)
    local gridNext = Button(gridPanel, ">", 36, 28)
    gridNext:SetPoint("BOTTOM", gridPanel, "BOTTOM", 70, 12)
    gridNext:SetScript("OnClick", function() Core.SetPage(Core.state.page + 1) end)
    gridPanel:Hide()

    footerBar = CreateFrame("Frame", nil, frame)
    footerBar.label = Text(frame, "GameFontHighlightSmall", "LEFT", frame, "BOTTOMLEFT", PAD + 6, 44, "")

    local gold = Text(frame, "GameFontHighlight", "BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD - 170, 26, "12,450 |TInterface\\MoneyFrame\\UI-GoldIcon:14:14:2:0|t  87 |TInterface\\MoneyFrame\\UI-SilverIcon:14:14:2:0|t  42 |TInterface\\MoneyFrame\\UI-CopperIcon:14:14:2:0|t")
    gold:SetJustifyH("RIGHT")
    local depositBtn = Button(frame, "Deposit Items", 180, 32)
    depositBtn:SetPoint("BOTTOMRIGHT", -PAD - 8, 20)
    depositBtn:SetBackdropColor(RED[1], RED[2], RED[3], 0.95)
    depositBtn.text:SetTextColor(RGB(GOLD))
    depositBtn:SetScript("OnClick", function()
        Core.SetMode("deposit")
        if CursorHasItem() then Core.DepositCursor() end
    end)

    local grip = CreateFrame("Button", nil, frame)
    grip:SetWidth(16); grip:SetHeight(16)
    grip:SetPoint("BOTTOMRIGHT", -5, 7)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing(); SavePosition() end)
    frame:SetScript("OnSizeChanged", SavePosition)

    frame:Hide()
    UI.Refresh()
end

function UI.Open()
    BuildFrame()
    Core.Rebuild()
    UI.Refresh()
    frame:Show()
end

function UI.Toggle()
    if frame and frame:IsShown() then frame:Hide() else UI.Open() end
end

local init = CreateFrame("Frame")
init:RegisterEvent("PLAYER_LOGIN")
init:SetScript("OnEvent", function()
    Core.Rebuild()
end)
