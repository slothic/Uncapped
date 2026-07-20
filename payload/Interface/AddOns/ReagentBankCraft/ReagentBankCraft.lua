-- ReagentBankCraft
--
-- Talks to the server via the player's own personal channel (auto-joined
-- at login, built earlier this session for loot notifications) instead of
-- fighting the client's compiled-in local reagent check on the TradeSkill
-- window. Flow:
--   1. Click "Withdraw Bank Mats" -> sends RBWITHDRAWALL:<spellId>
--   2. Server withdraws everything in the reagent bank for that recipe's
--      reagents into your real bags, replies RBWITHDRAWN:<spellId>
--   3. Addon catches that reply and refreshes the recipe display, so the
--      REAL "Create"/"Create All" buttons naturally become enabled, since
--      the reagents are genuinely, physically in your bags now
--   4. Craft normally with the real buttons -- no further addon
--      involvement needed for the craft itself
--   5. Closing the TradeSkill window sends RBREDEPOSITALL:<spellId> ->
--      server redeposits whatever's left of what IT withdrew (never more
--      than that, so materials you had beforehand or gathered separately
--      are never touched)
--
-- Also adds "Buy Missing Mats": asks how many crafts you want, prices the
-- shortfall server-side, shows the cost, and on confirmation buys only the
-- reagents actually sold by a vendor somewhere (Fine Thread, Empty Vial and
-- the like). Gathered materials cannot be bought and are reported instead.
-- Bought mats go to bags, overflowing to the reagent bank if bags are full.
--
-- The RBWITHDRAWN:/RBREDEPOSITED:/RBQUOTE:/RBBOUGHT: replies travel over the
-- same channel used for loot notifications, so they're filtered out of chat
-- display entirely (see the ChatFrame_AddMessageEventFilter call below) --
-- purely a data channel, nothing for the player to see.

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("CHAT_MSG_CHANNEL")

local myChannelName = nil
local lastWithdrawnSpellId = nil

-- TradeSkillFrame.selectedSkill is a LIST INDEX (position in the current
-- recipe list), not a spell ID -- confirmed from the real client source
-- (GetTradeSkillInfo/SelectTradeSkill both take this same index). The
-- actual recipe spell ID comes specifically from GetTradeSkillRecipeLink,
-- NOT GetTradeSkillItemLink (which returns the *produced item's* link
-- instead).
function ReagentBankCraft_GetSelectedRecipeSpellId()
    if not TradeSkillFrame or not TradeSkillFrame.selectedSkill then
        return nil
    end
    local link = GetTradeSkillRecipeLink(TradeSkillFrame.selectedSkill)
    if not link then
        return nil
    end
    local id = link:match("enchant:(%d+)")
    return id and tonumber(id) or nil
end

function ReagentBankCraft_Send(command)
    SendAddonMessage("REAGENTBANK", command, "WHISPER", UnitName("player"))
end

-- Hides our protocol replies (RBWITHDRAWN:/RBREDEPOSITED:/RBMAX:) from
-- ever displaying in any chat window, while still letting the
-- CHAT_MSG_CHANNEL event fire normally so our own handler below still
-- receives and processes it.
local function ReagentBankChatFilter(self, event, msg, ...)
    if msg:find("^RBWITHDRAWN:") or msg:find("^RBREDEPOSITED:") or msg:find("^RBMAX:")
        or msg:find("^RBQUOTE:") or msg:find("^RBBOUGHT:") or msg:find("^RBBUYFAIL:")
        or msg:find("^RBSRC:") or msg:find("^RBSRCEND:")
        or msg:find("^RBWL:") or msg:find("^RBWLM:") or msg:find("^RBWLEND:") then
        return true
    end
    return false
end

-- Formats a copper amount the way the game does: 12g 34s 56c
local function FormatMoney(copper)
    copper = tonumber(copper) or 0
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    if g > 0 then
        return string.format("%dg %ds %dc", g, s, c)
    elseif s > 0 then
        return string.format("%ds %dc", s, c)
    end
    return string.format("%dc", c)
end

