-- UncappedDashboardConfig -- static tab definitions plus the player-editable
-- nav button order that's saved on top of them. Loads first (see
-- UncappedDashboard.toc) so Core.TABS exists before DashboardButtons.lua
-- computes panel sizing from it.

local Core = _G.UncappedDashboard or {}
_G.UncappedDashboard = Core

-- `hint` is the slash command that already opens that addon today, shown
-- as a placeholder in the content pane until this button opens the real
-- window directly. Keep in sync with each addon's own SLASH_* registration.
-- Array order here is only the DEFAULT button order -- the player's actual
-- order (once they've moved anything) is saved separately, see
-- Core.OrderedTabs/Core.MoveTab below.
-- `disabled = true` means the button's click-to-open is inert (dimmed,
-- "Not available yet" tooltip) -- see CreateNavButton in DashboardButtons.lua.
-- Shift/ctrl-click reordering still works on a disabled button; only
-- Core.SetTab is skipped.
Core.TABS = {
    { key = "dashboard", label = "Dashboard" },
    -- Progress ships inside this addon (UncappedProgress\), not as a separate
    -- addon, so there is no `addon` field to enable/disable and no slash-command
    -- hint fallback to give -- it embeds directly, see EMBEDDED_TABS in
    -- UncappedDashboard_UI.lua.
    { key = "progress", label = "Progress", addon = "UncappedProgress", hint = "/progress" },
    -- Prestige ships inside this addon too (UncappedPrestige\), same shape as
    -- Progress: it embeds directly, see EMBEDDED_TABS in UncappedDashboard_UI.lua.
    --
    -- ⚠ THE NAV COLUMN IS NEARLY FULL. DashboardButtons.lua derives the window's
    -- required height from #Core.TABS: 44 + 14 + (#TABS - 1) * 36 + 30 + 16 + 40
    -- + 16. At 15 tabs that is 664 units, against the ~708 a default-UI-scale
    -- screen offers (UIParent is ~768 units tall whatever the monitor is, less
    -- SCREEN_MARGIN). ONE slot is left after this one -- 16 tabs is 700, and 17
    -- overflows and starts clipping buttons off the bottom of the window.
    -- Before adding a seventeenth, the column needs to scroll or paginate.
    { key = "prestige", label = "Prestige", addon = "UncappedPrestige", hint = "/prestige" },
    { key = "forge", label = "Forge", addon = "UncappedForge", hint = "/dashboard" },
    { key = "soulforge", label = "Soul Forge", addon = "UncappedSoulForge", hint = "/dashboard" },
    { key = "anima", label = "Anima", addon = "UncappedAnima", hint = "/dashboard" },
    { key = "vault", label = "Vault", addon = "UncappedVault", hint = "/dashboard" },
    { key = "transmog", label = "Transmog", addon = "UncappedTransmog", hint = "/dashboard" },
    { key = "lootfeed", label = "Loot Feed", addon = "UncappedLootFeed", hint = "/lootfeed" },
    { key = "statfeed", label = "Statistics", addon = "StatFeed", hint = "/statfeed", disabled = true },
    { key = "questlog", label = "Quest Log", addon = "UncappedQuests", hint = "/uquests", disabled = true },
    { key = "tutorial", label = "Tutorial", addon = "UncappedTutorial", disabled = true },
    { key = "utilities", label = "Utilities", addon = "UncappedOptions", hint = "/uncapped", disabled = true },
    { key = "beastiary", label = "Beastiary", disabled = true },
    { key = "soulscrolls", label = "Soul Scrolls", addon = "UncappedScrolls", hint = "/dashboard" },
}

-- Toggles shown in the Dashboard tab's "Modules" section. Purely a saved
-- on/off preference for now (UncappedDashboard_UI.lua persists it to
-- db.modules) -- nothing actually enables/disables these features yet.
Core.MODULES = {
    { key = "statfeed", label = "Stat Feed" },
    { key = "autoloot", label = "Autoloot" },
    { key = "aoeloot", label = "AoE Loot" },
    { key = "autodisenchant", label = "Autodisenchant" },
}

-- Returns Core.TABS resolved into the player's saved order (db.tabOrder, an
-- array of tab keys) -- falls back to Core.TABS' own array order if nothing's
-- been saved yet. Any key in a saved order that no longer matches a real tab
-- is dropped; any real tab missing from a stale saved order (e.g. one added
-- since the player last reordered) is appended at the end in its natural
-- Core.TABS position, rather than being lost.
function Core.OrderedTabs()
    local db = Core.GetDB()
    local order = db.tabOrder
    if type(order) ~= "table" or #order == 0 then
        return Core.TABS
    end

    local byKey = {}
    for _, tab in ipairs(Core.TABS) do byKey[tab.key] = tab end

    local resolved, seen = {}, {}
    for _, key in ipairs(order) do
        local tab = byKey[key]
        if tab and not seen[key] then
            resolved[#resolved + 1] = tab
            seen[key] = true
        end
    end
    for _, tab in ipairs(Core.TABS) do
        if not seen[tab.key] then
            resolved[#resolved + 1] = tab
            seen[tab.key] = true
        end
    end
    return resolved
end

-- Moves `key`'s nav button by `delta` slots (-1 up, +1 down) in the saved
-- order, clamped to the ends. Saves the new order and asks
-- DashboardButtons.lua to re-anchor the (already-built) nav buttons to match
-- -- see Buttons.RefreshOrder. Called from the nav buttons' own
-- shift/ctrl-click handlers (DashboardButtons.lua).
function Core.MoveTab(key, delta)
    local db = Core.GetDB()
    local order = Core.OrderedTabs()
    local keys = {}
    for i, tab in ipairs(order) do keys[i] = tab.key end

    local idx
    for i, k in ipairs(keys) do
        if k == key then idx = i; break end
    end
    if not idx then return end

    local newIdx = idx + delta
    if newIdx < 1 or newIdx > #keys then return end

    keys[idx], keys[newIdx] = keys[newIdx], keys[idx]
    db.tabOrder = keys

    if Core.Buttons and Core.Buttons.RefreshOrder then Core.Buttons.RefreshOrder() end
end
