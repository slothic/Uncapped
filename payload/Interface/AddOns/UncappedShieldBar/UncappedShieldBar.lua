--[[ ============================================================
     UncappedShieldBar -- report #522

     Akai: "Add some kind of bar or counter for total shielding, similar to HP
     bar. Currently mages have to guess or eat a hit to know to refresh."

     ★ THE CLIENT CANNOT COMPUTE THIS. In 3.3.5a UnitAura returns an icon, a
     stack count and a duration -- never the remaining absorb. So an addon can
     see that you have Ice Barrier and has no way to know whether it is holding
     ten points or ten million. Every number here arrives from the server over
     the addon pipe (absorb_shield_feed.cpp, "UABS:<total>", once a second).

     WHY THIS MATTERS MORE HERE THAN ON A STOCK REALM
     ------------------------------------------------
     Ice Barrier and its family SNAPSHOT spell power at cast time -- the aura
     carries canBeRecalculated = false -- and spell power on this realm moves in
     five-figure jumps. So a barrier you put up five minutes ago can be much
     weaker than one cast right now, and nothing in the default UI says so. That
     is the gap this closes: not "do I have a shield" (the buff icon already says
     that) but "is the shield I have worth anything".

     DESIGN NOTES
     ------------
     - NO COMBAT MATHS HERE. The bar renders what the server sent and nothing
       else. Every attempt to be clever client-side -- guessing decay, predicting
       the next hit -- ends in a bar that disagrees with reality at exactly the
       moment the player needs to trust it.
     - The maximum is the HIGHEST TOTAL SEEN THIS SHIELD, not a fixed cap. There
       is no such thing as "full" for an absorb, so the bar fills relative to
       what you had when you cast it, which is the question being asked: how much
       of my shield is left?
     - Hidden entirely at zero. A permanently empty bar under the player frame is
       clutter for the eleven classes that mostly do not shield.
     ============================================================ ]]

local ADDON_PIPE_PREFIX = "UNC"

-- BAR_W is the fallback width only -- normally the bar takes the power bar's.
local BAR_W, BAR_H = 119, 10

-- Server sends once a second; anything older than this means the feed stopped
-- (zoning, a disconnect, the script disabled) and a stale bar is worse than none.
local STALE_AFTER = 3.0

local db
local lastValue, peakValue, lastStamp = 0, 0, 0

local function Abbrev(n)
    -- Absorbs here run to the billions; a raw number would overflow the bar and
    -- be unreadable anyway.
    if n >= 1e12 then return string.format("%.2fT", n / 1e12) end
    if n >= 1e9  then return string.format("%.2fB", n / 1e9)  end
    if n >= 1e6  then return string.format("%.2fM", n / 1e6)  end
    if n >= 1e3  then return string.format("%.1fK", n / 1e3)  end
    return tostring(n)
end

-- ---------------------------------------------------------------- the bar ----
local frame = CreateFrame("Frame", "UncappedShieldBarFrame", PlayerFrame)
frame:SetHeight(BAR_H)

--[[ ★ ANCHOR TO THE MANA BAR, NOT TO PlayerFrame.

     The first version used a hand-measured offset from PlayerFrame's top-left,
     which put the bar straight through the mana text. Hardcoded offsets into
     someone else's frame are guesses that rot: the power bar moves between
     rage/energy/runic, and a druid shifting form rebuilds it. Hanging off
     PlayerFrameManaBar's bottom edge means the bar sits under whatever the power
     bar currently is, at whatever width it currently has, without measuring
     anything. The fallback keeps the addon working if Blizzard's frame is
     missing (another addon replaced the unit frames). ]]
if PlayerFrameManaBar then
    frame:SetPoint("TOPLEFT",  PlayerFrameManaBar, "BOTTOMLEFT",  0, -2)
    frame:SetPoint("TOPRIGHT", PlayerFrameManaBar, "BOTTOMRIGHT", 0, -2)
else
    frame:SetWidth(BAR_W)
    frame:SetPoint("TOPLEFT", PlayerFrame, "TOPLEFT", 106, -70)
end
frame:Hide()

local bg = frame:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints(frame)
bg:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
bg:SetVertexColor(0, 0, 0, 0.6)

