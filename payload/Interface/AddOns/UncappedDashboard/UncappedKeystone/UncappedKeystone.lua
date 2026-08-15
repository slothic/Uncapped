--[[ ==========================================================================
     UncappedKeystone -- the Dashboard's "M+ Rewards" tab.

     Owner request, 2026-08-11: "a place to preview rewards, with + and minus and
     picking a dungeon/raid".

     WHAT IT IS FOR
     --------------
     The Mythic+ payout is two terms multiplied together:

         reward  =  CLEAR SIZE  x  KEY BONUS

     CLEAR SIZE is how much dungeon you kill, measured in Utgarde Keeps -- so a
     long instance pays more than a short one, and a raid pays exactly what a
     dungeon of the same size pays. KEY BONUS doubles every few keystone levels.

     Both halves are legible on their own, and the whole point of this panel is
     that a player can SEE the second one compound. Pick a map, hold down [+],
     watch the numbers pull away. That is the argument for pushing, made with the
     player's own numbers instead of a patch note.

     WHERE THE NUMBERS COME FROM
     ---------------------------
     ★ NOTHING HERE IS A COPY OF THE FORMULA'S CONSTANTS. On open, the client
       asks MRWQ and the server replies with the anchor, the Anima rate and the
       doubling interval it is actually paying with, plus one CLEAR SIZE per map
       computed from that map's own spawn table. This addon multiplies. So a
       `.reload config` retune moves this panel too, and the panel cannot drift
       into advertising a payout the server stopped making -- which is exactly
       the bug the keystone NPC had, quoting gold that was never granted.

     ⚠ IT IS AN ESTIMATE OF A FULL CLEAR, AND IT SAYS SO ON SCREEN. The server
       pays for what you actually killed; this quotes the enemy-forces gate plus
       every boss, which is the least a completed run kills. Clear more than the
       gate and you earn more than the panel showed -- never less.

     ⚠ DEGRADE, NEVER ERROR. This ships in a payload release and first runs on a
       live client against whatever server build is up. An older server never
       answers MRWQ, and the panel says so after a timeout instead of sitting on
       "Loading..." forever.

     3.3.5a: no BackdropTemplate, no C_Timer (hence the OnUpdate timeout), and
     arg1..argN globals on some event paths.

       /keystone        open it
       /keystone sync   force a refresh
     ========================================================================== ]]

local ADDON_PIPE_PREFIX = "UNC"          -- server -> client
local TRANSPORT_PREFIX  = "REAGENTBANK"  -- client -> server (shared transport)

local REPLY_TIMEOUT = 6.0

local COLOR_HEAD  = "|cff9CC243"
local COLOR_LABEL = "|cffffffff"
local COLOR_VALUE = "|cffffff00"
local COLOR_DIM   = "|cff888888"
local COLOR_GOOD  = "|cff1eff00"

local Keystone = _G.UncappedKeystone or {}
_G.UncappedKeystone = Keystone
Keystone.UI = {}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
-- Filled from the wire. `tuning` stays nil until the server answers, and every
-- render path checks it -- that is what makes the no-answer case a message
-- rather than an arithmetic error on nil.
local tuning            -- { anchor, animaRate, doubleEvery, hotzone }
local maps = {}         -- array of { id, size, raid, name }
local pending = false   -- a request is in flight
local requestedAt = 0
local answered = false

local selected          -- index into `maps`
local level = 10
local filter = "all"    -- all | dungeon | raid

