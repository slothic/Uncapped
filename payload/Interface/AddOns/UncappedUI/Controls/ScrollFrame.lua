-- UncappedUIKit Controls.ScrollFrame -- FauxScrollFrameTemplate wrapper,
-- matching the scroll pattern already proven to work elsewhere in this
-- codebase on this 3.3.5 client (see UncappedForge.lua). A real
-- ScrollFrame + SetScrollChild has known gotchas on this build -- e.g.
-- `.ScrollBar` is not a field on the frame here, only a global named
-- "<frameName>ScrollBar" (a later-expansion convenience absent in
-- 3.3.5) -- so this sticks to what's already tested and working.
--
-- FauxScrollFrame is virtual scrolling: a small fixed pool of visible
-- rows gets rebound to different data as the user scrolls, instead of a
-- real scroll child growing to full content height. Build the row pool
-- yourself (see Navigation\Sidebar.lua for the pattern), then:
--   1. Call scroll:Update(totalCount) whenever the row count changes.
--   2. Inside `onScroll` (and after every Update), read the offset with
--      FauxScrollFrame_GetOffset(scroll) and re-populate rows from
--      data[offset + i].
--
-- There's no stock horizontal-scroll equivalent in this client either --
-- see the note in Navigation\Sidebar.lua if that's ever needed.

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

-- ★ SCROLLBAR SKINNING. FauxScrollFrameTemplate builds its scrollbar from
--   UIPanelScrollBarTemplate, whose parts are reachable only as GLOBALS derived
--   from the frame's name -- "<name>ScrollBar", plus that bar's own Top/Middle/
--   Bottom track textures and its up/down buttons. That is exactly why this
--   control grew a `name` parameter (see the note on CreateFauxScrollFrame):
--   without a predictable name none of this is addressable.
--
-- ⚠ EVERY LOOKUP IS GUARDED. These globals are created by a Blizzard template
--   this kit does not own; if a future template stops producing one of them the
--   scrollbar must keep working unstyled, not throw. An unskinned scrollbar is
--   a blemish -- a Lua error is a broken panel.
local function SkinScrollBar(scroll, theme)
    local name = scroll:GetName()
    if not name then return end
    local bar = _G[name .. "ScrollBar"]
    if not bar then return end

    local t, c = theme.textures, theme.colors

    -- Track: Blizzard draws it as three stacked textures. Hide them and lay our
    -- own single channel behind the thumb instead.
    for _, suffix in ipairs({ "Top", "Middle", "Bottom" }) do
        local piece = _G[name .. "ScrollBar" .. suffix]
        if piece then
            if t.scrollTrack then piece:Hide() else piece:Show() end
        end
    end

    if t.scrollTrack then
        if not bar.uncappedTrack then
            bar.uncappedTrack = bar:CreateTexture(nil, "BACKGROUND")
            bar.uncappedTrack:SetPoint("TOPLEFT", 4, -18)
            bar.uncappedTrack:SetPoint("BOTTOMRIGHT", -4, 18)
        end
        bar.uncappedTrack:SetTexture(t.scrollTrack)
        local tc = c.scrollTrackTint or { 1, 1, 1 }
        bar.uncappedTrack:SetVertexColor(tc[1], tc[2], tc[3])
        bar.uncappedTrack:Show()
    elseif bar.uncappedTrack then
        bar.uncappedTrack:Hide()
    end

    -- Recount reaches the thumb as "<name>ScrollBarThumbTexture"; the Slider
    -- method is the tidier route. Try the method, fall back to the global.
    local thumb = (bar.GetThumbTexture and bar:GetThumbTexture())
        or _G[name .. "ScrollBarThumbTexture"]
    if thumb and t.scrollThumb then
        thumb:SetTexture(t.scrollThumb)
        local tc = c.scrollThumbTint or { 1, 1, 1 }
        thumb:SetVertexColor(tc[1], tc[2], tc[3])
        thumb:SetWidth(12)
    end

    -- The arrow buttons keep their shape but lose Blizzard's gold.
    for _, suffix in ipairs({ "ScrollUpButton", "ScrollDownButton" }) do
        local b = _G[name .. "ScrollBar" .. suffix]
        if b then
            local tc = c.scrollThumbTint or { 1, 1, 1 }
            for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetDisabledTexture" }) do
                local tex = b[getter] and b[getter](b)
                if tex then tex:SetVertexColor(tc[1], tc[2], tc[3]) end
            end
        end
    end
