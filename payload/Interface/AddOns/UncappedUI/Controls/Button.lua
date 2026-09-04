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

    -- Decoration is built lazily HERE rather than in CreateButton, because this
    -- function also runs on every theme change and must be able to bring a
    -- layer into existence that the previous theme never asked for.
    if not button.rim and UncappedUIKit.CreateNineSlice then
        button.rim = UncappedUIKit.CreateNineSlice(button, { layer = "BORDER", sublayer = 1 })
    end
    if not button.gloss then
        button.gloss = button:CreateTexture(nil, "ARTWORK")
        -- Anchored across the TOP EDGE ONLY, so width comes from the anchors
        -- and height stays under SetHeight's control below. Anchoring both
        -- TOPLEFT and BOTTOMRIGHT would fully define the rect and silently make
        -- that SetHeight a no-op -- the sheen would render as a hairline.
        button.gloss:SetPoint("TOPLEFT", 1, -1)
        button.gloss:SetPoint("TOPRIGHT", -1, -1)
        button.gloss:Hide()
    end

    -- ★ The sheen is a VERTICAL gradient stretched horizontally, which is why it
    --   is a plain stretched texture and not nine-sliced: it has no horizontal
    --   detail to distort, so it survives any button width.
    local gloss = theme.metrics.buttonGlossAlpha or 0
    if theme.textures.gloss and gloss > 0 then
        button.gloss:SetTexture(theme.textures.gloss)
        button.gloss:SetAlpha(gloss)
        button.gloss:SetHeight((theme.metrics.buttonGlossHeight or 0.5) * button:GetHeight())
        button.gloss:Show()
    else
        button.gloss:Hide()
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
    -- A faint halo follows the cursor. Without this only the SELECTED button
    -- ever reacts, and a panel full of inert buttons reads as a screenshot.
    b:SetScript("OnEnter", function(self)
        if UncappedUIKit.SetGlowHover and not self.uncappedDisabled then
            UncappedUIKit.SetGlowHover(self, true)
        end
    end)
    b:SetScript("OnLeave", function(self)
        if UncappedUIKit.SetGlowHover then UncappedUIKit.SetGlowHover(self, false) end
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
    -- Rounded outline. Nil texture (stock "Default") leaves it hidden and the
    -- backdrop's own square edge remains the border, exactly as before.
    local function paintRim(col)
        if not button.rim then return end
        local t = theme.textures.buttonRim
        if t and col and (col[4] or 1) > 0 then
            button.rim:SetTexture(t)
            button.rim:SetVertexColor(col[1], col[2], col[3])
            button.rim:SetAlpha(col[4] or 1)
            button.rim:SetGeometry(0, theme.metrics.buttonCorner or 10)
            button.rim:Show()
        else
            button.rim:Hide()
        end
    end

    if button.uncappedDisabled then
        button:SetBackdropColor(unpack(c.buttonFillDisabled or { 0.05, 0.05, 0.05, 0.55 }))
        button:SetBackdropBorderColor(unpack(c.buttonBorderDisabled or { 0.20, 0.18, 0.15, 0.70 }))
        if button.text then button.text:SetTextColor(unpack(c.textDisabled or { 0.5, 0.5, 0.5 })) end
        if UncappedUIKit.SetGlowActive then UncappedUIKit.SetGlowActive(button, false) end
        paintRim(c.buttonRimDisabled)
        if button.gloss then button.gloss:SetAlpha((theme.metrics.buttonGlossAlpha or 0) * 0.3) end
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

    paintRim(button.active and c.buttonRimActive or c.buttonRim)

    -- The selected button is the one that breathes.
    if UncappedUIKit.SetGlowActive then UncappedUIKit.SetGlowActive(button, button.active) end
end
