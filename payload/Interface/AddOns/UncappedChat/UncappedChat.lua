--[[
  Uncapped Chat -- World / Discord / Loot in one window.

  Design: C:\Wotlk\docs\design\DISCORD_SERVER.md

  Three tabs:
    World    the "World" custom channel, captured from CHAT_MSG_CHANNEL
    Discord  relay traffic, pushed by the server on the shared "UNC" addon pipe
             (CHATD:<sender>:<text>) -- deliberately NOT in the world channel,
             so players without this addon never see Discord chatter
    Loot     purely client-side capture of CHAT_MSG_LOOT. No server involvement.

  Transport (matches the rest of the UNC pipe):
    RECEIVE : CHAT_MSG_ADDON, arg1 == "UNC", arg2 == body

  There is no client -> server path on the pipe (the Lua engine exposes no
  addon-message event), so the input box posts to the World channel and the
  server relays that onward to Discord. One box, both destinations.

  Blizzard's chat frame is left completely alone.
]]

local ADDON = "UncappedChat"
local PIPE = "UNC"
local WORLD_CHANNEL = "World"
local MAX_LINES = 300

local defaults = {
  shown = true,
  point = { "CENTER", "UIParent", "CENTER", 0, -180 },
  width = 520,
  height = 280,
  tab = 1,
  timestamps = true,
}

local TABS = {
  { key = "world",   label = "World"   },
  { key = "discord", label = "Discord" },
  { key = "loot",    label = "Loot"    },
}

local COLOURS = {
  world   = "ffffd200",
  discord = "ff7289da",   -- Discord blurple, so relayed lines read as foreign
  loot    = "ff1eff00",
  system  = "ff888888",
}

local buffers = { world = {}, discord = {}, loot = {} }
local unread  = { world = 0, discord = 0, loot = 0 }
local UC = CreateFrame("Frame", "UncappedChatFrame")
local ui = {}

-- --------------------------------------------------------------------------
-- helpers
-- --------------------------------------------------------------------------

local function db()
  if type(UncappedChatDB) ~= "table" then UncappedChatDB = {} end
  for k, v in pairs(defaults) do
    if UncappedChatDB[k] == nil then UncappedChatDB[k] = v end
  end
  return UncappedChatDB
end

local function stamp()
  if not db().timestamps then return "" end
  return string.format("|cff606060%s|r ", date("%H:%M"))
end

