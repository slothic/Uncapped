--[[---------------------------------------------------------------------------
UncappedBulkBuy -- buy many of a vendor item in one action.  Report #846.

    "Add a way to mass buy items requiring currency. Spending Justice points on
     gear for example is a chore."

WHY THIS IS A WINDOW AND NOT A BOX ON THE MERCHANT FRAME
-------------------------------------------------------------------------------
The obvious answer -- a quantity field on MerchantFrame -- was tried on paper
first and does not survive contact with the stock UI:

  * Every merchant row already spends its clicks.  Left-click PICKS UP the item
    (drag to buy), right-click BUYS ONE, shift-click opens StackSplitFrame.  A
    quantity field has nothing left to be committed by except a fourth button
    squeezed into a 153x44 row that already holds an icon, a name, a money frame
    and up to three alt-currency icons.
  * StackSplitFrame -- the one stack-buy path that exists -- is the natural place
    and is useless for exactly the case #846 is about.  OpenStackSplitFrame bails
    on `maxStack < 2`, and a piece of gear has a stack size of one.  The whole
    complaint is gear.
  * MerchantFrame paginates at ten.  Any per-row control has to be rebuilt on
    every page turn and every MERCHANT_UPDATE, and re-anchored between the two
    tabs, for a control the player uses on ONE row at a time.

So: one panel, opened from a button beside the merchant window, that lists what
the vendor sells and gives the selected item a real quantity control with the
price, the balance and the limit spelled out in full.  It is a bulk purchase of
a currency that takes weeks to earn -- it deserves more than a spinbox.

⚠ Nothing here is hooked into MerchantFrame's click handling, on purpose.  The
buy path is a separate addon message; the stock right-click still buys exactly
one, and a player who never opens this panel sees the vendor window they have
always seen.

★★ AND THE CLIENT DOES NOT DECIDE ANYTHING
-------------------------------------------------------------------------------
Every number in this window arrives from the server (BVQ/BVC), including how
many you may buy.  The quantity box is CLAMPED here purely so the player is not
shown a total they cannot have -- the server clamps again, from balances it
re-reads at that instant, and would refuse anyway.  In particular:

  * "Max" is not computed here.  GetMoney()/price would ignore bag space, vendor
    stock, unique limits and the per-call cap, and -- the one that matters --
    the client's own GetItemCount is blind to the account Vault, which is a
    documented source of the client and server disagreeing about how much of a
    token you hold.  Max is whatever the server said Max is.
  * The confirmation shows the SERVER's totals, not a local multiplication.

CONFIRMATION
-------------------------------------------------------------------------------
ConfirmSpend below is the UncappedTransmog gate, kept deliberately identical in
shape (StaticPopup, `uncappedRun` on the dialog, and the "all popup slots taken
-> drop the click rather than spend unannounced" fallback, which is the part of
that pattern that is actually load-bearing).  The threshold rule is different
and stricter: transmog asks about a repeated small gold charge, this asks about
a one-shot bulk spend, so it ALWAYS asks.  There is no "don't show this again".

WIRE  (see the header of bulk_vendor_buy.cpp for the authoritative definition)
-------------------------------------------------------------------------------
    send  BVQ:<index>:<itemId>
          BVBUY:<index>:<itemId>:<count>
    recv  BVQ:...  BVC:...  BVEND:<index>  BVRES:...  BVERR:<why>

`index` is the merchant button's own GetID() -- the ABSOLUTE merchant index
across pages, which is what BuyMerchantItem takes and what the server maps back
to a vendor slot.  It is never a 1..10 page position.
-----------------------------------------------------------------------------]]

local ADDON = "UncappedBulkBuy"

local TRANSPORT_PREFIX = "REAGENTBANK"      -- client -> server
local PIPE = "UNC"                          -- server -> client

local ROWS = 7
local ROW_HEIGHT = 34
local ANSWER_TIMEOUT = 6                    -- seconds before we call it silence

local ACCENT = "|cff9d4edd"
local WARN = "|cffff4040"
local GOOD = "|cff40ff40"
local HINT = "|cffffd100"

local ui = {}                               -- every frame we build
local list = {}                             -- filtered vendor rows, rebuilt on demand
local view = { search = "", selected = nil, quantity = 1 }

-- quote[index] = { fresh = bool, asked = <GetTime()>, ... server fields ... }
local quote = {}
local pending = nil                         -- index we are mid-burst on
local incoming = nil                        -- the quote being assembled

-- ---------------------------------------------------------------------------
-- small helpers
-- ---------------------------------------------------------------------------

