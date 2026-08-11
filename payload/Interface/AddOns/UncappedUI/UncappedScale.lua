-- UncappedUIKit Scale -- ONE user-adjustable zoom for every Uncapped window.
--
-- Written for 3.3.5a (Lua 5.1): no C_ APIs, no BackdropTemplate, no #frame.
--
-- ===========================================================================
-- WHO OWNS THE SCALE
-- ===========================================================================
-- ★ SetScale COMPOUNDS with every parent up the chain. A frame's real size is
--   parent:GetEffectiveScale() * frame:GetScale(), so scaling a window AND
--   something inside it multiplies the zoom twice and nothing lines up.
--
--   THE RULE FOR THIS SUITE, no exceptions:
--
--     ONLY A FRAME PARENTED DIRECTLY TO UIParent MAY BE REGISTERED HERE.
--
--   Everything nested inside such a frame inherits the zoom for free and must
--   NOT be registered. That is what makes the Dashboard cheap: its tabs
--   (Prestige, Progress, Vault, Forge, Soul Forge, Anima, Transmog, Scrolls,
--   Loot Feed) all build into a group INSIDE UncappedDashboardFrame, so the
--   one SetScale on the master window zooms every tab, including tabs that do
--   not exist yet.
--
--   The exceptions that DO need their own registration are the handful of
--   pop-outs that deliberately parent to UIParent instead of to the window
--   that opened them (the extractor, the socket window, the soulbind wheel,
--   the transmog outfit list, the forge source picker). Those are siblings of
--   the Dashboard, not children, so they inherit nothing.
--
-- ===========================================================================
-- WHY POSITIONS DO NOT JUMP
-- ===========================================================================
-- ★ SetPoint OFFSETS ARE IN THE ANCHORED FRAME'S OWN SCALE UNITS. A window
--   sitting at SetPoint("TOPLEFT", UIParent, "TOPLEFT", 300, -200) draws its
--   corner 300*scale screen-units from the left, so changing scale alone slides
--   a window the player carefully placed -- at 1.5 zoom, 50% further out --
--   and a window dragged near an edge can land completely off screen, where it
--   cannot be grabbed back without wiping SavedVariables.
--
--   So a scale change here is never just SetScale. Every registered frame gets:
--     1. its anchor offsets multiplied by oldScale/newScale, which pins the
--        anchored CORNER to the same screen pixel it was already on (the frame
--        grows away from that corner, which is what "zoom" should look like);
--     2. a clamp that shoves the frame back on screen if it still ends up
--        outside it -- pinning TOP-LEFT first, because that is where the title
--        bar, the close button and the drag area live;
--     3. a savePosition callback, so the corrected offsets are what gets
--        written to SavedVariables. Without this the addon would persist the
--        PRE-scale offsets and the window would jump on the next login instead.
--
-- ===========================================================================
-- GetScale() vs GetEffectiveScale()
-- ===========================================================================
-- GetScale() is the frame's own multiplier; GetEffectiveScale() is that times
-- every ancestor's. Anything comparing a frame to the screen (or to
-- GetCursorPosition(), which is raw pixels) must use EFFECTIVE scale, and the
-- conversion in this file is always written out as the explicit ratio
--     k = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
-- which turns the frame's own units into UIParent units. Divide by k to go
-- back. Mixing the two is the classic drift bug, so there is exactly one place
-- in this file that does the conversion (ScreenRect) and everything else uses
-- it.

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

local math_floor, math_min, math_max, math_abs = math.floor, math.min, math.max, math.abs
local tonumber, pairs, type = tonumber, pairs, type

-- Player-facing bounds. 1.0 must remain the default: at 1.0 with no per-frame
-- base scale this file is a no-op and every window behaves exactly as it did
-- before the setting existed.
local MIN_SCALE     = 0.5
local MAX_SCALE     = 1.5
local DEFAULT_SCALE = 1.0
local STEP          = 0.05

-- UIParent units left clear on each axis when capping a frame's zoom to what
-- the screen can actually show (see getFitSize). Matches DashboardButtons'
-- own SCREEN_MARGIN: size a window flush to the screen edge and the resize
-- grip ends up under it.
local FIT_MARGIN = 60

