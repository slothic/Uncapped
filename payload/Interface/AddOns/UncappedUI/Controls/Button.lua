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

    -- Every kit button gets a halo attached. Under a theme with glowAlpha 0
    -- (i.e. "Default") this is one permanently hidden texture and nothing else
    -- -- see Effects\Glow.lua -- so the stock look is unaffected and unbilled.
    if UncappedUIKit.AttachGlow then UncappedUIKit.AttachGlow(button) end

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

    --[[
        ★★ SetText AND Disable BOTH HAD TO BE OVERRIDDEN, and the reasons are
           different. A UI audit on 2026-08-16 found both already failing live.

        SetText: the label is an independent FontString on `b.text`, and this
        button never calls SetFontString -- so the inherited Button:SetText wrote
        to a font string that does not exist and the label silently never
        changed. Every caller that relabels a button at runtime (Chat's
        Expand/Compact, SoulForge's scope cycler, Transmog's outfit rows) went
        permanently blank. UncappedKeystoneRun.lua carried a hand-rolled shim for
        exactly this; that shim can now go.

        Disable: the inherited Enable/Disable work, but this button has no
        disabled texture and no disabled font object, so a disabled button looked
        **identical to an enabled one**. It still refused clicks, which is the
        worst combination -- the player sees a live button that does nothing.
        ⚠ This was already shipping in UncappedLFG, UncappedKeystone and
        UncappedKeystoneRun before the audit found it.

        ⚠ Both are overridden on the INSTANCE, not on a shared metatable: these
          are plain CreateFrame buttons with no shared prototype to hang methods
          on, and copying a metatable per widget would cost more than two
          closures.
    ]]
    function b:SetText(text)
        if self.text then self.text:SetText(text or "") end
    end
    function b:GetText()
        return self.text and self.text:GetText() or nil
    end

    local baseEnable, baseDisable = b.Enable, b.Disable
    function b:Enable()
        baseEnable(self)
        self.uncappedDisabled = false
        UncappedUIKit.SetButtonActive(self, self.active)   -- repaints from theme
    end
    function b:Disable()
        baseDisable(self)
        self.uncappedDisabled = true
        local theme = UncappedUIKit.GetActiveTheme()
        -- textDisabled has existed in the theme since it was written and was
        -- used by nothing until now.
        local c = theme.colors
        self:SetBackdropColor(unpack(c.buttonFillDisabled or { 0.05, 0.05, 0.05, 0.55 }))
        self:SetBackdropBorderColor(unpack(c.buttonBorderDisabled or { 0.20, 0.18, 0.15, 0.70 }))
        if self.text then self.text:SetTextColor(unpack(c.textDisabled or { 0.5, 0.5, 0.5 })) end
        if UncappedUIKit.SetGlowActive then UncappedUIKit.SetGlowActive(self, false) end
    end

    UncappedUIKit.Register(b, ApplyButtonSkin)
    return b
end

function UncappedUIKit.SetButtonActive(button, active)
    button.active = active and true or false
    local theme = UncappedUIKit.GetActiveTheme()
    local c = theme.colors

    -- ⚠ A disabled button keeps its disabled look. Without this, any refresh loop
    --   that re-asserts active state (Keystone's tab strip, the Vault's row
    --   highlighter) would repaint a disabled button as enabled -- and the theme
    --   hook calls this on every /uitheme, so it would happen on its own too.
    if button.uncappedDisabled then
        button:SetBackdropColor(unpack(c.buttonFillDisabled or { 0.05, 0.05, 0.05, 0.55 }))
        button:SetBackdropBorderColor(unpack(c.buttonBorderDisabled or { 0.20, 0.18, 0.15, 0.70 }))
        if button.text then button.text:SetTextColor(unpack(c.textDisabled or { 0.5, 0.5, 0.5 })) end
        if UncappedUIKit.SetGlowActive then UncappedUIKit.SetGlowActive(button, false) end
        return
    end

    -- ★ These four used to be literals here, which meant a theme could restyle
    --   every texture in the kit and still not change the colour of a selected
    --   button. They fall back to the old gold values, so a theme that defines
    --   none of them looks exactly as this did before.
    if button.active then
        button:SetBackdropColor(unpack(c.buttonFillActive or { 0.25, 0.18, 0.02, 0.92 }))
        button:SetBackdropBorderColor(unpack(c.buttonBorderActive or c.gold))
        button.text:SetTextColor(unpack(c.buttonTextActive or c.gold))
    else
        button:SetBackdropColor(unpack(c.buttonFill or { 0.05, 0.05, 0.05, 0.88 }))
        button:SetBackdropBorderColor(unpack(c.buttonBorder or { 0.30, 0.27, 0.20, 0.95 }))
        button.text:SetTextColor(unpack(c.buttonText or c.text))
    end

    -- The selected button is the one that breathes.
    if UncappedUIKit.SetGlowActive then UncappedUIKit.SetGlowActive(button, button.active) end
end
