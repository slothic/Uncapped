-- UncappedUI Navigation.Tabs -- horizontal tab bar built from themed
-- UncappedUI buttons with single-select active state.

local UncappedUI = _G.UncappedUI
if not UncappedUI then return end

-- tabs: { { key, label, width }, ... }
-- onSelect(key) is called after the active state switches.
function UncappedUI.CreateTabs(parent, tabs, onSelect)
    local bar = CreateFrame("Frame", nil, parent)
    bar.buttons = {}

    local x = 0
    for i, tab in ipairs(tabs) do
        local b = UncappedUI.CreateButton(bar, tab.label, tab.width or 90, 24)
        b:SetPoint("LEFT", bar, "LEFT", x, 0)
        b.key = tab.key
        b:SetScript("OnClick", function()
            bar:SelectTab(tab.key)
            if onSelect then onSelect(tab.key) end
        end)
        bar.buttons[i] = b
        x = x + (tab.width or 90) + 6
    end

    function bar:SelectTab(key)
        for _, b in ipairs(bar.buttons) do
            UncappedUI.SetButtonActive(b, b.key == key)
        end
    end

    return bar
end