-- Asks how many crafts to buy for. Confirming requests a quote rather than
-- buying outright, so the player sees the price before any gold is spent.
StaticPopupDialogs["REAGENTBANK_BUY_COUNT"] = {
    text = "How many times do you want to craft this?",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = 1,
    maxLetters = 5,
    OnShow = function(self)
        local box = self.editBox or getglobal(self:GetName() .. "EditBox")
        if box then
            box:SetText("1")
            box:HighlightText()
            box:SetFocus()
        end
    end,
    OnAccept = function(self)
        local box = self.editBox or getglobal(self:GetName() .. "EditBox")
        local count = tonumber(box and box:GetText() or "")
        if not count or count < 1 then
            return
        end
        local spellId = ReagentBankCraft_GetSelectedRecipeSpellId()
        if spellId then
            ReagentBankCraft_PendingBuy = { spellId = spellId, count = count }
            ReagentBankCraft_Send("RBBUYQUOTE:" .. spellId .. ":" .. count)
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        StaticPopupDialogs["REAGENTBANK_BUY_COUNT"].OnAccept(parent)
        parent:Hide()
    end,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

-- Shown once the server has priced the shortfall. Only this one spends gold.
StaticPopupDialogs["REAGENTBANK_BUY_CONFIRM"] = {
    text = "%s",
    button1 = ACCEPT,
    button2 = CANCEL,
    OnAccept = function()
        local pending = ReagentBankCraft_PendingBuy
        if pending then
            ReagentBankCraft_Send("RBBUY:" .. pending.spellId .. ":" .. pending.count)
            ReagentBankCraft_PendingBuy = nil
        end
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

-- The wishlist tracks the ITEM a recipe produces, not the recipe spell, so this
-- deliberately uses GetTradeSkillItemLink -- GetTradeSkillRecipeLink would give
-- the enchant/spell link instead, which is the wrong id entirely.
function ReagentBankCraft_GetSelectedProducedItem()
    if not TradeSkillFrame or not TradeSkillFrame.selectedSkill then
        return nil, nil
    end
    local link = GetTradeSkillItemLink(TradeSkillFrame.selectedSkill)
    if not link then
        return nil, nil
    end
    local id = link:match("item:(%d+)")
    local name = link:match("%[(.-)%]")
    return id and tonumber(id) or nil, name
end

-- Asks how many of the item you want before tracking it.
StaticPopupDialogs["REAGENTBANK_TRACK_COUNT"] = {
    text = "How many do you want to make?",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = 1,
    maxLetters = 5,
    OnShow = function(self)
        local box = self.editBox or getglobal(self:GetName() .. "EditBox")
        if box then
            box:SetText("1")
            box:HighlightText()
            box:SetFocus()
        end
    end,
    OnAccept = function(self)
        local box = self.editBox or getglobal(self:GetName() .. "EditBox")
        local count = tonumber(box and box:GetText() or "")
        if not count or count < 1 then
            return
        end
        local itemId = ReagentBankCraft_GetSelectedProducedItem()
        if itemId then
            ReagentBankWishlist_Track(itemId, count)
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        StaticPopupDialogs["REAGENTBANK_TRACK_COUNT"].OnAccept(parent)
        parent:Hide()
    end,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", ReagentBankChatFilter)


-- ---------------------------------------------------------------------------
-- "Where do I farm this?" panel.
--
-- Sources arrive one line at a time (RBSRC) followed by a terminator
-- (RBSRCEND), so lines accumulate into ReagentBankCraft_SourceBuffer and the
-- window only redraws once the terminator lands. Redrawing per line would
-- flicker and, worse, show a half-populated list as if it were complete.
local SOURCE_KIND = { [1] = "Drops from", [2] = "Gathered from", [3] = "Fished in", [4] = "Skinned from" }

ReagentBankCraft_SourceBuffer = {}

local sourceFrame = CreateFrame("Frame", "ReagentBankSourceFrame", UIParent)
sourceFrame:SetSize(360, 220)
sourceFrame:SetPoint("CENTER", UIParent, "CENTER", 260, 0)
sourceFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
sourceFrame:SetMovable(true)
sourceFrame:EnableMouse(true)
sourceFrame:RegisterForDrag("LeftButton")
sourceFrame:SetScript("OnDragStart", sourceFrame.StartMoving)
sourceFrame:SetScript("OnDragStop", sourceFrame.StopMovingOrSizing)
sourceFrame:Hide()

sourceFrame.title = sourceFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
sourceFrame.title:SetPoint("TOPLEFT", 20, -18)
sourceFrame.title:SetText("Where to farm")

sourceFrame.close = CreateFrame("Button", nil, sourceFrame, "UIPanelCloseButton")
sourceFrame.close:SetPoint("TOPRIGHT", -8, -8)

sourceFrame.lines = {}
for i = 1, 8 do
    local fs = sourceFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", 22, -38 - (i - 1) * 20)
    fs:SetWidth(310)
    fs:SetJustifyH("LEFT")
    sourceFrame.lines[i] = fs
end

function ReagentBankCraft_ShowSources(itemName)
    local buf = ReagentBankCraft_SourceBuffer
    sourceFrame.title:SetText("Where to farm: " .. (itemName or "item"))

    for i = 1, 8 do sourceFrame.lines[i]:SetText("") end

    if #buf == 0 then
        sourceFrame.lines[1]:SetText("|cffff8800No known source -- it may come from a quest, a nested loot table, or crafting.|r")
    else
        for i, src in ipairs(buf) do
            if i > 8 then break end
            -- Chance arrives in tenths of a percent; 0 means genuinely unknown
            -- (an equal-chance loot group), so show "?" rather than "0%".
            local chanceText = (src.chance > 0) and string.format("%.1f%%", src.chance / 10) or "?"
            local where = (src.zone ~= "" and src.zone) or "unknown area"
            local spawns = (src.spawns > 0) and (" (" .. src.spawns .. " spawns)") or ""
            sourceFrame.lines[i]:SetText(string.format("|cffffd100%s|r %s - |cff00ff00%s|r in %s%s",
                SOURCE_KIND[src.kind] or "From", src.name, chanceText, where, spawns))
        end
    end

    sourceFrame:Show()
end

function ReagentBankCraft_QuerySources(itemId, itemName)
    ReagentBankCraft_SourceBuffer = {}
    ReagentBankCraft_PendingSourceName = itemName
    ReagentBankCraft_Send("RBSOURCE:" .. itemId)
end

local function OnEvent(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName ~= "Blizzard_TradeSkillUI" then
            return
        end

        myChannelName = UnitName("player")
        JoinChannelByName(myChannelName)

        if not TradeSkillCreateButton then
            return
        end

        local withdrawButton = CreateFrame("Button", "ReagentBankWithdrawButton", TradeSkillCreateButton, "UIPanelButtonTemplate")
        withdrawButton:SetSize(150, 22)
        withdrawButton:SetPoint("TOP", TradeSkillCreateButton, "BOTTOM", 0, -4)
        withdrawButton:SetText("Withdraw Bank Mats")

        withdrawButton:SetScript("OnClick", function()
            local spellId = ReagentBankCraft_GetSelectedRecipeSpellId()
            if spellId then
                lastWithdrawnSpellId = spellId
                ReagentBankCraft_Send("RBWITHDRAWALL:" .. spellId)
            end
        end)

        withdrawButton:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetText("Withdraw reagent bank materials")
            GameTooltip:AddLine("Pulls everything currently in your reagent bank for this recipe's reagents into your bags, so the normal Create button will work. Leftovers are automatically redeposited when you close this window.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        withdrawButton:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        local buyButton = CreateFrame("Button", "ReagentBankBuyButton", TradeSkillCreateButton, "UIPanelButtonTemplate")
        buyButton:SetSize(150, 22)
        buyButton:SetPoint("TOP", withdrawButton, "BOTTOM", 0, -3)
        buyButton:SetText("Buy Missing Mats")

        buyButton:SetScript("OnClick", function()
            if not ReagentBankCraft_GetSelectedRecipeSpellId() then
                return
            end
            StaticPopup_Show("REAGENTBANK_BUY_COUNT")
        end)

        buyButton:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetText("Buy missing reagents")
            GameTooltip:AddLine("Asks how many times you want to craft this, then buys whatever you are short of. Only reagents actually sold by a vendor somewhere can be bought -- gathered materials cannot. You are shown the price before anything is spent.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        buyButton:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        local trackButton = CreateFrame("Button", "ReagentBankTrackButton", TradeSkillCreateButton, "UIPanelButtonTemplate")
        trackButton:SetSize(150, 22)
        trackButton:SetPoint("TOP", buyButton, "BOTTOM", 0, -3)
        trackButton:SetText("Track")

        trackButton:SetScript("OnClick", function()
            if ReagentBankCraft_GetSelectedRecipeSpellId() then
                StaticPopup_Show("REAGENTBANK_TRACK_COUNT")
            end
        end)

        trackButton:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetText("Track this recipe")
            GameTooltip:AddLine("Adds it to your wishlist for a chosen quantity. The wishlist window shows every material you still need, counting bags, bank and reagent bank, and updates itself as you farm. Open it any time with /wishlist.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        trackButton:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        -- Click any reagent in the recipe to ask where it comes from.
        -- The reagent buttons are Blizzard's own (TradeSkillReagent1..8) and
        -- already exist by the time Blizzard_TradeSkillUI has loaded, so they
        -- can be hooked directly rather than recreated.
        for i = 1, 8 do
            local reagentButton = getglobal("TradeSkillReagent" .. i)
            if reagentButton then
                reagentButton:HookScript("OnClick", function()
                    local skillIndex = TradeSkillFrame and TradeSkillFrame.selectedSkill
                    if not skillIndex then
                        return
                    end

                    local link = GetTradeSkillReagentItemLink(skillIndex, i)
                    if not link then
                        return
                    end

                    local itemId = link:match("item:(%d+)")
                    local itemName = link:match("%[(.-)%]")
                    if itemId then
                        ReagentBankCraft_QuerySources(tonumber(itemId), itemName)
                    end
                end)
            end
        end

        -- Auto-redeposit leftovers when the window closes, regardless of
        -- how it was closed (Exit button, Escape, clicking away, etc --
        -- OnHide fires for all of these).
        TradeSkillFrame:HookScript("OnHide", function()
            if lastWithdrawnSpellId then
                ReagentBankCraft_Send("RBREDEPOSITALL:" .. lastWithdrawnSpellId)
                lastWithdrawnSpellId = nil
            end
        end)

    elseif event == "CHAT_MSG_CHANNEL" then
        local text, sender = ...
        if sender ~= UnitName("player") then
            return
        end

        -- Wishlist traffic lives in Wishlist.lua; hand it straight over.
        if ReagentBankWishlist_OnMessage and ReagentBankWishlist_OnMessage(text) then
            return
        end

        -- RBSRC:<itemId>:<kind>:<chanceTenths>:<spawns>:<name>|<zone>
        if text:find("^RBSRC:") then
            local kind, chance, spawns, rest = text:match("^RBSRC:%d+:(%d+):(%d+):(%d+):(.*)$")
            if rest then
                local name, zone = rest:match("^(.-)|(.*)$")
                table.insert(ReagentBankCraft_SourceBuffer, {
                    kind = tonumber(kind) or 1,
                    chance = tonumber(chance) or 0,
                    spawns = tonumber(spawns) or 0,
                    name = name or rest,
                    zone = zone or "",
                })
            end
            return
        end

        if text:find("^RBSRCEND:") then
            ReagentBankCraft_ShowSources(ReagentBankCraft_PendingSourceName)
            return
        end

        -- RBQUOTE:<spellId>:<copper>:<kindsToBuy>:<kindsUnbuyable>
        if text:find("^RBQUOTE:") then
            local _, cost, kinds, unbuyable = text:match("^RBQUOTE:(%d+):(%d+):(%d+):(%d+)$")
            cost, kinds, unbuyable = tonumber(cost) or 0, tonumber(kinds) or 0, tonumber(unbuyable) or 0

            if kinds == 0 then
                if unbuyable > 0 then
                    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Reagent Bank]|r Nothing can be bought -- "
                        .. unbuyable .. " missing reagent type(s) are not sold by any vendor.")
                else
                    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Reagent Bank]|r You already have everything for that.")
                end
                ReagentBankCraft_PendingBuy = nil
                return
            end

            local msg = "Buy " .. kinds .. " missing reagent type(s) for " .. FormatMoney(cost) .. "?"
            if unbuyable > 0 then
                msg = msg .. "\n\n|cffff8800" .. unbuyable
                    .. " other reagent type(s) are missing but are not sold by vendors.|r"
            end
            StaticPopup_Show("REAGENTBANK_BUY_CONFIRM", msg)
            return
        end

        -- RBBOUGHT:<spellId>:<copper>:<kindsDelivered>:<kindsUnbuyable>
        if text:find("^RBBOUGHT:") then
            local _, cost, delivered = text:match("^RBBOUGHT:(%d+):(%d+):(%d+):(%d+)$")
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Reagent Bank]|r Bought "
                .. (tonumber(delivered) or 0) .. " reagent type(s) for " .. FormatMoney(cost) .. ".")
            -- Refresh so the real Create button re-evaluates with the new mats.
            if TradeSkillFrame and TradeSkillFrame.selectedSkill and TradeSkillFrame_SetSelection then
                TradeSkillFrame_SetSelection(TradeSkillFrame.selectedSkill)
            end
            return
        end

        if text:find("^RBBUYFAIL:") then
            local reason = text:match("^RBBUYFAIL:%d+:(%a+)$")
            if reason == "money" then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Reagent Bank]|r You cannot afford those reagents.")
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Reagent Bank]|r Nothing to buy for that recipe.")
            end
            ReagentBankCraft_PendingBuy = nil
            return
        end

        if text:find("^RBWITHDRAWN:") then
            -- Refresh the reagent/button display now that items have
            -- actually arrived, so the real Create button re-evaluates
            -- and becomes enabled on its own.
            if TradeSkillFrame and TradeSkillFrame.selectedSkill and TradeSkillFrame_SetSelection then
                TradeSkillFrame_SetSelection(TradeSkillFrame.selectedSkill)
            end
        end
    end
end

frame:SetScript("OnEvent", OnEvent)
