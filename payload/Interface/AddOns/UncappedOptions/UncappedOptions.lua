-- UncappedOptions -- shared settings hub for the Uncapped addon suite.
--
-- Three jobs:
--   1. Expose a global widget library `UncappedUI` so every Uncapped addon can
--      build a settings page in a couple of lines instead of hand-placing frames.
--   2. Register the parent "Uncapped" category in ESC > Interface > AddOns, so
--      every addon's page nests under one heading (child.parent = "Uncapped").
--   3. Host the "Looting" page, which drives the server-side .auto / .aoeloot
--      commands. (It was "Loot & Disenchant" until 2026-08-16; the disenchant
--      half drove `.autodisenchant`, which no longer exists.)
--
-- This addon loads before every addon that builds a page (they list it in
-- ## OptionalDeps), so the parent category and the widget library exist before
-- any child page is built.
--
-- It loads AFTER exactly one addon: UncappedUI, which it now lists in its own
-- ## OptionalDeps. That is not a cycle -- UncappedUI references nothing here --
-- and it is what lets the window-scale slider below read the real saved value
-- while it is being built instead of showing 1.00 until the next login.
--
-- ⚠ Two different globals are both called "UncappedUI" and they are NOT the
-- same thing. `UncappedUI` (this file) is the settings-page widget library.
-- `UncappedUIKit` (the UncappedUI addon) is the in-game window toolkit and the
-- owner of the window-scale setting.

local PARENT = "Uncapped"

-- ===========================================================================
-- Widget library (global: UncappedUI)
-- ===========================================================================
UncappedUI = UncappedUI or {}
local UI = UncappedUI

local LEFT = 16               -- left inset shared by every widget
local uid = 0                 -- unique-name counter (sliders/dropdowns need names)
local function nextName(prefix)
    uid = uid + 1
    return prefix .. uid
end

-- A top-to-bottom layout cursor over a panel. Each widget is placed at the
-- current Y and advances it. Single left column, modest widths, so nothing ever
-- spills off the panel (its real width varies from client to client).
local Layout = {}
Layout.__index = Layout

-- ★ Redirects into the panel's SCROLL CONTENT when it has one.
--
-- Every widget below anchors to `self.panel`, so pointing that at the scroll
-- child is what makes fourteen settings pages scroll without touching a single
-- widget or call site. Pages built before this existed keep working: a plain
-- frame has no .uncappedContent and behaves exactly as it did.
function UI.Layout(panel, startY)
    local host = (panel and panel.uncappedContent) or panel
    return setmetatable({ panel = host, y = startY or -16 }, Layout)
end

-- Advancing the cursor also GROWS the scroll child, which is what gives the
-- scrollbar something to scroll. A scroll child with a fixed height silently
-- clips everything past it -- that was the bug: pages ran off the bottom of the
-- Interface window with no way to reach the rest.
function Layout:advance(h)
    self.y = self.y - h
    local host = self.panel
    if host and host.uncappedIsScrollContent then
        -- +24 so the last widget is not flush against the bottom edge.
        local needed = -self.y + 24
        if needed > (host:GetHeight() or 0) then
            host:SetHeight(needed)
        end
    end
end
function Layout:Gap(h) self:advance(h or 10) end

function Layout:Header(text)
    local fs = self.panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fs:SetPoint("TOPLEFT", self.panel, "TOPLEFT", LEFT, self.y)
    fs:SetText("|cffffd100" .. text .. "|r")
    self:advance(24)
    return fs
end

-- Wrapping help text. Caller passes an approximate pixel height (line wrapping
-- can't be measured before layout), 28 is about two lines.
function Layout:Note(text, height)
    local fs = self.panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", self.panel, "TOPLEFT", LEFT, self.y)
    fs:SetPoint("RIGHT", self.panel, "RIGHT", -16, 0)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    self:advance((height or 28) + 4)
    return fs
end

-- Checkbox. get() -> bool, set(bool) applies + persists.
function Layout:Check(label, get, set)
    local cb = CreateFrame("CheckButton", nil, self.panel, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", self.panel, "TOPLEFT", LEFT, self.y)
    cb:SetWidth(24)
    cb:SetHeight(24)
    local fs = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    fs:SetText(label)
    cb:SetChecked(get() and true or false)
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    cb.uncappedRefresh = function() cb:SetChecked(get() and true or false) end
    self:advance(26)
    return cb
end

-- Slider. get()/set(v) on a number; snaps to step; shows the live value.
function Layout:Slider(label, minV, maxV, step, get, set, fmt)
    fmt = fmt or "%.2f"
    local name = nextName("UncappedUISlider")
    local s = CreateFrame("Slider", name, self.panel, "OptionsSliderTemplate")
    s:SetPoint("TOPLEFT", self.panel, "TOPLEFT", LEFT, self.y - 14)
    s:SetWidth(250)
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step)
    _G[name .. "Low"]:SetText(tostring(minV))
    _G[name .. "High"]:SetText(tostring(maxV))
    local caption = _G[name .. "Text"]
    local function relabel(v) caption:SetText(label .. ":  |cffffd100" .. string.format(fmt, v) .. "|r") end
    s:SetValue(get())
    relabel(get())
    s:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v / step + 0.5) * step
        set(v)
        relabel(v)
    end)
    s.uncappedRefresh = function() s:SetValue(get()); relabel(get()) end
    self:advance(48)
    return s