local function push(key, line)
  local buf = buffers[key]
  buf[#buf + 1] = stamp() .. line
  while #buf > MAX_LINES do table.remove(buf, 1) end

  if ui.frame and ui.frame:IsShown() and TABS[db().tab].key == key then
    ui.scroll:AddMessage(stamp() .. line)
  else
    unread[key] = unread[key] + 1
    if ui.frame then ui.UpdateTabs() end
  end
end

--- Find the numeric index of the world channel, or nil if we're not in it.
local function worldChannelIndex()
  local id = GetChannelName(WORLD_CHANNEL)
  if id and id > 0 then return id end
  return nil
end

-- --------------------------------------------------------------------------
-- channel membership -- the half that actually fixes "join didn't stick"
-- --------------------------------------------------------------------------

--- JoinPermanentChannel (not /join) is what makes the client REMEMBER the
--- channel across sessions. Binding it to a chat frame is what makes it
--- visible -- a channel joined but bound to no frame looks exactly like a
--- failed join, which is the usual cause of "I'm not in world chat".
local function ensureWorldChannel()
  if worldChannelIndex() then return end
  JoinPermanentChannel(WORLD_CHANNEL, nil, 1, false)
  -- Bind it so it shows in the default frame too, for players who never open
  -- this window. Harmless if already bound.
  if ChatFrame_AddChannel then
    ChatFrame_AddChannel(DEFAULT_CHAT_FRAME, WORLD_CHANNEL)
  end
end

-- --------------------------------------------------------------------------
-- window
-- --------------------------------------------------------------------------

local function buildUI()
  if ui.frame then return end
  local d = db()

  local f
  if UncappedUI and UncappedUI.CreatePanel then
    f = UncappedUI.CreatePanel(ADDON .. "Panel", "Uncapped Chat", d.width, d.height)
  end
  if not f then
    -- Standalone fallback so the addon still works if UncappedOptions is absent.
    f = CreateFrame("Frame", ADDON .. "Panel", UIParent)
    f:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 32,
      insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -14)
    title:SetText("Uncapped Chat")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
  end

  f:SetSize(d.width, d.height)
  f:ClearAllPoints()
  f:SetPoint(unpack(d.point))
  f:SetMovable(true)
  f:SetResizable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint()
    db().point = { p, "UIParent", rp, x, y }
  end)
  f:SetClampedToScreen(true)
  ui.frame = f

  -- scrolling message area
  local sf = CreateFrame("ScrollingMessageFrame", ADDON .. "Scroll", f)
  sf:SetPoint("TOPLEFT", 16, -58)
  sf:SetPoint("BOTTOMRIGHT", -16, 46)
  sf:SetFontObject(ChatFontNormal)
  sf:SetJustifyH("LEFT")
  sf:SetFading(false)
  sf:SetMaxLines(MAX_LINES)
  sf:EnableMouseWheel(true)
  sf:SetScript("OnMouseWheel", function(self, delta)
    if delta > 0 then self:ScrollUp() else self:ScrollDown() end
  end)
  sf:SetHyperlinksEnabled(true)
  sf:SetScript("OnHyperlinkClick", function(_, link, text, button)
    SetItemRef(link, text, button)
  end)
  ui.scroll = sf

  -- tabs
  ui.tabs = {}
  for i, tab in ipairs(TABS) do
    local b = CreateFrame("Button", nil, f)
    b:SetSize(84, 22)
    b:SetPoint("TOPLEFT", 16 + (i - 1) * 88, -34)
    b:SetNormalFontObject(GameFontNormalSmall)
    b:SetHighlightFontObject(GameFontHighlightSmall)
    b:SetText(tab.label)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(0, 0, 0, 0.35)
    b.bg = bg
    b:SetScript("OnClick", function()
      db().tab = i
      unread[tab.key] = 0
      ui.Render()
    end)
    ui.tabs[i] = b
  end

  -- input
  local eb = CreateFrame("EditBox", ADDON .. "Input", f, "InputBoxTemplate")
  eb:SetPoint("BOTTOMLEFT", 20, 16)
  eb:SetPoint("BOTTOMRIGHT", -74, 16)
  eb:SetHeight(20)
  eb:SetAutoFocus(false)
  eb:SetMaxLetters(255)
  eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  eb:SetScript("OnEnterPressed", function(self)
    local text = strtrim(self:GetText() or "")
    if text ~= "" then UC.Send(text) end
    self:SetText("")
    self:ClearFocus()
  end)
  ui.input = eb

  local send = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  send:SetSize(52, 22)
  send:SetPoint("BOTTOMRIGHT", -16, 15)
  send:SetText("Send")
  send:SetScript("OnClick", function() eb:GetScript("OnEnterPressed")(eb) end)

  -- resize grip
  local grip = CreateFrame("Button", nil, f)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", -4, 4)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
  grip:SetScript("OnMouseUp", function()
    f:StopMovingOrSizing()
    db().width, db().height = f:GetWidth(), f:GetHeight()
    ui.Render()
  end)

  function ui.UpdateTabs()
    for i, tab in ipairs(TABS) do
      local b = ui.tabs[i]
      local active = (db().tab == i)
      b.bg:SetTexture(0, 0, 0, active and 0.65 or 0.25)
      local label = tab.label
      if not active and unread[tab.key] > 0 then
        label = string.format("%s |cffffd200(%d)|r", label, unread[tab.key])
      end
      b:SetText(label)
    end
  end

  function ui.Render()
    ui.scroll:Clear()
    for _, line in ipairs(buffers[TABS[db().tab].key]) do
      ui.scroll:AddMessage(line)
    end
    ui.scroll:ScrollToBottom()
    ui.UpdateTabs()
  end

  ui.Render()
end

-- --------------------------------------------------------------------------
-- sending
-- --------------------------------------------------------------------------

