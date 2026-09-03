-- UncappedScrolls
--
-- A status window for every customization-scroll bonus on the account.
--
-- The scrolls are consumables: they are destroyed on use and leave behind no
-- item, no aura and no tooltip. The only feedback a player ever got was the chat
-- line printed at the moment of clicking, so after a relog there was no way to
-- answer "how much gather range do I actually have?" or "which instances did my
-- Fortune scrolls land on?". This window is that answer.
--
-- Everything shown is server-authoritative -- the client stores nothing but the
-- window position. Open it, the addon asks (SCRGET), the server bursts the
-- current values back and the window renders them.
--
--   /scrolls        open it (switches the Dashboard to the Soul Scrolls tab)
--   /scrolls sync   force a refresh
--
-- Wire format is documented server-side in mod-scroll-bonuses/src/scroll_status_comms.cpp.
--
-- Lives inside the Dashboard's content panel (see EmbedInto below) -- no own
-- backdrop/title/close/drag, since the Dashboard's master window already
-- provides all of that chrome. Internal layout stays the fixed-pixel size the
-- standalone window used (it's a plain text listing, nothing to reflow), with
-- GetMinWidth/GetMinHeight telling the Dashboard how much room that needs.

local ADDON_PIPE_PREFIX = "UNC"          -- server -> client (replies arrive here)
local TRANSPORT_PREFIX  = "REAGENTBANK"  -- client -> server (shared addon transport)

-- ---------------------------------------------------------------------------
-- State. Rebuilt wholesale on every burst -- there is no incremental update, so
-- a dropped line can never leave a stale row behind.
-- ---------------------------------------------------------------------------
local state = {
    gatherRange = 0,
    yieldTenths = 0,   -- tenths of a percent -- see the Bounty row in Render()
    delver      = 0,
    petDelver   = nil,  -- hunters only; nil means the server sent no pet line
    petMult     = 2,
    questCount  = 0,
    questMult   = 1,
    contagion   = 0,    -- [#882] per CHARACTER, unlike everything above it
    contagionMax = 10,
    -- [#902] extra targets granted by the CLASS, on top of contagion. Priests only;
    -- the server omits the line entirely for everyone else, so 0 is the correct
    -- default and not a "no data" sentinel.
    contagionInnate = 0,
    professions = {},   -- { name, cur, max }
    fortune     = {},   -- { mapName, bonus }
    fortuneAll  = 0,    -- total server-side, may exceed #fortune (list is capped)
    -- [#986] nil until a SCRCONV line arrives. nil is "this server does not have the
    -- feature", NOT "off" -- the control stays hidden rather than offering a toggle
    -- the server has no handler for.
    autoScroll  = nil,
    received    = false,
}

local pending = nil     -- burst being assembled; swapped into `state` at SCREND

local COLOR_HEAD  = "|cff33ff99"   -- section headings (matches the scroll chat colour)
local COLOR_LABEL = "|cffffffff"
local COLOR_VALUE = "|cffffff00"
local COLOR_DIM   = "|cff888888"

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------
local WIDTH, HEIGHT = 360, 454
local ROW_H         = 14
local FORTUNE_ROWS  = 8

local frame, fortuneScroll
local lines = {}
local fortuneRows = {}

-- ⚠ FORWARD DECLARATION, and it is load-bearing. Render (below) builds a checkbox
--   whose OnClick calls Request(), but Request is defined ~180 lines further down;
--   without this line that call compiled as a read of the nil GLOBAL `Request` and
--   the checkbox errored instead of refreshing. See the note at the definition.
local Request

--[[ ==========================================================================
     [#1092] MASS-CONSUME -- "Use all", and why it is a SERVER VERB.

     ★★ IT CANNOT BE A LUA LOOP. UseContainerItem is a PROTECTED function: the
        3.3.5a client refuses it unless the call is inside the same execution
        frame as a real hardware event, and one keypress buys exactly one call.
        An addon cannot iterate 200 scrolls out of a bag no matter how it is
        written -- "Interface action failed because of an AddOn" is the whole of
        what a loop achieves. So the client's only honest job here is to name the
        item and ask; the consuming has to happen server-side, in one message.

     ⚠ BULK-SAFE ENTRIES ONLY, AND THE LIST IS NOT A CONVENIENCE.
        Three of the ten scrolls open a CLIENT PICKER when used and consume
        nothing at the moment of use -- Transmog (500201), Extraction (500208)
        and Socket (500209). Firing 200 of those server-side either does nothing
        200 times or destroys 200 scrolls for one picker, and neither is a thing
        a player asked for. They are absent from this table on purpose; do not
        add one because it "looks like the others".

     The names here are a FALLBACK for an uncached item. GetItemInfo is asked
     first (see bulkName) so a renamed scroll reads correctly without an addon
     patch.
     ========================================================================== ]]
local BULK_H = 22
local BULK_SCROLLS = {
    { entry = 500202, name = "Scroll of Honor" },
    { entry = 500203, name = "Scroll of Reach" },
    { entry = 500204, name = "Scroll of Bounty" },
    { entry = 500205, name = "Scroll of Mastery" },
    { entry = 500206, name = "Scroll of Fortune" },
    { entry = 500207, name = "Scroll of the Delver" },
    { entry = 500211, name = "Scroll of Contagion" },
}
local bulkRows = {}

-- GetItemInfo first, the table's own label second. The table is only a fallback for
-- an item the client has not cached yet -- which is normal for a scroll that went
-- straight from a loot table into the Vault and never passed through a bag.
local function bulkName(entry)
    local live = GetItemInfo(entry)
    if live and live ~= "" then return live end
    for _, s in ipairs(BULK_SCROLLS) do
        if s.entry == entry then return s.name end
    end
    return "item " .. tostring(entry)
end

-- Only the types actually in the bags, in the table's order. Everything visible
-- in this section is a client-side GetItemCount -- unlike the rest of the window,
-- which is server-authoritative -- because these scrolls are still loose items and
-- the server keeps no balance for them.
local function bulkHeld()
    local out = {}
    for _, s in ipairs(BULK_SCROLLS) do
        local n = GetItemCount(s.entry) or 0
        if n > 0 then
            out[#out + 1] = { entry = s.entry, name = bulkName(s.entry), count = n }
        end
    end
    return out
end

local function hideBulkRows()
    for _, row in ipairs(bulkRows) do
        row.label:Hide()
        row.btn.entry = nil
        row.btn:Hide()
    end
end

--[[ ⚠ A CONFIRMATION, BECAUSE THIS DESTROYS ITEMS.

     Every scroll in the stack is spent in one server call and there is no undo.
     The count and the item name are both in the sentence -- a bare "Are you
     sure?" over a stack of 300 Scrolls of Fortune is not consent to anything.

     3.3.5a hands the payload through differently depending on how the dialog was
     raised, so `data` is read from either place -- same shape as the Soulforge
     dialogs. ]]
StaticPopupDialogs["UNCAPPED_SCROLLS_USE_ALL"] = {
    text = "Use all |cffffffff%d|r %s?\n\nThey are consumed immediately and cannot be recovered.",
    button1 = ACCEPT,
    button2 = CANCEL,
    OnAccept = function(self, data)
        local d = data or (self and self.data)
        if not d or not d.entry then return end
        -- Same call shape as the ICSC toggle below: the shared client -> server
        -- transport, whispered to yourself.
        SendAddonMessage(TRANSPORT_PREFIX, "SCRALL:" .. d.entry, "WHISPER", UnitName("player"))
    end,
    timeout = 0, whileDead = 1, hideOnEscape = 1, showAlert = 1,
}

-- Body lines: a fixed column of font strings, filled top-down by Render(). Using
-- a fixed pool rather than creating strings per refresh keeps the window from
-- leaking frames every time it is opened.
local function AcquireLine(index, yOffset)
    local fs = lines[index]
    if not fs then
        fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetJustifyH("LEFT")
        fs:SetWidth(WIDTH - 50)
        lines[index] = fs
    end
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, yOffset)
    fs:Show()
    return fs
end

local function RefreshFortuneRows()
    local offset = FauxScrollFrame_GetOffset(fortuneScroll) or 0
    for i = 1, FORTUNE_ROWS do
        local entry = state.fortune[i + offset]
        local fs = fortuneRows[i]
        if entry then
            fs:SetText(string.format("%s%s  %s+%.2f%%|r", COLOR_LABEL, entry.name, COLOR_VALUE, entry.bonus))
            fs:Show()
        else
            fs:Hide()
        end
    end
    FauxScrollFrame_Update(fortuneScroll, #state.fortune, FORTUNE_ROWS, ROW_H)
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------
local function Render()
    if not frame then return end
    local i, y = 1, -14

    local function Head(text)
        local fs = AcquireLine(i, y)
        fs:SetText(COLOR_HEAD .. text .. "|r")
        i, y = i + 1, y - (ROW_H + 4)
    end

    local function Row(label, value)
        local fs = AcquireLine(i, y)
        fs:SetText(string.format("%s%s|r  %s%s|r", COLOR_LABEL, label, COLOR_VALUE, value))
        i, y = i + 1, y - ROW_H
    end

    local function Note(text)
        local fs = AcquireLine(i, y)
        fs:SetText(COLOR_DIM .. text .. "|r")
        i, y = i + 1, y - ROW_H
    end

    if not state.received then
        Head("Account-wide")
        Note("Waiting for the server...")
        for n = i, #lines do lines[n]:Hide() end
        fortuneScroll:Hide()
        for n = 1, FORTUNE_ROWS do fortuneRows[n]:Hide() end
        -- [#1092] These are a separate pool from `lines`, so the loop above does
        -- not reach them -- they have to be put away by hand or they hang over the
        -- "Waiting for the server..." placeholder.
        hideBulkRows()
        return
    end

    Head("Account-wide")
    Row("Scroll of Reach",  string.format("+%.0f yd gather / auto-loot range", state.gatherRange))
    -- ⚠ yieldTenths is TENTHS of a percent (#899): 250 means +25.0%. One decimal,
    --   because the per-scroll grant is 2.5% and rounding to whole percent would
    --   render the first four scrolls as "+2%", "+5%", "+7%", "+10%".
    Row("Scroll of Bounty", string.format("+%.1f%% gathering yield", state.yieldTenths / 10))
    -- Delver moved up here from "This character" -- it is account-wide now.
    Row("Scroll of the Delver", string.format("+%d dungeon stat roll", state.delver))
    if state.petDelver then
        Row("  ...on your pet", string.format("+%d  %s(%.1fx, hunters only)|r",
            state.petDelver, COLOR_DIM, state.petMult))
    end

    y = y - 6
    Head("This character")

    -- Quest bonus moved down here from "Account-wide" (2026-08-14). It used to
    -- pool every character on the account into one count, which paid an alt again
    -- for quests the main had already done; it now counts only this character's
    -- own completed quests, so it belongs under this heading.
    Row("Quest bonus",      string.format("x%.1f Anima  %s(%d quests)|r",
        state.questMult, COLOR_DIM, state.questCount))

    -- [#882] Contagion sits under "This character" because it is the one scroll
    -- spent per character rather than per account. Shown at zero on purpose --
    -- two players reported this window precisely because they could not tell
    -- whether they had any.
    --
    -- [#902] Priests carry a class grant on top of any scrolls, so the two halves get
    -- named separately on their own line. A priest shown one combined number would
    -- read their scrolls as having done nothing -- which is the same invisibility bug
    -- #882 was reported for, one level up.
    local innate = state.contagionInnate or 0
    local reach  = state.contagion + innate
    if reach > 0 then
        Row("Scroll of Contagion", string.format("+%d nearby %s hit by your DoTs",
            reach, reach == 1 and "enemy" or "enemies"))
        if innate > 0 then
            -- "your own spells" is load-bearing: the grant is gated on the priest spell
            -- family server-side, so a trinket proc or a bomb still spreads by scrolls
            -- alone. Saying only "+3 innate" would promise more than it pays.
            Note(string.format("   %d innate on your own spells + %d of %d scrolls applied",
                innate, state.contagion, state.contagionMax))
        else
            Note(string.format("   %d of %d scrolls applied", state.contagion, state.contagionMax))
        end
    else
        Row("Scroll of Contagion", string.format("%snone applied  (0 of %d)|r",
            COLOR_DIM, state.contagionMax))
    end

    if #state.professions > 0 then
        for n = 1, #state.professions do
            local p = state.professions[n]
            Row(p.name, string.format("%d / %d", p.cur, p.max))
        end
    else
        Note("No professions learned.")
    end

    -- [#986] Directly under the professions, because that is what a Scroll of Mastery
    -- raises and this toggle is about what happens when there is none left to raise.
    -- Hidden entirely when the server never sent SCRCONV.
    if state.autoScroll ~= nil then
        if not frame.convCheck then
            local cb = CreateFrame("CheckButton", "UncappedScrollsConv", frame,
                                   "InterfaceOptionsCheckButtonTemplate")
            _G[cb:GetName() .. "Text"]:SetText("Convert unusable Mastery scrolls \226\134\146 Delver")
            cb:SetScript("OnClick", function(self)
                local want = self:GetChecked() and 1 or 0
                -- Snap back to the server's value; the SCRCONV in the reply burst is
                -- the authority, exactly as the Soulforge checkboxes behave.
                self:SetChecked(state.autoScroll and true or false)
                SendAddonMessage(TRANSPORT_PREFIX, "ICSC:" .. want, "WHISPER", UnitName("player"))
                Request()
            end)
            cb:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine("Scroll auto-convert", 1, 1, 1)
                GameTooltip:AddLine("A Scroll of Mastery only raises a profession you have not "
                    .. "maxed. Once they are all maxed it does nothing and stays in your bags.",
                    0.8, 0.8, 0.8, true)
                GameTooltip:AddLine("With this on, using one of those turns it into a Scroll of "
                    .. "the Delver instead.", 0.6, 1, 0.6, true)
                GameTooltip:AddLine("It is never converted while it still has a profession it "
                    .. "could raise.", 0.6, 0.6, 0.7, true)
                GameTooltip:Show()
            end)
            cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
            frame.convCheck = cb
        end

        -- Positioned from the running y like every other row, so it cannot collide with
        -- whatever the profession list happened to be this refresh.
        frame.convCheck:ClearAllPoints()
        frame.convCheck:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, y - 2)
        frame.convCheck:SetChecked(state.autoScroll)
        frame.convCheck:Show()
        y = y - (ROW_H + 12)
    elseif frame.convCheck then
        frame.convCheck:Hide()
    end

    --[[ [#1092] "Use all", one row per bulk-safe scroll type you are actually
         carrying. Rows for types you hold none of are not drawn at all: a column
         of seven greyed buttons is a worse answer than a section that simply is
         not there, and the height this section costs is reported to the Dashboard
         from the same count (see GetMinHeight).

         Laid out off the running `y` like every other block here, so it cannot
         collide with however many professions the character happened to have. ]]
    local held = bulkHeld()
    if #held > 0 then
        y = y - 6
        Head("Use in bulk")
        for idx, row in ipairs(bulkRows) do
            local h = held[idx]
            if h then
                row.label:ClearAllPoints()
                row.label:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, y - 4)
                row.label:SetText(string.format("%s%s|r", COLOR_LABEL, h.name))
                row.label:Show()

                row.btn:ClearAllPoints()
                row.btn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -22, y - 1)
                -- The count lives on the BUTTON, not beside the name: it is the
                -- number the confirmation is about to quote back, so it should be
                -- the number under the cursor.
                row.btn.entry, row.btn.count, row.btn.scrollName = h.entry, h.count, h.name
                row.btn:SetText(string.format("Use all (%d)", h.count))
                row.btn:Show()

                y = y - BULK_H
            else
                row.label:Hide()
                row.btn.entry = nil
                row.btn:Hide()
            end
        end
    else
        hideBulkRows()
    end

    y = y - 6
    if state.fortuneAll > #state.fortune then
        Head(string.format("Scroll of Fortune  (showing %d of %d)", #state.fortune, state.fortuneAll))
    else
        Head(string.format("Scroll of Fortune  (%d)", state.fortuneAll))
    end

    for n = i, #lines do lines[n]:Hide() end

    -- Anchor the Fortune list under whatever the sections above ended up using,
    -- so a character with six professions does not overlap it.
    if #state.fortune > 0 then
        fortuneScroll:ClearAllPoints()
        fortuneScroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, y - 2)
        fortuneScroll:Show()
        for n = 1, FORTUNE_ROWS do
            fortuneRows[n]:ClearAllPoints()
            fortuneRows[n]:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, y - 2 - (n - 1) * ROW_H)
        end
        RefreshFortuneRows()
    else
        fortuneScroll:Hide()
        for n = 1, FORTUNE_ROWS do fortuneRows[n]:Hide() end
        local fs = AcquireLine(i, y)
        fs:SetText(COLOR_DIM .. "No Fortune bonuses yet." .. "|r")
    end
end

local function BuildFrame(parent)
    if frame then return end

    frame = CreateFrame("Frame", "UncappedScrollsFrame", parent or UIParent)
    frame:SetPoint("TOPLEFT"); frame:SetPoint("BOTTOMRIGHT")

    fortuneScroll = CreateFrame("ScrollFrame", "UncappedScrollsFortuneScroll", frame, "FauxScrollFrameTemplate")
    fortuneScroll:SetWidth(WIDTH - 60)
    fortuneScroll:SetHeight(FORTUNE_ROWS * ROW_H)
    fortuneScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, RefreshFortuneRows)
    end)

    for i = 1, FORTUNE_ROWS do
        local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetJustifyH("LEFT")
        fs:SetWidth(WIDTH - 60)
        fs:Hide()
        fortuneRows[i] = fs
    end

    -- [#1092] One reusable row per bulk-safe scroll TYPE (there are seven and there
    -- will never be many), built once for the same reason AcquireLine pools its
    -- font strings: this window is opened and closed constantly.
    for i = 1, #BULK_SCROLLS do
        local row = {}

        row.label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.label:SetJustifyH("LEFT")
        row.label:SetWidth(WIDTH - 160)
        row.label:Hide()

        local btn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        btn:SetWidth(110)
        btn:SetHeight(20)
        btn:SetText("Use all")
        btn:SetScript("OnClick", function(self)
            -- Re-read nothing here: `count` was written by the same Render pass
            -- that drew this label, and the confirmation quotes it. If the stack
            -- moved in between, the SERVER uses whatever is actually there -- the
            -- number in the dialog is a description, never an instruction.
            if not self.entry or (self.count or 0) <= 0 then return end
            StaticPopup_Show("UNCAPPED_SCROLLS_USE_ALL",
                self.count, self.scrollName or "scrolls", { entry = self.entry })
        end)
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.scrollName or "Use all", 1, 1, 1)
            GameTooltip:AddLine("Uses every one of these in your bags, in one go.",
                0.8, 0.8, 0.8, true)
            GameTooltip:AddLine("They are destroyed. You are asked to confirm first.",
                1, 0.5, 0.4, true)
            -- Said plainly, because the obvious question on seeing this button is
            -- "why is there no such button for my Scrolls of Transmog?".
            GameTooltip:AddLine("Scrolls that open a window when used -- Transmog, Extraction, "
                .. "Socket -- have no bulk button: they consume nothing until you pick "
                .. "something in that window.", 0.6, 0.6, 0.7, true)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        btn:Hide()

        row.btn = btn
        bulkRows[i] = row
    end

    frame:Hide()
end

-- ---------------------------------------------------------------------------
-- Comms
-- ---------------------------------------------------------------------------
--[[ ⚠ ASSIGNED, NOT DECLARED, and the `local Request` forward declaration above
     Render is what makes that legal.

     The auto-convert checkbox built inside Render (see the SCRCONV block) calls
     Request() from its OnClick. Render is compiled ~180 lines ABOVE this point, so
     with a plain `local function Request` here that call compiled as a read of the
     GLOBAL `Request` -- which is nil, so ticking the box threw "attempt to call
     global 'Request' (a nil value)" and never refreshed. Hoisting the local fixes
     it for that caller and for the [#1092] SCRDONE handler below, which needs the
     same function from a closure defined earlier in the file. ]]
function Request()
    SendAddonMessage(TRANSPORT_PREFIX, "SCRGET", "WHISPER", UnitName("player"))
end

local comms = CreateFrame("Frame")
comms:RegisterEvent("CHAT_MSG_ADDON")
-- [#1092] The "Use all" labels are client-side GetItemCount, so a bag change is
-- the only thing that can move them. Gated on the window being open and doing
-- nothing but a local repaint -- no message is sent from here.
comms:RegisterEvent("BAG_UPDATE")
comms:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "BAG_UPDATE" then
        -- ⚠ IsVisible, not IsShown. This panel is a Dashboard tab: EmbedInto shows
        --   the frame once and the Dashboard hides the GROUP around it, so IsShown
        --   stays true for the whole session and this would repaint on every bag
        --   change with the window shut. IsVisible walks the parents.
        if frame and frame:IsVisible() then Render() end
        return
    end

    local prefix, text = a1, a2
    if prefix ~= ADDON_PIPE_PREFIX or not text then return end
    if text:sub(1, 3) ~= "SCR" then return end

    --[[ [#1092] SCRDONE:<itemEntry>:<used> -- the mass-consume reply.

         ★ MATCHED BEFORE THE BURST ACCUMULATOR BELOW, deliberately. Every other
           SCR verb belongs to a status burst and opens `pending` on arrival; this
           one is an answer to an action and carries none of that data. Letting it
           fall through would open an accumulator that no SCREND ever closes, and
           the next real burst would then be merged into it instead of replacing
           it.

         `used` is what the server ACTUALLY consumed, which is not necessarily what
         the button offered -- the stack can move between the click and the call,
         and a Scroll of Mastery with nothing left to raise may be converted rather
         than spent. Reporting the server's number is the whole reason this is a
         reply and not a fire-and-forget. ]]
    local doneEntry, doneUsed = text:match("^SCRDONE:(%d+):(%d+)$")
    if doneEntry then
        doneEntry, doneUsed = tonumber(doneEntry), tonumber(doneUsed) or 0
        local nm = bulkName(doneEntry)
        if doneUsed > 0 then
            DEFAULT_CHAT_FRAME:AddMessage(string.format("%s[Scrolls]|r Used |cffffffff%d|r %s.",
                COLOR_HEAD, doneUsed, nm))
        else
            DEFAULT_CHAT_FRAME:AddMessage(COLOR_HEAD .. "[Scrolls]|r Nothing to use \226\128\148 "
                .. "no " .. nm .. " left in your bags.")
        end
        -- The bonuses those scrolls bought are server-side, so the panel is only
        -- right again once the server has re-sent them. Render() first so the
        -- button labels drop immediately; Request() repaints the rest when it lands.
        if frame and frame:IsShown() then Render() end
        Request()
        return
    end

    -- Any SCR line other than SCREND belongs to a burst in flight. The first one
    -- seen opens a fresh accumulator, so a second request while one is arriving
    -- replaces the old burst rather than merging with it.
    if not pending then
        pending = { professions = {}, fortune = {}, fortuneAll = 0,
                    gatherRange = 0, yieldTenths = 0, delver = 0, petDelver = nil, petMult = 2,
                    questCount = 0, questMult = 1, contagion = 0, contagionMax = 10,
                    contagionInnate = 0, autoScroll = nil }
    end

    local range, yield = text:match("^SCRACC:([%d%.%-]+):(%d+)$")
    if range then
        pending.gatherRange = tonumber(range) or 0
        pending.yieldTenths = tonumber(yield) or 0
        return
    end

    -- [#986] Scroll auto-convert. Its own anchored verb, so a client predating it
    -- simply falls off the end of the match chain and never shows the control.
    local conv = text:match("^SCRCONV:(%d+)$")
    if conv then
        pending.autoScroll = (tonumber(conv) or 0) == 1
        return
    end

    -- SCRCHR keeps its name for wire compatibility; the value it carries is
    -- account-wide now. See scroll_status_comms.cpp for why it wasn't folded
    -- into SCRACC.
    local delver = text:match("^SCRCHR:(%d+)$")
    if delver then
        pending.delver = tonumber(delver) or 0
        return
    end

    -- Hunters only -- the server simply omits this line for everyone else, so a
    -- nil petDelver is "not a hunter", not "no data".
    local petDelver, petMult = text:match("^SCRPET:(%d+):([%d%.]+)$")
    if petDelver then
        pending.petDelver = tonumber(petDelver) or 0
        pending.petMult   = tonumber(petMult) or 2
        return
    end

    local qcount, qmult = text:match("^SCRQST:(%d+):([%d%.]+)$")
    if qcount then
        pending.questCount = tonumber(qcount) or 0
        pending.questMult  = tonumber(qmult) or 1
        return
    end

    -- [#882] Per character, and sent even at zero -- "I have none" is a real answer
    -- here, and the absence of a row was the whole report.
    local contagion, contagionMax = text:match("^SCRCON:(%d+):(%d+)$")
    if contagion then
        pending.contagion    = tonumber(contagion) or 0
        pending.contagionMax = tonumber(contagionMax) or 10
        return
    end

    -- [#902] Class grant, sent only to classes that have one (priests today). Its
    -- absence is the answer "none", so nothing here needs a not-received sentinel.
    local innate = text:match("^SCRCIN:(%d+)$")
    if innate then
        pending.contagionInnate = tonumber(innate) or 0
        return
    end

    -- Profession and map names can contain spaces and apostrophes but never a
    -- colon, so anchoring the numeric tail is enough to split them safely.
    local pname, cur, max = text:match("^SCRPRF:(.+):(%d+):(%d+)$")
    if pname then
        tinsert(pending.professions, { name = pname, cur = tonumber(cur), max = tonumber(max) })
        return
    end

    local mname, bonus = text:match("^SCRFOR:(.+):([%d%.%-]+)$")
    if mname then
        tinsert(pending.fortune, { name = mname, bonus = tonumber(bonus) or 0 })
        return
    end

    local total = text:match("^SCREND:(%d+)$")
    if total then
        pending.fortuneAll = tonumber(total) or #pending.fortune
        pending.received   = true
        state   = pending
        pending = nil
        if frame and frame:IsShown() then Render() end
        return
    end
end)

-- ===========================================================================
-- Dashboard embedding
-- ===========================================================================
-- The Dashboard hosts this panel directly inside its own window instead of
-- Scrolls owning a window of its own -- see UncappedDashboard_UI.lua, which
-- calls EmbedInto once (to build the frame into its content group) and
-- Activate every time the Soul Scrolls tab is selected.
local Scrolls = _G.UncappedScrolls or {}
_G.UncappedScrolls = Scrolls
Scrolls.UI = {}

function Scrolls.UI.EmbedInto(parent)
    BuildFrame(parent)
    frame:Show()
    return frame
end

function Scrolls.UI.Activate()
    if not frame then return end
    Render()      -- paint immediately with whatever's cached
    Request()     -- then refresh
end

-- Content-panel width (not window width) Scrolls needs: its original
-- standalone window's width (360) plus the embedded group's own 6px padding
-- on each side = 372.
function Scrolls.UI.GetMinWidth()
    return 372
end

-- Full window height (not content height) Scrolls needs: its original
-- standalone window's height (440) plus the Dashboard window's own chrome
-- (title/banner + margins) that a standalone window didn't have to account
-- for, ~72px.
function Scrolls.UI.GetMinHeight()
    -- +14 for the Scroll of Contagion row added by #882.
    -- +14 for the detail line under it added by #902 ("n innate + m of 10 scrolls").
    -- Reserved unconditionally: this is a fixed number, and a priest opening the tab
    -- must not be the case that overflows it.
    --
    -- [#1092] ...plus the "Use in bulk" section, which is the one part of this panel
    -- whose height genuinely varies -- it draws a row only for a scroll type you are
    -- carrying, and there are seven. Measured rather than reserved at the maximum:
    -- reserving 7 rows would make the window 154px taller for everyone including the
    -- majority holding none. The Dashboard re-asks on every tab activation, and the
    -- floor it sets is clamped to the screen by Buttons.SetMinContentHeight, so a
    -- number that grows here can never push the window off-screen.
    local extra = 0
    for _, s in ipairs(BULK_SCROLLS) do
        if (GetItemCount(s.entry) or 0) > 0 then extra = extra + BULK_H end
    end
    if extra > 0 then extra = extra + 22 end   -- the section heading
    return 540 + extra
end

-- Switches the Dashboard to the Soul Scrolls tab, opening it if it's closed.
-- Used by the settings-page button -- Scrolls has no window of its own
-- anymore to open directly.
local function OpenInDashboard()
    local Dashboard = _G.UncappedDashboard
    if not Dashboard then
        DEFAULT_CHAT_FRAME:AddMessage(COLOR_HEAD .. "[Scrolls]|r now lives inside the Dashboard -- load UncappedDashboard to use it.")
        return
    end
    Dashboard.SetTab("soulscrolls")
    if not (Dashboard.UI and Dashboard.UI.IsShown and Dashboard.UI.IsShown()) then
        Dashboard.Toggle()
    end
end

-- ---------------------------------------------------------------------------
-- Entry points
-- ---------------------------------------------------------------------------
-- Opening the window is now /dashboard's job (this is just a Dashboard tab), so
-- /scrolls only survives for its "sync" argument -- a distinct data-refresh
-- action, not a window toggle.
SLASH_UNCAPPEDSCROLLS1 = "/scrolls"
SlashCmdList["UNCAPPEDSCROLLS"] = function(arg)
    arg = (arg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if arg == "sync" then
        Request()
        DEFAULT_CHAT_FRAME:AddMessage(COLOR_HEAD .. "[Scrolls]|r Refreshing...")
    else
        DEFAULT_CHAT_FRAME:AddMessage(COLOR_HEAD .. "[Scrolls]|r type |cffffd100/dashboard|r to open Scroll Bonuses, or |cffffd100/scrolls sync|r to refresh.")
    end
end

-- Settings page (ESC > Interface > AddOns > Uncapped > Scrolls). Provided by the
-- shared UncappedUI widget library (UncappedOptions addon); guard on it so the
-- settings page just doesn't appear if that addon is missing.
if UncappedUI then
    local _, L = UncappedUI.CreatePanel("Scrolls",
        "Every customization-scroll bonus on your account -- Reach, Bounty, Fortune, Mastery and Delver.")

    L:Header("Scroll bonuses")
    L:Button("Open Scroll Bonuses", OpenInDashboard, 180)
    L:Note("Shows what each scroll you have used is actually giving you, including which "
        .. "instances your Scroll of Fortune bonuses landed on, plus your account-wide "
        .. "quest bonus to Anima. Also available with /scrolls.", 48)
end