local frame, listScroll, listButtons, statusText
local previewTexts = {}
local levelText

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function Comma(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

-- Payouts here run from tens to tens of millions. A raw comma'd integer stops
-- being readable somewhere around seven digits, and the exact ones digit of a
-- 12-million Anima payout is not information anybody wants.
local function Abbrev(n)
    n = tonumber(n) or 0
    if n >= 1e9 then return string.format("%.2fB", n / 1e9) end
    if n >= 1e6 then return string.format("%.2fM", n / 1e6) end
    return Comma(n)
end

local function Send(msg)
    if not SendAddonMessage then return end
    SendAddonMessage(TRANSPORT_PREFIX, msg, "WHISPER", UnitName("player"))
end

local function Request()
    if pending then return end
    pending = true
    answered = false
    requestedAt = GetTime()
    Send("MRWQ")
end

-- The KEY BONUS, exactly as the server computes it.
local function KeyBonus(lvl)
    if not tuning then return 1 end
    local per = tuning.doubleEvery
    if not per or per <= 0 then per = 5 end
    return 2 ^ ((math.max(lvl, 1) - 1) / per)
end

local function FilteredMaps()
    if filter == "all" then return maps end
    local out = {}
    for _, m in ipairs(maps) do
        if (filter == "raid") == (m.raid) then out[#out + 1] = m end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Wire
-- ---------------------------------------------------------------------------
local function HandleMessage(msg)
    if msg == "MRWE" then
        pending = false
        answered = true
        -- Longest first is the useful default: the panel's whole argument is that
        -- size and depth both pay, and opening on the biggest instance makes the
        -- size half visible before the player touches anything.
        table.sort(maps, function(a, b)
            if a.size ~= b.size then return a.size > b.size end
            return (a.name or "") < (b.name or "")
        end)
        if not selected and #maps > 0 then selected = 1 end
        if Keystone.Render then Keystone.Render() end
        return
    end

    local head = string.match(msg, "^MRWH:(.+)$")
    if head then
        local a, r, d, h = string.match(head, "^([%d%.%-]+):([%d%.%-]+):([%d%.%-]+):([%d%.%-]+)$")
        if a then
            tuning = {
                anchor      = tonumber(a) or 24,
                animaRate   = tonumber(r) or 175,
                doubleEvery = tonumber(d) or 5,
                hotzone     = tonumber(h) or 2,
            }
            -- A fresh header means a fresh table; without this a second sync
            -- would append every map a second time.
            maps = {}
            selected = nil
        end
        return
    end

    local body = string.match(msg, "^MRWM:(.+)$")
    if not body then return end

    for row in string.gmatch(body, "([^;]+)") do
        local id, size, raid, name = string.match(row, "^(%d+),([%d%.%-]+),(%d+),(.*)$")
        if id then
            maps[#maps + 1] = {
                id   = tonumber(id),
                size = tonumber(size) or 0,
                raid = (raid == "1"),
                name = name ~= "" and name or ("Map " .. id),
            }
        end
    end
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------
local ROW_H, ROWS = 16, 18

local function RenderList()
    if not listButtons then return end
    local list = FilteredMaps()
    local offset = FauxScrollFrame_GetOffset(listScroll) or 0

    FauxScrollFrame_Update(listScroll, #list, ROWS, ROW_H)

    for i = 1, ROWS do
        local btn = listButtons[i]
        local idx = i + offset
        local m = list[idx]
        if m then
            local tag = m.raid and (COLOR_DIM .. "[R]|r ") or ""
            local isSel = (maps[selected] == m)
            btn.text:SetText(string.format("%s%s%s|r", tag,
                isSel and COLOR_VALUE or COLOR_LABEL, m.name))
            btn.mapRef = m
            btn:Show()
            if isSel then btn.hl:Show() else btn.hl:Hide() end
        else
            btn.mapRef = nil
            btn:Hide()
        end
    end
end

local function SetLine(key, text)
    if previewTexts[key] then previewTexts[key]:SetText(text) end
end

function Keystone.Render()
    if not frame then return end

    if levelText then
        levelText:SetText(string.format("%s+%d|r", COLOR_VALUE, level))
    end

    RenderList()

    if not tuning then
        SetLine("map", COLOR_DIM .. (answered and "No map data." or "Loading...") .. "|r")
        for _, k in ipairs({ "size", "bonus", "sacks", "anima", "note", "compare" }) do SetLine(k, "") end
        return
    end

    local m = maps[selected]
    if not m then
        SetLine("map", COLOR_DIM .. "Pick a dungeon or raid on the left.|r")
        for _, k in ipairs({ "size", "bonus", "sacks", "anima", "note", "compare" }) do SetLine(k, "") end
        return
    end

    local bonus = KeyBonus(level)
    local sacks = math.max(1, math.floor(tuning.anchor * m.size * bonus + 0.5))
    local anima = math.max(1, math.floor(tuning.animaRate * m.size * bonus + 0.5))

    SetLine("map", string.format("%s%s|r  %s", COLOR_HEAD, m.name,
        m.raid and (COLOR_DIM .. "(raid)|r") or (COLOR_DIM .. "(dungeon)|r")))

    SetLine("size", string.format("%sClear size|r    %s%.2f|r  %s(1.00 = one Utgarde Keep)|r",
        COLOR_LABEL, COLOR_VALUE, m.size, COLOR_DIM))
    SetLine("bonus", string.format("%sKey bonus|r     %sx%.1f|r  %s(doubles every %d levels)|r",
        COLOR_LABEL, COLOR_VALUE, bonus, COLOR_DIM, math.floor(tuning.doubleEvery + 0.5)))

    SetLine("sacks", string.format("%sSacks|r         %s%s|r", COLOR_LABEL, COLOR_GOOD, Abbrev(sacks)))
    SetLine("anima", string.format("%sAnima|r         %s%s|r  %s(before quest / SoulRush bonuses)|r",
        COLOR_LABEL, COLOR_GOOD, Abbrev(anima), COLOR_DIM))

    -- The comparison IS the feature. A number on its own does not tell anyone
    -- whether pushing is worth it; "x4.0 what a +10 pays" does.
    local ref = 10
    if level ~= ref then
        local refBonus = KeyBonus(ref)
        SetLine("compare", string.format("%sThat is x%.1f what a +%d on this map pays.|r",
            COLOR_HEAD, bonus / refBonus, ref))
    else
        SetLine("compare", COLOR_DIM .. "Move the key up and down to compare.|r")
    end

    SetLine("note", COLOR_DIM ..
        "Estimate for a full clear (required trash + every boss). Clear more, earn more.|r")
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
local function StepLevel(delta)
    level = math.max(1, math.min(200, level + delta))
    Keystone.Render()
end

local function MakeButton(parent, label, w, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetWidth(w)
    b:SetHeight(22)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

local function BuildFrame(parent)
    if frame then
        frame:SetParent(parent)
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", 0, 0)
        frame:SetPoint("BOTTOMRIGHT", 0, 0)
        return frame
    end

    frame = CreateFrame("Frame", "UncappedKeystoneFrame", parent)
    frame:SetPoint("TOPLEFT", 0, 0)
    frame:SetPoint("BOTTOMRIGHT", 0, 0)

    --[[ ----------------------------------------------------------------------
         SUB-TABS -- and why Mythic+ gets exactly ONE dashboard tab.

         Owner ruling 2026-08-12: the whole keystone system moves into the
         Dashboard. It cannot move as four tabs. UncappedDashboardConfig.lua
         documents the nav column's budget: 15 tabs today, ONE slot left, 17
         clips off the bottom of the window -- and the 16th alone drops the
         window's zoom ceiling to ~1.01 for everyone, because REQUIRED_HEIGHT is
         in window units and the player's zoom multiplies it.

         So everything M+ lives behind this strip instead: Your Keystone, Reward
         Preview, and later Affixes / History / Leaderboard. Costs zero nav slots
         and leaves the zoom ceiling where it is.

         ★ ADD SECTIONS HERE, NOT TO Core.TABS.
      ------------------------------------------------------------------------ ]]
    local SUBTAB_H = 26

    local sections, subButtons = {}, {}
    local activeSection

    -- Forward-declared so the buttons can call it before the sections table is
    -- populated at the bottom of this function.
    local ShowSection

    local strip = CreateFrame("Frame", nil, frame)
    strip:SetPoint("TOPLEFT", 0, 0)
    strip:SetPoint("TOPRIGHT", 0, 0)
    strip:SetHeight(SUBTAB_H)

    local SUBTABS = {
        { key = "keystone", label = "Your Keystone" },
        { key = "lfg",      label = "Group Finder" },   -- [#605]
        { key = "rewards",  label = "Reward Preview" },
    }

    --[[
        ⚠ HOUSE WIDGET KIT, NOT UIPanelButtonTemplate.

        These started as raw Blizzard buttons and looked like it -- red and boxy
        against a Dashboard where every other control is UncappedUI. The kit also
        gives a proper SELECTED state (SetButtonActive), which a tab strip needs
        and the Blizzard template does not have.

        ★ Fallback kept on purpose: UncappedUI is a separate addon in the payload.
          With it disabled this degrades to plain buttons rather than erroring on a
          nil global, on the Dashboard's most-used tab.
    ]]
    local sx = 8
    for _, spec in ipairs(SUBTABS) do
        local w = max(104, strlen(spec.label) * 9)
        local b
        if UncappedUIKit and UncappedUIKit.CreateButton then
            b = UncappedUIKit.CreateButton(strip, spec.label, w, 22)
        else
            b = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
            b:SetWidth(w)
            b:SetHeight(22)
            b:SetText(spec.label)
        end
        b:SetPoint("TOPLEFT", sx, -2)
        b:SetScript("OnClick", function() ShowSection(spec.key) end)
        subButtons[spec.key] = b
        sx = sx + w + 8   -- +8, not +4: the old gap let the labels crowd together
    end

    -- Shows one section and hides the rest. A section is just a list of regions,
    -- so a FontString parented straight to `frame` is as hideable as a Frame is --
    -- which matters because the reward preview's heading and formula line are
    -- exactly that.
    ShowSection = function(key)
        if not sections[key] then return end
        activeSection = key

        for k, parts in pairs(sections) do
            local on = (k == key)
            for _, region in ipairs(parts) do
                if region then
                    if on then region:Show() else region:Hide() end
                end
            end
            -- Selected state via the kit (the gold "current tab" look). Disable()
            -- was the first attempt and it just greys the label out, which reads
            -- as "this tab is unavailable" rather than "you are on this tab".
            if subButtons[k] then
                if UncappedUIKit and UncappedUIKit.SetButtonActive then
                    UncappedUIKit.SetButtonActive(subButtons[k], on)
                elseif on then
                    subButtons[k]:Disable()
                else
                    subButtons[k]:Enable()
                end
            end
        end

        -- Let a section refresh itself as it comes into view, so switching to it
        -- never shows a stale number.
        if key == "keystone" and _G.UncappedKeystoneRun and _G.UncappedKeystoneRun.UI then
            _G.UncappedKeystoneRun.UI.Activate()
        elseif key == "lfg" and _G.UncappedLFG and _G.UncappedLFG.UI then
            _G.UncappedLFG.UI.Activate()
        elseif key == "rewards" then
            Keystone.Render()
            Request()
        end
    end
    Keystone.ShowSection = function(key) if ShowSection then ShowSection(key) end end
    Keystone.CurrentSection = function() return activeSection or "keystone" end

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 8, -6 - SUBTAB_H)
    title:SetText("Mythic+ Reward Preview")

    local formula = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    formula:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    formula:SetText(COLOR_DIM .. "reward = clear size x key bonus|r")

    -- ---- left: map list ----
    local listBg = CreateFrame("Frame", nil, frame)
    listBg:SetPoint("TOPLEFT", formula, "BOTTOMLEFT", 0, -28)
    listBg:SetWidth(210)
    listBg:SetHeight(ROWS * ROW_H + 8)

    local filterAll, filterDun, filterRaid
    local function SetFilter(f)
        filter = f
        FauxScrollFrame_SetOffset(listScroll, 0)
        if listScroll.ScrollBar then listScroll.ScrollBar:SetValue(0) end
        Keystone.Render()
    end
    filterAll  = MakeButton(frame, "All", 56, function() SetFilter("all") end)
    filterDun  = MakeButton(frame, "Dungeons", 76, function() SetFilter("dungeon") end)
    filterRaid = MakeButton(frame, "Raids", 60, function() SetFilter("raid") end)
    filterAll:SetPoint("TOPLEFT", formula, "BOTTOMLEFT", 0, -2)
    filterDun:SetPoint("LEFT", filterAll, "RIGHT", 2, 0)
    filterRaid:SetPoint("LEFT", filterDun, "RIGHT", 2, 0)

    listScroll = CreateFrame("ScrollFrame", "UncappedKeystoneList", listBg, "FauxScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", 0, -4)
    listScroll:SetWidth(190)
    listScroll:SetHeight(ROWS * ROW_H)
    listScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, RenderList)
    end)

    listButtons = {}
    for i = 1, ROWS do
        local b = CreateFrame("Button", nil, listBg)
        b:SetWidth(188)
        b:SetHeight(ROW_H)
        if i == 1 then
            b:SetPoint("TOPLEFT", listScroll, "TOPLEFT", 0, 0)
        else
            b:SetPoint("TOPLEFT", listButtons[i - 1], "BOTTOMLEFT", 0, 0)
        end

        local hl = b:CreateTexture(nil, "BACKGROUND")
        hl:SetAllPoints(b)
        hl:SetTexture(0.35, 0.28, 0.62, 0.55)
        hl:Hide()
        b.hl = hl

        local t = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        t:SetPoint("LEFT", 4, 0)
        t:SetJustifyH("LEFT")
        t:SetWidth(180)
        b.text = t

        b:SetScript("OnClick", function(self)
            if not self.mapRef then return end
            for idx, m in ipairs(maps) do
                if m == self.mapRef then selected = idx; break end
            end
            Keystone.Render()
        end)
        listButtons[i] = b
    end

    -- ---- right: the stepper and the readout ----
    local right = CreateFrame("Frame", nil, frame)
    right:SetPoint("TOPLEFT", listBg, "TOPRIGHT", 18, 0)
    right:SetPoint("BOTTOMRIGHT", -8, 8)

    --[[ ----------------------------------------------------------------------
         Register the two sections, then open on the keystone.

         `keystone` is the default deliberately: managing and STARTING a key is
         what people came for once the item is gone, and the reward preview is
         the thing you consult occasionally. It is also the section that answers
         reports #655 and #657.

         The run panel lives in its own file so this one keeps doing one job.
         Guarded because the two ship as separate files in the same payload and a
         partial install must degrade to "the preview still works", not to a Lua
         error on the Dashboard's most-used tab.
      ------------------------------------------------------------------------ ]]
    sections["rewards"] = { title, formula, listBg, right }

    if _G.UncappedKeystoneRun and _G.UncappedKeystoneRun.UI then
        local runFrame = _G.UncappedKeystoneRun.UI.EmbedInto(frame)
        if runFrame then
            -- EmbedInto anchors to fill its parent; re-anchor under the strip so
            -- the sub-tabs stay clickable.
            runFrame:ClearAllPoints()
            runFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -SUBTAB_H)
            runFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
            sections["keystone"] = { runFrame }
        end
    end

    -- [#605] The Group Finder, embedded exactly like the run panel above and
    -- guarded for the same reason: the two ship as separate files in one payload,
    -- and a partial install must degrade to "the other tabs still work".
    if _G.UncappedLFG and _G.UncappedLFG.UI then
        local lfgFrame = _G.UncappedLFG.UI.EmbedInto(frame)
        if lfgFrame then
            lfgFrame:ClearAllPoints()
            lfgFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -SUBTAB_H)
            lfgFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
            sections["lfg"] = { lfgFrame }
        end
    end

    if not sections["lfg"] then
        -- Same rule as the keystone sub-tab: a button that does nothing when
        -- pressed is worse than no button.
        if subButtons["lfg"] then subButtons["lfg"]:Hide() end
    end

    if not sections["keystone"] then
        -- No run panel in this install: drop its sub-tab rather than leaving a
        -- button that does nothing when pressed.
        if subButtons["keystone"] then subButtons["keystone"]:Hide() end
        ShowSection("rewards")
    else
        ShowSection("keystone")
    end

    local keyLabel = right:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    keyLabel:SetPoint("TOPLEFT", 0, 0)
    keyLabel:SetText("Keystone level")

    local minus10 = MakeButton(right, "-10", 40, function() StepLevel(-10) end)
    local minus1  = MakeButton(right, "-", 28, function() StepLevel(-1) end)
    local plus1   = MakeButton(right, "+", 28, function() StepLevel(1) end)
    local plus10  = MakeButton(right, "+10", 40, function() StepLevel(10) end)

    minus10:SetPoint("TOPLEFT", keyLabel, "BOTTOMLEFT", 0, -6)
    minus1:SetPoint("LEFT", minus10, "RIGHT", 3, 0)

    levelText = right:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    levelText:SetPoint("LEFT", minus1, "RIGHT", 10, 0)
    levelText:SetWidth(56)
    levelText:SetJustifyH("CENTER")

    plus1:SetPoint("LEFT", levelText, "RIGHT", 10, 0)
    plus10:SetPoint("LEFT", plus1, "RIGHT", 3, 0)

    local order = { "map", "size", "bonus", "sacks", "anima", "compare", "note" }
    local anchor = minus10
    local gaps = { map = -16, size = -10, bonus = -2, sacks = -12, anima = -2, compare = -14, note = -8 }
    for _, key in ipairs(order) do
        local style = (key == "map") and "GameFontNormalLarge" or "GameFontHighlightSmall"
        local fs = right:CreateFontString(nil, "OVERLAY", style)
        fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, gaps[key])
        fs:SetJustifyH("LEFT")
        fs:SetWidth(340)
        previewTexts[key] = fs
        anchor = fs
    end

    statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    statusText:SetPoint("BOTTOMLEFT", 8, 6)

    -- Timeout watcher. One unanswered request is enough to know this server has
    -- no MRWQ handler; re-opening the tab is the manual retry.
    frame:SetScript("OnUpdate", function()
        if pending and (GetTime() - requestedAt) > REPLY_TIMEOUT then
            pending = false
            answered = true
            if statusText then
                statusText:SetText("The server did not answer -- this realm build has no reward preview yet.")
            end
            Keystone.Render()
        end
    end)

    return frame
