-- UncappedUI Controls.ScrollFrame -- FauxScrollFrameTemplate wrapper,
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

local UncappedUI = _G.UncappedUI
if not UncappedUI then return end

local nameCounter = 0
local function NextName(prefix)
    nameCounter = nameCounter + 1
    return prefix .. nameCounter
end

-- rowHeight/visibleRows: fixed per-row pixel height and pool size used to
-- compute the scroll offset/range. onScroll() is called after the offset
-- changes -- wire your row-render function in there.
function UncappedUI.CreateFauxScrollFrame(parent, rowHeight, visibleRows, onScroll)
    local scroll = CreateFrame("ScrollFrame", NextName("UncappedUIFauxScroll"), parent, "FauxScrollFrameTemplate")
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
