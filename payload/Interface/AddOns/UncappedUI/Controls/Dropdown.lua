-- UncappedUI Controls.Dropdown -- wraps the stock UIDropDownMenuTemplate.
--
-- There is no clean 3.3.5a way to retexture Blizzard's dropdown menu
-- chrome without replacing the whole template, so this control renders
-- identically under every theme for now. Revisit once the Uncapped theme
-- has real dropdown art to swap in.

local UncappedUI = _G.UncappedUI
if not UncappedUI then return end

-- choices: { { value = ..., text = "..." }, ... }
-- get(): returns the currently selected value
-- set(value): applies a newly chosen value
function UncappedUI.CreateDropdown(parent, name, width, choices, get, set)
    local dd = CreateFrame("Frame", name, parent, "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(dd, width)
    UIDropDownMenu_Initialize(dd, function()
        for _, choice in ipairs(choices) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = choice.text
            info.value = choice.value
            info.checked = get() == choice.value
            info.func = function()
                set(choice.value)
                UIDropDownMenu_SetSelectedValue(dd, choice.value)
                UIDropDownMenu_SetText(dd, choice.text)
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    for _, choice in ipairs(choices) do
        if choice.value == get() then
            UIDropDownMenu_SetSelectedValue(dd, choice.value)
            UIDropDownMenu_SetText(dd, choice.text)
            break
        end
    end
    return dd
end
