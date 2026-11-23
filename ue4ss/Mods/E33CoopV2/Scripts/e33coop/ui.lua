-- Settings menu customization & Team Screen PlayerIndicator formatting.
--
-- Features preserved & cleaned up:
--   - Adds "Random (P1/P2)" (value 3) to all 3 Character Assignment selectors in Settings
--   - Labels each slot with the character currently standing in it: "Character 1 Assignment (Sciel)"
--   - Explains in the option description that the choice follows the character
--   - Saves per-character choices into config.json and immediately re-syncs CoopConfig
--   - Shows the character's assigned player ("P1", "P2", "P3", or "P?" for Random) on PlayerIndicator

local Log = require("e33coop.log")
local Roster = require("e33coop.roster")

local UI = {}

local DESCRIPTION_PREFIX = "Select which player should control character "
local REMEMBERED_NOTE = " The choice is remembered for the character in this party position, and follows them when the party order changes."

function UI.new(ue, config, battle)
    local self = {}

    local function enhanceOptionEntry(entry, slotZeroBased, partyNames)
        local charId = partyNames[slotZeroBased + 1]
        local display = Roster.displayName(charId)

        -- 1. Update OptionName to include the character currently in this slot
        local baseTitle = string.format("Character %d Assignment", slotZeroBased + 1)
        local title = display and string.format("%s (%s)", baseTitle, display) or baseTitle
        pcall(function()
            entry:SetOptionName(FText(title))
        end)

        -- 2. Update OptionDescription to clarify per-character persistence
        pcall(function()
            local descText = entry.OptionDescription and entry.OptionDescription:ToString() or ""
            if descText ~= "" and not descText:find("remembered for the character", 1, true) then
                entry:SetOptionDescription(FText(descText .. REMEMBERED_NOTE))
            end
        end)

        -- 3. Add "Random (P1/P2)" (value 3) to WBP_NamedIntegerSelector and select the character's saved setting
        local okSel, err = pcall(function()
            local slotWidget = entry.NamedSlot_WidgetSelector
            if not ue.isValid(slotWidget) then
                return
            end
            local selector = slotWidget:GetContent()
            if not ue.isValid(selector) then
                return
            end

            selector.AvailableIntegers = {
                Roster.PLAYER_1,
                Roster.PLAYER_2,
                Roster.PLAYER_3,
                Roster.RANDOM_P1_P2,
            }
            selector:SetAvailableNames({
                FText(Roster.PLAYER_LABELS[Roster.PLAYER_1]),
                FText(Roster.PLAYER_LABELS[Roster.PLAYER_2]),
                FText(Roster.PLAYER_LABELS[Roster.PLAYER_3]),
                FText(Roster.PLAYER_LABELS[Roster.RANDOM_P1_P2]),
            })

            local configured = config.getConfiguredAssignment(charId, slotZeroBased)
            selector:SetSelectedValue(configured)
        end)
        if not okSel then
            Log.warn("Failed to enhance selector for slot %d: %s", slotZeroBased + 1, tostring(err))
        end
    end

    -- Called POST after WBP_Settings_GeneralOptionsList::SetupAvailableOptions finishes.
    function self.onSetupSettingsMenu(settingsList)
        if not ue.isValid(settingsList) then
            return
        end

        local partyNames = ue.getCurrentPartyNames()
        local ok, err = pcall(function()
            local scrollBox = settingsList.ScrollBox
            if not ue.isValid(scrollBox) then
                local subSize = settingsList.WBP_Settings_OptionEntry_Subtitles_Size
                if ue.isValid(subSize) then
                    scrollBox = subSize:GetParent()
                end
            end
            if not ue.isValid(scrollBox) then
                Log.warn("SetupSettingsMenu: could not locate Options ScrollBox")
                return
            end

            local count = scrollBox:GetChildrenCount()
            local updated = 0
            for i = 0, count - 1 do
                local child = scrollBox:GetChildAt(i)
                if ue.isValid(child) then
                    local okDesc, desc = pcall(function()
                        return child.OptionDescription and child.OptionDescription:ToString() or ""
                    end)
                    if okDesc and type(desc) == "string" and desc:sub(1, #DESCRIPTION_PREFIX) == DESCRIPTION_PREFIX then
                        local digit = desc:sub(#DESCRIPTION_PREFIX + 1, #DESCRIPTION_PREFIX + 1)
                        local slotNum = tonumber(digit)
                        if slotNum and slotNum >= 1 and slotNum <= Roster.MAX_PARTY_SLOTS then
                            enhanceOptionEntry(child, slotNum - 1, partyNames)
                            updated = updated + 1
                        end
                    end
                end
            end
            Log.debug("Enhanced %d Coop character assignment option(s) in Settings menu", updated)
        end)
        if not ok then
            Log.warn("onSetupSettingsMenu failed: %s", tostring(err))
        end
    end

    -- Called POST after WBP_Settings_GeneralOptionsList::UpdateChar<N>Assignment(Value, Name, Widget).
    function self.onUpdateCharAssignment(slotZeroBased, value)
        if type(value) ~= "number" then
            return
        end
        local partyNames = ue.getCurrentPartyNames()
        config.setSlotAssignment(slotZeroBased, value, partyNames)

        -- Immediately re-sync in-memory CoopConfig so changes apply live (even mid-battle!)
        -- and never leave raw value 3 ("Random") in ModActor.CoopConfig or the "Coop" SaveGame slot.
        battle.syncConfig("settings_update")
        if value == Roster.RANDOM_P1_P2 then
            local coopConfig = ue.getCoopConfig()
            if coopConfig then
                ue.saveCoopConfigSlot(coopConfig)
            end
        end
    end

    -- Called POST on PlayerIndicator_C::GetText(ReturnValue).
    -- Replaces the default party-slot badge ("P1"/"P2"/"P3" by slot) with the character's
    -- assigned player ("P1"/"P2"/"P3", or "P?" for Random).
    function self.onPlayerIndicatorGetText(indicator, returnValueParam)
        if not ue.isValid(indicator) or not returnValueParam then
            return
        end

        local okName, charId = pcall(function()
            local n = indicator.CharacterName
            return n and n:ToString() or nil
        end)
        if not okName or not charId or charId == "" or charId == "None" then
            return
        end

        local partyNames = ue.getCurrentPartyNames()
        local partyIndex = ue.findPartyIndex(partyNames, charId)
        if partyIndex == nil then
            -- Character is not in active party: leave ReturnValue empty so GetVisibility_0 hides badge
            return
        end

        local label = config.getIndicatorLabel(charId, partyIndex)
        pcall(function()
            returnValueParam:set(FText(label))
        end)
    end

    return self
end

return UI