local bar = CreateFrame("StatusBar", nil, frame)
bar:SetAllPoints(frame)
bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
-- Pale gold: distinct from health green, mana blue and the rage/energy bars, so
-- it cannot be misread at a glance during a pull.
bar:SetStatusBarColor(0.85, 0.78, 0.35)
bar:SetMinMaxValues(0, 1)
bar:SetValue(0)

local border = frame:CreateTexture(nil, "OVERLAY")
border:SetPoint("TOPLEFT", frame, "TOPLEFT", -1, 1)
border:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 1, -1)
border:SetTexture(0, 0, 0, 0.5)

local text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
text:SetPoint("CENTER", bar, "CENTER", 0, 0)
text:SetTextColor(1, 1, 1)

local function Redraw()
    --[[ ★ THE HIDE TOGGLE HAS TO BE CHECKED HERE, NOT ONLY IN THE SLASH COMMAND.

         Redraw runs on every feed tick -- once a second, forever. So a /shieldbar
         that only called frame:Hide() was undone by the very next packet, and the
         bar came straight back. From the player's side that reads as an inverted
         toggle: it announces "hidden" and stays visible. Any show/hide state that
         lives outside the function which does the showing will always lose to it.]]
    if db and db.hidden then
        frame:Hide()
        return
    end

    if lastValue <= 0 then
        frame:Hide()
        return
    end

    -- Relative to the most this shield has been worth, not to any global cap --
    -- see the design note. peakValue resets when the shield drops to zero.
    local pct = 0
    if peakValue > 0 then
        pct = lastValue / peakValue
        if pct > 1 then pct = 1 end
    end

    bar:SetValue(pct)
    text:SetText(Abbrev(lastValue))
    frame:Show()
end

-- ------------------------------------------------------------- the feed ------
local comms = CreateFrame("Frame")
comms:RegisterEvent("CHAT_MSG_ADDON")
comms:RegisterEvent("PLAYER_ENTERING_WORLD")
comms:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "PLAYER_ENTERING_WORLD" then
        -- Zoning tears down the feed for a moment. Clear rather than carry the
        -- old number across a loading screen, where it is certainly wrong.
        lastValue, peakValue, lastStamp = 0, 0, 0
        Redraw()
        return
    end

    if a1 ~= ADDON_PIPE_PREFIX or not a2 then return end

    local raw = string.match(a2, "^UABS:(%d+)$")
    if not raw then return end

    local value = tonumber(raw) or 0
    lastStamp = GetTime()

    --[[ ★ PEAK RESETS ONLY ON A TRUE ZERO.

         Resetting the peak whenever the value drops would make the bar refill
         itself after every hit -- it would always read "full" and tell the
         player nothing. Resetting only when the shield is actually gone means
         the peak is "what this shield was worth when you cast it", so the bar
         answers the question Akai actually asked. ]]
    if value <= 0 then
        peakValue = 0
    elseif value > peakValue then
        peakValue = value
    end

    lastValue = value
    Redraw()
end)

-- Stale guard. If the server stops feeding -- script disabled, a disconnect, a
-- zone the map script does not tick -- the bar must not sit there showing a
-- shield that may have broken minutes ago.
--
-- ★ The guard lives on `comms`, not on `frame`. A hidden frame gets no OnUpdate,
--   so hanging the staleness check on the bar itself means it stops checking in
--   exactly the state where a stale value could be waiting to reappear.
comms:SetScript("OnUpdate", function(_, elapsed)
    if lastValue <= 0 then return end
    if GetTime() - lastStamp > STALE_AFTER then
        lastValue, peakValue = 0, 0
        Redraw()
    end
end)

-- --------------------------------------------------------------- saved vars --
local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:SetScript("OnEvent", function(_, _, name)
    if name ~= "UncappedShieldBar" then return end
    UncappedShieldBarDB = UncappedShieldBarDB or {}
    db = UncappedShieldBarDB
    Redraw()
end)

SLASH_UNCAPPEDSHIELDBAR1 = "/shieldbar"
SlashCmdList["UNCAPPEDSHIELDBAR"] = function()
    db = db or {}
    db.hidden = not db.hidden

    -- One path in and one path out: set the flag, let Redraw decide what the
    -- frame does. The command never touches Show/Hide itself.
    Redraw()

    if db.hidden then
        DEFAULT_CHAT_FRAME:AddMessage("|cffD9C759[Shield Bar]|r hidden. /shieldbar to show it again.")
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffD9C759[Shield Bar]|r shown.")
    end
end
