-- UncappedUIKit Effects.NineSlice -- places one texture around a frame as nine
-- (well, eight) pieces: four fixed-size corners with the edges stretched
-- between them.
--
-- ★ WHY NOT SetBackdrop's edgeFile? Because that format is a horizontal strip
--   whose eight tiles must be in an exact order, and getting that order or the
--   tile orientation wrong fails SILENTLY -- you get a subtly wrong border and
--   no error. Here the caller supplies one square texture and THIS file decides
--   which region each piece samples, so there is no convention to get wrong and
--   every asset is authored the same way: slice lines at 25% and 75%.
--
-- ★ THE POINT OF FIXED CORNERS is that a rounded corner keeps its radius and
--   a glow keeps its thickness at ANY frame size. Stretching a single square
--   texture over a 260x34 button instead squashes the curve flat along the long
--   axis -- which is exactly the bug that made the first glow read as a band
--   top-and-bottom with nothing on the ends.
--
-- ⚠ Every piece is a texture on the OWNER frame, never on a child frame. A
--   child draws at a higher frame level and would cover the owner's own
--   contents; and 3.3.5a has no SetClipsChildren, so a child could not be
--   clipped back either.

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

local unpack = unpack

-- Anchors are expressed relative to the OWNER for the corners, and relative to
-- the already-placed CORNERS for the edges. Anchoring edges to corners rather
-- than computing offsets means the edges cannot drift out of alignment.
local CORNERS = {
    { key = "tl", p = "TOPLEFT",     rp = "TOPLEFT",     ox = -1, oy =  1 },
    { key = "tr", p = "TOPRIGHT",    rp = "TOPRIGHT",    ox =  1, oy =  1 },
    { key = "bl", p = "BOTTOMLEFT",  rp = "BOTTOMLEFT",  ox = -1, oy = -1 },
    { key = "br", p = "BOTTOMRIGHT", rp = "BOTTOMRIGHT", ox =  1, oy = -1 },
}
local EDGES = {
    { key = "top",    a = { "TOPLEFT", "tl", "TOPRIGHT" },     b = { "BOTTOMRIGHT", "tr", "BOTTOMLEFT" } },
    { key = "bottom", a = { "TOPLEFT", "bl", "TOPRIGHT" },     b = { "BOTTOMRIGHT", "br", "BOTTOMLEFT" } },
    { key = "left",   a = { "TOPLEFT", "tl", "BOTTOMLEFT" },   b = { "BOTTOMRIGHT", "bl", "TOPRIGHT" } },
    { key = "right",  a = { "TOPLEFT", "tr", "BOTTOMLEFT" },   b = { "BOTTOMRIGHT", "br", "TOPRIGHT" } },
}

local function TexCoords(q)
    local r = 1 - q
    return {
        tl     = { 0, q, 0, q },   tr    = { r, 1, 0, q },
        bl     = { 0, q, r, 1 },   br    = { r, 1, r, 1 },
        top    = { q, r, 0, q },   bottom = { q, r, r, 1 },
        left   = { 0, q, q, r },   right  = { r, 1, q, r },
    }
end

-- opts:
--   texture     texture path (may be set later with ns:SetTexture)
--   layer       draw layer, default "ARTWORK"
--   sublayer    draw sublevel, default 0
--   blend       "BLEND" (default) or "ADD" for anything that should glow
--   cornerFrac  fraction of the source that is corner, default 0.25
function UncappedUIKit.CreateNineSlice(owner, opts)
    if not owner then return nil end
    opts = opts or {}
    local layer = opts.layer or "ARTWORK"
    local sub = opts.sublayer or 0
    local q = opts.cornerFrac or 0.25
    local tc = TexCoords(q)

    local ns = { owner = owner, pieces = {}, byKey = {} }

    local function make(key)
        local t = owner:CreateTexture(nil, layer)
        t:SetDrawLayer(layer, sub)
        if opts.blend then t:SetBlendMode(opts.blend) end
        if opts.texture then t:SetTexture(opts.texture) end
        t:SetTexCoord(tc[key][1], tc[key][2], tc[key][3], tc[key][4])
        t:Hide()
        ns.pieces[#ns.pieces + 1] = t
        ns.byKey[key] = t
        return t
    end

    for _, c in ipairs(CORNERS) do make(c.key) end
    for _, e in ipairs(EDGES) do make(e.key) end

    -- outset: how far the whole thing sits OUTSIDE the owner (0 = flush).
    -- corner: rendered size of each corner piece, in pixels.
    function ns:SetGeometry(outset, corner)
        outset = outset or 0
        corner = corner or 8
        for _, c in ipairs(CORNERS) do
            local t = self.byKey[c.key]
            t:ClearAllPoints()
            t:SetWidth(corner); t:SetHeight(corner)
            t:SetPoint(c.p, self.owner, c.rp, c.ox * outset, c.oy * outset)
        end
        for _, e in ipairs(EDGES) do
            local t = self.byKey[e.key]
            t:ClearAllPoints()
            t:SetPoint(e.a[1], self.byKey[e.a[2]], e.a[3], 0, 0)
            t:SetPoint(e.b[1], self.byKey[e.b[2]], e.b[3], 0, 0)
        end
    end

    function ns:SetTexture(path)
        for i = 1, #self.pieces do self.pieces[i]:SetTexture(path) end
    end
    function ns:SetVertexColor(r, g, b)
        for i = 1, #self.pieces do self.pieces[i]:SetVertexColor(r, g, b) end
    end
    function ns:SetAlpha(a)
        for i = 1, #self.pieces do self.pieces[i]:SetAlpha(a) end
    end
    function ns:Show()
        for i = 1, #self.pieces do self.pieces[i]:Show() end
    end
    function ns:Hide()
        for i = 1, #self.pieces do self.pieces[i]:Hide() end
    end

    ns:SetGeometry(opts.outset, opts.corner)
    return ns
end
