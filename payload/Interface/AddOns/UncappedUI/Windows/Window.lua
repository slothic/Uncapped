-- UncappedUIKit Windows.Window -- themed top-level window chrome: backdrop,
-- banner, title, close button, drag-to-move, optional resize grip, and
-- position/size persistence into a caller-supplied SavedVariables table.

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

local floor = math.floor
local tinsert = table.insert
local unpack = unpack

local function ApplyWindowSkin(win, theme)
    win:SetBackdrop({
        bgFile = theme.textures.windowBG,
        edgeFile = theme.textures.windowEdge,
        tile = true, tileSize = 32, edgeSize = theme.metrics.windowEdgeSize,
        insets = theme.metrics.windowInsets,
    })

    -- ★ Tint. CreateWindow never set a backdrop colour at all, which is the
    --   same as multiplying the art by white -- so the whole window was locked
    --   to whatever hue Blizzard's dialog texture happens to be, no matter what
    --   the theme said. Tinting the STOCK art is what turns this chrome violet
    --   without a single new asset: the corner gem goes amethyst on its own.
    local c = theme.colors
    win:SetBackdropColor(unpack(c.windowTint or { 1, 1, 1, 1 }))
    win:SetBackdropBorderColor(unpack(c.windowBorderTint or { 1, 1, 1, 1 }))

    win.banner:SetTexture(theme.textures.windowBanner)
    win.banner:SetVertexColor(unpack(c.bannerTint or { 1, 1, 1 }))
    win.titleText:SetTextColor(unpack(theme.colors.gold))
    if win.resizeGrip then
        win.resizeGrip:SetNormalTexture(theme.textures.resizeGripUp)
        win.resizeGrip:SetHighlightTexture(theme.textures.resizeGripHighlight)
        win.resizeGrip:SetPushedTexture(theme.textures.resizeGripDown)
    end
end

