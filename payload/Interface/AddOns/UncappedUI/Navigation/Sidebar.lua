-- UncappedUI Navigation.Sidebar -- themed category/list nav with a
-- FauxScrollFrame (Controls\ScrollFrame.lua), so lists longer than the
-- visible area scroll instead of overflowing the panel. Generalizes the
-- category sidebar pattern (parent rows + indented child rows,
-- selected-state highlight bar) used by things like the vault UI.

local UncappedUI = _G.UncappedUI
if not UncappedUI then return end

local unpack = unpack

local function ApplyRowSkin(row, theme)
    local c = theme.colors
    if row.active then
        row.selected:SetTexture(c.gold[1], c.gold[2], c.gold[3], 0.18)
        row.selected:Show()
        row.label:SetTextColor(unpack(c.gold))
    else
        row.selected:Hide()
        row.label:SetTextColor(unpack(c.text))
    end
    row.count:SetTextColor(unpack(c.textMuted))
end

-- opts: rowHeight (default 24), visibleRows (default 8 -- tune this to
-- the panel's actual height; rowHeight * visibleRows should roughly
-- match the space given to the returned list), startY (default 0),
-- indentPerLevel (default 16)
function UncappedUI.CreateSidebarList(parent, opts)
    opts = opts or {}
    local rowHeight = opts.rowHeight or 24
    local visibleRows = opts.visibleRows or 8
    local startY = opts.startY or 0
    local indentPerLevel = opts.indentPerLevel or 16

    local list = CreateFrame("Frame", nil, parent)
    list.entries = {}
    list.rows = {}

    local function RenderVisible()
        local offset = FauxScrollFrame_GetOffset(list.scroll) or 0
        local theme = UncappedUI.GetActiveTheme()
        for i = 1, visibleRows do
            local row = list.rows[i]
            local entry = list.entries[i + offset]
            row.entry = entry
            if entry then
                row.active = entry.active and true or false
                row.label:SetText(entry.label or "")
                row.label:ClearAllPoints()
                row.label:SetPoint("LEFT", row, "LEFT", 12 + (entry.level or 0) * indentPerLevel, 0)
                row.count:SetText(entry.count ~= nil and tostring(entry.count) or "")
                ApplyRowSkin(row, theme)
                row:Show()
            else
                row:Hide()
            end
        end
    end

    list.scroll = UncappedUI.CreateFauxScrollFrame(list, rowHeight, visibleRows, RenderVisible)
    list.scroll:SetAllPoints(list)

    for i = 1, visibleRows do
        local row = CreateFrame("Button", nil, list)
        row:SetHeight(rowHeight)
        row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -(startY + (i - 1) * rowHeight))
        row:SetPoint("RIGHT", list, "RIGHT", -20, 0) -- leave room for the scrollbar

        row.selected = row:CreateTexture(nil, "BACKGROUND")
        row.selected:SetPoint("TOPLEFT", 2, -2)
        row.selected:SetPoint("BOTTOMRIGHT", -2, 2)
        row.selected:Hide()

        row.label = UncappedUI.CreateText(row, "highlightSmall", "LEFT", row, "LEFT", 12, 0, "")
        row.count = UncappedUI.CreateText(row, "highlightSmall", "RIGHT", row, "RIGHT", -10, 0, "")

        row.line = row:CreateTexture(nil, "BACKGROUND")
        row.line:SetTexture(1, 1, 1, 0.06)
        row.line:SetPoint("BOTTOMLEFT", 4, 0)
        row.line:SetPoint("BOTTOMRIGHT", -4, 0)
        row.line:SetHeight(1)

        row:SetScript("OnClick", function(self)
            if self.entry and self.entry.onClick then self.entry.onClick(self.entry) end
        end)

        UncappedUI.Register(row, ApplyRowSkin)
        list.rows[i] = row
    end

    -- entries: { { key, label, count, level, active, onClick(entry) }, ... }
    function list:SetEntries(entries)
        list.entries = entries or {}
        list.scroll:Update(#list.entries)
        RenderVisible()
    end

    return list
end
