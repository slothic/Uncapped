-- UncappedUIKit ThemeManager -- theme registry, resolution, and live re-skin.
--
-- A "theme" is a plain table of colors/fonts/textures/metrics. Any theme
-- other than "Default" is resolved by deep-merging its own overrides on
-- top of "Default", so a theme only needs to define the keys it actually
-- changes -- everything else falls back to the default WoW look. That is how
-- the "Uncapped" theme gets away with defining colours and four glow metrics
-- and nothing else: every texture, font and inset it does not mention comes
-- from Default, so the realm look is a tint over stock art rather than a
-- second complete theme to keep in step.
--
-- Widgets built by the other UncappedUIKit modules call UncappedUIKit.Register()
-- with a small "apply this theme to me" function. That function runs once
-- immediately, and again every time the active theme changes, so anything
-- built through this library stays in sync with the Theme setting for
-- free -- callers never re-skin their own widgets manually.

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

local pairs, ipairs, type = pairs, ipairs, type
local tsort, tconcat = table.sort, table.concat

local DEFAULT_THEME_NAME = "Default"

-- ★ What a player who has never run /uitheme gets. Deliberately NOT the same
--   constant as DEFAULT_THEME_NAME: that one is the deep-merge BASE every
--   other theme inherits from and must stay "Default" forever, whereas this
--   one is just the opening choice and is safe to move.
--
--   Set to "Uncapped" on 2026-09-04 so the realm's own look is what people
--   actually see -- a theme nobody selects is a theme nobody has. `/uitheme
--   default` still returns the stock WoW appearance and is remembered.
--
-- ⚠ This can name a theme that has not registered yet (load order: GetDB may
--   run before Themes\UncappedTheme.lua). That is safe -- GetActiveTheme
--   falls back to Default for an unknown name, and RegisterTheme calls
--   ApplyAll() when the theme it just registered is the selected one, so the
--   UI repaints itself the moment the real definition arrives.
local INITIAL_THEME_NAME = "Uncapped"

-- ⚠ DECLARED HERE, NOT NEXT TO GetActiveTheme WHERE THEY ARE USED. Lua binds
--   an upvalue at COMPILE time, so a local declared further down the file is not
--   in scope inside RegisterTheme above it -- the call would compile as a lookup
--   of a GLOBAL of the same name, find nil, and throw the first time a theme
--   registered. It compiles cleanly either way, so nothing catches it but this.
local customCache = nil
local function InvalidateCustom()
    customCache = nil
end

local themes = {}      -- name -> raw definition passed to RegisterTheme
local resolved = {}    -- name -> definition deep-merged over Default
local widgets = setmetatable({}, { __mode = "k" }) -- widget -> apply(widget, theme)
local listeners = {}

local function DeepMerge(base, override)
    local out = {}
    for k, v in pairs(base) do
        if type(v) == "table" then
            out[k] = DeepMerge(v, nil)
        else
            out[k] = v
        end
    end
    if override then
        for k, v in pairs(override) do
            if type(v) == "table" and type(out[k]) == "table" then
                out[k] = DeepMerge(out[k], v)
            else
                out[k] = v
            end
        end
    end
    return out
end

local function Resolve(name)
    local def = themes[name]
    if not def then return resolved[DEFAULT_THEME_NAME] end
    if name == DEFAULT_THEME_NAME then
        resolved[name] = DeepMerge(def, nil)
        return resolved[name]
    end
    local base = resolved[DEFAULT_THEME_NAME] or DeepMerge(themes[DEFAULT_THEME_NAME] or {}, nil)
    resolved[name] = DeepMerge(base, def)
    return resolved[name]
end

-- Registers (or replaces) a theme definition and re-resolves every
-- registered theme, so load order between Default and its dependents
-- never matters.
function UncappedUIKit.RegisterTheme(name, definition)
    themes[name] = definition or {}
    for existing in pairs(themes) do
        Resolve(existing)
    end
    InvalidateCustom()
    if UncappedUIKit.GetThemeName() == name then
        UncappedUIKit.ApplyAll()
    end
end

