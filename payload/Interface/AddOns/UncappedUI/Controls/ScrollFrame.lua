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
    return scroll
end
