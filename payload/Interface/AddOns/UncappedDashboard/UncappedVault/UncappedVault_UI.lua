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
local TOP_H = 92
local FOOTER_H = 58
local ROW_H = 48
local TABLE_HEAD_H = 34
-- Generous row-frame pool -- how many actually show is recomputed from
-- tablePanel's real height (see RefreshRowCount), never this constant
-- itself. High enough that even a very tall Dashboard window never runs out.
local MAX_ROWS = 24
local ICON = 36
local GRID_SLOT = 38
local GRID_GAP = 6
local GRID_HEADER_H = 30
local CATEGORY_START_Y = 80  -- clears the List/Grid buttons above it (bottom edge at -76) with a small gap
local CATEGORY_ROW_H = 24

local frame, searchBox, categoryPanel, categoryScroll, tablePanel, gridPanel, footerBar
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

-- Table columns used to sit at fixed pixel offsets tuned for a wide (~760px)
-- standalone window; embedded in the Dashboard, tablePanel can end up
-- narrower than that, and fixed offsets just spilled text out past its
-- right edge instead of shrinking to fit. Columns are fractions of
-- tablePanel's actual width instead, recomputed by RelayoutColumns
-- whenever it resizes -- see headers/rows loop below.
local COL_ICON_GUTTER = 58   -- icon (at x=12, 36 wide) + gap before columns start
local COL_RIGHT_PAD = 16     -- breathing room before the panel's own right edge
local COLUMNS = {
    { key = "name",     label = "Name",        sortKey = "name",     frac = 0.33 },
    { key = "level",    label = "Lvl",         sortKey = "level",    frac = 0.09 },
    { key = "rarity",   label = "Rarity",      sortKey = "rarity",   frac = 0.19 },
    { key = "quantity", label = "Quantity",    sortKey = "quantity", frac = 0.16 },
    { key = "slot",     label = "Slot / Type", sortKey = "slot",     frac = 0.23 },
}
local headers = {}

local function ColumnRects(panelWidth)
    local avail = max(0, (panelWidth or 0) - COL_ICON_GUTTER - COL_RIGHT_PAD)
    local x = COL_ICON_GUTTER
    local rects = {}
    for _, col in ipairs(COLUMNS) do
        local w = avail * col.frac
        rects[col.key] = { x = x, w = w }
        x = x + w
    end
    return rects
end

-- Re-anchors every header button and every row's field FontStrings to the
-- current column rects. Called once after building the table and again
-- whenever tablePanel resizes (see its OnSizeChanged in BuildFrame).
local function RelayoutColumns()
    if not tablePanel then return end
    local rects = ColumnRects(tablePanel:GetWidth())

    for _, col in ipairs(COLUMNS) do
        local rect = rects[col.key]
        local h = headers[col.key]
        if h then
            h:ClearAllPoints()
            if col.key == "name" then
                -- Spans the icon gutter too, same as the original layout's
                -- "Name" header starting well left of where the text does.
                h:SetPoint("TOPLEFT", tablePanel, "TOPLEFT", 12, -4)
                h:SetWidth(max(10, (rect.x - 12) + rect.w))
            else
                h:SetPoint("TOPLEFT", tablePanel, "TOPLEFT", rect.x, -4)
                h:SetWidth(max(10, rect.w))
            end
        end
    end

    local fieldKey = { name = "name", level = "level", rarity = "rarity", quantity = "qty", slot = "slot" }
    for _, row in ipairs(rows) do
        for _, col in ipairs(COLUMNS) do
            local rect = rects[col.key]
            local fs = row[fieldKey[col.key]]
            if fs then
                fs:ClearAllPoints()
                if col.key == "quantity" then
                    fs:SetPoint("RIGHT", row, "LEFT", rect.x + rect.w, 0)
                else
                    fs:SetPoint("LEFT", row, "LEFT", rect.x, 0)
                end
                fs:SetWidth(max(10, rect.w))
            end
        end
    end
end

local function SortHeader(parent, label, key)
    local b = Button(parent, label, 10, TABLE_HEAD_H - 6)
    b.key = key
    b:SetScript("OnClick", function() Core.SetSort(key) end)
    headers[key] = b
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

    -- Positions/widths below are placeholders -- RelayoutColumns (called
    -- right after all rows are built, and again on every tablePanel resize)
    -- re-anchors every one of these to the current column rects.
    row.name = Text(row, "GameFontHighlightSmall", "LEFT", row, "LEFT", 58, 0)
    row.name:SetJustifyH("LEFT")
    row.level = Text(row, "GameFontHighlightSmall", "LEFT", row, "LEFT", 58, 0)
    row.rarity = Text(row, "GameFontHighlightSmall", "LEFT", row, "LEFT", 58, 0)
    row.qty = Text(row, "GameFontHighlightSmall", "RIGHT", row, "LEFT", 58, 0)
    row.slot = Text(row, "GameFontHighlightSmall", "LEFT", row, "LEFT", 58, 0)

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

