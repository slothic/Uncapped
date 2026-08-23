-- UncappedUIKit "Uncapped" theme -- WIP, awaiting custom art.
--
-- ThemeManager deep-merges this table on top of "Default" (see
-- ThemeManager.lua), so leaving a key out here means it simply inherits
-- the stock WoW look for that key. Right now every key is left out on
-- purpose: there is no Uncapped-branded art yet, so this theme currently
-- resolves to an exact copy of Default.
--
-- ⚠ [AN-06] BECAUSE OF THAT, THIS FILE IS NOT IN UncappedUI.toc. Registering a
-- theme that resolves to an identical copy of Default put an "Uncapped" entry in
-- /uitheme that reported success and changed nothing -- a setting players could
-- pick and then wonder what it did.
--
-- To bring a piece of it online:
--   1. Drop the finished texture under WIP\UI\Assets\Buttons, \Frames, or
--      \Icons (matching the live path Interface\AddOns\UncappedUIKit\Assets\...
--      once synced).
--   2. Uncomment/add the matching key below pointing at that path.
--   3. ★ Re-add the `Themes\UncappedTheme.lua` line to UncappedUI.toc, or none
--      of this runs.
-- ThemeManager re-resolves and every widget built through UncappedUIKit
-- re-skins itself immediately -- no other code changes needed.

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

UncappedUIKit.RegisterTheme("Uncapped", {
    -- colors = {
    --     gold = { 1.00, 0.82, 0.22 },
    -- },
    -- textures = {
    --     windowBG = "Interface\\AddOns\\UncappedUIKit\\Assets\\Frames\\WindowBG.tga",
    --     windowEdge = "Interface\\AddOns\\UncappedUIKit\\Assets\\Frames\\WindowEdge.tga",
    --     panelBG = "Interface\\AddOns\\UncappedUIKit\\Assets\\Frames\\PanelBG.tga",
    --     panelEdge = "Interface\\AddOns\\UncappedUIKit\\Assets\\Frames\\PanelEdge.tga",
    --     buttonBG = "Interface\\AddOns\\UncappedUIKit\\Assets\\Buttons\\ButtonBG.tga",
    --     buttonEdge = "Interface\\AddOns\\UncappedUIKit\\Assets\\Buttons\\ButtonEdge.tga",
    -- },
})