local function Send(msg)
    SendAddonMessage(TRANSPORT_PREFIX, msg, "WHISPER", UnitName("player"))
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(ACCENT .. "[Bulk Buy]|r " .. msg)
end

local function Icon(path, size)
    if not path or path == "" then return "" end
    size = size or 14
    return "|T" .. path .. ":" .. size .. ":" .. size .. ":0:0|t"
end

local HONOR_ICON = "Interface\\PVPFrame\\PVP-Currency-" .. (UnitFactionGroup("player") or "Alliance")
local ARENA_ICON = "Interface\\PVPFrame\\PVP-ArenaPoints-Icon"

-- The item id out of a merchant link.  Returns nil rather than 0 so a caller
-- cannot accidentally ask the server to price item zero.
local function LinkItemId(link)
    if not link then return nil end
    local id = link:match("item:(%d+)")
    return id and tonumber(id) or nil
end

-- Item texture for a cost component.  Preferred source is the merchant API,
-- which hands the texture over directly and needs no client item cache;
-- GetItemInfo is the fallback for the 4th and 5th cost slots, which the 3.3.5a
-- client cannot see at all (MAX_ITEM_COST is 3, the server's array is 5).
local function CostTexture(index, itemId)
    for i = 1, 3 do
        local texture, _, link = GetMerchantItemCostItem(index, i)
        if link and LinkItemId(link) == itemId then
            return texture
        end
    end

    local _, _, _, _, _, _, _, _, _, texture = GetItemInfo(itemId)
    return texture
end

local function ItemName(itemId)
    local name = GetItemInfo(itemId)
    return name or ("item " .. tostring(itemId))
end

-- "limited by ..." wording for the server's bound code.  Deliberately phrased as
-- the REASON rather than as an error: none of these is a failure, they are all
-- just the answer to "how many can I have".
local BOUND_TEXT = {
    none  = nil,
    cost  = "you cannot afford more",
    room  = "your bags have no more room",
    stock = "that is all the vendor has",
    cap   = "that is the most one purchase may buy",
}

local ERROR_TEXT = {
    off    = "Bulk buying is switched off on this realm.",
    busy   = "Too fast -- try that again in a second.",
    vendor = "Step back to the vendor and try again.",
    item   = "The vendor list moved. Close and reopen the merchant window.",
    rating = "That item still needs an arena rating you cannot earn here.",
    rep    = "You are not reputable enough with this faction to buy that.",
    denied = "The server refused the purchase.",
}

-- ---------------------------------------------------------------------------
-- confirmation
--
-- Same gate as UncappedTransmog's ConfirmSpend, including the failure branch:
-- if StaticPopup_Show returns nil every popup slot is taken, and the correct
-- answer is to DROP the click.  Spending somebody's emblems because the dialog
-- could not be shown is the one outcome this whole feature must never produce.
-- ---------------------------------------------------------------------------

StaticPopupDialogs["UNCAPPED_BULKBUY_CONFIRM"] = {
    text = "%s",
    button1 = ACCEPT,
    button2 = CANCEL,
    OnAccept = function(self) if self.uncappedRun then self.uncappedRun() end end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

local function ConfirmSpend(body, act)
    local dialog = StaticPopup_Show("UNCAPPED_BULKBUY_CONFIRM", body)
    if not dialog then
        Print(WARN .. "Could not show the confirmation, so nothing was bought.|r Try again in a moment.")
        return
    end
    dialog.uncappedRun = act
end

-- ---------------------------------------------------------------------------
-- the vendor list
-- ---------------------------------------------------------------------------

local function RebuildList()
    list = {}

    local total = GetMerchantNumItems() or 0
    local needle = view.search ~= "" and view.search:lower() or nil

    for index = 1, total do
        local name, texture, price, stackCount, numAvailable, _, extendedCost = GetMerchantItemInfo(index)
        if name then
            if not needle or name:lower():find(needle, 1, true) then
                table.insert(list, {
                    index = index,
                    itemId = LinkItemId(GetMerchantItemLink(index)),
                    name = name,
                    texture = texture,
                    price = price or 0,
                    stackCount = stackCount or 1,
                    available = numAvailable or -1,
                    extendedCost = extendedCost and true or false,
                })
            end
        end
    end
end

-- A one-line cost summary for a list row.  Gold uses the client's own coin
-- string; currency components use the merchant API's textures.  Kept short --
-- the full breakdown belongs in the detail pane, where there is room to be
-- honest about balances.
local function RowCost(entry)
    local parts = {}

    if entry.price and entry.price > 0 then
        table.insert(parts, GetCoinTextureString(entry.price))
    end

    local honor, arena = GetMerchantItemCostInfo(entry.index)
    if honor and honor > 0 then table.insert(parts, Icon(HONOR_ICON) .. honor) end
    if arena and arena > 0 then table.insert(parts, Icon(ARENA_ICON) .. arena) end

    for i = 1, 3 do
        local texture, value = GetMerchantItemCostItem(entry.index, i)
        if texture and value and value > 0 then
            table.insert(parts, Icon(texture) .. value)
        end
    end

    if #parts == 0 then return "|cff808080free|r" end
    return table.concat(parts, "  ")
end

-- ---------------------------------------------------------------------------
-- quotes
-- ---------------------------------------------------------------------------

local function InvalidateQuotes()
    quote = {}
    pending = nil
    incoming = nil
end

local function AskForQuote(index)
    local entry = nil
    for _, row in ipairs(list) do
        if row.index == index then entry = row break end
    end
    if not entry or not entry.itemId then return end

    pending = index
    incoming = { index = index, costs = {} }
    quote[index] = quote[index] or {}
    quote[index].asked = GetTime()

    Send("BVQ:" .. index .. ":" .. entry.itemId)
end

-- Has the answer for `index` gone missing?  A worldserver without this feature
-- never replies at all, and that must render as "unavailable" rather than as a
-- window stuck on "Asking...".
local function QuoteTimedOut(index)
    local q = quote[index]
    if not q or q.maxBuy then return false end
    return q.asked and (GetTime() - q.asked) > ANSWER_TIMEOUT
end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------

local Render        -- forward declaration; the detail pane and the list both call it

local function RenderList()
    if not ui.scroll then return end

    -- Update BEFORE reading the offset: a shorter list clamps the offset here,
    -- and reading first would draw one repaint's worth of blank rows every time
    -- the search box narrows the results.
    FauxScrollFrame_Update(ui.scroll, #list, ROWS, ROW_HEIGHT)

    local offset = FauxScrollFrame_GetOffset(ui.scroll) or 0

    for i = 1, ROWS do
        local row = ui.rows[i]
        local entry = list[i + offset]

        if entry then
            row.entry = entry
            row.icon:SetTexture(entry.texture)
            row.name:SetText(entry.name)
            row.cost:SetText(RowCost(entry))

            if view.selected == entry.index then
                row.selection:Show()
            else
                row.selection:Hide()
            end

            row:Show()
        else
            row.entry = nil
            row:Hide()
        end
    end
end

local function SelectedEntry()
    if not view.selected then return nil end
    for _, row in ipairs(list) do
        if row.index == view.selected then return row end
    end
    return nil
end

-- The cost of ONE purchase, laid out with what you hold beside it.  Balances
-- come from the server (BVQ/BVC) rather than from GetItemCount, because those
-- two do not always agree and only one of them is the one the purchase checks.
local function DetailCostLines(entry, q)
    local cost, have = {}, {}

    if q.copperEach and q.copperEach > 0 then
        table.insert(cost, GetCoinTextureString(q.copperEach))
        table.insert(have, GetCoinTextureString(q.money or 0))
    end

    if q.honorEach and q.honorEach > 0 then
        table.insert(cost, Icon(HONOR_ICON) .. q.honorEach)
        table.insert(have, Icon(HONOR_ICON) .. (q.honor or 0))
    end

    if q.arenaEach and q.arenaEach > 0 then
        table.insert(cost, Icon(ARENA_ICON) .. q.arenaEach)
        table.insert(have, Icon(ARENA_ICON) .. (q.arena or 0))
    end

    for _, component in ipairs(q.costs or {}) do
        local texture = CostTexture(entry.index, component.itemId)
        table.insert(cost, Icon(texture) .. component.each)
        table.insert(have, Icon(texture) .. component.have)
    end

    return cost, have
end

local function TotalString(entry, q, count)
    local parts = {}

    if q.copperEach and q.copperEach > 0 then
        table.insert(parts, GetCoinTextureString(q.copperEach * count))
    end
    if q.honorEach and q.honorEach > 0 then
        table.insert(parts, Icon(HONOR_ICON) .. (q.honorEach * count))
    end
    if q.arenaEach and q.arenaEach > 0 then
        table.insert(parts, Icon(ARENA_ICON) .. (q.arenaEach * count))
    end
    for _, component in ipairs(q.costs or {}) do
        table.insert(parts, Icon(CostTexture(entry.index, component.itemId)) .. (component.each * count))
    end

    if #parts == 0 then return "nothing" end
    return table.concat(parts, "  ")
end

local function RenderDetail()
    -- SetQuantity reaches here directly (from the protocol handlers as well as
    -- from the box), and those can land before the panel has ever been built.
    if not ui.frame then return end

    local entry = SelectedEntry()

    if not entry then
        ui.detailIcon:SetTexture(nil)
        ui.detailName:SetText("|cff808080Pick something from the list.|r")
        ui.detailCost:SetText("")
        ui.detailHave:SetText("")
        ui.detailStock:SetText("")
        ui.detailMax:SetText("")
        ui.detailTotal:SetText("")
        ui.quantity:SetText("")
        ui.quantity:Disable()
        ui.maxButton:Disable()
        ui.buyButton:Disable()
        ui.buyButton:SetText("Buy")
        return
    end

    ui.detailIcon:SetTexture(entry.texture)
    ui.detailName:SetText(entry.name)

    local q = quote[entry.index]

    if not q or not q.maxBuy then
        local waiting = QuoteTimedOut(entry.index)
            and (WARN .. "This realm's server does not offer bulk buying.|r")
            or "|cff808080Asking the server...|r"

        ui.detailCost:SetText(waiting)
        ui.detailHave:SetText("")
        ui.detailStock:SetText("")
        ui.detailMax:SetText("")
        ui.detailTotal:SetText("")
        ui.quantity:Disable()
        ui.maxButton:Disable()
        ui.buyButton:Disable()
        return
    end

    local cost, have = DetailCostLines(entry, q)
    ui.detailCost:SetText("Each:  " .. (#cost > 0 and table.concat(cost, "  ") or "|cff808080free|r")
        .. (q.buyCount > 1 and ("  |cff808080(gives " .. q.buyCount .. ")|r") or ""))
    ui.detailHave:SetText("You have:  " .. (#have > 0 and table.concat(have, "  ") or "-"))

    if q.stock and q.stock >= 0 then
        ui.detailStock:SetText("Vendor stock:  " .. q.stock)
    else
        ui.detailStock:SetText("Vendor stock:  |cff808080unlimited|r")
    end

    local count = view.quantity or 1
    if count > q.maxBuy then count = q.maxBuy end
    if count < 1 then count = 1 end

    local reason = BOUND_TEXT[q.why or "none"]
    if q.maxBuy < 1 then
        ui.detailMax:SetText(WARN .. "You cannot buy any right now" .. (reason and (" -- " .. reason) or "") .. ".|r")
    elseif reason then
        ui.detailMax:SetText("Up to " .. HINT .. q.maxBuy .. "|r -- " .. reason .. ".")
    else
        ui.detailMax:SetText("Up to " .. HINT .. q.maxBuy .. "|r.")
    end

    ui.detailTotal:SetText("Total:  " .. TotalString(entry, q, count)
        .. "  |cff808080for " .. (count * q.buyCount) .. " item"
        .. ((count * q.buyCount) == 1 and "" or "s") .. "|r")

    ui.quantity:Enable()
    ui.maxButton:Enable()

    -- ⚠ buyLockedUntil outranks everything here. MERCHANT_UPDATE fires between
    -- the BVBUY going out and the BVRES coming back, and a repaint that re-enabled
    -- the button in that window would put a second spend one click away.
    if q.maxBuy < 1 or ui.buyLockedUntil then
        ui.maxButton:Disable()
        ui.buyButton:Disable()
        ui.buyButton:SetText(ui.buyLockedUntil and "Buying..." or "Buy")
    else
        ui.buyButton:Enable()
        ui.buyButton:SetText("Buy " .. count)
    end
end

Render = function()
    if not ui.frame or not ui.frame:IsShown() then return end
    ui.vendorName:SetText(UnitName("npc") or "")
    RenderList()
    RenderDetail()
end

-- ---------------------------------------------------------------------------
-- actions
-- ---------------------------------------------------------------------------

-- ⚠ EditBox:SetText FIRES OnTextChanged, including when the text is unchanged.
-- Without this guard the normalising SetText below re-enters through the very
-- handler that called it and the client hangs on the first keypress in the
-- quantity box. Found by reading, not in game: an infinite loop inside an
-- OnTextChanged does not fail politely.
local settingQuantity = false

local function SetQuantity(value)
    value = tonumber(value) or 1
    if value < 1 then value = 1 end

    local q = view.selected and quote[view.selected]
    if q and q.maxBuy and value > q.maxBuy then
        value = q.maxBuy
    end

    view.quantity = value

    if ui.quantity and not settingQuantity then
        local shown = tostring(value)
        if (ui.quantity:GetText() or "") ~= shown then
            settingQuantity = true
            ui.quantity:SetText(shown)
            settingQuantity = false
        end
    end

    RenderDetail()
end

local function Select(index)
    view.selected = index
    view.quantity = 1
    if ui.quantity then ui.quantity:SetText("1") end

    if not quote[index] or not quote[index].maxBuy then
        AskForQuote(index)
    end

    Render()
end

local function DoBuy()
    local entry = SelectedEntry()
    if not entry or not entry.itemId then return end

    local q = quote[entry.index]
    if not q or not q.maxBuy or q.maxBuy < 1 then return end

    local count = view.quantity or 1
    if count > q.maxBuy then count = q.maxBuy end
    if count < 1 then return end

    local body = string.format("Buy %s%d x %s|r?\n\nThat costs %s.\n\nYou have %s.",
        HINT, count * q.buyCount, entry.name,
        TotalString(entry, q, count),
        (function()
            local _, have = DetailCostLines(entry, q)
            return #have > 0 and table.concat(have, "  ") or "-"
        end)())

    if q.buyCount > 1 then
        body = body .. "\n\n|cff808080" .. count .. " purchase" .. (count == 1 and "" or "s")
            .. " of " .. q.buyCount .. ".|r"
    end

    ConfirmSpend(body, function()
        -- Re-checked at accept time: the popup can sit open while the player
        -- spends elsewhere, and the stale count would only be refused by the
        -- server anyway. Better to send a number that is still true.
        local live = quote[entry.index]
        local send = count
        if live and live.maxBuy and send > live.maxBuy then send = live.maxBuy end
        if send < 1 then
            Print("Nothing to buy any more.")
            return
        end

        Send("BVBUY:" .. entry.index .. ":" .. entry.itemId .. ":" .. send)

        -- Locked until the server answers, so a double-click cannot become a
        -- double spend. Released by BVRES, or by the watchdog in OnUpdate if the
        -- answer never arrives -- a permanently dead Buy button would be a worse
        -- bug than the one this is preventing.
        ui.buyButton:Disable()
        ui.buyLockedUntil = GetTime() + ANSWER_TIMEOUT
    end)
end

-- ---------------------------------------------------------------------------
-- frames
-- ---------------------------------------------------------------------------

local function BuildRow(parent, i)
    local row = CreateFrame("Button", nil, parent)
    row:SetWidth(272)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)

    row.selection = row:CreateTexture(nil, "BACKGROUND")
    row.selection:SetAllPoints()
    row.selection:SetTexture(0.61, 0.30, 0.86, 0.35)
    row.selection:Hide()

    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetWidth(28)
    row.icon:SetHeight(28)
    row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, -1)
    row.name:SetWidth(232)
    row.name:SetJustifyH("LEFT")

    row.cost = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.cost:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 6, 1)
    row.cost:SetWidth(232)
    row.cost:SetJustifyH("LEFT")

    row:SetScript("OnClick", function(self)
        if self.entry then Select(self.entry.index) end
    end)

    row:SetScript("OnEnter", function(self)
        if not self.entry then return end

        -- SetHyperlink on an empty string errors out; the link can genuinely be
        -- nil for a page that has just been invalidated under us.
        local link = GetMerchantItemLink(self.entry.index)
        if not link then return end

        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(link)
        GameTooltip:Show()
    end)

    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return row
end

local function BuildFrame()
    if ui.frame then return end

    local f = CreateFrame("Frame", "UncappedBulkBuyFrame", UIParent)
    f:SetWidth(330)
    f:SetHeight(530)
    f:SetPoint("TOPLEFT", MerchantFrame, "TOPRIGHT", -4, -60)
    f:SetFrameStrata("HIGH")
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:Hide()
    ui.frame = f

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -16)
    title:SetText("Bulk Buy")

    ui.vendorName = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ui.vendorName:SetPoint("TOP", f, "TOP", 0, -32)

    local search = CreateFrame("EditBox", "UncappedBulkBuySearch", f, "InputBoxTemplate")
    search:SetWidth(280)
    search:SetHeight(20)
    search:SetPoint("TOPLEFT", f, "TOPLEFT", 22, -52)
    search:SetAutoFocus(false)
    search:SetTextInsets(4, 4, 0, 0)
    search:SetScript("OnTextChanged", function(self)
        view.search = self:GetText() or ""
        RebuildList()
        FauxScrollFrame_SetOffset(ui.scroll, 0)
        if UncappedBulkBuyScrollScrollBar then UncappedBulkBuyScrollScrollBar:SetValue(0) end
        Render()
    end)
    search:SetScript("OnEscapePressed", function(self) self:SetText("") self:ClearFocus() end)
    ui.search = search

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", search, "LEFT", 4, 0)
    hint:SetText("Search")
    search:SetScript("OnEditFocusGained", function() hint:Hide() end)
    search:SetScript("OnEditFocusLost", function(self)
        if (self:GetText() or "") == "" then hint:Show() end
    end)

    local listHolder = CreateFrame("Frame", nil, f)
    listHolder:SetWidth(272)
    listHolder:SetHeight(ROWS * ROW_HEIGHT)
    listHolder:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -80)

    ui.rows = {}
    for i = 1, ROWS do
        ui.rows[i] = BuildRow(listHolder, i)
    end

    local scroll = CreateFrame("ScrollFrame", "UncappedBulkBuyScroll", f, "FauxScrollFrameTemplate")
    scroll:SetWidth(272)
    scroll:SetHeight(ROWS * ROW_HEIGHT)
    scroll:SetPoint("TOPLEFT", listHolder, "TOPLEFT", 0, 0)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, RenderList)
    end)
    ui.scroll = scroll

    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
    divider:SetVertexColor(0.4, 0.4, 0.4, 0.8)
    divider:SetWidth(290)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -326)

    ui.detailIcon = f:CreateTexture(nil, "ARTWORK")
    ui.detailIcon:SetWidth(36)
    ui.detailIcon:SetHeight(36)
    ui.detailIcon:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -336)

    ui.detailName = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ui.detailName:SetPoint("TOPLEFT", f, "TOPLEFT", 62, -338)
    ui.detailName:SetWidth(248)
    ui.detailName:SetJustifyH("LEFT")

    ui.detailCost = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.detailCost:SetPoint("TOPLEFT", f, "TOPLEFT", 62, -356)
    ui.detailCost:SetWidth(248)
    ui.detailCost:SetJustifyH("LEFT")

    ui.detailHave = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.detailHave:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -382)
    ui.detailHave:SetWidth(290)
    ui.detailHave:SetJustifyH("LEFT")

    ui.detailStock = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ui.detailStock:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -400)
    ui.detailStock:SetWidth(290)
    ui.detailStock:SetJustifyH("LEFT")

    local qtyLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    qtyLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -426)
    qtyLabel:SetText("Quantity")

    local qty = CreateFrame("EditBox", "UncappedBulkBuyQuantity", f, "InputBoxTemplate")
    qty:SetWidth(60)
    qty:SetHeight(20)
    qty:SetPoint("TOPLEFT", f, "TOPLEFT", 88, -422)
    qty:SetAutoFocus(false)
    qty:SetNumeric(true)
    qty:SetMaxLetters(6)
    qty:SetTextInsets(4, 4, 0, 0)
    qty:SetScript("OnTextChanged", function(self) SetQuantity(self:GetText()) end)
    qty:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    qty:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    ui.quantity = qty

    local maxButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    maxButton:SetWidth(60)
    maxButton:SetHeight(22)
    maxButton:SetPoint("TOPLEFT", f, "TOPLEFT", 158, -423)
    maxButton:SetText("Max")
    maxButton:SetScript("OnClick", function()
        local q = view.selected and quote[view.selected]
        if q and q.maxBuy then SetQuantity(q.maxBuy) end
    end)
    ui.maxButton = maxButton

    local refresh = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refresh:SetWidth(70)
    refresh:SetHeight(22)
    refresh:SetPoint("TOPLEFT", f, "TOPLEFT", 228, -423)
    refresh:SetText("Refresh")
    refresh:SetScript("OnClick", function()
        if view.selected then
            quote[view.selected] = nil
            AskForQuote(view.selected)
            Render()
        end
    end)

    ui.detailMax = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ui.detailMax:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -450)
    ui.detailMax:SetWidth(290)
    ui.detailMax:SetJustifyH("LEFT")

    ui.detailTotal = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ui.detailTotal:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -468)
    ui.detailTotal:SetWidth(290)
    ui.detailTotal:SetJustifyH("LEFT")

    local buy = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    buy:SetWidth(290)
    buy:SetHeight(26)
    buy:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -492)
    buy:SetText("Buy")
    buy:SetScript("OnClick", DoBuy)
    ui.buyButton = buy

    f:SetScript("OnShow", function()
        RebuildList()
        Render()
    end)
