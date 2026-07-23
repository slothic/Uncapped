-- Land Here -- cancel a flight path in progress.
--
-- A button appears while you are on a taxi and disappears when you land. It
-- puts you down at the NEXT flight master on your route, not wherever you
-- happen to be, so you never end up stranded over water or inside terrain you
-- cannot walk out of.
--
-- The button is deliberately draggable and remembers where you left it: the
-- default position sits under the minimap, which is busy on most UIs.

local BUTTON_SAVED = "taxiButtonPos"

UncappedAlertsDB = UncappedAlertsDB or {}

local button = CreateFrame("Button", "UncappedLandHereButton", UIParent, "UIPanelButtonTemplate")
button:SetSize(110, 26)
button:SetText("Land Here")
button:SetMovable(true)
button:EnableMouse(true)
button:RegisterForDrag("LeftButton")
button:SetClampedToScreen(true)
button:Hide()

local function RestorePosition()
    local pos = UncappedAlertsDB[BUTTON_SAVED]
    button:ClearAllPoints()
    if pos then
        button:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
    else
        button:SetPoint("TOP", UIParent, "TOP", 0, -180)
    end
end

button:SetScript("OnDragStart", button.StartMoving)
button:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relativePoint, x, y = self:GetPoint()
    UncappedAlertsDB[BUTTON_SAVED] = { point = point, relativePoint = relativePoint, x = x, y = y }
end)

button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Land Here")
    GameTooltip:AddLine("Ends your flight at the next flight master on the route. Drag to move this button.", 1, 1, 1, true)
    GameTooltip:Show()
end)
button:SetScript("OnLeave", function() GameTooltip:Hide() end)

button:SetScript("OnClick", function(self)
    self:Disable()
    self:SetText("Landing...")
    SendAddonMessage("REAGENTBANK", "RBTAXICANCEL:0", "WHISPER", UnitName("player"))
end)

local function ResetButton()
    button:Enable()
    button:SetText("Land Here")
end

-- UnitOnTaxi is the reliable "am I flying" check in 3.3.5. It is polled rather
-- than event-driven because the taxi start/stop events do not fire reliably for
-- every route type, and a stuck button is worse than a cheap poll.
local watcher = CreateFrame("Frame")
local sinceCheck = 0

watcher:RegisterEvent("PLAYER_LOGIN")
watcher:SetScript("OnEvent", RestorePosition)

watcher:SetScript("OnUpdate", function(self, delta)
    sinceCheck = sinceCheck + delta
    if sinceCheck < 0.5 then
        return
    end
    sinceCheck = 0

    if UnitOnTaxi("player") then
        if not button:IsShown() then
            ResetButton()
            button:Show()
        end
    elseif button:IsShown() then
        button:Hide()
        ResetButton()
    end
end)

-- The reply rides the player's personal channel, which is a data pipe -- hide
-- it so "RBTAXI:1:Stormwind" never appears in chat. Registered here rather than
-- relying on ReagentBankCraft's filter, since the two addons are independent
-- and either can be absent.
ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", function(self, event, msg)
    if msg and msg:find("^RBTAXI:") then
        return true
    end
    return false
end)

-- Prefix for the whole server->client pipe (see the transport note below).
local ADDON_PIPE_PREFIX = "UNC"

-- Server reply: RBTAXI:<1|0>:<flight master name>
local listener = CreateFrame("Frame")
listener:RegisterEvent("CHAT_MSG_CHANNEL")
listener:RegisterEvent("CHAT_MSG_ADDON")
listener:SetScript("OnEvent", function(self, event, a1, a2)
    -- Two transports, on purpose.
    --
    -- CHAT_MSG_ADDON is where the pipe is moving: the client never renders it,
    -- so the protocol can no longer leak into chat when an addon fails to load.
    -- CHAT_MSG_CHANNEL is the old transport, kept because one payload serves
    -- both realms and a realm still running the previous worldserver would go
    -- silent otherwise. Drop the channel branch once every realm is converted.
    --
    --   CHAT_MSG_ADDON   : a1 = prefix, a2 = body
    --   CHAT_MSG_CHANNEL : a1 = body,   a2 = author (our own name on the pipe)
    local text
    if event == "CHAT_MSG_ADDON" then
        if a1 ~= ADDON_PIPE_PREFIX then return end
        text = a2
    else
        if a2 ~= UnitName("player") then return end
        text = a1
    end
    if not text then
        return
    end

    local ok, where = text:match("^RBTAXI:(%d):(.*)$")
    if not ok then
        return
    end

    button:Hide()
    ResetButton()

    if ok == "1" then
        if where and where ~= "" then
            DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Flight cancelled -- landing at " .. where .. ".")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[Uncapped]|r Flight cancelled.")
        end
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff5555[Uncapped]|r Could not cancel -- you are already on the final approach.")
    end
end)
