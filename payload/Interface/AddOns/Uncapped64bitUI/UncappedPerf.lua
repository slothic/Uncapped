-- ===========================================================================
-- UncappedPerf -- combat effect density, and a way to measure it
-- ===========================================================================
--
-- WHY THIS EXISTS
--
-- Report #675: "client is laggy when doing big pulls. It might be the number of
-- effects, or something else, not sure." Narrowed by the owner to the thing that
-- actually correlates: "it's when there's a lot of effects on screen."
--
-- Two halves answer that, and only one of them lives here.
--
-- The server half is the root cause and shipped alongside this: Multicast fires
-- up to ten extra copies of a spell, and every copy used to play its own full
-- visual on targets that were already covered in the same effect. One AoE press
-- against thirty mobs drew up to 330 impact visuals. Copies past the second are
-- now cast silently -- same damage, same auras, same procs, no second visual.
-- See MULTICAST_VISIBLE_COPIES in multicast_spellscript.cpp.
--
-- This half is what the player can do about the effects that are LEGITIMATE. A
-- thirty-mob pull on a realm where everyone is running trillion-scale AoE is
-- always going to be a lot of particles, and the client has knobs for exactly
-- that which most players have never opened the video panel to find. All this
-- does is put them somewhere findable, with presets, and a frame-rate meter so
-- the choice can be made on evidence rather than on feel.
--
-- NOTHING HERE IS FORCED ON ANYONE. No preset is applied automatically and no
-- CVar is touched at load. A player who never opens this panel is in exactly the
-- state they were in before it existed.
--
-- ⚠ ON THE CVAR NAMES. All five were verified present in this client's binary
-- before any of this was written -- they are not guesses carried over from a
-- later expansion. What is NOT verified is the accepted RANGE of each, which is
-- why "full quality" restores a captured baseline rather than writing a number
-- this file invented: see CaptureBaseline below.

local ADDON_COLOUR = "|cff40ff40[Uncapped]|r"

local function Msg(text)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(ADDON_COLOUR .. " " .. text) end
end

local function DB()
    Uncapped64bitUIDB = Uncapped64bitUIDB or {}
    Uncapped64bitUIDB.perf = Uncapped64bitUIDB.perf or {}
    return Uncapped64bitUIDB.perf
end

-- ---------------------------------------------------------------------------
-- The CVars
-- ---------------------------------------------------------------------------
-- Ordered loudest-first: the top two are what a spell-effect pull is made of,
-- the bottom three are scenery that costs frames in the same places.
local PERF_CVARS = {
    { cvar = "spellEffectLevel",   label = "Spell effect detail",  low = "0",  mid = "1"  },
    { cvar = "particleDensity",    label = "Particle density",     low = "0.3", mid = "0.6" },
    { cvar = "projectedTextures",  label = "Projected textures",   low = "0",  mid = "0"  },
    { cvar = "weatherDensity",     label = "Weather density",      low = "0",  mid = "1"  },
    { cvar = "groundEffectDensity",label = "Ground clutter",       low = "16", mid = "48" },
}

--[[ The baseline is CAPTURED, never invented.

     "High quality" has to put a player back exactly where they started, and this
     file does not know what that was: the ranges these CVars accept are not
     documented anywhere we can check, the defaults differ between video presets,
     and a player may have tuned them by hand years ago. Writing a number of our
     own choosing would quietly overwrite that and call it a restore.

     So the first time a preset is applied -- and only then -- whatever is
     currently set is saved. Restoring writes those values back. If the capture
     is somehow missing, GetCVarDefault is asked, and if that has nothing either
     the CVar is left alone rather than guessed at. ]]
local function CaptureBaseline()
    local db = DB()
    if db.baseline then return end

    local baseline = {}
    for _, entry in ipairs(PERF_CVARS) do
        local ok, value = pcall(GetCVar, entry.cvar)
        if ok and value ~= nil then baseline[entry.cvar] = tostring(value) end
    end
    db.baseline = baseline
end

local function ApplyCVar(cvar, value)
    if value == nil then return false end
    -- pcall'd individually rather than around the whole loop: a client that
    -- rejects one of these must still get the other four.
    local ok = pcall(SetCVar, cvar, value)
    return ok and true or false
end

local PRESETS = {
    performance = { key = "low",  label = "Best performance" },
    balanced    = { key = "mid",  label = "Balanced" },
    quality     = { key = nil,    label = "Full quality" },
}

local function ApplyPreset(name)
    local preset = PRESETS[name]
    if not preset then return end

    CaptureBaseline()
    local db = DB()
    local applied, refused = 0, 0

    for _, entry in ipairs(PERF_CVARS) do
        local value
        if preset.key then
            value = entry[preset.key]
        else
            value = db.baseline and db.baseline[entry.cvar]
            if value == nil then
                local ok, def = pcall(GetCVarDefault, entry.cvar)
                if ok then value = def end
            end
        end

        if ApplyCVar(entry.cvar, value) then applied = applied + 1 else refused = refused + 1 end
    end

    db.preset = name

    if refused > 0 then
        Msg(preset.label .. " applied to " .. applied .. " setting(s); this client refused "
            .. refused .. ". The rest are in effect.")
    else
        Msg(preset.label .. " applied. Effects change immediately -- no reload needed.")
    end
