-- Wishlist / farming tracker window.
--
-- Shows what you are farming for and how close you are:
--
--     Copper Pants x10
--       2/20 Copper Bar
--         0/40 Copper Ore
--
-- Indented rows are expansions of a SHORTFALL -- you are 18 Copper Bars short,
-- which is 36 Copper Ore. Materials you already have enough of never expand.
--
-- Updates arrive unprompted from the server whenever something tracked lands in
-- your bags, bank or reagent bank, so the numbers move while you farm. Nothing
-- is printed to chat; the window just redraws. Lines accumulate into a buffer
-- and only render on RBWLEND, so a half-received list never displays as if it
-- were complete.
--
-- Toggle with /wishlist. Add items from the crafting window's Track button.

-- Re-read from ReagentBankCraftDB (shared with ReagentBankCraft.lua) each time
-- the rows are (re)built, so the "Wishlist visible rows" slider takes effect on
-- the next open. Render/Toggle capture it as an upvalue, so reassigning it in
-- RebuildRows updates every closure. Starts at the DB default.
local MAX_ROWS = 22
local WISHLIST_DEFAULT_POS = { "CENTER", "CENTER", -320, 0 }

ReagentBankWishlist_Buffer = {}
ReagentBankWishlist_Entries = {}

local frame = CreateFrame("Frame", "ReagentBankWishlistFrame", UIParent)
frame:SetSize(340, 420)
frame:SetPoint("CENTER", UIParent, "CENTER", -320, 0)
frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    if ReagentBankCraft_SavePos then
        ReagentBankCraft_SavePos(self, "wishlistPos")
    end
end)
frame:Hide()

-- Re-applies the saved (or default) window position. Also used by the settings
-- page's "Reset window positions" button.
function ReagentBankWishlist_RestoreWindow()
    if ReagentBankCraft_RestorePos then
        ReagentBankCraft_RestorePos(frame, "wishlistPos",
            WISHLIST_DEFAULT_POS[1], WISHLIST_DEFAULT_POS[2], WISHLIST_DEFAULT_POS[3], WISHLIST_DEFAULT_POS[4])
    end
end

frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
frame.title:SetPoint("TOPLEFT", 20, -18)
frame.title:SetText("Wishlist")

frame.close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
frame.close:SetPoint("TOPRIGHT", -8, -8)

frame.rows = {}
frame.rowButtons = {}

-- (Re)creates rows to match the current DB row count. Extra rows from a larger
-- previous build are hidden rather than destroyed.
local function RebuildRows()
    MAX_ROWS = (ReagentBankCraftDB and ReagentBankCraftDB.wishlistRows) or 22
    for i = 1, MAX_ROWS do
        local fs = frame.rows[i]
        if not fs then
            fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetWidth(295)
            fs:SetJustifyH("LEFT")
            frame.rows[i] = fs

            -- Invisible hit area over each row. FontStrings cannot take clicks,
            -- so removal needs a real frame on top; only rows that are a wishlist
            -- HEADER get wired up, and the rest stay inert.
            local hit = CreateFrame("Button", nil, frame)
            hit:SetSize(300, 16)
            hit:RegisterForClicks("RightButtonUp")
            frame.rowButtons[i] = hit
        end
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", 22, -40 - (i - 1) * 16)
        fs:Show()
        local hit = frame.rowButtons[i]
        hit:ClearAllPoints()
        hit:SetPoint("TOPLEFT", 20, -40 - (i - 1) * 16)
        hit:Hide()
    end
    for i = MAX_ROWS + 1, #frame.rows do
        frame.rows[i]:SetText("")
        frame.rows[i]:Hide()
        frame.rowButtons[i]:Hide()
        frame.rowButtons[i]:SetScript("OnClick", nil)
    end
end

RebuildRows()

-- Every open re-applies DB-driven sizing and window position before the fresh
-- list arrives from the server.
frame:SetScript("OnShow", function(self)
    RebuildRows()
    ReagentBankWishlist_RestoreWindow()
end)

-- Converts a {r,g,b} (0-1) DB colour into a "|cffRRGGBB" escape, falling back to
-- the given default table when unset.
local function ColorEscape(c, fallback)
    c = c or fallback
    local r = math.floor((c[1] or 1) * 255 + 0.5)
    local g = math.floor((c[2] or 1) * 255 + 0.5)
    local b = math.floor((c[3] or 1) * 255 + 0.5)
    return string.format("|cff%02x%02x%02x", r, g, b)
