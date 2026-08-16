-- UncappedUIKit Controls.Dropdown -- wraps the stock UIDropDownMenuTemplate.
--
-- There is no clean 3.3.5a way to retexture Blizzard's dropdown menu
-- chrome without replacing the whole template, so this control renders
-- identically under every theme for now. Revisit once the Uncapped theme
-- has real dropdown art to swap in.

local UncappedUIKit = _G.UncappedUIKit
if not UncappedUIKit then return end

--[[
    choices: { { value = ..., text = "..." }, ... }
             ★ OR a function returning that list.
    get():   returns the currently selected value
    set(v):  applies a newly chosen value

    ★ The function-valued `choices` and the re-derived label below were promoted
      here from UncappedVault_UI.lua on 2026-08-16, during the UI audit. The Vault
      had a private copy of this control that was a strict SUPERSET of the kit's,
      so aliasing the Vault to the kit would have been a downgrade -- the kit had
      to grow first. Both behaviours matter and neither is Vault-specific:

      LIVE LISTS. The equipment-slot dropdown offers only the slots the vault
      currently holds, and that set moves with every deposit, withdrawal and "my
      class only" toggle. A list captured once at build time goes stale the first
      time anything changes.

      RE-DERIVED LABEL. `set` can legitimately produce a different label than the
      entry that was clicked: picking the stat you are already sorted by flips the
      direction and so changes the caret, and slot entries carry live counts.
      Falling back to choice.text keeps the old behaviour whenever nothing
      re-derives.
]]
function UncappedUIKit.CreateDropdown(parent, name, width, choices, get, set)
    local function List()
        if type(choices) == "function" then return choices() end
        return choices
    end

    local dd = CreateFrame("Frame", name, parent, "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(dd, width)
    UIDropDownMenu_Initialize(dd, function()
        for _, choice in ipairs(List()) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = choice.text
            info.value = choice.value
            info.checked = get() == choice.value
            info.func = function()
                set(choice.value)
                UIDropDownMenu_SetSelectedValue(dd, choice.value)
                UIDropDownMenu_SetText(dd, dd.CurrentText() or choice.text)
            end
            UIDropDownMenu_AddButton(info)
        end
    end)

    -- Exposed, not local: callers refresh the visible label after changing the
    -- underlying data without reopening the menu.
    dd.CurrentText = function()
        for _, choice in ipairs(List()) do
            if choice.value == get() then return choice.text end
        end
        return nil
    end

    local text = dd.CurrentText()
    if text then
        UIDropDownMenu_SetSelectedValue(dd, get())
        UIDropDownMenu_SetText(dd, text)
    end

    return dd
end
