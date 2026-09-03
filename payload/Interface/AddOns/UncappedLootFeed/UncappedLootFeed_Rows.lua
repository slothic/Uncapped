-- UncappedLootFeed_Rows -- one loot row, drawn the same way everywhere.
--
-- WHY THIS IS ITS OWN FILE
--   There are two views over the same ring now: the Dashboard tab and the
--   pop-out window (#125). A row is the same object in both -- icon, source
--   column, item name, watched marker -- and the moment each view drew its own,
--   they would start to drift. The first thing to drift would have been the
--   watched highlight, which is precisely the thing the owner asked to be
--   unmistakable.
--
-- THE WATCHED TREATMENT  (the "target items" ask)
--   Three signals, because one is easy to miss while you are fighting:
--     * a gold GLOW around the icon -- the stock action-button border texture,
--       which is what this client already uses to mean "this one matters";
--     * the name in gold rather than in its quality colour;
--     * a second line saying WHERE it drops, from the baked source table.
--   Everything else in the feed stays quiet, which is the whole point -- a
--   highlight that fires on every row is just a louder feed.
--
-- ROW HEIGHT IS UNIFORM, AND DELIBERATELY SO
--   Watched rows carry a second line and unwatched ones do not, so the obvious
--   build gives them different heights. FauxScrollFrame's arithmetic is built on
--   one fixed row height -- offsets, thumb size and "how many fit" all assume it
--   -- and a variable-height list silently mis-scrolls. So every row is
--   ROW_H tall and the NAME moves instead: centred when it is alone, raised when
--   there is a source line under it.

local LF = _G.UncappedLootFeed
if not LF then return end

local Rows = {}
LF.Rows = Rows

Rows.H = 30
Rows.ICON = 20

local GOLD = "|cffffd100"
-- The Vault's own blue, the same one UncappedVault prefixes its chat lines with,
-- so "this went to the Vault" reads as the same thing in both places.
local VAULT_COLOR = "|cff40c0ff"

local CHECK_TEX = "Interface\\Buttons\\UI-CheckBox-Check"
-- The soft square glow the action bars use for a proc/equipped marker. Drawn at
-- 1.6x the icon so it reads as an outline AROUND it rather than a frame on it.
local GLOW_TEX  = "Interface\\Buttons\\UI-ActionButton-Border"

local function Data()
    return _G.UncappedLootFeedData
end

-- ---------------------------------------------------------------------------
-- Descriptors
-- ---------------------------------------------------------------------------
-- A Vault row arrives as a bare item id. Prefer a real link when the client has
-- one (identical rendering to a bag row, tooltip and shift-click included), and
-- fall back to the baked table's coloured name when it does not -- which is the
-- common case for something the player has never held.
local function ResolveLink(e)
    if e.link then return e.link end
    if not e.id then return nil end
    local _, live = GetItemInfo(e.id)
    return live
end

-- The "Drops from X in Y" line, or nil. Only ever asked for on a watched row:
-- on every row it would be a wall of grey text, and for an item you are not
-- farming it is noise.
function Rows.SourceLine(id)
    local db = LF.GetDB()
    if db and db.popoutSource == false then return nil end
    local D = Data()
    if not D or not D.SourceLine then return nil end
    return D.SourceLine(id, false)
end

-- Feed entry -> row descriptor. One shape, whatever built it:
--   { id, link, label, sub, watched, vault, plain }
--
-- MEMOISED ONTO THE ENTRY, the same way the engine already memoises e.q at
-- capture time (UncappedLootFeed.lua:254-260). The feed is an APPEND-ONLY ring of
-- up to 100 entries, and both views rebuilt every descriptor on every repaint --
-- the popout repaints 5x/s while loot is arriving, so ~600 Describe calls a
-- repaint and ~3,000 a second, to reproduce an identical answer for 99 rows in
-- 100. That is exactly the always-on repaint work that has cost this realm real
-- frames, and it lands hardest during AoE farming and bulk Vault deposits, when
-- the feed is most useful and the client is busiest.
--
-- Three things can legitimately change a built descriptor, and all three are in
-- the cache key so no external invalidation hook is needed:
--   * the watch state (gold name + the source sub-line appear/disappear),
--   * the item link resolving later (GetItemInfo had never seen the item yet),
--   * the "show source line" setting.
-- Feed entries are fresh tables per push and are never recycled, so the memo
-- cannot leak from one drop to another.
function Rows.Describe(e)
    local D = Data()

    if e.overflow then
        -- Tail of a batched bulk deposit -- see ULFVX in the engine. Fixed text,
        -- so it is built once and kept.
        local fixed = e.desc
        if not fixed then
            fixed = {
                label = VAULT_COLOR .. "Vault|r  |cffaaaaaa... and " .. e.overflow
                    .. " more stack" .. ((e.overflow == 1) and "" or "s") .. " banked|r",
                plain = true,
            }
            e.desc = fixed
        end
        return fixed
    end

    local link = ResolveLink(e)
    local watched = LF.IsWatched(e.id)

    local lfdb = LF.GetDB()
    local sourceOn = not (lfdb and lfdb.popoutSource == false)

    local cached = e.desc
    if cached and cached.watched == watched and cached.link == link
       and e.descSourceOn == sourceOn then
        return cached
    end

    -- First column is the SOURCE, and the Vault gets its own colour: the whole
    -- point of #214 is being able to see at a glance that the item went
    -- somewhere other than your bags.
    local source
    if e.src == LF.SRC_VAULT then
        source = VAULT_COLOR .. "Vault|r"
    elseif e.mine then
        source = "|cff40ff40" .. (e.who or "You") .. "|r"
    else
        source = "|cffaaaaaa" .. (e.who or "?") .. "|r"
    end

    local name

    if watched then
        -- Gold, not the quality colour: a watched drop has to win the row, and
        -- an epic's purple already competes with everything else on screen.
        name = GOLD .. ((D and D.NameFor(e.id)) or ("item " .. tostring(e.id))) .. "|r"
    else
        name = link or (D and D.ColoredName(e.id)) or ("item " .. tostring(e.id))
    end

    local suffix = (e.count and e.count > 1) and ("|cffffffff x" .. e.count .. "|r") or ""

    local desc = {
        id      = e.id,
        link    = link,
        label   = source .. "  " .. name .. suffix,
        sub     = watched and Rows.SourceLine(e.id) or nil,
        watched = watched,
        vault   = (e.src == LF.SRC_VAULT),
    }

    -- Only keep it once the baked table is answering. Before that the name would
    -- be the "item 12345" fallback, and caching that would freeze it there.
    if D and D.IsReady and D.IsReady() then
        e.desc = desc
        e.descSourceOn = sourceOn
    else
        e.desc = nil
    end

    return desc
end

-- ---------------------------------------------------------------------------
-- Widget
-- ---------------------------------------------------------------------------
local function OnClick(self)
    local entry = self.entry
    if not entry or not entry.id then return end

    -- Shift-click puts the link in whatever edit box is open, which is what
    -- shift-click does everywhere else in this client.
    if IsShiftKeyDown() and entry.link and ChatEdit_InsertLink then
        ChatEdit_InsertLink(entry.link)
        return
    end

    local D = Data()
    local name = D and D.NameFor(entry.id) or nil
    local nowWatched = LF.ToggleWatch(entry.id, name)

    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|cffffd100[Loot Feed]|r %s %s.",
        nowWatched and "watching for" or "no longer watching",
        name or ("item " .. entry.id)))
