--------------------------------------------------------------------------
-- Moonforge v1.4.1  (Uncapped / WotLK 3.3.5a)
--
-- A ground-up recreation of the Uncapped Soulforge tab as a standalone
-- addon, with the whitelist and consume workflows expanded.
--
-- Originally by Mhortai (v1.4.0), shipped on Uncapped with realm-side fixes.
-- v1.4.1 changes, all in the gap between what the addon BELIEVED it sent and
-- what the server actually accepted:
--   * bulk whitelist queue repaced from 16/s to 1.33/s -- it was 8x over the
--     server's token budget and silently lost ~70% of a large batch
--   * lost adds are now detected against the authoritative list, retried, and
--     reported in red if they still will not land
--   * Auto-Consume cannot be armed while a whitelist batch is still draining
--   * ICERR is handled: without it the Soulbind Duplicates button bricked
--     itself on the ordinary "nothing to bind" reply
--   * every in-flight flag has a timeout, not just a reply handler
--   * the "copies of soulbound gear are never consumed" rule text was false
--
-- Wire protocol (verbatim from the official UncappedSoulForge source --
-- nothing here is invented):
--   SEND    : SendAddonMessage("REAGENTBANK", body, "WHISPER", UnitName("player"))
--   RECEIVE : CHAT_MSG_ADDON, prefix "UNC", body in arg2.
--
--   ICSF                       -> ICSF:<extractPctx100>:<fillPctx10>:<completions>:<autoconsume>:<autoopen>
--   ICSFDING:<levels>             the forge levelled
--   ICAC:<0|1>                 -> server arms + replies ICACWARN:<secs>; confirm with ICAC:1:CONFIRM
--   ICVRENDER                  -> ICVR:<stacks>:<pieces>:<souls>:<armSecs> forecast; confirm ICVRENDER:CONFIRM
--                                 -> ICVRDONE:<stacks>:<pieces>:<souls>
--                                 (server rule: GREY + WHITE, VAULT only)
--   ICWLIST                    -> ICWL:<name> ... ICWLEND
--   ICWLADD:<name> / ICWLREM:<name>
--   ICISEARCH:<query>          -> ICINAME:<name> ... ICINAMEEND   (expensive server-side: debounced,
--                                 one in flight, timeout -- pacing copied from the official addon)
--   ICEXSRC                    -> ICEXI:<bag>:<slot>:<entry>:<equipped>:<spellId>:<trigger> ... ICEXIEND
--                                 (spellId 0 = no extractable proc; used for "Whitelist Procs")
--   ICINV                      -> per soulbound item: ICITEM:<key> (key "E:<invSlot>" or "B:<bag>:<slot>"),
--                                 then ICISTAT/ICIPROC lines, and ICIVEST:<count>:<multPct> when the item
--                                 has absorbed duplicates; the stream ends with ICINVEND.
--                                 (used by the Soulbound Info window)
--   ICSBALL                    -> ICBOUNDALL:<count>, or ICERR:soulbindall:<reason> when there was
--                                 nothing to bind. BOTH replies must be handled -- see the ICERR
--                                 branch. ~1,500 unbatched DB writes per press server-side, so the
--                                 30s client-side courtesy cooldown is kept on top of the throttle.
--
-- ★★ EVERY VERB ABOVE IS METERED. src/server/game/Handlers/AddonThrottle.cpp runs a
--    per-player token bucket -- 60 burst, 6 tokens/second refill -- and a verb the
--    bucket cannot afford is DROPPED: not answered, not queued, not retried. Prices:
--    ICINV / ICEXSRC / ICISEARCH cost 6 each, ICWLADD / ICWLREM / ICAC / ICVRENDER /
--    ICSBALL cost 3, ICSF / ICWLIST cost 2. The bucket is shared with every other
--    addon on the account, and a zone-in alone costs 28.
--
--    The server pushes one "UTHR:<ms>" line when it drops something, rate limited to
--    one per two seconds and naming no verb. That is a DIAGNOSIS, never a clock --
--    pace your own sends and use UTHR only to explain a failure.
--
--    ⚠ Consequences, learned the hard way and encoded below: every in-flight flag
--      needs a plain timeout as well as a reply handler, and no destructive action
--      may be armed while a bulk queue is still draining.
--
-- House rules: no output to the default chat frames beyond the single login
-- version stamp; all runtime messages go to the in-window status line and
-- the /mf log window. No C_Timer (doesn't exist on 3.3.5a) -- an OnUpdate
-- scheduler stands in. All shared state is declared at the top of the file,
-- above every consumer.
--
-- Slash: /moonforge or /mf   (also: /mf log, /mf options, /mf debug)
--------------------------------------------------------------------------

local ADDON_NAME  = "Moonforge"
local VERSION     = "1.4.1"
local SEND_PREFIX = "REAGENTBANK"
local PIPE_PREFIX = "UNC"

--========================== shared state (top, always) ====================
local db                                   -- SavedVariables (MoonforgeDB), set at ADDON_LOADED
local UI, WLADD, WLLIST, LOGWIN, SBINFO    -- main window + sub-windows (built lazily)
local mmBtn, optPanel                      -- minimap button + Interface Options panel
local openMain                             -- assigned below; declared here so the
                                           -- minimap/options handlers close over THIS
                                           -- local, not a nil global (scoping rule)
local debugWire = false

local state = {
  sf = { mult = 0, fill = 0, completions = 0, autoconsume = false, autoopen = 0 },
  vr = { stacks = 0, pieces = 0, souls = 0 },
  whitelist  = {},        -- committed names, server order
  wlStaging  = {},
  wlSet      = {},        -- lowercase set for dedupe
  wlSuggest  = {},        -- ICINAME search hits
  wlSuggestStaging = {},

  -- Soulbind Duplicates pacing (values verbatim from the official addon)
  sbReadyAt  = 0,
  sbInflight = false,
  sbCooldown = 30,

  -- "Whitelist Procs" pending ICEXSRC sweep. Other addons (VaultScan) fire
  -- ICEXSRC too, so replies only count while this is armed and fresh.
  procWL = { pending = false, since = 0, entries = {}, entryName = {} },

  -- Soulbound Info: ICINV stream staging. Keys are the server's item keys
  -- ("E:<invSlot>" / "B:<bag>:<slot>"); values are vestige count + worth.
  sbi = { curKey = nil, staging = {}, items = nil },

  -- outbound queue for bulk whitelist adds (pace SendAddonMessage bursts)
  queue = {}, queueAfter = nil,             -- queueAfter: verb sent when queue drains

  -- ★★ INTENT LEDGER. wlSet is written OPTIMISTICALLY when a name is queued, and
  --    the server's ICWLEND rebuilds it from truth -- so after a batch the two
  --    disagree exactly where a message was lost. wlIntent remembers what we meant
  --    to add so that difference can be measured instead of silently absorbed.
  --    Without it a dropped ICWLADD is invisible: the panel converges to the right
  --    (smaller) list and nothing ever contradicts the "Whitelisting 137..." line.
  wlIntent = {}, wlRound = 0,

  -- One-shot per-rarity consume (ICVCONSUME). `pending` is the ask we have sent
  -- and not yet had a forecast for; quality/scope are echoed back by the server
  -- so the confirm dialog can name exactly what is about to go.
  -- ⚠ The echo is COPY. The gate is the server's own stored arm -- a forecast left
  --   on screen from one button cannot be confirmed against another's scope,
  --   because ICVCONSUME:CONFIRM deliberately takes no arguments.
  vc = { pending = false, since = 0, quality = nil, scope = nil },
}

--========================== tiny OnUpdate scheduler =======================
local schedFrame = CreateFrame("Frame")
local scheduled  = {}
schedFrame:SetScript("OnUpdate", function(_, elapsed)
  local any = false
  for tok in pairs(scheduled) do
    any = true
    tok.left = tok.left - elapsed
    if tok.left <= 0 then
      scheduled[tok] = nil
      local ok, err = pcall(tok.fn)
      if not ok and debugWire then
        if _G.Moonforge_LogLine then _G.Moonforge_LogLine("timer error: " .. tostring(err)) end
      end
    end
  end
  if not any then schedFrame:Hide() end
end)
schedFrame:Hide()
local function After(sec, fn)
  scheduled[{ left = sec, fn = fn }] = true
  schedFrame:Show()
end

--========================== log / status (no chat output) =================
local logLines, LOG_MAX = {}, 200
local function refreshLogWindow() if LOGWIN and LOGWIN:IsShown() then LOGWIN:Refresh() end end
local function log(text)
  table.insert(logLines, date("%H:%M:%S ") .. text)
  while #logLines > LOG_MAX do table.remove(logLines, 1) end
  if UI and UI.status then UI.status:SetText(text) end
  refreshLogWindow()
end
_G.Moonforge_LogLine = log
local function dbg(text) if debugWire then log("|cff667799" .. text .. "|r") end end

--========================== transport =====================================
local function send(body)
  dbg("-> " .. body)
  SendAddonMessage(SEND_PREFIX, body, "WHISPER", UnitName("player"))
end

-- Bulk sender, then an optional trailing verb (used to fire one ICWLIST refresh
-- after a batch of ICWLADDs).
--
-- ★★ THE RATE IS THE SERVER'S, NOT A GUESS. Every inbound addon verb is metered
--    by a per-player token bucket (AddonThrottle.cpp): 60 burst, 6 tokens/second
--    refill, and a verb the bucket cannot afford is DROPPED -- not queued, not
--    answered, not retried. ICWLADD is COST_WRITE = 3 tokens, so the sustainable
--    rate is exactly 6/3 = 2 per second.
--
--    This pump originally sent 4 per 0.25s = 16/s = 48 tokens/s, EIGHT TIMES the
--    refill. It drained a full bucket in 1.4s and then dropped roughly everything
--    after the first ~22 names. On a 137-name "Whitelist Sets" sweep that is 100
--    adds thrown away while the status line said all 137 were done -- and the
--    whitelist is the only thing standing between your gear and Auto-Consume.
--
--    One message per 0.75s is 4 tokens/s, DELIBERATELY UNDER the 6/s refill. Not
--    at it: the bucket is shared with every other addon on the account, and a
--    zone-in alone costs 28 tokens. Pacing exactly at the refill would keep the
--    burst permanently flat and simply move the starvation onto the quest ledger,
--    the shard panel and the anima panel -- which is the four-reports-one-cause
--    failure this realm has already had once. Leaving 2 tokens/s spare lets the
--    burst rebuild underneath a long batch.
--
--    It is slower on purpose. A 19-slot "Whitelist Equipped" takes 14 seconds and
--    every name arrives, which beats 1.4 seconds and losing 100 of them.
local PUMP_INTERVAL = 0.75
local settleTries = 0
local pumpFrame, pumpAccum = CreateFrame("Frame"), 0
pumpFrame:Hide()
pumpFrame:SetScript("OnUpdate", function(_, elapsed)
  pumpAccum = pumpAccum + elapsed
  if pumpAccum < PUMP_INTERVAL then return end
  pumpAccum = 0
  local body = table.remove(state.queue, 1)
  if body then send(body) end
  if #state.queue == 0 then
    pumpFrame:Hide()
    if state.queueAfter then
      local trailing = state.queueAfter
      state.queueAfter = nil
      send(trailing)
    end
    --[[ ⚠ THE SETTLE WATCHDOG, and it is not optional.
      Reconciliation runs in the ICWLEND branch, and every accepted ICWLADD
      produces one -- so normally the last add's own reply triggers it. But if the
      LAST add is the one that gets dropped, no ICWLEND follows it, and the trailing
      ICWLIST above is only 2 tokens and can be dropped too. Without this, a batch
      that loses its tail never reconciles and never warns: exactly the silence the
      whole fix exists to remove. Ask again, bounded, until intent is resolved.  ]]
    if next(state.wlIntent) then
      settleTries = (settleTries or 0) + 1
      if settleTries <= 4 then
        After(4, function()
          if next(state.wlIntent) and #state.queue == 0 then send("ICWLIST") end
        end)
      else
        local n = 0
        for _ in pairs(state.wlIntent) do n = n + 1 end
        state.wlIntent, state.wlRound, settleTries = {}, 0, 0
        log(string.format("|cffff2020The server never confirmed %d whitelist add(s). "
                          .. "Reopen The List to check what is actually protected.|r", n))
      end
    else
      settleTries = 0
    end
  end
end)
local function enqueue(body) table.insert(state.queue, body); pumpAccum = 1; pumpFrame:Show() end
local function flushQueueThen(verb)
  if #state.queue == 0 then send(verb) else state.queueAfter = verb end
end

--========================== helpers =======================================
local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function groupDigits(n)
  local s, out = tostring(math.floor(tonumber(n) or 0)), ""
  while #s > 3 do out = "," .. s:sub(-3) .. out; s = s:sub(1, -4) end
  return s .. out
end

local function linkName(link)
  if not link then return nil end
  return link:match("%[(.-)%]") or GetItemInfo(link)
end
local function linkEntry(link)
  if not link then return nil end
  local id = link:match("item:(%d+)")
  return id and tonumber(id) or nil
end
local function lerp(a, b, t) return a + (b - a) * t end

-- Moonlight bar gradient: deep indigo at the trailing edge, pale silver-blue
-- at the leading edge; the whole bar brightens gently as it approaches full.
local function moonColours(f)
  f = math.max(0, math.min(1, f))
  local l1 = { lerp(0.20, 0.34, f), lerp(0.17, 0.30, f), lerp(0.48, 0.74, f) }
  local l2 = { lerp(0.60, 0.88, f), lerp(0.68, 0.94, f), lerp(0.92, 1.00, f) }
  return l1, l2
end

-- Hidden tooltip scanner (set-bonus detection).
local scanTip = CreateFrame("GameTooltip", "MoonforgeScanTip", nil, "GameTooltipTemplate")
local function tooltipHasSetLine()
  local n = scanTip:NumLines() or 0
  for i = 2, n do
    local fs = _G["MoonforgeScanTipTextLeft" .. i]
    local t = fs and fs:GetText()
    -- Set headers render as "Set Name (0/8)". Durability uses "100 / 100"
    -- (spaced), so this anchored pattern cannot confuse the two.
    if t and t:match("^.+ %((%d+)/(%d+)%)$") then return true end
  end
  return false
end

-- Iterate worn gear: cb(invSlot, link). Slots 1..19 (0 is ammo).
local function forEachEquipped(cb)
  for slot = 1, 19 do
    local link = GetInventoryItemLink("player", slot)
    if link then cb(slot, link) end
  end
end
-- Iterate bag gear: cb(bag, slot, link). Bags 0..4.
local function forEachBagItem(cb)
  for bag = 0, 4 do
    local slots = GetContainerNumSlots(bag) or 0
    for slot = 1, slots do
      local link = GetContainerItemLink(bag, slot)
      if link then cb(bag, slot, link) end
    end
  end
end

-- One scan of worn + carried gear -> { lowercased name = link }. Built once
-- per List refresh so 30 rows don't each rescan five bags.
local function buildNameLinkMap()
  local map = {}
  forEachEquipped(function(_, link)
    local nm = linkName(link)
    if nm then map[nm:lower()] = link end
  end)
  forEachBagItem(function(_, _, link)
    local nm = linkName(link)
    if nm then map[nm:lower()] = link end
  end)
  return map
end

-- "bulwark of smouldering steel" -> "Bulwark Of Smouldering Steel", for
-- whitelist substrings that never resolve to a real item.
local function titleCase(s)
  return (tostring(s):gsub("(%a[%w']*)", function(w)
    return w:sub(1, 1):upper() .. w:sub(2)
  end))
end

-- Resolve a whitelist NAME back to a real item link where possible: exact
-- match against carried/worn gear first, then the client's item-info cache.
-- The whitelist is substrings, so this can legitimately fail -- the caller
-- shows a generic "protects anything containing this" tooltip then.
local function resolveNameToLink(name)
  local want, found = tostring(name):lower(), nil
  forEachEquipped(function(_, link)
    if not found and (linkName(link) or ""):lower() == want then found = link end
  end)
  if found then return found end
  forEachBagItem(function(_, _, link)
    if not found and (linkName(link) or ""):lower() == want then found = link end
  end)
  if found then return found end
  local _, link = GetItemInfo(name)
  return link
end

-- Resolve a server ICINV item key to a link. Key shapes from the official
-- source: "E:<invSlot>" (worn) or "B:<bag>:<slot>" (carried).
local function resolveKeyToLink(key)
  local inv = key:match("^E:(%d+)$")
  if inv then return GetInventoryItemLink("player", tonumber(inv)) end
  local bag, slot = key:match("^B:(%d+):(%d+)$")
  if bag then return GetContainerItemLink(tonumber(bag), tonumber(slot)) end
  return nil
end

-- One dedupe gate for whitelist adds. Returns true if enqueued.
local function wlAdd(name)
  name = trim(name)
  if name == "" then return false end
  if state.wlSet[name:lower()] then return false end
  state.wlSet[name:lower()] = true      -- optimistic; ICWLEND is the authority
  state.wlIntent[name:lower()] = name   -- ...and this is what we can hold it to
  enqueue("ICWLADD:" .. name)
  return true
end

-- True while any whitelist add is still queued or still unconfirmed. Nothing
-- destructive may be armed while this is true -- see the Auto-Consume gate.
local function wlSettling()
  return #state.queue > 0 or next(state.wlIntent) ~= nil
end

-- Ask for the soulbound-item stream, and remember WHEN so a dropped request can
-- be told apart from a slow one. Every send of a COST_HEAVY verb wants this.
local function askInv()
  state.sbi.askedAt = GetTime() or 0
  send("ICINV")
  After(8.5, function()
    if not state.sbi.items and SBINFO and SBINFO:IsShown() then SBINFO:Refresh() end
  end)
end

--========================== popup dedupe ==================================
-- If the official Soulforge addon is also loaded, it raises its own dialog
-- for ICACWARN / ICVR. Two identical consent dialogs stacked on top of each
-- other is worse than one, and theirs sends the same confirm verbs ours
-- would -- so ours yields. The 0.15s delay lets their same-tick handler
-- show first regardless of event-registration order.
local function showDeduped(ourKey, theirKey, a1, a2)
  After(0.15, function()
    if StaticPopup_Visible and StaticPopup_Visible(theirKey) then
      dbg("popup " .. ourKey .. " suppressed (official addon showed " .. theirKey .. ")")
      return
    end
    StaticPopup_Show(ourKey, a1, a2)
  end)
end

--========================== StaticPopups ==================================
-- Consent dialogs for irreversible destruction. The wording names EXACTLY
-- what the server will eat, same rule the official addon holds itself to.
StaticPopupDialogs["MOONFORGE_AUTOCONSUME"] = {
  text = "|cffff2020This permanently destroys gear.|r\n\n"
      .. "While Auto-Consume is on, every |cffffffffcommon, uncommon, rare or epic|r weapon and armour "
      .. "piece you are |cffffffffnot wearing|r is rendered down for souls -- out of your bags "
      .. "|cffffffffand out of your Vault|r -- automatically, within seconds. It cannot be "
      .. "undone, and you are not asked again each time.\n\n"
      .. "Only the |cffffffffWhitelist|r protects an item.\n\nTurn Auto-Consume on?",
  button1 = "Yes, destroy my spare gear", button2 = CANCEL,
  -- Same gate as the tickbox. The popup can sit on screen for up to 60s, which is
  -- long enough for a whitelist batch to still be draining behind it.
  OnAccept = function()
    if wlSettling() then
      log("|cffff2020Whitelist is still being applied -- Auto-Consume NOT enabled. "
          .. "Wait for it to finish, then tick the box again.|r")
      return
    end
    send("ICAC:1:CONFIRM")
  end,
  timeout = 60, whileDead = 1, hideOnEscape = 1, showAlert = 1,
}

StaticPopupDialogs["MOONFORGE_RENDER_JUNK"] = {
  text = "|cffff2020This permanently destroys gear.|r\n\n"
      .. "Render |cffffffff%s|r |cffffffffgrey and white|r weapon and armour piece(s) out of your "
      .. "|cffffffffVault|r into |cffffffff%s|r souls?\n\n"
      .. "The server sweeps grey AND white together -- there is no narrower door. "
      .. "Green and better gear is |cffffffffnot|r touched. Quest turn-ins, your Whitelist "
      .. "and exact copies of worn gear are all held back.\n\nThis cannot be undone.",
  button1 = "Yes, render them down", button2 = CANCEL,
  OnAccept = function() send("ICVRENDER:CONFIRM") end,
  timeout = 60, whileDead = 1, hideOnEscape = 1, showAlert = 1,
}

-- One-shot per-rarity consume. The text is filled in from the server's own
-- forecast (pieces, souls, and which rarity and scope it armed) rather than from
-- what we asked for, so what the player reads is what the server will actually do.
StaticPopupDialogs["MOONFORGE_VCONSUME"] = {
  text = "%s",
  button1 = "Yes, render them down", button2 = CANCEL,
  OnAccept = function()
    -- ⚠ No arguments, and that is the design: the server acts on the arm it stored
    -- when it sent the forecast. A dialog left open from one button therefore
    -- cannot be answered against another button's rarity or scope.
    send("ICVCONSUME:CONFIRM")
  end,
  timeout = 60, whileDead = 1, hideOnEscape = 1, showAlert = 1,
}

StaticPopupDialogs["MOONFORGE_SOULBIND_ALL"] = {
  text = "Soulbind every exact duplicate of the gear you're wearing (from bags AND vault) onto it?\n\n"
      .. "The duplicates are consumed. This cannot be undone.",
  button1 = ACCEPT, button2 = CANCEL,
  OnAccept = function()
    -- Arm lives here, not on the button: the popup can sit on screen
    -- indefinitely and a second one can be raised behind it.
    if state.sbInflight then return end
    if (GetTime() or 0) < (state.sbReadyAt or 0) then return end
    state.sbInflight = true
    state.sbReadyAt  = (GetTime() or 0) + (state.sbCooldown or 30)
    send("ICSBALL")
    log("Soulbind Duplicates sent -- waiting on the server...")
    --[[ ⚠ EVERY IN-FLIGHT FLAG NEEDS A PLAIN TIMEOUT, not just a reply handler.
      ICSBALL costs 3 tokens and can be dropped outright by the server's throttle,
      in which case NOTHING ever arrives -- no ICBOUNDALL, no ICERR -- and a flag
      cleared only by a reply is a flag that is never cleared. 15s is well past the
      one query round trip this verb actually takes.                            ]]
    local armedAt = GetTime() or 0
    state.sbArmedAt = armedAt
    After(15, function()
      -- Only fire for the press that armed it: a later press supersedes this one.
      if state.sbInflight and state.sbArmedAt == armedAt then
        state.sbInflight = false
        log("|cffffd100No answer from the server on Soulbind Duplicates -- it was most "
            .. "likely dropped. Try again in a moment.|r")
      end
    end)
  end,
  timeout = 0, whileDead = 1, hideOnEscape = 1, showAlert = 1,
}

--========================== whitelist search pacing =======================
-- Copied deliberately from the official addon [DE-04]: ICISEARCH is a
-- leading-wildcard LIKE over the whole item_template ON THE MAIN WORLD
-- THREAD. Debounce, one in flight, timestamp (not boolean) timeout.
local WL_SEARCH_DEBOUNCE = 0.30
local WL_SEARCH_TIMEOUT  = 3.0
local wlSearch = { pending = nil, inflight = nil, sentAt = 0, last = nil, wait = nil }

local function wlSearchFlush()
  local q = wlSearch.pending
  if not q or #q < 2 then return end
  if wlSearch.inflight then
    local age = (GetTime() or 0) - (wlSearch.sentAt or 0)
    if age < WL_SEARCH_TIMEOUT then return end
    wlSearch.inflight = nil
  end
  if q == wlSearch.last then wlSearch.pending = nil; return end
  wlSearch.pending, wlSearch.last = nil, q
  wlSearch.inflight, wlSearch.sentAt = q, GetTime() or 0
  send("ICISEARCH:" .. q)
end

local function wlSearchType(text)
  text = trim(text)
  if #text < 2 then
    wlSearch.pending = nil
    if WLADD and WLADD.hint then WLADD.hint:SetText("Type at least 2 letters to search all items.") end
    return
  end
  wlSearch.pending = text
  if WLADD and WLADD.hint then WLADD.hint:SetText("Searching...") end
  wlSearch.wait = (GetTime() or 0) + WL_SEARCH_DEBOUNCE
  After(WL_SEARCH_DEBOUNCE, function()
    if wlSearch.wait and (GetTime() or 0) >= wlSearch.wait then
      wlSearch.wait = nil
      wlSearchFlush()
    end
  end)
end

local function wlSearchAnswered()
  wlSearch.inflight = nil
  if WLADD and WLADD.hint then
    WLADD.hint:SetText(wlSearch.pending and "Searching..."
      or (#state.wlSuggest == 0 and "No items match that name." or ""))
  end
  if wlSearch.pending then wlSearchFlush() end
end

--========================== bulk whitelist actions ========================
local function whitelistEquipped()
  local added = 0
  forEachEquipped(function(_, link)
    local nm = linkName(link)
    if nm and wlAdd(nm) then added = added + 1 end
  end)
  flushQueueThen("ICWLIST")
  log(added > 0 and ("Whitelisting " .. added .. " equipped item name(s)...")
                or  "All equipped item names are already whitelisted.")
end

local function whitelistSets()
  local added = 0
  local function tryTip(nm)
    if nm and tooltipHasSetLine() and wlAdd(nm) then added = added + 1 end
  end
  forEachEquipped(function(slot, link)
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    scanTip:SetInventoryItem("player", slot)
    tryTip(linkName(link))
  end)
  forEachBagItem(function(bag, slot, link)
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    scanTip:SetBagItem(bag, slot)
    tryTip(linkName(link))
  end)
  scanTip:Hide()
  flushQueueThen("ICWLIST")
  log(added > 0 and ("Whitelisting " .. added .. " set item name(s)...")
                or  "No new set items found on you or in your bags.")
end

local function whitelistProcs()
  -- Arm, snapshot an entry->name map from what we can see client-side, then
  -- ask the server which carried items actually hold procs.
  local p = state.procWL
  -- ⚠ ICEXSRC is COST_HEAVY -- 6 tokens of a 60-token bucket that refills at 6/s.
  -- Ten impatient clicks is the entire burst, and every other addon on the account
  -- is then starved for ten seconds. One sweep at a time.
  if p.pending and ((GetTime() or 0) - (p.since or 0)) < 10 then
    log("Still waiting on the last proc sweep -- give it a moment.")
    return
  end
  p.pending, p.since = true, GetTime() or 0
  p.entries, p.entryName = {}, {}
  forEachEquipped(function(_, link)
    local e, nm = linkEntry(link), linkName(link)
    if e and nm then p.entryName[e] = nm end
  end)
  forEachBagItem(function(_, _, link)
    local e, nm = linkEntry(link), linkName(link)
    if e and nm then p.entryName[e] = nm end
  end)
  send("ICEXSRC")
  log("Asking the server which of your items carry procs...")
end

local function whitelistProcsCommit()
  local p = state.procWL
  p.pending = false
  local added = 0
  for entry in pairs(p.entries) do
    local nm = p.entryName[entry] or GetItemInfo(entry)
    if nm and wlAdd(nm) then added = added + 1 end
  end
  p.entries = {}
  flushQueueThen("ICWLIST")
  log(added > 0 and ("Whitelisting " .. added .. " proc item name(s)...")
                or  "No new proc-carrying items to whitelist.")
end

--========================== UI: shared widgets ============================
local BACKDROP_WIN = {
  bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
  tile = true, tileSize = 32, edgeSize = 32,
  insets = { left = 8, right = 8, top = 8, bottom = 8 },
}
local BACKDROP_BOX = {
  bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 12,
  insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

local function saveSize(f, name)
  if not db then return end
  db.size = db.size or {}
  db.size[name] = { w = f:GetWidth(), h = f:GetHeight() }
end

-- makeWindow(name, w, h, title [, minW, minH, maxW, maxH])
-- Passing the min/max sizes makes the window resizable with a corner grip;
-- size is persisted per window. onResize (set by the caller as f.OnResize)
-- runs while dragging so contents can relayout live.
local function makeWindow(name, w, h, title, minW, minH, maxW, maxH)
  local f = CreateFrame("Frame", name, UIParent)
  f:SetSize(w, h)
  f:SetFrameStrata("DIALOG")
  f:SetBackdrop(BACKDROP_WIN)
  f:SetBackdropColor(0.06, 0.06, 0.10, 0.96)
  f:SetMovable(true); f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    if db then
      local point, _, _, x, y = self:GetPoint()
      db.pos = db.pos or {}
      db.pos[name] = { point = point, x = x, y = y }
    end
  end)
  f:SetClampedToScreen(true)
  f:Hide()

  local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  t:SetPoint("TOP", 0, -14)
  t:SetText(title)
  f.title = t

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -6, -6)

  if minW then
    f:SetResizable(true)
    f:SetMinResize(minW, minH or minW)
    f:SetMaxResize(maxW or 900, maxH or 800)
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -5, 5)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function()
      f:StartSizing("BOTTOMRIGHT")
      f.sizing = true
    end)
    grip:SetScript("OnMouseUp", function()
      f:StopMovingOrSizing()
      f.sizing = nil
      saveSize(f, name)
      if f.OnResize then f:OnResize() end
    end)
    f:SetScript("OnSizeChanged", function(self)
      if self.OnResize then self:OnResize() end
    end)
  end

  tinsert(UISpecialFrames, name)   -- Escape closes it
  return f