end

local function BuildToggle()
    if ui.toggle then return end

    local b = CreateFrame("Button", "UncappedBulkBuyToggle", MerchantFrame, "UIPanelButtonTemplate")
    b:SetWidth(90)
    b:SetHeight(22)
    -- Hanging off the right edge on purpose: every square inch inside
    -- MerchantFrame already belongs to something (money frame, repair cluster,
    -- page arrows, tabs), and an addon button that overlaps one of those is a
    -- bug report about the vendor window, not about this feature.
    b:SetPoint("TOPLEFT", MerchantFrame, "TOPRIGHT", -4, -28)
    b:SetText("Bulk Buy")
    b:SetScript("OnClick", function()
        BuildFrame()
        if ui.frame:IsShown() then
            ui.frame:Hide()
        else
            ui.frame:Show()
        end
    end)
    ui.toggle = b
end

-- ---------------------------------------------------------------------------
-- protocol
-- ---------------------------------------------------------------------------

local function OnQuoteLine(msg)
    local index, itemId, buyCount, copperEach, honorEach, arenaEach, stock, maxBuy, why, money, honor, arena =
        msg:match("^BVQ:(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%-?%d+):(%d+):(%a+):(%d+):(%d+):(%d+)$")

    if not index then return end

    index = tonumber(index)
    incoming = {
        index = index,
        itemId = tonumber(itemId),
        buyCount = tonumber(buyCount),
        copperEach = tonumber(copperEach),
        honorEach = tonumber(honorEach),
        arenaEach = tonumber(arenaEach),
        stock = tonumber(stock),
        maxBuy = tonumber(maxBuy),
        why = why,
        money = tonumber(money),
        honor = tonumber(honor),
        arena = tonumber(arena),
        costs = {},
    }