end

local function OnEnter(self)
    local entry = self.entry
    if not entry then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")

    -- The batched-deposit tail has no item behind it, so there is nothing to
    -- link and nothing to watch -- say what it is instead of showing a bare
    -- "click to watch" on a row that does not respond to clicks.
    if entry.plain then
        GameTooltip:SetText("Vault", 0.25, 0.75, 1)
        GameTooltip:AddLine("A bulk deposit banked more stacks than the feed lists individually.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
        return
    end

    if entry.link then
        GameTooltip:SetHyperlink(entry.link)
    elseif entry.id then
        GameTooltip:SetHyperlink("item:" .. entry.id)
    end

    -- The full source line, WITH the drop chance and the "+N more sources"
    -- tail, lives here for every item -- not just watched ones. The row can
    -- only afford the short version, and this is where someone deciding whether
    -- to watch an item wants the detail.
    local D = Data()
    if D and D.SourceLine and entry.id then
        local line = D.SourceLine(entry.id, true)
        if line then GameTooltip:AddLine(line, 0.45, 0.75, 0.45, true) end
    end

    if entry.vault then
        GameTooltip:AddLine("Went straight to your Vault, not your bags.", 0.25, 0.75, 1)
    end
    GameTooltip:AddLine(entry.watched and "Click to stop watching" or "Click to watch this item", 0.7, 0.7, 0.7)
    if entry.link then
        GameTooltip:AddLine("Shift-click to link it in chat", 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
end

-- Unanchored on purpose: the tab and the window place their rows differently,
-- and a factory that also positioned them would need to know about both.
function Rows.Create(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(Rows.H)

    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    if row:GetHighlightTexture() then row:GetHighlightTexture():SetBlendMode("ADD") end

    -- Vault rows get a faint blue wash as well as the "Vault" label, so the
    -- distinction survives someone skimming rather than reading the first word
    -- of every line.
    row.tint = row:CreateTexture(nil, "BACKGROUND")
    row.tint:SetAllPoints(row)
    row.tint:SetTexture(0.10, 0.42, 0.68, 0.15)
    row.tint:Hide()

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetWidth(Rows.ICON)
    row.icon:SetHeight(Rows.ICON)
    row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)
    -- Trim the stock icon border so it sits flush next to the text.
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    row.glow = row:CreateTexture(nil, "OVERLAY")
    row.glow:SetTexture(GLOW_TEX)
    row.glow:SetBlendMode("ADD")
    row.glow:SetWidth(Rows.ICON * 1.6)
    row.glow:SetHeight(Rows.ICON * 1.6)
    row.glow:SetPoint("CENTER", row.icon, "CENTER", 0, 0)
    row.glow:SetVertexColor(1.0, 0.82, 0.15)
    row.glow:Hide()

    row.check = row:CreateTexture(nil, "OVERLAY")
    row.check:SetWidth(16)
    row.check:SetHeight(16)
    row.check:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    row.check:SetTexture(CHECK_TEX)
    row.check:Hide()

    --[[ Both strings are anchored from ONE edge only -- the name from the top,
         the source line from the bottom -- with left/right giving them their
         width.

         Mixing a vertical anchor with a centring one (LEFT/RIGHT anchors carry
         a vertical centre of their own) over-constrains the frame, and 3.3.5
         resolves that by quietly ignoring one of them. Keeping each string on a
         single vertical reference is what makes the one-line and two-line
         layouts land where they are supposed to. ]]
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetJustifyH("LEFT")

    row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.sub:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", Rows.ICON + 10, 3)
    row.sub:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -22, 3)
    row.sub:SetJustifyH("LEFT")
    row.sub:SetTextColor(0.55, 0.72, 0.55)

    row:SetScript("OnClick", OnClick)
    row:SetScript("OnEnter", OnEnter)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return row
end

function Rows.Paint(row, entry)
    row.entry = entry
    if not entry then
        row:Hide()
        return
    end

    local D = Data()

    -- A plain row (the batched-deposit tail) has no item, so no icon to draw --
    -- IconFor would hand back the question mark, which reads like a broken item.
    if entry.plain then
        row.icon:SetTexture(nil)
    else
        row.icon:SetTexture(D and D.IconFor(entry.id) or nil)
    end

    row.text:SetText(entry.label or "")

    --[[ The name's TOP offset is what absorbs the second line: high when there
         is a source line under it, half-way down when the row is a single line.
         Cleared first, because SetPoint ADDS anchors and a row recycled from the
         other state would otherwise carry both. ]]
    local twoLine = (entry.sub and entry.sub ~= "") and true or false
    local topInset = twoLine and 3 or 9

    row.text:ClearAllPoints()
    row.text:SetPoint("TOPLEFT", row, "TOPLEFT", Rows.ICON + 10, -topInset)
    row.text:SetPoint("TOPRIGHT", row, "TOPRIGHT", -22, -topInset)

    if twoLine then
        row.sub:SetText(entry.sub)
        row.sub:Show()
    else
        row.sub:SetText("")
        row.sub:Hide()
    end

    if entry.watched then row.check:Show() else row.check:Hide() end
    if entry.watched and not entry.plain then row.glow:Show() else row.glow:Hide() end
    if entry.vault or entry.plain then row.tint:Show() else row.tint:Hide() end

    row:Show()
end