end

-- ★ EIGHTEEN OF THIS SUITE'S SCROLLING LISTS DO NOT COME THROUGH THIS FILE.
--   Every Dashboard tab -- Vault, Forge, Soul Forge's eight lists, Transmog,
--   Keystone, Prestige, Progress, Scrolls, Anima -- builds its own
--   FauxScrollFrameTemplate directly, so skinning only the kit-built ones would
--   have left a stock blue-and-gold scrollbar on essentially every list a player
--   actually scrolls.
--
--   Rather than edit eighteen call sites, we hook the one function they all must
--   call to work at all, and skin the frame the first time it updates.
--
-- ⚠ GATED ON THE NAME PREFIX. This hook sees EVERY FauxScrollFrame in the
--   game, including other addons'. Restyling Recount's scrollbar because it
--   happened to scroll would be hostile. Only frames we named get touched.
local OUR_PREFIX = "Uncapped"
local autoSkinned = setmetatable({}, { __mode = "k" })

local function EnsureSkinned(frame)
    if not frame or autoSkinned[frame] then return end
    local n = frame.GetName and frame:GetName()
    if not n or n:sub(1, #OUR_PREFIX) ~= OUR_PREFIX then return end
    autoSkinned[frame] = true
    -- Register applies immediately AND re-applies on every /uitheme.
    UncappedUIKit.Register(frame, SkinScrollBar)
end

if hooksecurefunc and FauxScrollFrame_Update then
    hooksecurefunc("FauxScrollFrame_Update", EnsureSkinned)
end

local nameCounter = 0
local function NextName(prefix)
    nameCounter = nameCounter + 1
    return prefix .. nameCounter
end

-- rowHeight/visibleRows: fixed per-row pixel height and pool size used to
-- compute the scroll offset/range. onScroll() is called after the offset
-- changes -- wire your row-render function in there.
--
-- ★★ `name` is optional but almost always wanted, and its absence is why this
--    control had ZERO users outside the kit (UI audit, 2026-08-16).
--
--    FauxScrollFrameTemplate creates its scrollbar as a global named
--    `<frameName>ScrollBar`. With a generated name the caller cannot predict
--    that global, so it cannot reach the scrollbar -- and reaching it is how you
--    wire mouse-wheel scrolling, which every list in this suite wants. Callers
--    therefore skipped the kit and hand-rolled the frame purely to control the
--    name; UncappedLootFeed_UI.lua says so in a comment.
--
--    Pass a name and the scrollbar is addressable. Omit it and you get the old
--    generated-name behaviour, so existing callers are unaffected.
function UncappedUIKit.CreateFauxScrollFrame(parent, rowHeight, visibleRows, onScroll, name)
    local scroll = CreateFrame("ScrollFrame", name or NextName("UncappedUIFauxScroll"), parent, "FauxScrollFrameTemplate")
    scroll.rowHeight = rowHeight
    scroll.visibleRows = visibleRows
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, rowHeight, onScroll)
    end)
    function scroll:Update(totalCount)
        FauxScrollFrame_Update(self, totalCount, self.visibleRows, self.rowHeight)
    end

    -- Always skinnable: this frame is created with `name or NextName(...)`, so it
    -- ALWAYS has a name and its scrollbar globals are always addressable. The
    -- `name` parameter exists so the CALLER can predict those globals (to wire
    -- mouse-wheel scrolling), which is a different problem from this one.
    UncappedUIKit.Register(scroll, SkinScrollBar)

    return scroll
end