-- opts:
--   name                    global frame name; also enables Escape-to-close
--   title                   banner title text
--   width/height            initial size (used when db has no saved size)
--   point                   initial anchor point (default "CENTER")
--   minWidth/minHeight      resize floor (only used when resizable)
--   maxWidth/maxHeight      resize ceiling (only used when resizable)
--   resizable               boolean, default false
--   movable                 boolean, default true -- set false for a
--                           companion window that should only move by
--                           following another window's live anchor
--                           (e.g. one snapped via SetPoint to it) rather
--                           than being dragged independently
--   db                      SavedVariables table for position + size
--   persistPosition         boolean, default true -- set false to persist
--                           width/height only, never point/x/y (e.g. a
--                           window that should always open centered based
--                           on its saved size rather than remembering
--                           where it was last dragged to)
--   escapeClose             default true (requires opts.name)
--   onReceiveDrag/onMouseUp optional passthrough scripts (e.g. bag deposit)
--   onResizeStop            optional fn(win), called after a resize-grip
--                           drag ends (StopMovingOrSizing) but before the
--                           final SavePosition -- e.g. to re-anchor the
--                           window instead of leaving it wherever the grip
--                           drag left it
--
--   -- user zoom (UncappedScale.lua); every kit window gets this for free
--   scaleBase               fn() -> number, this window's OWN scale, which the
--                           player's global zoom multiplies (default 1)
--   scaleFit                fn() -> w, h, logical size that must stay on
--                           screen; caps the zoom rather than letting the
--                           window grow past the screen edge
--   scaleKeepPosition       default true -- offsets are rewritten so the
--                           window's corner stays on the same screen pixel.
--                           Pass false only if onScaleChanged re-places the
--                           window itself (the Dashboard re-centres).
--   onScaleChanged          fn(win, appliedScale), after every (re)apply
function UncappedUIKit.CreateWindow(opts)
    opts = opts or {}
    local db = opts.db

    local win = CreateFrame("Frame", opts.name, UIParent)
    win:SetWidth((db and db.width) or opts.width or 400)
    win:SetHeight((db and db.height) or opts.height or 300)
    win:SetPoint(
        (db and db.point) or opts.point or "CENTER", UIParent,
        (db and db.relativePoint) or opts.point or "CENTER",
        (db and db.x) or 0, (db and db.y) or 0
    )
    win:SetFrameStrata(opts.strata or "HIGH")
    win:SetClampedToScreen(true)
    win:EnableMouse(true)

    local function SavePosition()
        if not db then return end
        if opts.persistPosition ~= false then
            local p, _, rp, x, y = win:GetPoint()
            db.point, db.relativePoint = p or "CENTER", rp or "CENTER"
            db.x, db.y = floor((x or 0) + 0.5), floor((y or 0) + 0.5)
        end
        db.width, db.height = win:GetWidth(), win:GetHeight()
    end
    win.SavePosition = SavePosition

    if opts.movable ~= false then
        win:SetMovable(true)
        win:RegisterForDrag("LeftButton")
        win:SetScript("OnDragStart", win.StartMoving)
        win:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            SavePosition()
        end)
    end

    if opts.resizable then
        win:SetResizable(true)
        if opts.minWidth then win:SetMinResize(opts.minWidth, opts.minHeight or opts.minWidth) end
        if opts.maxWidth then win:SetMaxResize(opts.maxWidth, opts.maxHeight or opts.maxWidth) end
        win:SetScript("OnSizeChanged", SavePosition)

        local grip = CreateFrame("Button", nil, win)
        grip:SetWidth(16); grip:SetHeight(16)
        grip:SetPoint("BOTTOMRIGHT", -5, 7)
        grip:SetScript("OnMouseDown", function() win:StartSizing("BOTTOMRIGHT") end)
        grip:SetScript("OnMouseUp", function()
            win:StopMovingOrSizing()
            if opts.onResizeStop then opts.onResizeStop(win) end
            SavePosition()
        end)
        win.resizeGrip = grip
    end

    if opts.name and opts.escapeClose ~= false then
        tinsert(UISpecialFrames, opts.name)
    end

    win.banner = win:CreateTexture(nil, "ARTWORK")
    win.banner:SetWidth(256); win.banner:SetHeight(64)
    win.banner:SetPoint("TOP", 0, 12)

    win.titleText = UncappedUIKit.CreateText(win, "title", "TOP", win, "TOP", 0, 1, opts.title or "")

    win.closeButton = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    win.closeButton:SetPoint("TOPRIGHT", -6, -6)

    if opts.onReceiveDrag then win:SetScript("OnReceiveDrag", opts.onReceiveDrag) end
    if opts.onMouseUp then win:SetScript("OnMouseUp", opts.onMouseUp) end

    UncappedUIKit.Register(win, ApplyWindowSkin)

    -- ★ THE WINDOW OWNS THE PLAYER'S ZOOM FOR EVERYTHING INSIDE IT.
    --
    -- SetScale compounds down the frame chain, so this single call is the ONLY
    -- one allowed for this window's whole tree: banner, title, close button,
    -- resize grip, and every panel a caller anchors into it (for the Dashboard
    -- that means all 15 tabs, including ones added later). Registering a child
    -- as well would multiply the zoom twice.
    --
    -- SavePosition is picked up automatically by RegisterScaledFrame, so the
    -- offsets it rewrites to keep the window put are the ones that persist.
    if UncappedUIKit.RegisterScaledFrame then
        UncappedUIKit.RegisterScaledFrame(win, {
            -- Which per-addon zoom slider owns this window. Defaults to nil,
            -- which means "global slider only" -- the behaviour every window had
            -- before per-addon zoom existed.
            group          = opts.scaleGroup,
            getBase        = opts.scaleBase,
            getFitSize     = opts.scaleFit,
            keepPosition   = opts.scaleKeepPosition,
            onScaleChanged = opts.onScaleChanged,
        })
    end

    win:Hide()
    return win
end
