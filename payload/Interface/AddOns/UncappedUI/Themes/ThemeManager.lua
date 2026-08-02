-- UncappedUI ThemeManager -- theme registry, resolution, and live re-skin.
--
-- A "theme" is a plain table of colors/fonts/textures/metrics. Any theme
-- other than "Default" is resolved by deep-merging its own overrides on
-- top of "Default", so a theme only needs to define the keys it actually
-- changes -- everything else falls back to the default WoW look. This is
-- what lets the "Uncapped" theme exist today with zero art: it resolves
-- to an exact copy of "Default" until real texture keys are filled in.
--
-- Widgets built by the other UncappedUI modules call UncappedUI.Register()
-- with a small "apply this theme to me" function. That function runs once
-- immediately, and again every time the active theme changes, so anything
-- built through this library stays in sync with the Theme setting for
-- free -- callers never re-skin their own widgets manually.

local UncappedUI = _G.UncappedUI
if not UncappedUI then return end

local pairs, ipairs, type = pairs, ipairs, type
local tsort, tconcat = table.sort, table.concat

local DEFAULT_THEME_NAME = "Default"

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
function UncappedUI.RegisterTheme(name, definition)
    themes[name] = definition or {}
    for existing in pairs(themes) do
        Resolve(existing)
    end
    if UncappedUI.GetThemeName() == name then
        UncappedUI.ApplyAll()
    end
end

function UncappedUI.GetThemeNames()
    local names = {}
    for name in pairs(themes) do names[#names + 1] = name end
    tsort(names)
    return names
end

function UncappedUI.GetDB()
    UncappedUIDB = UncappedUIDB or {}
    local db = UncappedUIDB
    if db.theme == nil then db.theme = DEFAULT_THEME_NAME end
    return db
end

function UncappedUI.GetThemeName()
    return UncappedUI.GetDB().theme or DEFAULT_THEME_NAME
end

function UncappedUI.GetActiveTheme()
    local name = UncappedUI.GetThemeName()
    return resolved[name] or resolved[DEFAULT_THEME_NAME] or {}
end

-- Re-applies the active theme to every widget created through this
-- library, then notifies any addon-level listeners (for custom reskin
-- logic that lives outside UncappedUI's own widget set).
function UncappedUI.ApplyAll()
    local theme = UncappedUI.GetActiveTheme()
    for widget, apply in pairs(widgets) do
        apply(widget, theme)
    end
    for i = 1, #listeners do
        listeners[i](theme)
    end
end

function UncappedUI.SetTheme(name)
    if not themes[name] then return false end
    UncappedUI.GetDB().theme = name
    UncappedUI.ApplyAll()
    return true
end

-- Hooks a widget into the live theme system. `apply` is called immediately
-- with the current theme, then again on every SetTheme().
function UncappedUI.Register(widget, apply)
    if not widget or type(apply) ~= "function" then return end
    widgets[widget] = apply
    apply(widget, UncappedUI.GetActiveTheme())
end

function UncappedUI.Unregister(widget)
    widgets[widget] = nil
end

-- For addon code that needs to react to theme changes but isn't a widget
-- built through UncappedUI's constructors (e.g. re-tinting custom art).
function UncappedUI.OnThemeChanged(callback)
    if type(callback) ~= "function" then return end
    listeners[#listeners + 1] = callback
end

local function PrintLine(text)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(text) end
end

SLASH_UNCAPPEDUITHEME1 = "/uitheme"
SlashCmdList["UNCAPPEDUITHEME"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local names = UncappedUI.GetThemeNames()
    if msg == "" then
        PrintLine("|cff40c0ff[UI]|r current theme: |cffffd100" .. UncappedUI.GetThemeName()
            .. "|r. Available: " .. tconcat(names, ", "))
        return
    end
    for _, name in ipairs(names) do
        if name:lower() == msg:lower() then
            UncappedUI.SetTheme(name)
            PrintLine("|cff40c0ff[UI]|r theme set to |cffffd100" .. name .. "|r.")
            return
        end
    end
    PrintLine("|cff40c0ff[UI]|r unknown theme '" .. msg .. "'. Available: " .. tconcat(names, ", "))
end