end

local function restorePos(f, name, defX, defY)
  f:ClearAllPoints()
  local p = db and db.pos and db.pos[name]
  if p then f:SetPoint(p.point or "CENTER", UIParent, p.point or "CENTER", p.x or 0, p.y or 0)
  else f:SetPoint("CENTER", defX or 0, defY or 0) end
  local s = db and db.size and db.size[name]
  if s and s.w and f:IsResizable() then
    f:SetSize(s.w, s.h)
  end
  if f.OnResize then f:OnResize() end
end

local function makeButton(parent, label, w, h)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, h)
  b:SetText(label)
  return b
end

-- Flat coloured button (the stock template is baked red and tints poorly).
-- Carries SetText/GetFontString shims so callers can treat it like a
-- template button. `outline` puts a dark outline on the label font -- pure
-- white outlined text stays crisp on saturated backgrounds where plain
-- text fogs.
local function makeColorButton(parent, label, w, h, bg, txt, outline, bg2)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(w, h)
  b.bg = bg
  b:SetBackdrop(BACKDROP_BOX)
  if bg2 then
    -- Split background: bg on the left half, bg2 on the right, one border.
    b:SetBackdropColor(0, 0, 0, 0)
    local lh = b:CreateTexture(nil, "BACKGROUND")
    lh:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    lh:SetPoint("TOPLEFT", 3, -3); lh:SetPoint("BOTTOMLEFT", 3, 3)
    lh:SetPoint("RIGHT", b, "CENTER", 0, 0)
    lh:SetVertexColor(bg[1], bg[2], bg[3], 0.92)
    local rh = b:CreateTexture(nil, "BACKGROUND")
    rh:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    rh:SetPoint("TOPRIGHT", -3, -3); rh:SetPoint("BOTTOMRIGHT", -3, 3)
    rh:SetPoint("LEFT", b, "CENTER", 0, 0)
    rh:SetVertexColor(bg2[1], bg2[2], bg2[3], 0.92)
    b:SetBackdropBorderColor(
      (bg[1] + bg2[1]) * 0.28 + 0.18,
      (bg[2] + bg2[2]) * 0.28 + 0.18,
      (bg[3] + bg2[3]) * 0.28 + 0.18)
  else
    b:SetBackdropColor(bg[1], bg[2], bg[3], 0.92)
    b:SetBackdropBorderColor(bg[1] * 0.55 + 0.18, bg[2] * 0.55 + 0.18, bg[3] * 0.55 + 0.18)
  end
  local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  if outline then
    local path, size = GameFontHighlight:GetFont()
    fs:SetFont(path, size, "OUTLINE")
  end
  -- ⚠ THE FOG WAS THE FONT'S BUILT-IN DROP SHADOW. Every stock font object
  -- carries a black shadow at (1,-1); on a white button it doubles the black
  -- glyph edges into a blur, and on a black button it smears under the white
  -- outline. Coloured buttons draw their own contrast -- no shadow.
  fs:SetShadowColor(0, 0, 0, 0)
  fs:SetShadowOffset(0, 0)
  fs:SetPoint("CENTER")
  fs:SetTextColor(txt[1], txt[2], txt[3])
  b.text = fs
  b.SetText = function(self, t) self.text:SetText(t) end
  b.GetFontString = function(self) return self.text end
  b:SetText(label)
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
  hl:SetVertexColor(1, 1, 1, 0.18)
  hl:SetBlendMode("ADD")
  b:SetScript("OnMouseDown", function(self) self.text:SetPoint("CENTER", 1, -1) end)
  b:SetScript("OnMouseUp", function(self) self.text:SetPoint("CENTER", 0, 0) end)
  b:SetScript("OnDisable", function(self) self:SetAlpha(0.55) end)
  b:SetScript("OnEnable", function(self) self:SetAlpha(1) end)
  return b