end

local function OnCostLine(msg)
    local index, _, itemId, each, have = msg:match("^BVC:(%d+):(%d+):(%d+):(%d+):(%d+)$")
    if not index or not incoming or incoming.index ~= tonumber(index) then return end

    table.insert(incoming.costs, {
        itemId = tonumber(itemId),
        each = tonumber(each),
        have = tonumber(have),
    })
end

local function OnQuoteEnd(msg)
    local index = msg:match("^BVEND:(%d+)$")
    if not index then return end

    index = tonumber(index)
    if incoming and incoming.index == index then
        quote[index] = incoming
    end

    incoming = nil
    if pending == index then pending = nil end

    -- The typed quantity was clamped against a quote that did not exist yet.
    SetQuantity(view.quantity or 1)
    Render()
end

local function OnResult(msg)
    local index, itemId, bought, items, copper, honor, arena, why =
        msg:match("^BVRES:(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%a+)$")

    if not index then return end

    index, bought, items = tonumber(index), tonumber(bought), tonumber(items)
    copper, honor, arena = tonumber(copper), tonumber(honor), tonumber(arena)

    if bought > 0 then
        local spent = {}
        if copper > 0 then table.insert(spent, GetCoinTextureString(copper)) end
        if honor > 0 then table.insert(spent, Icon(HONOR_ICON) .. honor) end
        if arena > 0 then table.insert(spent, Icon(ARENA_ICON) .. arena) end

        -- Token spend is not reported as a total on the wire (the wire carries
        -- what you HELD, per component, and the server has already said what one
        -- costs) -- so the item components are recovered from the quote we acted
        -- on rather than invented here.
        local q = quote[index]
        if q then
            for _, component in ipairs(q.costs or {}) do
                table.insert(spent, Icon(CostTexture(index, component.itemId)) .. (component.each * bought))
            end
        end

        Print(GOOD .. "Bought " .. items .. " x " .. ItemName(tonumber(itemId)) .. "|r"
            .. (#spent > 0 and ("  for " .. table.concat(spent, "  ")) or ""))
    else
        local reason = BOUND_TEXT[why] or ERROR_TEXT[why]
        Print("Bought nothing" .. (reason and (" -- " .. reason) or "") .. ".")
    end

    ui.buyLockedUntil = nil

    -- The quote is now stale by definition: balances, stock and bag space all
    -- moved. Throw it away and ask again rather than letting the panel keep
    -- offering the number it offered before the spend.
    quote[index] = nil
    if view.selected == index then
        view.quantity = 1
        if ui.quantity then ui.quantity:SetText("1") end
        ui.pendingRequote = GetTime() + 2.2      -- clear of the server's buy cooldown
    end

    RebuildList()
    Render()
end

local function OnError(msg)
    local why = msg:match("^BVERR:(%a+)$")
    if not why then return end

    if why == "busy" then
        -- Not worth a chat line: the panel simply asks again shortly. The buy
        -- lock is released because a throttled request never reached a purchase
        -- -- nothing was spent, so the button must not stay dead.
        ui.buyLockedUntil = nil
        if view.selected then ui.pendingRequote = GetTime() + 1.5 end
        Render()
        return
    end

    incoming = nil
    pending = nil
    ui.buyLockedUntil = nil

    if view.selected then quote[view.selected] = nil end

    Print(WARN .. (ERROR_TEXT[why] or ("Refused: " .. why)) .. "|r")
    Render()
end

-- ---------------------------------------------------------------------------
-- events
-- ---------------------------------------------------------------------------

local driver = CreateFrame("Frame", "UncappedBulkBuyDriver")
driver:RegisterEvent("ADDON_LOADED")
driver:RegisterEvent("MERCHANT_SHOW")
driver:RegisterEvent("MERCHANT_CLOSED")
driver:RegisterEvent("MERCHANT_UPDATE")
driver:RegisterEvent("CHAT_MSG_ADDON")

driver:SetScript("OnEvent", function(self, event, a1, a2, a3, a4)
    if event == "ADDON_LOADED" then
        if a1 ~= ADDON then return end
        UncappedBulkBuyDB = UncappedBulkBuyDB or {}
        BuildToggle()
        return
    end

    if event == "CHAT_MSG_ADDON" then
        --  ★ Sender check, the client half ADDON_PROTOCOL.md 2.1 records as owed.
        --  Everything under this prefix is server -> client and arrives as a
        --  whisper to yourself; anything else claiming to be it is another player
        --  writing our protocol at us.
        if a1 ~= PIPE or not a2 then return end
        if a3 ~= "WHISPER" or a4 ~= UnitName("player") then return end
        if a2:sub(1, 2) ~= "BV" then return end

        if a2:sub(1, 4) == "BVQ:" then
            OnQuoteLine(a2)
        elseif a2:sub(1, 4) == "BVC:" then
            OnCostLine(a2)
        elseif a2:sub(1, 6) == "BVEND:" then
            OnQuoteEnd(a2)
        elseif a2:sub(1, 6) == "BVRES:" then
            OnResult(a2)
        elseif a2:sub(1, 6) == "BVERR:" then
            OnError(a2)
        end
        return
    end

    if event == "MERCHANT_SHOW" then
        BuildToggle()
        InvalidateQuotes()
        view.selected = nil
        view.quantity = 1
        if ui.toggle then ui.toggle:Show() end
        if ui.frame and ui.frame:IsShown() then
            RebuildList()
            Render()
        end
        return
    end

    if event == "MERCHANT_UPDATE" then
        -- Stock and affordability both move under us on every update, and a
        -- quote is a statement about both. Keep the selection, drop the numbers.
        quote = {}
        incoming = nil
        pending = nil
        if ui.frame and ui.frame:IsShown() then
            RebuildList()
            if view.selected then AskForQuote(view.selected) end
            Render()
        end
        return
    end

    if event == "MERCHANT_CLOSED" then
        InvalidateQuotes()
        view.selected = nil
        if ui.frame then ui.frame:Hide() end
        if ui.toggle then ui.toggle:Hide() end
        StaticPopup_Hide("UNCAPPED_BULKBUY_CONFIRM")
        return
    end
end)

-- One timer, on the driver rather than on the panel, so a deferred re-quote
-- still fires while the window is closed and the answer is waiting when it
-- reopens. Throttled to 5/sec; there is nothing here that needs a frame.
local elapsedSince = 0
driver:SetScript("OnUpdate", function(self, elapsed)
    elapsedSince = elapsedSince + elapsed
    if elapsedSince < 0.2 then return end
    elapsedSince = 0

    if ui.pendingRequote and GetTime() >= ui.pendingRequote then
        ui.pendingRequote = nil
        if view.selected and MerchantFrame and MerchantFrame:IsShown() then
            AskForQuote(view.selected)
        end
    end

    if ui.buyLockedUntil and GetTime() >= ui.buyLockedUntil then
        ui.buyLockedUntil = nil
        Render()
    end

    -- Repaint only while something is actually outstanding, so the timeout
    -- message can appear without the panel repainting every tick forever.
    if pending and ui.frame and ui.frame:IsShown() and QuoteTimedOut(pending) then
        pending = nil
        Render()
    end
end)

SLASH_UNCAPPEDBULKBUY1 = "/bulkbuy"
SlashCmdList["UNCAPPEDBULKBUY"] = function()
    if not MerchantFrame or not MerchantFrame:IsShown() then
        Print("Open a vendor first.")
        return
    end

    BuildFrame()
    if ui.frame:IsShown() then
        ui.frame:Hide()
    else
        ui.frame:Show()
    end
end
