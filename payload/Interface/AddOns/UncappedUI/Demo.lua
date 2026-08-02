-- UncappedUI Demo -- `/uidemo` opens a window exercising every control in
-- this library. Useful as a living usage example and as a quick way to
-- confirm `/uitheme <name>` re-skins everything live.

local UncappedUI = _G.UncappedUI
if not UncappedUI then return end

UncappedUIDemoDB = UncappedUIDemoDB or {}

local demoWindow

local function BuildDemo()
    if demoWindow then return end

    demoWindow = UncappedUI.CreateWindow({
        name = "UncappedUIDemoFrame",
        title = "UI Demo",
        width = 520, height = 380,
        minWidth = 420, minHeight = 300,
        maxWidth = 900, maxHeight = 700,
        resizable = true,
        db = UncappedUIDemoDB,
    })

    -- Left inner frame: themed bordered panel (Frames\Panel.lua) holding
    -- the sidebar nav. Every addon window built on this library should be
    -- composed of these panels rather than parenting controls straight to
    -- the window -- it's what gives the sunken/bordered look.
    local leftPanel = UncappedUI.CreatePanel(demoWindow)
    leftPanel:SetPoint("TOPLEFT", 16, -44)
    leftPanel:SetPoint("BOTTOMLEFT", 16, 50)
    leftPanel:SetWidth(170)

    local sidebar = UncappedUI.CreateSidebarList(leftPanel, { startY = 12, visibleRows = 10 })
    sidebar:SetPoint("TOPLEFT", 6, -6)
    sidebar:SetPoint("BOTTOMRIGHT", -6, 6)

    -- Deliberately more entries than the panel can show at once, so the
    -- vertical scrollbar (Controls\ScrollFrame.lua, wired in by
    -- Navigation\Sidebar.lua) actually has something to scroll.
    local selected = "one"
    local function RefreshSidebar()
        local function Select(entry)
            selected = entry.key
            RefreshSidebar()
        end
        local entries = {}
        for i = 1, 20 do
            local key = "entry" .. i
            entries[#entries + 1] = { key = key, label = "Entry " .. i, count = i, active = selected == key, onClick = Select }
            if i % 5 == 0 then
                local subKey = key .. "-sub"
                entries[#entries + 1] = { key = subKey, label = "Sub Entry", count = 1, level = 1, active = selected == subKey, onClick = Select }
            end
        end
        sidebar:SetEntries(entries)
    end
    RefreshSidebar()

    -- Right inner frame: a second themed panel holding the rest of the
    -- controls, so the demo shows panels nested/composed side by side the
    -- way a real addon window would use them.
    local rightPanel = UncappedUI.CreatePanel(demoWindow, { light = true })
    rightPanel:SetPoint("TOPLEFT", leftPanel, "TOPRIGHT", 10, 0)
    rightPanel:SetPoint("BOTTOMRIGHT", -16, 50)

    local search = UncappedUI.CreateSearchBox(rightPanel, 220, 26, "Search...")
    search:SetPoint("TOPLEFT", 14, -14)

    local btn = UncappedUI.CreateButton(rightPanel, "Themed Button", 140, 26)
    btn:SetPoint("TOPLEFT", search, "BOTTOMLEFT", 0, -12)
    btn:SetScript("OnClick", function() UncappedUI.SetButtonActive(btn, not btn.active) end)

    local cb = UncappedUI.CreateCheckbox(rightPanel, "Checkbox")
    cb:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 4, -16)

    local dd = UncappedUI.CreateDropdown(rightPanel, "UncappedUIDemoDropdown", 140, {
        { value = 1, text = "Choice A" },
        { value = 2, text = "Choice B" },
    }, function() return demoWindow.ddValue or 1 end, function(v) demoWindow.ddValue = v end)
    dd:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", -14, -20)

    local tabs = UncappedUI.CreateTabs(rightPanel, {
        { key = "a", label = "Tab A", width = 80 },
        { key = "b", label = "Tab B", width = 80 },
    })
    tabs:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 14, -30)
    tabs:SelectTab("a")
end

local function ToggleDemo()
    BuildDemo()
    if demoWindow:IsShown() then demoWindow:Hide() else demoWindow:Show() end
end

SLASH_UNCAPPEDUIDEMO1 = "/uidemo"
SlashCmdList["UNCAPPEDUIDEMO"] = ToggleDemo
