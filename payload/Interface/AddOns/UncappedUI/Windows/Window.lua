-- UncappedUI Windows.Window -- themed top-level window chrome: backdrop,
-- banner, title, close button, drag-to-move, optional resize grip, and
-- position/size persistence into a caller-supplied SavedVariables table.

local UncappedUI = _G.UncappedUI
if not UncappedUI then return end

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
    win.banner:SetTexture(theme.textures.windowBanner)
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
function UncappedUI.CreateWindow(opts)
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
        grip:SetScript("OnMouseUp", function() win:StopMovingOrSizing(); SavePosition() end)
        win.resizeGrip = grip
    end

    if opts.name and opts.escapeClose ~= false then
        tinsert(UISpecialFrames, opts.name)
    end

    win.banner = win:CreateTexture(nil, "ARTWORK")
    win.banner:SetWidth(256); win.banner:SetHeight(64)
    win.banner:SetPoint("TOP", 0, 12)

    win.titleText = UncappedUI.CreateText(win, "title", "TOP", win, "TOP", 0, 1, opts.title or "")

    win.closeButton = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    win.closeButton:SetPoint("TOPRIGHT", -6, -6)

    if opts.onReceiveDrag then win:SetScript("OnReceiveDrag", opts.onReceiveDrag) end
    if opts.onMouseUp then win:SetScript("OnMouseUp", opts.onMouseUp) end

    UncappedUI.Register(win, ApplyWindowSkin)

    win:Hide()
    return win
end
