-- UncappedUIKit Navigation.Tabs -- horizontal tab bar built from themed
-- UncappedUIKit buttons with single-select active state.

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

-- tabs: { { key, label, width }, ... }
-- onSelect(key) is called after the active state switches.
function UncappedUIKit.CreateTabs(parent, tabs, onSelect)
    local bar = CreateFrame("Frame", nil, parent)
    bar.buttons = {}

    -- ⚠ The bar was created with NO SIZE. A zero-width, zero-height frame still
    --   resolves its own anchor, so the buttons did render -- but the bar had no
    --   clickable or measurable extent of its own, nothing could be anchored
    --   BELOW it, and anything asking how tall it was got 0. Sized properly from
    --   its contents at the end of this function.
    local x = 0
    for i, tab in ipairs(tabs) do
        local b = UncappedUIKit.CreateButton(bar, tab.label, tab.width or 90, 24)
        b:SetPoint("LEFT", bar, "LEFT", x, 0)
        b.key = tab.key
        b:SetScript("OnClick", function()
            bar:SelectTab(tab.key)
            if onSelect then onSelect(tab.key) end
        end)
        bar.buttons[i] = b
        x = x + (tab.width or 90) + 6
    end

    bar:SetWidth(math.max(1, x - 6))
    bar:SetHeight(24)

    function bar:SelectTab(key)
        for _, b in ipairs(bar.buttons) do
            UncappedUIKit.SetButtonActive(b, b.key == key)
        end
    end

    return bar
end
