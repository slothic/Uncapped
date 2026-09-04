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
-- Strip along the top of the grid panel holding its sort button. Grid view has
-- no clickable column headers, so without this there is no way to reach the
-- sort from it at all (report #267). Reserved out of the page height in
-- RefreshGridRowCount and out of the first row's y in RefreshGrid -- both, or
-- the bottom row runs under the pager.
local GRID_SORT_H = 32
-- Clears the List/Grid buttons (bottom edge at -76), the "my class only" check
-- button below them (-80 to -104), and the "Sort by stat" label + dropdown below
-- that (-110 to -154), with a small gap.
--
-- Raised from 108 for the stat dropdown (report #308). The category list is a
-- windowed scroller -- RefreshCategories derives its visible row count from
-- categoryScroll's actual height -- so spending 52px here costs two visible rows
-- of a list that already had to scroll, not any category's reachability.
local CATEGORY_START_Y = 160
local CATEGORY_ROW_H = 24

local frame, searchBox, categoryPanel, categoryScroll, tablePanel, gridPanel, footerBar
local rows, catRows, gridSlots, gridHeaders = {}, {}, {}, {}

--[[ ★★ [DE-05] TYPING DOES NOT REFILTER ON THE SPOT.

     Core.SetQuery -> Notify -> Core.Rebuild + UI.Refresh is the widest thing this
     addon does. On a documented 3,901-row vault it was a walk of every row, a full
     table.sort, a second per-bucket sort in the grid layout, one fresh table per
     item, and a repaint of every widget -- PER CHARACTER TYPED. That is the
     per-frame stall shape behind the realm's FPS reports, fired eight to fifteen
     times per search.

     Core.Rebuild is far cheaper on a narrowing query now (see the DE-05 note
     there), but "cheaper" is not "free" and the REPAINT is not narrowed at all, so
     a burst of keystrokes still gets coalesced into one pass here. Same mechanism,
     same reasoning and deliberately the same feel as the Forge's search box
     (SEARCH_DEBOUNCE in UncappedForge.lua).

     ⚠ 0.12s, not the 0.30s the Soulforge whitelist box uses. That one pays for a
       round trip and a full-table scan ON THE SERVER, so it is worth waiting
       longer to be sure. This one is pure local CPU: a longer wait would buy
       nothing except a list that visibly lags the caret. ]]
local SEARCH_DEBOUNCE = 0.12
local searchWait = nil      -- seconds left on the debounce, nil when idle
local searchPending = nil   -- the text the debounce will hand to Core.SetQuery
local searchTimer = CreateFrame("Frame")
searchTimer:Hide()

-- Hands the settled text over now. Called by the ticker, and directly whenever the
-- box is going away: if the frame hid with a query still queued, Core.state.query
-- and the text sitting in the box would disagree until the next keystroke, and
-- reopening the Vault would show a list contradicting its own search box.
local function FlushSearch()
    if searchPending == nil then return end
    local text = searchPending
    searchWait, searchPending = nil, nil
    searchTimer:Hide()
    Core.SetQuery(text)
end

searchTimer:SetScript("OnUpdate", function(self, elapsed)
    if not searchWait then self:Hide(); return end
    searchWait = searchWait - (elapsed or arg1 or 0)
    if searchWait > 0 then return end
    FlushSearch()
end)
local viewButtons = {}
local qualityDD, slotDD, statDD, classOnlyCheck, gridSortBtn

--[[
    ★★ THESE WERE PRIVATE FORKS OF UncappedUIKit, deleted 2026-08-16 after a UI
       audit found them byte-identical to the kit they were extracted from.

    This file carried its own GOLD/BLUE/GREEN/PURPLE/RED, Panel, Text, Button,
    SetButtonActive and Dropdown. The colour literals matched DefaultTheme
    exactly; Button's backdrop, insets, highlight and ADD blend matched
    Controls/Button.lua exactly; SetButtonActive's gold matched exactly. It was
    the reference implementation the kit was extracted FROM, left behind
    un-deleted -- so the Vault alone never re-skinned on /uitheme, and it was the
    one window that missed every later kit fix.

    ⚠ The Vault's Dropdown was NOT a fork but a SUPERSET (function-valued choices
      and a re-derived label). It was promoted INTO Controls/Dropdown.lua rather
      than discarded -- aliasing without promoting first would have been a
      silent downgrade for the slot filter, whose choices change on every
      deposit.

    ⚠ Kit Panel tints 1,1,1,0.95 where this file used 0,0,0,0.82. Panel() below
      re-applies the darker tint so the Vault looks exactly as it did today; drop
      that line when the whole suite moves onto the theme's panel colour.
]]
local UIKit = _G.UncappedUIKit
-- Same guard idiom as DashboardButtons.lua:12. Not a new dependency: this file
-- only ever draws a Dashboard TAB, and DashboardButtons already returns early
-- without the kit, so there is no Dashboard to host the tab in that case. Bailing
-- here turns what would be a nil-index error into a clean no-op.
if not UIKit then return end

-- ★ THE PALETTE IS LIVE, AND THE TABLES ARE REUSED IN PLACE.
--
--   GOLD used to be `UIKit.GetActiveTheme().colors.gold` evaluated ONCE at file
--   load. Running /uitheme afterwards left every gold accent in this tab -- the
--   category headings, the selected-row highlight, the Deposit button's label --
--   frozen on whichever theme happened to be active at login, while text built
--   through UIKit.CreateText re-skinned around them. The other four were flat
--   literals that merely re-typed DefaultTheme's values and would drift silently
--   the moment anyone tuned them.
--
--   ⚠ Refresh MUTATES these tables rather than reassigning them, because they
--     are captured by closures and passed straight to RGB() all over this file.
--     Rebinding the locals would leave every existing reference pointing at the
--     old table.
local GOLD, BLUE, GREEN, PURPLE, RED = {}, {}, {}, {}, {}

local function setColor(dst, src, fallback)
    local c = src or fallback
    dst[1], dst[2], dst[3] = c[1], c[2], c[3]
end

local function RefreshPalette()
    local c = (UIKit.GetActiveTheme() or {}).colors or {}
    setColor(GOLD,   c.gold,   { 1.00, 0.82, 0.22 })
    setColor(BLUE,   c.blue,   { 0.30, 0.62, 1.00 })
    setColor(GREEN,  c.green,  { 0.32, 1.00, 0.20 })
    setColor(PURPLE, c.purple, { 0.68, 0.28, 1.00 })
    setColor(RED,    c.red,    { 0.72, 0.10, 0.06 })
end

RefreshPalette()
if UIKit.OnThemeChanged then UIKit.OnThemeChanged(RefreshPalette) end

local function RGB(c) return c[1], c[2], c[3] end

local function Panel(parent)
    local f = UIKit.CreatePanel(parent)
    f:SetBackdropColor(0, 0, 0, 0.82)   -- see the note above
    return f
end

-- The kit takes a style KEY where this file passed a raw font template. Mapped
-- rather than rewriting ~19 call sites. ⚠ Hoisted out of Text() deliberately:
-- this is called once per row per redraw over a list that can be thousands of
-- items, and rebuilding a table per call is exactly the kind of cost that only
-- shows up once someone has a big vault.
local FONT_STYLE = {
    GameFontNormal = "normal", GameFontNormalSmall = "normalSmall",
    GameFontHighlight = "highlight", GameFontHighlightSmall = "highlightSmall",
    GameFontDisableSmall = "disableSmall", GameFontNormalLarge = "title",
}

local function Text(parent, template, point, rel, relPoint, x, y, text)
    return UIKit.CreateText(parent, FONT_STYLE[template] or "highlightSmall",
        point, rel or parent, relPoint or point, x or 0, y or 0, text)
end

local Button = UIKit.CreateButton
local SetButtonActive = UIKit.SetButtonActive

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

-- Promoted into UncappedUI/Controls/Dropdown.lua on 2026-08-16 -- this file's
-- version was a superset of the kit's, so the kit grew rather than this
-- shrinking. Same signature, same behaviour, one copy.
local Dropdown = UIKit.CreateDropdown

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

-- What each column's ordering actually does, shown on hover. Written out
-- because the useful part of report #267 is the TIEBREAK, and a tiebreak is
-- invisible until someone tells you it is there.
local SORT_TIPS = {
    recent   = "Most recently banked first.",
    name     = "A to Z.",
    level    = "Highest item level first, then rarity.",
    rarity   = "Legendary first, then highest item level.",
    quantity = "Largest stack first.",
    slot     = "Paper-doll order, then highest item level.",
}

-- Long-form names for the grid's single sort button, which has room to say
-- "Item Level" where a table column only had room for "Lvl".
local SORT_LABELS = {
    recent = "Recent", name = "Name", level = "Item Level",
    rarity = "Rarity", quantity = "Quantity", slot = "Slot / Type",
}
--[[ The cycle stays the six FIXED keys and deliberately does not grow with the
     stat sorts (report #308). A single button that cycles twenty-four orderings
     one click at a time is not a control, it is a punishment, and the stats have
     their own dropdown for that reason.

     Cycling out of a stat sort still works without a special case: a key that is
     not in this list leaves the search below at its default index of 1, so the
     next click lands on entry 2, "name". ]]
local SORT_CYCLE = { "recent", "name", "level", "rarity", "quantity", "slot" }

-- Both lookups fall through to the generated stat keys ("stat:strength", ...),
-- which have no static entry above and never will -- STAT_SORTS is the one place
-- a stat is described, so the label and the tip are derived from it.
local function SortLabel(key)
    if SORT_LABELS[key] then return SORT_LABELS[key] end
    local def = Core.STAT_BY_SORTKEY and Core.STAT_BY_SORTKEY[key]
    return (def and def.label) or key or "Recent"
end

local function SortTip(key)
    if SORT_TIPS[key] then return SORT_TIPS[key] end
    local def = Core.STAT_BY_SORTKEY and Core.STAT_BY_SORTKEY[key]
    if not def then return nil end
    return "Most " .. def.label .. " first, then item level. Items without it sort last."
end

local function SortHeader(parent, label, key)
    local b = Button(parent, label, 10, TABLE_HEAD_H - 6)
    b.key = key
    b.label = label
    b:SetScript("OnClick", function() Core.SetSort(key) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Sort by " .. (self.label or ""))
        local tip = SortTip(key)
        if tip then GameTooltip:AddLine(tip, 1, 1, 1) end
        GameTooltip:AddLine("Click again to reverse.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    headers[key] = b
    return b
end

-- Which column is sorted, and which way. Nothing marked it before, so the only
-- way to find out was to read the list and infer it -- and inferring a sort off
-- a page of mixed loot is exactly the "bit all over" feeling report #267
-- describes. The active header goes gold (the same treatment the List/Grid and
-- category buttons use) and carries the direction caret.
local function RefreshSortHeaders()
    local active = Core.state.sort
    local caret = Core.state.sortAsc and " |cff808080^|r" or " |cff808080v|r"
    for key, b in pairs(headers) do
        local on = (key == active)
        SetButtonActive(b, on)
        b.text:SetText((b.label or "") .. (on and caret or ""))
    end
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
        -- [#809] The EXACT count, because the grid label is now abbreviated. Without
        -- this line the true stack size is unreachable anywhere in the UI, which
        -- would trade an overflow bug for a missing-information one.
        GameTooltip:AddLine("Stored: " .. Core.Comma(self.item.c or 0), 1, 0.82, 0.22)
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
            row.count:SetText(Core.Abbrev(cat.count))   -- [#809] sidebar is narrow too
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
    -- Guarded like every other Refresh* function here: RefreshGridRowCount's
    -- initial call in BuildFrame can cascade into this (via SetGridMetrics ->
    -- Notify("pagesize") -> UI.Refresh) before footerBar is built further down
    -- in that same function.
    if not footerBar then return end
    local text = "Vault Space Used:  |cffffd100" .. Core.Comma(Core.spaceUsed) .. "|r"
    -- Says out loud that the window is showing less than it holds. A storage
    -- UI that quietly hides rows gets reported as missing items; one that
    -- prints the number it hid does not.
    local hidden = Core.hiddenByClass or 0
    if Core.state.classOnly and hidden > 0 then
        text = text .. "        |cffb8b8b8" .. Core.Comma(hidden) .. " hidden by \"only gear I can use\"|r"
    end
    footerBar.label:SetText(text)
end

local ARMOR_TYPE_NAME = { [1] = "Cloth", [2] = "Leather", [3] = "Mail", [4] = "Plate" }

-- The "Slot / Type" column used to print the item's top-level category, so
-- every one of a hundred armour rows said "Armor" -- a column that only ever
-- repeats the sidebar selection you are already looking at. It says "Plate
-- Legs" / "Two-Hand" / "Trinket" now, and falls back to the category name
-- only for things that go in no slot at all (ore, potions, glyphs).
local function SlotText(it)
    local eq = Core.EquipSlotFor(it)
    if not eq then return Core.SLOT_LABELS[Core.SlotFor(it)] or "Item" end

    local label = Core.EQUIP_LABELS[eq] or eq
    -- Cloaks are armour subclass CLOTH, so "Cloth Back" would be true and
    -- useless -- nobody picks a cloak by armour type.
    if (it.cls == 4) and eq ~= "back" and ARMOR_TYPE_NAME[it.sub or 0] then
        label = ARMOR_TYPE_NAME[it.sub] .. " " .. label
    end
    return label
end

-- ★ THE VAULT HAD NO EMPTY STATE AT ALL. Both the list and the grid simply hid
--   every row when there was nothing to show, leaving a blank panel under a
--   footer that always reads "Page 1 of 1" (PageCount is max(1, ...)). Four
--   completely different situations produced the identical picture: the vault is
--   genuinely empty, the search matched nothing, the snapshot has not arrived
--   yet, or the server never answered and the retry loop gave up thirty seconds
--   ago. The player could not tell "you own nothing" from "this is broken".
--
--   Every sibling panel in the suite already does this -- Forge, Soul Forge and
--   Transmog all carry an emptyText widget. This one was the outlier.
local function UpdateEmptyState(panel, count)
    if not panel then return end
    if not panel.emptyText then
        panel.emptyText = Text(panel, "GameFontNormal",
            "CENTER", panel, "CENTER", 0, 10, "")
        panel.emptyText:SetJustifyH("CENTER")
    end
    local fs = panel.emptyText
    if (count or 0) > 0 then
        fs:Hide()
        return
    end

    local sync = Core.syncState
    local searching = (Core.state.query or "") ~= ""
        or (Core.state.category or "all") ~= "all"

    if sync == "waiting" then
        fs:SetText("Loading your Vault...")
    elseif sync == "failed" then
        fs:SetText("The server hasn't answered -- use the refresh button to try again.")
    elseif searching then
        fs:SetText("Nothing here matches what you're looking for.")
    else
        fs:SetText("Your Vault is empty.")
    end
    fs:Show()
end

local function RefreshRows()
    if not tablePanel or not tablePanel.pageText then return end
    local pageItems = Core.PageItems()
    UpdateEmptyState(tablePanel, #pageItems)
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
            row.slot:SetText(SlotText(it))
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

local RefreshGrid

-- Same overflow bug RefreshRowCount fixes for the list view, but for rows of
-- icons instead of rows of text.
--
-- This used to hand Core a single number: rows * GridCols(), i.e. how many
-- CELLS fit. Core then used it to slice gridLayout, which counts ENTRIES --
-- and category headers are entries that take a full-width line rather than a
-- cell, so every header on a page pushed the real layout further past the
-- bottom of the panel. Core walks the entries in pixels now, so all it needs
-- from here is the two measurements only the UI knows: how many columns wide,
-- and how many pixels tall a page may be. GRID_FOOT_H reserves the space the
-- page prev/next/text row below the icons needs.
local GRID_FOOT_H = 54
local function RefreshGridRowCount()
    if not gridPanel then return end
    Core.SetGridMetrics(GridCols(), gridPanel:GetHeight() - 12 - GRID_SORT_H - GRID_FOOT_H)
    RefreshGrid()
end

-- Label always states the current sort rather than implying it -- same
-- one-button idiom (and same wording) as the Quest Ledger's sort control.
local function RefreshGridSort()
    if not gridSortBtn then return end
    local key = Core.state.sort or "recent"
    gridSortBtn.text:SetText("Sort: " .. SortLabel(key)
        .. (Core.state.sortAsc and " |cff808080^|r" or " |cff808080v|r"))
end

function RefreshGrid()
    if not gridPanel or not gridPanel.pageText then return end

    local cols = GridCols()
    local entries = Core.PageGridEntries()
    UpdateEmptyState(gridPanel, #entries)
    local headerIndex, slotIndex = 0, 0
    -- Starts below the sort strip, not at the panel's own top edge.
    local x, y = 12, -12 - GRID_SORT_H
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
            -- [#809] Abbreviated: the cell is 38px and this label has no width, so
            -- a six-digit stack overruns the item next to it. The exact number is
            -- in the tooltip -- see the count line added there.
            if (it.c or 0) > 1 then b.count:SetText(Core.Abbrev(it.c)) else b.count:SetText("") end
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
    -- Read back through the dropdown's own live choice list rather than a
    -- static label table: the entries carry counts, and Core.Rebuild can reset
    -- the selection to "all" underneath us when the chosen slot empties out.
    UIDropDownMenu_SetSelectedValue(slotDD, Core.state.equipSlot)
    UIDropDownMenu_SetText(slotDD, slotDD.CurrentText() or "All Slots")
    --[[ The stat dropdown is the ONLY thing marking a stat sort as active: no
         table column owns one, so RefreshSortHeaders below correctly lights
         nothing up. Carrying the same direction caret the headers and the grid
         button carry keeps that readable rather than half-marked.

         CurrentText() is nil whenever the active sort is not a stat, which is
         what turns this back into its idle label the moment a column header is
         clicked. ]]
    if statDD then
        UIDropDownMenu_SetSelectedValue(statDD, Core.state.sort)
        UIDropDownMenu_SetText(statDD, statDD.CurrentText() or "Sort by Stat")
    end
    if classOnlyCheck then classOnlyCheck:SetChecked(Core.state.classOnly and true or false) end
    RefreshViewButtons()
    RefreshSortHeaders()
    RefreshGridSort()
    RefreshCategories()
    if Core.state.viewMode == "grid" then
        tablePanel:Hide()
        gridPanel:Show()
        -- RefreshGridRowCount, not RefreshGrid directly: switching TO grid view
        -- only changes visibility, not gridPanel's size, so OnSizeChanged never
        -- fires here -- without recomputing here too, the grid metrics could
        -- still be whatever they were left at from BuildFrame (possibly before
        -- gridPanel had a real height yet), and never correct themselves.
        RefreshGridRowCount()
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
    -- Stock InputBoxTemplate does NOT carry autoFocus="false" (checked against the
    -- client's own UIPanelTemplates.xml), and an EditBox defaults to autofocus, so
    -- between CreateFrame above and this line the box exists, is shown, and is
    -- entitled to take the keyboard. The ClearFocus is not redundant with the
    -- SetAutoFocus: turning autofocus off does not hand back focus already taken.
    searchBox:SetAutoFocus(false)
    searchBox:ClearFocus()
    local ph = Text(searchBox, "GameFontDisableSmall", "LEFT", searchBox, "LEFT", 24, 1, "Search items...")
    local mag = searchBox:CreateTexture(nil, "OVERLAY")
    mag:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
    mag:SetWidth(16); mag:SetHeight(16); mag:SetPoint("LEFT", 6, 0)
    searchBox:SetScript("OnTextChanged", function(self)
        local text = self:GetText() or ""
        -- The placeholder stays IMMEDIATE. It costs one Show/Hide and it is the
        -- only thing on screen that has to track the caret exactly; debouncing it
        -- would make the box itself look laggy, which is the opposite of the point.
        -- Only the refilter waits.
        if text == "" then ph:Show() else ph:Hide() end
        searchPending = text
        searchWait = SEARCH_DEBOUNCE
        searchTimer:Show()
    end)
    -- Report #88: Escape left the box holding the keyboard, so "b" landed in the
    -- search field instead of opening bags.
    --
    -- ClearFocus runs BEFORE SetText, and the order is still the point. SetText
    -- fires OnTextChanged synchronously, and anything that raises in that handler
    -- aborts this one where it stands -- with SetText first, that abort would
    -- happen while the box still owns the keyboard, which is exactly the reported
    -- symptom. Dropping focus first makes releasing the keyboard independent of
    -- whatever the handler does.
    --
    -- ⚠ [DE-05] It used to be that handler that did the damage: it ran
    --   Core.SetQuery -> Rebuild -> UI.Refresh inline, and an empty query is the
    --   widest possible rebuild since nothing is filtered out. It only QUEUES now,
    --   so the exposure is much smaller -- but the ordering stays, because
    --   "smaller" is not "none" and this order costs nothing.
    searchBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        self:SetText("")
    end)

    -- An EditBox hidden while focused keeps the keyboard in 3.3.5a -- it goes on
    -- swallowing keypresses with nothing on screen to show where they are going.
    -- The Vault is a Dashboard tab, so it is hidden out from under a focused
    -- search box every time the player switches tab or closes the window.
    -- ⚠ [DE-05] FlushSearch as well as ClearFocus: a query queued on the debounce
    --   when the tab is switched away must still land, or Core.state.query and the
    --   text in the box disagree and reopening the Vault shows a list that
    --   contradicts its own search box.
    frame:SetScript("OnHide", function() searchBox:ClearFocus(); FlushSearch() end)

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

    --[[ Equipment slot.

         This replaces the old "Slot" dropdown, which listed Weapons / Armor /
         Consumables / ... -- the same ten entries the category sidebar already
         offers, with counts, one click away. Two controls over one axis is not
         redundancy, it is a contradiction: the sidebar and the dropdown ANDed
         together, so picking Armor in one and Weapons in the other produced an
         empty window with no indication of which control to undo.

         So the dropdown gets the axis the sidebar does not have -- the real
         equipment slot -- and the sidebar keeps armour type and weapon
         subclass. They compose instead of fighting: Plate + Chest. ]]
    slotDD = Dropdown(frame, "UncappedVaultSlot", 140, function()
        local out = { { value = "all", text = "All Slots" } }
        for _, row in ipairs(Core.equipSlots or {}) do
            out[#out + 1] = { value = row.key, text = row.label .. "  (" .. Core.Comma(row.count) .. ")" }
        end
        return out
    end, function() return Core.state.equipSlot end, Core.SetEquipSlot)
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

    --[[ "Only what I can use."

         Lives in the sidebar rather than the dropdown row because it is not a
         third filter axis competing with Quality and Slot -- it is a lens over
         the whole window, and it changes the sidebar's own counts. Putting it
         where those counts are is what makes that legible.

         Off by default: see Core.SetClassOnly. ]]
    classOnlyCheck = CreateFrame("CheckButton", "UncappedVaultClassOnly", categoryPanel, "UICheckButtonTemplate")
    classOnlyCheck:SetWidth(24); classOnlyCheck:SetHeight(24)
    classOnlyCheck:SetPoint("TOPLEFT", categoryPanel, "TOPLEFT", 12, -80)
    local classLabel = Text(categoryPanel, "GameFontHighlightSmall", "LEFT", classOnlyCheck, "RIGHT", 2, 1, "Only gear I can use")
    classLabel:SetJustifyH("LEFT")
    classLabel:SetWordWrap(false)
    classLabel:SetWidth(LEFT_W - 50)
    classOnlyCheck:SetScript("OnClick", function(self)
        Core.SetClassOnly(self:GetChecked() and true or false)
    end)
    local function ClassOnlyTooltip(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Only gear I can use", 1, 1, 1)
        local localized, class = UnitClass("player")
        GameTooltip:AddLine("Hides weapons, armor and glyphs a "
            .. (localized or "character") .. " can't equip or learn.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Armor type, weapon proficiency and glyph class only "
            .. "-- rings, necks, trinkets and cloaks always stay visible, and "
            .. "nothing outside your gear is ever hidden.", 0.6, 0.6, 0.6, true)
        GameTooltip:AddLine("Turn it off to gear an alt.", 0.6, 0.6, 0.6, true)
        if class and Core.state.classOnly and (Core.hiddenByClass or 0) > 0 then
            GameTooltip:AddLine(Core.Comma(Core.hiddenByClass) .. " item(s) hidden right now.", 1, 0.82, 0.22, true)
        end
        GameTooltip:Show()
    end
    classOnlyCheck:SetScript("OnEnter", ClassOnlyTooltip)
    classOnlyCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

    --[[ Sort by stat -- report #308.

         A DROPDOWN, NOT COLUMNS. There are eighteen stats; the table has five
         columns whose widths are fractions of a panel that is already tight, and
         the grid view has no columns at all. Eighteen more headers would be
         unreadable, and eighteen more stops on the grid's cycle button would make
         reaching the last one an eighteen-click job.

         ⚠ IN THE SIDEBAR AND NOT THE QUALITY/SLOT ROW, and that is a measurement
         rather than a preference. UI.GetMinWidth() promises this window works at
         660px; the dropdown row starts at PAD + LEFT_W + 12 + 5 = 273, leaving
         371px, and the two dropdowns already there consume 165 + 18 + 165 = 348
         of it. A third would hang off the right edge at every window size a
         player is likely to use, which is how the fixed column offsets this
         window used to have got themselves rewritten as fractions.

         The sidebar is also where it belongs on its own merits: it already holds
         View (List/Grid) and the "only gear I can use" lens, so it is the
         window-controls column rather than a second filter bar, and it has 240px
         to spend.

         There is deliberately no "off" entry. Clearing it is what the column
         headers and the grid's cycle button already do -- picking Rarity turns
         this back to "Sort by Stat" through UI.Refresh -- and an entry meaning
         "go back to whichever sort you had before" would be a third idiom for
         something two controls already express. ]]
    local statLabel = Text(categoryPanel, "GameFontNormalSmall", "TOPLEFT", categoryPanel, "TOPLEFT", 14, -110, "Sort by stat")
    statLabel:SetTextColor(RGB(GOLD))
    statDD = Dropdown(categoryPanel, "UncappedVaultStat", 170, function()
        local out = {}
        for _, def in ipairs(Core.STAT_SORTS or {}) do
            out[#out + 1] = { value = def.sortKey, text = def.label }
        end
        return out
    end, function() return Core.state.sort end, Core.SetSort)
    -- -2 rather than 14: UIDropDownMenuTemplate carries ~16px of left chrome
    -- before its text starts, so this is what lines the label up with the
    -- "View" buttons and the class-only check above it.
    statDD:SetPoint("TOPLEFT", categoryPanel, "TOPLEFT", -2, -122)

    -- The direction caret belongs on the CLOSED control, not on the entries in
    -- the open menu -- a caret against one row of a list reads as part of that
    -- row's name. Wrapping CurrentText rather than decorating the choices puts
    -- it in the one place both the click handler and UI.Refresh already read.
    local statCurrentText = statDD.CurrentText
    statDD.CurrentText = function()
        local text = statCurrentText()
        if not text then return nil end
        return text .. (Core.state.sortAsc and " |cff808080^|r" or " |cff808080v|r")
    end

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

    -- Manual refresh, 10px above the item panel -- gridPanel shares the exact
    -- same top edge (both anchored off categoryPanel's TOPRIGHT with no
    -- vertical offset), so anchoring to tablePanel alone holds in both views.
    -- Standard Blizzard button skin (UIPanelButtonTemplate) rather than a
    -- custom texture/backdrop -- always renders, no text, tooltip only.
    local refreshBtn = CreateFrame("Button", "UncappedVaultRefreshButton", frame, "UIPanelButtonTemplate")
    refreshBtn:SetWidth(24); refreshBtn:SetHeight(24)
    refreshBtn:SetPoint("BOTTOMRIGHT", tablePanel, "TOPRIGHT", 0, 10)
    refreshBtn:SetText("")
    refreshBtn:SetScript("OnClick", function()
        Core.ManualRefresh()
    end)
    refreshBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Refresh Vault")
        local secs = Core.SecondsUntilRecache and Core.SecondsUntilRecache()
        if not secs then
            GameTooltip:AddLine("Next auto-refresh: shortly.", 0.7, 0.7, 0.7)
        elseif secs >= 60 then
            GameTooltip:AddLine(format("Next auto-refresh in %dm %ds.", floor(secs / 60), secs % 60), 0.7, 0.7, 0.7)
        else
            GameTooltip:AddLine(format("Next auto-refresh in %ds.", secs), 0.7, 0.7, 0.7)
        end
        GameTooltip:Show()
    end)
    refreshBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

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

    -- [#1071] Same scrollwheel paging as the grid view. Safe here because this panel
    -- has no inner ScrollFrame to compete with -- its row count is derived from the
    -- panel's own height (RefreshRowCount) rather than being windowed, so the wheel
    -- has no other meaning to steal. The category list on the left keeps its own
    -- wheel handler and is unaffected; wheeling there still scrolls categories.
    tablePanel:EnableMouseWheel(true)
    tablePanel:SetScript("OnMouseWheel", function(_, delta)
        Core.SetPage(Core.state.page - delta)
    end)

    RefreshRowCount()
    RelayoutColumns()
    tablePanel:SetScript("OnSizeChanged", function()
        RefreshRowCount()
        RelayoutColumns()
    end)

    gridPanel = Panel(frame)
    gridPanel:SetPoint("TOPLEFT", categoryPanel, "TOPRIGHT", 12, 0)
    gridPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, FOOTER_H + 12)
    -- Grid's stand-in for the list view's clickable column headers. Left-click
    -- cycles the key, right-click reverses -- both routed through the same
    -- Core.SetSort the headers use, so the two views cannot drift apart and the
    -- choice is remembered either way (see GetDB).
    gridSortBtn = Button(gridPanel, "Sort: Recent", 168, 24)
    gridSortBtn:SetPoint("TOPLEFT", gridPanel, "TOPLEFT", 12, -8)
    gridSortBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    gridSortBtn:SetScript("OnClick", function(_, button)
        local key = Core.state.sort or "recent"
        if button == "RightButton" then
            Core.SetSort(key)       -- same key = flip direction
            return
        end
        local index = 1
        for i, k in ipairs(SORT_CYCLE) do
            if k == key then index = i end
        end
        Core.SetSort(SORT_CYCLE[(index % #SORT_CYCLE) + 1])
    end)
    gridSortBtn:SetScript("OnEnter", function(self)
        local key = Core.state.sort or "recent"
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:SetText("Sort")
        local tip = SortTip(key)
        if tip then GameTooltip:AddLine(tip, 1, 1, 1) end
        GameTooltip:AddLine("Left-click cycles the order.", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Right-click reverses it.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    gridSortBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    gridPanel.pageText = Text(gridPanel, "GameFontHighlightSmall", "BOTTOM", gridPanel, "BOTTOM", 0, 19, "Page 1 of 1")
    local gridPrev = Button(gridPanel, "<", 36, 28)
    gridPrev:SetPoint("BOTTOM", gridPanel, "BOTTOM", -70, 12)
    gridPrev:SetScript("OnClick", function() Core.SetPage(Core.state.page - 1) end)
    local gridNext = Button(gridPanel, ">", 36, 28)
    gridNext:SetPoint("BOTTOM", gridPanel, "BOTTOM", 70, 12)
    gridNext:SetScript("OnClick", function() Core.SetPage(Core.state.page + 1) end)

    -- [#1071] Scrollwheel pages the vault. Owner ruling 2026-08-27.
    --
    -- Routed through Core.SetPage exactly as the < and > buttons above are, so the
    -- wheel cannot reach a page the buttons could not: SetPage clamps to
    -- [1, PageCount()] itself, which is also why no bounds check belongs here.
    --
    -- Wheel DOWN is the next page. That matches every other paged list in the
    -- client (and a book, and this frame's own top-to-bottom fill order), so
    -- "further down the list" and "further down the wheel" agree.
    gridPanel:EnableMouseWheel(true)
    gridPanel:SetScript("OnMouseWheel", function(_, delta)
        Core.SetPage(Core.state.page - delta)
    end)

    RefreshGridRowCount()
    gridPanel:SetScript("OnSizeChanged", RefreshGridRowCount)
    gridPanel:Hide()

    footerBar = CreateFrame("Frame", nil, frame)
    footerBar.label = Text(frame, "GameFontHighlightSmall", "LEFT", frame, "BOTTOMLEFT", PAD + 6, 44, "")

    local depositBtn = Button(frame, "Deposit Items", 180, 32)
    depositBtn:SetPoint("BOTTOMRIGHT", -PAD - 8, 20)
    depositBtn:SetBackdropColor(RED[1], RED[2], RED[3], 0.95)
    depositBtn.text:SetTextColor(RGB(GOLD))
    -- Holding an item: deposit that one (the drag-and-drop path). Empty-handed:
    -- deposit everything in bags the keep rule does not protect. The button used
    -- to only switch mode when clicked with nothing held, which looked broken.
    depositBtn:SetScript("OnClick", function()
        Core.SetMode("deposit")
        if CursorHasItem() then
            Core.DepositCursor()
        else
            Core.DepositAllBags()
        end
    end)
    depositBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Deposit Items", 1, 1, 1)
        GameTooltip:AddLine("Click to send everything in your bags to the Vault.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Hearthstone, keystone, ammo and quest items you still need stay put.", 0.6, 0.6, 0.6, true)
        GameTooltip:AddLine("You can also drag an item here to deposit just that one.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    depositBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Gold/Anima moved to the Dashboard's own nav panel (see
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
-- Dashboard itself) rather than showing/hiding this frame directly.
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