-- Category rows used to be placed at a fixed absolute Y per category index,
-- unbounded and unscrolled -- with enough categories/expanded subcategories
-- that ran past categoryPanel's bottom edge, and since nothing in this
-- client clips child frames, past the panel, the frame, and the window
-- itself. Windowed into categoryScroll the same way tablePanel's rows are
-- (see RelayoutColumns/RefreshRowCount) instead -- catRows[slot] is a fixed
-- visual position, repopulated with whichever category currently scrolls
-- into it.
local function RefreshCategories()
    if not categoryScroll then return end
    local visibleRows = max(1, floor(categoryScroll:GetHeight() / CATEGORY_ROW_H))
    FauxScrollFrame_Update(categoryScroll, #Core.categories, visibleRows, CATEGORY_ROW_H)
    local offset = FauxScrollFrame_GetOffset(categoryScroll)

    for slot = 1, visibleRows do
        local cat = Core.categories[slot + offset]
        local row = catRows[slot]
        if not row then
            row = CreateFrame("Button", nil, categoryScroll)
            row:SetHeight(CATEGORY_ROW_H)
            row:SetPoint("TOPLEFT", categoryScroll, "TOPLEFT", 8, -(slot - 1) * CATEGORY_ROW_H)
            row:SetPoint("RIGHT", categoryScroll, "RIGHT", -8, 0)
            row.selected = row:CreateTexture(nil, "BACKGROUND")
            row.selected:SetPoint("TOPLEFT", 2, -2)
            row.selected:SetPoint("BOTTOMRIGHT", -2, 2)
            row.selected:SetTexture(GOLD[1], GOLD[2], GOLD[3], 0.18)
            row.selected:Hide()
            row.label = Text(row, "GameFontHighlightSmall", "LEFT", row, "LEFT", 14, 0)
            -- FontStrings default to CENTER justify -- harmless with no
            -- SetWidth (the box equals the text), but label now gets an
            -- explicit width below, and centered text in a wider box is
            -- exactly what "anchored middle" looks like.
            row.label:SetJustifyH("LEFT")
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
            catRows[slot] = row
        end

        if not cat then
            row:Hide()
        else
            row.kind = cat.kind or "category"
            row.key = cat.key
            row.subcategory = cat.subcategory
            row.label:SetText(cat.label)
            row.count:SetText(Core.Comma(cat.count))
            row.label:ClearAllPoints()
            -- Width-capped and non-wrapping -- unbounded before, so a long
            -- category/subcategory name could run past categoryPanel's right
            -- edge (or, worse, wrap to a second line and bleed into the row
            -- below it) instead of just clipping. Width is relative to the
            -- row's own actual size, not the fixed LEFT_W constant, since
            -- the row is narrower than that (categoryScroll insets it).
            row.label:SetWordWrap(false)
            -- Base indent (16) puts category-row text 5px right of "All
            -- Categories" (which sits at x=19, row text starts 8px inset
            -- into categoryScroll, so 19+5-8=16); subcategories keep the
            -- same 10px indent beyond that they always had.
            local indent = (row.kind == "subcategory") and 26 or 16
            row.label:SetPoint("LEFT", row, "LEFT", indent, 0)
            row.label:SetWidth(max(10, row:GetWidth() - indent - 50))
            if row.kind == "subcategory" then
                row.count:SetTextColor(0.62, 0.62, 0.62)
            else
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
    end
    for i = visibleRows + 1, #catRows do catRows[i]:Hide() end
end

-- Item selection (Core.SelectItem, still set on row click) no longer drives
-- any visible UI now that the right-hand detail panel is gone -- Core.UI.RefreshDetails
-- is looked up with a guard before being called, so simply not defining it
-- here is enough; withdrawing still works via right-click on a row/slot.

local function RefreshInfo()
    footerBar.label:SetText("Vault Space Used:  |cffffd100" .. Core.Comma(Core.spaceUsed) .. "|r")
end

local function RefreshRows()
    if not tablePanel or not tablePanel.pageText then return end
    local pageItems = Core.PageItems()
    -- Always walks the full MAX_ROWS pool, not just the current pageSize --
    -- pageSize can shrink between refreshes (window got shorter), and rows
    -- beyond the new size need to actually hide, not just stop being touched.
    for i = 1, MAX_ROWS do
        local row = rows[i]
        if not row then break end
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
            row:Show()
        else
            row.item = nil
            row:Hide()
        end
    end
    tablePanel.pageText:SetText(format("Page %d of %d", Core.state.page, Core.PageCount()))
