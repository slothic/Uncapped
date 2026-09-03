-- UncappedBugReporter_UI -- the /bug report window.
-- Written for 3.3.5a: no BackdropTemplate and no modern C_ APIs.


--[[
    KitButton -- the in-house widget kit's button, with a guarded fall back to
    the raw Blizzard template.

    Guarded rather than calling UncappedUIKit directly because this addon lists
    UncappedUI as an OPTIONAL dependency: if it is absent or errored during load,
    an unguarded call is a nil index at build time and the whole window dies.
    Same shape as the fallback in UncappedKeystoneRun.

    ⚠ Resolved at FILE SCOPE on purpose. A `local UIKit` declared partway down
      and used above that line silently reads the nil GLOBAL of the same name --
      it parses fine and only errors when the window opens.
]]
local UIKit = _G.UncappedUIKit
local function KitButton(parent, label, w, h)
    if UIKit and UIKit.CreateButton then
        return UIKit.CreateButton(parent, label or "", w, h)
    end
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    if w then b:SetWidth(w) end
    if h then b:SetHeight(h) end
    b:SetText(label or "")
    return b
end

local BR = UncappedBugReporter
if not BR then return end

local UI = {}
BR.UI = UI

local WIDTH, HEIGHT = 420, 300
local MAX_REPORT = BR.MAX_REPORT
local MAX_TITLE = BR.MAX_TITLE
-- Shared left/right margins for the Title bar and the message box's visual
-- background, so the two line up exactly. Derived from the message scroll
-- frame's own inset from `frame` (20 / -36, the -36 leaving room for its
-- scrollbar) plus scrollBg's -5/+5 outset from that -- see scrollBg below.
local BOX_LEFT, BOX_RIGHT = 15, -31

local frame, titleBox, editBox, counter

local GOLD = { 1.00, 0.82, 0.22 }

local function SavePosition()
    local db = BR.GetDB()
    if not db or not frame then return end
    local point, _, relPoint, x, y = frame:GetPoint()
    -- A brand-new frame has no anchor at all until RestorePosition below sets
    -- one -- GetPoint() on that returns nils, and saving that would corrupt
    -- db.point permanently (every later restore then hands SetPoint a nil
    -- point string and crashes). Only save a point that's actually usable.
    if not point then return end
    db.point = { point, "UIParent", relPoint, x, y }
end

local function RestorePosition()
    local db = BR.GetDB()
    frame:ClearAllPoints()
    -- Also guards against a db.point already corrupted by the bug above from
    -- an earlier session -- self-heals instead of crashing forever.
    if db and db.point and type(db.point[1]) == "string" then
        frame:SetPoint(db.point[1], UIParent, db.point[3], db.point[4], db.point[5])
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    end
end

local function UpdateCounter()
    local len = editBox:GetText() and #editBox:GetText() or 0
    counter:SetText(len .. " / " .. MAX_REPORT)
    if len > MAX_REPORT then
        counter:SetTextColor(1, 0.3, 0.3)
    else
        counter:SetTextColor(0.7, 0.7, 0.7)
    end
end

local function Submit()
    local title = titleBox:GetText()
    local text = editBox:GetText()
    if BR.Send(title, text) then
        titleBox:SetText("")
        editBox:SetText("")
        frame:Hide()
    end
end

