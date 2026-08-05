--[[
    UncappedNative -- the client half of the native data channel.

    WHAT THIS IS
      A second server->client transport that does not go through addon chat
      messages. The injected UncappedCT.dll registers a handler for a custom
      network opcode and exposes two functions to Lua:

        UncappedNative_Version()  -> "1"           (absent when the DLL is not loaded)
        UncappedNative_Poll()     -> topic, payload  (nothing when idle)

      An addon message caps at 255 bytes including the prefix, so anything large
      -- a vault, a wardrobe -- has to be chopped, numbered and glued back
      together in Lua. A native frame is one packet and can carry megabytes, so
      the payload arrives whole and the reassembly code stops existing.

    WHY IT IS OPTIONAL, AND MUST STAY OPTIONAL
      The DLL is delivered with the client, not with the addons, so an addon
      update can reach a player before the DLL does -- and someone running a
      stock client will never have it at all. IsAvailable() is therefore not a
      formality: every caller needs a working addon-message path behind it. This
      library makes that explicit by refusing to pretend, rather than by
      silently doing nothing.

    HOW A CONSUMER USES IT

        local N = UncappedNative
        if N and N.IsAvailable() then
            N.Register("VAULT", function(payload) ... end)
        else
            -- existing addon-message path, unchanged
        end

    THE ANNOUNCEMENT
      The server sends nothing on this channel until the client says it can
      listen -- a stock client receiving an unknown opcode takes the dispatcher's
      unhandled branch, and that is not a thing to broadcast to a realm on the
      strength of "it is probably fine". So this announces once per login, over
      the ordinary addon pipe, and the server gates every native send on having
      heard it.
]]

local ADDON_TRANSPORT_PREFIX = "REAGENTBANK"   -- the pipe every Uncapped addon already uses
local PROTOCOL_VERSION = "1"

local UncappedNative = {}
_G.UncappedNative = UncappedNative

local handlers = {}
local announced = false

-- Forward declaration: the pump below closes over this, and it is defined near
-- the slash command at the bottom. Without the declaration here the closure
-- would capture a global that never exists.
local SelfTest

-- Cached once: the function either exists at load or it never will, because it
-- is registered by the DLL when the world Lua state is built.
local nativeVersion = nil
if type(UncappedNative_Version) == "function" then
    local ok, v = pcall(UncappedNative_Version)
    if ok then nativeVersion = v end
end

function UncappedNative.IsAvailable()
    return nativeVersion == PROTOCOL_VERSION
end

function UncappedNative.Version()
    return nativeVersion
end

--[[ Register a handler for one topic. Returns false if the channel is not
     available, so a caller can branch on the result rather than on a separate
     availability check. ]]
function UncappedNative.Register(topic, fn)
    if not UncappedNative.IsAvailable() then return false end
    if type(topic) ~= "string" or type(fn) ~= "function" then return false end
    handlers[topic] = fn
    return true
end

function UncappedNative.Unregister(topic)
    handlers[topic] = nil
end

local function Announce()
    if announced or not UncappedNative.IsAvailable() then return end
    if not SendAddonMessage then return end
    SendAddonMessage(ADDON_TRANSPORT_PREFIX, "NATIVE:" .. PROTOCOL_VERSION,
                     "WHISPER", UnitName("player"))
    announced = true
end

--[[ Polling rather than a callback from the DLL.

     A callback would have to cross from the client's network thread onto the UI
     thread before it could touch Lua at all, which means a queue and a pump --
     exactly what this is, minus the part where a bug in it corrupts the Lua
     state. Idle cost is one C call per frame returning nothing.

     Drained in a loop, not one per frame: a burst of frames should be delivered
     in the frame it arrived, and the queue in the DLL is only 16 deep. ]]
local pump = CreateFrame("Frame")
pump:RegisterEvent("PLAYER_ENTERING_WORLD")
pump:SetScript("OnEvent", function()
    -- The session is not ready to accept an addon message at load; entering the
    -- world is the first moment it is.
    Announce()
    UncappedNative.Register("TEST", SelfTest)
end)

pump:SetScript("OnUpdate", function()
    if not UncappedNative.IsAvailable() then return end

    for _ = 1, 16 do
        local topic, payload = UncappedNative_Poll()
        if not topic then return end

        local fn = handlers[topic]
        if fn then
            -- pcall so one addon's parser cannot stop every other topic from
            -- being drained; a stuck queue would drop later frames.
            local ok, err = pcall(fn, payload, topic)
            if not ok then
                DEFAULT_CHAT_FRAME:AddMessage(
                    "|cffff8040[UncappedNative]|r handler for '" .. tostring(topic)
                    .. "' errored: " .. tostring(err))
            end
        end
    end
end)

--[[ /uncnative -- is the channel up, and is anything using it?

     Worth having as a slash command rather than a debug print: "is my client
     actually running the DLL" is the first question for any report about this
     transport, and it has to be answerable by the player. ]]
--[[ The self-test handler for the server's `.native test <bytes>`.

     Registered permanently rather than behind a debug flag: it costs one table
     entry, and it is the only way to answer "did the bytes arrive intact" from
     inside the game. The server fills the payload with a repeating A..Z, so a
     read at the wrong offset shows up immediately as the wrong starting letter
     rather than as a plausible-looking string. ]]
SelfTest = function(payload)
    local n = #payload
    local head = string.sub(payload, 1, 12)
    local tail = string.sub(payload, -12)

    --[[ Whole-payload comparison, because an offset slip in the middle would
         sail past a head/tail check.

         Built with string.rep and compared in one operation rather than looped
         per byte: at four million bytes a Lua loop is millions of interpreted
         iterations and would visibly hang the client, while this is two C
         calls. ]]
    local unit = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    local expected = string.sub(string.rep(unit, math.floor(n / 26) + 1), 1, n)
    local ok = (expected == payload)

    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|cff1eff00[UncappedNative]|r TEST %d bytes, head '%s', tail '%s' -- %s",
        n, head, tail,
        ok and "|cff1eff00all bytes verified|r" or "|cffff2020CONTENT MISMATCH|r"))
end

SLASH_UNCNATIVE1 = "/uncnative"
SlashCmdList["UNCNATIVE"] = function()
    if UncappedNative.IsAvailable() then
        DEFAULT_CHAT_FRAME:AddMessage("|cff1eff00[UncappedNative]|r available, protocol v"
            .. tostring(nativeVersion) .. (announced and " (announced)" or " (not yet announced)"))
        local n = 0
        for topic in pairs(handlers) do
            n = n + 1
            DEFAULT_CHAT_FRAME:AddMessage("    topic: " .. topic)
        end
        if n == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("    no topics registered -- everything is still on addon messages.")
        end
    elseif nativeVersion then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff8040[UncappedNative]|r client speaks v" .. tostring(nativeVersion)
            .. ", this addon speaks v" .. PROTOCOL_VERSION .. " -- staying on addon messages.")
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff8040[UncappedNative]|r not available (UncappedCT.dll is not loaded).")
    end
end
