-- UncappedUIKit Controls.Button -- theme-aware backdrop button with an
-- active/inactive toggle state (used for filter chips, view toggles, tabs).

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

local unpack = unpack

local function ApplyButtonSkin(button, theme)
    button:SetBackdrop({
        bgFile = theme.textures.buttonBG,
        edgeFile = theme.textures.buttonEdge,
        tile = false, edgeSize = theme.metrics.buttonEdgeSize,
        insets = theme.metrics.buttonInsets,
    })
    if button:GetHighlightTexture() then
        button:GetHighlightTexture():SetTexture(theme.textures.buttonHighlight)
    end
    UncappedUIKit.SetButtonActive(button, button.active)
end

function UncappedUIKit.CreateButton(parent, label, width, height)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(width or 90)
    b:SetHeight(height or 26)
    b.text = UncappedUIKit.CreateText(b, "highlightSmall", "CENTER", b, "CENTER", 0, 0, label)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    if b:GetHighlightTexture() then b:GetHighlightTexture():SetBlendMode("ADD") end
    b:SetPushedTexture("Interface\\Buttons\\WHITE8x8")
    local pushed = b:GetPushedTexture()
    if pushed then
        pushed:SetVertexColor(0, 0, 0, 0.35)
        pushed:SetBlendMode("BLEND")
    end
    b:SetScript("OnMouseDown", function(self)
        if self:IsEnabled() then self.text:SetPoint("CENTER", self, "CENTER", 1, -1) end
    end)
    b:SetScript("OnMouseUp", function(self)
        self.text:SetPoint("CENTER", self, "CENTER", 0, 0)
    end)
    b.active = false
    UncappedUIKit.Register(b, ApplyButtonSkin)
    return b
end

function UncappedUIKit.SetButtonActive(button, active)
    button.active = active and true or false
    local theme = UncappedUIKit.GetActiveTheme()
    local c = theme.colors
    if button.active then
        button:SetBackdropColor(0.25, 0.18, 0.02, 0.92)
        button:SetBackdropBorderColor(unpack(c.gold))
        button.text:SetTextColor(unpack(c.gold))
    else
        button:SetBackdropColor(0.05, 0.05, 0.05, 0.88)
        button:SetBackdropBorderColor(0.30, 0.27, 0.20, 0.95)
        button.text:SetTextColor(unpack(c.text))
    end
end