end

StaticPopupDialogs["REAGENTBANK_WISHLIST_REMOVE"] = {
    text = "Stop tracking %s?",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, itemId)
        if itemId then
            ReagentBankCraft_Send("RBWISHDEL:" .. itemId)
        end
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

local function Render()
    for i = 1, MAX_ROWS do
        frame.rows[i]:SetText("")
        frame.rowButtons[i]:Hide()
        frame.rowButtons[i]:SetScript("OnClick", nil)
    end

    local row = 1

    if #ReagentBankWishlist_Entries == 0 then
        frame.rows[1]:SetText("|cff888888Nothing tracked.|r")
        frame.rows[2]:SetText("|cff888888Open a crafting window, pick a recipe,|r")
        frame.rows[3]:SetText("|cff888888and click Track.|r")
        return
    end

    for _, entry in ipairs(ReagentBankWishlist_Entries) do
        if row > MAX_ROWS then break end

        frame.rows[row]:SetText(string.format("|cffffd100%s x%d|r  |cff666666(right-click to remove)|r", entry.name, entry.quantity))

        local hit = frame.rowButtons[row]
        hit:SetScript("OnClick", function()
            local popup = StaticPopup_Show("REAGENTBANK_WISHLIST_REMOVE", entry.name)
            if popup then
                popup.data = entry.itemId
            end
        end)
        hit:Show()

        row = row + 1

        for _, mat in ipairs(entry.materials) do
            if row > MAX_ROWS then break end

            -- Green once satisfied, red while short (both configurable on the
            -- settings page). Colour is doing the real work here: the point is to
            -- see at a glance what still needs doing.
            local db = ReagentBankCraftDB
            local colour = (mat.have >= mat.need)
                and ColorEscape(db and db.haveColor, { 0.0, 1.0, 0.0 })
                or ColorEscape(db and db.needColor, { 1.0, 0.333, 0.333 })
            local indent = string.rep("  ", (mat.depth or 0) + 1)

            frame.rows[row]:SetText(string.format("%s%s%d/%d|r %s",
                indent, colour, mat.have, mat.need, mat.name))
            row = row + 1
        end
    end
end

function ReagentBankWishlist_Toggle()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        ReagentBankCraft_Send("RBWISHGET:0")
    end
end

function ReagentBankWishlist_Track(itemId, quantity)
    ReagentBankCraft_Send("RBWISHSET:" .. itemId .. ":" .. quantity)
    frame:Show()
end

-- Called by the shared message handler in ReagentBankCraft.lua.
function ReagentBankWishlist_OnMessage(text)
    if text:find("^RBWL:") then
        local itemId, qty, name = text:match("^RBWL:(%d+):(%d+):(.*)$")
        if itemId then
            table.insert(ReagentBankWishlist_Buffer, {
                itemId = tonumber(itemId),
                quantity = tonumber(qty) or 1,
                name = name or "?",
                materials = {},
            })
        end
        return true
    end

    if text:find("^RBWLM:") then
        local _, matId, have, need, depth, name = text:match("^RBWLM:(%d+):(%d+):(%d+):(%d+):(%d+):(.*)$")
        local entry = ReagentBankWishlist_Buffer[#ReagentBankWishlist_Buffer]
        if entry and matId then
            table.insert(entry.materials, {
                itemId = tonumber(matId),
                have = tonumber(have) or 0,
                need = tonumber(need) or 0,
                depth = tonumber(depth) or 0,
                name = name or "?",
            })
        end
        return true
    end

    if text:find("^RBWLEND:") then
        ReagentBankWishlist_Entries = ReagentBankWishlist_Buffer
        ReagentBankWishlist_Buffer = {}
        Render()
        return true
    end

    return false
end

-- Re-renders the current list in place (e.g. after a colour change on the
-- settings page), without asking the server for fresh data.
function ReagentBankWishlist_Rerender()
    if frame:IsShown() then
        Render()
    end
end

SLASH_REAGENTWISHLIST1 = "/wishlist"
SlashCmdList["REAGENTWISHLIST"] = function()
    ReagentBankWishlist_Toggle()
end