end

-- ---------------------------------------------------------------------------
-- The meter
-- ---------------------------------------------------------------------------
-- A preset is only worth anything if the player can tell whether it helped, and
-- "it feels smoother" is not a measurement. This samples every frame for a fixed
-- window and reports the three numbers that describe a pull:
--
--   average    what the fight felt like overall
--   worst 1%   the number that actually reads as "laggy" -- an average of 45 with
--              a floor of 8 is a stutter, and only the floor says so
--   longest    the single worst frame, in milliseconds. This is what #666's
--              "frame drop every time it auto consumes" is made of.
local sampler = CreateFrame("Frame")
local sampling, sampleEnds, frames, worstMs, elapsedTotal = false, 0, nil, 0, 0

local function ReportSample()
    sampling = false
    sampler:SetScript("OnUpdate", nil)

    local n = frames and #frames or 0
    if n < 2 then
        Msg("not enough frames to report. Try again while the client is actually drawing.")
        return
    end

    table.sort(frames)   -- ascending frame TIMES, so the worst are at the end

    local total = 0
    for i = 1, n do total = total + frames[i] end

    -- Worst 1% of frames, floored at one frame so a short sample still reports.
    local tailCount = math.max(1, math.floor(n * 0.01))
    local tail = 0
    for i = n - tailCount + 1, n do tail = tail + frames[i] end

    local avgFps  = (total > 0) and (n / total) or 0
    local lowFps  = (tail > 0) and (tailCount / tail) or 0

    Msg(string.format("%.1fs sample: |cffffd100%.0f fps|r average, |cffffd100%.0f fps|r worst 1%%, "
        .. "longest frame |cffffd100%.0f ms|r.", elapsedTotal, avgFps, lowFps, worstMs * 1000))
    Msg("Compare against another pull after |cffffff00/uperf fast|r to see whether effects are the cost.")
end

