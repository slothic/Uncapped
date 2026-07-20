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
        or msg:find("^RBQUOTE:") or msg:find("^RBBOUGHT:") or msg:find("^RBBUYFAIL:") then
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
ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", ReagentBankChatFilter)

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