end

-- Colour swatch. get() -> r,g,b ; set(r,g,b) applies + persists.
function Layout:Color(label, get, set)
    local btn = CreateFrame("Button", nil, self.panel)
    btn:SetPoint("TOPLEFT", self.panel, "TOPLEFT", LEFT, self.y)
    btn:SetWidth(18)
    btn:SetHeight(18)
    local border = btn:CreateTexture(nil, "BACKGROUND")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetTexture(0, 0, 0)
    local sw = btn:CreateTexture(nil, "ARTWORK")
    sw:SetAllPoints()
    local function refresh() sw:SetTexture(get()) end
    refresh()
    local fs = btn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("LEFT", btn, "RIGHT", 6, 0)
    fs:SetText(label)
    btn:SetScript("OnClick", function()
        local r, g, b = get()
        local function apply()
            local nr, ng, nb = ColorPickerFrame:GetColorRGB()
            set(nr, ng, nb)
            refresh()
        end
        ColorPickerFrame.func = apply
        ColorPickerFrame.cancelFunc = function() set(r, g, b); refresh() end
        ColorPickerFrame.hasOpacity = false
        ColorPickerFrame.previousValues = { r, g, b }
        ColorPickerFrame:SetColorRGB(r, g, b)
        if ColorPickerFrame:IsShown() then ColorPickerFrame:Hide() end
        ColorPickerFrame:Show()
    end)
    btn.uncappedRefresh = refresh
    self:advance(26)
    return btn
end

function Layout:Button(label, onClick, width)
    local b = CreateFrame("Button", nil, self.panel, "UIPanelButtonTemplate")
    b:SetPoint("TOPLEFT", self.panel, "TOPLEFT", LEFT, self.y)
    b:SetWidth(width or 150)
    b:SetHeight(24)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    self:advance(30)
    return b
end

