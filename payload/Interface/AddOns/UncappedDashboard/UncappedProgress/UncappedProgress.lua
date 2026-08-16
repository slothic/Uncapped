-- UncappedProgress
--
-- The Dashboard's "Progress" tab: the permanent, per-character things this realm
-- gives you that had nowhere to be read.
--
-- WHAT IT SHOWS, AND WHY EACH ONE IS HERE
--
--   SoulRush            Every dungeon you have ever cleared, how many times, and
--                       exactly what that dungeon currently pays you: movement
--                       speed, a loot multiplier, an Anima multiplier and a wider
--                       dungeon-stat roll. Two of those four are UNCAPPED and
--                       permanent, and until now the only place any of them ever
--                       appeared was a single chat line at the instant of the
--                       clear -- gone by the next login, and gone forever once
--                       the buff icon's stack count saturated at 255.
--
--   Bonus talent points A finite, per-class-capped resource earned at 1% per
--                       eligible kill. The grant line prints "(n/max)" once. At
--                       the cap the roll returns silently, so a capped player
--                       gets no feedback at all, ever.
--
--   Bonus pet talents   The same, hunters only, same silence.
--
--   Dungeon Stats       The BANKED stat ledger. StatFeed shows the live per-kill
--                       feed and the character sheet shows the applied total, but
--                       the banked ledger itself was reachable only by typing the
--                       literal string "ds" in chat to open a gossip window that
--                       appears in no help text anywhere.
--
--   Pet Dungeon Stats   [#636] The same ledger, for your pet -- one pool per pet,
--                       plus the conversion. Both halves were already live on the
--                       server; the only way to reach either was `.dspet`, an
--                       undocumented command that needs the pet SUMMONED, so a
--                       hunter could not see three of four stabled pools at all.
--
-- EVERYTHING HERE IS SERVER-AUTHORITATIVE. This addon stores nothing but which
-- rows are on screen. It holds no opinion about what a clear is worth: the
-- server sends the already-derived speed/loot/Anima/stat numbers, computed by
-- the same SoulRush functions the gameplay paths call, so retuning SoulRush.* in
-- worldserver.conf moves what the player is shown with no addon change. Same
-- rule the Anima tab follows.
--
-- ⚠ DEGRADE, NEVER ERROR. This module ships in a payload release, which means the
--   first time it ever runs is on a live player's client, against whatever server
--   build is up. So: an older server that has never heard of PRGGET simply never
--   replies, and the panel says "unavailable" after a timeout rather than sitting
--   on "Waiting..." forever or throwing. A section whose line never arrives (no
--   Dungeon_Stats table, not a hunter) renders as absent, not as zero. Every
--   frame lookup is guarded.
--
-- Wire format is documented server-side in
-- src/server/scripts/Custom/progress_comms_playerscript.cpp.
--
-- 3.3.5a client: no BackdropTemplate, no C_Timer (hence the OnUpdate timeout
-- below), arg1..argN globals on some event paths, and GetSpellInfo(id) is the
-- only reliable icon source -- not that this panel uses any icons.
--
--   /progress        open it (switches the Dashboard to the Progress tab)
--   /progress sync   force a refresh


--[[
    KitButton -- the in-house widget kit's button, with a guarded fall back to
    the raw Blizzard template.

    Guarded rather than calling UncappedUIKit directly because this addon lists
    UncappedUI as an OPTIONAL dependency: if it is absent or errored during load,
    an unguarded call is a nil index at build time and the whole window dies.
    Same shape as the fallback in UncappedKeystoneRun.

    ⚠ Resolved at FILE SCOPE on purpose. A `local UIKit` declared partway down
      and used above that line silently reads the nil GLOBAL of the same name --
      it parses fine and only errors when the window opens.
]]
local UIKit = _G.UncappedUIKit
local function KitButton(parent, label, w, h)
    if UIKit and UIKit.CreateButton then
        return UIKit.CreateButton(parent, label or "", w, h)
    end
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    if w then b:SetWidth(w) end
    if h then b:SetHeight(h) end
    b:SetText(label or "")
    return b
end

local ADDON_PIPE_PREFIX = "UNC"          -- server -> client (replies arrive here)
local TRANSPORT_PREFIX  = "REAGENTBANK"  -- client -> server (shared addon transport)

-- How long to wait for a burst before declaring the server doesn't answer. Not a
-- retry timer: one unanswered request is enough to know this server build has no
-- PRGGET handler, and hammering it would be pointless traffic. Re-opening the tab
-- asks again, which is the manual retry.
local REPLY_TIMEOUT = 6.0

local COLOR_HEAD  = "|cff9CC243"   -- section headings (the StatFeed green)
local COLOR_LABEL = "|cffffffff"
local COLOR_VALUE = "|cffffff00"
local COLOR_DIM   = "|cff888888"
local COLOR_HERE  = "|cff1eff00"   -- the SoulRush chat colour, for "you are here"
local COLOR_WARN  = "|cffff6060"

-- ---------------------------------------------------------------------------
-- Wing labels.
--
-- ★ COSMETIC MIRROR, WITH A SAFE FALLBACK -- read this before adding to it.
--
-- Most dungeons key their SoulRush counter on the map id. The shared-map ones key
-- on mapId * 100 + wingIndex, because four Scarlet Monastery wings are all map
-- 189 and each earns its own counter. The server sends the MAP name (which it
-- reads from Map.dbc and therefore cannot get wrong) and this table adds the wing
-- half of the label.
--
-- The wing tables themselves live in modules/mod-mythic-plus/src/mythic_plus.cpp
-- (WINGED_MAPS), which the core may not link against, and that list grew three
-- times in the week this was written -- Stratholme, Maraudon and Blackrock Spire
-- were all added within days of each other. So this WILL fall behind, and it is
-- built to fall behind harmlessly: an unknown wing index renders as "Wing 2", a
-- dull label rather than a wrong one, and the counts, multipliers and highlight
-- are all unaffected because none of them come from here.
--
-- If you add a winged map server-side, add its rows here at the next payload.
-- If you don't, nothing breaks.
-- ---------------------------------------------------------------------------
local WING_NAMES = {
    -- Scarlet Monastery (189)
    [18900] = "Graveyard",
    [18901] = "Library",
    [18902] = "Armory",
    [18903] = "Cathedral",
    -- Dire Maul (429)
    [42900] = "East",
    [42901] = "West",
    [42902] = "North",
    -- Stratholme (329)
    [32900] = "Living Side",
    [32901] = "Undead Side",
    -- Maraudon (349)
    [34900] = "Foulspore Cavern",
    [34901] = "Wicked Grotto",
    [34902] = "Inner Maraudon",
    -- Blackrock Spire (229)
    [22900] = "Lower Blackrock Spire",
    [22901] = "Upper Blackrock Spire",
}

-- Dungeon Stats ledger, in the wire order PRGESS sends them. The server's SELECT
-- column list and this array are one fact in two places and must stay in step --
-- but a mismatch here only mislabels a number, it cannot lose one, because the
-- line is positional and fixed-width.
local ESSENCE_STATS = {
    "Strength", "Agility", "Stamina", "Intellect",
    "Spirit", "Defense Rating", "Spell Power", "Expertise",
}

-- [#636] A pet pool has only the first five -- no Defense Rating, Spell Power or
-- Expertise. This array is positional and its ORDER IS THE WIRE ORDER, matching
-- DungeonStats::PET_STAT_COUNT and the UNIT_MOD_STAT_START order the server
-- indexes with. The INDEX (0-based, so PET_STATS[n] is stat n-1) is what DSPCONV
-- sends, so reordering this silently converts the wrong stat -- which is not a
-- mistake a player can undo. Do not reorder.
local PET_STATS = { "Strength", "Agility", "Stamina", "Intellect", "Spirit" }

-- ---------------------------------------------------------------------------
-- State. Rebuilt wholesale from each burst -- there is no incremental update, so
-- a dropped line can never leave a stale row behind. `pending` is the burst being
-- assembled and is swapped into `state` only on PRGEND, so the panel never paints
-- a half-arrived block.
-- ---------------------------------------------------------------------------
local function NewState()
    return {
        received   = false,
        -- SoulRush
        srEnabled  = true,
        srRequires = true,   -- is the Discord gate switched on at all
        srVerified = false,
        speedCap   = 100,
        lootPct    = 1,
        animaPct   = 1,
        clearsPerStat = 10,
        hereKey    = 0,
        dungeons   = {},     -- { key, count, speed, loot, anima, stat, name }
        dungeonsAll = 0,     -- server-side total; may exceed #dungeons if truncated
        -- Talents
        talEarned  = nil,    -- nil means the server sent no PRGTAL line
        talMax     = 0,
        petEarned  = nil,    -- nil means "not a hunter", not "zero"
        petMax     = 0,
        -- Dungeon Stats ledger
        essence    = nil,    -- nil means no Dungeon_Stats row / no such table
    }
end

local state   = NewState()
local pending = nil
local requested = false      -- a PRGGET is in flight
local waited  = 0            -- seconds since it went out
local timedOut = false

-- ---------------------------------------------------------------------------
-- [#636] Pet Dungeon Stats -- a SEPARATE burst with separate state.
--
-- ★ NOT folded into `pending`/`state` above, deliberately. DSP* is its own
--   request/reply pair with its own terminator, and a conversion re-sends only
--   the pet burst. Staging pet rows into the Progress accumulator would mean the
--   next PRGEND -- which knows nothing about pets -- swapped them out from under
--   the panel, so a conversion would appear to work and then blank itself the
--   moment anything else refreshed. Two bursts, two accumulators, one Render.
--
-- petSel is keyed by pet NUMBER, not by list index: the list is sorted by pooled
-- total, so converting stats can reorder it, and an index would silently move
-- the selection onto a different pet between the click and the Convert.
-- ---------------------------------------------------------------------------
local petState = { received = false, rate = 2, active = 0, pets = {} }
local petPending = nil
local petSel = nil           -- selected pet NUMBER (nil = "first in the list")
-- 0-based stat indexes into PET_STATS, matching the wire. Spirit -> Strength is
-- the default because Spirit is the one of the five that does least for most
-- pets, so it is the likeliest source; both are re-picked before anything is
-- spent, and the server validates them again regardless.
local petFrom, petTo = 4, 0
local petError = nil         -- last refusal, shown under the converter

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------
local PAD        = 18
local ROW_H      = 14
local LIST_ROWS  = 12

-- Column offsets for the SoulRush list, measured from the panel's left inset.
-- Five right-aligned numeric columns after a left-aligned name: a single
-- formatted string cannot align columns in a proportional font, so each cell is
-- its own font string with its own width.
local COL_NAME_X,  COL_NAME_W  = 0,   192
local COL_CLR_X,   COL_CLR_W   = 196, 46
local COL_SPD_X,   COL_SPD_W   = 246, 52
local COL_LOOT_X,  COL_LOOT_W  = 302, 58
local COL_ANIMA_X, COL_ANIMA_W = 364, 58
local COL_STAT_X,  COL_STAT_W  = 426, 46
local LIST_WIDTH = COL_STAT_X + COL_STAT_W          -- 472

local frame, listScroll, statusText
local lines = {}          -- pooled font strings for the static top block
local listRows = {}       -- pooled { name, clears, speed, loot, anima, stat }
local listHeader = nil
local listTop = 0         -- y offset the list was last anchored at

-- [#636] The pet converter's live widgets. Created ONCE in BuildFrame and
-- re-anchored by Render, like listScroll -- 3.3.5a cannot destroy a frame, so
-- anything built per paint leaks one set per refresh for the whole session.
local petUI = nil

-- ---------------------------------------------------------------------------
-- Formatting helpers
-- ---------------------------------------------------------------------------

-- Thousands separators. 3.3.5a has no built-in, and the banked stat ledger runs
-- to seven digits today (the largest measured is ~6.0M) against a server-side cap
-- of 1e15, which is unreadable unbroken.
local function Comma(n)
    n = tostring(math.floor(tonumber(n) or 0))
    local out = n
    while true do
        local replaced
        out, replaced = string.gsub(out, "^(-?%d+)(%d%d%d)", "%1,%2")
        if replaced == 0 then break end
    end
    return out
end

-- Past a billion, commas stop helping and start wrapping the column. The exact
-- value is still available on the row's tooltip.
local function Short(n)
    n = tonumber(n) or 0
    if n >= 1e12 then return string.format("%.2fT", n / 1e12) end
    if n >= 1e9  then return string.format("%.2fB", n / 1e9)  end
    return Comma(n)
end

-- "Scarlet Monastery -- Cathedral", or just "Scarlet Monastery" for a normal map.
-- See WING_NAMES: an unknown wing index degrades to "Wing 3" rather than being
-- dropped or guessed.
local function DisplayName(key, mapName)
    mapName = mapName or "Unknown"
    if not key or key <= 1000 then return mapName end
    local wing = WING_NAMES[key]
    if not wing then
        wing = "Wing " .. tostring(key % 100)
    end
    return mapName .. " -- " .. wing
end

-- ---------------------------------------------------------------------------
-- Comms
-- ---------------------------------------------------------------------------
local function Send(msg)
    SendAddonMessage(TRANSPORT_PREFIX, msg, "WHISPER", UnitName("player"))
end

local Render   -- forward declaration; defined below, used by the comms handler

local function Request()
    -- Don't reset `state` -- the panel keeps rendering the last good burst while
    -- a new one is in flight, which is what makes re-opening the tab feel instant.
    pending  = nil
    requested = true
    waited   = 0
    timedOut = false
    Send("PRGGET")

    -- [#636] The pet pools are a second, independent burst. Asked for here so
    -- opening the tab is still ONE user action -- but not tied to the PRG reply
    -- in any way, so a server that answers one and not the other renders the
    -- half it has instead of neither. There is deliberately no separate timeout:
    -- a server old enough to lack DSPGET lacks PRGGET too, and that one timeout
    -- already says so.
    petPending = nil
    Send("DSPGET")
end

-- Opens (or reuses) the accumulator for the burst currently arriving. The first
-- line of a burst opens a fresh one, so a second request while one is landing
-- replaces the old burst rather than merging with it.
local function Staging()
    if not pending then pending = NewState() end
    return pending
end

-- ---------------------------------------------------------------------------
-- [#636] The DSP* burst -- pet pools and the conversion reply.
--
-- Returns true when it consumed the line, so the Progress parser below never
-- sees it. Kept in its own function rather than bolted onto HandleMessage
-- because the two bursts share nothing but the transport.
-- ---------------------------------------------------------------------------
local function HandlePetMessage(text)
    local err = string.match(text, "^DSPERR:(.+)$")
    if err then
        -- "busy" is the throttle and is not worth showing anyone -- the panel is
        -- already painting real data and a refusal to repaint it changes
        -- nothing. Everything else is a REFUSED CONVERSION and is the whole
        -- reason a player is looking at this section, so it is surfaced verbatim:
        -- the server composes those sentences (not enough Spirit, already at the
        -- cap, that pet has no banked stats) and it is the only thing that knows
        -- the real numbers.
        if err ~= "busy" then petError = err end
        petPending = nil
        if frame and frame:IsShown() then Render() end
        return true
    end

    local rate, active = string.match(text, "^DSPCFG:(%d+):(%d+)$")
    if rate then
        petPending = { received = true, rate = tonumber(rate) or 2,
                       active = tonumber(active) or 0, pets = {} }
        return true
    end

    -- The pet's NAME is last and captured with (.*)$ -- it may legitimately be
    -- EMPTY (pool 0 belongs to a minion with no character_pet row to name it),
    -- and a player-chosen name can contain colons. Same rule as PRGSR's map name,
    -- except that this one also has to survive being blank.
    local num, act, s1, s2, s3, s4, s5, name =
        string.match(text, "^DSPPET:(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(.*)$")
    if num then
        -- A row before DSPCFG means a burst we never saw the head of. Open an
        -- accumulator anyway rather than dropping it: a missing config line costs
        -- a default conversion rate, a dropped row costs a whole pet.
        if not petPending then
            petPending = { received = true, rate = petState.rate or 2, active = 0, pets = {} }
        end
        tinsert(petPending.pets, {
            num    = tonumber(num) or 0,
            active = act == "1",
            name   = (name ~= "" and name) or nil,
            stats  = { tonumber(s1) or 0, tonumber(s2) or 0, tonumber(s3) or 0,
                       tonumber(s4) or 0, tonumber(s5) or 0 },
        })
        return true
    end

    -- DSPEND is the only place petState is replaced, so the panel never paints a
    -- half-arrived list. A count of zero is a real answer ("you have no pet
    -- pools"), not a dropped burst.
    if string.match(text, "^DSPEND:(%d+)$") then
        petState = petPending or { received = true, rate = 2, active = 0, pets = {} }
        petPending = nil

        -- Drop a selection whose pet is no longer in the list (stabled pet
        -- released, or a fresh character). Left dangling it would send DSPCONV
        -- for a pool the server would rightly refuse, with a confusing message.
        if petSel then
            local stillThere = false
            for _, p in ipairs(petState.pets) do
                if p.num == petSel then stillThere = true; break end
            end
            if not stillThere then petSel = nil end
        end

        if frame and frame:IsShown() then Render() end
        return true
    end

    return false
end

local function HandleMessage(text)
    if string.sub(text, 1, 3) == "DSP" then
        return HandlePetMessage(text)
    end

    -- PRGERR means the server heard us and declined (throttle). Deliberately NOT
    -- treated as "no reply": the whole point of answering a throttled request is
    -- that the client can tell a busy server apart from a server with no PRGGET
    -- handler at all. Keep the previous data on screen and stop the timeout.
    local err = string.match(text, "^PRGERR:(.+)$")
    if err then
        requested = false
        if statusText then
            if err == "busy" then
                statusText:SetText(COLOR_DIM .. "Refreshing too fast -- try again in a moment.|r")
            else
                statusText:SetText(COLOR_DIM .. err .. "|r")
            end
        end
        return
    end

    local enabled, requires, verified, cap, loot, anima, cps =
        string.match(text, "^PRGCFG:(%d+):(%d+):(%d+):(%d+):([%d%.]+):([%d%.]+):(%d+)$")
    if enabled then
        local p = Staging()
        p.srEnabled     = enabled == "1"
        p.srRequires    = requires == "1"
        p.srVerified    = verified == "1"
        p.speedCap      = tonumber(cap) or 100
        p.lootPct       = tonumber(loot) or 1
        p.animaPct      = tonumber(anima) or 1
        p.clearsPerStat = tonumber(cps) or 0
        return
    end

    local here = string.match(text, "^PRGHERE:(%d+)$")
    if here then
        Staging().hereKey = tonumber(here) or 0
        return
    end

    -- The map name is LAST and captured with (.+)$ on purpose: real map names
    -- contain colons ("Ahn'kahet: The Old Kingdom"), so anchoring the numeric
    -- head and taking the rest is the only safe split. Same rule as ANIMADEF.
    local key, count, speed, lootX, animaX, statB, name =
        string.match(text, "^PRGSR:(%d+):(%d+):(%d+):([%d%.]+):([%d%.]+):(%d+):(.+)$")
    if key then
        local p = Staging()
        tinsert(p.dungeons, {
            key   = tonumber(key),
            count = tonumber(count) or 0,
            speed = tonumber(speed) or 0,
            loot  = tonumber(lootX) or 1,
            anima = tonumber(animaX) or 1,
            stat  = tonumber(statB) or 0,
            name  = name,
        })
        return
    end

    local talEarned, talMax = string.match(text, "^PRGTAL:(%d+):(%d+)$")
    if talEarned then
        local p = Staging()
        p.talEarned = tonumber(talEarned) or 0
        p.talMax    = tonumber(talMax) or 0
        return
    end

    -- Hunters only. The server omits this line entirely for everyone else, so a
    -- nil petEarned means "not a hunter", never "no data" -- same shape SCRPET
    -- uses in the Scrolls panel.
    local petEarned, petMax = string.match(text, "^PRGPET:(%d+):(%d+)$")
    if petEarned then
        local p = Staging()
        p.petEarned = tonumber(petEarned) or 0
        p.petMax    = tonumber(petMax) or 0
        return
    end

    local s1, s2, s3, s4, s5, s6, s7, s8 =
        string.match(text, "^PRGESS:(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)$")
    if s1 then
        Staging().essence = {
            tonumber(s1), tonumber(s2), tonumber(s3), tonumber(s4),
            tonumber(s5), tonumber(s6), tonumber(s7), tonumber(s8),
        }
        return
    end

    -- PRGEND terminates the burst and is the only place `state` is replaced.
    -- Every server path ends here, including the ones with nothing to report, so
    -- "answered with nothing" and "never answered" stay distinguishable.
    local total = string.match(text, "^PRGEND:(%d+)$")
    if total then
        local p = Staging()
        p.dungeonsAll = tonumber(total) or #p.dungeons
        p.received    = true
        state     = p
        pending   = nil
        requested = false
        timedOut  = false
        if frame and frame:IsShown() then Render() end
        return
    end
end

-- ---------------------------------------------------------------------------
-- Frame construction
-- ---------------------------------------------------------------------------

-- Body lines for the static top block: a fixed pool of font strings, re-anchored
-- and re-filled by Render(). A pool rather than fresh strings per refresh --
-- 3.3.5a has no way to destroy a font string, so creating them per paint leaks
-- one set per refresh for the session.
local function AcquireLine(index, x, y, width)
    local fs = lines[index]
    if not fs then
        fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetJustifyH("LEFT")
        lines[index] = fs
    end
    fs:SetWidth(width or 460)
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + (x or 0), y)
    fs:Show()
    return fs
end

local function BuildListRow(index)
    local row = listRows[index]
    if row then return row end

    row = {}
    row.frame = CreateFrame("Button", nil, frame)
    row.frame:SetHeight(ROW_H)
    row.frame:SetWidth(LIST_WIDTH)

    local function Cell(x, w, justify)
        local fs = row.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetWidth(w)
        fs:SetJustifyH(justify)
        fs:SetPoint("TOPLEFT", row.frame, "TOPLEFT", x, 0)
        return fs
    end

    row.name   = Cell(COL_NAME_X,  COL_NAME_W,  "LEFT")
    row.clears = Cell(COL_CLR_X,   COL_CLR_W,   "RIGHT")
    row.speed  = Cell(COL_SPD_X,   COL_SPD_W,   "RIGHT")
    row.loot   = Cell(COL_LOOT_X,  COL_LOOT_W,  "RIGHT")
    row.anima  = Cell(COL_ANIMA_X, COL_ANIMA_W, "RIGHT")
    row.stat   = Cell(COL_STAT_X,  COL_STAT_W,  "RIGHT")

    row.frame:SetScript("OnEnter", function(self)
        local d = self.entry
        if not d then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(DisplayName(d.key, d.name), 1, 0.82, 0)
        GameTooltip:AddLine(string.format("%s clears banked", Comma(d.count)), 1, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("While you are inside this dungeon:", 0.8, 0.8, 0.8)
        GameTooltip:AddLine(string.format("  Movement speed  +%d%%  (out of combat)", d.speed), 0.6, 1, 0.6)
        -- [#533] Say the quiet part. WoW takes the LARGEST movement-speed effect and
        -- ignores the others -- it never adds them -- so a player carrying an unfusion
        -- speed bonus and this one gets whichever is bigger, not the sum. Reported as
        -- "speed unfusion does not stack with movement speed from dungeons cleared",
        -- which was true and had nothing anywhere telling them so.
        GameTooltip:AddLine("  (movement speed does not stack -- your largest bonus applies)", 0.5, 0.5, 0.5)
        GameTooltip:AddLine(string.format("  Loot chance     x%.2f", d.loot), 0.6, 1, 0.6)
        GameTooltip:AddLine(string.format("  Anima on clear  x%.2f", d.anima), 0.6, 1, 0.6)
        GameTooltip:AddLine(string.format("  Stat roll       +%d to both ends", d.stat), 0.6, 1, 0.6)
        GameTooltip:Show()
    end)
    row.frame:SetScript("OnLeave", function() GameTooltip:Hide() end)

    listRows[index] = row
    return row
end

local function RefreshListRows()
    if not listScroll then return end

    local data = state.dungeons or {}

    -- Update BEFORE reading the offset, the same order the Anima tab's Relayout
    -- uses. FauxScrollFrame_Update can clamp (and therefore change) the scroll
    -- position when the row count shrinks; reading the offset first would paint
    -- one frame from a position that no longer exists, and Update's own SetValue
    -- would then re-enter this function through OnVerticalScroll to fix it.
    FauxScrollFrame_Update(listScroll, #data, LIST_ROWS, ROW_H)
    local offset = FauxScrollFrame_GetOffset(listScroll) or 0

    for i = 1, LIST_ROWS do
        local row = BuildListRow(i)
        local d = data[i + offset]
        if d then
            row.frame:ClearAllPoints()
            row.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, listTop - (i - 1) * ROW_H)
            -- ⚠ ON row.frame, NOT ON row. OnEnter is handed the FRAME as `self`,
            --   and its handler reads self.entry -- stashing it on the wrapper
            --   table left self.entry nil, so the per-dungeon tooltip (clears,
            --   speed, loot, Anima, stat roll) never appeared at all. Found by a
            --   smoke run of the Prestige tab, which had copied the same shape.
            row.frame.entry = d

            -- The dungeon you are standing in right now is the one whose numbers
            -- are actually live, so it is coloured rather than merely listed.
            local isHere = (state.hereKey or 0) ~= 0 and d.key == state.hereKey
            local nameColor = isHere and COLOR_HERE or COLOR_LABEL
            row.name:SetText(nameColor .. DisplayName(d.key, d.name) .. "|r")
            row.clears:SetText(COLOR_VALUE .. Comma(d.count) .. "|r")
            row.speed:SetText(string.format("%s+%d%%|r", COLOR_LABEL, d.speed))
            row.loot:SetText(string.format("%sx%.2f|r", COLOR_LABEL, d.loot))
            row.anima:SetText(string.format("%sx%.2f|r", COLOR_LABEL, d.anima))
            row.stat:SetText(string.format("%s+%d|r", COLOR_LABEL, d.stat))
            row.frame:Show()
        else
            row.frame.entry = nil
            row.frame:Hide()
        end
    end
end

-- ---------------------------------------------------------------------------
-- [#636] Pet Dungeon Stats -- helpers
-- ---------------------------------------------------------------------------

-- The pool the converter acts on. Follows petSel when it still exists, and
-- otherwise falls back to the first row -- which is the richest, because the
-- server sorts by pooled total.
local function SelectedPet()
    local pets = petState.pets or {}
    if petSel then
        for _, p in ipairs(pets) do
            if p.num == petSel then return p end
        end
    end
    return pets[1]
end

-- "Snuffles", or "Your minion" for pool 0, which has no character_pet row to be
-- named from and is the ONLY pool every non-hunter has. Never "Pet 0".
local function PetLabel(p)
    if not p then return "" end
    if p.name then return p.name end
    if p.num == 0 then return "Your minion" end
    return "Pet #" .. tostring(p.num)
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------
function Render()
    if not frame then return end

    local i, y = 1, -12

    local function Head(text)
        local fs = AcquireLine(i, 0, y)
        fs:SetText(COLOR_HEAD .. text .. "|r")
        i, y = i + 1, y - (ROW_H + 4)
    end

    local function Row(label, value)
        local fs = AcquireLine(i, 0, y, 250)
        fs:SetText(COLOR_LABEL .. label .. "|r")
        i = i + 1
        local vs = AcquireLine(i, 256, y, 200)
        vs:SetText(COLOR_VALUE .. value .. "|r")
        i, y = i + 1, y - ROW_H
    end

    -- Two stat columns, so the eight-row ledger costs four rows of height.
    local function Pair(l1, v1, l2, v2)
        local fs = AcquireLine(i, 0, y, 110); fs:SetText(COLOR_LABEL .. l1 .. "|r"); i = i + 1
        local vs = AcquireLine(i, 114, y, 110); vs:SetText(COLOR_VALUE .. v1 .. "|r"); i = i + 1
        if l2 then
            local fs2 = AcquireLine(i, 244, y, 110); fs2:SetText(COLOR_LABEL .. l2 .. "|r"); i = i + 1
            local vs2 = AcquireLine(i, 358, y, 110); vs2:SetText(COLOR_VALUE .. v2 .. "|r"); i = i + 1
        end
        y = y - ROW_H
    end

    -- Free text, wrapped inside `width`.
    --
    -- ★ ADVANCES BY THE MEASURED HEIGHT, NOT BY ROW_H.
    --
    --   A font string with an explicit width wraps by itself, silently: it takes
    --   two lines of screen space while a caller advancing a fixed ROW_H thinks
    --   it took one, and the next element is then drawn on top of the second
    --   line. That failure is invisible until the exact sentence that is one word
    --   too long ships -- and every one of these sentences quotes live numbers
    --   from the server, so its length is not fixed at authoring time in the
    --   first place. Measuring removes the whole class of bug rather than
    --   requiring every string here to be hand-fitted forever.
    --
    --   Guarded on GetStringHeight existing and returning something sane, so a
    --   string measured before layout still advances at least one row.
    local function Note(text, width)
        local fs = AcquireLine(i, 0, y, width or 460)
        fs:SetText(COLOR_DIM .. text .. "|r")
        local h = fs.GetStringHeight and fs:GetStringHeight() or 0
        i, y = i + 1, y - math.max(ROW_H, math.ceil(tonumber(h) or 0))
    end

    -- Same measuring, but shouted. Used only for the Discord gate warning, which
    -- is the one line here a player must not miss.
    local function Warn(text, width)
        local fs = AcquireLine(i, 0, y, width or 460)
        fs:SetText(COLOR_WARN .. text .. "|r")
        local h = fs.GetStringHeight and fs:GetStringHeight() or 0
        i, y = i + 1, y - (math.max(ROW_H, math.ceil(tonumber(h) or 0)) + 4)
    end

    local function HideRest()
        for n = i, #lines do lines[n]:Hide() end
    end

    -- Every early return has to hide the LIST as well as the unused text lines --
    -- and the column header with it. Missing the header is the easy mistake: it
    -- is created once and re-anchored on each paint, so a render that returns
    -- before reaching it leaves last paint's "Dungeon / Clears / Speed ..."
    -- floating over whatever replaced the list.
    local function HideList()
        if listScroll then listScroll:Hide() end
        for n = 1, #listRows do listRows[n].frame:Hide() end
        for n = 1, #(listHeader or {}) do listHeader[n]:Hide() end
    end

    -- [#636] The pet converter's widgets are real frames, not pooled font
    -- strings, so HideRest() cannot reach them. Every early return below has to
    -- hide them explicitly or last paint's dropdowns float over whatever
    -- replaced them -- the same trap the list header already documents.
    local function HidePetUI()
        if petUI then petUI.holder:Hide() end
    end

    -- ---- not answered yet ----------------------------------------------------
    if not state.received then
        Head("Progress")
        if timedOut then
            -- The honest message. A server build without the PRGGET handler is a
            -- supported state, not a fault: this addon can ship in a payload
            -- before the matching worldserver build is deployed, and it must not
            -- read as broken while that is true.
            Note("This realm's server hasn't sent your progress. That usually means the server "
                .. "hasn't been updated for this panel yet -- nothing is wrong with your character. "
                .. "Try again with /progress sync.", 470)
        else
            Note("Waiting for the server...")
        end
        HideRest()
        HideList()
        HidePetUI()
        if statusText then statusText:SetText("") end
        return
    end

    -- ---- talents -------------------------------------------------------------
    Head("Bonus talent points")
    if state.talEarned then
        if state.talMax > 0 then
            Row("Yours", string.format("%d / %d", state.talEarned, state.talMax))
            if state.talEarned >= state.talMax then
                Note("You have every bonus talent point your class can spend.")
            end
        else
            Row("Yours", tostring(state.talEarned))
        end
    else
        Note("Not reported by the server.")
    end

    if state.petEarned then
        Row("Your pet's", string.format("%d / %d", state.petEarned, state.petMax))
        Note("Earned by you and shared by whichever pet is out. A pet family whose talent "
            .. "tree is smaller than this cannot spend all of them.", 470)
    end

    y = y - 6

    -- ---- banked dungeon stats ------------------------------------------------
    Head("Dungeon Stats banked")
    if state.essence then
        for n = 1, 8, 2 do
            Pair(ESSENCE_STATS[n], Short(state.essence[n]),
                 ESSENCE_STATS[n + 1], Short(state.essence[n + 1]))
        end
        Note("Already applied to your character sheet. Convert them with the .ds window.")
    else
        Note("No banked stats yet -- kill something in a dungeon.")
    end

    y = y - 6

    -- ---- pet dungeon stats [#636] --------------------------------------------
    --
    -- Deliberately right under the player's own banked ledger: they are the same
    -- currency earned on the same kill, and reading one without the other was
    -- most of what made the pet pool feel invisible.
    local pets = petState.pets or {}
    if not petState.received then
        -- No DSP reply at all. Say nothing rather than claiming zero -- an older
        -- server simply has no DSPGET handler, and this section not existing is
        -- the honest rendering of that.
        HidePetUI()
    elseif #pets == 0 then
        Head("Pet Dungeon Stats")
        Note("Your pet hasn't banked any stats yet. Every dungeon kill rolls for it, "
            .. "the same as it does for you -- and the pool follows the pet, so a "
            .. "stabled one keeps what it earned.", 470)
        HidePetUI()
        y = y - 6
    else
        local sel = SelectedPet()
        Head("Pet Dungeon Stats")

        -- One line, five values. A pet pool has only the first five stats (no
        -- Defense Rating, Spell Power or Expertise), so this fits on a row and
        -- does not need the two-column Pair layout the eight-stat ledger uses.
        local parts = {}
        for n = 1, 5 do
            parts[n] = string.format("%s%s|r %s%s|r",
                COLOR_DIM, string.sub(PET_STATS[n], 1, 3),
                COLOR_VALUE, Short(sel.stats[n]))
        end
        local fs = AcquireLine(i, 0, y, LIST_WIDTH)
        fs:SetText(table.concat(parts, "   "))
        i, y = i + 1, y - (ROW_H + 2)

        if petUI then
            petUI.holder:ClearAllPoints()
            petUI.holder:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
            petUI.holder:Show()
            petUI.Refresh()
        end
        y = y - (petUI and petUI.HEIGHT or 0)

        if petError then
            Warn(petError, 470)
        else
            Note(string.format("Costs %d of the source for every 1 gained. Also available as "
                .. "/dspet -- this does exactly the same thing.", petState.rate or 2), 470)
        end
        y = y - 6
    end

    -- ---- SoulRush ------------------------------------------------------------
    if not state.srEnabled then
        Head("SoulRush")
        Note("SoulRush is switched off on this realm right now.")
        HideRest()
        HideList()
        return
    end

    if state.dungeonsAll > #state.dungeons then
        Head(string.format("SoulRush  (showing %d of %d dungeons)", #state.dungeons, state.dungeonsAll))
    else
        Head(string.format("SoulRush  (%d dungeons)", state.dungeonsAll))
    end

    -- The rule, built from the numbers the server actually derived rather than
    -- from prose written here, so retuning SoulRush.* moves this sentence
    -- instead of leaving it advertising a curve the server stopped honouring.
    --
    -- ⚠ The SPEED figure is the one exception and is deliberately the literal 1.
    --   SoulRush::SpeedPct is min(completions, cap) -- one percent per clear is
    --   the shape of the function itself, not a tunable, so there is nothing to
    --   read. Only the CAP is configurable, and that is quoted. Do not reuse
    --   lootPct here: it is a different knob that merely happens to default to
    --   the same number, and using it would claim "+2% speed" the moment loot
    --   was retuned to 2.
    Note("Every clear of a dungeon banks forever, and pays out only inside THAT dungeon:", 470)
    -- [#533] Same note as the per-dungeon tooltip: speed effects do not add up, the
    -- biggest one wins. Stated here too because this is the line people read first.
    Note("Movement speed does not stack with other speed effects -- your largest applies.", 470)
    --[[ --------------------------------------------------------------------
         ★ ONLY NAME THE REWARDS THAT ARE ACTUALLY PAYING.

         This used to state loot and Anima unconditionally. Both knobs are
         currently 0 on the realm (SoulRush.LootPctPerClear,
         SoulRush.ArenaPctPerClear), so it rendered "x1.00 loot and x1.00 Anima
         per clear" -- advertising two rewards that do not exist as though they
         were features, in the same breath as one that does.

         Building the clause list from the live numbers means switching a knob
         back on restores its sentence automatically, and switching one off
         retires it, with nothing here to remember.
    ]]
    local pays = { string.format("+1%% out-of-combat speed per clear (up to +%d%%)", state.speedCap) }
    if state.lootPct and state.lootPct > 0 then
        pays[#pays + 1] = string.format("x%.2f loot", 1 + state.lootPct / 100)
    end
    if state.animaPct and state.animaPct > 0 then
        pays[#pays + 1] = string.format("x%.2f Anima", 1 + state.animaPct / 100)
    end
    if state.clearsPerStat and state.clearsPerStat > 0 then
        pays[#pays + 1] = string.format("+1 to your dungeon-stat roll every %d clears",
            state.clearsPerStat)
    end
    Note(table.concat(pays, ", ") .. ".", 470)

    -- The gate, stated only when it is actually on. "You are not verified" and
    -- "verification is not required" are different sentences, and nagging someone
    -- about a gate the server has switched off is the worse mistake -- which is
    -- why srRequires is its own wire field rather than being inferred.
    if state.srRequires and not state.srVerified then
        Warn("Your account isn't linked to Discord, so clears are NOT being counted. Type /verify to start.", 470)
    end

    y = y - 4

    -- ---- the list ------------------------------------------------------------
    if #state.dungeons == 0 then
        Note("No dungeon clears banked yet.")
        HideRest()
        HideList()
        return
    end

    -- Column header, anchored under whatever the blocks above ended up using, so
    -- a hunter (two extra rows) doesn't overlap it.
    if not listHeader then
        listHeader = {}
        local function HCell(x, w, justify, text)
            local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            fs:SetWidth(w)
            fs:SetJustifyH(justify)
            fs:SetText(text)
            tinsert(listHeader, fs)
            return fs
        end
        HCell(COL_NAME_X,  COL_NAME_W,  "LEFT",  "Dungeon")
        HCell(COL_CLR_X,   COL_CLR_W,   "RIGHT", "Clears")
        HCell(COL_SPD_X,   COL_SPD_W,   "RIGHT", "Speed")
        HCell(COL_LOOT_X,  COL_LOOT_W,  "RIGHT", "Loot")
        HCell(COL_ANIMA_X, COL_ANIMA_W, "RIGHT", "Anima")
        HCell(COL_STAT_X,  COL_STAT_W,  "RIGHT", "Stat")
    end
    local hx = { COL_NAME_X, COL_CLR_X, COL_SPD_X, COL_LOOT_X, COL_ANIMA_X, COL_STAT_X }
    for n = 1, #listHeader do
        listHeader[n]:ClearAllPoints()
        listHeader[n]:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + hx[n], y)
        listHeader[n]:Show()
    end
    y = y - (ROW_H + 2)

    HideRest()

    listTop = y
    listScroll:ClearAllPoints()
    listScroll:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
    listScroll:Show()
    RefreshListRows()
end

-- ---------------------------------------------------------------------------
-- [#636] The pet converter row.
--
-- ONE row, on purpose. The Dashboard derives its window height floor from this
-- panel's GetMinHeight, and that floor is clamped to what the screen can show
-- (DashboardButtons.SetMinContentHeight -> GetMaxHeight). Asking for more height
-- than the screen has does not scroll -- it CLIPS, and the first thing off the
-- bottom would be the SoulRush list. A second widget row costs ~30 units and the
-- budget does not have them, so the pet selector shares the row with the
-- converter rather than sitting above it.
--
-- Dropdowns are anchored to each OTHER, not to fixed x offsets:
-- UIDropDownMenu_SetWidth sets the inner text width and the frame ends up
-- noticeably wider than the number you passed, by an amount that is not worth
-- hard-coding. Relative anchoring absorbs that; a column of magic numbers would
-- have to be re-tuned by hand the first time a stat name got longer.
-- ---------------------------------------------------------------------------
local function BuildPetUI(parent)
    -- Guarded as a whole: these are stock 3.3.5a FrameXML globals and every
    -- other Uncapped panel uses them unguarded, but this file's standing rule is
    -- degrade-never-error, and a missing dropdown API should cost the converter,
    -- not the whole Progress tab.
    if not UIDropDownMenu_Initialize or not UIDropDownMenu_SetWidth then return nil end

    local ui = {}
    ui.HEIGHT = 30

    local holder = CreateFrame("Frame", nil, parent)
    holder:SetWidth(LIST_WIDTH)
    holder:SetHeight(ui.HEIGHT)
    holder:Hide()
    ui.holder = holder

    local function MakeDrop(name, width, anchorTo)
        local dd = CreateFrame("Frame", name, holder, "UIDropDownMenuTemplate")
        if anchorTo then
            dd:SetPoint("LEFT", anchorTo, "RIGHT", -14, 0)
        else
            -- The template carries a chunk of built-in left padding, so a bare 0
            -- would leave the visible control indented past everything else on
            -- the panel.
            dd:SetPoint("TOPLEFT", holder, "TOPLEFT", -16, 0)
        end
        UIDropDownMenu_SetWidth(dd, width)
        return dd
    end

    ui.petDrop = MakeDrop("UncappedProgressPetDrop", 88)
    ui.fromDrop = MakeDrop("UncappedProgressPetFrom", 66, ui.petDrop)

    local arrow = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    arrow:SetPoint("LEFT", ui.fromDrop, "RIGHT", -10, 2)
    arrow:SetText(COLOR_DIM .. "into|r")
    ui.arrow = arrow

    ui.toDrop = MakeDrop("UncappedProgressPetTo", 66, arrow)

    ui.amount = CreateFrame("EditBox", "UncappedProgressPetAmount", holder, "InputBoxTemplate")
    ui.amount:SetPoint("LEFT", ui.toDrop, "RIGHT", 2, 2)
    ui.amount:SetWidth(52)
    ui.amount:SetHeight(18)
    ui.amount:SetAutoFocus(false)
    ui.amount:SetNumeric(true)     -- whole numbers only, the same rule the server enforces
    ui.amount:SetMaxLetters(15)    -- the stat cap is 1e15
    ui.amount:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    ui.convert = KitButton(holder, "", 74, 20)
    ui.convert:SetPoint("LEFT", ui.amount, "RIGHT", 10, -2)
    
    
    ui.convert:SetText("Convert")

    local function DoConvert()
        local sel = SelectedPet()
        if not sel then return end

        local amount = tonumber(ui.amount:GetText() or "")
        if not amount or amount < 1 then
            -- Answered locally: the server would refuse this with the same
            -- sentence, and making the player wait a round trip to be told they
            -- left the box empty is worse than saying so at once.
            petError = "Enter a whole number greater than 0."
            Render()
            return
        end

        if petFrom == petTo then
            petError = "Pick two different stats."
            Render()
            return
        end

        petError = nil
        ui.amount:ClearFocus()
        -- Fire and forget. The server replies with either DSPERR (which Render
        -- surfaces verbatim) or a fresh DSPCFG/DSPPET/DSPEND burst carrying the
        -- new numbers, so there is nothing to update optimistically -- and
        -- nothing that can leave the panel claiming a conversion that did not
        -- happen.
        Send(string.format("DSPCONV:%d:%d:%d:%d", sel.num, petFrom, petTo, math.floor(amount)))
    end

    ui.convert:SetScript("OnClick", DoConvert)
    ui.amount:SetScript("OnEnterPressed", DoConvert)

    -- Repaints the three dropdown captions from current state. Called on every
    -- Render, so a burst that renamed or reordered the pets cannot leave a stale
    -- caption over a different pool.
    function ui.Refresh()
        local sel = SelectedPet()
        UIDropDownMenu_SetText(ui.petDrop, PetLabel(sel))
        UIDropDownMenu_SetText(ui.fromDrop, PET_STATS[petFrom + 1] or "?")
        UIDropDownMenu_SetText(ui.toDrop, PET_STATS[petTo + 1] or "?")
    end

    UIDropDownMenu_Initialize(ui.petDrop, function()
        for _, p in ipairs(petState.pets or {}) do
            local info = UIDropDownMenu_CreateInfo()
            -- The pet that is actually out is marked rather than sorted to the
            -- top: the list order is "richest pool first" and comes from the
            -- server, and re-sorting it here would make the panel and the wire
            -- disagree about which row is which.
            info.text = PetLabel(p) .. (p.active and (" " .. COLOR_HERE .. "(out)|r") or "")
            info.value = p.num
            info.checked = (SelectedPet() == p)
            info.func = function(self)
                petSel = self.value
                CloseDropDownMenus()
                Render()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)

    local function StatMenu(dd, get, set)
        UIDropDownMenu_Initialize(dd, function()
            for n = 1, #PET_STATS do
                local info = UIDropDownMenu_CreateInfo()
                info.text = PET_STATS[n]
                info.value = n - 1        -- 0-based, matching the wire
                info.checked = (get() == n - 1)
                info.func = function(self)
                    set(self.value)
                    CloseDropDownMenus()
                    Render()
                end
                UIDropDownMenu_AddButton(info)
            end
        end)
    end

    StatMenu(ui.fromDrop, function() return petFrom end, function(v) petFrom = v end)
    StatMenu(ui.toDrop, function() return petTo end, function(v) petTo = v end)

    return ui
end

local function BuildFrame(parent)
    if frame then return end

    frame = CreateFrame("Frame", "UncappedProgressFrame", parent or UIParent)
    frame:SetPoint("TOPLEFT"); frame:SetPoint("BOTTOMRIGHT")

    statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, 14)
    statusText:SetJustifyH("LEFT")
    statusText:SetWidth(470)
    statusText:SetText("")

    listScroll = CreateFrame("ScrollFrame", "UncappedProgressListScroll", frame, "FauxScrollFrameTemplate")
    listScroll:SetWidth(LIST_WIDTH)
    listScroll:SetHeight(LIST_ROWS * ROW_H)
    listScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, RefreshListRows)
    end)
    listScroll:EnableMouseWheel(true)
    listScroll:SetScript("OnMouseWheel", function(self, delta)
        local sb = _G["UncappedProgressListScrollScrollBar"]
        if sb then sb:SetValue(sb:GetValue() - delta * ROW_H) end
    end)
    listScroll:Hide()

    -- [#636] Built once, re-anchored by Render. Returns nil on a client whose
    -- dropdown API is missing, in which case the pet section still RENDERS (the
    -- numbers are plain font strings) and only the converter is absent -- which
    -- is a strictly better outcome than the whole tab erroring.
    petUI = BuildPetUI(frame)

    -- The reply timeout. 3.3.5a has no C_Timer, so this is an OnUpdate with an
    -- accumulator -- the standard shape on this client. It only runs while the
    -- tab is visible AND a request is outstanding, so it costs nothing the rest
    -- of the time.
    frame:SetScript("OnUpdate", function(self, elapsed)
        if not requested then return end
        waited = waited + (elapsed or 0)
        if waited < REPLY_TIMEOUT then return end
        requested = false
        timedOut  = true
        pending   = nil
        Render()
    end)

    frame:Hide()
end

-- ===========================================================================
-- Dashboard embedding
-- ===========================================================================
-- The Dashboard hosts this panel inside its own window rather than Progress
-- owning one -- see UncappedDashboard_UI.lua, which calls EmbedInto once and
-- Activate every time the Progress tab is selected.
local Progress = _G.UncappedProgress or {}
_G.UncappedProgress = Progress
Progress.UI = {}

function Progress.UI.EmbedInto(parent)
    BuildFrame(parent)
    frame:Show()
    return frame
end

function Progress.UI.Activate()
    if not frame then return end
    Render()     -- paint immediately from whatever's cached
    Request()    -- then refresh
end

-- Content-panel width: the list is 472 wide, plus PAD on the left, ~20 for the
-- scroll bar the FauxScrollFrame template creates on the right, plus the
-- embedded group's own 6px padding on each side.
function Progress.UI.GetMinWidth()
    return 472 + PAD + 20 + 12 + 8
end

-- Full WINDOW height (not content height): the static block runs to roughly
-- 300px on a hunter (the tallest case -- two extra talent rows and two notes),
-- the list is 12 * 14 = 168, the status line reserves 30, and the Dashboard's
-- own chrome above/around the content area is ~72.
--
-- [#636] +88 for the pet section: heading 18, the five-stat line 16, the
-- converter row 30, its note 16, and 8 of padding.
--
-- ⚠ THIS NUMBER IS A REQUEST AGAINST A HARD CEILING, not a guarantee.
--   DashboardButtons.SetMinContentHeight clamps it to GetMaxHeight(), i.e. what
--   the screen can actually show, and content past that is CLIPPED, not
--   scrolled -- the SoulRush list sits last, so it is what would be lost. At 658
--   there is roughly 50 units of headroom on a default-scale 768-tall UIParent.
--   Before adding anything else here, take the height out of something rather
--   than adding to this total.
function Progress.UI.GetMinHeight()
    return 300 + 88 + (LIST_ROWS * ROW_H) + 30 + 72
end

local function OpenInDashboard()
    local Dashboard = _G.UncappedDashboard
    if not Dashboard then
        DEFAULT_CHAT_FRAME:AddMessage(COLOR_HEAD .. "[Progress]|r lives inside the Dashboard -- load UncappedDashboard to use it.")
        return
    end
    Dashboard.SetTab("progress")
    if not (Dashboard.UI and Dashboard.UI.IsShown and Dashboard.UI.IsShown()) then
        Dashboard.Toggle()
    end
end

-- ===========================================================================
-- Events / slash
-- ===========================================================================
local comms = CreateFrame("Frame")
comms:RegisterEvent("CHAT_MSG_ADDON")
comms:SetScript("OnEvent", function(self, event, a1, a2)
    -- 3.3.5a hands some paths the arg1..argN globals rather than parameters.
    event = event or _G.event
    a1 = a1 or _G.arg1
    a2 = a2 or _G.arg2

    if event ~= "CHAT_MSG_ADDON" then return end
    if a1 ~= ADDON_PIPE_PREFIX or not a2 then return end
    -- Two token families land here now: PRG* (the Progress burst) and DSP* (the
    -- pet pools, #636). Cheap prefix test first -- this handler sees every
    -- server->client line on the shared UNC pipe, which in an AoE Mythic+ pull is
    -- well over a hundred a second.
    local head = string.sub(a2, 1, 3)
    if head ~= "PRG" and head ~= "DSP" then return end
    HandleMessage(a2)
end)

SLASH_UNCAPPEDPROGRESS1 = "/progress"
SlashCmdList["UNCAPPEDPROGRESS"] = function(arg)
    arg = string.lower(arg or "")
    arg = string.gsub(arg, "^%s+", "")
    arg = string.gsub(arg, "%s+$", "")
    if arg == "sync" then
        Request()
        DEFAULT_CHAT_FRAME:AddMessage(COLOR_HEAD .. "[Progress]|r Refreshing...")
    else
        OpenInDashboard()
    end
end

-- Settings page (ESC > Interface > AddOns > Uncapped > Progress). Provided by the
-- shared UncappedUI widget library (UncappedOptions addon); guarded so the page
-- just doesn't appear if that addon is missing.
if UncappedUI then
    local _, L = UncappedUI.CreatePanel("Progress",
        "The permanent things this realm has given your character: SoulRush dungeon mastery, bonus talent points and your banked Dungeon Stats.")

    L:Header("Progress")
    L:Button("Open Progress", OpenInDashboard, 180)
    -- ⚠ Static copy, written before `state` exists, so it cannot derive itself the
    --   way the in-panel line does. It therefore names only what SoulRush pays that
    --   is NOT currently switched off: loot, Anima and the wider stat roll are all
    --   at 0 on the realm right now (SoulRush.LootPctPerClear / .ArenaPctPerClear /
    --   .StatPctPerClear). Promising them here made the panel read as though three
    --   rewards existed that do not. If any of those are turned back on, say so here
    --   again -- and check the derived line in Render(), which handles it on its own.
    L:Note("SoulRush banks every dungeon clear forever and pays it back only inside that "
        .. "dungeon: out-of-combat movement speed, and a bonus dungeon-stat point for "
        .. "every ten clears. This is where you read those numbers.", 48)
    L:Note("Also shows how many bonus talent points you and your pet have earned against "
        .. "your class maximum, and the stat ledger you have banked from kills. "
        .. "Also available with /progress.", 48)
    L:Note("Your pet's own banked stats are here too, one pool per pet -- including "
        .. "stabled ones you do not have out -- and you can convert between them from "
        .. "the same row. The /dspet command does the same thing.", 48)
end
