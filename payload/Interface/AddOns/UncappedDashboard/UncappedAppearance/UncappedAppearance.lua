-- UncappedAppearance -- the Dashboard's "Appearance" tab: recolour the whole
-- interface, choose the background patterns, and tune how the clouds move.
--
-- ★ THE PLAYER NEVER SEES A THEME KEY. The kit has about a hundred of them;
--   showing that list would be a config file with a mouse on it. This panel
--   offers eight ROLES instead -- "Selection", "Chrome", "Body text" -- and each
--   writes every key that shares that job. One click recolours the halo, the
--   rim, the tick and the selected label together, because those are one idea to
--   a player even though they are eight keys to the kit.
--
-- ★ EVERYTHING IS LIVE. Overrides go through UncappedUIKit.SetCustom, which
--   re-resolves the theme and re-skins every registered widget immediately, so
--   the panel recolours under the cursor as the wheel is dragged. No Apply
--   button, no reload.
--
-- ★ FILL COLOURS ARE DERIVED, NEVER PICKED. The one way a colour panel can
--   genuinely break a UI is letting someone set a label and the thing behind it
--   to the same colour. So "Selection" picks ONE colour and this file derives
--   the button fill dark and the label bright from it. The contrast is a
--   property of the code, not of the player's taste.
--
-- ⚠ Nothing here is destructive. Overrides live separately from the theme, in
--   UncappedUIDB.custom, and are merged ON TOP of it -- so Reset restores the
--   shipped look exactly, and a theme shipped later still reaches players who
--   have customised only a couple of things.

local Kit = _G.UncappedUIKit
if not Kit then return end

local Appearance = _G.UncappedAppearance or {}
_G.UncappedAppearance = Appearance
Appearance.UI = {}

local frame, sections, tabBar
local galleryTarget = "nebulaA"      -- which layer the gallery assigns to
local galleryFamily = "all"          -- family filter in the pattern gallery

local PAD = 16
local PATTERN_DIR = "Interface\\AddOns\\UncappedUI\\Assets\\Patterns\\"

local function clamp01(v) return v < 0 and 0 or (v > 1 and 1 or v) end

-- ---------------------------------------------------------------------------
-- Roles: one player-facing colour -> every theme key that shares its job.
-- `derive` lets a key take a TRANSFORMED version of the picked colour, which is
-- how fill/label pairs stay legible no matter what is chosen.
-- ---------------------------------------------------------------------------
local ROLES = {
    {
        id = "selection", label = "Selection",
        help = "Whatever you have picked: the open tab, a ticked box, the chosen row.",
        sample = "buttonRimActive",
        keys = { "gold", "glowActive", "buttonRimActive", "rowSelected",
                 "checkBoxTintChecked", "checkMarkTint",
                 "buttonFillActive", "buttonTextActive", "rowSelectedText" },
        derive = {
            -- Dark enough to sit under bright text, whatever hue is chosen.
            buttonFillActive = function(r, g, b) return { r * 0.34, g * 0.34, b * 0.34 } end,
            -- Lifted toward white so the label always clears its own fill.
            buttonTextActive = function(r, g, b)
                return { clamp01(r * 0.4 + 0.6), clamp01(g * 0.4 + 0.6), clamp01(b * 0.4 + 0.6) }
            end,
            rowSelectedText = function(r, g, b)
                return { clamp01(r * 0.4 + 0.6), clamp01(g * 0.4 + 0.6), clamp01(b * 0.4 + 0.6) }
            end,
        },
    },
    {
        id = "chrome", label = "Chrome",
        help = "Frames, rims, scrollbars, and the glow that follows your cursor.",
        sample = "panelRimTint",
        keys = { "windowTint", "windowBorderTint", "bannerTint", "panelTint",
                 "panelRimTint", "buttonRim", "glow", "glowHover",
                 "scrollThumbTint", "checkBoxTint", "closeGlyphTint", "editBoxTint" },
        derive = {
            -- The window art is large and already mid-bright; tinting it with the
            -- full-strength accent turns the whole frame into a slab of colour.
            windowTint = function(r, g, b)
                return { clamp01(r * 0.5 + 0.45), clamp01(g * 0.5 + 0.2), clamp01(b * 0.5 + 0.45) }
            end,
            panelTint = function(r, g, b) return { r * 0.85, g * 0.85, b * 0.9 } end,
        },
    },
    {
        id = "surface", label = "Panel",
        help = "The flat colour behind the clouds.",
        sample = "nebulaBase", keys = { "nebulaBase" },
    },
    {
        id = "text", label = "Body text",
        sample = "text", keys = { "text", "buttonText" },
    },
    {
        id = "muted", label = "Quiet text",
        help = "Hints, counts, and anything deliberately secondary.",
        sample = "textMuted", keys = { "textMuted" },
    },
    {
        id = "cloudA", label = "Clouds, near",
        sample = "nebulaTintA", keys = { "nebulaTintA" },
    },
    {
        id = "cloudB", label = "Clouds, far",
        sample = "nebulaTintB", keys = { "nebulaTintB" },
    },
    {
        id = "stars", label = "Stars",
        sample = "nebulaTintStars", keys = { "nebulaTintStars" },
    },
}

