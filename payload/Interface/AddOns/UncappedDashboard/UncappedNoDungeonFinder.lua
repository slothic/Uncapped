--[[ ==========================================================================
     UncappedNoDungeonFinder -- the stock Dungeon Finder is gone.

     Owner ruling 2026-08-18: "I don't want the dungeonfinder system at all."
     The realm has its own noticeboard (/mlfg, UncappedLFG.lua next door), and
     two competing group finders is worse than either one alone.

     THIS IS THE CLIENT HALF. The server half is DungeonFinder.OptionsMask = 0,
     which stops LFGMgr dead. Both are needed and neither is sufficient:

       * server only -> the window still opens, looks alive, and silently does
         nothing. AC defines WorldSession::SendLfgDisabled() but NEVER CALLS IT
         (verified: the only references are the definition and the header), so
         the client is never told the system is off. A window that opens and
         does nothing is worse than no window.
       * client only -> a /run script could still queue.

     ⚠ HOLIDAY BOSSES ARE NOT AFFECTED, and that was checked rather than
       assumed. Coren Direbrew (BRD), Apothecary Hummel (Shadowfang Keep), the
       Headless Horseman (Pumpkin Shrine, SM Graveyard) and Ahune (Ice Stone,
       Slave Pens) are all spawned and reachable on foot, and all four carry
       real loot on that path. LFGMgr::FinishDungeon already early-returns for
       any group that was not queued, so walking in was always the unrewarded-
       by-LFG path -- turning LFG off just makes everyone a walk-in.

     ★ WHY THIS PROBES INSTEAD OF ASSUMING. FrameXML is not enumerable from the
       client's MPQ listfiles, so the exact global names could not be verified
       from outside the game. Every name below is therefore OPTIONAL: if it does
       not exist it is skipped and recorded. `/nodf` prints what was caught and
       what was missing, so a wrong name shows up as a visible gap the first
       time anyone looks, instead of quietly leaving a window reachable.
     ========================================================================== ]]

local ADDON = "UncappedNoDungeonFinder"
local COLOR = "|cff9CC243"

-- Windows and popups that must never appear. Superset on purpose -- see the
-- header note about names not being verifiable outside the game.
local SUPPRESS = {
    -- the Dungeon Finder itself
    "LFDParentFrame", "LFDQueueFrame", "LFDSearchStatus",
    -- the Raid Browser (owner asked for this too)
    "LFRParentFrame", "LFRQueueFrame", "LFRBrowseFrame",
    -- anything that can appear WITHOUT the player opening it
    "LFGDungeonReadyPopup", "LFGDungeonReadyDialog", "LFGDungeonReadyStatus",
    "LFDRoleCheckPopup", "LFGSearchStatus",
}

-- Globals the micro button, the keybind and other addons call to open it.
local TOGGLES = {
    "ToggleLFDParentFrame", "ToggleLFRParentFrame", "ToggleLFGParentFrame",
}

local caught, absent = {}, {}

-- Open the realm's own noticeboard. Deliberately routed through the /mlfg slash
-- handler rather than reaching into UncappedLFG's internals: that handler already
-- does the whole open -- SetTab("keystone"), show the window, then drop onto the
-- Group Finder sub-tab -- and if it ever changes this follows it for free.
--
-- ⚠ IT CHANGED ONCE AND SAID NOTHING. Until 2026-08-22 that handler ended in
--   `if Dashboard.Open then Dashboard:Open("keystone") end`, and the Dashboard has
--   never had an Open(). The guard turned a missing function into a silent no-op,
--   so this button, the I key and /mlfg itself opened nothing for six days and
--   nothing anywhere said so. Routing all three through one handler was still the
--   right call: one dead call broke three doors, and one edit fixes all three.
local function OpenOurs()
    local run = SlashCmdList and SlashCmdList["UNCAPPEDMLFG"]
    if run then
        run("")
    else
        DEFAULT_CHAT_FRAME:AddMessage(COLOR ..
            "[Uncapped]|r The Dungeon Finder is retired here -- type /mlfg for the group noticeboard.")
    end
end

local function Smother(name)
    local f = _G[name]
    if not f then
        absent[#absent + 1] = name
        return
    end

    -- Unregister first: these frames react to server LFG traffic, and the popups
    -- are the ones that can appear unprompted. With no events they cannot even
    -- decide to show themselves.
    if f.UnregisterAllEvents then f:UnregisterAllEvents() end
    if f.Hide then f:Hide() end

    -- Belt and braces for anything that calls :Show() directly. HookScript rather
    -- than SetScript so we do not stomp Blizzard's own handler -- ours runs after
    -- it and closes the frame again in the same frame, so it never paints.
    if f.HookScript then
        f:HookScript("OnShow", function(self) self:Hide() end)
    end

    caught[#caught + 1] = name
end

local function Apply()
    for _, name in ipairs(SUPPRESS) do
        Smother(name)
    end

    -- Replace the openers. This is what actually covers the `I` keybind: the
    -- binding calls the global, so overriding the global covers the key, the
    -- micro button, macros and any third-party addon at once.
    for _, fn in ipairs(TOGGLES) do
        if type(_G[fn]) == "function" then
            _G[fn] = OpenOurs
            caught[#caught + 1] = fn .. "()"
        else
            absent[#absent + 1] = fn .. "()"
        end
    end

    -- The micro button keeps its place in the menu but opens ours instead, so
    -- there is no dead button and no missing one. ⚠ Dominos re-parents this
    -- button (Dominos/menuBar.lua:44) but does not touch its scripts, so setting
    -- OnClick here survives.
    local btn = _G.LFDMicroButton
    if btn then
        btn:SetScript("OnClick", function() OpenOurs() end)
        if btn.tooltipText then
            btn.tooltipText = "Group Noticeboard"
        end
        if btn.newbieText then
            btn.newbieText = "Find other players for Mythic+ dungeons and raids."
        end
        caught[#caught + 1] = "LFDMicroButton"
    else
        absent[#absent + 1] = "LFDMicroButton"
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
-- Re-apply on ADDON_LOADED as well: if any part of the LFG UI is load-on-demand
-- in this client build it will not exist at PLAYER_LOGIN, and a one-shot pass
-- would leave exactly that piece reachable.
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        Apply()
    elseif event == "ADDON_LOADED" and type(arg1) == "string" and arg1:find("LookingFor") then
        caught, absent = {}, {}
        Apply()
    end
end)

SLASH_UNCAPPEDNODF1 = "/nodf"
SlashCmdList["UNCAPPEDNODF"] = function()
    DEFAULT_CHAT_FRAME:AddMessage(COLOR .. "[No Dungeon Finder]|r suppressed " ..
        #caught .. ", not present " .. #absent .. ":")
    DEFAULT_CHAT_FRAME:AddMessage("  caught : " ..
        (#caught > 0 and table.concat(caught, ", ") or "(none -- something is wrong)"))
    DEFAULT_CHAT_FRAME:AddMessage("  absent : " ..
        (#absent > 0 and table.concat(absent, ", ") or "(none)"))
end