--- One input box, whichever tab is open. Everything goes to the World channel;
--- the server relays that on to Discord. The Discord tab is a read-only view of
--- what comes back the other way, so there is nothing to "reply" to directly.
function UC.Send(text)
  local id = worldChannelIndex()
  if not id then
    ensureWorldChannel()
    id = worldChannelIndex()
  end
  if not id then
    push("world", "|cffff5555Not in the World channel yet -- try again in a moment.|r")
    return
  end
  SendChatMessage(text, "CHANNEL", nil, id)
end

function UC.Toggle()
  buildUI()
  if ui.frame:IsShown() then
    ui.frame:Hide()
    db().shown = false
  else
    ui.frame:Show()
    db().shown = true
    unread[TABS[db().tab].key] = 0
    ui.Render()
  end
end

-- --------------------------------------------------------------------------
-- events
-- --------------------------------------------------------------------------

UC:RegisterEvent("PLAYER_ENTERING_WORLD")
UC:RegisterEvent("CHAT_MSG_CHANNEL")
UC:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")
UC:RegisterEvent("CHAT_MSG_ADDON")
UC:RegisterEvent("CHAT_MSG_LOOT")

UC:SetScript("OnEvent", function(_, event, ...)
  if event == "PLAYER_ENTERING_WORLD" then
    buildUI()
    if not db().shown then ui.frame:Hide() end
    -- The channel list isn't ready the instant we enter the world, and joining
    -- too early is exactly what leaves people silently out of world chat.
    -- Retry a few times rather than assuming the first attempt took.
    local tries = 0
    local ticker = CreateFrame("Frame")
    ticker.elapsed = 0
    ticker:SetScript("OnUpdate", function(self, e)
      self.elapsed = self.elapsed + e
      if self.elapsed < 2 then return end
      self.elapsed = 0
      tries = tries + 1
      ensureWorldChannel()
      if worldChannelIndex() or tries >= 10 then
        self:SetScript("OnUpdate", nil)
      end
    end)

  elseif event == "CHAT_MSG_CHANNEL" then
    local msg, author, _, _, _, _, _, _, channelName = ...
    if channelName and channelName:lower() == WORLD_CHANNEL:lower() then
      push("world", string.format("|c%s[%s]|r %s", COLOURS.world, author or "?", msg or ""))
    end

  elseif event == "CHAT_MSG_CHANNEL_NOTICE" then
    local kind, _, _, _, _, _, _, _, channelName = ...
    if channelName and channelName:lower() == WORLD_CHANNEL:lower()
       and (kind == "YOU_LEFT" or kind == "SUSPENDED") then
      -- Someone or something removed us. Rejoin rather than sit silent.
      push("world", "|c" .. COLOURS.system .. "Rejoining World...|r")
      ensureWorldChannel()
    end

  elseif event == "CHAT_MSG_ADDON" then
    local prefix, body = ...
    if prefix ~= PIPE or not body then return end
    local sender, text = body:match("^CHATD:([^:]*):(.*)$")
    if sender then
      -- Server swapped any colon in player text for U+00B7; put it back.
      sender = sender:gsub("\194\183", ":")
      text = text:gsub("\194\183", ":")
      push("discord", string.format("|c%s[%s]|r %s", COLOURS.discord, sender, text))
    end

  elseif event == "CHAT_MSG_LOOT" then
    local msg = ...
    if msg then push("loot", "|c" .. COLOURS.loot .. msg .. "|r") end
  end
end)

-- --------------------------------------------------------------------------
-- slash
-- --------------------------------------------------------------------------

SLASH_UNCAPPEDCHAT1 = "/uchat"
SLASH_UNCAPPEDCHAT2 = "/uncappedchat"
SlashCmdList["UNCAPPEDCHAT"] = function(arg)
  arg = strtrim((arg or ""):lower())
  if arg == "join" then
    ensureWorldChannel()
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Uncapped Chat]|r rejoining World channel.")
  elseif arg == "time" then
    db().timestamps = not db().timestamps
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Uncapped Chat]|r timestamps "
      .. (db().timestamps and "on" or "off"))
  else
    UC.Toggle()
  end
end
