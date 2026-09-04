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
    --
    -- ⚠ THE PLAYER'S WINDOW ZOOM SPENDS THE SAME BUDGET. REQUIRED_HEIGHT is in
    -- window units and the zoom multiplies it, so 664 units at 1.05x is already
    -- the whole screen. Adding a tab therefore does not just use a slot -- it
    -- lowers the zoom this window can reach for everyone (the cap is
    -- (usable screen height) / REQUIRED_HEIGHT). The Dashboard clamps its own
    -- zoom to that cap rather than letting the column clip; see the CurrentScale
    -- block in DashboardButtons.lua. The 16th tab drops the ceiling to ~1.01,
    -- i.e. it effectively ends zooming for this window. Read "one slot left" as
    -- "one slot left, and taking it costs the zoom feature here".
    { key = "prestige", label = "Prestige", addon = "UncappedPrestige", hint = "/prestige" },
    { key = "forge", label = "Forge", addon = "UncappedForge", hint = "/dashboard" },
    { key = "soulforge", label = "Soul Forge", addon = "UncappedSoulForge", hint = "/dashboard" },
    { key = "anima", label = "Anima", addon = "UncappedAnima", hint = "/dashboard" },
    { key = "vault", label = "Vault", addon = "UncappedVault", hint = "/dashboard" },
    { key = "transmog", label = "Transmog", addon = "UncappedTransmog", hint = "/dashboard" },
    { key = "lootfeed", label = "Loot Feed", addon = "UncappedLootFeed", hint = "/lootfeed" },
    { key = "statfeed", label = "Statistics", addon = "StatFeed", hint = "/statfeed", disabled = true },
    { key = "questlog", label = "Quest Log", addon = "UncappedQuests", hint = "/uquests", disabled = true },
    -- ★ THIS SLOT WAS "Tutorial" -- a disabled placeholder pointing at
    -- `UncappedTutorial`, an addon that does not exist and never did. Taken for
    -- Extraction 2026-08-16 rather than adding a SIXTEENTH tab, for exactly the
    -- reason the block above spells out: at 16 the nav column needs ~700 units
    -- and the window's zoom ceiling collapses to ~1.01, which ends zooming here
    -- for everyone. Same trade the Beastiary slot took. If a tutorial is ever
    -- built it needs the scrolling nav column first.
    { key = "extraction", label = "Extraction", addon = "UncappedSoulForge", hint = "/extract" },
    -- ★ THIS SLOT WAS "Utilities" -- a DISABLED row pointing at UncappedOptions,
    -- which is a real addon but an ESC-menu settings hub with no UI.EmbedInto,
    -- so the tab could never have opened anything. Taken for Appearance on
    -- 2026-09-04 rather than adding a SIXTEENTH tab, for the reason the block
    -- above spells out: at 16 the nav column needs ~700 units and the window's
    -- zoom ceiling collapses to ~1.01, which ends zooming here for everyone.
    -- Same trade the Extraction and Keystone slots already took.
    -- UncappedOptions is untouched and still reachable via /uncapped and ESC.
    { key = "appearance", label = "Appearance", addon = "UncappedAppearance", hint = "/dashboard" },
    -- ★ THIS SLOT WAS "Beastiary" -- a disabled placeholder with no addon behind
    -- it, never built. Taken rather than adding a SIXTEENTH tab, because the
    -- comment above is not decoration: at 16 the nav column's required height
    -- reaches ~700 units and the window's zoom ceiling collapses to ~1.01, i.e.
    -- adding one costs the zoom feature for everyone. Swapping a dead button for
    -- a live one costs nothing. If the Beastiary is ever built it needs the
    -- scrolling nav column first.
    { key = "keystone", label = "M+ Rewards", addon = "UncappedKeystone", hint = "/keystone" },
    { key = "soulscrolls", label = "Soul Scrolls", addon = "UncappedScrolls", hint = "/dashboard" },
}

-- Sends a dot command as the player. Same route UncappedPanel uses: a dot
-- command typed into SAY is intercepted by the server and never reaches chat.
function Core.RunDotCommand(command)
    if not command or command == "" then return false end
    if not SendChatMessage then return false end
    SendChatMessage(command, "SAY")
    return true
end

-- Toggles shown in the Dashboard tab's "Modules" section.
--
-- ★ These DO something as of 2026-08-16. They previously wrote db.modules and
--   nothing read it, so all four ticked, saved, and changed nothing -- a control
--   that looks live and isn't, with no hint to the player that it was inert.
--
-- Each entry carries `set` (apply the state) and optionally `get` (read the real
-- current state). Where `get` is absent the saved preference is the only record
-- we have, which is correct for the server-side toggles: the client cannot query
-- them, and both default ON server-side exactly as the checkbox defaults ticked.
Core.MODULES = {
    {
        key = "statfeed", label = "Stat Feed",
        -- StatFeed exposes only a TOGGLE, never a setter, so read the real frame
        -- and fire the toggle solely when it disagrees with the checkbox --
        -- otherwise ticking an already-shown window would hide it.
        get = function()
            return StatFeedFrame ~= nil and StatFeedFrame:IsShown()
        end,
        set = function(on)
            if not StatFeedFrame or not SlashCmdList or not SlashCmdList["STATFEED"] then
                return false
            end
            local shown = StatFeedFrame:IsShown() and true or false
            if shown ~= (on and true or false) then
                SlashCmdList["STATFEED"]("")
            end
            return true
        end,
    },
    {
        -- ⚠ `.auto` is not just autolooting. Unit.cpp gates personal group loot
        -- on it too: with it OFF, a recipient's roll is never banked at all
        -- ("Each recipient's own .auto governs delivery"). Unticking this without
        -- the note would quietly cut the player out of group loot, which is the
        -- kind of surprise that arrives as a bug report weeks later.
        key = "autoloot", label = "Autoloot",
        note = "also gathering, and receiving group loot",
        set = function(on) return Core.RunDotCommand(".auto " .. (on and "on" or "off")) end,
    },
    {
        key = "aoeloot", label = "AoE Loot",
        set = function(on) return Core.RunDotCommand(".aoeloot " .. (on and "on" or "off")) end,
    },
}

-- ⚠ Do not add an auto-disenchant toggle here (owner ruling 2026-08-16): its protection predicate consulted only the Soulforge name whitelist and had no quest check, so quest turn-in gear was eligible for destruction. Bulk disenchanting is the Forge and nowhere else.

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