end

-- ---------------------------------------------------------------------------
-- Dashboard embedding
-- ---------------------------------------------------------------------------
function Keystone.UI.EmbedInto(parent)
    BuildFrame(parent)
    frame:Show()
    return frame
end

function Keystone.UI.Activate()
    if not frame then return end

    -- Refresh whichever SECTION is open rather than always the reward preview.
    -- ShowSection already knows how to bring a section up to date, so re-showing
    -- the current one is both the refresh and the guarantee that the strip's
    -- enabled/disabled states match what is on screen.
    if Keystone.ShowSection and Keystone.CurrentSection then
        Keystone.ShowSection(Keystone.CurrentSection())
        return
    end

    Keystone.Render()   -- paint from cache first
    Request()           -- then refresh
end

-- List 210 + gap 18 + the readout's 340 + padding on both sides.
function Keystone.UI.GetMinWidth()
    return 210 + 18 + 340 + 30
end

function Keystone.UI.GetMinHeight()
    return 40 + (ROWS * ROW_H) + 40 + 72
end

-- ---------------------------------------------------------------------------
-- Events / slash
-- ---------------------------------------------------------------------------
local comms = CreateFrame("Frame")
comms:RegisterEvent("CHAT_MSG_ADDON")
comms:SetScript("OnEvent", function(self, event, a1, a2)
    event = event or _G.event
    a1 = a1 or _G.arg1
    a2 = a2 or _G.arg2

    if event ~= "CHAT_MSG_ADDON" then return end
    if a1 ~= ADDON_PIPE_PREFIX or not a2 then return end
    -- "MRW" is this panel's own three-letter space on the shared pipe.
    if string.sub(a2, 1, 3) ~= "MRW" then return end
    HandleMessage(a2)
end)

local function OpenInDashboard()
    local Dashboard = _G.UncappedDashboard
    if not Dashboard then
        DEFAULT_CHAT_FRAME:AddMessage(COLOR_HEAD .. "[M+ Rewards]|r lives inside the Dashboard -- load UncappedDashboard to use it.")
        return
    end
    Dashboard.SetTab("keystone")
    if not (Dashboard.UI and Dashboard.UI.IsShown and Dashboard.UI.IsShown()) then
        Dashboard.Toggle()
    end
end

SLASH_UNCAPPEDKEYSTONE1 = "/keystone"
SLASH_UNCAPPEDKEYSTONE2 = "/ukeystone"
SlashCmdList["UNCAPPEDKEYSTONE"] = function(arg)
    arg = string.lower(arg or "")
    arg = string.gsub(arg, "^%s+", "")
    if arg == "sync" then
        pending = false
        Request()
        DEFAULT_CHAT_FRAME:AddMessage(COLOR_HEAD .. "[M+ Rewards]|r refreshing...")
        return
    end
    OpenInDashboard()
end