-- Dropdown. choices = { {value=, text=}, ... }; get()/set(value).
function Layout:Dropdown(label, choices, get, set, width)
    local header = self.panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    header:SetPoint("TOPLEFT", self.panel, "TOPLEFT", LEFT, self.y)
    header:SetText(label)
    self:advance(16)
    local dd = CreateFrame("Frame", nextName("UncappedUIDrop"), self.panel, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", self.panel, "TOPLEFT", LEFT - 16, self.y)
    local function textFor(v)
        for _, c in ipairs(choices) do if c.value == v then return c.text end end
        return tostring(v)
    end
    UIDropDownMenu_Initialize(dd, function(self, level)
        for _, c in ipairs(choices) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = c.text
            info.value = c.value
            info.func = function()
                set(c.value)
                UIDropDownMenu_SetSelectedValue(dd, c.value)
                UIDropDownMenu_SetText(dd, c.text)
            end
            info.checked = (get() == c.value)
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UIDropDownMenu_SetWidth(dd, width or 160)
    UIDropDownMenu_SetSelectedValue(dd, get())
    UIDropDownMenu_SetText(dd, textFor(get()))
    dd.uncappedRefresh = function()
        UIDropDownMenu_SetSelectedValue(dd, get())
        UIDropDownMenu_SetText(dd, textFor(get()))
    end
    self:advance(42)
    return dd
end

-- Create a page registered under the "Uncapped" parent. Returns the panel and a
-- layout cursor already positioned below the title/subtitle.
-- Wrap a settings panel's body in a scroll frame and hand back the scroll child.
--
-- Exposed rather than kept private because one page (Uncapped64bitUI's combat
-- text) builds its own two-column layout by hand and needs the same treatment
-- without adopting the whole Layout cursor.
--
-- `topInset` is a NEGATIVE y offset -- where the scrollable body starts, below
-- whatever fixed header the caller drew.
function UI.MakeScrollable(panel, topInset)
    local scroll = CreateFrame("ScrollFrame", nextName("UncappedPanelScroll"), panel,
        "UIPanelScrollFrameTemplate")
    -- -30 on the right leaves the scrollbar its lane; the template parents the bar
    -- to the scroll frame and draws it just outside the right edge.
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, topInset or -46)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -30, 12)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetWidth(1)
    content:SetHeight(1)
    content.uncappedIsScrollContent = true
    scroll:SetScrollChild(content)

    -- ⚠ THE CHILD'S WIDTH CANNOT BE SET AT BUILD TIME. An Interface options page
    -- has no size until the Interface frame shows it and sizes it to the panel
    -- container, so a width measured now is 0 and every "SetPoint RIGHT" inside
    -- resolves against nothing. Sync it whenever the scroll frame actually has a
    -- size, and again on show for pages built before the frame was ever displayed.
    local function sync()
        local w = scroll:GetWidth()
        if w and w > 0 then content:SetWidth(w) end
    end
    scroll:SetScript("OnSizeChanged", sync)
    panel:HookScript("OnShow", sync)
    sync()

    -- The template wires the bar but not always the wheel on 3.3.5; do it
    -- explicitly so the page scrolls the way every player expects it to.
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local bar = _G[self:GetName() .. "ScrollBar"]
        if not bar then return end
        local step = 28
        bar:SetValue(bar:GetValue() - delta * step)
    end)

    panel.uncappedContent = content
    panel.uncappedScroll = scroll
    return content
end

function UI.CreatePanel(displayName, subtitle)
    local panel = CreateFrame("Frame", nextName("UncappedPanel"), UIParent)
    panel.name = displayName
    if displayName ~= PARENT then panel.parent = PARENT end

    -- Title and subtitle stay on the PANEL, not in the scroll body: a heading
    -- that scrolls away leaves the player looking at controls with no idea which
    -- page they are on.
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(displayName)

    local startY = -46
    if subtitle then
        local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
        sub:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
        sub:SetJustifyH("LEFT")
        sub:SetText(subtitle)
        startY = -62
    end

    UI.MakeScrollable(panel, startY)
    InterfaceOptions_AddCategory(panel)
    -- Layout redirects into the scroll child, and the cursor restarts at the top
    -- of it -- the header's offset is already spent by the scroll frame's anchor.
    return panel, UI.Layout(panel, -8)
end