end

--[[ ★ THE RARITY BUTTONS ARE NO LONGER LOCKED (2026-09-04).
  They were greyed out with "the server protocol has no one-shot consume for this
  rarity yet -- needs a server-side verb; ask the admin". The verb exists, and it is
  character for character the one MOONFORGE_DEVELOPER.md §8 asked for:

      ICVCONSUME:<quality>:<scope>   -> ICVCFORECAST:<q>:<s>:<pieces>:<souls>:<arm>
      ICVCONSUME:CONFIRM            -> ICVCDONE:<pieces>:<souls>

  quality is 2 / 3 / 4 / 9(ALL); scope 0 = Vault, 1 = Vault AND bags. Grey is
  deliberately NOT reachable here -- it stays Consume Junk's, because ICVRENDER is
  the only door that prices POOR. "All" therefore means white through epic, exactly
  the set the standing Auto-Consume eats, and never legendaries.

  ⚠ lockButton is kept, not deleted. It is the right pattern for the next verb that
    genuinely does not exist yet, and it documents why a locked button must not be
    Disable()d.
]]
-- A button that exists but is waiting on a server-side verb.
-- ⚠ NOT Disable()d: a disabled Button on 3.3.5a receives no mouse events, so
-- its explanatory tooltip would never show. The gate on OnClick is what makes
-- it BE unavailable (same pattern as the official addon's locked sack row).
local LOCK_WHY = "This one still needs a server-side verb; ask the admin."
local function lockButton(b, why)
  -- Dim the BACKDROP, not the button: SetAlpha on the whole frame fogged the
  -- label along with it (v1.2 complaint). The text stays at full crispness;
  -- the muted background + tooltip carry the "locked" reading.
  if b.bg then
    b:SetBackdropColor(b.bg[1] * 0.7, b.bg[2] * 0.7, b.bg[3] * 0.7, 0.80)
  else
    b:SetAlpha(0.7)
  end
  b:SetScript("OnClick", function()
    log("That consume needs a server-side verb first -- see the tooltip.")
  end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Not available yet")
    GameTooltip:AddLine(why, 1, 0.82, 0, true)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

--========================== UI: main window ===============================
local function BuildUI()
  if UI then return UI end
  local W, H = 470, 468
  local f = makeWindow("MoonforgeFrame", W, H, "|cffb8ccffMoon|r|cfff0e6c8forge|r",
    470, 468, 820, 700)
  UI = f

  local ver = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  ver:SetPoint("TOP", f.title, "BOTTOM", 0, -1)
  ver:SetText("v" .. VERSION)

  -- ---- forge header ------------------------------------------------------
  local hdr = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  hdr:SetPoint("TOPLEFT", 18, -44)
  hdr:SetText("|cff9f8fffThe Soulforge|r")

  local lvl = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  lvl:SetPoint("TOPRIGHT", -18, -42)
  f.level = lvl

  -- Slim moonlight bar.
  local bar = CreateFrame("StatusBar", nil, f)
  bar:SetPoint("TOPLEFT", 18, -64)
  bar:SetPoint("TOPRIGHT", -18, -64)
  bar:SetHeight(13)
  bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  bar:SetStatusBarColor(1, 1, 1)
  bar:SetMinMaxValues(0, 100)
  local barBG = bar:CreateTexture(nil, "BACKGROUND")
  barBG:SetAllPoints()
  barBG:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
  barBG:SetVertexColor(0.03, 0.03, 0.10, 0.70)
  local barEdge = CreateFrame("Frame", nil, bar)
  barEdge:SetPoint("TOPLEFT", -2, 2); barEdge:SetPoint("BOTTOMRIGHT", 2, -2)
  barEdge:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10 })
  barEdge:SetBackdropBorderColor(0.55, 0.62, 0.88)
  local spark = bar:CreateTexture(nil, "OVERLAY")
  spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
  spark:SetBlendMode("ADD"); spark:SetSize(18, 30)
  spark:SetVertexColor(0.85, 0.92, 1.00)
  local barText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  barText:SetPoint("CENTER")

  -- Ding glow: its OWN overlay frame. v1.1 flashed the bar itself and
  -- UIFrameFlash(showWhenDone=false) HIDES its frame when the flash ends --
  -- that is the "bar disappeared" bug. The glow can vanish; the bar cannot.
  local glow = CreateFrame("Frame", nil, bar)
  glow:SetPoint("TOPLEFT", -3, 3); glow:SetPoint("BOTTOMRIGHT", 3, -3)
  local glowTex = glow:CreateTexture(nil, "OVERLAY")
  glowTex:SetAllPoints()
  glowTex:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
  glowTex:SetVertexColor(0.80, 0.88, 1.00, 0.85)
  glowTex:SetBlendMode("ADD")
  glow:Hide()
  f.bar, f.spark, f.barText, f.glow = bar, spark, barText, glow

  local extract = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  extract:SetPoint("TOPLEFT", 18, -84)
  f.extract = extract

  -- ---- auto-consume ------------------------------------------------------
  local ac = CreateFrame("CheckButton", "MoonforgeAC", f, "InterfaceOptionsCheckButtonTemplate")
  ac:SetPoint("TOPLEFT", 14, -102)
  _G[ac:GetName() .. "Text"]:SetText("Auto-Consume for Souls and Transmogs")
  -- Ticking only ASKS: the server arms and replies ICACWARN; nothing is on
  -- until the popup is accepted. Unticking is immediate. The box is put
  -- straight back to the server's value so it never shows a state the
  -- server hasn't agreed to -- the ICSF push is the authority.
  ac:SetScript("OnClick", function(self)
    local want = self:GetChecked() and 1 or 0
    self:SetChecked(state.sf.autoconsume)
    --[[ ★★★ THE GATE. This addon's own manual says "whitelist first, enable
      second", and the whitelist is applied over many seconds at the rate the
      server will accept. Arming Auto-Consume while those adds are still in
      flight turns a queue that has not finished into gear that no longer
      exists -- the Vault half of the sweep has NO grace period at all.
      Turning it OFF is always allowed; only arming waits.                    ]]
    if want == 1 and wlSettling() then
      log(string.format("|cffff2020Whitelist is still being applied -- %d name(s) have not "
                        .. "reached the server yet. Wait for it to finish.|r", #state.queue))
      return
    end
    send("ICAC:" .. want)
  end)
  f.acCheck = ac

  -- ---- whitelist box -----------------------------------------------------
  local wbox = CreateFrame("Frame", nil, f)
  wbox:SetPoint("TOPLEFT", 14, -132)
  wbox:SetPoint("TOPRIGHT", -14, -132)
  wbox:SetHeight(92)
  wbox:SetBackdrop(BACKDROP_BOX)
  wbox:SetBackdropColor(0.10, 0.12, 0.20, 0.65)
  wbox:SetBackdropBorderColor(0.45, 0.55, 0.85)
  local wlbl = wbox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  wlbl:SetPoint("TOPLEFT", 10, -8)
  wlbl:SetText("|cff40c0f0Whitelist|r  |cff888888-- protected from all consuming|r")

  local bw, bh, gap = 138, 22, 6
  local wl1 = makeButton(wbox, "Whitelist Equipped", bw, bh)
  wl1:SetPoint("TOPLEFT", 10, -28)
  wl1:SetScript("OnClick", whitelistEquipped)
  local wl2 = makeButton(wbox, "Whitelist Sets", bw, bh)
  wl2:SetPoint("LEFT", wl1, "RIGHT", gap, 0)
  wl2:SetScript("OnClick", whitelistSets)
  local wl3 = makeButton(wbox, "Whitelist Procs", bw, bh)
  wl3:SetPoint("LEFT", wl2, "RIGHT", gap, 0)
  wl3:SetScript("OnClick", whitelistProcs)
  local wl4 = makeButton(wbox, "Whitelist Item...", bw, bh)
  wl4:SetPoint("TOPLEFT", wl1, "BOTTOMLEFT", 0, -6)
  wl4:SetScript("OnClick", function()
    if WLADD:IsShown() then WLADD:Hide() else WLADD:Show(); WLADD.box:SetFocus() end
  end)
  local wl5 = makeButton(wbox, "The List...", bw, bh)
  wl5:SetPoint("LEFT", wl4, "RIGHT", gap, 0)
  wl5:SetScript("OnClick", function()
    if WLLIST:IsShown() then WLLIST:Hide()
    else WLLIST:Show(); WLLIST:Refresh(); send("ICWLIST") end
  end)
  local wlcount = wbox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  wlcount:SetPoint("LEFT", wl5, "RIGHT", 10, 0)
  f.wlCount = wlcount

  -- Tooltips for the bulk buttons: name their scope plainly.
  local function tip(btn, title, body)
    btn:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine(title)
      GameTooltip:AddLine(body, 1, 1, 1, true)
      GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  end
  tip(wl1, "Whitelist Equipped", "Adds the NAME of every item you are wearing. The whitelist matches by name, so spare copies of worn gear are protected too.")
  tip(wl2, "Whitelist Sets", "Scans your worn gear and bags and adds every item that belongs to an item set (has a set bonus).")
  tip(wl3, "Whitelist Procs", "Asks the server which of your carried and worn items hold an extractable proc, then whitelists those item names.")
  tip(wl4, "Whitelist Item", "Search all items by name and add one at a time.")
  tip(wl5, "The List", "Everything currently whitelisted; click the x to remove an entry.")

  -- ---- consume box -------------------------------------------------------
  local cbox = CreateFrame("Frame", nil, f)
  cbox:SetPoint("TOPLEFT", 14, -232)
  cbox:SetPoint("TOPRIGHT", -14, -232)
  cbox:SetHeight(122)
  cbox:SetBackdrop(BACKDROP_BOX)
  cbox:SetBackdropColor(0.16, 0.10, 0.10, 0.65)
  cbox:SetBackdropBorderColor(0.85, 0.45, 0.35)
  local clbl = cbox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  clbl:SetPoint("TOPLEFT", 10, -8)
  clbl:SetText("|cffff6060Consume|r  |cff888888-- destroys gear from the Vault to feed the forge|r")

  local function consumeSweep()
    send("ICVRENDER")   -- server replies ICVR (forecast + arm); confirm follows
    log("Requesting the vault junk forecast...")
  end

  --[[ One-shot per-rarity consume. Sends the forecast; the server arms and replies
    ICVCFORECAST, and MOONFORGE_VCONSUME below is what actually confirms.

    ⚠ Same gate as Auto-Consume: nothing destructive is armed while a whitelist
      batch is still draining. The whitelist is what protects gear from this too,
      and a queue that has not finished is protection that does not exist yet.  ]]
  local function consumeRarity(quality, label)
    if wlSettling() then
      log(string.format("|cffff2020Whitelist is still being applied -- %d name(s) have not "
                        .. "reached the server yet. Wait for it to finish.|r", #state.queue))
      return
    end
    local p = state.vc
    if p.pending and ((GetTime() or 0) - (p.since or 0)) < 10 then
      log("Still waiting on the last forecast -- give it a moment.")
      return
    end
    local scope = (f.invCheck and f.invCheck:GetChecked()) and 1 or 0
    local armedAt = GetTime() or 0
    p.pending, p.since, p.label = true, armedAt, label
    send("ICVCONSUME:" .. quality .. ":" .. scope)
    log("Requesting the " .. label .. " forecast (" ..
        (scope == 1 and "Vault and bags" or "Vault only") .. ")...")
    -- A plain timeout: ICVCONSUME costs 3 tokens and can be dropped outright, and
    -- a pending flag cleared only by a reply is a flag that is never cleared.
    -- Compared against the arming timestamp so a newer press supersedes this one.
    After(12, function()
      if p.pending and p.since == armedAt then
        p.pending = false
        log("|cffffd100No forecast came back -- the request was most likely dropped. "
            .. "Try again in a moment.|r")
      end
    end)
  end
  -- Rarity colours (3.3.5a item quality palette). Bright backgrounds carry
  -- dark text, dark backgrounds carry white -- contrast picked per button.
  -- One button for the one server sweep: Consume Junk fires the grey+white
  -- Vault render (that is the whole sweep -- there was never a separate
  -- white-only door, so two buttons were one door wearing two labels).
  -- Split grey/white background says exactly what it eats.
  local cJunk = makeColorButton(cbox, "Consume Junk", bw, bh,
    { 0.62, 0.62, 0.62 }, { 0, 0, 0 }, false, { 0.92, 0.92, 0.92 })
  cJunk:SetPoint("TOPLEFT", 10, -28); cJunk:SetScript("OnClick", consumeSweep)
  local cG = makeColorButton(cbox, "Consume Green",  bw, bh, { 0.12, 0.75, 0.10 }, { 1, 1, 1 }, true)
  cG:SetPoint("LEFT", cJunk, "RIGHT", gap, 0)
  local cB = makeColorButton(cbox, "Consume Blue",   bw, bh, { 0.00, 0.44, 0.87 }, { 1, 1, 1 }, true)
  cB:SetPoint("LEFT", cG, "RIGHT", gap, 0)
  local cP = makeColorButton(cbox, "Consume Purple", bw, bh, { 0.64, 0.21, 0.93 }, { 1, 1, 1 }, true)
  cP:SetPoint("TOPLEFT", cJunk, "BOTTOMLEFT", 0, -6)
  local cAll = makeColorButton(cbox,
    "Consume All |TInterface\\TargetingFrame\\UI-TargetingFrame-Skull:14:14:0:-1|t",
    bw, bh, { 0.05, 0.05, 0.05 }, { 1, 1, 1 }, true)
  cAll:SetPoint("LEFT", cP, "RIGHT", gap, 0)
  -- 2 = uncommon, 3 = rare, 4 = epic, 9 = every rarity SoulValue prices (white
  -- through epic; never grey, never legendary).
  cG:SetScript("OnClick",   function() consumeRarity(2, "Consume Green")  end)
  cB:SetScript("OnClick",   function() consumeRarity(3, "Consume Blue")   end)
  cP:SetScript("OnClick",   function() consumeRarity(4, "Consume Purple") end)
  cAll:SetScript("OnClick", function() consumeRarity(9, "Consume All")    end)
  tip(cG, "Consume Green", "One-shot sweep for GREEN (uncommon) weapons and armour. The server forecasts what would go and you confirm before anything is destroyed. Whitelisted items, quest turn-ins, soulbound gear in your bags and exact copies of what you are wearing are all held back.")
  tip(cB, "Consume Blue", "One-shot sweep for BLUE (rare) weapons and armour. Same forecast-then-confirm, same protections.")
  tip(cP, "Consume Purple", "One-shot sweep for PURPLE (epic) weapons and armour. Same forecast-then-confirm, same protections. This is the one to be careful with -- read the forecast.")
  tip(cAll, "Consume All", "|cffff2020Every rarity the standing Auto-Consume eats, in one press: white, green, blue AND purple.|r Greys are not included (that is Consume Junk) and legendaries are never touched. Same forecast-then-confirm, same protections.")
  tip(cJunk, "Consume Junk", "One-shot sweep of your Vault: every GREY and WHITE weapon and armour piece is rendered into souls. You will see the server's forecast and confirm before anything is destroyed. Whitelisted items, quest turn-ins and copies of worn gear are held back.")

  local inv = CreateFrame("CheckButton", "MoonforgeInvToo", cbox, "InterfaceOptionsCheckButtonTemplate")
  inv:SetPoint("TOPLEFT", 6, -84)
  _G[inv:GetName() .. "Text"]:SetText("Also consume from inventory")
  -- ⚠ Unlocked 2026-09-04. This was greyed out on the belief that "the one-shot
  -- sweep is Vault-only server-side"; it is not -- CONSUME_SCOPE_BAGS = 1 means
  -- Vault AND bags and the server accepts it. It is a scope on the rarity buttons
  -- only: Consume Junk (ICVRENDER) is a different verb and stays Vault-only.
  inv:SetScript("OnClick", function(self)
    log(self:GetChecked()
        and "|cffff2020Rarity sweeps will now take from your BAGS as well as the Vault.|r"
        or  "Rarity sweeps will take from the Vault only.")
  end)
  inv:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Also consume from inventory")
    GameTooltip:AddLine("Applies to the four rarity buttons above -- not to Consume Junk, "
      .. "which is a separate server door and is always Vault-only.\n\n"
      .. "|cffff2020Your bags are where the gear you are actually using lives.|r The same "
      .. "protections still hold (whitelist, quest turn-ins, soulbound items, exact copies "
      .. "of worn gear) and you still see a forecast first -- but read it.", 1, 0.82, 0, true)
    GameTooltip:Show()
  end)
  inv:SetScript("OnLeave", function() GameTooltip:Hide() end)
  f.invCheck = inv

  local rule = cbox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  rule:SetPoint("BOTTOMRIGHT", -10, 10)
  -- ⚠ This line used to read "Soulbound gear and copies of it are never consumed",
  -- and the second half was false. The server's protection is FindEquippedMatch:
  -- it holds back copies of what you are WEARING, and only those with an identical
  -- randomPropertyId. A soulbound piece sitting in your bags protects itself and
  -- nothing else, so a stockpile of duplicates kept for an off-set weapon is
  -- exactly what gets eaten. Say what the server actually does.
  rule:SetText("Soulbound gear in your bags is never consumed. Exact copies of what you are WEARING are held back -- copies of soulbound gear you are not wearing are NOT.")

  -- ---- Soulbind Duplicates (golden button) -------------------------------
  local sb = makeColorButton(f, "Soulbind Duplicates", 240, 26,
    { 1.00, 0.80, 0.10 }, { 0.28, 0.14, 0.02 })
  sb:SetPoint("TOP", cbox, "BOTTOM", 0, -14)
  sb:SetScript("OnClick", function()
    if state.sbInflight or (GetTime() or 0) < (state.sbReadyAt or 0) then return end
    StaticPopup_Show("MOONFORGE_SOULBIND_ALL")
  end)
  sb:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Soulbind Duplicates")
    GameTooltip:AddLine("Feeds every exact duplicate of gear you are wearing (bags and Vault) onto the worn copy, extracting the current rate of its stats and ramping its procs. 30s cooldown -- one press is heavy on the server.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  sb:SetScript("OnLeave", function() GameTooltip:Hide() end)
  f.sbBtn = sb

  -- Cooldown ticker on the button label.
  local cdAccum = 0
  f:SetScript("OnUpdate", function(_, elapsed)
    cdAccum = cdAccum + elapsed
    if cdAccum < 0.25 then return end
    cdAccum = 0
    local now = GetTime() or 0
    if state.sbInflight then
      sb:SetText("Soulbinding..."); sb:Disable()
    elseif now < (state.sbReadyAt or 0) then
      sb:SetText(string.format("Soulbind Duplicates (%ds)", math.ceil(state.sbReadyAt - now)))
      sb:Disable()
    else
      sb:SetText("Soulbind Duplicates"); sb:Enable()
    end
  end)

  -- ---- Soulbound Info (lower right) --------------------------------------
  local sbi = makeButton(f, "Soulbound Info", 118, 22)
  sbi:SetPoint("BOTTOMRIGHT", -24, 10)
  sbi:SetScript("OnClick", function()
    if SBINFO:IsShown() then SBINFO:Hide()
    else SBINFO:Show(); SBINFO:Refresh(); askInv() end
  end)
  tip(sbi, "Soulbound Info", "Which of your soulbound items have consumed duplicates, and how many each has absorbed.")

  -- ---- status line -------------------------------------------------------
  local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status:SetPoint("BOTTOMLEFT", 16, 14)
  status:SetPoint("BOTTOMRIGHT", -150, 14)
  status:SetJustifyH("LEFT")
  status:SetText("Ready.  /mf log shows the full log.")
  f.status = status

  -- ---- live relayout on resize -------------------------------------------
  -- The boxes stretch via their TOPRIGHT anchors; the three-across button
  -- rows recompute their widths from the box width.
  local threeAcross = { wl1, wl2, wl3, cJunk, cG, cB, cP, cAll }
  local twoish      = { wl4, wl5 }
  function f:OnResize()
    local boxW = wbox:GetWidth() or (self:GetWidth() - 28)
    local colW = math.floor((boxW - 20 - 2 * gap) / 3)
    if colW < 100 then colW = 100 end
    for _, b in ipairs(threeAcross) do b:SetWidth(colW) end
    for _, b in ipairs(twoish) do b:SetWidth(colW) end
  end

  -- ---- refreshers --------------------------------------------------------
  function f:RefreshForge()
    local sf = state.sf
    self.level:SetText("Level " .. sf.completions)
    self.bar:SetValue(sf.fill)
    local frac = sf.fill / 100
    local l, r = moonColours(frac)
    local tex = self.bar:GetStatusBarTexture()
    if tex and tex.SetGradientAlpha then
      tex:SetGradientAlpha("HORIZONTAL", l[1], l[2], l[3], 1, r[1], r[2], r[3], 1)
    else
      self.bar:SetStatusBarColor(r[1], r[2], r[3])
    end
    self.barText:SetText(string.format("%.1f%% to Level %d", sf.fill, sf.completions + 1))
    local w = self.bar:GetWidth() or 0
    self.spark:ClearAllPoints()
    self.spark:SetPoint("CENTER", self.bar, "LEFT", w * frac, 0)
    if sf.fill > 0 and sf.fill < 100 then self.spark:Show() else self.spark:Hide() end
    self.extract:SetText(string.format("|cffffd200Extraction:|r |cffffffff+%.2f%%|r of stats per soulbind", sf.mult))
    self.acCheck:SetChecked(sf.autoconsume)
  end

  function f:RefreshWhitelist()
    self.wlCount:SetText(#state.whitelist .. " protected")
  end

  function f:Ding()
    pcall(PlaySound, "LEVELUPSOUND")
    -- Flash the GLOW overlay, never the bar (see the note where it's built).
    if UIFrameFlash then UIFrameFlash(self.glow, 0.15, 0.45, 0.9, false, 0, 0) end
  end

  restorePos(f, "MoonforgeFrame", 0, 40)
  f:OnResize()
  return f
end

--========================== UI: Whitelist Item window =====================
local SUG_ROWS = 8
local function BuildWLAdd()
  if WLADD then return WLADD end
  local f = makeWindow("MoonforgeWLAdd", 360, 330, "Whitelist an item")
  WLADD = f

  local sub = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  sub:SetPoint("TOP", 0, -36)
  sub:SetWidth(320)
  sub:SetText("Items whose name contains one of these are never consumed.")

  local box = CreateFrame("EditBox", "MoonforgeWLAddBox", f, "InputBoxTemplate")
  box:SetSize(240, 20)
  box:SetPoint("TOPLEFT", 24, -62)
  box:SetAutoFocus(false)
  box:SetScript("OnTextChanged", function(self, user)
    if user then wlSearchType(self:GetText()) end
  end)
  box:SetScript("OnEnterPressed", function(self)
    local t = trim(self:GetText())
    if t ~= "" and wlAdd(t) then flushQueueThen("ICWLIST"); log("Whitelisted \"" .. t .. "\".") end
    self:SetText("")
    state.wlSuggest = {}
    if f.UpdateSuggest then f:UpdateSuggest() end
  end)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  f.box = box

  local add = makeButton(f, "Add", 60, 22)
  add:SetPoint("LEFT", box, "RIGHT", 8, 0)
  add:SetScript("OnClick", function()
    local t = trim(box:GetText())
    if t ~= "" and wlAdd(t) then flushQueueThen("ICWLIST"); log("Whitelisted \"" .. t .. "\".") end
    box:SetText("")
    state.wlSuggest = {}
    f:UpdateSuggest()
  end)

  local mh = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  mh:SetPoint("TOPLEFT", 24, -94)
  mh:SetText("|cff40c0f0Matching items|r  |cff888888(click to whitelist)|r")

  local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("TOP", 0, -140)
  hint:SetText("Type at least 2 letters to search all items.")
  f.hint = hint

  local rows = {}
  for i = 1, SUG_ROWS do
    local r = CreateFrame("Button", nil, f)
    r:SetSize(312, 22)
    r:SetPoint("TOPLEFT", 24, -110 - (i - 1) * 24)
    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(); hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight"); hl:SetBlendMode("ADD")
    local t = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t:SetPoint("LEFT", 4, 0); t:SetPoint("RIGHT", -4, 0); t:SetJustifyH("LEFT")
    r.text = t
    r:SetScript("OnClick", function(self)
      if self.iname and wlAdd(self.iname) then
        flushQueueThen("ICWLIST")
        log("Whitelisted \"" .. self.iname .. "\".")
      end
    end)
    r:Hide()
    rows[i] = r
  end

  function f:UpdateSuggest()
    for i = 1, SUG_ROWS do
      local nm = state.wlSuggest[i]
      local r = rows[i]
      if nm then
        r.iname = nm
        local onList = state.wlSet[nm:lower()]
        r.text:SetText(onList and ("|cff44dd44" .. nm .. "  (listed)|r") or nm)
        r:Show()
      else
        r.iname = nil
        r:Hide()
      end
    end
    if #state.wlSuggest > SUG_ROWS then
      self.hint:SetText("Showing " .. SUG_ROWS .. " of " .. #state.wlSuggest .. " -- keep typing to narrow.")
      self.hint:ClearAllPoints()
      self.hint:SetPoint("BOTTOM", 0, 18)
      self.hint:Show()
    elseif #state.wlSuggest == 0 then
      self.hint:ClearAllPoints()
      self.hint:SetPoint("TOP", 0, -140)
      self.hint:Show()
    else
      self.hint:Hide()
    end
  end

  f:SetScript("OnShow", function(self)
    wlSearch.pending, wlSearch.inflight, wlSearch.last = nil, nil, nil
    state.wlSuggest = {}
    self:UpdateSuggest()
    self.hint:SetText("Type at least 2 letters to search all items.")
  end)

  restorePos(f, "MoonforgeWLAdd", 260, 40)
  return f
end

--========================== UI: The List window ===========================
local LIST_MAX_ROWS, LIST_H = 30, 24
local function BuildWLList()
  if WLLIST then return WLLIST end
  local f = makeWindow("MoonforgeWLList", 360, 380, "The List",
    300, 240, 560, 740)
  WLLIST = f
  f.offset = 0

  local sub = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  sub:SetPoint("TOP", 0, -36)
  f.countText = sub

  local rows = {}
  for i = 1, LIST_MAX_ROWS do
    local r = CreateFrame("Frame", nil, f)
    r:SetHeight(LIST_H)
    r:SetPoint("TOPLEFT", 22, -56 - (i - 1) * (LIST_H + 2))
    r:SetPoint("RIGHT", f, "RIGHT", -22, 0)
    r:EnableMouse(true)
    -- Same anatomy as the Soulbound Info rows: icon, then title.
    local icon = r:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("LEFT", 0, 0)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    r.icon = icon
    local t = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    t:SetPoint("RIGHT", -26, 0)
    t:SetJustifyH("LEFT")
    r.text = t
    -- Hover: full item tooltip when the entry resolved to a real item
    -- (link cached at Refresh); otherwise say what the substring protects.
    r:SetScript("OnEnter", function(self)
      if not self.wlname then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      if self.link then
        GameTooltip:SetHyperlink(self.link)
      else
        GameTooltip:AddLine(titleCase(self.wlname), 1, 1, 1)
        GameTooltip:AddLine("Protects any item whose name contains this text.", 0.7, 0.7, 0.7, true)
      end
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local x = CreateFrame("Button", nil, r)
    x:SetSize(18, 18)
    x:SetPoint("RIGHT", -2, 0)
    x:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    x:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Down")
    x:SetScript("OnClick", function()
      if r.wlname then
        send("ICWLREM:" .. r.wlname)
        state.wlSet[r.wlname:lower()] = nil   -- optimistic; ICWLEND corrects
        send("ICWLIST")
        log("Removed \"" .. r.wlname .. "\" from the whitelist.")
      end
    end)
    r:Hide()
    rows[i] = r
  end

  local function visibleRows(self)
    local n = math.floor(((self:GetHeight() or 380) - 90) / (LIST_H + 2))
    if n < 1 then n = 1 end
    if n > LIST_MAX_ROWS then n = LIST_MAX_ROWS end
    return n
  end

  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(self, delta)
    local vis = visibleRows(self)
    local maxOff = math.max(0, #state.whitelist - vis)
    self.offset = math.max(0, math.min(maxOff, self.offset - delta * 3))
    self:Refresh()
  end)

  function f:Refresh()
    local n = #state.whitelist
    local vis = visibleRows(self)
    local maxOff = math.max(0, n - vis)
    if self.offset > maxOff then self.offset = maxOff end
    local carried = buildNameLinkMap()   -- one scan for the whole redraw
    for i = 1, LIST_MAX_ROWS do
      local r = rows[i]
      local nm = (i <= vis) and state.whitelist[self.offset + i] or nil
      if nm then
        r.wlname = nm
        -- Exact match against carried/worn gear first, then the item cache.
        local link = carried[nm:lower()]
        if not link then local _, l = GetItemInfo(nm); link = l end
        r.link = link
        if link then
          local realName, _, quality = GetItemInfo(link)
          local tex = select(10, GetItemInfo(link))
          r.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
          local c = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
          if c then
            r.text:SetText(string.format("|cff%02x%02x%02x%s|r",
              c.r * 255, c.g * 255, c.b * 255, realName or titleCase(nm)))
          else
            r.text:SetText(realName or titleCase(nm))
          end
        else
          -- A substring, not a resolvable item: parchment icon, plain title.
          r.icon:SetTexture("Interface\\Icons\\INV_Scroll_02")
          r.text:SetText(titleCase(nm))
        end
        r:Show()
      else
        r.wlname = nil
        r.link = nil
        r:Hide()
      end
    end
    if n == 0 then
      self.countText:SetText("Nothing whitelisted yet.")
    elseif n > vis then
      self.countText:SetText(n .. " item name(s) protected -- mouse wheel to scroll.")
    else
      self.countText:SetText(n .. " item name(s) protected.")
    end
  end

  function f:OnResize() self:Refresh() end

  restorePos(f, "MoonforgeWLList", -260, 40)
  return f
end

--========================== UI: Soulbound Info window =====================
local SBI_MAX_ROWS, SBI_H = 30, 24
local function BuildSBInfo()
  if SBINFO then return SBINFO end
  local f = makeWindow("MoonforgeSBInfo", 400, 380, "Soulbound Info",
    340, 260, 600, 740)
  SBINFO = f
  f.offset = 0

  local sub = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  sub:SetPoint("TOP", 0, -36)
  f.countText = sub

  local rows = {}
  for i = 1, SBI_MAX_ROWS do
    local r = CreateFrame("Frame", nil, f)
    r:SetHeight(SBI_H)
    r:SetPoint("TOPLEFT", 22, -56 - (i - 1) * (SBI_H + 2))
    r:SetPoint("RIGHT", f, "RIGHT", -22, 0)
    r:EnableMouse(true)
    local icon = r:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("LEFT", 0, 0)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    r.icon = icon
    local t = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    t:SetPoint("RIGHT", -120, 0)
    t:SetJustifyH("LEFT")
    r.text = t
    local c = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    c:SetPoint("RIGHT", -2, 0)
    c:SetJustifyH("RIGHT")
    r.count = c
    r:SetScript("OnEnter", function(self)
      if not self.link then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetHyperlink(self.link)
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r:Hide()
    rows[i] = r
  end

  local function visibleRows(self)
    local n = math.floor(((self:GetHeight() or 380) - 90) / (SBI_H + 2))
    if n < 1 then n = 1 end
    if n > SBI_MAX_ROWS then n = SBI_MAX_ROWS end
    return n
  end

  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(self, delta)
    local vis = visibleRows(self)
    local maxOff = math.max(0, #(self.sorted or {}) - vis)
    self.offset = math.max(0, math.min(maxOff, self.offset - delta * 3))
    self:Layout()
  end)

  -- Rebuild the sorted view from state.sbi.items. Items with zero absorbed
  -- duplicates are filtered out; the list is duplicates-desc, then name.
  function f:Refresh()
    local out = {}
    local items = state.sbi.items
    if items then
      for key, d in pairs(items) do
        if (d.vest or 0) > 0 then
          local link = resolveKeyToLink(key)
          local nm = link and linkName(link) or key
          table.insert(out, { key = key, link = link, name = nm,
                              vest = d.vest, mult = d.mult or 100 })
        end
      end
      table.sort(out, function(a, b)
        if a.vest ~= b.vest then return a.vest > b.vest end
        return (a.name or "") < (b.name or "")
      end)
    end
    self.sorted = out
    self:Layout()
  end

  function f:Layout()
    local out = self.sorted or {}
    local vis = visibleRows(self)
    local maxOff = math.max(0, #out - vis)
    if self.offset > maxOff then self.offset = maxOff end
    for i = 1, SBI_MAX_ROWS do
      local r = rows[i]
      local d = (i <= vis) and out[self.offset + i] or nil
      if d then
        r.link = d.link
        local tex = d.link and (select(10, GetItemInfo(d.link)))
        r.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
        r.text:SetText(d.name or "?")
        r.count:SetText(string.format("|cffffd200%s|r duplicates  |cff888888(+%.2f%% each)|r",
          groupDigits(d.vest), (d.mult or 100) / 100))
        r:Show()
      else
        r.link = nil
        r:Hide()
      end
    end
    if not state.sbi.items then
      -- ⚠ NEVER A PERMANENT "loading". ICINV is COST_HEAVY (6 tokens) and can be
      -- dropped outright, in which case no ICINVEND ever arrives and this panel
      -- would read "Asking the server..." until /reload. sbi.askedAt lets it say
      -- what actually happened instead.
      if state.sbi.askedAt and ((GetTime() or 0) - state.sbi.askedAt) > 8 then
        self.countText:SetText("|cffffd100No answer from the server -- the request was most "
                               .. "likely dropped. Close and reopen this window.|r")
      else
        self.countText:SetText("Asking the server...")
      end
    elseif #out == 0 then
      self.countText:SetText("No soulbound item has absorbed a duplicate yet.")
    elseif #out > vis then
      self.countText:SetText(#out .. " item(s) have absorbed duplicates -- mouse wheel to scroll.")
    else
      self.countText:SetText(#out .. " item(s) have absorbed duplicates.")
    end
  end

  function f:OnResize() self:Layout() end

  restorePos(f, "MoonforgeSBInfo", 260, -20)
  return f
end

--========================== UI: log window ================================
local function BuildLog()
  if LOGWIN then return LOGWIN end
  local f = makeWindow("MoonforgeLog", 460, 320, "Moonforge log")
  LOGWIN = f

  local scroll = CreateFrame("ScrollFrame", "MoonforgeLogScroll", f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 16, -40)
  scroll:SetPoint("BOTTOMRIGHT", -34, 16)
  local eb = CreateFrame("EditBox", "MoonforgeLogEdit", scroll)
  eb:SetMultiLine(true)
  eb:SetFontObject(GameFontHighlightSmall)
  eb:SetWidth(400)
  eb:SetAutoFocus(false)
  eb:EnableMouse(true)
  eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  scroll:SetScrollChild(eb)
  f.edit = eb

  function f:Refresh()
    self.edit:SetText(table.concat(logLines, "\n"))
    self.edit:ClearFocus()
    After(0, function()
      local range = scroll:GetVerticalScrollRange() or 0
      scroll:SetVerticalScroll(range)
    end)
  end
  f:SetScript("OnShow", function(self) self:Refresh() end)

  restorePos(f, "MoonforgeLog", 0, -120)
  return f
end

--========================== minimap button ================================
-- Standard 3.3.5a ring button: position stored as an angle (degrees) in
-- db.minimap.pos, draggable around the minimap edge.
local function mmSetPosition()
  if not mmBtn then return end
  local angle = math.rad((db and db.minimap and db.minimap.pos) or 220)
  mmBtn:ClearAllPoints()
  mmBtn:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(angle), 80 * math.sin(angle))
end

local function BuildMinimapButton()
  if mmBtn then return mmBtn end
  local b = CreateFrame("Button", "MoonforgeMinimapButton", Minimap)
  mmBtn = b
  b:SetSize(31, 31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local overlay = b:CreateTexture(nil, "OVERLAY")
  overlay:SetSize(53, 53)
  overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  overlay:SetPoint("TOPLEFT")

  local icon = b:CreateTexture(nil, "BACKGROUND")
  icon:SetSize(20, 20)
  icon:SetTexture("Interface\\Icons\\Spell_Nature_StarFall")
  icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
  icon:SetPoint("TOPLEFT", 7, -5)

  local function drag(self)
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    cx, cy = cx / scale, cy / scale
    db.minimap = db.minimap or {}
    db.minimap.pos = math.deg(math.atan2(cy - my, cx - mx))
    mmSetPosition()
  end
  b:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", drag)
  end)
  b:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
  end)

  b:SetScript("OnClick", function(_, button)
    if button == "RightButton" then
      if optPanel then
        InterfaceOptionsFrame_OpenToCategory(optPanel)
        InterfaceOptionsFrame_OpenToCategory(optPanel)   -- classic first-call quirk
      end
    else
      openMain()
    end
  end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("|cffb8ccffMoon|r|cfff0e6c8forge|r v" .. VERSION)
    GameTooltip:AddLine("Left-click: open Moonforge", 1, 1, 1)
    GameTooltip:AddLine("Right-click: options", 1, 1, 1)
    GameTooltip:AddLine("Drag: move this button", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)

  mmSetPosition()
  return b
end

local function mmApplyVisibility()
  BuildMinimapButton()
  if db and db.minimap and db.minimap.hide then mmBtn:Hide() else mmBtn:Show() end
end

--========================== options panel =================================
-- Built after ADDON_LOADED (never file scope), content kept inside ~390x390.
local function BuildOptions()
  if optPanel then return optPanel end
  local p = CreateFrame("Frame", "MoonforgeOptions", UIParent)
  optPanel = p
  p.name = "Moonforge"

  local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText("|cffb8ccffMoon|r|cfff0e6c8forge|r  |cff888888v" .. VERSION .. "|r")

  local sub = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
  sub:SetText("The Soulforge, reforged.  Slash commands: /mf, /mf log, /mf debug, /mf options")

  local mm = CreateFrame("CheckButton", "MoonforgeOptMinimap", p, "InterfaceOptionsCheckButtonTemplate")
  mm:SetPoint("TOPLEFT", 14, -64)
  _G[mm:GetName() .. "Text"]:SetText("Show minimap button")
  mm:SetScript("OnClick", function(self)
    db.minimap = db.minimap or {}
    db.minimap.hide = not self:GetChecked() and true or nil
    mmApplyVisibility()
  end)
  p.mmCheck = mm

  local dbgC = CreateFrame("CheckButton", "MoonforgeOptDebug", p, "InterfaceOptionsCheckButtonTemplate")
  dbgC:SetPoint("TOPLEFT", 14, -92)
  _G[dbgC:GetName() .. "Text"]:SetText("Wire debug logging (view with /mf log)")
  dbgC:SetScript("OnClick", function(self)
    debugWire = self:GetChecked() and true or false
    log("Wire debug " .. (debugWire and "ON" or "OFF") .. ".")
  end)
  p.dbgCheck = dbgC

  local open = makeButton(p, "Open Moonforge", 150, 22)
  open:SetPoint("TOPLEFT", 18, -132)
  open:SetScript("OnClick", function() openMain() end)

  local logB = makeButton(p, "Open the log", 150, 22)
  logB:SetPoint("LEFT", open, "RIGHT", 8, 0)
  logB:SetScript("OnClick", function()
    BuildLog()
    if LOGWIN:IsShown() then LOGWIN:Hide() else LOGWIN:Show() end
  end)

  local reset = makeButton(p, "Reset window positions", 190, 22)
  reset:SetPoint("TOPLEFT", open, "BOTTOMLEFT", 0, -8)
  reset:SetScript("OnClick", function()
    db.pos = {}
    db.size = {}
    if UI     then UI:SetSize(470, 468);  restorePos(UI,     "MoonforgeFrame",   0,   40) end
    if WLADD  then                         restorePos(WLADD,  "MoonforgeWLAdd",   260, 40) end
    if WLLIST then WLLIST:SetSize(360, 380); restorePos(WLLIST, "MoonforgeWLList", -260, 40) end
    if SBINFO then SBINFO:SetSize(400, 380); restorePos(SBINFO, "MoonforgeSBInfo", 260, -20) end
    if LOGWIN then                         restorePos(LOGWIN, "MoonforgeLog",     0, -120) end
    log("Window positions reset.")
  end)

  local note = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  note:SetPoint("TOPLEFT", 18, -196)
  note:SetWidth(360)
  note:SetJustifyH("LEFT")
  note:SetText("Consume Green / Blue / Purple / All and the inventory tickbox unlock once the "
    .. "server gains a rarity-parameterised sweep verb. Everything destructive is confirmed "
    .. "with the server's own forecast first, and the Whitelist always protects an item.")

  p:SetScript("OnShow", function(self)
    self.mmCheck:SetChecked(not (db and db.minimap and db.minimap.hide))
    self.dbgCheck:SetChecked(debugWire)
  end)

  InterfaceOptions_AddCategory(p)
  return p
end

--========================== receive =======================================
local function OnLine(body)
  dbg("<- " .. body)
  local cmd, rest = body:match("^(%u+):?(.*)$")
  if not cmd then cmd = body; rest = "" end

  if cmd == "ICSF" then
    local mp, fp, comp, ac, ao = rest:match("^(%d+):(%d+):(%d+):(%d+):(%d+)$")
    if mp then
      state.sf.mult = tonumber(mp) / 100
      state.sf.fill = tonumber(fp) / 10
      state.sf.completions = tonumber(comp)
      state.sf.autoconsume = ac == "1"
      state.sf.autoopen = tonumber(ao) or 0
      if UI then UI:RefreshForge() end
    end

  elseif cmd == "ICSFDING" then
    if UI then UI:Ding() end
    log("|cff9CC243The Soulforge grows stronger!|r Extraction is now higher.")

  elseif cmd == "ICACWARN" then
    StaticPopupDialogs["MOONFORGE_AUTOCONSUME"].timeout = tonumber(rest) or 60
    showDeduped("MOONFORGE_AUTOCONSUME", "UNCAPPED_SF_AUTOCONSUME")

  elseif cmd == "ICVR" then
    local st, pc, sl, arm = rest:match("^(%d+):(%d+):(%d+):(%d+)$")
    if st then
      state.vr.stacks, state.vr.pieces, state.vr.souls =
        tonumber(st) or 0, tonumber(pc) or 0, tonumber(sl) or 0
      local secs = tonumber(arm) or 0
      if secs > 0 then
        StaticPopupDialogs["MOONFORGE_RENDER_JUNK"].timeout = secs
        showDeduped("MOONFORGE_RENDER_JUNK", "UNCAPPED_SF_RENDER_JUNK",
          groupDigits(state.vr.pieces), groupDigits(state.vr.souls))
      elseif state.vr.pieces == 0 then
        log("Nothing in the Vault for the sweep to consume.")
      end
    end

  elseif cmd == "ICVRDONE" then
    local st, pc, sl = rest:match("^(%d+):(%d+):(%d+)$")
    if st then
      log(string.format("Rendered %s piece(s) into %s souls.", groupDigits(pc), groupDigits(sl)))
      send("ICSF")
    end

  elseif cmd == "ICVCFORECAST" then
    -- <quality>:<scope>:<pieces>:<souls>:<armSeconds>
    local q, sc, pieces, souls, arm = rest:match("^(%d+):(%d+):(%d+):(%d+):(%d+)$")
    local p = state.vc
    p.pending = false
    if not q then
      log("|cffffd100Could not read the consume forecast from the server.|r")
    --[[ ⚠ A ZEROED FORECAST RIGHT AFTER A DONE IS THE SERVER'S OWN REDRAW, NOT A
      "nothing found". RunOneShotConsume sends ICVCDONE and then immediately
      ICVCFORECAST:<q>:<s>:0:0:0 so the button re-enables against the truth instead
      of the numbers it was still showing. Both go out consecutively from the same
      function with no async boundary between them, so they arrive together.
      Without this test a SUCCESSFUL consume prints "Nothing matches that rarity"
      directly underneath "Rendered 41 pieces into 9,300,000 souls", which reads as
      a bug. The window is generous on purpose -- it costs nothing, because a real
      user-initiated forecast cannot land within it.                             ]]
    elseif tonumber(pieces) == 0 and state.vc.doneAt
           and ((GetTime() or 0) - state.vc.doneAt) < 3 then
      -- the redraw; the ICVCDONE line above it already said what happened

    --[[ ★ ICVCFORECAST:0:0:0:0:0 IS THE EXPIRY REPLY, NOT A FORECAST.
      A confirm with no live arm -- expired, already answered, or never armed --
      answers with literal zeros for quality and scope, because the server never
      got as far as reading the arm. Quality 0 is not a value the forecast form
      can ever return (only 2/3/4/9 are accepted), so this is unambiguous.       ]]
    elseif q == "0" then
      log("That confirmation expired -- nothing was consumed. Press the button again.")

    --[[ ⚠ A zeroed forecast WITH a real quality has two causes that are identical
      on the wire: nothing of that rarity was found, OR the forge was already
      walking your vault and refused the press (it shares one in-flight guard with
      the standing sweep, the junk render and soulbind-all). The server explains
      which in chat; the addon channel cannot tell them apart, so the wording
      covers both rather than asserting the wrong one.                          ]]
    elseif tonumber(pieces) == 0 then
      log("Nothing to consume there right now -- either you have no " ..
          "gear of that rarity " .. (tonumber(sc) == 1 and "in your Vault or bags"
          or "in your Vault") .. ", or the forge is still busy. Check the chat line.")
    else
      local QNAME = { ["2"] = "GREEN (uncommon)", ["3"] = "BLUE (rare)", ["4"] = "PURPLE (epic)",
                      ["9"] = "WHITE, GREEN, BLUE and PURPLE" }
      p.quality, p.scope = q, sc
      -- Named from the SERVER's echo, never from the button we pressed.
      StaticPopup_Show("MOONFORGE_VCONSUME", string.format(
        "|cffff2020This permanently destroys gear.|r\n\n"
        .. "%s piece(s) of %s weapon and armour will be rendered down for "
        .. "|cffffffff%s|r souls, out of your %s.\n\n"
        .. "Whitelisted items, quest turn-ins, soulbound gear in your bags and exact copies "
        .. "of what you are wearing are held back. Everything else in that rarity goes, and "
        .. "it cannot be undone.\n\nYou have %s seconds to confirm.",
        groupDigits(pieces), QNAME[q] or ("quality " .. q), groupDigits(souls),
        tonumber(sc) == 1 and "|cffff2020Vault AND bags|r" or "Vault", arm))
    end

  elseif cmd == "ICVCDONE" then
    local pieces, souls = rest:match("^(%d+):(%d+)$")
    if pieces then
      -- Stamped BEFORE anything else: the zeroing forecast redraw follows this
      -- line immediately and is recognised by this timestamp.
      state.vc.doneAt = GetTime() or 0
      if tonumber(pieces) == 0 then
        -- The re-walk found nothing left. The server has already said so in chat.
        log("Nothing was left to consume by the time you confirmed.")
      else
        log(string.format("Rendered %s piece(s) into %s souls.",
                          groupDigits(pieces), groupDigits(souls)))
        if UI then UI:Ding() end
      end
      send("ICSF")
    end

  elseif cmd == "ICWL" then
    table.insert(state.wlStaging, rest)

  elseif cmd == "ICWLEND" then
    state.whitelist = state.wlStaging
    state.wlStaging = {}
    state.wlSet = {}
    for _, n in ipairs(state.whitelist) do state.wlSet[tostring(n):lower()] = true end

    --[[ ★★ THE ONLY PLACE A LOST ICWLADD CAN BE SEEN.
      The server drops a verb it cannot afford: no answer, no error, no queue.
      The list we just rebuilt is the truth, and wlIntent is what we meant --
      so anything we intended and did not get back was thrown away in transit.
      Retry it, bounded, and if it still will not land SAY SO IN RED. A whitelist
      that silently came up short is gear that Auto-Consume is about to eat.
      This block only ever runs after the queue has drained, so a mid-batch
      ICWLEND (the server sends one per successful add) is not mistaken for a
      loss.                                                                  ]]
    if #state.queue == 0 and next(state.wlIntent) then
      local missing = {}
      for k, orig in pairs(state.wlIntent) do
        if not state.wlSet[k] then table.insert(missing, orig) end
      end
      state.wlIntent = {}
      if #missing == 0 then
        state.wlRound, settleTries = 0, 0
      elseif state.wlRound < 3 then
        state.wlRound = state.wlRound + 1
        for _, orig in ipairs(missing) do
          state.wlSet[orig:lower()] = true
          state.wlIntent[orig:lower()] = orig
          enqueue("ICWLADD:" .. orig)
        end
        flushQueueThen("ICWLIST")
        log(string.format("|cffffd100%d whitelist add(s) did not reach the server; retrying (%d/3).|r",
                          #missing, state.wlRound))
      else
        state.wlRound, settleTries = 0, 0
        log(string.format("|cffff2020%d item name(s) FAILED to whitelist and are NOT protected. "
                          .. "Add them by hand before enabling Auto-Consume.|r", #missing))
      end
    end

    if UI then UI:RefreshWhitelist() end
    if WLLIST and WLLIST:IsShown() then WLLIST:Refresh() end
    if WLADD and WLADD:IsShown() then WLADD:UpdateSuggest() end

  elseif cmd == "ICINAME" then
    table.insert(state.wlSuggestStaging, rest)

  elseif cmd == "ICINAMEEND" then
    state.wlSuggest = state.wlSuggestStaging
    state.wlSuggestStaging = {}
    if WLADD and WLADD:IsShown() then WLADD:UpdateSuggest() end
    wlSearchAnswered()

  elseif cmd == "ICEXI" then
    -- Only meaningful to us while a "Whitelist Procs" sweep is armed.
    local p = state.procWL
    if p.pending then
      local _, _, entry, _, spell = rest:match("^(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)$")
      if entry and spell and tonumber(spell) ~= 0 then
        p.entries[tonumber(entry)] = true
      end
    end

  elseif cmd == "ICEXIEND" then
    local p = state.procWL
    if p.pending then
      if (GetTime() or 0) - (p.since or 0) <= 10 then
        whitelistProcsCommit()
      else
        p.pending = false   -- stale arm; a stray sweep from another addon
      end
    end

  elseif cmd == "ICITEM" then
    -- Start of one soulbound item's block in the ICINV stream.
    state.sbi.curKey = rest
    state.sbi.staging[rest] = { vest = 0, mult = 100 }

  elseif cmd == "ICIVEST" then
    -- <count>:<multPct> -- duplicates this item has absorbed + their worth.
    local n, m = rest:match("^(%d+):(%d+)$")
    local key = state.sbi.curKey
    if n and key and state.sbi.staging[key] then
      state.sbi.staging[key].vest = tonumber(n)
      state.sbi.staging[key].mult = tonumber(m)
    end

  elseif cmd == "ICINVEND" then
    state.sbi.items = state.sbi.staging
    state.sbi.staging = {}
    state.sbi.curKey = nil
    if SBINFO and SBINFO:IsShown() then SBINFO:Refresh() end

  elseif cmd == "ICBOUND" then
    local entry = tonumber(rest)
    local nm = entry and GetItemInfo(entry) or nil
    log("Soulbound " .. (nm or ("item " .. tostring(rest))) .. " onto your gear.")
    if UI then UI:Ding() end
    send("ICSF")

  elseif cmd == "ICBOUNDALL" then
    state.sbInflight = false
    local n = tonumber(rest) or 0
    log(string.format("Soulbound %d duplicate%s onto your gear.", n, n == 1 and "" or "s"))
    if UI then UI:Ding() end
    send("ICSF")
    if SBINFO and SBINFO:IsShown() then askInv() end

  --[[ ★★ ICERR IS A REPLY, NOT AN ANOMALY -- and missing it bricked a button.
    ICSBALL answers ICBOUNDALL:<count> only when it bound something. With nothing
    to bind -- the normal state for anyone who has pressed it once already -- it
    answers ICERR:soulbindall:<reason>. With no branch here that reply fell off
    the end of the dispatch, sbInflight stayed true forever, and the button read
    "Soulbinding..." and stayed disabled until /reload. Deterministic, no throttle
    needed, and it would have been the first bug report on this addon.          ]]
  elseif cmd == "ICERR" then
    local what   = rest:match("^([^:]+)") or "?"
    local reason = rest:match("^[^:]+:(.*)$") or rest
    if what == "vconsume" then
      state.vc.pending = false
      local WHY = {
        parse   = "the request was malformed (this is an addon bug -- please report it)",
        quality = "that rarity is not one the server will sweep",
        scope   = "that scope is not one the server will accept",
      }
      log("|cffffd100Consume refused: " .. (WHY[reason] or reason) .. "|r")
    elseif what == "soulbindall" then
      -- Clearing the flag is all that is needed: the button's own OnUpdate ticker
      -- reads sbInflight/sbReadyAt every 0.25s and re-enables itself. The 30s
      -- cooldown deliberately STAYS -- the server ran its vault SELECT either way,
      -- so the press was not free just because it found nothing.
      state.sbInflight = false
      log("Nothing to soulbind: " .. reason)
    else
      log("|cffffd100Server refused " .. what .. ": " .. reason .. "|r")
    end
  end
end

--========================== events / slash ================================
local listener = CreateFrame("Frame")
listener:RegisterEvent("ADDON_LOADED")
listener:RegisterEvent("PLAYER_LOGIN")
listener:RegisterEvent("CHAT_MSG_ADDON")
listener:SetScript("OnEvent", function(_, event, arg1, arg2)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    MoonforgeDB = MoonforgeDB or {}
    db = MoonforgeDB
    db.pos = db.pos or {}
    db.size = db.size or {}
    db.minimap = db.minimap or { pos = 220 }
    BuildOptions()
    mmApplyVisibility()

  elseif event == "PLAYER_LOGIN" then
    -- Single login stamp; everything else stays in the window/log.
    DEFAULT_CHAT_FRAME:AddMessage("|cffb8ccffMoonforge|r v" .. VERSION .. " -- /mf")
    After(2, function() send("ICSF"); send("ICWLIST") end)
    --[[ Explain drops rather than pace off them. UncappedThrottle turns the
      server's UTHR line into a callback; it is READ AT CALL TIME so a load-order
      accident degrades to "no explanation" instead of an error. Never wait on
      this to decide when to send -- UTHR only ever arrives AFTER a message has
      already been thrown away, and it is itself rate limited.                 ]]
    After(3, function()
      local UT = _G.UncappedThrottle
      if UT and UT.OnDrop then
        UT.OnDrop(function()
          local txt = UT.StatusText and UT.StatusText()
          log("|cffffd100" .. (txt or "The server is dropping addon requests right now.") .. "|r")
        end)
      end
    end)

  elseif event == "CHAT_MSG_ADDON" then
    if arg1 == PIPE_PREFIX and arg2 then OnLine(arg2) end
  end
end)

-- ⚠ Assignment, not `local function`: the minimap and options handlers above
-- closed over the forward-declared local at the top of the file. A fresh
-- `local` here would be a different variable and they'd call nil.
openMain = function()
  BuildUI(); BuildWLAdd(); BuildWLList(); BuildSBInfo()
  if UI:IsShown() then UI:Hide(); return end
  UI:Show()
  UI:RefreshForge()
  UI:RefreshWhitelist()
  send("ICSF"); send("ICWLIST")
end

SLASH_MOONFORGE1 = "/moonforge"
SLASH_MOONFORGE2 = "/mf"
SlashCmdList["MOONFORGE"] = function(msgIn)
  local arg = trim(msgIn or ""):lower()
  if arg == "log" then
    BuildLog()
    if LOGWIN:IsShown() then LOGWIN:Hide() else LOGWIN:Show() end
  elseif arg == "options" or arg == "opt" or arg == "config" then
    BuildOptions()
    InterfaceOptionsFrame_OpenToCategory(optPanel)
    InterfaceOptionsFrame_OpenToCategory(optPanel)   -- classic first-call quirk
  elseif arg == "debug" then
    debugWire = not debugWire
    log("Wire debug " .. (debugWire and "ON" or "OFF") .. " (view with /mf log).")
  else
    openMain()
  end
end
