-- Kill the client's AFK logout warning.
--
-- ★ THE POPUP WAS TELLING PLAYERS SOMETHING THAT IS NOT TRUE HERE.
--
-- "You have been inactive for some time and will be logged out of the game."
-- The client raises that on its own idle timer and starts a logout. This realm
-- does not kick idle players -- the server-side idle disconnect is gated behind
-- CloseIdleConnections, which report #314 wired up and which is off. So the only
-- thing still trying to log people out for standing still is the client, warning
-- about a rule that no longer exists.
--
-- ⚠ WHY CancelLogout() AND NOT JUST HIDING THE POPUP.
--
-- Hiding the dialog would remove the message and leave the logout running,
-- which is strictly worse than the status quo: the player loses the warning and
-- still gets dropped, with nothing on screen to explain it. CancelLogout() is
-- the client API the popup's own Cancel button calls, so this does exactly what
-- a player mashing Cancel would do -- it aborts the logout the client started.
-- The popup is then dismissed because there is nothing left for it to warn about.
--
-- Hooked on StaticPopup_Show rather than on an event, because the idle warning
-- is raised from the client's own C code and fires no Lua event we can listen
-- for. hooksecurefunc runs AFTER the popup is shown, which is fine: the logout
-- has a grace period measured in seconds and we cancel it within the same frame.

local IDLE_POPUP = "IDLE_MESSAGE"

-- How long after an idle warning we treat a logout-refusal as belonging to it.
-- Short on purpose: see the note on the UIErrorsFrame hook below.
local ERROR_GRACE = 3.0
local suppressErrorsUntil = 0

local function AbortIdleLogout()
    -- pcall: CancelLogout is a plain client API, but a future client build that
    -- renamed or removed it must not take the whole addon file down with it.
    -- Losing this feature is a nuisance; losing UncappedAlerts would mean losing
    -- the restart countdown, which players genuinely need.
    suppressErrorsUntil = GetTime() + ERROR_GRACE
    pcall(CancelLogout)
    StaticPopup_Hide(IDLE_POPUP)
end

-- One hook is enough: StaticPopup_Show is the only route by which a StaticPopup
-- can be displayed, so there is no second path to guard. An OnUpdate-based
-- backstop was considered and dropped -- it would run every frame for every
-- popup to catch a case that cannot happen.
hooksecurefunc("StaticPopup_Show", function(which)
    if which == IDLE_POPUP then
        AbortIdleLogout()
    end
end)

--[[ ------------------------------------------------------------------------
     ★ AND THE RED "You can't logout now." THAT COMES WITH IT.

     The idle timer does not just warn -- it actually sends a logout request,
     and the server REFUSES it (which is why nobody is being kicked). The refusal
     comes back as ERR_LOGOUT_FAILED and paints across the middle of the screen
     in red, once per attempt. Three warnings, three red lines.

     Cancelling at popup time should stop the request ever being sent, so this
     hook should never fire. It exists because the ordering is the client's to
     decide, not ours, and the failure mode if we are wrong is the player still
     getting the spam we told them we removed.

     ⚠ DELIBERATELY NOT A BLANKET FILTER. "You can't logout now." is a legitimate
       and useful message when you type /logout in combat -- swallowing it always
       would replace one confusing behaviour with another. It is suppressed only
       within a few seconds of an idle warning we ourselves cancelled, which is
       the only window in which the player did not ask to log out.
]]
local origAddMessage = UIErrorsFrame.AddMessage
UIErrorsFrame.AddMessage = function(self, msg, ...)
    if msg == ERR_LOGOUT_FAILED and GetTime() < suppressErrorsUntil then
        return
    end
    return origAddMessage(self, msg, ...)
end
