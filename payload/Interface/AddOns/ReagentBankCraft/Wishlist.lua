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

local MAX_ROWS = 22

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
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:Hide()

frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
frame.title:SetPoint("TOPLEFT", 20, -18)
frame.title:SetText("Wishlist")

frame.close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
frame.close:SetPoint("TOPRIGHT", -8, -8)

frame.rows = {}
for i = 1, MAX_ROWS do
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", 22, -40 - (i - 1) * 16)
    fs:SetWidth(295)
    fs:SetJustifyH("LEFT")
    frame.rows[i] = fs
end

local function Render()
    for i = 1, MAX_ROWS do
        frame.rows[i]:SetText("")
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

        frame.rows[row]:SetText(string.format("|cffffd100%s x%d|r", entry.name, entry.quantity))
        row = row + 1

        for _, mat in ipairs(entry.materials) do
            if row > MAX_ROWS then break end

            -- Green once satisfied, red while short. Colour is doing the real
            -- work here: the point is to see at a glance what still needs doing.
            local colour = (mat.have >= mat.need) and "|cff00ff00" or "|cffff5555"
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

SLASH_REAGENTWISHLIST1 = "/wishlist"
SlashCmdList["REAGENTWISHLIST"] = function()
    ReagentBankWishlist_Toggle()
end