end

-- List-view page size used to be a fixed 12 (see Core.SetPageSize's comment
-- for why that overflowed past the panel's bottom edge once embedded).
-- Recomputes how many rows actually fit in tablePanel's current height and,
-- if that's changed, tells Core about the new page size and re-renders.
local function RefreshRowCount()
    if not tablePanel then return end
    local avail = tablePanel:GetHeight() - TABLE_HEAD_H
    local fit = max(1, min(MAX_ROWS, floor(avail / ROW_H)))
    if fit ~= Core.state.pageSize then
        Core.SetPageSize(fit)
        RefreshRows()
    end
end

-- Column count used to be a fixed 13, tuned for a wide standalone window --
-- same overflow problem the list view's fixed pixel columns had once
-- embedded in a narrower Dashboard panel, just for a grid instead of table
-- columns. Computed from gridPanel's actual current width instead, so a
-- slot never gets placed past the panel's right edge regardless of window
-- size -- recomputed every refresh, which already happens on every
-- gridPanel resize (see its OnSizeChanged in BuildFrame).
local function GridCols()
    if not gridPanel then return 1 end
    return max(1, floor((gridPanel:GetWidth() - 24) / (GRID_SLOT + GRID_GAP)))
end

local function RefreshGrid()
    if not gridPanel or not gridPanel.pageText then return end

    local cols = GridCols()
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
            if col >= cols then
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
    -- tablePanel/gridPanel are both required below regardless of viewMode --
    -- guarded separately from `frame` because RefreshRowCount's OnSizeChanged
    -- handler can fire mid-BuildFrame (as soon as tablePanel gets its first
    -- layout pass), before gridPanel has been created yet.
    if not frame or not tablePanel or not gridPanel then return end
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
end

-- "Shown" means the Dashboard itself is open on the Vault tab, not just that
-- this frame exists -- it's always built once EmbedInto runs, but only
-- visible while its embedded group is the active tab (see UI.Refresh in
-- UncappedDashboard_UI.lua).
function UI.IsShown()
    local Dashboard = _G.UncappedDashboard
    return frame ~= nil and Dashboard ~= nil and Dashboard.UI and Dashboard.UI.IsShown
        and Dashboard.UI.IsShown() and Dashboard.state and Dashboard.state.tab == "vault"
end

function UI.Close()
    local Dashboard = _G.UncappedDashboard
    if Dashboard and Dashboard.UI and Dashboard.UI.IsShown and Dashboard.UI.IsShown() then
        Dashboard.Toggle()
    end
end

-- Lives inside the Dashboard's content panel (see EmbedInto below) -- no own
-- backdrop/title/close/drag/resize, since the Dashboard's master window
-- already provides all of that chrome. categoryPanel keeps its original
-- fixed width; tablePanel/gridPanel fill the remainder all the way to the
-- frame's right edge (no more right-hand detail/info column) -- that already
-- stretches with whatever size the Dashboard window currently has, the same
-- way it stretched with this frame's own resizing back when Vault owned its
-- own window.
local function BuildFrame(parent)
    if frame then return end
    Core.GetDB()

    frame = CreateFrame("Frame", "UncappedVaultFrame", parent or UIParent)
    frame:SetPoint("TOPLEFT"); frame:SetPoint("BOTTOMRIGHT")
    frame:EnableMouse(true)
    frame:SetScript("OnReceiveDrag", Core.DepositCursor)
    frame:SetScript("OnMouseUp", function(_, b) if b == "LeftButton" and CursorHasItem() then Core.DepositCursor() end end)

    -- Matches categoryPanel's own width and left edge exactly (both anchored
    -- off frame's TOPLEFT at PAD), instead of a wider box offset from it.
    searchBox = CreateFrame("EditBox", "UncappedVaultSearch", frame, "InputBoxTemplate")
    searchBox:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -54)
    searchBox:SetWidth(LEFT_W); searchBox:SetHeight(26)
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

    -- 5px right of the item frame (tablePanel/gridPanel's own left edge,
    -- which sits at PAD + LEFT_W + 12 from frame's left) -- computed here
    -- rather than anchored off tablePanel directly since tablePanel isn't
    -- built yet at this point.
    local ITEM_FRAME_LEFT = PAD + LEFT_W + 12
    qualityDD = Dropdown(frame, "UncappedVaultQuality", 140, {
        { value = -1, text = "All Qualities" },
        { value = 5, text = "Legendary" },
        { value = 4, text = "Epic" },
        { value = 3, text = "Rare" },
        { value = 2, text = "Uncommon" },
        { value = 1, text = "Common" },
        { value = 0, text = "Poor" },
    }, function() return Core.state.quality end, Core.SetQuality)
    qualityDD:SetPoint("TOPLEFT", frame, "TOPLEFT", ITEM_FRAME_LEFT + 5, -49)

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

    categoryPanel = Panel(frame)
    categoryPanel:SetPoint("TOPLEFT", PAD, -TOP_H)
    categoryPanel:SetPoint("BOTTOMLEFT", PAD, FOOTER_H + 12)
    categoryPanel:SetWidth(LEFT_W)
    Text(categoryPanel, "GameFontNormal", "TOPLEFT", categoryPanel, "TOPLEFT", 19, -14, "All Categories"):SetTextColor(RGB(GOLD))
    local viewLabel = Text(categoryPanel, "GameFontNormalSmall", "TOPLEFT", categoryPanel, "TOPLEFT", 14, -38, "View")
    viewLabel:SetTextColor(RGB(GOLD))
    local listView = Button(categoryPanel, "List", 70, 24)
    listView:SetPoint("TOPLEFT", categoryPanel, "TOPLEFT", 14, -52)
    local gridView = Button(categoryPanel, "Grid", 70, 24)
    gridView:SetPoint("LEFT", listView, "RIGHT", 8, 0)
    viewButtons.list, viewButtons.grid = listView, gridView
    listView:SetScript("OnClick", function() Core.SetViewMode("list") end)
    gridView:SetScript("OnClick", function() Core.SetViewMode("grid") end)

    -- Category/subcategory list -- windowed the same way the item table's
    -- rows are (see RefreshCategories), so it scrolls instead of running
    -- past categoryPanel's bottom edge when there are more entries than fit.
    categoryScroll = CreateFrame("ScrollFrame", "UncappedVaultCategoryScroll", categoryPanel, "FauxScrollFrameTemplate")
    categoryScroll:SetPoint("TOPLEFT", categoryPanel, "TOPLEFT", 0, -CATEGORY_START_Y)
    -- -25, not -20: the extra 5px shifts the auto-created scrollbar (which
    -- anchors relative to categoryScroll's own right edge) 5px further left.
    categoryScroll:SetPoint("BOTTOMRIGHT", categoryPanel, "BOTTOMRIGHT", -25, 8)
    categoryScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, CATEGORY_ROW_H, RefreshCategories)
    end)
    categoryScroll:EnableMouseWheel(true)
    categoryScroll:SetScript("OnMouseWheel", function(self, delta)
        local sb = _G["UncappedVaultCategoryScrollScrollBar"]
        if sb then sb:SetValue(sb:GetValue() - delta * CATEGORY_ROW_H) end
    end)
    categoryScroll:SetScript("OnSizeChanged", RefreshCategories)

    -- The right-hand detail/info panel is gone -- table/grid now stretch all
    -- the way to the frame's own right edge instead of stopping short to
    -- leave room for it. "View Transaction Log" (the info panel's only
    -- button) is temporarily parked bottom-center of the frame for now,
    -- since it has nowhere else to live yet.
    local tx = Button(frame, "View Transaction Log", 214, 28)
    tx:SetPoint("BOTTOM", frame, "BOTTOM", 0, 20)

    tablePanel = Panel(frame)
    tablePanel:SetPoint("TOPLEFT", categoryPanel, "TOPRIGHT", 12, 0)
    tablePanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, FOOTER_H + 12)
    for _, col in ipairs(COLUMNS) do
        SortHeader(tablePanel, col.label, col.sortKey)
    end
    for i = 1, MAX_ROWS do rows[i] = CreateRow(tablePanel, i) end

    -- pageText/prev/next must exist BEFORE RefreshRowCount's first call
    -- below (it calls RefreshRows, which needs tablePanel.pageText) --
    -- OnSizeChanged can also fire as soon as tablePanel gets its first
    -- layout pass, possibly before BuildFrame reaches this point otherwise.
    local prev = Button(tablePanel, "<", 36, 28)
    prev:SetPoint("BOTTOM", tablePanel, "BOTTOM", -70, 12)
    prev:SetScript("OnClick", function() Core.SetPage(Core.state.page - 1) end)
    tablePanel.pageText = Text(tablePanel, "GameFontHighlightSmall", "BOTTOM", tablePanel, "BOTTOM", 0, 19, "Page 1 of 1")
    local next = Button(tablePanel, ">", 36, 28)
    next:SetPoint("BOTTOM", tablePanel, "BOTTOM", 70, 12)
    next:SetScript("OnClick", function() Core.SetPage(Core.state.page + 1) end)

    RefreshRowCount()
    RelayoutColumns()
    tablePanel:SetScript("OnSizeChanged", function()
        RefreshRowCount()
        RelayoutColumns()
    end)

    gridPanel = Panel(frame)
    gridPanel:SetPoint("TOPLEFT", categoryPanel, "TOPRIGHT", 12, 0)
    gridPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, FOOTER_H + 12)
    gridPanel.pageText = Text(gridPanel, "GameFontHighlightSmall", "BOTTOM", gridPanel, "BOTTOM", 0, 19, "Page 1 of 1")
    local gridPrev = Button(gridPanel, "<", 36, 28)
    gridPrev:SetPoint("BOTTOM", gridPanel, "BOTTOM", -70, 12)
    gridPrev:SetScript("OnClick", function() Core.SetPage(Core.state.page - 1) end)
    local gridNext = Button(gridPanel, ">", 36, 28)
    gridNext:SetPoint("BOTTOM", gridPanel, "BOTTOM", 70, 12)
    gridNext:SetScript("OnClick", function() Core.SetPage(Core.state.page + 1) end)
    gridPanel:SetScript("OnSizeChanged", RefreshGrid)
    gridPanel:Hide()

    footerBar = CreateFrame("Frame", nil, frame)
    footerBar.label = Text(frame, "GameFontHighlightSmall", "LEFT", frame, "BOTTOMLEFT", PAD + 6, 44, "")

    local depositBtn = Button(frame, "Deposit Items", 180, 32)
    depositBtn:SetPoint("BOTTOMRIGHT", -PAD - 8, 20)
    depositBtn:SetBackdropColor(RED[1], RED[2], RED[3], 0.95)
    depositBtn.text:SetTextColor(RGB(GOLD))
    depositBtn:SetScript("OnClick", function()
        Core.SetMode("deposit")
        if CursorHasItem() then Core.DepositCursor() end
    end)

    -- Gold/Arena Points moved to the Dashboard's own nav panel (see
    -- DashboardButtons.lua) so they stay visible on every tab, not just
    -- while Vault is active.

    frame:Hide()
    UI.Refresh()