-- ---------------------------------------------------------------------------
-- Sliders. mapIn/mapOut exist so a plain 0-100 dial can drive a theme value
-- that runs backwards or over an odd range. Cloud SIZE is why: bigger clouds
-- mean a SMALLER texture window.
-- ---------------------------------------------------------------------------
local function pct(v) return math.floor((v or 0) * 100 + 0.5) end

local SLIDERS = {
    { key = "nebulaAlphaA", label = "Near cloud density", default = 0.34,
      mapIn = pct, mapOut = function(v) return v / 100 end },
    { key = "nebulaAlphaB", label = "Far cloud density", default = 0.26,
      mapIn = pct, mapOut = function(v) return v / 100 end },
    { key = "nebulaAlphaStars", label = "Star brightness", default = 0.75,
      mapIn = pct, mapOut = function(v) return v / 100 end },

    -- ⚠ INVERTED, and it can never exceed 0.5. The texture window may not be
    --   wider than the content period or the coordinate leaves [0,1] -- see the
    --   header of Effects\Nebula.lua. So 0.5 is "smallest clouds", not a middle.
    { key = "nebulaScaleA", label = "Near cloud size", default = 0.42,
      mapIn = function(v) return math.floor((0.5 - (v or 0.5)) / 0.0038 + 0.5) end,
      mapOut = function(v) return 0.5 - v * 0.0038 end },
    { key = "nebulaScaleB", label = "Far cloud size", default = 0.30,
      mapIn = function(v) return math.floor((0.5 - (v or 0.5)) / 0.0038 + 0.5) end,
      mapOut = function(v) return 0.5 - v * 0.0038 end },

    { key = "glowAlpha", label = "Glow strength", default = 0.90,
      mapIn = pct, mapOut = function(v) return v / 100 end },

    -- Shown as "how fast", so a SHORTER period is a HIGHER number. 0 means the
    -- glow holds steady, which is a legitimate choice, not "off".
    { key = "glowPulsePeriod", label = "Pulse speed", default = 2.6,
      mapIn = function(v)
          if not v or v <= 0 then return 0 end
          return math.floor((8.0 - v) / 0.075 + 0.5)
      end,
      mapOut = function(v)
          if v <= 0 then return 0 end
          return 8.0 - v * 0.075
      end },
}

-- One dial for both cloud layers plus the stars. Separate speed sliders invite a
-- combination where one layer looks frozen and reads as a bug.
local BASE_SPEED = { nebulaSpeedA = 0.0060, nebulaSpeedB = 0.0105, nebulaSpeedStars = 0.0016 }

-- ---------------------------------------------------------------------------
local function ThemeValue(section, key)
    local t = Kit.GetActiveTheme()
    return (t[section] or {})[key]
end

local function RoleColor(role)
    local c = ThemeValue("colors", role.sample) or { 1, 1, 1 }
    return c[1] or 1, c[2] or 1, c[3] or 1
end

-- ⚠ ONE batched write, not one per key. The colour wheel calls this
--   continuously while being dragged, and "Selection" covers nine keys -- the
--   per-key version meant nine complete re-skins of every widget in the suite,
--   every frame of a drag.
local function SetRoleColor(role, r, g, b)
    local values = {}
    for _, key in ipairs(role.keys) do
        if role.derive and role.derive[key] then
            values[key] = role.derive[key](r, g, b)
        else
            -- Three components only. DeepMerge keeps the base ALPHA, so a key
            -- that is deliberately translucent (rowSelected at 0.22) is not
            -- slammed opaque just because someone picked a hue.
            values[key] = { r, g, b }
        end
    end
    Kit.SetCustomBatch("colors", values)