function UncappedUIKit.GetThemeNames()
    local names = {}
    for name in pairs(themes) do names[#names + 1] = name end
    tsort(names)
    return names
end

function UncappedUIKit.GetDB()
    UncappedUIDB = UncappedUIDB or {}
    local db = UncappedUIDB
    if db.theme == nil then db.theme = INITIAL_THEME_NAME end

    -- ★ ONE-TIME MIGRATION, and without it changing INITIAL_THEME_NAME above
    --   would have done NOTHING for a single existing player.
    --
    --   This function has always WRITTEN db.theme = "Default" the first time it
    --   ran, so every character that has ever logged in already carries an
    --   explicit "Default" that was never a choice anybody made -- and an
    --   explicit value is exactly what the line above declines to overwrite.
    --   The new look would have shipped to an empty set.
    --
    --   So: a stored theme only counts as the player's own if SetTheme wrote it
    --   (i.e. they ran /uitheme). Everyone else is moved across once, and
    --   themeMigrated makes sure once means once -- run /uitheme default after
    --   this and it sticks for good.
    --
    -- ⚠ Anyone who had deliberately run /uitheme default BEFORE this shipped
    --   is indistinguishable from someone who never touched it (the flag did not
    --   exist to record them) and does get moved. That is one re-run of a slash
    --   command for them, against the entire playerbase never seeing the theme.
    if not db.themeMigrated then
        db.themeMigrated = true
        if not db.themeSetByUser then
            db.theme = INITIAL_THEME_NAME
        end
    end

    return db
end

function UncappedUIKit.GetThemeName()
    return UncappedUIKit.GetDB().theme or DEFAULT_THEME_NAME
end

-- ★ THE PLAYER'S OWN OVERRIDES, MERGED ON TOP OF WHICHEVER THEME IS SELECTED.
--
--   db.custom looks exactly like a theme definition -- { colors = {...},
--   metrics = {...}, textures = {...} } -- and is deep-merged over the resolved
--   theme. That means a player who recolours one thing overrides one key and
--   keeps inheriting every other value, including from a theme we ship LATER.
--   Storing a whole flattened theme instead would freeze their UI at today's
--   key set and quietly opt them out of every future improvement.
--
--   ⚠ A colour is an ARRAY, and DeepMerge merges arrays index-wise. That is
--     deliberate and useful: a custom { r, g, b } laid over a base
--     { r, g, b, a } keeps the base ALPHA. Players pick a hue; they should not
--     have to think about opacity to avoid accidentally erasing it.
function UncappedUIKit.GetActiveTheme()
    if customCache then return customCache end
    local name = UncappedUIKit.GetThemeName()
    local base = resolved[name] or resolved[DEFAULT_THEME_NAME] or {}
    local db = UncappedUIKit.GetDB()
    if db.custom and next(db.custom) ~= nil then
        customCache = DeepMerge(base, db.custom)
    else
        customCache = base
    end
    return customCache
end

-- section is "colors", "metrics" or "textures". Passing value = nil CLEARS the
-- override for that key, dropping back to whatever the theme says.
function UncappedUIKit.SetCustom(section, key, value)
    if not section or not key then return end
    local db = UncappedUIKit.GetDB()
    db.custom = db.custom or {}
    if value == nil then
        if db.custom[section] then db.custom[section][key] = nil end
    else
        db.custom[section] = db.custom[section] or {}
        db.custom[section][key] = value
    end
    InvalidateCustom()
    UncappedUIKit.ApplyAll()
end

-- ★ BATCHED. SetCustom re-resolves the theme and re-skins EVERY registered
--   widget on each call, which is right for one change and badly wrong for a
--   group of them: a player-facing colour like "Selection" writes nine keys, and
--   the colour wheel fires continuously while dragging -- so the per-key version
--   was nine full UI repaints per frame of a drag.
--
--   `values` is key -> value. A key may not be cleared here (a Lua table cannot
--   hold nil); use ClearCustomBatch for that.
function UncappedUIKit.SetCustomBatch(section, values)
    if not section or type(values) ~= "table" then return end
    local db = UncappedUIKit.GetDB()
    db.custom = db.custom or {}
    db.custom[section] = db.custom[section] or {}
    for key, value in pairs(values) do
        db.custom[section][key] = value
    end
    InvalidateCustom()
    UncappedUIKit.ApplyAll()
end

-- Drops overrides for a list of keys, then re-skins once.
function UncappedUIKit.ClearCustomBatch(section, keys)
    if not section or type(keys) ~= "table" then return end
    local db = UncappedUIKit.GetDB()
    if not (db.custom and db.custom[section]) then return end
    for i = 1, #keys do
        db.custom[section][keys[i]] = nil
    end
    if next(db.custom[section]) == nil then db.custom[section] = nil end
    if next(db.custom) == nil then db.custom = nil end
    InvalidateCustom()
    UncappedUIKit.ApplyAll()
end

function UncappedUIKit.GetCustom(section, key)
    local db = UncappedUIKit.GetDB()
    return db.custom and db.custom[section] and db.custom[section][key] or nil
end

-- Drops every override and returns to the selected theme as shipped. Passing a
-- section clears only that section.
function UncappedUIKit.ResetCustom(section)
    local db = UncappedUIKit.GetDB()
    if section then
        if db.custom then db.custom[section] = nil end
    else
        db.custom = nil
    end
    InvalidateCustom()
    UncappedUIKit.ApplyAll()
end

function UncappedUIKit.HasCustom()
    local db = UncappedUIKit.GetDB()
    return db.custom ~= nil and next(db.custom) ~= nil
end

-- Re-applies the active theme to every widget created through this
-- library, then notifies any addon-level listeners (for custom reskin
-- logic that lives outside UncappedUIKit's own widget set).
function UncappedUIKit.ApplyAll()
    local theme = UncappedUIKit.GetActiveTheme()
    for widget, apply in pairs(widgets) do
        apply(widget, theme)
    end
    for i = 1, #listeners do
        listeners[i](theme)
    end
end

function UncappedUIKit.SetTheme(name)
    if not themes[name] then return false end
    local db = UncappedUIKit.GetDB()
    -- Marks the choice as the player's own, which is what stops the migration in
    -- GetDB from ever second-guessing it.
    db.themeSetByUser = true
    db.theme = name
    InvalidateCustom()
    UncappedUIKit.ApplyAll()
    return true
end

-- Hooks a widget into the live theme system. `apply` is called immediately
-- with the current theme, then again on every SetTheme().
function UncappedUIKit.Register(widget, apply)
    if not widget or type(apply) ~= "function" then return end
    widgets[widget] = apply
    apply(widget, UncappedUIKit.GetActiveTheme())
end

function UncappedUIKit.Unregister(widget)
    widgets[widget] = nil
end

-- For addon code that needs to react to theme changes but isn't a widget
-- built through UncappedUIKit's constructors (e.g. re-tinting custom art).
function UncappedUIKit.OnThemeChanged(callback)
    if type(callback) ~= "function" then return end
    listeners[#listeners + 1] = callback
end

-- ★ Theme colour as a "|cffRRGGBB" escape, for the many places that build a
--   coloured STRING rather than colouring a FontString -- SetText("|cff..."),
--   chat output, tooltip lines. Those sites cannot use SetTextColor, so before
--   this they all hand-typed hex and drifted apart: six Dashboard tabs each had
--   their own copy of a heading/label/value/dim quadruplet, two of them a
--   different green from the other four.
--
--   Call this at USE time, or refresh through OnThemeChanged -- the returned
--   string is a snapshot, not a live binding.
function UncappedUIKit.Hex(key, fallback)
    local c = UncappedUIKit.GetActiveTheme().colors or {}
    local col = c[key] or fallback
    if not col then return "|cffffffff" end
    return string.format("|cff%02x%02x%02x",
        math.floor((col[1] or 1) * 255 + 0.5),
        math.floor((col[2] or 1) * 255 + 0.5),
        math.floor((col[3] or 1) * 255 + 0.5))
end

-- "B876E0" for display and for typing back in. No "|cff" prefix and no alpha:
-- this is the six-digit code people paste between tools, not a WoW escape.
function UncappedUIKit.ColorToHex(r, g, b)
    return string.format("%02X%02X%02X",
        math.floor((r or 0) * 255 + 0.5),
        math.floor((g or 0) * 255 + 0.5),
        math.floor((b or 0) * 255 + 0.5))
end

-- Parses a hex colour typed by a player. Returns r, g, b in 0..1, or nil if the
-- string is not a colour -- callers reject rather than guess.
--
-- ⚠ Deliberately generous about FORM and strict about CONTENT: a leading "#",
--   surrounding spaces, lower case and the three-digit shorthand are all
--   accepted, because those are what people actually paste. Anything that is not
--   then exactly six hex digits is refused outright.
function UncappedUIKit.HexToColor(text)
    if type(text) ~= "string" then return nil end
    local s = text:gsub("%s+", ""):gsub("^#", "")
    if #s == 3 then
        s = s:sub(1, 1):rep(2) .. s:sub(2, 2):rep(2) .. s:sub(3, 3):rep(2)
    end
    if #s ~= 6 or s:find("%X") then return nil end
    return tonumber(s:sub(1, 2), 16) / 255,
           tonumber(s:sub(3, 4), 16) / 255,
           tonumber(s:sub(5, 6), 16) / 255
end

local function PrintLine(text)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(text) end
end

SLASH_UNCAPPEDUITHEME1 = "/uitheme"
SlashCmdList["UNCAPPEDUITHEME"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local names = UncappedUIKit.GetThemeNames()
    if msg == "" then
        PrintLine("|cff40c0ff[UI]|r current theme: |cffffd100" .. UncappedUIKit.GetThemeName()
            .. "|r. Available: " .. tconcat(names, ", "))
        return
    end
    for _, name in ipairs(names) do
        if name:lower() == msg:lower() then
            UncappedUIKit.SetTheme(name)
            PrintLine("|cff40c0ff[UI]|r theme set to |cffffd100" .. name .. "|r.")
            return
        end
    end
    PrintLine("|cff40c0ff[UI]|r unknown theme '" .. msg .. "'. Available: " .. tconcat(names, ", "))
end