end

-- ===========================================================================
-- Dashboard embedding
-- ===========================================================================
-- The Dashboard hosts this panel directly inside its own window instead of
-- Vault owning a window of its own -- see UncappedDashboard_UI.lua, which
-- calls EmbedInto once (to build the frame into its content group) and
-- Activate every time the Vault tab is selected. Opening/closing/toggling
-- now means switching the Dashboard to the Vault tab (and showing/hiding the
-- Dashboard itself) rather than showing/hiding this frame directly -- it's
-- what OpenAllBags/ToggleAllBags/CloseAllBags (see InstallBagSync in
-- UncappedVault.lua) and the /vault slash command both end up calling.
function UI.EmbedInto(parent)
    BuildFrame(parent)
    frame:Show()
    return frame
end

function UI.Activate()
    if not frame then return end
    Core.Rebuild()
    UI.Refresh()
end

-- Content-panel width (not window width) Vault needs. Was 932 (920 original
-- standalone minimum + 12px embedded-group padding) when a right-hand
-- detail/info column existed; now that it's gone, drop the width it used to
-- reserve (260px column + 12px gap = 272px): 932 - 272 = 660.
function UI.GetMinWidth()
    return 660
end

-- Full window height Vault needs: its original standalone minimum height
-- (620) plus the Dashboard window's own chrome (title/banner + margins,
-- ~72px) that a standalone window didn't have to account for.
function UI.GetMinHeight()
    return 692
end

function UI.Open()
    local Dashboard = _G.UncappedDashboard
    if not Dashboard then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff8040[Vault]|r now lives inside the Dashboard -- load UncappedDashboard to use it.")
        return
    end
    Dashboard.SetTab("vault")
    if not (Dashboard.UI and Dashboard.UI.IsShown and Dashboard.UI.IsShown()) then
        Dashboard.Toggle()
    end
end

function UI.Toggle()
    local Dashboard = _G.UncappedDashboard
    if Dashboard and Dashboard.UI and Dashboard.UI.IsShown and Dashboard.UI.IsShown()
            and Dashboard.state and Dashboard.state.tab == "vault" then
        Dashboard.Toggle()
    else
        UI.Open()
    end
end

local init = CreateFrame("Frame")
init:RegisterEvent("PLAYER_LOGIN")
init:SetScript("OnEvent", function()
    Core.Rebuild()
end)
