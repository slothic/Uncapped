-- UncappedUI "Uncapped" theme -- WIP, awaiting custom art.
--
-- ThemeManager deep-merges this table on top of "Default" (see
-- ThemeManager.lua), so leaving a key out here means it simply inherits
-- the stock WoW look for that key. Right now every key is left out on
-- purpose: there is no Uncapped-branded art yet, so this theme currently
-- resolves to an exact copy of Default.
--
-- To bring a piece of it online:
--   1. Drop the finished texture under WIP\UI\Assets\Buttons, \Frames, or
--      \Icons (matching the live path Interface\AddOns\UncappedUI\Assets\...
--      once synced).
--   2. Uncomment/add the matching key below pointing at that path.
-- ThemeManager re-resolves and every widget built through UncappedUI
-- re-skins itself immediately -- no other code changes needed.

local UncappedUI = _G.UncappedUI
if not UncappedUI then return end

UncappedUI.RegisterTheme("Uncapped", {
    -- colors = {
    --     gold = { 1.00, 0.82, 0.22 },
    -- },
    -- textures = {
    --     windowBG = "Interface\\AddOns\\UncappedUI\\Assets\\Frames\\WindowBG.tga",
    --     windowEdge = "Interface\\AddOns\\UncappedUI\\Assets\\Frames\\WindowEdge.tga",
    --     panelBG = "Interface\\AddOns\\UncappedUI\\Assets\\Frames\\PanelBG.tga",
    --     panelEdge = "Interface\\AddOns\\UncappedUI\\Assets\\Frames\\PanelEdge.tga",
    --     buttonBG = "Interface\\AddOns\\UncappedUI\\Assets\\Buttons\\ButtonBG.tga",
    --     buttonEdge = "Interface\\AddOns\\UncappedUI\\Assets\\Buttons\\ButtonEdge.tga",
    -- },
})