local function StartSample(seconds)
    if sampling then
        Msg("already measuring -- wait for the report.")
        return
    end

    seconds = tonumber(seconds) or 10
    if seconds < 3 then seconds = 3 elseif seconds > 60 then seconds = 60 end

    frames, worstMs, elapsedTotal = {}, 0, 0
    sampling, sampleEnds = true, seconds

    sampler:SetScript("OnUpdate", function(_, dt)
        dt = dt or arg1 or 0
        -- A zero or negative delta is the client reporting nothing useful (it
        -- happens on the frame a load screen clears); counting it would divide
        -- into an infinite frame rate.
        if dt <= 0 then return end
        frames[#frames + 1] = dt
        if dt > worstMs then worstMs = dt end
        elapsedTotal = elapsedTotal + dt
        if elapsedTotal >= sampleEnds then ReportSample() end
    end)

    Msg("measuring for " .. seconds .. " seconds -- keep fighting.")
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------
SLASH_UNCAPPEDPERF1 = "/uperf"
SlashCmdList["UNCAPPEDPERF"] = function(msg)
    -- Named `input`, not `arg`: `arg` is Lua 5.1's varargs table, and shadowing it
    -- inside a function that later grows a `...` is a bug waiting to be written.
    local input = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local word, rest = input:match("^(%S*)%s*(.*)$")

    if word == "fast" or word == "low" then
        ApplyPreset("performance")
    elseif word == "balanced" or word == "mid" then
        ApplyPreset("balanced")
    elseif word == "full" or word == "quality" or word == "restore" then
        ApplyPreset("quality")
    elseif word == "measure" or word == "test" then
        StartSample(rest)
    elseif word == "" then
        Msg("current effect settings:")
        for _, entry in ipairs(PERF_CVARS) do
            local ok, value = pcall(GetCVar, entry.cvar)
            DEFAULT_CHAT_FRAME:AddMessage(string.format("   %-22s |cffffd100%s|r",
                entry.label, (ok and value ~= nil) and tostring(value) or "unavailable"))
        end
        Msg("|cffffff00/uperf fast|r reduce effects  ·  |cffffff00/uperf balanced|r  ·  "
            .. "|cffffff00/uperf full|r restore  ·  |cffffff00/uperf measure|r check your frame rate")
    else
        Msg("unknown option \"" .. word .. "\". Use fast, balanced, full or measure.")
    end
end

-- ---------------------------------------------------------------------------
-- Options panel
-- ---------------------------------------------------------------------------
if UncappedUI then
    local panel, L = UncappedUI.CreatePanel("Performance",
        "Combat effect density, for big pulls.")

    -- ★ [AN-04] Published so /fct can land here. The combat-text options page was
    --   deleted on 2026-08-31 -- it configured a renderer retired in August -- and this
    --   page owns the switch that actually matters for damage numbers, so the slash
    --   command redirects rather than dying. Uncapped64bitUI.lua resolves this global at
    --   CALL time, because that file loads BEFORE this one.
    Uncapped64bitUI_PerfPanel = panel

    L:Header("Combat effects")
    L:Note("A big pull on this realm draws a lot of spell effects at once, and on most machines that "
        .. "is what costs frames -- not the mobs, the effects over them. These are the client's own "
        .. "graphics settings, gathered here so you do not have to go hunting for them. Nothing is "
        .. "changed until you press one, and Full quality puts back exactly what you had.", 62)

    L:Button("Best performance", function() ApplyPreset("performance") end, 200)
    L:Button("Balanced", function() ApplyPreset("balanced") end, 200)
    L:Button("Full quality (restore)", function() ApplyPreset("quality") end, 200)

    L:Gap(6)
    L:Header("Damage numbers")
    --[[ ⚠ DELIBERATELY NOT PART OF ANY PRESET.

         These are the numbers that fly off a unit's body, and on a thirty-mob
         pull they are genuinely a large share of what is moving on screen -- every
         copy of every hit on every target draws one. Turning them off is the
         single biggest thing a player can do about that.

         It is also the thing this realm is FOR. The whole 64-bit combat-text
         stack exists so those numbers show a real trillion-scale hit instead of
         a clamped 2.1B, and quietly switching them off inside a button labelled
         "best performance" would hand someone a faster client by removing the
         feature they came for -- and they would have no idea which button did it.

         So it is its own checkbox, with the cost written next to it, and the
         player decides. ]]
    L:Note("These are the numbers over each enemy's body. They are the most expensive thing on screen "
        .. "during a big pull, because every hit on every target draws one -- but they are also how you "
        .. "read a fight here. Turn them off only if the presets above were not enough.", 50)

    --[[ ★★ [#447] THESE TWO BOXES WERE BOUND TO CVARS THIS CLIENT DOES NOT HAVE.
         `floatingCombatTextCombatDamage` / `...Healing` are Cataclysm-era names. This
         client's engine floaters are gated by CombatDamage / CombatHealing /
         PetMeleeDamage / PetSpellDamage -- verified against the shipped binary
         (Client\ChromieCraft_3.3.5a\UncappedClient.dat: the floatingCombatText* names
         are absent, the four below are present). See NativeCT/notes/CLIENT_MAP.md.

         With the wrong name GetCVar returns nil, so the box rendered permanently
         UNCHECKED, and SetCVar threw straight into the pcall, so clicking it did
         nothing. That is a dead switch sitting directly under the one feature this
         realm exists for -- and since 2026-08-08 the engine floaters are the ONLY
         renderer left (this addon's own was retired then and deleted 2026-08-31, and
         CT_ApplyBlizzardSurfaces pins SHOW_COMBAT_TEXT to "0"), so a player whose
         CombatDamage happened to be 0 had no combat numbers at all and no working
         control anywhere to bring them back.

         Pet damage rides along with the enemy-damage box because it is the same
         decision to the player, and leaving it out means two more silent CVars. ]]
    L:Check("Show damage numbers over enemies",
        function() local ok, v = pcall(GetCVar, "CombatDamage") return ok and v == "1" end,
        function(v)
            pcall(SetCVar, "CombatDamage",   v and "1" or "0")
            pcall(SetCVar, "PetMeleeDamage", v and "1" or "0")
            pcall(SetCVar, "PetSpellDamage", v and "1" or "0")
            -- ★ The player has said what they want out loud. The #926 repair in
            --   Uncapped64bitUI.lua (ApplyFloatingCombatTextRepair) reads this and stands
            --   down -- a one-shot that overrides a stated choice is not a repair, it is
            --   the addon arguing with the options panel. [audit 2026-08-22 AN-02]
            DB().fctChoice = true
        end)

    L:Check("Show healing numbers",
        function() local ok, v = pcall(GetCVar, "CombatHealing") return ok and v == "1" end,
        function(v)
            pcall(SetCVar, "CombatHealing", v and "1" or "0")
            DB().fctChoice = true
        end)

    L:Note("You can also hide only the SMALL hits and keep the big ones, which costs you nothing you "
        .. "were reading anyway: |cffffff00/hideunder 500m|r. That one is filtered on the server, so "
        .. "those packets are never sent to you at all.", 40)

    L:Gap(6)
    L:Header("Measure it")
    L:Note("Ten seconds of frame timings, reported in chat: your average, your worst 1% (the number "
        .. "that actually reads as lag), and your single longest frame. Start it during a pull, then "
        .. "run it again after changing a preset -- that comparison is worth more than any guess, "
        .. "and it is exactly what we need in a bug report about frame rate.", 62)

    L:Button("Measure 10 seconds", function() StartSample(10) end, 200)

    UncappedPerfPanel = panel
end