end

local function RoleHasCustom(role)
    for _, key in ipairs(role.keys) do
        if Kit.GetCustom("colors", key) ~= nil then return true end
    end
    return false
end

-- Drops this role's overrides only. What it falls back to is whatever the
-- selected THEME says, which is the point: "default" means the shipped value,
-- not a hardcoded colour this panel carries its own copy of.
local function ResetRole(role)
    Kit.ClearCustomBatch("colors", role.keys)
end

-- ===========================================================================
-- Colours
-- ===========================================================================
local ROW_H = 48

local function BuildColours(parent)
    local g = CreateFrame("Frame", nil, parent)
    g:SetAllPoints(parent)
    g.rows = {}

    Kit.CreateText(g, "title", "TOPLEFT", g, "TOPLEFT", PAD, -PAD, "Colours")
    Kit.CreateText(g, "highlightSmall", "TOPLEFT", g, "TOPLEFT", PAD, -PAD - 26,
        "Click a swatch for the wheel, or type a hex code. Everything updates as you go.")

    local top = -PAD - 60
    for i, role in ipairs(ROLES) do
        local y = top - (i - 1) * ROW_H
        local row = { role = role }

        row.swatch = Kit.CreateColorSwatch(g, role.label,
            function() return RoleColor(role) end,
            function(r, gg, b)
                SetRoleColor(role, r, gg, b)
                if g.RefreshRow then g:RefreshRow(row) end
            end)
        row.swatch:SetPoint("TOPLEFT", g, "TOPLEFT", PAD, y)

        if role.help then
            -- Below the whole row, not beside the label: the hex field and the
            -- Default button occupy y-1 down to y-23 on this same line.
            Kit.CreateText(g, "disableSmall", "TOPLEFT", g, "TOPLEFT", PAD + 34, y - 27, role.help)
        end

        -- @ST@ A HEX FIELD, because that is how people move a colour between tools.
        --   CreateValueBox commits on Enter or focus-loss and restores the last
        --   good value on Escape, so a half-typed code never reaches the theme.
        row.hex = Kit.CreateValueBox(g, 82, 22, "RRGGBB")
        row.hex:SetPoint("TOPLEFT", g, "TOPLEFT", PAD + 210, y - 1)
        row.hex.OnCommit = function(text)
            local r, gg, b = Kit.HexToColor(text)
            if not r then
                -- Rejected: CreateValueBox puts the previous value back, so a
                -- typo leaves the colour alone instead of blanking it.
                return false
            end
            SetRoleColor(role, r, gg, b)
            g:RefreshRow(row)
            return true
        end

        row.reset = Kit.CreateButton(g, "Default", 76, 22)
        row.reset:SetPoint("TOPLEFT", g, "TOPLEFT", PAD + 304, y - 1)
        row.reset:SetScript("OnClick", function()
            ResetRole(role)
            g:Refresh()
        end)
        row.reset:SetScript("OnEnter", function(self)
            if not self.uncappedDisabled and Kit.SetGlowHover then
                Kit.SetGlowHover(self, true)
            end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Back to the shipped colour")
            GameTooltip:AddLine(role.label, 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        row.reset:SetScript("OnLeave", function(self)
            if Kit.SetGlowHover then Kit.SetGlowHover(self, false) end
            GameTooltip:Hide()
        end)

        g.rows[#g.rows + 1] = row
    end

    function g:RefreshRow(row)
        row.swatch:Refresh()
        local r, gg, b = RoleColor(row.role)
        row.hex:SetValue(Kit.ColorToHex(r, gg, b))
        -- Nothing to put back means nothing to press. The kit styles a disabled
        -- button properly, so this reads as unavailable rather than broken.
        if RoleHasCustom(row.role) then row.reset:Enable() else row.reset:Disable() end
    end

    function g:Refresh()
        for _, row in ipairs(self.rows) do self:RefreshRow(row) end
    end

    return g
end

-- ===========================================================================
-- Background: pattern gallery + motion
-- ===========================================================================
local GALLERY_COLS, GALLERY_ROWS, CELL = 9, 4, 52

-- ★ THE LIBRARY IS UNBROWSABLE WITHOUT THIS. 124 patterns behind a Previous /
--   Next pair is fourteen pages of paging to find the poison ones. Built from
--   whatever families are actually present rather than a hardcoded list, so it
--   stays right when art is added.
local function FamilyChoices()
    local seen, out = {}, { { value = "all", text = "All families" } }
    for _, e in ipairs(Kit.PATTERNS or {}) do
        local fam = e.family or "Other"
        if not seen[fam] then
            seen[fam] = true
            out[#out + 1] = { value = fam, text = fam }
        end
    end
    return out
end

local function FilteredPatterns()
    local all = Kit.PATTERNS or {}
    if galleryFamily == "all" then return all end
    local out = {}
    for _, e in ipairs(all) do
        if e.family == galleryFamily then out[#out + 1] = e end
    end
    return out
end

local function BuildBackground(parent)
    local g = CreateFrame("Frame", nil, parent)
    g:SetAllPoints(parent)
    g.cells = {}
    g.page = 1

    Kit.CreateText(g, "title", "TOPLEFT", g, "TOPLEFT", PAD, -PAD, "Background")

    local layerTabs = Kit.CreateTabs(g, {
        { key = "nebulaA", label = "Near clouds", width = 100 },
        { key = "nebulaB", label = "Far clouds", width = 96 },
        { key = "nebulaStars", label = "Stars", width = 70 },
    }, function(key)
        galleryTarget = key
        g:RefreshGallery()
    end)
    layerTabs:SetPoint("TOPLEFT", g, "TOPLEFT", PAD, -PAD - 30)
    layerTabs:SelectTab("nebulaA")

    g.familyDrop = Kit.CreateDropdown(g, "UncappedAppearanceFamilyDrop", 120,
        FamilyChoices,
        function() return galleryFamily end,
        function(v)
            galleryFamily = v
            g.page = 1
            g:RefreshGallery()
        end)
    g.familyDrop:SetPoint("TOPLEFT", g, "TOPLEFT", PAD + 268, -PAD - 26)

    local grid = CreateFrame("Frame", nil, g)
    grid:SetPoint("TOPLEFT", g, "TOPLEFT", PAD, -PAD - 64)
    grid:SetWidth(GALLERY_COLS * CELL)
    grid:SetHeight(GALLERY_ROWS * CELL)

    for i = 1, GALLERY_COLS * GALLERY_ROWS do
        local b = CreateFrame("Button", nil, grid)
        b:SetWidth(CELL - 6); b:SetHeight(CELL - 6)
        b:SetPoint("TOPLEFT", grid, "TOPLEFT",
            ((i - 1) % GALLERY_COLS) * CELL,
            -math.floor((i - 1) / GALLERY_COLS) * CELL)

        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints(b)

        -- ⚠ The swatch shows the THUMBNAIL, never the full pattern. A page of
        --   36 full-size patterns would be well over a hundred megabytes of
        --   texture memory just to draw a grid of chips.
        b.thumb = b:CreateTexture(nil, "ARTWORK")
        b.thumb:SetPoint("TOPLEFT", 2, -2)
        b.thumb:SetPoint("BOTTOMRIGHT", -2, 2)
        b.thumb:SetBlendMode("ADD")

        b.rim = Kit.CreateNineSlice and Kit.CreateNineSlice(b, { layer = "OVERLAY", sublayer = 1 }) or nil

        b:SetScript("OnClick", function(self)
            if not self.patKey then return end
            Kit.SetCustom("textures", galleryTarget, self.path)
            g:RefreshGallery()
        end)
        b:SetScript("OnEnter", function(self)
            if not self.patKey then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.patLabel or self.patKey)
            if self.patFamily then GameTooltip:AddLine(self.patFamily, 0.7, 0.7, 0.7) end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        g.cells[i] = b
    end

    local prev = Kit.CreateButton(g, "Previous", 84, 22)
    prev:SetPoint("TOPLEFT", grid, "BOTTOMLEFT", 0, -10)
    prev:SetScript("OnClick", function()
        g.page = math.max(1, g.page - 1); g:RefreshGallery()
    end)
    local nxt = Kit.CreateButton(g, "Next", 84, 22)
    nxt:SetPoint("LEFT", prev, "RIGHT", 8, 0)
    nxt:SetScript("OnClick", function() g.page = g.page + 1; g:RefreshGallery() end)
    g.pageText = Kit.CreateText(g, "highlightSmall", "LEFT", nxt, "RIGHT", 14, 0, "")

    local sy = -(PAD + 64) - GALLERY_ROWS * CELL - 56
    g.sliders = {}
    for i, def in ipairs(SLIDERS) do
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)
        local s = Kit.CreateSlider(g, def.label, 0, 100, 1,
            function()
                local v = ThemeValue("metrics", def.key)
                return def.mapIn(v == nil and def.default or v)
            end,
            function(v) Kit.SetCustom("metrics", def.key, def.mapOut(v)) end,
            function() return def.label end)
        s:SetPoint("TOPLEFT", g, "TOPLEFT", PAD + col * 240, sy - row * 46)
        g.sliders[#g.sliders + 1] = { widget = s, def = def }
    end

    local speedRow = math.ceil(#SLIDERS / 2)
    g.speed = Kit.CreateSlider(g, "Drift speed", 0, 200, 5,
        function()
            local a = ThemeValue("metrics", "nebulaSpeedA") or BASE_SPEED.nebulaSpeedA
            return math.floor(a / BASE_SPEED.nebulaSpeedA * 100 + 0.5)
        end,
        function(v)
            for key, base in pairs(BASE_SPEED) do
                Kit.SetCustom("metrics", key, base * (v / 100))
            end
        end,
        function() return "Drift speed" end)
    g.speed:SetPoint("TOPLEFT", g, "TOPLEFT", PAD, sy - speedRow * 46)

    function g:RefreshGallery()
        local list = FilteredPatterns()
        local perPage = GALLERY_COLS * GALLERY_ROWS
        local pages = math.max(1, math.ceil(#list / perPage))
        if self.page > pages then self.page = pages end
        local offset = (self.page - 1) * perPage
        local current = ThemeValue("textures", galleryTarget)
        local theme = Kit.GetActiveTheme()
        local c = theme.colors

        for i = 1, perPage do
            local cell = self.cells[i]
            local entry = list[i + offset]
            if entry then
                cell.patKey, cell.patLabel, cell.patFamily = entry.key, entry.label, entry.family
                cell.path = PATTERN_DIR .. entry.key
                cell.thumb:SetTexture(cell.path .. "_t")
                cell.bg:SetTexture(0.03, 0.015, 0.05, 1)

                local chosen = (current == cell.path)
                if cell.rim then
                    local tint = chosen and (c.gold or { 1, 0.8, 0.3 })
                                        or (c.panelRimTint or { 0.6, 0.4, 0.9 })
                    cell.rim:SetTexture(theme.textures.panelRim)
                    cell.rim:SetVertexColor(tint[1], tint[2], tint[3])
                    cell.rim:SetAlpha(chosen and 1 or 0.30)
                    cell.rim:SetGeometry(0, 9)
                    cell.rim:Show()
                end
                cell:Show()
            else
                cell.patKey = nil
                cell:Hide()
            end
        end
        self.pageText:SetText(string.format("Page %d of %d   %d %s", self.page, pages, #list,
            galleryFamily == "all" and "patterns" or (galleryFamily .. " patterns")))
    end

    function g:Refresh()
        self:RefreshGallery()
        for _, e in ipairs(self.sliders) do
            local v = ThemeValue("metrics", e.def.key)
            e.widget:SetValueSilently(e.def.mapIn(v == nil and e.def.default or v))
        end
        local a = ThemeValue("metrics", "nebulaSpeedA") or BASE_SPEED.nebulaSpeedA
        self.speed:SetValueSilently(math.floor(a / BASE_SPEED.nebulaSpeedA * 100 + 0.5))
    end

    return g
end

-- ===========================================================================
-- Presets
-- ===========================================================================
local PRESETS = {
    { name = "Uncapped", theme = "Uncapped",
      desc = "The realm's own look: violet chrome, gold selection." },
    { name = "Stock WoW", theme = "Default",
      desc = "Blizzard's original frames. No clouds, no glow." },
}

local function BuildPresets(parent)
    local g = CreateFrame("Frame", nil, parent)
    g:SetAllPoints(parent)

    Kit.CreateText(g, "title", "TOPLEFT", g, "TOPLEFT", PAD, -PAD, "Presets")
    Kit.CreateText(g, "highlightSmall", "TOPLEFT", g, "TOPLEFT", PAD, -PAD - 26,
        "A starting point. Anything you changed by hand is kept until you reset.")

    local y = -PAD - 60
    for _, preset in ipairs(PRESETS) do
        local b = Kit.CreateButton(g, preset.name, 150, 24)
        b:SetPoint("TOPLEFT", g, "TOPLEFT", PAD, y)
        b:SetScript("OnClick", function()
            Kit.SetTheme(preset.theme)
            if sections then sections:Refresh() end
        end)
        Kit.CreateText(g, "highlightSmall", "LEFT", b, "RIGHT", 14, 0, preset.desc)
        y = y - 34
    end

    y = y - 24
    local reset = Kit.CreateButton(g, "Reset everything", 150, 24)
    reset:SetPoint("TOPLEFT", g, "TOPLEFT", PAD, y)
    reset:SetScript("OnClick", function()
        Kit.ResetCustom()
        if sections then sections:Refresh() end
    end)
    Kit.CreateText(g, "highlightSmall", "LEFT", reset, "RIGHT", 14, 0,
        "Puts every colour and pattern back the way it shipped.")

    function g:Refresh() end
    return g
end

-- ===========================================================================
-- Frame
-- ===========================================================================
-- ★ EACH SECTION IS BUILT IN ISOLATION, and a failure becomes a visible panel
--   rather than an exception.
--
--   Without this, one error anywhere in one section aborted BuildFrame outright:
--   the section that had already been built stayed on screen, the other two were
--   never created, and -- because the tab strip is built AFTER all three -- the
--   panel ended up with NO NAVIGATION AT ALL. It did not look like something had
--   broken, it looked like the tabs were never designed. That is the worst kind
--   of failure: silent, and misread as the intended design.
local function SafeBuild(label, fn, parent)
    local ok, result = pcall(fn, parent)
    if ok and result then return result end

    local g = CreateFrame("Frame", nil, parent)
    g:SetAllPoints(parent)
    Kit.CreateText(g, "title", "TOPLEFT", g, "TOPLEFT", PAD, -PAD, label)
    Kit.CreateText(g, "highlightSmall", "TOPLEFT", g, "TOPLEFT", PAD, -PAD - 30,
        "This section could not be built. The error is below -- please pass it on.")
    local err = Kit.CreateText(g, "disableSmall", "TOPLEFT", g, "TOPLEFT", PAD, -PAD - 54,
        tostring(result))
    err:SetWidth(460)
    err:SetJustifyH("LEFT")

    function g:Refresh() end
    return g
end

local function BuildFrame(parent)
    if frame then return frame end

    frame = CreateFrame("Frame", "UncappedAppearanceFrame", parent or UIParent)
    frame:SetPoint("TOPLEFT")
    frame:SetPoint("BOTTOMRIGHT")

    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -34)
    body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)

    local built = {
        colours    = SafeBuild("Colours", BuildColours, body),
        background = SafeBuild("Background", BuildBackground, body),
        presets    = SafeBuild("Presets", BuildPresets, body),
    }

    sections = {}
    function sections:Show(key)
        for k, sec in pairs(built) do
            if k == key then sec:Show() else sec:Hide() end
        end
        self.current = key
        if built[key].Refresh then pcall(built[key].Refresh, built[key]) end
    end
    function sections:Refresh()
        -- pcall for the same reason as SafeBuild: a refresh that throws must not
        -- take the tab strip with it.
        if self.current and built[self.current].Refresh then
            pcall(built[self.current].Refresh, built[self.current])
        end
    end

    tabBar = Kit.CreateTabs(frame, {
        { key = "colours", label = "Colours", width = 88 },
        { key = "background", label = "Background", width = 106 },
        { key = "presets", label = "Presets", width = 88 },
    }, function(key) sections:Show(key) end)
    tabBar:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -6)
    tabBar:SelectTab("colours")
    sections:Show("colours")

    -- Repaint the controls whenever ANYTHING changes the theme, including a
    -- change this panel did not make -- /uitheme typed into chat, say.
    if Kit.OnThemeChanged then
        Kit.OnThemeChanged(function() if sections then sections:Refresh() end end)
    end

    return frame
end

-- ===========================================================================
-- Dashboard embedding
-- ===========================================================================
function Appearance.UI.EmbedInto(parent)
    BuildFrame(parent)
    frame:Show()
    return frame
end

function Appearance.UI.Activate()
    if not frame then return end
    if sections then sections:Refresh() end
end

-- ⚠ Content-panel width, but FULL-WINDOW height. The asymmetry is the
--   Dashboard's contract, not a slip: SetMinContentWidth adds the nav column and
--   margins itself, while SetMinContentHeight takes the number as given.
function Appearance.UI.GetMinWidth()
    return GALLERY_COLS * CELL + PAD * 2 + 20
end

function Appearance.UI.GetMinHeight()
    return 720
end
