-- #1417: native pools remain usable across forms. Read the typed replicated fields.
local frame = CreateFrame("Frame", "UncappedDruidResources", UIParent)
frame:SetSize(160, 46)
frame:SetPoint("TOPLEFT", PlayerFrame, "BOTTOMLEFT", 45, 0)
frame:Hide()

local pools = {
    { id=0, name="Mana", color={0.2, 0.45, 1} },
    { id=3, name="Energy", color={1, 0.85, 0.15} },
    { id=1, name="Rage", color={0.9, 0.15, 0.1} },
}

for i, pool in ipairs(pools) do
    local bar = CreateFrame("StatusBar", nil, frame)
    bar:SetSize(160, 14)
    bar:SetPoint("TOPLEFT", 0, -(i-1)*16)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(unpack(pool.color))
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(0, 0, 0, 0.7)
    local text = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("CENTER")
    text:SetTextColor(1, 1, 1)
    pool.bar, pool.text = bar, text
end

local function refresh()
    for _, pool in ipairs(pools) do
        local value = UnitPower("player", pool.id) or 0
        local maximum = UnitPowerMax("player", pool.id) or 0
        pool.bar:SetMinMaxValues(0, math.max(1, maximum))
        pool.bar:SetValue(value)
        pool.text:SetText(string.format("%s  %d / %d", pool.name, value, maximum))
    end
end

frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(self)
    local _, class = UnitClass("player")
    if class == "DRUID" then self:Show(); refresh() else self:Hide() end
end)
local elapsed = 0
frame:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed >= 0.1 then elapsed = 0; refresh() end
end)