-- Open the Interface options straight to a page (double call works around the
-- long-standing client quirk where the first call doesn't scroll to it).
function UI.Open(panel)
    InterfaceOptionsFrame_OpenToCategory(panel)
    InterfaceOptionsFrame_OpenToCategory(panel)
end

-- ===========================================================================
-- The parent "Uncapped" landing page.
-- ===========================================================================
local hub = UI.CreatePanel(PARENT, "Settings for the Uncapped realm's custom addons. Pick a page under this heading on the left.")

-- Window zoom lives on the LANDING page, not on a page of its own: it is the
-- one setting that applies to every Uncapped addon at once, so burying it
-- under any single addon's heading would be a lie about its reach.
--
-- The setting itself is owned by UncappedUI (UncappedScale.lua) and saved in
-- UncappedUIDB, NOT here: that addon is the one that actually applies it, so
-- it must be able to restore the zoom on login whether or not this options
-- addon is enabled. This page is only a control surface -- every accessor
-- below re-reads _G.UncappedUIKit at call time and no-ops when it is absent.
local function ScaleKit()
    local kit = _G.UncappedUIKit
    if kit and kit.GetUIScale and kit.SetUIScale then return kit end
    return nil
end

local function GetWindowScale()
    local kit = ScaleKit()
    if kit then return kit.GetUIScale() end
    return 1.0
end

local function SetWindowScale(v)
    local kit = ScaleKit()
    if kit then kit.SetUIScale(v) end
end

local scaleRefreshers = {}

do
    local L = UI.Layout(hub, -76)
    L:Header("Uncapped")
    L:Note("Everything that makes this realm 'uncapped' -- combat text, alerts, the Mythic+ HUD and rewards, hotzones, the reagent-bank helper, and loot automation -- is configured on the pages listed under this heading. Click one on the left to open it.", 72)

    L:Gap(8)
    L:Header("Window Scale")
    L:Note("Zooms every Uncapped window -- the Dashboard and all of its tabs, the Vault, Forge, Soul Forge, Transmog, Loot Feed, chat, the Mythic+ HUD and the rest. Blizzard's own frames are not affected; for those use the UI Scale slider on the Video options. Takes effect immediately and is remembered between sessions.", 56)

    local slider = L:Slider("Uncapped window scale", 0.5, 1.5, 0.05,
        GetWindowScale, SetWindowScale, "%.2f")
    scaleRefreshers[#scaleRefreshers + 1] = slider.uncappedRefresh

    L:Button("Reset to 100%", function()
        SetWindowScale(1.0)
        for _, r in ipairs(scaleRefreshers) do r() end
    end, 150)

    L:Note("|cff808080Windows keep their place when you change this -- anything that would land off the screen is pulled back on. The Dashboard's button column is the one window that stops zooming early: past a certain size its 15 buttons would not fit the screen height, so it grows only as far as it can still show all of them.|r", 44)

    -- =======================================================================
    -- Per-window zoom
    -- =======================================================================
    -- The slider above is a master control; these are per-window trims on top of
    -- it. A player who wants a big Dashboard and a small HUD could not say so
    -- before -- one number moved everything at once.
    --
    -- ★ THE SLIDER LIST COMES FROM UncappedUIKit.GetScaleGroups(), NOT FROM A
    --   COPY HERE. That table is declared next to the code that applies the
    --   zoom, so a group added there gets a slider automatically and the two can
    --   never disagree about what exists.
    local kit0 = ScaleKit()
    if kit0 and kit0.GetScaleGroups and kit0.GetGroupScale and kit0.SetGroupScale then
        L:Gap(10)
        L:Header("Per-Window Zoom")
        L:Note("Fine-tune individual windows on top of the master scale above. 1.00 means "
            .. "'just follow the master'. The two multiply, so a master of 1.20 with a "
            .. "Dashboard of 0.80 gives the Dashboard 0.96.", 40)

        local groups = kit0.GetScaleGroups()
        for i = 1, #groups do
            local g = groups[i]
            local key = g.key
            local sl = L:Slider(g.label, 0.5, 1.5, 0.05,
                function()
                    local kit = ScaleKit()
                    return (kit and kit.GetGroupScale and kit.GetGroupScale(key)) or 1.0
                end,
                function(v)
                    local kit = ScaleKit()
                    if kit and kit.SetGroupScale then kit.SetGroupScale(key, v) end
                end,
                "%.2f")
            scaleRefreshers[#scaleRefreshers + 1] = sl.uncappedRefresh
            if g.note then
                L:Note("|cff808080" .. g.note .. "|r", 26)
            end
        end

        L:Button("Reset every window to 1.00", function()
            local kit = ScaleKit()
            if kit and kit.SetGroupScale then
                for j = 1, #groups do kit.SetGroupScale(groups[j].key, 1.0) end
            end
            for _, r in ipairs(scaleRefreshers) do r() end
        end, 220)
    end
end

-- ===========================================================================
-- Looting page (drives the server-side .auto / .aoeloot commands).
--
-- ⚠ THE AUTO-DISENCHANT SECTION WAS REMOVED 2026-08-16 (owner ruling). It drove
--   `.autodisenchant`, which no longer exists on the server -- bulk disenchanting
--   lives in the Forge and nowhere else. Do not rebuild this UI: the command it
--   sent is gone, and the point of removing it was that a background process
--   which destroys gear had no quest check and ate quest turn-in items.
-- ===========================================================================

-- Runs a dot-command exactly as if the player had typed it into chat: the server
-- intercepts the leading "." and executes it. Works for the SEC_PLAYER commands
-- .auto / .aoeloot.
local function RunDotCommand(cmd)
    local eb = DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox
    if not eb then return end
    eb:SetText(cmd)
    ChatEdit_SendText(eb, 0)
    eb:SetText("")
end

-- Live settings table. Filled from SavedVariables at ADDON_LOADED; the global
-- then points at this table so edits persist. These mirror what we last SENT --
-- the server is the real source of truth (there's no clean way to read it back),
-- which the page's note makes clear.
local db = {
    auto = true,
    aoeloot = false,
    -- [#1231] The coin chime on a gold pickup. Default TRUE because that is what
    -- the realm does today and a default must never silently change a setting
    -- nobody asked about; the report is that with auto-loot on it fires constantly,
    -- not that it should be off to begin with.
    coinsound = true,
}

local refreshers = {}
local function refreshLoot()
    for _, r in ipairs(refreshers) do r() end
end

-- ---------------------------------------------------------------------------
-- [#833] The auto-sell list.
--
-- Vendor trash has always been sold for you. This is the player-editable half:
-- anything else you always want turned into gold the moment it drops.
--
-- ⚠ THE SERVER OWNS THE LIST AND EVERY RULE ABOUT IT. This page never decides
--   what may be added, never keeps its own copy between sessions, and never
--   treats its confirmation dialog as the safety step -- the server arms that
--   confirmation and refuses an unarmed answer. A settings page can be stale,
--   disabled or replaced; the thing that destroys items must not depend on it.
--
-- Unlike the two toggles above (which fire a dot-command and hope), this talks
-- over the addon pipe and redraws from whatever the server sends back, so it is
-- correct even when another character on the same account edits the list --
-- which it can, because the list is account-wide.
-- ---------------------------------------------------------------------------
local AS_TRANSPORT = "REAGENTBANK"   -- client -> server (shared addon transport)
local AS_PIPE      = "UNC"           -- server -> client (replies arrive here)
local AS_MAX       = 100             -- server's own ceiling; mirrored for the header
local AS_ROW_H     = 22

local AS = {
    rows    = {},    -- reusable row frames, index 1..n
    entries = {},    -- what the server last told us the list is
    pending = nil,   -- burst accumulator between ASLBEG and ASLEND
    confirm = nil,   -- the add currently sitting in the confirmation popup
}

local function ASSend(body)
    if SendAddonMessage then
        SendAddonMessage(AS_TRANSPORT, body, "WHISPER", UnitName("player"))
    end
end

-- Plain-English versions of the server's refusal codes. Every one of these is a
-- rule the server enforces whether or not this page exists; the text only
-- explains it.
local AS_ERRORS = {
    DUP     = "That is already on your list.",
    QUEST   = "That item is used by a quest, so it can never be auto-sold.",
    KEEP    = "That is always kept in your bags (hearthstone, keystone, reagents, ammo, dungeon keys) and cannot be auto-sold.",
    BAG     = "Bags cannot be auto-sold -- destroying one destroys everything inside it.",
    WORTH   = "That sells for nothing, so adding it would delete it rather than sell it.",
    FULL    = "Your list is full. Remove something first.",
    NOCONF  = "That confirmation expired. Add the item again.",
    UNKNOWN = "The server did not recognise that item.",
}

local function ASPrint(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Auto-sell]|r " .. msg)
end

-- The confirmation for anything that is not vendor trash. Its timeout is set
-- from the window the server reports, never hardcoded: a dialog that outlives
-- the arm behind it sends an answer that is refused, and the player is told
-- "that expired" by a box still sitting on their screen.
StaticPopupDialogs["UNCAPPED_AUTOSELL_CONFIRM"] = {
    text = "%s",
    button1 = ACCEPT,
    button2 = CANCEL,
    OnAccept = function()
        if AS.confirm then
            ASSend("ASLADDC:" .. AS.confirm.entry)
            AS.confirm = nil
        end
    end,
    OnCancel = function() AS.confirm = nil end,
    timeout = 60,
    whileDead = 1,
    hideOnEscape = 1,
    showAlert = 1,
}

StaticPopupDialogs["UNCAPPED_AUTOSELL_CLEAR"] = {
    text = "Empty your auto-sell list?\n\nVendor trash will still be sold for you; nothing else will.",
    button1 = ACCEPT,
    button2 = CANCEL,
    OnAccept = function() ASSend("ASLCLR") end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

do
    local panel, L = UI.CreatePanel("Looting",
        "Automate looting. These options send the matching server commands for you.")

    L:Header("Looting")
    refreshers[#refreshers + 1] = L:Check("Auto-collect loot, mining, herbs & skinning",
        function() return db.auto end,
        function(v) db.auto = v; RunDotCommand(".auto " .. (v and "on" or "off")) end).uncappedRefresh
    refreshers[#refreshers + 1] = L:Check("AOE loot (loot all nearby corpses at once)",
        function() return db.aoeloot end,
        function(v) db.aoeloot = v; RunDotCommand(".aoeloot " .. (v and "on" or "off")) end).uncappedRefresh

    --[[ [#1231] The coin chime.

         ⚠ A SERVER TOGGLE, NOT A CLIENT MUTE, and that is not a preference. The
           3.3.5a client has no MuteSoundFile (7.x) and no scriptable way to
           suppress one sound of the loot event, so the only place this can be
           switched off is where the sound is played from -- hence a dot-command,
           exactly like the two boxes above it.

         Phrased POSITIVELY ("play it") so the tick reads the same way round as the
         other two: ticked = the thing happens. The dot-command follows the tick,
         so `.coinsound off` is what an unticked box sends. ]]
    refreshers[#refreshers + 1] = L:Check("Play the coin sound when you loot gold",
        function() return db.coinsound end,
        function(v) db.coinsound = v; RunDotCommand(".coinsound " .. (v and "on" or "off")) end).uncappedRefresh

    L:Gap(6)
    L:Note("|cff808080These toggles send server commands and remember your last choice here. If you change them with a chat command instead, this page won't know -- reopen it after /reload to resync.|r", 40)

    -- =======================================================================
    -- Auto-sell
    -- =======================================================================
    L:Gap(10)
    L:Header("Auto-sell")
    L:Note("Grey vendor trash is always sold for you automatically. Anything you put on the list below is sold the same way, the moment it drops -- on every character on this account.", 44)
    L:Note("|cffff8080Items on this list are sold and destroyed without asking. Quest items, your hearthstone, keystone, reagents, ammo, dungeon keys and bags can never be added, and anything that is not grey asks you to confirm first. Nothing you are already carrying or wearing is ever touched -- the list only acts on new loot.|r", 56)

    -- The drop target. Pick an item up from your bags and either drop it here or
    -- click the button while holding it.
    local drop = L:Button("Drop an item here to add it", function() end, 240)

    local function ASAddFromCursor()
        local kind, id = GetCursorInfo()
        if kind ~= "item" or not id then
            ASPrint("Pick an item up from your bags first, then drop it here (or type its ID below).")
            return
        end
        ClearCursor()
        ASSend("ASLADD:" .. id)
    end

    drop:SetScript("OnClick", ASAddFromCursor)
    drop:SetScript("OnReceiveDrag", ASAddFromCursor)

    -- ...and the typed route, which is the one that still works when the item is
    -- not in your bags to pick up. Accepts a pasted item link or a bare item ID.
    local box = CreateFrame("EditBox", "UncappedAutoSellEntryBox", L.panel, "InputBoxTemplate")
    box:SetPoint("TOPLEFT", L.panel, "TOPLEFT", 20, L.y)
    box:SetWidth(160)
    box:SetHeight(20)
    box:SetAutoFocus(false)

    local function ASAddFromBox()
        local text = box:GetText() or ""
        -- An item link carries "item:<id>:"; a bare number is the id itself.
        local id = text:match("|Hitem:(%d+):") or text:match("^%s*(%d+)%s*$")
        if not id then
            ASPrint("Type an item ID, or paste an item link.")
            return
        end
        box:SetText("")
        box:ClearFocus()
        ASSend("ASLADD:" .. id)
    end

    box:SetScript("OnEnterPressed", ASAddFromBox)
    box:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)

    local addBtn = CreateFrame("Button", nil, L.panel, "UIPanelButtonTemplate")
    addBtn:SetPoint("LEFT", box, "RIGHT", 8, 0)
    addBtn:SetWidth(70)
    addBtn:SetHeight(22)
    addBtn:SetText("Add")
    addBtn:SetScript("OnClick", ASAddFromBox)
    L:Gap(30)

    L:Note("|cff808080You can also use |cffffffff.autosell add|cff808080 in chat and shift-click the item straight into the command. |cffffffff.autosell|cff808080 on its own lists everything.|r", 36)

    local clearBtn = L:Button("Clear the whole list", function()
        StaticPopup_Show("UNCAPPED_AUTOSELL_CLEAR")
    end, 180)
    clearBtn:Disable()

    L:Gap(8)
    local heading = L:Header("On the list")

    -- Everything above this point is fixed height, so the list is built last and
    -- is the only thing that has to grow the scroll body. `listTop` is where it
    -- starts; the rows are laid out downward from there and the scroll child is
    -- resized to match after every redraw.
    local listTop = L.y

    local function ASGrow(rowCount)
        local host = panel.uncappedContent
        if not (host and host.uncappedIsScrollContent) then return end
        host:SetHeight(-listTop + (rowCount * AS_ROW_H) + 24)
    end

    local function ASRow(i)
        local row = AS.rows[i]
        if row then return row end

        row = CreateFrame("Button", nil, L.panel)
        row:SetPoint("TOPLEFT", L.panel, "TOPLEFT", 20, listTop - (i - 1) * AS_ROW_H)
        row:SetPoint("RIGHT", L.panel, "RIGHT", -20, 0)
        row:SetHeight(AS_ROW_H - 2)

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.icon:SetWidth(16)
        row.icon:SetHeight(16)

        row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.label:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.label:SetJustifyH("LEFT")

        row.price = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        row.price:SetPoint("LEFT", row.label, "RIGHT", 8, 0)
        row.price:SetJustifyH("LEFT")

        row.remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.remove:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        row.remove:SetWidth(70)
        row.remove:SetHeight(18)
        row.remove:SetText("Remove")
        row.remove:SetScript("OnClick", function()
            if row.entry then ASSend("ASLDEL:" .. row.entry) end
        end)

        -- The tooltip is the honest answer to "what exactly did I add" -- the
        -- name alone is not, on a realm with re-skinned and customised items.
        row:SetScript("OnEnter", function(self)
            if not self.entry then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("item:" .. self.entry)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)

        AS.rows[i] = row
        return row
    end

    local function ASRedraw()
        local n = #AS.entries

        for i = 1, n do
            local e = AS.entries[i]
            local row = ASRow(i)
            row.entry = e.entry

            local colour = (ITEM_QUALITY_COLORS[e.quality] and ITEM_QUALITY_COLORS[e.quality].hex) or "|cffffffff"
            row.label:SetText(colour .. e.name .. "|r")
            row.price:SetText(GetCoinTextureString and GetCoinTextureString(e.sell) or (e.sell .. "c"))
            row.icon:SetTexture(GetItemIcon and GetItemIcon(e.entry) or "Interface\\Icons\\INV_Misc_QuestionMark")
            row:Show()
        end

        for i = n + 1, #AS.rows do
            AS.rows[i]:Hide()
            AS.rows[i].entry = nil
        end

        if n > 0 then
            heading:SetText("|cffffd100On the list (" .. n .. " of " .. AS_MAX .. ")|r")
            clearBtn:Enable()
        else
            heading:SetText("|cffffd100On the list -- nothing yet|r")
            clearBtn:Disable()
        end

        ASGrow(n)
    end

    -- ---------------------------------------------------------------------
    -- Comms. The list is never patched locally: every accepted edit is answered
    -- by a fresh full burst, so this page cannot drift away from the server.
    -- ---------------------------------------------------------------------
    local comms = CreateFrame("Frame")
    comms:RegisterEvent("CHAT_MSG_ADDON")
    comms:SetScript("OnEvent", function(_, _, prefix, text)
        if prefix ~= AS_PIPE or not text then return end
        if text:sub(1, 3) ~= "ASL" then return end

        if text:sub(1, 7) == "ASLBEG:" then
            AS.pending = {}
            return
        end

        if text == "ASLEND" then
            AS.entries = AS.pending or {}
            AS.pending = nil
            ASRedraw()
            return
        end

        local entry, quality, sell, name = text:match("^ASLROW:(%d+):(%d+):(%d+):(.*)$")
        if entry then
            if not AS.pending then AS.pending = {} end
            AS.pending[#AS.pending + 1] = {
                entry = tonumber(entry), quality = tonumber(quality),
                sell = tonumber(sell) or 0, name = name,
            }
            return
        end

        local cEntry, cQuality, cSell, cArm, cName = text:match("^ASLCONF:(%d+):(%d+):(%d+):(%d+):(.*)$")
        if cEntry then
            AS.confirm = { entry = tonumber(cEntry) }
            local colour = (ITEM_QUALITY_COLORS[tonumber(cQuality)] and ITEM_QUALITY_COLORS[tonumber(cQuality)].hex)
                or "|cffffffff"
            StaticPopupDialogs["UNCAPPED_AUTOSELL_CONFIRM"].timeout = tonumber(cArm) or 60
            StaticPopup_Show("UNCAPPED_AUTOSELL_CONFIRM",
                colour .. cName .. "|r is not vendor trash.\n\nEvery copy you loot from now on will be sold "
                .. "for " .. ((GetCoinTextureString and GetCoinTextureString(tonumber(cSell) or 0))
                    or ((cSell or 0) .. "c")) .. " each and destroyed, on every character on this account.\n\n"
                .. "Nothing you are carrying or wearing right now is touched.")
            return
        end

        local eEntry, code = text:match("^ASLERR:(%d+):(%a+)$")
        if eEntry then
            ASPrint(AS_ERRORS[code] or ("That item was refused (" .. code .. ")."))
            return
        end
    end)

    -- Ask on login and every time the page is opened. Cheap, and it is the only
    -- thing that keeps this honest when the list was edited from chat or by
    -- another character on the account.
    local waker = CreateFrame("Frame")
    waker:RegisterEvent("PLAYER_LOGIN")
    waker:SetScript("OnEvent", function() ASSend("ASLGET") end)
    panel:HookScript("OnShow", function() ASSend("ASLGET") end)

    ASRedraw()

    UncappedLootPanel = panel
end

-- ===========================================================================
-- SavedVariables load: merge saved values, point the global at our live table.
-- ===========================================================================
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
-- The window-scale slider is built at file scope from a value owned by another
-- addon's SavedVariables (UncappedUIDB, see above). ## OptionalDeps: UncappedUI
-- makes that load first so the value is normally already right, but the slider
-- is re-synced at login anyway -- one event is a lot cheaper than a slider that
-- silently reads 1.00 while the player's windows are at 1.30.
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self, event, name)
    if event == "PLAYER_LOGIN" then
        for _, r in ipairs(scaleRefreshers) do r() end
        return
    end
    if name ~= "UncappedOptions" then return end
    if type(UncappedOptionsDB) == "table" then
        local s = UncappedOptionsDB
        -- s.de (the old auto-disenchant qualities/ilvl) is deliberately ignored:
        -- the feature is gone, and a saved table from before 2026-08-16 must not
        -- resurrect keys nothing reads.
        if s.auto ~= nil then db.auto = s.auto end
        if s.aoeloot ~= nil then db.aoeloot = s.aoeloot end
        -- [#1231] `~= nil`, not truthiness: `false` is the whole point of this key,
        -- and `if s.coinsound then` would quietly restore the default for everyone
        -- who had turned it off.
        if s.coinsound ~= nil then db.coinsound = s.coinsound end
    end
    UncappedOptionsDB = db   -- persist edits to our live table
    refreshLoot()
    self:UnregisterEvent("ADDON_LOADED")
end)

-- /uncapped opens the hub.
SLASH_UNCAPPEDOPTIONS1 = "/uncapped"
SlashCmdList["UNCAPPEDOPTIONS"] = function() UI.Open(hub) end
