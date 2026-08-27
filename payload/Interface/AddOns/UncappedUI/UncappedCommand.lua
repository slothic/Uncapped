--[[
  ★★ [#1008] DOT-COMMANDS WHILE YOU ARE A GHOST.

  Reported as "all . commands are unusable as a ghost", and the server is completely
  innocent: ChatHandler runs ParseCommands for every non-addon chat type and returns
  before it ever reaches the alive check, so the server would happily run your
  commands while you are dead. Nothing in modules/ or scripts/Custom/ gates on it
  either.

  The block is in the 3.3.5a client itself. Its SendChatMessage refuses to build the
  packet at all for SAY, YELL, EMOTE, TEXT_EMOTE and AFK while the player is dead --
  it raises ERR_CHAT_WHILE_DEAD and returns. SAY is what this realm uses to carry
  dot-commands, from the default chat box and from every addon that drives one, so
  every command on the realm dies at that check the moment you release.

  ⚠ This has NEVER worked. It is not a regression, which is worth knowing before
    anyone goes looking for what broke it.

  What it costs players is worse than an inconvenience: `.dropcombat` is the realm's
  only way out of a stuck-in-combat state, and it is unreachable exactly when a stuck
  fight has killed you. GM commands are blocked identically, so staff cannot `.appear`
  as a ghost either.

  THE FIX. WHISPER was never blocked, and a whisper to yourself is already the
  established pipe this realm uses for addon traffic. The server strips a leading dot
  and runs it as a command before the text can reach any channel, so nothing is ever
  posted and nobody sees it. So while dead, quietly re-route a leading-dot SAY down a
  whisper to yourself and let the server do exactly what it would have done anyway.

  Safe against the obvious failure -- a mistyped `.foo` leaking into someone's chat --
  because AllowPlayerCommands is on for this realm, so an unrecognised command returns
  "There is no such command" rather than falling through as text. And the whisper
  level gate explicitly exempts whispering yourself, so this works at any level.
]]

local _G = getfenv(0)

local originalSendChatMessage = _G.SendChatMessage

_G.SendChatMessage = function(msg, chatType, language, channel, ...)
    -- Only ever intervene for the exact case that is broken: a dot-command, sent
    -- down a chat type the client will refuse, while the player is actually dead.
    -- Everything else -- including a normal SAY while alive -- is passed straight
    -- through untouched, so this hook is invisible in every other situation.
    if msg
        and type(msg) == "string"
        and strsub(msg, 1, 1) == "."
        and strsub(msg, 1, 2) ~= ".."          -- leave "..." and friends alone
        and UnitIsDeadOrGhost("player")
    then
        -- nil chatType means SAY, which is the default chat box and the common case.
        local blocked = (chatType == nil)
            or chatType == "SAY" or chatType == "YELL"
            or chatType == "EMOTE" or chatType == "TEXT_EMOTE"

        if blocked then
            local self = UnitName("player")
            if self and self ~= "" then
                return originalSendChatMessage(msg, "WHISPER", language, self)
            end
        end
    end

    return originalSendChatMessage(msg, chatType, language, channel, ...)
end