-- UIParent units of a frame that must stay on screen after a scale change.
-- Enough to grab and drag with.
local KEEP_VISIBLE = 60

local entries = {}     -- ordered array of registration records
local byFrame = {}     -- frame -> record
local listeners = {}
local current = DEFAULT_SCALE

local function Clamp(v)
    v = tonumber(v) or DEFAULT_SCALE
    if v < MIN_SCALE then v = MIN_SCALE elseif v > MAX_SCALE then v = MAX_SCALE end
    -- Snap to the slider's step so a saved value can't drift to 1.0300000001
    -- and make the readout look broken.
    return math_floor(v / STEP + 0.5) * STEP
end

-- Deliberately NOT UncappedUIKit.GetDB() (ThemeManager's): that file loads
-- AFTER this one, and this table is touched from load handlers. Both are
-- idempotent and both point at the same SavedVariables table, so they compose.
local function ScaleDB()
    UncappedUIDB = UncappedUIDB or {}
    return UncappedUIDB
end

-- ===========================================================================
-- PER-ADDON ZOOM
-- ===========================================================================
-- The global slider was the only control for a long time, which meant a player
-- who wanted a bigger Dashboard also got a bigger chat window, a bigger HUD and
-- bigger alerts. Each window now carries a GROUP, and each group has its own
-- multiplier on top of the global one:
--
--     effective = frame's own base  x  global  x  group
--
-- ★ THE GROUP LIST IS DECLARED HERE, NOT DISCOVERED FROM REGISTRATIONS.
--   A slider that only appears once its addon happens to have built a window is
--   a settings page that changes shape depending on where you were standing when
--   you opened it. Declaring them up front means the page is always the same, and
--   a group whose addon is disabled simply has nothing to apply to.
--
--   Adding a window to a group is one `group = "..."` in its registration. A
--   window with no group follows the global slider alone, which is what every
--   window did before this existed.
local GROUPS = {
    { key = "dashboard", label = "Dashboard",   note = "The Dashboard and every tab in it -- Vault, Forge, Soul Forge, Transmog, Anima, Progress, Prestige, Scrolls, Loot Feed -- plus its pop-out windows." },
    { key = "mythic",    label = "Mythic+ HUD", note = "The keystone timer, boss list and enemy-forces bar." },
    { key = "chat",      label = "Chat",        note = "The Uncapped chat window." },
    { key = "alerts",    label = "Alerts",      note = "The pop-up alert toasts." },
    { key = "rewards",   label = "Rewards",     note = "The end-of-run reward window." },
    { key = "hotzones",  label = "Hotzones",    note = "The hotzone bar." },
    { key = "quests",    label = "Quest Log",   note = "The quest ledger window." },
    { key = "panel",     label = "Info Panel",  note = "The Uncapped info panel." },
}

local function GroupDB()
    local db = ScaleDB()
    db.groupScale = db.groupScale or {}
    return db.groupScale
end

local function GroupFactor(group)
    if not group then return 1 end
    local v = tonumber(GroupDB()[group])
    if not v or v <= 0 then return 1 end
    return v
end

-- ---------------------------------------------------------------------------
-- Geometry helpers
-- ---------------------------------------------------------------------------

-- The frame's rectangle expressed in UIParent units, plus the conversion
-- factor k that got it there. Returns nil when the frame has never been laid
-- out (GetLeft() is nil until the first frame it is positioned on).
local function ScreenRect(frame)
    local left, right = frame:GetLeft(), frame:GetRight()
    local top, bottom = frame:GetTop(), frame:GetBottom()
    if not left or not right or not top or not bottom then return nil end
    local eff = frame.GetEffectiveScale and frame:GetEffectiveScale()
    local uiEff = UIParent:GetEffectiveScale()
    if not eff or eff <= 0 or not uiEff or uiEff <= 0 then return nil end
    local k = eff / uiEff
    return left * k, right * k, top * k, bottom * k, k
end

-- Rewrites every anchor of `frame`, running each x/y offset through fn(x, y).
-- Preserves the anchor STRUCTURE (a two-point TOPLEFT+BOTTOMRIGHT frame stays
-- two-point) rather than collapsing it to a single TOPLEFT, which would
-- silently un-stretch anything anchored to two corners.
local function MapPoints(frame, fn)
    local n = frame:GetNumPoints()
    if not n or n < 1 then return false end
    local saved = {}
    for i = 1, n do
        local p, rel, rp, x, y = frame:GetPoint(i)
        local nx, ny = fn(x or 0, y or 0)
        saved[i] = { p, rel, rp or p, nx, ny }
    end
    frame:ClearAllPoints()
    local parent = frame:GetParent() or UIParent
    for i = 1, n do
        local d = saved[i]
        frame:SetPoint(d[1], d[2] or parent, d[3], d[4], d[5])
    end
    return true
end

-- Keeps the anchored corner on the same screen pixel across a scale change.
-- Offsets live in the frame's own units, so screen offset = offset * scale;
-- multiplying by old/new holds that product constant.
--
-- Only correct while the frames anchored TO are not themselves being rescaled,
-- which is exactly the "top-level frames only" rule at the top of this file.
local function RescaleOffsets(frame, oldScale, newScale)
    if newScale <= 0 or math_abs(oldScale - newScale) < 0.0001 then return end
    local ratio = oldScale / newScale
    MapPoints(frame, function(x, y) return x * ratio, y * ratio end)
end

-- Shoves a frame back on screen after a scale change. Nothing here runs at
-- scale 1.0 on a window that was already visible, so it cannot move windows
-- that were fine.
local function ClampOnScreen(frame)
    local left, right, top, bottom, k = ScreenRect(frame)
    if not left then return end

    local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
    if not sw or not sh or sw <= 0 or sh <= 0 then return end

    local dx, dy = 0, 0
    if right < KEEP_VISIBLE then
        dx = KEEP_VISIBLE - right                 -- entirely off the left edge
    elseif left > sw - KEEP_VISIBLE then
        dx = (sw - KEEP_VISIBLE) - left           -- entirely off the right edge
    end
    if bottom > sh - KEEP_VISIBLE then
        dy = (sh - KEEP_VISIBLE) - bottom         -- entirely above the screen
    elseif top < KEEP_VISIBLE then
        dy = KEEP_VISIBLE - top                   -- entirely below the screen
    end

    -- A frame zoomed bigger than the screen can satisfy neither edge. Pin its
    -- TOP-LEFT: the title bar, the close button and the draggable strip are all
    -- up there, so a window hanging off the BOTTOM is still usable while one
    -- hanging off the TOP is not.
    if top + dy > sh then dy = sh - top end
    if left + dx < 0 then dx = -left end

    if dx == 0 and dy == 0 then return end
    -- Back into the frame's own units (k converts frame units -> UIParent).
    local fdx, fdy = dx / k, dy / k
    MapPoints(frame, function(x, y) return x + fdx, y + fdy end)
end

-- ---------------------------------------------------------------------------
-- Scale resolution
-- ---------------------------------------------------------------------------

-- The scale a frame should actually run at.
--
--   base    the frame's OWN zoom, for windows that already had a personal
--           scale setting before this one existed (the Mythic+ HUD, the chat
--           window). The global setting multiplies theirs rather than
--           overwriting it, so neither slider clobbers the other.
--   fitW/H  logical (unzoomed) size that must remain fully on screen. This is
--           the cap that stops a big zoom from pushing content off the edge --
--           see the nav-column note in DashboardButtons.lua. Pass nil when the
--           frame has no such requirement.
--
-- Never returns less than `base`: at global scale 1.0 every frame must be
-- exactly what it was before this feature shipped, even a frame whose fit size
-- already did not fit.
function UncappedUIKit.ResolveScale(base, fitW, fitH, group)
    base = tonumber(base) or 1
    if base <= 0 then base = 1 end

    -- base x global x group. The fit cap below still applies afterwards, so a
    -- group slider can never push a window off the screen.
    local want = base * current * GroupFactor(group)

    if fitW or fitH then
        local cap = want
        local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
        if fitW and fitW > 0 and sw and sw > 0 then
            cap = math_min(cap, (sw - FIT_MARGIN) / fitW)
        end
        if fitH and fitH > 0 and sh and sh > 0 then
            cap = math_min(cap, (sh - FIT_MARGIN) / fitH)
        end
        if cap < base then cap = base end
        if cap < want then want = cap end
    end

    return want
end

local function BaseOf(entry)
    if entry.getBase then
        return tonumber(entry.getBase(entry.frame)) or 1
    end
    return tonumber(entry.base) or 1
end

local function ApplyTo(entry)
    local f = entry.frame
    if not f or not f.SetScale then return end

    local fitW, fitH
    if entry.getFitSize then fitW, fitH = entry.getFitSize(f) end

    local want = UncappedUIKit.ResolveScale(BaseOf(entry), fitW, fitH, entry.group)
    if want < 0.2 then want = 0.2 end       -- paranoia: never scale to nothing

    local old = f:GetScale() or 1
    if old <= 0 then old = 1 end

    if math_abs(old - want) > 0.0005 then
        f:SetScale(want)
        -- Order does not matter (SetScale leaves the numeric offsets alone,
        -- it only changes how they are interpreted) but reading them after
        -- SetScale keeps the two steps from looking independent.
        if entry.keepPosition ~= false then
            RescaleOffsets(f, old, want)
        end
        if entry.clamp ~= false then
            ClampOnScreen(f)
        end
        -- Persist the CORRECTED anchor, or the addon saves pre-scale offsets
        -- and the window jumps on the next login.
        --
        -- ⚠ Guarded on the frame actually HAVING an anchor. A window that is
        -- built at file scope but not positioned until it first opens has no
        -- points here, so GetPoint() returns nil -- and a savePosition callback
        -- handed nils would write a junk position table over a real saved one.
        -- Nothing was re-anchored in that case either, so there is nothing to
        -- persist: it gets its position, at the current scale, when it opens.
        if f:GetNumPoints() > 0 then
            if entry.savePosition then
                entry.savePosition(f)
            elseif f.SavePosition then
                f.SavePosition()
            end
        end
    end

    entry.applied = want
    -- Always fires, even when the scale did not move: owners use it to
    -- re-derive size bounds that also depend on the screen (the Dashboard
    -- re-computes its resize ceiling here), and those go stale on a
    -- resolution change with no scale change at all.
    if entry.onScaleChanged then entry.onScaleChanged(f, want) end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function UncappedUIKit.GetUIScale()
    return current
end

function UncappedUIKit.GetUIScaleBounds()
    return MIN_SCALE, MAX_SCALE, STEP, DEFAULT_SCALE
end

-- The declared groups, in display order. The options page builds one slider per
-- entry; returning the table itself is fine because nothing mutates it.
function UncappedUIKit.GetScaleGroups()
    return GROUPS
end

function UncappedUIKit.GetGroupScale(group)
    return GroupFactor(group)
end

-- Re-applies immediately, like the global setter, so a dragged slider moves the
-- window under the player's cursor rather than on the next login.
function UncappedUIKit.SetGroupScale(group, v)
    if not group then return 1 end
    v = Clamp(v)
    GroupDB()[group] = v
    UncappedUIKit.ApplyUIScale()
    return v
end

-- Re-applies the current scale to every registered frame.
function UncappedUIKit.ApplyUIScale()
    for i = 1, #entries do
        ApplyTo(entries[i])
    end
    for i = 1, #listeners do
        listeners[i](current)
    end
end

function UncappedUIKit.SetUIScale(v)
    v = Clamp(v)
    local changed = math_abs(v - current) > 0.0005
    current = v
    ScaleDB().uiScale = v
    -- Re-apply even when unchanged: callers use this as "make it so".
    UncappedUIKit.ApplyUIScale()
    return current, changed
end

-- opts (all optional):
--   base / getBase(frame)  the frame's own zoom; the global setting multiplies it
--   getFitSize(frame)      -> w, h  logical size that must stay on screen
--   keepPosition           default true; false = frame re-places itself in
--                          onScaleChanged (the Dashboard re-centres)
--   clamp                  default true
--   savePosition(frame)    persist the corrected anchor; defaults to the
--                          frame's own SavePosition method when it has one
--   onScaleChanged(frame, applied)
--
-- ★ frame MUST be parented to UIParent. See the header.
function UncappedUIKit.RegisterScaledFrame(frame, opts)
    if not frame or not frame.SetScale then return nil end

    local entry = byFrame[frame]
    if not entry then
        entry = { frame = frame }
        entries[#entries + 1] = entry
        byFrame[frame] = entry
    end
    if opts then
        for k, v in pairs(opts) do entry[k] = v end
    end
    ApplyTo(entry)
    return entry
end

function UncappedUIKit.UnregisterScaledFrame(frame)
    local entry = byFrame[frame]
    if not entry then return end
    byFrame[frame] = nil
    for i = 1, #entries do
        if entries[i] == entry then
            table.remove(entries, i)
            return
        end
    end
end

-- Re-resolves ONE frame -- for an addon whose own per-frame scale slider just
-- moved, so it does not have to touch SetScale itself (which would drop the
-- global multiplier on the floor).
function UncappedUIKit.RefreshScaledFrame(frame)
    local entry = byFrame[frame]
    if entry then ApplyTo(entry) end
end

function UncappedUIKit.OnUIScaleChanged(callback)
    if type(callback) ~= "function" then return end
    listeners[#listeners + 1] = callback
end

-- Plain globals so an addon can register without naming the kit's table, and
-- so a call site reads as one line. Still requires UncappedUI to have loaded
-- first -- every registering addon lists it in ## OptionalDeps, which is what
-- forces that load order.
function _G.UncappedScale_Register(frame, opts)
    return UncappedUIKit.RegisterScaledFrame(frame, opts)
end

function _G.UncappedScale_Refresh(frame)
    return UncappedUIKit.RefreshScaledFrame(frame)
end

function _G.UncappedScale_GroupGet(group)
    return UncappedUIKit.GetGroupScale(group)
end

function _G.UncappedScale_GroupSet(group, v)
    return UncappedUIKit.SetGroupScale(group, v)
end

function _G.UncappedScale_Get()
    return current
end

-- ---------------------------------------------------------------------------
-- Load / re-apply
-- ---------------------------------------------------------------------------
-- ADDON_LOADED is where the saved value first becomes readable. PLAYER_LOGIN
-- re-applies it because frames registered between the two (anything built at
-- another addon's file scope, e.g. the Mythic+ HUD) came up before the saved
-- value was known, and because UIParent's final size -- which every fit cap
-- depends on -- is only trustworthy by then.
--
-- The two display events cover the player changing the GAME's own UI scale or
-- their resolution while logged in: UIParent's height in units moves, so the
-- fit caps have to be recomputed or a window can be left taller than the
-- screen with nothing to notice it.
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("DISPLAY_SIZE_CHANGED")
loader:RegisterEvent("UI_SCALE_CHANGED")
loader:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" then
        if name ~= UncappedUIKit.ADDON then return end
        local db = ScaleDB()
        if db.uiScale ~= nil then current = Clamp(db.uiScale) end
        db.uiScale = current
    end
    UncappedUIKit.ApplyUIScale()
end)

-- ---------------------------------------------------------------------------
-- /uiscale -- same shape as /uitheme next door.
-- ---------------------------------------------------------------------------
SLASH_UNCAPPEDUISCALE1 = "/uiscale"
SlashCmdList["UNCAPPEDUISCALE"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "" then
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                "|cff40c0ff[UI]|r Uncapped window scale: |cffffd100%.2f|r  |cff808080(/uiscale %.1f - %.1f, or use ESC > Interface > AddOns > Uncapped)|r",
                current, MIN_SCALE, MAX_SCALE))
        end
        return
    end
    local v = UncappedUIKit.SetUIScale(msg:match("([%d%.]+)"))
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff40c0ff[UI]|r Uncapped window scale set to |cffffd100%.2f|r.", v))
    end
end