local function BuildFrame()
    if frame then return end

    frame = CreateFrame("Frame", "UncappedBugReporterFrame", UIParent)
    -- UI audit 2026-08-16: siblings of this window had these and it did not.
    tinsert(UISpecialFrames, "UncappedBugReporterFrame")   -- Escape closes it
    if UncappedScale_Register then UncappedScale_Register(frame, { group = "dashboard" }) end
    frame:SetWidth(WIDTH)
    frame:SetHeight(HEIGHT)
    frame:SetFrameStrata("DIALOG")
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 11, top = 11, bottom = 11 },
    })
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    -- Anchored BEFORE OnHide is wired up and before the initial Hide() below --
    -- a fresh CreateFrame starts shown, so :Hide() fires OnHide synchronously
    -- right there. Doing this after would let SavePosition capture a frame
    -- with no anchor at all (GetPoint() returning nils) and corrupt db.point.
    RestorePosition()
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    frame:SetScript("OnHide", SavePosition)
    frame:Hide()

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", frame, "TOP", 0, -16)
    title:SetText("Report a Bug")
    title:SetTextColor(GOLD[1], GOLD[2], GOLD[3])

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

    -- Same TOPLEFT + RIGHT anchor mismatch as the Title bar's old bug --
    -- RIGHT pins to the frame's vertical center rather than pairing cleanly
    -- with a top-pinned point, which left this FontString's wrap width
    -- undefined and let the text run past the window's right edge instead of
    -- wrapping. An explicit width fixes wrapping regardless of anchor quirks.
    local note = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -44)
    note:SetWidth(WIDTH - 40)
    note:SetJustifyH("LEFT")
    note:SetText("What happened, where, and how to repeat it. Goes straight to the dev Discord.")

    -- Short single-line summary -- rides in its own "[brackets]" on the wire
    -- so the Discord side can use it as the real title instead of synthesizing
    -- one by truncating the message body (see the file header for the format).
    local titleLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    titleLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -66)
    titleLabel:SetText("Title")
    titleLabel:SetTextColor(GOLD[1], GOLD[2], GOLD[3])

    -- Shares its left/right margins with scrollBg below (BOX_LEFT/BOX_RIGHT),
    -- not frame's own 20/-20 -- scrollBg's box is inset from `scroll`, which is
    -- itself narrower than the frame by an extra 16px on the right to leave
    -- room for the scrollbar, so matching frame's raw margins here made this
    -- bar visibly wider than the message box below it, with mismatched left
    -- edges too.
    --
    -- TOPLEFT + TOPRIGHT (both on the same edge), not TOPLEFT + RIGHT -- RIGHT
    -- anchors to the frame's vertical CENTER, which fights the explicit height
    -- below and an already-fixed top edge.
    local titleBg = CreateFrame("Frame", nil, frame)
    titleBg:SetPoint("TOPLEFT", frame, "TOPLEFT", BOX_LEFT, -80)
    titleBg:SetPoint("TOPRIGHT", frame, "TOPRIGHT", BOX_RIGHT, -80)
    titleBg:SetHeight(20)
    titleBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 8, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    titleBg:SetBackdropColor(0, 0, 0, 0.5)

    titleBox = CreateFrame("EditBox", "UncappedBugReporterTitle", titleBg)
    titleBox:SetPoint("TOPLEFT", titleBg, "TOPLEFT", 6, -2)
    titleBox:SetPoint("BOTTOMRIGHT", titleBg, "BOTTOMRIGHT", -6, 2)
    titleBox:SetFontObject(ChatFontNormal)
    titleBox:SetAutoFocus(false)
    titleBox:SetMaxLetters(MAX_TITLE)
    titleBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    titleBox:SetScript("OnEnterPressed", function(self) editBox:SetFocus() end)

    -- Scrollable multi-line box -- the standard Blizzard EditBox is single-line
    -- only; SetMultiLine plus a ScrollFrame parent is what a full report needs,
    -- since a one-line chat box is what made typing these awkward in the first
    -- place (see the file header on why this addon exists at all).
    local scroll = CreateFrame("ScrollFrame", "UncappedBugReporterScroll", frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -108)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -36, 74)

    -- Anchored to `frame` with BOX_LEFT/BOX_RIGHT (same as titleBg above), not
    -- outset from `scroll` itself -- `scroll` is inset from `frame` by 20/-36,
    -- so outsetting from IT by 5px lands at 15/-31, which is where
    -- BOX_LEFT/BOX_RIGHT come from; anchoring here directly guarantees the two
    -- boxes always match instead of relying on two separate derivations of the
    -- same numbers staying in sync. Top/bottom keep the original 5px padding
    -- around `scroll`'s own -108/74.
    local scrollBg = CreateFrame("Frame", nil, frame)
    scrollBg:SetPoint("TOPLEFT", frame, "TOPLEFT", BOX_LEFT, -103)
    scrollBg:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", BOX_RIGHT, 69)
    scrollBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 8, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    scrollBg:SetBackdropColor(0, 0, 0, 0.5)

    editBox = CreateFrame("EditBox", "UncappedBugReporterEditBox", scroll)
    editBox:SetMultiLine(true)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetWidth(WIDTH - 76)
    -- Taller than the visible scroll area on purpose -- this is the scroll
    -- child, so its own height is the scrollable range, not the window size.
    editBox:SetHeight(500)
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(MAX_REPORT)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editBox:SetScript("OnTextChanged", UpdateCounter)
    editBox:SetScript("OnKeyDown", function(self, keyv)
        -- Ctrl+Enter submits; plain Enter is a newline in a multi-line box.
        if keyv == "ENTER" and IsControlKeyDown() then
            Submit()
        end
    end)
    scroll:SetScrollChild(editBox)

    counter = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    counter:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 20, 46)

    local submit = KitButton(frame, "", 100, 24)
    submit:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -20, 16)
    submit:SetText("Send")
    submit:SetScript("OnClick", Submit)

    local cancel = KitButton(frame, "", 80, 24)
    cancel:SetPoint("RIGHT", submit, "LEFT", -8, 0)
    cancel:SetText("Cancel")
    cancel:SetScript("OnClick", function() frame:Hide() end)
end

function UI.Open()
    BuildFrame()
    frame:Show()
    titleBox:SetFocus()
    UpdateCounter()
end
